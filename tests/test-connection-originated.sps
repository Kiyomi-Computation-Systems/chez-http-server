#!r6rs
;;; (http-server connection): every status the server originates, end to
;;; end, and each one closes the connection.  M3.4.
;;;
;;; Design §6.5's statuses, and decision 0009's 301, each provoked on a fake
;;; connection the way a client provokes it: a request the core refuses, a
;;; head left unfinished past its deadline, a handler that raises or answers
;;; what cannot be written safely, the HTTP/2 preface.  Each response is
;;; written through the serializer and read back with chez-httparse's strict
;;; response parser, a client that is not our code ((response-reader)).
;;;
;;; Every originated status closes the connection (design §6.5): what comes
;;; after it cannot be read safely.  So each row checks that
;;;   - the response says `Connection: close`, with no body and
;;;     `Content-Length: 0` (decision 0010 item 6);
;;;   - nothing the client sent after the offending request is fed to the
;;;     parser or answered.  Every row but the 408, whose head never ends,
;;;     sends a request behind it in the same delivery.  Another is
;;;     delivered while the write is outstanding, if the connection still
;;;     reads then; after a handler's 500 it does not, since reading stopped
;;;     at the pause, and nothing may start it again before the close;
;;;   - the connection closes once the write completes, for the row's reason.
;;; A row states all of it: each write as the client reads it, the actions
;;; from the core's own response on, and the state and reason it ends with.
;;;
;;; 413 has no way in before M6's buffering helper (decision 0005's
;;; max-body-bytes row), so its row is the serializer's alone: the response
;;; the core would originate, framed as the core frames its own.
;;;
;;; Oracles: design §6.5's table, and decision 0009 for the 301; RFC 9110
;;; §15's reason phrases, and RFC 6585 §5's for 431; decision 0010 item 6;
;;; decision 0005's defaults, which set the limit each row passes; and the
;;; Date: the fake clock starts at the epoch, `Thu, 01 Jan 1970 00:00:00
;;; GMT`, and a minute on, when the 408's row is ticked, reads `Thu, 01 Jan
;;; 1970 00:01:00 GMT`.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (only (http-server decisions) originated-reasons response-framing response-connection)
        (only (http-server serializer) serialize-response)
        (fake-shell) (response-reader) (read-back))

(define (b s) (string->utf8 s))

;; lines : Nat String -> String — `n` copies of the header line `line`.
(define (lines n line) (apply string-append (vector->list (make-vector n line))))

;; The Date a minute after the epoch, as the reader returns it.
(define a-minute-on '("Date" . "Thu, 01 Jan 1970 00:01:00 GMT"))

;; at : Field Field ... -> (Listof Field)
;; An originated response's fields: `date`, any of the row's own (a
;; redirect's Location), `Content-Length: 0` and `Connection: close`.
(define (at date . own) (cons date (append own (list (content-length "0") close))))

;; originated : Nat String Symbol (Listof Field) Action ... -> Outcome
;; What the connection does with a status it originates: one write, read
;; back as `status` and `reason` with `fields`; from the core's response on,
;; `before` (the log naming a refused response's fault), the write, the
;; write deadline and the close, and nothing else; and it ends closed, for
;; `why`.
(define (originated status reason why fields . before)
  (list (list (message status reason fields ""))
        (append before (list (list 'write status) '(arm-deadline write) (list 'close why)))
        'closed why))

(define get "GET / HTTP/1.1\r\nHost: x\r\n\r\n")

;; The handlers: one that answers, one that raises, and one whose answer
;; carries its own framing, which the server writes (decision 0010 item 2).
(define (answers request) (make-response 200 #f '() (b "ok")))
(define (raises request) (raise 'boom))
(define (frames-itself request)
  (make-response 200 #f (list (cons (b "Content-Length") (b "2"))) (b "ok")))

;; deliver! : FakeShell Bytevector -> Any — one delivery, all of it.
(define (deliver! sh bv) (fake-shell-deliver! sh (list 'bytes-arrived bv 0 (bytevector-length bv))))

;; sent : String -> (FakeShell -> Any)
;; The client sends `text` in one delivery.
(define (sent text) (lambda (sh) (deliver! sh (b text))))

;; stalled : String -> (FakeShell -> Any)
;; The client sends `text`, a head it never finishes; a minute passes, and
;; the connection is ticked, as M5's wheel ticks one whose header deadline
;; has passed.  The core reads no clock: the tick is what tells it, and only
;; the Date shows the minute.
(define (stalled text)
  (lambda (sh)
    (deliver! sh (b text))
    (fake-shell-advance! sh 60000)
    (fake-shell-tick! sh)))

;; from-response : (Listof Action) -> (Listof Datum)
;; The actions from the core's own response on: from its write, or from the
;; log before it naming a fault.  A write shows as its status.
(define (from-response actions)
  (cond ((null? actions) '())
        ((memq (caar actions) '(log write))
         (map (lambda (a) (if (eq? (car a) 'write) (list 'write (written-status a)) a)) actions))
        (else (from-response (cdr actions)))))

;; drive : (Request -> Response) (FakeShell -> Any) -> Outcome
;; One connection under decision 0005's defaults, with `handler`: the
;; client's moves, then another request, delivered while the connection
;; still reads and before any write has completed, then every later turn.
;; The outcome: each write read back, the actions from the core's own
;; response on, and the phase and reason the connection ended with; or
;; `(raised)` if the run raised.
(define (drive handler provoke)
  (guard (e (#t '(raised)))
    (let ((sh (make-fake-connection default-limits handler)))
      (provoke sh)
      (when (fake-shell-reading? sh) (deliver! sh (b get)))
      (fake-shell-settle! sh)
      (let ((s (fake-shell-conn-state sh)))
        (list (map (lambda (w) (read-response w #f #f)) (fake-shell-writes sh))
              (from-response (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s))))))

;; A row: what it shows; the handler; the client's moves; the outcome.
(define (row text handler provoke outcome) (list text handler provoke outcome))
(define (row-status r) (car (car (car (list-ref r 3)))))
(define (row-reason r) (list-ref (list-ref r 3) 3))

(define max-target (limits-max-target-bytes default-limits))
(define max-field (limits-max-header-field-bytes default-limits))
(define max-value (limits-max-header-value-bytes default-limits))
(define max-count (limits-max-header-count default-limits))

(define rows
  (list
   ;; A GET or HEAD whose target's only faults are bracket params and pipes
   ;; is redirected to the target encoded (decision 0009).
   (row "301: bracket params in a GET, redirected to the target encoded"
        answers (sent (string-append "GET /s?ids[]=1 HTTP/1.1\r\nHost: x\r\n\r\n" get))
        (originated 301 "Moved Permanently" 'target-redirect (at epoch '("Location" . "/s?ids%5B%5D=1"))))
   ;; 400: a target or a Host the core refuses, and a parser error.
   (row "400: a target with a fragment, which no request-target form allows"
        answers (sent (string-append "GET /a#b HTTP/1.1\r\nHost: x\r\n\r\n" get))
        (originated 400 "Bad Request" 'invalid-target (at epoch)))
   (row "400: HTTP/1.1 with no Host"
        answers (sent (string-append "GET / HTTP/1.1\r\n\r\n" get))
        (originated 400 "Bad Request" 'invalid-host (at epoch)))
   (row "400: a parser error, a space in a field name"
        answers (sent (string-append "GET / HTTP/1.1\r\nHo st: x\r\n\r\n" get))
        (originated 400 "Bad Request" 'parser-error (at epoch)))
   ;; HTTP/1.0 has no Transfer-Encoding, so a request below 1.1 that carries
   ;; it has faulty framing (RFC 9112 §6.1; decided on the owner's word,
   ;; 2026-09-26).
   (row "400: an HTTP/1.0 request with Transfer-Encoding"
        answers (sent (string-append "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" get))
        (originated 400 "Bad Request" 'faulty-framing (at epoch)))
   ;; With no chunked coding the body's length cannot be known (RFC 9112
   ;; §6.3), and the parser refuses the request.
   (row "400: a parser error, a Transfer-Encoding with no chunked"
        answers (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: pigeons\r\n\r\n" get))
        (originated 400 "Bad Request" 'parser-error (at epoch)))
   ;; 408: the header deadline passes with the head unfinished.
   (row "408: a head still unfinished when the header deadline passes"
        answers (stalled "GET / HTTP/1.1\r\nHo")
        (originated 408 "Request Timeout" 'header-timeout (at a-minute-on)))
   ;; 414 and 431: one past a limit.
   (row "414: a target one byte past max-target-bytes"
        answers (sent (string-append "GET /" (make-string max-target #\a) " HTTP/1.1\r\nHost: x\r\n\r\n" get))
        (originated 414 "URI Too Long" 'target-too-large (at epoch)))
   (row "431: a field name one byte past max-header-field-bytes"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n" (make-string (+ max-field 1) #\n)
                                     ": v\r\n\r\n" get))
        (originated 431 "Request Header Fields Too Large" 'header-field-too-large (at epoch)))
   (row "431: a field value one byte past max-header-value-bytes"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\nX: " (make-string (+ max-value 1) #\v)
                                     "\r\n\r\n" get))
        (originated 431 "Request Header Fields Too Large" 'header-value-too-large (at epoch)))
   (row "431: one field past max-header-count"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n" (lines max-count "X: v\r\n")
                                     "\r\n" get))
        (originated 431 "Request Header Fields Too Large" 'too-many-headers (at epoch)))
   ;; Three 6,000-byte values: each within max-header-value-bytes, together
   ;; past max-header-bytes (16,384).
   (row "431: a header section past max-header-bytes, each field within its own limit"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n"
                                     (lines 3 (string-append "X: " (make-string 6000 #\v) "\r\n"))
                                     "\r\n" get))
        (originated 431 "Request Header Fields Too Large" 'headers-too-large (at epoch)))
   ;; 500: the handler raised, or answered what cannot be written safely.
   ;; Its request was read whole, so the one behind it in the delivery is
   ;; the pause's pending input, never fed.
   (row "500: the handler raised"
        raises (sent (string-append get get))
        (originated 500 "Internal Server Error" 'handler-failed (at epoch)))
   (row "500: the handler answered with its own Content-Length"
        frames-itself (sent (string-append get get))
        (originated 500 "Internal Server Error" 'invalid-response (at epoch)
                    '(log invalid-response framing-field)))
   ;; 501: a coding before a final chunked, which the server does not
   ;; implement (RFC 9112 §6.1).
   (row "501: Transfer-Encoding: gzip, chunked"
        answers (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
                                     "0\r\n\r\n" get))
        (originated 501 "Not Implemented" 'unsupported-transfer-coding (at epoch)))
   ;; 505: HTTP/2's preface; there is nothing to hand it to (decision 0006
   ;; item 2).
   (row "505: the HTTP/2 preface"
        answers (sent (string-append "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" get))
        (originated 505 "HTTP Version Not Supported" 'http2-preface (at epoch)))))

;; serialized : Nat -> (Listof Datum)
;; The response the core would originate with `status`, read back: no body,
;; framed as the core frames a response to no request it has read, and
;; closing (decision 0010 item 6).  `(raised)` if serializing it raised.
(define (serialized status)
  (guard (e (#t '(raised)))
    (let-values (((segments nbytes)
                  (serialize-response (make-response status #f '() #f)
                                      (response-framing #f 1 1 status #f)
                                      (response-connection #t 1 1))))
      (list (read-response (write-wire segments nbytes 0) #f #f)))))

;; The statuses driven end to end: design §6.5's but 413, and 0009's 301.
(define end-to-end '(301 400 408 414 431 500 501 505))

(run-suite "connection-originated"
  (lambda ()
    (for-each (lambda (r)
                (test-equal (car r) (list-ref r 3) (drive (list-ref r 1) (list-ref r 2))))
              rows)

    (test-equal "413, through the serializer alone: no body, Content-Length: 0 and Connection: close"
                (list (message 413 "Content Too Large" (at epoch) ""))
                (serialized 413))

    ;; The table is every status the core originates, not a sample of them.
    ;; A parser error's status is the error's, not a reason's (design §6.3).
    (test-equal "every reason the core originates a response for has a row" '()
                (filter (lambda (reason) (not (memq reason (map row-reason rows))))
                        originated-reasons))
    (test-equal "every row's reason is one of them, or a parser error" '()
                (filter (lambda (reason)
                          (not (or (eq? reason 'parser-error) (memq reason originated-reasons))))
                        (map row-reason rows)))
    (test-equal "design §6.5's statuses but 413, and decision 0009's 301, each have a row"
                end-to-end
                (filter (lambda (status) (memv status (map row-status rows))) end-to-end))))
