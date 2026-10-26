#!r6rs
;;; A body pulled by the handler that waits, through the fake shell's message
;;; loop: (http-server connection)'s rows for it, and (http-server private
;;; waits)' `next-body-piece` and `body-input-port`.
;;;
;;; With chez-httparse driving the core through the adapter, a handler that
;;; answers `awaiting` may pull its request's body from its thunk, before it
;;; answers: each call answers the next piece, a bytevector of a byte or more
;;; the caller owns, or the eof object at the end, and again after it.  The
;;; first call pulls the body, so a client that waits for `100 Continue` is
;;; sent it then.  Reading waits for the pull to take what it was handed.  A
;;; cap of its own, given to the first call, is checked as a reader's is.  A
;;; body that fails while pulled raises `&body-failed`, after the pieces met
;;; before it, and again at every call after: let out, it is answered with
;;; its status; caught, the handler's answer is sent; either closes the
;;; connection after it.  An answer before the body's end is sent at once,
;;; and closes the connection after it.  Once the connection closes before
;;; the body's end, every call raises `&client-closed`.  A call with a piece
;;; or the end to answer answers it; one that must wait is a wait.
;;;
;;; Most rows run at every delivery size, from a byte at a time to the whole
;;; input in one delivery, so one expected answer is also the outcome's
;;; independence from how the bytes were split.  The pieces handed over are
;;; joined in the outcome: how the body divides into pieces is the reads'.
;;;
;;; Oracles: the inputs' own bytes (a 10-byte body; a chunked one of 3 and 2
;;; bytes; a trailer value of 20 bytes against a limit of 16; chunk
;;; extensions of 16,385 bytes against their fixed 16 KiB); RFC 9110 §10.1.1
;;; and §15.2.1 for the 100; the statuses 400, 408, 413 and 500 (RFC 9110
;;; §15.5.1, §15.5.9, §15.5.14, §15.6.1) and 431 (RFC 6585 §5); the body
;;; deadline's 60 s default; the staged close (RFC 9112 §9.6).
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits) (http-server body)
        (http-server awaiting)
        (only (http-server private waits)
              next-body-piece body-input-port await sleep-ms with-deadline)
        (only (http-server private scheduler) scheduler-invariant? scheduler-invariant-name)
        (fake-shell) (decisive) (only (read-back) send! client-close!))

(define (b s) (string->utf8 s))

(define ok (make-response 200 #f '() #f))

;; run : Bytevector Nat Limits (Request -> Any) [Nat] -> FakeShell
;; One connection reading `input` in `size`-byte deliveries; given `offset`,
;; each delivery a bytevector of its own (fake-shell-feed-input!).
(define (run input size limits handler . offset)
  (let ((sh (make-fake-connection limits handler)))
    (apply fake-shell-feed-input! sh input size offset)
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
  (at-sizes (let loop ((n (bytevector-length input)) (sizes '()))
              (if (zero? n) sizes (loop (- n 1) (cons n sizes))))
            input limits make view))

;; at-sizes : (Listof Nat) Bytevector Limits (-> (values (Request -> Any) Probe))
;;            (FakeShell Probe -> Datum) -> (Listof Datum)
;; The same over the delivery sizes `sizes` only, for an input too long to
;; run at every size.
(define (at-sizes sizes input limits make view)
  (let loop ((sizes sizes) (seen '()))
    (if (null? sizes)
        (reverse seen)
        (let-values (((handler probe) (make)))
          (let ((o (view (run input (car sizes) limits handler) probe)))
            (loop (cdr sizes) (if (member o seen) seen (cons o seen))))))))

;; seen-by : (FakeShell -> Datum) -> (FakeShell Probe -> Datum)
(define (seen-by view) (lambda (sh probe) (view sh)))

;; probed : FakeShell Probe -> Datum — what the handler saw.
(define (probed sh probe) (probe))

;; kinds : FakeShell -> Datum — the outcome with each piece's text dropped,
;; for a handler whose answer comes after a piece of a size the split sets.
(define (kinds sh)
  (let ((o (outcome sh)))
    (cons (map (lambda (d) (if (eq? (car d) 'body) '(body) d)) (car o)) (cdr o))))

;; closes? : FakeShell -> Boolean — whether the response says
;; `Connection: close`.
(define (closes? sh)
  (let ((ws (fake-shell-writes sh)))
    (and (pair? ws) (contains? (utf8->string (car (reverse ws))) "Connection: close"))))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) sub) (loop (+ i 1)))))))

;; caught : (-> Any) -> Datum
;; What a call raised, by kind, or 'returned: `(body-failed reason status)`,
;; `client-closed`, `deadline-passed`, `(assertion who)`, `(r1|r2|r5)`.
(define (caught thunk)
  (guard (e ((body-failed? e) (list 'body-failed (body-failed-reason e) (body-failed-status e)))
            ((client-closed? e) 'client-closed)
            ((deadline-passed? e) 'deadline-passed)
            ((scheduler-invariant? e) (list (scheduler-invariant-name e)))
            ((assertion-violation? e)
             (list 'assertion (and (who-condition? e) (condition-who e)))))
    (thunk)
    'returned))

;; drain : (-> (U Bytevector Eof)) -> (Listof Bytevector)
;; Every piece `pull` answers until the eof object.
(define (drain pull)
  (let loop ((acc '()))
    (let ((p (pull)))
      (if (eof-object? p) (reverse acc) (loop (cons p acc))))))

;; joined : (Listof Bytevector) -> String
(define (joined pieces) (apply string-append (map utf8->string pieces)))

;; --- the handlers -------------------------------------------------------------

;; pulling : [Cap] -> (values (Request -> Any) (-> (Listof Datum)))
;; A handler that waits and pulls every body, with `cap` given to each call
;; if given, and answers 200; for each request, the body's text, whether
;; every piece was a bytevector of a byte or more, and whether a call after
;; the end answered the eof object again.
(define (pulling . cap)
  (let ((seen '()))
    (values (lambda (request)
              (awaiting
               (lambda ()
                 (let* ((pieces (drain (lambda () (apply next-body-piece cap))))
                        (again (eof-object? (apply next-body-piece cap))))
                   (set! seen (cons (list (joined pieces)
                                          (for-all (lambda (p) (and (bytevector? p) (> (bytevector-length p) 0)))
                                                   pieces)
                                          again)
                                    seen))
                   ok))))
            (lambda () (reverse seen)))))

;; failing : Cap Boolean -> (values (Request -> Any) (-> (Listof Datum)))
;; A handler that pulls every body with `cap` and keeps what the pull
;; answered until it raised, and the raise, then a second call's raise; it
;; answers 200 if `catch?`, and else lets the first raise out.
(define (failing cap catch?)
  (let ((seen '()))
    (values (lambda (request)
              (awaiting
               (lambda ()
                 (let* ((pieces '())
                        (first (guard (e ((body-failed? e) e))
                                 (let loop ()
                                   (let ((p (if cap (next-body-piece cap) (next-body-piece))))
                                     (unless (eof-object? p)
                                       (set! pieces (cons p pieces))
                                       (loop))))
                                 #f)))
                   (set! seen (cons (list (joined (reverse pieces))
                                          (and first (list (body-failed-reason first) (body-failed-status first)))
                                          (caught (lambda () (if cap (next-body-piece cap) (next-body-piece)))))
                                    seen))
                   (cond ((not first) ok)
                         (catch? ok)
                         (else (raise first)))))))
            (lambda () (reverse seen)))))

;; first-piece : -> (values (Request -> Any) #f)
;; A handler that pulls one piece and answers, before the body's end.
(define (first-piece)
  (values (lambda (request) (awaiting (lambda () (next-body-piece) ok))) #f))

;; plain : (Request -> Any) -> (-> (values (Request -> Any) #f))
(define (plain handler) (lambda () (values handler #f)))

;; --- the inputs --------------------------------------------------------------

(define post-a "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789")
(define chunked-head "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
(define chunked-a (string-append chunked-head "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"))
(define get-b "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
(define expect-a "POST /a HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n")

(define post-then-get (b (string-append post-a get-b)))
(define chunked-then-get (b (string-append chunked-a get-b)))
(define malformed (b (string-append chunked-head "3\r\nabc\r\nzz\r\n")))

;; A chunked body of 3 bytes whose trailer's value is 20 bytes, past
;; `values-capped`'s 16; and one whose second chunk's extension name is
;; 16,385 bytes, past the 16 KiB a body's extensions may come to.  Each with
;; a GET behind it.
(define trailed
  (b (string-append chunked-head "3\r\nabc\r\n0\r\nX-T: " (make-string 20 #\v) "\r\n\r\n" get-b)))
(define values-capped (limits-with default-limits '((max-header-value-bytes . 16))))
(define extended
  (b (string-append chunked-head "3\r\nabc\r\n2;" (make-string 16385 #\e) "\r\nde\r\n0\r\n\r\n" get-b)))

(define (capped n) (limits-with default-limits (list (cons 'max-body-bytes n))))

(run-suite "connection-pull"
  (lambda ()
    ;; --- the body, pulled ----------------------------------------------------------
    ;; Asked once the head is in; its code pulls the body, handed each piece in
    ;; order, then its end; the handler's answer then comes, and the connection
    ;; serves the GET behind, whose pull ends at once: it has no body.
    (test-equal "a pulled body, every delivery size: asked at the head, handed the body, its end, then the answer; the GET behind served"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size post-then-get default-limits pulling (seen-by outcome)))
    (test-equal "chunked: the chunks' bytes, their framing removed"
                '((((call-handler (POST "/a")) (body "abcde") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size chunked-then-get default-limits pulling (seen-by outcome)))
    (test-equal "what the pull answered, every delivery size: the body in order, each piece a bytevector of a byte or more, then the eof object, and again after it; for the GET, the eof object at once"
                '((("0123456789" #t #t) ("" #t #t)))
                (every-size post-then-get default-limits pulling probed))
    (test-equal "chunked, the same"
                '((("abcde" #t #t) ("" #t #t)))
                (every-size chunked-then-get default-limits pulling probed))

    ;; The pull is the request's: the next request's reader is handed its own
    ;; body, as if no pull had come before it.
    (test-equal "a pulled body, then a body read by a reader, every delivery size: each handed its own"
                '(((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                     (call-handler (POST "/b")) (body "abcde") (end) (write 200))
                    idle #f)
                   ("abcde")))
                (every-size (b (string-append post-a "POST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nabcde"))
                            default-limits
                            (lambda ()
                              (let ((read '()))
                                (values (lambda (request)
                                          (if (equal? (render-request request) '(POST "/a"))
                                              (awaiting (lambda () (drain next-body-piece) ok))
                                              (read-body (lambda (bv from to) (set! read (cons (text bv from to) read)))
                                                         (lambda () ok))))
                                        (lambda () (list (apply string-append (reverse read)))))))
                            (lambda (sh probe) (list (outcome sh) (probe)))))

    ;; Reading waits for the pull: what the core hands it and it has not
    ;; taken is one read at most, and it takes all of a read's pieces before
    ;; reading starts again, whatever the reads.
    (test-equal "reading waits for the pull, every delivery size: handed at most one read untaken, every credit a read's at most and one a read, every action from the outermost drain"
                '((#t #t #t ()))
                (let loop ((size 1) (seen '()))
                  (if (> size (bytevector-length chunked-then-get))
                      (reverse seen)
                      (let-values (((handler probe) (pulling)))
                        (let* ((handed 0) (most 0) (credits '()) (reads 0) (fresh? #f)
                               (sh (make-fake-connection
                                    default-limits handler
                                    (lambda (kind datum)
                                      (cond ((and (eq? kind 'event) (eq? (car datum) 'bytes-arrived))
                                             (set! fresh? #t))
                                            ((and (eq? kind 'action) (eq? (car datum) 'deliver-body))
                                             (when fresh? (set! fresh? #f) (set! reads (+ reads 1)))
                                             (set! handed (+ handed (- (cadddr datum) (caddr datum))))
                                             (set! most (max most handed)))
                                            ((and (eq? kind 'event) (eq? (car datum) 'body-credit))
                                             (set! credits (cons (cadr datum) credits))
                                             (set! handed (- handed (cadr datum)))))))))
                          (fake-shell-feed-input! sh chunked-then-get size)
                          (let ((o (list (<= most size)
                                         (for-all (lambda (n) (<= 1 n size)) credits)
                                         (= (length credits) reads)
                                         (fake-shell-violations sh))))
                            (loop (+ size 1) (if (member o seen) seen (cons o seen)))))))))

    ;; A pull slow to take its pieces holds the read they came in: the
    ;; connection reads nothing more until it has taken them all.
    (let* ((resume #f) (took '())
           (sh (make-fake-connection
                default-limits
                (lambda (request)
                  (awaiting (lambda ()
                              (set! took (cons (utf8->string (next-body-piece)) took))
                              (await (lambda (r) (set! resume r)))
                              (set! took (cons (utf8->string (next-body-piece)) took))
                              (await (lambda (r) #f)))))))
           (read (b (string-append chunked-head "3\r\nabc\r\n2\r\nde\r\n"))))
      (fake-shell-deliver! sh (list 'bytes-arrived read 0 (bytevector-length read)))
      (fake-shell-settle! sh)
      (let ((holding (list (reverse took) (conn-phase (fake-shell-conn-state sh)) (fake-shell-reading? sh))))
        (when resume (resume #t))
        (fake-shell-schedule! sh)
        (test-equal "a pull holding one of a read's two pieces untaken: reading waits; taken, reading starts again"
                    '((("abc") awaiting-credit #f) (("abc" "de") body #t))
                    (list holding
                          (list (reverse took) (conn-phase (fake-shell-conn-state sh)) (fake-shell-reading? sh))))))

    ;; --- Expect: 100-continue ---------------------------------------------------------
    ;; The pull is pulling the body, so the 100 goes then, first, however
    ;; much of the body came with the head.
    (test-equal "expecting 100-continue, pulled, every delivery size: the 100 first, then the body, its end and the answer"
                '((((call-handler (POST "/a")) (write 100) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (b (string-append expect-a "0123456789" get-b)) default-limits pulling (seen-by outcome)))
    (let* ((resume #f)
           (sh (make-fake-connection
                default-limits
                (lambda (request)
                  (awaiting (lambda ()
                              (await (lambda (r) (set! resume r)))
                              (drain next-body-piece)
                              ok))))))
      (send! sh expect-a)
      (let ((waiting (length (fake-shell-writes sh))))
        (when resume (resume #t))
        (fake-shell-schedule! sh)
        (test-equal "the 100 waits for the pull: none while the thunk waits on something else, then the 100 alone at its first call"
                    '(0 ("HTTP/1.1 100 Continue\r\n\r\n"))
                    (list waiting (map utf8->string (fake-shell-writes sh))))))
    (test-equal "answered without pulling, every delivery size: no 100, the answer at once, then the staged close"
                '((((call-handler (POST "/a")) (write 200)) lingering unread-body))
                (every-size (b (string-append expect-a "0123456789")) default-limits
                            (plain (lambda (request) (awaiting (lambda () ok))))
                            (seen-by outcome)))

    ;; --- an answer before the body's end --------------------------------------------
    ;; The client sends 7 of the body's 10 bytes, so the body never ends.
    (test-equal "an answer after the first piece, before the body's end, every delivery size: written at once, then the staged close, unread-body"
                '(((((call-handler (POST "/a")) (body) (write 200)) lingering unread-body) #t))
                (every-size (b (substring post-a 0 (- (string-length post-a) 3))) default-limits first-piece
                            (seen-by (lambda (sh) (list (kinds sh) (closes? sh))))))

    ;; --- the pull's cap -------------------------------------------------------------
    ;; A declared length past it is in the head: the first call raises, no
    ;; piece taken and no 100 sent.  Let out, 413; caught, the handler's
    ;; answer, closing; either way a second call raises again.
    (test-equal "a declared length past the pull's cap, the raise let out, every delivery size: no piece, the failure, 413, then the staged close"
                '((((call-handler (POST "/a")) (failed body-too-large 413) (write 413)) lingering body-too-large))
                (every-size post-then-get default-limits (lambda () (failing 4 #f)) (seen-by outcome)))
    (test-equal "what it raised, every delivery size: &body-failed body-too-large 413, and again at the next call"
                '((("" (body-too-large 413) (body-failed body-too-large 413))))
                (every-size post-then-get default-limits (lambda () (failing 4 #f)) probed))
    (test-equal "the raise caught, every delivery size: the handler's answer, saying Connection: close, then the staged close"
                '(((((call-handler (POST "/a")) (failed body-too-large 413) (write 200)) lingering body-too-large) #t))
                (every-size post-then-get default-limits (lambda () (failing 4 #t))
                            (seen-by (lambda (sh) (list (outcome sh) (closes? sh))))))
    (test-equal "expecting 100-continue, a declared length past the pull's cap, every delivery size: no 100"
                '((((call-handler (POST "/a")) (failed body-too-large 413) (write 413)) lingering body-too-large))
                (every-size (b (string-append expect-a "0123456789")) default-limits (lambda () (failing 4 #f))
                            (seen-by outcome)))
    ;; A counted body past it, chunked, is known as it passes: the bytes up
    ;; to the cap first, then the raise; the server's cap the same.
    (test-equal "chunked, 5 bytes past a pull's cap of 4, every delivery size: the first 4 bytes, then the failure, 413"
                '((((call-handler (POST "/a")) (body "abcd") (failed body-too-large 413) (write 413))
                   lingering body-too-large))
                (every-size chunked-then-get default-limits (lambda () (failing 4 #f)) (seen-by outcome)))
    (test-equal "what it took and raised, every delivery size: abcd, then body-too-large 413, twice"
                '((("abcd" (body-too-large 413) (body-failed body-too-large 413))))
                (every-size chunked-then-get default-limits (lambda () (failing 4 #f)) probed))
    (test-equal "the server's cap, 4, a pull of no cap of its own, every delivery size: the same"
                '((((call-handler (POST "/a")) (body "abcd") (failed body-too-large 413) (write 413))
                   lingering body-too-large))
                (every-size chunked-then-get (capped 4) (lambda () (failing #f #f)) (seen-by outcome)))

    ;; --- a malformed body ------------------------------------------------------------
    (test-equal "a malformed chunked body, pulled, the raise let out, every delivery size: the piece before the error, then the failure, 400"
                '((((call-handler (POST "/a")) (body "abc") (failed invalid-chunk-size 400) (write 400))
                   lingering parser-error))
                (every-size malformed default-limits (lambda () (failing #f #f)) (seen-by outcome)))
    (test-equal "the raise caught, every delivery size: the handler's answer, closing"
                '(((((call-handler (POST "/a")) (body "abc") (failed invalid-chunk-size 400) (write 200))
                    lingering parser-error) #t))
                (every-size malformed default-limits (lambda () (failing #f #t))
                            (seen-by (lambda (sh) (list (outcome sh) (closes? sh))))))

    ;; --- a trailer or the extensions past a limit ------------------------------------
    ;; Refused as a head's field is, and told to the pull as a cap passed is,
    ;; with the reason's status: met as it reads, or met in the head's feed
    ;; and kept for it.
    (test-equal "a trailer past a header limit, pulled, the raise let out, every delivery size: the body before it, then the failure, 431, then the staged close"
                '((((call-handler (POST "/a")) (body "abc") (failed header-value-too-large 431) (write 431))
                   lingering header-value-too-large))
                (every-size trailed values-capped (lambda () (failing #f #f)) (seen-by outcome)))
    (test-equal "what it took and raised, every delivery size: abc, then header-value-too-large 431, twice"
                '((("abc" (header-value-too-large 431) (body-failed header-value-too-large 431))))
                (every-size trailed values-capped (lambda () (failing #f #f)) probed))
    (test-equal "the raise caught, every delivery size: the handler's answer, closing"
                '(((((call-handler (POST "/a")) (body "abc") (failed header-value-too-large 431) (write 200))
                    lingering header-value-too-large) #t))
                (every-size trailed values-capped (lambda () (failing #f #t))
                            (seen-by (lambda (sh) (list (outcome sh) (closes? sh))))))
    (test-equal "chunk extensions past 16 KiB, pulled, the raise let out, a byte, 2, 3 and 4,096 at a time and whole: abc, then the failure, 413, twice, then the staged close"
                '(((((call-handler (POST "/a")) (body "abc") (failed chunk-extensions-too-large 413) (write 413))
                    lingering chunk-extensions-too-large)
                   (("abc" (chunk-extensions-too-large 413) (body-failed chunk-extensions-too-large 413)))))
                (at-sizes (list 1 2 3 4096 (bytevector-length extended)) extended default-limits
                          (lambda () (failing #f #f)) (lambda (sh probe) (list (outcome sh) (probe)))))

    ;; --- the body deadline -----------------------------------------------------------
    ;; The client stalls with the body unfinished: past the body deadline the
    ;; pull, parked, raises, and the handler answers.
    (let-values (((handler probe) (failing #f #f)))
      (let ((sh (make-fake-connection default-limits handler)))
        (send! sh (string-append (substring post-a 0 (- (string-length post-a) 7))))
        (fake-shell-advance! sh (+ (limits-deadline-ms default-limits 'body) 1))
        (fake-shell-fire! sh)
        (fake-shell-settle! sh)
        (test-equal "a pulled body stalled past the body deadline, the raise let out: the piece taken, the failure, 408, then the staged close"
                    '((((call-handler (POST "/a")) (body "012") (failed body-timeout 408) (write 408))
                       lingering body-timeout)
                      (("012" (body-timeout 408) (body-failed body-timeout 408))))
                    (list (outcome sh) (probe)))))

    ;; --- other raises ------------------------------------------------------------------
    (test-equal "a pulled body, the handler raising something else, every delivery size: 500"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 500)) lingering handler-failed))
                (every-size (b post-a) default-limits
                            (plain (lambda (request)
                                     (awaiting (lambda ()
                                                 (drain next-body-piece)
                                                 (raise (make-message-condition "the handler failed"))))))
                            (seen-by outcome)))

    ;; --- the client's close -----------------------------------------------------------
    ;; The connection closes before the body's end: the pull, parked, raises
    ;; &client-closed, and so does every call after it; nothing is answered.
    (let* ((seen '())
           (sh (make-fake-connection
                default-limits
                (lambda (request)
                  (awaiting (lambda ()
                              (set! seen (list (utf8->string (next-body-piece))
                                               (caught next-body-piece)
                                               (caught next-body-piece)))
                              ok))))))
      (send! sh (substring post-a 0 (- (string-length post-a) 7)))
      (client-close! sh)
      (fake-shell-settle! sh)
      (test-equal "the client's end before the body's: the piece taken, then &client-closed at the call parked and the next; nothing answered, the connection closed"
                  '(("012" client-closed client-closed) () closed)
                  (list seen (fake-shell-writes sh) (conn-phase (fake-shell-conn-state sh)))))

    ;; The connection closes, a read's error, while the handler waits on
    ;; something else: a pull it begins after raises &client-closed.
    (let* ((seen #f)
           (sh (make-fake-connection
                default-limits
                (lambda (request)
                  (awaiting (lambda ()
                              (guard (e ((client-closed? e) #f)) (await (lambda (r) #f)))
                              (set! seen (list (caught next-body-piece) (caught next-body-piece)))
                              ok))))))
      (send! sh post-a)
      (fake-shell-deliver! sh '(read-error ECONNRESET))
      (fake-shell-settle! sh)
      (test-equal "a pull begun once the connection has closed, the body whole in the core: &client-closed, and again"
                  '(client-closed client-closed)
                  seen))

    ;; --- where it may be called --------------------------------------------------------
    (test-equal "off a coroutine, the pull is refused as a wait is: R2"
                '((r2) (r2))
                (list (caught next-body-piece) (caught (lambda () (get-u8 (body-input-port))))))
    (let ((seen '()))
      (define (note! x) (set! seen (cons x seen)))
      (let ((sh (make-fake-connection
                 default-limits
                 (lambda (request)
                   (awaiting
                    (lambda ()
                      (note! (caught (lambda () (next-body-piece -1))))
                      (note! (caught (lambda () (next-body-piece 'all))))
                      (note! (utf8->string (next-body-piece 20)))
                      (note! (caught (lambda () (next-body-piece 30))))
                      (note! (caught (lambda () (next-body-piece #f))))
                      (note! (eof-object? (next-body-piece 20)))
                      ok))))))
        (send! sh post-a)
        (fake-shell-settle! sh)
        (test-equal "a cap that is no count is refused; a later call naming another cap than the first's is refused, #f among them"
                    '((assertion next-body-piece) (assertion next-body-piece) "0123456789"
                      (assertion next-body-piece) (assertion next-body-piece) #t)
                    (reverse seen))))
    (let ((seen '()))
      (let ((sh (make-fake-connection
                 default-limits
                 (lambda (request)
                   (awaiting
                    (lambda ()
                      (make-response 200 #f '()
                                     (let ((done #f))
                                       (lambda ()
                                         (set! seen (cons (caught next-body-piece) seen))
                                         (if done (eof-object) (begin (set! done #t) (b "x"))))))))))))
        (send! sh get-b)
        (fake-shell-settle! sh)
        (test-equal "a producer the thunk answers with may not pull: refused on its coroutine"
                    '((assertion next-body-piece) (assertion next-body-piece))
                    (reverse seen))))
    (let ((seen '()))
      (let ((sh (make-fake-connection
                 default-limits
                 (lambda (request)
                   (awaiting
                    (lambda ()
                      (read-body (lambda (bv from to) (set! seen (cons (caught next-body-piece) seen)))
                                 (lambda () ok))))))))
        (send! sh post-a)
        (fake-shell-settle! sh)
        (test-equal "a reader the thunk answers with may not pull: refused on its piece's coroutine"
                    '((assertion next-body-piece))
                    (list (car seen)))))

    ;; --- a wait where it waits ------------------------------------------------------------
    ;; Inside a deadline that has passed, a call with a piece to answer
    ;; answers it; one that must wait raises; outside it, the pull reads on,
    ;; losing nothing.
    (let* ((seen '())
           (sh (make-fake-connection
                default-limits
                (lambda (request)
                  (awaiting
                   (lambda ()
                     (set! seen (list (utf8->string (next-body-piece))))
                     (with-deadline 5
                       (lambda ()
                         (set! seen (cons (caught (lambda () (sleep-ms 10))) seen))
                         (set! seen (cons (utf8->string (next-body-piece)) seen))
                         (set! seen (cons (caught next-body-piece) seen))))
                     (set! seen (cons (eof-object? (next-body-piece)) seen))
                     ok))))))
      (send! sh (string-append chunked-head "3\r\nabc\r\n2\r\nde\r\n"))
      (fake-shell-advance! sh 10)
      (fake-shell-fire-waits! sh)
      (fake-shell-settle! sh)
      (send! sh "0\r\n\r\n")
      (fake-shell-settle! sh)
      (test-equal "a pull in a deadline that has passed: the piece held answered, the call that would wait raised; after it, the end"
                  '("abc" deadline-passed "de" deadline-passed #t)
                  (reverse seen)))

    ;; --- the pieces ---------------------------------------------------------------------
    ;; A piece that is all of one read is that read's bytevector, which
    ;; nothing else keeps; any other is a copy, sharing no memory with the
    ;; read it came in.  Each delivery here is a bytevector of its own.
    (test-equal "each piece is the read's own bytevector when it is all of it, and a copy otherwise, every delivery size: the body whole, a GET behind it"
                '((#t "0123456789"))
                (let loop ((size 1) (seen '()))
                  (if (> size (bytevector-length post-then-get))
                      (reverse seen)
                      (let* ((handed '()) (took '())
                             (sh (make-fake-connection
                                  default-limits
                                  (lambda (request)
                                    (awaiting (lambda ()
                                                (let ((pieces (drain next-body-piece)))
                                                  (when (null? took) (set! took pieces)))
                                                ok)))
                                  (lambda (kind datum)
                                    (when (and (eq? kind 'action) (eq? (car datum) 'deliver-body))
                                      (set! handed (cons (cdr datum) handed)))))))
                        (fake-shell-feed-input! sh post-then-get size 0)
                        (let ((o (list (and (= (length took) (length handed))
                                            (for-all (lambda (piece span)
                                                       (let ((whole? (and (= (cadr span) 0)
                                                                          (= (caddr span) (bytevector-length (car span))))))
                                                         (eq? whole? (eq? piece (car span)))))
                                                     took (reverse handed)))
                                       (joined took))))
                          (loop (+ size 1) (if (member o seen) seen (cons o seen))))))))

    ;; --- the port ---------------------------------------------------------------------------
    (let ((seen '()))
      (let ((sh (make-fake-connection
                 default-limits
                 (lambda (request)
                   (let ((port (body-input-port)))
                     (awaiting
                      (lambda ()
                        (set! seen (list (utf8->string (get-bytevector-all port)) (eof-object? (get-u8 port))))
                        ok)))))))
        (send! sh post-a)
        (fake-shell-settle! sh)
        (test-equal "a port made by the handler, read whole in its thunk: the body, then the eof object"
                    '("0123456789" #t)
                    seen)))
    (test-equal "a port read in pieces of 4 bytes, every delivery size: the body"
                '(("0123" "4567" "89"))
                (every-size post-then-get default-limits
                            (lambda ()
                              (let ((seen #f))
                                (values (lambda (request)
                                          (awaiting
                                           (lambda ()
                                             (let ((port (body-input-port)))
                                               (unless seen
                                                 (set! seen (let loop ((acc '()))
                                                              (let ((x (get-bytevector-n port 4)))
                                                                (if (eof-object? x)
                                                                    (map utf8->string (reverse acc))
                                                                    (loop (cons x acc))))))))
                                             ok)))
                                        (lambda () seen))))
                            probed))
    (test-equal "a text port over it, read a line at a time, every delivery size: the lines"
                '(("one" "two" "three"))
                (every-size (b (string-append chunked-head "4\r\none\n\r\n6\r\ntwo\nth\r\n3\r\nree\r\n0\r\n\r\n"))
                            default-limits
                            (lambda ()
                              (let ((seen #f))
                                (values (lambda (request)
                                          (awaiting
                                           (lambda ()
                                             (let ((port (transcoded-port (body-input-port)
                                                                          (make-transcoder (utf-8-codec)))))
                                               (set! seen (let loop ((acc '()))
                                                            (let ((l (get-line port)))
                                                              (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
                                             ok)))
                                        (lambda () seen))))
                            probed))
    (test-equal "a port with a cap of 4, chunked 5 bytes, every delivery size: the read raises &body-failed, and so does the next"
                '(((body-failed body-too-large 413) (body-failed body-too-large 413)))
                (every-size chunked-then-get default-limits
                            (lambda ()
                              (let ((seen #f))
                                (values (lambda (request)
                                          (awaiting
                                           (lambda ()
                                             (let ((port (body-input-port 4)))
                                               (unless seen
                                                 (set! seen (list (caught (lambda () (get-bytevector-all port)))
                                                                  (caught (lambda () (get-u8 port)))))))
                                             ok)))
                                        (lambda () seen))))
                            probed))))
