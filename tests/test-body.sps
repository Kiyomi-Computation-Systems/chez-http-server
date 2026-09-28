#!r6rs
;;; (http-server body): the readers a handler answers with.  M6.1.
;;;
;;; Decision 0013: a handler answers a request whose framing announces a body
;;; with a response or a reader.  `read-body` streams: the server calls its
;;; `on-piece` with each piece of the body, then its `on-end`, once, for the
;;; response.  `read-whole-body` buffers: the core copies the body into one
;;; bytevector and hands it over as the reader's only piece, and the
;;; procedure is called with it.  Past its cap, 1 MiB unless one is given,
;;; the core answers 413; the reader only carries the cap.
;;;
;;; Oracles: decision 0013 items 2 and 6, and decision 0005's
;;; `max-body-bytes` row, whose buffering helper takes 1 MiB, 1,048,576 B;
;;; the bytes each check hands the reader.
(import (rnrs) (srfi :64) (testing)
        (http-server body))

(define (b s) (string->utf8 s))

;; verdict : (-> Any) -> (U 'accepted 'refused)
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (thunk)
    'accepted))

;; answered : BodyReader (Listof (List Bytevector Nat Nat)) -> Any
;; What the reader answers once handed `pieces` in order, then its end.
(define (answered reader pieces)
  (for-each (lambda (p) (apply (body-reader-on-piece reader) p)) pieces)
  ((body-reader-on-end reader)))

(run-suite "body"
  (lambda ()
    ;; --- read-body: the handler's own procedures, no cap ---------------------
    (let* ((on-piece (lambda (bv start end) 'piece))
           (on-end (lambda () 'response))
           (r (read-body on-piece on-end)))
      (test-equal "read-body is a streaming reader of the two procedures, with no cap of its own"
                  '(#t #t #t #f #f)
                  (list (body-reader? r)
                        (eq? on-piece (body-reader-on-piece r))
                        (eq? on-end (body-reader-on-end r))
                        (body-reader-max-bytes r)
                        (body-reader-whole? r))))

    ;; --- read-whole-body: the cap, 1 MiB unless given --------------------------
    (let ((proc (lambda (body) body)))
      (test-equal "read-whole-body buffers, capped at 1 MiB, 1,048,576 B, by default"
                  '(#t #t 1048576)
                  (let ((r (read-whole-body proc)))
                    (list (body-reader? r) (body-reader-whole? r) (body-reader-max-bytes r))))
      (test-equal "a cap given is the reader's, and #f gives it none"
                  '(4096 #f)
                  (list (body-reader-max-bytes (read-whole-body proc 4096))
                        (body-reader-max-bytes (read-whole-body proc #f)))))

    ;; --- read-whole-body: what its procedure is called with -------------------
    ;; The core hands a whole reader one piece, the body in a bytevector of
    ;; its own, which the procedure gets as it is.  A piece that is part of a
    ;; bytevector is copied, and no piece at all is an empty body (decision
    ;; 0013 item 6).
    (let ((whole (b "{\"a\":\"hello\"}")))
      (test-eq "the body handed over whole is the bytevector the procedure gets, not a copy"
               whole
               (answered (read-whole-body (lambda (body) body))
                         (list (list whole 0 (bytevector-length whole))))))
    (test-equal "a piece that is part of its bytevector is copied, exactly its bytes"
                (b "hello")
                (let ((bv (b "xxhelloyy")))
                  (answered (read-whole-body (lambda (body) body)) (list (list bv 2 7)))))
    (test-equal "no piece at all: the procedure gets an empty body"
                (make-bytevector 0)
                (answered (read-whole-body (lambda (body) body)) '()))
    (test-equal "its procedure's answer is the reader's"
                '(response 5)
                (answered (read-whole-body (lambda (body) (list 'response (bytevector-length body))))
                          (list (list (b "hello") 0 5))))

    ;; --- what a reader is made of -------------------------------------------------
    (test-equal "a reader is made of procedures, and a cap that is #f or a count"
                '(accepted refused refused refused refused accepted refused refused)
                (map verdict
                     (list (lambda () (read-body (lambda (bv s e) #t) (lambda () #t)))
                           (lambda () (read-body 'piece (lambda () #t)))
                           (lambda () (read-body (lambda (bv s e) #t) 'end))
                           (lambda () (read-whole-body 'proc))
                           (lambda () (read-whole-body (lambda (body) body) -1))
                           (lambda () (read-whole-body (lambda (body) body) 0))
                           (lambda () (read-whole-body (lambda (body) body) 1.5))
                           (lambda () (read-whole-body (lambda (body) body) 'many)))))))
