;; E6: call (uv-run loop 'nowait) from INSIDE an on-data callback and record the
;; exact condition chez-libuv raises; then let it escape to see the wrapping.
(import (rnrs) (libuv)
        (only (chezscheme) printf display-condition))
(define (log! fmt . args) (apply printf fmt args) (flush-output-port (current-output-port)))
(define (show e) (call-with-string-output-port (lambda (p) (display-condition e p))))
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define peer #f)
(uv-listen! server 128
  (lambda (err)
    (unless err
      (set! peer (uv-accept! server))
      (uv-read-start! peer
        (lambda (bv s e)
          (log! "on-data: ~a bytes; calling (uv-run loop 'nowait) from inside the callback\n" (- e s))
          (guard (x (#t
                     (log! "on-data: guard caught: display-condition => ~a\n" (show x))
                     (log! "on-data: uv-invalid-argument? ~s who ~s reason ~s\n"
                           (uv-invalid-argument? x)
                           (and (uv-invalid-argument? x) (uv-invalid-argument-who x))
                           (and (uv-invalid-argument? x) (uv-invalid-argument-reason x)))
                     (log! "on-data: uv-error? ~s message-condition? ~s who-condition? ~s\n"
                           (uv-error? x) (message-condition? x) (who-condition? x))
                     (log! "on-data: (uv-run loop 'once) inside callback also => ~a\n"
                           (guard (y (#t (show y))) (uv-run loop 'once) "NO RAISE"))
                     (log! "on-data: re-raising so the outer uv-run wraps it\n")
                     (raise x)))
            (uv-run loop 'nowait)
            (log! "on-data: uv-run nowait returned WITHOUT raising\n")))
        (lambda () #f)
        (lambda (e) (log! "peer error ~a\n" (show e)))))))
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (e) (uv-write! client (string->utf8 "ping") (lambda (e) #f))))
(define rc (guard (x (#t (log! "outer uv-run RAISED: ~a\n" (show x))
                         (log! "outer: uv-callback-error? ~s; cause is uv-invalid-argument? ~s; guard on the ORIGINAL type still matches? ~s\n"
                               (uv-callback-error? x)
                               (and (uv-callback-error? x) (uv-invalid-argument? (uv-callback-error-cause x)))
                               (uv-invalid-argument? x))
                         'raised))
            (uv-run loop 'default)))
(log! "outer uv-run result ~s; loop-open? ~s; deferred-errors ~s\n" rc (uv-loop-open? loop) (map show (uv-loop-deferred-errors loop)))
(guard (e (#t (log! "teardown RAISED: ~a\n" (show e)))) (uv-loop-teardown! loop))
(log! "teardown done; loop-open? ~s\n" (uv-loop-open? loop))
