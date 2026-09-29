#!r6rs
;;; The cross-shell contract (design §8.4; plan §8, M4.4).
;;;
;;; The fake shell and the direct libuv shell must do the same thing with the
;;; same events: the same bytes on the wire, and the same trace of the events
;;; each dispatched and the actions each ran, in order.  The core and the
;;; adapter are shared, so what the contract holds equal is what each shell
;;; adds: its message loop, its executors, and the completions it reports.
;;; M7 adds the coroutine shell.
;;;
;;; HOW THE SAME EVENTS REACH BOTH.  A script is a client's: what it sends,
;;; where it waits for the server to have read what it sent, and its end,
;;; which is the half-close, or a stall: the client sends nothing more and
;;; never ends its stream, and waits for the server's deadlines to close the
;;; connection (M5.3).  A script marked `(bare-close)` is one whose
;;; connection the server closes at once, with no linger, before it reads
;;; the client's half-close: a producer's failure once the head is on the
;;; wire (M6.3).  The client plays it on the libuv shell's own loop,
;;; to the shell's own listener, and the shell's trace records every event
;;; and action, and the loop's time each event came at and each write was
;;; made at.  How the kernel divides the bytes into reads is its policy
;;; (design §8.5), so the libuv shell's events are then given to the fake,
;;; its clock moved to each one's time first: each delivery and the
;;; client's end as the libuv shell received them; each completion (a
;;; write's, a half-close's, a close's) where the libuv shell received its
;;; own, the fake delivering the one it has waiting; and each tick as the
;;; fake's own timer firing then.  The events a shell makes itself while it
;;; performs an action, a parser's result and a handler's answer, each makes
;;; on its own.
;;;
;;; ONE CLOCK.  The libuv shell keeps two: the wall clock its Date line is
;;; made from, and the loop's (uv_now), which its deadlines are armed and
;;; ticked by.  The fake keeps one, the test's.  So the libuv shell's wall
;;; clock here is the loop's own, and the fake is made when the libuv shell
;;; adopted its connection, as the libuv shell arms its first deadline then.
;;; The libuv shell brings its clock up to date before each arm and each
;;; write, where the fake's stays at the instant of the event it was given,
;;; so the libuv shell arms each deadline then or a moment later: never
;;; earlier than the fake, which, fired where the libuv shell ticked, ticks
;;; too.  A Date names a second, and one can begin in that moment, so the
;;; fake dates each write at the libuv shell's instant for it, in order: the
;;; loop's time where the trace sees the write, which the shell calls once
;;; the clock is up to date.  One script holds its second request into the
;;; next second, so its answers are dated a second apart, the second a
;;; second after its event: a fake dated at the event's instant, or at the
;;; instants out of order, writes another Date.
;;;
;;; The checks, for each script:
;;;   - the libuv shell read what the client sent, then its end alone, and
;;;     closed: so the events the fake is given are the script's;
;;;   - the client read the bytes the fake shell wrote;
;;;   - the two traces are identical.
;;; A client that does not connect plays nothing, and the first check names
;;; how its connect ended.  Where the two shells part, a line on stderr names the script and the
;;; first byte, or the first event or action, that differs: `CONTRACT
;;; MISMATCH`, beside the harness's FAIL, which gives only the check's name.
;;;
;;; Oracles: the scripts' bytes; the fake shell, which the core's table
;;; suites hold to design §4.4's rows (M1.4 to M3.5) and its wheel to their
;;; deadlines (M5.3); the loop's time, as both shells' clock, read where the
;;; libuv shell's trace sees each event and each write.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) current-time time-second time-nanosecond)
        (libuv) (uv-testing)
        (http-server private shell)
        (only (http-server connection) conn-phase)
        (http-server request) (http-server response) (http-server span) (http-server limits)
        (http-server body)
        (fake-shell) (shell-testing) (producers))

(define (b s) (string->utf8 s))

(define cap 4096)

;; The handler answers 200 with the request's target as the body, except
;; `/close`, whose response asks to close the connection, `/raise`, which
;; raises a message, and `/raise-who`, which raises a condition with no
;; message; and it reads a body with a reader (decision 0013): `/read`
;; streams it, dropping it, `/whole` reads it whole and answers with it,
;; `/small` reads it whole, capped at 4 bytes, and `/piece-raises` and
;; `/end-raises` have readers that raise, at the first piece and at the
;; end.  `/stream` answers with a producer of three pieces (decision 0013
;; item 8; M6.3; tests/producers.sls), and `/stream-raises` with one whose
;; second call raises.
;; Both shells call it, so it keeps nothing between calls: each answer
;; makes a producer of its own.
(define (handler req)
  (let ((target (span->bytevector (request-target req))))
    (cond ((bytevector=? target (b "/close"))
           (make-response 200 #f (list (cons (b "Connection") (b "close"))) target))
          ((bytevector=? target (b "/raise"))
           (raise (make-message-condition "the handler failed")))
          ((bytevector=? target (b "/raise-who"))
           (raise (condition (make-error) (make-who-condition 'handler))))
          ((bytevector=? target (b "/read"))
           (read-body (lambda (bv start end) #t) (lambda () (make-response 200 #f '() target))))
          ((bytevector=? target (b "/whole"))
           (read-whole-body (lambda (body) (make-response 200 #f '() body))))
          ((bytevector=? target (b "/small"))
           (read-whole-body (lambda (body) (make-response 200 #f '() body)) 4))
          ((bytevector=? target (b "/piece-raises"))
           (read-body (lambda (bv start end) (raise (make-message-condition "the reader failed")))
                      (lambda () (make-response 200 #f '() target))))
          ((bytevector=? target (b "/end-raises"))
           (read-body (lambda (bv start end) #t)
                      (lambda () (raise (make-message-condition "the reader failed")))))
          ((bytevector=? target (b "/stream"))
           (make-response 200 #f '() (producer-of '("one " "two " "three"))))
          ((bytevector=? target (b "/stream-raises"))
           (make-response 200 #f '()
                          (producer-of '("one ")
                                       (lambda () (raise (make-message-condition "the producer failed"))))))
          (else (make-response 200 #f '() target)))))

;; The libuv shells call the handler through `held-handler`, which first
;; holds the loop into the next second for `/next-second`, as a handler that
;; computes for a while does: its request arrives in one second of the
;; loop's clock, and its answer is written in the next.  The fake's clock
;; stands still while its handler runs, so the fake calls the handler itself.
(define (held-handler req)
  (when (bytevector=? (span->bytevector (request-target req)) (b "/next-second"))
    (hold-into-next-second!))
  (handler req))

;; monotonic-ms : -> Nat — Chez's monotonic clock, in milliseconds.
(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

;; hold-into-next-second! : -> Void
;; Keep the loop's thread busy until the loop's clock has passed into the
;; second after the one it reads now: the rest of that second, and 5 ms
;; more for the two clocks' rounding, by Chez's monotonic clock, which runs
;; as the loop's does.  The loop's clock is left as it is, so the shell's
;; refresh before the write is the first to read the next second.
(define (hold-into-next-second!)
  (let ((until (+ (monotonic-ms) (- 1000 (mod (uv-now loop) 1000)) 5)))
    (let spin () (when (< (monotonic-ms) until) (spin)))))

;; A script: its name, then its steps, each `(send "text")`, or `(read)`,
;; which waits until the libuv shell has read everything sent so far.  The
;; client's end follows the last step, unless the last is `(stall)`: the
;; client sends nothing more, and never ends its stream.
(define scripts
  '(("a GET, kept alive" (send "GET /one HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("three requests in one write"
     (send "GET /1 HTTP/1.1\r\nHost: x\r\n\r\nGET /2 HTTP/1.1\r\nHost: x\r\n\r\nGET /3 HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a request split across two deliveries"
     (send "GET /split HTTP/1.1\r\nHo") (read) (send "st: x\r\n\r\n"))
    ("a request with a body, answered before it is read"
     (send "POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
    ("a body streamed to a reader, in two deliveries"
     (send "POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n01234") (read) (send "56789"))
    ("a chunked body read whole, then a GET"
     (send "POST /whole HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\nGET /after HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a body past a reader's cap"
     (send "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789"))
    ("a reader that raises at its first piece"
     (send "POST /piece-raises HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
    ("a reader that raises at its end"
     (send "POST /end-raises HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
    ("a response that closes the connection, then the linger"
     (send "GET /close HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("input that arrives while the connection lingers"
     (send "GET /close HTTP/1.1\r\nHost: x\r\n\r\n") (read) (send "GET /late HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a handler that raises" (send "GET /raise HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a handler that raises a condition with no message"
     (send "GET /raise-who HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a request the core refuses, with no Host" (send "GET /x HTTP/1.1\r\n\r\n"))
    ("a streamed response, chunked, the connection kept"
     (send "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n"))
    ("a streamed response to HTTP/1.0, close-delimited, then the linger"
     (send "GET /stream HTTP/1.0\r\n\r\n"))
    ("a producer that raises after a piece: the bare close"
     (send "GET /stream-raises HTTP/1.1\r\nHost: x\r\n\r\n") (bare-close))
    ("two requests in one write, the second answered in the next second"
     (send "GET /now HTTP/1.1\r\nHost: x\r\n\r\nGET /next-second HTTP/1.1\r\nHost: x\r\n\r\n"))))

;; The scripts whose deadlines pass, played to a shell with short limits: a
;; fifth of a second or a little more for a head, an idle connection and a
;; linger, each its own, and a tick of 10 ms.
(define quick-limits
  (limits-with default-limits
               '((read-header-timeout-ms . 200) (idle-timeout-ms . 250) (linger-timeout-ms . 300)
                 (tick-ms . 10))))

;; The scripts played to a shell made on credit (M6.2), which answers with
;; each answer and `credit`, as M7's coroutine shell will, handing a reader
;; its pieces on credit; the fake is made on credit too.  Whenever the
;; script's connection waits for its reader's credit, the script's waits
;; credit it, so a script reads the same however the reads divide.
(define credit-scripts
  '(("a body streamed to a reader on credit, credited each time it waits"
     (send "POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n01234") (read) (send "56789"))))

(define stalling-scripts
  '(("a head never finished: 408 once its deadline passes, then closed once the linger's does"
     (send "GET /stall HTTP/1.1\r\nHo") (stall))
    ("a client that sends nothing: closed once the idle deadline armed as it was adopted passes"
     (stall))))

;; ends-with? : Script Datum -> Boolean — whether its last step is `step`.
(define (ends-with? script step)
  (let ((steps (cdr script)))
    (and (pair? steps) (equal? (list-ref steps (- (length steps) 1)) step))))

;; stalls? : Script -> Boolean — whether its client stalls at the end.
(define (stalls? script) (ends-with? script '(stall)))

;; closes-bare? : Script -> Boolean — whether the server closes its
;; connection at once, before it reads the client's end.
(define (closes-bare? script) (ends-with? script '(bare-close)))

;; latin-1 : Bytevector -> String — one character per byte, so two byte
;; strings render alike only if they are alike.
(define (latin-1 bv) (list->string (map integer->char (bytevector->u8-list bv))))

;; render : Datum -> Datum
;; An event or action as data `equal?` compares by content, made when it is
;; traced so nothing done with it later changes the trace: a bytevector as its
;; bytes, a span by its bytes, a request and a response by their fields, a
;; reader by its cap and kind and a producer as one (each shell calls the
;; handler, which makes its own), a condition by each of its simple
;; conditions, and any other record by its type and fields.  `equal?` compares a record with fields by identity,
;; so two shells' conditions would otherwise never match.
(define (render x)
  (cond ((bytevector? x) (list 'bytes (latin-1 x)))
        ((span? x) (list 'span (latin-1 (span->bytevector x))))
        ((request? x)
         (list 'request (request-method x) (render (request-target x))
               (request-http-major x) (request-http-minor x)
               (render (request-headers x)) (render (request-body x))))
        ((response? x)
         (list 'response (response-status x) (render (response-reason x))
               (render (response-headers x)) (render (response-body x))))
        ((body-reader? x) (list 'reader (body-reader-max-bytes x) (body-reader-whole? x)))
        ((procedure? x) 'producer)
        ((condition? x) (cons 'condition (map render-record (simple-conditions x))))
        ((record? x) (render-record x))
        ((pair? x) (cons (render (car x)) (render (cdr x))))
        (else x)))

;; render-record : Record -> Datum — its type's name, then every field,
;; rendered, its parents' first.
(define (render-record r)
  (let up ((rtd (record-rtd r)) (fields '()))
    (if rtd
        (up (record-type-parent rtd)
            (append (let each ((i (- (vector-length (record-type-field-names rtd)) 1)) (out '()))
                      (if (< i 0)
                          out
                          (each (- i 1) (cons (render ((record-accessor rtd i) r)) out))))
                    fields))
        (cons (record-type-name (record-rtd r)) fields))))

;; first-difference : (Listof Datum) (Listof Datum) -> Datum
;; 'identical, or the first index where the libuv shell's trace and the
;; fake's part, with each one's entry there, or 'ended.
(define (first-difference libuv fake)
  (let scan ((i 0) (l libuv) (f fake))
    (cond ((and (null? l) (null? f)) 'identical)
          ((and (pair? l) (pair? f) (equal? (car l) (car f))) (scan (+ i 1) (cdr l) (cdr f)))
          (else (list 'differs-at i
                      'libuv (if (pair? l) (car l) 'ended)
                      'fake (if (pair? f) (car f) 'ended))))))

;; diag : String -> Void — one line to stderr, beside the harness's FAIL.
(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; check : String String Datum Datum -> Void
;; One check of a script, `result` against `expected`.  A result that is not
;; the one expected is also written to stderr, since the harness prints only
;; a failing check's name, and the point of the contract is where the shells
;; part.
(define (check script what expected result)
  (unless (equal? result expected)
    (diag (string-append "CONTRACT MISMATCH " script ", " what ": "
                         (call-with-string-output-port (lambda (p) (write result p))))))
  (test-equal (string-append script ": " what) expected result))

;; joined : (Listof Bytevector) -> Bytevector — one after another, through
;; chez-libuv's byte collector.
(define (joined bvs)
  (let ((c (make-byte-collector)))
    (for-each (lambda (bv) (collect-span! c bv 0 (bytevector-length bv))) bvs)
    (collector-bytes c)))

;; --- the libuv shell -------------------------------------------------------------

(define loop #f)
(define shell #f)

;; What the libuv shell's connection has done while a script plays: every
;; event dispatched and action run, rendered, newest first; the events
;; themselves, newest first, for the fake, each as (at . event), `at` the
;; loop's time it came at; the loop's time at each of its writes, newest
;; first, which dates the write (ONE CLOCK); the bytes of its deliveries,
;; collected as they arrive; whether its close has completed; and the
;; loop's time the shell adopted it at.  One client plays at a time, so
;; these are its connection's.
(define traced '())
(define received '())
(define written-at '())
(define delivered #f)
(define closed #f)
(define adopted-at #f)

;; trace! : Any Symbol Any -> Void — the libuv shells' trace.
(define (trace! who kind datum)
  (cond ((connection? who)
         (set! traced (cons (list kind (render datum)) traced))
         (when (eq? kind 'event)
           (set! received (cons (cons (uv-now loop) datum) received))
           (case (car datum)
             ((bytes-arrived) (collect-span! delivered (cadr datum) (caddr datum) (cadddr datum)))
             ((closed) (set! closed #t))))
         (when (and (eq? kind 'action) (eq? (car datum) 'write))
           (set! written-at (cons (uv-now loop) written-at))))
        ((and (eq? kind 'server-action) (eq? (car datum) 'accept))
         (set! adopted-at (uv-now loop)))))

;; wait-for : (-> Boolean) -> Symbol
;; Run the libuv shell's own run loop until `pred` holds: 'satisfied or
;; 'iterations-exhausted.  The run loop logs a callback's error and runs on,
;; so such a bug shows in the checks; a byte-machine contract condition it
;; raises again (design §6.4), which ends the suite, as it would end a server.
(define (wait-for pred) (run-shell-until loop shell pred cap))

;; The libuv shell a script plays to, and its connections as the script
;; began: the script's own is any other.
(define playing #f)
(define earlier '())

;; credit-owed : -> (U #f (Pair Connection Nat))
;; When the script's connection waits for its reader's credit, it and the
;; bytes it was handed since its last credit, read from its trace: the
;; `deliver-body` actions since the last `body-credit` event.  Otherwise #f.
(define (credit-owed)
  (let ((cs (filter (lambda (c) (not (memq c earlier))) (shell-connections playing))))
    (and (pair? cs)
         (eq? (conn-phase (connection-state (car cs))) 'awaiting-credit)
         (cons (car cs)
               (let scan ((t traced) (n 0))
                 (cond ((null? t) n)
                       ((and (eq? (caar t) 'event) (eq? (car (cadar t)) 'body-credit)) n)
                       ((and (eq? (caar t) 'action) (eq? (car (cadar t)) 'deliver-body))
                        (let ((a (cadar t))) (scan (cdr t) (+ n (- (cadddr a) (caddr a))))))
                       (else (scan (cdr t) n))))))))

;; wait-crediting : (-> Boolean) -> Symbol
;; wait-for, crediting the script's connection each time it waits for its
;; reader's credit with what it owes, `(credit-owed)`.  'credit-refused if
;; the core refuses a credit, an assertion violation of its own, and
;; 'credit-cap-reached after `cap` credits with `pred` still unmet.
(define (wait-crediting pred)
  (let again ((n 0))
    (let* ((w (wait-for (lambda () (or (pred) (and (credit-owed) #t)))))
           (owed (credit-owed)))
      (cond ((not owed) w)
            ((>= n cap) 'credit-cap-reached)
            ((guard (e ((assertion-violation? e) #f))
               (connection-body-credit! (car owed) (cdr owed))
               #t)
             (again (+ n 1)))
            (else 'credit-refused)))))

;; play! : Shell Nat Script -> (List Bytevector Client Datum)
;; Play a script to the libuv shell `sh`, listening on `port`: the bytes the
;; client sent, the client, and 'satisfied if every wait was, each `(read)`
;; and the connection's close with its client at the stream's end;
;; otherwise the outcomes of the waits, in order.  A client that does not
;; connect plays nothing, and answers how its connect ended.  The client's
;; handle is closed after.
(define (play! sh port script)
  (set! playing sh)
  (set! earlier (shell-connections sh))
  (set! traced '())
  (set! received '())
  (set! written-at '())
  (set! delivered (make-byte-collector))
  (set! closed #f)
  (set! adopted-at #f)
  (let* ((cl (open-client loop port #f #t))
         (sent (make-byte-collector))
         (connecting (wait-for (lambda () (not (eq? (client-connected cl) 'never)))))
         (waits (if (eq? (client-connected cl) 'no-error)
                    (let step ((steps (cdr script)) (waits '()))
                      (if (pair? steps)
                          (case (caar steps)
                            ((send)
                             (let ((bv (b (cadar steps))))
                               (collect-span! sent bv 0 (bytevector-length bv))
                               (client-send! cl bv)
                               (step (cdr steps) waits)))
                            ((read)
                             (step (cdr steps)
                                   (cons (wait-crediting (lambda () (= (collector-count delivered)
                                                                       (collector-count sent))))
                                         waits)))
                            ((stall) (step '() waits))
                            ((bare-close) (step (cdr steps) waits)))
                          (begin
                            (unless (stalls? script) (client-shut! cl))
                            (reverse (cons (wait-crediting
                                            (lambda () (and closed (not (eq? (client-end cl) 'open)))))
                                           waits)))))
                    (list (list 'not-connected connecting (client-connected cl))))))
    (client-close! cl)
    (wait-for (lambda () (eq? (uv-handle-state (client-tcp cl)) 'closed)))
    (list (collector-bytes sent) cl
          (if (for-all (lambda (w) (eq? w 'satisfied)) waits) 'satisfied waits))))

;; --- the fake shell -----------------------------------------------------------

;; replay : Limits Boolean (Listof (Pair Nat Event)) (Listof Nat) -> (values FakeShell (Listof Entry))
;; The libuv shell's events given to a fake connection under the same
;; limits, made on credit if the libuv shell was (M6.2), and at the instant
;; the libuv shell adopted its own, its clock
;; moved to each event's instant before it is given: a delivery, the
;; client's end, a read's error and a reader's credit delivered as they
;; are, a completion as
;; the fake's own oldest one waiting, a tick as the fake's timer firing,
;; and the events a shell makes itself left to the fake.  Then whatever the
;; fake still has waiting.  Its writes are dated at `writes`, the instants
;; the libuv shell's were, in order (ONE CLOCK).  Answers the fake and its
;; trace, in order.  A client the libuv shell never adopted has no events,
;; and its fake is made at 0.  Whatever raises while the fake takes an
;; event, a bug in the core or in the fake, is recorded in its trace as
;; `(raised event condition)`, so the traces part there and the checks
;; name it, where a raise out of the suite would end it (M6.3's mutants).
(define (replay limits on-credit? events writes)
  (let* ((seen '())
         (fake (make-fake-connection limits handler
                                     (lambda (kind datum)
                                       (set! seen (cons (list kind (render datum)) seen)))
                                     (or adopted-at 0)
                                     on-credit?)))
    (fake-shell-date-writes! fake writes)
    (for-each (lambda (e)
                (fake-shell-advance! fake (- (car e) (fake-shell-now fake)))
                (let ((event (cdr e)))
                  (guard (x (#t (set! seen (cons (list 'raised (render event) (render x)) seen))))
                    (case (car event)
                      ((bytes-arrived eof read-error) (fake-shell-deliver! fake event))
                      ;; A credit the fake's core refuses, where the libuv
                      ;; shell took it, is a difference the traces show, not
                      ;; a raise out of the suite.
                      ((body-credit)
                       (guard (e ((assertion-violation? e)
                                  (set! seen (cons (list 'refused (render event)) seen))))
                         (fake-shell-deliver! fake event)))
                      ((write-completed shutdown-completed closed) (fake-shell-deliver-later! fake))
                      ((tick) (fake-shell-fire! fake))
                      (else (values))))))
              events)
    (guard (x (#t (set! seen (cons (list 'raised 'settling (render x)) seen))))
      (fake-shell-settle! fake))
    (values fake (reverse seen))))

;; check-script! : Shell Nat Limits Boolean Script -> Void
;; Play `script` to the libuv shell `sh`, listening on `port`, replay its
;; events to a fake under `limits`, made on credit if `sh` was, and check the
;; three things the contract holds.
(define (check-script! sh port limits on-credit? script)
  (let* ((played (play! sh port script))
         (sent (car played)) (cl (cadr played)) (finished (caddr played))
         (libuv (reverse traced))
         (evs (reverse received))
         (name (car script)))
    (let-values (((fake fake-trace) (replay limits on-credit? evs (reverse written-at))))
      ;; No script resets its connection, so the client's end is the one
      ;; input besides the bytes: a read error there would be the libuv
      ;; shell's own, which the replay would hand the fake too.  A client
      ;; that stalls never ends its stream, and a bare close comes before
      ;; the client's end.
      (check name "the libuv shell read what the client sent, then its end alone, and closed"
             (list 'identical (if (or (stalls? script) (closes-bare? script)) '() '(eof)) 'satisfied)
             (list (compare-bytes sent (collector-bytes delivered))
                   (map car (filter (lambda (e) (memq (car e) '(eof read-error))) (map cdr evs)))
                   finished))
      ;; compare-bytes names the first byte that differs, the fake's then
      ;; the client's: (differs-at index fake libuv).
      (check name "the client read the bytes the fake shell wrote"
             'identical
             (compare-bytes (joined (fake-shell-writes fake)) (client-bytes cl)))
      (check name "the two shells' traces are identical"
             'identical
             (first-difference libuv fake-trace)))))

(run-suite "contract"
  (lambda ()
    (set! loop (make-uv-loop))
    ;; Each shell's wall clock is the loop's own (ONE CLOCK, above).
    (set! shell (make-shell loop held-handler default-limits (lambda () (uv-now loop))
                            (lambda (what details) #f) trace!))
    (let ((quick (make-shell loop held-handler quick-limits (lambda () (uv-now loop))
                             (lambda (what details) #f) trace!))
          (on-credit (make-shell loop held-handler default-limits (lambda () (uv-now loop))
                                 (lambda (what details) #f) trace! #t)))
      ;; A client the libuv shell never adopted, one that did not connect,
      ;; has no events to replay: the fake writes and traces nothing, so of
      ;; its script's checks only the first fails, naming how the connect
      ;; ended.
      (test-equal "a client the libuv shell never adopted replays as nothing"
                  '(() ())
                  (begin (set! adopted-at #f)
                         (let-values (((fake fake-trace) (replay default-limits #f '() '())))
                           (list (fake-shell-writes fake) fake-trace))))
      (let ((port (shell-listen! shell "127.0.0.1" 0)))
        (for-each (lambda (script) (check-script! shell port default-limits #f script)) scripts))
      (let ((port (shell-listen! quick "127.0.0.1" 0)))
        (for-each (lambda (script) (check-script! quick port quick-limits #f script)) stalling-scripts))
      (let ((port (shell-listen! on-credit "127.0.0.1" 0)))
        (for-each (lambda (script) (check-script! on-credit port default-limits #t script))
                  credit-scripts))

      (shell-shutdown! shell)
      (shell-shutdown! quick)
      (shell-shutdown! on-credit)
      (test-equal "at the end, no connection is left, and no handle on the loop" '(() () () ())
                  (begin (wait-for (lambda ()
                                     (for-all (lambda (sh) (eq? (uv-handle-state (shell-listener sh)) 'closed))
                                              (list shell quick on-credit))))
                         (list (shell-connections shell) (shell-connections quick)
                               (shell-connections on-credit) (uv-loop-live-handles loop)))))
    (uv-loop-teardown! loop)))
