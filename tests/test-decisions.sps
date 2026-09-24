#!r6rs
;;; (http-server decisions): every status the server originates, in one place
;;; (design §6.5).
;;;
;;; Oracles: design §6.5's table of originated statuses; design §6.3's parser
;;; map (`invalid-transfer-encoding` splits by node name, never by reason
;;; string, chez-httparse #36 and its docs/api.org); decision 0006 item 2 (an
;;; h2c preface is answered 505); chez-httparse's own table of its error codes
;;; (`adapter-error-codes`, from its test harness), which fixes the codes the
;;; map must cover.
(import (rnrs) (srfi :64) (testing)
        (http-server decisions)
        (httparse test adapter)          ; adapter-error-codes
        (generated httparse-message) (httparse modes) (byte-machine runtime))

;; verdict : (-> Any) -> (U 'accepted 'refused)
(define (verdict thunk)
  (guard (e ((assertion-violation? e) 'refused))
    (thunk)
    'accepted))

;; The codes chez-httparse's error channel carries: its table's codes, less
;; paused-upgrade (a pause reason, read from parser-result-pause), plus
;; unexpected-message-type, the one code with no llhttp number (a parser made
;; without a message type).
(define error-channel-codes
  (append (filter (lambda (c) (not (eq? c 'paused-upgrade))) (map car adapter-error-codes))
          '(unexpected-message-type)))

;; parse-error-status : String -> (U Nat Symbol)
;; Feed `text` whole to chez-httparse as a request, and map the error it
;; returns; 'no-error if it returns none.
(define (parse-error-status text)
  (let* ((silent (map (lambda (row)
                        (list (car row)
                              (if (eq? (cadr row) 'span)
                                  (lambda (p ctx bv from to) callback-continue)
                                  (lambda (p ctx) callback-continue))))
                      adapter-trace-names))
         (p (make-parser httparse-message-machine silent #f
                         (list (cons 'type (httparse-message-type-value 'request)))))
         (bv (string->utf8 text))
         (r (parser-feed! p bv 0 (bytevector-length bv))))
    (if (eq? (parser-result-status r) 'error)
        (let ((e (parser-result-error r)))
          (parser-error-status (parser-error-code e) (parser-error-node-name e)))
        'no-error)))

(run-suite "decisions"
  (lambda ()
    ;; --- the core's own reasons (design §6.5, policy and application) -----
    (test-equal "each reason the core closes with after a response, and its status"
                '((parser-error . 400) (invalid-target . 400) (header-timeout . 408)
                  (target-too-large . 414)
                  (headers-too-large . 431) (too-many-headers . 431)
                  (header-field-too-large . 431) (header-value-too-large . 431)
                  (handler-failed . 500))
                (map (lambda (r) (cons r (reason-status r)))
                     '(parser-error invalid-target header-timeout target-too-large
                       headers-too-large too-many-headers
                       header-field-too-large header-value-too-large handler-failed)))
    ;; A connection that closes with no response has no status to give.
    (test-equal "a reason with no originated response is refused" '()
                (filter (lambda (r) (eq? 'accepted (verdict (lambda () (reason-status r)))))
                        '(not-keep-alive eof read-error idle-timeout no-such-reason)))

    ;; --- the parser's codes (design §6.3) ---------------------------------
    (test-eqv "chez-httparse's error channel carries 18 codes" 18 (length error-channel-codes))
    (test-equal "every code but two is a 400, whatever its node" '()
                (filter (lambda (c)
                          (and (not (memq c '(invalid-transfer-encoding paused-h2-upgrade)))
                               (not (= 400 (parser-error-status c 'any-node)))))
                        error-channel-codes))
    (test-eqv "invalid-transfer-encoding at e-request-invalid-te is a 501"
              501 (parser-error-status 'invalid-transfer-encoding 'e-request-invalid-te))
    (test-eqv "invalid-transfer-encoding at any other node is a 400"
              400 (parser-error-status 'invalid-transfer-encoding 'e-bad-te-value))
    (test-eqv "an h2c preface is a 505 (0006 item 2)"
              505 (parser-error-status 'paused-h2-upgrade 'e-pri-upgrade))
    (test-eq "paused-upgrade is a pause reason, not an error" 'refused
             (verdict (lambda () (parser-error-status 'paused-upgrade 'e-upgrade-paused))))
    (test-eq "a code outside chez-httparse's vocabulary is refused" 'refused
             (verdict (lambda () (parser-error-status 'no-such-code 'e-none))))
    (test-eq "the core's own callback code is not a parser code" 'refused
             (verdict (lambda () (parser-error-status 'too-many-headers 'e-callback))))

    ;; The split keys on a node name, and a node name can move upstream, so the
    ;; map is checked against the parser at the pin: the two cases
    ;; chez-httparse's docs/api.org and the design's smoke run name.
    (test-eqv "a real Transfer-Encoding: pigeons request maps to 501" 501
              (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: pigeons\r\n\r\n"))
    (test-eqv "a real Transfer-Encoding: chunked,deflate request maps to 400" 400
              (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: chunked,deflate\r\n\r\n"))))
