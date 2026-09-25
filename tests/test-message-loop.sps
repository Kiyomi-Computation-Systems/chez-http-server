#!r6rs
;;; (http-server connection) through the fake shell's message loop.  M2.4.
;;;
;;; Decision 0004 item 1's cycle, and the whole of serial pipelining, with
;;; chez-httparse driving the core through the adapter: at on-message-complete
;;; the core pauses the parser, stops reading and calls the handler; the rest
;;; of the delivery is kept from `parser-result-next`; after the response the
;;; parser resumes, the rest is fed, and reading starts again.  After a
;;; close-marked message nothing more is fed (0004 item 4).
;;;
;;; The fake shell runs every action the core asks for after the outermost
;;; dispatch, from one queue (design §4.5).  Only `reply-parser` is answered
;;; inside a parser callback, by the adapter; an action run anywhere but the
;;; outermost drain is a violation the shell records (design §6.4).
;;;
;;; The rows:
;;;   - one keep-alive request runs design §4.4's happy path in order;
;;;   - the pipelining boundary: when the handler runs, the rest of the
;;;     delivery is kept from where the parser stopped, and the resume feeds
;;;     exactly that;
;;;   - after a close-marked message the next one is never fed, and the
;;;     parser's "Data after `Connection: close`" error never fires;
;;;   - one message at a time: from a call-handler to the resume after its
;;;     response, the parser is not fed and the socket is not read;
;;;   - a handler that raises is answered 500, then close;
;;;   - an upgrade (a WebSocket handshake, a CONNECT, `Upgrade: h2c`) is
;;;     served, then the connection closes, and the bytes after it are never
;;;     read; the HTTP/2 preface is answered 505, then close (M2.5);
;;;   - at every delivery size, the same handlers, responses and close, and
;;;     every action run from the outermost drain.
;;;
;;; Oracles: design §4.4's rows in order; the input's own bytes (the spike's
;;; three messages are 51, 47 and 19 bytes, so the parser stops at 51 and
;;; 98 of 117, as research/spike/pipeline-pause.sps measured on 2026-09-19
;;; and again on 2026-09-25 at the pin); decision 0004 items 1 and 4;
;;; decision 0006 as amended on the owner's word, 2026-09-25.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server span) (http-server limits) (fake-shell))

(define (b s) (string->utf8 s))

(define resp (make-response 200 #f '() (b "ok")))

;; render-request : Request -> Datum — the request as its bytes.
(define (render-request r)
  (list (request-method r) (utf8->string (span->bytevector (request-target r)))
        (request-http-major r) (request-http-minor r)
        (map (lambda (h) (cons (utf8->string (span->bytevector (car h)))
                               (utf8->string (span->bytevector (cdr h)))))
             (request-headers r))))

;; render-action : Action -> Datum
;; A request or a response is a record, so it is rendered by its contents.
(define (render-action a)
  (case (car a)
    ((call-handler hand-off) (list (car a) (render-request (cadr a))))
    ((write) (list 'write (response-status (cadr a))))
    (else a)))

;; connection : Limits [(Request -> Response)] -> (values FakeShell (-> (Listof Pending)))
;; A fake connection whose handler is `answer` (by default, `resp` to every
;; request), and a thunk giving the pending input the core held each time
;; the handler ran, in order.
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
                   (answer request)))))
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

;; The spike's three messages: a POST with a body, a GET that asks to
;; close, and a GET after it.
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

;; serial? : FakeShell -> Boolean
;; From each call-handler to the resume after its response, no feed-parser
;; and no read-start, and reading was stopped before the handler was called.
(define (serial? sh)
  (let loop ((as (fake-shell-actions sh)) (handling #f) (reading #t))
    (cond ((null? as) #t)
          (else
           (let ((kind (car (car as))))
             (case kind
               ((call-handler) (and (not handling) (not reading) (loop (cdr as) #t reading)))
               ((resume-parser) (loop (cdr as) #f reading))
               ((feed-parser) (and (not handling) (loop (cdr as) handling reading)))
               ((read-stop) (loop (cdr as) handling #f))
               ((read-start) (and (not handling) (loop (cdr as) handling #t)))
               (else (loop (cdr as) handling reading))))))))

(run-suite "message-loop"
  (lambda ()
    ;; --- design §4.4's happy path, in order ---------------------------------
    ;; H1 feeds; the callbacks' actions (H2, H4, H6) run after the feed; the
    ;; handler's response (H7) after them; the write's completion (H9) later.
    (let* ((input (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"))
           (sh (run input (bytevector-length input) default-limits)))
      (test-equal "one keep-alive request: design §4.4's rows, in order"
                  `((feed-parser ,input 0 28)
                    (disarm-deadline) (arm-deadline header)
                    (disarm-deadline) (arm-deadline body)
                    (read-stop) (disarm-deadline) (call-handler (GET "/a" 1 1 (("Host" . "x"))))
                    (write 200) (arm-deadline write)
                    (resume-parser) (read-start) (arm-deadline idle))
                  (map render-action (fake-shell-actions sh)))
      (test-equal "and nothing ran inside a feed" '() (fake-shell-violations sh)))

    ;; --- the pipelining boundary (0004 item 1) --------------------------------
    ;; Delivered whole, the parser stops at 51, the first message's end; the
    ;; handler runs with [51, 117) kept; the resume feeds exactly that; the
    ;; parser stops at 98 and the second handler runs with [98, 117) kept.
    (let ((boundary (guard (e (#t (list 'raised e)))
                      (let-values (((sh seen) (connection default-limits)))
                        (fake-shell-feed-input! sh spike (bytevector-length spike))
                        (list (seen) (feeds sh))))))
      (test-equal "the rest of the delivery is kept from where the parser stopped: 51, then 98"
                  `((,spike 51 117) (,spike 98 117))
                  (car boundary))
      (test-equal "the resume feeds exactly the rest; after the close-marked GET, nothing"
                  '((0 117) (51 117))
                  (cadr boundary)))

    ;; --- a close-marked message ends the reading (0004 item 4) -----------------
    ;; GET /c is never fed, so no "Data after `Connection: close`" and no 400.
    (test-equal "the spike's messages, every delivery size: two handled, then close"
                (list (list (list (list 'call-handler post-a) '(write 200)
                                  (list 'call-handler get-b) '(write 200)
                                  '(close not-keep-alive))
                            'closed))
                (every-size spike default-limits outcome))
    (test-equal "the parser never reported an error"
                '(#f)
                (every-size spike default-limits
                            (lambda (sh)
                              (exists (lambda (ev) (and (eq? (car ev) 'parser-result)
                                                        (eq? (cadr ev) 'error)))
                                      (fake-shell-events sh)))))
    ;; Delivered a byte at a time, the input after GET /b is never read: the
    ;; connection stopped reading at its pause and closed after its response.
    (test-eqv "a byte at a time, the 19 bytes after the close-marked GET are never delivered"
              98
              (let-values (((sh seen) (connection default-limits)))
                (fake-shell-feed-input! sh spike 1)))

    ;; --- one message at a time ------------------------------------------------
    (test-equal "three pipelined GETs, every delivery size: served in order, the connection idle"
                (list (list (list (list 'call-handler (get "1")) '(write 200)
                                  (list 'call-handler (get "2")) '(write 200)
                                  (list 'call-handler (get "3")) '(write 200))
                            'idle))
                (every-size three default-limits outcome))
    (test-equal "from a call-handler to its resume, the parser is not fed nor the socket read"
                '(#t)
                (every-size three default-limits serial?))

    ;; --- a handler that raises (design §4.4 T6) --------------------------------
    ;; The fake shell answers a raise with handler-failed: a 500, then close,
    ;; and the next message is never handled.
    (test-equal "a handler that raises: 500, then close, every delivery size"
                (list (list (list (list 'call-handler (get "1")) '(write 500)
                                  '(close handler-failed))
                            'closed))
                (every-size three default-limits
                            (lambda (sh) (outcome sh))
                            (lambda (request) (raise 'boom))))

    ;; --- upgrades (M2.5; decided on the owner's word, 2026-09-25) ---------------
    ;; An upgrade is served like any request, and the connection closes after
    ;; the response: the bytes after the request are another protocol's, so
    ;; they are never read (decision 0006's amendment).  `Upgrade: h2c`, what
    ;; `curl --http2` sends to an http:// URL, is an upgrade like any other.
    (test-equal "a WebSocket handshake, every delivery size: served, then close"
                (list (list (list (list 'call-handler (list 'GET "/chat" 1 1 (list ws-host ws-conn ws-up)))
                                  '(write 200) '(close upgrade))
                            'closed))
                (every-size websocket default-limits outcome))
    (test-eqv "a byte at a time, the frame after the handshake is never delivered"
              (- (bytevector-length websocket) 5)
              (let-values (((sh seen) (connection default-limits)))
                (fake-shell-feed-input! sh websocket 1)))
    (test-equal "a CONNECT, every delivery size: served, then close"
                (list (list (list (list 'call-handler '(CONNECT "example.com:443" 1 1 (("Host" . "example.com:443"))))
                                  '(write 200) '(close upgrade))
                            'closed))
                (every-size (b "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nTUNNEL")
                            default-limits outcome))
    (test-equal "Upgrade: h2c, every delivery size: served like any upgrade, then close"
                '(((close upgrade)))
                (every-size (b (string-append "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\n"
                                              "Upgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n"))
                            default-limits
                            (lambda (sh) (filter (lambda (a) (eq? (car a) 'close)) (fake-shell-actions sh)))))
    ;; The HTTP/2 preface hands off on the parser's error channel; with no
    ;; HTTP/2 to hand to, it is answered 505 and no handler runs (0006 item 2).
    (test-equal "the HTTP/2 preface, every delivery size: 505, then close"
                (list (list (list '(write 505) '(close http2-preface)) 'closed))
                (every-size (b "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nFRAME") default-limits outcome))

    ;; --- run to completion (design §4.5, §6.4) ---------------------------------
    (test-equal "every action ran from the outermost drain, at every delivery size"
                '(())
                (every-size three default-limits fake-shell-violations))
    (test-equal "the spike's messages too"
                '(())
                (every-size spike default-limits fake-shell-violations))
    (test-equal "a WebSocket handshake too"
                '(())
                (every-size websocket default-limits fake-shell-violations))))
