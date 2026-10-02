#!r6rs
;;; M6 exit, 2026-10-02: 16 MiB each way against a slow peer, and what the
;;; server holds while they move.
;;;
;;; The brief's M6 exit is 16 MiB each way against a slow peer, with memory
;;; bounded, and plan §14 reads the memory as the M4 exit read a connection:
;;; the server's heap, the client in a process of its own.  A server is
;;; started as `serve` starts one, on 127.0.0.1:0 with the default limits,
;;; and a peer in a process of its own (m6-exit-peer.py) holds one keep-alive
;;; connection to it.  The peer sends 16 MiB as a POST's body, then reads
;;; 16 MiB streamed back, each a piece at a time with a pause between, so
;;; the peer is the slow end.  The body is read by `read-body`, which checks
;;; each byte against the pattern and keeps none, and the answer is streamed
;;; by a producer of 16 KiB pieces, each a fresh bytevector.  While each
;;; moves, the spike reads every `every-ms`:
;;;   - the server's heap, after two full collections;
;;;   - the bytes the connection has written and not yet seen completed
;;;     (`conn-outstanding-bytes`), which chez-libuv holds in write blocks,
;;;     outside the heap, read after every turn of the loop;
;;;   - chez-libuv's write requests live, in its dev build;
;;; and the peer reads the server's resident memory, from outside.  Last, the
;;; same two exchanges with the 16 MiB held whole, the body by
;;; `read-whole-body`, its cap raised to 32 MiB, and the answer as one
;;; bytevector, so the readings show what 16 MiB held looks like.
;;;
;;; Run on the project's library path (`make run`'s), with this directory's
;;; m6-exit-peer.py, a piece size and a pause in milliseconds as its
;;; arguments, and python3 on PATH.
(import (rnrs)
        (only (chezscheme) printf collect collect-maximum-generation bytes-allocated scheme-version
              machine-type current-time time-second time-nanosecond)
        (libuv) (uv-testing) (shell-testing)
        (http-server)
        (only (http-server connection) conn-outstanding-bytes conn-phase)
        (only (http-server private shell) shell-connections connection-state)
        (only (http-server private serve) start-server)
        (only (libuv private native) live-counts))

(define peer (cadr (command-line)))
(define piece (caddr (command-line)))
(define pause (cadddr (command-line)))
(define cap 100000000)
(define every-ms 50)

(define size (* 16 1024 1024))
(define piece-size 16384)
(define period 65521)
;; The pattern: byte n is (m mod 251), m = (n mod 65521) squared.  Its
;; period is prime, so no two 16 KiB pieces of the 16 MiB are alike.
(define table
  (let ((t (make-bytevector period)))
    (do ((i 0 (+ i 1))) ((= i period) t)
      (bytevector-u8-set! t i (mod (* i i) 251)))))

;; fill! : Bytevector Nat -> Bytevector — `bv` filled with the pattern from `off`.
(define (fill! bv off)
  (let loop ((i 0) (k (mod off period)))
    (when (< i (bytevector-length bv))
      (let ((n (min (- (bytevector-length bv) i) (- period k))))
        (bytevector-copy! table k bv i n)
        (loop (+ i n) 0))))
  bv)

;; matches? : Bytevector Nat Nat Nat -> Boolean — `bv[start, end)` is the
;; pattern from `off`.
(define (matches? bv start end off)
  (let loop ((i start) (k (mod off period)))
    (cond ((= i end) #t)
          ((fx=? (bytevector-u8-ref bv i) (bytevector-u8-ref table k))
           (loop (+ i 1) (if (= (+ k 1) period) 0 (+ k 1))))
          (else #f))))

(define (text . parts)
  (string->utf8 (apply string-append (map (lambda (p) (if (number? p) (number->string p) p)) parts))))

;; /up reads the body a piece at a time and answers "bytes wrong largest";
;; /up-whole reads it whole, up to 32 MiB, and answers "bytes wrong";
;; /down streams the pattern in 16 KiB pieces; /down-whole answers it as
;; one bytevector.
(define producer-calls 0)
(define (handler r)
  (let ((path (request-path r)))
    (cond
     ((string=? path "/up")
      (let ((got 0) (wrong 0) (largest 0))
        (read-body (lambda (bv start end)
                     (unless (matches? bv start end got) (set! wrong (+ wrong 1)))
                     (set! largest (max largest (- end start)))
                     (set! got (+ got (- end start))))
                   (lambda () (make-response 200 #f '() (text got " " wrong " " largest))))))
     ((string=? path "/up-whole")
      (read-whole-body (lambda (body)
                         (make-response 200 #f '()
                                        (text (bytevector-length body) " "
                                              (if (matches? body 0 (bytevector-length body) 0) 0 1))))
                       (* 32 1024 1024)))
     ((string=? path "/down")
      (let ((off 0))
        (set! producer-calls 0)
        (make-response 200 #f '()
                       (lambda ()
                         (set! producer-calls (+ producer-calls 1))
                         (if (= off size)
                             (eof-object)
                             (let ((bv (fill! (make-bytevector piece-size) off)))
                               (set! off (+ off piece-size))
                               bv))))))
     ((string=? path "/down-whole")
      (make-response 200 #f '() (fill! (make-bytevector size) 0)))
     (else (make-response 200 #f '() (text "pong"))))))

;; heap : -> Nat — the bytes the heap holds after two full collections.
(define (heap)
  (collect (collect-maximum-generation))
  (collect (collect-maximum-generation))
  (bytes-allocated))

(define (monotonic-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

(define (write-requests) (cdr (assq 'write-req (live-counts))))

(define loop (make-uv-loop))
(define logged '())
(define sh (start-server loop handler
                         (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "0"))
                         (lambda (what details) (set! logged (cons (cons what details) logged)))))
(define port (caddr (assq 'listening logged)))

(define in (make-uv-pipe loop))
(define out (make-uv-pipe loop))
(define said (make-byte-collector))
(define peer-exit #f)
(define child
  (uv-spawn! loop "python3" (list "python3" peer (number->string port) piece pause)
             (list (cons 'stdio (list (list 'pipe in 'to-child) (list 'pipe out 'from-child)
                                      '(inherit-fd . 2))))
             (lambda (status signal) (set! peer-exit (list status signal)))))
(uv-read-start! out (lambda (bv start end) (collect-span! said bv start end)) (lambda () #f) (lambda (e) #f))

;; lines : -> (Listof String) — the peer's whole lines so far.
(define (lines)
  (let ((s (utf8->string (collector-bytes said))))
    (let split ((i 0) (start 0) (acc '()))
      (cond ((= i (string-length s)) (reverse acc))
            ((char=? (string-ref s i) #\newline)
             (split (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (split (+ i 1) start acc))))))

;; sampled : Nat -> (List Symbol String Nat Nat Nat Nat)
;; Run the server until the peer has printed `n` lines, reading the heap every
;; `every-ms` and the bytes outstanding after every turn: how the wait ended,
;; the peer's last line, the most heap read, how many heap readings, the most
;; bytes outstanding, and the most write requests live.
(define (sampled n)
  (let ((most-heap 0) (readings 0) (most-out 0) (most-reqs 0) (next (monotonic-ms)))
    (let ((outcome
           (run-shell-until loop sh
                            (lambda ()
                              (for-each (lambda (c)
                                          (set! most-out (max most-out (conn-outstanding-bytes (connection-state c)))))
                                        (shell-connections sh))
                              (when (>= (monotonic-ms) next)
                                (set! most-heap (max most-heap (heap)))
                                (set! most-reqs (max most-reqs (write-requests)))
                                (set! readings (+ readings 1))
                                (set! next (+ (monotonic-ms) every-ms)))
                              (>= (length (lines)) n))
                            cap)))
      (list outcome (if (null? (lines)) "" (list-ref (lines) (- (length (lines)) 1)))
            most-heap readings most-out most-reqs))))

(define (idle?)
  (for-all (lambda (c) (eq? (conn-phase (connection-state c)) 'idle)) (shell-connections sh)))

(printf "Chez ~a (~a), libuv ~a; the listener on 127.0.0.1:~a; the peer's piece ~a B, its pause ~a ms\n"
        (scheme-version) (machine-type) (uv-version) port piece pause)
(let ((ready (sampled 1)))
  (printf "ready: ~a, ~a; connections ~a\n" (car ready) (cadr ready) (length (shell-connections sh))))
(for-each
 (lambda (cmd k)
   (run-shell-until loop sh idle? cap)
   (let ((before (heap)))
     (uv-write! in (string->utf8 (string-append cmd "\n")) (lambda (err) #f))
     (let* ((r (sampled k))
            (after (begin (run-shell-until loop sh idle? cap) (heap))))
       (printf "~a: ~a\n  peer: ~a\n" cmd (car r) (cadr r))
       (printf "  heap: ~a B idle before, at most ~a B in ~a readings (+~a), ~a B idle after\n"
               before (caddr r) (cadddr r) (- (caddr r) before) after)
       (printf "  written and not completed: at most ~a B; write requests live: at most ~a~a\n"
               (list-ref r 4) (list-ref r 5)
               (if (string=? cmd "down") (string-append "; the producer called " (number->string producer-calls) " times") "")))))
 '("up" "down" "up-whole" "down-whole")
 '(2 3 4 5))
(uv-close! in)
(run-shell-until loop sh (lambda () (and peer-exit (null? (shell-connections sh)))) cap)
(printf "peer exit ~a; logged ~a\n" peer-exit (map car (reverse logged)))
