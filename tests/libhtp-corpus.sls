#!r6rs
;;; (libhtp-corpus) — load a vendored libhtp `.t` connection stream.
;;;
;;; libhtp's test/files/*.t files interleave a client and an origin's bytes with
;;; packet markers: a line `>>>` opens a client chunk, `<<<` opens a server
;;; chunk, and the chunk runs to the line before the next marker.  This is a
;;; byte-faithful port of libhtp's own test.c chunker (test_is_boundary /
;;; test_next_chunk), so the bytes we deliver are the bytes libhtp delivers:
;;;
;;;   - a chunk is the bytes after its marker line up to the `\n` that precedes
;;;     the next marker (or EOF); that separating `\n` is not part of the chunk,
;;;     and ONE `\r` immediately before it is stripped (test.c's "remove one
;;;     '\r'");
;;;   - an empty chunk (a marker immediately followed by another marker) is
;;;     skipped, as test.c sets chunk = NULL and continues;
;;;   - the final chunk runs to EOF with no separator stripped.
;;;
;;; The vendored corpus uses only `>>>`/`<<<`; libhtp's gap variants (`><>`,
;;; `<><`) appear in none of the 102 files, so a line where a marker is expected
;;; that is not exactly `>>>` or `<<<` is REFUSED rather than guessed at (libhtp
;;; is archived and will not add one).  The loader only splits streams: no HTTP
;;; is parsed here, and the `<<<` chunks are a recorded origin's replies, not an
;;; oracle.
(library (libhtp-corpus)
  (export libhtp-parse-stream
          libhtp-parse-error? libhtp-parse-error-detail)
  (import (rnrs))

  ;; libhtp-parse-error? : Any -> Boolean — a stream was refused.
  ;; libhtp-parse-error-detail : LibhtpParseError -> String — why: the offset
  ;; where a marker was expected.
  (define-condition-type &libhtp-parse &error
    make-libhtp-parse-error libhtp-parse-error? (detail libhtp-parse-error-detail))

  (define (refuse detail)
    (raise (condition (make-libhtp-parse-error detail)
                      (make-who-condition 'libhtp-parse-stream)
                      (make-message-condition detail))))

  (define (u8 bv i) (bytevector-u8-ref bv i))

  ;; marker-at : Bytevector Nat Nat -> (U 'client 'server #f)
  ;; A `>>>`/`<<<` marker at `pos` followed by `\n` or `\r\n`, with room for it.
  (define (marker-at bv pos len)
    (and (< (+ pos 3) len)
         (let ((b0 (u8 bv pos)) (b1 (u8 bv (+ pos 1)))
               (b2 (u8 bv (+ pos 2))) (b3 (u8 bv (+ pos 3))))
           (define (nl-ok?)
             (or (= b3 10)
                 (and (= b3 13) (< (+ pos 4) len) (= (u8 bv (+ pos 4)) 10))))
           (cond ((and (= b0 62) (= b1 62) (= b2 62) (nl-ok?)) 'client)   ; >>>
                 ((and (= b0 60) (= b1 60) (= b2 60) (nl-ok?)) 'server)   ; <<<
                 (else #f)))))

  (define (slice bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  ;; libhtp-parse-stream : Bytevector -> (Listof (Pair (U 'client 'server) Bytevector))
  ;; The chunks in file order.  Refuses a stream that does not begin with a
  ;; marker, or any position where a marker is expected but not found.
  (define (libhtp-parse-stream bv)
    (let ((len (bytevector-length bv)))
      (let loop ((pos 0) (acc '()))
        (if (>= pos len)
            (reverse acc)
            (let ((dir (marker-at bv pos len)))
              (unless dir
                (refuse (string-append "expected a >>> or <<< marker at offset "
                                       (number->string pos))))
              (let* ((after3 (+ pos 3))
                     (start (if (= (u8 bv after3) 13) (+ after3 2) (+ after3 1))))
                (cond
                 ((>= start len) (reverse acc))           ; marker with nothing after it
                 ((marker-at bv start len) (loop start acc)) ; empty chunk: skip
                 (else
                  (let scan ((p start))
                    (cond
                     ((>= p len)                          ; last chunk runs to EOF
                      (reverse (cons (cons dir (slice bv start len)) acc)))
                     ((and (= (u8 bv p) 10) (marker-at bv (+ p 1) len))
                      (let ((end (if (and (> p start) (= (u8 bv (- p 1)) 13)) (- p 1) p)))
                        (loop (+ p 1) (cons (cons dir (slice bv start end)) acc))))
                     (else (scan (+ p 1))))))))))))) )
