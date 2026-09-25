#!r6rs
;; chez-httparse v0.4.1 (9bc669c; #47 via PR #48, release PR #49), measured at
;; the pin before the server reads it, 2026-09-25.  v0.4.1 documents the
;; `upgrade` field as llhttp's `llhttp_get_upgrade`: "1 if this message
;; upgrades", written just before on-headers-complete.  Its generated parser
;; is byte-identical to v0.4.0's, so this measures what the server will rely
;; on, not a change:
;;
;;   (1) Over the strict request fixtures (type exactly "request"), fed whole
;;       and a byte at a time and resumed past every pause, the field read at
;;       each on-headers-complete equals llhttp's rule for a request, CONNECT
;;       (method 5) or both upgrade bits.  The rule is transcribed here, from
;;       llhttp's `llhttp__before_headers_complete` (src/native/http.c), so
;;       that this spike keeps its oracle once the server stops carrying one.
;;   (2) The fixtures where the field is 1 are exactly the ones whose llhttp
;;       logs record "Pause on CONNECT/Upgrade".
;;
;; Run on the project's library path (the Makefile's LIBDIRS).
(import (rnrs)
        (httparse test adapter) (httparse test corpus-load) (httparse test corpus-decode)
        (only (httparse decisions) F-UPGRADE F-CONNECTION-UPGRADE)
        (only (trace-lane) strict-request-fixtures)
        (generated httparse-message) (httparse modes) (byte-machine runtime))
(define (rule method flags)
  (or (= method 5)
      (let ((both (bitwise-ior F-UPGRADE F-CONNECTION-UPGRADE)))
        (= (bitwise-and flags both) both))))
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) sub) (loop (+ i 1)))))))
;; A request parser whose callbacks all continue; on-headers-complete first
;; runs `headers` on the parser.
(define (request-parser headers)
  (make-parser httparse-message-machine
               (map (lambda (row)
                      (list (car row)
                            (cond ((eq? (car row) 'on-headers-complete)
                                   (lambda (p ctx) (headers p) callback-continue))
                                  ((eq? (cadr row) 'span) (lambda (p ctx bv from to) callback-continue))
                                  (else (lambda (p ctx) callback-continue)))))
                    adapter-trace-names)
               #f (list (cons 'type (httparse-message-type-value 'request)))))
;; Deliveries of `size` bytes ('whole: one), resumed past every pause, to the
;; end or the first error.
(define (feed-all! p bv size)
  (let ((len (bytevector-length bv)))
    (let loop ((at 0))
      (when (< at len)
        (let* ((to (if (eq? size 'whole) len (min len (+ at size))))
               (r (parser-feed! p bv at to)))
          (case (parser-result-status r)
            ((need-input) (loop to))
            ((paused) (parser-resume! p) (loop (parser-result-next r)))
            (else #f)))))))
(define logged
  (map car (filter (lambda (pr)
                     (exists (lambda (line) (contains? (expectation-text line) "Pause on CONNECT/Upgrade"))
                             (fixture-expected (cdr pr))))
                   strict-request-fixtures)))
(define (run size)
  (let ((reads 0) (disagree 0) (marked '()))
    (for-each
     (lambda (pr)
       (let* ((hit #f)
              (p (request-parser
                  (lambda (p)
                    (let ((field (parser-field-ref p 'upgrade)))
                      (set! reads (+ reads 1))
                      (unless (eq? (= field 1) (rule (parser-field-ref p 'method)
                                                     (parser-field-ref p 'flags)))
                        (set! disagree (+ disagree 1)))
                      (when (= field 1) (set! hit #t)))))))
         (feed-all! p (corpus-decode-input (fixture-input-text (cdr pr))) size)
         (when hit (set! marked (cons (car pr) marked)))))
     strict-request-fixtures)
    (list 'size size 'on-headers-complete-reads reads 'field-vs-rule-disagreements disagree
          'field-is-1-in (length marked) 'same-as-logged (equal? (reverse marked) logged))))
(write (list 'strict-fixtures (length strict-request-fixtures))) (newline)
(write (list 'logged-upgrades (length logged) logged)) (newline)
(write (run 'whole)) (newline)
(write (run 1)) (newline)
