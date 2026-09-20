#!r6rs
;; chez-libuv v0.6.0 (#20): uv_async as the one cross-thread wake-up, and loop-thread
;; affinity enforced as a named refusal (&uv-wrong-thread) instead of registry corruption.
;; (a) a worker sends 1000 times; the loop thread drains a caller-side queue (sends coalesce);
;; (b) the same worker is refused a handle verb and a make-uv-async on the loop's handles;
;; (c) the worker-pool handoff: a loop created on main, run on thread B, is owned by B
;;     until main runs it again.
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time get-thread-id) (libuv))
(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))
(define m (make-mutex))
(define main-id (get-thread-id))
(define (refusal thunk)
  (guard (e ((uv-wrong-thread? e)
             (list 'wrong-thread (uv-wrong-thread-who e)
                   'expected-main? (= (uv-wrong-thread-expected e) main-id)
                   'actual-caller? (= (uv-wrong-thread-actual e) (get-thread-id))))
            (#t (list 'other-condition)))
    (thunk) 'not-refused))
;; --- (a) and (b)
(define loop (make-uv-loop))
(define q '()) (define drained 0) (define wakes 0) (define worker-refusals '())
(define t (make-uv-timer loop))                 ; a loop-owned handle the worker must be refused on
(define a (make-uv-async loop
  (lambda (async)
    (set! wakes (+ wakes 1))
    (let ((items (with-mutex m (let ((x q)) (set! q '()) x))))
      (for-each (lambda (i) (if (eq? i 'done) (begin (uv-close! async) (uv-close! t)) (set! drained (+ drained 1)))) items)))))
(fork-thread
  (lambda ()
    (let ((r1 (refusal (lambda () (uv-timer-start! t (lambda (tm) #f) 1000 0))))
          (r2 (refusal (lambda () (make-uv-async loop (lambda (x) #f))))))
      (with-mutex m (set! worker-refusals (list r1 r2))))
    (let lp ((i 0)) (when (< i 1000) (with-mutex m (set! q (cons i q))) (uv-async-send! a) (lp (+ i 1))))
    (with-mutex m (set! q (cons 'done q)))
    (uv-async-send! a)))
(uv-run loop 'default)
(uv-loop-teardown! loop)
(show "worker refused uv-timer-start! on the loop's timer (expect wrong-thread uv-timer-start! expected-main? #t actual-caller? #t):" (car worker-refusals))
(show "worker refused make-uv-async (expect wrong-thread make-uv-async expected-main? #t actual-caller? #t):" (cadr worker-refusals))
(show "items drained (expect 1000):" drained "| wakes (expect between 1 and 1001; sends coalesce):" wakes)
;; --- (c)
(define loop2 (make-uv-loop))
(define t2 (make-uv-timer loop2))
(define cb-thread #f) (define b-done #f)
(uv-timer-start! t2 (lambda (tm) (set! cb-thread (get-thread-id)) (uv-timer-stop! tm)) 1 0)
(fork-thread (lambda () (uv-run loop2 'default) (with-mutex m (set! b-done #t))))
(let wait () (unless (with-mutex m b-done) (nap 1) (wait)))
(show "timer callback ran on thread B, not main (expect #t):" (and cb-thread (not (= cb-thread main-id))))
(show "main refused after the handoff (expect wrong-thread uv-timer-start! expected-main? #f actual-caller? #t):" (refusal (lambda () (uv-timer-start! t2 (lambda (tm) #f) 1 0))))
(uv-run loop2 'nowait)                             ; ownership transfers to main at uv-run entry
(show "after uv-run on main the start is accepted (expect ok):" (guard (e (#t 'refused)) (uv-timer-start! t2 (lambda (tm) (uv-timer-stop! tm) (uv-close! tm)) 1 0) 'ok))
(uv-run loop2 'default)
(uv-loop-teardown! loop2)
(display "done") (newline)
