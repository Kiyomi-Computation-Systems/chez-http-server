#!r6rs
;;; Waiting for another thread: GET /sum?n=N adds 1 to N the slow way, on a
;;; worker thread of its own, and answers the sum.  The server goes on
;;; serving meanwhile: GET / answers at once, even while the worker is busy.
;;; A sum that takes more than 5 seconds is answered 504.  The worker still
;;; finishes it, and its answer is dropped, so the next sum waits for it:
;;; a deadline doesn't stop the work.  N is at most 4,000,000,000.
;;;
;;;   make run PROGRAM=examples/worker.sps
;;;   curl '127.0.0.1:8080/sum?n=1000000000'   # takes a second or so
;;;   curl 127.0.0.1:8080/                     # answers at once meanwhile
(import (rnrs) (http-server)
        (only (chezscheme) fork-thread make-mutex make-condition with-mutex
              condition-wait condition-signal))

;; --- the worker ---------------------------------------------------------------

;; The jobs waiting for the worker, oldest first, each `(work . resume)`,
;; guarded by `lock`; `ready` is signalled as each is added.
(define lock (make-mutex))
(define ready (make-condition))
(define jobs '())

;; put-job! : (Pair (-> Any) (Any -> Boolean)) -> Void — on any thread.
(define (put-job! job)
  (with-mutex lock
    (set! jobs (append jobs (list job)))
    (condition-signal ready)))

;; take-job! : -> (Pair (-> Any) (Any -> Boolean))
;; The oldest job, waiting for one if there is none: on the worker only.
(define (take-job!)
  (with-mutex lock
    (let wait () (when (null? jobs) (condition-wait ready lock) (wait)))
    (let ((job (car jobs))) (set! jobs (cdr jobs)) job)))

;; The worker runs each job in turn, and posts what it returned, or what it
;; raised, through the job's `resume`, so a raise never leaves a handler
;; waiting for ever.
(fork-thread
 (lambda ()
   (let loop ()
     (let* ((job (take-job!)) (work (car job)) (resume (cdr job)))
       (resume (guard (e (#t (cons 'raised e))) (cons 'ok (work))))
       (loop)))))

;; on-worker : (-> Any) -> Any
;; What `work` returns, run on the worker; what it raised is raised here.
;; Only in a handler that waits: `await-outside` parks it, and the loop
;; serves others, until the worker's answer comes.
(define (on-worker work)
  (let ((answer (await-outside (lambda (resume) (put-job! (cons work resume))))))
    (if (eq? (car answer) 'ok) (cdr answer) (raise (cdr answer)))))

;; --- the server ---------------------------------------------------------------

;; slow-sum : Nat -> Nat — 1 + 2 + ... + n, one at a time.
(define (slow-sum n)
  (let loop ((i 1) (sum 0))
    (if (> i n) sum (loop (+ i 1) (+ sum i)))))

;; text : Nat String -> Response
(define (text status s)
  (make-response status #f (list (cons (string->utf8 "Content-Type") (string->utf8 "text/plain")))
                 (string->utf8 s)))

;; query-number : Request String Nat Nat -> Nat
;; The query's `name=digits`, at most `most`; `default` if it is not there.
(define (query-number request name default most)
  (let loop ((pairs (split (or (request-query request) "") #\&)))
    (cond ((null? pairs) default)
          ((let ((kv (split (car pairs) #\=)))
             (and (= (length kv) 2) (string=? (car kv) name) (string->number (cadr kv) 10)))
           => (lambda (n) (if (and (integer? n) (exact? n) (>= n 0)) (min n most) default)))
          (else (loop (cdr pairs))))))

;; split : String Char -> (Listof String)
(define (split s c)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) c) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

(serve
 (lambda (request)
   (if (string=? (request-path request) "/sum")
       ;; Read what the worker needs here, on the loop's thread: the worker
       ;; gets a number, never the request.
       (let ((n (query-number request "n" 1000 4000000000)))
         (awaiting
          (lambda ()
            (guard (e ((deadline-passed? e) (text 504 "too slow\n")))
              (with-deadline 5000
                (lambda ()
                  (text 200 (string-append (number->string (on-worker (lambda () (slow-sum n))))
                                           "\n"))))))))
       (text 200 "Hello\n"))))
