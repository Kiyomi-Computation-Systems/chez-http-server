#!r6rs
;;; (smuggling-lane) — the server's answer to the request-framing vectors of
;;; (smuggling-corpus), and the run they are held to.  M8.3's last open item
;;; (plan §14; design §8.8, beside the robustness lane).
;;;
;;; Each case is fed to one fake connection as its bytes, whole and at every
;;; chunk size (reusing (outcome-lane)), the handler reading any body it is
;;; given, and the connection did one of two things: it reached the handler
;;; (the request was served), or it refused the request before the handler,
;;; with a status and a close.
;;;
;;; Two properties are gated (tests/test-smuggling-lane.sls):
;;;   1. THE VERDICT.  Each case's measured verdict is the one the corpus
;;;      records (`served`, or a refusal status), gated BOTH WAYS: a change
;;;      that serves a recorded refusal, or refuses a recorded serve, or moves
;;;      a refusal's status, fails until the corpus is updated under review.
;;;   2. THE SECURITY POLICY.  A `hazard` case is never recorded as served and
;;;      a `safe` case never as refused: the corpus's own `category` and its
;;;      recorded verdict agree.  With property 1 this is the lane's reason to
;;;      exist — no framing a desync rides on is served.
;;;
;;; Chunk invariance is not re-gated here.  These vectors are refused (or
;;; served) at the head, before any body, and llhttp raises at the same byte
;;; however the bytes are split, so the outcome is invariant by construction;
;;; the property is gated across all 167 request fixtures by (outcome-lane)
;;; and across guardian's 162 by (robustness-lane), where bodies make the
;;; split matter.  Re-asserting it on these shapes would add a check no
;;; mutant can redden.  The verdict is measured on the whole input.
(library (smuggling-lane)
  (export smuggling-outcome smuggling-verdict smuggling-verdict-fault
          smuggling-policy-fault)
  (import (rnrs)
          (smuggling-corpus)
          (only (outcome-lane) outcome-at attempt reads))

  ;; smuggling-outcome : SmugglingCase -> Datum
  ;; (outcome-lane)'s outcome on the whole input, the handler reading any body.
  (define (smuggling-outcome c)
    (outcome-at (smuggling-case-request c)
                (max 1 (bytevector-length (smuggling-case-request c)))
                reads))

  ;; find-write : (Listof Action) -> (U #f Action) — the first write action.
  (define (find-write acts)
    (cond ((null? acts) #f)
          ((eq? (caar acts) 'write) (car acts))
          (else (find-write (cdr acts)))))

  ;; smuggling-verdict : Datum -> (U 'served Nat 'malformed)
  ;; What the connection did: `served` if the handler was reached; else the
  ;; status it wrote (>= 400) before closing with no handler; else
  ;; `malformed` (no handler, no refusal — not a verdict these requests
  ;; should produce).  Shaped to equal a case's `expected` directly.
  (define (smuggling-verdict o)
    (let ((acts (car o)))
      (cond
       ((exists (lambda (a) (eq? (car a) 'call-handler)) acts) 'served)
       ((let ((w (find-write acts)))
          (and w (>= (cadr w) 400)
               (exists (lambda (a) (eq? (car a) 'close)) acts)
               (cadr w)))
        => (lambda (status) status))
       (else 'malformed))))

  ;; smuggling-policy-fault : SmugglingCase -> (U #f String)
  ;; #f when the case's recorded `category` and `expected` agree: `safe` is
  ;; served, `hazard` is a refusal status.  Else what is inconsistent.  This
  ;; reads no server; it holds the corpus to its own security claim, so a
  ;; case recorded as a served hazard fails before any measurement.
  (define (smuggling-policy-fault c)
    (let ((cat (smuggling-case-category c)) (exp (smuggling-case-expected c)))
      (cond
       ((and (eq? cat 'safe) (not (eq? exp 'served)))
        (string-append "safe but recorded refused " (number->string exp)))
       ((and (eq? cat 'hazard) (eq? exp 'served))
        "hazard but recorded served")
       ((and (eq? cat 'hazard) (not (and (integer? exp) (>= exp 400))))
        "hazard but not a refusal status")
       ((not (memq cat '(safe hazard)))
        "category is neither safe nor hazard")
       (else #f))))

  ;; smuggling-verdict-fault : SmugglingCase -> (U #f String)
  ;; #f when the case's measured verdict is the one recorded (`expected`);
  ;; else the fault.  This is the gate's server half: a change that serves a
  ;; recorded refusal, refuses a recorded serve, or moves a refusal's status
  ;; shows here.  A run that raises is reported, never raised.
  (define (smuggling-verdict-fault c)
    (let ((whole (attempt (lambda () (smuggling-outcome c)))))
      (cond
       ((string? whole) (string-append "the whole input " whole))
       (else
        (let ((verdict (smuggling-verdict whole))
              (expected (smuggling-case-expected c)))
          (cond
           ((eq? verdict 'malformed) "no handler and no refusal")
           ((not (equal? verdict expected))
            (string-append "verdict " (show verdict) ", recorded " (show expected)))
           (else #f)))))))

  ;; show : Any -> String
  (define (show x) (call-with-string-output-port (lambda (p) (write x p)))))
