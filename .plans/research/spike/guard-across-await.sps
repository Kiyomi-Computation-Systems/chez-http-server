#!r6rs
;; (1) Does a guard installed INSIDE a coroutine catch a raise that happens
;;     after the coroutine was suspended (call/1cc) and resumed by the scheduler?
;; (2) How many times do dynamic-wind in/out thunks run across one suspend/resume?
;; (3) Does an UNCAUGHT raise inside a coroutine land in the scheduler's guard
;;     (a plain Scheme frame), i.e. never anywhere near a foreign frame?
(import (rnrs) (only (chezscheme) call/1cc))

(define sched-k #f)
(define parked #f)
(define (await!) (call/1cc (lambda (k) (set! parked k) (sched-k 'suspended))))

(define ins 0) (define outs 0)
(define result-1 'not-run)
(define result-3 'not-run)

(define (coroutine-1)
  (set! result-1
        (guard (e ((symbol? e) (list 'caught e)))
          (dynamic-wind
            (lambda () (set! ins (+ ins 1)))
            (lambda ()
              (await!)                    ; suspend here; scheduler resumes later
              (raise 'after-resume))      ; raised AFTER resumption
            (lambda () (set! outs (+ outs 1))))))
  (sched-k 'finished))

(define (coroutine-3)
  (await!)
  (raise 'uncaught-in-coroutine)         ; no guard in the coroutine
  (sched-k 'finished))

(define (run coroutine)
  (set! parked #f)
  (let ((r (guard (e (#t (list 'scheduler-guard-caught e)))
             (call/1cc (lambda (k) (set! sched-k k) (coroutine))))))
    (let loop ((r r))
      (cond ((eq? r 'suspended)
             ;; the scheduler "polls" here in the real design; then resumes
             (loop (guard (e (#t (list 'scheduler-guard-caught e)))
                     (call/1cc (lambda (k) (set! sched-k k) (parked 'go))))))
            (else r)))))

(display "coroutine-1 run -> ") (display (run coroutine-1)) (newline)
(display "guard-inside-coroutine caught after resume: ") (display result-1) (newline)
(display "dynamic-wind in=") (display ins) (display " out=") (display outs) (newline)
(display "coroutine-3 run -> ") (display (run coroutine-3)) (newline)
