#!r6rs
;;; (http-server request) — the parsed HTTP request record (pure).
;;;
;;; The connection core builds a request from chez-httparse's callbacks.
;;; The request-target and every header name and value are spans of the
;;; delivery they arrived in, in wire order, kept without copying (see
;;; (http-server span)) — no percent-decoding, no case folding, no trimming
;;; happens here (the header library and uriparse own those).  The target
;;; has been judged one of RFC 9112 §3.2's forms before the request is built
;;; (see (http-server target)).  PURE: imports only (rnrs).
(library (http-server request)
  (export make-request request?
          request-method request-target
          request-http-major request-http-minor
          request-headers request-body)
  (import (rnrs))

  ;; make-request : Symbol Span Nat Nat Headers Body -> Request
  ;;   Symbol  = the method, as llhttp names it: GET, POST, M-SEARCH, ...
  ;;   Span    = the request-target, as it arrived
  ;;   Nat Nat = the HTTP major and minor version
  ;;   Headers = (Listof (Pair Span Span))      ; name . value, wire order
  ;;   Body    = Any                            ; #f: a handler reads a body through
  ;;                                            ; the reader it answers with, and
  ;;                                            ; the core builds every request
  ;;                                            ; with #f here
  ;; request? : Any -> Boolean
  ;; request-method : Request -> Symbol
  ;; request-target : Request -> Span
  ;; request-http-major : Request -> Nat
  ;; request-http-minor : Request -> Nat
  ;; request-headers : Request -> Headers
  ;; request-body : Request -> Body
  (define-record-type request
    (fields
      (immutable method      request-method)
      (immutable target      request-target)
      (immutable http-major  request-http-major)
      (immutable http-minor  request-http-minor)
      (immutable headers     request-headers)
      (immutable body        request-body))))
