#!r6rs
;;; (http-server serializer): a response, as the bytes the server writes.  M3.1.
;;;
;;; Four tables:
;;;   - the wire: a response, a framing mode and a Connection, to the bytes of
;;;     one write, written out here by hand from RFC 9112's grammar.  Each row
;;;     also asserts how many segments the write is (the plan's check: status
;;;     line, Date slot, header block and body stay separate, never
;;;     concatenated; design §7.3), the byte count the serializer reports, and
;;;     what chez-httparse's strict response parser reads back (response-reader),
;;;     a client that is not our code;
;;;   - the status lines: RFC 9110 §15's and RFC 6585's reason phrases, each
;;;     line made once and shared by every response (the M3 exit);
;;;   - the Date line: RFC 9110 §5.6.7's example, and Chez's own UTC calendar
;;;     over four centuries of instants;
;;;   - the faults: what a handler's response may not carry (decision 0010
;;;     item 2), each with its reason.
;;; And, since M3.2: the reader's own calibration, what it sees after a
;;; message and past an interim one; and the entry for a response already
;;; checked for faults, which writes every wire row as serialize-response does.
;;; And, since M6.3: a body of unknown length, a producer (decision 0013 item
;;; 8), whose head writes no body, and whose pieces and end are each the
;;; segments of one write of their own, chunked (RFC 9112 §7.1) or
;;; close-delimited (§6.3 rule 8), read back whole by the same parser.
;;; And, since M8.2: the 101 a switch is written as (decision 0016 item 1),
;;; its status line and its fields with `Connection: upgrade` (RFC 9110
;;; §7.8), no Date and no framing (§6.6.1, §15.2), read back by the same
;;; parser; and what a switch may not carry, each with its reason.
;;; Every slot is filled with RFC 9110 §5.6.7's example line, written out here,
;;; so the wire does not depend on the Date line under test.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) make-time time-utc->date
              date-week-day date-day date-month date-year date-hour date-minute date-second)
        (http-server serializer) (http-server response) (http-server span)
        (http-server switch)
        (response-reader))

(define (b s) (string->utf8 s))

;; bytes->text : Bytevector -> String — one character per byte (Latin-1).
(define (bytes->text bv) (list->string (map integer->char (bytevector->u8-list bv))))

;; The line every Date slot is filled with.
(define date-text "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n")

;; wire : (Listof Segment) -> String — the write as it reaches the socket: a
;; segment is a bytevector, the Date slot, or a span of a bytevector, `(bv
;; start end)`, as uv-write*! takes one (M6.3).
(define (wire segments)
  (apply string-append
         (map (lambda (seg)
                (cond ((eq? seg 'date) date-text)
                      ((pair? seg)
                       (let* ((n (- (caddr seg) (cadr seg))) (o (make-bytevector n)))
                         (bytevector-copy! (car seg) (cadr seg) o 0 n)
                         (bytes->text o)))
                      (else (bytes->text seg))))
              segments)))

;; text->bytes : String -> Bytevector — one byte per character (Latin-1).
(define (text->bytes t) (u8-list->bytevector (map char->integer (string->list t))))

;; A body of unknown length: a producer, which the serializer never calls.
(define (producer) (eof-object))

;; The slot's place in a row's expected wire.
(define D date-text)

(define (response status headers body) (make-response status #f headers body))
(define (h name value) (cons (b name) (b value)))

;; The server's Date, as the parser reads it back.
(define read-date '("Date" . "Sun, 06 Nov 1994 08:49:37 GMT"))

;; A row: name, response, mode, connection, the wire expected, the segments
;; expected, whether it answers a HEAD, whether the connection ends after it,
;; and what the parser reads back: (status reason headers body end).
(define-record-type row
  (fields name response mode connection wire segments head? eof? read))

(define request-bytes (b "X-Id: abc"))   ; a span's delivery, as a request's

(define rows
  (list
   (make-row "a body goes out after its Content-Length"
             (response 200 '() (b "hi")) 'content-length #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Content-Length: 2\r\n\r\n" "hi")
             4 #f #f
             `(200 "OK" (,read-date ("Content-Length" . "2")) "hi" complete))
   (make-row "no body is Content-Length: 0, and no body segment"
             (response 200 '() #f) 'content-length #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Content-Length: 0\r\n\r\n")
             3 #f #f
             `(200 "OK" (,read-date ("Content-Length" . "0")) "" complete))
   ;; RFC 9110 §9.3.2: a HEAD's answer carries the GET's fields, and no content.
   (make-row "a HEAD's answer announces the length and writes no body"
             (response 200 '() (b "hello")) 'content-length-only #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Content-Length: 5\r\n\r\n")
             3 #t #f
             `(200 "OK" (,read-date ("Content-Length" . "5")) "" complete))
   ;; RFC 9110 §8.6: no Content-Length in a 204.
   (make-row "a 204 has neither a length nor a body"
             (response 204 '() #f) 'no-body #f
             (string-append "HTTP/1.1 204 No Content\r\n" D "\r\n")
             3 #f #f
             `(204 "No Content" (,read-date) "" complete))
   ;; RFC 9110 §15.4.5: a 304 "cannot contain content".
   (make-row "a body where none may go is not written"
             (response 304 (list (h "ETag" "\"v1\"")) (b "stale")) 'no-body #f
             (string-append "HTTP/1.1 304 Not Modified\r\n" D "ETag: \"v1\"\r\n\r\n")
             3 #f #f
             `(304 "Not Modified" (,read-date ("ETag" . "\"v1\"")) "" complete))
   ;; RFC 9112 §7.1: chunk = chunk-size CRLF chunk-data CRLF, the size in hex.
   (make-row "chunked: Transfer-Encoding, and the body as the first chunk"
             (response 200 '() (b "abcdefghijklmnopqrstuvwxyz")) 'chunked #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Transfer-Encoding: chunked\r\n\r\n"
                            "1a\r\n" "abcdefghijklmnopqrstuvwxyz" "\r\n")
             6 #f #f
             `(200 "OK" (,read-date ("Transfer-Encoding" . "chunked"))
                   "abcdefghijklmnopqrstuvwxyz" need-input))
   (make-row "chunked with no body yet is the head alone"
             (response 200 '() #f) 'chunked #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Transfer-Encoding: chunked\r\n\r\n")
             3 #f #f
             `(200 "OK" (,read-date ("Transfer-Encoding" . "chunked")) "" need-input))
   ;; Decision 0013 item 8: a producer's pieces follow its head, each a write
   ;; of its own (serialize-piece, below), so the head writes no body.
   (make-row "a producer's head is chunked, and writes no body"
             (response 200 '() producer) 'chunked #f
             (string-append "HTTP/1.1 200 OK\r\n" D "Transfer-Encoding: chunked\r\n\r\n")
             3 #f #f
             `(200 "OK" (,read-date ("Transfer-Encoding" . "chunked")) "" need-input))
   (make-row "a producer's head to HTTP/1.0 is close-delimited, and closes"
             (response 200 '() producer) 'close-delimited 'close
             (string-append "HTTP/1.1 200 OK\r\n" D "Connection: close\r\n\r\n")
             3 #f #t
             `(200 "OK" (,read-date ("Connection" . "close")) "" complete))
   ;; RFC 9110 §8.6: a HEAD's Content-Length must be the GET's, and a
   ;; producer's length is not known.
   (make-row "a HEAD's answer with a producer announces no length"
             (response 200 '() producer) 'no-body #f
             (string-append "HTTP/1.1 200 OK\r\n" D "\r\n")
             3 #t #f
             `(200 "OK" (,read-date) "" complete))
   ;; RFC 9112 §6.3 rule 8: a response with neither is delimited by the close.
   (make-row "close-delimited: no length, then the body, ended by the close"
             (response 200 '() (b "hello")) 'close-delimited 'close
             (string-append "HTTP/1.1 200 OK\r\n" D "Connection: close\r\n\r\n" "hello")
             4 #f #t
             `(200 "OK" (,read-date ("Connection" . "close")) "hello" complete))
   (make-row "the handler's fields in its order, then the framing, then Connection"
             (response 200 (list (h "Content-Type" "text/plain") (h "X-Request-Id" "7")) (b "ok"))
             'content-length 'close
             (string-append "HTTP/1.1 200 OK\r\n" D
                            "Content-Type: text/plain\r\nX-Request-Id: 7\r\n"
                            "Content-Length: 2\r\nConnection: close\r\n\r\n" "ok")
             4 #f #f
             `(200 "OK" (,read-date ("Content-Type" . "text/plain") ("X-Request-Id" . "7")
                         ("Content-Length" . "2") ("Connection" . "close"))
                   "ok" complete))
   ;; Decision 0006 item 1; decision 0010 item 3.
   (make-row "an HTTP/1.0 client kept alive is told so"
             (response 200 '() (b "ok")) 'content-length 'keep-alive
             (string-append "HTTP/1.1 200 OK\r\n" D "Content-Length: 2\r\nConnection: keep-alive\r\n\r\n" "ok")
             4 #f #f
             `(200 "OK" (,read-date ("Content-Length" . "2") ("Connection" . "keep-alive")) "ok" complete))
   ;; Decision 0010 item 4.
   (make-row "a handler's own Date is written, and no slot is left"
             (response 200 (list (h "Date" "Mon, 07 Nov 1994 08:49:37 GMT")) #f) 'content-length #f
             (string-append "HTTP/1.1 200 OK\r\n" "Date: Mon, 07 Nov 1994 08:49:37 GMT\r\n"
                            "Content-Length: 0\r\n\r\n")
             2 #f #f
             `(200 "OK" (("Date" . "Mon, 07 Nov 1994 08:49:37 GMT") ("Content-Length" . "0")) "" complete))
   ;; Decision 0010 item 3: one Connection field, the server's.
   (make-row "a handler's Connection: close is written once"
             (response 200 (list (h "Connection" "close")) (b "ok")) 'content-length 'close
             (string-append "HTTP/1.1 200 OK\r\n" D "Content-Length: 2\r\nConnection: close\r\n\r\n" "ok")
             4 #f #f
             `(200 "OK" (,read-date ("Content-Length" . "2") ("Connection" . "close")) "ok" complete))
   (make-row "a handler's reason phrase is written as given"
             (make-response 200 (b "Fine") '() #f) 'content-length #f
             (string-append "HTTP/1.1 200 Fine\r\n" D "Content-Length: 0\r\n\r\n")
             3 #f #f
             `(200 "Fine" (,read-date ("Content-Length" . "0")) "" complete))
   ;; RFC 9112 §4: status-line = HTTP-version SP status-code SP [ reason-phrase ].
   (make-row "a status with no registered phrase keeps the space before it"
             (response 299 '() #f) 'content-length #f
             (string-append "HTTP/1.1 299 \r\n" D "Content-Length: 0\r\n\r\n")
             3 #f #f
             `(299 "" (,read-date ("Content-Length" . "0")) "" complete))
   (make-row "a name and a value may be spans of a request's bytes"
             (response 200 (list (cons (make-span request-bytes 0 4) (make-span request-bytes 6 9))) #f)
             'content-length #f
             (string-append "HTTP/1.1 200 OK\r\n" D "X-Id: abc\r\nContent-Length: 0\r\n\r\n")
             3 #f #f
             `(200 "OK" (,read-date ("X-Id" . "abc") ("Content-Length" . "0")) "" complete))
   ;; RFC 9110 §5.5: field-vchar = VCHAR / obs-text, with SP and HTAB between.
   (make-row "an HTAB and obs-text in a value are written"
             (response 200 (list (cons (b "X-Tab") (u8-list->bytevector '(97 9 98 233)))) #f)
             'content-length #f
             (string-append "HTTP/1.1 200 OK\r\n" D "X-Tab: a\tb\xE9;\r\nContent-Length: 0\r\n\r\n")
             3 #f #f
             `(200 "OK" (,read-date ("X-Tab" . "a\tb\xE9;") ("Content-Length" . "0")) "" complete))
   ;; Decision 0009: the core's own redirect.
   (make-row "a redirect carries its Location, and closes"
             (response 301 (list (h "Location" "/a?x=%5B%5D")) #f) 'content-length 'close
             (string-append "HTTP/1.1 301 Moved Permanently\r\n" D
                            "Location: /a?x=%5B%5D\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
             3 #f #f
             `(301 "Moved Permanently" (,read-date ("Location" . "/a?x=%5B%5D")
                                        ("Content-Length" . "0") ("Connection" . "close"))
                   "" complete))))

;; The statuses the server writes or a handler commonly sends, with their
;; phrases: RFC 9110 §15's section titles, and RFC 6585 §5 for 431.
(define phrases
  '((200 "OK") (204 "No Content") (301 "Moved Permanently") (304 "Not Modified")
    (400 "Bad Request") (404 "Not Found") (408 "Request Timeout")
    (413 "Content Too Large") (414 "URI Too Long")
    (431 "Request Header Fields Too Large") (500 "Internal Server Error")
    (501 "Not Implemented") (505 "HTTP Version Not Supported")))

;; --- the Date line, against Chez's own calendar -------------------------------

(define day-names '#("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))
(define month-names '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (pad n width)
  (let ((s (number->string n)))
    (string-append (make-string (max 0 (- width (string-length s))) #\0) s)))

;; chez-date-text : Nat -> String — the IMF-fixdate line for `seconds`, from
;; Chez's UTC calendar (time-utc->date, zone offset 0).
(define (chez-date-text seconds)
  (let ((d (time-utc->date (make-time 'time-utc 0 seconds) 0)))
    (string-append "Date: " (vector-ref day-names (date-week-day d)) ", "
                   (pad (date-day d) 2) " " (vector-ref month-names (- (date-month d) 1)) " "
                   (pad (date-year d) 4) " " (pad (date-hour d) 2) ":" (pad (date-minute d) 2)
                   ":" (pad (date-second d) 2) " GMT\r\n")))

;; The instants: every 3,000,017 s from the epoch into the 24th century, and
;; the edges a calendar gets wrong: the leap days of 2000 and 2400, and 2100,
;; which is not leap.
(define instants
  (append
   (let loop ((t 0) (acc '()))
     (if (> t 13000000000) (reverse acc) (loop (+ t 3000017) (cons t acc))))
   '(951782399 951782400 951868799 951868800           ; 2000-02-28/29, 03-01
     4107456000 4107542399 4107542400                  ; 2100-02-28, 03-01
     13574563199 13574563200 13574649600               ; 2400-02-28/29, 03-01
     946684799 946684800 253402300799)))               ; 1999/2000, 9999-12-31

;; --- the faults ----------------------------------------------------------------

(define (with-header name value) (response 200 (list (cons name value)) #f))

;; (name value fault): decision 0010 item 2, one row per reason.
(define faults
  (list
   (list "a string is not a response" "HTTP/1.1 200 OK" 'not-a-response)
   ;; RFC 9110 §15: 1xx is interim; outside 100..599 is invalid.
   (list "a 100 is interim, not an answer" (response 100 '() #f) 'invalid-status)
   (list "a 199 is interim, not an answer" (response 199 '() #f) 'invalid-status)
   (list "a 600 is no status" (response 600 '() #f) 'invalid-status)
   (list "an inexact 200 is no status" (response 200.0 '() #f) 'invalid-status)
   (list "a reason with a CR" (make-response 200 (b "O\rK") '() #f) 'invalid-reason)
   (list "a reason that is a string" (make-response 200 "OK" '() #f) 'invalid-reason)
   (list "headers that are not a list" (response 200 (b "X: 1") #f) 'invalid-headers)
   (list "a value that is a string" (with-header (b "X") "1") 'invalid-headers)
   (list "a field that is not a pair" (response 200 (list (b "X")) #f) 'invalid-headers)
   ;; RFC 9110 §5.1: field-name = token.
   (list "an empty name" (with-header (b "") (b "1")) 'invalid-header-name)
   (list "a name with a space" (with-header (b "X Y") (b "1")) 'invalid-header-name)
   (list "a name with a colon" (with-header (b "X:") (b "1")) 'invalid-header-name)
   ;; RFC 9110 §5.5: CR, LF and NUL "invalid and dangerous", other CTLs invalid.
   (list "a value with a CR" (with-header (b "X") (b "a\rb")) 'invalid-header-value)
   (list "a value with an LF" (with-header (b "X") (b "a\nb")) 'invalid-header-value)
   (list "a value with a NUL" (with-header (b "X") (u8-list->bytevector '(97 0 98))) 'invalid-header-value)
   (list "a value with a 0x01" (with-header (b "X") (u8-list->bytevector '(97 1 98))) 'invalid-header-value)
   (list "a value with a DEL" (with-header (b "X") (u8-list->bytevector '(97 127 98))) 'invalid-header-value)
   ;; Decision 0010 item 1: the framing is the server's.
   (list "a handler's Content-Length" (with-header (b "Content-Length") (b "2")) 'framing-field)
   (list "a handler's content-length" (with-header (b "content-length") (b "2")) 'framing-field)
   (list "a handler's Transfer-Encoding" (with-header (b "Transfer-Encoding") (b "chunked")) 'framing-field)
   ;; Decision 0010 item 3: a handler's Connection may only be close.
   (list "a handler's Connection: keep-alive" (with-header (b "Connection") (b "keep-alive")) 'connection-field)
   (list "a handler's Connection: close, upgrade" (with-header (b "Connection") (b "close, upgrade")) 'connection-field)
   (list "a body that is a string" (response 200 '() "hi") 'invalid-body)
   ;; Decision 0013 item 8: a body of unknown length is a producer.
   (list "a body that is a procedure is a producer" (response 200 '() producer) #f)
   ;; And what is not a fault.
   (list "a handler's Connection: Close" (with-header (b "Connection") (b "Close")) #f)
   (list "a handler's Connection: close, with spaces" (with-header (b "connection") (b " close ")) #f)
   (list "an empty reason" (make-response 200 (b "") '() #f) #f)
   (list "a 599" (response 599 '() #f) #f)
   (list "an HTAB and obs-text in a value" (with-header (b "X-Tab") (u8-list->bytevector '(97 9 98 233))) #f)
   (list "a name and a value that are spans"
         (let ((bv (b "X-Id: abc"))) (with-header (make-span bv 0 4) (make-span bv 6 9)))
         #f)))

(define (assertion-raised? thunk)
  (guard (e ((assertion-violation? e) 'refused)) (thunk) 'accepted))

;; --- a producer's pieces, and its end (M6.3) -----------------------------------

(define alphabet (b "abcdefghijklmnopqrstuvwxyz"))
(define delivery (b "xxhelloyy"))
(define four-k (make-bytevector 4096 97))

;; (name mode bv start end wire segments): RFC 9112 §7.1's chunk, chunk-size
;; CRLF chunk-data CRLF with the size in hex, and §6.3 rule 8's close-
;; delimited body, the bytes alone.
(define pieces
  (list
   (list "a chunk: its size in hex, the piece, CRLF" 'chunked (b "hello") 0 5 "5\r\nhello\r\n" 3)
   (list "a chunk's size is written in lowercase hex" 'chunked alphabet 0 26
         "1a\r\nabcdefghijklmnopqrstuvwxyz\r\n" 3)
   (list "a chunk of 4 KiB is 1000 in hex" 'chunked four-k 0 4096
         (string-append "1000\r\n" (make-string 4096 #\a) "\r\n") 3)
   (list "a chunk of a span of its bytevector" 'chunked delivery 2 7 "5\r\nhello\r\n" 3)
   (list "close-delimited: the piece alone" 'close-delimited (b "hello") 0 5 "hello" 1)
   (list "close-delimited, a span" 'close-delimited delivery 2 7 "hello" 1)))

;; piece-write : Symbol Bytevector Nat Nat -> (U (List (Listof Segment) Nat) 'refused)
(define (piece-write mode bv start end)
  (guard (e ((assertion-violation? e) 'refused))
    (call-with-values (lambda () (serialize-piece mode bv start end)) list)))

;; end-write : Symbol -> (U (List (Listof Segment) Nat) 'refused)
(define (end-write mode)
  (guard (e ((assertion-violation? e) 'refused))
    (call-with-values (lambda () (serialize-end mode)) list)))

;; streamed : Symbol Connection (Listof String) -> String
;; A producer's whole response on the wire: its head, each piece's write,
;; then the end's.
(define (streamed mode connection texts)
  (apply string-append
         (call-with-values (lambda () (serialize-response (response 200 '() producer) mode connection))
                           (lambda (segments bytes) (wire segments)))
         (append (map (lambda (t)
                        (let ((bv (b t)))
                          (call-with-values (lambda () (serialize-piece mode bv 0 (bytevector-length bv)))
                                            (lambda (segments bytes) (wire segments)))))
                      texts)
                 (list (call-with-values (lambda () (serialize-end mode))
                                         (lambda (segments bytes) (wire segments)))))))

;; --- the 101 a switch is written as (M8.2; decision 0016) ---------------------

(define (take-over transport retained) 'taken)
(define (switch headers) (switch-protocols headers take-over))
(define accept (h "Sec-WebSocket-Accept" "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

;; A WebSocket handshake's request fields, as RFC 6455 §1.2's example has
;; them, less the ones no check here reads.
(define offered (list (h "Host" "server.example.com") (h "Upgrade" "websocket") (h "Connection" "Upgrade")))

;; (name switch offered fault): RFC 9110 §7.8 and §15.2's rules for a 101,
;; and decision 0010 item 2's for the fields, one row per reason, then what
;; is not a fault.
(define switch-faults
  (list
   (list "a response is no switch" (response 101 (list (h "Upgrade" "websocket")) #f) offered 'not-a-switch)
   (list "a take-over that is no procedure"
         (switch-protocols (list (h "Upgrade" "websocket")) 'take-over) offered 'invalid-take-over)
   (list "headers that are not a list" (switch (h "Upgrade" "websocket")) offered 'invalid-headers)
   (list "a name with a space" (switch (list (h "Upgrade" "websocket") (h "X Y" "1"))) offered
         'invalid-header-name)
   (list "a value with a CR" (switch (list (h "Upgrade" "web\rsocket"))) offered 'invalid-header-value)
   ;; §8.6: a 1xx carries neither; and the framing is the server's anyway.
   (list "a Content-Length" (switch (list (h "Upgrade" "websocket") (h "Content-Length" "0"))) offered
         'framing-field)
   (list "a Transfer-Encoding" (switch (list (h "Upgrade" "websocket") (h "Transfer-Encoding" "chunked")))
         offered 'framing-field)
   ;; The server writes `Connection: upgrade`; a handler's may only say so.
   (list "a Connection: close" (switch (list (h "Upgrade" "websocket") (h "Connection" "close"))) offered
         'connection-field)
   (list "a Connection: upgrade, close"
         (switch (list (h "Upgrade" "websocket") (h "Connection" "upgrade, close"))) offered
         'connection-field)
   ;; §7.8: a 101 MUST send Upgrade, naming only what the request offered.
   (list "no Upgrade" (switch (list accept)) offered 'invalid-upgrade)
   (list "an Upgrade naming nothing" (switch (list (h "Upgrade" " , "))) offered 'invalid-upgrade)
   (list "an Upgrade the request did not offer" (switch (list (h "Upgrade" "h2c"))) offered 'invalid-upgrade)
   (list "an offered protocol and one not" (switch (list (h "Upgrade" "websocket, h2c"))) offered
         'invalid-upgrade)
   (list "a request that offered none" (switch (list (h "Upgrade" "websocket")))
         (list (h "Host" "server.example.com")) 'invalid-upgrade)
   ;; And what is not a fault.
   (list "the protocol the request offered" (switch (list (h "Upgrade" "websocket") accept)) offered #f)
   (list "in another case, compared without regard to it (§7.8's SHOULD)"
         (switch (list (h "Upgrade" "WebSocket"))) offered #f)
   (list "one of the request's list, and of its second line"
         (switch (list (h "Upgrade" "IRC/6.9")))
         (list (h "Upgrade" "websocket") (h "upgrade" "IRC/6.9, RTA/x11")) #f)
   (list "a handler's own Connection: Upgrade"
         (switch (list (h "Upgrade" "websocket") (h "Connection" " Upgrade "))) offered #f)
   (list "a request's fields that are spans"
         (switch (list (h "Upgrade" "websocket")))
         (let ((bv (b "Upgrade: websocket"))) (list (cons (make-span bv 0 7) (make-span bv 9 18))))
         #f)))

;; switched : Switch -> (U (List String Nat Nat) 'refused)
;; The switch's 101 as the wire, its segments and its byte count.
(define (switched sw)
  (guard (e ((assertion-violation? e) 'refused))
    (let-values (((segments bytes) (serialize-switch sw)))
      (list (wire segments) (length segments) bytes))))

(run-suite "serializer"
  (lambda ()
    (for-each
     (lambda (r)
       ;; A refusal fails the row's checks rather than ending the suite.
       (let-values (((segments bytes)
                     (guard (e ((assertion-violation? e) (values '(refused) -1)))
                       (serialize-response (row-response r) (row-mode r) (row-connection r)))))
         (test-equal (string-append (row-name r) ": the wire") (row-wire r) (wire segments))
         (test-eqv (string-append (row-name r) ": its segments") (row-segments r) (length segments))
         (test-eqv (string-append (row-name r) ": its byte count")
                   (string-length (row-wire r)) bytes)
         (test-equal (string-append (row-name r) ": what a client reads")
                     (row-read r)
                     (read-response (u8-list->bytevector (map char->integer (string->list (wire segments))))
                                    (row-head? r) (row-eof? r)))
         (test-eq (string-append (row-name r) ": no fault") #f (response-fault (row-response r)))))
     rows)

    (for-each
     (lambda (p)
       (let-values (((segments bytes)
                     (guard (e ((assertion-violation? e) (values '(refused) -1)))
                       (serialize-response (response (car p) '() #f) 'no-body #f))))
         (test-equal (string-append "the status line of " (number->string (car p)))
                     (string-append "HTTP/1.1 " (number->string (car p)) " " (cadr p) "\r\n")
                     (bytes->text (car segments)))))
     phrases)

    ;; A registered status's line is made once, so a response allocates
    ;; nothing for it (the M3 exit; decision 0002's shapes): two responses
    ;; with the same status write the same bytevector.  A refusal answers a
    ;; fresh list each time, so it can never pass.
    (let ((line (lambda (status)
                  (guard (e ((assertion-violation? e) (list 'refused)))
                    (let-values (((segments bytes) (serialize-response (response status '() #f) 'no-body #f)))
                      (car segments))))))
      (test-equal "every status line in the table is made once, and shared" '()
                  (map car (filter (lambda (p) (not (eq? (line (car p)) (line (car p))))) phrases))))

    (test-equal "RFC 9110 §5.6.7's example" date-text (bytes->text (date-line 784111777)))
    (test-equal "the epoch" "Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n" (bytes->text (date-line 0)))
    (test-equal "every instant's line is Chez's calendar's" '()
                (filter (lambda (t) (not (string=? (chez-date-text t) (bytes->text (date-line t)))))
                        instants))
    (test-equal "every line is date-line-length bytes" '()
                (filter (lambda (t) (not (= date-line-length (bytevector-length (date-line t)))))
                        instants))
    (test-eqv "a line is 37 bytes: Date, an IMF-fixdate, CRLF" 37 date-line-length)
    (test-eq "before the epoch is refused" 'refused (assertion-raised? (lambda () (date-line -1))))
    (test-eq "past 9999 is refused" 'refused (assertion-raised? (lambda () (date-line 253402300800))))

    (for-each
     (lambda (f) (test-eq (car f) (caddr f) (response-fault (cadr f))))
     faults)
    (test-eq "a handler's Connection: close closes" #t
             (response-closes? (with-header (b "Connection") (b "CLOSE"))))
    (test-eq "no Connection field does not" #f (response-closes? (response 200 '() #f)))
    (test-eq "a response with a fault is not serialized" 'refused
             (assertion-raised?
              (lambda () (serialize-response (with-header (b "X") (b "a\nb")) 'content-length #f))))
    (test-eq "a mode outside the five is refused" 'refused
             (assertion-raised? (lambda () (serialize-response (response 200 '() #f) 'identity #f))))
    (test-eq "a close-delimited body on a kept connection is refused" 'refused
             (assertion-raised?
              (lambda () (serialize-response (response 200 '() (b "x")) 'close-delimited #f))))
    (test-eq "a handler's close on a kept connection is refused" 'refused
             (assertion-raised?
              (lambda () (serialize-response (with-header (b "Connection") (b "close"))
                                             'content-length 'keep-alive))))

    ;; --- a producer's pieces and its end (M6.3) ---
    (for-each
     (lambda (p)
       (let* ((name (list-ref p 0)) (w (piece-write (list-ref p 1) (list-ref p 2) (list-ref p 3) (list-ref p 4))))
         (test-equal (string-append name ": the wire") (list-ref p 5)
                     (if (pair? w) (wire (car w)) w))
         (test-eqv (string-append name ": its segments") (list-ref p 6)
                   (if (pair? w) (length (car w)) -1))
         (test-eqv (string-append name ": its byte count") (string-length (list-ref p 5))
                   (if (pair? w) (cadr w) -1))))
     pieces)
    ;; chez-libuv copies every segment as the write is issued (design §7.3),
    ;; so the serializer copies none: a whole bytevector is its own segment,
    ;; and a span of one is uv-write*!'s `(bv start end)` over it.
    (test-equal "a piece is written from its own bytes, never copied"
                '(#t #t #t)
                (let ((hello (b "hello")))
                  (list (let ((w (piece-write 'chunked hello 0 5)))
                          (and (pair? w) (eq? hello (cadr (car w)))))
                        (let ((w (piece-write 'close-delimited hello 0 5)))
                          (and (pair? w) (eq? hello (car (car w)))))
                        (let ((w (piece-write 'chunked delivery 2 7)))
                          (and (pair? w) (let ((seg (cadr (car w))))
                                           (and (pair? seg) (eq? delivery (car seg))
                                                (equal? (cdr seg) '(2 7)))))))))
    ;; A size line is made once for a piece whose length is a power of two,
    ;; as the pieces a buffer hands out are, and shared by every such piece
    ;; (M6.3's review), as a status line is shared by every response; any
    ;; other length's is made for its piece.
    (test-equal "a size line is shared by every piece of the same power-of-two length, and made afresh otherwise"
                '(shared shared own)
                (let ((line (lambda (bv) (let ((w (piece-write 'chunked bv 0 (bytevector-length bv))))
                                           (if (pair? w) (car (car w)) (list 'refused))))))
                  (list (if (eq? (line four-k) (line (make-bytevector 4096 98))) 'shared 'own)
                        (if (eq? (line (make-bytevector 1 97)) (line (make-bytevector 1 98))) 'shared 'own)
                        (if (eq? (line (b "hello")) (line (b "world"))) 'shared 'own))))

    ;; RFC 9112 §7.1: last-chunk = 1*"0" CRLF, then the trailer section, here
    ;; empty, and CRLF.  A close-delimited body is ended by the close.
    (test-equal "the end of a chunked body is the last chunk and an empty trailer section"
                '("0\r\n\r\n" 1 5)
                (let ((w (end-write 'chunked)))
                  (if (pair? w) (list (wire (car w)) (length (car w)) (cadr w)) w)))
    (test-equal "a close-delimited body's end writes nothing: the close ends it"
                '(() 0) (end-write 'close-delimited))
    (test-equal "a producer's response reads back whole: chunked, to its last chunk"
                `(200 "OK" (,read-date ("Transfer-Encoding" . "chunked")) "hello, world" complete)
                (read-response (text->bytes (streamed 'chunked #f '("hello" ", " "world"))) #f #f))
    (test-equal "and close-delimited, to the close"
                `(200 "OK" (,read-date ("Connection" . "close")) "hello, world" complete)
                (read-response (text->bytes (streamed 'close-delimited 'close '("hello" ", " "world")))
                               #f #t))
    ;; A chunk of no bytes is the last chunk, so an empty piece would end the
    ;; body early: the core never asks for one.  A mode that writes no
    ;; pieces, a span outside its bytevector, and a body of unknown length
    ;; given a Content-Length are refused.
    (test-equal "an empty piece, a piece where no body is written, or one outside its bytevector is refused"
                '(refused refused refused refused refused refused refused)
                (list (piece-write 'chunked (b "hello") 2 2)
                      (piece-write 'close-delimited (b "hello") 5 5)
                      (piece-write 'content-length (b "hello") 0 5)
                      (piece-write 'no-body (b "hello") 0 5)
                      (piece-write 'chunked (b "hello") 3 2)
                      (piece-write 'chunked (b "hello") 0 6)
                      (piece-write 'chunked "hello" 0 5)))
    (test-equal "the end of a mode that writes no pieces is refused"
                '(refused refused refused)
                (map end-write '(content-length content-length-only no-body)))
    (test-equal "a producer given a Content-Length is refused"
                '(refused refused)
                (map (lambda (mode)
                       (assertion-raised?
                        (lambda () (serialize-response (response 200 '() producer) mode #f))))
                     '(content-length content-length-only)))

    ;; The reader, the oracle of these rows and of the core's (M3.2).  One
    ;; that never saw bytes after a message would pass every row whose body
    ;; must not be written.  An interim response is not the answer: a client
    ;; reads on to the final one (RFC 9110 §15.2), and so does the reader;
    ;; alone, it is what there is.
    (test-equal "the reader sees a body written after a HEAD's answer"
                '(200 "OK" (("Content-Length" . "5")) "" bytes-after)
                (read-response (b "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") #t #f))
    (test-equal "the reader reads past a 100 Continue to the final response"
                '(200 "OK" (("Content-Length" . "2")) "ok" complete)
                (read-response (b "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                               #f #f))
    (test-equal "the reader reads a 100 Continue alone as itself"
                '(100 "Continue" () "" complete)
                (read-response (b "HTTP/1.1 100 Continue\r\n\r\n") #f #f))

    ;; The entry for a response whose fault the caller has already asked for
    ;; (M3.2: the core, which answers a fault with 500 before it frames).  It
    ;; writes what serialize-response writes, and refuses what it refuses but
    ;; the fault, which it does not look for again.
    (test-equal "the checked entry writes every row as serialize-response does" '()
                (filter (lambda (r)
                          (not (equal? (call-with-values
                                        (lambda () (serialize-response (row-response r) (row-mode r)
                                                                       (row-connection r)))
                                        list)
                                       (guard (e ((assertion-violation? e) '(refused)))
                                         (call-with-values
                                          (lambda () (serialize-checked-response
                                                      (row-response r) (row-mode r) (row-connection r)))
                                          list)))))
                        rows))
    (test-equal "the checked entry refuses a bad mode, and a close on a kept connection"
                '(refused refused refused)
                (list (assertion-raised?
                       (lambda () (serialize-checked-response (response 200 '() #f) 'identity #f)))
                      (assertion-raised?
                       (lambda () (serialize-checked-response (response 200 '() (b "x"))
                                                              'close-delimited #f)))
                      (assertion-raised?
                       (lambda () (serialize-checked-response (with-header (b "Connection") (b "close"))
                                                              'content-length 'keep-alive)))))

    ;; --- the 101 a switch is written as (M8.2; decision 0016 item 1) ---
    ;; The status line, the handler's fields in its order, `Connection:
    ;; upgrade` (§7.8: a sender of Upgrade MUST list it), and the blank
    ;; line: two segments, no Date slot (§6.6.1: a 1xx MAY carry one, and
    ;; the 100 the server writes carries none) and no framing (§15.2: a 1xx
    ;; has no content).  A handler's own Connection is not copied, and its
    ;; own Date is, as any field.
    (let ((ws "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nConnection: upgrade\r\n\r\n"))
      (test-equal "a WebSocket's 101: the status line, its fields, Connection: upgrade, the blank line; two segments"
                  (list ws 2 (string-length ws))
                  (switched (switch (list (h "Upgrade" "websocket") accept))))
      (let ((dated (string-append "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                  date-text "Connection: upgrade\r\n\r\n")))
        (test-equal "a handler's Connection is not copied, and its Date is"
                    (list dated 2 (string-length dated))
                    (switched (switch (list (h "Upgrade" "websocket") (h "Connection" "Upgrade")
                                            (h "Date" "Sun, 06 Nov 1994 08:49:37 GMT"))))))
      (test-equal "what a client reads: a 101 and its fields, the server's Connection among them, nothing after"
                  '(101 "Switching Protocols"
                        (("Upgrade" . "websocket") ("Sec-WebSocket-Accept" . "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
                         ("Connection" . "upgrade"))
                        "" complete)
                  (let ((w (switched (switch (list (h "Upgrade" "websocket") accept)))))
                    (if (pair? w) (read-response (text->bytes (car w)) #f #f) w))))
    (test-eq "what is not a switch is not written as one" 'refused
             (switched (response 101 (list (h "Upgrade" "websocket")) #f)))
    (for-each
     (lambda (f) (test-eq (string-append "a switch: " (car f)) (cadddr f) (switch-fault (cadr f) (caddr f))))
     switch-faults)))
