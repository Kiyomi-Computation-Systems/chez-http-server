#!r6rs
;;; The guards' hoist, 2026-10-05: what the connection core and the parser
;;; allocate for the GET oha 1.16.0 sends, its 124 bytes as captured, served
;;; as decision 0002's gate serves a request (tests/test-connection-allocation.sps,
;;; its `connection`), answered "ok": the gated share of what the whole
;;; server allocates for it (hoist-request-alloc.sps).  Read off
;;; `bytes-allocated` with the collector held off, three windows of 10,000.
;;;
;;;   chez --program hoist-core-share.sps    (on the project's library path)
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) statistics sstats-bytes bytes-allocated collect-request-handler)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits) (http-server body)
        (uri collect)
        (only (generated httparse-message) httparse-message-machine)
        (only (httparse modes) httparse-message-type-value httparse-lenient-flags-value)
        (byte-machine runtime))

(define (b s) (string->utf8 s))

(define resp (make-response 200 #f '() #f))

;; with-body : Nat -> Response — a 200 with an `n`-byte body.
(define (with-body n) (make-response 200 #f '() (make-bytevector n 97)))

;; connection : Bytevector Response -> (-> Void)
;; A keep-alive connection that serves `request` once per call, answering
;; `response`.
(define (connection request response)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (cons actions queued)))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (assertion-violation 'connection "the core did not pause the parser"
                               (parser-result-status r)))
        (set! queued '())
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-stream-offset r)
                                      (parser-result-next r) #f #f))
        (let ((w (assq 'write (conn-context-step! ctx (list 'handler-responded response)))))
          (conn-context-step! ctx (list 'write-completed (caddr w))))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'connection "the connection did not return to idle"
                               (conn-phase (conn-context-state ctx))))
        (parser-resume! p)))))


(define request (string->utf8 "GET / HTTP/1.1\r\naccept: */*\r\naccept-encoding: gzip, compress, deflate, br\r\nuser-agent: oha/1.16.0\r\nhost: 127.0.0.1:18777\r\n\r\n"))
(define ok (make-response 200 #f '() (string->utf8 "ok")))
(define serve-once (connection request ok))
(let warm ((i 0)) (when (< i 2000) (serve-once) (warm (+ i 1))))
(collect-request-handler (lambda () #f))
(define (per n) (let ((a (bytes-allocated))) (let loop ((i 0)) (when (< i n) (serve-once) (loop (+ i 1))))
  (/ (- (bytes-allocated) a) n)))
(for-each (lambda (k) (display "core + parser, oha's GET, 10,000 requests: ") (display (inexact (per 10000))) (display " B a request\n")) '(1 2 3))
