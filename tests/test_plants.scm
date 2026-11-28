;; (world plants): plant meshes and the trunks the player walks around.

(import (scheme base) (world terrain) (world plants))
(include "helpers.scm")

(test-begin "plants")

(set-world-seed! 4242)

(define CHUNKS '((0 0) (1 0) (-3 2) (5 -4) (-2 -17) (2 -7) (8 3) (-6 -6)))

(define (plants-of chunk . options)
  (let* ((ox (* (car chunk) CHUNK-SIZE)) (oz (* (cadr chunk) CHUNK-SIZE))
         (m (chunk-mesh-data ox oz no-pause)))
    (apply chunk-plants ox oz (car m) (list-ref m 4) no-pause options)))

(define grown (map (lambda (c) (cons c (plants-of c))) CHUNKS))

(test-equal "rock silhouettes have no edges longer than a fifth of their size" 0
  (let ((p (plants-of '(0 0))))
    (coarse-surfaces (car p) (cadr p) (list-ref p 3)
      (lambda (i) (= 10 (floor (vector-ref (list-ref p 4) (* 2 i))))) 0.2)))

(test-assert "something grows" (pair? (filter cdr grown)))

(for-each
  (lambda (entry)
    (let ((chunk (car entry)) (p (cdr entry)))
      (when p
        (let* ((vs (car p)) (n (quotient (vector-length vs) 3))
               (ox (* (car chunk) CHUNK-SIZE)) (oz (* (cadr chunk) CHUNK-SIZE))
               (name (lambda (what) (named "chunk " chunk ": " what))))
          (test-equal (name "a valid mesh") #t (mesh-problem vs 3 (list-ref p 3)))
          (test-equal (name "normals, colors and uvs match the vertices") #t
                      (and (= (vector-length (cadr p)) (vector-length vs))
                           (= (vector-length (list-ref p 2)) (* 4 n))
                           (= (vector-length (list-ref p 4)) (* 2 n))))
          (test-equal (name "trunks stand in the chunk, on dry ground") '()
                      (filter (lambda (t)
                                (let ((x (car t)) (z (cadr t)) (r (list-ref t 2)))
                                  (not (and (<= ox x (+ ox CHUNK-SIZE)) (<= oz z (+ oz CHUNK-SIZE))
                                            (> r 0.0) (> (terrain-height x z) SEA-LEVEL)))))
                              (list-ref p 5)))
          (test-equal (name "the same plants every time") (vector-length vs)
                      (vector-length (car (plants-of chunk))))
          (test-equal (name "nothing grows where it's all cleared") #f
                      (plants-of chunk (lambda (x z) #t)))))))
  grown)

;; Keep the same strip of dry ground and the same placement rolls. Lower
;; one side and raise the other to turn that strip into a sandstone shelf.
(define (bank-material height material wall? . biome)
  (let* ((side (+ CHUNK-RES 1)) (n (* side side))
         (vs (make-vector (* n 3) 0.0)) (colors (make-vector (* n 4) 0.0)))
    (do ((i 0 (+ i 1))) ((= i n))
      (let ((x (remainder i side)))
        (vector-set! vs (+ (* i 3) 1)
                     (+ height (cond ((not wall?) 0) ((< x 10) -5) ((>= x 16) 8) (else 0))))
        (let ((channel (if (pair? biome) (car biome) 0)))
          (when channel (vector-set! colors (+ (* 4 i) channel) 1.0)))))
    (let chunks ((k 0) (count 0))
      (if (= k 8) count
          (let* ((oz (* k CHUNK-SIZE))
                 (p (chunk-plants 0 oz vs colors no-pause
                      (lambda (x z) (not (and (< 11 x 15) (< (+ oz 5) z (+ oz 27)))))))
                 (uv (if p (list-ref p 4) (vector))))
            (chunks (+ k 1)
              (let scan ((i 0) (total count))
                (if (= i (vector-length uv)) total
                    (scan (+ i 2) (+ total (if (= material (floor (vector-ref uv i))) 1 0)))))))))))

(test-assert "mesquites favor dry ledges with a wall behind and a drop below"
             (> (bank-material 12.0 6 #t) (bank-material 12.0 6 #f)))
(test-assert "fallen rock collects at the foot of a dry wall"
             (> (bank-material 6.6 10 #t) (bank-material 6.6 10 #f)))

(for-each
  (lambda (channel material name)
    (test-assert name (> (bank-material 12.0 material #t channel)
                         (bank-material 12.0 material #f channel))))
  '(2 #f 1) '(7 8 8)
  '("snowy ledges support conifers" "grassland ledges support oaks" "dry grassland ledges support junipers"))
(test-assert "talus collects below grey cliffs above the shoreline"
             (> (bank-material 12.0 10 #t #f) (bank-material 12.0 10 #f #f)))

(test-end "plants")
