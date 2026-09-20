;; E1a: call/1cc captured inside timer t1's callback, returned normally, then
;; invoked from a LATER, DIFFERENT callback (timer t2).
(import (rnrs) (libuv)
        (only (chezscheme) printf call/1cc display-condition))
(define (log! fmt . args) (apply printf fmt args) (flush-output-port (current-output-port)))
(define (show e) (call-with-string-output-port (lambda (p) (display-condition e p))))

;; CONTROL (no libuv, no foreign frames): call/1cc, return normally, invoke again.
(define ctrl #f)
(define ctrl-invoked #f)
(define (ctrl-capture)
  (let ((v (call/1cc (lambda (k) (set! ctrl k) 'first))))
    (log! "control: call/1cc returned ~s\n" v) v))
(ctrl-capture)
(unless ctrl-invoked
  (set! ctrl-invoked #t)
  (guard (e (#t (log! "control: invoking one-shot k after its normal return RAISED: ~a\n" (show e))))
    (ctrl 'second)
    (log! "control: statement after (ctrl 'second) reached\n")))

(define loop (make-uv-loop))
(define stash #f)
(define t1-entries 0)
(define t1 (make-uv-timer loop))
(define t2 (make-uv-timer loop))
(define t3 (make-uv-timer loop))
(uv-timer-start! t1
  (lambda (t)
    (set! t1-entries (+ t1-entries 1))
    (log! "t1: fired (entry #~a); capturing call/1cc\n" t1-entries)
    (let ((v (call/1cc (lambda (k) (set! stash k) 'first-time))))
      (log! "t1: call/1cc returned ~s; returning normally to libuv\n" v)))
  10 0)
(uv-timer-start! t2
  (lambda (t)
    (log! "t2: fired; invoking stashed k with 'from-t2 (unguarded inside t2)\n")
    (stash 'from-t2)
    (log! "t2: statement after (stash 'from-t2) reached\n"))
  30 0)
(uv-timer-start! t3
  (lambda (t) (log! "t3: fired -- the loop is still dispatching; closing all three timers\n")
    (uv-close! t1) (uv-close! t2) (uv-close! t3))
  60 0)
(define (run-once tag)
  (let ((rc (guard (e (#t (log! "~a: uv-run RAISED: ~a\n" tag (show e)) 'raised))
              (uv-run loop 'default))))
    (log! "~a: uv-run returned ~s; deferred-errors: ~s\n" tag rc
          (map show (uv-loop-deferred-errors loop)))))
(run-once "run-1")
(run-once "run-2 (does the loop survive?)")
(guard (e (#t (log! "teardown RAISED: ~a\n" (show e)))) (uv-loop-teardown! loop))
(log! "teardown done; loop-open? ~s; t1-entries ~a\n" (uv-loop-open? loop) t1-entries)
