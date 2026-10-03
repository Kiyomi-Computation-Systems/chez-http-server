#!r6rs
;; M8.2, 2026-10-03: what a handler that tries to take a WebSocket handshake
;; gets on main today, through the fake shell: a 101 it answers, with and
;; without `Connection: upgrade`, and a plain 200.  Each row: the status
;; written, the log, the close-after, and the state the connection ends in.
(import (rnrs) (http-server connection) (http-server limits) (http-server response)
        (fake-shell))

(define (b s) (string->utf8 s))
(define handshake
  (b "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"))

(define (row name response)
  (let ((sh (make-fake-connection default-limits (lambda (request) response))))
    (fake-shell-feed-input! sh handshake (bytevector-length handshake))
    (let ((actions (fake-shell-actions sh)))
      (write (list name
                   'written (map written-status (filter (lambda (a) (eq? (car a) 'write)) actions))
                   'logs (filter (lambda (a) (eq? (car a) 'log)) actions)
                   'close-after (conn-close-after (fake-shell-conn-state sh))
                   'state (conn-phase (fake-shell-conn-state sh))))
      (newline))))

(define accept-headers
  (list (cons (b "Upgrade") (b "websocket"))
        (cons (b "Sec-WebSocket-Accept") (b "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))))
(row 'a-101 (make-response 101 #f accept-headers #f))
(row 'a-101-with-connection-upgrade
     (make-response 101 #f (cons (cons (b "Connection") (b "upgrade")) accept-headers) #f))
(row 'a-plain-200 (make-response 200 #f '() (b "no upgrade here")))
