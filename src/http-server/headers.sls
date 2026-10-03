#!r6rs
;;; (http-server headers) — pure operations on header lists.
;;;
;;; A header list is an association list of (name . value) pairs in wire
;;; order.  A name or value is a bytevector or a span of one: the connection
;;; core builds a request's headers as spans of the delivery (design §7.1),
;;; and a handler may build a response's from bytevectors.  Field-name
;;; comparison is ASCII case-insensitive (RFC 9110 §5.1).  Values are kept as
;;; raw bytes; no decoding here.  The byte helpers a value's list is read with
;;; are here too: OWS (RFC 9110 §5.6.3), and a range compared with a token
;;; without regard to case, each reading the bytes in place; and whether a
;;; field's list holds a token (§5.6.1), which the core asks of a request's
;;; Expect (M6.4); and a field's elements, which the serializer reads a
;;; switch's Upgrade with (M8.2).  PURE: imports only (rnrs) and (http-server
;;; span).
(library (http-server headers)
  (export header-name=? headers-ref headers-ref-all ows? trim-ows range-ci=? field-lists?
          field-elements)
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

  ;; ranges-ci=? : Bytevector Nat Nat Bytevector Nat Nat -> Boolean
  ;; av[as, ae) and bv[bs, be) hold the same bytes, without regard to ASCII
  ;; case.
  (define (ranges-ci=? av as ae bv bs be)
    (and (= (- ae as) (- be bs))
         (let loop ((i as) (j bs))
           (or (= i ae)
               (and (= (ascii-downcase-byte (bytevector-u8-ref av i))
                       (ascii-downcase-byte (bytevector-u8-ref bv j)))
                    (loop (+ i 1) (+ j 1)))))))

  ;; header-name=? : Bytes Bytes -> Boolean
  ;; ASCII case-insensitive equality of two field names.
  (define (header-name=? a b)
    (ranges-ci=? (bytes-vector a) (bytes-start a) (bytes-end a)
                 (bytes-vector b) (bytes-start b) (bytes-end b)))

  ;; range-ci=? : Bytevector Nat Nat Bytevector -> Boolean
  ;; bv[from, to) is `token`, all of it, without regard to ASCII case.
  (define (range-ci=? bv from to token)
    (ranges-ci=? bv from to token 0 (bytevector-length token)))

  ;; ows? : Octet -> Boolean — SP or HTAB, optional whitespace (RFC 9110
  ;; §5.6.3).
  (define (ows? c) (or (= c 32) (= c 9)))

  ;; trim-ows : Bytevector Nat Nat -> (values Nat Nat)
  ;; The bounds of bv[from, to) without the OWS at either end.  A range of
  ;; OWS alone trims to the empty range at its end.
  (define (trim-ows bv from to)
    (let* ((start (let loop ((i from))
                    (if (and (< i to) (ows? (bytevector-u8-ref bv i))) (loop (+ i 1)) i)))
           (end (let loop ((i to))
                  (if (and (> i start) (ows? (bytevector-u8-ref bv (- i 1)))) (loop (- i 1)) i))))
      (values start end)))

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
            (else (loop (cdr hs) acc)))))

  ;; field-lists? : (Listof (Pair Bytes Bytes)) Bytes Bytevector -> Boolean
  ;; Whether a field named `name` lists `token`: whether an element of the
  ;; comma-separated list in one of its values, the OWS around it trimmed,
  ;; is `token`, all of it, without regard to ASCII case (RFC 9110 §5.6.1).
  ;; A list may run over several lines, each a field of the name, in any
  ;; order.  An empty element is none.  Values are read in place, and
  ;; nothing is allocated.
  (define (field-lists? headers name token)
    (and (pair? headers)
         (or (and (header-name=? (caar headers) name)
                  (let ((v (cdar headers)))
                    (lists? (bytes-vector v) (bytes-start v) (bytes-end v) token)))
             (field-lists? (cdr headers) name token))))

  ;; lists? : Bytevector Nat Nat Bytevector -> Boolean
  ;; Whether the list in bv[start, end) has the element `token`.
  (define (lists? bv start end token)
    (let loop ((i start))
      (and (fx<=? i end)
           (let ((comma (find-comma bv i end)))
             (let-values (((from to) (trim-ows bv i comma)))
               (or (range-ci=? bv from to token)
                   (loop (fx+ comma 1))))))))

  ;; field-elements : (Listof (Pair Bytes Bytes)) Bytes -> (Listof Bytevector)
  ;; The elements of the comma-separated lists in every field named `name`,
  ;; in wire order, the OWS around each trimmed, each a copy of its own; an
  ;; empty element is none (RFC 9110 §5.6.1).  Where field-lists? asks after
  ;; one token and allocates nothing, this hands each element over.
  (define (field-elements headers name)
    (let fields ((hs headers) (acc '()))
      (cond ((null? hs) (reverse acc))
            ((header-name=? (caar hs) name)
             (let* ((v (cdar hs)) (bv (bytes-vector v)) (end (bytes-end v)))
               (let each ((i (bytes-start v)) (acc acc))
                 (if (fx>? i end)
                     (fields (cdr hs) acc)
                     (let ((comma (find-comma bv i end)))
                       (let-values (((from to) (trim-ows bv i comma)))
                         (each (fx+ comma 1)
                               (if (fx=? from to) acc (cons (copy-range bv from to) acc)))))))))
            (else (fields (cdr hs) acc)))))

  ;; copy-range : Bytevector Nat Nat -> Bytevector — a copy of bv[from, to).
  (define (copy-range bv from to)
    (let ((out (make-bytevector (fx- to from))))
      (bytevector-copy! bv from out 0 (fx- to from))
      out))

  ;; find-comma : Bytevector Nat Nat -> Nat — the first comma in [i, end), or end.
  (define (find-comma bv i end)
    (if (or (fx=? i end) (fx=? (bytevector-u8-ref bv i) 44)) i (find-comma bv (fx+ i 1) end))))
