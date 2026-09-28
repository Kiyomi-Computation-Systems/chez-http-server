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
;;; One decision tells a parser result apart before either map is asked
;;; (M2.5): whether it hands the stream off, which the parser reports on two
;;; channels.  Whether a request upgrades is not here: it is the parser's own
;;; answer, its `upgrade` field (chez-httparse v0.4.1, #47), which the core
;;; reads at on-headers-complete.
;;;
;;; The framing decision is here too (M3.2; design §3.1): how a response's
;;; body goes on the wire, for the request it answers, and the Connection
;;; field it carries.  (http-server serializer) writes what they decide.
;;;
;;; Keep-alive and needs-eof are not here either: `should-keep-alive?` and
;;; `message-needs-eof?` come from (httparse decisions), which mirrors llhttp.
;;; PURE: imports only (rnrs).
(library (http-server decisions)
  (export reason-status originated-reasons parser-error-status result-hands-off-stream?
          response-framing response-connection http/1.1?)
  (import (rnrs))

  ;; The core's own reasons and their statuses, by status.
  (define reason-statuses
    '((target-redirect . 301)                ; bracket params and pipes (0009)
      (invalid-target . 400)                 ; not a form RFC 9112 §3.2 allows
      (invalid-host . 400)                   ; RFC 9112 §3.2's Host rules
      (faulty-framing . 400)                 ; Transfer-Encoding below HTTP/1.1 (RFC 9112 §6.1)
      (header-timeout . 408)
      (body-timeout . 408)                   ; a body stalled past its deadline (M5.2)
      (body-too-large . 413)                 ; a body past a cap (0013 item 5)
      (target-too-large . 414)
      (headers-too-large . 431) (too-many-headers . 431)
      (header-field-too-large . 431) (header-value-too-large . 431)
      (handler-failed . 500)
      (invalid-response . 500)               ; one the serializer cannot write (0010 item 2)
      (unsupported-transfer-coding . 501)    ; a coding before a final chunked (RFC 9112 §6.1)
      (http2-preface . 505)))                ; nothing to hand HTTP/2 to (0006 item 2)

  ;; reason-status : Symbol -> Nat
  ;; The status of a response the core originates, by the reason the
  ;; connection closes after it.  A reason with no originated response (eof,
  ;; idle-timeout, not-keep-alive, upgrade, ...) is an assertion violation,
  ;; and so is parser-error, whose status is the error's (parser-error-status).
  (define (reason-status reason)
    (cond ((assq reason reason-statuses) => cdr)
          (else (assertion-violation 'reason-status
                  "not a reason the core originates a response for" reason))))

  ;; originated-reasons : (Listof Symbol)
  ;; Every reason reason-status answers, by status: each one a response the
  ;; core originates, then closes after (M3.4 drives each end to end).
  (define originated-reasons (map car reason-statuses))

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

  ;; parser-error-status : Symbol -> Nat
  ;;   code — parser-error-code
  ;; The status for a parser error (design §6.3): 400, whatever the code.
  ;; `invalid-transfer-encoding` is one, at each of its four nodes (decided on
  ;; the owner's word, 2026-09-26).  No chunked, a coding after chunked and an
  ;; empty value leave the body's length undetermined, which RFC 9112 §6.3
  ;; answers 400; a Content-Length before the Transfer-Encoding is a request
  ;; §6.1 lets a server refuse, then close.  The 501 for a coding the server does
  ;; not implement is the core's own reason, unsupported-transfer-coding.  The
  ;; HTTP/2 preface's `paused-h2-upgrade` is a hand-off, answered by the core's
  ;; own reason (see result-hands-off-stream?), so it is an assertion violation
  ;; here, like a code outside the parser's vocabulary.
  (define (parser-error-status code)
    (unless (memq code parser-error-codes)
      (assertion-violation 'parser-error-status "not a chez-httparse error code" code))
    (when (eq? code 'paused-h2-upgrade)
      (assertion-violation 'parser-error-status "a hand-off, not an error" code))
    400)

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

  ;; response-framing :
  ;;   (U Symbol #f) Nat Nat Nat (U Nat #f 'unknown) -> Symbol
  ;;   method http-major http-minor — the request's: the method as llhttp
  ;;     names it, or #f when the core has read no request to answer (a
  ;;     refusal before the head was complete), and its version
  ;;   status — the response's
  ;;   length — its body's: a count, #f for no body, or 'unknown for a body
  ;;     whose length is not known before it is written (M6's stream)
  ;; How the response's body goes on the wire: one of (http-server
  ;; serializer)'s framing modes.  The rules, first match wins:
  ;;   - a 1xx, a 204, a 304 and a 2xx to CONNECT: no-body.  A client ends
  ;;     each at the blank line, whatever its fields say (RFC 9112 §6.3 rules
  ;;     1 and 2).  A 1xx, a 204 and a 2xx to CONNECT must carry neither
  ;;     Content-Length nor Transfer-Encoding (RFC 9110 §8.6, §9.3.6; RFC 9112
  ;;     §6.1).  A 304 may carry the 200's Content-Length, but only a HEAD's
  ;;     answer announces one (decision 0010).  A body the handler gave one
  ;;     of these is not written.
  ;;   - a HEAD's answer: content-length-only when the handler gave the body
  ;;     a GET would get, no-body when it gave none or its length is unknown.
  ;;     A HEAD's Content-Length must be the GET's (RFC 9110 §8.6), so it is
  ;;     written only when known (decision 0010 item 6).
  ;;   - a known length, a body or none: content-length (RFC 9110 §8.6).
  ;;   - an unknown length: chunked to HTTP/1.1, close-delimited to any other
  ;;     version, which must not be sent Transfer-Encoding (RFC 9112 §6.1).
  ;; A status outside 100–599 (RFC 9110 §15) and a length outside the three
  ;; kinds are assertion violations.
  (define (response-framing method http-major http-minor status length)
    (unless (and (fixnum? status) (fx<=? 100 status 599))
      (assertion-violation 'response-framing "not a status" status))
    (unless (or (not length) (eq? length 'unknown)
                (and (fixnum? length) (fx>=? length 0)))
      (assertion-violation 'response-framing "not a body length" length))
    (cond ((or (fx<=? 100 status 199) (fx=? status 204) (fx=? status 304)
               (and (eq? method 'CONNECT) (fx<=? 200 status 299)))
           'no-body)
          ((eq? method 'HEAD) (if (fixnum? length) 'content-length-only 'no-body))
          ((not (eq? length 'unknown)) 'content-length)
          ((http/1.1? http-major http-minor) 'chunked)
          (else 'close-delimited)))

  ;; response-connection : Boolean Nat Nat -> (U 'close 'keep-alive #f)
  ;;   closes? — the connection closes after this response
  ;;   http-major http-minor — the request's version
  ;; The Connection field the server writes (decision 0010 items 3 and 6):
  ;; `close` on the last response (RFC 9112 §9.6); `keep-alive` on one to any
  ;; version but HTTP/1.1 that keeps the connection, which only a request
  ;; that asked to keep it does (should-keep-alive?), and an HTTP/1.0 client
  ;; persists only when told so (RFC 9112 Appendix C.2.2); and none to
  ;; HTTP/1.1, which persists by default (RFC 9112 §9.3).
  (define (response-connection closes? http-major http-minor)
    (cond (closes? 'close)
          ((http/1.1? http-major http-minor) #f)
          (else 'keep-alive)))

  ;; http/1.1? : Nat Nat -> Boolean
  ;; llhttp's version gate, `major > 0 && minor > 0`, which
  ;; should-keep-alive? applies too.  Of the versions the strict parser
  ;; admits (0.9, 1.0, 1.1 and 2.0; measured 2026-09-25) only 1.1 passes,
  ;; which is RFC 9112 §6.1's "HTTP/1.1 (or later minor revisions)".
  (define (http/1.1? http-major http-minor)
    (and (> http-major 0) (> http-minor 0))))
