#!r6rs
;;; (robustness-lane) — the server's answer to AWS http-desync-guardian's
;;; cases, and the run they are held to.
;;;
;;; Guardian's corpus classifies a request for a proxy, by the risk it poses
;;; of an HTTP desync: Compliant, Acceptable, Ambiguous, or Severe, the last
;;; meaning "treat as an irrecoverable error (400 + close)" (severe.yaml).
;;; This server is an origin, not a proxy, so guardian's tier is not our
;;; verdict; what we do with each case is ours, as for libhtp's.  Each case is
;;; fed to one fake connection as its bytes, whole and at every chunk size, the
;;; handler reading any body it is given, and the connection did one of two
;;; things: it reached the handler (the request was accepted), or it refused
;;; the request before the handler, with a status and a close.
;;;
;;; Three properties are gated:
;;;   1. THE SERVE MANIFEST.  Which cases reach the handler is ours, written
;;;      from RFC 9112, and gated BOTH WAYS against `served-cases`: a case in
;;;      the list must be served and one not in it must be refused, so a
;;;      change that starts serving a refused case, or refuses a served one,
;;;      fails until reviewed.
;;;   2. THE SECURITY PROPERTY.  No Severe case is in the serve manifest, so
;;;      with property 1 no Severe case is ever served.  This is guardian's
;;;      own contract for Severe ("an irrecoverable error", severe.yaml), and
;;;      the reason the corpus is here; the suite asserts it against the
;;;      corpus's tiers, so adding a Severe case to the manifest fails.
;;;   3. CHUNK INVARIANCE.  Each case's outcome is the same however its bytes
;;;      are split into reads, as (outcome-lane) gates the llhttp corpus, at
;;;      the sizes the corpus lanes share: size 1 and the whole by default,
;;;      every size under CORPUS=full ((corpus-scan)).
(library (robustness-lane)
  (export robustness-outcome robustness-verdict robustness-mismatch
          served-cases guardian-short-id severe?)
  (import (rnrs)
          (guardian-corpus)
          (only (corpus-scan) invariance-fault)
          (only (outcome-lane) outcome-at attempt reads))

  ;; served-cases : (Listof String) — the cases the server accepts to the
  ;; handler, by short id ("file-stem#n").  Ours, from RFC 9112:
  ;;   - a GET or HEAD with Content-Length: 0, or with a valid Content-Length
  ;;     or Transfer-Encoding: chunked (a body is allowed on any method; §6);
  ;;   - a header whose name only looks like a framing field — `Transfer_Encoding`,
  ;;     `Transfer---Encoding` — which is an ordinary field, not a coding (§5.1);
  ;;   - a plainly valid request (rfc-compliant's first eight, the compliant
  ;;     PUT/POSTs), and a target carrying a percent-encoded CTL (%09, %20,
  ;;     %0D, %0A), which is a valid pct-encoded octet (RFC 3986 §2.1);
  ;;   - a 1.x past 1.1, HTTP/1.2, served as HTTP/1.1 (RFC 9110 §6.2), which
  ;;     guardian rates Acceptable.
  ;; Every other case is refused: a conflicting or malformed framing, a bad
  ;; target, a coding we do not implement before chunked (501), or HTTP/0.9.
  (define served-cases
    '("acceptable#5" "acceptable#6" "acceptable#9"
      "ambiguous#8" "ambiguous#9" "ambiguous#13" "ambiguous#14" "ambiguous#15"
      "ambiguous#16" "ambiguous#34" "ambiguous#35"
      "more-compliant-tests#1" "more-compliant-tests#2" "more-compliant-tests#3"
      "more-compliant-tests#4" "more-compliant-tests#5" "more-compliant-tests#7"
      "real-life-test-cases#1" "real-life-test-cases#2"
      "rfc-compliant#1" "rfc-compliant#2" "rfc-compliant#3" "rfc-compliant#4"
      "rfc-compliant#5" "rfc-compliant#6" "rfc-compliant#7" "rfc-compliant#8"
      "uri-specific-test-cases#11" "uri-specific-test-cases#12"
      "uri-specific-test-cases#13" "uri-specific-test-cases#14"))

  ;; guardian-short-id : GuardianCase -> String — "file-stem#n" from the
  ;; case's id "file.yaml#n".
  (define (guardian-short-id c)
    (let* ((id (guardian-case-id c)) (hash (index-of id #\#)))
      (string-append (drop-suffix (substring id 0 hash) ".yaml")
                     (substring id hash (string-length id)))))

  ;; severe? : GuardianCase -> Boolean — guardian's tier is Severe.
  (define (severe? c) (string=? (guardian-case-tier c) "Severe"))

  ;; robustness-outcome : GuardianCase Nat -> Datum — (outcome-lane)'s outcome
  ;; at one chunk size, the handler reading any body.
  (define (robustness-outcome c size)
    (outcome-at (guardian-case-request c) size reads))

  ;; robustness-verdict : Datum -> (U 'served (Pair 'refused Nat) 'malformed)
  ;; What the connection did: `served` if the handler was reached; else
  ;; `(refused . status)` if it wrote a status of 400 or more and closed with
  ;; no handler; else `malformed` (no handler, no refusal — not a verdict the
  ;; corpus's requests should produce).
  (define (robustness-verdict o)
    (let ((acts (car o)))
      (cond
       ((exists (lambda (a) (eq? (car a) 'call-handler)) acts) 'served)
       ((let ((w (find-write acts)))
          (and w (>= (cadr w) 400)
               (exists (lambda (a) (eq? (car a) 'close)) acts)
               (cons 'refused (cadr w))))
        => (lambda (v) v))
       (else 'malformed))))

  ;; find-write : (Listof Action) -> (U #f Action) — the first write action.
  (define (find-write acts)
    (cond ((null? acts) #f)
          ((eq? (caar acts) 'write) (car acts))
          (else (find-write (cdr acts)))))

  ;; robustness-mismatch : GuardianCase Symbol -> (U #f String)
  ;; #f when the case meets the serve manifest and is chunk-invariant at the
  ;; sizes `selection` schedules ('extremes or 'full); else the first fault.
  ;; A run that raises is reported, never raised, so a caller outside a check
  ;; (were there one) sees a string.
  (define (robustness-mismatch c selection)
    (let* ((bv (guardian-case-request c))
           (len (bytevector-length bv))
           (whole (attempt (lambda () (robustness-outcome c (max 1 len))))))
      (cond
       ((string? whole) (string-append "the whole input " whole))
       (else
        (let ((verdict (robustness-verdict whole))
              (want-served (and (member (guardian-short-id c) served-cases) #t)))
          (cond
           ((eq? verdict 'malformed)
            "no handler and no refusal")
           ((and want-served (not (eq? verdict 'served)))
            "in served-cases, but refused")
           ((and (not want-served) (eq? verdict 'served))
            "refused by served-cases, but served")
           (else (invariance-fault (lambda (size) (robustness-outcome c size)) len whole selection))))))))

  ;; --- text -------------------------------------------------------------------

  (define (index-of s ch)
    (let loop ((i 0))
      (cond ((= i (string-length s)) (assertion-violation 'robustness-lane "no #" s))
            ((char=? (string-ref s i) ch) i)
            (else (loop (+ i 1))))))

  (define (drop-suffix s suf)
    (let ((n (string-length s)) (m (string-length suf)))
      (if (and (>= n m) (string=? (substring s (- n m) n) suf)) (substring s 0 (- n m)) s))))
