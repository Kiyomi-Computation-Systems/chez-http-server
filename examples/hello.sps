#!r6rs
;;; The smallest server: every request gets "Hello".
;;;
;;;   make run PROGRAM=examples/hello.sps
;;;   curl http://127.0.0.1:8080/
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (make-response 200 #f '() (string->utf8 "Hello\n"))))
