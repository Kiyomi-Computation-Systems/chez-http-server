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
;;; Oracles: decision 0016; RFC 9110 §7.8 and §15.2.2; RFC 6455 §5.7's
;;; masked "Hello" frame, two of its bytes after the header; the inputs'
;;; own bytes; design §6.5's 500; decision 0011's staged close.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (http-server switch) (http-server transport)
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
       (transport-on-close! transport (lambda () (taker-closes-set! t (+ 1 (taker-closes t)))))
       (transport-read-start! transport
                              (lambda (bv from to) (taker-read-set! t (cons (slice bv from to) (taker-read t))))
                              (lambda (why) (taker-ends-set! t (cons why (taker-ends t)))))
       (unless (null? then) ((car then) transport))))))

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
    (test-equal "the core's part, from the handler's call: the 101 written, then the hand-off, disarmed first, and nothing after"
                '((call-handler (GET "/chat")) (write 101) (arm-deadline write) (disarm-deadline) hand-off)
                (let ((sh (run eager (bytevector-length eager) (taking (make-taker)))))
                  (map (lambda (a) (if (eq? (car a) 'hand-off) 'hand-off a))
                       (let from ((as (rendered-actions sh)))
                         (cond ((null? as) '())
                               ((eq? (caar as) 'call-handler) as)
                               (else (from (cdr as))))))))

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
    ;; The taker's close: once its writes are written, the connection closes,
    ;; its close call runs once, and the core ends closed.  A write asked for
    ;; after the close is not written: its callback is told ECANCELED.
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager)
                    (taking t (lambda (tr)
                                (transport-write! tr (b "bye"))
                                (transport-close! tr)
                                (transport-write! tr (b "late") 0 4
                                                  (lambda (err) (taker-written-set! t (cons err (taker-written t))))))))))
      (test-equal "closed by the taker: its write first, its close call once, a later write cancelled, the core closed"
                  (list (concat (list the-101 (b "bye"))) 1 '(ECANCELED) 'closed)
                  (list (client-bytes sh) (taker-closes t) (taker-written t)
                        (conn-phase (fake-shell-conn-state sh)))))
    ;; A close call registered once the stream has closed runs at once, so a
    ;; taker that asks late still hears of the close (M8.2's review, the
    ;; eighth).
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager) (taking t (lambda (tr) (transport-close! tr))))))
      (let ((before (taker-closes t)))
        (transport-on-close! (taker-transport t) (lambda () (taker-closes-set! t (+ 10 (taker-closes t)))))
        (test-equal "a close call registered after the stream has closed runs at once"
                    '(closed 1 11)
                    (list (conn-phase (fake-shell-conn-state sh)) before (taker-closes t)))))
    ;; On a stream that has closed, a deadline arms nothing and never passes,
    ;; as the libuv shell's arms none (M8.2's review, the seventh).
    (let* ((t (make-taker))
           (sh (run eager (bytevector-length eager) (taking t (lambda (tr) (transport-close! tr))))))
      (transport-deadline! (taker-transport t) 1000 (lambda () (taker-passes-set! t (+ 1 (taker-passes t)))))
      (let ((armed (fake-shell-armed sh)))
        (fake-shell-advance! sh 2000)
        (fake-shell-fire! sh)
        (test-equal "on a stream that has closed, a deadline arms nothing and never passes"
                    '(closed #f 0)
                    (list (conn-phase (fake-shell-conn-state sh)) armed (taker-passes t)))))
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
