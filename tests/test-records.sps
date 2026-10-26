#!r6rs
;;; (http-server request), (http-server response), (http-server switch) and
;;; (http-server transport): the pure records the connection core fills in.
;;; Construct, read back, and distinguish the types.  The switch is what a
;;; handler answers to take an upgrade; the transport is the record of verbs
;;; the taker is handed, whose arguments are checked before the verb is
;;; called, so a fake and the server's shell are handed the same shapes.  A
;;; transport made of seven procedures, without the abort, is still a
;;; transport, and refuses the abort.
(import (rnrs) (srfi :64) (testing)
        (http-server request) (http-server response) (http-server span)
        (http-server switch) (http-server transport))

;; refused : (-> Any) -> (U 'refused 'accepted)
(define (refused thunk)
  (guard (e ((assertion-violation? e) 'refused)) (thunk) 'accepted))

;; recording : -> (values Transport (-> (Listof Datum)))
;; A transport whose every verb is recorded, newest last, as its name and
;; the arguments it was handed.
(define (recording)
  (let* ((seen '())
         (note (lambda (name) (lambda args (set! seen (cons (cons name args) seen))))))
    (values (make-transport (note 'write) (note 'read-start) (note 'read-stop) (note 'close)
                            (note 'deadline) (note 'on-drain) (note 'on-close) (note 'abort))
            (lambda () (reverse seen)))))

(define (b s) (string->utf8 s))

(run-suite "records"
  (lambda ()
    ;; --- request: spans of one delivery, as the core builds it ---
    (let* ((wire (b "GET /p HTTP/1.1\r\nHost: x\r\n\r\n"))
           (target (make-span wire 4 6))
           (hs (list (cons (make-span wire 17 21) (make-span wire 23 24))))
           (req (make-request 'GET target 1 1 hs #t)))
      (test-eq    "method reads back"  'GET      (request-method req))
      (test-eq    "target reads back"  target    (request-target req))
      (test-equal "the target is /p"   (b "/p")  (span->bytevector (request-target req)))
      (test-eqv   "major reads back"   1         (request-http-major req))
      (test-eqv   "minor reads back"   1         (request-http-minor req))
      (test-equal "headers read back"  hs        (request-headers req))
      (test-equal "the header is Host: x" (list (b "Host") (b "x"))
                  (let ((h (car (request-headers req))))
                    (list (span->bytevector (car h)) (span->bytevector (cdr h)))))
      (test-eq    "a body announced reads back" #t (request-has-body? req))
      (test-eq    "and none announced"  'no
                  (if (request-has-body? (make-request 'GET target 1 1 hs #f)) 'yes 'no))
      (test-eq    "request? accepts"   'yes (if (request? req) 'yes 'no))
      (test-eq    "request? rejects a fixnum" 'no (if (request? 42) 'yes 'no)))

    ;; --- request: the procedures told how its response ended ---
    ;; Each registered procedure records its name and what it was told.
    (let* ((heard '())
           (hears (lambda (name) (lambda (how) (set! heard (cons (list name how) heard)))))
           (fresh (lambda () (make-request 'GET (make-span (b "/") 0 1) 1 1 '() #f))))
      (let ((req (fresh)))
        (request-on-done! req (hears 'first))
        (request-on-done! req (hears 'second))
        (test-equal "a registration calls nothing while the response is under way" '() heard)
        (for-each (lambda (p) (p 'written)) (request-done! req 'written))
        (test-equal "marked done, the request hands back its procedures, newest first"
                    '((first written) (second written)) heard)
        (test-equal "and only once: marked done again, it hands back none" '()
                    (request-done! req 'failed))
        (set! heard '())
        (request-on-done! req (hears 'late))
        (test-equal "one registered once it is done is called at once, with how it ended"
                    '((late written)) heard))
      (let* ((req (fresh))
             (handed (request-done! req 'client-closed)))
        (set! heard '())
        (request-on-done! req (hears 'late))
        (test-equal "a request with none registered hands back none, and one registered after is called at once, with how it ended"
                    '(() ((late client-closed))) (list handed heard)))
      (test-eq "request-on-done! refuses what is not a procedure" 'refused
               (refused (lambda () (request-on-done! (fresh) 'not-a-procedure))))
      (test-eq "request-done! refuses an ending that is not written, client-closed or failed" 'refused
               (refused (lambda () (request-done! (fresh) 'finished)))))

    ;; --- response ---
    (let ((res (make-response 200 #f (list (cons (b "Server") (b "chez"))) (b "hi"))))
      (test-eqv   "status reads back"  200       (response-status res))
      (test-eq    "absent reason"      'none     (or (response-reason res) 'none))
      (test-equal "body reads back"    (b "hi")  (response-body res))
      (test-eq    "response? accepts"  'yes (if (response? res) 'yes 'no))
      (test-eq    "records are distinct types" 'no (if (request? res) 'yes 'no)))

    ;; a present reason phrase is kept verbatim
    (let ((res (make-response 404 (b "Not Found") '() #f)))
      (test-equal "present reason kept" (b "Not Found") (response-reason res)))

    ;; --- a sized body: a producer with its length declared ---
    (let* ((p (lambda () (eof-object)))
           (sb (sized-body 5 p)))
      (test-equal "a sized body's length and producer read back" (list 5 p)
                  (list (sized-body-length sb) (sized-body-producer sb)))
      (test-equal "sized-body? accepts one, and neither a producer nor a bytevector" '(yes no no)
                  (map (lambda (x) (if (sized-body? x) 'yes 'no)) (list sb p (b "hello"))))
      (test-eq "a response takes one as its body" sb (response-body (make-response 200 #f '() sb)))
      ;; Its length is a count of bytes, a fixnum, as the framing decision
      ;; takes one, 0 among them; its producer a procedure.
      (test-equal "a length that is no fixnum count of bytes, or a producer that is no procedure, is refused; 0 bytes is a length"
                  '(refused refused refused refused refused refused accepted)
                  (list (refused (lambda () (sized-body -1 p)))
                        (refused (lambda () (sized-body 5.0 p)))
                        (refused (lambda () (sized-body 5/2 p)))
                        (refused (lambda () (sized-body (+ (greatest-fixnum) 1) p)))
                        (refused (lambda () (sized-body "5" p)))
                        (refused (lambda () (sized-body 5 (b "hello"))))
                        (refused (lambda () (sized-body 0 p))))))

    ;; --- the switch a handler answers to take an upgrade ---
    (let* ((take-over (lambda (transport retained) 'taken))
           (hs (list (cons (b "Upgrade") (b "websocket"))))
           (sw (switch-protocols hs take-over)))
      (test-equal "a switch's headers read back" hs (switch-headers sw))
      (test-eq "its take-over reads back" take-over (switch-take-over sw))
      (test-eq "switch? accepts" 'yes (if (switch? sw) 'yes 'no))
      (test-eq "a switch is no response" 'no (if (response? sw) 'yes 'no))
      (test-eq "a response is no switch" 'no
               (if (switch? (make-response 101 #f hs #f)) 'yes 'no)))

    ;; --- the transport handed to the taker ---
    ;; Each verb hands its procedure the arguments in one shape: a write
    ;; its range, the whole bytevector by default, and its callback or #f;
    ;; a deadline its milliseconds and its callback, or #f twice to disarm.
    (let-values (((t seen) (recording)))
      (let ((bv (b "hello")) (done (lambda (err) err)) (on-bytes (lambda (bv from to) #t))
            (on-end (lambda (why) why)) (passed (lambda () 'passed)) (drain (lambda () 'drain))
            (closed (lambda () 'closed)))
        (transport-write! t bv)
        (transport-write! t bv 1 3)
        (transport-write! t bv 1 3 done)
        (transport-read-start! t on-bytes on-end)
        (transport-read-stop! t)
        (transport-deadline! t 250 passed)
        (transport-deadline! t #f)
        (transport-on-drain! t drain)
        (transport-on-close! t closed)
        (transport-close! t)
        (transport-abort! t)
        (test-equal "each verb calls its procedure, the arguments in one shape"
                    (list (list 'write bv 0 5 #f) (list 'write bv 1 3 #f) (list 'write bv 1 3 done)
                          (list 'read-start on-bytes on-end) (list 'read-stop)
                          (list 'deadline 250 passed) (list 'deadline #f #f)
                          (list 'on-drain drain) (list 'on-close closed) (list 'close) (list 'abort))
                    (seen))
        (test-eq "transport? accepts" 'yes (if (transport? t) 'yes 'no))
        (test-eq "transport? rejects a switch" 'no
                 (if (transport? (switch-protocols '() (lambda (t r) #f))) 'yes 'no))))
    ;; What a verb is handed is checked before its procedure is called, so
    ;; a taker's mistake is the same refusal on a fake as on the server.  A
    ;; write of no bytes is refused: chez-libuv would complete an empty
    ;; span a turn late, and a close cancel it.
    (let-values (((t seen) (recording)))
      (let ((bv (b "hello")) (cb (lambda () #t)))
        (test-equal "a write of no bytes, outside its bytevector, of no bytevector, or with a callback that is no procedure is refused"
                    '(refused refused refused refused refused refused)
                    (list (refused (lambda () (transport-write! t bv 2 2)))
                          (refused (lambda () (transport-write! t bv 3 6)))
                          (refused (lambda () (transport-write! t bv -1 2)))
                          (refused (lambda () (transport-write! t (make-bytevector 0))))
                          (refused (lambda () (transport-write! t "hello")))
                          (refused (lambda () (transport-write! t bv 0 5 'done)))))
        (test-equal "reading is started with two procedures, or refused"
                    '(refused refused)
                    (list (refused (lambda () (transport-read-start! t cb #f)))
                          (refused (lambda () (transport-read-start! t 'data cb)))))
        (test-equal "a deadline is a count of milliseconds with a procedure, or #f alone, or refused"
                    '(refused refused refused refused)
                    (list (refused (lambda () (transport-deadline! t -1 cb)))
                          (refused (lambda () (transport-deadline! t 2.5 cb)))
                          (refused (lambda () (transport-deadline! t 250)))
                          (refused (lambda () (transport-deadline! t #f cb)))))
        (test-equal "the drain's and the close's calls are procedures, or refused"
                    '(refused refused)
                    (list (refused (lambda () (transport-on-drain! t 'bye)))
                          (refused (lambda () (transport-on-close! t #f)))))
        (test-equal "and no refused verb reached its procedure" '() (seen))))
    (test-equal "a transport is made of seven procedures, or eight, or refused" '(refused refused)
                (list (refused (lambda () (make-transport car car car car car car 'not-a-procedure)))
                      (refused (lambda () (make-transport car car car car car car car 'not-a-procedure)))))
    ;; A transport made of seven procedures, without an abort, is still a
    ;; transport, and refuses the abort it was made without, naming it,
    ;; before any of its procedures is called.
    (let* ((called '())
           (t7 (apply make-transport
                      (map (lambda (name) (lambda args (set! called (cons name called))))
                           '(write read-start read-stop close deadline on-drain on-close)))))
      (test-equal "a transport made of seven procedures is one, and refuses transport-abort!, naming it, calling nothing"
                  '(yes transport-abort! ())
                  (list (if (transport? t7) 'yes 'no)
                        (guard (e ((and (assertion-violation? e) (who-condition? e)) (condition-who e)))
                          (transport-abort! t7)
                          'aborted)
                        called)))))
