#!r6rs
;;; (http-server connection): what the parser reads and hands the core no
;;; span of, through the fake shell's message loop.  The padding PR.
;;;
;;; With chez-httparse driving the core through the adapter, each event
;;; callback carrying the parser's position.  Four runs of bytes the parser
;;; reads outside the pieces it hands on are held to limits (decided on the
;;; owner's word, 2026-09-30):
;;;   - the empty lines before a request line: two are skipped (RFC 9112
;;;     §2.2 asks for one, and llhttp's own fixture has two after a POST's
;;;     body), and more are refused, 400;
;;;   - the spaces between the request line's parts: one each (§3), and more
;;;     are refused, 400;
;;;   - the spaces and tabs before a field's value: counted with the value,
;;;     against its limit and the section's, 431, in a head and in a
;;;     trailer section; an empty value's with its line end;
;;;   - a chunk size's digits: 16 at most, zeros included (§7.1), and more
;;;     are refused, 400.
;;;
;;; Each row runs at every delivery size, from a byte at a time to the whole
;;; input in one delivery, so one expected answer is also the outcome's
;;; independence from how the bytes were split (design §8.1's second
;;; property).  Each delivery is a bytevector of its own, the bytes at an
;;; offset in it, as a shell hands over a read: a run's bytes are counted
;;; from where the parser is, not from where a delivery's bytes sit.  The megabyte runs, the ones main answered 200, run at a
;;; sample of sizes from 64 bytes, the shell's 16 KiB read among them: a
;;; byte at a time, a connection that did not refuse would pass the fake
;;; shell's cap of 100,000 dispatches.
;;;
;;; Oracles: RFC 9112 §2.2, §3, §5 and §7.1; the inputs' own bytes; the
;;; limits each row sets; design §6.5's 400 and 431; decision 0011's staged
;;; close.
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server response) (http-server limits)
        (fake-shell) (decisive))

(define (b s) (string->utf8 s))

(define ok (make-response 200 #f '() #f))

;; read! : Bytevector Nat Limits -> FakeShell
;; One connection reading `input` in `size`-byte deliveries while it reads,
;; each copied to index 3 of a bytevector of its own, its handler reading
;; every body.
(define (read! input size limits)
  (let ((sh (make-fake-connection limits (drops-body (lambda (request) ok)))))
    (fake-shell-feed-input! sh input size 3)
    sh))

;; outcome : Bytevector Nat Limits -> Datum
;; What the connection did with `input`, and the phase and close-after it
;; ended with.
(define (outcome input size limits)
  (let* ((sh (read! input size limits)) (s (fake-shell-conn-state sh)))
    (list (decisive (fake-shell-actions sh)) (conn-phase s) (conn-close-after s))))

;; fed-of : Bytevector Nat -> Nat
;; How much of `input` a connection fed its parser: what it read and
;; dropped as it lingered after a refusal is not.
(define (fed-of input size)
  (fold-left (lambda (n a) (if (eq? (car a) 'feed-parser) (+ n (- (cadddr a) (caddr a))) n))
             0 (fake-shell-actions (read! input size default-limits))))

;; at-sizes : (Listof Nat) Bytevector Limits -> (Listof Datum)
;; The distinct outcomes over the delivery sizes `sizes`.
(define (at-sizes sizes input limits)
  (fold-left (lambda (seen size)
               (let ((o (outcome input size limits)))
                 (if (member o seen) seen (append seen (list o)))))
             '() sizes))

;; every-size : Bytevector Limits -> (Listof Datum) — at-sizes over 1 to the whole.
(define (every-size input limits)
  (let loop ((size (bytevector-length input)) (sizes '()))
    (if (zero? size) (at-sizes sizes input limits) (loop (- size 1) (cons size sizes)))))

;; sampled : Bytevector Limits -> (Listof Datum)
;; at-sizes over sizes from 64 bytes, the shell's 16 KiB read, and the whole.
(define (sampled input limits)
  (at-sizes (append '(64 509 4096 16384) (list (bytevector-length input))) input limits))

;; --- the inputs --------------------------------------------------------------

(define get-a "GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
(define get-b "GET /b HTTP/1.1\r\nHost: x\r\n\r\n")

;; repeat : String Nat -> String
(define (repeat s n)
  (let loop ((n n) (acc '())) (if (zero? n) (apply string-append acc) (loop (- n 1) (cons s acc)))))

(define (spaces n) (make-string n #\space))
(define (zeros n) (make-string n #\0))

(define megabyte 1000000)

;; small : Limits — a value of 8 bytes and 32 in a section, as M6.4's
;; trailers were held to, 3 fields.  The head's Host: x is 6 bytes with its
;; space.
(define small
  (limits-with default-limits
               '((max-header-value-bytes . 8) (max-header-bytes . 32) (max-header-count . 3))))

;; field-get : String -> Bytevector — GET /a with the field line `line`.
(define (field-get line) (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n" line "\r\n\r\n")))

;; chunked : String -> Bytevector
;; A chunked POST to /a whose body is `body`, and the GET behind it.
(define (chunked body)
  (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" body get-b)))

;; The outcomes: both requests served; a refusal before any request; one
;; after the POST's handler was asked, the body handed over so far.
(define both-served
  '((((call-handler (GET "/a")) (end) (write 200) (call-handler (GET "/b")) (end) (write 200))
     idle #f)))
(define (refused-first status reason) (list (list (list (list 'write status)) 'lingering reason)))
(define post-served
  '((((call-handler (POST "/a")) (body "abc") (end) (write 200)
      (call-handler (GET "/b")) (end) (write 200))
     idle #f)))
(define (post-refused body status reason)
  (list (list (append '((call-handler (POST "/a"))) (if body (list (list 'body body)) '())
                      (list (list 'write status)))
              'lingering reason)))

(run-suite "connection-padding"
  (lambda ()
    ;; --- empty lines before a request line --------------------------------------
    ;; Two are skipped, at a connection's start, between requests, or after a
    ;; POST's body, as CRLFs or bare LFs: their 4 bytes are the most.
    (test-equal "two empty lines before a request line, CRLF or LF, at the start, between requests and after a body, every delivery size: served"
                (list both-served both-served both-served post-served)
                (list (every-size (b (string-append "\r\n\r\n" get-a get-b)) default-limits)
                      (every-size (b (string-append "\n\n\n\n" get-a get-b)) default-limits)
                      (every-size (b (string-append get-a "\r\n\r\n" get-b)) default-limits)
                      (every-size (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n"
                                                    "abc\r\n\r\n" get-b))
                                  default-limits)))
    (test-equal "a byte more, at the start or between requests, every delivery size: 400, then the staged close"
                (list (refused-first 400 'empty-lines)
                      '((((call-handler (GET "/a")) (end) (write 200) (write 400)) lingering empty-lines)))
                (list (every-size (b (string-append "\r\n\r\n\n" get-a get-b)) default-limits)
                      (every-size (b (string-append get-a "\r\n\r\n\r" get-b)) default-limits)))
    (test-equal "a megabyte of empty lines, sampled delivery sizes: 400"
                (refused-first 400 'empty-lines)
                (sampled (b (string-append (repeat "\r\n" (div megabyte 2)) get-a)) default-limits))

    ;; --- the request line's spaces ------------------------------------------------
    (test-equal "two spaces after the method, or before the version, every delivery size: 400"
                (list (refused-first 400 'request-line-spaces) (refused-first 400 'request-line-spaces))
                (list (every-size (b (string-append "GET  /a HTTP/1.1\r\nHost: x\r\n\r\n" get-b)) default-limits)
                      (every-size (b (string-append "GET /a  HTTP/1.1\r\nHost: x\r\n\r\n" get-b)) default-limits)))
    (test-equal "a megabyte of spaces after the method, sampled delivery sizes: 400"
                (refused-first 400 'request-line-spaces)
                (sampled (b (string-append "GET" (spaces megabyte) "/a HTTP/1.1\r\nHost: x\r\n\r\n"))
                         default-limits))

    ;; --- the whitespace before a field's value -----------------------------------
    ;; Under `small`, 8 bytes of value: the whitespace and the value together.
    (test-equal "spaces or tabs before a value, with it at the value's limit, every delivery size: served"
                (list '((((call-handler (GET "/a")) (end) (write 200)) idle #f))
                      '((((call-handler (GET "/a")) (end) (write 200)) idle #f)))
                (list (every-size (field-get (string-append "X:" (spaces 7) "v")) small)
                      (every-size (field-get "X:\t \t \t \tv") small)))
    (test-equal "a byte of whitespace more, every delivery size: 431"
                (refused-first 431 'header-value-too-large)
                (every-size (field-get (string-append "X:" (spaces 8) "v")) small))
    ;; An empty value is handed over after its line end, so its whitespace and
    ;; line end count together: 6 spaces and CRLF are 8.
    (test-equal "an empty value's whitespace and line end at the value's limit, and a byte more, every delivery size: served, then 431"
                (list '((((call-handler (GET "/a")) (end) (write 200)) idle #f))
                      (refused-first 431 'header-value-too-large))
                (list (every-size (field-get (string-append "X:" (spaces 6))) small)
                      (every-size (field-get (string-append "X:" (spaces 7))) small)))
    ;; The section's 32: Host: x, 6; then 13 and 13 with their whitespace.
    (test-equal "the section at its limit with the whitespace counted, and a byte more, every delivery size: served, then 431"
                (list '((((call-handler (GET "/a")) (end) (write 200)) idle #f))
                      (refused-first 431 'headers-too-large))
                (list (every-size (field-get (string-append "Abcde:" (spaces 7) "v\r\nFghij:" (spaces 7) "v"))
                                  small)
                      (every-size (field-get (string-append "Abcde:" (spaces 7) "v\r\nFghijk:" (spaces 7) "v"))
                                  small)))
    (test-equal "a trailer's whitespace with its value at the limit, and a byte more, every delivery size: served, then 431"
                (list post-served (post-refused "abc" 431 'header-value-too-large))
                (list (every-size (chunked (string-append "3\r\nabc\r\n0\r\nT:" (spaces 7) "v\r\n\r\n")) small)
                      (every-size (chunked (string-append "3\r\nabc\r\n0\r\nT:" (spaces 8) "v\r\n\r\n")) small)))
    (test-equal "a megabyte of spaces before a value, in a head and in a trailer section, sampled delivery sizes: 431"
                (list (refused-first 431 'header-value-too-large)
                      (post-refused "abc" 431 'header-value-too-large))
                (list (sampled (field-get (string-append "X:" (spaces megabyte) "v")) default-limits)
                      (sampled (chunked (string-append "3\r\nabc\r\n0\r\nT:" (spaces megabyte) "t\r\n\r\n"))
                               default-limits)))

    ;; --- a chunk size's digits ---------------------------------------------------
    (test-equal "a chunk size of 16 digits, zeros included, in a data chunk, the last, or before an extension, every delivery size: served"
                (list post-served post-served post-served)
                (list (every-size (chunked (string-append (zeros 15) "3\r\nabc\r\n0\r\n\r\n")) default-limits)
                      (every-size (chunked (string-append "3\r\nabc\r\n" (zeros 16) "\r\n\r\n")) default-limits)
                      (every-size (chunked (string-append (zeros 15) "3;e\r\nabc\r\n0\r\n\r\n")) default-limits)))
    (test-equal "17 digits, in a data chunk, the last, or before an extension, every delivery size: 400"
                (list (post-refused #f 400 'chunk-size-too-long)
                      (post-refused "abc" 400 'chunk-size-too-long)
                      (post-refused #f 400 'chunk-size-too-long))
                (list (every-size (chunked (string-append (zeros 16) "3\r\nabc\r\n0\r\n\r\n")) default-limits)
                      (every-size (chunked (string-append "3\r\nabc\r\n" (zeros 17) "\r\n\r\n")) default-limits)
                      (every-size (chunked (string-append (zeros 16) "3;e\r\nabc\r\n0\r\n\r\n")) default-limits)))
    (test-equal "a last chunk of a megabyte of zeros, sampled delivery sizes: 400"
                (post-refused "abc" 400 'chunk-size-too-long)
                (sampled (chunked (string-append "3\r\nabc\r\n" (zeros megabyte) "\r\n\r\n")) default-limits))

    ;; --- the work a run costs --------------------------------------------------------
    ;; In the shells' 16 KiB reads each run passes its limit inside the
    ;; first, and is refused at that read's end, so the parser is fed no
    ;; more: a megabyte of padding costs it one read.  The rest is read and
    ;; dropped as the connection lingers (decision 0011).
    (test-equal "a megabyte of each run, in 16 KiB reads: refused at the first read's end, the rest never parsed"
                '(16384 16384 16384 16384 16384)
                (map (lambda (input) (fed-of input 16384))
                     (list (b (string-append (repeat "\r\n" (div megabyte 2)) get-a))
                           (b (string-append "GET" (spaces megabyte) "/a HTTP/1.1\r\nHost: x\r\n\r\n"))
                           (field-get (string-append "X:" (spaces megabyte) "v"))
                           (chunked (string-append "3\r\nabc\r\n0\r\nT:" (spaces megabyte) "t\r\n\r\n"))
                           (chunked (string-append "3\r\nabc\r\n" (zeros megabyte) "\r\n\r\n")))))))
