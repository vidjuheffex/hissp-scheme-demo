;; (world caves): mouths, chunk seams, walking, darkness and clearings.
;;
;; Checks the caves of world seed 4242 for holes, repeated edges and
;; reversed faces across whole blocks of chunks, then walks the player's
;; climb and headroom rules in and out of every mouth and along each main
;; tunnel.

(import (scheme base))
(include "helpers.scm")
(import (scheme python)
        (only (world terrain) CHUNK-SIZE SEA-LEVEL set-world-seed! terrain-height chunk-mesh-data)
        (world caves)
        (only (world plants) chunk-plants))

(set-world-seed! 4242)

(define SITES '((-4 3) (-3 2) (-1 -4) (0 -1) (0 3) (2 2) (3 -2) (0 4)))
(define MAX-CLIMB 2.0)   ; as the game's: meters of rise per meter walked

(test-begin "caves")

;; The seed's chamber off the sandstone mouth has water centered here.
(let* ((x -428.5) (z 334.5) (ox -448) (oz 320)
       (mesh (list-ref (chunk-mesh-data ox oz no-pause
                         (lambda (h c n) (cave-chunk-data ox oz h c n no-pause))) 5))
       (vs (car mesh)) (uv (list-ref mesh 3))
       (water (let scan ((i 0))
                (and (< (* 2 i) (vector-length uv))
                     (if (and (= (vector-ref uv (+ 1 (* 2 i))) 4.0)
                              (= (+ ox (vector-ref vs (* 3 i))) x)
                              (= (+ oz (vector-ref vs (+ 2 (* 3 i)))) z))
                         (vector-ref vs (+ 1 (* 3 i)))
                         (scan (+ i 1)))))))
  (caves-ready-near! x z)
  (let ((bed (cave-ground x z 8.5 (terrain-height x z)))
        (bank (cave-ground (+ x 2.6) z 8.5 (terrain-height (+ x 2.6) z))))
    (test-assert "pool water sits between the cave bed and its bank"
                 (and water bed bank (< bed (- water 0.1)) (< water (- bank 0.06)))))
  (let ((bank-wet? #f) (wet-away? #f))
    (do ((i 0 (+ i 1))) ((= (* 2 i) (vector-length uv)))
      (let* ((material (vector-ref uv (+ 1 (* 2 i))))
             (dy (- (vector-ref vs (+ 1 (* 3 i))) water))
             (r2 (+ (square (- (+ ox (vector-ref vs (* 3 i))) x))
                    (square (- (+ oz (vector-ref vs (+ 2 (* 3 i)))) z)))))
        (when (and (< 1.0 material 2.0) (< r2 25.0))
          (when (and (< 0.0 dy 0.45) (< r2 6.25)) (set! bank-wet? #t))
          (when (or (> dy 1.0) (> r2 12.25)) (set! wet-away? #t)))))
    (test-assert "the cave floor just above the pool is wet" bank-wet?)
    (test-equal "the dry floor and ceiling beyond the pool stay dry" #f wet-away?)))

;; Sample the rock at either end of each formation in three chambers. The
;; hanging, standing and joined forms must actually reach their host rock.
(let ((hanging 0) (standing 0) (joined 0) (shortest 100.0) (tallest 0.0))
  (for-each
    (lambda (site)
      (let* ((c (apply site-cave site)) (room (vector-ref (vector-ref c 5) 0))
             (ox (* CHUNK-SIZE (floor (/ (vector-ref room 1) CHUNK-SIZE))))
             (oz (* CHUNK-SIZE (floor (/ (vector-ref room 3) CHUNK-SIZE))))
             (ctx (vector (vector-ref c 0) (vector-ref c 2)))
             (m (list-ref (chunk-mesh-data ox oz no-pause
                            (lambda (h colors ns) (cave-chunk-data ox oz h colors ns no-pause))) 5)))
        (for-each
          (lambda (body)
            (let* ((x (car body)) (z (cadr body)) (h (terrain-height x z))
                   (lo (list-ref body 3)) (hi (list-ref body 4))
                   (base? (< (solid-field ctx x (- lo 0.2) z h) 0))
                   (crown? (< (solid-field ctx x (+ hi 0.2) z h) 0)))
              (when (> (solid-field ctx x (* 0.5 (+ lo hi)) z h) 0)
                (set! shortest (min shortest (- hi lo)))
                (set! tallest (max tallest (- hi lo)))
                (cond ((and base? crown?) (set! joined (+ joined 1)))
                      (base? (set! standing (+ standing 1)))
                      (crown? (set! hanging (+ hanging 1)))))))
          (if (and m (> (length m) 5)) (list-ref m 5) '()))))
    '((-1 -4) (3 -2) (-3 2)))
  (test-assert "stalactites hang from chamber ceilings" (> hanging 0))
  (test-assert "stalagmites rise from chamber floors" (> standing 0))
  (test-assert "columns meet rock at both ends" (> joined 0))
  (test-assert "short dripstone and room-height formations grow together"
               (and (< shortest 1.0) (> tallest 3.5))))

;; Water vertices in the cave mesh carry the pool material. Count the
;; chambers containing water, including dry chambers in the same world.
(let ((wet 0) (dry 0) (meshes (make-hash-table)))
  (for-each
    (lambda (site)
      (vector-for-each
        (lambda (room)
          (let* ((x (vector-ref room 1)) (z (vector-ref room 3))
                 (ox (* CHUNK-SIZE (floor (/ x CHUNK-SIZE))))
                 (oz (* CHUNK-SIZE (floor (/ z CHUNK-SIZE))))
                 (key (list ox oz))
                 (mesh (or (hash-table-ref/default meshes key #f)
                           (let ((m (list-ref (chunk-mesh-data ox oz no-pause
                                      (lambda (h c n) (cave-chunk-data ox oz h c n no-pause))) 5)))
                             (hash-table-set! meshes key m) m))))
            (if (and mesh (let ((vs (car mesh)) (uv (list-ref mesh 3)))
                            (let scan ((i 0))
                              (and (< (* 2 i) (vector-length uv))
                                   (or (and (>= (vector-ref uv (+ 1 (* 2 i))) 4.0)
                                            (< (abs (- (+ ox (vector-ref vs (* 3 i))) x)) (vector-ref room 4))
                                            (< (abs (- (+ oz (vector-ref vs (+ 2 (* 3 i)))) z)) (vector-ref room 6)))
                                       (scan (+ i 1)))))))
                (set! wet (+ wet 1)) (set! dry (+ dry 1)))))
        (vector-ref (apply site-cave site) 5)))
    SITES)
  (test-assert "a minority of chambers hold drip pools" (< 0 wet dry)))

;; (vertices normals triangles cave?) for the chunk at (cx, cz), its cave
;; mesh where a cave reaches it.
(define cave-meshes (make-hash-table))
(define (cave-mesh cx cz)
  (let ((key (list cx cz)))
    (or (hash-table-ref/default cave-meshes key #f)
        (let* ((ox (* cx CHUNK-SIZE)) (oz (* cz CHUNK-SIZE))
               (data (chunk-mesh-data ox oz no-pause
                                      (lambda (heights colors normals)
                                        (cave-chunk-data ox oz heights colors normals no-pause))))
               (cave (list-ref data 5))
               (m (if cave
                      (list (car cave) (cadr cave) (list-ref cave 4) #t)
                      (list (car data) (cadr data) (list-ref data 2) #f))))
          (hash-table-set! cave-meshes key m)
          m))))

;; --- a mouth on the ground --------------------------------------------------

;; A tunnel whose top just meets the ground: no sheet of rock between them.
(let ((ctx (vector (vector (capsule -2.0 19.0 0.0 4.0 19.0 0.0 2.0))
                   (list (vector 0.0 18.0 0.0 1.0 0.0)))))
  (for-each (lambda (y)
              (test-assert (named "open mouth at y " y) (> (solid-field ctx 0.0 y 0.0 18.0) 0.0)))
            '(17.98 18.0 18.02)))

;; --- watertight and consistently wound ---------------------------------------

(define (micro v) (+ (exact (round (* v 1e6))) 1099511627776))
(define (whole? v) (< (abs (- v (round v))) 1e-6))

;; Welds the meshes of every chunk around the cave at `site`, and an extra
;; ring, and returns (bad-edges flipped): edges inside the block not met
;; exactly once each way, and cave faces turned against their normals.
(define (weld-check site)
  (let* ((box (vector-ref (site-cave (car site) (cadr site)) 3))
         (c0x (- (exact (floor (/ (car box) CHUNK-SIZE))) 1))
         (c0z (- (exact (floor (/ (cadr box) CHUNK-SIZE))) 1))
         (c1x (+ (exact (floor (/ (list-ref box 2) CHUNK-SIZE))) 1))
         (c1z (+ (exact (floor (/ (list-ref box 3) CHUNK-SIZE))) 1))
         (ids (make-hash-table))
         (inside (vector))
         (edges (make-hash-table))
         (flipped 0))
    (define (inside? x z)
      (and (< (+ (* c0x CHUNK-SIZE) 2) x (- (* (+ c1x 1) CHUNK-SIZE) 2))
           (< (+ (* c0z CHUNK-SIZE) 2) z (- (* (+ c1z 1) CHUNK-SIZE) 2))))
    (define (point-id x y z)
      (let ((key (+ (* (micro x) 4835703278458516698824704) (* (micro y) 2199023255552) (micro z))))
        (or (hash-table-ref/default ids key #f)
            (let ((id (hash-table-size ids)))
              (hash-table-set! ids key id)
              (call-method inside 'append (inside? x z))
              id))))
    (define (edge! a b)
      (hash-table-update!/default edges (+ (* a 4294967296) b) (lambda (n) (+ n 1)) 0))
    (do ((cx (- c0x 1) (+ cx 1))) ((> cx (+ c1x 1)))
      (do ((cz (- c0z 1) (+ cz 1))) ((> cz (+ c1z 1)))
        (let* ((m (cave-mesh cx cz))
               (vs (car m)) (ns (cadr m)) (ts (list-ref m 2))
               (check-faces (and (list-ref m 3) (<= c0x cx c1x) (<= c0z cz c1z)))
               (ox (* cx CHUNK-SIZE)) (oz (* cz CHUNK-SIZE))
               (p (lambda (v k) (vector-ref vs (+ (* 3 v) k)))))
          (do ((t 0 (+ t 3))) ((>= t (vector-length ts)))
            (let* ((i (vector-ref ts t)) (j (vector-ref ts (+ t 1))) (k (vector-ref ts (+ t 2)))
                   (a (point-id (+ ox (p i 0)) (p i 1) (+ oz (p i 2))))
                   (b (point-id (+ ox (p j 0)) (p j 1) (+ oz (p j 2))))
                   (c (point-id (+ ox (p k 0)) (p k 1) (+ oz (p k 2)))))
              (unless (or (= a b) (= b c) (= a c))
                (edge! a b) (edge! b c) (edge! c a)
                ;; Faces of the plain terrain can lean against their
                ;; smoothed normals on jagged ground; only cave faces count.
                (when (and check-faces
                           (not (and (whole? (p i 0)) (whole? (p i 2)) (whole? (p j 0))
                                     (whole? (p j 2)) (whole? (p k 0)) (whole? (p k 2)))))
                  (let* ((ux (- (p j 0) (p i 0))) (uy (- (p j 1) (p i 1))) (uz (- (p j 2) (p i 2)))
                         (wx (- (p k 0) (p i 0))) (wy (- (p k 1) (p i 1))) (wz (- (p k 2) (p i 2)))
                         (n (lambda (q) (+ (vector-ref ns (+ (* 3 i) q)) (vector-ref ns (+ (* 3 j) q))
                                           (vector-ref ns (+ (* 3 k) q))))))
                    (when (> (+ (* (- (* uy wz) (* uz wy)) (n 0))
                                (* (- (* uz wx) (* ux wz)) (n 1))
                                (* (- (* ux wy) (* uy wx)) (n 2)))
                             1e-9)
                      (set! flipped (+ flipped 1)))))))))))
    (let ((bad 0))
      (hash-table-walk edges
        (lambda (key count)
          (let ((a (quotient key 4294967296)) (b (remainder key 4294967296)))
            (when (and (vector-ref inside a) (vector-ref inside b)
                       (not (and (= count 1)
                                 (= 1 (hash-table-ref/default edges (+ (* b 4294967296) a) 0)))))
              (set! bad (+ bad 1))))))
      (list bad flipped))))

(for-each
  (lambda (site)
    (let ((result (weld-check site)))
      (test-equal (named "cave " site ": open or repeated edges") 0 (car result))
      (test-equal (named "cave " site ": reversed faces") 0 (cadr result))))
  SITES)

;; --- walking -------------------------------------------------------------------

;; The floor under feet at `feet` in (x, z), as the game picks it.
(define (floor-at x z feet)
  (let ((h (terrain-height x z)))
    (or (cave-ground x z feet h) h)))

;; The floor if the player may step there from `feet`, `distance` away, else #f.
(define (step x z feet distance)
  (let* ((h (terrain-height x z))
         (ground (or (cave-ground x z feet h) h)))
    (and (<= ground (+ feet 0.01 (* MAX-CLIMB distance)))
         (cave-headroom? x z ground h)
         ground)))

;; Walks through the mouth at #(x floor z dx dz), from 6 m out to 4.5 m in
;; (`way` 1) or back out (-1), sidestepping a little where blocked. #t, or
;; where it got stuck.
(define (walk-mouth mouth way)
  (let* ((mx (vector-ref mouth 0)) (my (vector-ref mouth 1)) (mz (vector-ref mouth 2))
         (dx (vector-ref mouth 3)) (dz (vector-ref mouth 4))
         (start (if (> way 0) -6.0 4.5))
         (sx (+ mx (* start dx))) (sz (+ mz (* start dz))))
    (let loop ((along start) (x sx) (z sz)
               (feet (floor-at sx sz (+ 0.5 (if (> way 0) (terrain-height sx sz) my))))
               (steps 0))
      (cond ((if (> way 0) (>= along 4.5) (<= along -6.0)) #t)
            ((= steps 50) (named "didn't get through, " along " m along"))
            (else
              (let* ((next (+ along (* way 0.25)))
                     (moved (let attempt ((sides '(0.0 0.4 -0.4 0.8 -0.8 1.2 -1.2)))
                              (and (pair? sides)
                                   (let* ((nx (- (+ mx (* next dx)) (* (car sides) dz 0.25)))
                                          (nz (+ mz (* next dz) (* (car sides) dx 0.25)))
                                          (f (step nx nz feet (sqrt (+ (square (- nx x)) (square (- nz z)))))))
                                     (if f (list nx nz f) (attempt (cdr sides))))))))
                (if moved
                    (loop next (car moved) (cadr moved) (list-ref moved 2) (+ steps 1))
                    (named "blocked " along " m along"))))))))

;; The cave's main tunnel: its first chain of joined segments, from the mouth in.
(define (main-chain cave)
  (let ((prims (vector-ref cave 0)))
    (let collect ((k 0) (out '()))
      (if (or (= k (vector-length prims))
              (not (= (vector-ref (vector-ref prims k) 0) 0))
              (and (> k 0)
                   (let ((p (vector-ref prims k)) (q (vector-ref prims (- k 1))))
                     (or (> (abs (- (vector-ref p 1) (vector-ref q 4))) 1e-6)
                         (> (abs (- (vector-ref p 3) (vector-ref q 6))) 1e-6)))))
          (reverse out)
          (collect (+ k 1) (cons (vector-ref prims k) out))))))

;; Follows the main tunnel from the mouth in. #t, or where it got stuck.
(define (walk-tunnel cave)
  (let* ((chain (main-chain cave))
         (path (cons (list (vector-ref (car chain) 1) (vector-ref (car chain) 3))
                     (map (lambda (p) (list (vector-ref p 4) (vector-ref p 6))) chain))))
    (caves-ready-near! (car (car path)) (cadr (car path)))
    (let segment ((targets (cdr path)) (x (car (car path))) (z (cadr (car path)))
                  (feet (terrain-height (car (car path)) (cadr (car path)))) (n 1))
      (if (null? targets)
          #t
          (let ((tx (car (car targets))) (tz (cadr (car targets))))
            (let walk ((x x) (z z) (feet feet) (steps 0))
              (let ((d (sqrt (+ (square (- tx x)) (square (- tz z))))))
                (cond ((<= d 0.4) (segment (cdr targets) x z feet (+ n 1)))
                      ((= steps 400) (named "couldn't reach segment " n))
                      (else
                        (let* ((ux (/ (- tx x) d)) (uz (/ (- tz z) d))
                               (moved (let attempt ((sides '(0.0 0.5 -0.5 1.0 -1.0 1.5 -1.5 2.0 -2.0)))
                                        (and (pair? sides)
                                             (let* ((a (* 0.6 (car sides)))
                                                    (nx (+ x (* 0.25 (- (* ux (cos a)) (* uz (sin a))))))
                                                    (nz (+ z (* 0.25 (+ (* ux (sin a)) (* uz (cos a))))))
                                                    (f (step nx nz feet 0.25)))
                                               (if f (list nx nz f) (attempt (cdr sides))))))))
                          (if moved
                              (walk (car moved) (cadr moved) (list-ref moved 2) (+ steps 1))
                              (named "blocked in segment " n " at " (list x feet z)))))))))))))

(for-each
  (lambda (site)
    (let ((cave (site-cave (car site) (cadr site))))
      (for-each
        (lambda (mouth)
          (caves-ready-near! (vector-ref mouth 0) (vector-ref mouth 2))
          (test-equal (named "cave " site ": in through mouth at " (exact (round (vector-ref mouth 0))) ","
                             (exact (round (vector-ref mouth 2))))
                      #t (walk-mouth mouth 1))
          (test-equal (named "cave " site ": out through mouth at " (exact (round (vector-ref mouth 0))) ","
                             (exact (round (vector-ref mouth 2))))
                      #t (walk-mouth mouth -1)))
        (vector-ref cave 2))
      (test-equal (named "cave " site ": main tunnel") #t (walk-tunnel cave))))
  SITES)

;; --- layout, darkness, shelter, clearings -------------------------------------

(define (chunk-origin v) (* CHUNK-SIZE (floor (/ v CHUNK-SIZE))))

(for-each
  (lambda (site)
    (let* ((cave (site-cave (car site) (cadr site)))
           (mouth (car (vector-ref cave 1)))
           (mx (vector-ref mouth 0)) (my (vector-ref mouth 1)) (mz (vector-ref mouth 2))
           (dx (vector-ref mouth 3)) (dz (vector-ref mouth 4))
           (name (lambda (what) (named "cave " site ": " what)))
           ;; Out in the open in front of the mouth, and at the far end of
           ;; the main tunnel, at eye height.
           (ox (- mx (* 15.0 dx))) (oz (- mz (* 15.0 dz))) (oh (terrain-height ox oz))
           (end (car (reverse (main-chain cave))))
           (ex (vector-ref end 4)) (ez (vector-ref end 6)) (eh (terrain-height ex ez))
           (efloor (cave-ground ex ez (+ (- (vector-ref end 5) (* 0.55 (vector-ref end 7))) 0.5) eh))
           ;; Well away from this cave's box.
           (box (vector-ref cave 3))
           (fx (- (car box) 25.0)) (fz (- (cadr box) 25.0)) (fh (terrain-height fx fz)))
      (caves-ready-near! mx mz)
      (test-assert (name "the mouth's floor is above the sea") (> my SEA-LEVEL))
      (test-assert (name "the mouth faces along a unit vector")
                   (< (abs (- 1.0 (sqrt (+ (square dx) (square dz))))) 1e-6))
      (test-equal (name "daylight out in front") 0.0 (cave-depth ox (+ oh 1.6) oz oh))
      (test-equal (name "open sky out in front") 0.0 (cave-shelter ox (+ oh 1.6) oz oh))
      (test-assert (name "the main tunnel has a floor at its end") efloor)
      (when efloor
        (test-assert (name "dark at the end of the main tunnel") (> (cave-depth ex (+ efloor 1.6) ez eh) 0.5))
        (test-assert (name "sheltered at the end of the main tunnel")
                     (> (cave-shelter ex (+ efloor 1.6) ez eh) 0.9)))
      (caves-ready-near! fx fz)
      (test-equal (name "no cave floor away from it") #f (cave-ground fx fz (+ fh 0.5) fh))
      (test-assert (name "headroom away from it") (cave-headroom? fx fz fh fh))
      ;; Plants keep out of the clearing in front of the mouth, as the game asks.
      (let* ((cx (- mx (* 3.0 dx))) (cz (- mz (* 3.0 dz)))
             (cox (chunk-origin cx)) (coz (chunk-origin cz))
             (clear? (mouth-clearing cox coz 8.0 6.0))
             (terrain (chunk-mesh-data cox coz no-pause))
             (plants (chunk-plants cox coz (car terrain) (list-ref terrain 4) no-pause clear?)))
        (test-assert (name "the ground in front of the mouth is kept clear") (clear? cx cz))
        (test-equal (name "no trunks in the clearing") '()
                    (if plants
                        (filter (lambda (t) (clear? (car t) (cadr t))) (list-ref plants 5))
                        '())))))
  SITES)

(test-end "caves")
