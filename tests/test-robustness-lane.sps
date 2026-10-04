#!r6rs
;;; The robustness lane: the server's answer to AWS http-desync-guardian's
;;; cases (design §8.8, plan §14, M8.3).
;;;
;;; The corpus is vendored (decision 0007); this suite verifies its bytes are
;;; the bytes we fetched (PROVENANCE, status 3 on drift), loads every case
;;; from the YAML, and gates three properties (tests/robustness-lane.sls):
;;; every Severe case is refused (guardian's own contract), each case's
;;; outcome is chunk-size invariant, and which cases reach the handler is our
;;; serve manifest, gated both ways.  The handler reads any body it is given
;;; and answers 200, as the outcome lane's does.
(import (rnrs) (srfi :64) (testing)
        (sha256)                         ; FIPS 180-4 calibration
        (corpus-scan)                    ; corpus-selection, delivery-sizes
        (provenance)                     ; verify-provenance!
        (guardian-corpus)
        (robustness-lane))

;; --- the corpus loads, and raises on a malformed shape --------------------

(define (parse-error? thunk)
  (guard (e ((guardian-parse-error? e) 'refused)) (thunk) 'accepted))

;; The delivery sizes, as the corpus lanes take them: size 1 and the whole
;; input, unless CORPUS=full asks for every size (decision 0007).
(define selection (corpus-selection))

;; diag : String -> Void — a line to standard error.
(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; filter-map : (a -> (U b #f)) (Listof a) -> (Listof b)
(define (filter-map f xs)
  (fold-right (lambda (x acc) (let ((y (f x))) (if y (cons y acc) acc))) '() xs))

;; probe-case : String String -> String
;; One case of the corpus's shape, its uri line and a header's value line
;; given: the rest is fixed and valid.
(define (probe-case uri-line value-line)
  (string-append "- name: probe\n" uri-line "\n  method: GET\n  version: HTTP/1.1\n"
                 "  headers:\n    - name: H\n" value-line "\n      tier: Compliant\n"
                 "  expected:\n    tier: Compliant\n    reason: Compliant\n"))

;; path-parts : String -> (Listof String) — a relative path's parts, by "/".
(define (path-parts rel)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length rel)) (reverse (cons (substring rel start i) acc)))
          ((char=? (string-ref rel i) #\/) (loop (+ i 1) (+ i 1) (cons (substring rel start i) acc)))
          (else (loop (+ i 1) start acc)))))

(run-suite "robustness-lane"
  (lambda ()
    ;; 1. calibrate the hasher (FIPS 180-4) before trusting the manifest.
    (test-equal "sha256 of the empty string"
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                (sha256-hex (string->utf8 "")))
    (test-equal "sha256 of \"abc\""
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                (sha256-hex (string->utf8 "abc")))

    ;; 2. provenance: every vendored byte is the byte we fetched, or exit 3.
    ;;    First, a file no refresh writes is not the corpus's: a Finder
    ;;    .DS_Store, or an AppleDouble ._ file a copy leaves.  The tree's own
    ;;    .gitattributes is one such dotfile, so the walk leaves it out by
    ;;    what it is, not by name (the review's third finding).  Checked
    ;;    before the manifest, which a walk that kept it would fail first.
    (test-equal "the files a refresh writes leave out every dotfile" '()
                (filter (lambda (rel) (exists (lambda (part) (and (> (string-length part) 0)
                                                                  (char=? (string-ref part 0) #\.)))
                                              (path-parts rel)))
                        (vendored-files guardian-dir)))
    (let ((listed (verify-provenance! guardian-dir)))
      (test-eqv "PROVENANCE lists LICENSE, NOTICE, the README and the ten YAML files"
                13 (length listed)))

    ;; 3. the corpus loads: the ten files, and 162 cases in all (measured on
    ;;    the vendored corpus, 2026-10-04; the survey's 668 counted header
    ;;    rows as cases).
    (test-eqv "ten guardian YAML files" 10 (length (guardian-files)))
    (test-eqv "162 guardian cases" 162 (length (guardian-cases)))

    ;; 4. the loader refuses a shape it does not know, rather than reading it
    ;;    wrong (a refresh that brings a new one fails by name).
    (test-eq "the loader refuses an unindented line that is not a case"
             'refused
             (parse-error?
              (lambda () (guardian-parse-text "probe" "not-a-case: value\n"))))
    ;; A whole case of the corpus's shape is read, so each fault below is the
    ;; one refused: YAML would drop a second space after a key's colon, and a
    ;; plain scalar's " #" comment, where reading them on would change the
    ;; request (the review's fourth finding).
    (test-equal "a whole case of the corpus's shape is read as its request"
                (string->utf8 "GET /x HTTP/1.1\r\nH: v\r\n\r\n")
                (guardian-case-request (car (guardian-parse-text "probe" (probe-case "  uri: /x" "      value: v")))))
    (test-equal "the loader refuses two spaces after a key's colon, a quoted scalar's among them, and a plain scalar's comment"
                '(refused refused refused)
                (map (lambda (lines)
                       (parse-error? (lambda () (guardian-parse-text "probe" (apply probe-case lines)))))
                     '(("  uri:  /x" "      value: v")
                       ("  uri: /x" "      value:  \"v\"")
                       ("  uri: /x" "      value: v # a note"))))

    ;; 5. one case, end to end, as an oracle the file dictates: severe.yaml's
    ;;    first, "Multiple Content-Length", two Content-Length lines.  Its
    ;;    request is the three parts and the two fields, CRLF-terminated.
    (let ((c (car (guardian-file-cases "severe.yaml"))))
      (test-equal "severe.yaml#1 is read as its bytes"
                  (string->utf8
                   (string-append "POST /foo/bar HTTP/1.1\r\n"
                                  "Content-Length: 1000\r\nContent-Length: 100\r\n\r\n"))
                  (guardian-case-request c))
      (test-equal "severe.yaml#1 is Severe" "Severe" (guardian-case-tier c)))

    ;; --- the three properties, every case -----------------------------------

    (let* ((cases (guardian-cases))
           (mismatches (filter-map (lambda (c)
                                     (let ((m (robustness-mismatch c selection)))
                                       (and m (cons (guardian-short-id c) m))))
                                   cases))
           (runs (fold-left (lambda (acc c)
                              (+ acc 1 (length (delivery-sizes (bytevector-length (guardian-case-request c)) selection))))
                            0 cases)))
      (diag (string-append "robustness-lane: selection=" (symbol->string selection)
                           " runs=" (number->string runs)))
      ;; The schedule is the corpus lanes': two runs a case by default, size 1
      ;; and the whole (each request is longer than a byte), and one a size
      ;; up to its length under CORPUS=full.
      (test-eqv "the runs are the corpus lanes' schedule: two a case, or every size under CORPUS=full"
                (if (eq? selection 'full)
                    (fold-left (lambda (acc c) (+ acc (bytevector-length (guardian-case-request c)))) 0 cases)
                    (* 2 (length cases)))
                runs)
      (for-each (lambda (m) (diag (string-append "ROBUSTNESS MISMATCH " (car m) ": " (cdr m))))
                mismatches)
      ;; The lane is not vacuous: 162 cases, 63 of them Severe (measured on
      ;; the vendored corpus, 2026-10-04).
      (test-eqv "63 Severe cases" 63 (length (filter severe? cases)))
      (test-eqv "30 cases reach the handler" 30 (length served-cases))
      ;; Property 3 + the serve manifest's "refused" half: every case is
      ;; served iff it is in served-cases, and every case is chunk-invariant.
      (test-equal "every case meets the serve-manifest and invariance properties"
                  '() mismatches)
      ;; The serve manifest names only cases that exist.
      (test-equal "every served case is a real case" '()
                  (let ((ids (map guardian-short-id cases)))
                    (filter (lambda (s) (not (member s ids))) served-cases)))
      ;; Property 2, the security property: no Severe case is in the serve
      ;; manifest, so with the "served iff listed" gate no Severe case is
      ;; ever served (guardian's contract: Severe is an irrecoverable error).
      (test-equal "no Severe case is in the serve manifest" '()
                  (filter (lambda (c) (and (severe? c) (member (guardian-short-id c) served-cases)))
                          cases)))))
