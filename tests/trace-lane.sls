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
;;;
;;; M2.2 adds the same parse with the connection core's bindings installed
;;; beside the recorder's (design §8.1, property 1: the connection layer must
;;; not perturb parsing).  The core answers the parser; the recorder records.
;;; The core pauses at every on-message-complete, and the driver then runs the
;;; handler cycle and resumes, recording nothing, so the rendered trace must
;;; still equal the fixture's log.  A fixture's own harness mode (a pause it
;;; names, or skip-body) still answers as the recorder says, since that is part
;;; of what llhttp recorded; a failure the core asks for always wins, and
;;; would show in the trace.
(library (trace-lane)
  (export request-fixtures strict-request-fixtures fixture-strict?
          trace-mismatch core-trace-mismatch trace-scan-runs)
  (import (rnrs)
          (only (chezscheme) directory-list)
          (httparse test corpus-load)      ; corpus-parse-file, fixture-*, fixture-lenient-flags
          (httparse test corpus-decode)    ; corpus-decode-input
          (httparse test conformance)      ; corpus-scan-sizes, trace-compare, mismatch-*
          (httparse test adapter)          ; make-trace-recorder, trace-recorder-*, adapter-*
          (httparse test drive)            ; drive-feed!
          (httparse test trace-format)     ; trace-format
          (generated httparse-message)     ; httparse-message-machine
          (byte-machine runtime)           ; make-parser, parser-result-status/-error/-pause
          (http-server connection) (http-server private adapter)
          (http-server limits) (http-server response))

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

  ;; core-trace-at : Fixture Bytevector Nat -> (Listof Bytevector)
  ;; The trace at one chunk size with the core's bindings installed beside the
  ;; recorder's, one connection per run.
  (define (core-trace-at f bv size)
    (let* ((init (strict-init f))
           (r (make-trace-recorder))
           (ctx (make-conn-context (make-conn-state 'idle 'idle #f 0 #f #f default-limits)))
           (harness-paused #f)
           (core-paused #f)
           ;; Whose answer the parser gets: a failure the core asks for; else
           ;; a pause the core asks for, noting whether the harness asked too;
           ;; else whatever the harness mode says; else the core's continue.
           (combine (lambda (from-recorder from-core)
                      (cond ((callback-failure? from-core) from-core)
                            ((eq? from-core callback-pause)
                             (set! core-paused #t)
                             (when (eq? from-recorder callback-pause) (set! harness-paused #t))
                             callback-pause)
                            ((eq? from-recorder callback-continue) from-core)
                            (else
                             (when (eq? from-recorder callback-pause) (set! harness-paused #t))
                             from-recorder))))
           (bindings
            (map (lambda (row)
                   (let ((name (car row)) (recorder (cadr row))
                         (core (cadr (assq (car row) adapter-bindings))))
                     (list name
                           (if (memq name conn-span-callbacks)
                               (lambda (p c bv from to)
                                 (combine (recorder p c bv from to) (core p c bv from to)))
                               (lambda (p c) (combine (recorder p c) (core p c)))))))
                 (trace-recorder-bindings r init (strict-harness-mode f))))
           (p (make-parser httparse-message-machine bindings ctx (adapter-parser-inits init))))
      ;; feed : Nat Nat -> ParserResult
      ;; One chunk, through every pause nobody outside asked for.  The
      ;; harness's own pause is recorded as the plain driver records it; the
      ;; core's is followed by the handler cycle (handler-responded, then
      ;; write-completed); either way the parse resumes where it stopped.
      (define (feed from to)
        (let again ((at from))
          (set! harness-paused #f)
          (set! core-paused #f)
          (let ((res (parser-feed! p bv at to)))
            (conn-context-take-actions! ctx)
            (if (and (eq? (parser-result-status res) 'paused)
                     (not (parser-error? (parser-result-pause res))))
                (begin
                  (when (or harness-paused (not core-paused))
                    (trace-recorder-note-requested-pause! r (parser-stream-offset p)))
                  (when core-paused
                    (conn-context-step! ctx (list 'handler-responded core-response))
                    (conn-context-step! ctx '(write-completed 1)))
                  (parser-resume! p)
                  (again (parser-result-next res)))
                res))))
      (let loop ((bounds (corpus-chunk-bounds (bytevector-length bv) size)) (result #f))
        (cond
         ((null? bounds)
          (when (and result (eq? (parser-result-status result) 'error))
            (trace-recorder-note-error! r (parser-result-error result)))
          (when (and result (eq? (parser-result-status result) 'paused))
            (trace-recorder-note-paused! r (parser-result-pause result)))
          (render-trace r))
         (else
          (let ((res (feed (caar bounds) (cdar bounds))))
            (if (eq? (parser-result-status res) 'need-input)
                (loop (cdr bounds) res)
                (loop '() res))))))))

  ;; What the handler answers in core-trace-at's cycle; the trace never sees it.
  (define core-response (make-response 200 #f '() #f))

  ;; trace-mismatch : Fixture Symbol -> #f | String
  ;; #f when every scheduled chunk size matches the recorded log, else the first
  ;; size that did not.  An adapter refusal is a failing fixture, not a crash.
  (define (trace-mismatch f selection) (mismatch-at trace-at f selection))

  ;; core-trace-mismatch : Fixture Symbol -> #f | String
  ;; The same, with the core's bindings installed.
  (define (core-trace-mismatch f selection) (mismatch-at core-trace-at f selection))

  (define (mismatch-at trace-at f selection)
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
