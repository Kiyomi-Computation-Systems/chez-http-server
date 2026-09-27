#!r6rs
;;; (http-server connection): the staged close, end to end.  M3.5.
;;;
;;; After every response that closes the connection, the core closes it in
;;; stages (RFC 9112 §9.6; decided on the owner's word, 2026-09-26, decision
;;; 0011).  It shuts its write side, so the client reads the response and
;;; then the stream's end; it reads on and drops what arrives; and it closes
;;; when the client closes, when a read fails, or when the linger deadline
;;; passes.  Closing at once while the client still sends makes the server's
;;; TCP stack reset the connection, which fails a client's send before it
;;; reads the response, and throws away what of the response the kernel has
;;; not yet sent (measured, decision 0011).
;;;
;;; The core's own statuses are the originated suite's rows.  These rows drive
;;; the closes a request or a handler asks for, one per reason, each with a
;;; request pipelined behind it, and then the ways a linger ends.  A close
;;; after a close-delimited body is M6's: no response has one before then.
;;; A close with nothing to protect, at the client's end, a read error or the
;;; idle deadline, is at once: the table's T1, T2 and T5.
;;;
;;; Oracles: RFC 9112 §9.6 (the staged close) and §9.3 (HTTP/1.0 closes
;;; unless it says keep-alive); decision 0011 (every close after a response
;;; lingers, its deadline armed once); decision 0010 item 3 (a handler's
;;; `Connection: close`); decision 0006's amendment (an upgrade is served,
;;; then the connection closes).
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (fake-shell) (only (read-back) send! client-close! from-response))

(define (b s) (string->utf8 s))

(define get "GET / HTTP/1.1\r\nHost: x\r\n\r\n")

;; The handlers: one that answers, and one that asks to close.
(define (answers request) (make-response 200 #f '() (b "ok")))
(define (asks-to-close request)
  (make-response 200 #f (list (cons (b "Connection") (b "close"))) (b "ok")))

;; served : (Request -> Response) String -> Outcome
;; One connection reading `input` in one delivery, with `handler`, then every
;; later turn; then, as a client does once it has read a response that
;; closes, another request and its close, each delivered only while the
;; connection reads, as libuv delivers them; then every later turn.  The
;; outcome: how many requests the handler saw, the actions from the first
;; write on, and the phase and reason the connection ended with; or
;; `(raised)` if the run raised.
(define (served handler input)
  (guard (e (#t '(raised)))
    (let ((sh (make-fake-connection default-limits handler)))
      (send! sh input)
      (send! sh get)
      (client-close! sh)
      (fake-shell-settle! sh)
      (let ((s (fake-shell-conn-state sh)) (actions (fake-shell-actions sh)))
        (list (length (filter (lambda (a) (eq? (car a) 'call-handler)) actions))
              (from-response actions)
              (conn-phase s) (conn-close-after s))))))

;; staged : Symbol -> Outcome — one request handled and answered 200, then
;; the staged close, ended by the client's close, for `why`.  Like every
;; close, it disarms the deadline first (M5.2).
(define (staged why)
  (list 1 (list '(write 200) '(arm-deadline write)
                '(shutdown) '(read-start) '(arm-deadline linger)
                '(disarm-deadline) (list 'close why))
        'closed why))

;; lingering : -> FakeShell
;; A connection whose handler asked to close, its response written and
;; completed: it lingers.
(define (lingering)
  (let ((sh (make-fake-connection default-limits asks-to-close)))
    (send! sh get)
    sh))

;; after : FakeShell (FakeShell -> Any) -> (List (Listof Action) Phase CloseAfter)
;; What `move` makes a connection do, then every later turn: the actions it
;; asks for, and the phase and reason it is left in.
(define (after sh move)
  (let ((n (length (fake-shell-actions sh))))
    (move sh)
    (fake-shell-settle! sh)
    (let ((s (fake-shell-conn-state sh)))
      (list (list-tail (fake-shell-actions sh) n) (conn-phase s) (conn-close-after s)))))

;; linger-passes! : FakeShell -> Any
;; The linger deadline passes: the clock moves by the limit, and the fake's
;; timer fires, which ticks the connection once its deadline has passed
;; (M5.3).  The core reads no clock; the tick is what tells it.
(define (linger-passes! sh)
  (fake-shell-advance! sh (limits-linger-timeout-ms default-limits))
  (fake-shell-fire! sh))

(define websocket
  (string-append "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                 "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"))

(run-suite "connection-linger"
  (lambda ()
    ;; --- every close a request or a handler asks for lingers ----------------
    ;; The request behind the first, in the same delivery, is the pause's
    ;; pending input, dropped; the one sent while the connection lingers is
    ;; dropped too.  Neither is fed to the parser or answered.
    (test-equal "a request's Connection: close: answered, then the staged close"
                (staged 'not-keep-alive)
                (served answers (string-append "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" get)))
    (test-equal "HTTP/1.0 without keep-alive: answered, then the staged close"
                (staged 'not-keep-alive)
                (served answers (string-append "GET / HTTP/1.0\r\n\r\n" get)))
    (test-equal "a handler's Connection: close: answered, then the staged close"
                (staged 'handler-close)
                (served asks-to-close (string-append get get)))
    (test-equal "an upgrade: served, then the staged close"
                (staged 'upgrade)
                (served answers (string-append websocket get)))
    ;; The contrast: a connection kept alive never half-closes.  Its client
    ;; sends a third request, reads the answer, and closes; that close has
    ;; no response to protect, so it is at once (the table's T1).
    (test-equal "a request that keeps the connection: every one answered, no half-close, the client's close at once"
                '(3 ((close eof)) closed #f)
                (let ((o (served answers (string-append get get))))
                  (list (car o) (filter (lambda (a) (memq (car a) '(shutdown close))) (cadr o))
                        (caddr o) (cadddr o))))

    ;; --- the ways a linger ends ----------------------------------------------
    (test-equal "a client that never closes: the linger deadline closes the connection"
                '(((disarm-deadline) (close handler-close)) closed handler-close)
                (after (lingering) linger-passes!))
    ;; The deadline is armed once, when lingering starts: what arrives is
    ;; dropped and asks for nothing, so a client that keeps sending cannot
    ;; hold the connection past it.
    (test-equal "a client that keeps sending: nothing fed, the deadline not re-armed, and it still closes"
                '(((disarm-deadline) (close handler-close)) closed handler-close)
                (after (lingering)
                       (lambda (sh)
                         (send! sh get)
                         (send! sh "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n")
                         (send! sh "123456789")
                         (linger-passes! sh))))
    (test-equal "a read error while lingering: logged, then the close"
                '(((log read-error ECONNRESET) (disarm-deadline) (close read-error)) closed handler-close)
                (after (lingering) (lambda (sh) (fake-shell-deliver! sh '(read-error ECONNRESET)))))
    (test-equal "the half-close's completion changes nothing: the connection lingers, reading"
                '((() lingering handler-close) #t)
                (let ((sh (lingering)))
                  (list (after sh (lambda (sh) (fake-shell-deliver! sh '(shutdown-completed))))
                        (fake-shell-reading? sh))))))
