;; Every test suite, without a window:
;;
;;   uv run main.py tests/run.scm
;;
;; Exits 1 if any test fails. One suite alone, for a quicker turn while
;; working on it (the summary still counts failures):
;;
;;   uv run main.py tests/test_terrain.scm

(import (scheme base)
        (srfi 64)
        (rename (only sys exit) (exit sys-exit)))

(test-begin "world")
(include "test_state.scm"
         "test_terrain.scm"
         "test_weather.scm"
         "test_life.scm"
         "test_plants.scm"
         "test_game.scm"
         "test_sounds.scm"
         "test_caves.scm")
(test-end "world")
(sys-exit (test-exit-code))
