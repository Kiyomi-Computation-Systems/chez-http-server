#!r6rs
;;; (smuggling-corpus) — a small, hand-written set of request-framing vectors,
;;; the kinds an HTTP request-smuggling (desync) attack is built from, each
;;; stated so this server's answer to it can be pinned.  Test-only,
;;; defensive.
;;;
;;; These are FIXED vectors authored here, not generated and not a probe: no
;;; code here emits permutations or talks to a server.  Each case is one
;;; request's bytes and the verdict this server gives it, so a parser or
;;; framing change that would start honouring a smuggling gadget fails the
;;; lane (tests/smuggling-lane.sls) until reviewed.
;;;
;;; The families are the well-known request-smuggling taxonomy (RFC 9112 §6.1,
;;; §6.3, §5.1; the PortSwigger/defparam catalogues name the same shapes):
;;;   - CL.TE / TE.CL — a message carrying both Content-Length and
;;;     Transfer-Encoding, the ambiguity a desync rides on (§6.1);
;;;   - duplicate or malformed Content-Length (§6.3);
;;;   - an obfuscated Transfer-Encoding: a space before the colon, a tab in
;;;     the value, a repeated header, a coding list with chunked out of place,
;;;     a coding the server does not implement (§6.1, §5.1);
;;;   - a look-alike field name (Transfer_Encoding, Transfer--Encoding) that
;;;     is an ordinary header, not a coding, and must not frame (§5.1).
;;;
;;; Each case names its `category`: `safe`, a request this server serves
;;; because its framing is unambiguous (a valid request, a tab that is only
;;; OWS, a name that is not a coding); or `hazard`, a request that must be
;;; refused, because serving it with a body boundary an attacker chose is the
;;; desync.  tests/smuggling-lane.sls holds `category` and the server's answer
;;; to each other: no hazard may be served, and no served case may be a
;;; hazard.
;;;
;;; PURE data and a byte assembler; imports only (rnrs).
(library (smuggling-corpus)
  (export smuggling-case? smuggling-case-id smuggling-case-family
          smuggling-case-category smuggling-case-reference
          smuggling-case-expected smuggling-case-request
          smuggling-cases)
  (import (rnrs))

  ;; A case:
  ;;   id        — String, unique; the lane reports by it.
  ;;   family    — Symbol, the smuggling taxonomy family.
  ;;   category  — Symbol, `safe` (served) or `hazard` (refused).
  ;;   reference — String, the RFC clause the verdict rests on.
  ;;   expected  — the server's answer: the symbol `served`, or a status Nat
  ;;               meaning "refused with this status, then close".
  ;;   lines     — (Listof String), the request line then the header lines,
  ;;               joined with CRLF; a blank line follows.
  ;;   body      — String, appended after the blank line verbatim (may be "").
  ;;
  ;; smuggling-case?          : Any -> Boolean
  ;; smuggling-case-id        : SmugglingCase -> String
  ;; smuggling-case-family    : SmugglingCase -> Symbol
  ;; smuggling-case-category  : SmugglingCase -> (U 'safe 'hazard)
  ;; smuggling-case-reference : SmugglingCase -> String
  ;; smuggling-case-expected  : SmugglingCase -> (U 'served Nat)
  (define-record-type smuggling-case
    (fields id family category reference expected lines body)
    (sealed #t))

  (define TAB (string #\tab))
  ;; A chunked body that terminates at once: "0" CRLF CRLF.
  (define END "0\r\n\r\n")

  ;; smuggling-case-request : SmugglingCase -> Bytevector
  ;; The case's bytes: its lines joined with CRLF, a blank line, then the body.
  (define (smuggling-case-request c)
    (let loop ((ls (smuggling-case-lines c)) (acc '()))
      (if (null? ls)
          (string->utf8 (apply string-append
                               (append (reverse acc) (list "\r\n" (smuggling-case-body c)))))
          (loop (cdr ls) (cons "\r\n" (cons (car ls) acc))))))

  ;; smuggling-cases : -> (Listof SmugglingCase)
  ;; The corpus, in a fixed order.  Each `expected` is this server's answer;
  ;; the lane runs the server on every case and holds it to that answer.
  (define (smuggling-cases)
    (list
     ;; --- safe: served, framing unambiguous --------------------------------
     (make-smuggling-case "baseline-get" 'baseline 'safe
       "RFC 9112 §6.3 (no body, length 0)" 'served
       '("GET / HTTP/1.1" "Host: x") "")
     (make-smuggling-case "baseline-chunked" 'baseline 'safe
       "RFC 9112 §6.1 (a valid chunked request)" 'served
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: chunked") END)
     (make-smuggling-case "baseline-content-length" 'baseline 'safe
       "RFC 9110 §8.6 (a valid Content-Length)" 'served
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 0") "")
     (make-smuggling-case "te-ows-tab" 'te-obfuscation 'safe
       "RFC 9112 §5.1 (a tab after the colon is OWS; chunked is honoured)" 'served
       (list "POST / HTTP/1.1" "Host: x" (string-append "Transfer-Encoding:" TAB "chunked")) END)
     (make-smuggling-case "lookalike-underscore" 'lookalike-name 'safe
       "RFC 9112 §5.1 (an underscore is not a hyphen; an ordinary field)" 'served
       '("POST / HTTP/1.1" "Host: x" "Transfer_Encoding: chunked") "")
     (make-smuggling-case "lookalike-doubledash" 'lookalike-name 'safe
       "RFC 9112 §5.1 (not the Transfer-Encoding field name)" 'served
       '("POST / HTTP/1.1" "Host: x" "Transfer--Encoding: chunked") "")
     ;; --- hazard: CL and TE together (CL.TE / TE.CL) -----------------------
     (make-smuggling-case "cl.te" 'cl-and-te 'hazard
       "RFC 9112 §6.1 (both present: the desync ambiguity)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 6" "Transfer-Encoding: chunked") END)
     (make-smuggling-case "te.cl" 'cl-and-te 'hazard
       "RFC 9112 §6.1 (both present, other order)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: chunked" "Content-Length: 6") END)
     ;; --- hazard: duplicate or malformed Content-Length --------------------
     (make-smuggling-case "dup-cl-equal" 'duplicate-cl 'hazard
       "RFC 9112 §6.3 (two Content-Length, equal)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 6" "Content-Length: 6") "hello!")
     (make-smuggling-case "dup-cl-differ" 'duplicate-cl 'hazard
       "RFC 9112 §6.3 (two Content-Length, differing)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 6" "Content-Length: 5") "hello!")
     (make-smuggling-case "cl-plus" 'malformed-cl 'hazard
       "RFC 9110 §8.6 (a sign is not a digit)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: +6") "hello!")
     (make-smuggling-case "cl-nondigit" 'malformed-cl 'hazard
       "RFC 9110 §8.6 (a trailing non-digit)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 6a") "hello!")
     (make-smuggling-case "cl-list" 'malformed-cl 'hazard
       "RFC 9112 §6.3 (a comma list of lengths)" 400
       '("POST / HTTP/1.1" "Host: x" "Content-Length: 6, 6") "hello!")
     ;; --- hazard: obfuscated Transfer-Encoding -----------------------------
     (make-smuggling-case "te-space-before-colon" 'te-obfuscation 'hazard
       "RFC 9112 §5.1 (no space before the colon)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding : chunked") END)
     (make-smuggling-case "dup-te-chunked" 'te-obfuscation 'hazard
       "RFC 9112 §6.1 (chunked declared twice)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: chunked" "Transfer-Encoding: chunked") END)
     (make-smuggling-case "te-chunked-not-last" 'te-ordering 'hazard
       "RFC 9112 §6.1 (chunked must be the final coding)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: chunked, gzip") END)
     (make-smuggling-case "te-coding-before-chunked" 'te-unimplemented 'hazard
       "RFC 9112 §6.1 (a coding the server does not implement: 501)" 501
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: gzip, chunked") END)
     (make-smuggling-case "te-unknown-coding" 'te-unimplemented 'hazard
       "RFC 9112 §6.1 (an unknown single coding)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: cow") END)
     (make-smuggling-case "te-identity" 'te-unimplemented 'hazard
       "RFC 9112 §6.1 (identity is not an HTTP/1.1 coding)" 400
       '("POST / HTTP/1.1" "Host: x" "Transfer-Encoding: identity") END))))
