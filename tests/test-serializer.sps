#!r6rs
;;; (http-server serializer): what a handler's response may carry, and the
;;; Date line.  M3.1, first step.
;;;
;;; Two tables:
;;;   - the Date line: RFC 9110 §5.6.7's example, and Chez's own UTC calendar
;;;     over four centuries of instants;
;;;   - the faults: what a handler's response may not carry (decision 0010
;;;     item 2), each with its reason.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) make-time time-utc->date
              date-week-day date-day date-month date-year date-hour date-minute date-second)
        (http-server serializer) (http-server response) (http-server span))

(define (b s) (string->utf8 s))

;; bytes->text : Bytevector -> String — one character per byte (Latin-1).
(define (bytes->text bv) (list->string (map integer->char (bytevector->u8-list bv))))

;; RFC 9110 §5.6.7's example, as a Date line.
(define date-text "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n")

(define (response status headers body) (make-response status #f headers body))

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

(run-suite "serializer"
  (lambda ()
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
    (test-eq "no Connection field does not" #f (response-closes? (response 200 '() #f)))))
