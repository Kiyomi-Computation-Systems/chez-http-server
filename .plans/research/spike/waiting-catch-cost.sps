#!r6rs
;;; docs/waiting.md's "Costs to know", 2026-10-25 (issue #231): what a catch
;;; costs a handler that answers `awaiting`, through the whole server, by the
;;; method of hoist-request-alloc.sps.
;;;
;;; One server, started as `serve` starts one, under the default limits,
;;; whose handler is the current VARIANT: `(awaiting thunk)`, the thunk an
;;; APP wrapped in a CATCH.  The apps answer one response built once, or
;;; raise, with or without one park, `(sleep-ms 0)`, first; a raise is
;;; Chez's `(error 'app "boom")`, whose condition carries the raise's
;;; continuation, or a `&error` built once and raised again, which carries
;;; none.  The catches are none; `guard`; `with-exception-handler` alone,
;;; raising again; and an escape by `call/cc`, or by `call/1cc`, around
;;; `with-exception-handler`.  A catch answers a 500 built once.  oha, in a
;;; process of its own, sends GETs on connections kept alive, 1 and 50 at a
;;; time; the loop is turned as `serve` turns it, shell-run-turns!, until oha
;;; has ended.  Each load is run with 5,000 GETs and with LARGE, 25,000
;;; unless given, alternating, and a request's bytes are the difference over
;;; the LARGE less 5,000 more.  Each variant is read over its baseline, the
;;; unwrapped app with the same park answering 200, in the same round: so a
;;; raise's row holds the condition and the catch.  `none-ok-again` is the
;;; baseline under another name, a control that should read 0.  The
;;; `-closure` rows make the thunk per request, closing over the request, as
;;; a handler's code usually does: the catch's own thunk then closes over it
;;; too, where the other rows' catches are handed the app itself.
;;;
;;;   chez --program waiting-catch-cost.sps OHA [ROUNDS [LARGE [VARIANT ...]]]
;;;
;;; VARIANTs, when named, are the only ones run, with their baselines.
;;;
;;; Run on the project's library path, from the repository's root.
(import (rnrs)
        (only (chezscheme) printf statistics sstats-bytes collect scheme-version machine-type
              open-process-ports native-transcoder call/1cc format)
        (libuv) (only (uv-testing) make-byte-collector collect-span! collector-bytes)
        (http-server)
        (only (http-server private shell) shell-run-turns!)
        (only (http-server private serve) start-server))

(define oha (cadr (command-line)))
(define rounds (if (> (length (command-line)) 2) (string->number (caddr (command-line))) 2))
(define large-count (if (> (length (command-line)) 3) (string->number (cadddr (command-line))) 25000))

(define ok-response (make-response 200 #f '() (string->utf8 "ok")))
(define failed-response (make-response 500 #f '() (string->utf8 "failed")))
(define made-once (make-error))

;;; The apps: thunks a handler's coroutine runs.
(define (ok) ok-response)
(define (ok-park) (sleep-ms 0) ok-response)
(define (boom) (error 'app "boom"))
(define (boom-park) (sleep-ms 0) (error 'app "boom"))
(define (plain) (raise made-once))
(define (plain-park) (sleep-ms 0) (raise made-once))

;;; The apps that read the request they answer.
(define (ok/request request) (and request ok-response))
(define (ok-park/request request) (sleep-ms 0) (and request ok-response))

;;; The catches: each takes an app and gives the thunk `awaiting` runs.
(define (none app) app)
(define (with-guard app)
  (lambda () (guard (e ((error? e) failed-response)) (app))))
(define (with-handler app)
  (lambda () (with-exception-handler (lambda (e) (raise e)) app)))
(define (with-escape/cc app)
  (lambda ()
    (call/cc (lambda (k) (with-exception-handler (lambda (e) (k failed-response)) app)))))
(define (with-escape/1cc app)
  (lambda ()
    (call/1cc (lambda (k) (with-exception-handler (lambda (e) (k failed-response)) app)))))

;;; The same, the thunk made per request and closing over it.
(define (none/closure app) (lambda (request) (lambda () (app request))))
(define (with-guard/closure app)
  (lambda (request) (lambda () (guard (e ((error? e) failed-response)) (app request)))))
(define (with-handler/closure app)
  (lambda (request) (lambda () (with-exception-handler (lambda (e) (raise e)) (lambda () (app request))))))

;; all-variants : (Listof (List String (U String #f) (U Thunk (Request -> Thunk))))
;; Name, baseline's name, and the thunk, or for a `-closure` row what makes
;; it from the request.
(define all-variants
  (list (list "none-ok" #f (none ok))
        (list "none-ok-park" #f (none ok-park))
        (list "none-ok-again" "none-ok" (none ok))
        (list "guard-ok" "none-ok" (with-guard ok))
        (list "guard-ok-park" "none-ok-park" (with-guard ok-park))
        (list "guard-error" "none-ok" (with-guard boom))
        (list "guard-error-park" "none-ok-park" (with-guard boom-park))
        (list "guard-plain" "none-ok" (with-guard plain))
        (list "guard-plain-park" "none-ok-park" (with-guard plain-park))
        (list "handler-ok" "none-ok" (with-handler ok))
        (list "handler-ok-park" "none-ok-park" (with-handler ok-park))
        (list "cc-ok" "none-ok" (with-escape/cc ok))
        (list "cc-ok-park" "none-ok-park" (with-escape/cc ok-park))
        (list "cc-error" "none-ok" (with-escape/cc boom))
        (list "cc-error-park" "none-ok-park" (with-escape/cc boom-park))
        (list "cc-plain" "none-ok" (with-escape/cc plain))
        (list "cc-plain-park" "none-ok-park" (with-escape/cc plain-park))
        (list "1cc-ok" "none-ok" (with-escape/1cc ok))
        (list "1cc-ok-park" "none-ok-park" (with-escape/1cc ok-park))
        (list "1cc-error" "none-ok" (with-escape/1cc boom))
        (list "1cc-error-park" "none-ok-park" (with-escape/1cc boom-park))
        (list "1cc-plain" "none-ok" (with-escape/1cc plain))
        (list "1cc-plain-park" "none-ok-park" (with-escape/1cc plain-park))
        (list "none-closure-ok" #f (none/closure ok/request))
        (list "none-closure-ok-park" #f (none/closure ok-park/request))
        (list "guard-closure-ok" "none-closure-ok" (with-guard/closure ok/request))
        (list "guard-closure-ok-park" "none-closure-ok-park" (with-guard/closure ok-park/request))
        (list "handler-closure-ok" "none-closure-ok" (with-handler/closure ok/request))
        (list "handler-closure-ok-park" "none-closure-ok-park" (with-handler/closure ok-park/request))))

;; variants : (Listof (List String (U String #f) (U Thunk (Request -> Thunk))))
;; The VARIANTs named on the command line and their baselines, or all.
(define variants
  (let ((named (if (> (length (command-line)) 4) (cddddr (command-line)) '())))
    (if (null? named)
        all-variants
        (filter (lambda (v)
                  (or (member (car v) named)
                      (exists (lambda (w) (and (member (car w) named) (equal? (cadr w) (car v))))
                              all-variants)))
                all-variants))))

;; closure? : String -> Boolean — whether the variant makes its thunk per request.
(define (closure? name)
  (let ((n (string-length name)))
    (let scan ((i 0))
      (cond ((> (+ i 8) n) #f) ((string=? (substring name i (+ i 8)) "-closure") #t) (else (scan (+ i 1)))))))

(define current (lambda (request) (caddr (car variants))))
(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         (lambda (request) (awaiting (current request)))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))
(define url (string-append "http://127.0.0.1:" (number->string port) "/"))

;; allocated : -> Nat — the bytes this process has allocated, all told.
(define (allocated) (sstats-bytes (statistics)))

;; load : Nat Nat -> (List Nat String)
;; oha's `n` GETs at `c` connections: the bytes allocated from its start to
;; its end, and oha's tallies, read off its report.
(define (load c n)
  (collect)
  (let* ((out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f)
         (b0 (allocated))
         (child (uv-spawn! loop oha
                           (list oha "--no-tui" "--output-format" "json" "-t" "10s"
                                 "-n" (number->string n) "-c" (number->string c) url)
                           (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child) '(inherit-fd . 2))))
                           (lambda (status signal) (set! exit (list status signal))))))
    (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
    (shell-run-turns! sh (lambda () (not exit)))
    (let ((b1 (allocated)))
      (uv-close! child)
      (uv-close! out)
      (list (- b1 b0) (tallies (utf8->string (collector-bytes said)))))))

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

;; per-request : Nat -> Real — one request's bytes for variant `v` at `c`
;; connections, its tallies printed.
(define (per-request v c)
  (set! current (if (closure? (car v)) (caddr v) (let ((thunk (caddr v))) (lambda (request) thunk))))
  (let* ((small (load c 5000)) (large (load c large-count)))
    (printf "  ~a, ~a conn: 5,000 ~a B, ~a ~a B, ~a\n" (car v) c (car small) large-count (car large) (cadr large))
    (/ (- (car large) (car small)) (- large-count 5000))))

(printf "~a, ~a (~a), libuv ~a, ~a\n"
        (let-values (((to from err pid) (open-process-ports "uname -srm" 'block (native-transcoder))))
          (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l))
        (scheme-version) (machine-type) (uv-version)
        (let-values (((to from err pid) (open-process-ports (string-append oha " --version") 'block (native-transcoder))))
          (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l)))
(load 1 2000)

;; results : (Listof (List Nat Nat String Real)) — round, connections,
;; variant, a request's bytes.
(define results
  (let each-round ((k 1) (acc '()))
    (if (> k rounds)
        (reverse acc)
        (each-round
         (+ k 1)
         (fold-left (lambda (acc c)
                      (fold-left (lambda (acc v) (cons (list k c (car v) (per-request v c)) acc))
                                 acc variants))
                    acc '(1 50))))))

;; bytes : Nat Nat String -> Real
(define (bytes k c name)
  (cadddr (find (lambda (r) (and (= (car r) k) (= (cadr r) c) (string=? (caddr r) name))) results)))

(define (range xs)
  (let ((lo (apply min xs)) (hi (apply max xs)))
    (if (= (round lo) (round hi))
        (format #f "~a" (round lo))
        (format #f "~a to ~a" (round lo) (round hi)))))

(define (round-numbers) (let count ((k rounds) (acc '())) (if (= k 0) acc (count (- k 1) (cons k acc)))))

(printf "\na request, and over its baseline, as the range over ~a rounds:\n" rounds)
(for-each
 (lambda (v)
   (printf "~a:" (car v))
   (for-each
    (lambda (c)
      (let ((own (map (lambda (k) (bytes k c (car v))) (round-numbers))))
        (printf "  ~a conn ~a B" c (range own))
        (when (cadr v)
          (printf " (over ~a: ~a B)" (cadr v)
                  (range (map (lambda (k) (- (bytes k c (car v)) (bytes k c (cadr v)))) (round-numbers)))))))
    '(1 50))
   (newline))
 variants)
(printf "logged: ~a\n" (map car (filter (lambda (e) (not (eq? (car e) 'listening))) logged)))
