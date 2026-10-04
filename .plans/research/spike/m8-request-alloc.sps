#!r6rs
;;; M8.4, 2026-10-04: what a request allocates through the whole server, the
;;; libuv shell and chez-libuv included, beside the connection core's share,
;;; which decision 0002's gate holds (the review's second finding).
;;;
;;; A server started as `serve` starts one, under the default limits, whose
;;; handler answers every request with one response built once, so the
;;; handler allocates nothing.  oha, in a process of its own, sends it GETs on
;;; connections kept alive, 1 and 50 at a time.  The bytes the server's
;;; process allocates are read off Chez's cumulative counter, `sstats-bytes`,
;;; as oha starts and once it has ended.  The loop is turned as `serve` turns
;;; it, `shell-turn!` after `shell-turn!` with nothing else on the loop, so
;;; what a turn costs is counted as `serve` pays it.  Each load is run with
;;; 5,000 GETs and with 25,000, alternating, so the difference over the
;;; 20,000 more leaves out what does not grow with the requests: starting
;;; oha, its connections and its report.
;;;
;;;   chez --program m8-request-alloc.sps OHA [ROUNDS]
;;;
;;; Run on the project's library path, from the repository's root.
(import (rnrs)
        (only (chezscheme) printf statistics sstats-bytes collect scheme-version machine-type
              open-process-ports native-transcoder)
        (libuv) (only (uv-testing) make-byte-collector collect-span! collector-bytes)
        (http-server)
        (only (http-server private shell) shell-turn!)
        (only (http-server private serve) start-server))

(define oha (cadr (command-line)))
(define rounds (if (> (length (command-line)) 2) (string->number (caddr (command-line))) 2))
(define response (make-response 200 #f '() (string->utf8 "ok")))
(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         (lambda (request) response)
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))
(define url (string-append "http://127.0.0.1:" (number->string port) "/"))

;; allocated : -> Nat — the bytes this process has allocated, all told.
(define (allocated) (sstats-bytes (statistics)))

;; load : Nat Nat -> (List Nat Nat String)
;; oha's `n` GETs at `c` connections: the bytes allocated from its start to
;; its end, the turns the loop took, and oha's tallies, read off its report.
(define (load c n)
  (collect)
  (let* ((out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f) (turns 0)
         (b0 (allocated))
         (child (uv-spawn! loop oha
                           (list oha "--no-tui" "--output-format" "json" "-t" "10s"
                                 "-n" (number->string n) "-c" (number->string c) url)
                           (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child) '(inherit-fd . 2))))
                           (lambda (status signal) (set! exit (list status signal))))))
    (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
    (let turn () (unless exit (shell-turn! sh) (set! turns (+ turns 1)) (turn)))
    (let ((b1 (allocated)))
      (uv-close! child)
      (uv-close! out)
      (list (- b1 b0) turns (tallies (utf8->string (collector-bytes said)))))))

;; tallies : String -> String — the report's two tallies, as written.
(define (tallies text)
  (let ((object (lambda (key)
                  (let ((at (find-text text (string-append "\"" key "\":"))))
                    (if at
                        (let close ((i at)) (if (char=? (string-ref text i) #\}) (substring text at (+ i 1)) (close (+ i 1))))
                        (string-append key ": none"))))))
    (string-append (squeeze (object "statusCodeDistribution")) " " (squeeze (object "errorDistribution")))))

;; find-text : String String -> (U Nat #f) — where `sub` first is in `s`.
(define (find-text s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let scan ((i 0))
      (cond ((> (+ i m) n) #f) ((string=? (substring s i (+ i m)) sub) i) (else (scan (+ i 1)))))))

;; squeeze : String -> String — the text with its runs of whitespace one space.
(define (squeeze s)
  (let walk ((cs (string->list s)) (acc '()) (space? #f))
    (cond ((null? cs) (list->string (reverse acc)))
          ((char-whitespace? (car cs)) (walk (cdr cs) (if space? acc (cons #\space acc)) #t))
          (else (walk (cdr cs) (cons (car cs) acc) #f)))))

(printf "~a, ~a (~a), libuv ~a, ~a\n"
        (let-values (((to from err pid) (open-process-ports "uname -srm" 'block (native-transcoder))))
          (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l))
        (scheme-version) (machine-type) (uv-version)
        (let-values (((to from err pid) (open-process-ports (string-append oha " --version") 'block (native-transcoder))))
          (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l)))
(load 1 2000)
(for-each
   (lambda (k)
     (for-each
      (lambda (c)
        (let* ((small (load c 5000)) (large (load c 25000))
               (bytes (- (car large) (car small))))
          (printf "round ~a, ~a connection~a: 5,000 GETs ~a B in ~a turns, ~a; 25,000 ~a B in ~a turns, ~a; a request ~a B\n"
                  k c (if (= c 1) "" "s")
                  (car small) (cadr small) (caddr small) (car large) (cadr large) (caddr large)
                  (round (/ bytes 20000)))))
      '(1 50)))
   (let count ((k rounds) (acc '())) (if (= k 0) acc (count (- k 1) (cons k acc)))))
