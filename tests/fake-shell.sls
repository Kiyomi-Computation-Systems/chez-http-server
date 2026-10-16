#!r6rs
;;; (fake-shell) — the imperative shell as a test double.
;;;
;;; M1.4.  The real shell (design §5) delivers libuv events to the pure core and
;;; runs the actions it returns.  It was written before the core existed, so its
;;; own suite drives it against STUB steps the test supplies, and proves only
;;; what does not depend on connection semantics:
;;;
;;;   - it delivers scripted events IN ORDER and threads the step's state;
;;;   - it RECORDS every action the step returns, faithfully and in order;
;;;   - it takes time by INJECTION — a fake clock set and advanced explicitly,
;;;     never a real one, so a `tick` event carries the injected `now` and no
;;;     test ever sleeps (decision 0005, consequences).
;;;
;;; The step is `(step state event) -> (values state' (Listof Action))`, the
;;; shape of `conn-step` (design §4.1), so the real core drops in where a stub
;;; stands; tests/test-connection-table.sps runs it that way (M2.1).
;;;
;;; M2.4: THE MESSAGE LOOP.  Actions run after the outermost dispatch, in
;;; order, from one queue (design §4.5).  A dispatch made while that queue
;;; drains, or while the parser feeds, only queues, so no drain is ever nested
;;; inside another.  `depth` counts the drain and the feed inside it: every
;;; action must run at depth 1, from the outermost drain, and one that runs
;;; anywhere else is a VIOLATION, recorded.  That is design §6.4's check, a
;;; test rather than a comment, because the way it fails is silent:
;;; byte-machine poisons a parser whose callback escapes, and chez-libuv defers
;;; the raise.  Only `reply-parser` is answered inside a parser callback, and
;;; the adapter does that without reaching the queue.
;;;
;;; M3.5: A WRITE AFTER THE SHUTDOWN IS REFUSED.  The core shuts the write
;;; side only once its last write has completed (decision 0011), and nothing
;;; may be written after it: a `write` action run after a `shutdown` is the
;;; core's bug, an assertion violation where it happens.  Any raise from an
;;; action abandons its dispatch, and the shell dispatches the next event as
;;; it would have.
;;;
;;; M4.4: A TRACE sees what the shell does in the order it does it, as the
;;; libuv shell's does, so the cross-shell contract test (design §8.4) can
;;; compare the two: each event as it is dispatched, and each action as it
;;; runs, before it is performed; and, once the stream is taken, each event
;;; of the door's, `door`, as the libuv shell traces its own: a delivery to
;;; the taker or dropped, `(stream-read bv start end)` or `(stream-end why)`;
;;; a taker's write at its turn, `(stream-wrote why)`; the timer firing
;;; past the stream's deadline, `(stream-passed now)`; and its close's two
;;; stages, the half-close, `(stream-shut)`, and the close begun,
;;; `(stream-close)`.  And the events a
;;; later turn brings are delivered one at a time on request, so that test
;;; can deliver them where the libuv shell delivered its own, a taker's
;;; write with the libuv shell's outcome for it.
;;;
;;; M5.3: THE WHEEL.  A fake connection keeps its deadline in a wheel of its
;;; own, as the libuv shell keeps its connections' (decision 0005): armed at
;;; the fake clock's now plus the kind's limit (limits-deadline-ms), the idle
;;; deadline armed so when the connection is made, and disarmed on request.
;;; The fake clock is the test's own, and so is the timer: `fake-shell-fire!`
;;; is the timer firing at the clock's now, and it ticks the connection only
;;; once its deadline has passed.  A stub step's shell keeps no wheel, and
;;; `fake-shell-tick!` ticks its step, whatever it has armed.
;;;
;;; `make-fake-connection` is the shell M2.4 drives the core with: the core
;;; through the adapter's bindings, one real parser, and a handler that answers
;;; at once.  It performs what a v1 shell performs:
;;;
;;;   feed-parser     parser-feed!, then the result as `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler called from the connection's scheduler,
;;;                   drained once the outermost dispatch's drain has ended,
;;;                   as the libuv shell calls it after libuv's turn
;;;                   (decision 0014; M7.1): its answer, a response or a
;;;                   reader, as `handler-responded`, or `handler-failed` if
;;;                   it raises; or, if it answers `awaiting`, its thunk run
;;;                   on a coroutine (A HANDLER THAT WAITS, below)
;;;   deliver-body    the piece to the reader the core is handing the body to
;;;                   (conn-body-reader), or `handler-failed` if it raises;
;;;                   with no reader, nothing (M6.1, decision 0013)
;;;   deliver-body-end  the reader's end: its response as `handler-responded`,
;;;                   or `handler-failed` if it raises
;;;   notify-producer the producer a streamed response is written from
;;;                   (conn-producer), called for its next piece, its answer
;;;                   as `handler-body-chunk` or `handler-body-end`
;;;                   (producer-event), or `handler-failed` if it raises or
;;;                   answers neither; with no producer, nothing (M6.3,
;;;                   decision 0013 item 8)
;;;   write           fills the Date slot from the fake clock, or from the
;;;                   instant given for the write (fake-shell-date-writes!),
;;;                   keeps the bytes as the client would read them, and
;;;                   completes on a later turn, as `write-completed` with the
;;;                   write's byte count
;;;   read-stop/-start  whether the next delivery is read
;;;   shutdown        shuts the write side; `shutdown-completed` arrives on a
;;;                   later turn, as uv_shutdown's callback does
;;;   close           stops reading; `closed` arrives on a later turn
;;;   arm-deadline    arms the wheel at the clock's now plus the kind's limit
;;;   disarm-deadline disarms it
;;;
;;;   hand-off        the switch's take-over called with a transport over the
;;;                   fake connection and the bytes handed over, copied
;;;                   (THE DOOR, below)
;;;
;;; and records the rest (logs) without acting on them.  A fake connection made on credit (M6.2) answers with
;;; each handler's answer and `credit`, `(handler-responded answer credit)`,
;;; as a handler that waits is answered (A HANDLER THAT WAITS, below): the
;;; test then gives the reader's credit, `(body-credit n)`.
;;; Input is delivered only while the connection reads, as libuv delivers
;;; it.  An event the core cannot finish within `dispatch-cap` dispatches is
;;; a harness error, never a hang (global-constraints: cap by iteration
;;; count, never wall-clock).
;;;
;;; M8.2: THE DOOR (decision 0016).  Handed off, the connection is the
;;; taker's: the fake transport's verbs act on it as the libuv shell's do.
;;; A write's bytes, copied at the call, are the client's on a later turn,
;;; after the 101, and its callback is told then, #f; one asked for once the
;;; close has been is not written, and its callback is told ECANCELED at the
;;; connection's next drain, as the libuv shell tells it on its next turn.
;;; Reading delivers each delivery to the taker, `(on-bytes bv start end)`,
;;; and the client's end or a read error to its `on-end`, once, reading
;;; then stopped; none reaches the core.  What the client sends while the
;;; stream is not read, before the taker's read-start or after its
;;; read-stop, is kept, as the kernel keeps it, and read on a later turn
;;; once reading starts again, at a read-start or at the close, ahead of
;;; what comes after it (plan §14's review note).  An end the core read as the 101
;;; was written comes with the hand-off, and is told to the taker's
;;; read-start at the connection's next drain; a stream that has ended
;;; reads no more.  The close comes on a later turn, after the writes asked for
;;; before it, as `closed` to the core and the taker's close call, which,
;;; registered after it, runs at once.  The
;;; deadline is the connection's one wheel entry, and `fake-shell-fire!`
;;; calls it once its time has come; a stream closing arms none.
;;; `fake-shell-drain!` is the shell
;;; draining: the core told `shutdown-requested`, or a taker's drain call
;;; run, once, and one registered while the shell drains runs at once.
;;; A take-over that answers `(awaiting thunk)` has the thunk run on a
;;; coroutine, the taker's notice given to it, told once the stream has
;;; closed (decision 0023); a raise of it but that close is recorded
;;; (`fake-shell-taker-failures`) and closes the stream.  Each delivery to a
;;; taker and each of its completions is a turn of the libuv shell's, so
;;; the scheduler is drained after it, unless held.
;;;
;;; Decision 0024: A CLIENT THAT READS NOTHING.  A taker's write is
;;; outstanding until its turn, which stands for the client reading it, so a
;;; test that delivers no later turn plays a client that reads nothing.  A
;;; close asked for waits for the writes outstanding before it begins, as
;;; the libuv shell's does, so a deadline asked for meanwhile is armed; once
;;; begun, it disarms the deadline, as the libuv shell's close does.  Once
;;; the close has been asked for, the taker is read nothing more.  The
;;; abort, `transport-abort!`, begins the close at once: each write
;;; outstanding is told ECANCELED on its turn, and the client reads none of
;;; it.  (The libuv shell's client may still get what the system already
;;; held: a write libuv had written at the call, or part of one.  The fake
;;; keeps to whole writes, and is told the libuv shell's outcome of each
;;; where the contract test replays it: fake-shell-deliver-later!.)  Every call into the taker's
;;; code is guarded, as the libuv shell's taker-call! guards it: the
;;; take-over, its reads and its end, its deadline's, drain and close calls,
;;; and a write's callback.  A raise there, or from a waiting thunk, is the
;;; taker's failure, recorded, and aborts the stream.
;;;
;;; Decision 0026: THE CLOSE IS STAGED, as the libuv shell stages it.  Asked
;;; for, the taker is read nothing more, but the stream reads on, each
;;; delivery dropped.  Once no write is outstanding, the write side is shut
;;; (`fake-shell-shut?`) and the stream lingers, the linger deadline armed on
;;; the fake clock in the taker's deadline's place, until the client's end
;;; or that deadline's firing closes it; a read error closes it at once, as
;;; an abort does.  A client whose end came while the writes were
;;; outstanding is closed once they are written.  From the close on, the
;;; taker's read-stop changes nothing, and once the stream lingers neither
;;; does its deadline or its cancel.
;;;
;;; Decision 0027: A CLOSE'S WRITES ARE BOUNDED, as the libuv shell bounds
;;; them.  Until the stream lingers, each write the close waits for has the
;;; write timeout, from the close and again from each write's end, and past
;;; it the stream is aborted.  The taker's own deadline runs beside it: the
;;; one wheel entry is armed at the earlier, and once that one passes, the
;;; other is armed again.
;;;
;;; M7.3: A HANDLER THAT WAITS, as the libuv shell's (decision 0014), so
;;; the contract test (design §8.4) can hold the coroutine shell to it.  A
;;; fake connection keeps a scheduler of its own, (http-server private
;;; scheduler)'s, drained once each outermost dispatch has ended, as the
;;; libuv shell's turn drains its loop's after libuv's run: the handler is
;;; called there, and the coroutines run there.  A handler that answers
;;; `(awaiting thunk)` has its thunk run on a coroutine, and its answer
;;; dispatched on credit once it has ended.  Until the next request's
;;; handler is called, the connection's calls into the handler's code, its
;;; reader's pieces and end and its producer, are each made on a coroutine,
;;; one at a time, in order, each event its call brings dispatched once it
;;; has ended: a streaming reader's piece is credited, `(body-credit n)`,
;;; once the reader has taken it, whatever values the piece answers, none
;;; included, as the libuv shell's (the M7 exit).  A call that waits goes on
;;; when its connection closes, but what it answers is dropped, and the
;;; connection makes no more calls (decision 0015 item 4).  The fake drains its
;;; scheduler after every dispatch, so no event can close a connection
;;; between the dispatch that asks for the handler's call and that call, as
;;; libuv's turn can: it keeps none of the libuv shell's check for a handler
;;; whose connection closed before its call (M7.1's review).  It never
;;; polls: a coroutine that yields runs again at the connection's next
;;; drain.  Its handler code waits with (http-server private waits)'s verbs
;;; (decision 0015) on waits of its own, scripted: their clock is the
;;; injected one; their timer is the test's, `fake-shell-fire-waits!` firing
;;; it at the clock's now; and their resolver is the test's,
;;; `fake-shell-answer-lookup!` answering the lookup asked for, one at a
;;; time, as the connection's calls are made.  A deadline that ends a lookup
;;; cancels it, and the lookup is answered no more.
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events fake-shell-violations
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-fire! fake-shell-run!
          make-fake-connection fake-shell-conn-state fake-shell-reading? drops-body
          fake-shell-deliver-later! fake-shell-settle! fake-shell-feed-input!
          fake-shell-writes fake-shell-date-writes! written-status write-wire
          fake-shell-fire-waits! fake-shell-answer-lookup! fake-shell-drain! fake-shell-armed
          event->door-read door-read->event
          fake-shell-shut? fake-shell-hold! fake-shell-schedule! fake-shell-taker-failures)
  (import (rnrs)
          (byte-machine runtime)
          (only (http-server connection) make-conn-state conn-body-reader conn-producer producer-event)
          (only (http-server body) body-reader-on-piece body-reader-on-end body-reader-whole? read-body)
          (only (http-server awaiting) awaiting? awaiting-thunk client-closed?)
          (only (http-server private scheduler)
                make-scheduler scheduler-call! scheduler-spawn! scheduler-drain!)
          (only (http-server private waits) make-waits waits-clock! waits-fire! waits-resolver!
                make-notice notice-attach! notice-close! notice-closed?)
          (only (http-server limits) limits-tick-ms limits-deadline-ms)
          (http-server wheel)
          (only (http-server serializer) date-line)
          (only (http-server transport) make-transport)
          (http-server private adapter))

  ;; make-fake-shell : Step State Nat [Perform [Trace]] -> FakeShell
  ;;   Perform = FakeShell Action -> Any, run for each action as it is taken
  ;;   from the queue; without one (or with #f) the shell only records.
  ;;   Trace   = Symbol Any -> Any, called as (trace 'event event) when an
  ;;   event is dispatched and (trace 'action action) when an action runs,
  ;;   before it is performed; the datum is the event or action itself.
  ;; fake-shell? : Any -> Boolean
  ;; fake-shell-state : FakeShell -> State — the step's state, threaded
  ;; fake-shell-now : FakeShell -> Nat — the injected clock
  ;; fake-shell-reading? : FakeShell -> Boolean — whether the next delivery
  ;;   is read: #t until a read-stop or a close, and again at a read-start
  (define-record-type fake-shell
    (fields step (mutable state) (mutable now) (mutable actions-rev) (mutable events-rev)
            perform
            (mutable front) (mutable back)    ; the queue: front in order, back reversed
            (mutable depth)                   ; the drain, and a feed inside it
            (mutable violations-rev)
            (mutable later)                   ; events for a later turn, in order
            (mutable parser)
            (mutable reading?)
            (mutable dispatches)
            (mutable writes-rev)              ; the bytes of each write, newest first
            (mutable shut?)                   ; whether a shutdown has run
            trace
            (mutable wheel) (mutable entry)   ; a connection's deadline; #f for a stub's
            (mutable dated)                   ; instants its next writes are dated at, in order
            (mutable credit?)                 ; whether it answers on credit (M6.2)
            (mutable scheduler)               ; a connection's calls and coroutines; #f for a stub's
            (mutable waits?)                  ; whether the request's handler answered awaiting
            (mutable waiting)                 ; its calls on coroutines to make, in order
            (mutable calling?)                ; whether one of them runs
            (mutable closing?)                ; whether its close has run
            (mutable timed)                   ; a connection's waits, scripted (fake-waits)
            (mutable lookup)                  ; the lookup they asked for: (host . answer!), or #f
            (mutable taker)                   ; once handed off, the taker's calls (THE DOOR)
            (mutable draining?)               ; whether the shell has drained
            (mutable notice)                  ; the request's notice of its client's close, or #f
            (mutable held?)                   ; whether its scheduler waits to be drained (fake-shell-hold!)
            (mutable taker-failures-rev))     ; what a waiting taker's thunks raised, newest first (decision 0023)
    (protocol (lambda (new)
                (define (make step state0 now0 perform trace)
                  (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0 '() #f trace
                       #f #f '() #f #f #f '() #f #f #f #f #f #f #f #f '()))
                (case-lambda
                  ((step state0 now0) (make step state0 now0 #f #f))
                  ((step state0 now0 perform) (make step state0 now0 perform #f))
                  ((step state0 now0 perform trace) (make step state0 now0 perform trace))))))

  ;; trace! : FakeShell Symbol Any -> Void
  (define (trace! s kind datum)
    (let ((trace (fake-shell-trace s)))
      (when trace (trace kind datum))))

  ;; fake-shell-actions / -violations : FakeShell -> (Listof Action)
  ;; fake-shell-events : FakeShell -> (Listof Event)
  ;; fake-shell-writes : FakeShell -> (Listof Bytevector)
  ;; The actions run, the actions run anywhere but the outermost drain, the
  ;; events dispatched, and the bytes of each write a connection performed,
  ;; its Date slot filled, each in arrival order (the fields hold them
  ;; reversed, appended to as they arrive).
  (define (fake-shell-actions s) (reverse (fake-shell-actions-rev s)))
  (define (fake-shell-events s) (reverse (fake-shell-events-rev s)))
  (define (fake-shell-violations s) (reverse (fake-shell-violations-rev s)))
  (define (fake-shell-writes s) (reverse (fake-shell-writes-rev s)))

  ;; fake-shell-taker-failures : FakeShell -> (Listof Any)
  ;; What a waiting taker's thunks raised, in order, the close their notice
  ;; told not among them (decision 0023): the libuv shell logs each as
  ;; `taker-failed`.
  (define (fake-shell-taker-failures s) (reverse (fake-shell-taker-failures-rev s)))

  ;; fake-shell-advance! : FakeShell Nat -> Nat
  ;; Move the injected clock forward by `dt` and return the new now; it never
  ;; runs backwards.
  (define (fake-shell-advance! s dt)
    (when (< dt 0)
      (assertion-violation 'fake-shell-advance! "the fake clock never runs backwards" dt))
    (fake-shell-now-set! s (+ (fake-shell-now s) dt))
    (fake-shell-now s))

  ;; dispatch-cap : Nat — dispatches one shell may make before it is stuck.
  (define dispatch-cap 100000)

  ;; fake-shell-deliver! : FakeShell Event -> (Listof Action)
  ;; Dispatch one event: trace it, step it, thread the state, record the
  ;; event, queue the actions, and drain the queue unless a drain or a feed is
  ;; under way.  Once the outermost drain has ended, drain the connection's
  ;; scheduler (schedule!): the handler calls the drain queued and the
  ;; coroutines ready, in order, each answer a dispatch of its own.  Returns
  ;; this event's actions.  Once the stream is taken, a read or an end goes
  ;; to the taker (taker-read!) if the stream reads and nothing is kept, or
  ;; else is kept behind what is (THE DOOR), and returns none.
  (define (fake-shell-deliver! s event)
    (fake-shell-dispatches-set! s (+ (fake-shell-dispatches s) 1))
    (when (> (fake-shell-dispatches s) dispatch-cap)
      (assertion-violation 'fake-shell-deliver! "no progress: the dispatch cap was reached"
                           dispatch-cap event))
    (if (and (fake-shell-taker s) (memq (car event) '(bytes-arrived eof read-error)))
        (let ((tk (fake-shell-taker s)))
          (if (and (fake-shell-reading? s) (null? (fake-taker-kept tk)))
              (begin (trace! s 'door (event->door-read event))
                     (taker-read! s tk event)
                     (unless (fake-shell-held? s) (schedule! s)))
              (fake-taker-kept-set! tk (append (fake-taker-kept tk) (list event))))
          '())
        (step-event! s event)))

  ;; event->door-read : Event -> Datum
  ;; A read's event, `bytes-arrived`, `eof` or `read-error`, as a taken
  ;; stream's trace has it (THE DOOR): `(stream-read bv start end)`, or
  ;; `(stream-end why)`, 'eof or the errno, as the libuv shell traces its own.
  (define (event->door-read event)
    (case (car event)
      ((bytes-arrived) (cons 'stream-read (cdr event)))
      ((eof) '(stream-end eof))
      (else (list 'stream-end (cadr event)))))

  ;; door-read->event : Datum -> Event — a taken stream's read or end, as
  ;; its trace has it, as the read's event: event->door-read's inverse.
  (define (door-read->event datum)
    (cond ((eq? (car datum) 'stream-read) (cons 'bytes-arrived (cdr datum)))
          ((eq? (cadr datum) 'eof) '(eof))
          (else (list 'read-error (cadr datum)))))

  ;; step-event! : FakeShell Event -> (Listof Action) — fake-shell-deliver!'s
  ;; dispatch to the step.
  (define (step-event! s event)
    (trace! s 'event event)
    (call-with-values
     (lambda () ((fake-shell-step s) (fake-shell-state s) event))
     (lambda (state* actions)
       (fake-shell-state-set! s state*)
       (fake-shell-events-rev-set! s (cons event (fake-shell-events-rev s)))
       (enqueue! s actions)
       (when (= (fake-shell-depth s) 0)
         (drain! s)
         (unless (fake-shell-held? s) (schedule! s)))
       actions)))

  ;; fake-shell-hold! : FakeShell Boolean -> Void
  ;; Held, the connection's scheduler is drained only when asked
  ;; (fake-shell-schedule!), or as its waits fire or its lookup is answered,
  ;; not after each event: as the libuv shell drains its own once a turn of
  ;; the loop, after every event the turn brought (decision 0014).  The
  ;; contract test holds a fake it gives the libuv shell's events, and drains
  ;; it where a turn of the libuv shell's began (decision 0020: a client's
  ;; end can come in the turn a handler's call waits in).
  (define (fake-shell-hold! s held?) (fake-shell-held?-set! s held?))

  ;; fake-shell-schedule! : FakeShell -> Void — drain the connection's
  ;; scheduler now.
  (define (fake-shell-schedule! s) (schedule! s))

  ;; schedule! : FakeShell -> Void
  ;; Drain the connection's scheduler: what is ready, handler calls and
  ;; coroutines, oldest first, until nothing is, each answer a dispatch of
  ;; its own, which drains it again in turn.  A stub's shell has none.
  (define (schedule! s)
    (let ((sched (fake-shell-scheduler s)))
      (when sched (scheduler-drain! sched))))

  ;; enqueue! : FakeShell (Listof Action) -> Void — behind what is queued.
  (define (enqueue! s actions)
    (fake-shell-back-set! s (fold-left (lambda (acc a) (cons a acc)) (fake-shell-back s) actions)))

  ;; dequeue! : FakeShell -> (U #f Action) — the oldest queued action.
  (define (dequeue! s)
    (when (null? (fake-shell-front s))
      (fake-shell-front-set! s (reverse (fake-shell-back s)))
      (fake-shell-back-set! s '()))
    (let ((front (fake-shell-front s)))
      (and (pair? front)
           (begin (fake-shell-front-set! s (cdr front)) (car front)))))

  ;; drain! : FakeShell -> Void — run the queue, in order, until it is empty.
  ;; An action that raises abandons the dispatch it came from: the depth is
  ;; restored, a feed's inside it included, and the actions still queued are
  ;; dropped, so the shell dispatches the next event as it would have.
  (define (drain! s)
    (let ((before (fake-shell-depth s)))
      (dynamic-wind
       (lambda () (fake-shell-depth-set! s (+ before 1)))
       (lambda ()
         (let loop ()
           (let ((a (dequeue! s)))
             (when a (run! s a) (loop)))))
       (lambda ()
         (fake-shell-depth-set! s before)
         (fake-shell-front-set! s '())
         (fake-shell-back-set! s '())))))

  ;; run! : FakeShell Action -> Void
  ;; Record and trace the action, and a violation if it runs anywhere but the
  ;; outermost drain; then perform it.  A write after a shutdown is refused
  ;; first.  A stub step's action may be any datum, so only a tagged list is
  ;; read.
  (define (run! s a)
    (case (and (pair? a) (car a))
      ((write)
       (when (fake-shell-shut? s)
         (assertion-violation 'fake-shell "a write after the write side was shut" a)))
      ((shutdown) (fake-shell-shut?-set! s #t)))
    (unless (= (fake-shell-depth s) 1)
      (fake-shell-violations-rev-set! s (cons a (fake-shell-violations-rev s))))
    (fake-shell-actions-rev-set! s (cons a (fake-shell-actions-rev s)))
    (trace! s 'action a)
    (let ((perform (fake-shell-perform s)))
      (when perform (perform s a))))

  ;; fake-shell-tick! : FakeShell -> (Listof Action)
  ;; Deliver a `(tick now)` event carrying the injected now — the tagged-list
  ;; shape of (http-server connection)'s event vocabulary — to the step,
  ;; whatever deadline it has: what a stub step is ticked with.
  (define (fake-shell-tick! s) (fake-shell-deliver! s (list 'tick (fake-shell-now s))))

  ;; fake-shell-fire! : FakeShell -> (Listof Action)
  ;; A fake connection's timer fires at the injected now: its wheel is
  ;; advanced to now, and the connection ticked, `(tick now)`, only if its
  ;; deadline has passed.  Returns the tick's actions, or none when nothing
  ;; was ticked.  Once the stream is taken, the taker's deadline passing
  ;; makes its call, or its linger's close, and the turn ends with the
  ;; connection's scheduler drained unless held, as a delivery's does.  A
  ;; stub step's shell keeps no wheel, and firing it is an assertion
  ;; violation.
  (define (fake-shell-fire! s)
    (let ((wheel (fake-shell-wheel s)) (now (fake-shell-now s)))
      (unless wheel
        (assertion-violation 'fake-shell-fire! "a stub step's shell keeps no timer" s))
      (cond ((not (pair? (wheel-advance! wheel now))) '())
            ((fake-shell-taker s)
             (trace! s 'door (list 'stream-passed now))
             (taker-passed! s (fake-shell-taker s) now)
             (unless (fake-shell-held? s) (schedule! s))
             '())
            (else (fake-shell-deliver! s (list 'tick now))))))

  ;; fake-shell-run! : FakeShell (Listof Event) -> Void — deliver them in order.
  (define (fake-shell-run! s events)
    (for-each (lambda (e) (fake-shell-deliver! s e)) events))

  ;; later! : FakeShell Event -> Void — deliver `event` on a later turn.
  (define (later! s event)
    (fake-shell-later-set! s (append (fake-shell-later s) (list event))))

  ;; fake-shell-deliver-later! : FakeShell [(U #f Symbol)] -> (U Event (-> Any) DoorWrite #f)
  ;; Deliver the oldest event waiting for a later turn, a write's completion,
  ;; a half-close's or a close's, and return it; #f if none waits.  A
  ;; taker's close waits as a procedure, called then, and its write as a
  ;; door-write (THE DOOR).  Given an outcome, #f or the errno, the oldest
  ;; must be a taker's write, and its turn has that outcome, as the libuv
  ;; shell's write had: whether libuv had written it when its stream was
  ;; aborted is the kernel's, as how it divides the reads is.  Otherwise the
  ;; write's outcome is the fake's own: ECANCELED once aborted, else #f.
  (define fake-shell-deliver-later!
    (case-lambda
      ((s) (deliver-later! s #f #f))
      ((s outcome) (deliver-later! s #t outcome))))

  ;; deliver-later! : FakeShell Boolean (U #f Symbol) -> (U Event (-> Any) DoorWrite #f)
  (define (deliver-later! s given? outcome)
    (let ((later (fake-shell-later s)))
      (and (pair? later)
           (let ((item (car later)))
             (when (and given? (not (door-write? item)))
               (assertion-violation 'fake-shell-deliver-later! "an outcome for a write, and no taker's write waits"
                                    outcome item))
             (fake-shell-later-set! s (cdr later))
             (cond ((door-write? item)
                    ((door-write-turn item) given? outcome)
                    (unless (fake-shell-held? s) (schedule! s)))
                   ((procedure? item) (item) (unless (fake-shell-held? s) (schedule! s)))
                   (else (fake-shell-deliver! s item)))
             item))))

  ;; fake-shell-settle! : FakeShell -> Void
  ;; Deliver the events waiting for a later turn, oldest first, until none
  ;; wait: a write's completion, a close's `closed`.  Each turn begins as
  ;; the libuv shell's does, with the connection's scheduler drained unless
  ;; held, so what was deferred to it between turns is called: a write's
  ;; ECANCELED, asked for after the close (THE DOOR).
  (define (fake-shell-settle! s)
    (unless (fake-shell-held? s) (schedule! s))
    (when (fake-shell-deliver-later! s)
      (fake-shell-settle! s)))

  ;; --- the connection ---------------------------------------------------------

  ;; make-fake-connection : Limits (Request -> Answer) [Trace [Nat [Boolean]]] -> FakeShell
  ;;   Answer = Response | BodyReader | Awaiting
  ;; A connection in idle, reading, the clock at `now` (0 unless given), and
  ;; its idle deadline armed there: (http-server connection)'s core through
  ;; the adapter, with a parser of its own, a scheduler of its own, and
  ;; `handler` answering every request, traced as make-fake-shell traces.
  ;; Made `on-credit?`, it answers with each answer and `credit` (M6.2).
  ;; Its state is the adapter's context; fake-shell-conn-state reads the
  ;; core's state from it.
  (define make-fake-connection
    (case-lambda
      ((limits handler) (make-fake-connection limits handler #f 0 #f))
      ((limits handler trace) (make-fake-connection limits handler trace 0 #f))
      ((limits handler trace now) (make-fake-connection limits handler trace now #f))
      ((limits handler trace now on-credit?)
       (let* ((cell #f)
              (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f limits)
                                      (lambda (actions) (enqueue! cell actions))))
              (s (make-fake-shell (lambda (ctx event) (values ctx (conn-context-step! ctx event)))
                                  ctx now
                                  (lambda (s a) (perform-connection! s a handler limits))
                                  trace)))
         (set! cell s)
         (fake-shell-credit?-set! s on-credit?)
         (fake-shell-scheduler-set!
          s (make-scheduler
             (lambda (mode) (assertion-violation 'fake-shell "the fake never polls" mode))))
         (fake-shell-timed-set! s (fake-waits s))
         (fake-shell-parser-set! s (make-conn-parser ctx))
         (fake-shell-wheel-set! s (make-wheel (limits-tick-ms limits)))
         (fake-shell-entry-set! s (make-wheel-entry s))
         (arm! s limits 'idle)
         s))))

  ;; drops-body : (Request -> Response) -> (Request -> BodyReader)
  ;; A handler for a fake connection: it reads every request's body,
  ;; dropping it, then answers what `answer` gives for the request.  A
  ;; request with no body gets its reader's end at once.  A response given in
  ;; place of a reader to a request whose head announces a body closes the
  ;; connection (decision 0013), so suites that keep the connection past a
  ;; body read it with this.
  (define (drops-body answer)
    (lambda (request) (read-body (lambda (bv from to) #t) (lambda () (answer request)))))

  ;; fake-shell-conn-state : FakeShell -> ConnState
  (define (fake-shell-conn-state s) (conn-context-state (fake-shell-state s)))

  ;; arm! : FakeShell Limits Symbol -> Void
  ;; Arm the connection's deadline of `kind`: the clock's now plus its limit.
  (define (arm! s limits kind)
    (wheel-arm! (fake-shell-wheel s) (fake-shell-entry s)
                (+ (fake-shell-now s) (limits-deadline-ms limits kind))))

  ;; perform-connection! : FakeShell Action (Request -> Answer) Limits -> Void
  (define (perform-connection! s a handler limits)
    (case (car a)
      ((feed-parser) (feed! s (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (fake-shell-notice-set! s #f) (parser-resume! (fake-shell-parser s)))
      ((call-handler)
       (let ((request (cadr a)))
         (fake-shell-waits?-set! s #f)
         (scheduler-call! (fake-shell-scheduler s)
           (lambda ()
             (let ((event (guard (e (#t (list 'handler-failed e)))
                            (answered s (handler request) #t))))
               (when event (fake-shell-deliver! s event)))))))
      ((deliver-body)
       (let ((r (conn-body-reader (fake-shell-conn-state s)))
             (bv (cadr a)) (start (caddr a)) (end (cadddr a)))
         (when r
           (if (fake-shell-waits? s)
               (call-waiting! s (lambda () ((body-reader-on-piece r) bv start end) #t)
                              (lambda (v) (and (not (body-reader-whole? r))
                                               (list 'body-credit (- end start)))))
               (guard (e (#t (fake-shell-deliver! s (list 'handler-failed e))))
                 ((body-reader-on-piece r) bv start end))))))
      ((deliver-body-end)
       (let ((r (conn-body-reader (fake-shell-conn-state s))))
         (when r
           (if (fake-shell-waits? s)
               (call-waiting! s (body-reader-on-end r) (lambda (v) (answered s v #f)))
               (let ((event (guard (e (#t (list 'handler-failed e)))
                              (answered s ((body-reader-on-end r)) #f))))
                 (when event (fake-shell-deliver! s event)))))))
      ((notify-producer)
       (let ((p (conn-producer (fake-shell-conn-state s))))
         (when p
           (if (fake-shell-waits? s)
               (call-waiting! s p producer-event)
               (fake-shell-deliver! s (guard (e (#t (list 'handler-failed e)))
                                        (producer-event (p))))))))
      ((write) (write! s (cadr a) (caddr a)))
      ((read-stop) (fake-shell-reading?-set! s #f))
      ((read-start) (fake-shell-reading?-set! s #t))
      ((shutdown) (later! s '(shutdown-completed)))
      ((close) (fake-shell-reading?-set! s #f) (fake-shell-closing?-set! s #t) (later! s '(closed)))
      ((arm-deadline) (arm! s limits (cadr a)))
      ((disarm-deadline) (wheel-disarm! (fake-shell-wheel s) (fake-shell-entry s)))
      ((hand-off) (hand-off! s (cadr a) (caddr a) (cadddr a) limits))
      ((client-closed) (notice-close! (request-notice s)))
      (else (values))))

  ;; request-notice : FakeShell -> Notice
  ;; The notice of the request in flight (decision 0020), as the libuv
  ;; shell's: the one its code's coroutines were given, or else a new one.
  (define (request-notice s)
    (or (fake-shell-notice s)
        (let ((n (make-notice)))
          (fake-shell-notice-set! s n)
          n)))

  ;; --- the door (M8.2) ----------------------------------------------------------

  ;; door-write : a taker's write waiting for its turn, `turn` called then
  ;; with whether an outcome was given and the outcome
  ;; (fake-shell-deliver-later!).
  (define-record-type door-write (fields turn))

  ;; The calls a taker has registered, how far its stream has gone, the
  ;; notice its waits are told the close by, once a take-over has answered
  ;; `awaiting` (decision 0023), how many of its writes are outstanding,
  ;; whether it aborted, whether the client's end has come (decision 0024),
  ;; whether the stream lingers, and how long it may (decision 0026); the
  ;; end the core handed over, 'eof, until the taker is told it at its
  ;; read-start, else #f (0016's amendment of 2026-10-12); what the client
  ;; sent while the stream was not read, its reads and its end, in order,
  ;; kept as the kernel keeps them (read-kept!); and the instants, by the
  ;; fake clock, its own deadline passes at and its close's write bound
  ;; does, each #f when none is armed, and how long a write may take
  ;; (decision 0027).
  (define-record-type fake-taker
    (fields (mutable on-bytes) (mutable on-end) (mutable on-passed) (mutable on-drain)
            (mutable on-close) (mutable closing?) (mutable drained?) (mutable closed?)
            (mutable notice) (mutable writes) (mutable aborted?) (mutable ended?)
            (mutable lingering?) (mutable unheard) (mutable kept) (mutable due) (mutable bound)
            linger-ms write-ms)
    (protocol (lambda (new)
                (lambda (linger-ms write-ms)
                  (new #f #f #f #f #f #f #f #f #f 0 #f #f #f #f '() #f #f linger-ms write-ms)))))

  ;; hand-off! : FakeShell (Transport Bytevector -> Any) (U #f (List Bytevector Nat Nat)) Boolean Limits -> Void
  ;; The switch's take-over, called with a transport over the connection and
  ;; the bytes handed over, a copy, empty when none were.  A client's end
  ;; the core read as the 101 was written, `ended?`, is the taker's: the
  ;; stream has ended, and its read-start is told it, as the libuv shell's
  ;; is (0016's amendment of 2026-10-12).
  ;; A take-over that answers `(awaiting thunk)` has the thunk run on a
  ;; coroutine, as the libuv shell runs it (taker-wait!, decision 0023).
  (define (hand-off! s take-over retained ended? limits)
    (let ((tk (make-fake-taker (limits-deadline-ms limits 'linger) (limits-deadline-ms limits 'write)))
          (answer #f))
      (when ended?
        (fake-taker-ended?-set! tk #t)
        (fake-taker-unheard-set! tk 'eof))
      (fake-shell-taker-set! s tk)
      (taker-call! s tk
        (lambda ()
          (call-with-values
            (lambda ()
              (take-over (fake-transport s tk)
                         (if retained (copy-of (car retained) (cadr retained) (caddr retained)) (make-bytevector 0))))
            (lambda vs (when (and (pair? vs) (null? (cdr vs))) (set! answer (car vs)))))))
      (when (awaiting? answer) (taker-wait! s tk (awaiting-thunk answer)))))

  ;; taker-wait! : FakeShell FakeTaker (-> Any) -> Void
  ;; The thunk on a coroutine, the taker's notice given to it; a raise but
  ;; the close the notice told is the taker's failure, recorded, and closes
  ;; the stream at once (taker-abort!); what it returns is dropped, however
  ;; many values, as the libuv shell's taker-wait! drops it.
  (define (taker-wait! s tk thunk)
    (let ((n (make-notice)))
      (fake-taker-notice-set! tk n)
      (notice-attach!
       (scheduler-spawn! (fake-shell-scheduler s) (lambda () (thunk) #t)
         (lambda (kind v)
           (when (and (eq? kind 'raised) (not (and (client-closed? v) (notice-closed? n))))
             (fake-shell-taker-failures-rev-set! s (cons v (fake-shell-taker-failures-rev s)))
             (taker-abort! s tk))))
       n)))

  ;; taker-call! : FakeShell FakeTaker (-> Any) -> Void
  ;; A call into the taker's code.  A raise is the taker's failure,
  ;; recorded, and closes the stream at once, as the libuv shell's
  ;; taker-call! logs it and closes (decision 0024).
  (define (taker-call! s tk thunk)
    (guard (e (#t (fake-shell-taker-failures-rev-set! s (cons e (fake-shell-taker-failures-rev s)))
                  (taker-abort! s tk)))
      (thunk)))

  ;; taker-close! : FakeShell FakeTaker -> Void
  ;; The stream's staged close, asked for once (decision 0026): the taker is
  ;; read nothing more, the stream reading on, each delivery dropped, and it
  ;; lingers once no write is outstanding, as the libuv shell's does; until
  ;; then its writes are bounded (taker-bound!).
  (define (taker-close! s tk)
    (unless (fake-taker-closing? tk)
      (fake-taker-closing?-set! tk #t)
      (if (fake-taker-ended? tk)
          (fake-shell-reading?-set! s #f)
          (reading-begun! s tk))
      (if (fxzero? (fake-taker-writes tk))
          (linger-begun! s tk)
          (taker-bound! s tk))))

  ;; taker-bound! : FakeShell FakeTaker -> Void
  ;; The close waits for a write: it has the write timeout from the fake
  ;; clock's now, and the stream is aborted past it (decision 0027), armed
  ;; beside the taker's own deadline (taker-arm!).
  (define (taker-bound! s tk)
    (fake-taker-bound-set! tk (+ (fake-shell-now s) (fake-taker-write-ms tk)))
    (taker-arm! s tk))

  ;; taker-arm! : FakeShell FakeTaker -> Void
  ;; The stream's one wheel entry armed at the earlier of the taker's own
  ;; deadline and its close's write bound, or disarmed when neither is
  ;; armed, as the libuv shell's.  A stream closing is armed no more.
  (define (taker-arm! s tk)
    (let ((due (fake-taker-due tk)) (bound (fake-taker-bound tk)))
      (cond ((fake-shell-closing? s))
            ((or due bound)
             (wheel-arm! (fake-shell-wheel s) (fake-shell-entry s)
                         (if (and due bound) (min due bound) (or due bound))))
            (else (wheel-disarm! (fake-shell-wheel s) (fake-shell-entry s))))))

  ;; taker-passed! : FakeShell FakeTaker Nat -> Void
  ;; Its entry has passed at `now`: the stream lingering, its close; its
  ;; close's write bound passed, its abort (decision 0027); else its own
  ;; deadline, whose call is made, and then whichever is still armed is
  ;; armed again, as the libuv shell's taker-passed! has it.
  (define (taker-passed! s tk now)
    (cond ((fake-taker-lingering? tk) (close-begun! s tk))
          ((let ((bound (fake-taker-bound tk))) (and bound (<= bound now))) (taker-abort! s tk))
          (else
           (fake-taker-due-set! tk #f)
           (let ((passed (fake-taker-on-passed tk)))
             (when passed (taker-call! s tk passed)))
           (taker-arm! s tk))))

  ;; reading-begun! : FakeShell FakeTaker -> Void
  ;; The stream reads: what was kept while it did not is read on a later
  ;; turn (read-kept!), as libuv reads what the kernel kept once its reads
  ;; start, never inside the call that starts them.
  (define (reading-begun! s tk)
    (fake-shell-reading?-set! s #t)
    (when (pair? (fake-taker-kept tk))
      (later! s (lambda () (read-kept! s tk)))))

  ;; read-kept! : FakeShell FakeTaker -> Void
  ;; What was kept read now, oldest first, each traced as it is read, while
  ;; the stream reads: a taker that stops reading at one leaves the rest
  ;; kept for its next read-start, as libuv reads no more once stopped.
  (define (read-kept! s tk)
    (let ((kept (fake-taker-kept tk)))
      (when (and (pair? kept) (fake-shell-reading? s))
        (fake-taker-kept-set! tk (cdr kept))
        (trace! s 'door (event->door-read (car kept)))
        (taker-read! s tk (car kept))
        (read-kept! s tk))))

  ;; linger-begun! : FakeShell FakeTaker -> Void
  ;; The close's writes are written.  A client whose end has come is closed
  ;; now; any other has the write side shut, and the stream lingers, the
  ;; linger deadline armed on the fake clock in the taker's deadline's place.
  (define (linger-begun! s tk)
    (cond ((fake-shell-closing? s))
          ((fake-taker-ended? tk) (close-begun! s tk))
          (else
           (fake-taker-lingering?-set! tk #t)
           (trace! s 'door '(stream-shut))
           (fake-shell-shut?-set! s #t)
           (wheel-arm! (fake-shell-wheel s) (fake-shell-entry s)
                       (+ (fake-shell-now s) (fake-taker-linger-ms tk))))))

  ;; taker-abort! : FakeShell FakeTaker -> Void
  ;; The stream closed now, whatever is outstanding: the taker stops, each
  ;; write outstanding is told ECANCELED on its turn, its bytes never the
  ;; client's, and the close begins (decision 0024).
  (define (taker-abort! s tk)
    (stop-taking! s tk)
    (fake-taker-aborted?-set! tk #t)
    (close-begun! s tk))

  ;; stop-taking! : FakeShell FakeTaker -> Void
  ;; The taker's close asked for: it is written and read nothing more.
  (define (stop-taking! s tk)
    (fake-taker-closing?-set! tk #t)
    (fake-shell-reading?-set! s #f))

  ;; close-begun! : FakeShell FakeTaker -> Void
  ;; The handle's close, once: nothing more is armed, and after the turn,
  ;; behind the writes' turns before it, the core is told `closed`, the
  ;; taker's waits are told, and its close call runs.
  (define (close-begun! s tk)
    (unless (fake-shell-closing? s)
      (trace! s 'door '(stream-close))
      (fake-shell-closing?-set! s #t)
      (wheel-disarm! (fake-shell-wheel s) (fake-shell-entry s))
      (later! s (lambda ()
                  (fake-shell-deliver! s '(closed))
                  (fake-taker-closed?-set! tk #t)
                  (let ((n (fake-taker-notice tk))) (when n (notice-close! n)))
                  (let ((closed (fake-taker-on-close tk))) (when closed (taker-call! s tk closed)))))))

  ;; copy-of : Bytevector Nat Nat -> Bytevector — bv[from, to), copied.
  (define (copy-of bv from to)
    (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o))

  ;; fake-transport : FakeShell FakeTaker -> Transport
  ;; The verbs over the fake connection, as THE DOOR in the header has them.
  (define (fake-transport s tk)
    (make-transport
     (lambda (bv start end written)
       (if (fake-taker-closing? tk)
           (when written
             (scheduler-call! (fake-shell-scheduler s)
                              (lambda () (taker-call! s tk (lambda () (written 'ECANCELED))))))
           (let ((bytes (copy-of bv start end)))
             (fake-taker-writes-set! tk (fx+ (fake-taker-writes tk) 1))
             (later! s (make-door-write
                        (lambda (given? outcome)
                          (taker-wrote! s tk bytes written
                                        (if given? outcome (and (fake-taker-aborted? tk) 'ECANCELED)))))))))
     (lambda (on-bytes on-end)
       (fake-taker-on-bytes-set! tk on-bytes)
       (fake-taker-on-end-set! tk on-end)
       (cond ((fake-taker-closing? tk))
             ((fake-taker-ended? tk)
              (let ((why (fake-taker-unheard tk)))
                (when why
                  (fake-taker-unheard-set! tk #f)
                  (scheduler-call! (fake-shell-scheduler s)
                                   (lambda ()
                                     (unless (or (fake-taker-closing? tk) (fake-shell-closing? s))
                                       (taker-call! s tk (lambda () (on-end why)))))))))
             (else (reading-begun! s tk))))
     (lambda () (unless (fake-taker-closing? tk) (fake-shell-reading?-set! s #f)))
     (lambda () (taker-close! s tk))
     (lambda (ms passed)
       (unless (fake-taker-lingering? tk)
         (fake-taker-on-passed-set! tk passed)
         (fake-taker-due-set! tk (and ms (+ (fake-shell-now s) ms)))
         (taker-arm! s tk)))
     (lambda (thunk)
       (fake-taker-on-drain-set! tk thunk)
       (when (fake-shell-draining? s) (drain-taker! s tk)))
     (lambda (thunk)
       (fake-taker-on-close-set! tk thunk)
       (when (fake-taker-closed? tk) (taker-call! s tk thunk)))
     (lambda () (taker-abort! s tk))))

  ;; taker-wrote! : FakeShell FakeTaker Bytevector (U #f ((U #f Symbol) -> Any)) (U #f Symbol) -> Void
  ;; A write's turn, its outcome `why`: no longer outstanding, and, written,
  ;; its bytes the client's and its callback told #f; or neither, its
  ;; callback told the errno, ECANCELED for a stream aborted before it; then,
  ;; if the close was asked for, the stream lingering once no write is left,
  ;; or else its write bound armed again (decision 0027).
  (define (taker-wrote! s tk bytes written why)
    (trace! s 'door (list 'stream-wrote why))
    (fake-taker-writes-set! tk (fx- (fake-taker-writes tk) 1))
    (unless why
      (fake-shell-writes-rev-set! s (cons bytes (fake-shell-writes-rev s))))
    (when written
      (taker-call! s tk (lambda () (written why))))
    (when (fake-taker-closing? tk)
      (if (fxzero? (fake-taker-writes tk))
          (linger-begun! s tk)
          (taker-bound! s tk))))

  ;; taker-read! : FakeShell FakeTaker Event -> Void
  ;; A delivery, the client's end or a read error, to the taker: each read
  ;; to its on-bytes, and the end to its on-end, once.  Once the taker's
  ;; close has been asked for, or its end told, nothing reaches it.  While
  ;; the stream closes, a read is dropped, the client's end closes it once no
  ;; write is outstanding, and a read error closes it at once (decision 0026).
  (define (taker-read! s tk event)
    (cond
     ((or (fake-taker-ended? tk) (fake-shell-closing? s)))
     ((fake-taker-closing? tk)
      (unless (eq? (car event) 'bytes-arrived)
        (fake-taker-ended?-set! tk #t)
        (fake-shell-reading?-set! s #f)
        (cond ((not (eq? (car event) 'eof)) (taker-abort! s tk))
              ((fxzero? (fake-taker-writes tk)) (close-begun! s tk)))))
     (else
      (case (car event)
        ((bytes-arrived)
         (taker-call! s tk (lambda () ((fake-taker-on-bytes tk) (cadr event) (caddr event) (cadddr event)))))
        (else
         (let ((on-end (fake-taker-on-end tk)))
           (when on-end
             (fake-taker-ended?-set! tk #t)
             (fake-shell-reading?-set! s #f)
             (taker-call! s tk (lambda () (on-end (if (eq? (car event) 'eof) 'eof (cadr event))))))))))))

  ;; fake-shell-armed : FakeShell -> (U Nat #f)
  ;; The instant a fake connection's deadline passes at, its core's or, once
  ;; handed off, its taker's; #f while none is armed.
  (define (fake-shell-armed s) (wheel-entry-deadline (fake-shell-entry s)))

  ;; fake-shell-drain! : FakeShell -> Void
  ;; The shell drains: a connection handed off has its taker's drain call
  ;; run, once; any other is told `shutdown-requested`.
  (define (fake-shell-drain! s)
    (unless (fake-shell-draining? s)
      (fake-shell-draining?-set! s #t)
      (if (fake-shell-taker s)
          (drain-taker! s (fake-shell-taker s))
          (fake-shell-deliver! s '(shutdown-requested)))))

  ;; drain-taker! : FakeShell FakeTaker -> Void — its drain call, once, if
  ;; it has one.
  (define (drain-taker! s tk)
    (let ((drain (fake-taker-on-drain tk)))
      (when (and drain (not (fake-taker-drained? tk)))
        (fake-taker-drained?-set! tk #t)
        (taker-call! s tk drain))))

  ;; fake-waits : FakeShell -> Waits
  ;; The waits of the connection's scheduler: their clock the injected one,
  ;; their timer the test's (fake-shell-fire-waits!), and their resolver the
  ;; test's, a lookup kept until fake-shell-answer-lookup! answers it, or a
  ;; deadline cancels it: one at a time, as a connection's calls are made,
  ;; so a second while one waits is an assertion violation.  What they
  ;; would log, a late resume, is dropped.
  (define (fake-waits s)
    (let ((w (make-waits (fake-shell-scheduler s) (lambda (what details) (values)))))
      (waits-clock! w (lambda () (fake-shell-now s)) (lambda (ms) (values)) (lambda () (values)))
      (waits-resolver! w
                       (lambda (host answer!)
                         (when (fake-shell-lookup s)
                           (assertion-violation 'fake-shell "a second lookup while one waits" host))
                         (fake-shell-lookup-set! s (cons host answer!))
                         (fake-shell-lookup s))
                       (lambda (request)
                         (when (eq? request (fake-shell-lookup s))
                           (fake-shell-lookup-set! s #f))))
      w))

  ;; fake-shell-fire-waits! : FakeShell -> Void
  ;; The timer of a connection's waits fires at the injected now: each sleep
  ;; and deadline due by then ends (waits-fire!), and what that wakes runs.
  (define (fake-shell-fire-waits! s)
    (waits-fire! (fake-shell-timed s))
    (schedule! s))

  ;; fake-shell-answer-lookup! : FakeShell (U Symbol #f) (Listof String) -> Void
  ;; The lookup a connection's handler code asked for, unanswered, answered
  ;; with `reason` and `addresses`, as a resolver answers (#f and the
  ;; addresses, or the reason it failed, such as EAI_NONAME, and '()), and
  ;; what that wakes run; with none waiting, nothing.
  (define (fake-shell-answer-lookup! s reason addresses)
    (let ((lookup (fake-shell-lookup s)))
      (when lookup
        (fake-shell-lookup-set! s #f)
        ((cdr lookup) reason addresses)
        (schedule! s))))

  ;; answered : FakeShell Any Boolean -> (U Event #f)
  ;; The event an answer brings, as the libuv shell's: the handler's or, not
  ;; `handler?`, a reader's at its end: `(handler-responded answer)`, and
  ;; `credit` after the handler's on a connection made on credit or once the
  ;; handler waits; or, for `awaiting`, none yet: its thunk is called on a
  ;; coroutine (call-waiting!), and its answer answered so in turn.
  (define (answered s a handler?)
    (cond
     ((awaiting? a)
      (fake-shell-waits?-set! s #t)
      (call-waiting! s (awaiting-thunk a) (lambda (v) (answered s v handler?)))
      #f)
     ((and handler? (or (fake-shell-waits? s) (fake-shell-credit? s)))
      (list 'handler-responded a 'credit))
     (else (list 'handler-responded a))))

  ;; call-waiting! : FakeShell (-> Any) (Any -> (U Event #f)) -> Void
  ;; Call `thunk` on a coroutine, after the connection's calls before it:
  ;; once it has ended, the event `->event` makes of its value is
  ;; dispatched, or `handler-failed` if either raised; then the next call
  ;; starts.  A connection closing makes no more, and drops what one that
  ;; ends then answers.  Each coroutine is given the request's notice, as the
  ;; libuv shell's (decision 0020).
  (define (call-waiting! s thunk ->event)
    (fake-shell-waiting-set! s (append (fake-shell-waiting s) (list (cons thunk ->event))))
    (unless (fake-shell-calling? s) (next-call! s)))

  ;; next-call! : FakeShell -> Void — start the oldest call waiting, if any.
  (define (next-call! s)
    (let ((calls (fake-shell-waiting s)))
      (cond
       ((or (null? calls) (fake-shell-closing? s))
        (fake-shell-waiting-set! s '())
        (fake-shell-calling?-set! s #f))
       (else
        (let ((call (car calls)))
          (fake-shell-waiting-set! s (cdr calls))
          (fake-shell-calling?-set! s #t)
          (notice-attach!
           (scheduler-spawn! (fake-shell-scheduler s) (car call)
             (lambda (kind v)
               (let ((event (guard (e (#t (list 'handler-failed e)))
                              (if (eq? kind 'raised) (raise v) ((cdr call) v)))))
                 (when (and event (not (fake-shell-closing? s)))
                   (fake-shell-deliver! s event)))
               (next-call! s)))
           (request-notice s)))))))

  ;; fake-shell-date-writes! : FakeShell (Listof Nat) -> Void
  ;; Date the connection's next writes at `instants`, one each, in order,
  ;; rather than at the clock's now; once they run out, a write is dated at
  ;; the clock's now again.  The contract test gives its fake the instants
  ;; the libuv shell dated its own writes at, which can be a moment after the
  ;; event the fake's clock stands at.
  (define (fake-shell-date-writes! s instants) (fake-shell-dated-set! s instants))

  ;; write! : FakeShell (Listof Segment) Nat -> Void
  ;; Perform `(write segments nbytes)` as a shell does: the bytes are kept as
  ;; write-wire makes them, for the second of the write's instant (the clock
  ;; counts milliseconds, decision 0005's unit), and the write completes on a
  ;; later turn with its byte count.
  (define (write! s segments nbytes)
    (let ((wire (write-wire segments nbytes (div (write-instant! s) 1000))))
      (fake-shell-writes-rev-set! s (cons wire (fake-shell-writes-rev s)))
      (later! s (list 'write-completed nbytes))))

  ;; write-instant! : FakeShell -> Nat
  ;; The instant a write is dated at: the first of those given for the next
  ;; writes, taken, or the clock's now when none is left.
  (define (write-instant! s)
    (let ((dated (fake-shell-dated s)))
      (if (pair? dated)
          (begin (fake-shell-dated-set! s (cdr dated)) (car dated))
          (fake-shell-now s))))

  ;; write-wire : (Listof Segment) Nat Nat -> Bytevector
  ;; The bytes `(write segments nbytes)` puts on the wire, copied out of the
  ;; segments as uv-write*! copies them, a span `(bv start end)` as the bytes
  ;; it spans (M6.3), with the Date slot filled with the line for `second`
  ;; (decision 0010 item 4).  The count must be the bytes' own, which the
  ;; serializer promises: one that is not is an assertion violation, never a
  ;; quiet pass.
  (define (write-wire segments nbytes second)
    (let* ((line (date-line second))
           (parts (map (lambda (seg)
                         (cond ((eq? seg 'date) line)
                               ((pair? seg)
                                (let ((o (make-bytevector (- (caddr seg) (cadr seg)))))
                                  (bytevector-copy! (car seg) (cadr seg) o 0 (bytevector-length o))
                                  o))
                               (else seg)))
                       segments))
           (wire (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 parts))))
      (fold-left (lambda (at bv)
                   (bytevector-copy! bv 0 wire at (bytevector-length bv))
                   (+ at (bytevector-length bv)))
                 0 parts)
      (unless (= nbytes (bytevector-length wire))
        (assertion-violation 'fake-shell "a write's byte count is not its bytes'"
                             nbytes (bytevector-length wire)))
      wire))

  ;; written-status : Action -> Nat
  ;; The status a `(write segments nbytes)` action writes: the three digits
  ;; after `HTTP/1.1 ` in its first segment, the status line.
  (define (written-status a)
    (let ((line (car (cadr a))))
      (+ (* 100 (- (bytevector-u8-ref line 9) 48))
         (* 10 (- (bytevector-u8-ref line 10) 48))
         (- (bytevector-u8-ref line 11) 48))))

  ;; feed! : FakeShell Bytevector Nat Nat -> Void
  ;; Feed the parser bv[start, end), counting the feed in the depth, then
  ;; dispatch its result as the adapter builds it: the status, where the
  ;; parser is, where to resume, the code of its error or its pause, and the
  ;; span an error abandoned.
  (define (feed! s bv start end)
    (fake-shell-depth-set! s (+ (fake-shell-depth s) 1))
    (let ((r (parser-feed! (fake-shell-parser s) bv start end)))
      (fake-shell-depth-set! s (- (fake-shell-depth s) 1))
      (fake-shell-deliver! s (parser-result-event r))))

  ;; fake-shell-feed-input! : FakeShell Bytevector Nat [Nat] -> Nat
  ;; Deliver `input` in `size`-byte deliveries, each as `bytes-arrived`, while
  ;; the connection reads, letting every later turn happen in between.
  ;; Returns how many bytes were delivered: what a stopped connection never
  ;; read is not delivered.  Each delivery is a slice of `input`; given an
  ;; `offset`, it is a bytevector of its own instead, its bytes from that
  ;; index, as a shell hands over a read: a delivery's index then differs
  ;; from where the bytes sit in the connection (the padding PR).
  (define fake-shell-feed-input!
    (case-lambda
      ((s input size) (feed-input! s input size #f))
      ((s input size offset) (feed-input! s input size offset))))

  (define (feed-input! s input size offset)
    (let ((len (bytevector-length input)))
      (let loop ((from 0))
        (fake-shell-settle! s)
        (if (and (< from len) (fake-shell-reading? s))
            (let ((to (min len (+ from size))))
              (fake-shell-deliver! s (if offset
                                         (let ((read (make-bytevector (+ offset (- to from)) 0)))
                                           (bytevector-copy! input from read offset (- to from))
                                           (list 'bytes-arrived read offset (+ offset (- to from))))
                                         (list 'bytes-arrived input from to)))
              (loop to))
            from)))))
