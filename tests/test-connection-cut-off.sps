#!r6rs
;;; (http-server connection): what the parser's error cuts off, through the
;;; fake shell's message loop.  The cut-off-span PR.
;;;
;;; A malformed byte ends the parse, and the span the parser was reading is
;;; abandoned, never handed over (chez-httparse's docs/api.org: "an error
;;; abandons an open span rather than flushing it").  Only two spans can be
;;; open at an error, a target and a field name; a value, an extension and
;;; the protocol are handed over first.  A target or a name past its limit,
;;; then a malformed byte, was answered for the limit where a read ended
;;; between the two, and 400 where one read held both; a run of what the
;;; parser hands no span of, past its limit and then such a byte, was 400
;;; either way, for the run's reason or the parser's.  Now at the parser's
;;; error the core judges what it cut off as a read's end would have
;;; (decided on the owner's word, 2026-10-01), so the first limit passed, in
;;; the order of the bytes, names the response at every split:
;;;   - a target past its limit, 414, but past one space after the method
;;;     first, 400 for the spaces;
;;;   - a field name past its limit, 431, or past the section's, 431 for
;;;     the one passed first, in a head and in a trailer section;
;;;   - a chunk size's digits past 16 and the byte a read may end on, 400;
;;;   - and a byte the parser takes and then refuses, a tab, counted as
;;;     nothing: it is not the target's, nor a space.
;;; A shell hands the core the parser's open span with the result, and at an
;;; error, the refused byte's position.  Where the span began the parser
;;; does not say, so the core places it (byte-machine #145, filed to have a
;;; parse error say it): a name begins where its line does, a target one
;;; byte after the method's space unless that byte is another space.
;;;
;;; Each row runs at every delivery size, from a byte at a time to the whole
;;; input in one delivery, each delivery a bytevector of its own with the
;;; bytes at an offset in it, as a shell hands over a read.  A byte at a
;;; time, nothing is ever cut off: the expected answer is that one.
;;;
;;; Oracles: the inputs' own bytes; the limits each row sets; design §6.5's
;;; 400, 414 and 431; chez-httparse's parser, its errors' offsets and their
;;; position kinds (byte-machine's .reference/transition-and-cursor-
;;; semantics.md §4: `byte` at the refused byte, `boundary` past a byte the
;;; parser took); byte-machine v0.6.1's exports.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) library-exports)
        (http-server connection) (http-server response) (http-server limits)
        (http-server private adapter)
        (generated httparse-message) (httparse modes) (byte-machine runtime)
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

;; every-size : Bytevector Limits -> (Listof Datum)
;; The distinct outcomes over every delivery size, 1 to the whole.
(define (every-size input limits)
  (let loop ((size (bytevector-length input)) (seen '()))
    (if (zero? size)
        seen
        (let ((o (outcome input size limits)))
          (loop (- size 1) (if (member o seen) seen (cons o seen)))))))

;; --- the inputs --------------------------------------------------------------

;; tight : Limits — a target of 16 bytes; a field name of 17, so that a
;; chunked head's Transfer-Encoding passes; a value of 8; 32 in a section, a
;; trailer section's counted afresh; ten fields.
(define tight
  (limits-with default-limits
               '((max-target-bytes . 16) (max-header-field-bytes . 17) (max-header-value-bytes . 8)
                 (max-header-bytes . 32) (max-header-count . 10))))

(define ctl "\x1;")
(define (a n) (make-string n #\a))
(define (zeros n) (make-string n #\0))

;; chunked : String -> Bytevector — a chunked POST to /a whose body is `body`.
(define (chunked body)
  (b (string-append "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" body)))

;; The outcomes: a refusal before any request; one after the POST's handler
;; was asked, the body handed over so far.
(define (refused-first status reason) (list (list (list (list 'write status)) 'lingering reason)))
(define (post-refused body status reason)
  (list (list (append '((call-handler (POST "/a"))) (if body (list (list 'body body)) '())
                      (list (list 'write status)))
              'lingering reason)))

;; names-cut-off : Nat -> (Listof Bytevector)
;; A field name of `n` bytes cut off by a control byte, where a name begins:
;; the head's first line after the request line, a line after a field, the
;; first after a request line with no version, a trailer section's first,
;; and a line after a trailer.
(define (names-cut-off n)
  (let ((name (string-append (make-string n #\N) ctl ": v\r\n\r\n")))
    (list (b (string-append "GET /a HTTP/1.1\r\n" name))
          (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\n" name))
          (b (string-append "GET /a\r\n" name))
          (chunked (string-append "3\r\nabc\r\n0\r\n" name))
          (chunked (string-append "3\r\nabc\r\n0\r\nT: v\r\n" name)))))

;; result-event : String Bindings -> Event
;; The event a shell hands the core for one feed of `text`, whole, to a
;; fresh parser bound to `bindings`.
(define (result-event text bindings)
  (let* ((p (make-parser httparse-message-machine bindings #f
                         (list (cons 'type (httparse-message-type-value 'request)))))
         (bv (b text)))
    (parser-result-event (parser-feed! p bv 0 (bytevector-length bv)) p)))

;; bindings-with : SpanCallback -> Bindings
;; A binding for each callback the core declares, answering continue, but
;; `on-url-data`, which is `on-url-data`.  `quiet` answers continue to all;
;; `failing-url` fails the target's span.
(define (bindings-with on-url-data)
  (map (lambda (name)
         (list name (cond ((eq? name 'on-url-data) on-url-data)
                          ((memq name conn-span-callbacks) (lambda (p ctx bv from to) callback-continue))
                          (else (lambda (p ctx) callback-continue)))))
       conn-parser-callbacks))
(define quiet (bindings-with (lambda (p ctx bv from to) callback-continue)))
(define failing-url (bindings-with (lambda (p ctx bv from to) (make-callback-failure 'refused #f))))

;; The parser-error accessors byte-machine v0.6.1 exports, and the
;; active-span one: none says where an abandoned span began.
(define error-and-span-names
  '(parser-active-span parser-error-code parser-error-detail parser-error-domain
    parser-error-node-name parser-error-offset parser-error-position-kind
    parser-error-reason parser-error-state-id parser-error?))

;; starts-with? : String String -> Boolean
(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(run-suite "connection-cut-off"
  (lambda ()
    ;; --- a target ------------------------------------------------------------------
    (test-equal "a target at its limit, then a control byte, every delivery size: 400 for the parser"
                (refused-first 400 'parser-error)
                (every-size (b (string-append "GET /" (a 15) ctl " HTTP/1.1\r\nHost: x\r\n\r\n")) tight))
    (test-equal "a byte past its limit, then a control byte, every delivery size: 414"
                (refused-first 414 'target-too-large)
                (every-size (b (string-append "GET /" (a 16) ctl " HTTP/1.1\r\nHost: x\r\n\r\n")) tight))
    ;; The spaces after the method come before the target: past the one,
    ;; they are refused first, whatever the target and the byte after it.
    (test-equal "two spaces after the method, then a target past its limit and a control byte, or three and a control byte, every delivery size: 400 for the spaces"
                (list (refused-first 400 'request-line-spaces) (refused-first 400 'request-line-spaces))
                (list (every-size (b (string-append "GET  /" (a 16) ctl " HTTP/1.1\r\nHost: x\r\n\r\n")) tight)
                      (every-size (b (string-append "GET   " ctl " HTTP/1.1\r\nHost: x\r\n\r\n")) tight)))
    ;; The parser takes a tab there before refusing it: the error's offset
    ;; is past it, and it is neither a space nor the target's.
    (test-equal "a tab the parser takes and then refuses, after the method's space or after a target at its limit, every delivery size: 400 for the parser"
                (list (refused-first 400 'parser-error) (refused-first 400 'parser-error))
                (list (every-size (b "GET \t/a HTTP/1.1\r\nHost: x\r\n\r\n") tight)
                      (every-size (b (string-append "GET /" (a 15) "\tx HTTP/1.1\r\nHost: x\r\n\r\n")) tight)))

    ;; --- a field name --------------------------------------------------------------
    (test-equal "a field name at its limit, then a control byte, as the first field, after a field, after a request line with no version, as a trailer's first and after a trailer, every delivery size: 400 for the parser"
                (list (refused-first 400 'parser-error) (refused-first 400 'parser-error)
                      (refused-first 400 'parser-error)
                      (post-refused "abc" 400 'parser-error) (post-refused "abc" 400 'parser-error))
                (map (lambda (input) (every-size input tight)) (names-cut-off 17)))
    (test-equal "a byte past its limit, in each of those places, every delivery size: 431"
                (list (refused-first 431 'header-field-too-large) (refused-first 431 'header-field-too-large)
                      (refused-first 431 'header-field-too-large)
                      (post-refused "abc" 431 'header-field-too-large)
                      (post-refused "abc" 431 'header-field-too-large))
                (map (lambda (input) (every-size input tight)) (names-cut-off 18)))
    ;; The section's 32: Host: x, 6; Abcdefg: abcdefg, 15; Hijklm: abc, 10;
    ;; and the name cut off, within its own 17.
    (test-equal "a name within its limit that takes the section to its limit, and past it, then a control byte, every delivery size: 400 for the parser, then 431 for the section"
                (list (refused-first 400 'parser-error) (refused-first 431 'headers-too-large))
                (list (every-size (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\nAbcdefg: abcdefg\r\n"
                                                    "Hijklm: abc\r\nN" ctl ": v\r\n\r\n"))
                                  tight)
                      (every-size (b (string-append "GET /a HTTP/1.1\r\nHost: x\r\nAbcdefg: abcdefg\r\n"
                                                    "Hijklm: abc\r\nNo" ctl ": v\r\n\r\n"))
                                  tight)))

    ;; --- a chunk size's digits -------------------------------------------------------
    ;; At a read's end a size may hold one byte more than its 16 digits, the
    ;; `;` or CR that ends it, which the parser reads with no callback; at
    ;; the parser's error the digits are judged so too.
    (test-equal "eighteen digits, then a byte that is not one, every delivery size: 400 for the digits; seventeen, the byte a read may end on: 400 for the parser"
                (list (post-refused #f 400 'chunk-size-too-long) (post-refused #f 400 'parser-error))
                (list (every-size (chunked (string-append (zeros 18) "g\r\nabc\r\n0\r\n\r\n")) default-limits)
                      (every-size (chunked (string-append (zeros 17) "g\r\nabc\r\n0\r\n\r\n")) default-limits)))

    ;; --- what a shell hands the core -------------------------------------------------
    ;; `(parser-result status offset next code span)`, built once, by the
    ;; adapter: the parser's count, or at an error the refused byte's
    ;; position; one code, an error's or a pause's; the span it has open.
    ;; In "GET /a" the target's bytes are 4 and 5, so a control byte at 6 is
    ;; refused where it stands, and a tab at 6 after the parser took it.
    (test-equal "a result as a shell hands it: the count and the open span; at an error, the refused byte's position, the code, the span cut off; a callback's failure at its own position"
                '((parser-result need-input 6 6 #f url-span)
                  (parser-result error 6 6 invalid-url url-span)
                  (parser-result error 6 7 invalid-url url-span)
                  (parser-result error 6 6 refused url-span))
                (list (result-event "GET /a" quiet)
                      (result-event (string-append "GET /a" ctl "x") quiet)
                      (result-event "GET /a\tx" quiet)
                      (result-event "GET /a " failing-url)))
    (test-equal "a pause's code goes where an error's would: an upgrade's, with no span open"
                '(parser-result paused 51 51 paused-upgrade #f)
                (result-event "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: x\r\n\r\n" quiet))

    ;; --- decision 0008: the workaround and its ask -----------------------------------
    ;; The core places a cut-off span itself because a parse error does not
    ;; say where the span it abandoned began.  byte-machine #145 asks that it
    ;; should; when an accessor for it lands, this goes red, and the line
    ;; starts and the space check go.
    (test-equal "byte-machine #145 has not landed: its runtime's error and active-span accessors are v0.6.1's"
                error-and-span-names
                (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                           (filter (lambda (name)
                                     (let ((s (symbol->string name)))
                                       (or (starts-with? s "parser-error") (starts-with? s "parser-active-span"))))
                                   (library-exports '(byte-machine runtime)))))))
