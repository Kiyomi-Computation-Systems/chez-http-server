#!r6rs
;;; (producers) — the producers the suites stream a response from.
;;;
;;; A producer is a response's body of unknown length: a procedure the server
;;; calls for each piece, which answers a bytevector, or the eof object at the
;;; end.  The stream, shell, contract and clients suites share these.  Each is
;;; made fresh by its caller, for the one response it streams.
;;;
;;; PURE apart from each producer's own count of what it has handed out.
(library (producers)
  (export producer-of sized-producer refilled-producer sized-body counted)
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

  ;; refilled-producer : Nat Nat -> (-> (U Bytevector Eof))
  ;; sized-producer's pieces, each handed out in the same bytevector,
  ;; refilled with the next letter at each call, as handlers.org lets a
  ;; producer do.
  (define (refilled-producer count size)
    (let ((made 0) (piece (make-bytevector size)))
      (lambda ()
        (if (= made count)
            (eof-object)
            (begin (bytevector-fill! piece (+ 97 (mod made 26)))
                   (set! made (+ made 1))
                   piece)))))

  ;; sized-body : Nat Nat -> String — the body sized-producer's pieces make,
  ;; and refilled-producer's.
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
