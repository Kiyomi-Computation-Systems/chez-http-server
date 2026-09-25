#!r6rs
;;; The libhtp lane: our expectations for libhtp's pipelining and multi-packet
;;; streams (design §8.2).  The M2 exit.
;;;
;;; The scope is what the streams carry, not their names (the owner's word,
;;; 2026-09-25): every stream whose client packets hold two or more requests,
;;; or one request split across packets.  A plain strict request parser counts
;;; that over all 102 streams, so a stream that carries either with no
;;; expectation is red, and so is an expectation for one that carries
;;; neither.  Then each of those streams must meet its expectation, from
;;; (libhtp-lane).
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list)
        (libhtp-corpus) (libhtp-lane)
        (httparse test adapter)          ; adapter-trace-names
        (generated httparse-message) (httparse modes) (byte-machine runtime))

(define files-dir "test/vendor/libhtp/files")

;; suffix? : String String -> Boolean
(define (suffix? suf s)
  (let ((n (string-length s)) (m (string-length suf)))
    (and (>= n m) (string=? (substring s (- n m) n) suf))))

;; packets : String -> (Listof Bytevector)
;; A stream's client chunks, in order.
(define (packets name)
  (map cdr (filter (lambda (c) (eq? (car c) 'client))
                   (libhtp-parse-stream
                    (call-with-port (open-file-input-port (string-append files-dir "/" name))
                      get-bytevector-all)))))

;; carries? : String -> Boolean
;; #t when the stream's client packets, fed one by one to a strict request
;; parser that continues at every callback, complete two or more messages, or
;; complete one that began in an earlier packet.  The count stops at the
;; parser's first pause or error.
(define (carries? name)
  (let* ((packet 0) (began #f) (messages '())
         (p (make-parser
             httparse-message-machine
             (map (lambda (row)
                    (list (car row)
                          (case (car row)
                            ((on-message-begin)
                             (lambda (p ctx) (set! began packet) callback-continue))
                            ((on-message-complete)
                             (lambda (p ctx)
                               (set! messages (cons (cons began packet) messages))
                               callback-continue))
                            (else (if (eq? (cadr row) 'span)
                                      (lambda (p ctx bv from to) callback-continue)
                                      (lambda (p ctx) callback-continue))))))
                  adapter-trace-names)
             #f (list (cons 'type (httparse-message-type-value 'request))))))
    (let loop ((ps (packets name)))
      (when (pair? ps)
        (let ((r (parser-feed! p (car ps) 0 (bytevector-length (car ps)))))
          (when (eq? (parser-result-status r) 'need-input)
            (set! packet (+ packet 1))
            (loop (cdr ps))))))
    (or (>= (length messages) 2)
        (exists (lambda (m) (not (= (car m) (cdr m)))) messages))))

;; carrying-files : -> (Listof String) — the streams that carry either, by
;; name, in file-name order.
(define (carrying-files)
  (filter carries?
          (list-sort string<? (filter (lambda (f) (suffix? ".t" f)) (directory-list files-dir)))))

(run-suite "libhtp-lane"
  (lambda ()
    (test-eqv "twelve streams have an expectation" 12 (length libhtp-expected-files))
    (test-equal "the streams that carry pipelining or a split request are the ones with one"
                libhtp-expected-files (carrying-files))
    (for-each (lambda (name)
                (test-equal (string-append name " meets its expectation")
                            (libhtp-expectation name) (libhtp-outcome name)))
              libhtp-expected-files)))
