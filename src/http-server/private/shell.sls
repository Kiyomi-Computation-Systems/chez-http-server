#!r6rs
;;; (http-server private shell) — the direct libuv shell (design §5.2; M4.2).
;;;
;;; The core is pure (decision 0002); this is where its actions happen.  A
;;; SHELL holds what every connection on one loop shares: the handler, the
;;; limits, the clock and the Date line made from it, the log, and the
;;; connection table.  A CONNECTION is one accepted TCP handle, the core's
;;; state in the adapter's context, a parser on the adapter's one binding
;;; list, and the closures chez-libuv calls, each of which turns what
;;; happened into one of the core's events and dispatches it (decision 0003
;;; item 1).  None runs application code but the handler's call, and none
;;; captures a continuation.
;;;
;;; THE MESSAGE LOOP is the fake shell's (design §4.5).  Actions run after the
;;; outermost dispatch, in order, from one queue; a dispatch made while the
;;; queue drains, or while the parser feeds, only queues.  `depth` counts the
;;; drain and a feed inside it.  An action run anywhere but the outermost
;;; drain is a VIOLATION, recorded (design §6.4, the second hazard):
;;; byte-machine poisons a parser whose callback escapes, and chez-libuv
;;; defers the raise, so the one action answered inside a parser callback is
;;; `reply-parser`, which the adapter answers without reaching the queue.
;;;
;;; THE ACTIONS, performed:
;;;   feed-parser     parser-feed!, counted in the depth, then its result as
;;;                   `parser-result`
;;;   resume-parser   parser-resume!
;;;   call-handler    the handler's response as `handler-responded`, or, if
;;;                   the handler raises, `handler-failed`, logged
;;;   write           uv-write*!, the Date slot filled from the clock (decision
;;;                   0010); its completion reports `write-completed` with the
;;;                   action's byte count, which is all the completion keeps:
;;;                   chez-libuv copied the segments at the call (design §7.3)
;;;   read-stop/-start  uv-read-stop! and uv-read-start!, when reading
;;;                   changes; the first start, at adoption, fixes the read
;;;                   buffer at the limits' read-buffer-size (design §7.2)
;;;   shutdown        uv-shutdown!, the write side (decision 0011); its
;;;                   completion reports `shutdown-completed`
;;;   close           connection-close!, the one uv-close! call; the handle's
;;;                   close takes the connection out of the table and reports
;;;                   `closed`
;;;   log             the shell's log
;;; A deadline is not acted on: the wheel is M5's.  Bodies (M6) and the
;;; hand-off (M8) are never asked for in v1's flow.
;;;
;;; THE DATE is made once a second (decision 0010).  The shell's clock is read
;;; when a second of the loop's own time has passed, libuv's cached
;;; milliseconds, which cost nothing to read; between readings the second is
;;; the last reading plus the loop's time since.  A response reads no clock.
(library (http-server private shell)
  (export make-shell shell? shell-adopt! shell-connections
          connection? connection-state connection-tcp connection-violations
          connection-close!
          wall-clock)
  (import (rnrs)
          (only (chezscheme) current-time time-second time-nanosecond)
          (libuv)
          (byte-machine runtime)
          (only (http-server connection) make-conn-state)
          (only (http-server limits) limits-read-buffer-size)
          (only (http-server serializer) date-line)
          (http-server private adapter))

  ;; make-shell :
  ;;   UvLoop (Request -> Response) Limits (-> Nat) (Symbol (Listof Any) -> Any)
  ;;   [(Connection Symbol Any -> Any)] -> Shell
  ;; A shell on `loop`: the handler every connection calls, the limits every
  ;; connection is held to, the clock (milliseconds since the epoch, read at
  ;; most once a second for the Date), and the log, called with what happened
  ;; and its details.  The optional trace is called with each event a
  ;; connection dispatches and each action it runs, as (connection 'event
  ;; datum) and (connection 'action datum).  The datum is the event or the
  ;; action itself, not a copy: a trace that keeps it keeps what it holds, a
  ;; response's body among them.
  ;; shell? : Any -> Boolean
  (define-record-type (shell %make-shell shell?)
    (fields loop handler limits clock log trace table
            (mutable read-at) (mutable read-ms)       ; the clock's last reading, and when
            (mutable date-second) (mutable date-line)))

  (define make-shell
    (case-lambda
      ((loop handler limits clock log) (make-shell loop handler limits clock log #f))
      ((loop handler limits clock log trace)
       (%make-shell loop handler limits clock log trace (make-eq-hashtable) #f #f #f #f))))

  ;; wall-clock : -> Nat — milliseconds since the epoch, UTC: a shell's clock.
  (define (wall-clock)
    (let ((t (current-time 'time-utc)))
      (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

  ;; shell-connections : Shell -> (Listof Connection)
  ;; The connections adopted and not yet closed.
  (define (shell-connections sh) (vector->list (hashtable-keys (shell-table sh))))

  ;; connection? : Any -> Boolean
  ;; connection-tcp : Connection -> UvTcp
  ;; connection-violations : Connection -> (Listof Action)
  ;;   actions run anywhere but the outermost drain, newest first
  (define-record-type (connection make-connection connection?)
    (fields shell tcp
            (mutable ctx) (mutable parser)
            (mutable front) (mutable back)    ; the queue: front in order, back reversed
            (mutable depth)                   ; the drain, and a feed inside it
            (mutable violations)
            (mutable reading?)
            (mutable closing?)
            (mutable on-data) (mutable on-eof) (mutable on-error)))

  ;; connection-state : Connection -> ConnState — the core's state.
  (define (connection-state c) (conn-context-state (connection-ctx c)))

  ;; shell-adopt! : Shell UvTcp -> Connection
  ;; Serve an accepted TCP handle: the core in idle, a parser of its own, the
  ;; connection in the table, Nagle's algorithm off, and reading started with
  ;; the limits' buffer.  Nagle's algorithm would hold a response's last
  ;; partial segment until the client acknowledged the ones before it, and
  ;; the shell writes each response whole, in one write; a socket that
  ;; refuses the option has already failed, which reading will report.
  (define (shell-adopt! sh tcp)
    (let ((c (make-connection sh tcp #f #f '() '() 0 '() #f #f #f #f #f)))
      (connection-ctx-set! c (make-conn-context
                              (make-conn-state 'idle 'idle #f 0 0 #f #f (shell-limits sh))
                              (lambda (actions) (enqueue! c actions))))
      (connection-parser-set! c (make-conn-parser (connection-ctx c)))
      (connection-on-data-set! c (lambda (bv start end) (dispatch! c (list 'bytes-arrived bv start end))))
      (connection-on-eof-set! c (lambda () (dispatch! c '(eof))))
      (connection-on-error-set! c (lambda (e) (dispatch! c (list 'read-error (errno e)))))
      (hashtable-set! (shell-table sh) c #t)
      (guard (e ((transport-condition? e) (values)))
        (uv-tcp-nodelay! tcp #t))
      (uv-read-start! tcp (connection-on-data c) (connection-on-eof c) (connection-on-error c)
                      (limits-read-buffer-size (shell-limits sh)))
      (connection-reading?-set! c #t)
      c))

  ;; --- the message loop ---------------------------------------------------------

  ;; dispatch! : Connection Event -> Void
  ;; Step the core with one event and queue its actions, then drain the queue
  ;; unless a drain or a feed is under way.
  (define (dispatch! c event)
    (if (fx=? (connection-depth c) 0)
        (begin (step! c event) (drain! c))
        (step! c event)))

  ;; step! : Connection Event -> Void — the core's step, its actions queued.
  (define (step! c event)
    (trace! c 'event event)
    (enqueue! c (conn-context-step! (connection-ctx c) event)))

  ;; enqueue! : Connection (Listof Action) -> Void — behind what is queued.
  (define (enqueue! c actions)
    (connection-back-set! c (fold-left (lambda (acc a) (cons a acc)) (connection-back c) actions)))

  ;; dequeue! : Connection -> (U #f Action) — the oldest queued action.
  (define (dequeue! c)
    (when (null? (connection-front c))
      (connection-front-set! c (reverse (connection-back c)))
      (connection-back-set! c '()))
    (let ((front (connection-front c)))
      (and (pair? front)
           (begin (connection-front-set! c (cdr front)) (car front)))))

  ;; drain! : Connection -> Void — run the queue, in order, until it is empty.
  ;; A raise abandons the dispatch it came from: the depth is restored and
  ;; what is still queued is dropped.
  (define (drain! c)
    (let ((before (connection-depth c)))
      (dynamic-wind
       (lambda () (connection-depth-set! c (fx+ before 1)))
       (lambda ()
         (let loop ()
           (let ((a (dequeue! c)))
             (when a (run! c a) (loop)))))
       (lambda ()
         (connection-depth-set! c before)
         (connection-front-set! c '())
         (connection-back-set! c '())))))

  ;; run! : Connection Action -> Void
  ;; Record a violation if the action runs anywhere but the outermost drain,
  ;; then perform it.
  (define (run! c a)
    (unless (fx=? (connection-depth c) 1)
      (connection-violations-set! c (cons a (connection-violations c))))
    (trace! c 'action a)
    (case (car a)
      ((feed-parser) (feed! c (cadr a) (caddr a) (cadddr a)))
      ((resume-parser) (parser-resume! (connection-parser c)))
      ((call-handler) (call-handler! c (cadr a)))
      ((write) (write! c (cadr a) (caddr a)))
      ((read-stop) (read-stop! c))
      ((read-start) (read-start! c))
      ((shutdown) (shutdown! c))
      ((close) (connection-close! c))
      ((log) (log! (connection-shell c) (cadr a) (cddr a)))
      (else (values))))

  (define (trace! c kind datum)
    (let ((trace (shell-trace (connection-shell c))))
      (when trace (trace c kind datum))))

  (define (log! sh what details) ((shell-log sh) what details))

  ;; --- the executors ------------------------------------------------------------

  ;; feed! : Connection Bytevector Nat Nat -> Void
  ;; Feed the parser bv[start, end), counting the feed in the depth, then
  ;; dispatch its result: the status, the bytes consumed, where to resume,
  ;; and the codes of its error and its pause.
  (define (feed! c bv start end)
    (connection-depth-set! c (fx+ (connection-depth c) 1))
    (let ((r (parser-feed! (connection-parser c) bv start end)))
      (connection-depth-set! c (fx- (connection-depth c) 1))
      (dispatch! c (list 'parser-result (parser-result-status r)
                         (parser-result-consumed r) (parser-result-next r)
                         (code (parser-result-error r))
                         (code (parser-result-pause r))))))

  ;; code : (U #f ParserError) -> (U #f Symbol)
  (define (code e) (and e (parser-error-code e)))

  ;; call-handler! : Connection Request -> Void
  (define (call-handler! c request)
    (let ((answer (guard (e (#t (log! (connection-shell c) 'handler-failed (list e))
                                (list 'handler-failed e)))
                    (list 'handler-responded ((shell-handler (connection-shell c)) request)))))
      (dispatch! c answer)))

  ;; write! : Connection (Listof Segment) Nat -> Void
  ;; One uv-write*! of the segments, the Date slot filled.
  (define (write! c segments nbytes)
    (let ((line (current-date-line (connection-shell c))))
      (uv-write*! (connection-tcp c)
                  (map (lambda (seg) (if (eq? seg 'date) line seg)) segments)
                  (write-done c nbytes))))

  ;; write-done : Connection Nat -> ((U #f Condition) -> Void)
  ;; A write's completion, which keeps the write's byte count and nothing of
  ;; its segments.
  (define (write-done c nbytes)
    (lambda (err)
      (dispatch! c (list 'write-completed nbytes))))

  ;; read-stop! / read-start! : Connection -> Void
  ;; Reading changes only when it is not already what the action asks.  A
  ;; stop races a close only if the handle is no longer open, and a closed
  ;; handle reads nothing.
  (define (read-stop! c)
    (when (connection-reading? c)
      (connection-reading?-set! c #f)
      (when (uv-handle-open? (connection-tcp c))
        (uv-read-stop! (connection-tcp c)))))

  (define (read-start! c)
    (unless (or (connection-reading? c) (connection-closing? c))
      (connection-reading?-set! c #t)
      (uv-read-start! (connection-tcp c)
                      (connection-on-data c) (connection-on-eof c) (connection-on-error c))))

  ;; shutdown! : Connection -> Void — the half-close.
  (define (shutdown! c)
    (uv-shutdown! (connection-tcp c)
                  (lambda (err) (dispatch! c '(shutdown-completed)))))

  ;; connection-close! : Connection -> Void
  ;; Close the connection's handle, once.  This is the one uv-close! call
  ;; (design §7.6; `make check-close-ownership`): chez-libuv keeps the
  ;; callback of the first close alone, so a second close from anywhere else
  ;; would leave this one's never run, and the connection in the table.
  (define (connection-close! c)
    (unless (connection-closing? c)
      (connection-closing?-set! c #t)
      (connection-reading?-set! c #f)
      (uv-close! (connection-tcp c)
                 (lambda ()
                   (hashtable-delete! (shell-table (connection-shell c)) c)
                   (dispatch! c '(closed))))))

  ;; transport-condition? : Any -> Boolean
  ;; What a verb raises when the connection, not the program, has failed.
  (define (transport-condition? e) (or (uv-errno-error? e) (uv-handle-closed? e)))

  ;; errno : Condition -> Symbol — the failure's portable name.
  (define (errno e)
    (cond ((uv-errno-error? e) (uv-errno-error-errno e))
          ((uv-handle-closed? e) 'handle-closed)
          (else 'unknown)))

  ;; current-date-line : Shell -> Bytevector
  ;; The Date line for the current second.  The clock is read when a second of
  ;; the loop's time has passed since its last reading, and the line made
  ;; again only when the second it names has changed.
  (define (current-date-line sh)
    (let ((now (uv-now (shell-loop sh))))
      (unless (and (shell-read-at sh) (< (- now (shell-read-at sh)) 1000))
        (shell-read-ms-set! sh ((shell-clock sh)))
        (shell-read-at-set! sh now))
      (let ((second (div (+ (shell-read-ms sh) (- now (shell-read-at sh))) 1000)))
        (unless (eqv? second (shell-date-second sh))
          (shell-date-line-set! sh (date-line second))
          (shell-date-second-set! sh second))
        (shell-date-line sh)))))
