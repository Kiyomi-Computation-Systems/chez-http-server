#!r6rs
;;; The strictness lane: the server's verdicts on Kestrel's parsing tables,
;;; httpd's http_strict.t and lighttpd's request.t (design §8.8, plan §14,
;;; M8.3).
;;;
;;; The three corpora are vendored (decision 0007); this suite verifies their
;;; bytes against their PROVENANCE (status 3 on drift), reads each with a
;;; reader that refuses a shape it does not know, and holds every case to
;;; (strictness-lane): its refused-or-served verdict is its source's, or it is
;;; a listed departure that still departs, and its outcome is chunk-size
;;; invariant at the corpus lanes' sizes.  The handler reads any body it is
;;; given and answers 200, as the outcome lane's does.
(import (rnrs) (srfi :64) (testing)
        (sha256) (provenance) (corpus-scan) (only (corpus-text) prefix?)
        (kestrel-corpus) (httpd-corpus) (lighttpd-corpus)
        (strictness-lane))

;; The delivery sizes, as the corpus lanes take them: size 1 and the whole
;; input, unless CORPUS=full asks for every size (decision 0007).
(define selection (corpus-selection))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

(define (filter-map f xs)
  (fold-right (lambda (x acc) (let ((y (f x))) (if y (cons y acc) acc))) '() xs))

;; refused? : (-> Any) (Condition -> Boolean) -> Symbol
(define (refused? thunk parse-error?)
  (guard (e ((parse-error? e) 'refused)) (thunk) 'accepted))

(define (b s) (string->utf8 s))

;; module-gated? : HttpdRow -> Boolean — gated on a module of httpd's.
(define (module-gated? r)
  (let ((c (httpd-row-condition r))) (and c (prefix? "have_module" c))))

;; The corpora, each with the files a refresh writes and the PROVENANCE count.
(define corpora '(("test/vendor/kestrel" . 2) ("test/vendor/httpd-tests" . 3) ("test/vendor/lighttpd" . 2)))

(run-suite "strictness-lane"
  (lambda ()
    ;; 1. calibrate the hasher (FIPS 180-4) before trusting the manifests.
    (test-equal "sha256 of the empty string"
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                (sha256-hex (string->utf8 "")))
    (test-equal "sha256 of \"abc\""
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                (sha256-hex (string->utf8 "abc")))

    ;; 2. provenance: each corpus's bytes are the bytes we fetched, or exit 3.
    ;;    Verified outside the check, which would take the failure for its
    ;;    own and exit 1.
    (let ((counts (map (lambda (c) (length (verify-provenance! (car c)))) corpora)))
      (test-equal "each corpus's PROVENANCE lists its files: Kestrel 2, httpd 3, lighttpd 2"
                  (map cdr corpora) counts))

    ;; 3. each reader reads its corpus whole, at the counts its file holds
    ;;    (the survey's for Kestrel's tables: 90 invalid lines, 58 invalid
    ;;    headers, 15 incomplete, 20 non-token methods; measured 2026-10-04).
    (test-equal "Kestrel's eleven tables, row by row"
                '(90 4 20 4 7 4 2 5 58 4 15)
                (map (lambda (t) (length (kestrel-table t)))
                     '("RequestLineInvalidData" "RequestLineInvalidDataLineFeedTerminator"
                       "MethodWithNonTokenCharData" "MethodWithNullCharData" "TargetWithEncodedNullCharData"
                       "TargetWithNullCharData" "QueryStringWithNullCharData" "UnrecognizedHttpVersionData"
                       "RequestHeaderInvalidData" "RequestHeaderInvalidDataLineFeedTerminator"
                       "RequestLineIncompleteData")))
    (test-equal "Kestrel's three tables that append others still append as ported" '()
                (kestrel-composition-faults))
    ;; Three rows are gated: two on httpd's version (`$test_underscore`, a
    ;; fix level), whose expectation holds for any server, and one on a
    ;; module of httpd's (`have_module`), which is httpd's alone.
    (test-equal "httpd's 88 rows: 8 response-header rows; 2 gated on httpd's version, 1 on a module"
                '(88 8 2 1)
                (let ((rows (httpd-rows)))
                  (list (length rows) (length (filter httpd-row-response-test? rows))
                        (length (filter (lambda (r) (and (httpd-row-conditional? r) (not (module-gated? r)))) rows))
                        (length (filter module-gated? rows)))))
    ;; Row 41 is `[ "GET /\r\n" => 90, undef ]`: its harness reads an undef
    ;; strict expectation as the lenient one, an HTTP/0.9 body (90).
    (test-equal "httpd's row 41: the strict host expects what the lenient one does, as its harness reads an undef"
                '(90 90)
                (let ((r (find (lambda (r) (= (httpd-row-index r) 41)) (httpd-rows))))
                  (list (httpd-row-unsafe r) (httpd-row-strict r))))
    (test-equal "lighttpd's 24 sections, and 41 blocks in the two the lane takes"
                '(24 41)
                (list (length (lighttpd-sections)) (length (lighttpd-blocks lighttpd-scope))))

    ;; 4. each reader refuses a shape it does not know, rather than reading it
    ;;    wrong: a table not found; a row's value that is no value; a line in
    ;;    a section that is no block shape.
    (test-equal "the readers refuse an unknown table, an unknown value, an unknown line"
                '(refused refused refused)
                (list (refused? (lambda () (kestrel-table "NoSuchTable")) kestrel-parse-error?)
                      (refused? (lambda () (httpd-rows-of-text "my @test_cases = (\n    [ \"GET /\\r\\n\" => foo! ],\n);\n"))
                                httpd-parse-error?)
                      (refused? (lambda () (lighttpd-blocks-of-text "## keep-alive\n$t->{FOO} = 1;\n" '("keep-alive")))
                                lighttpd-parse-error?)))

    ;; Kestrel's reader takes a table's rows from the "{" on the line after
    ;; its constructor; one opened on the constructor's line would have it
    ;; take the next table's (the review's sixth).  Its rows are ASCII, as
    ;; Kestrel's tests send them (the seventh).
    (test-equal "Kestrel's reader refuses an array opened on its constructor's line, and a row past ASCII"
                '(refused refused)
                (list (refused? (lambda ()
                                  (kestrel-table-of-text
                                   (string-append "public static IEnumerable<string> T => new[] { \"a\" };\n"
                                                  "public static IEnumerable<string> U => new[]\n{\n    \"b\",\n};\n")
                                   "T"))
                                kestrel-parse-error?)
                      (refused? (lambda ()
                                  (kestrel-table-of-text
                                   "public static IEnumerable<string> T => new[]\n{\n    \"/\\u00E5\",\n};\n" "T"))
                                kestrel-parse-error?)))

    ;; 5. one case of each, end to end, as an oracle its file dictates.
    ;; lighttpd's is its third block, three lines, so its LFs are made CRLF.
    (test-equal "Kestrel's first invalid line, \"G\", httpd's first row, and lighttpd's first three-line block, as delivered"
                (list (b "G\r\n\r\n") (b "GET / HTTP/1.0\r\n\r\n")
                      (b "OPTIONS / HTTP/1.1\r\nHost: www.example.org\r\nConnection: close\r\n\r\n"))
                (let ((cases (strictness-cases)))
                  (map (lambda (id) (strictness-case-request (find (lambda (c) (string=? (strictness-case-id c) id)) cases)))
                       '("kestrel/RequestLineInvalidData#1" "httpd/row-1" "lighttpd/request.t:35"))))

    ;; 6. a bare line is completed into a head, and nothing else is.
    ;; Only a bare request line, one line ended by CRLF, is completed (the
    ;; owner's word, by form: "Complete them into heads"); a header section
    ;; ended by CRLF is not one (the review's third finding).
    (test-equal "complete-head: a line ending CRLF gains one; a head, a partial line, a pipeline, a header section do not"
                (list (b "GET / HTTP/1.1\r\n\r\n") (b "GET / HTTP/1.1\r\n\r\n") (b "GET") (b "A\r\n\r\nB\r\n")
                      (b "GET / HTTP/1.1\r\nH: v\r\n"))
                (map complete-head (list (b "GET / HTTP/1.1\r\n") (b "GET / HTTP/1.1\r\n\r\n") (b "GET")
                                         (b "A\r\n\r\nB\r\n") (b "GET / HTTP/1.1\r\nH: v\r\n"))))

    ;; --- the lane, every case --------------------------------------------------

    (let* ((cases (strictness-cases))
           (ids (map strictness-case-id cases))
           (mismatches (filter-map (lambda (c)
                                     (let ((m (strictness-mismatch c selection)))
                                       (and m (cons (strictness-case-id c) m))))
                                   cases))
           (runs (fold-left (lambda (acc c)
                              (+ acc 1 (length (delivery-sizes (bytevector-length (strictness-case-request c)) selection))))
                            0 cases)))
      (diag (string-append "strictness-lane: selection=" (symbol->string selection)
                           " cases=" (number->string (length cases)) " runs=" (number->string runs)))
      (for-each (lambda (m) (diag (string-append "STRICTNESS MISMATCH " (car m) ": " (cdr m)))) mismatches)
      ;; Kestrel's tables as its tests wrap them: 114 request lines (90 and
      ;; the 24 non-token methods), 7 and 6 targets, 5 versions, 58 and 4
      ;; header sections, 4 LF-ended lines, 15 incomplete, 24 methods; httpd's
      ;; 88 less its 8 response-header rows and its 1 gated on a module;
      ;; lighttpd's 41.
      (test-equal "the cases: Kestrel 237, httpd 79, lighttpd 41"
                  '(237 79 41)
                  (map (lambda (p) (length (filter (lambda (id) (prefix? p id)) ids)))
                       '("kestrel/" "httpd/" "lighttpd/")))
      (test-equal "every case agrees with its source, or departs as listed, and is chunk-invariant"
                  '() mismatches)
      ;; A departure is pinned to this server's own verdict, not only to
      ;; differ from its source's (the review's first finding): httpd's row
      ;; 50 is unanswered, and listed so; listed as served, it is a mismatch.
      (test-equal "a departure listed with a verdict this server does not give is a mismatch"
                  '(#f mismatch)
                  (let ((row-50 (find (lambda (c) (string=? (strictness-case-id c) "httpd/row-50")) cases)))
                    (list (strictness-mismatch row-50 selection '(("httpd/row-50" (unanswered) head-never-ends)))
                          (and (strictness-mismatch row-50 selection '(("httpd/row-50" (served) head-never-ends)))
                               'mismatch))))
      (test-equal "every listed departure names a case" '()
                  (filter (lambda (d) (not (member (car d) ids))) departures))
      ;; The schedule is the corpus lanes': two runs a case by default, size 1
      ;; and the whole (each request longer than a byte, but Kestrel's "G"),
      ;; and one a size up to its length under CORPUS=full.
      (test-eqv "the runs are the corpus lanes' schedule"
                (fold-left (lambda (acc c)
                             (let ((len (bytevector-length (strictness-case-request c))))
                               (+ acc (if (or (eq? selection 'full) (<= len 1)) (max len 1) 2))))
                           0 cases)
                runs))))

