;; E5e: E5c through the binding, but the loop thread sits in ONE (uv-run loop 'default)
;; and never returns to top-level Scheme between polls: only chez-libuv's timer
;; dispatch path (trampoline -> registry -> dispatch-guarded -> closure) runs per
;; tick. If the worker still finishes in a few ms with a 1 ms timer, the binding's
;; per-callback Scheme volume alone reaches $event, and E5c's 'once wait loop was
;; not what opened the GC windows. Same worker as E5c (3,000,000 ten-element vectors).
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time collections) (libuv) (spike common))
(define m (make-mutex))
(define (allocate!) (let lp ((i 0) (keep '())) (if (= i 3000000) (length keep) (lp (+ i 1) (if (= 0 (mod i 100000)) (cons (make-vector 10) keep) (begin (make-vector 10) keep))))))
(define (trial period-ms)
  (let* ((loop (make-uv-loop)) (t (make-uv-timer loop)) (done #f) (elapsed #f) (fires 0) (c0 (collections)))
    (uv-timer-start! t (lambda (tm) (set! fires (+ fires 1)) (when (with-mutex m done) (uv-close! t))) period-ms period-ms)
    (fork-thread (lambda () (sleep (make-time 'time-duration 20000000 0)) (let ((t0 (now-ms))) (allocate!) (with-mutex m (set! elapsed (- (now-ms) t0)) (set! done #t)))))
    (uv-run loop 'default)
    (uv-loop-teardown! loop)
    (say "  period " period-ms " ms: worker elapsed " elapsed " ms; collections " (- (collections) c0) "; timer fired " fires " times")))
(say "loop thread in one (uv-run loop 'default); binding dispatch path only")
(trial 300)
(trial 1)
(say "done")
