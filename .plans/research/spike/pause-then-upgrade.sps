#!r6rs
;; M2.4, 2026-09-25: where an upgrade's hand-off arrives when every message's
;; end is paused.  The core answers on-message-complete with a pause (decision
;; 0004 item 1); this program does the same with a silent binding list, then
;; resumes and feeds from parser-result-next, as the message loop does.  It
;; shows the result at each step for a CONNECT tunnel, a `Connection: upgrade`
;; request, the h2c preface and two pipelined GETs.  Run on the project's
;; library path (the ledger's M2.4 entry gives it).
(import (rnrs) (generated httparse-message) (httparse modes) (byte-machine runtime))
(define (ev name) (lambda (p c) (if (eq? name 'on-message-complete) callback-pause callback-continue)))
(define (sp name) (lambda (p c bv f t) callback-continue))
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
(define bindings (map (lambda (n) (list n (if (memq n spans) (sp n) (ev n)))) names))
(define (show label r)
  (display (list label (parser-result-status r) 'consumed (parser-result-consumed r) 'next (parser-result-next r)
                 'pause (let ((e (parser-result-pause r))) (and e (parser-error-code e)))
                 'error (let ((e (parser-result-error r))) (and e (parser-error-code e)))))
  (newline))
;; run : Symbol String -> Void — feed the whole input; at each pause, resume and
;; feed on from next, three times at most.
(define (run label s)
  (let* ((bv (string->utf8 s)) (len (bytevector-length bv))
         (p (make-parser httparse-message-machine bindings #f (list (cons 'type (httparse-message-type-value 'request))))))
    (let loop ((at 0) (i 0))
      (let ((r (parser-feed! p bv at len)))
        (show (list label i) r)
        (when (and (eq? (parser-result-status r) 'paused) (< i 3))
          (display (list 'resume (parser-resume! p))) (newline)
          (loop (parser-result-next r) (+ i 1)))))))
(run 'connect "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nTUNNEL")
(run 'upgrade "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\nFRAME")
(run 'h2c "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nxx")
(run 'plain2 "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n")
