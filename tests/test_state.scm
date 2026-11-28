;; (world state): the table that survives reloads.

(import (scheme base))
(include "helpers.scm")
(import (world state) (world terrain))

(test-begin "state")

(state-set! 'test-value '(1 2 3))
(test-equal "a value set is read back" '(1 2 3) (state-ref 'test-value))

(set-world-seed! 31337)
(test-equal "the world's seed is kept in the state" 31337 (state-ref 'seed))
(set-world-seed! 4242)

(test-assert "the clock starts in the day" (<= 0.0 (state-ref 'time-of-day) 24.0))

(test-end "state")
