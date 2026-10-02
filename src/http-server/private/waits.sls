#!r6rs
;;; (http-server private waits) — what a handler waits with (decision 0015;
;;; design §5.3's R4; M7.2).
;;;
;;; A handler that answers `awaiting` runs on a coroutine (decision 0014),
;;; and code on a coroutine may wait.  A WAIT is one-shot: `(await register)`
;;; calls `register` with `resume`, then parks the coroutine until `resume`
;;; is called, and answers what `resume` was given.  Its first call wakes
;;; the coroutine, wherever the loop's thread makes it: a libuv callback of
;;; the server's own, another handler, a reader or a producer, since a wake
;;; only makes the coroutine ready, to run at the drain (R1 holds).  A
;;; resume called while `register` still runs ends the wait at once: the
;;; coroutine does not park.  Every later call is R4's recorded fault (design
;;; §5.3): logged as `late-resume`, it wakes nothing, not even the coroutine
;;; waiting again on a wait of its own since.  A wait begins only where a
;;; coroutine may park, and is refused before `register` runs anywhere else,
;;; as R1, R2 or R5 (the scheduler's `waiting-coroutine`): so a handler that
;;; did not answer `awaiting` has failed (0014 item 3).  The log line names
;;; the verb the late resume came for: `late-resume await`, `late-resume
;;; resolve`.
;;;
;;; TIMED WAITS (decision 0015 item 3).  `(sleep-ms n)` parks the coroutine
;;; until the loop's clock reads `n` milliseconds on.  `(with-deadline ms
;;; thunk)` bounds the waits `thunk` makes: once `ms` milliseconds have
;;; passed, the wait in progress, or else the next one, raises
;;; `&deadline-passed`, and so does every later wait inside the deadline.
;;; Code that does not wait is never cut short.  A deadline is in force from
;;; its start until its thunk is left, by a return, a raise or a
;;; continuation, once: a `dynamic-wind` holds it, whose after thunk a park
;;; runs too, and tells from a leaving by the scheduler's
;;; `coroutine-suspending?`.  A raise that a handler outside continues
;;; leaves nothing; a continuation that enters the thunk again does not put
;;; the deadline back.  Deadlines nest, and each passes on its own time.  A
;;; wait a deadline ends has what it waited on taken back, a sleep's time;
;;; anything that still comes for it is a late resume (R4).
;;;
;;; THE LOOP'S WAITS are one a loop, kept by the loop's scheduler
;;; (`make-waits`), which a waiting verb finds through the coroutine
;;; running: the log a late resume is recorded in; and, given by the libuv
;;; shell (`waits-clock!`), the loop's clock and a timer of their own.  The
;;; waits keep each sleep's time and each deadline in a heap, (http-server
;;; heap), with the timer armed for the earliest; each time it fires,
;;; `waits-fire!` ends what is due and arms it for the earliest left, or
;;; stops it when none is, so an idle loop sleeps (decision 0005).  A wait
;;; on a loop that keeps no waits, or a timed one on waits with no clock, is
;;; an assertion violation.  What a coroutine's deadlines need of it, the
;;; wait it is parked on and how many of its deadlines in force have passed,
;;; it keeps (`coroutine-waits`), from its first deadline on.
;;;
;;; Nothing here catches with `guard`: on a coroutine, a `guard` costs the
;;; coroutine a stack of its own (M7.2's first step, design §5.2's note).
(library (http-server private waits)
  (export make-waits waits? waits-clock! waits-fire! waits-timed
          await sleep-ms with-deadline)
  (import (rnrs)
          (http-server heap)
          (only (http-server awaiting) make-deadline-passed)
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
            (mutable now) (mutable start) (mutable stop))   ; the loop's clock and timer, or #f
    (sealed #t))

  (define (make-waits s log!)
    (let ((w (%make-waits log! (make-heap) #f #f #f)))
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

  ;; waits-timed : Waits -> Nat — how many sleeps and deadlines are armed.
  ;; At 0 the timer is stopped, or stops the next time it fires.
  (define (waits-timed w) (heap-count (waits-heap w)))

  ;; A cell is one wait: the verb that made it, the coroutine waiting, its
  ;; loop's waits, how far the wait has come, the value a resume gave while
  ;; `register` ran, and what it waits on that a deadline takes back, a
  ;; sleep's entry in the heap, or #f.
  ;;   registering  `register` runs: a resume keeps its value, 'early
  ;;   parked       the coroutine has parked: a resume wakes it, 'resumed
  ;;   early, resumed  the wait is over: a resume is late (R4)
  (define-record-type cell
    (fields who coroutine waits (mutable state) (mutable value) (mutable pending))
    (sealed #t))

  ;; A coroutine's context, from its first deadline: the wait it is parked
  ;; on, or #f, and how many of its deadlines in force have passed.
  (define-record-type context
    (fields (mutable cell) (mutable passed))
    (sealed #t))

  ;; A deadline: its coroutine's context, its time, its entry in the heap
  ;; until it passes or ends, or #f, and whether it has passed.
  (define-record-type deadline
    (fields context time (mutable entry) (mutable passed?))
    (sealed #t))

  ;; What a passed deadline resumes the wait in progress with, which no one
  ;; else can give: the wait raises as it resumes.
  (define passed-token (list 'deadline-passed))

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
  ;; sleep's time out of the heap.
  (define (take-back! cell)
    (let ((p (cell-pending cell)))
      (when p
        (cell-pending-set! cell #f)
        (heap-remove! (waits-heap (cell-waits cell)) p))))

  ;; wait! : Symbol Waits Coroutine (Cell -> Any) -> Any
  ;; One wait of `c`'s: `start!` called with its cell, then a park until it
  ;; is resumed, unless it was resumed while `start!` ran.  A deadline that
  ;; has passed, in force, makes it raise before `start!` runs, and one that
  ;; passes while it is parked, as it resumes.
  (define (wait! who w c start!)
    (let ((x (coroutine-waits c)))
      (when (and x (> (context-passed x) 0)) (deadline-passed! who))
      (let ((cell (make-cell who c w 'registering #f #f)))
        (start! cell)
        (if (eq? (cell-state cell) 'early)
            (cell-value cell)
            (begin
              (cell-state-set! cell 'parked)
              (when x (context-cell-set! x cell))
              (let ((v (coroutine-park!)))
                (when x (context-cell-set! x #f))
                (if (eq? v passed-token) (deadline-passed! who) v)))))))

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
      ((parked) (cell-state-set! cell 'resumed) (coroutine-wake! (cell-coroutine cell) v))
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
                  (let ((x (make-context #f 0)))
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
