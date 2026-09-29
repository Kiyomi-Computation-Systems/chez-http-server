#!r6rs
;;; (http-server response) — the HTTP response record (pure).
;;;
;;; A handler yields a response; the serializer (M3) turns it into wire
;;; segments.  M0 only fixes its shape.  The reason phrase and header
;;; names and values are raw bytevectors; a #f reason means "derive the
;;; canonical phrase from the status" (M3).  A body of unknown length is a
;;; producer, a procedure of no arguments the server calls for each piece,
;;; which answers a bytevector, or the eof object at the end, as
;;; `get-bytevector-some` does (M6.3; decision 0013 item 8).  PURE: imports
;;; only (rnrs).
(library (http-server response)
  (export make-response response?
          response-status response-reason
          response-headers response-body)
  (import (rnrs))

  ;; make-response : Nat (U Bytevector #f) Headers Body -> Response
  ;;   Nat     = the status code (e.g. 200)
  ;;   reason  = the reason-phrase bytes, or #f to derive from the status (M3)
  ;;   Headers = (Listof (Pair Bytevector Bytevector))  ; wire order
  ;;   Body    = (U Bytevector #f (-> (U Bytevector Eof)))  ; a producer (M6.3)
  ;; response? : Any -> Boolean
  ;; response-status / -reason / -headers / -body : Response -> the field
  (define-record-type response
    (fields
      (immutable status   response-status)
      (immutable reason   response-reason)
      (immutable headers  response-headers)
      (immutable body     response-body))))
