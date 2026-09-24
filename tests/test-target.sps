#!r6rs
;;; (http-server target): the request-target's form and its judgement.  M2.3.
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
;;; none) nor userinfo (RFC 9110 §4.2.4).  CONNECT's goes through
;;; `uri-parse-authority-form-validate`.  Decided on the owner's word,
;;; 2026-09-24 (the ledger's M2.3 entry).
;;;
;;; Oracles: RFC 9112 §3.2 and RFC 9110 §4.2.4 for the rules; RFC 3986's
;;; grammar and uriparse's documented error codes for the verdicts; and, where
;;; a code is the scanner's, uriparse's own one-shot `uri-parse-validate` on
;;; the same bytes.
;;;
;;; Every verdict is compared as 'accepted or a code, never as #f: SRFI-64
;;; turns an exception inside a test expression into #f (design §3.4).
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
    (test-equal "a malformed percent-encoding is refused" 'invalid-pct-encoded (fault 'GET "/a%zz"))
    ;; RFC 9112 §3.2's forms carry no fragment, and "#" is in neither the
    ;; path's set nor the query's.
    (test-equal "a fragment is refused, after a path or after a query"
                '(invalid-pchar invalid-query)
                (list (fault 'GET "/a#b") (fault 'GET "/a?b#c")))
    (test-eq "a target is judged by its own bytes, not its delivery's"
             'accepted (judged (make-target-judge) 'GET (inside "|/x?y|" 1 5)))

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
    ;; The method decides first: CONNECT's * is an authority with no port.
    (test-equal "CONNECT * is judged as authority-form" 'port-required (fault 'CONNECT "*"))
    (test-eq "a CONNECT target is judged by its own bytes"
             'accepted (judged (make-target-judge) 'CONNECT (inside "|example.com:443|" 1 16)))))
