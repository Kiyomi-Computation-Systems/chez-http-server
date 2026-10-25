#!r6rs
;;; docs/waiting.md's `dynamic-wind` bullet, 2026-10-25 (issue #231): what a
;;; wait does to a `dynamic-wind` around it, under the server.
;;;
;;; One server, started as `serve` starts one, whose handler answers by the
;;; request's path:
;;;   /wind      `awaiting`: a `dynamic-wind` around two waits, each thunk
;;;              noting when it runs;
;;;   /critical  `awaiting`: Chez's `critical-section`, a `dynamic-wind` that
;;;              disables interrupts, around a 300 ms wait; the
;;;              interrupt-disable count noted as it enters, as it resumes,
;;;              and once it has left;
;;;   /probe     in place, while /critical waits: its own disable count, and
;;;              the collections 64 MiB of allocation runs;
;;;   /control   the same inside a `critical-section` of its own: what /probe
;;;              would see had /critical's still been in force.
;;; One shell, spawned on the server's loop, runs curl at each in turn,
;;; /probe and /control 100 ms after /critical; the loop is turned as `serve`
;;; turns it until the shell has ended.
;;;
;;;   chez --program wait-dynamic-wind.sps
;;;
;;; Run on the project's library path, from the repository's root.
(import (rnrs)
        (only (chezscheme) printf critical-section disable-interrupts enable-interrupts
              collections collect-trip-bytes)
        (libuv)
        (http-server)
        (only (http-server private shell) shell-run-turns!)
        (only (http-server private serve) start-server))

(define ok (make-response 200 #f '() (string->utf8 "ok\n")))

;; notes : (Listof (Listof Any)) — what ran, latest first.
(define notes '())
(define (note! . what) (set! notes (cons what notes)))

;; disable-count : -> Nat — the interrupt-disable count, as it is.
(define (disable-count)
  (let ((n (disable-interrupts)))
    (enable-interrupts)
    (- n 1)))

;; collections-in-64-mib : -> Nat — the collections run while this
;; allocates 64 MiB, none of it kept.
(define (collections-in-64-mib)
  (let ((c0 (collections)))
    (let churn ((i 0))
      (when (< i 65536)
        (make-bytevector 1024)
        (churn (+ i 1))))
    (- (collections) c0)))

(define (wind)
  (awaiting
   (lambda ()
     (dynamic-wind
      (lambda () (note! 'wind 'before))
      (lambda ()
        (note! 'wind 'body)
        (sleep-ms 0)
        (note! 'wind 'after-wait-1)
        (sleep-ms 0)
        (note! 'wind 'after-wait-2)
        ok)
      (lambda () (note! 'wind 'after))))))

(define (critical)
  (awaiting
   (lambda ()
     (critical-section
      (note! 'critical 'entered 'count (disable-count))
      (sleep-ms 300)
      (note! 'critical 'resumed 'count (disable-count)))
     (note! 'critical 'left 'count (disable-count))
     ok)))

(define (probe)
  (note! 'probe 'count (disable-count) 'collections-in-64-mib (collections-in-64-mib))
  ok)

(define (control)
  (critical-section
   (note! 'control 'count (disable-count) 'collections-in-64-mib (collections-in-64-mib)))
  ok)

(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         (lambda (request)
                           (let ((path (request-path request)))
                             (cond ((string=? path "/wind") (wind))
                                   ((string=? path "/critical") (critical))
                                   ((string=? path "/probe") (probe))
                                   ((string=? path "/control") (control))
                                   (else (make-response 404 #f '() #f)))))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define base
  (string-append "http://127.0.0.1:" (number->string (caddr (assq 'listening logged)))))

(define script
  (string-append
   "curl -sS -o /dev/null " base "/wind && "
   "{ curl -sS -o /dev/null " base "/critical & "
   "sleep 0.1; curl -sS -o /dev/null " base "/probe; "
   "curl -sS -o /dev/null " base "/control; wait; }"))

(let ((exit #f))
  (uv-spawn! loop "/bin/sh" (list "/bin/sh" "-c" script)
             (list (cons 'stdio (list 'ignore '(inherit-fd . 1) '(inherit-fd . 2))))
             (lambda (status signal) (set! exit (list status signal))))
  (shell-run-turns! sh (lambda () (not exit)))
  (printf "collect-trip-bytes ~a; the shell's exit ~a\n" (collect-trip-bytes) exit))
(for-each (lambda (n) (printf "~s\n" n)) (reverse notes))
(printf "logged: ~a\n" (map car (filter (lambda (e) (not (eq? (car e) 'listening))) logged)))
