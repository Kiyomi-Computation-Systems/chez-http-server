#!r6rs
;;; (http-server headers): ASCII case-insensitive field-name operations over a
;;; header alist, and the byte helpers a field value's list is read with.
;;; Oracles: RFC 9110 §5.1 (field names are case-insensitive) and §5.6.3
;;; (OWS is SP and HTAB).  Names and values are bytevectors or spans: the
;;; connection core builds a request's headers as spans of the delivery
;;; (design §7.1).
(import (rnrs) (srfi :64) (testing) (http-server headers) (http-server span))

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
    (test-eq "name=? non-alpha byte" 'same (if (header-name=? (b "X-1_a") (b "x-1_A")) 'same 'diff))

    ;; --- spans: a request's headers as the core builds them ---
    ;; One delivery, read as spans of it.  The headers follow the request
    ;; line, so no span starts at 0 and every comparison has to honour the
    ;; span's start.
    (let* ((wire (b "GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\nx-a: 2\r\n"))
           (sp (lambda (from to) (make-span wire from to)))
           (spans (list (cons (sp 16 20) (sp 22 23))
                        (cons (sp 25 28) (sp 30 31))
                        (cons (sp 33 36) (sp 38 39)))))
      (test-equal "a bytevector query finds a span name, case folded"
                  (b "x") (span->bytevector (headers-ref spans (b "HOST"))))
      (test-equal "ref-all over spans keeps wire order"
                  (list (b "1") (b "2"))
                  (map span->bytevector (headers-ref-all spans (b "x-a"))))
      (test-eq "a miss over spans is absent" 'absent (or (headers-ref spans (b "Hos")) 'absent))
      (test-eq "name=? compares a span with a bytevector" 'same
               (if (header-name=? (sp 25 28) (b "x-A")) 'same 'diff))
      (test-eq "name=? compares two spans at different offsets" 'same
               (if (header-name=? (sp 25 28) (sp 33 36)) 'same 'diff))
      (test-eq "name=? on spans is length-sensitive" 'diff
               (if (header-name=? (sp 25 28) (sp 25 27)) 'same 'diff)))

    ;; --- the byte helpers ---------------------------------------------------------
    (let ((bv (b "x\t Chunked \ty")))
      (test-equal "OWS is SP and HTAB, and nothing else"
                  '(#t #t #f #f #f)
                  (map (lambda (c) (if (ows? c) #t #f)) '(32 9 10 13 120)))
      (test-equal "trim-ows drops the OWS around a range, and only that"
                  '((3 10) (3 10) (5 5))
                  (list (call-with-values (lambda () (trim-ows bv 1 12)) list)
                        (call-with-values (lambda () (trim-ows bv 3 10)) list)
                        (call-with-values (lambda () (trim-ows (b "     ") 0 5)) list)))
      (test-equal "range-ci=? compares a range with a token, all of it, without regard to case"
                  '(same same diff diff diff)
                  (map (lambda (r) (if (range-ci=? bv (car r) (cadr r) (b (caddr r))) 'same 'diff))
                       '((3 10 "chunked") (3 10 "CHUNKED") (3 9 "chunked") (3 10 "chunk")
                         (3 10 "chunkex")))))))
