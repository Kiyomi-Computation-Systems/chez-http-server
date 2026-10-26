#!r6rs
;;; (test-fake-shell) — the fake shell records faithfully, queues in order, and
;;; takes its clock by injection.  Its trace sees events and actions in the
;;; order it handles them, as the libuv shell's does.  Its dispatch cap is
;;; each event's, never a shell's whole life's.  Driven against stub
;;; steps, so these checks hold whatever core it carries; conn-step runs in it
;;; in test-connection-table.sps, and the whole message loop in
;;; test-message-loop.sps.
(import (rnrs) (srfi :64) (testing) (fake-shell))

;; echo-step : count deliveries; each event's action echoes the event.
(define (echo-step st ev) (values (+ st 1) (list ev)))
;; two-step : two actions per event, to witness intra-event order.
(define (two-step st ev) (values st (list (cons 'x ev) (cons 'y ev))))
;; silent-step : no actions; state accumulates the events (reversed).
(define (silent-step st ev) (values (cons ev st) '()))
;; call-step : a's actions call b, then note 1; b's action notes 2.
(define (call-step st ev)
  (values st (case ev ((a) '((call b) (note 1))) ((b) '((note 2))) (else '()))))
;; shut-step : `shut` asks for the half-close, `write` for a write, and
;; `write-then-note` for a write with a note queued behind it.
(define (shut-step st ev)
  (values st (case ev
               ((shut) '((shutdown)))
               ((write) '((write () 0)))
               ((write-then-note) '((write () 0) (note abandoned)))
               (else '()))))

(run-suite "fake-shell"
  (lambda ()
    ;; delivers in order, threads state, records each action in order
    (let ((s (make-fake-shell echo-step 0 0)))
      (fake-shell-run! s '(a b c))
      (test-eqv   "state threaded through three events" 3 (fake-shell-state s))
      (test-equal "events delivered in order" '(a b c) (fake-shell-events s))
      (test-equal "actions recorded in order" '(a b c) (fake-shell-actions s)))

    ;; a step's multiple actions keep order, within and across deliveries
    (let ((s (make-fake-shell two-step 'st 0)))
      (fake-shell-deliver! s 'p)
      (fake-shell-deliver! s 'q)
      (test-equal "multi-action steps record in order"
                  '((x . p) (y . p) (x . q) (y . q)) (fake-shell-actions s)))

    ;; a step that returns no actions records none, yet still threads and queues
    (let ((s (make-fake-shell silent-step '() 0)))
      (fake-shell-run! s '(a b))
      (test-equal "no actions when the step returns none" '() (fake-shell-actions s))
      (test-equal "events still recorded in order" '(a b) (fake-shell-events s))
      (test-equal "state still threaded" '(b a) (fake-shell-state s)))

    ;; the clock is injected: a tick carries the current now, advance moves it
    (let ((s (make-fake-shell echo-step 0 0)))
      (fake-shell-tick! s)
      (test-eqv "advance! returns the new now" 250 (fake-shell-advance! s 250))
      (fake-shell-tick! s)
      (test-eqv "advance! returns the new now again" 260 (fake-shell-advance! s 10))
      (test-equal "ticks carry the injected clock, in order"
                  '((tick 0) (tick 250)) (fake-shell-events s))
      (test-eqv "now reflects the injected advances" 260 (fake-shell-now s)))

    ;; the injected clock never runs backwards
    (let ((s (make-fake-shell echo-step 0 100)))
      (test-eq "advance! refuses a negative step" 'refused
               (guard (e (#t 'refused)) (fake-shell-advance! s -1) 'accepted)))

    ;; a fake connection's timer is its wheel's; a stub step's shell keeps
    ;; none, so firing it is refused, where its tick is delivered.
    (let ((s (make-fake-shell echo-step 0 0)))
      (test-equal "a stub step's shell keeps no timer: firing it is refused, and nothing is delivered"
                  '(refused ())
                  (list (guard (e ((assertion-violation? e) 'refused)) (fake-shell-fire! s) 'fired)
                        (fake-shell-events s))))

    ;; actions run after the outermost dispatch, from one queue.  Performing
    ;; (call b) dispatches b; b's action must wait behind the (note 1) already
    ;; queued, never run in a drain nested inside this one.
    (let ((s (make-fake-shell call-step 'st 0
                              (lambda (sh action)
                                (when (eq? (car action) 'call)
                                  (fake-shell-deliver! sh (cadr action)))))))
      (fake-shell-deliver! s 'a)
      (test-equal "a dispatch made while draining queues its actions behind the rest"
                  '((call b) (note 1) (note 2)) (fake-shell-actions s))
      (test-equal "both events were dispatched, in order" '(a b) (fake-shell-events s))
      (test-equal "every action ran from the outermost drain" '() (fake-shell-violations s)))

    ;; a trace sees what the shell does in the order it does it, as the libuv
    ;; shell's trace does (the contract test compares the two): each event as
    ;; it is dispatched, and each action as it runs, before it is performed.
    ;; So b, dispatched while (call b) is performed, comes after (call b) and
    ;; before (note 1).
    (let* ((seen '())
           (s (make-fake-shell call-step 'st 0
                               (lambda (sh action)
                                 (when (eq? (car action) 'call)
                                   (fake-shell-deliver! sh (cadr action))))
                               (lambda (kind datum) (set! seen (cons (list kind datum) seen))))))
      (fake-shell-deliver! s 'a)
      (test-equal "a trace sees each event as it is dispatched, and each action before it is performed"
                  '((event a) (action (call b)) (event b) (action (note 1)) (action (note 2)))
                  (reverse seen)))

    ;; the core shuts the write side once its last write has completed, so a
    ;; write after the shutdown is the core's bug, refused where it happens.
    ;; The raise abandons the dispatch it came from: the note queued behind
    ;; the write never runs, and the shell dispatches the next event as it
    ;; would have.
    (let ((s (make-fake-shell shut-step 'st 0)))
      (fake-shell-deliver! s 'write)
      (fake-shell-deliver! s 'shut)
      (test-eq "a write after the shutdown is refused" 'refused
               (guard (e ((assertion-violation? e) 'refused))
                 (fake-shell-deliver! s 'write-then-note)
                 'accepted))
      (fake-shell-deliver! s 'shut)
      (test-equal "the refused dispatch is abandoned, and the next one runs"
                  '((write () 0) (shutdown) (shutdown)) (fake-shell-actions s))
      (test-equal "and from the outermost drain" '() (fake-shell-violations s)))

    ;; the dispatch cap, 100,000, is each event's: an event that leads to
    ;; dispatch after dispatch is stopped there, but a shell's life may hold
    ;; any number of events, after a raise too.
    (let ((s (make-fake-shell (lambda (st ev) (values st (list (list 'call ev)))) 'st 0
                              (lambda (sh action) (fake-shell-deliver! sh (cadr action))))))
      (test-eq "an event whose every action dispatches another is stopped at the cap" 'stuck
               (guard (e ((assertion-violation? e) 'stuck))
                 (fake-shell-deliver! s 'again)
                 'finished)))
    (let ((s (make-fake-shell (lambda (st ev) (values (+ st 1) '())) 0 0)))
      (test-equal "100,001 events, each its own, are no harness error" '(delivered 100001)
                  (list (guard (e ((assertion-violation? e) 'stuck))
                          (let loop ((n 0)) (when (< n 100001) (fake-shell-deliver! s 'e) (loop (+ n 1))))
                          'delivered)
                        (fake-shell-state s))))
    (let ((s (make-fake-shell shut-step 'st 0)))
      (fake-shell-deliver! s 'shut)
      (guard (e ((assertion-violation? e) 'refused)) (fake-shell-deliver! s 'write))
      (test-eq "and after an event that raised, the next one's count begins again" 'delivered
               (guard (e ((assertion-violation? e) 'stuck))
                 (let loop ((n 0)) (when (< n 100001) (fake-shell-deliver! s 'none) (loop (+ n 1))))
                 'delivered)))))
