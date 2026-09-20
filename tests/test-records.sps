#!r6rs
;;; (http-server request) and (http-server response): the pure records M0 fixes
;;; for the connection core to fill in M2/M3.  Construct, read back, and
;;; distinguish the two types.
(import (rnrs) (srfi :64) (testing)
        (http-server request) (http-server response))

(define (b s) (string->utf8 s))

(run-suite "records"
  (lambda ()
    ;; --- request ---
    (let* ((hs (list (cons (b "Host") (b "x"))))
           (req (make-request 'GET (b "/p") 1 1 hs 'the-body)))
      (test-eq    "method reads back"  'GET      (request-method req))
      (test-equal "target reads back"  (b "/p")  (request-target req))
      (test-eqv   "major reads back"   1         (request-http-major req))
      (test-eqv   "minor reads back"   1         (request-http-minor req))
      (test-equal "headers read back"  hs        (request-headers req))
      (test-eq    "body reads back"    'the-body (request-body req))
      (test-eq    "request? accepts"   'yes (if (request? req) 'yes 'no))
      (test-eq    "request? rejects a fixnum" 'no (if (request? 42) 'yes 'no)))

    ;; --- response ---
    (let ((res (make-response 200 #f (list (cons (b "Server") (b "chez"))) (b "hi"))))
      (test-eqv   "status reads back"  200       (response-status res))
      (test-eq    "absent reason"      'none     (or (response-reason res) 'none))
      (test-equal "body reads back"    (b "hi")  (response-body res))
      (test-eq    "response? accepts"  'yes (if (response? res) 'yes 'no))
      (test-eq    "records are distinct types" 'no (if (request? res) 'yes 'no)))

    ;; a present reason phrase is kept verbatim
    (let ((res (make-response 404 (b "Not Found") '() #f)))
      (test-equal "present reason kept" (b "Not Found") (response-reason res)))))
