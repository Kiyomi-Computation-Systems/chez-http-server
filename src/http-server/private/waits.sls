#!r6rs
;;; (http-server private waits) — what a handler waits with.
;;;
;;; A handler that answers `awaiting` runs on a coroutine, and code on a
;;; coroutine may wait.  A WAIT is one-shot: `(await register)` calls
;;; `register` with `resume`, then parks the coroutine until `resume` is
;;; called, and answers what `resume` was given.  Its first call wakes the
;;; coroutine, wherever the loop's thread makes it: a libuv callback of the
;;; server's own, another handler, a reader or a producer, since a wake only
;;; makes the coroutine ready, to run at the drain (R1 holds).  A resume
;;; called while `register` still runs ends the wait at once: the coroutine
;;; does not park.  Every later call is R4's recorded fault: logged as
;;; `late-resume`, it wakes nothing, not even the coroutine waiting again on a
;;; wait of its own since.  A wait begins only where a coroutine may park, and
;;; is refused before `register` runs anywhere else, as R1, R2 or R5 (the
;;; scheduler's `waiting-coroutine`): so a handler that waits without
;;; answering `awaiting` has failed.  The log line names the verb the late
;;; resume came for: `late-resume await`, `late-resume resolve`.
;;;
;;; TIMED WAITS.  `(sleep-ms n)` parks the coroutine until the loop's clock
;;; reads `n` milliseconds on.  `(with-deadline ms thunk)` bounds the waits
;;; `thunk` makes: once `ms` milliseconds have passed, the wait in progress,
;;; or else the next one, raises `&deadline-passed`, and so does every later
;;; wait inside the deadline.  Code that does not wait is never cut short.  A
;;; deadline is in force from its start until its thunk is left, by a return,
;;; a raise or a continuation, once: a `dynamic-wind` holds it, whose after
;;; thunk a park runs too, and tells from a leaving by the scheduler's
;;; `coroutine-suspending?`.  A raise that a handler outside continues leaves
;;; nothing; a continuation that enters the thunk again does not put the
;;; deadline back.  Deadlines nest, and each passes on its own time.  A wait a
;;; deadline ends has what it waited on taken back, a sleep's time, or a
;;; lookup, cancelled if it has not begun; anything that still comes for it is
;;; a late resume (R4).
;;;
;;; A CLIENT'S CLOSE: the shell makes a NOTICE for a request whose code runs
;;; on coroutines, gives it to each coroutine it runs that code on
;;; (`notice-attach!`), and closes it once the core says the client has closed
;;; or reset the connection (`notice-close!`).  ONCE: the wait the code is
;;; parked in then, or else the next wait any of those coroutines makes,
;;; raises `&client-closed`, what it waited on taken back as a deadline takes
;;; it back; after that, waits work as before.
;;;
;;; A LOOKUP: `(resolve host)` parks the coroutine until the loop's resolver
;;; answers for `host`, through `uv-getaddrinfo!` in the libuv shell: the
;;; addresses, as strings, in the resolver's order; or, for a name that does
;;; not resolve, `&resolve-error`, whose reason names why.
;;;
;;; THE LOOP'S WAITS are one a loop, kept by the loop's scheduler
;;; (`make-waits`), which a waiting verb finds through the coroutine running:
;;; the log a late resume is recorded in; and, given by the libuv shell, the
;;; loop's clock and a timer of their own (`waits-clock!`), and its resolver
;;; (`waits-resolver!`).  The waits keep each sleep's time and each deadline
;;; in a heap, (http-server heap), with the timer armed for the earliest; each
;;; time it fires, `waits-fire!` ends what is due and arms it for the earliest
;;; left, or stops it when none is, so an idle loop sleeps.  A wait on a loop
;;; that keeps no waits, or a timed one on waits with no clock, is an
;;; assertion violation, and so is a lookup on waits with no resolver.  What a
;;; coroutine's deadlines need of it, the wait it is parked on and how many of
;;; its deadlines in force have passed, it keeps (`coroutine-waits`), from its
;;; first deadline on.
;;;
;;; Nothing here catches with `guard`, which on a coroutine costs about twice
;;; what an exception handler does.
(library (http-server private waits)
  (export make-waits waits? waits-clock! waits-fire! waits-timed waits-resolver!
          make-notice notice? notice-attach! notice-close! notice-closed?
          await sleep-ms with-deadline resolve)
  (import (rnrs)
          (http-server heap)
          (only (http-server awaiting) make-deadline-passed make-client-closed make-resolve-error)
          (only (http-server private scheduler)
                waiting-coroutine coroutine-scheduler coroutine-park! coroutine-wake!
                coroutine-waits coroutine-waits-set! coroutine-suspending?
                scheduler-waits scheduler-waits-set!))

  ;; make-waits : Scheduler (Symbol (Listof Any) -> Any) -> Waits
  ;; The waits of the loop `s` schedules, kept by `s`: a late resume is
  ;; logged as `(log! 'late-resume (list verb))`, the verb the wait was
  ;; made by, such as `await`.  They keep no clock until waits-clock! gives
  ;; them one.
  ;; waits? : Any -> Boolean
  (define-record-type (waits %make-waits waits?)
    (fields log heap
            (mutable now) (mutable start) (mutable stop)   ; the loop's clock and timer, or #f
            (mutable lookup) (mutable cancel))             ; its resolver, or #f
    (sealed #t))

  (define (make-waits s log!)
    (let ((w (%make-waits log! (make-heap) #f #f #f #f #f)))
      (scheduler-waits-set! s w)
      w))

  ;; waits-clock! : Waits (-> Nat) (Nat -> Any) (-> Any) -> Void
  ;; The loop's clock, `now`, in milliseconds, brought up to date as it is
  ;; read, and a timer for the timed waits: `(start! ms)` arms it to fire
  ;; once, `ms` milliseconds on, in place of any arming before, and
  ;; `(stop!)` disarms it.  Each time it fires, its owner calls waits-fire!.
  (define (waits-clock! w now start! stop!)
    (waits-now-set! w now)
    (waits-start-set! w start!)
    (waits-stop-set! w stop!))

  ;; waits-resolver! :
  ;;   Waits (String ((U Symbol #f) (Listof String) -> Any) -> Any) (Any -> Any) -> Void
  ;; The loop's resolver: `(lookup! host answer!)` begins a lookup of
  ;; `host`, and answers what `cancel!` takes, or #f; the lookup answers once
  ;; through `(answer! reason addresses)`, reason #f and the addresses, or the
  ;; reason it failed and '(), then or later.  `(cancel! request)` cancels a
  ;; lookup that has not begun, which then answers as it is cancelled.
  (define (waits-resolver! w lookup! cancel!)
    (waits-lookup-set! w lookup!)
    (waits-cancel-set! w cancel!))

  ;; waits-timed : Waits -> Nat — how many sleeps and deadlines are armed.
  ;; At 0 the timer is stopped, or stops the next time it fires.
  (define (waits-timed w) (heap-count (waits-heap w)))

  ;; A cell is one wait: the verb that made it, the coroutine waiting, until
  ;; the wait is over, its loop's waits, how far the wait has come, the value
  ;; a resume gave while `register` ran, until the wait answers it, and what
  ;; it waits on that a deadline takes back, a sleep's entry in the heap or a
  ;; lookup's request, or #f.  Whoever registered may keep the resume, and so
  ;; the cell, after the wait: it then keeps neither the coroutine nor a
  ;; value.
  ;;   registering  `register` runs: a resume keeps its value, 'early
  ;;   parked       the coroutine has parked: a resume wakes it, 'resumed
  ;;   early, resumed  the wait is over: a resume is late (R4)
  (define-record-type cell
    (fields who (mutable coroutine) waits (mutable state) (mutable value) (mutable pending))
    (sealed #t))

  ;; A coroutine's context, from its first deadline or its notice: the wait
  ;; it is parked on, or #f, how many of its deadlines in force have passed,
  ;; and the notice of the request whose code it runs, or #f.
  (define-record-type context
    (fields (mutable cell) (mutable passed) (mutable notice))
    (sealed #t))

  ;; make-notice : -> Notice — a request's, before its client has closed.
  ;; notice? : Any -> Boolean
  ;; Its state, and the context of the coroutine given it last, or #f:
  ;;   open    the client has not closed
  ;;   closed  it has, and no wait has raised it yet
  ;;   raised  a wait has
  (define-record-type (notice make-notice notice?)
    (fields (mutable state) (mutable context))
    (protocol (lambda (new) (lambda () (new 'open #f))))
    (sealed #t))

  ;; A deadline: its coroutine's context, its time, its entry in the heap
  ;; until it passes or ends, or #f, and whether it has passed.
  (define-record-type deadline
    (fields context time (mutable entry) (mutable passed?))
    (sealed #t))

  ;; What a passed deadline resumes the wait in progress with, which no one
  ;; else can give: the wait raises as it resumes.
  (define passed-token (list 'deadline-passed))

  ;; What a client's close resumes the wait it ends with, as a deadline's.
  (define closed-token (list 'client-closed))

  ;; notice-attach! : Coroutine Notice -> Void
  ;; `c` runs the code of the request `n` is for: its waits raise the close
  ;; once, as `n` says, and a close ends the wait it is parked in.
  (define (notice-attach! c n)
    (let ((x (or (coroutine-waits c)
                 (let ((x (make-context #f 0 #f)))
                   (coroutine-waits-set! c x)
                   x))))
      (context-notice-set! x n)
      (notice-context-set! n x)))

  ;; notice-close! : Notice -> Void
  ;; The client has closed: the wait the coroutine given `n` last is parked
  ;; in ends, what it waited on taken back, raising `&client-closed` as it
  ;; resumes; with none parked, the next wait raises.  A notice closed before
  ;; is left as it is.
  (define (notice-close! n)
    (when (eq? (notice-state n) 'open)
      (notice-state-set! n 'closed)
      (let ((x (notice-context n)))
        (when x
          (let ((cell (context-cell x)))
            (when (and cell (eq? (cell-state cell) 'parked))
              (take-back! cell)
              (resume! cell closed-token)))))))

  ;; notice-closed? : Notice -> Boolean — the client has closed.
  (define (notice-closed? n) (not (eq? (notice-state n) 'open)))

  ;; owed? : Context -> Boolean — the client has closed, and no wait has
  ;; raised it.
  (define (owed? x)
    (let ((n (context-notice x)))
      (and n (eq? (notice-state n) 'closed))))

  ;; client-closed! : Context Symbol -> [raises] — the close's one raise,
  ;; from `who`.
  (define (client-closed! x who)
    (notice-state-set! (context-notice x) 'raised)
    (raise (condition (make-client-closed)
                      (make-who-condition who)
                      (make-message-condition "the client has closed"))))

  ;; deadline-passed! : Symbol -> [raises] — a deadline's raise, from `who`.
  (define (deadline-passed! who)
    (raise (condition (make-deadline-passed)
                      (make-who-condition who)
                      (make-message-condition "the deadline has passed"))))

  ;; whole-ms! : Symbol Any -> Void — refuse what is not a whole number of
  ;; milliseconds.
  (define (whole-ms! who ms)
    (unless (and (integer? ms) (exact? ms) (>= ms 0))
      (assertion-violation who "expected a whole number of milliseconds" ms)))

  ;; loop-waits : Symbol Coroutine -> Waits — the waits of the loop `c`
  ;; runs on.
  (define (loop-waits who c)
    (or (scheduler-waits (coroutine-scheduler c))
        (assertion-violation who "the loop keeps no waits" c)))

  ;; clocked-waits : Symbol Coroutine -> Waits — the loop's waits, which
  ;; keep a clock.
  (define (clocked-waits who c)
    (let ((w (loop-waits who c)))
      (unless (waits-now w) (assertion-violation who "the loop's waits keep no clock" c))
      w))

  ;; arm-at! : Waits Nat Nat Any -> HeapEntry
  ;; `key` armed at `time` in the heap, read at `now`, and the timer armed
  ;; for it if it is now the earliest.
  (define (arm-at! w now time key)
    (let* ((h (waits-heap w))
           (before (heap-earliest h))
           (e (heap-insert! h time key)))
      (when (or (not before) (< time before))
        ((waits-start w) (max 0 (- time now))))
      e))

  ;; waits-fire! : Waits -> Void
  ;; The loop's timer has fired: each sleep and deadline due by the loop's
  ;; now ends, the earliest first, then the timer is armed for the earliest
  ;; left, or stopped if none is left.  A sleep a deadline in the same
  ;; advance took back, due at the deadline's own time, wakes nothing.
  ;; Called from the timer's callback, where it only wakes coroutines (R1).
  (define (waits-fire! w)
    (let* ((h (waits-heap w))
           (now ((waits-now w))))
      (for-each (lambda (key)
                  (cond ((deadline? key) (pass! key))
                        ((cell-pending key) (cell-pending-set! key #f) (resume! key #t))))
                (heap-advance! h now))
      (let ((next (heap-earliest h)))
        (if next
            ((waits-start w) (max 0 (- next now)))
            ((waits-stop w))))))

  ;; pass! : Deadline -> Void
  ;; Its time has come: it has passed, and the wait in progress inside it,
  ;; if one is parked, is ended, what it waited on taken back, raising as it
  ;; resumes.  A deadline in force alone is in the heap.
  (define (pass! d)
    (deadline-entry-set! d #f)
    (deadline-passed?-set! d #t)
    (let ((x (deadline-context d)))
      (context-passed-set! x (+ (context-passed x) 1))
      (let ((cell (context-cell x)))
        (when (and cell (eq? (cell-state cell) 'parked))
          (take-back! cell)
          (resume! cell passed-token)))))

  ;; take-back! : Cell -> Void — what the wait waits on, taken back: a
  ;; sleep's time out of the heap, or a lookup cancelled.
  (define (take-back! cell)
    (let ((p (cell-pending cell)) (w (cell-waits cell)))
      (when p
        (cell-pending-set! cell #f)
        (if (heap-entry? p)
            (heap-remove! (waits-heap w) p)
            ((waits-cancel w) p)))))

  ;; wait! : Symbol Waits Coroutine (Cell -> Any) -> Any
  ;; One wait of `c`'s: `start!` called with its cell, then a park until it
  ;; is resumed, unless it was resumed while `start!` ran.  A deadline that
  ;; has passed, in force, makes it raise before `start!` runs, and one that
  ;; passes while it is parked, as it resumes; and so a client's close no
  ;; wait has raised yet, and one that comes while it is parked.
  (define (wait! who w c start!)
    (let ((x (coroutine-waits c)))
      (when (and x (> (context-passed x) 0)) (deadline-passed! who))
      (when (and x (owed? x)) (client-closed! x who))
      (let ((cell (make-cell who c w 'registering #f #f)))
        (start! cell)
        (if (eq? (cell-state cell) 'early)
            (let ((v (cell-value cell)))
              (cell-coroutine-set! cell #f)
              (cell-value-set! cell #f)
              v)
            (begin
              (cell-state-set! cell 'parked)
              (when x (context-cell-set! x cell))
              (let ((v (coroutine-park! who)))
                (when x (context-cell-set! x #f))
                (cond ((eq? v passed-token) (deadline-passed! who))
                      ((eq? v closed-token) (client-closed! x who))
                      (else v))))))))

  ;; await : ((Any -> Void) -> Any) -> Any
  ;; Call `register` with `resume`, a procedure of one argument, then park
  ;; until it is called: what it was called with.  Refused, before
  ;; `register` runs, where no coroutine may park.
  (define (await register)
    (let* ((c (waiting-coroutine 'await))
           (w (loop-waits 'await c)))
      (wait! 'await w c (lambda (cell) (register (lambda (v) (resume! cell v)))))))

  ;; resume! : Cell Any -> Void
  ;; The wait's first resume ends it; every later one is logged (R4).
  (define (resume! cell v)
    (case (cell-state cell)
      ((registering) (cell-value-set! cell v) (cell-state-set! cell 'early))
      ((parked)
       (let ((c (cell-coroutine cell)))
         (cell-coroutine-set! cell #f)
         (cell-state-set! cell 'resumed)
         (coroutine-wake! c v)))
      (else ((waits-log (cell-waits cell)) 'late-resume (list (cell-who cell))))))

  ;; sleep-ms : Nat -> Void
  ;; Park until the loop's clock reads `ms` milliseconds on: the first time
  ;; the loop's timer for the waits fires at or after then.
  (define (sleep-ms ms)
    (whole-ms! 'sleep-ms ms)
    (let* ((c (waiting-coroutine 'sleep-ms))
           (w (clocked-waits 'sleep-ms c)))
      (wait! 'sleep-ms w c
             (lambda (cell)
               (let ((now ((waits-now w))))
                 (cell-pending-set! cell (arm-at! w now (+ now ms) cell))))))
    (values))

  ;; resolve : String -> (Listof String)
  ;; Park until the loop's resolver answers for `host`: its addresses, as
  ;; strings, in the resolver's order.  A name that does not resolve raises
  ;; `&resolve-error`, with the reason the resolver gave and `host`.
  (define (resolve host)
    (unless (string? host) (assertion-violation 'resolve "not a string" host))
    (let* ((c (waiting-coroutine 'resolve))
           (w (loop-waits 'resolve c)))
      (unless (waits-lookup w) (assertion-violation 'resolve "the loop's waits keep no resolver" c))
      (let ((r (wait! 'resolve w c
                      (lambda (cell)
                        (cell-pending-set! cell
                          ((waits-lookup w) host
                           (lambda (reason addresses) (resume! cell (cons reason addresses)))))))))
        (if (car r)
            (raise (condition (make-resolve-error (car r))
                              (make-who-condition 'resolve)
                              (make-message-condition "the name does not resolve")
                              (make-irritants-condition (list host))))
            (cdr r)))))

  ;; with-deadline : Nat (-> (Values Any ...)) -> (Values Any ...)
  ;; Every value `thunk` returns, called on the coroutine running; once
  ;; `ms` milliseconds of the loop's clock have passed, the wait in
  ;; progress inside it, or else the next, raises `&deadline-passed`, and so
  ;; does every later one inside it.  Refused, before anything is armed,
  ;; where no coroutine may park.
  (define (with-deadline ms thunk)
    (whole-ms! 'with-deadline ms)
    (unless (procedure? thunk) (assertion-violation 'with-deadline "not a procedure" thunk))
    (let* ((c (waiting-coroutine 'with-deadline))
           (w (clocked-waits 'with-deadline c))
           (x (or (coroutine-waits c)
                  (let ((x (make-context #f 0 #f)))
                    (coroutine-waits-set! c x)
                    x)))
           (now ((waits-now w)))
           (d (make-deadline x (+ now ms) #f #f))
           (in? #t))
      (deadline-entry-set! d (arm-at! w now (deadline-time d) d))
      (enter! x d)
      (dynamic-wind
       (lambda () #f)
       thunk
       (lambda ()
         (when (and in? (not (coroutine-suspending? c)))
           (set! in? #f)
           (leave! w x d))))))

  ;; enter! : Context Deadline -> Void — `d` in force, counted if it has
  ;; passed.
  (define (enter! x d)
    (when (deadline-passed? d) (context-passed-set! x (+ (context-passed x) 1))))

  ;; leave! : Waits Context Deadline -> Void
  ;; `d` in force no more: counted no more, and out of the heap if it has
  ;; not passed.
  (define (leave! w x d)
    (when (deadline-passed? d) (context-passed-set! x (- (context-passed x) 1)))
    (let ((e (deadline-entry d)))
      (when e
        (deadline-entry-set! d #f)
        (heap-remove! (waits-heap w) e)))))
