#!r6rs
;;; (trace-lane) — drive the strict llhttp corpus through our path and compare
;;; against the recorded logs.  The M1.2 driver, extracted so the trace suite
;;; and the M1.4 ratchet share one comparator rather than two that could drift.
;;;
;;; It re-derives chez-httparse's own conformance result through OUR library
;;; path, our Chez and our pins (design §8.1): drive each fixture through the
;;; generated parser with the harness recorder bindings, render with
;;; `(httparse test trace-format)` behind our `render-trace` shim, and
;;; `trace-compare` bit-exactly against the fixture's log.  The driving loop
;;; mirrors chez-httparse's own conformance driver (run-at/fixture-mismatch,
;;; generated lane) restricted to the strict (type=request) lane.
(library (trace-lane)
  (export request-fixtures strict-request-fixtures fixture-strict?
          trace-mismatch trace-scan-runs)
  (import (rnrs)
          (only (chezscheme) directory-list)
          (httparse test corpus-load)      ; corpus-parse-file, fixture-*, fixture-lenient-flags
          (httparse test corpus-decode)    ; corpus-decode-input
          (httparse test conformance)      ; corpus-scan-sizes, trace-compare, mismatch-*
          (httparse test adapter)          ; make-trace-recorder, trace-recorder-*, adapter-*
          (httparse test drive)            ; drive-feed!
          (httparse test trace-format)     ; trace-format
          (generated httparse-message)     ; httparse-message-machine
          (byte-machine runtime))          ; make-parser, parser-result-status/-error/-pause

  (define request-dir "vendor/chez-httparse/test/vendor/llhttp/request/")

  (define (string-suffix? suf s)
    (let ((ns (string-length s)) (nf (string-length suf)))
      (and (>= ns nf) (string=? (substring s (- ns nf) ns) suf))))

  (define (slurp path) (call-with-input-file path get-string-all))

  (define request-files
    (list-sort string<?
      (filter (lambda (f) (string-suffix? ".md" f))
              (map (lambda (x) (if (string? x) x (symbol->string x)))
                   (directory-list request-dir)))))

  ;; (id . fixture) with the ratchet's id shape (request/<file>#n).
  (define (load-file rel)
    (let loop ((fs (corpus-parse-file (slurp (string-append request-dir rel)))) (i 1) (acc '()))
      (if (null? fs)
          (reverse acc)
          (loop (cdr fs) (+ i 1)
                (cons (cons (string-append "request/" rel "#" (number->string i)) (car fs)) acc)))))

  ;; request-fixtures : (Listof (Pair String Fixture)) — all 167, file order.
  (define request-fixtures (apply append (map load-file request-files)))

  ;; fixture-strict? : Fixture -> Boolean — type is exactly "request" (§2.1).
  (define (fixture-strict? f) (equal? "request" (fixture-meta-ref f 'type 'no-type)))

  (define strict-request-fixtures
    (filter (lambda (p) (fixture-strict? (cdr p))) request-fixtures))

  (define (strict-init f) (cons 'request (fixture-lenient-flags f)))
  (define (strict-harness-mode f)
    (let ((pause (fixture-meta-ref f 'pause 'absent)))
      (cond ((not (eq? pause 'absent)) (list 'pause pause))
            ((eq? #t (fixture-meta-ref f 'skipBody #f)) (list 'skip-body))
            (else #f))))

  ;; render-trace : Recorder -> (Listof Bytevector)
  ;; Our thin shim over the harness renderer; the seam M1.2's mutation perturbs.
  (define (render-trace r) (trace-format (trace-recorder-events r)))

  (define (trace-at f bv size)
    (let* ((init (strict-init f))
           (r (make-trace-recorder))
           (p (make-parser httparse-message-machine
                           (trace-recorder-bindings r init (strict-harness-mode f))
                           #f (adapter-parser-inits init))))
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

  ;; trace-mismatch : Fixture Symbol -> #f | String
  ;; #f when every scheduled chunk size matches the recorded log, else the first
  ;; size that did not.  An adapter refusal is a failing fixture, not a crash.
  (define (trace-mismatch f selection)
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

  ;; trace-scan-runs : (Listof Fixture) Symbol -> Nat — scheduled replays (§2.2).
  (define (trace-scan-runs fixtures selection)
    (fold-left
     (lambda (acc f)
       (+ acc (length (corpus-scan-sizes
                       (bytevector-length (corpus-decode-input (fixture-input-text f)))
                       (eq? #t (fixture-meta-ref f 'noScan #f))
                       selection))))
     0 fixtures)))
