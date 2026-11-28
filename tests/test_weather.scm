;; (world weather): targets, wind, mist, blooms, the weather's step, meshes.

(import (scheme base))
(include "helpers.scm")
(import (world terrain) (world weather))

(test-begin "weather")

(set-world-seed! 4242)

(define DAYS (let loop ((d 0.0) (out '())) (if (> d 30.0) (reverse out) (loop (+ d 0.37) (cons d out)))))
(define POINTS (grid-points -600.0 -600.0 150.0 9))

;; --- targets ---------------------------------------------------------------

(test-equal "targets are 0 to 1" #t
            (all-within 0.0 1.0
                        (apply append
                               (map (lambda (p)
                                      (apply append
                                             (map (lambda (d) (weather-target d (car p) (cadr p)
                                                                              (terrain-height (car p) (cadr p)) #f))
                                                  '(0.0 3.3 7.9 15.2))))
                                    POINTS))))
(test-equal "a forced cover sets the cover" 1.0 (car (weather-target 4.0 0.0 0.0 10.0 1.0)))
(test-equal "no cover, no rain or snow falling" 0.0 (cadr (weather-target 4.0 0.0 0.0 10.0 0.0)))
(test-assert "high ground gets snow" (> (list-ref (weather-target 4.0 0.0 0.0 40.0 1.0) 2) 0.99))

;; --- wind -------------------------------------------------------------------

(test-equal "the wind's direction is a unit vector" '()
            (filter (lambda (d)
                      (let ((w (wind-direction d 0.3)))
                        (> (abs (- 1.0 (sqrt (+ (square (car w)) (square (cadr w)))))) 1e-6)))
                    DAYS))
(test-equal "wind speeds are finite and not negative" #t
            (all-within 0.0 100.0 (map (lambda (d) (wind-speed d 0.5 0.3 0.0)) DAYS)))
(let ((mean (lambda (f) (/ (apply + (map f DAYS)) (length DAYS)))))
  (test-assert "storms blow harder than clear days"
               (> (mean (lambda (d) (wind-speed d 0.5 1.0 1.0))) (mean (lambda (d) (wind-speed d 0.5 0.0 0.0)))))
  (test-assert "nights are calmer than days"
               (< (mean (lambda (d) (wind-speed d -1.0 0.2 0.0))) (mean (lambda (d) (wind-speed d 0.8 0.2 0.0))))))

;; --- mist and flowers -----------------------------------------------------------

(test-equal "mist is 0 to 1" #t
            (all-within 0.0 1.0 (map (lambda (d) (mist-amount d 5.0 -0.1 0.2 0.5 0.0 '(0.0 0.0 0.0))) DAYS)))
(test-equal "no mist in the desert" #t
            (all-within 0.0 0.0 (map (lambda (d) (mist-amount d 5.0 -0.1 0.0 1.0 0.0 '(1.0 0.0 0.0))) DAYS)))
(test-equal "blooms are four shares, 0 to 1" #t
            (and (= 4 (length (blooms 3.0)))
                 (all-within 0.0 1.0 (apply append (map blooms DAYS)))))

;; --- the weather's step -----------------------------------------------------------

(define (run-weather weather target seconds)
  (let loop ((w weather) (t 0.0))
    (if (>= t seconds) w (loop (weather-step w target 0.25) (+ t 0.25)))))

(let* ((dry '(0.0 0.0 0.0 0.0 0.0))
       (rained (run-weather dry '(1.0 1.0 0.0) 40.0))
       (dried (run-weather rained '(0.0 0.0 0.0) 150.0))
       (snowed (run-weather dry '(1.0 1.0 1.0) 90.0))
       (melted (run-weather snowed '(0.0 0.0 0.0) 300.0)))
  (test-equal "the weather stays 0 to 1" #t (all-within 0.0 1.0 (append rained dried snowed melted)))
  (test-assert "the cover comes in" (> (car rained) 0.95))
  (test-assert "rain soaks the ground" (> (list-ref rained 3) 0.95))
  (test-assert "rain leaves no snow" (< (list-ref rained 4) 1e-9))
  (test-assert "the ground dries" (< (list-ref dried 3) 0.05))
  (test-assert "snow settles" (> (list-ref snowed 4) 0.95))
  (test-assert "snow doesn't soak the ground" (< (list-ref snowed 3) 0.05))
  (test-assert "snow melts" (< (list-ref melted 4) 0.05)))

;; --- meshes -----------------------------------------------------------------------

(define (consistent-mesh m)
  (let ((n (quotient (vector-length (car m)) 3)))
    (cond ((not (= (* 2 n) (vector-length (cadr m)))) "uvs don't match the vertices")
          ((not (= (* 4 n) (vector-length (list-ref m 2)))) "colors don't match the vertices")
          (else (mesh-problem (car m) 3 (list-ref m 3))))))

(let ((drops (precipitation-mesh)))
  (test-equal "rain and snow: a valid mesh" #t (consistent-mesh drops))
  (test-equal "rain and snow fill their box" #t
              (let ((vs (car drops)))
                (let loop ((i 0))
                  (or (>= i (vector-length vs))
                      (if (and (<= (abs (vector-ref vs i)) (* 0.5 (car PRECIP-BOX)))
                               (<= (abs (vector-ref vs (+ i 1))) (* 0.5 (cadr PRECIP-BOX)))
                               (<= (abs (vector-ref vs (+ i 2))) (* 0.5 (list-ref PRECIP-BOX 2))))
                          (loop (+ i 3))
                          (named "drop vertex " (quotient i 3))))))))
(test-equal "wind lines: a valid mesh" #t (consistent-mesh (wind-lines-mesh)))

(test-end "weather")
