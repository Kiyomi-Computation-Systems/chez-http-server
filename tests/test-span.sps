#!r6rs
;;; (http-server span): a span is the bytes [start, end) of a bytevector, kept
;;; without copying (the core retains spans of the delivery for the request
;;; head).  Oracle: the bytes the span was made over.
(import (rnrs) (srfi :64) (testing) (http-server span))

(define (b s) (string->utf8 s))

;; verdict : (-> Any) -> (U 'accepted 'refused)
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (thunk)
    'accepted))

(run-suite "span"
  (lambda ()
    (let* ((bv (b "GET /index.html HTTP/1.1"))
           (s (make-span bv 4 15)))
      (test-eq    "the bytevector reads back, not a copy" 'same
                  (if (eq? bv (span-bytevector s)) 'same 'copied))
      (test-eqv   "start reads back"  4  (span-start s))
      (test-eqv   "end reads back"    15 (span-end s))
      (test-eqv   "length is end - start" 11 (span-length s))
      (test-equal "span->bytevector is exactly [start, end)"
                  (b "/index.html") (span->bytevector s))
      (let ((copy (span->bytevector s)))
        (bytevector-u8-set! copy 0 (char->integer #\X))
        (test-equal "and it is a copy: writing it leaves the delivery alone"
                    (b "GET /index.html HTTP/1.1") bv))
      (test-eq "span? accepts a span" 'yes (if (span? s) 'yes 'no))
      (test-eq "span? rejects a bytevector" 'no (if (span? bv) 'yes 'no)))

    (let ((empty (make-span (b "abc") 3 3)))
      (test-eqv   "an empty span is allowed" 0 (span-length empty))
      (test-equal "and copies to an empty bytevector" (b "") (span->bytevector empty)))

    ;; A span outside its bytevector is a caller bug, refused at construction.
    (test-eq "start past end is refused" 'refused
             (verdict (lambda () (make-span (b "abc") 2 1))))
    (test-eq "end past the bytevector is refused" 'refused
             (verdict (lambda () (make-span (b "abc") 0 4))))
    (test-eq "a negative start is refused" 'refused
             (verdict (lambda () (make-span (b "abc") -1 2))))
    (test-eq "a span over a string is refused" 'refused
             (verdict (lambda () (make-span "abc" 0 1))))))
