#!r6rs
;;; The programs under examples/, each run as a process of its own, as a
;;; reader runs them, and asked for pages over loopback.
;;;
;;; Each example is started with the Chez the environment's CHEZ names, or
;;; `chez`, with CHEZ_HTTP_HOST=127.0.0.1 and CHEZ_HTTP_PORT=0 in its
;;; environment, so it listens where the kernel says; the suite reads the
;;; port from the `listening` line `serve` writes, asks its questions with
;;; clients on a loop of its own, each wait capped by an iteration count, and
;;; kills the process after.  A response is read back by chez-httparse's
;;; response parser (tests/response-reader.sls).
;;;
;;; Oracles:
;;;   - examples/README.org, which says what each example answers;
;;;   - for examples/file-server.sps, Python's `python3 -m http.server`,
;;;     which it copies: a directory's listing, or its index.html; a
;;;     directory asked for without its slash redirected to it (301); a
;;;     file with the type its name's extension says; 404 for what is not
;;;     there; `.` and `..` segments dropped, so no request leaves the
;;;     directory it serves; GET and HEAD, and 501 for any other method;
;;;   - the files the suite writes into build/examples-root, a tree of its
;;;     own: their bytes are what a file's response must carry.
(import (rnrs) (srfi :64) (testing)
        (only (chezscheme) putenv getenv mkdir directory-list file-directory?
              delete-directory)
        (libuv) (uv-testing) (shell-testing) (response-reader))

(define (b s) (string->utf8 s))

(define cap 8192)

;; The tree file-server.sps serves.
(define root "build/examples-root")

;; big-size : Nat — over the 1 MiB file-server.sps reads whole, so a file this
;; long is streamed.
(define big-size 1100000)

;; big-byte : Nat -> Nat — the byte at `i` in the big file.
(define (big-byte i) (mod (* i 7) 251))

;; remove-tree! : String -> Void — `path` and everything under it, if it exists.
(define (remove-tree! path)
  (cond ((file-directory? path)
         (for-each (lambda (name) (remove-tree! (string-append path "/" name)))
                   (directory-list path))
         (delete-directory path))
        ((file-exists? path) (delete-file path))))

;; write-file! : String Bytevector -> Void
(define (write-file! path bytes)
  (let ((port (open-file-output-port path (file-options no-fail))))
    (put-bytevector port bytes)
    (close-port port)))

;; make-root! : -> Void
;; build/examples-root, fresh: hello.txt, page.html, "with space.txt",
;; data.json, big.bin (big-size bytes), served/ (with an index.html),
;; listed/ (without one, holding inner.txt), and .hidden.
(define (make-root!)
  (unless (file-directory? "build") (mkdir "build"))
  (remove-tree! root)
  (mkdir root)
  (write-file! (string-append root "/hello.txt") (b "hello\n"))
  (write-file! (string-append root "/page.html") (b "<p>page</p>\n"))
  (write-file! (string-append root "/with space.txt") (b "spaced\n"))
  (write-file! (string-append root "/data.json") (b "{\"a\":1}\n"))
  (write-file! (string-append root "/.hidden") (b "hidden\n"))
  (let ((big (make-bytevector big-size)))
    (do ((i 0 (+ i 1))) ((= i big-size)) (bytevector-u8-set! big i (big-byte i)))
    (write-file! (string-append root "/big.bin") big))
  (mkdir (string-append root "/served"))
  (write-file! (string-append root "/served/index.html") (b "<p>index</p>\n"))
  (mkdir (string-append root "/listed"))
  (write-file! (string-append root "/listed/inner.txt") (b "inner\n")))

;; with-example : String (Listof String) (UvLoop (U Nat #f) Symbol -> Any) -> Any
;; Start examples/`name`.sps with `args` as a process of its own, its
;; standard output collected, and wait until it logs where it listens.  Call
;; `body` with the loop, the port (#f if it never said), and how the wait
;; ended.  Then the process is killed, everything closed and the loop torn
;; down, answering what `body` answered.
(define (with-example name args body)
  (let* ((loop (make-uv-loop))
         (pipe (make-uv-pipe loop))
         (out (make-byte-collector))
         (exit-status #f)
         (chez (or (getenv "CHEZ") "chez"))
         (process (uv-spawn! loop chez
                             (append (list chez "--program" (string-append "examples/" name ".sps")) args)
                             (list (cons 'stdio (list 'ignore (list 'pipe pipe 'from-child)
                                                      '(inherit-fd . 2))))
                             (lambda (status signal) (set! exit-status (list status signal))))))
    (uv-read-start! pipe (lambda (bv start end) (collect-span! out bv start end))
                    (lambda () #f) (lambda (e) #f))
    (let* ((port (lambda () (listening-port (utf8->string (collector-bytes out)))))
           (listening (run-loop-until loop (lambda () (or (port) exit-status)) cap))
           (answer (body loop (port) (if (port) listening 'exited))))
      (unless exit-status
        (uv-process-kill! process 'sigkill)
        (run-loop-until loop (lambda () exit-status) cap))
      (uv-close! process)
      (uv-close! pipe)
      (run-until-drained loop cap)
      (uv-loop-teardown! loop)
      answer)))

;; fetch : UvLoop Nat String Boolean -> (U (List Nat (Listof (Pair String String)) String) Symbol)
;; Send `request` (its head and body as one string) and read until the
;; server closes, then the status, the headers and the body, by
;; chez-httparse's response parser (`head?` for the answer to a HEAD); or
;; how the wait ended, if the stream never did.
(define (fetch loop port request head?)
  (let* ((cl (open-client loop port (b request) #t))
         (ended (run-loop-until loop (lambda () (not (eq? (client-end cl) 'open))) cap))
         (bytes (client-bytes cl)))
    (client-close! cl)
    (if (eq? ended 'satisfied)
        (let ((r (read-response bytes head? #t)))
          (list (car r) (caddr r) (cadddr r)))
        ended)))

;; get : UvLoop Nat String -> as fetch — `GET target`, the connection closed after.
(define (get loop port target)
  (fetch loop port (string-append "GET " target " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") #f))

;; header : (List Nat Headers String) String -> (U String #f) — a field, by any case.
(define (header response name)
  (let ((hit (find (lambda (h) (string-ci=? (car h) name)) (cadr response))))
    (and hit (cdr hit))))

;; status-of / body-of : the response's status and body, or what fetch answered instead.
(define (status-of r) (if (pair? r) (car r) r))
(define (body-of r) (if (pair? r) (caddr r) r))

;; contains? : String String -> Boolean
(define (contains? s part)
  (let ((n (string-length s)) (m (string-length part)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) part) #t)
            (else (loop (+ i 1)))))))

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

;; big-body-ok? : String -> (U 'same Datum) — whether a body is the big file's bytes.
(define (big-body-ok? body)
  (cond ((not (string? body)) body)
        ((not (= (string-length body) big-size)) (list 'length (string-length body)))
        (else (let loop ((i 0))
                (cond ((= i big-size) 'same)
                      ((= (char->integer (string-ref body i)) (big-byte i)) (loop (+ i 1)))
                      (else (list 'differs-at i)))))))

(putenv "CHEZ_HTTP_HOST" "127.0.0.1")
(putenv "CHEZ_HTTP_PORT" "0")

(run-suite "examples"
  (lambda ()
    (with-example "hello" '()
      (lambda (loop port listening)
        (test-eq "hello: it listens" 'satisfied listening)
        (when port
          (let ((r (get loop port "/")))
            (test-equal "hello: GET / is 200 Hello" '(200 "Hello\n") (list (status-of r) (body-of r)))))))

    (with-example "echo" '()
      (lambda (loop port listening)
        (test-eq "echo: it listens" 'satisfied listening)
        (when port
          (let ((r (fetch loop port (string-append "POST /anything HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
                                                   "Content-Type: text/plain\r\nContent-Length: 5\r\n\r\nabcde")
                          #f)))
            (test-equal "echo: a POST's body comes back, with its type"
                        '(200 "abcde" "text/plain")
                        (list (status-of r) (body-of r) (and (pair? r) (header r "content-type")))))
          (let ((r (get loop port "/a/b?c=1")))
            (test-equal "echo: a GET is told its method, path and query"
                        '(200 "GET /a/b?c=1\n")
                        (list (status-of r) (body-of r)))))))

    (with-example "stream" '()
      (lambda (loop port listening)
        (test-eq "stream: it listens" 'satisfied listening)
        (when port
          (let ((r (get loop port "/count?n=3")))
            (test-equal "stream: /count?n=3 streams three lines, chunked"
                        '(200 "1\n2\n3\n" "chunked")
                        (list (status-of r) (body-of r) (and (pair? r) (header r "transfer-encoding")))))
          (let ((r (get loop port "/ticks?n=2&ms=10")))
            (test-equal "stream: /ticks?n=2&ms=10 sends two events, as text/event-stream"
                        '(200 "data: tick 1\n\ndata: tick 2\n\n" "text/event-stream")
                        (list (status-of r) (body-of r) (and (pair? r) (header r "content-type"))))))))

    (with-example "long-poll" '()
      (lambda (loop port listening)
        (test-eq "long-poll: it listens" 'satisfied listening)
        (when port
          (let* ((waiter (open-client loop port (b "GET /wait HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") #t))
                 ;; A send that wakes no one came before the wait was in:
                 ;; send again, a fresh client each time, up to 50 times.
                 (woke (let try ((n 0))
                         (let ((r (fetch loop port (string-append "POST /send HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
                                                                  "Content-Length: 2\r\n\r\nhi")
                                         #f)))
                           (if (or (= n 50) (not (equal? (body-of r) "woke 0\n"))) (body-of r) (try (+ n 1))))))
                 (ended (run-loop-until loop (lambda () (not (eq? (client-end waiter) 'open))) cap))
                 (r (and (eq? ended 'satisfied) (read-response (client-bytes waiter) #f #t))))
            (client-close! waiter)
            (test-equal "long-poll: a POST /send wakes the GET /wait, which answers with its body"
                        '("woke 1\n" 200 "hi")
                        (list woke (and r (car r)) (and r (cadddr r))))))))

    (make-root!)
    (with-example "file-server" (list "--directory" root)
      (lambda (loop port listening)
        (test-eq "file-server: it listens" 'satisfied listening)
        (when port
          (let ((r (get loop port "/hello.txt")))
            (test-equal "file-server: a file, its bytes, length and type"
                        '(200 "hello\n" "6" "text/plain")
                        (list (status-of r) (body-of r) (and (pair? r) (header r "content-length"))
                              (and (pair? r) (header r "content-type")))))
          (test-equal "file-server: the type follows the extension"
                      '("text/html" "application/json")
                      (map (lambda (t) (let ((r (get loop port t))) (and (pair? r) (header r "content-type"))))
                           '("/page.html" "/data.json")))
          (let ((r (get loop port "/with%20space.txt")))
            (test-equal "file-server: a name is percent-decoded" '(200 "spaced\n")
                        (list (status-of r) (body-of r))))
          (let ((r (get loop port "/")))
            (test-equal "file-server: a directory with no index.html is listed, each name linked, a directory's with its slash"
                        '(200 #t #t #t #t #t)
                        (list (status-of r)
                              (and (pair? r) (contains? (body-of r) "Directory listing for /"))
                              (and (pair? r) (contains? (body-of r) "<a href=\"hello.txt\">hello.txt</a>"))
                              (and (pair? r) (contains? (body-of r) "<a href=\"with%20space.txt\">with space.txt</a>"))
                              (and (pair? r) (contains? (body-of r) "<a href=\"listed/\">listed/</a>"))
                              (and (pair? r) (contains? (body-of r) "<a href=\".hidden\">.hidden</a>")))))
          (let ((r (get loop port "/listed/")))
            (test-equal "file-server: a subdirectory's listing names its own files"
                        '(200 #t #t)
                        (list (status-of r)
                              (and (pair? r) (contains? (body-of r) "Directory listing for /listed/"))
                              (and (pair? r) (contains? (body-of r) "<a href=\"inner.txt\">inner.txt</a>")))))
          (let ((r (get loop port "/served/")))
            (test-equal "file-server: a directory with an index.html is served it" '(200 "<p>index</p>\n")
                        (list (status-of r) (body-of r))))
          (let ((r (get loop port "/served")))
            (test-equal "file-server: a directory without its slash is redirected to it"
                        '(301 "/served/") (list (status-of r) (and (pair? r) (header r "location")))))
          (let ((r (get loop port "/served?x=1")))
            (test-equal "file-server: the redirect keeps the query"
                        '(301 "/served/?x=1") (list (status-of r) (and (pair? r) (header r "location")))))
          (test-equal "file-server: what is not there is 404, and so is a file asked for as a directory"
                      '(404 404 404)
                      (map (lambda (t) (status-of (get loop port t))) '("/nope.txt" "/listed/nope/" "/hello.txt/")))
          (let ((r (get loop port "/listed/%2e%2e/%2e%2e/%2e%2e/Makefile")))
            (test-equal "file-server: .. segments are dropped, so a request stays inside the directory"
                        404 (status-of r)))
          (let ((r (get loop port "/listed/../hello.txt")))
            (test-equal "file-server: .. never climbs: /listed/../hello.txt is /listed/hello.txt"
                        404 (status-of r)))
          (let ((r (fetch loop port "HEAD /hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" #t)))
            (test-equal "file-server: HEAD gets the length and no body"
                        '(200 "6" "") (list (status-of r) (and (pair? r) (header r "content-length")) (body-of r))))
          (let ((r (fetch loop port "DELETE /hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" #f)))
            (test-equal "file-server: any other method is 501" 501 (status-of r)))
          (let ((r (get loop port "/big.bin")))
            (test-equal "file-server: a file over 1 MiB is streamed, chunked, byte for byte"
                        '(200 "chunked" #f same)
                        (list (status-of r) (and (pair? r) (header r "transfer-encoding"))
                              (and (pair? r) (header r "content-length"))
                              (big-body-ok? (body-of r))))))))
    (remove-tree! root)))
