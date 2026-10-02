#!r6rs
;;; (http-server private shell) — the direct libuv shell (design §5.2; M4.2).
;;;
;;; The core is pure (decision 0002); this is where its actions happen.  A
;;; SHELL holds what every connection on one loop shares: the handler, the
;;; limits, the clock and the Date line made from it, the log, and the
;;; connection table.  A CONNECTION is one accepted TCP handle, the core's
;;; state in the adapter's context, a parser on the adapter's one binding
;;; list, and the closures chez-libuv calls, each of which turns what
;;; happened into one of the core's events and dispatches it (decision 0003
;;; item 1).  None runs application code but the handler's call, its
;;; reader's and its producer's, and none captures a continuation.
;;;
;;; THE MESSAGE LOOP is the fake shell's (design §4.5).  Actions run after the
;;; outermost dispatch, in order, from one queue; a dispatch made while the
;;; queue drains, or while the parser feeds, only queues.  Once the queue is
;;; empty, the drain sends the writes held (WRITE BATCHING, below), and runs
;;; on while that queues more.  `depth` counts the drain and a feed inside
;;; it.  An action run anywhere but the outermost drain is a VIOLATION,
;;; recorded (design §6.4, the second hazard):
;;; byte-machine poisons a parser whose callback escapes, and chez-libuv
;;; defers the raise, so the one action answered inside a parser callback is
;;; `reply-parser`, which the adapter answers without reaching the queue.
;;;
;;; THE ACTIONS, performed:
;;;   feed-parser     parser-feed!, counted in the depth and in the phase
;;;                   'in-parser (the scheduler's, below), then its result
;;;                   as `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler called after libuv's turn, from the
;;;                   scheduler's drain (decision 0014): its answer, a
;;;                   response or a reader, as `handler-responded`, or, if
;;;                   the handler raises, `handler-failed`, logged; or, if
;;;                   it answers `awaiting`, its thunk run on a coroutine
;;;                   and the thunk's answer as `handler-responded`, on
;;;                   credit (A HANDLER THAT WAITS, below)
;;;   deliver-body    the piece to the reader the core is handing the body to
;;;                   (conn-body-reader; decision 0013), or, if it raises,
;;;                   `handler-failed`, logged; with no reader, nothing
;;;   deliver-body-end  the reader's end: its response as `handler-responded`,
;;;                   or, if it raises, `handler-failed`, logged
;;;   notify-producer the producer a streamed response is written from
;;;                   (conn-producer; decision 0013 item 8), called for its
;;;                   next piece, the drain's first call once the writes held
;;;                   have gone out (WRITE BATCHING): its answer as
;;;                   `handler-body-chunk` or `handler-body-end`
;;;                   (producer-event), or, if it raises or answers neither,
;;;                   `handler-failed`, logged; with no producer, nothing
;;;   write           the segments, the Date slot filled from the clock
;;;                   (decision 0010): held for the turn's one write if under
;;;                   4,096 bytes (WRITE BATCHING, below), or else one
;;;                   uv-write*! of their own; the completion reports
;;;                   `write-completed` with the action's byte count, which
;;;                   is all it keeps: a held write's bytes were copied as it
;;;                   was held, and chez-libuv copies the segments at the call
;;;                   (design §7.3), a span of a bytevector, `(bv start end)`,
;;;                   among them
;;;   read-stop/-start  uv-read-stop! and uv-read-start!, when reading
;;;                   changes; the first start, at adoption, fixes the read
;;;                   buffer at the limits' read-buffer-size (design §7.2)
;;;   shutdown        uv-shutdown!, the write side (decision 0011), after the
;;;                   writes held; its completion reports `shutdown-completed`
;;;   close           connection-close!, through handle-close! (below), after
;;;                   the writes held; the close's callback takes the
;;;                   connection out of the table and reports `closed`
;;;   log             the shell's log
;;;   arm-deadline    the connection's entry in the wheel, at the loop's now
;;;                   plus the kind's limit (below)
;;;   disarm-deadline its entry taken out of the wheel
;;; The hand-off (M8) is never asked for in v1's flow.  A shell made on
;;; credit (M6.2) answers with each handler's answer and `credit`, and a
;;; streaming reader's credit reaches the core through
;;; connection-body-credit!, which no action asks for.  v1's server never
;;; makes one: the checks do, standing in for M7's coroutine shell, which
;;; hands a reader its pieces on credit.
;;;
;;; DEADLINES (decision 0005 and its amendments of 2026-09-27; M5.3).  The
;;; shell keeps the deadlines of its connections in one wheel, (http-server
;;; wheel), in which each connection keeps one entry, made as it is adopted.
;;; A deadline is armed at the loop's now, `uv_now`, which never steps, plus
;;; the kind's limit (limits-deadline-ms), never by the wall clock the Date
;;; is made from.  The first is armed as the connection is adopted, its idle
;;; one: the core starts it in idle with that deadline recorded, and asks
;;; for the next ones.  libuv reads the loop's clock once a turn, and what
;;; runs in the turn holds the loop, a handler above all, so the shell
;;; brings the clock up to date (uv-update-time!, chez-libuv #28) as it
;;; adopts a connection, and before each arm and each write, whose Date the
;;; loop's time dates: in run!, ahead of the action's trace.  Like every
;;; chez-libuv verb the shell calls, uv-update-time! is refused off the
;;; loop's thread (`&uv-wrong-thread`), and the shell runs only on it
;;; (decision 0003).  ONE TIMER TICKS THEM ALL, every tick-ms: made when a
;;; deadline is first armed, stopped by the first firing that finds the
;;; wheel empty, so an idle server sleeps (0005), started again by the next
;;; arm, and closed once the shell has stopped listening and no connection
;;; is left.  Each time it fires, the wheel is advanced to the loop's now,
;;; each connection whose deadline has passed is ticked, `(tick now)`, and
;;; the server is told the time, as its events say (design §4.6).  A
;;; connection is ticked the first time the timer fires at or after its
;;; deadline: never before it, and within tick-ms of it when the loop runs
;;; on time.  A connection that leaves with no step of the core, closed by
;;; handle-close! or dropped by the reconciliation, is taken out of the
;;; wheel there, and one closing is armed no more.
;;;
;;; THE LISTENER is the server's (design §4.6; M4.3): `server-step` decides,
;;; and the shell performs.  Each connection the listener takes is offered to
;;; the server with the count of connections open, the table's size, and is
;;; served, or refused and closed at once: none is left waiting on the
;;; listener, and none left open with no one to close it.  A shutdown, or a
;;; listener that fails, closes the listener, and a shell whose server has
;;; stopped listening never listens again.
;;;
;;; ONE PROCEDURE CLOSES EVERY HANDLE: handle-close!, the one uv-close! call
;;; (tests/test-close-ownership.sps reads the source to hold it), for a
;;; connection's handle, the listener, and one the server refused.  What a
;;; close does follows the handle, not the caller: chez-libuv runs the
;;; callback of a handle's first close alone, and every close passes the same
;;; one, so a connection's close takes it out of the table and reports
;;; `closed` whoever asked for it.
;;;
;;; WRITE BATCHING (decided on the owner's word, by form, 2026-09-29; design
;;; §7.3).  A write under 4,096 bytes is held: its bytes are copied at once,
;;; behind those held before it, into the connection's chunks, each new one
;;; twice the last's length or the write's, so none is copied again.  What
;;; is held goes out as one write once the drain has emptied the queue, and
;;; first when the core asks for a shutdown or a close, or writes 4,096
;;; bytes or more, so the bytes keep the order the core wrote them in.  So a
;;; turn's small pieces of a streamed response, up to 64 (M6.3's second
;;; review), are one write request of libuv's, where each was one, with its
;;; `uv_write_t` and its completion.  What is held goes out too before the
;;; drain first calls a producer, so a stream's head never waits for its
;;; pieces: a producer slow to make them delays them, a turn at a time, but
;;; not the head.  The copy is made as a write is held, not as the turn's
;;; write is issued: a producer may hand out one bytevector again, refilled
;;; (handlers.org).  A larger write is copied by chez-libuv at the call, as
;;; every write was before.  The completion reports `write-completed` for
;;; each write it carried, with its byte count, in the order written.
;;;
;;; A TRANSPORT FAILURE IS A `read-error` (design §6.3): a read's error, and a
;;; write's or a shutdown's, whether chez-libuv raises it at the call or
;;; reports it at the completion.  A failed write is settled too, as
;;; `write-completed` with each byte count it carried, once the one
;;; `read-error` has closed the connection; the core settles a write a close
;;; cut short in `closing` (M3.3).  A write the close itself cancels is
;;; reported the same way.
;;;
;;; A BUG CLOSES ITS CONNECTION.  Whatever raises out of a connection's
;;; outermost dispatch drops the actions still queued, and the writes held,
;;; and one of them may have been the close, or the read that would have seen
;;; the client go: the connection is closed before the raise goes on to
;;; chez-libuv and the run loop.  An adoption that fails is closed the same
;;; way.
;;;
;;; THE DATE is made once a second (decision 0010).  The shell's clock is read
;;; when a second of the loop's own time has passed, libuv's milliseconds,
;;; brought up to date before the write (DEADLINES, above); between readings
;;; the second is the last reading plus the loop's time since.  So a
;;; response reads the shell's clock once a second at most.
;;;
;;; THE SCHEDULER (decisions 0003 and 0014; design §5.2; M7.1).  Each loop
;;; has one, (http-server private scheduler)'s, made by the first shell on
;;; it and shared by every shell on it: its turn is its drain and then one
;;; uv-run of the loop, the poll.  A connection's handler is called from
;;; that drain, after libuv's turn: a turn's requests are all read before
;;; any is answered, and no handler runs inside a libuv callback.  A run
;;; loop turns it, `shell-turn!`, which guards the turn as the run loop
;;; guards a run (below), taking whatever the drain raises, where no
;;; chez-libuv catches it, as a callback's raise; `loop-turn!` turns it with
;;; no guard.  A handler whose connection has closed before the drain
;;; reaches its call is not called.
;;;
;;; A HANDLER THAT WAITS (decision 0014; M7.1) answers `(awaiting thunk)`,
;;; (http-server awaiting)'s.  The thunk runs on a coroutine of its own, so
;;; it may wait, and what it returns is the answer, dispatched on credit,
;;; once it has ended, from the drain: a response or a reader, or awaiting
;;; again, which waits again; a raise is `handler-failed`, logged.  Until
;;; the next request's handler is called, the connection's calls into the
;;; handler's code, its reader's pieces and end and its producer, are each
;;; made on a coroutine too, one at a time, in order (call-waiting!), each
;;; event its call brings dispatched from the drain once it has ended: a
;;; streaming reader's piece is credited once the reader has taken it, so
;;; reading waits while it does (M6.2).  Every other reader and producer is
;;; called in place, as in v1.  Code on those coroutines waits with
;;; (http-server private waits)'s verbs (decision 0015; M7.2): the loop's
;;; scheduler keeps the loop's waits, made with the log of the first shell
;;; on the loop, which records a late resume as `late-resume` (R4), and
;;; given the loop's clock and a timer of their own for the sleeps and
;;; deadlines, one a loop, closed with the tick timer by a shell that serves
;;; no more (loop-clock!).  A wait goes on when its connection
;;; closes (0015 item 4): what it then answers is dropped, and the
;;; connection makes no more calls.
;;;
;;; THE RUN LOOP (design §6.4, the first hazard; decision 0003 item 4).
;;; chez-libuv catches whatever a callback raises, and raises it again from
;;; uv-run composed with `&uv-callback-error`; a raise out of the drain, a
;;; handler call's dispatch, is taken as one.  A `&byte-machine-contract` in
;;; it is a bug that has poisoned a parser: logged, the table reconciled, and
;;; raised again.  Any other callback error is logged, the table reconciled,
;;; and the loop runs on.  `&byte-machine-contract` derives from `&condition`,
;;; not `&error`, but the composition makes every callback's raise an
;;; `&error`, so what keeps a poisoned parser fatal is that its arm comes
;;; before the callback-error arm.  The run loop's own logging cannot take the
;;; failure's place: a log that raises there is ignored.
(library (http-server private shell)
  (export make-shell shell? shell-listen! shell-adopt! shell-shutdown! shell-run! shell-turn!
          loop-turn!
          shell-connections shell-server shell-listener shell-timer shell-deadlines
          shell-waits-timed
          connection? connection-state connection-tcp connection-violations
          connection-deadline
          connection-close! connection-body-credit!
          wall-clock)
  (import (rnrs)
          (only (chezscheme) current-time time-second time-nanosecond make-ephemeron-eq-hashtable)
          (libuv)
          (byte-machine runtime)
          (only (byte-machine private conditions) byte-machine-contract-condition?)
          (only (http-server connection) make-conn-state conn-body-reader conn-producer producer-event)
          (only (http-server body) body-reader-on-piece body-reader-on-end body-reader-whole?)
          (only (http-server awaiting) awaiting? awaiting-thunk)
          (only (http-server limits)
                limits-read-buffer-size limits-backlog limits-tick-ms limits-deadline-ms)
          (http-server wheel)
          (only (http-server private scheduler)
                make-scheduler scheduler-turn! scheduler-call! scheduler-spawn!
                scheduler-phase scheduler-feed-begin! scheduler-feed-end! scheduler-waits)
          (only (http-server private waits) make-waits waits-clock! waits-fire! waits-timed)
          (only (http-server server) make-server-state server-step server-phase)
          (only (http-server serializer) date-line)
          (http-server private adapter))

  ;; make-shell :
  ;;   UvLoop (Request -> Response) Limits (-> Nat) (Symbol (Listof Any) -> Any)
  ;;   [(U #f (Connection Symbol Any -> Any)) [Boolean]] -> Shell
  ;; A shell on `loop`: the handler every connection calls, the limits every
  ;; connection is held to and the server's cap and backlog, the clock
  ;; (milliseconds since the epoch, read at most once a second for the
  ;; Date), and the log, called with what happened and its details.  It
  ;; serves what it is offered (shell-adopt!), and listens when it is asked
  ;; to (shell-listen!).  The optional trace is called with each event a
  ;; connection dispatches and each action it runs, as (connection 'event
  ;; datum) and (connection 'action datum), and with each event the server
  ;; steps and each action of its the shell performs, as (shell 'server-event
  ;; datum) and (shell 'server-action datum).  The datum is the event or the
  ;; action itself, not a copy: a trace that keeps it keeps what it holds, a
  ;; response's body among them.  Made `on-credit?`, the shell answers with
  ;; each handler's answer and `credit`, `(handler-responded answer credit)`
  ;; (M6.2): a streaming reader it answers then owes credit for the pieces
  ;; it is handed, and reading waits for connection-body-credit!.
  ;; shell? : Any -> Boolean
  ;; shell-server : Shell -> ServerState — the server's state (design §4.6)
  ;; shell-listener : Shell -> (U #f UvTcp)
  ;;   the listener the shell last made, open or closed, or #f if none
  ;; shell-timer : Shell -> (U #f UvTimer)
  ;;   the one timer that ticks its connections' deadlines, running or
  ;;   stopped, from the first deadline armed until the shell has stopped
  ;;   listening and has no connection left; #f before and after
  ;; The limits' tick-ms is its wheel's bucket, and one below 1 is an
  ;; assertion violation (make-wheel's).
  (define-record-type (shell %make-shell shell?)
    (fields loop handler limits clock log trace on-credit? table wheel scheduler
            waits-kept                         ; the box of its loop's waits' timer (loop-clock!)
            (mutable server)
            (mutable listener)
            (mutable timer) (mutable ticking?)  ; the timer, and whether it runs
            (mutable read-at) (mutable read-ms)       ; the clock's last reading, and when
            (mutable date-second) (mutable date-line)))

  (define make-shell
    (case-lambda
      ((loop handler limits clock log) (make-shell loop handler limits clock log #f #f))
      ((loop handler limits clock log trace) (make-shell loop handler limits clock log trace #f))
      ((loop handler limits clock log trace on-credit?)
       (let* ((s (loop-scheduler loop log))
              (kept (hashtable-ref waits-timers loop #f)))
         (%make-shell loop handler limits clock log trace (and on-credit? #t) (make-eq-hashtable)
                      (make-wheel (limits-tick-ms limits)) s kept
                      (make-server-state 'listening 0 limits) #f #f #f #f #f #f #f)))))

  ;; loop-scheduler : UvLoop [(Symbol (Listof Any) -> Any)] -> Scheduler
  ;; The loop's scheduler, made the first time it is asked for: its poll is
  ;; one uv-run of the loop.  Asked for with `log`, by a shell, it keeps the
  ;; loop's waits, made with the first such log (A HANDLER THAT WAITS, the
  ;; header).  Kept in an ephemeron table, so a loop let go takes its
  ;; scheduler with it, though the scheduler's poll holds the loop.
  (define schedulers (make-ephemeron-eq-hashtable))
  (define loop-scheduler
    (case-lambda
      ((loop)
       (or (hashtable-ref schedulers loop #f)
           (let ((s (make-scheduler (lambda (mode) (uv-run loop mode)))))
             (hashtable-set! schedulers loop s)
             s)))
      ((loop log)
       (let ((s (loop-scheduler loop)))
         (unless (scheduler-waits s) (loop-clock! loop (make-waits s log)))
         s))))

  ;; loop-clock! : UvLoop Waits -> Void
  ;; Give the loop's waits the loop's clock, brought up to date each time it
  ;; is read, as the shell's deadlines are (DEADLINES, the header), and a
  ;; timer of their own, made the first time it is started, whose callback
  ;; fires them.  Like the tick timer, it is stopped while they have nothing
  ;; armed, so an idle loop sleeps, and closed by a shell on the loop that
  ;; serves no more (release-waits-timer!).  It is kept in `waits-timers`,
  ;; the loop's, as `#(timer)`, or `#(#f)` while it has none.
  (define waits-timers (make-ephemeron-eq-hashtable))
  (define (loop-clock! loop w)
    (let ((kept (vector #f))
          (fire (lambda (t) (waits-fire! w))))
      (hashtable-set! waits-timers loop kept)
      (waits-clock! w
                    (lambda () (uv-update-time! loop) (uv-now loop))
                    (lambda (ms)
                      (unless (vector-ref kept 0) (vector-set! kept 0 (make-uv-timer loop)))
                      (uv-timer-start! (vector-ref kept 0) fire ms 0))
                    (lambda () (let ((timer (vector-ref kept 0)))
                                 (when timer (uv-timer-stop! timer)))))))

  ;; shell-waits-timed : Shell -> Nat — how many sleeps and deadlines the
  ;; waits of its loop have armed.
  (define (shell-waits-timed sh) (waits-timed (scheduler-waits (shell-scheduler sh))))

  ;; wall-clock : -> Nat — milliseconds since the epoch, UTC: a shell's clock.
  (define (wall-clock)
    (let ((t (current-time 'time-utc)))
      (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

  ;; shell-connections : Shell -> (Listof Connection)
  ;; The connections adopted and not yet closed.  The table maps each one's
  ;; handle to it.
  (define (shell-connections sh)
    (let-values (((handles connections) (hashtable-entries (shell-table sh))))
      (vector->list connections)))

  ;; connection? : Any -> Boolean
  ;; connection-tcp : Connection -> UvTcp
  ;; connection-violations : Connection -> (Listof Action)
  ;;   actions run anywhere but the outermost drain, newest first
  (define-record-type (connection make-connection connection?)
    (fields shell tcp
            (mutable ctx) (mutable parser)
            (mutable front) (mutable back)    ; the queue: front in order, back reversed
            (mutable depth)                   ; the drain, and a feed inside it
            (mutable violations)
            (mutable reading?)
            (mutable closing?)
            (mutable on-data) (mutable on-eof) (mutable on-error)
            (mutable entry)                   ; its deadline's, in the shell's wheel
            (mutable held)                    ; the writes held: their byte counts, newest first
            (mutable chunk) (mutable chunk-end) ; the last chunk they fill, or #f, and where they end in it
            (mutable chunks)                  ; the chunks before it, as spans, newest first
            (mutable producer-called?)        ; whether the drain has called a producer yet
            (mutable waits?)                  ; whether the request's handler answered awaiting
            (mutable calls)                   ; its calls on coroutines to make, in order
            (mutable calling?)))              ; whether one of them runs

  ;; connection-state : Connection -> ConnState — the core's state.
  (define (connection-state c) (conn-context-state (connection-ctx c)))

  ;; connection-deadline : Connection -> (U Nat #f)
  ;; The loop's time its deadline passes at, or #f while none is armed.
  (define (connection-deadline c) (wheel-entry-deadline (connection-entry c)))

  ;; shell-deadlines : Shell -> Nat — how many of its connections have a
  ;; deadline armed.
  (define (shell-deadlines sh) (wheel-count (shell-wheel sh)))

  ;; --- the listener -------------------------------------------------------------

  ;; shell-listen! : Shell String Nat -> Nat
  ;; Listen on `host`, an IPv4 or IPv6 literal, and `port`, with the limits'
  ;; backlog, offering each connection the listener takes to the server: the
  ;; port it listens on, the kernel's choice for port 0.  A shell listens on
  ;; one listener at a time, and not at all once its server has stopped
  ;; listening; either is an assertion violation.  A listener that cannot
  ;; listen is closed, the raise goes on, and the shell may listen again.
  ;; An error the listener reports in place of a connection means it has
  ;; stopped (libuv 1.52.1 reports one only on Windows, src/win/tcp.c): the
  ;; server is told, `listener-failed`, and shuts down.  On Unix libuv drops a
  ;; failed accept itself, and when descriptors run out it sheds load by
  ;; accepting and closing whatever waits (src/unix/stream.c).
  (define (shell-listen! sh host port)
    (unless (eq? (server-phase (shell-server sh)) 'listening)
      (assertion-violation 'shell-listen! "the server has stopped listening" sh))
    (let ((listener (shell-listener sh)))
      (when (and listener (uv-handle-open? listener))
        (assertion-violation 'shell-listen! "the shell listens already" sh)))
    (let ((tcp (make-uv-tcp (shell-loop sh))))
      (shell-listener-set! sh tcp)
      (closing-on-raise sh tcp
        (lambda ()
          (uv-tcp-bind! tcp host port)
          (uv-listen! tcp (limits-backlog (shell-limits sh))
                      (lambda (err)
                        (if err
                            (server-dispatch! sh (list 'listener-failed (errno err)))
                            (let ((client (accept! sh tcp)))
                              (when client (shell-adopt! sh client))))))
          (uv-tcp-getsockname-port tcp)))))

  ;; accept! : Shell UvTcp -> (U UvTcp #f)
  ;; The connection the listener has taken, or #f, logged as `accept-failed`,
  ;; if libuv could not open it: libuv has closed its descriptor, and the
  ;; listener listens on (libuv 1.52.1, src/unix/stream.c's uv_accept).
  (define (accept! sh listener)
    (guard (e ((transport-condition? e) (log! sh 'accept-failed (list (errno e))) #f))
      (uv-accept! listener)))

  ;; shell-shutdown! : Shell -> Void
  ;; Ask the server to shut down: it stops listening, and refuses what it is
  ;; offered after.  The connections open are served on (M8 drains them).
  (define (shell-shutdown! sh)
    (server-dispatch! sh '(shutdown-requested)))

  ;; shell-adopt! : Shell UvTcp -> (U Connection #f)
  ;; Offer an accepted TCP handle to the server, with the count of
  ;; connections open: served, as a connection, while fewer than the limits'
  ;; max-connections are, or refused, closed at once, answering #f, when that
  ;; many are or the server drains.  The server answers first, `accept` or
  ;; `refuse`, and anything else is an assertion violation.  If anything
  ;; raises before the handle is served, it is closed, so none is left open
  ;; with no one to close it; what the server asks for after its answer, a
  ;; log, runs once the handle is served or closed.
  (define (shell-adopt! sh tcp)
    (let-values (((served rest)
                  (closing-on-raise sh tcp
                    (lambda ()
                      (let ((actions (server-step! sh (list 'connection-arrived
                                                            (hashtable-size (shell-table sh))))))
                        (case (and (pair? actions) (caar actions))
                          ((accept)
                           (server-trace! sh 'server-action (car actions))
                           (values (serve! sh tcp) (cdr actions)))
                          ((refuse)
                           (server-trace! sh 'server-action (car actions))
                           (handle-close! sh tcp)
                           (values #f (cdr actions)))
                          (else (assertion-violation 'shell-adopt!
                                  "the server answered an arrival with neither accept nor refuse"
                                  actions))))))))
      (run-server-actions! sh rest)
      served))

  ;; server-step! : Shell Event -> (Listof Action)
  ;; Step the server with one event, keep the state it leaves, and answer the
  ;; actions it asks for.
  (define (server-step! sh event)
    (server-trace! sh 'server-event event)
    (let-values (((s actions) (server-step (shell-server sh) event)))
      (shell-server-set! sh s)
      actions))

  ;; server-trace! : Shell Symbol Any -> Void
  (define (server-trace! sh kind datum)
    (let ((trace (shell-trace sh)))
      (when trace (trace sh kind datum))))

  ;; server-dispatch! : Shell Event -> Void — an event that brings no handle.
  ;; A server that has stopped listening, with no connection left, takes the
  ;; timer with it (release-timer!).
  (define (server-dispatch! sh event)
    (run-server-actions! sh (server-step! sh event))
    (release-timer! sh))

  ;; run-server-actions! : Shell (Listof Action) -> Void — in order.
  (define (run-server-actions! sh actions)
    (unless (null? actions)
      (server-run! sh (car actions))
      (run-server-actions! sh (cdr actions))))

  ;; server-run! : Shell Action -> Void
  ;; A server action that brings no handle: close the listener, or log.  An
  ;; arrival's `accept` or `refuse` is taken with its handle, in shell-adopt!,
  ;; and `force-close-all` is M8's; anything else here is an assertion
  ;; violation, so an action the shell cannot perform is never dropped.
  (define (server-run! sh a)
    (server-trace! sh 'server-action a)
    (case (car a)
      ((close-listener) (listener-close! sh))
      ((log) (log! sh (cadr a) (cddr a)))
      (else (assertion-violation 'server-run! "not an action the shell performs here" a))))

  ;; listener-close! : Shell -> Void — close the listener, if the shell has one.
  (define (listener-close! sh)
    (let ((tcp (shell-listener sh)))
      (when tcp (handle-close! sh tcp))))

  ;; serve! : Shell UvTcp -> Connection
  ;; Serve an accepted TCP handle: the core in idle, a parser of its own, the
  ;; connection in the table, its idle deadline armed at the loop's time
  ;; brought up to date, Nagle's algorithm off, and reading started with the
  ;; limits' buffer.  Nagle's algorithm would hold a response's last partial
  ;; segment until the client acknowledged the ones before it, and the shell
  ;; writes each response whole, in one write; a socket that refuses the
  ;; option has already failed, which reading will report.  A start that
  ;; raises goes on to shell-adopt!, which closes the handle.
  (define (serve! sh tcp)
    (let ((c (make-connection sh tcp #f #f '() '() 0 '() #f #f #f #f #f #f '() #f 0 '() #f #f '() #f)))
      (connection-entry-set! c (make-wheel-entry c))
      (connection-ctx-set! c (make-conn-context
                              (make-conn-state 'idle 'idle #f 0 0 #f #f (shell-limits sh))
                              (lambda (actions) (enqueue! c actions))))
      (connection-parser-set! c (make-conn-parser (connection-ctx c)))
      (connection-on-data-set! c (lambda (bv start end) (dispatch! c (list 'bytes-arrived bv start end))))
      (connection-on-eof-set! c (lambda () (dispatch! c '(eof))))
      (connection-on-error-set! c (lambda (e) (dispatch! c (list 'read-error (errno e)))))
      (hashtable-set! (shell-table sh) tcp c)
      (uv-update-time! (shell-loop sh))
      (arm! c 'idle)
      (guard (e ((transport-condition? e) (values)))
        (uv-tcp-nodelay! tcp #t))
      (uv-read-start! tcp (connection-on-data c) (connection-on-eof c) (connection-on-error c)
                      (limits-read-buffer-size (shell-limits sh)))
      (connection-reading?-set! c #t)
      c))

  ;; --- the message loop ---------------------------------------------------------

  ;; dispatch! : Connection Event -> Void
  ;; Step the core with one event and queue its actions, then drain the queue
  ;; unless a drain or a feed is under way.  The outermost dispatch closes the
  ;; connection if anything raises.
  (define (dispatch! c event)
    (if (fx=? (connection-depth c) 0)
        (closing-on-raise (connection-shell c) (connection-tcp c)
                          (lambda () (step! c event) (drain! c)))
        (step! c event)))

  ;; step! : Connection Event -> Void — the core's step, its actions queued.
  (define (step! c event)
    (trace! c 'event event)
    (enqueue! c (conn-context-step! (connection-ctx c) event)))

  ;; closing-on-raise : Shell UvHandle (-> Any ...) -> Any ...
  ;; Run `thunk`; if it raises, close the handle and raise again.
  (define (closing-on-raise sh h thunk)
    (guard (e (#t (handle-close! sh h) (raise e)))
      (thunk)))

  ;; enqueue! : Connection (Listof Action) -> Void — behind what is queued.
  (define (enqueue! c actions)
    (connection-back-set! c (fold-left (lambda (acc a) (cons a acc)) (connection-back c) actions)))

  ;; dequeue! : Connection -> (U #f Action) — the oldest queued action.
  (define (dequeue! c)
    (when (null? (connection-front c))
      (connection-front-set! c (reverse (connection-back c)))
      (connection-back-set! c '()))
    (let ((front (connection-front c)))
      (and (pair? front)
           (begin (connection-front-set! c (cdr front)) (car front)))))

  ;; drain! : Connection -> Void
  ;; Run the queue, in order, and once it is empty send the writes held
  ;; (flush!), until nothing is queued or held: a write that fails at the
  ;; call queues what its failure dispatches.  A drain starts having called
  ;; no producer (run!'s `notify-producer`).  A raise abandons the dispatch
  ;; it came from: the depth is restored, the scheduler's phase too, which a
  ;; feed the raise came out of left 'in-parser (feed!), and what is still
  ;; queued or held is dropped.
  (define (drain! c)
    (let ((before (connection-depth c)) (phase (scheduler-phase)))
      (dynamic-wind
       (lambda ()
         (connection-depth-set! c (fx+ before 1))
         (connection-producer-called?-set! c #f))
       (lambda ()
         (let loop ()
           (let ((a (dequeue! c)))
             (cond (a (run! c a) (loop))
                   ((pair? (connection-held c)) (flush! c) (loop))))))
       (lambda ()
         (connection-depth-set! c before)
         (scheduler-feed-end! phase)
         (connection-front-set! c '())
         (connection-back-set! c '())
         (drop-held! c)))))

  ;; run! : Connection Action -> Void
  ;; Record a violation if the action runs anywhere but the outermost drain,
  ;; then perform it.  An arm or a write reads the loop's time, for its
  ;; deadline or its Date, so the loop's clock is brought up to date first,
  ;; before the trace, which then reads the time the action does.
  (define (run! c a)
    (unless (fx=? (connection-depth c) 1)
      (connection-violations-set! c (cons a (connection-violations c))))
    (when (memq (car a) '(arm-deadline write))
      (uv-update-time! (shell-loop (connection-shell c))))
    (trace! c 'action a)
    (case (car a)
      ((feed-parser) (feed! c (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (parser-resume! (connection-parser c)))
      ((call-handler) (call-handler! c (cadr a)))
      ((deliver-body) (deliver-body! c (cadr a) (caddr a) (cadddr a)))
      ((deliver-body-end) (deliver-body-end! c))
      ((notify-producer)
       (unless (connection-producer-called? c)
         (connection-producer-called?-set! c #t)
         (flush! c))
       (notify-producer! c))
      ((write) (write! c (cadr a) (caddr a)))
      ((read-stop) (read-stop! c))
      ((read-start) (read-start! c))
      ((shutdown) (flush! c) (shutdown! c))
      ((close) (flush! c) (connection-close! c))
      ((log) (log! (connection-shell c) (cadr a) (cddr a)))
      ((arm-deadline) (arm! c (cadr a)))
      ((disarm-deadline) (disarm! c))
      (else (values))))

  (define (trace! c kind datum)
    (let ((trace (shell-trace (connection-shell c))))
      (when trace (trace c kind datum))))

  (define (log! sh what details) ((shell-log sh) what details))

  ;; --- the executors ------------------------------------------------------------

  ;; feed! : Connection Bytevector Nat Nat -> Void
  ;; Feed the parser bv[start, end), counting the feed in the depth, and in
  ;; the scheduler's phase 'in-parser (R5), then dispatch its result as the
  ;; adapter builds it: the status, where the parser is, where to resume, the
  ;; code of its error or its pause, and the span an error abandoned.  The
  ;; phase is set and left with no closure, so a feed allocates nothing for
  ;; it; a raise out of the feed leaves it to the drain (drain!).
  (define (feed! c bv start end)
    (connection-depth-set! c (fx+ (connection-depth c) 1))
    (let* ((phase (scheduler-feed-begin!))
           (r (parser-feed! (connection-parser c) bv start end)))
      (scheduler-feed-end! phase)
      (connection-depth-set! c (fx- (connection-depth c) 1))
      (dispatch! c (parser-result-event r))))

  ;; call-handler! : Connection Request -> Void
  ;; The handler called from the scheduler's drain, after libuv's turn
  ;; (decision 0014): its answer, and `credit` after it on a shell made on
  ;; credit, dispatched there, the turn's guard taking a raise out of the
  ;; dispatch as a callback's (shell-turn!).  A connection that has closed
  ;; before the drain reaches the call has its handler called no more, as a
  ;; waiting connection's calls are not made (next-call!).
  (define (call-handler! c request)
    (let ((sh (connection-shell c)))
      (connection-waits?-set! c #f)
      (scheduler-call! (shell-scheduler sh)
        (lambda ()
          (unless (connection-closing? c)
            (let ((event (guard (e (#t (log! sh 'handler-failed (list e))
                                       (list 'handler-failed e)))
                           (answered c ((shell-handler sh) request) #t))))
              (when event (dispatch! c event))))))))

  ;; answered : Connection Any Boolean -> (U Event #f)
  ;; The event an answer brings, the handler's or, not `handler?`, a
  ;; reader's at its end: `(handler-responded answer)`, and `credit` after
  ;; the handler's on a shell made on credit or once the handler waits, for
  ;; the reader it may be (M6.2); or, for `awaiting`, none yet: its thunk is
  ;; called on a coroutine (call-waiting!), and its answer answered so in
  ;; turn.
  (define (answered c a handler?)
    (cond
     ((awaiting? a)
      (connection-waits?-set! c #t)
      (call-waiting! c (awaiting-thunk a) (lambda (v) (answered c v handler?)))
      #f)
     ((and handler? (or (connection-waits? c) (shell-on-credit? (connection-shell c))))
      (list 'handler-responded a 'credit))
     (else (list 'handler-responded a))))

  ;; call-waiting! : Connection (-> Any) (Any -> (U Event #f)) -> Void
  ;; Call `thunk` on a coroutine, after the connection's calls before it:
  ;; once it has ended, the event `->event` makes of its value is
  ;; dispatched, from the drain, or `handler-failed`, logged, if either
  ;; raised; then the next call starts.  A connection closing makes no more.
  ;; A raise out of the dispatch goes to the turn's guard (shell-turn!),
  ;; having closed the connection, whose calls then matter no more.
  (define (call-waiting! c thunk ->event)
    (connection-calls-set! c (append (connection-calls c) (list (cons thunk ->event))))
    (unless (connection-calling? c) (next-call! c)))

  ;; next-call! : Connection -> Void — start the oldest call waiting, if any.
  (define (next-call! c)
    (let ((calls (connection-calls c)))
      (cond
       ((or (null? calls) (connection-closing? c))
        (connection-calls-set! c '())
        (connection-calling?-set! c #f))
       (else
        (let ((call (car calls)) (sh (connection-shell c)))
          (connection-calls-set! c (cdr calls))
          (connection-calling?-set! c #t)
          (scheduler-spawn! (shell-scheduler sh) (car call)
            (lambda (kind v)
              (let ((event (guard (e (#t (log! sh 'handler-failed (list e))
                                         (list 'handler-failed e)))
                             (if (eq? kind 'raised)
                                 (raise v)
                                 ((cdr call) v)))))
                (when (and event (not (connection-closing? c)))
                  (dispatch! c event)))
              (next-call! c))))))))

  ;; deliver-body! : Connection Bytevector Nat Nat -> Void
  ;; Hand bv[start, end) to the reader the core is handing the body to; if
  ;; the reader raises, `handler-failed`, logged.  With no reader, nothing:
  ;; the core let it go after this piece was asked for.  The reader of a
  ;; handler that waits takes it on a coroutine (call-waiting!), and a
  ;; streaming one is then credited with it, `(body-credit n)`.
  (define (deliver-body! c bv start end)
    (let ((r (conn-body-reader (connection-state c))))
      (when r
        (if (connection-waits? c)
            (call-waiting! c (lambda () ((body-reader-on-piece r) bv start end))
                           (lambda (v) (and (not (body-reader-whole? r))
                                            (list 'body-credit (- end start)))))
            (guard (e (#t (log! (connection-shell c) 'handler-failed (list e))
                          (dispatch! c (list 'handler-failed e))))
              ((body-reader-on-piece r) bv start end))))))

  ;; deliver-body-end! : Connection -> Void
  ;; The reader's end: its response as `handler-responded` (answered), or,
  ;; if it raises, `handler-failed`, logged; on a coroutine for a handler
  ;; that waits (call-waiting!).
  (define (deliver-body-end! c)
    (let ((r (conn-body-reader (connection-state c))))
      (when r
        (if (connection-waits? c)
            (call-waiting! c (body-reader-on-end r) (lambda (v) (answered c v #f)))
            (let ((event (guard (e (#t (log! (connection-shell c) 'handler-failed (list e))
                                       (list 'handler-failed e)))
                           (answered c ((body-reader-on-end r)) #f))))
              (when event (dispatch! c event)))))))

  ;; notify-producer! : Connection -> Void
  ;; The producer the core writes a response's body from, called for its
  ;; next piece: its answer as `handler-body-chunk` or `handler-body-end`,
  ;; or, if it raises or answers neither, `handler-failed`, logged.  With no
  ;; producer, nothing: the core let it go after the piece was asked for.
  ;; The producer of a handler that waits is called on a coroutine
  ;; (call-waiting!).
  (define (notify-producer! c)
    (let ((p (conn-producer (connection-state c))))
      (when p
        (if (connection-waits? c)
            (call-waiting! c p producer-event)
            (dispatch! c (guard (e (#t (log! (connection-shell c) 'handler-failed (list e))
                                       (list 'handler-failed e)))
                           (producer-event (p))))))))

  ;; write! : Connection (Listof Segment) Nat -> Void
  ;; A write of `nbytes`, the Date slot filled: held for the turn's one
  ;; write if under held-below bytes (hold!), or else one uv-write*! of its
  ;; own, after the writes held (flush!), which copies its segments at the
  ;; call.
  (define (write! c segments nbytes)
    (let ((line (current-date-line (connection-shell c))))
      (cond ((fx<? nbytes held-below) (hold! c segments line nbytes))
            (else
             (flush! c)
             (send! c (map (lambda (seg) (if (eq? seg 'date) line seg)) segments)
                    (list nbytes))))))

  ;; A write under this many bytes is held (WRITE BATCHING, the header):
  ;; gathered, pieces below it streamed faster on Linux and on Darwin, and
  ;; pieces of 16 KiB slower on Linux (design §7.3's note).
  (define held-below 4096)

  ;; hold! : Connection (Listof Segment) Bytevector Nat -> Void
  ;; Hold a write of `nbytes`: copy its segments' bytes, the Date slot's as
  ;; `line`, behind those held, into the last chunk if they fit, or else
  ;; into a new one, twice the last's length or the write's, whichever is
  ;; more.  A chunk's bytes are never copied again, and the first chunk is
  ;; the first write's own length, so a turn that holds one write holds its
  ;; bytes and no more.  The copy is a loop of its own, not fold-left's,
  ;; whose procedure would be a closure made for every write held.
  (define (hold! c segments line nbytes)
    (let* ((last (connection-chunk c))
           (end (connection-chunk-end c))
           (chunk (if (and last (fx<=? (fx+ end nbytes) (bytevector-length last)))
                      last
                      (begin
                        (when last
                          (connection-chunks-set! c (cons (list last 0 end) (connection-chunks c))))
                        (let ((new (make-bytevector
                                    (if last (fxmax nbytes (fx* 2 (bytevector-length last))) nbytes))))
                          (connection-chunk-set! c new)
                          new)))))
      (connection-chunk-end-set! c
        (let copy ((segments segments) (at (if (eq? chunk last) end 0)))
          (if (null? segments)
              at
              (let ((seg (car segments)))
                (copy (cdr segments)
                      (cond ((eq? seg 'date) (copy-span! line 0 (bytevector-length line) chunk at))
                            ((bytevector? seg) (copy-span! seg 0 (bytevector-length seg) chunk at))
                            (else (copy-span! (car seg) (cadr seg) (caddr seg) chunk at))))))))
      (connection-held-set! c (cons nbytes (connection-held c)))))

  ;; copy-span! : Bytevector Nat Nat Bytevector Nat -> Nat
  ;; Copy bv[start, end) into `out` at `at`, answering where the copy ends.
  (define (copy-span! bv start end out at)
    (bytevector-copy! bv start out at (fx- end start))
    (fx+ at (fx- end start)))

  ;; flush! : Connection -> Void
  ;; Send the writes held as one write of their chunks' spans, and hold
  ;; none.
  (define (flush! c)
    (let ((held (connection-held c)))
      (unless (null? held)
        (let ((spans (reverse (cons (list (connection-chunk c) 0 (connection-chunk-end c))
                                    (connection-chunks c)))))
          (drop-held! c)
          (send! c spans (reverse held))))))

  ;; drop-held! : Connection -> Void — hold no write.
  (define (drop-held! c)
    (connection-held-set! c '())
    (connection-chunk-set! c #f)
    (connection-chunk-end-set! c 0)
    (connection-chunks-set! c '()))

  ;; send! : Connection (Listof Segment) (Listof Nat) -> Void
  ;; One uv-write*! of `segments`, which carries writes of `counts` bytes, in
  ;; the order written.  A raise at the call is a failure, as one at the
  ;; completion is (write-done).
  (define (send! c segments counts)
    (let ((done (write-done c counts)))
      (guard (e ((transport-condition? e) (done e)))
        (uv-write*! (connection-tcp c) segments done))))

  ;; write-done : Connection (Listof Nat) -> ((U #f Condition) -> Void)
  ;; The completion of a write that carried writes of `counts` bytes, in the
  ;; order written, which keeps their byte counts and nothing of their
  ;; bytes: `write-completed` for each, after one `read-error` if the write
  ;; failed.
  (define (write-done c counts)
    (lambda (err)
      (when err (dispatch! c (list 'read-error (errno err))))
      (for-each (lambda (n) (dispatch! c (list 'write-completed n))) counts)))

  ;; read-stop! / read-start! : Connection -> Void
  ;; Reading changes only when it is not already what the action asks.  A
  ;; stop races a close only if the handle is no longer open, and a closed
  ;; handle reads nothing.
  (define (read-stop! c)
    (when (connection-reading? c)
      (connection-reading?-set! c #f)
      (when (uv-handle-open? (connection-tcp c))
        (uv-read-stop! (connection-tcp c)))))

  (define (read-start! c)
    (unless (or (connection-reading? c) (connection-closing? c))
      (connection-reading?-set! c #t)
      (guard (e ((transport-condition? e) (dispatch! c (list 'read-error (errno e)))))
        (uv-read-start! (connection-tcp c)
                        (connection-on-data c) (connection-on-eof c) (connection-on-error c)))))

  ;; shutdown! : Connection -> Void — the half-close.
  (define (shutdown! c)
    (guard (e ((transport-condition? e) (dispatch! c (list 'read-error (errno e)))))
      (uv-shutdown! (connection-tcp c)
                    (lambda (err)
                      (dispatch! c (if err (list 'read-error (errno err)) '(shutdown-completed)))))))

  ;; --- deadlines ----------------------------------------------------------------

  ;; arm! : Connection Symbol -> Void
  ;; Arm the connection's deadline of `kind` at the loop's now plus the
  ;; kind's limit, moving the one it had, and see the timer runs.  Its
  ;; callers, run! and serve!, have brought the loop's clock up to date.  A
  ;; connection already closing is not armed, as it is not read: it left the
  ;; wheel for good as its close began (handle-close!), and the core may not
  ;; know it has, when the close came from outside it.
  (define (arm! c kind)
    (unless (connection-closing? c)
      (let ((sh (connection-shell c)))
        (wheel-arm! (shell-wheel sh) (connection-entry c)
                    (+ (uv-now (shell-loop sh)) (limits-deadline-ms (shell-limits sh) kind)))
        (start-ticking! sh))))

  ;; start-ticking! : Shell -> Void
  ;; See the timer runs: made and started, every tick-ms, if the shell has
  ;; none, and started again if it has stopped, keeping its callback and
  ;; repeat (uv-timer-again!).  A timer whose first start raises is closed,
  ;; and the raise goes on.
  (define (start-ticking! sh)
    (unless (shell-ticking? sh)
      (let ((timer (shell-timer sh)))
        (if timer
            (uv-timer-again! timer)
            (let ((timer (make-uv-timer (shell-loop sh)))
                  (tick-ms (limits-tick-ms (shell-limits sh))))
              (closing-on-raise sh timer
                (lambda () (uv-timer-start! timer (lambda (t) (tick! sh)) tick-ms tick-ms)))
              (shell-timer-set! sh timer))))
      (shell-ticking?-set! sh #t)))

  ;; stop-ticking! : Shell -> Void — stop the timer, if it runs.
  (define (stop-ticking! sh)
    (when (shell-ticking? sh)
      (uv-timer-stop! (shell-timer sh))
      (shell-ticking?-set! sh #f)))

  ;; disarm! : Connection -> Void — take its deadline out of the wheel.
  (define (disarm! c)
    (wheel-disarm! (shell-wheel (connection-shell c)) (connection-entry c)))

  ;; tick! : Shell -> Void
  ;; The timer has fired: advance the wheel to the loop's now, tick each
  ;; connection whose deadline has passed, earliest first, stop the timer
  ;; if the wheel is then empty, and tell the server the time.  The wheel
  ;; has let every one of them go, so each is ticked under its own guard,
  ;; and one that raises keeps none of the rest from its tick; its dispatch
  ;; has closed its connection.  Once every tick is delivered, the first
  ;; raise goes on, and the run loop logs it, unless a later one is a
  ;; byte-machine contract condition, which the run loop keeps fatal
  ;; (design §6.4): that one goes on.
  (define (tick! sh)
    (let* ((now (uv-now (shell-loop sh)))
           (event (list 'tick now))
           (raised '()))
      (define (guarded thunk)
        (guard (e (#t (when (or (null? raised)
                                (and (byte-machine-contract-condition? e)
                                     (not (byte-machine-contract-condition? (car raised)))))
                        (set! raised (list e)))))
          (thunk)))
      (for-each (lambda (c) (guarded (lambda () (dispatch! c event))))
                (wheel-advance! (shell-wheel sh) now))
      (when (fxzero? (wheel-count (shell-wheel sh))) (stop-ticking! sh))
      (guarded (lambda () (server-dispatch! sh event)))
      (unless (null? raised) (raise (car raised)))))

  ;; release-timer! : Shell -> Void
  ;; Close the timer once the shell has stopped listening and no connection
  ;; is left: a shell that serves no more holds none.  The timer of its
  ;; loop's waits goes with it, once they have nothing armed.
  (define (release-timer! sh)
    (when (and (fxzero? (hashtable-size (shell-table sh)))
               (not (eq? (server-phase (shell-server sh)) 'listening)))
      (let ((timer (shell-timer sh)))
        (when timer
          (shell-timer-set! sh #f)
          (shell-ticking?-set! sh #f)
          (handle-close! sh timer)))
      (release-waits-timer! sh)))

  ;; release-waits-timer! : Shell -> Void
  ;; Close the timer of its loop's waits, if it has one and they have
  ;; nothing armed: a shell that serves no more leaves no timer of theirs
  ;; behind either.  The next timed wait makes another (loop-clock!).  The
  ;; shell keeps the timer's box, so that this reads nothing of the
  ;; library's own but what the shell holds: the code each request runs
  ;; reaches it through calls Chez knows, by the deadlines' timer (arm!,
  ;; start-ticking!, tick!, server-dispatch!), and a table of the library's
  ;; read here made Chez's closures for each request carry it, 130 B a
  ;; request more (M7.2).
  (define (release-waits-timer! sh)
    (let ((kept (shell-waits-kept sh)))
      (when (and (vector-ref kept 0) (fxzero? (shell-waits-timed sh)))
        (let ((timer (vector-ref kept 0)))
          (vector-set! kept 0 #f)
          (handle-close! sh timer)))))

  ;; connection-close! : Connection -> Void — close the connection's handle.
  (define (connection-close! c)
    (handle-close! (connection-shell c) (connection-tcp c)))

  ;; connection-body-credit! : Connection Nat -> Void
  ;; The reader the core hands the body to, answered on credit, has taken
  ;; `n` more bytes of what it was handed: `(body-credit n)`, dispatched
  ;; (M6.2).  Reading waits for it once a read's pieces are handed over.
  ;; M7's scheduler will give it as an awaiting reader takes its pieces; in
  ;; v1 only the checks do.  A credit the core refuses, for more than the
  ;; reader was handed and has not credited, is a bug, and a bug closes its
  ;; connection (the header): the connection is closed, and the core's
  ;; assertion violation raised to the caller.
  (define (connection-body-credit! c n)
    (dispatch! c (list 'body-credit n)))

  ;; handle-close! : Shell UvHandle -> Void
  ;; Close a handle: a connection's, the listener, the timer, or one the
  ;; server refused.  This is the one uv-close! call (design §5.3 and §7.6;
  ;; tests/test-close-ownership.sps).  chez-libuv runs the callback of a
  ;; handle's first close alone, and a later close does nothing, so every
  ;; close passes the same callback, and what it does follows the handle: a
  ;; connection's handle stops reading at once and leaves the wheel, and its
  ;; close takes the connection out of the table and reports `closed`,
  ;; whoever asked for it.
  (define (handle-close! sh h)
    (let ((c (hashtable-ref (shell-table sh) h #f)))
      (when c
        (connection-closing?-set! c #t)
        (connection-reading?-set! c #f)
        (disarm! c)))
    (uv-close! h (lambda () (handle-closed! sh h))))

  ;; handle-closed! : Shell UvHandle -> Void — a handle's close has completed.
  (define (handle-closed! sh h)
    (let ((c (hashtable-ref (shell-table sh) h #f)))
      (when c
        (hashtable-delete! (shell-table sh) h)
        (release-timer! sh)
        (dispatch! c '(closed)))))

  ;; transport-condition? : Any -> Boolean
  ;; What a verb raises when the connection, not the program, has failed.
  (define (transport-condition? e) (or (uv-errno-error? e) (uv-handle-closed? e)))

  ;; errno : Condition -> Symbol — the failure's portable name.
  (define (errno e)
    (cond ((uv-errno-error? e) (uv-errno-error-errno e))
          ((uv-handle-closed? e) 'handle-closed)
          (else 'unknown)))

  ;; current-date-line : Shell -> Bytevector
  ;; The Date line for the current second.  The clock is read when a second of
  ;; the loop's time has passed since its last reading, and the line made
  ;; again only when the second it names has changed.
  (define (current-date-line sh)
    (let ((now (uv-now (shell-loop sh))))
      (unless (and (shell-read-at sh) (< (- now (shell-read-at sh)) 1000))
        (shell-read-ms-set! sh ((shell-clock sh)))
        (shell-read-at-set! sh now))
      (let ((second (div (+ (shell-read-ms sh) (- now (shell-read-at sh))) 1000)))
        (unless (eqv? second (shell-date-second sh))
          (shell-date-line-set! sh (date-line second))
          (shell-date-second-set! sh second))
        (shell-date-line sh))))

  ;; --- the run loop --------------------------------------------------------------

  ;; shell-turn! : Shell -> Boolean
  ;; One turn of the loop's scheduler, under the run loop's guard: the
  ;; handlers called since the last, then one uv-run, 'once, or 'nowait
  ;; while something is ready.  Whether work remains, or #t after a
  ;; callback's error, logged.  Whatever the drain raises, where no
  ;; chez-libuv catches it, is taken as a callback's raise: its dispatch
  ;; has closed its connection, and what the drain had still to run runs
  ;; at the next turn.  A run loop turns it until it answers #f.
  (define (shell-turn! sh)
    (run-guarded sh (lambda () (scheduler-turn! (shell-scheduler sh))) (lambda (e) #t)))

  ;; loop-turn! : UvLoop -> Boolean
  ;; One turn of `loop`'s scheduler with no guard: what remains, as the
  ;; turn answers.  A raise from a callback comes out as uv-run raises it.
  (define (loop-turn! loop)
    (scheduler-turn! (loop-scheduler loop)))

  ;; shell-run! : Shell Symbol -> Boolean
  ;; One uv-run of the shell's loop in `mode`, with no scheduler: whether
  ;; work remains, as uv-run answers, or #t after a callback's error,
  ;; logged, so the caller runs again.  A byte-machine contract condition is
  ;; raised again.  A handler is called only from a turn's drain
  ;; (shell-turn!), so a loop run by this alone calls none.
  (define (shell-run! sh mode)
    (run-guarded sh (lambda () (uv-run (shell-loop sh) mode)) uv-callback-error?))

  ;; run-guarded : Shell (-> Any) (Any -> Boolean) -> Any
  ;; What `thunk`, a run of the loop, answers, under the run loop's guard:
  ;; a byte-machine contract condition is logged, the table reconciled, and
  ;; raised again; a raise `callback?` takes as a callback's is logged, the
  ;; table reconciled, and #t answered, so the caller runs again.
  (define (run-guarded sh thunk callback?)
    (guard (e ((byte-machine-contract-condition? e)
               (log-quietly! sh 'contract-violation (list e))
               (reconcile! sh)
               (raise e))
              ((callback? e)
               (log-quietly! sh 'callback-error (list e))
               (reconcile! sh)
               #t))
      (thunk)))

  ;; log-quietly! : Shell Symbol (Listof Any) -> Void
  ;; Log from the run loop, which is already handling a failure: a raise from
  ;; the log is dropped, so it cannot take that failure's place.
  (define (log-quietly! sh what details)
    (guard (e (#t (values)))
      (log! sh what details)))

  ;; reconcile! : Shell -> Void
  ;; Hold the table to the loop: a connection whose handle the loop no longer
  ;; has, so whose close never reported back, is logged, taken out of the
  ;; wheel and dropped, which frees its place, since the server counts the
  ;; table.  A server that has stopped listening takes the timer with its
  ;; last connection (release-timer!).
  (define (reconcile! sh)
    (let ((live (make-eq-hashtable)))
      (for-each (lambda (h) (hashtable-set! live h #t))
                (uv-loop-live-handles (shell-loop sh)))
      (let-values (((handles connections) (hashtable-entries (shell-table sh))))
        (vector-for-each
         (lambda (h c)
           (unless (hashtable-contains? live h)
             (log-quietly! sh 'reconciled (list c))
             (disarm! c)
             (hashtable-delete! (shell-table sh) h)))
         handles connections))
      (release-timer! sh))))
