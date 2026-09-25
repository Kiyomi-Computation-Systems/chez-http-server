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
;;; `make-fake-connection` is the shell M2.4 drives the core with: the core
;;; through the adapter's bindings, one real parser, and a handler that answers
;;; at once.  It performs what a v1 shell performs:
;;;
;;;   feed-parser     parser-feed!, then the result as `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler's response as `handler-responded`, or
;;;                   `handler-failed` if it raises
;;;   write           completes on a later turn, as `write-completed`
;;;   read-stop/-start  whether the next delivery is read
;;;   close           stops reading; `closed` arrives on a later turn
;;;
;;; and records the rest (deadlines, logs, body deliveries, a hand-off)
;;; without acting on them: the wheel is M5's, bodies M6's, the hand-off
;;; M2.5's.  Input is delivered only while the connection reads, as libuv
;;; delivers it.  An event the core cannot finish within `dispatch-cap`
;;; dispatches is a harness error, never a hang (global-constraints: cap by
;;; iteration count, never wall-clock).
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events fake-shell-violations
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-run!
          make-fake-connection fake-shell-conn-state fake-shell-reading?
          fake-shell-settle! fake-shell-feed-input!)
  (import (rnrs)
          (byte-machine runtime)
          (only (http-server connection) make-conn-state)
          (http-server private adapter))

  ;; make-fake-shell : Step State Nat [Perform] -> FakeShell
  ;;   Perform = FakeShell Action -> Any, run for each action as it is taken
  ;;   from the queue; without one the shell only records.
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
            (mutable dispatches))
    (protocol (lambda (new)
                (case-lambda
                  ((step state0 now0) (new step state0 now0 '() '() #f '() '() 0 '() '() #f #t 0))
                  ((step state0 now0 perform)
                   (new step state0 now0 '() '() perform '() '() 0 '() '() #f #t 0))))))

  ;; fake-shell-actions / -violations : FakeShell -> (Listof Action)
  ;; fake-shell-events : FakeShell -> (Listof Event)
  ;; The actions run, the actions run anywhere but the outermost drain, and
  ;; the events dispatched, each in arrival order (the fields hold them
  ;; reversed, appended to as they arrive).
  (define (fake-shell-actions s) (reverse (fake-shell-actions-rev s)))
  (define (fake-shell-events s) (reverse (fake-shell-events-rev s)))
  (define (fake-shell-violations s) (reverse (fake-shell-violations-rev s)))

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
  ;; Dispatch one event: step it, thread the state, record the event, queue
  ;; the actions, and drain the queue unless a drain or a feed is under way.
  ;; Returns this event's actions.
  (define (fake-shell-deliver! s event)
    (fake-shell-dispatches-set! s (+ (fake-shell-dispatches s) 1))
    (when (> (fake-shell-dispatches s) dispatch-cap)
      (assertion-violation 'fake-shell-deliver! "no progress: the dispatch cap was reached"
                           dispatch-cap event))
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
  (define (drain! s)
    (fake-shell-depth-set! s (+ (fake-shell-depth s) 1))
    (let loop ()
      (let ((a (dequeue! s)))
        (when a (run! s a) (loop))))
    (fake-shell-depth-set! s (- (fake-shell-depth s) 1)))

  ;; run! : FakeShell Action -> Void
  ;; Record the action, and a violation if it runs anywhere but the outermost
  ;; drain; then perform it.
  (define (run! s a)
    (unless (= (fake-shell-depth s) 1)
      (fake-shell-violations-rev-set! s (cons a (fake-shell-violations-rev s))))
    (fake-shell-actions-rev-set! s (cons a (fake-shell-actions-rev s)))
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

  ;; fake-shell-settle! : FakeShell -> Void
  ;; Deliver the events waiting for a later turn, oldest first, until none
  ;; wait: a write's completion, a close's `closed`.
  (define (fake-shell-settle! s)
    (let loop ()
      (let ((later (fake-shell-later s)))
        (when (pair? later)
          (fake-shell-later-set! s (cdr later))
          (fake-shell-deliver! s (car later))
          (loop)))))

  ;; --- the connection ---------------------------------------------------------

  ;; make-fake-connection : Limits (Request -> Response) -> FakeShell
  ;; A connection in idle, reading, its idle deadline armed, the clock at 0:
  ;; (http-server connection)'s core through the adapter, with a parser of its
  ;; own and `handler` answering every request at once.  Its state is the
  ;; adapter's context; fake-shell-conn-state reads the core's state from it.
  (define (make-fake-connection limits handler)
    (let* ((cell #f)
           (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 #f #f limits)
                                   (lambda (actions) (enqueue! cell actions))))
           (s (make-fake-shell (lambda (ctx event) (values ctx (conn-context-step! ctx event)))
                               ctx 0
                               (lambda (s a) (perform-connection! s a handler)))))
      (set! cell s)
      (fake-shell-parser-set! s (make-conn-parser ctx))
      s))

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
      ;; The count is the bytes written; M3's serializer gives a response bytes.
      ((write) (later! s '(write-completed 0)))
      ((read-stop) (fake-shell-reading?-set! s #f))
      ((read-start) (fake-shell-reading?-set! s #t))
      ((close) (fake-shell-reading?-set! s #f) (later! s '(closed)))
      (else (values))))

  ;; feed! : FakeShell Bytevector Nat Nat -> Void
  ;; Feed the parser bv[start, end), counting the feed in the depth, then
  ;; dispatch its result: the status, the bytes consumed, where to resume,
  ;; and the error's or the pause's code.
  (define (feed! s bv start end)
    (fake-shell-depth-set! s (+ (fake-shell-depth s) 1))
    (let ((r (parser-feed! (fake-shell-parser s) bv start end)))
      (fake-shell-depth-set! s (- (fake-shell-depth s) 1))
      (fake-shell-deliver! s (list 'parser-result (parser-result-status r)
                                   (parser-result-consumed r) (parser-result-next r)
                                   (code (parser-result-error r)) (code (parser-result-pause r))))))

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
