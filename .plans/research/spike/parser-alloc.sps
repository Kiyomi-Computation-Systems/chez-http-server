#!r6rs
;; Per-connection Scheme-side cost: one make-parser (bindings shared) and one 3-closure set.
(import (rnrs) (generated httparse-message) (httparse modes) (byte-machine runtime)
        (only (chezscheme) printf statistics sstats-bytes))
(define (silent)
  (define (e p c) callback-continue) (define (s p c bv f t) callback-continue)
  (map (lambda (n) (list n (if (memq n '(on-method-data on-url-data on-protocol-data on-version-data on-status-data
                                          on-header-field-data on-header-value-data on-body-data
                                          on-chunk-extension-name-data on-chunk-extension-value-data)) s e)))
       '(on-reset on-message-begin on-method-data on-method-complete on-url-data on-url-complete on-protocol-data
         on-protocol-complete on-version-data on-version-complete on-status-data on-status-complete
         on-header-field-data on-header-field-complete on-header-value-data on-header-value-complete
         on-headers-complete on-body-data on-chunk-header on-chunk-extension-name-data
         on-chunk-extension-name-complete on-chunk-extension-value-data on-chunk-extension-value-complete
         on-chunk-complete on-message-complete)))
(define shared (silent))
(define inits (list (cons 'type (httparse-message-type-value 'request))))
(define keep '())
(define (mk n) (let loop ((i 0)) (when (< i n) (set! keep (cons (make-parser httparse-message-machine shared #f inits) keep)) (loop (+ i 1)))))
(mk 100) (set! keep '())
(let ((b (sstats-bytes (statistics)))) (mk 10000)
  (printf "make-parser (shared bindings): ~a bytes each\n" (div (- (sstats-bytes (statistics)) b) 10000)))
(set! keep '())
(let ((b (sstats-bytes (statistics)))) (let loop ((i 0)) (when (< i 10000) (set! keep (cons (silent) keep)) (loop (+ i 1))))
  (printf "a fresh 25-entry binding list per connection would add: ~a bytes each\n" (div (- (sstats-bytes (statistics)) b) 10000)))
