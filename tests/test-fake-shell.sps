#!r6rs
;;; (test-fake-shell) — the fake shell records faithfully, queues in order, and
;;; takes its clock by injection.  M1.4.  Driven against stub steps, so these
;;; checks hold whatever core it carries; conn-step runs in it in
;;; test-connection-table.sps, and the whole message loop in
;;; test-message-loop.sps (M2.4).
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

    ;; M2.4: actions run after the outermost dispatch, from one queue (design
    ;; §4.5).  Performing (call b) dispatches b; b's action must wait behind
    ;; the (note 1) already queued, never run in a drain nested inside this one.
    (let ((s (make-fake-shell call-step 'st 0
                              (lambda (sh action)
                                (when (eq? (car action) 'call)
                                  (fake-shell-deliver! sh (cadr action)))))))
      (fake-shell-deliver! s 'a)
      (test-equal "a dispatch made while draining queues its actions behind the rest"
                  '((call b) (note 1) (note 2)) (fake-shell-actions s))
      (test-equal "both events were dispatched, in order" '(a b) (fake-shell-events s))
      (test-equal "every action ran from the outermost drain" '() (fake-shell-violations s)))))
