;; Procedural terrain math: deterministic noise -> heights -> chunk mesh data.
;;
;; No engine imports here, so this library can be loaded and tested without
;; opening a window. Mesh data is returned as Scheme vectors (Python lists),
;; which Ursina's `Mesh` accepts directly. Surface coloring (grass, rock,
;; sand, snow) happens in `shaders/terrain.frag`.
;;
;; Each world is picked by a seed. The seed just shifts where in the (endless)
;; noise field we sample, so every seed is a different but repeatable world.
;;
;; Biomes (grassland, dry grassland, desert, snowy) come from two slow noise
;; fields, temperature and moisture. Each biome reshapes the same terrain
;; noise, and the shapes are blended by biome weight so borders are smooth.
;; Chunks carry the weights in their vertex colors for the shader.

(define-library (world terrain)
  (export CHUNK-SIZE
          CHUNK-RES
          SEA-LEVEL
          set-world-seed!
          terrain-height
          ground-height
          climate
          biome-weights
          biome-at
          chunk-mesh-data)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only random Random)
          (only (world state) state-set! state-ref))
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
    ;; The seed is also kept in `(world state)`, so a reload of this library
    ;; comes back up on the same world (see the last form below).
    (define SEED-X 0.0)
    (define SEED-Z 0.0)

    (define (set-world-seed! seed)
      (state-set! 'seed seed)
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

    ;; Terrain noise in [0, 1) at one world (x, z). `noise-grid!` below
    ;; computes the same values for a whole grid at once; keep the two in step.
    (define (terrain-noise x z)
      (let ((x (* (+ x SEED-X) BASE-FREQUENCY))
            (z (* (+ z SEED-Z) BASE-FREQUENCY)))
        (let loop ((i 0) (freq 1.0) (amp 0.5) (sum 0.0))
          (if (= i OCTAVES)
              (/ sum FBM-NORM)
              (loop (+ i 1)
                    (* freq 2.0)
                    (* amp 0.5)
                    (+ sum (* amp (value-noise (* x freq) (* z freq)))))))))

    ;; --- biomes ------------------------------------------------------------
    ;;
    ;; Temperature and moisture are sampled at warped coordinates, so borders
    ;; wander instead of tracing smooth blobs. A long stretch of one climate
    ;; makes one big biome; a brief dip makes a small one.
    ;;
    ;; Weights are (desert dry-grassland snowy). Grassland is whatever is left,
    ;; so the four always sum to 1.

    (define CLIMATE-FREQUENCY (/ 1.0 1000.0)) ; lower -> bigger biomes
    (define WARP-FREQUENCY (/ 1.0 400.0))
    (define WARP-AMOUNT 500.0)                ; borders shift up to half this
    ;; Hot places are drier: moisture is lowered by this much per unit of
    ;; temperature above 0.5, so deserts sit in the heat and not by the snow.
    (define HEAT-DRYING 0.6)
    ;; Each blend runs between two values: (start end).
    ;; Roughly 40% grassland, 15% dry grassland, 22% desert, 22% snowy.
    (define COLD (list 0.37 0.43))       ; colder than this -> snowy
    (define HOT (list 0.50 0.56))        ; deserts need at least this much heat
    (define ARID (list 0.40 0.46))       ; drier than this -> desert
    (define SEMI-ARID (list 0.47 0.53))  ; drier than this -> dry grassland
    ;; Biome weights are computed on a grid this coarse and blended between.
    (define CLIMATE-STEP 16.0)

    ;; Shapes, applied to the terrain noise `n`. The base is the original
    ;; terrain: flat lowlands with occasional steep hills.
    (define DUNE-HEIGHT 3.0)
    (define DUNE-FREQUENCY 0.09)
    (define (grassland-height base) base)
    (define (dry-grassland-height base) (+ (* 0.55 base) 3.0))
    (define (desert-height base n x z)
      (let ((dune (- 1.0 (abs (sin (+ (* DUNE-FREQUENCY (+ (* 0.8 x) (* 0.6 z)))
                                       (* 6.0 n)))))))
        (+ SEA-LEVEL 1.5 (* 0.35 base) (* DUNE-HEIGHT dune))))
    (define (snowy-height base) (+ (* 1.5 base) 2.0))

    ;; Blend of the shapes by biome weight. Shapes with no weight are skipped;
    ;; most points are entirely one biome.
    (define (biome-height n desert dry snowy x z)
      (let ((base (* HEIGHT-SCALE n n))
            (grass (- 1.0 desert dry snowy)))
        (+ (if (> grass 0.0) (* grass (grassland-height base)) 0.0)
           (if (> dry 0.0) (* dry (dry-grassland-height base)) 0.0)
           (if (> desert 0.0) (* desert (desert-height base n x z)) 0.0)
           (if (> snowy 0.0) (* snowy (snowy-height base)) 0.0))))

    ;; Value-noise fbm in [0, 1) with `octaves` octaves.
    (define (fbm x z octaves)
      (let loop ((i 0) (freq 1.0) (amp 0.5) (sum 0.0) (norm 0.0))
        (if (= i octaves)
            (/ sum norm)
            (loop (+ i 1)
                  (* freq 2.0)
                  (* amp 0.5)
                  (+ sum (* amp (value-noise (* x freq) (* z freq))))
                  (+ norm amp)))))

    ;; 0 below the range's start, 1 past its end, smooth in between.
    (define (ramp range x)
      (let ((lo (car range)) (hi (cadr range)))
        (smooth (max 0.0 (min 1.0 (/ (- x lo) (- hi lo)))))))

    ;; REPL: (climate x z) -> (temperature moisture), each roughly 0 to 1.
    (define (climate x z)
      (let* ((sx (+ x SEED-X))
             (sz (+ z SEED-Z))
             (qx (* sx WARP-FREQUENCY))
             (qz (* sz WARP-FREQUENCY))
             (wx (+ sx (* WARP-AMOUNT (- (fbm qx qz 2) 0.5))))
             (wz (+ sz (* WARP-AMOUNT (- (fbm (+ qx 31.7) (+ qz 47.3) 2) 0.5))))
             (cx (* wx CLIMATE-FREQUENCY))
             (cz (* wz CLIMATE-FREQUENCY)))
        (list (fbm (+ cx 113.1) (+ cz 71.9) 3)
              (fbm (+ cx 457.3) (+ cz 291.1) 3))))

    ;; Unblended (desert dry-grassland snowy) weights at one point. Arid
    ;; ground that isn't hot is dry grassland, which keeps deserts from
    ;; touching snow.
    (define (climate-weights x z)
      (let* ((c (climate x z))
             (t (car c))
             (m (- (cadr c) (* HEAT-DRYING (- t 0.5))))
             (warm (ramp COLD t))
             (hot (ramp HOT t))
             (arid (- 1.0 (ramp ARID m)))
             (semi-arid (* (ramp ARID m) (- 1.0 (ramp SEMI-ARID m)))))
        (list (* warm arid hot)
              (* warm (+ (* arid (- 1.0 hot)) semi-arid))
              (- 1.0 warm))))

    (define (bilerp a b c d u v)
      (let ((top (+ a (* (- b a) u)))
            (bottom (+ c (* (- d c) u))))
        (+ top (* (- bottom top) v))))

    ;; Biome weights at (x, z), blended from the CLIMATE-STEP grid the same
    ;; way chunks do it, so the ground you stand on matches the mesh.
    (define (biome-weights x z)
      (let* ((fx (/ x CLIMATE-STEP))
             (fz (/ z CLIMATE-STEP))
             (ix (floor fx))
             (iz (floor fz))
             (u (- fx ix))
             (v (- fz iz))
             (gx (* ix CLIMATE-STEP))
             (gz (* iz CLIMATE-STEP))
             (a (climate-weights gx gz))
             (b (climate-weights (+ gx CLIMATE-STEP) gz))
             (c (climate-weights gx (+ gz CLIMATE-STEP)))
             (d (climate-weights (+ gx CLIMATE-STEP) (+ gz CLIMATE-STEP))))
        (map (lambda (a b c d) (bilerp a b c d u v)) a b c d)))

    ;; REPL: (biome-at x z) -> each biome's share of the ground there,
    ;; rounded to two places.
    (define (biome-at x z)
      (let* ((w (biome-weights x z))
             (desert (car w))
             (dry (cadr w))
             (snowy (list-ref w 2))
             (share (lambda (v) (/ (round (* (max v 0.0) 100.0)) 100.0))))
        (list (cons "grassland" (share (- 1.0 desert dry snowy)))
              (cons "dry grassland" (share dry))
              (cons "desert" (share desert))
              (cons "snowy" (share snowy)))))

    ;; Terrain height at one world (x, z).
    (define (terrain-height x z)
      (let ((w (biome-weights x z)))
        (biome-height (terrain-noise x z) (car w) (cadr w) (list-ref w 2) x z)))

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

    ;; Biome weights for a count x count grid (row-major) whose first sample
    ;; is world (x0, z0), as three vectors: (desert dry-grassland snowy).
    ;; Climate is evaluated once per CLIMATE-STEP corner and blended, exactly
    ;; like `biome-weights`.
    (define (biome-grid x0 z0 step count)
      (let* ((last (* step (- count 1)))
             (gx0 (floor (/ x0 CLIMATE-STEP)))
             (gz0 (floor (/ z0 CLIMATE-STEP)))
             (gw (exact (+ (- (floor (/ (+ x0 last) CLIMATE-STEP)) gx0) 2)))
             (gh (exact (+ (- (floor (/ (+ z0 last) CLIMATE-STEP)) gz0) 2)))
             (corners (make-vector (* gw gh) #f))
             (desert (make-vector (* count count) 0.0))
             (dry (make-vector (* count count) 0.0))
             (snowy (make-vector (* count count) 0.0)))
        (do ((j 0 (+ j 1))) ((= j gh))
          (do ((i 0 (+ i 1))) ((= i gw))
            (vector-set! corners (+ i (* j gw))
                         (climate-weights (* (+ gx0 i) CLIMATE-STEP)
                                          (* (+ gz0 j) CLIMATE-STEP)))))
        (if (all-equal? corners)
            ;; The whole grid is one climate, so there's nothing to blend.
            (let ((w (vector-ref corners 0)))
              (vector-fill! desert (car w))
              (vector-fill! dry (cadr w))
              (vector-fill! snowy (list-ref w 2)))
            (blend-corners! corners gw gx0 gz0 x0 z0 step count desert dry snowy))
        (list desert dry snowy)))

    (define (all-equal? v)
      (let ((first (vector-ref v 0)))
        (let loop ((i 1))
          (cond ((= i (vector-length v)) #t)
                ((equal? (vector-ref v i) first) (loop (+ i 1)))
                (else #f)))))

    ;; Bilinear blend of the corner weights into each grid sample, one biome
    ;; at a time. A biome with no weight at any corner is just zeros.
    (define (blend-corners! corners gw gx0 gz0 x0 z0 step count desert dry snowy)
      (let ((cols (make-vector count 0))
            (us (make-vector count 0.0)))
        (do ((i 0 (+ i 1))) ((= i count))
          (let* ((fx (- (/ (+ x0 (* i step)) CLIMATE-STEP) gx0))
                 (cx (exact (floor fx))))
            (vector-set! cols i cx)
            (vector-set! us i (- fx cx))))
        (for-each
          (lambda (out pick)
            (let ((w (vector-map pick corners)))
              (if (all-equal? w)
                  (vector-fill! out (vector-ref w 0))
                  (do ((j 0 (+ j 1))) ((= j count))
                    (let* ((fz (- (/ (+ z0 (* j step)) CLIMATE-STEP) gz0))
                           (cz (exact (floor fz)))
                           (v (- fz cz))
                           (row (* cz gw))
                           (s0 (* j count)))
                      (do ((i 0 (+ i 1))) ((= i count))
                        (let ((k (+ row (vector-ref cols i))))
                          (vector-set! out (+ s0 i)
                                       (bilerp (vector-ref w k)
                                               (vector-ref w (+ k 1))
                                               (vector-ref w (+ k gw))
                                               (vector-ref w (+ k gw 1))
                                               (vector-ref us i)
                                               v)))))))))
          (list desert dry snowy)
          (list car cadr (lambda (w) (list-ref w 2))))))

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
    ;;   (terrain-vertices terrain-normals triangles water terrain-colors)
    ;; where `water` is #f for dry chunks, or (water-vertices water-colors).
    ;; Water colors carry the depth below the surface (red = depth / 10),
    ;; which the water shader uses for shallow tint, transparency, and foam.
    ;; Terrain colors carry the biome weights: red desert, green dry
    ;; grassland, blue snowy (grassland is the rest).
    ;; The optional `pause` thunk is called periodically during generation.
    (define (chunk-mesh-data ox oz . options)
      (let* ((pause (if (pair? options) (car options) no-pause))
             (x0 (- ox CELL))
             (z0 (- oz CELL))
             (heights (make-vector (* SAMPLES SAMPLES) 0.0))
             (vertices (make-vector (* VERTS VERTS 3) 0.0))
             (normals (make-vector (* VERTS VERTS 3) 0.0))
             (water-colors (make-vector (* VERTS VERTS 4) 0.0))
             (colors (make-vector (* VERTS VERTS 4) 1.0))
             (inv-2cell (/ 1.0 (* 2.0 CELL)))
             (wet? #f))
        ;; Sample heights, including a border so edge normals match neighbors.
        (noise-grid! heights x0 z0 CELL SAMPLES pause)
        (let* ((biomes (biome-grid x0 z0 CELL SAMPLES))
               (desert (car biomes))
               (dry (cadr biomes))
               (snowy (list-ref biomes 2)))
          (pause)
          (do ((j 0 (+ j 1))) ((= j SAMPLES))
            (let ((z (+ z0 (* j CELL))))
              (do ((i 0 (+ i 1))) ((= i SAMPLES))
                (let ((k (+ i (* j SAMPLES))))
                  (vector-set! heights k
                               (biome-height (vector-ref heights k)
                                             (vector-ref desert k)
                                             (vector-ref dry k)
                                             (vector-ref snowy k)
                                             (+ x0 (* i CELL))
                                             z))))))
          (pause)
          ;; Vertex (i, j) is sample (i + 1, j + 1), past the border.
          (do ((j 0 (+ j 1))) ((= j VERTS))
            (do ((i 0 (+ i 1))) ((= i VERTS))
              (let ((s (+ (+ i 1) (* (+ j 1) SAMPLES)))
                    (c (* 4 (+ i (* j VERTS)))))
                (vector-set! colors c (vector-ref desert s))
                (vector-set! colors (+ c 1) (vector-ref dry s))
                (vector-set! colors (+ c 2) (vector-ref snowy s))))))
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
              (and wet? (list WATER-VERTICES water-colors))
              colors)))

    ;; Runs on every load, including hot reloads: restores the current seed.
    (set-world-seed! (state-ref 'seed))))
