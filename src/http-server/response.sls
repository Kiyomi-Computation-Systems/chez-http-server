#!r6rs
;;; (http-server response) — the HTTP response record (pure).
;;;
;;; A handler yields a response; the serializer (M3) turns it into wire
;;; segments.  M0 only fixes its shape.  The reason phrase and header
;;; names and values are raw bytevectors; a #f reason means "derive the
;;; canonical phrase from the status" (M3).  PURE: imports only (rnrs).
(library (http-server response)
  (export make-response response?
          response-status response-reason
          response-headers response-body)
  (import (rnrs))

  ;; make-response : Nat (U Bytevector #f) Headers Body -> Response
  ;;   Nat     = the status code (e.g. 200)
  ;;   reason  = the reason-phrase bytes, or #f to derive from the status (M3)
  ;;   Headers = (Listof (Pair Bytevector Bytevector))  ; wire order
  ;;   Body    = (U Bytevector #f)  ; segments/streaming arrive in M3/M6
  ;; response? : Any -> Boolean
  ;; response-status / -reason / -headers / -body : Response -> the field
  (define-record-type response
    (fields
      (immutable status   response-status)
      (immutable reason   response-reason)
      (immutable headers  response-headers)
      (immutable body     response-body))))
