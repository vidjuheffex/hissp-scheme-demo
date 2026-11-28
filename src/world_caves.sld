;; Caves: tunnels and caverns behind mouths in canyon walls and cliffs.
;;
;; The terrain is a heightfield, so it can't overhang; caves are meshes of
;; their own. Every cave is a 3D distance field (negative inside) made of
;; tunnels, chains of capsules with flat floors, and caverns, flat-floored
;; blobs, blended with a smooth minimum and roughened with 3D noise.
;;
;; Caves start from sites on a SITE-meter grid. A site looks along a few
;; rays for a wall (a sharp rise, as canyons and escarpments have) with a
;; dry foot. Where it finds one, it may get a cave: a small grotto, a
;; medium tunnel with caverns, or a large network that can join another
;; cave's mouth underground. Every cave stays at least ROOF meters under
;; the ground, except around its mouths, and above the sea.
;;
;; The solid is "under the terrain and not in a cave". A chunk a cave
;; reaches is drawn as one mesh of that solid, made with surface nets on
;; the worker thread, in place of its terrain: the ground, the mouth with
;; its hole and the cave inside are one surface, and walking follows the
;; same field. Where no cave comes near, the mesh is the terrain's own.
;; Like the terrain library, no engine imports here.

(define-library (world caves)
  (export cave-chunk-data
          mouth-clearing
          cave-ground
          cave-headroom?
          cave-depth
          cave-shelter
          caves-ready-near!
          find-cave-site
          cave-size-near
          site-cave
          capsule
          solid-field)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (srfi 69)
          (only (srfi 1) filter)
          (only random Random)
          (rename (only math floor sin sqrt) (floor fast-floor) (sin fast-sin) (sqrt fast-sqrt))
          (rename (only builtins max min) (max fast-max) (min fast-min))
          (world terrain))
  (begin
    (define PI 3.141592653589793)

    (define SITE 160.0)                  ; meters between cave sites
    (define SITE-CHANCE 0.8)             ; of sites with a wall, how many get a cave
    (define RAY 60)                      ; meters each wall search looks
    (define WALL-RISE 6.0)               ; a wall rises this much within two meters
    (define ROOF 2.5)                    ; rock left over caves, away from mouths
    (define MIN-ROOF 1.0)                ; the thinnest rock left over a cave
    (define MAX-TILT 2.5)                ; most the roof deepens under steep ground
    (define MOUTH-ROOF (list 4.0 10.0))  ; meters from a mouth over which the roof thickens to ROOF
    (define MOUTH-EXIT (list 1.0 4.0))   ; meters in from a mouth over which the roof comes in
    (define MOUTH-SIDE (list 4.0 7.0))   ; meters either side of a mouth's line, the same
    (define APRON 3.5)                   ; meters out from a mouth where its floor meets the ground
    (define FLOOR-ABOVE-SEA 0.3)
    (define FLOOR-DROP 0.55)             ; tunnel floors sit this many radii under the middle
    (define SLOPE 0.3)                   ; most a tunnel climbs or drops per meter
    (define CROSS-GAP 1.0)               ; rock left between tunnels that pass over each other
    (define BLEND 1.5)                   ; smooth-minimum width where shapes meet
    (define MOUTH-BLEND 1.0)             ; rounds the junction of cave and ground
    (define ROUGH 0.45)                  ; wall roughness, meters either way
    (define ROUGH-FREQUENCY 0.35)
    (define BAND 1.0)                    ; meters sampled past each shape's surface
    (define DARK (list 2.0 20.0))        ; meters from a mouth, from daylight to dark
    (define SHELTER (list 0.5 3.0))      ; meters in under the rock, from open sky to sheltered

    (define (clamp01 x) (max 0.0 (min 1.0 x)))
    (define (lerp a b t) (+ a (* (- b a) t)))
    (define (fade t) (* t t (- 3.0 (* 2.0 t))))
    (define (ramp lo hi x) (fade (clamp01 (/ (- x lo) (- hi lo)))))

    (define (smooth-min a b k)
      (let ((e (- k (if (< a b) (- b a) (- a b))))
            (low (if (< a b) a b)))
        (if (> e 0.0) (- low (/ (* e e) (* 4.0 k))) low)))

    ;; --- 3D value noise ------------------------------------------------------
    ;;
    ;; Written out in full: this runs for every grid point of every cave
    ;; chunk, and a Scheme procedure call costs more than the arithmetic.

    (define (noise3 x y z)
      (let* ((ix (fast-floor x)) (iy (fast-floor y)) (iz (fast-floor z))
             (fu (- x ix)) (fv (- y iy)) (fw (- z iz))
             (u (* fu fu (- 3.0 (* 2.0 fu))))
             (v (* fv fv (- 3.0 (* 2.0 fv))))
             (w (* fw fw (- 3.0 (* 2.0 fw))))
             (jx (+ ix 1.0)) (jy (+ iy 1.0)) (jz (+ iz 1.0))
             (h000 (let ((s (* (fast-sin (+ (* ix 127.1) (* iy 269.5) (* iz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h001 (let ((s (* (fast-sin (+ (* ix 127.1) (* iy 269.5) (* jz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h010 (let ((s (* (fast-sin (+ (* ix 127.1) (* jy 269.5) (* iz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h011 (let ((s (* (fast-sin (+ (* ix 127.1) (* jy 269.5) (* jz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h100 (let ((s (* (fast-sin (+ (* jx 127.1) (* iy 269.5) (* iz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h101 (let ((s (* (fast-sin (+ (* jx 127.1) (* iy 269.5) (* jz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h110 (let ((s (* (fast-sin (+ (* jx 127.1) (* jy 269.5) (* iz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (h111 (let ((s (* (fast-sin (+ (* jx 127.1) (* jy 269.5) (* jz 311.7))) 43758.5453))) (- s (fast-floor s))))
             (a00 (+ h000 (* (- h100 h000) u)))
             (a10 (+ h010 (* (- h110 h010) u)))
             (a01 (+ h001 (* (- h101 h001) u)))
             (a11 (+ h011 (* (- h111 h011) u)))
             (b0 (+ a00 (* (- a10 a00) v)))
             (b1 (+ a01 (* (- a11 a01) v))))
        (+ b0 (* (- b1 b0) w))))

    ;; The walls' roughness at (x, y, z), ROUGH meters either way.
    (define (rough x y z)
      (* ROUGH (- (* 2.0 (noise3 (* x ROUGH-FREQUENCY) (* y ROUGH-FREQUENCY) (* z ROUGH-FREQUENCY)))
                  1.0)))

    ;; --- sites and walls -----------------------------------------------------

    (define (site-rng cx cz salt)
      (let ((o (seed-offset)))
        (Random (exact (floor (* 1e9 (hash2 (+ (* cx 1.731) (* 0.0137 (car o)) salt)
                                            (+ (* cz 2.917) (* 0.0173 (cadr o))))))))))

    (define (uniform rng lo hi) (call-method rng 'uniform lo hi))
    (define (chance? rng p) (< (call-method rng 'random) p))
    (define (pick rng lo hi) (call-method rng 'randint lo hi))

    ;; A site's mouth: #(x floor z dx dz), the foot of a wall and the way
    ;; into it, or #f. Searching is slow (60 terrain heights a ray), so
    ;; results are kept; sites far from any channel or cliff country skip it.
    (define mouths (make-hash-table))

    (define (search-mouth cx cz)
      (let* ((rng (site-rng cx cz 0.0))
             (px (* SITE (+ cx 0.15 (* 0.7 (call-method rng 'random)))))
             (pz (* SITE (+ cz 0.15 (* 0.7 (call-method rng 'random)))))
             (a0 (* 2.0 PI (call-method rng 'random)))
             (heights (make-vector (+ RAY 3) 0.0)))
        (and (wall-country? px pz (+ RAY 20.0))
             (let try ((n 0))
               (and (< n 3)
                    (let* ((a (+ a0 (* n 2.0944)))
                           (dx (cos a))
                           (dz (sin a)))
                      (do ((i 0 (+ i 1))) ((= i (+ RAY 3)))
                        (vector-set! heights i (terrain-height (+ px (* dx i)) (+ pz (* dz i)))))
                      (let scan ((i 0))
                        (if (>= i RAY)
                            (try (+ n 1))
                            (let* ((h (vector-ref heights i))
                                   (j (if (> (- (vector-ref heights (+ i 1)) h) 1.5) i (+ i 1))))
                              (if (and (>= (- (vector-ref heights (+ i 2)) h) WALL-RISE)
                                       (>= (- (vector-ref heights (+ i 3)) h) WALL-RISE)
                                       (> h (+ SEA-LEVEL FLOOR-ABOVE-SEA))
                                       ;; not up on a ledge you can't walk to
                                       (< (- h (terrain-height (+ px (* dx (- i 3))) (+ pz (* dz (- i 3))))) 3.0)
                                       ;; The apron can fit on a narrow shelf with a sheer
                                       ;; drop just outside it. Check the approach as well.
                                       (< (- (vector-ref heights j)
                                             (if (>= j 6) (vector-ref heights (- j 6))
                                                 (terrain-height (+ px (* dx (- j 6))) (+ pz (* dz (- j 6))))))
                                          3.0))
                                  (vector (+ px (* dx j)) (+ (vector-ref heights j) 0.1)
                                          (+ pz (* dz j)) dx dz)
                                  (scan (+ i 1))))))))))))

    (define (site-mouth cx cz)
      (let ((key (list cx cz)))
        (if (hash-table-exists? mouths key)
            (hash-table-ref mouths key)
            (let ((mouth (search-mouth cx cz)))
              (hash-table-set! mouths key mouth)
              mouth))))

    (define (site-has-cave? cx cz)
      (and (site-mouth cx cz)
           (chance? (site-rng cx cz 7.0) SITE-CHANCE)))

    ;; --- layout ----------------------------------------------------------------
    ;;
    ;; A cave is #(prims mouths openings box size caverns site): prims a
    ;; vector of shapes, mouths the #(x floor z dx dz) it cuts into walls,
    ;; openings every mouth it reaches (for how dark it gets), box
    ;; (x0 z0 x1 z1), caverns its blobs.
    ;;
    ;; Shapes are vectors: #(0 ax ay az bx by bz r x0 y0 z0 x1 y1 z1 bax bay baz inv)
    ;; for a tunnel segment between centres a and b, radius r; and
    ;; #(1 cx cy cz rx ry rz rmin x0 y0 z0 x1 y1 z1) for a cavern.

    (define (capsule ax ay az bx by bz r)
      (let ((bax (- bx ax)) (bay (- by ay)) (baz (- bz az)) (pad (+ r BAND ROUGH)))
        (vector 0 ax ay az bx by bz r
                (- (min ax bx) pad) (- (min ay by) pad) (- (min az bz) pad)
                (+ (max ax bx) pad) (+ (max ay by) pad) (+ (max az bz) pad)
                bax bay baz (/ 1.0 (max 1e-6 (+ (* bax bax) (* bay bay) (* baz baz)))))))

    (define (blob cx cy cz rx ry rz)
      (let ((px (+ rx BAND ROUGH)) (py (+ ry BAND ROUGH)) (pz (+ rz BAND ROUGH)))
        (vector 1 cx cy cz rx ry rz (min rx ry rz)
                (- cx px) (- cy py) (- cz pz) (+ cx px) (+ cy py) (+ cz pz))))

    ;; Nodes are #(x floor z r). A tunnel between two has its middle line
    ;; FLOOR-DROP radii over the floors.
    (define (tunnel a b)
      (let ((r (vector-ref b 3)))
        (capsule (vector-ref a 0) (+ (vector-ref a 1) (* FLOOR-DROP r)) (vector-ref a 2)
                 (vector-ref b 0) (+ (vector-ref b 1) (* FLOOR-DROP r)) (vector-ref b 2)
                 r)))

    ;; The highest a floor at (x, z) can be under radius `r` with `roof`
    ;; meters of rock left, or #f when that would be under the sea.
    (define (roofed-floor x z floor r roof)
      (let ((top (- (terrain-height x z) (* roof (terrain-tilt x z)) (* (+ 1.0 FLOOR-DROP) r))))
        (let ((f (min floor top)))
          (and (>= f (+ SEA-LEVEL FLOOR-ABOVE-SEA)) f))))

    ;; The floor of a tunnel or cavern in `prims` that a tube of radius `r`
    ;; with its floor at `floor` would run into at (x, z), or #f. Tubes that
    ;; pass clear over or under each other are left alone.
    (define (crossed-floor prims x z floor r)
      (let loop ((k 0))
        (and (< k (vector-length prims))
             (let* ((p (vector-ref prims k))
                    (hit
                      (if (eqv? (vector-ref p 0) 0)
                          (let* ((ax (vector-ref p 1)) (az (vector-ref p 3))
                                 (bax (vector-ref p 14)) (baz (vector-ref p 16))
                                 (t (clamp01 (/ (+ (* (- x ax) bax) (* (- z az) baz))
                                                (max 1e-6 (+ (* bax bax) (* baz baz))))))
                                 (r2 (vector-ref p 7))
                                 (f2 (- (+ (vector-ref p 2) (* t (vector-ref p 15))) (* FLOOR-DROP r2))))
                            (and (< (sqrt (+ (square (- x (+ ax (* t bax)))) (square (- z (+ az (* t baz))))))
                                    (+ r r2))
                                 (< floor (+ f2 (* (+ 1.0 FLOOR-DROP) r2) CROSS-GAP))
                                 (> (+ floor (* (+ 1.0 FLOOR-DROP) r) CROSS-GAP) f2)
                                 f2))
                          (let ((f2 (- (vector-ref p 2) (* 0.5 (vector-ref p 5)))))
                            (and (< (+ (square (/ (- x (vector-ref p 1)) (+ (vector-ref p 4) r)))
                                       (square (/ (- z (vector-ref p 3)) (+ (vector-ref p 6) r))))
                                    1.0)
                                 (< floor (+ (vector-ref p 2) (vector-ref p 5) CROSS-GAP))
                                 (> (+ floor (* (+ 1.0 FLOOR-DROP) r) CROSS-GAP) f2)
                                 f2)))))
               (or hit (loop (+ k 1)))))))

    ;; Grows a tunnel from node `start`, heading `heading` radians, for up
    ;; to `count` segments; stops early where the rock gets too thin.
    ;; `target`, if given, is #(x floor z) to steer for. Where it would run
    ;; into one of `prims`, it meets that one's floor instead. Returns the
    ;; new nodes in order.
    (define (grow rng start heading count lengths radii target prims)
      (let loop ((node start) (heading heading) (n 0) (out '()))
        (if (= n count)
            (reverse out)
            (let* ((heading (if target
                                (+ (atan (- (vector-ref target 2) (vector-ref node 2))
                                         (- (vector-ref target 0) (vector-ref node 0)))
                                   (uniform rng -0.25 0.25))
                                (+ heading (uniform rng -0.7 0.7))))
                   (len (uniform rng (car lengths) (cadr lengths)))
                   (r (uniform rng (car radii) (cadr radii)))
                   (x (+ (vector-ref node 0) (* len (cos heading))))
                   (z (+ (vector-ref node 2) (* len (sin heading))))
                   (nf (vector-ref node 1))
                   (want (if target
                             (+ nf (max (* (- SLOPE) len) (min (* SLOPE len) (- (vector-ref target 1) nf))))
                             (max (+ SEA-LEVEL FLOOR-ABOVE-SEA 0.1)
                                  (+ nf (* len (uniform rng (- SLOPE) SLOPE))))))
                   (mx (* 0.5 (+ x (vector-ref node 0)))) (mz (* 0.5 (+ z (vector-ref node 2))))
                   ;; Meeting a tunnel halfway sets the slope to reach its floor there.
                   (want (let ((at-mid (crossed-floor prims mx mz (* 0.5 (+ nf want)) r)))
                           (if at-mid
                               (+ nf (* 2.0 (- at-mid nf)))
                               (or (crossed-floor prims x z want r) want))))
                   (mid (roofed-floor mx mz (* 0.5 (+ nf want)) r ROOF))
                   (floor (and mid (roofed-floor x z (+ nf (* 2.0 (- mid nf))) r ROOF))))
              (if (and floor (<= (abs (- floor nf)) (* SLOPE len)))
                  (let ((next (vector x floor z r)))
                    (if (and target
                             (< (+ (square (- x (vector-ref target 0))) (square (- z (vector-ref target 2))))
                                144.0))
                        (reverse (cons next out))
                        (loop next heading (+ n 1) (cons next out))))
                  (reverse out))))))

    ;; A cavern on node `node`, if the rock over it is thick enough.
    (define (cavern rng node size)
      (let* ((x (vector-ref node 0)) (floor (vector-ref node 1)) (z (vector-ref node 2))
             (big (if (eq? size 'small) 0.6 1.0))
             (rx (* big (uniform rng 5.0 9.0)))
             (rz (* big (uniform rng 5.0 9.0)))
             (low (min (terrain-height x z)
                       (terrain-height (+ x rx) z) (terrain-height (- x rx) z)
                       (terrain-height x (+ z rz)) (terrain-height x (- z rz))))
             (ry (min (* big (uniform rng 3.0 5.5)) (/ (- low ROOF floor) 1.5))))
        (and (>= ry 2.2)
             (blob x (+ floor (* 0.5 ry)) z rx ry rz))))

    (define SIZES
      ;; size share segments lengths radii caverns branches
      (list (list 'small 0.35 '(2 3) '(4.0 7.0) '(1.6 2.1) '(1 1) '(0 0))
            (list 'medium 0.8 '(5 10) '(8.0 14.0) '(1.7 2.6) '(1 3) '(0 1))
            (list 'large 1.0 '(12 20) '(9.0 15.0) '(1.8 3.0) '(3 6) '(2 4))))

    (define (layout cx cz)
      (let* ((mouth (site-mouth cx cz))
             (rng (site-rng cx cz 3.0))
             (u (call-method rng 'random))
             (spec (let find ((s SIZES)) (if (or (null? (cdr s)) (< u (cadr (car s)))) (car s) (find (cdr s)))))
             (size (car spec))
             (range-of (lambda (k) (let ((r (list-ref spec k))) (pick rng (car r) (cadr r)))))
             (mx (vector-ref mouth 0)) (y0 (vector-ref mouth 1)) (mz (vector-ref mouth 2))
             (dx (vector-ref mouth 3)) (dz (vector-ref mouth 4))
             (heading (atan dz dx))
             (r0 (uniform rng 1.7 2.2))
             (outside (vector (- mx (* 2.5 dx)) y0 (- mz (* 2.5 dz)) r0))
             (len0 (uniform rng 5.0 8.0))
             (inside (let ((x (+ mx (* len0 dx))) (z (+ mz (* len0 dz))))
                       (let ((f (roofed-floor x z y0 r0 1.0)))
                         (and f (vector x f z r0))))))
        (and inside
             (let* ((main (cons outside (cons inside
                                              (grow rng inside heading (range-of 2)
                                                    (list-ref spec 3) (list-ref spec 4) #f (vector)))))
                    (nodes (list->vector main))
                    (prims (vector))
                    (caverns (vector))
                    (openings (list mouth)))
               (define (add-chain! chain)
                 (let loop ((c chain))
                   (when (and (pair? c) (pair? (cdr c)))
                     (call-method prims 'append (tunnel (car c) (cadr c)))
                     (loop (cdr c)))))
               (add-chain! main)
               ;; Caverns on nodes past the mouth, always one at the end.
               (let ((count (range-of 5)) (n (vector-length nodes)))
                 (when (> n 2)
                   (do ((k 0 (+ k 1))) ((= k count))
                     (let* ((at (if (= k 0) (- n 1) (pick rng 2 (- n 1))))
                            (c (cavern rng (vector-ref nodes at) size)))
                       (when c
                         (call-method prims 'append c)
                         (call-method caverns 'append c))))))
               ;; Side branches from nodes past the mouth.
               (let ((count (range-of 6)) (n (vector-length nodes)))
                 (when (> n 3)
                   (do ((k 0 (+ k 1))) ((= k count))
                     (let* ((from (vector-ref nodes (pick rng 2 (- n 1))))
                            (branch (grow rng from (* 2.0 PI (call-method rng 'random)) (pick rng 3 7)
                                          (list-ref spec 3) (list-ref spec 4) #f prims)))
                       (add-chain! (cons from branch))
                       (when (and (pair? branch) (chance? rng 0.5))
                         (let ((c (cavern rng (car (reverse branch)) size)))
                           (when c
                             (call-method prims 'append c)
                             (call-method caverns 'append c))))))))
               ;; A large cave reaches for the nearest other cave's mouth.
               (when (eq? size 'large)
                 (let ((other (nearest-other-mouth cx cz mx mz)))
                   (when other
                     (let* ((target (vector (+ (vector-ref other 0) (* 4.0 (vector-ref other 3)))
                                            (vector-ref other 1)
                                            (+ (vector-ref other 2) (* 4.0 (vector-ref other 4)))))
                            (from (vector-ref nodes (- (vector-length nodes) 1)))
                            (link (grow rng from 0.0 30 '(8.0 12.0) (list-ref spec 4) target prims)))
                       (add-chain! (cons from link))
                       (when (and (pair? link)
                                  (let ((end (car (reverse link))))
                                    (< (+ (square (- (vector-ref end 0) (vector-ref target 0)))
                                          (square (- (vector-ref end 2) (vector-ref target 2))))
                                       144.0)))
                         (let ((end (car (reverse link))))
                           (call-method prims 'append
                                        (tunnel end (vector (vector-ref target 0) (vector-ref target 1)
                                                            (vector-ref target 2) (vector-ref end 3))))
                           (set! openings (cons other openings))))))))
               (let loop ((k 0) (x0 1e9) (z0 1e9) (x1 -1e9) (z1 -1e9))
                 (if (= k (vector-length prims))
                     (vector prims (list mouth) openings (list x0 z0 x1 z1) size caverns
                             (list cx cz))
                     (let ((p (vector-ref prims k)))
                       (loop (+ k 1)
                             (min x0 (vector-ref p 8)) (min z0 (vector-ref p 10))
                             (max x1 (vector-ref p 11)) (max z1 (vector-ref p 13))))))))))

    (define (nearest-other-mouth cx cz mx mz)
      (let loop ((dx -1) (dz -1) (best #f) (best-d (square 200.0)))
        (cond ((> dz 1) best)
              ((> dx 1) (loop -1 (+ dz 1) best best-d))
              ((and (= dx 0) (= dz 0)) (loop (+ dx 1) dz best best-d))
              (else
                (let ((m (and (site-has-cave? (+ cx dx) (+ cz dz)) (site-mouth (+ cx dx) (+ cz dz)))))
                  (if m
                      (let ((d (+ (square (- (vector-ref m 0) mx)) (square (- (vector-ref m 2) mz)))))
                        (if (< d best-d)
                            (loop (+ dx 1) dz m d)
                            (loop (+ dx 1) dz best best-d)))
                      (loop (+ dx 1) dz best best-d)))))))

    (define caves (make-hash-table))

    (define (site-cave cx cz)
      (let ((key (list cx cz)))
        (if (hash-table-exists? caves key)
            (hash-table-ref caves key)
            (let ((cave (and (site-has-cave? cx cz) (layout cx cz))))
              (hash-table-set! caves key cave)
              cave))))

    ;; Caves can reach this far from their site's cell.
    (define REACH 2)

    ;; Caves whose box comes within `pad` of the box (x0 z0 x1 z1). With
    ;; `cached-only`, sites not laid out yet are skipped, so it's quick.
    (define (caves-in x0 z0 x1 z1 pad cached-only)
      (let ((c0x (- (exact (floor (/ x0 SITE))) REACH)) (c1x (+ (exact (floor (/ x1 SITE))) REACH))
            (c0z (- (exact (floor (/ z0 SITE))) REACH)) (c1z (+ (exact (floor (/ z1 SITE))) REACH)))
        (let loop ((cx c0x) (cz c0z) (out '()))
          (cond ((> cz c1z) out)
                ((> cx c1x) (loop c0x (+ cz 1) out))
                (else
                  (let ((cave (if cached-only
                                  (hash-table-ref/default caves (list cx cz) #f)
                                  (site-cave cx cz))))
                    (loop (+ cx 1) cz
                          (if (and cave
                                   (let ((b (vector-ref cave 3)))
                                     (and (< (- (car b) pad) x1) (> (+ (list-ref b 2) pad) x0)
                                          (< (- (cadr b) pad) z1) (> (+ (list-ref b 3) pad) z0))))
                              (cons cave out)
                              out))))))))

    ;; Lays out the caves around (x, z) so `cave-ground` and friends see
    ;; them. The chunk worker does this as it builds; the REPL helpers too.
    (define (caves-ready-near! x z)
      (caves-in x z x z 0.0 #f))

    ;; --- the field -----------------------------------------------------------
    ;;
    ;; A field context is #(prims openings): every shape and opening of the
    ;; caves that matter somewhere.

    (define (context-of cave-list)
      (let ((prims (vector)) (openings '()))
        (for-each (lambda (cave)
                    (call-method prims 'extend (vector-ref cave 0))
                    (set! openings (append (vector-ref cave 2) openings)))
                  cave-list)
        (vector prims openings)))

    ;; Signed distance from shape `p` at (x, y, z), roughness `n`: the wall
    ;; or the flat floor, whichever is nearer the open space.
    (define (prim-distance p x y z n)
      (if (eqv? (vector-ref p 0) 0)
          (let* ((ax (vector-ref p 1)) (ay (vector-ref p 2)) (az (vector-ref p 3))
                 (bax (vector-ref p 14)) (bay (vector-ref p 15)) (baz (vector-ref p 16))
                 (s (* (+ (* (- x ax) bax) (* (- y ay) bay) (* (- z az) baz)) (vector-ref p 17)))
                 (t (if (< s 0.0) 0.0 (if (> s 1.0) 1.0 s)))
                 (qx (- x (+ ax (* t bax))))
                 (cy (+ ay (* t bay)))
                 (qy (- y cy))
                 (qz (- z (+ az (* t baz))))
                 (r (vector-ref p 7)))
            (fast-max (+ (- (fast-sqrt (+ (* qx qx) (* qy qy) (* qz qz))) r) n)
                 (+ (- cy (* FLOOR-DROP r) y) (* 0.15 n))))
          (let* ((ry (vector-ref p 5))
                 (cy (vector-ref p 2))
                 (qx (/ (- x (vector-ref p 1)) (vector-ref p 4)))
                 (qy (/ (- y cy) ry))
                 (qz (/ (- z (vector-ref p 3)) (vector-ref p 6))))
            (fast-max (+ (* (- (fast-sqrt (+ (* qx qx) (* qy qy) (* qz qz))) 1.0) (vector-ref p 7)) n)
                 (+ (- cy (* 0.5 ry) y) (* 0.15 n))))))

    (define (in-box? p x y z)
      (and (> x (vector-ref p 8)) (< x (vector-ref p 11))
           (> y (vector-ref p 9)) (< y (vector-ref p 12))
           (> z (vector-ref p 10)) (< z (vector-ref p 13))))

    ;; Signed distance to the caves' open space at (x, y, z), negative
    ;; inside; 1e9 away from every shape's box. Shapes blend in order.
    (define (cave-distance prims x y z)
      (let ((n #f) (acc 1e9) (count (vector-length prims)))
        (do ((k 0 (+ k 1))) ((= k count) acc)
          (let ((p (vector-ref prims k)))
            (when (in-box? p x y z)
              (unless n (set! n (rough x y z)))
              (set! acc (smooth-min acc (prim-distance p x y z n) BLEND)))))))

    (define (nearest-opening openings x y z)
      (let loop ((o openings) (best 1e9))
        (if (null? o)
            (sqrt best)
            (let ((m (car o)))
              (loop (cdr o)
                    (min best (+ (square (- x (vector-ref m 0))) (square (- y (vector-ref m 1) 1.5))
                                 (square (- z (vector-ref m 2))))))))))

    (define (nearest-mouth-flat openings x z)
      (let loop ((o openings) (best 1e9))
        (if (null? o)
            (sqrt best)
            (let ((m (car o)))
              (loop (cdr o) (min best (+ (square (- x (vector-ref m 0))) (square (- z (vector-ref m 2))))))))))

    ;; How much deeper than the rock is thick the ground is over a point,
    ;; where it slopes `gx` and `gz`: rock under a steep face is thinner
    ;; than its depth.
    (define (tilt gx gz)
      (fast-min MAX-TILT (fast-sqrt (+ 1.0 (* gx gx) (* gz gz)))))

    (define (terrain-tilt x z)
      (tilt (- (terrain-height (+ x 0.5) z) (terrain-height (- x 0.5) z))
            (- (terrain-height x (+ z 0.5)) (terrain-height x (- z 0.5)))))

    ;; The limits on the cave field at (x, z), as #(roof dig top): open space
    ;; only under the ground less `roof` (ROOF, thinning toward a mouth),
    ;; and, where the ground is under `top`, no deeper than `dig` under it.
    ;; Rock left over a cave is never thinner than MIN-ROOF, thinner and the
    ;; mesh's grid would miss it or pinch it, except where a tunnel comes
    ;; out through its wall: there it comes in from none, straight in from
    ;; the mouth only, so the ground beside and above isn't cut open.
    ;; `slant` is the ground's tilt.
    ;; Out in front of a mouth `dig` comes up to nothing APRON meters out, so
    ;; the floor rises to meet the ground; `top`, a little over the mouth's
    ;; floor, leaves the wall above alone.
    (define (roof-at openings x z slant)
      (let loop ((o openings) (dig 1e9) (top -1e9) (exit 1.0))
        (if (null? o)
            (vector (* slant exit
                       (fast-max MIN-ROOF
                                 (* ROOF (ramp (car MOUTH-ROOF) (cadr MOUTH-ROOF) (nearest-mouth-flat openings x z)))))
                    dig top)
            (let* ((m (car o))
                   (rx (- x (vector-ref m 0))) (rz (- z (vector-ref m 2)))
                   (along (+ (* rx (vector-ref m 3)) (* rz (vector-ref m 4))))
                   (side (abs (- (* rz (vector-ref m 3)) (* rx (vector-ref m 4)))))
                   (back (fast-max 0.0 (+ along 1.5)))
                   (d (+ (* 0.6 (+ along APRON)) (* 3.0 back back) (* 3.0 (fast-max 0.0 (- side 7.0)))))
                   (exit (fast-min exit (fast-max (ramp (car MOUTH-EXIT) (cadr MOUTH-EXIT) along)
                                                  (ramp (car MOUTH-SIDE) (cadr MOUTH-SIDE) side)))))
              (if (and (< side 10.0) (< along 0.0) (< d dig))
                  (loop (cdr o) d (+ (vector-ref m 1) 1.5) exit)
                  (loop (cdr o) dig top exit))))))

    (define (with-roof c y ground limits)
      (if (>= c 1e8)
          c
          (let ((c (fast-max c (+ (- y ground) (vector-ref limits 0)))))
            (if (< ground (vector-ref limits 2))
                (fast-max c (- ground (vector-ref limits 1) y))
                c))))

    ;; Walking asks about one (x, z) many times over.
    (define last-limits (list #f #f #f #f))

    (define (limits-at ctx x z)
      (let ((last last-limits))
        (if (and (eq? (car last) ctx) (eqv? (cadr last) x) (eqv? (list-ref last 2) z))
            (list-ref last 3)
            (let ((limits (roof-at (vector-ref ctx 1) x z (terrain-tilt x z))))
              (set! last-limits (list ctx x z limits))
              limits))))

    (define (roofed ctx x y z ground)
      (with-roof (cave-distance (vector-ref ctx 0) x y z) y ground (limits-at ctx x z)))

    ;; Positive in open air and caves, negative in rock. A smooth union
    ;; rounds the mouth instead of leaving a thin wedge where the two
    ;; surfaces meet. Walking and meshing use the same blend.
    (define (solid-field ctx x y z ground)
      (surface-field y ground (roofed ctx x y z ground)))

    (define (surface-field y ground cave)
      (- (smooth-min (- ground y) cave MOUTH-BLEND)))

    ;; --- walking and darkness ------------------------------------------------

    ;; The context around the player, kept until they move to another cell.
    (define here-key #f)
    (define here-ctx #f)

    (define (context-near x z)
      (let ((key (list (exact (floor (/ x 16.0))) (exact (floor (/ z 16.0))) (hash-table-size caves))))
        (unless (equal? key here-key)
          (set! here-key key)
          (let ((near (caves-in (- x 24.0) (- z 24.0) (+ x 24.0) (+ z 24.0) 0.0 #t)))
            (set! here-ctx (and (pair? near) (context-of near)))))
        here-ctx))

    (define (box-has? ctx x z)
      (let ((prims (vector-ref ctx 0)))
        (let loop ((k 0))
          (and (< k (vector-length prims))
               (let ((p (vector-ref prims k)))
                 (or (and (> x (vector-ref p 8)) (< x (vector-ref p 11))
                          (> z (vector-ref p 10)) (< z (vector-ref p 13)))
                     (loop (+ k 1))))))))

    ;; The ground under feet at height `feet` in (x, z) where a cave could
    ;; change it, or #f to use `ground` (the terrain height) as it is. From
    ;; just over knee height it looks down for the first floor; started in
    ;; rock (a cave wall, or the wall over a mouth) it looks up for the top
    ;; instead, which the climb limit then refuses.
    (define (cave-ground x z feet ground)
      (let ((ctx (context-near x z)))
        (and ctx (box-has? ctx x z)
             (let* ((field (lambda (y) (solid-field ctx x y z ground)))
                    (start (+ feet 1.0))
                    (open? (> (field start) 0.0)))
               (let march ((y start) (n 0))
                 (let ((next (if open? (- y 0.3) (+ y 0.3))))
                   (cond ((> n 200) #f)
                         ((eq? open? (> (field next) 0.0)) (march next (+ n 1)))
                         (else
                           ;; Bisect between the last open and solid heights.
                           (let refine ((hi (if open? y next)) (lo (if open? next y)) (k 0))
                             (if (= k 7)
                                 (* 0.5 (+ hi lo))
                                 (let ((mid (* 0.5 (+ hi lo))))
                                   (if (> (field mid) 0.0)
                                       (refine mid lo (+ k 1))
                                       (refine hi mid (+ k 1))))))))))))))

    ;; Is there room to stand at floor `floor` in (x, z)? The field is about
    ;; the distance to rock, so the eyes (2 m up) keep EYE-ROOM from walls
    ;; that lean in over the feet, as well as from the ceiling. Where a
    ;; mouth's tunnel comes up through the ground the field is near nothing
    ;; along the ground's line with open space either side, so there the
    ;; eyes go by the distance to the tunnel's walls instead.
    (define EYE-ROOM 0.25)

    (define (cave-headroom? x z floor ground)
      (let ((ctx (context-near x z)))
        (or (not ctx) (not (box-has? ctx x z))
            (let ((eyes (+ floor 2.0)))
              (and (> (solid-field ctx x (+ floor 1.0) z ground) 0.0)
                   (let ((open (solid-field ctx x eyes z ground)))
                     (or (> open EYE-ROOM)
                         (and (> open 0.0)
                              (> (solid-field ctx x (+ eyes EYE-ROOM) z ground) 0.0)
                              (< (cave-distance (vector-ref ctx 0) x eyes z) (- EYE-ROOM))))))))))

    ;; 0 outside caves, rising to 1 deep inside, at (x, y, z).
    (define (cave-depth x y z ground)
      (let ((ctx (context-near x z)))
        (if (and ctx (box-has? ctx x z) (< (roofed ctx x y z ground) 0.0))
            (ramp (car DARK) (cadr DARK) (nearest-opening (vector-ref ctx 1) x y z))
            0.0)))

    ;; 0 out in the open, rising to 1 a few meters in under a cave's rock.
    (define (cave-shelter x y z ground)
      (let ((ctx (context-near x z)))
        (if (and ctx (> ground (+ y 0.5)) (box-has? ctx x z) (< (roofed ctx x y z ground) 0.0))
            (ramp (car SHELTER) (cadr SHELTER) (nearest-opening (vector-ref ctx 1) x y z))
            0.0)))

    ;; --- plants -------------------------------------------------------------

    ;; Plants are kept out of the ground in front of a mouth, `out` meters
    ;; out from the wall and `across` either side, and off ground a cave
    ;; cuts away or comes up just under. A procedure telling whether world
    ;; (x, z) is in a clearing, for the chunk at (ox, oz).
    (define (mouth-clearing ox oz out across)
      (let* ((near (caves-in (- ox out) (- oz out) (+ ox CHUNK-SIZE out) (+ oz CHUNK-SIZE out) out #f))
             (mouths (apply append (map (lambda (c) (vector-ref c 1)) near)))
             (ctx (and (pair? near) (context-of near))))
        (lambda (x z)
          (or (let loop ((m mouths))
                (and (pair? m)
                     (let* ((mo (car m))
                            (rx (- x (vector-ref mo 0))) (rz (- z (vector-ref mo 2)))
                            (along (+ (* rx (vector-ref mo 3)) (* rz (vector-ref mo 4))))
                            (side (- (* rz (vector-ref mo 3)) (* rx (vector-ref mo 4)))))
                       (or (and (> along (- out)) (< along 2.0) (< (abs side) across))
                           (loop (cdr m))))))
              (and ctx (box-has? ctx x z)
                   (let ((h (terrain-height x z)))
                     (< (roofed ctx x (- h 0.5) z h) 0.5)))))))

    ;; --- the chunk mesh --------------------------------------------------------
    ;;
    ;; A chunk a cave reaches draws one mesh in place of its terrain: surface
    ;; nets over the solid field, terrain and caves together, so the ground
    ;; outside, the mouth and the cave are one surface with nothing to stitch.
    ;;
    ;; The grid's points sit halfway between the terrain's height samples, so
    ;; each cell is centred on a terrain vertex. In a column of cells where no
    ;; cave comes within NEAR of the ground, the cells the ground passes
    ;; through all take that terrain vertex, and the mesh there is the
    ;; terrain's own two triangles a cell. So the chunk's edges, which caves
    ;; never reach unless the chunk next door has caves too, meet the plain
    ;; terrain there exactly.

    (define SIDE (+ CHUNK-SIZE 3))       ; height samples a side, from a meter before the chunk
    (define POINTS (- SIDE 1))           ; grid points a side, between the samples
    (define VERTS (+ CHUNK-SIZE 1))      ; terrain vertices a side, and cell columns
    (define NEAR 1.0)                    ; meters from a cave that leave the ground as the terrain's
    ;; The mesh for the chunk at (ox, oz) if a cave reaches it, else #f:
    ;; (vertices normals colors uvs triangles), drawn with the terrain's
    ;; shader in place of the terrain. `heights` are the chunk's height
    ;; samples, SIDE a side from a meter before its corner; `colors` and
    ;; `normals` the terrain's, VERTS a side. The uvs are (depth shelter):
    ;; how dark it is, 0 outside to 1 deep in, and how far in under the
    ;; rock, 0 under the sky to 1.
    (define (cave-chunk-data ox oz heights colors normals pause)
      (let* ((x0 (- ox 1.0)) (z0 (- oz 1.0))
             (near (caves-in x0 z0 (+ x0 SIDE) (+ z0 SIDE) 0.0 #f)))
        (and (pair? near)
             (let* ((ctx (context-of near))
                    (prims (let ((out (vector)))
                             (vector-for-each
                               (lambda (p)
                                 (when (and (< (vector-ref p 8) (+ x0 SIDE)) (> (vector-ref p 11) x0)
                                            (< (vector-ref p 10) (+ z0 SIDE)) (> (vector-ref p 13) z0))
                                   (call-method out 'append p)))
                               (vector-ref ctx 0))
                             out)))
               (and (> (vector-length prims) 0)
                    (chunk-surface ox oz heights colors normals (vector prims (vector-ref ctx 1)) pause))))))

    (define (chunk-surface ox oz heights colors normals ctx pause)
      (let* ((x0 (- ox 1.0)) (z0 (- oz 1.0))
             (prims (vector-ref ctx 0))
             (openings (vector-ref ctx 1))
             (low (let loop ((k 0) (lo 1e9))
                    (if (= k (vector-length heights)) lo (loop (+ k 1) (fast-min lo (vector-ref heights k))))))
             (high (let loop ((k 0) (hi -1e9))
                     (if (= k (vector-length heights)) hi (loop (+ k 1) (fast-max hi (vector-ref heights k))))))
             (ylo (exact (floor (let loop ((k 0) (lo (- low 3.0)))
                                  (if (= k (vector-length prims)) lo
                                      (loop (+ k 1) (fast-min lo (vector-ref (vector-ref prims k) 9))))))))
             (yhi (exact (ceiling (let loop ((k 0) (hi (+ high 3.0)))
                                    (if (= k (vector-length prims)) hi
                                        (loop (+ k 1) (fast-max hi (vector-ref (vector-ref prims k) 12))))))))
             (ny (+ (- yhi ylo) 1))
             (count (* POINTS POINTS ny))
             (ground (make-vector (* POINTS POINTS) 0.0))   ; the ground at each grid column
             (caved (make-vector (* POINTS POINTS) #f))     ; columns some cave shape reaches
             (acc (make-vector count #f))                   ; the shapes blended so far
             (noise (make-vector count #f))
             (cave (make-vector count #f))                  ; the caves' distance, roofed
             (value (make-vector count #f))                 ; the solid field, where worked out
             (touched (vector))                             ; points with a value, in order
             (purity (make-vector (* VERTS VERTS) 0))       ; cell columns: 0 unknown, 1 pure, 2 not
             (snapped (make-vector (* VERTS VERTS) #f))     ; their terrain vertex, once made
             (cell-vertex (make-vector count #f))
             (vertices (vector)) (normals-out (vector)) (colors-out (vector)) (uvs (vector))
             (tris (vector))
             (tri-count (make-hash-table))
             (face-shaded (make-hash-table)))               ; vertices shaded by their faces
        (define (sample i k) (vector-ref heights (+ i (* k SIDE))))
        (define (at i j k) (+ i (* POINTS (+ k (* POINTS j)))))
        (define (ground-at i k) (vector-ref ground (+ i (* POINTS k))))
        (define (value-at i j k)
          (or (vector-ref value (at i j k)) (- (+ ylo j) (ground-at i k))))
        (define (near-at? i j k)
          (let ((c (vector-ref cave (at i j k)))) (and c (< c NEAR))))
        (define (cell-near? ci cj ck)
          (let loop ((c 0))
            (and (< c 8)
                 (let ((o (vector-ref CORNERS c)))
                   (or (near-at? (+ ci (vector-ref o 0)) (+ cj (vector-ref o 1)) (+ ck (vector-ref o 2)))
                       (loop (+ c 1)))))))
        ;; The cells cell column (ci, ck) has the ground passing through.
        (define (ground-cells ci ck)
          (let* ((g (list (ground-at ci ck) (ground-at (+ ci 1) ck)
                          (ground-at ci (+ ck 1)) (ground-at (+ ci 1) (+ ck 1)))))
            (values (fast-max 0 (- (exact (ceiling (- (apply min g) ylo))) 1))
                    (fast-min (- ny 2) (exact (floor (- (apply max g) ylo)))))))
        ;; Is cell column (ci, ck) left as the terrain: no cave near any cell
        ;; the ground passes through?
        (define (pure? ci ck)
          (let* ((key (+ ci (* VERTS ck))) (known (vector-ref purity key)))
            (if (> known 0)
                (= known 1)
                (let ((pure (or (not (or (vector-ref caved (+ ci (* POINTS ck)))
                                         (vector-ref caved (+ ci 1 (* POINTS ck)))
                                         (vector-ref caved (+ ci (* POINTS (+ ck 1))))
                                         (vector-ref caved (+ ci 1 (* POINTS (+ ck 1))))))
                                (let-values (((j0 j1) (ground-cells ci ck)))
                                  (let loop ((j j0))
                                    (or (> j j1) (and (not (cell-near? ci j ck)) (loop (+ j 1)))))))))
                  (vector-set! purity key (if pure 1 2))
                  pure))))
        (define (snapped? ci cj ck)
          (and (pure? ci ck) (not (cell-near? ci cj ck))))
        (define (touch! n v)
          (vector-set! value n v)
          (call-method touched 'append n))
        ;; Blend shape `p` into the grid points inside its box, as
        ;; `cave-distance` does for walking.
        (define (fill! p)
          (let ((i0 (fast-max 0 (+ (exact (fast-floor (- (vector-ref p 8) x0 0.5))) 1)))
                (i1 (fast-min (- POINTS 1) (- (exact (ceiling (- (vector-ref p 11) x0 0.5))) 1)))
                (j0 (fast-max 0 (+ (exact (fast-floor (- (vector-ref p 9) ylo))) 1)))
                (j1 (fast-min (- ny 1) (- (exact (ceiling (- (vector-ref p 12) ylo))) 1)))
                (k0 (fast-max 0 (+ (exact (fast-floor (- (vector-ref p 10) z0 0.5))) 1)))
                (k1 (fast-min (- POINTS 1) (- (exact (ceiling (- (vector-ref p 13) z0 0.5))) 1))))
            (do ((j j0 (+ j 1))) ((> j j1))
              (let ((y (+ ylo j)))
                (do ((k k0 (+ k 1))) ((> k k1))
                  (let ((z (+ z0 k 0.5)) (row (* POINTS (+ k (* POINTS j)))))
                    (do ((i i0 (+ i 1))) ((> i i1))
                      (let* ((n (+ i row)) (x (+ x0 i 0.5))
                             (d (prim-distance p x y z
                                               (or (vector-ref noise n)
                                                   (let ((r (rough x y z)))
                                                     (vector-set! noise n r)
                                                     r))))
                             (c (vector-ref acc n)))
                        (if c
                            (vector-set! acc n (smooth-min c d BLEND))
                            (begin (vector-set! acc n d)
                                   (vector-set! caved (+ i (* POINTS k)) #t)
                                   (call-method touched 'append n)))))))
                (pause)))))
        (define (add-vertex! x y z normal color uv)
          (let ((v (quotient (vector-length vertices) 3)))
            (call-method vertices 'extend (list (- x ox) y (- z oz)))
            (call-method normals-out 'extend normal)
            (call-method colors-out 'extend color)
            (call-method uvs 'extend uv)
            v))
        ;; The terrain's per-vertex data, `width` numbers a vertex, blended
        ;; to chunk position (u, w).
        (define (terrain-mix source width u w)
          (let* ((u (fast-max 0.0 (fast-min (- CHUNK-SIZE 1e-6) u)))
                 (w (fast-max 0.0 (fast-min (- CHUNK-SIZE 1e-6) w)))
                 (i (fast-floor u)) (k (fast-floor w))
                 (fu (- u i)) (fw (- w k))
                 (a (* width (+ i (* VERTS k)))) (b (+ a width))
                 (c (+ a (* width VERTS))) (d (+ c width)))
            (let loop ((m (- width 1)) (out '()))
              (if (< m 0)
                  out
                  (loop (- m 1)
                        (cons (bilerp (vector-ref source (+ a m)) (vector-ref source (+ b m))
                                      (vector-ref source (+ c m)) (vector-ref source (+ d m)) fu fw)
                              out))))))
        (define (ground-near x z)
          (let* ((u (fast-max 0.0 (fast-min (- SIDE 1.001) (- x x0))))
                 (w (fast-max 0.0 (fast-min (- SIDE 1.001) (- z z0))))
                 (i (fast-floor u)) (k (fast-floor w)))
            (bilerp (sample i k) (sample (+ i 1) k) (sample i (+ k 1)) (sample (+ i 1) (+ k 1))
                    (- u i) (- w k))))
        ;; Terrain vertex (ci, ck), with the terrain's own normal and colour.
        (define (terrain-vertex ci ck)
          (let ((key (+ ci (* VERTS ck))))
            (or (vector-ref snapped key)
                (let ((v (add-vertex! (+ ox ci) (sample (+ ci 1) (+ ck 1)) (+ oz ck)
                                      (list (vector-ref normals (* 3 key)) (vector-ref normals (+ (* 3 key) 1))
                                            (vector-ref normals (+ (* 3 key) 2)))
                                      (list (vector-ref colors (* 4 key)) (vector-ref colors (+ (* 4 key) 1))
                                            (vector-ref colors (+ (* 4 key) 2)) (vector-ref colors (+ (* 4 key) 3)))
                                      (list 0.0 0.0))))
                  (vector-set! snapped key v)
                  v))))
        ;; The vertex for this crossed edge's surface patch in the cell.
        ;; Most cells have one patch; averaging disconnected patches into
        ;; one vertex folds the rock into a flap above some mouths.
        (define (vertex ci cj ck edge)
          (if (snapped? ci cj ck)
              (terrain-vertex ci ck)
              (let ((n (at ci cj ck)))
                (let ((v (or (vector-ref cell-vertex n)
                             (let ((v (cell-vertex! ci cj ck)))
                               (vector-set! cell-vertex n v)
                               v))))
                  (if (vector? v) (vector-ref v edge) v)))))
        (define (cell-vertex! ci cj ck)
          (let ((corner (make-vector 8 0.0)) (sx 0.0) (sy 0.0) (sz 0.0) (m 0))
            (do ((c 0 (+ c 1))) ((= c 8))
              (let ((o (vector-ref CORNERS c)))
                (vector-set! corner c (value-at (+ ci (vector-ref o 0)) (+ cj (vector-ref o 1)) (+ ck (vector-ref o 2))))))
            (for-each
              (lambda (e)
                (let ((a (vector-ref corner (vector-ref e 0))) (b (vector-ref corner (vector-ref e 1))))
                  (unless (eq? (> a 0.0) (> b 0.0))
                    (let ((t (/ a (- a b))))
                      (set! sx (+ sx (lerp (vector-ref e 2) (vector-ref e 5) t)))
                      (set! sy (+ sy (lerp (vector-ref e 3) (vector-ref e 6) t)))
                      (set! sz (+ sz (lerp (vector-ref e 4) (vector-ref e 7) t)))
                      (set! m (+ m 1))))))
              CELL-EDGES)
            ;; Two separate patches need at least three crossings each.
            (let ((groups (and (>= m 6) (cell-groups corner))))
              (if groups
                  (let ((by-edge (make-vector 12 #f)))
                    (for-each
                      (lambda (group)
                        (let ((gx 0.0) (gy 0.0) (gz 0.0))
                          (for-each
                            (lambda (index)
                              (let* ((e (list-ref CELL-EDGES index))
                                     (a (vector-ref corner (vector-ref e 0)))
                                     (b (vector-ref corner (vector-ref e 1)))
                                     (t (/ a (- a b))))
                                (set! gx (+ gx (lerp (vector-ref e 2) (vector-ref e 5) t)))
                                (set! gy (+ gy (lerp (vector-ref e 3) (vector-ref e 6) t)))
                                (set! gz (+ gz (lerp (vector-ref e 4) (vector-ref e 7) t)))))
                            group)
                          (let* ((count (length group))
                                 (v (cell-point! ci cj ck (/ gx count) (/ gy count) (/ gz count) corner)))
                            (for-each (lambda (index) (vector-set! by-edge index v)) group))))
                      groups)
                    by-edge)
                  (cell-point! ci cj ck (/ sx m) (/ sy m) (/ sz m) corner)))))
        ;; Add the average crossing point for one connected surface patch.
        (define (cell-point! ci cj ck fx fy fz corner)
          (let* ((x (+ x0 0.5 ci fx))
                 (y (+ ylo cj fy))
                 (z (+ z0 0.5 ck fz))
                 (terrain-normal (unit (terrain-mix normals 3 (- x ox) (- z oz))))
                 (shaped (cell-near? ci cj ck))
                 ;; Near a cave, the field's gradient toward the open side
                 ;; for the probe below; the mesh's own faces shade it.
                 ;; Ground the caves leave alone shades like the terrain.
                 (normal (if shaped (unit (cell-gradient corner)) terrain-normal))
                 ;; Dark and sheltered as the open space just off the surface.
                 (px (+ x (* 0.3 (car normal)))) (py (+ y (* 0.3 (cadr normal))))
                 (pz (+ z (* 0.3 (list-ref normal 2))))
                 (g (ground-near px pz))
                 (under (and (> g (+ py 0.5))
                             (< (with-roof (cave-distance prims px py pz) py g
                                           (roof-at openings px pz
                                                    (tilt (- (ground-near (+ px 0.5) pz) (ground-near (- px 0.5) pz))
                                                          (- (ground-near px (+ pz 0.5)) (ground-near px (- pz 0.5))))))
                                0.0)))
                 (opening (if under (nearest-opening openings px py pz) 0.0)))
            (let ((v (add-vertex! x y z normal (terrain-mix colors 4 (- x ox) (- z oz))
                                  (list (if under (ramp (car DARK) (cadr DARK) opening) 0.0)
                                        (if under (ramp (car SHELTER) (cadr SHELTER) opening) 0.0)))))
              (when shaped (hash-table-set! face-shaded v #t))
              v)))
        ;; Triangles made twice, either way round, are folds where cells
        ;; meet the terrain: those are dropped at the end.
        (define (tri! a b c)
          (unless (or (= a b) (= b c) (= a c))
            (let* ((lo (fast-min a (fast-min b c))) (hi (fast-max a (fast-max b c)))
                   (key (+ (* lo 4194304 4194304) (* (- (+ a b c) lo hi) 4194304) hi)))
              (hash-table-update!/default tri-count key (lambda (n) (+ n 1)) 0)
              (call-method tris 'extend (list a b c)))))
        ;; Wound as the terrain's triangles are: (a b d) and (b c d).
        ;; At a snapped terrain column a quad can become concave. Use its
        ;; other diagonal when the usual one folds a triangle backward.
        (define (quad! a b c d)
          (if (and (or (not (hash-table-exists? face-shaded a))
                       (not (hash-table-exists? face-shaded b))
                       (not (hash-table-exists? face-shaded c))
                       (not (hash-table-exists? face-shaded d)))
                   (split-ac? vertices a b c d))
              (begin (tri! a b c) (tri! a c d))
              (begin (tri! a b d) (tri! b c d))))
        ;; Edge (i, j, k) runs from that point one step along `axis`. The
        ;; chunk makes the quads of the edges starting in its own cells.
        (define (edge! i j k axis)
          (when (and (>= i 1) (<= i CHUNK-SIZE) (>= k 1) (<= k CHUNK-SIZE) (>= j 1) (<= j (- ny 2)))
            (let* ((ni (if (= axis 0) (+ i 1) i)) (nj (if (= axis 1) (+ j 1) j)) (nk (if (= axis 2) (+ k 1) k))
                   (here (value-at i j k))
                   (there (value-at ni nj nk)))
              (unless (eq? (> here 0.0) (> there 0.0))
                (let ((cells (cond ((= axis 0) (list (list i (- j 1) (- k 1)) (list i j (- k 1)) (list i j k) (list i (- j 1) k)))
                                   ((= axis 1) (list (list (- i 1) j (- k 1)) (list i j (- k 1)) (list i j k) (list (- i 1) j k)))
                                   (else (list (list (- i 1) (- j 1) k) (list i (- j 1) k) (list i j k) (list (- i 1) j k))))))
                  ;; Cells all left as the terrain make the terrain's own
                  ;; triangles, below.
                  ;; Around a y edge the cells run the other way round from
                  ;; x and z edges, so the turn is reversed there.
                  (unless (let loop ((c cells))
                            (or (null? c) (and (apply snapped? (car c)) (loop (cdr c)))))
                    ;; Local CELL-EDGES indices around the shared edge.
                    (let* ((edge-ids (cond ((= axis 0) '(3 1 0 2))
                                           ((= axis 1) '(11 10 8 9))
                                           (else '(7 6 4 5))))
                           (vs (map (lambda (c edge) (vertex (car c) (cadr c) (list-ref c 2) edge)) cells edge-ids)))
                      (if (eq? (> here 0.0) (= axis 1))
                          (quad! (list-ref vs 3) (list-ref vs 2) (cadr vs) (car vs))
                          (quad! (car vs) (cadr vs) (list-ref vs 2) (list-ref vs 3))))))))))
        (do ((k 0 (+ k 1))) ((= k POINTS))
          (do ((i 0 (+ i 1))) ((= i POINTS))
            (vector-set! ground (+ i (* POINTS k))
                         (* 0.25 (+ (sample i k) (sample (+ i 1) k) (sample i (+ k 1)) (sample (+ i 1) (+ k 1)))))))
        (vector-for-each fill! prims)
        ;; The roofed cave distance and the solid field at every point a
        ;; shape reached.
        (let ((roofs (make-vector (* POINTS POINTS) #f)))
          (do ((m 0 (+ m 1))) ((= m (vector-length touched)))
            (when (= (remainder m 512) 0) (pause))
            (let* ((n (vector-ref touched m))
                   (col (remainder n (* POINTS POINTS)))
                   (i (remainder col POINTS)) (k (quotient col POINTS))
                   (y (+ ylo (quotient n (* POINTS POINTS))))
                   (g (vector-ref ground col))
                   (limits (or (vector-ref roofs col)
                               (let ((r (roof-at openings (+ x0 i 0.5) (+ z0 k 0.5)
                                                 (tilt (* 0.5 (- (+ (sample (+ i 1) k) (sample (+ i 1) (+ k 1)))
                                                                 (+ (sample i k) (sample i (+ k 1)))))
                                                       (* 0.5 (- (+ (sample i (+ k 1)) (sample (+ i 1) (+ k 1)))
                                                                 (+ (sample i k) (sample (+ i 1) k))))))))
                                 (vector-set! roofs col r)
                                 r)))
                   (c (with-roof (vector-ref acc n) y g limits)))
              (vector-set! cave n c)
              (vector-set! value n (surface-field y g c)))))
        (pause)
        ;; The ground's points in cell columns a cave changes.
        (do ((ck 0 (+ ck 1))) ((= ck VERTS))
          (do ((ci 0 (+ ci 1))) ((= ci VERTS))
            (unless (pure? ci ck)
              (let-values (((j0 j1) (ground-cells ci ck)))
                (for-each
                  (lambda (o)
                    (let ((i (+ ci (car o))) (k (+ ck (cadr o))))
                      (do ((j (fast-max 0 (- j0 1)) (+ j 1))) ((> j (fast-min (- ny 1) (+ j1 2))))
                        (let ((n (at i j k)))
                          (unless (vector-ref value n)
                            (touch! n (- (+ ylo j) (ground-at i k))))))))
                  '((0 0) (1 0) (0 1) (1 1)))))))
        (pause)
        ;; Each crossed edge from a point with a value, and into it from one
        ;; without.
        (do ((m 0 (+ m 1))) ((= m (vector-length touched)))
          (when (= (remainder m 256) 0) (pause))
          (let* ((n (vector-ref touched m))
                 (col (remainder n (* POINTS POINTS)))
                 (i (remainder col POINTS)) (k (quotient col POINTS))
                 (j (quotient n (* POINTS POINTS))))
            (edge! i j k 0) (edge! i j k 1) (edge! i j k 2)
            (when (and (> i 0) (not (vector-ref value (at (- i 1) j k)))) (edge! (- i 1) j k 0))
            (when (and (> j 0) (not (vector-ref value (at i (- j 1) k)))) (edge! i (- j 1) k 1))
            (when (and (> k 0) (not (vector-ref value (at i j (- k 1))))) (edge! i j (- k 1) 2))))
        (pause)
        ;; Terrain cells whose corners are all left as the terrain.
        (do ((vk 0 (+ vk 1))) ((= vk CHUNK-SIZE))
          (do ((vi 0 (+ vi 1))) ((= vi CHUNK-SIZE))
            (when (and (pure? vi vk) (pure? (+ vi 1) vk) (pure? vi (+ vk 1)) (pure? (+ vi 1) (+ vk 1)))
              (let ((a (terrain-vertex vi vk)) (b (terrain-vertex (+ vi 1) vk))
                    (c (terrain-vertex vi (+ vk 1))) (d (terrain-vertex (+ vi 1) (+ vk 1))))
                (tri! a b c)
                (tri! b d c)))))
        (let ((triangles (vector)))
          (do ((t 0 (+ t 3))) ((>= t (vector-length tris)))
            (let* ((a (vector-ref tris t)) (b (vector-ref tris (+ t 1))) (c (vector-ref tris (+ t 2)))
                   (lo (fast-min a (fast-min b c))) (hi (fast-max a (fast-max b c)))
                   (key (+ (* lo 4194304 4194304) (* (- (+ a b c) lo hi) 4194304) hi)))
              (when (= (hash-table-ref tri-count key) 1)
                (call-method triangles 'extend (list a b c)))))
          (shade-by-faces! vertices normals-out triangles face-shaded)
          (list vertices normals-out colors-out uvs triangles))))

    ;; Whether the a-c diagonal fixes a folded terrain-transition quad.
    (define (split-ac? vertices a b c d)
      (define (normal i j k)
        (let* ((p (lambda (v axis) (vector-ref vertices (+ (* 3 v) axis))))
               (ux (- (p j 0) (p i 0))) (uy (- (p j 1) (p i 1))) (uz (- (p j 2) (p i 2)))
               (vx (- (p k 0) (p i 0))) (vy (- (p k 1) (p i 1))) (vz (- (p k 2) (p i 2))))
          (vector (- (* uy vz) (* uz vy))
                  (- (* uz vx) (* ux vz))
                  (- (* ux vy) (* uy vx)))))
      (define (agree? u v)
        (> (+ (* (vector-ref u 0) (vector-ref v 0))
              (* (vector-ref u 1) (vector-ref v 1))
              (* (vector-ref u 2) (vector-ref v 2))) 0.0))
      (and (not (agree? (normal a b d) (normal b c d)))
           (agree? (normal a b c) (normal a c d))))

    ;; Gives the vertices in `which` the area-weighted normal of the
    ;; triangles around them, so the light follows the mesh's shape where
    ;; the field's gradient wouldn't: around a mouth the ground and the
    ;; cave meet at a crease.
    (define (shade-by-faces! vertices normals triangles which)
      (let ((sums (make-hash-table)))
        (do ((t 0 (+ t 3))) ((>= t (vector-length triangles)))
          (let ((a (vector-ref triangles t)) (b (vector-ref triangles (+ t 1))) (c (vector-ref triangles (+ t 2))))
            (when (or (hash-table-exists? which a) (hash-table-exists? which b) (hash-table-exists? which c))
              (let* ((p (lambda (v k) (vector-ref vertices (+ (* 3 v) k))))
                     (ux (- (p b 0) (p a 0))) (uy (- (p b 1) (p a 1))) (uz (- (p b 2) (p a 2)))
                     (wx (- (p c 0) (p a 0))) (wy (- (p c 1) (p a 1))) (wz (- (p c 2) (p a 2)))
                     (n (vector (- (* wy uz) (* wz uy)) (- (* wz ux) (* wx uz)) (- (* wx uy) (* wy ux)))))
                (for-each
                  (lambda (v)
                    (when (hash-table-exists? which v)
                      (let ((s (hash-table-ref/default sums v #f)))
                        (if s
                            (do ((k 0 (+ k 1))) ((= k 3))
                              (vector-set! s k (+ (vector-ref s k) (vector-ref n k))))
                            (hash-table-set! sums v (vector-copy n))))))
                  (list a b c))))))
        (hash-table-walk sums
          (lambda (v s)
            (let ((len (fast-sqrt (+ (square (vector-ref s 0)) (square (vector-ref s 1)) (square (vector-ref s 2))))))
              (when (> len 1e-9)
                (do ((k 0 (+ k 1))) ((= k 3))
                  (vector-set! normals (+ (* 3 v) k) (/ (vector-ref s k) len)))))))))

    ;; Corner c of a cell is (c mod 2, c div 4, (c div 2) mod 2) in (x, y, z).
    (define CORNERS
      (vector (vector 0 0 0) (vector 1 0 0) (vector 0 0 1) (vector 1 0 1)
              (vector 0 1 0) (vector 1 1 0) (vector 0 1 1) (vector 1 1 1)))

    ;; Cell edges as #(corner corner ax ay az bx by bz).
    (define CELL-EDGES
      (map (lambda (e)
             (let ((a (vector-ref CORNERS (car e))) (b (vector-ref CORNERS (cadr e))))
               (vector (car e) (cadr e)
                       (vector-ref a 0) (vector-ref a 1) (vector-ref a 2)
                       (vector-ref b 0) (vector-ref b 1) (vector-ref b 2))))
             '((0 1) (2 3) (4 5) (6 7)
             (0 2) (1 3) (4 6) (5 7)
             (0 4) (1 5) (2 6) (3 7))))

    ;; Disconnected patches of crossed edges in an ambiguous cell, or #f
    ;; when all crossings belong to one surface. Adjacent cells use the
    ;; same bilinear saddle test on their shared face.
    (define (cell-groups corner)
      (let ((parents (vector 0 1 2 3 4 5 6 7 8 9 10 11))
            (crossed (make-vector 12 #f))
            (groups (make-vector 12 '())))
        (define (root i)
          (let ((p (vector-ref parents i))) (if (= p i) i (root p))))
        (define (join! a b) (vector-set! parents (root a) (root b)))
        (let loop ((edges CELL-EDGES) (i 0))
          (when (pair? edges)
            (let ((e (car edges)))
              (vector-set! crossed i (not (eq? (> (vector-ref corner (vector-ref e 0)) 0.0)
                                               (> (vector-ref corner (vector-ref e 1)) 0.0)))))
            (loop (cdr edges) (+ i 1))))
        (for-each
          (lambda (face)
            (let ((active (filter (lambda (i) (vector-ref crossed i)) (car face))))
              (cond ((= (length active) 2) (join! (car active) (cadr active)))
                    ((= (length active) 4)
                     (let* ((corners (cadr face))
                            (v (map (lambda (i) (vector-ref corner i)) corners)))
                       (if (>= (* (car v) (list-ref v 2)) (* (cadr v) (list-ref v 3)))
                           (begin (join! (car active) (cadr active))
                                  (join! (list-ref active 2) (list-ref active 3)))
                           (begin (join! (car active) (list-ref active 3))
                                  (join! (cadr active) (list-ref active 2)))))))))
          CELL-FACES)
        (do ((i 0 (+ i 1))) ((= i 12))
          (when (vector-ref crossed i)
            (let ((r (root i)))
              (vector-set! groups r (cons i (vector-ref groups r))))))
        (let ((out (filter pair? (vector->list groups))))
          (and (pair? out) (pair? (cdr out)) out))))

    (define CELL-FACES
      '(((0 5 1 4) (0 1 3 2))
        ((2 7 3 6) (4 5 7 6))
        ((0 9 2 8) (0 1 5 4))
        ((1 11 3 10) (2 3 7 6))
        ((4 10 6 8) (0 2 6 4))
        ((5 11 7 9) (1 3 7 5))))

    ;; Which way values at a cell's corners rise, as (x y z).
    (define (cell-gradient v)
      (let ((g (lambda (hi lo)
                 (- (apply + (map (lambda (c) (vector-ref v c)) hi))
                    (apply + (map (lambda (c) (vector-ref v c)) lo))))))
        (list (g '(1 3 5 7) '(0 2 4 6))
              (g '(4 5 6 7) '(0 1 2 3))
              (g '(2 3 6 7) '(0 1 4 5)))))

    (define (unit v)
      (let ((len (fast-max 1e-6 (fast-sqrt (apply + (map (lambda (c) (* c c)) v))))))
        (map (lambda (c) (/ c len)) v)))

    ;; --- REPL helpers ------------------------------------------------------------

    ;; The nearest cave mouth to (x, z), searching sites ring by ring out to
    ;; `rings` cells: #(x floor z dx dz), or #f. Slow: it searches every site.
    (define (find-cave-site x z rings)
      (let ((cx (exact (floor (/ x SITE)))) (cz (exact (floor (/ z SITE)))))
        (let ring ((r 0))
          (and (<= r rings)
               (let loop ((dx (- r)) (dz (- r)) (best #f) (best-d 1e18))
                 (cond ((> dz r) (or best (ring (+ r 1))))
                       ((> dx r) (loop (- r) (+ dz 1) best best-d))
                       ((< (max (abs dx) (abs dz)) r) (loop (+ dx 1) dz best best-d))
                       (else
                         (let* ((sx (+ cx dx)) (sz (+ cz dz))
                                (cave (site-cave sx sz))
                                (m (and cave (car (vector-ref cave 1))))
                                (d (if m (+ (square (- (vector-ref m 0) x)) (square (- (vector-ref m 2) z))) 1e18)))
                           (if (< d best-d)
                               (loop (+ dx 1) dz (list m (vector-ref cave 4)) d)
                               (loop (+ dx 1) dz best best-d))))))))))

    ;; The size of the nearest laid-out cave to (x, z): small, medium or large.
    (define (cave-size-near x z)
      (let ((near (caves-in (- x 200.0) (- z 200.0) (+ x 200.0) (+ z 200.0) 0.0 #t)))
        (and (pair? near) (vector-ref (car near) 4))))))
