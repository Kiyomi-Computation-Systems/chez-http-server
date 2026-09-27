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
;;     and allocation per call.  Eight rounds, each with the four in an order
;;     rotated by one, so each is measured first, second, third and last in
;;     two rounds; each one's eight results sorted, their least and median.
;; A part that fails names how, a raise, a callback that never ran or a
;; thread that never answered, and the program goes on to the next.
(import (rnrs) (rnrs mutable-pairs)
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

;; describe : Any -> List — what was raised: its who and message, if it has them.
(define (describe e)
  (list 'raised
        (and (who-condition? e) (condition-who e))
        (and (message-condition? e) (condition-message e))))

;; --- (a) ---
(define loop (make-uv-loop))
(define due-ran? #f)
(define seen 'never-ran)
(uv-timer-start! (make-uv-timer loop) (lambda (t) (set! due-ran? #t) (uv-close! t)) 10 0)
(uv-timer-start! (make-uv-timer loop)
                 (lambda (t)
                   (set! seen
                         (guard (e (#t (describe e)))
                           (let ((n0 (uv-now loop)))
                             (hold! 100)
                             (let ((n1 (uv-now loop)))
                               (uv-update-time! loop)
                               (list (- n1 n0) (- (uv-now loop) n0) due-ran?)))))
                   (uv-close! t))
                 0 0)
(uv-run loop 'default)
(if (and (pair? seen) (number? (car seen)))
    (begin
      (show "(a) after a 100 ms hold, uv-now had moved (expect 0):" (car seen))
      (show "    after uv-update-time!, it had moved (expect 100 or more):" (cadr seen))
      (show "    a 10 ms timer, due, had run during the call (expect #f):" (caddr seen)
            "| and ran after it (expect #t):" due-ran?))
    (show "(a) did not run to its end:" seen))

;; --- (b) ---
;; fired-after : Boolean -> (U Integer List Symbol)
;; How long after its arm, in whole ms, a 150 ms timer fired when it was
;; armed at the end of a callback that held the loop 100 ms; or what raised,
;; or `never-fired`.
(define (fired-after refresh?)
  (let ((l (make-uv-loop)) (armed #f) (fired #f) (raised #f))
    (uv-timer-start! (make-uv-timer l)
                     (lambda (t)
                       (guard (e (#t (set! raised (describe e))))
                         (hold! 100)
                         (when refresh? (uv-update-time! l))
                         (set! armed (now-ms))
                         (uv-timer-start! (make-uv-timer l)
                                          (lambda (t) (set! fired (now-ms)) (uv-close! t))
                                          150 0))
                       (uv-close! t))
                     0 0)
    (uv-run l 'default)
    (uv-loop-teardown! l)
    (cond (raised raised)
          ((and armed fired) (exact (round (- fired armed))))
          (else 'never-fired))))
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
                      (#t (describe e)))
              (uv-update-time! loop)
              'not-refused)))
     (with-mutex m (set! refusal r)))))
(let wait ((ms 0))
  (let ((r (with-mutex m refusal)))
    (cond (r (show "(c) off the loop's thread (expect wrong-thread uv-update-time!):" r))
          ((= ms 2000) (show "(c) off the loop's thread: no answer in 2000 ms"))
          (else (sleep (make-time 'time-duration 1000000 0)) (wait (+ ms 1))))))

;; --- (d) ---
(define native (foreign-procedure "uv_update_time" (uptr) void))
(define (workaround!) (native (loop-pointer loop 'workaround!)))
(define (verb!) (uv-update-time! loop))

;; measure : Nat (-> Any) -> (List Nat Real) — ns and bytes per call over n calls.
(define (measure n thunk)
  (collect)
  (let* ((s0 (statistics))
         (ran (do ((i 0 (+ i 1))) ((= i n)) (thunk)))
         (s1 (statistics))
         (cpu (lambda (s) (+ (* 1000000000 (time-second (sstats-cpu s))) (time-nanosecond (sstats-cpu s))))))
    (list (div (- (cpu s1) (cpu s0)) n)
          (inexact (/ (- (sstats-bytes s1) (sstats-bytes s0)) n)))))

(define rows
  (list (cons "uv-update-time!" verb!)
        (cons "the workaround " workaround!)
        (cons "uv-now         " (lambda () (uv-now loop)))
        (cons "nothing        " (lambda () #f))))

;; rotate : (Listof Any) Nat -> (Listof Any) — begun at its k-th element.
(define (rotate xs k)
  (if (= k 0) xs (rotate (append (cdr xs) (list (car xs))) (- k 1))))

(for-each (lambda (row) (measure 100000 (cdr row))) rows)
(let ((results (map (lambda (row) (cons (car row) '())) rows)))
  (do ((round 0 (+ round 1))) ((= round 8))
    (for-each (lambda (row)
                (let ((slot (assoc (car row) results)))
                  (set-cdr! slot (cons (measure 1000000 (cdr row)) (cdr slot)))))
              (rotate rows (mod round 4))))
  (show "(d) eight rounds of a million calls each, the order rotated; ns per call sorted, least, median, and bytes per call:")
  (for-each (lambda (slot)
              (let* ((ns (list-sort < (map car (cdr slot))))
                     (bytes (fold-left (lambda (acc b) (if (member b acc) acc (cons b acc)))
                                       '() (map cadr (cdr slot)))))
                (show "   " (car slot) ns 'least (car ns)
                      'median (inexact (/ (+ (list-ref ns 3) (list-ref ns 4)) 2))
                      'bytes bytes)))
            results))
(uv-loop-teardown! loop)
(display "done") (newline)
