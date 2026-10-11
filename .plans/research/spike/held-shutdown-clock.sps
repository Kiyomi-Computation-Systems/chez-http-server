#!r6rs
;;; The shell suite's "a shutdown asked once the loop has been held 300 ms
;;; dates its drain after the hold", repeated with the real shell, N rounds,
;;; two ways a round, each on loops of its own:
;;;   chez: the hold is 300 ms of Chez's monotonic clock, the suite's hold!,
;;;         as the check held until 2026-10-10;
;;;   loop: the hold spins on a second loop, bringing its time up to date,
;;;         until it reads before + 300, as the check holds since.
;;; Each round prints, a line a way: the way, the drain's date less
;;; `before`, both on the loop's clock in ms, and the hold's length on
;;; Chez's clock in µs.  The check took the first at 299 or more until
;;; 2026-10-10, and at 300 or more since.
;;;
;;;   CHEZSCHEMELIBDIRS=<make build's library path> chez --program held-shutdown-clock.sps N
(import (rnrs)
        (only (chezscheme) current-time time-second time-nanosecond)
        (libuv)
        (http-server private shell)
        (http-server limits) (http-server response))

(define slow-ms 300)
(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))
(define (monotonic-us)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000 (time-second t)) (div (time-nanosecond t) 1000))))
(define (hold! ms)
  (let ((until (+ (monotonic-ms) ms)))
    (let spin () (when (< (monotonic-ms) until) (spin)))))
(define (hold-on-clock! l until)
  (let spin ()
    (uv-update-time! l)
    (when (< (uv-now l) until) (spin))))

(define drain-limits
  (limits-with default-limits '((drain-timeout-ms . 200) (tick-ms . 10))))
(define asked #f)
(define (trace! c kind datum)
  (when (and (eq? kind 'server-event) (eq? (car datum) 'shutdown-requested))
    (set! asked (cadr datum))))
(define (handler req) (make-response 200 #f '() (string->utf8 "x")))

;; one : Symbol -> Void — one round of `way`.
(define (one way)
  (let* ((loop (make-uv-loop))
         (other (make-uv-loop))
         (late (make-shell loop handler drain-limits (lambda () 0) (lambda (w d) #f) trace!)))
    (set! asked #f)
    (uv-update-time! loop)
    (let* ((before (uv-now loop))
           (from (monotonic-us)))
      (if (eq? way 'chez) (hold! slow-ms) (hold-on-clock! other (+ before slow-ms)))
      (let ((held (- (monotonic-us) from)))
        (shell-shutdown! late)
        (uv-loop-teardown! other)
        (uv-loop-teardown! loop)
        (display way) (display " ") (display (- asked before)) (display " ") (display held)
        (newline)))))

(let ((n (string->number (cadr (command-line)))))
  (do ((i 0 (+ i 1))) ((= i n))
    (one 'chez)
    (one 'loop)))
