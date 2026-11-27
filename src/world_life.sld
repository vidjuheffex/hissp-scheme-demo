;; Wildlife: fireflies over the grass on warm evenings, bats flitting
;; overhead at dusk, and flocks of birds circling high up by day.
;;
;; All of them are one mesh that follows the camera, moved entirely by the
;; life shader, like the rain. Fireflies hover over the ground, so the
;; shader gets a small grid of ground heights around the player
;; (`ground-grid`). How many of each are out depends on the hour, the
;; weather and the biome (`life-amounts`). Like the terrain library, no
;; engine imports here.

(define-library (world life)
  (export FIREFLY-BOX
          GROUND-SAMPLES
          GROUND-SPACING
          life-mesh
          life-amounts
          ground-corner
          ground-row)
  (import (scheme base)
          (scheme inexact)
          (scheme python)
          (only random Random)
          (only array array)
          (only (srfi 1) iota)
          (world terrain))
  (begin
    (define FIREFLY-COUNT 400)
    (define BAT-COUNT 8)
    (define FLOCKS 3)
    (define BIRDS-PER-FLOCK 7)

    ;; Fireflies fill a square this many meters across around the camera;
    ;; the shader wraps them around inside it.
    (define FIREFLY-BOX 40.0)
    ;; Ground heights are sampled on a GROUND-SAMPLES square grid this many
    ;; meters apart, centered on the player.
    ;; Sampling is slow (about 0.15 ms a height), so the grid is coarse and
    ;; filled a few rows per frame.
    (define GROUND-SAMPLES 12)
    (define GROUND-SPACING 4.0)

    (define (clamp01 x) (max 0.0 (min 1.0 x)))

    (define (smooth lo hi x)
      (let ((t (clamp01 (/ (- x lo) (- hi lo)))))
        (* t t (- 3.0 (* 2.0 t)))))

    ;; Each creature's vertices all start at its anchor; the shader spreads
    ;; them out. UVs give each vertex's place on the creature: for a
    ;; firefly the corner of its glow (x, y -1 or 1); for bats and birds x
    ;; across the wings (-1 left tip to 1 right tip) and y along the body
    ;; (-1 tail to 1 nose). Color red is the kind (0 firefly, 0.5 bat, 1
    ;; bird), green and blue its own random numbers (for birds green is the
    ;; flock's). Returns (vertices uvs colors triangles).
    ;; Bats and birds share one outline of 8 vertices: nose, tail, and for
    ;; each wing its leading joint, its tip and a point on its trailing edge.
    (define BAT-UVS
      (list 0.0 0.6  0.0 -0.6
            -0.5 0.4  -1.0 0.0  -0.55 -0.45
            0.5 0.4  1.0 0.0  0.55 -0.45))
    (define BIRD-UVS
      (list 0.0 1.0  0.0 -1.0
            -0.45 0.25  -1.0 -0.4  -0.35 -0.3
            0.45 0.25  1.0 -0.4  0.35 -0.3))
    (define WING-TRIANGLES (list 0 2 1  2 4 1  2 3 4  0 1 5  5 1 7  5 7 6))

    (define (life-mesh)
      (let ((rng (Random 5))
            (vertices (vector))
            (uvs (vector))
            (colors (vector))
            (triangles (vector)))
        (define (random) (call-method rng 'random))
        (define (add! anchor corners shape kind g b)
          (let ((first (quotient (vector-length vertices) 3))
                (n (quotient (length corners) 2)))
            (do ((k 0 (+ k 1))) ((= k n))
              (call-method vertices 'extend anchor)
              (call-method colors 'extend (list kind g b 1.0)))
            (call-method uvs 'extend corners)
            (call-method triangles 'extend (map (lambda (i) (+ first i)) shape))))
        (do ((k 0 (+ k 1))) ((= k FIREFLY-COUNT))
          (add! (list (* FIREFLY-BOX (- (random) 0.5)) (random) (* FIREFLY-BOX (- (random) 0.5)))
                (list -1.0 -1.0  1.0 -1.0  1.0 1.0  -1.0 1.0)
                (list 0 1 2  0 2 3)
                0.0 (random) (random)))
        (do ((k 0 (+ k 1))) ((= k BAT-COUNT))
          (let ((angle (* 6.283 (random)))
                (out (* 22.0 (sqrt (random)))))
            (add! (list (* out (cos angle)) (+ 4.0 (* 6.0 (random))) (* out (sin angle)))
                  BAT-UVS WING-TRIANGLES 0.5 (random) (random))))
        (do ((f 0 (+ f 1))) ((= f FLOCKS))
          (let ((flock (random)))
            (do ((k 0 (+ k 1))) ((= k BIRDS-PER-FLOCK))
              (add! (list (* 6.0 (- (random) 0.5)) (* 3.0 (- (random) 0.5)) (* 6.0 (- (random) 0.5)))
                    BIRD-UVS WING-TRIANGLES 1.0 flock (random)))))
        (list vertices uvs colors triangles)))

    ;; How many of each are out, 0 to 1: (fireflies bats birds), at
    ;; `hours` with the sun at `height` (-1 midnight to 1 noon), under
    ;; `cover` and `precipitation` (`snow` of it snow), in `wind`, where the
    ;; biome weights are `weights` (desert dry snowy).
    ;; Fireflies come out after dusk over grass, until a couple of hours past
    ;; midnight, and stay down in rain, snow, cold and strong wind. Bats hunt
    ;; in the twilight after sunset and before sunrise. Birds fly by day, fewer under heavy cloud,
    ;; none in a storm.
    (define (life-amounts hours height cover precipitation snow wind weights)
      (let* ((desert (car weights))
             (dry (cadr weights))
             (snowy (list-ref weights 2))
             (grass (max 0.0 (- 1.0 desert dry snowy)))
             (dark (- 1.0 (smooth -0.12 0.0 height)))
             (dry-weather (* (- 1.0 (smooth 0.05 0.3 precipitation)) (- 1.0 snow)))
             (evening (if (> hours 12.0) 1.0 (- 1.0 (smooth 1.0 3.0 hours))))
             ;; From sunset until the sun is well down, and the same before
             ;; sunrise: while there's still light in the sky to see them by.
             (twilight (* (- 1.0 (smooth -0.05 0.1 height)) (smooth -0.4 -0.25 height))))
        (list (* dark evening dry-weather (+ grass (* 0.4 dry))
                 (- 1.0 (smooth 1.0 1.6 wind)))
              (* twilight dry-weather (- 1.0 snowy))
              (* (smooth 0.05 0.25 height) (- 1.0 (smooth 0.2 0.5 precipitation))
                 (- 1.0 (* 0.5 cover))))))

    ;; The outer corner (x0 z0) of the ground grid around world (x, z):
    ;; samples sit half a spacing in from it, so the texture's texel centers
    ;; land on them.
    (define (ground-corner x z)
      (let ((half (* 0.5 GROUND-SAMPLES GROUND-SPACING)))
        (list (- (* GROUND-SPACING (round (/ x GROUND-SPACING))) half)
              (- (* GROUND-SPACING (round (/ z GROUND-SPACING))) half))))

    ;; Row `j` (along x) of the grid from `corner`: ground heights, never
    ;; below the sea.
    (define (ground-row corner j)
      (map (lambda (i)
             (max SEA-LEVEL
                  (terrain-height (+ (car corner) (* GROUND-SPACING (+ i 0.5)))
                                  (+ (cadr corner) (* GROUND-SPACING (+ j 0.5))))))
           (iota GROUND-SAMPLES)))))
