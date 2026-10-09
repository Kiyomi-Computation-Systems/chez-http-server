#!r6rs
;;; (http-server private scheduler): coroutines, and the turn of two levels,
;;; the drain then the poll.  M7.1's first step; a park by a full
;;; continuation, which lands once, decision 0025's.
;;;
;;; Oracles: design §5.2 and §5.3's invariants, decision 0003 item 2,
;;; decision 0014, and decision 0025.  `poll!` is the scheduler's one
;;; injection point (design §5.3), so no check loads libuv: each scheduler
;;; polls a script, which records the mode it was asked to poll in and runs
;;; the next batch of callbacks, as `uv-run` runs the callbacks that landed,
;;; answering whether more batches remain.  Every run of turns is capped by
;;; a count, never by the clock (global-constraints).
;;;
;;; The checks, R3's first.  A coroutine that returns normally, R3 broken,
;;; returns into the drain that first entered it, which runs again from
;;; there, and the drains after it break: that drain's continuation is a
;;; full one (decision 0025), where Chez refused a return into a one-shot
;;; one.  Since M7.2's handler for a coroutine's raise, that comes at the
;;; first coroutine that raises, or parks and ends, so R3's row runs before
;;; any other (the M7 exit):
;;;   - R3: a coroutine that parks, is woken and ends, ends through the
;;;     scheduler: its end once, and the turns after it run on;
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
;;;   - R5: a park inside a feed is refused as R5, and the phase is the one
;;;     before the feed once it is over;
;;;   - a call is made in the drain, on no coroutine;
;;;   - waking a coroutine that is not parked is an assertion violation;
;;;   - a turn answers the poll's answer, or #t while something is ready;
;;;   - a guard inside a coroutine catches a raise after a park, and what a
;;;     coroutine parameterizes stays its own across a park;
;;;   - a park's or a yield's continuation entered a second time is refused:
;;;     the coroutine whose turn it is ends by an assertion naming the verb,
;;;     and the code after the park runs once (decision 0025: a one-shot
;;;     continuation refused it, and a full one lands as often as it is
;;;     entered); so inside a guard that catches everything, which never
;;;     sees the refusal; and entered from another coroutine while its own
;;;     waits on a newer park, the one that entered it ends, and the one
;;;     parked stays parked, its newer park landing when it is woken;
;;;   - a coroutine that ends, by its value or by a raise, allocates no stack
;;;     of its own (M7.2's first step: a `guard` around the thunk gave each
;;;     one a stack);
;;;   - a coroutine that parks once, is woken and ends allocates under half
;;;     of what a one-shot continuation held at the same depth allocates
;;;     (decision 0025's review: on a one-shot continuation the drain
;;;     entered, its park cost a fresh stack segment);
;;;   - a coroutine parked keeps on the heap under half of what a one-shot
;;;     continuation held at the same depth keeps (decision 0025: parked by
;;;     a one-shot continuation, it kept that stack segment).
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) make-parameter parameterize statistics sstats-bytes call/1cc)
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

;; ended : Symbol Any -> (Listof Any)
;; A coroutine's end, or a raise, as a check reads it: `(returned v)`, or
;; `(raised assertion who)` for an assertion naming who, `(raised
;; assertion)` for one naming no one, `(raised other)` for anything else.
(define (ended kind v)
  (cond ((not (eq? kind 'raised)) (list kind v))
        ((not (assertion-violation? v)) '(raised other))
        ((who-condition? v) (list 'raised 'assertion (condition-who v)))
        (else '(raised assertion))))

;; entered-twice : Symbol -> (Listof Any)
;; A coroutine that parks, for 'park, or yields, for 'yield, inside a
;; dynamic-wind whose before thunk, as the coroutine is resumed, captures the
;; continuation it runs in; once landed, the coroutine calls that
;; continuation, which enters the park again.  What it noted: `(landed n)`
;; at each landing, then its end, as `ended` reads it.
(define (entered-twice how)
  (let* ((seen '()) (again #f) (armed #f) (landings 0)
         (note! (lambda (x) (set! seen (cons x seen))))
         (s (make-scheduler (lambda (mode) #f)))
         (c (scheduler-spawn! s
              (lambda ()
                (dynamic-wind
                 (lambda () (when armed (call/cc (lambda (k) (set! again k)))))
                 (lambda ()
                   (if (eq? how 'park) (coroutine-park!) (coroutine-yield!))
                   (set! landings (+ landings 1))
                   (note! (list 'landed landings))
                   (let ((k again))
                     (when k (set! again #f) (k #f)))
                   landings)
                 (lambda () #f)))
              (lambda (kind v) (note! (ended kind v))))))
    (scheduler-drain! s)
    (set! armed #t)
    (when (eq? how 'park) (coroutine-wake! c 'go))
    (scheduler-drain! s)
    (reverse seen)))

;; entered-guarded : -> (Listof Any)
;; entered-twice's park inside a guard that catches anything, noting
;; `(caught . what)`, as `ended` reads it; the code after the guard notes
;; `(after-guard n)`, then calls the continuation once, which enters the
;; park again.  What it noted, then its end.
(define (entered-guarded)
  (let* ((seen '()) (again #f) (armed #f) (landings 0)
         (note! (lambda (x) (set! seen (cons x seen))))
         (s (make-scheduler (lambda (mode) #f)))
         (c (scheduler-spawn! s
              (lambda ()
                (dynamic-wind
                 (lambda () (when armed (call/cc (lambda (k) (set! again k)))))
                 (lambda ()
                   (guard (e (#t (note! (cons 'caught (ended 'raised e)))))
                     (coroutine-park!))
                   (set! landings (+ landings 1))
                   (note! (list 'after-guard landings))
                   (let ((k again))
                     (when k (set! again #f) (k #f)))
                   landings)
                 (lambda () #f)))
              (lambda (kind v) (note! (ended kind v))))))
    (scheduler-drain! s)
    (set! armed #t)
    (coroutine-wake! c 'go)
    (scheduler-drain! s)
    (reverse seen)))

;; entered-from-another : -> (Listof Any)
;; Coroutine A parks inside a dynamic-wind whose before thunk, as A is first
;; resumed, captures the continuation it runs in; A then parks again.
;; While A waits on that second park, coroutine B calls the continuation,
;; entering A's first park again; then A is woken.  What was noted: `(a
;; after-1st)` and `(a after-2nd)` after A's parks, each coroutine's end as
;; `(a . end)` or `(b . end)`, as `ended` reads it, and a raise out of A's
;; wake as `(wake . raise)`.
(define (entered-from-another)
  (let* ((seen '()) (again #f) (armed #f)
         (note! (lambda (x) (set! seen (cons x seen))))
         (s (make-scheduler (lambda (mode) #f)))
         (a (scheduler-spawn! s
              (lambda ()
                (dynamic-wind
                 (lambda () (when (and armed (not again)) (call/cc (lambda (k) (set! again k)))))
                 (lambda ()
                   (coroutine-park!)
                   (note! '(a after-1st))
                   (coroutine-park!)
                   (note! '(a after-2nd))
                   'a-done)
                 (lambda () #f)))
              (lambda (kind v) (note! (cons 'a (ended kind v)))))))
    (scheduler-drain! s)
    (set! armed #t)
    (coroutine-wake! a 'go)
    (scheduler-drain! s)
    (scheduler-spawn! s (lambda () (again #f) 'b-done) (lambda (kind v) (note! (cons 'b (ended kind v)))))
    (scheduler-drain! s)
    (guard (e (#t (note! (cons 'wake (ended 'raised e)))))
      (coroutine-wake! a 'go)
      (scheduler-drain! s))
    (reverse seen)))

;; deep : Nat (-> Any) -> Any — `thunk`'s value, called `d` calls deep, each
;; call's frame kept by what it does after.
(define sink (make-vector 1 #f))
(define (deep d thunk)
  (if (= d 0)
      (thunk)
      (let ((v (deep (- d 1) thunk)))
        (vector-set! sink 0 v)
        v)))

;; parked-held : Nat Nat -> Nat
;; What each of `n` coroutines parked `d` calls deep keeps on the heap, all
;; parked at once: the heap before and after, and the coroutines kept.
(define (parked-held n d)
  (let* ((s (make-scheduler (lambda (mode) #f)))
         (before (heap))
         (kept (let loop ((i 0) (kept '()))
                 (if (= i n)
                     kept
                     (loop (+ i 1)
                           (cons (scheduler-spawn! s (lambda () (deep d coroutine-park!))
                                                   (lambda (kind v) #f))
                                 kept))))))
    (scheduler-drain! s)
    (let ((after (heap)))
      (div (- after before) (length kept)))))

;; one-shot-held : Nat Nat -> Nat
;; What each of `n` one-shot continuations keeps on the heap, each captured
;; `d` calls deep and left by an escape, never called: a park as the
;; scheduler made one before decision 0025, with no scheduler.
(define (one-shot-held n d)
  (let* ((before (heap))
         (kept (let loop ((i 0) (kept '()))
                 (if (= i n)
                     kept
                     (loop (+ i 1)
                           (call/1cc
                            (lambda (out)
                              (deep d (lambda ()
                                        (call/1cc (lambda (k) (out (cons k kept))))))))))))
         (after (heap)))
    (div (- after before) (length kept))))

;; one-shot-allocates : Nat Nat -> Nat
;; What each of `n` one-shot continuations allocates, each captured `d`
;; calls deep and left by an escape, never called, all kept, after a
;; warm-up of the same: one-shot-held's continuations, by the counter.
(define (one-shot-allocates n d)
  (define (run!)
    (let loop ((i 0) (kept '()))
      (when (< i n)
        (loop (+ i 1)
              (call/1cc
               (lambda (out)
                 (deep d (lambda ()
                           (call/1cc (lambda (k) (out (cons k kept))))))))))))
  (run!)
  (let ((before (sstats-bytes (statistics))))
    (run!)
    (div (- (sstats-bytes (statistics)) before) n)))

;; waits-once-allocates : Nat Nat -> Nat
;; What each of `n` coroutines allocates, one at a time, each parking once
;; `d` calls deep, woken and drained to its end, after a warm-up of the
;; same.
(define (waits-once-allocates n d)
  (let ((s (make-scheduler (lambda (mode) #f))) (c #f))
    (define (run!)
      (do ((i 0 (+ i 1))) ((= i n))
        (scheduler-spawn! s (lambda () (deep d (lambda () (set! c (current-coroutine)) (coroutine-park!))))
                          (lambda (kind v) #f))
        (scheduler-drain! s)
        (coroutine-wake! c #t)
        (scheduler-drain! s)))
    (run!)
    (let ((before (sstats-bytes (statistics))))
      (run!)
      (div (- (sstats-bytes (statistics)) before) n))))

;; bytes-each : Nat (-> Any) -> Nat
;; The bytes each of `n` coroutines running `thunk` allocates, all spawned
;; and then run by one turn's drain, after a warm-up of the same.
(define (bytes-each n thunk)
  (let-values (((poll! modes) (scripted '())))
    (let ((s (make-scheduler poll!)))
      (define (run!)
        (do ((i 0 (+ i 1))) ((= i n)) (scheduler-spawn! s thunk (lambda (kind v) #f)))
        (scheduler-turn! s))
      (run!)
      (let ((before (sstats-bytes (statistics))))
        (run!)
        (div (- (sstats-bytes (statistics)) before) n)))))

(run-suite "scheduler"
  (lambda ()
    ;; R3's row first: once a coroutine returns normally, no drain after it
    ;; runs (the header).
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

    ;; Its raise is caught by the drain that resumed it, not the one that
    ;; first entered it, whose continuation the park used.
    (let*-values (((note! seen) (recorder))
                  ((parked) #f)
                  ((poll! modes) (scripted (list (list (lambda () (coroutine-wake! parked 'go)))
                                                 (list (lambda () (note! 'later)))))))
      (let ((s (make-scheduler poll!)))
        (scheduler-spawn! s
          (lambda ()
            (set! parked (current-coroutine))
            (coroutine-park!)
            (raise 'after-park))
          (ender note!))
        (test-equal "a coroutine that raises after a park: the raise comes to its end procedure, and the turns after it run on"
          '((returned 2) ((end raised after-park) later))
          (let ((taken (refusal (lambda () (turns! s 8)))))
            (list taken (seen))))))

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
          '((other outer) (callback outer) (resumed mine)) (seen))))

    (test-equal "a park's or a yield's continuation entered a second time is refused, as an assertion naming the verb, and the code after it runs once"
      '(((landed 1) (raised assertion coroutine-park!))
        ((landed 1) (raised assertion coroutine-yield!)))
      (list (entered-twice 'park) (entered-twice 'yield)))

    (test-equal "a park entered a second time inside a guard that catches everything: the guard never sees the refusal, and the code after the guard runs once"
      '((after-guard 1) (raised assertion coroutine-park!))
      (entered-guarded))

    (test-equal "a park entered from another coroutine, while its own waits on a newer park: the one that entered it ends by the refusal, and the one parked stays parked, its newer park landing when it is woken"
      '((a after-1st) (b raised assertion coroutine-park!) (a after-2nd) (a returned a-done))
      (entered-from-another))

    ;; --- what a coroutine allocates --------------------------------------
    ;; A one-shot continuation captured 4 calls deep and left keeps a stack
    ;; segment: 3,516 B each (Darwin arm64), whatever the scheduler does.
    ;; Calibration: the counter sees it.  A coroutine that ends, by its value
    ;; or by a raise, needs no stack of its own, and under 1,024 B it cannot
    ;; have made one.  One that parks once, woken and ended, allocates under
    ;; half of the reference, 4 calls deep: on a one-shot continuation the
    ;; drain entered, its full park cost a fresh segment, 4,256 to 4,257 B;
    ;; on a full one, 1,177 to 1,242 B (decision 0025's review).
    (let ((reference (one-shot-allocates 1000 4)))
      (test-eq "a one-shot continuation captured 4 calls deep and left allocates a stack the counter sees"
               'stacks (if (> reference 2048) 'stacks reference))
      (let ((once (waits-once-allocates 1000 4)))
        (test-equal "a coroutine that parks once 4 calls deep, is woken and ends, one at a time, allocates under half of what a one-shot continuation held 4 calls deep allocates"
          'under-half (if (< (* 2 once) reference) 'under-half (list once reference)))))
    (let ((ended (bytes-each 1000 (lambda () 'done))))
      (test-eq "a coroutine that ends by its value allocates no stack of its own"
               'stackless (if (< ended 1024) 'stackless ended)))
    (let ((raised (bytes-each 1000 (lambda () (raise 'boom)))))
      (test-eq "a coroutine that ends by a raise allocates no stack of its own"
               'stackless (if (< raised 1024) 'stackless raised)))

    ;; --- what a coroutine keeps, parked -----------------------------------
    ;; Decision 0025: parked by a one-shot continuation, a coroutine kept the
    ;; stack segment its park was captured on, 3,691 to 3,692 B 4 calls deep;
    ;; by a full one, it keeps its frames, 802 B, the drain's continuation
    ;; full too (Darwin arm64, and Linux aarch64 and x86_64, alike).  The
    ;; reference is that one-shot park with no scheduler, a one-shot
    ;; continuation captured 4 calls deep and left by an escape, 3,419 to
    ;; 3,420 B on all three.  Should it keep under 2 KiB, the counter no
    ;; longer sees a segment, and the suite stops as a provenance failure.
    (parked-held 100 4)
    (one-shot-held 100 4)
    (let* ((reference (one-shot-held 1000 4))
           (parked (parked-held 1000 4)))
      (when (< reference 2048)
        (provenance-failure
         (string-append "a one-shot continuation held 4 calls deep no longer keeps a stack segment here: "
                        (number->string reference) " B each")))
      (test-equal "a coroutine parked 4 calls deep keeps on the heap under half of what a one-shot continuation held 4 calls deep keeps, 1,000 of each, footprints back to back"
        'under-half (if (< (* 2 parked) reference) 'under-half (list parked reference))))))
