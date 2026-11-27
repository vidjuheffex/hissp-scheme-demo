;; Mutable state that survives hot reloads.
;;
;; The terrain and scene libraries are re-executed on every save, which would
;; reset any top-level `define`d counter or table. So everything that must
;; persist (chunk entities, the worker's queues, the player, shader handles)
;; lives in the `state` table here. This library is never reloaded; changing
;; its shape needs a restart.

(define-library (world state)
  (export state state-ref state-set! lock work-available repl-done)
  (import (scheme base)
          (srfi 18)
          (srfi 69))
  (begin
    (define state (make-hash-table))
    (define (state-ref key) (hash-table-ref state key))
    (define (state-set! key value) (hash-table-set! state key value))

    ;; Guards the chunk worker's job queue and results, and the dev command queue.
    (define lock (make-mutex "chunk-queue"))
    (define work-available (make-condition-variable "chunk-work"))
    ;; Signalled when the main thread has finished a REPL line.
    (define repl-done (make-condition-variable "repl-done"))

    (for-each
      (lambda (entry) (hash-table-set! state (car entry) (cadr entry)))
      (list (list 'seed 0)
            (list 'generation 0)
            (list 'chunks (make-hash-table))
            (list 'in-flight (make-hash-table))
            (list 'grass-jobs (make-hash-table))   ; chunk key -> 'pending or 'done
            (list 'job-queue '())
            (list 'finished '())
            (list 'dev-queue '())
            (list 'mtimes (make-hash-table))
            (list 'last-poll 0.0)
            (list 'last-error "")
            (list 'time-of-day 10.0)     ; hours, 0 <= t < 24
            (list 'day-length 1800.0)     ; real seconds per in-game day; 0 freezes
            (list 'day 10)               ; days since a new moon; +1 each midnight
            (list 'last-tick 0.0)
            (list 'applied-time #f)      ; time the scene was last lit for
            (list 'sun-dir #f)           ; direction sunlight travels
            (list 'moon-dir #f)          ; direction moonlight travels
            (list 'light-dir #f)         ; the shadow light: sun by day, moon at night
            (list 'moon #f)              ; moon disc entity
            (list 'sky #f)               ; (sky clouds precipitation) entities
            (list 'life #f)              ; fireflies, bats and birds, see `make-life!`
            (list 'hud #f)               ; (shadow text shown) coordinates readout, see `make-hud!`
            ;; (cover precipitation snow wetness snow-cover), see (world weather)
            (list 'weather (list 0.0 0.0 0.0 0.0 0.0))
            (list 'weather-override #f)  ; cloud cover forced from the REPL
            (list 'wind 1.0)             ; wind speed now, see `wind-speed`
            (list 'wind-override #f)     ; wind speed forced from the REPL
            (list 'cloud-drift (list 0.0 0.0))  ; meters the clouds have moved
            (list 'repl-busy #f)         ; a REPL line is waiting to be evaluated
            (list 'player #f)
            (list 'sun #f)
            (list 'world-root #f)
            (list 'terrain-shader #f)
            (list 'water-shader #f)
            (list 'grass-shader #f)
            (list 'plant-shader #f)))))
