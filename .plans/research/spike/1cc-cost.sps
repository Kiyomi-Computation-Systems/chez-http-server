#!r6rs
;; Measure: cost of call/1cc capture + one-shot resume, as a coroutine yield.
;; A "coroutine" here is exactly the shape the proposal uses: the scheduler
;; resumes a saved k; the coroutine captures its own k with call/1cc and
;; jumps back to the scheduler's k. No foreign frames anywhere.
(import (rnrs) (only (chezscheme) call/1cc bytes-allocated current-time time-difference time-nanosecond time-second collect set-car!))

(define iterations 1000000)

;; two-way ping-pong between a scheduler continuation and a coroutine continuation
(define (run-1cc n)
  (let ((sched-k #f) (coro-k #f) (count 0))
    ;; the coroutine body: loop n times, yielding each time
    (define (coroutine)
      (let loop ((i 0))
        (when (< i n)
          (call/1cc (lambda (k) (set! coro-k k) (sched-k 'yielded)))
          (set! count (+ count 1))
          (loop (+ i 1))))
      (sched-k 'done))
    (let sched ()
      (let ((r (call/1cc (lambda (k) (set! sched-k k)
                          (if coro-k (coro-k 'go) (coroutine))))))
        (if (eq? r 'done) count (sched))))))

(define (run-cc n)
  (let ((sched-k #f) (coro-k #f) (count 0))
    (define (coroutine)
      (let loop ((i 0))
        (when (< i n)
          (call/cc (lambda (k) (set! coro-k k) (sched-k 'yielded)))
          (set! count (+ count 1))
          (loop (+ i 1))))
      (sched-k 'done))
    (let sched ()
      (let ((r (call/cc (lambda (k) (set! sched-k k)
                         (if coro-k (coro-k 'go) (coroutine))))))
        (if (eq? r 'done) count (sched))))))

(define (measure name thunk)
  (collect)
  (let* ((b0 (bytes-allocated)) (t0 (current-time))
         (r (thunk))
         (t1 (current-time)) (b1 (bytes-allocated))
         (d (time-difference t1 t0))
         (ns (+ (* (time-second d) 1000000000) (time-nanosecond d))))
    (display name) (display ": result=") (display r)
    (display " total-ns=") (display ns)
    (display " ns/yield=") (display (div ns iterations))
    (display " bytes/yield=") (display (div (- b1 b0) iterations))
    (newline)))

(measure "call/1cc ping-pong" (lambda () (run-1cc iterations)))
(measure "call/cc  ping-pong" (lambda () (run-cc iterations)))
(measure "call/1cc ping-pong (2nd)" (lambda () (run-1cc iterations)))
(measure "call/cc  ping-pong (2nd)" (lambda () (run-cc iterations)))

;; Deep-stack variant: coroutine yields from 200 frames deep (a handler that
;; awaits from inside nested calls), so the captured stack segment is bigger.
(define (deep-yield sched-k-box depth)
  (if (zero? depth)
      (call/1cc (lambda (k) ((car sched-k-box) k)))
      (+ 1 (deep-yield sched-k-box (- depth 1)))))
(define (run-deep n)
  ;; RULE: a coroutine never returns normally into the scheduler's spent
  ;; one-shot; it ends by jumping to the CURRENT scheduler k.
  (let ((box (list #f)) (count 0) (coro-k #f))
    (define (coroutine)
      (let loop ((i 0))
        (when (< i n)
          (deep-yield box 200)
          (set! count (+ count 1))
          (loop (+ i 1))))
      ((car box) 'done))
    (let sched ()
      (let ((r (call/1cc (lambda (k) (set-car! box k)
                          (if coro-k (coro-k 0) (coroutine))))))
        (cond ((eq? r 'done) count)
              (else (set! coro-k r) (sched)))))))
(measure "call/1cc yield from 200 frames deep" (lambda () (run-deep iterations)))
