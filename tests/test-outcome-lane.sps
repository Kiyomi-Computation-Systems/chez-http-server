#!r6rs
;;; (test-outcome-lane) — the outcome lane: design §8.1's property 2.  M2.4.
;;;
;;; Every strict (type=request) fixture, fed to one fake connection at every
;;; scheduled chunk size, has one outcome: the handlers called and the
;;; requests they got, the responses written, the close and its reason, the
;;; state it ended in, and every action run from the outermost drain (see
;;; (outcome-lane)).  `make test` runs 'extremes; the release lane runs 'full
;;; under CORPUS=full (plan §2.2), the M2 exit's two selections.
;;;
;;; Since M2.5 that holds for all 135, the four upgrades M2.4 listed
;;; included: the core serves an upgrade and closes the connection after the
;;; response, so the parser is never resumed onto its own hand-off (decision
;;; 0006's amendment, on the owner's word, 2026-09-25).  Since M6.1 it holds
;;; with two handlers, one that reads every body and one that reads none
;;; (decision 0013; see (outcome-lane)).
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) getenv)
        (only (http-server switch) switch-protocols)
        (trace-lane) (outcome-lane))

(define selection
  (let ((v (getenv "CORPUS"))) (if (and (string? v) (string=? v "full")) 'full 'extremes)))

;; The instrument, calibrated on an input whose outcome is known from
;; decision 0004 and the input's own bytes: research/spike/pipeline-pause.sps's
;; three messages, the second close-marked.  An outcome that saw nothing
;; would pass every fixture.
(define spike
  (string->utf8 (string-append "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
                               "GET /b HTTP/1.1\r\nHost: y\r\nConnection: close\r\n\r\n"
                               "GET /c HTTP/1.1\r\n\r\n")))
(define spike-outcome
  '(((call-handler (POST "/a" 1 1 (("Host" . "x") ("Content-Length" . "3"))))
     (write 200)
     (call-handler (GET "/b" 1 1 (("Host" . "y") ("Connection" . "close"))))
     (write 200)
     (close not-keep-alive))
    closed not-keep-alive ()))
;; With a handler that reads no body, the POST, whose head announces one, is
;; answered at once and closes the connection (decision 0013 item 4).
(define spike-answered
  '(((call-handler (POST "/a" 1 1 (("Host" . "x") ("Content-Length" . "3"))))
     (write 200)
     (close unread-body))
    closed unread-body ()))

(define (diag line)
  (let ((p (current-error-port))) (put-string p line) (put-char p #\newline) (flush-output-port p)))

(run-suite "outcome-lane"
  (lambda ()
    (diag (string-append "outcome-lane: selection=" (symbol->string selection)
                         " scan-runs=" (number->string
                                        (trace-scan-runs (map cdr strict-request-fixtures) selection))))
    (test-eqv "135 strict fixtures in the lane" 135 (length strict-request-fixtures))
    (test-equal "the instrument: the spike's messages whole give two handlers, two responses, the close"
                spike-outcome (outcome-at spike 117))
    (test-equal "and a byte at a time, the same" spike-outcome (outcome-at spike 1))
    (test-equal "a handler that reads no body: the POST answered, then the close, whole and a byte at a time"
                (list spike-answered spike-answered)
                (list (outcome-at spike 117 answers) (outcome-at spike 1 answers)))
    ;; The lane renders a hand-off by the bytes handed over (M8.2): a
    ;; WebSocket handshake taken by a handler's switch, read whole, with
    ;; another protocol's 5 bytes after it.
    (test-equal "the instrument renders a hand-off: a handshake taken, the bytes after it handed over"
                '(((call-handler (GET "/chat" 1 1 (("Host" . "x") ("Connection" . "upgrade") ("Upgrade" . "websocket"))))
                   (write 101)
                   (hand-off "FRAME"))
                  handed-off upgrade ())
                (let ((in (string->utf8 "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\nFRAME")))
                  (outcome-at in (bytevector-length in)
                              (lambda (request)
                                (switch-protocols (list (cons (string->utf8 "Upgrade") (string->utf8 "websocket")))
                                                  (lambda (transport retained) #t))))))
    (for-each
     (lambda (handler name)
       (let* ((results (map (lambda (p) (cons (car p) (outcome-mismatch (cdr p) selection handler)))
                            strict-request-fixtures))
              (varied (filter cdr results)))
         (for-each (lambda (r) (diag (string-append "OUTCOME MISMATCH (" name ") " (car r) ": " (cdr r))))
                   varied)
         (test-equal (string-append "every fixture has one outcome at every chunk size, " name)
                     '() (map car varied))))
     (list reads answers)
     (list "its bodies read" "its bodies left unread"))))
