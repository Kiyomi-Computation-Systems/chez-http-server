#!r6rs
;;; A static file server, like Python's `python3 -m http.server`: it serves
;;; the files under a directory, lists a directory that has no index.html,
;;; and names each file's type from its extension.
;;;
;;;   make run PROGRAM=examples/file-server.sps ARGS="8000 --directory docs"
;;;   chez --program examples/file-server.sps [PORT] [--bind ADDRESS] [--directory DIR]
;;;
;;; PORT is CHEZ_HTTP_PORT, else 8000, as Python's is.  ADDRESS is
;;; CHEZ_HTTP_HOST, else 127.0.0.1: Python's listens on every address, so
;;; pass `--bind 0.0.0.0` for that.  DIR is the current directory unless
;;; given.  Every other setting is the server's own (docs/configuration.md).
;;;
;;; Like Python's, it is for local use: it serves whatever the directory
;;; holds, symbolic links included, to anyone who can reach it.  A request
;;; never leaves the directory: `.` and `..` segments are dropped, as Python
;;; drops them.
(import (rnrs) (http-server)
        (only (chezscheme) getenv directory-list file-directory? file-regular? port-length))

;; whole-limit : Nat — a file up to this long is read whole and sent with
;; its Content-Length; a longer one is streamed, a piece at a time.
(define whole-limit (* 1024 1024))

;; latin-1 : Transcoder — a request's strings hold one byte per character.
(define latin-1 (make-transcoder (latin-1-codec)))

;; ---------------------------------------------------------------------------
;; The command line

;; settings : (Listof String) -> (values (U String #f) (U String #f) String)
;; The port, the address and the directory the arguments name.
(define (settings args)
  (let loop ((args args) (port #f) (bind #f) (dir "."))
    (cond ((null? args) (values port bind dir))
          ((and (member (car args) '("--bind" "-b")) (pair? (cdr args)))
           (loop (cddr args) port (cadr args) dir))
          ((and (member (car args) '("--directory" "-d")) (pair? (cdr args)))
           (loop (cddr args) port bind (cadr args)))
          (else (loop (cdr args) (car args) bind dir)))))

;; ---------------------------------------------------------------------------
;; Paths

;; decoded-segments : String -> (U (Listof String) #f)
;; The request path's segments, percent-decoded as UTF-8, with the empty,
;; `.` and `..` ones dropped; #f if one holds a NUL or a backslash, which no
;; file name here may.
(define (decoded-segments path)
  (let ((segments (split (utf8->string (percent-decode path)) #\/)))
    (and (for-all (lambda (s) (not (or (string-has? s #\nul) (string-has? s #\\)))) segments)
         (filter (lambda (s) (not (member s '("" "." "..")))) segments))))

;; percent-decode : String -> Bytevector — %XX as its byte, any other
;; character as the byte it stands for.
(define (percent-decode s)
  (let-values (((out done) (open-bytevector-output-port)))
    (let loop ((i 0))
      (cond ((= i (string-length s)) (done))
            ((and (char=? (string-ref s i) #\%) (<= (+ i 3) (string-length s))
                  (string->number (substring s (+ i 1) (+ i 3)) 16))
             => (lambda (byte) (put-u8 out byte) (loop (+ i 3))))
            (else (put-u8 out (char->integer (string-ref s i))) (loop (+ i 1)))))))

;; percent-encode : String -> String — the name's UTF-8 bytes, with all but
;; letters, digits and `-._~` written %XX, for a link.
(define (percent-encode name)
  (apply string-append
         (map (lambda (byte)
                (let ((c (integer->char byte)))
                  (if (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
                          (memv c '(#\- #\. #\_ #\~)))
                      (string c)
                      (string-append "%" (if (< byte 16) "0" "")
                                     (string-upcase (number->string byte 16))))))
              (bytevector->u8-list (string->utf8 name)))))

;; split : String Char -> (Listof String)
(define (split s c)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) c) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

;; string-has? : String Char -> Boolean
(define (string-has? s c) (and (memv c (string->list s)) #t))

;; ends-with-slash? : String -> Boolean
(define (ends-with-slash? s)
  (and (> (string-length s) 0) (char=? (string-ref s (- (string-length s) 1)) #\/)))

;; ---------------------------------------------------------------------------
;; Types

;; content-types : (Listof (Pair String String)) — by extension, lower case.
(define content-types
  '(("html" . "text/html") ("htm" . "text/html") ("css" . "text/css")
    ("js" . "text/javascript") ("mjs" . "text/javascript") ("json" . "application/json")
    ("txt" . "text/plain") ("md" . "text/markdown") ("org" . "text/plain")
    ("scm" . "text/plain") ("ss" . "text/plain") ("sls" . "text/plain") ("sps" . "text/plain")
    ("csv" . "text/csv") ("xml" . "application/xml") ("svg" . "image/svg+xml")
    ("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp") ("ico" . "image/vnd.microsoft.icon")
    ("pdf" . "application/pdf") ("wasm" . "application/wasm") ("zip" . "application/zip")
    ("gz" . "application/gzip") ("mp3" . "audio/mpeg") ("mp4" . "video/mp4")
    ("webm" . "video/webm") ("woff" . "font/woff") ("woff2" . "font/woff2")))

;; content-type : String -> String — the type a file's extension names, or
;; application/octet-stream.
(define (content-type path)
  (let loop ((i (string-length path)))
    (cond ((= i 0) "application/octet-stream")
          ((char=? (string-ref path (- i 1)) #\/) "application/octet-stream")
          ((char=? (string-ref path (- i 1)) #\.)
           (let ((hit (assoc (string-downcase (substring path i (string-length path))) content-types)))
             (if hit (cdr hit) "application/octet-stream")))
          (else (loop (- i 1))))))

;; ---------------------------------------------------------------------------
;; Answers

;; header : String String -> (Pair Bytevector Bytevector)
(define (header name value)
  (cons (string->utf8 name) (string->bytevector value latin-1)))

;; answer : Request Nat Headers Body -> Response — the response, and its
;; line in the log: the method, the path and the status.
(define (answer request status headers body)
  (put-string (current-output-port)
              (string-append "file-server " (symbol->string (request-method request)) " "
                             (request-path request) " " (number->string status) "\n"))
  (flush-output-port (current-output-port))
  (make-response status #f headers body))

;; text : Request Nat String -> Response
(define (text request status s)
  (answer request status (list (header "Content-Type" "text/plain; charset=utf-8")) (string->utf8 s)))

(define (not-found request) (text request 404 "File not found\n"))

;; redirect : Request -> Response — 301 to the path with a slash, its query kept.
(define (redirect request)
  (let ((query (request-query request)))
    (answer request 301
            (list (header "Location" (string-append (request-path request) "/"
                                                    (if query (string-append "?" query) ""))))
            #f)))

;; serve-file : Request String -> Response
;; The file's bytes, whole up to whole-limit, else streamed.  The stream's
;; port opens on the producer's first call, so a HEAD, whose producer is
;; never called, opens none.
(define (serve-file request path)
  (let* ((port (open-file-input-port path))
         (size (port-length port))
         (type (list (header "Content-Type" (content-type path)))))
    (if (<= size whole-limit)
        (let ((bytes (if (= size 0) (make-bytevector 0) (get-bytevector-n port size))))
          (close-port port)
          (answer request 200 type (if (eof-object? bytes) (make-bytevector 0) bytes)))
        (begin
          (close-port port)
          (answer request 200 type (file-producer path))))))

;; file-producer : String -> (-> (U Bytevector Eof)) — the file, 64 KiB a piece.
(define (file-producer path)
  (let ((port #f))
    (lambda ()
      (unless port (set! port (open-file-input-port path)))
      (let ((piece (get-bytevector-n port 65536)))
        (when (eof-object? piece) (close-port port))
        piece))))

;; serve-listing : Request String (Listof String) -> Response
;; The directory's entries, sorted by name in any case, each a link; a
;; directory's with its slash.
(define (serve-listing request dir segments)
  (let* ((title (html-escape (string-append "/" (join segments "/") (if (null? segments) "" "/"))))
         (names (list-sort (lambda (a b) (string-ci<? a b)) (directory-list dir)))
         (items (map (lambda (name)
                       (let ((slash (if (file-directory? (string-append dir "/" name)) "/" "")))
                         (string-append "<li><a href=\"" (percent-encode name) slash "\">"
                                        (html-escape name) slash "</a></li>\n")))
                     names)))
    (answer request 200 (list (header "Content-Type" "text/html; charset=utf-8"))
            (string->utf8
             (string-append "<!DOCTYPE HTML>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
                            "<title>Directory listing for " title "</title>\n</head>\n<body>\n"
                            "<h1>Directory listing for " title "</h1>\n<hr>\n<ul>\n"
                            (apply string-append items)
                            "</ul>\n<hr>\n</body>\n</html>\n")))))

;; html-escape : String -> String
(define (html-escape s)
  (apply string-append
         (map (lambda (c)
                (case c
                  ((#\&) "&amp;") ((#\<) "&lt;") ((#\>) "&gt;") ((#\") "&quot;") ((#\') "&#x27;")
                  (else (string c))))
              (string->list s))))

;; join : (Listof String) String -> String
(define (join parts sep)
  (if (null? parts) ""
      (fold-left (lambda (acc p) (string-append acc sep p)) (car parts) (cdr parts))))

;; serve-path : String Request -> Response — what `root` holds at the request's path.
(define (serve-path root request)
  (let ((segments (decoded-segments (request-path request))))
    (if (not segments)
        (not-found request)
        (let ((path (fold-left (lambda (acc s) (string-append acc "/" s)) root segments))
              (slash? (ends-with-slash? (request-path request))))
          (cond ((file-directory? path)
                 (cond ((not slash?) (redirect request))
                       ((find (lambda (index) (file-regular? (string-append path "/" index)))
                              '("index.html" "index.htm"))
                        => (lambda (index) (serve-file request (string-append path "/" index))))
                       (else (serve-listing request path segments))))
                ((and (file-regular? path) (not slash?)) (serve-file request path))
                (else (not-found request)))))))

;; ---------------------------------------------------------------------------
;; The server

(let-values (((port bind dir) (settings (cdr (command-line)))))
  (serve
   (lambda (request)
     (if (memq (request-method request) '(GET HEAD))
         ;; A file or directory it cannot read is not found, as Python's says.
         (guard (e ((i/o-error? e) (not-found request)))
           (serve-path dir request))
         (text request 501 (string-append "Unsupported method ("
                                          (symbol->string (request-method request)) ")\n"))))
   (lambda (name)
     (cond ((string=? name "CHEZ_HTTP_PORT") (or port (getenv name) "8000"))
           ((string=? name "CHEZ_HTTP_HOST") (or bind (getenv name) "127.0.0.1"))
           (else (getenv name))))))
