#!r6rs
;;; (http-server private scheduler): coroutines on one-shot continuations, and
;;; the turn of two levels, the drain then the poll.  M7.1's first step.
;;;
;;; Oracles: design §5.2 and §5.3's invariants, decision 0003 item 2 and
;;; decision 0014.  `poll!` is the scheduler's one injection point (design
;;; §5.3), so no check loads libuv: each scheduler polls a script, which
;;; records the mode it was asked to poll in and runs the next batch of
;;; callbacks, as `uv-run` runs the callbacks that landed, answering whether
;;; more batches remain.  Every run of turns is capped by a count, never by
;;; the clock (global-constraints).
;;;
;;; The checks:
;;;   - a coroutine spawned runs at the next drain, not where it was spawned,
;;;     a callback included: a callback only enqueues (R1);
;;;   - a coroutine's end, its value or what it raised, comes to its end
;;;     procedure once it has ended, from the scheduler, on no coroutine;
;;;   - a coroutine parks, a callback wakes it, and it resumes at the next
;;;     turn's drain with what the callback gave it;
;;;   - a drain runs every coroutine and call ready, and every one made ready
;;;     while it runs, in the order they were made ready; a coroutine that
;;;     yields runs again only after the poll;
;;;   - the poll is 'once when nothing is ready after the drain, and
;;;     'nowait when a coroutine yielded (design §5.3's first mutation);
;;;   - R1: a callback that parks, and a drain inside a callback, are
;;;     refused as R1;
;;;   - R2: a park on no coroutine, from a call the drain makes or from
;;;     outside any turn, is refused as R2;
;;;   - R3: a coroutine that parks, is woken and ends, ends through the
;;;     scheduler: its end once, and the turns after it run on;
;;;   - R5: a park inside a feed is refused as R5, and the phase is the one
;;;     before the feed once it is over;
;;;   - a call is made in the drain, on no coroutine;
;;;   - waking a coroutine that is not parked is an assertion violation;
;;;   - a turn answers the poll's answer, or #t while something is ready;
;;;   - a guard inside a coroutine catches a raise after a park, and what a
;;;     coroutine parameterizes stays its own across a park.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) make-parameter parameterize)
        (http-server private scheduler))

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

;; recorder : -> (values (Any -> Void) (-> (Listof Any)))
;; A procedure that records what it is given, and one answering it, in order.
(define (recorder)
  (let ((seen '()))
    (values (lambda (x) (set! seen (cons x seen)))
            (lambda () (reverse seen)))))

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

(run-suite "scheduler"
  (lambda ()
    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s (lambda () (note! 'ran) 'v) (ender note!))
        (note! 'spawned)
        (scheduler-drain! s)
        (test-equal "a coroutine spawned runs at the next drain, not where it was spawned"
          '(spawned ran (end returned v)) (seen))))

    (let*-values (((note! seen) (recorder))
                  ((s) #f)
                  ((poll! modes)
                   (scripted (list (list (lambda ()
                                           (note! (list 'callback (scheduler-phase)))
                                           (scheduler-spawn! s
                                             (lambda ()
                                               (note! (list 'ran (scheduler-phase)
                                                            (coroutine? (current-coroutine))))
                                               'v)
                                             (ender note!))
                                           (note! 'spawned)))))))
      (set! s (make-scheduler poll!))
      (turns! s 4)
      (test-equal "a coroutine a callback spawns runs at the next turn's drain, once the poll is over"
        '((callback in-uv-run) spawned (ran scheduling #t) (end returned v)) (seen)))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s (lambda () 'v)
                          (lambda (kind v)
                            (note! (list kind v (current-coroutine) (scheduler-phase)))))
        (scheduler-drain! s)
        (test-equal "a coroutine's value comes to its end procedure from the scheduler, on no coroutine"
          '((returned v #f scheduling)) (seen))))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s (lambda () (raise 'boom)) (lambda (kind v) (note! (list kind v))))
        (scheduler-spawn! s (lambda () (note! 'next) 'w) (ender note!))
        (test-equal "a coroutine that raises: the raise comes to its end procedure, and the drain runs on"
          '(returned ((raised boom) next (end returned w)))
          (let ((r (refusal (lambda () (scheduler-drain! s) 'drained))))
            (list (car r) (seen))))))

    (let*-values (((note! seen) (recorder))
                  ((parked) #f)
                  ((poll! modes)
                   (scripted (list (list (lambda ()
                                           (note! 'callback)
                                           (coroutine-wake! parked 'answer)))))))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (set! parked (current-coroutine))
            (note! 'parks)
            (let ((v (coroutine-park!)))
              (note! (list 'resumed v (scheduler-phase)))
              'done))
          (ender note!))
        (turns! s 4)
        (test-equal "a coroutine parks, a callback wakes it, and it resumes at the next drain with what it was given"
          '(parks callback (resumed answer scheduling) (end returned done)) (seen))))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (note! 'a)
            (scheduler-spawn! s (lambda () (note! 'c)) (lambda (kind v) #f))
            (scheduler-call! s (lambda () (note! 'p))))
          (lambda (kind v) #f))
        (scheduler-spawn! s (lambda () (note! 'b)) (lambda (kind v) #f))
        (scheduler-drain! s)
        (test-equal "a drain runs what is ready, then what was made ready while it ran, in that order"
          '((a b c p) #f) (list (seen) (scheduler-ready? s)))))

    (let*-values (((note! seen) (recorder))
                  ((poll! modes) (scripted (list (list (lambda () (note! 'callback)))
                                                 (list (lambda () (note! 'second-callback)))))))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (note! 'yields)
            (coroutine-yield!)
            (note! 'after-yield))
          (lambda (kind v) #f))
        (turns! s 4)
        (test-equal "a coroutine that yields runs again once the poll is over; the poll is 'nowait while it waits, 'once when nothing is ready"
          '((yields callback after-yield second-callback) (nowait once))
          (list (seen) (modes)))))

    (let*-values (((note! seen) (recorder))
                  ((s) #f)
                  ((poll! modes)
                   (scripted (list (list (lambda () (note! (refusal (lambda () (coroutine-park!))))))
                                   (list (lambda () (note! (refusal (lambda () (scheduler-drain! s))))))))))
      (set! s (make-scheduler poll!))
      (turns! s 4)
      (test-equal "R1: a callback that parks, and a drain inside a callback, are refused as R1"
        '((refused r1) (refused r1)) (seen)))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-call! s (lambda () (note! (refusal (lambda () (coroutine-park!))))))
        (scheduler-drain! s)
        (note! (refusal (lambda () (coroutine-park!))))
        (test-equal "R2: a park on no coroutine, in a call the drain makes and outside any turn, is refused as R2"
          '((refused r2) (refused r2)) (seen))))

    (let*-values (((note! seen) (recorder))
                  ((parked) #f)
                  ((s) #f)
                  ((poll! modes)
                   (scripted (list (list (lambda () (coroutine-wake! parked 41)))
                                   (list (lambda ()
                                           (scheduler-spawn! s (lambda () (note! 'later) 'l)
                                                             (ender note!))))
                                   (list (lambda () (note! 'last-callback)))))))
      (set! s (make-scheduler poll!))
      (scheduler-spawn! s
        (lambda ()
          (set! parked (current-coroutine))
          (+ 1 (coroutine-park!)))
        (ender note!))
      (let ((taken (refusal (lambda () (turns! s 8)))))
        (test-equal "R3: a coroutine that parks, is woken and ends, ends through the scheduler, and the turns after it run on"
          '((returned 3) ((end returned 42) later (end returned l) last-callback))
          (list taken (seen)))))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (let ((before (scheduler-feed-begin!)))
              (let ((refused (refusal (lambda () (coroutine-park!)))))
                (scheduler-feed-end! before)
                (note! refused)))
            (note! (scheduler-phase)))
          (lambda (kind v) (note! (list 'end kind))))
        (scheduler-drain! s)
        (test-equal "R5: a park inside a feed is refused as R5, and the phase is the drain's once the feed is over"
          '((refused r5) scheduling (end returned)) (seen))))

    (let*-values (((note! seen) (recorder))
                  ((poll! modes)
                   (scripted (list (list (lambda ()
                                           (let ((before (scheduler-feed-begin!)))
                                             (note! (scheduler-phase))
                                             (scheduler-feed-end! before))
                                           (note! (scheduler-phase))))))))
      (let ((s (make-scheduler poll!)))
        (turns! s 4)
        (test-equal "a feed inside a callback is 'in-parser, and 'in-uv-run once it is over"
          '(in-parser in-uv-run) (seen))))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let ((s (make-scheduler poll!)))
        (scheduler-call! s (lambda () (note! (list (current-coroutine) (scheduler-phase)))))
        (scheduler-drain! s)
        (test-equal "a call is made in the drain, on no coroutine"
          '((#f scheduling)) (seen))))

    (let-values (((note! seen) (recorder))
                 ((poll! modes) (scripted '())))
      (let* ((s (make-scheduler poll!))
             (ready (scheduler-spawn! s (lambda () 'v) (lambda (kind v) #f)))
             (parked #f))
        (note! (refusal (lambda () (coroutine-wake! ready 1))))
        (scheduler-spawn! s
          (lambda () (set! parked (current-coroutine)) (coroutine-park!))
          (lambda (kind v) #f))
        (scheduler-drain! s)
        (coroutine-wake! parked 1)
        (note! (refusal (lambda () (coroutine-wake! parked 2))))
        (scheduler-drain! s)
        (note! (refusal (lambda () (coroutine-wake! ready 3))))
        (test-equal "waking a coroutine that is not parked, ready, woken already or ended, is an assertion violation"
          '(assertion assertion assertion) (seen))))

    (let ((s (make-scheduler (lambda (mode) #f))))
      (let ((idle (scheduler-turn! s)))
        (scheduler-spawn! s (lambda () (coroutine-yield!)) (lambda (kind v) #f))
        (let* ((yielded (scheduler-turn! s))
               (after (scheduler-turn! s))
               (busy (scheduler-turn! (make-scheduler (lambda (mode) #t)))))
          (test-equal "a turn answers the poll's answer, or #t while something is ready"
            '(#f #t #f #t) (list idle yielded after busy)))))

    (let*-values (((note! seen) (recorder))
                  ((parked) #f)
                  ((poll! modes) (scripted (list (list (lambda () (coroutine-wake! parked 'go)))))))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (set! parked (current-coroutine))
            (guard (e ((symbol? e) (note! (list 'caught e)) 'recovered))
              (coroutine-park!)
              (raise 'after-park)))
          (ender note!))
        (turns! s 4)
        (test-equal "a guard inside a coroutine catches a raise after a park"
          '((caught after-park) (end returned recovered)) (seen))))

    (let*-values (((note! seen) (recorder))
                  ((p) (make-parameter 'outer))
                  ((parked) #f)
                  ((poll! modes) (scripted (list (list (lambda ()
                                                         (note! (list 'callback (p)))
                                                         (coroutine-wake! parked 'go)))))))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (set! parked (current-coroutine))
            (parameterize ((p 'mine))
              (coroutine-park!)
              (note! (list 'resumed (p)))))
          (lambda (kind v) #f))
        (scheduler-spawn! s (lambda () (note! (list 'other (p)))) (lambda (kind v) #f))
        (turns! s 4)
        (test-equal "what a coroutine parameterizes stays its own across a park"
          '((other outer) (callback outer) (resumed mine)) (seen))))))
