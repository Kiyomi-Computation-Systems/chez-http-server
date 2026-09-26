#!r6rs
;;; (http-server transfer-coding) — RFC 9112 §6.1's two rules for a request's
;;; transfer codings, from the parser's flags and the head's kept fields
;;; (pure).
;;;
;;; The server implements one transfer coding, chunked (RFC 9112 §7).
;;; Decided on the owner's word, 2026-09-26:
;;;
;;;   - "A server that receives a request message with a transfer coding it
;;;     does not understand SHOULD respond with 501 (Not Implemented)."  When
;;;     the parser frames the body by a final chunked and the
;;;     Transfer-Encoding lists another coding beside it, the request is
;;;     refused, and the core answers 501: the parser reads the chunked, and
;;;     nothing would undo the rest.  Every other invalid Transfer-Encoding,
;;;     with no chunked or a coding after it, leaves the body's length
;;;     unknown: the parser refuses it, and its error is a 400 (§6.3);
;;;   - a server that receives an HTTP/1.0 message with Transfer-Encoding
;;;     "MUST treat the message as if the framing is faulty" and close the
;;;     connection after processing it.  A request below HTTP/1.1 with the
;;;     field is refused, and the core answers 400, then closes: RFC 9112
;;;     answers faulty framing with a 400 and a close elsewhere (§6.3), and
;;;     nginx does the same here.
;;;
;;; The parser says which applies, in the flags the core reads at
;;; on-headers-complete: F-CHUNKED when it frames the body by a final
;;; chunked, and F-TRANSFER-ENCODING whenever the field is present (measured
;;; at the pin, ledger 2026-09-26).  So the codings are read only when the
;;; parser will read chunked, and where chunked sits in them is the parser's
;;; to judge, not this library's.
;;;
;;; The codings are the elements of every Transfer-Encoding line (RFC 9110
;;; §5.3).  OWS around an element is not part of it, and an empty element is
;;; ignored (§5.6.1).  Chunked is matched without regard to case, and a
;;; coding with a parameter is not chunked.  Values are read in place, and
;;; nothing is copied.
;;; PURE: imports (rnrs), (http-server span), (http-server headers),
;;; (http-server decisions) and (httparse decisions).
(library (http-server transfer-coding)
  (export unsupported-transfer-coding? faulty-framing?)
  (import (rnrs)
          (http-server span)
          (only (http-server headers) header-name=? trim-ows range-ci=?)
          (only (http-server decisions) http/1.1?)
          (only (httparse decisions) F-CHUNKED F-TRANSFER-ENCODING))

  (define TRANSFER-ENCODING (string->utf8 "transfer-encoding"))
  (define CHUNKED (string->utf8 "chunked"))

  ;; unsupported-transfer-coding? : (Listof (Pair Span Span)) Nat -> Boolean
  ;;   fields flags — the head's (name . value) spans, in any order, and
  ;;   llhttp's flags, read at on-headers-complete
  ;; #t when the parser frames the body by a final chunked (F-CHUNKED) and a
  ;; Transfer-Encoding line lists another coding, one the server does not
  ;; implement.  The lines are read only under F-CHUNKED.
  (define (unsupported-transfer-coding? fields flags)
    (and (flag? flags F-CHUNKED) (other-coding? fields)))

  ;; faulty-framing? : Nat Nat Nat -> Boolean
  ;;   http-major http-minor flags — the request's version, and llhttp's flags
  ;; #t when a request below HTTP/1.1 carries Transfer-Encoding
  ;; (F-TRANSFER-ENCODING): its framing is to be treated as faulty (RFC 9112
  ;; §6.1), and the core refuses it.  Below 1.1 is llhttp's version gate,
  ;; `http/1.1?`, which should-keep-alive? applies too.
  (define (faulty-framing? http-major http-minor flags)
    (and (flag? flags F-TRANSFER-ENCODING) (not (http/1.1? http-major http-minor))))

  ;; flag? : Nat Nat -> Boolean — whether `flags` has the bit `f`.
  (define (flag? flags f) (not (fxzero? (fxand flags f))))

  ;; other-coding? : (Listof (Pair Span Span)) -> Boolean
  ;; Whether any Transfer-Encoding line lists a coding other than chunked.
  (define (other-coding? fields)
    (and (pair? fields)
         (or (and (header-name=? (caar fields) TRANSFER-ENCODING)
                  (let ((value (cdar fields)))
                    (lists-other? (span-bytevector value) (span-start value) (span-end value))))
             (other-coding? (cdr fields)))))

  ;; lists-other? : Bytevector Nat Nat -> Boolean
  ;; Whether the list in bv[start, end) holds an element other than chunked.
  (define (lists-other? bv start end)
    (let loop ((i start))
      (and (fx<=? i end)
           (let ((comma (find-comma bv i end)))
             (let-values (((from to) (trim-ows bv i comma)))
               (or (and (fx<? from to) (not (range-ci=? bv from to CHUNKED)))
                   (loop (fx+ comma 1))))))))

  ;; find-comma : Bytevector Nat Nat -> Nat — the first comma in [i, end), or end.
  (define (find-comma bv i end)
    (if (or (fx=? i end) (fx=? (bytevector-u8-ref bv i) 44)) i (find-comma bv (fx+ i 1) end))))
