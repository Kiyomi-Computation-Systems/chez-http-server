#!r6rs
;; M8.2, 2026-10-03: what the core already holds when a handler answers an
;; upgrade, measured before the door's form.  The core pauses the parser at
;; every message's end (decision 0004 item 1) and keeps the rest of that
;; delivery, from `parser-result-next`, as its pending input; reading stops
;; at the pause, so what the client sent after it waits in the kernel.  If
;; the door hands over the pending input as the retained bytes, then what a
;; taker reads is the retained bytes, then what reading on brings, and the
;; two together must be exactly the bytes after the request, at every
;; delivery size.  Here, for each input, at each size from 1 to its length:
;;   - the pending input the core holds when the answer is made (for a
;;     request with a body, at its reader's end), as (from to) of the input;
;;   - the bytes read by then, the end of the last range the parser was
;;     fed, read from the actions and not from the pending input; the rest
;;     is unread;
;;   - whether pending ++ unread = the bytes after the request, and whether
;;     the pending input begins at the request's end.
;; Run on the project's `make` library path.
(import (rnrs) (http-server connection) (http-server limits) (http-server response)
        (fake-shell))

(define (b s) (string->utf8 s))
(define resp (make-response 200 #f '() (b "ok")))

;; run : Bytevector Nat Nat Boolean -> Datum
;; `input` delivered `size` bytes at a time to a fake connection whose
;; handler notes the core's pending input; `end` is the request's end.
(define (run input size end body?)
  (let* ((cell #f) (seen 'never) (read-by 'never)
         (answer (lambda (request)
                   (set! seen (conn-pending (fake-shell-conn-state cell)))
                   ;; what the shell had delivered by then: the end of the
                   ;; last range the parser was fed, read from the actions,
                   ;; not from the pending input
                   (set! read-by
                         (fold-left (lambda (n a) (if (eq? (car a) 'feed-parser) (cadddr a) n))
                                    0 (fake-shell-actions cell)))
                   resp))
         (sh (make-fake-connection default-limits (if body? (drops-body answer) answer))))
    (set! cell sh)
    (let* ((fed-all (fake-shell-feed-input! sh input size))
           (delivered read-by)
           (len (bytevector-length input))
           (pending (cond ((eq? seen 'never) 'never)
                          ((not seen) '())
                          (else (list (cadr seen) (caddr seen)))))
           (retained (cond ((eq? seen 'never) #f)
                           ((not seen) (make-bytevector 0))
                           (else (let ((v (make-bytevector (- (caddr seen) (cadr seen)))))
                                   (bytevector-copy! (car seen) (cadr seen) v 0 (bytevector-length v))
                                   v))))
           (unread (let ((v (make-bytevector (- len delivered))))
                     (bytevector-copy! input delivered v 0 (- len delivered))
                     v))
           (after (let ((v (make-bytevector (- len end))))
                    (bytevector-copy! input end v 0 (- len end))
                    v)))
      (list 'pending pending 'read-by delivered
            'exact (and retained (equal? (bytevector-append retained unread) after))
            'starts-at-end (or (null? pending) (eq? pending 'never) (= (car pending) end))))))

(define (bytevector-append a c)
  (let ((v (make-bytevector (+ (bytevector-length a) (bytevector-length c)))))
    (bytevector-copy! a 0 v 0 (bytevector-length a))
    (bytevector-copy! c 0 v (bytevector-length a) (bytevector-length c))
    v))

;; A masked WebSocket text frame "Hi" (RFC 6455 §5.7's example), sent
;; before the 101, as hyper's `upgrades` test sends "eagerly optimistic".
(define frame (u8-list->bytevector '(#x81 #x82 #x37 #xfa #x21 #x3d #x7f #x9f)))
(define (with-frame s) (bytevector-append (b s) frame))
(define ws "GET /chat HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n")
(define inputs
  (list (list 'websocket (b ws) (string-length ws) #f)
        (list 'websocket+frame (with-frame ws) (string-length ws) #f)
        (let ((s "PUT /u HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nContent-Length: 4\r\nUpgrade: ws\r\n\r\nabcd"))
          (list 'upgrade-body+frame (with-frame s) (string-length s) #t))
        (let ((s "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"))
          (list 'connect+tunnel (bytevector-append (b s) (b "TUNNEL")) (string-length s) #f))
        (let ((s "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n"))
          (list 'h2c+preface (bytevector-append (b s) (b "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")) (string-length s) #f))
        (let ((s "GET /chat HTTP/1.0\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"))
          (list 'http/1.0+frame (with-frame s) (string-length s) #f))))

(for-each
 (lambda (in)
   (let* ((name (car in)) (input (cadr in)) (end (caddr in)) (body? (cadddr in))
          (len (bytevector-length input)))
     (let loop ((size 1) (exact 0) (starts 0) (kinds '()))
       (if (> size len)
           (begin
             (write (list name 'length len 'request-end end
                          'sizes len 'exact exact 'starts-at-end starts
                          'pending-shapes (length kinds)))
             (newline))
           (let ((r (run input size end body?)))
             (loop (+ size 1)
                   (if (list-ref r 5) (+ exact 1) exact)
                   (if (list-ref r 7) (+ starts 1) starts)
                   (let ((shape (list (if (null? (list-ref r 1)) 'none 'some))))
                     (if (member shape kinds) kinds (cons shape kinds)))))))))
 inputs)

;; Two sizes shown whole: a byte at a time, and the input whole.
(for-each
 (lambda (in)
   (let* ((name (car in)) (input (cadr in)) (end (caddr in)) (body? (cadddr in))
          (len (bytevector-length input)))
     (write (list name 'size 1 (run input 1 end body?))) (newline)
     (write (list name 'size len (run input len end body?))) (newline)))
 inputs)
