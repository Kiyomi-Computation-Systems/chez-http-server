#!r6rs
;;; (http-server), the facade, and the server it starts.
;;;
;;; An embedder imports (http-server) and calls `serve` with a handler.
;;; `serve` starts a server on a loop of its own, configured through the
;;; environment and logging on standard output, and runs that loop until the
;;; server stops.  The start is `start-server`: this suite starts servers
;;; with it on a loop of the suite's own, through environments it makes, and
;;; runs its clients on that loop, every wait capped by an iteration count.
;;; A start that fails raises before any loop runs, so those checks call
;;; `serve` itself.  And `serve`'s own loop, the scheduler's turns that call
;;; each handler after libuv's, runs in a process of its own,
;;; tests/serve-child.sps, started with the Chez the environment's CHEZ
;;; names, as `make` runs it, or `chez`: the suite reads the port it logs,
;;; and a client on the suite's loop asks it for a page.
;;; Sent SIGTERM, or SIGINT, the child drains: a client idle on its
;;; keep-alive connection is closed at once, a request in flight is
;;; answered, saying the connection closes, one held past the drain's
;;; deadline is closed at it, the drain is logged, and `serve` returns once
;;; its last connection has closed, so the child exits 0.  It drains even
;;; when the SIGTERM comes as it logs `listening`.  Once `serve` has
;;; returned, a SIGINT ends the process at once.
;;;
;;; Oracles:
;;;   - the documented configuration and handler reading (docs/handlers.md,
;;;     docs/configuration.md): where the server listens, CHEZ_HTTP_HOST and
;;;     CHEZ_HTTP_PORT, and what a handler reads;
;;;   - a malformed setting at startup is an &http-server-config-error,
;;;     which is an &http-server-error, an &error;
;;;   - CHEZ_HTTP_REQUIRE_HOST is "true" or "false", and any other value is
;;;     refused;
;;;   - a number is written in ASCII digits alone, so CHEZ_HTTP_PORT=#x1F90
;;;     is refused, not port 8080;
;;;   - chez-libuv's bind, which refuses a host that is not an IPv4 or IPv6
;;;     literal ('bad-address);
;;;   - the handler contract is request -> response, so the facade exports
;;;     what a handler needs, the server's start, and its errors; a handler
;;;     takes an upgrade with the facade's names alone, its switch, and the
;;;     transport's verbs;
;;;   - the Twelve-Factor App's logs (XI): one line for each thing that
;;;     happens, written to standard output.  A condition's text is Chez's
;;;     `display-condition`'s, as Chez 10.4.1 prints it;
;;;   - and its disposability (IX): a process shuts down gracefully when sent
;;;     SIGTERM, and SIGINT too.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) library-exports with-output-to-string putenv getenv)
        (libuv) (uv-testing) (shell-testing) (response-reader)
        (http-server)
        (only (http-server private shell) shell-connections shell-listener shell-shutdown! shell-scheduler shell-signals)
        (only (http-server private scheduler) scheduler-call!)
        (only (http-server private serve) start-server run-until-stopped! log-line))

(define (b s) (string->utf8 s))

(define cap 4096)

;; A host no bind accepts.  The suite's own environment names it, and so does
;; every start below that should fail, so a start that got past its settings,
;; or a `serve` that read the process's environment rather than its lookup, is
;; refused at the bind instead of listening on 8080 and running for good.
(define unbound-host "not-an-ip")

;; env : (Pair String String) ... -> (String -> (U String #f))
;; An environment holding just these variables.
(define (env . pairs)
  (lambda (name) (let ((p (assoc name pairs))) (and p (cdr p)))))

;; What the server logged, oldest first, as (what . details).
(define logged '())
(define (log! what details) (set! logged (append logged (list (cons what details)))))

;; The handler reads the request through the facade's names alone, and
;; answers with what it read: the method, the path, the query, the host and
;; the X-Probe header, "-" for one that is not there.  At `/door` it takes
;; the upgrade to `echo`, with the facade's names alone: its taker writes
;; back what it is handed and what it reads, and closes at the client's end.
(define (handler r)
  (if (string=? (request-path r) "/door")
      (switch-protocols (list (cons (b "Upgrade") (b "echo")))
                        (lambda (t retained)
                          (when (> (bytevector-length retained) 0) (transport-write! t retained))
                          (transport-read-start! t
                                                 (lambda (bv from to) (transport-write! t bv from to))
                                                 (lambda (why) (transport-close! t)))))
      (make-response 200 #f '()
                     (b (string-append (symbol->string (request-method r))
                                       " " (request-path r)
                                       " " (or (request-query r) "-")
                                       " " (request-host r)
                                       " " (or (request-header r "x-probe") "-")
                                       " " (number->string (request-http-major r))
                                       "." (number->string (request-http-minor r)))))))

;; refused : (-> Any) String -> (U (List Boolean Boolean Boolean Boolean) 'started)
;; How `start` fails: whether its raise is an &http-server-config-error, an
;; &http-server-error and an &error, and whether its irritants name
;; `variable`; 'started if it does not raise.
(define (refused start variable)
  (guard (e ((condition? e)
             (list (http-server-config-error? e) (http-server-error? e) (error? e)
                   (and (irritants-condition? e)
                        (member variable (condition-irritants e))
                        #t))))
    (start)
    'started))

;; exchange : UvLoop Shell Nat Bytevector -> (List Nat String Symbol)
;; A client sends `request` to `port` and reads until the server ends the
;; stream: the status, the body and how the read ended, by chez-httparse's
;; response parser.  It then closes, ending the server's linger.
(define (exchange loop sh port request)
  (let ((cl (open-client loop port request #t)))
    (run-shell-until loop sh (lambda () (not (eq? (client-end cl) 'open))) cap)
    (client-close! cl)
    (run-shell-until loop sh (lambda () (null? (shell-connections sh))) cap)
    (let ((r (read-response (client-bytes cl) #f #t)))
      (list (car r) (cadddr r) (list-ref r 4)))))

;; dones-at-stop : Nat Boolean -> (List (Listof (List Nat Any)) (Listof (List Nat Any)) Boolean)
;; A server whose handler takes an upgrade, and whose taker, once its stream
;; has closed, asks for `writes` writes, numbered from 1, the `done` of each
;; recording its number and what it is told; with `again?`, a `done` so told
;; asks for one more, until three have been asked for.  As the stream
;; closes, other work is queued on the scheduler too, which notes that it
;; ran.  The taker's drain call closes its stream, which lingers for the
;; server's 1 s, its client open.  Once the client has been
;; handed over, the server is shut down and run as `serve` runs it
;; (run-until-stopped!): what the `done`s had been told when that run
;; returned, and once the loop had turned on until only timers were left;
;; and whether the other work had run when that run returned.
(define (dones-at-stop writes again?)
  (letrec* ((told '())
            (other #f)
            (asked 0)
            (taken #f)
            (loop (make-uv-loop))
            (sh (start-server loop
                              (lambda (r)
                                (switch-protocols
                                 (list (cons (b "Upgrade") (b "echo")))
                                 (lambda (t retained)
                                   (define (write-late!)
                                     (set! asked (+ asked 1))
                                     (let ((k asked))
                                       (transport-write! t (b "late") 0 4
                                                         (lambda (why)
                                                           (set! told (append told (list (list k why))))
                                                           (when (and again? (< asked 3))
                                                             (write-late!))))))
                                   (set! taken #t)
                                   (transport-on-drain! t (lambda () (transport-close! t)))
                                   (transport-on-close! t (lambda ()
                                                            (scheduler-call! (shell-scheduler sh)
                                                                             (lambda () (set! other #t)))
                                                            (do ((i 0 (+ i 1))) ((= i writes))
                                                              (write-late!)))))))
                              (env '("CHEZ_HTTP_PORT" . "0") '("CHEZ_HTTP_LINGER_TIMEOUT" . "1"))
                              (lambda (what details) #f)))
            (cl (open-client loop (uv-tcp-getsockname-port (shell-listener sh))
                             (b "GET / HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n")
                             #t)))
    (run-shell-until loop sh (lambda () taken) cap)
    (shell-shutdown! sh)
    (run-until-stopped! sh)
    (let ((at-stop told) (other-at-stop other))
      (client-close! cl)
      (run-shell-until loop sh (lambda () (for-all uv-timer? (uv-loop-live-handles loop))) cap)
      (uv-loop-teardown! loop)
      (list at-stop told other-at-stop))))

;; with-child : (Listof String) (UvLoop (-> String) (-> (U #f List)) UvProcess -> Any) -> Any
;; Start tests/serve-child.sps with `args` as a process of its own, with the
;; Chez the environment's CHEZ names, or `chez`, its standard output
;; collected on a loop of the suite's own, and call `body` with the loop,
;; what the child has written so far, how it exited, (status signal), or #f
;; while it runs, and the process.  Then a child still running is killed,
;; everything closed and the loop torn down, answering what `body` answered.
(define (with-child args body)
  (let* ((loop (make-uv-loop))
         (pipe (make-uv-pipe loop))
         (out (make-byte-collector))
         (exit-status #f)
         (chez (or (getenv "CHEZ") "chez"))
         (process (uv-spawn! loop chez (append (list chez "--program" "tests/serve-child.sps") args)
                             (list (cons 'stdio (list 'ignore (list 'pipe pipe 'from-child)
                                                      '(inherit-fd . 2))))
                             (lambda (status signal) (set! exit-status (list status signal))))))
    (uv-read-start! pipe (lambda (bv start end) (collect-span! out bv start end))
                    (lambda () #f) (lambda (e) #f))
    (let ((answer (body loop (lambda () (utf8->string (collector-bytes out))) (lambda () exit-status)
                        process)))
      (unless exit-status
        (uv-process-kill! process 'sigkill)
        (run-loop-until loop (lambda () exit-status) cap))
      (uv-close! process)
      (uv-close! pipe)
      (run-until-drained loop cap)
      (uv-loop-teardown! loop)
      answer)))

;; served-by-a-child : -> (List Symbol (U (List Nat String Symbol) #f))
;; Start the child (with-child), waiting until it logs where it listens,
;; whatever it writes before that line; then a client asks it for a page,
;; reading until it closes the stream.  How the waits ended, the first that
;; did not end 'satisfied, and the response, by chez-httparse's response
;; parser, or #f if none was read; the child is killed after.
(define (served-by-a-child)
  (with-child '()
    (lambda (loop text exited process)
      (let* ((port (lambda () (listening-port (text))))
             (listening (run-loop-until loop (lambda () (and (port) #t)) cap))
             (cl (and (port)
                      (open-client loop (port) (b "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n") #t)))
             (answered (if cl (run-loop-until loop (lambda () (not (eq? (client-end cl) 'open))) cap) 'no-port))
             (response (and cl (pair? (responses-of (client-bytes cl)))
                            (let ((r (read-response (client-bytes cl) #f #t)))
                              (list (car r) (cadddr r) (list-ref r 4))))))
        (when cl (client-close! cl))
        (list (if (eq? listening 'satisfied) answered listening) response)))))

;; drained-by-a-child : Symbol -> Datum
;; Start the child.  One client is served `/` and left idle on its
;; keep-alive connection; a second sends the head of `POST /wait`, in
;; flight once the child writes `handling`, its body still to come; and a
;; third `GET /long`, in flight once the child writes `holding`.  Then the
;; child is sent `sig`; once the idle client's stream has ended, which shows
;; the drain has begun, the second sends its body.  How each wait ended; the
;; second's response, its status, body and Connection field, by
;; chez-httparse's response parser; what the third read, as statuses, and
;; how its stream ended; the lines the child wrote after `listening`; and
;; how it exited.  The second client closes once it has read the stream's
;; end, which ends the child's linger.
(define (drained-by-a-child sig)
  (with-child '()
    (lambda (loop text exited process)
      (let* ((said? (lambda (line) (and (member line (lines-after-listening (text))) #t)))
             (port (lambda () (listening-port (text))))
             (listening (run-loop-until loop (lambda () (and (port) #t)) cap))
             (idle (and (port) (open-client loop (port) (b "GET / HTTP/1.1\r\nHost: h\r\n\r\n") #t)))
             (served (if idle
                         (run-loop-until loop (lambda () (pair? (responses-of (client-bytes idle)))) cap)
                         'no-port))
             (flight (and idle (open-client loop (port)
                                            (b "POST /wait HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n")
                                            #t)))
             (handling (if flight (run-loop-until loop (lambda () (said? "handling")) cap) 'no-port))
             (held (and flight (open-client loop (port) (b "GET /long HTTP/1.1\r\nHost: h\r\n\r\n") #t)))
             (holding (if held (run-loop-until loop (lambda () (said? "holding")) cap) 'no-port))
             (signalled (begin (uv-process-kill! process sig) 'signalled))
             (idle-ended (if idle (run-loop-until loop (lambda () (not (eq? (client-end idle) 'open))) cap)
                             'no-port))
             (sent (begin (when flight (client-send! flight (b "hello"))) 'sent))
             (answered (if flight (run-loop-until loop (lambda () (not (eq? (client-end flight) 'open))) cap)
                           'no-port))
             (response (and flight (pair? (responses-of (client-bytes flight)))
                            (let ((r (read-response (client-bytes flight) #f #t)))
                              (list (car r) (cadddr r)
                                    (let ((f (assoc "Connection" (caddr r)))) (if f (cdr f) 'absent))))))
             (closed (begin (when flight (client-close! flight)) 'closed))
             (cut (if held (run-loop-until loop (lambda () (not (eq? (client-end held) 'open))) cap) 'no-port))
             (ended (run-loop-until loop exited cap)))
        (for-each (lambda (cl) (when cl (client-close! cl))) (list idle held))
        (list (list listening served handling holding idle-ended answered cut ended) response
              (if held (list (map car (responses (client-bytes held))) (client-end held)) 'no-port)
              (lines-after-listening (text)) (exited))))))

;; returned-then-interrupted : -> Datum
;; Start the child with `sigint-after` and send it SIGTERM once it listens,
;; no connection open, so its drain ends at once and `serve` returns; the
;; child then sends itself SIGINT.  How the waits ended, the lines it wrote
;; after `listening`, and how it exited.
(define (returned-then-interrupted)
  (with-child '("sigint-after")
    (lambda (loop text exited process)
      (let* ((listening (run-loop-until loop (lambda () (and (listening-port (text)) #t)) cap))
             (signalled (begin (uv-process-kill! process 'sigterm) 'signalled))
             (ended (run-loop-until loop exited cap)))
        (list listening ended (lines-after-listening (text)) (exited))))))

;; signalled-at-listening : -> Datum
;; Start the child with `sigterm-at-listening`, which sends itself SIGTERM
;; as `serve` writes `listening`.  How the wait for its exit ended, whether
;; it wrote where it listens, the lines it wrote after that, and how it
;; exited.
(define (signalled-at-listening)
  (with-child '("sigterm-at-listening")
    (lambda (loop text exited process)
      (let ((ended (run-loop-until loop exited cap)))
        (list ended (and (listening-port (text)) #t) (lines-after-listening (text)) (exited))))))

;; lines-after-listening : String -> (Listof String)
;; The whole lines of `text` after the first that starts `listening `.
(define (lines-after-listening text)
  (let loop ((rest text) (seen? #f) (acc '()))
    (let ((end (string-index rest #\newline)))
      (if (not end)
          (reverse acc)
          (let ((line (substring rest 0 end))
                (more (substring rest (+ end 1) (string-length rest))))
            (cond (seen? (loop more #t (cons line acc)))
                  ((and (>= (string-length line) 10) (string=? (substring line 0 10) "listening "))
                   (loop more #t acc))
                  (else (loop more #f acc))))))))

;; listening-port : String -> (U Nat #f)
;; The port the line `listening HOST PORT` names, among the whole lines of
;; `text`, or #f until one has come.
(define (listening-port text)
  (let loop ((rest text))
    (let ((end (string-index rest #\newline)))
      (and end
           (let ((line (substring rest 0 end)))
             (if (and (>= (string-length line) 10) (string=? (substring line 0 10) "listening "))
                 (string->number (last-word line))
                 (loop (substring rest (+ end 1) (string-length rest)))))))))

;; string-index : String Char -> (U Nat #f)
(define (string-index s c)
  (let loop ((i 0))
    (cond ((= i (string-length s)) #f)
          ((char=? (string-ref s i) c) i)
          (else (loop (+ i 1))))))

;; last-word : String -> String — after the last space.
(define (last-word s)
  (let loop ((i (string-length s)))
    (cond ((= i 0) s)
          ((char=? (string-ref s (- i 1)) #\space) (substring s i (string-length s)))
          (else (loop (- i 1))))))

;; responses-of : Bytevector -> (Listof Any) — whether a response's head has
;; arrived: a list with one element once the bytes hold a blank line.
(define (responses-of bv)
  (let loop ((i 0))
    (cond ((> (+ i 4) (bytevector-length bv)) '())
          ((and (= (bytevector-u8-ref bv i) 13) (= (bytevector-u8-ref bv (+ i 1)) 10)
                (= (bytevector-u8-ref bv (+ i 2)) 13) (= (bytevector-u8-ref bv (+ i 3)) 10))
           '(head))
          (else (loop (+ i 1))))))

(run-suite "serve"
  (lambda ()
    (putenv "CHEZ_HTTP_HOST" unbound-host)

    ;; --- what the facade exports ---
    (test-equal "the facade exports the handler's names, the verbs it waits with and what they raise, a switch and the transport's verbs, the server's start, and its errors"
                '(&client-closed &deadline-passed &http-server-config-error &http-server-error &resolve-error
                  await awaiting client-closed? deadline-passed? http-server-config-error? http-server-error?
                  make-response
                  make-transport read-body read-whole-body request-header request-header-values request-host
                  request-http-major request-http-minor request-method
                  request-path request-query request? resolve resolve-error-reason resolve-error?
                  response? serve sleep-ms switch-protocols transport-abort! transport-close! transport-deadline!
                  transport-on-close! transport-on-drain! transport-read-start! transport-read-stop!
                  transport-write! transport? with-deadline)
                (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                           (library-exports '(http-server))))

    ;; --- a server started through an environment, serving ---
    (let* ((loop (make-uv-loop))
           (sh (start-server loop handler
                             (env '("CHEZ_HTTP_PORT" . "0") '("CHEZ_HTTP_MAX_TARGET_BYTES" . "64")
                                  '("CHEZ_HTTP_MAX_BODY_BYTES" . "4"))
                             log!))
           (port (let ((entry (assq 'listening logged))) (and entry (caddr entry)))))
      (test-equal "it listens where the environment says, and logs where, with the kernel's port"
                  '((listening "127.0.0.1" #t))
                  (map (lambda (entry)
                         (list (car entry) (cadr entry)
                               (and (eqv? (caddr entry) (uv-tcp-getsockname-port (shell-listener sh)))
                                    (> (caddr entry) 0))))
                       logged))
      (test-equal "started with no ready, it watches no signal: that is serve's"
                  '()
                  (shell-signals sh))
      (test-equal "started with a ready, it calls it once it listens, before it logs listening"
                  '(listening ())
                  (let* ((rloop (make-uv-loop))
                         (said '())
                         (seen #f)
                         (rsh (start-server rloop handler (env '("CHEZ_HTTP_PORT" . "0"))
                                            (lambda (what details) (set! said (cons what said)))
                                            (lambda (s)
                                              (set! seen (list (let ((l (shell-listener s)))
                                                                 (and l (uv-handle-open? l) 'listening))
                                                               said))))))
                    (shell-shutdown! rsh)
                    (run-until-drained rloop cap)
                    (uv-loop-teardown! rloop)
                    seen))
      (test-equal "a request reaches the handler, read through the facade's names, and its answer the client"
                  '(200 "GET /p q=1 example.test:81 v 1.1" complete)
                  (exchange loop sh port
                            (b "GET http://example.test:81/p?q=1 HTTP/1.1\r\nHost: other.test\r\nX-Probe: v\r\nConnection: close\r\n\r\n")))
      (test-equal "the version reads as the request names it: HTTP/1.0 is 1.0"
                  '(200 "GET /p - h - 1.0" complete)
                  (exchange loop sh port (b "GET /p HTTP/1.0\r\nHost: h\r\n\r\n")))
      ;; The server answers it as HTTP/1.1 (tests/test-connection-head.sps);
      ;; the handler reads the version the client sent.
      (test-equal "and HTTP/1.2 is 1.2, not the 1.1 it is answered in"
                  '(200 "GET /p - h - 1.2" complete)
                  (exchange loop sh port (b "GET /p HTTP/1.2\r\nHost: h\r\nConnection: close\r\n\r\n")))
      (test-equal "its limits are the environment's: a target over CHEZ_HTTP_MAX_TARGET_BYTES gets 414"
                  '(414 "" complete)
                  (exchange loop sh port
                            (b (string-append "GET /" (make-string 70 #\a) " HTTP/1.1\r\nHost: h\r\n\r\n"))))
      ;; Sent in one write, the target and the byte after it reach the
      ;; parser in one read, and the parser's error cuts the target off: the
      ;; shell hands the core the span it had open, so the limit it passed
      ;; first still names the answer.
      (test-equal "and so does such a target followed by a byte no target may hold, the parser's error cutting it off"
                  '(414 "" complete)
                  (exchange loop sh port
                            (b (string-append "GET /" (make-string 70 #\a) "\x1; HTTP/1.1\r\nHost: h\r\n\r\n"))))
      (test-equal "and a body over CHEZ_HTTP_MAX_BODY_BYTES gets 413"
                  '(413 "" complete)
                  (exchange loop sh port
                            (b "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")))
      ;; A client sends its handshake and, with it, the first bytes of the
      ;; new protocol: it reads the 101 and those bytes back; then it ends
      ;; its side, and reads the stream's end, which the taker closes at its
      ;; own.
      (let* ((sent (b "GET /door HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\nping"))
             (expected "HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: upgrade\r\n\r\nping")
             (cl (open-client loop port sent #t))
             (back (run-shell-until loop sh (lambda () (>= (bytevector-length (client-bytes cl))
                                                           (string-length expected)))
                                    cap)))
        (client-shut! cl)
        (run-shell-until loop sh (lambda () (not (eq? (client-end cl) 'open))) cap)
        (client-close! cl)
        (run-shell-until loop sh (lambda () (null? (shell-connections sh))) cap)
        (test-equal "a handler takes an upgrade with the facade's names alone: the 101, then what its taker writes back, then the stream's end"
                    (list 'satisfied expected 'eof)
                    (list back (utf8->string (client-bytes cl)) (client-end cl))))
      (shell-shutdown! sh)
      (run-until-drained loop cap)
      (test-equal "shut down, the server leaves nothing on the loop" '() (uv-loop-live-handles loop))
      (uv-loop-teardown! loop))

    ;; --- a taker's write refused as the server stops: its `done` waits for
    ;; a turn, and `serve` runs no turn once its server has stopped.
    (test-equal "two writes a taker asks for once its stream has closed: their dones are told ECANCELED before serve's run returns, in order, and once each, and nothing else the scheduler holds is run"
                '(((1 ECANCELED) (2 ECANCELED)) ((1 ECANCELED) (2 ECANCELED)) #f)
                (dones-at-stop 2 #f))
    (test-equal "a done so told as serve's run returns that asks for a write: that write's done waits for a turn, which serve does not run"
                '(((1 ECANCELED)) ((1 ECANCELED) (2 ECANCELED) (3 ECANCELED)) #f)
                (dones-at-stop 1 #t))

    ;; --- a start that fails ---
    (test-equal "a malformed setting raises an &http-server-config-error naming it, from serve"
                '((#t #t #t #t) (#t #t #t #t) (#t #t #t #t) (#t #t #t #t))
                (map (lambda (setting)
                       (refused (lambda ()
                                  (serve handler (env setting (cons "CHEZ_HTTP_HOST" unbound-host))))
                                (car setting)))
                     '(("CHEZ_HTTP_PORT" . "http")
                       ("CHEZ_HTTP_REQUIRE_HOST" . "yes")
                       ("CHEZ_HTTP_MAX_CONNECTIONS" . "0")
                       ("CHEZ_HTTP_PORT" . "#x1F90"))))
    (let ((loop (make-uv-loop)))
      (test-equal "a host that is no IP literal is refused by the bind, as a config error naming CHEZ_HTTP_HOST, and nothing is left open"
                  '((#t #t #t #t) ())
                  (let ((outcome (refused (lambda ()
                                            (start-server loop handler
                                                          (env (cons "CHEZ_HTTP_HOST" unbound-host)
                                                               '("CHEZ_HTTP_PORT" . "0"))
                                                          log!))
                                          "CHEZ_HTTP_HOST")))
                    (run-until-drained loop cap)
                    (list outcome (uv-loop-live-handles loop))))
      (uv-loop-teardown! loop))

    ;; --- serve's own loop, in a process of its own ---
    (test-equal "serve, run as a program of its own, answers a request, calling its handler after libuv's turn"
                '(satisfied (200 "served" complete))
                (served-by-a-child))
    ;; The child's drain lasts 2 s: its idle client is closed at once, before
    ;; the request in flight is answered, and its `/long` is cut short at
    ;; the deadline, a minute's wait still armed, which `serve` does not
    ;; wait for.
    (test-equal "serve, sent SIGTERM, drains: the idle client closed at once, the request in flight answered saying it closes, one held closed at the deadline, the drain logged, and serve returns, the process exiting 0"
                '((satisfied satisfied satisfied satisfied satisfied satisfied satisfied satisfied)
                  (200 "waited" "close") (() eof)
                  ("handling" "holding" "draining 3" "drain-timeout" "stopped") (0 #f))
                (drained-by-a-child 'sigterm))
    (test-equal "and so does serve sent SIGINT"
                '((satisfied satisfied satisfied satisfied satisfied satisfied satisfied satisfied)
                  (200 "waited" "close") (() eof)
                  ("handling" "holding" "draining 3" "drain-timeout" "stopped") (0 #f))
                (drained-by-a-child 'sigint))
    ;; `serve` watches the signals before it logs `listening`, so a
    ;; supervisor that signals the moment it reads the line finds them
    ;; watched.
    (test-equal "serve, sent SIGTERM as it logs listening, drains, as it does a moment later, the process exiting 0"
                '(satisfied #t ("draining 0" "stopped") (0 #f))
                (signalled-at-listening))
    ;; Once `serve` has returned it watches no signal, and chez-libuv leaves
    ;; SIGINT's default disposition, not Chez's keyboard interrupt, so the
    ;; next one ends the process (docs/handlers.md).
    (test-equal "once serve has returned, a SIGINT ends the process at once"
                '(satisfied satisfied ("draining 0" "stopped") (0 sigint))
                (returned-then-interrupted))

    ;; --- the log ---
    (test-equal "the log writes a line for each thing: what happened, then each detail"
                "listening 127.0.0.1 8080\nreconciled #<response>\n"
                (with-output-to-string
                  (lambda ()
                    (log-line 'listening '("127.0.0.1" 8080))
                    (log-line 'reconciled (list (make-response 200 #f '() #f))))))
    (test-equal "a condition in the log reads as Chez displays it, on one line"
                "handler-failed Exception in handler: it failed\ncallback-error Exception occurred with condition components:   0. &error\n"
                (with-output-to-string
                  (lambda ()
                    (log-line 'handler-failed
                              (list (condition (make-error) (make-who-condition 'handler)
                                               (make-message-condition "it failed"))))
                    (log-line 'callback-error (list (make-error))))))))
