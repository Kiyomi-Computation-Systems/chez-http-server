#!r6rs
;;; The LIBUV shell: the SAME (sansio core) + (sansio adapter) as
;;; sansio-shell.sps, driven by a real loop over loopback. One in-process
;;; client pipelines four requests. Handlers answer asynchronously and OUT OF
;;; ORDER (timer-delayed), one of them via uv-getaddrinfo!; the core still
;;; writes responses in request order.
(import (rnrs) (libuv) (sansio core) (sansio adapter) (byte-machine runtime)
        (only (chezscheme) printf format))

(define loop (make-uv-loop))
(define connections (make-eqv-hashtable))   ; peer id -> conn cell; the server owns every close
(define next-peer 0)
(define events '())                          ; observability log
(define (note! . x) (set! events (cons x events)))

(define (bv-concat cs)
  (let* ((n (apply + (map bytevector-length cs))) (out (make-bytevector n)))
    (let loop ((cs cs) (at 0))
      (unless (null? cs)
        (bytevector-copy! (car cs) 0 out at (bytevector-length (car cs)))
        (loop (cdr cs) (+ at (bytevector-length (car cs))))))
    out))

;; The application handler: (request respond) -> unspecified. `respond` may be
;; called now or later; either way it becomes a handler-responded EVENT.
(define (handler req respond)
  (let ((url (request-url req)))
    (cond
     ((string=? url "/dns")
      ;; awaiting an external async result: the DNS completion callback is just
      ;; another libuv callback that re-enters the machine through `respond`.
      (uv-getaddrinfo! loop "localhost" #f '((socktype . stream))
                       (lambda (err results)
                         (respond 200 '()
                                  (string->utf8
                                   (if err (format "dns error ~a\n" (uv-errno-error-errno err))
                                       (format "dns ~a\n" (map uv-addrinfo-address results))))))))
     (else
      ;; delay by id so that request 1 answers LAST: 30ms, 20ms, 10ms
      (let ((t (make-uv-timer loop)))
        (uv-timer-start! t (lambda (timer)
                             (uv-close! timer)
                             (respond 200 '() (string->utf8 (string-append "echo " url "\n"))))
                         (* 10 (- 4 (request-id req))) 0))))))

(define (serve! tcp)
  (let ((c (make-conn (make-limits 8 65536 16384)))
        (id next-peer)
        (closing #f))
    (define (on-data bv start end) (conn-dispatch! c (list 'bytes-arrived bv start end)))
    (define (on-eof) (conn-dispatch! c '(eof)))
    (define (on-error err) (conn-dispatch! c (list 'read-error (uv-errno-error-errno err))))
    (set! next-peer (+ next-peer 1))
    (hashtable-set! connections id c)
    (conn-set-executor! c
      (lambda (a)
        (note! 'action (if (memq (car a) '(feed-parser write)) (list (car a)) a))
        (case (car a)
          ((feed-parser) (conn-run-parser-feed! c (cadr a) (caddr a) (cadddr a)))
          ((resume-parser) (parser-resume! (conn-parser c)))
          ((write)
           (let ((n (bytevector-length (cadr a))))
             (uv-write! tcp (cadr a) (lambda (err) (conn-dispatch! c (list 'write-completed n err))))))
          ((write-status)
           (uv-write! tcp (string->utf8 (format "HTTP/1.1 ~a X\r\nContent-Length: 0\r\n\r\n" (cadr a))) (lambda (err) #f)))
          ((call-handler)
           (let ((req (cadr a)))
             ;; a handler exception becomes an event; nothing raises across the trampoline
             (guard (e (#t (conn-dispatch! c (list 'handler-failed (request-id req) e))))
               (handler req (lambda (status headers body)
                              (note! 'handler-responded (request-id req))
                              (conn-dispatch! c (list 'handler-responded (request-id req) (list status headers body))))))))
          ((read-stop) (when (uv-handle-open? tcp) (uv-read-stop! tcp)))
          ((read-start) (when (uv-handle-open? tcp) (uv-read-start! tcp on-data on-eof on-error)))
          ((close)
           ;; close ownership: exactly one initiation per handle, from here only
           (unless closing
             (set! closing #t)
             (uv-shutdown! tcp (lambda (err)
                                 (uv-close! tcp (lambda ()
                                                  (hashtable-delete! connections id)
                                                  (note! 'peer-closed id (cadr a))))))))
          ((start-timer stop-timer) #f)
          (else #f))))
    (uv-read-start! tcp on-data on-eof on-error)))

(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(uv-listen! server 128 (lambda (err) (unless err (serve! (uv-accept! server)))))

;; --- the client, same loop --------------------------------------------------
(define pipelined
  (string->utf8 (string-append
                 "POST /aaa HTTP/1.1\r\nContent-Length: 3\r\n\r\nAAA"
                 "PUT /bbb HTTP/1.1\r\nContent-Length: 4\r\n\r\nBBBB"
                 "PATCH /ccc HTTP/1.1\r\nContent-Length: 5\r\n\r\nCCCCC"
                 "GET /dns HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")))
(define client (make-uv-tcp loop))
(define received '())
(define client-eof #f)
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (unless err
      (uv-read-start! client
                      (lambda (bv start end)
                        (let ((b (make-bytevector (- end start))))
                          (bytevector-copy! bv start b 0 (- end start))
                          (set! received (cons b received))))
                      (lambda () (set! client-eof #t) (uv-close! client) (uv-close! server))
                      (lambda (err) (uv-close! client)))
      ;; two uneven writes so the request boundaries do not align with deliveries
      (uv-write! client pipelined 0 50 (lambda (err) #f))
      (uv-write! client pipelined 50 (bytevector-length pipelined) (lambda (err) #f)))))

(uv-run loop 'default)
(uv-loop-teardown! loop)

(define text (utf8->string (bv-concat (reverse received))))
(printf "client received (~a bytes):\n~a\n" (string-length text) text)
(printf "server actions, in order:\n")
(for-each (lambda (e) (printf "  ~s\n" e)) (reverse events))

(define (index-of hay needle)
  (let loop ((i 0))
    (cond ((> (+ i (string-length needle)) (string-length hay)) #f)
          ((string=? (substring hay i (+ i (string-length needle))) needle) i)
          (else (loop (+ i 1))))))
(define ok
  (and client-eof
       (index-of text "echo /aaa") (index-of text "echo /bbb") (index-of text "echo /ccc") (index-of text "dns ")
       (< (index-of text "echo /aaa") (index-of text "echo /bbb") (index-of text "echo /ccc") (index-of text "dns "))
       (index-of text "Connection: close")
       (= 0 (hashtable-size connections))))
(printf "~a: responses in request order despite out-of-order handlers; connection closed after Connection: close; connection table empty\n"
        (if ok "ok  " "FAIL"))
(exit (if ok 0 1))
