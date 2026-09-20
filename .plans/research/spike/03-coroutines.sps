;; E3: two-level loop. Coroutines are started from TOP LEVEL (no foreign frame
;; on the stack); a handler suspends with call/1cc captured outside any foreign
;; frame; libuv callbacks only enqueue; the scheduler alternates draining the
;; run queue with (uv-run loop 'once).
(import (rnrs) (libuv)
        (only (chezscheme) printf call/1cc display-condition real-time collect
              bytevector-copy time))
(define (log! fmt . args) (apply printf fmt args) (flush-output-port (current-output-port)))
(define (show e) (call-with-string-output-port (lambda (p) (display-condition e p))))
(define (span->bv bv s e) (let ((o (make-bytevector (- e s)))) (bytevector-copy! bv s o 0 (- e s)) o))

(define loop (make-uv-loop))

;; ---- scheduler core -------------------------------------------------------
(define run-queue '())
(define (enqueue! thunk) (set! run-queue (append run-queue (list thunk))))
(define (dequeue!) (let ((x (car run-queue))) (set! run-queue (cdr run-queue)) x))
(define sched-k #f)
(define capture call/1cc)              ; swapped to call/cc for one timing variant
(define finished '())
(define (spawn! name thunk)
  (enqueue! (lambda ()
              (let ((v (thunk)))
                (set! finished (cons (cons name v) finished))
                (sched-k (list 'finished name))))))
;; suspend : ((any -> unspecified) -> unspecified) -> any
;; Captures the HANDLER's continuation (no foreign frame beneath it), hands the
;; registrar a resumer that only ENQUEUES, and jumps to the scheduler.
(define (suspend register!)
  (capture (lambda (k)
             (register! (lambda (v) (enqueue! (lambda () (k v)))))
             (sched-k 'suspended))))
(define dispatches 0)
(define (run-scheduler)
  (let sched ()
    (cond ((pair? run-queue)
           (let ((job (dequeue!)))
             (set! dispatches (+ dispatches 1))
             (call/1cc (lambda (k) (set! sched-k k) (job)))
             (sched)))
          ((uv-loop-alive? loop) (uv-run loop 'once) (sched))
          (else 'idle))))

;; ---- waiting primitives; callbacks only enqueue -----------------------------
(define (sleep-ms ms)
  (suspend (lambda (resume!)
             (let ((t (make-uv-timer loop)))
               (uv-timer-start! t (lambda (tm) (uv-close! t) (resume! (list 'timer ms))) ms 0)))))

;; per-stream inbox + waiter
(define inboxes '())   ; alist stream -> (inbox . waiter)
(define (slot s) (or (assq s inboxes) (let ((c (cons s (cons '() #f)))) (set! inboxes (cons c inboxes)) (cdr c))))
(define (deliver! s item)
  (let ((sl (slot s)))
    (if (cdr sl)
        (let ((w (cdr sl))) (set-cdr! sl #f) (w item))
        (set-car! sl (append (car sl) (list item))))))
(define (await-data s)
  (let ((sl (slot s)))
    (if (pair? (car sl))
        (let ((x (caar sl))) (set-car! sl (cdar sl)) x)
        (suspend (lambda (resume!) (set-cdr! sl resume!))))))
(define (start-reading! s)
  (uv-read-start! s
    (lambda (bv st en) (deliver! s (span->bv bv st en)))
    (lambda () (deliver! s 'eof))
    (lambda (err) (deliver! s (list 'error (show err))))))

;; ---- (a) timers, two coroutines interleaved ----------------------------------
(define trace '())
(define (trace! x) (set! trace (cons x trace)))
(spawn! 'A (lambda () (trace! 'A-start) (sleep-ms 60) (trace! 'A-woke) 'A-done))
(spawn! 'B (lambda () (trace! 'B-start) (sleep-ms 10) (trace! 'B-woke-1) (sleep-ms 10) (trace! 'B-woke-2) 'B-done))
(run-scheduler)
(log! "(a) trace: ~s\n" (reverse trace))
(log! "(a) finished: ~s dispatches so far: ~a\n" (reverse finished) dispatches)

;; ---- (b) TCP on-data wakeup with nested handler calls -------------------------
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define (level3 s) (trace! 'level3-await) (let ((bv (await-data s))) (trace! 'level3-resumed) (utf8->string bv)))
(define (level2 s) (string-append "L2<" (level3 s) ">"))
(define (level1 s) (string-append "L1<" (level2 s) ">"))
(uv-listen! server 128
  (lambda (err)
    (unless err
      (let ((peer (uv-accept! server)))
        (start-reading! peer)
        ;; the callback only ENQUEUES a coroutine; nothing runs here
        (spawn! 'peer-handler
          (lambda ()
            (let ((msg (level1 peer)))
              (trace! (list 'peer-got msg))
              (let ((reply (string->utf8 (string-append "echo:" msg))))
                (suspend (lambda (resume!) (uv-write! peer reply (lambda (e) (resume! (list 'written e))))))
                (uv-close! peer)
                msg)))))))
(define client (make-uv-tcp loop))
(spawn! 'client
  (lambda ()
    (let ((rc (suspend (lambda (resume!) (uv-tcp-connect! client "127.0.0.1" port (lambda (e) (resume! (list 'connected e))))))))
      (trace! rc)
      (start-reading! client)
      (uv-write! client (string->utf8 "hello") (lambda (e) #f))
      (let ((reply (utf8->string (await-data client))))
        (trace! (list 'client-got reply))
        (uv-close! client) (uv-close! server)
        reply))))
(set! trace '())
(run-scheduler)
(log! "(b) trace: ~s\n" (reverse trace))
(log! "(b) finished: ~s\n" (reverse finished))

;; ---- (c) cost of 10,000 suspend/resume cycles ---------------------------------
(define (cycles n)
  (let f ((i 0)) (if (< i n) (begin (suspend (lambda (resume!) (resume! i))) (f (+ i 1))) n)))
(define (time-it label thunk)
  (collect)
  (let ((t0 (real-time)))
    (thunk)
    (let ((dt (- (real-time) t0)))
      (log! "(c) ~a: ~a ms total, ~a us per cycle\n" label dt (/ (* dt 1000.) 10000)))))
(set! capture call/1cc)
(time-it "10,000 pure suspend/resume, call/1cc, no libuv" (lambda () (spawn! 'C1 (lambda () (cycles 10000))) (run-scheduler)))
(set! capture call/cc)
(time-it "10,000 pure suspend/resume, call/cc handler capture, no libuv" (lambda () (spawn! 'C2 (lambda () (cycles 10000))) (run-scheduler)))
(set! capture call/1cc)
(time-it "10,000 suspend/resume via a 0 ms timer each (make-timer + uv-run once + close)"
  (lambda () (spawn! 'C3 (lambda () (let f ((i 0)) (if (< i 10000) (begin (sleep-ms 0) (f (+ i 1))) i)))) (run-scheduler)))
(log! "(c) dispatches total: ~a\n" dispatches)
(guard (e (#t (log! "teardown RAISED: ~a\n" (show e)))) (uv-loop-teardown! loop))
(log! "teardown done; loop-open? ~s\n" (uv-loop-open? loop))
