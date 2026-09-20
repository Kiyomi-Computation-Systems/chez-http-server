#!r6rs
;;; (http-server headers): ASCII case-insensitive field-name operations over a
;;; header alist.  Oracle: RFC 9110 §5.1 (field names are case-insensitive).
(import (rnrs) (srfi :64) (testing) (http-server headers))

(define (b s) (string->utf8 s))

(run-suite "headers"
  (lambda ()
    (define hs (list (cons (b "Host") (b "example.com"))
                     (cons (b "X-A") (b "1"))
                     (cons (b "x-a") (b "2"))))

    ;; case-insensitive lookup returns the first match's value
    (test-equal "lower-case query hits Host" (b "example.com") (headers-ref hs (b "host")))
    (test-equal "upper-case query hits Host" (b "example.com") (headers-ref hs (b "HOST")))
    (test-equal "exact match"                (b "1")           (headers-ref hs (b "X-A")))

    ;; a miss returns #f — asserted via a positive sentinel (footgun-safe)
    (test-eq "a miss is absent" 'absent (or (headers-ref hs (b "Nope")) 'absent))

    ;; ref-all keeps wire order across case variants
    (test-equal "ref-all across case" (list (b "1") (b "2")) (headers-ref-all hs (b "x-a")))
    (test-equal "ref-all miss is empty" '() (headers-ref-all hs (b "Nope")))

    ;; header-name=? folds ASCII case and is length-sensitive
    (test-eq "name=? folds case"     'same (if (header-name=? (b "Content-Length") (b "content-length")) 'same 'diff))
    (test-eq "name=? rejects prefix" 'diff (if (header-name=? (b "X") (b "XY")) 'same 'diff))
    (test-eq "name=? non-alpha byte" 'same (if (header-name=? (b "X-1_a") (b "x-1_A")) 'same 'diff))))
