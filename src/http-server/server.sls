#!r6rs
;;; (http-server server) — the listener's pure step, and the drain.
;;;
;;; `server-step` is to the listener what `conn-step` is to a connection: the
;;; shell turns what happens to the listener into EVENTS, and the step answers
;;; with ACTIONS for the shell to perform.  Pure by the same contract: a step
;;; allocates nothing but Scheme data, calls no libuv procedure, reads no
;;; clock, and never raises on a well-formed event.  An event outside the
;;; vocabulary, or one without the time or the count it carries, is a caller
;;; bug and an assertion violation.  The state is linear, as a connection's
;;; is: updated in place and returned.
;;;
;;;   events   (connection-arrived open)  (shutdown-requested now open)
;;;            (listener-failed errno now open)  (tick now)
;;;            (connection-closed open)
;;;   actions  (accept)  (refuse)  (close-listener)  (finish-all)
;;;            (force-close-all)  (log what . details)
;;;
;;; `open` is the count of connections the shell holds, its table's size: the
;;; step keeps no count of its own, so none can drift.  `now` is the loop's
;;; time, in milliseconds, as a connection's tick carries it: the step reads
;;; no clock.
;;;
;;; A CONNECTION THAT ARRIVES IS ALWAYS ANSWERED FIRST, `accept` or `refuse`,
;;; in the shell's on-connection callback.  libuv has already taken it off the
;;; socket and stops watching the listener until it is accepted, so nothing is
;;; left waiting: an accepted connection is served, and a refused one closed
;;; at once, as nginx closes one its worker_connections cannot hold.  One is
;;; accepted while fewer than the limits' max-connections are open, and
;;; refused once that many are.  A refusal episode is logged twice at most:
;;; `(log refusing max-connections)` at its first refusal, and
;;; `(log refused max-connections n)`, n its refusals, when a connection is
;;; next accepted or the server stops listening.  So a flood of connections
;;; writes two lines, not one a connection.
;;;
;;; A SHUTDOWN STOPS LISTENING, `close-listener`, and the server DRAINS: what
;;; arrives after is refused, unlogged, and the connections open are told to
;;; finish, `finish-all`, the drain logged as `(log draining open)`.  Its
;;; deadline is the time the shutdown was asked at plus the limits'
;;; drain-timeout-ms: the first tick at or after it asks for every connection
;;; still open to be closed at once, `force-close-all`, logged as
;;; `(log drain-timeout)`, and no tick after asks again.  The drain ends when
;;; the shell says its last connection has closed, `(connection-closed 0)`, or
;;; at once if none was open: the server has STOPPED, logged as
;;; `(log stopped)`.  A LISTENER THAT FAILS does the same, logged first as
;;; `(log listener-failed errno)`, so the process ends once its connections
;;; have, and whatever supervises it starts it again: a listener that has
;;; stopped would otherwise leave a server that runs and never accepts.  A
;;; second shutdown, or a failure while draining, asks for nothing.
(library (http-server server)
  (export server-phases server-events server-actions
          make-server-state server-state? server-phase server-refused server-limits
          server-deadline
          server-step)
  (import (rnrs) (http-server limits))

  ;; server-phases : (Listof Symbol)
  ;; `listening`, accepting connections; `draining`, after a shutdown or a
  ;; failed listener, refusing them while those open finish; `stopped`, once
  ;; none is left.
  (define server-phases '(listening draining stopped))

  ;; server-events : (Listof Symbol)
  ;; The closed set of event kinds `server-step` accepts.
  (define server-events
    '(connection-arrived shutdown-requested listener-failed tick connection-closed))

  ;; server-actions : (Listof Symbol)
  ;; The closed set of action kinds `server-step` answers with; `finish-all`
  ;; tells the connections open to finish.
  (define server-actions '(accept refuse close-listener finish-all force-close-all log))

  ;; make-server-state : Phase Nat Limits (U Nat #f) -> ServerState
  ;;   Phase    = one of server-phases (anything else is an assertion violation)
  ;;   Nat      = the refusals in the episode under way, 0 when none is
  ;;   Limits   = the policy the step enforces: max-connections, an exact
  ;;              integer of at least 1, and drain-timeout-ms
  ;;              (anything else is an assertion violation)
  ;;   deadline = the loop's time a drain closes what is still open at, or #f
  ;;              when no drain waits for one: before a shutdown, and once
  ;;              its connections have been closed (anything else is an
  ;;              assertion violation)
  ;; server-state? : Any -> Boolean
  ;; server-phase : ServerState -> Phase
  ;; server-refused : ServerState -> Nat
  ;; server-limits : ServerState -> Limits
  ;; server-deadline : ServerState -> (U Nat #f)
  (define-record-type (server-state make-server-state server-state?)
    (fields (mutable phase server-phase server-phase-set!)
            (mutable refused server-refused server-refused-set!)
            (immutable limits server-limits)
            (mutable deadline server-deadline server-deadline-set!))
    (protocol
     (lambda (new)
       (lambda (phase refused limits deadline)
         (unless (memq phase server-phases)
           (assertion-violation 'make-server-state "not a server phase" phase))
         (unless (and (fixnum? refused) (fx>=? refused 0))
           (assertion-violation 'make-server-state "not a count of refusals" refused))
         (unless (and (limits? limits)
                      (let ((cap (limits-max-connections limits)))
                        (and (integer? cap) (exact? cap) (>= cap 1))))
           (assertion-violation 'make-server-state
             "not a limits record with a connection cap of at least 1" limits))
         (unless (or (not deadline) (instant? deadline))
           (assertion-violation 'make-server-state "not the loop's time" deadline))
         (new phase refused limits deadline)))))

  ;; instant? : Any -> Boolean — the loop's time: an exact integer, at least 0.
  (define (instant? x) (and (integer? x) (exact? x) (>= x 0)))

  ;; count? : Any -> Boolean — a count of connections.
  (define (count? x) (and (fixnum? x) (fx>=? x 0)))

  ;; server-step : ServerState Event -> (values ServerState (Listof Action))
  ;; One event in, the state it leaves (the same object, updated) and the
  ;; actions to perform, in order.
  (define (server-step s ev)
    (case (and (pair? ev) (car ev))
      ((connection-arrived) (on-arrived s (car (shaped ev (list count?)))))
      ((shutdown-requested)
       (let ((f (shaped ev (list instant? count?))))
         (stop-listening s '((close-listener)) (car f) (cadr f))))
      ((listener-failed)
       (let ((f (shaped ev (list any? instant? count?))))
         (stop-listening s (list '(close-listener) (list 'log 'listener-failed (car f)))
                         (cadr f) (caddr f))))
      ((tick) (on-tick s (car (shaped ev (list instant?)))))
      ((connection-closed) (on-closed s (car (shaped ev (list count?)))))
      (else (assertion-violation 'server-step "not a server event" ev))))

  ;; shaped : Event (Listof (Any -> Boolean)) -> (Listof Any)
  ;; The event's fields, one for each check and each meeting it, in order:
  ;; an errno is any datum, a time an instant, a count a count.  An event of
  ;; any other shape is an assertion violation.
  (define (shaped ev checks)
    (let ((f (cdr ev)))
      (unless (and (list? f) (= (length f) (length checks)) (for-all (lambda (ok? x) (ok? x)) checks f))
        (assertion-violation 'server-step "an event without the time or the count it carries" ev))
      f))

  ;; any? : Any -> Boolean — any datum at all, as an errno is.
  (define (any? x) #t)

  ;; listening, connection-arrived: accept below the cap, and end a refusal
  ;; episode; refuse at it, logging an episode's first.
  ;; draining or stopped, connection-arrived: refuse.
  (define (on-arrived s open)
    (cond ((not (eq? (server-phase s) 'listening)) (values s '((refuse))))
          ((< open (limits-max-connections (server-limits s)))
           (values s (cons '(accept) (end-episode! s))))
          ((fxzero? (server-refused s))
           (server-refused-set! s 1)
           (values s '((refuse) (log refusing max-connections))))
          (else
           (server-refused-set! s (fx+ (server-refused s) 1))
           (values s '((refuse))))))

  ;; listening, shutdown-requested or listener-failed -> draining: `actions`,
  ;; a refusal episode's count, the drain logged with the `open` connections
  ;; it waits for, and those told to finish, its deadline `now` plus the
  ;; limits' drain timeout; with none open, stopped at once.  Otherwise
  ;; nothing.
  (define (stop-listening s actions now open)
    (case (server-phase s)
      ((listening)
       (let ((head (append actions (end-episode! s) (list (list 'log 'draining open)))))
         (cond ((fxzero? open)
                (server-phase-set! s 'stopped)
                (values s (append head '((log stopped)))))
               (else
                (server-phase-set! s 'draining)
                (server-deadline-set! s (+ now (limits-drain-timeout-ms (server-limits s))))
                (values s (append head '((finish-all))))))))
      (else (values s '()))))

  ;; draining, tick at or past the deadline: close every connection still
  ;; open, logged, once.  Otherwise nothing.
  (define (on-tick s now)
    (let ((deadline (server-deadline s)))
      (cond ((and (eq? (server-phase s) 'draining) deadline (>= now deadline))
             (server-deadline-set! s #f)
             (values s '((force-close-all) (log drain-timeout))))
            (else (values s '())))))

  ;; draining, connection-closed with none left open -> stopped, logged.
  ;; Otherwise nothing.
  (define (on-closed s open)
    (cond ((and (eq? (server-phase s) 'draining) (fxzero? open))
           (server-phase-set! s 'stopped)
           (server-deadline-set! s #f)
           (values s '((log stopped))))
          (else (values s '()))))

  ;; end-episode! : ServerState -> (Listof Action)
  ;; The log of a refusal episode's count, if one is under way, which ends it.
  (define (end-episode! s)
    (let ((n (server-refused s)))
      (if (fxzero? n)
          '()
          (begin (server-refused-set! s 0)
                 (list (list 'log 'refused 'max-connections n)))))))
