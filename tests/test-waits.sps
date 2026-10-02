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
;;;   - a wait on a loop that keeps no waits is an assertion violation.
(import (rnrs) (srfi :64) (testing)
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
            '((returned 1) (raised assertion)) (list t outcome)))))))
