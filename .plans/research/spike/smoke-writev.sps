#!r6rs
(import (rnrs) (libuv))
(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define received '())                     ; list of bytevectors, newest first
(define completions 0)
(define peer #f)
(uv-listen! server 128
  (lambda (err)
    (unless err
      (set! peer (uv-accept! server))
      (uv-read-start! peer
        (lambda (bv s e) (let ((o (make-bytevector (- e s)))) (bytevector-copy! bv s o 0 (- e s)) (set! received (cons o received))))
        (lambda () (uv-shutdown! peer (lambda (e) (uv-close! peer))) (uv-close! server))
        (lambda (c) (uv-close! peer))))))
(define client (make-uv-tcp loop))
(define head (string->utf8 "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"))
(define big (string->utf8 "xxhelloyy"))   ; span [2,7) = "hello"
(define tail (string->utf8 "TRAILER"))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (unless err
      ;; empty list must be refused synchronously
      (show "empty-list refusal:"
            (guard (e ((uv-invalid-argument? e) (list 'refused (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
              (uv-write*! client '() (lambda (e) #f)) 'not-refused))
      (uv-write*! client (list head (list big 2 7) tail)
        (lambda (err)
          (set! completions (+ completions 1))
          (show "on-complete err:" (if err 'ERROR 'none))
          (uv-shutdown! client (lambda (e) (uv-close! client))))))))
(uv-run loop 'default)
(uv-loop-teardown! loop)
(define got (let* ((parts (reverse received)) (n (apply + (map bytevector-length parts))) (o (make-bytevector n)))
  (let loop ((ps parts) (at 0)) (unless (null? ps) (bytevector-copy! (car ps) 0 o at (bytevector-length (car ps))) (loop (cdr ps) (+ at (bytevector-length (car ps)))))) o))
(define want (let* ((a head) (b (string->utf8 "hello")) (c tail) (o (make-bytevector (+ (bytevector-length a) 5 (bytevector-length c)))))
  (bytevector-copy! a 0 o 0 (bytevector-length a)) (bytevector-copy! b 0 o (bytevector-length a) 5) (bytevector-copy! c 0 o (+ (bytevector-length a) 5) (bytevector-length c)) o))
(show "completions (expect 1):" completions)
(show "bytes match concatenation (expect match):" (if (equal? got want) 'match (list 'MISMATCH (utf8->string got))))
(show "received:" (utf8->string got))
