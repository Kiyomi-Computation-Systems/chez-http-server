#!r6rs
;;; (http-server decisions): every status the server originates, in one place.
;;;
;;; Oracles: the library's table of originated statuses; the parser map, every
;;; parser error a 400: a request's Transfer-Encoding the parser refuses leaves
;;; the body's length undetermined, which RFC 9112 §6.3 answers 400; the
;;; HTTP/2 preface is answered 505; chez-httparse's own table of its error
;;; codes (`adapter-error-codes`, from its test harness), which fixes the codes
;;; the map must cover; and four hand-off rows run against chez-httparse: a
;;; CONNECT tunnel, `Connection: upgrade`, the HTTP/2 preface and a plain
;;; pause.  Which requests upgrade is the parser's own answer, its `upgrade`
;;; field (chez-httparse v0.4.1 or later), pinned in test-flag-pins.sps.
;;;
;;; The framing decision is RFC 9112 §6's and RFC 9110 §8.6's rules, each row
;;; citing its own: only a HEAD's answer announces a length, and an HTTP/1.0
;;; client that keeps the connection is told `keep-alive`.  Its answers are
;;; the serializer's own framing modes.  The request versions in the rows are
;;; the four chez-httparse's strict parser hands a handler: 0.9, 1.0, 1.1 and
;;; 2.0 reach on-headers-complete, and 1.2, 1.9, 2.1, 3.0 and 9.9 are refused.
(import (rnrs) (srfi :64) (testing)
        (http-server decisions)
        (only (http-server serializer) framing-modes)
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
          (parser-error-status (parser-error-code e)))
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

;; The framing table.  A row: what it shows; the request's method, #f for
;; none the core has read; its major and minor version; the response's
;; status; its body's length, #f for no body and `unknown` for a length not
;; known before the body is written (a stream); and the framing mode.
(define framing-rows
  '(;; A length the server knows is announced: an origin server SHOULD send
    ;; Content-Length when it knows the size (RFC 9110 §8.6).
    ("a body of known length gets Content-Length" GET 1 1 200 13 content-length)
    ("no body gets Content-Length: 0" GET 1 1 200 #f content-length)
    ("an empty body gets Content-Length: 0" GET 1 1 200 0 content-length)
    ("HTTP/1.0 gets Content-Length too (RFC 1945 §10.4)" GET 1 0 200 13 content-length)
    ("a 205 with no body gets Content-Length: 0, one of RFC 9110 §15.3.6's three framings"
     POST 1 1 205 #f content-length)
    ("the core's own answer to no request it has read gets Content-Length: 0"
     #f 1 1 400 #f content-length)
    ;; A length the server does not know.  Only HTTP/1.1 may be sent
    ;; Transfer-Encoding (RFC 9112 §6.1); anything else reads to the close.
    ("an unknown length to HTTP/1.1 is chunked (RFC 9112 §7.1)" GET 1 1 200 unknown chunked)
    ("an unknown length to HTTP/1.0 is close-delimited" GET 1 0 200 unknown close-delimited)
    ("an unknown length to HTTP/0.9 is close-delimited" GET 0 9 200 unknown close-delimited)
    ("an unknown length to HTTP/2.0, in HTTP/1 syntax, is close-delimited"
     GET 2 0 200 unknown close-delimited)
    ;; A HEAD's answer has no body (RFC 9110 §9.3.2).  Its Content-Length, if
    ;; any, must be the GET's (§8.6).
    ("a HEAD answered with the GET's body gets its Content-Length and no body"
     HEAD 1 1 200 13 content-length-only)
    ("a HEAD answered with no body gets neither: the GET's length is unknown"
     HEAD 1 1 200 #f no-body)
    ("a HEAD answered with an unknown length gets neither" HEAD 1 1 200 unknown no-body)
    ("a HEAD to HTTP/1.0 of unknown length gets neither: it ends at the blank line (RFC 9112 §6.3 rule 1)"
     HEAD 1 0 200 unknown no-body)
    ;; A 1xx, a 204 and a 304 end at the blank line whatever they say (RFC
    ;; 9112 §6.3 rule 1).  A 1xx and a 204 must not carry Content-Length or
    ;; Transfer-Encoding (RFC 9110 §8.6, RFC 9112 §6.1); a 304 may carry the
    ;; 200's Content-Length, but the server announces a length only in a
    ;; HEAD's answer.
    ("a 1xx gets neither (such as 100 Continue)" GET 1 1 100 #f no-body)
    ("the last 1xx gets neither" GET 1 1 199 #f no-body)
    ("a 204 with a body gets neither, and its body is not written" GET 1 1 204 13 no-body)
    ("a 204 of unknown length is not chunked" GET 1 1 204 unknown no-body)
    ("a 204 to a HEAD gets no Content-Length: the 204's rule comes first" HEAD 1 1 204 13 no-body)
    ("a 304 with a body gets neither, and its body is not written" GET 1 1 304 13 no-body)
    ("a 304 to a HEAD gets neither" HEAD 1 1 304 13 no-body)
    ("a 303, next to it, is framed as usual" GET 1 1 303 13 content-length)
    ;; A 2xx to CONNECT makes the connection a tunnel after the blank line;
    ;; it carries neither field and no body (RFC 9110 §9.3.6, RFC 9112 §6.3
    ;; rule 2).  Any other status to CONNECT is an ordinary response.
    ("a 2xx to CONNECT gets neither, and its body is not written" CONNECT 1 1 200 13 no-body)
    ("the last 2xx to CONNECT, of unknown length, gets neither" CONNECT 1 1 299 unknown no-body)
    ("a 3xx to CONNECT is framed as usual" CONNECT 1 1 300 13 content-length)
    ("a 407 to CONNECT is framed as usual" CONNECT 1 1 407 13 content-length)))

;; framing : Row -> Symbol — the decision for the row's request and response.
(define (framing row)
  (response-framing (list-ref row 1) (list-ref row 2) (list-ref row 3)
                    (list-ref row 4) (list-ref row 5)))

;; The Connection field, by the request's version: what the last response
;; says, and what a response on a connection that stays says.  A row: what it
;; shows, the major and minor version, and the two answers.
(define connection-rows
  '(("HTTP/1.1: close on the last response, nothing while it stays: persistence is 1.1's default (RFC 9112 §9.3)"
     1 1 (close #f))
    ("HTTP/1.0: close on the last response, keep-alive while it stays (RFC 9112 Appendix C.2.2)"
     1 0 (close keep-alive))
    ("HTTP/0.9: the same as 1.0" 0 9 (close keep-alive))
    ("HTTP/2.0, in HTTP/1 syntax: the same as 1.0 by llhttp's gate" 2 0 (close keep-alive))))

(run-suite "decisions"
  (lambda ()
    ;; --- the core's own reasons (policy and application) ------------------
    ;; invalid-response: a handler's response the serializer cannot write
    ;; safely is answered 500, as a handler that raised is.
    (test-equal "each reason the core closes with after a response, and its status"
                '((target-redirect . 301) (invalid-target . 400)
                  (invalid-host . 400) (faulty-framing . 400)
                  (header-timeout . 408) (body-timeout . 408) (target-too-large . 414)
                  (headers-too-large . 431) (too-many-headers . 431)
                  (header-field-too-large . 431) (header-value-too-large . 431)
                  (handler-failed . 500) (invalid-response . 500)
                  (unsupported-transfer-coding . 501) (version-not-supported . 505)
                  (http2-preface . 505))
                (map (lambda (r) (cons r (reason-status r)))
                     '(target-redirect invalid-target invalid-host faulty-framing header-timeout
                       body-timeout target-too-large headers-too-large too-many-headers
                       header-field-too-large header-value-too-large handler-failed
                       invalid-response unsupported-transfer-coding version-not-supported
                       http2-preface)))
    ;; A connection that closes with no response has no status to give, and
    ;; one that closes after the handler's response (an upgrade; the handler's
    ;; own `Connection: close`, or a body the close ends) gives the handler's.
    (test-equal "a reason with no originated response is refused" '()
                (filter (lambda (r) (eq? 'accepted (verdict (lambda () (reason-status r)))))
                        '(not-keep-alive upgrade handler-close close-delimited eof read-error
                          idle-timeout write-timeout no-such-reason)))
    ;; A parser error's status depends on the error, so it comes from
    ;; parser-error-status, never from the reason the connection closes with.
    (test-eq "parser-error has no status of its own" 'refused
             (verdict (lambda () (reason-status 'parser-error))))

    ;; --- the parser's codes -----------------------------------------------
    (test-eqv "chez-httparse's error channel carries 18 codes" 18 (length error-channel-codes))
    ;; invalid-transfer-encoding among them, at whichever node the parser
    ;; refused: none leaves the body's length known (RFC 9112 §6.3).  The
    ;; 501 for a coding the server does not implement is the core's own
    ;; reason, unsupported-transfer-coding, above.
    (test-equal "every code but the hand-off is a 400" '()
                (filter (lambda (c)
                          (and (not (eq? c 'paused-h2-upgrade))
                               (not (= 400 (parser-error-status c)))))
                        error-channel-codes))
    ;; Both hand-off codes are refused: a hand-off is answered by the core's
    ;; own reason (http2-preface, above), never as a parser error.
    (test-eq "paused-h2-upgrade is a hand-off, not an error" 'refused
             (verdict (lambda () (parser-error-status 'paused-h2-upgrade))))
    (test-eq "paused-upgrade is a pause reason, not an error" 'refused
             (verdict (lambda () (parser-error-status 'paused-upgrade))))
    (test-eq "a code outside chez-httparse's vocabulary is refused" 'refused
             (verdict (lambda () (parser-error-status 'no-such-code))))
    (test-eq "the core's own callback code is not a parser code" 'refused
             (verdict (lambda () (parser-error-status 'too-many-headers))))

    ;; The map is checked against the parser at the pin.  With no chunked, or
    ;; a coding after it, the parser refuses the request: a 400.  A coding
    ;; before a final chunked it lets through, for the core to answer 501
    ;; ((http-server transfer-coding)).
    (test-eqv "a real Transfer-Encoding: pigeons request maps to 400" 400
              (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: pigeons\r\n\r\n"))
    (test-eqv "a real Transfer-Encoding: chunked,deflate request maps to 400" 400
              (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: chunked,deflate\r\n\r\n"))
    (test-eq "at the pin, a coding before a final chunked is no parser error" 'no-error
             (parse-error-status "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"))

    ;; --- the hand-off, on either channel ---------------------------------
    ;; chez-httparse's docs/api.org: a CONNECT tunnel, `Connection: upgrade`
    ;; and a 101 pause with the reason paused-upgrade, and the HTTP/2 preface
    ;; is an error with the code paused-h2-upgrade; a plain pause carries no
    ;; reason.
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
                      (result-hands-off-stream? 'paused #f 'paused-h2-upgrade)))

    ;; --- the framing decision --------------------------------------------
    (for-each (lambda (row) (test-eq (car row) (list-ref row 6) (framing row)))
              framing-rows)
    (test-equal "every answer is one of the serializer's framing modes" '()
                (filter (lambda (mode) (not (memq mode framing-modes)))
                        (map framing framing-rows)))
    (test-equal "every framing mode is some row's answer" framing-modes
                (filter (lambda (mode) (memq mode (map framing framing-rows))) framing-modes))
    (test-eq "a length that is not a count, #f or unknown is refused" 'refused
             (verdict (lambda () (response-framing 'GET 1 1 200 'unknwon))))
    ;; A status outside RFC 9110 §15's 100–599 is none; one that is not a
    ;; fixnum at all is refused by the fixnum comparisons in any case.
    (test-equal "a status outside 100–599 is refused" '(refused refused)
                (list (verdict (lambda () (response-framing 'GET 1 1 99 13)))
                      (verdict (lambda () (response-framing 'GET 1 1 600 13)))))
    (for-each (lambda (row)
                (test-equal (car row) (list-ref row 3)
                            (list (response-connection #t (list-ref row 1) (list-ref row 2))
                                  (response-connection #f (list-ref row 1) (list-ref row 2)))))
              connection-rows)
    ;; The gate the rows above turn on, which (http-server transfer-coding)
    ;; reads too: of the versions the strict parser admits, only 1.1 passes.
    (test-equal "llhttp's version gate passes 1.1 alone"
                '(#t #f #f #f)
                (map (lambda (v) (if (http/1.1? (car v) (cadr v)) #t #f)) '((1 1) (1 0) (0 9) (2 0))))))
