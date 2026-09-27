#!r6rs
;;; (http-server host): RFC 9112 §3.2's Host rules, judged over the head's
;;; kept fields.
;;;
;;; "A server MUST respond with a 400 (Bad Request) status code to any
;;; HTTP/1.1 request message that lacks a Host header field and to any request
;;; message that contains more than one Host header field line or a Host header
;;; field with an invalid field value."  A valid value is RFC 9110 §7.2's
;;; `uri-host [ ":" port ]`: an RFC 3986 authority with no userinfo.  Decided
;;; on the owner's word, 2026-09-25 (the ledger's Host entry): the missing-Host
;;; rule sits behind decision 0005's `require-host` switch; an empty value is
;;; valid here and M4's to judge (RFC 9112 §3.3).
;;;
;;; Oracles: RFC 9112 §3.2 for the rules; uriparse's `validate-authority` and
;;; its documented error codes for a value's verdict; RFC 9110 §7.2 for the
;;; userinfo rule; RFC 9112 §5 for the OWS that is not part of a value.  Every
;;; verdict is compared as 'accepted or a code, never as #f: SRFI-64 turns an
;;; exception inside a test expression into #f.
(import (rnrs) (srfi :64) (testing)
        (http-server host) (http-server span))

(define (b s) (string->utf8 s))

;; field : String String -> (Pair Span Span) — a header line's name and value,
;; each a span inside the line "name: value\r\n", as the core keeps them.
(define (field name value)
  (let* ((line (b (string-append name ": " value "\r\nX: @[:]\r\n")))
         (ns 0) (ne (bytevector-length (b name)))
         (vs (+ ne 2)) (ve (+ vs (bytevector-length (b value)))))
    (cons (make-span line ns ne) (make-span line vs ve))))

;; judged : (Listof (Pair String String)) Nat Nat Boolean -> Symbol
;; 'accepted, or the fault, for those fields at that version.
(define (judged fields major minor require?)
  (or (host-fault (map (lambda (f) (field (car f) (cdr f))) fields) major minor require?)
      'accepted))

;; one-host : String -> Symbol — an HTTP/1.1 request with that one Host value.
(define (one-host value) (judged (list (cons "Host" value)) 1 1 #t))

(run-suite "host"
  (lambda ()
    ;; --- one Host, valid ----------------------------------------------------------
    (test-equal "one valid Host passes"
                '(accepted accepted accepted accepted)
                (map one-host '("x" "example.com:8080" "[::1]:80" "192.0.2.1")))
    ;; RFC 9112 §3.2: a client sends an empty Host when the target has no
    ;; authority, and §3.3 leaves the empty authority to the server: M4's.
    (test-eq "an empty Host value passes" 'accepted (one-host ""))
    ;; RFC 9112 §5: the OWS around a field line value is not part of it.
    ;; llhttp leaves out the OWS before a value but keeps the OWS after it, so
    ;; the span the core keeps can end in a space or a tab.
    (test-equal "a Host value is judged without the OWS around it"
                '(accepted accepted accepted accepted)
                (map one-host '("h " "h\t" "example.com:8080 \t " " h")))
    (test-equal "the Host name matches in any case"
                '(accepted duplicate-host)
                (list (judged '(("hOsT" . "x")) 1 1 #t)
                      (judged '(("HOST" . "a") ("host" . "b")) 1 1 #t)))
    (test-eq "a field named like Host is not Host" 'accepted
             (judged '(("X-Host" . "a b") ("Host" . "x")) 1 1 #t))

    ;; --- no Host ------------------------------------------------------------------
    (test-eq "HTTP/1.1 with no Host is refused" 'missing-host
             (judged '(("Accept" . "*/*")) 1 1 #t))
    (test-eq "unless the requirement is off" 'accepted
             (judged '(("Accept" . "*/*")) 1 1 #f))
    (test-equal "HTTP/1.0 and 0.9 with no Host pass"
                '(accepted accepted)
                (list (judged '() 1 0 #t) (judged '() 0 9 #t)))

    ;; --- more than one Host, in any version, the requirement on or off -----------
    (test-equal "more than one Host is refused"
                '(duplicate-host duplicate-host duplicate-host)
                (list (judged '(("Host" . "a") ("Host" . "a")) 1 1 #t)
                      (judged '(("Host" . "a") ("Accept" . "*/*") ("Host" . "b")) 1 0 #t)
                      (judged '(("Host" . "a") ("Host" . "b")) 1 1 #f)))

    ;; --- a value that is not uri-host [ ":" port ] ---------------------------------
    (test-equal "an invalid Host value is refused with uriparse's code"
                '(invalid-reg-name invalid-port invalid-ip-literal invalid-pct-encoded)
                (map one-host '("a b" "h:x" "[::1" "h%zz")))
    (test-eq "a Host with userinfo is refused" 'host-userinfo (one-host "u@h"))
    ;; The value is judged in place: the "@", "[", ":" and "]" after it in its
    ;; line are not read.
    (test-eq "a Host value is judged by its own bytes, not its line's" 'accepted
             (one-host "h"))))
