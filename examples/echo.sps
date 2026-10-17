#!r6rs
;;; Reading a request: a GET is told what it asked for, and any request with
;;; a body gets that body back, with the same Content-Type.
;;;
;;;   make run PROGRAM=examples/echo.sps
;;;   curl 'http://127.0.0.1:8080/some/path?x=1'
;;;   curl --data-binary @README.org -H 'Content-Type: text/plain' http://127.0.0.1:8080/
(import (rnrs) (http-server))

;; latin-1 : Transcoder — a request's strings hold one byte per character.
(define latin-1 (make-transcoder (latin-1-codec)))

;; header : String String -> (Pair Bytevector Bytevector)
(define (header name value)
  (cons (string->utf8 name) (string->bytevector value latin-1)))

;; describe : Request -> Bytevector — "METHOD PATH[?QUERY]" and a newline.
(define (describe request)
  (let ((query (request-query request)))
    (string->utf8 (string-append (symbol->string (request-method request)) " "
                                 (request-path request)
                                 (if query (string-append "?" query) "")
                                 "\n"))))

(serve
 (lambda (request)
   (if (memq (request-method request) '(GET HEAD))
       (make-response 200 #f '() (describe request))
       ;; Answer with a reader to read the body: here, whole, up to 1 MiB.
       (read-whole-body
        (lambda (body)
          (let ((type (request-header request "content-type")))
            (make-response 200 #f (if type (list (header "Content-Type" type)) '()) body)))))))
