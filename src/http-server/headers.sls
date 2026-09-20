#!r6rs
;;; (http-server headers) — pure operations on header lists.
;;;
;;; A header list is an association list of (name . value) bytevector
;;; pairs in wire order.  Field-name comparison is ASCII case-insensitive
;;; (RFC 9110 §5.1).  Values are kept as raw bytes; no decoding here.
;;; PURE: imports only (rnrs).
(library (http-server headers)
  (export header-name=? headers-ref headers-ref-all)
  (import (rnrs))

  ;; ascii-downcase-byte : Octet -> Octet — fold A-Z to a-z, others unchanged.
  (define (ascii-downcase-byte b)
    (if (and (>= b 65) (<= b 90)) (+ b 32) b))

  ;; header-name=? : Bytevector Bytevector -> Boolean
  ;; ASCII case-insensitive equality of two field names.
  (define (header-name=? a b)
    (let ((n (bytevector-length a)))
      (and (= n (bytevector-length b))
           (let loop ((i 0))
             (or (= i n)
                 (and (= (ascii-downcase-byte (bytevector-u8-ref a i))
                         (ascii-downcase-byte (bytevector-u8-ref b i)))
                      (loop (+ i 1))))))))

  ;; headers-ref : (Listof (Pair Bytevector Bytevector)) Bytevector
  ;;               -> (U Bytevector #f)
  ;; The value of the first field whose name matches `name`, or #f.
  (define (headers-ref headers name)
    (cond ((null? headers) #f)
          ((header-name=? (caar headers) name) (cdar headers))
          (else (headers-ref (cdr headers) name))))

  ;; headers-ref-all : (Listof (Pair Bytevector Bytevector)) Bytevector
  ;;                   -> (Listof Bytevector)
  ;; Every matching value, in wire order.
  (define (headers-ref-all headers name)
    (let loop ((hs headers) (acc '()))
      (cond ((null? hs) (reverse acc))
            ((header-name=? (caar hs) name)
             (loop (cdr hs) (cons (cdar hs) acc)))
            (else (loop (cdr hs) acc))))))
