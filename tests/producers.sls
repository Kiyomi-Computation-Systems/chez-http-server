#!r6rs
;;; (producers) — the producers the suites stream a response from (M6.3).
;;;
;;; A producer is a response's body of unknown length (decision 0013 item
;;; 8): a procedure the server calls for each piece, which answers a
;;; bytevector, or the eof object at the end.  The stream, shell, contract
;;; and clients suites share these, where five copies were (M6.3's review).
;;; Each is made fresh by its caller, for the one response it streams.
;;;
;;; PURE apart from each producer's own count of what it has handed out.
(library (producers)
  (export producer-of sized-producer sized-body counted)
  (import (rnrs))

  ;; producer-of : (Listof String) [(-> Any)] -> (-> Any)
  ;; A producer answering each text's bytes, UTF-8, in turn, then what
  ;; `last` answers each time it is called after: the eof object unless
  ;; given, or anything else a check wants a producer to answer, a raise
  ;; among them.
  (define producer-of
    (case-lambda
      ((texts) (producer-of texts eof-object))
      ((texts last)
       (let ((left texts))
         (lambda ()
           (if (null? left)
               (last)
               (let ((t (car left))) (set! left (cdr left)) (string->utf8 t))))))))

  ;; sized-producer : Nat Nat -> (-> (U Bytevector Eof))
  ;; `count` pieces of `size` bytes, the k-th filled with the k-th letter
  ;; (mod 26) from `a`, then the eof object.
  (define (sized-producer count size)
    (let ((made 0))
      (lambda ()
        (if (= made count)
            (eof-object)
            (let ((bv (make-bytevector size (+ 97 (mod made 26)))))
              (set! made (+ made 1))
              bv)))))

  ;; sized-body : Nat Nat -> String — the body sized-producer's pieces make.
  (define (sized-body count size)
    (let loop ((k 0) (acc '()))
      (if (= k count)
          (apply string-append (reverse acc))
          (loop (+ k 1) (cons (make-string size (integer->char (+ 97 (mod k 26)))) acc)))))

  ;; counted : (-> Any) -> (values (-> Any) (-> Nat))
  ;; The producer, and how many times it has been called.
  (define (counted producer)
    (let ((calls 0))
      (values (lambda () (set! calls (+ calls 1)) (producer))
              (lambda () calls)))))
