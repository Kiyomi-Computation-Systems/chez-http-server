#!r6rs
;;; The guards' hoist, 2026-10-05: what Chez 10.4.1 allocates for the
;;; protections the shell wraps around its work, none of them raising: a
;;; guard, with-exception-handler, call/1cc with it, and dynamic-wind; and a
;;; guard's cost as the stack under it deepens.  Read off `bytes-allocated`
;;; with the collector held off, the least of five calls after one to warm.
;;;
;;;   chez --program hoist-guard-cost.sps
(import (chezscheme))
(define keep (make-vector 2 #f))
(define cell0 (vector (lambda (x) (vector-set! keep 1 x) x)))
(define (opq x) ((vector-ref cell0 0) x))
(define (cost thunk)
  (thunk)
  (let loop ((i 0) (least #f))
    (if (= i 5) least
        (let ((a (bytes-allocated))) (thunk)
          (let ((d (- (bytes-allocated) a))) (loop (+ i 1) (if least (min least d) d)))))))
(define (plain x) (opq x))
(define (g1 x) (guard (e (#t (opq e) (raise e))) (opq x)))
(define (weh x) (with-exception-handler (lambda (e) (opq e) (raise e)) (lambda () (opq x))))
(define (c1cc x) (call/1cc (lambda (k) (with-exception-handler (lambda (e) (k (opq e))) (lambda () (opq x))))))
(define (dw3 c before) (dynamic-wind (lambda () (opq c)) (lambda () (opq before)) (lambda () (opq c) (opq before))))
(define (nested-guard-deep n) (if (= n 0) (g1 1) (+ 0 (nested-guard-deep (- n 1)))))
(collect-request-handler void)
(printf "~a (~a)\n" (scheme-version) (machine-type))
(printf "calibration, a plain call: ~a B\n" (cost (lambda () (plain 1))))
(printf "guard, a re-raising clause, no raise: ~a B\n" (cost (lambda () (g1 1))))
(printf "with-exception-handler: ~a B\n" (cost (lambda () (weh 1))))
(printf "call/1cc + with-exception-handler: ~a B\n" (cost (lambda () (c1cc 1))))
(printf "dynamic-wind, thunks with two free variables: ~a B\n" (cost (lambda () (dw3 1 2))))
(for-each (lambda (d) (printf "guard under ~a frames: ~a B\n" d (cost (lambda () (nested-guard-deep d))))) '(0 10 100 1000))
