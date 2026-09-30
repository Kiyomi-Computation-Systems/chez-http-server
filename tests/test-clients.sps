#!r6rs
;;; Real clients: curl and ab against the server.  The M4 exit (plan §8).
;;;
;;; The brief's gate for M4: `curl` and `ab` get correct responses, and the
;;; counters return to zero.  A server is started through an environment, as
;;; `serve` starts one (tests/test-serve.sps), on a loop of the suite's own.
;;; Each client runs as a child process on that loop: its standard output is
;;; read through a pipe, and its exit is reported there, so every wait is
;;; capped by an iteration count, a 1 ms ticker keeping the loop awake
;;; (design §8.5).  A client that cannot be started is the harness's failure,
;;; status 2, and named on standard error: curl, and ab, from Apache's
;;; apache2-utils on Linux, are test tools.
;;;
;;; Oracles:
;;;   - what each client reports of its exchanges.  curl's --write-out gives
;;;     each transfer's status, the connections it opened (0 when it reused
;;;     one) and the body's size; ApacheBench's report the requests completed,
;;;     failed, answered with other than 2xx, and kept alive;
;;;   - RFC 9112 §9.3: an HTTP/1.1 connection persists, so curl sends its
;;;     second request on the first's connection; decision 0006: a 1.0
;;;     connection closes after its response unless it asks to be kept alive,
;;;     as ab -k asks;
;;;   - RFC 9110 §9.3.2: the answer to a HEAD has the fields a GET's would,
;;;     and no content;
;;;   - RFC 9112 §7.1 and §6.3 rule 8: a streamed body (decision 0013 item 8;
;;;     M6.3) is chunked to HTTP/1.1, so the connection persists after it,
;;;     and close-delimited to 1.0, so it does not;
;;;   - chez-libuv's live handles, and the counters of its dev build: with
;;;     every client gone, the listener is the one handle left but the timer
;;;     the shell keeps for its next deadline (M5.3), and after the shutdown
;;;     none is.
(import (rnrs) (srfi :64) (testing)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server private shell) shell-connections shell-listener shell-shutdown! shell-timer)
        (only (http-server private serve) start-server)
        (rename (only (libuv private native) live-counts) (live-counts debug-live-counts))
        (producers))

(define (b s) (string->utf8 s))

;; The cap on every wait.  All of this suite's clients together take about
;; 700 iterations (2026-09-27, Darwin arm64).
(define cap 20000)

;; env : (Pair String String) ... -> (String -> (U String #f))
(define (env . pairs)
  (lambda (name) (let ((p (assoc name pairs))) (and p (cdr p)))))

;; What the server logged, oldest first, as (what . details).
(define logged '())
(define (log! what details) (set! logged (append logged (list (cons what details)))))

;; The handler answers with the path and the query it read, "-" for none,
;; reading a POST's body first: a response given instead of a reader to a
;; request whose head announces a body closes the connection (decision 0013).
;; `/stream` is answered with a producer of three pieces (M6.3;
;; tests/producers.sls).
(define (handler r)
  (let ((answer (make-response 200 #f '()
                               (if (string=? (request-path r) "/stream")
                                   (producer-of '("one " "two " "three"))
                                   (b (string-append (request-path r) " " (or (request-query r) "-") "\n"))))))
    (if (eq? (request-method r) 'POST)
        (read-body (lambda (bv start end) #t) (lambda () answer))
        answer)))

;; A client run as a child: its process, the pipe its standard output is
;; read through, what it wrote, its exit, as (status signal), and whether its
;; output has ended.
(define-record-type child
  (fields process pipe out (mutable exit) (mutable ended?)))

;; spawn : UvLoop String (Listof String) -> Child
;; Start `file` with `args` on `loop`, its standard input empty, its standard
;; output read into the child's collector, its standard error the suite's.
;; A child that cannot be started raises, its name on standard error.
(define (spawn loop file args)
  (let ((pipe (make-uv-pipe loop)) (out (make-byte-collector)) (c #f))
    (let ((process
           (guard (e (#t (uv-close! pipe)
                         (let ((p (current-error-port)))
                           (put-string p (string-append "clients: cannot start " file
                                                        "; it is a test tool, see tests/test-clients.sps\n"))
                           (flush-output-port p))
                         (raise e)))
             (uv-spawn! loop file (cons file args)
                        (list (cons 'stdio (list 'ignore (list 'pipe pipe 'from-child) '(inherit-fd . 2))))
                        (lambda (status signal) (child-exit-set! c (list status signal)))))))
      (set! c (make-child process pipe out #f #f))
      (uv-read-start! pipe
                      (lambda (bv start end) (collect-span! out bv start end))
                      (lambda () (child-ended?-set! c #t))
                      (lambda (e) (child-ended?-set! c #t)))
      c)))

;; run : UvLoop Shell String (Listof String) -> (List Symbol (List Nat Any) String)
;; Run a client to its end while the server serves: how the wait ended, the
;; client's exit, and what it wrote.  One still running at the cap is killed.
(define (run loop sh file args)
  (let* ((c (spawn loop file args))
         (outcome (run-shell-until loop sh (lambda () (and (child-exit c) (child-ended? c))) cap)))
    (unless (child-exit c)
      (uv-process-kill! (child-process c) 'sigkill)
      (run-shell-until loop sh (lambda () (child-exit c)) cap))
    (uv-close! (child-process c))
    (when (uv-handle-open? (child-pipe c)) (uv-close! (child-pipe c)))
    (list outcome (child-exit c) (utf8->string (collector-bytes (child-out c))))))

;; require-client! : UvLoop Shell String String -> Void
;; Run `file` with `flag`, which prints its version, before any check: a
;; client that cannot be started, or fails, raises there, outside every
;; check, so the suite's status is the harness's, 2, not a failed check's.
(define (require-client! loop sh file flag)
  (let ((r (run loop sh file (list flag))))
    (unless (equal? (list (car r) (cadr r)) '(satisfied (0 #f)))
      (error 'require-client! "a client did not run" file r))))

;; lines : String -> (Listof String) — split after each newline, which is dropped.
(define (lines s)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) #\newline)
           (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

;; starts? : String String -> Boolean
(define (starts? prefix s)
  (and (<= (string-length prefix) (string-length s))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; undated : String -> (List String Nat)
;; The text without its Date lines, which name the second they were written,
;; and how many there were.
(define (undated s)
  (let* ((all (lines s))
         (kept (filter (lambda (l) (not (starts? "Date: " l))) all)))
    (list (if (null? kept)
              ""
              (fold-left (lambda (text l) (string-append text "\n" l)) (car kept) (cdr kept)))
          (- (length all) (length kept)))))

;; report : String String -> (U String #f)
;; What ab's report says after `label`, its spaces trimmed; #f with no such line.
(define (report text label)
  (let ((line (find (lambda (l) (starts? label l)) (lines text))))
    (and line
         (let skip ((i (string-length label)))
           (if (and (< i (string-length line)) (char=? (string-ref line i) #\space))
               (skip (+ i 1))
               (substring line i (string-length line)))))))

;; ab-report : (List Symbol (List Nat Any) String) -> List
;; An ab run as its wait, its exit, and the report's requests: complete,
;; failed, answered with other than 2xx, kept alive, and the body's length.
(define (ab-report run)
  (let ((text (caddr run)))
    (list (car run) (cadr run)
          (map (lambda (label) (report text label))
               '("Complete requests:" "Failed requests:" "Non-2xx responses:"
                 "Keep-Alive requests:" "Document Length:")))))

;; live-count : Symbol -> Nat — chez-libuv's dev-build count of a kind.
(define (live-count kind) (cdr (assq kind (debug-live-counts))))

(define curl-out "%{http_code} %{num_connects} %{size_download}\\n")

(run-suite "clients"
  (lambda ()
    (let* ((loop (make-uv-loop))
           (sh (start-server loop handler (env '("CHEZ_HTTP_PORT" . "0")) log!))
           (port (caddr (assq 'listening logged)))
           (url (lambda (path) (string-append "http://127.0.0.1:" (number->string port) path))))
      (require-client! loop sh "curl" "--version")
      (require-client! loop sh "ab" "-V")

      ;; --- curl ---
      (test-equal "curl: two GETs, the second on the first's connection"
                  (list 'satisfied '(0 #f) "/a x=1\n200 1 7\n/b -\n200 0 5\n")
                  (run loop sh "curl" (list "-sS" "-w" curl-out (url "/a?x=1") (url "/b"))))
      (test-equal "curl: two HEADs, each the fields a GET's answer has and no content, on one connection"
                  (list 'satisfied '(0 #f)
                        (list (string-append "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n200 1 0\n"
                                             "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n200 0 0\n")
                              2))
                  (let ((r (run loop sh "curl" (list "-sS" "-I" "-w" curl-out (url "/h") (url "/i")))))
                    (list (car r) (cadr r) (undated (caddr r)))))
      (test-equal "curl: two POSTs with a body, the second on the first's connection"
                  (list 'satisfied '(0 #f) "/p -\n200 1 5\n/q -\n200 0 5\n")
                  (run loop sh "curl" (list "-sS" "-d" "k=v" "-w" curl-out (url "/p") (url "/q"))))
      ;; curl asks for the 100 on its own for a large upload; asked here for
      ;; a small one.  It waits up to a minute for the 100, so a server that
      ;; never sends one holds it past the cap, and --dump-header shows the
      ;; 100 it read before the response (M6.4; RFC 9110 §10.1.1).
      (test-equal "curl: a POST expecting 100-continue reads the 100, then the response to the body it sent after it"
                  (list 'satisfied '(0 #f)
                        (list (string-append "HTTP/1.1 100 Continue\r\n\r\n"
                                             "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n/e -\n200 1 5\n")
                              1))
                  (let ((r (run loop sh "curl" (list "-sS" "-D" "-" "-H" "Expect: 100-continue"
                                                     "--expect100-timeout" "60" "-d" "k=v"
                                                     "-w" curl-out (url "/e")))))
                    (list (car r) (cadr r) (undated (caddr r)))))
      (test-equal "curl: two HTTP/1.0 GETs, each on a connection of its own"
                  (list 'satisfied '(0 #f) "/y -\n200 1 5\n/z -\n200 1 5\n")
                  (run loop sh "curl" (list "-sS" "--http1.0" "-w" curl-out (url "/y") (url "/z"))))
      (test-equal "curl: a streamed body, chunked, then a GET on its connection"
                  (list 'satisfied '(0 #f) "one two three200 1 13\n/b -\n200 0 5\n")
                  (run loop sh "curl" (list "-sS" "-w" curl-out (url "/stream") (url "/b"))))
      ;; Asked to keep the connection, as ab -k asks: the close still ends the
      ;; body (M3.2's carried arm).
      (test-equal "curl: a streamed body to HTTP/1.0, read to the close though kept alive was asked, then a GET on a connection of its own"
                  (list 'satisfied '(0 #f) "one two three200 1 13\n/b -\n200 1 5\n")
                  (run loop sh "curl" (list "-sS" "--http1.0" "-H" "Connection: keep-alive" "-w" curl-out
                                            (url "/stream") (url "/b"))))

      ;; --- ab ---
      (test-equal "ab: 200 requests, 8 at a time, each on a connection of its own, every one answered"
                  (list 'satisfied '(0 #f) '("200" "0" #f #f "4 bytes"))
                  (ab-report (run loop sh "ab" (list "-n" "200" "-c" "8" (url "/")))))
      (test-equal "ab -k: 200 requests, 8 at a time, kept alive, every one answered"
                  (list 'satisfied '(0 #f) '("200" "0" #f "200" "4 bytes"))
                  (ab-report (run loop sh "ab" (list "-k" "-n" "200" "-c" "8" (url "/")))))

      ;; --- the counters return to zero ---
      (test-eq "with every client gone, every connection leaves the table" 'satisfied
               (run-shell-until loop sh
                                (lambda ()
                                  (and (null? (shell-connections sh))
                                       (for-all (lambda (h) (not (or (uv-pipe? h) (uv-process? h))))
                                                (uv-loop-live-handles loop))))
                                cap))
      (test-equal "and the listener is the one handle left, beside the timer the shell keeps"
                  '(#t #t 2)
                  (let ((live (uv-loop-live-handles loop)) (timer (shell-timer sh)))
                    (list (and (memq (shell-listener sh) live) #t)
                          (and timer (memq timer live) #t)
                          (length live))))
      (test-equal "the server logged nothing but where it listens" '(listening) (map car logged))
      (shell-shutdown! sh)
      (run-until-drained loop cap)
      (test-equal "shut down, nothing is left on the loop" '() (uv-loop-live-handles loop))
      ;; The counters exist only in chez-libuv's dev build (`make build`); a
      ;; prod shim (`make prod`) answers zero for every kind, so they are read
      ;; only when they count the loop this suite made.
      (if (= (live-count 'loop) 1)
          (test-equal "nor a TCP handle, a read buffer, a write request, a pipe or a process"
                      '(0 0 0 0 0)
                      (map live-count '(tcp read-buffer write-req pipe process)))
          (display "clients: chez-libuv's counters are off in this build; not read\n"))
      (uv-loop-teardown! loop))))
