#!r6rs
;; uriparse v0.5.0: #21 validate-component over a range -- judge a span in place.
;; The claims to check, on the pinned tree: (1) the ranged call's verdict on bv[start, end) is
;; the two-argument call's verdict on a copy of those bytes, code and component-relative index,
;; even when the bytes around the span are ones the component refuses (a request line's spaces);
;; (2) a "%" whose HEXDIGs lie past end is malformed, though the bytes after end would complete
;; it; (3) the ranged call allocates nothing, where judging a copy costs the copy.  Origin-form
;; is split at its first "?" the way (http-server target) splits it.
(import (rnrs) (uri charset) (only (chezscheme) real-time collect statistics sstats-bytes))
;; show : Any ... -> Void — the items on one line, one space apart.
(define (show x . xs) (display x) (for-each (lambda (x) (display " ") (display x)) xs) (newline))
(define (bv s) (string->utf8 s))
(define (first-question b s e)
  (let lp ((i s)) (cond ((fx=? i e) e) ((fx=? (bytevector-u8-ref b i) 63) i) (else (lp (fx+ i 1))))))
(define (copy b s e)
  (let ((out (make-bytevector (fx- e s)))) (bytevector-copy! b s out 0 (fx- e s)) out))
(define (verdict thunk) (call-with-values thunk list))
;; one component judged both ways: in place, and on a copy
(define (both component b s e)
  (let ((ranged (verdict (lambda () (validate-component component b s e))))
        (copied (verdict (lambda () (validate-component component (copy b s e))))))
    (list component ranged copied (if (equal? ranged copied) 'agree 'DISAGREE))))
;; in-request-line : String -> (values Bytevector Nat Nat)
;; The target inside a request line, "GET " target " HTTP/1.1", and its bounds there.
(define (in-request-line target)
  (let ((t (bv target)))
    (values (bv (string-append "GET " target " HTTP/1.1")) 4 (fx+ 4 (bytevector-length t)))))
(define (row target)
  (let-values (((line s e) (in-request-line target)))
    (let ((q (first-question line s e)))
      (show target (both 'path line s q)
            (if (fx<? q e) (both 'query line (fx+ q 1) e) 'no-query)))))
(display "--- #21: ranged verdict == the verdict on a copy (expect agree in every component)") (newline)
(row "/")
(row "/api/v1/items/12345?fields=name,price&limit=50")
(row "//a@b:c/d")                        ; origin-form; a collector would read an authority here
(row "/a<b>?q=1")                        ; '<' in the path, index 2
(row "/ok?q=a\"b")                       ; '"' in the query, index 3
(row "/x?a[]=1&b=|")                     ; '[' in the query (decision 0009's redirect case)
(row "/p%zz")                            ; malformed pct-encoded at the '%', index 2
(display "--- a '%' whose HEXDIGs lie past end is malformed, though the bytes after end complete it") (newline)
(let ((b (bv "/a%41")))
  (show "whole /a%41:" (verdict (lambda () (validate-component 'path b 0 5)))
        "range [0,4) /a%4:" (verdict (lambda () (validate-component 'path b 0 4)))
        "range [1,5) a%41:" (verdict (lambda () (validate-component 'path b 1 5)))))
;; --- per-call allocation, measured once (not a standing lane) ------------------------------
(define n 200000)
(define (measure label target thunk)
  (collect)
  (let* ((b0 (sstats-bytes (statistics))) (t0 (real-time)))
    (thunk)
    (let ((ms (- (real-time) t0)) (bytes (- (sstats-bytes (statistics)) b0)))
      (show label (bytevector-length (bv target)) 'bytes-per-target (div bytes n) 'ns (div (* ms 1000000) n)))))
(define (pass judge target)
  (let-values (((line s e) (in-request-line target)))
    (lambda ()
      (let lp ((i 0))
        (when (fx<? i n)
          (let ((q (first-question line s e)))
            (judge 'path line s q)
            (when (fx<? q e) (judge 'query line (fx+ q 1) e)))
          (lp (fx+ i 1)))))))
(define (in-place component b s e) (validate-component component b s e))
(define (on-copy component b s e) (validate-component component (copy b s e)))
(define targets
  (list "/a" "/api/v1/items/12345?fields=name,price&limit=50"
        (string-append "/" (make-string 499 #\a))))
(show "---" n "origin-form targets judged per pass, path and query: in place vs on a copy")
;; Two passes, so that a warm-up effect would show as a difference between them.
(for-each (lambda (t)
            (measure "in-place:" t (pass in-place t))
            (measure "on-copy: " t (pass on-copy t)))
          targets)
(for-each (lambda (t)
            (measure "in-place:" t (pass in-place t))
            (measure "on-copy: " t (pass on-copy t)))
          targets)
(display "done") (newline)
