;; Shared by the test suites: names, mesh checks, number checks.

(import (scheme base)
        (scheme inexact)
        (scheme write)
        (srfi 64)
        (srfi 69)
        (only (srfi 1) filter))

;; A test name from strings, numbers and anything `write` can show.
(define (named . parts)
  (apply string-append
         (map (lambda (p) (cond ((string? p) p)
                                ((number? p) (number->string p))
                                (else (let ((out (open-output-string))) (write p out) (get-output-string out)))))
              parts)))

(define (no-pause) #f)

(define (finite? v) (and (real? v) (= v v) (< (abs v) 1e30)))

(define (within? lo hi v) (and (finite? v) (<= lo v hi)))

;; #t, or the first of `numbers` outside [lo, hi].
(define (all-within lo hi numbers)
  (let loop ((v numbers))
    (cond ((null? v) #t)
          ((within? lo hi (car v)) (loop (cdr v)))
          (else (car v)))))

;; #t, or what's wrong with a mesh: `width` numbers a vertex in `vertices`,
;; triangles as indices into them.
(define (mesh-problem vertices width triangles)
  (let ((n (quotient (vector-length vertices) width)))
    (cond ((not (= 0 (remainder (vector-length vertices) width)))
           (named "vertex buffer of " (vector-length vertices) " isn't whole vertices"))
          ((not (= 0 (remainder (vector-length triangles) 3)))
           (named (vector-length triangles) " indices aren't whole triangles"))
          (else
            (let check-v ((i 0))
              (if (< i (vector-length vertices))
                  (if (finite? (vector-ref vertices i))
                      (check-v (+ i 1))
                      (named "vertex value " i " is " (vector-ref vertices i)))
                  (let check-t ((t 0))
                    (if (< t (vector-length triangles))
                        (let ((k (vector-ref triangles t)))
                          (if (and (exact-integer? k) (<= 0 k) (< k n))
                              (check-t (+ t 1))
                              (named "index " t " is " k " of " n " vertices")))
                        #t))))))))

;; #t, or the first of `normals` (x y z each) not a unit vector.
(define (unit-normals-problem normals)
  (let loop ((i 0))
    (if (>= i (vector-length normals))
        #t
        (let ((len (sqrt (+ (square (vector-ref normals i)) (square (vector-ref normals (+ i 1)))
                            (square (vector-ref normals (+ i 2)))))))
          (if (< (abs (- len 1.0)) 1e-4)
              (loop (+ i 3))
              (named "normal " (quotient i 3) " has length " len))))))

;; Longest visible edge as a fraction of each connected object's extent.
;; This bounds silhouette coarseness without depending on a vertex count.
(define (coarse-surfaces vs ns ts material? limit)
  (let* ((n (quotient (vector-length vs) 3)) (parent (make-vector n 0))
         (bounds (make-hash-table)) (bad 0))
    (define (root i)
      (if (= i (vector-ref parent i)) i
          (let ((r (root (vector-ref parent i)))) (vector-set! parent i r) r)))
    (define (p i k) (vector-ref vs (+ (* 3 i) k)))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! parent i i))
    (do ((i 0 (+ i 3))) ((= i (vector-length ts)))
      (let ((a (vector-ref ts i)) (b (vector-ref ts (+ i 1))) (c (vector-ref ts (+ i 2))))
        (when (and (material? a) (material? b) (material? c))
          (vector-set! parent (root b) (root a))
          (vector-set! parent (root c) (root a)))))
    (do ((i 0 (+ i 1))) ((= i n))
      (when (material? i)
        (let* ((r (root i))
               (box (hash-table-ref/default bounds r #f)))
          (unless box
            (set! box (vector (p i 0) (p i 1) (p i 2) (p i 0) (p i 1) (p i 2) 0.0))
            (hash-table-set! bounds r box))
          (do ((k 0 (+ k 1))) ((= k 3))
            (vector-set! box k (min (vector-ref box k) (p i k)))
            (vector-set! box (+ k 3) (max (vector-ref box (+ k 3)) (p i k)))))))
    (do ((i 0 (+ i 3))) ((= i (vector-length ts)))
      (let ((a (vector-ref ts i)) (b (vector-ref ts (+ i 1))) (c (vector-ref ts (+ i 2))))
        (for-each
          (lambda (pair)
            (let ((a (car pair)) (b (cdr pair)))
              (when (and (material? a) (material? b)
                         (< (abs (vector-ref ns (+ (* 3 a) 1))) 0.999)
                         (< (abs (vector-ref ns (+ (* 3 b) 1))) 0.999))
                (let* ((box (hash-table-ref bounds (root a)))
                       (len (sqrt (+ (square (- (p a 0) (p b 0))) (square (- (p a 1) (p b 1)))
                                     (square (- (p a 2) (p b 2)))))))
                  (vector-set! box 6 (max len (vector-ref box 6)))))))
          (list (cons a b) (cons b c) (cons c a)))))
    (hash-table-walk bounds
      (lambda (r box)
        (when (> (vector-ref box 6)
                 (* limit (max (- (vector-ref box 3) (vector-ref box 0))
                               (- (vector-ref box 4) (vector-ref box 1))
                               (- (vector-ref box 5) (vector-ref box 2)))))
          (set! bad (+ bad 1)))))
    bad))

;; The points (x z) on a grid `step` apart over the square from (x0, z0), `n` a side.
(define (grid-points x0 z0 step n)
  (let loop ((i 0) (j 0) (out '()))
    (cond ((= j n) (reverse out))
          ((= i n) (loop 0 (+ j 1) out))
          (else (loop (+ i 1) j (cons (list (+ x0 (* i step)) (+ z0 (* j step))) out))))))
