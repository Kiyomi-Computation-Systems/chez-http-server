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
;;; the verb the late resume came for: `late-resume await`.
;;;
;;; THE LOOP'S WAITS are one a loop, kept by the loop's scheduler
;;; (`make-waits`), which a waiting verb finds through the coroutine
;;; running: the log a late resume is recorded in.  A wait on a loop that
;;; keeps none is an assertion violation.
;;;
;;; Nothing here catches with `guard`: on a coroutine, a `guard` costs the
;;; coroutine a stack of its own (M7.2's first step, design §5.2's note).
(library (http-server private waits)
  (export make-waits waits? await)
  (import (rnrs)
          (only (http-server private scheduler)
                waiting-coroutine coroutine-scheduler coroutine-park! coroutine-wake!
                scheduler-waits scheduler-waits-set!))

  ;; make-waits : Scheduler (Symbol (Listof Any) -> Any) -> Waits
  ;; The waits of the loop `s` schedules, kept by `s`: a late resume is
  ;; logged as `(log! 'late-resume (list verb))`, the verb the wait was
  ;; made by, `await`.
  ;; waits? : Any -> Boolean
  (define-record-type (waits %make-waits waits?)
    (fields log)
    (sealed #t))

  (define (make-waits s log!)
    (let ((w (%make-waits log!)))
      (scheduler-waits-set! s w)
      w))

  ;; A cell is one wait: the verb that made it, the coroutine waiting, its
  ;; loop's waits, how far the wait has come, and the value a resume gave
  ;; while `register` ran.
  ;;   registering  `register` runs: a resume keeps its value, 'early
  ;;   parked       the coroutine has parked: a resume wakes it, 'resumed
  ;;   early, resumed  the wait is over: a resume is late (R4)
  (define-record-type cell
    (fields who coroutine waits (mutable state) (mutable value))
    (sealed #t))

  ;; await : ((Any -> Void) -> Any) -> Any
  ;; Call `register` with `resume`, a procedure of one argument, then park
  ;; until it is called: what it was called with.  Refused, before
  ;; `register` runs, where no coroutine may park.
  (define (await register)
    (let* ((c (waiting-coroutine 'await))
           (w (scheduler-waits (coroutine-scheduler c))))
      (unless w (assertion-violation 'await "the loop keeps no waits" c))
      (let ((cell (make-cell 'await c w 'registering #f)))
        (register (lambda (v) (resume! cell v)))
        (if (eq? (cell-state cell) 'early)
            (cell-value cell)
            (begin
              (cell-state-set! cell 'parked)
              (coroutine-park!))))))

  ;; resume! : Cell Any -> Void
  ;; The wait's first resume ends it; every later one is logged (R4).
  (define (resume! cell v)
    (case (cell-state cell)
      ((registering) (cell-value-set! cell v) (cell-state-set! cell 'early))
      ((parked) (cell-state-set! cell 'resumed) (coroutine-wake! (cell-coroutine cell) v))
      (else ((waits-log (cell-waits cell)) 'late-resume (list (cell-who cell)))))))
