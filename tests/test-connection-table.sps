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
;;; 2026-09-27).  And M6.2's eleven credit rows, and M6.3's sixteen for a
;;; streamed response, from decision 0013 item 8 and plan §14: a producer's
;;; head, then each piece it is asked for, chunked to HTTP/1.1 and
;;; close-delimited to 1.0 (M3.2's carried arm), asked for only at or below
;;; decision 0005's high water, and past it, again once the bytes outstanding
;;; fall to its low water; and a failure after the head is on the wire closes
;;; with no response.  And M6.4's eight rows for `Expect: 100-continue`, from
;;; RFC 9110 §10.1.1 and decision 0013's consequences: the 100 written when
;;; the handler answers with a reader, and the body deadline armed then; and
;;; its seven for what a chunked body carries beside its data, its trailer
;;; fields held to the four header limits and its chunk extensions to 16 KiB
;;; (both decided on the owner's word, 2026-09-29).  And the padding PR's
;;; fourteen for what the parser reads and hands no span of, each event at the
;;; parser's position: the empty lines before a request line, the spaces
;;; between its parts, the whitespace before a field's value and a chunk
;;; size's digits, judged where they end and at a read's end (decided on the
;;; owner's word, 2026-09-30).  And the cut-off-span PR's four for what the
;;; parser's error cuts off, a target or a field name it never hands on,
;;; judged at the error as a read's end would have judged it (decided on the
;;; owner's word, 2026-10-01).  And M7.1's, from decision 0014 and plan §14's
;;; note of M6.2: a handler answers after the drain that asks it, so a
;;; request whose body is still arriving waits on its handler in handling,
;;; reading stopped and nothing armed, and its reader's answer reads again,
;;; with the body deadline; the rows B2 to B19, C3, S4 and E3 to E7 that
;;; answer in that wait say so.  And M8.1's, from plan §14 and design §4.4's
;;; shutdown row: told to finish, an idle connection closes at once, with no
;;; response, as at its idle deadline (decision 0011's amendment: a close
;;; with no response is at once), and one with a request in flight answers
;;; it, `Connection: close` while its head is unwritten, then lingers, as
;;; every close after a response does.  So `draining`, which only idle
;;; entered, is retired, and the states are ten.
;;;
;;; A parser-result event carries its error as the error's code, one of
;;; chez-httparse's, whose status never depends on where the parser refused
;;; (design §6.3, amended 2026-09-26).  It carries a pause's code in the same
;;; place, since a result has one or neither, and then the span the parser
;;; has open (the cut-off-span PR).
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
;; fields / limits; every field not named takes its default, and the limits
;; are decision 0005's defaults unless given.  The head
;; is the core's own, so a target (a string) is read into it the way the
;; parser delivers one, in a request line `GET target HTTP/1.1`, each event
;; at the parser's position in it and each span at its bounds, and a host (a
;; string) likewise, as a Host header line, then each of `fields`, a list of
;; (name . value) strings (M6.4).  Each of those callbacks must be
;; answered `continue` (`setup!`), so the head built is one a parse reaches.
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
      (let* ((line (b (string-append "GET " target " HTTP/1.1")))
             (end (- (bytevector-length line) 9)))
        (setup! s 'on-method-complete 3)
        (setup! s 'on-url-data line 4 end)
        (setup! s 'on-url-complete (+ end 1))
        (setup! s 'on-protocol-data line (+ end 1) (+ end 5))))
    (when host (field-line! s "Host" host))
    (for-each (lambda (f) (field-line! s (car f) (cdr f))) (get 'fields '()))
    s))

;; field-line! : ConnState String String -> Void
;; A header line `name: value` read into the head, as the parser delivers it:
;; its name's span, its name's end past the colon, then its value's span, a
;; space after the colon.
(define (field-line! s name value)
  (let ((line (b (string-append name ": " value))) (n (string-length name)))
    (setup! s 'on-header-field-data line 0 n)
    (setup! s 'on-header-field-complete (+ n 1))
    (setup! s 'on-header-value-data line (+ n 2) (bytevector-length line))
    (setup! s 'on-header-value-complete (bytevector-length line))))

;; setup! : ConnState Symbol . Payload -> Void
;; One parser callback a synthetic state is built from: one the core does
;; not answer `continue` would leave a state no parse reaches, a refusal
;; held for the next row's result to find, so it is an error here.
(define (setup! s name . payload)
  (let-values (((s actions) (apply conn-parser-step s name payload)))
    (unless (equal? (car actions) '(reply-parser continue))
      (assertion-violation 'state "a step building the state was refused" name actions))))

;; render-action : Action -> Datum
;; A write's segments are bytes, so it is rendered with each as text, a span
;; of a bytevector, `(bv start end)`, as its bytes' (M6.3); the Date slot
;; stays the symbol `date` (M3.2).
(define (render-action a)
  (if (eq? (car a) 'write)
      (list 'write
            (map (lambda (seg)
                   (cond ((bytevector? seg) (utf8->string seg))
                         ((pair? seg)
                          (let ((o (make-bytevector (- (caddr seg) (cadr seg)))))
                            (bytevector-copy! (car seg) (cadr seg) o 0 (bytevector-length o))
                            (utf8->string o)))
                         (else seg)))
                 (cadr a))
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
        (i (state 'idle 'deadline 'idle) '(parser-event on-message-begin 0)
           '(head #f ((reply-parser continue) (disarm-deadline) (arm-deadline header)))))

   (row 'H3 "head, on-header-* -> head: continue"
        (i (state 'head 'deadline 'header) `(parser-event on-header-field-data ,bv 16 20)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) '(parser-event on-header-field-complete 21)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) `(parser-event on-header-value-data ,bv 22 23)
           '(head #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header) '(parser-event on-header-value-complete 25)
           '(head #f ((reply-parser continue)))))

   ;; on-headers-complete carries the six parser fields read inside it
   ;; (0002 item 4): here llhttp's method 1 (GET), HTTP/1.1, no flags, no
   ;; content-length, and an `upgrade` of 0; and the parser's position, the
   ;; head's end, as every event callback carries it.  The head holds a target, as
   ;; every parsed one does, since the target is judged here (M2.3), and a
   ;; Host, as every HTTP/1.1 one must (RFC 9112 §3.2, 2026-09-25).
   (row 'H4 "head, on-headers-complete -> body: continue, disarm, arm body"
        (i (state 'head 'deadline 'header 'target "/" 'host "x")
           '(parser-event on-headers-complete 1 1 1 0 0 0 27)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   ;; The piece goes to the reader the handler answered with (M6.1,
   ;; decision 0013): here a streaming one, reading a body of 10 bytes.
   (row 'H5 "body, on-body-data -> body: continue, deliver-body, arm body"
        (i (reading 10 (read-body (lambda (bv from to) #t) (lambda () resp)))
           `(parser-event on-body-data ,bv 3 8)
           `(body #f ((reply-parser continue) (deliver-body ,bv 3 8) (arm-deadline body)))))

   (row 'H6 "body, on-message-complete -> handling: pause, read-stop, disarm, call-handler"
        (i (state 'body 'deadline 'body 'request req) '(parser-event on-message-complete 27)
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
        (i (state 'head 'deadline 'header 'request req) '(parser-result paused 55 55 paused-upgrade #f)
           `(handed-off #f ((read-stop) (disarm-deadline) (hand-off ,req))))
        (i (state 'body 'deadline 'body 'request req) '(parser-result paused 63 63 paused-upgrade #f)
           `(handed-off #f ((read-stop) (disarm-deadline) (hand-off ,req)))))

   ;; M8.1: told to finish, an idle connection has nothing in flight, so it
   ;; closes at once, with no response, as at its idle deadline.  A state
   ;; with a request in flight keeps its rows and closes after its response,
   ;; for a reason of its own if it has one: T10 and T11 follow one through.
   ;; A state already closing after its response, or closing, is left as it is.
   (row 'T8 "any, shutdown-requested: idle closes at once, no response; in flight, close after the response"
        (i (state 'idle 'deadline 'idle) '(shutdown-requested)
           '(closing #f ((disarm-deadline) (close shutdown))))
        (i (state 'head 'deadline 'header) '(shutdown-requested)
           '(head shutdown ()))
        (i (state 'body 'deadline 'body 'request post) '(shutdown-requested)
           '(body shutdown ()))
        (i (withheld 10 '(3 8)) '(shutdown-requested)
           '(awaiting-credit shutdown ()))
        (i (state 'handling 'request req) '(shutdown-requested)
           '(handling shutdown ()))
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100) '(shutdown-requested)
           '(responding shutdown ()))
        (i (streaming 'chunked) '(shutdown-requested)
           '(responding shutdown ()))
        (i (state 'handling 'request req 'close-after 'not-keep-alive) '(shutdown-requested)
           '(handling not-keep-alive ()))
        (i (state 'lingering 'deadline 'linger 'close-after 'headers-too-large) '(shutdown-requested)
           '(lingering headers-too-large ()))
        (i (state 'closing) '(shutdown-requested)
           '(closing #f ())))

   (row 'T9 "closing, closed -> closed"
        (i (state 'closing) '(closed)
           '(closed #f ())))

   ;; The request in flight is answered as any is, saying it closes, since
   ;; its head is not yet written (decision 0010 items 2 and 3).
   (row 'T10 "told to finish, handling, handler-responded -> responding: the response says Connection: close"
        (i (after (state 'handling 'request req) '(shutdown-requested)) `(handler-responded ,resp)
           `(responding shutdown (,answered-closing (arm-deadline write)))))

   ;; Its last write's completion is followed by the staged close, the
   ;; pipelined rest dropped (decision 0004 item 4; decision 0011).
   (row 'T11 "told to finish, responding, last write-completed -> lingering: shutdown, read-start, arm linger"
        (i (after (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100
                         'pending (list bv 10 20))
                  '(shutdown-requested))
           '(write-completed 100)
           '(lingering shutdown ((shutdown) (read-start) (arm-deadline linger)))))

   ;; A request only the shell's own close cancels: a close from outside the
   ;; core, at a drain's deadline or for a bug, cancels the write or the
   ;; half-close outstanding, which reports ECANCELED.  That is no transport
   ;; failure, so the core closes as for one, and logs nothing (M8.1's
   ;; review).
   (row 'T12 "any live state, read-error ECANCELED -> closing: disarm, close, no log"
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 100)
           '(read-error ECANCELED)
           '(closing #f ((disarm-deadline) (close cancelled))))
        (i (state 'lingering 'deadline 'linger 'close-after 'shutdown) '(read-error ECANCELED)
           '(closing shutdown ((disarm-deadline) (close cancelled)))))))

;; ---------------------------------------------------------------------------
;; Decision 0004's pause protocol: three rows (M2.4).  Design §4.4 folds the
;; first into H6, "retain pending-input", but the core cannot keep the
;; remainder at on-message-complete: the parser says where it stopped,
;; `parser-result-next`, only when the feed has returned.  So the result that
;; follows the pause keeps the rest of the delivery the core fed, and these
;; rows' outcomes show what is kept.

;; paused : Nat Nat CloseAfter -> ConnState
;; A connection that fed the parser the delivery bv[from, to) and was paused
;; by its own answer to on-message-complete, 18 bytes in: in handling, its
;; result to come.
(define (paused from to close-after)
  (let ((s (state 'body 'deadline 'body 'request req 'close-after close-after)))
    (conn-step s `(bytes-arrived ,bv ,from ,to))
    (conn-step s '(parser-event on-message-complete 18))
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
           '(parser-event on-headers-complete 5 1 1 0 0 1 49)
           '(body upgrade ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat" 'host "x")
           `(parser-event on-headers-complete 1 1 1 ,upgrade-flags 0 1 49)
           '(body upgrade ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat")
           `(parser-event on-headers-complete 1 1 0 ,upgrade-flags 0 1 49)
           '(body not-keep-alive ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/chat" 'host "x")
           `(parser-event on-headers-complete 1 1 1 ,upgrade-flags 0 0 49)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "example.com:443" 'host "example.com:443")
           '(parser-event on-headers-complete 5 1 1 0 0 0 49)
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
;; and linger deadlines; D1 and D2 act on the other two.  (D3 acted on the
;; idle deadline a draining connection carried, until M8.1 retired the
;; state.)  A body that stalls past its inactivity deadline is answered 408, as a head that stalls is, framed for
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
;; M7.1 (decision 0014): the answer comes after the drain that asks for it,
;; so a request asked about with its body still to come waits on its handler
;; in handling, reading stopped and nothing armed (plan §14's note of M6.2),
;; and a reader's answer reads again, with the body deadline.

;; announced : (U Nat 'chunked) [Limits] -> ConnState
;; A POST whose head, just complete, announced a body of `n` bytes by
;; Content-Length, or a chunked one: in body, its handler to be asked.  The
;; head ends at the parser's position 46, and a chunked body's first size
;; line, `1` and its line end, at 49, where the feed that completed the head
;; returns.
(define (announced framing . limits)
  (let ((s (apply state 'head 'deadline 'header 'target "/" 'host "x"
                  (if (null? limits) '() (list 'limits (car limits))))))
    (head-complete! s framing)
    s))

;; head-complete! : ConnState (U Nat 'chunked) -> Void
;; A POST's head completes at 46, announcing its body; a chunked one's
;; first size line is read, as the parser reads one before any of its data.
(define (head-complete! s framing)
  (if (eq? framing 'chunked)
      (begin
        (conn-step s `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0 46))
        (conn-step s '(parser-event on-chunk-header 49)))
      (conn-step s `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH ,framing 0 46))))

;; met : ConnState (Listof (List Nat Nat)) -> ConnState
;; The same state, having met `pieces`, each bv[from, to), as body data.
(define (met s pieces)
  (for-each (lambda (p) (conn-step s `(parser-event on-body-data ,bv ,(car p) ,(cadr p)))) pieces)
  s)

;; asked : (U Nat 'chunked) . Piece -> ConnState
;; A POST that met `pieces` in the feed that completed its head, which has
;; returned and asked its handler: in handling, its body still to come.
(define (asked framing . pieces)
  (let ((s (met (announced framing) pieces)))
    (conn-step s '(parser-result need-input 49 49 #f #f))
    s))

;; reading : (U Nat 'chunked) BodyReader -> ConnState
;; The same, with no piece met, its handler having answered with `reader`:
;; in body, reading again.
(define (reading framing reader)
  (let ((s (asked framing)))
    (conn-step s `(handler-responded ,reader))
    s))

;; ended : (U Nat 'chunked) . Piece -> ConnState
;; A POST whose head and whole body, `pieces`, came in one feed: paused at
;; the message's end, its handler to be asked.
(define (ended framing . pieces)
  (let ((s (met (announced framing) pieces)))
    (conn-step s '(parser-event on-message-complete 54))
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
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (state 'head 'deadline 'header 'target "/" 'host "x")
           `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   (row 'B2 "body or handling, the feed that completed the head returns -> handling: read-stop, disarm, call-handler; or the body ended in it, call-handler"
        (i (announced 10) '(parser-result need-input 49 49 #f #f)
           '(handling #f ((read-stop) (disarm-deadline) (call-handler POST))))
        (i (ended 5 '(3 8)) '(parser-result paused 54 54 #f #f)
           '(handling #f ((call-handler POST)))))

   (row 'B3 "body, on-body-data in the head's feed, before the handler is asked -> body: continue, arm body, the piece kept"
        (i (announced 10) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser continue) (arm-deadline body)))))

   (row 'B4 "handling, the body still to come, handler-responded with a streaming reader -> body: the pieces kept, handed over in order, then read-start, arm body"
        (i (asked 10 '(3 5) '(5 8)) `(handler-responded ,streamer)
           `(body #f ((deliver-body ,bv 3 5) (deliver-body ,bv 5 8) (read-start) (arm-deadline body)))))

   (row 'B5 "handling, the message ended in the head's feed, handler-responded with a streaming reader -> handling: the pieces kept, then deliver-body-end"
        (let ((s (ended 5 '(3 8))))
          (conn-step s '(parser-result paused 54 54 #f #f))
          (i s `(handler-responded ,streamer)
             `(handling #f ((deliver-body ,bv 3 8) (deliver-body-end))))))

   (row 'B6 "handling, the body still to come, handler-responded with a whole reader -> body: the pieces kept buffered, read-start, arm body"
        (i (asked 10 '(3 8)) `(handler-responded ,(whole-reader))
           '(body #f ((read-start) (arm-deadline body)))))

   (row 'B7 "body, on-body-data, a whole reader reading -> body: continue, arm body, the piece buffered"
        (i (reading 10 (whole-reader)) `(parser-event on-body-data ,bv 3 8)
           '(body #f ((reply-parser continue) (arm-deadline body)))))

   (row 'B8 "body, on-message-complete, a streaming reader reading -> handling: pause, read-stop, disarm, deliver-body-end"
        (i (reading 10 streamer) '(parser-event on-message-complete 59)
           '(handling #f ((reply-parser pause) (read-stop) (disarm-deadline) (deliver-body-end)))))

   ;; The body, "GET /" and " HTTP" of the delivery, whole in a bytevector
   ;; of its own.
   (row 'B9 "body, on-message-complete, a whole reader reading -> handling: pause, read-stop, disarm, the body as one piece, deliver-body-end"
        (let ((s (met (reading 10 (whole-reader)) '((0 5) (5 10)))))
          (i s '(parser-event on-message-complete 59)
             `(handling #f ((reply-parser pause) (read-stop) (disarm-deadline)
                            (deliver-body ,(b "GET / HTTP") 0 10) (deliver-body-end))))))

   (row 'B10 "handling, handler-responded with the reader's response -> responding: write, arm write"
        (let ((s (reading 10 streamer)))
          (conn-step s '(parser-event on-message-complete 59))
          (i s `(handler-responded ,resp)
             `(responding #f (,(written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\n\r\n" "row H7")
                              (arm-deadline write))))))

   ;; Item 4: sent at once, and the connection closes after it, whether the
   ;; body is still arriving or came whole with the head.  Either way the
   ;; request waited on its handler with reading stopped (M7.1).
   (row 'B11 "handling, handler-responded with a response to a request that announced a body -> responding, close-after unread-body"
        (i (asked 10) `(handler-responded ,resp)
           `(responding unread-body (,answered-closing (arm-deadline write))))
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
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
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
   (row 'B15 "handling, handler-responded with a reader whose cap the body passes -> responding 413, close-after"
        (i (asked 10) `(handler-responded ,(whole-reader 5))
           `(responding body-too-large (,(status-write 413 "Content Too Large") (arm-deadline write))))
        (i (asked 'chunked '(3 8)) `(handler-responded ,(whole-reader 4))
           `(responding body-too-large (,(status-write 413 "Content Too Large") (arm-deadline write)))))

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

   (row 'B19 "handling or body, handler-failed -> responding 500, close-after; read-stop from body, where a reader reads"
        (i (asked 10) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (arm-deadline write))))
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

   (row 'C3 "handling, the body still to come, handler-responded with a reader on credit -> the pieces kept handed over, then awaiting-credit, reading stopped already; or none kept, body: read-start, arm body"
        (i (asked 10 '(3 5) '(5 8)) `(handler-responded ,streamer credit)
           `(awaiting-credit #f ((deliver-body ,bv 3 5) (deliver-body ,bv 5 8))))
        (i (asked 10) `(handler-responded ,streamer credit)
           '(body #f ((read-start) (arm-deadline body)))))

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
          (conn-step s '(parser-event on-message-complete 59))
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

;; ---------------------------------------------------------------------------
;; M6.3: a streamed response, nineteen rows (decision 0013 item 8; plan §14).
;; A response whose body is a producer is written as its head, then a piece
;; at a time: `notify-producer` asks the shell to call the producer, whose
;; answer comes back as `handler-body-chunk` or `handler-body-end`, or as
;; `handler-failed` if it raised.  Each piece is a write of its own, chunked
;; to HTTP/1.1 and close-delimited to 1.0 (the serializer's).  The producer
;; is asked only while the bytes outstanding are at or below the high water,
;; so at most one piece passes it, and while fewer than 64 writes are, since
;; a write costs the same whatever its size (M6.3's second review); past
;; either, the producer waits until completions bring the bytes to the low
;; water and the writes to 16.  The head alone may pass the high water.  A
;; failure once the head is on the wire gets a bare close, since a status
;; can no longer be written.  The states are reached by steps, from a GET in
;; handling.  The heads are 84 bytes chunked and 75 close-delimited, as H7's
;; is 60 with its Content-Length: the status line 17, the Date slot 37, then
;; the header block.

(define (producer) (eof-object))
(define streamed-resp (make-response 200 #f '() producer))
(define req10 (make-request 'GET (b "/") 1 0 '() #f))
(define hello (b "hello"))

;; waters : Nat Nat -> Limits — decision 0005's, with these water marks.
(define (waters high low)
  (limits-with default-limits (list (cons 'write-high-water high) (cons 'write-low-water low))))

;; streaming : (U 'chunked 'close-delimited) [Limits] -> ConnState
;; A GET, HTTP/1.1 for chunked and 1.0 for close-delimited, answered with a
;; producer: its head written, and the producer asked for a piece.
(define (streaming framing . limits)
  (let ((s (apply state 'handling 'request (if (eq? framing 'chunked) req req10)
                  (if (null? limits) '() (list 'limits (car limits))))))
    (conn-step s `(handler-responded ,streamed-resp))
    s))

;; waiting : Limits -> ConnState
;; The same, chunked, under `limits`, whose high water is 84, the head's
;; bytes: a 5-byte piece, 10 bytes framed, took the bytes outstanding past
;; it, 94 in two writes, so the producer waits.
(define (waiting limits)
  (let ((s (streaming 'chunked limits)))
    (conn-step s `(handler-body-chunk ,hello 0 5))
    s))

;; asked-after : Nat -> ConnState
;; The stream of `streaming`, chunked, under decision 0005's marks, after
;; `n` pieces of 5 bytes, each written in 10: 1 + n writes outstanding and
;; 84 + 10n bytes, far below the high water, the producer asked again.
(define (asked-after n)
  (let ((s (streaming 'chunked)))
    (do ((k 0 (+ k 1))) ((= k n) s)
      (conn-step s `(handler-body-chunk ,hello 0 5)))))

;; stalled : Nat -> ConnState
;; The same after 63 pieces, 64 writes outstanding, so the producer waits;
;; then the head's completion, and the pieces' until `n` writes are left,
;; each of the bytes its write counted, 84 and 10, read from the state, so
;; that building this state never raises where a row is to fail.
(define (stalled n)
  (let* ((head (conn-outstanding-bytes (streaming 'chunked)))
         (s (asked-after 63))
         (piece (div (- (conn-outstanding-bytes s) head) 63)))
    (conn-step s `(write-completed ,head))
    (do ((left 63 (- left 1))) ((= left n) s)
      (conn-step s `(write-completed ,piece)))))

;; produced : ConnState Event -> (U (List Phase CloseAfter (Listof Datum) Boolean) 'refused 'crashed)
;; One step's outcome, and whether a producer is left to write from after
;; it; or 'refused when the core refuses the event, an assertion violation
;; of its own, and 'crashed for one raised by anything else.
(define (produced s ev)
  (guard (e ((assertion-violation? e)
             (if (and (who-condition? e) (eq? (condition-who e) 'conn-step)) 'refused 'crashed)))
    (let* ((o (outcome s ev)) (left (and (conn-producer s) #t)))
      (append o (list left)))))

(define chunked-head (written "HTTP/1.1 200 OK\r\n" 'date "Transfer-Encoding: chunked\r\n\r\n"))
(define closing-head (written "HTTP/1.1 200 OK\r\n" 'date "Connection: close\r\n\r\n"))

(define (stream-rows)
  (list
   (row 'S1 "handling, handler-responded with a producer, HTTP/1.1 -> responding: the head chunked, arm write, notify-producer"
        (i (state 'handling 'request req) `(handler-responded ,streamed-resp)
           `(responding #f (,chunked-head (arm-deadline write) (notify-producer)) #t)))

   ;; M3.2's carried arm: a close-delimited body ends only with the
   ;; connection (RFC 9112 §6.3 rule 8), so the connection closes after it,
   ;; and its head says so, though the request would have kept it.
   (row 'S2 "handling, handler-responded with a producer, HTTP/1.0 -> responding, close-after close-delimited: the head with Connection: close, arm write, notify-producer"
        (i (state 'handling 'request req10) `(handler-responded ,streamed-resp)
           `(responding close-delimited (,closing-head (arm-deadline write) (notify-producer)) #t)))

   ;; No body is written to a HEAD, a 204 or a 304, so the producer is never
   ;; called, and a HEAD's answer announces no length, which is unknown.
   (row 'S3 "handling, handler-responded with a producer where no body is written -> responding: the head alone, arm write; the producer never asked"
        (i (state 'handling 'request head-req) `(handler-responded ,streamed-resp)
           `(responding #f (,(written "HTTP/1.1 200 OK\r\n" 'date "\r\n") (arm-deadline write)) #f))
        (i (state 'handling 'request req) `(handler-responded ,(make-response 204 #f '() producer))
           `(responding #f (,(written "HTTP/1.1 204 No Content\r\n" 'date "\r\n") (arm-deadline write)) #f)))

   ;; Decision 0013 item 4: a response given instead of a reader closes the
   ;; connection after it, the body unread, a streamed one too.
   (row 'S4 "handling, handler-responded with a producer instead of a reader -> responding, close-after unread-body: the head, arm write, notify-producer"
        (i (asked 10) `(handler-responded ,streamed-resp)
           `(responding unread-body
                        (,(written "HTTP/1.1 200 OK\r\n" 'date
                                   "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
                         (arm-deadline write) (notify-producer))
                        #t)))

   (row 'S5 "responding, handler-body-chunk asked for, at or below high water -> responding: write the piece, arm write, notify-producer"
        (i (streaming 'chunked) `(handler-body-chunk ,hello 0 5)
           `(responding #f (,(written "5\r\n" "hello" "\r\n") (arm-deadline write) (notify-producer)) #t))
        (i (streaming 'chunked) `(handler-body-chunk ,bv 3 8)
           `(responding #f (,(written "5\r\n" " / HT" "\r\n") (arm-deadline write) (notify-producer)) #t))
        (i (streaming 'close-delimited) `(handler-body-chunk ,hello 0 5)
           `(responding close-delimited (,(written "hello") (arm-deadline write) (notify-producer)) #t)))

   ;; Under a high water of 84 the head is at it, 84 outstanding, so the
   ;; producer is asked, and its first piece passes it.  Under 83 the head
   ;; alone passes it, and the producer waits before its first piece.
   (row 'S6 "responding, a write past high water -> responding: write, arm write; the producer waits"
        (i (streaming 'chunked (waters 84 20)) `(handler-body-chunk ,hello 0 5)
           `(responding #f (,(written "5\r\n" "hello" "\r\n") (arm-deadline write)) #t))
        (i (state 'handling 'request req 'limits (waters 83 20)) `(handler-responded ,streamed-resp)
           `(responding #f (,chunked-head (arm-deadline write)) #t)))

   ;; Waiting with 94 outstanding in two writes: the head's completion
   ;; leaves 10, at or below a low water of 20, or of 10, and the producer
   ;; goes on, the piece's write still outstanding; at a low water of 0 the
   ;; last completion leaves none, so no deadline stays armed while the
   ;; producer is asked (S16).
   (row 'S7 "responding, waiting, a completion to low water or below -> responding: arm write (or disarm, none outstanding), notify-producer"
        (i (waiting (waters 84 20)) '(write-completed 84)
           '(responding #f ((arm-deadline write) (notify-producer)) #t))
        (i (waiting (waters 84 10)) '(write-completed 84)
           '(responding #f ((arm-deadline write) (notify-producer)) #t))
        (let ((s (waiting (waters 84 0))))
          (conn-step s '(write-completed 84))
          (i s '(write-completed 10)
             '(responding #f ((disarm-deadline) (notify-producer)) #t))))

   (row 'S8 "responding, waiting, a completion above low water -> responding: arm write; the producer still waits"
        (i (waiting (waters 84 9)) '(write-completed 84)
           '(responding #f ((arm-deadline write)) #t)))

   ;; RFC 9112 §7.1's last chunk ends a chunked body; the response is written
   ;; once it completes, as any response is (H9, H10).
   (row 'S9 "responding, handler-body-end, chunked -> responding: write the last chunk, arm write; the producer let go"
        (i (streaming 'chunked) '(handler-body-end)
           `(responding #f (,(written "0\r\n\r\n") (arm-deadline write)) #f)))

   (row 'S10 "responding, handler-body-end, close-delimited, writes outstanding -> responding: nothing; the producer let go"
        (i (streaming 'close-delimited) '(handler-body-end)
           '(responding close-delimited () #f)))

   ;; The close ends a close-delimited body, so with every write completed
   ;; the response is written at its end, and closes in stages (decision
   ;; 0011): the half-close is the end the client reads.
   (row 'S11 "responding, handler-body-end, close-delimited, nothing outstanding -> lingering: shutdown, read-start, arm linger"
        (let ((s (streaming 'close-delimited)))
          (conn-step s '(write-completed 75))
          (i s '(handler-body-end)
             '(lingering close-delimited ((shutdown) (read-start) (arm-deadline linger)) #f))))

   ;; Design §4.4's handler-failed row: a bare close once the head is on the
   ;; wire.  The shell logs the failure as it logs a handler's.  A failure
   ;; while no piece is asked for, a reader's raised late (B19), changes
   ;; nothing.
   (row 'S12 "responding, handler-failed with a piece asked for -> closing: disarm, close, no response"
        (i (streaming 'chunked) '(handler-failed boom)
           '(closing #f ((disarm-deadline) (close handler-failed)) #f))
        (i (waiting (waters 84 20)) '(handler-failed boom)
           '(responding #f () #t)))

   ;; A producer's answer is a piece of a byte or more (producer-event): an
   ;; empty one is the producer failing, since asking again at once would
   ;; hold the loop for as long as it had nothing (M6.3's review).  So a
   ;; piece of no bytes is the shell's bug, as a piece not asked for is.
   (row 'S13 "responding, handler-body-chunk of no bytes: refused"
        (i (streaming 'chunked) `(handler-body-chunk ,hello 2 2) 'refused))

   ;; A piece or an end the core did not ask for is the shell's bug, as a
   ;; completion the core did not ask for is (M3.3).
   (row 'S14 "responding, handler-body-chunk or handler-body-end not asked for: refused"
        (i (waiting (waters 84 20)) `(handler-body-chunk ,hello 0 5) 'refused)
        (i (waiting (waters 84 20)) '(handler-body-end) 'refused)
        (i (state 'responding 'deadline 'write 'outstanding 1 'outstanding-bytes 60)
           '(handler-body-end) 'refused))

   ;; Once the connection has let the producer go, a piece asked for before
   ;; changes nothing.
   (row 'S15 "closing, handler-body-chunk or handler-body-end -> closing: nothing"
        (let ((s (streaming 'chunked)))
          (conn-step s '(read-error EPIPE))
          (i s `(handler-body-chunk ,hello 0 5) '(closing #f () #f)))
        (let ((s (streaming 'chunked)))
          (conn-step s '(read-error EPIPE))
          (i s '(handler-body-end) '(closing #f () #f))))

   ;; A completion while the producer's answer is to come: the write
   ;; deadline stays armed while a write is outstanding, and with none, none
   ;; is: the producer is the one waited on, and decision 0005 has no
   ;; deadline for a handler.
   (row 'S16 "responding, a completion while a piece is asked for -> responding: arm write, or disarm with none outstanding"
        (let ((s (streaming 'chunked)))
          (conn-step s `(handler-body-chunk ,hello 0 5))
          (i s '(write-completed 84)
             '(responding #f ((arm-deadline write)) #t)))
        (i (streaming 'chunked) '(write-completed 84)
           '(responding #f ((disarm-deadline)) #t)))

   ;; The producer is asked only at or below the high water, whatever the
   ;; low water: limits-with, unlike the environment, accepts one above it
   ;; (M6.3's review).  Under a high water of 90 and a low of 200, a piece
   ;; takes the bytes outstanding to 94, past the high water; a completion
   ;; of 2 leaves 92, at or below the low water, still past the high.
   (row 'S17 "responding, waiting, a completion at or below the low water, still past the high -> responding: arm write; the producer still waits"
        (i (waiting (waters 90 200)) '(write-completed 2)
           '(responding #f ((arm-deadline write)) #t)))

   ;; Each piece is a write of its own, and a write holds the loop and
   ;; memory the same whatever its size, so the producer is asked only while
   ;; fewer than 64 writes are outstanding too (M6.3's second review): the
   ;; head and 62 pieces leave 63, and it is asked; one more leaves 64, far
   ;; below the high water, and it waits.
   (row 'S18 "responding, a piece that leaves 64 writes outstanding, below the high water -> responding: write, arm write; the producer waits"
        (i (asked-after 61) `(handler-body-chunk ,hello 0 5)
           `(responding #f (,(written "5\r\n" "hello" "\r\n") (arm-deadline write) (notify-producer)) #t))
        (i (asked-after 62) `(handler-body-chunk ,hello 0 5)
           `(responding #f (,(written "5\r\n" "hello" "\r\n") (arm-deadline write)) #t)))

   ;; Waiting at 64 writes, the producer is asked again once a completion
   ;; leaves 16 or fewer, the bytes at or below the low water as they are here.
   (row 'S19 "responding, waiting at 64 writes, a completion to 16 -> responding: arm write, notify-producer; to 17, the producer still waits"
        (i (stalled 17) '(write-completed 10)
           '(responding #f ((arm-deadline write) (notify-producer)) #t))
        (i (stalled 18) '(write-completed 10)
           '(responding #f ((arm-deadline write)) #t)))))

;; ---------------------------------------------------------------------------
;; M6.4: Expect: 100-continue (plan §14; decision 0013's consequences).  A
;; client that sends `Expect: 100-continue` with a head that announces a
;; body may wait for `100 Continue` before it sends the body (RFC 9110
;; §10.1.1).  Answering with a reader is pulling the body, so the 100 is
;; written then, before anything else the answer brings, however much of the
;; body has arrived, so what happens does not depend on the reads (design
;; §8.1's second property).  Until then the server is the one waiting, so
;; the head arms no body deadline, and the 100 arms it (plan §14's note of
;; 2026-09-27); a piece the client sends without waiting arms it too, as any
;; piece does.  A response instead of a reader, a reader whose cap the
;; declared length passes, and a handler that raises write their final status
;; and no 100.  The expectation is ignored on HTTP/1.0, as RFC 9110 §10.1.1
;; says it must be, on a request with no body, and when it is not
;; 100-continue (decided on the owner's word, 2026-09-29).  The value is
;; matched without regard to case, as a member of its list.

;; expecting : (U Nat 'chunked) String -> ConnState
;; A POST whose head carries `Expect: value` and, just complete, announced a
;; body of `framing`: in body, its handler to be asked.
(define (expecting framing value)
  (let ((s (state 'head 'deadline 'header 'target "/" 'host "x"
                  'fields (list (cons "Expect" value)))))
    (head-complete! s framing)
    s))

;; expected : (U Nat 'chunked) . Piece -> ConnState
;; A POST expecting 100-continue that met `pieces` in the feed that
;; completed its head, which has returned and asked its handler.
(define (expected framing . pieces)
  (let ((s (met (expecting framing "100-continue") pieces)))
    (conn-step s '(parser-result need-input 49 49 #f #f))
    s))

;; ended-expecting : -> ConnState
;; A POST expecting 100-continue whose head and whole 5-byte body came in one
;; feed, which has returned and asked its handler.
(define (ended-expecting)
  (let ((s (met (expecting 5 "100-continue") '((3 8)))))
    (conn-step s '(parser-event on-message-complete 54))
    (conn-step s '(parser-result paused 54 54 #f #f))
    s))

;; The 100 as render-action shows it: its status line and the blank line,
;; with no Date, which a 1xx may leave out (RFC 9110 §6.6.1), and no field.
(define continue-write (written "HTTP/1.1 100 Continue\r\n\r\n"))

;; head-expecting : String -> ConnState
;; A POST head, not yet complete, whose fields hold `Expect: value`.
(define (head-expecting value)
  (state 'head 'deadline 'header 'target "/" 'host "x" 'fields (list (cons "Expect" value))))

(define (expect-rows)
  (list
   ;; The value's case is not the client's to get right, and an expectation
   ;; is a member of the field's list, which may run over two lines.
   (row 'E1 "head, on-headers-complete announcing a body, expecting 100-continue, HTTP/1.1 -> body: continue, disarm; no deadline until the 100"
        (i (head-expecting "100-continue") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline))))
        (i (head-expecting "100-continue") `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline))))
        (i (head-expecting "100-Continue") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline))))
        (i (state 'head 'deadline 'header 'target "/" 'host "x"
                  'fields '(("expect" . "foo, 100-continue")))
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline))))
        (i (state 'head 'deadline 'header 'target "/" 'host "x"
                  'fields '(("Expect" . "foo") ("Expect" . " 100-continue ")))
           `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline)))))

   ;; RFC 9110 §10.1.1: HTTP/1.0's is ignored, and so is one with no body to
   ;; wait for; another expectation is ignored, on the owner's word.
   (row 'E2 "head, on-headers-complete where 100-continue does not apply -> body: continue, disarm, arm body"
        (i (head-expecting "100-continue") `(parser-event on-headers-complete 3 1 0 ,F-CONTENT-LENGTH 10 0 46)
           '(body not-keep-alive ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (head-expecting "100-continue") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 0 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (head-expecting "200-ok") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (head-expecting "100-continues") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body))))
        (i (head-expecting "") `(parser-event on-headers-complete 3 1 1 ,F-CONTENT-LENGTH 10 0 46)
           '(body #f ((reply-parser continue) (disarm-deadline) (arm-deadline body)))))

   (row 'E3 "handling, the body still to come, handler-responded with a reader, expecting 100-continue -> body: write the 100, then the pieces kept, read-start, arm body"
        (i (expected 10) `(handler-responded ,streamer)
           `(body #f (,continue-write (read-start) (arm-deadline body))))
        (i (expected 10 '(3 5) '(5 8)) `(handler-responded ,streamer)
           `(body #f (,continue-write (deliver-body ,bv 3 5) (deliver-body ,bv 5 8)
                                      (read-start) (arm-deadline body))))
        (i (expected 10 '(3 8)) `(handler-responded ,(whole-reader))
           `(body #f (,continue-write (read-start) (arm-deadline body)))))

   ;; The 100 though the whole body is in: had it come in a later read, the
   ;; 100 would have gone first, and the outcome is the same either way.
   (row 'E4 "handling, the body ended in the head's feed, handler-responded with a reader -> handling: write the 100, the pieces, deliver-body-end"
        (i (ended-expecting) `(handler-responded ,streamer)
           `(handling #f (,continue-write (deliver-body ,bv 3 8) (deliver-body-end))))
        (i (ended-expecting) `(handler-responded ,(whole-reader))
           `(handling #f (,continue-write (deliver-body ,(b " / HT") 0 5) (deliver-body-end)))))

   (row 'E5 "handling, handler-responded with a reader on credit -> write the 100, the pieces kept, then awaiting-credit, reading stopped already"
        (i (expected 10 '(3 5) '(5 8)) `(handler-responded ,streamer credit)
           `(awaiting-credit #f (,continue-write (deliver-body ,bv 3 5) (deliver-body ,bv 5 8)))))

   ;; What the head's feed met waits for the answer, and the 100 still goes
   ;; first, as it would have had the body come in a later read: an error
   ;; kept, or a body met past the reader's own cap, in body or, the body
   ;; ended, in handling (M6.4's review).
   (row 'E6 "handling, an error kept or a body met past the reader's cap, handler-responded with a reader -> responding: the 100, the pieces, then the status"
        (let ((s (met (expecting 'chunked "100-continue") '((3 8)))))
          (conn-step s '(parser-result error 60 60 invalid-chunk-size #f))
          (i s `(handler-responded ,streamer)
             `(responding parser-error (,continue-write (deliver-body ,bv 3 8)
                                        ,(status-write 400 "Bad Request") (arm-deadline write)))))
        (i (expected 'chunked '(3 8)) `(handler-responded ,(whole-reader 4))
           `(responding body-too-large (,continue-write ,(status-write 413 "Content Too Large")
                                        (arm-deadline write))))
        (let ((s (met (expecting 'chunked "100-continue") '((3 8)))))
          (conn-step s '(parser-event on-message-complete 54))
          (conn-step s '(parser-result paused 54 54 #f #f))
          (i s `(handler-responded ,(whole-reader 4))
             `(responding body-too-large (,continue-write ,(status-write 413 "Content Too Large")
                                          (arm-deadline write))))))

   (row 'E7 "handling, a response instead of a reader, a reader whose cap the declared length passes, or handler-failed -> responding: the final status, no 100"
        (i (expected 10) `(handler-responded ,resp)
           `(responding unread-body (,answered-closing (arm-deadline write))))
        (i (expected 10) `(handler-responded ,(whole-reader 5))
           `(responding body-too-large (,(status-write 413 "Content Too Large") (arm-deadline write))))
        (i (expected 10) '(handler-failed boom)
           `(responding handler-failed (,(status-write 500 "Internal Server Error") (arm-deadline write)))))))

;; The 100 is a write like any other, outstanding until it completes (M3.3's
;; accounting, which these rows are run through): in a state that reads, or
;; waits for the reader, its completion settles it and changes nothing else,
;; and once the response follows it, the response's completion is the last.
(define (continue-accounting-rows)
  (list
   (row 'E8 "body, handling, awaiting-credit or responding, write-completed for the 100 -> the same: nothing more, the 100 no longer outstanding"
        (let ((s (expected 10)))
          (conn-step s `(handler-responded ,streamer))
          (i s '(write-completed 25) '(body #f () 0 0)))
        (let ((s (ended-expecting)))
          (conn-step s `(handler-responded ,streamer))
          (i s '(write-completed 25) '(handling #f () 0 0)))
        (let ((s (expected 10 '(3 8))))
          (conn-step s `(handler-responded ,streamer credit))
          (i s '(write-completed 25) '(awaiting-credit #f () 0 0)))
        (let ((s (ended-expecting))
              (w (written "HTTP/1.1 200 OK\r\n" 'date "Content-Length: 6\r\n\r\n" "row H7")))
          (conn-step s `(handler-responded ,streamer))
          (conn-step s `(handler-responded ,resp))
          (i s '(write-completed 25) `(responding #f ((arm-deadline write)) 1 ,(nbytes w)))))))

;; ---------------------------------------------------------------------------
;; M6.4: what a chunked body carries beside its data is held to limits
;; (decided on the owner's word, 2026-09-29).  Its trailer fields, which the
;; parser delivers as header callbacks once the last chunk is read (the
;; ledger, M2), are held to the four header limits, as a head is, counted
;; afresh, so the head's fields leave the trailers theirs; none is kept.
;; Its chunk extensions, their names' and values' bytes and a byte as each
;; ends, for the `;` or `=` before it, all of a body's together, are held to
;; 16 KiB, fixed, as hyper and Node hold theirs.  One
;; past a limit is refused as a head's field is, `(reply-parser (fail
;; reason))`, and the parser's error that follows is answered with the
;; reason's status: a trailer's the head's 431, the extensions' 413, as a
;; body past a cap.

;; tight : Limits — header limits small enough to pass in a row: a name or a
;; value of 4 bytes, 10 bytes in all, and 2 fields.
(define tight
  (limits-with default-limits
               '((max-header-field-bytes . 4) (max-header-value-bytes . 4)
                 (max-header-bytes . 10) (max-header-count . 2))))

;; Bytes for a trailer's or an extension's span, a letter each.
(define big (make-bytevector 20000 97))

;; trailing : Limits . (Pair String String) -> ConnState
;; A chunked POST under `limits`, its head holding Host: x and `fields`,
;; with its streaming reader reading.
(define (trailing limits . fields)
  (let ((s (state 'head 'deadline 'header 'target "/" 'host "x" 'fields fields 'limits limits)))
    (head-complete! s 'chunked)
    (conn-step s '(parser-result need-input 49 49 #f #f))
    (conn-step s `(handler-responded ,streamer))
    s))

;; trailer : ConnState Nat Nat -> ConnState
;; The same, having met a trailer field whose name is `name` bytes and whose
;; value is `value`, with no space between them: every span and event is at
;; the start of `big`.
(define (trailer s name value)
  (conn-step s `(parser-event on-header-field-data ,big 0 ,name))
  (conn-step s '(parser-event on-header-field-complete 0))
  (conn-step s `(parser-event on-header-value-data ,big 0 ,value))
  (conn-step s '(parser-event on-header-value-complete 0))
  s)

;; extended : Nat ... -> ConnState
;; A chunked POST, its streaming reader reading, that met an extension name
;; of each of `sizes` bytes, one a chunk: n + 1 bytes each, counted with the
;; `;` its end stands for.
(define (extended . sizes)
  (let ((s (reading 'chunked streamer)))
    (for-each (lambda (n)
                (conn-step s `(parser-event on-chunk-extension-name-data ,big 0 ,n))
                (conn-step s '(parser-event on-chunk-extension-name-complete 0))
                (conn-step s '(parser-event on-chunk-header 0))
                (conn-step s '(parser-event on-chunk-complete 0)))
              sizes)
    s))

(define max-extensions 16384)

(define (framing-rows)
  (list
   (row 'F1 "body, a trailer field within the four header limits -> body: continue, nothing kept"
        (i (trailing tight) `(parser-event on-header-field-data ,big 0 4)
           '(body #f ((reply-parser continue))))
        (i (trailing tight) '(parser-event on-header-field-complete 0)
           '(body #f ((reply-parser continue))))
        (let ((s (trailing tight)))
          (conn-step s `(parser-event on-header-field-data ,big 0 1))
          (conn-step s '(parser-event on-header-field-complete 0))
          (i s `(parser-event on-header-value-data ,big 0 4)
             '(body #f ((reply-parser continue)))))
        (i (trailer (trailing tight) 1 4) '(parser-event on-header-value-complete 0)
           '(body #f ((reply-parser continue)))))

   (row 'F2 "body, a trailer field past one of the four header limits -> body: fail, for the head's reason"
        (i (trailing tight) `(parser-event on-header-field-data ,big 0 5)
           '(body #f ((reply-parser (fail header-field-too-large)))))
        (let ((s (trailing tight)))
          (conn-step s `(parser-event on-header-field-data ,big 0 1))
          (conn-step s '(parser-event on-header-field-complete 0))
          (i s `(parser-event on-header-value-data ,big 0 5)
             '(body #f ((reply-parser (fail header-value-too-large))))))
        (i (trailer (trailing tight) 4 4) `(parser-event on-header-field-data ,big 0 3)
           '(body #f ((reply-parser (fail headers-too-large)))))
        (i (trailer (trailer (trailing tight) 1 1) 1 1) '(parser-event on-header-field-complete 0)
           '(body #f ((reply-parser (fail too-many-headers))))))

   ;; The head holds 2 fields, 10 bytes with the space after each colon, at
   ;; the tight limits' edge; its trailers may hold as many again.
   (row 'F3 "body, trailer fields after a head at the limits -> body: continue; the trailers are counted on their own"
        (i (trailer (trailing tight '("Ab" . "c")) 4 4) `(parser-event on-header-field-data ,big 0 1)
           '(body #f ((reply-parser continue))))
        (let ((s (trailer (trailing tight '("Ab" . "c")) 4 4)))
          (conn-step s `(parser-event on-header-field-data ,big 0 1))
          (i s '(parser-event on-header-field-complete 0)
             '(body #f ((reply-parser continue))))))

   ;; A name's or a value's end counts a byte, for the delimiter before it.
   (row 'F4 "body, a body's chunk extensions within 16 KiB, all of them together -> body: continue"
        (i (extended) `(parser-event on-chunk-extension-name-data ,big 0 ,max-extensions)
           '(body #f ((reply-parser continue))))
        (i (extended 8192) `(parser-event on-chunk-extension-value-data ,big 0 8191)
           '(body #f ((reply-parser continue))))
        (i (after (extended) `(parser-event on-chunk-extension-name-data ,big 0 ,(- max-extensions 1)))
           '(parser-event on-chunk-extension-name-complete 0)
           '(body #f ((reply-parser continue))))
        (i (after (extended) `(parser-event on-chunk-extension-value-data ,big 0 ,(- max-extensions 1)))
           '(parser-event on-chunk-extension-value-complete 0)
           '(body #f ((reply-parser continue)))))

   (row 'F5 "body, a body's chunk extensions past 16 KiB, all of them together -> body: fail chunk-extensions-too-large"
        (i (extended) `(parser-event on-chunk-extension-name-data ,big 0 ,(+ max-extensions 1))
           '(body #f ((reply-parser (fail chunk-extensions-too-large)))))
        (i (extended 8192) `(parser-event on-chunk-extension-value-data ,big 0 8192)
           '(body #f ((reply-parser (fail chunk-extensions-too-large)))))
        (i (extended 4096 4096 4096) `(parser-event on-chunk-extension-name-data ,big 0 4094)
           '(body #f ((reply-parser (fail chunk-extensions-too-large)))))
        (i (after (extended) `(parser-event on-chunk-extension-name-data ,big 0 ,max-extensions))
           '(parser-event on-chunk-extension-name-complete 0)
           '(body #f ((reply-parser (fail chunk-extensions-too-large)))))
        (i (after (extended) `(parser-event on-chunk-extension-value-data ,big 0 ,max-extensions))
           '(parser-event on-chunk-extension-value-complete 0)
           '(body #f ((reply-parser (fail chunk-extensions-too-large))))))

   (row 'F6 "body, the parser's error for a trailer or the extensions refused -> responding 431 or 413, read-stop, close-after"
        (let ((s (trailing tight)))
          (conn-step s `(parser-event on-header-field-data ,big 0 5))
          (i s '(parser-result error 60 60 header-field-too-large #f)
             `(responding header-field-too-large
                          (,(status-write 431 "Request Header Fields Too Large") (read-stop) (arm-deadline write)))))
        (let ((s (extended)))
          (conn-step s `(parser-event on-chunk-extension-name-data ,big 0 ,(+ max-extensions 1)))
          (i s '(parser-result error 60 60 chunk-extensions-too-large #f)
             `(responding chunk-extensions-too-large
                          (,(status-write 413 "Content Too Large") (read-stop) (arm-deadline write))))))

   ;; What the feed that completed the head met of the body waits for the
   ;; handler's answer, a refusal among it (design §8.1's second property).
   (row 'F7 "body, a trailer or the extensions refused in the head's feed, before the handler is asked -> handling: read-stop, disarm, call-handler, the refusal kept, then answered with its status"
        (let ((s (announced 'chunked tight)))
          (conn-step s `(parser-event on-header-field-data ,big 0 5))
          (i s '(parser-result error 60 60 header-field-too-large #f)
             '(handling #f ((read-stop) (disarm-deadline) (call-handler POST)))))
        (let ((s (announced 'chunked)))
          (conn-step s `(parser-event on-chunk-extension-name-data ,big 0 ,(+ max-extensions 1)))
          (i s '(parser-result error 60 60 chunk-extensions-too-large #f)
             '(handling #f ((read-stop) (disarm-deadline) (call-handler POST)))))
        (let ((s (announced 'chunked tight)))
          (conn-step s `(parser-event on-header-field-data ,big 0 5))
          (conn-step s '(parser-result error 60 60 header-field-too-large #f))
          (i s `(handler-responded ,streamer)
             `(responding header-field-too-large
                          (,(status-write 431 "Request Header Fields Too Large") (arm-deadline write)))))
        (let ((s (announced 'chunked)))
          (conn-step s `(parser-event on-chunk-extension-name-data ,big 0 ,(+ max-extensions 1)))
          (conn-step s '(parser-result error 60 60 chunk-extensions-too-large #f))
          (i s `(handler-responded ,streamer)
             `(responding chunk-extensions-too-large
                          (,(status-write 413 "Content Too Large") (arm-deadline write))))))))

;; ---------------------------------------------------------------------------
;; The padding PR: what the parser reads and hands the core no span of is
;; held to limits (decided on the owner's word, 2026-09-30).  Four runs of
;; it: empty lines before a request line, two skipped (RFC 9112 §2.2 asks
;; for one; llhttp's own fixture carries two after a POST's body); the
;; spaces between the request line's parts, one each (§3); the spaces and
;; tabs before a field's value, counted with the value against its limit
;; and the section's; and a chunk size's digits, 16 at most, zeros
;; included.  Every event carries the parser's position, and a run is
;; measured from where one piece ends to where the next begins: at the
;; callback that ends it, and at a read's end while it runs, the parser's
;; error among them, once what the error cut off is judged (the cut-off
;; rows below).  The rows' spans are at their bounds in
;; the bytevectors named, and their events at the positions a parse of the
;; same bytes commits.

;; after : ConnState Event ... -> ConnState — the state, having taken `events`.
(define (after s . events)
  (for-each (lambda (ev) (conn-step s ev)) events)
  s)

;; served : Nat -> ConnState
;; A GET that ended at the parser's position `end` and was answered: idle
;; again, its response written.
(define (served end)
  (let ((s (after (state 'body 'deadline 'body 'request req)
                  `(parser-event on-message-complete ,end)
                  `(parser-result paused ,end ,end #f #f))))
    (let-values (((s actions) (conn-step s `(handler-responded ,resp))))
      (after s `(write-completed ,(nbytes (assq 'write actions)))))))

;; The request lines the rows read, one space and two between their parts,
;; and with no version, ended by a bare LF or CRLF, a field after it.
(define spaced (b "GET / HTTP/1.1"))
(define method-spaced (b "GET  / HTTP/1.1"))
(define target-spaced (b "GET /  HTTP/1.1"))
(define versionless (b "GET /\nHost: x\r\n\r\n"))
(define versionless-crlf (b "GET /\r\nHost: x\r\n\r\n"))

;; reading-chunks : -> ConnState
;; A chunked POST read by a streaming reader, which has met its first
;; chunk: the chunk ends at 60, where the next size line begins.
(define (reading-chunks)
  (after (reading 'chunked streamer) '(parser-event on-chunk-complete 60)))

(define status-400 (status-write 400 "Bad Request"))
(define status-431 (status-write 431 "Request Header Fields Too Large"))

(define (padding-rows)
  (list
   (row 'G1 "idle, on-message-begin after two empty lines or fewer -> head: continue, disarm, arm header"
        (i (state 'idle 'deadline 'idle) '(parser-event on-message-begin 4)
           '(head #f ((reply-parser continue) (disarm-deadline) (arm-deadline header))))
        (i (served 27) '(parser-event on-message-begin 31)
           '(head #f ((reply-parser continue) (disarm-deadline) (arm-deadline header)))))

   (row 'G2 "idle, on-message-begin after more than two empty lines' 4 bytes -> head: fail empty-lines, disarm, arm header"
        (i (state 'idle 'deadline 'idle) '(parser-event on-message-begin 5)
           '(head #f ((reply-parser (fail empty-lines)) (disarm-deadline) (arm-deadline header))))
        (i (served 27) '(parser-event on-message-begin 32)
           '(head #f ((reply-parser (fail empty-lines)) (disarm-deadline) (arm-deadline header)))))

   (row 'G3 "head, a target or a protocol one space past the part before it -> head: continue"
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           `(parser-event on-url-data ,spaced 4 5)
           '(head #f ((reply-parser continue))))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,spaced 4 5) '(parser-event on-url-complete 6))
           `(parser-event on-protocol-data ,spaced 6 10)
           '(head #f ((reply-parser continue)))))

   (row 'G4 "head, a target or a protocol more than one space past the part before it -> head: fail request-line-spaces"
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           `(parser-event on-url-data ,method-spaced 5 6)
           '(head #f ((reply-parser (fail request-line-spaces)))))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,target-spaced 4 5) '(parser-event on-url-complete 6))
           `(parser-event on-protocol-data ,target-spaced 7 11)
           '(head #f ((reply-parser (fail request-line-spaces))))))

   ;; Under `tight`: a value of 4 bytes, 10 in a section.  The head holds
   ;; `Host: x`, 6 bytes with its space; a field `Ab` ends its name at 2,
   ;; its colon read by 3.
   ;; A name after a value counts none of that value's whitespace: here 4
   ;; bytes, the name's limit, after Host's space, or a trailer's.
   (row 'G5 "head or body, a value's first bytes: the whitespace since the colon counts with the value -> continue within the limits; and the next name counts none"
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           `(parser-event on-header-value-data ,big 3 5)
           '(head #f ((reply-parser continue))))
        (i (after (trailing tight) `(parser-event on-header-field-data ,big 0 2)
                  '(parser-event on-header-field-complete 3))
           `(parser-event on-header-value-data ,big 4 7)
           '(body #f ((reply-parser continue))))
        (i (state 'head 'deadline 'header 'host "x" 'limits tight)
           `(parser-event on-header-field-data ,big 0 4)
           '(head #f ((reply-parser continue))))
        (i (after (trailing tight) `(parser-event on-header-field-data ,big 0 2)
                  '(parser-event on-header-field-complete 3) `(parser-event on-header-value-data ,big 4 7)
                  '(parser-event on-header-value-complete 9))
           `(parser-event on-header-field-data ,big 0 4)
           '(body #f ((reply-parser continue)))))

   (row 'G6 "head or body, a value's first bytes past the value's limit or the section's, counted with the whitespace since the colon -> fail"
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           `(parser-event on-header-value-data ,big 5 6)
           '(head #f ((reply-parser (fail headers-too-large)))))
        (i (after (trailing tight) `(parser-event on-header-field-data ,big 0 2)
                  '(parser-event on-header-field-complete 3))
           `(parser-event on-header-value-data ,big 5 8)
           '(body #f ((reply-parser (fail header-value-too-large))))))

   ;; The next size line begins at 60; 16 digits end at 76, then `;` or its
   ;; line end.
   (row 'G7 "body, a chunk size of 16 digits, zeros included, ended by its line or its first extension -> continue"
        (i (reading-chunks) '(parser-event on-chunk-header 78)
           '(body #f ((reply-parser continue))))
        (i (reading-chunks) `(parser-event on-chunk-extension-name-data ,big 77 78)
           '(body #f ((reply-parser continue)))))

   (row 'G8 "body, a chunk size of 17 digits -> fail chunk-size-too-long"
        (i (reading-chunks) '(parser-event on-chunk-header 79)
           '(body #f ((reply-parser (fail chunk-size-too-long)))))
        (i (reading-chunks) `(parser-event on-chunk-extension-name-data ,big 78 79)
           '(body #f ((reply-parser (fail chunk-size-too-long)))))
        (i (after (state 'head 'deadline 'header 'target "/" 'host "x")
                  `(parser-event on-headers-complete 3 1 1 ,F-CHUNKED 0 0 46))
           '(parser-event on-chunk-header 65)
           '(body #f ((reply-parser (fail chunk-size-too-long))))))

   ;; A read's end within the run, within its limit: nothing; the reads here
   ;; are all the connection's, from its first byte.
   ;; A read may end a byte past the target's space, where a request line
   ;; with no version has its CR, and two past the whitespace before a
   ;; value, an empty value's line end, without a refusal.
   (row 'G9 "a read's end inside a run within its limit -> the same: nothing"
        (i (state 'idle 'deadline 'idle) '(parser-result need-input 4 4 #f #f)
           '(idle #f ()))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           '(parser-result need-input 4 4 #f #f)
           '(head #f ()))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,spaced 4 5) '(parser-event on-url-complete 6))
           '(parser-result need-input 7 7 #f #f)
           '(head #f ()))
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           '(parser-result need-input 5 5 #f #f)
           '(head #f ()))
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           '(parser-result need-input 7 7 #f #f)
           '(head #f ()))
        (i (reading-chunks) '(parser-result need-input 77 77 #f #f)
           '(body #f ())))

   (row 'G10 "idle, head or body, a read's end inside a run past its limit -> responding: the run's status, read-stop, close-after"
        (i (state 'idle 'deadline 'idle) '(parser-result need-input 5 5 #f #f)
           `(responding empty-lines (,status-400 (read-stop) (arm-deadline write))))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           '(parser-result need-input 5 5 #f #f)
           `(responding request-line-spaces (,status-400 (read-stop) (arm-deadline write))))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,spaced 4 5) '(parser-event on-url-complete 6))
           '(parser-result need-input 8 8 #f #f)
           `(responding request-line-spaces (,status-400 (read-stop) (arm-deadline write))))
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           '(parser-result need-input 9 9 #f #f)
           `(responding headers-too-large (,status-431 (read-stop) (arm-deadline write))))
        (i (reading-chunks) '(parser-result need-input 78 78 #f #f)
           `(responding chunk-size-too-long (,status-400 (read-stop) (arm-deadline write)))))

   ;; The feed that completed the head went on past the next size line's
   ;; 17th digit: the refusal waits for the handler's answer, as T3's does.
   (row 'G11 "body, the head's feed ends inside a run past its limit -> handling: read-stop, disarm, call-handler, the refusal kept"
        (i (after (announced 'chunked) `(parser-event on-body-data ,bv 3 4)
                  '(parser-event on-chunk-complete 52))
           '(parser-result need-input 71 71 #f #f)
           '(handling #f ((read-stop) (disarm-deadline) (call-handler POST)))))

   ;; The parser's error inside a run, with no span cut off: the run is
   ;; judged as at a read's end, to the byte the parser refused, so past its
   ;; limit its status stands, and within it the parser's (the cut-off-span
   ;; PR; before it, only the whitespace's was judged here).
   (row 'G12 "head or body, the parser's error inside a run, no span cut off -> the run's status past its limit, as at a read's end, and the parser's within it"
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           '(parser-result error 9 9 invalid-url #f)
           `(responding request-line-spaces (,status-400 (read-stop) (arm-deadline write))))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3))
           '(parser-result error 4 4 invalid-url #f)
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write))))
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2))
           '(parser-result error 9 9 invalid-header-token #f)
           `(responding headers-too-large (,status-431 (read-stop) (arm-deadline write))))
        (i (reading-chunks) '(parser-result error 78 78 invalid-chunk-size #f)
           `(responding chunk-size-too-long (,status-400 (read-stop) (arm-deadline write)))))

   ;; The parser ends a target at a space, a bare LF or a CRLF, and the run
   ;; after it opens at each; a request line with no version lets it go at
   ;; its first field, so a read's end past the field's name judges nothing.
   (row 'G13 "head, a request line with no version, its first field met -> head: the run after the target let go"
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,versionless 4 5) '(parser-event on-url-complete 6)
                  `(parser-event on-header-field-data ,versionless 6 10))
           '(parser-result need-input 10 10 #f #f)
           '(head #f ()))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,versionless-crlf 4 5) '(parser-event on-url-complete 7)
                  `(parser-event on-header-field-data ,versionless-crlf 7 11))
           '(parser-result need-input 11 11 #f #f)
           '(head #f ())))

   ;; A run is judged at a read's end only in the phase it is read in: one
   ;; still open when a deadline's 408 moves the connection on is not, so a
   ;; read's end after it changes nothing, as an event with no transition.
   (row 'G14 "responding, a read's end with a run from head or body still open -> responding: nothing"
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3) '(tick 60000))
           '(parser-result need-input 30 30 #f #f)
           '(responding header-timeout ()))
        (i (after (state 'head 'deadline 'header) '(parser-event on-method-complete 3)
                  `(parser-event on-url-data ,spaced 4 5) '(parser-event on-url-complete 6) '(tick 60000))
           '(parser-result need-input 30 30 #f #f)
           '(responding header-timeout ()))
        (i (after (state 'head 'deadline 'header 'host "x" 'limits tight)
                  `(parser-event on-header-field-data ,big 0 1) '(parser-event on-header-field-complete 2)
                  '(tick 60000))
           '(parser-result need-input 30 30 #f #f)
           '(responding header-timeout ()))
        (i (after (reading-chunks) '(tick 60000))
           '(parser-result need-input 100 100 #f #f)
           '(responding body-timeout ())))))

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
           '(parser-result error 19 29 closed-connection #f)
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

;; ---------------------------------------------------------------------------
;; What the parser's error cuts off (the cut-off-span PR; decided on the
;; owner's word, 2026-10-01).  A malformed byte ends the parse, and a
;; target or a field name the parser was reading is abandoned, never handed
;; on.  The result names the span the error abandoned and where its
;; withheld bytes begin (byte-machine v0.7.0's two accessors, for its #145),
;; and its offset is the refused byte's; the core judges the span's bytes it
;; was not handed, from there to that byte, as a read's end would have.  They
;; begin where the span did when it began in the read that failed (a target
;; past the method's spaces, a name at its line's start), and otherwise at
;; that read's start.  The rows' events are at the positions a parse of the
;; bytes named commits, each delivery fed from its index 0.

;; cut : Limits — tight's header limits, and a target of 4 bytes.
(define cut (limits-with tight '((max-target-bytes . 4))))

;; fed : Bytevector Nat Nat -> Event — a delivery of line[from, to).
(define (fed line from to) `(bytes-arrived ,line ,from ,to))

;; The request lines the target rows read: a target of 4 bytes and of 5,
;; each then a control byte; 2 spaces after the method, then a target, or
;; the control byte at once.
(define four (b "GET /aaa\x1; HTTP/1.1"))
(define five (b "GET /aaaa\x1; HTTP/1.1"))
(define spaced-five (b "GET  /aaaa\x1; HTTP/1.1"))
(define spaced-none (b "GET  \x1; HTTP/1.1"))

;; method-read : Bytevector -> ConnState
;; A GET in head under `cut`, the delivery `line` fed whole and its method
;; read: the spaces after it are counted from 3.
(define (method-read line)
  (after (state 'head 'deadline 'header 'limits cut)
         (fed line 0 (bytevector-length line)) '(parser-event on-method-complete 3)))

;; carried : Bytevector -> ConnState
;; The same, but the first read ended at 6, where the target's first two
;; bytes were handed on, and the rest of `line` is the next delivery.
(define (carried line)
  (after (state 'head 'deadline 'header 'limits cut)
         (fed line 0 6) '(parser-event on-method-complete 3) `(parser-event on-url-data ,line 4 6)
         '(parser-result need-input 6 6 #f #f) (fed line 6 (bytevector-length line))))

;; request-line : Limits -> ConnState
;; A GET of / in head, its request line, `GET / HTTP/1.1`, read to its
;; version's end at 14, past which, at 16, its first field's line begins.
(define (request-line limits)
  (after (state 'head 'deadline 'header 'target "/" 'limits limits) '(parser-event on-version-complete 14)))

;; one-field : String -> ConnState
;; The same under tight, having read the field Host: `value`, its line from
;; 16, the next one beginning past its CRLF.
(define (one-field value)
  (let ((line (b (string-append "GET / HTTP/1.1\r\nHost: " value "\r\n")))
        (end (+ 22 (string-length value))))
    (after (request-line tight)
           `(parser-event on-header-field-data ,line 16 20) '(parser-event on-header-field-complete 21)
           `(parser-event on-header-value-data ,line 22 ,end) `(parser-event on-header-value-complete ,(+ end 2)))))

;; last-chunk : -> ConnState
;; A chunked POST under tight, its streaming reader reading, that met a
;; 1-byte chunk and then the last chunk's size line: the trailer section's
;; first line begins at 55.
(define (last-chunk)
  (after (trailing tight) `(parser-event on-body-data ,big 49 50) '(parser-event on-chunk-complete 52)
         '(parser-event on-chunk-header 55)))

(define status-414 (status-write 414 "URI Too Long"))

(define (cut-off-rows)
  (list
   ;; `GET /aaa`, and the control byte at 8: the target's 4 bytes from 4.
   (row 'K1 "head, the parser's error with the target cut off within its limit -> responding: the parser's status"
        (i (method-read four) '(parser-result error 8 8 invalid-url (url-span . 4))
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write))))
        (i (carried four) '(parser-result error 8 8 invalid-url (url-span . 6))
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write)))))
   (row 'K2 "head, the parser's error with the target cut off past its limit -> responding: 414"
        (i (method-read five) '(parser-result error 9 9 invalid-url (url-span . 4))
           `(responding target-too-large (,status-414 (read-stop) (arm-deadline write))))
        (i (carried five) '(parser-result error 9 9 invalid-url (url-span . 6))
           `(responding target-too-large (,status-414 (read-stop) (arm-deadline write)))))
   ;; The spaces after the method come first: the 2nd, at 4, is past the one,
   ;; and the target, or the control byte where it would be, begins at 5.
   (row 'K3 "head, the parser's error with the target cut off after more than one space -> responding: the spaces' status"
        (i (method-read spaced-five) '(parser-result error 10 10 invalid-url (url-span . 5))
           `(responding request-line-spaces (,status-400 (read-stop) (arm-deadline write))))
        (i (method-read spaced-none) '(parser-result error 5 5 invalid-url (url-span . 5))
           `(responding request-line-spaces (,status-400 (read-stop) (arm-deadline write)))))
   ;; A name of 4 bytes is tight's limit, as 10 is its section's: Host: x
   ;; and its space, 6, and a name of 4; with Host: xx, 7, a name of 4 is
   ;; within its own limit but past the section's.
   (row 'K4 "head or body, the parser's error with a field name cut off -> responding: the parser's status within the limits; past one, 431 for the limit passed first"
        (i (request-line tight) '(parser-result error 20 20 invalid-header-token (header-field-span . 16))
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write))))
        (i (request-line tight) '(parser-result error 21 21 invalid-header-token (header-field-span . 16))
           `(responding header-field-too-large (,status-431 (read-stop) (arm-deadline write))))
        (i (one-field "x") '(parser-result error 29 29 invalid-header-token (header-field-span . 25))
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write))))
        (i (one-field "xx") '(parser-result error 30 30 invalid-header-token (header-field-span . 26))
           `(responding headers-too-large (,status-431 (read-stop) (arm-deadline write))))
        (i (last-chunk) '(parser-result error 59 59 invalid-header-token (header-field-span . 55))
           `(responding parser-error (,status-400 (read-stop) (arm-deadline write))))
        (i (last-chunk) '(parser-result error 60 60 invalid-header-token (header-field-span . 55))
           `(responding header-field-too-large (,status-431 (read-stop) (arm-deadline write)))))))

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
        '(shutdown-completed) '(closed) '(tick 0) '(parser-event on-message-begin 0)
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
    (test-equal "ten states: design §4.3's nine, less draining (M8.1), decision 0011's lingering and M6.2's awaiting-credit"
                '(idle head body awaiting-credit handling responding lingering handed-off
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
    ;; A producer's answer as the event the shells dispatch for it (M6.3;
    ;; decision 0013 item 8): the core makes it, so both shells report a
    ;; producer alike.  What is no piece, an empty bytevector among it, a
    ;; shell reports as the producer failing (the stream suite's flows).
    (test-equal "a producer's answer as an event: a bytevector of a byte or more is a piece, the eof object the end, an empty bytevector or anything else refused"
                (list (list 'handler-body-chunk (b "abc") 0 3) '(handler-body-end) 'refused 'refused 'refused)
                (list (producer-event (b "abc")) (producer-event (eof-object))
                      (verdict (lambda () (producer-event (make-bytevector 0))))
                      (verdict (lambda () (producer-event 'done)))
                      (verdict (lambda () (producer-event "abc")))))
    ;; The shells log the refusal as the producer failing, and an answer that
    ;; is no piece is the response's data, a whole page when a string was
    ;; answered for its bytes: so the refusal names the answer by its kind
    ;; and its length, where it has one, and never holds the answer (M6.3's
    ;; second review).
    (test-equal "a producer's answer that is no piece is named by its kind and length, never held"
                '(((bytevector 0)) ((string 100000)) ((vector 2)) ((list 2)) ((pair)) ((symbol))
                  ((char)) ((number)) ((boolean)) ((procedure)) ((other)))
                (map (lambda (x)
                       (guard (e ((assertion-violation? e) (condition-irritants e)))
                         (producer-event x)
                         'accepted))
                     (list (make-bytevector 0) (make-string 100000 #\a) (vector 1 2)
                           (list (b "a") (b "b")) (cons (b "a") (b "b")) 'done #\a 42 #f car
                           (make-response 200 #f '() #f))))
    (test-eq "an unknown event is an assertion violation" 'refused
             (verdict (lambda () (conn-step (state 'idle) '(no-such-event)))))
    (test-eq "an event that is not a tagged list is an assertion violation" 'refused
             (verdict (lambda () (conn-step (state 'idle) 'eof))))
    (test-eq "a state outside the ten is refused" 'refused
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
           (credits (count-rows "credit" credit-rows credited))
           (streams (count-rows "stream" stream-rows produced))
           (expects (count-rows "expect" expect-rows asked-by))
           (continues (count-rows "continue-accounting" continue-accounting-rows accounted))
           (framings (count-rows "framing" framing-rows asked-by))
           (paddings (count-rows "padding" padding-rows asked-by))
           (cut-offs (count-rows "cut-off" cut-off-rows asked-by)))
      (test-eqv "design §4.4: all 10 happy-path rows have a test" 10 happy)
      (test-eqv "design §4.4: all 9 termination and error rows have a test, and M8.1's three" 12 term)
      (test-eqv "decision 0004: all 3 pause-protocol rows have a test" 3 pause)
      (test-eqv "M2.5: both upgrade-door rows have a test" 2 upgrade)
      (test-eqv "M3.2: both response rows have a test" 2 answered)
      (test-eqv "M3.3: all 5 accounting rows have a test" 5 accounting)
      (test-eqv "M3.5: all 4 linger rows have a test" 4 linger)
      (test-eqv "M5.2: all 3 tick rows left since M8.1 retired draining have a test" 3 ticks)
      (test-eqv "M6.1: all 19 body rows have a test" 19 bodies)
      (test-eqv "M6.2: all 11 credit rows have a test" 11 credits)
      (test-eqv "M6.3: all 19 stream rows have a test" 19 streams)
      (test-eqv "M6.4: all 7 Expect rows have a test" 7 expects)
      (test-eqv "M6.4: the 100's accounting row has a test" 1 continues)
      (test-eqv "M6.4: all 7 trailer and extension rows have a test" 7 framings)
      (test-eqv "the padding PR: all 14 padding rows have a test" 14 paddings)
      (test-eqv "the cut-off-span PR: all 4 cut-off rows have a test" 4 cut-offs))

    ;; Every action the table produced is in the vocabulary, and the table
    ;; uses all of it: `notify-producer` since M6.3.
    (test-equal "no row emits an action outside the vocabulary" '()
                (filter (lambda (k) (not (memq k conn-actions))) emitted))
    (test-equal "the rows use all sixteen actions" conn-actions
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
    ;; connection open, and no connection may keep the idle
    ;; deadline it carried with nothing to act on it.
    (test-equal "each deadline a row leaves armed, ticked in the state it leaves, moves the connection on"
                '((idle idle closing) (head header responding)
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
