#!r6rs
;;; Real clients: curl, ab and vtest against the server.  The M4 exit (plan
;;; §8), and M8.3's black-box lane (plan §14): vtest2's scripts.
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
;;;     none is;
;;;   - the M6 exit's 16 MiB each way (plan §14): every byte, checked a piece
;;;     at a time against its piece's letter; the server's heap, read after
;;;     two full collections as the M4 exit read a connection's (its budget
;;;     spike), the client in a process of its own; and the bytes a
;;;     connection has written and not yet seen completed, against decision
;;;     0005's water marks;
;;;   - vtest's verdict on each of tests/vtc/*.vtc (M8.3): a script is a
;;;     client's exchanges and what it expects of each answer, written from
;;;     RFC 9112 and the decisions before it first ran, and read by vtest's
;;;     own HTTP/1 code, which is neither curl's nor chez-httparse's.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) collect collect-maximum-generation bytes-allocated getenv directory-list)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server limits) default-limits limits-read-buffer-size
              limits-write-high-water limits-write-low-water)
        (only (http-server connection) conn-outstanding-bytes)
        (only (http-server private shell) shell-connections shell-listener shell-shutdown! shell-timer
              connection-state)
        (only (http-server private serve) start-server)
        (rename (only (libuv private native) live-counts) (live-counts debug-live-counts))
        (producers)
        (only (corpus-text) prefix? suffix? split trim find-sub))

(define (b s) (string->utf8 s))

;; The cap on every wait.  All of this suite's clients together take about
;; 700 iterations (2026-09-27, Darwin arm64), and each 16 MiB run, the M6
;; exit's, 324 to 1,021 more (2026-10-02, Darwin arm64 and Linux aarch64).
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
;; tests/producers.sls), and `/sixteen` moves the M6 exit's 16 MiB (below).
(define (handler r)
  (if (string=? (request-path r) "/sixteen")
      (sixteen r)
      (let ((answer (make-response 200 #f '()
                                   (if (string=? (request-path r) "/stream")
                                       (producer-of '("one " "two " "three"))
                                       (b (string-append (request-path r) " " (or (request-query r) "-") "\n"))))))
        (if (eq? (request-method r) 'POST)
            (read-body (lambda (bv start end) #t) (lambda () answer))
            answer))))

;; --- 16 MiB each way (the M6 exit) ---
;;
;; The 16 MiB are 1,024 pieces of 16 KiB, the k-th filled with the k-th
;; letter (mod 26) from `a`, as sized-producer makes them.
(define sixteen-size 16384)
(define sixteen-count 1024)

;; make-checker : -> (Pair (Bytevector Nat Nat -> Void) (-> (List Nat Nat)))
;; What the 16 MiB are handed to as they arrive, keeping none of them: a
;; procedure taking each run of them, bv[start, end), and one answering the
;; bytes taken and how many of them were not their piece's letter.
(define (make-checker)
  (let ((taken 0) (wrong 0))
    (cons (lambda (bv start end)
            (let check ((i start))
              (when (< i end)
                ;; bv[i, stop) is the rest of the k-th piece, or the run's end.
                (let* ((at (+ taken (- i start)))
                       (k (div at sixteen-size))
                       (stop (min end (+ i (- (* (+ k 1) sixteen-size) at))))
                       (letter (+ 97 (mod k 26))))
                  (let scan ((j i))
                    (cond ((= j stop) (check stop))
                          ((fx=? (bytevector-u8-ref bv j) letter) (scan (+ j 1)))
                          (else (set! wrong (+ wrong 1)) (scan (+ j 1))))))))
            (set! taken (+ taken (- end start))))
          (lambda () (list taken wrong)))))

;; The largest piece the server's reader was handed.
(define sixteen-largest 0)

;; sixteen : Request -> (U Response BodyReader)
;; A GET is answered with the 16 MiB, streamed a piece at a time; any other
;; request's body is read as it arrives, checked and kept nowhere, and
;; answered with the bytes taken and the bytes wrong.
(define (sixteen r)
  (if (eq? (request-method r) 'GET)
      (make-response 200 #f '() (sized-producer sixteen-count sixteen-size))
      (let ((checker (make-checker)))
        (set! sixteen-largest 0)
        (read-body (lambda (bv start end)
                     (set! sixteen-largest (max sixteen-largest (- end start)))
                     ((car checker) bv start end))
                   (lambda ()
                     (let ((took ((cdr checker))))
                       (make-response 200 #f '()
                                      (b (string-append (number->string (car took)) " "
                                                        (number->string (cadr took)) "\n")))))))))

;; A client run as a child: its process, the pipe its standard output is
;; read through, the pipe the suite writes its standard input through or
;; #f, what it wrote, its exit, as (status signal), and whether its output
;; has ended.
(define-record-type child
  (fields process pipe in out (mutable exit) (mutable ended?)))

;; spawn : UvLoop String (Listof String) [(U (UvPipe -> Any) #f) (U (Bytevector Nat Nat -> Any) #f)] -> Child
;; Start `file` with `args` on `loop`, its standard input empty, or a pipe
;; handed to `give` once the child has started, for the suite to write; its
;; standard output read into the child's collector, or handed to `take` a
;; read at a time and not kept; its standard error the suite's.  A child
;; that cannot be started raises, its name on standard error.
(define spawn
  (case-lambda
    ((loop file args) (spawn loop file args #f #f))
    ((loop file args give take)
     (let ((pipe (make-uv-pipe loop)) (in (and give (make-uv-pipe loop))) (out (make-byte-collector)) (c #f))
       (let ((process
              (guard (e (#t (uv-close! pipe)
                            (when in (uv-close! in))
                            (let ((p (current-error-port)))
                              (put-string p (string-append "clients: cannot start " file
                                                           "; it is a test tool, see tests/test-clients.sps\n"))
                              (flush-output-port p))
                            (raise e)))
                (uv-spawn! loop file (cons file args)
                           (list (cons 'stdio (list (if in (list 'pipe in 'to-child) 'ignore)
                                                    (list 'pipe pipe 'from-child) '(inherit-fd . 2))))
                           (lambda (status signal) (child-exit-set! c (list status signal)))))))
         (set! c (make-child process pipe in out #f #f))
         (uv-read-start! pipe
                         (or take (lambda (bv start end) (collect-span! out bv start end)))
                         (lambda () (child-ended?-set! c #t))
                         (lambda (e) (child-ended?-set! c #t)))
         (when give (give in))
         c)))))

;; run : UvLoop Shell String (Listof String) [(U Procedure #f) (U Procedure #f) (-> Any) Nat]
;;       -> (List Symbol (List Nat Any) String)
;; Run a client to its end while the server serves: how the wait ended, the
;; client's exit, and what it wrote.  One still running at the cap is killed.
;; `give` and `take` are spawn's; `watch` is called before each look at
;; whether the client has ended, and `steps` caps the wait.
(define run
  (case-lambda
    ((loop sh file args) (run loop sh file args #f #f (lambda () #f) cap))
    ((loop sh file args give take watch steps)
     (let* ((c (spawn loop file args give take))
            (outcome (run-shell-until loop sh (lambda () (watch) (and (child-exit c) (child-ended? c))) steps)))
       (unless (child-exit c)
         (uv-process-kill! (child-process c) 'sigkill)
         (run-shell-until loop sh (lambda () (child-exit c)) cap))
       (uv-close! (child-process c))
       (for-each (lambda (p) (when (and p (uv-handle-open? p)) (uv-close! p)))
                 (list (child-pipe c) (child-in c)))
       (list outcome (child-exit c) (utf8->string (collector-bytes (child-out c))))))))

;; heap : -> Nat — the bytes the server's heap holds after two full
;; collections, as the M4 exit read a connection's (its budget spike).
(define (heap)
  (collect (collect-maximum-generation))
  (collect (collect-maximum-generation))
  (bytes-allocated))

;; make-watch : UvLoop Shell Nat -> (Pair (-> Void) (-> (List Nat Nat Nat)))
;; A watch for run, and what it saw: the heap, read every `every-ms` by the
;; loop's clock, and the bytes each connection has written and not yet seen
;; completed, read at every look, which chez-libuv holds outside the heap
;; (design §7.3).  It answers the most heap read, how many readings, and the
;; most bytes outstanding.
(define (make-watch loop sh every-ms)
  (let ((most-heap 0) (readings 0) (most-out 0) (next 0))
    (cons (lambda ()
            (for-each (lambda (c)
                        (set! most-out (max most-out (conn-outstanding-bytes (connection-state c)))))
                      (shell-connections sh))
            (when (>= (uv-now loop) next)
              (set! most-heap (max most-heap (heap)))
              (set! readings (+ readings 1))
              (set! next (+ (uv-now loop) every-ms))))
          (lambda () (list most-heap readings most-out)))))

;; feed! : UvPipe -> Void
;; Write the 16 MiB to `in` a piece at a time, each once the one before it
;; is written, so one piece at a time is held, then close it.
(define (feed! in)
  (let next ((k 0))
    (if (= k sixteen-count)
        (uv-close! in)
        (uv-write! in (make-bytevector sixteen-size (+ 97 (mod k 26)))
                   (lambda (err) (if err (uv-close! in) (next (+ k 1))))))))

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

;; --- vtest (M8.3) ---
;;
;; vtest2 is built at its pin by `make vtest` (decision 0017); VTEST names
;; another build.  Its scripts run against a server of the lane's own, on a
;; loop of its own, whose deadlines are a second each and whose bodies are
;; capped at 1 KiB, so its timeouts and limits act within a run.  vtest
;; gives each script 5 s (`-t`), the longest taking 1.24 s, so twelve that
;; hang end within the suite's 120 s, each with vtest's own verdict.
(define vtest (or (getenv "VTEST") "build/vtest"))

;; The scripts, each with the verdict it is held to: the lane's manifest,
;; gated both ways against tests/vtc, as M1's ratchet gates its fixtures.
(define vtc-manifest
  '(("chunked-upload.vtc" . passed) ("expect.vtc" . passed) ("framing.vtc" . passed)
    ("head.vtc" . passed) ("http10.vtc" . passed) ("keep-alive.vtc" . passed)
    ("limits.vtc" . passed) ("redirect.vtc" . passed) ("stream.vtc" . passed)
    ("timeouts.vtc" . passed) ("upgrade.vtc" . passed) ("version.vtc" . passed)))

;; vtc-file? : String -> Boolean
;; A script's name: one ending .vtc, but no dotfile, such as the lock file
;; an editor keeps beside a script it has changed (the review's seventh).
(define (vtc-file? name)
  (and (not (prefix? "." name)) (suffix? ".vtc" name)))

;; vtc-faults : String String -> (Listof String)
;; What the script `name`, its text `text`, breaks of the two rules the
;; lane's verdicts rest on: each rxresp is followed by a check of the
;; answer's status, or vtest reads stray content as the next status line
;; and checks the rest (M8B-D1); and each client is run, `-run` at its
;; block's end, or `-start` there and `-wait` after it, or it never
;; connects and its script passes having checked nothing (the review's
;; sixth).
(define (vtc-faults name text)
  (let loop ((ls (map trim (split text #\newline))) (n 1) (client #f) (started '()) (faults '()))
    (if (null? ls)
        (append (reverse faults)
                (map (lambda (c) (string-append name ": client " c " is started and never waited for"))
                     (reverse started)))
        (let ((l (car ls)) (rest (cdr ls)))
          (define (word k) (list-ref (filter (lambda (w) (> (string-length w) 0)) (split l #\space)) k))
          (cond
           ((and (prefix? "client " l) (suffix? "{" l))
            (loop rest (+ n 1) (word 1) started faults))
           ((and client (prefix? "}" l))
            (cond ((string=? l "} -run") (loop rest (+ n 1) #f started faults))
                  ((string=? l "} -start") (loop rest (+ n 1) #f (cons client started) faults))
                  (else (loop rest (+ n 1) #f started
                              (cons (string-append name ": client " client " is never run") faults)))))
           ((and (prefix? "client " l) (suffix? "-wait" l))
            (loop rest (+ n 1) client (remove (word 1) started) faults))
           ((and (or (string=? l "rxresp") (prefix? "rxresp " l))
                 (not (and (pair? rest) (prefix? "expect resp.status" (car rest)))))
            (loop rest (+ n 1) client started
                  (cons (string-append name ": line " (number->string n) ": rxresp with no status check after it")
                        faults)))
           (else (loop rest (+ n 1) client started faults)))))))

;; file-text : String -> String — a file's text, as UTF-8.
(define (file-text path)
  (let* ((p (open-file-input-port path)) (bv (get-bytevector-all p)))
    (close-port p)
    (if (eof-object? bv) "" (utf8->string bv))))

;; vtc-handler : Request -> (U Response BodyReader)
;; The clients' handler, but a POST's body is echoed whole, so a script
;; reads back the body the server read.
(define (vtc-handler r)
  (if (eq? (request-method r) 'POST)
      (read-whole-body (lambda (body) (make-response 200 #f '() body)))
      (handler r)))

;; vtc-verdict : (List Symbol (List Nat Any) String) -> (U 'passed List)
;; A vtest run as its verdict: 'passed when vtest ran to its end and exited
;; 0; else how the wait ended, the exit, and the lines vtest's log marks as
;; a failure's, which begin "----", with "TIMED OUT" for a script vtest
;; killed at its test timeout, which leaves none.
(define (vtc-verdict run)
  (if (equal? (list (car run) (cadr run)) '(satisfied (0 #f)))
      'passed
      (let ((log (lines (caddr run))))
        (list (car run) (cadr run)
              (append (filter (lambda (l) (starts? "----" l)) log)
                      (if (exists (lambda (l) (find-sub l "TIMED OUT")) log) '("TIMED OUT") '()))))))

(define curl-out "%{http_code} %{num_connects} %{size_download}\\n")

(run-suite "clients"
  (lambda ()
    (let* ((loop (make-uv-loop))
           (sh (start-server loop handler (env '("CHEZ_HTTP_PORT" . "0")) log!))
           (port (caddr (assq 'listening logged)))
           (url (lambda (path) (string-append "http://127.0.0.1:" (number->string port) path))))
      (require-client! loop sh "curl" "--version")
      (require-client! loop sh "ab" "-V")

      ;; --- vtest (M8.3) ---
      ;; Every script is run before any check, so a vtest that cannot be
      ;; started raises outside them: the harness's status, 2.  The lane's
      ;; loop is torn down before the suite's own handles are counted.
      (let* ((vloop (make-uv-loop))
             (vlogged '())
             (vsh (start-server vloop vtc-handler
                                (env '("CHEZ_HTTP_PORT" . "0")
                                     '("CHEZ_HTTP_READ_HEADER_TIMEOUT" . "1")
                                     '("CHEZ_HTTP_IDLE_TIMEOUT" . "1")
                                     '("CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT" . "1")
                                     '("CHEZ_HTTP_MAX_BODY_BYTES" . "1024"))
                                (lambda (what details) (set! vlogged (append vlogged (list (cons what details)))))))
             (port-macro (string-append "port=" (number->string (caddr (assq 'listening vlogged)))))
             (files (list-sort string<? (filter vtc-file? (directory-list "tests/vtc"))))
             (verdicts (map (lambda (f)
                              (cons f (vtc-verdict
                                       (run vloop vsh vtest
                                            (list "-t" "5" "-D" "host=127.0.0.1" "-D" port-macro
                                                  (string-append "tests/vtc/" f))))))
                            files)))
        ;; What the verdicts rest on, read off each script's text.
        (test-equal "vtest: the lane leaves out a dotfile, as an editor's lock file is, and a backup's name"
                    '(#t #f #f) (map vtc-file? '("keep-alive.vtc" ".#keep-alive.vtc" "keep-alive.vtc~")))
        (test-equal "vtest: the rules' reader names an rxresp with no status check, a client never run, one never waited for"
                    '("x.vtc: line 3: rxresp with no status check after it"
                      "x.vtc: client c1 is never run"
                      "x.vtc: client c2 is started and never waited for")
                    (vtc-faults "x.vtc" (string-append "vtest \"x\"\nclient c1 -connect \"h p\" {\n    rxresp\n"
                                                        "    expect resp.body == \"a\"\n}\n"
                                                        "client c2 -connect \"h p\" {\n    txreq\n} -start\n")))
        ;; How a run is read: vtest marks a failure's lines "----", and a
        ;; script it kills at its test timeout only "TIMED OUT".
        (test-equal "vtest: a run is passed only at exit 0; else its ---- lines, and TIMED OUT for one vtest killed"
                    '(passed
                      (satisfied (2 #f) ("---- c1    EXPECT resp.status (404) == \"200\" failed"))
                      (satisfied (2 #f) ("TIMED OUT")))
                    (map vtc-verdict
                         (list (list 'satisfied '(0 #f) "#    top  TEST tests/vtc/x.vtc passed (0.131)\n")
                               (list 'satisfied '(2 #f) (string-append "**** c1    EXPECT resp.status (404) == \"200\"\n"
                                                                       "---- c1    EXPECT resp.status (404) == \"200\" failed\n"))
                               (list 'satisfied '(2 #f) (string-append "#    top  TEST tests/vtc/x.vtc TIMED OUT (kill -9)\n"
                                                                       "#    top  TEST tests/vtc/x.vtc FAILED (5.002) signal=9\n")))))
        (test-equal "vtest: every script checks each answer's status and runs every client" '()
                    (apply append (map (lambda (f) (vtc-faults f (file-text (string-append "tests/vtc/" f)))) files)))
        (for-each (lambda (v)
                    (unless (member v vtc-manifest)
                      (let ((p (current-error-port)))
                        (put-string p "VTEST ") (write v p) (newline p) (flush-output-port p))))
                  verdicts)
        (test-equal "vtest: the scripts in tests/vtc are the manifest's" (map car vtc-manifest) files)
        (test-equal "vtest: each script meets the verdict the manifest lists" vtc-manifest verdicts)
        (test-eq "and every connection the scripts opened leaves the table" 'satisfied
                 (run-shell-until vloop vsh (lambda () (null? (shell-connections vsh))) cap))
        (shell-shutdown! vsh)
        (run-until-drained vloop cap)
        (test-equal "the lane's server logged where it listens, then a drain with no connection open, and nothing else"
                    '(listening (draining 0) (stopped))
                    (map (lambda (e) (if (eq? (car e) 'listening) 'listening e)) vlogged))
        (test-equal "shut down, nothing of the lane's server is left on its loop" '() (uv-loop-live-handles vloop))
        (uv-loop-teardown! vloop))

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

      ;; --- 16 MiB each way, against a slow peer (the M6 exit) ---
      ;; curl sends 16 MiB, chunked from its standard input, which the suite
      ;; writes a piece at a time, then reads 16 MiB streamed back, each at
      ;; 16 MiB/s (--limit-rate), so curl is the slow end.  The server reads
      ;; the body as it arrives and keeps none of it, and streams the answer
      ;; from a producer of 16 KiB pieces; the suite takes curl's output a
      ;; read at a time and keeps none of it either.  As each moves, the
      ;; heap is read every 50 ms: five readings or more span 200 ms of it
      ;; at least.  Measured on 2026-10-02, curl took 14 to 21 readings to
      ;; move the 16 MiB at the limit, and two or three unlimited (Darwin
      ;; arm64 and Linux aarch64).  The bound, 1 MiB, is a sixteenth of
      ;; what moves; what grew was 32 to 83 KB (the ledger's M6 exit).
      (let* ((watch (make-watch loop sh 50))
             (before (heap))
             (r (run loop sh "curl" (list "-sS" "-f" "--limit-rate" "16M" "-T" "-" (url "/sixteen"))
                     feed! #f (car watch) cap))
             (saw ((cdr watch))))
        (test-equal "curl: 16 MiB sent at 16 MiB/s arrive in order, no read handing the reader more than the read buffer"
                    (list 'satisfied '(0 #f) "16777216 0\n" #t)
                    (list (car r) (cadr r) (caddr r)
                          (<= 1 sixteen-largest (limits-read-buffer-size default-limits))))
        (test-equal "and the server's heap, read throughout, grew by less than 1 MiB as they came in"
                    '(#t #t)
                    (list (>= (cadr saw) 5) (< (- (car saw) before) (* 1024 1024)))))
      ;; Streamed to it, the answer's writes back up behind curl: each piece
      ;; is a write of 16,392 bytes, its size line `4000` CRLF, the piece and
      ;; CRLF, and the producer is asked only while the bytes outstanding are
      ;; at or below the high water (decision 0005; M6.3).
      (let* ((checker (make-checker))
             (watch (make-watch loop sh 50))
             (before (heap))
             (r (run loop sh "curl" (list "-sS" "-f" "--limit-rate" "16M" (url "/sixteen"))
                     #f (car checker) (car watch) cap))
             (saw ((cdr watch)))
             (high (limits-write-high-water default-limits))
             (low (limits-write-low-water default-limits)))
        (test-equal "curl: 16 MiB streamed to it, read at 16 MiB/s, arrive in order"
                    (list 'satisfied '(0 #f) '(16777216 0))
                    (list (car r) (cadr r) ((cdr checker))))
        (test-equal "and the bytes written and not yet completed backed up past the low water, and never passed the high water by more than a piece's write"
                    '(#t #t)
                    (list (> (caddr saw) low) (<= (caddr saw) (+ high sixteen-size 8))))
        (test-equal "and the server's heap, read throughout, grew by less than 1 MiB as they went out"
                    '(#t #t)
                    (list (>= (cadr saw) 5) (< (- (car saw) before) (* 1024 1024)))))

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
