#!r6rs
;;; (http-server request) — the parsed HTTP request record (pure).
;;;
;;; The connection core builds a request from chez-httparse's callbacks.
;;; The request-target and every header name and value are spans of the
;;; delivery they arrived in, in wire order, kept without copying (see
;;; (http-server span)) — no percent-decoding, no case folding, no trimming
;;; happens here (the header library and uriparse own those).  The target
;;; has been judged one of RFC 9112 §3.2's forms before the request is built
;;; (see (http-server target)).
;;;
;;; WHEN ITS RESPONSE IS DONE.  A request also keeps the procedures its code
;;; registers with `request-on-done!`, each told once how the response ended:
;;; `written`, every write of the handler's response completed;
;;; `client-closed`, the client closed or reset the connection first;
;;; `failed`, the server ended it itself.  The core marks the request done
;;; with `request-done!`, which hands the procedures back for the shell to
;;; call, and a procedure registered after that is called at once.  The slot
;;; holds '() while the response is under way, then the procedures, newest
;;; first, then the symbol the response ended with, so nothing it held is
;;; kept once it is done.  PURE: imports only (rnrs).
(library (http-server request)
  (export make-request request?
          request-method request-target
          request-http-major request-http-minor
          request-headers request-has-body?
          request-on-done! request-done!)
  (import (rnrs))

  ;; make-request : Symbol Span Nat Nat Headers Boolean -> Request
  ;;   Symbol  = the method, as llhttp names it: GET, POST, M-SEARCH, ...
  ;;   Span    = the request-target, as it arrived
  ;;   Nat Nat = the HTTP major and minor version
  ;;   Headers = (Listof (Pair Span Span))      ; name . value, wire order
  ;;   Boolean = whether the framing announces a body, as the core decides
  ;;             it: chunked, or a Content-Length above 0 (RFC 9112 §6.3).
  ;;             A handler reads the body through the reader it answers with.
  ;; A request is made with its response under way, nothing registered.
  ;; request? : Any -> Boolean
  ;; request-method : Request -> Symbol
  ;; request-target : Request -> Span
  ;; request-http-major : Request -> Nat
  ;; request-http-minor : Request -> Nat
  ;; request-headers : Request -> Headers
  ;; request-has-body? : Request -> Boolean
  (define-record-type request
    (fields
      (immutable method      request-method)
      (immutable target      request-target)
      (immutable http-major  request-http-major)
      (immutable http-minor  request-http-minor)
      (immutable headers     request-headers)
      (immutable has-body?   request-has-body?)
      (mutable   done        request-done-slot request-done-slot-set!))
    (protocol
     (lambda (new)
       (lambda (method target http-major http-minor headers has-body?)
         (new method target http-major http-minor headers has-body? '())))))

  ;; request-on-done! : Request (Symbol -> Any) -> Void
  ;; Register `proc` to be called once with how the request's response ended:
  ;; `written`, `client-closed` or `failed`.  The server calls the procedures
  ;; registered in reverse order of registration, in place, so each must be
  ;; quick and cannot wait.  Once the response is done, `proc` is called at
  ;; once, here, and its raise is the caller's.  Anything but a procedure is
  ;; an assertion violation.
  (define (request-on-done! r proc)
    (unless (procedure? proc)
      (assertion-violation 'request-on-done! "not a procedure" proc))
    (let ((done (request-done-slot r)))
      (if (symbol? done)
          (proc done)
          (request-done-slot-set! r (cons proc done))))
    (if #f #f))

  ;; request-done! : Request Symbol -> (Listof (Symbol -> Any))
  ;; Mark the request's response done, as `how` says, and hand back the
  ;; procedures registered, newest first, to be called with it; '() once it
  ;; is done already, so each is handed back once.  The core calls it.  A
  ;; `how` other than `written`, `client-closed` or `failed` is an assertion
  ;; violation.
  (define (request-done! r how)
    (unless (memq how '(written client-closed failed))
      (assertion-violation 'request-done! "not how a response ends" how))
    (let ((done (request-done-slot r)))
      (if (symbol? done)
          '()
          (begin (request-done-slot-set! r how) done)))))
