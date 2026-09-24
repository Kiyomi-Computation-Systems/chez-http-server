#!r6rs
;;; (http-server connection): what a request costs in allocation.  M2.2, M2.3.
;;;
;;; Decision 0002's second amendment: the 3 KiB gate is a regression ratchet
;;; counted as a total (parser, adapter and core), and shapes are the real
;;; guard.  One keep-alive connection runs whole requests the way a shell
;;; will: `bytes-arrived`, the feed through the adapter's bindings (the core
;;; pauses the parser at the message's end), the queued actions taken, then
;;; `parser-result`, `handler-responded`, `write-completed`, and the resume.
;;; The workload is the CPS spike's (research/spike/cps-core.sps §4): a
;;; keep-alive GET with three headers, fed whole.
;;;
;;; The checks:
;;;   - the total per request is within the 3,072 B ratchet;
;;;   - it does not grow with the length of a header value: the head is kept
;;;     as spans, never copied (the amendment's second shape);
;;;   - nor with the length of the target, but for one copy: an origin-form
;;;     target's path is copied to be judged, because uriparse's validator
;;;     takes a whole bytevector.  That copy is carried until it takes a range
;;;     (uriparse #21), and this check then falls to "costs what a short one
;;;     does";
;;;   - an absolute-form target costs one parse by a reused uriparse collector
;;;     in place of that copy: the collector is the connection's, made once,
;;;     never one per request (M2.3, design §7.5);
;;;   - the cost stays constant from request to request: later requests on
;;;     the connection cost what earlier ones did (the third shape).
;;; The first shape, per callback, is test-connection-entry.sps's.
;;;
;;; Oracles: the 3,072 B ratchet and the shapes, from 0002's second amendment;
;;; Chez's cumulative allocation counter `sstats-bytes`, calibrated below and
;;; never the live heap; what a bytevector costs, and what uriparse's own
;;; reused collector costs on the same target, both read by that counter.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) statistics sstats-bytes)
        (http-server connection) (http-server private adapter)
        (http-server response) (http-server limits)
        (uri collect)
        (byte-machine runtime))

(define (b s) (string->utf8 s))

(define gate 3072)
(define warm 1000)
(define reps 10000)

(define resp (make-response 200 #f '() #f))

;; connection : Bytevector -> (-> Void)
;; A keep-alive connection that serves `request` once per call.
(define (connection request)
  (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 #f #f default-limits)))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (assertion-violation 'connection "the core did not pause the parser"
                               (parser-result-status r)))
        (conn-context-take-actions! ctx)
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                      (parser-result-next r) #f #f))
        (conn-context-step! ctx (list 'handler-responded resp))
        (conn-context-step! ctx (list 'write-completed len))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'connection "the connection did not return to idle"
                               (conn-phase (conn-context-state ctx))))
        (parser-resume! p)))))

;; What a thunk last returned, so an allocation it makes is never dead code.
(define hold #f)

;; bytes-per-call : (-> Any) Nat -> Nat
;; Bytes one call of `thunk` allocates, averaged over `n` calls.
(define (bytes-per-call thunk n)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i n) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) n)))

;; per-request : Bytevector -> Nat — after a warm-up, over `reps` requests.
(define (per-request request)
  (let ((serve (connection request)))
    (bytes-per-call serve warm)
    (bytes-per-call serve reps)))

;; warmed : (-> Any) -> Nat — the same, for any thunk.
(define (warmed thunk)
  (bytes-per-call thunk warm)
  (bytes-per-call thunk reps))

(define (repeat s n)
  (let loop ((i 0) (acc '())) (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

(define cps (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
;; The same request with a 500-byte User-Agent; with a 500-byte target; and
;; with its target in absolute-form.
(define cps-long-header
  (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: " (repeat "s" 500)
                    "\r\nAccept: */*\r\n\r\n")))
(define cps-long-target
  (b (string-append "GET /" (repeat "a" 499)
                    " HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n")))
(define cps-absolute
  (b "GET http://x/a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; measure : (-> Nat) -> (U Nat 'refused)
;; A reading, or 'refused if a request on the connection was not served, so
;; that failure is a check rather than the suite ending early.
(define (measure thunk)
  (guard (e ((assertion-violation? e)
             (diag (string-append "connection-allocation: a request was not served: "
                                  (if (message-condition? e) (condition-message e) "?")))
             'refused))
    (thunk)))

(run-suite "connection-allocation"
  (lambda ()
    ;; Calibration: an instrument that always read zero would pass the shapes.
    (let* ((before (sstats-bytes (statistics)))
           (junk (make-bytevector 100000 0))
           (after (sstats-bytes (statistics))))
      (test-eq "the counter sees a 100000-byte bytevector" 'seen
               (if (and (>= (- after before) 100000) (= (bytevector-length junk) 100000))
                   'seen
                   'missed)))
    (test-eqv "an empty loop allocates nothing per iteration"
              0 (bytes-per-call (lambda () #f) reps))

    (let ((short (measure (lambda () (per-request cps))))
          (long-header (measure (lambda () (per-request cps-long-header))))
          (long-target (measure (lambda () (per-request cps-long-target))))
          (absolute (measure (lambda () (per-request cps-absolute)))))
      (test-eq "every request on the four connections is served" 'served
               (if (for-all number? (list short long-header long-target absolute)) 'served 'refused))
      (when (for-all number? (list short long-header long-target absolute))
        (diag (string-append "connection-allocation: the CPS workload "
                             (number->string short) " B/request (ratchet "
                             (number->string gate) " B); with a 500-byte header "
                             (number->string long-header) ", with a 500-byte target "
                             (number->string long-target) ", in absolute-form "
                             (number->string absolute)))
        (test-eq "a keep-alive request costs something" 'allocates
                 (if (> short 0) 'allocates 'free))
        (test-eq "and no more than the 3,072 B ratchet" 'within
                 (if (<= short gate) 'within 'over))
        (test-eqv "a 500-byte header value costs what a short one does" short long-header)
        ;; The origin-form path is copied once to be judged (uriparse #21):
        ;; "/a" and "/aaa..." are 2 and 500 bytes.
        (let ((copies (- (warmed (lambda () (make-bytevector 500)))
                         (warmed (lambda () (make-bytevector 2))))))
          (test-eqv "a 500-byte target costs what a short one does, but for its path's copy"
                    (+ short copies) long-target))
        ;; In place of "/a"'s copy, an absolute-form target costs one parse by
        ;; a reused collector: uriparse's own, measured on the same target.
        (let* ((c (make-uri-collector 'uri))
               (t (b "http://x/a"))
               (parse (warmed (lambda ()
                                (uri-collector-reset! c)
                                (uri-collect-feed! c t 0 (bytevector-length t))
                                (uri-parse-result-validate (uri-collect-finish! c)))))
               (copy (warmed (lambda () (make-bytevector 2)))))
          (test-eqv "an absolute-form target costs one reused collector's parse"
                    (+ (- short copy) parse) absolute))))

    ;; The same connection, twice as long: the requests after the first
    ;; 11,000 cost what those did.
    (let* ((serve (connection cps))
           (first (measure (lambda () (bytes-per-call serve warm) (bytes-per-call serve reps))))
           (later (measure (lambda () (bytes-per-call serve reps)))))
      (test-eq "every request on the long connection is served" 'served
               (if (and (number? first) (number? later)) 'served 'refused))
      (when (and (number? first) (number? later))
        (test-eqv "request 20,000 costs what request 1,000 did" first later)))))
