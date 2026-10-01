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
;;; runs, before it is performed.  And the events a later turn brings are
;;; delivered one at a time on request, so that test can deliver them where
;;; the libuv shell delivered its own.
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
;;;   call-handler    the handler's answer, a response or a reader, as
;;;                   `handler-responded`, or `handler-failed` if it raises
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
;;; and records the rest (logs, a hand-off) without acting on them: the
;;; hand-off is M8's.  A fake connection made on credit (M6.2) answers with
;;; each handler's answer and `credit`, `(handler-responded answer credit)`,
;;; as M7's coroutine shell will, which hands a reader its pieces on
;;; credit: the test then gives the reader's credit, `(body-credit n)`.  (Since M2.5 the core serves an upgrade and closes after
;;; it, so its own loop never hands off.)
;;; Input is delivered only while the connection reads, as libuv delivers
;;; it.  An event the core cannot finish within `dispatch-cap` dispatches is
;;; a harness error, never a hang (global-constraints: cap by iteration
;;; count, never wall-clock).
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events fake-shell-violations
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-fire! fake-shell-run!
          make-fake-connection fake-shell-conn-state fake-shell-reading? drops-body
          fake-shell-deliver-later! fake-shell-settle! fake-shell-feed-input!
          fake-shell-writes fake-shell-date-writes! written-status write-wire)
  (import (rnrs)
          (byte-machine runtime)
          (only (http-server connection) make-conn-state conn-body-reader conn-producer producer-event)
          (only (http-server body) body-reader-on-piece body-reader-on-end read-body)
          (only (http-server limits) limits-tick-ms limits-deadline-ms)
          (http-server wheel)
          (only (http-server serializer) date-line)
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
            (mutable credit?))                ; whether it answers on credit (M6.2)
    (protocol (lambda (new)
                (case-lambda
                  ((step state0 now0)
                   (new step state0 now0 '() '() #f '() '() 0 '() '() #f #t 0 '() #f #f #f #f '() #f))
                  ((step state0 now0 perform)
                   (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0 '() #f #f #f #f '() #f))
                  ((step state0 now0 perform trace)
                   (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0 '() #f trace #f #f '()
                        #f))))))

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
  ;; under way.  Returns this event's actions.
  (define (fake-shell-deliver! s event)
    (fake-shell-dispatches-set! s (+ (fake-shell-dispatches s) 1))
    (when (> (fake-shell-dispatches s) dispatch-cap)
      (assertion-violation 'fake-shell-deliver! "no progress: the dispatch cap was reached"
                           dispatch-cap event))
    (trace! s 'event event)
    (call-with-values
     (lambda () ((fake-shell-step s) (fake-shell-state s) event))
     (lambda (state* actions)
       (fake-shell-state-set! s state*)
       (fake-shell-events-rev-set! s (cons event (fake-shell-events-rev s)))
       (enqueue! s actions)
       (when (= (fake-shell-depth s) 0) (drain! s))
       actions)))

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
  ;; was ticked.  A stub step's shell keeps no wheel, and firing it is an
  ;; assertion violation.
  (define (fake-shell-fire! s)
    (let ((wheel (fake-shell-wheel s)) (now (fake-shell-now s)))
      (unless wheel
        (assertion-violation 'fake-shell-fire! "a stub step's shell keeps no timer" s))
      (if (pair? (wheel-advance! wheel now))
          (fake-shell-deliver! s (list 'tick now))
          '())))

  ;; fake-shell-run! : FakeShell (Listof Event) -> Void — deliver them in order.
  (define (fake-shell-run! s events)
    (for-each (lambda (e) (fake-shell-deliver! s e)) events))

  ;; later! : FakeShell Event -> Void — deliver `event` on a later turn.
  (define (later! s event)
    (fake-shell-later-set! s (append (fake-shell-later s) (list event))))

  ;; fake-shell-deliver-later! : FakeShell -> (U Event #f)
  ;; Deliver the oldest event waiting for a later turn, a write's completion,
  ;; a half-close's or a close's, and return it; #f if none waits.
  (define (fake-shell-deliver-later! s)
    (let ((later (fake-shell-later s)))
      (and (pair? later)
           (begin (fake-shell-later-set! s (cdr later))
                  (fake-shell-deliver! s (car later))
                  (car later)))))

  ;; fake-shell-settle! : FakeShell -> Void
  ;; Deliver the events waiting for a later turn, oldest first, until none
  ;; wait: a write's completion, a close's `closed`.
  (define (fake-shell-settle! s)
    (when (fake-shell-deliver-later! s)
      (fake-shell-settle! s)))

  ;; --- the connection ---------------------------------------------------------

  ;; make-fake-connection : Limits (Request -> Response) [Trace [Nat [Boolean]]] -> FakeShell
  ;; A connection in idle, reading, the clock at `now` (0 unless given), and
  ;; its idle deadline armed there: (http-server connection)'s core through
  ;; the adapter, with a parser of its own and `handler` answering every
  ;; request at once, traced as make-fake-shell traces.  Made `on-credit?`,
  ;; it answers with each answer and `credit` (M6.2).  Its state is the
  ;; adapter's context; fake-shell-conn-state reads the core's state from it.
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

  ;; perform-connection! : FakeShell Action (Request -> Response) Limits -> Void
  (define (perform-connection! s a handler limits)
    (case (car a)
      ((feed-parser) (feed! s (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (parser-resume! (fake-shell-parser s)))
      ((call-handler)
       (let ((answer (guard (e (#t (list 'handler-failed e)))
                       (list 'handler-responded (handler (cadr a))))))
         (fake-shell-deliver! s (if (and (fake-shell-credit? s) (eq? (car answer) 'handler-responded))
                                    (append answer '(credit))
                                    answer))))
      ((deliver-body)
       (let ((r (conn-body-reader (fake-shell-conn-state s))))
         (when r
           (guard (e (#t (fake-shell-deliver! s (list 'handler-failed e))))
             ((body-reader-on-piece r) (cadr a) (caddr a) (cadddr a))))))
      ((deliver-body-end)
       (let ((r (conn-body-reader (fake-shell-conn-state s))))
         (when r
           (fake-shell-deliver! s (guard (e (#t (list 'handler-failed e)))
                                    (list 'handler-responded ((body-reader-on-end r))))))))
      ((notify-producer)
       (let ((p (conn-producer (fake-shell-conn-state s))))
         (when p
           (fake-shell-deliver! s (guard (e (#t (list 'handler-failed e)))
                                    (producer-event (p)))))))
      ((write) (write! s (cadr a) (caddr a)))
      ((read-stop) (fake-shell-reading?-set! s #f))
      ((read-start) (fake-shell-reading?-set! s #t))
      ((shutdown) (later! s '(shutdown-completed)))
      ((close) (fake-shell-reading?-set! s #f) (later! s '(closed)))
      ((arm-deadline) (arm! s limits (cadr a)))
      ((disarm-deadline) (wheel-disarm! (fake-shell-wheel s) (fake-shell-entry s)))
      (else (values))))

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
  ;; span it has open.
  (define (feed! s bv start end)
    (fake-shell-depth-set! s (+ (fake-shell-depth s) 1))
    (let ((r (parser-feed! (fake-shell-parser s) bv start end)))
      (fake-shell-depth-set! s (- (fake-shell-depth s) 1))
      (fake-shell-deliver! s (parser-result-event r (fake-shell-parser s)))))

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
