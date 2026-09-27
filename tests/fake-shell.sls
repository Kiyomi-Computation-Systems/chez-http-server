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
;;; `make-fake-connection` is the shell M2.4 drives the core with: the core
;;; through the adapter's bindings, one real parser, and a handler that answers
;;; at once.  It performs what a v1 shell performs:
;;;
;;;   feed-parser     parser-feed!, then the result as `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler's response as `handler-responded`, or
;;;                   `handler-failed` if it raises
;;;   write           fills the Date slot from the fake clock, keeps the bytes
;;;                   as the client would read them, and completes on a later
;;;                   turn, as `write-completed` with the write's byte count
;;;   read-stop/-start  whether the next delivery is read
;;;   shutdown        shuts the write side; `shutdown-completed` arrives on a
;;;                   later turn, as uv_shutdown's callback does
;;;   close           stops reading; `closed` arrives on a later turn
;;;
;;; and records the rest (deadlines, logs, body deliveries, a hand-off)
;;; without acting on them: the wheel is M5's, bodies M6's, the hand-off
;;; M8's.  (Since M2.5 the core serves an upgrade and closes after it, so its
;;; own loop never hands off.)  Input is delivered only while the connection
;;; reads, as libuv delivers it.  An event the core cannot finish within
;;; `dispatch-cap` dispatches is a harness error, never a hang
;;; (global-constraints: cap by iteration count, never wall-clock).
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events fake-shell-violations
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-run!
          make-fake-connection fake-shell-conn-state fake-shell-reading?
          fake-shell-deliver-later! fake-shell-settle! fake-shell-feed-input!
          fake-shell-writes written-status write-wire)
  (import (rnrs)
          (byte-machine runtime)
          (only (http-server connection) make-conn-state)
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
            trace)
    (protocol (lambda (new)
                (case-lambda
                  ((step state0 now0) (new step state0 now0 '() '() #f '() '() 0 '() '() #f #t 0 '() #f #f))
                  ((step state0 now0 perform)
                   (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0 '() #f #f))
                  ((step state0 now0 perform trace)
                   (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0 '() #f trace))))))

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
  ;; shape of (http-server connection)'s event vocabulary.
  (define (fake-shell-tick! s) (fake-shell-deliver! s (list 'tick (fake-shell-now s))))

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

  ;; make-fake-connection : Limits (Request -> Response) [Trace] -> FakeShell
  ;; A connection in idle, reading, its idle deadline armed, the clock at 0:
  ;; (http-server connection)'s core through the adapter, with a parser of its
  ;; own and `handler` answering every request at once, traced as
  ;; make-fake-shell traces.  Its state is the adapter's context;
  ;; fake-shell-conn-state reads the core's state from it.
  (define make-fake-connection
    (case-lambda
      ((limits handler) (make-fake-connection limits handler #f))
      ((limits handler trace)
       (let* ((cell #f)
              (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f limits)
                                      (lambda (actions) (enqueue! cell actions))))
              (s (make-fake-shell (lambda (ctx event) (values ctx (conn-context-step! ctx event)))
                                  ctx 0
                                  (lambda (s a) (perform-connection! s a handler))
                                  trace)))
         (set! cell s)
         (fake-shell-parser-set! s (make-conn-parser ctx))
         s))))

  ;; fake-shell-conn-state : FakeShell -> ConnState
  (define (fake-shell-conn-state s) (conn-context-state (fake-shell-state s)))

  ;; perform-connection! : FakeShell Action (Request -> Response) -> Void
  (define (perform-connection! s a handler)
    (case (car a)
      ((feed-parser) (feed! s (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (parser-resume! (fake-shell-parser s)))
      ((call-handler)
       (let ((answer (guard (e (#t (list 'handler-failed e)))
                       (list 'handler-responded (handler (cadr a))))))
         (fake-shell-deliver! s answer)))
      ((write) (write! s (cadr a) (caddr a)))
      ((read-stop) (fake-shell-reading?-set! s #f))
      ((read-start) (fake-shell-reading?-set! s #t))
      ((shutdown) (later! s '(shutdown-completed)))
      ((close) (fake-shell-reading?-set! s #f) (later! s '(closed)))
      (else (values))))

  ;; write! : FakeShell (Listof Segment) Nat -> Void
  ;; Perform `(write segments nbytes)` as a shell does: the bytes are kept as
  ;; write-wire makes them, for the fake clock's second (the clock counts
  ;; milliseconds, decision 0005's unit), and the write completes on a later
  ;; turn with its byte count.
  (define (write! s segments nbytes)
    (let ((wire (write-wire segments nbytes (div (fake-shell-now s) 1000))))
      (fake-shell-writes-rev-set! s (cons wire (fake-shell-writes-rev s)))
      (later! s (list 'write-completed nbytes))))

  ;; write-wire : (Listof Segment) Nat Nat -> Bytevector
  ;; The bytes `(write segments nbytes)` puts on the wire, copied out of the
  ;; segments as uv-write*! copies them, with the Date slot filled with the
  ;; line for `second` (decision 0010 item 4).  The count must be the bytes'
  ;; own, which the serializer promises: one that is not is an assertion
  ;; violation, never a quiet pass.
  (define (write-wire segments nbytes second)
    (let* ((line (date-line second))
           (parts (map (lambda (seg) (if (eq? seg 'date) line seg)) segments))
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
  ;; dispatch its result: the status, the bytes consumed, where to resume,
  ;; and the codes of its error and its pause.
  (define (feed! s bv start end)
    (fake-shell-depth-set! s (+ (fake-shell-depth s) 1))
    (let ((r (parser-feed! (fake-shell-parser s) bv start end)))
      (fake-shell-depth-set! s (- (fake-shell-depth s) 1))
      (fake-shell-deliver! s (list 'parser-result (parser-result-status r)
                                   (parser-result-consumed r) (parser-result-next r)
                                   (code (parser-result-error r))
                                   (code (parser-result-pause r))))))

  ;; code : (U #f ParserError) -> (U #f Symbol)
  (define (code e) (and e (parser-error-code e)))

  ;; fake-shell-feed-input! : FakeShell Bytevector Nat -> Nat
  ;; Deliver `input` in `size`-byte deliveries, each as `bytes-arrived`, while
  ;; the connection reads, letting every later turn happen in between.
  ;; Returns how many bytes were delivered: what a stopped connection never
  ;; read is not delivered.
  (define (fake-shell-feed-input! s input size)
    (let ((len (bytevector-length input)))
      (let loop ((from 0))
        (fake-shell-settle! s)
        (if (and (< from len) (fake-shell-reading? s))
            (let ((to (min len (+ from size))))
              (fake-shell-deliver! s (list 'bytes-arrived input from to))
              (loop to))
            from)))))
