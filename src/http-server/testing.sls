#!r6rs
;;; (http-server testing) — a handler run against scripted requests, its
;;; waits included, with no socket and no real time.
;;;
;;; A TEST HOST runs a handler, the one `serve` would be given, with the
;;; settings an environment procedure gives, read as `serve` reads them;
;;; without one, every setting is its default, and the process's environment
;;; is not read.  Nothing listens, so the host is never told CHEZ_HTTP_HOST is
;;; not an IP literal: only `serve`'s bind refuses that.  A test connects
;;; clients to it.  Each client sends bytes, closes or resets, and reads what
;;; the server wrote back, parsed into responses.  Each client's connection
;;; is (http-server private fake-shell)'s: the server's own core and parser,
;;; the shell's work done with no I/O.
;;;
;;; ONE SCHEDULER AND ONE WAITS, the host's, as the libuv shell keeps one a
;;; loop: every connection runs its handler's calls and coroutines on the
;;; host's scheduler, which runs what is ready in the order it was made
;;; ready, whichever connection it is for; and every wait is in the host's
;;; waits, made with make-waits as the libuv shell makes its loop's: their
;;; log is the host's, their clock the host's, their timer one whose instant
;;; the host keeps, and their resolver the host's.
;;;
;;; NOTHING RUNS BUT WHAT THE TEST DOES.  Each call that acts, a connect, a
;;; send, a close, a reset, an advance or an answer, runs the host until it
;;; is quiet, and then returns: every event that follows is dispatched, every
;;; write is read by the client at once, and every coroutine made ready runs.
;;; Nothing runs between calls: a resume the test calls itself runs at the
;;; host's next call, as an advance of 0 ms.  Nothing hangs: a handler that
;;; waits for what never comes stays parked, and is reported
;;; (test-client-waiting?), and a run that takes more than `turn-cap` turns
;;; to go quiet, as a producer that never ends or a handler that sleeps 0 ms
;;; forever makes it, is an assertion violation.  A call that acts, made
;;; from the host's own code, a handler's, a coroutine's or a taker's, is
;;; refused as an assertion violation, raised in that code.
;;;
;;; THE CLOCK is the host's: milliseconds from 0, which the Date field reads
;;; as seconds since the Unix epoch.  It moves only when the test advances
;;; it.  As it passes an instant something is due at, a sleep's end, a
;;; deadline or a connection's timeout, that fires at that instant, in
;;; order, and what it wakes runs there.  A connection's timeout fires at its
;;; earliest instant, where the server's tick fires it as much as
;;; CHEZ_HTTP_TICK_MS later.
;;;
;;; A CLIENT SENDS bytes as they go on the wire, so a request may be
;;; malformed, pipelined, or have its body sent in pieces, now or after an
;;; advance.  The server reads them as it reads a socket: at most its read
;;; buffer at a time, and only while it reads.  What it does not read yet is
;;; kept, as the kernel keeps it, and read once it reads again.  A close is
;;; the client's end, and a reset ECONNRESET, each read after what the client
;;; sent before it.  A client that has closed or reset sends no more, and one
;;; that has reset reads nothing written after it.  A write the server makes
;;; after a reset it has not read completes as any other: the server learns
;;; of the reset only when it reads it.
;;;
;;; WHAT THE CLIENT READ is every byte the server wrote, and the responses
;;; they make, read by chez-httparse's response parser: each one's status,
;;; reason, fields and body, de-chunked, with its own bytes beside them.
;;; Which request a response answers comes from the requests the client
;;; sent, read by the parser the server reads them with, so a response to a
;;; HEAD is read with no body.  A 1xx is a response of its own, and answers
;;; no request.  After a 101 the bytes are another protocol's, and the
;;; parser reads no response past it.  A response is read once its head is
;;; in: one not yet whole is read as far as it goes and is not complete,
;;; unless the server has ended the connection and its body is the one that
;;; end delimits.
;;;
;;; THE LOG holds what the server logs, in order, each entry `(what .
;;; details)`, as `serve` logs `what` and its details on a line: the core's
;;; entries, such as `read-error`; `handler-failed` with what the handler,
;;; its reader or its producer raised, unless it is the close its client
;;; made, or its pulled body's failure, which the server does not log;
;;; `late-resume` with the verb;
;;; `taker-failed` with what a taker raised; and `on-done-failed` with what
;;; a procedure `request-on-done!` registered raised.  One raise the server
;;; logs is not here: that of a call into the handler's code that ends
;;; after its connection has closed, whose answer the fake shell drops
;;; unread.
;;;
;;; A LOOKUP that `resolve` asks for waits until the test answers it, with
;;; the addresses or the reason the name does not resolve.  A deadline that
;;; ends a lookup cancels it: it waits no more, and answers later, as
;;; libuv's does, with EAI_CANCELED, which the waits log as a late resume.
;;;
;;; A host has no listener, so no connection cap and no backlog, and no
;;; drain; its clients read every write as it is made.  A request and a
;;; reset that arrive in one turn of the server's loop may close the
;;; connection before its handler is called; the host reads the reset after
;;; the request, and always calls it.
(library (http-server testing)
  (export make-test-host test-host? test-host-now test-host-advance! test-host-log
          test-host-lookups test-host-answer! test-host-waiting test-host-connect!
          test-client? test-client-send! test-client-close! test-client-reset!
          test-client-received test-client-responses test-client-connection-closed?
          test-client-waiting?
          test-response? test-response-status test-response-reason test-response-headers
          test-response-header test-response-body test-response-bytes test-response-complete?)
  (import (rnrs)
          (byte-machine runtime) (generated httparse-message) (httparse modes) (httparse methods)
          (only (http-server connection) conn-parser-callbacks conn-span-callbacks)
          (only (http-server headers) headers-ref trim-ows)
          (only (http-server limits) limits-read-buffer-size)
          (only (http-server awaiting) client-closed?)
          (only (http-server private adapter) request-parser-inits)
          (only (http-server private scheduler) make-scheduler scheduler-ready? scheduler-drain!)
          (only (http-server private waits) make-waits waits-clock! waits-resolver! waits-fire!)
          (only (http-server private serve) settings)
          (only (http-server private fake-shell)
                make-fake-connection fake-shell-advance! fake-shell-fire! fake-shell-armed
                fake-shell-deliver! fake-shell-deliver-later! fake-shell-reading? fake-shell-writes
                fake-shell-taker-failures fake-shell-done-failures fake-shell-calling?
                fake-shell-pull-failure?
                fake-waits-puller!))

  ;; --- the host ---------------------------------------------------------------

  ;; test-host? : Any -> Boolean
  ;; test-host-now : TestHost -> Nat — the host's clock, in milliseconds
  ;; A host: the handler, the limits, the clock, its scheduler and its
  ;; waits, and when their timer is due, or #f; its clients in the order
  ;; they connected; what it has logged, newest first; the lookups that wait
  ;; for an answer, oldest first, and those a deadline cancelled, which
  ;; answer at the next turn; whether a call that acts runs; and the turns
  ;; its run to quiet has taken.
  (define-record-type (test-host %make-test-host test-host?)
    (fields handler limits (mutable now) (mutable scheduler) (mutable waits) (mutable due)
            (mutable clients) (mutable log-rev) (mutable asked) (mutable cancelled)
            (mutable running?) (mutable turns))
    (sealed #t))

  ;; A lookup `resolve` asked for: the name, and how it is answered.
  (define-record-type asked (fields name answer!) (sealed #t))

  ;; make-test-host : (Request -> (U Answer Switch)) [(String -> (U String #f))] -> TestHost
  ;; Answer as (http-server awaiting) defines it, Switch as (http-server switch).
  ;; A host for `handler`, its clock at 0, with the settings `lookup` gives,
  ;; read as `serve` reads them, every setting its default without it.  A
  ;; malformed setting raises &http-server-config-error, as `serve` does
  ;; before it listens; a CHEZ_HTTP_HOST that is not an IP literal, which
  ;; `serve` refuses only at its bind, is not refused.
  (define make-test-host
    (case-lambda
      ((handler) (make-test-host handler (lambda (name) #f)))
      ((handler lookup)
       (unless (procedure? handler) (assertion-violation 'make-test-host "the handler is not a procedure" handler))
       (unless (procedure? lookup) (assertion-violation 'make-test-host "the lookup is not a procedure" lookup))
       (let-values (((limits host port) (settings lookup)))
         (let ((h (%make-test-host handler limits 0 #f #f #f '() '() '() '() #f 0)))
           (host-waits! h)
           h)))))

  ;; host-waits! : TestHost -> Void
  ;; The host's scheduler, which never polls, and its waits (ONE SCHEDULER
  ;; AND ONE WAITS), given the fake's puller, so a handler may pull its body.
  ;; A lookup a deadline cancels answers at the next turn, as cancelled.
  (define (host-waits! host)
    (let* ((s (make-scheduler (lambda (mode) (assertion-violation 'test-host "the host never polls" mode))))
           (w (make-waits s (lambda (what details) (log! host what details)))))
      (waits-clock! w
                    (lambda () (test-host-now host))
                    (lambda (ms) (test-host-due-set! host (+ (test-host-now host) ms)))
                    (lambda () (test-host-due-set! host #f)))
      (waits-resolver! w
                       (lambda (name answer!)
                         (let ((l (make-asked name answer!)))
                           (test-host-asked-set! host (append (test-host-asked host) (list l)))
                           l))
                       (lambda (l)
                         (when (memq l (test-host-asked host))
                           (test-host-asked-set! host (remq l (test-host-asked host)))
                           (test-host-cancelled-set! host (append (test-host-cancelled host) (list l))))))
      (fake-waits-puller! w)
      (test-host-scheduler-set! host s)
      (test-host-waits-set! host w)))

  ;; test-host-log : TestHost -> (Listof (Pair Symbol (Listof Any)))
  ;; What the server has logged, in order, each `(what . details)`.
  (define (test-host-log host) (reverse (test-host-log-rev host)))

  ;; log! : TestHost Symbol (Listof Any) -> Void
  ;; An entry, after any on-done-failed not yet logged (on-done-failed!).
  (define (log! host what details)
    (on-done-failed! host)
    (record! host what details))

  ;; record! : TestHost Symbol (Listof Any) -> Void — an entry, as it is.
  (define (record! host what details)
    (test-host-log-rev-set! host (cons (cons what details) (test-host-log-rev host))))

  ;; on-done-failed! : TestHost -> Void
  ;; What each client's connection recorded of the procedures told a
  ;; response's end raising, not yet logged, logged `on-done-failed`, as the
  ;; libuv shell logs each where it is raised.  The fake shell records them
  ;; and traces nothing, so the host logs them before the next entry, the
  ;; next trace and the end of each round: after what came before them, and
  ;; before what came after.
  (define (on-done-failed! host)
    (for-each
     (lambda (c)
       (let ((s (test-client-shell c)))
         (when s
           (let* ((all (fake-shell-done-failures s)) (n (length all)))
             (when (> n (test-client-done-failures c))
               (for-each (lambda (e) (record! host 'on-done-failed (list e)))
                         (list-tail all (test-client-done-failures c)))
               (test-client-done-failures-set! c n))))))
     (test-host-clients host)))

  ;; test-host-lookups : TestHost -> (Listof String)
  ;; The names `resolve` has asked for and the test has not answered, in
  ;; the order asked.
  (define (test-host-lookups host) (map asked-name (test-host-asked host)))

  ;; test-host-answer! : TestHost String (U (Listof String) Symbol) -> Void
  ;; Answer the oldest lookup of `name`: with addresses, which `resolve`
  ;; returns, or with a reason, such as EAI_NONAME, which it raises as
  ;; &resolve-error.  Then run the host until it is quiet.  A name no lookup
  ;; waits for is an assertion violation.
  (define (test-host-answer! host name answer)
    (acting! host 'test-host-answer!)
    (unless (string? name) (assertion-violation 'test-host-answer! "the name is not a string" name))
    (unless (or (symbol? answer) (and (list? answer) (for-all string? answer)))
      (assertion-violation 'test-host-answer! "expected a list of addresses, as strings, or a reason, a symbol" answer))
    (let ((l (find (lambda (l) (string=? (asked-name l) name)) (test-host-asked host))))
      (unless l (assertion-violation 'test-host-answer! "no lookup of the name waits for an answer" name))
      (test-host-asked-set! host (remq l (test-host-asked host)))
      (if (symbol? answer)
          ((asked-answer! l) answer '())
          ((asked-answer! l) #f answer))
      (quiesce! host)))

  ;; test-host-waiting : TestHost -> (Listof TestClient)
  ;; The clients whose handler's code still waits, in the order they
  ;; connected (test-client-waiting?).
  (define (test-host-waiting host) (filter test-client-waiting? (test-host-clients host)))

  ;; test-host-advance! : TestHost Nat -> Void
  ;; Move the clock `ms` milliseconds on, stopping at each instant something
  ;; is due by then, a sleep's end, a deadline or a connection's timeout,
  ;; for it to fire there and for what it wakes to run, until the host is
  ;; quiet; then on to the end.  An advance of 0 runs what is ready.
  (define (test-host-advance! host ms)
    (acting! host 'test-host-advance!)
    (unless (and (integer? ms) (exact? ms) (>= ms 0))
      (assertion-violation 'test-host-advance! "expected a whole number of milliseconds" ms))
    (let ((target (+ (test-host-now host) ms)))
      (let loop ()
        (let ((next (next-due host)))
          (cond ((and next (<= next target))
                 (clock-to! host (max next (test-host-now host)))
                 (quiesce! host)
                 (loop))
                (else
                 (clock-to! host target)
                 (quiesce! host)))))))

  ;; acting! : TestHost Symbol -> Void
  ;; Refuse a call that acts, `who`, made while one runs: from the host's own
  ;; code, a handler's say.
  (define (acting! host who)
    (when (test-host-running? host)
      (assertion-violation who "a call that acts, made from the host's own code" host)))

  ;; clock-to! : TestHost Nat -> Void — the host's clock, and every
  ;; connection's, at `t`.
  (define (clock-to! host t)
    (let ((dt (- t (test-host-now host))))
      (test-host-now-set! host t)
      (for-each (lambda (c) (fake-shell-advance! (test-client-shell c) dt)) (test-host-clients host))))

  ;; next-due : TestHost -> (U Nat #f)
  ;; The earliest instant something is due at: the waits' timer, or a
  ;; connection's deadline; #f when nothing is.
  (define (next-due host)
    (fold-left (lambda (best c) (earliest best (fake-shell-armed (test-client-shell c))))
               (test-host-due host) (test-host-clients host)))

  ;; earliest : (U Nat #f) (U Nat #f) -> (U Nat #f)
  (define (earliest a b)
    (cond ((not a) b) ((not b) a) (else (min a b))))

  ;; turn-cap : Nat — turns a run to quiet may take before the host is
  ;; stuck: rounds of quiesce!, and later turns of a connection.
  (define turn-cap 100000)

  ;; turn! : TestHost -> Void — one more turn, refused past turn-cap.
  (define (turn! host)
    (test-host-turns-set! host (+ (test-host-turns host) 1))
    (when (> (test-host-turns host) turn-cap)
      (assertion-violation 'test-host "no progress: the host did not go quiet" turn-cap)))

  ;; quiesce! : TestHost -> Void
  ;; Run the host until nothing has anything to do: what is due by the
  ;; clock fires, what is ready runs, each connection's later turns come and
  ;; the client's bytes are read while the server reads, and the lookups a
  ;; deadline cancelled answer; and again, while any of that is left.  While
  ;; it runs, a call that acts is refused (acting!).
  (define (quiesce! host)
    (test-host-turns-set! host 0)
    (dynamic-wind
     (lambda () (test-host-running?-set! host #t))
     (lambda ()
       (let loop ()
         (turn! host)
         (fire! host)
         (for-each (lambda (c) (settle! c) (pump! c) (taker-failed! host c)) (test-host-clients host))
         (on-done-failed! host)
         (answer-cancelled! host)
         (when (busy? host) (loop))))
     (lambda () (test-host-running?-set! host #f))))

  ;; busy? : TestHost -> Boolean
  ;; Whether something is left to do: a coroutine or a call ready, the
  ;; waits' timer or a connection's deadline due, a cancelled lookup to
  ;; answer, or bytes or an end to read while the server reads.
  (define (busy? host)
    (let ((now (test-host-now host)))
      (or (scheduler-ready? (test-host-scheduler host))
          (let ((due (test-host-due host))) (and due (<= due now)))
          (pair? (test-host-cancelled host))
          (exists (lambda (c)
                    (or (let ((armed (fake-shell-armed (test-client-shell c)))) (and armed (<= armed now)))
                        (and (reads? c) (or (unread? c) (test-client-end c)) #t)))
                  (test-host-clients host)))))

  ;; fire! : TestHost -> Void
  ;; What is due by the clock fires: the waits' timer, and what it wakes
  ;; runs; then each connection's deadline, in the order they connected.
  (define (fire! host)
    (let ((now (test-host-now host)) (due (test-host-due host)))
      (when (and due (<= due now))
        (test-host-due-set! host #f)
        (waits-fire! (test-host-waits host))
        (scheduler-drain! (test-host-scheduler host)))
      (for-each (lambda (c)
                  (let ((armed (fake-shell-armed (test-client-shell c))))
                    (when (and armed (<= armed now))
                      (fake-shell-fire! (test-client-shell c)))))
                (test-host-clients host))))

  ;; answer-cancelled! : TestHost -> Void
  ;; Each lookup a deadline cancelled answers, as cancelled: its wait has
  ;; ended, so the waits log a late resume.
  (define (answer-cancelled! host)
    (let ((cancelled (test-host-cancelled host)))
      (test-host-cancelled-set! host '())
      (for-each (lambda (l) ((asked-answer! l) 'EAI_CANCELED '())) cancelled)))

  ;; --- a client ---------------------------------------------------------------

  ;; test-client? : Any -> Boolean
  ;; test-client-connection-closed? : TestClient -> Boolean — whether the
  ;;   server has ended the connection: shut its side, or closed it, so that
  ;;   the client reads the end after the bytes it has read
  ;; A client: its host and its connection; each send, newest first; what
  ;; the server has not read of them, from `from` on; its end, 'eof or
  ;; 'reset, until the server reads it; whether it has closed or reset;
  ;; once it has reset, how many writes it had read and whether the server
  ;; had ended the connection by then, or #f; whether the server has ended
  ;; the connection; whether the client's close has been told to the
  ;; request's code; whether the connection is handed off; and how many of a
  ;; taker's failures are logged, and how many of the raises of the
  ;; procedures told a response's end.
  (define-record-type (test-client %make-test-client test-client?)
    (fields host (mutable shell)
            (mutable sent-rev) (mutable unread) (mutable from) (mutable end) (mutable left?)
            (mutable cut) (mutable connection-closed?) (mutable told?) (mutable handed-off?)
            (mutable failures) (mutable done-failures))
    (protocol (lambda (new)
                (lambda (host) (new host #f '() (make-bytevector 0) 0 #f #f #f #f #f #f 0 0))))
    (sealed #t))

  ;; test-host-connect! : TestHost -> TestClient
  ;; A client connected to the host now, its connection idle.
  (define (test-host-connect! host)
    (acting! host 'test-host-connect!)
    (let ((c (%make-test-client host)))
      (test-client-shell-set! c (make-fake-connection (test-host-limits host) (test-host-handler host)
                                                      (tracer host c) (test-host-now host) #f
                                                      (test-host-scheduler host)))
      (test-host-clients-set! host (append (test-host-clients host) (list c)))
      (quiesce! host)
      c))

  ;; tracer : TestHost TestClient -> (Symbol Any -> Void)
  ;; The connection's trace: what the server logs, whether the client's
  ;; close was told to the request's code, whether the server has ended the
  ;; connection, and whether it is handed off, read from each event and
  ;; action as the fake shell takes it.  The request's notice is the fake
  ;; shell's from a `client-closed` to the next request's `resume-parser`.
  (define (tracer host c)
    (lambda (kind datum)
      (on-done-failed! host)
      (case kind
        ((event)
         (when (eq? (car datum) 'handler-failed)
           (let ((e (cadr datum)))
             (unless (or (and (client-closed? e) (test-client-told? c))
                         (fake-shell-pull-failure? (test-client-shell c) e))
               (log! host 'handler-failed (list e))))))
        ((action)
         (case (car datum)
           ((log) (log! host (cadr datum) (cddr datum)))
           ((client-closed) (test-client-told?-set! c #t))
           ((resume-parser) (test-client-told?-set! c #f))
           ((shutdown close) (test-client-connection-closed?-set! c #t))
           ((hand-off) (test-client-handed-off?-set! c #t))))
        ((door)
         (when (member datum '((stream-shut) (stream-close)))
           (test-client-connection-closed?-set! c #t))
         (taker-failed! host c)))))

  ;; taker-failed! : TestHost TestClient -> Void
  ;; Each failure of the taker's not yet logged, logged `taker-failed`.
  (define (taker-failed! host c)
    (when (test-client-handed-off? c)
      (let* ((all (fake-shell-taker-failures (test-client-shell c)))
             (n (length all)))
        (when (> n (test-client-failures c))
          (for-each (lambda (e) (log! host 'taker-failed (list e))) (list-tail all (test-client-failures c)))
          (test-client-failures-set! c n)))))

  ;; test-client-send! : TestClient Bytevector -> Void
  ;; Send `bytes`, copied, after what the client has sent, and run the host
  ;; until it is quiet.  A client that has closed or reset sends no more: an
  ;; assertion violation.
  (define (test-client-send! c bytes)
    (acting! (test-client-host c) 'test-client-send!)
    (unless (bytevector? bytes) (assertion-violation 'test-client-send! "not a bytevector" bytes))
    (when (test-client-left? c) (assertion-violation 'test-client-send! "the client has closed or reset" bytes))
    (let ((sent (copy-of bytes 0 (bytevector-length bytes))))
      (test-client-sent-rev-set! c (cons sent (test-client-sent-rev c)))
      (test-client-unread-set! c (join (list (copy-of (test-client-unread c) (test-client-from c)
                                                      (bytevector-length (test-client-unread c)))
                                             sent)))
      (test-client-from-set! c 0)
      (quiesce! (test-client-host c))))

  ;; test-client-close! : TestClient -> Void
  ;; The client closes its side: the server reads its end after what it
  ;; sent.  Then the host runs until it is quiet.
  ;; test-client-reset! : TestClient -> Void
  ;; The client resets the connection: the server reads ECONNRESET after
  ;; what it sent, and the client reads nothing written from now on.  Then
  ;; the host runs until it is quiet.
  ;; Either, once the client has closed or reset, is an assertion violation.
  (define (test-client-close! c) (leave! 'test-client-close! c 'eof))
  (define (test-client-reset! c) (leave! 'test-client-reset! c 'reset))

  ;; leave! : Symbol TestClient (U 'eof 'reset) -> Void
  (define (leave! who c end)
    (acting! (test-client-host c) who)
    (when (test-client-left? c) (assertion-violation who "the client has closed or reset" c))
    (test-client-left?-set! c #t)
    (test-client-end-set! c end)
    (when (eq? end 'reset)
      (test-client-cut-set! c (cons (length (fake-shell-writes (test-client-shell c)))
                                    (test-client-connection-closed? c))))
    (quiesce! (test-client-host c)))

  ;; reads? : TestClient -> Boolean
  ;; Whether what the client sends is read now: while the server reads,
  ;; or, once handed off, always, the fake shell keeping what the taker
  ;; does not read.
  (define (reads? c)
    (or (test-client-handed-off? c) (fake-shell-reading? (test-client-shell c))))

  ;; unread? : TestClient -> Boolean — whether some of what it sent is unread.
  (define (unread? c) (< (test-client-from c) (bytevector-length (test-client-unread c))))

  ;; settle! : TestClient -> Void
  ;; The connection's later turns, oldest first, until none is left, each a
  ;; turn of the host's, with what is ready run before each.
  (define (settle! c)
    (let ((host (test-client-host c)))
      (let loop ()
        (scheduler-drain! (test-host-scheduler host))
        (when (fake-shell-deliver-later! (test-client-shell c))
          (turn! host)
          (loop)))))

  ;; pump! : TestClient -> Void
  ;; What the server has not read, read while it reads: at most its read
  ;; buffer at a time, each later turn coming in between, and then the
  ;; client's end.
  (define (pump! c)
    (let ((sh (test-client-shell c))
          (size (limits-read-buffer-size (test-host-limits (test-client-host c)))))
      (let loop ()
        (when (reads? c)
          (cond ((unread? c)
                 (let* ((unread (test-client-unread c))
                        (from (test-client-from c))
                        (to (min (bytevector-length unread) (+ from size))))
                   (test-client-from-set! c to)
                   (fake-shell-deliver! sh (list 'bytes-arrived unread from to))
                   (settle! c)
                   (loop)))
                ((test-client-end c)
                 => (lambda (end)
                      (test-client-end-set! c #f)
                      (fake-shell-deliver! sh (if (eq? end 'reset) '(read-error ECONNRESET) '(eof)))
                      (settle! c))))))))

  ;; test-client-waiting? : TestClient -> Boolean
  ;; Whether the handler's code on its connection still waits: the handler
  ;; that answered `awaiting`, or its reader or producer, parked in a wait.
  ;; A taker's code is not counted.
  (define (test-client-waiting? c) (fake-shell-calling? (test-client-shell c)))

  ;; test-client-received : TestClient -> Bytevector
  ;; Every byte the client has read, in order: once it has reset, what was
  ;; written before.
  (define (test-client-received c)
    (let ((writes (fake-shell-writes (test-client-shell c))) (cut (test-client-cut c)))
      (join (if cut (list-head writes (car cut)) writes))))

  ;; list-head : (Listof Any) Nat -> (Listof Any) — the first `n`.
  (define (list-head xs n)
    (if (or (zero? n) (null? xs)) '() (cons (car xs) (list-head (cdr xs) (- n 1)))))

  ;; test-client-responses : TestClient -> (Listof TestResponse)
  ;; The responses the client has read, in order (WHAT THE CLIENT READ).
  ;; Once it has reset, it has read the server's end only if that came
  ;; before.
  (define (test-client-responses c)
    (read-responses (test-client-received c)
                    (request-methods (join (reverse (test-client-sent-rev c))))
                    (let ((cut (test-client-cut c)))
                      (if cut (cdr cut) (test-client-connection-closed? c)))))

  ;; --- what the client read -----------------------------------------------------

  ;; test-response? : Any -> Boolean
  ;; test-response-status : TestResponse -> Nat
  ;; test-response-reason : TestResponse -> Bytevector — the reason phrase
  ;; test-response-headers : TestResponse -> (Listof (Pair Bytevector Bytevector))
  ;;   — each field, its name as sent and its value without the spaces
  ;;   around it, in order, as make-response takes them
  ;; test-response-body : TestResponse -> Bytevector — the body, de-chunked
  ;; test-response-bytes : TestResponse -> Bytevector — the response's
  ;;   bytes on the wire, from its status line to its body's end
  ;; test-response-complete? : TestResponse -> Boolean — whether all of it
  ;;   has been read
  (define-record-type (test-response %make-test-response test-response?)
    (fields status reason headers body bytes complete?)
    (sealed #t))

  ;; test-response-header : TestResponse String -> (U Bytevector #f)
  ;; The value of the first field named `name`, in any case, or #f.
  (define (test-response-header r name)
    (unless (string? name) (assertion-violation 'test-response-header "the name is not a string" name))
    (headers-ref (test-response-headers r) (string->utf8 name)))

  ;; bindings : (Symbol -> (U Procedure #f)) -> (Listof (List Symbol Procedure))
  ;; The binding list chez-httparse requires, all twenty-five callbacks:
  ;; `own`'s procedure for each it gives, and for the rest one that goes on.
  (define (bindings own)
    (map (lambda (name)
           (list name
                 (or (own name)
                     (if (memq name conn-span-callbacks)
                         (lambda (p ctx bv from to) callback-continue)
                         (lambda (p ctx) callback-continue)))))
         conn-parser-callbacks))

  ;; head-method : Nat — llhttp's number for HEAD.
  (define head-method (httparse-method-number 'HEAD))

  ;; request-methods : Bytevector -> (Listof Nat)
  ;; The method of each request in `sent`, by llhttp's number, in order, as
  ;; far as they parse, read with the parser the server reads requests with
  ;; (request-parser-inits).
  (define (request-methods sent)
    (let* ((methods '())
           (p (make-parser httparse-message-machine
                           (bindings
                            (lambda (name)
                              (case name
                                ((on-headers-complete)
                                 (lambda (p ctx)
                                   (set! methods (cons (parser-field-ref p 'method) methods))
                                   callback-continue))
                                ((on-message-complete) (lambda (p ctx) callback-pause))
                                (else #f))))
                           #f
                           request-parser-inits)))
      (let loop ((from 0))
        (let ((r (parser-feed! p sent from (bytevector-length sent))))
          (when (eq? (parser-result-status r) 'paused)
            (parser-resume! p)
            (loop (parser-result-next r)))))
      (reverse methods)))

  ;; response-inits : (Listof (Pair Symbol Any)) — a parser for responses.
  (define response-inits
    (list (cons 'type (httparse-message-type-value 'response))))

  ;; read-responses : Bytevector (Listof Nat) Boolean -> (Listof TestResponse)
  ;; The responses in `wire`, in order: each but a 1xx answers the next of
  ;; `methods`, the requests' methods.  `ended?` says the client has read the
  ;; server's end after `wire`.
  (define (read-responses wire methods ended?)
    (let ((status #f) (reason '()) (name '()) (value '()) (fields '()) (body '())
          (complete? #f) (owed methods) (len (bytevector-length wire)))
      (define (reset!)
        (set! status #f) (set! reason '()) (set! name '()) (set! value '())
        (set! fields '()) (set! body '()) (set! complete? #f))
      (define (keep! acc bv from to) (cons (copy-of bv from to) acc))
      (define (head! s)
        (set! status s)
        (if (< s 200)
            callback-continue
            (let ((m (and (pair? owed) (car owed))))
              (when (pair? owed) (set! owed (cdr owed)))
              (if (eqv? m head-method) 'skip-body callback-continue))))
      (define (field! name value)
        (let-values (((from to) (trim-ows value 0 (bytevector-length value))))
          (set! fields (cons (cons name (copy-of value from to)) fields))))
      (define (response from to whole?)
        (%make-test-response status (join (reverse reason)) (reverse fields) (join (reverse body))
                             (copy-of wire from to) whole?))
      (let ((p (make-parser
                httparse-message-machine
                (bindings
                 (lambda (n)
                   (case n
                     ((on-message-begin) (lambda (p ctx) (reset!) callback-continue))
                     ((on-status-data)
                      (lambda (p ctx bv from to) (set! reason (keep! reason bv from to)) callback-continue))
                     ((on-header-field-data)
                      (lambda (p ctx bv from to) (set! name (keep! name bv from to)) callback-continue))
                     ((on-header-value-data)
                      (lambda (p ctx bv from to) (set! value (keep! value bv from to)) callback-continue))
                     ((on-header-value-complete)
                      (lambda (p ctx)
                        (field! (join (reverse name)) (join (reverse value)))
                        (set! name '())
                        (set! value '())
                        callback-continue))
                     ((on-headers-complete) (lambda (p ctx) (head! (parser-field-ref p 'status-code))))
                     ((on-body-data)
                      (lambda (p ctx bv from to) (set! body (keep! body bv from to)) callback-continue))
                     ((on-message-complete) (lambda (p ctx) (set! complete? #t) callback-pause))
                     (else #f))))
                #f
                response-inits)))
        (let loop ((from 0) (out '()))
          (let* ((r (parser-feed! p wire from len))
                 (st (parser-result-status r)))
            (cond
             ((and complete? (eq? st 'paused))
              (let* ((next (parser-result-next r))
                     (out (cons (response from next #t) out)))
                (reset!)
                (parser-resume! p)
                (loop next out)))
             ((not status) (reverse out))
             ((and ended? (eq? st 'need-input))
              (parser-finish! p)
              (reverse (cons (response from len complete?) out)))
             (else (reverse (cons (response from len #f) out)))))))))

  ;; copy-of : Bytevector Nat Nat -> Bytevector — bv[from, to), copied.
  (define (copy-of bv from to)
    (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o))

  ;; join : (Listof Bytevector) -> Bytevector — the bytevectors, in order, as one.
  (define (join bvs)
    (let ((o (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 bvs))))
      (fold-left (lambda (at bv)
                   (bytevector-copy! bv 0 o at (bytevector-length bv))
                   (+ at (bytevector-length bv)))
                 0 bvs)
      o)))
