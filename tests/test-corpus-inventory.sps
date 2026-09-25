#!r6rs
;;; (test-corpus-inventory) — a drift guard on the chez-httparse pin.
;;;
;;; M1.1.  The instrument's first obligation is to know its corpus.  This suite
;;; loads every request fixture through the vendored harness ((httparse test
;;; corpus-load) / corpus-decode), reachable only because M1.1 added
;;; test/support/harness to the Makefile's LIBDIR_LIST, and asserts the request
;;; lane's shape as measured for milestone-plan §2.
;;;
;;; The oracle is the vendored corpus AT THE PIN (chez-httparse v0.4.1,
;;; 9bc669c; its corpus is v0.4.0's byte for byte), so these numbers are a
;;; drift guard, not an invariant: move the pin and the guard reddens, and
;;; §2's counts get re-measured on the new tree rather than silently aging.
;;; Measured 2026-09-20, Darwin arm64, Chez 10.4.1 `tarm64osx`.
;;;
;;; Two traps the meta reader must respect (corpus-load's own meta note):
;;;   - fixture-meta-ref takes a SYMBOL key (it is assq) and its third argument
;;;     is the default, so an untyped fixture defaulted to "request" would be
;;;     counted as strict.  The default here is an impossible symbol.
;;;   - `pause` is a STRING naming the callback to pause in, not a boolean, so
;;;     it is tested for PRESENCE.  `noScan` and `skipBody` are booleans.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list)
        (httparse test corpus-load)      ; corpus-parse-file, fixture-meta-ref, fixture-input-text
        (httparse test corpus-decode))   ; corpus-decode-input

(define request-dir "vendor/chez-httparse/test/vendor/llhttp/request/")

(define (string-suffix? suf s)
  (let ((ns (string-length s)) (nf (string-length suf)))
    (and (>= ns nf) (string=? (substring s (- ns nf) ns) suf))))

;; request-files : (Listof String)
;; The request corpus files, DISCOVERED rather than hardcoded, so a file added
;; or removed at a future pin moves the count and reddens the guard.
(define request-files
  (list-sort string<?
    (filter (lambda (f) (string-suffix? ".md" f))
            (map (lambda (x) (if (string? x) x (symbol->string x)))
                 (directory-list request-dir)))))

;; slurp : String -> String — a corpus file's whole text (UTF-8).
(define (slurp path) (call-with-input-file path get-string-all))

;; all-fixtures : (Listof Fixture) — every fixture, file then document order.
(define all-fixtures
  (apply append
    (map (lambda (f) (corpus-parse-file (slurp (string-append request-dir f))))
         request-files)))

;; strict? : Fixture -> Boolean — type is exactly "request" (§2.1's strict lane).
(define (strict? f) (equal? "request" (fixture-meta-ref f 'type 'no-type)))
(define strict-fixtures (filter strict? all-fixtures))

(define (count-of pred xs) (length (filter pred xs)))

(define (has-pause? f) (not (eq? 'none (fixture-meta-ref f 'pause 'none))))
(define (no-scan?   f) (eq? #t (fixture-meta-ref f 'noScan #f)))
(define (skip-body? f) (eq? #t (fixture-meta-ref f 'skipBody #f)))

;; strict-decoded-bytes : Nat — total decoded input over the strict lane.
(define strict-decoded-bytes
  (fold-left (lambda (acc f)
               (+ acc (bytevector-length
                       (corpus-decode-input (fixture-input-text f)))))
             0 strict-fixtures))

(run-suite "corpus-inventory"
  (lambda ()
    ;; Each assertion compares a measured count against §2's oracle literal —
    ;; a value only the corpus-at-the-pin produces, never #f or truthiness.
    (test-eqv "13 request corpus files"          13    (length request-files))
    (test-eqv "167 fixtures across all files"    167   (length all-fixtures))
    (test-eqv "135 type=request fixtures"        135   (length strict-fixtures))
    (test-eqv "17 noScan in the strict lane"     17    (count-of no-scan? strict-fixtures))
    (test-eqv "13 pause keys in the strict lane" 13    (count-of has-pause? strict-fixtures))
    (test-eqv "1 skipBody in the strict lane"    1     (count-of skip-body? strict-fixtures))
    (test-eqv "10,364 decoded bytes in the strict lane" 10364 strict-decoded-bytes)))
