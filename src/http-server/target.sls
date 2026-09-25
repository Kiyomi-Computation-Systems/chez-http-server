#!r6rs
;;; (http-server target) — the request-target's form, and uriparse's verdict
;;; on it (pure).  M2.3.
;;;
;;; RFC 9112 §3.2 gives a request-target four forms.  The method and the
;;; first byte say which one a target must be, in this order:
;;;
;;;   CONNECT        authority-form, host:port (§3.2.3)
;;;   "*" alone      asterisk-form, for OPTIONS only (§3.2.4)
;;;   "/" first      origin-form, absolute-path [ "?" query ] (§3.2.1)
;;;   anything else  absolute-form, an absolute-URI (§3.2.2)
;;;
;;; The bytes are judged by uriparse's audited validators, never by a copy of
;;; them here (decision 0001):
;;;
;;;   - origin-form, the form nearly every request carries, is judged by
;;;     `(uri charset)`'s `validate-component` in one pass: as a path up to
;;;     its first "?", which is outside the path's set and so ends the path's
;;;     judgement, then as a query after it.  Both are judged in place, in the
;;;     bytevector the target is held in (a range since uriparse v0.5.0, #21):
;;;     the judge copies nothing, and reads nothing outside the target.  No
;;;     parser runs.  (A uriparse parse would read a leading "//" as an
;;;     authority, as RFC 3986 requires; RFC 9110 §4.1's absolute-path is
;;;     1*( "/" segment ), so "//a" is a path.)
;;;   - absolute-form is parsed by the judge's collector, made on the
;;;     connection's first absolute-form target and reset before each one,
;;;     and judged by `uri-parse-result-validate`.  It must carry no fragment
;;;     (§3.2's forms have none) and no userinfo (RFC 9110 §4.2.4), and an
;;;     http or https one must name a host (RFC 9110 §4.2.1 and §4.2.2).
;;;   - authority-form goes through `uri-parse-authority-form-validate`,
;;;     which parses a copy of the target fresh.  It must name a host: it is
;;;     the tunnel's destination (RFC 9112 §3.2.3).
;;;
;;; The last two run uriparse's own scanner, a byte-machine parser that this
;;; judge owns and that is never the parser calling the core (0002's
;;; amendment of 2026-09-24).  Every verdict is data: uriparse's error code,
;;; or one of this library's four.
;;;
;;; ONE REFUSAL IS REDIRECTED INSTEAD (decision 0009).  Browsers send "[",
;;; "]" and "|" unencoded, because the WHATWG URL standard's query and path
;;; percent-encode sets leave them out, and RFC 9112 §3.2 lets a server answer
;;; an invalid target with a 301 to the target properly encoded.
;;; `target-redirect` gives that target, for bracket params and pipes only.
;;; PURE: imports (rnrs), (uri ...) and (http-server span).
(library (http-server target)
  (export make-target-judge target-judge? target-fault target-redirect)
  (import (rnrs)
          (http-server span)
          (only (uri collect)
                make-uri-collector uri-collector-reset! uri-collect-feed!
                uri-collect-finish! uri-parse-result-validate
                uri-parse-ok? uri-parse-error-code uri-parse-components
                uri-parse-authority-form-validate)
          (only (uri components)
                uri-components-scheme uri-components-authority uri-components-fragment)
          (only (uri charset) validate-component)
          (only (uri host) authority-host-span)
          (only (uri percent) pct-encode))

  ;; make-target-judge : -> TargetJudge
  ;; One connection's judge.  It holds the collector absolute-form targets
  ;; are parsed with, #f until the first one.
  ;; target-judge? : Any -> Boolean
  (define-record-type (target-judge make-target-judge target-judge?)
    (fields (mutable collector judge-collector judge-collector-set!))
    (protocol (lambda (new) (lambda () (new #f)))))

  (define SLASH 47)
  (define ASTERISK 42)
  (define QUESTION 63)
  (define LEFT-BRACKET 91)
  (define RIGHT-BRACKET 93)
  (define PIPE 124)

  ;; target-fault : TargetJudge Symbol Span -> (U #f Symbol)
  ;;   judge method target — the method as llhttp names it ('GET, 'CONNECT)
  ;; #f when the target is the form its method and first byte call for, and
  ;; uriparse finds its bytes valid; otherwise what is wrong with it:
  ;; uriparse's error code, or 'asterisk-not-options, 'fragment, 'userinfo or
  ;; 'no-host.
  (define (target-fault judge method target)
    (let ((bv (span-bytevector target)) (start (span-start target)) (end (span-end target)))
      (cond
       ((eq? method 'CONNECT) (authority-form-fault target))
       ((and (fx=? (fx- end start) 1) (fx=? (bytevector-u8-ref bv start) ASTERISK))
        (if (eq? method 'OPTIONS) #f 'asterisk-not-options))
       ((and (fx<? start end) (fx=? (bytevector-u8-ref bv start) SLASH))
        (origin-form-fault bv start end))
       (else (absolute-form-fault judge bv start end)))))

  ;; origin-form-fault : Bytevector Nat Nat -> (U #f Symbol)
  ;; The path before the first "?", then the query after it.  One pass finds
  ;; both: judged as a path, the target's first fault is at or before its
  ;; first "?", and a fault that is a "?" is where the query begins.
  (define (origin-form-fault bv start end)
    (let-values (((code index) (validate-component 'path bv start end)))
      (if (and code (fx=? (bytevector-u8-ref bv (fx+ start index)) QUESTION))
          (component-fault 'query bv (fx+ start (fx+ index 1)) end)
          code)))

  ;; first-question : Bytevector Nat Nat -> Nat
  ;; The first "?" in [start, end), where an origin-form query begins, or end.
  ;; The redirect's split; the judge finds the same "?" by judging the path.
  (define (first-question bv start end)
    (let loop ((i start))
      (cond ((fx=? i end) end)
            ((fx=? (bytevector-u8-ref bv i) QUESTION) i)
            (else (loop (fx+ i 1))))))

  ;; component-fault : Symbol Bytevector Nat Nat -> (U #f Symbol)
  ;; `(uri charset)`'s verdict on [start, end) as the named component, judged
  ;; in place.
  (define (component-fault component bv start end)
    (let-values (((code index) (validate-component component bv start end)))
      code))

  ;; target-redirect : TargetJudge Symbol Span -> (U #f Bytevector)
  ;;   judge method target
  ;; The target a refused one is redirected to (decision 0009), or #f.
  ;; Narrow on purpose.  The target must be:
  ;;   - a GET or HEAD request's: a client may turn a POST into a GET when it
  ;;     follows a 301 (RFC 9110 §15.4.2);
  ;;   - origin-form, and its path must not begin "//": a Location that did
  ;;     would be a network-path reference, which a client resolves to
  ;;     another host;
  ;;   - one whose only faults are "|" in its path and "[", "]" or "|" in its
  ;;     query.  Those bytes are percent-encoded by uriparse's `pct-encode`,
  ;;     and the encoded target is redirected to only if this judge accepts
  ;;     it and it differs from the target, so a redirect is never refused
  ;;     and never loops.
  ;; The Location is the encoded target itself, an absolute-path reference the
  ;; client resolves against the URI it asked for (RFC 9110 §10.2.2).
  (define (target-redirect judge method target)
    (let ((bv (span-bytevector target)) (start (span-start target)) (end (span-end target)))
      (and (memq method '(GET HEAD))
           (fx<? start end)
           (fx=? (bytevector-u8-ref bv start) SLASH)
           (not (and (fx<? (fx+ start 1) end) (fx=? (bytevector-u8-ref bv (fx+ start 1)) SLASH)))
           (let* ((q (first-question bv start end))
                  (path (encoded bv start q path-keeps?))
                  (location (if (fx<? q end)
                                (join-query path (encoded bv (fx+ q 1) end query-keeps?))
                                path)))
             (and (fx>? (bytevector-length location) (fx- end start))
                  (not (target-fault judge method (make-span location 0 (bytevector-length location))))
                  location)))))

  ;; encoded : Bytevector Nat Nat (Octet -> Boolean) -> Bytevector
  ;; [start, end) percent-encoded, keeping the bytes `keeps?` accepts.
  ;; `pct-encode` takes a whole bytevector, so the range is copied first: the
  ;; redirect is a refusal, off the hot path, and builds a fresh Location
  ;; anyway (accepted without an ask, decision 0008's note of 2026-09-24).
  (define (encoded bv start end keeps?)
    (pct-encode (span->bytevector (make-span bv start end)) keeps?))

  ;; path-keeps? / query-keeps? : Octet -> Boolean
  ;; The bytes the redirect leaves as they are: all but "|" in a path, all but
  ;; "[", "]" and "|" in a query.
  (define (path-keeps? b) (not (fx=? b PIPE)))
  (define (query-keeps? b)
    (not (or (fx=? b PIPE) (fx=? b LEFT-BRACKET) (fx=? b RIGHT-BRACKET))))

  ;; join-query : Bytevector Bytevector -> Bytevector — path "?" query, fresh.
  (define (join-query path query)
    (let* ((np (bytevector-length path)) (nq (bytevector-length query))
           (out (make-bytevector (fx+ np (fx+ 1 nq)))))
      (bytevector-copy! path 0 out 0 np)
      (bytevector-u8-set! out np QUESTION)
      (bytevector-copy! query 0 out (fx+ np 1) nq)
      out))

  ;; absolute-form-fault : TargetJudge Bytevector Nat Nat -> (U #f Symbol)
  (define (absolute-form-fault judge bv start end)
    (let ((c (or (judge-collector judge)
                 (let ((c (make-uri-collector 'uri)))
                   (judge-collector-set! judge c)
                   c))))
      (uri-collector-reset! c)
      (uri-collect-feed! c bv start end)
      (let ((r (uri-parse-result-validate (uri-collect-finish! c))))
        (if (uri-parse-ok? r)
            (let* ((parts (uri-parse-components r))
                   (authority (uri-components-authority parts)))
              (cond ((uri-components-fragment parts) 'fragment)
                    ((userinfo? authority) 'userinfo)
                    ((and (http-scheme? (uri-components-scheme parts)) (not (host? authority)))
                     'no-host)
                    (else #f)))
            (uri-parse-error-code r)))))

  ;; userinfo? : (U #f Bytevector) -> Boolean
  ;; A validated authority carries userinfo exactly when its host begins
  ;; after an "@", by `(uri host)`'s own split.
  (define (userinfo? authority)
    (and authority
         (let-values (((host-start host-end) (authority-host-span authority)))
           (fx>? host-start 0))))

  ;; host? : (U #f Bytevector) -> Boolean
  ;; An authority that names a host: present, and its host, by `(uri host)`'s
  ;; own split, not empty.  "http:x" has no authority; "http:///x" and
  ;; "http://:80/x" have an empty host.
  (define (host? authority)
    (and authority
         (let-values (((host-start host-end) (authority-host-span authority)))
           (fx<? host-start host-end))))

  ;; http-scheme? : Bytevector -> Boolean
  ;; "http" or "https", in any case: schemes are case-insensitive (RFC 3986
  ;; §3.1), and uriparse keeps the case it was sent.  A validated absolute-
  ;; form target always has a scheme.
  (define (http-scheme? scheme)
    (or (scheme=? scheme HTTP) (scheme=? scheme HTTPS)))

  (define HTTP (string->utf8 "http"))
  (define HTTPS (string->utf8 "https"))

  ;; scheme=? : Bytevector Bytevector -> Boolean
  ;; `scheme` is `lower`, ignoring the case of its letters.  A scheme holds
  ;; letters, digits, "+", "-" and "."; of those, setting bit 5 changes only
  ;; an upper-case letter, to its lower case.
  (define (scheme=? scheme lower)
    (let ((n (bytevector-length lower)))
      (and (fx=? (bytevector-length scheme) n)
           (let loop ((i 0))
             (or (fx=? i n)
                 (and (fx=? (fxior (bytevector-u8-ref scheme i) #x20) (bytevector-u8-ref lower i))
                      (loop (fx+ i 1))))))))

  ;; authority-form-fault : Span -> (U #f Symbol)
  ;; The strict validator parses a whole bytevector fresh, so the target is
  ;; copied first.  Accepted without an ask: CONNECT is rare, and the fresh
  ;; parse, not the copy, is most of what it costs (design §7.5).  A valid
  ;; target is an authority with no userinfo, so its host is `host?`'s.
  (define (authority-form-fault target)
    (let* ((authority (span->bytevector target))
           (r (uri-parse-authority-form-validate authority)))
      (cond ((not (uri-parse-ok? r)) (uri-parse-error-code r))
            ((host? authority) #f)
            (else 'no-host)))))
