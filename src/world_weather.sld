;; Weather: cloud cover that comes and goes over the days, and the rain or
;; snow that falls from heavy cloud.
;;
;; Cover follows slow noise over game time, so each world has its own run
;; of clear and stormy spells. Where the player stands shapes it: deserts
;; see half the cloud and little rain, and it falls as snow in the snowy
;; biome or high up. The scene smooths toward these targets with
;; `weather-step`, which also tracks how wet the ground is and how much
;; fresh snow lies on it.

(define-library (world weather)
  (export WIND
          PRECIP-BOX
          weather-target
          wind-speed
          weather-step
          precipitation-mesh)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only random Random)
          (world terrain))
  (begin
    ;; Direction (x z) the wind blows: clouds drift and rain slants this
    ;; way. The grass shader sways along the same direction.
    (define WIND (list 0.85 0.53))

    ;; Changes of weather per in-game day, roughly.
    (define WEATHER-RATE 2.0)

    (define (clamp01 x) (max 0.0 (min 1.0 x)))

    (define (smooth-step lo hi x)
      (let ((t (clamp01 (/ (- x lo) (- hi lo)))))
        (* t t (- 3.0 (* 2.0 t)))))

    ;; Cover from 0 (clear) to 1 (overcast) at `days` (days plus the
    ;; fraction of the current one), before the local climate has a say.
    (define (sky-cover days)
      (let ((t (+ (* days WEATHER-RATE) (* 0.001 (car (seed-offset))))))
        (smooth-step 0.3 0.7 (+ (* 0.65 (value-noise t 17.3))
                                (* 0.35 (value-noise (* t 3.1) 91.7))))))

    ;; What the weather at world (x, z), ground `height`, is heading toward:
    ;; (cover precipitation snow), each 0 to 1. `precipitation` is how hard
    ;; it rains or snows, `snow` how much of it is snow. `forced`, if a
    ;; number, sets the cover everywhere, deserts included.
    (define (weather-target days x z height forced)
      (let* ((w (biome-weights x z))
             (desert (if forced 0.0 (car w)))
             (cover (if forced forced (* (sky-cover days) (- 1.0 (* 0.5 desert)))))
             (precipitation (* (smooth-step 0.6 0.9 cover) (- 1.0 (* 0.85 desert))))
             (snow (max (smooth-step 0.3 0.6 (list-ref w 2))
                        (smooth-step 30.0 38.0 height))))
        (list cover precipitation snow)))

    ;; How hard the wind blows at `days`, with the sun at `height` (-1
    ;; midnight to 1 noon) under the scene's `cover` and `precipitation`:
    ;; about 1 for an ordinary breeze, down near 0 when dead calm. Breezy and
    ;; still spells come and go over the days; nights are calmer, as the air
    ;; settles once the ground cools, so clear nights often go glassy;
    ;; storms blow hardest.
    (define (wind-speed days height cover precipitation)
      (let* ((t (+ (* days 3.0) (* 0.001 (cadr (seed-offset)))))
             (spell (+ 0.2 (* 1.1 (smooth-step 0.25 0.75 (value-noise t 53.9)))))
             (night (- 1.0 (smooth-step -0.2 0.1 height))))
        (+ (* spell (- 1.0 (* 0.75 night)))
           (* 0.6 cover cover)
           (* 0.8 precipitation))))

    ;; `x` moved toward `target` over `dt` seconds, covering most of the
    ;; way in about 3 / `rate` seconds.
    (define (approach x target rate dt)
      (+ x (* (- target x) (- 1.0 (exp (- (* rate dt)))))))

    ;; The weather `dt` real seconds on, heading for `target`. Weather is
    ;; (cover precipitation snow wetness snow-cover): the first three as in
    ;; `weather-target`, `wetness` how soaked the ground is, `snow-cover` how
    ;; much fresh snow lies on it. Rain soaks the ground in about 12 s and it
    ;; dries in about a minute and a half; snow settles in about half a minute
    ;; and takes three to melt.
    (define (weather-step weather target dt)
      (let* ((precipitation (approach (cadr weather) (cadr target) 0.3 dt))
             (snow (approach (list-ref weather 2) (list-ref target 2) 0.5 dt))
             (rain (* precipitation (- 1.0 snow)))
             (snowfall (* precipitation snow)))
        (list (approach (car weather) (car target) 0.3 dt)
              precipitation
              snow
              (clamp01 (+ (list-ref weather 3)
                          (* dt (- (* 0.08 rain) (* 0.012 (- 1.0 rain))))))
              (clamp01 (+ (list-ref weather 4)
                          (* dt (- (* 0.03 snowfall) (* 0.006 (- 1.0 snowfall)))))))))

    ;; --- rain and snow -----------------------------------------------------

    ;; Drops fill a box this size (x y z) around the camera; the shader moves
    ;; them and wraps them around inside it.
    (define PRECIP-BOX (list 36.0 24.0 36.0))
    (define PRECIP-COUNT 12000)

    ;; One quad per drop, all four corners at the drop's spot in the box:
    ;; the shader spreads them into a streak or a flake. UVs give the corner
    ;; (x -1 or 1 across, y 0 or 1 along the fall); color red decides at
    ;; what intensity the drop shows, green varies its speed. Returns
    ;; (vertices uvs colors triangles).
    (define (precipitation-mesh)
      (let ((rng (Random 3))
            (vertices (vector))
            (uvs (vector))
            (colors (vector))
            (triangles (vector)))
        (do ((k 0 (+ k 1))) ((= k PRECIP-COUNT))
          (let ((x (* (car PRECIP-BOX) (- (call-method rng 'random) 0.5)))
                (y (* (cadr PRECIP-BOX) (- (call-method rng 'random) 0.5)))
                (z (* (list-ref PRECIP-BOX 2) (- (call-method rng 'random) 0.5)))
                (show (call-method rng 'random))
                (speed (call-method rng 'random))
                (i (* 4 k)))
            (call-method vertices 'extend (list x y z x y z x y z x y z))
            (call-method uvs 'extend (list -1.0 0.0 1.0 0.0 1.0 1.0 -1.0 1.0))
            (call-method colors 'extend (list show speed 0.0 1.0 show speed 0.0 1.0
                                              show speed 0.0 1.0 show speed 0.0 1.0))
            (call-method triangles 'extend (list i (+ i 1) (+ i 2) i (+ i 2) (+ i 3)))))
        (list vertices uvs colors triangles)))))
