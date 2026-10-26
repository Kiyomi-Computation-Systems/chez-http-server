#!r6rs
;;; (http-server view): what a handler sees of a request.
;;;
;;; A handler reads the request through accessors that copy what it asks
;;; for, as strings, a character per byte (Latin-1), so every byte reads back
;;; as it was sent and nothing is percent-decoded.  Each request here is fed
;;; whole to a fake connection running the real core and parser, and read
;;; inside the handler's call, as a handler reads it.
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
;;;   - Otherwise the host is the Host field's value, which may be empty, and
;;;     a request with none reads empty too.  A header's value is its first
;;;     field's, as `headers-ref` reads it.
;;;   - Every field of a name, in the order they came, each as
;;;     `request-header` reads the first; RFC 9110 §5.3 lets a list run over
;;;     several field lines.
;;;   - Every field line of the head, in the order it came, its name as
;;;     sent: names are case-insensitive (RFC 9110 §5.1), so the reader folds
;;;     case, and the order of lines of the same name is significant (§5.3).
;;;   - The connection's addresses are the ones its fake was made with, RFC
;;;     5737's documentation addresses, or #f, each of the four, when it was
;;;     made with none.  They are the connection's, so each request on it
;;;     reads the same.
(import (rnrs) (rnrs mutable-strings) (srfi :64) (testing) (fake-shell)
        (only (http-server request) make-addresses)
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

;; seen-each : (U Addresses #f) Bytevector (Request -> Any) -> (Listof Any)
;; What `look` answers about each request `bv` carries, in order, asked
;; inside each handler's call, on one fake connection made with `addresses`,
;; or with none when it is #f.
(define (seen-each addresses bv look)
  (let* ((answers '())
         (handler (lambda (request)
                    (set! answers (cons (look request) answers))
                    (make-response 200 #f '() #f)))
         (sh (if addresses
                 (make-fake-connection default-limits handler #f 0 #f #f addresses)
                 (make-fake-connection default-limits handler))))
    (fake-shell-feed-input! sh bv (bytevector-length bv))
    (reverse answers)))

;; ends : Request -> (List (U String #f) (U Nat #f) (U String #f) (U Nat #f))
;; The connection's two ends: the remote address and port, then the local.
(define (ends r)
  (list (request-remote-address r) (request-remote-port r)
        (request-local-address r) (request-local-port r)))

;; documented : -> Addresses
;; RFC 5737's documentation addresses, a client's port and a server's, each
;; address a fresh string, as the libuv shell's are.
(define (documented)
  (make-addresses (string-copy "192.0.2.7") 54321 (string-copy "198.51.100.1") 8080))

(define two-gets (b "GET /1 HTTP/1.1\r\nHost: h\r\n\r\nGET /2 HTTP/1.1\r\nHost: h\r\n\r\n"))

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
    ;; judge reads the value without it.
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
    (test-equal "every field of a name, in any case, in the order they came, an empty one among them, each without the whitespace around it; none when there is none; request-header still the first"
                '(("first" "second, third" "") () "first")
                (seen (b "GET / HTTP/1.1\r\nHost: h\r\nX-Twice: first\r\nAccept: */*\r\nx-twice:  second, third \r\nX-TWICE:\r\n\r\n")
                      (lambda (r) (list (request-header-values r "X-Twice")
                                        (request-header-values r "missing")
                                        (request-header r "x-twice")))))
    (test-equal "a value without the whitespace after it"
                '("v  x" "v")
                (seen (b "GET / HTTP/1.1\r\nHost: h\r\nX-Pad:   v  x  \r\nX-Tab:\tv\t\r\n\r\n")
                      (lambda (r) (list (request-header r "x-pad") (request-header r "x-tab")))))
    (test-equal "a value is a character per byte, whatever the byte"
                '(99 97 102 233)
                (seen (bytes (list "GET / HTTP/1.1\r\nHost: h\r\nX-Name: caf" #xE9 "\r\n\r\n"))
                      (lambda (r) (map char->integer (string->list (request-header r "x-name"))))))

    ;; --- every field line ---
    (test-equal "every field line, in the order it came: its name as sent, in its own case, and its value without the whitespace around it; a name on several lines comes as several pairs"
                '(("Host" . "h") ("X-Again" . "first") ("accept" . "*/*")
                  ("x-AGAIN" . "second, third") ("X-Empty" . "") ("X-Again" . "fourth"))
                (seen (b "GET / HTTP/1.1\r\nHost: h\r\nX-Again: first\r\naccept:*/*\r\nx-AGAIN:  second, third \t\r\nX-Empty:\r\nX-Again: fourth\r\n\r\n")
                      request-header-list))
    (test-equal "a head with no field lines lists none"
                '()
                (seen (b "GET / HTTP/1.0\r\n\r\n") request-header-list))
    (test-equal "a listed value is a character per byte, whatever the byte"
                '(("Host" 104) ("X-Name" 99 97 102 233))
                (seen (bytes (list "GET / HTTP/1.1\r\nHost: h\r\nX-Name: caf" #xE9 "\r\n\r\n"))
                      (lambda (r)
                        (map (lambda (field) (cons (car field) (map char->integer (string->list (cdr field)))))
                             (request-header-list r)))))

    ;; --- the connection's addresses ---
    (test-equal "a connection made with no addresses: each request reads #f for all four"
                '((#f #f #f #f) (#f #f #f #f))
                (seen-each #f two-gets ends))
    (test-equal "a connection given addresses: each request reads the remote address and port, then the local, the same on each"
                '(("192.0.2.7" 54321 "198.51.100.1" 8080) ("192.0.2.7" 54321 "198.51.100.1" 8080))
                (seen-each (documented) two-gets ends))
    ;; Each address is a string of the handler's own: one handler's change to
    ;; it is no other's.
    (test-equal "an address is the handler's own string: a handler that changes it changes nothing the next request reads"
                '(("X92.0.2.7" "X98.51.100.1") ("192.0.2.7" "198.51.100.1"))
                (seen-each (documented) two-gets
                           (lambda (r)
                             (let ((remote (request-remote-address r)) (local (request-local-address r)))
                               (let ((seen (list (string-copy remote) (string-copy local))))
                                 (string-set! remote 0 #\X)
                                 (string-set! local 0 #\X)
                                 (if (char=? (string-ref (request-path r) 1) #\1)
                                     (list remote local)
                                     seen))))))))
