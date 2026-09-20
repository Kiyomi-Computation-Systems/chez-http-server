#!r6rs
;;; (fake-shell) — the imperative shell as a test double.
;;;
;;; M1.4.  The real shell (design §5) delivers libuv events to the pure core and
;;; runs the actions it returns.  There is no core to drive yet (`conn-step` is
;;; M2), so this fake shell is driven against a STUB step the test supplies, and
;;; it proves only what does not depend on connection semantics:
;;;
;;;   - it delivers scripted events IN ORDER and threads the step's state;
;;;   - it RECORDS every action the step returns, faithfully and in order;
;;;   - it takes time by INJECTION — a fake clock set and advanced explicitly,
;;;     never a real one, so a `tick` event carries the injected `now` and no
;;;     test ever sleeps (decision 0005, consequences).
;;;
;;; The step is `(step state event) -> (values state' (Listof Action))`, the
;;; shape `conn-step` will have (design §4.1), so M2 drops its real core in
;;; where the stub stands now.
(library (fake-shell)
  (export make-fake-shell fake-shell?
          fake-shell-state fake-shell-now
          fake-shell-actions fake-shell-events
          fake-shell-advance! fake-shell-deliver! fake-shell-tick! fake-shell-run!)
  (import (rnrs))

  (define-record-type fake-shell
    (fields step (mutable state) (mutable now) (mutable actions-rev) (mutable events-rev))
    (protocol (lambda (new)
                (lambda (step state0 now0) (new step state0 now0 '() '())))))

  ;; fake-shell-actions / -events : the recorded actions / delivered events in
  ;; arrival order (the fields hold them reversed, appended to as they arrive).
  (define (fake-shell-actions s) (reverse (fake-shell-actions-rev s)))
  (define (fake-shell-events s) (reverse (fake-shell-events-rev s)))

  ;; fake-shell-advance! : the clock is injected and only ever moves forward.
  (define (fake-shell-advance! s dt)
    (when (< dt 0)
      (assertion-violation 'fake-shell-advance! "the fake clock never runs backwards" dt))
    (fake-shell-now-set! s (+ (fake-shell-now s) dt))
    (fake-shell-now s))

  ;; fake-shell-deliver! : one event through the step; thread state, record the
  ;; event and each returned action in order.  Returns this event's actions.
  (define (fake-shell-deliver! s event)
    (call-with-values
     (lambda () ((fake-shell-step s) (fake-shell-state s) event))
     (lambda (state* actions)
       (fake-shell-state-set! s state*)
       (fake-shell-events-rev-set! s (cons event (fake-shell-events-rev s)))
       (fake-shell-actions-rev-set!
        s (fold-left (lambda (acc a) (cons a acc)) (fake-shell-actions-rev s) actions))
       actions)))

  ;; fake-shell-tick! : deliver a `(tick . now)` event carrying the injected now.
  (define (fake-shell-tick! s) (fake-shell-deliver! s (cons 'tick (fake-shell-now s))))

  ;; fake-shell-run! : deliver a list of events in order.
  (define (fake-shell-run! s events)
    (for-each (lambda (e) (fake-shell-deliver! s e)) events)))
