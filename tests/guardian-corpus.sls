#!r6rs
;;; (guardian-corpus) — AWS http-desync-guardian's test cases, read from the
;;; vendored YAML, and each case's request, written as guardian's own test
;;; harness writes it.
;;;
;;; Each case names a request line's three parts, its fields, and the tier
;;; guardian's classifier gives it: Compliant, Acceptable, Ambiguous or
;;; Severe.  Guardian classifies requests for a proxy; what our server does
;;; with each is our own expectation (tests/robustness-lane.sls).
;;;
;;; The files are YAML of one shape: a list of cases, each a map of `name`,
;;; `uri`, `method`, `version`, a list of `headers` (`name`, `value`, `tier`)
;;; and an `expected` map (`tier`, `reason`, `required_message_items`), at
;;; indents of 0, 2, 4 and 6 spaces, with whole-line comments.  This reads
;;; that shape and refuses any other line, so a refresh that brings a new one
;;; fails by name rather than being read wrong.
;;;
;;; A field's text passes two decoders, as in guardian's harness
;;; (src/request_analyzer.rs, `extract_value!`): the YAML scalar's own (a
;;; double-quoted scalar's escapes), then guardian's `unescape_value`, which
;;; reads \xNN, \b, \f, \n, \r and \t, and keeps the character after any other
;;; backslash.  A plain scalar that YAML reads as a number is formatted back
;;; as a decimal there; each in the corpus is one already, and any other is
;;; refused.  The request is "method SP uri SP version CRLF", each field as
;;; "name: value CRLF", then CRLF, as UTF-8: the harness's `raw_request`.
(library (guardian-corpus)
  (export guardian-dir guardian-files guardian-cases guardian-file-cases
          guardian-parse-text
          guardian-case-id guardian-case-name guardian-case-tier
          guardian-case-uri guardian-case-method guardian-case-version
          guardian-case-headers guardian-case-request
          guardian-parse-error? guardian-parse-error-detail)
  (import (rnrs) (only (chezscheme) directory-list)
          (only (corpus-text) split strip-cr index-of suffix?))

  ;; guardian-dir : String — where the corpus is vendored.
  (define guardian-dir "test/vendor/http-desync-guardian")

  ;; A case: its id ("file#n"), name, expected tier (Compliant, Acceptable,
  ;; Ambiguous or Severe), request line parts, headers, and request bytes.
  ;;
  ;; guardian-case-id      : GuardianCase -> String
  ;; guardian-case-name    : GuardianCase -> String
  ;; guardian-case-tier    : GuardianCase -> String
  ;; guardian-case-uri     : GuardianCase -> String
  ;; guardian-case-method  : GuardianCase -> String
  ;; guardian-case-version : GuardianCase -> String
  ;; guardian-case-headers : GuardianCase -> (Listof (Pair String String))
  ;; guardian-case-request : GuardianCase -> Bytevector
  (define-record-type guardian-case
    (fields id name tier uri method version headers request))

  ;; guardian-parse-error? : Any -> Boolean — a file was refused.
  ;; guardian-parse-error-detail : GuardianParseError -> String — why, with the
  ;; file and line.
  (define-condition-type &guardian-parse &error
    make-guardian-parse-error guardian-parse-error? (detail guardian-parse-error-detail))

  (define (refuse file line-number detail)
    (let ((d (string-append file ":" (number->string line-number) ": " detail)))
      (raise (condition (make-guardian-parse-error d)
                        (make-who-condition 'guardian-corpus)
                        (make-message-condition d)))))

  ;; guardian-files : -> (Listof String) — the YAML files, in name order.
  (define (guardian-files)
    (list-sort string<? (filter (lambda (f) (suffix? ".yaml" f))
                                (directory-list (string-append guardian-dir "/tests")))))

  ;; guardian-cases : -> (Listof GuardianCase) — every case, file by file.
  (define (guardian-cases)
    (apply append (map guardian-file-cases (guardian-files))))

  ;; guardian-file-cases : String -> (Listof GuardianCase)
  ;; The cases of one file, by its name, in order; each's id is "file#n".
  ;; Each file is read once a process.
  (define (guardian-file-cases file)
    (cond
     ((assoc file read-files) => cdr)
     (else
      (let* ((port (open-file-input-port (string-append guardian-dir "/tests/" file)))
             (text (utf8->string (get-bytevector-all port))))
        (close-port port)
        (let ((cases (parse-cases file text)))
          (set! read-files (cons (cons file cases) read-files))
          cases)))))

  ;; The files read so far, with their cases.
  (define read-files '())

  ;; guardian-parse-text : String String -> (Listof GuardianCase)
  ;; The cases of `text`, named `file` in refusals: for a test that feeds a
  ;; shape no vendored file has.
  (define (guardian-parse-text file text) (parse-cases file text))

  ;; --- the YAML ---------------------------------------------------------------

  ;; parse-cases : String String -> (Listof GuardianCase)
  ;; Each case is gathered as an association list of its fields, with its
  ;; headers and expected tier, then built once its last line is read.
  (define (parse-cases file text)
    (let loop ((lines (split text #\newline)) (n 1) (section #f) (case-fields #f) (done '()))
      (define (finish)
        (if case-fields (cons (build file (+ (length done) 1) case-fields) done) done))
      (if (null? lines)
          (reverse (finish))
          (let* ((raw (strip-cr (car lines)))
                 (indent (leading-spaces raw))
                 (rest (substring raw indent (string-length raw))))
            (define (next section fields) (loop (cdr lines) (+ n 1) section fields done))
            (define (line-refused why) (refuse file n why))
            (cond
             ((or (string=? rest "") (char=? (string-ref rest 0) #\#)) (next section case-fields))
             ((= indent 0)
              (let ((kv (item-key-value rest file n)))
                (unless (and kv (string=? (car kv) "name") (cdr kv))
                  (line-refused "a case begins with \"- name:\""))
                (loop (cdr lines) (+ n 1) #f (list (cons 'name (cdr kv))) (finish))))
             ((not case-fields) (line-refused "a line before the first case"))
             ((= indent 2)
              (let ((kv (key-value rest file n)))
                (cond
                 ((not kv) (line-refused "a case's field is key: value"))
                 ((and (member (car kv) '("uri" "method" "version")) (cdr kv))
                  (next #f (cons (cons (string->symbol (car kv)) (cdr kv)) case-fields)))
                 ((and (string=? (car kv) "headers") (not (cdr kv)))
                  (next 'headers (cons (cons 'headers '()) case-fields)))
                 ((and (string=? (car kv) "expected") (not (cdr kv)))
                  (next 'expected case-fields))
                 (else (line-refused (string-append "an unknown field: " (car kv)))))))
             ((and (= indent 4) (eq? section 'headers))
              (let ((kv (item-key-value rest file n)))
                (unless (and kv (string=? (car kv) "name") (cdr kv))
                  (line-refused "a header begins with \"- name:\""))
                (next 'headers (add-header case-fields (list (cons 'name (cdr kv)))))))
             ((and (= indent 6) (eq? section 'headers))
              (let ((kv (key-value rest file n)))
                (unless (and kv (member (car kv) '("value" "tier")) (cdr kv))
                  (line-refused "a header's field is value: or tier:"))
                (when (null? (cdr (assq 'headers case-fields)))
                  (line-refused "a header's field before its \"- name:\""))
                (next 'headers (add-header-field case-fields (string->symbol (car kv)) (cdr kv)))))
             ((and (= indent 4) (memq section '(expected items)))
              (let ((kv (key-value rest file n)))
                (cond
                 ((and kv (member (car kv) '("tier" "reason")) (cdr kv))
                  (next 'expected
                        (cons (cons (if (string=? (car kv) "tier") 'expected-tier 'reason) (cdr kv))
                              case-fields)))
                 ((and kv (string=? (car kv) "required_message_items") (not (cdr kv)))
                  (next 'items case-fields))
                 (else (line-refused "expected's field is tier:, reason: or required_message_items:")))))
             ((and (= indent 6) (eq? section 'items))
              (unless (and (> (string-length rest) 2) (string=? (substring rest 0 2) "- "))
                (line-refused "a message item is \"- text\""))
              (scalar (substring rest 2 (string-length rest)) file n)
              (next 'items case-fields))
             (else (line-refused "a line at an indent this shape has no place for")))))))

  ;; build : String Nat Alist -> GuardianCase
  (define (build file index fields)
    (define (field key)
      (let ((p (assq key fields)))
        (unless p
          (refuse file 0 (string-append "case " (number->string index) " has no " (symbol->string key))))
        (cdr p)))
    (let* ((uri (unescape (field 'uri))) (method (unescape (field 'method)))
           (version (unescape (field 'version)))
           (headers (map (lambda (h)
                           (unless (and (assq 'name h) (assq 'value h) (assq 'tier h))
                             (refuse file 0 (string-append "case " (number->string index)
                                                           " has a header without name, value and tier")))
                           (cons (unescape (cdr (assq 'name h))) (unescape (cdr (assq 'value h)))))
                         (reverse (field 'headers)))))
      (make-guardian-case
       (string-append file "#" (number->string index))
       (field 'name) (field 'expected-tier) uri method version headers
       (string->utf8
        (apply string-append
               method " " uri " " version "\r\n"
               (append (map (lambda (h) (string-append (car h) ": " (cdr h) "\r\n")) headers)
                       (list "\r\n")))))))

  ;; The headers are kept newest first, each an alist built field by field.
  (define (add-header fields header)
    (map (lambda (p) (if (eq? (car p) 'headers) (cons 'headers (cons header (cdr p))) p)) fields))
  (define (add-header-field fields key value)
    (map (lambda (p)
           (if (eq? (car p) 'headers)
               (cons 'headers (cons (cons (cons key value) (cadr p)) (cddr p)))
               p))
         fields))

  ;; key-value : String String Nat -> (U (Pair String (U String #f)) #f)
  ;; "key: scalar" as (key . text), or "key:" as (key . #f); #f otherwise.
  (define (key-value s file n)
    (let ((colon (index-of s #\:)))
      (and colon (> colon 0)
           (let ((key (substring s 0 colon)) (after (substring s (+ colon 1) (string-length s))))
             (and (for-all key-char? (string->list key))
                  (cond ((string=? (trim-right after) "") (cons key #f))
                        ((and (> (string-length after) 1) (char=? (string-ref after 0) #\space)
                              (char=? (string-ref after 1) #\space))
                         (refuse file n "two spaces after a key's colon, which YAML would drop"))
                        ((char=? (string-ref after 0) #\space)
                         (cons key (scalar (substring after 1 (string-length after)) file n)))
                        (else #f)))))))

  ;; item-key-value : String String Nat -> (U (Pair String (U String #f)) #f)
  ;; "- key: scalar", a list item that is a map's first field.
  (define (item-key-value s file n)
    (and (> (string-length s) 2) (string=? (substring s 0 2) "- ")
         (key-value (substring s 2 (string-length s)) file n)))

  (define (key-char? c) (or (char-alphabetic? c) (char=? c #\_)))

  ;; scalar : String String Nat -> String — a YAML scalar's text.
  (define (scalar s file n)
    (cond
     ((string=? s "") (refuse file n "an empty scalar"))
     ((char=? (string-ref s 0) #\") (double-quoted s file n))
     ((char=? (string-ref s 0) #\') (single-quoted s file n))
     (else (plain (trim-right s) file n))))

  ;; double-quoted : String String Nat -> String
  ;; YAML 1.2 §5.7's escapes; the closing quote ends the line.
  (define (double-quoted s file n)
    (let loop ((i 1) (acc '()))
      (cond
       ((>= i (string-length s)) (refuse file n "a double-quoted scalar with no closing quote"))
       ((char=? (string-ref s i) #\")
        (unless (string=? (trim-right (substring s (+ i 1) (string-length s))) "")
          (refuse file n "text after a double-quoted scalar"))
        (list->string (reverse acc)))
       ((char=? (string-ref s i) #\\)
        (when (>= (+ i 1) (string-length s)) (refuse file n "a backslash at a line's end"))
        (let ((e (string-ref s (+ i 1))))
          (case e
            ((#\x #\u #\U)
             (let* ((width (case e ((#\x) 2) ((#\u) 4) (else 8)))
                    (end (+ i 2 width)))
               (unless (<= end (string-length s)) (refuse file n "a short hex escape"))
               (let ((v (string->number (substring s (+ i 2) end) 16)))
                 (unless v (refuse file n "a hex escape that is not hex"))
                 (loop end (cons (integer->char v) acc)))))
            (else
             (let ((c (assv e '((#\0 . #\nul) (#\a . #\alarm) (#\b . #\backspace) (#\t . #\tab)
                                (#\tab . #\tab) (#\n . #\newline) (#\v . #\vtab) (#\f . #\page)
                                (#\r . #\return) (#\e . #\esc) (#\space . #\space) (#\" . #\")
                                (#\/ . #\/) (#\\ . #\\) (#\N . #\x85) (#\_ . #\xA0)
                                (#\L . #\x2028) (#\P . #\x2029)))))
               (unless c (refuse file n (string-append "an unknown escape \\" (string e))))
               (loop (+ i 2) (cons (cdr c) acc)))))))
       (else (loop (+ i 1) (cons (string-ref s i) acc))))))

  ;; single-quoted : String String Nat -> String — '' is a quote.
  (define (single-quoted s file n)
    (let loop ((i 1) (acc '()))
      (cond
       ((>= i (string-length s)) (refuse file n "a single-quoted scalar with no closing quote"))
       ((char=? (string-ref s i) #\')
        (if (and (< (+ i 1) (string-length s)) (char=? (string-ref s (+ i 1)) #\'))
            (loop (+ i 2) (cons #\' acc))
            (begin
              (unless (string=? (trim-right (substring s (+ i 1) (string-length s))) "")
                (refuse file n "text after a single-quoted scalar"))
              (list->string (reverse acc)))))
       (else (loop (+ i 1) (cons (string-ref s i) acc))))))

  ;; plain : String String Nat -> String
  ;; A plain scalar's text.  YAML's core schema reads some as numbers,
  ;; booleans or null, which guardian's harness formats back as a decimal or
  ;; cannot read: a decimal already is its own text; any other is refused.
  ;; A "#" that begins it, or follows a space, begins a comment YAML drops:
  ;; refused, not read on.
  (define (plain s file n)
    (cond
     ((or (char=? (string-ref s 0) #\#) (contains-comment? s))
      (refuse file n "a plain scalar with a comment, which YAML would drop"))
     ((member s '("true" "false" "True" "False" "TRUE" "FALSE" "null" "Null" "NULL" "~"))
      (refuse file n (string-append "a plain scalar YAML reads as no string: " s)))
     ((number-like? s)
      (unless (canonical-decimal? s)
        (refuse file n (string-append "a plain number that is no canonical decimal: " s)))
      s)
     (else s)))

  ;; number-like? : String -> Boolean — YAML 1.2's core schema reads it as
  ;; a number: digits with a sign or point, 0x/0o, an exponent, .inf, .nan.
  (define (number-like? s)
    (let* ((n (string-length s))
           (body (if (and (> n 0) (memv (string-ref s 0) '(#\+ #\-))) (substring s 1 n) s)))
      (or (and (> (string-length body) 0)
               (for-all (lambda (c) (or (char-numeric? c) (memv c '(#\. #\e #\E #\+ #\-))))
                        (string->list body))
               (exists char-numeric? (string->list body)))
          (and (> n 2) (member (substring s 0 2) '("0x" "0o")))
          (member s '(".inf" ".Inf" ".INF" "-.inf" "+.inf" ".nan" ".NaN" ".NAN")))))

  ;; contains-comment? : String -> Boolean — a "#" after a space or a tab.
  (define (contains-comment? s)
    (let loop ((i 1))
      (and (< i (string-length s))
           (or (and (char=? (string-ref s i) #\#)
                    (memv (string-ref s (- i 1)) '(#\space #\tab)))
               (loop (+ i 1))))))

  ;; canonical-decimal? : String -> Boolean — digits, no leading zero but "0".
  (define (canonical-decimal? s)
    (and (> (string-length s) 0)
         (for-all char-numeric? (string->list s))
         (or (= (string-length s) 1) (not (char=? (string-ref s 0) #\0)))))

  ;; unescape : String -> String — guardian's `unescape_value`.
  (define (unescape s)
    (let ((n (string-length s)))
      (let loop ((i 0) (acc '()))
        (cond
         ((= i n) (list->string (reverse acc)))
         ((not (char=? (string-ref s i) #\\)) (loop (+ i 1) (cons (string-ref s i) acc)))
         ((= (+ i 1) n) (error 'guardian-corpus "a malformed escape: a backslash at the end" s))
         (else
          (let ((e (string-ref s (+ i 1))))
            (case e
              ((#\x)
               (let ((v (and (<= (+ i 4) n) (string->number (substring s (+ i 2) (+ i 4)) 16))))
                 (unless v (error 'guardian-corpus "a malformed \\x escape" s))
                 (loop (+ i 4) (cons (integer->char v) acc))))
              ((#\b) (loop (+ i 2) (cons #\backspace acc)))
              ((#\f) (loop (+ i 2) (cons #\page acc)))
              ((#\n) (loop (+ i 2) (cons #\newline acc)))
              ((#\r) (loop (+ i 2) (cons #\return acc)))
              ((#\t) (loop (+ i 2) (cons #\tab acc)))
              (else (loop (+ i 2) (cons e acc))))))))))

  ;; --- text -------------------------------------------------------------------

  (define (leading-spaces s)
    (let loop ((i 0)) (if (and (< i (string-length s)) (char=? (string-ref s i) #\space)) (loop (+ i 1)) i)))

  (define (trim-right s)
    (let loop ((end (string-length s)))
      (if (and (> end 0) (char=? (string-ref s (- end 1)) #\space)) (loop (- end 1)) (substring s 0 end))))

)
