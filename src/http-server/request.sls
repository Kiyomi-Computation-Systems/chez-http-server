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
;;; kept once it is done.
;;;
;;; A request also holds the ADDRESSES of the connection it came on: the
;;; remote end's address and port, and the local end's, the one the
;;; connection came in on.  The shell reads them once, as it adopts the
;;; connection, and every request on it holds the one record.  Each is #f
;;; where the server cannot say.  PURE: imports only (rnrs).
(library (http-server request)
  (export make-request request?
          request-method request-target
          request-http-major request-http-minor
          request-headers request-has-body? request-addresses
          request-on-done! request-done!
          make-addresses addresses? no-addresses
          addresses-remote-address addresses-remote-port
          addresses-local-address addresses-local-port)
  (import (rnrs))

  ;; make-addresses : (U String #f) (U Nat #f) (U String #f) (U Nat #f) -> Addresses
  ;;   the remote end's address and port, then the local end's: an address
  ;;   is text, such as "192.0.2.7" or "::1", and a port is from 0 to
  ;;   65535; #f where the server cannot say.  A port is kept only beside
  ;;   its address: given with none, it is #f.  Anything else is an
  ;;   assertion violation.
  ;; addresses? : Any -> Boolean
  ;; addresses-remote-address, addresses-local-address : Addresses -> (U String #f)
  ;; addresses-remote-port, addresses-local-port : Addresses -> (U Nat #f)
  (define-record-type (addresses make-addresses addresses?)
    (fields (immutable remote-address addresses-remote-address)
            (immutable remote-port addresses-remote-port)
            (immutable local-address addresses-local-address)
            (immutable local-port addresses-local-port))
    (protocol
     (lambda (new)
       (lambda (remote-address remote-port local-address local-port)
         (for-each (lambda (address)
                     (unless (or (not address) (string? address))
                       (assertion-violation 'make-addresses "not an address, a string or #f" address)))
                   (list remote-address local-address))
         (for-each (lambda (port)
                     (unless (or (not port) (and (fixnum? port) (fx<=? 0 port 65535)))
                       (assertion-violation 'make-addresses "not a port, from 0 to 65535, or #f" port)))
                   (list remote-port local-port))
         (new remote-address (and remote-address remote-port)
              local-address (and local-address local-port))))))

  ;; no-addresses : Addresses — #f for all four: a connection whose shell
  ;; gave it none.
  (define no-addresses (make-addresses #f #f #f #f))

  ;; make-request : Symbol Span Nat Nat Headers Boolean [Addresses] -> Request
  ;;   Symbol    = the method, as llhttp names it: GET, POST, M-SEARCH, ...
  ;;   Span      = the request-target, as it arrived
  ;;   Nat Nat   = the HTTP major and minor version, each from 0 to 255, as
  ;;               llhttp reads them; anything else is an assertion violation
  ;;   Headers   = (Listof (Pair Span Span))      ; name . value, wire order
  ;;   Boolean   = whether the framing announces a body, as the core decides
  ;;               it: chunked, or a Content-Length above 0 (RFC 9112 §6.3).
  ;;               A handler reads the body through the reader it answers with.
  ;;   Addresses = the connection's, no-addresses unless given
  ;; A request is made with its response under way, nothing registered.  Its
  ;; version is kept as one number, the major times 256 plus the minor, so a
  ;; request is a record of seven fields.
  ;; request? : Any -> Boolean
  ;; request-method : Request -> Symbol
  ;; request-target : Request -> Span
  ;; request-headers : Request -> Headers
  ;; request-has-body? : Request -> Boolean
  ;; request-addresses : Request -> Addresses
  (define-record-type request
    (fields
      (immutable method      request-method)
      (immutable target      request-target)
      (immutable version     request-version)
      (immutable headers     request-headers)
      (immutable has-body?   request-has-body?)
      (mutable   done        request-done-slot request-done-slot-set!)
      (immutable addresses   request-addresses))
    (protocol
     (lambda (new)
       (define (make method target http-major http-minor headers has-body? addresses)
         (for-each (lambda (n)
                     (unless (and (fixnum? n) (fx<=? 0 n 255))
                       (assertion-violation 'make-request "not a version number, from 0 to 255" n)))
                   (list http-major http-minor))
         (new method target (fxior (fxarithmetic-shift-left http-major 8) http-minor)
              headers has-body? '() addresses))
       (case-lambda
         ((method target http-major http-minor headers has-body?)
          (make method target http-major http-minor headers has-body? no-addresses))
         ((method target http-major http-minor headers has-body? addresses)
          (make method target http-major http-minor headers has-body? addresses))))))

  ;; request-http-major : Request -> Nat
  ;; request-http-minor : Request -> Nat
  ;; Anything but a request is an assertion violation, under each one's name.
  (define (request-http-major r)
    (unless (request? r) (assertion-violation 'request-http-major "not a request" r))
    (fxarithmetic-shift-right (request-version r) 8))
  (define (request-http-minor r)
    (unless (request? r) (assertion-violation 'request-http-minor "not a request" r))
    (fxand (request-version r) 255))

  ;; request-on-done! : Request (Symbol -> Any) -> Void
  ;; Register `proc` to be called once with how the request's response ended:
  ;; `written`, `client-closed` or `failed`.  The server calls the procedures
  ;; registered in reverse order of registration, on no coroutine, so each
  ;; must be quick and cannot wait.  Once the response is done, `proc` is
  ;; called at once, here, and its raise is the caller's.  Anything but a
  ;; procedure is an assertion violation.
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
