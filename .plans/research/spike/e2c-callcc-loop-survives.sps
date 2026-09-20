;; E2c: after the stale-foreign-context trap escapes uv-run (E2a), is the loop
;; still usable? Arm a new timer, run again, then tear down.
(import (rnrs) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define ta (make-uv-timer loop))
(define tb (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (let ((v (call/cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/cc returned " v)))
  10 0)
(uv-timer-start! tb (lambda (t) (say "B: invoking saved") (saved 'from-B)) 40 0)
(say "top: uv-run #1 -> " (guarded "uv-run#1" (lambda () (uv-run loop 'default))))
(say "top: live handles: " (length (uv-loop-live-handles loop)) " states: "
     (map uv-handle-state (uv-loop-live-handles loop)))
(define tc (make-uv-timer loop))
(uv-timer-start! tc (lambda (t) (say "C: new timer fired after the trap")) 5 0)
(say "top: uv-run #2 -> " (guarded "uv-run#2" (lambda () (uv-run loop 'default))))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
