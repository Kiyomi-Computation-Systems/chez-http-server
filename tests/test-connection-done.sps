#!r6rs
;;; How a request's response ended, told to what its code registered, through
;;; the fake shell, with chez-httparse driving the core.
;;;
;;; A handler, its reader or its producer registers a procedure with
;;; `request-on-done!`; the core tells the request once, as its response
;;; ends, with `written`, `client-closed` or `failed`, and the shell calls
;;; what was registered, newest first, from its scheduler's drain, a
;;; switch's in place.  The rows:
;;;   - written: kept alive, before the next request's handler is called;
;;;     newest first; held, at the scheduler's drain after the write
;;;     completed; a switch's 101, before its take-over; a client's end
;;;     while the handler waits, then its answer, written to the client that
;;;     only half-closed;
;;;   - client-closed: a read error while a producer streams, the producer
;;;     called no more after it; the client's end while a body is read;
;;;   - failed: a handler that raises, a faulty response, the write deadline,
;;;     a producer that raises after the head, a body past its reader's cap
;;;     and one past its deadline, and a close the core did not ask for;
;;;   - a procedure that raises is the shell's to report, the others still
;;;     told and the connection going on;
;;;   - one registered once the response is done is called at once, with how
;;;     it ended, whether or not anything was registered before;
;;;   - while the request's code still runs on a coroutine, the procedures
;;;     wait for that call to end, and a reader let go is handed no more;
;;;   - with nothing registered, the core asks for nothing.
;;;
;;; Oracles: the requests' own bytes; RFC 9110 §15.5.14 (413) and §15.5.9
;;; (408), statuses the core already answers.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server span) (http-server limits) (http-server body) (http-server switch)
        (fake-shell)
        (only (http-server awaiting) awaiting client-closed?)
        (only (http-server private waits) sleep-ms))

(define (b s) (string->utf8 s))

(define resp (make-response 200 #f '() (b "ok")))

;; heard : (Listof (List Symbol Symbol))
;; What the registered procedures were told, in the order told, each as its
;; name and how the response ended.
(define heard '())
(define (hearing name) (lambda (how) (set! heard (append heard (list (list name how))))))
(define (heard!) (let ((h heard)) (set! heard '()) h))

;; get-bytes : String -> Bytevector — a GET of `path` with a Host.
(define (get-bytes path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; post-head : Nat -> Bytevector — a POST's head announcing `n` bytes.
(define (post-head n)
  (b (string-append "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: " (number->string n) "\r\n\r\n")))

;; join : Bytevector ... -> Bytevector — one bytevector of them all, in order.
(define (join . bvs)
  (let ((o (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
    (fold-left (lambda (at bv) (bytevector-copy! bv 0 o at (bytevector-length bv)) (+ at (bytevector-length bv)))
               0 bvs)
    o))

;; sub : Bytevector Nat Nat -> Bytevector — a copy of bv[from, to).
(define (sub bv from to)
  (let ((o (make-bytevector (- to from))))
    (bytevector-copy! bv from o 0 (- to from))
    o))

;; deliver : FakeShell Bytevector -> Void — one delivery of all of `bv`.
(define (deliver sh bv) (fake-shell-deliver! sh (list 'bytes-arrived bv 0 (bytevector-length bv))))

;; path : Request -> String
(define (path r) (utf8->string (span->bytevector (request-target r))))

;; statuses : FakeShell -> (Listof Nat) — the status of each response written.
(define (statuses sh)
  (map written-status (filter (lambda (a) (and (eq? (car a) 'write)
                                               (let ((line (car (cadr a))))
                                                 (and (bytevector? line)
                                                      (>= (bytevector-length line) 12)
                                                      (equal? (b "HTTP/1.1 ")
                                                              (let ((o (make-bytevector 9)))
                                                                (bytevector-copy! line 0 o 0 9)
                                                                o))))))
                              (fake-shell-actions sh))))

;; asked : FakeShell -> (Listof Symbol) — the kinds of its actions named `kind`.
(define (asked sh kind) (filter (lambda (a) (eq? (car a) kind)) (fake-shell-actions sh)))

;; registering : Symbol Answer -> (Request -> Answer)
;; A handler that registers a procedure named `name`, then answers `answer`.
(define (registering name answer)
  (lambda (r) (request-on-done! r (hearing name)) answer))

;; endless : (-> Nat) — a producer of 1,000-byte pieces that never ends,
;; and a thunk counting its calls.
(define (endless)
  (let ((calls 0) (piece (make-bytevector 1000 65)))
    (values (lambda () (set! calls (+ calls 1)) piece) (lambda () calls))))

;; WebSocket's handshake, RFC 6455 §1.2's, and its 101's accept field.
(define handshake
  (b (string-append "GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUpgrade: websocket\r\n"
                    "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                    "Sec-WebSocket-Version: 13\r\n\r\n")))
(define accept (cons (b "Sec-WebSocket-Accept") (b "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")))

(run-suite "connection-done"
  (lambda ()
    ;; --- written -----------------------------------------------------------
    (heard!)
    (let* ((at-second #f)
           (sh (make-fake-connection
                default-limits
                (lambda (r)
                  (when (string=? (path r) "/2") (set! at-second heard))
                  (request-on-done! r (hearing (string->symbol (path r))))
                  resp))))
      (deliver sh (join (get-bytes "/1") (get-bytes "/2")))
      (fake-shell-settle! sh)
      (test-equal "kept alive: each request told written, once, the first before the second's handler is called"
                  '(((/1 written)) ((/1 written) (/2 written)) (200 200) ())
                  (list at-second (heard!) (statuses sh) (fake-shell-violations sh))))

    (let ((sh (make-fake-connection
               default-limits
               (lambda (r)
                 (request-on-done! r (hearing 'outer))
                 (request-on-done! r (hearing 'inner))
                 resp))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (test-equal "several registered are told newest first" '((inner written) (outer written)) (heard!)))

    ;; Held, as the contract test holds it, the scheduler is drained only
    ;; when asked, as the libuv shell drains its own once a turn: the
    ;; procedure is told at the drain after the write completed, not in
    ;; place as it completes.
    (let ((sh (make-fake-connection default-limits (registering 'held resp))))
      (fake-shell-hold! sh #t)
      (deliver sh (get-bytes "/"))
      (fake-shell-schedule! sh)
      (fake-shell-settle! sh)
      (let ((completed (heard!)))
        (fake-shell-schedule! sh)
        (test-equal "held: the response written, its procedure is told at the scheduler's next drain, not as its write completes"
                    '(() ((held written)) (200))
                    (list completed (heard!) (statuses sh)))))

    (let* ((at-take-over #f)
           (sh (make-fake-connection
                default-limits
                (lambda (r)
                  (request-on-done! r (hearing 'switch))
                  (switch-protocols (list (cons (b "Upgrade") (b "websocket")) accept)
                                    (lambda (transport retained) (set! at-take-over heard)))))))
      (deliver sh handshake)
      (fake-shell-settle! sh)
      (test-equal "a switch: told written once its 101 is written, before its take-over is called"
                  '(((switch written)) ((switch written)) handed-off)
                  (list at-take-over (heard!) (conn-phase (fake-shell-conn-state sh)))))

    (let ((sh (make-fake-connection
               default-limits
               (lambda (r)
                 (request-on-done! r (hearing 'waits))
                 (awaiting (lambda () (guard (e ((client-closed? e) resp)) (sleep-ms 10) resp)))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "the client's end while the handler waits, then its answer, written to the client that half-closed: written"
                  '(((waits written)) (200))
                  (list (heard!) (statuses sh))))

    ;; --- client-closed -----------------------------------------------------
    (let-values (((producer calls) (endless)))
      (let ((sh (make-fake-connection default-limits
                                      (registering 'stream (make-response 200 #f '() producer)))))
        (deliver sh (get-bytes "/"))
        (let ((before (calls)))
          (fake-shell-deliver! sh '(read-error ECONNRESET))
          (fake-shell-settle! sh)
          (test-equal "a read error while a producer streams: client-closed, and the producer is called no more"
                      (list '((stream client-closed)) before)
                      (list (heard!) (calls))))))

    (let ((sh (make-fake-connection default-limits
                                    (registering 'reader (read-body (lambda (bv from to) #t)
                                                                    (lambda () resp))))))
      (deliver sh (join (post-head 10) (b "abc")))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "the client's end while a reader reads the body: client-closed" '((reader client-closed)) (heard!)))

    ;; --- failed ------------------------------------------------------------
    (let ((sh (make-fake-connection default-limits
                                    (lambda (r) (request-on-done! r (hearing 'raises)) (raise 'boom)))))
      (deliver sh (get-bytes "/"))
      (let ((before (heard!)))
        (fake-shell-settle! sh)
        (test-equal "a handler that raises: nothing told until its 500 is written, then failed"
                    '(() ((raises failed)) (500))
                    (list before (heard!) (statuses sh)))))

    (let ((sh (make-fake-connection default-limits
                                    (registering 'faulty (make-response 200 #f (list (cons (b "Content-Length") (b "2")))
                                                                        (b "ok"))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (test-equal "a response the server cannot write safely, answered 500: failed"
                  '(((faulty failed)) (500)) (list (heard!) (statuses sh))))

    (let ((sh (make-fake-connection default-limits (registering 'slow resp))))
      (deliver sh (get-bytes "/"))
      (fake-shell-advance! sh (limits-deadline-ms default-limits 'write))
      (fake-shell-fire! sh)
      (test-equal "past the write deadline, the response's write never completed: failed"
                  '(((slow failed)) closing)
                  (list (heard!) (conn-phase (fake-shell-conn-state sh)))))

    (let ((sh (make-fake-connection default-limits
                                    (registering 'producer (make-response 200 #f '() (lambda () (raise 'boom)))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (test-equal "a producer that raises once the head is written: failed" '((producer failed)) (heard!)))

    (let ((sh (make-fake-connection default-limits
                                    (registering 'capped (read-whole-body (lambda (bv) resp) 5)))))
      (deliver sh (join (post-head 10) (b "0123456789")))
      (fake-shell-settle! sh)
      (test-equal "a body past its reader's cap, answered 413: failed"
                  '(((capped failed)) (413)) (list (heard!) (statuses sh))))

    (let ((sh (make-fake-connection default-limits
                                    (registering 'stalled (read-body (lambda (bv from to) #t)
                                                                     (lambda () resp))))))
      (deliver sh (join (post-head 10) (b "abc")))
      (fake-shell-advance! sh (limits-deadline-ms default-limits 'body))
      (fake-shell-fire! sh)
      (fake-shell-settle! sh)
      (test-equal "a body past its deadline, answered 408: failed"
                  '(((stalled failed)) (408)) (list (heard!) (statuses sh))))

    (let ((sh (make-fake-connection default-limits
                                    (lambda (r)
                                      (request-on-done! r (hearing 'outside))
                                      (awaiting (lambda () (sleep-ms 10) resp))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-deliver! sh '(closed))
      (let ((before (heard!)))
        (fake-shell-advance! sh 10)
        (fake-shell-fire-waits! sh)
        (test-equal "a close the core did not ask for, while the handler waits: failed, once the handler's call ends"
                    '(() ((outside failed)))
                    (list before (heard!)))))

    ;; A sized body whose producer disagrees with its length is cut short:
    ;; its fault, failed, past the length or short of it; but short of it
    ;; once the client has closed, the client's doing, client-closed.
    (let ((sh (make-fake-connection default-limits
                                    (registering 'long (make-response 200 #f '()
                                                                      (sized-body 2 (lambda () (b "abc"))))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (test-equal "a sized body's producer past its length: failed" '((long failed)) (heard!)))
    (let ((sh (make-fake-connection default-limits
                                    (registering 'short (make-response 200 #f '()
                                                                       (sized-body 5 (lambda () (eof-object))))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (test-equal "a sized body's producer short of its length: failed" '((short failed)) (heard!)))
    (let ((sh (make-fake-connection (limits-with default-limits '((write-high-water . 1) (write-low-water . 1)))
                                    (registering 'left (make-response 200 #f '()
                                                                      (sized-body 5 (lambda () (eof-object))))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-deliver! sh '(eof))
      (fake-shell-settle! sh)
      (test-equal "a sized body's producer short of its length once the client has closed: client-closed"
                  '((left client-closed)) (heard!)))

    ;; --- while the request's code still runs -------------------------------
    ;; A reader of a handler that waits takes each piece on a coroutine.  A
    ;; chunked body passes the cap of 5 at its second piece, so the reader is
    ;; handed "abc" and the prefix "de", and the 413 is written while it
    ;; still waits inside "abc".  The procedure is told once that call has
    ;; ended, and the reader, let go as the connection lingers, is handed
    ;; nothing more.
    (let* ((seen '())
           (note (lambda (x) (set! seen (append seen (list x)))))
           (sh (make-fake-connection
                (limits-with default-limits '((max-body-bytes . 5)))
                (lambda (r)
                  (request-on-done! r (lambda (how) (note (list 'done how))))
                  (awaiting
                   (lambda ()
                     (read-body (lambda (bv from to)
                                  (let ((text (utf8->string (sub bv from to))))
                                    (note (list 'start text))
                                    (sleep-ms 10)
                                    (note (list 'end text))))
                                (lambda () resp))))))))
      (deliver sh (join (b "POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
                        (b "3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n")))
      (fake-shell-settle! sh)
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (test-equal "a reader still waiting inside a piece as its 413 is written: told failed once that piece's call ends, and handed nothing after"
                  '(((start "abc") (end "abc") (done failed)) (413))
                  (list seen (statuses sh))))

    ;; --- a procedure that raises -------------------------------------------
    (let ((sh (make-fake-connection
               default-limits
               (lambda (r)
                 (request-on-done! r (hearing (string->symbol (string-append (path r) "-first"))))
                 (request-on-done! r (lambda (how) (raise 'boom)))
                 (request-on-done! r (hearing (string->symbol (string-append (path r) "-third"))))
                 resp))))
      (deliver sh (join (get-bytes "/1") (get-bytes "/2")))
      (fake-shell-settle! sh)
      (test-equal "a procedure that raises: reported, the others still told, the connection going on"
                  '(((/1-third written) (/1-first written) (/2-third written) (/2-first written))
                    (boom boom) (200 200) idle)
                  (list (heard!) (fake-shell-done-failures sh) (statuses sh)
                        (conn-phase (fake-shell-conn-state sh)))))

    ;; --- a registration once the response is done --------------------------
    (let ((sh (make-fake-connection
               default-limits
               (lambda (r)
                 (request-on-done! r (hearing 'early))
                 (awaiting (lambda ()
                             (guard (e ((client-closed? e) (request-on-done! r (hearing 'late)) resp))
                               (sleep-ms 10)
                               resp)))))))
      (deliver sh (get-bytes "/"))
      (fake-shell-deliver! sh '(read-error ECONNRESET))
      (fake-shell-settle! sh)
      (test-equal "registered once the client has reset, by the handler's code told of it: called at once, client-closed, newest first, the one before it told once the handler's call ends"
                  '((late client-closed) (early client-closed)) (heard!)))

    (let* ((kept #f)
           (sh (make-fake-connection default-limits (lambda (r) (set! kept r) resp))))
      (deliver sh (get-bytes "/"))
      (fake-shell-settle! sh)
      (let ((asked-for (asked sh 'response-done)))
        (request-on-done! kept (hearing 'late))
        (test-equal "with nothing registered, no response-done is asked for; one registered after is called at once, written"
                    '(() ((late written)))
                    (list asked-for (heard!)))))))
