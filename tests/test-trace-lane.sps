#!r6rs
;;; (test-trace-lane) — the trace lane: our path, their comparator.
;;;
;;; M1.2, now driven through the shared (trace-lane) library so this suite and
;;; the M1.4 ratchet share one comparator.  Every strict (type=request) fixture
;;; renders a trace, through OUR path, byte-identical to its recorded log at
;;; every scheduled chunk size (design §8.1).  `make test` runs 'extremes; the
;;; release lane runs 'full under CORPUS=full (§2.2).
;;;
;;; M2.2 adds design §8.1's property 1 with the connection core's bindings
;;; installed beside the recorder's: the core answers every callback, pausing
;;; at each message's end, and the trace must not change.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) getenv)
        (trace-lane))

(define selection
  (let ((v (getenv "CORPUS"))) (if (and (string? v) (string=? v "full")) 'full 'extremes)))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

(run-suite "trace-lane"
  (lambda ()
    (diag (string-append "trace-lane: selection=" (symbol->string selection)
                         " scan-runs=" (number->string
                                        (trace-scan-runs (map cdr strict-request-fixtures) selection))))
    ;; The lane is not vacuous: the strict split is M1.1's 135 (§2.1).
    (test-eqv "135 strict fixtures in the lane" 135 (length strict-request-fixtures))
    ;; The selection replayed the scheduled amount (§2.2): 253 / 9,394.
    (test-eqv "scan-schedule runs match plan §2.2"
              (if (eq? selection 'full) 9394 253)
              (trace-scan-runs (map cdr strict-request-fixtures) selection))
    ;; The trace lane: our rendered trace equals the recorded log for every
    ;; strict fixture at every scheduled chunk size.
    (let ((mismatches
           (filter (lambda (p) (cdr p))
                   (map (lambda (p) (cons (car p) (trace-mismatch (cdr p) selection)))
                        strict-request-fixtures))))
      (for-each (lambda (m) (diag (string-append "TRACE MISMATCH " (car m) ": " (cdr m))))
                mismatches)
      (test-eqv "every strict fixture's trace equals its recorded log"
                0 (length mismatches)))
    ;; Property 1: the connection layer does not perturb parsing.
    (let ((mismatches
           (filter (lambda (p) (cdr p))
                   (map (lambda (p) (cons (car p) (core-trace-mismatch (cdr p) selection)))
                        strict-request-fixtures))))
      (for-each (lambda (m) (diag (string-append "CORE TRACE MISMATCH " (car m) ": " (cdr m))))
                mismatches)
      (test-eqv "with the core's bindings installed, every trace still equals its log"
                0 (length mismatches)))))
