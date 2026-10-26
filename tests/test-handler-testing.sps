#!r6rs
;;; (http-server testing): a handler that waits, run against scripted
;;; requests, with no socket and no real time.
;;;
;;; Each row hosts a handler that waits, sends it requests as bytes, and reads
;;; what the client read back, parsed:
;;;   - a sleep-ms answers once the clock has gone its time on, not before,
;;;     and the Date field reads the host's clock;
;;;   - a with-deadline whose time passes raises &deadline-passed in the wait;
;;;   - a resolve waits for the test's answer: the addresses, or the reason
;;;     the name does not resolve;
;;;   - a client that closes or resets while the handler waits: the wait
;;;     raises &client-closed, nothing is answered, and the connection
;;;     closes;
;;;   - a body sent in pieces, some later, reaches the reader piece by piece,
;;;     and one its handler pulls is read through a port;
;;;   - two requests in one send are answered in order, a malformed one after
;;;     them 400, then the connection closes;
;;;   - a raise is answered 500 and logged `handler-failed`, a resume after
;;;     its deadline logged `late-resume await`, and a told close not at all;
;;;   - a handler left waiting is reported, and one that answered is not;
;;;   - a field reads with its name as sent and its value unpadded;
;;;   - a HEAD's response has its length and no body, a 100 Continue is a
;;;     response of its own that answers no request, the server reads at
;;;     most its read buffer at a time, a chunked body still arriving is
;;;     read as far as it goes, a close-delimited one is completed by the
;;;     close, the bytes after a 101 are the taker's, and the idle deadline
;;;     fires as the clock passes it;
;;;   - the settings come from the environment procedure, as `serve` reads
;;;     them, a host that is not an IP literal not refused;
;;;   - one scheduler and one waits for every connection: what is woken
;;;     first runs first, and sleeps due together end in the order they
;;;     slept, whatever connection they are on;
;;;   - the fake shell's dispatch cap is each event's, so one connection can
;;;     run past 100,000 dispatches;
;;;   - a lookup a deadline ends answers later as cancelled, logged
;;;     `late-resume resolve`, and an answer goes to the oldest lookup of a
;;;     name;
;;;   - a client that resets reads nothing written after it, and the server
;;;     reads the reset after what was sent before it;
;;;   - a taker's raise is logged `taker-failed`;
;;;   - a procedure told the response's end that raises is logged
;;;     `on-done-failed`, the others still told, newest first, in the order
;;;     it happened among the other entries;
;;;   - a run that never goes quiet raises, never hangs;
;;;   - a resume the test calls runs at an advance of 0 ms, a host call from
;;;     the host's own code is refused, and so are malformed arguments;
;;;   - examples/long-poll.sps's handler: a wait a send on another
;;;     connection wakes, its deadline, and a client that leaves.
;;;
;;; Oracles: docs/waiting.md (what each wait does, and what is logged);
;;; docs/handlers.md (a raise is a 500, logged `handler-failed`; the
;;; procedures `request-on-done!` registers are told newest first, and one
;;; that raises is logged `on-done-failed`, the others still told);
;;; docs/responses.md (what the server adds and answers itself, and what a
;;; HEAD gets, and how a producer's body is framed); docs/upgrades.md (the
;;; stream after a 101 is the taker's); docs/configuration.md (each setting
;;; and its default); RFC 9112 §9.3.2 (responses in the order of their
;;; requests); RFC 9110 §5.5 (a field's value has no spaces around it),
;;; §5.6.7 (the Date field's format: Unix second 1 is Thu, 01 Jan 1970
;;; 00:00:01 GMT) and §15 (each status's reason phrase); the request's own
;;; bytes (its head is 50 bytes, so reads of 8 end at 56 and 60); the core's
;;; transition on a read error (logged `read-error`, with the errno, here
;;; ECONNRESET, which (http-server testing) gives for a reset);
;;; (http-server private scheduler)'s drain (what is ready runs in the order
;;; it was made ready) and (http-server private waits)' contract (sleeps due
;;; together end in the order they slept; a cancelled lookup still answers,
;;; as chez-libuv's docs/dns.md says, EAI_CANCELED, and a resume after its
;;; wait is over is logged `late-resume`); the fake shell's own suite, which
;;; holds its dispatch cap at 100,000 an event; docs/upgrades.md (a taker's
;;; raise is logged `taker-failed`); and examples/README.org and
;;; docs/waiting.md for long-poll.sps.
(import (rnrs) (rnrs eval) (srfi :64) (testing)
        (http-server) (http-server testing)
        (only (http-server private waits) body-input-port))

(define (b s) (string->utf8 s))

;; copy : Bytevector Nat Nat -> Bytevector — bv[start, end), copied.
(define (copy bv start end)
  (let ((o (make-bytevector (- end start)))) (bytevector-copy! bv start o 0 (- end start)) o))

;; append-bytes : (Listof Bytevector) -> Bytevector
(define (append-bytes bvs)
  (let ((o (make-bytevector (fold-left (lambda (n bv) (+ n (bytevector-length bv))) 0 bvs))))
    (fold-left (lambda (at bv) (bytevector-copy! bv 0 o at (bytevector-length bv)) (+ at (bytevector-length bv)))
               0 bvs)
    o))

;; seen : TestClient -> (Listof (List Nat String))
;; Each response the client read: its status and its body, as text.
(define (seen c)
  (map (lambda (r) (list (test-response-status r) (utf8->string (test-response-body r))))
       (test-client-responses c)))

;; field : TestResponse String -> (U String #f) — the field's value, as text.
(define (field r name)
  (let ((v (test-response-header r name))) (and v (utf8->string v))))

;; whats : TestHost -> (Listof Symbol) — what the server logged, in order.
(define (whats host) (map car (test-host-log host)))

;; refused : Symbol (-> Any) -> (U 'refused 'accepted Any)
;; Whether `thunk` is refused by `who`: an assertion violation it names.
;; Any other raise is answered as it is.
(define (refused who thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (eq? (condition-who e) who)) 'refused))
    (thunk)
    'accepted))

(define (get path) (b (string-append "GET " path " HTTP/1.1\r\nHost: x\r\n\r\n")))

;; text : Nat String -> Response
(define (text status s) (make-response status #f '() (b s)))

;; never : -> Any — a wait no one ends.
(define (never) (await (lambda (resume) #f)))

;; program-handler : String -> (Request -> Answer)
;; The handler the program at `path` gives `serve`: its body run, under its
;; own imports, with `serve` bound to a procedure that keeps the handler.
(define (program-handler path)
  (let* ((forms (call-with-input-file path
                  (lambda (port)
                    (let loop ((acc '()))
                      (let ((d (read port))) (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
         (kept #f))
    (unless (and (pair? forms) (pair? (car forms)) (eq? (caar forms) 'import))
      (provenance-failure (string-append path " does not begin with its imports")))
    ((eval `(lambda (serve) ,@(cdr forms)) (apply environment (cdar forms)))
     (lambda (handler . lookup) (set! kept handler)))
    (unless (procedure? kept)
      (provenance-failure (string-append path " gave serve no handler")))
    kept))

(run-suite "handler-testing"
  (lambda ()
    ;; --- the clock: a sleep, and the Date field -----------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting (lambda () (sleep-ms 1000) (text 200 "slept"))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((before (list (seen c) (test-client-waiting? c))))
        (test-host-advance! host 999)
        (let ((at-999 (seen c)))
          (test-host-advance! host 1)
          (test-equal "a sleep-ms of 1000 ms answers once the clock has gone 1000 ms on, and not at 999"
                      '((() #t) () 1000 ((200 "slept")) #f)
                      (list before at-999 (test-host-now host) (seen c) (test-client-waiting? c)))
          (test-equal "its response: the usual reason, its length, the Date of the clock's second, and the connection kept"
                      '(("OK") ("5") ("Thu, 01 Jan 1970 00:00:01 GMT") #f)
                      (list (map (lambda (r) (utf8->string (test-response-reason r))) (test-client-responses c))
                            (map (lambda (r) (field r "content-length")) (test-client-responses c))
                            (map (lambda (r) (field r "DATE")) (test-client-responses c))
                            (test-client-connection-closed? c)))
          (test-equal "the raw bytes beside it: the client's bytes are the response's, from its status line to its body"
                      '("HTTP/1.1 200 OK\r\n" "\r\n\r\nslept" complete all-of-them)
                      (let* ((r (test-client-responses c))
                             (raw (if (pair? r) (test-response-bytes (car r)) (make-bytevector 0)))
                             (n (bytevector-length raw)))
                        (list (utf8->string (copy raw 0 (min n 17)))
                              (utf8->string (copy raw (max 0 (- n 9)) n))
                              (if (and (pair? r) (test-response-complete? (car r))) 'complete 'incomplete)
                              (if (equal? raw (test-client-received c)) 'all-of-them 'not-all)))))))

    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting (lambda () (make-response 200 #f (list (cons (b "X-Pad") (b " padded "))) (b "ok")))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (test-equal "a field reads as its name was sent and its value without the spaces around it"
                  '(("padded") ((("X-Pad" . "padded"))))
                  (list (map (lambda (r) (field r "x-pad")) (test-client-responses c))
                        (map (lambda (r)
                               (map (lambda (f) (cons (utf8->string (car f)) (utf8->string (cdr f))))
                                    (filter (lambda (f) (equal? (car f) (b "X-Pad"))) (test-response-headers r))))
                             (test-client-responses c)))))

    ;; --- with-deadline --------------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (guard (e ((deadline-passed? e) (text 504 "late")))
                         (with-deadline 500 never)))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (test-host-advance! host 499)
      (let ((at-499 (seen c)))
        (test-host-advance! host 1)
        (test-equal "a with-deadline of 500 ms raises &deadline-passed in its wait at 500, not at 499"
                    '(() ((504 "late")) ("Gateway Timeout"))
                    (list at-499 (seen c)
                          (map (lambda (r) (utf8->string (test-response-reason r))) (test-client-responses c))))))

    ;; --- resolve ----------------------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (let ((as (resolve "db.example")))
                         (text 200 (fold-left (lambda (acc a) (if (string=? acc "") a (string-append acc " " a)))
                                              "" as))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((asked (list (test-host-lookups host) (seen c) (test-client-waiting? c))))
        (test-host-answer! host "db.example" '("192.0.2.7" "2001:db8::7"))
        (test-equal "a resolve waits for the test's answer, and gets its addresses, in order"
                    '((("db.example") () #t) () ((200 "192.0.2.7 2001:db8::7")))
                    (list asked (test-host-lookups host) (seen c)))))
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (guard (e ((resolve-error? e)
                                  (text 502 (symbol->string (resolve-error-reason e)))))
                         (resolve "nowhere.example")
                         (text 200 "resolved")))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((asked (test-host-lookups host)))
        (test-host-answer! host "nowhere.example" 'EAI_NONAME)
        (test-equal "a resolve answered with a reason raises &resolve-error, with that reason"
                    '(("nowhere.example") ((502 "EAI_NONAME")))
                    (list asked (seen c))))
      (test-equal "answering a name no lookup asks for is refused"
                  'refused
                  (refused 'test-host-answer! (lambda () (test-host-answer! host "nowhere.example" '("192.0.2.1"))))))

    ;; --- the client leaves while the handler waits -------------------------------
    (let* ((told 0)
           (handler (lambda (request)
                      (awaiting
                       (lambda ()
                         (guard (e ((client-closed? e) (set! told (+ told 1)) (raise e)))
                           (never))))))
           (host (make-test-host handler))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((before (list told (test-client-connection-closed? c))))
        (test-client-close! c)
        (test-equal "a client that closes while the handler waits: the wait raises &client-closed once, nothing is answered, nothing is logged, and the connection closes"
                    '((0 #f) 1 () () #t #f)
                    (list before told (seen c) (test-host-log host) (test-client-connection-closed? c)
                          (test-client-waiting? c))))
      (test-equal "and the client that has closed sends no more"
                  'refused
                  (refused 'test-client-send! (lambda () (test-client-send! c (get "/again"))))))
    (let* ((told 0)
           (host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (guard (e ((client-closed? e) (set! told (+ told 1)) (raise e)))
                         (never)))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (test-client-reset! c)
      (test-equal "a client that resets: the wait raises &client-closed, nothing is answered, the read error is logged, and the connection closes"
                  '(1 () ((read-error ECONNRESET)) #t)
                  (list told (seen c) (test-host-log host) (test-client-connection-closed? c))))

    ;; --- a body in pieces, some later ------------------------------------------
    (let* ((pieces '())
           (host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (sleep-ms 10)
                       (read-body (lambda (bv start end) (set! pieces (cons (utf8->string (copy bv start end)) pieces)))
                                  (lambda ()
                                    (text 200 (fold-left string-append "" (reverse pieces))))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello"))
      (test-host-advance! host 10)
      (test-host-advance! host 50)
      (let ((between (list (reverse pieces) (seen c))))
        (test-client-send! c (b "world"))
        (test-equal "a body sent in two pieces, the second 50 ms later, reaches the reader piece by piece, and is answered at its end"
                    '((("hello") ()) ("hello" "world") ((200 "helloworld")))
                    (list between (reverse pieces) (seen c)))))

    ;; --- a body pulled ------------------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (make-response 200 #f '() (get-bytevector-all (body-input-port))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello"))
      (let ((between (seen c)))
        (test-client-send! c (b "world"))
        (test-equal "a body its handler pulls through a port, sent in two pieces: nothing answered until its end, then the body"
                    '(() ((200 "helloworld")) ())
                    (list between (seen c) (test-host-log host)))))

    ;; --- pipelined, then malformed ------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (if (string=? (request-path request) "/a")
                        (awaiting (lambda () (sleep-ms 10) (text 200 "a")))
                        (text 200 "b")))))
           (c (test-host-connect! host)))
      (test-client-send! c (append-bytes (list (get "/a") (get "/b") (b "GET / HTTP/1.1\r\nHost x\r\n\r\n"))))
      (let ((before (seen c)))
        (test-host-advance! host 10)
        (let ((r (test-client-responses c)))
          (test-equal "two requests in one send are answered in order, the waiting one first; the malformed one after them is answered 400, with no body"
                      '(() ((200 "a") (200 "b") (400 "")) ("OK" "OK" "Bad Request"))
                      (list before (seen c) (map (lambda (r) (utf8->string (test-response-reason r))) r)))
          (test-equal "and the connection closes after the 400, which says so"
                      '("close" #t)
                      (list (and (= (length r) 3) (field (caddr r) "connection")) (test-client-connection-closed? c)))
          (test-equal "the client's bytes are the three responses', in order"
                      '(3 #t)
                      (list (length r) (equal? (test-client-received c) (append-bytes (map test-response-bytes r))))))))

    ;; --- what the server logs -----------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request) (awaiting (lambda () (sleep-ms 5) (raise 'boom))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((before (test-host-log host)))
        (test-host-advance! host 5)
        (test-equal "a handler that raises as it waits is answered 500, logged handler-failed with what it raised, and the connection closes"
                    '(() ((500 "")) ((handler-failed boom)) #t)
                    (list before (seen c) (test-host-log host) (test-client-connection-closed? c)))))
    (let* ((kept #f)
           (host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (guard (e ((deadline-passed? e) (make-response 504 #f '() #f)))
                         (with-deadline 100 (lambda () (await (lambda (resume) (set! kept resume)))))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (test-host-advance! host 100)
      (let ((before (test-host-log host)))
        (when (procedure? kept) (kept 'too-late))
        (test-equal "a resume called after its deadline wakes nothing, and is logged late-resume await"
                    '(() ((504 "")) ((late-resume await)))
                    (list before (seen c) (test-host-log host)))))

    ;; --- a run that ends with a handler waiting -----------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (if (string=? (request-path request) "/quick")
                        (awaiting (lambda () (text 200 "quick")))
                        (awaiting never)))))
           (stuck (test-host-connect! host))
           (quick (test-host-connect! host)))
      (test-client-send! stuck (get "/stuck"))
      (test-client-send! quick (get "/quick"))
      (test-host-advance! host 3600000)
      (test-equal "a handler still waiting an hour on is reported, and one that answered is not"
                  '(() #t ((200 "quick")) #f 1)
                  (list (seen stuck) (test-client-waiting? stuck) (seen quick) (test-client-waiting? quick)
                        (length (test-host-waiting host))))
      (test-eq "the one reported is the client whose handler waits" stuck
               (let ((w (test-host-waiting host))) (and (pair? w) (car w)))))

    ;; --- framing the client reads --------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request) (awaiting (lambda () (sleep-ms 1) (text 200 "hello"))))))
           (c (test-host-connect! host)))
      (test-client-send! c (append-bytes (list (b "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n") (get "/"))))
      (test-host-advance! host 2)
      (test-equal "a HEAD's response has its body's length and no body, and the GET after it is read whole"
                  '(((200 "") (200 "hello")) ("5" "5"))
                  (list (seen c) (map (lambda (r) (field r "content-length")) (test-client-responses c)))))
    (let* ((host (make-test-host
                  (lambda (request)
                    (if (eq? (request-method request) 'HEAD)
                        (text 200 "hello")
                        (awaiting (lambda () (sleep-ms 1) (read-whole-body (lambda (body) (make-response 200 #f '() body)))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n"))
      (test-host-advance! host 1)
      (let ((interim (map test-response-status (test-client-responses c))))
        (test-client-send! c (append-bytes (list (b "hi") (b "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"))))
        (test-equal "a 100 Continue is a response of its own, before the final one, and answers no request of its own: the HEAD after is still a HEAD's"
                    '((100) ((100 "") (200 "hi") (200 "")) "5")
                    (list interim (seen c)
                          (let ((r (test-client-responses c))) (and (= (length r) 3) (field (caddr r) "content-length")))))))
    (let* ((pieces '())
           (host (make-test-host
                  (lambda (request)
                    (awaiting
                     (lambda ()
                       (sleep-ms 1)
                       (read-body (lambda (bv start end) (set! pieces (cons (utf8->string (copy bv start end)) pieces)))
                                  (lambda () (text 200 "read"))))))
                  (lambda (name) (and (string=? name "CHEZ_HTTP_READ_BUFFER_SIZE") "8"))))
           (c (test-host-connect! host)))
      ;; The head is 50 bytes, so reads of 8 end at 56 and 60: the body,
      ;; bytes 50 to 60, comes as its first 6 bytes and its last 4.
      (test-client-send! c (b "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhelloworld"))
      (test-host-advance! host 1)
      (test-equal "the server reads at most its read buffer at a time: with CHEZ_HTTP_READ_BUFFER_SIZE=8, the body's pieces end where those reads do"
                  '(("hellow" "orld") ((200 "read")))
                  (list (reverse pieces) (seen c))))
    (let* ((producer (lambda (parts)
                       (lambda ()
                         (if (null? parts)
                             (eof-object)
                             (let ((part (car parts)))
                               (set! parts (cdr parts))
                               (when (string=? part "b") (sleep-ms 10))
                               (b part))))))
           (host (make-test-host
                  (lambda (request)
                    (awaiting (lambda () (make-response 200 #f '() (producer (list "a" "b"))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((partial (map (lambda (r) (list (utf8->string (test-response-body r)) (test-response-complete? r)))
                          (test-client-responses c))))
        (test-host-advance! host 10)
        (test-equal "a chunked body whose producer waits between pieces is read as far as it goes, not complete, and complete at its end"
                    '((("a" #f)) (("ab" #t)) ("chunked") #f)
                    (list partial
                          (map (lambda (r) (list (utf8->string (test-response-body r)) (test-response-complete? r)))
                               (test-client-responses c))
                          (map (lambda (r) (field r "transfer-encoding")) (test-client-responses c))
                          (test-client-connection-closed? c))))
      (let* ((host10 (make-test-host
                      (lambda (request)
                        (awaiting (lambda () (sleep-ms 1) (make-response 200 #f '() (producer (list "ab" "c"))))))))
             (c10 (test-host-connect! host10)))
        (test-client-send! c10 (b "GET / HTTP/1.0\r\n\r\n"))
        (test-host-advance! host10 1)
        (test-host-advance! host10 10)
        (test-equal "to HTTP/1.0, a producer's body has no length, the connection closes after it, and the close completes it"
                    '(((200 "abc")) (#f) (#f) (#t) #t)
                    (list (seen c10)
                          (map (lambda (r) (field r "content-length")) (test-client-responses c10))
                          (map (lambda (r) (field r "transfer-encoding")) (test-client-responses c10))
                          (map test-response-complete? (test-client-responses c10))
                          (test-client-connection-closed? c10)))))
    (let* ((read '())
           (host (make-test-host
                  (lambda (request)
                    (switch-protocols
                     (list (cons (b "Upgrade") (b "echo")))
                     (lambda (t retained)
                       (transport-read-start! t
                                              (lambda (bv start end)
                                                (set! read (cons (utf8->string (copy bv start end)) read))
                                                (transport-write! t (copy bv start end)))
                                              (lambda (why) (transport-close! t))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "GET /echo HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\n"))
      (test-equal "a handler that switches protocols: its 101 is read, with nothing sent after the request"
                  '(101)
                  (map test-response-status (test-client-responses c)))
      (test-client-send! c (b "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
      (let* ((all (test-client-received c))
             (n (bytevector-length all))
             (echoed (b "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")))
        (test-equal "a handler that switches protocols: the 101 is the last response read, and after it the taker reads what the client sends and writes back, bytes the client reads but no response"
                    '((101) ("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                    (list (map test-response-status (test-client-responses c))
                          (reverse read)
                          (utf8->string (copy all (max 0 (- n (bytevector-length echoed))) n))))))
    (let* ((host (make-test-host (lambda (request) (awaiting (lambda () (sleep-ms 10) (text 200 "ok"))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (test-host-advance! host 75009)
      (let ((open (test-client-connection-closed? c)))
        (test-host-advance! host 1)
        (test-equal "the idle deadline, 75 s from the response at 10 ms, closes the connection at 75010 ms, not before"
                    '(((200 "ok")) #f #t)
                    (list (seen c) open (test-client-connection-closed? c)))))

    ;; --- settings ---------------------------------------------------------------
    (let* ((handler (lambda (request)
                      (awaiting (lambda () (sleep-ms 1) (read-whole-body (lambda (body) (text 200 "read")))))))
           (host (make-test-host handler (lambda (name) (and (string=? name "CHEZ_HTTP_MAX_BODY_BYTES") "4"))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
      (test-host-advance! host 1)
      (test-equal "the settings come from the environment procedure: a 5-byte body over CHEZ_HTTP_MAX_BODY_BYTES=4 is answered 413"
                  '((413 ""))
                  (seen c))
      (test-equal "a malformed setting raises &http-server-config-error, as serve's settings do before it listens: a limit, or the port"
                  '(config-error config-error)
                  (map (lambda (setting)
                         (guard (e ((http-server-config-error? e) 'config-error) (#t 'other))
                           (make-test-host handler (lambda (name) (and (string=? name (car setting)) (cdr setting))))
                           'accepted))
                       '(("CHEZ_HTTP_MAX_BODY_BYTES" . "lots") ("CHEZ_HTTP_PORT" . "http"))))
      (test-equal "a CHEZ_HTTP_HOST that is not an IP literal is not refused: serve refuses it only at its bind"
                  'accepted
                  (guard (e ((http-server-config-error? e) 'config-error) (#t 'other))
                    (make-test-host handler (lambda (name) (and (string=? name "CHEZ_HTTP_HOST") "example.com")))
                    'accepted)))

    ;; --- one scheduler and one clock for every connection ----------------------
    (let* ((ran '())
           (resumes '())
           (host (make-test-host
                  (lambda (request)
                    (let* ((path (request-path request)) (name (substring path 1 2)))
                      (if (string=? path "/wake")
                          (begin
                            (for-each (lambda (n) ((cdr (assoc n resumes)) #t)) '("b" "a"))
                            (text 200 "woke"))
                          (awaiting
                           (lambda ()
                             (await (lambda (resume) (set! resumes (cons (cons name resume) resumes))))
                             (set! ran (cons name ran))
                             (text 200 path))))))))
           (a (test-host-connect! host))
           (bc (test-host-connect! host))
           (waker (test-host-connect! host)))
      (test-client-send! a (get "/a"))
      (test-client-send! bc (get "/b"))
      (test-client-send! waker (get "/wake"))
      (test-equal "waiters on two connections run in the order they were woken, the later connection's first, as one scheduler runs what is ready"
                  '(("b" "a") ((200 "/a")) ((200 "/b")) ((200 "woke")))
                  (list (reverse ran) (seen a) (seen bc) (seen waker))))
    (let* ((ran '())
           (host (make-test-host
                  (lambda (request)
                    (awaiting (lambda ()
                                (sleep-ms 100)
                                (set! ran (cons (request-path request) ran))
                                (text 200 "slept"))))))
           (first (test-host-connect! host))
           (second (test-host-connect! host)))
      (test-client-send! second (get "/second"))
      (test-client-send! first (get "/first"))
      (test-host-advance! host 100)
      (test-equal "two sleeps due at one instant, on two connections, end in the order they slept, not the order the connections were made"
                  '("/second" "/first")
                  (reverse ran)))

    ;; --- the dispatch cap is each event's ---------------------------------------
    (let* ((calls 0)
           (host (make-test-host (lambda (request) (set! calls (+ calls 1)) (text 200 "ok"))))
           (c (test-host-connect! host))
           (batch (append-bytes (let loop ((n 0) (acc '())) (if (= n 250) acc (loop (+ n 1) (cons (get "/") acc)))))))
      (let ((outcome (guard (e ((assertion-violation? e) 'cap-reached))
                       (let loop ((n 0)) (when (< n 200) (test-client-send! c batch) (loop (+ n 1))))
                       'served)))
        (test-equal "one connection runs past 100,000 dispatches in all, each event well within the cap: 50,000 requests, all answered"
                    '(served 50000 () #f)
                    (list outcome calls (test-host-log host) (test-client-connection-closed? c)))))

    ;; --- a lookup a deadline ends ------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting (lambda ()
                                (guard (e ((deadline-passed? e) (text 504 "late")))
                                  (with-deadline 100 (lambda () (resolve "x") (text 200 "resolved")))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (let ((asked (test-host-lookups host)))
        (test-host-advance! host 100)
        (test-equal "a lookup a deadline ends is cancelled, and answers later as cancelled, once its wait is over: logged late-resume resolve"
                    '(("x") ((504 "late")) () ((late-resume resolve)))
                    (list asked (seen c) (test-host-lookups host) (test-host-log host)))
        (test-equal "and the name it asked for can be answered no more"
                    'refused
                    (refused 'test-host-answer! (lambda () (test-host-answer! host "x" '("192.0.2.1")))))))
    (let* ((host (make-test-host
                  (lambda (request)
                    (awaiting (lambda () (text 200 (car (resolve "same.example"))))))))
           (one (test-host-connect! host))
           (two (test-host-connect! host)))
      (test-client-send! one (get "/"))
      (test-client-send! two (get "/"))
      (let ((asked (test-host-lookups host)))
        (test-host-answer! host "same.example" '("192.0.2.1"))
        (test-equal "two lookups of one name: an answer goes to the one asked first"
                    '(("same.example" "same.example") ((200 "192.0.2.1")) () ("same.example"))
                    (list asked (seen one) (seen two) (test-host-lookups host)))))

    ;; --- a reset ------------------------------------------------------------------
    (let* ((paths '())
           (host (make-test-host
                  (lambda (request)
                    (let ((path (request-path request)))
                      (set! paths (cons path paths))
                      (if (string=? path "/a")
                          (awaiting (lambda () (sleep-ms 10) (text 200 "a")))
                          (text 200 (substring path 1 2)))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/q"))
      (let ((before (test-client-received c)))
        ;; /a waits; /b arrives and is held, so the server stops reading,
        ;; and /c is still unread when the client resets.
        (test-client-send! c (get "/a"))
        (test-client-send! c (get "/b"))
        (test-client-send! c (get "/c"))
        (test-client-reset! c)
        (test-host-advance! host 10)
        (test-equal "a client that resets reads nothing written after it: only what was written before"
                    '(((200 "q")) same-bytes)
                    (list (seen c) (if (equal? (test-client-received c) before) 'same-bytes 'more-bytes)))
        (test-equal "and the server reads the reset after what the client sent before it, as it reads a close"
                    '(("/q" "/a" "/b" "/c") ((read-error ECONNRESET)) #t)
                    (list (reverse paths) (test-host-log host) (test-client-connection-closed? c)))))

    ;; --- a taker's raise ---------------------------------------------------------
    (let* ((host (make-test-host
                  (lambda (request)
                    (switch-protocols (list (cons (b "Upgrade") (b "echo")))
                                      (lambda (t retained) (raise 'taker-boom))))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "GET /echo HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: echo\r\n\r\n"))
      (test-equal "a taker that raises is logged taker-failed with what it raised, and its stream closed"
                  '((101) ((taker-failed taker-boom)) #t)
                  (list (map test-response-status (test-client-responses c)) (test-host-log host)
                        (test-client-connection-closed? c))))

    ;; --- a procedure told the response's end that raises ------------------------
    (let* ((heard '())
           (host (make-test-host
                  (lambda (request)
                    (request-on-done! request (lambda (how) (set! heard (cons (list 'first how) heard))))
                    (request-on-done! request (lambda (how) (raise 'done-boom)))
                    (make-response 200 #f '() (b "ok")))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
      (test-equal "a procedure told the response's end that raises is logged on-done-failed with what it raised, and the one registered before it is still told"
                  '((200) ((on-done-failed done-boom)) ((first written)))
                  (list (map test-response-status (test-client-responses c)) (test-host-log host) heard)))
    (let* ((host (make-test-host
                  (lambda (request)
                    (if (string=? (request-path request) "/first")
                        (begin (request-on-done! request (lambda (how) (raise 'done-boom)))
                               (make-response 200 #f '() (b "ok")))
                        (raise 'handler-boom)))))
           (c (test-host-connect! host)))
      (test-client-send! c (b "GET /first HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n"))
      (test-equal "the first response's on-done-failed is logged before the second request's handler-failed, in the order they happened"
                  '((200 500) ((on-done-failed done-boom) (handler-failed handler-boom)))
                  (list (map test-response-status (test-client-responses c)) (test-host-log host))))

    ;; --- a host that never goes quiet --------------------------------------------
    (let* ((host (make-test-host (lambda (request) (awaiting (lambda () (let loop () (sleep-ms 0) (loop)))))))
           (c (test-host-connect! host)))
      (test-equal "a handler that sleeps 0 ms forever never lets the host go quiet: an assertion violation, not a hang"
                  'stuck
                  (guard (e ((assertion-violation? e) (if (eq? (condition-who e) 'test-host) 'stuck (condition-who e))))
                    (test-client-send! c (get "/"))
                    'returned)))
    (let* ((host (make-test-host (lambda (request) (make-response 200 #f '() (lambda () (b "more"))))))
           (c (test-host-connect! host)))
      (test-equal "and so does a producer that never ends"
                  'stuck
                  (guard (e ((assertion-violation? e) (if (eq? (condition-who e) 'test-host) 'stuck (condition-who e))))
                    (test-client-send! c (get "/"))
                    'returned)))

    ;; --- what the test calls, and when ---------------------------------------------
    (let* ((kept #f)
           (host (make-test-host
                  (lambda (request)
                    (awaiting (lambda () (text 200 (await (lambda (resume) (set! kept resume)))))))))
           (c (test-host-connect! host)))
      (test-client-send! c (get "/"))
      (when (procedure? kept) (kept "resumed"))
      (let ((before (seen c)))
        (test-host-advance! host 0)
        (test-equal "a resume the test calls itself runs at the host's next call: an advance of 0 ms"
                    '(() ((200 "resumed")) 0)
                    (list before (seen c) (test-host-now host)))))
    (let* ((cell #f)
           (host (make-test-host
                  (lambda (request)
                    (if (string=? (request-path request) "/plain")
                        (begin (test-host-advance! (car cell) 0) (text 200 "advanced"))
                        (awaiting (lambda () (test-client-send! (cdr cell) (get "/x")) (text 200 "sent")))))))
           (plain (test-host-connect! host))
           (waits (test-host-connect! host)))
      (set! cell (cons host plain))
      (test-client-send! plain (get "/plain"))
      (test-client-send! waits (get "/waits"))
      (test-equal "a host call from the host's own code, a handler's or a coroutine's, is refused: the handler raises, answered 500 and logged handler-failed"
                  '(((500 "")) ((500 "")) (test-host-advance! test-client-send!))
                  (list (seen plain) (seen waits)
                        (map (lambda (entry)
                               (let ((e (and (pair? (cdr entry)) (cadr entry))))
                                 (and (eq? (car entry) 'handler-failed) (condition? e) (who-condition? e)
                                      (condition-who e))))
                             (test-host-log host)))))
    (test-equal "a host is made with a procedure, its clock goes on by a whole number of milliseconds, and a client sends a bytevector"
                '(refused refused refused refused)
                (let* ((host (make-test-host (lambda (request) (text 200 "ok"))))
                       (c (test-host-connect! host)))
                  (list (refused 'make-test-host (lambda () (make-test-host 'not-a-procedure)))
                        (refused 'test-host-advance! (lambda () (test-host-advance! host -1)))
                        (refused 'test-host-advance! (lambda () (test-host-advance! host 1.5)))
                        (refused 'test-client-send! (lambda () (test-client-send! c "GET / HTTP/1.1\r\n\r\n"))))))

    ;; --- examples/long-poll.sps ----------------------------------------------------
    (let* ((host (make-test-host (program-handler "examples/long-poll.sps")))
           (waiter (test-host-connect! host))
           (sender (test-host-connect! host)))
      (test-client-send! waiter (get "/wait"))
      (let ((waiting (list (seen waiter) (test-client-waiting? waiter))))
        (test-client-send! sender (b "POST /send HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
        (test-equal "long-poll: a GET /wait waits, and a POST /send on another connection wakes it with its message"
                    '((() #t) ((200 "woke 1\n")) ((200 "hello")) #f)
                    (list waiting (seen sender) (seen waiter) (test-client-waiting? waiter)))))
    (let* ((host (make-test-host (program-handler "examples/long-poll.sps")))
           (waiter (test-host-connect! host)))
      (test-client-send! waiter (get "/wait"))
      (test-host-advance! host 29999)
      (let ((at-29999 (seen waiter)))
        (test-host-advance! host 1)
        (test-equal "long-poll: a wait that hears nothing for 30 seconds is answered 504"
                    '(() ((504 "no message came\n")))
                    (list at-29999 (seen waiter)))))
    (let* ((host (make-test-host (program-handler "examples/long-poll.sps")))
           (left (test-host-connect! host))
           (sender (test-host-connect! host)))
      (test-client-send! left (get "/wait"))
      (test-client-close! left)
      (test-client-send! sender (b "POST /send HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi"))
      (test-equal "long-poll: a client that leaves is forgotten, so a send wakes no one, and nothing is logged"
                  '(() #t ((200 "woke 0\n")) ())
                  (list (seen left) (test-client-connection-closed? left) (seen sender) (test-host-log host))))))
