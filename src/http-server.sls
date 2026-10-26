#!r6rs
;;; (http-server) — the facade: what an embedder imports.
;;;
;;; A server is a handler, a procedure from a request to a response, given
;;; to `serve`:
;;;
;;;   (import (rnrs) (http-server))
;;;   (serve (lambda (request)
;;;            (make-response 200 #f '() (string->utf8 (request-path request)))))
;;;
;;; `serve` listens where CHEZ_HTTP_HOST and CHEZ_HTTP_PORT say, by default
;;; 127.0.0.1:8080, with the limits the other CHEZ_HTTP_ variables set, and
;;; logs a line for each thing that happens on standard output (see
;;; (http-server private serve)).  A handler reads the request through
;;; accessors that copy what it asks for, as strings, the method as the
;;; symbol llhttp names (see (http-server view)), and the version as the two
;;; numbers the request names: HTTP/1.2 reads 1 and 2, though the server
;;; answers it as HTTP/1.1.  It reads the connection's addresses too, each
;;; end's address and port, read once as the server accepted the connection,
;;; and #f where the server cannot say.  A request whose head announces a
;;; body, chunked or with a Content-Length above 0, which `request-has-body?`
;;; says without reading a header, reaches the handler once its head is in,
;;; and the handler reads the body by answering with a reader, `read-body`
;;; or `read-whole-body`; a response given instead is sent at once, and the
;;; connection closes after it (see (http-server body)).  The response is
;;; (http-server response)'s record, which the server frames; a body made as
;;; it is written is a producer, or, with its length declared, a sized body,
;;; sent with that Content-Length.  A handler
;;; that waits answers `(awaiting thunk)`: the server runs `thunk` on a
;;; coroutine of its own, and what it returns is the answer.  There it may
;;; wait with `await`, which hands a one-shot `resume` to whatever ends the
;;; wait, another handler's code among them; with `sleep-ms`; inside
;;; `with-deadline`, whose wait raises &deadline-passed once its time has
;;; passed; and with `resolve`, which looks a name up, or raises
;;; &resolve-error (see (http-server private waits)).  Once its client has
;;; closed or reset the connection, the wait it is in, or else its next,
;;; raises &client-closed, once.  There, before it answers, it may pull its
;;; body a piece at a time, `next-body-piece`, or read it through a port,
;;; `body-input-port`; a body that fails while pulled raises &body-failed,
;;; answered with its status if let out.  A handler takes a request that asks to
;;; switch protocols, an HTTP/1.1 upgrade with no body, by answering
;;; `(switch-protocols headers take-over)`: the server writes the 101 and
;;; then calls `take-over` with the stream, as a transport whose verbs
;;; write, read, close, arm a deadline and hear of the drain and the close,
;;; and the bytes it read past the request (see (http-server switch) and
;;; (http-server transport)).  A taker's tests make a fake with
;;; `make-transport`.  Code that holds a request may register a procedure
;;; with `request-on-done!`: the server calls it once, in place, when the
;;; request's response is done, with how it ended, `written`,
;;; `client-closed` or `failed` (see (http-server request)).  A malformed setting raises &http-server-config-error
;;; at startup.
;;;
;;; Each export's type, by the library that defines and documents it:
;;;
;;;   (http-server private serve)
;;;     serve : (Request -> (U Answer Switch)) [(String -> (U String #f))]
;;;             -> Void, Answer as (http-server awaiting) defines it
;;;     &http-server-error, an &error; &http-server-config-error, an
;;;       &http-server-error
;;;     http-server-error?, http-server-config-error? : Any -> Boolean
;;;   (http-server request) and (http-server view)
;;;     request? : Any -> Boolean
;;;     request-method : Request -> Symbol
;;;     request-http-major, request-http-minor : Request -> Nat
;;;     request-has-body? : Request -> Boolean
;;;     request-path, request-host : Request -> String
;;;     request-query : Request -> (U String #f)
;;;     request-header : Request String -> (U String #f)
;;;     request-header-values : Request String -> (Listof String)
;;;     request-header-list : Request -> (Listof (Pair String String))
;;;     request-remote-address, request-local-address : Request -> (U String #f)
;;;     request-remote-port, request-local-port : Request -> (U Nat #f)
;;;     request-on-done! : Request (Symbol -> Any) -> Void
;;;   (http-server body)
;;;     read-body : (Bytevector Nat Nat -> Any) (-> Response) -> BodyReader
;;;     read-whole-body : (Bytevector -> Response) [(U Nat #f)] -> BodyReader
;;;   (http-server response)
;;;     make-response : Nat (U Bytevector #f) Headers Body -> Response
;;;       Headers  = (Listof (Pair Bytevector Bytevector))
;;;       Body     = (U Bytevector #f Producer SizedBody)
;;;       Producer = (-> (U Bytevector Eof))
;;;     response? : Any -> Boolean
;;;     sized-body : Nat Producer -> SizedBody
;;;   (http-server awaiting)
;;;     awaiting : (-> Answer) -> Awaiting
;;;       Answer = (U Response BodyReader Awaiting)
;;;     &deadline-passed, &client-closed, &resolve-error, &body-failed, each
;;;       an &error
;;;     deadline-passed?, client-closed?, resolve-error?, body-failed? :
;;;       Any -> Boolean
;;;     resolve-error-reason : ResolveError -> Symbol
;;;     body-failed-reason : BodyFailed -> Symbol
;;;     body-failed-status : BodyFailed -> Nat
;;;   (http-server private waits)
;;;     await : ((Any -> Void) -> Any) -> Any
;;;     sleep-ms : Nat -> Void
;;;     with-deadline : Nat (-> (Values Any ...)) -> (Values Any ...)
;;;     resolve : String -> (Listof String)
;;;     next-body-piece : [(U Nat #f)] -> (U Bytevector Eof)
;;;     body-input-port : [(U Nat #f)] -> BinaryInputPort
;;;   (http-server switch)
;;;     switch-protocols : Headers (Transport Bytevector -> Any) -> Switch
;;;   (http-server transport)
;;;     make-transport : write read-start read-stop close deadline on-drain
;;;                      on-close [abort] -> Transport, each a procedure
;;;     transport? : Any -> Boolean
;;;     transport-write! :
;;;       Transport Bytevector [Nat Nat] [(U #f ((U #f Symbol) -> Any))] -> Any
;;;     transport-read-start! :
;;;       Transport (Bytevector Nat Nat -> Any) (Symbol -> Any) -> Any
;;;     transport-read-stop!, transport-close!, transport-abort! :
;;;       Transport -> Any
;;;     transport-deadline! : Transport (U Nat #f) [(-> Any)] -> Any
;;;     transport-on-drain!, transport-on-close! : Transport (-> Any) -> Any
;;;
;;; Nothing here names a libuv handle or verb: the shell owns every one
;;; (tests/test-exports.sps checks it).
(library (http-server)
  (export
    ;; the server
    serve
    ;; what a handler reads
    request? request-method request-path request-query request-header request-header-values
    request-header-list request-host request-http-major request-http-minor request-has-body?
    request-remote-address request-remote-port request-local-address request-local-port
    read-body read-whole-body
    ;; when its response is done
    request-on-done!
    ;; what it answers
    make-response response? sized-body awaiting switch-protocols
    ;; the stream a handler that takes an upgrade is handed
    make-transport transport? transport-write! transport-read-start! transport-read-stop!
    transport-close! transport-abort! transport-deadline! transport-on-drain! transport-on-close!
    ;; what a handler that waits waits with, and what a wait raises
    await sleep-ms with-deadline resolve
    &deadline-passed deadline-passed? &client-closed client-closed?
    &resolve-error resolve-error? resolve-error-reason
    ;; the body pulled by a handler that waits, and what a failed one raises
    next-body-piece body-input-port
    &body-failed body-failed? body-failed-reason body-failed-status
    ;; what a start raises
    &http-server-error http-server-error?
    &http-server-config-error http-server-config-error?)
  (import (only (http-server request) request? request-method request-http-major request-http-minor
                request-has-body? request-on-done!)
          (only (http-server view) request-path request-query request-header request-header-values
                request-header-list request-host
                request-remote-address request-remote-port request-local-address request-local-port)
          (only (http-server body) read-body read-whole-body)
          (only (http-server response) make-response response? sized-body)
          (only (http-server switch) switch-protocols)
          (http-server transport)
          (only (http-server awaiting) awaiting &deadline-passed deadline-passed?
                &client-closed client-closed? &resolve-error resolve-error? resolve-error-reason
                &body-failed body-failed? body-failed-reason body-failed-status)
          (only (http-server private waits) await sleep-ms with-deadline resolve
                next-body-piece body-input-port)
          (only (http-server private serve)
                serve
                &http-server-error http-server-error?
                &http-server-config-error http-server-config-error?)))
