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
    (only sys argv stdout)
    (only random randrange)
    (only hissp_scheme.reader SchemeLissp transpile-scheme-file)
    (world state)
    (world terrain)
    (only ursina
          DirectionalLight Entity Mesh Ursina application camera destroy mouse window)
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
    (define FOG-END (* CHUNK-SIZE VIEW-RADIUS 0.95))

    ;; Colors as Scheme lists of RGB. Sky and fog blend between these by
    ;; height of the sun; see `scene-at`.
    (define SKY-DAY (list 0.62 0.78 0.95))
    (define SKY-DUSK (list 0.95 0.55 0.38))
    (define SKY-NIGHT (list 0.03 0.04 0.10))
    (define SUN-COLOR (list 0.95 0.88 0.75))   ; midday
    (define SUN-WARM (list 1.0 0.6 0.32))      ; near the horizon
    (define AMBIENT-NIGHT (list 0.45 0.50 0.75))
    (define PI 3.141592653589793)
    ;; The sun's path tilts toward +z, so the direction it travels is
    ;; (cos a, -sin a, 0.6) / sqrt(1.36) for angle a. This is that norm.
    (define SUN-TILT-NORM (sqrt 1.36))
    ;; Depth tolerance (fraction of the shadow camera's depth range) that
    ;; keeps terrain from shadowing itself in stripes.
    (define SHADOW-BIAS 0.002)
    ;; Side length of the square around the player that receives shadows.
    (define SHADOW-AREA (* CHUNK-SIZE 5))
    (define SUN-DISTANCE 900)

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

    (define (read-shader-source file)
      (call-method (Path (asset-path "src" "shaders" file)) 'read-text))

    (define (load-shader name)
      (call/kw Shader
               (name name
                vertex (read-shader-source (string-append name ".vert"))
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
                                                triangles triangles))
                                position (make-tuple ox 0 oz)
                                shader (state-ref 'terrain-shader)))))
        (when water
          (let ((surface (call/kw Entity
                                  (parent terrain
                                   model (call/kw Mesh
                                                  (vertices (car water)
                                                   colors (cadr water)
                                                   triangles triangles))
                                   shader (state-ref 'water-shader)))))
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
              (hash-table-delete! chunks key)))
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
      (for-each (lambda (key) (hash-table-delete! (state-ref 'in-flight) key))
                (hash-table-keys (state-ref 'in-flight)))
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
    ;; Jobs are (cx cz generation); results are (cx cz generation data).

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
            ;; A failing chunk reports #f instead of killing the worker. It stays
            ;; in flight, so it isn't retried every frame until `regenerate!`.
            (let ((data (guard (e (else (report! "chunk" e) #f))
                          (generate-chunk (list-ref job 0) (list-ref job 1) pace!))))
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
                              (list (append key (list (state-ref 'generation))))))))
      (condition-variable-signal! work-available))

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

    ;; Build entities for finished chunks, skipping ones we've walked away from
    ;; and results from before the last `regenerate!`. Leftovers beyond the
    ;; per-frame cap go back on the list.
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
                        (key (list cx cz)))
                   (cond ((not (= (list-ref job 2) (state-ref 'generation)))
                          (loop (cdr done) budget))
                         ((not (list-ref job 3))
                          (loop (cdr done) budget))
                         (else
                          (hash-table-delete! in-flight key)
                          (if (out-of-range? key pcx pcz)
                              (loop (cdr done) budget)
                              (begin
                                (hash-table-set! chunks key
                                                 (make-chunk cx cz (list-ref job 3)))
                                (loop (cdr done) (- budget 1))))))))))))

    ;; --- sun -------------------------------------------------------------

    ;; Directional sunlight with shadows, plus a visible sun disc in the sky.
    ;; The three parts are kept in state as (light bounds disc).
    ;; `look-at` takes a point, so aim one step from the light along the
    ;; sun's direction; the light moves with the player.
    (define (aim-sun!)
      (let* ((dir (state-ref 'sun-dir))
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
        (attribute-set! disc 'position
                        (make-tuple (- (attribute-ref eye 'x) (* (car dir) SUN-DISTANCE))
                                    (- (attribute-ref eye 'y) (* (cadr dir) SUN-DISTANCE))
                                    (- (attribute-ref eye 'z) (* (list-ref dir 2) SUN-DISTANCE))))))

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

    ;; What the sky looks like at `hours`. Returns
    ;;   (light-direction sun-color sky-color ambient-color)
    ;; The light direction is the way the light travels (the sun sits the
    ;; opposite way). Night is dark blue with no sun, only ambient light.
    (define (scene-at hours)
      (let* ((a (sun-angle hours))
             (height (sin a))                       ; -1 midnight, 1 noon
             (day (smooth-step -0.08 0.12 height))  ; 0 at night, 1 in daylight
             (high (smooth-step 0.0 0.45 height))   ; 0 at the horizon, 1 overhead
             (dir (list (/ (cos a) SUN-TILT-NORM)
                        (/ (- (sin a)) SUN-TILT-NORM)
                        (/ 0.6 SUN-TILT-NORM)))
             ;; Warm band around the horizon at dawn and dusk.
             (twilight (- 1.0 (smooth-step 0.0 0.3 (abs height))))
             (sun-color (scale-list (lerp-list SUN-WARM SUN-COLOR high) day))
             (sky (lerp-list (lerp-list SKY-NIGHT SKY-DAY day) SKY-DUSK twilight))
             (ambient (lerp-list AMBIENT-NIGHT (list 1.0 1.0 1.0) day)))
        (list dir sun-color sky ambient)))

    ;; Light the scene for the current hour. Only does work when the hour has
    ;; changed since the last call.
    (define (apply-time!)
      (let ((hours (state-ref 'time-of-day)))
        (unless (equal? hours (state-ref 'applied-time))
          (state-set! 'applied-time hours)
          (let* ((scene (scene-at hours))
                 (sun-color (list-ref scene 1))
                 (sky (list-ref scene 2)))
            (state-set! 'sun-dir (list-ref scene 0))
            (when (state-ref 'sun)
              (attribute-set! (car (state-ref 'sun)) 'color (rgba sun-color))
              (aim-sun!))
            (attribute-set! window 'color (rgba sky))
            (set-input! "fog_color" (rgba sky))
            (set-input! "ambient_color" (rgb (list-ref scene 3)))))))

    ;; Advance the clock by the real time since the last tick.
    (define (advance-time!)
      (let* ((t (now))
             (dt (min 0.25 (- t (state-ref 'last-tick))))
             (day-seconds (state-ref 'day-length)))
        (state-set! 'last-tick t)
        (when (> day-seconds 0.0)
          (state-set! 'time-of-day
                      (wrap-hours (+ (state-ref 'time-of-day)
                                     (* dt (/ 24.0 day-seconds))))))))

    ;; REPL: `(set-time-of-day! 18.5)` for 6:30pm. The clock keeps running
    ;; unless the day length is 0.
    (define (set-time-of-day! hours)
      (state-set! 'time-of-day (wrap-hours hours)))

    ;; REPL: `(set-day-length! 0)` freezes the clock, `(set-day-length! 60)`
    ;; runs a day in a minute.
    (define (set-day-length! seconds)
      (state-set! 'day-length seconds))

    ;; --- per-frame update and input --------------------------------------

    (define (world-update)
      (let* ((player (state-ref 'player))
             (x (attribute-ref player 'x))
             (z (attribute-ref player 'z))
             (pcx (world->chunk x))
             (pcz (world->chunk z)))
        (dev-drain!)
        (dev-poll!)
        (advance-time!)
        (apply-time!)
        ;; Stick the player to the ground (gravity is off on the controller).
        (attribute-set! player 'y (ground-height x z))
        (follow-sun! x z)
        (build-finished! pcx pcz)
        (request-missing! pcx pcz)
        (unload-far! pcx pcz)))

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
        (list (list "fog_end" FOG-END)
              (list "sea_level" SEA-LEVEL)
              (list "shadow_bias" SHADOW-BIAS)))
      (state-set! 'applied-time #f)
      (apply-time!))

    ;; --- shaders ---------------------------------------------------------

    ;; Terrain and water shaders are compiled from src/shaders/*. Ursina
    ;; compiles a shader when it is first used, so a fresh `Shader` object
    ;; picks up edits to the GLSL.
    (define (apply-shaders! terrain)
      (attribute-set! terrain 'shader (state-ref 'terrain-shader))
      (vector-for-each
        (lambda (child) (attribute-set! child 'shader (state-ref 'water-shader)))
        (attribute-ref terrain 'children)))

    (define (reload-shaders!)
      (state-set! 'terrain-shader (load-shader "terrain"))
      (state-set! 'water-shader (load-shader "water"))
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
            "shaders/water.vert" "shaders/water.frag"))
    (define WATCHED-FILES
      (append (list "world_terrain.sld" "world_game.sld") SHADER-FILES))

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

    ;; The scene copies the terrain's exports when it is imported, so after
    ;; the terrain changes the scene has to reload too. Reloading the scene
    ;; replaces these very functions, so the calls below go to the new code.
    (define (reload-changed! changed)
      (let ((terrain? (member "world_terrain.sld" changed))
            (scene? (member "world_game.sld" changed))
            (shaders? (any-member? SHADER-FILES changed)))
        (when (or terrain? scene?)
          (when terrain? (reload-library! "world_terrain.sld"))
          (reload-library! "world_game.sld")
          (apply-scene!)
          (when terrain? (regenerate!)))
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

    ;; The prompt is printed by the main thread, after each result. If the
    ;; reader printed it, it would land before the result and the next line
    ;; would show no prompt.
    (define (repl-prompt)
      (display "> ")
      (call-method stdout 'flush))

    (define (repl-loop)
      ;; EOF (or no terminal at all) ends the loop.
      (let ((line (guard (e (else #f)) (input ""))))
        (when line
          (enqueue-dev!
            (lambda ()
              (unless (equal? (call-method line 'strip) "")
                (repl-eval! line))
              (repl-prompt)))
          (repl-loop))))

    (define (start-repl!)
      (thread-start! (make-thread (lambda () (repl-loop)) "repl"))
      (display "Entering REPL. Type one Scheme form per line.")
      (newline)
      (repl-prompt))

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
        (make-sun!)
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
