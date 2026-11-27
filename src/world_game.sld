;; Infinite terrain walker.
;;
;; The world is split into square chunks. Every frame we look at which chunk
;; the player stands in, ask a background thread for missing chunks
;; nearest-first, build the ones it has finished, and drop chunks that fall
;; out of range. Each run uses a random seed unless one is given.

(define-library (world game)
  (export run setup!)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only (scheme write) display)
          (srfi 18)
          (srfi 69)
          (srfi 177)
          (only sys argv)
          (only random randrange)
          (world terrain)
          (only ursina
                DirectionalLight Entity Mesh Ursina camera destroy mouse window)
          (only ursina.prefabs.first_person_controller FirstPersonController)
          (only ursina.shader Shader)
          (only ursina.shaders.text_with_shadows_shader text-with-shadows-shader)
          (only pathlib Path)
          (only panda3d.core Filename SamplerState TexturePool)
          (rename (only panda3d.core loadPrcFileData)
                  (loadPrcFileData load-prc-file-data)))
  (begin
    ;; Chunks kept loaded in each direction from the player's chunk.
    (define VIEW-RADIUS 7)
    (define SKY-COLOR (make-tuple 0.62 0.78 0.95 1.0))
    (define FOG-END (* CHUNK-SIZE VIEW-RADIUS 0.95))

    ;; Direction the sunlight travels (normalized). Low-ish sun for long shadows.
    (define SUN-DIR
      (let* ((x 1.0) (y -0.55) (z 0.6)
             (len (sqrt (+ (* x x) (* y y) (* z z)))))
        (list (/ x len) (/ y len) (/ z len))))
    (define SUN-COLOR (make-tuple 0.95 0.88 0.75 1.0))
    ;; Depth tolerance (fraction of the shadow camera's depth range) that
    ;; keeps terrain from shadowing itself in stripes.
    (define SHADOW-BIAS 0.002)
    ;; Side length of the square around the player that receives shadows.
    (define SHADOW-AREA (* CHUNK-SIZE 5))
    (define SUN-DISTANCE 900)

    ;; (cx cz) -> Entity
    (define chunks (make-hash-table))

    ;; Parent of every chunk. Shader inputs shared by all chunks (fog, sea
    ;; level, textures, ...) are set once here and inherited. Set in `run`.
    (define world-root #f)

    ;; --- assets ----------------------------------------------------------

    ;; This library compiles to `.scheme-build/world_game.py`, so the project
    ;; root is two levels up from it.
    (define PROJECT-ROOT
      (attribute-ref (attribute-ref (call-method (Path __file__) 'resolve) 'parent)
                     'parent))

    (define (asset-path . parts)
      (let loop ((path PROJECT-ROOT) (parts parts))
        (if (null? parts)
            (call-method path 'as-posix)
            (loop (call-method path 'joinpath (car parts)) (cdr parts)))))

    ;; Mipmapped, anisotropic, repeating texture for tiling across terrain.
    (define (load-tiling-texture name)
      (let ((texture (call-method TexturePool 'load-texture
                                  (Filename (asset-path "assets" "textures" name)))))
        (call-method texture 'set-minfilter
                     (attribute-ref SamplerState 'FT_linear_mipmap_linear))
        (call-method texture 'set-magfilter (attribute-ref SamplerState 'FT_linear))
        (call-method texture 'set-anisotropic-degree 8)
        texture))

    (define (read-shader-source file)
      (call-method (Path (asset-path "src" "shaders" file)) 'read-text))

    (define (load-shader name)
      (call/kw Shader
               (name name
                vertex (read-shader-source (string-append name ".vert"))
                fragment (read-shader-source (string-append name ".frag")))))

    (define TERRAIN-SHADER #f)
    (define WATER-SHADER #f)

    (define (world->chunk v)
      (exact (floor (/ v CHUNK-SIZE))))

    ;; Offsets ordered ring by ring, so nearby chunks are built first.
    (define (ring-offsets radius)
      (let loop ((r 0) (acc '()))
        (if (> r radius)
            (reverse acc)
            (loop (+ r 1)
                  (let collect ((dz (- r)) (acc acc))
                    (if (> dz r)
                        acc
                        (collect (+ dz 1)
                                 (let row ((dx (- r)) (acc acc))
                                   (cond ((> dx r) acc)
                                         ((= r (max (abs dx) (abs dz)))
                                          (row (+ dx 1) (cons (list dx dz) acc)))
                                         (else (row (+ dx 1) acc)))))))))))

    (define OFFSETS (ring-offsets VIEW-RADIUS))

    ;; Turn generated mesh data into entities. Must run on the main thread.
    (define (make-chunk cx cz data)
      (let* ((ox (* cx CHUNK-SIZE))
             (oz (* cz CHUNK-SIZE))
             (triangles (list-ref data 2))
             (water (list-ref data 3))
             (terrain (call/kw Entity
                               (parent world-root
                                model (call/kw Mesh
                                               (vertices (car data)
                                                normals (cadr data)
                                                triangles triangles))
                                position (make-tuple ox 0 oz)
                                shader TERRAIN-SHADER))))
        (when water
          (let ((surface (call/kw Entity
                                  (parent terrain
                                   model (call/kw Mesh
                                                  (vertices (car water)
                                                   colors (cadr water)
                                                   triangles triangles))
                                   shader WATER-SHADER))))
            (call-method surface 'set-transparency #t)
            ;; Mask 1 is the shadow camera; water shouldn't shade the seabed.
            (call-method surface 'hide 1)))
        terrain))

    (define (generate-chunk cx cz pause)
      (chunk-mesh-data (* cx CHUNK-SIZE) (* cz CHUNK-SIZE) pause))

    (define (no-pause) #f)

    ;; Generate and build chunks right away on the main thread (used at spawn).
    (define (load-now! pcx pcz radius)
      (for-each
        (lambda (offset)
          (when (<= (max (abs (car offset)) (abs (cadr offset))) radius)
            (let ((cx (+ pcx (car offset)))
                  (cz (+ pcz (cadr offset))))
              (hash-table-set! chunks (list cx cz)
                               (make-chunk cx cz (generate-chunk cx cz no-pause))))))
        OFFSETS))

    (define (out-of-range? key pcx pcz)
      (> (max (abs (- (car key) pcx)) (abs (- (cadr key) pcz)))
         (+ VIEW-RADIUS 1)))

    ;; Destroy chunks further than the view radius (plus one, for hysteresis).
    (define (unload-far! pcx pcz)
      (for-each
        (lambda (key)
          (when (out-of-range? key pcx pcz)
            (destroy (hash-table-ref chunks key))
            (hash-table-delete! chunks key)))
        (hash-table-keys chunks)))

    ;; --- background generation (SRFI 18) ----------------------------------
    ;;
    ;; A worker thread runs the noise and mesh math; the main thread only
    ;; turns finished data into entities (Panda isn't thread-safe). The main
    ;; thread keeps just a couple of jobs in flight and always asks for the
    ;; nearest missing chunk, so priorities follow the player.

    (define MAX-JOBS-IN-FLIGHT 2)
    (define MAX-BUILDS-PER-FRAME 2)

    (define lock (make-mutex "chunk-queue"))
    (define work-available (make-condition-variable "chunk-work"))
    (define job-queue '())     ; keys waiting for the worker (guarded by lock)
    (define finished '())      ; (key . data) results (guarded by lock)
    (define in-flight (make-hash-table))  ; keys requested but not yet built

    (define (with-lock thunk)
      (mutex-lock! lock)
      (let ((result (thunk)))
        (mutex-unlock! lock)
        result))

    ;; Chunk math holds the GIL, so a worker running flat out lands a whole
    ;; chunk's worth of CPU in one frame. Instead it works in short bursts
    ;; and sleeps in between, spreading each chunk over a few frames.
    (define WORK-BURST 0.003)
    (define REST 0.003)

    (define (now) (time->seconds (current-time)))

    (define burst-start (now))

    (define (pace!)
      (when (> (- (now) burst-start) WORK-BURST)
        (thread-sleep! REST)
        (set! burst-start (now))))

    (define (worker-loop)
      (mutex-lock! lock)
      (if (null? job-queue)
          ;; Atomically releases the lock and waits for a signal.
          (begin (mutex-unlock! lock work-available)
                 (worker-loop))
          (let ((key (car job-queue)))
            (set! job-queue (cdr job-queue))
            (mutex-unlock! lock)
            (let ((data (generate-chunk (car key) (cadr key) pace!)))
              (with-lock (lambda () (set! finished (cons (cons key data) finished))))
              (worker-loop)))))

    (define (start-worker!)
      (thread-start! (make-thread worker-loop "chunk-worker")))

    (define (request-chunk! key)
      (hash-table-set! in-flight key #t)
      (with-lock (lambda () (set! job-queue (append job-queue (list key)))))
      (condition-variable-signal! work-available))

    ;; Ask the worker for the nearest missing chunks, up to the in-flight cap.
    (define (request-missing! pcx pcz)
      (let loop ((offsets OFFSETS))
        (when (and (pair? offsets)
                   (< (hash-table-size in-flight) MAX-JOBS-IN-FLIGHT))
          (let ((key (list (+ pcx (car (car offsets)))
                           (+ pcz (cadr (car offsets))))))
            (unless (or (hash-table-exists? chunks key)
                        (hash-table-exists? in-flight key))
              (request-chunk! key))
            (loop (cdr offsets))))))

    (define (take-finished!)
      (with-lock (lambda ()
                   (let ((done finished))
                     (set! finished '())
                     done))))

    ;; Build entities for finished chunks (skipping ones we've walked away
    ;; from). Leftovers beyond the per-frame cap go back on the list.
    (define (build-finished! pcx pcz)
      (let loop ((done (take-finished!)) (budget MAX-BUILDS-PER-FRAME))
        (cond ((null? done) #t)
              ((= budget 0)
               (with-lock (lambda () (set! finished (append done finished)))))
              (else
               (let ((key (car (car done))))
                 (hash-table-delete! in-flight key)
                 (if (out-of-range? key pcx pcz)
                     (loop (cdr done) budget)
                     (begin
                       (hash-table-set! chunks key
                                        (make-chunk (car key) (cadr key) (cdr (car done))))
                       (loop (cdr done) (- budget 1)))))))))

    ;; Directional sunlight with shadows, plus a visible sun disc in the sky.
    ;; Returns a procedure that keeps both centered on the player.
    (define (make-sun)
      (let* ((dx (car SUN-DIR))
             (dy (cadr SUN-DIR))
             (dz (list-ref SUN-DIR 2))
             (light (call/kw DirectionalLight
                             (shadow-map-resolution (make-tuple 2048 2048)
                              color SUN-COLOR)))
             ;; Shadows are only rendered inside this invisible box.
             (bounds (call/kw Entity
                              (model "cube"
                               scale (make-tuple SHADOW-AREA 90 SHADOW-AREA)
                               visible #f)))
             (disc (call/kw Entity
                            (model "sphere"
                             color (make-tuple 1.0 0.95 0.75 1.0)
                             scale 45))))
        (call-method light 'look-at (make-tuple dx dy dz))
        ;; Mask 1 is the shadow camera; the disc shouldn't cast a shadow.
        (call-method disc 'hide 1)
        (lambda (x z)
          ;; Ursina sizes the shadow lens assuming the light sits inside the
          ;; bounds box, so the light moves with it. Snapping to chunk centers
          ;; keeps shadows from shimmering as the player walks.
          (let ((cx (* CHUNK-SIZE (+ (world->chunk x) 0.5)))
                (cz (* CHUNK-SIZE (+ (world->chunk z) 0.5)))
                (eye (attribute-ref camera 'world-position)))
            (attribute-set! light 'position (make-tuple cx 35 cz))
            (attribute-set! bounds 'position (make-tuple cx 35 cz))
            (call-method light 'update-bounds bounds)
            (attribute-set! disc 'position
                            (make-tuple (- (attribute-ref eye 'x) (* dx SUN-DISTANCE))
                                        (- (attribute-ref eye 'y) (* dy SUN-DISTANCE))
                                        (- (attribute-ref eye 'z) (* dz SUN-DISTANCE))))))))

    (define (make-world-updater player follow-sun!)
      (lambda ()
        (let* ((x (attribute-ref player 'x))
               (z (attribute-ref player 'z))
               (pcx (world->chunk x))
               (pcz (world->chunk z)))
          ;; Stick the player to the ground (gravity is off on the controller).
          (attribute-set! player 'y (ground-height x z))
          (follow-sun! x z)
          (build-finished! pcx pcz)
          (request-missing! pcx pcz)
          (unload-far! pcx pcz))))

    (define (handle-input key)
      (when (equal? key "escape")
        (attribute-set! mouse 'locked (not (attribute-ref mouse 'locked)))))

    ;; macOS only offers GLSL >= 1.40 in a core profile, and requires
    ;; `#version` on the very first line.
    (define (core-profile-glsl source)
      (if (string? source)
          (call-method (call-method source 'lstrip)
                       'replace "#version 130" "#version 140")
          source))

    ;; macOS hands out a legacy OpenGL 2.1 context unless asked otherwise,
    ;; and that can't compile Ursina's shaders. Request a 3.2 core context
    ;; and fix up every shader's source right before Ursina compiles it.
    ;; Must run before `(Ursina)` opens the window.
    (define (use-core-gl!)
      (load-prc-file-data "" "gl-version 3 2")
      (let ((compile (attribute-ref Shader 'compile)))
        (attribute-set!
          Shader 'compile
          (lambda (shader . args)
            (for-each
              (lambda (stage)
                (attribute-set! shader stage
                                (core-profile-glsl (attribute-ref shader stage))))
              '(vertex fragment geometry))
            (apply compile shader args))))
      ;; Ursina compiles this one at import time, before the patch above.
      (call-method text-with-shadows-shader 'compile))

    ;; `uv run main.py 1234` revisits a world; otherwise every run is new.
    (define (choose-seed)
      (or (and (> (vector-length argv) 1) (string->number (vector-ref argv 1)))
          (randrange 1000000)))

    ;; Open the window and build the world. Returns (app player).
    (define (setup!)
      (use-core-gl!)
      (let* ((seed (choose-seed))
             (app (begin
                    (set-world-seed! seed)
                    (display "World seed: ") (display seed) (newline)
                    (call/kw Ursina
                             (title (string-append "Hissp Scheme Game - seed "
                                                   (number->string seed))
                              icon (asset-path "assets" "icon.png"))))))
        ;; Ursina's full-screen fade overlay renders opaque black in a core
        ;; profile context and hides the whole scene. We don't use fades.
        (attribute-set! (attribute-ref camera 'overlay) 'enabled #f)
        (attribute-set! window 'color SKY-COLOR)

        (set! TERRAIN-SHADER (load-shader "terrain"))
        (set! WATER-SHADER (load-shader "water"))
        (set! world-root (Entity))
        (for-each
          (lambda (input)
            (call-method world-root 'set-shader-input (car input) (cadr input)))
          (list (list "fog_color" SKY-COLOR)
                (list "fog_end" FOG-END)
                (list "sea_level" SEA-LEVEL)
                (list "shadow_bias" SHADOW-BIAS)
                (list "grass_tex" (load-tiling-texture "grass.png"))
                (list "rock_tex" (load-tiling-texture "rock.png"))))

        ;; Build the chunks right around spawn so we don't start in the void.
        (load-now! 0 0 1)
        (start-worker!)

        (let* ((player (call/kw FirstPersonController
                                (position (make-tuple 0 (ground-height 0 0) 0)
                                 gravity 0
                                 speed 12)))
               (follow-sun! (make-sun))
               (world (Entity)))
          (attribute-set! world 'update (make-world-updater player follow-sun!))
          (attribute-set! world 'input handle-input)
          (list app player))))

    (define (run)
      (call-method (car (setup!)) 'run))))
