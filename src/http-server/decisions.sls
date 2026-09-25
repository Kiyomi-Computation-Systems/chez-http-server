#!r6rs
;;; (http-server decisions) — every status the server originates, in one place
;;; (design §6.5), and the parser results the core must tell apart.  Pure
;;; tables.
;;;
;;; Two maps, because a status has two kinds of origin:
;;;
;;;   - the core's own reasons: a limit, a deadline or a target form it
;;;     enforces (policy), a handler that raised (application), or the
;;;     HTTP/2 preface it has nothing to hand to.  The reason is the one the
;;;     connection closes with after the response (`close-after`).
;;;   - the parser's error codes.  chez-httparse returns an error as data, and
;;;     lifting its codes into statuses is ours (design §6.2).
;;;
;;; A limit tripped or a target refused inside a parser callback makes the
;;; parser fail with the core's own code, and its status comes from the first
;;; map, never from the second (design §6.3): the parser was told to stop, not
;;; asked what went wrong.  Every originated status closes the connection
;;; (design §6.5).
;;;
;;; Two decisions tell a parser result apart before either map is asked
;;; (M2.5): whether it hands the stream off, which the parser reports on two
;;; channels, and whether a request upgrades, which llhttp decides before
;;; on-headers-complete and chez-httparse does not export.
;;;
;;; Keep-alive and needs-eof are not here: `should-keep-alive?` and
;;; `message-needs-eof?` come from (httparse decisions), which mirrors llhttp.
;;; PURE: imports only (rnrs) and (httparse decisions)' flag bits.
(library (http-server decisions)
  (export reason-status parser-error-status
          result-hands-off-stream? request-upgrades?)
  (import (rnrs)
          (only (httparse decisions) F-UPGRADE F-CONNECTION-UPGRADE))

  ;; reason-status : Symbol -> Nat
  ;; The status of a response the core originates, by the reason the
  ;; connection closes after it.  A reason with no originated response (eof,
  ;; idle-timeout, not-keep-alive, upgrade, ...) is an assertion violation,
  ;; and so is parser-error, whose status is the error's (parser-error-status).
  (define (reason-status reason)
    (case reason
      ((target-redirect) 301)                ; bracket params and pipes (0009)
      ((invalid-target) 400)                 ; not a form RFC 9112 §3.2 allows
      ((invalid-host) 400)                   ; RFC 9112 §3.2's Host rules
      ((header-timeout) 408)
      ((target-too-large) 414)
      ((headers-too-large too-many-headers
        header-field-too-large header-value-too-large) 431)
      ((handler-failed) 500)
      ((http2-preface) 505)                  ; nothing to hand HTTP/2 to (0006 item 2)
      (else (assertion-violation 'reason-status
              "not a reason the core originates a response for" reason))))

  ;; The codes chez-httparse's error channel carries: one per llhttp error
  ;; number (its decision 0013), less paused-upgrade, which arrives as a pause
  ;; reason instead, plus unexpected-message-type, which has no llhttp number.
  ;; paused-h2-upgrade is one of them, but it is a hand-off, not an error.
  (define parser-error-codes
    '(strict lf-expected unexpected-content-length closed-connection
      invalid-method invalid-url invalid-constant invalid-version
      invalid-header-token invalid-content-length invalid-chunk-size
      invalid-status invalid-eof-state invalid-transfer-encoding
      paused-h2-upgrade cr-expected unexpected-space unexpected-message-type))

  ;; parser-error-status : Symbol Symbol -> Nat
  ;;   code node-name — parser-error-code and parser-error-node-name
  ;; The status for a parser error (design §6.3).  `invalid-transfer-encoding`
  ;; splits by node, never by reason string: a Transfer-Encoding whose last
  ;; coding is not chunked arrives at `e-request-invalid-te` and is a 501 (RFC
  ;; 9112 §6.1; chez-httparse #36, its docs/api.org), every other one is a 400.
  ;; Every other code is a 400.  The HTTP/2 preface's `paused-h2-upgrade` is a
  ;; hand-off, answered by the core's own reason (see result-hands-off-stream?),
  ;; so it is an assertion violation here, like a code outside the parser's
  ;; vocabulary.
  (define (parser-error-status code node-name)
    (unless (memq code parser-error-codes)
      (assertion-violation 'parser-error-status "not a chez-httparse error code" code))
    (case code
      ((invalid-transfer-encoding) (if (eq? node-name 'e-request-invalid-te) 501 400))
      ((paused-h2-upgrade)
       (assertion-violation 'parser-error-status "a hand-off, not an error" code))
      (else 400)))

  ;; result-hands-off-stream? : Symbol (U #f Symbol) (U #f Symbol) -> Boolean
  ;;   status error-code pause-code — a ParserResult's status, and the codes
  ;;   of its error and its pause, as the shell's parser-result event
  ;;   carries them
  ;; #t when the result hands the stream to another protocol.  The parser
  ;; reports a hand-off on two channels: a CONNECT tunnel, `Connection:
  ;; upgrade` and a 101 pause with the reason `paused-upgrade`, and the HTTP/2
  ;; preface is an error with the code `paused-h2-upgrade`, because llhttp
  ;; implements it that way.  A plain pause carries no reason.  This is the
  ;; check chez-httparse's docs/api.org gives as embedder code ("Upgrades hand
  ;; off on two channels", `result-hands-off-stream?`, over a ParserResult),
  ;; here over the result's parts.  A code counts only on its own channel.
  (define (result-hands-off-stream? status error-code pause-code)
    (or (and (eq? status 'paused) (eq? pause-code 'paused-upgrade))
        (and (eq? status 'error) (eq? error-code 'paused-h2-upgrade))))

  ;; request-upgrades? : Nat Nat -> Boolean
  ;;   method flags — llhttp's method number and flag bits, as read inside
  ;;   on-headers-complete
  ;; #t when the request asks to switch protocols, so the parser will hand
  ;; the stream off after it: llhttp's `llhttp__before_headers_complete` for
  ;; a request (chez-httparse's grammar, `before-headers-complete`), which
  ;; sets `upgrade` for CONNECT (method 5) whatever its headers, and for a
  ;; request carrying both `Upgrade` and `upgrade` among its `Connection`
  ;; options.  chez-httparse exports the flag bits and not this rule, so it
  ;; is transcribed here; test-decisions.sps holds it to llhttp's recorded
  ;; logs.
  (define (request-upgrades? method flags)
    (or (eqv? method 5)
        (let ((both (bitwise-ior F-UPGRADE F-CONNECTION-UPGRADE)))
          (= (bitwise-and flags both) both)))))
