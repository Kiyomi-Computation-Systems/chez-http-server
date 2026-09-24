#!r6rs
;;; m2-event-alloc.sps — what M2.1's tagged-list parser events cost per request,
;;; against the 3 KiB gate (decision 0002, consequences; design §7.5).
;;;
;;; M2.1 (85e7d81) hands every parser callback to `conn-step` as a fresh tagged
;;; list: (parser-event name) for an event callback, (parser-event name bv from
;;; to) for a span.  This measures what those lists cost on the CPS spike's
;;; workload, what M2.1's whole `conn-step` path costs with them and without
;;; them, and two alternative event shapes, each beside the parser alone.
;;;
;;; Method, from cps-core.sps §4 and chez-httparse's
;;; test/common/allocation-tests.sps: one parser per connection with a shared
;;; binding list; the workload is cps-core's keep-alive GET with three headers,
;;; fed whole; 1,000 untimed requests, then 10,000 measured.  The reading is the
;;; difference in (sstats-bytes (statistics)), the CUMULATIVE allocation counter,
;;; divided by 10,000.  Never `bytes-allocated`: that is the live heap, and it
;;; read -77 B/request across a collection in the CPS spike.  The calibration
;;; row makes a counter that stopped counting visible.
(import (rnrs) (rnrs mutable-pairs)
        (generated httparse-message) (httparse modes) (byte-machine runtime)
        (http-server connection) (http-server response)
        (only (chezscheme) printf statistics sstats-bytes machine-type scheme-version))

(define one (string->utf8 "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
(define len (bytevector-length one))
(define inits (list (cons 'type (httparse-message-type-value 'request))))
(define warm 1000)
(define reps 10000)
(define gate 3072)

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

;; bindings : (Symbol -> SpanProc) (Symbol -> EventProc) -> Bindings
;; All 25, each made once per configuration and shared by its parser.
(define (bindings span event)
  (map (lambda (name)
         (list name (if (memq name span-callbacks) (span name) (event name))))
       all-callbacks))

;; reply : Symbol -> Outcome — pause at on-message-complete, as M2's loop does.
(define (reply name)
  (if (eq? name 'on-message-complete) callback-pause callback-continue))

;; per-request : (-> Any) -> Nat — bytes allocated per call, after warm-up.
(define (per-request thunk)
  (let loop ((i 0)) (when (< i warm) (thunk) (loop (+ i 1))))
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i reps) (thunk) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) reps)))

;; driver : Bindings Ctx -> (-> Any)
;; One request: feed it whole, and resume if the bindings paused the parser.
(define (driver bs ctx)
  (let ((p (make-parser httparse-message-machine bs ctx inits)))
    (lambda ()
      (let ((r (parser-feed! p one 0 len)))
        (case (parser-result-status r)
          ((paused) (parser-resume! p))
          ((need-input) #t)
          (else (error 'driver "unexpected parser status" (parser-result-status r))))))))

;; The sink every event goes to: assigned here and read at the end, so no
;; event the bindings build can be optimized away.
(define hold #f)

;; --- configurations ---------------------------------------------------------

;; A0: silent bindings, no pause — cps-core.sps's 4b, the parser alone.
(define (silent-no-pause)
  (bindings (lambda (name) (lambda (p c bv f t) callback-continue))
            (lambda (name) (lambda (p c) callback-continue))))

;; A1: silent bindings that pause at on-message-complete — the parser under
;; M2's control flow, and the base the event configurations are read against.
(define (silent-pause)
  (bindings (lambda (name) (lambda (p c bv f t) callback-continue))
            (lambda (name) (let ((r (reply name))) (lambda (p c) r)))))

;; B: A1 plus M2.1's shape — a fresh tagged list per callback.
(define (list-events)
  (bindings (lambda (name)
              (lambda (p c bv f t) (set! hold (list 'parser-event name bv f t)) callback-continue))
            (lambda (name)
              (let ((r (reply name)))
                (lambda (p c) (set! hold (list 'parser-event name)) r)))))

;; B-rec: A1 plus a fresh record per callback instead of a list.
(define-record-type pev (fields name bv from to))
(define (record-events)
  (bindings (lambda (name)
              (lambda (p c bv f t) (set! hold (make-pev name bv f t)) callback-continue))
            (lambda (name)
              (let ((r (reply name)))
                (lambda (p c) (set! hold (make-pev name #f 0 0)) r)))))

;; B-reuse: A1 plus one preallocated event per shape, overwritten per callback.
(define span-cell (list 'parser-event #f #f 0 0))
(define event-cell (list 'parser-event #f))
(define (reused-events)
  (bindings (lambda (name)
              (lambda (p c bv f t)
                (let ((l (cdr span-cell)))
                  (set-car! l name) (set-car! (cdr l) bv)
                  (set-car! (cddr l) f) (set-car! (cdddr l) t))
                (set! hold span-cell)
                callback-continue))
            (lambda (name)
              (let ((r (reply name)))
                (lambda (p c) (set-car! (cdr event-cell) name) (set! hold event-cell) r)))))

;; C: M2.1's `conn-step` itself, as the shell will drive it.  The adapter
;; answers the parser with the step's `reply-parser` (continue when a step in
;; M2.1 has none yet), and keeps the rest of the actions as a queue would.
(define-record-type cx (fields (mutable state) (mutable queued)))
(define (dispatch! c ev)
  (call-with-values
   (lambda () (conn-step (cx-state c) ev))
   (lambda (s actions)
     (cx-state-set! c s)
     (if (and (pair? actions) (eq? (caar actions) 'reply-parser))
         (begin (cx-queued-set! c (cdr actions))
                (if (eq? (cadar actions) 'pause) callback-pause callback-continue))
         (begin (cx-queued-set! c actions) callback-continue)))))
(define (core-events)
  (bindings (lambda (name) (lambda (p c bv f t) (dispatch! c (list 'parser-event name bv f t))))
            (lambda (name) (lambda (p c) (dispatch! c (list 'parser-event name))))))
(define resp (make-response 200 #f '() #f))
(define (core-driver c)
  (let ((p (make-parser httparse-message-machine (core-events) c inits)))
    (lambda ()
      (dispatch! c (list 'bytes-arrived one 0 len))
      (let ((r (parser-feed! p one 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (error 'core-driver "the core did not pause the parser" (parser-result-status r)))
        (dispatch! c (list 'parser-result (parser-result-status r) (parser-result-consumed r)
                           (parser-result-next r) #f #f))
        (dispatch! c (list 'handler-responded resp))
        (dispatch! c (list 'write-completed len))
        (parser-resume! p)))))

;; C-reuse: C with the parser events delivered through one reused cell per
;; shape, so no event is allocated per callback.  This is the cost a direct
;; entry point for parser callbacks would leave: the four shell events and
;; the action lists.
(define (core-events-reused)
  (bindings (lambda (name)
              (lambda (p c bv f t)
                (let ((l (cdr span-cell)))
                  (set-car! l name) (set-car! (cdr l) bv)
                  (set-car! (cddr l) f) (set-car! (cdddr l) t))
                (dispatch! c span-cell)))
            (lambda (name)
              (lambda (p c) (set-car! (cdr event-cell) name) (dispatch! c event-cell)))))
(define (core-driver-reused c)
  (let ((p (make-parser httparse-message-machine (core-events-reused) c inits)))
    (lambda ()
      (dispatch! c (list 'bytes-arrived one 0 len))
      (let ((r (parser-feed! p one 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (error 'core-driver-reused "the core did not pause the parser" (parser-result-status r)))
        (dispatch! c (list 'parser-result (parser-result-status r) (parser-result-consumed r)
                           (parser-result-next r) #f #f))
        (dispatch! c (list 'handler-responded resp))
        (dispatch! c (list 'write-completed len))
        (parser-resume! p)))))

;; D: count the callbacks one request fires, by kind.
(define counts (make-eq-hashtable))
(define (counting)
  (bindings (lambda (name)
              (lambda (p c bv f t) (hashtable-update! counts name (lambda (n) (+ n 1)) 0) callback-continue))
            (lambda (name)
              (let ((r (reply name)))
                (lambda (p c) (hashtable-update! counts name (lambda (n) (+ n 1)) 0) r)))))

;; --- measurements -------------------------------------------------------------

(printf "platform: ~a, ~a\n" (machine-type) (scheme-version))

;; Calibration: 10,000 fresh pairs must read as 10,000 pairs' worth.
(let ((before (sstats-bytes (statistics))))
  (let loop ((i 0) (acc '())) (if (< i 10000) (loop (+ i 1) (cons i acc)) (set! hold acc)))
  (printf "calibration: 10000 conses read as ~a bytes (~a per pair)\n"
          (- (sstats-bytes (statistics)) before)
          (div (- (sstats-bytes (statistics)) before) 10000)))

;; One event of each shape, 10,000 times, to price the shapes themselves.
(define (shape-bytes make)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i 10000) (set! hold (make i)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) 10000)))
(printf "shape: (parser-event name) ~a B; (parser-event name bv from to) ~a B; pev record ~a B\n"
        (shape-bytes (lambda (i) (list 'parser-event 'on-url-complete)))
        (shape-bytes (lambda (i) (list 'parser-event 'on-url-data one i 7)))
        (shape-bytes (lambda (i) (make-pev 'on-url-data one i 7))))

(let ((d (driver (counting) #f)))
  (d)                                   ; the first request fires no on-reset
  (hashtable-clear! counts)
  (d)
  (let-values (((names tallies) (hashtable-entries counts)))
    (let* ((total (apply + (vector->list tallies)))
           (spans (let loop ((i 0) (n 0))
                    (if (= i (vector-length names)) n
                        (loop (+ i 1) (if (memq (vector-ref names i) span-callbacks)
                                          (+ n (vector-ref tallies i)) n))))))
      (printf "callbacks per keep-alive request: ~a = ~a spans + ~a events\n"
              total spans (- total spans)))))

(define a0 (per-request (driver (silent-no-pause) #f)))
(define a1 (per-request (driver (silent-pause) #f)))
(define b  (per-request (driver (list-events) #f)))
(define br (per-request (driver (record-events) #f)))
(define bu (per-request (driver (reused-events) #f)))
(define cx0 (make-cx (make-conn-state 'idle 'idle #f 0 #f #f) '()))
(define c  (per-request (core-driver cx0)))
(define cx1 (make-cx (make-conn-state 'idle 'idle #f 0 #f #f) '()))
(define cr (per-request (core-driver-reused cx1)))

(define (row label n base)
  (printf "~a ~a B/request~a  (~a% of the ~a B gate)\n"
          label n
          (if base (string-append "  = A1 + " (number->string (- n base))) "")
          (div (* 100 n) gate) gate))
(row "A0     parser alone, silent, no pause (cps-core 4b):     " a0 #f)
(row "A1     parser alone, silent, pause + resume:             " a1 #f)
(row "B      A1 + M2.1's tagged-list events:                   " b a1)
(row "B-rec  A1 + a record per callback:                       " br a1)
(row "B-reuse A1 + one reused event per shape:                 " bu a1)
(row "C      M2.1's conn-step, the whole cycle:                " c a1)
(row "C-reuse C with no event allocated per callback:          " cr a1)

;; The core really ran both cycles: back in idle, with the resume actions queued.
(printf "C ended in ~a with ~s queued; the sink holds a ~a\n"
        (conn-phase (cx-state cx0)) (cx-queued cx0)
        (if (pair? hold) (car hold) hold))
(printf "C-reuse ended in ~a with ~s queued\n"
        (conn-phase (cx-state cx1)) (cx-queued cx1))
