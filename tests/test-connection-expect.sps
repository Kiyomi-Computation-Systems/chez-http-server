#!r6rs
;;; (http-server connection): `Expect: 100-continue`, and what a chunked body
;;; carries beside its data, through the fake shell's message loop.  M6.4.
;;;
;;; With chez-httparse driving the core through the adapter.  A client that
;;; sends `Expect: 100-continue` with a head that announces a body is sent
;;; `100 Continue` when the handler answers with a reader, which is pulling
;;; the body (decision 0013's consequences), and not when it answers with a
;;; response, on HTTP/1.0, or for a request with no body (RFC 9110
;;; §10.1.1).  The 100 arms the body deadline.  A reader whose cap the
;;; declared length passes is answered 413 with no 100, as the head says;
;;; one whose cap the body met so far passes, after the 100, as it would be
;;; had the body come later.  A chunked body's trailer fields are held to
;;; the four header limits, counted afresh, and its chunk extensions to
;;; 16 KiB, all of a body's together (decided on the owner's word,
;;; 2026-09-29).
;;;
;;; Each row runs at every delivery size, from a byte at a time to the whole
;;; input in one delivery, so one expected answer is also the outcome's
;;; independence from how the bytes were split (design §8.1's second
;;; property).  The extensions' inputs, over 16 KiB, run at a sample of
;;; sizes.  The pieces a reader is handed are joined in the outcome.
;;;
;;; Oracles: RFC 9110 §10.1.1 and §15.2.1; decision 0013; the inputs' own
;;; bytes; the limits each row sets; design §6.5's 413 and 431 (RFC 6585
;;; §5's phrase); decision 0005's 60 s body deadline; decision 0011's staged
;;; close.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server request) (http-server response)
        (http-server span) (http-server limits) (http-server body)
        (fake-shell) (response-reader) (only (read-back) send!))

(define (b s) (string->utf8 s))

(define ok (make-response 200 #f '() #f))

;; text : Bytevector Nat Nat -> String
(define (text bv from to)
  (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) (utf8->string o)))

;; render-request : Request -> Datum — the method and target.
(define (render-request r)
  (list (request-method r) (utf8->string (span->bytevector (request-target r)))))

;; decisive : (Listof Action) -> (Listof Datum)
;; The handlers asked, the pieces handed over joined into one text between
;; two other actions, each reader's end, and the writes by status.
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

;; at-sizes : (Listof Nat) Bytevector Limits (Request -> Any) (FakeShell -> Datum)
;;            -> (Listof Datum)
;; The distinct answers of `view` over the delivery sizes `sizes`.
(define (at-sizes sizes input limits handler view)
  (fold-left (lambda (seen size)
               (let ((o (view (run input size limits handler))))
                 (if (member o seen) seen (append seen (list o)))))
             '() sizes))

;; every-size : Bytevector Limits (Request -> Any) (FakeShell -> Datum) -> (Listof Datum)
;; at-sizes over every size, from 1 to the input's length.
(define (every-size input limits handler view)
  (let loop ((size (bytevector-length input)) (sizes '()))
    (if (zero? size) (at-sizes sizes input limits handler view) (loop (- size 1) (cons size sizes)))))

;; sampled : Bytevector -> (Listof Nat)
;; Delivery sizes for an input too long to run at every size: small ones, a
;; few that fall across its framing, and the whole.
(define (sampled input)
  (append '(1 2 3 5 8 13 64 509 4096 16384) (list (bytevector-length input))))

;; The handlers: one that streams every body, one that reads it whole, one
;; that reads it whole within 4 bytes, one that answers at once, reading
;; nothing.
(define (streaming request) (read-body (lambda (bv from to) #t) (lambda () ok)))
(define (whole request) (read-whole-body (lambda (body) ok)))
(define (whole-within-4 request) (read-whole-body (lambda (body) ok) 4))
(define (answers request) ok)

;; --- the inputs --------------------------------------------------------------

(define get-b "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")

;; post : String String String -> Bytevector
;; A POST to /a on HTTP/1.`minor` with `fields` (each line CRLF-ended) and the
;; body `rest`, and the GET behind it.
(define (post minor fields rest)
  (b (string-append "POST /a HTTP/1." minor "\r\nHost: x\r\n" fields "\r\n" rest get-b)))

(define expect "Expect: 100-continue\r\n")
(define ten (string-append "Content-Length: 10\r\n"))
(define chunked "Transfer-Encoding: chunked\r\n")

;; The 100 as the client reads it: its status line and the blank line.
(define continue-wire "HTTP/1.1 100 Continue\r\n\r\n")

;; --- trailers: header limits small enough to fill ------------------------------
;; A field's name up to 17 bytes, Transfer-Encoding's, its value up to 8, 32
;; bytes in all and 3 fields, a value counting the whitespace before it (the
;; padding PR).  The head holds 31 bytes in 2 fields: Host, x,
;; Transfer-Encoding, chunked, and a space before each value.
(define small
  (limits-with default-limits
               '((max-header-field-bytes . 17) (max-header-value-bytes . 8)
                 (max-header-bytes . 32) (max-header-count . 3))))

;; trailed : String -> Bytevector
;; A chunked POST of "abc" whose trailer section is `trailers`, and the GET
;; behind it.
(define (trailed trailers)
  (post "1" chunked (string-append "3\r\nabc\r\n0\r\n" trailers "\r\n")))

;; Three trailer fields, 18, 9 and 5 bytes with their spaces: 32 in all, and
;; 3 fields, as much as `small` lets a section hold.
(define full-trailers "Trailer-One: 123456\r\nTw: 123456\r\nTh: 12\r\n")

;; --- extensions: 16 KiB of names and values, over two chunks -----------------
;; extended : Nat Nat -> Bytevector
;; A chunked POST of "abc" and "de", each chunk carrying one extension `e`
;; whose value is `n1` and `n2` bytes, and the GET behind it.
(define (extended n1 n2)
  (post "1" chunked
        (string-append "3;e=" (make-string n1 #\v) "\r\nabc\r\n"
                       "2;e=" (make-string n2 #\v) "\r\nde\r\n0\r\n\r\n")))

(run-suite "connection-expect"
  (lambda ()
    ;; --- Expect: 100-continue -----------------------------------------------------
    ;; The handler is asked at the head and answers with a reader, so the 100
    ;; goes first, whatever of the body came with the head: had the body come
    ;; later, the 100 would have gone before it, so the outcome is one.
    (test-equal "expecting 100-continue, read by a streaming reader, every delivery size: the 100 first, then the body, its end and the response; the GET behind served"
                '((((call-handler (POST "/a")) (write 100) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (post "1" (string-append expect ten) "0123456789") default-limits
                            streaming outcome))
    (test-equal "chunked, read whole, every delivery size: the 100 first, then the chunks as one piece"
                '((((call-handler (POST "/a")) (write 100) (body "abcde") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (post "1" (string-append expect chunked) "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
                            default-limits whole outcome))
    ;; The 100 is a write of its own, which a client reads as an interim
    ;; response, then the final one (RFC 9110 §15.2): chez-httparse's strict
    ;; response parser reads each.
    (test-equal "the 100 as the client reads it, every delivery size: a write of its own, the status line and the blank line, then the response"
                (list (list continue-wire '(100 "Continue" () "" complete) 200 200))
                (every-size (post "1" (string-append expect ten) "0123456789") default-limits streaming
                            (lambda (sh)
                              (let ((ws (fake-shell-writes sh)))
                                (cons (utf8->string (car ws))
                                      (cons (read-response (car ws) #f #f)
                                            (map (lambda (w) (car (read-response w #f #f))) (cdr ws))))))))
    ;; A response instead of a reader is sent at once, with no 100, and the
    ;; connection closes after it (decision 0013 item 4).
    (test-equal "answered with a response instead, every delivery size: no 100, the response at once, then the staged close"
                '((((call-handler (POST "/a")) (write 200)) lingering unread-body))
                (every-size (post "1" (string-append expect ten) "0123456789") default-limits
                            answers outcome))
    ;; RFC 9110 §10.1.1: HTTP/1.0's expectation is ignored, and so is one
    ;; with no body to wait for; any but 100-continue, on the owner's word.
    (test-equal "on HTTP/1.0, every delivery size: no 100; the body, the response, then the staged close"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)) lingering not-keep-alive))
                (every-size (post "0" (string-append expect ten) "0123456789") default-limits
                            streaming outcome))
    (test-equal "with no body, Content-Length: 0, every delivery size: no 100"
                '((((call-handler (POST "/a")) (end) (write 200) (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (post "1" (string-append expect "Content-Length: 0\r\n") "") default-limits
                            streaming outcome))
    (test-equal "another expectation, every delivery size: no 100, the request served as without it"
                '((((call-handler (POST "/a")) (body "0123456789") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (post "1" (string-append "Expect: 200-ok\r\n" ten) "0123456789") default-limits
                            streaming outcome))
    ;; A reader's cap: a declared length past it is in the head, so it is
    ;; answered 413 with no 100 whatever the split.  A body past it is known
    ;; only once met: had it come after the answer, the 100 would have gone
    ;; first, so it goes first when the body came with the head too.
    (test-equal "a declared length past the reader's cap, every delivery size: 413, no 100, then the staged close"
                '((((call-handler (POST "/a")) (write 413)) lingering body-too-large))
                (every-size (post "1" (string-append expect ten) "0123456789") default-limits
                            whole-within-4 outcome))
    (test-equal "a chunked body past the reader's cap, every delivery size: the 100, then 413 and the staged close"
                '((((call-handler (POST "/a")) (write 100) (write 413)) lingering body-too-large))
                (every-size (post "1" (string-append expect chunked) "a\r\nabcdefghij\r\n0\r\n\r\n")
                            default-limits whole-within-4 outcome))
    ;; The 100 arms the body deadline: a client that waits for it, then never
    ;; sends its body, is answered 408 once the deadline passes, a minute on
    ;; (decision 0005), and the connection closes, in stages.
    (let ((sh (make-fake-connection default-limits streaming)))
      (send! sh "POST /a HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n")
      (fake-shell-settle! sh)
      (let ((before (decisive (fake-shell-actions sh))))
        (fake-shell-advance! sh 59999)
        (fake-shell-fire! sh)
        (fake-shell-settle! sh)
        (let ((at-59999 (decisive (fake-shell-actions sh))))
          (fake-shell-advance! sh 1)
          (fake-shell-fire! sh)
          (fake-shell-settle! sh)
          (test-equal "a client that waits for the 100 and never sends its body: nothing more at 59,999 ms, 408 once the body deadline, armed with the 100, passes"
                      '(((call-handler (POST "/a")) (write 100))
                        ((call-handler (POST "/a")) (write 100))
                        (((call-handler (POST "/a")) (write 100) (write 408)) lingering body-timeout))
                      (list before at-59999 (outcome sh))))))

    ;; --- trailers --------------------------------------------------------------------
    ;; Counted afresh: the head's 31 bytes and 2 fields leave the trailers
    ;; the whole 32 and 3, so a section at the limits is served.
    (test-equal "trailers as large as a head may be, after a head near the limits, every delivery size: served"
                '((((call-handler (POST "/a")) (body "abc") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (every-size (trailed full-trailers) small streaming outcome))
    ;; One past a limit is answered 431, as a head would be, after the body
    ;; the reader was handed; the GET behind is never served.
    (test-equal "a trailer section a byte past max-header-bytes, every delivery size: 431, then the staged close"
                '((((call-handler (POST "/a")) (body "abc") (write 431)) lingering headers-too-large))
                (every-size (trailed "Trailer-One: 123456\r\nTw: 123456\r\nTh: 123\r\n") small
                            streaming outcome))
    (test-equal "a fourth trailer field, every delivery size: 431 for the count"
                '((((call-handler (POST "/a")) (body "abc") (write 431)) lingering too-many-headers))
                (every-size (trailed "A: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n") small streaming outcome))
    (test-equal "a trailer value a byte past max-header-value-bytes, every delivery size: 431"
                '((((call-handler (POST "/a")) (body "abc") (write 431)) lingering header-value-too-large))
                (every-size (trailed "T: 12345678\r\n") small streaming outcome))

    ;; --- chunk extensions ---------------------------------------------------------
    ;; Two extensions of 1 + 8,191 bytes each: 16,384 together, the most.
    (test-equal "a body's chunk extensions at 16 KiB, together over two chunks, sampled delivery sizes: served"
                '((((call-handler (POST "/a")) (body "abcde") (end) (write 200)
                    (call-handler (GET "/b")) (end) (write 200))
                   idle #f))
                (let ((input (extended 8191 8191)))
                  (at-sizes (sampled input) input default-limits streaming outcome)))
    ;; A byte more, in the second chunk's: the first chunk's data was handed
    ;; over, then 413.
    (test-equal "a byte more, sampled delivery sizes: the first chunk's data, then 413 and the staged close"
                '((((call-handler (POST "/a")) (body "abc") (write 413)) lingering chunk-extensions-too-large))
                (let ((input (extended 8191 8192)))
                  (at-sizes (sampled input) input default-limits streaming outcome)))))
