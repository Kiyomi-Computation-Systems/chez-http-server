#!r6rs
;;; M4, 2026-09-26: what a handler's view of the request costs, per request.
;;;
;;; The core hands the handler the request it built: the method a symbol,
;;; the target and each header name and value a span of the delivery (design
;;; §7.1).  What handlers see is M4's to settle (ledger, M2.2).  Three views:
;;;   (A) the spans, read through accessors that copy only what the handler
;;;       asks for: here the path and one header's value, as strings;
;;;   (B) every request copied to strings before the handler runs: the target,
;;;       and each header's name, lower-cased, and value;
;;;   (C) the spans alone: the handler copies with span->bytevector.
;;; Strings are made byte for byte (Latin-1) straight from the span, with no
;;; bytevector between, which is the cheapest a copy can be.  Each figure is
;;; averaged over 10,000 calls after 1,000, and adds to what the request
;;; already costs parser, adapter and core (1,840 B for curl's GET at the
;;; M3 exit).
;;;
;;; Run on the project's library path (the ledger's M3 entry gives it).
(import (rnrs) (rnrs mutable-strings)
        (only (chezscheme) statistics sstats-bytes)
        (byte-machine runtime)
        (http-server connection) (http-server private adapter)
        (http-server request) (http-server span) (http-server headers)
        (http-server limits))

(define (b s) (string->utf8 s))
(define hold #f)

;; bytes-per-call : (-> Any) -> Nat — after 1,000 calls, averaged over 10,000.
(define (bytes-per-call thunk)
  (let loop ((i 0)) (when (< i 1000) (set! hold (thunk)) (loop (+ i 1))))
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i 10000) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) 10000)))

;; request-of : Bytevector -> Request — the request the core hands the
;; handler for `bytes`, fed whole to a fresh connection.
(define (request-of bytes)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (append queued actions)))))
         (p (make-conn-parser ctx)))
    (conn-context-step! ctx (list 'bytes-arrived bytes 0 (bytevector-length bytes)))
    (parser-feed! p bytes 0 (bytevector-length bytes))
    (let ((call (assq 'call-handler queued)))
      (unless call (assertion-violation 'request-of "the core called no handler" queued))
      (cadr call))))

;; latin-1 : Bytevector Nat Nat Boolean -> String — bv[from, to), a
;; character per byte, lower-cased if asked.
(define (latin-1 bv from to lower?)
  (let ((s (make-string (- to from))))
    (let loop ((i from))
      (when (< i to)
        (let ((c (bytevector-u8-ref bv i)))
          (string-set! s (- i from)
                       (integer->char (if (and lower? (<= 65 c 90)) (+ c 32) c))))
        (loop (+ i 1))))
    s))

(define (span->string sp lower?) (latin-1 (span-bytevector sp) (span-start sp) (span-end sp) lower?))

;; (A) the path, up to any `?`, and one header's value.
(define (path-of req)
  (let* ((t (request-target req)) (bv (span-bytevector t)) (end (span-end t)))
    (let scan ((i (span-start t)))
      (if (or (= i end) (= (bytevector-u8-ref bv i) 63))
          (latin-1 bv (span-start t) i #f)
          (scan (+ i 1))))))
(define user-agent (b "user-agent"))
(define (view-a req)
  (cons (path-of req)
        (let ((v (headers-ref (request-headers req) user-agent)))
          (and v (span->string v #f)))))

;; (B) everything, before the handler runs.
(define (view-b req)
  (list (request-method req)
        (span->string (request-target req) #f)
        (map (lambda (h) (cons (span->string (car h) #t) (span->string (cdr h) #f)))
             (request-headers req))))

;; (C) nothing.
(define (view-c req) req)

(define requests
  (list
   (list "curl's GET, 3 fields         "
         (b "GET / HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n\r\n"))
   (list "a JSON POST, 5 fields        "
         (b (string-append "POST /api HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n"
                           "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}")))
   (list "a browser's GET, 11 fields   "
         (b (string-append "GET /index.html HTTP/1.1\r\nHost: localhost:8080\r\nConnection: keep-alive\r\n"
                           "sec-ch-ua: \"Chromium\";v=\"128\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"macOS\"\r\n"
                           "Upgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh)\r\n"
                           "Accept: text/html,application/xhtml+xml\r\nSec-Fetch-Site: none\r\n"
                           "Accept-Encoding: gzip, deflate, br\r\nAccept-Language: en-US,en;q=0.9\r\n\r\n")))))

(define (show . xs) (for-each display xs) (newline))

(show "--- bytes added per request, by view: (A) path and User-Agent on demand, (B) all copied, (C) spans")
(for-each
 (lambda (row)
   (let ((req (request-of (cadr row))))
     (show (car row) "(A) " (bytes-per-call (lambda () (view-a req)))
           "   (B) " (bytes-per-call (lambda () (view-b req)))
           "   (C) " (bytes-per-call (lambda () (view-c req))))))
 requests)
