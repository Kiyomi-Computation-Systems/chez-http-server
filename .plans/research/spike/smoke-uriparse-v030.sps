#!r6rs
;; uriparse v0.3.0: #11 uri-collector-reset! -- one collector per connection.
;; A reset-and-reparse must equal a fresh parse (components AND offsets), no stale
;; span may leak, the embedder-chosen mode must survive, and a reset after an error
;; result must work. Then the allocation a reused collector saves, measured once.
;; The reset serves feed!/finish! only: uri-parse-validate and the authority-form validator
;; build their own collector (collect.sls:271-275, 370), so a server validating its targets
;; does not get this until validation is exported over a parse result (uriparse #18).
(import (rnrs) (uri collect) (uri components) (only (chezscheme) real-time collect statistics sstats-bytes))
(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))
(define (bv s) (string->utf8 s))
(define (fresh mode s) (uri-parse mode (bv s)))
(define (reuse mode a b)   ; parse a, reset, parse b -> the result of b
  (let ((c (make-uri-collector mode)) (ba (bv a)) (bb (bv b)))
    (uri-collect-feed! c ba 0 (bytevector-length ba)) (uri-collect-finish! c)
    (uri-collector-reset! c)
    (uri-collect-feed! c bb 0 (bytevector-length bb)) (uri-collect-finish! c)))
(define (offsets r) (map (lambda (c) (uri-parse-component-offset r c)) '(scheme authority path query fragment)))
(define (same? got want)
  (and (uri-parse-ok? got) (uri-parse-ok? want)
       (uri-components=? (uri-parse-components got) (uri-parse-components want))
       (equal? (offsets got) (offsets want))))
(define (row mode a b)
  (let ((got (reuse mode a b)))
    (show (list mode a '-> b 'reuse==fresh (same? got (fresh mode b)) 'offsets (offsets got)))))
(display "--- #11: reset-and-reparse equals a fresh collector (components and offsets; expect #t in every row)") (newline)
(row 'uri "http://a/b?q#f" "http://h/x")
(row 'uri "http:/p" "http://a/x")              ; rooted, then not: the rooted flag must clear
(row 'uri-reference "g/h" "/p")                ; segment verdict, then a rooted path with no leading token
(row 'uri-reference "g:h" "a/b")               ; scheme verdict, then segment verdict
(row 'relative-ref "//a/b?q" "p/q")
(let ((got (reuse 'uri "http://a/p?q=1#top" "http://a/x")))
  (show "stale query and fragment absent after reset (expect #t #t):"
        (uri-component-absent? (uri-components-query (uri-parse-components got)))
        (uri-component-absent? (uri-components-fragment (uri-parse-components got)))))
(let ((got (reuse 'relative-ref "//h/a" "b/c")))
  (show "mode survives the reset (expect #t b/c):" (uri-parse-ok? got) (utf8->string (uri-components-path (uri-parse-components got)))))
(let ((c (make-uri-collector 'uri)) (bad (bv "nocolon")) (ok (bv "http://h/x")))
  (uri-collect-feed! c bad 0 (bytevector-length bad))
  (let ((r1 (uri-collect-finish! c)))
    (uri-collector-reset! c)
    (uri-collect-feed! c ok 0 (bytevector-length ok))
    (show "reset after an error result (expect (err scheme-required N) #t):"
          (list 'err (uri-parse-error-code r1) (uri-parse-error-offset r1))
          (same? (uri-collect-finish! c) (fresh 'uri "http://h/x")))))
;; --- the per-request allocation, measured once (not a standing lane) -------
(define target (bv "/api/v1/items/12345?fields=name,price&limit=50"))
(define n 200000)
(define (measure label thunk)
  (collect)
  (let* ((b0 (sstats-bytes (statistics))) (t0 (real-time)))
    (thunk)
    (let ((ms (- (real-time) t0)) (bytes (- (sstats-bytes (statistics)) b0)))
      (show label 'per-parse-bytes (div bytes n) 'ns (div (* ms 1000000) n))
      (cons (div bytes n) (div (* ms 1000000) n)))))
(define (fresh-pass)
  (let lp ((i 0)) (when (fx<? i n) (uri-parse 'uri-reference target) (lp (fx+ i 1)))))
(define (reuse-pass)
  (let ((c (make-uri-collector 'uri-reference)))
    (let lp ((i 0))
      (when (fx<? i n)
        (uri-collect-feed! c target 0 (bytevector-length target)) (uri-collect-finish! c)
        (uri-collector-reset! c) (lp (fx+ i 1))))))
(let ((b0 (sstats-bytes (statistics)))) (make-bytevector 1048576 0)
  (show "calibration: sstats-bytes grows by about 1048576 for a 1 MiB bytevector ->" (- (sstats-bytes (statistics)) b0)))
(show "--- one" (string-append "'" (symbol->string 'uri-reference)) "target of" (bytevector-length target) "bytes," n "parses per pass, fresh collector vs one reset collector")
(define f1 (measure "fresh:" fresh-pass))
(define r1 (measure "reuse:" reuse-pass))
(define f2 (measure "fresh:" fresh-pass))
(define r2 (measure "reuse:" reuse-pass))
(show "fresh/reuse bytes ratio:" (div (+ (car f1) (car f2)) (max 1 (+ (car r1) (car r2)))) "time ratio x10:" (div (* 10 (+ (cdr f1) (cdr f2))) (max 1 (+ (cdr r1) (cdr r2)))))
(display "done") (newline)
