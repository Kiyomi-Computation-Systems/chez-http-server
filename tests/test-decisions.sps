#!r6rs
;;; (http-server decisions): every status the server originates, in one place
;;; (design §6.5).
;;;
;;; Oracles: design §6.5's table of originated statuses; design §6.3's parser
;;; map (`invalid-transfer-encoding` splits by node name, never by reason
;;; string, chez-httparse #36 and its docs/api.org); decision 0006 item 2 (the
;;; HTTP/2 preface is answered 505) as amended on 2026-09-25; chez-httparse's
;;; own table of its error codes (`adapter-error-codes`, from its test
;;; harness), which fixes the codes the map must cover; and the four hand-off
;;; rows research/spike/smoke-v040.sps ran at the pin (ledger, 2026-09-19
;;; night).  Which requests upgrade is the parser's own answer, its `upgrade`
;;; field (chez-httparse v0.4.1, #47), pinned in test-flag-pins.sps.
(import (rnrs) (srfi :64) (testing)
        (http-server decisions)
        (httparse test adapter)          ; adapter-error-codes, adapter-trace-names
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
  (let* ((r (feed-whole text callback-continue)))
    (if (eq? (parser-result-status r) 'error)
        (let ((e (parser-result-error r)))
          (parser-error-status (parser-error-code e) (parser-error-node-name e)))
        'no-error)))

;; request-parser : Outcome -> Parser
;; A request parser whose callbacks all continue, except on-message-complete,
;; which answers `complete`.
(define (request-parser complete)
  (make-parser httparse-message-machine
               (map (lambda (row)
                      (list (car row)
                            (case (car row)
                              ((on-message-complete) (lambda (p ctx) complete))
                              (else (if (eq? (cadr row) 'span)
                                        (lambda (p ctx bv from to) callback-continue)
                                        (lambda (p ctx) callback-continue))))))
                    adapter-trace-names)
               #f (list (cons 'type (httparse-message-type-value 'request)))))

;; feed-whole : String Outcome -> ParserResult
;; `text` fed whole to a request parser whose on-message-complete answers
;; `complete`.
(define (feed-whole text complete)
  (let ((bv (string->utf8 text)))
    (parser-feed! (request-parser complete) bv 0 (bytevector-length bv))))

;; hands-off? : ParserResult -> Boolean
;; result-hands-off-stream? over what the shell's parser-result event carries:
;; the status, and the error's and the pause's codes.
(define (hands-off? r)
  (let ((code (lambda (e) (and e (parser-error-code e)))))
    (result-hands-off-stream? (parser-result-status r)
                              (code (parser-result-error r)) (code (parser-result-pause r)))))

(run-suite "decisions"
  (lambda ()
    ;; --- the core's own reasons (design §6.5, policy and application) -----
    (test-equal "each reason the core closes with after a response, and its status"
                '((target-redirect . 301) (invalid-target . 400)
                  (invalid-host . 400) (header-timeout . 408) (target-too-large . 414)
                  (headers-too-large . 431) (too-many-headers . 431)
                  (header-field-too-large . 431) (header-value-too-large . 431)
                  (handler-failed . 500) (http2-preface . 505))
                (map (lambda (r) (cons r (reason-status r)))
                     '(target-redirect invalid-target invalid-host header-timeout
                       target-too-large headers-too-large too-many-headers
                       header-field-too-large header-value-too-large handler-failed
                       http2-preface)))
    ;; A connection that closes with no response has no status to give, and
    ;; one that closes after the handler's response (an upgrade, M2.5) gives
    ;; the handler's.
    (test-equal "a reason with no originated response is refused" '()
                (filter (lambda (r) (eq? 'accepted (verdict (lambda () (reason-status r)))))
                        '(not-keep-alive upgrade eof read-error idle-timeout no-such-reason)))
    ;; A parser error's status depends on the error, so it comes from
    ;; parser-error-status, never from the reason the connection closes with.
    (test-eq "parser-error has no status of its own" 'refused
             (verdict (lambda () (reason-status 'parser-error))))

    ;; --- the parser's codes (design §6.3) ---------------------------------
    (test-eqv "chez-httparse's error channel carries 18 codes" 18 (length error-channel-codes))
    (test-equal "every code but the split one and the hand-off is a 400, whatever its node" '()
                (filter (lambda (c)
                          (and (not (memq c '(invalid-transfer-encoding paused-h2-upgrade)))
                               (not (= 400 (parser-error-status c 'any-node)))))
                        error-channel-codes))
    (test-eqv "invalid-transfer-encoding at e-request-invalid-te is a 501"
              501 (parser-error-status 'invalid-transfer-encoding 'e-request-invalid-te))
    (test-eqv "invalid-transfer-encoding at any other node is a 400"
              400 (parser-error-status 'invalid-transfer-encoding 'e-bad-te-value))
    ;; Both hand-off codes are refused: a hand-off is answered by the core's
    ;; own reason (http2-preface, above), never as a parser error (M2.5).
    (test-eq "paused-h2-upgrade is a hand-off, not an error" 'refused
             (verdict (lambda () (parser-error-status 'paused-h2-upgrade 'e-pri-upgrade))))
    (test-eq "paused-upgrade is a pause reason, not an error" 'refused
             (verdict (lambda () (parser-error-status 'paused-upgrade 'upgrade-pause))))
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
              (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: chunked,deflate\r\n\r\n"))

    ;; --- the hand-off, on either channel (design §4.4; M2.5) -----------------
    ;; chez-httparse's docs/api.org: a CONNECT tunnel, `Connection: upgrade`
    ;; and a 101 pause with the reason paused-upgrade, and the HTTP/2 preface
    ;; is an error with the code paused-h2-upgrade; a plain pause carries no
    ;; reason.  The four rows research/spike/smoke-v040.sps ran at the pin.
    (test-eq "at the pin, a CONNECT tunnel hands off (the pause channel)" #t
             (hands-off? (feed-whole "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\nTUNNEL"
                                     callback-continue)))
    (test-eq "at the pin, Connection: upgrade hands off (the pause channel)" #t
             (hands-off? (feed-whole "GET /chat HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\nWSDATA"
                                     callback-continue)))
    (test-eq "at the pin, the HTTP/2 preface hands off (the error channel)" #t
             (hands-off? (feed-whole "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nFRAME" callback-continue)))
    (test-eq "at the pin, a plain pause at on-message-complete does not hand off" #f
             (hands-off? (feed-whole "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n" callback-pause)))
    ;; Each code counts only on its own channel.
    (test-equal "a hand-off code on the other channel is no hand-off" '(#f #f)
                (list (result-hands-off-stream? 'error 'paused-upgrade #f)
                      (result-hands-off-stream? 'paused #f 'paused-h2-upgrade)))))
