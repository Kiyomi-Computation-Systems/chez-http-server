#!r6rs
;; Measure resident Scheme heap per SUSPENDED coroutine: N coroutines each
;; parked at a call/1cc from a modest stack depth (a handler awaiting inside
;; a few nested calls), then a full collection, then bytes-allocated delta / N.
(import (rnrs) (only (chezscheme) call/1cc bytes-allocated collect collect-maximum-generation set-car!))

(define n 10000)
(define parked (make-vector n #f))
(define sched-k #f)

(define (handler-body i depth)
  ;; nest a few frames, then park
  (if (zero? depth)
      (call/1cc (lambda (k) (vector-set! parked i k) (sched-k 'parked)))
      (+ 1 (handler-body i (- depth 1)))))

(define (measure depth)
  (collect (collect-maximum-generation))
  (let ((b0 (bytes-allocated)))
    (let loop ((i 0))
      (when (< i n)
        (call/1cc (lambda (k) (set! sched-k k) (handler-body i depth) (sched-k 'finished)))
        (loop (+ i 1))))
    (collect (collect-maximum-generation))
    (let ((b1 (bytes-allocated)))
      (display "depth=") (display depth)
      (display " parked=") (display n)
      (display " bytes/parked-coroutine=") (display (div (- b1 b0) n))
      (newline))
    ;; resume them all so nothing leaks into the next measurement
    (let loop ((i 0))
      (when (< i n)
        (call/1cc (lambda (k) (set! sched-k k) ((vector-ref parked i) 0)))
        (vector-set! parked i #f)
        (loop (+ i 1))))))

(measure 4)
(measure 16)
(measure 64)
