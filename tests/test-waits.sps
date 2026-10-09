#!r6rs
;;; (http-server private waits): what a handler waits with.  M7.2.
;;;
;;; Oracles: decision 0015, design §5.3's R4, and the scheduler's refusals
;;; (R1, R2 and R5, decision 0014 item 3).  As in the scheduler's suite, no
;;; check loads libuv: each scheduler polls a script, which records the mode
;;; it was asked to poll in and runs the next batch of callbacks, as
;;; `uv-run` runs the callbacks that landed, answering whether more batches
;;; remain.  Every run of turns is capped by a count, never by the clock
;;; (global-constraints).
;;;
;;; The checks (the second step, `await`):
;;;   - a wait parks until its resume is called, from a callback, and
;;;     answers what the resume was given;
;;;   - a resume called while `register` runs: the wait answers at once,
;;;     without parking;
;;;   - R4: a resume called again is logged as `late-resume`, naming the
;;;     verb, and wakes nothing, not even the coroutine waiting again on a
;;;     second wait; and so for a resume called twice while `register` runs;
;;;   - one coroutine's resume, called by another, wakes it in the same
;;;     drain;
;;;   - a raise out of `register` comes out of the wait, and nothing parks;
;;;   - a wait begins only where a coroutine may park: on no coroutine it is
;;;     refused as R2, inside a callback as R1, inside a feed as R5, each
;;;     before `register` is called;
;;;   - a wait on a loop that keeps no waits is an assertion violation;
;;;   - a wait's park entered a second time ends the coroutine by an
;;;     assertion naming the wait, `await` (decision 0025's review), and
;;;     nothing is logged.
;;;
;;; The checks (the third step, `sleep-ms` and `with-deadline`), on a clock
;;; the suite sets, the loop's timer standing in as a recorder of each start
;;; and stop, and fired from a poll, as libuv fires it:
;;;   - a sleep parks until the timer fires at or after its time, the timer
;;;     armed for it, again for what is left, and stopped once none is left;
;;;   - sleeps wake in the order of their times, equal times in the order
;;;     they slept, the timer armed for the earliest;
;;;   - `sleep-ms` and `with-deadline` take a whole number of milliseconds,
;;;     and a timed wait on a loop whose waits keep no clock is an assertion
;;;     violation, each before anything is armed;
;;;   - the wait in progress when a deadline passes raises `&deadline-passed`,
;;;     and its sleep is taken out of the timer's keeping; and so when the
;;;     sleep falls due at the deadline's own time, its wake taken back too;
;;;   - a deadline that passes while its coroutine is not parked makes its
;;;     next wait raise at once, before anything is armed;
;;;   - `with-deadline` answers what its thunk returns, and its deadline is
;;;     taken out when the thunk returns or raises;
;;;   - once a deadline has passed, every later wait inside it raises at
;;;     once, and a wait after it does not;
;;;   - deadlines nest: an inner one passing first raises through it alone,
;;;     and the outer one, passing later, raises at the wait then; an outer
;;;     one passing inside an inner one raises out through both;
;;;   - R4: a resume after a deadline ended its wait is logged as
;;;     `late-resume`;
;;;   - `with-deadline` is refused where no coroutine may park, as a wait is,
;;;     its thunk not run;
;;;   - a raise that a handler outside continues leaves the deadline in
;;;     force;
;;;   - an escape from the thunk by a continuation takes the deadline out, so
;;;     a wait after it is not cut short; every value the thunk returns comes
;;;     back; and a continuation that enters the thunk again, and leaves it
;;;     again, ends the deadline once, so a deadline after it still counts.
;;;
;;; The checks (the fourth step, `resolve`), the loop's resolver standing in
;;; as a recorder of each lookup asked and each cancelled:
;;;   - `resolve` parks until the lookup answers, and answers its addresses;
;;;   - a lookup's failure raises `&resolve-error`, its reason the
;;;     resolver's;
;;;   - a lookup answered while it is asked: `resolve` answers at once,
;;;     without parking;
;;;   - R4's own example: a deadline that ends a `resolve` cancels its
;;;     lookup, and the lookup's answer after it is logged as `late-resume`;
;;;   - `resolve` takes a string, and on waits with no resolver is an
;;;     assertion violation.
;;;
;;; The checks (decision 0020, a client's close), the notice the shell gives
;;; each coroutine a request's code runs on, closed as a callback closes it:
;;;   - a close ends the wait parked then: it raises `&client-closed`, and
;;;     its sleep is taken out of the timer's keeping;
;;;   - a close while the code is not parked makes its next wait raise at
;;;     once, before anything is armed; and so for a close before the code
;;;     begins;
;;;   - only once: after the close has raised, the code waits as before, a
;;;     coroutine given the notice later among it, and a second close ends
;;;     nothing;
;;;   - R4: a resume after a close ended its wait is logged as `late-resume`.
(import (rnrs) (srfi :64) (testing)
        (only (http-server awaiting) deadline-passed? client-closed? resolve-error? resolve-error-reason)
        (http-server private scheduler)
        (http-server private waits))

;; scripted : (Listof (Listof (-> Any))) -> (values (Symbol -> Boolean) (-> (Listof Symbol)))
;; A poll! that records each mode it is asked to poll in, then runs the next
;; batch of callbacks, in order, answering whether batches remain after it;
;; and a procedure answering the modes asked, in order.
(define (scripted batches)
  (let ((modes '()) (left batches))
    (values
     (lambda (mode)
       (set! modes (cons mode modes))
       (if (null? left)
           #f
           (let ((batch (car left)))
             (set! left (cdr left))
             (for-each (lambda (callback) (callback)) batch)
             (pair? left))))
     (lambda () (reverse modes)))))

;; turns! : Scheduler Nat -> Nat — turns, up to `cap`, until one answers
;; that no work remains: the turns taken.
(define (turns! s cap)
  (let loop ((i 1))
    (if (and (scheduler-turn! s) (< i cap))
        (loop (+ i 1))
        i)))

;; taken : Scheduler Nat -> Any
;; `(returned n)`, the turns taken, or what refusal makes of a raise out
;; of them, so a check reads a raise as its own failure.
(define (taken s cap) (refusal (lambda () (turns! s cap))))

;; recorder : -> (values (Any -> Void) (-> (Listof Any)))
;; A procedure that records what it is given, and one answering it, in order.
(define (recorder)
  (let ((seen '()))
    (values (lambda (x) (set! seen (cons x seen)))
            (lambda () (reverse seen)))))

;; logger : -> (values (Symbol (Listof Any) -> Void) (-> (Listof Any)))
;; A log that records `(what . details)`, and a procedure answering it, in
;; order.
(define (logger)
  (let-values (((note! seen) (recorder)))
    (values (lambda (what details) (note! (cons what details))) seen)))

;; refusal : (-> Any) -> Any
;; The invariant a scheduler refusal names, `(refused r1)` and so on; the
;; symbol `assertion` for another assertion violation; `other` for any
;; other raise; or `(returned v)`.
(define (refusal thunk)
  (guard (e ((scheduler-invariant? e) (list 'refused (scheduler-invariant-name e)))
            ((assertion-violation? e) 'assertion)
            (#t 'other))
    (list 'returned (thunk))))

;; ender : (Any -> Void) -> (Symbol Any -> Void)
;; An end procedure that records `(end kind value)`, a raise's condition as
;; the symbol `condition`.
(define (ender note!)
  (lambda (kind v) (note! (list 'end kind (if (condition? v) 'condition v)))))

;; clocked : (-> Nat) (Listof (Listof (-> Any))) -> (values Scheduler (-> (Listof Any)) (-> (Listof Any)))
;; A scheduler polling `batches`, with waits that log and keep time by
;; `now`, their timer recording each start, `(start ms)`, and each stop,
;; `(stop)`; the log, and the timer's record.
(define (clocked now batches)
  (let*-values (((s logged) (waiting batches))
                ((note! timer) (recorder)))
    (waits-clock! (scheduler-waits s) now
                  (lambda (ms) (note! (list 'start ms)))
                  (lambda () (note! '(stop))))
    (values s logged timer)))

;; refused-by : (-> Any) -> Any
;; `(assertion who)` for an assertion violation, naming who refused it, or
;; `other` for any other raise, or `(returned v)`.
(define (refused-by thunk)
  (guard (e ((assertion-violation? e) (list 'assertion (and (who-condition? e) (condition-who e))))
            (#t 'other))
    (list 'returned (thunk))))

;; passed-or : (-> Any) -> Any — what `thunk` returns, or `passed` if a
;; deadline's raise comes out of it.
(define (passed-or thunk)
  (guard (e ((deadline-passed? e) 'passed)) (thunk)))

;; closed-or : (-> Any) -> Any — what `thunk` returns, or `closed` if a
;; client's close raises out of it.
(define (closed-or thunk)
  (guard (e ((client-closed? e) 'closed)) (thunk)))

;; await-entered-twice : -> (List (Listof Any) (Listof Any))
;; A coroutine that awaits inside a dynamic-wind whose before thunk, as the
;; coroutine is resumed, captures the continuation it runs in; once its
;; wait has answered, the coroutine calls that continuation, which enters
;; the wait's park again.  What it noted, `landed` at each landing, then its
;; end, `(returned v)` or `(raised who)` for a condition naming who; and the
;; waits' log.
(define (await-entered-twice)
  (let*-values (((note! seen) (recorder))
                ((resume) #f)
                ((again) #f)
                ((armed) #f)
                ((s logged) (waiting (list (list (lambda () (set! armed #t) (resume 'go)))))))
    (scheduler-spawn! s
      (lambda ()
        (dynamic-wind
         (lambda () (when armed (call/cc (lambda (k) (set! again k)))))
         (lambda ()
           (await (lambda (r) (set! resume r)))
           (note! 'landed)
           (let ((k again))
             (when k (set! again #f) (k #f)))
           'done)
         (lambda () #f)))
      (lambda (kind v)
        (note! (list kind (if (and (condition? v) (who-condition? v)) (condition-who v) v)))))
    (turns! s 4)
    (list (seen) (logged))))

;; waiting : (Listof (Listof (-> Any))) -> (values Scheduler (-> (Listof Any)))
;; A scheduler polling `batches`, with waits that log, and the log.
(define (waiting batches)
  (let*-values (((poll! modes) (scripted batches))
                ((log! logged) (logger)))
    (let ((s (make-scheduler poll!)))
      (make-waits s log!)
      (values s logged))))

(run-suite "waits"
  (lambda ()
    ;; --- await ---------------------------------------------------------------
    (let*-values (((note! seen) (recorder))
                  ((resume) #f)
                  ((s logged) (waiting (list (list (lambda () (note! 'callback) (resume 'answer)))))))
      (scheduler-spawn! s
        (lambda ()
          (note! 'waits)
          (let ((v (await (lambda (r) (set! resume r)))))
            (note! (list 'resumed v (scheduler-phase)))
            'done))
        (ender note!))
      (let ((t (taken s 4)))
        (test-equal "a wait parks until its resume is called, from a callback, and answers what the resume was given"
          '((returned 2) (waits callback (resumed answer scheduling) (end returned done)) ())
          (list t (seen) (logged)))))

    (let*-values (((note! seen) (recorder))
                  ((s logged) (waiting '())))
      (scheduler-spawn! s
        (lambda ()
          (note! (list 'early (await (lambda (resume) (resume 'now)))))
          'done)
        (ender note!))
      (scheduler-spawn! s (lambda () (note! 'next) 'n) (ender note!))
      (let ((t (taken s 4)))
        (test-equal "a resume called while register runs: the wait answers at once, without parking"
          '((returned 1) ((early now) (end returned done) next (end returned n)) ())
          (list t (seen) (logged)))))

    ;; R4 (design §5.3): the first resume wakes, every later one is logged and
    ;; wakes nothing, even the coroutine parked on a wait of its own since.
    (let*-values (((note! seen) (recorder))
                  ((first second) (values #f #f))
                  ((s logged) (waiting (list (list (lambda () (first 'one)))
                                             (list (lambda () (note! 'again) (first 'late)))
                                             (list (lambda () (second 'two)))))))
      (scheduler-spawn! s
        (lambda ()
          (let* ((a (await (lambda (r) (set! first r))))
                 (b (await (lambda (r) (set! second r)))))
            (note! (list 'resumed a b))
            'done))
        (ender note!))
      (let ((t (taken s 8)))
        (test-equal "R4: a resume called again is logged as late-resume, naming the verb, and wakes nothing, not even the coroutine waiting again"
          '((returned 4) (again (resumed one two) (end returned done)) ((late-resume await)))
          (list t (seen) (logged)))))

    (let*-values (((note! seen) (recorder))
                  ((s logged) (waiting '())))
      (scheduler-spawn! s
        (lambda () (await (lambda (resume) (resume 'once) (resume 'twice))))
        (ender note!))
      (let ((t (taken s 4)))
        (test-equal "R4: a resume called twice while register runs: the wait answers the first, and the second is logged"
          '((returned 1) ((end returned once)) ((late-resume await)))
          (list t (seen) (logged)))))

    ;; One request can wake another (decision 0015 item 1).
    (let*-values (((note! seen) (recorder))
                  ((resume) #f)
                  ((s logged) (waiting '())))
      (scheduler-spawn! s
        (lambda () (note! (list 'woken (await (lambda (r) (set! resume r))))) 'a)
        (ender note!))
      (scheduler-spawn! s
        (lambda () (note! 'waking) (resume 'from-b) (note! 'woke) 'b)
        (ender note!))
      (let ((t (taken s 4)))
        (test-equal "one coroutine's resume, called by another, wakes it in the same drain"
          '((returned 1) (waking woke (end returned b) (woken from-b) (end returned a)))
          (list t (seen)))))

    (let*-values (((note! seen) (recorder))
                  ((s logged) (waiting '())))
      (scheduler-spawn! s
        (lambda () (await (lambda (resume) (raise 'refused))) 'not-here)
        (ender note!))
      (scheduler-spawn! s (lambda () (note! 'next) 'n) (ender note!))
      (let ((t (taken s 4)))
        (test-equal "a raise out of register comes out of the wait, and nothing parks"
          '((returned 1) ((end raised refused) next (end returned n)))
          (list t (seen)))))

    ;; Decision 0014 item 3: a wait outside a coroutine is refused, here
    ;; before `register` runs, so nothing is left registered to resume.
    (let*-values (((registered) '())
                  ((s logged)
                   (waiting (list (list (lambda ()
                                          (set! registered
                                                (cons (refusal (lambda () (await (lambda (r) (set! registered (cons 'r1 registered))))))
                                                      registered))))))))
      (let ((on-none (refusal (lambda () (await (lambda (r) (set! registered (cons 'r2 registered))))))))
        (scheduler-spawn! s
          (lambda ()
            (let* ((before (scheduler-feed-begin!))
                   (in-feed (refusal (lambda () (await (lambda (r) (set! registered (cons 'r5 registered))))))))
              (scheduler-feed-end! before)
              (set! registered (cons in-feed registered))))
          (lambda (kind v) #f))
        (let ((t (taken s 4)))
          (test-equal "a wait on no coroutine is refused as R2, in a callback as R1, in a feed as R5, each before register runs"
            '((returned 1) (refused r2) (refused r5) (refused r1))
            (cons* t on-none (reverse registered))))))

    (let-values (((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)) (outcome #f))
        (scheduler-spawn! s
          (lambda () (await (lambda (r) (r 'never))))
          (lambda (kind v) (set! outcome (list kind (if (assertion-violation? v) 'assertion v)))))
        (let ((t (taken s 4)))
          (test-equal "a wait on a loop that keeps no waits is an assertion violation"
            '((returned 1) (raised assertion)) (list t outcome)))))

    (test-equal "a wait's park entered a second time ends the coroutine by an assertion naming the wait, await, and nothing is logged"
      '((landed (raised await)) ())
      (await-entered-twice))

    ;; --- sleep-ms and with-deadline ------------------------------------------
    ;; Each check keeps time in `clock`, which its batches set before they
    ;; fire the loop's timer, as libuv fires it, inside the poll.
    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 9) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 10) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda () (sleep-ms 10) (note! (list 'woke (vector-ref clock 0))) 'done)
          (ender note!))
        (let ((t (taken s 8)))
          (test-equal "a sleep parks until the timer fires at or after its time; the timer armed for it, again for what is left, and stopped once none is left"
            '((returned 3) ((woke 10) (end returned done)) ((start 10) (start 1) (stop)) 0)
            (list t (seen) (timer) (waits-timed w))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 10) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 20) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (for-each (lambda (name ms)
                    (scheduler-spawn! s
                      (lambda () (sleep-ms ms) (note! (list name (vector-ref clock 0))))
                      (lambda (kind v) #f)))
                  '(a b c) '(20 10 10))
        (let ((t (taken s 8)))
          (test-equal "sleeps wake in the order of their times, equal times in the order they slept, the timer armed for the earliest"
            '((returned 3) ((b 10) (c 10) (a 20)) ((start 20) (start 10) (start 10) (stop)))
            (list t (seen) (timer))))))

    ;; At 10 on the clock, -1 would make a time the heap takes, 9: the verbs
    ;; refuse it themselves.
    (let-values (((s logged timer) (clocked (lambda () 10) '()))
                 ((note! seen) (recorder)))
      (scheduler-spawn! s
        (lambda ()
          (note! (map (lambda (bad) (refused-by (lambda () (sleep-ms bad)))) '(-1 1.5 soon)))
          (note! (map (lambda (bad) (refused-by (lambda () (with-deadline bad (lambda () 'ran))))) '(-1 1.5 soon))))
        (lambda (kind v) #f))
      (let ((t (taken s 4)))
        (test-equal "sleep-ms and with-deadline take a whole number of milliseconds, refused by them before anything is armed"
          '((returned 1)
            (((assertion sleep-ms) (assertion sleep-ms) (assertion sleep-ms))
             ((assertion with-deadline) (assertion with-deadline) (assertion with-deadline)))
            ())
          (list t (seen) (timer)))))

    (let*-values (((s logged) (waiting '()))
                  ((note! seen) (recorder)))
      (scheduler-spawn! s
        (lambda ()
          (note! (refused-by (lambda () (sleep-ms 1))))
          (note! (refused-by (lambda () (with-deadline 1 (lambda () 'ran))))))
        (lambda (kind v) #f))
      (let ((t (taken s 4)))
        (test-equal "a timed wait on a loop whose waits keep no clock is an assertion violation, the verb's"
          '((returned 1) ((assertion sleep-ms) (assertion with-deadline)))
          (list t (seen)))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 50) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda () (note! (passed-or (lambda () (with-deadline 5 (lambda () (sleep-ms 50) 'slept))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "the wait in progress when a deadline passes raises &deadline-passed, and its sleep is taken out of the timer's keeping"
            '((returned 2) (passed) ((start 5) (stop) (stop)) () 0)
            (list t (seen) (timer) (logged) (waits-timed w))))))

    ;; A sleep due at its deadline's own time, the deadline armed first: one
    ;; advance takes out both, the deadline first, and the sleep it took
    ;; back must not wake, nor be logged late.
    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 10) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda () (note! (passed-or (lambda () (with-deadline 10 (lambda () (sleep-ms 10) 'slept))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "a sleep due at its deadline's own time, the deadline armed first: the wait raises, and the sleep taken back wakes nothing and logs nothing"
            '((returned 2) (passed) ())
            (list t (seen) (logged))))))

    (let* ((clock (vector 0)) (w #f) (resume #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (resume 'go) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (with-deadline 5
              (lambda ()
                (note! (list 'got (await (lambda (r) (set! resume r)))))
                (note! (passed-or (lambda () (sleep-ms 1) 'slept))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "a deadline that passes while its coroutine is not parked makes its next wait raise at once, before anything is armed"
            '((returned 2) ((got go) passed) ((start 5) (stop)))
            (list t (seen) (timer))))))

    (let-values (((s logged timer) (clocked (lambda () 0) '()))
                 ((note! seen) (recorder)))
      (scheduler-spawn! s
        (lambda ()
          (note! (with-deadline 100 (lambda () 'fine)))
          (note! (guard (e (#t 'caught)) (with-deadline 100 (lambda () (raise 'boom))))))
        (lambda (kind v) #f))
      (let ((t (taken s 4)))
        (test-equal "with-deadline answers what its thunk returns, and its deadline is taken out when the thunk returns or raises"
          '((returned 1) (fine caught) 0)
          (list t (seen) (waits-timed (scheduler-waits s))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 6) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (with-deadline 5
              (lambda ()
                (note! (passed-or (lambda () (sleep-ms 50) 'slept)))
                (note! (passed-or (lambda () (sleep-ms 1) 'slept)))))
            (sleep-ms 1)
            (note! (list 'slept (vector-ref clock 0))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "once a deadline has passed, every later wait inside it raises at once, and a wait after it does not"
            '((returned 3) (passed passed (slept 6)) ((start 5) (stop) (start 1) (stop)))
            (list t (seen) (timer))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 20) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (note! (list 'outer
                         (passed-or
                          (lambda ()
                            (with-deadline 20
                              (lambda ()
                                (note! (list 'inner (passed-or (lambda () (with-deadline 5 (lambda () (sleep-ms 50) 'slept))))))
                                (sleep-ms 50)
                                'slept)))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "deadlines nest: the inner one passing first raises through it alone, and the outer one, passing later, raises at the wait then"
            '((returned 3) ((inner passed) (outer passed)) ((start 20) (start 5) (start 15) (stop)) 0)
            (list t (seen) (timer) (waits-timed w))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (note! (list 'outer (passed-or (lambda () (with-deadline 5 (lambda () (with-deadline 50 (lambda () (sleep-ms 100) 'slept)))))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "an outer deadline passing inside an inner one raises out through both, and takes the inner one out"
            '((returned 2) ((outer passed)) ((start 5) (start 45)) 0)
            (list t (seen) (timer) (waits-timed w))))))

    (let* ((clock (vector 0)) (w #f) (resume #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (resume 'late)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda () (note! (passed-or (lambda () (with-deadline 5 (lambda () (await (lambda (r) (set! resume r)))))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "R4: a resume after a deadline ended its wait is logged as late-resume"
            '((returned 2) (passed) ((late-resume await)))
            (list t (seen) (logged))))))

    (let* ((ran '())
           (note-ran! (lambda (x) (set! ran (cons x ran))))
           (try (lambda (tag) (refusal (lambda () (with-deadline 5 (lambda () (note-ran! tag))))))))
      (let*-values (((s logged timer)
                     (clocked (lambda () 0) (list (list (lambda () (note-ran! (try 'r1-ran))))))))
        (let ((on-none (try 'r2-ran)))
          (scheduler-spawn! s
            (lambda ()
              (let* ((before (scheduler-feed-begin!))
                     (in-feed (try 'r5-ran)))
                (scheduler-feed-end! before)
                (note-ran! in-feed)))
            (lambda (kind v) #f))
          (let ((t (taken s 4)))
            (test-equal "with-deadline is refused as a wait is, on no coroutine as R2, in a feed as R5, in a callback as R1, its thunk not run and nothing armed"
              '((returned 1) (refused r2) (refused r5) (refused r1) ())
              (append (list t on-none) (reverse ran) (list (timer))))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (note! (passed-or
                    (lambda ()
                      (with-exception-handler
                       (lambda (e) (if (eq? e 'warn) 'continued (raise-continuable e)))
                       (lambda ()
                         (with-deadline 5
                           (lambda ()
                             (note! (list 'continued (raise-continuable 'warn)))
                             (sleep-ms 50)
                             'slept))))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "a raise that a handler outside continues leaves the deadline in force"
            '((returned 2) ((continued continued) passed) ((start 5) (stop)))
            (list t (seen) (timer))))))

    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 50) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (note! (call/cc (lambda (k) (with-deadline 5 (lambda () (k 'escaped))))))
            (note! (waits-timed w))
            (note! (passed-or (lambda () (sleep-ms 50) (list 'slept (vector-ref clock 0))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "an escape from with-deadline's thunk by a continuation takes the deadline out, and a wait after it is not cut short"
            '((returned 3) (escaped 0 (slept 50)) ((start 5) (start 50) (start 45) (stop)))
            (list t (seen) (timer))))))

    (let-values (((s logged timer) (clocked (lambda () 0) '()))
                 ((note! seen) (recorder)))
      (scheduler-spawn! s
        (lambda () (note! (call-with-values (lambda () (with-deadline 100 (lambda () (values 1 2 3)))) list)))
        (lambda (kind v) (note! (list 'end kind))))
      (let ((t (taken s 4)))
        (test-equal "with-deadline answers every value its thunk returns"
          '((returned 1) ((1 2 3) (end returned)))
          (list t (seen)))))

    ;; Entered again by a continuation after it has passed and ended, and
    ;; left again: the deadline ends once, or the count of passed deadlines
    ;; goes below zero, and a deadline after it, once passed, would spare
    ;; the next wait.
    (let* ((clock (vector 0)) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () (vector-set! clock 0 15) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (scheduler-spawn! s
          (lambda ()
            (let ((again #f) (entries 0))
              (note! (passed-or
                      (lambda ()
                        (with-deadline 5
                          (lambda ()
                            (call/cc (lambda (k) (set! again k)))
                            (set! entries (+ entries 1))
                            (if (= entries 1) (begin (sleep-ms 50) 'slept) 'entered-again))))))
              (when (= entries 1) (again #f))
              (with-deadline 10
                (lambda ()
                  (note! (passed-or (lambda () (sleep-ms 50) 'slept)))
                  (note! (passed-or (lambda () (sleep-ms 1) 'slept)))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "a continuation that enters a deadline's thunk again and leaves it again ends the deadline once, and a deadline after it still counts"
            '((returned 3) (passed entered-again passed passed))
            (list t (seen))))))

    ;; --- resolve ---------------------------------------------------------------
    ;; Each check's resolver records each lookup asked, `(lookup host)`, and
    ;; each cancel, `(cancel request)`, a request being the lookup's number;
    ;; its batches answer a lookup through the procedure it was given.
    (let* ((answers '()) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged) (waiting (list (list (lambda () ((car answers) #f '("::1" "127.0.0.1")))))))
                    ((note-asked! asked) (recorder)))
        (set! w (scheduler-waits s))
        (waits-resolver! w
                         (lambda (host answer!) (note-asked! (list 'lookup host)) (set! answers (cons answer! answers)) (length answers))
                         (lambda (request) (note-asked! (list 'cancel request))))
        (scheduler-spawn! s (lambda () (note! (resolve "localhost"))) (lambda (kind v) #f))
        (let ((t (taken s 4)))
          (test-equal "resolve parks until the lookup answers, and answers its addresses"
            '((returned 2) (("::1" "127.0.0.1")) ((lookup "localhost")))
            (list t (seen) (asked))))))

    (let* ((answers '()) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged) (waiting (list (list (lambda () ((car answers) 'EAI_NONAME '()))))))
                    ((note-asked! asked) (recorder)))
        (set! w (scheduler-waits s))
        (waits-resolver! w
                         (lambda (host answer!) (set! answers (cons answer! answers)) (length answers))
                         (lambda (request) (note-asked! (list 'cancel request))))
        (scheduler-spawn! s
          (lambda ()
            (note! (guard (e ((resolve-error? e) (list 'refused (resolve-error-reason e))))
                     (resolve "nowhere.invalid"))))
          (lambda (kind v) #f))
        (let ((t (taken s 4)))
          (test-equal "a lookup's failure raises &resolve-error, its reason the resolver's"
            '((returned 2) ((refused EAI_NONAME)))
            (list t (seen))))))

    (let*-values (((note! seen) (recorder))
                  ((s logged) (waiting '())))
      (waits-resolver! (scheduler-waits s)
                       (lambda (host answer!) (answer! #f (list host)) #f)
                       (lambda (request) (note! (list 'cancel request))))
      (scheduler-spawn! s (lambda () (note! (resolve "127.0.0.1"))) (lambda (kind v) #f))
      (scheduler-spawn! s (lambda () (note! 'next)) (lambda (kind v) #f))
      (let ((t (taken s 4)))
        (test-equal "a lookup answered while it is asked: resolve answers at once, without parking"
          '((returned 1) (("127.0.0.1") next))
          (list t (seen)))))

    ;; R4's own example (plan §14's M7.2): a lookup's answer after its
    ;; deadline wakes nothing, and is logged.
    (let* ((clock (vector 0)) (answers '()) (w #f))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))
                                    (list (lambda () ((car answers) #f '("192.0.2.1")))))))
                    ((note-asked! asked) (recorder)))
        (set! w (scheduler-waits s))
        (waits-resolver! w
                         (lambda (host answer!) (note-asked! (list 'lookup host)) (set! answers (cons answer! answers)) (length answers))
                         (lambda (request) (note-asked! (list 'cancel request))))
        (scheduler-spawn! s
          (lambda () (note! (passed-or (lambda () (with-deadline 5 (lambda () (resolve "slow.example")))))))
          (lambda (kind v) #f))
        (let ((t (taken s 8)))
          (test-equal "R4: a deadline that ends a resolve cancels its lookup, and the lookup's answer after it is logged as late-resume"
            '((returned 2) (passed) ((lookup "slow.example") (cancel 1)) ((late-resume resolve)))
            (list t (seen) (asked) (logged))))))

    ;; A resolver that would answer at once, so that only resolve's own
    ;; check refuses a name that is not a string; and waits with none.
    (let*-values (((s logged) (waiting '()))
                  ((bare bare-logged) (waiting '()))
                  ((note! seen) (recorder)))
      (waits-resolver! (scheduler-waits s) (lambda (host answer!) (answer! #f '("answered")) #f) (lambda (r) #f))
      (scheduler-spawn! s (lambda () (note! (refused-by (lambda () (resolve 'localhost))))) (lambda (kind v) #f))
      (scheduler-spawn! bare (lambda () (note! (refused-by (lambda () (resolve "localhost"))))) (lambda (kind v) #f))
      (let* ((t (taken s 4)) (u (taken bare 4)))
        (test-equal "resolve takes a string, and on waits with no resolver is an assertion violation, its own"
          '((returned 1) (returned 1) ((assertion resolve) (assertion resolve)))
          (list t u (seen)))))

    ;; --- a client's close (decision 0020) ------------------------------------
    (let* ((clock (vector 0)) (w #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (vector-set! clock 0 5) (notice-close! n)))))))
        (set! w (scheduler-waits s))
        (notice-attach! (scheduler-spawn! s
                          (lambda () (note! (closed-or (lambda () (sleep-ms 50) 'slept))))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 8)))
          (test-equal "a client's close ends the wait parked then: it raises &client-closed, and its sleep is taken out of the timer's keeping"
            '((returned 2) (closed) ((start 50)) () 0)
            (list t (seen) (timer) (logged) (waits-timed w))))))

    (let* ((clock (vector 0)) (resume #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (resume 'go) (notice-close! n)))))))
        (notice-attach! (scheduler-spawn! s
                          (lambda ()
                            (note! (list 'got (await (lambda (r) (set! resume r)))))
                            (note! (closed-or (lambda () (sleep-ms 1) 'slept))))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 8)))
          (test-equal "a close while the request's code is not parked makes its next wait raise at once, before anything is armed"
            '((returned 2) ((got go) closed) ())
            (list t (seen) (timer))))))

    (let* ((clock (vector 0)) (n (make-notice)))
      (notice-close! n)
      (let*-values (((note! seen) (recorder))
                    ((s logged timer) (clocked (lambda () (vector-ref clock 0)) '())))
        (notice-attach! (scheduler-spawn! s
                          (lambda () (note! (closed-or (lambda () (sleep-ms 1) 'slept))))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 4)))
          (test-equal "a close before the request's code begins makes its first wait raise, before anything is armed"
            '((returned 1) (closed) ())
            (list t (seen) (timer))))))

    (let* ((clock (vector 0)) (w #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (notice-close! n)))
                                    (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (notice-attach! (scheduler-spawn! s
                          (lambda ()
                            (note! (closed-or (lambda () (sleep-ms 50) 'slept)))
                            (sleep-ms 5)
                            (note! 'slept-again))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 8)))
          (test-equal "only once: after the close has raised, the request's code waits as before"
            '((returned 3) (closed slept-again) ((start 50) (start 5) (stop)))
            (list t (seen) (timer))))))

    ;; The shell gives the notice to each coroutine it runs the request's
    ;; code on, starting the next once one has ended, from its end.
    (let* ((clock (vector 0)) (w #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (notice-close! n)))
                                    (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (notice-attach! (scheduler-spawn! s
                          (lambda () (note! (closed-or (lambda () (sleep-ms 50) 'slept))))
                          (lambda (kind v)
                            (notice-attach! (scheduler-spawn! s
                                              (lambda () (note! (closed-or (lambda () (sleep-ms 5) 'slept))))
                                              (lambda (kind v) #f))
                                            n)))
                        n)
        (let ((t (taken s 8)))
          (test-equal "once for the request: a coroutine given the notice after the close has raised waits as any other"
            '((returned 3) (closed slept))
            (list t (seen))))))

    (let* ((clock (vector 0)) (w #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged timer)
                     (clocked (lambda () (vector-ref clock 0))
                              (list (list (lambda () (notice-close! n)))
                                    (list (lambda () (notice-close! n)))
                                    (list (lambda () (vector-set! clock 0 5) (waits-fire! w)))))))
        (set! w (scheduler-waits s))
        (notice-attach! (scheduler-spawn! s
                          (lambda ()
                            (note! (closed-or (lambda () (sleep-ms 50) 'slept)))
                            (sleep-ms 5)
                            (note! 'slept-again))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 8)))
          (test-equal "a second close, while the code waits again after the first raised, ends nothing"
            '((returned 4) (closed slept-again))
            (list t (seen))))))

    (let* ((resume #f) (n (make-notice)))
      (let*-values (((note! seen) (recorder))
                    ((s logged) (waiting (list (list (lambda () (notice-close! n)))
                                               (list (lambda () (resume 'late)))))))
        (notice-attach! (scheduler-spawn! s
                          (lambda () (note! (closed-or (lambda () (await (lambda (r) (set! resume r)))))))
                          (lambda (kind v) #f))
                        n)
        (let ((t (taken s 8)))
          (test-equal "R4: a resume after a close ended its wait is logged as late-resume"
            '((returned 2) (closed) ((late-resume await)))
            (list t (seen) (logged))))))))
