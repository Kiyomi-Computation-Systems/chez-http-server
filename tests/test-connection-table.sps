#!r6rs
;;; (http-server connection): the vocabulary, and design §4.4's transition
;;; table as data.  M2.1.
;;;
;;; The table below is the specification and conn-step is what has to agree
;;; with it (design §8.3).  Every row is driven from a SYNTHETIC state by one
;;; synthetic event, with no parser, so the rows are independent: a mutation
;;; that breaks one row turns that row red and no other.
;;;
;;; Oracles: the nine states of design §4.3; the fifteen events and fifteen
;;; actions of decision 0002 item 2, plus the `hand-off` action decision 0006
;;; item 3 adds; the 10 + 9 rows of design §4.4's two tables; the three
;;; rows of decision 0004's pause protocol that the design's tables fold into
;;; H6 and H10 (M2.4); and the two rows of the upgrade door, decided on the
;;; owner's word on 2026-09-25 (M2.5).
;;;
;;; A parser-result event carries its error as the error's code and node,
;;; (code . node), because the status of one code splits by node (design
;;; §6.3); the node names in the rows are the ones chez-httparse reports at
;;; the pin for the same failure.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server limits) (fake-shell)
        (only (httparse decisions) F-UPGRADE F-CONNECTION-UPGRADE))

(define (b s) (string->utf8 s))

;; Any delivery will do: in M2.1 the core never reads the bytes it is handed.
(define bv (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(define req (make-request 'GET (b "/") 1 1 '() #f))
(define resp (make-response 200 #f '() (b "row H7")))

;; state : Symbol . Plist -> ConnState
;; A synthetic state: the phase, plus any of deadline / close-after /
;; outstanding / pending / request / target / host; every field not named
;; takes its default, and the limits are decision 0005's defaults.  The head
;; is the core's own, so a target (a string) is read into it the way the
;; parser delivers one, on-url-data then on-url-complete, and a host (a
;; string) likewise, as a Host header line.
(define (state phase . plist)
  (define (get key default)
    (let loop ((p plist))
      (cond ((null? p) default)
            ((eq? (car p) key) (cadr p))
            (else (loop (cddr p))))))
  (let ((s (make-conn-state phase
                            (get 'deadline #f) (get 'close-after #f) (get 'outstanding 0)
                            (get 'pending #f) (get 'request #f) default-limits))
        (target (get 'target #f))
        (host (get 'host #f)))
    (when target
      (let ((tbv (b target)))
        (let*-values (((s1 a1) (conn-parser-step s 'on-url-data tbv 0 (bytevector-length tbv)))
                      ((s2 a2) (conn-parser-step s 'on-url-complete)))
          #t)))
    (when host
      (let ((line (b (string-append "Host: " host))))
        (let*-values (((s1 a1) (conn-parser-step s 'on-header-field-data line 0 4))
                      ((s2 a2) (conn-parser-step s 'on-header-field-complete))
                      ((s3 a3) (conn-parser-step s 'on-header-value-data line 6 (bytevector-length line)))
                      ((s4 a4) (conn-parser-step s 'on-header-value-complete)))
          #t)))
    s))

;; render-action : Action -> Datum
;; A written response is a record, and `equal?` compares records by identity,
;; so a response the core builds (408, 500, ...) is rendered field by field.
(define (render-action a)
  (if (and (eq? (car a) 'write) (response? (cadr a)))
      (let ((r (cadr a)))
        (list 'write (list 'response (response-status r) (response-reason r)
                           (response-headers r) (response-body r))))
      a))

;; An originated status as render-action shows it: no reason (M3 derives the
;; phrase), no headers (M3's framing adds Connection: close), no body.
(define (status-write n) `(write (response ,n #f () #f)))

;; Every action kind any row emitted, for the vocabulary check at the end.
(define emitted '())

;; outcome : ConnState Event -> (List Phase CloseAfter (Listof Datum))
;; One step: the state it leaves, whether it closes after the response, and
;; the actions in order.
(define (outcome s ev)
  (call-with-values
   (lambda () (conn-step s ev))
   (lambda (s* actions)
     (set! emitted (append (map car actions) emitted))
     (list (conn-phase s*) (conn-close-after s*) (map render-action actions)))))

;; A row is the design's wording and its instances; an instance is a synthetic
;; state, one event, and the expected outcome.  "any" and "head/body" rows get
;; one instance per state they name.
(define (row id text . instances) (list id text instances))
(define (row-id r) (car r))
(define (row-text r) (cadr r))
(define (row-instances r) (caddr r))
(define (i st ev expected) (list st ev expected))

;; ---------------------------------------------------------------------------
;; Design §4.4, the happy path: ten rows.  The tables are procedures so their
;; synthetic states are built inside the suite, where a raise is a harness
;; error (status 2) rather than a crash before any test runs.
(define (happy-path)
  (list
   (row 'H1 "idle, bytes-arrived -> idle: feed-parser"
        (i (state 'idle 'deadline 'idle) `(bytes-arrived ,bv 0 5)
           `(idle #f ((feed-parser ,bv 0 5)))))

   (row 'H2 "idle, on-message-begin -> head: continue, disarm, arm header"
        (i (state 'idle 'deadline 'idle) '(parser-event on-message-begin)
           '(head #f ((reply-parser continue) (disarm-deadline) (arm-deadline header)))))

   (row 'H3 "head, on-header-* -> head: continue"
        (i (state 'head 'deadline 'header) `(parser-event on-header-field-data ,bv 16 20)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) '(parser-event on-header-field-complete)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) `(parser-event on-header-value-data ,bv 22 23)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) '(parser-event on-header-value-complete)
           '(head #f ((reply-parser continue)))))

   ;; on-headers-complete carries the six parser fields read inside it
   ;; (0002 item 4): here llhttp's method 1 (GET), HTTP/1.1, no flags, no
   ;; content-length, and an `upgrade` of 0.  The head holds a target, as
   ;; every parsed one does, since the target is judged here (M2.3), and a
   ;; Host, as every HTTP/1.1 one must (RFC 9112 §3.2, 2026-09-25).
   (row 'H4 "head, on-headers-complete -> body: continue, disarm, arm body"
        (i (state 'head 'deadline 'header 'target "/" 'host "x")
           '(parser-event on-headers-complete 1 1 1 0 0 0)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   (row 'H5 "body, on-body-data -> body: continue, deliver-body, arm body"
        (i (state 'body 'deadline 'body) `(parser-event on-body-data ,bv 3 8)
           `(body #f ((reply-parser continue) (deliver-body ,bv 3 8) (arm-deadline body)))))

   (row 'H6 "body, on-message-complete -> handling: pause, read-stop, disarm, call-handler"
        (i (state 'body 'deadline 'body 'request req) '(parser-event on-message-complete)
           `(handling #f ((reply-parser pause) (read-stop) (disarm-deadline) (call-handler ,req)))))

   (row 'H7 "handling, handler-responded -> responding: write, arm write"
        (i (state 'handling) `(handler-responded ,resp)
           `(responding #f (,(render-action (list 'write resp)) (arm-deadline write)))))

   (row 'H8 "responding, write-completed with more outstanding -> responding: arm write"
        (i (state 'responding 'deadline 'write 'outstanding 2) '(write-completed 100)
           '(responding #f ((arm-deadline write)))))

   (row 'H9 "responding, last write-completed, keep-alive -> idle: resume, feed pending, read-start, arm idle"
        (i (state 'responding 'deadline 'write 'outstanding 1 'pending (list bv 10 20))
           '(write-completed 100)
           `(idle #f ((resume-parser) (feed-parser ,bv 10 20) (read-start) (arm-deadline idle)))))

   ;; The pending remainder is dropped, not fed: after a close-marked message
   ;; the core stops feeding (decision 0004 item 4).
   (row 'H10 "responding, last write-completed, close-after -> closing: close"
        (i (state 'responding 'deadline 'write 'outstanding 1 'close-after 'not-keep-alive
                  'pending (list bv 10 20))
           '(write-completed 100)
           '(closing not-keep-alive ((close not-keep-alive)))))))

;; ---------------------------------------------------------------------------
;; Design §4.4, termination and error: nine rows.
(define (termination)
  (list
   (row 'T1 "any reading state, eof -> closing: close"
        (i (state 'idle 'deadline 'idle) '(eof) '(closing #f ((close eof))))
        (i (state 'head 'deadline 'header) '(eof) '(closing #f ((close eof))))
        (i (state 'body 'deadline 'body) '(eof) '(closing #f ((close eof)))))

   (row 'T2 "any live state, read-error -> closing: log, close, no response"
        (i (state 'idle 'deadline 'idle) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (close read-error))))
        (i (state 'head 'deadline 'header) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (close read-error))))
        (i (state 'body 'deadline 'body) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (close read-error))))
        (i (state 'handling) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (close read-error))))
        (i (state 'responding 'deadline 'write 'outstanding 1) '(read-error EPIPE)
           '(closing #f ((log read-error EPIPE) (close read-error))))
        (i (state 'draining) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (close read-error)))))

   ;; The status is design §6.5's for the error: 400, except the one
   ;; invalid-transfer-encoding node that is a 501 (RFC 9112 §6.1).
   (row 'T3 "head/body, parser-result status=error -> responding: write the status, close-after"
        (i (state 'head 'deadline 'header) '(parser-result error 0 0 (invalid-method . e-bad-method-open) #f)
           `(responding parser-error (,(status-write 400))))
        (i (state 'body 'deadline 'body) '(parser-result error 47 47 (invalid-chunk-size . e-bad-chunk-size) #f)
           `(responding parser-error (,(status-write 400))))
        (i (state 'body 'deadline 'body)
           '(parser-result error 49 49 (invalid-transfer-encoding . e-request-invalid-te) #f)
           `(responding parser-error (,(status-write 501))))
        (i (state 'body 'deadline 'body)
           '(parser-result error 44 44 (invalid-transfer-encoding . e-bad-te-value) #f)
           `(responding parser-error (,(status-write 400)))))

   ;; Deadlines are kinds, not instants: the shell's wheel ticks a connection
   ;; only once the deadline it armed has passed (decision 0005), so "past the
   ;; header deadline" is a tick while the header deadline is armed.  The
   ;; second instance is the guard: a tick with nothing armed changes nothing.
   (row 'T4 "head, tick past the header deadline -> responding: write 408, close-after"
        (i (state 'head 'deadline 'header) '(tick 60000)
           `(responding header-timeout (,(status-write 408))))
        (i (state 'head) '(tick 60000)
           '(head #f ())))

   (row 'T5 "idle, tick past the idle deadline -> closing: close, no response"
        (i (state 'idle 'deadline 'idle) '(tick 75000)
           '(closing #f ((close idle-timeout))))
        (i (state 'idle) '(tick 75000)
           '(idle #f ())))

   (row 'T6 "handling, handler-failed -> responding: write 500, close-after"
        (i (state 'handling) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500)))))

   ;; The pause channel.  In v1 the core's own flow never reaches this row:
   ;; it pauses the parser at every message's end, and serves an upgrade and
   ;; closes after it (U1), so the parser never runs on to its hand-off.  It
   ;; is the door M8 opens for a handler that takes upgrades (decision 0006's
   ;; amendment of 2026-09-25).  The error channel is U2's.
   (row 'T7 "head/body, parser-result hands off -> handed-off: read-stop, the hand-off hook"
        (i (state 'head 'deadline 'header 'request req) '(parser-result paused 55 55 #f paused-upgrade)
           `(handed-off #f ((read-stop) (hand-off ,req))))
        (i (state 'body 'deadline 'body 'request req) '(parser-result paused 63 63 #f paused-upgrade)
           `(handed-off #f ((read-stop) (hand-off ,req)))))

   ;; Instantiated on idle only: with nothing in flight "finish in flight" is
   ;; vacuous.  The table has no row whose source is draining, so the in-flight
   ;; states have nothing to finish through yet; that is M8's.
   (row 'T8 "any, shutdown-requested -> draining: finish in flight, then shutdown"
        (i (state 'idle 'deadline 'idle) '(shutdown-requested)
           '(draining #f ((shutdown)))))

   (row 'T9 "closing, closed -> closed"
        (i (state 'closing) '(closed)
           '(closed #f ())))))

;; ---------------------------------------------------------------------------
;; Decision 0004's pause protocol: three rows (M2.4).  Design §4.4 folds the
;; first into H6, "retain pending-input", but the core cannot keep the
;; remainder at on-message-complete: the parser says where it stopped,
;; `parser-result-next`, only when the feed has returned.  So the result that
;; follows the pause keeps the rest of the delivery the core fed, and these
;; rows' outcomes show what is kept.

;; paused : Nat Nat CloseAfter -> ConnState
;; A connection that fed the parser the delivery bv[from, to) and was paused
;; by its own answer to on-message-complete: in handling, its result to come.
(define (paused from to close-after)
  (let ((s (state 'body 'deadline 'body 'request req 'close-after close-after)))
    (conn-step s `(bytes-arrived ,bv ,from ,to))
    (conn-step s '(parser-event on-message-complete))
    s))

;; kept : ConnState Event -> (List Phase CloseAfter (Listof Datum) Pending)
;; One step's outcome, and the pending input the state holds after it.
(define (kept s ev)
  (let* ((o (outcome s ev)) (pending (conn-pending s)))
    (append o (list pending))))

;; ---------------------------------------------------------------------------
;; The upgrade door: two rows (M2.5, decided on the owner's word, 2026-09-25).
;; An upgrade (the parser's `upgrade` field, llhttp's rule: CONNECT, or
;; `Connection: upgrade` with `Upgrade`) is served like any request and
;; closes the connection after the response, so the bytes after it are never
;; read (decision 0006's amendment).  The HTTP/2 preface, a hand-off on the
;; parser's error channel, is answered 505 (0006 item 2).
(define upgrade-flags (bitwise-ior F-UPGRADE F-CONNECTION-UPGRADE))

(define (upgrade-door)
  (list
   ;; on-headers-complete's fields: llhttp's method (5 CONNECT, 1 GET), the
   ;; version, the flags, the content-length and the parser's `upgrade`
   ;; (chez-httparse v0.4.1, #47).  The field decides, whatever the method and
   ;; flags say, and a message that closes the connection anyway keeps its
   ;; own reason.
   (row 'U1 "head, on-headers-complete of an upgrade -> body: served, close-after upgrade"
        (i (state 'head 'deadline 'header 'target "example.com:443" 'host "example.com:443")
           '(parser-event on-headers-complete 5 1 1 0 0 1)
           '(body upgrade ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat" 'host "x")
           `(parser-event on-headers-complete 1 1 1 ,upgrade-flags 0 1)
           '(body upgrade ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat")
           `(parser-event on-headers-complete 1 1 0 ,upgrade-flags 0 1)
           '(body not-keep-alive ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat" 'host "x")
           `(parser-event on-headers-complete 1 1 1 ,upgrade-flags 0 0)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "example.com:443" 'host "example.com:443")
           '(parser-event on-headers-complete 5 1 1 0 0 0)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   (row 'U2 "head, parser-result hands off on the error channel (the HTTP/2 preface) -> responding 505, close-after"
        (i (state 'head 'deadline 'header) '(parser-result error 24 24 (paused-h2-upgrade . e-pri-upgrade) #f)
           `(responding http2-preface (,(status-write 505)))))))

(define (pause-protocol)
  (list
   ;; bv[10, 40) was fed and the parser stopped at 28, 18 bytes in: the rest
   ;; of the delivery is what the resume feeds (H9).  A pause at the feed's
   ;; end leaves nothing.
   (row 'P1 "handling, parser-result paused with no reason -> handling: keep the delivery's rest from next"
        (i (paused 10 40 #f) '(parser-result paused 18 28 #f #f)
           `(handling #f () (,bv 28 40)))
        (i (paused 10 28 #f) '(parser-result paused 18 28 #f #f)
           '(handling #f () #f)))

   ;; llhttp's "Data after `Connection: close`".  The pause at every
   ;; message's end means the core never feeds that data, so the error cannot
   ;; fire; if it did, it is not answered.
   (row 'P2 "handling after a close-marked message, parser-result error -> handling: ignored"
        (i (paused 10 40 'not-keep-alive)
           '(parser-result error 1 29 (closed-connection . e-data-after-close) #f)
           '(handling not-keep-alive () #f)))

   ;; The states a close-marked message passes through after its pause.
   (row 'P3 "after a close-marked message, bytes-arrived -> no feed-parser"
        (i (state 'handling 'close-after 'not-keep-alive) `(bytes-arrived ,bv 0 5)
           '(handling not-keep-alive () #f))
        (i (state 'responding 'deadline 'write 'outstanding 1 'close-after 'not-keep-alive)
           `(bytes-arrived ,bv 0 5)
           '(responding not-keep-alive () #f))
        (i (state 'closing 'close-after 'not-keep-alive) `(bytes-arrived ,bv 0 5)
           '(closing not-keep-alive () #f)))))

;; run-row : Row [(ConnState Event -> Datum)] -> (U 0 1)
;; Run every instance of a row through `step` (default: outcome); 1 if the
;; row has a test, 0 if it has none.
(define run-row
  (case-lambda
    ((r) (run-row r outcome))
    ((r step)
     (for-each (lambda (inst)
                 (test-equal (string-append (symbol->string (row-id r)) " " (row-text r))
                             (caddr inst)
                             (step (car inst) (cadr inst))))
               (row-instances r))
     (if (null? (row-instances r)) 0 1))))

;; One well-formed event of every kind, for the closed-set checks.
(define samples
  (list `(bytes-arrived ,bv 0 4) '(eof) '(read-error ECONNRESET) '(write-completed 10)
        '(shutdown-completed) '(closed) '(tick 0) '(parser-event on-message-begin)
        '(parser-result need-input 4 4 #f #f) `(handler-responded ,resp)
        `(handler-body-chunk ,bv 0 4) '(handler-body-end) '(handler-failed boom)
        '(body-credit 1) '(shutdown-requested)))

;; verdict : (-> Any) -> (U 'accepted 'refused)
;; 'refused if the thunk raises an assertion violation; any other raise
;; escapes, and the suite ends as a harness error.
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (call-with-values thunk (lambda results 'accepted))))

(run-suite "connection-table"
  (lambda ()
    ;; --- the closed sets -------------------------------------------------
    (test-equal "nine states (design §4.3)"
                '(idle head body handling responding draining handed-off closing closed)
                conn-states)
    (test-equal "fifteen events (decision 0002 item 2)"
                '(bytes-arrived eof read-error write-completed shutdown-completed closed
                  tick parser-event parser-result handler-responded handler-body-chunk
                  handler-body-end handler-failed body-credit shutdown-requested)
                conn-events)
    (test-equal "0002's fifteen actions plus 0006 item 3's hand-off"
                '(reply-parser feed-parser resume-parser write read-stop read-start
                  call-handler deliver-body deliver-body-end notify-producer
                  arm-deadline disarm-deadline shutdown close log hand-off)
                conn-actions)

    (test-equal "the samples name every event, in order" conn-events (map car samples))
    (for-each (lambda (ev)
                (test-eq (string-append "a vocabulary event is accepted: "
                                        (symbol->string (car ev)))
                         'accepted
                         (verdict (lambda () (conn-step (state 'idle 'deadline 'idle) ev)))))
              samples)
    (test-eq "an unknown event is an assertion violation" 'refused
             (verdict (lambda () (conn-step (state 'idle) '(no-such-event)))))
    (test-eq "an event that is not a tagged list is an assertion violation" 'refused
             (verdict (lambda () (conn-step (state 'idle) 'eof))))
    (test-eq "a state outside the nine is refused" 'refused
             (verdict (lambda () (state 'no-such-state))))

    ;; --- the table ------------------------------------------------------
    ;; A row with no instance is absent from the count, and the count is the
    ;; design's.
    (let* ((count-rows (lambda (rows)
                         (fold-left (lambda (n r) (+ n (run-row r))) 0 rows)))
           (happy (count-rows (happy-path)))
           (term (count-rows (termination))))
      (test-eqv "design §4.4: all 10 happy-path rows have a test" 10 happy)
      (test-eqv "design §4.4: all 9 termination and error rows have a test" 9 term)
      (test-eqv "decision 0004: all 3 pause-protocol rows have a test" 3
                (fold-left (lambda (n r) (+ n (run-row r kept))) 0 (pause-protocol)))
      (test-eqv "M2.5: both upgrade-door rows have a test" 2 (count-rows (upgrade-door))))

    ;; Every action the table produced is in the vocabulary, and the table
    ;; uses all of it but the two body-streaming actions (M6's).
    (test-equal "no row emits an action outside the vocabulary" '()
                (filter (lambda (k) (not (memq k conn-actions))) emitted))
    (test-equal "the rows use fourteen of the sixteen actions"
                '(reply-parser feed-parser resume-parser write read-stop read-start
                  call-handler deliver-body arm-deadline disarm-deadline shutdown
                  close log hand-off)
                (filter (lambda (k) (memq k emitted)) conn-actions))

    ;; --- conn-step in the fake shell ------------------------------------
    ;; The fake shell's tick is a vocabulary event: (tick now), not (tick . now).
    (let ((s (make-fake-shell conn-step (state 'idle 'deadline 'idle) 0)))
      (fake-shell-advance! s 75000)
      (fake-shell-tick! s)
      (test-equal "the fake shell delivers (tick now)" '((tick 75000)) (fake-shell-events s))
      (test-equal "conn-step runs in the fake shell: the idle deadline closes"
                  '((close idle-timeout)) (fake-shell-actions s))
      (test-eq "the fake shell threads conn-step's state" 'closing
               (conn-phase (fake-shell-state s))))))
