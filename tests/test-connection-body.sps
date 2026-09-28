#!r6rs
;;; (http-server connection): reading a request's body, through the fake
;;; shell's message loop.  M6.1.
;;;
;;; Decision 0013, with chez-httparse driving the core through the adapter:
;;; a request whose framing announces a body is handed to the handler once
;;; the feed that completed its head has returned, and the handler answers
;;; with a response or a reader.  A streaming reader (`read-body`) is handed
;;; each piece as the parser meets it, then its end; a whole one
;;; (`read-whole-body`) is handed the body as one piece at the end.  A
;;; response given instead is sent at once, and the connection closes after
;;; it.  A body past a cap is answered 413.
;;;
;;; Each row runs at every delivery size, from a byte at a time to the
;;; whole input in one delivery, so one expected answer is also the
;;; outcome's independence from how the bytes were split (design §8.1's
;;; second property).  The pieces a reader is handed are joined in the
;;; outcome: how the body divides into pieces is the reads', not the core's.
;;;
;;; Oracles: decision 0013 items 1 to 7; the inputs' own bytes (a 10-byte
;;; body; a chunked one of 3 and 2 bytes); design §6.5's 413 and 500; the
;;; staged close of decision 0011.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server span) (http-server limits) (http-server body) (fake-shell))

(define (b s) (string->utf8 s))

(define ok (make-response 200 #f '() #f))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) sub) (loop (+ i 1)))))))

;; text : Bytevector Nat Nat -> String
(define (text bv from to)
  (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) (utf8->string o)))

;; render-request : Request -> Datum — the method and target.
(define (render-request r)
  (list (request-method r) (utf8->string (span->bytevector (request-target r)))))

;; decisive : (Listof Action) -> (Listof Datum)
;; The handlers asked, the pieces handed over joined into one text between
;; two other actions, each reader's end, and the responses written by status.
(define (decisive actions)
  (let loop ((as actions) (acc '()))
    (if (null? as)
        (reverse acc)
        (let ((a (car as)))
          (case (car a)
            ((call-handler) (loop (cdr as) (cons (list 'call-handler (render-request (cadr a))) acc)))
            ((deliver-body)
             (let ((piece (text (cadr a) (caddr a) (cadddr a))))
               (if (and (pair? acc) (eq? (car (car acc)) 'body))
                   (loop (cdr as) (cons (list 'body (string-append (cadr (car acc)) piece)) (cdr acc)))
                   (loop (cdr as) (cons (list 'body piece) acc)))))
            ((deliver-body-end) (loop (cdr as) (cons '(end) acc)))
            ((write) (loop (cdr as) (cons (list 'write (written-status a)) acc)))
            (else (loop (cdr as) acc)))))))

;; run : Bytevector Nat Limits (Request -> Any) -> FakeShell
;; One connection reading `input` in `size`-byte deliveries.
(define (run input size limits handler)
  (let ((sh (make-fake-connection limits handler)))
    (fake-shell-feed-input! sh input size)
    sh))

;; outcome : FakeShell -> Datum
;; What the connection did, and the phase and close-after it ended with.
(define (outcome sh)
  (let ((s (fake-shell-conn-state sh)))
    (list (decisive (fake-shell-actions sh)) (conn-phase s) (conn-close-after s))))

;; every-size : Bytevector Limits (-> (values (Request -> Any) Probe))
;;              (FakeShell Probe -> Datum) -> (Listof Datum)
;; The distinct answers of `view` over every delivery size, each run with a
;; fresh handler from `make`, which also gives a probe of what that handler
;; saw, for `view`.
(define (every-size input limits make view)
  (let loop ((size 1) (seen '()))
    (if (> size (bytevector-length input))
        (reverse seen)
        (let-values (((handler probe) (make)))
          (let ((o (view (run input size limits handler) probe)))
            (loop (+ size 1) (if (member o seen) seen (cons o seen))))))))

;; plain : (Request -> Any) -> (-> (values (Request -> Any) #f)) — no probe.
(define (plain handler) (lambda () (values handler #f)))

;; seen-by : (FakeShell -> Datum) -> (FakeShell Probe -> Datum) — a view
;; that does not read the probe.
(define (seen-by view) (lambda (sh probe) (view sh)))

;; probed : FakeShell Probe -> Datum — what the handler saw.
(define (probed sh probe) (probe))

;; --- the handlers -------------------------------------------------------------

;; streaming : -> (values (Request -> Any) (-> (Listof String)))
;; A handler that streams every body, and what its readers were handed, in
;; order, a piece's text each, with 'end at each end.
(define (streaming)
  (let ((read '()))
    (values (lambda (request)
              (read-body (lambda (bv from to) (set! read (cons (text bv from to) read)))
                         (lambda () (set! read (cons 'end read)) ok)))
            (lambda () (reverse read)))))

;; whole : [(U Nat #f)] -> (values (Request -> Any) (-> (Listof Any)))
;; A handler that reads every body whole, and each body its procedure got,
;; as text, with the length of the bytevector it came in.
(define (whole . cap)
  (let ((got '()))
    (values (lambda (request)
              (apply read-whole-body
                     (lambda (body)
                       (set! got (cons (list (utf8->string body) (bytevector-length body)) got))
                       ok)
                     cap))
            (lambda () (reverse got)))))

;; --- a reader on credit (M6.2) --------------------------------------------------

;; granting : -> (values (Request -> Any) (-> Datum) (-> Nat))
;; A handler that streams every body, for a connection that hands its
;; readers their pieces on credit; what its readers were handed, as the
;; pieces' texts joined, each end, and the most bytes they held uncredited at
;; once; and `take!`, the bytes handed since it was last called, which the
;; driver credits.
(define (granting)
  (let ((read '()) (held 0) (most 0))
    (values (lambda (request)
              (read-body (lambda (bv from to)
                           (set! read (cons (text bv from to) read))
                           (set! held (+ held (- to from)))
                           (set! most (max most held)))
                         (lambda () (set! read (cons 'end read)) ok)))
            (lambda ()
              (let ((read (reverse read)))
                (list (apply string-append (filter string? read)) (filter symbol? read) most)))
            (lambda () (let ((n held)) (set! held 0) n)))))

;; The most credits one run gives: a count, so a core that never stops
;; waiting fails rather than hangs (global-constraints: cap by count).
(define credit-cap 1000)

;; feed-crediting : FakeShell Bytevector Nat (-> Nat) -> (Listof (U Nat 'refused))
;; Deliver `input` in `size`-byte deliveries while the connection reads, as
;; fake-shell-feed-input! does; each time it waits for its reader's credit,
;; credit what the reader was handed since the last credit, `(take!)`.  The
;; credits given, in order; a credit the core refuses, an assertion
;; violation of its own, ends them as 'refused.
(define (feed-crediting sh input size take!)
  (let ((len (bytevector-length input)))
    (let loop ((from 0) (credits '()) (n 0))
      (fake-shell-settle! sh)
      (cond
       ((and (< from len) (fake-shell-reading? sh))
        (let ((to (min len (+ from size))))
          (fake-shell-deliver! sh (list 'bytes-arrived input from to))
          (loop to credits n)))
       ((and (eq? (conn-phase (fake-shell-conn-state sh)) 'awaiting-credit) (< n credit-cap))
        (let ((credit (take!)))
          (if (credited? sh credit)
              (loop from (cons credit credits) (+ n 1))
              (reverse (cons 'refused credits)))))
       (else (reverse credits))))))

;; credited? : FakeShell Nat -> Boolean
;; Credit the connection's reader with `n` bytes: #f if the core refuses it.
(define (credited? sh n)
  (guard (e ((assertion-violation? e) #f))
    (fake-shell-deliver! sh (list 'body-credit n))
    #t))

;; every-size/crediting : Bytevector Limits (-> (values Handler Probe Take))
;;                        (FakeShell Probe (Listof Nat) Nat -> Datum) -> (Listof Datum)
;; every-size, on a connection that hands its readers their pieces on
;; credit, the reader's credit given as feed-crediting gives it; the view
;; also reads the credits and the delivery size.
(define (every-size/crediting input limits make view)
  (let loop ((size 1) (seen '()))
    (if (> size (bytevector-length input))
        (reverse seen)
        (let-values (((handler probe take!) (make)))
          (let* ((sh (make-fake-connection limits handler #f 0 #t))
                 (credits (feed-crediting sh input size take!))
                 (o (view sh probe credits size)))
            (loop (+ size 1) (if (member o seen) seen (cons o seen))))))))

;; held-one-read : FakeShell Probe (Listof Nat) Nat -> Datum
;; What the connection did, what its readers were handed, and whether each
;; held at most one read's bytes uncredited, and every credit was of one
;; read's, with every action run from the outermost drain.
(define (held-one-read sh probe credits size)
  (let ((seen (probe)))
    (list (outcome sh)
          (list (car seen) (cadr seen))
          (<= (caddr seen) size)
          (for-all (lambda (n) (and (number? n) (<= 1 n size))) credits)
          (fake-shell-violations sh))))

;; --- the inputs --------------------------------------------------------------

(define post-a "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789")
(define chunked-a (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                 "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"))
(define get-b "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")

;; A POST with a 10-byte body and a GET behind it, and the same POST chunked.
(define post-then-get (b (string-append post-a get-b)))
(define chunked-then-get (b (string-append chunked-a get-b)))

(define (capped n) (limits-with default-limits (list (cons 'max-body-bytes n))))

(run-suite "connection-body"
  (lambda ()
    ;; --- a streaming reader (decision 0013 items 1 to 3) -------------------------
    ;; Asked once the head is in, before any piece; handed each piece as the
    ;; parser meets it, the ones met before it answered first; then its end.
    ;; Its response is written, and the connection serves the GET behind.
    ;; The handler answers the GET behind with a reader too, which is handed
    ;; its end at once (item 6).
    (test-equal "a streaming reader, every delivery size: asked at the head, handed the body, then its end; the GET behind served"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size post-then-get default-limits streaming (seen-by outcome)))
    (test-equal "chunked: the chunks' bytes, their framing removed"
                '((((call-handler (POST "/a")) (body "abcde") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size chunked-then-get default-limits streaming (seen-by outcome)))
    (test-equal "what the readers were handed, every delivery size: the body's bytes in order, then each one's end"
                '(("0123456789" (end end)))
                (every-size post-then-get default-limits streaming
                            (lambda (sh probe)
                              (let ((read (probe)))
                                (list (apply string-append (filter string? read))
                                      (filter symbol? read))))))

    ;; --- a whole reader (items 2 and 5) --------------------------------------------
    ;; Handed the body once, as one piece at the end, in a bytevector of the
    ;; declared length; chunked, the chunks joined into one.
    (test-equal "a whole reader, every delivery size: the body as one piece, then its end; the GET behind served"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size post-then-get default-limits whole (seen-by outcome)))
    (test-equal "its procedure gets the body in a bytevector of the declared length; the GET's, an empty one"
                '((("0123456789" 10) ("" 0)))
                (every-size post-then-get default-limits whole probed))
    (test-equal "chunked: one piece, the chunks joined"
                '((("abcde" 5) ("" 0)))
                (every-size chunked-then-get default-limits whole probed))
    (test-equal "one deliver-body for the whole body, whatever the reads"
                '(1)
                (every-size post-then-get default-limits whole
                            (seen-by (lambda (sh) (length (filter (lambda (a) (eq? (car a) 'deliver-body))
                                                                  (fake-shell-actions sh)))))))

    ;; --- a request with no body (item 6) ----------------------------------------------
    (test-equal "a reader answered for a request with no body: its end at once, and the connection kept"
                '((((call-handler (GET "/b")) (end) (write 200)) idle #f))
                (every-size (b get-b) default-limits whole (seen-by outcome)))

    ;; --- a response given instead of a reader (item 4) --------------------------------
    ;; Sent at once, and the connection closes after it, in stages: no piece
    ;; is handed over, and the GET behind is never served, however much of
    ;; the body arrived with the head.
    (test-equal "a response instead of a reader, every delivery size: written at once, then the staged close, unread-body"
                '((((call-handler (POST "/a")) (write 200)) lingering unread-body))
                (every-size post-then-get default-limits (plain (lambda (request) ok)) (seen-by outcome)))
    (test-equal "the response says so: Connection: close"
                '(#t)
                (every-size post-then-get default-limits (plain (lambda (request) ok))
                            (seen-by (lambda (sh)
                                       (let ((w (car (filter (lambda (a) (eq? (car a) 'write))
                                                             (fake-shell-actions sh)))))
                                         (contains? (apply string-append
                                                           (map (lambda (seg) (if (bytevector? seg) (utf8->string seg) ""))
                                                                (cadr w)))
                                                    "Connection: close\r\n"))))))

    ;; --- caps (item 5) --------------------------------------------------------------
    ;; The limits' max-body-bytes caps every body: a declared length past it
    ;; is answered 413 before the handler is asked, and a chunked body at
    ;; the piece that passes it.  A whole reader's own cap likewise, its
    ;; procedure never called.  Every 413 closes, in stages.
    (test-equal "max-body-bytes 5, a declared 10: 413 before the handler is asked, every delivery size"
                '((((write 413)) lingering body-too-large))
                (every-size post-then-get (capped 5) streaming (seen-by outcome)))
    ;; The handler is asked before anything the body brings is answered, and
    ;; a piece that passes the cap is handed over up to it: the reader is
    ;; handed exactly the cap's bytes, then 413, whatever the reads.
    (test-equal "max-body-bytes 4, a chunked 5: the reader handed the first 4 bytes, then 413, every delivery size"
                '((((call-handler (POST "/a")) (body "abcd") (write 413)) lingering body-too-large))
                (every-size chunked-then-get (capped 4) streaming (seen-by outcome)))
    (test-equal "…and what the reader was handed, every delivery size: those 4 bytes, and no end"
                '(("abcd" ()))
                (every-size chunked-then-get (capped 4) streaming
                            (lambda (sh probe)
                              (let ((read (probe)))
                                (list (apply string-append (filter string? read)) (filter symbol? read))))))
    (test-equal "a whole reader capped at 5, a declared 10: 413 when it answers, and its procedure never called"
                '(((((call-handler (POST "/a")) (write 413)) lingering body-too-large) ()))
                (every-size post-then-get default-limits (lambda () (whole 5))
                            (lambda (sh probe) (list (outcome sh) (probe)))))
    ;; Refused when it answers, the body is never fed: a byte at a time, the
    ;; parser is fed the head alone, and what arrives after is dropped.
    (test-equal "…a byte at a time, the parser is fed the head alone"
                (- (bytevector-length (b post-a)) 10)
                (let ((sh (run (b post-a) 1 default-limits (let-values (((h got) (whole 5))) h))))
                  (fold-left (lambda (n a) (if (eq? (car a) 'feed-parser) (+ n (- (cadddr a) (caddr a))) n))
                             0 (fake-shell-actions sh))))
    (test-equal "a whole reader capped at 4, a chunked 5: 413, and its procedure never called, every delivery size"
                '(((((call-handler (POST "/a")) (write 413)) lingering body-too-large) ()))
                (every-size chunked-then-get default-limits (lambda () (whole 4))
                            (lambda (sh probe) (list (outcome sh) (probe)))))

    ;; --- an error the body brings, whatever the reads -------------------------------
    ;; A chunk size of `zz` is the parser's error.  The feed that completes
    ;; the head may meet it before the handler is asked, or a later one after:
    ;; either way the handler is asked first, and a reader is handed the
    ;; pieces before the error, then 400; a response is sent, and the body is
    ;; not read, so the error is not met (design §8.1's second property).
    (let ((malformed (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                       "3\r\nabc\r\nzz\r\n"))))
      (test-equal "a malformed chunked body, read by a reader, every delivery size: the pieces before the error, then 400"
                  '((((call-handler (POST "/a")) (body "abc") (write 400)) lingering parser-error))
                  (every-size malformed default-limits streaming (seen-by outcome)))
      (test-equal "…and what the reader was handed, every delivery size: the pieces before the error, and no end"
                  '(("abc" ()))
                  (every-size malformed default-limits streaming
                              (lambda (sh probe)
                                (let ((read (probe)))
                                  (list (apply string-append (filter string? read)) (filter symbol? read))))))
      (test-equal "and answered with a response instead, every delivery size: the response, then the staged close"
                  '((((call-handler (POST "/a")) (write 200)) lingering unread-body))
                  (every-size malformed default-limits (plain (lambda (request) ok)) (seen-by outcome))))

    ;; --- a handler or a reader that raises (item 7) ---------------------------------
    (test-equal "a handler that raises at the head: 500, then the staged close, every delivery size"
                '((((call-handler (POST "/a")) (write 500)) lingering handler-failed))
                (every-size post-then-get default-limits
                            (plain (lambda (request) (raise 'boom))) (seen-by outcome)))
    ;; Chunked, two chunks: a read can bring both pieces, the second asked for
    ;; before the first is handed over, and it never reaches the reader.
    (test-equal "a reader that raises at its first piece, every delivery size: 500, the staged close, and no piece after it"
                '(((write 500) lingering handler-failed 1))
                (every-size chunked-then-get default-limits
                            (lambda ()
                              (let ((calls 0))
                                (values (lambda (request)
                                          (read-body (lambda (bv from to) (set! calls (+ calls 1)) (raise 'boom))
                                                     (lambda () ok)))
                                        (lambda () calls))))
                            (lambda (sh probe)
                              (let ((o (outcome sh)))
                                (list (let ((writes (filter (lambda (d) (eq? (car d) 'write)) (car o))))
                                        (if (= (length writes) 1) (car writes) writes))
                                      (cadr o) (caddr o) (probe))))))
    (test-equal "a reader whose end raises: 500, then the staged close, every delivery size"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 500)) lingering handler-failed))
                (every-size post-then-get default-limits
                            (plain (lambda (request) (read-body (lambda (bv from to) #t)
                                                                (lambda () (raise 'boom)))))
                            (seen-by outcome)))

    ;; --- what a whole reader's buffer holds (M6.1's review) -------------------------
    ;; A declared length is the client's word: the core buffers nothing before
    ;; the body's bytes arrive, then never more than twice what has arrived,
    ;; and hands the body over in the buffer it grew in, exactly its length.
    (let* ((declared 65536)
           (head (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: "
                                   (number->string declared) "\r\n\r\n")))
           (piece (make-bytevector 1000 97))
           (sh (make-fake-connection default-limits
                                     (lambda (request) (read-whole-body (lambda (body) ok) #f)))))
      (fake-shell-deliver! sh (list 'bytes-arrived head 0 (bytevector-length head)))
      (let ((before (conn-body-buffered (fake-shell-conn-state sh))))
        (let loop ((arrived 0) (over '()))
          (if (< arrived declared)
              (let ((n (min 1000 (- declared arrived))))
                (fake-shell-deliver! sh (list 'bytes-arrived piece 0 n))
                (let ((buffered (conn-body-buffered (fake-shell-conn-state sh))))
                  (loop (+ arrived n) (if (> buffered (* 2 (+ arrived n)))
                                          (cons (list (+ arrived n) buffered) over)
                                          over))))
              (let ((handed (filter (lambda (a) (eq? (car a) 'deliver-body)) (fake-shell-actions sh))))
                (test-equal "a whole reader of a declared 64 KiB: nothing buffered before its bytes arrive, then never more than twice what has"
                            '(0 ())
                            (list before over))
                (test-equal "…and its body handed over once, in the buffer it grew in, exactly the declared length"
                            (list (list declared 0 declared))
                            (map (lambda (a) (list (bytevector-length (cadr a)) (caddr a) (cadddr a)))
                                 handed)))))))

    ;; Refused mid-body, the whole reader's buffer goes with the 413, while its
    ;; write is outstanding: only the reader is kept, for the pieces already
    ;; asked for.
    (let* ((sh (make-fake-connection default-limits
                                     (lambda (request) (read-whole-body (lambda (body) ok) 4096))))
           (chunk (lambda (n) (b (string-append (number->string n 16) "\r\n" (make-string n #\a) "\r\n"))))
           (send (lambda (bv) (fake-shell-deliver! sh (list 'bytes-arrived bv 0 (bytevector-length bv))))))
      (send (b "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"))
      (send (chunk 3000))
      (let ((reading (conn-body-buffered (fake-shell-conn-state sh))))
        (send (chunk 2000))
        (let ((s (fake-shell-conn-state sh)))
          (test-equal "a whole reader capped at 4,096 past its cap mid-body: 3,000 bytes buffered, then the 413's write outstanding and nothing buffered"
                      '(3000 responding body-too-large 1 0)
                      (list reading (conn-phase s) (conn-close-after s) (conn-outstanding s)
                            (conn-body-buffered s))))))

    ;; --- what the core keeps --------------------------------------------------------
    (test-equal "once the reader's response is written, the core holds no reader"
                '(#f)
                (every-size (b post-a) default-limits streaming
                            (seen-by (lambda (sh) (conn-body-reader (fake-shell-conn-state sh))))))

    ;; --- run to completion (design §4.5) --------------------------------------------
    (test-equal "every action ran from the outermost drain, at every delivery size"
                '(())
                (every-size chunked-then-get default-limits streaming (seen-by fake-shell-violations)))

    ;; --- backpressure: a reader on credit (M6.2) ------------------------------------
    ;; On a connection that hands its readers their pieces on credit, as M7's
    ;; coroutine shell will: once a read's pieces are handed to the reader,
    ;; reading waits for its credit, so it holds at most one read; given the
    ;; credit, reading goes on.  The pieces the read that ends the message
    ;; brings are handed over with its end, and need no credit: reading waits
    ;; for the response then.
    (test-equal "a reader on credit, every delivery size: the body in order, then its end, never more than one read held uncredited; the GET behind served"
                '(((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                     (call-handler (GET "/b")) (end) (write 200))
                    idle #f)
                   ("0123456789" (end end)) #t #t ()))
                (every-size/crediting post-then-get default-limits granting held-one-read))
    (test-equal "chunked: the chunks' bytes, one read at most held uncredited"
                '(((((call-handler (POST "/a")) (body "abcde") (end) (write 200)
                     (call-handler (GET "/b")) (end) (write 200))
                    idle #f)
                   ("abcde" (end end)) #t #t ()))
                (every-size/crediting chunked-then-get default-limits granting held-one-read))

    ;; The refusal, not the wait: a body the parser refuses, or one past a
    ;; cap, is answered with its status though the reader owes credit for
    ;; the pieces before it, whatever the reads.
    (let ((malformed (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                                       "3\r\nabc\r\nzz\r\n")))
          (refused (lambda (sh probe credits size)
                     (let ((seen (probe))) (list (outcome sh) (car seen) (cadr seen))))))
      (test-equal "a reader on credit, a malformed chunked body, every delivery size: the pieces before the error, then 400, and no end"
                  '(((((call-handler (POST "/a")) (body "abc") (write 400)) lingering parser-error) "abc" ()))
                  (every-size/crediting malformed default-limits granting refused))
      (test-equal "a reader on credit, max-body-bytes 4, a chunked 5, every delivery size: the first 4 bytes, then 413, and no end"
                  '(((((call-handler (POST "/a")) (body "abcd") (write 413)) lingering body-too-large) "abcd" ()))
                  (every-size/crediting chunked-then-get (capped 4) granting refused)))

    ;; A reader answered with no word of credit, as v1's shells answer every
    ;; one, takes each piece as it is handed over and never makes reading
    ;; wait: reading stops only at each message's end (decision 0004's
    ;; pause), whatever the reads.
    (test-equal "a reader answered with no word of credit never makes reading wait: two read-stops, one per message, every delivery size"
                '(2)
                (every-size post-then-get default-limits streaming
                            (seen-by (lambda (sh)
                                       (length (filter (lambda (a) (eq? (car a) 'read-stop))
                                                       (fake-shell-actions sh)))))))

    ;; While the reader withholds its credit the server is the one waiting,
    ;; so the body deadline does not run (plan §14's note of 2026-09-27): a
    ;; timer firing past it ticks nothing.  Given the credit, reading starts
    ;; and the deadline is armed again, and a client that then sends nothing
    ;; is answered 408 once it passes.
    (let-values (((handler probe take!) (granting)))
      (let* ((sh (make-fake-connection default-limits handler #f 0 #t))
             (head+3 (b "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n012"))
             (body-ms (limits-deadline-ms default-limits 'body)))
        (fake-shell-deliver! sh (list 'bytes-arrived head+3 0 (bytevector-length head+3)))
        (let* ((waiting (list (conn-phase (fake-shell-conn-state sh)) (fake-shell-reading? sh)))
               (ticks (lambda () (length (filter (lambda (e) (eq? (car e) 'tick)) (fake-shell-events sh)))))
               (fired (begin (fake-shell-advance! sh (+ body-ms 1)) (fake-shell-fire! sh) (ticks)))
               (after (list (conn-phase (fake-shell-conn-state sh)) (length (fake-shell-writes sh))))
               (credited (and (credited? sh (take!))
                              (list (conn-phase (fake-shell-conn-state sh)) (fake-shell-reading? sh))))
               (stalled (begin (fake-shell-advance! sh (+ body-ms 1)) (fake-shell-fire! sh))))
          (test-equal "a reader on credit withholding it past the body deadline: reading stopped, nothing ticked, nothing written; credited, reading starts and the deadline runs again, 408 once it passes"
                      '((awaiting-credit #f) 0 (awaiting-credit 0) (body #t) (408))
                      (list waiting fired after credited
                            (map written-status (filter (lambda (a) (eq? (car a) 'write)) stalled)))))))))
