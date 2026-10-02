#!r6rs
;;; A program that serves, for tests/test-serve.sps to run as a process of its
;;; own: `serve` itself, its loop and all, which no suite can run in place,
;;; since it returns only when the server stops.  It listens on 127.0.0.1,
;;; the kernel's choice of port, which `serve` logs on standard output, and
;;; answers every request 200, "served", until it is killed.  Its lookup is
;;; its own, so the environment the suite runs in sets nothing here.  Run on
;;; the project's library path.
(import (rnrs) (http-server))

(serve (lambda (request) (make-response 200 #f '() (string->utf8 "served")))
       (lambda (name)
         (cond ((string=? name "CHEZ_HTTP_HOST") "127.0.0.1")
               ((string=? name "CHEZ_HTTP_PORT") "0")
               (else #f))))
(exit 0)
