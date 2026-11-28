(import (scheme base)
        (only (world game) cave-outdoor-gain flashlight-strength set-flashlight!)
        (world state)
        (only (world terrain) set-world-seed!))
(include "helpers.scm")

(test-begin "game")
(set-world-seed! 4242)
(test-equal "above ground the outdoor mix is full" 1.0 (cave-outdoor-gain 0.0 0.0))
(test-assert "outside sound fades near a covered cave entrance"
             (< 0.0 (cave-outdoor-gain 0.15 0.9) 0.75))
(test-equal "thick rock silences the outdoor mix" 0.0 (cave-outdoor-gain 0.6 1.0))

(define flashlight-saved-hours (state-ref 'time-of-day))
(define flashlight-saved-inside (state-ref 'inside))
(test-assert "a flashlight is available until equipment controls it"
             (state-ref 'flashlight-enabled))

(state-set! 'inside 0.0)
(state-set! 'time-of-day 12.0)
(test-equal "the flashlight stays off outdoors in daylight" 0.0 (flashlight-strength))
(state-set! 'time-of-day 0.0)
(test-equal "the flashlight turns on outdoors at night" 1.0 (flashlight-strength))

(state-set! 'time-of-day 18.0)
(define dusk-flashlight (flashlight-strength))
(test-assert "the flashlight fades up through dusk" (< 0.0 dusk-flashlight 1.0))
(state-set! 'time-of-day 6.0)
(test-approximate "dawn and dusk have the same light" dusk-flashlight (flashlight-strength) 1e-6)

(state-set! 'time-of-day 12.0)
(state-set! 'inside 0.05)
(test-assert "the flashlight fades up as the cave darkens"
             (< 0.0 (flashlight-strength) 1.0))
(state-set! 'inside 1.0)
(test-equal "the flashlight turns on in a dark cave by day" 1.0 (flashlight-strength))
(set-flashlight! #f)
(test-equal "unequipping a flashlight leaves a cave dark" 0.0 (flashlight-strength))
(state-set! 'inside 0.0)
(state-set! 'time-of-day 0.0)
(test-equal "unequipping a flashlight also disables it outdoors" 0.0 (flashlight-strength))
(set-flashlight! #t)
(test-equal "equipping a flashlight restores automatic night lighting" 1.0 (flashlight-strength))
(state-set! 'time-of-day 12.0)
(test-equal "equipping a flashlight keeps it off in daylight" 0.0 (flashlight-strength))

(state-set! 'time-of-day flashlight-saved-hours)
(state-set! 'inside flashlight-saved-inside)
(test-end "game")
