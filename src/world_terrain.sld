;; Procedural terrain math: deterministic noise -> heights -> chunk mesh data.
;;
;; No engine imports here, so this library can be loaded and tested without
;; opening a window. Mesh data is returned as Scheme vectors (Python lists),
;; which Ursina's `Mesh` accepts directly. Surface coloring (grass, rock,
;; sand, snow) happens in `shaders/terrain.frag`.
;;
;; Each world is picked by a seed. The seed just shifts where in the (endless)
;; noise field we sample, so every seed is a different but repeatable world.

(define-library (world terrain)
  (export CHUNK-SIZE
          CHUNK-RES
          SEA-LEVEL
          set-world-seed!
          terrain-height
          ground-height
          chunk-mesh-data)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only random Random))
  (begin
    ;; World units per chunk side, and grid cells per chunk side.
    (define CHUNK-SIZE 32)
    (define CHUNK-RES 32)
    (define CELL (/ CHUNK-SIZE CHUNK-RES 1.0))

    (define SEA-LEVEL 6.0)
    (define HEIGHT-SCALE (* 48.0 1.6))
    (define BASE-FREQUENCY 0.012)
    (define OCTAVES 6)

    ;; --- seed ------------------------------------------------------------

    ;; World-space offset applied before sampling noise. Kept within +-50k so
    ;; the sine hash below stays precise at the highest octave.
    (define SEED-X 0.0)
    (define SEED-Z 0.0)

    (define (set-world-seed! seed)
      (let ((rng (Random seed)))
        (set! SEED-X (call-method rng 'uniform -50000.0 50000.0))
        (set! SEED-Z (call-method rng 'uniform -50000.0 50000.0))))

    ;; --- noise -----------------------------------------------------------

    ;; Cheap deterministic hash of an integer lattice point into [0, 1).
    (define (hash2 ix iz)
      (let ((s (* (sin (+ (* ix 127.1) (* iz 311.7))) 43758.5453)))
        (- s (floor s))))

    (define (smooth t) (* t t (- 3.0 (* 2.0 t))))

    (define (lerp a b t) (+ a (* (- b a) t)))

    ;; Smoothly interpolated value noise in [0, 1) at a single point.
    (define (value-noise x z)
      (let* ((ix (floor x))
             (iz (floor z))
             (u (smooth (- x ix)))
             (v (smooth (- z iz))))
        (lerp (lerp (hash2 ix iz) (hash2 (+ ix 1) iz) u)
              (lerp (hash2 ix (+ iz 1)) (hash2 (+ ix 1) (+ iz 1)) u)
              v)))

    (define FBM-NORM
      (let loop ((i 0) (amp 0.5) (norm 0.0))
        (if (= i OCTAVES) norm (loop (+ i 1) (* amp 0.5) (+ norm amp)))))

    (define (height-from-noise n) (* HEIGHT-SCALE n n))

    ;; Raw terrain height at one world (x, z). Squaring the noise gives flat
    ;; lowlands with occasional steep hills. `noise-grid` below computes the
    ;; same values for a whole grid at once; keep the two in step.
    (define (terrain-height x z)
      (let ((x (* (+ x SEED-X) BASE-FREQUENCY))
            (z (* (+ z SEED-Z) BASE-FREQUENCY)))
        (let loop ((i 0) (freq 1.0) (amp 0.5) (sum 0.0))
          (if (= i OCTAVES)
              (height-from-noise (/ sum FBM-NORM))
              (loop (+ i 1)
                    (* freq 2.0)
                    (* amp 0.5)
                    (+ sum (* amp (value-noise (* x freq) (* z freq)))))))))

    ;; Walkable height: terrain, but never below the water surface.
    (define (ground-height x z)
      (max SEA-LEVEL (terrain-height x z)))

    ;; --- fast grid noise ---------------------------------------------------
    ;;
    ;; Chunks sample a regular grid, so almost all of the per-point work in
    ;; `value-noise` is shared between neighbors:
    ;;   - each column's lattice cell and x weight depend only on the column,
    ;;   - each row's z weight depends only on the row,
    ;;   - the lattice hashes are reused by every sample in the cell.
    ;; So per octave we hash each lattice point once, blend lattice rows by the
    ;; row's z weight once per row, and each sample is then a single lerp.

    ;; Per-axis setup: for `count` samples starting at world coordinate `start`
    ;; spaced `step` apart, return (first-cell cell-offsets weights), where
    ;; cell-offsets[i] is the sample's lattice cell relative to first-cell.
    (define (axis-cells start step count scale)
      (let* ((first (floor (* start scale)))
             (offsets (make-vector count 0))
             (weights (make-vector count 0.0)))
        (do ((i 0 (+ i 1))) ((= i count))
          (let* ((p (* (+ start (* i step)) scale))
                 (cell (floor p)))
            (vector-set! offsets i (exact (- cell first)))
            (vector-set! weights i (smooth (- p cell)))))
        (list first offsets weights)))

    ;; Fill `out` (count x count, row-major) with fbm noise in [0, 1) for a grid
    ;; whose first sample is world (x0, z0). Calls `pause` between rows so a
    ;; worker thread can let the render thread run.
    (define (noise-grid! out x0 z0 step count pause)
      (vector-fill! out 0.0)
      (let octave ((o 0) (freq BASE-FREQUENCY) (amp (/ 0.5 FBM-NORM)))
        (when (< o OCTAVES)
          (let* ((xs (axis-cells (+ x0 SEED-X) step count freq))
                 (zs (axis-cells (+ z0 SEED-Z) step count freq))
                 (cx0 (car xs)) (col-cells (cadr xs)) (col-weights (list-ref xs 2))
                 (cz0 (car zs)) (row-cells (cadr zs)) (row-weights (list-ref zs 2))
                 ;; Lattice points needed, +1 for each cell's far corner.
                 (width (+ (vector-ref col-cells (- count 1)) 2))
                 (height (+ (vector-ref row-cells (- count 1)) 2))
                 (lattice (make-vector (* width height) 0.0))
                 (blended (make-vector width 0.0)))
            (do ((j 0 (+ j 1))) ((= j height))
              (do ((i 0 (+ i 1))) ((= i width))
                (vector-set! lattice (+ i (* j width))
                             (hash2 (+ cx0 i) (+ cz0 j)))))
            (do ((j 0 (+ j 1))) ((= j count))
              (let* ((base (* (vector-ref row-cells j) width))
                     (v (vector-ref row-weights j))
                     (row (* j count)))
                (do ((i 0 (+ i 1))) ((= i width))
                  (let ((a (vector-ref lattice (+ base i))))
                    (vector-set! blended i
                                 (+ a (* (- (vector-ref lattice (+ base i width)) a) v)))))
                (do ((i 0 (+ i 1))) ((= i count))
                  (let* ((k (vector-ref col-cells i))
                         (a (vector-ref blended k))
                         (index (+ row i)))
                    (vector-set! out index
                                 (+ (vector-ref out index)
                                    (* amp (+ a (* (- (vector-ref blended (+ k 1)) a)
                                                   (vector-ref col-weights i))))))))
                (pause)))
            (octave (+ o 1) (* freq 2.0) (* amp 0.5))))))

    ;; --- chunk mesh ------------------------------------------------------

    (define VERTS (+ CHUNK-RES 1))        ; vertices per side
    (define SAMPLES (+ CHUNK-RES 3))      ; heights per side, with 1-cell border

    ;; Two triangles per grid cell, wound so the front faces point up (+y).
    ;; Identical for every chunk, so it's built once and shared.
    (define TRIANGLES
      (let ((triangles (make-vector (* CHUNK-RES CHUNK-RES 6) 0)))
        (do ((j 0 (+ j 1))) ((= j CHUNK-RES))
          (do ((i 0 (+ i 1))) ((= i CHUNK-RES))
            (let* ((a (+ i (* j VERTS)))
                   (b (+ a 1))
                   (c (+ a VERTS))
                   (d (+ c 1))
                   (t (* 6 (+ i (* j CHUNK-RES)))))
              (vector-set! triangles t a)
              (vector-set! triangles (+ t 1) b)
              (vector-set! triangles (+ t 2) c)
              (vector-set! triangles (+ t 3) b)
              (vector-set! triangles (+ t 4) d)
              (vector-set! triangles (+ t 5) c))))
        triangles))

    (define (no-pause) #f)

    ;; Water surface vertices are the same flat grid at sea level for every
    ;; chunk; only the per-vertex depth (in the colors) differs.
    (define WATER-VERTICES
      (let ((v (make-vector (* VERTS VERTS 3) SEA-LEVEL)))
        (do ((j 0 (+ j 1))) ((= j VERTS))
          (do ((i 0 (+ i 1))) ((= i VERTS))
            (let ((k (* 3 (+ i (* j VERTS)))))
              (vector-set! v k (* i CELL))
              (vector-set! v (+ k 2) (* j CELL)))))
        v))

    ;; Build mesh data for the chunk whose corner sits at world (ox, oz).
    ;; Vertices are local to the chunk. All arrays are flat float vectors
    ;; (x y z x y z ...), which Ursina's Mesh takes as-is. Returns
    ;;   (terrain-vertices terrain-normals triangles water)
    ;; where `water` is #f for dry chunks, or (water-vertices water-colors).
    ;; Water colors carry the depth below the surface (red = depth / 10),
    ;; which the water shader uses for shallow tint, transparency, and foam.
    ;; The optional `pause` thunk is called periodically during generation.
    (define (chunk-mesh-data ox oz . options)
      (let* ((pause (if (pair? options) (car options) no-pause))
             (heights (make-vector (* SAMPLES SAMPLES) 0.0))
             (vertices (make-vector (* VERTS VERTS 3) 0.0))
             (normals (make-vector (* VERTS VERTS 3) 0.0))
             (water-colors (make-vector (* VERTS VERTS 4) 0.0))
             (inv-2cell (/ 1.0 (* 2.0 CELL)))
             (wet? #f))
        ;; Sample heights, including a border so edge normals match neighbors.
        (noise-grid! heights (- ox CELL) (- oz CELL) CELL SAMPLES pause)
        (do ((k 0 (+ k 1))) ((= k (* SAMPLES SAMPLES)))
          (let ((n (vector-ref heights k)))
            (vector-set! heights k (* HEIGHT-SCALE n n))))
        (do ((j 0 (+ j 1))) ((= j VERTS))
          (let ((above (+ (* (+ j 2) SAMPLES) 1))
                (here (+ (* (+ j 1) SAMPLES) 1))
                (below (+ (* j SAMPLES) 1))
                (z (* j CELL)))
            (do ((i 0 (+ i 1))) ((= i VERTS))
              (let* ((s (+ here i))
                     (h (vector-ref heights s))
                     (dhx (* (- (vector-ref heights (+ s 1))
                                (vector-ref heights (- s 1)))
                             inv-2cell))
                     (dhz (* (- (vector-ref heights (+ above i))
                                (vector-ref heights (+ below i)))
                             inv-2cell))
                     (inv-len (/ 1.0 (sqrt (+ (* dhx dhx) 1.0 (* dhz dhz)))))
                     (depth (- SEA-LEVEL h))
                     (v (* 3 (+ i (* j VERTS))))
                     (c (* 4 (+ i (* j VERTS)))))
                (vector-set! vertices v (* i CELL))
                (vector-set! vertices (+ v 1) h)
                (vector-set! vertices (+ v 2) z)
                (vector-set! normals v (* (- dhx) inv-len))
                (vector-set! normals (+ v 1) inv-len)
                (vector-set! normals (+ v 2) (* (- dhz) inv-len))
                (when (> depth 0.0)
                  (set! wet? #t)
                  (vector-set! water-colors c (min 1.0 (* depth 0.1))))
                (vector-set! water-colors (+ c 3) 1.0)))
            (pause)))
        (list vertices
              normals
              TRIANGLES
              (and wet? (list WATER-VERTICES water-colors)))))

    (set-world-seed! 0)))
