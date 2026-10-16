#!r6rs
;;; (test-ratchet) — the three-lane, two-way ratchet.
;;;
;;; tests/ratchet.txt records a status per fixture per lane.  This suite gates
;;; it BOTH WAYS: a `passing` entry that does not pass is a regression, and a
;;; `not-yet` entry that does pass is an unexplained improvement (usually a
;;; comparator that stopped comparing).  The deferred/in-scope split is
;;; DERIVED, per lane, and checked against the manifest: the trace lane's from
;;; each fixture's own meta, so a corpus refresh cannot smuggle a lenient
;;; fixture in as not-yet; the outcome lane holds every request fixture, since
;;; it runs the server's own parser and reads no recorded log.
;;;
;;; The lanes have different comparators:
;;;   trace   — the trace lane's, re-run here (via (trace-lane)), so the
;;;             ratchet gates the trace lane itself rather than trusting the
;;;             trace suite;
;;;   outcome — the outcome lane's, re-run here (via (outcome-lane)): the
;;;             connection-level outcome is the same at every chunk size
;;;             ('extremes);
;;;   libhtp  — the libhtp lane's, re-run here (via (libhtp-lane)): a stream
;;;             passes when it has one of our expectations and meets it.
;;;
;;; The gate runs the lanes, so it runs inside the suite: a raise there is a
;;; harness error (status 2), never a crash outside the status vocabulary.
;;; The outcome and libhtp lanes make a run that raises a mismatch, which the
;;; gate reports as a violation with the lane's reason (status 1).
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list)
        (httparse test ratchet)          ; ratchet-parse, ratchet-entry-id/-status
        (trace-lane)                     ; request-fixtures, fixture-strict?, trace-mismatch
        (outcome-lane)                   ; outcome-mismatch
        (libhtp-lane))                   ; libhtp-mismatch

(define (read-file-text path)
  (let* ((p (open-file-input-port path)) (b (get-bytevector-all p)))
    (close-port p)
    (utf8->string (if (eof-object? b) (make-bytevector 0) b))))

(define (string-suffix? suf s)
  (let ((ns (string-length s)) (nf (string-length suf)))
    (and (>= ns nf) (string=? (substring s (- ns nf) ns) suf))))

;; split-lane : "lane/fixture-id" -> (lane . fixture-id) on the first slash.
(define (split-lane full)
  (let loop ((i 0))
    (cond ((>= i (string-length full)) (cons full ""))
          ((char=? (string-ref full i) #\/)
           (cons (substring full 0 i) (substring full (+ i 1) (string-length full))))
          (else (loop (+ i 1))))))

(define entries (ratchet-parse (read-file-text "tests/ratchet.txt")))

(define libhtp-files
  (list-sort string<?
    (filter (lambda (f) (string-suffix? ".t" f))
            (map (lambda (x) (if (string? x) x (symbol->string x)))
                 (directory-list "test/vendor/libhtp/files")))))

;; --- the model, from the corpus ------------------------------------------

(define request-by-id
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (pr) (hashtable-set! h (car pr) (cdr pr))) request-fixtures)
    h))

(define libhtp-id-set
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (f) (hashtable-set! h (string-append "files/" f) #t)) libhtp-files)
    h))

;; lane-class : String String -> (U 'in-scope 'deferred 'unknown)
;; Derived per lane.  The trace lane compares llhttp's recorded logs, so a
;; fixture recorded under a lenient flag, or with the finish call, is deferred
;; and a strict one in-scope, from its meta.  The outcome lane runs the
;; server's own parser and reads no log, so every request fixture is in-scope.
;; Every libhtp file is in-scope; anything else is unknown (extra).
(define (lane-class lane fid)
  (cond
   ((string=? lane "trace")
    (let ((f (hashtable-ref request-by-id fid #f)))
      (cond ((not f) 'unknown)
            ((fixture-strict? f) 'in-scope)
            (else 'deferred))))
   ((string=? lane "outcome")
    (if (hashtable-contains? request-by-id fid) 'in-scope 'unknown))
   ((string=? lane "libhtp")
    (if (hashtable-contains? libhtp-id-set fid) 'in-scope 'unknown))
   (else 'unknown)))

;; lane-mismatch : String String -> (U #f String) — the lane's comparator on
;; an in-scope fixture: #f when it passes, else why not.  A libhtp id is
;; "files/<name>".
(define (lane-mismatch lane fid)
  (let ((f (hashtable-ref request-by-id fid #f)))
    (cond ((string=? lane "trace") (if f (trace-mismatch f 'extremes) "no fixture"))
          ((string=? lane "outcome") (if f (outcome-mismatch f 'extremes) "no fixture"))
          ((string=? lane "libhtp")
           (libhtp-mismatch (substring fid 6 (string-length fid))))
          (else "no comparator"))))

;; --- the two-way gate -----------------------------------------------------

;; violations : -> (Listof String) — one line per entry the gate refuses.
;; It runs every lane, so only the suite calls it.
(define (violations)
  (fold-right
   (lambda (e acc)
     (let* ((full (ratchet-entry-id e))
            (status (ratchet-entry-status e))
            (lp (split-lane full)) (lane (car lp)) (fid (cdr lp))
            (class (lane-class lane fid)))
       (cond
        ((eq? class 'unknown)
         (cons (string-append full ": names no fixture in lane " lane) acc))
        ((eq? class 'deferred)
         (if (eq? status 'deferred) acc
             (cons (string-append full ": lenient, must be deferred, is "
                                  (symbol->string status)) acc)))
        ((eq? status 'deferred)
         (cons (string-append full ": in-scope fixture marked deferred") acc))
        (else
         (let ((why (lane-mismatch lane fid)))
           (cond
            ((and (eq? status 'passing) why)
             (cons (string-append full ": marked passing but does not pass: " why) acc))
            ((and (eq? status 'not-yet) (not why))
             (cons (string-append full ": marked not-yet but now passes") acc))
            (else acc)))))))
   '() entries))

;; --- coverage: every expected fixture is in the manifest ------------------

(define expected-ids
  (append
   (map (lambda (pr) (string-append "trace/" (car pr))) request-fixtures)
   (map (lambda (pr) (string-append "outcome/" (car pr))) request-fixtures)
   (map (lambda (f) (string-append "libhtp/files/" f)) libhtp-files)))

(define manifest-id-set
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (e) (hashtable-set! h (ratchet-entry-id e) #t)) entries)
    h))

(define missing
  (filter (lambda (id) (not (hashtable-contains? manifest-id-set id))) expected-ids))

;; --- counts per lane ------------------------------------------------------

(define (entry-lane e) (car (split-lane (ratchet-entry-id e))))
(define (lane-count lane status)
  (length (filter (lambda (e) (and (string=? (entry-lane e) lane)
                                   (eq? (ratchet-entry-status e) status)))
                  entries)))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

(run-suite "ratchet"
  (lambda ()
    ;; the per-lane counts, moved only by a reviewed promotion in
    ;; tests/ratchet.txt
    (test-eqv "trace lane: 135 passing"   135 (lane-count "trace" 'passing))
    (test-eqv "trace lane: 32 deferred"    32 (lane-count "trace" 'deferred))
    (test-eqv "outcome lane: 167 passing" 167 (lane-count "outcome" 'passing))
    (test-eqv "outcome lane: 0 not-yet"     0 (lane-count "outcome" 'not-yet))
    (test-eqv "outcome lane: 0 deferred"    0 (lane-count "outcome" 'deferred))
    (test-eqv "libhtp lane: 42 passing"    42 (lane-count "libhtp" 'passing))
    (test-eqv "libhtp lane: 60 not-yet"    60 (lane-count "libhtp" 'not-yet))
    ;; every fixture in every lane is listed (no missing entry)
    (for-each (lambda (m) (diag (string-append "RATCHET MISSING " m))) missing)
    (test-equal "manifest covers every fixture in every lane" '() missing)
    ;; the two-way gate and the meta-derived split hold
    (let ((vs (violations)))
      (for-each (lambda (v) (diag (string-append "RATCHET VIOLATION " v))) vs)
      (test-equal "no ratchet violations" '() vs))))
