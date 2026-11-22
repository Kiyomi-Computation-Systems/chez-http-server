#!r6rs
;;; await-outside, 2026-11-22: what an outside wait costs, measured on the
;;; tree once decision 0039's verb is built (issue #260 §8.4), as decision
;;; 0015 measured `await` with m7-waits.sps.
;;;
;;; Every wait here is the tree's own: (http-server private waits)'s `await`
;;; and `await-outside`, on the real scheduler, (http-server private
;;; scheduler), whose poll is uv-run on a real loop.  The scheduler and its
;;; waits are a shell's, made by make-shell on the loop, so the inbox opener
;;; is the one loop-outside! gives the waits, not a copy: an async handle an
;;; inbox, whose callback delivers, and a wake that is async-sent?.  The
;;; inbox is opened by the first outside wait of PART 1's first warm-up, and
;;; stays open through every figure of PARTS 1 and 2.
;;;
;;; PART 1, bytes and CPU a wait: 10,000 coroutines, each waiting once, all
;;; spawned at once and then one at a time, as m7-waits.sps PART 1:
;;;   await               resumed by a call the drain makes, as m7-waits
;;;                       does;
;;;   await-outside (i)   resumed by a call the drain makes, on the loop's
;;;                       thread: the post and the wake there, the delivery
;;;                       in the poll that follows;
;;;   await-outside (ii)  resumed by one worker thread made by fork-thread,
;;;                       which takes each resume from a mailbox of the
;;;                       spike's, a mutex, a condition and a queue, where
;;;                       `register` puts it.
;;; Bytes are the delta of Chez's cumulative count, (sstats-bytes
;;; (statistics)), as m7-waits reads it, not bytes-allocated, which falls
;;; at a collection; it counts every thread's allocation, so (ii)'s include
;;; the worker's.  A reading itself allocates 160 B, once a window.  CPU is counted three ways:
;;; the process's (`time-process`: every thread, the collector's included),
;;; the loop's thread's own (`time-thread`), and for (ii) the worker's own,
;;; which it reads itself when asked through its mailbox, outside the
;;; window.  Each figure is a run after one to warm up, as m7-waits's are.
;;; Then the first outside wait on a fresh shell's loop, which opens an
;;; inbox, five times: its bytes beside a wait once one is open.
;;;
;;; Two changes to m7-waits's way of turning, both forced by the inbox's
;;; async handle, which keeps the loop alive while it is open, so that a
;;; turn whose drain ends the last coroutine then blocks in its poll for
;;; ever.  The end that brings the count to the run's target starts a 0 ms
;;; timer of the spike's, one a loop, once a run, so that poll returns.  And
;;; one at a time, each coroutine's end, in the drain, spawns the next,
;;; where m7-waits spawned one, turned until it ended, and spawned the next;
;;; so a wait that needs no poll, `await`'s, takes no turn here, and its
;;; figures one at a time are not m7-waits's.  The figures to compare are
;;; this spike's own, against its own coroutines that end without waiting.
;;;
;;; PART 2, resume to run: a worker reads the monotonic clock and calls
;;; `resume` with what it read; the coroutine reads the clock again once it
;;; runs, and the difference is a sample.  At rest: one wait at a time, the
;;; worker napping 1 ms before it reads, so the loop is asleep in its poll,
;;; 2,000 samples.  Under load: 8 workers, 256 coroutines each waiting 200
;;; times in a row, coroutine i's resume handed to worker i mod 8, which
;;; posts it as soon as it takes it: 51,200 samples; and 8 coroutines, one
;;; a worker, 1,000 times each.  The median, the 99th percentile and the
;;; extremes, and the loop's turns.
;;;
;;; PART 3, an idle open inbox: a shell listening on 127.0.0.1:0, its loop
;;; turned as serve turns it (shell-run-turns!), over a 1 s window that a
;;; libuv timer of the spike's ends, with no inbox, and with one opened by
;;; an outside wait done before the window: the turns taken, the bytes, and
;;; the CPU of the loop's thread and of the process.  Asleep, nothing else
;;; on the loop; and ticking, a 1 ms timer of the spike's turning it about
;;; 1,000 times, for a cost a turn.  Each twice, in the order none, open,
;;; open, none; each window's timers armed from the loop's time brought up
;;; to date, as the shell arms.
;;;
;;; PART 4, one GET through the whole server: tests/test-clients.sps's
;;; method, copied here: a server of its own (start-server), its handler
;;; answering one response made once, sent oha's 2,000 and then 7,000 GETs
;;; on one connection kept alive, its loop turned as serve turns it; the
;;; bytes over the two runs differ by what 5,000 GETs cost.  Without an
;;; inbox, and with one opened before oha starts, by an outside wait on the
;;; server's loop; each twice, alternating.
;;;
;;; Run from the repository's root on the project's library path:
;;; outside-waits.sh runs it twice, with the platform and the load average.
(import (rnrs)
        (only (chezscheme) statistics sstats-bytes collect collect-maximum-generation
              current-time time-second time-nanosecond scheme-version machine-type printf format
              fork-thread thread-join make-mutex mutex-acquire mutex-release make-condition
              condition-wait condition-signal make-time sleep iota getenv)
        (libuv) (uv-testing) (shell-testing)
        (only (http-server) make-response)
        (only (http-server limits) default-limits)
        (only (http-server private shell) make-shell shell-scheduler shell-listen! shell-shutdown!
              shell-run-turns! wall-clock)
        (only (http-server private serve) start-server)
        (only (http-server private scheduler) scheduler-spawn! scheduler-call! scheduler-turn!)
        (only (http-server private waits) await await-outside)
        (only (corpus-text) find-sub trim))

(define (b s) (string->utf8 s))

;; say : String Any ... -> Void — printf, flushed, so a run piped to a
;; file shows how far it has come.
(define (say . args) (apply printf args) (flush-output-port (current-output-port)))

(define (ns t) (+ (* 1000000000 (time-second t)) (time-nanosecond t)))
(define (now-ns) (ns (current-time 'time-monotonic)))
(define (cpu-ns) (ns (current-time 'time-process)))
(define (thread-ns) (ns (current-time 'time-thread)))
(define (bytes) (sstats-bytes (statistics)))

;; nap : Nat -> Void — this thread asleep `ms` milliseconds.
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))

;; loadavg : -> String — /proc/loadavg's first three fields, or "?".
(define (loadavg)
  (guard (e (#t "?"))
    (let* ((line (call-with-input-file "/proc/loadavg" get-line))
           (i (let skip ((i 0) (spaces 0))
                (cond ((= i (string-length line)) i)
                      ((char=? (string-ref line i) #\space)
                       (if (= spaces 2) i (skip (+ i 1) (+ spaces 1))))
                      (else (skip (+ i 1) spaces))))))
      (substring line 0 i))))

;; --- between threads ---------------------------------------------------------

;; A mailbox: a queue under a mutex, with a condition its one taker waits
;; on, and whether it is closed.  Taken with mutex-acquire and -release, not
;; with-mutex, so the spike's own hand-over allocates only its pair.
(define-record-type mailbox
  (fields mutex changed (mutable front) (mutable back) (mutable closed?))
  (protocol (lambda (new) (lambda () (new (make-mutex) (make-condition) '() '() #f)))))

;; mailbox-put! : Mailbox Any -> Void
(define (mailbox-put! mb x)
  (let ((m (mailbox-mutex mb)))
    (mutex-acquire m)
    (mailbox-back-set! mb (cons x (mailbox-back mb)))
    (condition-signal (mailbox-changed mb))
    (mutex-release m)))

;; mailbox-take! : Mailbox -> Any — the oldest item, waiting for one; #f
;; once the mailbox is closed and empty.
(define (mailbox-take! mb)
  (let ((m (mailbox-mutex mb)))
    (mutex-acquire m)
    (let wait ()
      (when (and (null? (mailbox-front mb)) (pair? (mailbox-back mb)))
        (mailbox-front-set! mb (reverse (mailbox-back mb)))
        (mailbox-back-set! mb '()))
      (cond ((pair? (mailbox-front mb))
             (let ((x (car (mailbox-front mb))))
               (mailbox-front-set! mb (cdr (mailbox-front mb)))
               (mutex-release m)
               x))
            ((mailbox-closed? mb) (mutex-release m) #f)
            (else (condition-wait (mailbox-changed mb) m) (wait))))))

;; mailbox-close! : Mailbox -> Void
(define (mailbox-close! mb)
  (let ((m (mailbox-mutex mb)))
    (mutex-acquire m)
    (mailbox-closed?-set! mb #t)
    (condition-signal (mailbox-changed mb))
    (mutex-release m)))

;; Resumes a worker called that did not answer #t, counted by each worker
;; and summed once it is joined.
(define refused 0)

;; start-worker : Mailbox (-> Any) -> (-> Void)
;; A thread taking jobs from `mb` until it is closed: a resume, called with
;; what `(value)` answers then, or `(cpu . reply)`, answered by putting its
;; own thread's CPU ns in `reply`.  Answers a join, which adds its refusals
;; to `refused`.
(define (start-worker mb value)
  (let* ((mine 0)
         (t (fork-thread
             (lambda ()
               (let next ()
                 (let ((job (mailbox-take! mb)))
                   (when job
                     (if (pair? job)
                         (mailbox-put! (cdr job) (thread-ns))
                         (unless (eq? (job (value)) #t) (set! mine (+ mine 1))))
                     (next))))))))
    (lambda () (mailbox-close! mb) (thread-join t) (set! refused (+ refused mine)))))

;; worker-cpu : Mailbox -> Nat — the CPU ns of the worker taking from `mb`.
(define (worker-cpu mb)
  (let ((reply (make-mailbox)))
    (mailbox-put! mb (cons 'cpu reply))
    (mailbox-take! reply)))

;; --- a loop, a shell on it, and coroutines on its scheduler ---------------------

;; What any shell here logged, newest first: a late resume would be here.
(define logged '())
(define (log! what details) (set! logged (cons (cons what details) logged)))

;; open-shell : UvLoop -> Shell — a shell on `loop`, not listening, whose
;; scheduler keeps the loop's waits with the shell's own opener.
(define (open-shell loop) (make-shell loop (lambda (r) #f) default-limits wall-clock log!))

(define loop (make-uv-loop))
(define sh (open-shell loop))
(define s (shell-scheduler sh))

;; Coroutines ended, what any raised, and the turns taken; the count a
;; run ends at, the stopper of the loop it runs on, and what spawns the
;; next coroutine when one ends, or #f.
(define ended 0)
(define raised '())
(define turns 0)
(define target 0)
(define stopper #f)
(define chain #f)
(define (on-end kind v)
  (set! ended (+ ended 1))
  (when (eq? kind 'raised) (set! raised (cons v raised)))
  (if (>= ended target)
      (uv-timer-start! stopper (lambda (t) #f) 0 0)
      (when chain (chain))))
(define (spawn! s thunk) (scheduler-spawn! s thunk on-end))

;; Each loop's stopper: a timer, started for 0 ms by the end that brings
;; `ended` to `target`, so the poll of that turn returns.
(define stoppers (make-eq-hashtable))
(define (stopper-of l)
  (or (hashtable-ref stoppers l #f)
      (let ((t (make-uv-timer l))) (hashtable-set! stoppers l t) t)))

;; run-until! : Scheduler UvLoop Nat -> Void
;; Turn `s`, whose loop is `l`, until `n` coroutines have ended.
(define (run-until! s l n)
  (set! target n)
  (set! stopper (stopper-of l))
  (let lp () (unless (>= ended n) (scheduler-turn! s) (set! turns (+ turns 1)) (lp))))

;; asyncs : UvLoop -> Nat — the async handles live on `loop`.
(define (asyncs loop) (length (filter uv-async? (uv-loop-live-handles loop))))

;; --- PART 1 --------------------------------------------------------------------

;; measure : (-> Any) (U Mailbox #f) -> (values Int Nat Nat (U Nat #f) Nat Nat)
;; Bytes allocated, process CPU ns, the loop's thread's CPU ns, the worker's
;; CPU ns if `mb` names one, real ns and turns while `thunk` runs, after a
;; full collection.
(define (measure thunk mb)
  (collect (collect-maximum-generation))
  (let* ((w0 (and mb (worker-cpu mb)))
         (u0 turns) (b0 (bytes)) (c0 (cpu-ns)) (t0 (thread-ns)) (r0 (now-ns)))
    (thunk)
    (let* ((r1 (now-ns)) (t1 (thread-ns)) (c1 (cpu-ns)) (b1 (bytes)) (u1 turns)
           (w1 (and mb (worker-cpu mb))))
      (values (- b1 b0) (- c1 c0) (- t1 t0) (and mb (- w1 w0)) (- r1 r0) (- u1 u0)))))

;; report : String Nat (-> Any) (U Mailbox #f) -> Void
;; `thunk` run once to warm up, then measured, per one of `n`.
(define (report what n thunk mb)
  (thunk)
  (let-values (((b c t w r u) (measure thunk mb)))
    (say "  ~a: ~a B, ~a ns CPU process, ~a ns CPU loop's thread~a, ~a ns real each (~a ms in all, ~a turns)\n"
            what (div b n) (div c n) (div t n)
            (if w (format ", ~a ns CPU worker's thread" (div w n)) "")
            (div r n) (div r 1000000) u)))

(define (part1 n)
  (define (none) #t)
  (define (waits/await)
    (await (lambda (resume) (scheduler-call! s (lambda () (resume #t))))))
  (define (waits/outside-loop)
    (await-outside (lambda (resume)
                     (scheduler-call! s (lambda () (unless (eq? (resume #t) #t) (set! refused (+ refused 1))))))))
  (define jobs (make-mailbox))
  (define join! (start-worker jobs (lambda () #t)))
  (define (waits/outside-worker)
    (await-outside (lambda (resume) (mailbox-put! jobs resume))))
  (define (all-at-once body)
    (lambda () (set! ended 0) (do ((i 0 (+ i 1))) ((= i n)) (spawn! s body)) (run-until! s loop n)))
  (define (one-at-a-time body)
    (lambda ()
      (set! ended 0)
      (set! chain (lambda () (spawn! s body)))
      (spawn! s body)
      (run-until! s loop n)
      (set! chain #f)))
  (say "PART 1, a wait alone, ~a coroutines (load ~a)\n" n (loadavg))
  (report "all at once, none waiting" n (all-at-once none) #f)
  (report "all at once, await, resumed by a call the drain makes" n (all-at-once waits/await) #f)
  (report "all at once, await-outside (i), resumed by a call the drain makes" n (all-at-once waits/outside-loop) #f)
  (report "all at once, await-outside (ii), resumed by one worker thread" n (all-at-once waits/outside-worker) jobs)
  (report "one at a time, none waiting" n (one-at-a-time none) #f)
  (report "one at a time, await, resumed by a call the drain makes" n (one-at-a-time waits/await) #f)
  (report "one at a time, await-outside (i), resumed by a call the drain makes" n (one-at-a-time waits/outside-loop) #f)
  (report "one at a time, await-outside (ii), resumed by one worker thread" n (one-at-a-time waits/outside-worker) jobs)
  (join!)
  (say "  async handles on the loop: ~a; resumes that did not answer #t: ~a\n" (asyncs loop) refused))

;; first-outside : -> (values Int Nat)
;; On a fresh loop and a shell on it, one coroutine's outside wait, resumed
;; by a call the drain makes: the bytes from the spawn to its end, and the
;; async handles live after.  The loop is torn down after.
(define (first-outside)
  (let* ((l (make-uv-loop)) (fresh (shell-scheduler (open-shell l))))
    (stopper-of l)
    (collect (collect-maximum-generation))
    (set! ended 0)
    (let ((b0 (bytes)))
      (spawn! fresh (lambda () (await-outside (lambda (resume) (scheduler-call! fresh (lambda () (resume #t)))))))
      (run-until! fresh l 1)
      (let* ((b1 (bytes)) (live (asyncs l)))
        (uv-loop-teardown! l)
        (values (- b1 b0) live)))))

(define (part1-open)
  (say "PART 1b, the first outside wait on a fresh shell's loop, which opens its inbox\n")
  (do ((i 0 (+ i 1))) ((= i 5))
    (let-values (((bs live) (first-outside)))
      (say "  fresh loop ~a: ~a B, one at a time (i); async handles after: ~a\n" (+ i 1) bs live))))

;; --- PART 2 --------------------------------------------------------------------

(define (pct v p) (vector-ref v (min (- (vector-length v) 1) (exact (floor (* p (vector-length v)))))))
(define (us x) (/ (round (/ x 100)) 10.))

;; summary : String (Listof Nat) -> Void
(define (summary what samples)
  (let ((v (list->vector (list-sort < samples))))
    (say "  ~a: ~a samples; median ~a us, 99th percentile ~a us; min ~a us, max ~a us\n"
            what (vector-length v) (us (pct v 1/2)) (us (pct v 99/100))
            (us (vector-ref v 0)) (us (vector-ref v (- (vector-length v) 1))))))

;; clock-cost : -> Nat — the median ns between two monotonic readings in a
;; row, over 10,000.
(define (clock-cost)
  (let ((v (make-vector 10000 0)))
    (do ((i 0 (+ i 1))) ((= i 10000))
      (let* ((a (now-ns)) (z (now-ns))) (vector-set! v i (- z a))))
    (vector-sort! < v)
    (vector-ref v 5000)))

(define (at-rest k)
  (let* ((jobs (make-mailbox))
         (join! (start-worker jobs (lambda () (nap 1) (now-ns))))
         (samples '())
         (u0 turns))
    (set! ended 0)
    (spawn! s (lambda ()
                (do ((i 0 (+ i 1))) ((= i k))
                  (let ((posted (await-outside (lambda (resume) (mailbox-put! jobs resume)))))
                    (set! samples (cons (- (now-ns) posted) samples))))))
    (run-until! s loop 1)
    (join!)
    (summary "at rest, one wait at a time, the worker napping 1 ms first" samples)
    (say "    turns: ~a, ~a a sample\n" (- turns u0) (/ (round (* 100 (/ (- turns u0) k))) 100.))))

(define (under-load workers waits rounds)
  (let* ((boxes (list->vector (map (lambda (k) (make-mailbox)) (iota workers))))
         (joins (map (lambda (k) (start-worker (vector-ref boxes k) now-ns)) (iota workers)))
         (samples '())
         (u0 turns)
         (r0 (now-ns)))
    (set! ended 0)
    (do ((i 0 (+ i 1))) ((= i waits))
      (let ((box (vector-ref boxes (mod i workers))))
        (spawn! s (lambda ()
                    (do ((j 0 (+ j 1))) ((= j rounds))
                      (let ((posted (await-outside (lambda (resume) (mailbox-put! box resume)))))
                        (set! samples (cons (- (now-ns) posted) samples))))))))
    (run-until! s loop waits)
    (let ((r (- (now-ns) r0)) (u (- turns u0)))
      (for-each (lambda (j) (j)) joins)
      (summary (format "under load, ~a workers posting to ~a waits, ~a rounds" workers waits rounds) samples)
      (say "    ~a ms in all, ~a posts a second; turns: ~a, ~a values a turn\n"
              (div r 1000000) (div (* (length samples) 1000000000) r) u
              (/ (round (* 10 (/ (length samples) u))) 10.)))))

(define (part2)
  (say "PART 2, resume to run (load ~a)\n" (loadavg))
  (say "  two monotonic readings in a row, the median of 10,000: ~a ns\n" (clock-cost))
  (at-rest 2000)
  (under-load 8 256 200)
  (under-load 8 8 1000)
  (say "  async handles on the loop: ~a; resumes that did not answer #t: ~a\n" (asyncs loop) refused))

;; --- PART 3 --------------------------------------------------------------------

;; idle-rig : Boolean -> (Pair UvLoop Shell)
;; A loop of its own and a shell on it listening on 127.0.0.1:0; with
;; `open?`, one outside wait done on it first, resumed by a call the drain
;; makes, so its inbox is open and nothing is posted.
(define (idle-rig open?)
  (let* ((l (make-uv-loop)) (shell (open-shell l)) (sc (shell-scheduler shell)))
    (shell-listen! shell "127.0.0.1" 0)
    (stopper-of l)
    (when open?
      (set! ended 0)
      (spawn! sc (lambda () (await-outside (lambda (resume) (scheduler-call! sc (lambda () (resume #t)))))))
      (run-until! sc l 1))
    (cons l shell)))

;; window : (Pair UvLoop Shell) Nat Boolean -> Void
;; The rig's loop turned as serve turns it until a timer of `ms` fires, a
;; 1 ms ticker turning it too if `tick?`: what was taken, printed.
(define (window rig ms tick? what)
  (let* ((l (car rig)) (shell (cdr rig))
         (fired #f) (n 0)
         (stop (make-uv-timer l))
         (ticker (and tick? (make-uv-timer l)))
         (live (asyncs l)))
    (collect (collect-maximum-generation))
    (let ((b0 (bytes)) (c0 (cpu-ns)) (t0 (thread-ns)) (r0 (now-ns)))
      (uv-update-time! l)
      (uv-timer-start! stop (lambda (t) (set! fired #t)) ms 0)
      (when ticker (uv-timer-start! ticker (lambda (t) #f) 1 1))
      (shell-run-turns! shell (lambda () (set! n (+ n 1)) (not fired)))
      (let* ((r1 (now-ns)) (t1 (thread-ns)) (c1 (cpu-ns)) (b1 (bytes)))
        (uv-close! stop)
        (when ticker (uv-timer-stop! ticker) (uv-close! ticker))
        (uv-run l 'nowait)
        (say "  ~a, async handles ~a: ~a turns in ~a ms; ~a B, ~a us CPU loop's thread, ~a us CPU process~a\n"
                what live n (div (- r1 r0) 1000000) (- b1 b0) (div (- t1 t0) 1000) (div (- c1 c0) 1000)
                (if (> n 1)
                    (format "; a turn: ~a B, ~a ns CPU loop's thread" (div (- b1 b0) n) (div (- t1 t0) n))
                    ""))))))

(define (part3)
  (say "PART 3, an idle open inbox, a 1 s window (load ~a)\n" (loadavg))
  (let ((none (idle-rig #f)) (open (idle-rig #t)))
    (window none 1000 #f "asleep, no inbox")
    (window open 1000 #f "asleep, an inbox open")
    (window open 1000 #f "asleep, an inbox open")
    (window none 1000 #f "asleep, no inbox")
    (window none 1000 #t "ticking, no inbox")
    (window open 1000 #t "ticking, an inbox open")
    (window open 1000 #t "ticking, an inbox open")
    (window none 1000 #t "ticking, no inbox")
    (uv-loop-teardown! (car none))
    (uv-loop-teardown! (car open))))

;; --- PART 4: tests/test-clients.sps's GET, copied ---------------------------

(define cap 20000)
(define oha-cap 25000)
(define oha (let ((v (getenv "OHA"))) (if (and v (not (string=? v ""))) v "build/oha")))

(define (env . pairs)
  (lambda (name) (let ((p (assoc name pairs))) (and p (cdr p)))))

(define-record-type child
  (fields process pipe out (mutable exit) (mutable ended?)))

;; spawn-child : UvLoop String (Listof String) -> Child — test-clients's
;; spawn, its standard input empty and its output collected.
(define (spawn-child loop file args)
  (let ((pipe (make-uv-pipe loop)) (out (make-byte-collector)) (c #f))
    (let ((process (uv-spawn! loop file (cons file args)
                              (list (cons 'stdio (list 'ignore (list 'pipe pipe 'from-child) '(inherit-fd . 2))))
                              (lambda (status signal) (child-exit-set! c (list status signal))))))
      (set! c (make-child process pipe out #f #f))
      (uv-read-start! pipe
                      (lambda (bv start end) (collect-span! out bv start end))
                      (lambda () (child-ended?-set! c #t))
                      (lambda (e) (child-ended?-set! c #t)))
      c)))

(define (json-string s i)
  (let loop ((i i) (acc '()))
    (let ((c (string-ref s i)))
      (cond ((char=? c #\") (values (list->string (reverse acc)) (+ i 1)))
            ((char=? c #\\) (loop (+ i 2) (cons (string-ref s (+ i 1)) acc)))
            (else (loop (+ i 1) (cons c acc)))))))

(define (oha-tally text key)
  (let ((at (find-sub text (string-append "\"" key "\":"))))
    (and at
         (let next ((i (+ at (string-length key) 3)) (acc '()))
           (let ((c (string-ref text i)))
             (cond ((char=? c #\}) (reverse acc))
                   ((char=? c #\")
                    (let-values (((name j) (json-string text (+ i 1))))
                      (let* ((start (let skip ((j j))
                                      (if (memv (string-ref text j) '(#\: #\space #\newline)) (skip (+ j 1)) j)))
                             (end (let digits ((k start))
                                    (if (char-numeric? (string-ref text k)) (digits (+ k 1)) k))))
                        (next end (cons (cons name (string->number (substring text start end))) acc)))))
                   (else (next (+ i 1) acc))))))))

;; allocated-over : UvLoop Shell String Nat -> (List Nat Tally) — test-clients's.
(define (allocated-over loop sh url n)
  (collect)
  (let* ((b0 (sstats-bytes (statistics)))
         (c (spawn-child loop oha (list "--no-tui" "--output-format" "json" "-t" "5s"
                                        "-n" (number->string n) "-c" "1" url)))
         (turns 0))
    (shell-run-turns! sh (lambda ()
                           (set! turns (+ turns 1))
                           (and (< turns oha-cap) (not (and (child-exit c) (child-ended? c))))))
    (let ((b1 (sstats-bytes (statistics))))
      (unless (child-exit c)
        (uv-process-kill! (child-process c) 'sigkill)
        (run-shell-until loop sh (lambda () (child-exit c)) cap))
      (uv-close! (child-process c))
      (when (uv-handle-open? (child-pipe c)) (uv-close! (child-pipe c)))
      (list (- b1 b0) (oha-tally (utf8->string (collector-bytes (child-out c))) "statusCodeDistribution")))))

;; measured-get : (Request -> Answer) Boolean -> (List Rational Tally Tally (Listof UvHandle) Nat)
;; test-clients's, with `open?` opening an inbox on the server's loop
;; first, by an outside wait resumed by a call the drain makes: what a GET
;; costs, the two runs' responses by status, what is left on the loop once
;; the server has shut down, and the async handles live while oha ran.
(define (measured-get handler open?)
  (let* ((aloop (make-uv-loop))
         (alogged '())
         (ash (start-server aloop handler (env '("CHEZ_HTTP_PORT" . "0"))
                            (lambda (what details) (set! alogged (append alogged (list (cons what details)))))))
         (aurl (string-append "http://127.0.0.1:" (number->string (caddr (assq 'listening alogged))) "/")))
    (when open?
      (let ((sc (shell-scheduler ash)))
        (set! ended 0)
        (spawn! sc (lambda () (await-outside (lambda (resume) (scheduler-call! sc (lambda () (resume #t)))))))
        (run-until! sc aloop 1)
        (uv-close! (stopper-of aloop))))
    (let* ((live (asyncs aloop))
           (small (allocated-over aloop ash aurl 2000))
           (large (allocated-over aloop ash aurl 7000)))
      (shell-shutdown! ash)
      (run-until-drained aloop cap)
      (let ((left (uv-loop-live-handles aloop)))
        (uv-loop-teardown! aloop)
        (list (/ (- (car large) (car small)) 5000) (cadr small) (cadr large) left live)))))

(define (part4)
  (say "PART 4, a GET through the whole server, one connection kept alive (load ~a)\n" (loadavg))
  (let ((ok (make-response 200 #f '() (b "ok"))))
    (for-each
     (lambda (open?)
       (let ((r (measured-get (lambda (req) ok) open?)))
         (say "  ~a, async handles ~a: a GET allocates ~a B; answered ~s ~s; left ~a handles\n"
                 (if open? "an inbox open" "no inbox") (list-ref r 4)
                 (/ (round (* 10 (car r))) 10.) (cadr r) (caddr r) (length (cadddr r)))))
     '(#f #t #f #t))))

;; --- the run -------------------------------------------------------------------

(say "~a, ~a; libuv ~a\n" (scheme-version) (machine-type) (uv-version))
(part1 10000)
(part1-open)
(part2)
(part3)
(part4)
(say "logged: ~s\n" (reverse logged))
(unless (null? raised) (say "SPIKE FAILURE: coroutines raised ~s\n" raised))
(unless (zero? refused) (say "SPIKE FAILURE: ~a resumes did not answer #t\n" refused))
(uv-loop-teardown! loop)
