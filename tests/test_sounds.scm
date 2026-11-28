;; The cave sound files the game loads. It loads them the first time the
;; player is under rock, so a missing file would only show up in a cave.
;; Run from the repository root, as README.md says.

(import (scheme base))
(include "helpers.scm")
(import (scheme file))

(test-begin "sounds")

(define (sound-file . parts)
  (apply string-append "assets/sounds/" parts))

(define (variants prefix count suffix)
  (let loop ((k count) (out '()))
    (if (= k 0) out (loop (- k 1) (cons (string-append prefix (number->string k) suffix) out)))))

(for-each
  (lambda (file)
    (test-assert (named file " exists") (file-exists? file))
    (test-assert (named file " is an Ogg file")
                 (and (file-exists? file)
                      (let* ((in (open-binary-input-file file))
                             (head (read-bytevector 4 in)))
                        (close-port in)
                        (and (bytevector? head) (equal? head (bytevector 79 103 103 83)))))))  ; "OggS"
  (append (variants (sound-file "cave/drip-") 3 ".ogg")
          (variants (sound-file "steps/cave-rock-") 4 ".ogg")
          (variants (sound-file "steps/cave-water-") 4 ".ogg")))

(test-end "sounds")
