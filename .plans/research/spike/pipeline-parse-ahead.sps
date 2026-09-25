#!r6rs
;; 2026-09-25, for decision 0004 item 2: what pausing at every message's end
;; costs the parser, against parsing ahead.  16 pipelined keep-alive GETs in
;; one buffer, the CPS workload's request repeated, parsed with silent
;; bindings: (a) paused at every on-message-complete, resumed and fed on from
;; parser-result-next, as the serial core does; (b) never paused, the parser's
;; share of a parse-ahead design.  Time is CPU time over 320,000 requests,
;; after a warm-up; bytes are the cumulative sstats-bytes counter, never the
;; live heap.  Each pass runs twice, so a warm-up effect would show.
;; Run on the project's library path (the ledger's entry gives it).
(import (rnrs) (generated httparse-message) (httparse modes) (byte-machine runtime)
        (only (chezscheme) real-time collect statistics sstats-bytes cpu-time))
(define names '(on-reset on-message-begin on-method-data on-method-complete
      on-url-data on-url-complete on-protocol-data on-protocol-complete
      on-version-data on-version-complete on-status-data on-status-complete
      on-header-field-data on-header-field-complete
      on-header-value-data on-header-value-complete
      on-headers-complete on-body-data on-chunk-header
      on-chunk-extension-name-data on-chunk-extension-name-complete
      on-chunk-extension-value-data on-chunk-extension-value-complete
      on-chunk-complete on-message-complete))
(define spans '(on-method-data on-url-data on-protocol-data on-version-data
      on-status-data on-header-field-data on-header-value-data on-body-data
      on-chunk-extension-name-data on-chunk-extension-value-data))
(define (bindings pause?)
  (map (lambda (n) (list n (cond ((memq n spans) (lambda (p c bv f t) callback-continue))
                                 ((and pause? (eq? n 'on-message-complete)) (lambda (p c) callback-pause))
                                 (else (lambda (p c) callback-continue)))))
       names))
(define one "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")
(define depth 16)
(define buf (string->utf8 (apply string-append (let loop ((i 0) (acc '())) (if (= i depth) acc (loop (+ i 1) (cons one acc)))))))
(define len (bytevector-length buf))
(define (parse-all p pause?)
  (let loop ((at 0) (msgs 0))
    (let ((r (parser-feed! p buf at len)))
      (case (parser-result-status r)
        ((paused) (parser-resume! p) (loop (parser-result-next r) (+ msgs 1)))
        ((need-input) msgs)
        (else (error 'parse-all "unexpected" (parser-result-status r)))))))
(define (measure label pause? reps)
  (let ((p (make-parser httparse-message-machine (bindings pause?) #f
                        (list (cons 'type (httparse-message-type-value 'request))))))
    (let warm ((i 0)) (when (< i 2000) (parse-all p pause?) (warm (+ i 1))))
    (collect)
    (let ((b0 (sstats-bytes (statistics))) (t0 (cpu-time)))
      (let loop ((i 0)) (when (< i reps) (parse-all p pause?) (loop (+ i 1))))
      (let ((ms (- (cpu-time) t0)) (bytes (- (sstats-bytes (statistics)) b0)) (reqs (* reps depth)))
        (display (list label 'requests reqs 'ns-per-request (div (* ms 1000000) reqs)
                       'bytes-per-request (div bytes reqs)))
        (newline)))))
(define reps 20000)
(display (list 'buffer len 'bytes depth 'requests)) (newline)
(measure "paused at each end: " #t reps)
(measure "never paused:       " #f reps)
(measure "paused at each end: " #t reps)
(measure "never paused:       " #f reps)
