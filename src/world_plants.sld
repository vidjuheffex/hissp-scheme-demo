;; Desert plants, Chihuahuan style: prickly pear, barrel cactus and cholla,
;; plus ocotillo and agave. And trees: oak groves in grassland, conifers in
;; the snow and up the mountains to the tree line, junipers scattered over
;; dry grassland and the odd mesquite in the desert.
;;
;; Each species is modeled once per run as a few randomly built 3D variants,
;; each pre-turned to several headings (the "templates"). A chunk's plants
;; are copies of those, scaled, moved and tinted, merged into one mesh with
;; vertex colors. Deserts get the full mix of desert plants; dry grassland
;; gets a sparse scatter of agave, ocotillo and prickly pear. Like the
;; terrain library, no engine imports here.

(define-library (world plants)
  (export chunk-plants)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only (srfi 1) iota fold)
          (only (srfi 132) list-sort)
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
    ;; material (its whole part) and an `across` value (its fraction): the
    ;; position across an agave leaf, from trunk to tip of a conifer tier,
    ;; or bottom to top of a clump of leaves. v is the height above the
    ;; plant's base.

    (define MAT-PAD 0.0)     ; prickly pear pad
    (define MAT-BARREL 1.0)
    (define MAT-CHOLLA 2.0)
    (define MAT-CANE 3.0)    ; ocotillo
    (define MAT-LEAF 4.0)    ; agave
    (define MAT-PLAIN 5.0)   ; fruit, flowers, flower stalks
    (define MAT-BARK 6.0)
    (define MAT-NEEDLES 7.0)
    (define MAT-FOLIAGE 8.0) ; broadleaf clumps
    (define MAT-PODS 9.0)    ; agave flower and seed pod clusters

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
    ;; j (0..rings) and step i (0..steps-1) around it, optionally followed by
    ;; the `across` value of `add-vertex!`.
    (define (band! b rings steps point)
      (let ((first (vertex-count b)))
        (do ((j 0 (+ j 1))) ((> j rings))
          (do ((i 0 (+ i 1))) ((= i steps))
            (apply add-vertex! b (point j i))))
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
                (set-material! b MAT-PODS)
                (do ((f 0 (+ f 1))) ((= f 4))
                  (let ((r (call-method rng 'uniform 0.06 0.08)))
                    (ellipsoid! b (v+ end (v* (heading (* f 1.9) (* 0.6 f)) 0.07))
                                (list 1.0 0.0 0.0) UP (list 0.0 0.0 1.0) r r r 5 8
                                (let ((c (jitter rng (list 0.86 0.72 0.22) 0.08)))
                                  (lambda (p) c)))))
                (set-material! b MAT-PLAIN)))))))

    ;; --- trees ------------------------------------------------------------

    ;; Conifer: a straight trunk under tiers of drooping, ragged needle
    ;; skirts narrowing to a spire. Most are narrow, dark spruces; the rest
    ;; broader, warmer pines with more bare trunk.
    (define (make-conifer b rng)
      (let* ((height (call-method rng 'uniform 7.0 11.0))
             (spruce? (< (call-method rng 'random) 0.6))
             (width (* height (if spruce?
                                  (call-method rng 'uniform 0.17 0.22)
                                  (call-method rng 'uniform 0.23 0.29))))
             ;; Bare trunk below the lowest tier, high enough to walk under,
             ;; as in a forest where the lower branches have died off.
             (clear (max 2.8 (* height (if spruce?
                                           (call-method rng 'uniform 0.25 0.32)
                                           (call-method rng 'uniform 0.3 0.45)))))
             (tiers (call-method rng 'randint 6 8))
             (span (/ (- height clear) tiers))
             (dark (jitter rng (if spruce? (list 0.10 0.22 0.14) (list 0.16 0.26 0.13)) 0.1))
             (tips (jitter rng (if spruce? (list 0.22 0.36 0.24) (list 0.32 0.42 0.20)) 0.1))
             (bark (jitter rng (if spruce? (list 0.30 0.24 0.20) (list 0.42 0.28 0.18)) 0.1)))
        (set-material! b MAT-BARK)
        (tube! b (list (list 0.0 -0.3 0.0) (list 0.0 (* 0.5 height) 0.0)
                       (list 0.0 (* 0.92 height) 0.0))
               (list (* 0.03 height) (* 0.02 height) (* 0.006 height)) 6
               (lambda (k) bark))
        (set-material! b MAT-NEEDLES)
        (do ((k 0 (+ k 1))) ((= k tiers))
          (let* ((f (/ k (- tiers 1.0)))
                 (last? (= k (- tiers 1)))
                 (bottom (+ clear (* k span)))
                 (tall (* span (if last? 1.6 1.9)))
                 (r (* width (- 1.0 (* 0.8 f)) (call-method rng 'uniform 0.88 1.12)))
                 (droop (* tall (call-method rng 'uniform 0.1 0.22)))
                 (steps (* 2 (call-method rng 'randint 5 7)))
                 (twist (call-method rng 'uniform 0.0 (* 2.0 PI)))
                 (ragged (list->vector (map (lambda (i) (call-method rng 'uniform 0.85 1.15))
                                            (iota steps))))
                 ;; Lower tiers sit in the shade of the ones above.
                 (shade (+ 0.75 (* 0.3 f))))
            ;; Rings from the top of the tier out to its ragged rim, then
            ;; back in underneath.
            (band! b 3 steps
                   (lambda (j i)
                     (let* ((theta (+ twist (* 2.0 PI (/ i steps))))
                            (out (list (cos theta) 0.0 (sin theta)))
                            (jag (* (vector-ref ragged i) (if (even? i) 1.15 0.8)))
                            (ring (lambda (radius y up color across)
                                    (list (v+ (v* out radius) (list 0.0 y 0.0))
                                          (v+ out (list 0.0 up 0.0))
                                          (v* color shade)
                                          across))))
                       (cond ((= j 0) (ring (if last? 0.0 (* 0.12 r)) (+ bottom tall) 1.5 dark -1.0))
                             ((= j 1) (ring (* 0.6 r (sqrt jag)) (+ bottom (* 0.42 tall)) 0.7
                                            (blend dark tips 0.45) 0.0))
                             ((= j 2) (ring (* r jag) (- bottom (* droop jag)) 0.2 tips 1.0))
                             (else (ring (* 0.2 r) (+ bottom (* 0.12 tall)) -3.0
                                         (v* dark 0.7) -0.6))))))))))

    ;; A lumpy clump of leaves around `center`, radius `r` and its height
    ;; `flat` times that. Normals lean away from `heart`, the middle of the
    ;; crown, so the clumps of a crown shade as one mass.
    (define (clump! b rng center r flat heart color)
      (let ((a (call-method rng 'uniform 0.0 6.0))
            (c (call-method rng 'uniform 0.0 6.0))
            (e (call-method rng 'uniform 0.0 6.0)))
        (band! b 4 8
               (lambda (j i)
                 (let* ((phi (- (* PI (/ j 4.0)) (/ PI 2.0)))
                        (theta (* -2.0 PI (/ i 8.0)))
                        (d (list (* (cos phi) (cos theta)) (sin phi) (* (cos phi) (sin theta))))
                        (lump (+ 1.0
                                 (* 0.3 (sin (+ (* 3.1 (x-of d)) a)) (sin (+ (* 2.7 (y-of d)) c)))
                                 (* 0.15 (sin (+ (* 5.3 (z-of d)) e)))))
                        (p (v+ center (list (* r lump (x-of d))
                                            (* r flat lump (y-of d))
                                            (* r lump (z-of d)))))
                        (n (normalize (v+ d (v* (normalize (v- p heart)) 0.8)))))
                   (list p n (v* color (+ 0.62 (* 0.45 (smooth -1.0 1.0 (y-of n))))) (y-of d)))))))

;; Broadleaf trees: one or more trunks under a crown of overlapping leaf
    ;; clumps, with limbs reaching out to them. A form gives the proportions,
    ;; lengths as fractions of the tree's height: `fork` where the trunk
    ;; ends, the crown's `middle` height and its `width` and `depth` radii,
    ;; the `clump` radius and `flat` its height over its width.
    (define OAK
      '((height 6.0 9.5) (stems . 1) (fork . 0.35) (middle . 0.66) (width . 0.36)
        (depth . 0.26) (clumps 8 11) (clump . 0.15) (flat . 0.8) (girth . 0.035)
        (foliage 0.26 0.42 0.15) (bark 0.33 0.27 0.22)))
    (define JUNIPER
      '((height 2.8 4.2) (stems . 3) (fork . 0.15) (middle . 0.55) (width . 0.36)
        (depth . 0.36) (clumps 5 7) (clump . 0.19) (flat . 0.85) (girth . 0.04)
        (foliage 0.19 0.30 0.22) (bark 0.40 0.30 0.24)))
    (define MESQUITE
      '((height 2.5 4.0) (stems . 3) (fork . 0.35) (middle . 0.75) (width . 0.6)
        (depth . 0.18) (clumps 7 10) (clump . 0.2) (flat . 0.5) (girth . 0.03)
        (foliage 0.42 0.50 0.24) (bark 0.30 0.22 0.17)))

    (define LIMBS 5)   ; at most, to the lowest clumps; the rest hide inside

    (define (make-broadleaf form)
      (lambda (b rng)
        (define (get key) (cdr (assq key form)))
        (define (uniform lo hi) (call-method rng 'uniform lo hi))
        (let* ((height (uniform (car (get 'height)) (cadr (get 'height))))
               (stems (get 'stems))
               (foliage (jitter rng (get 'foliage) 0.1))
               (bark (jitter rng (get 'bark) 0.1))
               (r (/ (* height (get 'girth)) (sqrt stems)))
               (middle (list 0.0 (* height (get 'middle)) 0.0))
               (width (* height (get 'width) (uniform 0.85 1.15)))
               (depth (* height (get 'depth) (uniform 0.85 1.15)))
               (size (* height (get 'clump)))
               (count (call-method rng 'randint (car (get 'clumps)) (cadr (get 'clumps))))
               (yaw0 (uniform 0.0 (* 2.0 PI)))
               ;; Clumps over the crown's upper part, going round by the
               ;; golden angle, and one on top.
               (clumps (cons (list (v+ middle (list 0.0 (* 0.65 depth) 0.0)) (* 1.1 size))
                             (map (lambda (k)
                                    (let ((yaw (+ yaw0 (* k 2.39996) (uniform -0.3 0.3)))
                                          (rise (uniform -0.35 1.0))
                                          (out (uniform 0.6 0.9)))
                                      (list (v+ middle
                                                (list (* width out (cos rise) (sin yaw))
                                                      (* depth out (sin rise))
                                                      (* width out (cos rise) (cos yaw))))
                                            (* size (uniform 0.75 1.15)))))
                                  (iota count))))
               (tops (map (lambda (s)
                            (let ((yaw (+ yaw0 (* 2.0 PI (/ s stems)))))
                              (v* (if (= stems 1)
                                      (heading yaw (uniform 0.0 0.1))
                                      (heading yaw (uniform 0.2 0.45)))
                                  (* height (get 'fork) (uniform 0.85 1.15)))))
                          (iota stems))))
          (set-material! b MAT-BARK)
          (for-each
            (lambda (top)
              (let ((wobble (list (uniform -0.2 0.2) 0.0 (uniform -0.2 0.2))))
                (tube! b (list (list 0.0 -0.3 0.0) (v+ (v* top 0.5) (v* wobble (* r 4.0))) top)
                       (list (* 1.3 r) r (* 0.85 r)) 6 (lambda (k) bark))))
            tops)
          ;; Limbs from the nearest trunk top out toward the lowest clumps.
          (let loop ((targets (list-sort (lambda (p q) (< (y-of (car p)) (y-of (car q))))
                                         (cdr clumps)))
                     (n 0))
            (when (and (pair? targets) (< n LIMBS))
              (let* ((target (blend middle (car (car targets)) 0.85))
                     (from (fold (lambda (top best)
                                   (if (< (dot (v- top target) (v- top target))
                                          (dot (v- best target) (v- best target)))
                                       top best))
                                 (car tops) tops))
                     (mid (v+ (blend from target 0.5) (list 0.0 (* 0.1 height) 0.0))))
                (tube! b (list from mid target) (list (* 0.6 r) (* 0.4 r) (* 0.25 r)) 5
                       (lambda (k) bark))
                (loop (cdr targets) (+ n 1)))))
          (set-material! b MAT-FOLIAGE)
          (for-each (lambda (c)
                      (clump! b rng (car c) (cadr c) (get 'flat) middle
                              (jitter rng foliage 0.06)))
                    clumps))))

    ;; --- templates --------------------------------------------------------

    (define VARIANTS 12)
    (define TREE-VARIANTS 8)
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

    ;; Like SPECIES, for trees, plus the radius of trunk (or stems) the
    ;; player can't walk through.
    (define TREES
      (vector (list make-conifer 0.75 1.3 0.4 0.3)
              (list (make-broadleaf OAK) 0.85 1.2 0.4 0.35)
              (list (make-broadleaf JUNIPER) 0.8 1.25 0.3 0.45)
              (list (make-broadleaf MESQUITE) 0.8 1.3 0.3 0.35)))

    ;; For each species, `variants` vectors of the mesh turned to each heading.
    (define (build-templates species variants seed)
      (let ((rng (Random seed)))
        (vector-map
          (lambda (kind)
            (let loop ((k 0) (acc '()))
              (if (= k variants)
                  (list->vector (reverse acc))
                  (let ((b (make-builder)))
                    ((car kind) b rng)
                    (loop (+ k 1)
                          (cons (list->vector
                                  (map (lambda (h) (turn b (* 2.0 PI (/ h HEADINGS))))
                                       (iota HEADINGS)))
                                acc))))))
          species)))

    (define TEMPLATES (build-templates SPECIES VARIANTS 7))
    (define TREE-TEMPLATES (build-templates TREES TREE-VARIANTS 11))

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

    (define TREE-SPACING 6.4)
    (define FOREST-CHANCE 0.6)         ; per spot, mid-grove, in grassland or snow
    (define JUNIPER-CHANCE 0.15)       ; per spot, in full dry grassland
    (define MESQUITE-CHANCE 0.03)      ; per spot, in full desert
    (define GROVE-FREQUENCY (/ 1.0 90.0))
    (define GROVES (list 0.35 0.65))   ; grove noise ramp from meadow to forest
    (define MOUNTAIN-PINES (list 17.0 24.0))  ; heights where conifers replace oaks
    (define TREE-LINE (list 27.0 31.0))
    (define TREE-SHORE 1.5)
    (define TREE-MAX-GRADIENT 0.7)
    (define TREE-SPOTS-PER-SIDE (exact (round (/ CHUNK-SIZE TREE-SPACING))))

    (define (pick mix r)
      (if (or (null? (cdr mix)) (< r (car (car mix))))
          (cadr (car mix))
          (pick (cdr mix) r)))

    ;; Index of the weight `r` (0..1 of their total) falls in.
    (define (pick-weighted weights r)
      (let loop ((ws weights) (k 0) (left (* r (apply + weights))))
        (if (or (null? (cdr ws)) (< left (car ws)))
            k
            (loop (cdr ws) (+ k 1) (- left (car ws))))))

    (define (spot-random gi gj k)
      (hash2 (+ gi (* 23 k)) (- gj (* 41 k))))

    (define (ramp range x)
      (smooth (car range) (cadr range) x))

    ;; (height steepness) of the terrain at grid position (fx fz), in cells
    ;; from the chunk corner, following the mesh's triangles.
    (define (ground terrain fx fz)
      (let* ((ci (exact (floor fx)))
             (cj (exact (floor fz)))
             (u (- fx ci))
             (v (- fz cj))
             (a (+ 1 (* 3 (+ ci (* cj VERTS)))))
             (ha (vector-ref terrain a))
             (hb (vector-ref terrain (+ a 3)))
             (hc (vector-ref terrain (+ a (* 3 VERTS))))
             (hd (vector-ref terrain (+ a (* 3 VERTS) 3))))
        (list (if (<= (+ u v) 1.0)
                  (+ ha (* (- hb ha) u) (* (- hc ha) v))
                  (+ hd (* (- hc hd) (- 1.0 u)) (* (- hb hd) (- 1.0 v))))
              (/ (max (abs (- hb ha)) (abs (- hc ha)) (abs (- hd hb)) (abs (- hd hc)))
                 CELL))))

    ;; Plant mesh data for the chunk at world (ox, oz), from the terrain
    ;; vertices and biome colors `chunk-mesh-data` made for it. Returns
    ;; (vertices normals colors triangles uvs trunks), or #f if nothing
    ;; grows, where `trunks` lists each tree's world (x z radius).
    (define (chunk-plants ox oz terrain biomes pause)
      (let* ((seed (seed-offset))
             (parts '())
             (trunks '())
             (base 0))
        ;; Add a copy of species `kind`, picking variant, heading, size and
        ;; tint from the spot's random numbers `rand`, standing on ground of
        ;; height `h` and steepness `gradient` at chunk position (lx lz).
        ;; Returns the size picked.
        (define (add! species templates variants kind rand lx h gradient lz)
          (let* ((sp (vector-ref species kind))
                 (template (vector-ref
                             (vector-ref (vector-ref templates kind)
                                         (exact (floor (* variants (rand 5)))))
                             (exact (floor (* HEADINGS (rand 7))))))
                 (scale (+ (cadr sp) (* (- (list-ref sp 2) (cadr sp)) (rand 6))))
                 (part (place template lx
                              (- h 0.05 (* gradient (list-ref sp 3) scale))
                              lz
                              scale
                              (+ 0.85 (* 0.35 (rand 9)))
                              (+ 0.88 (* 0.24 (rand 8)))
                              base)))
            (set! base (+ base (quotient (vector-length (car part)) 3)))
            (set! parts (cons part parts))
            scale))
        ;; Visit a grid of spots `spacing` apart, `side` to a side, calling
        ;; `grow` with the spot's random numbers, its chunk position, its
        ;; ground and the biome weights there.
        (define (each-spot spacing side salt grow)
          (let ((gi0 (exact (floor (/ (+ ox (car seed)) spacing))))
                (gj0 (exact (floor (/ (+ oz (cadr seed)) spacing)))))
            (do ((j 0 (+ j 1))) ((= j side))
              (do ((i 0 (+ i 1))) ((= i side))
                (let* ((gi (+ gi0 i))
                       (gj (+ gj0 j))
                       (rand (lambda (k) (spot-random gi gj (+ k salt))))
                       (fx (/ (* spacing (+ i (rand 1))) CELL))
                       (fz (/ (* spacing (+ j (rand 2))) CELL))
                       (c (* 4 (+ (exact (floor fx)) (* (exact (floor fz)) VERTS)))))
                  (grow rand (* fx CELL) (* fz CELL) (ground terrain fx fz)
                        (vector-ref biomes c) (vector-ref biomes (+ c 1))
                        (vector-ref biomes (+ c 2)))))
              (pause))))
        (define (noise-at lx lz frequency)
          (value-noise (* (+ ox lx (car seed)) frequency)
                       (* (+ oz lz (cadr seed)) frequency)))
        (each-spot PLANT-SPACING SPOTS-PER-SIDE 0
          (lambda (rand lx lz g w-desert w-dry w-snowy)
            (let ((chance (+ (* DESERT-PLANT-CHANCE w-desert) (* DRY-PLANT-CHANCE w-dry)))
                  (h (car g)))
              (when (and (> chance 0.0)
                         (> h (+ SEA-LEVEL PLANT-SHORE))
                         (< (cadr g) PLANT-MAX-GRADIENT)
                         (< (rand 0) (* chance (ramp PATCHES (noise-at lx lz PATCH-FREQUENCY)))))
                (add! SPECIES TEMPLATES VARIANTS
                      (pick (if (< (rand 4) (/ (* DESERT-PLANT-CHANCE w-desert) chance))
                                DESERT-MIX
                                DRY-MIX)
                            (rand 3))
                      rand lx h (cadr g) lz)))))
        (each-spot TREE-SPACING TREE-SPOTS-PER-SIDE 50
          (lambda (rand lx lz g w-desert w-dry w-snowy)
            (let* ((h (car g))
                   (w-grass (max 0.0 (- 1.0 w-desert w-dry w-snowy)))
                   (mountain (ramp MOUNTAIN-PINES h))
                   (forest (* FOREST-CHANCE (ramp GROVES (noise-at lx lz GROVE-FREQUENCY))))
                   ;; By TREES index: conifer, oak, juniper, mesquite.
                   (weights (list (* forest (+ w-snowy (* w-grass mountain)))
                                  (* forest w-grass (- 1.0 mountain))
                                  (* JUNIPER-CHANCE w-dry)
                                  (* MESQUITE-CHANCE w-desert)))
                   (chance (* (apply + weights) (- 1.0 (ramp TREE-LINE h)))))
              (when (and (> chance 0.0)
                         (> h (+ SEA-LEVEL TREE-SHORE))
                         (< (cadr g) TREE-MAX-GRADIENT)
                         (< (rand 0) chance))
                (let* ((kind (pick-weighted weights (rand 3)))
                       (scale (add! TREES TREE-TEMPLATES TREE-VARIANTS kind rand lx h (cadr g) lz)))
                  (set! trunks (cons (list (+ ox lx) (+ oz lz)
                                           (* scale (list-ref (vector-ref TREES kind) 4)))
                                     trunks)))))))
        (and (pair? parts)
             (let ((parts (reverse parts)))
               (append
                 (map (lambda (pick) (apply vector-append (map pick parts)))
                      (list car cadr (lambda (p) (list-ref p 2)) (lambda (p) (list-ref p 3))
                            (lambda (p) (list-ref p 4))))
                 (list trunks))))))))
