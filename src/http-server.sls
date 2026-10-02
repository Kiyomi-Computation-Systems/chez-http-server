#!r6rs
;;; (http-server) — the facade: what an embedder imports (decision 0001).
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
;;; accessors that copy what it asks for, as strings, and the method as the
;;; symbol llhttp names (decision 0012; see (http-server view)).  A request
;;; whose head announces a body reaches the handler once its head is in, and
;;; the handler reads the body by answering with a reader, `read-body` or
;;; `read-whole-body`; a response given instead is sent at once, and the
;;; connection closes after it (decision 0013; see (http-server body)).  The
;;; response is (http-server response)'s record, which the server frames
;;; (decision 0010).  A handler that waits answers `(awaiting thunk)`: the
;;; server runs `thunk` on a coroutine of its own, and what it returns is the
;;; answer (decision 0014).  There it may wait with `await`, which hands a
;;; one-shot `resume` to whatever ends the wait, another handler's code
;;; among them; with `sleep-ms`; inside `with-deadline`, whose wait raises
;;; &deadline-passed once its time has passed; and with `resolve`, which
;;; looks a name up, or raises &resolve-error (decision 0015; see
;;; (http-server private waits)).  A malformed setting raises
;;; &http-server-config-error at startup (design §6.4).
;;;
;;; Nothing here names a libuv handle or verb: the shell owns every one
;;; (decision 0003; tests/test-exports.sps).
(library (http-server)
  (export
    ;; the server
    serve
    ;; what a handler reads
    request? request-method request-path request-query request-header request-host
    read-body read-whole-body
    ;; what it answers
    make-response response? awaiting
    ;; what a handler that waits waits with, and what a wait raises
    await sleep-ms with-deadline resolve
    &deadline-passed deadline-passed?
    &resolve-error resolve-error? resolve-error-reason
    ;; what a start raises
    &http-server-error http-server-error?
    &http-server-config-error http-server-config-error?)
  (import (only (http-server request) request? request-method)
          (only (http-server view) request-path request-query request-header request-host)
          (only (http-server body) read-body read-whole-body)
          (only (http-server response) make-response response?)
          (only (http-server awaiting) awaiting &deadline-passed deadline-passed?
                &resolve-error resolve-error? resolve-error-reason)
          (only (http-server private waits) await sleep-ms with-deadline resolve)
          (only (http-server private serve)
                serve
                &http-server-error http-server-error?
                &http-server-config-error http-server-config-error?)))
