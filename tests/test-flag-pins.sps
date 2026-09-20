#!r6rs
;;; The pin test (brief, M0).  The F-* flag constants and method numbers the
;;; recorded parser traces depend on are IMPORTED from (httparse decisions) and
;;; (httparse methods), never copied, and must equal llhttp's own values.
;;;
;;; Oracle: llhttp's FLAGS enum and method table (src/native/http.c and
;;; llhttp.h) — F_CONNECTION_CLOSE = 1<<1 = 2, F_SKIP_BODY = 1<<6 = 64, and the
;;; method numbering the corpus traces are read against.  If a dependency bump
;;; ever moves one of these, this suite reddens before any trace can lie.
(import (rnrs) (srfi :64) (testing)
        (httparse decisions) (httparse methods))

(run-suite "flag-pins"
  (lambda ()
    ;; the two the brief names explicitly
    (test-eqv "F-CONNECTION-CLOSE = 1<<1" 2  F-CONNECTION-CLOSE)
    (test-eqv "F-SKIP-BODY = 1<<6"        64 F-SKIP-BODY)

    ;; the neighbours the connection layer reads alongside them
    (test-eqv "F-CONNECTION-KEEP-ALIVE" 1   F-CONNECTION-KEEP-ALIVE)
    (test-eqv "F-CONTENT-LENGTH"        32  F-CONTENT-LENGTH)
    (test-eqv "F-TRANSFER-ENCODING = 1<<9 (not 1<<8)" 512 F-TRANSFER-ENCODING)

    ;; method numbers the traces key on (oracle: llhttp method table)
    (test-eqv "GET is 1"     1 (httparse-method-number 'GET))
    (test-eqv "HEAD is 2"    2 (httparse-method-number 'HEAD))
    (test-eqv "CONNECT is 5" 5 (httparse-method-number 'CONNECT))))
