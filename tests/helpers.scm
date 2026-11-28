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

;; The points (x z) on a grid `step` apart over the square from (x0, z0), `n` a side.
(define (grid-points x0 z0 step n)
  (let loop ((i 0) (j 0) (out '()))
    (cond ((= j n) (reverse out))
          ((= i n) (loop 0 (+ j 1) out))
          (else (loop (+ i 1) j (cons (list (+ x0 (* i step)) (+ z0 (* j step))) out))))))
