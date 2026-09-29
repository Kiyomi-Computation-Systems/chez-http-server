#!r6rs
;;; (http-server serializer) — a response, as the bytes the server writes (M3;
;;; design §3.1, §7.3; decision 0010).
;;;
;;; `serialize-response` turns a response record and the connection's framing
;;; decision into the segments of one `uv-write*!`: the status line, the Date
;;; slot, the header block and the body, each a segment of its own, so nothing
;;; is concatenated (one request, one completion; design §7.3).  It is a
;;; function of its arguments alone, tabled apart from any connection state,
;;; which is why it is a library of its own.
;;;
;;; THE DATE SLOT (decision 0010 item 4).  The core reads no clock (decision
;;; 0002 item 1), so a final response leaves the symbol `date` where its Date
;;; line goes, directly after the status line, and the shell writes the line
;;; there.  A line is always `date-line-length` bytes, so the byte count is
;;; exact before the shell fills the slot.  `date-line` formats one from whole
;;; seconds since the epoch; the shell keeps it and re-formats it when the
;;; second changes.  A response whose handler wrote its own Date keeps that
;;; one and leaves no slot.
;;;
;;; THE FRAMING IS THE SERVER'S (decision 0010 items 1 and 3).  The handler's
;;; fields are written in its order, then Content-Length or Transfer-Encoding
;;; as the mode says, then Connection as the connection says, then the blank
;;; line.  A handler's own Connection field is never copied: it may only be
;;; `close`, and the connection argument carries that.
;;;
;;; A BODY OF UNKNOWN LENGTH IS A PRODUCER (M6.3; decision 0013 item 8): a
;;; procedure the server calls for each piece, which answers a bytevector,
;;; or the eof object at the end.  Its head writes no body, and each piece
;;; is a write of its own, `serialize-piece`, then the end, `serialize-end`:
;;; chunked to HTTP/1.1, close-delimited to any other version (the framing
;;; decision's).  A piece is never copied: chez-libuv copies every segment
;;; as the write is issued (design §7.3), so a segment may also be a span of
;;; a bytevector, `(bv start end)`, as uv-write*! takes one.
;;;
;;; WHAT CANNOT BE WRITTEN SAFELY is a fault (decision 0010 item 2).
;;; `response-fault` names it, and the core answers 500 instead; serializing
;;; a response with a fault is a caller bug, an assertion violation.  A
;;; caller that has asked already, as the core has, writes the response with
;;; `serialize-checked-response`, which does not read it for faults again.  The
;;; value bytes refused are the ones llhttp's strict parser refuses in a
;;; field value: every control character but HTAB.
;;;
;;; PURE: imports only (rnrs) and this project's pure libraries.
(library (http-server serializer)
  (export serialize-response serialize-checked-response serialize-piece serialize-end
          response-fault response-closes? framing-modes date-line date-line-length)
  (import (rnrs) (http-server response) (http-server span)
          (only (http-server headers) header-name=? trim-ows range-ci=?))

  ;; framing-modes : (Listof Symbol)
  ;; How a response's body goes on the wire, as the framing decision names it
  ;; (M3.2; RFC 9112 §6):
  ;;   content-length       Content-Length, then the body
  ;;   content-length-only  Content-Length and no body: a HEAD's answer
  ;;   no-body              neither, and no body: a 204, a 304, a 2xx to
  ;;                        CONNECT, a HEAD answered with no body
  ;;   chunked              Transfer-Encoding: chunked, and the body, if any,
  ;;                        as the first chunk; a producer's pieces follow,
  ;;                        each a write of its own (M6.3)
  ;;   close-delimited      neither, then the body, which the close ends
  (define framing-modes
    '(content-length content-length-only no-body chunked close-delimited))

  ;; serialize-response :
  ;;   Response Mode Connection -> (values (Listof Segment) Nat)
  ;;   Mode       = one of framing-modes
  ;;   Connection = (U 'close 'keep-alive #f) — the Connection field to write
  ;;   Segment    = (U Bytevector 'date (List Bytevector Nat Nat)) — 'date is
  ;;                the Date slot, and a list a span of a bytevector
  ;; The segments of one write, in order, and the bytes they come to, the
  ;; slot counted at date-line-length.  A producer's head writes no body: its
  ;; pieces follow (serialize-piece).  A response with a fault, a mode or a
  ;; connection outside those sets, a close-delimited body or a handler's
  ;; `Connection: close` on a connection that stays open, and a producer
  ;; given a Content-Length, are assertion violations.
  (define (serialize-response r mode connection)
    (cond ((response-fault r)
           => (lambda (fault)
                (assertion-violation 'serialize-response "a response with a fault" fault))))
    (serialize-checked-response r mode connection))

  ;; serialize-checked-response :
  ;;   Response Mode Connection -> (values (Listof Segment) Nat)
  ;; serialize-response for a response whose response-fault the caller has
  ;; already found #f, as the core has before it frames a handler's response
  ;; (M3.2): the fault check reads every byte of every field, so it is not
  ;; made twice.  Everything else is checked as serialize-response checks it.
  (define (serialize-checked-response r mode connection)
    (cond ((not (memq mode framing-modes))
           (assertion-violation 'serialize-response "not a framing mode" mode))
          ((not (memq connection '(close keep-alive #f)))
           (assertion-violation 'serialize-response "not a Connection" connection))
          ((and (not (eq? connection 'close))
                (or (eq? mode 'close-delimited) (response-closes? r)))
           (assertion-violation 'serialize-response
             "a response that closes the connection, on one that stays open" mode))
          ((and (procedure? (response-body r)) (memq mode '(content-length content-length-only)))
           (assertion-violation 'serialize-response
             "a body of unknown length has no Content-Length" mode)))
    (let* ((headers (response-headers r))
           (body (response-body r))
           (length (if (bytevector? body) (bytevector-length body) 0))
           (status (status-line (response-status r) (response-reason r)))
           (block (header-block headers mode length connection))
           (tail (body-segments mode body length))
           (bytes (fold-left (lambda (n seg) (fx+ n (bytevector-length seg)))
                             (fx+ (bytevector-length status) (bytevector-length block))
                             tail)))
      (if (exists (lambda (h) (header-name=? (car h) date-name)) headers)
          (values (cons status (cons block tail)) bytes)
          (values (cons status (cons 'date (cons block tail)))
                  (fx+ bytes date-line-length)))))

  ;; --- the status line --------------------------------------------------------

  ;; The reason phrases: RFC 9110 §15's, and RFC 6585's for 428, 429, 431 and
  ;; 511.  A status without one is written with an empty phrase, which RFC
  ;; 9112 §4 allows ("status-code SP [ reason-phrase ]"); a client ignores
  ;; the phrase anyway.
  (define reason-phrases
    '((100 . "Continue") (101 . "Switching Protocols")
      (200 . "OK") (201 . "Created") (202 . "Accepted")
      (203 . "Non-Authoritative Information") (204 . "No Content")
      (205 . "Reset Content") (206 . "Partial Content")
      (300 . "Multiple Choices") (301 . "Moved Permanently") (302 . "Found")
      (303 . "See Other") (304 . "Not Modified") (305 . "Use Proxy")
      (307 . "Temporary Redirect") (308 . "Permanent Redirect")
      (400 . "Bad Request") (401 . "Unauthorized") (402 . "Payment Required")
      (403 . "Forbidden") (404 . "Not Found") (405 . "Method Not Allowed")
      (406 . "Not Acceptable") (407 . "Proxy Authentication Required")
      (408 . "Request Timeout") (409 . "Conflict") (410 . "Gone")
      (411 . "Length Required") (412 . "Precondition Failed")
      (413 . "Content Too Large") (414 . "URI Too Long")
      (415 . "Unsupported Media Type") (416 . "Range Not Satisfiable")
      (417 . "Expectation Failed") (421 . "Misdirected Request")
      (422 . "Unprocessable Content") (426 . "Upgrade Required")
      (428 . "Precondition Required") (429 . "Too Many Requests")
      (431 . "Request Header Fields Too Large")
      (500 . "Internal Server Error") (501 . "Not Implemented")
      (502 . "Bad Gateway") (503 . "Service Unavailable")
      (504 . "Gateway Timeout") (505 . "HTTP Version Not Supported")
      (511 . "Network Authentication Required")))

  ;; build-status-line : Nat Bytevector -> Bytevector
  ;; `HTTP/1.1 NNN reason CRLF`: the version is always 1.1 (RFC 9110 §2.5).
  (define (build-status-line status reason)
    (let* ((n (bytevector-length reason))
           (out (make-bytevector (fx+ 15 n))))
      (bytevector-copy! version-prefix 0 out 0 9)
      (put-decimal! out 12 status)
      (bytevector-u8-set! out 12 32)
      (bytevector-copy! reason 0 out 13 n)
      (bytevector-u8-set! out (fx+ 13 n) 13)
      (bytevector-u8-set! out (fx+ 14 n) 10)
      out))

  (define version-prefix (string->utf8 "HTTP/1.1 "))

  ;; status-line : Nat (U Bytevector #f) -> Bytevector
  (define (status-line status reason)
    (cond (reason (build-status-line status reason))
          ((vector-ref status-lines status))
          (else (build-status-line status (make-bytevector 0)))))

  ;; put-decimal! : Bytevector Nat Nat -> Void
  ;; Write `n`'s decimal digits into `out`, ending just before `end`.
  (define (put-decimal! out end n)
    (let loop ((at (fx- end 1)) (n n))
      (bytevector-u8-set! out at (fx+ 48 (fxmod n 10)))
      (when (fx>=? n 10) (loop (fx- at 1) (fxdiv n 10)))))

  ;; decimal-digits : Nat -> Nat — how many digits `n` is written in.
  (define (decimal-digits n)
    (if (fx<? n 10) 1 (fx+ 1 (decimal-digits (fxdiv n 10)))))

  ;; status-lines : (Vectorof (U Bytevector #f)) — by status, made once, so a
  ;; registered status's line allocates nothing per response.
  (define status-lines
    (let ((v (make-vector 600 #f)))
      (for-each (lambda (row)
                  (vector-set! v (car row) (build-status-line (car row) (string->utf8 (cdr row)))))
                reason-phrases)
      v))

  ;; --- the header block ---------------------------------------------------------

  (define date-name (string->utf8 "Date"))
  (define content-length-prefix (string->utf8 "Content-Length: "))
  (define chunked-line (string->utf8 "Transfer-Encoding: chunked\r\n"))
  (define close-line (string->utf8 "Connection: close\r\n"))
  (define keep-alive-line (string->utf8 "Connection: keep-alive\r\n"))
  (define crlf (string->utf8 "\r\n"))

  ;; put-bytes! : Bytevector Nat Bytes -> Nat — copy `x` in at `at`; where it ends.
  (define (put-bytes! out at x)
    (let ((n (bytes-length x)))
      (bytevector-copy! (bytes-vector x) (bytes-start x) out at n)
      (fx+ at n)))

  ;; header-block : Headers Mode Nat Connection -> Bytevector
  ;; The handler's fields but Connection, the framing field, the Connection
  ;; field, and the blank line, in one bytevector.
  (define (header-block headers mode length connection)
    (let* ((framing (case mode
                      ((content-length content-length-only)
                       (fx+ (fx+ (bytevector-length content-length-prefix) (decimal-digits length)) 2))
                      ((chunked) (bytevector-length chunked-line))
                      (else 0)))
           (closing (case connection
                      ((close) close-line)
                      ((keep-alive) keep-alive-line)
                      (else #f)))
           (size (fold-left (lambda (n h)
                              (if (copied? h)
                                  (fx+ n (fx+ (fx+ (bytes-length (car h)) (bytes-length (cdr h))) 4))
                                  n))
                            (fx+ (fx+ framing (if closing (bytevector-length closing) 0)) 2)
                            headers))
           (out (make-bytevector size)))
      (let* ((at (fold-left (lambda (at h)
                              (if (copied? h)
                                  (let ((at (put-bytes! out at (car h))))
                                    (bytevector-u8-set! out at 58)          ; ":"
                                    (bytevector-u8-set! out (fx+ at 1) 32)  ; SP
                                    (put-bytes! out (put-bytes! out (fx+ at 2) (cdr h)) crlf))
                                  at))
                            0 headers))
             (at (case mode
                   ((content-length content-length-only)
                    (let* ((at (put-bytes! out at content-length-prefix))
                           (end (fx+ at (decimal-digits length))))
                      (put-decimal! out end length)
                      (put-bytes! out end crlf)))
                   ((chunked) (put-bytes! out at chunked-line))
                   (else at)))
             (at (if closing (put-bytes! out at closing) at)))
        (put-bytes! out at crlf))
      out))

  ;; copied? : (Pair Bytes Bytes) -> Boolean — every field of the handler's
  ;; but Connection, which the connection argument writes.
  (define (copied? h) (not (header-name=? (car h) connection-name)))

  ;; body-segments : Mode (U Bytevector #f) Nat -> (Listof Bytevector)
  ;; What follows the head: the body itself, never copied, where the mode
  ;; writes one and there is one; for chunked, framed as the first chunk
  ;; (RFC 9112 §7.1: chunk-size in hex, CRLF, the data, CRLF).
  (define (body-segments mode body length)
    (cond ((fx=? length 0) '())
          ((memq mode '(content-length close-delimited)) (list body))
          ((eq? mode 'chunked) (list (chunk-size-line length) body crlf))
          (else '())))

  ;; --- a producer's pieces (M6.3) -------------------------------------------------

  ;; serialize-piece : Mode Bytevector Nat Nat -> (values (Listof Segment) Nat)
  ;; One piece of a producer's body, bv[start, end), as the segments of one
  ;; write, and the bytes they come to (decision 0013 item 8): chunked, its
  ;; size line, the piece and CRLF (RFC 9112 §7.1); close-delimited, the piece
  ;; alone.  The piece is never copied: a whole bytevector is its own
  ;; segment, and a span of one is uv-write*!'s `(bv start end)`.  The size
  ;; line of a piece whose length is a power of two, as the pieces a buffer
  ;; hands out are, is made once and shared (size-line).  An empty piece is
  ;; an assertion violation, since a chunk of no bytes is the last chunk, and
  ;; so the caller writes none; so are a mode no piece is written in and a
  ;; span outside its bytevector.
  (define (serialize-piece mode bv start end)
    (unless (memq mode '(chunked close-delimited))
      (assertion-violation 'serialize-piece "not a mode a producer's pieces are written in" mode))
    (unless (and (bytevector? bv) (fixnum? start) (fixnum? end)
                 (fx<=? 0 start) (fx<? start end) (fx<=? end (bytevector-length bv)))
      (assertion-violation 'serialize-piece "not a piece: a span of a byte or more" bv start end))
    (let* ((n (fx- end start))
           (piece (if (and (fxzero? start) (fx=? end (bytevector-length bv))) bv (list bv start end))))
      (if (eq? mode 'chunked)
          (let ((line (size-line n)))
            (values (list line piece crlf) (fx+ (fx+ (bytevector-length line) n) 2)))
          (values (list piece) n))))

  ;; serialize-end : Mode -> (values (Listof Segment) Nat)
  ;; The end of a producer's body: chunked, the last chunk and an empty
  ;; trailer section, `0` CRLF CRLF (RFC 9112 §7.1), one shared segment;
  ;; close-delimited, nothing, since the close ends the body.  Any other mode
  ;; is an assertion violation.
  (define (serialize-end mode)
    (case mode
      ((chunked) (values last-chunk (bytevector-length (car last-chunk))))
      ((close-delimited) (values '() 0))
      (else (assertion-violation 'serialize-end "not a mode a producer's body is written in" mode))))

  (define last-chunk (list (string->utf8 "0\r\n\r\n")))

  ;; chunk-size-line : Nat -> Bytevector — `length` in lowercase hex, CRLF.
  (define (chunk-size-line length)
    (let* ((digits (let loop ((n length) (d 1)) (if (fx<? n 16) d (loop (fxdiv n 16) (fx+ d 1)))))
           (out (make-bytevector (fx+ digits 2))))
      (let loop ((at (fx- digits 1)) (n length))
        (bytevector-u8-set! out at (bytevector-u8-ref hex-digits (fxmod n 16)))
        (when (fx>=? n 16) (loop (fx- at 1) (fxdiv n 16))))
      (bytevector-u8-set! out digits 13)
      (bytevector-u8-set! out (fx+ digits 1) 10)
      out))

  (define hex-digits (string->utf8 "0123456789abcdef"))

  ;; size-line : Nat -> Bytevector
  ;; A chunk's size line: one of power-of-two-lines when `n` is a power of
  ;; two, 1 to 2^24, and made for it otherwise (M6.3's review: 16 B a piece).
  (define (size-line n)
    (if (and (fx=? (fxand n (fx- n 1)) 0) (fx<=? n max-shared-size))
        (vector-ref power-of-two-lines (fx- (fxlength n) 1))
        (chunk-size-line n)))

  ;; max-shared-size : Nat — the largest piece whose size line is shared,
  ;; 16 MiB, past which a piece's line costs little beside its bytes.
  (define max-shared-size (expt 2 24))

  ;; power-of-two-lines : (Vectorof Bytevector) — the size lines of 2^0 to
  ;; 2^24, made once, as the status lines are.
  (define power-of-two-lines
    (let ((v (make-vector 25)))
      (let loop ((k 0))
        (when (fx<? k 25)
          (vector-set! v k (chunk-size-line (expt 2 k)))
          (loop (fx+ k 1))))
      v))

  ;; --- the faults ------------------------------------------------------------------

  ;; Bytes = (U Bytevector Span)
  (define (bytes-vector x) (if (span? x) (span-bytevector x) x))
  (define (bytes-start x) (if (span? x) (span-start x) 0))
  (define (bytes-end x) (if (span? x) (span-end x) (bytevector-length x)))
  (define (bytes-length x) (fx- (bytes-end x) (bytes-start x)))

  (define connection-name (string->utf8 "Connection"))
  (define content-length-name (string->utf8 "Content-Length"))
  (define transfer-encoding-name (string->utf8 "Transfer-Encoding"))

  ;; response-fault : Any -> (U #f Symbol)
  ;; #f when `r` is a response the serializer can write safely; otherwise
  ;; the first fault found (decision 0010 item 2):
  ;;   not-a-response        not a response record
  ;;   invalid-status        not an exact integer from 200 to 599: 1xx is
  ;;                         interim and never an answer, and outside 100..599
  ;;                         is no status (RFC 9110 §15)
  ;;   invalid-reason        a reason that is not a bytevector, or holds a
  ;;                         control character other than HTAB (RFC 9112 §4)
  ;;   invalid-headers       not a list of (name . value) pairs of bytes
  ;;   invalid-header-name   a name that is not a token (RFC 9110 §5.1)
  ;;   invalid-header-value  a control character other than HTAB (RFC 9110
  ;;                         §5.5: CR, LF and NUL are "invalid and dangerous")
  ;;   framing-field         a Content-Length or Transfer-Encoding: the
  ;;                         server's to write (item 1)
  ;;   connection-field      a Connection that is not `close` (item 3)
  ;;   invalid-body          neither a bytevector, a producer (a procedure;
  ;;                         decision 0013 item 8) nor #f
  (define (response-fault r)
    (cond ((not (response? r)) 'not-a-response)
          ((not (let ((s (response-status r)))
                  (and (fixnum? s) (fx<=? 200 s 599))))
           'invalid-status)
          ((not (let ((reason (response-reason r)))
                  (or (not reason) (and (bytevector? reason) (field-text? reason)))))
           'invalid-reason)
          ((headers-fault (response-headers r)))
          ((not (let ((body (response-body r))) (or (not body) (bytevector? body) (procedure? body))))
           'invalid-body)
          (else #f)))

  ;; headers-fault : Any -> (U #f Symbol) — the first field's fault, if any.
  (define (headers-fault headers)
    (cond ((not (list? headers)) 'invalid-headers)
          ((not (for-all (lambda (h) (and (pair? h) (bytes? (car h)) (bytes? (cdr h)))) headers))
           'invalid-headers)
          (else
           (let loop ((hs headers))
             (if (null? hs)
                 #f
                 (let ((name (caar hs)) (value (cdar hs)))
                   (cond ((not (token? name)) 'invalid-header-name)
                         ((not (field-text? value)) 'invalid-header-value)
                         ((or (header-name=? name content-length-name)
                              (header-name=? name transfer-encoding-name))
                          'framing-field)
                         ((and (header-name=? name connection-name) (not (close-option? value)))
                          'connection-field)
                         (else (loop (cdr hs))))))))))

  ;; response-closes? : Response -> Boolean
  ;; #t when the handler's response asks to close the connection after it:
  ;; a Connection field whose value is `close` (decision 0010 item 3).
  (define (response-closes? r)
    (exists (lambda (h) (and (header-name=? (car h) connection-name) (close-option? (cdr h))))
            (response-headers r)))

  ;; bytes? : Any -> Boolean
  (define (bytes? x) (or (bytevector? x) (span? x)))

  ;; token? : Bytes -> Boolean — 1*tchar (RFC 9110 §5.6.2).
  (define (token? x)
    (let ((bv (bytes-vector x)) (end (bytes-end x)))
      (and (fx<? (bytes-start x) end)
           (let loop ((i (bytes-start x)))
             (or (fx=? i end)
                 (and (tchar? (bytevector-u8-ref bv i)) (loop (fx+ i 1))))))))

  ;; tchar? : Octet -> Boolean
  ;; "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" /
  ;; "`" / "|" / "~" / DIGIT / ALPHA
  (define (tchar? c)
    (or (fx<=? 97 c 122) (fx<=? 65 c 90) (fx<=? 48 c 57)
        (memv c '(33 35 36 37 38 39 42 43 45 46 94 95 96 124 126))))

  ;; field-text? : Bytes -> Boolean
  ;; No control character but HTAB: VCHAR, obs-text, SP and HTAB only.
  (define (field-text? x)
    (let ((bv (bytes-vector x)) (end (bytes-end x)))
      (let loop ((i (bytes-start x)))
        (or (fx=? i end)
            (let ((c (bytevector-u8-ref bv i)))
              (and (or (fx=? c 9) (and (fx>=? c 32) (not (fx=? c 127))))
                   (loop (fx+ i 1))))))))

  ;; close-option? : Bytes -> Boolean
  ;; The value is the connection option `close`, in any case, with optional
  ;; whitespace around it (RFC 9110 §7.6.1).
  (define (close-option? x)
    (let ((bv (bytes-vector x)))
      (let-values (((start end) (trim-ows bv (bytes-start x) (bytes-end x))))
        (range-ci=? bv start end close-token))))

  (define close-token (string->utf8 "close"))

  ;; --- the Date line ------------------------------------------------------------

  ;; date-line-length : Nat — `Date: `, an IMF-fixdate, CRLF: 6 + 29 + 2.  An
  ;; IMF-fixdate is always 29 characters (RFC 9110 §5.6.7).
  (define date-line-length 37)

  ;; date-line : Nat -> Bytevector
  ;; The Date field line for `seconds` since the epoch, UTC, as an
  ;; IMF-fixdate: `Date: Sun, 06 Nov 1994 08:49:37 GMT` and CRLF.  An instant
  ;; before the epoch or after 9999, whose year is not four digits, is an
  ;; assertion violation.
  (define (date-line seconds)
    (unless (and (integer? seconds) (exact? seconds) (<= 0 seconds 253402300799))
      (assertion-violation 'date-line "not an instant from 1970 to 9999" seconds))
    (let* ((days (div seconds 86400))
           (time (mod seconds 86400))
           (out (make-bytevector date-line-length 32)))
      (let-values (((year month day) (civil-from-days days)))
        (bytevector-copy! date-prefix 0 out 0 6)
        (bytevector-copy! day-names (fx* 3 (fxmod (fx+ days 4) 7)) out 6 3)  ; 1970-01-01 was a Thursday
        (bytevector-u8-set! out 9 44)                                        ; ","
        (put-digits! out 11 2 day)
        (bytevector-copy! month-names (fx* 3 (fx- month 1)) out 14 3)
        (put-digits! out 18 4 year)
        (put-digits! out 23 2 (fxdiv time 3600))
        (bytevector-u8-set! out 25 58)
        (put-digits! out 26 2 (fxmod (fxdiv time 60) 60))
        (bytevector-u8-set! out 28 58)
        (put-digits! out 29 2 (fxmod time 60))
        (bytevector-copy! date-suffix 0 out 32 5)
        out)))

  (define date-prefix (string->utf8 "Date: "))
  (define date-suffix (string->utf8 "GMT\r\n"))
  (define day-names (string->utf8 "SunMonTueWedThuFriSat"))
  (define month-names (string->utf8 "JanFebMarAprMayJunJulAugSepOctNovDec"))

  ;; put-digits! : Bytevector Nat Nat Nat -> Void — `n` in `width` digits,
  ;; zero-padded, at `at`.
  (define (put-digits! out at width n)
    (let loop ((i (fx- width 1)) (n n))
      (when (fx>=? i 0)
        (bytevector-u8-set! out (fx+ at i) (fx+ 48 (fxmod n 10)))
        (loop (fx- i 1) (fxdiv n 10)))))

  ;; civil-from-days : Nat -> (values Nat Nat Nat)
  ;; The proleptic Gregorian year, month and day `days` after 1970-01-01, by
  ;; eras of 400 years, each 146,097 days, counted from 0000-03-01 so that a
  ;; leap day ends its year (H. Hinnant, "chrono-Compatible Low-Level Date
  ;; Algorithms", days_from_civil's inverse).
  (define (civil-from-days days)
    (let* ((z (fx+ days 719468))
           (era (fxdiv z 146097))
           (doe (fx- z (fx* era 146097)))
           (yoe (fxdiv (fx- (fx+ (fx- doe (fxdiv doe 1460)) (fxdiv doe 36524)) (fxdiv doe 146096))
                       365))
           (doy (fx- doe (fx- (fx+ (fx* 365 yoe) (fxdiv yoe 4)) (fxdiv yoe 100))))
           (mp (fxdiv (fx+ (fx* 5 doy) 2) 153))
           (day (fx+ (fx- doy (fxdiv (fx+ (fx* 153 mp) 2) 5)) 1))
           (month (if (fx<? mp 10) (fx+ mp 3) (fx- mp 9)))
           (year (fx+ (fx+ yoe (fx* era 400)) (if (fx<=? month 2) 1 0))))
      (values year month day))))
