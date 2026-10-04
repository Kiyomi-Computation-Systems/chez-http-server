#!r6rs
;;; M8.4, 2026-10-04: what the server holds at max-connections.
;;;
;;; Plan §14's M8.4 re-measures the memory at `max-connections`, 10,000 by
;;; default: at the M4 exit's 18.2 KB a connection, about 180 MB.  This is
;;; the budget spikes' hold again (m5-exit-budget.sps), at that many: a
;;; server started as `serve` starts one, under the default limits, and a
;;; client in a process of its own, m4-exit-hold.py, that opens N keep-alive
;;; connections, sends a GET on each, and holds them idle.  It reads the
;;; server's heap and its process's resident set before the client, while
;;; it holds them, and after it has closed them, with chez-libuv's counts of
;;; TCP handles and read buffers and how many connections have their idle
;;; deadline armed.  Each N is a process of its own, so what one hold leaves
;;; resident is not read as the next one's.
;;;
;;;   chez --program m8-max-connections.sps m4-exit-hold.py N
;;;
;;; Run on the project's library path, with python3 on PATH and the
;;; open-file limit (ulimit -n) above N plus a few.  On macOS, the client's
;;; closed connections hold their ports in TIME_WAIT for 30 s, of a range of
;;; 16,384, so a second hold of 10,000 started sooner cannot connect them
;;; all: the client exits with EADDRNOTAVAIL, and the spike says so.
(import (rnrs)
        (only (chezscheme) printf format collect collect-maximum-generation bytes-allocated
              scheme-version open-process-ports native-transcoder machine-type)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server limits) default-limits limits-read-buffer-size limits-max-connections)
        (only (http-server connection) conn-phase)
        (only (http-server private shell) shell-connections connection-state shell-deadlines)
        (only (http-server private serve) start-server)
        (only (libuv private native) live-counts))

(define hold (cadr (command-line)))
(define n (string->number (caddr (command-line))))
;; The cap on each wait, in turns of the loop, a 1 ms ticker keeping it
;; awake: hours.  A client that exits before it holds them all ends the
;; wait at once.
(define cap 10000000)

;; exit-process : Nat -> Void — R6RS's exit, named apart from the child's status.
(define exit-process exit)

;; heap : -> Nat — the bytes the heap holds after two full collections.
(define (heap)
  (collect (collect-maximum-generation))
  (collect (collect-maximum-generation))
  (bytes-allocated))

;; resident : -> Nat — this process's resident set, in bytes, as ps reads it.
(define (resident)
  (let-values (((to from err pid)
                (open-process-ports (format "ps -o rss= -p ~a" (uv-os-getpid))
                                    'block (native-transcoder))))
    (let ((line (get-line from)))
      (close-port to) (close-port from) (close-port err)
      (* 1024 (string->number
               (list->string (filter (lambda (c) (not (char=? c #\space))) (string->list line))))))))

(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop
                         (lambda (request) (make-response 200 #f '() (string->utf8 "ok")))
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))

(printf "~a, Chez ~a (~a), libuv ~a; max-connections ~a, read buffer ~a B; holding ~a\n"
        (let-values (((to from err pid) (open-process-ports "uname -srm" 'block (native-transcoder))))
          (let ((l (get-line from))) (close-port to) (close-port from) (close-port err) l))
        (scheme-version) (machine-type) (uv-version)
        (limits-max-connections default-limits) (limits-read-buffer-size default-limits) n)

(let* ((heap0 (heap)) (rss0 (resident))
       (in (make-uv-pipe loop)) (out (make-uv-pipe loop)) (said (make-byte-collector)) (exit #f)
       (child (uv-spawn! loop "python3"
                         (list "python3" hold (number->string port) (number->string n) "1")
                         (list (cons 'stdio (list (list 'pipe in 'to-child) (list 'pipe out 'from-child)
                                                  '(inherit-fd . 2))))
                         (lambda (status signal) (set! exit (list status signal))))))
  (uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))
  (let ((ready (run-shell-until loop sh
                                (lambda ()
                                  (or exit
                                      (and (equal? (collector-bytes said) (string->utf8 "ready\n"))
                                           (= (length (shell-connections sh)) n)
                                           (for-all (lambda (c) (eq? (conn-phase (connection-state c)) 'idle))
                                                    (shell-connections sh)))))
                                cap)))
    (when exit
      (printf "the client exited ~a before it held ~a; ~a open\n" exit n (length (shell-connections sh)))
      (exit-process 2))
    (let* ((heap1 (heap)) (rss1 (resident)) (counts (live-counts)) (armed (shell-deadlines sh))
           (open (length (shell-connections sh))))
      (uv-close! in)
      (let ((gone (run-shell-until loop sh (lambda () (and exit (null? (shell-connections sh)))) cap)))
        (uv-close! child)
        (uv-close! out)
        (run-until-drained loop 1000)
        (let ((heap2 (heap)) (rss2 (resident)))
          (printf "before the client: heap ~a B, resident ~a B\n" heap0 rss0)
          (printf "holding: ~a; ~a open, TCP handles ~a, read buffers ~a, deadlines armed ~a; heap ~a B, resident ~a B\n"
                  ready open (cdr (assq 'tcp counts)) (cdr (assq 'read-buffer counts)) armed heap1 rss1)
          (printf "after the client closed them: ~a, client exit ~a; heap ~a B, resident ~a B\n"
                  gone exit heap2 rss2)
          (printf "a held connection: heap ~a B, resident ~a B; ~a held: heap ~a MB, resident ~a MB\n"
                  (round (/ (- heap1 heap0) n)) (round (/ (- rss1 rss0) n))
                  n (/ (round (/ (- heap1 heap0) 100000)) 10.) (/ (round (/ (- rss1 rss0) 100000)) 10.)))))))
