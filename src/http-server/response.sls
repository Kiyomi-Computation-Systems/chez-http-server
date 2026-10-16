#!r6rs
;;; (http-server response) — the HTTP response record (pure).
;;;
;;; A handler answers a response; (http-server serializer) turns it into
;;; wire segments, and its `response-fault` names what one may not carry.
;;; The reason phrase and header names and values are raw bytevectors; a #f
;;; reason means "derive the canonical phrase from the status".  A body of
;;; unknown length is a producer, a procedure of no arguments the server
;;; calls for each piece, which answers a bytevector, or the eof object at
;;; the end, as `get-bytevector-some` does.  PURE: imports only (rnrs).
(library (http-server response)
  (export make-response response?
          response-status response-reason
          response-headers response-body)
  (import (rnrs))

  ;; make-response : Nat (U Bytevector #f) Headers Body -> Response
  ;;   Nat     = the status code (e.g. 200)
  ;;   reason  = the reason-phrase bytes, or #f to derive from the status
  ;;   Headers = (Listof (Pair Bytevector Bytevector))  ; wire order
  ;;   Body    = (U Bytevector #f (-> (U Bytevector Eof)))  ; #f: none; a thunk: a producer
  ;; response? : Any -> Boolean
  ;; response-status : Response -> Nat
  ;; response-reason : Response -> (U Bytevector #f)
  ;; response-headers : Response -> Headers
  ;; response-body : Response -> Body
  (define-record-type response
    (fields
      (immutable status   response-status)
      (immutable reason   response-reason)
      (immutable headers  response-headers)
      (immutable body     response-body))))
