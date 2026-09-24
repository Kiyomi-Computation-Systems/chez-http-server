#!r6rs
;;; (http-server headers) — pure operations on header lists.
;;;
;;; A header list is an association list of (name . value) pairs in wire
;;; order.  A name or value is a bytevector or a span of one: the connection
;;; core builds a request's headers as spans of the delivery (design §7.1),
;;; and a handler may build a response's from bytevectors.  Field-name
;;; comparison is ASCII case-insensitive (RFC 9110 §5.1).  Values are kept as
;;; raw bytes; no decoding here.  PURE: imports only (rnrs) and
;;; (http-server span).
(library (http-server headers)
  (export header-name=? headers-ref headers-ref-all)
  (import (rnrs) (http-server span))

  ;; Bytes = (U Bytevector Span)

  ;; ascii-downcase-byte : Octet -> Octet — fold A-Z to a-z, others unchanged.
  (define (ascii-downcase-byte b)
    (if (and (>= b 65) (<= b 90)) (+ b 32) b))

  ;; bytes-vector / -start / -end : Bytes -> the bytevector and the bounds of
  ;; the bytes it names; a bytevector names all of itself.
  (define (bytes-vector x) (if (span? x) (span-bytevector x) x))
  (define (bytes-start x) (if (span? x) (span-start x) 0))
  (define (bytes-end x) (if (span? x) (span-end x) (bytevector-length x)))

  ;; header-name=? : Bytes Bytes -> Boolean
  ;; ASCII case-insensitive equality of two field names.
  (define (header-name=? a b)
    (let ((av (bytes-vector a)) (as (bytes-start a)) (ae (bytes-end a))
          (bv (bytes-vector b)) (bs (bytes-start b)) (be (bytes-end b)))
      (and (= (- ae as) (- be bs))
           (let loop ((i as) (j bs))
             (or (= i ae)
                 (and (= (ascii-downcase-byte (bytevector-u8-ref av i))
                         (ascii-downcase-byte (bytevector-u8-ref bv j)))
                      (loop (+ i 1) (+ j 1))))))))

  ;; headers-ref : (Listof (Pair Bytes Bytes)) Bytes -> (U Bytes #f)
  ;; The value of the first field whose name matches `name`, or #f.
  (define (headers-ref headers name)
    (cond ((null? headers) #f)
          ((header-name=? (caar headers) name) (cdar headers))
          (else (headers-ref (cdr headers) name))))

  ;; headers-ref-all : (Listof (Pair Bytes Bytes)) Bytes -> (Listof Bytes)
  ;; Every matching value, in wire order.
  (define (headers-ref-all headers name)
    (let loop ((hs headers) (acc '()))
      (cond ((null? hs) (reverse acc))
            ((header-name=? (caar hs) name)
             (loop (cdr hs) (cons (cdar hs) acc)))
            (else (loop (cdr hs) acc))))))
