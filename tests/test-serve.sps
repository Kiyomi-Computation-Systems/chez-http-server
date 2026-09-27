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
;;; checks call `serve` itself.
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
        (only (chezscheme) library-exports with-output-to-string putenv)
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

(run-suite "serve"
  (lambda ()
    (putenv "CHEZ_HTTP_HOST" unbound-host)

    ;; --- what the facade exports ---
    (test-equal "the facade exports the handler's names, the server's start, and its errors"
                '(&http-server-config-error &http-server-error http-server-config-error?
                  http-server-error? make-response request-header request-host request-method
                  request-path request-query request? response? serve)
                (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                           (library-exports '(http-server))))

    ;; --- a server started through an environment, serving ---
    (let* ((loop (make-uv-loop))
           (sh (start-server loop handler
                             (env '("CHEZ_HTTP_PORT" . "0") '("CHEZ_HTTP_MAX_TARGET_BYTES" . "64"))
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
