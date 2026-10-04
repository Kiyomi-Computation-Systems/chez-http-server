#!r6rs
;;; Decision 0020, 2026-10-04: m7-exit-budget.sps's holds, plain responses
;;; only, after 10 and 50 GETs, three rounds, to see whether a connection
;;; idle after plain responses holds more once the server reads past a
;;; request's end.  The full spike, run twice on main (d784013) and on the
;;; branch, read 41 B more by median after plain responses, and 11 to 14 B
;;; more after waits, the two fields 0020 adds.  Run on main, on the branch,
;;; and on the branch with H6's read-stop put back: the readings fall in two
;;; bands about 95 B apart on all three, flipping between runs and holds, so
;;; the plain rows' medians say nothing of the change.
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
      (let* ((a100 (held 'response 100 r)) (a500 (held 'response 500 r)))
        (printf "response, after ~a GETs each, ~a: ~a B\n" r round (inexact (/ (- a500 a100) 400)))))
    '(first again third)))
 '(10 50))
