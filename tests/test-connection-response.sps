#!r6rs
;;; (http-server connection): the core writes through the serializer.  M3.2.
;;;
;;; A handler's response goes on the wire framed for the request it answers,
;;; by (http-server decisions)' framing decision, with the Connection field
;;; the connection's fate calls for, and a Date slot the shell fills
;;; (decision 0010).  A response the serializer cannot write safely is
;;; answered 500 instead, then close, with a log naming the fault (0010 item
;;; 2), and a handler's `Connection: close` closes the connection after its
;;; response (item 3).
;;;
;;; Each row runs one fake connection over its requests, the handler giving
;;; the row's answer to each, and reads every write back with chez-httparse's
;;; strict response parser, a client that is not our code ((response-reader)):
;;; the status, the reason, each field in order, the body, and whether the
;;; message ended at the write's last byte, which test-serializer.sps
;;; calibrates.  Then the logs and writes the core asked for, in order, the
;;; state the connection ended in, and why it closed.
;;;
;;; Oracles: the framing rules (RFC 9112 §6, RFC 9110 §8.6, tabled in
;;; test-decisions.sps) and decision 0010; each request's own bytes; RFC 9110
;;; §15's reason phrases; and the Date: the fake clock starts at the epoch,
;;; `Thu, 01 Jan 1970 00:00:00 GMT`, and at RFC 9110 §5.6.7's example,
;;; 784,111,777 s, reads `Sun, 06 Nov 1994 08:49:37 GMT`.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (fake-shell) (response-reader) (read-back))

(define (b s) (string->utf8 s))

;; The 500 a refused response is answered with: an originated response, with
;; no body (decision 0010 item 6).
(define internal-error
  (message 500 "Internal Server Error" (list epoch (content-length "0") close) ""))

(define hello (b "hello"))
(define (answer status . headers)
  (make-response status #f (map (lambda (h) (cons (b (car h)) (b (cdr h)))) headers) hello))

(define get "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
(define head "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n")
(define http/1.0-keep-alive "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")

;; outcome : String Any Boolean -> Datum
;; One connection reading `input` whole, the handler answering `answer` to
;; every request: each write read back (its body skipped when `skip?`, as a
;; client skips a HEAD's or a tunnel's), the logs and writes the core asked
;; for, a write as its status, then the phase and close-after it ended with.
;; `(raised)` if the run raised.
(define (outcome input answer skip?)
  (guard (e (#t '(raised)))
    (let* ((bv (b input))
           (sh (make-fake-connection default-limits (lambda (request) answer))))
      (fake-shell-feed-input! sh bv (bytevector-length bv))
      (let ((s (fake-shell-conn-state sh)))
        (list (map (lambda (w) (read-response w skip? #f)) (fake-shell-writes sh))
              (map (lambda (a) (if (eq? (car a) 'write) (list 'write (written-status a)) a))
                   (filter (lambda (a) (memq (car a) '(log write))) (fake-shell-actions sh)))
              (conn-phase s) (conn-close-after s))))))

;; A row: what it shows; the requests; the handler's answer; whether the
;; client skips the body; and the outcome expected.
(define (row text input answer skip? reads actions phase reason)
  (list text input answer skip? (list reads actions phase reason)))

(define wrote-200 '((write 200)))
(define (refused fault) (list (list 'log 'invalid-response fault) '(write 500)))

(define (rows)
  (list
   ;; HTTP/1.1 keeps the connection by default and needs no Connection field
   ;; for it; a client that asks to close is told so (RFC 9112 §9.6).
   (row "HTTP/1.1: the body's Content-Length, and the connection stays"
        get (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5")) "hello")) wrote-200 'idle #f)
   (row "HTTP/1.1 with no body: Content-Length: 0"
        get (make-response 200 #f '() #f) #f
        (list (message 200 "OK" (list epoch (content-length "0")) "")) wrote-200 'idle #f)
   (row "HTTP/1.1 asking to close: Connection: close, then the close"
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5") close) "hello"))
        wrote-200 'closed 'not-keep-alive)
   (row "two requests in one delivery: two responses, in order, and it stays"
        (string-append get get) (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5")) "hello")
              (message 200 "OK" (list epoch (content-length "5")) "hello"))
        '((write 200) (write 200)) 'idle #f)
   ;; HTTP/1.0 closes unless it asked to keep alive, and then persists only
   ;; when told so (RFC 9112 Appendix C.2.2; decision 0010 item 6).
   (row "HTTP/1.0: Content-Length and Connection: close, then the close"
        "GET / HTTP/1.0\r\n\r\n" (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5") close) "hello"))
        wrote-200 'closed 'not-keep-alive)
   (row "HTTP/1.0 asking to keep alive: Connection: keep-alive, and it stays"
        http/1.0-keep-alive (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5") keep-alive) "hello"))
        wrote-200 'idle #f)
   ;; The bodies a client does not read are not written.
   (row "a HEAD answered with the GET's body: its Content-Length, and no body"
        head (answer 200) #t
        (list (message 200 "OK" (list epoch (content-length "5")) "")) wrote-200 'idle #f)
   (row "a HEAD answered with no body: no Content-Length"
        head (make-response 200 #f '() #f) #t
        (list (message 200 "OK" (list epoch) "")) wrote-200 'idle #f)
   (row "a 204 with a body: no Content-Length, and no body"
        get (answer 204) #f
        (list (message 204 "No Content" (list epoch) "")) '((write 204)) 'idle #f)
   (row "a 304 with a body: no Content-Length, and no body"
        get (answer 304) #f
        (list (message 304 "Not Modified" (list epoch) "")) '((write 304)) 'idle #f)
   ;; An upgrade is served, then the connection closes (decision 0006's
   ;; amendment): v1 has no tunnel and nothing to hand a WebSocket to.
   (row "a 2xx to CONNECT: neither field and no body, and Connection: close"
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n" (answer 200) #t
        (list (message 200 "OK" (list epoch close) "")) wrote-200 'closed 'upgrade)
   (row "a WebSocket handshake answered 200: Connection: close, then the close"
        "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"
        (answer 200) #f
        (list (message 200 "OK" (list epoch (content-length "5") close) "hello"))
        wrote-200 'closed 'upgrade)
   ;; A handler's Connection: close is honoured, and the field written once
   ;; (decision 0010 item 3).
   (row "the handler's Connection: close: written once, and the request after it never answered"
        (string-append get get) (answer 200 '("Connection" . "close")) #f
        (list (message 200 "OK" (list epoch (content-length "5") close) "hello"))
        wrote-200 'closed 'handler-close)
   (row "the handler's Connection: close to HTTP/1.0 asking to keep alive: close"
        http/1.0-keep-alive (answer 200 '("Connection" . "close")) #f
        (list (message 200 "OK" (list epoch (content-length "5") close) "hello"))
        wrote-200 'closed 'handler-close)
   (row "the handler's own Date is written in its place, and no slot is left"
        get (answer 200 '("Date" . "Sun, 06 Nov 1994 08:49:37 GMT")) #f
        (list (message 200 "OK" (list '("Date" . "Sun, 06 Nov 1994 08:49:37 GMT") (content-length "5"))
                    "hello"))
        wrote-200 'idle #f)
   ;; What cannot be written safely is answered 500, then close, and the log
   ;; names why (decision 0010 item 2).
   (row "a handler's own Content-Length is refused: 500, then the close"
        get (answer 200 '("Content-Length" . "5")) #f
        (list internal-error) (refused 'framing-field) 'closed 'invalid-response)
   (row "a CR LF in a value, which would split the response in two, is refused"
        get (answer 200 '("X-A" . "1\r\nSet-Cookie: a=1")) #f
        (list internal-error) (refused 'invalid-header-value) 'closed 'invalid-response)
   (row "a 101, interim and never an answer, is refused"
        get (make-response 101 #f '() #f) #f
        (list internal-error) (refused 'invalid-status) 'closed 'invalid-response)
   (row "an answer that is not a response is refused"
        get "hello" #f
        (list internal-error) (refused 'not-a-response) 'closed 'invalid-response)
   (row "a refused answer closes the connection: the request after it is never answered"
        (string-append get get) (answer 200 '("Content-Length" . "5")) #f
        (list internal-error) (refused 'framing-field) 'closed 'invalid-response)
   ;; A HEAD's Content-Length must be the GET's (RFC 9110 §8.6), which the
   ;; core's own 500 cannot know: the HEAD rule of decision 0010 item 6.
   (row "a HEAD's refused answer: 500 with no Content-Length"
        head (answer 200 '("Content-Length" . "5")) #t
        (list (message 500 "Internal Server Error" (list epoch close) ""))
        (refused 'framing-field) 'closed 'invalid-response)
   ;; A refusal made before the request is built answers no request the core
   ;; has read, so a HEAD's gets `Content-Length: 0`: a GET with the same
   ;; target gets the same 301, so the length is the GET's (RFC 9110 §8.6).
   (row "a HEAD redirected before its request is built: 301 with Content-Length: 0"
        "HEAD /s?ids[]=1 HTTP/1.1\r\nHost: x\r\n\r\n" (answer 200) #t
        (list (message 301 "Moved Permanently"
                       (list epoch '("Location" . "/s?ids%5B%5D=1") (content-length "0") close) ""))
        '((write 301)) 'closed 'target-redirect)))

(run-suite "connection-response"
  (lambda ()
    (for-each (lambda (r)
                (test-equal (car r) (list-ref r 4)
                            (outcome (list-ref r 1) (list-ref r 2) (list-ref r 3))))
              (rows))

    ;; The Date is the shell's clock's, read when the write is performed.
    (test-equal "the Date slot is filled from the clock: RFC 9110 §5.6.7's example instant"
                '((200 "OK" (("Date" . "Sun, 06 Nov 1994 08:49:37 GMT") ("Content-Length" . "5"))
                   "hello" complete))
                (guard (e (#t '(raised)))
                  (let ((sh (make-fake-connection default-limits (lambda (request) (answer 200))))
                        (bv (b get)))
                    (fake-shell-advance! sh 784111777000)
                    (fake-shell-feed-input! sh bv (bytevector-length bv))
                    (map (lambda (w) (read-response w #f #f)) (fake-shell-writes sh)))))))
