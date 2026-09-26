#!r6rs
;;; One procedure closes every handle: handle-close!, the one use of
;;; `uv-close!` in src/ (design §5.3; decided 2026-09-26).  chez-libuv runs
;;; the callback of a handle's first close alone, so a close from anywhere
;;; else could run first and leave the shell's own callback never run.
;;;
;;; M4.2 held this with an awk scan of the text, which a `;` in a string, a
;;; `#\;`, or two uses one character apart got past (M4.3's review).  This
;;; reads the source with Chez's own reader, so it walks the code the
;;; compiler sees: every use of the name `uv-close!` (a call, an alias, an
;;; argument to `apply`, a rename in an import) is named with the definition
;;; it sits in, and a comment, a datum comment or a string is none.
;;;
;;; Oracles: the fixtures below, source texts whose uses are known; and the
;;; file tree under src/.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) directory-list file-directory?))

;; uses : Datum -> (Listof Symbol)
;; The definition each use of `uv-close!` in `datum` sits in, in order: the
;; name the innermost enclosing define binds, or `top-level`.
(define (uses datum)
  (let walk ((d datum) (owner 'top-level))
    (cond ((eq? d 'uv-close!) (list owner))
          ((pair? d)
           (let ((owner (defined-name d owner)))
             (let each ((d d) (acc '()))
               (cond ((pair? d) (each (cdr d) (append acc (walk (car d) owner))))
                     ((null? d) acc)
                     (else (append acc (walk d owner)))))))
          ((vector? d) (apply append (map (lambda (x) (walk x owner)) (vector->list d))))
          (else '()))))

;; defined-name : Pair Symbol -> Symbol
;; The name `form` binds if it is (define name ...) or (define (name ...)
;; ...), else `owner`.
(define (defined-name form owner)
  (if (and (eq? (car form) 'define) (pair? (cdr form)))
      (let target ((t (cadr form)))
        (if (pair? t) (target (car t)) t))
      owner))

;; read-all : TextualInputPort -> (Listof Datum)
(define (read-all port)
  (let loop ((acc '()))
    (let ((d (read port)))
      (if (eof-object? d) (reverse acc) (loop (cons d acc))))))

;; uses-in-text : String -> (Listof Symbol)
(define (uses-in-text text)
  (apply append (map uses (read-all (open-string-input-port text)))))

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

;; uses-under : String -> (Listof (Pair String Symbol))
;; Each use of `uv-close!` in a library under `dir`, as (file . definition).
(define (uses-under dir)
  (apply append
         (map (lambda (path)
                (let ((port (open-file-input-port path (file-options) (buffer-mode block)
                                                  (make-transcoder (utf-8-codec)))))
                  (let ((found (apply append (map uses (read-all port)))))
                    (close-port port)
                    (map (lambda (owner) (cons path owner)) found))))
              (libraries dir))))

;; Source texts whose uses are known, and those uses.
(define fixtures
  '(("a call" "(define (f h) (uv-close! h))" (f))
    ("two calls on one line" "(define (f h) (uv-close! h) (uv-close! h))" (f f))
    ("two uses one character apart" "(define (f h) (for-each (lambda (g) (g h)) (list uv-close! uv-close!)))" (f f))
    ("a call after a semicolon in a string" "(define (f h) (log! \"at once; unserved\") (uv-close! h))" (f))
    ("a call after a semicolon character" "(define (f h c) (if (eqv? c #\\;) #f (uv-close! h)))" (f))
    ("an alias" "(define shut uv-close!)" (shut))
    ("an argument to apply" "(define (f h) (apply uv-close! (list h)))" (f))
    ("a rename in an import" "(library (x) (export) (import (rename (libuv) (uv-close! shut))))" (top-level))
    ("a call in a definition inside another" "(define (outer) (define (inner h) (uv-close! h)) inner)" (inner))
    ("comments are not uses" "(define (f h) ; (uv-close! h)\n #;(uv-close! h) #| (uv-close! h) |# h)" ())
    ("a string naming it is not a use" "(define (f) \"uv-close!\")" ())))

(run-suite "close-ownership"
  (lambda ()
    (for-each (lambda (fixture)
                (test-equal (car fixture) (caddr fixture) (uses-in-text (cadr fixture))))
              fixtures)
    (test-equal "src/ uses uv-close! once, in handle-close!"
                '(("src/http-server/private/shell.sls" . handle-close!))
                (uses-under "src"))))
