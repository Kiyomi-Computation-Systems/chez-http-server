#!r6rs
;;; M0 exit: a program importing all four libraries at once runs.  This wires
;;; the ledger's smoke template through the harness so `make test` covers it —
;;; chez-libuv, chez-httparse (generated parser + decisions + methods),
;;; byte-machine (transitive) and uriparse, all on the one library path.
(import (rnrs) (srfi :64) (testing)
        (libuv)                          ; chez-libuv v0.7.1
        (generated httparse-message)     ; chez-httparse v0.4.3 (generated parser)
        (httparse decisions)             ; chez-httparse v0.4.3
        (httparse methods)               ; chez-httparse v0.4.3
        (byte-machine runtime)           ; byte-machine v0.6.1 (transitive)
        (uri collect)                    ; uriparse v0.6.1
        (uri components))                ; uriparse v0.6.1

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
