#!r6rs
;;; Integration smoke: a program importing all four dependencies at once runs —
;;; chez-libuv, chez-httparse (generated parser + decisions + methods),
;;; byte-machine (transitive) and uriparse, all on the one library path.
(import (rnrs) (srfi :64) (testing)
        (libuv)                          ; chez-libuv v0.11.0
        (generated httparse-message)     ; chez-httparse v0.4.5 (generated parser)
        (httparse decisions)             ; chez-httparse v0.4.5
        (httparse methods)               ; chez-httparse v0.4.5
        (byte-machine runtime)           ; byte-machine v0.7.0 (transitive)
        (uri collect)                    ; uriparse v0.6.2
        (uri components))                ; uriparse v0.6.2

(run-suite "integration"
  (lambda ()
    ;; chez-libuv: a loop can be created and torn down (verbs resolve and run)
    (let ((loop (make-uv-loop)))
      (test-eq "libuv loop created" 'ok (if loop 'ok 'no))
      (uv-loop-teardown! loop))

    ;; byte-machine <-> the generated parser interoperate
    (test-eq "httparse machine is compiled" 'machine
             (if (compiled-machine? httparse-message-machine) 'machine 'no))

    ;; chez-httparse decisions/methods resolve and agree with llhttp
    (test-eq  "keep-alive HTTP/1.1 no-close" 'alive
              (if (should-keep-alive? 1 1 'request 0 0) 'alive 'dead))
    (test-eqv "GET method number" 1 (httparse-method-number 'GET))

    ;; uriparse validates a clean absolute URI
    (let ((r (uri-parse-validate 'uri (string->utf8 "http://example.com/p?q=1"))))
      (test-eq "uri-parse-validate accepts a clean URI" 'ok
               (if (uri-parse-ok? r) 'ok 'no)))))
