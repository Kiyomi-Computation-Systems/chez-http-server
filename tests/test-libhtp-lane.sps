#!r6rs
;;; The libhtp lane: our expectations for libhtp's pipelining and multi-packet
;;; streams, its two Expect streams, and its early-response stream answered at
;;; the head too, as its recorded origin answered it.
;;;
;;; The scope is what the streams carry, not their names: every stream whose
;;; client packets hold two or more requests, or one request split across
;;; packets.  The robustness lane adds libhtp's invalid streams and its
;;; HTTP/0.9 streams, which are found by name.  A plain strict request parser
;;; counts what the streams carry over all 102 streams, as the lane delivers
;;; them, so a stream that carries either with no expectation is red, and so
;;; is an expectation for one that carries neither.  Then each of those
;;; streams must meet its expectation, from (libhtp-lane).  And a stream whose
;;; run raises is a mismatch that says what it raised, never a raise out of
;;; `libhtp-mismatch`, which the ratchet calls outside any check.
;;;
;;; The two Expect streams end their lines in a bare LF, which the strict
;;; parser refuses at the first line, so the lane delivers them with CRLF: as
;;; delivered, each carries a request split across packets.  Every other
;;; stream is delivered as libhtp's chunker cuts it, which is checked here, and
;;; so is the conversion: the two delivered have no bare LF left, and with
;;; their CRs taken out they are the chunks as cut, which have none.
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

;; cut : String -> (Listof Bytevector)
;; A stream's client chunks, in order, as libhtp's chunker cuts them.
(define (cut name)
  (map cdr (filter (lambda (c) (eq? (car c) 'client))
                   (libhtp-parse-stream
                    (call-with-port (open-file-input-port (string-append files-dir "/" name))
                      get-bytevector-all)))))

;; bare-lf? : Bytevector -> Boolean — whether an LF follows no CR.
(define (bare-lf? bv)
  (let loop ((i 0))
    (and (< i (bytevector-length bv))
         (or (and (= (bytevector-u8-ref bv i) 10)
                  (not (and (> i 0) (= (bytevector-u8-ref bv (- i 1)) 13))))
             (loop (+ i 1))))))

;; without-cr : Bytevector -> Bytevector — every CR taken out.
(define (without-cr bv)
  (u8-list->bytevector (filter (lambda (c) (not (= c 13))) (bytevector->u8-list bv))))

;; carries? : String -> Boolean
;; #t when the stream's client packets, as the lane delivers them, fed one by
;; one to a strict request parser that continues at every callback, complete
;; two or more messages, or complete one that began in an earlier packet.
;; The count stops at the parser's first pause or error.
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
    (let loop ((ps (libhtp-packets name)))
      (when (pair? ps)
        (let ((r (parser-feed! p (car ps) 0 (bytevector-length (car ps)))))
          (when (eq? (parser-result-status r) 'need-input)
            (set! packet (+ packet 1))
            (loop (cdr ps))))))
    (or (>= (length messages) 2)
        (exists (lambda (m) (not (= (car m) (cdr m)))) messages))))

;; all-files : -> (Listof String) — the 102 streams, in file-name order.
(define (all-files)
  (list-sort string<? (filter (lambda (f) (suffix? ".t" f)) (directory-list files-dir))))

;; carrying-files : -> (Listof String) — the streams that carry either, by
;; name, in file-name order.
(define (carrying-files) (filter carries? (all-files)))

(run-suite "libhtp-lane"
  (lambda ()
    (test-eqv "forty-two streams have an expectation" 42 (length libhtp-expected-files))
    (test-equal "the streams that carry pipelining or a split request are the ones with one, but the robustness lane's"
                (filter (lambda (f) (not (member f robustness-expected-files))) libhtp-expected-files)
                (carrying-files))
    ;; The robustness lane's streams are named, not found by a parser.
    (test-eqv "twenty-eight robustness streams: twenty-four invalid, four HTTP/0.9"
              28 (length robustness-expected-files))
    (test-equal "the robustness lane's streams are libhtp's invalid and HTTP/0.9 streams, by name"
                (filter robustness-file? (all-files)) robustness-expected-files)
    (test-equal "every stream but the two Expect streams is delivered as libhtp's chunker cuts it"
                '()
                (filter (lambda (f) (not (or (member f crlf-files) (equal? (libhtp-packets f) (cut f)))))
                        (all-files)))
    (test-equal "the two Expect streams are delivered with each bare LF made CRLF, and nothing else changed"
                '(("05-expect.t" #t #f #t) ("99-expect-100.t" #t #f #t))
                (map (lambda (f)
                       (let ((cuts (cut f)) (delivered (libhtp-packets f)))
                         (list f
                               (exists bare-lf? cuts)
                               (exists bare-lf? delivered)
                               (equal? (map without-cr delivered) cuts))))
                     crlf-files))
    (for-each (lambda (name)
                (test-equal (string-append name " meets its expectation")
                            (libhtp-expectation name) (libhtp-outcome name)))
              libhtp-expected-files)
    (test-equal "35-early-response.t answered 400 at the head, as its recorded origin answered it: the head's packet alone brings the 400, and the body after it is dropped as the connection lingers"
                early-response-expectation (early-response-outcomes))
    ;; A run that raises (here an assertion violation, as a fake shell's
    ;; fault would) is a mismatch; the ratchet calls `libhtp-mismatch` outside
    ;; any check, where an uncaught raise would end the process with exit 255.
    (test-equal "a stream whose run raises is a mismatch that says what it raised"
                "raised fake-shell a write's byte count is not its bytes'"
                (libhtp-mismatch "07-pipelined-connection.t"
                                 (lambda (name)
                                   (assertion-violation 'fake-shell
                                                        "a write's byte count is not its bytes'"
                                                        95 94))))))
