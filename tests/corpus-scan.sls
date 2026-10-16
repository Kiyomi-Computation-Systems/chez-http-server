#!r6rs
;;; (corpus-scan) — the delivery sizes the corpus lanes share, and the check
;;; that a case's outcome holds at each.  The sizes are size 1 and the whole
;;; input by default, every size under CORPUS=full (through chez-httparse's
;;; `corpus-scan-sizes`).
(library (corpus-scan)
  (export corpus-selection delivery-sizes invariance-fault)
  (import (rnrs) (only (chezscheme) getenv)
          (only (httparse test conformance) corpus-scan-sizes)
          (only (outcome-lane) attempt))

  ;; corpus-selection : -> Symbol — 'full under CORPUS=full, else 'extremes.
  (define (corpus-selection)
    (let ((v (getenv "CORPUS"))) (if (and (string? v) (string=? v "full")) 'full 'extremes)))

  ;; delivery-sizes : Nat Symbol -> (Listof Nat)
  ;; The sizes `selection` schedules for an input of `len` bytes, the whole
  ;; input's aside, which a case's run takes first.
  (define (delivery-sizes len selection)
    (filter (lambda (size) (< size len)) (corpus-scan-sizes len #f selection)))

  ;; invariance-fault : (Nat -> Datum) Nat Datum Symbol -> (U #f String)
  ;; #f when `run`, at each size `selection` schedules for `len` bytes, gives
  ;; `whole`, the whole input's outcome; else the first size that differed or
  ;; raised.
  (define (invariance-fault run len whole selection)
    (let loop ((sizes (delivery-sizes len selection)))
      (if (null? sizes)
          #f
          (let ((o (attempt (lambda () (run (car sizes))))))
            (cond ((string? o) (string-append "size " (number->string (car sizes)) " " o))
                  ((equal? o whole) (loop (cdr sizes)))
                  (else (string-append "size " (number->string (car sizes)) " differs from the whole input"))))))))
