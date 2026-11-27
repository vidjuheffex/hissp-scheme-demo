;; Infinite terrain walker: the Ursina scene.
;;
;; The world is split into square chunks. Every frame we look at which chunk
;; the player stands in, ask a background thread for missing chunks
;; nearest-first, build the ones it has finished, and drop chunks that fall
;; out of range. Each run uses a random seed unless one is given.
;;
;; This library hot-reloads: save it (or the terrain library, or a shader)
;; and the running game picks up the change within about half a second.
;; Anything that must survive a reload lives in `(world state)`.
;;
;; Live tools, typed into the terminal that started the game (one form per
;; line):
;;   (set-input! "fog_end" 80.0)   change a shader uniform immediately
;;   (set-time-of-day! 18.5)       set the clock: 0 to 24 hours
;;   (set-day-length! 0)           freeze the clock (60 = a day per minute)
;;   (moon-phase)                  day count, phase name, lit fraction
;;   (set-day! 15)                 jump the moon's cycle (0 new, 15 full)
;;   (weather)                     cloud cover, rain or snow, wet ground, snow cover
;;   (wildlife)                    how many fireflies, bats and birds are out (0 to 1)
;;   (sounds)                      ambient loop volumes: wind rain birds crickets water
;;   (set-weather! 0.9)            force the cloud cover (0 clear, 1 storm); #f undoes
;;   (set-wind! 0)                 force the wind (0 calm, 1 breeze); #f undoes
;;   (biome-here)                  biome weights under the player
;;   (visit-biome! "desert")       go to the nearest desert (or "snowy", ...)
;;   (go-to! 500 -200)             move the player
;;   (regenerate!)                 rebuild every chunk, e.g. after terrain edits
;;   (reload!)                     force-reload everything

(define-library (world game)
  (export run setup!)
  (import (scheme base)
    (scheme inexact)
    (scheme python)
    (only (scheme write) display write)
    (srfi 18)
    (srfi 69)
    (srfi 177)
    (only sys argv)
    (only readline read-history-file write-history-file set-history-length)
    (only random randrange)
    (only array array)
    (only hissp_scheme.reader SchemeLissp transpile-scheme-file)
    (world state)
    (world terrain)
    (world plants)
    (world weather)
    (world life)
    (only ursina
          Audio DirectionalLight Entity Mesh Text Ursina application camera destroy mouse window)
    (only ursina.prefabs.first_person_controller FirstPersonController)
    (only ursina.shader Shader)
    (only ursina.shaders.text_with_shadows_shader text-with-shadows-shader)
    (only pathlib Path)
    (only panda3d.core Filename SamplerState Texture TexturePool)
    (rename (only panda3d.core loadPrcFileData)
            (loadPrcFileData load-prc-file-data)))
  (begin
    ;; Chunks kept loaded in each direction from the player's chunk.
    (define VIEW-RADIUS 7)
    (define FOG-END (* CHUNK-SIZE VIEW-RADIUS 0.95))

    ;; Colors as Scheme lists of RGB. Sky and fog blend between these by
    ;; height of the sun; see `scene-at`.
    (define SKY-DAY (list 0.62 0.78 0.95))
    (define SKY-DUSK (list 0.95 0.55 0.38))
    (define SKY-NIGHT (list 0.01 0.015 0.04))     ; no moon
    (define SKY-MOONLIT (list 0.05 0.07 0.15))    ; full moon overhead
    (define SUN-COLOR (list 0.95 0.88 0.75))   ; midday
    (define SUN-WARM (list 1.0 0.6 0.32))      ; near the horizon
    (define AMBIENT-NEW-MOON (list 0.28 0.30 0.45))
    (define AMBIENT-FULL-MOON (list 0.50 0.56 0.82))
    ;; Moonlight at full moon is MOON-COLOR times MOON-BRIGHTNESS.
    (define MOON-COLOR (list 0.55 0.65 0.9))
    (define MOON-BRIGHTNESS 0.45)
    ;; Days from new moon to new moon, as for the real moon.
    (define SYNODIC-MONTH 29.53)
    (define PI 3.141592653589793)
    ;; The sun's path tilts toward +z: its light travels along
    ;; (cos a, -sin a, SUN-TILT), normalized, for angle a.
    (define SUN-TILT 0.6)
    ;; Depth tolerance (fraction of the shadow camera's depth range) that
    ;; keeps terrain from shadowing itself in stripes.
    (define SHADOW-BIAS 0.002)
    ;; Side length of the square around the player that receives shadows.
    (define SHADOW-AREA (* CHUNK-SIZE 5))
    (define SUN-DISTANCE 900)
    (define MOON-DISTANCE 850)

    ;; --- assets ----------------------------------------------------------

    ;; This library compiles to `.scheme-build/world_game.py`, so the project
    ;; root is two levels up from it.
    (define PROJECT-ROOT
      (attribute-ref (attribute-ref (call-method (Path __file__) 'resolve) 'parent)
                     'parent))
    (define SRC-ROOT (call-method PROJECT-ROOT 'joinpath "src"))
    (define BUILD-ROOT (call-method PROJECT-ROOT 'joinpath ".scheme-build"))

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

    ;; Mipmapped sprite sheet that must not wrap around at its edges.
    (define (load-sprite-texture name)
      (let ((texture (load-tiling-texture name))
            (clamp (attribute-ref SamplerState 'WM_clamp)))
        (call-method texture 'set-wrap-u clamp)
        (call-method texture 'set-wrap-v clamp)
        texture))

    ;; Files that shaders share with `#include "name"`; GLSL has no includes
    ;; of its own, so the line is replaced by the file's text.
    (define SHADER-INCLUDES (list "clouds.glsl" "stars.glsl"))

    (define (read-shader-source file)
      (let loop ((source (call-method (Path (asset-path "src" "shaders" file)) 'read-text))
                 (names SHADER-INCLUDES))
        (if (null? names)
            source
            (let ((line (string-append "#include \"" (car names) "\"")))
              (loop (if (>= (call-method source 'find line) 0)
                        (call-method source 'replace line (read-shader-source (car names)))
                        source)
                    (cdr names))))))

    ;; `vertex` names another shader whose vertex stage this one shares.
    (define (load-shader name . vertex)
      (call/kw Shader
               (name name
                vertex (read-shader-source
                         (string-append (if (pair? vertex) (car vertex) name) ".vert"))
                fragment (read-shader-source (string-append name ".frag")))))

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

    ;; --- chunk entities --------------------------------------------------

    ;; Grass clumps only grow (and show) in chunks this close to the
    ;; player's chunk. They're generated on demand, since most loaded chunks
    ;; are too far away to need them. The grass shader sinks clumps into the
    ;; ground over GRASS-FADE (distance from the camera), so they're gone
    ;; before their chunk is switched off.
    (define GRASS-RADIUS 2)
    (define GRASS-FADE (list (* CHUNK-SIZE 1.4) (* CHUNK-SIZE GRASS-RADIUS 0.95)))

    (define (grass-near? key centre)
      (<= (max (abs (- (car key) (car centre))) (abs (- (cadr key) (cadr centre))))
          GRASS-RADIUS))

    (define (show-grass! terrain show?)
      (vector-for-each
        (lambda (child)
          ;; `enabled`, not `visible`: showing again would also undo the
          ;; hide from the shadow camera.
          (when (equal? (attribute-ref child 'name) "grass")
            (attribute-set! child 'enabled show?)))
        (attribute-ref terrain 'children)))

    ;; Player chunk the grass was last shown around; #f after a reload, so
    ;; the next frame shows it again.
    (define grass-centre #f)

    (define (update-grass! pcx pcz)
      (let ((centre (list pcx pcz)))
        (unless (equal? centre grass-centre)
          (set! grass-centre centre)
          (hash-table-walk (state-ref 'chunks)
                           (lambda (key terrain)
                             (show-grass! terrain (grass-near? key centre)))))))

    ;; Turn generated mesh data into entities. Must run on the main thread.
    (define (make-chunk cx cz data)
      (let* ((ox (* cx CHUNK-SIZE))
             (oz (* cz CHUNK-SIZE))
             (triangles (list-ref data 2))
             (water (list-ref data 3))
             (terrain (call/kw Entity
                               (parent (state-ref 'world-root)
                                model (call/kw Mesh
                                               (vertices (car data)
                                                normals (cadr data)
                                                colors (list-ref data 4)
                                                triangles triangles))
                                position (make-tuple ox 0 oz)
                                shader (state-ref 'terrain-shader)))))
        (when water
          (let ((surface (call/kw Entity
                                  (parent terrain
                                   name "water"
                                   model (call/kw Mesh
                                                  (vertices (car water)
                                                   colors (cadr water)
                                                   triangles triangles))
                                   shader (state-ref 'water-shader)))))
            ;; On the model, where Ursina's own setting would override it.
            (call-method (attribute-ref surface 'model) 'set-transparency #t)
            ;; Mask 1 is the shadow camera; water shouldn't shade the seabed.
            (call-method surface 'hide 1)))
        (let ((plants (list-ref data 5)))
          ;; Tree trunks, as world (x z radius), for `keep-out-of-trunks!`.
          (attribute-set! terrain 'trunks (if plants (list-ref plants 5) '()))
          (when plants
            (let ((mesh (call/kw Mesh
                                 (vertices (car plants)
                                  normals (cadr plants)
                                  colors (list-ref plants 2)
                                  triangles (list-ref plants 3)
                                  uvs (list-ref plants 4)))))
              ;; The mesh is on the GPU now. Ursina keeps the source lists,
              ;; millions of entries across a desert, and Python's full
              ;; garbage collection pass walks them all: a 40 ms hitch.
              (attribute-set! mesh 'vertices (vector))
              (attribute-set! mesh 'normals (vector))
              (attribute-set! mesh 'colors (vector))
              (attribute-set! mesh 'triangles (vector))
              (attribute-set! mesh 'uvs (vector))
              (call/kw Entity
                       (parent terrain
                        name "plants"
                        model mesh
                        shader (state-ref 'plant-shader)
                        double_sided #t)))))
        terrain))

    ;; Add the clump mesh from `chunk-grass` to a chunk's terrain entity.
    (define (make-grass! terrain grass show?)
      (let ((clumps (call/kw Entity
                             (parent terrain
                              name "grass"
                              model (call/kw Mesh
                                             (vertices (car grass)
                                              normals (cadr grass)
                                              uvs (list-ref grass 2)
                                              colors (list-ref grass 3)
                                              triangles (list-ref grass 4)))
                              shader (state-ref 'grass-shader)
                              double_sided #t))))
        ;; Too fine for the shadow map; it would only add speckle.
        (call-method clumps 'hide 1)
        (attribute-set! clumps 'enabled show?)))

    ;; Terrain data with the chunk's plants appended at index 5.
    (define (generate-chunk cx cz pause)
      (let* ((ox (* cx CHUNK-SIZE))
             (oz (* cz CHUNK-SIZE))
             (data (chunk-mesh-data ox oz pause)))
        (append data (list (chunk-plants ox oz (car data) (list-ref data 4) pause)))))

    ;; `sources` is the chunk's terrain (vertices colors).
    (define (generate-grass cx cz sources pause)
      (chunk-grass (* cx CHUNK-SIZE) (* cz CHUNK-SIZE) (car sources) (cadr sources) pause))

    (define (no-pause) #f)

    ;; Generate and build chunks right away on the main thread (used at spawn).
    (define (load-now! pcx pcz radius)
      (for-each
        (lambda (offset)
          (when (<= (max (abs (car offset)) (abs (cadr offset))) radius)
            (let ((cx (+ pcx (car offset)))
                  (cz (+ pcz (cadr offset))))
              (hash-table-set! (state-ref 'chunks) (list cx cz)
                               (make-chunk cx cz (generate-chunk cx cz no-pause))))))
        OFFSETS))

    (define (out-of-range? key pcx pcz)
      (> (max (abs (- (car key) pcx)) (abs (- (cadr key) pcz)))
         (+ VIEW-RADIUS 1)))

    ;; Destroy chunks further than the view radius (plus one, for hysteresis).
    (define (unload-far! pcx pcz)
      (let ((chunks (state-ref 'chunks)))
        (for-each
          (lambda (key)
            (when (out-of-range? key pcx pcz)
              (destroy (hash-table-ref chunks key))
              (hash-table-delete! chunks key)
              (hash-table-delete! (state-ref 'grass-jobs) key)))
          (hash-table-keys chunks))))

    ;; Drop every chunk and any pending work. Used after terrain edits: the
    ;; generation counter makes results from the old terrain get discarded.
    (define (regenerate!)
      (let ((chunks (state-ref 'chunks)))
        (for-each
          (lambda (key)
            (destroy (hash-table-ref chunks key))
            (hash-table-delete! chunks key))
          (hash-table-keys chunks)))
      (for-each (lambda (table)
                  (for-each (lambda (key) (hash-table-delete! table key))
                            (hash-table-keys table)))
                (list (state-ref 'in-flight) (state-ref 'grass-jobs)))
      (with-lock
        (lambda ()
          (state-set! 'job-queue '())
          (state-set! 'finished '())
          (state-set! 'generation (+ 1 (state-ref 'generation))))))

    ;; --- background generation (SRFI 18) ---------------------------------
    ;;
    ;; A worker thread runs the noise and mesh math; the main thread only
    ;; turns finished data into entities (Panda isn't thread-safe). The main
    ;; thread keeps just a couple of jobs in flight and always asks for the
    ;; nearest missing chunk, so priorities follow the player.
    ;;
    ;; Jobs are (cx cz generation grass-sources): `grass-sources` is #f for
    ;; a chunk, or the chunk's terrain (vertices colors) for its grass.
    ;; Results are the job with the generated data added on the end.

    (define MAX-JOBS-IN-FLIGHT 2)
    (define MAX-BUILDS-PER-FRAME 2)

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
      (if (null? (state-ref 'job-queue))
          ;; Atomically releases the lock and waits for a signal.
          (begin (mutex-unlock! lock work-available)
                 (worker-loop))
          (let ((job (car (state-ref 'job-queue))))
            (state-set! 'job-queue (cdr (state-ref 'job-queue)))
            (mutex-unlock! lock)
            ;; A failing job reports #f instead of killing the worker. A chunk
            ;; stays in flight, so it isn't retried every frame until
            ;; `regenerate!`; grass is marked done without any.
            (let ((data (guard (e (else (report! "chunk" e) #f))
                          (if (list-ref job 3)
                              (generate-grass (list-ref job 0) (list-ref job 1)
                                              (list-ref job 3) pace!)
                              (generate-chunk (list-ref job 0) (list-ref job 1) pace!)))))
              (with-lock
                (lambda ()
                  (state-set! 'finished
                              (cons (append job (list data)) (state-ref 'finished)))))
              (worker-loop)))))

    (define (start-worker!)
      ;; A lambda, not the function itself, so a reload is picked up.
      (thread-start! (make-thread (lambda () (worker-loop)) "chunk-worker")))

    (define (request-chunk! key)
      (hash-table-set! (state-ref 'in-flight) key #t)
      (with-lock
        (lambda ()
          (state-set! 'job-queue
                      (append (state-ref 'job-queue)
                              (list (append key (list (state-ref 'generation) #f)))))))
      (condition-variable-signal! work-available))

    ;; Grass jobs go to the front of the queue: they're small, and right
    ;; around the player.
    (define MAX-GRASS-JOBS 2)

    (define (request-grass! key terrain)
      (let ((model (attribute-ref terrain 'model)))
        (hash-table-set! (state-ref 'grass-jobs) key 'pending)
        (with-lock
          (lambda ()
            (state-set! 'job-queue
                        (cons (append key (list (state-ref 'generation)
                                                (list (attribute-ref model 'vertices)
                                                      (attribute-ref model 'colors))))
                              (state-ref 'job-queue)))))
        (condition-variable-signal! work-available)))

    (define (pending-grass-jobs)
      (let count ((states (hash-table-values (state-ref 'grass-jobs))) (n 0))
        (cond ((null? states) n)
              ((equal? (car states) 'pending) (count (cdr states) (+ n 1)))
              (else (count (cdr states) n)))))

    ;; Ask for grass on loaded chunks within GRASS-RADIUS that don't have it.
    (define (request-missing-grass! pcx pcz)
      (let ((chunks (state-ref 'chunks)) (jobs (state-ref 'grass-jobs)))
        (let loop ((offsets OFFSETS) (pending (pending-grass-jobs)))
          (when (and (pair? offsets)
                     (< pending MAX-GRASS-JOBS)
                     (grass-near? (car offsets) (list 0 0)))
            (let* ((key (list (+ pcx (car (car offsets)))
                              (+ pcz (cadr (car offsets)))))
                   (terrain (hash-table-ref/default chunks key #f)))
              (if (and terrain (not (hash-table-exists? jobs key)))
                  (begin (request-grass! key terrain)
                         (loop (cdr offsets) (+ pending 1)))
                  (loop (cdr offsets) pending)))))))

    ;; Ask the worker for the nearest missing chunks, up to the in-flight cap.
    (define (request-missing! pcx pcz)
      (let ((chunks (state-ref 'chunks)) (in-flight (state-ref 'in-flight)))
        (let loop ((offsets OFFSETS))
          (when (and (pair? offsets)
                     (< (hash-table-size in-flight) MAX-JOBS-IN-FLIGHT))
            (let ((key (list (+ pcx (car (car offsets)))
                             (+ pcz (cadr (car offsets))))))
              (unless (or (hash-table-exists? chunks key)
                          (hash-table-exists? in-flight key))
                (request-chunk! key))
              (loop (cdr offsets)))))))

    (define (take-finished!)
      (with-lock
        (lambda ()
          (let ((done (state-ref 'finished)))
            (state-set! 'finished '())
            done))))

    ;; Add finished grass to its chunk, unless the chunk is gone or the result
    ;; is stale. Returns #t if it built an entity.
    (define (grass-finished! key grass pcx pcz)
      (let ((jobs (state-ref 'grass-jobs))
            (terrain (hash-table-ref/default (state-ref 'chunks) key #f)))
        (and (equal? (hash-table-ref/default jobs key #f) 'pending)
             (begin
               (hash-table-set! jobs key 'done)
               (and terrain
                    grass
                    (begin (make-grass! terrain grass (grass-near? key (list pcx pcz)))
                           #t))))))

    ;; Build entities for finished chunks and grass, skipping chunks we've
    ;; walked away from and results from before the last `regenerate!`.
    ;; Leftovers beyond the per-frame cap go back on the list.
    (define (build-finished! pcx pcz)
      (let ((chunks (state-ref 'chunks)) (in-flight (state-ref 'in-flight)))
        (let loop ((done (take-finished!)) (budget MAX-BUILDS-PER-FRAME))
          (cond ((null? done) #t)
                ((= budget 0)
                 (with-lock
                   (lambda () (state-set! 'finished (append done (state-ref 'finished))))))
                (else
                 (let* ((job (car done))
                        (cx (list-ref job 0))
                        (cz (list-ref job 1))
                        (key (list cx cz))
                        (data (list-ref job 4)))
                   (cond ((not (= (list-ref job 2) (state-ref 'generation)))
                          (loop (cdr done) budget))
                         ((list-ref job 3)
                          (loop (cdr done)
                                (if (grass-finished! key data pcx pcz) (- budget 1) budget)))
                         ((not data)
                          (loop (cdr done) budget))
                         (else
                          (hash-table-delete! in-flight key)
                          (if (out-of-range? key pcx pcz)
                              (loop (cdr done) budget)
                              (begin
                                (hash-table-set! chunks key
                                                 (make-chunk cx cz data))
                                (loop (cdr done) (- budget 1))))))))))))

    ;; --- sun -------------------------------------------------------------

    ;; One directional light casts shadows: the sun by day, the moon at
    ;; night. The light, its shadow bounds and the sun disc are kept in state
    ;; as (light bounds disc); the moon disc is separate.
    ;; `look-at` takes a point, so aim one step from the light along the
    ;; light's direction; the light moves with the player.
    (define (aim-sun!)
      (let* ((dir (state-ref 'light-dir))
             (light (car (state-ref 'sun)))
             (pos (attribute-ref light 'world-position)))
        (call-method light 'look-at
                     (make-tuple (+ (attribute-ref pos 'x) (car dir))
                                 (+ (attribute-ref pos 'y) (cadr dir))
                                 (+ (attribute-ref pos 'z) (list-ref dir 2))))))

    (define (make-sun!)
      (let* ((light (call/kw DirectionalLight
                             (shadow-map-resolution (make-tuple 2048 2048)
                              color (rgba SUN-COLOR))))
             ;; Shadows are only rendered inside this invisible box.
             (bounds (call/kw Entity
                              (model "cube"
                               scale (make-tuple SHADOW-AREA 90 SHADOW-AREA)
                               visible #f)))
             (disc (call/kw Entity
                            (model "sphere"
                             color (make-tuple 1.0 0.95 0.75 1.0)
                             scale 45))))
        (state-set! 'sun (list light bounds disc))
        ;; Mask 1 is the shadow camera; the disc shouldn't cast a shadow.
        (call-method disc 'hide 1)))

    ;; The moon is a sphere lit from the sun's direction by its shader, so
    ;; seen from the player it shows the right phase by itself.
    (define (make-moon!)
      (let ((moon (call/kw Entity
                           (model "sphere"
                            scale 80
                            shader (load-shader "moon")))))
        ;; On the model: Ursina gives models "dual" transparency, which
        ;; would draw the unlit side solid.
        (call-method (attribute-ref moon 'model) 'set-transparency #t)
        (call-method moon 'set-shader-input "moon_tex" (load-sprite-texture "moon.png"))
        (call-method moon 'hide 1)
        (state-set! 'moon moon)))

    ;; The sky is two domes around the camera: the colors of the sky first,
    ;; then the sun and moon, then the clouds over them, all drawn before the
    ;; terrain and without depth so the terrain covers them. Rain and snow
    ;; fill a box that follows the camera. Kept in state as
    ;; (sky clouds precipitation).
    (define (make-sky!)
      (let* ((sky (call/kw Entity (model "sphere" scale 1900 double_sided #t
                                   shader (load-shader "sky"))))
             (clouds (call/kw Entity (model "sphere" scale 1900 double_sided #t
                                      shader (load-shader "clouds" "sky"))))
             (data (precipitation-mesh))
             (mesh (call/kw Mesh (vertices (car data)
                                  uvs (cadr data)
                                  colors (list-ref data 2)
                                  triangles (list-ref data 3))))
             (precipitation (call/kw Entity (model mesh double_sided #t enabled #f
                                             shader (load-shader "precip")))))
        (for-each (lambda (entity order)
                    (call-method entity 'set-bin "background" order)
                    (call-method entity 'set-depth-write #f)
                    (call-method entity 'hide 1))
                  (list sky (list-ref (state-ref 'sun) 2) (state-ref 'moon) clouds)
                  (list 0 1 2 3))
        (call-method (attribute-ref clouds 'model) 'set-transparency #t)
        (call-method mesh 'set-transparency #t)
        (call-method precipitation 'set-depth-write #f)
        (call-method precipitation 'hide 1)
        (call-method precipitation 'set-shader-input "box" (rgb PRECIP-BOX))
        (call-method precipitation 'set-shader-input "wind" (rgb WIND))
        (state-set! 'sky (list sky clouds precipitation))))

    ;; Fireflies, bats and birds (see (world life)): one mesh that follows
    ;; the camera, and a float texture of the ground heights around the
    ;; player for the fireflies to hover over. Kept in state as
    ;; (entity ground-texture sampled filling): `sampled` is where the
    ;; ground in the texture was sampled, `filling` #f or the grid being
    ;; sampled next, (x z corner rows-so-far).
    (define (make-life!)
      (let* ((data (life-mesh))
             (mesh (call/kw Mesh (vertices (car data)
                                  uvs (cadr data)
                                  colors (list-ref data 2)
                                  triangles (list-ref data 3))))
             (life (call/kw Entity (model mesh double_sided #t shader (load-shader "life"))))
             (ground (Texture "life-ground"))
             (clamp (attribute-ref SamplerState 'WM_clamp)))
        (call-method ground 'setup-2d-texture GROUND-SAMPLES GROUND-SAMPLES
                     (attribute-ref Texture 'T_float) (attribute-ref Texture 'F_r32))
        (call-method ground 'set-minfilter (attribute-ref SamplerState 'FT_linear))
        (call-method ground 'set-magfilter (attribute-ref SamplerState 'FT_linear))
        (call-method ground 'set-wrap-u clamp)
        (call-method ground 'set-wrap-v clamp)
        (call-method mesh 'set-transparency #t)
        (call-method life 'set-depth-write #f)
        (call-method life 'hide 1)
        (for-each (lambda (input) (call-method life 'set-shader-input (car input) (cadr input)))
                  (list (list "box" FIREFLY-BOX)
                        (list "ground" ground)
                        (list "ground_size" (* GROUND-SAMPLES GROUND-SPACING))
                        (list "ground_corner" (make-tuple 0.0 0.0))
                        (list "fireflies" 0.0)
                        (list "bats" 0.0)
                        (list "birds" 0.0)
                        (list "ambient_color" (make-tuple 1.0 1.0 1.0))))
        (state-set! 'life (list life ground #f #f))))

    ;; How many of each creature are out where the player stands, now.
    (define (life-now x z)
      (let ((weather (state-ref 'weather))
            (hours (state-ref 'time-of-day)))
        (life-amounts hours (sin (sun-angle hours)) (car weather) (cadr weather)
                      (list-ref weather 2) (state-ref 'wind) (biome-weights x z))))

    (define GROUND-ROWS-PER-FRAME 2)

    ;; While fireflies are out, resample the ground under them once the
    ;; player has moved a few meters, a couple of rows a frame, swapping the
    ;; new grid in when it's done. And tell the shader how many of each
    ;; are out.
    (define (update-life! x z)
      (let ((life (state-ref 'life))
            (amounts (life-now x z)))
        (when life
          (let ((entity (car life))
                (texture (cadr life))
                (sampled (list-ref life 2))
                (filling (list-ref life 3)))
            (when (and (> (car amounts) 0.0)
                       (not filling)
                       (or (not sampled)
                           (> (+ (abs (- x (car sampled))) (abs (- z (cadr sampled)))) 6.0)))
              (set! filling (list x z (ground-corner x z) '())))
            (when filling
              (let loop ((k 0) (rows (list-ref filling 3)))
                (if (and (< k GROUND-ROWS-PER-FRAME) (< (length rows) GROUND-SAMPLES))
                    (loop (+ k 1)
                          (cons (ground-row (list-ref filling 2) (length rows)) rows))
                    (set! filling (list (car filling) (cadr filling) (list-ref filling 2) rows))))
              (when (= (length (list-ref filling 3)) GROUND-SAMPLES)
                (let ((corner (list-ref filling 2)))
                  (call-method texture 'set-ram-image
                               (call-method (array "f" (apply append (reverse (list-ref filling 3))))
                                            'tobytes))
                  (call-method entity 'set-shader-input "ground_corner"
                               (make-tuple (car corner) (cadr corner)))
                  (set! sampled (list (car filling) (cadr filling)))
                  (set! filling #f))))
            (state-set! 'life (list entity texture sampled filling))
            (for-each (lambda (name amount) (call-method entity 'set-shader-input name amount))
                      (list "fireflies" "bats" "birds")
                      amounts)))))

    ;; REPL: `(wildlife)` => (fireflies bats birds), each 0 to 1.
    (define (wildlife)
      (let ((player (state-ref 'player)))
        (map (lambda (a) (/ (round (* 100.0 a)) 100.0))
             (life-now (attribute-ref player 'x) (attribute-ref player 'z)))))

    ;; --- ambient sound ----------------------------------------------------

    ;; Looping ambience from assets/sounds (see tools/make_sounds.py), each
    ;; faded toward a volume set by the wind, the rain, the hour, the biome
    ;; and how near the water is.
    (define SOUNDS (list "wind" "rain" "birds" "crickets" "water"))

    ;; Seconds for a loop to get most of the way to a new volume.
    (define SOUND-FADE 4.0)

    ;; The water is listened for at points on rings around the player, one
    ;; point a frame: this many directions at each of these distances.
    (define WATER-DIRECTIONS 16)
    (define WATER-RINGS (list 6.0 18.0 40.0))
    ;; Water this far away or farther can't be heard.
    (define WATER-EARSHOT 55.0)

    (define (make-sounds!)
      (state-set! 'sounds
                  (list (map (lambda (name)
                               (call/kw Audio
                                        (sound_file_name (Path (asset-path "assets" "sounds"
                                                                           (string-append name ".ogg")))
                                         loop #t
                                         autoplay #t
                                         auto_destroy #f
                                         group "ambient"
                                         volume 0.0)))
                             SOUNDS)
                        (map (lambda (name) 0.0) SOUNDS)
                        (make-vector (* WATER-DIRECTIONS (length WATER-RINGS)) 0.0)
                        0)))

    ;; How loud the water at ring point `k` around (x, z) is: louder nearer,
    ;; nothing if the ground there is dry.
    (define (water-heard x z k)
      (let ((angle (/ (* 6.283185 (modulo k WATER-DIRECTIONS)) WATER-DIRECTIONS))
            (r (list-ref WATER-RINGS (quotient k WATER-DIRECTIONS))))
        (if (< (terrain-height (+ x (* r (cos angle))) (+ z (* r (sin angle)))) SEA-LEVEL)
            (expt (- 1.0 (/ r WATER-EARSHOT)) 1.5)
            0.0)))

    ;; Target volumes, in `SOUNDS` order, at (x, z) with water `near` (0 to 1).
    (define (sound-levels x z near)
      (let* ((weather (state-ref 'weather))
             (hours (state-ref 'time-of-day))
             (height (sin (sun-angle hours)))
             (precipitation (cadr weather))
             (snow (list-ref weather 2))
             (wind (state-ref 'wind))
             (weights (biome-weights x z))
             (desert (car weights))
             (dry (cadr weights))
             (snowy (list-ref weights 2))
             (grass (max 0.0 (- 1.0 desert dry snowy)))
             (dry-weather (- 1.0 (smooth-step 0.05 0.3 precipitation)))
             (day (smooth-step -0.05 0.15 height))
             (dark (- 1.0 (smooth-step -0.15 0.02 height)))
             (morning (if (< hours 12.0) (- 1.0 (smooth-step 8.5 10.5 hours)) 0.0)))
        (list (+ 0.06 (* 0.4 (clamp01 (/ wind 1.8))))
              (* 0.8 precipitation (- 1.0 snow))
              (* day dry-weather (+ grass (* 0.7 dry) (* 0.35 desert) (* 0.25 snowy))
                 (+ 0.55 (* 0.45 morning))
                 (- 1.0 (smooth-step 1.2 2.0 wind)))
              (* 0.7 dark dry-weather (- 1.0 snow)
                 (+ grass (* 0.8 dry) (* 0.5 desert))
                 (- 1.0 (smooth-step 1.0 1.8 wind)))
              (* 0.8 near (+ 0.35 (* 0.65 (clamp01 (/ wind 1.2))))))))

    ;; Listens for water at one more ring point, and fades every loop
    ;; toward its level over `dt` seconds.
    (define (update-sounds! x z dt)
      (let ((sounds (state-ref 'sounds)))
        (when sounds
          (let* ((heard (list-ref sounds 2))
                 (k (list-ref sounds 3))
                 (fade (- 1.0 (exp (/ (* -3.0 dt) SOUND-FADE))))
                 (volumes (map (lambda (audio volume target)
                                 (let ((v (+ volume (* (- target volume) fade))))
                                   (attribute-set! audio 'volume v)
                                   v))
                               (car sounds)
                               (cadr sounds)
                               (sound-levels x z (apply max (vector->list heard))))))
            (vector-set! heard k (water-heard x z k))
            (state-set! 'sounds
                        (list (car sounds) volumes heard
                              (modulo (+ k 1) (vector-length heard))))))))

    ;; REPL: `(sounds)` => volumes of (wind rain birds crickets water), 0 to 1.
    (define (sounds)
      (map (lambda (v) (/ (round (* 100.0 v)) 100.0)) (cadr (state-ref 'sounds))))

    (define (sky-position eye dir distance)
      (make-tuple (- (attribute-ref eye 'x) (* (car dir) distance))
                  (- (attribute-ref eye 'y) (* (cadr dir) distance))
                  (- (attribute-ref eye 'z) (* (list-ref dir 2) distance))))

    ;; Keeps the light and disc on the player. Ursina sizes the shadow lens
    ;; assuming the light sits inside the bounds box, so the light moves with
    ;; it. Snapping to chunk centers keeps shadows from shimmering as the
    ;; player walks.
    (define (follow-sun! x z)
      (let* ((sun (state-ref 'sun))
             (dir (state-ref 'sun-dir))
             (light (car sun))
             (bounds (cadr sun))
             (disc (list-ref sun 2))
             (cx (* CHUNK-SIZE (+ (world->chunk x) 0.5)))
             (cz (* CHUNK-SIZE (+ (world->chunk z) 0.5)))
             (eye (attribute-ref camera 'world-position)))
        (attribute-set! light 'position (make-tuple cx 35 cz))
        (attribute-set! bounds 'position (make-tuple cx 35 cz))
        (call-method light 'update-bounds bounds)
        (attribute-set! disc 'position (sky-position eye dir SUN-DISTANCE))
        (let ((moon (state-ref 'moon)))
          (when moon
            (attribute-set! moon 'position
                            (sky-position eye (state-ref 'moon-dir) MOON-DISTANCE))
            ;; Keeps the same face (its +z side) toward the player.
            (call-method moon 'look-at eye)))
        (let ((sky (state-ref 'sky)))
          (when sky
            (for-each (lambda (entity) (attribute-set! entity 'position eye)) sky)
            (call-method (cadr sky) 'set-shader-input "eye" eye)
            (call-method (list-ref sky 2) 'set-shader-input "eye" eye)))
        (let ((life (state-ref 'life)))
          (when life
            (attribute-set! (car life) 'position eye)
            (call-method (car life) 'set-shader-input "eye" eye)))))

    ;; --- time of day -----------------------------------------------------

    ;; The clock is `time-of-day` in hours (0 to 24) in the state table. It
    ;; advances by real time, `day-length` seconds per full day. Everything
    ;; in the sky follows from the hour, via `scene-at`.

    (define (clamp01 x) (max 0.0 (min 1.0 x)))

    ;; 0 below `lo`, 1 above `hi`, smooth in between.
    (define (smooth-step lo hi x)
      (let ((t (clamp01 (/ (- x lo) (- hi lo)))))
        (* t t (- 3.0 (* 2.0 t)))))

    (define (lerp-list a b t)
      (map (lambda (x y) (+ x (* (- y x) t))) a b))

    (define (scale-list a k)
      (map (lambda (x) (* x k)) a))

    (define (wrap-hours h)
      (- h (* 24.0 (floor (/ h 24.0)))))

    ;; Colors as Ursina tuples.
    (define (rgb c) (apply make-tuple c))
    (define (rgba c) (apply make-tuple (append c (list 1.0))))

    ;; The sun's angle: 0 at 6:00 (sunrise), PI/2 at noon, PI at 18:00.
    (define (sun-angle hours)
      (* PI (/ (- hours 6.0) 12.0)))

    ;; Direction light travels from a body at `angle` on a path tilted by
    ;; `tilt` (see SUN-TILT).
    (define (path-direction angle tilt)
      (let ((norm (sqrt (+ 1.0 (* tilt tilt)))))
        (list (/ (cos angle) norm)
              (/ (- (sin angle)) norm)
              (/ tilt norm))))

    ;; Moon phase from 0 to 1: 0 new, 0.25 first quarter, 0.5 full,
    ;; 0.75 last quarter.
    (define (moon-phase-at day hours)
      (let ((cycles (/ (+ day (/ hours 24.0)) SYNODIC-MONTH)))
        (- cycles (floor cycles))))

    ;; Lit fraction of the moon's face for a phase.
    (define (illumination phase)
      (* 0.5 (- 1.0 (cos (* 2.0 PI phase)))))

    ;; What the sky looks like at `hours` with the moon at `phase`, under
    ;; `cover` cloud (0 clear to 1 overcast) with `precipitation` (0 to 1)
    ;; falling. Returns
    ;;   (light-direction light-color sky-color ambient-color
    ;;    sun-direction moon-direction glare sun-glow overcast
    ;;    cloud-light-direction cloud-light-color stars)
    ;; `glare` (0 to 1) is how much daylight washes out the moon: most with
    ;; the sun high, less near sunrise and sunset, none at night. Overcast
    ;; turns the sky grey and hides the sun's glow; rain darkens it more. It
    ;; doesn't dim the light itself: shaders shade what's under a cloud.
    ;; `stars` (0 to 1) is how bright the stars are: out once the sky darkens,
    ;; washed out by a bright moon, gone under overcast or rain.
    ;; Clouds are lit by the light above them, and being high up they keep the
    ;; sunset's light a while after it has left the ground.
    ;; Directions are the way the light travels (the body sits the opposite
    ;; way). The moon trails the sun around the sky by its phase, as the real
    ;; one does: a full moon is opposite the sun and up all night, a new moon
    ;; is up with the sun and leaves the night dark. Once the sun is far
    ;; enough down that sunlight has faded out, the shadow light becomes the
    ;; moon, so the switch doesn't show.
    (define (scene-at hours phase cover precipitation)
      (let* ((a (sun-angle hours))
             (height (sin a))                       ; -1 midnight, 1 noon
             (day (smooth-step -0.08 0.12 height))  ; 0 at night, 1 in daylight
             (high (smooth-step 0.0 0.45 height))   ; 0 at the horizon, 1 overhead
             (night (- 1.0 (smooth-step -0.2 -0.08 height)))  ; 1 once the sun is well down
             (moon-a (- a (* 2.0 PI phase)))
             (moonlight (* (illumination phase) (smooth-step 0.0 0.15 (sin moon-a))))
             ;; Warm band around the horizon at dawn and dusk.
             (twilight (- 1.0 (smooth-step 0.0 0.3 (abs height))))
             (overcast (smooth-step 0.3 1.0 cover))
             (dim (- 1.0 (* 0.75 overcast)))
             (sun-tint (lerp-list SUN-WARM SUN-COLOR high))
             (sun-color (scale-list sun-tint day))
             (moon-color (scale-list MOON-COLOR (* MOON-BRIGHTNESS moonlight night)))
             (sun-on-clouds? (> height -0.2))
             (night-sky (lerp-list SKY-NIGHT SKY-MOONLIT (* moonlight dim)))
             (clear-sky (lerp-list (lerp-list night-sky SKY-DAY day) SKY-DUSK twilight))
             (grey (* 0.8 (+ (* 0.3 (car clear-sky)) (* 0.59 (cadr clear-sky))
                             (* 0.11 (list-ref clear-sky 2)))))
             (sky (scale-list (lerp-list clear-sky (list grey grey (* 1.06 grey))
                                         (* 0.85 overcast))
                              (- 1.0 (* 0.35 precipitation))))
             (ambient (scale-list
                        (lerp-list (lerp-list AMBIENT-NEW-MOON AMBIENT-FULL-MOON moonlight)
                                   (list 1.0 1.0 1.0)
                                   day)
                        (- 1.0 (* 0.2 overcast))))
             (sun-dir (path-direction a SUN-TILT))
             ;; The moon's tilt flips over the month, so that it's exactly
             ;; opposite the sun when full and 90 degrees off at the quarters.
             (moon-dir (path-direction moon-a (* SUN-TILT (cos (* 2.0 PI phase)))))
             (sun-light? (> height -0.08)))
        (list (if sun-light? sun-dir moon-dir)
              (if sun-light? sun-color moon-color)
              sky
              ambient
              sun-dir
              moon-dir
              (* day (+ 0.4 (* 0.6 (smooth-step 0.0 0.8 height))))
              (scale-list sun-color dim)
              overcast
              (if sun-on-clouds? sun-dir moon-dir)
              (if sun-on-clouds?
                  (scale-list sun-tint (smooth-step -0.2 0.05 height))
                  moon-color)
              (* (- 1.0 (smooth-step -0.25 -0.03 height))
                 (- 1.0 (* 0.75 moonlight))
                 (- 1.0 overcast)
                 (- 1.0 precipitation)))))

    (define (current-phase)
      (moon-phase-at (state-ref 'day) (state-ref 'time-of-day)))

    ;; Light the scene for the current hour and weather. Only does work when
    ;; either has changed since the last call.
    (define (apply-time!)
      (let* ((hours (state-ref 'time-of-day))
             (weather (state-ref 'weather))
             (cover (car weather))
             (precipitation (cadr weather))
             (key (list hours (round (* 200.0 cover)) (round (* 200.0 precipitation)))))
        (unless (equal? key (state-ref 'applied-time))
          (state-set! 'applied-time key)
          (let* ((scene (scene-at hours (current-phase) cover precipitation))
                 (sky (list-ref scene 2))
                 (sun-dir (list-ref scene 4))
                 ;; The stars turn with the sun, and a little further each
                 ;; day through the year.
                 (star-angle (+ (sun-angle hours) (* 2.0 PI (/ (state-ref 'day) 365.25))))
                 (moon (state-ref 'moon))
                 (domes (state-ref 'sky)))
            (state-set! 'light-dir (car scene))
            (state-set! 'sun-dir sun-dir)
            (state-set! 'moon-dir (list-ref scene 5))
            (when (state-ref 'sun)
              (attribute-set! (car (state-ref 'sun)) 'color (rgba (list-ref scene 1)))
              (aim-sun!))
            (when moon
              (call-method moon 'set-shader-input "to_sun" (rgb (scale-list sun-dir -1.0)))
              (call-method moon 'set-shader-input "glare" (list-ref scene 6)))
            (when domes
              (let ((sky-dome (car domes))
                    (clouds (cadr domes))
                    (cloud-light (rgb (list-ref scene 10)))
                    (ambient (rgb (list-ref scene 3))))
                (for-each (lambda (input)
                            (call-method sky-dome 'set-shader-input (car input) (cadr input)))
                          (list (list "sky_color" (rgb sky))
                                (list "to_sun" (rgb (scale-list sun-dir -1.0)))
                                (list "sun_color" (rgb (list-ref scene 7)))
                                (list "overcast" (list-ref scene 8))
                                (list "stars" (list-ref scene 11))
                                (list "star_angle" star-angle)))
                (for-each (lambda (input)
                            (call-method clouds 'set-shader-input (car input) (cadr input)))
                          (list (list "sky_color" (rgb sky))
                                (list "to_light" (rgb (scale-list (list-ref scene 9) -1.0)))
                                (list "light_color" cloud-light)
                                (list "ambient_color" ambient)
                                (list "cover" cover)
                                (list "precipitation" precipitation)))
                ;; Rain and snow are lit by what gets through the cloud.
                (call-method (list-ref domes 2) 'set-shader-input "light_color"
                             (rgb (scale-list (list-ref scene 1) (- 1.0 (* 0.75 cover)))))
                (call-method (list-ref domes 2) 'set-shader-input "ambient_color" ambient)))
            (attribute-set! window 'color (rgba sky))
            (set-input! "fog_color" (rgba sky))
            (set-input! "fog_end" (* FOG-END (- 1.0 (* 0.5 precipitation))))
            (set-input! "to_light" (rgb (scale-list (car scene) -1.0)))
            (set-input! "cover" cover)
            ;; For the sky, stars and clouds the water reflects.
            (set-input! "overcast" (list-ref scene 8))
            (set-input! "stars" (list-ref scene 11))
            (set-input! "star_angle" star-angle)
            (set-input! "precipitation" precipitation)
            (set-input! "cloud_light_color" (rgb (list-ref scene 10)))
            (set-input! "ambient_color" (rgb (list-ref scene 3)))
            (when (state-ref 'life)
              (call-method (car (state-ref 'life)) 'set-shader-input "ambient_color"
                           (rgb (list-ref scene 3))))))))

    ;; Advance the clock by the real time since the last tick, counting days
    ;; at midnight. Returns the seconds since the last tick.
    (define (advance-time!)
      (let* ((t (now))
             (dt (min 0.25 (- t (state-ref 'last-tick))))
             (day-seconds (state-ref 'day-length)))
        (state-set! 'last-tick t)
        (when (> day-seconds 0.0)
          (let ((hours (+ (state-ref 'time-of-day) (* dt (/ 24.0 day-seconds)))))
            (when (>= hours 24.0)
              (state-set! 'day (+ (state-ref 'day) 1)))
            (state-set! 'time-of-day (wrap-hours hours))))
        dt))

    ;; REPL: `(set-time-of-day! 18.5)` for 6:30pm. The clock keeps running
    ;; unless the day length is 0.
    (define (set-time-of-day! hours)
      (state-set! 'time-of-day (wrap-hours hours)))

    (define PHASE-NAMES
      (vector "new moon" "waxing crescent" "first quarter" "waxing gibbous"
              "full moon" "waning gibbous" "last quarter" "waning crescent"))

    ;; REPL: `(moon-phase)` => (day name lit-fraction), e.g.
    ;; (10 "waxing gibbous" 0.81).
    (define (moon-phase)
      (let ((phase (current-phase)))
        (list (state-ref 'day)
              (vector-ref PHASE-NAMES (modulo (exact (round (* phase 8.0))) 8))
              (/ (round (* 100.0 (illumination phase))) 100.0))))

    ;; REPL: `(set-day! 15)` jumps the moon's cycle: day 0 is a new moon,
    ;; about 7 first quarter, 15 full, 22 last quarter.
    (define (set-day! day)
      (state-set! 'day day)
      (state-set! 'applied-time #f)
      (moon-phase))

    ;; REPL: `(set-day-length! 0)` freezes the clock, `(set-day-length! 60)`
    ;; runs a day in a minute.
    (define (set-day-length! seconds)
      (state-set! 'day-length seconds))

    ;; --- weather ---------------------------------------------------------

    ;; Meters per second the wind carries the clouds.
    (define CLOUD-SPEED 8.0)

    (define (weather-days)
      (+ (state-ref 'day) (/ (state-ref 'time-of-day) 24.0)))

    ;; Move the weather on `dt` seconds toward what it should be where the
    ;; player stands, and hand it to the shaders.
    (define (update-weather! x z dt)
      (let* ((target (weather-target (weather-days) x z
                                     (attribute-ref (state-ref 'player) 'y)
                                     (state-ref 'weather-override)))
             (now-weather (weather-step (state-ref 'weather) target dt))
             (drift (map (lambda (d w) (+ d (* w CLOUD-SPEED dt)))
                         (state-ref 'cloud-drift) WIND))
             (wind (if (state-ref 'wind-override)
                       (state-ref 'wind-override)
                       (wind-speed (weather-days) (sin (sun-angle (state-ref 'time-of-day)))
                                   (car now-weather) (cadr now-weather))))
             (sky (state-ref 'sky)))
        (state-set! 'weather now-weather)
        (state-set! 'cloud-drift drift)
        (state-set! 'wind wind)
        (set-input! "wind_speed" wind)
        (set-input! "wetness" (list-ref now-weather 3))
        (set-input! "rain" (* (cadr now-weather) (- 1.0 (list-ref now-weather 2))))
        (set-input! "drift" (apply make-tuple drift))
        (set-input! "snow_cover" (list-ref now-weather 4))
        (when sky
          (call-method (cadr sky) 'set-shader-input "drift" (apply make-tuple drift))
          (let ((precipitation (list-ref sky 2))
                (amount (cadr now-weather)))
            (attribute-set! precipitation 'enabled (> amount 0.01))
            (call-method precipitation 'set-shader-input "intensity" amount)
            (call-method precipitation 'set-shader-input "snow" (list-ref now-weather 2))))))

    ;; Start on the weather that belongs at (x, z), rather than clearing up
    ;; or clouding over during the first seconds.
    (define (settle-weather! x z)
      (state-set! 'weather
                  (append (weather-target (weather-days) x z (ground-height x z)
                                          (state-ref 'weather-override))
                          (list 0.0 0.0))))

    ;; REPL: `(weather)` => (cover precipitation kind wetness snow-cover wind),
    ;; e.g. (0.82 0.4 "rain" 0.6 0.0 1.3).
    (define (weather)
      (let ((w (state-ref 'weather))
            (round2 (lambda (x) (/ (round (* 100.0 x)) 100.0))))
        (list (round2 (car w))
              (round2 (cadr w))
              (if (> (list-ref w 2) 0.5) "snow" "rain")
              (round2 (list-ref w 3))
              (round2 (list-ref w 4))
              (round2 (state-ref 'wind)))))

    ;; REPL: `(set-wind! 0)` makes it dead calm (glassy water), `(set-wind! 1.5)`
    ;; a gale, `(set-wind! #f)` lets the wind run by itself again.
    (define (set-wind! speed)
      (state-set! 'wind-override speed))

    ;; REPL: `(set-weather! 1.0)` brings a storm wherever you are,
    ;; `(set-weather! 0)` clears the sky, `(set-weather! #f)` lets the
    ;; weather run by itself again.
    (define (set-weather! cover)
      (state-set! 'weather-override cover))

    ;; --- biomes (REPL helpers) -------------------------------------------

    (define (player-xz)
      (let ((player (state-ref 'player)))
        (list (attribute-ref player 'x) (attribute-ref player 'z))))

    ;; Name of the biome with the most weight at (x, z).
    (define (dominant-biome x z)
      (let loop ((rest (biome-at x z)) (best #f))
        (cond ((null? rest) (car best))
              ((or (not best) (> (cdar rest) (cdr best))) (loop (cdr rest) (car rest)))
              (else (loop (cdr rest) best)))))

    ;; `(biome-here)`: each biome's share of the ground under the player.
    (define (biome-here)
      (apply biome-at (player-xz)))

    ;; `(find-biome "desert")`: the nearest (x z) where that biome dominates,
    ;; searching rings 64 units apart out to about 4 km, or #f.
    (define (find-biome name)
      (let* ((here (player-xz))
             (px (car here))
             (pz (cadr here)))
        (let ring ((r 1))
          (and (<= r 60)
               (let ((n (* 8 r)))
                 (let try ((k 0))
                   (if (= k n)
                       (ring (+ r 1))
                       (let* ((a (/ (* 2.0 PI k) n))
                              (x (+ px (* 64.0 r (cos a))))
                              (z (+ pz (* 64.0 r (sin a)))))
                         (if (equal? (dominant-biome x z) name)
                             (list x z)
                             (try (+ k 1)))))))))))

    ;; `(go-to! x z)`: move the player; chunks stream in around the new spot.
    (define (go-to! x z)
      (let ((player (state-ref 'player)))
        (attribute-set! player 'x x)
        (attribute-set! player 'z z)))

    ;; `(visit-biome! "snowy")`: go to the nearest spot of that biome.
    (define (visit-biome! name)
      (let ((spot (find-biome name)))
        (when spot (go-to! (car spot) (cadr spot)))
        spot))

    ;; --- per-frame update and input --------------------------------------

    (define PLAYER-RADIUS 0.35)

    ;; Push the player out of any tree trunk in their chunk or those around.
    (define (keep-out-of-trunks! player)
      (let ((chunks (state-ref 'chunks))
            (cx (world->chunk (attribute-ref player 'x)))
            (cz (world->chunk (attribute-ref player 'z))))
        (for-each
          (lambda (dx)
            (for-each
              (lambda (dz)
                (let ((terrain (hash-table-ref/default chunks (list (+ cx dx) (+ cz dz)) #f)))
                  (when terrain
                    (for-each
                      (lambda (trunk)
                        (let* ((ox (- (attribute-ref player 'x) (car trunk)))
                               (oz (- (attribute-ref player 'z) (cadr trunk)))
                               (reach (+ PLAYER-RADIUS (list-ref trunk 2)))
                               (d (sqrt (+ (* ox ox) (* oz oz)))))
                          (when (and (< d reach) (> d 1e-6))
                            (attribute-set! player 'x (+ (car trunk) (* ox (/ reach d))))
                            (attribute-set! player 'z (+ (cadr trunk) (* oz (/ reach d)))))))
                      (attribute-ref terrain 'trunks)))))
              (list -1 0 1)))
          (list -1 0 1))))

    ;; --- coordinates readout ----------------------------------------------

    ;; The player's position, top left, in Lexend Deca (assets/fonts): one
    ;; line per axis so the labels don't shift as the numbers change width,
    ;; over a dark copy offset down and right as a drop shadow.
    (define HUD-MARGIN 0.025)
    (define HUD-SHADOW 0.0022)

    (define (make-hud!)
      (attribute-set! application 'fonts_folder (Path (asset-path "assets" "fonts")))
      (let ((corner (attribute-ref window 'top_left))
            (shader (load-shader "hud")))
        (call-method shader 'compile)
        (let ((label
                (lambda (offset z color)
                  (call/kw Text
                      (text " "
                       font "LexendDeca.ttf"
                       resolution 160
                       line_height 1.15
                       origin (make-tuple -0.5 0.5)
                       position (make-tuple
                                  (+ (attribute-ref corner 'x) HUD-MARGIN offset)
                                  (- (attribute-ref corner 'y) HUD-MARGIN offset)
                                  z)
                       color color
                       shader shader)))))
          (let ((shadow (label HUD-SHADOW 0.01 (make-tuple 0.0 0.0 0.0 0.45)))
                (text (label 0.0 0.0 (make-tuple 1.0 1.0 1.0 0.92))))
            ;; Wider gaps between glyphs in the font's texture, or the edges
            ;; of neighboring glyphs bleed in as slivers.
            (let ((font (attribute-ref text 'font)))
              (call-method font 'set-texture-margin 6)
              (call-method font 'set-poly-margin 1.0)
              (call-method font 'clear))
            (state-set! 'hud (list shadow text #f))))))

    ;; Only rebuilds the text when the rounded position changes.
    (define (update-hud! player)
      (let* ((hud (state-ref 'hud))
             (meters (lambda (axis)
                       (number->string (exact (round (attribute-ref player axis))))))
             (shown (string-append "X  " (meters 'x) "\nY  " (meters 'y) "\nZ  " (meters 'z))))
        (when (and hud (not (equal? shown (list-ref hud 2))))
          (attribute-set! (car hud) 'text shown)
          (attribute-set! (cadr hud) 'text shown)
          (set-car! (cddr hud) shown))))

    (define (world-update)
      (keep-out-of-trunks! (state-ref 'player))
      (let* ((player (state-ref 'player))
             (x (attribute-ref player 'x))
             (z (attribute-ref player 'z))
             (pcx (world->chunk x))
             (pcz (world->chunk z)))
        (dev-drain!)
        (dev-poll!)
        (let ((dt (advance-time!)))
          (update-weather! x z dt)
          (apply-time!)
          (update-life! x z)
          (update-sounds! x z dt))
        ;; Stick the player to the ground (gravity is off on the controller).
        (attribute-set! player 'y (ground-height x z))
        (follow-sun! x z)
        (update-hud! player)
        (build-finished! pcx pcz)
        (request-missing! pcx pcz)
        (unload-far! pcx pcz)
        (request-missing-grass! pcx pcz)
        (update-grass! pcx pcz)))

    ;; Errors in a frame are printed once each, not every frame.
    (define (frame-safely)
      (guard (e (else (report-once! "frame" e)))
        (world-update)))

    (define (handle-input key)
      (when (equal? key "escape")
        (attribute-set! mouse 'locked (not (attribute-ref mouse 'locked)))))

    ;; --- scene settings --------------------------------------------------

    (define (set-input! name value)
      (call-method (state-ref 'world-root) 'set-shader-input name value))

    ;; Fog, shadows and the lighting for the current hour. Runs at setup and
    ;; after the scene library reloads, so edits to these show up at once.
    (define (apply-scene!)
      (for-each
        (lambda (input) (set-input! (car input) (cadr input)))
        (list (list "sea_level" SEA-LEVEL)
              (list "shadow_bias" SHADOW-BIAS)
              (list "grass_fade" (make-tuple (car GRASS-FADE) (cadr GRASS-FADE)))))
      (state-set! 'applied-time #f)
      (apply-time!))

    ;; --- shaders ---------------------------------------------------------

    ;; Terrain, water, grass and plant shaders are compiled from src/shaders/*.
    ;; Ursina compiles a shader when it is first used, so a fresh `Shader`
    ;; object picks up edits to the GLSL.
    (define (apply-shaders! terrain)
      (attribute-set! terrain 'shader (state-ref 'terrain-shader))
      (vector-for-each
        (lambda (child)
          (attribute-set! child 'shader
                          (state-ref (let ((name (attribute-ref child 'name)))
                                       (cond ((equal? name "grass") 'grass-shader)
                                             ((equal? name "plants") 'plant-shader)
                                             (else 'water-shader))))))
        (attribute-ref terrain 'children)))

    (define (reload-shaders!)
      (state-set! 'terrain-shader (load-shader "terrain"))
      (state-set! 'water-shader (load-shader "water"))
      (state-set! 'grass-shader (load-shader "grass"))
      (state-set! 'plant-shader (load-shader "plant"))
      (when (state-ref 'moon)
        (attribute-set! (state-ref 'moon) 'shader (load-shader "moon")))
      (let ((sky (state-ref 'sky)))
        (when sky
          (attribute-set! (car sky) 'shader (load-shader "sky"))
          (attribute-set! (cadr sky) 'shader (load-shader "clouds" "sky"))
          (attribute-set! (list-ref sky 2) 'shader (load-shader "precip"))))
      (when (state-ref 'life)
        (attribute-set! (car (state-ref 'life)) 'shader (load-shader "life")))
      (hash-table-walk (state-ref 'chunks)
                       (lambda (key terrain) (apply-shaders! terrain))))

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

    ;; --- live reload -----------------------------------------------------

    (define SHADER-FILES
      (list "shaders/terrain.vert" "shaders/terrain.frag"
            "shaders/water.vert" "shaders/water.frag"
            "shaders/grass.vert" "shaders/grass.frag"
            "shaders/plant.vert" "shaders/plant.frag"
            "shaders/moon.vert" "shaders/moon.frag"
            "shaders/sky.vert" "shaders/sky.frag" "shaders/clouds.frag" "shaders/clouds.glsl" "shaders/stars.glsl"
            "shaders/precip.vert" "shaders/precip.frag"
            "shaders/life.vert" "shaders/life.frag"))
    (define WATCHED-FILES
      (append (list "world_terrain.sld" "world_plants.sld" "world_weather.sld" "world_life.sld"
                  "world_game.sld")
              SHADER-FILES))

    (define (file-mtime name)
      (guard (e (else #f))
        (attribute-ref (call-method (call-method SRC-ROOT 'joinpath name) 'stat)
                       'st_mtime)))

    ;; Names of watched files whose modification time changed since last poll.
    ;; The first poll only records times.
    (define (poll-changes!)
      (let ((mtimes (state-ref 'mtimes)) (changed '()))
        (for-each
          (lambda (name)
            (let ((mtime (file-mtime name)))
              (when mtime
                (let ((old (hash-table-ref/default mtimes name #f)))
                  (when (and old (not (= old mtime)))
                    (set! changed (cons name changed))))
                (hash-table-set! mtimes name mtime))))
          WATCHED-FILES)
        changed))

    ;; Hissp evaluates a library's top-level forms into its module while it
    ;; transpiles them, so transpiling the file *is* the reload: definitions
    ;; are replaced in place. State in (world state) is kept. (importlib.reload
    ;; isn't used: these modules have no __spec__.)
    (define (reload-library! file)
      (transpile-scheme-file (call-method SRC-ROOT 'joinpath file) "" BUILD-ROOT))

    (define (any-member? names items)
      (and (pair? names)
           (or (member (car names) items)
               (any-member? (cdr names) items))))

    ;; Libraries copy their imports' exports when imported, so after the
    ;; terrain changes the plants, the weather and the scene have to reload too. Reloading the scene
    ;; replaces these very functions, so the calls below go to the new code.
    (define (reload-changed! changed)
      (let* ((terrain? (member "world_terrain.sld" changed))
             (plants? (or terrain? (member "world_plants.sld" changed)))
             (weather? (or terrain? (member "world_weather.sld" changed)))
             (life? (or terrain? (member "world_life.sld" changed)))
             (scene? (member "world_game.sld" changed))
             (shaders? (any-member? SHADER-FILES changed)))
        (when (or plants? weather? life? scene?)
          (when terrain? (reload-library! "world_terrain.sld"))
          (when plants? (reload-library! "world_plants.sld"))
          (when weather? (reload-library! "world_weather.sld"))
          (when life? (reload-library! "world_life.sld"))
          (reload-library! "world_game.sld")
          (apply-scene!)
          (when plants? (regenerate!)))
        (when shaders? (reload-shaders!))
        changed))

    ;; Poll file times about twice a second. Called from the frame update.
    (define (dev-poll!)
      (let ((time (now)))
        (when (> (- time (state-ref 'last-poll)) 0.4)
          (state-set! 'last-poll time)
          (let ((changed (poll-changes!)))
            (when (pair? changed)
              (guard (e (else (report! "reload" e)))
                (reload-changed! changed)
                (display "reloaded:")
                (for-each (lambda (name) (display " ") (display name)) changed)
                (newline)))))))

    ;; At the REPL, shows the list of files that were reloaded.
    (define (reload!)
      (reload-changed! WATCHED-FILES))

    ;; --- terminal REPL ---------------------------------------------------
    ;;
    ;; A thread reads lines from the terminal and queues them. The main
    ;; thread evaluates them between frames, because Panda work has to happen
    ;; there. Evaluation happens in this module's namespace, so definitions
    ;; take effect immediately.

    (define (report! where e)
      (display (string-append "[" where "] " (str e)))
      (newline))

    (define (report-once! where e)
      (let ((message (string-append where ": " (str e))))
        (when (not (equal? message (state-ref 'last-error)))
          (state-set! 'last-error message)
          (display message)
          (newline))))

    (define (enqueue-dev! thunk)
      (with-lock
        (lambda ()
          (state-set! 'dev-queue (append (state-ref 'dev-queue) (list thunk))))))

    (define (dev-drain!)
      (let ((thunks (with-lock
                      (lambda ()
                        (let ((queued (state-ref 'dev-queue)))
                          (state-set! 'dev-queue '())
                          queued)))))
        (for-each (lambda (thunk) (thunk)) thunks)))

    ;; Helpers that return nothing (Python None) print nothing.
    (define (repl-show value)
      (unless (equal? (str value) "None")
        (write value)
        (newline)))

    (define (define-form? text)
      (call-method (call-method text 'lstrip) 'startswith "(define"))

    (define (repl-eval! text)
      (guard (e (else (report! "repl" e)))
        ;; Expressions are wrapped so their value gets printed.
        (let* ((source (if (define-form? text)
                           text
                           (string-append "(repl-show " text ")")))
               (compiler (call/kw SchemeLissp
                                  ;; The .scm suffix makes the reader treat quoted
                                  ;; names like the libraries do.
                                  (qualname "world_game"
                                   env (globals)
                                   filename "<repl>.scm")))
               (code (call-method compiler 'compile source)))
          (exec code (globals)))))

    ;; Up/down recall earlier lines (importing `readline` turns that on for
    ;; `input`), including lines from earlier runs.
    (define HISTORY-FILE
      (string-append (str (call-method Path 'home)) "/.hissp_scheme_game_history"))

    (define (load-history!)
      (set-history-length 1000)
      (guard (e (else #f)) (read-history-file HISTORY-FILE)))

    (define (save-history!)
      (guard (e (else #f)) (write-history-file HISTORY-FILE)))

    ;; The reader waits for each line to finish before showing the next
    ;; prompt, so results print above it. `input` draws the prompt itself,
    ;; so line editing redraws it correctly.
    (define (repl-wait!)
      (mutex-lock! lock)
      (if (state-ref 'repl-busy)
          (begin (mutex-unlock! lock repl-done)
                 (repl-wait!))
          (mutex-unlock! lock)))

    (define (repl-finished!)
      (with-lock
        (lambda ()
          (state-set! 'repl-busy #f)
          (condition-variable-broadcast! repl-done))))

    (define (repl-loop)
      ;; EOF (or no terminal at all) ends the loop.
      (let ((line (guard (e (else #f)) (input "> "))))
        (when line
          (let ((blank? (equal? (call-method line 'strip) "")))
            (unless blank? (save-history!))
            (with-lock (lambda () (state-set! 'repl-busy #t)))
            (enqueue-dev!
              (lambda ()
                (dynamic-wind
                  (lambda () #f)
                  (lambda () (unless blank? (repl-eval! line)))
                  repl-finished!)))
            (repl-wait!)
            (repl-loop)))))

    (define (start-repl!)
      (load-history!)
      (display "Entering REPL. Type one Scheme form per line.")
      (newline)
      (thread-start! (make-thread (lambda () (repl-loop)) "repl")))

    ;; --- setup -----------------------------------------------------------

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
        ;; Ursina logs "info: changed aspect ratio" when the window settles,
        ;; a few frames in. It would land on the REPL prompt, so turn off
        ;; Ursina's info messages.
        (attribute-set! application 'print_info #f)

        (state-set! 'world-root (Entity))
        (reload-shaders!)
        (set-input! "grass_tex" (load-tiling-texture "grass.png"))
        (set-input! "rock_tex" (load-tiling-texture "rock.png"))
        (set-input! "clump_tex" (load-sprite-texture "grass_clumps.png"))
        (make-sun!)
        (make-moon!)
        (make-sky!)
        (make-life!)
        (make-hud!)
        (make-sounds!)
        (settle-weather! 0 0)
        (state-set! 'last-tick (now))
        (apply-scene!)

        ;; Build the chunks right around spawn so we don't start in the void.
        (load-now! 0 0 1)
        (start-worker!)
        (start-repl!)

        (let* ((player (call/kw FirstPersonController
                                (position (make-tuple 0 (ground-height 0 0) 0)
                                 gravity 0
                                 speed 12)))
               (world (Entity)))
          (state-set! 'player player)
          (attribute-set! world 'update (lambda () (frame-safely)))
          (attribute-set! world 'input (lambda (key) (handle-input key)))
          (list app player))))

    ;; `info` #f: skip Ursina's "os: / python version / development mode"
    ;; block, which would otherwise print after the REPL greeting.
    (define (run)
      (call-method (car (setup!)) 'run #f))))
