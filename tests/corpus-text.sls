#!r6rs
;;; (corpus-text) — the few string helpers the corpus readers share: the
;;; guardian, Kestrel, httpd and lighttpd readers and (provenance).  M8.3
;;; (step 2's review: one copy, not six).  Pure (rnrs).
(library (corpus-text)
  (export prefix? suffix? split trim strip-cr find-sub find-sub-from index-of last-pair)
  (import (rnrs))

  ;; prefix? : String String -> Boolean — `s` begins with `p`.
  (define (prefix? p s)
    (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

  ;; suffix? : String String -> Boolean — `s` ends with `suf`.
  (define (suffix? suf s)
    (let ((n (string-length s)) (m (string-length suf)))
      (and (>= n m) (string=? (substring s (- n m) n) suf))))

  ;; split : String Char -> (Listof String) — the parts between each `ch`,
  ;; empty ones kept.
  (define (split s ch)
    (let ((n (string-length s)))
      (let loop ((i 0) (start 0) (acc '()))
        (cond ((= i n) (reverse (cons (substring s start n) acc)))
              ((char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
              (else (loop (+ i 1) start acc))))))

  ;; trim : String -> String — whitespace off both ends.
  (define (trim s)
    (let* ((n (string-length s))
           (start (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
           (end (let loop ((i n)) (if (and (> i start) (char-whitespace? (string-ref s (- i 1)))) (loop (- i 1)) i))))
      (substring s start end)))

  ;; strip-cr : String -> String — a line's one trailing CR off.
  (define (strip-cr s)
    (let ((n (string-length s)))
      (if (and (> n 0) (char=? (string-ref s (- n 1)) #\return)) (substring s 0 (- n 1)) s)))

  ;; find-sub : String String -> (U Nat #f) — where `sub` first begins.
  (define (find-sub s sub) (find-sub-from s sub 0))

  ;; find-sub-from : String String Nat -> (U Nat #f) — the same, from `from`.
  (define (find-sub-from s sub from)
    (let ((n (string-length s)) (m (string-length sub)))
      (let loop ((i from))
        (cond ((> (+ i m) n) #f) ((string=? (substring s i (+ i m)) sub) i) (else (loop (+ i 1)))))))

  ;; index-of : String Char -> (U Nat #f) — where `ch` first is.
  (define (index-of s ch)
    (let loop ((i 0))
      (cond ((= i (string-length s)) #f) ((char=? (string-ref s i) ch) i) (else (loop (+ i 1))))))

  ;; last-pair : (Listof a) -> (Listof a) — the last pair of a non-empty list.
  (define (last-pair xs) (if (null? (cdr xs)) xs (last-pair (cdr xs)))))
