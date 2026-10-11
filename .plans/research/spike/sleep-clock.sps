#!r6rs
;;; The shell suite's "a handler that holds the loop 30 ms, then sleeps 20
;;; ms, ...", its `/sleep` handler repeated with the real shell and a client
;;; on its loop, N rounds, two ways a round:
;;;   chez: the hold is 30 ms of Chez's monotonic clock, the suite's hold!,
;;;         as the handler held until 2026-10-11;
;;;   loop: the hold spins on a second loop, bringing its time up to date,
;;;         until it reads 30 ms on, as hold-until! does.
;;; Either way the handler then reads both clocks, sleeps 20 ms, and reads
;;; both again: Chez's monotonic clock, in µs, as the check read it until
;;; 2026-10-11, and libuv's loop clock, in ms, read on a loop made for the
;;; read, as the check reads it since.  Each round prints, a line a way: the
;;; way, the sleep on Chez's clock in µs, the sleep on the loop's clock in
;;; ms, the hold on Chez's clock in µs, and the hold on the loop's clock in
;;; ms.  The check took the sleep at 18,000 µs or more until 2026-10-11, and
;;; at 20 ms of the loop's clock or more since.
;;;
;;;   CHEZSCHEMELIBDIRS=<make build's library path> chez --program sleep-clock.sps N
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
              (before-ms (loop-ms)))
         (sleep-ms 20)
         (let* ((after-ms (loop-ms))
                (after-us (monotonic-us)))
           (make-response 200 #f '()
                          (string->utf8
                           (string-append (number->string (- after-us before-us)) " "
                                          (number->string (- after-ms before-ms)) " "
                                          (number->string held-us) " "
                                          (number->string held-ms))))))))))

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
