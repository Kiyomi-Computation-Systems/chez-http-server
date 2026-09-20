#!r6rs
;; Spike: does a two-level scheduler (run ready coroutines, then uv-run 'once)
;; block when idle and wake when a callback lands, with NO busy loop?
;; Continuations are captured ONLY in scheduler frames (never inside a callable):
;; the libuv callbacks only push events onto a queue and return.
(import (rnrs) (libuv)
        (only (chezscheme) call/1cc current-time time-difference time-second time-nanosecond))

(define (now-ms)
  (let ((t (current-time)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

(define loop (make-uv-loop))

;; --- the scheduler -------------------------------------------------------
(define run-queue '())          ; list of thunks / continuations to resume (FIFO via append; fine for a spike)
(define (make-runnable! thunk) (set! run-queue (append run-queue (list thunk))))
(define uv-run-calls 0)
(define uv-run-blocked-ms 0)

(define sched-k #f)   ; the scheduler's own continuation, re-captured every resume

;; A coroutine awaits by capturing its k with call/1cc and jumping to the scheduler.
(define (await! register!)
  ;; register! : (k -> unspecified) -- arranges for k to be made runnable later.
  (call/1cc
    (lambda (k)
      (register! k)
      (sched-k 'suspended))))

(define (spawn! thunk) (make-runnable! thunk))

(define (scheduler-step!)
  ;; run every ready coroutine
  (let drain ()
    (unless (null? run-queue)
      (let ((t (car run-queue)))
        (set! run-queue (cdr run-queue))
        (call/1cc (lambda (k) (set! sched-k k) (t) (sched-k 'returned)))
        (drain))))
  ;; then let libuv deliver events; 'once BLOCKS when nothing is due.
  (let ((t0 (now-ms)))
    (set! uv-run-calls (+ 1 uv-run-calls))
    (let ((more (uv-run loop 'once)))
      (set! uv-run-blocked-ms (+ uv-run-blocked-ms (- (now-ms) t0)))
      more)))

(define (scheduler-run!)
  (let go ()
    (let ((more (scheduler-step!)))
      (when (or more (not (null? run-queue)))
        (go)))))

;; --- a fake async operation: a timer whose callback only enqueues -------
(define (sleep-ms! ms)
  (await! (lambda (k)
            (let ((timer (make-uv-timer loop)))
              (uv-timer-start! timer
                               (lambda (t)
                                 ;; callback: NO user code; enqueue and return
                                 (uv-close! t)
                                 (make-runnable! (lambda () (k 'woke))))
                               ms 0)))))

(define events '())
(define (log! x) (set! events (cons (cons (now-ms) x) events)))

(define t-start (now-ms))
(spawn! (lambda ()
          (log! 'a-start)
          (sleep-ms! 300)
          (log! 'a-after-300)
          (sleep-ms! 100)
          (log! 'a-after-400)))
(spawn! (lambda ()
          (log! 'b-start)
          (sleep-ms! 150)
          (log! 'b-after-150)))

(scheduler-run!)
(define elapsed (- (now-ms) t-start))
(for-each (lambda (e) (display (- (car e) t-start)) (display " ") (display (cdr e)) (newline))
          (reverse events))
(display "elapsed-ms=") (display elapsed) (newline)
(display "uv-run-calls=") (display uv-run-calls) (newline)
(display "uv-run-blocked-ms=") (display uv-run-blocked-ms) (newline)
(display "verdict: ")
(display (if (and (>= elapsed 400) (< uv-run-calls 20) (>= uv-run-blocked-ms 350))
             "BLOCKED-IN-UV-RUN-NO-BUSY-LOOP" "BUSY-OR-WRONG"))
(newline)
(uv-loop-teardown! loop)
