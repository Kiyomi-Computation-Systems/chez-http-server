#!r6rs
;;; M7 exit, 2026-10-02: what a connection costs the real shell, held idle,
;;; once its handler has waited.
;;;
;;; Since M7 a handler may answer `(awaiting thunk)`: the thunk runs on a
;;; coroutine, which parks while it waits (decision 0014).  Design §5.2 says
;;; a coroutine costs its stack only while it is parked, so an idle
;;; connection carries none, and plan §14's M7 exit runs the budget spike
;;; again to show it.  So this is m5-exit-budget.sps's holds again, on the
;;; merged tree, each GET answered three ways: by a handler that answers its
;;; response, as at the M4 and M5 exits; by one that answers awaiting, its
;;; thunk sleeping 0 ms (`sleep-ms`), so that its coroutine parks on the
;;; loop's timer for the waits; and by one whose thunk looks localhost up
;;; (`resolve`), so that its coroutine parks on uv-getaddrinfo!.  Each round
;;; holds the three in turn.  Each coroutine a thunk runs on is noted in a
;;; weak pair, and each hold prints how many coroutines its GETs made, and
;;; how many are still in the heap once the client is ready, after a full
;;; collection; the pairs are let go before the heap is read.  Last, for
;;; scale, what a coroutine parked at an `await` holds: 2,000 of them parked
;;; at once, on a scheduler of their own.
;;;
;;; Run on the project's library path (the ledger's M4 entry gives it), with
;;; this directory's m4-exit-hold.py as its argument and python3 on PATH.
(import (rnrs)
        (only (chezscheme) printf collect collect-maximum-generation bytes-allocated scheme-version
              weak-cons bwp-object?)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server connection) conn-phase)
        (only (http-server private scheduler)
              make-scheduler scheduler-spawn! scheduler-drain! current-coroutine)
        (only (http-server private waits) make-waits)
        (only (http-server private shell) shell-connections connection-state shell-deadlines
              shell-waits-timed)
        (only (http-server private serve) start-server)
        (only (libuv private native) live-counts))

(define hold (cadr (command-line)))
(define cap 1000000)

;; heap : -> Nat — the bytes the heap holds after two full collections.
(define (heap)
  (collect (collect-maximum-generation))
  (collect (collect-maximum-generation))
  (bytes-allocated))

;; How the handler answers, set before each hold: 'response, 'sleep or
;; 'resolve.  The coroutines its thunks have run on, each the car of a weak
;; pair, and how many there were.
(define way 'response)
(define noted '())
(define made 0)

;; note! : -> Void — the coroutine running, noted weakly.
(define (note!)
  (set! noted (weak-cons (current-coroutine) noted))
  (set! made (+ made 1)))

;; still-held : -> Nat
;; How many of the coroutines noted are in the heap after a full collection.
(define (still-held)
  (collect (collect-maximum-generation))
  (let count ((l noted) (n 0))
    (if (null? l) n (count (cdr l) (if (bwp-object? (car l)) n (+ n 1))))))

;; handler : Request -> Answer — a 200 with "ok", answered as `way` says.
(define (handler request)
  (case way
    ((response) (make-response 200 #f '() (string->utf8 "ok")))
    ((sleep) (awaiting (lambda ()
                         (note!)
                         (sleep-ms 0)
                         (make-response 200 #f '() (string->utf8 "ok")))))
    ((resolve) (awaiting (lambda ()
                           (note!)
                           (resolve "localhost")
                           (make-response 200 #f '() (string->utf8 "ok")))))))

(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         handler
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))

;; held : Symbol Nat Nat -> Nat
;; The server's heap while the client holds `n` connections, each idle after
;; `r` GETs, each GET answered as `w` says; printed with chez-libuv's counts
;; of TCP handles and read buffers, how many of the connections have a
;; deadline armed, how many sleeps and deadlines the waits have armed, and
;; the coroutines the GETs made and those still in the heap.
(define (held w n r)
  (set! way w)
  (set! noted '())
  (set! made 0)
  (let* ((in (make-uv-pipe loop)) (out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f)
         (child (uv-spawn! loop "python3"
                           (list "python3" hold (number->string port) (number->string n) (number->string r))
                           (list (cons 'stdio (list (list 'pipe in 'to-child) (list 'pipe out 'from-child)
                                                    '(inherit-fd . 2))))
                           (lambda (status signal) (set! exit (list status signal))))))
    (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
    (let ((ready (run-shell-until loop sh
                                  (lambda ()
                                    (and (equal? (collector-bytes said) (string->utf8 "ready\n"))
                                         (= (length (shell-connections sh)) n)
                                         (for-all (lambda (c) (eq? (conn-phase (connection-state c)) 'idle))
                                                  (shell-connections sh))))
                                  cap)))
      (let* ((left (still-held)) (coroutines made))
        (set! noted '())
        (let* ((h (heap)) (counts (live-counts)) (armed (shell-deadlines sh)) (timed (shell-waits-timed sh)))
          (uv-close! in)
          (let ((gone (run-shell-until loop sh (lambda () (and exit (null? (shell-connections sh)))) cap)))
            (uv-close! child)
            (uv-close! out)
            (run-until-drained loop 1000)
            (printf "  ~a, held ~a after ~a GET~a each: ~a, heap ~a B; TCP handles ~a, read buffers ~a; deadlines armed ~a, waits timed ~a; coroutines made ~a, in the heap ~a; then ~a, client exit ~a\n"
                    w n r (if (= r 1) "" "s") ready h (cdr (assq 'tcp counts)) (cdr (assq 'read-buffer counts))
                    armed timed coroutines left gone exit)
            h))))))

;; per-item : (-> Any) Nat -> Rational — the heap one more of `make`'s
;; results costs, kept in a list, `k` of them.
(define (per-item make k)
  (let* ((before (heap))
         (kept (let collect-items ((i 0) (acc '()))
                 (if (= i k) acc (collect-items (+ i 1) (cons (make) acc)))))
         (after (heap)))
    (if (null? kept) 0 (/ (- after before) k))))

(printf "Chez ~a, libuv ~a, the listener on 127.0.0.1:~a\n" (scheme-version) (uv-version) port)
(printf "One held connection's heap, (heap with 500 - heap with 100) / 400:\n")
(for-each
 (lambda (r)
   (for-each
    (lambda (round)
      (for-each
       (lambda (w)
         (let* ((a100 (held w 100 r)) (a500 (held w 500 r)))
           (printf "~a, after ~a GET~a each, ~a: ~a B\n" w r (if (= r 1) "" "s") round
                   (inexact (/ (- a500 a100) 400)))))
       '(response sleep resolve)))
    '(first again)))
 '(1 10 50 200))
(let* ((pair (per-item (lambda () #f) 2000))
       (s (make-scheduler (lambda (mode) #f)))
       (w (make-waits s (lambda (what details) #f)))
       (before (heap))
       (kept (let spawn ((i 0) (acc '()))
               (if (= i 2000)
                   acc
                   (spawn (+ i 1)
                          (cons (scheduler-spawn! s (lambda () (await (lambda (resume) #f)))
                                                  (lambda (how v) #f))
                                acc))))))
  (scheduler-drain! s)
  (let ((after (heap)))
    (printf "A coroutine parked at an await, 2,000 parked at once, less a list's pair (~a B): ~a B\n"
            pair (inexact (- (/ (- after before) (length kept)) pair)))))
