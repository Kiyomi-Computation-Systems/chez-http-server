#!r6rs
;;; (http-server headers): ASCII case-insensitive field-name operations over a
;;; header alist, the byte helpers a field value's list is read with, and
;;; whether a field's list holds a token (M6.4).  Oracles: RFC 9110 §5.1
;;; (field names are case-insensitive), §5.6.1 (lists) and §5.6.3 (OWS is SP
;;; and HTAB).  Names and values are bytevectors or spans: the
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
                         (3 10 "chunkex")))))

    ;; --- a token in a field's list (M6.4) ---------------------------------------------
    ;; RFC 9110 §5.6.1: a list-based field is `#element`, its elements
    ;; separated by commas with OWS around them, and empty elements are no
    ;; elements; a list may run over several lines of the same field (§5.3).
    ;; Expect's value is case-insensitive (§10.1.1).
    (let ((lists (lambda (fields) (if (field-lists? (map (lambda (f) (cons (b (car f)) (b (cdr f)))) fields)
                                                    (b "expect") (b "100-continue"))
                                      'lists 'not))))
      (test-equal "field-lists? finds a token as an element of a field's list, in any case, over any of its lines"
                  '(lists lists lists lists lists lists)
                  (map lists '((("Expect" . "100-continue"))
                               (("expect" . "100-CONTINUE"))
                               (("Expect" . "foo, 100-continue"))
                               (("Expect" . " ,\t100-continue ,"))
                               (("Host" . "x") ("Expect" . "foo") ("EXPECT" . "100-continue"))
                               (("Expect" . "100-continue, foo")))))
      (test-equal "…and nothing else: a near miss, a token inside an element, another field, none"
                  '(not not not not not not not)
                  (map lists '((("Expect" . "100-continues"))
                               (("Expect" . "x100-continue"))
                               (("Expect" . "100-continue=1"))
                               (("Expect" . "100 continue"))
                               (("X-Expect" . "100-continue"))
                               (("Expect" . ""))
                               ()))))
    ;; The core's head keeps its fields as spans of the delivery.
    (let* ((wire (b "POST / HTTP/1.1\r\nExpect: a, 100-continue\r\n"))
           (sp (lambda (from to) (make-span wire from to))))
      (test-eq "field-lists? reads a span's list in place, honouring its bounds" 'in-bounds
               (if (and (field-lists? (list (cons (sp 17 23) (sp 25 40))) (b "expect") (b "100-continue"))
                        (not (field-lists? (list (cons (sp 17 23) (sp 25 39))) (b "expect") (b "100-continue"))))
                   'in-bounds
                   'out-of-bounds)))))
