#!r6rs
;;; (http-server connection): the vocabulary, and design §4.4's transition
;;; table as data.  M2.1.
;;;
;;; The table below is the specification and conn-step is what has to agree
;;; with it (design §8.3).  Every row is driven from a SYNTHETIC state by one
;;; synthetic event, with no parser, so the rows are independent: a mutation
;;; that breaks one row turns that row red and no other.
;;;
;;; Oracles: the nine states of design §4.3, and decision 0011's tenth; the fifteen events and fifteen
;;; actions of decision 0002 item 2, plus the `hand-off` action decision 0006
;;; item 3 adds; the 10 + 9 rows of design §4.4's two tables; the three
;;; rows of decision 0004's pause protocol that the design's tables fold into
;;; H6 and H10 (M2.4); the two rows of the upgrade door, decided on the
;;; owner's word on 2026-09-25 (M2.5); M3.2's two rows for what the handler
;;; answers, from decision 0010 items 2 and 3; M3.3's five rows for the
;;; writes and bytes outstanding, from design §7.3 and decision 0010 item 5;
;;; and M3.5's staged close, from RFC 9112 §9.6 and decision 0011: every
;;; close after a response lingers in a tenth state, `lingering`, and a state
;;; that reads stops reading when it refuses a request, as design §4.3's
;;; table says `responding` does.  And the five kinds of deadline the rows
;;; arm, design §4.3's four and decision 0011's linger, each lasting one of
;;; the limits (M5.1).  And M5.2's two tick rows, from decision 0005's table:
;;; a body past its deadline is answered 408, and a write past its deadline
;;; closes with no response.  And M6.1's nineteen rows for reading a body,
;;; from decision 0013.  With them, every way the core lets a connection
;;; go, a close or the hand-off, disarms its deadline first (plan §14's note of
;;; 2026-09-27).
;;;
;;; A parser-result event carries its error as the error's code, one of
;;; chez-httparse's, whose status never depends on where the parser refused
;;; (design §6.3, amended 2026-09-26).
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server limits) (http-server body) (fake-shell)
        (only (httparse decisions) F-UPGRADE F-CONNECTION-UPGRADE F-CHUNKED F-CONTENT-LENGTH)
        (only (chezscheme) display-condition))

(define (b s) (string->utf8 s))

;; Any delivery will do: in M2.1 the core never reads the bytes it is handed.
(define bv (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(define req (make-request 'GET (b "/") 1 1 '() #f))
(define post (make-request 'POST (b "/") 1 1 '() #f))
(define head-req (make-request 'HEAD (b "/") 1 1 '() #f))
(define resp (make-response 200 #f '() (b "row H7")))

;; state : Symbol . Plist -> ConnState
;; A synthetic state: the phase, plus any of deadline / close-after /
;; outstanding / outstanding-bytes / pending / request / target / host /
;; limits; every field not named takes its default, and the limits are
;; decision 0005's defaults unless given.  The head
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
                            (get 'outstanding-bytes 0) (get 'pending #f) (get 'request #f)
                            (get 'limits default-limits)))
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
;; A write's segments are bytes, so it is rendered with each as text; the
;; Date slot stays the symbol `date` (M3.2).
(define (render-action a)
  (if (eq? (car a) 'write)
      (list 'write
            (map (lambda (seg) (if (bytevector? seg) (utf8->string seg) seg)) (cadr a))
            (caddr a))
      a))

;; written : (U String 'date) ... -> Datum
;; A write as render-action shows it: its segments, and the bytes they come
;; to, the Date slot counted at its 37 (`Date: `, RFC 9110 §5.6.7's
;; 29-character IMF-fixdate, CRLF; decision 0010 item 4).
(define (written . segments)
  (list 'write segments
        (fold-left (lambda (n seg) (+ n (if (string? seg) (string-length seg) 37))) 0 segments)))

;; An originated status as render-action shows it: RFC 9110 §15's phrase, and
;; no body, so `Content-Length: 0` and `Connection: close` (decision 0010
;; item 6; design §6.5: every one closes).
(define (status-write n phrase)
  (written (string-append "HTTP/1.1 " (number->string n) " " phrase "\r\n") 'date
           "Content-Length: 0\r\nConnection: close\r\n\r\n"))

;; Every action kind any row emitted, for the vocabulary check at the end.
(define emitted '())

;; Every kind of deadline any row armed, for the kinds' check at the end.
(define armed '())

;; Every state a row left with a deadline recorded, as (phase . kind): armed
;; by the row, or carried into the state from the one before, for the check
;; that each has its tick row.
(define held '())

;; Every step whose state records a kind of deadline other than the one its
;; actions leave armed, as (before actions after), for the check at the end.
(define strays '())

;; left-armed : (U #f Kind) (Listof Action) -> (U #f Kind)
;; What a shell that performs `actions` has armed, given `before`: the kind
;; of the last arm-deadline, #f after a disarm-deadline, and `before` when
;; the actions touch no deadline.
(define (left-armed before actions)
  (fold-left (lambda (kind a)
               (case (car a)
                 ((arm-deadline) (cadr a))
                 ((disarm-deadline) #f)
                 (else kind)))
             before actions))

;; wheel-before : ConnState Event -> (U #f Kind)
;; What the shell's wheel holds for the connection as the event arrives: the
;; kind the state records, but nothing at a tick, since the wheel ticks a
;; connection only as it lets the deadline go (decision 0005's amendment of
;; 2026-09-27: an advance returns its keys already disarmed).
(define (wheel-before s ev)
  (if (eq? (car ev) 'tick) #f (conn-deadline s)))

;; outcome : ConnState Event -> (List Phase CloseAfter (Listof Datum))
;; One step: the state it leaves, whether it closes after the response, and
;; the actions in order.  What the wheel holds is read before the step, since
;; the step updates the state in place.
(define (outcome s ev)
  (let ((before (wheel-before s ev)))
    (call-with-values
     (lambda () (conn-step s ev))
     (lambda (s* actions)
       (set! emitted (append (map car actions) emitted))
       (set! armed (append (map cadr (filter (lambda (a) (eq? (car a) 'arm-deadline)) actions))
                           armed))
       (when (conn-deadline s*)
         (set! held (cons (cons (conn-phase s*) (conn-deadline s*)) held)))
       (unless (eq? (conn-deadline s*) (left-armed before actions))
         (set! strays (cons (list before (map car actions) (conn-deadline s*)) strays)))
       (list (conn-phase s*) (conn-close-after s*) (map render-action actions))))))

;; ticked : ConnState Event -> (List Phase CloseAfter (Listof Datum) Kind)
;; One step's outcome, and the kind of deadline the state records after it:
;; read once the step has run, since arguments have no order of evaluation.
(define (ticked s ev)
  (let* ((o (outcome s ev)) (after (conn-deadline s)))
    (append o (list after))))

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
;; synthetic states are built inside the suite, where a raise fails the
;; group's count (status 1) rather than crashing before any test runs.
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

   ;; The piece goes to the reader the handler answered with (M6.1,
   ;; decision 0013): here a streaming one, reading a body of 10 bytes.
   (row 'H5 "body, on-body-data -> body: continue, deliver-body, arm body"
        (i (reading 10 (read-body (lambda (bv from to) #t) (lambda () resp)))
           `(parser-event on-body-data ,bv 3 8)
           `(body #f ((reply-parser continue) (deliver-body ,bv 3 8) (arm-deadline body)))))

   (row 'H6 "body, on-message-complete -> handling: pause, read-stop, disarm, call-handler"
        (i (state 'body 'deadline 'body 'request req) '(parser-event on-message-complete)
           `(handling #f ((reply-parser pause) (read-stop) (disarm-deadline) (call-handler ,req)))))

   ;; The write is the serializer's segments for the request being answered
   ;; (M3.2): an HTTP/1.1 GET that keeps the connection.
   (row 'H7 "handling, handler-responded -> responding: write, arm write"
        (i (state 'handling 'request req) `(handler-responded ,resp)
           `(responding #f (,(written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\n\r\n" "row H7")
                            (arm-deadline write)))))

   (row 'H8 "responding, write-completed with more outstanding -> responding: arm write"
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 300)
           '(write-completed 100)
           '(responding #f ((arm-deadline write)))))

   (row 'H9 "responding, last write-completed, keep-alive -> idle: resume, feed pending, read-start, arm idle"
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'pending (list bv 10 20))
           '(write-completed 100)
           `(idle #f ((resume-parser) (feed-parser ,bv 10 20) (read-start) (arm-deadline idle)))))

   ;; The pending remainder is dropped, not fed: after a close-marked message
   ;; the core stops feeding (decision 0004 item 4).  The connection closes in
   ;; stages (RFC 9112 §9.6; decision 0011): the write side shut, reading on
   ;; to drop what arrives, the linger deadline armed.  Every close after a
   ;; response does, a request's own and the core's own status alike.
   (row 'H10 "responding, last write-completed, close-after -> lingering: shutdown, read-start, arm linger"
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'close-after 'not-keep-alive 'pending (list bv 10 20))
           '(write-completed 100)
           '(lingering not-keep-alive ((shutdown) (read-start) (arm-deadline linger))))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'close-after 'headers-too-large)
           '(write-completed 100)
           '(lingering headers-too-large ((shutdown) (read-start) (arm-deadline linger)))))))

;; ---------------------------------------------------------------------------
;; Design §4.4, termination and error: nine rows.
;;
;; Every row that closes, and the hand-off (T7), disarms the deadline first,
;; armed or not (M5.2).  The shell's wheel holds a connection whose deadline
;; is armed until the deadline passes, up to the idle deadline's 75 s, so
;; every way the core lets a connection go says to let it go.
(define (termination)
  (list
   (row 'T1 "any reading state, eof -> closing: disarm, close"
        (i (state 'idle 'deadline 'idle) '(eof) '(closing #f ((disarm-deadline) (close eof))))
        (i (state 'head 'deadline 'header) '(eof) '(closing #f ((disarm-deadline) (close eof))))
        (i (state 'body 'deadline 'body) '(eof) '(closing #f ((disarm-deadline) (close eof)))))

   (row 'T2 "any live state, read-error -> closing: log, disarm, close, no response"
        (i (state 'idle 'deadline 'idle) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (state 'head 'deadline 'header) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (state 'body 'deadline 'body) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (state 'handling) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (withheld 10 '(3 8)) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100)
           '(read-error EPIPE)
           '(closing #f ((log read-error EPIPE) (disarm-deadline) (close read-error))))
        (i (state 'draining) '(read-error ECONNRESET)
           '(closing #f ((log read-error ECONNRESET) (disarm-deadline) (close read-error))))
        (i (state 'lingering 'deadline 'linger 'close-after 'headers-too-large) '(read-error ECONNRESET)
           '(closing headers-too-large ((log read-error ECONNRESET) (disarm-deadline) (close read-error)))))

   ;; The status is design §6.5's for a parser error: 400, whatever the code,
   ;; invalid-transfer-encoding among them (RFC 9112 §6.3; amended on the
   ;; owner's word, 2026-09-26).  Refusing, the connection stops reading, as
   ;; `responding` does not read (design §4.3; M3.5).
   (row 'T3 "head/body, parser-result status=error -> responding: write the status, read-stop, close-after"
        (i (state 'head 'deadline 'header) '(parser-result error 0 0 invalid-method #f)
           `(responding parser-error (,(status-write 400 "Bad Request") (read-stop) (arm-deadline write))))
        (i (state 'body 'deadline 'body) '(parser-result error 47 47 invalid-chunk-size #f)
           `(responding parser-error (,(status-write 400 "Bad Request") (read-stop) (arm-deadline write))))
        (i (state 'body 'deadline 'body) '(parser-result error 49 49 invalid-transfer-encoding #f)
           `(responding parser-error (,(status-write 400 "Bad Request") (read-stop) (arm-deadline write)))))

   ;; Deadlines are kinds, not instants: the shell's wheel ticks a connection
   ;; only once the deadline it armed has passed (decision 0005), so "past the
   ;; header deadline" is a tick while the header deadline is armed.  The
   ;; second instance is the guard: a tick with nothing armed changes nothing.
   (row 'T4 "head, tick past the header deadline -> responding: write 408, read-stop, close-after"
        (i (state 'head 'deadline 'header) '(tick 60000)
           `(responding header-timeout (,(status-write 408 "Request Timeout") (read-stop) (arm-deadline write))))
        (i (state 'head) '(tick 60000)
           '(head #f ())))

   (row 'T5 "idle, tick past the idle deadline -> closing: disarm, close, no response"
        (i (state 'idle 'deadline 'idle) '(tick 75000)
           '(closing #f ((disarm-deadline) (close idle-timeout))))
        (i (state 'idle) '(tick 75000)
           '(idle #f ())))

   (row 'T6 "handling, handler-failed -> responding: write 500, close-after"
        (i (state 'handling) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (arm-deadline write)))))

   ;; The pause channel.  In v1 the core's own flow never reaches this row:
   ;; it pauses the parser at every message's end, and serves an upgrade and
   ;; closes after it (U1), so the parser never runs on to its hand-off.  It
   ;; is the door M8 opens for a handler that takes upgrades (decision 0006's
   ;; amendment of 2026-09-25).  The error channel is U2's.
   (row 'T7 "head/body, parser-result hands off -> handed-off: read-stop, disarm, the hand-off hook"
        (i (state 'head 'deadline 'header 'request req) '(parser-result paused 55 55 #f paused-upgrade)
           `(handed-off #f ((read-stop) (disarm-deadline) (hand-off ,req))))
        (i (state 'body 'deadline 'body 'request req) '(parser-result paused 63 63 #f paused-upgrade)
           `(handed-off #f ((read-stop) (disarm-deadline) (hand-off ,req)))))

   ;; Instantiated on idle only: with nothing in flight "finish in flight" is
   ;; vacuous.  The in-flight states have no row into draining, so they have
   ;; nothing to finish through yet; that is M8's.  The idle deadline goes
   ;; with the connection into draining, and D3 acts on it there.
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

   (row 'U2 "head, parser-result hands off on the error channel (the HTTP/2 preface) -> responding 505, read-stop, close-after"
        (i (state 'head 'deadline 'header) '(parser-result error 24 24 paused-h2-upgrade #f)
           `(responding http2-preface (,(status-write 505 "HTTP Version Not Supported") (read-stop)
                                       (arm-deadline write)))))))

;; ---------------------------------------------------------------------------
;; M3.2: what handler-responded does with what the handler answers (decision
;; 0010 items 2 and 3).  A response the serializer cannot write safely is
;; answered 500, the log naming its fault; a handler's `Connection: close`
;; closes the connection after its response.  Each enters `responding` with
;; the write deadline armed, as every entry into it does (design §4.3).
(define (response-rows)
  (list
   (row 'R1 "handling, handler-responded with a fault -> responding 500, close-after: log, write, arm write"
        (i (state 'handling 'request req)
           `(handler-responded ,(make-response 200 #f (list (cons (b "Content-Length") (b "5"))) #f))
           `(responding invalid-response
                        ((log invalid-response framing-field)
                         ,(status-write 500 "Internal Server Error")
                         (arm-deadline write)))))
   (row 'R2 "handling, handler-responded with Connection: close -> responding, close-after: write, arm write"
        (i (state 'handling 'request req)
           `(handler-responded ,(make-response 200 #f (list (cons (b "Connection") (b "close"))) #f))
           `(responding handler-close
                        (,(written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 0\r\nConnection: close\r\n\r\n")
                         (arm-deadline write)))))))

;; ---------------------------------------------------------------------------
;; M3.3: the writes and bytes outstanding (design §7.3; decision 0010 item 5).
;; Every write the core asks for is outstanding, with the bytes it comes to,
;; until the shell reports it completed: in `responding`, or in `closing`
;; for a write a close cut short.  W1's writes are the rows' own above: H7's,
;; T4's 408 and R1's 500.  A completion the core did not ask for is the
;; shell's bug, refused as an assertion violation.

;; accounted : ConnState Event
;;   -> (U (List Phase CloseAfter (Listof Datum) Nat Nat) 'refused 'crashed)
;; One step's outcome, and the writes and bytes the state holds outstanding
;; after it; or 'refused when the core refuses the event, an assertion
;; violation of its own, and 'crashed for one raised by anything else, such
;; as a fixnum operation handed a symbol.
(define (accounted s ev)
  (guard (e ((assertion-violation? e)
             (if (and (who-condition? e) (eq? (condition-who e) 'conn-step)) 'refused 'crashed)))
    (let* ((o (outcome s ev)))
      (append o (list (conn-outstanding s) (conn-outstanding-bytes s))))))

;; nbytes : Datum -> Nat — the byte count of a write as render-action shows it.
(define (nbytes w) (caddr w))

(define (accounting-rows)
  (list
   (row 'W1 "handling -> responding: the write is outstanding, and its bytes"
        (let ((w (written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\n\r\n" "row H7")))
          (i (state 'handling 'request req) `(handler-responded ,resp)
             `(responding #f (,w (arm-deadline write)) 1 ,(nbytes w))))
        (let ((w (status-write 408 "Request Timeout")))
          (i (state 'head 'deadline 'header) '(tick 60000)
             `(responding header-timeout (,w (read-stop) (arm-deadline write)) 1 ,(nbytes w))))
        (let ((w (status-write 500 "Internal Server Error")))
          (i (state 'handling 'request req)
             `(handler-responded ,(make-response 200 #f (list (cons (b "Content-Length") (b "5"))) #f))
             `(responding invalid-response
                          ((log invalid-response framing-field) ,w (arm-deadline write))
                          1 ,(nbytes w)))))
   (row 'W2 "responding, write-completed with more outstanding: its bytes are no longer outstanding"
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 300)
           '(write-completed 100)
           '(responding #f ((arm-deadline write)) 1 200)))
   (row 'W3 "responding, the last write-completed: nothing is outstanding"
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100)
           '(write-completed 100)
           '(idle #f ((resume-parser) (read-start) (arm-deadline idle)) 0 0))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'close-after 'not-keep-alive)
           '(write-completed 100)
           '(lingering not-keep-alive ((shutdown) (read-start) (arm-deadline linger)) 0 0)))
   ;; Each instance breaks one condition: more bytes than are outstanding, a
   ;; last write that leaves some, a count that is not one, no count at all,
   ;; and no write outstanding.
   (row 'W4 "write-completed that the core did not ask for: refused"
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 100)
           '(write-completed 101) 'refused)
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100)
           '(write-completed 99) 'refused)
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 100)
           '(write-completed -1) 'refused)
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 100)
           '(write-completed ten) 'refused)
        (i (state 'responding 'deadline 'write 'outstanding 2 'outstanding-bytes 100)
           '(write-completed) 'refused)
        (i (state 'closing) '(write-completed 0) 'refused))
   ;; A read error while a write is outstanding closes the connection (T2),
   ;; and so does the write deadline (D2).  libuv still reports the write
   ;; the close cut short, and its completion settles it; how the shell
   ;; reports a cancelled write is M4's.
   (row 'W5 "closing, write-completed for a write the close cut short -> closing: nothing outstanding, nothing asked"
        (i (state 'closing 'outstanding 1 'outstanding-bytes 100) '(write-completed 100)
           '(closing #f () 0 0)))))

;; ---------------------------------------------------------------------------
;; M3.5: the staged close (RFC 9112 §9.6; decision 0011).  A connection that
;; lingers has written its last response and shut its write side; it reads,
;; and drops what arrives, until the client closes, a read fails (T2), or the
;; linger deadline passes.  The deadline is armed once, when lingering
;; starts, so a client that keeps sending cannot hold the connection past
;; it.  The close names the reason the connection closes after its response.
(define (linger-rows)
  (list
   (row 'L1 "lingering, bytes-arrived -> lingering: dropped, nothing fed, the deadline not re-armed"
        (i (state 'lingering 'deadline 'linger 'close-after 'headers-too-large) `(bytes-arrived ,bv 0 5)
           '(lingering headers-too-large ())))
   (row 'L2 "lingering, eof -> closing: disarm, close, for the reason it closes after its response"
        (i (state 'lingering 'deadline 'linger 'close-after 'not-keep-alive) '(eof)
           '(closing not-keep-alive ((disarm-deadline) (close not-keep-alive)))))
   ;; As T4 and T5: the wheel ticks a connection once its deadline has
   ;; passed, and a tick with nothing armed changes nothing.
   (row 'L3 "lingering, tick past the linger deadline -> closing: disarm, close"
        (i (state 'lingering 'deadline 'linger 'close-after 'handler-close) '(tick 30000)
           '(closing handler-close ((disarm-deadline) (close handler-close))))
        (i (state 'lingering 'close-after 'handler-close) '(tick 30000)
           '(lingering handler-close ())))
   ;; The shell reports that the half-close is done; the client's close,
   ;; not this, ends the linger.
   (row 'L4 "lingering, shutdown-completed -> lingering: nothing"
        (i (state 'lingering 'deadline 'linger 'close-after 'not-keep-alive) '(shutdown-completed)
           '(lingering not-keep-alive ())))))

;; ---------------------------------------------------------------------------
;; M5.2: every deadline the core arms has its tick row (design §4.4, amended
;; 2026-09-27; decision 0005's table).  T5, T4 and L3 act on the idle, header
;; and linger deadlines; D1 and D2 act on the other two, and D3 on the idle
;; deadline a draining connection carries.  A body that stalls past its
;; inactivity deadline is answered 408, as a head that stalls is, framed for
;; the request in flight.  A write still outstanding past its deadline means a
;; client that is not reading, so nothing more can be written to it: the
;; connection closes with no response, for the write deadline, whatever it
;; would have closed for after the response, and the write the close cuts
;; short is settled in `closing` (W5).  As in T4, an instance with nothing
;; armed is the guard.  Each outcome ends with the deadline the state records
;; after the tick.
(define (deadline-rows)
  (list
   ;; A HEAD's answer carries no Content-Length the core cannot know (decision
   ;; 0010 item 6), so its 408 shows the request in flight framing it.
   (row 'D1 "body, tick past the body deadline -> responding: write 408, read-stop, close-after"
        (i (state 'body 'deadline 'body 'request post) '(tick 60000)
           `(responding body-timeout (,(status-write 408 "Request Timeout") (read-stop) (arm-deadline write))
                        write))
        (i (state 'body 'deadline 'body 'request head-req) '(tick 60000)
           `(responding body-timeout (,(written "HTTP/1.1 408 Request Timeout\r\n" 'date
                                                "Connection: close\r\n\r\n")
                                      (read-stop) (arm-deadline write))
                        write))
        (i (state 'body 'request post) '(tick 60000)
           '(body #f () #f)))
   ;; The log names the bytes still outstanding, for an operator to tell a
   ;; client that stopped reading from one that went away.
   (row 'D2 "responding, tick past the write deadline -> closing: log, disarm, close, no response"
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100) '(tick 60000)
           '(closing #f ((log write-timeout 100) (disarm-deadline) (close write-timeout)) #f))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'close-after 'header-timeout)
           '(tick 60000)
           '(closing header-timeout ((log write-timeout 100) (disarm-deadline) (close write-timeout)) #f))
        (i (state 'responding 'outstanding 1 'outstanding-bytes 100) '(tick 60000)
           '(responding #f () #f)))
   ;; A connection draining from idle had nothing in flight, and the idle
   ;; deadline went with it (T8): past it, the connection closes, as idle's
   ;; does.  The rows M8 writes for draining arm the write deadline there.
   (row 'D3 "draining, tick past the idle deadline it carried from idle -> closing: disarm, close, no response"
        (i (state 'draining 'deadline 'idle) '(tick 75000)
           '(closing #f ((disarm-deadline) (close idle-timeout)) #f))
        (i (state 'draining) '(tick 75000)
           '(draining #f () #f)))
   ;; A tick means the wheel has let the deadline go: an advance returns its
   ;; keys already disarmed.  So the state records none after a tick, even
   ;; where no row acts on the kind it recorded, and agrees with the wheel.
   (row 'D4 "any, tick past a deadline no row acts on there -> the same state: nothing asked, no deadline recorded"
        (i (state 'handling 'deadline 'idle) '(tick 75000)
           '(handling #f () #f))
        (i (state 'head 'deadline 'body) '(tick 60000)
           '(head #f () #f))
        (i (withheld 10 '(3 8)) '(tick 60000)
           '(awaiting-credit #f () #f)))))

;; ---------------------------------------------------------------------------
;; M6.1: reading a body (decision 0013).  A request whose head announces a
;; body, chunked or a Content-Length above 0, is handed to the handler once
;; the feed that completed its head has returned; the handler answers with a
;; response or a reader, and the core hands a reader the body.  What that feed
;; met of the body before the handler was asked waits for its answer: the
;; pieces, and an error or a cap passed.  The states are reached by steps,
;; from a head being read: a POST (llhttp's method 3) whose head announces its
;; body, as on-headers-complete's flags and content-length say.

;; announced : (U Nat 'chunked) [Limits] -> ConnState
;; A POST whose head, just complete, announced a body of `n` bytes by
;; Content-Length, or a chunked one: in body, its handler to be asked.
(define (announced framing . limits)
  (let ((s (apply state 'head 'deadline 'header 'target "/" 'host "x"
                  (if (null? limits) '() (list 'limits (car limits))))))
    (conn-step s (if (eq? framing 'chunked)
                     `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0)
                     `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH ,framing 0)))
    s))

;; met : ConnState (Listof (List Nat Nat)) -> ConnState
;; The same state, having met `pieces`, each bv[from, to), as body data.
(define (met s pieces)
  (for-each (lambda (p) (conn-step s `(parser-event on-body-data ,bv ,(car p) ,(cadr p)))) pieces)
  s)

;; asked : (U Nat 'chunked) . Piece -> ConnState
;; A POST that met `pieces` in the feed that completed its head, which has
;; returned and asked its handler.
(define (asked framing . pieces)
  (let ((s (met (announced framing) pieces)))
    (conn-step s '(parser-result need-input 49 49 #f #f))
    s))

;; reading : (U Nat 'chunked) BodyReader -> ConnState
;; The same, with no piece met, its handler having answered with `reader`.
(define (reading framing reader)
  (let ((s (asked framing)))
    (conn-step s `(handler-responded ,reader))
    s))

;; ended : (U Nat 'chunked) . Piece -> ConnState
;; A POST whose head and whole body, `pieces`, came in one feed: paused at
;; the message's end, its handler to be asked.
(define (ended framing . pieces)
  (let ((s (met (announced framing) pieces)))
    (conn-step s '(parser-event on-message-complete))
    s))

;; erred : (U Nat 'chunked) Event . Piece -> ConnState
;; A POST whose head's feed met `pieces`, then the parser's error, an
;; invalid chunk size: in handling, reading stopped, its handler asked and
;; the error kept for its answer.
(define (erred framing . pieces)
  (let ((s (met (announced framing) pieces)))
    (conn-step s '(parser-result error 60 60 invalid-chunk-size #f))
    s))

(define streamer (read-body (lambda (bv from to) #t) (lambda () resp)))
(define (whole-reader . cap) (apply read-whole-body (lambda (body) resp) cap))
(define (capped n) (limits-with default-limits (list (cons 'max-body-bytes n))))

;; asked-by : ConnState Event -> (List Phase CloseAfter (Listof Datum))
;; One step's outcome, a call-handler shown by its request's method: the
;; request is the one the core built at the head.
(define (asked-by s ev)
  (let ((o (outcome s ev)))
    (list (car o) (cadr o)
          (map (lambda (a)
                 (if (and (pair? a) (eq? (car a) 'call-handler))
                     (list 'call-handler (request-method (cadr a)))
                     a))
               (caddr o)))))

(define answered-closing
  (written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\nConnection: close\r\n\r\n" "row H7"))

(define (body-rows)
  (list
   (row 'B1 "head, on-headers-complete announcing a body -> body: continue, disarm, arm body; nothing asked yet"
        (i (state 'head 'deadline 'header 'target "/" 'host "x")
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/" 'host "x")
           `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   (row 'B2 "body or handling, the feed that completed the head returns -> the same: call-handler"
        (i (announced 10) '(parser-result need-input 49 49 #f #f)
           '(body #f ((call-handler POST))))
        (i (ended 5 '(3 8)) '(parser-result paused 54 54 #f #f)
           '(handling #f ((call-handler POST)))))

   (row 'B3 "body, on-body-data before the handler answers -> body: continue, arm body, the piece kept"
        (i (asked 10) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser continue) (arm-deadline body)))))

   (row 'B4 "body, handler-responded with a streaming reader -> body: the pieces kept, handed over in order"
        (i (asked 10 '(3 5) '(5 8)) `(handler-responded ,streamer)
           `(body #f ((deliver-body ,bv 3 5) (deliver-body ,bv 5 8)))))

   (row 'B5 "handling, the message ended in the head's feed, handler-responded with a streaming reader -> handling: the pieces kept, then deliver-body-end"
        (let ((s (ended 5 '(3 8))))
          (conn-step s '(parser-result paused 54 54 #f #f))
          (i s `(handler-responded ,streamer)
             `(handling #f ((deliver-body ,bv 3 8) (deliver-body-end))))))

   (row 'B6 "body, handler-responded with a whole reader -> body: the pieces kept, buffered"
        (i (asked 10 '(3 8)) `(handler-responded ,(whole-reader))
           '(body #f ())))

   (row 'B7 "body, on-body-data, a whole reader reading -> body: continue, arm body, the piece buffered"
        (i (reading 10 (whole-reader)) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser continue) (arm-deadline body)))))

   (row 'B8 "body, on-message-complete, a streaming reader reading -> handling: pause, read-stop, disarm, deliver-body-end"
        (i (reading 10 streamer) '(parser-event on-message-complete)
           '(handling #f ((reply-parser pause) (read-stop) (disarm-deadline) (deliver-body-end)))))

   ;; The body, "GET /" and " HTTP" of the delivery, whole in a bytevector
   ;; of its own.
   (row 'B9 "body, on-message-complete, a whole reader reading -> handling: pause, read-stop, disarm, the body as one piece, deliver-body-end"
        (let ((s (met (reading 10 (whole-reader)) '((0 5) (5 10)))))
          (i s '(parser-event on-message-complete)
             `(handling #f ((reply-parser pause) (read-stop) (disarm-deadline)
                            (deliver-body ,(b "GET / HTTP") 0 10) (deliver-body-end))))))

   (row 'B10 "handling, handler-responded with the reader's response -> responding: write, arm write"
        (let ((s (reading 10 streamer)))
          (conn-step s '(parser-event on-message-complete))
          (i s `(handler-responded ,resp)
             `(responding #f (,(written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\n\r\n" "row H7")
                              (arm-deadline write))))))

   ;; Item 4: sent at once, and the connection closes after it, whether the
   ;; body is still arriving or came whole with the head.
   (row 'B11 "body or handling, handler-responded with a response to a request that announced a body -> responding, close-after unread-body"
        (i (asked 10) `(handler-responded ,resp)
           `(responding unread-body (,answered-closing (read-stop) (arm-deadline write))))
        (let ((s (ended 5 '(3 8))))
          (conn-step s '(parser-result paused 54 54 #f #f))
          (i s `(handler-responded ,resp)
             `(responding unread-body (,answered-closing (arm-deadline write))))))

   ;; Item 6: a whole reader of no body has an empty one, no piece.
   (row 'B12 "handling, handler-responded with a reader, for a request with no body -> handling: deliver-body-end"
        (i (state 'handling 'request req) `(handler-responded ,streamer)
           '(handling #f ((deliver-body-end))))
        (i (state 'handling 'request req) `(handler-responded ,(whole-reader))
           '(handling #f ((deliver-body-end)))))

   ;; Item 5: the limits' max-body-bytes caps every body, and a reader's own
   ;; cap its body.
   (row 'B13 "head, on-headers-complete declaring a length past max-body-bytes -> head: fail body-too-large"
        (i (state 'head 'deadline 'header 'target "/" 'host "x" 'limits (capped 5))
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0)
           '(head #f ((reply-parser (fail body-too-large))))))

   ;; The piece up to the cap, bv[3, 7), is handed to a streaming reader, or
   ;; kept for the answer; a whole reader's buffer is let go with the rest.
   (row 'B14 "body, on-body-data past max-body-bytes or a reader's cap -> body: fail body-too-large, the piece up to the cap handed over or kept"
        (let ((s (announced 'chunked (capped 4))))
          (conn-step s '(parser-result need-input 49 49 #f #f))
          (conn-step s `(handler-responded ,streamer))
          (i s `(parser-event on-body-data ,bv 3 8)
             `(body #f ((reply-parser (fail body-too-large)) (deliver-body ,bv 3 7)))))
        (i (announced 'chunked (capped 4)) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser (fail body-too-large)))))
        (i (reading 'chunked (whole-reader 4)) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser (fail body-too-large))))))

   ;; A reader's cap, passed before it reads: the declared length, or the
   ;; pieces met before it answered.
   (row 'B15 "body, handler-responded with a reader whose cap the body passes -> responding 413, read-stop, close-after"
        (i (asked 10) `(handler-responded ,(whole-reader 5))
           `(responding body-too-large (,(status-write 413 "Content Too Large") (read-stop) (arm-deadline write))))
        (i (asked 'chunked '(3 8)) `(handler-responded ,(whole-reader 4))
           `(responding body-too-large (,(status-write 413 "Content Too Large") (read-stop) (arm-deadline write)))))

   ;; What the feed that completed the head met in the body before the
   ;; handler was asked waits for its answer (design §8.1's second property).
   (row 'B16 "body, the head's feed met an error in the body -> handling: read-stop, disarm, call-handler, the error kept"
        (i (met (announced 'chunked) '((3 8))) '(parser-result error 60 60 invalid-chunk-size #f)
           '(handling #f ((read-stop) (disarm-deadline) (call-handler POST))))
        (let ((s (met (announced 'chunked (capped 4)) '((3 7)))))
          (conn-step s `(parser-event on-body-data ,bv 7 9))
          (i s '(parser-result error 60 60 body-too-large #f)
             '(handling #f ((read-stop) (disarm-deadline) (call-handler POST))))))

   (row 'B17 "handling, an error kept, handler-responded with a streaming reader -> responding: the pieces kept, then the error's status"
        (i (erred 'chunked '(3 8)) `(handler-responded ,streamer)
           `(responding parser-error ((deliver-body ,bv 3 8) ,(status-write 400 "Bad Request") (arm-deadline write))))
        (let ((s (met (announced 'chunked (capped 4)) '((3 7)))))
          (conn-step s `(parser-event on-body-data ,bv 7 9))
          (conn-step s '(parser-result error 60 60 body-too-large #f))
          (i s `(handler-responded ,streamer)
             `(responding body-too-large ((deliver-body ,bv 3 7)
                                          ,(status-write 413 "Content Too Large") (arm-deadline write))))))

   (row 'B18 "handling, an error kept, handler-responded with a response -> responding, close-after unread-body: the error not answered"
        (i (erred 'chunked '(3 8)) `(handler-responded ,resp)
           `(responding unread-body (,answered-closing (arm-deadline write)))))

   (row 'B19 "body, handler-failed -> responding 500, read-stop, close-after"
        (i (asked 10) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (read-stop) (arm-deadline write))))
        (i (reading 10 streamer) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (read-stop) (arm-deadline write)))))))

;; ---------------------------------------------------------------------------
;; M6.2: backpressure on the read side (plan §14; decision 0013's
;; consequences).  A shell that hands a streaming reader its pieces on credit
;; says so with the reader, `(handler-responded reader credit)`: M7's
;; coroutine shell, and in v1 only the checks' shells.  Handed a read's
;; pieces, such a reader makes reading wait until its credit covers them: the
;; connection reads nothing and arms no deadline, since the server is the one
;; waiting (plan §14's note of 2026-09-27), so a slow reader holds at most one
;; read.  A reader answered with no word of credit, as v1's shells answer
;; every one, takes each piece as it is handed over, and reading goes on at
;; once.  The credit counts bytes.

;; on-credit : (U Nat 'chunked) [Limits] -> ConnState
;; A POST with no piece met, whose handler's streaming reader the shell hands
;; its pieces on credit.
(define (on-credit framing . limits)
  (let ((s (apply announced framing limits)))
    (conn-step s '(parser-result need-input 49 49 #f #f))
    (conn-step s `(handler-responded ,streamer credit))
    s))

;; withheld : (U Nat 'chunked) . Piece -> ConnState
;; The same, handed `pieces` in one feed, which has returned: waiting for the
;; reader's credit for them.
(define (withheld framing . pieces)
  (let ((s (met (on-credit framing) pieces)))
    (conn-step s '(parser-result need-input 60 60 #f #f))
    s))

;; credited : ConnState Event -> (U (List Phase CloseAfter (Listof Datum)) 'refused 'crashed)
;; One step's outcome, or 'refused when the core refuses the event, an
;; assertion violation of its own, and 'crashed for one raised by anything
;; else.
(define (credited s ev)
  (guard (e ((assertion-violation? e)
             (if (and (who-condition? e) (eq? (condition-who e) 'conn-step)) 'refused 'crashed)))
    (outcome s ev)))

(define (credit-rows)
  (list
   (row 'C1 "body, a feed returns having handed a reader on credit pieces it has not credited -> awaiting-credit: read-stop, disarm"
        (i (met (on-credit 10) '((3 5) (5 8))) '(parser-result need-input 60 60 #f #f)
           '(awaiting-credit #f ((read-stop) (disarm-deadline))))
        (i (met (on-credit 'chunked) '((3 8))) '(parser-result need-input 60 60 #f #f)
           '(awaiting-credit #f ((read-stop) (disarm-deadline)))))

   ;; A reader answered with no word of credit, a whole reader answered on
   ;; credit (the core copies its pieces), and a reader on credit handed
   ;; nothing in the feed.
   (row 'C2 "body, a feed returns with nothing handed that is not credited -> body: nothing, reading goes on"
        (i (met (reading 10 streamer) '((3 8))) '(parser-result need-input 60 60 #f #f)
           '(body #f ()))
        (let ((s (asked 10)))
          (conn-step s `(handler-responded ,(whole-reader) credit))
          (i (met s '((3 8))) '(parser-result need-input 60 60 #f #f)
             '(body #f ())))
        (i (on-credit 10) '(parser-result need-input 60 60 #f #f)
           '(body #f ())))

   (row 'C3 "body, handler-responded with a reader on credit -> the pieces kept handed over, then awaiting-credit: read-stop, disarm"
        (i (asked 10 '(3 5) '(5 8)) `(handler-responded ,streamer credit)
           `(awaiting-credit #f ((deliver-body ,bv 3 5) (deliver-body ,bv 5 8) (read-stop) (disarm-deadline))))
        (i (asked 10) `(handler-responded ,streamer credit)
           '(body #f ())))

   (row 'C4 "awaiting-credit, body-credit for all it was handed -> body: read-start, arm body"
        (i (withheld 10 '(3 5) '(5 8)) '(body-credit 5)
           '(body #f ((read-start) (arm-deadline body))))
        (let ((s (withheld 10 '(3 8))))
          (conn-step s '(body-credit 2))
          (i s '(body-credit 3)
             '(body #f ((read-start) (arm-deadline body))))))

   (row 'C5 "awaiting-credit, body-credit for part of what it was handed -> awaiting-credit: nothing"
        (i (withheld 10 '(3 8)) '(body-credit 2)
           '(awaiting-credit #f ())))

   ;; Each instance breaks one condition: more than was handed, a count that
   ;; is not one, no count at all, and a credit to a reader that takes its
   ;; pieces as they are handed over.
   (row 'C6 "body-credit for more than the reader was handed and has not credited: refused"
        (i (withheld 10 '(3 8)) '(body-credit 6) 'refused)
        (i (withheld 10 '(3 8)) '(body-credit -1) 'refused)
        (i (withheld 10 '(3 8)) '(body-credit five) 'refused)
        (i (withheld 10 '(3 8)) '(body-credit) 'refused)
        (let ((s (met (reading 10 streamer) '((3 8)))))
          (conn-step s '(parser-result need-input 60 60 #f #f))
          (i s '(body-credit 1) 'refused)))

   (row 'C7 "awaiting-credit, handler-failed -> responding 500, close-after: reading stopped already"
        (i (withheld 10 '(3 8)) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (arm-deadline write)))))

   (row 'C8 "awaiting-credit, bytes-arrived -> awaiting-credit: nothing fed"
        (i (withheld 10 '(3 8)) `(bytes-arrived ,bv 0 4)
           '(awaiting-credit #f ())))

   ;; The message has ended, and reading waits for the response; or the
   ;; request was refused, and the reader keeps what it was handed.
   (row 'C9 "handling or responding, body-credit -> the same: nothing"
        (let ((s (met (on-credit 10) '((3 8)))))
          (conn-step s '(parser-event on-message-complete))
          (i s '(body-credit 5) '(handling #f ())))
        (let ((s (withheld 10 '(3 8))))
          (conn-step s '(handler-failed boom))
          (i s '(body-credit 5) '(responding handler-failed ()))))

   ;; The refusal, not the wait: a feed that handed a reader on credit pieces
   ;; and then met the parser's error, or passed a cap, is answered with the
   ;; status, as it is for any reader (T3, B14), though the reader owes credit.
   (row 'C10 "body, a feed that handed a reader on credit pieces ends in an error or past a cap -> responding: the status, not the wait"
        (i (met (on-credit 'chunked) '((3 8))) '(parser-result error 60 60 invalid-chunk-size #f)
           `(responding parser-error (,(status-write 400 "Bad Request") (read-stop) (arm-deadline write))))
        (let ((s (on-credit 'chunked (capped 4))))
          (conn-step s `(parser-event on-body-data ,bv 3 8))
          (i s '(parser-result error 60 60 body-too-large #f)
             `(responding body-too-large (,(status-write 413 "Content Too Large") (read-stop)
                                          (arm-deadline write))))))

   ;; What follows the answer is `credit` or nothing.
   (row 'C11 "handler-responded with a word after the answer other than credit: refused"
        (i (asked 10) `(handler-responded ,streamer later) 'refused)
        (i (asked 10) `(handler-responded ,streamer credit credit) 'refused))))

;; index : Any (Listof Any) -> Nat — where `x` stands in `xs`.
(define (index x xs)
  (let loop ((xs xs) (n 0))
    (if (eq? (car xs) x) n (loop (cdr xs) (+ n 1)))))

;; held-pairs : -> (Listof (Pair Phase Kind))
;; Each (phase . kind) the rows left a connection in, once: by kind, in
;; conn-deadline-kinds' order, then by phase, in conn-states'.
(define (held-pairs)
  (list-sort (lambda (a b)
               (let ((ka (index (cdr a) conn-deadline-kinds))
                     (kb (index (cdr b) conn-deadline-kinds)))
                 (or (< ka kb)
                     (and (= ka kb) (< (index (car a) conn-states) (index (car b) conn-states))))))
             (fold-left (lambda (seen p) (if (member p seen) seen (cons p seen))) '() held)))

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
           '(parser-result error 1 29 closed-connection #f)
           '(handling not-keep-alive () #f)))

   ;; The states a close-marked message passes through after its pause.
   (row 'P3 "after a close-marked message, bytes-arrived -> no feed-parser"
        (i (state 'handling 'close-after 'not-keep-alive) `(bytes-arrived ,bv 0 5)
           '(handling not-keep-alive () #f))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                  'close-after 'not-keep-alive)
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

;; count-rows : String (-> (Listof Row)) (ConnState Event -> Datum)
;;              -> (U Nat 'raised)
;; Build a group of rows and run each through `step`: how many have a test.
;; Building them runs the core, a target read into a state's head or a pause
;; reached by steps, so a raise there is the code under test failing, as a
;; raise inside a check is.  It fails the group's count, which is 'raised,
;; and the group's name and the condition go to the error port, so the cause
;; is not lost.
(define (count-rows name rows step)
  (guard (e (#t (let ((p (current-error-port)))
                  (put-string p (string-append "RAISED building the " name " rows: "))
                  (display-condition e p)
                  (newline p))
                'raised))
    (fold-left (lambda (n r) (+ n (run-row r step))) 0 (rows))))

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
    (test-equal "eleven states: design §4.3's nine, decision 0011's lingering and M6.2's awaiting-credit"
                '(idle head body awaiting-credit handling responding lingering draining handed-off
                  closing closed)
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
    (test-equal "five deadline kinds: design §4.3's idle, header, body and write, and decision 0011's linger"
                '(idle header body write linger)
                conn-deadline-kinds)

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
    (test-eq "a state outside the eleven is refused" 'refused
             (verdict (lambda () (state 'no-such-state))))
    ;; The writes and bytes outstanding are counts, zero together: every
    ;; write has bytes, a status line at least, and bytes are outstanding
    ;; only in a write (M3.3).
    (test-equal "writes and bytes outstanding that are not counts, or not zero together, are refused"
                '(accepted refused refused refused refused)
                (map (lambda (plist) (verdict (lambda () (apply state 'responding plist))))
                     '((outstanding 1 outstanding-bytes 100)
                       (outstanding 1)
                       (outstanding-bytes 100)
                       (outstanding -1 outstanding-bytes 100)
                       (outstanding 1 outstanding-bytes many))))

    ;; --- the table ------------------------------------------------------
    ;; A row with no instance is absent from the count, and the count is the
    ;; design's.  Each group's rows run before its count is checked: SRFI-64's
    ;; simple runner names a failing check after the last check run inside
    ;; it, so a count taken inside its check fails under a row's name.
    (let* ((happy (count-rows "happy-path" happy-path outcome))
           (term (count-rows "termination" termination outcome))
           (pause (count-rows "pause-protocol" pause-protocol kept))
           (upgrade (count-rows "upgrade-door" upgrade-door outcome))
           (answered (count-rows "response" response-rows outcome))
           (accounting (count-rows "accounting" accounting-rows accounted))
           (linger (count-rows "linger" linger-rows outcome))
           (ticks (count-rows "tick" deadline-rows ticked))
           (bodies (count-rows "body" body-rows asked-by))
           (credits (count-rows "credit" credit-rows credited)))
      (test-eqv "design §4.4: all 10 happy-path rows have a test" 10 happy)
      (test-eqv "design §4.4: all 9 termination and error rows have a test" 9 term)
      (test-eqv "decision 0004: all 3 pause-protocol rows have a test" 3 pause)
      (test-eqv "M2.5: both upgrade-door rows have a test" 2 upgrade)
      (test-eqv "M3.2: both response rows have a test" 2 answered)
      (test-eqv "M3.3: all 5 accounting rows have a test" 5 accounting)
      (test-eqv "M3.5: all 4 linger rows have a test" 4 linger)
      (test-eqv "M5.2: all 4 tick rows have a test" 4 ticks)
      (test-eqv "M6.1: all 19 body rows have a test" 19 bodies)
      (test-eqv "M6.2: all 11 credit rows have a test" 11 credits))

    ;; Every action the table produced is in the vocabulary, and the table
    ;; uses all of it but `notify-producer`, a streamed response's (M6.3).
    (test-equal "no row emits an action outside the vocabulary" '()
                (filter (lambda (k) (not (memq k conn-actions))) emitted))
    (test-equal "the rows use fifteen of the sixteen actions"
                '(reply-parser feed-parser resume-parser write read-stop read-start
                  call-handler deliver-body deliver-body-end arm-deadline disarm-deadline
                  shutdown close log hand-off)
                (filter (lambda (k) (memq k emitted)) conn-actions))
    (test-equal "the rows arm all five deadline kinds, and no other"
                (list conn-deadline-kinds '())
                (list (filter (lambda (k) (memq k armed)) conn-deadline-kinds)
                      (filter (lambda (k) (not (memq k conn-deadline-kinds))) armed)))
    (test-equal "each deadline kind lasts one of the limits: idle 75 s, header, body and write 60 s, linger 30 s"
                '(75000 60000 60000 60000 30000)
                (map (lambda (k) (limits-deadline-ms default-limits k)) conn-deadline-kinds))

    ;; The state records the kind of deadline armed, so that a tick is acted
    ;; on only while that kind is (the guards above), and a shell arms and
    ;; disarms only as the actions say.  The two must agree after every row:
    ;; the kind the state records is what the row's actions leave armed,
    ;; starting from what the wheel held, which at a tick is nothing (see
    ;; wheel-before).  A close and the hand-off cleared the kind without a
    ;; disarm until M5.2, which left a connection gone from the core in the
    ;; shell's wheel; and a tick no row acted on left a kind the wheel had
    ;; already let go (D4).
    (test-equal "after every row, the state records the deadline its actions leave armed" '()
                strays)

    ;; Every deadline the core arms has its tick row (M5.2): ticked in each
    ;; state a row leaves it armed in, armed there or carried in from the
    ;; state before, the connection moves on, to a 408 or a close, never
    ;; staying where it was.  A write that never completes must not keep the
    ;; connection open, and a draining connection must not keep the idle
    ;; deadline it carried with nothing to act on it.
    (test-equal "each deadline a row leaves armed, ticked in the state it leaves, moves the connection on"
                '((idle idle closing) (draining idle closing) (head header responding)
                  (body body responding) (responding write closing) (lingering linger closing))
                (map (lambda (pair)
                       (let ((s (state (car pair) 'deadline (cdr pair))))
                         (conn-step s '(tick 0))
                         (list (car pair) (cdr pair) (conn-phase s))))
                     (held-pairs)))

    ;; --- conn-step in the fake shell ------------------------------------
    ;; The fake shell's tick is a vocabulary event: (tick now), not (tick . now).
    (let ((s (make-fake-shell conn-step (state 'idle 'deadline 'idle) 0)))
      (fake-shell-advance! s 75000)
      (fake-shell-tick! s)
      (test-equal "the fake shell delivers (tick now)" '((tick 75000)) (fake-shell-events s))
      (test-equal "conn-step runs in the fake shell: the idle deadline closes"
                  '((disarm-deadline) (close idle-timeout)) (fake-shell-actions s))
      (test-eq "the fake shell threads conn-step's state" 'closing
               (conn-phase (fake-shell-state s))))))
