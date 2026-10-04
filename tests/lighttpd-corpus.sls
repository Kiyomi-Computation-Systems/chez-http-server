#!r6rs
;;; (lighttpd-corpus) — lighttpd's request.t blocks, read from the vendored
;;; file (decision 0007) as data, never run.  M8.3, the strictness lane.
;;;
;;; request.t is Perl, in sections headed "## ...".  A block sets
;;; `$t->{REQUEST}` to a heredoc, `$t->{RESPONSE}` to the responses it
;;; expects, each with its 'HTTP-Status', and ends with
;;; `ok($tf->handle_http($t) == 0, 'NAME')`.  This reads the blocks of the
;;; sections asked for, and refuses any line of theirs that is none of those
;;; shapes, a blank, a comment or `undef $t->{RESPONSE}`, so a refresh that
;;; brings a new one fails by its line.
;;;
;;; A heredoc `<<EOF` is Perl's interpolating kind: its \r, \n, \t, \\ and
;;; \xNN are read, and a "$" or "@" it would interpolate is refused.  The
;;; request is what LightyTest.pm's `handle_http` sends: the heredoc with
;;; each CR before an LF taken out, its last newline chomped, each LF made
;;; CRLF, then CRLF CRLF, each character a byte.
(library (lighttpd-corpus)
  (export lighttpd-path lighttpd-blocks lighttpd-blocks-of-text lighttpd-sections
          lighttpd-block-line lighttpd-block-name lighttpd-block-section
          lighttpd-block-request lighttpd-block-statuses
          lighttpd-parse-error? lighttpd-parse-error-detail)
  (import (rnrs) (only (corpus-text) trim prefix? find-sub-from last-pair split))

  ;; lighttpd-path : String — the vendored file.
  (define lighttpd-path "test/vendor/lighttpd/tests/request.t")

  ;; A block: the line its request begins on, its test name, its section,
  ;; its request's bytes, and the statuses it expects, in order.
  (define-record-type lighttpd-block (fields line name section request statuses))

  (define-condition-type &lighttpd-parse &error
    make-lighttpd-parse-error lighttpd-parse-error? (detail lighttpd-parse-error-detail))

  (define (refuse n detail)
    (let ((d (string-append "request.t:" (number->string n) ": " detail)))
      (raise (condition (make-lighttpd-parse-error d)
                        (make-who-condition 'lighttpd-corpus)
                        (make-message-condition d)))))

  ;; lighttpd-sections : -> (Listof String) — every "## " heading, in order.
  (define (lighttpd-sections)
    (map (lambda (l) (substring l 3 (string-length l)))
         (filter (lambda (l) (prefix? "## " l)) (split (file-text) #\newline))))

  ;; lighttpd-blocks : (Listof String) -> (Listof LighttpdBlock)
  ;; The blocks of the sections named, in file order.
  (define (lighttpd-blocks sections) (lighttpd-blocks-of-text (file-text) sections))

  ;; lighttpd-blocks-of-text : String (Listof String) -> (Listof LighttpdBlock)
  ;; The same of a file's text: for a test that feeds a shape no vendored
  ;; file has.
  (define (lighttpd-blocks-of-text text sections)
    (let loop ((lines (split text #\newline)) (n 1) (section #f) (request #f) (statuses #f) (blocks '()))
      (if (null? lines)
          (reverse blocks)
          (let ((l (car lines)))
            (define (next) (loop (cdr lines) (+ n 1) section request statuses blocks))
            (cond
             ((prefix? "## " l)
              (loop (cdr lines) (+ n 1) (substring l 3 (string-length l)) #f #f blocks))
             ((not (member section sections)) (next))
             ((or (string=? (trim l) "") (prefix? "#" (trim l))) (next))
             ((heredoc-start? l)
              (let-values (((body rest m) (heredoc (cdr lines) (+ n 1))))
                (unless (and (pair? rest) (string=? (car rest) " );"))
                  (refuse m "a heredoc's request ends with \" );\""))
                (loop (cdr rest) (+ m 1) section (cons n (transform body)) statuses blocks)))
             ((prefix? "$t->{RESPONSE} = [" l)
              (loop (cdr lines) (+ n 1) section request (status-list l n) blocks))
             ((string=? l "undef $t->{RESPONSE};")
              (loop (cdr lines) (+ n 1) section request #f blocks))
             ((prefix? "ok($tf->handle_http($t) == 0, '" l)
              (unless (and request statuses) (refuse n "a block's ok() before its request and responses"))
              (loop (cdr lines) (+ n 1) section #f statuses
                    (cons (make-lighttpd-block (car request) (quoted-name l n) section (cdr request) statuses)
                          blocks)))
             (else (refuse n (string-append "a line no block shape is: " l))))))))

  ;; heredoc-start? : String -> Boolean — "$t->{REQUEST}" "=" "( <<EOF".
  (define (heredoc-start? l)
    (and (prefix? "$t->{REQUEST}" l)
         (let ((rest (trim (substring l (string-length "$t->{REQUEST}") (string-length l)))))
           (string=? rest "= ( <<EOF"))))

  ;; heredoc : (Listof String) Nat -> (values String (Listof String) Nat)
  ;; The body to the line "EOF", decoded, with its final newline, as Perl
  ;; reads it; the lines after "EOF"; and the line number there.
  (define (heredoc lines n)
    (let loop ((lines lines) (n n) (acc '()))
      (cond
       ((null? lines) (refuse n "a heredoc with no \"EOF\""))
       ((string=? (car lines) "EOF")
        (values (apply string-append (map (lambda (l) (string-append l "\n")) (reverse acc)))
                (cdr lines) (+ n 1)))
       (else (loop (cdr lines) (+ n 1) (cons (decode (car lines) n) acc))))))

  ;; decode : String Nat -> String — an interpolating heredoc line's escapes.
  (define (decode l n)
    (let loop ((i 0) (acc '()))
      (cond
       ((= i (string-length l)) (list->string (reverse acc)))
       ((memv (string-ref l i) '(#\$ #\@)) (refuse n "a heredoc line that interpolates"))
       ((char=? (string-ref l i) #\\)
        (when (= (+ i 1) (string-length l)) (refuse n "a backslash at a line's end"))
        (let ((e (string-ref l (+ i 1))))
          (if (char=? e #\x)
              (let ((v (and (<= (+ i 4) (string-length l)) (string->number (substring l (+ i 2) (+ i 4)) 16))))
                (unless v (refuse n "\\x without two hex digits"))
                (loop (+ i 4) (cons (integer->char v) acc)))
              (let ((c (assv e '((#\r . #\return) (#\n . #\newline) (#\t . #\tab)
                                 (#\\ . #\\) (#\$ . #\$) (#\@ . #\@)))))
                (unless c (refuse n (string-append "an escape this reads not, \\" (string e))))
                (loop (+ i 2) (cons (cdr c) acc))))))
       (else (loop (+ i 1) (cons (string-ref l i) acc))))))

  ;; transform : String -> Bytevector — handle_http's: s/\r(?=\n)//g, chomp,
  ;; s/\n/\r\n/g, then "\r\n\r\n".
  (define (transform body)
    (let* ((cs (string->list body))
           (no-cr (let loop ((cs cs))
                    (cond ((null? cs) '())
                          ((and (char=? (car cs) #\return) (pair? (cdr cs)) (char=? (cadr cs) #\newline))
                           (loop (cdr cs)))
                          (else (cons (car cs) (loop (cdr cs)))))))
           (chomped (if (and (pair? no-cr) (char=? (car (last-pair no-cr)) #\newline))
                        (reverse (cdr (reverse no-cr)))
                        no-cr))
           (crlf (apply append (map (lambda (c) (if (char=? c #\newline) (list #\return #\newline) (list c)))
                                    chomped))))
      (u8-list->bytevector
       (map (lambda (c) (let ((v (char->integer c))) (if (< v 256) v (refuse 0 "a character past a byte"))))
            (append crlf (string->list "\r\n\r\n"))))))

  ;; status-list : String Nat -> (Listof Nat) — each 'HTTP-Status' => N.
  (define (status-list l n)
    (let loop ((from 0) (acc '()))
      (let ((at (find-sub-from l "'HTTP-Status' => " from)))
        (if (not at)
            (begin (when (null? acc) (refuse n "responses with no 'HTTP-Status'")) (reverse acc))
            (let* ((start (+ at (string-length "'HTTP-Status' => ")))
                   (end (let scan ((i start)) (if (and (< i (string-length l)) (char-numeric? (string-ref l i))) (scan (+ i 1)) i))))
              (when (= end start) (refuse n "an 'HTTP-Status' that is no number"))
              (loop end (cons (string->number (substring l start end)) acc)))))))

  ;; quoted-name : String Nat -> String — the test's name, 'NAME'.
  (define (quoted-name l n)
    (let* ((start (+ (find-sub-from l ", '" 0) 3))
           (end (find-sub-from l "'" start)))
      (unless end (refuse n "an ok() with no closing quote on its name"))
      (substring l start end)))

  ;; --- text -------------------------------------------------------------------

  ;; file-text : -> String — the vendored file, read once a process.
  (define (file-text)
    (unless text
      (let ((port (open-file-input-port lighttpd-path)))
        (set! text (utf8->string (get-bytevector-all port)))
        (close-port port)))
    text)

  (define text #f))
