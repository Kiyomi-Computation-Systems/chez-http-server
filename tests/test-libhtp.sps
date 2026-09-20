#!r6rs
;;; (test-libhtp) — the vendored libhtp corpus loads, and its bytes are the
;;; bytes we fetched.
;;;
;;; M1.3.  This is the first non-llhttp corpus and the first PROVENANCE gate.
;;; It proves three things and asserts nothing about HTTP semantics (that is
;;; M2), because the `<<<` chunks are a recorded origin's replies, not an oracle
;;; (decision 0007):
;;;
;;;   1. the sha256 hasher is SHA-256 (FIPS 180-4 vectors) — an uncalibrated
;;;      instrument measures nothing;
;;;   2. every vendored file matches its recorded sha256 in PROVENANCE; a
;;;      mismatch, a miscount, or an unlisted file is a PROVENANCE FAILURE and
;;;      exits 3 (the first use of `provenance-failure` in this repository);
;;;   3. the loader decomposes every stream into client/server chunks, byte-
;;;      faithfully to libhtp's test.c, and refuses a malformed marker.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list)
        (sha256)                 ; sha256-hex
        (libhtp-corpus))         ; libhtp-parse-stream, libhtp-parse-error?

(define vendor-dir "test/vendor/libhtp")
(define files-dir (string-append vendor-dir "/files"))
(define (in-files name) (string-append files-dir "/" name))

(define (read-file-bytes path)
  (let* ((p (open-file-input-port path)) (b (get-bytevector-all p)))
    (close-port p)
    (if (eof-object? b) (make-bytevector 0) b)))
(define (read-file-text path) (utf8->string (read-file-bytes path)))

(define (split-on s ch)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (suffix? suf s)
  (let ((ns (string-length s)) (nf (string-length suf)))
    (and (>= ns nf) (string=? (substring s (- ns nf) ns) suf))))

(define t-files
  (list-sort string<?
    (filter (lambda (f) (suffix? ".t" f))
            (map (lambda (x) (if (string? x) x (symbol->string x)))
                 (directory-list files-dir)))))

;; --- PROVENANCE ------------------------------------------------------------

;; provenance-entries : (Listof (Pair String String)) — (hash . relpath).
(define provenance-lines (split-on (read-file-text (string-append vendor-dir "/PROVENANCE")) #\newline))

(define (space-fields line) (filter (lambda (s) (> (string-length s) 0)) (split-on line #\space)))

(define provenance-entries
  (fold-right
   (lambda (line acc)
     (let ((fs (space-fields line)))
       (if (and (>= (length fs) 3) (string=? (car fs) "sha256"))
           (cons (cons (cadr fs) (caddr fs)) acc)
           acc)))
   '() provenance-lines))

(define provenance-file-count
  (let loop ((ls provenance-lines))
    (cond ((null? ls) #f)
          ((and (>= (string-length (car ls)) 12)
                (string=? (substring (car ls) 0 12) "file-count: "))
           (string->number (substring (car ls) 12 (string-length (car ls)))))
          (else (loop (cdr ls))))))

;; verify-provenance! : String -> Nat  [or exits 3 via provenance-failure]
;; Every recorded file exists and hashes to its recorded sha256; the declared
;; file-count matches the entry count; and no vendored file is unlisted.
(define (verify-provenance!)
  (unless (and provenance-file-count (= provenance-file-count (length provenance-entries)))
    (provenance-failure
     (string-append "file-count " (if provenance-file-count (number->string provenance-file-count) "absent")
                    " but " (number->string (length provenance-entries)) " sha256 entries")))
  (for-each
   (lambda (e)
     (let ((path (string-append vendor-dir "/" (cdr e))))
       (unless (file-exists? path)
         (provenance-failure (string-append (cdr e) ": listed in PROVENANCE but missing on disk")))
       (let ((got (sha256-hex (read-file-bytes path))))
         (unless (string=? got (car e))
           (provenance-failure
            (string-append (cdr e) ": expected sha256 " (car e) " but computed " got))))))
   provenance-entries)
  (let ((listed (map cdr provenance-entries)))
    (for-each
     (lambda (rel)
       (unless (member rel listed)
         (provenance-failure (string-append "vendored file not in the manifest: " rel))))
     (cons "LICENSE" (map (lambda (f) (string-append "files/" f)) t-files))))
  (length provenance-entries))

;; --- loader over the whole corpus ------------------------------------------

;; bad-loads : Nat — files that refuse, yield no chunk, or a non-client/server one.
(define (bad-loads)
  (fold-left
   (lambda (acc f)
     (+ acc (guard (e ((libhtp-parse-error? e) 1) (#t 1))
              (let ((ch (libhtp-parse-stream (read-file-bytes (in-files f)))))
                (if (and (pair? ch)
                         (for-all (lambda (c) (memq (car c) '(client server))) ch))
                    0 1)))))
   0 t-files))

(run-suite "libhtp"
  (lambda ()
    ;; 1. calibrate the hasher (FIPS 180-4) before trusting the manifest.
    (test-equal "sha256 of the empty string"
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                (sha256-hex (string->utf8 "")))
    (test-equal "sha256 of \"abc\""
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                (sha256-hex (string->utf8 "abc")))
    (test-equal "sha256 of a 56-byte input (two blocks)"
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
                (sha256-hex (string->utf8 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))

    ;; 2. provenance: the manifest parsed to LICENSE + the 102 streams, and
    ;;    every vendored byte verifies; abort with status 3 on any mismatch,
    ;;    miscount, or unlisted file.
    (test-eqv "PROVENANCE lists LICENSE + the 102 streams" 103 (length provenance-entries))
    (verify-provenance!)

    ;; 3a. the corpus is the 102 streams the survey names (§2.3, decision 0007).
    (test-eqv "102 libhtp .t stream files" 102 (length t-files))

    ;; 3b. every stream loads into client/server chunks, none refused.
    (test-eqv "streams that fail to load" 0 (bad-loads))

    ;; 3c. 01-get.t decomposes exactly as its bytes dictate (oracle: the file,
    ;;     read byte for byte).  The client chunk exercises the trailing-CR
    ;;     strip: the file's extra blank line before <<< is removed, leaving a
    ;;     request head ending in one CRLFCRLF.
    (let ((ch (libhtp-parse-stream (read-file-bytes (in-files "01-get.t")))))
      (test-eqv "01-get.t chunk count" 2 (length ch))
      (test-equal "01-get.t client chunk (bytes and direction)"
                  (cons 'client (string->utf8 "GET /?p=%20 HTTP/1.0\r\nUser-Agent: Mozilla\r\n\r\n"))
                  (car ch))
      (test-eq "01-get.t second chunk is the server's" 'server (car (cadr ch)))
      (test-eqv "01-get.t server chunk length" 148 (bytevector-length (cdr (cadr ch)))))

    ;; 3d. the loader refuses a stream that does not begin with a marker rather
    ;;     than guessing.
    (test-eq "loader refuses a malformed marker" 'refused
             (guard (e ((libhtp-parse-error? e) 'refused))
               (libhtp-parse-stream (string->utf8 "not a marker\r\nGET / HTTP/1.0\r\n\r\n"))
               'accepted))))
