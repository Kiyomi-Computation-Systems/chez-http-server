#!r6rs
;;; docs/reference.md names each name (http-server) exports, and no other,
;;; as its first line promises: everything the facade exports, one entry
;;; each.
;;;
;;; The oracles: the names (http-server) exports, as Chez's own
;;; `library-exports` lists them, not as the facade's text writes them; and
;;; the page, read by its structure, CommonMark with GitHub's tables, outside
;;; its fenced blocks.  A name is one of the page's entries when
;;; - a ### heading is it, or is a list of names, comma-separated, that holds
;;;   it.  A heading with a space inside a piece, such as "The transport", is
;;;   a section's and names nothing;
;;; - it is the first cell of a table's body row, written as one `code` span,
;;;   in a table whose first column is headed Name;
;;; - or a `code` span gives its type: `name : Type`.
;;; A name given any other way is not one: in prose, in `code` that gives no
;;; type (in a table's other cells too), under a ## heading, or in a fenced
;;; block.
;;; The reader is held to that on a page of the suite's own before it reads
;;; docs/reference.md.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) library-exports environment))

;; --- reading text ----------------------------------------------------------------

;; slurp : String -> String — the file's text.
(define (slurp path)
  (call-with-input-file path get-string-all))

;; text-lines : String -> (Listof String) — the text split at each newline.
(define (text-lines s)
  (let loop ((cs (string->list s)) (line '()) (out '()))
    (cond ((null? cs) (reverse (cons (list->string (reverse line)) out)))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse line)) out)))
          (else (loop (cdr cs) (cons (car cs) line) out)))))

;; joined : (Listof String) -> String — the lines, each ended by a newline.
(define (joined lines)
  (apply string-append (map (lambda (l) (string-append l "\n")) lines)))

;; blank? : Char -> Boolean
(define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

;; trim : String -> String — without the spaces and tabs at either end.
(define (trim s)
  (let* ((n (string-length s))
         (i (let loop ((i 0)) (if (and (< i n) (blank? (string-ref s i))) (loop (+ i 1)) i)))
         (j (let loop ((j n)) (if (and (> j i) (blank? (string-ref s (- j 1)))) (loop (- j 1)) j))))
    (substring s i j)))

;; starts? : String String -> Boolean
(define (starts? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

;; ends? : String String -> Boolean
(define (ends? s suffix)
  (let ((n (string-length s)) (k (string-length suffix)))
    (and (>= n k) (string=? (substring s (- n k) n) suffix))))

;; search : String String Nat -> (U Nat #f) — where pat next begins, from i.
(define (search s pat i)
  (let ((n (string-length s)) (k (string-length pat)))
    (let loop ((i i))
      (cond ((> (+ i k) n) #f)
            ((string=? (substring s i (+ i k)) pat) i)
            (else (loop (+ i 1)))))))

;; run : String Nat Char -> Nat — how many of c begin at i.
(define (run s i c)
  (let loop ((j i))
    (if (and (< j (string-length s)) (char=? (string-ref s j) c)) (loop (+ j 1)) (- j i))))

;; one-word? : String -> Boolean — not empty, and no space or tab inside it.
(define (one-word? s)
  (and (> (string-length s) 0) (not (exists blank? (string->list s)))))

;; --- fenced blocks and code spans --------------------------------------------------

;; fence : String -> (U (Pair Char Nat) #f)
;; A fence line's character and length (CommonMark §4.5): up to three spaces,
;; then three or more backticks or tildes.
(define (fence line)
  (let* ((indent (run line 0 #\space))
         (c (and (<= indent 3) (< indent (string-length line)) (string-ref line indent))))
    (and c (memv c '(#\` #\~))
         (let ((k (run line indent c))) (and (>= k 3) (cons c k))))))

;; closes? : String (Pair Char Nat) -> Boolean
;; Whether the line closes the block that open opened: its own character, at
;; least as many, and nothing after.
(define (closes? line open)
  (let ((f (fence line)))
    (and f (char=? (car f) (car open)) (>= (cdr f) (cdr open))
         (let ((after (substring line (+ (run line 0 #\space) (cdr f)) (string-length line))))
           (string=? (trim after) "")))))

;; prose : String -> (Listof String)
;; The text's lines, each line of a fenced block, its fences among them, as
;; a blank line.  A block no fence closes runs to the end.
(define (prose text)
  (let loop ((ls (text-lines text)) (open #f) (out '()))
    (cond ((null? ls) (reverse out))
          (open (loop (cdr ls) (if (closes? (car ls) open) #f open) (cons "" out)))
          ((fence (car ls)) => (lambda (f) (loop (cdr ls) f (cons "" out))))
          (else (loop (cdr ls) #f (cons (car ls) out))))))

;; span-text : String -> String
;; A code span's text (CommonMark §6.1): its line endings read as spaces,
;; and one space each side dropped when both are there and it is not all
;; spaces.
(define (span-text s)
  (let* ((s (list->string (map (lambda (c) (if (char=? c #\newline) #\space c)) (string->list s))))
         (n (string-length s)))
    (if (and (>= n 2) (char=? (string-ref s 0) #\space) (char=? (string-ref s (- n 1)) #\space)
             (not (for-all (lambda (c) (char=? c #\space)) (string->list s))))
        (substring s 1 (- n 1))
        s)))

;; code-spans : String -> (Listof String)
;; The text of each `code` span, in order: a run of backticks opens one, and
;; the next run of as many closes it; a run that none closes is text, and so
;; is a backtick after a backslash.
(define (code-spans text)
  (let ((n (string-length text)))
    ;; closer : Nat Nat -> (U Nat #f) — where the next run of exactly k backticks from i begins.
    (define (closer i k)
      (cond ((>= i n) #f)
            ((char=? (string-ref text i) #\`)
             (let ((m (run text i #\`))) (if (= m k) i (closer (+ i m) k))))
            (else (closer (+ i 1) k))))
    (let loop ((i 0) (out '()))
      (cond ((>= i n) (reverse out))
            ((and (char=? (string-ref text i) #\\) (< (+ i 1) n)) (loop (+ i 2) out))
            ((char=? (string-ref text i) #\`)
             (let* ((k (run text i #\`)) (j (closer (+ i k) k)))
               (if j
                   (loop (+ j k) (cons (span-text (substring text (+ i k) j)) out))
                   (loop (+ i k) out))))
            (else (loop (+ i 1) out))))))

;; only-span : String -> (U String #f) — the text of `x`, written as one code span and nothing else; else #f.
(define (only-span s)
  (let ((spans (code-spans s)))
    (and (starts? s "`") (ends? s "`") (= (length spans) 1) (car spans))))

;; unwrap : String -> String — `x` as x; anything else as it is.
(define (unwrap s) (or (only-span s) s))

;; paragraphs : (Listof String) -> (Listof String)
;; The runs of lines between blank lines, each joined: a code span lies
;; within one.
(define (paragraphs lines)
  (let loop ((ls lines) (para '()) (out '()))
    (let ((flush (lambda () (if (null? para) out (cons (joined (reverse para)) out)))))
      (cond ((null? ls) (reverse (flush)))
            ((string=? (trim (car ls)) "") (loop (cdr ls) '() (flush)))
            (else (loop (cdr ls) (cons (car ls) para) out))))))

;; --- tables ---------------------------------------------------------------------

;; has-bar? : String -> Boolean
(define (has-bar? line) (and (memv #\| (string->list line)) #t))

;; cells : String -> (Listof String)
;; A table row's cells (GitHub's tables): the row split at each bar not
;; escaped, its outer bars optional; each cell trimmed, \| read as |.
(define (cells row)
  (let* ((s (trim row))
         (parts (let loop ((cs (string->list s)) (cell '()) (out '()))
                  (cond ((null? cs) (reverse (cons (list->string (reverse cell)) out)))
                        ((and (char=? (car cs) #\\) (pair? (cdr cs)) (char=? (cadr cs) #\|))
                         (loop (cddr cs) (cons #\| cell) out))
                        ((char=? (car cs) #\|) (loop (cdr cs) '() (cons (list->string (reverse cell)) out)))
                        (else (loop (cdr cs) (cons (car cs) cell) out)))))
         (inner (let ((p (if (starts? s "|") (cdr parts) parts)))
                  (if (and (ends? s "|") (not (ends? s "\\|")) (pair? p)) (reverse (cdr (reverse p))) p))))
    (map trim inner)))

;; delimiter-row? : String -> Boolean — a row of cells each -, any number, a colon either side or not.
(define (delimiter-row? line)
  (and (has-bar? line)
       (let ((cs (cells line)))
         (and (pair? cs)
              (for-all (lambda (c)
                         (let* ((c (if (starts? c ":") (substring c 1 (string-length c)) c))
                                (c (if (ends? c ":") (substring c 0 (- (string-length c) 1)) c)))
                           (and (> (string-length c) 0)
                                (for-all (lambda (ch) (char=? ch #\-)) (string->list c)))))
                       cs)))))

;; table-names : (Listof String) -> (Listof String)
;; The first cell of each body row, written as one code span, of every table
;; whose header's first cell is Name: a header row with a bar over a
;; delimiter row of as many cells, then each row up to a blank line or a
;; line with no bar.
(define (table-names lines)
  (let scan ((ls lines) (out '()))
    (cond ((or (null? ls) (null? (cdr ls))) (reverse out))
          ((and (has-bar? (car ls)) (delimiter-row? (cadr ls))
                (= (length (cells (car ls))) (length (cells (cadr ls))))
                (equal? (unwrap (car (cells (car ls)))) "Name"))
           (let rows ((ls (cddr ls)) (out out))
             (if (or (null? ls) (string=? (trim (car ls)) "") (not (has-bar? (car ls))))
                 (scan ls out)
                 (let ((first (only-span (car (cells (car ls))))))
                   (rows (cdr ls) (if first (cons first out) out))))))
          (else (scan (cdr ls) out)))))

;; --- the page's entries ------------------------------------------------------------

;; split : String Char -> (Listof String) — the string split at each c.
(define (split s c)
  (let loop ((cs (string->list s)) (piece '()) (out '()))
    (cond ((null? cs) (reverse (cons (list->string (reverse piece)) out)))
          ((char=? (car cs) c) (loop (cdr cs) '() (cons (list->string (reverse piece)) out)))
          (else (loop (cdr cs) (cons (car cs) piece) out)))))

;; heading-names : (Listof String) -> (Listof String)
;; The names of each ### heading that is a list of names: its text split at
;; each comma, each piece trimmed, `code` unwrapped, and one word.
(define (heading-names lines)
  (apply append
         (map (lambda (line)
                (let ((pieces (map (lambda (p) (unwrap (trim p)))
                                   (split (substring line 4 (string-length line)) #\,))))
                  (if (for-all one-word? pieces) pieces '())))
              (filter (lambda (line) (starts? line "### ")) lines))))

;; typed-names : (Listof String) -> (Listof String)
;; The name each code span gives a type to: the span's text before its first
;; " : ", when that is one word.
(define (typed-names lines)
  (apply append
         (map (lambda (span)
                (let ((i (search span " : " 0)))
                  (if (and i (one-word? (substring span 0 i))) (list (substring span 0 i)) '())))
              (apply append (map code-spans (paragraphs lines))))))

;; named : String -> (Listof String)
;; The names the page's entries name, sorted, each once.
(define (named text)
  (let* ((lines (prose text))
         (all (append (heading-names lines) (table-names lines) (typed-names lines))))
    (list-sort string<?
               (fold-left (lambda (acc n) (if (member n acc) acc (cons n acc))) '() all))))

;; missing : (Listof String) (Listof String) -> (Listof String) — the names of ns not among ms, in order.
(define (missing ns ms) (filter (lambda (n) (not (member n ms))) ns))

;; noted : String (Listof String) -> (Listof String)
;; The names, said on stderr after what, when there are any: SRFI-64's
;; runner names a failed check, not its values.
(define (noted what ns)
  (unless (null? ns)
    (let ((p (current-error-port)))
      (put-string p what)
      (for-each (lambda (n) (put-char p #\space) (put-string p n)) ns)
      (put-char p #\newline)
      (flush-output-port p)))
  ns)

;; A page that holds an entry of each kind, and a name in passing of each
;; kind, and so the names the reader must take from it, and no other.
(define fixture
  (joined
   '("# A page"
     ""
     "Prose that gives `epsilon` in passing, and zeta, and"
     "`delta? : Any ->"
     "Boolean`, a type across a line."
     ""
     "## iota"
     ""
     "### alpha, beta?"
     ""
     "### `kappa`"
     ""
     "### The section"
     ""
     "| Name | Type |"
     "|:--|:--|"
     "| `gamma!` | `theta` |"
     "| lambda | `Any` |"
     ""
     "| Variable | Default |"
     "|:--|:--|"
     "| `mu` | `xi : Nat` |"
     ""
     "```text"
     "eta : Nat"
     "`omicron : Nat`"
     "### nu"
     "```")))

(run-suite "reference"
  (lambda ()
    (let ((taken (named fixture)) (entries '("alpha" "beta?" "delta?" "gamma!" "kappa" "xi")))
      (test-equal "the reader takes a page's names from its entries, and no name given in passing"
        '()
        (append (noted "the reader took, from the suite's page, names no entry names:" (missing taken entries))
                (noted "the reader missed, on the suite's page, entries' names:" (missing entries taken)))))

    (environment '(http-server))
    (let ((exported (list-sort string<? (map symbol->string (library-exports '(http-server)))))
          (page (named (slurp "docs/reference.md"))))
      (when (or (null? exported) (null? page))
        (provenance-failure "the facade's exports or docs/reference.md's entries read as none"))

      (test-equal "docs/reference.md names every name (http-server) exports"
        '()
        (noted "(http-server) exports, and docs/reference.md has no entry for:" (missing exported page)))

      (test-equal "and names none it does not export"
        '()
        (noted "docs/reference.md has an entry for, and (http-server) does not export:" (missing page exported))))))
