#!r6rs
;;; The libraries a handler can reach export no chez-libuv name.
;;;
;;; The shell owns every libuv handle and verb.  A handler that could close a connection's handle would leave the shell's
;;; own close callback never run (chez-libuv keeps the first close's callback
;;; alone), and one that could write to it would put bytes on the wire the
;;; core never counted.  So no library outside src/http-server/private/ may
;;; export a `uv-` name.  Each is loaded, and its exports are read by Chez's
;;; own `library-exports`, not from its text.
;;;
;;; Oracle: the file tree, which names the libraries a handler can reach.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) library-exports directory-list environment))

;; reachable : -> (Listof (Listof Symbol)) — the library names a handler can
;; import: (http-server X) for each src/http-server/X.sls, and the facade,
;; (http-server), once src/http-server.sls exists.  Read inside the suite, so
;; a tree it cannot read is the harness's status, not a crash.
(define (reachable)
  (let ((own (map (lambda (file)
                    (list 'http-server
                          (string->symbol (substring file 0 (- (string-length file) 4)))))
                  (filter (lambda (file)
                            (let ((n (string-length file)))
                              (and (> n 4) (string=? (substring file (- n 4) n) ".sls"))))
                          (directory-list "src/http-server")))))
    (if (file-exists? "src/http-server.sls") (cons '(http-server) own) own)))

;; uv-name? : Symbol -> Boolean
(define (uv-name? s)
  (let ((t (symbol->string s)))
    (and (>= (string-length t) 3) (string=? (substring t 0 3) "uv-"))))

(run-suite "exports"
  (lambda ()
    (let ((libraries (reachable)))
      (test-eq "the request library is among those a handler can reach" 'listed
               (if (member '(http-server request) libraries) 'listed libraries))
      (test-equal "none of them exports a uv- name" '()
                  (fold-left (lambda (acc lib)
                               (environment lib)
                               (append acc (map (lambda (s) (cons lib s))
                                                (filter uv-name? (library-exports lib)))))
                             '() libraries)))))
