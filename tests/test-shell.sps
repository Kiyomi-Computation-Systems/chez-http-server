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
;;;   - a handler is called after libuv's turn, from the scheduler's drain, on
;;;     no coroutine, never inside a libuv callback (decision 0014; M7.1),
;;;     and not at all once its connection has closed before the drain
;;;     reaches the call; and a loop let go with its shell is collected,
;;;     though its scheduler, kept for it, holds it;
;;;   - a handler that waits answers `awaiting`: its thunk parks on a
;;;     coroutine, nothing is answered while it waits, and once woken its
;;;     answer is written; its reader takes each piece on a coroutine, in
;;;     order, reading waiting while it takes one, and its producer is called
;;;     on a coroutine for each piece; an ordinary handler that waits fails,
;;;     500, the refusal logged as R2's (M7.1);
;;;   - the verbs a handler waits with (decision 0015, M7.2): a handler that
;;;     waits on `await` is woken by another request's handler, and a second
;;;     resume is logged as `late-resume` (R4); a handler that holds the
;;;     loop, then sleeps 20 ms, sleeps 18 ms or more by the monotonic clock,
;;;     its sleep armed on the loop's clock brought up to date, and one whose
;;;     deadline ends a sleep of a minute is answered at once, nothing left
;;;     armed after either; once a shell on the loop serves no more, which
;;;     closes the timer of the loop's waits, a sleep makes another; and a
;;;     handler that resolves localhost is answered what uv-getaddrinfo!
;;;     itself answers, one that resolves a name libuv refuses at the call,
;;;     empty, with a NUL or too long, `invalid-name`, and one that resolves
;;;     a name with an empty label `EAI_NONAME`;
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
;;;   - a streamed response (M6.3, decision 0013 item 8): a MiB, chunked, to
;;;     a client that reads nothing yet, its writes left waiting, the bytes
;;;     outstanding never past decision 0005's high water by more than a
;;;     piece's write, each piece's write a write request of chez-libuv's,
;;;     never held, then read whole and in order; rows of 100 bytes to a
;;;     client that reads nothing yet, never more than 64 writes outstanding
;;;     (M6.3's second review), and those a turn writes one write request of
;;;     chez-libuv's, the shell holding a turn's small writes for one libuv
;;;     write, then read whole; the rows handed out in one bytevector,
;;;     refilled at each call, read whole and in order, each as it was
;;;     handed over; pieces of 100 bytes and 5,000 in turn, in order, a larger
;;;     write sent after the smaller ones held; rows whose client goes while
;;;     they are outstanding, a read error, then each row's write settled,
;;;     and so are the rows of a turn whose one write is refused at the call;
;;;     a stream's head sent before its producer is first called, on a stream
;;;     behind another on one connection; pieces close-delimited to HTTP/1.0,
;;;     read at the close; and a producer that raises after a piece, a bare
;;;     close, the body cut short, what it raised logged;
;;;   - a write outstanding keeps nothing of its response: chez-libuv copied
;;;     the segments at the call, and the completion keeps their byte count
;;;     alone (design §7.3; M3.3's check, against the real write executor);
;;;   - a write that fails, at its completion or when it is issued, closes the
;;;     connection as a read error, and is settled after (design §6.3);
;;;   - the run loop raises again a byte-machine contract condition that a
;;;     callback raised, even when the log raises, and runs on after any other
;;;     (design §6.4, the first hazard; decision 0003 item 4);
;;;   - a connection whose callback raises is closed, and so is one whose
;;;     adoption fails, leaving no deadline armed; one whose callback raises
;;;     once a write is held sends nothing, and its close is its last event;
;;;     and one whose handler's answer raises as it is dispatched, in the
;;;     drain after libuv's turn, is closed, the raise logged as a callback's
;;;     (M7.1);
;;;   - the run loop drops a connection whose handle closed behind the shell,
;;;     taking it out of the wheel, and runs on;
;;;   - the server's own listener (design §4.6; M4.3) serves a client; refuses
;;;     those over max-connections, closing each at once, the first refusal
;;;     logged and the count once a place is free; serves the next then;
;;;     listens on one listener at a time; closes the listener the clients
;;;     used at a shutdown, and never listens after it; listens with the
;;;     limits' backlog; and closes a listener that cannot listen, after which
;;;     the shell may listen again;
;;;   - deadlines (M5.3; decision 0005), under short limits and the loop's own
;;;     clock: a client that sends half a head is answered 408, then closed
;;;     once its linger passes; an idle keep-alive connection is closed; a
;;;     lingering client that never closes is closed; and so is one that
;;;     connects and sends nothing, whose idle deadline the shell armed as it
;;;     adopted it.  Then slowhttptest's three shapes (the M5 exit): a head
;;;     sent a piece at a time is answered 408 at the deadline armed as it
;;;     began, which its pieces never move; a body sent a piece at a time,
;;;     then stopped, is answered 408 at the deadline armed again at its last
;;;     piece; and a client that never reads a MiB answer is closed at its
;;;     write's deadline, the write having held the loop less than a tick
;;;     (chez-libuv #35: bytes copied in bulk since v0.7.1).  Each deadline
;;;     is met at the first time the shell's timer fires at or after it, the
;;;     timer firing every tick-ms: within a tick of the deadline, never
;;;     before it.  The loop's clock is
;;;     brought up to date as each deadline is armed and each response
;;;     written, so a hold of the loop, a handler's, the shell's own work's or
;;;     one before an adoption, neither shortens the deadline armed after it
;;;     nor dates the response written after it early (chez-libuv #28).  A
;;;     connection closed from outside the core is armed no more;
;;;   - backpressure on the read side (M6.2), on a shell made on credit: a
;;;     reader handed a read of a 64 KiB body sent at once makes reading wait
;;;     for its credit, so the connection has no deadline armed and the
;;;     shell's timer stops while the connection stays, past the body
;;;     deadline's length; credited each time it waits, it is handed the
;;;     whole body in order, never holding more than one read, and the
;;;     response is written; and a credit for more than it was handed closes
;;;     the connection and raises to the caller;
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
;;; (uv_now) each was armed at, read where it was armed, and each write
;;; began at, and the suite's own limits.
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
        (only (http-server private scheduler)
              scheduler-phase current-coroutine coroutine-park! coroutine-wake! coroutine-yield!
              scheduler-invariant? scheduler-invariant-name)
        (only (http-server awaiting) awaiting deadline-passed? resolve-error? resolve-error-reason)
        (only (http-server private waits) await sleep-ms with-deadline resolve)
        (only (http-server server) server-phase)
        (only (http-server connection) conn-phase conn-parser-callbacks conn-span-callbacks
              conn-outstanding conn-outstanding-bytes)
        (http-server request) (http-server response) (http-server span) (http-server limits)
        (only (http-server body) read-body read-whole-body)
        (response-reader) (shell-testing) (producers))

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
;; While `watching-stream`, `stream-most` keeps the most bytes a connection
;; had outstanding as it issued a write, and `stream-most-writes` the most
;; writes: the core counts a write as it asks for it, so the trace, which
;; sees the action before it is performed, reads them with it.
(define traced '())
(define traps '())
(define closing-at #f)
(define closing-on #f)
(define holding-at #f)
(define watching-stream #f)
(define stream-most 0)
(define stream-most-writes 0)
(define (trace! c kind datum)
  (set! traced (cons (list c kind (car datum)) traced))
  (when (and watching-stream (connection? c) (eq? kind 'action) (eq? (car datum) 'write))
    (set! stream-most (max stream-most (conn-outstanding-bytes (connection-state c))))
    (set! stream-most-writes (max stream-most-writes (conn-outstanding (connection-state c)))))
  (case (car datum)
    ((arm-deadline) (time! (list 'arm c (cadr datum) (uv-now loop))))
    ((write) (time! (list 'write c (uv-now loop))))
    ((tick) (time! (list (if (connection? c) 'tick 'fire) c (cadr datum)))))
  (when (and closing-at (connection? c) (eq? kind 'action) (equal? datum closing-at))
    (set! closing-at #f)
    (connection-close! c))
  (when (and closing-on (connection? c) (eq? kind 'action) (eq? (car datum) closing-on))
    (set! closing-on #f)
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
;; write a connection began, as (write connection at); each tick a
;; connection was given, as (tick connection now); and each time a shell's
;; timer fired, as (fire shell now), which it tells its server.  The first
;; idle deadline, which the shell arms as it adopts a connection, is
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

;; The handler answers 200 with the request's target as the body, reading a
;; POST's body first (decision 0013: a response given instead of a reader
;; would close the connection), except: `/echo` reads the body whole and
;; answers with it; `/early` answers without reading it; `/small` reads it
;; whole, capped at 4 bytes;
;; `/raise` raises; `/big`, four MiB, held weakly here so the retention
;; check can ask whether anything else still holds it, and closing the
;; connection after it, so the client knows it has the whole response when it
;; reads the stream's end; `/wide`, a MiB, more than the kernel holds for a
;; client that never reads once the connection's send buffer is made small,
;; as the slow reader's is; `/slow`, answered once the handler has held
;; the loop `slow-ms`, as a handler that computes for a while does; and
;; `/credit`, read by a streaming reader that keeps what it is handed in
;; `credit-pieces`, newest first, counts in `credit-held` the bytes it has
;; not credited, and in `credit-most` the most it held at once: on a shell
;; made on credit (M6.2), it owes credit for them.  And a producer (M6.3;
;; tests/producers.sls): `/stream` streams a MiB in 64 pieces of 16 KiB, the
;; k-th filled with the k-th letter from `a`, and `stream-calls` says how many
;; times the last one was called; `/rows` streams 4,000 rows of 100 bytes the
;; same way, `rows-calls` counting; `/refilled` the same rows, each handed
;; out in one bytevector, refilled at each call; `/rows-close` the same rows,
;; closing the connection's handle behind the core as its producer is called
;; the second time; `/mixed` streams four pieces, of 100 bytes and 5,000 in
;; turn; `/pieces` streams three texts; `/head-first` two, its
;; producer keeping in `head-first-seen`, at its first call, how many more
;; write requests chez-libuv holds than when the handler was called
;; (`head-first-requests`); and `/stream-raise` a piece, then raises.  And
;; where a handler is called, and handlers that wait (decision 0014; M7.1):
;; `/phase` answers the scheduler's phase it was called in and whether a
;; coroutine ran it; `/await` waits, its thunk parked in `parked` until the
;; suite wakes it, then answers what it was woken with, the phase and
;; whether a coroutine ran it; `/wait-plain` parks with no `awaiting`;
;; `/await-read` waits and reads the body, yielding before it keeps each
;; piece, and answers the pieces joined; `/await-held` waits and reads the
;; body, its first piece parked in `parked` until the suite wakes it; and
;; `/await-stream` waits and streams three texts, yielding before each; and
;; `/read-phase` reads the body with an ordinary reader, and answers whether
;; a coroutine ran any of its pieces; and `/counted` counts its calls in
;; `counted-calls`.  And handlers that wait with the verbs (decision 0015;
;; M7.2): `/await-wake` waits on `await`, keeping its resume in `waker`,
;; and answers what it was given; `/wake` calls `waker` twice, with
;; "woken by another" and then "again", and answers "woke"; `/sleep` holds
;; the loop 30 ms, then sleeps 20 ms, and answers how many microseconds of
;; the monotonic clock it slept, read with no update of the loop's own,
;; which the sleep must make itself;
;; `/deadline` sleeps a minute inside a deadline of 10 ms, and answers
;; "passed" when the deadline's raise comes, or "slept"; `/resolve` resolves
;; "localhost" and answers the addresses, a space between each;
;; `/resolve-empty` resolves "", `/resolve-nul` a name with a NUL in it,
;; `/resolve-long` one of 300 characters, and `/resolve-unknown` "a..b",
;; whose empty label the resolver refuses without asking a server, each
;; answering the reason it raised with.
(define big-size (* 4 1024 1024))
(define big-body #f)
(define wide-size (* 1024 1024))
(define slow-ms 300)
(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))
;; hold! : Nat -> Void — keep the loop's thread busy `ms`.
(define (hold! ms)
  (let ((until (+ (monotonic-ms) ms)))
    (let spin () (when (< (monotonic-ms) until) (spin)))))
(define parked #f)
(define waker #f)
;; spaced : (Listof String) -> String — the strings, a space between each.
(define (spaced strings)
  (if (null? strings)
      ""
      (fold-left (lambda (acc x) (string-append acc " " x)) (car strings) (cdr strings))))

;; reason-for : String -> String — the reason `resolve` raised with for
;; `host`, or "resolved".
(define (reason-for host)
  (guard (e ((resolve-error? e) (symbol->string (resolve-error-reason e))))
    (resolve host)
    "resolved"))

;; looked-up : String -> (U (Listof String) 'failed)
;; What uv-getaddrinfo! itself answers for `host`, stream sockets alone,
;; the suite's loop run until it has.
(define (looked-up host)
  (let ((answer #f))
    (uv-getaddrinfo! loop host #f '((socktype . stream))
                     (lambda (err results)
                       (set! answer (if err 'failed (map uv-addrinfo-address results)))))
    (wait-for (lambda () answer))
    answer))

;; monotonic-us : -> Nat — the monotonic clock, in microseconds.
(define (monotonic-us)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000 (time-second t)) (div (time-nanosecond t) 1000))))
(define counted-calls 0)
(define credit-pieces '())
(define credit-held 0)
(define credit-most 0)
(define stream-pieces 64)
(define stream-piece-size 16384)
(define stream-calls (lambda () 0))
(define rows 4000)
(define row-size 100)
(define rows-calls (lambda () 0))
;; /mixed's pieces: a write of 5,000 bytes or more goes out alone, after the
;; smaller ones held before it.
(define mixed-pieces
  (list (make-string 100 #\a) (make-string 5000 #\b) (make-string 100 #\c) (make-string 5000 #\d)))
(define head-first-requests 0)
(define head-first-seen 'not-called)
(define (handler req)
  (let ((target (span->bytevector (request-target req))))
    (when (bytevector=? target (b "/slow"))
      (hold! slow-ms))
    (cond ((bytevector=? target (b "/big"))
           (let ((body (make-bytevector big-size 120)))
             (set! big-body (weak-cons body '()))
             (make-response 200 #f (list (cons (b "Connection") (b "close"))) body)))
          ((bytevector=? target (b "/wide"))
           (make-response 200 #f '() (make-bytevector wide-size 120)))
          ((bytevector=? target (b "/raise"))
           (raise (make-message-condition "the handler failed")))
          ((bytevector=? target (b "/await"))
           (awaiting
            (lambda ()
              (set! parked (current-coroutine))
              (let ((v (coroutine-park!)))
                (make-response 200 #f '()
                               (string->utf8 (string-append (symbol->string v) " "
                                                            (symbol->string (scheduler-phase))
                                                            (if (current-coroutine) " coroutine" " none"))))))))
          ((bytevector=? target (b "/await-wake"))
           (awaiting
            (lambda ()
              (make-response 200 #f '() (await (lambda (resume) (set! waker resume)))))))
          ((bytevector=? target (b "/sleep"))
           (awaiting
            (lambda ()
              (hold! 30)
              (let ((before (monotonic-us)))
                (sleep-ms 20)
                (make-response 200 #f '() (string->utf8 (number->string (- (monotonic-us) before))))))))
          ((bytevector=? target (b "/deadline"))
           (awaiting
            (lambda ()
              (make-response 200 #f '()
                             (string->utf8
                              (guard (e ((deadline-passed? e) "passed"))
                                (with-deadline 10 (lambda () (sleep-ms 60000) "slept"))))))))
          ((bytevector=? target (b "/resolve"))
           (awaiting
            (lambda ()
              (make-response 200 #f '() (string->utf8 (spaced (resolve "localhost")))))))
          ((bytevector=? target (b "/resolve-empty"))
           (awaiting (lambda () (make-response 200 #f '() (string->utf8 (reason-for ""))))))
          ((bytevector=? target (b "/resolve-nul"))
           (awaiting (lambda () (make-response 200 #f '() (string->utf8 (reason-for (string #\a #\nul #\b)))))))
          ((bytevector=? target (b "/resolve-long"))
           (awaiting (lambda () (make-response 200 #f '() (string->utf8 (reason-for (make-string 300 #\a)))))))
          ((bytevector=? target (b "/resolve-unknown"))
           (awaiting (lambda () (make-response 200 #f '() (string->utf8 (reason-for "a..b"))))))
          ((bytevector=? target (b "/wake"))
           (waker (b "woken by another"))
           (waker (b "again"))
           (make-response 200 #f '() (b "woke")))
          ((bytevector=? target (b "/wait-plain"))
           (coroutine-park!)
           (make-response 200 #f '() target))
          ((bytevector=? target (b "/await-read"))
           (awaiting
            (lambda ()
              (let ((pieces '()))
                (read-body (lambda (bv start end)
                             (coroutine-yield!)
                             (set! pieces (cons (bytes-between bv start end) pieces)))
                           (lambda ()
                             (make-response 200 #f '()
                                            (string->utf8 (apply string-append
                                                                 (map utf8->string (reverse pieces)))))))))))
          ((bytevector=? target (b "/await-held"))
           (awaiting
            (lambda ()
              (let ((first? #t))
                (read-body (lambda (bv start end)
                             (when first?
                               (set! first? #f)
                               (set! parked (current-coroutine))
                               (coroutine-park!)))
                           (lambda () (make-response 200 #f '() target)))))))
          ((bytevector=? target (b "/await-stream"))
           (awaiting
            (lambda ()
              (let ((p (producer-of '("one " "two " "three"))))
                (make-response 200 #f '() (lambda () (coroutine-yield!) (p)))))))
          ((bytevector=? target (b "/counted"))
           (set! counted-calls (+ counted-calls 1))
           (make-response 200 #f '() target))
          ((bytevector=? target (b "/read-phase"))
           (let ((seen 'none))
             (read-body (lambda (bv start end) (when (current-coroutine) (set! seen 'coroutine)))
                        (lambda () (make-response 200 #f '() (string->utf8 (symbol->string seen)))))))
          ((bytevector=? target (b "/phase"))
           (make-response 200 #f '()
                          (string->utf8 (string-append (symbol->string (scheduler-phase))
                                                       (if (current-coroutine) " coroutine" " none")))))
          ((bytevector=? target (b "/echo"))
           (read-whole-body (lambda (body) (make-response 200 #f '() body))))
          ((bytevector=? target (b "/early")) (make-response 200 #f '() target))
          ((bytevector=? target (b "/small"))
           (read-whole-body (lambda (body) (make-response 200 #f '() body)) 4))
          ((bytevector=? target (b "/credit"))
           (read-body (lambda (bv start end)
                        (set! credit-pieces (cons (bytes-between bv start end) credit-pieces))
                        (set! credit-held (+ credit-held (- end start)))
                        (set! credit-most (max credit-most credit-held)))
                      (lambda () (make-response 200 #f '() target))))
          ((bytevector=? target (b "/stream"))
           (let-values (((p calls) (counted (sized-producer stream-pieces stream-piece-size))))
             (set! stream-calls calls)
             (make-response 200 #f '() p)))
          ((bytevector=? target (b "/rows"))
           (let-values (((p calls) (counted (sized-producer rows row-size))))
             (set! rows-calls calls)
             (make-response 200 #f '() p)))
          ((bytevector=? target (b "/refilled"))
           (make-response 200 #f '() (refilled-producer rows row-size)))
          ((bytevector=? target (b "/rows-close"))
           (let ((p (sized-producer rows row-size)) (calls 0))
             (make-response 200 #f '()
                            (lambda ()
                              (set! calls (+ calls 1))
                              (when (= calls 2) (connection-close! (newest)))
                              (p)))))
          ((bytevector=? target (b "/head-first"))
           (set! head-first-requests (live-count 'write-req))
           (set! head-first-seen 'not-called)
           (let ((p (producer-of '("one " "two"))))
             (make-response 200 #f '()
                            (lambda ()
                              (when (eq? head-first-seen 'not-called)
                                (set! head-first-seen (- (live-count 'write-req) head-first-requests)))
                              (p)))))
          ((bytevector=? target (b "/pieces"))
           (make-response 200 #f '() (producer-of '("one " "two " "three"))))
          ((bytevector=? target (b "/mixed"))
           (make-response 200 #f '() (producer-of mixed-pieces)))
          ((bytevector=? target (b "/stream-raise"))
           (make-response 200 #f '()
                          (producer-of '("one piece")
                                       (lambda () (raise (make-message-condition "the producer failed"))))))
          ((eq? (request-method req) 'POST)
           (read-body (lambda (bv start end) #t) (lambda () (make-response 200 #f '() target))))
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

;; joined : (Listof Bytevector) -> Bytevector — the bytevectors end to end.
(define (joined bvs)
  (let ((out (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 bvs))))
    (fold-left (lambda (at bv)
                 (bytevector-copy! bv 0 out at (bytevector-length bv))
                 (+ at (bytevector-length bv)))
               0 bvs)
    out))

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
;; Each step a turn of the loop's scheduler, which calls the handlers asked
;; for since the last (decision 0014), and runs the loop once.
(define (wait-for pred) (run-loop-until loop pred cap))

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

;; Short limits, so the suite waits for its deadlines briefly: under a third
;; of a second for a body, a head, a write, an idle connection and a linger,
;; each its own, so a deadline armed for the wrong kind shows, and a tick of
;; 10 ms.  Loopback moves a client's bytes in a few milliseconds, so no
;; deadline passes before the client has made its move.
(define quick-limits
  (limits-with default-limits
               '((body-inactivity-timeout-ms . 175) (read-header-timeout-ms . 200)
                 (write-timeout-ms . 225) (idle-timeout-ms . 250) (linger-timeout-ms . 300)
                 (tick-ms . 10))))

;; open-adopted! : (U #f Bytevector) [Boolean] -> (Pair Client (U Connection #f))
;; A client that connects to the suite's listener, sends `request` unless it
;; is #f, and reads unless told not to; and the connection it was adopted
;; as, once it is.
(define open-adopted!
  (case-lambda
    ((request) (open-adopted! request #t))
    ((request read?)
     (let* ((before (newest)) (cl (open-client! request read?)))
       (wait-for (lambda () (and (adopted-since before) #t)))
       (cons cl (adopted-since before))))))

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

;; arms : Connection Symbol -> Nat — how many times `c` had a deadline of
;; `kind` armed.
(define (arms c kind)
  (length (filter (lambda (e) (and (eq? (car e) 'arm) (eq? (cadr e) c) (eq? (caddr e) kind)))
                  timed)))

;; last-armed : Connection Symbol -> (U Nat #f) — the loop's time `c` last
;; had a deadline of `kind` armed at, or #f if it never had one.
(define (last-armed c kind)
  (let ((e (find (lambda (e) (and (eq? (car e) 'arm) (eq? (cadr e) c) (eq? (caddr e) kind)))
                 timed)))
    (and e (cadddr e))))

;; last-written : Connection -> (U Nat #f) — the loop's time `c` last began
;; a write at, or #f if it never wrote.
(define (last-written c)
  (let ((e (find (lambda (e) (and (eq? (car e) 'write) (eq? (cadr e) c))) timed)))
    (and e (caddr e))))

;; slowhttptest's slow headers and slow body send a request a piece at a
;; time, each piece `gap-ms` after the last, well within every limit above.
(define gap-ms 60)

;; open-trickling! : Bytevector (Listof Bytevector)
;;                   -> (Pair (Pair Client (U Connection #f)) (-> (U Nat #f)))
;; A client adopted as it sends `first`, which then sends each of `pieces`
;; in turn, one every `gap-ms`, from a timer of its own on the loop, closed
;; after the last; and a procedure that answers the loop's time it sent its
;; last piece at, or #f until it has.
(define (open-trickling! first pieces)
  (let* ((p (open-adopted! first))
         (left pieces)
         (last-sent #f)
         (timer (make-uv-timer loop)))
    (uv-timer-start! timer
                     (lambda (t)
                       (client-send! (car p) (car left))
                       (set! left (cdr left))
                       (when (null? left)
                         (set! last-sent (uv-now loop))
                         (uv-close! t)))
                     gap-ms gap-ms)
    (cons p (lambda () last-sent))))

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

    ;; Where a handler is called (decision 0014): from the scheduler's drain,
    ;; after libuv's turn, on no coroutine, its phase 'scheduling, never a
    ;; callback's 'in-uv-run.
    (let ((cl (open-client! (b "GET /phase HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads the response of a handler that names where it was called" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "a handler is called after libuv's turn, from the scheduler's drain, on no coroutine"
                  '("scheduling none")
                  (map body (responses (client-bytes cl))))
      (client-close! cl))

    ;; A connection closed between the turn that asked for its handler and
    ;; the drain that would call it: the handler is not called, as a
    ;; waiting connection's calls are not made once it is closing.  The
    ;; trace closes it as the core's `call-handler` runs, in the read's drain.
    (set! counted-calls 0)
    (set! closing-on 'call-handler)
    (let ((cl (open-client! (b "GET /counted HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a handler whose connection closed before the drain reached its call is not called: its client reads the stream's end and nothing else"
                  '(satisfied 0 0)
                  (list (wait-for (lambda () (not (eq? (client-end cl) 'open))))
                        (collector-count (client-collector cl))
                        counted-calls))
      (set! closing-on #f)
      (client-close! cl))

    ;; The loop's scheduler is kept for the loop, in an ephemeron table: a
    ;; loop let go, with its shell, is collected, though the scheduler's poll
    ;; holds the loop.
    (test-eq "a loop let go with its shell is collected, its scheduler with it" #t
             (let ((w (let* ((l (make-uv-loop))
                             (sh (make-shell l handler default-limits clock log! trace!)))
                        (uv-loop-teardown! l)
                        (weak-cons l '()))))
               (collect (collect-maximum-generation))
               (collect (collect-maximum-generation))
               (bwp-object? (car w))))

    ;; A handler that waits (decision 0014): its thunk parks on a coroutine,
    ;; and nothing is answered until the suite wakes it.
    (set! parked #f)
    (let ((cl (open-client! (b "GET /await HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a handler that waits answers awaiting: its thunk parks on a coroutine, and nothing is answered while it waits"
                  '(satisfied 0 handling)
                  (let ((waited (wait-for (lambda () (and parked #t)))))
                    (run-loop-until loop (lambda () #f) 20)
                    (list waited (collector-count (client-collector cl))
                          (let ((c (newest))) (if (connection? c) (phase c) 'no-connection)))))
      (when parked (coroutine-wake! parked 'woken))
      (test-eq "once woken, its answer is written" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "the thunk's answer, resumed in the drain, on its coroutine"
                  '((200 "woken scheduling coroutine"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
      (client-send! cl (b "POST /read-phase HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
      (test-equal "the next request on the connection, its handler ordinary, has its reader called in place"
                  '(satisfied "none")
                  (list (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (let ((rs (responses (client-bytes cl))))
                          (if (= 2 (length rs)) (body (cadr rs)) 'no-response))))
      (client-close! cl))
    ;; One request wakes another (decision 0015 item 1): `/await-wake` waits
    ;; on `await`, and `/wake`, an ordinary handler on a connection of its
    ;; own, calls its resume twice; the second is R4's, logged.
    (set! waker #f)
    (set! logged '())
    (let ((waiting (open-client! (b "GET /await-wake HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a handler that waits on await parks, and nothing is answered while it waits"
                  '(satisfied 0)
                  (let ((waited (wait-for (lambda () (and waker #t)))))
                    (run-loop-until loop (lambda () #f) 20)
                    (list waited (collector-count (client-collector waiting)))))
      (let ((waking (open-client! (b "GET /wake HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "another request's handler wakes it: both are answered, and the second resume is logged as late-resume"
                    '(satisfied ((200 "woken by another")) ((200 "woke")) ((late-resume await)))
                    (list (wait-for (lambda () (and (= 1 (length (responses (client-bytes waiting))))
                                                    (= 1 (length (responses (client-bytes waking)))))))
                          (map (lambda (r) (list (status r) (body r))) (responses (client-bytes waiting)))
                          (map (lambda (r) (list (status r) (body r))) (responses (client-bytes waking)))
                          (filter (lambda (e) (eq? (car e) 'late-resume)) logged)))
        (client-close! waking))
      (client-close! waiting))
    ;; The timed waits (decision 0015 item 3): the loop's waits have their
    ;; own timer, and nothing is left armed once each wait is over.  A sleep
    ;; of 20 ms is armed on the loop's clock, which counts whole
    ;; milliseconds and may trail the monotonic clock by one: by that clock
    ;; it lasts 18 ms at least.  Armed on the loop's clock as the hold left
    ;; it, 30 ms behind, it would end at once.
    (let ((cl (open-client! (b "GET /sleep HTTP/1.1\r\nHost: x\r\n\r\nGET /deadline HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 18 ms or more by the monotonic clock; one whose deadline of 10 ms ends a sleep of a minute is answered passed; nothing is left armed"
                  '(satisfied (200 at-least-18-ms) (200 "passed") 0)
                  (list (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (let ((rs (responses (client-bytes cl))))
                          (if (pair? rs)
                              (let ((n (string->number (body (car rs)))))
                                (list (status (car rs)) (if (and n (>= n 18000)) 'at-least-18-ms n)))
                              'no-response))
                        (let ((rs (responses (client-bytes cl))))
                          (if (= 2 (length rs)) (list (status (cadr rs)) (body (cadr rs))) 'no-response))
                        (shell-waits-timed shell)))
      (client-close! cl))
    (set! logged '())
    (let ((cl (open-client! (b "GET /wait-plain HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of an ordinary handler that waits reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after a 500, the refusal logged as R2's, a wait on no coroutine"
                  '((500) handler-failed r2)
                  (list (map status (responses (client-bytes cl)))
                        (first-logged)
                        (let ((e (assq 'handler-failed logged)))
                          (if (and e (pair? (cdr e)) (scheduler-invariant? (cadr e)))
                              (scheduler-invariant-name (cadr e))
                              'no-refusal))))
      (client-close! cl))
    (let ((cl (open-client! (b (string-append "POST /await-read HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                              "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n")))))
      (test-eq "the client of a handler that waits and reads a body reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "its reader takes each piece on a coroutine, in order, yielding before it keeps one"
                  '((200 "hello world"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
      (client-close! cl))
    (set! parked #f)
    (let ((cl (open-client! (b "POST /await-held HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello"))))
      (test-equal "its reader waits on a piece, and reading waits for it: the connection awaits its credit"
                  '(satisfied awaiting-credit)
                  (let ((waited (wait-for (lambda () (and parked #t)))))
                    (client-send! cl (b " world"))
                    (run-loop-until loop (lambda () #f) 20)
                    (list waited (let ((c (newest))) (if (connection? c) (phase c) 'no-connection)))))
      (when parked (coroutine-wake! parked 'go))
      (test-eq "once it has taken the piece, the rest is read, and the response follows" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "the reader's response" '((200 "/await-held"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
      (client-close! cl))
    (let ((cl (open-client! (b "GET /await-stream HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a handler that waits and streams reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "its producer is called on a coroutine for each piece, yielding before each: the pieces in order"
                  '((200 "one two three"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
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

    ;; Bodies (M6.1, decision 0013), over loopback: read whole, chunked or
    ;; not, and echoed, on a connection kept for the request behind; answered
    ;; before the body is read, and closed after; past a reader's cap, 413.
    (let ((cl (open-client! (b (string-append "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\n"
                                              "hello world"
                                              "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                              "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")))))
      (test-eq "a client reads two whole responses to two POSTs" 'satisfied
               (wait-for (lambda () (= 2 (length (responses (client-bytes cl)))))))
      (test-equal "each POST's body read whole and echoed, chunked or not, on the one connection"
                  '((200 "hello world") (200 "hello world"))
                  (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl))))
      (client-close! cl))
    (let ((cl (open-client! (b "POST /early HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"))))
      (test-eq "the client of a handler that answers before reading the body reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after a 200 that says Connection: close"
                  '((200 "/early" "close"))
                  (map (lambda (r) (list (status r) (body r) (field r "Connection")))
                       (responses (client-bytes cl))))
      (client-close! cl))
    (let ((cl (open-client! (b "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"))))
      (test-eq "the client of a reader capped below the body reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after a 413" '(413) (map status (responses (client-bytes cl))))
      (client-close! cl))

    ;; Expect: 100-continue (M6.4), over loopback.  The client sends the head
    ;; alone and waits for the 100 before it sends its body, as curl does
    ;; for a large upload: the 100 is a write of its own, and nothing else
    ;; comes before the body is sent.  The response then answers the body
    ;; sent after it.
    (let* ((cl (open-client! (b "POST /expect HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")))
           (got-100 (wait-for (lambda () (>= (bytevector-length (client-bytes cl)) 25))))
           (before-body (utf8->string (client-bytes cl))))
      (client-send! cl (b "hello"))
      (let ((answered (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))))
        (test-equal "a client that waits for the 100 reads it, alone, before it sends its body"
                    '(satisfied "HTTP/1.1 100 Continue\r\n\r\n")
                    (list got-100 before-body))
        (test-equal "then the response to the body it sent after it, on the connection kept"
                    '(satisfied ((100 "") (200 "/expect")) absent)
                    (list answered
                          (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))
                          (field (cadr (responses (client-bytes cl))) "Connection"))))
      (client-close! cl))
    ;; A handler that answers at once gets no 100 before its response, and
    ;; the client, told the connection closes, never sends its body.
    (let ((cl (open-client! (b "POST /early HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"))))
      (test-eq "the client of a handler that answers an Expect head at once reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "after a 200 that says Connection: close, and no 100"
                  '((200 "/early" "close"))
                  (map (lambda (r) (list (status r) (body r) (field r "Connection")))
                       (responses (client-bytes cl))))
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

    ;; A streamed response (M6.3, decision 0013 item 8): a MiB in 64 pieces
    ;; of 16 KiB to a client that reads nothing yet, the connection's send
    ;; buffer small, as the slow reader's is, so the kernel holds far less
    ;; than the MiB.  The producer is asked only at or below decision 0005's
    ;; high water, 262,144 bytes outstanding, so the bytes outstanding never
    ;; pass it by more than one piece's write, 16,392 bytes: the size line
    ;; `4000` CRLF, the piece, CRLF.  That is the slow reader's memory bound
    ;; (plan §14: with the high water ignored, the first turn asks for the
    ;; whole MiB).  The first turn asks sixteen times, 262,356 bytes with the
    ;; head.  The request says Connection: close, so the client knows it has
    ;; the whole response at the stream's end.
    (set! small-send-buffer 4096)
    (set! stream-most 0)
    (set! watching-stream #t)
    (let* ((before (newest))
           (requests (live-count 'write-req))
           (cl (open-client! (b "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") #f)))
      (test-eq "a client that reads nothing yet asks for a MiB streamed" 'satisfied
               (wait-for (lambda () (>= (stream-calls) 16))))
      (set! small-send-buffer #f)
      ;; Some turns of the loop, for the kernel to take what it will.
      (run-loop-until loop (lambda () #f) 200)
      (let ((c (adopted-since before)))
        (test-equal "while it reads nothing, its writes wait, the bytes outstanding never past the high water by more than a piece's write"
                    '(outstanding #t)
                    (list (if (and c (> (uv-stream-write-queue-size (connection-tcp c)) 0)) 'outstanding 'completed)
                          (<= stream-most (+ 262144 16392))))
        ;; A write of 4,096 bytes or more is never held (write batching):
        ;; each piece's write is a write request of chez-libuv's, which copies
        ;; its bytes at the call, the only copy made of them.  Its dev build
        ;; counts them, and a prod shim answers zero.
        (if (= (live-count 'loop) 1)
            (test-equal "and each of the core's writes outstanding is a write request of chez-libuv's: a piece of 16 KiB is not held"
                        '(many #t)
                        (let ((n (and c (conn-outstanding (connection-state c)))))
                          (list (if (and n (> n 1)) 'many n)
                                (and n (= n (- (live-count 'write-req) requests))))))
            (display "shell: chez-libuv's counters are off in this build; the write requests not read\n")))
      (client-read! cl)
      (test-eq "the client then reads the whole response, and the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (set! watching-stream #f)
      (test-equal "a 200, chunked, whose body is the MiB, every piece in order, the bound kept as it read"
                  (list 200 "chunked" (sized-body stream-pieces stream-piece-size) 'complete 65 #t)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4)
                          (stream-calls) (<= stream-most (+ 262144 16392)))))
      (client-close! cl))
    ;; Rows of 100 bytes, each a write of the core's (M6.3's second review):
    ;; the producer is also asked only while fewer than 64 writes are
    ;; outstanding, where the bytes alone would let the first turn ask for
    ;; some 2,500 rows, 262,144 bytes at 106 a row.  The first turn asks 63
    ;; times; the client reads nothing yet, its send buffer small.  The shell
    ;; holds the small writes a turn makes and sends them as one libuv write
    ;; (write batching), so the core's writes outstanding, 48 or 64 of them
    ;; while the client reads nothing, are one write request of chez-libuv's:
    ;; its dev build counts them, and a prod shim answers zero.
    (set! small-send-buffer 4096)
    (set! stream-most-writes 0)
    (set! watching-stream #t)
    (let* ((before (newest))
           (requests (live-count 'write-req))
           (cl (open-client! (b "GET /rows HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") #f)))
      (test-eq "a client that reads nothing yet asks for 4,000 rows of 100 bytes streamed" 'satisfied
               (wait-for (lambda () (>= (rows-calls) 63))))
      (set! small-send-buffer #f)
      ;; Some turns of the loop, for the kernel to take what it will.
      (run-loop-until loop (lambda () #f) 200)
      (let ((c (adopted-since before)))
        (test-equal "while it reads nothing, its writes wait, never more than 64 of them outstanding"
                    '(outstanding #t)
                    (list (if (and c (> (uv-stream-write-queue-size (connection-tcp c)) 0)) 'outstanding 'completed)
                          (<= stream-most-writes 64)))
        (if (= (live-count 'loop) 1)
            (test-equal "and the core's writes outstanding are one write request of chez-libuv's: a turn's small writes go out as one"
                        '(many 1)
                        (list (if (and c (> (conn-outstanding (connection-state c)) 1))
                                  'many
                                  (and c (conn-outstanding (connection-state c))))
                              (- (live-count 'write-req) requests)))
            (display "shell: chez-libuv's counters are off in this build; the write requests not read\n")))
      (client-read! cl)
      (test-eq "the client then reads the rows, and the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (set! watching-stream #f)
      (test-equal "a 200, chunked, every row in order, never more than 64 writes outstanding as it read"
                  (list 200 "chunked" (sized-body rows row-size) 'complete (+ rows 1) #t)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4)
                          (rows-calls) (<= stream-most-writes 64))))
      (client-close! cl))
    ;; The rows handed out in one bytevector, refilled at each call, as
    ;; handlers.org lets a producer do.  A write the shell holds for the
    ;; turn's one libuv write is copied as it is handed over, so each row goes
    ;; out as it was then, not as the bytevector is once the turn's write is
    ;; issued.  The client reads as the rows come, so turns run whole.
    (let ((cl (open-client! (b "GET /refilled HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))))
      (test-eq "a client reads rows streamed from one bytevector refilled at each call, and the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "a 200, chunked, each row as it was when handed over, in order"
                  (list 200 "chunked" (sized-body rows row-size) 'complete)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4))))
      (client-close! cl))
    ;; Pieces of 100 bytes and 5,000 in turn: the larger write goes out alone,
    ;; but only after the smaller one held before it, so the pieces keep
    ;; their order.
    (let ((cl (open-client! (b "GET /mixed HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))))
      (test-eq "a client reads pieces of 100 bytes and 5,000 in turn, and the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "a 200, chunked, the pieces in the order handed over"
                  (list 200 "chunked" (apply string-append mixed-pieces) 'complete)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4))))
      (client-close! cl))
    ;; Rows whose client goes while they are outstanding: the turn's one
    ;; libuv write fails, at its completion or as the close cancels it, and
    ;; the connection closes as a read error (design §6.3).  Each row's write
    ;; is settled after, so the core counts none outstanding.
    (set! small-send-buffer 4096)
    (let* ((before (newest))
           (cl (open-client! (b "GET /rows HTTP/1.1\r\nHost: x\r\n\r\n") #f)))
      (test-eq "a client that will not read asks for rows streamed" 'satisfied
               (wait-for (lambda () (let ((c (adopted-since before)))
                                      (and c (> (uv-stream-write-queue-size (connection-tcp c)) 0))))))
      (set! small-send-buffer #f)
      (let ((c (adopted-since before)))
        (client-close! cl)
        (test-eq "rows whose client goes while they are outstanding close the connection" 'satisfied
                 (wait-for (lambda () (closed-and-gone? shell c))))
        (test-equal "as a read error, then each row's write settled, none left outstanding"
                    '(read-error-then-settled 0 0)
                    (list (if (and c (in-order? '(read-error write-completed) (events c)))
                              'read-error-then-settled
                              (and c (events c)))
                          (and c (conn-outstanding (connection-state c)))
                          (and c (conn-outstanding-bytes (connection-state c)))))))
    ;; A turn's one write refused at the call: the connection's handle is
    ;; closed behind the core as the producer is called the second time, so
    ;; the rows the turn goes on writing are held, and the write that carries
    ;; them is refused (chez-libuv's &uv-handle-closed).  A read error, then
    ;; each row's write settled, none left outstanding.
    (let* ((before (newest))
           (cl (open-client! (b "GET /rows-close HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "rows whose handle is closed behind the core mid-turn close the connection" 'satisfied
               (wait-for (lambda () (let ((c (adopted-since before))) (and c (closed-and-gone? shell c))))))
      (let ((c (adopted-since before)))
        (test-equal "a read error, then each row's write settled, the turn's write refused at the call; none left outstanding"
                    '(read-error-then-settled 0 0)
                    (list (if (and c (in-order? '(read-error write-completed) (events c)))
                              'read-error-then-settled
                              (and c (events c)))
                          (and c (conn-outstanding (connection-state c)))
                          (and c (conn-outstanding-bytes (connection-state c))))))
      (client-close! cl))
    ;; To HTTP/1.0 the pieces are close-delimited, and the connection closes
    ;; after them (RFC 9112 §6.3 rule 8), though this client asked to keep it
    ;; (M3.2's carried arm): the client has the body at the stream's end.
    (let ((cl (open-client! (b "GET /pieces HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"))))
      (test-eq "an HTTP/1.0 client of a streamed response reads the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "a 200 with Connection: close and no framing field, the body read whole at the close"
                  '(200 "close" absent absent "one two three" complete)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Connection") (field r "Transfer-Encoding")
                          (field r "Content-Length") (body r) (list-ref r 4))))
      (client-close! cl))
    ;; A chunked stream keeps the connection: the GET behind it is answered.
    (let ((cl (open-client! (b "GET /pieces HTTP/1.1\r\nHost: x\r\n\r\nGET /after HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads a streamed response and the one behind it" 'satisfied
               (wait-for (lambda () (= 2 (length (responses (client-bytes cl)))))))
      (test-equal "on one connection: the stream's body, then the GET's"
                  '((200 "chunked" "one two three") (200 absent "/after"))
                  (map (lambda (r) (list (status r) (field r "Transfer-Encoding") (body r)))
                       (responses (client-bytes cl))))
      (client-close! cl))
    ;; A stream's head goes out before its producer is first called (write
    ;; batching): a producer slow to make its pieces delays them a turn at a
    ;; time, not the head.  So the producer's first call finds one write
    ;; request more held by chez-libuv than the handler did, the head's.  The
    ;; stream is behind another on one connection, so the head goes out first
    ;; in each drain that calls a producer, not only the connection's first.
    ;; chez-libuv's dev build counts the requests; a prod shim answers zero.
    (let ((cl (open-client! (b "GET /pieces HTTP/1.1\r\nHost: x\r\n\r\nGET /head-first HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads a stream, and another behind it on one connection" 'satisfied
               (wait-for (lambda () (= 2 (length (responses (client-bytes cl)))))))
      (if (= (live-count 'loop) 1)
          (test-equal "the second stream's head went out before its producer was first called, one write request"
                      '(1 "one two")
                      (list head-first-seen
                            (let ((rs (responses (client-bytes cl))))
                              (if (= 2 (length rs)) (body (cadr rs)) 'no-second-response))))
          (display "shell: chez-libuv's counters are off in this build; the write requests not read\n"))
      (client-close! cl))
    ;; A producer that raises once the head is on the wire: no status can be
    ;; written, so the connection closes at once, with no half-close, and
    ;; the client reads a chunked body cut short, with no last chunk.
    (set! logged '())
    (let ((cl (open-client! (b "GET /stream-raise HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a producer that raises after a piece reads the stream's end" 'satisfied
               (wait-for (lambda () (not (eq? (client-end cl) 'open)))))
      (test-equal "after the head and the piece: the body cut short, no status written"
                  '(200 "chunked" "one piece" need-input eof)
                  (let ((r (read-response (client-bytes cl) #f #f)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4) (client-end cl))))
      (test-equal "and the shell logged what the producer raised" '(handler-failed "the producer failed")
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
    ;; A bug once a write is held: what is held is dropped with the rest of
    ;; the dispatch (write batching), so the head the core wrote is never
    ;; sent, and the close is the connection's last event, none of the held
    ;; write's after it.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /pieces HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (trap! 'action 'notify-producer)
      (test-eq "when a connection's callback raises once a write is held, its client reads the stream's end" 'satisfied
               (run-shell shell (lambda () (eq? (client-end cl) 'eof))))
      (let ((c (adopted-since before)))
        (test-equal "with nothing written, the connection closed and gone, the error logged, the close its last event"
                    '(0 #t callback-error closed)
                    (list (collector-count (client-collector cl)) (closed-and-gone? shell c)
                          (first-logged)
                          (and c (pair? (events c)) (car (reverse (events c)))))))
      (client-close! cl))

    ;; A bug once the handler has answered, in the drain after libuv's turn
    ;; (decision 0014): the dispatch of its answer raises, and the connection
    ;; is closed as a callback's raise closes it, the raise logged as a
    ;; callback's, and the run loop runs on.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /trap HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (trap! 'event 'handler-responded)
      (test-eq "when the dispatch of a handler's answer raises, its client reads the stream's end" 'satisfied
               (run-shell shell (lambda () (eq? (client-end cl) 'eof))))
      (let ((c (adopted-since before)))
        (test-equal "with no response, the connection closed and gone, the raise logged as a callback's"
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
             ;; slowhttptest's shapes: slow headers, slow body, slow read.
             (loris (open-trickling! (b "GET /loris HTTP/1.1\r\n")
                                     (map b '("Host: x\r\n" "X-1: 1\r\n" "X-2: 2\r\n"
                                              "X-3: 3\r\n" "X-4: 4\r\n"))))
             (rudy (open-trickling! (b "POST /rudy HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\nab")
                                    (map b '("cd" "ef" "gh"))))
             ;; A client that never reads.  The connection's send buffer is
             ;; made small as the listener accepts it, so what the kernel
             ;; holds of the answer is about the client's receive buffer: on
             ;; loopback, 408,300 B on Darwin and 131,072 B on Linux, left
             ;; as they are, since Darwin grows one made small after the
             ;; connect (the M5 exit's spike, m5-exit-rcvbuf.sps).
             (reader (let ((p (begin (set! small-send-buffer 4096) (open-adopted! #f #f))))
                       (set! small-send-buffer #f)
                       (client-send! (car p) (b "GET /wide HTTP/1.1\r\nHost: x\r\n\r\n"))
                       p))
             (all (list half idle bye silent (car loris) (car rudy))))
        (test-eq "each of them closes once its deadlines pass" 'satisfied
                 (wait-for (lambda ()
                             (and (for-all (lambda (p)
                                             (and (closed-and-gone? quick (cdr p))
                                                  (not (eq? (client-end (car p)) 'open))))
                                           all)
                                  (closed-and-gone? quick (cdr reader))))))
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
        (test-equal "a client that sends its head a piece at a time reads 408 once the deadline armed as the head began passes, which its pieces never move: slowhttptest's slow headers"
                    '((408) eof ((header on-time) (linger on-time)) 1)
                    (append (deadline-outcome quick (car loris)) (list (arms (cdr (car loris)) 'header))))
        (test-equal "a client that sends its body a piece at a time, then stops, reads 408 once the deadline armed again at its last piece passes: slowhttptest's slow body"
                    '((408) eof ((body on-time) (linger on-time)) #t)
                    (append (deadline-outcome quick (car rudy))
                            (list (let ((armed (last-armed (cdr (car rudy)) 'body)) (sent ((cdr rudy))))
                                    (and armed sent (>= armed sent))))))
        ;; let*, since Chez evaluates a call's arguments in no fixed order.
        (test-equal "a client that never reads a MiB answer is closed once its write's deadline passes, sent less than the whole: slowhttptest's slow read"
                    '(((write on-time)) satisfied eof #t)
                    (let* ((passed (deadlines-passed quick (cdr reader)))
                           (reading (client-read! (car reader)))
                           (read (wait-for (lambda () (not (eq? (client-end (car reader)) 'open))))))
                      (list passed read (client-end (car reader))
                            (< (bytevector-length (client-bytes (car reader))) wide-size))))
        (test-equal "a MiB answer's write holds the loop less than a tick: the loop's time moves less than tick-ms from the write's start to the write deadline armed after it"
                    'under-a-tick
                    (let ((written (last-written (cdr reader))) (armed (last-armed (cdr reader) 'write)))
                      (cond ((not (and written armed)) (list written armed))
                            ((< (- armed written) (limits-tick-ms quick-limits)) 'under-a-tick)
                            (else (- armed written)))))
        (for-each (lambda (p) (client-close! (car p))) (cons reader all)))

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
                           (ran (run-loop-until loop (lambda () #f) 50)))
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

    ;; Backpressure on the read side (M6.2), on a shell of its own with the
    ;; short limits, made on credit, as M7's coroutine shell will hand a
    ;; reader its pieces.  A client sends a 64 KiB body at once to `/credit`:
    ;; handed a read's pieces, its reader makes reading wait for its credit,
    ;; so the connection has no deadline armed, and its shell's wheel is
    ;; empty.  The timer then stops, firing once more at
    ;; most, while the connection stays, and a wait past the body deadline's
    ;; 175 ms answers nothing: the server, not the client, is the one waiting
    ;; (plan §14's notes of 2026-09-27).  Credited each time it waits, the
    ;; reader is handed the rest a read at a time.  The body's bytes count up
    ;; modulo 251, so their order shows.
    (let* ((waiter (make-shell loop handler quick-limits clock log! trace! #t))
           (fired (lambda ()
                    (length (filter (lambda (e) (and (eq? (car e) 'fire) (eq? (cadr e) waiter)))
                                    timed))))
           (size 65536)
           (body (let ((bv (make-bytevector size)))
                   (do ((i 0 (+ i 1))) ((= i size) bv) (bytevector-u8-set! bv i (mod i 251)))))
           (read-buffer (limits-read-buffer-size quick-limits)))
      (set! adopting waiter)
      (set! credit-pieces '())
      (set! credit-held 0)
      (set! credit-most 0)
      (let* ((p (open-adopted! (joined (list (b (string-append "POST /credit HTTP/1.1\r\nHost: x\r\n"
                                                                "Content-Length: 65536\r\n\r\n"))
                                             body))))
             (c (cdr p))
             (answered? (lambda () (pair? (responses (client-bytes (car p))))))
             ;; let*, since Chez evaluates a call's arguments in no fixed order.
             (waiting (wait-for (lambda () (and (connection? c) (eq? (phase c) 'awaiting-credit)))))
             (before (fired))
             (from (uv-now loop))
             (waited (wait-for (lambda () (>= (uv-now loop) (+ from 250))))))
        (test-equal "a reader withholding its credit 250 ms, past the body deadline: reading stopped, no deadline armed, the timer stopped, firing once more at most, the connection kept, one read at most held, nothing answered"
                    '(satisfied satisfied awaiting-credit #f #t #t #t #f)
                    (list waiting waited (phase c) (connection-deadline c)
                          (<= (- (fired) before) 1)
                          (and (memq c (shell-connections waiter)) #t)
                          (<= 1 credit-held read-buffer)
                          (answered?)))
        ;; A credit the core refuses, an assertion violation of its own,
        ;; ends the credits as 'refused.
        (let* ((credits (let credit ((n 0) (given '()))
                          (wait-for (lambda () (or (eq? (phase c) 'awaiting-credit) (answered?))))
                          (if (and (eq? (phase c) 'awaiting-credit) (< n 1000))
                              (let ((k credit-held))
                                (set! credit-held 0)
                                (if (guard (e ((assertion-violation? e) #f))
                                      (connection-body-credit! c k)
                                      #t)
                                    (credit (+ n 1) (cons k given))
                                    (reverse (cons 'refused given))))
                              (reverse given))))
               (read (wait-for answered?)))
          (test-equal "credited each time it waits, the reader is handed the whole body in order, never more than one read held, and the response is written"
                      '(satisfied (200) #t #t #t)
                      (list read (map status (responses (client-bytes (car p))))
                            (bytevector=? body (joined (reverse credit-pieces)))
                            (<= credit-most read-buffer)
                            (for-all (lambda (k) (and (number? k) (<= 1 k read-buffer))) credits))))
        (client-close! (car p))
        (wait-for (lambda () (null? (shell-connections waiter)))))
      ;; A credit for more than the reader was handed is a bug, and a bug
      ;; closes its connection: the connection is closed, and the core's
      ;; assertion violation raised to the caller.
      (set! credit-held 0)
      (let* ((p (open-adopted! (joined (list (b (string-append "POST /credit HTTP/1.1\r\nHost: x\r\n"
                                                                "Content-Length: 100\r\n\r\n"))
                                             (make-bytevector 50 97)))))
             (c (cdr p))
             (waiting (wait-for (lambda () (and (connection? c) (eq? (phase c) 'awaiting-credit)))))
             (credited (guard (e ((assertion-violation? e) 'refused))
                         (connection-body-credit! c (+ credit-held 1))
                         'taken))
             (gone (wait-for (lambda () (closed-and-gone? waiter c)))))
        (test-equal "a credit for more than the reader was handed raises to the caller, and the connection is closed"
                    '(satisfied refused satisfied)
                    (list waiting credited gone))
        (client-close! (car p)))
      (shell-shutdown! waiter)
      (set! adopting shell))

    ;; A lookup (decision 0015 item 1), against what uv-getaddrinfo! itself
    ;; answers; names libuv refuses at the call, empty, with a NUL, or over
    ;; 255 octets; and one the resolver refuses itself, with a network or
    ;; without (measured on Darwin and on Linux in Docker, `--network none`
    ;; and not): EAI_NONAME.
    (let* ((oracle (looked-up "localhost"))
           (cl (open-client! (b (string-append "GET /resolve HTTP/1.1\r\nHost: x\r\n\r\n"
                                               "GET /resolve-empty HTTP/1.1\r\nHost: x\r\n\r\n"
                                               "GET /resolve-nul HTTP/1.1\r\nHost: x\r\n\r\n"
                                               "GET /resolve-long HTTP/1.1\r\nHost: x\r\n\r\n"
                                               "GET /resolve-unknown HTTP/1.1\r\nHost: x\r\n\r\n")))))
      (test-equal "a handler that resolves localhost is answered the addresses uv-getaddrinfo! gives; one that resolves a name libuv refuses at the call, empty, with a NUL or too long, invalid-name; one with an empty label, EAI_NONAME"
                  (list 'satisfied (list 200 (if (pair? oracle) (spaced oracle) oracle))
                        '(200 "invalid-name") '(200 "invalid-name") '(200 "invalid-name") '(200 "EAI_NONAME"))
                  (cons (wait-for (lambda () (= 5 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))

    ;; A shell that serves no more closes the timer of its loop's waits,
    ;; which have nothing armed (decision 0015 item 3): the next sleep on
    ;; the loop makes another.
    (let ((cl (open-client! (b "GET /sleep HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "after a shell on the loop serves no more, closing the timer of the loop's waits, a handler that sleeps is answered: the timer is made again"
                  '(satisfied 200)
                  (list (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))
                        (let ((rs (responses (client-bytes cl))))
                          (if (pair? rs) (status (car rs)) 'no-response))))
      (client-close! cl)
      (wait-for (lambda () (null? (shell-connections shell)))))

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
