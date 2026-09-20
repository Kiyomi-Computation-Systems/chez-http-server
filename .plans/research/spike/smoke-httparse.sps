#!r6rs
(import (rnrs) (generated httparse-message) (httparse modes) (byte-machine runtime))
(define events '())
(define (ev name) (lambda (p ctx) (set! events (cons name events)) callback-continue))
(define (sp name) (lambda (p ctx bv from to) (set! events (cons (list name (utf8->string (let ((o (make-bytevector (- to from)))) (bytevector-copy! bv from o 0 (- to from)) o))) events)) callback-continue))
(define names-span '(on-method-data on-url-data on-protocol-data on-version-data on-status-data on-header-field-data on-header-value-data on-body-data on-chunk-extension-name-data on-chunk-extension-value-data))
(define names-ev '(on-method-complete on-url-complete on-protocol-complete on-version-complete on-status-complete on-header-field-complete on-header-value-complete on-chunk-extension-name-complete on-chunk-extension-value-complete on-message-begin on-headers-complete on-chunk-header on-chunk-complete on-message-complete on-reset))
(define parser (make-parser httparse-message-machine
  (append (map (lambda (n) (list n (sp n))) names-span) (map (lambda (n) (list n (ev n))) names-ev))
  #f (list (cons 'type (httparse-message-type-value 'request)) (cons 'lenient-flags (httparse-lenient-flags-value '())))))
(define input (string->utf8 "GET /a?b=1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /2 HTTP/1.1\r\n\r\n"))
(define r (parser-feed! parser input 0 (bytevector-length input)))
(display (list 'status (parser-result-status r) 'consumed (parser-result-consumed r) 'flags (parser-field-ref parser 'flags) 'method (parser-field-ref parser 'method))) (newline)
(for-each (lambda (e) (display e) (newline)) (reverse events))
