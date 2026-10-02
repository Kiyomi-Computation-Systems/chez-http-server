#!r6rs
;;; M7.2, 2026-10-02: what a handler's wait costs, measured before the
;;; decision on the verbs a handler waits with (plan §14's M7.2).
;;;
;;; Every wait here is a one-shot resume cell (design §5.3, R4) on the real
;;; scheduler, (http-server private scheduler), whose poll is uv-run on a
;;; real loop: a coroutine hands `resume` to whoever will end its wait, and
;;; parks; `resume` wakes it once, and a second call is counted, never a
;;; second wake.
;;;
;;; PART 1, a wait alone: 10,000 coroutines, each parked on a cell that a
;;; call the drain makes resumes, beside 10,000 that end without waiting:
;;; bytes, CPU and real time per coroutine, all spawned at once and then
;;; one at a time.  A parked coroutine keeps the stack it parked on, so all
;;; at once, every one has a stack of its own, and one at a time, each can
;;; take the last one's.
;;;
;;; PART 2, `sleep`, three ways of waking a coroutine at a time:
;;;   wheel  the deadlines' wheel, (http-server wheel), at the default tick,
;;;          250 ms, one libuv timer ticking it while anything is armed, an
;;;          entry made for each sleep, as the shell keeps its deadlines;
;;;   timer  a libuv timer for each sleep, made, started, and closed as it
;;;          fires;
;;;   heap   one libuv timer, started for the earliest of a binary heap of
;;;          the sleeps' times.
;;; Each arms from the loop's time brought up to date (uv-update-time!), as
;;; the shell arms.  For each: 10,000 coroutines sleeping 1 ms at once,
;;; bytes, CPU and real time per sleep; the libuv handles the way adds once
;;; all are armed; and one coroutine sleeping 10 ms eight times in a row,
;;; how long each took.
;;;
;;; PART 3, `resolve`: uv-getaddrinfo! for "localhost", stream sockets only,
;;; awaited: 100 in a row, the time each took and the bytes per lookup; then
;;; 100 at once.
;;;
;;; PART 4, a deadline, the heap's way: a wait no one ends within 50 ms
;;; raises once its deadline passes; the resume that comes later is counted
;;; (R4) and wakes nothing.
;;;
;;; PART 5, a handler's own libuv callback: a wait whose resume a callback
;;; the handler gave chez-libuv would call, but which raises first; whether
;;; the coroutine ever ends.
;;;
;;; Run from the repository's root on the project's library path (`make
;;; run`'s): make run PROGRAM=.plans/research/spike/m7-waits.sps.
;;; m7-waits.sh runs it twice on the tree's scheduler, and twice on it
;;; patched by m7-scheduler-escape.patch: its coroutine ends on a raise
;;; through an exception handler that jumps to the drain, not a `guard`.
(import (rnrs)
        (only (chezscheme) statistics sstats-bytes collect collect-maximum-generation
              current-time time-second time-nanosecond scheme-version machine-type printf)
        (libuv)
        (http-server wheel)
        (http-server private scheduler))

(define loop (make-uv-loop))
(define s (make-scheduler (lambda (mode) (uv-run loop mode))))

;; What a coroutine raised, if any did: the spike's own failure.
(define raised '())
(define (on-end kind v) (when (eq? kind 'raised) (set! raised (cons v raised))))
(define (spawn! thunk) (scheduler-spawn! s thunk on-end))

;; run! : -> Void — turn until nothing is ready and nothing is left to poll.
(define (run!) (let lp () (when (scheduler-turn! s) (lp))))

(define (ns t) (+ (* 1000000000 (time-second t)) (time-nanosecond t)))
(define (now-ns) (ns (current-time 'time-monotonic)))
(define (cpu-ns) (ns (current-time 'time-process)))
(define (bytes) (sstats-bytes (statistics)))

;; measure : (-> Any) -> (values Nat Nat Nat)
;; Bytes allocated, CPU ns and real ns while `thunk` runs, after a full
;; collection.
(define (measure thunk)
  (collect (collect-maximum-generation))
  (let ((b0 (bytes)) (c0 (cpu-ns)) (r0 (now-ns)))
    (thunk)
    (let* ((r1 (now-ns)) (c1 (cpu-ns)) (b1 (bytes)))
      (values (- b1 b0) (- c1 c0) (- r1 r0)))))

;; report : String Nat (-> Any) -> Void
;; `thunk` run once to warm up, then measured, per one of `n`.
(define (report what n thunk)
  (thunk)
  (let-values (((b c r) (measure thunk)))
    (printf "  ~a: ~a B, ~a ns CPU, ~a ns real each (~a ms in all)\n"
            what (div b n) (div c n) (div r n) (div r 1000000))))

;; --- the wait ------------------------------------------------------------

;; A resume cell: the coroutine waiting, and whether it has been resumed.
(define-record-type cell (fields coroutine (mutable resumed?)))

;; Resumes that came after the first: R4's recorded faults.
(define late 0)

;; await : ((Any -> Void) -> Any) -> Any
;; Call `register!` with a one-shot resume, then park until it is called;
;; answer what it was called with.
(define (await register!)
  (let ((c (make-cell (current-coroutine) #f)))
    (register! (lambda (v)
                 (if (cell-resumed? c)
                     (set! late (+ late 1))
                     (begin (cell-resumed?-set! c #t)
                            (coroutine-wake! (cell-coroutine c) v)))))
    (coroutine-park!)))

;; --- PART 1 --------------------------------------------------------------

(define (part1 n)
  (define (waits-once)
    (await (lambda (resume) (scheduler-call! s (lambda () (resume #t))))))
  (printf "PART 1, a wait alone, ~a coroutines\n" n)
  (report "all at once, a coroutine that ends without waiting" n
          (lambda ()
            (do ((i 0 (+ i 1))) ((= i n)) (spawn! (lambda () #t)))
            (run!)))
  (report "all at once, a coroutine that waits once, resumed by a call the drain makes" n
          (lambda ()
            (do ((i 0 (+ i 1))) ((= i n)) (spawn! waits-once))
            (run!)))
  (report "one at a time, a coroutine that ends without waiting" n
          (lambda ()
            (do ((i 0 (+ i 1))) ((= i n)) (spawn! (lambda () #t)) (run!))))
  (report "one at a time, a coroutine that waits once, resumed by a call the drain makes" n
          (lambda ()
            (do ((i 0 (+ i 1))) ((= i n)) (spawn! waits-once) (run!)))))

;; --- PART 2: three sleeps --------------------------------------------------

;; timer: one libuv timer a sleep.
(define (sleep/timer ms)
  (await (lambda (resume)
           (uv-update-time! loop)
           (let ((t (make-uv-timer loop)))
             (uv-timer-start! t (lambda (t) (uv-close! t) (resume #t)) ms 0)))))

;; wheel: the deadlines' wheel at 250 ms, one timer ticking it while
;; anything is armed (the shell's start-ticking! and tick!).
(define wheel (make-wheel 250))
(define wheel-timer #f)
(define wheel-ticking? #f)
(define (wheel-tick! t)
  (for-each (lambda (resume) (resume #t)) (wheel-advance! wheel (uv-now loop)))
  (when (zero? (wheel-count wheel))
    (uv-timer-stop! wheel-timer)
    (set! wheel-ticking? #f)))
(define (sleep/wheel ms)
  (await (lambda (resume)
           (uv-update-time! loop)
           (wheel-arm! wheel (make-wheel-entry resume) (+ (uv-now loop) ms))
           (unless wheel-ticking?
             (if wheel-timer
                 (uv-timer-again! wheel-timer)
                 (begin (set! wheel-timer (make-uv-timer loop))
                        (uv-timer-start! wheel-timer wheel-tick! 250 250)))
             (set! wheel-ticking? #t)))))

;; heap: one libuv timer, started for the earliest of a binary heap.
(define-record-type hentry (fields deadline seq resume value))
(define heap (make-vector 1024 #f))
(define heap-n 0)
(define heap-seq 0)
(define heap-timer #f)
(define (before? a b)
  (or (< (hentry-deadline a) (hentry-deadline b))
      (and (= (hentry-deadline a) (hentry-deadline b)) (< (hentry-seq a) (hentry-seq b)))))
(define (heap-push! e)
  (when (= heap-n (vector-length heap))
    (let ((v (make-vector (* 2 heap-n) #f)))
      (do ((i 0 (+ i 1))) ((= i heap-n)) (vector-set! v i (vector-ref heap i)))
      (set! heap v)))
  (let up ((i heap-n))
    (if (= i 0)
        (vector-set! heap 0 e)
        (let* ((p (div (- i 1) 2)) (pe (vector-ref heap p)))
          (if (before? e pe)
              (begin (vector-set! heap i pe) (up p))
              (vector-set! heap i e)))))
  (set! heap-n (+ heap-n 1)))
(define (heap-pop!)
  (let ((top (vector-ref heap 0)))
    (set! heap-n (- heap-n 1))
    (let ((last (vector-ref heap heap-n)))
      (vector-set! heap heap-n #f)
      (when (> heap-n 0)
        (let down ((i 0))
          (let* ((l (+ (* 2 i) 1)) (r (+ l 1))
                 (c (cond ((>= l heap-n) #f)
                          ((and (< r heap-n) (before? (vector-ref heap r) (vector-ref heap l))) r)
                          (else l))))
            (if (and c (before? (vector-ref heap c) last))
                (begin (vector-set! heap i (vector-ref heap c)) (down c))
                (vector-set! heap i last))))))
    top))
(define (heap-fire! t)
  (let ((now (uv-now loop)))
    (let lp ()
      (when (and (> heap-n 0) (<= (hentry-deadline (vector-ref heap 0)) now))
        (let ((e (heap-pop!))) ((hentry-resume e) (hentry-value e)))
        (lp)))
    (when (> heap-n 0)
      (uv-timer-start! heap-timer heap-fire! (- (hentry-deadline (vector-ref heap 0)) now) 0))))
;; heap-arm! : Nat (Any -> Void) Any -> Void — `(resume value)` in `ms`.
(define (heap-arm! ms resume value)
  (uv-update-time! loop)
  (let ((e (make-hentry (+ (uv-now loop) ms) heap-seq resume value)))
    (set! heap-seq (+ heap-seq 1))
    (heap-push! e)
    (when (eq? (vector-ref heap 0) e)
      (unless heap-timer (set! heap-timer (make-uv-timer loop)))
      (uv-timer-start! heap-timer heap-fire! ms 0))))
(define (sleep/heap ms)
  (await (lambda (resume) (heap-arm! ms resume #t))))

(define (part2 n)
  (printf "PART 2, sleep, ~a coroutines sleeping 1 ms at once\n" n)
  (for-each
   (lambda (way)
     (let ((sleep (cdr way)))
       (report (car way) n
               (lambda ()
                 (do ((i 0 (+ i 1))) ((= i n)) (spawn! (lambda () (sleep 1))))
                 (run!)))
       (let ((before (length (uv-loop-live-handles loop))) (open #f))
         (do ((i 0 (+ i 1))) ((= i n)) (spawn! (lambda () (sleep 1))))
         (spawn! (lambda () (set! open (length (uv-loop-live-handles loop)))))
         (run!)
         (printf "    libuv handles it adds, once all are armed: ~a\n" (- open before)))
       (let ((took '()))
         (spawn! (lambda ()
                   (do ((i 0 (+ i 1))) ((= i 8))
                     (let ((t0 (now-ns)))
                       (sleep 10)
                       (set! took (cons (div (- (now-ns) t0) 100000) took))))))
         (run!)
         (printf "    8 sleeps of 10 ms in a row, each took (0.1 ms): ~a\n" (reverse took)))))
   (list (cons "wheel" sleep/wheel) (cons "timer" sleep/timer) (cons "heap" sleep/heap))))

;; --- PART 3: resolve -------------------------------------------------------

;; resolve : String -> (Listof String)
(define (resolve host)
  (let ((r (await (lambda (resume)
                    (uv-getaddrinfo! loop host #f '((socktype . stream))
                                     (lambda (err results) (resume (cons err results))))))))
    (if (car r) (raise (car r)) (map uv-addrinfo-address (cdr r)))))

(define (median xs)
  (let ((v (list->vector (list-sort < xs))))
    (vector-ref v (div (vector-length v) 2))))

(define (part3 n)
  (printf "PART 3, resolve \"localhost\"\n")
  (let ((answer #f))
    (spawn! (lambda () (set! answer (resolve "localhost"))))
    (run!)
    (printf "  answers ~s\n" answer))
  (let ((took '()))
    (let-values (((b c r) (measure (lambda ()
                                     (spawn! (lambda ()
                                               (do ((i 0 (+ i 1))) ((= i n))
                                                 (let ((t0 (now-ns)))
                                                   (resolve "localhost")
                                                   (set! took (cons (div (- (now-ns) t0) 1000) took))))))
                                     (run!)))))
      (printf "  ~a in a row: ~a B, ~a ns CPU each; each took ~a to ~a us, median ~a\n"
              n (div b n) (div c n) (apply min took) (apply max took) (median took))))
  (let-values (((b c r) (measure (lambda ()
                                   (do ((i 0 (+ i 1))) ((= i n)) (spawn! (lambda () (resolve "localhost"))))
                                   (run!)))))
    (printf "  ~a at once: ~a B, ~a ns CPU each; ~a us in all\n" n (div b n) (div c n) (div r 1000))))

;; --- PART 4: a deadline ------------------------------------------------------

;; The wait in progress, PART 4's one coroutine's, and the token a passed
;; deadline resumes it with.
(define current-resume #f)
(define deadline-token (list 'deadline))
(define (await/deadline register!)
  (let ((v (await (lambda (resume) (set! current-resume resume) (register! resume)))))
    (set! current-resume #f)
    (if (eq? v deadline-token) (raise 'deadline-passed) v)))
(define (with-deadline ms thunk)
  (heap-arm! ms (lambda (v) (when current-resume (current-resume deadline-token))) #f)
  (thunk))

(define (part4)
  (printf "PART 4, a deadline of 50 ms around a wait no one ends in time\n")
  (let ((held #f) (outcome #f) (ends 0) (late0 late))
    (scheduler-spawn! s
      (lambda ()
        (let ((t0 (now-ns)))
          (guard (e ((eq? e 'deadline-passed)
                     (set! outcome (list 'raised-after-0.1ms (div (- (now-ns) t0) 100000)))))
            (with-deadline 50 (lambda () (await/deadline (lambda (resume) (set! held resume)))))
            (set! outcome 'returned))))
      (lambda (kind v) (set! ends (+ ends 1))))
    (run!)
    (held 'the-answer-come-late)
    (run!)
    (printf "  outcome ~s; the coroutine ended ~a time(s); late resumes counted ~a\n"
            outcome ends (- late late0))))

;; --- PART 5: a handler's own callback ------------------------------------

(define (part5)
  (printf "PART 5, a wait whose resume the handler's own libuv callback calls, after it raises\n")
  (let ((ended #f))
    (scheduler-spawn! s
      (lambda ()
        (await (lambda (resume)
                 (let ((t (make-uv-timer loop)))
                   (uv-timer-start! t
                                    (lambda (t) (uv-close! t) (vector-ref (vector) 0) (resume #t))
                                    1 0)))))
      (lambda (kind v) (set! ended kind)))
    (let ((e (guard (e (#t e)) (run!) #f)))
      (printf "  uv-run raised: ~a; uv-callback-error? ~a\n"
              (and e (condition? e)) (and e (uv-callback-error? e))))
    (run!)
    (printf "  once the loop has run on, the coroutine has ended: ~s\n" (and ended #t))))

(printf "~a, ~a\n" (scheme-version) (machine-type))
(part1 10000)
(part2 10000)
(part3 100)
(part4)
(part5)
(unless (null? raised) (printf "SPIKE FAILURE: coroutines raised ~s\n" raised))
(uv-loop-teardown! loop)
