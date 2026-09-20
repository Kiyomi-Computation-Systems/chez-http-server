;; E4a: a handler as a Chez engine; the top-level scheduler interleaves engine
;; slices with uv-run, and the engine is resumed after uv-run ran callbacks.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define fired 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm) (set! fired (+ fired 1))) 1 1)   ; 1 ms repeating
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define handler
  (make-engine (lambda ()
    (let lp ((i 0) (acc 0)) (if (= i 30) (list 'handler-done i acc) (lp (+ i 1) (+ acc (busy 100000))))))))
(define slices 0)
(define result
  (let run ((eng handler))
    (eng 5000
      (lambda (ticks-left . vals) (say "engine complete; ticks-left=" ticks-left " values=" vals) vals)
      (lambda (new-eng)
        (set! slices (+ slices 1))
        (let ((before fired))
          (if (<= slices 3) (uv-run loop 'once) (uv-run loop 'nowait))
          (when (or (<= slices 3) (= 0 (mod slices 100)))
            (say "slice " slices " expired; uv-run ran " (- fired before) " timer callback(s); resuming engine")))
        (run new-eng)))))
(say "result=" result " slices=" slices " timer callbacks total=" fired)
(uv-close! t)
(say "final uv-run -> " (uv-run loop 'default))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
