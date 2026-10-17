#!r6rs
;;; Streaming a response: the body is a producer, a procedure the server
;;; calls for each next piece until it returns the eof object.
;;;
;;;   /count?n=N        N numbered lines, made as fast as the client reads
;;;   /ticks?n=N&ms=M   N server-sent events, M milliseconds apart: the
;;;                     producer waits between them, so the handler answers
;;;                     with `awaiting`
;;;
;;;   make run PROGRAM=examples/stream.sps
;;;   curl 'http://127.0.0.1:8080/count?n=5'
;;;   curl -N 'http://127.0.0.1:8080/ticks?n=5&ms=1000'
(import (rnrs) (http-server))

;; header : String String -> (Pair Bytevector Bytevector)
(define (header name value) (cons (string->utf8 name) (string->utf8 value)))

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

;; counting : Nat -> (-> (U Bytevector Eof)) — the lines "1" to "n".
(define (counting n)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (if (> i n) (eof-object) (string->utf8 (string-append (number->string i) "\n"))))))

;; ticking : Nat Nat -> (-> (U Bytevector Eof))
;; n events, `ms` apart.  It waits with sleep-ms, so it must run where a
;; wait may: in a response an `awaiting` thunk answered.
(define (ticking n ms)
  (let ((i 0))
    (lambda ()
      (set! i (+ i 1))
      (cond ((> i n) (eof-object))
            (else (when (> i 1) (sleep-ms ms))
                  (string->utf8 (string-append "data: tick " (number->string i) "\n\n")))))))

(serve
 (lambda (request)
   (let ((path (request-path request)))
     (cond ((string=? path "/count")
            (make-response 200 #f (list (header "Content-Type" "text/plain"))
                           (counting (query-number request "n" 10 1000000))))
           ((string=? path "/ticks")
            (let ((n (query-number request "n" 10 1000))
                  (ms (query-number request "ms" 1000 60000)))
              (awaiting
               (lambda ()
                 (make-response 200 #f (list (header "Content-Type" "text/event-stream")
                                             (header "Cache-Control" "no-cache"))
                                (ticking n ms))))))
           (else
            (make-response 404 #f (list (header "Content-Type" "text/plain"))
                           (string->utf8 "try /count?n=5 or /ticks?n=5&ms=1000\n")))))))
