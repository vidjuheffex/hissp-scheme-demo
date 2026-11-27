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
;; Chunks carry the weights in their vertex colors for the shader, and how
;; wooded the ground is in their alpha (see forests below). Rivers, canyons
;; and cliffs are cut into the blended height afterwards (see below).

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
          forest-density
          channel-distance
          cliffiness
          RIVER-WIDTH
          chunk-mesh-data
          chunk-grass
          hash2
          value-noise
          seed-offset)
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

    ;; The current (SEED-X SEED-Z). Other libraries call this rather than
    ;; importing the variables, which would keep their values from import time.
    (define (seed-offset) (list SEED-X SEED-Z))

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
    ;; so the four always sum to 1. A fourth value, wet (0 to 1), isn't a
    ;; biome: it's how damp the ground is, and grows denser forests.

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
    (define WET (list 0.60 0.75))        ; wetter than this -> denser forest
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

    ;; Unblended (desert dry-grassland snowy wet) weights at one point. Arid
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
              (- 1.0 warm)
              (ramp WET m))))

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
        (shape-land (biome-height (terrain-noise x z) (car w) (cadr w) (list-ref w 2) x z)
                    (features x z) (car w) (cadr w))))

    ;; Walkable height: terrain, but never below the water surface.
    (define (ground-height x z)
      (max SEA-LEVEL (terrain-height x z)))

    ;; --- rivers, canyons and cliffs ----------------------------------------
    ;;
    ;; One carver cuts every channel. Its line is where a slow, warped noise
    ;; crosses 0.5; those contours run on and on, so a channel reaches the
    ;; sea or low ground rather than stopping. Across low ground the cut is a
    ;; wide valley with a river in it, its bed just below the sea so the
    ;; sea's water fills it, shallow enough to wade. Where the land stands
    ;; higher the same cut drops over a meter or two instead: a canyon with
    ;; sheer walls and the river at the bottom. In desert and dry grassland
    ;; the bed stays above the sea, a dry wash.
    ;;
    ;; In cliff country (a rare, slow region noise) hills, and desert flats
    ;; as mesas, rise in sheer steps instead of slopes. The steps go on
    ;; before the carve, so channels cut through them and rivers stay wet.
    ;;
    ;; These noises are slow, so they're sampled on a FEATURE-STEP lattice
    ;; and blended. Chunks and `terrain-height` share the lattice, so the
    ;; ground you walk on matches the mesh.

    (define FEATURE-STEP 8.0)
    (define RIVER-FREQUENCY (/ 1.0 700.0))
    (define RIVER-WARP-FREQUENCY (/ 1.0 350.0))
    (define RIVER-WARP 300.0)
    (define RIVER-METERS 1000.0)          ; meters from the line per unit the noise is off 0.5, roughly
    (define RIVER-WIDTH 4.0)              ; half-width of the water
    (define RIVER-DEPTH 0.75)             ; bed below the sea mid-river: wadeable
    (define WASH-FLOOR 0.4)               ; dry beds' height above the sea
    (define BANK-HEIGHT 0.3)              ; banks above the sea at the water's edge
    (define BANK-SLOPE 0.12)              ; rise per meter of a valley's sides
    (define CANYON-RISE (list 8.0 16.0))  ; land above the sea, from valley to canyon
    (define CANYON-FLOOR 6.0)             ; dry floor each side of a canyon's river
    (define CANYON-WALL 10.0)             ; rise per meter of a canyon's walls
    (define VALLEY-ROUNDING 3.0)          ; meters smoothed where a valley side meets the land

    (define CLIFF-REGION-FREQUENCY (/ 1.0 1500.0))
    (define CLIFF-REGIONS (list 0.78 0.85)) ; region noise ramp from none to cliff country
    (define CLIFF-HILLS (list 8.0 14.0))  ; land above the sea, from no cliffs to cliffs
    (define CLIFF-FREQUENCY (/ 1.0 250.0))
    (define CLIFF-STEPS 5.0)              ; steps across the noise's range
    (define CLIFF-STEP 6.0)               ; meters per step
    (define CLIFF-EDGE 0.012)             ; half the share of a step's noise it rises over

    ;; #(channel cliff-region cliff-steps) noises at one lattice point.
    (define (feature-noises x z)
      (let* ((sx (+ x SEED-X))
             (sz (+ z SEED-Z))
             (qx (* sx RIVER-WARP-FREQUENCY))
             (qz (* sz RIVER-WARP-FREQUENCY))
             (wx (+ sx (* RIVER-WARP (- (value-noise (+ qx 71.3) (+ qz 19.1)) 0.5))))
             (wz (+ sz (* RIVER-WARP (- (value-noise (+ qx 13.7) (+ qz 83.9)) 0.5)))))
        (vector (fbm (+ (* wx RIVER-FREQUENCY) 5.5) (+ (* wz RIVER-FREQUENCY) 9.7) 2)
                (value-noise (+ (* sx CLIFF-REGION-FREQUENCY) 41.9)
                             (+ (* sz CLIFF-REGION-FREQUENCY) 3.3))
                (fbm (+ (* sx CLIFF-FREQUENCY) 27.1) (+ (* sz CLIFF-FREQUENCY) 61.7) 2))))

    (define (direct-corner ix iz)
      (feature-noises (* ix FEATURE-STEP) (* iz FEATURE-STEP)))

    ;; Where (x, z) falls in the lattice: four values, the lattice cell
    ;; (ix iz) and how far across it (u v).
    (define (lattice-cell x z)
      (let* ((fx (/ x FEATURE-STEP))
             (fz (/ z FEATURE-STEP))
             (ix (exact (floor fx)))
             (iz (exact (floor fz))))
        (values ix iz (- fx ix) (- fz iz))))

    (define (blend-corners a b c d u v)
      (vector (bilerp (vector-ref a 0) (vector-ref b 0) (vector-ref c 0) (vector-ref d 0) u v)
              (bilerp (vector-ref a 1) (vector-ref b 1) (vector-ref c 1) (vector-ref d 1) u v)
              (bilerp (vector-ref a 2) (vector-ref b 2) (vector-ref c 2) (vector-ref d 2) u v)))

    ;; The feature noises at (x, z): #(channel cliff-region cliff-steps).
    (define (features x z)
      (let-values (((ix iz u v) (lattice-cell x z)))
        (blend-corners (direct-corner ix iz) (direct-corner (+ ix 1) iz)
                       (direct-corner ix (+ iz 1)) (direct-corner (+ ix 1) (+ iz 1))
                       u v)))

    ;; `features` for a count x count grid (row-major) whose first sample is
    ;; world (x0, z0), as one vector of feature vectors. Each lattice point
    ;; and each column's cell are worked out once, and the arithmetic is
    ;; `features`' own, so the two agree exactly.
    (define (feature-grid x0 z0 step count)
      (let*-values (((ix0 iz0 u0 v0) (lattice-cell x0 z0))
                    ((columns) (make-vector count #f))
                    ((rows) (make-vector count #f))
                    ((n) 0))
        (do ((i 0 (+ i 1))) ((= i count))
          (let-values (((ix iz u v) (lattice-cell (+ x0 (* i step)) (+ z0 (* i step)))))
            (vector-set! columns i (cons (- ix ix0) u))
            (vector-set! rows i (cons (- iz iz0) v))
            (set! n (max n (+ 2 (- ix ix0)) (+ 2 (- iz iz0))))))
        (let ((lattice (make-vector (* n n) #f))
              (out (make-vector (* count count) #f)))
          (do ((j 0 (+ j 1))) ((= j n))
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! lattice (+ i (* j n)) (direct-corner (+ ix0 i) (+ iz0 j)))))
          (do ((j 0 (+ j 1))) ((= j count))
            (let* ((row (vector-ref rows j))
                   (base (* (car row) n))
                   (v (cdr row)))
              (do ((i 0 (+ i 1))) ((= i count))
                (let* ((column (vector-ref columns i))
                       (k (+ base (car column))))
                  (vector-set! out (+ i (* j count))
                               (blend-corners (vector-ref lattice k)
                                              (vector-ref lattice (+ k 1))
                                              (vector-ref lattice (+ k n))
                                              (vector-ref lattice (+ k n 1))
                                              (cdr column) v))))))
          out)))

    ;; `ramp` from `lo` to `hi`, without the list: these run for every sample.
    (define (ramp-between lo hi x)
      (cond ((<= x lo) 0.0)
            ((>= x hi) 1.0)
            (else (smooth (/ (- x lo) (- hi lo))))))

    (define (smooth-min a b k)
      (let ((low (if (< a b) a b)))
        (if (<= k 0.0)
            low
            (let ((e (- k (abs (- a b)))))
              (if (> e 0.0) (- low (/ (* e e) (* 4.0 k))) low)))))

    ;; How much of cliff country's stepping applies at height `h`.
    (define (cliff-amount h desert region)
      (if (<= region (car CLIFF-REGIONS))
          0.0
          (let ((hills (ramp-between (car CLIFF-HILLS) (cadr CLIFF-HILLS) (- h SEA-LEVEL))))
            (* (ramp-between (car CLIFF-REGIONS) (cadr CLIFF-REGIONS) region)
               (if (> desert hills) desert hills)))))

    (define (cliff-steps h desert region s)
      (let ((amount (cliff-amount h desert region)))
        (if (<= amount 0.0)
            h
            (let* ((t (* s CLIFF-STEPS))
                   (k (floor t)))
              (+ h (* amount CLIFF-STEP
                      (+ k (ramp-between (- 0.5 CLIFF-EDGE) (+ 0.5 CLIFF-EDGE) (- t k)))))))))

    ;; Meters from the nearest channel's line, for channel noise `c`.
    (define (channel-meters c) (* RIVER-METERS (abs (- c 0.5))))

    ;; Lowest a channel `dist` meters away can cut, whatever the land: past
    ;; this, `carve` leaves the height alone.
    (define (lowest-cut dist)
      (let ((s (- dist RIVER-WIDTH)))
        (if (< s CANYON-FLOOR)
            (+ SEA-LEVEL BANK-HEIGHT (* 0.05 s))
            (+ SEA-LEVEL BANK-HEIGHT (* 0.05 CANYON-FLOOR) (* BANK-SLOPE (- s CANYON-FLOOR))))))

    ;; Height `h` cut down by a channel `dist` meters away; `dry` (0 to 1)
    ;; lifts the bed out of the water.
    (define (carve h dist dry)
      (if (and (> dist RIVER-WIDTH) (> (lowest-cut dist) (+ h VALLEY-ROUNDING)))
          h
          (let* ((canyon (ramp-between (car CANYON-RISE) (cadr CANYON-RISE) (- h SEA-LEVEL)))
                 (floor (lerp (- SEA-LEVEL RIVER-DEPTH) (+ SEA-LEVEL WASH-FLOOR) dry))
                 (edge (if (> floor (+ SEA-LEVEL BANK-HEIGHT)) floor (+ SEA-LEVEL BANK-HEIGHT)))
                 (valley (if (< dist RIVER-WIDTH)
                             (lerp floor edge (smooth (/ dist RIVER-WIDTH)))
                             (let ((s (- dist RIVER-WIDTH))
                                   (flat (* canyon CANYON-FLOOR))
                                   (slope (lerp BANK-SLOPE CANYON-WALL canyon)))
                               (if (< s flat)
                                   (+ edge (* 0.05 s))
                                   (+ edge (* 0.05 flat) (* slope (- s flat))))))))
            (smooth-min h valley (* VALLEY-ROUNDING (- 1.0 canyon))))))

    ;; Biome height `h` with cliffs and channels, for feature noises `f`.
    (define (shape-land h f desert dry)
      (let ((dryness (+ desert dry)))
        (carve (cliff-steps h desert (vector-ref f 1) (vector-ref f 2))
               (channel-meters (vector-ref f 0))
               (if (> dryness 1.0) 1.0 dryness))))

    ;; REPL and the game: meters from the nearest channel's line, and how
    ;; much cliff country's stepping applies, at (x, z).
    (define (channel-distance x z)
      (channel-meters (vector-ref (features x z) 0)))

    (define (cliffiness x z)
      (let ((w (biome-weights x z)))
        (cliff-amount (terrain-height x z) (car w) (vector-ref (features x z) 1))))

    ;; --- forests -----------------------------------------------------------
    ;;
    ;; Not a biome: woods grow in grassland and the snow where a slow grove
    ;; noise is high, from open meadow to forest. Wet ground lowers the bar,
    ;; so its woods are bigger and run together, and grows them denser.
    ;; `woods` is that stand density, 0 open ground to 1 the densest wet
    ;; forest, before the biome: the trees, the forest floor and its grass
    ;; all scale it by the share of grassland and snow.

    (define GROVE-FREQUENCY (/ 1.0 90.0))
    (define GROVES (list 0.35 0.65))     ; grove noise ramp from meadow to forest
    (define WET-GROVES 0.22)             ; wet ground starts the ramp this much lower
    (define DRY-WOODS 0.4)               ; densest stand where the ground isn't wet
    (define WOODS-TOP (list 27.0 31.0))  ; the tree line
    (define WOODS-SHORE (list 1.2 2.0))  ; meters above the sea, from none to full

    (define (woods x z h wet)
      (let ((shift (* WET-GROVES wet)))
        (* (ramp-between (- (car GROVES) shift) (- (cadr GROVES) shift)
                         (value-noise (* (+ x SEED-X) GROVE-FREQUENCY)
                                      (* (+ z SEED-Z) GROVE-FREQUENCY)))
           (+ DRY-WOODS (* (- 1.0 DRY-WOODS) wet))
           (- 1.0 (ramp-between (car WOODS-TOP) (cadr WOODS-TOP) h))
           (ramp-between (+ SEA-LEVEL (car WOODS-SHORE)) (+ SEA-LEVEL (cadr WOODS-SHORE)) h))))

    ;; REPL: (forest-density x z) -> how wooded the ground is, 0 to 1,
    ;; counting the biome.
    (define (forest-density x z)
      (let ((w (biome-weights x z)))
        (* (woods x z (terrain-height x z) (list-ref w 3))
           (max 0.0 (- 1.0 (car w) (cadr w))))))

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
    ;; spaced `step` apart, return three values: first-cell, cell-offsets and
    ;; weights, where cell-offsets[i] is the sample's lattice cell relative
    ;; to first-cell.
    (define (axis-cells start step count scale)
      (let* ((first (floor (* start scale)))
             (offsets (make-vector count 0))
             (weights (make-vector count 0.0)))
        (do ((i 0 (+ i 1))) ((= i count))
          (let* ((p (* (+ start (* i step)) scale))
                 (cell (floor p)))
            (vector-set! offsets i (exact (- cell first)))
            (vector-set! weights i (smooth (- p cell)))))
        (values first offsets weights)))

    ;; Fill `out` (count x count, row-major) with fbm noise in [0, 1) for a grid
    ;; whose first sample is world (x0, z0). Calls `pause` between rows so a
    ;; worker thread can let the render thread run.
    (define (noise-grid! out x0 z0 step count pause)
      (vector-fill! out 0.0)
      (let octave ((o 0) (freq BASE-FREQUENCY) (amp (/ 0.5 FBM-NORM)))
        (when (< o OCTAVES)
          (let*-values (((cx0 col-cells col-weights) (axis-cells (+ x0 SEED-X) step count freq))
                        ((cz0 row-cells row-weights) (axis-cells (+ z0 SEED-Z) step count freq))
                        ;; Lattice points needed, +1 for each cell's far corner.
                        ((width) (+ (vector-ref col-cells (- count 1)) 2))
                        ((height) (+ (vector-ref row-cells (- count 1)) 2))
                        ((lattice) (make-vector (* width height) 0.0))
                        ((blended) (make-vector width 0.0)))
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
    ;; is world (x0, z0), as four vectors: (desert dry-grassland snowy wet).
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
             (snowy (make-vector (* count count) 0.0))
             (wet (make-vector (* count count) 0.0)))
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
              (vector-fill! snowy (list-ref w 2))
              (vector-fill! wet (list-ref w 3)))
            (blend-corners! corners gw gx0 gz0 x0 z0 step count desert dry snowy wet))
        (list desert dry snowy wet)))

    (define (all-equal? v)
      (let ((first (vector-ref v 0)))
        (let loop ((i 1))
          (cond ((= i (vector-length v)) #t)
                ((equal? (vector-ref v i) first) (loop (+ i 1)))
                (else #f)))))

    ;; Bilinear blend of the corner weights into each grid sample, one biome
    ;; at a time. A biome with no weight at any corner is just zeros.
    (define (blend-corners! corners gw gx0 gz0 x0 z0 step count desert dry snowy wet)
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
          (list desert dry snowy wet)
          (list car cadr (lambda (w) (list-ref w 2)) (lambda (w) (list-ref w 3))))))

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

    ;; --- grass clumps ----------------------------------------------------
    ;;
    ;; Candidate spots sit GRASS-SPACING apart, jittered. Each keeps a clump
    ;; with a chance set by the biome (only grassland and dry grassland grow
    ;; grass) times a slow "meadow" noise, so grass comes in patches with
    ;; bare ground between. A clump is two crossed quads showing one sprite
    ;; of `assets/textures/grass_clumps.png`: 0 short, 1 tall, 2 flowers,
    ;; 3 dry, the wildflowers 4 daisies, 5 spikes, 6 poppies, 7 desert, and
    ;; 8 ferns. Under the trees (`woods`) grass and wildflowers thin out and
    ;; ferns grow in patches instead.
    ;;
    ;; Wildflowers come in drifts of their own (`FLOWERS` noise), among the
    ;; grass and, after rain, out in the desert. Which kind a drift is
    ;; follows another, slower noise. The shader opens or sinks each
    ;; wildflower clump by how far its kind is into bloom (see `blooms` in
    ;; (world weather)): every clump has its own threshold, so a drift fills
    ;; in gradually, and its own petal color from the kind's palette.

    (define GRASS-SPACING 1.6)
    (define GRASS-CHANCE 0.85)         ; in full grassland, mid-meadow
    (define DRY-GRASS-CHANCE 0.6)
    (define MEADOW-FREQUENCY (/ 1.0 40.0))
    (define MEADOW (list 0.25 0.5))    ; meadow noise ramp from bare to full
    (define GRASS-SHORE 1.6)           ; none this close above the sea (sand)
    (define GRASS-TOP 25.0)            ; none from the rock band up
    (define GRASS-MAX-GRADIENT 0.6)    ; none on slopes steeper than this
    (define CLUMP-SINK 0.15)           ; push bases into the ground on slopes
    (define CLUMPS-PER-SIDE (exact (round (/ CHUNK-SIZE GRASS-SPACING))))
    (define MAX-CLUMPS (* CLUMPS-PER-SIDE CLUMPS-PER-SIDE))
    (define SPRITES 9.0)
    (define FOREST-FLOOR (list 0.25 0.7)) ; woods ramp from open ground to forest floor
    (define FOREST-GRASS 0.15)         ; share of the grass left on the forest floor
    (define FERN-CHANCE 0.65)          ; on the forest floor, mid-patch
    (define FERN-FREQUENCY (/ 1.0 14.0))
    (define FERNS (list 0.35 0.6))     ; fern patch noise ramp from none to thick
    (define FLOWER-FREQUENCY (/ 1.0 18.0))
    (define FLOWERS (list 0.45 0.65))  ; drift noise ramp from none to thick
    (define FLOWER-CHANCE 0.8)         ; in grassland, mid-drift
    (define DRY-FLOWER-CHANCE 0.45)
    (define DESERT-FLOWER-CHANCE 0.6)
    (define FLOWER-KIND-FREQUENCY (/ 1.0 70.0))
    (define UV-INSET 0.004)            ; keeps sampling off the neighbor sprite

    ;; A spot's random numbers: stream k of spot (gi, gj).
    (define (spot-random gi gj k)
      (hash2 (+ gi (* 17 k)) (- gj (* 31 k))))

    ;; Another number in [0, 1) derived from `r`, for traits that needn't be
    ;; independent of each other.
    (define (scramble r factor)
      (let ((s (* r factor)))
        (- s (floor s))))

    ;; Which sprite a kept clump shows, given its share of dry grass.
    (define (clump-sprite dry-share pick flavor)
      (cond ((< pick dry-share) 3)
            ((< flavor 0.55) 0)
            ((< flavor 0.82) 1)
            (else 2)))

    (define SPRITE-HEIGHTS (vector 1.0 1.7 1.25 1.15 0.85 1.15 0.9 0.7 1.15))

    ;; Per-sprite color multiplier, so clumps read against the ground
    ;; texture they stand on (the sprites alone are darker than it).
    (define SPRITE-TINTS
      (vector (list 1.1 1.18 0.85) (list 1.0 1.08 0.85) (list 1.08 1.15 1.0)
              (list 1.12 1.1 0.98) (list 1.08 1.15 0.9) (list 1.05 1.12 0.9)
              (list 1.0 1.08 0.9) (list 1.1 1.08 0.95) (list 1.0 1.1 0.9)))

    ;; Which wildflower a drift grows, from the slow kind noise `k` and the
    ;; share of dry grassland: poppies like it dry.
    (define (flower-sprite k dry)
      (cond ((< k (- 0.4 (* 0.3 dry))) 4)
            ((< k (- 0.7 (* 0.4 dry))) 5)
            (else 6)))

    ;; Write clump number `n` into `mesh`: two crossed quads standing on
    ;; (x, y, z), spanning +-(dx, dz) sideways and `height` tall. A
    ;; wildflower's `hue` picks its petal color and `opens` is how far into
    ;; bloom its kind must be for it to show (-1 always, for grass).
    (define (put-clump! mesh n x y z dx dz height sprite r g b hue opens)
      (let ((top (+ y height))
            (u0 (+ (/ sprite SPRITES) UV-INSET))
            (u1 (- (/ (+ sprite 1) SPRITES) UV-INSET))
            (v (* 8 n)))
        (vector-copy! (car mesh) (* 24 n)
                      (vector (- x dx) y (- z dz) (+ x dx) y (+ z dz)
                              (+ x dx) top (+ z dz) (- x dx) top (- z dz)
                              (+ x dz) y (- z dx) (- x dz) y (+ z dx)
                              (- x dz) top (+ z dx) (+ x dz) top (- z dx)))
        (vector-copy! (cadr mesh) (* 24 n)
                      (vector hue 0.0 opens hue 0.0 opens hue height opens hue height opens
                              hue 0.0 opens hue 0.0 opens hue height opens hue height opens))
        (vector-copy! (list-ref mesh 2) (* 16 n)
                      (vector u0 0.0 u1 0.0 u1 1.0 u0 1.0 u0 0.0 u1 0.0 u1 1.0 u0 1.0))
        (vector-copy! (list-ref mesh 3) (* 32 n)
                      (vector r g b 1.0 r g b 1.0 r g b 1.0 r g b 1.0
                              r g b 1.0 r g b 1.0 r g b 1.0 r g b 1.0))
        (vector-copy! (list-ref mesh 4) (* 12 n)
                      (vector v (+ v 1) (+ v 2) v (+ v 2) (+ v 3)
                              (+ v 4) (+ v 5) (+ v 6) (+ v 4) (+ v 6) (+ v 7)))))

    ;; Grass clump mesh data for the chunk at world (ox, oz), from the
    ;; terrain vertices and colors `chunk-mesh-data` made for it. Returns
    ;;   (vertices normals uvs colors triangles), or #f if nothing grows.
    ;; Normals don't hold a direction: their y is the vertex's height above
    ;; the ground (0 at the bottom). The grass shader uses it for wind sway
    ;; and for sinking clumps into the ground at the edge of the grass range,
    ;; or out of bloom. x is a wildflower's hue and z its bloom threshold.
    ;; Heights follow the same two triangles per cell as the terrain mesh.
    (define (chunk-grass ox oz terrain biomes pause)
      (let ((mesh (list (make-vector (* MAX-CLUMPS 24) 0.0)
                        (make-vector (* MAX-CLUMPS 24) 0.0)
                        (make-vector (* MAX-CLUMPS 16) 0.0)
                        (make-vector (* MAX-CLUMPS 32) 1.0)
                        (make-vector (* MAX-CLUMPS 12) 0)))
            (gi0 (exact (floor (/ (+ ox SEED-X) GRASS-SPACING))))
            (gj0 (exact (floor (/ (+ oz SEED-Z) GRASS-SPACING))))
            (count 0))
        (do ((j 0 (+ j 1))) ((= j CLUMPS-PER-SIDE))
          (do ((i 0 (+ i 1))) ((= i CLUMPS-PER-SIDE))
            (let* ((gi (+ gi0 i))
                   (gj (+ gj0 j))
                   (jitter (spot-random gi gj 1))
                   (fx (/ (* GRASS-SPACING (+ i jitter)) CELL))
                   (fz (/ (* GRASS-SPACING (+ j (scramble jitter 57.13))) CELL))
                   (ci (exact (floor fx)))
                   (cj (exact (floor fz)))
                   (c (* 4 (+ ci (* cj VERTS))))
                   (w-desert (vector-ref biomes c))
                   (w-dry (vector-ref biomes (+ c 1)))
                   (w-grass (max 0.0 (- 1.0 w-desert w-dry (vector-ref biomes (+ c 2)))))
                   (canopy (ramp FOREST-FLOOR (vector-ref biomes (+ c 3))))
                   (open (- 1.0 (* (- 1.0 FOREST-GRASS) canopy)))
                   (lush (+ (* GRASS-CHANCE w-grass open) (* DRY-GRASS-CHANCE w-dry)))
                   (flowery (+ (* FLOWER-CHANCE w-grass open) (* DRY-FLOWER-CHANCE w-dry)))
                   (ferny (* FERN-CHANCE w-grass canopy))
                   (desert-flowery (* DESERT-FLOWER-CHANCE w-desert)))
              (when (> (+ lush desert-flowery ferny) 0.0)
                (let* ((u (- fx ci))
                       (v (- fz cj))
                       (a (+ 1 (* 3 (+ ci (* cj VERTS)))))
                       (ha (vector-ref terrain a))
                       (hb (vector-ref terrain (+ a 3)))
                       (hc (vector-ref terrain (+ a (* 3 VERTS))))
                       (hd (vector-ref terrain (+ a (* 3 VERTS) 3)))
                       (h (if (<= (+ u v) 1.0)
                              (+ ha (* (- hb ha) u) (* (- hc ha) v))
                              (+ hd (* (- hc hd) (- 1.0 u)) (* (- hb hd) (- 1.0 v)))))
                       (gradient (/ (max (abs (- hb ha)) (abs (- hc ha))
                                         (abs (- hd hb)) (abs (- hd hc)))
                                    CELL))
                       (lx (* fx CELL))
                       (lz (* fz CELL))
                       (wx (+ ox lx SEED-X))
                       (wz (+ oz lz SEED-Z))
                       (in-range (and (> h (+ SEA-LEVEL GRASS-SHORE))
                                      (< h GRASS-TOP)
                                      (< gradient GRASS-MAX-GRADIENT)))
                       (drift (if in-range
                                  (ramp FLOWERS (value-noise (* wx FLOWER-FREQUENCY)
                                                             (+ 71.3 (* wz FLOWER-FREQUENCY))))
                                  0.0))
                       (pick (spot-random gi gj 3)))
                  (if (< pick (* drift (+ flowery desert-flowery)))
                      (let* ((r (spot-random gi gj 2))
                             (sprite (if (< pick (* drift desert-flowery))
                                         7
                                         (flower-sprite
                                           (value-noise (* wx FLOWER-KIND-FREQUENCY)
                                                        (- (* wz FLOWER-KIND-FREQUENCY) 39.1))
                                           (/ (* DRY-FLOWER-CHANCE w-dry) (max flowery 1e-6)))))
                             (size (+ 0.75 (* 0.5 (scramble r 71.3))))
                             (half-width (* 0.6 size))
                             (angle (* 3.14159 (scramble r 157.1)))
                             (tint (vector-ref SPRITE-TINTS sprite)))
                        (put-clump! mesh count lx
                                    (- h CLUMP-SINK (* gradient half-width))
                                    lz
                                    (* half-width (cos angle))
                                    (* half-width (sin angle))
                                    (* size (vector-ref SPRITE-HEIGHTS sprite))
                                    sprite
                                    (car tint) (cadr tint) (list-ref tint 2)
                                    (scramble r 13.7)
                                    (+ 0.1 (* 0.8 (scramble r 331.7))))
                        (set! count (+ count 1)))
                  (if (and in-range
                           (> ferny 0.0)
                           (< (spot-random gi gj 4)
                              (* ferny (ramp FERNS (value-noise (* wx FERN-FREQUENCY)
                                                                (- (* wz FERN-FREQUENCY) 17.7))))))
                      (let* ((r (spot-random gi gj 2))
                             (size (+ 0.7 (* 0.6 (scramble r 71.3))))
                             (half-width (* 0.8 size))
                             (angle (* 3.14159 (scramble r 157.1)))
                             (shade (+ 0.8 (* 0.3 (scramble r 331.7))))
                             (tint (vector-ref SPRITE-TINTS 8)))
                        (put-clump! mesh count lx
                                    (- h CLUMP-SINK (* gradient half-width))
                                    lz
                                    (* half-width (cos angle))
                                    (* half-width (sin angle))
                                    (* size (vector-ref SPRITE-HEIGHTS 8))
                                    8
                                    (* shade (car tint)) (* shade (cadr tint)) (* shade (list-ref tint 2))
                                    0.0 -1.0)
                        (set! count (+ count 1)))
                  (when (and in-range
                             (< (spot-random gi gj 0)
                                (* lush
                                   (ramp MEADOW
                                         (value-noise (* (+ ox lx SEED-X) MEADOW-FREQUENCY)
                                                      (* (+ oz lz SEED-Z) MEADOW-FREQUENCY))))))
                    (let* ((r (spot-random gi gj 2))
                           (sprite (clump-sprite (/ (* DRY-GRASS-CHANCE w-dry) lush)
                                                 r (scramble r 13.7)))
                           (size (+ 0.7 (* 0.6 (scramble r 71.3))))
                           (half-width (* 0.75 size))
                           (angle (* 3.14159 (scramble r 157.1)))
                           (shade (+ 0.85 (* 0.3 (scramble r 331.7))))
                           (tint (vector-ref SPRITE-TINTS sprite)))
                      (put-clump! mesh count lx
                                  (- h CLUMP-SINK (* gradient half-width))
                                  lz
                                  (* half-width (cos angle))
                                  (* half-width (sin angle))
                                  (* size (vector-ref SPRITE-HEIGHTS sprite))
                                  sprite
                                  (* shade (car tint))
                                  (* shade (cadr tint) (+ 0.95 (* 0.1 (scramble r 673.3))))
                                  (* shade (list-ref tint 2))
                                  0.0 -1.0)
                      (set! count (+ count 1))))))))))
          (pause))
        (and (> count 0)
             (map (lambda (v per-clump) (vector-copy v 0 (* count per-clump)))
                  mesh
                  (list 24 24 16 32 12)))))

    ;; Build mesh data for the chunk whose corner sits at world (ox, oz).
    ;; Vertices are local to the chunk. All arrays are flat float vectors
    ;; (x y z x y z ...), which Ursina's Mesh takes as-is. Returns
    ;;   (terrain-vertices terrain-normals triangles water terrain-colors)
    ;; where `water` is #f for dry chunks, or (water-vertices water-colors).
    ;; Water colors carry the depth below the surface (red = depth / 10), or
    ;; for ground above it the height (green = height / 10), so the shader
    ;; finds where the shoreline crosses each triangle. It uses depth for the
    ;; shallow tint, transparency, foam and the fade at the water's edge.
    ;; Blue carries the slope of the ground (rise over run / 2), from which
    ;; it estimates how far the shore is.
    ;; Terrain colors carry the biome weights: red desert, green dry
    ;; grassland, blue snowy (grassland is the rest); alpha is `woods`.
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
               (snowy (list-ref biomes 2))
               (wet (list-ref biomes 3))
               (feature (feature-grid x0 z0 CELL SAMPLES)))
          (pause)
          (do ((j 0 (+ j 1))) ((= j SAMPLES))
            (let ((z (+ z0 (* j CELL))))
              (do ((i 0 (+ i 1))) ((= i SAMPLES))
                (let ((k (+ i (* j SAMPLES)))
                      (x (+ x0 (* i CELL))))
                  (vector-set! heights k
                               (shape-land (biome-height (vector-ref heights k)
                                                         (vector-ref desert k)
                                                         (vector-ref dry k)
                                                         (vector-ref snowy k)
                                                         x
                                                         z)
                                           (vector-ref feature k)
                                           (vector-ref desert k) (vector-ref dry k)))))
              (pause)))
          (pause)
          ;; Vertex (i, j) is sample (i + 1, j + 1), past the border.
          (do ((j 0 (+ j 1))) ((= j VERTS))
            (do ((i 0 (+ i 1))) ((= i VERTS))
              (let ((s (+ (+ i 1) (* (+ j 1) SAMPLES)))
                    (c (* 4 (+ i (* j VERTS)))))
                (vector-set! colors c (vector-ref desert s))
                (vector-set! colors (+ c 1) (vector-ref dry s))
                (vector-set! colors (+ c 2) (vector-ref snowy s))
                (vector-set! colors (+ c 3)
                             (woods (+ ox (* i CELL)) (+ oz (* j CELL))
                                    (vector-ref heights s) (vector-ref wet s)))))))
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
                (if (> depth 0.0)
                    (begin
                      (set! wet? #t)
                      (vector-set! water-colors c (min 1.0 (* depth 0.1))))
                    (vector-set! water-colors (+ c 1) (min 1.0 (* depth -0.1))))
                (vector-set! water-colors (+ c 2)
                             (min 1.0 (* 0.5 (sqrt (+ (* dhx dhx) (* dhz dhz))))))
                (vector-set! water-colors (+ c 3) 1.0)))
            (pause)))
        (list vertices
              normals
              TRIANGLES
              (and wet? (list WATER-VERTICES water-colors))
              colors)))

    ;; Runs on every load, including hot reloads: restores the current seed.
    (set-world-seed! (state-ref 'seed))))
