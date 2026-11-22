#!r6rs
;;; await-outside on the libuv shell: a resume called from other threads.
;;;
;;; The libuv shell gives the loop's waits an inbox opener whose wake is an
;;; async handle, one an inbox, and closes it when the shell serves no more.
;;; This suite drives it with real threads (`fork-thread`) and a real loop:
;;; each check makes a loop of its own, a shell on it listening on
;;; 127.0.0.1:0, and clients on that same loop, and every wait is capped by
;;; an iteration count, never wall-clock.  Handlers use the public
;;; (http-server) names alone: `awaiting`, `await-outside`, `with-deadline`,
;;; `make-response`.  A worker is handed each `resume` through a mailbox of
;;; the suite's own, a mutex, a condition and a queue, and calls it with the
;;; value its request is owed, "v" and the request's number.
;;;
;;; The checks:
;;;   - every post is delivered once: four threads each resume eight waits,
;;;     and each request is answered once, with its own value, every resume
;;;     answering #t, nothing logged;
;;;   - coalescing loses nothing: the threads post at once, released by a
;;;     barrier once every wait has parked;
;;;   - a sleeping loop wakes: one outside wait, nothing else armed, no ticker,
;;;     so the loop's turn blocks in its poll; the worker counts the loop's
;;;     turns over a window of its own, then posts, and the answer arrives.  A
;;;     watchdog of the suite's, a thread, wakes the loop through an async
;;;     handle of the suite's own if no answer has come after ten seconds,
;;;     and records it: the check is that the answer came, and not by it;
;;;   - an idle server stays idle: the window opens only once the shell's
;;;     tick timer has stopped, which the loop's thread reads from the
;;;     shell's trace, a tick told to the server with the wheel empty while
;;;     the server listens, whose firing stops it; over that window, with the
;;;     inbox open and nothing posted, the loop takes no turn;
;;;   - a waiting verb off the loop's thread: `await-outside`, `await` and
;;;     `sleep-ms`, called from a worker while the loop's thread runs a
;;;     handler's coroutine that waits for the worker, and while the loop's
;;;     thread is asleep in its poll, a handler parked outside, are each
;;;     refused on the worker as R2, off the loop's thread; no register
;;;     runs, no async handle is made, and the handler answers as before;
;;;   - a post races a deadline: values posted after the deadline passed, at
;;;     about its time, and well before it; each request is answered once, its
;;;     value or 504, and a value that comes after its deadline is dropped,
;;;     not logged;
;;;   - a post races the stop: the shell is shut down while threads post, and
;;;     its drain's deadline closes the connections still waiting; the run
;;;     ends, each thread's resumes answer #t until one answers #f and #f
;;;     from then on, a resume called once the server has stopped answers #f,
;;;     every resume called again after answers #f, and nothing raises on any
;;;     thread; and a loop torn down under an open inbox, closing its handle,
;;;     leaves each kept resume answering #f, raising nothing;
;;;   - a later outside wait opens a fresh inbox: a loop's first outside wait
;;;     makes one async handle, and none before; once its shell has stopped, a
;;;     second shell on the loop waits outside again and is answered, while
;;;     the first inbox's resume answers #f;
;;;   - an outside wait once no shell on the loop serves, by a coroutine that
;;;     outlived its connection, makes no async handle: its resume answers
;;;     #f, nothing is handed over, and the loop drains;
;;;   - two shells on one loop: the first stops, and is shut down again, so
;;;     it finds itself serving no more twice, while the second's outside
;;;     wait is parked, and the second's resume is still handed over; the
;;;     second's stop then closes the inbox's handle;
;;;   - a post while the server drains is handed over: a handler parked
;;;     outside keeps its connection through the shutdown, the resume
;;;     answers #t, and the client is answered before the drain's deadline;
;;;   - an inbox closed while its handle is open, as a wake that failed on
;;;     it leaves it, the waits closing it alone: the shell's stop still
;;;     closes the handle;
;;;   - per-thread order: one thread posts 1 to 16 to 16 waits, at once
;;;     while the loop polls nothing, and again a post at a time while it
;;;     polls; the handlers resume in that order;
;;;   - the loop stays live under a blocked worker: a worker asleep two
;;;     seconds in one C call declared `__collect_safe`, a request for `/`,
;;;     whose handler asks for a collection, is answered before the worker
;;;     wakes;
;;;   - no handle is left: after each stop, the loop's live handles are none.
;;; The racy checks (every post once, coalescing, the deadline, the stop) run
;;; five rounds each, a loop of its own for each, as a race shows only
;;; sometimes.
;;;
;;; Oracles: docs/waiting.md (what `await-outside` and its `resume` do: #t
;;; once posted, #f once called before or the server has stopped; a value
;;; after the deadline dropped and not logged; order per thread); chez-libuv's
;;; docs/threads.md (sends coalesce; a send that meets a closed handle raises
;;; `&uv-handle-closed`; an open async handle keeps the loop alive);
;;; chez-libuv's live-handle list; the request numbers the suite sends; and
;;; Chez's own collector: `collect-rendezvous` collects once every active
;;; thread has reached a safe point, and a thread inside a foreign call
;;; declared `__collect_safe` is not active.  `(collect)` cannot stand in: it
;;; refuses while another thread is active.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) fork-thread thread-join make-mutex with-mutex make-condition condition-wait
              condition-broadcast make-time sleep collections collect-rendezvous foreign-procedure
              foreign-entry? load-shared-object machine-type iota make-list list-head)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server private shell) make-shell shell-listen! shell-shutdown! shell-turn! shell-server
              shell-scheduler shell-deadlines shell-waits-timed wall-clock)
        (only (http-server private scheduler) scheduler-waits scheduler-invariant? scheduler-invariant-name)
        (only (http-server private waits) waits-queued? waits-outside-close!)
        (only (http-server server) server-phase)
        (only (http-server limits) limits-with default-limits))

(define (b s) (string->utf8 s))

;; get : Nat -> Bytevector — a GET for request `i`, its number the query.
(define (get i) (b (string-append "GET /?" (number->string i) " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; get-path : String -> Bytevector
(define (get-path path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; text : Nat String -> Response
(define (text status s) (make-response status #f '() (b s)))

;; value-of : Nat -> String — what request `i` is owed.
(define (value-of i) (string-append "v" (number->string i)))

(define cap 8000)

;; Limits whose tick timer stops within 10 ms of the wheel's emptying.
(define quick-ticks (limits-with default-limits '((tick-ms . 10))))

;; Limits whose drain lasts 200 ms.
(define drain-limits (limits-with default-limits '((drain-timeout-ms . 200) (tick-ms . 10))))

;; nap : Nat -> Void — this thread asleep `ms` milliseconds, in Chez's
;; `sleep`, which lets the collector run without it.
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))

;; guarded : (Any -> Boolean) Any -> (U Boolean (List 'raised Condition))
;; What `resume` answers for `v`, or what it raised.
(define (guarded resume v)
  (guard (e (#t (list 'raised e)))
    (resume v)))

;; --- between threads ---------------------------------------------------------------

;; A mailbox: a queue between threads, under a mutex, with a condition its
;; takers wait on; how many items were ever put, and whether it is closed.
(define-record-type mailbox
  (fields mutex changed (mutable front) (mutable back) (mutable puts) (mutable closed?))
  (protocol (lambda (new) (lambda () (new (make-mutex) (make-condition) '() '() 0 #f)))))

;; mailbox-put! : Mailbox Any -> Void — `x` behind what was put before.
(define (mailbox-put! mb x)
  (with-mutex (mailbox-mutex mb)
    (mailbox-back-set! mb (cons x (mailbox-back mb)))
    (mailbox-puts-set! mb (+ 1 (mailbox-puts mb)))
    (condition-broadcast (mailbox-changed mb))))

;; mailbox-take! : Mailbox -> Any
;; The oldest item, waiting for one; #f once the mailbox is closed and
;; empty.
(define (mailbox-take! mb)
  (with-mutex (mailbox-mutex mb)
    (let wait ()
      (when (and (null? (mailbox-front mb)) (pair? (mailbox-back mb)))
        (mailbox-front-set! mb (reverse (mailbox-back mb)))
        (mailbox-back-set! mb '()))
      (cond ((pair? (mailbox-front mb))
             (let ((x (car (mailbox-front mb))))
               (mailbox-front-set! mb (cdr (mailbox-front mb)))
               x))
            ((mailbox-closed? mb) #f)
            (else (condition-wait (mailbox-changed mb) (mailbox-mutex mb)) (wait))))))

;; mailbox-take-n! : Mailbox Nat -> (Listof Any) — `n` items, oldest first.
(define (mailbox-take-n! mb n)
  (let next ((k 0) (acc '()))
    (if (= k n) (reverse acc) (next (+ k 1) (cons (mailbox-take! mb) acc)))))

;; mailbox-count : Mailbox -> Nat — how many items were ever put.
(define (mailbox-count mb) (with-mutex (mailbox-mutex mb) (mailbox-puts mb)))

;; mailbox-close! : Mailbox -> Void — its takers answer #f once it is empty.
(define (mailbox-close! mb)
  (with-mutex (mailbox-mutex mb)
    (mailbox-closed?-set! mb #t)
    (condition-broadcast (mailbox-changed mb))))

;; A latch: set once, waited for by any thread.
(define-record-type latch
  (fields mutex changed (mutable on))
  (protocol (lambda (new) (lambda () (new (make-mutex) (make-condition) #f)))))

;; latch-set! : Latch -> Void
(define (latch-set! l)
  (with-mutex (latch-mutex l)
    (latch-on-set! l #t)
    (condition-broadcast (latch-changed l))))

;; latch-on? : Latch -> Boolean
(define (latch-on? l) (with-mutex (latch-mutex l) (latch-on l)))

;; latch-wait : Latch (U Nat #f) -> Boolean
;; Wait until the latch is set, or, given `seconds`, until that long has
;; passed with it unset: whether it is set.
(define (latch-wait l seconds)
  (with-mutex (latch-mutex l)
    (let wait ()
      (cond ((latch-on l) #t)
            ((not seconds) (condition-wait (latch-changed l) (latch-mutex l)) (wait))
            ((condition-wait (latch-changed l) (latch-mutex l) (make-time 'time-duration 0 seconds)) (wait))
            (else (latch-on l))))))

;; A counter any thread may bump and read.
(define-record-type counter
  (fields mutex (mutable n))
  (protocol (lambda (new) (lambda () (new (make-mutex) 0)))))

;; counter-bump! : Counter -> Void
(define (counter-bump! c) (with-mutex (counter-mutex c) (counter-n-set! c (+ 1 (counter-n c)))))

;; counter-read : Counter -> Nat
(define (counter-read c) (with-mutex (counter-mutex c) (counter-n c)))

;; --- a loop, a shell on it, and its clients --------------------------------------

;; A rig: a loop of its own, a shell on it listening on 127.0.0.1:0, the port,
;; and what the shell logged, newest first, as (what . details).
(define-record-type rig (fields loop shell port logged))

;; open-rig : (Request -> Answer) Limits [Trace] -> Rig — the shell traced
;; by `trace`, if given (make-shell's).
(define open-rig
  (case-lambda
    ((handler limits) (open-rig handler limits #f))
    ((handler limits trace)
     (let* ((loop (make-uv-loop))
            (logged (vector '()))
            (sh (make-shell loop handler limits wall-clock
                            (lambda (what details) (vector-set! logged 0 (cons (cons what details) (vector-ref logged 0))))
                            trace))
            (port (shell-listen! sh "127.0.0.1" 0)))
       (make-rig loop sh port logged)))))

;; rig-log : Rig -> (Listof (Pair Symbol (Listof Any))) — oldest first.
(define (rig-log r) (reverse (vector-ref (rig-logged r) 0)))

;; rig-waits : Rig -> Waits — its loop's.
(define (rig-waits r) (scheduler-waits (shell-scheduler (rig-shell r))))

;; client! : Rig Bytevector -> Client — a client on the rig's loop, reading,
;; that sends `request`.
(define (client! r request) (open-client (rig-loop r) (rig-port r) request #t))

;; turn-until : Rig (-> Boolean) Nat -> Symbol
;; Turn the shell's run loop, a 1 ms ticker keeping the loop awake, until
;; `pred` holds or `n` turns are taken: 'satisfied or 'iterations-exhausted.
(define (turn-until r pred n) (run-shell-until (rig-loop r) (rig-shell r) pred n))

;; bare-turns-until : Rig (-> Boolean) Nat Counter -> Symbol
;; The same with no ticker, each turn counted once it is over: a turn whose
;; poll finds nothing to do blocks until something wakes the loop.
(define (bare-turns-until r pred n turns)
  (let step ((i 0))
    (cond ((pred) 'satisfied)
          ((= i n) 'iterations-exhausted)
          (else (shell-turn! (rig-shell r)) (counter-bump! turns) (step (+ i 1))))))

;; watched-turns : Rig (-> Boolean) Counter -> (List Symbol Boolean)
;; bare-turns-until `pred`, up to `cap` turns, with a watchdog: a thread
;; that waits ten seconds for the turns to end, and if they have not, wakes
;; the loop through an async handle of the suite's own and records it, so
;; a loop no post wakes ends the check, failing it, where it would hang.
;; What the turns came to, and whether the watchdog woke the loop.
(define (watched-turns r pred turns)
  (let* ((over (make-latch))
         (rescued (make-latch))
         (rescue (make-uv-async (rig-loop r) (lambda (a) #f)))
         (watchdog (fork-thread
                    (lambda ()
                      (unless (latch-wait over 10)
                        (latch-set! rescued)
                        (uv-async-send! rescue)))))
         (outcome (bare-turns-until r (lambda () (or (latch-on? rescued) (pred))) cap turns)))
    (latch-set! over)
    (thread-join watchdog)
    (uv-close! rescue)
    (list outcome (latch-on? rescued))))

;; What each client has read, parsed once for each length it has had.
(define parsed (make-eq-hashtable))

;; read-back : Client -> (Listof (List Nat String))
;; Each whole response the client has read: its status and its body.
(define (read-back cl)
  (let* ((bv (client-bytes cl)) (n (bytevector-length bv)) (memo (hashtable-ref parsed cl #f)))
    (if (and memo (= (car memo) n))
        (cdr memo)
        (let ((rs (map (lambda (r) (list (car r) (cadddr r))) (responses bv))))
          (hashtable-set! parsed cl (cons n rs))
          rs))))

;; answered? : Client -> Boolean — it has read a whole response.
(define (answered? cl) (pair? (read-back cl)))

;; misanswered : (Listof Client) (Nat -> (Listof (List Nat String))) -> (Listof (Pair Nat Any))
;; Each client, by number, whose responses are not what `expected` says,
;; with what they are.
(define (misanswered clients expected)
  (let next ((cls clients) (i 0) (acc '()))
    (if (null? cls)
        (reverse acc)
        (next (cdr cls) (+ i 1)
              (if (equal? (read-back (car cls)) (expected i)) acc (cons (cons i (read-back (car cls))) acc))))))

;; handle-kind : UvHandle -> Symbol
(define (handle-kind h)
  (cond ((uv-async? h) 'async) ((uv-timer? h) 'timer) ((uv-tcp? h) 'tcp) ((uv-signal? h) 'signal)
        (else 'other)))

;; asyncs : Rig -> Nat — the async handles live on its loop.
(define (asyncs r) (length (filter uv-async? (uv-loop-live-handles (rig-loop r)))))

;; What was left on each rig's loop once its shell had stopped, as (name
;; stopped kinds), newest first.
(define leftovers '())

;; close-rig! : Rig String (Listof Client) -> Void
;; Close the clients, shut the shell down if it has not stopped, turn until
;; it has, run the loop until nothing but a timer is live, record what is
;; left, and tear the loop down.
(define (close-rig! r name clients)
  (for-each client-close! clients)
  (let ((sh (rig-shell r)))
    (unless (eq? (server-phase (shell-server sh)) 'stopped) (shell-shutdown! sh))
    (let ((stopped (turn-until r (lambda () (eq? (server-phase (shell-server sh)) 'stopped)) cap)))
      (run-until-drained (rig-loop r) cap)
      (set! leftovers (cons (list name stopped (map handle-kind (uv-loop-live-handles (rig-loop r))))
                            leftovers))
      (uv-loop-teardown! (rig-loop r)))))

;; outside-handler : (Nat (Any -> Boolean) -> Any) -> (Request -> Answer)
;; A handler that waits outside for request `i`, `GET /?i`: its `register`
;; calls `(give! i resume)`, and the value is the response's body, 200.
(define (outside-handler give!)
  (lambda (req)
    (let ((i (string->number (request-query req))))
      (awaiting (lambda () (text 200 (await-outside (lambda (resume) (give! i resume)))))))))

;; own-value : Nat -> (Listof (List Nat String)) — request `i`'s answer.
(define (own-value i) (list (list 200 (value-of i))))

;; not-true : (Vectorof Any) -> (Listof (Pair Nat Any))
;; Each index whose entry is not #t, with the entry.
(define (not-true v)
  (filter (lambda (e) (not (eq? (cdr e) #t)))
          (map (lambda (i) (cons i (vector-ref v i))) (iota (vector-length v)))))

;; --- every post once, and coalescing -------------------------------------------------

;; delivered-round : Nat Nat Boolean -> (List Symbol List List List)
;; `threads` workers, each given `each` waits' resumes, request i to worker
;; i mod `threads`, each resume called with what its request is owed.  At
;; once, a barrier releasing every worker once each holds all its resumes,
;; or as each comes.  What the run came to: whether every request was
;; answered, the requests misanswered, the resumes that did not answer #t,
;; and what was logged.
(define (delivered-round threads each at-once?)
  (let* ((total (* threads each))
         (boxes (list->vector (map (lambda (k) (make-mailbox)) (iota threads))))
         (answers (make-vector total 'never-called))
         (holding (make-counter))
         (go (make-latch))
         (r (open-rig (outside-handler (lambda (i resume)
                                         (mailbox-put! (vector-ref boxes (mod i threads)) (cons i resume))))
                      default-limits))
         (post! (lambda (job)
                  (when job (vector-set! answers (car job) (guarded (cdr job) (value-of (car job)))))))
         (workers
          (map (lambda (k)
                 (fork-thread
                  (lambda ()
                    (let ((box (vector-ref boxes k)))
                      (if at-once?
                          (let ((jobs (mailbox-take-n! box each)))
                            (counter-bump! holding)
                            (latch-wait go #f)
                            (for-each post! jobs))
                          (let next ()
                            (let ((job (mailbox-take! box)))
                              (when job (post! job) (next)))))))))
               (iota threads)))
         (clients (map (lambda (i) (client! r (get i))) (iota total)))
         (held (if at-once?
                   (turn-until r (lambda () (= threads (counter-read holding))) cap)
                   'satisfied)))
    (latch-set! go)
    (let ((outcome (turn-until r (lambda () (for-all answered? clients)) cap)))
      (vector-for-each mailbox-close! boxes)
      (for-each thread-join workers)
      (let ((result (list held outcome (misanswered clients own-value) (not-true answers) (rig-log r))))
        (close-rig! r (if at-once? "coalescing" "every post once") clients)
        result))))

;; --- a sleeping loop, and an idle one ------------------------------------------------

;; sleeping-loop : -> (List Symbol List Any Boolean Any)
;; One outside wait, nothing else armed, the loop turned with no ticker.
;; The loop's thread sets `quiet` once the shell's tick timer has stopped:
;; the trace saw a tick told to the server with the wheel empty while the
;; server listens, so that firing stopped it (tick!), and nothing but the
;; inbox and the client's connection is left armed.  The worker, given the
;; resume, waits for `quiet`, then reads how many turns the loop has taken,
;; waits 300 ms, reads again, and posts.  What the run came to: whether the
;; answer came, what the client read, what the resume answered, whether the
;; watchdog woke the loop, and the turns taken over the worker's window.
(define (sleeping-loop)
  (let* ((jobs (make-mailbox))
         (stopped? #f)
         (quiet (make-latch))
         (r (open-rig (outside-handler (lambda (i resume) (mailbox-put! jobs resume))) quick-ticks
                      (lambda (who kind datum)
                        (when (and (eq? kind 'server-event) (pair? datum) (eq? (car datum) 'tick)
                                   (zero? (shell-deadlines who))
                                   (eq? (server-phase (shell-server who)) 'listening))
                          (set! stopped? #t)))))
         (turns (make-counter))
         (answer 'never-called)
         (window 'never-measured)
         (worker (fork-thread
                  (lambda ()
                    (let ((resume (mailbox-take! jobs)))
                      (when (and resume (latch-wait quiet 10))
                        (let ((t0 (counter-read turns)))
                          (nap 300)
                          (set! window (- (counter-read turns) t0))))
                      (when resume (set! answer (guarded resume (value-of 0))))))))
         (cl (client! r (get 0)))
         (watched (watched-turns r
                                 (lambda ()
                                   (when stopped? (latch-set! quiet))
                                   (answered? cl))
                                 turns)))
    (mailbox-close! jobs)
    (thread-join worker)
    (let ((result (list (car watched) (read-back cl) answer (cadr watched)
                        (cond ((not (integer? window)) window)
                              ((zero? window) 'idle)
                              (else (list 'turned window))))))
      (put-string (current-output-port)
                  (string-append "outside-shell: the idle loop took " (if (integer? window) (number->string window) "?")
                                 " turns over the worker's 300 ms window\n"))
      (close-rig! r "a sleeping loop" (list cl))
      result)))

;; --- a waiting verb off the loop's thread ----------------------------------------------

;; What a wait off the loop's thread is refused with.
(define off-thread '(refused r2 "a wait off the loop's thread"))

;; refusal-of : (-> Any) -> Any
;; What `thunk` comes to: `(refused name message)` for a scheduler's
;; refusal, `(raised x)` for any other raise, a condition as `condition`, or
;; `(returned v)`.
(define (refusal-of thunk)
  (guard (e ((scheduler-invariant? e) (list 'refused (scheduler-invariant-name e) (condition-message e)))
            (#t (list 'raised (if (condition? e) 'condition e))))
    (list 'returned (thunk))))

;; on-thread : (-> Any) -> Any — what `thunk` answers on a thread of its own,
;; which this one waits for.
(define (on-thread thunk)
  (let* ((v 'never-called) (t (fork-thread (lambda () (set! v (thunk))))))
    (thread-join t)
    v))

;; verbs : (Symbol -> Void) -> (Listof (-> Any))
;; Calls of await-outside and of await, each register noting that it ran,
;; through `ran!`, then raising; of sleep-ms; and of await-outside with a
;; register that notes it ran and returns.
(define (verbs ran!)
  (list (lambda () (await-outside (lambda (r) (ran! 'await-outside) (raise 'register-ran))))
        (lambda () (await (lambda (r) (ran! 'await) (raise 'register-ran))))
        (lambda () (sleep-ms 1))
        (lambda () (await-outside (lambda (r) (ran! 'await-outside-returns))))))

;; off-thread-mid-coroutine : -> (List Any ...)
;; A handler whose coroutine makes each verb's call on a thread of its own,
;; waiting for each, then answers 200 "ok".  Whether the client was
;; answered, what each call came to, the registers that ran, what the client
;; read, the async handles live, and what was logged.
(define (off-thread-mid-coroutine)
  (let* ((ran '()) (outcomes 'never-called)
         (r (open-rig (lambda (req)
                        (awaiting (lambda ()
                                    (set! outcomes (map (lambda (call) (on-thread (lambda () (refusal-of call))))
                                                        (verbs (lambda (who) (set! ran (cons who ran))))))
                                    (text 200 "ok"))))
                      default-limits))
         (cl (client! r (get-path "/")))
         (done (turn-until r (lambda () (answered? cl)) cap))
         (result (list done outcomes ran (read-back cl) (asyncs r) (rig-log r))))
    (close-rig! r "a wait off the loop's thread, mid-coroutine" (list cl))
    result))

;; off-thread-in-poll : -> (List Any ...)
;; A handler parked outside, the loop turned with no ticker, so its turn
;; blocks in the poll; a worker, given the resume, waits 50 ms, makes each
;; verb's call, then posts the resume.  Whether the client was answered,
;; whether the watchdog woke the loop, what each call came to, the
;; registers that ran, what the resume answered, what the client read, and
;; what was logged.
(define (off-thread-in-poll)
  (let* ((jobs (make-mailbox)) (ran '()) (outcomes 'never-called) (answer 'never-called)
         (r (open-rig (outside-handler (lambda (i resume) (mailbox-put! jobs resume))) quick-ticks))
         (worker (fork-thread
                  (lambda ()
                    (let ((resume (mailbox-take! jobs)))
                      (when resume
                        (nap 50)
                        (set! outcomes (map refusal-of (verbs (lambda (who) (set! ran (cons who ran))))))
                        (set! answer (guarded resume (value-of 0))))))))
         (cl (client! r (get 0)))
         (watched (watched-turns r (lambda () (answered? cl)) (make-counter))))
    (mailbox-close! jobs)
    (thread-join worker)
    (let ((result (list (car watched) (cadr watched) outcomes ran answer (read-back cl) (rig-log r))))
      (close-rig! r "a wait off the loop's thread, in the poll" (list cl))
      result)))

;; --- a post races a deadline ---------------------------------------------------------

;; Each request's plan: when its value is posted, and its deadline in ms.
;;   after   once the handler has seen its deadline pass
;;   about   4 ms after its worker is given the resume
;;   before  as soon as its worker is given it
(define race-plan
  '#((after 10) (after 10) (after 10) (about 2) (about 3) (about 4) (about 4) (about 5) (about 6)
     (before 10000) (before 10000) (before 10000)))

;; deadline-round : -> (List Symbol List List List Nat)
;; Each request of race-plan on its own connection, each value posted by a
;; thread of its own.  What the run came to: whether every request was
;; answered, every value posted and handed over; the requests answered
;; otherwise than their plan allows; the resumes that did not answer #t;
;; what was logged; and how many `about` requests had their value.
(define (deadline-round)
  (let* ((k (vector-length race-plan))
         (passed (list->vector (map (lambda (i) (make-latch)) (iota k))))
         (answers (make-vector k 'never-called))
         (done (make-counter))
         (posters (make-mailbox))
         (r (open-rig
             (lambda (req)
               (let* ((i (string->number (request-query req))) (plan (vector-ref race-plan i)))
                 (awaiting
                  (lambda ()
                    (guard (e ((deadline-passed? e) (latch-set! (vector-ref passed i)) (text 504 "late")))
                      (with-deadline (cadr plan)
                        (lambda ()
                          (text 200 (await-outside
                                     (lambda (resume)
                                       (mailbox-put! posters
                                         (fork-thread
                                          (lambda ()
                                            (case (car plan)
                                              ((after) (latch-wait (vector-ref passed i) #f))
                                              ((about) (nap 4)))
                                            (vector-set! answers i (guarded resume (value-of i)))
                                            (counter-bump! done))))))))))))))
             default-limits))
         (clients (map (lambda (i) (client! r (get i))) (iota k)))
         (outcome (let ((answered (turn-until r (lambda () (for-all answered? clients)) cap)))
                    (if (eq? answered 'satisfied)
                        (turn-until r (lambda () (and (= k (counter-read done)) (not (waits-queued? (rig-waits r)))))
                                    2000)
                        answered))))
    (vector-for-each latch-set! passed)
    (mailbox-close! posters)
    (let join () (let ((t (mailbox-take! posters))) (when t (thread-join t) (join))))
    (let ((result (list outcome
                        (misanswered clients
                                     (lambda (i)
                                       (case (car (vector-ref race-plan i))
                                         ((after) '((504 "late")))
                                         ((before) (own-value i))
                                         (else (if (equal? (read-back (list-ref clients i)) '((504 "late")))
                                                   '((504 "late"))
                                                   (own-value i))))))
                        (not-true answers)
                        (rig-log r)
                        (length (filter (lambda (i) (and (eq? (car (vector-ref race-plan i)) 'about)
                                                         (equal? (read-back (list-ref clients i)) (own-value i))))
                                        (iota k))))))
      (close-rig! r "a deadline race" clients)
      result)))

;; --- a post races the stop ---------------------------------------------------------

;; monotone : (Listof Any) -> (U 'monotone (Listof Any))
;; 'monotone for answers that are #t, then #f from the first #f on, ending
;; in #f; else the answers.
(define (monotone answers)
  (let scan ((as answers) (seen-false? #f))
    (cond ((null? as) (if seen-false? 'monotone answers))
          ((eq? (car as) #t) (if seen-false? answers (scan (cdr as) #f)))
          ((eq? (car as) #f) (scan (cdr as) #t))
          (else answers))))

;; stop-round : Nat -> (List Symbol Symbol List List List List Nat)
;; Sixteen requests, request i's resume to worker i mod 4.  Once each has
;; parked the shell is shut down; worker k posts its first value at once,
;; its second and third each 90 + 3 `round` + 3k ms after the one before,
;; so the third comes 180 to 222 ms on, across the drain's 200 ms deadline,
;; which closes the connections still waiting, and its last once the server
;; has stopped.  Then every resume is called again, from a thread of its
;; own.
;; What the run came to: whether every wait parked and the server stopped;
;; each worker's answers, unless monotone; the requests answered otherwise
;; than with their value or not at all, or with a value whose resume did not
;; answer #t; the answers of the calls again; what was logged but the
;; drain's own lines; and how many were answered.
(define (stop-round round)
  (let* ((workers 4) (each 4) (total (* workers each))
         (boxes (list->vector (map (lambda (k) (make-mailbox)) (iota workers))))
         (kept (make-mailbox))
         (answers (make-vector total 'never-called))
         (stopped (make-latch))
         (r (open-rig (outside-handler (lambda (i resume)
                                         (mailbox-put! (vector-ref boxes (mod i workers)) (cons i resume))
                                         (mailbox-put! kept resume)))
                      drain-limits))
         (sh (rig-shell r))
         (sequences (make-vector workers '()))
         (threads
          (map (lambda (k)
                 (fork-thread
                  (lambda ()
                    (let post ((jobs (mailbox-take-n! (vector-ref boxes k) each)) (n 0) (acc '()))
                      (if (null? jobs)
                          (vector-set! sequences k (reverse acc))
                          (let ((job (car jobs)))
                            (cond ((= n (- each 1)) (latch-wait stopped #f))
                                  ((> n 0) (nap (+ 90 (* 3 round) (* 3 k)))))
                            (let ((a (if job (guarded (cdr job) (value-of (car job))) 'no-job)))
                              (when job (vector-set! answers (car job) a))
                              (post (cdr jobs) (+ n 1) (cons a acc)))))))))
               (iota workers)))
         (clients (map (lambda (i) (client! r (get i))) (iota total)))
         (parked (turn-until r (lambda () (= total (mailbox-count kept))) cap)))
    (shell-shutdown! sh)
    (let ((ended (turn-until r (lambda () (eq? (server-phase (shell-server sh)) 'stopped)) cap)))
      (latch-set! stopped)
      (vector-for-each mailbox-close! boxes)
      (for-each thread-join threads)
      (mailbox-close! kept)
      (let* ((again 'never-called)
             (t (fork-thread (lambda ()
                               (set! again (let next ((acc '()))
                                             (let ((resume (mailbox-take! kept)))
                                               (if resume (next (cons (guarded resume "again") acc)) acc))))))))
        (thread-join t)
        (let ((result
               (list parked ended
                     (filter (lambda (s) (not (eq? s 'monotone))) (map monotone (vector->list sequences)))
                     (misanswered clients
                                  (lambda (i)
                                    (if (and (eq? (vector-ref answers i) #t) (pair? (read-back (list-ref clients i))))
                                        (own-value i)
                                        '())))
                     (filter (lambda (a) (not (eq? a #f))) again)
                     (filter (lambda (e) (not (memq (car e) '(draining drain-timeout stopped)))) (rig-log r))
                     (length (filter answered? clients)))))
          (close-rig! r "a stop race" clients)
          result)))))

;; torn-down : -> (List Symbol Nat Any)
;; Two outside waits parked, their resumes kept, then the loop torn down
;; with the shell still serving, which closes the inbox's handle under it:
;; whether both parked, how many async handles were live before, and what
;; each resume answers after, called from a thread of its own.
(define (torn-down)
  (let* ((kept (make-mailbox))
         (r (open-rig (outside-handler (lambda (i resume) (mailbox-put! kept resume))) default-limits))
         (clients (map (lambda (i) (client! r (get i))) (iota 2)))
         (parked (turn-until r (lambda () (= 2 (mailbox-count kept))) cap))
         (live (asyncs r)))
    (uv-loop-teardown! (rig-loop r))
    (mailbox-close! kept)
    (let* ((after 'never-called)
           (t (fork-thread (lambda () (set! after (map (lambda (resume) (guarded resume "after"))
                                                       (mailbox-take-n! kept 2)))))))
      (thread-join t)
      (list parked live after))))

;; --- a fresh inbox ---------------------------------------------------------------------

;; reopened : -> (List Any ...)
;; A shell on a loop answers a plain request, then one that waits outside,
;; posted from a thread, and stops; a second shell on the same loop waits
;; outside again.  The async handles live before the first outside wait,
;; while it is open, and once the first shell has stopped; the answers; and
;; what the first wait's resume answers, called again once its shell has
;; stopped and once the second inbox is open, and what the second's does.
(define (reopened)
  (let* ((kept (make-mailbox))
         (handler (lambda (req)
                    (if (request-query req)
                        ((outside-handler (lambda (i resume) (mailbox-put! kept resume))) req)
                        (text 200 "plain"))))
         (first (open-rig handler default-limits))
         (loop (rig-loop first))
         (plain (client! first (get-path "/")))
         (plain-done (turn-until first (lambda () (answered? plain)) cap))
         (before (asyncs first))
         (a (client! first (get 1)))
         (a-parked (turn-until first (lambda () (= 1 (mailbox-count kept))) cap))
         (while-open (asyncs first))
         (ra (mailbox-take! kept))
         (on-thread (lambda (thunk) (let* ((v 'never-called) (t (fork-thread (lambda () (set! v (thunk))))))
                                      (thread-join t)
                                      v)))
         (ra-first (on-thread (lambda () (guarded ra (value-of 1)))))
         (a-done (turn-until first (lambda () (answered? a)) cap)))
    (for-each client-close! (list plain a))
    (shell-shutdown! (rig-shell first))
    (let* ((stopped (turn-until first (lambda () (eq? (server-phase (shell-server (rig-shell first))) 'stopped)) cap))
           (after-stop (turn-until first (lambda () (zero? (asyncs first))) 64))
           (ra-stopped (on-thread (lambda () (guarded ra "again"))))
           (logged (vector '()))
           (sh2 (make-shell loop handler default-limits wall-clock
                            (lambda (what details) (vector-set! logged 0 (cons (cons what details) (vector-ref logged 0))))))
           (second (make-rig loop sh2 (shell-listen! sh2 "127.0.0.1" 0) logged))
           (b2 (client! second (get 2)))
           (b-parked (turn-until second (lambda () (= 2 (mailbox-count kept))) cap))
           (rb (mailbox-take! kept))
           (ra-reopened (on-thread (lambda () (guarded ra "again"))))
           (rb-first (on-thread (lambda () (guarded rb (value-of 2)))))
           (b-done (turn-until second (lambda () (answered? b2)) cap))
           (result (list plain-done (read-back plain) before a-parked while-open ra-first a-done (read-back a)
                         stopped after-stop ra-stopped b-parked ra-reopened rb-first b-done (read-back b2))))
      (close-rig! second "a fresh inbox" (list b2))
      result)))

;; --- no shell serves ----------------------------------------------------------------------

;; outlived : -> (List Any ...)
;; A handler waits for a resume of the check's own, then outside.  The shell
;; is shut down, and the drain's 50 ms deadline closes the connection the
;; handler still waits on, so its coroutine outlives it; once the server
;; has stopped, the check's resume wakes it, and it waits outside, no shell
;; on the loop serving.  Whether the first wait parked, whether the server
;; stopped, the async handles live then, whether the outside wait began,
;; the async handles live after, what its resume answers from another
;; thread, whether a value was handed over in 200 turns, and whether the
;; loop then drains, nothing but a timer left, and the async handles live
;; at the end.
(define (outlived)
  (let* ((go #f) (kept (make-mailbox)) (resumed 'never)
         (r (open-rig (lambda (req)
                        (awaiting (lambda ()
                                    (await (lambda (resume) (set! go resume)))
                                    (let ((v (await-outside (lambda (resume) (mailbox-put! kept resume)))))
                                      (set! resumed v)
                                      (text 200 v)))))
                      (limits-with default-limits '((drain-timeout-ms . 50) (tick-ms . 10)))))
         (sh (rig-shell r))
         (cl (client! r (get-path "/")))
         (parked (turn-until r (lambda () (and go #t)) cap)))
    (shell-shutdown! sh)
    (let* ((stopped (turn-until r (lambda () (eq? (server-phase (shell-server sh)) 'stopped)) cap))
           (at-stop (asyncs r)))
      (when go (go #t))
      (let* ((waited (turn-until r (lambda () (= 1 (mailbox-count kept))) cap))
             (after (asyncs r))
             (answer (if (= 1 (mailbox-count kept))
                         (let ((resume (mailbox-take! kept))) (on-thread (lambda () (guarded resume "late"))))
                         'never-called))
             (handed (turn-until r (lambda () (not (eq? resumed 'never))) 200)))
        (client-close! cl)
        (let* ((drained (run-until-drained (rig-loop r) cap))
               (result (list parked stopped at-stop waited after answer handed resumed drained (asyncs r))))
          (uv-loop-teardown! (rig-loop r))
          result)))))

;; two-shells : -> (List Any ...)
;; Two shells on one loop, each listening; the second's handler waits
;; outside, its resume kept.  The first is shut down and stops, and is shut
;; down again, as a second signal would, so it finds itself serving no more
;; twice; then the resume is called from another thread, and the second's
;; client is answered; then the second is shut down and stops.  Whether the
;; wait
;; parked, whether the first stopped, the async handles live then, what the
;; resume answered, whether the second's client was answered, with what,
;; whether the second stopped, and whether its async handle was closed.
(define (two-shells)
  (let* ((kept (make-mailbox))
         (first (open-rig (lambda (req) (text 200 "first")) default-limits))
         (loop (rig-loop first))
         (sh2 (make-shell loop (outside-handler (lambda (i resume) (mailbox-put! kept resume)))
                          default-limits wall-clock (lambda (what details) #f)))
         (second (make-rig loop sh2 (shell-listen! sh2 "127.0.0.1" 0) (vector '())))
         (cl (client! second (get 1)))
         (parked (turn-until second (lambda () (= 1 (mailbox-count kept))) cap)))
    (shell-shutdown! (rig-shell first))
    (let* ((first-stopped (turn-until first (lambda () (eq? (server-phase (shell-server (rig-shell first))) 'stopped)) cap))
           (again (begin (shell-shutdown! (rig-shell first)) (turn-until first (lambda () #f) 8)))
           (live (asyncs first))
           (answer (if (= 1 (mailbox-count kept))
                       (let ((resume (mailbox-take! kept))) (on-thread (lambda () (guarded resume (value-of 1)))))
                       'never-called))
           (done (turn-until second (lambda () (answered? cl)) cap)))
      (client-close! cl)
      (shell-shutdown! sh2)
      (let* ((second-stopped (turn-until second (lambda () (eq? (server-phase (shell-server sh2)) 'stopped)) cap))
             (closed (turn-until second (lambda () (zero? (asyncs second))) 64))
             (result (list parked first-stopped live answer done (read-back cl) second-stopped closed)))
        (close-rig! second "two shells on one loop" '())
        result))))

;; drained-post : -> (List Any ...)
;; A handler parked outside keeps its connection; the shell is shut down,
;; and while the server drains, the resume is called from another thread.
;; Once answered, the client closes, as the drain's lingering close waits
;; for.  Whether the wait parked, the server's phase as the resume was
;; called, what it answered, whether the client was answered, with what,
;; whether the server stopped, and whether the drain's deadline was logged.
(define (drained-post)
  (let* ((kept (make-mailbox))
         (r (open-rig (outside-handler (lambda (i resume) (mailbox-put! kept resume))) default-limits))
         (sh (rig-shell r))
         (cl (client! r (get 1)))
         (parked (turn-until r (lambda () (= 1 (mailbox-count kept))) cap)))
    (shell-shutdown! sh)
    (let* ((phase (server-phase (shell-server sh)))
           (answer (if (= 1 (mailbox-count kept))
                       (let ((resume (mailbox-take! kept))) (on-thread (lambda () (guarded resume (value-of 1)))))
                       'never-called))
           (done (turn-until r (lambda () (answered? cl)) cap))
           (read (read-back cl)))
      (client-close! cl)
      (let* ((stopped (turn-until r (lambda () (eq? (server-phase (shell-server sh)) 'stopped)) cap))
             (result (list parked phase answer done read stopped
                           (and (assq 'drain-timeout (rig-log r)) #t))))
        (close-rig! r "a post while the server drains" (list cl))
        result))))

;; closed-under-open-handle : -> (List Any ...)
;; An outside wait parked; the loop's waits close their inbox alone, its
;; handle left open, as a wake that failed on it leaves them; then the
;; client closes and the shell stops.  Whether the wait parked, the async
;; handles live once the inbox is closed, what its resume then answers from
;; another thread, whether the server stopped, and whether the handle was
;; closed.
(define (closed-under-open-handle)
  (let* ((kept (make-mailbox))
         (r (open-rig (outside-handler (lambda (i resume) (mailbox-put! kept resume))) default-limits))
         (sh (rig-shell r))
         (cl (client! r (get 1)))
         (parked (turn-until r (lambda () (= 1 (mailbox-count kept))) cap)))
    (waits-outside-close! (rig-waits r) (lambda () #f))
    (let* ((live (asyncs r))
           (answer (if (= 1 (mailbox-count kept))
                       (let ((resume (mailbox-take! kept))) (on-thread (lambda () (guarded resume "after"))))
                       'never-called)))
      (client-close! cl)
      (shell-shutdown! sh)
      (let* ((stopped (turn-until r (lambda () (eq? (server-phase (shell-server sh)) 'stopped)) cap))
             (closed (turn-until r (lambda () (zero? (asyncs r))) 64))
             (result (list parked live answer stopped closed)))
        (close-rig! r "an inbox closed under its open handle" '())
        result))))

;; --- per-thread order ------------------------------------------------------------------

;; ordered : Boolean -> (List Symbol Symbol Any)
;; Sixteen waits parked, then one thread posts 1 to 16 to them, in the order
;; they parked: while the loop's thread waits for it, so the loop's next
;; poll finds every post, or a post at a time, 1 ms apart, while the loop
;; polls.  Whether all parked and all were answered, and the values in the
;; order the handlers resumed with them.
(define (ordered at-once?)
  (let* ((n 16)
         (jobs (make-mailbox))
         (resumed '())
         (go (make-latch))
         (posted (make-latch))
         (r (open-rig (lambda (req)
                        (awaiting (lambda ()
                                    (let ((v (await-outside (lambda (resume) (mailbox-put! jobs resume)))))
                                      (set! resumed (cons v resumed))
                                      (text 200 (number->string v))))))
                      default-limits))
         (worker (fork-thread
                  (lambda ()
                    (let ((resumes (mailbox-take-n! jobs n)))
                      (latch-wait go #f)
                      (let next ((rs resumes) (k 1))
                        (when (and (pair? rs) (car rs))
                          ((car rs) k)
                          (unless at-once? (nap 1))
                          (next (cdr rs) (+ k 1))))
                      (latch-set! posted)))))
         (clients (map (lambda (i) (client! r (get-path "/"))) (iota n)))
         (parked (turn-until r (lambda () (= n (mailbox-count jobs))) cap)))
    (latch-set! go)
    (when at-once? (latch-wait posted 10))
    (let ((outcome (turn-until r (lambda () (for-all answered? clients)) cap)))
      (mailbox-close! jobs)
      (thread-join worker)
      (let ((result (list parked outcome (reverse resumed))))
        (close-rig! r "per-thread order" clients)
        result))))

;; --- a blocked worker --------------------------------------------------------------------

;; suffix? : String String -> Boolean
(define (suffix? s end)
  (let ((n (string-length s)) (m (string-length end)))
    (and (>= n m) (string=? (substring s (- n m) n) end))))

;; c-sleep-seconds : -> (Nat -> Any)
;; A C call that sleeps whole seconds, declared `__collect_safe`, so the
;; thread in it is not active and a collection need not wait for it: libc's
;; `sleep` on Linux and Darwin, kernel32's `Sleep` on Windows.  One call,
;; so the thread never comes back to Scheme while it sleeps.
(define (c-sleep-seconds)
  (let ((mt (symbol->string (machine-type))))
    (if (suffix? mt "nt")
        (begin
          (load-shared-object "kernel32.dll")
          (let ((nap-ms (foreign-procedure __collect_safe "Sleep" (unsigned-32) void)))
            (lambda (s) (nap-ms (* 1000 s)))))
        (begin
          (unless (foreign-entry? "sleep")
            (load-shared-object (if (suffix? mt "osx") "libc.dylib" "libc.so.6")))
          (foreign-procedure __collect_safe "sleep" (unsigned-32) unsigned-32)))))

;; blocked-worker : -> (List Any ...)
;; `/slow` waits outside for a worker asleep in c-sleep-seconds for two
;; seconds; once it sleeps, a request for `/` is answered by a handler that
;; asks for a collection (collect-rendezvous) and says whether one ran.
;; Two seconds: `/`'s answer takes a few turns over loopback and one
;; collection of this suite's small heap, milliseconds, so the worker is
;; still asleep when it is read, with three orders of magnitude to spare,
;; at the cost of two seconds once.  What the run came to: whether the
;; worker began its sleep, whether `/` was answered and with what, whether
;; the worker had woken by then, and `/slow`'s answer and its resume's.
(define (blocked-worker)
  (let* ((c-sleep (c-sleep-seconds))
         (asleep (make-latch))
         (woke (make-latch))
         (sleeper #f)
         (answer 'never-called)
         (r (open-rig (lambda (req)
                        (if (string=? (request-path req) "/slow")
                            (awaiting
                             (lambda ()
                               (text 200 (await-outside
                                          (lambda (resume)
                                            (set! sleeper
                                                  (fork-thread
                                                   (lambda ()
                                                     (latch-set! asleep)
                                                     (c-sleep 2)
                                                     (latch-set! woke)
                                                     (set! answer (guarded resume "slept"))))))))))
                            (let ((before (collections)))
                              (collect-rendezvous)
                              (text 200 (if (> (collections) before) "collected" "not collected")))))
                      default-limits))
         (slow (client! r (get-path "/slow")))
         (sleeping (turn-until r (lambda () (latch-on? asleep)) cap))
         (fast (client! r (get-path "/")))
         (fast-done (turn-until r (lambda () (answered? fast)) cap))
         (woke-by-then (latch-on? woke))
         (slow-done (turn-until r (lambda () (answered? slow)) cap)))
    (when sleeper (thread-join sleeper))
    (let ((result (list sleeping fast-done (read-back fast) woke-by-then slow-done (read-back slow) answer)))
      (close-rig! r "a blocked worker" (list slow fast))
      result)))

(run-suite "outside-shell"
  (lambda ()
    (let ((rounds 5))
      (test-equal "four threads each resume eight waits: each request is answered once, with its own value, each resume answering #t, nothing logged; five rounds"
                  (make-list rounds '(satisfied satisfied () () ()))
                  (map (lambda (k) (delivered-round 4 8 #f)) (iota rounds)))

      (test-equal "four threads post sixteen values each at once, released by a barrier once every wait has parked: nothing is lost to coalesced wakes; five rounds"
                  (make-list rounds '(satisfied satisfied () () ()))
                  (map (lambda (k) (delivered-round 4 16 #t)) (iota rounds)))

      (let ((sleeping (sleeping-loop)))
        (test-equal "a loop asleep in its poll, nothing armed but the inbox, wakes for a post from another thread: the answer comes, and not by the watchdog's wake"
                    '(satisfied ((200 "v0")) #t #f)
                    (list-head sleeping 4))
        (test-equal "an idle server stays idle: over the worker's window, opened once the shell's tick timer has stopped, an inbox open and nothing posted, the loop takes no turn"
                    'idle
                    (list-ref sleeping 4)))

      (let ((races (map (lambda (k) (deadline-round)) (iota rounds))))
        (put-string (current-output-port)
                    (string-append "outside-shell: of the 6 posts about their deadline, each round,"
                                   (fold-left (lambda (acc race) (string-append acc " " (number->string (list-ref race 4))))
                                              "" races)
                                   " beat it\n"))
        (test-equal "a post races a deadline: each request is answered once, its own value or 504, a value after its deadline dropped and nothing logged; five rounds"
                    (make-list rounds '(satisfied () () ()))
                    (map (lambda (race) (list-head race 4)) races)))

      (let ((stops (map stop-round (iota rounds))))
        (put-string (current-output-port)
                    (string-append "outside-shell: of 16 requests waiting at the stop, each round,"
                                   (fold-left (lambda (acc stop) (string-append acc " " (number->string (list-ref stop 6))))
                                              "" stops)
                                   " were answered\n"))
        (test-equal "a post races the stop: the run ends, each thread's resumes answer #t until one answers #f, #f once the server has stopped, every resume called again answers #f, nothing raises, nothing is logged but the drain; five rounds"
                    (make-list rounds '(satisfied satisfied () () () ()))
                    (map (lambda (stop) (list-head stop 6)) stops))))

    (test-equal "await-outside, await and sleep-ms from a worker, while the loop's thread runs a handler's coroutine that waits for it, are each refused there as R2, off the loop's thread: no register runs, no async handle is made, and the handler answers as before"
                (list 'satisfied (make-list 4 off-thread) '() '((200 "ok")) 0 '())
                (off-thread-mid-coroutine))
    (test-equal "await-outside, await and sleep-ms from a worker, while the loop's thread is asleep in its poll, a handler parked outside, are each refused there as R2, off the loop's thread, not as R1: no register runs, and the handler's resume, posted after, is handed over"
                (list 'satisfied #f (make-list 4 off-thread) '() #t '((200 "v0")) '())
                (off-thread-in-poll))

    (test-equal "a loop torn down under an open inbox closes its handle: each kept resume then answers #f, from another thread, raising nothing"
                '(satisfied 1 (#f #f))
                (torn-down))

    (test-equal "a loop's first outside wait makes its one async handle, and its shell's stop closes it; a second shell's outside wait on the loop opens a fresh inbox and is answered, the first inbox's resume answering #f"
                '(satisfied ((200 "plain")) 0 satisfied 1 #t satisfied ((200 "v1"))
                  satisfied satisfied #f satisfied #f #t satisfied ((200 "v2")))
                (reopened))

    (test-equal "an outside wait once no shell on the loop serves, by a coroutine that outlived its connection, makes no async handle: its resume answers #f, nothing is handed over, and the loop drains"
                '(satisfied satisfied 0 satisfied 0 #f iterations-exhausted never satisfied 0)
                (outlived))
    (test-equal "two shells on one loop: the first stops, and is shut down again, while the second's outside wait is parked, and the second's resume is still handed over; the second's stop closes the inbox's handle"
                '(satisfied satisfied 1 #t satisfied ((200 "v1")) satisfied satisfied)
                (two-shells))
    (test-equal "a post while the server drains is handed over: the resume answers #t, and the client is answered before the drain's deadline"
                '(satisfied draining #t satisfied ((200 "v1")) satisfied #f)
                (drained-post))
    (test-equal "an inbox closed while its async handle is open, by its waits alone: its resume answers #f, and the shell's stop still closes the handle"
                '(satisfied 1 #f satisfied satisfied)
                (closed-under-open-handle))

    (test-equal "one thread posts 1 to 16 to sixteen waits while the loop polls nothing: the handlers resume in that order"
                (list 'satisfied 'satisfied (map (lambda (i) (+ i 1)) (iota 16)))
                (ordered #t))
    (test-equal "one thread posts 1 to 16 to sixteen waits a post at a time while the loop polls: the handlers resume in that order"
                (list 'satisfied 'satisfied (map (lambda (i) (+ i 1)) (iota 16)))
                (ordered #f))

    (test-equal "a worker asleep in a collect-safe C call keeps no one waiting: a request whose handler forces a collection is answered while the worker still sleeps, and the worker's own is answered after"
                '(satisfied satisfied ((200 "collected")) #f satisfied ((200 "slept")) #t)
                (blocked-worker))

    (test-equal "after each stop, no handle is left on the loop"
                '()
                (filter (lambda (l) (not (equal? (cdr l) '(satisfied ())))) leftovers))))
