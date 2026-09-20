#!r6rs
;;; (http-server request) — the parsed HTTP request record (pure).
;;;
;;; The connection core (M2) builds a request from chez-httparse's
;;; callbacks; M0 only fixes its shape.  The request-target and every
;;; header name and value are kept as raw bytevectors in wire order — no
;;; percent-decoding, no case folding, no trimming happens here (the
;;; header library and uriparse own those).  PURE: imports only (rnrs).
(library (http-server request)
  (export make-request request?
          request-method request-target
          request-http-major request-http-minor
          request-headers request-body)
  (import (rnrs))

  ;; make-request : Method Bytevector Nat Nat Headers Body -> Request
  ;;   Method  = (U Symbol Fixnum Bytevector)  ; the method token/number (fixed in M2)
  ;;   target  = the raw request-target bytes
  ;;   Nat Nat = the HTTP major and minor version
  ;;   Headers = (Listof (Pair Bytevector Bytevector))  ; wire order
  ;;   Body    = Any                            ; a body handle in M6; #f until then
  ;; request? : Any -> Boolean
  ;; request-method / -target / -http-major / -http-minor / -headers / -body :
  ;;   Request -> the corresponding field
  (define-record-type request
    (fields
      (immutable method      request-method)
      (immutable target      request-target)
      (immutable http-major  request-http-major)
      (immutable http-minor  request-http-minor)
      (immutable headers     request-headers)
      (immutable body        request-body))))
