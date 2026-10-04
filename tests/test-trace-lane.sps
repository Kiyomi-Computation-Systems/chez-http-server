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
;;;
;;; M2.3: except where the core refuses a message by policy.  The corpus is
;;; parser truth, not server truth (design §8.1), so those fixtures are listed
;;; below with the core's reason, and gated both ways: each listed fixture is
;;; refused for its reason, its trace the log's own up to the refusal; every
;;; other fixture's trace equals its log.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) getenv)
        (trace-lane))

(define selection
  (let ((v (getenv "CORPUS"))) (if (and (string? v) (string=? v "full")) 'full 'extremes)))

;; The fixtures the core refuses by policy, with the reason it closes for.
;; Each target is outside RFC 9112 §3.2's forms as the owner decided them
;; (2026-09-24), so the core answers where llhttp parses on: 400, or a 301
;; to the target encoded for the narrow case decision 0009 redirects.  And
;; since M8.3, a request line with no version, HTTP/0.9's, answered 505
;; (decided on the owner's word, by form, 2026-10-03).
(define core-refusals
  '(("request/method.md#5" . invalid-target)             ; M-SEARCH *: asterisk-form is OPTIONS's
    ("request/sample.md#10" . version-not-supported)     ; GET / with no version: HTTP/0.9
    ("request/transfer-encoding.md#21" . invalid-target) ; ?q=search#hey: a fragment
    ("request/transfer-encoding.md#22" . invalid-target) ; the same target
    ("request/transfer-encoding.md#23" . invalid-target) ; the same target
    ("request/uri.md#1" . invalid-target)                ; '"' outside the path's set
    ("request/uri.md#5" . target-redirect)               ; GET /test.cgi?query=|: a pipe, 301
    ("request/uri.md#8" . invalid-target)                ; ?page=1#posts-17408: a fragment
    ("request/uri.md#10" . invalid-target)))             ; absolute-form with userinfo

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
    ;; Property 1: the connection layer does not perturb parsing, except by
    ;; the refusals listed above.
    (let* ((listed? (lambda (p) (assoc (car p) core-refusals)))
           (refused (filter listed? strict-request-fixtures))
           (parsed (filter (lambda (p) (not (listed? p))) strict-request-fixtures)))
      (test-equal "every listed refusal names a strict fixture"
                  (map car core-refusals) (map car refused))
      (test-eqv "property 1 covers every strict fixture, refused or not"
                (length strict-request-fixtures) (+ (length refused) (length parsed)))
      (let ((mismatches
             (filter (lambda (p) (cdr p))
                     (map (lambda (p) (cons (car p) (core-trace-mismatch (cdr p) selection)))
                          parsed))))
        (for-each (lambda (m) (diag (string-append "CORE TRACE MISMATCH " (car m) ": " (cdr m))))
                  mismatches)
        (test-eqv "with the core's bindings installed, every other trace still equals its log"
                  0 (length mismatches)))
      (let ((mismatches
             (filter (lambda (p) (cdr p))
                     (map (lambda (p)
                            (cons (car p) (core-refusal-mismatch
                                           (cdr p) (cdr (assoc (car p) core-refusals)) selection)))
                          refused))))
        (for-each (lambda (m) (diag (string-append "CORE REFUSAL MISMATCH " (car m) ": " (cdr m))))
                  mismatches)
        (test-eqv "each listed fixture is refused for its reason, its log unchanged up to the refusal"
                  0 (length mismatches))))))
