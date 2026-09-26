#!r6rs
;;; (http-server private shell): the direct libuv shell, over loopback.  M4.2.
;;;
;;; The shell performs the core's actions with chez-libuv (design §5.2).  This
;;; suite serves clients on the same loop, bound to 127.0.0.1:0, each wait
;;; capped by an iteration count, never wall-clock (design §8.5), and asserts
;;; on bytes, states and the order of verbs, never on how the kernel split the
;;; stream.  A response is read back by chez-httparse's strict response parser
;;; (tests/response-reader.sls), not by our own code.
;;;
;;; The checks:
;;;   - a GET is answered, its Date from the shell's clock, and the connection
;;;     stays open;
;;;   - three requests in one write are answered in order, reading the clock
;;;     fewer times than they are answered (decision 0010: once a second), and
;;;     no action but the parser's reply runs at parser depth (design §6.4,
;;;     the second hazard), against the real shell as M2.4 checked the fake;
;;;   - a response that closes the connection is followed by the half-close:
;;;     the client reads the response, then the stream's end, while the
;;;     connection lingers, reading, until the client closes (decision 0011,
;;;     the shell's half of M3.5);
;;;   - a handler that raises is answered 500, and what it raised is logged;
;;;   - a write outstanding keeps nothing of its response: chez-libuv copied
;;;     the segments at the call, and the completion keeps their byte count
;;;     alone (design §7.3; M3.3's check, against the real write executor);
;;;   - a write that fails, at its completion or when it is issued, closes the
;;;     connection as a read error, and is settled after (design §6.3);
;;;   - the run loop raises again a byte-machine contract condition that a
;;;     callback raised, even when the log raises, and runs on after any other
;;;     (design §6.4, the first hazard; decision 0003 item 4);
;;;   - a connection whose callback raises is closed, and so is one whose
;;;     adoption fails;
;;;   - the run loop drops a connection whose handle closed behind the shell;
;;;   - and at the end every connection was accepted and has closed, and no
;;;     handle is left on the loop.
;;;
;;; Oracles: RFC 9110 §5.6.7's example instant, Sun, 06 Nov 1994 08:49:37
;;; GMT, as the shell's clock; chez-httparse's response parser; chez-libuv's
;;; live-handle list and its dev-build counters; byte-machine's own contract
;;; condition, provoked by a feed from inside a callback; and the weak-pair
;;; instrument, calibrated below.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?)
        (libuv) (uv-testing)
        (rename (only (libuv private native) live-counts) (live-counts debug-live-counts))
        (only (byte-machine private conditions)
              byte-machine-contract-condition? byte-machine-contract-condition-code)
        (byte-machine runtime)
        (only (generated httparse-message) httparse-message-machine)
        (only (httparse modes) httparse-message-type-value)
        (http-server private shell)
        (only (http-server connection) conn-phase conn-parser-callbacks conn-span-callbacks)
        (http-server request) (http-server response) (http-server span) (http-server limits)
        (response-reader))

(define (b s) (string->utf8 s))

;; RFC 9110 §5.6.7's example, as seconds since the epoch (`date -u -r`).
(define instant 784111777)
(define instant-date "Sun, 06 Nov 1994 08:49:37 GMT")

(define cap 4096)

;; err->symbol : (U #f Condition) -> Symbol — a callback's error, as a symbol
;; no failure path confuses with success.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else 'unexpected-error-object)))

;; --- what the shell reports, and the faults the suite hands it ------------------

;; What the shells logged, newest first, as (what . details).  While
;; `log-fails` names what is logged, the log raises instead.
(define logged '())
(define log-fails #f)
(define (log! what details)
  (when (eq? what log-fails) (raise (make-message-condition "the log failed")))
  (set! logged (cons (cons what details) logged)))

;; first-logged : -> Symbol — what the oldest entry since `logged` was
;; cleared says happened.
(define (first-logged)
  (if (pair? logged) (car (list-ref logged (- (length logged) 1))) 'nothing-logged))

;; The verbs the shells ran and the events they dispatched, newest first, as
;; (connection kind verb): only the verb, so the trace keeps nothing of an
;; action's bytes.  While `trap` is set, the next `call-handler` a connection
;; runs raises first, as a bug in the shell would.
(define traced '())
(define trap #f)
(define (trace! c kind datum)
  (set! traced (cons (list c kind (car datum)) traced))
  (when (and trap (eq? kind 'action) (eq? (car datum) 'call-handler))
    (set! trap #f)
    (raise (make-message-condition "a bug in the shell"))))

;; verbs / events : Connection -> (Listof Symbol) — its actions, or its
;; events, in order.
(define (traced-of c kind)
  (reverse (map caddr (filter (lambda (t) (and (eq? (car t) c) (eq? (cadr t) kind))) traced))))
(define (verbs c) (traced-of c 'action))
(define (events c) (traced-of c 'event))

;; in-order? : (Listof Symbol) (Listof Symbol) -> Boolean — `wanted` appears
;; in `seen` in its order, other verbs between.
(define (in-order? wanted seen)
  (cond ((null? wanted) #t)
        ((null? seen) #f)
        ((eq? (car wanted) (car seen)) (in-order? (cdr wanted) (cdr seen)))
        (else (in-order? wanted (cdr seen)))))

;; The shell's clock: RFC 9110's instant, in milliseconds, counting its
;; readings.
(define clock-reads 0)
(define (clock) (set! clock-reads (+ clock-reads 1)) (* 1000 instant))

;; The handler answers 200 with the request's target as the body, except:
;; `/raise` raises; and `/big`, four MiB, held weakly here so the retention
;; check can ask whether anything else still holds it, and closing the
;; connection after it, so the client knows it has the whole response when it
;; reads the stream's end.
(define big-size (* 4 1024 1024))
(define big-body #f)
(define (handler req)
  (let ((target (span->bytevector (request-target req))))
    (cond ((bytevector=? target (b "/big"))
           (let ((body (make-bytevector big-size 120)))
             (set! big-body (weak-cons body '()))
             (make-response 200 #f (list (cons (b "Connection") (b "close"))) body)))
          ((bytevector=? target (b "/raise"))
           (raise (make-message-condition "the handler failed")))
          (else (make-response 200 #f '() target)))))

;; limits-with-read-buffer : Nat -> Limits — the defaults, but the buffer.
(define (limits-with-read-buffer n)
  (let ((d default-limits))
    (make-limits (limits-read-header-timeout-ms d) (limits-idle-timeout-ms d)
                 (limits-body-inactivity-timeout-ms d) (limits-linger-timeout-ms d)
                 (limits-max-header-bytes d) (limits-max-header-count d)
                 (limits-max-header-field-bytes d) (limits-max-header-value-bytes d)
                 (limits-max-target-bytes d) (limits-max-body-bytes d)
                 (limits-pipeline-cap d) n (limits-require-host? d))))

;; --- the loop, the shell, and a listener of the suite's own ---------------------

(define loop #f)
(define shell #f)
(define listener #f)
(define port #f)
(define adopting #f)                   ; the shell the listener adopts into
(define adopted '())                   ; newest first
(define listen-error 'no-listen-error)
(define small-send-buffer #f)

;; open-server! : -> Void
;; The loop, the shell, and a listener on 127.0.0.1:0 that adopts each
;; connection it accepts into `adopting`; with `small-send-buffer`, the
;; connection's send buffer is asked to be that small first.  Made inside the
;; suite, so a failure here is the harness's status, not a crash.
(define (open-server!)
  (set! loop (make-uv-loop))
  (set! shell (make-shell loop handler default-limits clock log! trace!))
  (set! adopting shell)
  (set! listener (make-uv-tcp loop))
  (set! port (bind-loopback! listener))
  (uv-listen! listener 16
              (lambda (err)
                (if err
                    (set! listen-error (err->symbol err))
                    (let ((tcp (uv-accept! listener)))
                      (when small-send-buffer (uv-send-buffer-size! tcp small-send-buffer))
                      (set! adopted (cons (shell-adopt! adopting tcp) adopted)))))))

;; --- clients -------------------------------------------------------------------

(define-record-type client
  (fields tcp collector (mutable connected) (mutable end) (mutable reading?))
  (protocol (lambda (new) (lambda (tcp) (new tcp (make-byte-collector) 'never 'open #f)))))

(define clients '())

;; client-read! : Client -> Void — start reading, collecting what arrives.
(define (client-read! cl)
  (client-reading?-set! cl #t)
  (uv-read-start! (client-tcp cl)
                  (lambda (bv start end) (collect-span! (client-collector cl) bv start end))
                  (lambda () (client-end-set! cl 'eof))
                  (lambda (e) (client-end-set! cl (err->symbol e)))))

;; open-client! : (U #f Bytevector) [Boolean] -> Client
;; A client on the loop that connects, writes `request` whole unless it is #f,
;; and reads unless told to wait.
(define open-client!
  (case-lambda
    ((request) (open-client! request #t))
    ((request read?)
     (let* ((tcp (make-uv-tcp loop)) (cl (make-client tcp)))
       (set! clients (cons cl clients))
       (connect-loopback! tcp port
                          (lambda (err)
                            (client-connected-set! cl (err->symbol err))
                            (unless err
                              (when read? (client-read! cl))
                              (when request (client-send! cl request)))))
       cl))))

(define (client-send! cl bytes) (uv-write! (client-tcp cl) bytes (lambda (err) #f)))

(define (client-bytes cl) (collector-bytes (client-collector cl)))

(define (client-close! cl)
  (when (uv-handle-open? (client-tcp cl)) (uv-close! (client-tcp cl))))

;; bytes-between : Bytevector Nat Nat -> Bytevector
(define (bytes-between bv from to)
  (let ((out (make-bytevector (- to from))))
    (bytevector-copy! bv from out 0 (- to from))
    out))

;; responses : Bytevector -> (Listof Response-Read)
;; The whole responses at the front of `bv`, in order, each read by
;; chez-httparse's response parser: the shortest prefix it reads as one
;; complete message is the first, and what follows is read the same way.
(define (responses bv)
  (let next ((from 0) (acc '()))
    (let grow ((to (+ from 1)))
      (if (> to (bytevector-length bv))
          (reverse acc)
          (let ((r (read-response (bytes-between bv from to) #f #f)))
            (if (eq? (list-ref r 4) 'complete)
                (next to (cons r acc))
                (grow (+ to 1))))))))

;; head-length : Bytevector -> Nat — the bytes up to and including the blank
;; line that ends a response's head, or all of them if there is none.
(define (head-length bv)
  (let scan ((i 0))
    (cond ((> (+ i 4) (bytevector-length bv)) (bytevector-length bv))
          ((and (= 13 (bytevector-u8-ref bv i)) (= 10 (bytevector-u8-ref bv (+ i 1)))
                (= 13 (bytevector-u8-ref bv (+ i 2))) (= 10 (bytevector-u8-ref bv (+ i 3))))
           (+ i 4))
          (else (scan (+ i 1))))))

(define (status r) (car r))
(define (body r) (cadddr r))
(define (field r name)
  (let ((f (assoc name (caddr r))))
    (if f (cdr f) 'absent)))

;; wait-for : (-> Boolean) -> Symbol — 'satisfied, or 'iterations-exhausted.
(define (wait-for pred) (run-until/ticking loop pred cap))

;; the newest connection the listener adopted, or 'none.
(define (newest) (if (pair? adopted) (car adopted) 'none))

;; a connection adopted since `before`, or #f.
(define (adopted-since before)
  (let ((c (newest))) (and (connection? c) (not (eq? c before)) c)))

(define (phase c) (conn-phase (connection-state c)))

;; closed-and-gone? : Shell Connection -> Boolean
(define (closed-and-gone? sh c)
  (and (connection? c) (eq? (uv-handle-state (connection-tcp c)) 'closed)
       (not (memq c (shell-connections sh)))))

;; run-shell-until : Shell (-> Boolean) -> Symbol
;; Step `sh`'s run loop, which logs a callback's error and runs on, a 1 ms
;; ticker keeping the loop awake, until `pred` holds: 'satisfied or
;; 'iterations-exhausted.  The ticker is closed after, and its close drained.
(define (run-shell-until sh pred)
  (let ((ticker (make-uv-timer loop)))
    (uv-timer-start! ticker (lambda (t) #f) 1 1)
    (let ((outcome (let step ((i 0))
                     (cond ((pred) 'satisfied)
                           ((= i cap) 'iterations-exhausted)
                           (else (shell-run! sh 'once) (step (+ i 1)))))))
      (uv-timer-stop! ticker)
      (uv-close! ticker)
      (run-until loop (lambda () (eq? (uv-handle-state ticker) 'closed)) 8)
      outcome)))

;; --- the byte-machine contract condition, provoked ------------------------------

;; provoke-reentrancy : -> (U Condition Symbol)
;; A parser whose on-message-begin feeds the parser again: byte-machine
;; refuses the nested feed, and the condition comes out of the outer one.
(define (provoke-reentrancy)
  (let* ((request (b "GET / HTTP/1.1\r\n\r\n"))
         (bindings (map (lambda (name)
                          (list name
                                (cond ((eq? name 'on-message-begin)
                                       (lambda (p ctx) (parser-feed! p request 0 1) callback-continue))
                                      ((memq name conn-span-callbacks)
                                       (lambda (p ctx bv from to) callback-continue))
                                      (else (lambda (p ctx) callback-continue)))))
                        conn-parser-callbacks))
         (p (make-parser httparse-message-machine bindings #f
                         (list (cons 'type (httparse-message-type-value 'request))))))
    (guard (e ((byte-machine-contract-condition? e) e))
      (parser-feed! p request 0 (bytevector-length request))
      'no-raise)))

;; raise-in-callback : Any -> (U (List 'raised Any) Symbol)
;; A timer whose callback raises `obj`; the shell's run loop is stepped until
;; the timer has fired.  What the run loop did: `(raised e)` if it raised
;; `e`, or 'ran-on.  The timer is closed, and its close drained, either way.
(define (raise-in-callback obj)
  (let ((t (make-uv-timer loop)) (fired #f))
    (uv-timer-start! t (lambda (t) (set! fired #t) (raise obj)) 0 0)
    (let ((outcome (guard (e (#t (list 'raised e)))
                     (let step ((i 0))
                       (cond (fired 'ran-on)
                             ((= i cap) 'iterations-exhausted)
                             (else (shell-run! shell 'once) (step (+ i 1))))))))
      (uv-close! t)
      (run-until loop (lambda () (eq? (uv-handle-state t) 'closed)) 8)
      outcome)))

;; contract-code : (U (List 'raised Any) Symbol) -> Any — the code of the
;; contract condition raised, or the outcome itself.
(define (contract-code outcome)
  (if (and (pair? outcome) (byte-machine-contract-condition? (cadr outcome)))
      (byte-machine-contract-condition-code (cadr outcome))
      outcome))

;; --- the weak-pair instrument ----------------------------------------------------

;; state-after-collection : WeakPair -> Symbol — collect every generation, then
;; 'released if nothing holds the pair's object, else 'held.
(define (state-after-collection w)
  (collect (collect-maximum-generation))
  (if (bwp-object? (car w)) 'released 'held))

(define calibration-held (make-bytevector 64 0))

(define (live-count kind) (cdr (assq kind (debug-live-counts))))

(run-suite "shell"
  (lambda ()
    (open-server!)

    ;; A GET, answered.
    (let ((cl (open-client! (b "GET /one HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads one whole response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (let ((r (car (append (responses (client-bytes cl)) (list '(none "" () "" none))))))
        (test-equal "a GET is answered 200, the target its body" '(200 "/one") (list (status r) (body r)))
        (test-equal "its Date is the shell's clock's second" instant-date (field r "Date")))
      (test-equal "and the connection stays open, idle, in the table" '(idle #t)
                  (let ((c (newest)))
                    (if (connection? c)
                        (list (phase c) (and (memq c (shell-connections shell)) #t))
                        '(no-connection #f))))
      (client-close! cl))

    ;; Three requests in one write, the depth counter, and the clock.
    (set! clock-reads 0)
    (let ((cl (open-client! (b (string-append "GET /1 HTTP/1.1\r\nHost: x\r\n\r\n"
                                              "GET /2 HTTP/1.1\r\nHost: x\r\n\r\n"
                                              "GET /3 HTTP/1.1\r\nHost: x\r\n\r\n")))))
      (test-eq "a client reads three whole responses" 'satisfied
               (wait-for (lambda () (= 3 (length (responses (client-bytes cl)))))))
      (test-equal "three requests in one write are answered in order" '("/1" "/2" "/3")
                  (map body (responses (client-bytes cl))))
      (test-eq "three responses read the clock fewer than three times" 'fewer
               (if (< clock-reads 3) 'fewer (list 'read clock-reads)))
      (test-equal "no action ran but from the outermost drain" '()
                  (let ((c (newest))) (if (connection? c) (connection-violations c) '(no-connection))))
      (client-close! cl))

    ;; The half-close, and the linger.
    (let ((cl (open-client! (b "GET /bye HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))))
      (test-eq "the client reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after the whole response" '((200 "/bye"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
      (let ((c (newest)))
        (test-equal "while the client holds its end open, the connection lingers, in the table"
                    '(lingering #t)
                    (if (connection? c)
                        (list (phase c) (and (memq c (shell-connections shell)) #t))
                        '(no-connection #f)))
        (client-close! cl)
        (test-eq "when the client closes, the connection closes and leaves the table" 'satisfied
                 (wait-for (lambda () (and (connection? c) (eq? (phase c) 'closed)
                                           (not (memq c (shell-connections shell)))))))
        (test-eq "its verbs ran in order: write, shutdown, read-start, close" 'in-order
                 (if (and (connection? c) (in-order? '(write shutdown read-start close) (verbs c)))
                     'in-order
                     (list 'out-of-order (and (connection? c) (verbs c)))))))

    ;; A handler that raises.
    (set! logged '())
    (let ((cl (open-client! (b "GET /raise HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a handler that raises reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after a 500" '(500) (map status (responses (client-bytes cl))))
      (test-equal "and the shell logged what the handler raised" '(handler-failed "the handler failed")
                  (let ((entry (assq 'handler-failed logged)))
                    (if (and entry (pair? (cdr entry)) (message-condition? (cadr entry)))
                        (list 'handler-failed (condition-message (cadr entry)))
                        (list 'not-logged logged))))
      (client-close! cl))

    ;; A write outstanding keeps nothing of its response.
    (test-equal "the instrument sees a held object held" 'held
                (state-after-collection (weak-cons calibration-held '())))
    (test-eqv "and the object it holds is still there" 64 (bytevector-length calibration-held))
    (set! small-send-buffer 4096)
    (let ((cl (open-client! (b "GET /big HTTP/1.1\r\nHost: x\r\n\r\n") #f)))
      (test-eq "a client that does not read yet asks for four MiB" 'satisfied
               (wait-for (lambda () (and big-body (connection? (newest))
                                         (memq 'write (verbs (newest))) #t))))
      (set! small-send-buffer #f)
      (let ((c (newest)))
        (test-eq "the write is still outstanding" 'outstanding
                 (if (and (connection? c) (> (uv-stream-write-queue-size (connection-tcp c)) 0))
                     'outstanding 'completed))
        (test-eq "and nothing holds the response's body" 'released
                 (if big-body (state-after-collection big-body) 'no-body))
        (client-read! cl)
        (test-eq "the client then reads the whole response, and the stream's end" 'satisfied
                 (wait-for (lambda () (eq? (client-end cl) 'eof))))
        (let* ((bytes (client-bytes cl))
               (head (head-length bytes))
               (r (read-response (bytes-between bytes 0 head) #t #f)))
          (test-equal "a 200 whose body is the four MiB" (list 200 (number->string big-size) big-size)
                      (list (status r) (field r "Content-Length") (- (bytevector-length bytes) head)))))
      (client-close! cl))

    ;; A write that fails at its completion: the client goes while four MiB
    ;; are still being written to it.
    (set! small-send-buffer 4096)
    (let* ((before (newest))
           (cl (open-client! (b "GET /big HTTP/1.1\r\nHost: x\r\n\r\n") #f)))
      (test-eq "a client that will not read asks for four MiB" 'satisfied
               (wait-for (lambda () (let ((c (adopted-since before))) (and c (memq 'write (verbs c)) #t)))))
      (set! small-send-buffer #f)
      (let ((c (adopted-since before)))
        (test-eq "its write is outstanding when the client closes" 'outstanding
                 (if (and c (> (uv-stream-write-queue-size (connection-tcp c)) 0)) 'outstanding 'completed))
        (client-close! cl)
        (test-eq "a write that fails at its completion closes the connection" 'satisfied
                 (wait-for (lambda () (closed-and-gone? shell c))))
        (test-eq "as a read error, then settled, with no half-close" 'read-error-then-settled
                 (if (and c (in-order? '(read-error write-completed) (events c))
                          (not (memq 'shutdown (verbs c))))
                     'read-error-then-settled
                     (list (and c (events c)) (and c (verbs c)))))))

    ;; A write refused when it is issued: the connection's write side is shut
    ;; behind the shell's back, and libuv then refuses a write at the call.
    (let* ((before (newest))
           (cl (open-client! #f)))
      (test-eq "a client connects and says nothing yet" 'satisfied
               (wait-for (lambda () (and (adopted-since before) #t))))
      (let ((c (adopted-since before)))
        (when c (uv-shutdown! (connection-tcp c) (lambda (err) #f)))
        (client-send! cl (b "GET /refused HTTP/1.1\r\nHost: x\r\n\r\n"))
        (test-eq "a write refused when it is issued closes the connection" 'satisfied
                 (guard (e ((uv-callback-error? e) 'a-callback-raised))
                   (wait-for (lambda () (closed-and-gone? shell c)))))
        (test-eq "as a read error, then settled" 'read-error-then-settled
                 (if (and c (in-order? '(read-error write-completed) (events c)))
                     'read-error-then-settled
                     (and c (events c))))
        (test-equal "and its client reads nothing before the stream's end" '(eof 0)
                    (begin (wait-for (lambda () (not (eq? (client-end cl) 'open))))
                           (list (client-end cl) (collector-count (client-collector cl))))))
      (client-close! cl))

    ;; The run loop, and what callbacks raise.
    (let ((reentrancy (provoke-reentrancy)))
      (test-eq "byte-machine refuses a feed from inside a callback" 'reentrancy
               (if (byte-machine-contract-condition? reentrancy)
                   (byte-machine-contract-condition-code reentrancy)
                   reentrancy))
      (set! logged '())
      (let ((outcome (raise-in-callback reentrancy)))
        (test-eq "the run loop raises a contract condition again" 'reentrancy (contract-code outcome))
        (test-eq "having logged the contract violation first" 'contract-violation (first-logged)))
      (set! log-fails 'contract-violation)
      (let ((outcome (raise-in-callback reentrancy)))
        (set! log-fails #f)
        (test-eq "and raises it again when the log raises" 'reentrancy (contract-code outcome))))
    (set! logged '())
    (let ((outcome (raise-in-callback (make-message-condition "a bug in a callback"))))
      (test-eq "after any other error in a callback, the run loop runs on" 'ran-on outcome)
      (test-eq "having logged the callback's error first" 'callback-error (first-logged)))

    ;; A bug in a connection's callback closes that connection.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /trap HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (set! trap #t)
      (test-eq "when a connection's callback raises, its client reads the stream's end" 'satisfied
               (run-shell-until shell (lambda () (eq? (client-end cl) 'eof))))
      (let ((c (adopted-since before)))
        (test-equal "with no response, the connection closed and gone, the error logged"
                    '(0 #t callback-error)
                    (list (collector-count (client-collector cl)) (closed-and-gone? shell c)
                          (first-logged))))
      (client-close! cl))

    ;; An adoption that fails closes the connection.
    (let ((bad (make-shell loop handler (limits-with-read-buffer 0) clock log! trace!)))
      (set! adopting bad)
      (set! logged '())
      (let ((cl (open-client! #f)))
        (test-eq "when a connection cannot be adopted, its client reads the stream's end" 'satisfied
                 (run-shell-until bad (lambda () (eq? (client-end cl) 'eof))))
        (set! adopting shell)
        (test-equal "and the connection is closed and gone, the error logged" '(() callback-error)
                    (list (shell-connections bad) (first-logged)))
        (client-close! cl)))

    ;; The run loop drops a connection whose handle closed behind the shell.
    (let* ((before (newest))
           (cl (open-client! (b "GET /kept HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (let ((c (adopted-since before)))
        (when c (uv-close! (connection-tcp c)))
        (wait-for (lambda () (and c (eq? (uv-handle-state (connection-tcp c)) 'closed))))
        (test-eq "a connection whose handle was closed behind the shell's back stays in the table"
                 'in-table
                 (if (and c (memq c (shell-connections shell))) 'in-table 'gone))
        (set! logged '())
        (raise-in-callback (make-message-condition "a bug in a callback"))
        (test-equal "until the run loop reconciles the table with the loop, and logs it" '(gone #t)
                    (list (if (and c (memq c (shell-connections shell))) 'in-table 'gone)
                          (let ((entry (assq 'reconciled logged)))
                            (and entry (pair? (cdr entry)) (eq? (cadr entry) c))))))
      (client-close! cl))

    ;; The end.
    (for-each client-close! clients)
    (test-eq "every connection closes and leaves the table" 'satisfied
             (wait-for (lambda () (null? (shell-connections shell)))))
    (test-equal "the listener accepted every connection" 'no-listen-error listen-error)
    (uv-close! listener)
    (run-until loop (lambda () (eq? (uv-handle-state listener) 'closed)) 8)
    (test-equal "and no handle is left on the loop" '() (uv-loop-live-handles loop))
    ;; The counters exist only in chez-libuv's dev build (`make build`); a
    ;; prod shim (`make prod`) answers zero for every kind, so they are read
    ;; only when they count the loop this suite made.
    (if (= (live-count 'loop) 1)
        (test-equal "nor a TCP handle, a read buffer or a write request" '(0 0 0)
                    (map live-count '(tcp read-buffer write-req)))
        (display "shell: chez-libuv's counters are off in this build; not read\n"))
    (uv-loop-teardown! loop)))
