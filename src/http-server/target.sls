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
;;;   - origin-form, the form nearly every request carries, is split at its
;;;     first "?", and the path and the query are judged by `(uri charset)`'s
;;;     `validate-component`.  No parser runs.  (A uriparse parse would read a
;;;     leading "//" as an authority, as RFC 3986 requires; RFC 9110 §4.1's
;;;     absolute-path is 1*( "/" segment ), so "//a" is a path.)
;;;     `validate-component` judges a whole bytevector, so the two parts are
;;;     copied first, about one byte per target byte.  That workaround is
;;;     carried until it takes a range (uriparse #21, filed 2026-09-24).
;;;   - absolute-form is parsed by the judge's collector, made on the
;;;     connection's first absolute-form target and reset before each one,
;;;     and judged by `uri-parse-result-validate`.  It must carry no fragment
;;;     (§3.2's forms have none) and no userinfo (RFC 9110 §4.2.4).
;;;   - authority-form goes through `uri-parse-authority-form-validate`,
;;;     which parses fresh.
;;;
;;; The last two run uriparse's own scanner, a byte-machine parser that this
;;; judge owns and that is never the parser calling the core (0002's
;;; amendment of 2026-09-24).  Every verdict is data: uriparse's error code,
;;; or one of this library's three.  PURE: imports (rnrs), (uri ...) and
;;; (http-server span).
(library (http-server target)
  (export make-target-judge target-judge? target-fault)
  (import (rnrs)
          (http-server span)
          (only (uri collect)
                make-uri-collector uri-collector-reset! uri-collect-feed!
                uri-collect-finish! uri-parse-result-validate
                uri-parse-ok? uri-parse-error-code uri-parse-components
                uri-parse-authority-form-validate)
          (only (uri components) uri-components-authority uri-components-fragment)
          (only (uri charset) validate-component)
          (only (uri host) authority-host-span))

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

  ;; target-fault : TargetJudge Symbol Span -> (U #f Symbol)
  ;;   judge method target — the method as llhttp names it ('GET, 'CONNECT)
  ;; #f when the target is the form its method and first byte call for, and
  ;; uriparse finds its bytes valid; otherwise what is wrong with it:
  ;; uriparse's error code, or 'asterisk-not-options, 'fragment or 'userinfo.
  (define (target-fault judge method target)
    (let ((bv (span-bytevector target)) (start (span-start target)) (end (span-end target)))
      (cond
       ((eq? method 'CONNECT) (authority-form-fault bv start end))
       ((and (fx=? (fx- end start) 1) (fx=? (bytevector-u8-ref bv start) ASTERISK))
        (if (eq? method 'OPTIONS) #f 'asterisk-not-options))
       ((and (fx<? start end) (fx=? (bytevector-u8-ref bv start) SLASH))
        (origin-form-fault bv start end))
       (else (absolute-form-fault judge bv start end)))))

  ;; origin-form-fault : Bytevector Nat Nat -> (U #f Symbol)
  ;; The path before the first "?", then the query after it.
  (define (origin-form-fault bv start end)
    (let ((q (first-question bv start end)))
      (or (component-fault 'path bv start q)
          (and (fx<? q end) (component-fault 'query bv (fx+ q 1) end)))))

  ;; first-question : Bytevector Nat Nat -> Nat
  ;; The first "?" in [start, end), where an origin-form query begins, or end.
  (define (first-question bv start end)
    (let loop ((i start))
      (cond ((fx=? i end) end)
            ((fx=? (bytevector-u8-ref bv i) QUESTION) i)
            (else (loop (fx+ i 1))))))

  ;; range-copy : Bytevector Nat Nat -> Bytevector — [start, end), fresh.
  (define (range-copy bv start end)
    (let ((part (make-bytevector (fx- end start))))
      (bytevector-copy! bv start part 0 (fx- end start))
      part))

  ;; component-fault : Symbol Bytevector Nat Nat -> (U #f Symbol)
  ;; `(uri charset)`'s verdict on [start, end) as the named component.  The
  ;; range is copied because the validator judges a whole bytevector
  ;; (uriparse #21).
  (define (component-fault component bv start end)
    (let-values (((code index) (validate-component component (range-copy bv start end))))
      code))

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
            (let ((parts (uri-parse-components r)))
              (cond ((uri-components-fragment parts) 'fragment)
                    ((userinfo? (uri-components-authority parts)) 'userinfo)
                    (else #f)))
            (uri-parse-error-code r)))))

  ;; userinfo? : (U #f Bytevector) -> Boolean
  ;; A validated authority carries userinfo exactly when its host begins
  ;; after an "@", by `(uri host)`'s own split.
  (define (userinfo? authority)
    (and authority
         (let-values (((host-start host-end) (authority-host-span authority)))
           (fx>? host-start 0))))

  ;; authority-form-fault : Bytevector Nat Nat -> (U #f Symbol)
  ;; The strict validator takes a whole bytevector; CONNECT is rare, so the
  ;; target is copied and parsed fresh (design §7.5).
  (define (authority-form-fault bv start end)
    (let ((target (make-bytevector (fx- end start))))
      (bytevector-copy! bv start target 0 (fx- end start))
      (let ((r (uri-parse-authority-form-validate target)))
        (if (uri-parse-ok? r) #f (uri-parse-error-code r))))))
