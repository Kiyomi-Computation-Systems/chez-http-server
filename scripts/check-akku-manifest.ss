;;; scripts/check-akku-manifest.ss NAME=DIR...
;;;
;;; Holds Akku.manifest to what the suites run against. Each NAME=DIR names
;;; a package the library path carries and its vendored checkout. It checks,
;;; in the working directory:
;;;
;;;   - the package's own version is CHANGELOG.md's latest release;
;;;   - `depends` names exactly the packages given, each once, with a range
;;;     ^VERSION whose VERSION is the one DIR/Akku.manifest declares, under
;;;     the name NAME;
;;;   - Akku.lock locks each of them at that version.
;;;
;;; Prints one `akku ok:` line per fact it held, or an `AKKU MISMATCH:` line
;;; per one it did not, and exits 1 after the last. `make check-pins` runs it.

(define failed #f)

(define (ok . parts)
  (display "akku ok: ") (for-each display parts) (newline))

(define (mismatch . parts)
  (set! failed #t)
  (let ((p (current-error-port)))
    (display "AKKU MISMATCH: " p) (for-each (lambda (x) (display x p)) parts) (newline p)))

;; The first datum in FILE whose head is SYMBOL, or #f.
(define (form-in file symbol)
  (and (file-exists? file)
       (with-input-from-file file
         (lambda ()
           (let loop ()
             (let ((d (read)))
               (cond ((eof-object? d) #f)
                     ((and (pair? d) (eq? (car d) symbol)) d)
                     (else (loop)))))))))

;; (name version clauses) of FILE's akku-package form, or #f.
(define (package-of file)
  (let ((f (form-in file 'akku-package)))
    (and f (pair? (cdr f)) (list? (cadr f)) (= (length (cadr f)) 2)
         (list (car (cadr f)) (cadr (cadr f)) (cddr f)))))

;; The version in CHANGELOG.md's first `## [X.Y.Z]` heading, or #f.
(define (latest-release file)
  (and (file-exists? file)
       (with-input-from-file file
         (lambda ()
           (let loop ()
             (let ((line (get-line (current-input-port))))
               (cond ((eof-object? line) #f)
                     ((and (>= (string-length line) 5)
                           (string=? (substring line 0 4) "## [")
                           (char-numeric? (string-ref line 4)))
                      (let find ((i 4))
                        (cond ((= i (string-length line)) #f)
                              ((char=? (string-ref line i) #\]) (substring line 4 i))
                              (else (find (+ i 1))))))
                     (else (loop)))))))))

(define (string-prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))

;; The text after the last / of S.
(define (basename s)
  (let loop ((i (- (string-length s) 1)))
    (cond ((< i 0) s)
          ((char=? (string-ref s i) #\/) (substring s (+ i 1) (string-length s)))
          (else (loop (- i 1))))))

;; NAME=DIR, split; #f when there is no =.
(define (split-mapping arg)
  (let loop ((i 0))
    (cond ((= i (string-length arg)) #f)
          ((char=? (string-ref arg i) #\=)
           (cons (substring arg 0 i) (substring arg (+ i 1) (string-length arg))))
          (else (loop (+ i 1))))))

;; The url of NAME's entry in the lock's projects, #f for an entry with no
;; url, or 'absent.
(define (locked-url projects name)
  (let loop ((ps projects))
    (cond ((null? ps) 'absent)
          ((and (list? (car ps)) (equal? (assq 'name (car ps)) (list 'name name)))
           (let ((loc (assq 'location (car ps))))
             (and loc (pair? (cdr loc)) (pair? (cadr loc)) (eq? (car (cadr loc)) 'url)
                  (cadr (cadr loc)))))
          (else (loop (cdr ps))))))

(define mappings
  (map (lambda (arg)
         (or (split-mapping arg)
             (begin (mismatch "argument " arg " is not NAME=DIR") (exit 2))))
       (cdr (command-line))))

(when (null? mappings)
  (mismatch "no NAME=DIR given: name each package the library path carries")
  (exit 2))

(define self (package-of "Akku.manifest"))
(unless self
  (mismatch "Akku.manifest has no (akku-package (NAME VERSION) ...) form")
  (exit 1))

(let ((version (cadr self)) (release (latest-release "CHANGELOG.md")))
  (cond ((not release)
         (mismatch "CHANGELOG.md names no release (no `## [X.Y.Z]` heading)"))
        ((equal? version release)
         (ok (car self) " " version " is CHANGELOG.md's latest release"))
        (else
         (mismatch "Akku.manifest declares " (car self) " " version
                   ", but CHANGELOG.md's latest release is " release
                   "; bump the manifest with the release"))))

(define depends
  (let ((d (assq 'depends (caddr self))))
    (if d (cdr d) '())))

(define projects
  (let ((p (form-in "Akku.lock" 'projects)))
    (if p (cdr p) '())))

;; Each dependency: a ^VERSION range, a vendored copy at VERSION, the lock
;; at VERSION.
(for-each
 (lambda (dep)
   (let* ((name (and (pair? dep) (car dep)))
          (range (and (pair? dep) (pair? (cdr dep)) (cadr dep)))
          (m (assoc name mappings)))
     (cond
      ((not (and (string? range) (string-prefix? "^" range)))
       (mismatch "depends gives " name " the range " range "; it must be ^VERSION, VERSION the vendored one"))
      ((not m)
       (mismatch "depends names " name ", but no vendored copy of it is on the library path"))
      (else
       (let* ((floor (substring range 1 (string-length range)))
              (dir (cdr m))
              (vendored (package-of (string-append dir "/Akku.manifest"))))
         (cond
          ((not vendored)
           (mismatch dir " has no Akku.manifest; run make submodules"))
          ((not (equal? (car vendored) name))
           (mismatch dir "'s Akku.manifest is " (car vendored) "'s, not " name "'s"))
          ((not (equal? (cadr vendored) floor))
           (mismatch "depends gives " name " " range ", but " dir " is " (cadr vendored)
                     "; the floor is the vendored version"))
          (else
           (let ((url (locked-url projects name)))
             (cond
              ((eq? url 'absent)
               (mismatch "Akku.lock does not lock " name "; run akku lock"))
              ((not (and (string? url)
                         (string-prefix? (string-append name "_" floor "_") (basename url))))
               (mismatch "Akku.lock locks " name " at " url ", not at " floor
                         ", the vendored version"))
              (else
               (ok name " " range ": " dir " is " floor ", and Akku.lock locks " floor)))))))))))
 depends)

;; Each dependency is named once.
(let loop ((ds depends))
  (unless (null? ds)
    (when (and (pair? (car ds)) (assoc (caar ds) (cdr ds)))
      (mismatch "depends names " (caar ds) " twice"))
    (loop (cdr ds))))

;; Each vendored copy on the library path is a dependency.
(for-each
 (lambda (m)
   (unless (assoc (car m) depends)
     (mismatch (cdr m) " (" (car m) ") is on the library path, but Akku.manifest's depends does not name it")))
 mappings)

(exit (if failed 1 0))
