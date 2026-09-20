#!r6rs
;;; (test-trace-lane) — the trace lane: our path, their comparator.
;;;
;;; M1.2.  Drive every strict (type=request) fixture through the generated
;;; parser with the harness's own recorder bindings, render the recorded events
;;; with (httparse test trace-format), and compare BIT-EXACTLY against the
;;; fixture's recorded log with trace-compare, at every chunk size the selection
;;; asks for.
;;;
;;; This proves nothing about our server — there is none yet — and everything
;;; about our instrument: it re-derives chez-httparse's own conformance result
;;; through OUR library path, our Chez, our submodule pins (design §8.1).  An
;;; uncalibrated instrument cannot measure a parser; this is the calibration.
;;; The driving loop mirrors chez-httparse's own conformance driver
;;; (test/common/conformance-driver-tests.sps, the `run-at`/`fixture-mismatch`
;;; generated lane) restricted to the strict lane.
;;;
;;; THE pr/release SPLIT IS corpus-scan-sizes's `selection`, not something we
;;; build (§2.2): `make test` runs 'extremes (size 1 and whole buffer); the
;;; release lane runs 'full (every size) under CORPUS=full.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list getenv)
        (httparse test corpus-load)      ; corpus-parse-file, fixture-*, fixture-lenient-flags
        (httparse test corpus-decode)    ; corpus-decode-input
        (httparse test conformance)      ; corpus-scan-sizes, trace-compare, mismatch-*
        (httparse test adapter)          ; make-trace-recorder, trace-recorder-bindings/-note-*, adapter-*
        (httparse test drive)            ; drive-feed!
        (httparse test trace-format)     ; trace-format
        (generated httparse-message)     ; httparse-message-machine
        (byte-machine runtime))          ; make-parser, parser-result-status/-error/-pause

(define request-dir "vendor/chez-httparse/test/vendor/llhttp/request/")

(define (string-suffix? suf s)
  (let ((ns (string-length s)) (nf (string-length suf)))
    (and (>= ns nf) (string=? (substring s (- ns nf) ns) suf))))

(define (slurp path) (call-with-input-file path get-string-all))

;; request-files : (Listof String) — discovered, so the lane tracks the corpus.
(define request-files
  (list-sort string<?
    (filter (lambda (f) (string-suffix? ".md" f))
            (map (lambda (x) (if (string? x) x (symbol->string x)))
                 (directory-list request-dir)))))

;; (id . fixture) for every fixture, id shaped like the ratchet's (request/<f>#n).
(define (load-file rel)
  (let loop ((fs (corpus-parse-file (slurp (string-append request-dir rel)))) (i 1) (acc '()))
    (if (null? fs)
        (reverse acc)
        (loop (cdr fs) (+ i 1)
              (cons (cons (string-append "request/" rel "#" (number->string i)) (car fs)) acc)))))

(define all-fixtures (apply append (map load-file request-files)))

;; strict : (Listof (Pair String Fixture)) — the type=request lane (§2.1).
(define strict
  (filter (lambda (p) (equal? "request" (fixture-meta-ref (cdr p) 'type 'no-type)))
          all-fixtures))

;; selection : Symbol — 'extremes by default, 'full under CORPUS=full (§2.2).
(define selection
  (let ((v (getenv "CORPUS"))) (if (and (string? v) (string=? v "full")) 'full 'extremes)))

;; --- our path -------------------------------------------------------------

;; strict-init : Fixture -> (Pair Symbol (Listof Symbol))
;; The init hook the fixture compiles in: kind then lenient flags.  For a strict
;; fixture the flags are empty, but they are READ (fixture-lenient-flags), not
;; assumed, so a mis-selected fixture is refused rather than silently mis-driven.
(define (strict-init f) (cons 'request (fixture-lenient-flags f)))

;; strict-harness-mode : Fixture -> HarnessMode
;; #f, (pause "<llhttp macro>") or (skip-body), read off the meta and renamed,
;; not interpreted — exactly as the reference driver's fixture-harness-mode.
(define (strict-harness-mode f)
  (let ((pause (fixture-meta-ref f 'pause 'absent)))
    (cond ((not (eq? pause 'absent)) (list 'pause pause))
          ((eq? #t (fixture-meta-ref f 'skipBody #f)) (list 'skip-body))
          (else #f))))

;; render-trace : Recorder -> (Listof Bytevector)
;; Our thin shim over the harness's line renderer.  trace-format is the shared
;; vocabulary both sides render into (§8.1); the rendering step around it is
;; ours, and it is the seam M1.2's mutation perturbs.
(define (render-trace r)
  (trace-format (trace-recorder-events r)))

;; trace-at : Fixture Bytevector Nat -> (Listof Bytevector)
;; The trace our path produces for the fixture fed in size-byte chunks.  Mirrors
;; the reference driver's generated lane: drive-feed! records and resumes a pause
;; this harness asked for and hands back every other outcome, so a paused
;; fixture's trace is a complete parse with extra lines; a machine error or a
;; hand-off pause at the end is renamed by note-error!/-note-paused!.
(define (trace-at f bv size)
  (let* ((init (strict-init f))
         (r (make-trace-recorder))
         (p (make-parser httparse-message-machine
                         (trace-recorder-bindings r init (strict-harness-mode f))
                         #f
                         (adapter-parser-inits init))))
    (let loop ((bounds (corpus-chunk-bounds (bytevector-length bv) size)) (result #f))
      (cond
       ((null? bounds)
        (when (and result (eq? (parser-result-status result) 'error))
          (trace-recorder-note-error! r (parser-result-error result)))
        (when (and result (eq? (parser-result-status result) 'paused))
          (trace-recorder-note-paused! r (parser-result-pause result)))
        (render-trace r))
       (else
        (let ((res (drive-feed! r p bv (caar bounds) (cdar bounds))))
          (if (eq? (parser-result-status res) 'need-input)
              (loop (cdr bounds) res)
              (loop '() res))))))))

;; strict-mismatch : Fixture Symbol -> #f | String
;; #f when every chunk size in the selection matches the recorded log, else a
;; string naming the first size that did not and how.  An adapter refusal is a
;; failing fixture (the parser produced something the vocabulary cannot spell),
;; not a crashed lane — the no-default discipline of decision 0008 item 2.
(define (strict-mismatch f selection)
  (let* ((bv (corpus-decode-input (fixture-input-text f)))
         (expected (fixture-expected f))
         (no-scan (eq? #t (fixture-meta-ref f 'noScan #f)))
         (sizes (corpus-scan-sizes (bytevector-length bv) no-scan selection)))
    (let loop ((sizes sizes))
      (if (null? sizes)
          #f
          (let ((m (call/cc
                    (lambda (k)
                      (with-exception-handler
                       (lambda (e)
                         (if (adapter-error? e)
                             (k (string-append "adapter refused: " (adapter-error-detail e)))
                             (raise e)))
                       (lambda ()
                         (let ((d (trace-compare expected (trace-at f bv (car sizes)))))
                           (and d
                                (string-append
                                 "line " (number->string (mismatch-index d))
                                 " expected \"" (mismatch-expected d)
                                 "\" got \"" (mismatch-actual d)
                                 "\" (" (symbol->string (mismatch-reason d)) ")")))))))))
            (if m
                (string-append "size " (number->string (car sizes)) ": " m)
                (loop (cdr sizes))))))))

;; scan-runs : the number of (fixture, chunk-size) replays the selection
;; schedules over the strict lane — a pure corpus function (§2.2's "runs").
(define (fixture-runs p)
  (let* ((f (cdr p))
         (bv (corpus-decode-input (fixture-input-text f))))
    (length (corpus-scan-sizes (bytevector-length bv)
                               (eq? #t (fixture-meta-ref f 'noScan #f))
                               selection))))
(define scan-runs (apply + (map fixture-runs strict)))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

(run-suite "trace-lane"
  (lambda ()
    (diag (string-append "trace-lane: selection=" (symbol->string selection)
                         " scan-runs=" (number->string scan-runs)))
    ;; The lane is not vacuous: the strict split is M1.1's 135 (§2.1).
    (test-eqv "135 strict fixtures in the lane" 135 (length strict))
    ;; The selection actually replayed the scheduled amount (§2.2): 253 at
    ;; 'extremes, 9,394 at 'full.  A selection that matched nothing would make
    ;; the trace check below vacuously green.
    (test-eqv "scan-schedule runs match plan §2.2"
              (if (eq? selection 'full) 9394 253) scan-runs)
    ;; The trace lane: our rendered trace equals the recorded log, byte for
    ;; byte, for every strict fixture at every scheduled chunk size.
    (let ((mismatches
           (filter (lambda (p) (cdr p))
                   (map (lambda (p) (cons (car p) (strict-mismatch (cdr p) selection)))
                        strict))))
      (for-each (lambda (m) (diag (string-append "TRACE MISMATCH " (car m) ": " (cdr m))))
                mismatches)
      (test-eqv "every strict fixture's trace equals its recorded log"
                0 (length mismatches)))))
