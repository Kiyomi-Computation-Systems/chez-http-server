#!r6rs
;; Measure: pausing at on-message-complete gives the connection layer an EXACT
;; pipelining boundary (parser-result-consumed), and resuming continues into
;; the next message. Also: read flags INSIDE on-headers-complete (before reset).
(import (rnrs)
        (generated httparse-message) (httparse modes) (byte-machine runtime))

(define trace '())
(define (note! . xs) (set! trace (cons xs trace)))

(define (span name)
  (lambda (p ctx bv from to)
    (note! name (utf8->string (let ((o (make-bytevector (- to from))))
                                (bytevector-copy! bv from o 0 (- to from)) o)))
    callback-continue))
(define (event name)
  (lambda (p ctx) (note! name) callback-continue))

(define bindings
  (list (list 'on-message-begin (event 'on-message-begin))
        (list 'on-method-data (span 'method)) (list 'on-method-complete (event 'on-method-complete))
        (list 'on-url-data (span 'url)) (list 'on-url-complete (event 'on-url-complete))
        (list 'on-protocol-data (span 'protocol)) (list 'on-protocol-complete (event 'on-protocol-complete))
        (list 'on-version-data (span 'version)) (list 'on-version-complete (event 'on-version-complete))
        (list 'on-status-data (span 'status)) (list 'on-status-complete (event 'on-status-complete))
        (list 'on-header-field-data (span 'hf)) (list 'on-header-field-complete (event 'on-header-field-complete))
        (list 'on-header-value-data (span 'hv)) (list 'on-header-value-complete (event 'on-header-value-complete))
        (list 'on-headers-complete
              (lambda (p ctx)
                (note! 'on-headers-complete 'flags (parser-field-ref p 'flags)
                       'cl (parser-field-ref p 'content-length)
                       'major (parser-field-ref p 'http-major) 'minor (parser-field-ref p 'http-minor))
                callback-continue))
        (list 'on-body-data (span 'body))
        (list 'on-chunk-header (event 'on-chunk-header))
        (list 'on-chunk-extension-name-data (span 'cen)) (list 'on-chunk-extension-name-complete (event 'cen-complete))
        (list 'on-chunk-extension-value-data (span 'cev)) (list 'on-chunk-extension-value-complete (event 'cev-complete))
        (list 'on-chunk-complete (event 'on-chunk-complete))
        (list 'on-message-complete (lambda (p ctx) (note! 'on-message-complete) callback-pause))
        (list 'on-reset (event 'on-reset))))

(define p (make-parser httparse-message-machine bindings 'ctx
                       (list (cons 'type (httparse-message-type-value 'request)))))

(define input (string->utf8 "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /b HTTP/1.1\r\nHost: y\r\nConnection: close\r\n\r\nGET /c HTTP/1.1\r\n\r\n"))
(define len (bytevector-length input))

(define (show r)
  (display (list 'status (parser-result-status r) 'consumed (parser-result-consumed r)
                 'offset (parser-result-stream-offset r)
                 'error (let ((e (parser-result-error r))) (and e (list (parser-error-code e) (parser-error-reason e) (parser-error-offset e))))))
  (newline))

(define r1 (parser-feed! p input 0 len))
(show r1)
(define at (parser-result-consumed r1))
(display "first message ends at byte ") (display at) (display " of ") (display len) (newline)
(display "resume -> ") (display (parser-resume! p)) (newline)
(define r2 (parser-feed! p input at len))
(show r2)
(define at2 (+ at (parser-result-consumed r2)))
(display "second message ends at byte ") (display at2) (newline)
(display "resume -> ") (display (parser-resume! p)) (newline)
;; Now the close-marked message is done. Feed the remainder anyway, to show the
;; data-after-close error the connection layer must avoid by NOT feeding.
(define r3 (parser-feed! p input at2 len))
(show r3)
(for-each (lambda (x) (display "  ") (write x) (newline)) (reverse trace))
