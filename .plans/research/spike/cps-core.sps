#!r6rs
;;; Spike A: a CPS connection CORE over chez-httparse, no sockets.
;;; Questions measured:
;;;  1. pipelining: pause at on-message-complete; is `consumed` the boundary?
;;;  2. body backpressure: pause inside on-body-data; resume at every chunk size
;;;     and get the same body bytes + event sequence as the whole-buffer run.
;;;  3. Connection: close then another request -> parser error (data-after-close).
;;;  4. allocation per keep-alive GET through the core with a trivial handler.
(import (rnrs)
        (generated httparse-message)
        (httparse modes)
        (byte-machine runtime)
        (only (chezscheme) bytes-allocated printf format statistics sstats-bytes))

;; llhttp's own flag bits (src/httparse/grammar.sls:301-306; not exported).
(define F-CONNECTION-KEEP-ALIVE 1)
(define F-CONNECTION-CLOSE 2)
(define F-CHUNKED 8)

(define (bv-append . bvs)
  (let* ((n (apply + (map bytevector-length bvs))) (out (make-bytevector n)))
    (let loop ((bs bvs) (at 0))
      (if (null? bs) out
          (begin (bytevector-copy! (car bs) 0 out at (bytevector-length (car bs)))
                 (loop (cdr bs) (+ at (bytevector-length (car bs)))))))))
(define (sub bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

;; --- the request builder: what the 25 callbacks fold into --------------------
(define-record-type rb
  (fields (mutable method) (mutable url) (mutable field) (mutable value)
          (mutable headers) (mutable body-parts) (mutable close?) (mutable events)))
(define (new-rb) (make-rb '() '() '() '() '() '() #f '()))
(define (rb-note! r ev) (rb-events-set! r (cons ev (rb-events r))))

;; ctx is a mutable cell holding the current builder plus the "sink" policy.
(define-record-type ctx
  (fields (mutable rb) (mutable done) (mutable pause-on-body?) (mutable pause-on-complete?)))

(define (bindings)
  (define (accum get set!) (lambda (p c bv from to) (set! (ctx-rb c) (cons (sub bv from to) (get (ctx-rb c)))) callback-continue))
  (define (ev name) (lambda (p c) (rb-note! (ctx-rb c) name) callback-continue))
  (define (join parts) (let* ((n (apply + (map bytevector-length parts))) (out (make-bytevector n)))
                         (let loop ((ps (reverse parts)) (at 0))
                           (if (null? ps) out
                               (begin (bytevector-copy! (car ps) 0 out at (bytevector-length (car ps)))
                                      (loop (cdr ps) (+ at (bytevector-length (car ps)))))))))
  (list (list 'on-reset (ev 'reset))
        (list 'on-message-begin (lambda (p c) (ctx-rb-set! c (new-rb)) (rb-note! (ctx-rb c) 'begin) callback-continue))
        (list 'on-method-data (accum rb-method rb-method-set!))
        (list 'on-method-complete (ev 'method))
        (list 'on-url-data (accum rb-url rb-url-set!))
        (list 'on-url-complete (ev 'url))
        (list 'on-protocol-data (lambda (p c bv f t) callback-continue))
        (list 'on-protocol-complete (ev 'protocol))
        (list 'on-version-data (lambda (p c bv f t) callback-continue))
        (list 'on-version-complete (ev 'version))
        (list 'on-status-data (lambda (p c bv f t) callback-continue))
        (list 'on-status-complete (ev 'status))
        (list 'on-header-field-data (accum rb-field rb-field-set!))
        (list 'on-header-field-complete (ev 'field))
        (list 'on-header-value-data (accum rb-value rb-value-set!))
        (list 'on-header-value-complete
              (lambda (p c) (let ((r (ctx-rb c)))
                              (rb-headers-set! r (cons (cons (join (rb-field r)) (join (rb-value r))) (rb-headers r)))
                              (rb-field-set! r '()) (rb-value-set! r '())
                              (rb-note! r 'value))
                callback-continue))
        (list 'on-headers-complete
              (lambda (p c) ;; READ FLAGS HERE: the inter-message reset zeroes them.
                (let ((flags (parser-field-ref p 'flags)))
                  (rb-close?-set! (ctx-rb c) (not (zero? (bitwise-and flags F-CONNECTION-CLOSE))))
                  (rb-note! (ctx-rb c) (list 'headers-complete 'flags flags 'cl (parser-field-ref p 'content-length))))
                callback-continue))
        (list 'on-body-data
              (lambda (p c bv from to)
                (let ((r (ctx-rb c)))
                  (rb-body-parts-set! r (cons (sub bv from to) (rb-body-parts r)))
                  (rb-note! r (list 'body (- to from))))
                (if (ctx-pause-on-body? c) callback-pause callback-continue)))
        (list 'on-chunk-header (ev 'chunk-header))
        (list 'on-chunk-extension-name-data (lambda (p c bv f t) callback-continue))
        (list 'on-chunk-extension-name-complete (ev 'ext-name))
        (list 'on-chunk-extension-value-data (lambda (p c bv f t) callback-continue))
        (list 'on-chunk-extension-value-complete (ev 'ext-value))
        (list 'on-chunk-complete (ev 'chunk-complete))
        (list 'on-message-complete
              (lambda (p c) (rb-note! (ctx-rb c) 'complete)
                (ctx-done-set! c (cons (ctx-rb c) (ctx-done c)))
                (if (ctx-pause-on-complete? c) callback-pause callback-continue)))))

(define (new-parser c)
  (make-parser httparse-message-machine (bindings) c
               (list (cons 'type (httparse-message-type-value 'request)))))

;; --- 1. pipelining boundary ----------------------------------------------------
(define two (string->utf8 "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"))
(let* ((c (make-ctx #f '() #f #t)) (p (new-parser c)) (len (bytevector-length two)))
  (let ((r1 (parser-feed! p two 0 len)))
    (printf "1a status=~a consumed=~a (first message is ~a bytes) offset=~a\n"
            (parser-result-status r1) (parser-result-consumed r1) 29 (parser-result-stream-offset r1))
    (printf "1a resume -> ~a\n" (parser-resume! p))
    (let ((r2 (parser-feed! p two (parser-result-consumed r1) len)))
      (printf "1b status=~a consumed=~a offset=~a\n" (parser-result-status r2) (parser-result-consumed r2) (parser-result-stream-offset r2))
      (printf "1b events of 2nd message (oldest first): ~a\n" (reverse (rb-events (car (ctx-done c)))))
      (printf "1b urls: ~a\n" (map (lambda (r) (utf8->string (car (rb-url r)))) (reverse (ctx-done c)))))))

;; --- 2. body backpressure at every chunk size -----------------------------------
(define post (string->utf8 "POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"))
(define (run-body-at chunk)
  (let* ((c (make-ctx #f '() #t #t)) (p (new-parser c)) (len (bytevector-length post)))
    ;; FINDING: after a pause the parser is parked PAST the event; a zero-width
    ;; step (message-complete after the last body byte) needs one more feed,
    ;; even an EMPTY one, so the loop feeds again after every resume.
    (let loop ((at 0) (pauses 0) (resumed? #f))
      (if (and (>= at len) (not resumed?))
          (let ((r (car (ctx-done c))))
            (list pauses (utf8->string (apply bv-append (reverse (rb-body-parts r)))) (reverse (rb-events r))))
          (let* ((end (min (+ at chunk) len)) (r (parser-feed! p post at end)))
            (case (parser-result-status r)
              ((need-input) (loop end pauses #f))
              ((paused) (parser-resume! p) (loop (+ at (parser-result-consumed r)) (+ pauses 1) #t))
              (else (list 'unexpected (parser-result-status r)))))))))
(let ((whole (run-body-at (bytevector-length post))))
  (printf "2 whole-buffer: pauses=~a body=~s\n" (car whole) (cadr whole))
  (let check ((k 1) (bad '()))
    (if (> k (bytevector-length post))
        (printf "2 every chunk size 1..~a: body identical=~a, coalesced-event-sequence identical=~a, distinct pause counts=~a\n"
                (bytevector-length post) (null? bad) (null? bad)
                (let loop ((k 1) (acc '())) (if (> k (bytevector-length post)) (list-sort < acc)
                                                (let ((n (car (run-body-at k)))) (loop (+ k 1) (if (memv n acc) acc (cons n acc)))))))
        (let ((r (run-body-at k)))
          ;; body bytes must be identical; events identical once body fragments are coalesced
          (define (coalesce evs) (let loop ((e evs) (acc '())) (cond ((null? e) (reverse acc))
                                                                    ((and (pair? (car e)) (eq? (caar e) 'body) (pair? acc) (pair? (car acc)) (eq? (caar acc) 'body))
                                                                     (loop (cdr e) (cons (list 'body (+ (cadar e) (cadar acc))) (cdr acc))))
                                                                    (else (loop (cdr e) (cons (car e) acc))))))
          (check (+ k 1) (if (and (equal? (cadr r) (cadr whole)) (equal? (coalesce (caddr r)) (coalesce (caddr whole)))) bad (cons k bad)))))))

;; --- 3. Connection: close then more bytes ------------------------------------------
(define closed (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\n\r\n"))
(let* ((c (make-ctx #f '() #f #f)) (p (new-parser c)) (r (parser-feed! p closed 0 (bytevector-length closed))))
  (printf "3 status=~a consumed=~a done=~a close?=~a\n" (parser-result-status r) (parser-result-consumed r)
          (length (ctx-done c)) (rb-close? (car (ctx-done c))))
  (when (eq? (parser-result-status r) 'error)
    (printf "3 error code=~a reason=~s offset=~a\n" (parser-error-code (parser-result-error r))
            (parser-error-reason (parser-result-error r)) (parser-error-offset (parser-result-error r)))))
;; 3b: with pause-on-complete the core never feeds the second request.
(let* ((c (make-ctx #f '() #f #t)) (p (new-parser c)) (r (parser-feed! p closed 0 (bytevector-length closed))))
  (printf "3b with pause-on-complete: status=~a consumed=~a (first msg = 47 bytes) close?=~a\n"
          (parser-result-status r) (parser-result-consumed r) (rb-close? (car (ctx-done c)))))

;; --- 4. allocation per keep-alive GET through the core -------------------------------
(define one (string->utf8 "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
(define (serve-n n)
  ;; one parser per connection, N messages through it, handler = drop the request.
  (let* ((c (make-ctx #f '() #f #t)) (p (new-parser c)) (len (bytevector-length one)))
    (let loop ((i 0))
      (when (< i n)
        (let ((r (parser-feed! p one 0 len)))
          (unless (eq? (parser-result-status r) 'paused) (error 'serve-n "unexpected" (parser-result-status r)))
          (ctx-done-set! c '())            ; the handler consumed it
          (parser-resume! p)
          (loop (+ i 1)))))))
(serve-n 1000)
(let ((before (sstats-bytes (statistics))))
  (serve-n 10000)
  (printf "4 bytes allocated per request (parser + builder copies of method/url/3 headers): ~a\n"
          (div (- (sstats-bytes (statistics)) before) 10000)))
;; 4b: the same with silent (no-copy) bindings, i.e. parser cost alone.
(define (silent)
  (define (e p c) callback-continue) (define (s p c bv f t) callback-continue)
  (map (lambda (b) (list (car b) (if (memq (car b) '(on-method-data on-url-data on-protocol-data on-version-data on-status-data
                                                       on-header-field-data on-header-value-data on-body-data
                                                       on-chunk-extension-name-data on-chunk-extension-value-data)) s e)))
       (bindings)))
(let* ((p (make-parser httparse-message-machine (silent) #f (list (cons 'type (httparse-message-type-value 'request)))))
       (len (bytevector-length one))
       (go (lambda (n) (let loop ((i 0)) (when (< i n) (parser-feed! p one 0 len) (loop (+ i 1)))))))
  (go 1000)
  (let ((before (sstats-bytes (statistics)))) (go 10000)
    (printf "4b bytes allocated per request, parser alone (silent bindings, no pause): ~a\n" (div (- (sstats-bytes (statistics)) before) 10000))))
