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
;;; symbol llhttp names (decision 0012; see (http-server view)).  The
;;; response is (http-server response)'s record, which the server frames
;;; (decision 0010).  A malformed setting raises
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
    ;; what it answers
    make-response response?
    ;; what a start raises
    &http-server-error http-server-error?
    &http-server-config-error http-server-config-error?)
  (import (only (http-server request) request? request-method)
          (only (http-server view) request-path request-query request-header request-host)
          (only (http-server response) make-response response?)
          (only (http-server private serve)
                serve
                &http-server-error http-server-error?
                &http-server-config-error http-server-config-error?)))
