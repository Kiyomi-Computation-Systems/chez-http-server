#!r6rs
;;; After M8, 2026-10-04: what a taker's write refused after its stream has
;;; closed costs, for M8.2's review's sixth finding (decision 0016's
;;; amendment of this date).  A server started as `serve` starts one, whose
;;; handler takes an upgrade; the taker's stream is closed, and then
;;; batches of N writes are asked for on it, each refused, its `done`
;;; deferred to a turn.  The bytes allocated as the writes are asked for,
;;; and as the turns that follow make their `done`s, are read off Chez's
;;; cumulative counter, `sstats-bytes`, each per write.  A warm-up batch of
;;; 1,000, then three of 10,000.
;;;
;;;   chez --program taker-deferred-cost.sps
;;;
;;; Run on the project's library path, from the repository's root: on main's
;;; tree and on the fix's, the difference is the fix's.
(import (rnrs) (only (chezscheme) sstats-bytes statistics)
        (libuv) (uv-testing) (shell-testing) (http-server)
        (only (http-server private shell) shell-listener)
        (only (http-server private serve) start-server))
(define (b s) (string->utf8 s))
(define (env . pairs) (lambda (name) (let ((p (assoc name pairs))) (and p (cdr p)))))
(define (allocated) (sstats-bytes (statistics)))
(define the-t #f) (define closed #f) (define told 0)
(define bv (b "x"))
(define (done why) (set! told (+ told 1)))
(define loop (make-uv-loop))
(define sh (start-server loop
             (lambda (r)
               (switch-protocols (list (cons (b "Upgrade") (b "echo")))
                 (lambda (t retained)
                   (set! the-t t)
                   (transport-on-close! t (lambda () (set! closed #t))))))
             (env '("CHEZ_HTTP_PORT" . "0")) (lambda (what details) #f)))
(define cl (open-client loop (uv-tcp-getsockname-port (shell-listener sh))
             (b "GET / HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n") #t))
(run-shell-until loop sh (lambda () the-t) 4096)
(transport-close! the-t)
(run-shell-until loop sh (lambda () closed) 4096)
(define (batch n)
  (set! told 0)
  (let ((b0 (allocated)))
    (do ((i 0 (+ i 1))) ((= i n)) (transport-write! the-t bv 0 1 done))
    (let ((b1 (allocated)))
      (run-shell-until loop sh (lambda () (= told n)) 100000)
      (let ((b2 (allocated)))
        (list n (inexact (/ (- b1 b0) n)) (inexact (/ (- b2 b1) n)) told)))))
(batch 1000)                                  ; warm up
(for-each (lambda (r) (write r) (newline)) (list (batch 10000) (batch 10000) (batch 10000)))
(client-close! cl)
(run-shell-until loop sh (lambda () (for-all uv-timer? (uv-loop-live-handles loop))) 4096)
