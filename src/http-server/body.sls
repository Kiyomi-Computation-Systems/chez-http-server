#!r6rs
;;; (http-server body) — the readers a handler answers with (pure).
;;;
;;; A request whose framing announces a body, chunked or a Content-Length
;;; above 0, is handed to the handler once its head has arrived, before any of
;;; its body.  The handler answers a response, or a READER, and the server
;;; hands the reader the body:
;;;
;;;   (read-body on-piece on-end)     streams: `on-piece` is called with each
;;;                                   piece of the body as it arrives, as `bv
;;;                                   start end`, then `on-end`, once, which
;;;                                   gives the response;
;;;   (read-whole-body proc)          buffers: `proc` is called with the whole
;;;   (read-whole-body proc max)      body in one bytevector, and gives the
;;;                                   response.  Past `max` bytes, 1 MiB
;;;                                   unless given, the server answers 413.
;;;
;;; A piece is a span of the read it arrived in, never copied: a reader that
;;; keeps one keeps that read, up to read-buffer-size bytes, so what it keeps
;;; it copies.  A whole reader is handed its body by the core, which copies
;;; the pieces into one bytevector as they arrive, grown to the Content-Length
;;; or joined when chunked, and hands it over as the reader's only piece, once
;;; the body has ended; a reader of a request with no body is handed no piece.
;;; The reader carries its cap; the core enforces it, and the server's own,
;;; CHEZ_HTTP_MAX_BODY_BYTES, each answered 413.
;;;
;;; PURE: imports only (rnrs).
(library (http-server body)
  (export make-body-reader body-reader?
          body-reader-on-piece body-reader-on-end body-reader-max-bytes body-reader-whole?
          read-body read-whole-body)
  (import (rnrs))

  ;; make-body-reader :
  ;;   (Bytevector Nat Nat -> Any) (-> Response) (U Nat #f) Boolean -> BodyReader
  ;;   on-piece  called with each piece of the body, a span `bv start end`
  ;;   on-end    called once the body has ended; gives the response
  ;;   max-bytes the reader's cap, or #f for none of its own
  ;;   whole?    whether the core buffers the body and hands it over whole
  ;; Procedures that are not, or a cap that is neither #f nor a count, are an
  ;; assertion violation.
  ;; body-reader? : Any -> Boolean
  ;; body-reader-on-piece : BodyReader -> (Bytevector Nat Nat -> Any)
  ;; body-reader-on-end : BodyReader -> (-> Response)
  ;; body-reader-max-bytes : BodyReader -> (U Nat #f)
  ;; body-reader-whole? : BodyReader -> Boolean
  (define-record-type (body-reader make-body-reader body-reader?)
    (fields (immutable on-piece  body-reader-on-piece)
            (immutable on-end    body-reader-on-end)
            (immutable max-bytes body-reader-max-bytes)
            (immutable whole?    body-reader-whole?))
    (protocol
     (lambda (new)
       (lambda (on-piece on-end max-bytes whole?)
         (unless (and (procedure? on-piece) (procedure? on-end))
           (assertion-violation 'make-body-reader "a reader is made of procedures" on-piece on-end))
         (unless (or (not max-bytes) (and (integer? max-bytes) (exact? max-bytes) (>= max-bytes 0)))
           (assertion-violation 'make-body-reader "a cap is #f or a count of bytes" max-bytes))
         (new on-piece on-end max-bytes (and whole? #t))))))

  ;; read-body : (Bytevector Nat Nat -> Any) (-> Response) -> BodyReader
  ;; A reader that streams the body to `on-piece`, then answers `(on-end)`.
  (define (read-body on-piece on-end)
    (make-body-reader on-piece on-end #f #f))

  ;; The buffering helper's default cap: 1 MiB.
  (define whole-body-cap 1048576)

  ;; read-whole-body : (Bytevector -> Response) [(U Nat #f)] -> BodyReader
  ;; A reader that answers `(proc body)`, the body whole, capped at `max-bytes`
  ;; (1 MiB unless given; #f leaves only the server's cap).  The core hands it
  ;; the body as one piece: kept as it is when the piece is the whole of its
  ;; bytevector, as the core makes it, and copied otherwise.  No piece is an
  ;; empty body.
  (define read-whole-body
    (case-lambda
      ((proc) (read-whole-body proc whole-body-cap))
      ((proc max-bytes)
       (unless (procedure? proc)
         (assertion-violation 'read-whole-body "not a procedure" proc))
       (let ((body #f))
         (make-body-reader
          (lambda (bv start end)
            (set! body (if (and (fx=? start 0) (fx=? end (bytevector-length bv)))
                           bv
                           (let ((out (make-bytevector (fx- end start))))
                             (bytevector-copy! bv start out 0 (fx- end start))
                             out))))
          (lambda () (proc (or body (make-bytevector 0))))
          max-bytes
          #t))))))
