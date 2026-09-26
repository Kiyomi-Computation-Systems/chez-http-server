#!r6rs
;;; (http-server server) — the listener's pure step (design §4.6; M4.3).
;;;
;;; `server-step` is to the listener what `conn-step` is to a connection
;;; (decision 0002 item 5): the shell turns what happens to the listener into
;;; EVENTS, and the step answers with ACTIONS for the shell to perform.  Pure
;;; by the same contract: a step allocates nothing but Scheme data, calls no
;;; libuv procedure, reads no clock, and never raises on a well-formed event.
;;; An event outside the vocabulary, or an arrival without a count, is a
;;; caller bug and an assertion violation.  The state is linear, as a
;;; connection's is: updated in place and returned.
;;;
;;;   events   (connection-arrived open)  (shutdown-requested)
;;;            (listener-failed errno)  (tick now)  (connection-closed open)
;;;   actions  (accept)  (refuse)  (close-listener)  (force-close-all)
;;;            (log what . details)
;;;
;;; `open` is the count of connections the shell holds, its table's size: the
;;; step keeps no count of its own (decided 2026-09-26), so none can drift.
;;;
;;; A CONNECTION THAT ARRIVES IS ALWAYS ANSWERED FIRST, `accept` or `refuse`
;;; (decision 0005: "refuse in on-connection").  libuv has already taken it
;;; off the socket and stops watching the listener until it is accepted, so
;;; nothing is left waiting: an accepted connection is served, and a refused
;;; one closed at once, as nginx closes one its worker_connections cannot
;;; hold.  One is accepted while fewer than the limits' max-connections are
;;; open, and refused once that many are.  A refusal episode is logged twice
;;; at most (decided 2026-09-26): `(log refusing max-connections)` at its
;;; first refusal, and `(log refused max-connections n)`, n its refusals,
;;; when a connection is next accepted or the server stops listening.  So a
;;; flood of connections writes two lines, not one a connection.
;;;
;;; A SHUTDOWN STOPS LISTENING, `close-listener`, and the server drains: what
;;; arrives after is refused, unlogged.  A LISTENER THAT FAILS does the same,
;;; logged as `(log listener-failed errno)` (decided 2026-09-26), so the
;;; process ends once its connections have, and whatever supervises it starts
;;; it again: a listener that has stopped would otherwise leave a server that
;;; runs and never accepts.  M8 writes the rest of the drain (design §4.6):
;;; the connections told to finish, `force-close-all` at the drain-timeout
;;; deadline, which a tick will carry, and the drain's end, which a close will.
;;; Until then a tick and a close ask for nothing.
(library (http-server server)
  (export server-phases server-events server-actions
          make-server-state server-state? server-phase server-refused server-limits
          server-step)
  (import (rnrs) (http-server limits))

  ;; server-phases : (Listof Symbol)
  ;; `listening`, accepting connections; `draining`, after a shutdown or a
  ;; failed listener, refusing them.
  (define server-phases '(listening draining))

  ;; server-events : (Listof Symbol)
  ;; Design §4.6's four event kinds and `listener-failed`: the closed set
  ;; `server-step` accepts.
  (define server-events
    '(connection-arrived shutdown-requested listener-failed tick connection-closed))

  ;; server-actions : (Listof Symbol) — design §4.6's five action kinds.
  (define server-actions '(accept refuse close-listener force-close-all log))

  ;; make-server-state : Phase Nat Limits -> ServerState
  ;;   Phase  = one of server-phases (anything else is an assertion violation)
  ;;   Nat    = the refusals in the episode under way, 0 when none is
  ;;   Limits = the policy the step enforces: max-connections (decision 0005),
  ;;            an exact integer of at least 1 (anything else is an assertion
  ;;            violation)
  ;; server-state? : Any -> Boolean
  ;; server-phase : ServerState -> Phase
  ;; server-refused : ServerState -> Nat
  ;; server-limits : ServerState -> Limits
  (define-record-type (server-state make-server-state server-state?)
    (fields (mutable phase server-phase server-phase-set!)
            (mutable refused server-refused server-refused-set!)
            (immutable limits server-limits))
    (protocol
     (lambda (new)
       (lambda (phase refused limits)
         (unless (memq phase server-phases)
           (assertion-violation 'make-server-state "not a server phase" phase))
         (unless (and (fixnum? refused) (fx>=? refused 0))
           (assertion-violation 'make-server-state "not a count of refusals" refused))
         (unless (and (limits? limits)
                      (let ((cap (limits-max-connections limits)))
                        (and (integer? cap) (exact? cap) (>= cap 1))))
           (assertion-violation 'make-server-state
             "not a limits record with a connection cap of at least 1" limits))
         (new phase refused limits)))))

  ;; server-step : ServerState Event -> (values ServerState (Listof Action))
  ;; One event in, the state it leaves (the same object, updated) and the
  ;; actions to perform, in order.
  (define (server-step s ev)
    (case (and (pair? ev) (car ev))
      ((connection-arrived) (on-arrived s ev))
      ((shutdown-requested) (stop-listening s '((close-listener))))
      ((listener-failed)
       (stop-listening s (list '(close-listener) (list 'log 'listener-failed (cadr ev)))))
      ((tick connection-closed) (values s '()))
      (else (assertion-violation 'server-step "not a server event" ev))))

  ;; listening, connection-arrived: accept below the cap, and end a refusal
  ;; episode; refuse at it, logging an episode's first.
  ;; draining, connection-arrived: refuse.
  (define (on-arrived s ev)
    (let ((open (and (pair? (cdr ev)) (cadr ev))))
      (unless (and (fixnum? open) (fx>=? open 0))
        (assertion-violation 'server-step "an arrival without the count of connections open" ev))
      (cond ((eq? (server-phase s) 'draining) (values s '((refuse))))
            ((< open (limits-max-connections (server-limits s)))
             (values s (cons '(accept) (end-episode! s))))
            ((fxzero? (server-refused s))
             (server-refused-set! s 1)
             (values s '((refuse) (log refusing max-connections))))
            (else
             (server-refused-set! s (fx+ (server-refused s) 1))
             (values s '((refuse)))))))

  ;; listening, shutdown-requested or listener-failed -> draining: `actions`,
  ;; and a refusal episode's count.  draining: nothing.
  (define (stop-listening s actions)
    (case (server-phase s)
      ((listening)
       (server-phase-set! s 'draining)
       (values s (append actions (end-episode! s))))
      (else (values s '()))))

  ;; end-episode! : ServerState -> (Listof Action)
  ;; The log of a refusal episode's count, if one is under way, which ends it.
  (define (end-episode! s)
    (let ((n (server-refused s)))
      (if (fxzero? n)
          '()
          (begin (server-refused-set! s 0)
                 (list (list 'log 'refused 'max-connections n)))))))
