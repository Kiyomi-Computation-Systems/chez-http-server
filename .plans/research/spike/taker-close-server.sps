#!r6rs
;;; The lost close (chez-websocket's decision 0008, item 6), the server's side.
;;; `serve` answers every upgrade with a switch whose taker reads and counts.
;;; Once it has read 1 MiB (the argument `cap`, the default), or at its first
;;; read (`control`), it writes a WebSocket close frame, 1009 (RFC 6455
;;; §5.5.1, §7.4.1), and calls transport-close!, as chez-websocket's binding
;;; fails a connection.  It listens on 127.0.0.1, the kernel's choice of port,
;;; which `serve` logs on standard output.  Run on the project's library path;
;;; taker-close-run.sh runs it against taker-close-client.c.
(import (rnrs) (http-server))

(define mode (let ((args (cdr (command-line)))) (if (pair? args) (car args) "cap")))
(define cap (if (string=? mode "control") 1 (* 1024 1024)))
(define close-frame (u8-list->bytevector '(#x88 #x02 #x03 #xf1)))

(serve (lambda (request)
         (switch-protocols
          (list (cons (string->utf8 "Upgrade") (string->utf8 "websocket")))
          (lambda (t retained)
            (let ((n 0) (failed #f))
              (define (seen! k)
                (set! n (+ n k))
                (when (and (not failed) (>= n cap))
                  (set! failed #t)
                  (transport-write! t close-frame)
                  (transport-close! t)))
              (transport-read-start! t
                                     (lambda (bv start end) (seen! (- end start)))
                                     (lambda (why) (transport-close! t)))
              (when (> (bytevector-length retained) 0) (seen! (bytevector-length retained)))))))
       (lambda (name)
         (cond ((string=? name "CHEZ_HTTP_HOST") "127.0.0.1")
               ((string=? name "CHEZ_HTTP_PORT") "0")
               (else #f))))
(exit 0)
