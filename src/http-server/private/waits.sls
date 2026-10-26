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
;;; THE BODY, PULLED.  `(next-body-piece)` answers the next piece of the
;;; request's body, a bytevector of a byte or more the caller owns, or the eof
;;; object at its end, for the code of a handler that waits: on the coroutine
;;; of its `awaiting` thunk, or of a thunk it answers `awaiting` with in turn,
;;; before its answer (the request's notice names that coroutine, its PULLER:
;;; `notice-puller!`).  Off a coroutine it is refused as every wait is, and on
;;; another, an assertion violation.  The first call pulls the body: the loop's
;;; PULLER, given by the shell (`waits-puller!`), tells the request's core,
;;; with the cap the call gives or #f; a later call that names another cap is
;;; an assertion violation.  The shell then hands the pull what the core asks
;;; for it, `pull-piece!`, `pull-end!` and `pull-fail!`, and once the pull has
;;; taken every piece it was handed, the puller credits the core with their
;;; bytes, so reading waits for it.  A piece that is all of its bytevector is
;;; handed as it is, and any other copied.  A call with a piece or the end to
;;; answer answers it at once; one that must wait for more is a wait, as any
;;; is.  The ends stick: once it has answered the eof object, every call
;;; answers it again; once the body has failed, every call raises
;;; `&body-failed`, after the pieces handed before it; and once the
;;; connection closes before the body's end (`notice-closing!`), every call
;;; raises `&client-closed`, the notice's one raise among them if it is owed.
;;; `(body-input-port)` is a binary input port whose reads pull.
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
          notice-puller! notice-closing! notice-body-failure
          waits-puller! pull-piece! pull-end! pull-fail!
          await sleep-ms with-deadline resolve next-body-piece body-input-port)
  (import (rnrs)
          (http-server heap)
          (only (http-server awaiting) make-deadline-passed make-client-closed make-resolve-error
                make-body-failed)
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
            (mutable lookup) (mutable cancel)              ; its resolver, or #f
            (mutable pull) (mutable credit))               ; its puller, or #f
    (sealed #t))

  (define (make-waits s log!)
    (let ((w (%make-waits log! (make-heap) #f #f #f #f #f #f #f)))
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

  ;; waits-puller! : Waits (Any (U Nat #f) -> Boolean) (Any Nat -> Any) -> Void
  ;; The loop's puller: `(pull! owner cap)` tells the core of the request
  ;; whose notice `owner` was made for that its body is pulled, with `cap`,
  ;; and answers #f, telling it nothing, once that connection is closing;
  ;; `(credit! owner n)` tells it the pull has taken `n` more bytes of what
  ;; it was handed.  Either may hand the pull what the core asks for, in
  ;; place.
  (define (waits-puller! w pull! credit!)
    (waits-pull-set! w pull!)
    (waits-credit-set! w credit!))

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

  ;; make-notice : [Any] -> Notice — a request's, before its client has
  ;; closed: made for `owner`, the request's connection the loop's puller
  ;; knows, or #f for none.
  ;; notice? : Any -> Boolean
  ;; Its state, the context of the coroutine given it last, or #f, its owner,
  ;; the coroutine that may pull the body, or #f, and the pull, once it has
  ;; begun, or #f:
  ;;   open    the client has not closed
  ;;   closed  it has, and no wait has raised it yet
  ;;   raised  a wait has
  (define-record-type (notice %make-notice notice?)
    (fields (mutable state) (mutable context) owner (mutable puller) (mutable pull))
    (sealed #t))

  (define make-notice
    (case-lambda
      (() (%make-notice 'open #f #f #f #f))
      ((owner) (%make-notice 'open #f owner #f #f))))

  ;; A pulled body: the notice it is the request's, its cap, the pieces
  ;; handed and not yet taken, each `(bv start end)`, front in order and
  ;; back reversed, and their bytes; how it has ended, #f while it reads, eof,
  ;; closed or the `&body-failed` it raises; and the wait parked for it, or
  ;; #f.
  (define-record-type pull
    (fields notice cap (mutable front) (mutable back) (mutable owed) (mutable end) (mutable cell))
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
      (let ((p (notice-pull n)))
        (when (and p (not (pull-end p))) (pull-end-set! p 'closed)))
      (let ((x (notice-context n)))
        (when x
          (let ((cell (context-cell x)))
            (when (and cell (eq? (cell-state cell) 'parked))
              (take-back! cell)
              (resume! cell closed-token)))))))

  ;; notice-closing! : Notice -> Void
  ;; The request's connection is closing: a pull that has not ended, its body
  ;; never to come, closes the notice (notice-close!), so the wait parked for
  ;; it raises `&client-closed`, and every call after it.  With no pull, or
  ;; one ended, nothing.
  (define (notice-closing! n)
    (let ((p (notice-pull n)))
      (when (and p (not (pull-end p))) (notice-close! n))))

  ;; notice-puller! : Notice Coroutine -> Void
  ;; `c` runs the request's handler code, its `awaiting` thunk: it may pull
  ;; the body until it ends.
  (define (notice-puller! n c) (notice-puller-set! n c))

  ;; notice-body-failure : Notice -> (U #f Condition)
  ;; The `&body-failed` the request's pull raises once its body has failed,
  ;; or #f.
  (define (notice-body-failure n)
    (let ((p (notice-pull n)))
      (and p (condition? (pull-end p)) (pull-end p))))

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

  ;; pull-piece! : Notice (List Bytevector Nat Nat) -> Void
  ;; The core hands the pull `span`, `(bv start end)`, as it asked
  ;; (`deliver-body`): behind those it has not taken, owed its bytes' credit,
  ;; and the wait parked for it ended.
  (define (pull-piece! n span)
    (let ((p (notice-pull n)))
      (when p
        (pull-back-set! p (cons span (pull-back p)))
        (pull-owed-set! p (fx+ (pull-owed p) (fx- (caddr span) (cadr span))))
        (pull-wake! p))))

  ;; pull-end! : Notice -> Void — the body has ended (`deliver-body-end`).
  (define (pull-end! n)
    (let ((p (notice-pull n)))
      (when (and p (not (pull-end p)))
        (pull-end-set! p 'eof)
        (pull-wake! p))))

  ;; pull-fail! : Notice Symbol Nat -> Void
  ;; The body has failed, for `reason`, answered `status` if the raise is let
  ;; out (`deliver-body-failed`): every call raises `&body-failed` once the
  ;; pieces handed before it are taken.
  (define (pull-fail! n reason status)
    (let ((p (notice-pull n)))
      (when (and p (not (pull-end p)))
        (pull-end-set! p (condition (make-body-failed reason status)
                                    (make-who-condition 'next-body-piece)
                                    (make-message-condition "the body has failed")
                                    (make-irritants-condition (list reason status))))
        (pull-wake! p))))

  ;; pull-wake! : Pull -> Void — the wait parked for the pull, if one is,
  ;; ended: its call looks again.  One a deadline or a close ended first is
  ;; let go.
  (define (pull-wake! p)
    (let ((cell (pull-cell p)))
      (when cell
        (pull-cell-set! p #f)
        (when (eq? (cell-state cell) 'parked) (resume! cell #t)))))

  ;; next-body-piece : [(U Nat #f)] -> (U Bytevector Eof)
  ;; The next piece of the request's body, or the eof object at its end
  ;; (THE BODY, PULLED, the header).  The first call pulls the body, capped
  ;; at `max-bytes` if given; a cap that is neither #f nor a count, or a later
  ;; call's other than the first's, is an assertion violation.  Refused where
  ;; no coroutine may park, as a wait is, and on a coroutine that is not the
  ;; request's puller.
  (define next-body-piece
    (case-lambda
      (() (pull-next 'unnamed))
      ((max-bytes)
       (unless (or (not max-bytes) (and (integer? max-bytes) (exact? max-bytes) (>= max-bytes 0)))
         (assertion-violation 'next-body-piece "a cap is #f or a count of bytes" max-bytes))
       (pull-next max-bytes))))

  ;; pull-next : (U Nat #f 'unnamed) -> (U Bytevector Eof)
  (define (pull-next cap)
    (let* ((c (waiting-coroutine 'next-body-piece))
           (w (loop-waits 'next-body-piece c))
           (x (coroutine-waits c))
           (n (and x (context-notice x))))
      (unless (and n (eq? (notice-puller n) c))
        (assertion-violation 'next-body-piece
                             "only a handler's awaiting thunk may pull its body, before it answers" c))
      (let ((p (or (notice-pull n) (pull-begin! w n (if (eq? cap 'unnamed) #f cap)))))
        (unless (or (eq? cap 'unnamed) (eqv? cap (pull-cap p)))
          (assertion-violation 'next-body-piece "a cap other than the first call's" cap (pull-cap p)))
        (pull-take! w c x p))))

  ;; pull-begin! : Waits Notice (U Nat #f) -> Pull
  ;; The pull, begun: kept by the notice, then told to the core through the
  ;; loop's puller, whose pieces it may hand over at once.  A connection
  ;; closing already leaves it closed.
  (define (pull-begin! w n cap)
    (unless (waits-pull w) (assertion-violation 'next-body-piece "the loop's waits keep no puller" w))
    (let ((p (make-pull n cap '() '() 0 #f #f)))
      (notice-pull-set! n p)
      (unless ((waits-pull w) (notice-owner n) cap)
        (pull-end-set! p 'closed))
      p))

  ;; pull-take! : Waits Coroutine Context Pull -> (U Bytevector Eof)
  ;; The oldest piece handed, the core credited once none is left; or
  ;; the end, as it stuck; or else, a wait for more, then again.
  (define (pull-take! w c x p)
    (let loop ()
      (when (and (null? (pull-front p)) (pair? (pull-back p)))
        (pull-front-set! p (reverse (pull-back p)))
        (pull-back-set! p '()))
      (let ((front (pull-front p)) (end (pull-end p)))
        (cond
         ((pair? front)
          (let* ((span (car front)) (bv (car span)) (start (cadr span)) (stop (caddr span))
                 (piece (if (and (fx=? start 0) (fx=? stop (bytevector-length bv)))
                            bv
                            (let ((copy (make-bytevector (fx- stop start))))
                              (bytevector-copy! bv start copy 0 (fx- stop start))
                              copy))))
            (pull-front-set! p (cdr front))
            (when (and (null? (cdr front)) (null? (pull-back p)))
              (let ((owed (pull-owed p)))
                (pull-owed-set! p 0)
                ((waits-credit w) (notice-owner (pull-notice p)) owed)))
            piece))
         ((eq? end 'eof) (eof-object))
         ((eq? end 'closed)
          (if (owed? x)
              (client-closed! x 'next-body-piece)
              (raise (condition (make-client-closed)
                                (make-who-condition 'next-body-piece)
                                (make-message-condition "the client has closed")))))
         (end (raise end))
         (else
          (wait! 'next-body-piece w c (lambda (cell) (pull-cell-set! p cell)))
          (loop))))))

  ;; body-input-port : [(U Nat #f)] -> BinaryInputPort
  ;; A binary input port over the request's body: each read takes what is
  ;; left of the piece it holds, and pulls the next when none is left, with
  ;; `max-bytes`, if given, for its cap.  Made anywhere, it pulls nothing
  ;; until read, and is read where `next-body-piece` may be called; what a
  ;; pull raises, a read raises, and the port keeps what it held.  Its close
  ;; closes nothing.
  (define body-input-port
    (case-lambda
      (() (body-port next-body-piece))
      ((max-bytes)
       (unless (or (not max-bytes) (and (integer? max-bytes) (exact? max-bytes) (>= max-bytes 0)))
         (assertion-violation 'body-input-port "a cap is #f or a count of bytes" max-bytes))
       (body-port (lambda () (next-body-piece max-bytes))))))

  ;; body-port : (-> (U Bytevector Eof)) -> BinaryInputPort
  ;; The port over `pull`: the piece it holds, let go once read, and where
  ;; its next byte is.
  (define (body-port pull)
    (let ((piece #f) (at 0))
      (make-custom-binary-input-port
       "request body"
       (lambda (bv start count)
         (let fill ()
           (if piece
               (let ((n (fxmin count (fx- (bytevector-length piece) at))))
                 (bytevector-copy! piece at bv start n)
                 (set! at (fx+ at n))
                 (when (fx=? at (bytevector-length piece)) (set! piece #f))
                 n)
               (let ((next (pull)))
                 (if (eof-object? next)
                     0
                     (begin (set! piece next) (set! at 0) (fill)))))))
       #f #f #f)))

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
