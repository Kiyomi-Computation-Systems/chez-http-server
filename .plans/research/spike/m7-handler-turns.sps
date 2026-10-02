#!r6rs
;;; M7, 2026-10-02: a server whose handler's code runs one of five ways, for
;;; m7-handler-turns.sh to load with ab and m7-handler-streams.sh with curl.
;;; `m7-handler-turns.sps MODE`:
;;;   default    the libuv shell, its loop run as `serve` runs it, uv-run in
;;;              'default: the handler called in place, inside the read;
;;;   once       the same shell, its loop run a uv-run 'once at a time, as a
;;;              scheduler's turn would: the cost of the turns alone;
;;;   coroutine  the prototype coroutine shell (m7/coroutine-shell.sls, made
;;;              by m7-coroutine-shell.patch), its loop (m7 scheduler)'s
;;;              turns: every handler called on a coroutine of its own, from
;;;              the drain after uv-run returns; a reader's pieces and end
;;;              and a producer's calls in place;
;;;   deferred   the same, its scheduler made plain: every handler called
;;;              from the drain after uv-run returns, in place, with no
;;;              coroutine: the control that tells the coroutine's cost from
;;;              the deferral's;
;;;   every      the prototype switched to every call (`every!`): the
;;;              handler, each piece and the end of a reader, and each call
;;;              of a producer, each on a coroutine of its own, from the
;;;              drain, the reader answered on credit;
;;;   every-all  the same, its scheduler made to drain all: a coroutine made
;;;              ready while the drain runs, a producer's next call among
;;;              them, runs in that drain, not the next turn's.
;;; Each listens on 127.0.0.1:0 with the default limits, prints `port N`, and
;;; serves until it is killed: `/up` reads the body, counting its bytes, and
;;; answers the count; `/down` streams 16 MiB, 1,024 pieces of 16 KiB from a
;;; producer handing out one bytevector; anything else is answered 200 with a
;;; 6-byte body.  Run on the project's library path with a directory holding
;;; m7/ after it.
(import (rnrs)
        (only (chezscheme) printf)
        (libuv)
        (only (http-server) request-path read-body)
        (only (http-server response) make-response)
        (only (http-server limits) default-limits)
        (prefix (only (http-server private shell) make-shell shell-listen! shell-run! wall-clock) direct:)
        (prefix (only (m7 coroutine-shell) make-shell shell-listen! shell-run! every!) coroutine:)
        (only (m7 scheduler) turn! plain! drain-all!))

(define mode (string->symbol (cadr (command-line))))
(define hello (string->utf8 "hello\n"))
(define piece (make-bytevector 16384 97))

(define (down)
  (let ((left 1024))
    (lambda ()
      (if (zero? left) (eof-object) (begin (set! left (- left 1)) piece)))))

(define (up)
  (let ((n 0))
    (read-body (lambda (bv start end) (set! n (+ n (- end start))))
               (lambda () (make-response 200 #f '() (string->utf8 (string-append (number->string n) "\n")))))))

(define (handler request)
  (let ((path (request-path request)))
    (cond ((string=? path "/up") (up))
          ((string=? path "/down") (make-response 200 #f '() (down)))
          (else (make-response 200 #f '() hello)))))

(define (log! what details) (printf "~a ~s\n" what details))

(call-with-uv-loop
 (lambda (loop)
   (case mode
     ((default once)
      (let ((sh (direct:make-shell loop handler default-limits direct:wall-clock log!)))
        (printf "port ~a\n" (direct:shell-listen! sh "127.0.0.1" 0))
        (flush-output-port (current-output-port))
        (let run () (when (direct:shell-run! sh mode) (run)))))
     ((coroutine deferred every every-all)
      (when (eq? mode 'deferred) (plain! #t))
      (when (memq mode '(every every-all)) (coroutine:every!))
      (when (eq? mode 'every-all) (drain-all! #t))
      (let ((sh (coroutine:make-shell loop handler default-limits direct:wall-clock log!)))
        (printf "port ~a\n" (coroutine:shell-listen! sh "127.0.0.1" 0))
        (flush-output-port (current-output-port))
        (let run () (when (turn! (lambda (m) (coroutine:shell-run! sh m))) (run)))))
     (else (assertion-violation 'm7-handler-turns "not a mode" mode)))))
