#!r6rs
;;; (http-server connection): a streamed response, through the fake shell's
;;; message loop.
;;;
;;; A response's body of unknown length is a producer, a procedure the
;;; server calls for each piece, which answers a bytevector, or the eof
;;; object at the end.  The core writes the head, then asks the shell for a
;;; piece at a time, `notify-producer`, and writes each as it comes: chunked
;;; to HTTP/1.1, and close-delimited to 1.0, after which the connection
;;; closes.  The limits' write water marks bound what is outstanding: the
;;; producer is asked only while the bytes written and not yet completed are
;;; at or below the high water, so at most one piece passes it, and once past
;;; it, it is asked again only when they fall to the low water.  The writes
;;; outstanding are bounded too, at 64, and a waiting producer is asked again
;;; at 16 or fewer.  A producer that fails once the head is on the wire gets
;;; a bare close: a status can no longer be written.
;;;
;;; What a connection wrote is read back as a client reads it, by
;;; chez-httparse's strict response parser (response-reader), which is not
;;; our code.  The fake shell completes each write on a later turn, as libuv
;;; does, so within a turn the bytes outstanding only grow, as they do for a
;;; client that reads slowly.
;;;
;;; Oracles: the limits' write water marks, 262,144 and 65,536 bytes
;;; outstanding, and smaller ones for the flows that watch them act, and
;;; the bounds of 64 and 16 writes outstanding; RFC 9112 §7.1 (chunked) and
;;; §6.3 rule 8 (close-delimited), through the response parser; and the
;;; requests' and the pieces' own bytes.  A chunked piece of 16 KiB is
;;; written in 16,392 bytes: its size line, `4000` CRLF, the piece, and CRLF;
;;; one of 100 bytes in 106.  The head of a chunked 200 is 84 bytes: the
;;; status line 17, the Date 37, and `Transfer-Encoding: chunked` CRLF CRLF
;;; 30.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits) (http-server body)
        (fake-shell) (response-reader) (producers))

(define (b s) (string->utf8 s))

;; The Date the fake clock's 0 dates every write at (RFC 9110 §5.6.7).
(define epoch-date '("Date" . "Thu, 01 Jan 1970 00:00:00 GMT"))

(define get11 (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(define get10 (b "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"))
(define head11 (b "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"))
(define post11 (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789"))
(define two-gets (b "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"))

;; waters : Nat Nat -> Limits — the default limits with these water marks.
(define (waters high low)
  (limits-with default-limits (list (cons 'write-high-water high) (cons 'write-low-water low))))

;; --- producers (tests/producers.sls) -------------------------------------------

;; texts-producer : (Listof String) -> (values Producer (-> Nat))
;; A producer answering each text's bytes in turn, then the eof object; and
;; how many times it was called.
(define (texts-producer texts) (counted (producer-of texts)))

;; answering : Producer -> (Request -> Response)
;; A handler answering every request with a 200 streamed from `producer`.
(define (answering producer) (lambda (request) (make-response 200 #f '() producer)))

;; --- a connection --------------------------------------------------------------

;; What a stream did, read as each action runs, once the step that emitted it
;; has run: each ask, as the event it followed and the bytes and the writes
;; outstanding then, newest first; and the most bytes, and the most writes,
;; outstanding after any write.
(define-record-type watch
  (fields (mutable shell) (mutable asks) (mutable most) (mutable most-writes)
          (mutable last-event)))

(define (watching) (make-watch #f '() 0 0 #f))

;; tracer : Watch -> (Symbol Any -> Any) — a fake connection's trace.
(define (tracer w)
  (lambda (kind datum)
    (let ((s (fake-shell-conn-state (watch-shell w))))
      (case kind
        ((event) (watch-last-event-set! w (car datum)))
        ((action)
         (case (car datum)
           ((notify-producer)
            (watch-asks-set! w (cons (list (watch-last-event w) (conn-outstanding-bytes s)
                                           (conn-outstanding s))
                                     (watch-asks w))))
           ((write)
            (watch-most-set! w (max (watch-most w) (conn-outstanding-bytes s)))
            (watch-most-writes-set! w (max (watch-most-writes w) (conn-outstanding s))))
           (else #t)))
        (else #t)))))

;; connect : Limits (Request -> Any) Watch -> FakeShell
;; A fake connection, watched.
(define (connect limits handler w)
  (let ((sh (make-fake-connection limits handler (tracer w))))
    (watch-shell-set! w sh)
    sh))

;; serve : Limits (Request -> Any) Bytevector [Watch] -> FakeShell
;; A connection that reads `input` in one delivery, each write completing on
;; a later turn, until nothing more is to come.
(define serve
  (case-lambda
    ((limits handler input) (serve limits handler input (watching)))
    ((limits handler input w)
     (let ((sh (connect limits handler w)))
       (fake-shell-feed-input! sh input (bytevector-length input))
       (fake-shell-settle! sh)
       sh))))

;; begun : Limits (Request -> Any) Bytevector -> FakeShell
;; A connection that has read `input` in one delivery, and whose writes have
;; not completed: a client that reads nothing yet.
(define (begun limits handler input)
  (let ((sh (connect limits handler (watching))))
    (fake-shell-deliver! sh (list 'bytes-arrived input 0 (bytevector-length input)))
    sh))

;; wire : FakeShell -> Bytevector — every write's bytes, in order.
(define (wire sh)
  (let* ((writes (fake-shell-writes sh))
         (out (make-bytevector (fold-left (lambda (n w) (+ n (bytevector-length w))) 0 writes))))
    (fold-left (lambda (at w) (bytevector-copy! w 0 out at (bytevector-length w)) (+ at (bytevector-length w)))
               0 writes)
    out))

;; read-back : FakeShell Boolean Boolean -> Datum
;; What a client reads of the wire: the parser skips the body of a HEAD's
;; answer, and at the stream's end, `eof?`, finishes a message the close
;; delimits.
(define (read-back sh head? eof?) (read-response (wire sh) head? eof?))

;; status+body : Datum -> (List Nat String Symbol) — a read-back's status,
;; body and end, for a body too long to write out.
(define (status+body r) (list (car r) (cadddr r) (list-ref r 4)))

;; ended : FakeShell -> (List Phase CloseAfter) — where the connection is left.
(define (ended sh) (let ((s (fake-shell-conn-state sh))) (list (conn-phase s) (conn-close-after s))))

;; last-actions : FakeShell Nat -> (Listof Action) — the last `n` actions run.
(define (last-actions sh n)
  (let ((as (fake-shell-actions sh)))
    (list-tail as (- (length as) n))))

;; ran? : FakeShell Symbol -> (U Symbol 'none) — whether an action of `kind` ran.
(define (ran? sh kind)
  (if (exists (lambda (a) (eq? (car a) kind)) (fake-shell-actions sh)) kind 'none))

;; classify : Bytevector -> Symbol — a write as a head, a piece, or the last chunk.
(define (classify w)
  (let ((text (utf8->string w)))
    (cond ((and (>= (string-length text) 9) (string=? (substring text 0 9) "HTTP/1.1 ")) 'head)
          ((string=? text "0\r\n\r\n") 'end)
          (else 'piece))))

(run-suite "connection-stream"
  (lambda ()
    ;; --- framing: chunked to HTTP/1.1, close-delimited to 1.0 ---
    (test-equal "HTTP/1.1: the pieces chunked, read back whole; the producer called for each and for its end; the connection kept"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "hello, world" complete) 4 (idle #f) ())
                (let-values (((p calls) (texts-producer '("hello" ", " "world"))))
                  (let ((sh (serve default-limits (answering p) get11)))
                    (list (read-back sh #f #f) (calls) (ended sh) (fake-shell-violations sh)))))
    ;; A close-delimited body ends only with the connection (RFC 9112 §6.3
    ;; rule 8), so the connection closes after it, though this client asked to
    ;; keep it, and the head says so.  It lingers, the half-close its body's
    ;; end.
    (test-equal "HTTP/1.0: the pieces close-delimited, read back whole at the close; the connection closes after, though the client asked to keep it"
                `((200 "OK" (,epoch-date ("Connection" . "close")) "hello, world" complete) 4
                  (lingering close-delimited) shutdown)
                (let-values (((p calls) (texts-producer '("hello" ", " "world"))))
                  (let ((sh (serve default-limits (answering p) get10)))
                    (list (read-back sh #f #t) (calls) (ended sh) (ran? sh 'shutdown)))))
    ;; RFC 9110 §9.3.2 and §15.3.5: no body is written to a HEAD or in a 204,
    ;; so the producer is never called; a HEAD's length is unknown, and not
    ;; announced.
    (test-equal "a HEAD's answer, and a 204: the head alone; the producer never called; the connection kept"
                `(((200 "OK" (,epoch-date) "" complete) 0 (idle #f))
                  ((204 "No Content" (,epoch-date) "" complete) 0 (idle #f)))
                (list (let-values (((p calls) (texts-producer '("never"))))
                        (let ((sh (serve default-limits (answering p) head11)))
                          (list (read-back sh #t #f) (calls) (ended sh))))
                      (let-values (((p calls) (texts-producer '("never"))))
                        (let ((sh (serve default-limits
                                         (lambda (request) (make-response 204 #f '() p)) get11)))
                          (list (read-back sh #f #f) (calls) (ended sh))))))

    ;; --- the write water marks ---
    ;; 1 MiB in 64 pieces of 16 KiB, under the default marks: the first turn asks
    ;; for pieces while at most 262,144 bytes are outstanding, sixteen of
    ;; them, 262,356 bytes with the head, then waits for completions.  So the
    ;; bytes outstanding never pass the high water by more than one piece's
    ;; write, 16,392 bytes, where a producer asked regardless would have the
    ;; whole body outstanding at once: the slow reader's memory bound.
    (test-equal "the write water marks: 1 MiB in 16 KiB pieces, read back whole; the bytes outstanding never past the high water by more than a piece's write"
                (list (list 200 (sized-body 64 16384) 'complete) #t 65 '(idle #f))
                (let-values (((p calls) (counted (sized-producer 64 16384))))
                  (let* ((w (watching)) (sh (serve default-limits (answering p) get11 w)))
                    (list (status+body (read-back sh #f #f))
                          (<= (watch-most w) (+ 262144 16392))
                          (calls) (ended sh)))))
    ;; Under a high water of 1,000 and a low of 300, 30 pieces of 100 bytes:
    ;; the producer is asked at or below the high water, first after the
    ;; head, then after each piece; past it, it waits, and is asked again only
    ;; once a completion brings the bytes outstanding to the low water.
    (test-equal "past the high water the producer waits, and is told to go on at the low water: every ask at or below the high water, every one after a completion at or below the low water"
                (list '() '() 'waited (list 200 (sized-body 30 100) 'complete) 31)
                (let-values (((p calls) (counted (sized-producer 30 100))))
                  (let* ((w (watching)) (sh (serve (waters 1000 300) (answering p) get11 w))
                         (asks (reverse (watch-asks w))))
                    (list (filter (lambda (a) (> (cadr a) 1000)) asks)
                          (filter (lambda (a) (and (eq? (car a) 'write-completed) (> (cadr a) 300))) asks)
                          (if (exists (lambda (a) (eq? (car a) 'write-completed)) asks) 'waited 'never-waited)
                          (status+body (read-back sh #f #f))
                          (calls)))))
    ;; Each piece is a write of its own, and a write holds the loop and
    ;; memory the same whatever its size, so the producer is asked only while
    ;; fewer than 64 writes are outstanding too, and once at 64, again only
    ;; when 16 or fewer are.  1,000 pieces of 100 bytes, 106 each written,
    ;; under the default marks: the bytes alone would let the first turn ask
    ;; for all 1,000, 106,000 bytes; the writes let it ask for 63 after the
    ;; head, and each later turn for 48.
    (test-equal "small pieces: at most 64 writes outstanding, every ask after a completion at 16 writes or fewer, read back whole"
                (list 64 '() (list 200 (sized-body 1000 100) 'complete) 1001)
                (let-values (((p calls) (counted (sized-producer 1000 100))))
                  (let* ((w (watching)) (sh (serve default-limits (answering p) get11 w))
                         (asks (reverse (watch-asks w))))
                    (list (watch-most-writes w)
                          (filter (lambda (a) (and (eq? (car a) 'write-completed) (> (caddr a) 16))) asks)
                          (status+body (read-back sh #f #f))
                          (calls)))))

    ;; --- a failure once the head is on the wire: a bare close ---
    ;; No status can be written after the head, so the connection closes at
    ;; once, with no half-close: the client reads a chunked body cut short,
    ;; with no last chunk (RFC 9112 §8: incomplete).
    (test-equal "a producer that raises after a piece: a bare close, the body cut short, no status written"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "hello" need-input)
                  closed ((disarm-deadline) (close handler-failed)) none 2)
                (let ((sh (serve default-limits (answering (producer-of '("hello") (lambda () (raise 'boom))))
                                 get11)))
                  (list (read-back sh #f #f) (conn-phase (fake-shell-conn-state sh))
                        (last-actions sh 2) (ran? sh 'shutdown) (length (fake-shell-writes sh)))))
    (test-equal "a producer that raises at its first call: the head alone, then the bare close"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "" need-input)
                  closed ((disarm-deadline) (close handler-failed)))
                (let ((sh (serve default-limits (answering (producer-of '() (lambda () (raise 'boom)))) get11)))
                  (list (read-back sh #f #f) (conn-phase (fake-shell-conn-state sh)) (last-actions sh 2))))
    (test-equal "a producer that answers neither a bytevector nor the eof object fails the same way"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "hello" need-input)
                  closed ((disarm-deadline) (close handler-failed)))
                (let ((sh (serve default-limits (answering (producer-of '("hello") (lambda () 'done))) get11)))
                  (list (read-back sh #f #f) (conn-phase (fake-shell-conn-state sh)) (last-actions sh 2))))

    ;; --- the pieces ---
    ;; A chunk of no bytes would be the last chunk (RFC 9112 §7.1), and a
    ;; producer asked again at once for as long as it answers one would hold
    ;; the loop, every connection's, until it had something: an empty piece is
    ;; the producer failing, a bare close, and the producer is asked no more.
    (test-equal "a producer that answers an empty bytevector fails: a bare close after the pieces before it, the producer asked no more"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "x" need-input)
                  closed ((disarm-deadline) (close handler-failed)) 2)
                (let-values (((p calls) (counted (producer-of '("x") (lambda () (make-bytevector 0))))))
                  (let ((sh (serve default-limits (answering p) get11)))
                    (list (read-back sh #f #f) (conn-phase (fake-shell-conn-state sh))
                          (last-actions sh 2) (calls)))))
    ;; A write copies its segments as it is performed, as chez-libuv's does,
    ;; and each piece is written before the producer is asked
    ;; for the next, so a producer may hand out one bytevector again.
    (test-equal "a producer that hands out one bytevector again: each piece written as it was when handed over"
                `(200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "aaaabbbbcccc" complete)
                (read-back (serve default-limits (answering (refilled-producer 3 4)) get11) #f #f))

    ;; --- a stream among a connection's other answers ---
    ;; A response given instead of a reader is sent at once, the body unread,
    ;; and the connection closes after it.
    (test-equal "a producer answered instead of a reader: streamed with Connection: close, the body unread; the connection lingers after it"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked") ("Connection" . "close")) "streamed" complete)
                  (lingering unread-body))
                (let-values (((p calls) (texts-producer '("streamed"))))
                  (let ((sh (serve default-limits (answering p) post11)))
                    (list (read-back sh #f #f) (ended sh)))))
    (test-equal "a reader's response may be streamed: after the body, chunked, the connection kept"
                `((200 "OK" (,epoch-date ("Transfer-Encoding" . "chunked")) "got 0123456789" complete) (idle #f))
                (let ((sh (serve default-limits
                                 (lambda (request)
                                   (read-whole-body
                                    (lambda (body)
                                      (let-values (((p calls) (texts-producer (list "got " (utf8->string body)))))
                                        (make-response 200 #f '() p)))))
                                 post11)))
                  (list (read-back sh #f #f) (ended sh))))
    ;; One response at a time, so the GET behind the stream in the same read
    ;; waits for the stream's last chunk.
    (test-equal "a GET behind a stream in the same read is answered after the stream's last chunk"
                '((head piece piece end head) (idle #f))
                (let* ((asked 0)
                       (sh (serve default-limits
                                  (lambda (request)
                                    (set! asked (+ asked 1))
                                    (if (= asked 1)
                                        (let-values (((p calls) (texts-producer '("a" "b")))) (make-response 200 #f '() p))
                                        (make-response 200 #f '() (b "second"))))
                                  two-gets)))
                  (list (map classify (fake-shell-writes sh)) (ended sh))))

    ;; --- a stream the connection lets go ---
    ;; Under a high water of 1,000, the first turn asks nine times: the head
    ;; is 84 bytes, and each piece's write 106, so the ninth takes the bytes
    ;; outstanding to 1,038, past it.  None of those writes completes here.
    (test-equal "a transport failure mid-stream closes, and the producer, let go, is asked no more"
                '(9 9 closed #f)
                (let-values (((p calls) (counted (sized-producer 30 100))))
                  (let* ((sh (begun (waters 1000 300) (answering p) get11)) (before (calls)))
                    (fake-shell-deliver! sh '(read-error EPIPE))
                    (fake-shell-settle! sh)
                    (list before (calls) (conn-phase (fake-shell-conn-state sh))
                          (conn-producer (fake-shell-conn-state sh))))))
    ;; The write deadline, 60 s per completion: a client that reads nothing is
    ;; closed at it, as for any response, the close logged with the bytes
    ;; still outstanding.
    (test-equal "a stream whose writes never complete closes at the write deadline, logged with the bytes outstanding; the producer is asked no more"
                '(9 ((log write-timeout 1038) (disarm-deadline) (close write-timeout)) closed #f)
                (let-values (((p calls) (counted (sized-producer 30 100))))
                  (let ((sh (begun (waters 1000 300) (answering p) get11)))
                    (fake-shell-advance! sh 60000)
                    (fake-shell-fire! sh)
                    (let ((closing (last-actions sh 3)))
                      (fake-shell-settle! sh)
                      (list (calls) closing (conn-phase (fake-shell-conn-state sh))
                            (conn-producer (fake-shell-conn-state sh)))))))))
