#!r6rs
;;; (http-server connection): the door, through the fake shell's message
;;; loop.  M8.2.
;;;
;;; Decision 0016.  A handler takes an HTTP/1.1 upgrade with no body by
;;; answering a switch.  The core writes the 101, and once it is written
;;; hands the stream over: the fake shell calls the switch's take-over with
;;; a transport over the fake connection and the bytes read past the
;;; request.  The hook's contract (decision 0006 item 3): those bytes are
;;; exactly `parser-result-next` onward, so what the taker is handed,
;;; followed by what it reads on, is exactly what the client sent after the
;;; request, at every delivery size.  Through the fake transport, the
;;; taker's writes follow the 101, its close ends the connection once they
;;; are written, its deadline passes on the fake clock, and its drain call
;;; runs when the shell drains.  A request the door does not open for, and
;;; a switch with a fault, are answered 500, then the staged close.
;;;
;;; Decision 0024: for a client that reads nothing, the fake completes no
;;; write the taker asks for, as the libuv shell's never complete.  A close
;;; then waits for them, a deadline asked for meanwhile is armed, and an
;;; abort closes the stream at once, each write outstanding told ECANCELED.
;;; A raise in any of the taker's calls is its failure and closes the stream
;;; at once, as the libuv shell's taker-call! has it.
;;;
;;; Decision 0026: a taker's close is staged.  Once its writes are written
;;; the write side is shut and the stream lingers, the linger deadline armed
;;; in the taker's deadline's place, reading and dropping what comes, until
;;; the client's end, a read error or that deadline closes it.  A client
;;; whose end came during the close's writes is closed once they are
;;; written.  Once lingering, the stream is the server's: a deadline, its
;;; cancel and a read-stop change nothing; an abort closes it at once.
;;;
;;; Plan §14's review note (2026-10-12): what the client sends while the
;;; taker reads nothing, before its read-start or after its read-stop, is
;;; kept, as the kernel keeps it, and read once reading starts again.
;;;
;;; Oracles: decision 0016; RFC 9110 §7.8 and §15.2.2; RFC 6455 §5.7's
;;; masked "Hello" frame, two of its bytes after the header; the inputs'
;;; own bytes; design §6.5's 500; decision 0011's staged close.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (http-server switch) (http-server transport)
        (only (http-server awaiting) awaiting client-closed?)
        (only (http-server private waits) await)
        (fake-shell) (decisive))

(define (b s) (string->utf8 s))

(define (concat bvs)
  (let ((out (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 bvs))))
    (fold-left (lambda (at bv) (bytevector-copy! bv 0 out at (bytevector-length bv)) (+ at (bytevector-length bv)))
               0 bvs)
    out))

(define (slice bv from to)
  (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o))

;; A WebSocket handshake, RFC 6455 §1.2's, then two masked frames sent before
;; the 101 came, as hyper's `upgrades` test sends "eagerly optimistic"; RFC
;; 6455 §5.7's single-frame masked "Hello", then "Hi" with the same mask.
(define handshake
  (b (string-append "GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUpgrade: websocket\r\n"
                    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n\r\n")))
(define hello-frame (u8-list->bytevector '(#x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58)))
(define hi-frame (u8-list->bytevector '(#x81 #x82 #x37 #xfa #x21 #x3d #x7f #x93)))
(define frames (concat (list hello-frame hi-frame)))
(define eager (concat (list handshake frames)))

(define accept (cons (b "Sec-WebSocket-Accept") (b "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")))
(define the-101
  (b "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nConnection: upgrade\r\n\r\n"))

;; A taker that keeps what it is handed and reads, and the transport.
(define-record-type taker
  (fields (mutable transport) (mutable retained) (mutable read) (mutable ends) (mutable closes)
          (mutable drains) (mutable passes) (mutable written))
  (protocol (lambda (new) (lambda () (new #f #f '() '() 0 0 0 '())))))

;; counting-closes : Taker Transport -> Void — the stream's close counted.
(define (counting-closes t tr)
  (transport-on-close! tr (lambda () (taker-closes-set! t (+ 1 (taker-closes t))))))

;; taking : Taker [(Transport Bytevector -> Any)] -> (Request -> Switch)
;; A handler that switches to websocket, its take-over keeping the transport
;; and the retained bytes in `t`, reading on, each piece onto `read`, then
;; doing `then`, if given, with the transport.
(define (taking t . then)
  (lambda (request)
    (switch-protocols
     (list (cons (b "Upgrade") (b "websocket")) accept)
     (lambda (transport retained)
       (taker-transport-set! t transport)
       (taker-retained-set! t retained)
       (counting-closes t transport)
       (transport-read-start! transport
                              (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t))))
                              (lambda (why) (taker-ends-set! t (cons why (taker-ends t)))))
       (unless (null? then) ((car then) transport))))))

;; waiting-taking : (Transport -> Any) (Transport -> Any) -> (Request -> Switch)
;; A handler that switches to websocket, its take-over doing `now` with the
;; transport in place, then answering `(awaiting thunk)`, the thunk doing
;; `later` with it on a coroutine (decision 0023).
(define (waiting-taking now later)
  (lambda (request)
    (switch-protocols
     (list (cons (b "Upgrade") (b "websocket")) accept)
     (lambda (transport retained)
       (now transport)
       (awaiting (lambda () (later transport)))))))

;; keeping : Taker -> (Request -> Switch)
;; A handler that switches to websocket, its take-over keeping the transport
;; and the retained bytes in `t` and counting its closes, and reading nothing.
(define (keeping t)
  (lambda (request)
    (switch-protocols
     (list (cons (b "Upgrade") (b "websocket")) accept)
     (lambda (transport retained)
       (taker-transport-set! t transport)
       (taker-retained-set! t retained)
       (counting-closes t transport)))))

;; reads-into : Taker -> (Bytevector Nat Nat -> Void) — a taker's on-bytes
;; keeping each read on `t`'s `read`, newest first.
(define (reads-into t) (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t)))))

;; ends-into : Taker -> (Symbol -> Void) — a taker's on-end keeping each end
;; on `t`'s `ends`, newest first.
(define (ends-into t) (lambda (why) (taker-ends-set! t (cons why (taker-ends t)))))

;; arriving : Bytevector -> Event — `bv` whole, as one delivery.
(define (arriving bv) (list 'bytes-arrived bv 0 (bytevector-length bv)))

;; unread : Bytevector (Request -> Any) [Trace] -> FakeShell
;; One connection handed `input` whole, then let write the 101 and nothing
;; after: a write the taker asks for completes only on a later turn, so
;; none does, as for a client that reads nothing (decision 0024).  Traced
;; with `trace`, if given, as make-fake-connection traces.
(define (unread input handler . trace)
  (let ((sh (make-fake-connection default-limits handler (and (pair? trace) (car trace)))))
    (fake-shell-deliver! sh (list 'bytes-arrived input 0 (bytevector-length input)))
    (fake-shell-deliver-later! sh)
    (unless (eq? (conn-phase (fake-shell-conn-state sh)) 'handed-off)
      (assertion-violation 'unread "the 101's turn did not hand the stream off"
                           (conn-phase (fake-shell-conn-state sh))))
    sh))

;; noting : Taker -> ((U #f Symbol) -> Void) — a write's callback that keeps
;; what it is told on the taker's `written`, newest first.
(define (noting t) (lambda (err) (taker-written-set! t (cons err (taker-written t)))))

;; raised-in : Symbol -> Datum
;; A taker that writes to a client that reads nothing, then raises in one of
;; its calls, named by `where`: the take-over itself, its read, its end, its
;; deadline's call, its drain call, its write's callback, the client then
;; reading, or its close call, once it has aborted.  What was recorded, what the write was told, how often the close
;; call ran, and the core's phase.
(define (raised-in where)
  (let* ((t (make-taker))
         (fail (lambda () (raise (make-message-condition (symbol->string where)))))
         (sh (unread handshake
               (taking t (lambda (tr)
                           (when (eq? where 'close)
                             (transport-on-close! tr (lambda () (taker-closes-set! t (+ 1 (taker-closes t))) (fail))))
                           (transport-write! tr (b "unread") 0 6
                                             (lambda (err) ((noting t) err) (when (eq? where 'written) (fail))))
                           (transport-read-start! tr (lambda (bv from to) (when (eq? where 'read) (fail)))
                                                  (lambda (why) (when (eq? where 'end) (fail))))
                           (transport-deadline! tr 1000 (lambda () (when (eq? where 'deadline) (fail))))
                           (transport-on-drain! tr (lambda () (when (eq? where 'drain) (fail))))
                           (when (eq? where 'take-over) (fail))
                           (when (eq? where 'close) (transport-abort! tr)))))))
    (case where
      ((read) (fake-shell-deliver! sh (list 'bytes-arrived hi-frame 0 (bytevector-length hi-frame))))
      ((end) (fake-shell-deliver! sh '(eof)))
      ((deadline) (fake-shell-advance! sh 1000) (fake-shell-fire! sh))
      ((drain) (fake-shell-drain! sh)))
    (fake-shell-settle! sh)
    (list (map condition-message (fake-shell-taker-failures sh)) (taker-written t) (taker-closes t)
          (conn-phase (fake-shell-conn-state sh)))))

;; late-raises : -> (Listof String)
;; What was recorded of a taker that asks for its close, then for a write
;; whose callback raises when told ECANCELED, and, once the stream has
;; closed, registers a close call that raises, run at once.
(define (late-raises)
  (let* ((t (make-taker))
         (sh (run handshake (bytevector-length handshake)
                  (taking t (lambda (tr)
                              (transport-close! tr)
                              (transport-write! tr (b "late") 0 4
                                                (lambda (err) (raise (make-message-condition "late-written")))))))))
    (transport-on-close! (taker-transport t) (lambda () (raise (make-message-condition "late-close"))))
    (map condition-message (fake-shell-taker-failures sh))))

;; run : Bytevector Nat (Request -> Any) -> FakeShell
;; One connection reading `input` in `size`-byte deliveries, every later turn
;; let happen.
(define (run input size handler)
  (let ((sh (make-fake-connection default-limits handler)))
    (fake-shell-feed-input! sh input size)
    (fake-shell-settle! sh)
    sh))

;; iota-from : Nat Nat -> (Listof Nat) — from `from` to `to`, both included.
(define (iota-from from to) (if (> from to) '() (cons from (iota-from (+ from 1) to))))

;; rendered-actions : FakeShell -> (Listof Datum)
;; Its actions, a handler's call by its method and target and a write by its
;; status.
(define (rendered-actions sh)
  (map (lambda (a)
         (case (car a)
           ((call-handler) (list 'call-handler (render-request (cadr a))))
           ((write) (list 'write (written-status a)))
           (else a)))
       (fake-shell-actions sh)))

;; client-bytes : FakeShell -> Bytevector — what the client has read.
(define (client-bytes sh) (concat (fake-shell-writes sh)))

;; door : Nat -> Datum
;; At one delivery size, through the door: whether the bytes handed over,
;; then what the taker read, are the frames, and whether the 101 is all the
;; client read; and whether any bytes were handed over.
(define (door size)
  (let* ((t (make-taker)) (sh (run eager size (taking t))))
    (list (and (taker-retained t)
               (equal? (concat (cons (taker-retained t) (reverse (taker-read t)))) frames))
          (equal? (client-bytes sh) the-101)
          (conn-phase (fake-shell-conn-state sh)))))

(define (retained-at size)
  (let ((t (make-taker))) (run eager size (taking t)) (taker-retained t)))

;; refused : Bytevector (Request -> Any) -> Datum
;; What a request read whole gets: the writes by status, the logs, and the
;; phase and close-after it ends in.
(define (refused input handler)
  (let* ((sh (run input (bytevector-length input) handler)) (s (fake-shell-conn-state sh)))
    (list (map written-status (filter (lambda (a) (eq? (car a) 'write)) (fake-shell-actions sh)))
          (filter (lambda (a) (eq? (car a) 'log)) (fake-shell-actions sh))
          (conn-phase s) (conn-close-after s))))

(define (switch-to . protocol)
  (lambda (request)
    (switch-protocols (list (cons (b "Upgrade") (b (if (null? protocol) "websocket" (car protocol)))))
                      (lambda (transport retained) 'taken))))

(define ws-request "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n")

(run-suite "connection-switch"
  (lambda ()
    ;; --- the hook's contract (decision 0006 item 3) -----------------------
    ;; At every delivery size the bytes handed over, then what the taker
    ;; reads on, are the two frames, and the 101 is all the client reads.
    (test-equal "at every delivery size: the bytes handed over, then those read on, are exactly the bytes after the request; the client reads the 101"
                '((#t #t handed-off))
                (let loop ((size 1) (seen '()))
                  (if (> size (bytevector-length eager))
                      (reverse seen)
                      (let ((o (door size)))
                        (loop (+ size 1) (if (member o seen) seen (cons o seen)))))))
    ;; A read that ends inside the frames hands some over, and one that ends
    ;; with the request, none: so a contract that held only for one held
    ;; for nothing.
    (test-equal "some delivery sizes hand bytes over, and some hand none"
                '(#t #t)
                (let ((sizes (iota-from 1 (bytevector-length eager))))
                  (list (exists (lambda (n) (> (bytevector-length (retained-at n)) 0)) sizes)
                        (exists (lambda (n) (= (bytevector-length (retained-at n)) 0)) sizes))))
    (test-equal "read whole, every byte after the request is handed over" frames
                (retained-at (bytevector-length eager)))
    ;; RFC 9110 §7.8: a handshake that also expects 100-continue is sent the
    ;; 100 before the 101.
    (test-equal "a handshake expecting 100-continue reads the 100, then the 101"
                (concat (list (b "HTTP/1.1 100 Continue\r\n\r\n") the-101))
                (let* ((input (concat (list (b (string-append "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
                                                              "Connection: Upgrade\r\nExpect: 100-continue\r\n\r\n")))))
                       (sh (run input (bytevector-length input) (taking (make-taker)))))
                  (client-bytes sh)))
    (test-equal "the core's part, from the handler's call: the 101 written, then the hand-off, disarmed and reading stopped first, and nothing after"
                '((call-handler (GET "/chat")) (write 101) (arm-deadline write) (disarm-deadline) (read-stop) hand-off)
                (let ((sh (run eager (bytevector-length eager) (taking (make-taker)))))
                  (map (lambda (a) (if (eq? (car a) 'hand-off) 'hand-off a))
                       (let from ((as (rendered-actions sh)))
                         (cond ((null? as) '())
                               ((eq? (caar as) 'call-handler) as)
                               (else (from (cdr as))))))))

    ;; Decision 0016's amendment (2026-10-11): nothing is read between the
    ;; hand-off and the taker's read-start, so what the client sends after
    ;; the 101 waits for the taker, as Go's hijack and Node's upgrade keep
    ;; it.  A taker that starts reading only once its deadline passes: the
    ;; frames sent after the handshake are read by no one until then, and
    ;; are then all the taker's.
    (test-equal "a taker that starts reading once its deadline passes reads what the client sent after the 101, none of it read before"
                (list 0 frames 0 'handed-off)
                (let* ((t (make-taker))
                       (sh (unread handshake
                                   (lambda (request)
                                     (switch-protocols
                                      (list (cons (b "Upgrade") (b "websocket")) accept)
                                      (lambda (tr retained)
                                        (transport-deadline!
                                         tr 1000
                                         (lambda ()
                                           (transport-read-start!
                                            tr
                                            (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t))))
                                            (lambda (why) (taker-ends-set! t (cons why (taker-ends t))))))))))))
                       (before (fake-shell-feed-input! sh frames 64)))
                  (fake-shell-advance! sh 1000)
                  (fake-shell-fire! sh)
                  (fake-shell-feed-input! sh frames 64)
                  (list before (concat (reverse (taker-read t))) (length (fake-shell-taker-failures sh))
                        (conn-phase (fake-shell-conn-state sh)))))

    ;; Plan §14's review note (2026-10-12): what the client sends while a
    ;; taker reads nothing is the kernel's to keep, as the libuv shell's
    ;; kernel keeps it, never handed to a taker that has not asked for it.
    ;; Read once the taker starts reading, on the turn after, as libuv reads
    ;; it then, ahead of what came after it, each read traced as it is read.
    (let* ((t (make-taker))
           (door '())
           (sh (unread handshake (keeping t)
                       (lambda (kind datum) (when (eq? kind 'door) (set! door (cons (car datum) door)))))))
      (fake-shell-deliver! sh (arriving hello-frame))
      (let ((kept (list (taker-read t) (reverse door))))
        (transport-read-start! (taker-transport t) (reads-into t) (ends-into t))
        (fake-shell-deliver! sh (arriving hi-frame))
        (fake-shell-deliver! sh '(eof))
        (let ((in-call (list (taker-read t) (taker-ends t) (reverse door))))
          (fake-shell-settle! sh)
          (test-equal "what the client sends before a taker's read-start is kept, as the kernel keeps it: read on the turn after the read-start, ahead of what came after, each read traced as it is read, nothing failed"
                      (list '(() ()) '(() () ()) (list hello-frame hi-frame) '(eof)
                            '(stream-read stream-read stream-end) 0 'handed-off)
                      (list kept in-call (reverse (taker-read t)) (taker-ends t) (reverse door)
                            (length (fake-shell-taker-failures sh)) (conn-phase (fake-shell-conn-state sh)))))))
    ;; A taker that stops reading is read nothing more until it starts
    ;; again: what comes meanwhile is kept, and read on the turn after its
    ;; next read-start, up to its next read-stop.  This one stops at each
    ;; read and starts again between turns.
    (let* ((t (make-taker))
           (sh (unread handshake (keeping t)))
           (one-at-a-time (lambda (bv from to) ((reads-into t) bv from to) (transport-read-stop! (taker-transport t))))
           (start! (lambda () (transport-read-start! (taker-transport t) one-at-a-time (ends-into t)))))
      (start!)
      (fake-shell-deliver! sh (arriving hello-frame))
      (fake-shell-deliver! sh (arriving hi-frame))
      (fake-shell-deliver! sh '(eof))
      (let ((stopped (list (length (taker-read t)) (taker-ends t))))
        (start!)
        (fake-shell-settle! sh)
        (let ((again (list (length (taker-read t)) (taker-ends t))))
          (start!)
          (fake-shell-settle! sh)
          (test-equal "a taker that stops at each read and starts again between turns: what came while it was stopped is kept, and read a read a turn after each read-start, its end last"
                      (list '(1 ()) '(2 ()) (list hello-frame hi-frame) '(eof) 0)
                      (list stopped again (reverse (taker-read t)) (taker-ends t)
                            (length (fake-shell-taker-failures sh)))))))
    ;; A close reads on for the client's end, as the libuv shell's does
    ;; (decision 0026), so what was kept while the taker read nothing is
    ;; read then, and dropped: the client's end among it closes the stream,
    ;; which lingered from the close, the taker told nothing.
    (let* ((t (make-taker))
           (sh (unread handshake (keeping t))))
      (fake-shell-deliver! sh (arriving hello-frame))
      (fake-shell-deliver! sh '(eof))
      (transport-close! (taker-transport t))
      (let ((closing (list (fake-shell-shut? sh) (conn-phase (fake-shell-conn-state sh)))))
        (fake-shell-settle! sh)
        (test-equal "what was kept while a taker read nothing is read and dropped once it closes: the client's end among it closes the lingering stream, the taker told nothing, nothing failed"
                    (list '(#t handed-off) '() '() 1 'closed 0)
                    (list closing (taker-read t) (taker-ends t) (taker-closes t)
                          (conn-phase (fake-shell-conn-state sh)) (length (fake-shell-taker-failures sh))))))

    ;; --- the transport (decision 0016 item 2) ------------------------------
    ;; The taker's writes follow the 101, in order, each callback told once
    ;; its bytes are written.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-write! tr (b "one") 0 3
                                                  (lambda (err) (taker-written-set! t (cons (list 'one err) (taker-written t)))))
                                (transport-write! tr (b "xtwox") 1 4
                                                  (lambda (err) (taker-written-set! t (cons (list 'two err) (taker-written t))))))))))
      (test-equal "the taker's writes follow the 101, in order" (concat (list the-101 (b "one") (b "two")))
                  (client-bytes sh))
      (test-equal "each write's callback is told it is written, in order" '((one #f) (two #f))
                  (reverse (taker-written t))))
    ;; The taker's close: once its writes are written, the connection
    ;; lingers until the client ends (decision 0026), then closes, its close
    ;; call runs once, and the core ends closed.  A write asked for after the
    ;; close is not written: its callback is told ECANCELED.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-write! tr (b "bye"))
                                (transport-close! tr)
                                (transport-write! tr (b "late") 0 4
                                                  (lambda (err) (taker-written-set! t (cons err (taker-written t))))))))))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "closed by the taker: its write first, its close call once, a later write cancelled, the core closed"
                  (list (concat (list the-101 (b "bye"))) 1 '(ECANCELED) 'closed)
                  (list (client-bytes sh) (taker-closes t) (taker-written t)
                        (conn-phase (fake-shell-conn-state sh)))))
    ;; That ECANCELED is told on the next turn, as the libuv shell tells it
    ;; from its scheduler's drain (taker-later!): after a deadline's call
    ;; that closes, then writes, once the timer's turn ends; and after a
    ;; close and a write asked for between turns, at the next turn, not in
    ;; the write's call.
    (let* ((t (make-taker))
           (sh (unread handshake
                       (taking t (lambda (tr)
                                   (transport-deadline! tr 1000
                                                        (lambda ()
                                                          (transport-close! tr)
                                                          (transport-write! tr (b "late") 0 4 (noting t)))))))))
      (fake-shell-advance! sh 1000)
      (fake-shell-fire! sh)
      (test-equal "a write a deadline's call asks for after its close is told ECANCELED once the timer's turn ends"
                  '(ECANCELED)
                  (taker-written t)))
    (let* ((t (make-taker))
           (sh (unread handshake (taking t))))
      (transport-close! (taker-transport t))
      (transport-write! (taker-transport t) (b "late") 0 4 (noting t))
      (let ((in-call (taker-written t)))
        (fake-shell-settle! sh)
        (test-equal "a write asked for between turns after the close is told ECANCELED at the next turn, not in its call"
                    '(() (ECANCELED))
                    (list in-call (taker-written t)))))
    ;; A client's end read while the 101 is written is handed over with the
    ;; stream (decision 0016's amendment of 2026-10-12): the taker, reading
    ;; in its take-over, is told 'eof on the next turn, as the libuv shell
    ;; tells it, and its close closes the stream at once, the end having
    ;; come, with no linger.
    ;; Not in the read-start's call: on the next turn.  A taker that closes
    ;; in its take-over, after its read-start, is told nothing.
    (let* ((t (make-taker))
           (in-take-over #f)
           (sh (make-fake-connection default-limits (taking t (lambda (tr) (set! in-take-over (taker-ends t)))))))
      (fake-shell-deliver! sh (list 'bytes-arrived handshake 0 (bytevector-length handshake)))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (let ((ends (taker-ends t)))
        (transport-close! (taker-transport t))
        (fake-shell-settle! sh)
        (test-equal "a client's end read while the 101 is written: the taker, reading, is told eof on the next turn, and its close closes the stream at once"
                    (list '() '(eof) 'closed 1 #f)
                    (list in-take-over ends (conn-phase (fake-shell-conn-state sh)) (taker-closes t) (fake-shell-armed sh)))))
    (let* ((t (make-taker))
           (sh (make-fake-connection default-limits (taking t (lambda (tr) (transport-close! tr))))))
      (fake-shell-deliver! sh (list 'bytes-arrived handshake 0 (bytevector-length handshake)))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "a client's end read while the 101 is written, the taker closing in its take-over: it is told nothing, and the stream closes"
                  (list '() 'closed 1)
                  (list (taker-ends t) (conn-phase (fake-shell-conn-state sh)) (taker-closes t))))
    ;; Once told its end, a taker that starts reading again reads nothing
    ;; more, and is told nothing more: the stream reads no more, as the
    ;; libuv shell's does not start reading again.
    (let* ((t (make-taker))
           (sh (run handshake (bytevector-length handshake) (taking t))))
      (fake-shell-deliver! sh '(eof))
      (transport-read-start! (taker-transport t)
                             (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t))))
                             (lambda (why) (taker-ends-set! t (cons why (taker-ends t)))))
      (fake-shell-settle! sh)
      (test-equal "a taker told its end that starts reading again: the stream reads no more, and its end is told once"
                  '((eof) #f)
                  (list (taker-ends t) (fake-shell-reading? sh))))
    ;; A close call registered once the stream has closed runs at once, so a
    ;; taker that asks late still hears of the close (M8.2's review, the
    ;; eighth).
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager) (taking t (lambda (tr) (transport-close! tr))))))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (let ((before (taker-closes t)))
        (transport-on-close! (taker-transport t) (lambda () (taker-closes-set! t (+ 10 (taker-closes t)))))
        (test-equal "a close call registered after the stream has closed runs at once"
                    '(closed 1 11)
                    (list (conn-phase (fake-shell-conn-state sh)) before (taker-closes t)))))
    ;; On a stream that has closed, a deadline arms nothing and never passes,
    ;; as the libuv shell's arms none (M8.2's review, the seventh).
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager) (taking t (lambda (tr) (transport-close! tr))))))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (transport-deadline! (taker-transport t) 1000 (lambda () (taker-passes-set! t (+ 1 (taker-passes t)))))
      (let ((armed (fake-shell-armed sh)))
        (fake-shell-advance! sh 2000)
        (fake-shell-fire! sh)
        (test-equal "on a stream that has closed, a deadline arms nothing and never passes"
                    '(closed #f 0)
                    (list (conn-phase (fake-shell-conn-state sh)) armed (taker-passes t)))))
    ;; --- the close lingers (decision 0026) ----------------------------------
    ;; Once the close's writes are written, the write side is shut and the
    ;; stream lingers, the linger deadline armed in place of the taker's: a
    ;; read then is dropped, the taker reading nothing, and the client's end
    ;; closes the stream, its close call once.  The core is told nothing until
    ;; then.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-deadline! tr 1000 (lambda () (taker-passes-set! t (+ 1 (taker-passes t)))))
                                (transport-write! tr (b "bye"))
                                (transport-close! tr))))))
      (let ((lingering (list (fake-shell-shut? sh) (fake-shell-armed sh) (taker-closes t)
                             (conn-phase (fake-shell-conn-state sh)))))
        (fake-shell-deliver! sh (list 'bytes-arrived hi-frame 0 (bytevector-length hi-frame)))
        (let ((read (taker-read t)))
          (fake-shell-deliver! sh '(eof))
          (fake-shell-settle! sh)
          (test-equal "a taker's close: once its writes are out, the write side shut and the linger deadline armed in place of the taker's; a read then dropped, not the taker's; the client's end closes the stream, its close call once"
                      (list (list #t (limits-linger-timeout-ms default-limits) 0 'handed-off)
                            '() (concat (list the-101 (b "bye"))) 1 'closed '())
                      (list lingering read (client-bytes sh) (taker-closes t)
                            (conn-phase (fake-shell-conn-state sh)) (taker-ends t))))))
    ;; The linger deadline passing closes the stream, the taker's deadline it
    ;; replaced never passing; so does a read error while it lingers.
    (let* ((t1 (make-taker))
           (sh1 (run eager (bytevector-length eager)
                     (taking t1 (lambda (tr)
                                  (transport-deadline! tr 1000 (lambda () (taker-passes-set! t1 (+ 1 (taker-passes t1)))))
                                  (transport-close! tr)))))
           (t2 (make-taker))
           (sh2 (run eager (bytevector-length eager) (taking t2 (lambda (tr) (transport-close! tr))))))
      (fake-shell-advance! sh1 (- (limits-linger-timeout-ms default-limits) 1))
      (fake-shell-fire! sh1)
      (fake-shell-settle! sh1)
      (let ((before (list (taker-closes t1) (taker-passes t1))))
        (fake-shell-advance! sh1 1)
        (fake-shell-fire! sh1)
        (fake-shell-settle! sh1)
        (fake-shell-deliver! sh2 '(read-error ECONNRESET))
        (fake-shell-settle! sh2)
        (test-equal "the linger deadline passing closes the stream, the taker's deadline it replaced never passing; a read error while it lingers closes it too, the taker told nothing"
                    '((0 0) 1 0 closed 1 closed ())
                    (list before (taker-closes t1) (taker-passes t1) (conn-phase (fake-shell-conn-state sh1))
                          (taker-closes t2) (conn-phase (fake-shell-conn-state sh2)) (taker-ends t2)))))
    ;; A client that ends while the close's writes are outstanding has nothing
    ;; more to send: the stream closes once they are written, with no linger.
    (let* ((t (make-taker))
           (sh (unread handshake (taking t (lambda (tr) (transport-write! tr (b "bye")) (transport-close! tr))))))
      (fake-shell-deliver! sh '(eof))
      (let ((waiting (list (taker-closes t) (conn-phase (fake-shell-conn-state sh)))))
        (fake-shell-settle! sh)
        (test-equal "a client that ends while the close's writes are outstanding: the stream closes once they are written, with no linger"
                    (list '(0 handed-off) (concat (list the-101 (b "bye"))) 1 'closed #f '())
                    (list waiting (client-bytes sh) (taker-closes t) (conn-phase (fake-shell-conn-state sh))
                          (fake-shell-shut? sh) (taker-ends t)))))
    ;; A lingering stream is the server's: a deadline asked for then is not
    ;; armed, nor its cancel, a read-stop leaves it reading, and an abort
    ;; closes it at once.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager) (taking t (lambda (tr) (transport-close! tr)))))
           (tr (taker-transport t))
           (armed (fake-shell-armed sh)))
      (transport-deadline! tr 5 (lambda () (taker-passes-set! t (+ 1 (taker-passes t)))))
      (let ((after-arm (fake-shell-armed sh)))
        (transport-deadline! tr #f)
        (let ((after-cancel (fake-shell-armed sh)))
          (transport-read-stop! tr)
          (let ((reading (fake-shell-reading? sh)))
            (fake-shell-advance! sh 5)
            (fake-shell-fire! sh)
            (let ((open (list (taker-passes t) (taker-closes t))))
              (transport-abort! tr)
              (fake-shell-settle! sh)
              (test-equal "once a stream lingers, a deadline asked for is not armed, nor its cancel, and a read-stop leaves it reading; an abort closes it at once, its close call once"
                          (list (limits-linger-timeout-ms default-limits) #t #t #t '(0 0) 1 'closed)
                          (list armed (eqv? after-arm armed) (eqv? after-cancel armed) reading open
                                (taker-closes t) (conn-phase (fake-shell-conn-state sh)))))))))
    ;; The client's end reaches the taker, not the core; so does a read
    ;; error, as its errno.
    (let* ((t (make-taker)) (sh (run eager (bytevector-length eager) (taking t))))
      (fake-shell-deliver! sh '(eof))
      (test-equal "the client's end reaches the taker, and the core is not told" '((eof) handed-off)
                  (list (taker-ends t) (conn-phase (fake-shell-conn-state sh)))))
    (let* ((t (make-taker)) (sh (run eager (bytevector-length eager) (taking t))))
      (fake-shell-deliver! sh '(read-error ECONNRESET))
      (test-equal "a read error reaches the taker as its errno" '((ECONNRESET) handed-off)
                  (list (taker-ends t) (conn-phase (fake-shell-conn-state sh)))))
    ;; Reading stopped, the next deliveries wait: the taker that stops at
    ;; its first read, the eager frames delivered 8 bytes at a time, is
    ;; handed that read and no more, and what was handed over and read is
    ;; what was delivered past the request.
    (let* ((t (make-taker))
           (sh (make-fake-connection
                default-limits
                (taking t (lambda (tr)
                            (transport-read-start! tr
                                                   (lambda (bv from to)
                                                     (taker-read-set! t (cons (slice bv from to) (taker-read t)))
                                                     (transport-read-stop! tr))
                                                   (lambda (why) #t))))))
           (delivered (fake-shell-feed-input! sh eager 8)))
      (test-equal "a taker that stops reading is handed nothing more: one read, the rest of the input not delivered"
                  '(1 #t #t)
                  (list (length (taker-read t)) (< delivered (bytevector-length eager))
                        (equal? (concat (cons (taker-retained t) (taker-read t)))
                                (slice eager (bytevector-length handshake) delivered)))))
    ;; One deadline, on the fake clock: not before its time, once at it, and
    ;; none once disarmed.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-deadline! tr 1000 (lambda () (taker-passes-set! t (+ 1 (taker-passes t))))))))))
      (fake-shell-advance! sh 999)
      (fake-shell-fire! sh)
      (let ((before (taker-passes t)))
        (fake-shell-advance! sh 1)
        (fake-shell-fire! sh)
        (fake-shell-fire! sh)
        (test-equal "a deadline passes once its time has come, and once" '(0 1) (list before (taker-passes t))))
      (transport-deadline! (taker-transport t) 1000 (lambda () (taker-passes-set! t (+ 10 (taker-passes t)))))
      (let ((armed (fake-shell-armed sh)))
        (transport-deadline! (taker-transport t) #f)
        (let ((disarmed (fake-shell-armed sh)))
          (fake-shell-advance! sh 5000)
          (fake-shell-fire! sh)
          (test-equal "a deadline disarmed never passes, and leaves nothing armed"
                      (list (+ (fake-shell-now sh) -5000 1000) #f 1)
                      (list armed disarmed (taker-passes t))))))
    ;; The drain call runs when the shell drains, once; one registered while
    ;; the shell drains runs at once.  A connection not handed off is told
    ;; to finish instead, as the libuv shell tells it.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-on-drain! tr (lambda () (taker-drains-set! t (+ 1 (taker-drains t))))))))))
      (fake-shell-drain! sh)
      (fake-shell-drain! sh)
      (transport-on-drain! (taker-transport t) (lambda () (taker-drains-set! t (+ 10 (taker-drains t)))))
      (test-eqv "the drain call runs once the shell drains, once, a call registered after it never" 1
                (taker-drains t)))
    (let* ((t (make-taker))
           (cell #f)
           (count-drain (lambda () (taker-drains-set! t (+ 1 (taker-drains t)))))
           (handler (taking t (lambda (tr) (transport-on-drain! tr count-drain))))
           (sh (make-fake-connection default-limits
                                     (lambda (request) (fake-shell-drain! cell) (handler request)))))
      (set! cell sh)
      (fake-shell-feed-input! sh eager (bytevector-length eager))
      (fake-shell-settle! sh)
      (test-equal "a switch answered while the shell drains: its drain call runs as it is registered"
                  '(1 handed-off) (list (taker-drains t) (conn-phase (fake-shell-conn-state sh)))))
    (let ((sh (make-fake-connection default-limits (switch-to))))
      (fake-shell-drain! sh)
      (test-equal "a connection not handed off is told to finish: idle, it closes"
                  '(((shutdown-requested)) closing)
                  (list (fake-shell-events sh) (conn-phase (fake-shell-conn-state sh)))))

    ;; --- a taker that waits (decision 0023) --------------------------------
    ;; Its take-over answers (awaiting thunk): the thunk runs on a coroutine,
    ;; where it waits, here for a read its on-bytes call resumes it with,
    ;; then writes what it was resumed with after the 101.
    (let* ((resume-to #f)
           (sh (run handshake (bytevector-length handshake)
                    (waiting-taking
                     (lambda (tr)
                       (transport-read-start! tr
                                              (lambda (bv from to)
                                                (let ((r resume-to)) (set! resume-to #f) (when r (r (slice bv from to)))))
                                              (lambda (why) #t)))
                     (lambda (tr)
                       (transport-write! tr (await (lambda (resume) (set! resume-to resume)))))))))
      (let ((parked (and resume-to #t)))
        (fake-shell-deliver! sh (list 'bytes-arrived hello-frame 0 (bytevector-length hello-frame)))
        (fake-shell-settle! sh)
        (test-equal "a take-over that answers awaiting: its thunk waits on a coroutine, resumed by a read, then writes"
                    (list #t (concat (list the-101 hello-frame)) 'handed-off)
                    (list parked (client-bytes sh) (conn-phase (fake-shell-conn-state sh))))))
    ;; Its waits are told once the stream has closed, whoever closed it, here
    ;; its taker as the client ends: the wait it is in raises &client-closed,
    ;; once, so its next wait does not.
    (let* ((seen '())
           (sh (run handshake (bytevector-length handshake)
                    (waiting-taking
                     (lambda (tr) (transport-read-start! tr (lambda (bv from to) #t) (lambda (why) (transport-close! tr))))
                     (lambda (tr)
                       (guard (e ((client-closed? e) (set! seen (cons 'told seen))))
                         (await (lambda (resume) #f)))
                       (set! seen (cons (await (lambda (resume) (resume 'next))) seen)))))))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "its wait is told once the stream has closed: the wait it is in raises &client-closed, its next does not"
                  '((told next) closed ())
                  (list (reverse seen) (conn-phase (fake-shell-conn-state sh)) (fake-shell-taker-failures sh))))
    ;; A thunk that lets the told close out is no failure; one that raises
    ;; anything else is, and its stream closes, as a take-over that raises
    ;; closes it.
    (let* ((started #f)
           (sh (run handshake (bytevector-length handshake)
                    (waiting-taking
                     (lambda (tr) (transport-read-start! tr (lambda (bv from to) #t) (lambda (why) (transport-close! tr))))
                     (lambda (tr) (set! started #t) (await (lambda (resume) #f)))))))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "a thunk that lets the told close out is no failure: nothing recorded, the stream closed"
                  '(#t () closed)
                  (list started (fake-shell-taker-failures sh) (conn-phase (fake-shell-conn-state sh)))))
    (let ((sh (run handshake (bytevector-length handshake)
                   (waiting-taking (lambda (tr) #t)
                                   (lambda (tr) (raise (make-message-condition "the waiting taker failed")))))))
      (test-equal "a thunk that raises anything else: the taker's failure, the stream closed after the 101"
                  (list '("the waiting taker failed") the-101 'closed)
                  (list (map condition-message (fake-shell-taker-failures sh)) (client-bytes sh)
                        (conn-phase (fake-shell-conn-state sh)))))
    ;; A thunk that ends leaves the stream as it was: open, its taker
    ;; reading on.
    (let* ((t (make-taker))
           (ended #f)
           (sh (run handshake (bytevector-length handshake)
                    (waiting-taking
                     (lambda (tr)
                       (transport-read-start! tr
                                              (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t))))
                                              (lambda (why) #t)))
                     (lambda (tr) (set! ended #t) 'done)))))
      (fake-shell-deliver! sh (list 'bytes-arrived hi-frame 0 (bytevector-length hi-frame)))
      (fake-shell-settle! sh)
      (test-equal "a thunk that ends leaves the stream open, its taker reading on"
                  (list #t (list hi-frame) 'handed-off '())
                  (list ended (reverse (taker-read t)) (conn-phase (fake-shell-conn-state sh))
                        (fake-shell-taker-failures sh))))

    ;; --- a stream aborted, and a taker's raise (decision 0024) --------------
    ;; The client reads nothing, so the taker's write never completes and its
    ;; close waits.  A deadline asked for then is armed, as the libuv shell
    ;; arms it, and its call's abort closes the stream: the write is told
    ;; ECANCELED, the close call runs once, and nothing failed.
    (let* ((t (make-taker))
           (sh (unread handshake
                       (taking t (lambda (tr)
                                   (transport-write! tr (b "unread") 0 6 (noting t))
                                   (transport-close! tr)
                                   (transport-deadline! tr 1000
                                                        (lambda ()
                                                          (taker-passes-set! t (+ 1 (taker-passes t)))
                                                          (transport-abort! tr))))))))
      (let ((armed (fake-shell-armed sh)) (open (taker-closes t)))
        (fake-shell-advance! sh 1000)
        (fake-shell-fire! sh)
        (fake-shell-settle! sh)
        (test-equal "a close waiting on a write the client has not read: a deadline asked for then is armed, and its call's abort closes the stream, the write told ECANCELED, nothing failed"
                    '(1000 0 1 (ECANCELED) 1 closed ())
                    (list armed open (taker-passes t) (taker-written t) (taker-closes t)
                          (conn-phase (fake-shell-conn-state sh)) (fake-shell-taker-failures sh)))))
    ;; Aborted at once, a write outstanding and a deadline armed: reading
    ;; stops, that write and one asked for after are told ECANCELED, the
    ;; client reads neither, the stream closes, and the deadline is disarmed
    ;; with it, never passing, as the libuv shell's close disarms it.
    (let* ((t (make-taker))
           (sh (unread handshake
                       (taking t (lambda (tr)
                                   (transport-deadline! tr 1000 (lambda () (taker-passes-set! t (+ 1 (taker-passes t)))))
                                   (transport-write! tr (b "unread") 0 6 (noting t))
                                   (transport-abort! tr)
                                   (transport-write! tr (b "late") 0 4 (noting t)))))))
      (let ((reading (fake-shell-reading? sh)))
        (fake-shell-settle! sh)
        (fake-shell-advance! sh 1000)
        (fake-shell-fire! sh)
        (test-equal "aborted with a write outstanding and a deadline armed: reading stops, that write and a later one are told ECANCELED, the client reads neither, the stream closes, its close call once, the deadline never passing"
                    '(#f (ECANCELED ECANCELED) #t 1 closed 0)
                    (list reading (taker-written t) (equal? (client-bytes sh) the-101) (taker-closes t)
                          (conn-phase (fake-shell-conn-state sh)) (taker-passes t)))))
    ;; Once its close has been asked for, here by an abort, a taker is read
    ;; nothing more, as the libuv shell reads nothing then; and a stream's
    ;; end is told once: a read error after the client's end reaches no one.
    (let* ((t1 (make-taker)) (sh1 (run handshake (bytevector-length handshake) (taking t1)))
           (t2 (make-taker))
           (sh2 (run handshake (bytevector-length handshake) (taking t2 (lambda (tr) (transport-abort! tr))))))
      (fake-shell-deliver! sh1 '(eof))
      (fake-shell-deliver! sh1 '(read-error ECONNRESET))
      (fake-shell-deliver! sh2 (list 'bytes-arrived hi-frame 0 (bytevector-length hi-frame)))
      (fake-shell-deliver! sh2 '(eof))
      (test-equal "a stream's end reaches the taker once, a read error after it no one; once the stream is aborted, neither a read nor the end reaches it"
                  '((eof) () ())
                  (list (taker-ends t1) (taker-read t2) (taker-ends t2))))
    ;; A raise in any call into the taker's code is its failure, recorded,
    ;; and closes the stream at once, its write outstanding told ECANCELED.
    ;; A raise in a write's callback comes once the client has read the
    ;; write, so nothing is left to cancel; one in the close call, once the
    ;; stream has closed.
    (test-equal "a raise in the take-over, its read, its end, its deadline's call or its drain call: the taker's failure, recorded, and the stream closed at once, its write told ECANCELED; in a write's callback, the same once written; in its close call, recorded"
                '((("take-over") (ECANCELED) 1 closed) (("read") (ECANCELED) 1 closed)
                  (("end") (ECANCELED) 1 closed) (("deadline") (ECANCELED) 1 closed)
                  (("drain") (ECANCELED) 1 closed) (("written") (#f) 1 closed)
                  (("close") (ECANCELED) 1 closed))
                (map raised-in '(take-over read end deadline drain written close)))
    ;; And the two calls made once the close has been asked for: the callback
    ;; of a write asked for after it, told ECANCELED, and a close call
    ;; registered once the stream has closed, run at once.
    (test-equal "a raise in the callback of a write asked for after the close, or in a close call registered once the stream has closed: each the taker's failure, recorded"
                '("late-written" "late-close")
                (late-raises))
    ;; A waiting thunk's raise closes the stream at once too.
    (let* ((t (make-taker))
           (sh (unread handshake
                       (waiting-taking
                        (lambda (tr) (counting-closes t tr))
                        (lambda (tr)
                          (transport-write! tr (b "unread") 0 6 (noting t))
                          (raise (make-message-condition "the waiting taker failed")))))))
      (fake-shell-settle! sh)
      (test-equal "a waiting thunk that raises with a write outstanding: the taker's failure, the write told ECANCELED, the stream closed"
                  '(("the waiting taker failed") (ECANCELED) 1 closed)
                  (list (map condition-message (fake-shell-taker-failures sh)) (taker-written t) (taker-closes t)
                        (conn-phase (fake-shell-conn-state sh)))))

    ;; --- the door closed (decision 0016 items 1 and 4) ----------------------
    (test-equal "a request that does not upgrade, answered a switch: 500, logged not-an-upgrade, the staged close"
                '((500) ((log invalid-response not-an-upgrade)) lingering invalid-response)
                (refused (b "GET /chat HTTP/1.1\r\nHost: x\r\n\r\n") (switch-to)))
    (test-equal "an HTTP/1.0 upgrade (RFC 9110 §7.8: its Upgrade ignored): the same"
                '((500) ((log invalid-response not-an-upgrade)) lingering invalid-response)
                (refused (b "GET /chat HTTP/1.0\r\nConnection: keep-alive, upgrade\r\nUpgrade: websocket\r\n\r\n")
                         (switch-to)))
    (test-equal "a CONNECT: the same"
                '((500) ((log invalid-response not-an-upgrade)) lingering invalid-response)
                (refused (b "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n") (switch-to)))
    (test-equal "an upgrade with a body, answered at its head: the same"
                '((500) ((log invalid-response not-an-upgrade)) lingering invalid-response)
                (refused (b (string-append ws-request "Content-Length: 4\r\n\r\nabcd")) (switch-to)))
    (test-equal "a switch to a protocol the request did not offer: 500, logged invalid-upgrade"
                '((500) ((log invalid-response invalid-upgrade)) lingering invalid-response)
                (refused (b (string-append ws-request "\r\n")) (switch-to "h2c")))))
