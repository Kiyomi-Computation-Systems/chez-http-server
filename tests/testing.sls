#!r6rs
;;; (testing) — the chez-http-server test-harness bridge.
;;;
;;; Suites are SRFI-64 (global-constraints), but SRFI-64 sets no process
;;; status.  `run-suite` runs a suite's assertions and then exits with the
;;; project's status vocabulary:
;;;
;;;   0  every assertion passed and at least one ran
;;;   1  one or more assertions failed (or unexpectedly passed)
;;;   2  a harness / registration error: the body escaped with an exception,
;;;      or the selection was empty (no assertion ran)
;;;   3  a provenance failure, raised by `provenance-failure`
;;;
;;; "Empty selection is failure at every layer" (global-constraints): a suite
;;; that registers no assertion exits 2, never 0.
;;;
;;; The SRFI-64 footgun — an exception inside a test expression is silently
;;; turned into #f — is defended by discipline, not code: assertions compare
;;; against a value only success can produce, never #f or bare truthiness
;;; (global-constraints).  This library only computes the status.
(library (testing)
  (export run-suite provenance-failure provenance-error?)
  (import (rnrs) (srfi :64))

  ;; provenance-error : a raised marker mapping a suite to status 3.
  (define-record-type provenance-error
    (fields (immutable message provenance-error-message)))

  ;; provenance-failure : String -> [raises]
  (define (provenance-failure message)
    (raise (make-provenance-error message)))

  ;; suite-status : test-runner -> (U 0 1 2)
  ;; 1 if any assertion failed or unexpectedly passed; 2 if none ran; else 0.
  (define (suite-status runner)
    (let ((failed (+ (test-runner-fail-count runner)
                     (test-runner-xpass-count runner)))
          (ran (+ (test-runner-pass-count runner)
                  (test-runner-fail-count runner)
                  (test-runner-xpass-count runner)
                  (test-runner-xfail-count runner))))
      (cond ((> failed 0) 1)
            ((= ran 0) 2)
            (else 0))))

  ;; note : String -> unspecified — one diagnostic line to stderr.
  (define (note line)
    (let ((p (current-error-port)))
      (put-string p line) (put-char p #\newline) (flush-output-port p)))

  ;; run-suite : String (-> Any) -> [does not return; exits with the status]
  (define (run-suite name body)
    (let ((runner (test-runner-simple)))
      (test-runner-current runner)
      (test-begin name)
      (let ((status
             (guard (e ((provenance-error? e)
                        (note (string-append "PROVENANCE-ERROR " name ": "
                                             (provenance-error-message e)))
                        3)
                       (#t
                        (note (string-append "HARNESS-ERROR " name
                                             ": the suite body raised before finishing"))
                        2))
               (body)
               (suite-status runner))))
        (test-end name)
        (exit status)))))
