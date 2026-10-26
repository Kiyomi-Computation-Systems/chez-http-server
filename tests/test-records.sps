#!r6rs
;;; (http-server request), (http-server response), (http-server switch) and
;;; (http-server transport): the pure records the connection core fills in.
;;; Construct, read back, and distinguish the types.  The switch is what a
;;; handler answers to take an upgrade; the transport is the record of verbs
;;; the taker is handed, whose arguments are checked before the verb is
;;; called, so a fake and the server's shell are handed the same shapes.  A
;;; transport made of seven procedures, without the abort, is still a
;;; transport, and refuses the abort.  A connection's addresses are an
;;; address, a string, and a port, from 0 to 65535 as a TCP port is (RFC
;;; 9293 §3.1), for each end, or #f where the server cannot say.  A
;;; request's version is two numbers from 0 to 255, as llhttp reads them
;;; (its http_major and http_minor are each a byte).
(import (rnrs) (srfi :64) (testing)
        (http-server request) (http-server response) (http-server span)
        (http-server switch) (http-server transport))

;; refused : (-> Any) -> (U 'refused 'accepted)
(define (refused thunk)
  (guard (e ((assertion-violation? e) 'refused)) (thunk) 'accepted))

;; refuser : (-> Any) -> (U Symbol 'accepted)
;; Who refused `thunk`: the who of the assertion violation it raised, so a
;; refusal by a primitive the procedure happens to call reads as that
;; primitive's, not the procedure's.
(define (refuser thunk)
  (guard (e ((assertion-violation? e) (if (who-condition? e) (condition-who e) 'anonymous)))
    (thunk)
    'accepted))

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
      (test-equal "the version's two numbers read back apart, at their bounds, 0 and 255, too"
                  '((0 255) (255 0) (1 0) (0 9))
                  (map (lambda (v)
                         (let ((r (make-request 'GET target (car v) (cadr v) hs #f)))
                           (list (request-http-major r) (request-http-minor r))))
                       '((0 255) (255 0) (1 0) (0 9))))
      (test-equal "make-request refuses a version number outside 0 to 255, or not an exact integer"
                  '(make-request make-request make-request make-request)
                  (map refuser
                       (list (lambda () (make-request 'GET target 256 1 hs #f))
                             (lambda () (make-request 'GET target 1 -1 hs #f))
                             (lambda () (make-request 'GET target 1.0 1 hs #f))
                             (lambda () (make-request 'GET target 1 'one hs #f)))))
      (test-equal "the version's accessors refuse something other than a request, each by its own name"
                  '(request-http-major request-http-minor)
                  (list (refuser (lambda () (request-http-major 'x)))
                        (refuser (lambda () (request-http-minor 'x)))))
      (test-equal "headers read back"  hs        (request-headers req))
      (test-equal "the header is Host: x" (list (b "Host") (b "x"))
                  (let ((h (car (request-headers req))))
                    (list (span->bytevector (car h)) (span->bytevector (cdr h)))))
      (test-eq    "a body announced reads back" #t (request-has-body? req))
      (test-eq    "and none announced"  'no
                  (if (request-has-body? (make-request 'GET target 1 1 hs #f)) 'yes 'no))
      (test-eq    "request? accepts"   'yes (if (request? req) 'yes 'no))
      (test-eq    "request? rejects a fixnum" 'no (if (request? 42) 'yes 'no))
      (test-eq    "a request made with no addresses holds no-addresses" no-addresses (request-addresses req))
      (let ((addresses (make-addresses "192.0.2.7" 54321 "198.51.100.1" 8080)))
        (test-eq "a request made with its connection's addresses holds them"
                 addresses (request-addresses (make-request 'GET target 1 1 hs #f addresses)))))

    ;; --- the addresses of a connection: each end's address and port ---
    (let ((a (make-addresses "192.0.2.7" 54321 "::1" 0)))
      (test-equal "addresses read back: the remote address and port, then the local"
                  '("192.0.2.7" 54321 "::1" 0)
                  (list (addresses-remote-address a) (addresses-remote-port a)
                        (addresses-local-address a) (addresses-local-port a)))
      (test-eq "addresses? accepts" 'yes (if (addresses? a) 'yes 'no))
      (test-eq "addresses? rejects a request's span" 'no (if (addresses? (make-span (b "x") 0 1)) 'yes 'no)))
    (test-equal "no-addresses holds #f for all four"
                '(#f #f #f #f)
                (list (addresses-remote-address no-addresses) (addresses-remote-port no-addresses)
                      (addresses-local-address no-addresses) (addresses-local-port no-addresses)))
    ;; A port is a port of an address: one given with none is not kept.
    (test-equal "an end with no address keeps no port; an address with no port keeps the address"
                '(#f #f "198.51.100.1" #f)
                (let ((a (make-addresses #f 54321 "198.51.100.1" #f)))
                  (list (addresses-remote-address a) (addresses-remote-port a)
                        (addresses-local-address a) (addresses-local-port a))))
    (test-equal "make-addresses refuses an address that is no string, and a port outside 0 to 65535 or not an exact integer"
                '(make-addresses make-addresses make-addresses make-addresses make-addresses)
                (map refuser
                     (list (lambda () (make-addresses 54321 #f #f #f))
                           (lambda () (make-addresses #f #f 'here #f))
                           (lambda () (make-addresses "192.0.2.7" 65536 #f #f))
                           (lambda () (make-addresses #f #f "::1" -1))
                           (lambda () (make-addresses "192.0.2.7" 80.0 #f #f)))))
    (test-equal "and takes either end at its bounds, 0 and 65535"
                '(0 65535)
                (let ((a (make-addresses "192.0.2.7" 0 "::1" 65535)))
                  (list (addresses-remote-port a) (addresses-local-port a))))

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
