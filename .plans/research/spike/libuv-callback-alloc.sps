#!r6rs
;;; What chez-libuv allocates around each callback it delivers, with the
;;; callbacks themselves allocating nothing: a uv-run on an idle loop, a
;;; timer's firing, a write's call and its completion, and a read (libuv's
;;; alloc callback, the read callback and the copy).  Allocation is read off
;;; `bytes-allocated` with the collector held off for the measured window, so
;;; the reading allocates nothing itself (calibrated below: a cons reads 16 B).
;;; Each figure is the least of five windows of N operations each.
;;;
;;;   chez --program libuv-callback-alloc.sps    (chez-libuv's src on the path)
(import (rnrs)
        (only (chezscheme) printf collect collect-request-handler bytes-allocated void
              scheme-version machine-type)
        (libuv))

(define keep (make-vector 1 #f))
(define n 20000)

;; least : (-> Any) -> Nat — the least, over five windows, of the bytes one
;; call of `thunk` allocates, warmed first.
(define (least thunk)
  (thunk)
  (let loop ((w 0) (best #f))
    (if (= w 5)
        best
        (let ((a (bytes-allocated)))
          (let run ((i 0)) (when (< i n) (thunk) (run (+ i 1))))
          (let ((b (/ (- (bytes-allocated) a) n)))
            (loop (+ w 1) (if best (min best b) b)))))))

(define loop (make-uv-loop))
(collect)
(collect-request-handler void)
(printf "~a (~a), libuv ~a, chez-libuv's src as built\n" (scheme-version) (machine-type) (uv-version))
(define (r1 x) (/ (round (* 10 (inexact x))) 10))
(printf "calibration, a cons: ~a B\n" (least (lambda () (vector-set! keep 0 (cons 1 2)))))

;; 1. uv-run 'nowait on a loop with nothing on it.
(define idle-run (least (lambda () (uv-run loop 'nowait))))
(printf "uv-run 'nowait, idle loop: ~a B\n" (r1 idle-run))

;; 2. A timer's firing: started at 0 ms, run once, its callback empty.
(define t (make-uv-timer loop))
(define (on-timeout h) #f)
(define start-stop (least (lambda () (uv-timer-start! t on-timeout 0 0) (uv-timer-stop! t))))
(define start-run (least (lambda () (uv-timer-start! t on-timeout 0 0) (uv-run loop 'once))))
(printf "timer: start and stop ~a B; start and a run that fires it ~a B: the firing, less an idle run, ~a B\n"
        (r1 start-stop) (r1 start-run) (r1 (- start-run start-stop idle-run)))

;; 3. A write and its read over loopback: 16 bytes written with uv-write*!,
;; its completion empty; the peer's read callback empty.  Each round runs the
;; loop 'once until the completion and the read have both been delivered.
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define peer #f)
(uv-listen! server 16 (lambda (err) (set! peer (uv-accept! server))))
(define client (make-uv-tcp loop))
(define connected #f)
(uv-tcp-connect! client "127.0.0.1" (uv-tcp-getsockname-port server) (lambda (err) (set! connected #t)))
(let wait () (unless (and connected peer) (uv-run loop 'once) (wait)))
(define reads 0)
(define (on-data bv start end) (set! reads (+ reads 1)))
(uv-read-start! peer on-data (lambda () #f) (lambda (e) #f) 16384)
(define msg (make-bytevector 16 97))
(define segs (list msg))
(define done 0)
(define (on-written err) (set! done (+ done 1)))
(define runs 0)
(define (round-trip)
  (let ((d done) (r reads))
    (uv-write*! client segs on-written)
    (let wait () (unless (and (> done d) (> reads r)) (uv-run loop 'once) (set! runs (+ runs 1)) (wait)))))
;; The call alone, outside the runs that deliver its round:
(define calls-only
  (let ((total 0) (k 2000))
    (let go ((i 0))
      (when (< i k)
        (let ((d done) (r reads) (a (bytes-allocated)))
          (uv-write*! client segs on-written)
          (set! total (+ total (- (bytes-allocated) a)))
          (let wait () (unless (and (> done d) (> reads r)) (uv-run loop 'once) (wait))))
        (go (+ i 1))))
    (/ total k)))
(set! runs 0)
(define rt (least round-trip))
(define runs-per (/ runs (+ (* 5 n) 1)))  ; least: one warm-up, then five windows
(printf "uv-write*! of one 16-byte segment, the call alone: ~a B\n" (r1 calls-only))
(printf "a round: the call, then ~a uv-run 'once on average, delivering the completion, libuv's alloc callback, the read and its copy: ~a B\n"
        (r1 runs-per) (r1 rt))
(printf "  the callbacks' share, less the call and ~a idle runs: ~a B\n"
        (r1 runs-per) (r1 (- rt calls-only (* runs-per idle-run))))
