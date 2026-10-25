#!r6rs
;;; (http-server view) — what a handler sees of a request (pure).
;;;
;;; A handler reads the request through accessors that copy what it asks for.
;;; The path, the query, a header's name and value, and the host are strings,
;;; each made when it is asked for, a character per byte: the byte n reads as
;;; the character whose code point is n, as Latin-1 reads it, so every byte
;;; comes back as the byte it was.  The method is the request's own, the symbol
;;; llhttp names.  A handler that asks for nothing costs nothing: the request
;;; holds spans of the delivery it arrived in, and a handler that keeps the
;;; request, or a span of it, keeps that delivery too.
;;;
;;; Nothing is decoded.  The path and the query are as the client sent them,
;;; percent-encoding and all.  A header's value is its bytes without the
;;; whitespace around it (RFC 9112 §5): llhttp leaves out what comes before a
;;; value and keeps what comes after.  `request-header` reads a name's first
;;; field, and `request-header-values` every field of it, in the order they
;;; came, since a list may run over several lines (RFC 9110 §5.3).
;;; `request-header-list` reads every field line, each name as sent: names
;;; are case-insensitive (RFC 9110 §5.1), so a caller folds case itself.
;;;
;;; THE QUERY is what follows the target's first "?", in every form.  A "?"
;;; can be in neither an authority nor a path (RFC 3986 §3.2 and §3.3), and
;;; the judge refuses a fragment, so the first "?" begins the query; "*" and
;;; an authority-form target have none.
;;;
;;; THE TARGET'S FORM says where the path and the host are (RFC 9112 §3.2),
;;; read by (http-server target)'s `target-form`, the judge's own rule:
;;;
;;;   form       path                      host
;;;   origin     up to the first "?"       the Host field's
;;;   absolute   the URI's, "/" if empty   the URI's authority
;;;   asterisk   "*"                       the Host field's
;;;   authority  ""                        the Host field's
;;;
;;; An absolute-form target's host is its authority, whatever the Host field
;;; says (RFC 9112 §3.2.2).  Its parts are uriparse's, parsed when they are
;;; asked for by a collector of their own: the judge has accepted the target,
;;; and absolute-form is rare, a proxy's.  llhttp takes an absolute-form
;;; target only with a "//", so it always has an authority, which may be
;;; empty ("ftp:///x").  An empty path reads "/", its normal form (RFC 9110
;;; §4.2.3).  The Host field's value may be empty, and a request with no Host
;;; reads empty too.
;;;
;;; PURE: imports (rnrs), (rnrs mutable-strings) to fill the strings it makes,
;;; (uri ...) and this project's own libraries.
(library (http-server view)
  (export request-path request-query request-header request-header-values request-header-list
          request-host)
  (import (rnrs) (rnrs mutable-strings)
          (http-server request)
          (http-server span)
          (only (http-server headers) headers-ref headers-ref-all trim-ows)
          (only (http-server target) target-form first-question)
          (only (uri collect)
                make-uri-collector uri-collect-feed! uri-collect-finish!
                uri-parse-ok? uri-parse-components)
          (only (uri components) uri-components-authority uri-components-path))

  (define HOST (string->utf8 "host"))

  ;; request-path : Request -> String
  ;; The target's path, as sent, by the table above.
  (define (request-path r)
    (let ((t (request-target r)))
      (case (target-form (request-method r) t)
        ((origin)
         (let ((bv (span-bytevector t)) (start (span-start t)))
           (latin-1 bv start (first-question bv start (span-end t)))))
        ((absolute)
         (let ((path (uri-components-path (absolute-parts t))))
           (if (fx=? (bytevector-length path) 0) (string #\/) (whole path))))
        ((asterisk) (string #\*))
        (else (string)))))

  ;; request-query : Request -> (U String #f)
  ;; The target's query, as sent: what follows its first "?", which may be
  ;; empty, or #f when it has no "?".
  (define (request-query r)
    (let* ((t (request-target r)) (bv (span-bytevector t)) (end (span-end t))
           (q (first-question bv (span-start t) end)))
      (and (fx<? q end) (latin-1 bv (fx+ q 1) end))))

  ;; request-header : Request String -> (U String #f)
  ;; The value of the first field named `name`, without regard to ASCII case
  ;; (RFC 9110 §5.1), or #f when there is none.
  (define (request-header r name)
    (let ((value (headers-ref (request-headers r) (string->utf8 name))))
      (and value (field-value value))))

  ;; request-header-values : Request String -> (Listof String)
  ;; The value of every field named `name`, in the order they came, each as
  ;; request-header reads the first: without regard to ASCII case, and
  ;; without the OWS around it; '() when there is none.  A list may run
  ;; over several field lines (RFC 9110 §5.3).
  (define (request-header-values r name)
    (map field-value (headers-ref-all (request-headers r) (string->utf8 name))))

  ;; request-header-list : Request -> (Listof (Pair String String))
  ;; Every field line, in the order they came: its name as sent, in its own
  ;; case, and its value as request-header reads it.  A name on several
  ;; lines comes as several pairs.
  (define (request-header-list r)
    (map (lambda (field)
           (let ((name (car field)))
             (cons (latin-1 (span-bytevector name) (span-start name) (span-end name))
                   (field-value (cdr field)))))
         (request-headers r)))

  ;; request-host : Request -> String
  ;; An absolute-form target's authority, whatever the Host field says (RFC
  ;; 9112 §3.2.2); otherwise the Host field's value, "" when it is empty or
  ;; there is none.
  (define (request-host r)
    (let ((t (request-target r)))
      (if (eq? (target-form (request-method r) t) 'absolute)
          (whole (uri-components-authority (absolute-parts t)))
          (let ((value (headers-ref (request-headers r) HOST)))
            (if value (field-value value) (string))))))

  ;; absolute-parts : Span -> UriComponents
  ;; uriparse's parts of an absolute-form target, parsed by a collector made
  ;; for it.  The judge accepted the target, so a parse that fails is an
  ;; assertion violation.
  (define (absolute-parts t)
    (let ((c (make-uri-collector 'uri)))
      (uri-collect-feed! c (span-bytevector t) (span-start t) (span-end t))
      (let ((result (uri-collect-finish! c)))
        (unless (uri-parse-ok? result)
          (assertion-violation 'request-view "not an absolute-form target uriparse parses" t))
        (uri-parse-components result))))

  ;; field-value : Span -> String — a field's value without the OWS around it.
  (define (field-value value)
    (let ((bv (span-bytevector value)))
      (let-values (((start end) (trim-ows bv (span-start value) (span-end value))))
        (latin-1 bv start end))))

  ;; whole : Bytevector -> String
  (define (whole bv) (latin-1 bv 0 (bytevector-length bv)))

  ;; latin-1 : Bytevector Nat Nat -> String
  ;; A fresh string of bv[start, end), a character per byte.
  (define (latin-1 bv start end)
    (let ((s (make-string (fx- end start))))
      (let loop ((i start))
        (if (fx=? i end)
            s
            (begin
              (string-set! s (fx- i start) (integer->char (bytevector-u8-ref bv i)))
              (loop (fx+ i 1))))))))
