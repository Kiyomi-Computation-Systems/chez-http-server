#!r6rs
;;; (http-server private scheduler) — coroutines, and the turn of two levels
;;; (design §5.2 and §5.3; decisions 0003 and 0014; M7.1).
;;;
;;; A handler that waits cannot wait inside libuv's callback: a continuation
;;; captured under a C frame can never be resumed (design §5.1).  So a
;;; coroutine is entered and resumed only from this scheduler's DRAIN, which
;;; runs between libuv's runs, and libuv's callbacks only enqueue.  A TURN is
;;; the drain, then one poll: `(poll! mode)`, the injected procedure the libuv
;;; shell makes `uv-run` with, in 'once when nothing is ready and 'nowait
;;; when a coroutine has yielded, so the poll blocks only when nothing is left
;;; to run.  `poll!` is the one injection point, so a scheduler's checks
;;; script the callbacks that land and never load libuv.
;;;
;;; A COROUTINE is a thunk run on a one-shot continuation the drain enters
;;; (`call/1cc`).  It parks by capturing its own continuation and jumping to
;;; the drain's; `coroutine-wake!` makes it ready again, from a callback or
;;; anywhere else, and the drain resumes it with what the wake gave.  It ends
;;; by jumping to the drain's current continuation, never by returning (R3,
;;; below): its value, or what it raised, is caught on its own stack and
;;; handed to its end procedure by the drain, on no coroutine.  A CALL is a
;;; thunk the drain makes in place, on no coroutine: an ordinary handler's
;;; call (decision 0014).
;;;
;;; THE DRAIN runs what is ready in the order it was made ready, coroutines
;;; and calls alike, and then what was made ready while it ran, until nothing
;;; is: a coroutine whose end hands on work, a producer asked again, runs in
;;; the same drain (decided while building M7.1, measured by the M7 spike: a
;;; drain that stopped at what was ready as it began made each piece of a
;;; stream wait a turn).  A coroutine that yields is ready only once the
;;; turn's poll is over, so a coroutine that keeps yielding never keeps the
;;; loop from polling.
;;;
;;; THE PHASE is 'scheduling outside the poll, 'in-uv-run inside it, where
;;; libuv's callbacks run, and 'in-parser through a feed, whatever the
;;; phase around it (`scheduler-feed-begin!` and `scheduler-feed-end!`,
;;; which allocate nothing, so a shell may set it at every read).  It and the running
;;; coroutine are the process's, not a scheduler's: v1 is one thread (design
;;; §7.4), one turn runs at a time, and a waiting verb, which has no scheduler
;;; to name, finds both here.
;;;
;;; THE INVARIANTS ARE CHECKS (design §5.3), each a refusal raised as
;;; `&scheduler-invariant`, an `&assertion` naming it:
;;;   R1  a callback captures no continuation: a park, or a drain, inside the
;;;       poll is refused as 'r1;
;;;   R2  a continuation is captured only on a coroutine's stack, entered
;;;       from the drain: a park on no coroutine is refused as 'r2;
;;;   R3  a coroutine never returns normally: it ends by jumping to the
;;;       drain's current continuation, the one that entered or resumed it
;;;       last, since the one that first entered it was used as it parked;
;;;   R5  a parser callback never waits: a park inside a feed is refused as
;;;       'r5.
;;; R4, one-shot resume cells, is (http-server private waits)'s (M7.2).  A
;;; wake of a coroutine that is not parked, and a drain re-entered from a
;;; coroutine, are the caller's bugs, plain assertion violations.
;;;
;;; A scheduler keeps its loop's WAITS, (http-server private waits)'s, and a
;;; coroutine what its waits keep of it, the wait it is parked on and how
;;; many of its deadlines have passed: neither reads them, and a waiting
;;; verb finds both through the coroutine running.
(library (http-server private scheduler)
  (export make-scheduler scheduler? scheduler-ready?
          scheduler-spawn! scheduler-call! scheduler-drain! scheduler-turn! scheduler-turn-abandoned!
          scheduler-waits scheduler-waits-set!
          coroutine? current-coroutine coroutine-scheduler waiting-coroutine
          coroutine-waits coroutine-waits-set! coroutine-suspending?
          coroutine-park! coroutine-wake! coroutine-yield!
          scheduler-phase scheduler-feed-begin! scheduler-feed-end!
          &scheduler-invariant scheduler-invariant? scheduler-invariant-name)
  (import (rnrs) (only (chezscheme) call/1cc))

  ;; &scheduler-invariant : an invariant of design §5.3 refused.
  ;; scheduler-invariant? : Any -> Boolean
  ;; scheduler-invariant-name : SchedulerInvariant -> (U 'r1 'r2 'r5)
  (define-condition-type &scheduler-invariant &assertion
    make-scheduler-invariant scheduler-invariant?
    (name scheduler-invariant-name))

  ;; refuse : Symbol Symbol String -> [raises]
  (define (refuse invariant who message)
    (raise (condition (make-scheduler-invariant invariant)
                      (make-who-condition who)
                      (make-message-condition message))))

  ;; make-scheduler : (Symbol -> Any) -> Scheduler
  ;; A scheduler whose turn polls with `poll!`, called with 'once or
  ;; 'nowait and answering whether work remains, as uv-run answers.
  ;; scheduler? : Any -> Boolean
  ;; scheduler-waits : Scheduler -> Any — its loop's waits, or #f
  ;; scheduler-waits-set! : Scheduler Any -> Void
  (define-record-type (scheduler make-scheduler scheduler?)
    (fields poll
            (mutable front) (mutable back)  ; ready: front in order, back reversed
            (mutable later)                 ; yielded, reversed: ready once the poll is over
            (mutable k)                     ; the drain's continuation, while a coroutine runs
            (mutable waits))                ; its loop's waits, which it never reads
    (protocol (lambda (new) (lambda (poll!) (new poll! '() '() '() #f #f)))))

  ;; coroutine? : Any -> Boolean
  ;; coroutine-scheduler : Coroutine -> Scheduler — the one that runs it
  ;; coroutine-waits : Coroutine -> Any — what its waits keep of it, or #f
  ;; coroutine-waits-set! : Coroutine Any -> Void
  ;; A coroutine is 'ready, 'running, 'parked or 'ended.  `k` is its
  ;; continuation while parked, `value` what a wake gave it, and then its
  ;; end: what it returned or raised.
  (define-record-type (coroutine make-coroutine coroutine?)
    (fields scheduler thunk on-end
            (mutable state) (mutable k) (mutable value) (mutable raised?)
            (mutable waits))                ; what its waits keep of it, which it never reads
    (protocol (lambda (new)
                (lambda (s thunk on-end) (new s thunk on-end 'ready #f #f #f #f)))))

  ;; coroutine-suspending? : Coroutine -> Boolean
  ;; Whether it is parking or yielding: what a `dynamic-wind` on its stack
  ;; reads, as its after thunk runs, to tell a park from a leaving.  A park
  ;; marks the coroutine before it jumps to the drain.
  (define (coroutine-suspending? c)
    (and (memq (coroutine-state c) '(parked yielded)) #t))

  ;; The process's phase, and the coroutine running, if one is.
  (define phase 'scheduling)
  (define running #f)

  ;; scheduler-phase : -> (U 'scheduling 'in-uv-run 'in-parser)
  (define (scheduler-phase) phase)

  ;; current-coroutine : -> (U Coroutine #f) — the coroutine running.
  (define (current-coroutine) running)

  ;; scheduler-feed-begin! : -> Phase
  ;; A feed begins: the phase is 'in-parser, and the phase it was is
  ;; answered, for scheduler-feed-end!.
  ;; scheduler-feed-end! : Phase -> Void
  ;; The feed is over: the phase is `before` again.  A caller whose feed
  ;; raises sets it back on the way out, as the libuv shell's drain does.
  (define (scheduler-feed-begin!)
    (let ((before phase))
      (set! phase 'in-parser)
      before))
  (define (scheduler-feed-end! before)
    (set! phase before))

  ;; scheduler-ready? : Scheduler -> Boolean — whether anything waits to run.
  (define (scheduler-ready? s)
    (not (and (null? (scheduler-front s)) (null? (scheduler-back s)))))

  ;; enqueue! : Scheduler (U Coroutine (-> Any)) -> Void — behind what is ready.
  (define (enqueue! s item)
    (scheduler-back-set! s (cons item (scheduler-back s))))

  ;; dequeue! : Scheduler -> (U Coroutine (-> Any) #f) — the oldest ready.
  (define (dequeue! s)
    (when (null? (scheduler-front s))
      (scheduler-front-set! s (reverse (scheduler-back s)))
      (scheduler-back-set! s '()))
    (let ((front (scheduler-front s)))
      (and (pair? front)
           (begin (scheduler-front-set! s (cdr front)) (car front)))))

  ;; scheduler-spawn! : Scheduler (-> Any) (Symbol Any -> Any) -> Coroutine
  ;; A coroutine running `thunk`, ready: entered by a drain, the one under
  ;; way if one is, never here, so a callback may spawn one.  Once it has ended, the drain calls
  ;; `(on-end 'returned value)`, or `(on-end 'raised raised)`, on no
  ;; coroutine.
  (define (scheduler-spawn! s thunk on-end)
    (let ((c (make-coroutine s thunk on-end)))
      (enqueue! s c)
      c))

  ;; scheduler-call! : Scheduler (-> Any) -> Void
  ;; `thunk`, called at the next drain, in place, on no coroutine.
  (define (scheduler-call! s thunk)
    (enqueue! s thunk))

  ;; coroutine-wake! : Coroutine Any -> Void
  ;; A parked coroutine made ready: its park answers `v` when the drain
  ;; resumes it.  One that is not parked is an assertion violation.
  (define (coroutine-wake! c v)
    (unless (eq? (coroutine-state c) 'parked)
      (assertion-violation 'coroutine-wake! "the coroutine is not parked" (coroutine-state c)))
    (coroutine-state-set! c 'ready)
    (coroutine-value-set! c v)
    (enqueue! (coroutine-scheduler c) c))

  ;; coroutine-park! : -> Any
  ;; Park the coroutine running until a wake, and answer what it gave.
  ;; Inside the poll it is refused as R1, inside a feed as R5, and on no
  ;; coroutine as R2.
  (define (coroutine-park!)
    (suspend! 'coroutine-park! 'parked))

  ;; coroutine-yield! : -> Void
  ;; Let the loop poll: the coroutine running is ready again once the
  ;; turn's poll is over.  Refused as a park is.
  (define (coroutine-yield!)
    (suspend! 'coroutine-yield! 'yielded)
    (values))

  ;; waiting-coroutine : Symbol -> Coroutine
  ;; The coroutine running, where it may park: inside the poll a wait is
  ;; refused as R1, inside a feed as R5, and on no coroutine as R2, each
  ;; naming `who`.  A wait asks before it begins.
  (define (waiting-coroutine who)
    (case phase
      ((in-uv-run) (refuse 'r1 who "a wait inside a libuv callback"))
      ((in-parser) (refuse 'r5 who "a wait inside a feed")))
    (or running (refuse 'r2 who "a wait on no coroutine")))

  ;; suspend! : Symbol Symbol -> Any — park, or yield, the coroutine running.
  (define (suspend! who how)
    (let ((c (waiting-coroutine who)))
      (call/1cc
       (lambda (k)
         (coroutine-k-set! c k)
         (coroutine-state-set! c how)
         ((scheduler-k (coroutine-scheduler c)) how)))))

  ;; scheduler-drain! : Scheduler -> Void
  ;; Run what is ready, and what is made ready meanwhile, until nothing is;
  ;; then what yielded is ready, for the next turn.  Inside the poll it is
  ;; refused as R1; from a coroutine it is an assertion violation.
  (define (scheduler-drain! s)
    (when (eq? phase 'in-uv-run) (refuse 'r1 'scheduler-drain! "a drain inside a libuv callback"))
    (when running (assertion-violation 'scheduler-drain! "a drain from a coroutine" running))
    (let loop ()
      (let ((item (dequeue! s)))
        (when item
          (if (coroutine? item) (resume! s item) (item))
          (loop))))
    (let ((later (scheduler-later s)))
      (unless (null? later)
        (scheduler-later-set! s '())
        (for-each (lambda (c) (coroutine-state-set! c 'ready) (enqueue! s c)) (reverse later)))))

  ;; resume! : Scheduler Coroutine -> Void
  ;; Enter a ready coroutine, or resume a woken one, to its next park, yield
  ;; or end; at its end, hand what it returned or raised to its end
  ;; procedure.
  (define (resume! s c)
    (coroutine-state-set! c 'running)
    (set! running c)
    (let ((how (call/1cc
                (lambda (k)
                  (scheduler-k-set! s k)
                  (let ((k0 (coroutine-k c)))
                    (if k0
                        (begin (coroutine-k-set! c #f) (k0 (coroutine-value c)))
                        (enter! s c)))))))
      (set! running #f)
      (scheduler-k-set! s #f)
      (case how
        ((yielded) (scheduler-later-set! s (cons c (scheduler-later s))))
        ((ended)
         ((coroutine-on-end c) (if (coroutine-raised? c) 'raised 'returned) (coroutine-value c))))))

  ;; enter! : Scheduler Coroutine -> [does not return]
  ;; The coroutine's first run: its thunk, then the jump to the drain's
  ;; current continuation (R3).  A raise is caught on its own stack by a
  ;; handler that makes the same jump, never returning to the raise.  Not a
  ;; `guard`: inside the one-shot continuation the drain enters, Chez gave
  ;; each coroutine a stack of its own for one, 3,756 B where this costs
  ;; under 400 (M7.2's first step, decision 0015).
  (define (enter! s c)
    (with-exception-handler
     (lambda (e)
       (coroutine-raised?-set! c #t)
       (coroutine-value-set! c e)
       (end! s c))
     (lambda () (coroutine-value-set! c ((coroutine-thunk c)))))
    (end! s c))

  ;; end! : Scheduler Coroutine -> [does not return]
  ;; The coroutine has ended: the jump to the drain's current continuation.
  (define (end! s c)
    (coroutine-state-set! c 'ended)
    ((scheduler-k s) 'ended))

  ;; scheduler-turn! : Scheduler -> Boolean
  ;; The drain, then the poll, 'nowait when something is ready and 'once
  ;; when nothing is, in the phase 'in-uv-run: whether work remains, as the
  ;; poll answers, or #t while something is ready.  The phase is set and
  ;; left with no dynamic-wind, which costs every turn 96 B and more; a
  ;; poll that raises leaves it 'in-uv-run until whoever catches the raise
  ;; calls scheduler-turn-abandoned!.
  (define (scheduler-turn! s)
    (scheduler-drain! s)
    (set! phase 'in-uv-run)
    (let ((more ((scheduler-poll s) (if (scheduler-ready? s) 'nowait 'once))))
      (set! phase 'scheduling)
      (or (and more #t) (scheduler-ready? s))))

  ;; scheduler-turn-abandoned! : -> Void
  ;; A turn's poll raised, as uv-run raises a callback's error once libuv's
  ;; turn is over, so no callback is under way: the phase is 'scheduling
  ;; again.  The run loop's guard calls it as it catches the raise.
  (define (scheduler-turn-abandoned!)
    (set! phase 'scheduling)))
