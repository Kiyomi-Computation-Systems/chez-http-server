#!r6rs
;; uriparse v0.6.0: #24 validate-authority and authority-host-span over a range.
;; The claims to check, on the pinned tree: (1) the ranged verdict on a Host value inside
;; its header line is the verdict on a copy of the value, code and start-relative index,
;; though the bytes after the value hold "@", "[", ":" and "]"; (2) the ranged host bounds
;; are the copy's bounds, relative to start, so a userinfo shows as a host start other
;; than 0, and an "@" past the value's end is none; (3) the ranged calls allocate nothing,
;; where judging a copy costs the copy; (4) validate-component, whose range check moved to
;; (uri range) in this release, still judges a path as v0.5.0 did.
(import (rnrs) (uri host) (uri charset) (only (chezscheme) real-time collect statistics sstats-bytes))
;; show : Any ... -> Void — the items on one line, one space apart.
(define (show x . xs) (display x) (for-each (lambda (x) (display " ") (display x)) xs) (newline))
(define (bv s) (string->utf8 s))
(define (copy b s e)
  (let ((out (make-bytevector (fx- e s)))) (bytevector-copy! b s out 0 (fx- e s)) out))
(define (verdict thunk) (call-with-values thunk list))
;; in-header-line : String -> (values Bytevector Nat Nat)
;; The value inside "Host: " value "\r\nX: @[:]\r\n", and its bounds there.
(define (in-header-line value)
  (let ((v (bv value)))
    (values (bv (string-append "Host: " value "\r\nX: @[:]\r\n")) 6 (fx+ 6 (bytevector-length v)))))
(define (row value)
  (let-values (((line s e) (in-header-line value)))
    (let ((ranged (verdict (lambda () (validate-authority line s e))))
          (copied (verdict (lambda () (validate-authority (copy line s e)))))
          (span-ranged (verdict (lambda () (authority-host-span line s e))))
          (span-copied (verdict (lambda () (authority-host-span (copy line s e))))))
      (show (string-append "\"" value "\"") 'verdict ranged copied
            'host-span span-ranged span-copied
            (if (and (equal? ranged copied) (equal? span-ranged span-copied)) 'agree 'DISAGREE)))))
(display "--- #24: ranged == on a copy, verdict and host bounds (expect agree in every row)") (newline)
(for-each row '("x" "example.com" "example.com:8080" "[::1]:8080" "" "a b" "h:x" "[::1" "u@h" "h%zz" "h%4"))
(display "--- an \"@\" past the value's end splits nothing: the value \"h\" of \"h@x\"") (newline)
(let ((b (bv "h@x")))
  (show "whole h@x:" (verdict (lambda () (authority-host-span b)))
        "range [0,1) h:" (verdict (lambda () (authority-host-span b 0 1)))))
(display "--- validate-component after its range check moved to (uri range)") (newline)
(let ((b (bv "GET /a%4?q HTTP/1.1")))
  (show "path [4,8) /a%4:" (verdict (lambda () (validate-component 'path b 4 8)))
        "query [9,10) q:" (verdict (lambda () (validate-component 'query b 9 10)))))
;; --- per-call allocation, measured once (not a standing lane) ------------------------------
(define n 200000)
(define (measure label value thunk)
  (collect)
  (let* ((b0 (sstats-bytes (statistics))) (t0 (real-time)))
    (thunk)
    (let ((ms (- (real-time) t0)) (bytes (- (sstats-bytes (statistics)) b0)))
      (show label (bytevector-length (bv value)) 'bytes-per-value (div bytes n) 'ns (div (* ms 1000000) n)))))
(define (pass judge value)
  (let-values (((line s e) (in-header-line value)))
    (lambda ()
      (let lp ((i 0))
        (when (fx<? i n) (judge line s e) (lp (fx+ i 1)))))))
(define (in-place b s e)
  (validate-authority b s e)
  (authority-host-span b s e))
(define (on-copy b s e)
  (let ((c (copy b s e)))
    (validate-authority c)
    (authority-host-span c)))
(define values-measured '("x" "example.com:8080" "www.some-long-host-name.example.co.uk:443"))
(show "---" n "Host values judged per pass, validity and host bounds: in place vs on a copy")
;; Two passes, so that a warm-up effect would show as a difference between them.
(for-each (lambda (v)
            (measure "in-place:" v (pass in-place v))
            (measure "on-copy: " v (pass on-copy v)))
          values-measured)
(for-each (lambda (v)
            (measure "in-place:" v (pass in-place v))
            (measure "on-copy: " v (pass on-copy v)))
          values-measured)
(display "done") (newline)
