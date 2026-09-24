#!r6rs
;;; (http-server span) — the bytes [start, end) of a bytevector, kept without
;;; copying (pure).
;;;
;;; The parser hands the core bounds into the delivery the shell read, and
;;; copies nothing (chez-httparse, docs/api.org).  A delivery is a fresh Scheme
;;; bytevector that chez-libuv copied out of its read buffer, so holding a span
;;; of it is safe for as long as the span is held (design §7.1).  The request's
;;; target and header names and values are spans, which is how the head costs
;;; the same whatever the length of what it keeps (0002's second amendment).
;;; A span pins its whole delivery; copy it with `span->bytevector` to keep
;;; the bytes without the delivery.  PURE: imports only (rnrs).
(library (http-server span)
  (export make-span span? span-bytevector span-start span-end span-length
          span->bytevector)
  (import (rnrs))

  ;; make-span : Bytevector Nat Nat -> Span
  ;; The bytes [start, end) of `bv`.  Bounds outside `bv` are an assertion
  ;; violation.
  ;; span? : Any -> Boolean
  ;; span-bytevector / -start / -end : Span -> the corresponding field
  (define-record-type span
    (fields (immutable bytevector span-bytevector)
            (immutable start span-start)
            (immutable end span-end))
    (protocol
     (lambda (new)
       (lambda (bv start end)
         (unless (and (bytevector? bv)
                      (fixnum? start) (fixnum? end)
                      (fx<=? 0 start end (bytevector-length bv)))
           (assertion-violation 'make-span "not a span of the bytevector" start end))
         (new bv start end)))))

  ;; span-length : Span -> Nat
  (define (span-length s) (fx- (span-end s) (span-start s)))

  ;; span->bytevector : Span -> Bytevector
  ;; A fresh copy of the span's bytes.
  (define (span->bytevector s)
    (let ((out (make-bytevector (span-length s))))
      (bytevector-copy! (span-bytevector s) (span-start s) out 0 (span-length s))
      out)))
