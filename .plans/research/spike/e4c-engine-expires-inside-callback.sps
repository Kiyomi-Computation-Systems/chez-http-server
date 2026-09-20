;; E4c: (uv-run loop 'once) from INSIDE an engine slice where the timer
;; callback does enough work that the engine's ticks expire INSIDE the callback
;; (inside a foreign frame). Then the expired engine is resumed.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define cb-entered 0) (define cb-finished 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm)
                     (set! cb-entered (+ cb-entered 1))
                     (busy 200000)               ; far more than the slice's ticks
                     (set! cb-finished (+ cb-finished 1))
                     (say "callback: finished normally (entered=" cb-entered " finished=" cb-finished ")"))
                 0 0)
(define handler
  (make-engine (lambda ()
    (say "engine: calling (uv-run loop 'once) from inside the slice")
    (let ((r (uv-run loop 'once)))
      (say "engine: uv-run returned " r " (this means the callback's foreign frame returned)")
      (list 'engine-done r)))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 1000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng)
          (set! slices (+ slices 1))
          (say "expire #" slices ": cb-entered=" cb-entered " cb-finished=" cb-finished "; resuming the engine")
          (run new-eng)))))))
(say "result=" result " slices=" slices " cb-entered=" cb-entered " cb-finished=" cb-finished)
(say "loop-alive? " (guarded "alive" (lambda () (uv-loop-alive? loop))))
(say "uv-run after -> " (guarded "uv-run-after" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
