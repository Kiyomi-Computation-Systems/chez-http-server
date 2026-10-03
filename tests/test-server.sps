#!r6rs
;;; (http-server server): `server-step`, the listener's pure step.  M4.3, and
;;; the drain, M8.1.
;;;
;;; The listener has a connection's shape (decision 0002 item 5): an event in,
;;; the actions for the shell to perform out, the state linear.  M4.3 fixes
;;; the vocabulary (design §4.6, and `listener-failed`, decided 2026-09-26)
;;; and the rows a listener needs:
;;;   - a connection that arrives is accepted while fewer than max-connections
;;;     are open, the count the shell hands in, and refused once that many are;
;;;   - a refusal episode is logged twice at most: its first refusal, then how
;;;     many were refused, when a connection is next accepted or the server
;;;     shuts down (decided 2026-09-26);
;;;   - a shutdown, or a listener that fails, stops listening, and what arrives
;;;     after is refused;
;;;   - every event in the vocabulary is one the step takes, and no row asks
;;;     for an action outside it.
;;; M8.1 writes the drain (design §4.6; plan §14), table-tested on a fake
;;; clock, the loop's time each event carries:
;;;   - a shutdown, or a listener that fails, tells the connections open to
;;;     finish, and the drain's deadline is the time it was asked at plus the
;;;     limits' drain timeout;
;;;   - the first tick at or after the deadline asks for every connection
;;;     still open to be closed, once, and never a tick before it;
;;;   - the drain ends when the last connection has closed, or at once if
;;;     none was open, and then the server has stopped;
;;;   - it logs `draining` with the connections it waits for, `drain-timeout`
;;;     at the deadline, and `stopped` at its end (decided 2026-10-03).
;;;
;;; Oracles: design §4.6's vocabulary; decision 0005's max-connections,
;;; 10 000, "refuse in on-connection", and drain-timeout-ms, 10 000,
;;; force-close all; the owner's decisions of 2026-09-26 and 2026-10-03
;;; (ledger, M4.3 and M8.1); the counts and times each row starts from.
(import (rnrs) (srfi :64) (testing) (http-server server) (http-server limits))

;; capped : Nat -> Limits — the defaults, with at most `n` connections open.
(define (capped n) (limits-with default-limits (list (cons 'max-connections n))))

;; drained-in : Nat -> Limits — the defaults, with a drain of `ms`.
(define (drained-in ms) (limits-with default-limits (list (cons 'drain-timeout-ms ms))))

;; after : Phase Nat (U Nat #f) Limits Event -> (List Phase Nat (U Nat #f) (Listof Action))
;; One step from a server in `phase` with `refused` refusals in its episode
;; and the drain's `deadline`: the phase, refusals and deadline it leaves,
;; and the actions it asks for.
(define (after phase refused deadline limits event)
  (let-values (((s actions) (server-step (make-server-state phase refused limits deadline) event)))
    (list (server-phase s) (server-refused s) (server-deadline s) actions)))

;; A row: what it shows, the state it starts from (phase, refusals, deadline,
;; limits), the event, and what the step leaves (phase, refusals, deadline,
;; actions).
(define-record-type row (fields name phase refused deadline limits event expected))

(define refusing '(log refusing max-connections))

(define rows
  (list
   (make-row "an arrival with fewer open than the cap is accepted"
             'listening 0 #f (capped 2) '(connection-arrived 0) '(listening 0 #f ((accept))))
   (make-row "so is one that takes the last place"
             'listening 0 #f (capped 2) '(connection-arrived 1) '(listening 0 #f ((accept))))
   (make-row "an arrival with the cap open is refused, and the first refusal logged"
             'listening 0 #f (capped 2) '(connection-arrived 2)
             (list 'listening 1 #f (list '(refuse) refusing)))
   (make-row "a refusal after the first is counted, not logged"
             'listening 1 #f (capped 2) '(connection-arrived 2) '(listening 2 #f ((refuse))))
   (make-row "the cap is the limits': by default 10 000 open are refused"
             'listening 0 #f default-limits '(connection-arrived 10000)
             (list 'listening 1 #f (list '(refuse) refusing)))
   (make-row "and 9 999 open are not"
             'listening 0 #f default-limits '(connection-arrived 9999) '(listening 0 #f ((accept))))
   (make-row "an arrival once a place is free is accepted, and the refusals logged with their count"
             'listening 3 #f (capped 2) '(connection-arrived 1)
             '(listening 0 #f ((accept) (log refused max-connections 3))))
   (make-row "a shutdown stops listening, tells the connections open to finish, and arms the drain's deadline"
             'listening 0 #f (capped 5) '(shutdown-requested 1000 3)
             '(draining 0 11000 ((close-listener) (log draining 3) (finish-all))))
   (make-row "the deadline is the limits' drain timeout after the shutdown"
             'listening 0 #f (drained-in 250) '(shutdown-requested 1000 1)
             '(draining 0 1250 ((close-listener) (log draining 1) (finish-all))))
   (make-row "a shutdown during refusals logs their count"
             'listening 4 #f (capped 5) '(shutdown-requested 1000 5)
             '(draining 0 11000 ((close-listener) (log refused max-connections 4) (log draining 5)
                                 (finish-all))))
   (make-row "a shutdown with no connection open stops at once"
             'listening 0 #f (capped 5) '(shutdown-requested 1000 0)
             '(stopped 0 #f ((close-listener) (log draining 0) (log stopped))))
   (make-row "a second shutdown asks for nothing"
             'draining 0 11000 (capped 5) '(shutdown-requested 2000 3) '(draining 0 11000 ()))
   (make-row "nor does one once stopped"
             'stopped 0 #f (capped 5) '(shutdown-requested 2000 0) '(stopped 0 #f ()))
   (make-row "an arrival while draining is refused, and not logged"
             'draining 0 11000 (capped 5) '(connection-arrived 1) '(draining 0 11000 ((refuse))))
   (make-row "and once stopped"
             'stopped 0 #f (capped 5) '(connection-arrived 0) '(stopped 0 #f ((refuse))))
   (make-row "a listener that fails shuts the server down, logged, and drains as a shutdown does"
             'listening 0 #f (capped 5) '(listener-failed EMFILE 1000 2)
             '(draining 0 11000 ((close-listener) (log listener-failed EMFILE) (log draining 2)
                                 (finish-all))))
   (make-row "and logs the count of refusals under way"
             'listening 2 #f (capped 5) '(listener-failed EMFILE 1000 5)
             '(draining 0 11000 ((close-listener) (log listener-failed EMFILE)
                                 (log refused max-connections 2) (log draining 5) (finish-all))))
   (make-row "and stops at once with no connection open"
             'listening 0 #f (capped 5) '(listener-failed EMFILE 1000 0)
             '(stopped 0 #f ((close-listener) (log listener-failed EMFILE) (log draining 0)
                             (log stopped))))
   (make-row "a listener failure while draining asks for nothing"
             'draining 0 11000 (capped 5) '(listener-failed EMFILE 2000 3) '(draining 0 11000 ()))
   (make-row "a tick asks for nothing while listening"
             'listening 0 #f (capped 5) '(tick 1000) '(listening 0 #f ()))
   (make-row "nor while draining, before the deadline"
             'draining 0 11000 (capped 5) '(tick 10999) '(draining 0 11000 ()))
   (make-row "the first tick at the deadline closes every connection still open, logged"
             'draining 0 11000 (capped 5) '(tick 11000)
             '(draining 0 #f ((force-close-all) (log drain-timeout))))
   (make-row "and so does the first past it"
             'draining 0 11000 (capped 5) '(tick 11250)
             '(draining 0 #f ((force-close-all) (log drain-timeout))))
   (make-row "a tick once they have been closed asks for nothing"
             'draining 0 #f (capped 5) '(tick 11500) '(draining 0 #f ()))
   (make-row "nor does one once stopped"
             'stopped 0 #f (capped 5) '(tick 11500) '(stopped 0 #f ()))
   (make-row "a close asks for nothing while listening"
             'listening 0 #f (capped 5) '(connection-closed 0) '(listening 0 #f ()))
   (make-row "nor while draining, connections still open"
             'draining 0 11000 (capped 5) '(connection-closed 2) '(draining 0 11000 ()))
   (make-row "the last close ends the drain: stopped, logged"
             'draining 0 11000 (capped 5) '(connection-closed 0) '(stopped 0 #f ((log stopped))))
   (make-row "after the deadline too"
             'draining 0 #f (capped 5) '(connection-closed 0) '(stopped 0 #f ((log stopped))))))

;; answers : Limits (Listof Event) -> (Listof (Listof Action))
;; The actions each event is answered with, in turn, from a listening server
;; with no refusals, threading the state as a caller does.
(define (answers limits events)
  (let loop ((s (make-server-state 'listening 0 limits #f)) (events events) (acc '()))
    (if (null? events)
        (reverse acc)
        (let-values (((s actions) (server-step s (car events))))
          (loop s (cdr events) (cons actions acc))))))

;; outcome : (-> Any) -> Symbol — 'assertion-violation if `thunk` raises one.
(define (outcome thunk)
  (guard (e ((assertion-violation? e) 'assertion-violation))
    (thunk)
    'no-violation))

;; iota : Nat -> (Listof Nat)
(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; One event of each kind, in the vocabulary's order.
(define samples
  '((connection-arrived 0) (shutdown-requested 1000 0) (listener-failed EMFILE 1000 0) (tick 1000)
    (connection-closed 0)))

(run-suite "server"
  (lambda ()
    ;; --- the vocabulary (design §4.6, listener-failed, and finish-all) ---
    (test-equal "the events are design §4.6's four and listener-failed"
                '(connection-arrived shutdown-requested listener-failed tick connection-closed)
                server-events)
    (test-equal "the actions are design §4.6's five and finish-all"
                '(accept refuse close-listener finish-all force-close-all log) server-actions)
    (test-equal "a server listens, drains, then has stopped" '(listening draining stopped)
                server-phases)
    (test-equal "the samples name every event, in order" server-events (map car samples))
    (test-equal "every event is one the step takes, in every phase"
                (map (lambda (e) 'taken) (append samples samples samples))
                (map (lambda (e phase deadline)
                       (if (eq? (outcome (lambda () (after phase 0 deadline (capped 5) e))) 'no-violation)
                           'taken
                           (list 'violation phase e)))
                     (append samples samples samples)
                     (append (map (lambda (e) 'listening) samples)
                             (map (lambda (e) 'draining) samples)
                             (map (lambda (e) 'stopped) samples))
                     (append (map (lambda (e) #f) samples)
                             (map (lambda (e) 11000) samples)
                             (map (lambda (e) #f) samples))))

    ;; --- the rows ---
    (for-each (lambda (r)
                (test-equal (row-name r) (row-expected r)
                            (after (row-phase r) (row-refused r) (row-deadline r)
                                   (row-limits r) (row-event r))))
              rows)
    (test-equal "no row asks for an action outside the vocabulary" '()
                (filter (lambda (a) (not (memq (car a) server-actions)))
                        (apply append
                               (map (lambda (r)
                                      (cadddr (after (row-phase r) (row-refused r) (row-deadline r)
                                                     (row-limits r) (row-event r))))
                                    rows))))
    (test-equal "an episode at a cap of one: accepted; refused, logged; refused; accepted, counted"
                (list '((accept)) (list '(refuse) refusing) '((refuse))
                      '((accept) (log refused max-connections 2)))
                (answers (capped 1) '((connection-arrived 0) (connection-arrived 1)
                                      (connection-arrived 1) (connection-arrived 0))))
    ;; A drain on the fake clock, by default limits: two connections told to
    ;; finish at 0 ms; one closes; the first tick at 10 000 ms closes the
    ;; other, and no tick after asks again; its close ends the drain.
    (test-equal "a drain: told to finish, one closes, the deadline closes the other, and its close ends it"
                '(((close-listener) (log draining 2) (finish-all)) () ()
                  ((force-close-all) (log drain-timeout)) () ((log stopped)))
                (answers default-limits '((shutdown-requested 0 2) (tick 9750) (connection-closed 1)
                                          (tick 10000) (tick 10250) (connection-closed 0))))
    (test-equal "a drain whose connections finish before the deadline is never forced"
                '(((close-listener) (log draining 1) (finish-all)) () ((log stopped)) ())
                (answers default-limits '((shutdown-requested 0 1) (tick 250) (connection-closed 0)
                                          (tick 10000))))
    (test-equal "a drain of 0 ms closes what is open at the first tick, at its own instant"
                '(((close-listener) (log draining 1) (finish-all)) ((force-close-all) (log drain-timeout)))
                (answers (drained-in 0) '((shutdown-requested 500 1) (tick 500))))
    (test-eq "the step answers with the state it was given, updated" 'same
             (let ((s (make-server-state 'listening 0 (capped 1) #f)))
               (let-values (((s2 actions) (server-step s '(connection-arrived 1))))
                 (if (and (eq? s s2) (= (server-refused s) 1)) 'same (list 'other s2)))))

    ;; --- what cannot happen ---
    (test-equal "an event outside the vocabulary, or one without the time or the count it carries, is a caller bug"
                (map (lambda (e) 'assertion-violation) (iota 10))
                (map (lambda (event)
                       (outcome (lambda () (after 'listening 0 #f (capped 2) event))))
                     '((connection-reset) closed (connection-arrived) (connection-arrived -1)
                       (shutdown-requested) (shutdown-requested 1000) (listener-failed EMFILE)
                       (listener-failed EMFILE 1000 -1) (tick) (connection-closed))))
    (test-equal "so is a tick without its time while draining, and a close without its count"
                '(assertion-violation assertion-violation assertion-violation)
                (map (lambda (event)
                       (outcome (lambda () (after 'draining 0 11000 (capped 2) event))))
                     '((tick) (tick -1) (connection-closed x))))
    (test-equal "a state in no phase, with negative refusals, no limits, no cap, or a deadline not a time is refused"
                (map (lambda (e) 'assertion-violation) (iota 5))
                (list (outcome (lambda () (make-server-state 'closed 0 (capped 2) #f)))
                      (outcome (lambda () (make-server-state 'listening -1 (capped 2) #f)))
                      (outcome (lambda () (make-server-state 'listening 0 10000 #f)))
                      (outcome (lambda () (make-server-state 'listening 0
                                                             (limits-with default-limits
                                                                          '((max-connections . #f)))
                                                             #f)))
                      (outcome (lambda () (make-server-state 'draining 0 (capped 2) -1)))))))
