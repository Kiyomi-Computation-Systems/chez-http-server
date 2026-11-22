#!r6rs
;;; A program that serves, for tests/test-serve.sps to run as a process of its
;;; own: `serve` itself, its loop and all, which no suite can run in place,
;;; since it returns only when the server stops.  It listens on 127.0.0.1,
;;; the kernel's choice of port, which `serve` logs on standard output, and
;;; answers every request 200, "served", but three.  `/wait` writes the line
;;; `handling` on standard output and reads the request's body, answering
;;; "waited" at its end: the request stays in flight until the suite sends
;;; the body.  `/long` writes `holding`, then waits a minute, which the
;;; drain's deadline, 2 s, cuts short.  `/outside` waits outside, its
;;; `register` keeping the resume and raising, and answers "kept"; once
;;; `serve` has returned, the child calls the kept resume from a thread of
;;; its own and writes what it answered, `kept-resume #f` or `#t`, or
;;; `kept-resume raised`.  It serves until it is killed, or
;;; until a signal's drain ends and `serve` returns, when it exits 0;
;;; started with the argument `sigint-after`, it first sends itself SIGINT,
;;; and runs on a while, so that were a keyboard interrupt handled, it would
;;; be.  Started with `sigterm-at-listening`, it sends itself SIGTERM as
;;; `serve` writes the line `listening`, before that write returns: a
;;; supervisor that signals the moment it reads the line, with no gap.  Its
;;; lookup is its own, so the environment the suite runs in sets nothing
;;; here.  Run on the project's library path.
(import (rnrs) (http-server) (only (libuv) uv-kill! uv-os-getpid)
        (only (chezscheme) parameterize fork-thread thread-join)
        (rename (only (chezscheme) current-output-port) (current-output-port output-port-parameter)))

;; said : String -> Void — the line, on standard output, at once.
(define (said line)
  (put-string (current-output-port) line)
  (newline (current-output-port))
  (flush-output-port (current-output-port)))

;; signalling-at-listening : TextualOutputPort -> TextualOutputPort
;; A port writing through to `out`, flushed at once, that sends this
;; process SIGTERM once its first whole line has gone through, if that line
;; starts `listening `.
(define (signalling-at-listening out)
  (let ((first-line "") (done? #f))
    (make-custom-textual-output-port "signalling-at-listening"
      (lambda (s start count)
        (put-string out s start count)
        (flush-output-port out)
        (unless done?
          (set! first-line (string-append first-line (substring s start (+ start count))))
          (when (memv #\newline (string->list first-line))
            (set! done? #t)
            (when (and (>= (string-length first-line) 10)
                       (string=? (substring first-line 0 10) "listening "))
              (uv-kill! (uv-os-getpid) 'sigterm))))
        count)
      #f #f #f)))

;; The resume `/outside` kept, or #f.
(define kept #f)

;; serving : -> Void — `serve`, as the header says.
(define (serving)
  (serve (lambda (request)
           (cond ((string=? (request-path request) "/wait")
                  (said "handling")
                  (read-body (lambda (bv start end) #t)
                             (lambda () (make-response 200 #f '() (string->utf8 "waited")))))
                 ((string=? (request-path request) "/long")
                  (said "holding")
                  (awaiting (lambda () (sleep-ms 60000) (make-response 200 #f '() (string->utf8 "late")))))
                 ((string=? (request-path request) "/outside")
                  (awaiting (lambda ()
                              (guard (e ((eq? e 'kept) (make-response 200 #f '() (string->utf8 "kept"))))
                                (await-outside (lambda (resume) (set! kept resume) (raise 'kept)))))))
                 (else (make-response 200 #f '() (string->utf8 "served")))))
         (lambda (name)
           (cond ((string=? name "CHEZ_HTTP_HOST") "127.0.0.1")
                 ((string=? name "CHEZ_HTTP_PORT") "0")
                 ((string=? name "CHEZ_HTTP_DRAIN_TIMEOUT") "2")
                 (else #f)))))

(if (member "sigterm-at-listening" (command-line))
    (parameterize ((output-port-parameter (signalling-at-listening (current-output-port))))
      (serving))
    (serving))
(when kept
  (let* ((answer 'never-called)
         (t (fork-thread (lambda () (set! answer (guard (e (#t 'raised)) (kept "after")))))))
    (thread-join t)
    (said (string-append "kept-resume " (cond ((eq? answer #f) "#f") ((eq? answer #t) "#t") (else "raised"))))))
(when (member "sigint-after" (command-line))
  (uv-kill! (uv-os-getpid) 'sigint)
  (let spin ((i 0)) (when (< i 50000000) (spin (+ i 1)))))
(exit 0)
