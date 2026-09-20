#!r6rs
;; chez-libuv v0.6.0: #21 (uv-tcp-keepalive!, the reuseport bind flag) and the new
;; uv-tcp-sockname-address, plus the store-and-reraise oracle decision 0003 item 4 relies
;; on, now under a __collect_safe uv-run (#19): a raise inside a timer callback must come
;; back out of uv-run as &uv-callback-error carrying the raised object.
(import (rnrs) (libuv) (spike common))
(define (show . xs) (for-each (lambda (x) (display x) (display " ")) xs) (newline))
(define (outcome thunk)
  (guard (e ((uv-invalid-argument? e) (list 'invalid-argument (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            ((uv-errno-error? e) (list 'errno (uv-errno-error-code e) (uv-errno-error-message e)))
            ((uv-constant-unavailable? e) (list 'constant-unavailable (uv-constant-unavailable-name e)))
            (#t (list 'other (condition-kinds e))))
    (thunk)))
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(let-values (((addr p) (uv-tcp-sockname-address server)))
  (show "sockname of the bound server (expect 127.0.0.1 and the getsockname port):" addr (= p port) (> p 0)))
(show "reuseport bind flag on this platform:" (outcome (lambda () (let ((s (make-uv-tcp loop))) (uv-tcp-bind! s "127.0.0.1" 0 '(reuseport)) (uv-close! s) 'accepted))))
(show "keepalive on an unconnected handle, enable with delay 0 (expect invalid-argument delay-out-of-range):" (outcome (lambda () (uv-tcp-keepalive! server #t 0) 'ok)))
(define peer #f)
(uv-listen! server 128 (lambda (err) (unless err (set! peer (uv-accept! server)) (uv-close! peer) (uv-close! server))))
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (show "keepalive enable 60 s on the connected client (expect ok):" (outcome (lambda () (uv-tcp-keepalive! client #t 60) 'ok)))
    (show "keepalive disable (expect ok):" (outcome (lambda () (uv-tcp-keepalive! client #f) 'ok)))
    (uv-close! client)))
(uv-run loop 'default)
(uv-loop-teardown! loop)
;; --- store-and-reraise under a collect-safe uv-run
(define loop2 (make-uv-loop))
(define t (make-uv-timer loop2))
(uv-timer-start! t (lambda (tm) (uv-timer-stop! tm) (raise 'boom)) 1 0)
(show "raise inside a timer callback comes out of uv-run (expect (uv-callback-error boom)):"
      (guard (e ((uv-callback-error? e) (list 'uv-callback-error (uv-callback-error-cause e)))
                (#t (list 'other (condition-kinds e))))
        (uv-run loop2 'default) 'no-raise))
(show "the loop is still usable afterwards (expect ok):" (outcome (lambda () (uv-close! t) (uv-run loop2 'default) (uv-loop-teardown! loop2) 'ok)))
(display "done") (newline)
