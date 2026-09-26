#!r6rs
;;; (read-back) — what a write looks like read back by (response-reader), for
;;; a row's expected value: the suites that drive the core and read its
;;; writes back share it (test-connection-response.sps, M3.2, and
;;; test-connection-originated.sps, M3.4).
;;;
;;; A field is a (name . value) pair of strings, as read-response returns it.
;;; The Date is the fake shell's: its clock starts at the epoch.
(library (read-back)
  (export message epoch content-length close keep-alive)
  (import (rnrs))

  ;; message : Nat String (Listof (Pair String String)) String -> Datum
  ;; read-response's answer for a write holding one whole message, which
  ;; ended at the write's last byte: its status, reason, fields and body.
  (define (message status reason fields body) (list status reason fields body 'complete))

  ;; epoch : (Pair String String) — the Date at the fake clock's start.
  (define epoch '("Date" . "Thu, 01 Jan 1970 00:00:00 GMT"))

  ;; content-length : String -> (Pair String String)
  (define (content-length n) (cons "Content-Length" n))

  ;; close, keep-alive : (Pair String String) — the Connection fields.
  (define close '("Connection" . "close"))
  (define keep-alive '("Connection" . "keep-alive")))
