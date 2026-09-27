#!r6rs
;;; (http-server host) — RFC 9112 §3.2's Host rules, over the head's kept
;;; fields (pure).
;;;
;;; "A server MUST respond with a 400 (Bad Request) status code to any
;;; HTTP/1.1 request message that lacks a Host header field and to any request
;;; message that contains more than one Host header field line or a Host header
;;; field with an invalid field value."  Decided on the owner's word,
;;; 2026-09-25 (the ledger's Host entry):
;;;
;;;   - more than one Host line is refused, in any version;
;;;   - no Host on HTTP/1.1 is refused unless the caller's switch is off
;;;     (decision 0005's amendment of 2026-09-25, CHEZ_HTTP_REQUIRE_HOST);
;;;   - a value that is not RFC 9110 §7.2's `uri-host [ ":" port ]` is
;;;     refused: uriparse's `validate-authority` judges it as an RFC 3986
;;;     authority, and one with userinfo, which an authority allows and a Host
;;;     does not, is refused here.  An empty value is valid, and what it means
;;;     is M4's (RFC 9112 §3.3).
;;;
;;; The value is judged without the OWS around it (RFC 9112 §5; 2026-09-27),
;;; in place, in the bytevector the parser delivered, by uriparse's ranged
;;; forms (v0.6.0, uriparse #24): nothing is copied, and nothing outside the
;;; value is read.  Every verdict is data.
;;; PURE: imports (rnrs), (http-server span), (http-server headers) and
;;; (uri host).
(library (http-server host)
  (export host-fault)
  (import (rnrs)
          (http-server span)
          (only (http-server headers) header-name=? trim-ows)
          (only (uri host) validate-authority authority-host-span))

  (define HOST (string->utf8 "host"))

  ;; host-fault : (Listof (Pair Span Span)) Nat Nat Boolean -> (U #f Symbol)
  ;;   fields http-major http-minor require?
  ;; #f when the request's Host lines are what RFC 9112 §3.2 asks; otherwise
  ;; what is wrong: 'duplicate-host, 'missing-host (HTTP/1.1, and only when
  ;; `require?`), uriparse's error code for the value, or 'host-userinfo.
  ;; `fields` are the head's (name . value) spans, in any order.
  (define (host-fault fields http-major http-minor require?)
    (let loop ((fields fields) (value #f))
      (cond
       ((pair? fields)
        (if (header-name=? (caar fields) HOST)
            (if value 'duplicate-host (loop (cdr fields) (cdar fields)))
            (loop (cdr fields) value)))
       (value (value-fault value))
       ((and require? (fx=? http-major 1) (fx>=? http-minor 1)) 'missing-host)
       (else #f))))

  ;; value-fault : Span -> (U #f Symbol)
  ;; uriparse's verdict on the value as an authority, then the userinfo rule:
  ;; an authority carries userinfo exactly when its host begins after an "@",
  ;; by `(uri host)`'s own split, whose bounds are relative to the value.
  ;; Only uriparse's code is read, never the index it gives beside it.  The
  ;; value is the span without the OWS around it (RFC 9112 §5): llhttp leaves
  ;; out the OWS before a value but keeps the OWS after it.
  (define (value-fault value)
    (let ((bv (span-bytevector value)))
      (let-values (((start end) (trim-ows bv (span-start value) (span-end value))))
        (let-values (((code index) (validate-authority bv start end)))
          (cond (code code)
                ((let-values (((host-start host-end) (authority-host-span bv start end)))
                   (fx>? host-start 0))
                 'host-userinfo)
                (else #f)))))))
