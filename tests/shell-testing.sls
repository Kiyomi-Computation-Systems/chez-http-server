#!r6rs
;;; (shell-testing) — what the suites that drive the libuv shell over
;;; loopback share: clients on the shell's own loop, and a run of that loop.
;;;
;;; These suites run their clients on the loop the shell runs on, so one
;;; uv-run moves both ends and every wait is capped by an iteration count,
;;; never wall-clock (design §8.5).  A client connects to 127.0.0.1, collects
;;; what it reads with chez-libuv's own collector (tests/uv-testing.sls),
;;; which keeps each delivery rather than a copy, and records how its stream
;;; ended.  M4.2 wrote these inside tests/test-shell.sps, the socket lane;
;;; M4.4 moved them here, to share them with the contract test (design §8.4).
;;;
;;; NOT pure: it drives chez-libuv and the shell.
(library (shell-testing)
  (export open-client client? client-tcp client-collector client-connected client-end
          client-read! client-send! client-bytes client-close!
          err->symbol run-shell-until)
  (import (rnrs) (libuv) (uv-testing)
          (only (http-server private shell) shell-run!))

  ;; err->symbol : (U #f Condition) -> Symbol
  ;; A callback's error as a symbol no failure path confuses with success:
  ;; 'no-error, the errno's name, or 'unexpected-error-object.
  (define (err->symbol err)
    (cond ((not err) 'no-error)
          ((uv-errno-error? err) (uv-errno-error-errno err))
          (else 'unexpected-error-object)))

  ;; client? : Any -> Boolean
  ;; client-tcp : Client -> UvTcp
  ;; client-collector : Client -> ByteCollector — what it has read, in order
  ;; client-connected : Client -> Symbol
  ;;   'never until the connect completes, then its err->symbol
  ;; client-end : Client -> Symbol
  ;;   'open while its stream has not ended, then 'eof or the read's errno
  (define-record-type client
    (fields tcp collector (mutable connected) (mutable end) (mutable reading?))
    (protocol (lambda (new) (lambda (tcp) (new tcp (make-byte-collector) 'never 'open #f)))))

  ;; client-read! : Client -> Void — start reading, collecting what arrives.
  (define (client-read! cl)
    (client-reading?-set! cl #t)
    (uv-read-start! (client-tcp cl)
                    (lambda (bv start end) (collect-span! (client-collector cl) bv start end))
                    (lambda () (client-end-set! cl 'eof))
                    (lambda (e) (client-end-set! cl (err->symbol e)))))

  ;; open-client : UvLoop Nat (U #f Bytevector) Boolean -> Client
  ;; A client on `loop` that connects to 127.0.0.1:`port`, then starts
  ;; reading if `read?`, and writes `request` whole unless it is #f.  A
  ;; connect that fails at the call is recorded in client-connected as one
  ;; that fails later is, and the handle closed: macOS refuses a connect to
  ;; the client's own address with EINVAL, where a closed port gives
  ;; ECONNREFUSED at the completion.
  (define (open-client loop port request read?)
    (let* ((tcp (make-uv-tcp loop)) (cl (make-client tcp)))
      (guard (e ((uv-errno-error? e)
                 (client-connected-set! cl (uv-errno-error-errno e))
                 (uv-close! tcp)))
        (connect-loopback! tcp port
                           (lambda (err)
                             (client-connected-set! cl (err->symbol err))
                             (unless err
                               (when read? (client-read! cl))
                               (when request (client-send! cl request))))))
      cl))

  ;; client-send! : Client Bytevector -> Void — one write, its outcome ignored.
  (define (client-send! cl bytes) (uv-write! (client-tcp cl) bytes (lambda (err) #f)))

  ;; client-bytes : Client -> Bytevector — everything read so far, in order.
  (define (client-bytes cl) (collector-bytes (client-collector cl)))

  ;; client-close! : Client -> Void — close its handle, if it is open.
  (define (client-close! cl)
    (when (uv-handle-open? (client-tcp cl)) (uv-close! (client-tcp cl))))

  ;; run-shell-until : UvLoop Shell (-> Boolean) Nat -> Symbol
  ;; Step `sh`'s run loop on `loop`, which logs a callback's error and runs
  ;; on, a 1 ms ticker keeping the loop awake, until `pred` holds or `cap`
  ;; steps have been taken: 'satisfied or 'iterations-exhausted.  The ticker
  ;; is closed after, and its close drained, also when the run loop raises,
  ;; as it does a byte-machine contract condition (design §6.4): the raise
  ;; goes on, and a failure to close the ticker then is dropped, so it cannot
  ;; take the raise's place (as chez-libuv's run-until/ticking does).
  (define (run-shell-until loop sh pred cap)
    (let ((ticker (make-uv-timer loop)))
      (uv-timer-start! ticker (lambda (t) #f) 1 1)
      (let ((outcome (guard (e (#t (guard (cleanup (#t #f)) (disarm! loop ticker))
                                   (raise e)))
                       (let step ((i 0))
                         (cond ((pred) 'satisfied)
                               ((= i cap) 'iterations-exhausted)
                               (else (shell-run! sh 'once) (step (+ i 1))))))))
        (disarm! loop ticker)
        outcome)))

  ;; disarm! : UvLoop UvTimer -> Void — stop and close the ticker, if it is
  ;; open, and drain its close.
  (define (disarm! loop ticker)
    (when (uv-handle-open? ticker)
      (uv-timer-stop! ticker)
      (uv-close! ticker))
    (run-until loop (lambda () (eq? (uv-handle-state ticker) 'closed)) 8)))
