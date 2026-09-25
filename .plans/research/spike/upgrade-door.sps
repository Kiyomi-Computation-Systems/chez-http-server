#!r6rs
;; M2.5, 2026-09-25: where an upgrade meets the connection core, measured at
;; the pins before the owner chose the door.  The parser facts each option
;; rests on:
;;
;;   (1) Answered `continue` at on-message-complete, the parser runs on to
;;       its own hand-off in the same feed, at every delivery size, with
;;       `next` one past the message: the door M8 would open.
;;   (2) Answered `pause` there, as the core answers every message (decision
;;       0004 item 1), the hand-off comes only when the parse is resumed and
;;       fed again, even an empty range at `next`; a plain message answers
;;       need-input instead.  M2.4's core never did that, and stalled.
;;   (3) llhttp's rule (CONNECT, or both upgrade flags) equals the parser's
;;       own `upgrade` field at on-headers-complete, the one that decides the
;;       hand-off.  (httparse decisions) exports the flag bits, not the rule;
;;       the field is not in chez-httparse's documented list.
;;   (4) The HTTP/2 preface errors at once, `paused-h2-upgrade`, before any
;;       on-headers-complete; `Upgrade: h2c` is an upgrade like any other.
;;
;; Run on the project's library path (the ledger's M2.5 entry gives it).
(import (rnrs) (generated httparse-message) (httparse modes) (byte-machine runtime)
        (httparse decisions))
(define names '(on-reset on-message-begin on-method-data on-method-complete
      on-url-data on-url-complete on-protocol-data on-protocol-complete
      on-version-data on-version-complete on-status-data on-status-complete
      on-header-field-data on-header-field-complete
      on-header-value-data on-header-value-complete
      on-headers-complete on-body-data on-chunk-header
      on-chunk-extension-name-data on-chunk-extension-name-complete
      on-chunk-extension-value-data on-chunk-extension-value-complete
      on-chunk-complete on-message-complete))
(define spans '(on-method-data on-url-data on-protocol-data on-version-data
      on-status-data on-header-field-data on-header-value-data on-body-data
      on-chunk-extension-name-data on-chunk-extension-value-data))
;; What on-headers-complete saw last: llhttp's rule, and the parser's field.
(define seen 'never)
(define (rule method flags)
  (or (= method 5)
      (let ((both (bitwise-ior F-UPGRADE F-CONNECTION-UPGRADE)))
        (= (bitwise-and flags both) both))))
(define (make complete)
  (make-parser httparse-message-machine
    (map (lambda (n)
           (list n (cond ((memq n spans) (lambda (p c bv f t) callback-continue))
                         ((eq? n 'on-headers-complete)
                          (lambda (p c)
                            (set! seen (list 'rule (rule (parser-field-ref p 'method)
                                                         (parser-field-ref p 'flags))
                                             'field (parser-field-ref p 'upgrade)))
                            callback-continue))
                         ((eq? n 'on-message-complete) (lambda (p c) complete))
                         (else (lambda (p c) callback-continue)))))
         names)
    #f (list (cons 'type (httparse-message-type-value 'request)))))
(define (code e) (and e (parser-error-code e)))
(define (show r) (list (parser-result-status r) 'consumed (parser-result-consumed r)
                       'next (parser-result-next r)
                       'error (code (parser-result-error r)) 'pause (code (parser-result-pause r))))
;; first-stop : Parser Bytevector Nat -> Datum
;; Deliveries of `size` bytes until the first result that is not need-input.
(define (first-stop p bv size)
  (let ((len (bytevector-length bv)))
    (let loop ((from 0))
      (if (>= from len)
          '(need-input to the end)
          (let* ((to (min len (+ from size))) (r (parser-feed! p bv from to)))
            (if (eq? (parser-result-status r) 'need-input)
                (loop to)
                (list 'delivery from to (show r))))))))
(define inputs
  '((upgrade      "PUT /url HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: ws\r\n\r\n")
    (upgrade-body "PUT /url HTTP/1.1\r\nConnection: upgrade\r\nContent-Length: 4\r\nUpgrade: ws\r\n\r\nabcdefgh")
    (connect-1.1  "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nTUNNEL")
    (connect-1.0  "CONNECT foo.bar.com:443 HTTP/1.0\r\nContent-Length: 10\r\n\r\nblarfcicle")
    (upgrade-h2c  "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n")
    (preface      "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nFRAME")
    (plain        "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    (upgrade-only "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n")
    (conn-only    "GET / HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\n\r\n")))
(display "--- (1), (3), (4): continue at on-message-complete; the first stop, a byte at a time and whole") (newline)
(for-each (lambda (in)
            (let ((bv (string->utf8 (cadr in))))
              (for-each (lambda (size)
                          (set! seen 'never)
                          (let ((stop (first-stop (make callback-continue) bv size)))
                            (write (list (car in) 'size size stop 'headers-complete seen))
                            (newline)))
                        (list 1 (bytevector-length bv)))))
          inputs)
(display "--- (2): pause at on-message-complete; then resume and feed an empty range at next") (newline)
(for-each (lambda (in)
            (let* ((bv (string->utf8 (cadr in))) (p (make callback-pause))
                   (r (parser-feed! p bv 0 (bytevector-length bv))))
              (write (list (car in) 'fed-whole (show r)))
              (when (eq? (parser-result-status r) 'paused)
                (parser-resume! p)
                (write (list 'then-empty-at (parser-result-next r)
                             (show (parser-feed! p bv (parser-result-next r) (parser-result-next r))))))
              (newline)))
          inputs)
