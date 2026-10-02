#!r6rs
;;; (http-server), the facade, and the server it starts.  M4.5.
;;;
;;; An embedder imports (http-server) and calls `serve` with a handler.
;;; `serve` starts a server on a loop of its own, configured through the
;;; environment and logging on standard output, and runs that loop until the
;;; server stops.  The start is `start-server`: this suite starts servers
;;; with it on a loop of the suite's own, through environments it makes, and
;;; runs its clients on that loop, every wait capped by an iteration count
;;; (design §8.5).  A start that fails raises before any loop runs, so those
;;; checks call `serve` itself.  And `serve`'s own loop, the scheduler's turns
;;; that call each handler after libuv's (decision 0014; M7.1), runs in a
;;; process of its own, tests/serve-child.sps, started with the Chez the
;;; environment's CHEZ names, as `make` runs it, or `chez`: the suite reads
;;; the port it logs, and a client on the suite's loop asks it for a page.
;;;
;;; Oracles:
;;;   - decision 0012: where the server listens, and what a handler reads;
;;;   - design §6.4: a malformed setting at startup is an
;;;     &http-server-config-error, which is an &http-server-error, an &error;
;;;   - the M2.4 note: a facade that builds limits refuses a pipeline cap
;;;     other than 1, as the environment's path does;
;;;   - chez-libuv's bind, which refuses a host that is not an IPv4 or IPv6
;;;     literal ('bad-address);
;;;   - decision 0001: the handler contract is request -> response, so the
;;;     facade exports what a handler needs, the server's start, and its
;;;     errors;
;;;   - the Twelve-Factor App's logs (XI): one line for each thing that
;;;     happens, written to standard output.  A condition's text is Chez's
;;;     `display-condition`'s, as Chez 10.4.1 prints it.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) library-exports with-output-to-string putenv getenv)
        (libuv) (uv-testing) (shell-testing) (response-reader)
        (http-server)
        (only (http-server private shell) shell-connections shell-listener shell-shutdown!)
        (only (http-server private serve) start-server log-line))

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
;; the X-Probe header, "-" for one that is not there.
(define (handler r)
  (make-response 200 #f '()
                 (b (string-append (symbol->string (request-method r))
                                   " " (request-path r)
                                   " " (or (request-query r) "-")
                                   " " (request-host r)
                                   " " (or (request-header r "x-probe") "-")))))

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

;; served-by-a-child : -> (List Symbol (U (List Nat String Symbol) #f))
;; Start tests/serve-child.sps as a process of its own, its standard output
;; read on a loop of the suite's, until it logs where it listens, whatever
;; it writes before that line; then a
;; client asks it for a page, reading until it closes the stream.  How the
;; waits ended, the first that did not end 'satisfied, and the response,
;; by chez-httparse's response parser, or #f if none was read; the child is
;; killed after.
(define (served-by-a-child)
  (let* ((loop (make-uv-loop))
         (pipe (make-uv-pipe loop))
         (out (make-byte-collector))
         (exit-status #f)
         (chez (or (getenv "CHEZ") "chez"))
         (process (uv-spawn! loop chez (list chez "--program" "tests/serve-child.sps")
                             (list (cons 'stdio (list 'ignore (list 'pipe pipe 'from-child)
                                                      '(inherit-fd . 2))))
                             (lambda (status signal) (set! exit-status (list status signal))))))
    (uv-read-start! pipe (lambda (bv start end) (collect-span! out bv start end))
                    (lambda () #f) (lambda (e) #f))
    (let* ((port (lambda () (listening-port (utf8->string (collector-bytes out)))))
           (listening (run-loop-until loop (lambda () (and (port) #t)) cap))
           (cl (and (port)
                    (open-client loop (port) (b "GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n") #t)))
           (answered (if cl (run-loop-until loop (lambda () (not (eq? (client-end cl) 'open))) cap) 'no-port))
           (response (and cl (pair? (responses-of (client-bytes cl)))
                          (let ((r (read-response (client-bytes cl) #f #t)))
                            (list (car r) (cadddr r) (list-ref r 4))))))
      (when cl (client-close! cl))
      (uv-process-kill! process 'sigkill)
      (run-loop-until loop (lambda () exit-status) cap)
      (uv-close! process)
      (uv-close! pipe)
      (run-until-drained loop cap)
      (uv-loop-teardown! loop)
      (list (if (eq? listening 'satisfied) answered listening) response))))

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
    (test-equal "the facade exports the handler's names, the server's start, and its errors"
                '(&http-server-config-error &http-server-error http-server-config-error?
                  http-server-error? make-response read-body read-whole-body request-header
                  request-host request-method request-path request-query request? response? serve)
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
      (test-equal "a request reaches the handler, read through the facade's names, and its answer the client"
                  '(200 "GET /p q=1 example.test:81 v" complete)
                  (exchange loop sh port
                            (b "GET http://example.test:81/p?q=1 HTTP/1.1\r\nHost: other.test\r\nX-Probe: v\r\nConnection: close\r\n\r\n")))
      (test-equal "its limits are the environment's: a target over CHEZ_HTTP_MAX_TARGET_BYTES gets 414"
                  '(414 "" complete)
                  (exchange loop sh port
                            (b (string-append "GET /" (make-string 70 #\a) " HTTP/1.1\r\nHost: h\r\n\r\n"))))
      ;; Sent in one write, the target and the byte after it reach the
      ;; parser in one read, and the parser's error cuts the target off: the
      ;; shell hands the core the span it had open, so the limit it passed
      ;; first still names the answer (the cut-off-span PR).
      (test-equal "and so does such a target followed by a byte no target may hold, the parser's error cutting it off"
                  '(414 "" complete)
                  (exchange loop sh port
                            (b (string-append "GET /" (make-string 70 #\a) "\x1; HTTP/1.1\r\nHost: h\r\n\r\n"))))
      (test-equal "and a body over CHEZ_HTTP_MAX_BODY_BYTES gets 413"
                  '(413 "" complete)
                  (exchange loop sh port
                            (b "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")))
      (shell-shutdown! sh)
      (run-until-drained loop cap)
      (test-equal "shut down, the server leaves nothing on the loop" '() (uv-loop-live-handles loop))
      (uv-loop-teardown! loop))

    ;; --- a start that fails ---
    (test-equal "a malformed setting raises an &http-server-config-error naming it, from serve"
                '((#t #t #t #t) (#t #t #t #t) (#t #t #t #t))
                (map (lambda (setting)
                       (refused (lambda ()
                                  (serve handler (env setting (cons "CHEZ_HTTP_HOST" unbound-host))))
                                (car setting)))
                     '(("CHEZ_HTTP_PORT" . "http")
                       ("CHEZ_HTTP_PIPELINE_CAP" . "2")
                       ("CHEZ_HTTP_MAX_CONNECTIONS" . "0"))))
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
