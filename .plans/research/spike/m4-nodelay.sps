#!r6rs
;;; M4, 2026-09-26: does Nagle's algorithm hold the shell's small responses?
;;;
;;; The shell writes one response at a time, the next only once the last
;;; write has completed, which is when the kernel took the bytes, not when the
;;; client acknowledged them.  With Nagle on (the default), a small segment
;;; waits while an earlier one is unacknowledged, and a client that has
;;; nothing to send may delay its acknowledgement.  This times a client on the
;;; same loop over loopback, the server's connection with TCP_NODELAY off and
;;; on, three times each:
;;;   - pipelined: sixteen GETs in one write, until sixteen responses arrive;
;;;   - one at a time: sixteen GETs, each sent when the last response is whole.
;;; Wall-clock milliseconds, so a research reading, never a test's oracle.
;;;
;;; Run on the project's library path (the ledger's M4 entry gives it).
(import (rnrs)
        (only (chezscheme) real-time)
        (libuv) (uv-testing)
        (http-server private shell) (http-server response) (http-server limits))

(define (b s) (string->utf8 s))
(define get (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(define status-line (b "HTTP/1.1 200"))

(define loop (make-uv-loop))
(define shell (make-shell loop (lambda (req) (make-response 200 #f '() (b "hello, world\n")))
                          default-limits (lambda () 784111777) (lambda (what details) #f)))
(define nodelay? #f)
(define listener (make-uv-tcp loop))
(define port (bind-loopback! listener))
(uv-listen! listener 64
            (lambda (err)
              (unless err
                (let ((tcp (uv-accept! listener)))
                  (shell-adopt! shell tcp)
                  ;; After the adoption, which turns Nagle off since M4.2's
                  ;; review, so each row measures the mode it names.
                  (uv-tcp-nodelay! tcp nodelay?)))))

;; count-of : Bytevector Bytevector -> Nat — how many times `needle` occurs.
(define (count-of hay needle)
  (let ((n (bytevector-length needle)) (h (bytevector-length hay)))
    (let scan ((i 0) (k 0))
      (cond ((> (+ i n) h) k)
            ((let same ((j 0))
               (or (= j n) (and (= (bytevector-u8-ref hay (+ i j)) (bytevector-u8-ref needle j))
                                (same (+ j 1)))))
             (scan (+ i n) (+ k 1)))
            (else (scan (+ i 1) k))))))

;; exchange : Symbol -> Nat — milliseconds for one client's sixteen requests.
(define (exchange how)
  (let* ((tcp (make-uv-tcp loop)) (got (make-byte-collector)) (connected #f) (sent 0))
    (connect-loopback! tcp port
                       (lambda (err)
                         (set! connected #t)
                         (uv-read-start! tcp (lambda (bv s e) (collect-span! got bv s e))
                                         (lambda () #f) (lambda (e) #f))))
    (run-until/ticking loop (lambda () connected) 10000)
    (let ((start (real-time))
          (answered (lambda () (count-of (collector-bytes got) status-line))))
      (if (eq? how 'pipelined)
          (begin
            (uv-write! tcp (apply bytevector-append* (make-list 16 get)) (lambda (e) #f))
            (run-until/ticking loop (lambda () (= (answered) 16)) 100000))
          (let next ()
            (when (< sent 16)
              (set! sent (+ sent 1))
              (uv-write! tcp get (lambda (e) #f))
              (run-until/ticking loop (lambda () (= (answered) sent)) 100000)
              (next))))
      (let ((elapsed (- (real-time) start)))
        (uv-close! tcp)
        (run-until/ticking loop (lambda () (null? (shell-connections shell))) 10000)
        elapsed))))

(define (bytevector-append* . bvs)
  (let ((out (make-bytevector (fold-left + 0 (map bytevector-length bvs)))))
    (fold-left (lambda (at bv) (bytevector-copy! bv 0 out at (bytevector-length bv))
                 (+ at (bytevector-length bv)))
               0 bvs)
    out))

(define (make-list n x) (if (= n 0) '() (cons x (make-list (- n 1) x))))

(define (show . xs) (for-each display xs) (newline))

(for-each
 (lambda (mode)
   (set! nodelay? mode)
   (for-each
    (lambda (how)
      (show "TCP_NODELAY " (if mode "on " "off") "  " how ": "
            (exchange how) " " (exchange how) " " (exchange how) " ms"))
    '(pipelined one-at-a-time)))
 '(#f #t))

(uv-close! listener)
(uv-loop-teardown! loop)
