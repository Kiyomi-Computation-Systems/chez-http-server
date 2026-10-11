#!r6rs
;;; The shell suite's "a handler that holds the loop 30 ms, then sleeps 20
;;; ms, ..., a timer due 19 ms in firing while the sleep is armed; ...", its
;;; `/sleep` handler repeated as sleep-clock.sps repeats it, two ways a
;;; round, with the witness: before the sleep, a timer on the suite's loop,
;;; started from the loop's cached time so that it is due at `before` plus
;;; 19 by the loop's clock, reads how many timed waits are armed as it
;;; fires.  Each round prints, a line a way, what sleep-clock.sps prints,
;;; then what the witness read, or not-fired.  With the shell as built it
;;; reads 1, the sleep.  With M7T-21's shell first on the library path (the
;;; waits' clock read with no update), the sleep is due first, and the
;;; witness reads 0 or has not fired.
;;;
;;;   CHEZSCHEMELIBDIRS=[<mutant root>:]<make build's library path> chez --program sleep-witness.sps N
(import (rnrs)
        (only (chezscheme) current-time time-second time-nanosecond)
        (libuv) (uv-testing) (shell-testing) (response-reader)
        (http-server private shell)
        (only (http-server awaiting) awaiting)
        (only (http-server private waits) sleep-ms)
        (http-server request) (http-server span) (http-server limits) (http-server response))

(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))
(define (monotonic-us)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000 (time-second t)) (div (time-nanosecond t) 1000))))
(define (hold! ms)
  (let ((until (+ (monotonic-ms) ms)))
    (let spin () (when (< (monotonic-ms) until) (spin)))))
(define (hold-until! until)
  (call-with-uv-loop
   (lambda (clock)
     (let spin ()
       (uv-update-time! clock)
       (when (< (uv-now clock) until) (spin))))))
(define (loop-ms)
  (call-with-uv-loop (lambda (clock) (uv-update-time! clock) (uv-now clock))))

(define way 'chez)
(define (handler req)
  (awaiting
   (lambda ()
     (let ((hold-us (monotonic-us)) (hold-ms (loop-ms)))
       (if (eq? way 'chez) (hold! 30) (hold-until! (+ hold-ms 30)))
       (let* ((held-us (- (monotonic-us) hold-us))
              (held-ms (- (loop-ms) hold-ms))
              (before-us (monotonic-us))
              (before-ms (loop-ms))
              (seen (vector 'not-fired))
              (witness (make-uv-timer loop)))
         (uv-timer-start! witness
                          (lambda (t) (vector-set! seen 0 (shell-waits-timed shell)))
                          (- (+ before-ms 19) (uv-now loop)) 0)
         (sleep-ms 20)
         (uv-close! witness)
         (let* ((after-ms (loop-ms))
                (after-us (monotonic-us))
                (w (vector-ref seen 0)))
           (make-response 200 #f '()
                          (string->utf8
                           (string-append (number->string (- after-us before-us)) " "
                                          (number->string (- after-ms before-ms)) " "
                                          (number->string held-us) " "
                                          (number->string held-ms) " "
                                          (if (symbol? w) (symbol->string w) (number->string w)))))))))))

(define loop (make-uv-loop))
(define shell (make-shell loop handler default-limits (lambda () 0) (lambda (w d) #f) (lambda (c k d) #f)))
(define listener (make-uv-tcp loop))
(define port (bind-loopback! listener))
(uv-listen! listener 16 (lambda (err) (unless err (shell-adopt! shell (uv-accept! listener)))))

;; one : Symbol -> Void — one round of `w`.
(define (one w)
  (set! way w)
  (let ((cl (open-client loop port (string->utf8 "GET /sleep HTTP/1.1\r\nHost: x\r\n\r\n") #t)))
    (let ((outcome (run-loop-until loop (lambda () (= 1 (length (responses (client-bytes cl))))) 4096)))
      (display w) (display " ")
      (if (eq? outcome 'satisfied)
          (display (cadddr (car (responses (client-bytes cl)))))
          (display outcome))
      (newline))
    (client-close! cl)
    (run-loop-until loop (lambda () (null? (shell-connections shell))) 4096)))

(let ((n (string->number (cadr (command-line)))))
  (do ((i 0 (+ i 1))) ((= i n))
    (one 'chez)
    (one 'loop)))
