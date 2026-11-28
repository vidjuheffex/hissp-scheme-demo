;; (world life): when fireflies, bats and birds are out, their mesh, the
;; ground grid under them.

(import (scheme base))
(include "helpers.scm")
(import (world terrain) (world life))

(test-begin "life")

(set-world-seed! 4242)

(define GRASS '(0.0 0.0 0.0))
(define DESERT '(1.0 0.0 0.0))
;; (fireflies bats birds) at `hours`, sun `height`, clear and still unless given.
(define (out hours height . options)
  (let ((precipitation (if (pair? options) (car options) 0.0))
        (weights (if (and (pair? options) (pair? (cdr options))) (cadr options) GRASS)))
    (life-amounts hours height 0.0 precipitation 0.0 0.3 weights)))

(test-equal "amounts are 0 to 1" #t
            (all-within 0.0 1.0
                        (apply append
                               (map (lambda (h) (out h (cos (* 3.14159 (/ (- h 12.0) 12.0)))))
                                    '(0.0 2.0 4.0 6.0 8.0 12.0 17.0 19.0 21.0 23.0)))))
(test-assert "fireflies are out at midnight over grass" (> (car (out 0.0 -1.0)) 0.5))
(test-equal "no fireflies at noon" 0.0 (car (out 12.0 1.0)))
(test-equal "no fireflies in rain" 0.0 (car (out 0.0 -1.0 1.0)))
(test-equal "no fireflies in the desert" 0.0 (car (out 0.0 -1.0 0.0 DESERT)))
(test-assert "bats hunt at twilight" (> (cadr (out 19.5 -0.2)) 0.5))
(test-equal "no bats at noon" 0.0 (cadr (out 12.0 1.0)))
(test-assert "birds fly by day" (> (list-ref (out 12.0 1.0) 2) 0.5))
(test-equal "no birds at night" 0.0 (list-ref (out 0.0 -1.0) 2))
(test-equal "no birds in a storm" 0.0 (list-ref (out 12.0 1.0 1.0) 2))

(let ((m (life-mesh)))
  (test-equal "a valid mesh" #t (mesh-problem (car m) 3 (list-ref m 3)))
  (test-equal "uvs and colors match the vertices" #t
              (let ((n (quotient (vector-length (car m)) 3)))
                (and (= (* 2 n) (vector-length (cadr m))) (= (* 4 n) (vector-length (list-ref m 2)))))))

(for-each
  (lambda (p)
    (let* ((corner (ground-corner (car p) (cadr p)))
           (half (* 0.5 GROUND-SAMPLES GROUND-SPACING)))
      (test-assert (named "the ground grid is centred near " p)
                   (and (<= (abs (- (+ (car corner) half) (car p))) (* 0.5 GROUND-SPACING))
                        (<= (abs (- (+ (cadr corner) half) (cadr p))) (* 0.5 GROUND-SPACING))))
      (test-equal (named "ground rows near " p " are the ground's heights") #t
                  (let loop ((j 0))
                    (or (= j GROUND-SAMPLES)
                        (let ((row (ground-row corner j)))
                          (if (and (= (length row) GROUND-SAMPLES)
                                   (let check ((i 0) (r row))
                                     (or (null? r)
                                         (and (< (abs (- (car r)
                                                         (ground-height (+ (car corner) (* GROUND-SPACING (+ i 0.5)))
                                                                        (+ (cadr corner) (* GROUND-SPACING (+ j 0.5))))))
                                                 1e-9)
                                              (check (+ i 1) (cdr r))))))
                              (loop (+ j 1))
                              (named "row " j))))))))
  '((0.0 0.0) (123.4 -567.8) (-301.0 44.0)))

(test-end "life")
