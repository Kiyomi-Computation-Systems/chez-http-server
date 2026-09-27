#!r6rs
;;; (http-server view): what a handler sees of a request.  M4.5.
;;;
;;; A handler reads the request through accessors that copy what it asks
;;; for, as strings, a character per byte (decision 0012; its measurement
;;; made its strings that way).  Each request here is fed whole to a fake
;;; connection running the real core and parser, and read inside the
;;; handler's call, as a handler reads it.
;;;
;;; Oracles:
;;;   - RFC 9112 §3.2's four forms of request-target.  origin-form is
;;;     absolute-path [ "?" query ] (§3.2.1): the query is what follows the
;;;     first "?", and none when there is no "?".  An absolute-form target's
;;;     host is its authority: a server "MUST ignore the received Host
;;;     header field (if any) and instead use the host information of the
;;;     request-target" (§3.2.2).  authority-form (§3.2.3) and asterisk-form
;;;     (§3.2.4) carry no path of their own.
;;;   - RFC 9110 §4.2.3: an empty path is equivalent to "/", "so the normal
;;;     form is to provide a path of "/" instead".
;;;   - RFC 9110 §5.1: field names are case-insensitive.  RFC 9112 §5: the
;;;     whitespace before and after a field value is not part of it.
;;;   - Decision 0012: otherwise the host is the Host field's value, which
;;;     may be empty, and a request with none reads empty too.  A header's
;;;     value is its first field's, as `headers-ref` reads it in the
;;;     decision's measurement.
(import (rnrs) (srfi :64) (testing) (fake-shell)
        (http-server limits) (http-server response) (http-server view))

(define (b s) (string->utf8 s))

;; bytes : (Listof (U String Nat)) -> Bytevector
;; The text's bytes, and each number as the byte it is.
(define (bytes parts)
  (u8-list->bytevector
   (apply append (map (lambda (p) (if (string? p) (bytevector->u8-list (b p)) (list p))) parts))))

;; seen : Bytevector (Request -> Any) -> Any
;; What `look` answers about the one request `bv` carries, asked inside the
;; handler's call; 'no-handler-call if the core called no handler.
(define (seen bv look)
  (let* ((answer '(no-handler-call))
         (sh (make-fake-connection default-limits
                                   (lambda (request)
                                     (set! answer (list (look request)))
                                     (make-response 200 #f '() #f)))))
    (fake-shell-feed-input! sh bv (bytevector-length bv))
    (car answer)))

;; path+query : Request -> (List String (U String #f))
(define (path+query r) (list (request-path r) (request-query r)))

(run-suite "view"
  (lambda ()
    ;; --- origin-form: the target up to its first "?", then the rest ---
    (test-equal "origin-form: the path up to the first ?, as sent, and the query after it"
                '("/a%20b/c" "x=1&y=?z")
                (seen (b "GET /a%20b/c?x=1&y=?z HTTP/1.1\r\nHost: h\r\n\r\n") path+query))
    (test-equal "origin-form with no ?: no query; ending in ?: an empty one"
                '(("/a" #f) ("/a" ""))
                (list (seen (b "GET /a HTTP/1.1\r\nHost: h\r\n\r\n") path+query)
                      (seen (b "GET /a? HTTP/1.1\r\nHost: h\r\n\r\n") path+query)))

    ;; --- absolute-form: the URI's own path, query and authority ---
    (test-equal "absolute-form: the path and the query are the URI's"
                '("/p/q" "k=v")
                (seen (b "GET http://target.example:81/p/q?k=v HTTP/1.1\r\nHost: other.example\r\n\r\n")
                      path+query))
    (test-equal "absolute-form: the host is the target's authority, whatever Host says"
                "target.example:81"
                (seen (b "GET http://target.example:81/p/q?k=v HTTP/1.1\r\nHost: other.example\r\n\r\n")
                      request-host))
    (test-equal "absolute-form with an empty path: the path reads /"
                '(("/" #f) ("/" "x"))
                (list (seen (b "GET http://target.example HTTP/1.1\r\nHost: target.example\r\n\r\n")
                            path+query)
                      (seen (b "GET http://target.example?x HTTP/1.1\r\nHost: target.example\r\n\r\n")
                            path+query)))

    ;; --- the two forms with no path of their own ---
    (test-equal "asterisk-form: the path is *, with no query, and the host is Host's"
                '("*" #f "h")
                (seen (b "OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n")
                      (lambda (r) (list (request-path r) (request-query r) (request-host r)))))
    (test-equal "authority-form: no path, no query, and the host is Host's"
                '("" #f "proxy.example")
                (seen (b "CONNECT tunnel.example:443 HTTP/1.1\r\nHost: proxy.example\r\n\r\n")
                      (lambda (r) (list (request-path r) (request-query r) (request-host r)))))

    ;; --- the host of an origin-form request ---
    (test-equal "origin-form: the host is the Host field's value"
                "example.com:8080"
                (seen (b "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n") request-host))
    (test-equal "an empty Host reads empty, and so does a request with none"
                '("" "")
                (list (seen (b "GET / HTTP/1.1\r\nHost:\r\n\r\n") request-host)
                      (seen (b "GET / HTTP/1.0\r\n\r\n") request-host)))
    ;; llhttp ends the value's span after the whitespace, and the core's Host
    ;; judge reads the value without it (#54).
    (test-equal "the host is the Host field's value without the whitespace after it"
                "h"
                (seen (b "GET / HTTP/1.1\r\nHost: h \t\r\n\r\n") request-host))

    ;; --- a header's value, by name ---
    (test-equal "a header by name, in any case: the first field's value, or none"
                '("first" "*/*" #f)
                (seen (b "GET / HTTP/1.1\r\nHost: h\r\nX-Twice: first\r\nAccept: */*\r\nx-twice: second\r\n\r\n")
                      (lambda (r) (list (request-header r "X-TWICE")
                                        (request-header r "accept")
                                        (request-header r "missing")))))
    (test-equal "a value without the whitespace after it"
                '("v  x" "v")
                (seen (b "GET / HTTP/1.1\r\nHost: h\r\nX-Pad:   v  x  \r\nX-Tab:\tv\t\r\n\r\n")
                      (lambda (r) (list (request-header r "x-pad") (request-header r "x-tab")))))
    (test-equal "a value is a character per byte, whatever the byte"
                '(99 97 102 233)
                (seen (bytes (list "GET / HTTP/1.1\r\nHost: h\r\nX-Name: caf" #xE9 "\r\n\r\n"))
                      (lambda (r) (map char->integer (string->list (request-header r "x-name"))))))))
