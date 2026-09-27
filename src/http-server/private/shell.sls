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
;;; item 1).  None runs application code but the handler's call, and none
;;; captures a continuation.
;;;
;;; THE MESSAGE LOOP is the fake shell's (design §4.5).  Actions run after the
;;; outermost dispatch, in order, from one queue; a dispatch made while the
;;; queue drains, or while the parser feeds, only queues.  `depth` counts the
;;; drain and a feed inside it.  An action run anywhere but the outermost
;;; drain is a VIOLATION, recorded (design §6.4, the second hazard):
;;; byte-machine poisons a parser whose callback escapes, and chez-libuv
;;; defers the raise, so the one action answered inside a parser callback is
;;; `reply-parser`, which the adapter answers without reaching the queue.
;;;
;;; THE ACTIONS, performed:
;;;   feed-parser     parser-feed!, counted in the depth, then its result as
;;;                   `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler's response as `handler-responded`, or, if
;;;                   the handler raises, `handler-failed`, logged; the
;;;                   loop's clock brought up to date first, as the handler
;;;                   held the loop (chez-libuv #28)
;;;   write           uv-write*!, the Date slot filled from the clock (decision
;;;                   0010); its completion reports `write-completed` with the
;;;                   action's byte count, which is all the completion keeps:
;;;                   chez-libuv copied the segments at the call (design §7.3)
;;;   read-stop/-start  uv-read-stop! and uv-read-start!, when reading
;;;                   changes; the first start, at adoption, fixes the read
;;;                   buffer at the limits' read-buffer-size (design §7.2)
;;;   shutdown        uv-shutdown!, the write side (decision 0011); its
;;;                   completion reports `shutdown-completed`
;;;   close           connection-close!, through handle-close! (below); the
;;;                   close's callback takes the connection out of the table
;;;                   and reports `closed`
;;;   log             the shell's log
;;;   arm-deadline    the connection's entry in the wheel, at the loop's now
;;;                   plus the kind's limit (below)
;;;   disarm-deadline its entry taken out of the wheel
;;; Bodies (M6) and the hand-off (M8) are never asked for in v1's flow.
;;;
;;; DEADLINES (decision 0005 and its amendments of 2026-09-27; M5.3).  The
;;; shell keeps the deadlines of its connections in one wheel, (http-server
;;; wheel), in which each connection keeps one entry, made as it is adopted.
;;; A deadline is armed at the loop's now, `uv_now`, which never steps, plus
;;; the kind's limit (limits-deadline-ms), never by the wall clock the Date
;;; is made from.  The first is armed as the connection is adopted, its idle
;;; one: the core starts it in idle with that deadline recorded, and asks
;;; for the next ones.  ONE TIMER TICKS THEM ALL, every tick-ms: made when a
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
;;; A TRANSPORT FAILURE IS A `read-error` (design §6.3): a read's error, and a
;;; write's or a shutdown's, whether chez-libuv raises it at the call or
;;; reports it at the completion.  A failed write is settled too, as
;;; `write-completed` with its byte count, once the `read-error` has closed
;;; the connection; the core settles a write a close cut short in `closing`
;;; (M3.3).  A write the close itself cancels is reported the same way.
;;;
;;; A BUG CLOSES ITS CONNECTION.  Whatever raises out of a connection's
;;; outermost dispatch drops the actions still queued, and one of them may
;;; have been the close, or the read that would have seen the client go: the
;;; connection is closed before the raise goes on to chez-libuv and the run
;;; loop.  An adoption that fails is closed the same way.
;;;
;;; THE DATE is made once a second (decision 0010).  The shell's clock is read
;;; when a second of the loop's own time has passed, libuv's cached
;;; milliseconds, which cost nothing to read; between readings the second is
;;; the last reading plus the loop's time since.  A response reads no clock.
;;;
;;; THE RUN LOOP (design §6.4, the first hazard; decision 0003 item 4).
;;; chez-libuv catches whatever a callback raises, and raises it again from
;;; uv-run composed with `&uv-callback-error`.  A `&byte-machine-contract` in
;;; it is a bug that has poisoned a parser: logged, the table reconciled, and
;;; raised again.  Any other callback error is logged, the table reconciled,
;;; and the loop runs on.  `&byte-machine-contract` derives from `&condition`,
;;; not `&error`, but the composition makes every callback's raise an
;;; `&error`, so what keeps a poisoned parser fatal is that its arm comes
;;; before the callback-error arm.  The run loop's own logging cannot take the
;;; failure's place: a log that raises there is ignored.
(library (http-server private shell)
  (export make-shell shell? shell-listen! shell-adopt! shell-shutdown! shell-run!
          shell-connections shell-server shell-listener shell-timer shell-deadlines
          connection? connection-state connection-tcp connection-violations
          connection-deadline
          connection-close!
          wall-clock)
  (import (rnrs)
          (only (chezscheme) current-time time-second time-nanosecond)
          (libuv)
          (byte-machine runtime)
          (only (byte-machine private conditions) byte-machine-contract-condition?)
          (only (http-server connection) make-conn-state)
          (only (http-server limits)
                limits-read-buffer-size limits-backlog limits-tick-ms limits-deadline-ms)
          (http-server wheel)
          (only (http-server server) make-server-state server-step server-phase)
          (only (http-server serializer) date-line)
          (http-server private adapter))

  ;; make-shell :
  ;;   UvLoop (Request -> Response) Limits (-> Nat) (Symbol (Listof Any) -> Any)
  ;;   [(Connection Symbol Any -> Any)] -> Shell
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
  ;; response's body among them.
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
    (fields loop handler limits clock log trace table wheel
            (mutable server)
            (mutable listener)
            (mutable timer) (mutable ticking?)  ; the timer, and whether it runs
            (mutable read-at) (mutable read-ms)       ; the clock's last reading, and when
            (mutable date-second) (mutable date-line)))

  (define make-shell
    (case-lambda
      ((loop handler limits clock log) (make-shell loop handler limits clock log #f))
      ((loop handler limits clock log trace)
       (%make-shell loop handler limits clock log trace (make-eq-hashtable)
                    (make-wheel (limits-tick-ms limits))
                    (make-server-state 'listening 0 limits) #f #f #f #f #f #f #f))))

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
            (mutable entry)))                 ; its deadline's, in the shell's wheel

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
  ;; connection in the table, its idle deadline armed, Nagle's algorithm off,
  ;; and reading started with the limits' buffer.  Nagle's algorithm would
  ;; hold a response's last partial segment until the client acknowledged
  ;; the ones before it, and the shell writes each response whole, in one
  ;; write; a socket that refuses the option has already failed, which
  ;; reading will report.  A start that raises goes on to shell-adopt!, which
  ;; closes the handle.
  (define (serve! sh tcp)
    (let ((c (make-connection sh tcp #f #f '() '() 0 '() #f #f #f #f #f #f)))
      (connection-entry-set! c (make-wheel-entry c))
      (connection-ctx-set! c (make-conn-context
                              (make-conn-state 'idle 'idle #f 0 0 #f #f (shell-limits sh))
                              (lambda (actions) (enqueue! c actions))))
      (connection-parser-set! c (make-conn-parser (connection-ctx c)))
      (connection-on-data-set! c (lambda (bv start end) (dispatch! c (list 'bytes-arrived bv start end))))
      (connection-on-eof-set! c (lambda () (dispatch! c '(eof))))
      (connection-on-error-set! c (lambda (e) (dispatch! c (list 'read-error (errno e)))))
      (hashtable-set! (shell-table sh) tcp c)
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

  ;; drain! : Connection -> Void — run the queue, in order, until it is empty.
  ;; A raise abandons the dispatch it came from: the depth is restored and
  ;; what is still queued is dropped.
  (define (drain! c)
    (let ((before (connection-depth c)))
      (dynamic-wind
       (lambda () (connection-depth-set! c (fx+ before 1)))
       (lambda ()
         (let loop ()
           (let ((a (dequeue! c)))
             (when a (run! c a) (loop)))))
       (lambda ()
         (connection-depth-set! c before)
         (connection-front-set! c '())
         (connection-back-set! c '())))))

  ;; run! : Connection Action -> Void
  ;; Record a violation if the action runs anywhere but the outermost drain,
  ;; then perform it.
  (define (run! c a)
    (unless (fx=? (connection-depth c) 1)
      (connection-violations-set! c (cons a (connection-violations c))))
    (trace! c 'action a)
    (case (car a)
      ((feed-parser) (feed! c (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (parser-resume! (connection-parser c)))
      ((call-handler) (call-handler! c (cadr a)))
      ((write) (write! c (cadr a) (caddr a)))
      ((read-stop) (read-stop! c))
      ((read-start) (read-start! c))
      ((shutdown) (shutdown! c))
      ((close) (connection-close! c))
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
  ;; Feed the parser bv[start, end), counting the feed in the depth, then
  ;; dispatch its result: the status, the bytes consumed, where to resume,
  ;; and the codes of its error and its pause.
  (define (feed! c bv start end)
    (connection-depth-set! c (fx+ (connection-depth c) 1))
    (let ((r (parser-feed! (connection-parser c) bv start end)))
      (connection-depth-set! c (fx- (connection-depth c) 1))
      (dispatch! c (list 'parser-result (parser-result-status r)
                         (parser-result-consumed r) (parser-result-next r)
                         (code (parser-result-error r))
                         (code (parser-result-pause r))))))

  ;; code : (U #f ParserError) -> (U #f Symbol)
  (define (code e) (and e (parser-error-code e)))

  ;; call-handler! : Connection Request -> Void
  ;; The handler's answer, or its failure, dispatched once the loop's clock
  ;; is brought up to date: a handler holds the loop while it runs, and the
  ;; deadline armed after its answer runs from when it returned.
  (define (call-handler! c request)
    (let ((answer (guard (e (#t (log! (connection-shell c) 'handler-failed (list e))
                                (list 'handler-failed e)))
                    (list 'handler-responded ((shell-handler (connection-shell c)) request)))))
      (uv-update-time! (shell-loop (connection-shell c)))
      (dispatch! c answer)))

  ;; write! : Connection (Listof Segment) Nat -> Void
  ;; One uv-write*! of the segments, the Date slot filled.
  (define (write! c segments nbytes)
    (let ((line (current-date-line (connection-shell c))))
      (guard (e ((transport-condition? e) (write-failed! c e nbytes)))
        (uv-write*! (connection-tcp c)
                    (map (lambda (seg) (if (eq? seg 'date) line seg)) segments)
                    (write-done c nbytes)))))

  ;; write-done : Connection Nat -> ((U #f Condition) -> Void)
  ;; A write's completion, which keeps the write's byte count and nothing of
  ;; its segments.
  (define (write-done c nbytes)
    (lambda (err)
      (if err
          (write-failed! c err nbytes)
          (dispatch! c (list 'write-completed nbytes)))))

  ;; write-failed! : Connection Condition Nat -> Void
  (define (write-failed! c err nbytes)
    (dispatch! c (list 'read-error (errno err)))
    (dispatch! c (list 'write-completed nbytes)))

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
  ;; kind's limit, moving the one it had, and see the timer runs.  A
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
  ;; is left: a shell that serves no more holds none.
  (define (release-timer! sh)
    (let ((timer (shell-timer sh)))
      (when (and timer
                 (fxzero? (hashtable-size (shell-table sh)))
                 (not (eq? (server-phase (shell-server sh)) 'listening)))
        (shell-timer-set! sh #f)
        (shell-ticking?-set! sh #f)
        (handle-close! sh timer))))

  ;; connection-close! : Connection -> Void — close the connection's handle.
  (define (connection-close! c)
    (handle-close! (connection-shell c) (connection-tcp c)))

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

  ;; shell-run! : Shell Symbol -> Boolean
  ;; One uv-run of the shell's loop in `mode`: whether work remains, as uv-run
  ;; answers, or #t after a callback's error, logged, so the caller runs
  ;; again.  A byte-machine contract condition is raised again.
  (define (shell-run! sh mode)
    (guard (e ((byte-machine-contract-condition? e)
               (log-quietly! sh 'contract-violation (list e))
               (reconcile! sh)
               (raise e))
              ((uv-callback-error? e)
               (log-quietly! sh 'callback-error (list e))
               (reconcile! sh)
               #t))
      (uv-run (shell-loop sh) mode)))

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
