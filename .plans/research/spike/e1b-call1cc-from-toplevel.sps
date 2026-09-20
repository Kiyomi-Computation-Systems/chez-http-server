;; E1b: capture call/1cc inside timer A's callback, let uv-run return, invoke
;; the saved continuation from Scheme top level -- AT MOST ONCE, because the
;; first version of this script re-invoked it forever (the continuation
;; contains the rest of the top-level program).
(import (rnrs) (only (chezscheme) call/1cc) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define a-entries 0)
(define invocations 0)
(define ta (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (set! a-entries (+ a-entries 1))
    (say "A: entered, entry #" a-entries)
    (let ((v (call/1cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/1cc returned " v))
    (say "A: body end, returning normally to libuv"))
  10 0)
(say "top: uv-run 'default -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: loop alive? " (uv-loop-alive? loop) " (this line runs again if the continuation re-enters here)")
(if (= invocations 0)
    (begin
      (set! invocations 1)
      (say "top: invoking saved continuation from top level with 'from-top")
      (say "top: invocation -> " (guarded "invoke" (lambda () (saved 'from-top) 'returned))))
    (say "top: already invoked once; not invoking again"))
(say "top: after invocation, a-entries = " a-entries " invocations = " invocations)
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
