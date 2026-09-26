#!r6rs
;;; (http-server transfer-coding): RFC 9112 §6.1's two rules for a request's
;;; transfer codings, judged from the parser's flags and the head's kept
;;; fields.
;;;
;;; The server implements one transfer coding, chunked.  "A server that
;;; receives a request message with a transfer coding it does not understand
;;; SHOULD respond with 501 (Not Implemented)."  And a server that receives
;;; an HTTP/1.0 message with Transfer-Encoding MUST treat its framing as
;;; faulty and close the connection after processing it.  Decided on the
;;; owner's word, 2026-09-26: a coding listed beside a final chunked is a
;;; 501; every other invalid Transfer-Encoding is the parser's to refuse, a
;;; 400 (§6.3); and a request below HTTP/1.1 with Transfer-Encoding is
;;; refused as faulty framing, a 400 too.
;;;
;;; The flags are llhttp's, as the core reads them at on-headers-complete:
;;; F-CHUNKED when the parser frames the body by a final chunked, and
;;; F-TRANSFER-ENCODING whenever the request has the field.  Measured at the
;;; pin (ledger, 2026-09-26): `chunked`, `Chunked`, `gzip, chunked`, and gzip
;;; and chunked on two lines set both; `gzip` and `chunked;x=1` set only the
;;; second, and the parser refuses them.
;;;
;;; Oracles: RFC 9112 §6.1 and §7 (chunked, the one coding the server
;;; implements, matched without regard to case); RFC 9110 §5.3 (a field's
;;; lines combine into one list) and §5.6.1 (a list's elements, with OWS
;;; around each and empty elements ignored); llhttp's flags, as measured;
;;; llhttp's version gate, which only 1.1 passes.  Every verdict is compared
;;; as a symbol, never as #f: SRFI-64 turns an exception inside a test
;;; expression into #f.
(import (rnrs) (srfi :64) (testing)
        (http-server transfer-coding) (http-server span)
        (only (httparse decisions) F-CHUNKED F-TRANSFER-ENCODING F-CONNECTION-KEEP-ALIVE))

(define (b s) (string->utf8 s))

;; field : String String -> (Pair Span Span) — a header line's name and value,
;; each a span inside the bytes "name: value, gzip\r\n", as the core keeps
;; them.  The bytes after the value would change the verdict of a scan that
;; ran past it: `chunked` alone would read as chunked beside gzip.
(define (field name value)
  (let* ((line (b (string-append name ": " value ", gzip\r\n")))
         (ne (bytevector-length (b name)))
         (vs (+ ne 2)) (ve (+ vs (bytevector-length (b value)))))
    (cons (make-span line 0 ne) (make-span line vs ve))))

;; The flags a request with Transfer-Encoding carries: the body framed by a
;; final chunked, or not.
(define chunked-flags (bitwise-ior F-TRANSFER-ENCODING F-CHUNKED))
(define unframed-flags F-TRANSFER-ENCODING)

;; judged : (Listof (Pair String String)) Nat -> Symbol
;; 'unsupported when the check refuses the fields under `flags`, else
;; 'accepted.
(define (judged fields flags)
  (if (unsupported-transfer-coding? (map (lambda (f) (field (car f) (cdr f))) fields) flags)
      'unsupported
      'accepted))

;; coded : String -> Symbol — one Transfer-Encoding line, framed by chunked.
(define (coded value) (judged (list (cons "Host" "x") (cons "Transfer-Encoding" value)) chunked-flags))

;; framing : Nat Nat Nat -> Symbol — 'faulty or 'sound, by version and flags.
(define (framing major minor flags)
  (if (faulty-framing? major minor flags) 'faulty 'sound))

(run-suite "transfer-coding"
  (lambda ()
    ;; --- the 501: another coding beside a final chunked ------------------------
    (test-equal "chunked alone is accepted, in any case"
                '(accepted accepted accepted)
                (map coded '("chunked" "Chunked" "CHUNKED")))
    (test-equal "any other coding is refused, whatever it is"
                '(unsupported unsupported unsupported unsupported unsupported)
                (map coded '("gzip, chunked" "deflate, chunked" "compress, chunked"
                             "x-custom, chunked" "identity, chunked")))
    (test-eq "chunked is matched without regard to case" 'unsupported (coded "gzip, CHUNKED"))
    (test-equal "a coding with a parameter, or one that begins with chunked, is another coding"
                '(unsupported unsupported)
                (map coded '("gzip;q=0.5, chunked" "chunkedchunked, chunked")))
    ;; RFC 9110 §5.3: two lines are one list.  The core keeps its fields
    ;; newest first, so they are read in either order.
    (test-equal "codings on two lines combine, in either order"
                '(unsupported unsupported)
                (list (judged '(("Transfer-Encoding" . "gzip") ("Transfer-Encoding" . "chunked")) chunked-flags)
                      (judged '(("Transfer-Encoding" . "chunked") ("Transfer-Encoding" . "gzip")) chunked-flags)))
    (test-eq "the field's name is matched without regard to case" 'unsupported
             (judged '(("transfer-encoding" . "gzip, chunked")) chunked-flags))
    (test-eq "a field named like Transfer-Encoding is not it" 'accepted
             (judged '(("X-Transfer-Encoding" . "gzip, chunked") ("Transfer-Encoding" . "chunked"))
                     chunked-flags))

    ;; --- the list's syntax: OWS around each element, empty elements ignored ----
    (test-equal "OWS around chunked is not part of it"
                '(accepted accepted)
                (map coded '("chunked \t" "\t chunked")))
    (test-equal "an empty element is ignored"
                '(accepted accepted unsupported)
                (map coded '(", chunked" "chunked, , chunked" "gzip, , chunked")))

    ;; --- no chunked framing: the parser's to refuse, a 400 (RFC 9112 §6.3) ----
    ;; The check asks only when the parser frames the body by a final
    ;; chunked; otherwise a Transfer-Encoding is the parser's to refuse.
    ;; A coding after chunked is one: whatever the list holds, it is not
    ;; this check's to answer 501.
    (test-equal "without F-CHUNKED, nothing is refused here"
                '(accepted accepted accepted accepted)
                (list (judged '(("Transfer-Encoding" . "gzip")) unframed-flags)
                      (judged '(("Transfer-Encoding" . "chunked;x=1")) unframed-flags)
                      (judged '(("Transfer-Encoding" . "chunked, gzip")) unframed-flags)
                      (judged '(("Host" . "x")) 0)))

    ;; --- Transfer-Encoding below HTTP/1.1: faulty framing, a 400 --------------
    ;; Below 1.1 is llhttp's version gate, as should-keep-alive? applies it:
    ;; 0.9, 1.0, and 2.0 in HTTP/1 syntax.
    (test-equal "Transfer-Encoding below HTTP/1.1 is faulty framing"
                '(faulty faulty faulty faulty)
                (list (framing 1 0 unframed-flags) (framing 1 0 (bitwise-ior chunked-flags F-CONNECTION-KEEP-ALIVE))
                      (framing 0 9 chunked-flags) (framing 2 0 chunked-flags)))
    (test-equal "HTTP/1.1 with it, and anything without it, is sound"
                '(sound sound sound)
                (list (framing 1 1 chunked-flags) (framing 1 0 F-CONNECTION-KEEP-ALIVE) (framing 1 0 0)))))
