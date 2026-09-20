#!r6rs
;;; The SOCKET-FREE shell: drives (sansio core) + (sansio adapter) with an
;;; in-memory "loop" -- a queue of thunks standing in for libuv callbacks.
;;; No libuv is imported anywhere in this program.
(import (rnrs) (sansio core) (sansio adapter)
        (byte-machine runtime)
        (only (chezscheme) statistics sstats-bytes collect format printf))

(define (bv-concat cs)
  (let* ((n (apply + (map bytevector-length cs))) (out (make-bytevector n)))
    (let loop ((cs cs) (at 0))
      (unless (null? cs)
        (bytevector-copy! (car cs) 0 out at (bytevector-length (car cs)))
        (loop (cdr cs) (+ at (bytevector-length (car cs))))))
    out))

(define (s->bv s) (string->utf8 s))

;; run-sansio : Bytevector Nat Symbol Limits -> (values Bytevector Trace Symbol ResponseOrder)
;; mode: 'sync (handler responds inside call-handler) or 'lifo (handler
;; responses are delivered later, newest first, to prove ordering is the
;; core's job and not the handler's).
(define (run-sansio input chunk mode limits)
  (let ((c (make-conn limits))
        (out '()) (trace '()) (pending '()) (deferred '()) (closed #f)
        (reading #t) (pos 0) (resp-order '()) (eof-sent #f))
    (define (later! thunk) (set! pending (append pending (list thunk))))
    (define (note! a) (set! trace (cons a trace)))
    (conn-set-executor! c
      (lambda (a)
        (case (car a)
          ((feed-parser) (note! '(feed-parser)) (conn-run-parser-feed! c (cadr a) (caddr a) (cadddr a)))
          ((resume-parser) (note! a) (parser-resume! (conn-parser c)))
          ((write) (note! (list 'write (bytevector-length (cadr a))))
                   (set! out (cons (cadr a) out))
                   (later! (lambda () (conn-dispatch! c (list 'write-completed (bytevector-length (cadr a)) #f)))))
          ((write-status) (note! a) (set! out (cons (s->bv (format "HTTP/1.1 ~a\r\n\r\n" (cadr a))) out)))
          ((call-handler)
           (let* ((req (cadr a))
                  (respond (lambda (status headers body)
                             (set! resp-order (cons (request-id req) resp-order))
                             (conn-dispatch! c (list 'handler-responded (request-id req) (list status headers body))))))
             (note! (list 'call-handler (request-id req) (request-url req)))
             (case mode
               ((sync) (respond 200 '() (s->bv (string-append "echo " (request-url req) "\n"))))
               ((lifo) (set! deferred (cons (lambda () (respond 200 '() (s->bv (string-append "echo " (request-url req) "\n")))) deferred)))
               ((raise) (guard (e (#t (conn-dispatch! c (list 'handler-failed (request-id req) e))))
                          (error 'handler "boom"))))))
          ((read-stop) (note! a) (set! reading #f))
          ((read-start) (note! a) (set! reading #t))
          ((close) (note! a) (set! closed (cadr a)))
          ((start-timer stop-timer) #f)
          (else (note! a)))))
    ;; the fake loop
    (let loop ((i 0))
      (cond
       (closed #f)
       ((> i 10000) (set! closed 'stuck))
       ((pair? pending) (let ((t (car pending))) (set! pending (cdr pending)) (t) (loop (+ i 1))))
       ((and reading (< pos (bytevector-length input)))
        (let* ((end (min (bytevector-length input) (+ pos chunk)))
               (bv (make-bytevector (- end pos))))     ; a FRESH bytevector per delivery, as ADR-0009 promises
          (bytevector-copy! input pos bv 0 (- end pos))
          (set! pos end)
          (conn-dispatch! c (list 'bytes-arrived bv 0 (bytevector-length bv)))
          (loop (+ i 1))))
       ((pair? deferred) (let ((t (car deferred))) (set! deferred (cdr deferred)) (t) (loop (+ i 1))))
       ((and reading (not eof-sent)) (set! eof-sent #t) (conn-dispatch! c '(eof)) (loop (+ i 1)))
       (else (set! closed 'idle-with-read-stopped))))
    (values (bv-concat (reverse out)) (reverse trace) closed (reverse resp-order))))

(define pipelined
  (s->bv (string-append
          "POST /aaa HTTP/1.1\r\nContent-Length: 3\r\n\r\nAAA"
          "PUT /bbb HTTP/1.1\r\nContent-Length: 4\r\n\r\nBBBB"
          "PATCH /ccc HTTP/1.1\r\nContent-Length: 5\r\n\r\nCCCCC")))

(define wide (make-limits 8 1000000 0))
(define narrow (make-limits 2 1000000 0))

(define failures 0)
(define (check name ok? detail)
  (unless ok? (set! failures (+ failures 1)))
  (printf "~a ~a~a\n" (if ok? "ok  " "FAIL") name (if ok? "" (format " -- ~s" detail))))

;; --- 1. pipelining, every chunk size, sync handler ------------------------
(let-values (((out0 trace0 closed0 order0) (run-sansio pipelined (bytevector-length pipelined) 'sync wide)))
  (printf "whole-buffer output:\n~a\n" (utf8->string out0))
  (printf "whole-buffer trace: ~s\nclosed: ~s\n" trace0 closed0)
  (let loop ((n 1) (bad '()))
    (if (> n (bytevector-length pipelined))
        (check (format "pipelined: identical output at every chunk size 1..~a (sync)" (bytevector-length pipelined)) (null? bad) bad)
        (let-values (((out trace closed order) (run-sansio pipelined n 'sync wide)))
          (loop (+ n 1) (if (and (bytevector=? out out0) (equal? (filter (lambda (a) (memq (car a) '(call-handler close))) trace)
                                                                    (filter (lambda (a) (memq (car a) '(call-handler close))) trace0)))
                            bad (cons n bad))))))
  ;; --- 2. LIFO handler responses: output identical, delivery order reversed --
  (let-values (((out trace closed order) (run-sansio pipelined (bytevector-length pipelined) 'lifo wide)))
    (printf "lifo response order (handler side): ~s\n" order)
    (check "pipelined: handlers responded newest-first, wire order still 1,2,3" (and (bytevector=? out out0) (equal? order '(3 2 1))) (list order (utf8->string out))))
  ;; --- 3. cap of 2 outstanding: pause + read-stop, then resume + feed + read-start
  (let-values (((out trace closed order) (run-sansio pipelined (bytevector-length pipelined) 'lifo narrow)))
    (printf "cap=2 trace: ~s\n" trace)
    (check "cap=2: output identical" (bytevector=? out out0) (utf8->string out))
    (check "cap=2: parser paused and read stopped, then resumed, remainder fed, read restarted"
           (and (member '(read-stop) trace) (member '(resume-parser) trace) (member '(read-start) trace)
                (>= (length (filter (lambda (a) (eq? (car a) 'feed-parser)) trace)) 2))
           trace)
    (let loop ((n 1) (bad '()))
      (if (> n (bytevector-length pipelined))
          (check "cap=2: identical output at every chunk size (lifo)" (null? bad) bad)
          (let-values (((out trace closed order) (run-sansio pipelined n 'lifo narrow)))
            (loop (+ n 1) (if (bytevector=? out out0) bad (cons n bad))))))))

;; --- 4. Connection: close followed by more data (MEASURED) -----------------
(let* ((input (s->bv "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\n\r\n")))
  (let-values (((out trace closed order) (run-sansio input (bytevector-length input) 'sync wide)))
    (printf "close then data, whole buffer: trace=~s closed=~s\noutput:\n~a\n" trace closed (utf8->string out))
    (check "Connection: close -- exactly one handler call, one response, then close"
           (and (= 1 (length (filter (lambda (a) (eq? (car a) 'call-handler)) trace))) (eq? closed 'done))
           (list trace closed)))
  ;; and byte-at-a-time: the second request's bytes arrive AFTER close-after is set and are never fed
  (let-values (((out trace closed order) (run-sansio input 1 'sync wide)))
    (check "Connection: close at chunk=1 -- second request never fed to the parser"
           (and (= 1 (length (filter (lambda (a) (eq? (car a) 'call-handler)) trace))) (eq? closed 'done))
           (list trace closed))))

;; What the PARSER says about data after close, in isolation (no core):
(let* ((input (s->bv "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\n\r\n"))
       (c (make-conn wide)))
  (conn-set-executor! c (lambda (a) #f))
  (let ((r (parser-feed! (conn-parser c) input 0 (bytevector-length input))))
    (printf "raw parser on close-then-data: status=~s consumed=~s next=~s error=~s\n"
            (parser-result-status r) (parser-result-consumed r) (parser-result-next r)
            (let ((e (parser-result-error r))) (and e (list (parser-error-code e) (parser-error-reason e) (parser-error-offset e)))))))

;; --- 5. HTTP/1.0 without keep-alive closes -----------------------------------
(let* ((input (s->bv "GET / HTTP/1.0\r\n\r\n")))
  (let-values (((out trace closed order) (run-sansio input (bytevector-length input) 'sync wide)))
    (check "HTTP/1.0 no keep-alive: response then close" (eq? closed 'done) (list trace closed))))

;; --- 6. handler exception -> 500, connection survives -----------------------
(let* ((input (s->bv "GET /x HTTP/1.1\r\nHost: x\r\n\r\n")))
  (let-values (((out trace closed order) (run-sansio input (bytevector-length input) 'raise wide)))
    (printf "handler raise: ~a" (utf8->string out))
    (check "handler raise: 500 written, connection stays open until the fake client's EOF" (and (eq? closed 'eof) (member '(write 53) trace) #t) (list trace closed))))

;; --- 7. parser error -> 400 + close ---------------------------------------------
(let* ((input (s->bv "GET / HTTP/1.1\r\nBad Header: x\r\n\r\n")))
  (let-values (((out trace closed order) (run-sansio input 3 'sync wide)))
    (printf "parser error: trace=~s closed=~s\n" trace closed)
    (check "parser error: 400 and close" (and (eq? closed 'parser-error) (member '(write-status 400) trace) #t) (list trace closed))))

;; --- 8. eof with a request in flight: respond, then close ----------------------
(let* ((input (s->bv "GET /a HTTP/1.1\r\nHost: x\r\n\r\n")))
  (let-values (((out trace closed order) (run-sansio input (bytevector-length input) 'lifo wide)))
    (check "eof while handler pending: response still written, then close" (and (eq? closed 'eof) (member '(write 46) trace) #t) (list trace closed))))

;; --- 9. allocation per request, one request per delivery (keep-alive client shape)
(let* ((one (s->bv "GET /hello HTTP/1.1\r\nHost: example.com\r\nUser-Agent: x\r\nAccept: */*\r\n\r\n"))
       (n 2000)
       (input (bv-concat (let l ((i 0) (acc '())) (if (= i n) acc (l (+ i 1) (cons one acc)))))))
  (collect)
  (let ((b0 (sstats-bytes (statistics))))
    (let-values (((out trace closed order) (run-sansio input (bytevector-length one) 'sync (make-limits 8 100000000 0))))
      (let ((b1 (sstats-bytes (statistics))))
        (printf "allocation (core+adapter+parser+fake shell, sync handler, 1 request/delivery): ~a requests, ~a bytes total, ~a bytes/request\n"
                n (- b1 b0) (div (- b1 b0) n))
        (check "2000 keep-alive GETs answered" (= (length (filter (lambda (a) (eq? (car a) 'call-handler)) trace)) n) (length trace))))))

;; --- 10. allocation of the PURE CORE alone: replay one request's event script
(let* ((hv (lambda (s) (let ((b (s->bv s))) (list b 0 (bytevector-length b)))))
       (script (list '(parser-event on-message-begin)
                     (cons 'parser-event (cons 'on-url-data (hv "/hello")))
                     (cons 'parser-event (cons 'on-header-field-data (hv "Host")))
                     (cons 'parser-event (cons 'on-header-value-data (hv "example.com")))
                     '(parser-event on-header-value-complete)
                     (cons 'parser-event (cons 'on-header-field-data (hv "User-Agent")))
                     (cons 'parser-event (cons 'on-header-value-data (hv "x")))
                     '(parser-event on-header-value-complete)
                     (cons 'parser-event (cons 'on-header-field-data (hv "Accept")))
                     (cons 'parser-event (cons 'on-header-value-data (hv "*/*")))
                     '(parser-event on-header-value-complete)
                     '(parser-event on-headers-complete 1 1 1 0 0)
                     '(parser-event on-message-complete)
                     '(parser-result need-input 74 74 74 #f)))
       (resp (list 200 '() (s->bv "hello\n")))
       (n 20000))
  (collect)
  (let ((b0 (sstats-bytes (statistics))))
    (let loop ((i 0) (s (make-conn-state (make-limits 8 100000000 0))))
      (when (< i n)
        (let ((s (fold-left (lambda (s ev) (let-values (((s* acts) (conn-step s ev))) s*)) s script)))
          (let*-values (((s acts) (conn-step s (list 'handler-responded (+ i 1) resp)))
                        ((s acts) (conn-step s (list 'write-completed 49 #f))))
            (loop (+ i 1) s)))))
    (printf "allocation (pure core only, 14 parser events + response + write-completed per request): ~a bytes/request\n"
            (div (- (sstats-bytes (statistics)) b0) n))))

(printf "failures: ~a\n" failures)
(exit (if (zero? failures) 0 1))
