#!r6rs
;;; M7, 2026-10-02: what a handler costs on a coroutine, measured before the
;;; decision on how a handler comes to run on one (plan §14's M7.1).
;;;
;;; PART 1, per request, through the real parser, adapter and core, one
;;; keep-alive connection serving requests as the allocation suite's does
;;; (tests/test-connection-allocation.sps): `bytes-arrived`, the feed, its
;;; result, the handler's answer, the write's completion and the resume.  The
;;; handler answers a 200 it was given, and is called three ways:
;;;   direct     in place, as both shells call it today;
;;;   coroutine  on a coroutine of its own (m7/scheduler.sls), spawned where
;;;              the shell would call it, run from the scheduler's drain, its
;;;              answer handed to the core once it has ended: a handler that
;;;              never waits;
;;;   parked     the same, the handler parking once before it answers, woken
;;;              as a callback would wake it: a handler that waits once.
;;; Workloads: the allocation gate's GET (the CPS spike's, three fields) and
;;; ab -k's HTTP/1.0 keep-alive GET.  Bytes per request after 1,000 warm-up
;;; requests, averaged over 10,000 (Chez's `sstats-bytes`); and nanoseconds
;;; per request over 100,000, by the monotonic clock, in six rounds, the
;;; order of the three ways rotating from round to round.
;;;
;;; PART 2, what a parked handler holds: 10,000 coroutines, each a handler
;;; parked 4, 16 and 64 calls deep, the live heap after a collection of
;;; every generation, less the same before they were made, per coroutine.
;;; The research measured 3,449 B at 4, 3,815 B at 16 and 5,635 B at 64,
;;; with a bare continuation and no record (design §5.2).
;;;
;;; PART 3, a body read and a body streamed, through a small shell of the
;;; spike's own: the fake shell's message loop without its records, actions
;;; run from one queue after the outermost dispatch, and a write completed on
;;; a later turn.  Each call into the handler's code is made one of three
;;; ways:
;;;   in-place  every call in place, as today;
;;;   deferred  the handler's call made from the scheduler's drain, in place,
;;;             with no coroutine (the scheduler made plain), its reader's
;;;             pieces and end and its producer's calls in place;
;;;   handler   the handler's call on a coroutine, its reader's pieces and
;;;             end and its producer's calls in place;
;;;   every     every call on a coroutine of its own, spawned where the shell
;;;             makes it and run from the scheduler's drain: the handler's,
;;;             each piece's, the end's and each producer call.  The shell
;;;             answers on credit, a streaming reader's piece credited once
;;;             the reader has taken it (M6.2).
;;; Workloads: the gate's GET; the allocation suite's JSON POST (a 13-byte
;;; body, fed whole), read by `read-body`, dropping its pieces, and by
;;; `read-whole-body`; and the gate's GET answered with a producer of 8
;;; pieces of 100 bytes, a fresh producer each request.  Bytes per request
;;; after 1,000, over 10,000.  The small shell's queue costs the same each
;;; way, so the difference between ways is what a way adds; the totals
;;; count the shell, and the gate's total does not.
;;;
;;; PART 4, the floor: what the scheduler's capture costs alone, `call/1cc`
;;; with a procedure made once, and a coroutine record made once and run
;;; again, to its end, and parked once and woken, its thunk made once and
;;; the ready list threaded through the record, so that nothing but the
;;; continuations is made.  Bytes per run, after 1,000, over 100,000.
;;;
;;; Run on the project's library path (`make run`'s) with this directory,
;;; .plans/research/spike, after it, for (m7 scheduler).
(import (rnrs) (rnrs mutable-pairs)
        (only (chezscheme) call/1cc statistics sstats-bytes collect collect-maximum-generation bytes-allocated
              current-time time-second time-nanosecond scheme-version machine-type printf)
        (byte-machine runtime)
        (only (http-server connection) make-conn-state conn-phase conn-body-reader conn-producer
              producer-event)
        (only (http-server body) read-body read-whole-body body-reader-on-piece body-reader-on-end
              body-reader-whole?)
        (only (http-server private adapter)
              make-conn-context conn-context-step! conn-context-state make-conn-parser parser-result-event)
        (only (http-server response) make-response)
        (only (http-server limits) default-limits)
        (m7 scheduler))
;; PART 3's deferred way makes the scheduler plain while it is measured.

(define (b s) (string->utf8 s))

(define keeper (vector #f))
(define (keep! x) (vector-set! keeper 0 x))

;; bytes-per-run : (-> Any) Nat -> Nat — averaged over `n` runs.
(define (bytes-per-run thunk n)
  (let ((before (sstats-bytes (statistics))))
    (let loop ((i 0)) (when (< i n) (keep! (thunk)) (loop (+ i 1))))
    (div (- (sstats-bytes (statistics)) before) n)))

;; ns-per-run : (-> Any) Nat -> Nat — by the monotonic clock, over `n` runs.
(define (ns-per-run thunk n)
  (let ((t0 (current-time 'time-monotonic)))
    (let loop ((i 0)) (when (< i n) (keep! (thunk)) (loop (+ i 1))))
    (let ((t1 (current-time 'time-monotonic)))
      (div (+ (* 1000000000 (- (time-second t1) (time-second t0)))
              (- (time-nanosecond t1) (time-nanosecond t0)))
           n))))

(define resp (make-response 200 #f '() #f))
(define (handler request) resp)

;; call-handler-request : (Listof (Listof Action)) -> Request
;; The request the core asked the handler about, among the batches queued.
(define (call-handler-request batches)
  (cond ((null? batches) (assertion-violation 'call-handler-request "the core asked no handler"))
        ((assq 'call-handler (car batches)) => cadr)
        (else (call-handler-request (cdr batches)))))

;; connection : Bytevector Symbol -> (-> Void)
;; A keep-alive connection that serves `request` once a call, its handler
;; called the way `how` names.
(define (connection request how)
  (let* ((queued '())
         (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits)
                                 (lambda (actions) (set! queued (cons actions queued)))))
         (p (make-conn-parser ctx))
         (len (bytevector-length request))
         (answer #f)
         (parked #f))
    (define (respond! a)
      (let ((w (assq 'write (conn-context-step! ctx (list 'handler-responded a)))))
        (unless w (assertion-violation 'connection "the answer was not written"))
        (conn-context-step! ctx (list 'write-completed (caddr w)))))
    (lambda ()
      (set! queued '())
      (conn-context-step! ctx (list 'bytes-arrived request 0 len))
      (let ((r (parser-feed! p request 0 len)))
        (unless (eq? (parser-result-status r) 'paused)
          (assertion-violation 'connection "the core did not pause the parser" (parser-result-status r)))
        (conn-context-step! ctx (parser-result-event r))
        (let ((req (call-handler-request queued)))
          (case how
            ((direct) (respond! (handler req)))
            ((coroutine)
             (spawn! (lambda () (set! answer (handler req))))
             (drain-ready!)
             (respond! answer))
            ((parked)
             (spawn! (lambda ()
                       (set! parked (current-coroutine))
                       (park!)
                       (set! answer (handler req))))
             (drain-ready!)
             (wake! parked 'woken)
             (drain-ready!)
             (respond! answer))
            (else (assertion-violation 'connection "not a way to call a handler" how))))
        (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
          (assertion-violation 'connection "the connection did not return to idle"
                               (conn-phase (conn-context-state ctx))))
        (set! answer #f)
        (parser-resume! p)))))

(define gate-get (b "GET /a HTTP/1.1\r\nHost: x\r\nUser-Agent: spike\r\nAccept: */*\r\n\r\n"))
(define ab-get
  (b "GET / HTTP/1.0\r\nConnection: Keep-Alive\r\nHost: localhost:8080\r\nUser-Agent: ApacheBench/2.3\r\nAccept: */*\r\n\r\n"))

(printf "M7 handler coroutines: Chez ~a ~a\n" (scheme-version) (machine-type))
(printf "\nPART 1, per request through the parser, adapter and core\n")

;; rotate : (Listof Any) Nat -> (Listof Any) — `xs` begun at its `i`th, mod its length.
(define (rotate xs i)
  (let ((k (mod i (length xs))))
    (let loop ((j 0) (front '()) (rest xs))
      (if (= j k) (append rest (reverse front)) (loop (+ j 1) (cons (car rest) front) (cdr rest))))))

(define hows '(direct coroutine parked))

;; The bytes, once each; the time in six rounds, the order of the three
;; rotating from round to round, so none is always measured first.
(for-each
 (lambda (workload)
   (let ((serves (map (lambda (how) (cons how (connection (cdr workload) how))) hows)))
     (for-each (lambda (s)
                 (bytes-per-run (cdr s) 1000)
                 (printf "  ~a ~a: ~a B\n" (car workload) (car s) (bytes-per-run (cdr s) 10000)))
               serves)
     (let ((times (map (lambda (how) (cons how '())) hows)))
       (let round ((i 0))
         (when (< i 6)
           (for-each (lambda (s)
                       (let ((cell (assq (car s) times)))
                         (set-cdr! cell (cons (ns-per-run (cdr s) 100000) (cdr cell)))))
                     (rotate serves i))
           (round (+ i 1))))
       (for-each (lambda (t)
                   (printf "  ~a ~a: ~a ns, six rounds\n" (car workload) (car t) (reverse (cdr t))))
                 times))))
 (list (cons "the gate's GET" gate-get) (cons "ab -k's GET" ab-get)))

;; PART 2.
(define n 10000)
(define parked (make-vector n #f))

;; nest : Nat -> Any — `depth` calls deep, then park.
(define (nest depth)
  (if (zero? depth) (park!) (begin (keep! depth) (+ 1 (nest (- depth 1))))))

(define (collect-all) (collect (collect-maximum-generation)))

(define (held depth)
  (collect-all)
  (collect-all)
  (let ((before (bytes-allocated)))
    (let loop ((i 0))
      (when (< i n)
        (spawn! (lambda () (vector-set! parked i (current-coroutine)) (nest depth)))
        (loop (+ i 1))))
    (drain-ready!)
    (collect-all)
    (collect-all)
    (let ((after (bytes-allocated)))
      (let loop ((i 0))
        (when (< i n)
          (wake! (vector-ref parked i) 0)
          (vector-set! parked i #f)
          (loop (+ i 1))))
      (drain-ready!)
      (div (- after before) n))))

(printf "\nPART 2, a parked handler's coroutine, the live heap per coroutine at ~a parked\n" n)
(for-each (lambda (depth) (printf "  ~a calls deep: ~a B\n" depth (held depth))) '(4 16 64))
(for-each (lambda (depth) (printf "  ~a calls deep, again: ~a B\n" depth (held depth))) '(4 16 64))

;; PART 3.

;; mini-connection : Bytevector Symbol (Request -> Answer) -> (-> Void)
;; A keep-alive connection that serves `request` once a call, through the
;; small shell, its handler's code called the way `how` names.
(define (mini-connection request how handler)
  (let ((front '()) (back '()) (depth 0) (writes '()) (ctx #f) (p #f)
        (len (bytevector-length request))
        (credit? (eq? how 'every)))
    (define (enqueue! actions)
      (set! back (fold-left (lambda (acc a) (cons a acc)) back actions)))
    (define (dequeue!)
      (when (null? front) (set! front (reverse back)) (set! back '()))
      (and (pair? front) (let ((a (car front))) (set! front (cdr front)) a)))
    (define (dispatch! ev)
      (enqueue! (conn-context-step! ctx ev))
      (when (fxzero? depth) (drain!)))
    (define (drain!)
      (set! depth (fx+ depth 1))
      (let loop () (let ((a (dequeue!))) (when a (run! a) (loop))))
      (set! depth (fx- depth 1)))
    ;; call : Symbol (-> Any) -> Void — the call of `kind`, in place or on a coroutine.
    (define (call kind thunk)
      (if (case how ((in-place) #f) ((deferred handler) (eq? kind 'handler)) (else #t))
          (spawn! thunk)
          (thunk)))
    (define (run! a)
      (case (car a)
        ((feed-parser)
         (set! depth (fx+ depth 1))
         (let ((r (parser-feed! p (cadr a) (caddr a) (cadddr a))))
           (set! depth (fx- depth 1))
           (dispatch! (parser-result-event r))))
        ((resume-parser) (parser-resume! p))
        ((call-handler)
         (let ((req (cadr a)))
           (call 'handler
                 (lambda ()
                   (let ((answer (handler req)))
                     (dispatch! (if credit?
                                    (list 'handler-responded answer 'credit)
                                    (list 'handler-responded answer))))))))
        ((deliver-body)
         (let ((r (conn-body-reader (conn-context-state ctx)))
               (bv (cadr a)) (start (caddr a)) (end (cadddr a)))
           (when r
             (call 'piece
                   (lambda ()
                     ((body-reader-on-piece r) bv start end)
                     (when (and credit? (not (body-reader-whole? r)))
                       (dispatch! (list 'body-credit (- end start)))))))))
        ((deliver-body-end)
         (let ((r (conn-body-reader (conn-context-state ctx))))
           (when r
             (call 'end (lambda () (dispatch! (list 'handler-responded ((body-reader-on-end r)))))))))
        ((notify-producer)
         (let ((pr (conn-producer (conn-context-state ctx))))
           (when pr
             (call 'producer (lambda () (dispatch! (producer-event (pr))))))))
        ((write) (set! writes (cons (caddr a) writes)))
        ((shutdown close) (assertion-violation 'mini-connection "the connection closed" a))
        (else (values))))
    (set! ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits) enqueue!))
    (set! p (make-conn-parser ctx))
    (lambda ()
      (dispatch! (list 'bytes-arrived request 0 len))
      (let settle ()
        (cond ((ready?) (drain-ready!) (settle))
              ((pair? writes)
               (let ((ws (reverse writes)))
                 (set! writes '())
                 (for-each (lambda (n) (dispatch! (list 'write-completed n))) ws))
               (settle))))
      (unless (eq? (conn-phase (conn-context-state ctx)) 'idle)
        (assertion-violation 'mini-connection "the connection did not return to idle"
                             (conn-phase (conn-context-state ctx)))))))

(define json-post
  (b (string-append "POST /api HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\n"
                    "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":\"hello\"}")))
(define (streams request) (read-body (lambda (bv start end) #t) (lambda () resp)))
(define (whole request) (read-whole-body (lambda (body) resp)))
(define piece (make-bytevector 100 97))
(define (eight-pieces request)
  (let ((left 8))
    (make-response 200 #f '() (lambda ()
                                (if (zero? left)
                                    (eof-object)
                                    (begin (set! left (- left 1)) piece))))))

(printf "\nPART 3, through the small shell, bytes per request\n")
(for-each
 (lambda (w)
   (for-each
    (lambda (how)
      (let ((serve (mini-connection (cadr w) how (caddr w))))
        (plain! (eq? how 'deferred))
        (bytes-per-run serve 1000)
        (printf "  ~a ~a: ~a B\n" (car w) how (bytes-per-run serve 10000))
        (plain! #f)))
    '(in-place deferred handler every)))
 (list (list "the gate's GET" gate-get handler)
       (list "the JSON POST, read-body" json-post streams)
       (list "the JSON POST, read-whole-body" json-post whole)
       (list "the gate's GET, 8 pieces of 100 B" gate-get eight-pieces)))

;; PART 4.
(define floor-k #f)
(define (floor-body) 1)
(define enter-bare (lambda (k) (set! floor-k k) (floor-body) (floor-k 'finished)))
(define (bare) (call/1cc enter-bare))

;; A record made once, its thunk made once, the ready list threaded through it.
(define-record-type floor-co (fields (mutable k) (mutable thunk) (mutable next)))
(define the-co (make-floor-co #f floor-body #f))
(define floor-head #f)
(define floor-current #f)
(define enter-thunk (lambda (k) (set! floor-k k) ((floor-co-thunk floor-current)) (floor-k 'finished)))
(define enter-parked
  (lambda (k)
    (set! floor-k k)
    (let ((k0 (floor-co-k floor-current)))
      (floor-co-k-set! floor-current #f)
      (k0 'woken))))
(define (floor-resume! c)
  (set! floor-current c)
  (if (floor-co-k c) (call/1cc enter-parked) (call/1cc enter-thunk))
  (set! floor-current #f))
(define (floor-drain!)
  (let loop ()
    (when floor-head
      (let ((c floor-head))
        (set! floor-head (floor-co-next c))
        (floor-co-next-set! c #f)
        (floor-resume! c))
      (loop))))
(define (reused)
  (floor-co-next-set! the-co floor-head)
  (set! floor-head the-co)
  (floor-drain!))
(define park-enter (lambda (k) (floor-co-k-set! floor-current k) (floor-k 'parked)))
(define parking (lambda () (call/1cc park-enter) 1))
(define (reused-parked)
  (floor-co-thunk-set! the-co parking)
  (floor-resume! the-co)
  (floor-resume! the-co)
  (floor-co-thunk-set! the-co floor-body))

(printf "\nPART 4, the floor, bytes per run\n")
(for-each (lambda (w)
            (bytes-per-run (cdr w) 1000)
            (printf "  ~a: ~a B\n" (car w) (bytes-per-run (cdr w) 100000)))
          (list (cons "call/1cc alone" bare)
                (cons "a record made once, run to its end" reused)
                (cons "a record made once, parked once and woken" reused-parked)))
