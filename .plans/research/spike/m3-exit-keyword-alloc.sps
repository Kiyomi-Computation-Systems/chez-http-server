#!r6rs
;;; The M3 exit, 2026-09-26: what the fields llhttp reads by name cost in
;;; allocation.  byte-machine's `byte-machine-keyword-step/v1` (runtime.sls,
;;; v0.6.0) copies the prefix it has matched on every byte, so a field whose
;;; name, or part of it, is one of the parser's keywords costs more than an
;;; ordinary one, and the cost grows with the square of the match.
;;;
;;; (A) the parser alone, with silent bindings as in chez-httparse's allocation
;;;     lane: the allocation gate's GET, and the same GET with one more field;
;;; (B) the growth: one 17-byte field name whose first k bytes are
;;;     "Transfer-Encoding" and the rest 'x';
;;; (C) the worst case: 97 fields with a 17-byte name, ordinary or a near miss;
;;; (D) the server: parser, adapter and core answering an empty 200, as
;;;     tests/test-connection-allocation.sps runs the gate, over four requests
;;;     a server meets.
;;;
;;; Run on the project's library path (the ledger's M3 entry gives it).  Put a
;;; patched byte-machine's `src` first on it to price a fix.
;;;
;;; Filed as byte-machine #139, and fixed in v0.6.1: the pin moved to it through
;;; chez-httparse v0.4.3 and uriparse v0.6.1.  out/m3-exit-keyword-alloc.run{1,2}
;;; are at the old pin (byte-machine v0.6.0), and .v043.run{1,2} at the new one.
;;; The M3 exit puts (B)'s shape into tests/test-connection-allocation.sps, and
;;; gates (D)'s JSON POST and ab -k's GET there; curl's GET and the browser's
;;; are printed.
(import (rnrs)
        (only (chezscheme) statistics sstats-bytes)
        (generated httparse-message) (httparse modes) (byte-machine runtime)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits))

(define (b s) (string->utf8 s))
(define hold #f)

;; bytes-per-call : (-> Any) -> Nat — after 1,000 calls, averaged over 10,000.
(define (bytes-per-call thunk)
  (let loop ((i 0)) (when (< i 1000) (set! hold (thunk)) (loop (+ i 1))))
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i 10000) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) 10000)))

(define (show . xs) (for-each display xs) (newline))

;; --- the parser alone ---------------------------------------------------------

(define span-callbacks
  '(on-method-data on-url-data on-protocol-data on-version-data on-status-data
    on-header-field-data on-header-value-data on-body-data
    on-chunk-extension-name-data on-chunk-extension-value-data))
(define all-callbacks
  '(on-reset on-message-begin on-method-data on-method-complete on-url-data
    on-url-complete on-protocol-data on-protocol-complete on-version-data
    on-version-complete on-status-data on-status-complete on-header-field-data
    on-header-field-complete on-header-value-data on-header-value-complete
    on-headers-complete on-body-data on-chunk-header on-chunk-extension-name-data
    on-chunk-extension-name-complete on-chunk-extension-value-data
    on-chunk-extension-value-complete on-chunk-complete on-message-complete))
(define silent
  (map (lambda (name)
         (list name (if (memq name span-callbacks)
                        (lambda (p c bv f t) callback-continue)
                        (lambda (p c) callback-continue))))
       all-callbacks))
(define inits (list (cons 'type (httparse-message-type-value 'request))))

;; parser-only : Bytevector -> Nat — one keep-alive parser fed `request` whole.
(define (parser-only request)
  (let ((p (make-parser httparse-message-machine silent #f inits))
        (len (bytevector-length request)))
    (bytes-per-call
     (lambda ()
       (let ((r (parser-feed! p request 0 len)))
         (unless (eq? (parser-result-status r) 'need-input)
           (assertion-violation 'parser-only "not one whole message" (parser-result-status r))))))))

(define (with-field field)
  (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n" field
                    "User-Agent: spike\r\nAccept: */*\r\n\r\n")))

(show "--- (A) the parser alone, per request")
(define base (parser-only (with-field "")))
(show "the gate's GET (Host, User-Agent, Accept)   " base " B")
(for-each
 (lambda (row)
   (show (car row) "+" (- (parser-only (cadr row)) base) " B"))
 (list (list "+ an ordinary field, Xonnection           " (with-field "Xonnection: keep-alive\r\n"))
       (list "+ Connection: keep-alive                 " (with-field "Connection: keep-alive\r\n"))
       (list "+ Connection: foo                        " (with-field "Connection: foo\r\n"))
       (list "+ Content-Length: 0                      " (with-field "Content-Length: 0\r\n"))
       (list "+ Content-Type: text/plain               " (with-field "Content-Type: text/plain\r\n"))
       (list "+ Upgrade: foo                           " (with-field "Upgrade: foo\r\n"))
       (list "+ Transfer-Encoding: chunked, as a POST  "
             (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
                               "User-Agent: spike\r\nAccept: */*\r\n\r\n0\r\n\r\n")))))

(show "--- (B) a 17-byte name matching the first k bytes of Transfer-Encoding")
(for-each
 (lambda (k)
   (let ((name (string-append (substring "Transfer-Encoding" 0 k) (make-string (- 17 k) #\x))))
     (show "k=" k "  " name "  +" (- (parser-only (with-field (string-append name ": a\r\n"))) base) " B")))
 '(0 1 2 4 8 12 16))

(show "--- (C) 97 fields with a 17-byte name, in one request")
(define (fields-named name)
  (let loop ((i 0) (acc ""))
    (if (= i 97) acc (loop (+ i 1) (string-append acc name ": a\r\n")))))
(for-each
 (lambda (name)
   (let ((r (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n" (fields-named name) "\r\n"))))
     (show name ", a " (bytevector-length r) "-byte request: " (parser-only r) " B")))
 '("xxxxxxxxxxxxxxxxx" "Transfer-Encodinx"))

;; --- the server -----------------------------------------------------------------

;; served : Bytevector -> Nat — a keep-alive connection answering an empty 200,
;; driven as the allocation suite drives it, its queue of actions included.
(define (served request)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (cons actions queued)))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request))
         (resp (make-response 200 #f '() #f)))
    (bytes-per-call
     (lambda ()
       (conn-context-step! ctx (list 'bytes-arrived request 0 len))
       (let ((r (parser-feed! p request 0 len)))
         (unless (eq? (parser-result-status r) 'paused)
           (assertion-violation 'served "the core did not pause the parser" (parser-result-status r)))
         (set! queued '())
         (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                       (parser-result-next r) #f #f))
         (let ((w (assq 'write (conn-context-step! ctx (list 'handler-responded resp)))))
           (conn-context-step! ctx (list 'write-completed (caddr w))))
         (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
           (assertion-violation 'served "the connection did not return to idle"
                                (conn-phase (conn-context-state ctx))))
         (parser-resume! p))))))

(show "--- (D) the server, per request, answering an empty 200")
(for-each
 (lambda (row) (show (car row) (served (b (cadr row))) " B"))
 (list
  (list "curl's GET, the gate's shape                       "
        "GET / HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n\r\n")
  (list "a browser-like GET, 11 fields, Connection          "
        (string-append "GET /index.html HTTP/1.1\r\nHost: localhost:8080\r\nConnection: keep-alive\r\n"
                       "sec-ch-ua: \"Chromium\";v=\"128\"\r\nsec-ch-ua-mobile: ?0\r\nsec-ch-ua-platform: \"macOS\"\r\n"
                       "Upgrade-Insecure-Requests: 1\r\nUser-Agent: Mozilla/5.0 (Macintosh)\r\n"
                       "Accept: text/html,application/xhtml+xml\r\nSec-Fetch-Site: none\r\n"
                       "Accept-Encoding: gzip, deflate, br\r\nAccept-Language: en-US,en;q=0.9\r\n\r\n"))
  (list "a JSON POST, Content-Type and Content-Length        "
        (string-append "POST /api HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n"
                       "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}"))
  (list "ab -k: HTTP/1.0, Connection: Keep-Alive            "
        "GET / HTTP/1.0\r\nConnection: Keep-Alive\r\nHost: localhost:8080\r\nUser-Agent: ApacheBench/2.3\r\nAccept: */*\r\n\r\n")))
