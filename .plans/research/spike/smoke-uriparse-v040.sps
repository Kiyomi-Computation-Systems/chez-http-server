#!r6rs
;; uriparse v0.4.0: #18 uri-parse-result-validate -- validate a reused collector's result.
;; The claim to check: validation is a pure function of the parse result, so a reset-and-reused
;; collector's `uri-collect-finish!` result, passed to `uri-parse-result-validate`, reaches the
;; same verdict (ok, or code + absolute offset) as a fresh `uri-parse-validate` of the same bytes;
;; a structural error and a clean result come back as the argument itself (eq?). Then the
;; validated per-request allocation with one collector per connection, measured once.
(import (rnrs) (uri collect) (uri components) (only (chezscheme) real-time collect statistics sstats-bytes))
(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))
(define (bv s) (string->utf8 s))
(define (verdict r)
  (if (uri-parse-ok? r) 'ok (list 'err (uri-parse-error-code r) (uri-parse-error-offset r))))
;; parse `prior`, reset, parse `s`, validate the finish result
(define (reuse-validate mode prior s)
  (let ((c (make-uri-collector mode)) (bp (bv prior)) (bs (bv s)))
    (uri-collect-feed! c bp 0 (bytevector-length bp)) (uri-collect-finish! c)
    (uri-collector-reset! c)
    (uri-collect-feed! c bs 0 (bytevector-length bs))
    (let ((r (uri-collect-finish! c)))
      (cons r (uri-parse-result-validate r)))))
(define (row mode prior s)
  (let* ((fresh (uri-parse-validate mode (bv s)))
         (rv (reuse-validate mode prior s)) (raw (car rv)) (validated (cdr rv)))
    (show (list mode s 'fresh (verdict fresh) 'reused (verdict validated)
                'agree (equal? (verdict fresh) (verdict validated))
                'identity (if (eq? raw validated) 'same-object 'new-error-result)))))
(display "--- #18: reused collector + uri-parse-result-validate == fresh uri-parse-validate (expect agree #t in every row)") (newline)
(row 'uri-reference "/prior?x=1#f" "/api/v1/items/12345?fields=name,price&limit=50")   ; clean origin-form: ok, same object
(row 'uri-reference "/prior?x=1#f" "/a b")                                              ; SP in path: charset error
(row 'uri-reference "/prior?x=1#f" "/a<b>?q=1")                                         ; '<' in path
(row 'uri-reference "/ok" "/ok?q=a b")                                                  ; SP in query, after a clean prior
(row 'uri "http://h/x" "http://exa mple.com/p")                                         ; SP in host: host grammar (M4)
(row 'uri "http://h/x" "http://h:8x/p")                                                 ; bad port
(row 'uri "http://h/x" "nocolon")                                                       ; structural error: passes through unchanged
(row 'uri "http://h/x" "http://example.com/p?q#f")                                      ; clean absolute-form
(display "--- authority-form is unchanged in v0.4.0: its strict validator still parses fresh (collect.sls:385)") (newline)
(show (verdict (uri-parse-authority-form-validate (bv "example.com:443"))) (verdict (uri-parse-authority-form-validate (bv "example.com"))))
;; --- validated per-request allocation, measured once (not a standing lane) ------------
(define target (bv "/api/v1/items/12345?fields=name,price&limit=50"))
(define n 200000)
(define (measure label thunk)
  (collect)
  (let* ((b0 (sstats-bytes (statistics))) (t0 (real-time)))
    (thunk)
    (let ((ms (- (real-time) t0)) (bytes (- (sstats-bytes (statistics)) b0)))
      (show label 'per-parse-bytes (div bytes n) 'ns (div (* ms 1000000) n))
      (cons (div bytes n) (div (* ms 1000000) n)))))
(define (fresh-validated-pass)
  (let lp ((i 0)) (when (fx<? i n) (uri-parse-validate 'uri-reference target) (lp (fx+ i 1)))))
(define (reuse-validated-pass)
  (let ((c (make-uri-collector 'uri-reference)))
    (let lp ((i 0))
      (when (fx<? i n)
        (uri-collect-feed! c target 0 (bytevector-length target))
        (uri-parse-result-validate (uri-collect-finish! c))
        (uri-collector-reset! c) (lp (fx+ i 1))))))
(show "--- one 'uri-reference target of" (bytevector-length target) "bytes," n "validated parses per pass: fresh uri-parse-validate vs one reset collector + uri-parse-result-validate")
(define f1 (measure "fresh+validate:" fresh-validated-pass))
(define r1 (measure "reuse+validate:" reuse-validated-pass))
(define f2 (measure "fresh+validate:" fresh-validated-pass))
(define r2 (measure "reuse+validate:" reuse-validated-pass))
(show "fresh/reuse bytes ratio:" (div (+ (car f1) (car f2)) (max 1 (+ (car r1) (car r2)))) "time ratio x10:" (div (* 10 (+ (cdr f1) (cdr f2))) (max 1 (+ (cdr r1) (cdr r2)))))
(display "done") (newline)
