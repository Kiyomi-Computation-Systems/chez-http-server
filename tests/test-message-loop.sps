#!r6rs
;;; (http-server connection) through the fake shell's message loop.
;;;
;;; The cycle of serial pipelining, with chez-httparse driving the core
;;; through the adapter: at on-message-complete the core pauses the parser and
;;; calls the handler; the rest of the delivery is kept from
;;; `parser-result-next`; after the response the parser resumes and the rest
;;; is fed.  Reading goes on past the message's end only to notice the client
;;; close: what arrives before the response is held, never fed until the
;;; resume, and reading stops.  After a close-marked message nothing more is
;;; fed.
;;;
;;; The fake shell runs every action the core asks for after the outermost
;;; dispatch, from one queue.  Only `reply-parser` is answered inside a parser
;;; callback, by the adapter; an action run anywhere but the outermost drain is
;;; a violation the shell records.
;;;
;;; The rows:
;;;   - one keep-alive request runs the transition table's happy path (rows
;;;     H1-H9 of test-connection-table.sps) in order;
;;;   - the events a later turn brings are delivered one at a time on request,
;;;     oldest first, as the contract test needs;
;;;   - the pipelining boundary: when the handler runs, the rest of the
;;;     delivery is kept from where the parser stopped, and the resume feeds
;;;     exactly that;
;;;   - after a close-marked message the next one is never fed, and the
;;;     parser's "Data after `Connection: close`" error never fires;
;;;   - one message at a time: from a message's end to the resume after its
;;;     response, the parser is not fed, and one handler is asked from one
;;;     resume to the next (the POST is read by its handler, whose head
;;;     announces a body);
;;;   - a client's close: a waiting handler whose client ends while it waits
;;;     is told, its wait raising `&client-closed`, and, letting it out, is
;;;     answered nothing; one that catches it and answers is written to, a
;;;     client that only half-closed reading on, then the close, at once; a
;;;     request that arrives while a handler waits is held and served after,
;;;     two that arrive together among them, and judged where the parser
;;;     stopped; an end that comes with requests held behind tells no one, and
;;;     they are answered before the close, which a request it cut short has
;;;     at its cut, and an empty line held once it is read;
;;;   - a handler that raises is answered 500, then close;
;;;   - an upgrade (a WebSocket handshake, a CONNECT, `Upgrade: h2c`) is
;;;     served, then the connection closes, and the bytes after it are never
;;;     fed; the HTTP/2 preface is answered 505, then close;
;;;   - at every delivery size, the same handlers, responses and close, and
;;;     every action run from the outermost drain.
;;; A connection closes after a response in stages: it lingers, reading and
;;; dropping what arrives, until the client closes, and no client closes here.
;;; So a row that closes ends in `lingering`, its reason the close-after, and
;;; the bytes after the last message are read once its response is written,
;;; and never fed.
;;;
;;; Oracles: the transition table's rows in order; the input's own bytes (the
;;; three pipelined messages are 51, 47 and 19 bytes, so the parser stops at 51
;;; and 98 of 117); RFC 9110 §7.8, which lets a server ignore an upgrade it
;;; does not take.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server span) (http-server limits) (http-server switch) (fake-shell)
        (only (http-server awaiting) awaiting client-closed?)
        (only (http-server private waits) sleep-ms))

(define (b s) (string->utf8 s))

(define resp (make-response 200 #f '() (b "ok")))

;; reading : Request -> BodyReader
;; A handler that reads every request's body, dropping it, and answers
;; `resp`.  A request whose head announces a body is handed to its handler
;; at the head, and a response given instead of a reader closes the
;; connection, so the rows that pipeline past the POST read its body.
(define reading (drops-body (lambda (request) resp)))

;; render-request : Request -> Datum — the request as its bytes.
(define (render-request r)
  (list (request-method r) (utf8->string (span->bytevector (request-target r)))
        (request-http-major r) (request-http-minor r)
        (map (lambda (h) (cons (utf8->string (span->bytevector (car h)))
                               (utf8->string (span->bytevector (cdr h)))))
             (request-headers r))))

;; render-action : Action -> Datum
;; A request is a record, so it is rendered by its contents; a write, by the
;; status its segments write; a hand-off, by the bytes it hands over, as
;; text, or #f.
(define (render-action a)
  (case (car a)
    ((call-handler) (list 'call-handler (render-request (cadr a))))
    ((hand-off) (list 'hand-off (let ((r (caddr a)))
                                  (and r (let ((o (make-bytevector (- (caddr r) (cadr r)))))
                                           (bytevector-copy! (car r) (cadr r) o 0 (bytevector-length o))
                                           (utf8->string o))))))
    ((write) (list 'write (written-status a)))
    (else a)))

;; traces : EqHashtable FakeShell -> (Listof (Pair Symbol Datum))
;; Each connection's trace, newest first: every event dispatched and every
;; action run, in order, as `(event . e)` and `(action . a)`.
(define traces (make-eq-hashtable))

;; trace-of : FakeShell -> (Listof (Pair Symbol Datum)) — in order.
(define (trace-of sh) (reverse (hashtable-ref traces sh '())))

;; connection : Limits [(Request -> Response)] -> (values FakeShell (-> (Listof Pending)))
;; A fake connection whose handler is `answer` (by default, `resp` to every
;; request), and a thunk giving the pending input the core held each time
;; the handler ran, in order.  Its trace is kept (trace-of).
(define connection
  (case-lambda
    ((limits) (connection limits (lambda (request) resp)))
    ((limits answer)
     (let* ((seen '())
            (cell #f)
            (sh (make-fake-connection
                 limits
                 (lambda (request)
                   (set! seen (cons (conn-pending (fake-shell-conn-state cell)) seen))
                   (answer request))
                 (lambda (kind datum)
                   (hashtable-update! traces cell (lambda (t) (cons (cons kind datum) t)) '())))))
       (set! cell sh)
       (values sh (lambda () (reverse seen)))))))

;; run : Bytevector Nat Limits [(Request -> Response)] -> FakeShell
;; One connection reading `input` in `size`-byte deliveries.
(define (run input size limits . answer)
  (let-values (((sh seen) (apply connection limits answer)))
    (fake-shell-feed-input! sh input size)
    sh))

;; outcome : FakeShell -> Datum
;; What the connection did: the handlers called, the responses written, the
;; close and any hand-off, in order, and the state it ended in.
(define (outcome sh)
  (list (map render-action
             (filter (lambda (a) (memq (car a) '(call-handler write close hand-off)))
                     (fake-shell-actions sh)))
        (conn-phase (fake-shell-conn-state sh))))

;; every-size : Bytevector Limits (FakeShell -> Datum) [(Request -> Response)]
;;              -> (Listof Datum)
;; The distinct answers of `view` over every delivery size from 1 to the
;; whole input, so one expected answer is chunk invariance as well.
(define (every-size input limits view . answer)
  (let loop ((size 1) (seen '()))
    (if (> size (bytevector-length input))
        (reverse seen)
        (let ((o (view (apply run input size limits answer))))
          (loop (+ size 1) (if (member o seen) seen (cons o seen)))))))

;; Three messages: a POST with a body, a GET that asks to close, and a GET
;; after it.
(define spike
  (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
                    "GET /b HTTP/1.1\r\nHost: y\r\nConnection: close\r\n\r\n"
                    "GET /c HTTP/1.1\r\n\r\n")))
(define post-a '(POST "/a" 1 1 (("Host" . "x") ("Content-Length" . "3"))))
(define get-b '(GET "/b" 1 1 (("Host" . "y") ("Connection" . "close"))))

;; Three keep-alive GETs.
(define three
  (b (string-append "GET /1 HTTP/1.1\r\nHost: x\r\n\r\n"
                    "GET /2 HTTP/1.1\r\nHost: x\r\n\r\n"
                    "GET /3 HTTP/1.1\r\nHost: x\r\n\r\n")))
(define (get n) (list 'GET (string-append "/" n) 1 1 '(("Host" . "x"))))

;; A WebSocket handshake and the 5 bytes of a frame after it.
(define websocket
  (b "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\nFRAME"))
(define ws-host '("Host" . "x"))
(define ws-conn '("Connection" . "upgrade"))
(define ws-up '("Upgrade" . "websocket"))

;; feeds : FakeShell -> (Listof (List Nat Nat)) — the ranges the parser was fed.
(define (feeds sh)
  (map (lambda (a) (list (caddr a) (cadddr a)))
       (filter (lambda (a) (eq? (car a) 'feed-parser)) (fake-shell-actions sh))))

;; fed : FakeShell -> Nat — how many bytes the parser was fed.
(define (fed sh) (fold-left (lambda (n f) (+ n (- (cadr f) (car f)))) 0 (feeds sh)))

;; serial? : FakeShell -> Boolean
;; One message at a time: from each message's end, a paused
;; `parser-result`, to the resume after its response, no feed-parser; and
;; one handler asked from one resume to the next.  Reading goes on past the
;; end only to notice the client close: what arrives is held, and its
;; read-stop changes nothing here.  A read-stop with no message ended is a
;; request waiting on its handler with its body still to come, which stops
;; reading until the handler's reader answers and reading starts again:
;; nothing is fed meanwhile.  A response that closes the connection has no
;; resume: its staged close begins with the shutdown, after which the socket
;; is read again, to drop what arrives, but nothing is fed, handled or
;; resumed.  (The handler of a request whose head announces a body is asked
;; once the head is in, and its body read after.)
(define (serial? sh)
  (let loop ((t (trace-of sh)) (ended #f) (waiting #f) (closed #f) (asked #f))
    (cond ((null? t) #t)
          ((eq? (caar t) 'event)
           (let ((e (cdar t)))
             (loop (cdr t)
                   (or (and (eq? (car e) 'parser-result) (eq? (cadr e) 'paused)) ended)
                   waiting closed asked)))
          (else
           (let ((kind (car (cdar t))))
             (case kind
               ((read-stop) (loop (cdr t) ended (or waiting (not ended)) closed asked))
               ((call-handler) (and (not asked) (loop (cdr t) ended waiting closed #t)))
               ((resume-parser) (and (not closed) (loop (cdr t) #f #f #f #f)))
               ((feed-parser) (and (not ended) (not waiting) (loop (cdr t) ended waiting closed asked)))
               ((read-start) (loop (cdr t) ended #f closed asked))
               ((shutdown) (loop (cdr t) ended waiting #t asked))
               (else (loop (cdr t) ended waiting closed asked))))))))

;; --- a client's close ---------------------------------------------------------

;; get-bytes : String -> Bytevector — a GET of `path` with a Host.
(define (get-bytes path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; deliver : FakeShell Bytevector -> Void — one delivery of all of `bv`.
(define (deliver sh bv) (fake-shell-deliver! sh (list 'bytes-arrived bv 0 (bytevector-length bv))))

;; waits-then : Nat (-> Any) -> (Request -> Answer)
;; A handler that, for /a, waits `ms` then answers `resp` (what `then` does
;; with the wait's raise aside), and answers every other request at once.
(define (waits-then ms on-close)
  (lambda (request)
    (if (string=? (utf8->string (span->bytevector (request-target request))) "/a")
        (awaiting (lambda () (guard (e ((client-closed? e) (on-close e))) (sleep-ms ms) resp)))
        resp)))

(run-suite "message-loop"
  (lambda ()
    ;; --- the transition table's happy path, in order ------------------------
    ;; H1 feeds; the callbacks' actions (H2, H4, H6) run after the feed; the
    ;; handler's response (H7) after them; the write's completion (H9) later.
    (let* ((input (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"))
           (sh (run input (bytevector-length input) default-limits)))
      (test-equal "one keep-alive request: the transition table's rows, in order"
                  `((feed-parser ,input 0 28)
                    (disarm-deadline) (arm-deadline header)
                    (disarm-deadline) (arm-deadline body)
                    (disarm-deadline) (call-handler (GET "/a" 1 1 (("Host" . "x"))))
                    (write 200) (arm-deadline write)
                    (resume-parser) (read-start) (arm-deadline idle))
                  (map render-action (fake-shell-actions sh)))
      (test-equal "and nothing ran inside a feed" '() (fake-shell-violations sh)))

    ;; --- a later turn, one event at a time ---------------------------------------
    ;; The contract test delivers the fake's completions where the libuv shell
    ;; delivered its own, so the fake hands them over one at a time, oldest
    ;; first.  A close-marked GET: its write completes, the half-close is
    ;; asked for, and the client's end, arriving before the half-close has
    ;; completed, closes the connection; two completions then wait, in order.
    (let-values (((sh seen) (connection default-limits)))
      (let ((input (b "GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
            (next (lambda () (let ((e (fake-shell-deliver-later! sh))) (if e (car e) 'none)))))
        (fake-shell-deliver! sh (list 'bytes-arrived input 0 (bytevector-length input)))
        (let ((written (next)))
          (fake-shell-deliver! sh '(eof))
          (let* ((shut (next)) (closed (next)) (after (next)))
            (test-equal "a later turn's events are delivered one at a time, oldest first, then none"
                        '(write-completed shutdown-completed closed none)
                        (list written shut closed after))))))

    ;; --- the pipelining boundary ----------------------------------------------
    ;; Delivered whole, the parser stops at 51, the first message's end; the
    ;; handler runs with [51, 117) kept; the resume feeds exactly that; the
    ;; parser stops at 98 and the second handler runs with [98, 117) kept.
    ;; The POST's head announces a body, so its handler is asked with the
    ;; feed's result, once the feed has returned.
    (let ((boundary (guard (e (#t (list 'raised e)))
                      (let-values (((sh seen) (connection default-limits reading)))
                        (fake-shell-feed-input! sh spike (bytevector-length spike))
                        (list (seen) (feeds sh))))))
      (test-equal "the rest of the delivery is kept from where the parser stopped: 51, then 98"
                  `((,spike 51 117) (,spike 98 117))
                  (car boundary))
      (test-equal "the resume feeds exactly the rest; after the close-marked GET, nothing"
                  '((0 117) (51 117))
                  (cadr boundary)))

    ;; --- a close-marked message ends the reading -------------------------------
    ;; GET /c is never fed, so no "Data after `Connection: close`" and no 400.
    (test-equal "the POST and two GETs, every delivery size: two handled, then the staged close"
                (list (list (list (list 'call-handler post-a) '(write 200)
                                  (list 'call-handler get-b) '(write 200))
                            'lingering))
                (every-size spike default-limits outcome reading))
    ;; The close-marked GET's response has no resume: its staged close
    ;; begins with the shutdown, after which the socket is read again, and
    ;; nothing is fed, handled or resumed.
    (test-equal "from a message's end to its resume, or to its staged close, the parser is not fed nor the socket read"
                '(#t)
                (every-size spike default-limits serial? reading))
    (test-equal "the parser never reported an error"
                '(#f)
                (every-size spike default-limits
                            (lambda (sh)
                              (exists (lambda (ev) (and (eq? (car ev) 'parser-result)
                                                        (eq? (cadr ev) 'error)))
                                      (fake-shell-events sh)))
                            reading))
    ;; Delivered a byte at a time, the input after GET /b is read only once
    ;; its response is written: the connection stopped reading at its pause,
    ;; and reads again only to linger, dropping what arrives.  So all 117
    ;; bytes are delivered, and the parser is fed the first 98 alone.
    (test-equal "a byte at a time, the 19 bytes after the close-marked GET are read only while lingering, never fed"
                '(117 98 lingering)
                (let-values (((sh seen) (connection default-limits reading)))
                  (let ((delivered (fake-shell-feed-input! sh spike 1)))
                    (list delivered (fed sh) (conn-phase (fake-shell-conn-state sh))))))

    ;; --- one message at a time ------------------------------------------------
    (test-equal "three pipelined GETs, every delivery size: served in order, the connection idle"
                (list (list (list (list 'call-handler (get "1")) '(write 200)
                                  (list 'call-handler (get "2")) '(write 200)
                                  (list 'call-handler (get "3")) '(write 200))
                            'idle))
                (every-size three default-limits outcome))
    (test-equal "from a message's end to its resume, the parser is not fed nor the socket read"
                '(#t)
                (every-size three default-limits serial?))

    ;; --- a handler that raises -------------------------------------------------
    ;; The fake shell answers a raise with handler-failed: a 500, then close,
    ;; and the next message is never handled.
    (test-equal "a handler that raises: 500, then the staged close, every delivery size"
                (list (list (list (list 'call-handler (get "1")) '(write 500))
                            'lingering))
                (every-size three default-limits
                            (lambda (sh) (outcome sh))
                            (lambda (request) (raise 'boom))))

    ;; --- upgrades ---------------------------------------------------------------
    ;; An upgrade is served like any request, and the connection closes after
    ;; the response: the bytes after the request are another protocol's, so
    ;; they are never read (RFC 9110 §7.8 lets a server ignore an upgrade).
    ;; `Upgrade: h2c`, what `curl --http2` sends to an http:// URL, is an
    ;; upgrade like any other.
    (test-equal "a WebSocket handshake, every delivery size: served, then the staged close"
                (list (list (list (list 'call-handler (list 'GET "/chat" 1 1 (list ws-host ws-conn ws-up)))
                                  '(write 200))
                            'lingering))
                (every-size websocket default-limits outcome))
    (test-equal "a byte at a time, the frame after the handshake is read only while lingering, never fed"
                (list (bytevector-length websocket) (- (bytevector-length websocket) 5) 'lingering)
                (let-values (((sh seen) (connection default-limits)))
                  (let ((delivered (fake-shell-feed-input! sh websocket 1)))
                    (list delivered (fed sh) (conn-phase (fake-shell-conn-state sh))))))
    (test-equal "a CONNECT, every delivery size: served, then the staged close"
                (list (list (list (list 'call-handler '(CONNECT "example.com:443" 1 1 (("Host" . "example.com:443"))))
                                  '(write 200))
                            'lingering))
                (every-size (b "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nTUNNEL")
                            default-limits outcome))
    (test-equal "Upgrade: h2c, every delivery size: served like any upgrade, then the staged close"
                '((lingering upgrade))
                (every-size (b (string-append "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\n"
                                              "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n"))
                            default-limits
                            (lambda (sh)
                              (let ((s (fake-shell-conn-state sh))) (list (conn-phase s) (conn-close-after s))))))
    ;; The HTTP/2 preface hands off on the parser's error channel; with no
    ;; HTTP/2 to hand to, it is answered 505 and no handler runs.  Taken by a
    ;; handler's switch, the handshake's 101 is written and the stream handed
    ;; off, with the bytes after the request.
    (test-equal "a WebSocket handshake taken by a switch, read whole: its 101, then handed off with the bytes after it"
                (list (list (list 'call-handler (list 'GET "/chat" 1 1 (list ws-host ws-conn ws-up)))
                            '(write 101) '(hand-off "FRAME"))
                      'handed-off)
                (outcome (run websocket (bytevector-length websocket) default-limits
                              (lambda (request)
                                (switch-protocols (list (cons (b "Upgrade") (b "websocket")))
                                                  (lambda (transport retained) #t))))))
    (test-equal "the HTTP/2 preface, every delivery size: 505, then the staged close"
                (list (list (list '(write 505)) 'lingering))
                (every-size (b "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nFRAME") default-limits outcome))

    ;; --- run to completion -----------------------------------------------------
    (test-equal "every action ran from the outermost drain, at every delivery size"
                '(())
                (every-size three default-limits fake-shell-violations))
    (test-equal "the POST and two GETs too"
                '(())
                (every-size spike default-limits fake-shell-violations reading))
    (test-equal "a WebSocket handshake too"
                '(())
                (every-size websocket default-limits fake-shell-violations))

    ;; --- a client's close ---------------------------------------------------------
    ;; GET /a's handler waits 1000 ms; the client's end comes meanwhile.
    (let* ((told #f)
           (sh (make-fake-connection default-limits
                                     (waits-then 1000 (lambda (e) (set! told #t) (raise e))))))
      (deliver sh (get-bytes "/a"))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "a waiting handler whose client ends while it waits is told, and letting the raise out is answered nothing: the connection closes for the client"
                  '(told (((call-handler (GET "/a" 1 1 (("Host" . "x")))) (close client-closed)) closed))
                  (list (if told 'told 'not-told) (outcome sh))))

    (let ((sh (make-fake-connection default-limits (waits-then 1000 (lambda (e) resp)))))
      (deliver sh (get-bytes "/a"))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "one that catches it and answers is written to, a client that only half-closed reading on, then closes for the client at once, with no linger"
                  '((((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200) (close client-closed)) closed)
                    no-shutdown)
                  (list (outcome sh)
                        (if (memq 'shutdown (map car (fake-shell-actions sh))) 'shutdown 'no-shutdown))))

    ;; GET /b arrives while GET /a's handler waits 10 ms.  (Fed before the
    ;; resume, its bytes would meet a paused parser, which byte-machine
    ;; refuses by raising.)
    (let ((sh (make-fake-connection default-limits (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (get-bytes "/a"))
      (deliver sh (get-bytes "/b"))
      (let ((reading (fake-shell-reading? sh)))
        (fake-shell-advance! sh 10)
        (fake-shell-fire-waits! sh)
        (fake-shell-settle! sh)
        (test-equal "a request that arrives while a handler waits is held, reading stopped, and served after the response, in order"
                    '(#f (((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200)
                           (call-handler (GET "/b" 1 1 (("Host" . "x")))) (write 200))
                          idle)
                         #t)
                    (list reading (outcome sh) (fake-shell-reading? sh)))))

    ;; GET /a and GET /b in one delivery, then the client's end, while /a's
    ;; handler waits 10 ms.
    (let ((sh (make-fake-connection default-limits (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n\r\n" "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "an end that comes with a request held behind the one answered tells no one: both are answered, then the connection closes"
                  '(((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200)
                     (call-handler (GET "/b" 1 1 (("Host" . "x")))) (write 200) (close eof))
                    closed)
                  (outcome sh)))

    (let ((sh (make-fake-connection default-limits (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n\r\n" "GET /b HT")))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "and with a request held that the end cut short, the one before it is answered, then the connection closes at the cut"
                  '(((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200) (close eof)) closed)
                  (outcome sh)))

    ;; GET /b and GET /c arrive together while GET /a's handler waits 10 ms:
    ;; held as one, the parser fed them from where it stopped.
    (let ((sh (make-fake-connection default-limits (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (get-bytes "/a"))
      (deliver sh (b (string-append "GET /b HTTP/1.1\r\nHost: x\r\n\r\n" "GET /c HTTP/1.1\r\nHost: x\r\n\r\n")))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "two requests that arrive together while a handler waits are both held, and served after it, in order"
                  '(((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200)
                     (call-handler (GET "/b" 1 1 (("Host" . "x")))) (write 200)
                     (call-handler (GET "/c" 1 1 (("Host" . "x")))) (write 200))
                    idle)
                  (outcome sh)))

    ;; A held request is judged as one fed at once: the 10 spaces before its
    ;; value counted with it, 11 bytes past a limit of 8.
    (let ((sh (make-fake-connection (limits-with default-limits '((max-header-value-bytes . 8)))
                                    (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (get-bytes "/a"))
      (deliver sh (b "GET /b HTTP/1.1\r\nHost: x\r\nX-Pad:          y\r\n\r\n"))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "a held request is judged where the parser stopped: its value's padding past the limit, 431"
                  '(((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200) (write 431)) lingering)
                  (outcome sh)))

    ;; GET /a and an empty line, then the client's end, while /a's handler
    ;; waits 10 ms: the empty line is all that is left.
    (let ((sh (make-fake-connection default-limits (waits-then 10 (lambda (e) (raise e))))))
      (deliver sh (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\n\r\n"))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "and with only an empty line held after the end, the request is answered, then the connection closes"
                  '(((call-handler (GET "/a" 1 1 (("Host" . "x")))) (write 200) (close eof)) closed)
                  (outcome sh)))))
