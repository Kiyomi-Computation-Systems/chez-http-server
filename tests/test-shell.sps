#!r6rs
;;; (http-server private shell): the direct libuv shell, over loopback.
;;;
;;; The shell performs the core's actions with chez-libuv.  This suite is its
;;; socket lane: it serves clients on the same loop, bound to 127.0.0.1:0,
;;; each wait capped by an iteration count, never wall-clock, and asserts on
;;; bytes, states and the order of verbs, never on how the kernel split the
;;; stream.  Its clients are tests/shell-testing.sls's, which the contract
;;; test shares.  A response is read back by chez-httparse's strict response
;;; parser (tests/response-reader.sls), not by our own code.
;;;
;;; The checks, by area:
;;;   - requests: a GET is answered, its Date from the shell's clock, and the
;;;     connection stays open; three requests in one write are answered in
;;;     order, reading the clock fewer times than they are answered (once a
;;;     second), with no action but the parser's reply run at parser depth;
;;;     bodies, Expect: 100-continue, a handler that raises (500, logged);
;;;   - addresses: a request reads both ends of its connection, the same on
;;;     each request, from the one record the connection was adopted with; a
;;;     connection its client reset before adoption is served, its peer's
;;;     address and port #f; and over IPv6, on a listener of its own, which
;;;     a host with no IPv6 loopback fails, naming why;
;;;   - dispatch: a handler is called after libuv's turn, from the scheduler's
;;;     drain, on no coroutine, never inside a libuv callback, and not at all
;;;     once its connection has closed before the drain reaches the call; a
;;;     loop let go with its shell is collected;
;;;   - handlers that wait: an `awaiting` thunk parks on a coroutine and
;;;     nothing is answered until it is woken; its reader takes each piece,
;;;     and its producer is called, on a coroutine, in order; an ordinary
;;;     handler that waits fails, 500, the refusal logged; a client that
;;;     closes while its handler waits is told (`&client-closed`); the verbs
;;;     `await` (a second resume is logged as `late-resume`), `sleep-ms` and
;;;     `with-deadline` (timed by the loop's clock brought up to date, nothing
;;;     left armed after), and `resolve` (answers what uv-getaddrinfo! does);
;;;     an idle connection carries none of the coroutines they ran on;
;;;   - closing: a response that closes the connection is followed by the
;;;     half-close, and the connection lingers, reading and dropping, until
;;;     the client closes, so a client uploading four MiB past a refusal
;;;     sends it all and reads the status and the stream's end;
;;;   - streamed responses: a MiB, chunked, to a client that reads nothing
;;;     yet keeps the bytes outstanding within the limits' high water by at
;;;     most a piece's write, then is read whole and in order; rows of 100
;;;     bytes keep at most 64 writes outstanding, the shell sending a turn's
;;;     small writes as one write request of chez-libuv's; a stream's head is
;;;     sent before its producer is first called; a producer that raises
;;;     after a piece closes the connection with the body cut short, logged;
;;;     a sized body is sent with its Content-Length and the connection kept,
;;;     its producer on a coroutine for a handler that waits, and one whose
;;;     producer ends short, or gives a piece past its length, is closed
;;;     after the bytes written, logged;
;;;   - writes: one outstanding keeps nothing of its response (chez-libuv
;;;     copies the segments at the call); one that fails, at its completion or
;;;     when it is issued, closes the connection as a read error, and is
;;;     settled after;
;;;   - faults: the run loop raises again a byte-machine contract condition
;;;     that a callback raised, even when the log raises, and runs on after
;;;     any other; a connection whose callback raises, whose adoption fails,
;;;     or whose handler's answer raises as it is dispatched is closed, with
;;;     no deadline left armed; a connection whose handle closed behind the
;;;     shell is dropped from the wheel;
;;;   - the server's own listener: serves clients, refuses those over
;;;     max-connections (the first refusal logged), listens on one listener
;;;     at a time, listens with the limits' backlog, closes at a shutdown, and
;;;     closes when it cannot listen;
;;;   - deadlines, under short limits: 408 for half a head, a head or a body
;;;     sent a piece at a time (slowhttptest's slow headers and slow body),
;;;     and closes for an idle connection, a lingering client that never
;;;     closes, a client that sends nothing, and a client that never reads
;;;     a MiB answer (slow read; chez-libuv v0.7.1 or later copies a write's
;;;     bytes in bulk, so the write holds the loop less than a tick).  Each
;;;     deadline is met at the first time the shell's timer fires at or after
;;;     it, every tick-ms: within a tick, never before.  The loop's clock is
;;;     brought up to date as each deadline is armed and each response
;;;     written, so a hold of the loop (a handler's, the shell's own work's,
;;;     or one before an adoption) neither shortens a deadline armed after it
;;;     nor dates a response written after it early;
;;;   - read-side backpressure, on a shell made on credit: a reader makes
;;;     reading wait for its credit, with no deadline armed and the shell's
;;;     timer stopped; credited, it is handed the body in order, one read at
;;;     a time; a credit for more than it was handed closes the connection
;;;     and raises to the caller;
;;;   - the drain, on shells whose drain lasts 200 ms, with shell-shutdown!
;;;     in the signal's place: an idle connection is closed at once, a
;;;     request in flight is answered saying the connection closes, a client
;;;     holding half a head or a connection held in its handler is closed at
;;;     the drain's deadline, on time; the drain ends with its last
;;;     connection (`draining`, `drain-timeout`, `stopped` logged); when
;;;     telling a connection raises, the rest are still told; the shell
;;;     watches SIGTERM and SIGINT once and closes the handles when it serves
;;;     no more;
;;;   - the door: a WebSocket handshake answered with a switch gets a 101 and
;;;     hands the stream to the taker, which echoes however the kernel split
;;;     the reads and closes once its client ends; a taker that raises or
;;;     waits, a write after the close (cancelled), max-connections counting
;;;     taken streams, a taker's deadline (on time, armed at the loop's time
;;;     brought up to date), the staged close (the client reads the close and
;;;     the stream's end, the stream lingers until the client closes or the
;;;     linger deadline passes, an abort closes it at once), the write timeout
;;;     each write a closing taker waits for gets, and the taker's drain call;
;;;   - a response's end: what its request's code registered is told from the
;;;     scheduler's drain, after libuv's turn, the first request's before
;;;     the second's handler is called; a raise is taken by the run loop's
;;;     guard, whichever shell's turns the drain, logged `on-done-failed`,
;;;     the others still told; a switch's is told before its take-over;
;;;   - the shell's one timer: four connections add one timer to the loop; its
;;;     wheel empty, it stops, and the shell keeps it for its next deadline,
;;;     closing it once shut down with no connection left; when one firing's
;;;     ticks raise for two connections, each is still ticked;
;;;   - at the end every connection was accepted and has closed, and no
;;;     handle is left on the loop.
;;;
;;; Oracles: RFC 9110 §5.6.7's example instant, Sun, 06 Nov 1994 08:49:37
;;; GMT, as the shell's clock; chez-httparse's response parser; chez-libuv's
;;; live-handle list and its dev-build counters; byte-machine's own contract
;;; condition, provoked by a feed from inside a callback; the weak-pair
;;; instrument, calibrated below; for deadlines, the loop's time (uv_now)
;;; each was armed at, read where it was armed (a taker's as its arm left
;;; it), and each write began at, and the suite's own limits, and a hold of
;;; the loop timed by libuv's clock, read on a loop made for the hold
;;; (hold-until!); for a timer's stop, a firing traced after its
;;; connection's deadline left the wheel; for the drain, the loop's time
;;; each shutdown was asked at, which the server is told, plus the suite's
;;; drain timeout; and for the addresses, the address a client connected
;;; from, its handle's port, and a listener's address and bound port, as
;;; libuv reads them, and RFC 9293 §3.6.1's reset of data that comes after a
;;; close.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) collect collect-maximum-generation weak-cons bwp-object?
              current-time time-second time-nanosecond fork-thread)
        (libuv) (uv-testing)
        (rename (only (libuv private native) live-counts) (live-counts debug-live-counts))
        (only (byte-machine private conditions)
              byte-machine-contract-condition? byte-machine-contract-condition-code)
        (byte-machine runtime)
        (only (generated httparse-message) httparse-message-machine)
        (only (httparse modes) httparse-message-type-value)
        (http-server private shell)
        (only (http-server private scheduler)
              scheduler-phase current-coroutine coroutine-waits coroutine-park! coroutine-wake! coroutine-yield!
              scheduler-invariant? scheduler-invariant-name)
        (only (http-server awaiting) awaiting deadline-passed? client-closed? make-client-closed
              resolve-error? resolve-error-reason body-failed? make-body-failed)
        (only (http-server private waits) await sleep-ms with-deadline resolve
              next-body-piece body-input-port)
        (only (http-server server) server-phase)
        (only (http-server connection) conn-phase conn-parser-callbacks conn-span-callbacks
              conn-outstanding conn-outstanding-bytes conn-addresses)
        (http-server request) (http-server response) (http-server span) (http-server limits)
        (only (http-server view) request-remote-address request-remote-port
              request-local-address request-local-port)
        (only (http-server body) read-body read-whole-body)
        (http-server switch) (http-server transport)
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
    ((tick) (time! (list (if (connection? c) 'tick 'fire) c (cadr datum))))
    ((closed) (when (eq? kind 'event) (time! (list 'closed c (uv-now loop))))))
  (when (and (eq? kind 'server-event) (eq? (car datum) 'shutdown-requested))
    (time! (list 'shutdown c (cadr datum))))
  (when (and (eq? kind 'server-action) (eq? (car datum) 'force-close-all))
    (time! (list 'forced c)))
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
;; connection was given, as (tick connection now); each time a shell's
;; timer fired, as (fire shell now), which it tells its server; and each
;; shutdown a shell's server was asked for, as (shutdown shell now), and
;; each time it asked for every connection to be closed, as (forced shell);
;; and each connection's close, as (closed connection at), `at` the loop's
;; time as the close completed.  The first idle deadline, which the shell
;; arms as it adopts a connection, is recorded where the suite's listener
;; adopts it.
(define timed '())
(define (time! entry) (set! timed (cons entry timed)))

;; verbs / events : Connection -> (Listof Symbol) — its actions, or its
;; events, in order.
(define (traced-of c kind)
  (reverse (map caddr (filter (lambda (t) (and (eq? (car t) c) (eq? (cadr t) kind))) traced))))
(define (verbs c) (traced-of c 'action))
(define (events c) (traced-of c 'event))

;; last-verbs : Connection Nat -> (Listof Symbol) — its last `n` actions.
(define (last-verbs c n)
  (let ((v (verbs c)))
    (if (< (length v) n) v (list-tail v (- (length v) n)))))

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
;; POST's body first (a response given instead of a reader would close the
;; connection), except: `/echo` reads the body whole and
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
;; made on credit, it owes credit for them.  And a producer
;; (tests/producers.sls): `/stream` streams a MiB in 64 pieces of 16 KiB, the
;; k-th filled with the k-th letter from `a`, and `stream-calls` says how many
;; times the last one was called; `/rows` streams 4,000 rows of 100 bytes the
;; same way, `rows-calls` counting; `/refilled` the same rows, each handed
;; out in one bytevector, refilled at each call; `/rows-close` the same rows,
;; closing the connection's handle behind the core as its producer is called
;; the second time; `/mixed` streams four pieces, of 100 bytes and 5,000 in
;; turn; `/pieces` streams three texts; `/head-first` two, its
;; producer keeping in `head-first-seen`, at its first call, how many more
;; write requests chez-libuv holds than when the handler was called
;; (`head-first-requests`); and `/stream-raise` a piece, then raises; and
;; `/sized` three texts as a body of their 13 bytes, `/sized-short` two, 8
;; bytes, as a body of 20, and `/sized-long` the three as a body of 10.  And where a handler is called, and handlers that
;; wait:
;; `/phase` answers the scheduler's phase it was called in and whether a
;; coroutine ran it; `/await` waits, its thunk parked in `parked` until the
;; suite wakes it, then answers what it was woken with, the phase and
;; whether a coroutine ran it; `/wait-plain` parks with no `awaiting`;
;; `/await-read` waits and reads the body, yielding before it keeps each
;; piece, and answers the pieces joined; `/await-held` waits and reads the
;; body, its first piece parked in `parked` until the suite wakes it; and
;; `/await-stream` waits and streams three texts, yielding before each, and
;; `/await-sized` does as a body of their 13 bytes; and
;; `/read-phase` reads the body with an ordinary reader, and answers whether
;; a coroutine ran any of its pieces; and `/counted` counts its calls in
;; `counted-calls`.  And handlers that wait with the verbs: `/await-wake`
;; waits on `await`, keeping its resume in `waker`, and answers what it was
;; given; `/wake` calls `waker` twice, with
;; "woken by another" and then "again", and answers "woke"; `/sleep` holds
;; the loop 30 ms, then sleeps 20 ms, and answers how many milliseconds it
;; slept, the hold and the sleep each timed by the loop's clock read on a
;; loop of its own (loop-ms), so the suite's loop keeps its time from
;; before the hold, which the sleep must bring up to date itself; and what
;; a timer on the suite's loop due 19 ms into the sleep read of the timed
;; waits armed as it fired, or `not-fired`;
;; `/deadline` sleeps a minute inside a deadline of 10 ms, and answers
;; "passed" when the deadline's raise comes, or "slept"; `/resolve` resolves
;; "localhost" and answers the addresses, a space between each;
;; `/resolve-empty` resolves "", `/resolve-nul` a name with a NUL in it,
;; `/resolve-long` one of 300 characters, and `/resolve-unknown` "a..b",
;; whose empty label the resolver refuses without asking a server, each
;; answering the reason it raised with; and `/await-none` waits and reads
;; the body with a reader whose piece ends with a sleep, answering no
;; values, and answers its target at the body's end.  And `/noted` waits at
;; every call it makes into handler code, noting each coroutine it runs on
;; in `noted`, weakly: its thunk sleeps, looks localhost up and meets a
;; deadline of 0 ms; its reader's piece and end each sleep; and it streams
;; two texts, its producer sleeping before each call.  And `/addresses`
;; answers the connection's addresses, as addresses-text writes them, and
;; keeps in `addresses-seen`, newest first, the record the request holds.
;; And handlers that pull their body: `/pull` answers it; `/pull-length`
;; its length, as text; `/pull-held` takes its first piece, parks in
;; `parked` until the suite wakes it, then answers the length; `/pull-port`
;; answers the length it read whole through a port; `/pull-small` pulls it
;; capped at 4 bytes, letting the failure out, `/pull-caught` the same,
;; answering `caught`, and `/pull-own` the same, raising a `&body-failed` of
;; its own in place of the pull's; `/pull-leave` sets `leave-state` to 'waiting as it
;; begins and, once a pull raises &client-closed, to 'told, or 'told-twice
;; when the call after it raises too, then lets it out; `/pull-deadline`
;; pulls inside a deadline of 20 ms, answering "passed" when it raises;
;; `/pull-late` pulls inside a deadline of 20 ms, sets `leave-state` to
;; 'sleeping as it then sleeps 100 ms, and answers the rest of the body;
;; and `/pull-after` waits on `await`, keeping its resume in `waker`, then
;; sets `leave-state` to what two pulls raised.
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
;; hold-until! : Nat -> Void — keep the loop's thread busy until libuv's
;; loop clock reads `until` or later, read on a loop made for the hold.
;; Every loop in a process reads one clock, which never steps back (libuv
;; 1.52.1's uv__hrtime: src/unix/linux.c's one fast clock id, darwin.c's
;; mach_continuous_time, win/util.c's performance counter), so the hold is
;; timed in the suite's loop's milliseconds, and that loop keeps its cached
;; time.
(define (hold-until! until)
  (call-with-uv-loop
   (lambda (clock)
     (let spin ()
       (uv-update-time! clock)
       (when (< (uv-now clock) until) (spin))))))
;; loop-ms : -> Nat — libuv's loop clock now, read as hold-until! reads it,
;; on a loop made for the read: the suite's loop keeps its cached time.
(define (loop-ms)
  (call-with-uv-loop (lambda (clock) (uv-update-time! clock) (uv-now clock))))
(define parked #f)
(define waker #f)
;; How far the handlers of `/leave`, `/half-close` and `/held-wait` have
;; come: 'waiting once they wait, 'told once a close raised in the wait.
(define leave-state #f)
;; The coroutines `/noted` ran on, newest first, each with what it ran:
;; `(kind . weak-pair)`, the pair's car the coroutine.  And what each one's
;; waits kept of it, its context, which its request's notice points to,
;; the same way.
(define noted '())
(define noted-waits '())
;; note! : Symbol -> Void — the coroutine running, noted weakly as `kind`,
;; and its waits' context.
(define (note! kind)
  (set! noted (cons (cons kind (weak-cons (current-coroutine) '())) noted))
  (set! noted-waits (cons (cons kind (weak-cons (coroutine-waits (current-coroutine)) '())) noted-waits)))
;; reason-for : String -> String — the reason `resolve` raised with for
;; `host`, or "resolved".
(define (reason-for host)
  (guard (e ((resolve-error? e) (symbol->string (resolve-error-reason e))))
    (resolve host)
    "resolved"))

;; pulled-joined : (-> (U Bytevector Eof)) -> Bytevector
;; Every piece `pull` answers until the eof object, joined.
(define (pulled-joined pull)
  (let ((c (make-byte-collector)))
    (let loop ()
      (let ((p (pull)))
        (unless (eof-object? p)
          (collect-span! c p 0 (bytevector-length p))
          (loop))))
    (collector-bytes c)))

;; appended : Bytevector Bytevector -> Bytevector — one after the other.
(define (appended x y)
  (let ((o (make-bytevector (+ (bytevector-length x) (bytevector-length y)))))
    (bytevector-copy! x 0 o 0 (bytevector-length x))
    (bytevector-copy! y 0 o (bytevector-length x) (bytevector-length y))
    o))

;; pulled-length : Nat -> Nat — `n` and the bytes of every piece pulled
;; after it, until the eof object.
(define (pulled-length n)
  (let ((p (next-body-piece)))
    (if (eof-object? p) n (pulled-length (+ n (bytevector-length p))))))

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
;; What the procedures registered with request-on-done! were told, in the
;; order told, as (name how); what /done-2's handler found told when it was
;; called; and how many times /done-leave's producer was called.
(define done-heard '())
(define (done-hearing name) (lambda (how) (set! done-heard (append done-heard (list (list name how))))))
(define done-at-second 'not-called)
(define leave-calls 0)
(define leave-piece (make-bytevector 65536 120))
;; Whether /done-busy's producer and /done-sleeps's thunk have begun to
;; wait, and what /done-door's take-over found told when it was called.
(define busy-started #f)
(define sleeps-started #f)
(define done-at-take-over 'not-called)

;; piece-text : Bytevector Nat Nat -> String — bv[from, to) as text.
(define (piece-text bv from to)
  (let ((o (make-bytevector (- to from))))
    (bytevector-copy! bv from o 0 (- to from))
    (utf8->string o)))

(define mixed-pieces
  (list (make-string 100 #\a) (make-string 5000 #\b) (make-string 100 #\c) (make-string 5000 #\d)))
(define head-first-requests 0)
(define head-first-seen 'not-called)
(define addresses-seen '())
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
          ((bytevector=? target (b "/raise-contract"))
           (raise (provoke-reentrancy)))
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
              (hold-until! (+ (loop-ms) 30))
              (let ((before (loop-ms)) (seen (vector 'not-fired)) (witness (make-uv-timer loop)))
                (uv-timer-start! witness (lambda (t) (vector-set! seen 0 (shell-waits-timed shell)))
                                 (- (+ before 19) (uv-now loop)) 0)
                (sleep-ms 20)
                (uv-close! witness)
                (let ((slept (- (loop-ms) before)) (w (vector-ref seen 0)))
                  (make-response 200 #f '()
                                 (string->utf8 (string-append (number->string slept) " "
                                                              (if (symbol? w) (symbol->string w) (number->string w))))))))))
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
          ((bytevector=? target (b "/noted"))
           (awaiting
            (lambda ()
              (note! 'thunk)
              (sleep-ms 0)
              (resolve "localhost")
              (guard (e ((deadline-passed? e) #f))
                (with-deadline 0 (lambda () (sleep-ms 60000))))
              (read-body (lambda (bv start end) (note! 'piece) (sleep-ms 0))
                         (lambda ()
                           (note! 'end)
                           (sleep-ms 0)
                           (let ((p (producer-of '("one " "two"))))
                             (make-response 200 #f '()
                                            (lambda () (note! 'producer) (sleep-ms 0) (p)))))))))
          ((bytevector=? target (b "/await-none"))
           (awaiting
            (lambda ()
              (read-body (lambda (bv start end) (sleep-ms 0))
                         (lambda () (make-response 200 #f '() target))))))
          ;; A client's close while the handler waits.
          ((bytevector=? target (b "/leave"))
           (awaiting
            (lambda ()
              (set! leave-state 'waiting)
              (guard (e ((client-closed? e) (set! leave-state 'told) (raise e)))
                (sleep-ms 60000))
              (make-response 200 #f '() target))))
          ((bytevector=? target (b "/half-close"))
           (awaiting
            (lambda ()
              (set! leave-state 'waiting)
              (make-response 200 #f '()
                             (guard (e ((client-closed? e) (b "told, answered")))
                               (sleep-ms 60000)
                               (b "slept"))))))
          ((bytevector=? target (b "/raise-closed"))
           (awaiting (lambda () (raise (make-client-closed)))))
          ((bytevector=? target (b "/held-wait"))
           (awaiting
            (lambda ()
              (set! leave-state 'waiting)
              (sleep-ms 50)
              (make-response 200 #f '() target))))
          ((bytevector=? target (b "/pull"))
           (awaiting (lambda () (make-response 200 #f '() (pulled-joined next-body-piece)))))
          ((bytevector=? target (b "/pull-length"))
           (awaiting (lambda () (make-response 200 #f '() (b (number->string (pulled-length 0)))))))
          ((bytevector=? target (b "/pull-held"))
           (awaiting
            (lambda ()
              (let ((first (next-body-piece)))
                (set! parked (current-coroutine))
                (coroutine-park!)
                (make-response 200 #f '() (b (number->string (pulled-length (bytevector-length first)))))))))
          ((bytevector=? target (b "/pull-port"))
           (awaiting
            (lambda ()
              (let ((body (get-bytevector-all (body-input-port))))
                (make-response 200 #f '()
                               (b (number->string (if (eof-object? body) 0 (bytevector-length body)))))))))
          ((bytevector=? target (b "/pull-small"))
           (awaiting (lambda () (pulled-joined (lambda () (next-body-piece 4))) (make-response 200 #f '() target))))
          ((bytevector=? target (b "/pull-own"))
           (awaiting
            (lambda ()
              (guard (e ((body-failed? e) (raise (make-body-failed 'body-too-large 413))))
                (pulled-joined (lambda () (next-body-piece 4)))
                (make-response 200 #f '() target)))))
          ((bytevector=? target (b "/pull-caught"))
           (awaiting
            (lambda ()
              (make-response 200 #f '()
                             (guard (e ((body-failed? e) (b "caught")))
                               (pulled-joined (lambda () (next-body-piece 4))))))))
          ((bytevector=? target (b "/pull-leave"))
           (awaiting
            (lambda ()
              (set! leave-state 'waiting)
              (guard (e ((client-closed? e)
                         (set! leave-state
                               (if (guard (again ((client-closed? again) #t)) (next-body-piece) #f)
                                   'told-twice
                                   'told))
                         (raise e)))
                (pulled-joined next-body-piece))
              (make-response 200 #f '() target))))
          ((bytevector=? target (b "/pull-deadline"))
           (awaiting
            (lambda ()
              (make-response 200 #f '()
                             (guard (e ((deadline-passed? e) (b "passed")))
                               (with-deadline 20 (lambda () (pulled-joined next-body-piece))))))))
          ((bytevector=? target (b "/pull-late"))
           (awaiting
            (lambda ()
              (guard (e ((deadline-passed? e) #f))
                (with-deadline 20 (lambda () (pulled-joined next-body-piece))))
              (set! leave-state 'sleeping)
              (sleep-ms 100)
              (make-response 200 #f '() (pulled-joined next-body-piece)))))
          ((bytevector=? target (b "/pull-after"))
           (awaiting
            (lambda ()
              (await (lambda (resume) (set! waker resume)))
              (let ((raised (lambda () (guard (e ((client-closed? e) 'client-closed)) (next-body-piece) 'none))))
                (set! leave-state (list (raised) (raised))))
              (make-response 200 #f '() target))))
          ((bytevector=? target (b "/await-stream"))
           (awaiting
            (lambda ()
              (let ((p (producer-of '("one " "two " "three"))))
                (make-response 200 #f '() (lambda () (coroutine-yield!) (p)))))))
          ((bytevector=? target (b "/await-sized"))
           (awaiting
            (lambda ()
              (let ((p (producer-of '("one " "two " "three"))))
                (make-response 200 #f '() (sized-body 13 (lambda () (coroutine-yield!) (p))))))))
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
          ((bytevector=? target (b "/done-1"))
           (request-on-done! req (done-hearing 'done-1))
           (make-response 200 #f '() (b "one")))
          ((bytevector=? target (b "/done-2"))
           (set! done-at-second done-heard)
           (request-on-done! req (done-hearing 'done-2))
           (make-response 200 #f '() (b "two")))
          ((bytevector=? target (b "/done-phase"))
           (request-on-done! req (lambda (how)
                                   (set! done-heard (append done-heard (list (list 'phase (scheduler-phase)))))))
           (make-response 200 #f '() (b "phase")))
          ((bytevector=? target (b "/done-raise"))
           (request-on-done! req (done-hearing 'first))
           (request-on-done! req (lambda (how) (raise (make-message-condition "the done procedure failed"))))
           (request-on-done! req (done-hearing 'third))
           (make-response 200 #f '() (b "raise")))
          ((bytevector=? target (b "/done-wait"))
           (request-on-done! req (done-hearing 'after))
           (request-on-done! req (lambda (how) (sleep-ms 1) (set! done-heard (append done-heard '((slept))))))
           (make-response 200 #f '() (b "wait")))
          ((bytevector=? target (b "/done-leave"))
           (set! leave-calls 0)
           (request-on-done! req (done-hearing 'leave))
           (make-response 200 #f '() (lambda () (set! leave-calls (+ leave-calls 1)) leave-piece)))
          ((bytevector=? target (b "/done-busy"))
           (set! busy-started #f)
           (request-on-done! req (done-hearing 'busy))
           (awaiting
            (lambda ()
              (make-response 200 #f '()
                             (lambda ()
                               (set! busy-started #t)
                               (sleep-ms 20)
                               (set! done-heard (append done-heard '((woke))))
                               (eof-object))))))
          ((bytevector=? target (b "/done-reader"))
           (request-on-done! req (done-hearing 'reader))
           (awaiting
            (lambda ()
              (read-body (lambda (bv from to)
                           (let ((text (piece-text bv from to)))
                             (set! done-heard (append done-heard (list (list 'start text))))
                             (sleep-ms 20)
                             (set! done-heard (append done-heard (list (list 'end text))))))
                         (lambda () (make-response 200 #f '() #f))))))
          ((bytevector=? target (b "/done-door"))
           (set! done-at-take-over 'not-called)
           (request-on-done! req (done-hearing 'door))
           (switching (lambda (t retained)
                        (set! done-at-take-over done-heard)
                        (transport-close! t))))
          ((bytevector=? target (b "/done-sleeps"))
           (set! sleeps-started #f)
           (request-on-done! req (done-hearing 'sleeps))
           (awaiting (lambda () (set! sleeps-started #t) (sleep-ms 30) (make-response 200 #f '() #f))))
          ((bytevector=? target (b "/pieces"))
           (make-response 200 #f '() (producer-of '("one " "two " "three"))))
          ((bytevector=? target (b "/mixed"))
           (make-response 200 #f '() (producer-of mixed-pieces)))
          ((bytevector=? target (b "/sized"))
           (make-response 200 #f '() (sized-body 13 (producer-of '("one " "two " "three")))))
          ((bytevector=? target (b "/sized-short"))
           (make-response 200 #f '() (sized-body 20 (producer-of '("one " "two ")))))
          ((bytevector=? target (b "/sized-long"))
           (make-response 200 #f '() (sized-body 10 (producer-of '("one " "two " "three")))))
          ((bytevector=? target (b "/stream-raise"))
           (make-response 200 #f '()
                          (producer-of '("one piece")
                                       (lambda () (raise (make-message-condition "the producer failed"))))))
          ((bytevector=? target (b "/door")) (switching echo))
          ((bytevector=? target (b "/door-raise"))
           (switching (lambda (t retained) (raise (make-message-condition "the taker failed")))))
          ((bytevector=? target (b "/door-late"))
           (switching (lambda (t retained)
                        (transport-write! t (b "bye"))
                        (transport-close! t)
                        (transport-write! t (b "late") 0 4 (lambda (err) (took! 'late err))))))
          ((bytevector=? target (b "/door-deaf"))
           (switching (lambda (t retained)
                        (transport-on-close! t (lambda ()
                                                 (took! 'closed)
                                                 (transport-write! t (b "x") 0 1 (lambda (err) (took! 'after-close err)))
                                                 (transport-read-start! t (lambda (bv from to) #t)
                                                                        (lambda (why) (took! 'late-end why)))
                                                 (transport-deadline! t 1 (lambda () (took! 'late-passed)))
                                                 (transport-on-close! t (lambda () (took! 'closed-late)))
                                                 (values)))
                        (transport-read-start! t (lambda (bv from to) #t) (lambda (why) (took! 'ended why))))))
          ((bytevector=? target (b "/door-shut"))
           (switching (lambda (t retained)
                        (uv-shutdown! (connection-tcp (newest))
                                      (lambda (err)
                                        (transport-write! t (b "late") 0 4
                                                          (lambda (err) (took! 'refused err) (transport-close! t))))))))
          ((bytevector=? target (b "/door-thread"))
           (switching (lambda (t retained) (set! thread-transport t))))
          ((bytevector=? target (b "/door-pause"))
           (switching (lambda (t retained)
                        (set! paused-transport t)
                        (transport-read-start! t
                                               (lambda (bv from to)
                                                 (took! 'paused-read (bytes-between bv from to))
                                                 (transport-read-stop! t))
                                               (lambda (why) (took! 'ended why) (transport-close! t))))))
          ((bytevector=? target (b "/door-twice"))
           (switching (lambda (t retained)
                        (transport-read-start! t (lambda (bv from to) (took! 'first-reader)) (lambda (why) #t))
                        (transport-read-start! t (lambda (bv from to) (transport-write! t bv from to))
                                               (lambda (why) (transport-close! t))))))
          ((bytevector=? target (b "/door-timed"))
           (switching (lambda (t retained)
                        (transport-read-start!
                         t
                         (lambda (bv from to)
                           (transport-deadline! t door-ms (lambda () (took! 'passed (uv-now loop)) (transport-close! t)))
                           (took! 'armed (uv-now loop)))
                         (lambda (why) #t)))))
          ((bytevector=? target (b "/door-big"))
           (switching (lambda (t retained)
                        (transport-write! t big-door)
                        (transport-close! t))))
          ((bytevector=? target (b "/door-bound"))
           (switching (lambda (t retained)
                        (transport-on-close! t (lambda () (took! 'closed)))
                        (transport-write! t big-door 0 (bytevector-length big-door) (lambda (err) (took! 'written err)))
                        (transport-close! t)
                        (transport-deadline! t door-ms (lambda () (took! 'passed) (transport-abort! t))))))
          ((bytevector=? target (b "/door-bound-raise"))
           (switching (lambda (t retained)
                        (transport-on-close! t (lambda () (took! 'closed)))
                        (transport-write! t big-door 0 (bytevector-length big-door) (lambda (err) (took! 'written err)))
                        (transport-deadline! t door-ms
                                             (lambda ()
                                               (took! 'passed)
                                               (raise (make-message-condition "the deadline's call failed")))))))
          ((bytevector=? target (b "/door-unbounded"))
           (switching (lambda (t retained) (closing-behind! t (list big-door) #f #f))))
          ((bytevector=? target (b "/door-rearm"))
           (switching (lambda (t retained) (closing-behind! t (list big-door huge-door) #f #f))))
          ((bytevector=? target (b "/door-own-first"))
           (switching (lambda (t retained) (closing-behind! t (list big-door) 100 #f))))
          ((bytevector=? target (b "/door-own-later"))
           (switching (lambda (t retained) (closing-behind! t (list big-door) 600 #t))))
          ((bytevector=? target (b "/door-disarm"))
           (switching (lambda (t retained)
                        (transport-deadline! t 60000 (lambda () (took! 'passed)))
                        (took! 'armed (shell-deadlines adopting))
                        (transport-deadline! t #f)
                        (took! 'disarmed (shell-deadlines adopting))
                        (transport-close! t))))
          ((bytevector=? target (b "/door-fail"))
           (switching (lambda (t retained)
                        (let ((n (bytevector-length retained)))
                          (transport-on-close! t (lambda () (took! 'closed)))
                          (transport-read-start!
                           t
                           (lambda (bv from to)
                             (set! n (+ n (- to from)))
                             (took! 'read (- to from))
                             (when (and (>= n fail-cap) (null? (took-of 'failed)))
                               (took! 'failed n)
                               (transport-write! t close-frame)
                               (transport-close! t)))
                           (lambda (why) (took! 'ended why)))))))
          ((bytevector=? target (b "/door-bye"))
           (switching (lambda (t retained)
                        (set! lingering-transport t)
                        (transport-on-close! t (lambda () (took! 'closed)))
                        (transport-deadline! t door-ms (lambda () (took! 'passed)))
                        (transport-write! t close-frame)
                        (took! 'closing (uv-now loop))
                        (transport-close! t))))
          ((bytevector=? target (b "/door-held-close"))
           (switching (lambda (t retained)
                        (let ((stale (uv-now loop)))
                          (hold-until! (+ stale slow-ms))
                          (let ((unrefreshed (uv-now loop)))
                            (transport-close! t)
                            (took! 'held stale unrefreshed (connection-deadline (newest))))))))
          ((bytevector=? target (b "/door-held-bound"))
           (switching (lambda (t retained)
                        (let ((stale (uv-now loop)))
                          (hold-until! (+ stale slow-ms))
                          (let ((unrefreshed (uv-now loop)))
                            (transport-write! t big-door)
                            (transport-close! t)
                            (took! 'held stale unrefreshed (connection-deadline (newest))))))))
          ((bytevector=? target (b "/door-held"))
           (switching (lambda (t retained)
                        (let ((stale (uv-now loop)))
                          (hold-until! (+ stale slow-ms))
                          (let ((unrefreshed (uv-now loop)))
                            (transport-deadline! t 60000 (lambda () (took! 'passed)))
                            (took! 'held stale unrefreshed (connection-deadline (newest)))
                            (transport-close! t))))))
          ((bytevector=? target (b "/door-redrain"))
           (switching (lambda (t retained)
                        (transport-on-drain! t (lambda ()
                                                 (took! 'drained)
                                                 (transport-on-drain! t (lambda () (took! 'drained-again)))
                                                 (transport-close! t))))))
          ((bytevector=? target (b "/door-await"))
           (awaiting (lambda () (set! parked (current-coroutine)) (coroutine-park!) (switching echo))))
          ((bytevector=? target (b "/door-wait"))
           (let ((resume-to #f))
             (switching (lambda (t retained)
                          (transport-read-start! t
                                                 (lambda (bv from to)
                                                   (let ((r resume-to)) (set! resume-to #f) (when r (r (bytes-between bv from to)))))
                                                 (lambda (why) (took! 'ended why) (transport-close! t)))
                          (awaiting
                           (lambda ()
                             (guard (e ((client-closed? e) (took! 'told) (raise e)))
                               (let loop ()
                                 (transport-write! t (await (lambda (resume) (set! resume-to resume))))
                                 (loop)))))))))
          ((bytevector=? target (b "/door-woken"))
           (let ((resume-to #f))
             (switching (lambda (t retained)
                          (transport-read-start! t
                                                 (lambda (bv from to)
                                                   (let ((r resume-to) (piece (bytes-between bv from to)))
                                                     (set! resume-to #f)
                                                     (set! woken (weak-cons piece #f))
                                                     (when r (r piece))))
                                                 (lambda (why) (transport-close! t)))
                          (awaiting
                           (lambda ()
                             (let loop ()
                               (set! woken-waits #f)
                               (transport-write! t (await (lambda (resume) (set! woken-waits #t) (set! resume-to resume))))
                               (loop))))))))
          ((bytevector=? target (b "/door-read-later"))
           (switching (lambda (t retained)
                        (awaiting (lambda ()
                                    (sleep-ms door-ms)
                                    (took! 'read-start)
                                    (transport-read-start! t (lambda (bv from to) (transport-write! t bv from to))
                                                           (lambda (why) (took! 'ended why) (transport-close! t))))))))
          ((bytevector=? target (b "/door-ended-early"))
           (switch-protocols (list (cons (b "Upgrade") (b "websocket"))
                                   (cons (b "Sec-WebSocket-Accept") (b "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
                                   (cons (b "X-Pad") (make-bytevector door-pad 97)))
                             (lambda (t retained)
                               (transport-read-start! t (lambda (bv from to) #t)
                                                      (lambda (why) (took! 'ended why) (transport-close! t)))
                               (took! 'told-in-take-over (length (took-of 'ended)))
                               (when door-closes-early (transport-close! t)))))
          ((bytevector=? target (b "/door-reads-again"))
           (switching (lambda (t retained)
                        (define (on-end why)
                          (took! 'ended why)
                          (when (= (length (took-of 'ended)) 1)
                            (transport-read-start! t (lambda (bv from to) #t) on-end)
                            (transport-deadline! t door-ms (lambda () (took! 'passed) (transport-close! t)))))
                        (transport-read-start! t (lambda (bv from to) #t) on-end))))
          ((bytevector=? target (b "/door-wait-raise"))
           (switching (lambda (t retained)
                        (awaiting (lambda () (sleep-ms 1) (raise (make-message-condition "the waiting taker failed")))))))
          ((bytevector=? target (b "/door-wait-ends"))
           (switching (lambda (t retained)
                        (transport-read-start! t (lambda (bv from to) (transport-write! t bv from to))
                                               (lambda (why) (transport-close! t)))
                        (awaiting (lambda () (took! 'thunk-ended) 'done)))))
          ((or (bytevector=? target (b "/door-wait-no-values")) (bytevector=? target (b "/door-wait-two-values")))
           (switching (lambda (t retained)
                        (transport-read-start! t (lambda (bv from to) (transport-write! t bv from to))
                                               (lambda (why) (transport-close! t)))
                        (awaiting (lambda ()
                                    (took! 'thunk-ended)
                                    (if (bytevector=? target (b "/door-wait-no-values")) (values) (values 1 2)))))))
          ((bytevector=? target (b "/addresses"))
           (set! addresses-seen (cons (request-addresses req) addresses-seen))
           (make-response 200 #f '()
                          (string->utf8 (addresses-text (request-remote-address req) (request-remote-port req)
                                                        (request-local-address req) (request-local-port req)))))
          ((eq? (request-method req) 'POST)
           (read-body (lambda (bv start end) #t) (lambda () (make-response 200 #f '() target))))
          (else (make-response 200 #f '() target)))))

;; addresses-text : (U String #f) (U Nat #f) (U String #f) (U Nat #f) -> String
;; A connection's two ends, the remote address and port, then the local, a
;; space between each, and #f as "#f": what `/addresses` answers.
(define (addresses-text remote-address remote-port local-address local-port)
  (spaced (map (lambda (x) (cond ((string? x) x) ((number? x) (number->string x)) (else "#f")))
               (list remote-address remote-port local-address local-port))))

;; end-of : UvTcp (UvTcp -> (values (U String #f) Nat)) -> (List (U String #f) (U Nat #f))
;; One end of `tcp` as libuv reads it, `read` being uv-tcp-peer-address or
;; uv-tcp-sockname-address, or (#f #f) if the read fails: the oracle the
;; shell's addresses are held to.
(define (end-of tcp read)
  (guard (e ((uv-errno-error? e) (list #f #f)))
    (let-values (((address port) (read tcp))) (list address port))))

;; ends-text : UvTcp UvTcp -> String
;; addresses-text of the client's own end, `client`'s, as the remote, and
;; `server`'s end, a listener's, as the local: what a request on the
;; connection between them reads.
(define (ends-text client server)
  (apply addresses-text (append (end-of client uv-tcp-sockname-address)
                                (end-of server uv-tcp-sockname-address))))

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
(define withholding #f)                ; keep the next connection accepted, unadopted
(define withheld #f)                   ; the connection so kept

;; open-server! : -> Void
;; The loop, the shell, and a listener on 127.0.0.1:0 that adopts each
;; connection it accepts into `adopting`; with `small-send-buffer`, the
;; connection's send buffer is asked to be that small first.  While
;; `pairing`, it holds each connection it accepts until it accepts another,
;; and adopts the two in one callback, so the shell arms both at one
;; instant.  While `withholding`, it keeps the next connection it accepts in
;; `withheld`, for the suite to adopt.  Made inside the suite, so a failure
;; here is the harness's status, not a crash.
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
                      (cond (withholding (set! withholding #f) (set! withheld tcp))
                            ((and pairing (not held)) (set! held tcp))
                            (else (when held (adopt! held) (set! held #f))
                                  (adopt! tcp))))))))

;; adopt! : UvTcp -> Void
;; Serve `tcp` in `adopting`, recording when: the shell arms a connection's
;; first deadline, its idle one, as it adopts it.  While `holding-at` is
;; `adoption`, the loop is held first.
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
;; for since the last, and runs the loop once.
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

;; --- deadlines ---------------------------------------------------------------------

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

;; --- the drain ---------------------------------------------------------------------

;; A drain of 200 ms and a tick of 10 ms, every other limit its default, so no
;; deadline of a connection's passes while the suite looks.
(define drain-limits
  (limits-with default-limits '((drain-timeout-ms . 200) (tick-ms . 10))))

;; drain-forced : Shell -> Datum
;; Whether `sh`'s server closed what was left at its drain's deadline on
;; time: the instant its shutdown was asked at plus the drain's 200 ms; then
;; the first time `sh`'s timer fired at or after it, which told the server
;; the time, asked for every connection to be closed: never before the
;; deadline, and no firing between.  'on-time; or the deadline, the firing
;; that asked and the firings from the deadline to it; or 'never-forced, or
;; 'never-shut-down.
(define (drain-forced sh)
  (let* ((log (reverse timed))
         (asked (find (lambda (e) (and (eq? (car e) 'shutdown) (eq? (cadr e) sh))) log)))
    (if (not asked)
        'never-shut-down
        (let ((deadline (+ (caddr asked) (limits-drain-timeout-ms drain-limits))))
          (let scan ((es log) (fired #f))
            (cond ((null? es) 'never-forced)
                  ((and (eq? (car (car es)) 'fire) (eq? (cadr (car es)) sh))
                   (scan (cdr es) (caddr (car es))))
                  ((and (eq? (car (car es)) 'forced) (eq? (cadr (car es)) sh))
                   (let ((firings (filter (lambda (f) (and (eq? (car f) 'fire) (eq? (cadr f) sh)
                                                           fired (<= deadline (caddr f) fired)))
                                          log)))
                     (if (and fired (<= deadline fired) (equal? (map caddr firings) (list fired)))
                         'on-time
                         (list deadline fired (map caddr firings)))))
                  (else (scan (cdr es) fired))))))))

;; firings-of : Shell -> Nat — how many times `sh`'s timer has fired.
(define (firings-of sh)
  (length (filter (lambda (e) (and (eq? (car e) 'fire) (eq? (cadr e) sh))) timed)))

;; fired-since-emptied? : Shell Connection -> Boolean
;; Whether `sh`'s timer has fired since `c`, its one connection, left the
;; wheel empty: since the first disarm after `c`'s last arm, read from the
;; trace, where each firing is traced once its stop is decided.  That
;; firing stops the timer, so no later one comes.  It may come in the turn
;; a wait ends on, before the suite looks: a wait for a firing after the
;; suite looks then runs out of turns, as it did under load.
(define (fired-since-emptied? sh c)
  (let scan ((ts traced) (fired #f) (since #f))
    (if (null? ts)
        since
        (let ((t (car ts)))
          (cond ((and (eq? (car t) c) (eq? (cadr t) 'action) (eq? (caddr t) 'arm-deadline)) since)
                ((and (eq? (car t) c) (eq? (cadr t) 'action) (eq? (caddr t) 'disarm-deadline))
                 (scan (cdr ts) fired fired))
                ((and (eq? (car t) sh) (eq? (cadr t) 'server-event) (eq? (caddr t) 'tick))
                 (scan (cdr ts) #t since))
                (else (scan (cdr ts) fired since)))))))

;; drain-logged : -> (Listof (Pair Symbol (Listof Any)))
;; What the drains logged since `logged` was cleared, oldest first.
(define (drain-logged)
  (filter (lambda (e) (memq (car e) '(draining drain-timeout stopped))) (reverse logged)))

;; --- the door ----------------------------------------------------------------------

;; What the suite's takers saw, newest first, as (what . details).
(define took '())
(define (took! what . details) (set! took (cons (cons what details) took)))

;; took-of : Symbol -> (Listof (Listof Any)) — the details of each `what`
;; the takers noted, oldest first.
(define (took-of what) (map cdr (filter (lambda (e) (eq? (car e) what)) (reverse took))))

;; switching : (Transport Bytevector -> Any) -> Switch
;; A WebSocket's switch, RFC 6455 §1.3's Sec-WebSocket-Accept beside it.
(define (switching take-over)
  (switch-protocols (list (cons (b "Upgrade") (b "websocket"))
                          (cons (b "Sec-WebSocket-Accept") (b "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")))
                    take-over))

;; The 101 the switch is written as, as the client reads it.
(define door-101
  (b "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nConnection: upgrade\r\n\r\n"))

;; echo : Transport Bytevector -> Void
;; The suite's taker: it writes back the bytes it was handed, then each it
;; reads, and closes once its client ends; told the server drains, it writes
;; `bye` and closes.  Each end and close is noted.
(define (echo t retained)
  (took! 'retained retained)
  (transport-on-close! t (lambda () (took! 'closed)))
  (transport-on-drain! t (lambda () (took! 'drained) (transport-write! t (b "bye")) (transport-close! t)))
  (when (> (bytevector-length retained) 0) (transport-write! t retained))
  (transport-read-start! t
                         (lambda (bv from to) (transport-write! t bv from to))
                         (lambda (why) (took! 'ended why) (transport-close! t))))

;; door-unread : String -> (List Symbol Symbol Symbol Symbol Datum Datum Datum)
;; A client that reads nothing, the connection's send buffer small, sends a
;; handshake to `target`, whose taker writes more than the socket takes at
;; once and arms a deadline.  Whether the stream was
;; adopted, its deadline passed, the stream then closed and gone, and its
;; write told; what it was told, the close call's notes and the taker
;; failures logged.  Then both ends are closed and the stream gone, so
;; nothing of it lands in the next check, whatever it did.
(define (door-unread target)
  (set! took '())
  (set! logged '())
  (set! small-send-buffer 4096)
  (let* ((before (newest))
         (cl (open-client! (door-handshake target) #f))
         (passed (wait-for (lambda () (pair? (took-of 'passed)))))
         (c (adopted-since before)))
    (set! small-send-buffer #f)
    (let* ((gone (wait-for (lambda () (closed-and-gone? shell c))))
           (told (wait-for (lambda () (pair? (took-of 'written)))))
           (seen (list (if (connection? c) 'adopted 'none) passed gone told (took-of 'written) (took-of 'closed)
                       (map car (filter (lambda (e) (eq? (car e) 'taker-failed)) logged)))))
      (client-close! cl)
      (when (connection? c)
        (connection-close! c)
        (wait-for (lambda () (closed-and-gone? shell c))))
      seen)))

;; door-handshake : String -> Bytevector — a handshake to `target`.
(define (door-handshake target)
  (b (string-append "GET " target " HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")))

;; RFC 6455 §5.7's masked "Hello", and "Hi" with the same mask.
(define hello-frame (u8-list->bytevector '(#x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58)))
(define hi-frame (u8-list->bytevector '(#x81 #x82 #x37 #xfa #x21 #x3d #x7f #x93)))

;; How long a taker's deadline lasts, under drain-limits' 10 ms tick.
(define door-ms 50)

;; door-pad : Nat — the bytes of a field that keep a 101's write from
;; completing while its client reads nothing: more than loopback holds for
;; one connection on Darwin and Linux (8 MiB keeps the 101 outstanding past
;; the client's end).  The check that uses it waits for the end to be read
;; first, so a pad too small fails there.
(define door-pad (* 8 1024 1024))

;; door-closes-early : Boolean — whether /door-ended-early's taker closes in
;; its take-over, after its read-start.
(define door-closes-early #f)

;; A WebSocket close frame, 1009 (RFC 6455 §5.5.1, §7.4.1): what a taker
;; that fails its client writes before its close.
(define close-frame (u8-list->bytevector '(#x88 #x02 #x03 #xf1)))

;; How much /door-fail's taker reads before it fails its client, and what
;; that client, still sending, writes after its handshake: 4 MiB.
(define fail-cap 65536)
(define client-flood (make-bytevector (* 4 1024 1024) 0))

;; The transport of /door-bye's taker, to reach once its stream lingers.
(define lingering-transport #f)

;; The piece /door-woken's taker was last woken with, held weakly in the
;; car of a weak pair, or #f; and whether its thunk has begun its next wait.
(define woken #f)
(define woken-waits #f)

;; Limits whose linger lasts 100 ms, the timer firing every 10 ms.
(define linger-limits
  (limits-with default-limits '((linger-timeout-ms . 100) (tick-ms . 10))))

;; Limits whose write timeout is 300 ms, the timer firing every 10 ms.
(define bound-limits
  (limits-with default-limits '((write-timeout-ms . 300) (tick-ms . 10))))

;; closed-by-client : Shell (Pair Client Connection) -> Symbol
;; A taken stream whose taker has closed lingers until its client closes
;; Once the client has read the stream's end it closes, as a WebSocket client
;; does once the server's close comes (RFC 6455 §7.1.1): whether the stream
;; was then let go.
(define (closed-by-client sh p)
  (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))
  (client-close! (car p))
  (wait-for (lambda () (closed-and-gone? sh (cdr p)))))

;; lingering? : Shell Connection -> Symbol
;; 'lingering while the stream is open in `sh`, its handle open; else
;; 'closed.
(define (lingering? sh c)
  (if (and (connection? c) (memq c (shell-connections sh)) (uv-handle-open? (connection-tcp c)))
      'lingering
      'closed))

;; client-wrote : Client Bytevector -> (-> Symbol)
;; Write `bytes` as one write of the client's: a procedure that answers
;; 'pending until the write completes, then its err->symbol.
(define (client-wrote cl bytes)
  (let ((status 'pending))
    (uv-write! (client-tcp cl) bytes (lambda (err) (set! status (err->symbol err))))
    (lambda () status)))

;; What the taker of /door-big writes, then closes: more than a loopback
;; socket takes at once, so its write is still under way as the close is
;; asked for.  Its bytes count up modulo 251, so their order shows.
(define big-door
  (let ((bv (make-bytevector (* 4 1024 1024))))
    (do ((i 0 (+ i 1))) ((= i (bytevector-length bv)) bv) (bytevector-u8-set! bv i (mod i 251)))))

;; 16 MiB, more than a client's receive buffer grows to while it reads, so
;; a write of it waits once the client stops.
(define huge-door (make-bytevector (* 16 1024 1024) 7))

;; The client /door-rearm's first write stops reading once it is out.
(define reading-client #f)

;; closing-behind! : Transport (Listof Bytevector) (U #f Nat) Boolean -> Void
;; A taker that writes each of `writes` and closes, noting the close's
;; instant by the loop's clock, each write's end, `(written N why AT)`, and
;; its close call; with `ms`, it then asks for a deadline of its own, whose
;; call notes when it passed and, if `abort?`, aborts.  The first write's
;; end stops `reading-client` reading, when one is set.
(define (closing-behind! t writes ms abort?)
  (transport-on-close! t (lambda () (took! 'closed)))
  (let each ((ws writes) (n 1))
    (unless (null? ws)
      (transport-write! t (car ws) 0 (bytevector-length (car ws))
                        (lambda (err)
                          (took! 'written n err (uv-now loop))
                          (when (and (= n 1) reading-client)
                            (uv-read-stop! (client-tcp reading-client)))))
      (each (cdr ws) (+ n 1))))
  (took! 'closing (uv-now loop))
  (transport-close! t)
  (when ms
    (transport-deadline! t ms (lambda ()
                                (took! 'passed (uv-now loop))
                                (when abort? (transport-abort! t))))))

;; The transport of /door-thread's taker, written to from another thread, and
;; what that write raised, once it has.
(define thread-transport #f)
(define thread-raised #f)

;; The transport of the taker that stops reading, to start it again.
(define paused-transport #f)

;; read-bytes : Symbol -> Bytevector — the bytes the takers noted under
;; `what`, end to end.
(define (read-bytes what) (joined (map car (took-of what))))

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
(define raise-in-callback
  (case-lambda
    ((obj) (raise-in-callback obj shell))
    ((obj sh)
     (let ((t (make-uv-timer loop)) (fired #f))
       (uv-timer-start! t (lambda (t) (set! fired #t) (raise obj)) 0 0)
       (let ((outcome (guard (e (#t (list 'raised e)))
                        (let step ((i 0))
                          (cond (fired 'ran-on)
                                ((= i cap) 'iterations-exhausted)
                                (else (shell-run! sh 'once) (step (+ i 1))))))))
         (uv-close! t)
         (run-until loop (lambda () (eq? (uv-handle-state t) 'closed)) 8)
         outcome)))))

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

    ;; A request reads both ends of the connection it came on: the client's,
    ;; 127.0.0.1, where it connected from, and the port its handle reads, as
    ;; the remote end, and the listener's address and bound port as the
    ;; local.  Both are the connection's, read once, as it is adopted: a
    ;; second request on it reads the same, and each holds the one record
    ;; its connection was adopted with.
    (set! addresses-seen '())
    (let ((cl (open-client! (b "GET /addresses HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads the answer of a handler that reads the connection's addresses" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (client-send! cl (b "GET /addresses HTTP/1.1\r\nHost: x\r\n\r\n"))
      (test-eq "and a second request's, on the same connection" 'satisfied
               (wait-for (lambda () (= 2 (length (responses (client-bytes cl)))))))
      (test-equal "each request reads the client's address and port, its handle's, then the listener's address and port"
                  (let ((text (addresses-text "127.0.0.1" (cadr (end-of (client-tcp cl) uv-tcp-sockname-address))
                                              "127.0.0.1" port)))
                    (list text text))
                  (map body (responses (client-bytes cl))))
      (test-eqv "each holds the one record of addresses its connection was adopted with" 2
                (let ((c (newest)))
                  (and (connection? c)
                       (for-all (lambda (a) (eq? a (conn-addresses (connection-state c)))) addresses-seen)
                       (length addresses-seen))))
      (client-close! cl))

    ;; A connection whose peer's address cannot be read, since its client
    ;; reset it before the shell adopted it.  The client closes, and the
    ;; server's end, kept unadopted, writes to it: data that comes after a
    ;; close is answered with a reset (RFC 9293 §3.6.1), so libuv's read of
    ;; the peer fails then.  Adopted, it is served all the same, the peer's
    ;; address and port #f, its own end as libuv reads it, and it closes once
    ;; it reads the reset.
    (set! withholding #t)
    (set! withheld #f)
    (let* ((cl (open-client! #f #f))
           (accepted (wait-for (lambda () (and withheld (eq? (client-connected cl) 'no-error))))))
      (client-close! cl)
      (when withheld (uv-write! withheld (b "x") (lambda (err) #f)))
      (let* ((reset (wait-for (lambda () (and withheld (not (car (end-of withheld uv-tcp-peer-address)))))))
             (local (if withheld (end-of withheld uv-tcp-sockname-address) '(no-connection #f)))
             (before (newest))
             (adoption (guard (e (#t 'raised)) (when withheld (adopt! withheld)) 'adopted))
             (c (adopted-since before)))
        (test-equal "a connection its client reset before the shell adopted it is adopted, its peer's address and port #f and its own end as libuv reads it"
                    (list 'satisfied 'satisfied 'adopted (list #f #f (car local) (cadr local)))
                    (list accepted reset adoption
                          (if c
                              (let ((a (conn-addresses (connection-state c))))
                                (list (addresses-remote-address a) (addresses-remote-port a)
                                      (addresses-local-address a) (addresses-local-port a)))
                              'not-adopted)))
        (test-eq "and it closes once it reads the reset" 'satisfied
                 (wait-for (lambda () (closed-and-gone? shell c))))))

    ;; Over IPv6, on a shell's own listener: a request reads the client's end
    ;; and the listener's, each ::1, the client's port its handle's and the
    ;; listener's the one it bound.  A host with no IPv6 loopback cannot
    ;; listen on ::1, and fails the check with the errno it met.
    (let* ((six (make-shell loop handler default-limits clock log! trace!))
           (to (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
                 (shell-listen! six "::1" 0)))
           (cl (and (number? to)
                    (open-client loop to (b "GET /addresses HTTP/1.1\r\nHost: x\r\n\r\n") #t "::1")))
           (answered (and cl (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))))
      (when cl (set! clients (cons cl clients)))
      (unless cl
        (let ((p (current-error-port)))
          (put-string p (string-append "shell: listening on ::1 failed with "
                                       (if (symbol? to) (symbol->string to) "an unknown error")
                                       "; the IPv6 check fails"))
          (put-char p #\newline)
          (flush-output-port p)))
      (test-equal "over IPv6, a request reads the client's address and port, its handle's, then the listener's address and port"
                  (if cl
                      (list 'satisfied
                            (addresses-text "::1" (cadr (end-of (client-tcp cl) uv-tcp-sockname-address)) "::1" to))
                      'listening-on-ipv6-loopback)
                  (if cl
                      (list answered (let ((rs (responses (client-bytes cl))))
                                       (if (pair? rs) (body (car rs)) 'no-response)))
                      (list 'not-listening-on-ipv6-loopback to)))
      (when cl
        (client-close! cl)
        (shell-shutdown! six)
        (wait-for (lambda () (and (null? (shell-connections six))
                                  (eq? (uv-handle-state (shell-listener six)) 'closed))))))

    ;; Where a handler is called: from the scheduler's drain,
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

    ;; A handler that waits: its thunk parks on a coroutine,
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
    ;; One request wakes another: `/await-wake` waits on `await`, and
    ;; `/wake`, an ordinary handler on a connection of its own, calls its
    ;; resume twice; the second is a late resume, logged.
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
    ;; The timed waits: the loop's waits have their own timer, and nothing is
    ;; left armed once each wait is over.  A sleep of 20 ms is armed at the
    ;; loop's time brought up to date, a reading of the one clock every loop
    ;; reads taken after `before`, and ends once that clock, read again, is
    ;; 20 ms on; the handler reads it last.  So the sleep lasts 20 of the
    ;; loop's milliseconds at least: the bound is exact.  Timed by Chez's
    ;; monotonic clock, a sleep could end early on Linux, whose loop clock is
    ;; CLOCK_MONOTONIC_COARSE and lags it.  Armed on the loop's time as the
    ;; hold left it, 30 ms behind, the sleep would be due already, and a
    ;; pause in its wake could still make it last 20 ms.  So
    ;; the witness, a timer started from that time, due at `before` plus 19,
    ;; reads how many timed waits are armed as it fires.  libuv runs due
    ;; timers in the order they are due (1.52.1 src/timer.c, the same since
    ;; 1.48.0), so it fires before the waits' timer, due at 20 past
    ;; `before` or later, and reads the sleep: 1.  A sleep due already goes
    ;; first, and the witness reads 0, or has not fired.
    (let ((cl (open-client! (b "GET /sleep HTTP/1.1\r\nHost: x\r\n\r\nGET /deadline HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 20 ms or more by the loop's clock, a timer due 19 ms in firing while the sleep is armed; one whose deadline of 10 ms ends a sleep of a minute is answered passed; nothing is left armed"
                  '(satisfied (200 at-least-20-ms 1) (200 "passed") 0)
                  (list (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (let ((rs (responses (client-bytes cl))))
                          (if (pair? rs)
                              (let* ((p (open-string-input-port (body (car rs))))
                                     (n (read p))
                                     (w (read p)))
                                (list (status (car rs)) (if (and (number? n) (>= n 20)) 'at-least-20-ms n) w))
                              'no-response))
                        (let ((rs (responses (client-bytes cl))))
                          (if (= 2 (length rs)) (list (status (cadr rs)) (body (cadr rs))) 'no-response))
                        (shell-waits-timed shell)))
      (client-close! cl))
    ;; A client's close while its handler waits: past the
    ;; request's end the connection reads only to notice it.  The handlers
    ;; sleep a minute, past the wait's cap, so a close noticed only at the
    ;; answer would leave the checks unsatisfied.
    (set! logged '())
    (set! leave-state #f)
    (let ((cl (open-client! (b "GET /leave HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (wait-for (lambda () (eq? leave-state 'waiting)))
      (let ((c (newest)))
        (client-close! cl)
        (test-equal "a waiting handler whose client closes is told: its wait raises &client-closed, nothing is answered or logged, and the connection closes"
                    '(satisfied told () closed)
                    (list (wait-for (lambda () (and (eq? leave-state 'told) (connection? c)
                                                    (not (memq c (shell-connections shell))))))
                          leave-state
                          (filter (lambda (e) (memq (car e) '(handler-failed read-error))) logged)
                          (and (connection? c) (phase c))))))
    (set! leave-state #f)
    (let ((cl (open-client! (b "GET /half-close HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (wait-for (lambda () (eq? leave-state 'waiting)))
      (client-shut! cl)
      (test-equal "one whose client only half-closes, catching the close, answers: the client reads the answer, then the stream's end"
                  '(satisfied ((200 "told, answered")))
                  (list (wait-for (lambda () (eq? (client-end cl) 'eof)))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))
    ;; Only a close the client made is quiet: a waiting handler that raises
    ;; the condition itself, its client still there, has failed.
    (set! logged '())
    (let ((cl (open-client! (b "GET /raise-closed HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a waiting handler that raises &client-closed itself, its client still there, has failed: logged, and answered 500"
                  '(satisfied (500) (handler-failed))
                  (list (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))
                        (map status (responses (client-bytes cl)))
                        (map car (filter (lambda (e) (eq? (car e) 'handler-failed)) logged))))
      (client-close! cl))
    (set! leave-state #f)
    (let ((cl (open-client! (b "GET /held-wait HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (wait-for (lambda () (eq? leave-state 'waiting)))
      (client-send! cl (b "GET /second HTTP/1.1\r\nHost: x\r\n\r\n"))
      (test-equal "a request that arrives while a handler waits is held, and answered after it, in order"
                  '(satisfied ((200 "/held-wait") (200 "/second")))
                  (list (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))
    ;; A piece of a waiting handler's reader may answer no values, as an
    ;; ordinary reader's may: one that ends with a sleep does.
    (let* ((cl (open-client! (b "POST /await-none HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")))
           (waited (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
           (rs (responses (client-bytes cl))))
      (test-equal "the client of a handler that waits, whose reader's piece ends with a sleep and answers no values, reads its response"
                  '(satisfied (200 "/await-none"))
                  (list waited (if (pair? rs) (list (status (car rs)) (body (car rs))) 'no-response)))
      (client-close! cl))
    (set! logged '())
    (let ((cl (open-client! (b "GET /wait-plain HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of an ordinary handler that waits reads the stream's end" 'satisfied
               (run-turns-until loop shell (lambda () (eq? (client-end cl) 'eof)) cap))
      (test-equal "after a 500, the refusal logged as a wait on no coroutine"
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
    (let ((cl (open-client! (b "GET /await-sized HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a handler that waits and answers a sized body reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "its sized body's producer is called on a coroutine too, yielding before each piece: its length, the pieces in order"
                  '((200 "13" "one two three"))
                  (map (lambda (r) (list (status r) (field r "Content-Length") (body r)))
                       (responses (client-bytes cl))))
      (client-close! cl))

    ;; A body pulled by the handler that waits.
    (let ((cl (open-client! (b (string-append "POST /pull HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world"
                                              "POST /pull HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                              "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n")))))
      (test-equal "a body pulled, by its length and chunked: each answered, on the one connection kept"
                  '(satisfied ((200 "hello world" absent) (200 "hello world" absent)))
                  (list (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r) (field r "Connection")))
                             (responses (client-bytes cl)))))
      (client-close! cl))
    (let* ((cl (open-client! (b "POST /pull HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")))
           (got-100 (wait-for (lambda () (>= (bytevector-length (client-bytes cl)) 25))))
           (before-body (utf8->string (client-bytes cl))))
      (client-send! cl (b "hello"))
      (test-equal "a client that waits for the 100 reads it, alone, as the body is pulled, then the answer to the body it sent"
                  '(satisfied "HTTP/1.1 100 Continue\r\n\r\n" satisfied ((100 "") (200 "hello")))
                  (list got-100 before-body
                        (wait-for (lambda () (= 2 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))
    (set! logged '())
    (let ((cl (open-client! (b "POST /pull-small HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 11\r\n\r\n"))))
      (test-equal "a declared length past the pull's cap, the raise let out: 413 and no 100, the stream's end, nothing logged"
                  '(satisfied (413) ())
                  (list (wait-for (lambda () (eq? (client-end cl) 'eof)))
                        (map status (responses (client-bytes cl)))
                        (filter (lambda (e) (eq? (car e) 'handler-failed)) logged)))
      (client-close! cl))
    (set! logged '())
    (let ((cl (open-client! (b "POST /pull-own HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 11\r\n\r\n"))))
      (test-equal "a &body-failed of the handler's own, raised in place of the pull's: 413, logged handler-failed"
                  '(satisfied (413) (handler-failed))
                  (list (wait-for (lambda () (eq? (client-end cl) 'eof)))
                        (map status (responses (client-bytes cl)))
                        (map car (filter (lambda (e) (eq? (car e) 'handler-failed)) logged))))
      (client-close! cl))
    (let ((cl (open-client! (b "POST /pull-caught HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"))))
      (test-equal "a chunked body past the pull's cap, the raise caught: the handler's answer, saying Connection: close"
                  '(satisfied ((200 "caught" "close")))
                  (list (wait-for (lambda () (eq? (client-end cl) 'eof)))
                        (map (lambda (r) (list (status r) (body r) (field r "Connection")))
                             (responses (client-bytes cl)))))
      (client-close! cl))
    ;; A pull slow to take its pieces: once it holds one, the connection
    ;; reads one read more at most, then waits for it.
    (set! parked #f)
    (let* ((upload (make-bytevector wide-size 120))
           (cl (open-client! (appended
                              (b (string-append "POST /pull-held HTTP/1.1\r\nHost: x\r\nContent-Length: "
                                                (number->string wide-size) "\r\n\r\n"))
                              upload))))
      (test-equal "a pull that holds its first piece: the connection waits for it, reading stopped"
                  '(satisfied awaiting-credit)
                  (list (wait-for (lambda () (and parked (connection? (newest))
                                                  (eq? (phase (newest)) 'awaiting-credit))))
                        (let ((c (newest))) (if (connection? c) (phase c) 'no-connection))))
      (when parked (coroutine-wake! parked 'go))
      (test-equal "woken, it takes the rest: the whole body's length"
                  (list 'satisfied (list (list 200 (number->string wide-size))))
                  (list (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))
    (let ((cl (open-client! (appended
                             (b (string-append "POST /pull-port HTTP/1.1\r\nHost: x\r\nContent-Length: "
                                               (number->string wide-size) "\r\n\r\n"))
                             (make-bytevector wide-size 120)))))
      (test-equal "a MiB read whole through a port over the pull"
                  (list 'satisfied (list (list 200 (number->string wide-size))))
                  (list (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))))
      (client-close! cl))
    ;; The client leaves before the body's end: the pull raises
    ;; &client-closed, and so does the call after it.
    (set! logged '())
    (set! leave-state #f)
    (let ((cl (open-client! (b "POST /pull-leave HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello"))))
      (wait-for (lambda () (eq? leave-state 'waiting)))
      (let ((c (newest)))
        (run-loop-until loop (lambda () #f) 20)
        (client-close! cl)
        (test-equal "a pull whose client closes before the body's end: its call raises &client-closed, and the next; nothing answered or logged, the connection closed"
                    '(satisfied told-twice () closed)
                    (list (wait-for (lambda () (and (memq leave-state '(told told-twice)) (connection? c)
                                                    (not (memq c (shell-connections shell))))))
                          leave-state
                          (filter (lambda (e) (memq (car e) '(handler-failed read-error))) logged)
                          (and (connection? c) (phase c))))))
    (let ((cl (open-client! (b "POST /pull-deadline HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhel"))))
      (test-equal "a pull inside a deadline the client outlasts: the call raises &deadline-passed, the answer sent before the body's end, closing"
                  '(satisfied ((200 "passed" "close")))
                  (list (wait-for (lambda () (eq? (client-end cl) 'eof)))
                        (map (lambda (r) (list (status r) (body r) (field r "Connection")))
                             (responses (client-bytes cl)))))
      (client-close! cl))

    ;; A wait a deadline ended is let go: the pieces that come while the
    ;; handler then sleeps wake nothing and are logged as no late resume, and
    ;; its next pull takes them.
    (set! logged '())
    (set! leave-state #f)
    (let ((cl (open-client! (b "POST /pull-late HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhel"))))
      (wait-for (lambda () (eq? leave-state 'sleeping)))
      (client-send! cl (b "lo world"))
      (test-equal "a pull a deadline ended, the rest sent while its handler sleeps: no late resume, and its next pull takes the rest"
                  '(satisfied ((200 "lo world")) ())
                  (list (wait-for (lambda () (= 1 (length (responses (client-bytes cl))))))
                        (map (lambda (r) (list (status r) (body r))) (responses (client-bytes cl)))
                        (filter (lambda (e) (eq? (car e) 'late-resume)) logged)))
      (client-close! cl))
    ;; A pull begun once the shell has closed the connection, its body whole
    ;; in the core: &client-closed, and again.
    (set! waker #f)
    (set! leave-state #f)
    (let ((cl (open-client! (b "POST /pull-after HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))))
      (wait-for (lambda () (and waker (connection? (newest)))))
      (connection-close! (newest))
      (run-loop-until loop (lambda () #f) 5)
      (when waker (waker #t))
      (test-equal "a pull begun once the shell has closed the connection raises &client-closed, and again"
                  '(satisfied (client-closed client-closed))
                  (list (wait-for (lambda () (pair? leave-state))) leave-state))
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

    ;; The upload past a refusal.  A
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

    ;; Bodies, over loopback: read whole, chunked or
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

    ;; Expect: 100-continue, over loopback.  The client sends the head
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

    ;; A handler that raises.  The run loop's guard takes the raise as the
    ;; handler's failure (call-handler!), so these turn the loop as serve
    ;; does (run-turns-until), under that guard.
    (set! logged '())
    (let ((cl (open-client! (b "GET /raise HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a handler that raises reads the stream's end" 'satisfied
               (run-turns-until loop shell (lambda () (eq? (client-end cl) 'eof)) cap))
      (test-equal "after a 500" '(500) (map status (responses (client-bytes cl))))
      (test-equal "and the shell logged what the handler raised" '(handler-failed "the handler failed")
                  (let ((entry (assq 'handler-failed logged)))
                    (if (and entry (pair? (cdr entry)) (message-condition? (cadr entry)))
                        (list 'handler-failed (condition-message (cadr entry)))
                        (list 'not-logged logged))))
      (client-close! cl))
    ;; The handler's raise reaches the run loop's guard, which knows the
    ;; connection whose handler it called (call-handler!): a byte-machine
    ;; contract condition a handler raises is the handler's failure, not the
    ;; run loop's fatal one.
    (set! logged '())
    (let ((cl (open-client! (b "GET /raise-contract HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a handler that raises a contract condition reads the stream's end" 'satisfied
               (run-turns-until loop shell (lambda () (eq? (client-end cl) 'eof)) cap))
      (test-equal "after a 500, the raise logged as the handler's failure alone"
                  '((500) (handler-failed))
                  (list (map status (responses (client-bytes cl))) (map car logged)))
      (client-close! cl))
    ;; A bug in the dispatch of a handler's failure is a callback's, as a bug
    ;; in any dispatch is: logged after the failure, the connection closed,
    ;; and the run loop runs on.
    (set! logged '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /raise HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (trap! 'event 'handler-failed)
      (test-equal "when the dispatch of a handler's failure raises, its client reads the stream's end and no response, both logged, the run loop running on"
                  '(satisfied 0 (handler-failed callback-error) #t)
                  (list (run-turns-until loop shell (lambda () (eq? (client-end cl) 'eof)) cap)
                        (collector-count (client-collector cl))
                        (reverse (map car logged))
                        (closed-and-gone? shell (adopted-since before))))
      (client-close! cl))

    ;; A streamed response: a MiB in 64 pieces
    ;; of 16 KiB to a client that reads nothing yet, the connection's send
    ;; buffer small, as the slow reader's is, so the kernel holds far less
    ;; than the MiB.  The producer is asked only at or below the limits' high
    ;; water, 262,144 bytes outstanding, so the bytes outstanding never pass
    ;; it by more than one piece's write, 16,392 bytes: the size line `4000`
    ;; CRLF, the piece, CRLF.  That is the slow reader's memory bound (with
    ;; the high water ignored, the first turn asks for the whole MiB).  The first turn asks sixteen times, 262,356 bytes with the
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
                  (list 200 "chunked" (sized-text stream-pieces stream-piece-size) 'complete 65 #t)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4)
                          (stream-calls) (<= stream-most (+ 262144 16392)))))
      (client-close! cl))
    ;; Rows of 100 bytes, each a write of the core's:
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
                  (list 200 "chunked" (sized-text rows row-size) 'complete (+ rows 1) #t)
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (status r) (field r "Transfer-Encoding") (body r) (list-ref r 4)
                          (rows-calls) (<= stream-most-writes 64))))
      (client-close! cl))
    ;; The rows handed out in one bytevector, refilled at each call, as
    ;; docs/bodies.md lets a producer do.  A write the shell holds for the
    ;; turn's one libuv write is copied as it is handed over, so each row goes
    ;; out as it was then, not as the bytevector is once the turn's write is
    ;; issued.  The client reads as the rows come, so turns run whole.
    (let ((cl (open-client! (b "GET /refilled HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))))
      (test-eq "a client reads rows streamed from one bytevector refilled at each call, and the stream's end" 'satisfied
               (wait-for (lambda () (eq? (client-end cl) 'eof))))
      (test-equal "a 200, chunked, each row as it was when handed over, in order"
                  (list 200 "chunked" (sized-text rows row-size) 'complete)
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
    ;; the connection closes as a read error.  Each row's write
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
    ;; after them (RFC 9112 §6.3 rule 8), though this client asked to keep it:
    ;; the client has the body at the stream's end.
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
    ;; A sized body: its length announced, its pieces unframed, and the
    ;; connection kept, nothing logged.
    (set! logged '())
    (let ((cl (open-client! (b "GET /sized HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a sized body reads its response" 'satisfied
               (wait-for (lambda () (= 1 (length (responses (client-bytes cl)))))))
      (test-equal "a 200 with its Content-Length, the pieces in order, the connection kept, nothing logged"
                  '((200 "13" absent "one two three" complete) open ())
                  (let ((r (read-response (client-bytes cl) #f #f)))
                    (list (list (status r) (field r "Content-Length") (field r "Transfer-Encoding")
                                (body r) (list-ref r 4))
                          (client-end cl) logged)))
      (client-close! cl))
    ;; A sized body whose producer ends short: the bytes given, then the
    ;; staged close, so the client reads the stream's end short of the
    ;; length, and the shell logs the length and the bytes given.
    (set! logged '())
    (let ((cl (open-client! (b "GET /sized-short HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a sized body that ends short reads the stream's end" 'satisfied
               (wait-for (lambda () (not (eq? (client-end cl) 'open)))))
      (test-equal "its length, the bytes given, then the end: short of the length, logged with both counts"
                  '((200 "20" "one two " error) eof ((body-length-mismatch 20 8)))
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (list (status r) (field r "Content-Length") (body r) (list-ref r 4))
                          (client-end cl)
                          (filter (lambda (entry) (eq? (car entry) 'body-length-mismatch)) logged))))
      (client-close! cl))
    ;; A sized body whose producer gives a piece past its length: none of the
    ;; piece is written, so the client reads the stream's end short of the
    ;; length, and the shell logs the length and the bytes given, the piece
    ;; among them.
    (set! logged '())
    (let ((cl (open-client! (b "GET /sized-long HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of a sized body whose producer gives too much reads the stream's end" 'satisfied
               (wait-for (lambda () (not (eq? (client-end cl) 'open)))))
      (test-equal "its length, the pieces before the one past it, then the end: short of the length, logged with both counts"
                  '((200 "10" "one two " error) eof ((body-length-mismatch 10 13)))
                  (let ((r (read-response (client-bytes cl) #f #t)))
                    (list (list (status r) (field r "Content-Length") (body r) (list-ref r 4))
                          (client-end cl)
                          (filter (lambda (entry) (eq? (car entry) 'body-length-mismatch)) logged))))
      (client-close! cl))

    ;; --- how a response ended, told to what the request's code registered ---
    ;; Kept alive: the first request's procedure is told before the second's
    ;; handler is called.
    (set! done-heard '())
    (set! done-at-second 'not-called)
    (let ((cl (open-client! (b "GET /done-1 HTTP/1.1\r\nHost: x\r\n\r\nGET /done-2 HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads two responses on one connection, each request told" 'satisfied
               (wait-for (lambda () (and (= 2 (length (responses (client-bytes cl))))
                                         (= 2 (length done-heard))))))
      (test-equal "kept alive: each told written, once, the first before the second's handler is called"
                  '(((done-1 written)) ((done-1 written) (done-2 written)))
                  (list done-at-second done-heard))
      (client-close! cl))
    ;; A procedure is told from the scheduler's drain, after libuv's turn,
    ;; not inside the callback of the write that ended its response.
    (set! done-heard '())
    (let ((cl (open-client! (b "GET /done-phase HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a procedure is told from the scheduler's drain, after libuv's turn, not inside the write's callback"
                  '(satisfied ((phase scheduling)))
                  (list (wait-for (lambda () (pair? done-heard))) done-heard))
      (client-close! cl))
    ;; A procedure that raises is logged, the others still told, and the
    ;; connection goes on: the request behind it is answered.  The raise is
    ;; the run loop's guard's to take, so the loop is turned as `serve`
    ;; turns it (run-turns-until).
    (set! done-heard '())
    (set! logged '())
    (let ((cl (open-client! (b "GET /done-raise HTTP/1.1\r\nHost: x\r\n\r\nGET /done-1 HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads both responses past a procedure that raises" 'satisfied
               (run-turns-until loop shell
                                (lambda () (and (= 2 (length (responses (client-bytes cl))))
                                                (= 3 (length done-heard))))
                                cap))
      (test-equal "the others told, newest first, the raise logged on-done-failed, and the next request answered"
                  '(((third written) (first written) (done-1 written))
                    (on-done-failed "the done procedure failed")
                    (200 200))
                  (list done-heard
                        (let ((entry (assq 'on-done-failed logged)))
                          (if (and entry (pair? (cdr entry)) (message-condition? (cadr entry)))
                              (list 'on-done-failed (condition-message (cadr entry)))
                              (list 'not-logged logged)))
                        (map status (responses (client-bytes cl)))))
      (client-close! cl))
    ;; A procedure is called on no coroutine, so its wait is refused, logged
    ;; as its raise.
    (set! done-heard '())
    (set! logged '())
    (let ((cl (open-client! (b "GET /done-wait HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "a client reads the response whose procedure waits" 'satisfied
               (run-turns-until loop shell
                                (lambda () (and (= 1 (length (responses (client-bytes cl))))
                                                (pair? done-heard)))
                                cap))
      (test-equal "a wait in a procedure is refused, logged on-done-failed, and the one before it still told"
                  '(((after written)) refused)
                  (list done-heard
                        (let ((entry (assq 'on-done-failed logged)))
                          (if (and entry (pair? (cdr entry)) (scheduler-invariant? (cadr entry)))
                              'refused
                              (list 'not-refused logged)))))
      (client-close! cl))
    ;; A second shell on the loop: its procedures are told from the loop's
    ;; one drain, which the first shell's run loop turns, and a raise among
    ;; them is still the procedure's, logged on-done-failed by the second
    ;; shell, not a callback's error, the others still told.
    (set! done-heard '())
    (set! logged '())
    (let* ((second-logged '())
           (second (make-shell loop handler default-limits clock
                               (lambda (what details)
                                 (set! second-logged (cons (cons what details) second-logged)))
                               trace!))
           (to (shell-listen! second "127.0.0.1" 0))
           (listening (shell-listener second))
           (cl (open-client-to! to (b "GET /done-raise HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a second shell's procedure that raises, under the first shell's run loop: logged on-done-failed by the second shell, the others told"
                  '(satisfied ((third written) (first written)) () (on-done-failed) (200))
                  (let ((ran (run-turns-until loop shell
                                              (lambda () (and (= 1 (length (responses (client-bytes cl))))
                                                              (= 2 (length done-heard))))
                                              cap))
                        (kinds (lambda (entries)
                                 (map car (filter (lambda (e) (memq (car e) '(on-done-failed callback-error)))
                                                  entries)))))
                    (list ran done-heard (kinds logged) (kinds second-logged)
                          (map status (responses (client-bytes cl))))))
      (client-close! cl)
      (wait-for (lambda () (null? (shell-connections second))))
      (shell-shutdown! second)
      (wait-for (lambda () (eq? (uv-handle-state listening) 'closed))))
    ;; A client that leaves while a body streams: once its close reaches
    ;; the server's writes, the request is told client-closed, and its
    ;; producer is called no more.  A port the producer reads is closed
    ;; there.
    (set! done-heard '())
    (let ((cl (open-client! (b "GET /done-leave HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-eq "the client of an endless stream reads its head" 'satisfied
               (wait-for (lambda () (> (bytevector-length (client-bytes cl)) 0))))
      (client-close! cl)
      (test-eq "the client gone, the request is told" 'satisfied
               (wait-for (lambda () (pair? done-heard))))
      (let ((calls leave-calls))
        (run-loop-until loop (lambda () #f) 50)
        (test-equal "client-closed, and its producer called no more after"
                    (list '((leave client-closed)) calls)
                    (list done-heard leave-calls))))
    ;; The same with the shell's log raising as it logs the read error:
    ;; that log comes before the request's procedures in the drain, and its
    ;; raise abandons the drain, yet they are still told.
    (set! done-heard '())
    (let ((cl (open-client! (b "GET /done-leave HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a raise that abandons the drain before the procedures run still has them told"
                  '(satisfied satisfied ((leave client-closed)))
                  (let ((head (wait-for (lambda () (> (bytevector-length (client-bytes cl)) 0)))))
                    (set! log-fails 'read-error)
                    (client-close! cl)
                    (list head (run-shell-until loop shell (lambda () (pair? done-heard)) cap) done-heard)))
      (set! log-fails #f))
    ;; A close the core did not ask for, while the request's producer waits
    ;; on a coroutine: the procedure is told failed once that call ends.
    (set! done-heard '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /done-busy HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a connection closed under a producer that waits: told failed, once the producer's call has ended"
                  '(satisfied satisfied ((woke) (busy failed)))
                  (let* ((started (wait-for (lambda () busy-started)))
                         (c (adopted-since before)))
                    (when c (connection-close! c))
                    (let ((told (wait-for (lambda () (= 2 (length done-heard))))))
                      (list started told done-heard))))
      (client-close! cl))
    ;; A switch: the request is told written before its take-over is called.
    (set! done-heard '())
    (let ((cl (open-client! (door-handshake "/done-door"))))
      (test-equal "a switch: its request told written before its take-over is called"
                  '(satisfied ((door written)))
                  (let ((called (wait-for (lambda () (not (eq? done-at-take-over 'not-called))))))
                    (list called done-at-take-over)))
      (client-close! cl))
    ;; A connection the run loop drops, its handle closed behind the shell,
    ;; while its handler waits: told failed, once the handler's call ends,
    ;; and what that call answers is dropped, not written to the handle
    ;; gone.
    (set! done-heard '())
    (let* ((before (newest))
           (cl (open-client! (b "GET /done-sleeps HTTP/1.1\r\nHost: x\r\n\r\n"))))
      (test-equal "a connection the run loop drops tells its request failed, and writes nothing for it after"
                  '(satisfied satisfied ((sleeps failed)) quiet)
                  (let* ((started (wait-for (lambda () sleeps-started)))
                         (c (adopted-since before)))
                    (when c (uv-close! (connection-tcp c)))
                    (wait-for (lambda () (and c (eq? (uv-handle-state (connection-tcp c)) 'closed))))
                    (set! logged '())
                    (raise-in-callback (make-message-condition "a bug in a callback"))
                    (let ((told (wait-for (lambda () (pair? done-heard)))))
                      (list started told done-heard (if (assq 'read-error logged) 'logged 'quiet)))))
      (client-close! cl))
    ;; A reader of a handler that waits, on a shell whose bodies are capped
    ;; at 5 bytes: a chunked body passes the cap at its second piece, so the
    ;; reader is handed "abc" and the prefix "de", and the 413 is written
    ;; while it still waits inside "abc".  The procedure is told once that
    ;; call has ended, and the reader, let go as the connection lingers, is
    ;; handed nothing more.
    (set! done-heard '())
    (let* ((capped (make-shell loop handler (with 'max-body-bytes 5) clock log! trace!))
           (to (shell-listen! capped "127.0.0.1" 0))
           (listening (shell-listener capped))
           (cl (open-client-to! to (b (string-append "POST /done-reader HTTP/1.1\r\nHost: x\r\n"
                                                     "Transfer-Encoding: chunked\r\n\r\n"
                                                     "3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n")))))
      (test-equal "a reader still waiting inside a piece as its 413 is written: told failed once that piece's call ends, and handed nothing after"
                  '(satisfied (413) ((start "abc") (end "abc") (reader failed)))
                  (let ((told (wait-for (lambda () (and (= 1 (length (responses (client-bytes cl))))
                                                         (assq 'reader done-heard))))))
                    (run-loop-until loop (lambda () #f) 50)
                    (list told (map status (responses (client-bytes cl))) done-heard)))
      (client-close! cl)
      (wait-for (lambda () (null? (shell-connections capped))))
      (shell-shutdown! capped)
      (wait-for (lambda () (eq? (uv-handle-state listening) 'closed))))

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

    ;; A run of turns, as serve runs them (shell-run-turns!): one guard for
    ;; them all, set up again only after a callback's error.  The error comes
    ;; out of a turn's poll, so the turns after it must drain as before: a
    ;; request sent with it is answered.
    (set! logged '())
    (let* ((t (make-uv-timer loop)) (fired #f)
           (cl (begin
                 (uv-timer-start! t (lambda (t) (set! fired #t) (raise (make-message-condition "a bug in a callback"))) 0 0)
                 (open-client! (b "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")))))
      (test-eq "a run of turns, after an error in a callback, runs on and answers a request" 'satisfied
               (run-turns-until loop shell (lambda () (and fired (= 1 (length (responses (client-bytes cl)))))) cap))
      (test-equal "having logged the callback's error, and answered the request 200"
                  '(callback-error (200 "/after"))
                  (list (first-logged)
                        (let ((r (car (append (responses (client-bytes cl)) (list '(none "" () "" none))))))
                          (list (status r) (body r)))))
      (uv-close! t)
      (run-until loop (lambda () (eq? (uv-handle-state t) 'closed)) 8)
      (client-close! cl))
    (set! logged '())
    (let* ((t (make-uv-timer loop)) (reentrancy (provoke-reentrancy))
           (outcome (begin
                      (uv-timer-start! t (lambda (t) (raise reentrancy)) 0 0)
                      (guard (e ((byte-machine-contract-condition? e) (byte-machine-contract-condition-code e)))
                        (run-turns-until loop shell (lambda () #f) 8)))))
      (uv-close! t)
      (run-until loop (lambda () (eq? (uv-handle-state t) 'closed)) 8)
      (test-equal "a run of turns raises a contract condition again, having logged it first"
                  '(reentrancy contract-violation)
                  (list outcome (first-logged)))
      ;; Its raise came out of a turn's poll too: the turns after it drain.
      (let ((cl (open-client! (b "GET /next HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "and the next run of turns answers a request, logging nothing more"
                    '(satisfied (200 "/next") 1)
                    (list (run-turns-until loop shell (lambda () (= 1 (length (responses (client-bytes cl))))) cap)
                          (let ((r (car (append (responses (client-bytes cl)) (list '(none "" () "" none))))))
                            (list (status r) (body r)))
                          (length logged)))
        (client-close! cl)))

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

    ;; A bug once the handler has answered, in the drain after libuv's turn:
    ;; the dispatch of its answer raises, and the connection is closed as a
    ;; callback's raise closes it, the raise logged as a callback's, and the
    ;; run loop runs on.
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
      (set! logged '())
      (shell-shutdown! capped)
      (test-equal "a shutdown with no connection open closes the listener the clients used, and the server stops at once, logged"
                  '(closed stopped ((draining 0) (stopped)))
                  (begin
                    (wait-for (lambda () (eq? (uv-handle-state listening) 'closed)))
                    (list (uv-handle-state listening) (server-phase (shell-server capped))
                          (drain-logged))))
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

    ;; One timer however many connections are open: four clients that send
    ;; nothing, on a shell of their own under the default limits, so no
    ;; deadline of theirs passes while the suite looks.  The loop may hold
    ;; other shells' timers, kept stopped, so what is counted is the timers
    ;; the four add.
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
    ;; last reading plus the loop's time since.  On a shell
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

    ;; Deadlines, on a shell of their own with short limits, adopted
    ;; through the suite's listener, which records when each was adopted.
    (let ((quick (make-shell loop handler quick-limits clock log! trace!)))
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
             ;; holds of the answer is about the client's receive buffer,
             ;; which differs by platform on loopback.  The client's is left
             ;; as it is, since Darwin grows one made small after the
             ;; connect.
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

      ;; A handler that holds the loop past a deadline's length.  libuv reads
      ;; its clock once a turn, so the shell brings it up to date as it arms
      ;; each deadline, and the deadline armed after the answer runs from
      ;; then, not from before the handler ran.  Here the handler holds the
      ;; loop 300 ms, past the idle limit's 250.
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
      ;; keeps it for its next deadline.  Fifty turns of the loop, each
      ;; waiting on the wait's own 1 ms timer, span five ticks of 10 ms and
      ;; more, so a timer that ran on would fire in them.
      (let ((timer (shell-timer quick)))
        (test-equal "its wheel empty, the timer stops, firing once more at most, and the shell keeps it"
                    '(#t #t)
                    (let* ((before (firings-of quick))
                           (ran (run-loop-until loop (lambda () #f) 50)))
                      (list (<= (- (firings-of quick) before) 1)
                            (and timer (uv-timer? timer) (eq? (shell-timer quick) timer)))))

        ;; Each tick is delivered under its own guard.  Two connections
        ;; adopted in one callback share their idle deadline, so the kept
        ;; timer, started again, ticks both at one firing, the first adopted
        ;; first.  Both ticks raise, as bugs would: the first an error, the
        ;; second byte-machine's contract condition.  Each is still ticked,
        ;; and closed, and the contract condition is the one the run loop
        ;; raises again, which keeps it fatal.
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

    ;; The drain, on shells of their own under
    ;; drain-limits, adopted through the suite's listener: shell-shutdown!
    ;; stands in for the signal, which tests/test-serve.sps sends `serve`
    ;; itself.  Three clients: one idle on its keep-alive connection, one
    ;; whose handler waits on `/await`, and one that has sent half a head.
    ;; Told to finish, the idle one is closed at once; the handler, woken,
    ;; is answered, saying the connection closes, and the connection closes
    ;; once its client does; and the half head is closed at the drain's
    ;; deadline, which the trace shows met on time.  The drain then ends:
    ;; the server has stopped, logged, and the shell holds no timer.  Each
    ;; reading is bound in turn, since Chez evaluates a call's arguments in
    ;; no fixed order.
    (let ((drainer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting drainer)
      (set! parked #f)
      (set! logged '())
      (let* ((idle (open-adopted! (b "GET /idle HTTP/1.1\r\nHost: x\r\n\r\n")))
             (served (wait-for (lambda () (= 1 (length (responses (client-bytes (car idle))))))))
             (flight (open-adopted! (b "GET /await HTTP/1.1\r\nHost: x\r\n\r\n")))
             (waiting (wait-for (lambda () (and parked #t))))
             (half (open-adopted! (b "GET /half HTTP/1.1\r\nHo")))
             (heading (wait-for (lambda () (and (connection? (cdr half)) (eq? (phase (cdr half)) 'head)))))
             (phases (map (lambda (p) (if (connection? (cdr p)) (phase (cdr p)) 'none))
                          (list idle flight half))))
        (test-equal "before the shutdown: a keep-alive client served, a handler waiting, half a head read"
                    '(satisfied satisfied satisfied (idle handling head))
                    (list served waiting heading phases))
        (shell-shutdown! drainer)
        (let* ((idle-gone (wait-for (lambda () (closed-and-gone? drainer (cdr idle)))))
               (half-open (list (client-end (car half)) (and (memq (cdr half) (shell-connections drainer)) #t)))
               (idle-ended (wait-for (lambda () (not (eq? (client-end (car idle)) 'open))))))
          (test-equal "told to finish, an idle keep-alive connection is closed at once, with no response, while the half head is still open"
                      '(satisfied (open #t) satisfied (200) eof (disarm-deadline close))
                      (list idle-gone half-open idle-ended (map status (responses (client-bytes (car idle))))
                            (client-end (car idle)) (last-verbs (cdr idle) 2))))
        (when parked (coroutine-wake! parked 'woken))
        (let* ((answered (wait-for (lambda () (and (= 1 (length (responses (client-bytes (car flight)))))
                                                   (not (eq? (client-end (car flight)) 'open))))))
               (rs (responses (client-bytes (car flight)))))
          (test-equal "a request in flight is answered, saying the connection closes, then its client reads the stream's end"
                      '(satisfied (200 "close") eof)
                      (list answered
                            (if (pair? rs) (list (status (car rs)) (field (car rs) "Connection")) 'no-response)
                            (client-end (car flight)))))
        (client-close! (car flight))
        (let ((gone (wait-for (lambda () (closed-and-gone? drainer (cdr flight))))))
          (test-equal "and the connection closes once its client does, before the drain's deadline asks for anything"
                      '(satisfied never-forced)
                      (list gone (drain-forced drainer))))
        (let* ((gone (wait-for (lambda () (closed-and-gone? drainer (cdr half)))))
               (ended (wait-for (lambda () (not (eq? (client-end (car half)) 'open))))))
          (test-equal "a client that holds its connection is closed at the drain's deadline, with no response, on time"
                      '(satisfied satisfied () eof on-time)
                      (list gone ended (map status (responses (client-bytes (car half))))
                            (client-end (car half)) (drain-forced drainer))))
        (test-equal "the drain ends with its last connection: the server has stopped, logged, and the shell holds no timer"
                    '(stopped ((draining 3) (drain-timeout) (stopped)) #f)
                    (list (server-phase (shell-server drainer)) (drain-logged) (shell-timer drainer)))
        (for-each (lambda (p) (client-close! (car p))) (list idle flight half))
        (set! parked #f)))

    ;; A drain whose only connection is held in its handler: the core arms
    ;; no deadline there, so the shell's wheel is empty, and
    ;; the next firing of its timer stops it, which may come before the
    ;; handler is seen waiting.  Once it has, the shutdown: the timer is
    ;; started again and runs on, telling the server the time, until the
    ;; deadline closes the connection.
    (let ((parker (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting parker)
      (set! parked #f)
      (set! logged '())
      (let* ((p (open-adopted! (b "GET /await HTTP/1.1\r\nHost: x\r\n\r\n")))
             (waiting (wait-for (lambda () (and parked #t))))
             (armed (shell-deadlines parker))
             (stopped (wait-for (lambda () (fired-since-emptied? parker (cdr p))))))
        (shell-shutdown! parker)
        (let* ((gone (wait-for (lambda () (closed-and-gone? parker (cdr p)))))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "a connection held in its handler, nothing armed, the timer stopped, is closed at the drain's deadline, on time"
                      '(satisfied 0 satisfied satisfied satisfied () eof on-time)
                      (list waiting armed stopped gone ended (map status (responses (client-bytes (car p))))
                            (client-end (car p)) (drain-forced parker))))
        (test-equal "and that drain ends: stopped, logged"
                    '(stopped ((draining 1) (drain-timeout) (stopped)))
                    (list (server-phase (shell-server parker)) (drain-logged)))
        (client-close! (car p))
        (set! parked #f)))

    ;; A client that never reads its answer, a write outstanding when the
    ;; drain's deadline closes its connection: the write the close cancels
    ;; is no transport failure, and nothing logs a read error.
    (let ((stalled (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting stalled)
      (set! logged '())
      (let* ((p (begin (set! small-send-buffer 4096) (open-adopted! #f #f)))
             (c (cdr p)))
        (set! small-send-buffer #f)
        (client-send! (car p) (b "GET /wide HTTP/1.1\r\nHost: x\r\n\r\n"))
        (let ((writing (wait-for (lambda () (and (connection? c) (eq? (phase c) 'responding))))))
          (shell-shutdown! stalled)
          (let ((gone (wait-for (lambda () (closed-and-gone? stalled c)))))
            (test-equal "a client that never reads its answer is closed at the drain's deadline, on time, and the write the close cancels logs no read error"
                        '(satisfied satisfied on-time ((draining 1) (drain-timeout) (stopped)) #f)
                        (list writing gone (drain-forced stalled) (drain-logged)
                              (and (assq 'read-error logged) #t)))))
        (client-close! (car p))))

    ;; A connection the run loop drops during a drain, its handle closed
    ;; behind the shell so its close never reports back, is a close the
    ;; server is told of: the drain ends, before its deadline.
    (let ((dropper (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting dropper)
      (set! logged '())
      (let* ((p (open-adopted! (b "GET /kept HTTP/1.1\r\nHost: x\r\n\r\n")))
             (served (wait-for (lambda () (= 1 (length (responses (client-bytes (car p))))))))
             (c (cdr p)))
        (when (connection? c) (uv-close! (connection-tcp c)))
        (wait-for (lambda () (and (connection? c) (eq? (uv-handle-state (connection-tcp c)) 'closed))))
        (shell-shutdown! dropper)
        (let* ((draining (server-phase (shell-server dropper)))
               (outcome (raise-in-callback (make-message-condition "a bug in a callback") dropper))
               (stopped (server-phase (shell-server dropper))))
          (test-equal "a connection the run loop drops during a drain, its handle closed behind the shell, ends it as a close does"
                      '(satisfied draining ran-on stopped ((draining 1) (stopped)))
                      (list served draining outcome stopped (drain-logged))))
        (client-close! (car p))))
    (set! adopting shell)

    ;; A shutdown is dated by the loop's time brought up to date as it is
    ;; asked for, as a deadline is armed: one asked once the loop has been
    ;; held 300 ms dates its drain after the hold.  The hold is timed by the
    ;; loop's clock, read on a loop of its own, so the bound is exact, and
    ;; the suite's loop keeps its time from before the hold, which a
    ;; shutdown dated without bringing it up to date reads.  300 ms of
    ;; Chez's monotonic clock can be fewer than 300 of the loop's, by tens
    ;; on Linux, whose loop clock is CLOCK_MONOTONIC_COARSE.
    (let ((late (make-shell loop handler drain-limits clock log! trace!)))
      (uv-update-time! loop)
      (let ((before (uv-now loop)))
        (hold-until! (+ before slow-ms))
        (shell-shutdown! late)
        (let ((asked (find (lambda (e) (and (eq? (car e) 'shutdown) (eq? (cadr e) late))) timed)))
          (test-equal "a shutdown asked once the loop has been held 300 ms dates its drain after the hold"
                      '(#t stopped)
                      (list (and asked (>= (- (caddr asked) before) slow-ms) #t)
                            (server-phase (shell-server late)))))))

    ;; Told to finish, each connection is told under its own guard, as each
    ;; is ticked: one whose dispatch raises is closed, the rest are still
    ;; told, and once all have been, the first raise goes on to the caller.
    ;; Both raise here, each its own condition, so both are closed by their
    ;; raises, and the drain ends with them, before its deadline.
    (let ((told (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting told)
      (set! logged '())
      (let* ((x (open-adopted! (b "GET /x HTTP/1.1\r\nHost: x\r\n\r\n")))
             (y (open-adopted! (b "GET /y HTTP/1.1\r\nHost: x\r\n\r\n")))
             (served (wait-for (lambda () (for-all (lambda (p) (= 1 (length (responses (client-bytes (car p))))))
                                                   (list x y))))))
        (trap! 'event 'shutdown-requested)
        (trap! 'event 'shutdown-requested (make-message-condition "a second bug"))
        (let* ((raised (guard (e ((message-condition? e) (condition-message e)))
                         (shell-shutdown! told)
                         'nothing-raised))
               (unspent (length traps))
               (gone (wait-for (lambda () (for-all (lambda (p) (closed-and-gone? told (cdr p))) (list x y))))))
          (set! traps '())
          (test-equal "when telling each connection to finish raises, each is still told and closed, the first raise goes on, and the drain ends before its deadline"
                      '(satisfied "a bug in the shell" 0 satisfied stopped ((draining 2) (stopped)))
                      (list served raised unspent gone (server-phase (shell-server told)) (drain-logged))))
        (for-each (lambda (p) (client-close! (car p))) (list x y))))
    (set! adopting shell)

    ;; A shell asked to watch the process's signals holds a signal handle
    ;; for SIGTERM and one for SIGINT, watches once,
    ;; while it listens, and closes them once it serves no more.  No signal
    ;; is sent here: tests/test-serve.sps sends them to `serve`'s process.
    (let ((watcher (make-shell loop handler drain-limits clock log! trace!)))
      (shell-watch-signals! watcher)
      (let* ((signals (shell-signals watcher))
             (opened (map (lambda (h) (and (uv-signal? h) (uv-handle-state h))) signals))
             (again (guard (e ((assertion-violation? e) 'refused))
                      (shell-watch-signals! watcher)
                      'watched-again)))
        (shell-shutdown! watcher)
        (let ((closed (wait-for (lambda () (for-all (lambda (h) (eq? (uv-handle-state h) 'closed)) signals)))))
          (test-equal "a shell that watches signals holds two signal handles, watches once, and closes them once it serves no more"
                      '((open open) refused satisfied)
                      (list opened again closed)))))
    (let ((stopped (make-shell loop handler drain-limits clock log! trace!)))
      (shell-shutdown! stopped)
      (test-equal "a shell that has stopped is refused a watch, and holds no signal handle"
                  '(refused ())
                  (let ((watched (guard (e ((assertion-violation? e) 'refused))
                                   (shell-watch-signals! stopped)
                                   'watched)))
                    (list watched (shell-signals stopped)))))

    ;; The door, through a real socket.  A client sends
    ;; a WebSocket handshake and, with it, a frame, as one write: the switch
    ;; is answered 101, and the taker, handed the stream, writes back what it
    ;; was handed and then what it reads, so the client reads the 101 and the
    ;; frame back whether the kernel delivered the frame with the handshake
    ;; or after it (never asserting how the stream was split).
    ;; A second frame comes back the same way; the client's end reaches the
    ;; taker, which closes, the close told to it once.
    (set! took '())
    (let* ((p (open-adopted! (joined (list (door-handshake "/door") hello-frame))))
           (c (cdr p))
           (back (wait-for (lambda () (>= (bytevector-length (client-bytes (car p)))
                                          (+ (bytevector-length door-101) (bytevector-length hello-frame))))))
           (first-read (client-bytes (car p))))
      (test-equal "through the door: the 101, then the frame sent with the handshake, written back, the connection handed off"
                  (list 'satisfied (joined (list door-101 hello-frame)) 'handed-off)
                  (list back first-read (if (connection? c) (phase c) 'none)))
      (client-send! (car p) hi-frame)
      (let ((again (wait-for (lambda () (= (bytevector-length (client-bytes (car p)))
                                           (+ (bytevector-length first-read) (bytevector-length hi-frame)))))))
        (client-shut! (car p))
        (let* ((gone (wait-for (lambda () (closed-and-gone? shell c))))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "a frame sent later comes back after it; the client's end reaches the taker, which closes, told once; the core ends closed"
                      (list 'satisfied (joined (list door-101 hello-frame hi-frame)) 'satisfied 'satisfied 'eof
                            '((eof)) '(()) 'closed)
                      (list again (client-bytes (car p)) gone ended (client-end (car p))
                            (took-of 'ended) (took-of 'closed) (if (connection? c) (phase c) 'none)))))
      (client-close! (car p)))

    ;; The stream reads nothing between the hand-off and the taker's
    ;; read-start, so what the client sends after the 101 waits for the
    ;; taker.  A waiting taker that starts reading after a sleep of door-ms:
    ;; the client sends a frame once it has the 101, inside the sleep, and
    ;; gets it back once the taker reads.  As the frame is sent, the stream
    ;; is handed off and the taker has not started reading, so the window is
    ;; the one played, not one a slow turn skipped.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-read-later")))
           (c (cdr p))
           (heard (wait-for (lambda () (>= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-send! (car p) hello-frame)
      (let* ((at-send (list (phase c) (took-of 'read-start)))
             (back (wait-for (lambda () (>= (bytevector-length (client-bytes (car p)))
                                            (+ (bytevector-length door-101) (bytevector-length hello-frame)))))))
        (client-shut! (car p))
        (let ((gone (wait-for (lambda () (closed-and-gone? shell c)))))
          (test-equal "a waiting taker that starts reading after a sleep reads what its client sent once it had the 101: sent before its read-start, the frame comes back, then the client's end closes the stream"
                      (list 'satisfied '(handed-off ()) 'satisfied (joined (list door-101 hello-frame)) 'satisfied '((eof)))
                      (list heard at-send back (client-bytes (car p)) gone (took-of 'ended)))))
      (client-close! (car p)))

    ;; A client's end read while the 101 is written, a client that reads
    ;; nothing keeping it outstanding (door-pad): the core hands the end
    ;; over, and the taker reading in its take-over is told eof from it, its
    ;; reads not started again, so no end is read for it; its close at the
    ;; end closes the stream.
    ;; Told on a later turn, not in the read-start's call; and a taker that
    ;; closes in its take-over, after its read-start, is told nothing, not
    ;; even by the calls deferred to the next turn.
    (for-each
     (lambda (closes?)
       (set! took '())
       (set! door-closes-early closes?)
       (let* ((p (open-adopted! (door-handshake "/door-ended-early") #f))
              (c (cdr p)))
         (client-shut! (car p))
         (let ((ended (wait-for (lambda () (and (member (list c 'event 'eof) traced) #t)))))
           (client-read! (car p))
           (let ((gone (wait-for (lambda () (closed-and-gone? shell c)))))
             ;; The close can complete in the turn the take-over ran in,
             ;; before the next turn's drain: what was deferred to it is
             ;; made now, as `serve` makes it once its server has stopped.
             (shell-call-deferred! shell)
             (test-equal (if closes?
                             "a client's end read while the 101 is written, the taker closing in its take-over: it is told nothing, with no read for it, and the stream closes"
                             "a client's end read while the 101 is written: the taker reading in its take-over is told eof on a later turn, with no read for it, and its close closes the stream")
                         (list 'satisfied 'satisfied '((0)) (if closes? '() '((eof))) 0)
                         (list ended gone (took-of 'told-in-take-over) (took-of 'ended)
                               (length (filter (lambda (e) (and (eq? (car e) c) (eq? (cadr e) 'door) (eq? (caddr e) 'stream-end)))
                                               traced))))))
         (client-close! (car p))))
     '(#f #t))
    (set! door-closes-early #f)

    ;; Once told its end, a taker that starts reading again is told nothing
    ;; more: libuv's reads are not started again, so the end is not read
    ;; again.  Its deadline then closes the stream.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-reads-again")))
           (c (cdr p))
           (heard (wait-for (lambda () (>= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-shut! (car p))
      (let ((gone (wait-for (lambda () (closed-and-gone? shell c)))))
        (test-equal "a taker told its end that starts reading again is told nothing more, then its deadline closes the stream"
                    (list 'satisfied 'satisfied '((eof)) '(()))
                    (list heard gone (took-of 'ended) (took-of 'passed))))
      (client-close! (car p)))

    ;; A taker that raises as it takes the stream: logged, and the stream
    ;; closed after the 101, as a bug closes its connection.
    (set! logged '())
    (let* ((p (open-adopted! (door-handshake "/door-raise")))
           (gone (wait-for (lambda () (closed-and-gone? shell (cdr p)))))
           (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
      (test-equal "a taker that raises: logged taker-failed, the stream closed after the 101"
                  (list 'satisfied 'satisfied door-101 'eof '(taker-failed))
                  (list gone ended (client-bytes (car p)) (client-end (car p))
                        (map car (filter (lambda (e) (eq? (car e) 'taker-failed)) logged))))
      (client-close! (car p)))

    ;; A taker that waits: its take-over answers `awaiting`,
    ;; and the thunk, on a coroutine, waits for each read, which the read
    ;; callback resumes it with, and writes it back.  The client's end has
    ;; the taker close the stream, and the wait the thunk is in is told: it
    ;; notes the close and lets it out, which logs nothing.
    (set! took '())
    (set! logged '())
    (let* ((p (open-adopted! (door-handshake "/door-wait")))
           (opened (wait-for (lambda () (= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-send! (car p) hi-frame)
      (let ((echoed (wait-for (lambda () (= (bytevector-length (client-bytes (car p)))
                                             (+ (bytevector-length door-101) (bytevector-length hi-frame)))))))
        (client-shut! (car p))
        (let* ((gone (wait-for (lambda () (closed-and-gone? shell (cdr p)))))
               (told (wait-for (lambda () (pair? (took-of 'told))))))
          (test-equal "a taker that waits: its thunk, on a coroutine, writes back each read it waits for; the client's end closes the stream, its wait is told, and letting that out logs nothing"
                      (list 'satisfied 'satisfied (joined (list door-101 hi-frame)) 'satisfied 'satisfied '(()) '())
                      (list opened echoed (client-bytes (car p)) gone told (took-of 'told)
                            (filter (lambda (e) (eq? (car e) 'taker-failed)) logged)))))
      (client-close! (car p)))

    ;; A waiting taker woken with a read's bytes: once it waits for the next
    ;; read, nothing keeps the piece it was woken with, which it wrote back
    ;; and let go.
    (set! woken #f)
    (set! woken-waits #f)
    (let* ((p (open-adopted! (door-handshake "/door-woken")))
           (opened (wait-for (lambda () (= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-send! (car p) hi-frame)
      (let* ((echoed (wait-for (lambda () (and woken-waits
                                                (= (bytevector-length (client-bytes (car p)))
                                                   (+ (bytevector-length door-101) (bytevector-length hi-frame)))))))
             (kept (if woken (state-after-collection woken) 'never-woken)))
        (client-shut! (car p))
        (let ((gone (wait-for (lambda () (closed-and-gone? shell (cdr p))))))
          (client-close! (car p))
          (test-equal "a waiting taker woken with a read's bytes, written back, keeps none of them once it waits for the next read; the client's end closes the stream"
                      '(satisfied satisfied released satisfied) (list opened echoed kept gone)))))

    ;; A waiting taker whose thunk raises anything else: logged
    ;; taker-failed, and the stream closed after the 101.
    (set! logged '())
    (let* ((p (open-adopted! (door-handshake "/door-wait-raise")))
           (gone (wait-for (lambda () (closed-and-gone? shell (cdr p)))))
           (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
      (test-equal "a waiting taker whose thunk raises: logged taker-failed, the stream closed after the 101"
                  (list 'satisfied 'satisfied door-101 'eof '(taker-failed))
                  (list gone ended (client-bytes (car p)) (client-end (car p))
                        (map car (filter (lambda (e) (eq? (car e) 'taker-failed)) logged))))
      (client-close! (car p)))

    ;; A waiting taker whose thunk ends leaves the stream as it was: open,
    ;; its taker reading on and writing back what it reads.
    (set! took '())
    (set! logged '())
    (let* ((p (open-adopted! (door-handshake "/door-wait-ends")))
           (ended (wait-for (lambda () (pair? (took-of 'thunk-ended))))))
      (client-send! (car p) hi-frame)
      (let ((echoed (wait-for (lambda () (= (bytevector-length (client-bytes (car p)))
                                             (+ (bytevector-length door-101) (bytevector-length hi-frame)))))))
        (test-equal "a waiting taker whose thunk ends: the stream stays open, its taker writing back what it reads, nothing logged"
                    (list 'satisfied 'satisfied (joined (list door-101 hi-frame)) 'handed-off '())
                    (list ended echoed (client-bytes (car p)) (if (connection? (cdr p)) (phase (cdr p)) 'none)
                          (filter (lambda (e) (eq? (car e) 'taker-failed)) logged))))
      (client-close! (car p)))
    ;; And one whose thunk ends with no values, as one whose last call is a
    ;; sleep may, or with two: what it returns is dropped, so the same.
    (let ((ending
           (lambda (target)
             (set! took '())
             (set! logged '())
             (let* ((p (open-adopted! (door-handshake target)))
                    (ended (wait-for (lambda () (pair? (took-of 'thunk-ended))))))
               (client-send! (car p) hi-frame)
               (let* ((echoed (wait-for (lambda () (or (not (eq? (client-end (car p)) 'open))
                                                       (= (bytevector-length (client-bytes (car p)))
                                                          (+ (bytevector-length door-101) (bytevector-length hi-frame)))))))
                      (seen (list ended echoed (client-end (car p)) (client-bytes (car p))
                                  (if (connection? (cdr p)) (phase (cdr p)) 'none)
                                  (filter (lambda (e) (eq? (car e) 'taker-failed)) logged))))
                 (client-close! (car p))
                 seen)))))
      (test-equal "a waiting taker whose thunk ends with no values, or with two: no failure, the stream stays open, its taker writing back what it reads, nothing logged"
                  (let ((open (list 'satisfied 'satisfied 'open (joined (list door-101 hi-frame)) 'handed-off '())))
                    (list open open))
                  (list (ending "/door-wait-no-values") (ending "/door-wait-two-values"))))

    ;; A write asked for once the close has been is not written: its
    ;; callback is told ECANCELED, and the close waits for the write before
    ;; it, which the client reads.  From here on, a client that reads a
    ;; taker's close closes in turn (closed-by-client), which ends the
    ;; stream's linger.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-late")))
           (gone (closed-by-client shell p))
           (told (wait-for (lambda () (pair? (took-of 'late)))))
           (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
      (test-equal "the taker's close follows its write; a write after the close is cancelled, its callback told so"
                  (list 'satisfied 'satisfied 'satisfied (joined (list door-101 (b "bye"))) 'eof '((ECANCELED)))
                  (list gone told ended (client-bytes (car p)) (client-end (car p)) (took-of 'late)))
      (client-close! (car p)))

    ;; The taker's close waits for its write: 4 MiB, more than the socket
    ;; takes at once, so the write is still under way as the close is asked
    ;; for.  Its client reads all of it, then the stream's end.
    (let* ((p (open-adopted! (door-handshake "/door-big")))
           (gone (closed-by-client shell p))
           (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
      (test-equal "the taker's close waits for a write still under way: its client reads all of it, then the stream's end"
                  (list 'satisfied 'satisfied 'eof #t)
                  (list gone ended (client-end (car p))
                        (equal? (client-bytes (car p)) (joined (list door-101 big-door)))))
      (client-close! (car p)))

    ;; Through a client that reads nothing (door-unread): a
    ;; close waits for the 4 MiB under way, a deadline asked for then passes,
    ;; and its call's abort closes the stream at once, the write told
    ;; ECANCELED, its close call once, nothing logged.  And a raise in the
    ;; deadline's call does the same, logged taker-failed, as the fake shell
    ;; has it.
    (test-equal "a close waiting on a write the client reads nothing of: a deadline asked for then passes, and its abort closes the stream at once, the write told ECANCELED, its close call once, nothing logged"
                '(adopted satisfied satisfied satisfied ((ECANCELED)) (()) ())
                (door-unread "/door-bound"))
    (test-equal "a raise in a deadline's call, a write under way to a client that reads nothing: logged taker-failed, the stream closed at once, the write told ECANCELED"
                '(adopted satisfied satisfied satisfied ((ECANCELED)) (()) (taker-failed))
                (door-unread "/door-bound-raise"))

    ;; A write libuv refuses at the call, the stream's write side shut behind
    ;; the shell's back: its callback is told the errno after the turn, as a
    ;; failed write's would be at its completion (libuv's uv_write refuses a
    ;; stream it cannot write to with EPIPE at the call).
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-shut")))
           (told (wait-for (lambda () (pair? (took-of 'refused)))))
           (gone (wait-for (lambda () (closed-and-gone? shell (cdr p))))))
      (test-equal "a write refused at the call: its callback is told the errno, and the taker's close closes the stream"
                  '(satisfied satisfied ((EPIPE)))
                  (list told gone (took-of 'refused)))
      (client-close! (car p)))

    ;; A taker that stops reading reads nothing more until it starts again:
    ;; a frame sent while it is stopped waits, through fifty turns of the
    ;; loop, and is read once reading starts again, then the client's end.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-pause")))
           (switched (wait-for (lambda () (>= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-send! (car p) hello-frame)
      (let ((first (wait-for (lambda () (pair? (took-of 'paused-read))))))
        (client-send! (car p) hi-frame)
        (let* ((stopped (run-loop-until loop (lambda () #f) 50))
               (read-while-stopped (bytevector-length (read-bytes 'paused-read))))
          (test-equal "a taker that stops reading reads nothing more while it is stopped"
                      (list 'satisfied 'satisfied 'iterations-exhausted #t)
                      (list switched first stopped (<= read-while-stopped (bytevector-length hello-frame))))
          (transport-read-start! paused-transport
                                 (lambda (bv from to) (took! 'resumed (bytes-between bv from to)))
                                 (lambda (why) (took! 'ended why) (transport-close! paused-transport)))
          (let ((resumed (wait-for (lambda () (= (+ (bytevector-length (read-bytes 'paused-read))
                                                    (bytevector-length (read-bytes 'resumed)))
                                                 (+ (bytevector-length hello-frame) (bytevector-length hi-frame)))))))
            (client-shut! (car p))
            (let ((gone (wait-for (lambda () (closed-and-gone? shell (cdr p))))))
              (test-equal "started again, it reads what waited, then the client's end"
                          (list 'satisfied 'satisfied (joined (list hello-frame hi-frame)) '((eof)))
                          (list resumed gone (joined (list (read-bytes 'paused-read) (read-bytes 'resumed)))
                                (took-of 'ended)))))))
      (client-close! (car p)))
    (set! paused-transport #f)

    ;; A write chez-libuv refuses for no transport's failure, from a thread
    ;; that is not the loop's (`&uv-wrong-thread`), raises to its caller and
    ;; leaves nothing outstanding, so the taker's close still closes the
    ;; stream.
    (set! thread-transport #f)
    (set! thread-raised #f)
    (let* ((p (open-adopted! (door-handshake "/door-thread")))
           (taken (wait-for (lambda () (and thread-transport #t)))))
      (fork-thread (lambda ()
                     (set! thread-raised
                           (guard (e (#t e))
                             (transport-write! thread-transport (b "elsewhere"))
                             'returned))))
      (let ((raised (wait-for (lambda () (and thread-raised #t)))))
        (transport-close! thread-transport)
        (let* ((gone (closed-by-client shell p))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "a write refused off the loop's thread raises to its caller, and leaves the taker's close free to close"
                      (list 'satisfied 'satisfied #t 'satisfied 'satisfied door-101 'eof)
                      (list taken raised (uv-wrong-thread? thread-raised) gone ended
                            (client-bytes (car p)) (client-end (car p))))))
      (client-close! (car p)))
    (set! thread-transport #f)

    ;; Reading started again while it reads takes the new callbacks: a frame
    ;; comes back once, from the second, and the first hears nothing.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-twice")))
           (switched (wait-for (lambda () (>= (bytevector-length (client-bytes (car p))) (bytevector-length door-101))))))
      (client-send! (car p) hello-frame)
      (let ((back (wait-for (lambda () (>= (bytevector-length (client-bytes (car p)))
                                           (+ (bytevector-length door-101) (bytevector-length hello-frame)))))))
        (client-shut! (car p))
        (let* ((gone (wait-for (lambda () (closed-and-gone? shell (cdr p)))))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "reading started again while it reads: the second callbacks take the reads, the first hears nothing"
                      (list 'satisfied 'satisfied 'satisfied 'satisfied (joined (list door-101 hello-frame)) '())
                      (list switched back gone ended (client-bytes (car p)) (took-of 'first-reader)))))
      (client-close! (car p)))

    ;; A taken stream keeps its place in max-connections: with a cap of one,
    ;; a second client is refused while the first's stream is taken, and
    ;; accepted once it has closed.
    (let ((capped (make-shell loop handler (with 'max-connections 1) clock log! trace!)))
      (set! adopting capped)
      (set! took '())
      (set! logged '())
      (let* ((p (open-adopted! (door-handshake "/door")))
             (taken (wait-for (lambda () (and (connection? (cdr p)) (eq? (phase (cdr p)) 'handed-off)))))
             (q (open-client! #f))
             (refused (wait-for (lambda () (not (eq? (client-end q) 'open))))))
        (test-equal "a taken stream counts against max-connections: a second client is refused while it is open, reading the stream's end and nothing"
                    '(satisfied satisfied eof 0 ((refusing max-connections)) 1)
                    (list taken refused (client-end q) (collector-count (client-collector q))
                          (filter (lambda (e) (eq? (car e) 'refusing)) logged)
                          (length (shell-connections capped))))
        (client-shut! (car p))
        (let* ((gone (wait-for (lambda () (closed-and-gone? capped (cdr p)))))
               (r (open-client! (b "GET /third HTTP/1.1\r\nHost: x\r\n\r\n")))
               (served (wait-for (lambda () (= 1 (length (responses (client-bytes r))))))))
          (test-equal "and once it has closed, the next client is served"
                      '(satisfied satisfied (200))
                      (list gone served (map status (responses (client-bytes r)))))
          (client-close! r))
        (client-close! q)
        (client-close! (car p)))
      (shell-shutdown! capped)
      (set! adopting shell))

    ;; A taker's deadline rides the shell's wheel: met the first time the
    ;; timer fires at or after it, as a connection's are.  The
    ;; taker arms it as its first read comes, once the timer has stopped:
    ;; the hand-off took the connection's last deadline out of the wheel, and
    ;; the next firing found it empty, which may come before the hand-off is
    ;; seen.  The taker notes the loop's time as the arm left it, the time
    ;; the deadline counts from: the arm brings the loop's time up to date,
    ;; and the time its turn read can be milliseconds older under load.
    (let ((timed-shell (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting timed-shell)
      (set! took '())
      (let* ((p (open-adopted! (door-handshake "/door-timed")))
             (taken (wait-for (lambda () (and (connection? (cdr p)) (eq? (phase (cdr p)) 'handed-off)))))
             (stopped (wait-for (lambda () (fired-since-emptied? timed-shell (cdr p)))))
             (quiet (firings-of timed-shell))
             (idle (run-loop-until loop (lambda () #f) 30))
             (still (firings-of timed-shell))
             (sent (begin (client-send! (car p) hello-frame) 'sent))
             (passed (wait-for (lambda () (pair? (took-of 'passed)))))
             (gone (closed-by-client timed-shell p))
             (armed (let ((a (took-of 'armed))) (and (pair? a) (car (car a)))))
             (at (let ((a (took-of 'passed))) (and (pair? a) (car (car a)))))
             (fires (map caddr (filter (lambda (e) (and (eq? (car e) 'fire) (eq? (cadr e) timed-shell)))
                                       (reverse timed)))))
        (test-equal "a taker's deadline, armed with the timer stopped, passes the first time the timer fires at or after it, once"
                    '(satisfied satisfied iterations-exhausted #t satisfied satisfied #t #t 1)
                    (list taken stopped idle (= quiet still) passed gone
                          (and armed at (memv at fires) (<= (+ armed door-ms) at) #t)
                          (and armed at (not (exists (lambda (f) (and (<= (+ armed door-ms) f) (< f at))) fires)))
                          (length (took-of 'passed))))
        (client-close! (car p)))
      (shell-shutdown! timed-shell)
      (set! adopting shell))

    ;; A taker's deadline disarmed leaves none armed, so an idle server's
    ;; timer can stop.
    (let ((disarmer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting disarmer)
      (set! took '())
      (let* ((p (open-adopted! (door-handshake "/door-disarm")))
             (done (wait-for (lambda () (pair? (took-of 'disarmed))))))
        (test-equal "a taker's deadline is the stream's one entry in the wheel, and disarmed leaves none"
                    '(satisfied ((1)) ((0)) satisfied)
                    (list done (took-of 'armed) (took-of 'disarmed)
                          (closed-by-client disarmer p)))
        (client-close! (car p)))
      (shell-shutdown! disarmer)
      (set! adopting shell))

    ;; A taker's deadline is armed at the loop's time brought up to date, as
    ;; a connection's is: a taker that holds the loop 300 ms
    ;; by libuv's clock as it takes the stream, the loop's time left where
    ;; its turn read it, arms a deadline of a minute after the hold.  Each
    ;; side failing answers what it read.
    (let ((holder (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting holder)
      (set! took '())
      (let* ((p (open-adopted! (door-handshake "/door-held")))
             (done (wait-for (lambda () (pair? (took-of 'held)))))
             (seen (let ((h (took-of 'held))) (if (pair? h) (car h) '(#f #f #f))))
             (stale (car seen))
             (unrefreshed (cadr seen))
             (deadline (caddr seen)))
        (test-equal "a taker that holds the loop 300 ms as it takes the stream arms its deadline after the hold, at the loop's time brought up to date"
                    '(satisfied stale after-the-hold satisfied)
                    (list done
                          (if (and stale (eqv? unrefreshed stale)) 'stale unrefreshed)
                          (if (and stale deadline (>= (- deadline 60000 stale) slow-ms))
                              'after-the-hold
                              (and stale deadline (- deadline 60000 stale)))
                          (closed-by-client holder p)))
        (client-close! (car p)))
      (shell-shutdown! holder)
      (set! adopting shell))

    ;; A taker's close is staged, as the server's own are.  A taker that fails a client still sending writes its
    ;; close and closes: the client reads the close, then the stream's end,
    ;; not a reset, and its 4 MiB all go out, read and dropped, none of it
    ;; the taker's.  The stream lingers until the client closes, and its close
    ;; call runs then, once.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-fail")))
           (c (cdr p))
           (switched (wait-for (lambda () (>= (bytevector-length (client-bytes (car p))) (bytevector-length door-101)))))
           (sent (client-wrote (car p) client-flood))
           (ended (wait-for (lambda () (and (not (eq? (client-end (car p)) 'open)) (not (eq? (sent) 'pending))))))
           (state (lingering? shell c))
           (told-before (took-of 'closed)))
      (client-close! (car p))
      (let ((gone (wait-for (lambda () (closed-and-gone? shell c)))))
        (test-equal "a taker that fails a client still sending: the client reads the close and the stream's end, its 4 MiB read and dropped, none of it the taker's; the stream lingers until the client closes, its close call run then, once"
                    (list 'satisfied 'satisfied (joined (list door-101 close-frame)) 'eof 'no-error
                          'lingering '() 'satisfied '(()) #t)
                    (list switched ended (client-bytes (car p)) (client-end (car p)) (sent)
                          state told-before gone (took-of 'closed)
                          (let ((f (took-of 'failed)))
                            (and (pair? f) (= (car (car f)) (apply + (map car (took-of 'read))))))))))

    ;; A client whose end comes while the close's writes are under way has
    ;; nothing more to send: the stream closes once they are out, with no
    ;; linger.  The client reads nothing until it has ended, so the taker's
    ;; 4 MiB wait for it, as door-unread's do.
    (set! small-send-buffer 4096)
    (let* ((before (newest))
           (cl (open-client! (door-handshake "/door-big") #f))
           (taken (wait-for (lambda () (let ((c (adopted-since before))) (and c (eq? (phase c) 'handed-off))))))
           (c (adopted-since before)))
      (set! small-send-buffer #f)
      (client-shut! cl)
      (run-loop-until loop (lambda () #f) 20)
      (client-read! cl)
      (let* ((gone (wait-for (lambda () (closed-and-gone? shell c))))
             (ended (wait-for (lambda () (not (eq? (client-end cl) 'open))))))
        (test-equal "a client that ends while the close's writes are under way: it reads them all, then the stream's end, and the stream closes once they are out, with no linger"
                    (list 'satisfied 'satisfied 'satisfied 'eof #t)
                    (list taken gone ended (client-end cl)
                          (equal? (client-bytes cl) (joined (list door-101 big-door))))))
      (client-close! cl))

    ;; The linger's bound: a client that reads the
    ;; close and never closes is closed at the linger deadline, armed once
    ;; the close's writes are out, linger-timeout-ms past then, and met the
    ;; first time the timer fires at or after it.  It takes the place of the
    ;; deadline the taker armed before its close, whose call never runs.
    (let ((lingerer (make-shell loop handler linger-limits clock log! trace!)))
      (set! adopting lingerer)
      (set! took '())
      (let* ((p (open-adopted! (door-handshake "/door-bye")))
             (c (cdr p))
             (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open)))))
             (armed (and (connection? c) (connection-deadline c)))
             (gone (wait-for (lambda () (closed-and-gone? lingerer c))))
             (closing (let ((e (took-of 'closing))) (and (pair? e) (car (car e)))))
             (closed-at (let ((e (find (lambda (e) (and (eq? (car e) 'closed) (eq? (cadr e) c))) timed)))
                          (and e (caddr e))))
             (fires (map caddr (filter (lambda (e) (and (eq? (car e) 'fire) (eq? (cadr e) lingerer)))
                                       (reverse timed))))
             (first-fire (and armed (find (lambda (f) (>= f armed)) fires))))
        (test-equal "a client that reads the close and never closes: closed at the linger deadline, armed once the writes are out, met the first time the timer fires at or after it; the taker's deadline it replaced never passes"
                    '(satisfied eof satisfied #t #t #t ())
                    (list ended (client-end (car p)) gone
                          (and armed closing (>= armed (+ closing 100)) #t)
                          (and armed closed-at (>= closed-at armed) #t)
                          (and first-fire closed-at (<= (- closed-at first-fire) 10) #t)
                          (took-of 'passed)))
        (client-close! (car p)))
      (shell-shutdown! lingerer)
      (set! adopting shell))

    ;; Once a taker has asked to close, each write it waits
    ;; for has write-timeout-ms, 300 here, from the loop's time brought up
    ;; to date, as the server's own writes have; past it the stream is
    ;; aborted.  The taker's own deadline still runs beside it, the earlier
    ;; first.  Each client here reads nothing (the server's send buffer is
    ;; 4 KiB), but /door-rearm's, which reads from 150 ms after the close
    ;; until the first write is out, the send buffer 1 MiB from then, so that
    ;; write is out in a few milliseconds.
    (let ((bounder (make-shell loop handler bound-limits clock log! trace!)))
      (define (bounded target before)
        (set! took '())
        (set! logged '())
        (set! adopting bounder)
        (set! small-send-buffer 4096)
        (let* ((p (open-adopted! (door-handshake target) #f))
               (c (cdr p))
               (noted (wait-for (lambda () (pair? (took-of 'closing)))))
               (closing (let ((e (took-of 'closing))) (and (pair? e) (car (car e))))))
          (set! small-send-buffer #f)
          (before p closing)
          (let* ((gone (wait-for (lambda () (closed-and-gone? bounder c))))
                 (closed-at (let ((e (find (lambda (e) (and (eq? (car e) 'closed) (eq? (cadr e) c))) timed)))
                              (and e (caddr e))))
                 (seen (list gone
                             (map (lambda (w) (list (car w) (cadr w))) (took-of 'written))
                             (took-of 'closed)
                             (map car (filter (lambda (e) (eq? (car e) 'taker-failed)) logged))
                             (and closing closed-at (- closed-at closing))
                             (map (lambda (e) (- (car e) closing)) (took-of 'passed))
                             (let ((w (find (lambda (w) (eqv? (car w) 1)) (took-of 'written))))
                               (and w closing (- (caddr w) closing))))))
            (set! reading-client #f)
            (client-close! (car p))
            (when (and (connection? c) (not (closed-and-gone? bounder c)))
              (connection-close! c)
              (wait-for (lambda () (closed-and-gone? bounder c))))
            seen)))
      (define (nothing p closing) #f)
      (define (bound-met? seen from)
        (and (list-ref seen 4) from (>= (list-ref seen 4) (+ from 300)) #t))
      (let ((seen (bounded "/door-unbounded" nothing)))
        (test-equal "a close waiting on a write the client reads nothing of, the taker arming no deadline: aborted at the write timeout from the close, the write told ECANCELED, its close call once, nothing logged"
                    '(satisfied ((1 ECANCELED)) (()) () #t)
                    (list (car seen) (cadr seen) (caddr seen) (cadddr seen) (bound-met? seen 0))))
      (let ((seen (bounded "/door-rearm"
                           (lambda (p closing)
                             (wait-for (lambda () (>= (uv-now loop) (+ closing 150))))
                             (when (connection? (cdr p))
                               (uv-send-buffer-size! (connection-tcp (cdr p)) (* 1024 1024)))
                             (set! reading-client (car p))
                             (client-read! (car p))))))
        (test-equal "each write it waits for has the write timeout: a first write out 150 ms or more after the close moves the bound to 300 ms past it, where the second is aborted"
                    '(satisfied ((1 #f) (2 ECANCELED)) (()) #t #t)
                    (list (car seen) (cadr seen) (caddr seen)
                          (and (list-ref seen 6) (>= (list-ref seen 6) 150) #t)
                          (bound-met? seen (list-ref seen 6)))))
      (let ((seen (bounded "/door-own-first" nothing)))
        (test-equal "a taker's own deadline, earlier, runs first, and its call, which does not abort, leaves the bound armed: aborted at the write timeout"
                    '(satisfied ((1 ECANCELED)) (()) #t 1 #t)
                    (list (car seen) (cadr seen) (caddr seen)
                          (bound-met? seen 0)
                          (length (list-ref seen 5))
                          (and (pair? (list-ref seen 5)) (>= (car (list-ref seen 5)) 100) #t))))
      (let ((seen (bounded "/door-own-later" nothing)))
        (test-equal "a taker's own deadline later than the bound: aborted at the write timeout, the taker's call never made"
                    '(satisfied ((1 ECANCELED)) (()) #t ())
                    (list (car seen) (cadr seen) (caddr seen)
                          (and (bound-met? seen 0) (< (list-ref seen 4) 600) #t)
                          (list-ref seen 5))))
      ;; The bound is armed at the loop's time brought up to date, as the
      ;; linger's is: a taker that holds the loop
      ;; 300 ms by libuv's clock, then closes behind a write the client reads
      ;; nothing of, has its bound armed after the hold.
      (set! took '())
      (set! small-send-buffer 4096)
      (let* ((p (open-adopted! (door-handshake "/door-held-bound") #f))
             (c (cdr p))
             (done (wait-for (lambda () (pair? (took-of 'held)))))
             (seen (let ((h (took-of 'held))) (if (pair? h) (car h) '(#f #f #f))))
             (stale (car seen))
             (unrefreshed (cadr seen))
             (deadline (caddr seen)))
        (set! small-send-buffer #f)
        (let ((gone (wait-for (lambda () (closed-and-gone? bounder c)))))
          (test-equal "a taker that holds the loop 300 ms, then closes behind a write the client reads nothing of: the bound armed after the hold, at the loop's time brought up to date, and met"
                      '(satisfied stale after-the-hold satisfied)
                      (list done
                            (if (and stale (eqv? unrefreshed stale)) 'stale unrefreshed)
                            (if (and stale deadline (>= (- deadline 300 stale) slow-ms))
                                'after-the-hold
                                (and stale deadline (- deadline 300 stale)))
                            gone)))
        (client-close! (car p))
        (when (and (connection? c) (not (closed-and-gone? bounder c)))
          (connection-close! c)
          (wait-for (lambda () (closed-and-gone? bounder c)))))
      (shell-shutdown! bounder)
      (set! adopting shell))

    ;; The linger deadline is armed at the loop's time brought up to date: a
    ;; taker that holds the loop 300 ms by libuv's clock, then closes with
    ;; nothing to write, has its stream's linger armed after the hold.  Each side failing answers what it read.
    (set! took '())
    (let* ((p (open-adopted! (door-handshake "/door-held-close")))
           (done (wait-for (lambda () (pair? (took-of 'held)))))
           (seen (let ((h (took-of 'held))) (if (pair? h) (car h) '(#f #f #f))))
           (stale (car seen))
           (unrefreshed (cadr seen))
           (deadline (caddr seen))
           (linger (limits-linger-timeout-ms default-limits)))
      (test-equal "a taker that holds the loop 300 ms, then closes with nothing to write: the linger deadline armed after the hold, at the loop's time brought up to date"
                  '(satisfied stale after-the-hold satisfied)
                  (list done
                        (if (and stale (eqv? unrefreshed stale)) 'stale unrefreshed)
                        (if (and stale deadline (>= (- deadline linger stale) slow-ms))
                            'after-the-hold
                            (and stale deadline (- deadline linger stale)))
                        (closed-by-client shell p)))
      (client-close! (car p)))

    ;; A lingering stream is the server's: a deadline the
    ;; taker asks for then is not armed, nor is its cancel, and its read-stop
    ;; leaves the stream reading, so a client's 4 MiB still go out, read and
    ;; dropped.  Its abort still closes the stream at once.
    (set! took '())
    (set! lingering-transport #f)
    (let* ((p (open-adopted! (door-handshake "/door-bye")))
           (c (cdr p))
           (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open)))))
           (armed (and (connection? c) (connection-deadline c))))
      (transport-deadline! lingering-transport 1 (lambda () (took! 'late-passed)))
      (let ((after-arm (and (connection? c) (connection-deadline c))))
        (transport-deadline! lingering-transport #f)
        (let ((after-cancel (and (connection? c) (connection-deadline c))))
          (transport-read-stop! lingering-transport)
          (let* ((sent (client-wrote (car p) client-flood))
                 (written (wait-for (lambda () (not (eq? (sent) 'pending)))))
                 (state (lingering? shell c)))
            (transport-abort! lingering-transport)
            (let ((gone (wait-for (lambda () (closed-and-gone? shell c)))))
              (test-equal "once a stream lingers, a deadline asked for is not armed, nor its cancel, and a read-stop leaves it reading: a client's 4 MiB go out, dropped; an abort then closes it at once, its close call once"
                          (list 'satisfied #t #t #t 'satisfied 'no-error 'lingering 'satisfied '(()) '())
                          (list ended (and armed #t) (eqv? after-arm armed) (eqv? after-cancel armed)
                                written (sent) state gone (took-of 'closed) (took-of 'late-passed)))))))
      (client-close! (car p)))
    (set! lingering-transport #f)

    ;; The drain tells a taken stream and waits: the
    ;; taker's drain call says goodbye and closes, and the drain ends then,
    ;; before its deadline.  One that ignores the drain is closed at the
    ;; deadline, on time, its close told to it.
    (let ((door-drainer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting door-drainer)
      (set! took '())
      (set! logged '())
      (let* ((p (open-adopted! (door-handshake "/door")))
             (taken (wait-for (lambda () (and (connection? (cdr p)) (eq? (phase (cdr p)) 'handed-off))))))
        (shell-shutdown! door-drainer)
        (let* ((gone (closed-by-client door-drainer p))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "told the server drains, a taker says goodbye and closes; the drain ends then, before its deadline"
                      (list 'satisfied 'satisfied 'satisfied (joined (list door-101 (b "bye"))) 'eof
                            '(()) 'never-forced 'stopped '((draining 1) (stopped)))
                      (list taken gone ended (client-bytes (car p)) (client-end (car p))
                            (took-of 'drained) (drain-forced door-drainer)
                            (server-phase (shell-server door-drainer)) (drain-logged))))
        (client-close! (car p))))
    (let ((deaf-drainer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting deaf-drainer)
      (set! took '())
      (set! logged '())
      (let* ((p (open-adopted! (door-handshake "/door-deaf")))
             (taken (wait-for (lambda () (and (connection? (cdr p)) (eq? (phase (cdr p)) 'handed-off))))))
        (shell-shutdown! deaf-drainer)
        (let* ((gone (wait-for (lambda () (closed-and-gone? deaf-drainer (cdr p)))))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "a taker that ignores the drain has its stream closed at the deadline, on time, its close told to it"
                      (list 'satisfied 'satisfied 'satisfied door-101 'eof '(()) 'on-time
                            '((draining 1) (drain-timeout) (stopped)))
                      (list taken gone ended (client-bytes (car p)) (client-end (car p))
                            (took-of 'closed) (drain-forced deaf-drainer) (drain-logged))))
        ;; Its close call, run once the stream has closed, writes, reads and
        ;; arms a deadline: the write is cancelled, told after the turn, and
        ;; the read and the deadline are not begun, so they report nothing,
        ;; however long the loop runs on.  It ends with no values, which the
        ;; shell drops: its callbacks return one to chez-libuv.
        (let* ((told (wait-for (lambda () (pair? (took-of 'after-close)))))
               (from (uv-now loop))
               (later (wait-for (lambda () (>= (uv-now loop) (+ from 30))))))
          (test-equal "on a stream the server has closed, a write is cancelled, reading and a deadline begin nothing, and a close call registered then runs at once"
                      '(satisfied satisfied ((ECANCELED)) () () (()))
                      (list told later (took-of 'after-close) (took-of 'late-end) (took-of 'late-passed)
                            (took-of 'closed-late))))
        (client-close! (car p))))
    ;; A drain call runs once: one its taker registers again while the
    ;; server drains, from inside the first, is not run.
    (let ((redrainer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting redrainer)
      (set! took '())
      (let* ((p (open-adopted! (door-handshake "/door-redrain")))
             (taken (wait-for (lambda () (and (connection? (cdr p)) (eq? (phase (cdr p)) 'handed-off))))))
        (shell-shutdown! redrainer)
        (let ((gone (wait-for (lambda () (closed-and-gone? redrainer (cdr p))))))
          (test-equal "a drain call runs once: one registered again while the server drains is not run"
                      '(satisfied satisfied (()) ())
                      (list taken gone (took-of 'drained) (took-of 'drained-again))))
        (client-close! (car p))))
    ;; A switch answered while the server drains: the taker's drain call,
    ;; registered as it takes the stream, runs at once.
    (let ((late-drainer (make-shell loop handler drain-limits clock log! trace!)))
      (set! adopting late-drainer)
      (set! took '())
      (set! parked #f)
      (let* ((p (open-adopted! (door-handshake "/door-await")))
             (waiting (wait-for (lambda () (and parked #t)))))
        (shell-shutdown! late-drainer)
        (when parked (coroutine-wake! parked 'woken))
        (let* ((gone (closed-by-client late-drainer p))
               (ended (wait-for (lambda () (not (eq? (client-end (car p)) 'open))))))
          (test-equal "a switch answered while the server drains: its taker's drain call runs as it is registered"
                      (list 'satisfied 'satisfied 'satisfied (joined (list door-101 (b "bye"))) '(()) 'never-forced)
                      (list waiting gone ended (client-bytes (car p)) (took-of 'drained)
                            (drain-forced late-drainer))))
        (client-close! (car p))
        (set! parked #f)))
    (set! adopting shell)

    ;; Backpressure on the read side, on a shell of its own with the short
    ;; limits, made on credit, as a handler that waits is handed a reader's
    ;; pieces.  A client sends a 64 KiB body at once to `/credit`:
    ;; handed a read's pieces, its reader makes reading wait for its credit,
    ;; so the connection has no deadline armed, and its shell's wheel is
    ;; empty.  The timer then stops, firing once more at
    ;; most, while the connection stays, and a wait past the body deadline's
    ;; 175 ms answers nothing: the server, not the client, is the one waiting.
    ;; Credited each time it waits, the reader is handed the rest a read at a
    ;; time.  The body's bytes count up modulo 251, so their order shows.
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

    ;; A lookup, against what uv-getaddrinfo! itself answers; names libuv
    ;; refuses at the call, empty, with a NUL, or over 255 octets; and one the
    ;; resolver refuses itself, with a network or without: EAI_NONAME.
    (let* ((oracle (looked-up loop "localhost" cap))
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

    ;; An idle connection carries no coroutine:
    ;; once `/noted` is answered, each call into its code made on a
    ;; coroutine and each waiting, and its connection is idle, a full
    ;; collection leaves none of the coroutines it ran on, nor what their
    ;; waits kept of them, which the request's notice points to: the notice
    ;; goes with the request.  The instrument is the weak pair's, calibrated
    ;; above.
    (set! noted '())
    (set! noted-waits '())
    ;; Each reading is bound in turn: the collection comes after the wait.
    (let* ((cl (open-client! (b "POST /noted HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")))
           (waited (wait-for (lambda () (and (= 1 (length (responses (client-bytes cl))))
                                             (connection? (newest)) (eq? (phase (newest)) 'idle)))))
           (rs (responses (client-bytes cl)))
           (kinds (fold-left (lambda (kinds e) (if (memq (car e) kinds) kinds (append kinds (list (car e)))))
                             '() (reverse noted)))
           (held (map car (filter (lambda (e) (eq? (state-after-collection (cdr e)) 'held))
                                  (reverse noted))))
           (held-waits (map car (filter (lambda (e) (and (car (cdr e)) (eq? (state-after-collection (cdr e)) 'held)))
                                        (reverse noted-waits)))))
      (test-equal "a connection idle after its handler, its reader and its producer waited holds none of the coroutines they ran on, nor what their waits kept of them"
                  '(satisfied (200 "one two") (thunk piece end producer) () ())
                  (list waited (if (pair? rs) (list (status (car rs)) (body (car rs))) 'no-response) kinds held
                        held-waits))
      (client-close! cl))

    ;; A shell that serves no more closes the timer of its loop's waits,
    ;; which have nothing armed: the next sleep on the loop makes another.
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
