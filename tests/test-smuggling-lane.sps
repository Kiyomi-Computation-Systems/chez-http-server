#!r6rs
;;; The smuggling-framing lane: the server's answer to the hand-written
;;; request-framing vectors of (smuggling-corpus) — the shapes an HTTP
;;; request-smuggling (desync) attack is built from (plan §14's last open
;;; item, M8.3; design §8.8).  Defensive and test-only: fixed vectors, no
;;; generator, no probe.
;;;
;;; The corpus loads and assembles to the exact bytes we wrote; then two
;;; properties are gated over every case (tests/smuggling-lane.sls): each
;;; case's measured verdict is the one recorded (both ways); and the corpus's
;;; own `category` and verdict agree, so no `hazard` is served (the security
;;; property).  Chunk invariance is the outcome lane's, not re-gated here
;;; (these vectors are refused at the head; see smuggling-lane.sls).
(import (rnrs) (srfi :64) (testing)
        (smuggling-corpus)
        (smuggling-lane))

;; diag : String -> Void — a line to standard error.
(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; filter-map : (a -> (U b #f)) (Listof a) -> (Listof b)
(define (filter-map f xs)
  (fold-right (lambda (x acc) (let ((y (f x))) (if y (cons y acc) acc))) '() xs))

(run-suite "smuggling-lane"
  (lambda ()
    (let ((cases (smuggling-cases)))

      ;; 1. the corpus loads: a fixed count and mix, so the lane is not
      ;;    vacuous and the properties below loop over the list this counts.
      ;;    (measured at the time of writing, 2026-10-04.)
      (test-eqv "nineteen framing vectors" 19 (length cases))
      (test-eqv "six are safe (served)" 6
                (length (filter (lambda (c) (eq? (smuggling-case-category c) 'safe)) cases)))
      (test-eqv "thirteen are hazards (refused)" 13
                (length (filter (lambda (c) (eq? (smuggling-case-category c) 'hazard)) cases)))
      ;; every id is unique: the lane reports by it.
      (test-equal "every case id is unique" '()
                  (let loop ((ids (map smuggling-case-id cases)) (dups '()))
                    (cond ((null? ids) (reverse dups))
                          ((member (car ids) (cdr ids)) (loop (cdr ids) (cons (car ids) dups)))
                          (else (loop (cdr ids) dups)))))

      ;; 2. the assembler, pinned on two cases: a CL.TE request, and the one
      ;;    whose byte is subtle — a tab after the colon (OWS), not a space.
      (test-equal "cl.te assembles to its exact bytes"
                  (string->utf8 (string-append "POST / HTTP/1.1\r\nHost: x\r\n"
                                               "Content-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
                  (smuggling-case-request
                   (find (lambda (c) (string=? (smuggling-case-id c) "cl.te")) cases)))
      (test-equal "te-ows-tab carries a tab, not a space, after the colon"
                  (string->utf8 (string-append "POST / HTTP/1.1\r\nHost: x\r\n"
                                               "Transfer-Encoding:\tchunked\r\n\r\n0\r\n\r\n"))
                  (smuggling-case-request
                   (find (lambda (c) (string=? (smuggling-case-id c) "te-ows-tab")) cases)))

      ;; 3. the security policy: the corpus's own category and recorded
      ;;    verdict agree — no hazard is recorded as served, no safe as
      ;;    refused.  This reads no server, so a smuggling hole cannot be
      ;;    written into the corpus as acceptable.
      (test-equal "every case's category and recorded verdict agree" '()
                  (filter-map (lambda (c)
                                (let ((f (smuggling-policy-fault c)))
                                  (and f (cons (smuggling-case-id c) f))))
                              cases))

      ;; 4. the verdict, both ways, every case: measured equals recorded.
      (let ((mismatches (filter-map (lambda (c)
                                      (let ((m (smuggling-verdict-fault c)))
                                        (and m (cons (smuggling-case-id c) m))))
                                    cases)))
        (for-each (lambda (m) (diag (string-append "SMUGGLING MISMATCH " (car m) ": " (cdr m))))
                  mismatches)
        (test-equal "every case meets its recorded verdict" '() mismatches)))))
