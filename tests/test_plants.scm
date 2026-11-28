;; (world plants): plant meshes and the trunks the player walks around.

(import (scheme base))
(include "helpers.scm")
(import (world terrain) (world plants))

(test-begin "plants")

(set-world-seed! 4242)

(define CHUNKS '((0 0) (1 0) (-3 2) (5 -4) (-2 -17) (2 -7) (8 3) (-6 -6)))

(define (plants-of chunk . options)
  (let* ((ox (* (car chunk) CHUNK-SIZE)) (oz (* (cadr chunk) CHUNK-SIZE))
         (m (chunk-mesh-data ox oz no-pause)))
    (apply chunk-plants ox oz (car m) (list-ref m 4) no-pause options)))

(define grown (map (lambda (c) (cons c (plants-of c))) CHUNKS))

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

(test-end "plants")
