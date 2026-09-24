#!r6rs
;;; (http-server decisions) — every status the server originates, in one place
;;; (design §6.5).  Pure tables.
;;;
;;; Two maps, because a status has two kinds of origin:
;;;
;;;   - the core's own reasons: a limit or a deadline it enforces (policy), or
;;;     a handler that raised (application).  The reason is the one the
;;;     connection closes with after the response (`close-after`).
;;;   - the parser's error codes.  chez-httparse returns an error as data, and
;;;     lifting its codes into statuses is ours (design §6.2).
;;;
;;; A limit the core trips inside a parser callback makes the parser fail with
;;; the core's own code, and its status comes from the first map, never from
;;; the second (design §6.3): the parser was told to stop, not asked what went
;;; wrong.  Every originated status closes the connection (design §6.5).
;;;
;;; Keep-alive and needs-eof are not here: `should-keep-alive?` and
;;; `message-needs-eof?` come from (httparse decisions), which mirrors llhttp.
;;; PURE: imports only (rnrs).
(library (http-server decisions)
  (export reason-status parser-error-status)
  (import (rnrs))

  ;; reason-status : Symbol -> Nat
  ;; The status of a response the core originates, by the reason the
  ;; connection closes after it.  A reason with no originated response (eof,
  ;; idle-timeout, not-keep-alive, ...) is an assertion violation.
  (define (reason-status reason)
    (case reason
      ((parser-error) 400)                   ; the parser's default (design §6.3)
      ((header-timeout) 408)
      ((target-too-large) 414)
      ((headers-too-large too-many-headers
        header-field-too-large header-value-too-large) 431)
      ((handler-failed) 500)
      (else (assertion-violation 'reason-status
              "not a reason the core originates a response for" reason))))

  ;; The codes chez-httparse's error channel carries: one per llhttp error
  ;; number (its decision 0013), less paused-upgrade, which arrives as a pause
  ;; reason instead, plus unexpected-message-type, which has no llhttp number.
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
  ;; The h2c preface arrives on this channel as `paused-h2-upgrade` and is a
  ;; 505 (decision 0006 item 2).  Every other code is a 400.  A code outside
  ;; the parser's vocabulary is an assertion violation.
  (define (parser-error-status code node-name)
    (unless (memq code parser-error-codes)
      (assertion-violation 'parser-error-status "not a chez-httparse error code" code))
    (case code
      ((invalid-transfer-encoding) (if (eq? node-name 'e-request-invalid-te) 501 400))
      ((paused-h2-upgrade) 505)
      (else 400))))
