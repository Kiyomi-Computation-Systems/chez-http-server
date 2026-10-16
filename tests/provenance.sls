#!r6rs
;;; (provenance) — a vendored corpus's bytes are the bytes we fetched: the
;;; check for the corpora tests/vendor-corpus.sh vendors and for libhtp's.
;;;
;;; A corpus directory holds upstream's files and a PROVENANCE that lists a
;;; sha256 per file and how many there are.  Every listed file must exist and
;;; hash to its sha256, the count must be the entries', and no file beside
;;; them may be unlisted, so a refresh cannot slip one in.  A failure is
;;; `provenance-failure`, which ends the suite with status 3.  The suite
;;; calibrates the hasher before trusting it (FIPS 180-4 vectors).
(library (provenance)
  (export verify-provenance! vendored-files read-file-bytes)
  (import (rnrs) (only (chezscheme) directory-list file-directory?)
          (only (corpus-text) split) (sha256) (testing))

  ;; read-file-bytes : String -> Bytevector — the file's bytes, all of them.
  (define (read-file-bytes path)
    (let* ((p (open-file-input-port path)) (b (get-bytevector-all p)))
      (close-port p)
      (if (eof-object? b) (make-bytevector 0) b)))

  ;; verify-provenance! : String -> (Listof String)  [or raises provenance-failure]
  ;; The files `dir`'s PROVENANCE lists, relative to `dir`, once every one has
  ;; been found and hashed to its sha256, the count checked, and every file a
  ;; refresh writes (vendored-files) found among them.
  (define (verify-provenance! dir)
    (let* ((lines (lines-of (utf8->string (read-file-bytes (string-append dir "/PROVENANCE")))))
           (entries (filter-map entry lines))
           (count (exists declared-count lines)))
      (unless (and count (= count (length entries)))
        (provenance-failure
         (string-append dir ": file-count " (if count (number->string count) "absent")
                        " but " (number->string (length entries)) " sha256 entries")))
      (for-each
       (lambda (e)
         (let ((path (string-append dir "/" (cdr e))))
           (unless (file-exists? path)
             (provenance-failure (string-append path ": listed in PROVENANCE but missing on disk")))
           (let ((got (sha256-hex (read-file-bytes path))))
             (unless (string=? got (car e))
               (provenance-failure
                (string-append path ": expected sha256 " (car e) " but computed " got))))))
       entries)
      (let ((listed (map cdr entries)))
        (for-each
         (lambda (rel)
           (unless (member rel listed)
             (provenance-failure (string-append dir ": vendored file not in the manifest: " rel))))
         (vendored-files dir))
        listed)))

  ;; vendored-files : String -> (Listof String)
  ;; The files a refresh writes under `dir`, relative to it: every file but
  ;; the PROVENANCE itself and any dotfile, its own .gitattributes, a Finder
  ;; .DS_Store or a copy's AppleDouble ._ file, none of which a refresh
  ;; copies from upstream.
  (define (vendored-files dir)
    (filter (lambda (rel) (not (string=? rel "PROVENANCE"))) (files-under dir "")))

  ;; entry : String -> (U (Pair String String) #f) — (hash . path) of a
  ;; "sha256 HASH PATH" line.
  (define (entry line)
    (let ((fs (line-fields line)))
      (and (= (length fs) 3) (string=? (car fs) "sha256") (cons (cadr fs) (caddr fs)))))

  ;; declared-count : String -> (U Nat #f) — N of a "file-count: N" line.
  (define (declared-count line)
    (let ((fs (line-fields line)))
      (and (= (length fs) 2) (string=? (car fs) "file-count:") (string->number (cadr fs)))))

  ;; files-under : String String -> (Listof String)
  ;; Every file below `dir`/`rel` that is no dotfile, in no dot-directory, as
  ;; a path relative to `dir`.
  (define (files-under dir rel)
    (let ((here (if (string=? rel "") dir (string-append dir "/" rel))))
      (apply append
             (map (lambda (name)
                    (let ((r (if (string=? rel "") name (string-append rel "/" name))))
                      (if (file-directory? (string-append dir "/" r))
                          (files-under dir r)
                          (list r))))
                  (filter (lambda (name) (not (char=? (string-ref name 0) #\.)))
                          (directory-list here))))))

  ;; lines-of : String -> (Listof String)
  (define (lines-of s) (split s #\newline))

  ;; line-fields : String -> (Listof String) — the line's words, split on spaces.
  (define (line-fields line) (filter (lambda (w) (> (string-length w) 0)) (split line #\space)))

  ;; filter-map : (a -> (U b #f)) (Listof a) -> (Listof b)
  (define (filter-map f xs)
    (fold-right (lambda (x acc) (let ((y (f x))) (if y (cons y acc) acc))) '() xs)))
