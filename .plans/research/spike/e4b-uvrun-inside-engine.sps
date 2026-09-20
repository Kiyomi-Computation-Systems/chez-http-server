;; E4b: (uv-run loop 'nowait) called from INSIDE an engine slice, with a
;; trivial timer callback (expiry is overwhelmingly likely outside the callback).
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define fired 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm) (set! fired (+ fired 1))) 0 1)
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define runs-inside 0)
(define handler
  (make-engine (lambda ()
    (let lp ((i 0))
      (if (= i 300) (list 'done i 'fired fired 'runs-inside runs-inside)
          (begin (set! runs-inside (+ runs-inside 1)) (uv-run loop 'nowait) (busy 3000) (lp (+ i 1))))))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 2000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng) (set! slices (+ slices 1)) (run new-eng)))))))
(say "result=" result " slices=" slices " fired=" fired " loop-alive?=" (uv-loop-alive? loop))
(uv-close! t)
(say "final uv-run -> " (guarded "final" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
