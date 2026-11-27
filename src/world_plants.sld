;; Desert plants, Chihuahuan style: prickly pear, barrel cactus and cholla,
;; plus ocotillo and agave.
;;
;; Each species is modeled once per run as a few randomly built 3D variants,
;; each pre-turned to a dozen headings (the "templates"). A chunk's plants
;; are copies of those, scaled, moved and tinted, merged into one mesh with
;; vertex colors. Deserts get
;; the full mix; dry grassland gets a sparse scatter of agave, ocotillo and
;; prickly pear. Like the terrain library, no engine imports here.

(define-library (world plants)
  (export chunk-plants)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only (srfi 1) iota)
          (only random Random)
          (rename (only builtins map list) (map py-map) (list py-list))
          (only itertools cycle repeat)
          (only array array)
          (rename (only operator add mul) (add py-add) (mul py-mul))
          (world terrain))
  (begin
    (define PI 3.141592653589793)
    (define CELL (/ CHUNK-SIZE CHUNK-RES 1.0))
    (define VERTS (+ CHUNK-RES 1))

    ;; --- small vector math on (x y z) lists -------------------------------

    (define (v+ a b) (map + a b))
    (define (v- a b) (map - a b))
    (define (v* a k) (map (lambda (x) (* x k)) a))
    (define (x-of v) (car v))
    (define (y-of v) (cadr v))
    (define (z-of v) (list-ref v 2))

    (define (dot a b)
      (+ (* (x-of a) (x-of b)) (* (y-of a) (y-of b)) (* (z-of a) (z-of b))))

    (define (cross a b)
      (list (- (* (y-of a) (z-of b)) (* (z-of a) (y-of b)))
            (- (* (z-of a) (x-of b)) (* (x-of a) (z-of b)))
            (- (* (x-of a) (y-of b)) (* (y-of a) (x-of b)))))

    (define (normalize v)
      (v* v (/ 1.0 (max 1e-9 (sqrt (dot v v))))))

    ;; `v` turned by `angle` around the unit `axis`.
    (define (rotate v axis angle)
      (let ((c (cos angle)) (s (sin angle)))
        (v+ (v+ (v* v c) (v* (cross axis v) s))
            (v* axis (* (dot axis v) (- 1.0 c))))))

    (define UP (list 0.0 1.0 0.0))

    ;; Unit vector at `yaw` around the vertical, tipped `tilt` down from it.
    (define (heading yaw tilt)
      (list (* (sin tilt) (sin yaw)) (cos tilt) (* (sin tilt) (cos yaw))))

    (define (clamp01 x) (max 0.0 (min 1.0 x)))

    (define (smooth lo hi x)
      (let ((t (clamp01 (/ (- x lo) (- hi lo)))))
        (* t t (- 3.0 (* 2.0 t)))))

    (define (blend a b t) (v+ a (v* (v- b a) t)))

    ;; --- mesh builder -----------------------------------------------------
    ;;
    ;; A builder is (vertices normals colors triangles uvs material), growing
    ;; flat vectors, plus a one-element vector holding the current material.
    ;;
    ;; The uvs aren't texture coordinates: for the plant shader, u is the
    ;; material (its whole part) and, on agave leaves, the position across
    ;; the leaf (its fraction); v is the height above the plant's base.

    (define MAT-PAD 0.0)     ; prickly pear pad
    (define MAT-BARREL 1.0)
    (define MAT-CHOLLA 2.0)
    (define MAT-CANE 3.0)    ; ocotillo
    (define MAT-LEAF 4.0)    ; agave
    (define MAT-PLAIN 5.0)   ; fruit, flowers, flower stalks

    (define (make-builder) (list (vector) (vector) (vector) (vector) (vector) (vector MAT-PLAIN)))

    (define (set-material! b m) (vector-set! (list-ref b 5) 0 m))
    (define (material b) (vector-ref (list-ref b 5) 0))

    (define (vertex-count b) (quotient (vector-length (car b)) 3))

    ;; `across`, if given, runs -1..1 over the width of an agave leaf.
    (define (add-vertex! b p n c . across)
      (let ((i (vertex-count b)))
        (call-method (car b) 'extend p)
        (call-method (cadr b) 'extend (normalize n))
        (call-method (list-ref b 2) 'extend (list (x-of c) (y-of c) (z-of c) 1.0))
        (call-method (list-ref b 4) 'extend
                     (list (+ (material b) (* 0.45 (+ 1.0 (if (pair? across) (car across) 0.0))))
                           (y-of p)))
        i))

    ;; Takes corners counter-clockwise seen from the front (right-handed,
    ;; as all the math here is); Ursina's left-handed space wants clockwise.
    (define (add-triangle! b i j k)
      (call-method (list-ref b 3) 'extend (list i k j)))

    ;; A closed band of rings: `point` gives (position normal color) for ring
    ;; j (0..rings) and step i (0..steps-1) around it.
    (define (band! b rings steps point)
      (let ((first (vertex-count b)))
        (do ((j 0 (+ j 1))) ((> j rings))
          (do ((i 0 (+ i 1))) ((= i steps))
            (let ((pnc (point j i)))
              (add-vertex! b (car pnc) (cadr pnc) (list-ref pnc 2)))))
        (do ((j 0 (+ j 1))) ((= j rings))
          (do ((i 0 (+ i 1))) ((= i steps))
            (let* ((a (+ first (* j steps) i))
                   (b2 (+ first (* j steps) (modulo (+ i 1) steps)))
                   (c (+ a steps))
                   (d (+ b2 steps)))
              (add-triangle! b a b2 c)
              (add-triangle! b b2 d c))))))

    ;; Ellipsoid around `center` with axes e1 e2 e3 (unit, perpendicular) and
    ;; radii r1 r2 r3. `color` gets the unit-sphere point (x y z). `taper`
    ;; widens the e1 radius toward +e2 (and narrows it toward -e2).
    (define (ellipsoid! b center e1 e2 e3 r1 r2 r3 rings steps color . taper)
      (let ((taper (if (pair? taper) (car taper) 0.0)))
        (band! b rings steps
               (lambda (j i)
                 (let* ((phi (- (* PI (/ j rings)) (/ PI 2.0)))
                        (theta (* -2.0 PI (/ i steps)))
                        (x (* (cos phi) (cos theta)))
                        (y (sin phi))
                        (z (* (cos phi) (sin theta)))
                        (w (* r1 (+ 1.0 (* taper y)))))
                   (list (v+ center (v+ (v+ (v* e1 (* w x)) (v* e2 (* r2 y)))
                                        (v* e3 (* r3 z))))
                         (v+ (v+ (v* e1 (/ x w)) (v* e2 (/ y r2))) (v* e3 (/ z r3)))
                         (color (list x y z))))))))

    ;; Fruit and flowers: always plain material.
    (define (sphere! b center radius color)
      (let ((m (material b)))
        (set-material! b MAT-PLAIN)
        (ellipsoid! b center (list 1.0 0.0 0.0) UP (list 0.0 0.0 1.0)
                    radius radius radius 4 6 (lambda (p) color))
        (set-material! b m)))

    ;; A tube along `points` with matching `radii`, closed at the far end.
    ;; `color` gets the point index.
    (define (tube! b points radii sides color)
      (let* ((n (length points))
             (pts (list->vector points))
             (rs (list->vector radii)))
        (define (tangent k)
          (normalize (v- (vector-ref pts (min (+ k 1) (- n 1)))
                         (vector-ref pts (max (- k 1) 0)))))
        (band! b n sides
               (lambda (j i)
                 (let* ((k (min j (- n 1)))
                        (t (tangent k))
                        (side (normalize (cross t (if (> (abs (y-of t)) 0.95)
                                                      (list 1.0 0.0 0.0)
                                                      UP))))
                        (other (cross t side))
                        (theta (* 2.0 PI (/ i sides)))
                        (out (v+ (v* side (cos theta)) (v* other (sin theta)))))
                   (if (= j n)
                       ;; Cap: a point just past the end.
                       (list (v+ (vector-ref pts k) (v* t (vector-ref rs k))) t (color k))
                       (list (v+ (vector-ref pts k) (v* out (vector-ref rs k)))
                             out
                             (color k))))))))

    ;; --- species ----------------------------------------------------------
    ;;
    ;; Each maker builds one variant at about real size in meters, standing
    ;; on (0 0 0), using `rng` for its shape and colors.

    (define (jitter rng color amount)
      (map (lambda (c) (* c (+ 1.0 (call-method rng 'uniform (- amount) amount)))) color))

    ;; Prickly pear: flat oval pads, a few on the ground and more growing off
    ;; their rims, some with magenta fruit.
    (define (make-prickly-pear b rng)
      (set-material! b MAT-PAD)
      (let* ((purple? (< (call-method rng 'random) 0.3))
             (body (jitter rng (if purple? (list 0.46 0.44 0.44) (list 0.38 0.54 0.32)) 0.08))
             (rim (if purple? (list 0.55 0.32 0.45) (list 0.52 0.56 0.30)))
             (width 0.3)
             (height 0.4))
        (define (pad! center e1 e2 e3)
          (ellipsoid! b center e1 e2 e3 (* width (call-method rng 'uniform 0.85 1.15))
                      (* height (call-method rng 'uniform 0.85 1.15)) 0.06 6 10
                      (lambda (p)
                        (blend body rim (smooth 0.75 1.0 (sqrt (+ (* (x-of p) (x-of p))
                                                                 (* (y-of p) (y-of p)))))))
                      0.25))
        (define (frame yaw lean)
          (let* ((e3 (list (sin yaw) 0.0 (cos yaw)))
                 (e1 (rotate (list (cos yaw) 0.0 (- (sin yaw))) e3 lean))
                 (e2 (rotate UP e3 lean)))
            (list e1 e2 e3)))
        (let loop ((pads (let base ((k (call-method rng 'randint 2 3)) (acc '()))
                           (if (= k 0)
                               acc
                               (let ((f (frame (call-method rng 'uniform 0.0 PI)
                                               (call-method rng 'uniform -0.25 0.25))))
                                 (base (- k 1)
                                       (cons (cons (list (call-method rng 'uniform -0.25 0.25)
                                                         (* height 0.8)
                                                         (call-method rng 'uniform -0.25 0.25))
                                                   f)
                                             acc))))))
                   (extra (call-method rng 'randint 2 4)))
          (if (> extra 0)
              ;; Grow a pad from a random rim point of an existing pad.
              (let* ((parent (list-ref pads (call-method rng 'randint 0 (- (length pads) 1))))
                     (c (car parent))
                     (e1 (cadr parent))
                     (e2 (list-ref parent 2))
                     (e3 (list-ref parent 3))
                     (a (call-method rng 'uniform -1.0 1.0))
                     (out (normalize (v+ (v* e2 (cos a)) (v* e1 (sin a)))))
                     (twist (call-method rng 'uniform -0.9 0.9))
                     (n-e2 (normalize (v+ out (list 0.0 0.25 0.0))))
                     (n-e3 (rotate (normalize (cross (cross n-e2 e3) n-e2)) n-e2 twist))
                     (n-e1 (cross n-e2 n-e3))
                     (attach (v+ c (v+ (v* e2 (* height (cos a) 0.9))
                                      (v* e1 (* width (sin a) 0.9)))))
                     (center (v+ attach (v* n-e2 (* height 0.85)))))
                (loop (if (> (y-of center) (* height 0.6))
                          (cons (list center n-e1 n-e2 n-e3) pads)
                          pads)
                      (- extra 1)))
              (for-each
                (lambda (p)
                  (pad! (car p) (cadr p) (list-ref p 2) (list-ref p 3))
                  (when (< (call-method rng 'random) 0.35)
                    (do ((k (call-method rng 'randint 2 4) (- k 1))) ((= k 0))
                      (let ((a (call-method rng 'uniform -0.8 0.8)))
                        (sphere! b (v+ (car p) (v+ (v* (list-ref p 2) (* height (cos a)))
                                                   (v* (cadr p) (* width (sin a)))))
                                 0.05 (list 0.62 0.12 0.28))))))
                pads)))))

    ;; Barrel cactus: a squat ribbed barrel with reddish spines along the
    ;; ribs and a crown of yellow fruit.
    (define (make-barrel b rng)
      (set-material! b MAT-BARREL)
      (let ((count (if (< (call-method rng 'random) 0.3) 2 1)))
        (do ((n 0 (+ n 1))) ((= n count))
          (let* ((radius (* (call-method rng 'uniform 0.25 0.38) (if (= n 0) 1.0 0.7)))
                 (height (* radius (call-method rng 'uniform 1.4 2.4)))
                 (ribs (call-method rng 'randint 10 13))
                 (steps (* 3 ribs))
                 (offset (if (= n 0)
                             (list 0.0 0.0 0.0)
                             (list (* 1.4 radius) 0.0 (* 0.6 radius))))
                 (body (jitter rng (list 0.27 0.43 0.28) 0.08))
                 (spines (jitter rng (list 0.42 0.44 0.30) 0.1))
                 (crown (list 0.72 0.62 0.30)))
            (band! b 8 steps
                   (lambda (j i)
                     (let* ((phi (+ -0.1 (* (/ j 8.0) (+ (/ PI 2.0) 0.1))))
                            (theta (* -2.0 PI (/ i steps)))
                            (rib (cos (* ribs theta)))
                            (r (* radius (expt (max 0.0 (cos phi)) 0.55) (+ 1.0 (* 0.07 rib))))
                            (around (list (cos theta) 0.0 (sin theta)))
                            (along (list (- (sin theta)) 0.0 (cos theta)))
                            (n (v+ (normalize (list (/ (* (cos phi) (cos theta)) radius)
                                                    (/ (sin phi) height)
                                                    (/ (* (cos phi) (sin theta)) radius)))
                                   (v* along (* 0.04 ribs (sin (* ribs theta)) (cos phi))))))
                       (list (v+ offset (v+ (v* around r)
                                            (list 0.0 (* height (/ (+ (sin phi) 0.1) 1.1)) 0.0)))
                             n
                             (blend (blend body spines (* 0.6 (smooth 0.4 1.0 rib)))
                                  crown
                                  (smooth 1.2 1.5 phi))))))
            ;; Fruit around the crown.
            (when (< (call-method rng 'random) 0.7)
              (do ((k 0 (+ k 1))) ((= k 4))
                (let ((a (* k (/ PI 2.0))))
                  (sphere! b (v+ offset (list (* 0.25 radius (cos a)) (* 0.97 height)
                                              (* 0.25 radius (sin a))))
                           (* 0.18 radius) (list 0.85 0.72 0.22)))))))))

    ;; Cholla: a short trunk branching into jointed, pale stems.
    (define (make-cholla b rng)
      (set-material! b MAT-CHOLLA)
      (let ((color (jitter rng (list 0.56 0.60 0.38) 0.08)))
        (define (branch! base dir length radius depth)
          (let* ((bend (normalize (v+ dir (list 0.0 0.15 0.0))))
                 (mid (v+ base (v* dir (* 0.5 length))))
                 (end (v+ mid (v* bend (* 0.5 length)))))
            (tube! b (list base mid end) (list radius (* 0.95 radius) (* 0.85 radius)) 6
                   (lambda (k) color))
            (if (> depth 0)
                (do ((k (call-method rng 'randint 2 4) (- k 1))) ((= k 0))
                  (let* ((axis (normalize (cross bend (heading (call-method rng 'uniform 0.0 (* 2 PI)) 1.2))))
                         (child (normalize (v+ (rotate bend axis (call-method rng 'uniform 0.6 1.2))
                                               (list 0.0 0.35 0.0)))))
                    (branch! end child (* length (call-method rng 'uniform 0.55 0.8))
                             (* radius 0.75) (- depth 1))))
                (when (< (call-method rng 'random) 0.4)
                  (sphere! b end (* radius 0.9) (list 0.80 0.75 0.30))))))
        (branch! (list 0.0 0.0 0.0) UP (call-method rng 'uniform 0.45 0.65) 0.065 2)))

    ;; Ocotillo: a fan of long, thin, gently curving canes, leafy green after
    ;; rain or bare grey-brown, some tipped with red flowers.
    (define (make-ocotillo b rng)
      (set-material! b MAT-CANE)
      (let* ((leafy? (< (call-method rng 'random) 0.4))
             (flowers? (< (call-method rng 'random) 0.5))
             (stem (jitter rng (if leafy? (list 0.42 0.52 0.28) (list 0.52 0.46 0.38)) 0.08))
             (red (list 0.82 0.18 0.10)))
        (do ((k (call-method rng 'randint 9 15) (- k 1))) ((= k 0))
          (let* ((yaw (call-method rng 'uniform 0.0 (* 2.0 PI)))
                 (tilt (call-method rng 'uniform 0.08 0.5))
                 (length (call-method rng 'uniform 2.4 4.2))
                 (step (/ length 3.0))
                 (points (let walk ((s 0)
                                    (p (list (* 0.06 (sin yaw)) 0.0 (* 0.06 (cos yaw))))
                                    (acc '()))
                           (if (> s 3)
                               (reverse acc)
                               (walk (+ s 1)
                                     (v+ p (v* (heading yaw (+ tilt (* 0.08 s))) step))
                                     (cons p acc))))))
            (tube! b points (list 0.04 0.03 0.02 0.012) 3
                   (lambda (i) (if (and flowers? (= i 3)) red stem)))))))

    ;; Agave: a rosette of thick, pointed, blue-grey leaves (or a smaller,
    ;; greener lechuguilla), now and then with a tall flower stalk.
    (define (make-agave b rng)
      (set-material! b MAT-LEAF)
      (let* ((lechuguilla? (< (call-method rng 'random) 0.35))
             (leaves (call-method rng 'randint 16 26))
             (size (if lechuguilla? 0.55 0.85))
             (width (if lechuguilla? 0.07 0.14))
             (body (jitter rng (if lechuguilla? (list 0.54 0.64 0.38) (list 0.56 0.68 0.64)) 0.06))
             (tip (list 0.30 0.24 0.18)))
        (do ((k 0 (+ k 1))) ((= k leaves))
          (let* ((outer (- 1.0 (/ k leaves)))
                 (yaw (+ (* k 2.39996) (call-method rng 'uniform -0.2 0.2)))
                 (tilt (- (* PI 0.5) (+ 0.2 (* (- 1.0 outer) 1.0)
                                       (if lechuguilla? 0.25 0.0))))
                 (length (* size (+ 0.6 (* 0.45 outer)) (call-method rng 'uniform 0.9 1.1)))
                 (side (list (cos yaw) 0.0 (- (sin yaw))))
                 (first (vertex-count b)))
            (for-each
              (lambda (t half)
                (let* ((dir (heading yaw (+ tilt (* 0.35 outer t))))
                       (center (v+ (list 0.0 0.05 0.0)
                                   (v* (heading yaw (+ tilt (* 0.15 outer t))) (* length t))))
                       (normal (normalize (cross dir side)))
                       (w (* width half))
                       (color (blend body tip (smooth 0.75 1.0 t))))
                  (add-vertex! b (v- center (v* side w)) (v+ normal (v* side 0.4)) color -1.0)
                  (add-vertex! b (v- center (v* normal (* 0.4 w))) normal color 0.0)
                  (add-vertex! b (v+ center (v* side w)) (v- normal (v* side 0.4)) color 1.0)))
              (list 0.0 0.3 0.65 1.0)
              (list 0.55 1.0 0.7 0.0))
            (do ((s 0 (+ s 1))) ((= s 3))
              (let* ((l0 (+ first (* 3 s))) (c0 (+ l0 1)) (r0 (+ l0 2))
                     (l1 (+ l0 3)) (c1 (+ l0 4)) (r1 (+ l0 5)))
                (add-triangle! b l0 l1 c0)
                (add-triangle! b c0 l1 c1)
                (add-triangle! b c0 c1 r0)
                (add-triangle! b r0 c1 r1)))))
        ;; Flower stalk (quiote) with yellow clusters on short side branches.
        (when (and (not lechuguilla?) (< (call-method rng 'random) 0.3))
          (let* ((height (call-method rng 'uniform 3.0 4.2))
                 (lean (heading (call-method rng 'uniform 0.0 (* 2.0 PI)) 0.06))
                 (stalk (list 0.46 0.42 0.26)))
            (set-material! b MAT-PLAIN)
            (tube! b (list (list 0.0 0.1 0.0) (v* lean (* 0.5 height)) (v* lean height))
                   (list 0.07 0.05 0.03) 7 (lambda (k) stalk))
            (do ((k 0 (+ k 1))) ((= k 5))
              (let* ((base (v* lean (* height (+ 0.62 (* 0.08 k)))))
                     (out (heading (* k 2.4) 1.1))
                     (end (v+ base (v* out 0.35))))
                (tube! b (list base end) (list 0.025 0.02) 5 (lambda (k) stalk))
                (do ((f 0 (+ f 1))) ((= f 4))
                  (sphere! b (v+ end (v* (heading (* f 1.9) (* 0.6 f)) 0.07))
                           (call-method rng 'uniform 0.06 0.08)
                           (jitter rng (list 0.86 0.72 0.22) 0.08)))))))))

    ;; --- templates --------------------------------------------------------

    (define VARIANTS 12)
    (define HEADINGS 8)

    ;; A builder's mesh turned `angle` radians about the vertical axis.
    (define (turn b angle)
      (let* ((tv (car b))
             (tn (cadr b))
             (n (vector-length tv))
             (vertices (make-vector n 0.0))
             (normals (make-vector n 0.0))
             (c (cos angle))
             (s (sin angle)))
        (do ((i 0 (+ i 3))) ((= i n))
          (let ((lx (vector-ref tv i))
                (lz (vector-ref tv (+ i 2)))
                (nx (vector-ref tn i))
                (nz (vector-ref tn (+ i 2))))
            (vector-set! vertices i (+ (* c lx) (* s lz)))
            (vector-set! vertices (+ i 1) (vector-ref tv (+ i 1)))
            (vector-set! vertices (+ i 2) (- (* c lz) (* s lx)))
            (vector-set! normals i (+ (* c nx) (* s nz)))
            (vector-set! normals (+ i 1) (vector-ref tn (+ i 1)))
            (vector-set! normals (+ i 2) (- (* c nz) (* s nx)))))
        ;; Compact float arrays: no per-number objects for the garbage
        ;; collector to walk.
        (list (array "f" vertices) (array "f" normals) (array "f" (list-ref b 2))
              (array "l" (list-ref b 3)) (array "f" (list-ref b 4)))))

    ;; A copy of `template` scaled by `scale` (and its height by `stretch`),
    ;; moved to (x y z) and its colors tinted, with triangle indices starting
    ;; at `base`. Returns (vertices normals colors triangles uvs).
    ;; Done with Python's `map` over whole lists, as per-vertex Scheme loops
    ;; were most of the cost of a chunk.
    (define (place template x y z scale stretch tint base)
      (list (py-list (py-map py-add
                             (py-map py-mul (car template)
                                     (cycle (make-tuple scale (* scale stretch) scale)))
                             (cycle (make-tuple x y z))))
            (py-list (cadr template))
            (py-list (py-map py-mul (list-ref template 2) (repeat tint)))
            (py-list (py-map py-add (list-ref template 3) (repeat base)))
            (py-list (py-map py-mul (list-ref template 4)
                             (cycle (make-tuple 1.0 (* scale stretch)))))))

    ;; Per species: (maker scale-low scale-high footprint), where `footprint`
    ;; is the radius used to sink the base into sloping ground.
    (define SPECIES
      (vector (list make-prickly-pear 0.8 1.4 0.5)
              (list make-barrel 0.7 1.3 0.3)
              (list make-cholla 0.8 1.5 0.3)
              (list make-ocotillo 0.8 1.2 0.15)
              (list make-agave 0.7 1.3 0.6)))

    (define (build-templates)
      (let ((rng (Random 7)))
        (vector-map
          (lambda (species)
            (let loop ((k 0) (acc '()))
              (if (= k VARIANTS)
                  (list->vector (reverse acc))
                  (let ((b (make-builder)))
                    ((car species) b rng)
                    (loop (+ k 1)
                          (cons (list->vector
                                  (map (lambda (h) (turn b (* 2.0 PI (/ h HEADINGS))))
                                       (iota HEADINGS)))
                                acc))))))
          SPECIES)))

    (define TEMPLATES (build-templates))

    ;; --- placement --------------------------------------------------------

    (define PLANT-SPACING 4.0)
    (define DESERT-PLANT-CHANCE 0.35)  ; per spot, in full desert, mid-patch
    (define DRY-PLANT-CHANCE 0.05)     ; per spot, in full dry grassland
    (define PATCH-FREQUENCY (/ 1.0 70.0))
    (define PATCHES (list 0.2 0.65))   ; patch noise ramp from bare to full
    (define PLANT-SHORE 1.2)           ; none this close above the sea
    (define PLANT-MAX-GRADIENT 0.9)
    (define SPOTS-PER-SIDE (exact (round (/ CHUNK-SIZE PLANT-SPACING))))

    ;; Cumulative chances of each species (by SPECIES index).
    (define DESERT-MIX (list (list 0.26 0) (list 0.40 1) (list 0.56 2) (list 0.70 3) (list 1.0 4)))
    (define DRY-MIX (list (list 0.30 0) (list 0.48 3) (list 1.0 4)))

    (define (pick mix r)
      (if (or (null? (cdr mix)) (< r (car (car mix))))
          (cadr (car mix))
          (pick (cdr mix) r)))

    (define (spot-random gi gj k)
      (hash2 (+ gi (* 23 k)) (- gj (* 41 k))))

    (define (ramp range x)
      (smooth (car range) (cadr range) x))

    ;; Plant mesh data for the chunk at world (ox, oz), from the terrain
    ;; vertices and biome colors `chunk-mesh-data` made for it. Returns
    ;; (vertices normals colors triangles uvs), or #f if nothing grows.
    (define (chunk-plants ox oz terrain biomes pause)
      (let* ((seed (seed-offset))
             (gi0 (exact (floor (/ (+ ox (car seed)) PLANT-SPACING))))
             (gj0 (exact (floor (/ (+ oz (cadr seed)) PLANT-SPACING))))
             (parts '())
             (base 0))
        (do ((j 0 (+ j 1))) ((= j SPOTS-PER-SIDE))
          (do ((i 0 (+ i 1))) ((= i SPOTS-PER-SIDE))
            (let* ((gi (+ gi0 i))
                   (gj (+ gj0 j))
                   (jitter (spot-random gi gj 1))
                   (fx (/ (* PLANT-SPACING (+ i jitter)) CELL))
                   (fz (/ (* PLANT-SPACING (+ j (spot-random gi gj 2))) CELL))
                   (ci (exact (floor fx)))
                   (cj (exact (floor fz)))
                   (c (* 4 (+ ci (* cj VERTS))))
                   (w-desert (vector-ref biomes c))
                   (w-dry (vector-ref biomes (+ c 1)))
                   (chance (+ (* DESERT-PLANT-CHANCE w-desert) (* DRY-PLANT-CHANCE w-dry))))
              (when (> chance 0.0)
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
                       (lz (* fz CELL)))
                  (when (and (> h (+ SEA-LEVEL PLANT-SHORE))
                             (< gradient PLANT-MAX-GRADIENT)
                             (< (spot-random gi gj 0)
                                (* chance
                                   (ramp PATCHES
                                         (value-noise (* (+ ox lx (car seed)) PATCH-FREQUENCY)
                                                      (* (+ oz lz (cadr seed)) PATCH-FREQUENCY))))))
                    (let* ((r (spot-random gi gj 3))
                           (kind (pick (if (< (spot-random gi gj 4)
                                              (/ (* DESERT-PLANT-CHANCE w-desert) chance))
                                           DESERT-MIX
                                           DRY-MIX)
                                       r))
                           (species (vector-ref SPECIES kind))
                           (template (vector-ref
                                       (vector-ref (vector-ref TEMPLATES kind)
                                                   (exact (floor (* VARIANTS (spot-random gi gj 5)))))
                                       (exact (floor (* HEADINGS (spot-random gi gj 7))))))
                           (scale (+ (cadr species)
                                     (* (- (list-ref species 2) (cadr species))
                                        (spot-random gi gj 6))))
                           (part (place template lx
                                        (- h 0.05 (* gradient (list-ref species 3) scale))
                                        lz
                                        scale
                                        (+ 0.85 (* 0.35 (spot-random gi gj 9)))
                                        (+ 0.88 (* 0.24 (spot-random gi gj 8)))
                                        base)))
                      (set! base (+ base (quotient (vector-length (car part)) 3)))
                      (set! parts (cons part parts))))))))
          (pause))
        (and (pair? parts)
             (let ((parts (reverse parts)))
               (map (lambda (pick) (apply vector-append (map pick parts)))
                    (list car cadr (lambda (p) (list-ref p 2)) (lambda (p) (list-ref p 3))
                          (lambda (p) (list-ref p 4))))))))))
