#!r6rs
;; chez-libuv v0.7.0 (#28): `uv-update-time!` brings the loop's cached clock,
;; `uv-now`, up to date.  libuv reads that clock once a turn and arms every
;; timer from it, so a callback that holds the loop leaves it behind, and a
;; timer armed after such a callback comes due early.
;; (a) in a callback that holds the loop 100 ms, `uv-now` has not moved; after
;;     `uv-update-time!` it has moved by the hold at least, and a timer already
;;     due has not run: the call runs nothing;
;; (b) a 150 ms timer armed after that hold fires early without the refresh,
;;     by about the hold, and on time with it;
;; (c) off the loop's thread the call is refused, `&uv-wrong-thread`;
;; (d) a million calls of it, beside a million of the workaround
;;     chez-http-server carried at v0.6.0 (`uv_update_time` through
;;     chez-libuv's private loop pointer), of `uv-now`, and of nothing: CPU
;;     and allocation per call.
(import (rnrs)
        (only (chezscheme) foreign-procedure statistics sstats-bytes sstats-cpu
              current-time time-second time-nanosecond collect
              fork-thread sleep make-time make-mutex with-mutex)
        (libuv) (only (libuv private handles) loop-pointer))

(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))

;; The monotonic clock in ms, exact and fractional.
(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (/ (time-nanosecond t) 1000000))))

;; Hold the loop's thread `ms`, as a handler that computes does.
(define (hold! ms)
  (let ((end (+ (now-ms) ms)))
    (let spin () (when (< (now-ms) end) (spin)))))

;; --- (a) ---
(define loop (make-uv-loop))
(define due-ran? #f)
(define seen #f)
(uv-timer-start! (make-uv-timer loop) (lambda (t) (set! due-ran? #t) (uv-close! t)) 10 0)
(uv-timer-start! (make-uv-timer loop)
                 (lambda (t)
                   (let ((n0 (uv-now loop)))
                     (hold! 100)
                     (let ((n1 (uv-now loop)))
                       (uv-update-time! loop)
                       (set! seen (list (- n1 n0) (- (uv-now loop) n0) due-ran?))))
                   (uv-close! t))
                 0 0)
(uv-run loop 'default)
(show "(a) after a 100 ms hold, uv-now had moved (expect 0):" (car seen))
(show "    after uv-update-time!, it had moved (expect 100 or more):" (cadr seen))
(show "    a 10 ms timer, due, had run during the call (expect #f):" (caddr seen)
      "| and ran after it (expect #t):" due-ran?)

;; --- (b) ---
;; fired-after : Boolean -> Integer
;; How long after its arm, in whole ms, a 150 ms timer fired when it was
;; armed at the end of a callback that held the loop 100 ms.
(define (fired-after refresh?)
  (let ((l (make-uv-loop)) (armed #f) (fired #f))
    (uv-timer-start! (make-uv-timer l)
                     (lambda (t)
                       (hold! 100)
                       (when refresh? (uv-update-time! l))
                       (set! armed (now-ms))
                       (uv-timer-start! (make-uv-timer l)
                                        (lambda (t) (set! fired (now-ms)) (uv-close! t))
                                        150 0)
                       (uv-close! t))
                     0 0)
    (uv-run l 'default)
    (uv-loop-close! l)
    (exact (round (- fired armed)))))
(show "(b) a 150 ms timer armed after the hold, without the refresh, fired after (expect about 50):"
      (fired-after #f))
(show "    with the refresh (expect 149 or more: libuv's clock counts whole ms):"
      (fired-after #t))

;; --- (c) ---
(define m (make-mutex))
(define refusal #f)
(fork-thread
 (lambda ()
   (let ((r (guard (e ((uv-wrong-thread? e) (list 'wrong-thread (uv-wrong-thread-who e)))
                      (#t (list 'other-condition)))
              (uv-update-time! loop)
              'not-refused)))
     (with-mutex m (set! refusal r)))))
(let wait ()
  (unless (with-mutex m refusal) (sleep (make-time 'time-duration 1000000 0)) (wait)))
(show "(c) off the loop's thread (expect wrong-thread uv-update-time!):" refusal)

;; --- (d) ---
(define native (foreign-procedure "uv_update_time" (uptr) void))
(define (workaround!) (native (loop-pointer loop 'workaround!)))
(define (verb!) (uv-update-time! loop))
(define (measure n thunk)
  (collect)
  (let* ((s0 (statistics))
         (ran (do ((i 0 (+ i 1))) ((= i n)) (thunk)))
         (s1 (statistics))
         (cpu (lambda (s) (+ (* 1000000000 (time-second (sstats-cpu s))) (time-nanosecond (sstats-cpu s))))))
    (list 'ns-per-call (div (- (cpu s1) (cpu s0)) n)
          'bytes-per-call (inexact (/ (- (sstats-bytes s1) (sstats-bytes s0)) n)))))
(measure 100000 verb!)
(measure 100000 workaround!)
(for-each (lambda (round)
            (show "(d) round" round "of a million calls each:")
            (show "    uv-update-time!" (measure 1000000 verb!))
            (show "    the workaround " (measure 1000000 workaround!))
            (show "    uv-now         " (measure 1000000 (lambda () (uv-now loop))))
            (show "    nothing        " (measure 1000000 (lambda () #f))))
          '(1 2))
(uv-loop-teardown! loop)
(display "done") (newline)
