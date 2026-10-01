#!r6rs
;;; (http-server connection): what the parser's error cuts off.  The
;;; cut-off-span PR.
;;;
;;; A malformed byte ends the parse, and the span the parser was reading is
;;; abandoned, never handed over (chez-httparse's docs/api.org: "an error
;;; abandons an open span rather than flushing it").  To judge what it cut
;;; off, the core needs to know which span that was, so a shell hands it the
;;; span the parser has open with each result.  The event is built once, by
;;; the adapter, for both shells: `(parser-result status offset next code
;;; span)`, its code the error's or the pause's, since a result has one or
;;; neither (decided on the owner's word, 2026-10-01).
;;;
;;; Oracles: the inputs' own bytes; chez-httparse's parser, its results and
;;; the span it has open (`parser-active-span`).
(import (rnrs) (srfi :64) (testing)
        (http-server connection) (http-server private adapter)
        (generated httparse-message) (httparse modes) (byte-machine runtime))

(define (b s) (string->utf8 s))

(define ctl "\x1;")

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

(run-suite "connection-cut-off"
  (lambda ()
    ;; --- what a shell hands the core -------------------------------------------------
    ;; `(parser-result status offset next code span)`, built once, by the
    ;; adapter: the parser's count; one code, an error's or a pause's; the
    ;; span it has open.  In "GET /a" the target's bytes are 4 and 5, so a
    ;; control byte at 6 is refused where it stands, and a tab at 6 after the
    ;; parser took it.
    (test-equal "a result as a shell hands it: the count and the open span; at an error, the code and the span cut off"
                '((parser-result need-input 6 6 #f url-span)
                  (parser-result error 6 6 invalid-url url-span)
                  (parser-result error 7 7 invalid-url url-span)
                  (parser-result error 6 6 refused url-span))
                (list (result-event "GET /a" quiet)
                      (result-event (string-append "GET /a" ctl "x") quiet)
                      (result-event "GET /a\tx" quiet)
                      (result-event "GET /a " failing-url)))
    (test-equal "a pause's code goes where an error's would: an upgrade's, with no span open"
                '(parser-result paused 51 51 paused-upgrade #f)
                (result-event "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: x\r\n\r\n" quiet))))
