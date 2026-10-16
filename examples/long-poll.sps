#!r6rs
;;; Waiting: GET /wait holds its answer until someone sends a message with
;;; POST /send, then answers with that message.  A wait that hears nothing
;;; for 30 seconds is answered 504, and a client that leaves is forgotten.
;;;
;;;   make run PROGRAM=examples/long-poll.sps
;;;   curl http://127.0.0.1:8080/wait                  # in one terminal
;;;   curl --data 'hello' http://127.0.0.1:8080/send   # in another
(import (rnrs) (http-server))

;; The waits in progress: each is the `resume` its `await` handed out.
(define waiting '())

;; text : Nat String -> Response
(define (text status s)
  (make-response status #f (list (cons (string->utf8 "Content-Type") (string->utf8 "text/plain")))
                 (string->utf8 s)))

;; wait-for-a-message : -> Response
;; Runs on a coroutine of its own (see `awaiting` below), where it may wait.
(define (wait-for-a-message)
  (let ((mine #f))
    (guard (e ((deadline-passed? e)
               (set! waiting (remq mine waiting))
               (text 504 "no message came\n"))
              ((client-closed? e)
               (set! waiting (remq mine waiting))
               (raise e)))
      (with-deadline 30000
        (lambda ()
          (make-response 200 #f '()
                         (await (lambda (resume)
                                  (set! mine resume)
                                  (set! waiting (cons resume waiting))))))))))

;; send! : Bytevector -> Response — wake every wait with `message`.
(define (send! message)
  (let ((woken waiting))
    (set! waiting '())
    (for-each (lambda (resume) (resume message)) woken)
    (text 200 (string-append "woke " (number->string (length woken)) "\n"))))

(serve
 (lambda (request)
   (let ((path (request-path request)))
     (cond ((and (string=? path "/wait") (eq? (request-method request) 'GET))
            (awaiting wait-for-a-message))
           ((and (string=? path "/send") (eq? (request-method request) 'POST))
            (read-whole-body send! 65536))
           (else (text 404 "GET /wait, or POST /send with a message\n"))))))
