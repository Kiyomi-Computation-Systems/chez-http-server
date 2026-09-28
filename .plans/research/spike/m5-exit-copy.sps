#!r6rs
;;; M5 exit, 2026-09-27: what chez-libuv's copies cost the loop.
;;;
;;; The M5 exit's slow-read client asks for a four MiB answer and never reads
;;; it.  In the socket lane, the loop's timer did not fire for about a quarter
;;; of a second after that request, so a client beside it that sent its body
;;; a piece at a time sent none of its pieces in that time, and its body
;;; deadline passed first.  chez-libuv v0.7.0 copies each write's bytes into
;;; the memory libuv writes from, and each read's out of the buffer libuv
;;; reads into, one byte at a time, in Scheme (`copy-in!` and `copy-out` in
;;; `(libuv private native)`).  This prices:
;;; (a) copy-in! and copy-out at 16 KiB (the shell's read buffer), 256 KiB,
;;;     1 MiB (the exit's slow reader's answer) and 4 MiB, in ns per byte,
;;;     and what copy-out allocates;
;;; (b) the same copies through libc's memcpy, one foreign call each, the
;;;     bytevector passed as `u8*`: what a bulk copy costs;
;;; (c) the four MiB answer's work before its write is under way: the
;;;     handler's body made, the response serialized, and its segments
;;;     copied as uv-write*! copies them.
;;; Each is timed on the monotonic clock, five times after one untimed run,
;;; and the five are printed sorted.
;;;
;;; Run on the project's library path (the ledger's M4 entry gives it).
(import (rnrs)
        (only (chezscheme) printf foreign-procedure foreign-alloc foreign-free foreign-entry?
              current-time time-second time-nanosecond statistics sstats-bytes collect)
        (http-server response)
        (only (http-server serializer) serialize-checked-response)
        (only (libuv private native) copy-in! copy-out))

(define (now-ns)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))

;; timed : (-> Any) -> (Listof Nat) — the ns five runs of `thunk` took,
;; sorted, after one run untimed.
(define (timed thunk)
  (thunk)
  (list-sort <
             (map (lambda (i)
                    (collect)
                    (let ((t0 (now-ns)))
                      (thunk)
                      (- (now-ns) t0)))
                  '(1 2 3 4 5))))

;; per-byte : (Listof Nat) Nat -> Real — the least of `ns` over `n` bytes.
(define (per-byte ns n) (/ (round (* 100 (/ (car ns) n))) 100.0))

(define memcpy-in (and (foreign-entry? "memcpy") (foreign-procedure "memcpy" (uptr u8* size_t) uptr)))
(define memcpy-out (and (foreign-entry? "memcpy") (foreign-procedure "memcpy" (u8* uptr size_t) uptr)))

(printf "(a) and (b): ns per byte, the least of five; the five in ns\n")
(for-each
 (lambda (n)
   (let ((bv (make-bytevector n 120)) (mem (foreign-alloc n)))
     (let ((in (timed (lambda () (copy-in! mem bv 0 n))))
           (out (timed (lambda () (copy-out mem n))))
           (out-bytes (let ((s0 (statistics)))
                        (copy-out mem n)
                        (- (sstats-bytes (statistics)) (sstats-bytes s0)))))
       (printf "  ~a B: copy-in! ~a ns/B ~a; copy-out ~a ns/B ~a, allocating ~a B a call\n"
               n (per-byte in n) in (per-byte out n) out out-bytes)
       (if memcpy-in
           (let ((min (timed (lambda () (memcpy-in mem bv n))))
                 (mout (timed (lambda () (memcpy-out (make-bytevector n) mem n)))))
             (printf "  ~a B: memcpy in ~a ns/B ~a; memcpy out, into a fresh bytevector, ~a ns/B ~a\n"
                     n (per-byte min n) min (per-byte mout n) mout))
           (printf "  memcpy: not found\n")))
     (foreign-free mem)))
 (list 16384 (* 256 1024) (* 1024 1024) (* 4 1024 1024)))

(printf "(c) the four MiB answer's work, the least of five, in ms:\n")
(let* ((size (* 4 1024 1024))
       (made (timed (lambda () (make-bytevector size 120))))
       (response (make-response 200 #f (list (cons (string->utf8 "Connection") (string->utf8 "close")))
                                (make-bytevector size 120)))
       (serialized (timed (lambda () (serialize-checked-response response 'content-length 'close))))
       (segments (let-values (((segs n) (serialize-checked-response response 'content-length 'close))) segs))
       ;; A segment is a bytevector or the Date slot, which the shell fills
       ;; with a line of its own; the bytevectors are copied here.
       (copied (timed (lambda ()
                        (for-each (lambda (seg)
                                    (when (bytevector? seg)
                                      (let* ((len (bytevector-length seg))
                                             (mem (foreign-alloc (max len 1))))
                                        (copy-in! mem seg 0 len)
                                        (foreign-free mem))))
                                  segments)))))
  (printf "  the body made: ~a; serialized: ~a; its ~a segments copied: ~a\n"
          (/ (car made) 1e6) (/ (car serialized) 1e6) (length segments) (/ (car copied) 1e6)))
