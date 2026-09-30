#!r6rs
;;; (http-server connection): every status the server originates, end to
;;; end, and each one closes the connection, in stages.  M3.4, and M3.5's
;;; staged close.
;;;
;;; Design §6.5's statuses, and decision 0009's 301, each provoked on a fake
;;; connection the way a client provokes it: a request the core refuses, a
;;; head or a body left unfinished past its deadline, a body past a cap, a
;;; handler that raises or answers what cannot be written safely, the HTTP/2
;;; preface.  Each response is
;;; written through the serializer and read back with chez-httparse's strict
;;; response parser, a client that is not our code ((response-reader)).
;;;
;;; Every originated status closes the connection (design §6.5): what comes
;;; after it cannot be read safely.  So each row checks that
;;;   - the response says `Connection: close`, with no body and
;;;     `Content-Length: 0` (decision 0010 item 6);
;;;   - the connection stops reading when it refuses a request, as
;;;     `responding` does not read (design §4.3); a handler's 500 comes after
;;;     reading stopped at the pause;
;;;   - once the write completes, the connection closes in stages (RFC 9112
;;;     §9.6; decision 0011): it shuts its write side, reads again, drops
;;;     what arrives, and closes when the client closes;
;;;   - nothing the client sent after the offending request is fed to the
;;;     parser or answered.  Every row but the two 408s, whose requests
;;;     never end, sends a request behind it in the same delivery, and every
;;;     row sends another while the connection lingers;
;;;   - the connection closes for the row's reason.
;;; A row states all of it: each write as the client reads it, the actions
;;; from the core's own response on, and the state and reason it ends with.
;;; The client's close ends the linger, and like every close it disarms the
;;; deadline first (M5.2).
;;;
;;; 413 has its way in since M6.1 (decision 0013 item 5): a body past a
;;; cap, here the limits' max-body-bytes.  A request whose head announces a
;;; body is handed to its handler at the head, and a response given instead
;;; of a reader closes the connection (decision 0013), so the 408's body is
;;; read by its handler.  M6.4 adds a second way in, a body's chunk
;;; extensions past 16 KiB together, and a trailer field past the header
;;; limits, answered 431 as a head's is.  Both rows' requests arrive in the
;;; head's delivery, so what they meet waits for the handler's answer, and
;;; reading stops where it is met.  The padding PR adds a 400 for what the
;;; parser reads and hands no span of: a chunk size of more than 16 digits,
;;; met in the head's delivery too.
;;;
;;; Oracles: design §6.5's table, and decision 0009 for the 301; RFC 9110
;;; §15's reason phrases, and RFC 6585 §5's for 431; decision 0010 item 6;
;;; decision 0005's defaults, which set the limit each row passes; and the
;;; Date: the fake clock starts at the epoch, `Thu, 01 Jan 1970 00:00:00
;;; GMT`, and a minute on, when the 408s' rows are ticked, reads `Thu, 01 Jan
;;; 1970 00:01:00 GMT`.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (only (http-server decisions) originated-reasons)
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

;; closes : Nat String Symbol (Listof Field) (Listof Action) (Listof Action)
;;          -> Outcome
;; What the connection does with a status it originates: one write, read
;; back as `status` and `reason` with `fields`; from the core's response on,
;; `before` (the log naming a refused response's fault), the write, `stop`
;; (the read-stop of a connection still reading), the write deadline, then
;; the staged close, and nothing else; and it ends closed, for `why`.
(define (closes status reason why fields before stop)
  (list (list (message status reason fields ""))
        (append before (list (list 'write status)) stop
                (list '(arm-deadline write) '(shutdown) '(read-start) '(arm-deadline linger)
                      '(disarm-deadline) (list 'close why)))
        'closed why))

;; refused : Nat String Symbol (Listof Field) -> Outcome
;; A status for a request the core refuses as it reads it: reading stops
;; with the write.
(define (refused status reason why fields) (closes status reason why fields '() '((read-stop))))

;; failed : Nat String Symbol (Listof Field) Action ... -> Outcome
;; A status in place of a handler's answer, after reading stopped at the
;; pause; `before` is the log naming a fault.
(define (failed status reason why fields . before) (closes status reason why fields before '()))

;; kept : Nat String Symbol (Listof Field) -> Outcome
;; A status for what the feed that completed the head met in the body, which
;; waited for the handler's answer (decision 0013): reading stopped where it
;; was met, before the handler was asked.
(define (kept status reason why fields) (closes status reason why fields '() '()))

(define get "GET / HTTP/1.1\r\nHost: x\r\n\r\n")

;; The handlers: one that answers, one that raises, and one whose answer
;; carries its own framing, which the server writes (decision 0010 item 2).
(define (answers request) (make-response 200 #f '() (b "ok")))
(define (raises request) (raise 'boom))
(define (frames-itself request)
  (make-response 200 #f (list (cons (b "Content-Length") (b "2"))) (b "ok")))
;; reads : a handler that reads the body, dropping it, then answers.
(define reads (drops-body answers))

;; sent : String -> (FakeShell -> Any)
;; The client sends `text` in one delivery.
(define (sent text) (lambda (sh) (send! sh text)))

;; stalled : String -> (FakeShell -> Any)
;; The client sends `text`, a request it never finishes; a minute passes,
;; the header and body deadlines' 60 s, and the fake's timer fires, which
;; ticks the connection once its deadline has passed (M5.3).  The core reads
;; no clock: the tick is what tells it, and only the Date shows the minute.
(define (stalled text)
  (lambda (sh)
    (send! sh text)
    (fake-shell-advance! sh 60000)
    (fake-shell-fire! sh)))

;; drive : (Request -> Any) (FakeShell -> Any) Limits -> Outcome
;; One connection under `limits`, with `handler`: the
;; client's moves, then every later turn; then, as a client does once it has
;; read a response that closes, another request and its close, each
;; delivered only while the connection reads, as libuv delivers them; then
;; every later turn.  The outcome: each write read back, the actions from
;; the core's own response on, and the phase and reason the connection
;; ended with; or `(raised)` if the run raised.
(define (drive handler provoke limits)
  (guard (e (#t '(raised)))
    (let ((sh (make-fake-connection limits handler)))
      (provoke sh)
      (fake-shell-settle! sh)
      (send! sh get)
      (client-close! sh)
      (fake-shell-settle! sh)
      (let ((s (fake-shell-conn-state sh)))
        (list (map (lambda (w) (read-response w #f #f)) (fake-shell-writes sh))
              (from-response (fake-shell-actions sh))
              (conn-phase s) (conn-close-after s))))))

;; A row: what it shows; the handler; the client's moves; the outcome; and
;; the limits, decision 0005's defaults unless given.
(define (row text handler provoke outcome . limits)
  (list text handler provoke outcome (if (null? limits) default-limits (car limits))))
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
        (refused 301 "Moved Permanently" 'target-redirect (at epoch '("Location" . "/s?ids%5B%5D=1"))))
   ;; 400: a target or a Host the core refuses, and a parser error.
   (row "400: a target with a fragment, which no request-target form allows"
        answers (sent (string-append "GET /a#b HTTP/1.1\r\nHost: x\r\n\r\n" get))
        (refused 400 "Bad Request" 'invalid-target (at epoch)))
   (row "400: HTTP/1.1 with no Host"
        answers (sent (string-append "GET / HTTP/1.1\r\n\r\n" get))
        (refused 400 "Bad Request" 'invalid-host (at epoch)))
   (row "400: a parser error, a space in a field name"
        answers (sent (string-append "GET / HTTP/1.1\r\nHo st: x\r\n\r\n" get))
        (refused 400 "Bad Request" 'parser-error (at epoch)))
   ;; HTTP/1.0 has no Transfer-Encoding, so a request below 1.1 that carries
   ;; it has faulty framing (RFC 9112 §6.1; decided on the owner's word,
   ;; 2026-09-26).
   (row "400: an HTTP/1.0 request with Transfer-Encoding"
        answers (sent (string-append "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" get))
        (refused 400 "Bad Request" 'faulty-framing (at epoch)))
   ;; With no chunked coding the body's length cannot be known (RFC 9112
   ;; §6.3), and the parser refuses the request.
   (row "400: a parser error, a Transfer-Encoding with no chunked"
        answers (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: pigeons\r\n\r\n" get))
        (refused 400 "Bad Request" 'parser-error (at epoch)))
   ;; What the parser reads and hands no span of (the padding PR): a chunk
   ;; size of 17 digits, zeros included.
   (row "400: a chunk size of 17 digits"
        reads (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                   (make-string 16 #\0) "5\r\nhello\r\n0\r\n\r\n" get))
        (kept 400 "Bad Request" 'chunk-size-too-long (at epoch)))
   ;; 408: the header deadline passes with the head unfinished, or the body
   ;; deadline with the body unfinished (M5.2): two of its five bytes.
   (row "408: a head still unfinished when the header deadline passes"
        answers (stalled "GET / HTTP/1.1\r\nHo")
        (refused 408 "Request Timeout" 'header-timeout (at a-minute-on)))
   (row "408: a body still unfinished when the body deadline passes"
        reads (stalled "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nab")
        (refused 408 "Request Timeout" 'body-timeout (at a-minute-on)))
   ;; 413: a declared length one byte past max-body-bytes, refused before
   ;; any of the body is read or the handler asked (decision 0013 item 5).
   (row "413: a declared length one byte past max-body-bytes"
        reads (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" get))
        (refused 413 "Content Too Large" 'body-too-large (at epoch))
        (limits-with default-limits '((max-body-bytes . 4))))
   ;; A chunked body's extensions, all of them together, one byte past
   ;; 16 KiB (M6.4): answered as a body past a cap is.  The reader is handed
   ;; no piece: the extension comes before the chunk's data.
   (row "413: a body's chunk extensions one byte past 16 KiB"
        reads (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5;e="
                                   (make-string 16384 #\v) "\r\nhello\r\n0\r\n\r\n" get))
        (kept 413 "Content Too Large" 'chunk-extensions-too-large (at epoch)))
   ;; 414 and 431: one past a limit.
   (row "414: a target one byte past max-target-bytes"
        answers (sent (string-append "GET /" (make-string max-target #\a) " HTTP/1.1\r\nHost: x\r\n\r\n" get))
        (refused 414 "URI Too Long" 'target-too-large (at epoch)))
   (row "431: a field name one byte past max-header-field-bytes"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n" (make-string (+ max-field 1) #\n)
                                     ": v\r\n\r\n" get))
        (refused 431 "Request Header Fields Too Large" 'header-field-too-large (at epoch)))
   (row "431: a field value one byte past max-header-value-bytes"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\nX: " (make-string (+ max-value 1) #\v)
                                     "\r\n\r\n" get))
        (refused 431 "Request Header Fields Too Large" 'header-value-too-large (at epoch)))
   (row "431: one field past max-header-count"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n" (lines max-count "X: v\r\n")
                                     "\r\n" get))
        (refused 431 "Request Header Fields Too Large" 'too-many-headers (at epoch)))
   ;; Three 6,000-byte values: each within max-header-value-bytes, together
   ;; past max-header-bytes (16,384).
   (row "431: a header section past max-header-bytes, each field within its own limit"
        answers (sent (string-append "GET / HTTP/1.1\r\nHost: x\r\n"
                                     (lines 3 (string-append "X: " (make-string 6000 #\v) "\r\n"))
                                     "\r\n" get))
        (refused 431 "Request Header Fields Too Large" 'headers-too-large (at epoch)))
   ;; A chunked body's trailer fields are held to the same four limits
   ;; (M6.4), and one past them is answered as a head's is.
   (row "431: a trailer field value one byte past max-header-value-bytes"
        reads (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                   "5\r\nhello\r\n0\r\nT: " (make-string (+ max-value 1) #\v) "\r\n\r\n" get))
        (kept 431 "Request Header Fields Too Large" 'header-value-too-large (at epoch)))
   ;; 500: the handler raised, or answered what cannot be written safely.
   ;; Its request was read whole, so the one behind it in the delivery is
   ;; the pause's pending input, never fed.
   (row "500: the handler raised"
        raises (sent (string-append get get))
        (failed 500 "Internal Server Error" 'handler-failed (at epoch)))
   (row "500: the handler answered with its own Content-Length"
        frames-itself (sent (string-append get get))
        (failed 500 "Internal Server Error" 'invalid-response (at epoch)
                    '(log invalid-response framing-field)))
   ;; 501: a coding before a final chunked, which the server does not
   ;; implement (RFC 9112 §6.1).
   (row "501: Transfer-Encoding: gzip, chunked"
        answers (sent (string-append "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
                                     "0\r\n\r\n" get))
        (refused 501 "Not Implemented" 'unsupported-transfer-coding (at epoch)))
   ;; 505: HTTP/2's preface; there is nothing to hand it to (decision 0006
   ;; item 2).
   (row "505: the HTTP/2 preface"
        answers (sent (string-append "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" get))
        (refused 505 "HTTP Version Not Supported" 'http2-preface (at epoch)))))

;; The statuses driven end to end: design §6.5's, and 0009's 301.
(define end-to-end '(301 400 408 413 414 431 500 501 505))

(run-suite "connection-originated"
  (lambda ()
    (for-each (lambda (r)
                (test-equal (car r) (list-ref r 3) (drive (list-ref r 1) (list-ref r 2) (list-ref r 4))))
              rows)

    ;; The table is every status the core originates, not a sample of them.
    ;; A parser error's status is the error's, not a reason's (design §6.3).
    (test-equal "every reason the core originates a response for has a row" '()
                (filter (lambda (reason) (not (memq reason (map row-reason rows))))
                        originated-reasons))
    (test-equal "every row's reason is one of them, or a parser error" '()
                (filter (lambda (reason)
                          (not (or (eq? reason 'parser-error) (memq reason originated-reasons))))
                        (map row-reason rows)))
    (test-equal "design §6.5's statuses, and decision 0009's 301, each have a row"
                end-to-end
                (filter (lambda (status) (memv status (map row-status rows))) end-to-end))))
