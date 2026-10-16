#!r6rs
;;; The import audit: what a library under src/ may import.
;;;
;;; - (chezscheme) and (libuv ...) only under src/http-server/private/.  The
;;;   facade, src/http-server.sls, reaches them through private/.
;;; - No test library in src/: (uv-testing) and (httparse test ...) are on the
;;;   library path for the suites alone.
;;; - No (libuv private ...) in src/: the shell uses chez-libuv's public verbs
;;;   only.
;;; - Nothing a parser feed runs can reach the scheduler, since a parser
;;;   callback never waits (R5).  The pure libraries, src/http-server/*.sls,
;;;   import no (http-server private ...) library, and the adapter neither the
;;;   scheduler, nor the shell or serve, which turn it, nor the waits, which
;;;   park on it.
;;;
;;; The check reads each library with Chez's own reader and takes the
;;; libraries its import forms name (a text scan is fooled by a comment or a
;;; string naming one).  Every (import ...) and (import-only ...) form counts,
;;; the library's own and any in its body, and so does each quoted argument to
;;; `environment`.
;;;
;;; Oracles: the fixtures below, source texts whose imports are known; and the
;;; file tree under src/.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list file-directory?))

;; A LibraryName is a list of symbols, such as (http-server private waits).

;; imports : Datum -> (Listof LibraryName)
;; Every library `datum` names in an (import ...) or (import-only ...) form,
;; or in a quoted argument to `environment`, wherever it sits, in order.
(define (imports datum)
  (let walk ((d datum))
    (cond ((pair? d)
           (case (car d)
             ((import import-only) (import-set-names (cdr d)))
             ((environment) (import-set-names (map cadr (filter quoted? (proper (cdr d))))))
             (else (apply append (map walk (proper d))))))
          ((vector? d) (apply append (map walk (vector->list d))))
          (else '()))))

;; quoted? : Datum -> Boolean — a (quote x) form.
(define (quoted? d)
  (and (pair? d) (eq? (car d) 'quote) (pair? (cdr d))))

;; proper : Datum -> (List Datum) — the elements of a list, proper or not;
;; an improper list's last cdr is its last element.
(define (proper d)
  (cond ((pair? d) (cons (car d) (proper (cdr d))))
        ((null? d) '())
        (else (list d))))

;; import-set-names : Datum -> (Listof LibraryName)
(define (import-set-names sets)
  (filter values (map import-set-name (proper sets))))

;; import-set-name : Datum -> (U LibraryName #f)
;; The library an import set draws on, through only, except, prefix, rename,
;; for, and Chez's alias, add-prefix and drop-prefix; (library ref) names ref.
(define (import-set-name set)
  (cond ((not (pair? set)) #f)
        ((and (memq (car set) '(only except prefix rename for alias add-prefix drop-prefix))
              (pair? (cdr set)))
         (import-set-name (cadr set)))
        ((and (eq? (car set) 'library) (pair? (cdr set)))
         (reference-name (cadr set)))
        (else (reference-name set))))

;; reference-name : Datum -> (U LibraryName #f)
;; The name a library reference gives, its version left off: (libuv (1)) names
;; (libuv).
(define (reference-name ref)
  (let loop ((r ref) (acc '()))
    (if (and (pair? r) (symbol? (car r)))
        (loop (cdr r) (cons (car r) acc))
        (and (pair? acc) (reverse acc)))))

;; A rule: its tag, the message a breach prints, and `forbids?`, which says
;; whether the library at a path may not import a library name.
(define-record-type rule (fields tag message forbids?))

;; starts? : LibraryName LibraryName -> Boolean — `name` is `prefix` or below it.
(define (starts? name prefix)
  (cond ((null? prefix) #t)
        ((pair? name) (and (eq? (car name) (car prefix)) (starts? (cdr name) (cdr prefix))))
        (else #f)))

;; string-prefix? : String String -> Boolean
(define (string-prefix? prefix s)
  (let ((n (string-length prefix)))
    (and (<= n (string-length s)) (string=? prefix (substring s 0 n)))))

;; pure? : String -> Boolean — a library directly in src/http-server/.
(define (pure? path)
  (let ((dir "src/http-server/"))
    (and (string-prefix? dir path)
         (not (memv #\/ (string->list (substring path (string-length dir) (string-length path))))))))

(define adapter "src/http-server/private/adapter.sls")

(define rules
  (list
   (make-rule 'impure "IMPURE IMPORT outside src/http-server/private/:"
              (lambda (path name)
                (and (not (string-prefix? "src/http-server/private/" path))
                     (or (starts? name '(chezscheme)) (starts? name '(libuv))))))
   (make-rule 'test-only "TEST-ONLY IMPORT in a shipped library:"
              (lambda (path name)
                (or (starts? name '(uv-testing)) (starts? name '(httparse test)))))
   (make-rule 'libuv-private "CHEZ-LIBUV PRIVATE IMPORT in a shipped library:"
              (lambda (path name) (starts? name '(libuv private))))
   (make-rule 'feed "PRIVATE IMPORT in code a parser feed runs, which could reach the scheduler (R5):"
              (lambda (path name)
                (or (and (pure? path) (starts? name '(http-server private)))
                    (and (string=? path adapter)
                         (member name '((http-server private scheduler) (http-server private waits)
                                        (http-server private shell) (http-server private serve)))
                         #t))))))

;; forbidden : Rule String (Listof LibraryName) -> (Listof LibraryName)
;; The names in `names` that `rule` forbids the library at `path`, in order.
(define (forbidden rule path names)
  (filter (lambda (name) ((rule-forbids? rule) path name)) names))

;; read-all : TextualInputPort -> (Listof Datum)
(define (read-all port)
  (let loop ((acc '()))
    (let ((d (read port)))
      (if (eof-object? d) (reverse acc) (loop (cons d acc))))))

;; text-imports : String -> (Listof LibraryName)
(define (text-imports text)
  (apply append (map imports (read-all (open-string-input-port text)))))

;; breaches : String String -> (Listof (Pair Symbol LibraryName))
;; Each import in `text`, read as the library at `path`, that a rule
;; forbids, as (tag . name): rule by rule, names in order within each.
(define (breaches path text)
  (let ((names (text-imports text)))
    (apply append
           (map (lambda (rule)
                  (map (lambda (name) (cons (rule-tag rule) name))
                       (forbidden rule path names)))
                rules))))

;; libraries : String -> (Listof String) — every .sls file under `dir`.
(define (libraries dir)
  (apply append
         (map (lambda (name)
                (let ((path (string-append dir "/" name))
                      (n (string-length name)))
                  (cond ((file-directory? path) (libraries path))
                        ((and (> n 4) (string=? (substring name (- n 4) n) ".sls")) (list path))
                        (else '()))))
              (directory-list dir))))

;; file-imports : String -> (Listof LibraryName)
(define (file-imports path)
  (let* ((port (open-file-input-port path (file-options) (buffer-mode block)
                                     (make-transcoder (utf-8-codec))))
         (found (apply append (map imports (read-all port)))))
    (close-port port)
    found))

;; written : Datum -> String
(define (written datum)
  (call-with-string-output-port (lambda (p) (write datum p))))

;; note : String -> unspecified — one line to stderr.
(define (note line)
  (let ((p (current-error-port)))
    (put-string p line) (put-char p #\newline) (flush-output-port p)))

;; Source texts, the path each is read as, and the breaches each holds.
(define fixtures
  '(;; (chezscheme) and (libuv ...) only under private/
    ("(chezscheme) in a pure library" "src/http-server/body.sls"
     "(library (http-server body) (export) (import (rnrs) (chezscheme)))"
     ((impure chezscheme)))
    ("(libuv) through only, in the facade" "src/http-server.sls"
     "(library (http-server) (export) (import (rnrs) (only (libuv) uv-run)))"
     ((impure libuv)))
    ("(libuv tcp) with a version, below a pure library" "src/http-server/extra/x.sls"
     "(library (http-server extra x) (export) (import (rnrs) (libuv tcp (0 11))))"
     ((impure libuv tcp)))
    ("(chezscheme) for run, through the library escape" "src/http-server/body.sls"
     "(library (http-server body) (export) (import (rnrs) (for (library (chezscheme)) run)))"
     ((impure chezscheme)))
    ("(chezscheme) through environment" "src/http-server/body.sls"
     "(library (http-server body) (export) (import (rnrs) (rnrs eval)) (define e (environment '(rnrs) '(chezscheme))))"
     ((impure chezscheme)))
    ("(chezscheme) and (libuv) in a private library" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) (chezscheme) (libuv)))"
     ())
    ("a comment naming (chezscheme) in a pure library" "src/http-server/body.sls"
     ";;; `body` is (chezscheme)'s, and (libuv)'s\n(library (http-server body) (export) (import (rnrs)))"
     ())
    ;; no test library in src/
    ("(uv-testing) in a private library" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) (uv-testing)))"
     ((test-only uv-testing)))
    ("(httparse test corpus) through prefix" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) (prefix (httparse test corpus) t:)))"
     ((test-only httparse test corpus)))
    ("a block comment and a string naming test libraries" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs)) #| (import (uv-testing)) |# (define s \"(import (httparse test corpus))\"))"
     ())
    ;; no (libuv private ...) in src/
    ("(libuv private handles) through only, in the shell" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) (only (libuv private handles) loop-pointer)))"
     ((libuv-private libuv private handles)))
    ("(libuv private handles) in a pure library breaks two rules" "src/http-server/body.sls"
     "(library (http-server body) (export) (import (rnrs) (libuv private handles)))"
     ((impure libuv private handles) (libuv-private libuv private handles)))
    ("(libuv private handles) through an import in a body" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (chezscheme)) (define (f) (import (libuv private handles)) 1))"
     ((libuv-private libuv private handles)))
    ("a datum comment naming (libuv private handles)" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) #;(libuv private handles)))"
     ())
    ;; nothing a parser feed runs reaches the scheduler
    ("(http-server private waits) in a pure library" "src/http-server/awaiting.sls"
     "(library (http-server awaiting) (export) (import (rnrs) (http-server private waits)))"
     ((feed http-server private waits)))
    ("(http-server private adapter) through except, in a pure library" "src/http-server/body.sls"
     "(library (http-server body) (export) (import (rnrs) (except (http-server private adapter) adapter-bindings)))"
     ((feed http-server private adapter)))
    ("the scheduler, the waits, the shell and serve in the adapter" "src/http-server/private/adapter.sls"
     "(library (http-server private adapter) (export) (import (rnrs) (http-server private scheduler) (rename (http-server private waits) (park! p!)) (http-server private shell) (only (http-server private serve) serve)))"
     ((feed http-server private scheduler) (feed http-server private waits)
      (feed http-server private shell) (feed http-server private serve)))
    ("the adapter's own imports" "src/http-server/private/adapter.sls"
     "(library (http-server private adapter) (export) (import (rnrs) (byte-machine runtime) (generated httparse-message) (httparse modes) (http-server connection)))"
     ())
    ("serve in the facade" "src/http-server.sls"
     "(library (http-server) (export) (import (rnrs) (only (http-server private serve) serve)))"
     ())
    ("the scheduler in the shell" "src/http-server/private/shell.sls"
     "(library (http-server private shell) (export) (import (rnrs) (http-server private scheduler)))"
     ())
    ("a comment naming the waits in a pure library" "src/http-server/awaiting.sls"
     ";;; `resolve` is (http-server private waits)'s\n(library (http-server awaiting) (export) (import (rnrs)))"
     ())
    ("a comment naming the scheduler in the adapter" "src/http-server/private/adapter.sls"
     "(library (http-server private adapter) (export) (import (rnrs) ; (http-server private scheduler)\n (http-server connection)))"
     ())))

(run-suite "imports"
  (lambda ()
    (for-each (lambda (fixture)
                (test-equal (car fixture) (cadddr fixture) (breaches (cadr fixture) (caddr fixture))))
              fixtures)
    (let* ((tree (map (lambda (path) (cons path (file-imports path))) (libraries "src")))
           (held (map (lambda (path) (and (assoc path tree) #t)) (list "src/http-server.sls" adapter)))
           (unread (map car (filter (lambda (entry) (null? (cdr entry))) tree))))
      (test-equal "src/ holds the facade and the adapter" '(#t #t) held)
      (test-equal "each library under src/ has its imports read" '() unread)
      (let ((clean
             (map (lambda (rule)
                    (let ((found (apply append
                                        (map (lambda (entry)
                                               (map (lambda (name)
                                                      (string-append (car entry) " imports " (written name)))
                                                    (forbidden rule (car entry) (cdr entry))))
                                             tree))))
                      (unless (null? found)
                        (note (rule-message rule))
                        (for-each note found))
                      (test-equal (rule-message rule) '() found)
                      (null? found)))
                  rules)))
        (when (and (equal? held '(#t #t)) (null? unread) (for-all values clean))
          (display "import audit ok: no (libuv)/(chezscheme) outside src/http-server/private/, the facade's included; no test library and no chez-libuv private library in src/; no private library in the pure ones, and no scheduler, waits, shell or serve in the adapter")
          (newline))))))
