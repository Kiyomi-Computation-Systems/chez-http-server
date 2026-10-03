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
          client-read! client-send! client-shut! client-bytes client-close!
          err->symbol run-shell-until run-loop-until run-until-drained
          bytes-between responses spaced looked-up)
  (import (rnrs) (libuv) (uv-testing) (response-reader)
          (only (http-server private shell) shell-turn! loop-turn!))

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

  ;; client-shut! : Client -> Void
  ;; End the stream the client sends, its write side, reading on.
  (define (client-shut! cl) (uv-shutdown! (client-tcp cl) (lambda (err) #f)))

  ;; client-bytes : Client -> Bytevector — everything read so far, in order.
  (define (client-bytes cl) (collector-bytes (client-collector cl)))

  ;; client-close! : Client -> Void — close its handle, if it is open.
  (define (client-close! cl)
    (when (uv-handle-open? (client-tcp cl)) (uv-close! (client-tcp cl))))

  ;; run-shell-until : UvLoop Shell (-> Boolean) Nat -> Symbol
  ;; Step `sh`'s run loop on `loop`, which logs a callback's error and runs
  ;; on, a 1 ms ticker keeping the loop awake, until `pred` holds or `cap`
  ;; steps have been taken: 'satisfied or 'iterations-exhausted.  A step is a
  ;; turn of the loop's scheduler (shell-turn!), which calls the handlers
  ;; the last one asked for, then runs the loop once (decision 0014).  The
  ;; ticker is closed after, and its close drained, also when the run loop
  ;; raises, as it does a byte-machine contract condition (design §6.4): the
  ;; raise goes on, and a failure to close the ticker then is dropped, so it
  ;; cannot take the raise's place (as chez-libuv's run-until/ticking does).
  (define (run-shell-until loop sh pred cap)
    (ticking-until loop (lambda () (shell-turn! sh)) pred cap))

  ;; run-loop-until : UvLoop (-> Boolean) Nat -> Symbol
  ;; The same with no shell's guard: each step a turn of the loop's
  ;; scheduler (loop-turn!), so a callback's raise comes out as uv-run
  ;; raises it, as chez-libuv's run-until/ticking lets it.
  (define (run-loop-until loop pred cap)
    (ticking-until loop (lambda () (loop-turn! loop)) pred cap))

  ;; ticking-until : UvLoop (-> Any) (-> Boolean) Nat -> Symbol
  ;; `step!` until `pred` holds or `cap` steps have been taken, a 1 ms
  ;; ticker keeping the loop awake, closed after, as run-shell-until says.
  (define (ticking-until loop step! pred cap)
    (let ((ticker (make-uv-timer loop)))
      (uv-timer-start! ticker (lambda (t) #f) 1 1)
      (let ((outcome (guard (e (#t (guard (cleanup (#t #f)) (disarm! loop ticker))
                                   (raise e)))
                       (let step ((i 0))
                         (cond ((pred) 'satisfied)
                               ((= i cap) 'iterations-exhausted)
                               (else (step!) (step (+ i 1))))))))
        (disarm! loop ticker)
        outcome)))

  ;; run-until-drained : UvLoop Nat -> Symbol
  ;; Run `loop` until nothing but a timer is live on it, or `cap` steps have
  ;; been taken: 'satisfied or 'iterations-exhausted.  A wait for an empty
  ;; loop never sees one, since the ticker that keeps it awake is live while
  ;; it waits: it runs to its cap.  The caller asks after the wait whether
  ;; the loop is empty, the ticker closed by then.
  (define (run-until-drained loop cap)
    (run-until/ticking loop (lambda () (for-all uv-timer? (uv-loop-live-handles loop))) cap))

  ;; bytes-between : Bytevector Nat Nat -> Bytevector — a copy of bv[from, to).
  (define (bytes-between bv from to)
    (let ((out (make-bytevector (- to from))))
      (bytevector-copy! bv from out 0 (- to from))
      out))

  ;; responses : Bytevector -> (Listof ResponseRead)
  ;; The whole responses at the front of `bv`, in order, each read by
  ;; chez-httparse's response parser (tests/response-reader.sls): the
  ;; shortest prefix it reads as one complete message is the first, and what
  ;; follows is read the same way.
  (define (responses bv)
    (let next ((from 0) (acc '()))
      (let grow ((to (+ from 1)))
        (if (> to (bytevector-length bv))
            (reverse acc)
            (let ((r (read-response (bytes-between bv from to) #f #f)))
              (if (eq? (list-ref r 4) 'complete)
                  (next to (cons r acc))
                  (grow (+ to 1))))))))

  ;; spaced : (Listof String) -> String — the strings, a space between each.
  (define (spaced strings)
    (if (null? strings)
        ""
        (fold-left (lambda (acc x) (string-append acc " " x)) (car strings) (cdr strings))))

  ;; looked-up : UvLoop String Nat -> (U (Listof String) 'failed)
  ;; What uv-getaddrinfo! itself answers for `host`, stream sockets alone:
  ;; the oracle a handler's lookup is held to.  `loop` is run until it has
  ;; answered, `cap` steps at most (run-loop-until).
  (define (looked-up loop host cap)
    (let ((answer #f))
      (uv-getaddrinfo! loop host #f '((socktype . stream))
                       (lambda (err results)
                         (set! answer (if err 'failed (map uv-addrinfo-address results)))))
      (run-loop-until loop (lambda () answer) cap)
      answer))

  ;; disarm! : UvLoop UvTimer -> Void — stop and close the ticker, if it is
  ;; open, and drain its close.
  (define (disarm! loop ticker)
    (when (uv-handle-open? ticker)
      (uv-timer-stop! ticker)
      (uv-close! ticker))
    (run-until loop (lambda () (eq? (uv-handle-state ticker) 'closed)) 8)))
