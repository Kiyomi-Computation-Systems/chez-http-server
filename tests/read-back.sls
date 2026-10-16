#!r6rs
;;; (read-back) — what a write looks like read back by (response-reader), for
;;; a row's expected value: the suites that drive the core and read its
;;; writes back share it (test-connection-response.sps and
;;; test-connection-originated.sps).  It also holds what the originated and
;;; linger suites share besides: a client's two moves on a fake connection,
;;; the actions from the core's own response on, and `shown`, how those suites
;;; and the deadlines suite state an action.
;;;
;;; A field is a (name . value) pair of strings, as read-response returns it.
;;; The Date is the fake shell's: its clock starts at the epoch.
(library (read-back)
  (export message epoch content-length close keep-alive
          send! client-close! from-response shown)
  (import (rnrs)
          (only (fake-shell) written-status fake-shell-feed-input! fake-shell-reading?
                fake-shell-deliver!))

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
  (define keep-alive '("Connection" . "keep-alive"))

  ;; send! : FakeShell String -> Nat
  ;; The client sends `text` in one delivery, delivered only while the
  ;; connection reads, as libuv delivers it, with every later turn around it
  ;; (fake-shell-feed-input!).  Returns how many bytes were delivered.
  (define (send! sh text)
    (let ((bv (string->utf8 text))) (fake-shell-feed-input! sh bv (bytevector-length bv))))

  ;; client-close! : FakeShell -> Any
  ;; The client closes: its eof, delivered only while the connection reads.
  (define (client-close! sh)
    (when (fake-shell-reading? sh) (fake-shell-deliver! sh '(eof))))

  ;; from-response : (Listof Action) -> (Listof Datum)
  ;; The actions from the core's own response on: from its write, or from the
  ;; log before it naming a fault.  A write shows as its status.
  (define (from-response actions)
    (cond ((null? actions) '())
          ((memq (caar actions) '(log write)) (map shown actions))
          (else (from-response (cdr actions)))))

  ;; shown : Action -> Datum
  ;; An action as the suites state it: a write as its status, any other as it
  ;; is.
  (define (shown a) (if (eq? (car a) 'write) (list 'write (written-status a)) a)))
