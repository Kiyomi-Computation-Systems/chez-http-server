#!r6rs
;;; (httpd-corpus) — Apache httpd-tests' http_strict.t request table, read from
;;; the vendored file as data, never run.
;;;
;;; The table is Perl: `my @test_cases = ( ... );`, a row `[ REQUEST =>
;;; UNSAFE, STRICT, CONDITION ]`, where REQUEST is double-quoted strings
;;; joined by `.`, UNSAFE and STRICT are what the test expects of httpd's
;;; lenient and strict hosts (STRICT, absent or undef, is UNSAFE, as the
;;; harness reads it), and CONDITION, when present, gates the row on httpd's
;;; own build.  An expectation is a number (0: any error, 1: any success, 90:
;;; an HTTP/0.9 body, else the status) or `undef` (the connection dropped, with
;;; no answer).  A request that begins "R" is a response-header test, sent
;;; through httpd's CGI.  This reads every row, decoding Perl's escapes, each
;;; character a byte, as httpd's harness sends it, and refuses any other shape
;;; by its line.
(library (httpd-corpus)
  (export httpd-path httpd-rows httpd-rows-of-text
          httpd-row-index httpd-row-request httpd-row-unsafe httpd-row-strict
          httpd-row-conditional? httpd-row-condition httpd-row-response-test?
          httpd-parse-error? httpd-parse-error-detail)
  (import (rnrs) (only (corpus-text) find-sub find-sub-from))

  ;; httpd-path : String — the vendored file.
  (define httpd-path "test/vendor/httpd-tests/t/apache/http_strict.t")

  ;; A row: its index from 1, its request's bytes, the two expectations
  ;; (a Nat or 'undef), and its condition's text, or #f for none.
  ;;
  ;; httpd-row-index     : HttpdRow -> Nat
  ;; httpd-row-request   : HttpdRow -> Bytevector
  ;; httpd-row-unsafe    : HttpdRow -> (U Nat 'undef) — the lenient host's
  ;; httpd-row-strict    : HttpdRow -> (U Nat 'undef) — the strict host's
  ;; httpd-row-condition : HttpdRow -> (U String #f)
  (define-record-type httpd-row (fields index request unsafe strict condition))

  ;; httpd-row-conditional? : HttpdRow -> Boolean — the row has a condition.
  (define (httpd-row-conditional? r) (and (httpd-row-condition r) #t))

  ;; httpd-parse-error? : Any -> Boolean — a row or the table was refused.
  ;; httpd-parse-error-detail : HttpdParseError -> String — why.
  (define-condition-type &httpd-parse &error
    make-httpd-parse-error httpd-parse-error? (detail httpd-parse-error-detail))

  (define (refuse detail)
    (raise (condition (make-httpd-parse-error detail)
                      (make-who-condition 'httpd-corpus)
                      (make-message-condition detail))))

  ;; httpd-row-response-test? : HttpdRow -> Boolean — the request begins "R".
  (define (httpd-row-response-test? r)
    (let ((bv (httpd-row-request r)))
      (and (> (bytevector-length bv) 0) (= (bytevector-u8-ref bv 0) (char->integer #\R)))))

  ;; httpd-rows : -> (Listof HttpdRow) — every row of the table, in order,
  ;; read once a process.
  (define (httpd-rows)
    (unless rows (set! rows (httpd-rows-of-text (file-text))))
    rows)

  (define rows #f)

  ;; httpd-rows-of-text : String -> (Listof HttpdRow)
  ;; The rows of a file's text: for a test that feeds a shape no vendored
  ;; file has.
  (define (httpd-rows-of-text text)
    (let loop ((cs (string->list (table-text text))) (index 1) (rows '()))
      (let ((cs (skip-space-and-comments cs)))
        (cond
         ((null? cs) (reverse rows))
         ((char=? (car cs) #\[)
          (let-values (((row rest) (parse-row (cdr cs) index)))
            (loop rest (+ index 1) (cons row rows))))
         (else (refuse (string-append "a row begins with \"[\", not: " (head-text cs))))))))

  ;; file-text : -> String — the vendored file.
  (define (file-text)
    (let* ((port (open-file-input-port httpd-path))
           (text (utf8->string (get-bytevector-all port))))
      (close-port port)
      text))

  ;; table-text : String -> String — between "my @test_cases = (" and its
  ;; ");" line.
  (define (table-text text)
    (let* ((open "my @test_cases = (")
           (start (find-sub text open)))
      (unless start (refuse "no \"my @test_cases = (\""))
      (let ((end (find-sub-from text "\n);" start)))
        (unless end (refuse "no \");\" closing the table"))
        (substring text (+ start (string-length open)) end))))

  ;; parse-row : (Listof Char) Nat -> (values HttpdRow (Listof Char))
  ;; After the "[": the request, "=>", its values, then "]" and a ",".
  (define (parse-row cs index)
    (let*-values (((request cs) (parse-strings cs))
                  ((cs) (expect "=>" (skip-space cs)))
                  ((vals cs) (parse-values cs)))
      (unless (<= 1 (length vals) 3)
        (refuse (string-append "row " (number->string index) ": one to three values after \"=>\"")))
      ;; The two expectations are numbers or undef; only the third value may
      ;; be a condition.
      (unless (for-all (lambda (v) (or (number? v) (eq? v 'undef)))
                       (if (= (length vals) 3) (list (car vals) (cadr vals)) vals))
        (refuse (string-append "row " (number->string index) ": an expectation that is no number or undef")))
      (unless (or (< (length vals) 3) (string? (caddr vals)))
        (refuse (string-append "row " (number->string index) ": a third value that is no condition")))
      (let ((cs (skip-space cs)))
        (unless (and (pair? cs) (char=? (car cs) #\,))
          (refuse (string-append "row " (number->string index) ": a \",\" after its \"]\"")))
        ;; As the harness reads it: a strict expectation absent or undef is
        ;; the lenient one (`$expect = $t->[1] if (! defined $expect)`).
        (let* ((unsafe (car vals))
               (strict (if (and (>= (length vals) 2) (not (eq? (cadr vals) 'undef))) (cadr vals) unsafe)))
          (values (make-httpd-row index request unsafe strict (and (= (length vals) 3) (caddr vals))) (cdr cs))))))

  ;; parse-strings : (Listof Char) -> (values Bytevector (Listof Char))
  ;; One or more double-quoted strings joined by ".", as bytes.
  (define (parse-strings cs)
    (let loop ((cs (skip-space cs)) (acc '()))
      (unless (and (pair? cs) (char=? (car cs) #\"))
        (refuse (string-append "a double-quoted string, not: " (head-text cs))))
      (let-values (((s rest) (perl-string (cdr cs))))
        (let ((rest (skip-space rest)) (acc (cons s acc)))
          (if (and (pair? rest) (char=? (car rest) #\.))
              (loop (skip-space (cdr rest)) acc)
              (values (latin-1 (apply string-append (reverse acc))) rest))))))

  ;; perl-string : (Listof Char) -> (values String (Listof Char))
  ;; A double-quoted string's text after its opening quote, Perl's escapes
  ;; decoded; a "$" or "@" it would interpolate is refused.
  (define (perl-string cs)
    (let loop ((cs cs) (acc '()))
      (cond
       ((null? cs) (refuse "an unterminated string"))
       ((char=? (car cs) #\") (values (list->string (reverse acc)) (cdr cs)))
       ((memv (car cs) '(#\$ #\@)) (refuse (string-append "a string that interpolates: " (head-text cs))))
       ((char=? (car cs) #\\)
        (when (null? (cdr cs)) (refuse "a backslash at the table's end"))
        (let ((e (cadr cs)))
          (if (char=? e #\x)
              (let-values (((v rest) (hex-digits (cddr cs) 2)))
                (loop rest (cons (integer->char v) acc)))
              (let ((c (assv e '((#\r . #\return) (#\n . #\newline) (#\t . #\tab) (#\0 . #\nul)
                                 (#\f . #\page) (#\e . #\esc) (#\a . #\alarm) (#\\ . #\\)
                                 (#\" . #\") (#\@ . #\@) (#\$ . #\$)))))
                (unless c (refuse (string-append "an escape this reads not, \\" (string e))))
                (loop (cddr cs) (cons (cdr c) acc))))))
       (else (loop (cdr cs) (cons (car cs) acc))))))

  ;; hex-digits : (Listof Char) Nat -> (values Nat (Listof Char)) — 1 to `most`.
  (define (hex-digits cs most)
    (let loop ((cs cs) (n 0) (v 0))
      (if (and (pair? cs) (< n most) (string->number (string (car cs)) 16))
          (loop (cdr cs) (+ n 1) (+ (* v 16) (string->number (string (car cs)) 16)))
          (begin (when (= n 0) (refuse "\\x with no digit")) (values v cs)))))

  ;; parse-values : (Listof Char) -> (values (Listof (U Nat 'undef String)) (Listof Char))
  ;; Comma-separated, to the row's "]": a number, `undef`, or a condition, as
  ;; its text (a `$name`, or a call such as `have_module qw(mod_headers)`).
  (define (parse-values cs)
    (let loop ((cs (skip-space cs)) (acc '()))
      (let-values (((v rest) (parse-value cs)))
        (let ((rest (skip-space rest)) (acc (cons v acc)))
          (cond
           ((and (pair? rest) (char=? (car rest) #\])) (values (reverse acc) (cdr rest)))
           ((and (pair? rest) (char=? (car rest) #\,)) (loop (skip-space (cdr rest)) acc))
           (else (refuse (string-append "a \",\" or \"]\" after a value, not: " (head-text rest)))))))))

  (define (parse-value cs)
    (cond
     ((null? cs) (refuse "a value at the table's end"))
     ((char-numeric? (car cs))
      (let loop ((cs cs) (digits '()))
        (if (and (pair? cs) (char-numeric? (car cs)))
            (loop (cdr cs) (cons (car cs) digits))
            (values (string->number (list->string (reverse digits))) cs))))
     ((prefix-chars? "undef" cs) (values 'undef (list-tail cs 5)))
     ((or (char=? (car cs) #\$) (char-alphabetic? (car cs)))
      ;; a condition: to the "]" or "," that ends it, past any parentheses
      (let loop ((rest cs) (depth 0) (text '()))
        (cond ((null? rest) (refuse "a condition with no end"))
              ((char=? (car rest) #\() (loop (cdr rest) (+ depth 1) (cons (car rest) text)))
              ((char=? (car rest) #\)) (loop (cdr rest) (- depth 1) (cons (car rest) text)))
              ((and (= depth 0) (memv (car rest) '(#\] #\,)))
               (values (trim-chars (reverse text)) rest))
              (else (loop (cdr rest) depth (cons (car rest) text))))))
     (else (refuse (string-append "a value, not: " (head-text cs))))))

  ;; --- text -------------------------------------------------------------------

  ;; skip-space-and-comments : (Listof Char) -> (Listof Char)
  ;; Past whitespace and whole "#" comments, to a row.
  (define (skip-space-and-comments cs)
    (let ((cs (skip-space cs)))
      (if (and (pair? cs) (char=? (car cs) #\#))
          (skip-space-and-comments (let loop ((cs cs)) (if (or (null? cs) (char=? (car cs) #\newline)) cs (loop (cdr cs)))))
          cs)))

  (define (skip-space cs) (if (and (pair? cs) (char-whitespace? (car cs))) (skip-space (cdr cs)) cs))

  ;; trim-chars : (Listof Char) -> String — the text, whitespace off its ends.
  (define (trim-chars cs)
    (list->string (reverse (skip-space (reverse (skip-space cs))))))

  (define (expect word cs)
    (if (prefix-chars? word cs)
        (list-tail cs (string-length word))
        (refuse (string-append "\"" word "\", not: " (head-text cs)))))

  (define (prefix-chars? word cs)
    (let loop ((i 0) (cs cs))
      (cond ((= i (string-length word)) #t)
            ((and (pair? cs) (char=? (car cs) (string-ref word i))) (loop (+ i 1) (cdr cs)))
            (else #f))))

  (define (head-text cs)
    (list->string (let loop ((cs cs) (n 0)) (if (or (null? cs) (= n 40)) '() (cons (car cs) (loop (cdr cs) (+ n 1)))))))

  ;; latin-1 : String -> Bytevector — each character a byte, as Perl sends a
  ;; byte string.
  (define (latin-1 s)
    (let ((bv (make-bytevector (string-length s))))
      (let loop ((i 0))
        (when (< i (string-length s))
          (let ((c (char->integer (string-ref s i))))
            (unless (< c 256) (refuse "a character past a byte"))
            (bytevector-u8-set! bv i c)
            (loop (+ i 1)))))
      bv))

)
