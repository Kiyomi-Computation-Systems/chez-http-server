#!r6rs
;;; (http-server private shell): the direct libuv shell, over loopback.  M4.2.
;;;
;;; The shell performs the core's actions with chez-libuv (design §5.2).  This
;;; suite is the socket lane (design §8.5): it serves clients on the same loop,
;;; bound to 127.0.0.1:0, each wait capped by an iteration count, never
;;; wall-clock, and asserts on bytes, states and the order of verbs, never on
;;; how the kernel split the stream.  Its clients are tests/shell-testing.sls's,
;;; which the contract test shares.  A response is read back by chez-httparse's
;;; strict response parser (tests/response-reader.sls), not by our own code.
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
;;;   - a client that uploads four MiB past a refusal sends all of it, and
;;;     then reads the status and the stream's end: the connection lingers,
;;;     reading and dropping the upload (decision 0011's measurement, M4.4);
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
;;;     adoption fails, leaving no deadline armed;
;;;   - the run loop drops a connection whose handle closed behind the shell,
;;;     taking it out of the wheel, and runs on;
;;;   - the server's own listener (design §4.6; M4.3) serves a client; refuses
;;;     those over max-connections, closing each at once, the first refusal
;;;     logged and the count once a place is free; serves the next then;
;;;     listens on one listener at a time; closes the listener the clients
;;;     used at a shutdown, and never listens after it; listens with the
;;;     limits' backlog; and closes a listener that cannot listen, after which
;;;     the shell may listen again;
;;;   - deadlines (M5.3; decision 0005), under short limits and the loop's
;;;     own clock: a client that sends half a head is answered 408, then
;;;     closed once its linger passes; an idle keep-alive connection is
;;;     closed; a lingering client that never closes is closed; and so is one
;;;     that connects and sends nothing, whose idle deadline the shell armed
;;;     as it adopted it.  Each deadline is met at the first time the shell's
;;;     timer fires at or after it, the timer firing every tick-ms: within a
;;;     tick of the deadline, never before it.  The loop's clock is brought
;;;     up to date as each deadline is armed and each response written, so
;;;     a hold of the loop, a handler's, the shell's own work's or one before
;;;     an adoption, neither shortens the deadline armed after it nor dates
;;;     the response written after it early (chez-libuv #28).  A connection
;;;     closed from outside the core is armed no more;
;;;   - the shell's one timer: four connections add one timer to the loop;
;;;     its wheel empty, it stops, and the shell keeps it for its next
;;;     deadline, and closes it once shut down with no connection left; when
;;;     one firing's ticks raise for two connections, each is still ticked,
;;;     and a byte-machine contract condition among the raises is the one the
;;;     run loop raises again;
;;;   - and at the end every connection was accepted and has closed, and no
;;;     handle is left on the loop.
;;;
;;; Oracles: RFC 9110 §5.6.7's example instant, Sun, 06 Nov 1994 08:49:37
;;; GMT, as the shell's clock; chez-httparse's response parser; chez-libuv's
;;; live-handle list and its dev-build counters; byte-machine's own contract
;;; condition, provoked by a feed from inside a callback; the weak-pair
;;; instrument, calibrated below; and for deadlines, the loop's time
;;; (uv_now) each was armed at, read where it was armed, and the suite's
;;; own limits.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?
              current-time time-second time-nanosecond)
        (libuv) (uv-testing)
        (rename (only (libuv private native) live-counts) (live-counts debug-live-counts))
        (only (byte-machine private conditions)
              byte-machine-contract-condition? byte-machine-contract-condition-code)
        (byte-machine runtime)
        (only (generated httparse-message) httparse-message-machine)
        (only (httparse modes) httparse-message-type-value)
        (http-server private shell)
        (only (http-server server) server-phase)
        (only (http-server connection) conn-phase conn-parser-callbacks conn-span-callbacks)
        (http-server request) (http-server response) (http-server span) (http-server limits)
        (response-reader) (shell-testing))

(define (b s) (string->utf8 s))

;; RFC 9110 §5.6.7's example, as seconds since the epoch (`date -u -r`).
(define instant 784111777)
(define instant-date "Sun, 06 Nov 1994 08:49:37 GMT")

(define cap 4096)

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
;; (connection kind verb), or (shell kind verb) for the server's: only the
;; verb, so the trace keeps nothing of an action's bytes.  Each trap, set by
;; `trap!`, is (kind verb raised): the next trace of that verb, a
;; connection's `action` or `event` or the server's `server-event`, raises
;; `raised` first, as a bug in the shell would, and the trap is spent.
;; While `closing-at` is an action, the next connection to run it has its
;; handle closed by the trace first, behind the core's back, as a close from
;; outside the core would.  While `holding-at` is an action, the next
;; connection to run it holds the loop `slow-ms` in the trace first, as the
;; shell's own work might, a collection or a large copy; while it is
;; `adoption`, the listener holds the loop so before its next adoption.
(define traced '())
(define traps '())
(define closing-at #f)
(define holding-at #f)
(define (trace! c kind datum)
  (set! traced (cons (list c kind (car datum)) traced))
  (case (car datum)
    ((arm-deadline) (time! (list 'arm c (cadr datum) (uv-now loop))))
    ((tick) (time! (list (if (connection? c) 'tick 'fire) c (cadr datum)))))
  (when (and closing-at (connection? c) (eq? kind 'action) (equal? datum closing-at))
    (set! closing-at #f)
    (connection-close! c))
  (when (and holding-at (connection? c) (eq? kind 'action) (equal? datum holding-at))
    (set! holding-at #f)
    (hold! slow-ms))
  (let ((t (find (lambda (t) (and (eq? kind (car t)) (eq? (car datum) (cadr t)))) traps)))
    (when t
      (set! traps (remq t traps))
      (raise (caddr t)))))

;; trap! : Symbol Symbol [Any] -> Void
;; Set a trap for the next trace of `verb` as `kind`, behind those set: it
;; raises `raised`, by default a message condition, as a bug would.
(define (trap! kind verb . raised)
  (set! traps (append traps (list (list kind verb (if (pair? raised)
                                                      (car raised)
                                                      (make-message-condition "a bug in the shell")))))))

;; What the deadlines' checks read, newest first: each deadline armed, as
;; (arm connection kind at), `at` the loop's time where it was armed; each
;; tick a connection was given, as (tick connection now); and each time a
;; shell's timer fired, as (fire shell now), which it tells its server.  The
;; first idle deadline, which the shell arms as it adopts a connection, is
;; recorded where the suite's listener adopts it.
(define timed '())
(define (time! entry) (set! timed (cons entry timed)))

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
;; `/raise` raises; `/big`, four MiB, held weakly here so the retention
;; check can ask whether anything else still holds it, and closing the
;; connection after it, so the client knows it has the whole response when it
;; reads the stream's end; and `/slow`, answered once the handler has held
;; the loop `slow-ms`, as a handler that computes for a while does.
(define big-size (* 4 1024 1024))
(define big-body #f)
(define slow-ms 300)
(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))
;; hold! : Nat -> Void — keep the loop's thread busy `ms`.
(define (hold! ms)
  (let ((until (+ (monotonic-ms) ms)))
    (let spin () (when (< (monotonic-ms) until) (spin)))))
(define (handler req)
  (let ((target (span->bytevector (request-target req))))
    (when (bytevector=? target (b "/slow"))
      (hold! slow-ms))
    (cond ((bytevector=? target (b "/big"))
           (let ((body (make-bytevector big-size 120)))
             (set! big-body (weak-cons body '()))
             (make-response 200 #f (list (cons (b "Connection") (b "close"))) body)))
          ((bytevector=? target (b "/raise"))
           (raise (make-message-condition "the handler failed")))
          (else (make-response 200 #f '() target)))))

;; with : Symbol Any -> Limits — the defaults, but one field.
(define (with field value) (limits-with default-limits (list (cons field value))))

;; --- the loop, the shell, and a listener of the suite's own ---------------------

(define loop #f)
(define shell #f)
(define listener #f)
(define port #f)
(define adopting #f)                   ; the shell the listener adopts into
(define adopted '())                   ; newest first
(define listen-error 'no-listen-error)
(define small-send-buffer #f)
(define pairing #f)                    ; adopt connections two at a time
(define held #f)                       ; the first of a pair, accepted, not yet adopted

;; open-server! : -> Void
;; The loop, the shell, and a listener on 127.0.0.1:0 that adopts each
;; connection it accepts into `adopting`; with `small-send-buffer`, the
;; connection's send buffer is asked to be that small first.  While
;; `pairing`, it holds each connection it accepts until it accepts another,
;; and adopts the two in one callback, so the shell arms both at one
;; instant.  Made inside the suite, so a failure here is the harness's
;; status, not a crash.
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
                      (cond ((and pairing (not held)) (set! held tcp))
                            (else (when held (adopt! held) (set! held #f))
                                  (adopt! tcp))))))))

;; adopt! : UvTcp -> Void
;; Serve `tcp` in `adopting`, recording when: the shell arms a connection's
;; first deadline, its idle one, as it adopts it (M5.3).  While `holding-at`
;; is `adoption`, the loop is held first.
(define (adopt! tcp)
  (when (eq? holding-at 'adoption)
    (set! holding-at #f)
    (hold! slow-ms))
  (let ((c (shell-adopt! adopting tcp)))
    (when (connection? c) (time! (list 'arm c 'idle (uv-now loop))))
    (set! adopted (cons c adopted))))

;; --- clients (tests/shell-testing.sls) ---------------------------------------

(define clients '())

;; open-client-to! : Nat (U #f Bytevector) [Boolean] -> Client
;; A client on the loop that connects to `to`, writes `request` whole unless
;; it is #f, and reads unless told to wait; closed at the suite's end.
(define open-client-to!
  (case-lambda
    ((to request) (open-client-to! to request #t))
    ((to request read?)
     (let ((cl (open-client loop to request read?)))
       (set! clients (cons cl clients))
       cl))))

;; open-client! : (U #f Bytevector) [Boolean] -> Client — one to the suite's
;; own listener.
(define open-client!
  (case-lambda
    ((request) (open-client-to! port request #t))
    ((request read?) (open-client-to! port request read?))))

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

;; run-shell : Shell (-> Boolean) -> Symbol
;; Step `sh`'s run loop, which logs a callback's error and runs on, until
;; `pred` holds (tests/shell-testing.sls): 'satisfied or 'iterations-exhausted.
(define (run-shell sh pred) (run-shell-until loop sh pred cap))

;; --- deadlines (M5.3) -------------------------------------------------------------

;; Short limits, so the suite waits for its deadlines briefly: a fifth of a
;; second or a little more for a head, an idle connection and a linger, each
;; its own, so a deadline armed for the wrong kind shows, and a tick of 10
;; ms.  Loopback moves a client's bytes in a few milliseconds, so no
;; deadline passes before the client has made its move.
(define quick-limits
  (limits-with default-limits
               '((read-header-timeout-ms . 200) (idle-timeout-ms . 250) (linger-timeout-ms . 300)
                 (tick-ms . 10))))

;; open-adopted! : (U #f Bytevector) -> (Pair Client (U Connection #f))
;; A client that connects to the suite's listener, sends `request` unless it
;; is #f, and reads; and the connection it was adopted as, once it is.
(define (open-adopted! request)
  (let* ((before (newest)) (cl (open-client! request)))
    (wait-for (lambda () (and (adopted-since before) #t)))
    (cons cl (adopted-since before))))

;; deadlines-passed : Shell Connection -> (Listof (List Symbol Datum))
;; Each tick `c` was given, in order: the kind of the deadline armed last
;; before it, and `on-time` if the tick came the first time `sh`'s timer
;; fired at or after that deadline, the instant it was armed at plus the
;; kind's limit: at a firing, never before the deadline, and no firing
;; between.  Otherwise the deadline, the tick's instant, and the firings
;; from the deadline to the tick.
(define (deadlines-passed sh c)
  (let ((log (reverse timed)))
    (let scan ((es log) (armed #f) (out '()))
      (if (null? es)
          (reverse out)
          (let ((e (car es)))
            (cond ((and (eq? (car e) 'arm) (eq? (cadr e) c)) (scan (cdr es) e out))
                  ((and (eq? (car e) 'tick) (eq? (cadr e) c))
                   (let* ((kind (caddr armed))
                          (deadline (+ (cadddr armed) (limits-deadline-ms quick-limits kind)))
                          (now (caddr e))
                          (firings (filter (lambda (f) (and (eq? (car f) 'fire) (eq? (cadr f) sh)
                                                            (<= deadline (caddr f) now)))
                                           log)))
                     (scan (cdr es) armed
                           (cons (list kind (if (and (<= deadline now) (equal? (map caddr firings) (list now)))
                                                'on-time
                                                (list deadline now (map caddr firings))))
                                 out))))
                  (else (scan (cdr es) armed out))))))))

;; deadline-outcome : Shell (Pair Client Connection) -> Datum
;; What the client read, as statuses; how its stream ended; and each
;; deadline its connection passed (deadlines-passed).
(define (deadline-outcome sh p)
  (list (map status (responses (client-bytes (car p)))) (client-end (car p))
        (deadlines-passed sh (cdr p))))

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

    ;; The upload past a refusal (decision 0011's measurement, as a test).  A
    ;; client sends four MiB after a head the core refuses, with no Host, and
    ;; reads only once all of it is sent, as Python's http.client and Node's
    ;; fetch do.  Its send buffer is small, so the upload is sent only if the
    ;; server reads it: the connection lingers, reading and dropping it.  A
    ;; close at once would reset the connection with the upload unread, and
    ;; fail the send before the status is read.
    (let* ((head (b (string-append "POST /upload HTTP/1.1\r\nContent-Length: "
                                   (number->string big-size) "\r\n\r\n")))
           (upload (make-bytevector (+ (bytevector-length head) big-size) 120))
           (sent 'not-yet)
           (cl (open-client! #f #f)))
      (bytevector-copy! head 0 upload 0 (bytevector-length head))
      (wait-for (lambda () (not (eq? (client-connected cl) 'never))))
      ;; A client that did not connect sends nothing, and both checks say how
      ;; its connect ended.
      (let ((connected (client-connected cl)))
        (when (eq? connected 'no-error)
          (uv-send-buffer-size! (client-tcp cl) 4096)
          ;; It reads once its send is over, whatever the outcome; a send the
          ;; suite's own close cuts short has nothing to read.
          (uv-write! (client-tcp cl) upload
                     (lambda (err)
                       (set! sent (err->symbol err))
                       (when (uv-handle-open? (client-tcp cl)) (client-read! cl)))))
        (test-eq "a client that uploads four MiB past a refusal sends all of it" 'no-error
                 (if (eq? connected 'no-error)
                     (begin (wait-for (lambda () (not (eq? sent 'not-yet)))) sent)
                     (list 'not-connected connected)))
        (test-equal "and then reads the refusal, a 400, and the stream's end" '((400) eof)
                    (if (eq? connected 'no-error)
                        (begin (wait-for (lambda () (not (eq? (client-end cl) 'open))))
                               (list (map status (responses (client-bytes cl))) (client-end cl)))
                        (list 'not-connected connected))))
      (client-close! cl))

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
        (test-eq "and raises it again when the log raises" 'reentrancy (contract-code outcome)))
      ;; A wait through the run loop that its raise ends leaves nothing of the
      ;; wait's own on the loop: run-shell-until's ticker is closed on the way
      ;; out (tests/shell-testing.sls).
      (let* ((before (length (uv-loop-live-handles loop)))
             (t (make-uv-timer loop))
             (outcome (begin
                        (uv-timer-start! t (lambda (t) (raise reentrancy)) 0 0)
                        (guard (e ((byte-machine-contract-condition? e) 'raised))
                          (run-shell shell (lambda () #f))
                          'ran-out))))
        (uv-close! t)
        (run-until loop (lambda () (eq? (uv-handle-state t) 'closed)) 8)
        (test-equal "a wait the run loop's raise ends leaves no handle of its own on the loop"
                    (list 'raised before)
                    (list outcome (length (uv-loop-live-handles loop))))))
    (set! logged '())
    (let ((outcome (raise-in-callback (make-message-condition "a bug in a callback"))))
      (test-eq "after any other error in a callback, the run loop runs on" 'ran-on outcome)
      (test-eq "having logged the callback's error first" 'callback-error (first-logged)))

    ;; A bug in a connection's callback closes that connection.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /trap HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (trap! 'action 'call-handler)
      (test-eq "when a connection's callback raises, its client reads the stream's end" 'satisfied
               (run-shell shell (lambda () (eq? (client-end cl) 'eof))))
      (let ((c (adopted-since before)))
        (test-equal "with no response, the connection closed and gone, the error logged"
                    '(0 #t callback-error)
                    (list (collector-count (client-collector cl)) (closed-and-gone? shell c)
                          (first-logged))))
      (client-close! cl))

    ;; An adoption that fails closes the connection.
    (let ((bad (make-shell loop handler (with 'read-buffer-size 0) clock log! trace!)))
      (set! adopting bad)
      (set! logged '())
      (let ((cl (open-client! #f)))
        (test-eq "when a connection cannot be adopted, its client reads the stream's end" 'satisfied
                 (run-shell bad (lambda () (eq? (client-end cl) 'eof))))
        (set! adopting shell)
        (test-equal "and the connection is closed and gone, the error logged" '(() callback-error)
                    (list (shell-connections bad) (first-logged)))
        (test-eqv "leaving no deadline armed" 0 (shell-deadlines bad))
        (client-close! cl))
      ;; The adoption armed a deadline, so the shell made its timer, and
      ;; keeps it until it serves no more.
      (let ((timer (shell-timer bad)))
        (shell-shutdown! bad)
        (test-equal "a shell shut down with no connection left closes the timer it kept"
                    '(#t #f #t)
                    (list (and timer (uv-timer? timer) #t) (shell-timer bad)
                          (and timer (memq (uv-handle-state timer) '(closing closed)) #t)))))

    ;; A bug before a connection is served closes its handle: the server's
    ;; step raises on the arrival, and the client reads the stream's end.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! #f)))
      (trap! 'server-event 'connection-arrived)
      (test-eq "when the server's step raises on an arrival, its client reads the stream's end"
               'satisfied
               (run-shell shell (lambda () (eq? (client-end cl) 'eof))))
      (set! traps '())
      (test-equal "with nothing read, no connection served, and the error logged"
                  '(0 none-served callback-error)
                  (list (collector-count (client-collector cl))
                        (if (adopted-since before) 'served 'none-served)
                        (first-logged)))
      (client-close! cl))

    ;; The run loop drops a connection whose handle closed behind the shell.
    (let* ((before (newest))
           (cl (open-client! (b "GET /kept HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (let ((c (adopted-since before)))
        (when c (uv-close! (connection-tcp c)))
        (wait-for (lambda () (and c (eq? (uv-handle-state (connection-tcp c)) 'closed))))
        (test-equal "a connection whose handle was closed behind the shell's back stays in the table, its deadline armed"
                    '(in-table #t)
                    (list (if (and c (memq c (shell-connections shell))) 'in-table 'gone)
                          (and c (number? (connection-deadline c)))))
        (set! logged '())
        (let ((outcome (raise-in-callback (make-message-condition "a bug in a callback"))))
          (test-equal "until the run loop reconciles the table with the loop, logs it, takes it out of the wheel, and runs on"
                      '(gone #t #f ran-on)
                      (list (if (and c (memq c (shell-connections shell))) 'in-table 'gone)
                            (let ((entry (assq 'reconciled logged)))
                              (and entry (pair? (cdr entry)) (eq? (cadr entry) c)))
                            (and c (connection-deadline c))
                            outcome))))
      (client-close! cl))

    ;; The server's own listener, at most one connection open.
    (set! logged '())
    (let* ((capped (make-shell loop handler (with 'max-connections 1) clock log! trace!))
           (to (shell-listen! capped "127.0.0.1" 0))
           (listening (shell-listener capped))
           (served (lambda (cl) (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))))
           (ended (lambda (cl) (wait-for (lambda () (not (eq? (client-end cl) 'open))))))
           (refusals (lambda ()
                       (filter (lambda (entry) (memq (car entry) '(refusing refused)))
                               (reverse logged))))
           (a (open-client-to! to (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the server's own listener serves a client" 'satisfied (served a))
      (test-eq "and listens on one listener at a time" 'refused
               (guard (e ((assertion-violation? e) 'refused))
                 (shell-listen! capped "127.0.0.1" 0)
                 'listened-again))
      (let* ((over (open-client-to! to #f))
             (over-end (ended over))
             (again (open-client-to! to #f))
             (again-end (ended again)))
        (test-equal "two clients over max-connections each read the stream's end, having read nothing"
                    '(satisfied satisfied (eof 0) (eof 0))
                    (list over-end again-end
                          (list (client-end over) (collector-count (client-collector over)))
                          (list (client-end again) (collector-count (client-collector again)))))
        (test-equal "the first refusal is logged, the second is not, and one connection is open"
                    '(((refusing max-connections)) 1)
                    (list (refusals) (length (shell-connections capped))))
        (client-close! over)
        (client-close! again))
      (client-close! a)
      (test-eq "when the client served closes, its place is free" 'satisfied
               (wait-for (lambda () (null? (shell-connections capped)))))
      (let ((next (open-client-to! to (b "GET /next HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-eq "and the next client is served" 'satisfied (served next))
        (test-equal "and the refusals are logged with their count"
                    '((refusing max-connections) (refused max-connections 2))
                    (refusals))
        (client-close! next)
        (wait-for (lambda () (null? (shell-connections capped)))))
      (shell-shutdown! capped)
      (test-equal "a shutdown closes the listener the clients used, and the server drains"
                  '(closed draining)
                  (begin
                    (wait-for (lambda () (eq? (uv-handle-state listening) 'closed)))
                    (list (uv-handle-state listening) (server-phase (shell-server capped)))))
      (test-eq "and a server that has stopped listening never listens again" 'refused
               (guard (e ((assertion-violation? e) 'refused))
                 (shell-listen! capped "127.0.0.1" 0)
                 'listened-again)))

    ;; A listener listens with the limits' backlog, and one that cannot listen
    ;; is closed, after which the shell may listen again.
    (let* ((bad (make-shell loop handler (with 'backlog -1) clock log! trace!))
           (reason (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
                     (shell-listen! bad "127.0.0.1" 0)
                     'listening)))
      (test-equal "a listener with the limits' backlog of -1 cannot listen, and is closed"
                  '(backlog-out-of-range closed)
                  (let ((l (shell-listener bad)))
                    (wait-for (lambda () (and l (eq? (uv-handle-state l) 'closed))))
                    (list reason (if l (uv-handle-state l) 'no-listener)))))
    (let* ((holder (make-shell loop handler default-limits clock log! trace!))
           (taken (shell-listen! holder "127.0.0.1" 0))
           (retry (make-shell loop handler default-limits clock log! trace!))
           (in-use (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
                     (shell-listen! retry "127.0.0.1" taken)
                     'listened))
           (failed (shell-listener retry)))
      (test-equal "a listener on a port in use cannot listen, and is closed" '(EADDRINUSE closed)
                  (begin (wait-for (lambda () (and failed (eq? (uv-handle-state failed) 'closed))))
                         (list in-use (if failed (uv-handle-state failed) 'no-listener))))
      (test-eq "and the shell may listen again" 'listening
               (guard (e ((assertion-violation? e) 'refused))
                 (shell-listen! retry "127.0.0.1" 0)
                 'listening))
      (shell-shutdown! holder)
      (shell-shutdown! retry)
      (wait-for (lambda () (for-all (lambda (sh) (eq? (uv-handle-state (shell-listener sh)) 'closed))
                                    (list holder retry)))))

    ;; The end of the connections the suite's own shell served.
    (for-each client-close! clients)
    (set! clients '())
    (test-eq "every connection closes and leaves the table" 'satisfied
             (wait-for (lambda () (null? (shell-connections shell)))))
    (test-equal "the listener accepted every connection" 'no-listen-error listen-error)

    ;; One timer however many connections are open (M5.3): four clients
    ;; that send nothing, on a shell of their own under decision 0005's
    ;; limits, so no deadline of theirs passes while the suite looks.  The
    ;; loop may hold other shells' timers, kept stopped, so what is counted
    ;; is the timers the four add.
    (let* ((steady (make-shell loop handler default-limits clock log! trace!))
           (timers (lambda () (filter uv-timer? (uv-loop-live-handles loop))))
           (before (length (timers)))
           (counted (live-count 'timer)))
      (set! adopting steady)
      (let* ((w (open-adopted! #f)) (x (open-adopted! #f)) (y (open-adopted! #f)) (z (open-adopted! #f))
             (four (list w x y z)))
        (test-equal "four connections open on one shell add one timer to the loop, the shell's, firing every tick"
                    '(4 1 #t 250)
                    (let ((timer (shell-timer steady)) (now (timers)))
                      (list (length (shell-connections steady)) (- (length now) before)
                            (and timer (memq timer now) #t)
                            (if timer (uv-timer-repeat timer) 'no-timer))))
        ;; The counters exist only in chez-libuv's dev build, as below.
        (if (= (live-count 'loop) 1)
            (test-eqv "and chez-libuv counts one timer more" 1 (- (live-count 'timer) counted))
            (display "shell: chez-libuv's counters are off in this build; not read\n"))
        (for-each (lambda (p) (client-close! (car p))) four)
        (wait-for (lambda () (null? (shell-connections steady)))))
      (shell-shutdown! steady))

    ;; A write reads the loop's time too: its Date is the shell's clock's
    ;; last reading plus the loop's time since (decision 0010).  On a shell
    ;; whose clock reads 800 ms into RFC 9110's second, two requests in one
    ;; write: the first's answer reads the clock, and the second, `/slow`,
    ;; is answered once its handler has held the loop 300 ms, in the next
    ;; second.
    (let ((dated (make-shell loop handler default-limits
                             (lambda () (+ (* 1000 instant) 800)) log! trace!)))
      (set! adopting dated)
      (let ((p (open-adopted! (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /slow HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "a response written after its handler held the loop 300 ms is dated after the hold"
                    (list 'satisfied (list instant-date "Sun, 06 Nov 1994 08:49:38 GMT"))
                    (let ((read (wait-for (lambda () (= 2 (length (responses (client-bytes (car p)))))))))
                      (list read (map (lambda (r) (field r "Date")) (responses (client-bytes (car p)))))))
        (client-close! (car p))
        (wait-for (lambda () (null? (shell-connections dated)))))
      (shell-shutdown! dated))

    ;; Deadlines (M5.3), on a shell of their own with short limits, adopted
    ;; through the suite's listener, which records when each was adopted.
    (let* ((quick (make-shell loop handler quick-limits clock log! trace!))
           (firings (lambda ()
                      (length (filter (lambda (e) (and (eq? (car e) 'fire) (eq? (cadr e) quick))) timed)))))
      (set! adopting quick)
      (let* ((half (open-adopted! (b "GET /half HTTP/1.1\r\nHo")))
             (idle (open-adopted! (b "GET /idle HTTP/1.1\r\nHost: x\r\n\r\n")))
             (bye (open-adopted! (b "GET /bye HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")))
             (silent (open-adopted! #f))
             (all (list half idle bye silent)))
        (test-eq "each of them closes once its deadlines pass" 'satisfied
                 (wait-for (lambda ()
                             (for-all (lambda (p)
                                        (and (closed-and-gone? quick (cdr p))
                                             (not (eq? (client-end (car p)) 'open))))
                                      all))))
        (test-equal "a client that sends half a head reads 408 once its head's deadline passes, and the stream's end; it is closed once its linger's does"
                    '((408) eof ((header on-time) (linger on-time)))
                    (deadline-outcome quick half))
        (test-equal "an idle keep-alive connection is closed once its idle deadline passes"
                    '((200) eof ((idle on-time)))
                    (deadline-outcome quick idle))
        (test-equal "a lingering client that never closes is closed once its linger deadline passes"
                    '((200) eof ((linger on-time)))
                    (deadline-outcome quick bye))
        (test-equal "a client that connects and sends nothing is closed at the idle deadline armed as it was adopted"
                    '(() eof ((idle on-time)))
                    (deadline-outcome quick silent))
        (for-each (lambda (p) (client-close! (car p))) all))

      ;; A handler that holds the loop past a deadline's length (M5.3's
      ;; review).  libuv reads its clock once a turn, so the shell brings it
      ;; up to date as it arms each deadline, and the deadline armed after
      ;; the answer runs from then, not from before the handler ran.  Here
      ;; the handler holds the loop 300 ms, past the idle limit's 250.
      (let ((slow (open-adopted! (b "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "after a handler that holds the loop 300 ms, the idle deadline armed after its answer is still ahead when the client has it"
                    '(satisfied #t)
                    (let* ((read (wait-for (lambda () (= 1 (length (responses (client-bytes (car slow))))))))
                           (deadline (connection-deadline (cdr slow))))
                      (list read (and deadline (> deadline (uv-now loop)) #t))))
        (client-close! (car slow)))

      ;; The shell's own work can hold the loop too, not only a handler.
      ;; Here the trace holds it 300 ms as the shell starts reading again
      ;; after a keep-alive response, the action before its idle deadline's
      ;; arm.  The deadline is also the one the trace recorded, the time it
      ;; read plus the limit: the deadlines' checks above read the trace.
      (set! holding-at '(read-start))
      (let ((held-up (open-adopted! (b "GET /held HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "after the shell's own work holds the loop 300 ms, the idle deadline armed after it is still ahead, and is the one its trace recorded"
                    '(satisfied #t #t)
                    (let* ((read (wait-for (lambda ()
                                             (and (not holding-at)
                                                  (= 1 (length (responses (client-bytes (car held-up)))))))))
                           (deadline (connection-deadline (cdr held-up)))
                           (armed (find (lambda (e) (and (eq? (car e) 'arm) (eq? (cadr e) (cdr held-up))))
                                        timed)))
                      (list read
                            (and deadline (> deadline (uv-now loop)) #t)
                            (and deadline armed (eq? (caddr armed) 'idle)
                                 (= deadline (+ (cadddr armed) (limits-deadline-ms quick-limits 'idle)))))))
        (set! holding-at #f)
        (client-close! (car held-up)))

      ;; And so can the work before an adoption: the listener holds the
      ;; loop 300 ms before the shell adopts a connection, arming its idle
      ;; deadline as it does.
      (set! holding-at 'adoption)
      (let ((late-adopted (open-adopted! #f)))
        (test-eq "a connection adopted after the loop is held 300 ms has its idle deadline ahead"
                 #t
                 (let ((deadline (connection-deadline (cdr late-adopted))))
                   (and deadline (> deadline (uv-now loop)) #t)))
        (set! holding-at #f)
        (client-close! (car late-adopted)))

      ;; A deadline the core asks for once the shell has closed its
      ;; connection behind it is not armed: the connection has left the
      ;; wheel for good.  A keep-alive response written, the connection is
      ;; closed from outside the core just as its idle deadline is armed.
      (set! closing-at '(arm-deadline idle))
      (let ((late (open-adopted! (b "GET /late HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "a connection closed from outside the core as it arms a deadline leaves with none armed"
                    '(satisfied #f 0)
                    (let ((gone (wait-for (lambda () (closed-and-gone? quick (cdr late))))))
                      (list gone (connection-deadline (cdr late)) (shell-deadlines quick))))
        (set! closing-at #f)
        (client-close! (car late)))

      ;; Its wheel empty, the next firing stops the timer, and the shell
      ;; keeps it for its next deadline (0005).  Fifty turns of the loop, each
      ;; waiting on the wait's own 1 ms timer, span five ticks of 10 ms and
      ;; more, so a timer that ran on would fire in them.
      (let ((timer (shell-timer quick)))
        (test-equal "its wheel empty, the timer stops, firing once more at most, and the shell keeps it"
                    '(#t #t)
                    (let* ((before (firings))
                           (ran (run-until/ticking loop (lambda () #f) 50)))
                      (list (<= (- (firings) before) 1)
                            (and timer (uv-timer? timer) (eq? (shell-timer quick) timer)))))

        ;; Each tick is delivered under its own guard.  Two connections
        ;; adopted in one callback share their idle deadline, so the kept
        ;; timer, started again, ticks both at one firing, the first adopted
        ;; first.  Both ticks raise, as bugs would: the first an error, the
        ;; second byte-machine's contract condition.  Each is still ticked,
        ;; and closed, and the contract condition is the one the run loop
        ;; raises again, which keeps it fatal (design §6.4).
        (set! logged '())
        (set! pairing #t)
        (let* ((n (length adopted))
               (first-cl (open-client! #f))
               (second-cl (open-client! #f)))
          (wait-for (lambda () (= (length adopted) (+ n 2))))
          (set! pairing #f)
          ;; A pair whose second never came leaves its first held: closed.
          (when held (uv-close! held) (set! held #f))
          (let* ((pair (if (= (length adopted) (+ n 2)) (list (cadr adopted) (car adopted)) '()))
                 (both-gone (lambda ()
                              (and (pair? pair)
                                   (for-all (lambda (c) (closed-and-gone? quick c)) pair)))))
            (trap! 'event 'tick)
            (trap! 'event 'tick (provoke-reentrancy))
            ;; let*, since Chez evaluates a call's arguments in no fixed order.
            (test-equal "when one firing's ticks raise for both of two connections, each is still ticked and closed, and a contract condition is the raise the run loop raises again"
                        '(reentrancy satisfied (((idle on-time)) ((idle on-time))) #t)
                        (let* ((raised (guard (e ((byte-machine-contract-condition? e)
                                                  (byte-machine-contract-condition-code e)))
                                         (run-shell quick both-gone)))
                               (gone (wait-for both-gone))
                               (ticked (map (lambda (c) (deadlines-passed quick c)) pair)))
                          (list raised gone ticked (eq? (shell-timer quick) timer)))))
          (set! traps '())
          (client-close! first-cl)
          (client-close! second-cl))

        (set! adopting shell)
        (shell-shutdown! quick)
        (test-equal "shut down with no connection left, the shell closes its timer"
                    '(#f #t)
                    (list (shell-timer quick)
                          (and timer (memq (uv-handle-state timer) '(closing closed)) #t)))))

    ;; The end.  The suite's own shell, shut down with no connection left,
    ;; closes the timer it kept.
    (for-each client-close! clients)
    (shell-shutdown! shell)
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
