#!r6rs
;;; (http-server serializer) — a response, as the bytes the server writes (M3;
;;; design §3.1, §7.3; decision 0010).
;;;
;;; M3.1 lands in two steps.  This one holds what a handler's response may
;;; carry and the Date line; the second adds `serialize-response`, which
;;; turns a response and the connection's framing decision into the segments
;;; of one `uv-write*!`.
;;;
;;; WHAT CANNOT BE WRITTEN SAFELY is a fault (decision 0010 item 2).
;;; `response-fault` names it, and the core answers 500 instead.  The value
;;; bytes refused are the ones llhttp's strict parser refuses in a field
;;; value: every control character but HTAB.  A handler's `Connection` field
;;; may only be `close` (item 3), which `response-closes?` reads.
;;;
;;; THE DATE LINE (decision 0010 item 4).  The core reads no clock (decision
;;; 0002 item 1), so the shell fills each response's Date: `date-line`
;;; formats the line from whole seconds since the epoch, always
;;; `date-line-length` bytes, and the shell keeps it and re-formats it when
;;; the second changes.
;;;
;;; PURE: imports only (rnrs) and this project's pure libraries.
(library (http-server serializer)
  (export response-fault response-closes? date-line date-line-length)
  (import (rnrs) (http-server response) (http-server span)
          (only (http-server headers) header-name=?))

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
  ;;   invalid-body          neither a bytevector nor #f
  (define (response-fault r)
    (cond ((not (response? r)) 'not-a-response)
          ((not (let ((s (response-status r)))
                  (and (fixnum? s) (fx<=? 200 s 599))))
           'invalid-status)
          ((not (let ((reason (response-reason r)))
                  (or (not reason) (and (bytevector? reason) (field-text? reason)))))
           'invalid-reason)
          ((headers-fault (response-headers r)))
          ((not (let ((body (response-body r))) (or (not body) (bytevector? body))))
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
    (let* ((bv (bytes-vector x))
           (start (let loop ((i (bytes-start x)))
                    (if (and (fx<? i (bytes-end x)) (ows? (bytevector-u8-ref bv i))) (loop (fx+ i 1)) i)))
           (end (let loop ((i (bytes-end x)))
                  (if (and (fx>? i start) (ows? (bytevector-u8-ref bv (fx- i 1)))) (loop (fx- i 1)) i))))
      (and (fx=? (fx- end start) 5)
           (header-name=? (make-span bv start end) close-token))))

  (define (ows? c) (or (fx=? c 32) (fx=? c 9)))
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
