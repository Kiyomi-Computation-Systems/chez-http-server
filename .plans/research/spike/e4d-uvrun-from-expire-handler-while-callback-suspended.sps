;; E4d: the engine's ticks expire INSIDE a timer callback (as in E4c), and the
;; expire handler then calls (uv-run loop 'nowait) BEFORE resuming the engine,
;; i.e. a second uv_run while the first uv_run's C frames are suspended under
;; the unfinished callback. This is what an engine scheduler that interleaves
;; uv-run with slices would do if a handler ever ran a callback.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define cb-entered 0) (define cb-finished 0) (define t2-fired 0)
(define t1 (make-uv-timer loop))
(define t2 (make-uv-timer loop))
(uv-timer-start! t1 (lambda (tm)
                      (set! cb-entered (+ cb-entered 1))
                      (busy 200000)
                      (set! cb-finished (+ cb-finished 1))
                      (say "t1 callback: finished normally (entered=" cb-entered " finished=" cb-finished ")"))
                 0 0)
(uv-timer-start! t2 (lambda (tm) (set! t2-fired (+ t2-fired 1))) 1 1)
(define handler
  (make-engine (lambda ()
    (say "engine: calling (uv-run loop 'once) from inside the slice")
    (let ((r (uv-run loop 'once)))
      (say "engine: uv-run returned " r)
      (list 'engine-done r)))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 1000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng)
          (set! slices (+ slices 1))
          (let ((nested (guarded "nested-uv-run" (lambda () (uv-run loop 'nowait)))))
            (when (or (<= slices 3) (= 0 (mod slices 50)))
              (say "expire #" slices ": cb-entered=" cb-entered " cb-finished=" cb-finished
                   "; nested (uv-run loop 'nowait) -> " nested "; t2-fired=" t2-fired "; resuming")))
          (run new-eng)))))))
(say "result=" result " slices=" slices " cb-entered=" cb-entered " cb-finished=" cb-finished " t2-fired=" t2-fired)
(uv-timer-stop! t2)
(say "loop-alive? " (guarded "alive" (lambda () (uv-loop-alive? loop))))
(say "uv-run after -> " (guarded "uv-run-after" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
