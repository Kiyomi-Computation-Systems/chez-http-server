#!r6rs
;;; (http-server response) — the HTTP response record (pure).
;;;
;;; A handler answers a response; (http-server serializer) turns it into
;;; wire segments, and its `response-fault` names what one may not carry.
;;; The reason phrase and header names and values are raw bytevectors; a #f
;;; reason means "derive the canonical phrase from the status".  A body of
;;; unknown length is a producer, a procedure of no arguments the server
;;; calls for each piece, which answers a bytevector, or the eof object at
;;; the end, as `get-bytevector-some` does.  A body whose length is known but
;;; which is made as it is written, a file's, is a SIZED BODY: that length
;;; and a producer, `(sized-body n producer)`, sent with `Content-Length: n`.
;;; The server writes no byte past `n`, and asks the producer for no more
;;; once `n` are written.  PURE: imports only (rnrs).
(library (http-server response)
  (export make-response response?
          response-status response-reason
          response-headers response-body
          sized-body sized-body? sized-body-length sized-body-producer)
  (import (rnrs))

  ;; make-response : Nat (U Bytevector #f) Headers Body -> Response
  ;;   Nat     = the status code (e.g. 200)
  ;;   reason  = the reason-phrase bytes, or #f to derive from the status
  ;;   Headers = (Listof (Pair Bytevector Bytevector))  ; wire order
  ;;   Body    = (U Bytevector #f Producer SizedBody)  ; #f: none
  ;;   Producer = (-> (U Bytevector Eof))
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
      (immutable body     response-body)))

  ;; sized-body : Nat Producer -> SizedBody
  ;; A body of `n` bytes, made by `producer` as it is written.  A length that
  ;; is not a fixnum of 0 or more, or a producer that is not a procedure, is
  ;; an assertion violation.
  ;; sized-body? : Any -> Boolean
  ;; sized-body-length : SizedBody -> Nat
  ;; sized-body-producer : SizedBody -> Producer
  (define-record-type (sized sized-body sized-body?)
    (fields (immutable length   sized-body-length)
            (immutable producer sized-body-producer))
    (protocol
     (lambda (new)
       (lambda (n producer)
         (unless (and (fixnum? n) (fx>=? n 0))
           (assertion-violation 'sized-body "a length is a count of bytes, a fixnum" n))
         (unless (procedure? producer)
           (assertion-violation 'sized-body "a producer is a procedure" producer))
         (new n producer))))))
