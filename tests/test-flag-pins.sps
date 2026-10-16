#!r6rs
;;; Pin test: the F-* flag constants and method numbers the recorded parser
;;; traces depend on are IMPORTED from (httparse decisions) and
;;; (httparse methods), never copied, and must equal llhttp's own values.
;;;
;;; Oracle: llhttp's FLAGS enum and method table (src/native/http.c and
;;; llhttp.h) — F_CONNECTION_CLOSE = 1<<1 = 2, F_SKIP_BODY = 1<<6 = 64, and the
;;; method numbering the corpus traces are read against.  If a dependency bump
;;; ever moves one of these, this suite reddens before any trace can lie.
;;;
;;; The adapter also reads the parser's `upgrade` field, llhttp's own answer to
;;; whether a message upgrades (chez-httparse v0.4.1 or later documents it as
;;; llhttp's `llhttp_get_upgrade`).  Its oracle is llhttp's recorded logs,
;;; which pause for an upgrade exactly when one of a fixture's messages
;;; upgrades.
(import (rnrs) (srfi :64) (testing)
        (httparse decisions) (httparse methods)
        (httparse test adapter)          ; adapter-trace-names
        (httparse test corpus-load)      ; fixture-input-text, fixture-expected
        (httparse test corpus-decode)    ; corpus-decode-input
        (only (trace-lane) strict-request-fixtures)
        (generated httparse-message) (httparse modes) (byte-machine runtime))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) sub) (loop (+ i 1)))))))

;; logged-upgrades : -> (Listof String)
;; The strict fixtures whose recorded llhttp logs pause for an upgrade.  Read
;; inside the suite, where a raise is a harness error.
(define (logged-upgrades)
  (map car (filter (lambda (pr)
                     (exists (lambda (line)
                               (contains? (expectation-text line) "Pause on CONNECT/Upgrade"))
                             (fixture-expected (cdr pr))))
                   strict-request-fixtures)))

;; upgrading-fixtures : -> (Listof String)
;; The strict fixtures with a message whose `upgrade` field is 1 at its
;; on-headers-complete, each fed whole to a request parser whose callbacks all
;; continue, and resumed past every pause.
(define (upgrading-fixtures)
  (filter (lambda (id) id)
          (map (lambda (pr)
                 (let* ((marked #f)
                        (bv (corpus-decode-input (fixture-input-text (cdr pr))))
                        (len (bytevector-length bv))
                        (p (make-parser
                            httparse-message-machine
                            (map (lambda (row)
                                   (list (car row)
                                         (cond ((eq? (car row) 'on-headers-complete)
                                                (lambda (p ctx)
                                                  (when (= 1 (parser-field-ref p 'upgrade))
                                                    (set! marked #t))
                                                  callback-continue))
                                               ((eq? (cadr row) 'span)
                                                (lambda (p ctx bv from to) callback-continue))
                                               (else (lambda (p ctx) callback-continue)))))
                                 adapter-trace-names)
                            #f (list (cons 'type (httparse-message-type-value 'request))))))
                   (let loop ((at 0))
                     (let ((r (parser-feed! p bv at len)))
                       (when (and (eq? (parser-result-status r) 'paused)
                                  (< (parser-result-next r) len))
                         (parser-resume! p)
                         (loop (parser-result-next r)))))
                   (and marked (car pr))))
               strict-request-fixtures)))

(run-suite "flag-pins"
  (lambda ()
    ;; the connection-close and skip-body flags
    (test-eqv "F-CONNECTION-CLOSE = 1<<1" 2  F-CONNECTION-CLOSE)
    (test-eqv "F-SKIP-BODY = 1<<6"        64 F-SKIP-BODY)

    ;; the neighbours the connection layer reads alongside them
    (test-eqv "F-CONNECTION-KEEP-ALIVE" 1   F-CONNECTION-KEEP-ALIVE)
    (test-eqv "F-CONTENT-LENGTH"        32  F-CONTENT-LENGTH)
    (test-eqv "F-TRANSFER-ENCODING = 1<<9 (not 1<<8)" 512 F-TRANSFER-ENCODING)

    ;; method numbers the traces key on (oracle: llhttp method table)
    (test-eqv "GET is 1"     1 (httparse-method-number 'GET))
    (test-eqv "HEAD is 2"    2 (httparse-method-number 'HEAD))
    (test-eqv "CONNECT is 5" 5 (httparse-method-number 'CONNECT))

    ;; the parser's `upgrade` field (oracle: llhttp's recorded logs)
    (let ((logged (logged-upgrades)))
      (test-equal "the strict fixtures whose llhttp logs pause for an upgrade are nine"
                  '("request/connection.md#14" "request/connection.md#18" "request/connection.md#19"
                    "request/connection.md#20" "request/connection.md#21" "request/method.md#2"
                    "request/method.md#3" "request/method.md#4" "request/uri.md#9")
                  logged)
      (test-equal "the parser's upgrade field is 1 in exactly those, at on-headers-complete"
                  logged (upgrading-fixtures)))))
