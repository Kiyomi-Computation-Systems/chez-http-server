#!r6rs
;;; (http-server server): `server-step`, the listener's pure step.  M4.3.
;;;
;;; The listener has a connection's shape (decision 0002 item 5): an event in,
;;; the actions for the shell to perform out, the state linear.  M4.3 fixes
;;; the vocabulary (design §4.6, and `listener-failed`, decided 2026-09-26)
;;; and the rows a listener needs before M8's drain:
;;;   - a connection that arrives is accepted while fewer than max-connections
;;;     are open, the count the shell hands in, and refused once that many are;
;;;   - a refusal episode is logged twice at most: its first refusal, then how
;;;     many were refused, when a connection is next accepted or the server
;;;     shuts down (decided 2026-09-26);
;;;   - a shutdown, or a listener that fails, stops listening, and what arrives
;;;     after is refused;
;;;   - a tick and a close ask for nothing yet: M5 brings the timer, M8 the drain;
;;;   - every event in the vocabulary is one the step takes, and no row asks
;;;     for an action outside it.
;;;
;;; Oracles: design §4.6's vocabulary; decision 0005's max-connections,
;;; 10 000, "refuse in on-connection"; the owner's decisions of 2026-09-26
;;; (ledger, M4.3); the counts each row starts from.
(import (rnrs) (srfi :64) (testing) (http-server server) (http-server limits))

;; capped : Nat -> Limits — the defaults, with at most `n` connections open.
(define (capped n) (limits-with default-limits (list (cons 'max-connections n))))

;; after : Phase Nat Limits Event -> (List Phase Nat (Listof Action))
;; One step from a server in `phase` with `refused` refusals in its episode:
;; the phase and refusals it leaves, and the actions it asks for.
(define (after phase refused limits event)
  (let-values (((s actions) (server-step (make-server-state phase refused limits) event)))
    (list (server-phase s) (server-refused s) actions)))

;; A row: what it shows, the state it starts from (phase, refusals, limits),
;; the event, and what the step leaves (phase, refusals, actions).
(define-record-type row (fields name phase refused limits event expected))

(define refusing '(log refusing max-connections))

(define rows
  (list
   (make-row "an arrival with fewer open than the cap is accepted"
             'listening 0 (capped 2) '(connection-arrived 0) '(listening 0 ((accept))))
   (make-row "so is one that takes the last place"
             'listening 0 (capped 2) '(connection-arrived 1) '(listening 0 ((accept))))
   (make-row "an arrival with the cap open is refused, and the first refusal logged"
             'listening 0 (capped 2) '(connection-arrived 2)
             (list 'listening 1 (list '(refuse) refusing)))
   (make-row "a refusal after the first is counted, not logged"
             'listening 1 (capped 2) '(connection-arrived 2) '(listening 2 ((refuse))))
   (make-row "the cap is the limits': by default 10 000 open are refused"
             'listening 0 default-limits '(connection-arrived 10000)
             (list 'listening 1 (list '(refuse) refusing)))
   (make-row "and 9 999 open are not"
             'listening 0 default-limits '(connection-arrived 9999) '(listening 0 ((accept))))
   (make-row "an arrival once a place is free is accepted, and the refusals logged with their count"
             'listening 3 (capped 2) '(connection-arrived 1)
             '(listening 0 ((accept) (log refused max-connections 3))))
   (make-row "a shutdown stops listening"
             'listening 0 (capped 5) '(shutdown-requested) '(draining 0 ((close-listener))))
   (make-row "a shutdown during refusals logs their count"
             'listening 4 (capped 5) '(shutdown-requested)
             '(draining 0 ((close-listener) (log refused max-connections 4))))
   (make-row "a second shutdown asks for nothing"
             'draining 0 (capped 5) '(shutdown-requested) '(draining 0 ()))
   (make-row "an arrival while draining is refused, and not logged"
             'draining 0 (capped 5) '(connection-arrived 1) '(draining 0 ((refuse))))
   (make-row "a listener that fails shuts the server down, logged"
             'listening 0 (capped 5) '(listener-failed EMFILE)
             '(draining 0 ((close-listener) (log listener-failed EMFILE))))
   (make-row "and logs the count of refusals under way"
             'listening 2 (capped 5) '(listener-failed EMFILE)
             '(draining 0 ((close-listener) (log listener-failed EMFILE)
                           (log refused max-connections 2))))
   (make-row "a listener failure while draining asks for nothing"
             'draining 0 (capped 5) '(listener-failed EMFILE) '(draining 0 ()))
   (make-row "a tick asks for nothing yet, listening"
             'listening 0 (capped 5) '(tick 1000) '(listening 0 ()))
   (make-row "or draining"
             'draining 0 (capped 5) '(tick 1000) '(draining 0 ()))
   (make-row "a close asks for nothing yet, listening"
             'listening 0 (capped 5) '(connection-closed 0) '(listening 0 ()))
   (make-row "or draining"
             'draining 0 (capped 5) '(connection-closed 0) '(draining 0 ()))))

;; answers : Limits (Listof Event) -> (Listof (Listof Action))
;; The actions each event is answered with, in turn, from a listening server
;; with no refusals, threading the state as a caller does.
(define (answers limits events)
  (let loop ((s (make-server-state 'listening 0 limits)) (events events) (acc '()))
    (if (null? events)
        (reverse acc)
        (let-values (((s actions) (server-step s (car events))))
          (loop s (cdr events) (cons actions acc))))))

;; outcome : (-> Any) -> Symbol — 'assertion-violation if `thunk` raises one.
(define (outcome thunk)
  (guard (e ((assertion-violation? e) 'assertion-violation))
    (thunk)
    'no-violation))

;; One event of each kind, in the vocabulary's order.
(define samples
  '((connection-arrived 0) (shutdown-requested) (listener-failed EMFILE) (tick 1000)
    (connection-closed 0)))

(run-suite "server"
  (lambda ()
    ;; --- the vocabulary (design §4.6, and listener-failed) ---
    (test-equal "the events are design §4.6's four and listener-failed"
                '(connection-arrived shutdown-requested listener-failed tick connection-closed)
                server-events)
    (test-equal "the actions are design §4.6's five"
                '(accept refuse close-listener force-close-all log) server-actions)
    (test-equal "a server listens, then drains" '(listening draining) server-phases)
    (test-equal "the samples name every event, in order" server-events (map car samples))
    (test-equal "every event is one the step takes, listening or draining"
                (map (lambda (e) 'taken) (append samples samples))
                (map (lambda (e phase)
                       (if (eq? (outcome (lambda () (after phase 0 (capped 5) e))) 'no-violation)
                           'taken
                           (list 'violation phase e)))
                     (append samples samples)
                     (append (map (lambda (e) 'listening) samples)
                             (map (lambda (e) 'draining) samples))))

    ;; --- the rows ---
    (for-each (lambda (r)
                (test-equal (row-name r) (row-expected r)
                            (after (row-phase r) (row-refused r) (row-limits r) (row-event r))))
              rows)
    (test-equal "no row asks for an action outside the vocabulary" '()
                (filter (lambda (a) (not (memq (car a) server-actions)))
                        (apply append
                               (map (lambda (r)
                                      (caddr (after (row-phase r) (row-refused r)
                                                    (row-limits r) (row-event r))))
                                    rows))))
    (test-equal "an episode at a cap of one: accepted; refused, logged; refused; accepted, counted"
                (list '((accept)) (list '(refuse) refusing) '((refuse))
                      '((accept) (log refused max-connections 2)))
                (answers (capped 1) '((connection-arrived 0) (connection-arrived 1)
                                      (connection-arrived 1) (connection-arrived 0))))
    (test-eq "the step answers with the state it was given, updated" 'same
             (let ((s (make-server-state 'listening 0 (capped 1))))
               (let-values (((s2 actions) (server-step s '(connection-arrived 1))))
                 (if (and (eq? s s2) (= (server-refused s) 1)) 'same (list 'other s2)))))

    ;; --- what cannot happen ---
    (test-equal "an event outside the vocabulary, or an arrival without a count, is a caller bug"
                '(assertion-violation assertion-violation assertion-violation assertion-violation)
                (map (lambda (event)
                       (outcome (lambda () (after 'listening 0 (capped 2) event))))
                     '((connection-reset) closed (connection-arrived) (connection-arrived -1))))
    (test-equal "a state in no phase, with negative refusals, no limits, or no cap is refused"
                '(assertion-violation assertion-violation assertion-violation assertion-violation)
                (list (outcome (lambda () (make-server-state 'stopped 0 (capped 2))))
                      (outcome (lambda () (make-server-state 'listening -1 (capped 2))))
                      (outcome (lambda () (make-server-state 'listening 0 10000)))
                      (outcome (lambda () (make-server-state 'listening 0
                                                             (limits-with default-limits
                                                                          '((max-connections . #f))))))))))
