#!r6rs
;;; m2.3-target-alloc.sps — what validating the request-target costs, per
;;; target and per request, against the 3,072 B ratchet (decision 0002's second
;;; amendment); which targets each route judges differently; and which of the
;;; strict corpus's targets a validating core would refuse.
;;;
;;; The plan's route (milestone plan §6, M2.3; design §7.5): one uriparse
;;; collector per connection, reset with `uri-collector-reset!`, fed the
;;; target, finished, and judged with `uri-parse-result-validate`.  The other
;;; route measured here judges an origin-form target the way RFC 9112 §3.2.1
;;; writes it, `absolute-path [ "?" query ]`: split at the first "?", and each
;;; part judged by uriparse's `(uri charset)` `validate-component`.  That takes
;;; a whole bytevector, so the route copies the two parts; the row with no
;;; copy is `validate-component` over a standalone bytevector, a stand-in for
;;; a validator that takes a range.
;;;
;;; Method, from m2-event-alloc.sps: 1,000 untimed calls, then 10,000
;;; measured, read as the difference of the CUMULATIVE counter
;;; (sstats-bytes (statistics)), never the live heap.  The whole-cycle rows run
;;; tests/test-connection-allocation.sps's cycle — the CPS workload through
;;; parser, adapter and core with the shell's four events — and validate the
;;; target of the request `call-handler` carries, once per request.
(import (rnrs)
        (uri collect) (uri components) (uri charset)
        (generated httparse-message) (httparse modes) (byte-machine runtime)
        (httparse methods)
        (httparse test corpus-decode) (httparse test corpus-load)
        (trace-lane)
        (http-server connection) (http-server private adapter)
        (http-server request) (http-server response) (http-server limits)
        (http-server span)
        (only (chezscheme) printf statistics sstats-bytes machine-type scheme-version))

(define (b s) (string->utf8 s))
(define warm 1000)
(define reps 10000)
(define gate 3072)
(define hold #f)

;; per-call : (-> Any) -> Nat — bytes one call allocates, after a warm-up.
(define (per-call thunk)
  (let loop ((i 0)) (when (< i warm) (set! hold (thunk)) (loop (+ i 1))))
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i reps) (set! hold (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) reps)))

(define (repeat s n)
  (let loop ((i 0) (acc '())) (if (= i n) (apply string-append acc) (loop (+ i 1) (cons s acc)))))

;; --- the two routes, over a range of a bytevector ----------------------------

(define collector (make-uri-collector 'uri-reference))

;; plan-route : Bytevector Nat Nat -> uri-parse-result
(define (plan-route bv start end)
  (uri-collector-reset! collector)
  (uri-collect-feed! collector bv start end)
  (uri-parse-result-validate (uri-collect-finish! collector)))

;; question-mark : Bytevector Nat Nat -> Nat — the first "?" in [start, end), or end.
(define (question-mark bv start end)
  (let loop ((i start))
    (cond ((fx=? i end) end)
          ((fx=? (bytevector-u8-ref bv i) 63) i)
          (else (loop (fx+ i 1))))))

(define (copy bv start end)
  (let ((out (make-bytevector (fx- end start))))
    (bytevector-copy! bv start out 0 (fx- end start))
    out))

;; charset-route : Bytevector Nat Nat -> (U #f Symbol)
;; RFC 9112 origin-form: the path before the first "?", the query after it.
(define (charset-route bv start end)
  (let ((q (question-mark bv start end)))
    (let-values (((code at) (validate-component 'path (copy bv start q))))
      (or code
          (and (fx<? q end)
               (let-values (((code at) (validate-component 'query (copy bv (fx+ q 1) end))))
                 code))))))

;; --- the whole cycle, from test-connection-allocation.sps ----------------------

(define resp (make-response 200 #f '() #f))

;; connection : Bytevector (U #f (Bytevector Nat Nat -> Any)) -> (-> Any)
;; A keep-alive connection serving `request` once per call; `validate`, when
;; given, judges the target of the request the core hands the handler.
(define (connection request validate)
  (let* ((ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 #f #f default-limits)))
         (p (make-conn-parser ctx))
         (len (bytevector-length request)))
    (lambda ()
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (error 'connection "the core did not pause the parser" (parser-result-status r)))
        (let ((call (assq 'call-handler (conn-context-take-actions! ctx))))
          (when validate
            (let ((t (request-target (cadr call))))
              (set! hold (validate (span-bytevector t) (span-start t) (span-end t))))))
        (conn-context-step! ctx (list 'parser-result 'paused (parser-result-consumed r)
                                      (parser-result-next r) #f #f))
        (conn-context-step! ctx (list 'handler-responded resp))
        (conn-context-step! ctx (list 'write-completed len))
        (parser-resume! p)))))

(define cps (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
(define cps-long
  (b (string-append "GET /" (repeat "a" 499) " HTTP/1.1\r\nHost: x\r\nUser-Agent: "
                    (repeat "s" 500) "\r\nAccept: */*\r\n\r\n")))

;; --- measurements --------------------------------------------------------------

(printf "platform: ~a, ~a\n" (machine-type) (scheme-version))
(let ((before (sstats-bytes (statistics))))
  (let loop ((i 0) (acc '())) (if (< i 10000) (loop (+ i 1) (cons i acc)) (set! hold acc)))
  (printf "calibration: 10000 conses read as ~a bytes (~a per pair)\n"
          (- (sstats-bytes (statistics)) before)
          (div (- (sstats-bytes (statistics)) before) 10000)))

(printf "--- per target, B per validation\n")
(for-each
 (lambda (t)
   (let ((n (bytevector-length t)))
     (printf "~a-byte target: plan's route ~a | charset route (copying) ~a | validate-component alone ~a\n"
             n (per-call (lambda () (plan-route t 0 n)))
             (per-call (lambda () (charset-route t 0 n)))
             (per-call (lambda () (let-values (((code at) (validate-component 'path t))) code))))))
 (list (b "/a") (b "/api/v1/items/12345?fields=name,price&limit=50")
       (b (string-append "/" (repeat "a" 499)))))
(let ((t (b "/a")))
  (printf "the plan's route on /a, cumulatively: reset ~a, + feed ~a, + finish ~a, + validate ~a\n"
          (per-call (lambda () (uri-collector-reset! collector)))
          (per-call (lambda () (uri-collector-reset! collector) (uri-collect-feed! collector t 0 2)))
          (per-call (lambda () (uri-collector-reset! collector) (uri-collect-feed! collector t 0 2)
                      (uri-collect-finish! collector)))
          (per-call (lambda () (plan-route t 0 2)))))
(let ((t (b "example.com:443")))
  (printf "CONNECT example.com:443, the strict authority-form validator (a fresh parse): ~a\n"
          (per-call (lambda () (uri-parse-authority-form-validate t)))))
(let ((cu (make-uri-collector 'uri)) (t (b "http://example.com/p?q=1")))
  (printf "absolute-form http://example.com/p?q=1, a reused 'uri collector: ~a\n"
          (per-call (lambda () (uri-collector-reset! cu) (uri-collect-feed! cu t 0 (bytevector-length t))
                      (uri-parse-result-validate (uri-collect-finish! cu))))))

(printf "--- per request, the whole cycle (parser, adapter, core, shell events)\n")
(define (row label request validate)
  (let ((n (per-call (connection request validate))))
    (printf "~a ~a B/request (~a% of the ~a B ratchet)\n" label n (div (* 100 n) gate) gate)))
(row "cycle, no validation, CPS workload:           " cps #f)
(row "cycle + the plan's route:                     " cps plan-route)
(row "cycle + the charset route (copying):          " cps charset-route)
(row "cycle, no validation, 500-byte target:        " cps-long #f)
(row "cycle + the plan's route, 500-byte target:    " cps-long plan-route)
(row "cycle + the charset route, 500-byte target:   " cps-long charset-route)

(printf "--- where the routes disagree (origin-form is absolute-path [ \"?\" query ], RFC 9112 3.2.1)\n")
(define (plan-verdict t)
  (let ((r (plan-route t 0 (bytevector-length t))))
    (if (uri-parse-ok? r) 'accepted (list (uri-parse-error-code r) (uri-parse-error-offset r)))))
(define (charset-verdict t) (or (charset-route t 0 (bytevector-length t)) 'accepted))
(for-each (lambda (s)
            (printf "~s plan's route ~s, charset route ~s\n" s (plan-verdict (b s)) (charset-verdict (b s))))
          '("//a@b:c/d" "//x/y" "/a#b" "/a?b#c" "/p?q=a|b"))

(printf "--- the strict corpus's targets (every message that reaches on-headers-complete, fed whole)\n")
(define method-names
  (let ((v (make-vector 64 #f)))
    (for-each (lambda (row) (vector-set! v (cdr row) (car row))) httparse-method-numbers)
    v))
;; targets-of : Bytevector -> (Listof (Pair String Bytevector)) — method and target.
(define (targets-of bv)
  (let* ((url '()) (out '())
         (spans '(on-method-data on-url-data on-protocol-data on-version-data
                  on-status-data on-header-field-data on-header-value-data on-body-data
                  on-chunk-extension-name-data on-chunk-extension-value-data))
         (bindings
          (map (lambda (name)
                 (list name
                       (if (memq name spans)
                           (lambda (p c bv from to)
                             (when (eq? name 'on-url-data) (set! url (cons (copy bv from to) url)))
                             callback-continue)
                           (lambda (p c)
                             (when (eq? name 'on-headers-complete)
                               (set! out (cons (cons (vector-ref method-names (parser-field-ref p 'method))
                                                     (apply bytevector-append* (reverse url)))
                                               out))
                               (set! url '()))
                             callback-continue))))
               conn-parser-callbacks))
         (p (make-parser httparse-message-machine bindings #f
                         (list (cons 'type (httparse-message-type-value 'request))))))
    (let loop ((at 0))
      (let ((r (parser-feed! p bv at (bytevector-length bv))))
        (when (eq? (parser-result-status r) 'paused)
          (parser-resume! p)
          (loop (parser-result-next r)))))
    (reverse out)))
(define (bytevector-append* . bvs)
  (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
    (let loop ((bvs bvs) (at 0))
      (if (null? bvs) out
          (begin (bytevector-copy! (car bvs) 0 out at (bytevector-length (car bvs)))
                 (loop (cdr bvs) (+ at (bytevector-length (car bvs)))))))))
(define (has-byte? bv byte)
  (let loop ((i 0)) (and (< i (bytevector-length bv))
                         (or (= (bytevector-u8-ref bv i) byte) (loop (+ i 1))))))
(define messages 0)
(for-each
 (lambda (fixture)
   (for-each
    (lambda (mt)
      (let ((method (car mt)) (t (cdr mt)))
        (set! messages (+ messages 1))
        (cond
         ((string=? method "CONNECT")
          (let ((r (uri-parse-authority-form-validate t)))
            (unless (uri-parse-ok? r)
              (printf "~a CONNECT ~s: the authority-form validator refuses ~s\n"
                      (car fixture) (utf8->string t) (uri-parse-error-code r)))))
         ((equal? t (b "*"))
          (unless (string=? method "OPTIONS")
            (printf "~a ~a *: asterisk-form with a method other than OPTIONS\n" (car fixture) method)))
         (else
          (let ((plan (plan-verdict t)))
            (unless (eq? plan 'accepted)
              (printf "~a ~a ~s: the plan's route refuses ~s\n" (car fixture) method (utf8->string t) plan)))
          (when (has-byte? t 35)
            (printf "~a ~a ~s: a fragment\n" (car fixture) method (utf8->string t)))
          (when (and (not (= (bytevector-u8-ref t 0) 47)) (has-byte? t 64))
            (printf "~a ~a ~s: absolute-form with userinfo\n" (car fixture) method (utf8->string t)))))))
    (targets-of (corpus-decode-input (fixture-input-text (cdr fixture))))))
 strict-request-fixtures)
(printf "~a strict fixtures, ~a messages reach on-headers-complete\n"
        (length strict-request-fixtures) messages)
