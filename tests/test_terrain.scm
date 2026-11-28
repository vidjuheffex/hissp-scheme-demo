;; (world terrain): noise, seeds, heights, biomes and chunk meshes.

(import (scheme base))
(include "helpers.scm")
(import (world terrain))

(test-begin "terrain")

(set-world-seed! 4242)

;; Inland hills, a coast, cliffs: chunks of every kind around the spawn.
(define CHUNKS '((0 0) (1 0) (0 1) (-3 2) (5 -4) (-2 -17) (2 -7)))
(define POINTS (grid-points -700.0 -700.0 97.3 15))

;; --- noise -----------------------------------------------------------------

(test-equal "hash2 is in [0, 1)" #t
            (let loop ((i -50))
              (or (> i 50)
                  (and (let ((h (hash2 i (* 7 i)))) (and (>= h 0.0) (< h 1.0)))
                       (loop (+ i 1))))))
(test-equal "hash2 gives the same value twice" (hash2 12 -40) (hash2 12 -40))
(test-equal "value-noise is in [0, 1)" #t
            (all-within 0.0 0.9999999 (map (lambda (p) (value-noise (car p) (cadr p))) POINTS)))

;; --- seeds -----------------------------------------------------------------

(let ((heights (lambda () (map (lambda (p) (terrain-height (car p) (cadr p))) POINTS))))
  (let ((first (heights)))
    (set-world-seed! 7)
    (let ((other (heights)) (other-offset (seed-offset)))
      (set-world-seed! 4242)
      (test-equal "a seed gives the same world again" first (heights))
      (test-assert "another seed gives another world"
                   (> (length (filter (lambda (d) (> (abs d) 0.01)) (map - first other)))
                      (* 0.9 (length first))))
      (test-assert "the seed moves the noise" (not (equal? other-offset (seed-offset)))))))

;; --- heights and biomes ------------------------------------------------------

(test-equal "heights are finite" #t
            (all-within -1e4 1e4 (map (lambda (p) (terrain-height (car p) (cadr p))) POINTS)))

(test-equal "walkable ground is the terrain, or the water surface over it" '()
            (filter (lambda (p)
                      (let ((h (terrain-height (car p) (cadr p))) (g (ground-height (car p) (cadr p))))
                        (not (< (abs (- g (max h SEA-LEVEL))) 1e-9))))
                    POINTS))

(test-equal "biome weights are shares: each 0 to 1, no more than 1 together" '()
            (filter (lambda (p)
                      (let ((w (biome-weights (car p) (cadr p))))
                        (not (and (eq? #t (all-within 0.0 1.0 (list (car w) (cadr w) (list-ref w 2))))
                                  (<= (+ (car w) (cadr w) (list-ref w 2)) 1.000001)))))
                    POINTS))

(test-equal "forest density is 0 to 1" #t
            (all-within 0.0 1.0 (map (lambda (p) (forest-density (car p) (cadr p))) POINTS)))

(test-assert "climate is a temperature and a moisture"
             (let ((c (climate 100.0 -250.0)))
               (and (= (length c) 2) (finite? (car c)) (finite? (cadr c)))))

;; Cross both banks of the dry wash. A ledge has room to stand between
;; two rises, several meters above the wash and below the rim.
(test-assert "dry canyon walls expose broad shelves partway up the face"
  (let rows ((z -1836))
    (and (<= z -1800)
         (or (let bank ((x -1465))
               (and (< x -1430)
                    (or (let ((h (terrain-height x z)))
                          (and (< 10 h 17)
                               (< (abs (- h (terrain-height (+ x 1) z))) 0.45)
                               (< (abs (- h (terrain-height (+ x 2) z))) 0.6)
                               (let ((a (terrain-height (- x 5) z))
                                     (b (terrain-height (+ x 7) z)))
                                 (and (< (min a b) (- h 3))
                                      (> (max a b) (+ h 3))))))
                        (bank (+ x 1)))))
             (rows (+ z 2))))))

;; --- chunk meshes --------------------------------------------------------------

(define VERTS (+ CHUNK-RES 1))
(define CELL (/ CHUNK-SIZE CHUNK-RES 1.0))

(define meshes (make-hash-table))
(define (mesh cx cz)
  (let ((key (list cx cz)))
    (or (hash-table-ref/default meshes key #f)
        (let ((m (chunk-mesh-data (* cx CHUNK-SIZE) (* cz CHUNK-SIZE) no-pause)))
          (hash-table-set! meshes key m)
          m))))

(for-each
  (lambda (chunk)
    (let* ((cx (car chunk)) (cz (cadr chunk))
           (ox (* cx CHUNK-SIZE)) (oz (* cz CHUNK-SIZE))
           (m (mesh cx cz))
           (vs (car m)) (ns (cadr m)) (ts (list-ref m 2)) (water (list-ref m 3)) (colors (list-ref m 4))
           (name (lambda (what) (named "chunk " chunk ": " what))))
      (test-equal (name "one vertex per grid point") (* VERTS VERTS 3) (vector-length vs))
      (test-equal (name "a valid mesh") #t (mesh-problem vs 3 ts))
      (test-equal (name "unit normals") #t (unit-normals-problem ns))
      (test-equal (name "vertices sit on the grid at the terrain's height") #t
                  (let loop ((v 0))
                    (or (= v (* VERTS VERTS))
                        (let ((x (vector-ref vs (* 3 v))) (y (vector-ref vs (+ (* 3 v) 1)))
                              (z (vector-ref vs (+ (* 3 v) 2))))
                          (if (and (< (abs (- x (* CELL (remainder v VERTS)))) 1e-9)
                                   (< (abs (- z (* CELL (quotient v VERTS)))) 1e-9)
                                   (< (abs (- y (terrain-height (+ ox x) (+ oz z)))) 1e-6))
                              (loop (+ v 1))
                              (named "vertex " v " at " (list x y z)))))))
      (test-equal (name "every triangle faces up") #t
                  (let loop ((t 0))
                    (or (>= t (vector-length ts))
                        (let* ((p (lambda (i k) (vector-ref vs (+ (* 3 (vector-ref ts (+ t i))) k))))
                               (ux (- (p 1 0) (p 0 0))) (uz (- (p 1 2) (p 0 2)))
                               (wx (- (p 2 0) (p 0 0))) (wz (- (p 2 2) (p 0 2))))
                          (if (> (- (* wz ux) (* wx uz)) 0.0)
                              (loop (+ t 3))
                              (named "triangle " (quotient t 3)))))))
      (test-equal (name "biome colors are shares") #t
                  (let loop ((c 0))
                    (or (>= c (vector-length colors))
                        (let ((r (vector-ref colors c)) (g (vector-ref colors (+ c 1)))
                              (b (vector-ref colors (+ c 2))) (a (vector-ref colors (+ c 3))))
                          (if (and (eq? #t (all-within 0.0 1.0 (list r g b a))) (<= (+ r g b) 1.000001))
                              (loop (+ c 4))
                              (named "vertex " (quotient c 4) " has " (list r g b a)))))))
      (test-equal (name "water only where the ground dips under the sea")
                  (let loop ((v 0))
                    (and (< v (* VERTS VERTS))
                         (or (< (vector-ref vs (+ (* 3 v) 1)) SEA-LEVEL) (loop (+ v 1)))))
                  (and water #t))))
  CHUNKS)

;; Neighbors share their edge: the same heights and the same normals.
(define (edge-mismatch a b along-x)
  (let loop ((k 0))
    (if (= k VERTS)
        #t
        (let ((va (if along-x (+ (* k VERTS) CHUNK-RES) (+ k (* CHUNK-RES VERTS))))
              (vb (if along-x (* k VERTS) k)))
          (if (let check ((q 0))
                (or (= q 3)
                    (and (< (abs (- (vector-ref (car a) (+ (* 3 va) 1)) (vector-ref (car b) (+ (* 3 vb) 1)))) 1e-9)
                         (< (abs (- (vector-ref (cadr a) (+ (* 3 va) q)) (vector-ref (cadr b) (+ (* 3 vb) q)))) 1e-9)
                         (check (+ q 1)))))
              (loop (+ k 1))
              (named "edge vertex " k))))))

(test-equal "chunks meet their neighbor along x" #t (edge-mismatch (mesh 0 0) (mesh 1 0) #t))
(test-equal "chunks meet their neighbor along z" #t (edge-mismatch (mesh 0 0) (mesh 0 1) #f))

;; --- grass -------------------------------------------------------------------

(for-each
  (lambda (chunk)
    (let* ((ox (* (car chunk) CHUNK-SIZE)) (oz (* (cadr chunk) CHUNK-SIZE))
           (m (mesh (car chunk) (cadr chunk)))
           (grass (chunk-grass ox oz (car m) (list-ref m 4) no-pause)))
      (when grass
        (test-equal (named "chunk " chunk ": a valid grass mesh") #t
                    (mesh-problem (car grass) 3 (list-ref grass 4))))
      (test-equal (named "chunk " chunk ": no grass where it's all cleared") #f
                  (chunk-grass ox oz (car m) (list-ref m 4) no-pause (lambda (x z) #t)))))
  CHUNKS)

(test-assert "grass grows somewhere"
             (let loop ((c CHUNKS))
               (and (pair? c)
                    (let ((m (mesh (car (car c)) (cadr (car c)))))
                      (or (chunk-grass (* (car (car c)) CHUNK-SIZE) (* (cadr (car c)) CHUNK-SIZE) (car m) (list-ref m 4) no-pause)
                          (loop (cdr c)))))))

(test-end "terrain")
