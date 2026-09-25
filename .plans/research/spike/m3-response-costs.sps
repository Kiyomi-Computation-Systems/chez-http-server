#!r6rs
;;; M3, 2026-09-25: what the response path would cost, measured before M3
;;; builds it and before the owner chose who writes the Date (decision 0010).
;;; A prior, not an oracle: every number here is re-measured on the tree once
;;; M3 lands.
;;;
;;; (A) the Date header (RFC 9110 §6.6.1), three ways: formatted per response
;;;     through strings; formatted per response straight into bytes; cached
;;;     once a second by the shell, so a response costs nothing for it.
;;; (B) a prototype serializer head: status line (shared constant) plus one
;;;     header block, and the segment list and write action around it.
;;; (C) the scan that refuses a header name that is not a token, or a value
;;;     holding CR, LF or NUL (RFC 9110 §5.1, §5.5).
;;; (D) the allocation suite's keep-alive workload with (B) in the loop, as
;;;     the core would run it, against the 3,072 B gate.  Its actions go
;;;     nowhere, where the suite's own loop keeps them, so (D0) reads a
;;;     little under the suite's 2,512 B.
;;;
;;; Run on the project's library path (the ledger's M3 entry gives it).
(import (rnrs)
        (only (chezscheme) statistics sstats-bytes current-date current-time
              date-week-day date-day date-month date-year date-hour date-minute date-second
              time-second time-nanosecond)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits)
        (byte-machine runtime))

(define (b s) (string->utf8 s))
(define hold #f)

(define (bytes-per-call thunk n)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i n) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) n)))

(define (ns-per-call thunk n)
  (let ((t0 (current-time 'time-monotonic)))
    (let loop ((i 0)) (when (< i n) (set! hold (thunk)) (loop (+ i 1))))
    (let* ((t1 (current-time 'time-monotonic))
           (ns (+ (* (- (time-second t1) (time-second t0)) 1000000000)
                  (- (time-nanosecond t1) (time-nanosecond t0)))))
      (/ (round (* 10 (/ ns n))) 10.0))))

(define (warmed-bytes thunk) (bytes-per-call thunk 1000) (bytes-per-call thunk 100000))
(define (warmed-ns thunk) (ns-per-call thunk 1000) (ns-per-call thunk 1000000))

(define (show . xs)
  (for-each (lambda (x) (display x)) xs)
  (newline))

;; --- (A) the Date header -------------------------------------------------------

(define day-names '#("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))
(define month-names '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (two n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

;; A1: through strings, the obvious way.
(define (date-line/strings)
  (let ((d (current-date 0)))
    (string->utf8
     (string-append "Date: " (vector-ref day-names (date-week-day d)) ", "
                    (two (date-day d)) " " (vector-ref month-names (- (date-month d) 1)) " "
                    (number->string (date-year d)) " "
                    (two (date-hour d)) ":" (two (date-minute d)) ":" (two (date-second d))
                    " GMT\r\n"))))

;; A2: straight into one 37-byte bytevector.
(define day-bytes (vector-map b day-names))
(define month-bytes (vector-map b month-names))
(define (put-2! bv at n)
  (bytevector-u8-set! bv at (+ 48 (div n 10)))
  (bytevector-u8-set! bv (+ at 1) (+ 48 (mod n 10))))
(define (date-line/bytes)
  (let ((d (current-date 0)) (bv (make-bytevector 37 32)))
    (bytevector-copy! (b "Date: ") 0 bv 0 6)
    (bytevector-copy! (vector-ref day-bytes (date-week-day d)) 0 bv 6 3)
    (bytevector-u8-set! bv 9 44)
    (put-2! bv 11 (date-day d))
    (bytevector-copy! (vector-ref month-bytes (- (date-month d) 1)) 0 bv 14 3)
    (let ((y (date-year d)))
      (put-2! bv 18 (div y 100)) (put-2! bv 20 (mod y 100)))
    (put-2! bv 23 (date-hour d)) (bytevector-u8-set! bv 25 58)
    (put-2! bv 26 (date-minute d)) (bytevector-u8-set! bv 28 58)
    (put-2! bv 29 (date-second d))
    (bytevector-copy! (b "GMT\r\n") 0 bv 32 5)
    bv))

;; A3: the shell's cache, refreshed once a second; a response only reads it.
(define cached (date-line/bytes))
(define (date-line/cached) cached)

;; --- (B) a prototype serializer head ---------------------------------------------

(define status-200 (b "HTTP/1.1 200 OK\r\n"))

(define (decimal-length n) (if (< n 10) 1 (+ 1 (decimal-length (div n 10)))))
(define (put-decimal! bv end n)          ; digits of n ending just before `end`
  (let loop ((at (- end 1)) (n n))
    (bytevector-u8-set! bv at (+ 48 (mod n 10)))
    (when (>= n 10) (loop (- at 1) (div n 10)))))

(define cl-name (b "Content-Length: "))
(define close-line (b "Connection: close\r\n"))

;; head-block : Headers Nat Boolean -> Bytevector
;; The handler's headers, Content-Length, Connection: close if closing, CRLF.
(define (head-block headers body-len close?)
  (let* ((hlen (fold-left (lambda (acc h) (+ acc (bytevector-length (car h)) 2
                                             (bytevector-length (cdr h)) 2))
                          0 headers))
         (digits (decimal-length body-len))
         (total (+ hlen 16 digits 2 (if close? 19 0) 2))
         (bv (make-bytevector total)))
    (let loop ((hs headers) (at 0))
      (if (pair? hs)
          (let* ((name (caar hs)) (value (cdar hs))
                 (nl (bytevector-length name)) (vl (bytevector-length value)))
            (bytevector-copy! name 0 bv at nl)
            (bytevector-u8-set! bv (+ at nl) 58)
            (bytevector-u8-set! bv (+ at nl 1) 32)
            (bytevector-copy! value 0 bv (+ at nl 2) vl)
            (bytevector-u8-set! bv (+ at nl 2 vl) 13)
            (bytevector-u8-set! bv (+ at nl 3 vl) 10)
            (loop (cdr hs) (+ at nl vl 4)))
          (let ((at (begin (bytevector-copy! cl-name 0 bv at 16) (+ at 16))))
            (put-decimal! bv (+ at digits) body-len)
            (let ((at (+ at digits)))
              (bytevector-u8-set! bv at 13) (bytevector-u8-set! bv (+ at 1) 10)
              (let ((at (+ at 2)))
                (when close? (bytevector-copy! close-line 0 bv at 19))
                (let ((at (if close? (+ at 19) at)))
                  (bytevector-u8-set! bv at 13) (bytevector-u8-set! bv (+ at 1) 10)))))))
    bv))

;; serialize : Response -> Action — the write the core would emit.
(define (serialize r)
  (let* ((body (response-body r))
         (len (if body (bytevector-length body) 0))
         (block (head-block (response-headers r) len #f))
         (segs (if body (list status-200 block body) (list status-200 block))))
    (list 'write segs (+ (bytevector-length status-200) (bytevector-length block) len))))

(define empty-200 (make-response 200 #f '() #f))
(define three-headers
  (list (cons (b "Content-Type") (b "text/plain; charset=utf-8"))
        (cons (b "Cache-Control") (b "no-store"))
        (cons (b "ETag") (b "\"abc123\""))))
(define small-200 (make-response 200 #f three-headers (b "hello, world\n")))

;; --- (C) the header scan --------------------------------------------------------

(define (tchar? c)
  (or (and (>= c 97) (<= c 122)) (and (>= c 65) (<= c 90)) (and (>= c 48) (<= c 57))
      (memv c '(33 35 36 37 38 39 42 43 45 46 94 95 96 124 126))))
(define (token? bv)
  (let ((n (bytevector-length bv)))
    (and (> n 0) (let loop ((i 0)) (or (= i n) (and (tchar? (bytevector-u8-ref bv i)) (loop (+ i 1))))))))
(define (clean-value? bv)
  (let ((n (bytevector-length bv)))
    (let loop ((i 0))
      (or (= i n)
          (let ((c (bytevector-u8-ref bv i)))
            (and (not (= c 0)) (not (= c 10)) (not (= c 13)) (loop (+ i 1))))))))
(define (headers-ok? hs)
  (for-all (lambda (h) (and (token? (car h)) (clean-value? (cdr h)))) hs))

;; --- (D) the allocation suite's workload, with the prototype in the loop -----------

(define cps (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))

(define (connection request response serialize?)
  (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 #f #f default-limits)
                                 (lambda (actions) #f)))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                      (parser-result-next r) #f #f))
        (conn-context-step! ctx (list 'handler-responded response))
        (when serialize? (set! hold (serialize response)))
        (conn-context-step! ctx (list 'write-completed len))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'connection "not idle" (conn-phase (conn-context-state ctx))))
        (parser-resume! p)))))

(define (per-request request response serialize?)
  (let ((serve (connection request response serialize?)))
    (bytes-per-call serve 1000)
    (bytes-per-call serve 10000)))

(show "--- (A) the Date header: bytes and ns per response")
(show "A1 per response, through strings  " (warmed-bytes date-line/strings) " B  "
      (warmed-ns date-line/strings) " ns")
(show "A2 per response, into bytes       " (warmed-bytes date-line/bytes) " B  "
      (warmed-ns date-line/bytes) " ns")
(show "A3 cached by the shell            " (warmed-bytes date-line/cached) " B  "
      (warmed-ns date-line/cached) " ns")
(show "A2's line: " (utf8->string (date-line/bytes)))
(show "A1 and A2 agree: " (equal? (date-line/strings) (date-line/bytes)))
(show "--- (B) a prototype head: bytes per response, with its segments and write action")
(show "B1 200, no headers, no body       " (warmed-bytes (lambda () (serialize empty-200))) " B")
(show "B2 200, three headers, 13 B body  " (warmed-bytes (lambda () (serialize small-200))) " B")
(show "B2's wire: " (let ((a (serialize small-200)))
                      (apply string-append (map utf8->string (cadr a)))))
(show "--- (C) the header scan: bytes and ns per response")
(show "C  three headers                  " (warmed-bytes (lambda () (headers-ok? three-headers))) " B  "
      (warmed-ns (lambda () (headers-ok? three-headers))) " ns")
(show "--- (D) the allocation suite's workload (M2's gate: 3,072 B per request)")
(show "D0 today, no serializer           " (per-request cps empty-200 #f) " B/request")
(show "D1 with B1 in the loop            " (per-request cps empty-200 #t) " B/request")
(show "D2 with B2 in the loop            " (per-request cps small-200 #t) " B/request")
