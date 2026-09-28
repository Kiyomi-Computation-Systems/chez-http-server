#!r6rs
;;; M5 exit, 2026-09-27: how much of an answer the kernel holds for a client
;;; that never reads, on loopback.
;;;
;;; The socket lane's slow reader (slowhttptest's slow read) must ask for more
;;; than the kernel holds, or its write completes and no write deadline passes.
;;; Here a server writes 512 KiB, then 2 MiB, to a client that never reads,
;;; its send buffer made 4,096 B as it accepts the client, as the lane's is.
;;; The client's receive buffer is left as the kernel makes it, or made
;;; 16,384 B after it connects, or before, bound first.  Printed: whether the
;;; write completed within 2 s of the loop's time, and when, and the client's
;;; receive buffer then.
;;;
;;; Run on the project's library path (the ledger's M4 entry gives it).
(import (rnrs) (only (chezscheme) printf format) (libuv) (uv-testing))

;; trial : Symbol Nat -> Void
;; One server and one client on a loop of their own; `when-set` is `unset`,
;; `after` or `before`.
(define (trial when-set size)
  (let* ((loop (make-uv-loop))
         (listener (make-uv-tcp loop))
         (port (bind-loopback! listener))
         (client (make-uv-tcp loop))
         (served #f) (started #f) (completed #f))
    (uv-listen! listener 4
                (lambda (err)
                  (let ((tcp (uv-accept! listener)))
                    (set! served tcp)
                    (uv-send-buffer-size! tcp 4096)
                    (set! started (uv-now loop))
                    (uv-write! tcp (make-bytevector size 120)
                               (lambda (err) (set! completed (list (- (uv-now loop) started) err)))))))
    (when (eq? when-set 'before)
      (bind-loopback! client)
      (uv-recv-buffer-size! client 16384))
    (connect-loopback! client port
                       (lambda (err)
                         (when (eq? when-set 'after) (uv-recv-buffer-size! client 16384))))
    (let ((t0 (uv-now loop)) (tick (make-uv-timer loop)))
      (uv-timer-start! tick (lambda (t) #f) 5 5)
      (let run ()
        (uv-run loop 'once)
        (unless (or completed (> (- (uv-now loop) t0) 2000)) (run)))
      (printf "~a, ~a B: write ~a; the client's receive buffer then ~a B\n"
              when-set size
              (if completed (format "completed after ~a ms" (car completed)) "not completed in 2 s")
              (uv-recv-buffer-size client))
      (for-each (lambda (h) (unless (eq? (uv-handle-state h) 'closed) (uv-close! h)))
                (filter (lambda (h) h) (list tick client listener served)))
      (run-until loop (lambda () #f) 50)
      (uv-loop-teardown! loop))))

(for-each (lambda (w) (for-each (lambda (size) (trial w size)) (list (* 512 1024) (* 2 1024 1024))))
          '(unset after before))
