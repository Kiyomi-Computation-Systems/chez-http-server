#!r6rs
;;; (sha256) — a byte-exact SHA-256 in pure R6RS.
;;;
;;; Decision 0007 vendors every corpus with a `sha256` per file; the harness's
;;; own fingerprint is a polynomial rolling hash explicitly "not for anything
;;; security relevant", so it cannot verify a sha256 manifest.  This can.  It is
;;; test-only support, imports only (rnrs), and is calibrated against FIPS 180-4
;;; vectors by every suite that uses it — an uncalibrated instrument measures
;;; nothing (design §8, decision 0008 item 4).
;;;
;;; Arithmetic is on exact integers masked to 32 bits, never native words; R6RS
;;; guarantees the range and `string-set!` is not in the base library, so the
;;; hex digest is built as a list.
(library (sha256)
  (export sha256-bytevector sha256-hex)
  (import (rnrs))

  (define mask32 #xffffffff)
  (define (u32 x) (bitwise-and x mask32))
  (define (rotr x n)
    (u32 (bitwise-ior (bitwise-arithmetic-shift-right x n)
                      (bitwise-arithmetic-shift-left x (- 32 n)))))
  (define (shr x n) (bitwise-arithmetic-shift-right x n))
  (define (ch x y z) (bitwise-xor (bitwise-and x y) (bitwise-and (bitwise-not x) z)))
  (define (maj x y z)
    (bitwise-xor (bitwise-and x y) (bitwise-and x z) (bitwise-and y z)))
  (define (bsig0 x) (bitwise-xor (rotr x 2) (rotr x 13) (rotr x 22)))
  (define (bsig1 x) (bitwise-xor (rotr x 6) (rotr x 11) (rotr x 25)))
  (define (ssig0 x) (bitwise-xor (rotr x 7) (rotr x 18) (shr x 3)))
  (define (ssig1 x) (bitwise-xor (rotr x 17) (rotr x 19) (shr x 10)))

  (define k
    (vector #x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
            #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
            #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
            #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
            #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
            #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
            #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
            #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
            #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
            #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
            #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

  (define h-init
    (vector #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
            #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))

  ;; pad : Bytevector -> Bytevector — the 0x80 terminator, zero fill to 56 mod
  ;; 64, then the message bit-length as a 64-bit big-endian integer.
  (define (pad msg)
    (let* ((len (bytevector-length msg))
           (bitlen (* len 8))
           (zeros (mod (- 56 (mod (+ len 1) 64)) 64))
           (total (+ len 1 zeros 8))
           (out (make-bytevector total 0)))
      (bytevector-copy! msg 0 out 0 len)
      (bytevector-u8-set! out len #x80)
      (let loop ((i 0))
        (when (< i 8)
          (bytevector-u8-set! out (- total 1 i)
                              (bitwise-and (bitwise-arithmetic-shift-right bitlen (* 8 i)) #xff))
          (loop (+ i 1))))
      out))

  (define (be-word bv i)
    (u32 (+ (bitwise-arithmetic-shift-left (bytevector-u8-ref bv i) 24)
            (bitwise-arithmetic-shift-left (bytevector-u8-ref bv (+ i 1)) 16)
            (bitwise-arithmetic-shift-left (bytevector-u8-ref bv (+ i 2)) 8)
            (bytevector-u8-ref bv (+ i 3)))))

  (define (copy-vector v)
    (let ((out (make-vector (vector-length v))))
      (do ((i 0 (+ i 1))) ((= i (vector-length v)) out)
        (vector-set! out i (vector-ref v i)))))

  ;; sha256-bytevector : Bytevector -> Bytevector (32 bytes)
  (define (sha256-bytevector msg)
    (let ((data (pad msg))
          (h (copy-vector h-init)))
      (let block-loop ((base 0))
        (if (>= base (bytevector-length data))
            (digest->bytevector h)
            (let ((w (make-vector 64 0)))
              (do ((t 0 (+ t 1))) ((= t 16))
                (vector-set! w t (be-word data (+ base (* t 4)))))
              (do ((t 16 (+ t 1))) ((= t 64))
                (vector-set! w t (u32 (+ (ssig1 (vector-ref w (- t 2)))
                                         (vector-ref w (- t 7))
                                         (ssig0 (vector-ref w (- t 15)))
                                         (vector-ref w (- t 16))))))
              (let loop ((t 0)
                         (a (vector-ref h 0)) (b (vector-ref h 1))
                         (c (vector-ref h 2)) (d (vector-ref h 3))
                         (e (vector-ref h 4)) (f (vector-ref h 5))
                         (g (vector-ref h 6)) (hh (vector-ref h 7)))
                (if (= t 64)
                    (begin
                      (vector-set! h 0 (u32 (+ (vector-ref h 0) a)))
                      (vector-set! h 1 (u32 (+ (vector-ref h 1) b)))
                      (vector-set! h 2 (u32 (+ (vector-ref h 2) c)))
                      (vector-set! h 3 (u32 (+ (vector-ref h 3) d)))
                      (vector-set! h 4 (u32 (+ (vector-ref h 4) e)))
                      (vector-set! h 5 (u32 (+ (vector-ref h 5) f)))
                      (vector-set! h 6 (u32 (+ (vector-ref h 6) g)))
                      (vector-set! h 7 (u32 (+ (vector-ref h 7) hh)))
                      (block-loop (+ base 64)))
                    (let* ((t1 (u32 (+ hh (bsig1 e) (ch e f g)
                                       (vector-ref k t) (vector-ref w t))))
                           (t2 (u32 (+ (bsig0 a) (maj a b c)))))
                      (loop (+ t 1)
                            (u32 (+ t1 t2)) a b c
                            (u32 (+ d t1)) e f g)))))))))

  (define (digest->bytevector h)
    (let ((out (make-bytevector 32)))
      (do ((i 0 (+ i 1))) ((= i 8) out)
        (let ((x (vector-ref h i)) (o (* i 4)))
          (bytevector-u8-set! out o (bitwise-and (bitwise-arithmetic-shift-right x 24) #xff))
          (bytevector-u8-set! out (+ o 1) (bitwise-and (bitwise-arithmetic-shift-right x 16) #xff))
          (bytevector-u8-set! out (+ o 2) (bitwise-and (bitwise-arithmetic-shift-right x 8) #xff))
          (bytevector-u8-set! out (+ o 3) (bitwise-and x #xff))))))

  (define hexd "0123456789abcdef")

  ;; sha256-hex : Bytevector -> String (64 lowercase hex chars)
  (define (sha256-hex msg)
    (let* ((d (sha256-bytevector msg)) (n (bytevector-length d)))
      (let loop ((i (- n 1)) (acc '()))
        (if (< i 0)
            (list->string acc)
            (let ((b (bytevector-u8-ref d i)))
              (loop (- i 1)
                    (cons (string-ref hexd (bitwise-arithmetic-shift-right b 4))
                          (cons (string-ref hexd (bitwise-and b #xf)) acc)))))))))
