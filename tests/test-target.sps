#!r6rs
;;; (http-server target): the request-target's form, its judgement, and the
;;; narrow redirect.
;;;
;;; RFC 9112 §3.2 gives a request-target four forms, and the method and the
;;; first byte say which one a target must be:
;;;   - CONNECT takes authority-form, `host:port` (§3.2.3);
;;;   - `*` alone is asterisk-form, for OPTIONS only (§3.2.4);
;;;   - a target that begins with "/" is origin-form,
;;;     `absolute-path [ "?" query ]` (§3.2.1);
;;;   - anything else is absolute-form, an absolute-URI (§3.2.2).
;;; A target is judged by uriparse's audited validators.  An origin-form
;;; target is split at its first "?" and its parts judged by `(uri charset)`.
;;; An absolute-form target is judged by a reused collector with
;;; `uri-parse-result-validate`, and must carry neither a fragment (§3.2 has
;;; none) nor userinfo (RFC 9110 §4.2.4); an http or https one must name a
;;; host (RFC 9110 §4.2.1 and §4.2.2).  CONNECT's goes through
;;; `uri-parse-authority-form-validate`, and must name a host too.
;;;
;;; A refused target that browsers produce is redirected rather than refused,
;;; and only that one: a GET or HEAD origin-form target whose
;;; only faults are "|" in its path and "[", "]" or "|" in its query.
;;;
;;; Oracles: RFC 9112 §3.2 and RFC 9110 §4.2.4 for the rules; RFC 3986's
;;; grammar and uriparse's documented error codes for the verdicts; and, where
;;; a code is the scanner's, uriparse's own one-shot `uri-parse-validate` on
;;; the same bytes.  For the redirect: RFC 9112 §3.2, which lets a server
;;; answer an invalid target with a 301 to it properly encoded, and RFC 3986
;;; §2.1's encoding, "%" and two uppercase hex digits: "[" %5B, "]" %5D,
;;; "|" %7C.
;;;
;;; Every verdict is compared as 'accepted or a code, never as #f: SRFI-64
;;; turns an exception inside a test expression into #f.
(import (rnrs) (srfi :64) (testing)
        (http-server target) (http-server span)
        (uri collect))

(define (b s) (string->utf8 s))

;; span-of : String -> Span — the whole of a fresh bytevector.
(define (span-of s) (let ((bv (b s))) (make-span bv 0 (bytevector-length bv))))

;; inside : String Nat Nat -> Span — [start, end) of the string's bytes.
(define (inside s start end) (make-span (b s) start end))

;; judged : TargetJudge Symbol Span -> Symbol — 'accepted, or the fault.
(define (judged judge method target) (or (target-fault judge method target) 'accepted))

;; fault : Symbol String -> Symbol — a fresh judge's verdict.
(define (fault method target) (judged (make-target-judge) method (span-of target)))

;; uriparse-code : Symbol String -> Symbol
;; uriparse's own one-shot verdict on the bytes, the oracle for a code the
;; scanner gives.
(define (uriparse-code mode s)
  (let ((r (uri-parse-validate mode (b s))))
    (if (uri-parse-ok? r) 'accepted (uri-parse-error-code r))))

;; redirect-span : Symbol Span -> (U String 'none)
;; redirect : Symbol String -> (U String 'none)
;; Where a fresh judge redirects the target, or 'none.
(define (redirect-span method target)
  (let ((location (target-redirect (make-target-judge) method target)))
    (if location (utf8->string location) 'none)))
(define (redirect method target) (redirect-span method (span-of target)))

(run-suite "target"
  (lambda ()
    ;; --- origin-form: absolute-path [ "?" query ] -----------------------------
    (test-equal "origin-form targets that RFC 9112 allows are accepted"
                '(accepted accepted accepted accepted)
                (map (lambda (t) (fault 'GET t))
                     '("/" "/a/b?c=1&d=%20" "/test.cgi?foo=bar?baz" "/a;p=1/:@!$&'()*+,=")))
    ;; RFC 9110 §4.1: absolute-path = 1*( "/" segment ), so a first segment may
    ;; be empty and "//" is a path.  RFC 3986 would read it as an authority,
    ;; and "b:c" as a bad port.
    (test-eq "a path that begins \"//\" is a path, not an authority"
             'accepted (fault 'GET "//a@b:c/d"))
    ;; The split is at the FIRST "?": the query may hold "?" and the path may not.
    (test-eq "the query begins at the first \"?\"" 'accepted (fault 'GET "/a?b?c"))
    (test-equal "a byte outside pchar in the path is refused" 'invalid-pchar (fault 'GET "/a\"b"))
    (test-equal "a byte outside the query's set is refused" 'invalid-query (fault 'GET "/p?q=a|b"))
    ;; The query is judged from the byte after the "?", its first.
    (test-equal "a query's first byte is judged"
                '(invalid-query invalid-query invalid-pct-encoded invalid-pct-encoded)
                (map (lambda (t) (fault 'GET t)) '("/a?\"b" "/a?|b" "/a?%zz" "/?%")))
    (test-equal "a malformed percent-encoding is refused" 'invalid-pct-encoded (fault 'GET "/a%zz"))
    ;; RFC 9112 §3.2's forms carry no fragment, and "#" is in neither the
    ;; path's set nor the query's.
    (test-equal "a fragment is refused, after a path or after a query"
                '(invalid-pchar invalid-query)
                (list (fault 'GET "/a#b") (fault 'GET "/a?b#c")))
    (test-equal "a target is judged by its own bytes, not its delivery's"
                '(accepted accepted)
                (list (judged (make-target-judge) 'GET (inside "|/x?y|" 1 5))
                      (judged (make-target-judge) 'GET (inside "|/x|" 1 3))))

    ;; --- asterisk-form: OPTIONS only -------------------------------------------
    (test-eq "OPTIONS * is accepted" 'accepted (fault 'OPTIONS "*"))
    (test-equal "* with any other method is refused"
                '(asterisk-not-options asterisk-not-options)
                (list (fault 'GET "*") (fault 'M-SEARCH "*")))
    (test-equal "*x is not asterisk-form: it is judged as absolute-form"
                (uriparse-code 'uri "*x") (fault 'OPTIONS "*x"))

    ;; --- absolute-form: absolute-URI, no fragment, no userinfo --------------------
    (test-equal "absolute-form targets are accepted"
                '(accepted accepted accepted)
                (map (lambda (t) (fault 'GET t))
                     '("http://example.com/p?q=1" "http://example.com" "http://[::1]:80/p")))
    (test-equal "the host grammar judges the authority" 'invalid-port (fault 'GET "http://h:8x/p"))
    (test-equal "userinfo is refused (RFC 9110 §4.2.4)" 'userinfo (fault 'GET "http://u@h/p"))
    (test-equal "a fragment is refused" 'fragment (fault 'GET "http://h/p#f"))
    ;; RFC 9110 §4.2.1 and §4.2.2: an http or https URI is "//" and an
    ;; authority, and a recipient MUST reject one with an empty host.  A
    ;; missing authority is no host either.  The scheme matches in any case.
    (test-equal "an http or https target with no host is refused"
                '(no-host no-host no-host no-host no-host no-host)
                (map (lambda (t) (fault 'GET t))
                     '("http:///x" "http://:80/x" "https://?q" "HTTP:///x" "http:x" "http:/x")))
    ;; The rule is RFC 9110's, for http and https only: another scheme, even
    ;; one that begins "http", keeps uriparse's verdict.  Whether to serve it
    ;; is the server's question, not the judge's.
    (test-equal "a target of another scheme keeps uriparse's verdict"
                '(accepted accepted)
                (map (lambda (t) (fault 'GET t)) '("ftp:///x" "httpx:///x")))
    (test-equal "an empty target is refused as uriparse refuses it"
                (uriparse-code 'uri "") (fault 'GET ""))
    (test-eq "an absolute-form target is judged by its own bytes"
             'accepted (judged (make-target-judge) 'GET (inside "|http://h/p|" 1 11)))
    ;; One judge per connection: its collector is reset before each target, so
    ;; no verdict leaks into the next.
    (let ((j (make-target-judge)))
      (test-equal "one judge, three absolute-form targets in a row"
                  '(invalid-port accepted userinfo)
                  (map (lambda (t) (judged j 'GET (span-of t)))
                       '("http://h:8x/p" "http://h/p" "http://u@h/p"))))

    ;; --- authority-form: CONNECT ---------------------------------------------------
    (test-eq "CONNECT host:port is accepted" 'accepted (fault 'CONNECT "example.com:443"))
    (test-equal "CONNECT without a port is refused" 'port-required (fault 'CONNECT "example.com"))
    (test-equal "CONNECT with userinfo is refused" 'userinfo-forbidden
                (fault 'CONNECT "u@example.com:443"))
    (test-equal "CONNECT with a path is refused" 'not-authority-form (fault 'CONNECT "h:1/x"))
    ;; The target is the tunnel's destination (RFC 9112 §3.2.3), and an empty
    ;; host names none, though RFC 3986's grammar allows it.
    (test-equal "CONNECT with an empty host is refused" 'no-host (fault 'CONNECT ":443"))
    ;; The method decides first: CONNECT's * is an authority with no port.
    (test-equal "CONNECT * is judged as authority-form" 'port-required (fault 'CONNECT "*"))
    (test-eq "a CONNECT target is judged by its own bytes"
             'accepted (judged (make-target-judge) 'CONNECT (inside "|example.com:443|" 1 16)))

    ;; --- the narrow redirect -----------------------------------------
    ;; Browsers send "[", "]" and "|" unencoded (the WHATWG URL standard's query
    ;; and path percent-encode sets leave them out), and RFC 9112 §3.2 lets a
    ;; server answer an invalid target with a 301 to it properly encoded.
    (test-equal "bracket params and pipes are redirected, encoded"
                '("/search?ids%5B%5D=1&ids%5B%5D=2" "/search?user%5Bname%5D=x"
                  "/maps?markers=color:red%7Clabel:S" "/files/a%7Cb.txt")
                (map (lambda (t) (redirect 'GET t))
                     '("/search?ids[]=1&ids[]=2" "/search?user[name]=x"
                       "/maps?markers=color:red|label:S" "/files/a|b.txt")))
    (test-equal "HEAD is redirected as GET is" "/a%7Cb" (redirect 'HEAD "/a|b"))
    ;; RFC 9110 §15.4.2: a client may turn a POST into a GET on a 301.
    (test-equal "no other method is redirected"
                '(none none none) (map (lambda (m) (redirect m "/a|b")) '(POST PUT OPTIONS)))
    (test-eq "brackets in a path are not bracket params" 'none (redirect 'GET "/a[b]"))
    (test-equal "a target with any other fault is not redirected"
                '(none none none none)
                (map (lambda (t) (redirect 'GET t))
                     '("/a|b\"" "/a?b[]=1#f" "/a?q={x}|" "/a%zz|")))
    ;; A Location beginning "//" is a network-path reference: the client would
    ;; resolve it to another host, so the server would be an open redirect.
    (test-eq "a path that begins // is not redirected" 'none (redirect 'GET "//evil.example/a|b"))
    ;; Browsers read "\" in a path as "/", so "/\evil.example" is "//" in
    ;; disguise; "\" is another fault, so it is never redirected.
    (test-eq "a path that begins /\\ is not redirected" 'none (redirect 'GET "/\\evil.example/a|b"))
    (test-eq "an absolute-form target is not redirected" 'none (redirect 'GET "http://h/a|b"))
    (test-eq "a target with nothing to encode is not redirected" 'none (redirect 'GET "/a?b=%7C"))
    (test-equal "a target is encoded from its own bytes, not its delivery's"
                "/x%7C" (redirect-span 'GET (inside "|/x||" 1 4)))
    (let* ((j (make-target-judge))
           (location (target-redirect j 'GET (span-of "/s?a[]=1|2"))))
      (test-eq "the Location is a target the judge accepts" 'accepted
               (if location
                   (judged j 'GET (make-span location 0 (bytevector-length location)))
                   'not-redirected)))))
