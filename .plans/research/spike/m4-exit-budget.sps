#!r6rs
;;; M4 exit, 2026-09-27: what a connection costs the real shell, held idle.
;;;
;;; Design §7.5 budgets a connection at 16,384 + 264 + 1,072 bytes: the read
;;; buffer, libuv's uv_tcp_t, and a parser on the shared binding list, from
;;; sizes measured before any shell existed.  Plan §8's M4 exit re-measures it
;;; against the real handle.  A server is started as `serve` starts one, on
;;; 127.0.0.1:0 with the default limits, and a client in a process of its own
;;; (m4-exit-hold.py) holds N keep-alive connections to it, each idle after R
;;; GETs.  The server's heap is read after two full collections with 100 and
;;; with 500 held, twice for each R, and the difference over 400 is one
;;; connection's heap.  chez-libuv's dev-build counts confirm what is held.
;;; What lives outside the heap is read from libuv and the limits.  Last, the
;;; heap cost of the parts a connection is made of, each made 2,000 times and
;;; kept in a list, less the list's own pair.
;;;
;;; Run on the project's library path (the ledger's M4 entry gives it), with
;;; this directory's m4-exit-hold.py as its argument and python3 on PATH.
(import (rnrs)
        (only (chezscheme) printf collect collect-maximum-generation bytes-allocated scheme-version)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server limits) default-limits limits-read-buffer-size)
        (only (http-server connection) make-conn-state conn-phase)
        (only (http-server private adapter) make-conn-context make-conn-parser)
        (only (http-server private shell) shell-connections connection-state)
        (only (http-server private serve) start-server)
        (only (libuv private native) uv-handle-size live-counts)
        (only (libuv private constants) uv-tcp-type))

(define hold (cadr (command-line)))
(define cap 1000000)

;; heap : -> Nat — the bytes the heap holds after two full collections.
(define (heap)
  (collect (collect-maximum-generation))
  (collect (collect-maximum-generation))
  (bytes-allocated))

(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         (lambda (request) (make-response 200 #f '() (string->utf8 "ok")))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))

;; held : Nat Nat -> Nat
;; The server's heap while the client holds `n` connections, each idle after
;; `r` GETs; printed with chez-libuv's counts of TCP handles and read buffers.
(define (held n r)
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
      (let ((h (heap)) (counts (live-counts)))
        (uv-close! in)
        (let ((gone (run-shell-until loop sh (lambda () (and exit (null? (shell-connections sh)))) cap)))
          (uv-close! child)
          (uv-close! out)
          (run-until-drained loop 1000)
          (printf "  held ~a after ~a GET~a each: ~a, heap ~a B; TCP handles ~a, read buffers ~a; then ~a, client exit ~a\n"
                  n r (if (= r 1) "" "s") ready h (cdr (assq 'tcp counts)) (cdr (assq 'read-buffer counts))
                  gone exit)
          h)))))

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
   (let* ((a100 (held 100 r)) (a500 (held 500 r)) (b100 (held 100 r)) (b500 (held 500 r)))
     (printf "after ~a GET~a each: ~a B, and again ~a B\n" r (if (= r 1) "" "s")
             (inexact (/ (- a500 a100) 400)) (inexact (/ (- b500 b100) 400)))))
 '(1 10 50 200))
(printf "Outside the heap, a connection's: uv_tcp_t ~a B (uv_handle_size), read buffer ~a B (limits-read-buffer-size)\n"
        (uv-handle-size (uv-tcp-type)) (limits-read-buffer-size default-limits))
(let ((pair (per-item (lambda () #f) 2000)))
  (printf "The parts, fresh, less a list's pair (~a B):\n" pair)
  (let ((state (lambda () (make-conn-state 'idle 'idle #f 0 0 #f #f default-limits))))
    (printf "  the core's state, with its head and target judge: ~a B\n" (- (per-item state 2000) pair))
    (printf "  the adapter's context: ~a B\n" (- (per-item (lambda () (make-conn-context #f (lambda (a) a))) 2000) pair))
    (let ((ctx (make-conn-context (state) (lambda (a) a))))
      (printf "  a parser on the shared binding list: ~a B\n" (- (per-item (lambda () (make-conn-parser ctx)) 2000) pair)))
    (printf "  chez-libuv's TCP handle, its heap side: ~a B\n" (- (per-item (lambda () (make-uv-tcp loop)) 2000) pair))))
