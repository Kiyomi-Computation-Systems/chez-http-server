#!r6rs
;;; (test-ratchet) — the three-lane, two-way ratchet.  M1.4.
;;;
;;; tests/ratchet.txt records a status per fixture per lane.  This suite gates
;;; it BOTH WAYS (decision 0008 item 6, design §8.6): a `passing` entry that
;;; does not pass is a regression, and a `not-yet` entry that does pass is an
;;; unexplained improvement (usually a comparator that stopped comparing).  The
;;; deferred/in-scope split is DERIVED from each fixture's own meta and checked
;;; against the manifest, so a corpus refresh cannot smuggle a lenient fixture
;;; in as not-yet.
;;;
;;; The lanes have different comparators:
;;;   trace   — M1.2's, re-run here (via (trace-lane)), so the ratchet gates the
;;;             trace lane itself rather than trusting the trace suite;
;;;   outcome — none until M2, so no fixture passes it (every strict is not-yet);
;;;   libhtp  — none until M2 (our expectations are M2's), so all not-yet.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list)
        (httparse test ratchet)          ; ratchet-parse, ratchet-entry-id/-status
        (trace-lane))                    ; request-fixtures, fixture-strict?, trace-mismatch

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
;; Derived from meta: a lenient request fixture is deferred; a strict one is
;; in-scope; every libhtp file is in-scope; anything else is unknown (extra).
(define (lane-class lane fid)
  (cond
   ((or (string=? lane "trace") (string=? lane "outcome"))
    (let ((f (hashtable-ref request-by-id fid #f)))
      (cond ((not f) 'unknown)
            ((fixture-strict? f) 'in-scope)
            (else 'deferred))))
   ((string=? lane "libhtp")
    (if (hashtable-contains? libhtp-id-set fid) 'in-scope 'unknown))
   (else 'unknown)))

;; lane-passes? : String String -> Boolean — the lane's comparator on an
;; in-scope fixture.  Only trace has one in M1.
(define (lane-passes? lane fid)
  (cond ((string=? lane "trace")
         (let ((f (hashtable-ref request-by-id fid #f)))
           (and f (not (trace-mismatch f 'extremes)))))
        (else #f)))

;; --- the two-way gate -----------------------------------------------------

(define violations
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
         (let ((passes (lane-passes? lane fid)))
           (cond
            ((and (eq? status 'passing) (not passes))
             (cons (string-append full ": marked passing but does not pass") acc))
            ((and (eq? status 'not-yet) passes)
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
    ;; the ratchet opens at the plan's per-lane counts
    (test-eqv "trace lane: 135 passing"   135 (lane-count "trace" 'passing))
    (test-eqv "trace lane: 32 deferred"    32 (lane-count "trace" 'deferred))
    (test-eqv "outcome lane: 135 not-yet" 135 (lane-count "outcome" 'not-yet))
    (test-eqv "outcome lane: 32 deferred"  32 (lane-count "outcome" 'deferred))
    (test-eqv "libhtp lane: 102 not-yet"  102 (lane-count "libhtp" 'not-yet))
    ;; every fixture in every lane is listed (no missing entry)
    (for-each (lambda (m) (diag (string-append "RATCHET MISSING " m))) missing)
    (test-equal "manifest covers every fixture in every lane" '() missing)
    ;; the two-way gate and the meta-derived split hold
    (for-each (lambda (v) (diag (string-append "RATCHET VIOLATION " v))) violations)
    (test-equal "no ratchet violations" '() violations)))
