#!r6rs
;;; (http-server connection): each deadline the core arms, reached as a
;;; client reaches it, then passed.  M5.2.
;;;
;;; A connection has one deadline armed at a time, of five kinds (design
;;; §4.3; decision 0011), and the shell's wheel ticks it once that deadline
;;; has passed (decision 0005; M5.3 builds the wheel into both shells).
;;; Every kind has its tick row (design §4.4, amended 2026-09-27), and each
;;; row here reaches one on a fake connection, the way a client does:
;;;   idle    a keep-alive client that sends nothing more: closed, with no
;;;           response;
;;;   header  a head never finished: 408, then the staged close;
;;;   body    a body never finished: 408, then the staged close;
;;;   write   a response the client never reads: logged, with the bytes
;;;           still outstanding, and closed, with no response, since nothing
;;;           more can be written to it.  The write the close cuts short is
;;;           settled when the shell reports it (M3.3);
;;;   linger  a client that never closes: closed.
;;; Every close disarms the deadline first, so the wheel lets the connection
;;; go (M5.2).
;;;
;;; A row reads which kind is armed once the client has moved, then passes
;;; it: the fake clock, at 0 while the client moves, moves by that kind's
;;; limit (limits-deadline-ms), the connection is ticked there, and every
;;; later turn runs.  The core reads no clock: the tick is what tells it, as
;;; M5.3's wheel will once that much time has passed.  The row states the
;;; kind, the instant of the tick, the actions from the tick on, a write
;;; shown as its status, and the phase, the reason it closes after its
;;; response, and the writes outstanding it ends with.
;;; test-connection-originated.sps reads the 408s' bytes back.
;;;
;;; Oracles: design §4.3's table of states and their deadlines, and §4.4's
;;; tick rows; decision 0005's table, its defaults (idle 75 s; header, body
;;; and write 60 s) and on breach (close, or 408 and close), and its linger
;;; row (30 s); decision 0011 (the staged close); decision 0010 item 4 (the
;;; Date line's 37 bytes); the requests' own bytes.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (fake-shell) (only (read-back) send! shown))

(define (b s) (string->utf8 s))

(define get "GET / HTTP/1.1\r\nHost: x\r\n\r\n")

;; The handler answers every request 200.
(define (answers request) (make-response 200 #f '() (b "ok")))

;; The bytes of that answer's one write: its status line, the Date line (37
;; bytes: `Date: `, RFC 9110 §5.6.7's 29-character IMF-fixdate, CRLF),
;; its Content-Length and the blank line, and the body.
(define answer-bytes
  (+ (string-length "HTTP/1.1 200 OK\r\n") 37 (string-length "Content-Length: 2\r\n\r\n") 2))

;; unread! : FakeShell String -> Any
;; The client sends `text` in one delivery and never reads: the connection
;; answers, and its write's completion is left waiting, as libuv leaves one
;; whose bytes the client's socket will not take.
(define (unread! sh text)
  (let ((bv (b text)))
    (fake-shell-deliver! sh (list 'bytes-arrived bv 0 (bytevector-length bv)))))

;; passed : (FakeShell -> Any) -> Outcome
;; One connection under decision 0005's defaults: the client's moves, then
;; the deadline they left armed passes, then every later turn.  The outcome:
;; the kind armed, the instant it passed, the actions from the tick on, and
;; the phase, close-after and writes outstanding the connection ends with;
;; or `(raised)` if the run raised, as it does when no deadline is armed.
(define (passed moves)
  (guard (e (#t '(raised)))
    (let ((sh (make-fake-connection default-limits answers)))
      (moves sh)
      (let ((kind (conn-deadline (fake-shell-conn-state sh)))
            (n (length (fake-shell-actions sh))))
        (fake-shell-advance! sh (limits-deadline-ms default-limits kind))
        (fake-shell-tick! sh)
        (fake-shell-settle! sh)
        (let ((s (fake-shell-conn-state sh)))
          (list kind (fake-shell-now sh) (map shown (list-tail (fake-shell-actions sh) n))
                (conn-phase s) (conn-close-after s) (conn-outstanding s)))))))

;; A 408, then the staged close (decision 0011): the write, reading stopped,
;; the write deadline; once the write completes, the half-close, reading
;; again to drop what arrives, and the linger deadline.
(define answered-408
  '((write 408) (read-stop) (arm-deadline write) (shutdown) (read-start) (arm-deadline linger)))

;; A row: what it shows; the client's moves; the outcome.
(define (row text moves outcome) (list text moves outcome))
(define (row-text r) (car r))
(define (row-moves r) (cadr r))
(define (row-outcome r) (caddr r))

(define rows
  (list
   (row "idle: a keep-alive client that sends nothing more is closed, with no response"
        (lambda (sh) (send! sh get))
        '(idle 75000 ((disarm-deadline) (close idle-timeout)) closed #f 0))
   (row "header: a head never finished is answered 408, then closed in stages"
        (lambda (sh) (send! sh "GET / HTTP/1.1\r\nHo"))
        `(header 60000 ,answered-408 lingering header-timeout 0))
   (row "body: a body never finished is answered 408, then closed in stages"
        (lambda (sh) (send! sh "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nab"))
        `(body 60000 ,answered-408 lingering body-timeout 0))
   (row "write: a response the client never reads: logged with its bytes, closed, with no response, its write settled"
        (lambda (sh) (unread! sh get))
        `(write 60000 ((log write-timeout ,answer-bytes) (disarm-deadline) (close write-timeout))
                closed #f 0))
   (row "linger: a client that never closes is closed"
        (lambda (sh) (send! sh "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
        '(linger 30000 ((disarm-deadline) (close not-keep-alive)) closed not-keep-alive 0))))

(run-suite "connection-deadlines"
  (lambda ()
    (for-each (lambda (r) (test-equal (row-text r) (row-outcome r) (passed (row-moves r))))
              rows)
    (test-equal "a row for each kind of deadline the core arms, in order"
                conn-deadline-kinds
                (map (lambda (r) (car (row-outcome r))) rows))))
