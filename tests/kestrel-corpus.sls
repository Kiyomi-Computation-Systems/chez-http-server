#!r6rs
;;; (kestrel-corpus) — ASP.NET Core Kestrel's HTTP/1 parsing tables, read from
;;; the vendored HttpParsingData.cs as data, never compiled.
;;;
;;; The file is C#: each table is a property whose body builds an array of
;;; string literals, one row a line, and a few end by appending another table
;;; (`}.Concat(...)`).  This reads one table by name: the first string literal
;;; of each row line between the array's `{` and its `}`, decoded by C#'s
;;; escapes, and the text after the `}`, its tail, which tells what the table
;;; appends.  The appending itself is the lane's to port (tests/
;;; strictness-lane.sls), with a check that each tail still reads as ported.
;;; A row line with no literal, a row past ASCII, an escape C# has not, an
;;; array opened on its constructor's line, or a table not found is refused
;;; by name, so a refresh that brings a new shape fails rather than being
;;; read wrong.
(library (kestrel-corpus)
  (export kestrel-path kestrel-table kestrel-table-tail kestrel-table-of-text
          kestrel-parse-error? kestrel-parse-error-detail)
  (import (rnrs) (only (corpus-text) strip-cr trim prefix? find-sub last-pair split))

  ;; kestrel-path : String — the vendored file.
  (define kestrel-path "test/vendor/kestrel/src/Servers/Kestrel/shared/test/HttpParsingData.cs")

  ;; kestrel-parse-error? : Any -> Boolean — a table was refused.
  ;; kestrel-parse-error-detail : KestrelParseError -> String — why.
  (define-condition-type &kestrel-parse &error
    make-kestrel-parse-error kestrel-parse-error? (detail kestrel-parse-error-detail))

  (define (refuse detail)
    (raise (condition (make-kestrel-parse-error detail)
                      (make-who-condition 'kestrel-corpus)
                      (make-message-condition detail))))

  ;; kestrel-table : String -> (Listof String)
  ;; The rows of the table named `name`, in order: each row line's first
  ;; string literal, decoded.
  (define (kestrel-table name) (car (table name)))

  ;; kestrel-table-tail : String -> String
  ;; What follows the table's closing `}` on its line, up to the `;`, as
  ;; written: "" for a table that appends nothing.
  (define (kestrel-table-tail name) (cdr (table name)))

  ;; kestrel-table-of-text : String String -> (Listof String)
  ;; The rows of the table named `name` in a file's text: for a test that
  ;; feeds a shape no vendored file has.
  (define (kestrel-table-of-text text name) (car (table-of-lines (text-lines text) name)))

  ;; table : String -> (Pair (Listof String) String)
  (define (table name) (table-of-lines (file-lines) name))

  ;; table-of-lines : (Listof String) String -> (Pair (Listof String) String)
  (define (table-of-lines lines name)
    (let loop ((lines lines) (n 1) (state 'seek) (rows '()))
      (when (null? lines)
        (refuse (string-append name ": " (if (eq? state 'seek) "no such table" "no closing brace"))))
      (let* ((line (car lines)) (t (trim line)))
        (case state
          ((seek)                       ; to the declaration, then its array's constructor
           (loop (cdr lines) (+ n 1)
                 (cond ((not (declares? t name)) 'seek)
                       ((constructs? t) (opens-alone t name n))
                       (else 'constructor))
                 rows))
          ((constructor)                ; past a getter's own braces, to `return new[]`
           (loop (cdr lines) (+ n 1) (if (constructs? t) (opens-alone t name n) 'constructor) rows))
          ((opening)                    ; to the array's own "{"
           (loop (cdr lines) (+ n 1) (if (string=? t "{") 'rows 'opening) rows))
          (else
           (cond
            ((or (string=? t "") (prefix? "//" t)) (loop (cdr lines) (+ n 1) 'rows rows))
            ((prefix? "}" t) (cons (reverse rows) (tail-of t)))
            ((first-literal t)
             => (lambda (s)
                  (unless (for-all (lambda (c) (< (char->integer c) 128)) (string->list s))
                    (refuse (string-append name ": line " (number->string n)
                                           " is a row past ASCII, which Kestrel's tests send as ASCII")))
                  (loop (cdr lines) (+ n 1) 'rows (cons s rows))))
            (else (refuse (string-append name ": line " (number->string n)
                                         " is no row with a string literal")))))))))

  ;; declares? : String String -> Boolean
  ;; The trimmed line declares a public static property named `name`: its
  ;; last word, or the word before " =>".
  (define (declares? t name)
    (and (prefix? "public static " t)
         (let* ((head (let ((arrow (find-sub t " =>"))) (if arrow (substring t 0 arrow) t)))
                (words (split head #\space)))
           (and (pair? words) (string=? (car (last-pair words)) name)))))

  ;; constructs? : String -> Boolean — the line builds the table's array:
  ;; `new[]` or `new TheoryData<...>`, whose `{` opens the rows.
  (define (constructs? t)
    (and (or (find-sub t "new[]") (find-sub t "new TheoryData<")) #t))

  ;; opens-alone : String String Nat -> Symbol
  ;; 'opening, the array's "{" to come on a line of its own; an array opened
  ;; on its constructor's line is refused, since reading on would take the
  ;; next table's "{".
  (define (opens-alone t name n)
    (when (find-sub t "{")
      (refuse (string-append name ": line " (number->string n) " opens its array on its constructor's line")))
    'opening)

  ;; tail-of : String -> String — "}.Concat(X);" -> ".Concat(X)"; "};" -> "".
  (define (tail-of t)
    (let* ((s (substring t 1 (string-length t)))
           (end (let loop ((i (string-length s)))
                  (if (and (> i 0) (memv (string-ref s (- i 1)) '(#\; #\space))) (loop (- i 1)) i))))
      (substring s 0 end)))

  ;; first-literal : String -> (U String #f)
  ;; The line's first regular string literal: a `"` not after `@` (verbatim)
  ;; or `$` (interpolated), decoded; #f when there is none.
  (define (first-literal t)
    (let loop ((i 0))
      (cond
       ((>= i (string-length t)) #f)
       ((and (char=? (string-ref t i) #\")
             (not (and (> i 0) (memv (string-ref t (- i 1)) '(#\@ #\$)))))
        (literal t (+ i 1)))
       (else (loop (+ i 1))))))

  ;; literal : String Nat -> String — C#'s escapes, to the closing quote.
  (define (literal t i)
    (let loop ((i i) (acc '()))
      (cond
       ((>= i (string-length t)) (refuse (string-append "an unterminated literal: " t)))
       ((char=? (string-ref t i) #\") (list->string (reverse acc)))
       ((char=? (string-ref t i) #\\)
        (when (>= (+ i 1) (string-length t)) (refuse (string-append "a backslash at a line's end: " t)))
        (let ((e (string-ref t (+ i 1))))
          (case e
            ((#\x) (let ((j (hex-end t (+ i 2) 4)))
                     (when (= j (+ i 2)) (refuse (string-append "\\x with no digit: " t)))
                     (loop j (cons (integer->char (string->number (substring t (+ i 2) j) 16)) acc))))
            ((#\u #\U)
             (let ((j (+ i 2 (if (char=? e #\u) 4 8))))
               (unless (and (<= j (string-length t)) (= (hex-end t (+ i 2) (- j i 2)) j))
                 (refuse (string-append "a short \\u escape: " t)))
               (loop j (cons (integer->char (string->number (substring t (+ i 2) j) 16)) acc))))
            (else
             (let ((c (assv e '((#\r . #\return) (#\n . #\newline) (#\t . #\tab) (#\0 . #\nul)
                                (#\\ . #\\) (#\" . #\") (#\' . #\') (#\a . #\alarm)
                                (#\b . #\backspace) (#\f . #\page) (#\v . #\vtab)))))
               (unless c (refuse (string-append "an escape C# has not, \\" (string e) ": " t)))
               (loop (+ i 2) (cons (cdr c) acc)))))))
       (else (loop (+ i 1) (cons (string-ref t i) acc))))))

  ;; hex-end : String Nat Nat -> Nat — past up to `most` hex digits from `i`.
  (define (hex-end t i most)
    (let loop ((j i))
      (if (and (< j (string-length t)) (< (- j i) most)
               (string->number (string (string-ref t j)) 16))
          (loop (+ j 1))
          j)))

  ;; --- text -------------------------------------------------------------------

  ;; file-lines : -> (Listof String) — the vendored file's lines, read once
  ;; a process.
  (define (file-lines)
    (unless lines
      (let* ((port (open-file-input-port kestrel-path))
             (text (utf8->string (get-bytevector-all port))))
        (close-port port)
        (set! lines (text-lines text))))
    lines)

  (define lines #f)

  (define (text-lines text) (map strip-cr (split text #\newline)))

)
