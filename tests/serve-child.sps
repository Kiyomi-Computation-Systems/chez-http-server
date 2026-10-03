#!r6rs
;;; A program that serves, for tests/test-serve.sps to run as a process of its
;;; own: `serve` itself, its loop and all, which no suite can run in place,
;;; since it returns only when the server stops.  It listens on 127.0.0.1,
;;; the kernel's choice of port, which `serve` logs on standard output, and
;;; answers every request 200, "served", but two.  `/wait` writes the line
;;; `handling` on standard output and reads the request's body, answering
;;; "waited" at its end: the request stays in flight until the suite sends
;;; the body.  `/long` writes `holding`, then waits a minute, which the
;;; drain's deadline, 2 s, cuts short.  It serves until it is killed, or
;;; until a signal's drain ends and `serve` returns (M8.1), when it exits 0;
;;; started with the argument `sigint-after`, it first sends itself SIGINT,
;;; and runs on a while, so that were a keyboard interrupt handled, it would
;;; be.  Its lookup is its own, so the environment the suite runs in sets
;;; nothing here.  Run on the project's library path.
(import (rnrs) (http-server) (only (libuv) uv-kill! uv-os-getpid))

;; said : String -> Void — the line, on standard output, at once.
(define (said line)
  (put-string (current-output-port) line)
  (newline (current-output-port))
  (flush-output-port (current-output-port)))

(serve (lambda (request)
         (cond ((string=? (request-path request) "/wait")
                (said "handling")
                (read-body (lambda (bv start end) #t)
                           (lambda () (make-response 200 #f '() (string->utf8 "waited")))))
               ((string=? (request-path request) "/long")
                (said "holding")
                (awaiting (lambda () (sleep-ms 60000) (make-response 200 #f '() (string->utf8 "late")))))
               (else (make-response 200 #f '() (string->utf8 "served")))))
       (lambda (name)
         (cond ((string=? name "CHEZ_HTTP_HOST") "127.0.0.1")
               ((string=? name "CHEZ_HTTP_PORT") "0")
               ((string=? name "CHEZ_HTTP_DRAIN_TIMEOUT") "2")
               (else #f))))
(when (member "sigint-after" (command-line))
  (uv-kill! (uv-os-getpid) 'sigint)
  (let spin ((i 0)) (when (< i 50000000) (spin (+ i 1)))))
(exit 0)
