(import (scheme base))
(include "helpers.scm")
(import (only (world game) cave-outdoor-gain))

(test-begin "game")
(test-equal "above ground the outdoor mix is full" 1.0 (cave-outdoor-gain 0.0 0.0))
(test-assert "outside sound fades near a covered cave entrance"
             (< 0.0 (cave-outdoor-gain 0.15 0.9) 0.75))
(test-equal "thick rock silences the outdoor mix" 0.0 (cave-outdoor-gain 0.6 1.0))
(test-end "game")
