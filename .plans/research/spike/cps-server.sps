#!r6rs
;;; Spike B: a minimal CPS HTTP/1.1 server on chez-libuv + chez-httparse, loopback,
;;; one in-process client, pipelined requests, a handler that AWAITS uv-getaddrinfo!.
;;; Measures: does the CPS shape work end to end; bytes allocated per request
;;; (server + client, an upper bound); parse-ahead cap + read-stop/read-start.
(import (rnrs)
        (libuv)
        (uv-testing)
        (generated httparse-message)
        (httparse modes)
        (byte-machine runtime)
        (only (chezscheme) bytes-allocated printf format collect statistics sstats-bytes))

(define F-CONNECTION-CLOSE 2)
(define (bv-append . bvs)
  (let* ((n (apply + (map bytevector-length bvs))) (out (make-bytevector n)))
    (let loop ((bs bvs) (at 0))
      (if (null? bs) out
          (begin (bytevector-copy! (car bs) 0 out at (bytevector-length (car bs)))
                 (loop (cdr bs) (+ at (bytevector-length (car bs)))))))))
(define (sub bv from to) (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o))

;; ---- CPS combinators (the whole "framework") --------------------------------------
;; A step is (lambda (k) ...) where k : (err . value) -> unspecified, called once.
;; cps-guard: a synchronous raise inside a step becomes (k err) -- never escapes to libuv.
(define (cps-guard step k)
  (guard (e (#t (k e #f))) (step k)))
;; cps-each: run (f item k) for each item in order, stop at first err.
(define (cps-each items f k)
  (let loop ((xs items))
    (if (null? xs) (k #f #f)
        (cps-guard (lambda (k1) (f (car xs) k1))
                   (lambda (err v) (if err (k err #f) (loop (cdr xs))))))))

;; ---- request record ----------------------------------------------------------------
(define-record-type req (fields (mutable method) (mutable url) (mutable headers) (mutable close?) (mutable body)))
(define-record-type conn
  (fields tcp (mutable parser) loop
          (mutable cur) (mutable queue) (mutable busy?) (mutable pending) (mutable reading?)
          (mutable out-bytes) (mutable closed?) (mutable served) (mutable stops)))
(define cap 4)  ; parse-ahead cap on queued, not-yet-answered requests

(define (bindings)
  (define (e p c) callback-continue)
  (define (s p c bv f t) callback-continue)
  (define (accum set! get) (lambda (p c bv f t) (let ((r (conn-cur c))) (set! r (cons (sub bv f t) (get r)))) callback-continue))
  (list (list 'on-reset e)
        (list 'on-message-begin (lambda (p c) (conn-cur-set! c (make-req '() '() '() #f '())) callback-continue))
        (list 'on-method-data (accum req-method-set! req-method)) (list 'on-method-complete e)
        (list 'on-url-data (accum req-url-set! req-url)) (list 'on-url-complete e)
        (list 'on-protocol-data s) (list 'on-protocol-complete e)
        (list 'on-version-data s) (list 'on-version-complete e)
        (list 'on-status-data s) (list 'on-status-complete e)
        (list 'on-header-field-data s) (list 'on-header-field-complete e)
        (list 'on-header-value-data s) (list 'on-header-value-complete e)
        (list 'on-headers-complete
              (lambda (p c) (req-close?-set! (conn-cur c) (not (zero? (bitwise-and (parser-field-ref p 'flags) F-CONNECTION-CLOSE)))) callback-continue))
        (list 'on-body-data (accum req-body-set! req-body))
        (list 'on-chunk-header e) (list 'on-chunk-extension-name-data s) (list 'on-chunk-extension-name-complete e)
        (list 'on-chunk-extension-value-data s) (list 'on-chunk-extension-value-complete e) (list 'on-chunk-complete e)
        (list 'on-message-complete
              (lambda (p c) (conn-queue-set! c (append (conn-queue c) (list (conn-cur c)))) callback-pause))))

;; ---- close ownership: exactly one site issues uv-close! ------------------------------
(define (conn-close! c why)
  (unless (conn-closed? c)
    (conn-closed?-set! c #t)
    (uv-close! (conn-tcp c) (lambda () (set! server-closed-conns (+ 1 server-closed-conns))))))
(define server-closed-conns 0)

;; ---- the feed loop: parse at most one message per resume, cap the queue ------------------
(define (conn-feed! c bv start end)
  (let ((r (parser-feed! (conn-parser c) bv start end)))
    (case (parser-result-status r)
      ((need-input) (conn-pending-set! c #f) (conn-pump! c))
      ((paused)
       (let ((next (+ start (parser-result-consumed r))))
         (conn-pending-set! c (if (< next end) (vector bv next end) #f))
         (parser-resume! (conn-parser c))
         (conn-pump! c)))
      ((error)
       (respond! c (make-req '() '() '() #t '()) 400 "bad request\n" (lambda (err v) (conn-close! c 'parser-error))))
      (else (conn-close! c 'terminal)))))

;; pump: dispatch if idle; parse ahead while under cap; stop/start the socket read.
(define (conn-pump! c)
  (cond ((and (not (conn-busy? c)) (pair? (conn-queue c)))
         (let ((r (car (conn-queue c))))
           (conn-queue-set! c (cdr (conn-queue c)))
           (conn-busy?-set! c #t)
           (cps-guard (lambda (k) (handler c r k))
                      (lambda (err v)
                        (conn-busy?-set! c #f)
                        (conn-served-set! c (+ 1 (conn-served c)))
                        (cond (err (respond! c r 500 "handler failed\n" (lambda (e2 v2) (if e2 (conn-close! c 'write-error) (conn-pump! c)))))
                              ((req-close? r) (conn-close! c 'connection-close))
                              (else (conn-pump! c)))))
           ;; keep pumping: parse ahead (up to cap) while the handler is in flight
           (conn-pump! c)))
        ((and (conn-pending c) (< (length (conn-queue c)) cap))
         (let ((p (conn-pending c))) (conn-feed! c (vector-ref p 0) (vector-ref p 1) (vector-ref p 2))))
        ((and (conn-pending c) (conn-reading?  c))
         ;; queue is full and bytes are still buffered: stop the socket read.
         (when (uv-handle-open? (conn-tcp c)) (uv-read-stop! (conn-tcp c)) (conn-reading?-set! c #f) (conn-stops-set! c (+ 1 (conn-stops c)))))
        ((and (not (conn-pending c)) (not (conn-reading? c)) (uv-handle-open? (conn-tcp c)))
         (uv-read-start! (conn-tcp c) (on-data c) (on-eof c) (on-error c)) (conn-reading?-set! c #t))
        (else #f)))

(define (respond! c r status body k)
  (let* ((b (string->utf8 body))
         (head (string->utf8 (string-append "HTTP/1.1 " (number->string status) " OK\r\nContent-Length: "
                                            (number->string (bytevector-length b)) "\r\n"
                                            (if (req-close? r) "Connection: close\r\n" "") "\r\n")))
         (bv (bv-append head b)))
    (if (uv-handle-open? (conn-tcp c))
        (begin
          (conn-out-bytes-set! c (+ (conn-out-bytes c) (bytevector-length bv)))
          (uv-write! (conn-tcp c) bv (lambda (err)
                                       (conn-out-bytes-set! c (- (conn-out-bytes c) (bytevector-length bv)))
                                       (k err #f))))
        (k 'closed #f))))

;; ---- the application handler: CPS, awaits DNS on the first request ------------------------
(define dns-answers 0)
(define (handler c r k)
  (let ((url (utf8->string (apply bv-append (reverse (req-url r))))))
    (cond ((string=? url "/dns")
           (uv-getaddrinfo! (conn-loop c) "localhost" #f '((socktype . stream))
                            (lambda (err results)
                              (set! dns-answers (+ 1 dns-answers))
                              (respond! c r 200 (if err "dns failed\n" (string-append "dns ok " (number->string (length results)) "\n")) k))))
          ((string=? url "/boom") (error 'handler "deliberate"))   ; synchronous raise -> 500, not process death
          (else (respond! c r 200 "hello\n" k)))))

(define (on-data c) (lambda (bv start end) (conn-feed! c bv start end)))
(define (on-eof c) (lambda () (conn-close! c 'eof)))
(define (on-error c) (lambda (err) (conn-close! c 'read-error)))

;; ---- server ------------------------------------------------------------------------------
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(define port (bind-loopback! server))
(define conns '())
(uv-listen! server 128
  (lambda (err)
    (unless err
      (let* ((tcp (uv-accept! server))
             (c (make-conn tcp #f loop #f '() #f #f #t 0 #f 0 0)))
        (set! conns (cons c conns))
        ;; the parser's ctx is the connection: no closure per callback
        (conn-parser-set! c (make-parser httparse-message-machine (bindings) c (list (cons 'type (httparse-message-type-value 'request)))))
        (uv-read-start! tcp (on-data c) (on-eof c) (on-error c))))))

;; ---- client: N pipelined requests in one write, last one Connection: close ---------------------
(define N 200)
(define request-bytes
  (string->utf8
   (apply string-append
          (append (list "GET /dns HTTP/1.1\r\nHost: x\r\n\r\n" "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n")
                  (let loop ((i 0) (acc '())) (if (= i (- N 3)) (reverse acc) (loop (+ i 1) (cons "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\n\r\n" acc))))
                  (list "GET /last HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")))))
(define got (make-byte-collector))
(define client-eof #f)
(define client (make-uv-tcp loop))
(connect-loopback! client port
  (lambda (err)
    (unless err
      (uv-read-start! client
                      (lambda (bv s e) (collect-span! got bv s e))
                      (lambda () (set! client-eof #t) (uv-close! client) (uv-close! server))
                      (lambda (err) (uv-close! client)))
      (uv-write! client request-bytes (lambda (err) #f)))))

(define before (sstats-bytes (statistics)))
(define res (guard (e (#t (printf "uv-run raised: ~a ~s\n" (if (uv-callback-error? e) 'uv-callback-error e)
                                   (list (and (who-condition? e) (condition-who e)) (and (message-condition? e) (condition-message e))
                                         (and (irritants-condition? e) (condition-irritants e)))) 'raised))
              (uv-run loop 'default)))
(define after (sstats-bytes (statistics)))
(uv-loop-teardown! loop)

(define (count-occurrences bv pat)
  (let ((n (bytevector-length bv)) (m (bytevector-length pat)))
    (let loop ((i 0) (k 0))
      (if (> (+ i m) n) k
          (loop (+ i 1) (if (let cmp ((j 0)) (or (= j m) (and (= (bytevector-u8-ref bv (+ i j)) (bytevector-u8-ref pat j)) (cmp (+ j 1))))) (+ k 1) k))))))
(let ((bv (collector-bytes got)))
  (printf "uv-run result=~a client-eof=~a responses(200)=~a responses(500)=~a dns-answers=~a closed-conns=~a\n"
          res client-eof (count-occurrences bv (string->utf8 "HTTP/1.1 200")) (count-occurrences bv (string->utf8 "HTTP/1.1 500"))
          dns-answers server-closed-conns)
  (printf "server conn: served=~a read-stops=~a queue-left=~a pending=~a out-bytes=~a\n"
          (conn-served (car conns)) (conn-stops (car conns)) (length (conn-queue (car conns))) (and (conn-pending (car conns)) #t) (conn-out-bytes (car conns)))
  (printf "bytes allocated during uv-run (server+client, N=~a): ~a total, ~a per request\n" N (- after before) (div (- after before) N)))
