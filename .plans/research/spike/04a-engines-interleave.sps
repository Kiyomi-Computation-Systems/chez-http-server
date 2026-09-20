;; E4a: a handler as a Chez engine, slices interleaved with (uv-run loop 'nowait)
;; from the TOP-LEVEL scheduler; resumable after a later uv-run that ran a
;; real callback.
(import (rnrs) (libuv)
        (only (chezscheme) printf make-engine display-condition))
(define (log! fmt . args) (apply printf fmt args) (flush-output-port (current-output-port)))
(define (show e) (call-with-string-output-port (lambda (p) (display-condition e p))))
(define loop (make-uv-loop))
(define ticks-fired 0)
(define tick (make-uv-timer loop))
(uv-timer-start! tick (lambda (t) (set! ticks-fired (+ ticks-fired 1))) 0 1)
(define (busy n) (let f ((i 0) (acc 0)) (if (< i n) (f (+ i 1) (+ acc i)) acc)))
(define handler
  (make-engine
    (lambda ()
      (let f ((i 0) (seen '()))
        (if (< i 8)
            (begin (busy 200000) (f (+ i 1) (cons (cons i ticks-fired) seen)))
            (reverse seen))))))
(define slices 0)
(define result
  (let run ((e handler))
    (e 10000
       (lambda (ticks-left . vals) (log! "engine COMPLETED after ~a expiries; ticks-left ~a\n" slices ticks-left) (car vals))
       (lambda (e2)
         (set! slices (+ slices 1))
         (guard (x (#t (log! "uv-run nowait between slices RAISED: ~a\n" (show x))))
           (uv-run loop 'nowait))
         (run e2)))))
(log! "(iteration . ticks-fired-at-that-point): ~s\n" result)
(log! "ticks-fired total ~a (timer callbacks ran between engine slices: ~s)\n" ticks-fired (> ticks-fired 0))

;; Second: expire once, then run a REAL 20 ms callback with uv-run 'once, then resume.
(define fired-20 #f)
(define t20 (make-uv-timer loop))
(uv-timer-start! t20 (lambda (t) (set! fired-20 #t) (uv-close! t20)) 20 0)
(define e1 (make-engine (lambda () (busy 5000000) 'second-done)))
(define outcome
  (e1 1000
      (lambda (tl . v) (list 'completed-in-first-slice v))
      (lambda (e2)
        (log! "engine expired; running uv-run 'once until the 20 ms callback fires...\n")
        (let wait () (unless fired-20 (uv-run loop 'once) (wait)))
        (log! "20 ms callback fired (fired-20=~s); resuming the expired engine with a big budget\n" fired-20)
        (e2 100000000 (lambda (tl . v) (list 'resumed-and-completed v)) (lambda (e3) 'expired-again)))))
(log! "outcome: ~s\n" outcome)
(uv-close! tick)
(guard (e (#t (log! "teardown RAISED: ~a\n" (show e)))) (uv-loop-teardown! loop))
(log! "teardown done; loop-open? ~s\n" (uv-loop-open? loop))
