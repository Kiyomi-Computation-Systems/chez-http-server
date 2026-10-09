#!r6rs
;;; (http-server transport) — the stream a taker is handed (pure).
;;;
;;; Decision 0016 item 2.  A handler that takes an upgrade is called, once
;;; the 101 is written, with a TRANSPORT: a record of verbs over the stream.
;;; The server's shell makes one over chez-libuv and keeps the stream (its
;;; place in max-connections, its close, its deadline and the drain), and a
;;; test makes one of its own procedures, so a taker imports no chez-libuv
;;; and is tested against a fake.  Each verb checks what it is handed and
;;; calls its procedure with the arguments in one shape, so a taker's
;;; mistake is the same refusal on a fake as on the server:
;;;
;;;   (transport-write! t bv [start end] [written])
;;;        write bv[start, end), a byte or more, the whole bytevector by
;;;        default; `written`, when given, is called with #f once the bytes
;;;        are written, or with the errno, as a symbol, if they are not.
;;;        The procedure is handed (bv start end written-or-#f).
;;;   (transport-read-start! t on-bytes on-end)
;;;        read: each read's bytes as (on-bytes bv start end), the bytevector
;;;        the taker's to keep; then (on-end why), 'eof or the errno, once.
;;;   (transport-read-stop! t)
;;;   (transport-close! t)
;;;        close the stream once the bytes written so far have been.
;;;   (transport-abort! t)
;;;        close the stream now: reading stops, and what is unsent is
;;;        dropped, each write outstanding told ECANCELED (decision 0024).
;;;   (transport-deadline! t ms on-passed) / (transport-deadline! t #f)
;;;        one deadline: `on-passed` called once `ms` milliseconds have
;;;        passed, the one armed before replaced; #f disarms it.  The
;;;        procedure is handed (ms on-passed), or (#f #f).
;;;   (transport-on-drain! t thunk)
;;;        `thunk` called if the server drains while the stream is open, so
;;;        the taker can say goodbye and close; the drain waits for it.
;;;   (transport-on-close! t thunk)
;;;        `thunk` called once the stream has closed, whoever closed it; at
;;;        once if it already has.
;;;
;;; Nothing bounds a taker's writes outstanding but the taker (decided on the
;;; owner's word, by form, at M8.2's review): `written` tells it what each
;;; write has become, so it can count what is still outstanding, and stop
;;; past a bound of its own.  A client that stops reading never takes them,
;;; so `transport-close!` would wait for it: a deadline whose call aborts
;;; closes it (decision 0024).
;;;
;;; A write of no bytes is refused: chez-libuv completes a write that ends in
;;; an empty span a turn late, and a close then cancels it.  PURE: imports
;;; only (rnrs).
(library (http-server transport)
  (export make-transport transport?
          transport-write! transport-read-start! transport-read-stop! transport-close!
          transport-abort! transport-deadline! transport-on-drain! transport-on-close!)
  (import (rnrs))

  (define-record-type (transport %make-transport transport?)
    (fields write read-start read-stop close deadline on-drain on-close abort))

  ;; make-transport :
  ;;   (Bytevector Nat Nat (U #f ((U #f Symbol) -> Any)) -> Any)  write
  ;;   ((Bytevector Nat Nat -> Any) (Symbol -> Any) -> Any)       read-start
  ;;   (-> Any)                                                   read-stop
  ;;   (-> Any)                                                   close
  ;;   ((U Nat #f) (U (-> Any) #f) -> Any)                        deadline
  ;;   ((-> Any) -> Any)                                          on-drain
  ;;   ((-> Any) -> Any)                                          on-close
  ;;   [(-> Any)]                                                 abort
  ;;   -> Transport
  ;; The verbs' procedures, each called with what its verb has checked.
  ;; Anything but a procedure among them is an assertion violation.  A
  ;; transport made of the first seven, as 0.3.0's were, refuses
  ;; transport-abort!, naming it.
  ;; transport? : Any -> Boolean
  (define make-transport
    (case-lambda
      ((write read-start read-stop close deadline on-drain on-close)
       (make-transport write read-start read-stop close deadline on-drain on-close
                       (lambda () (assertion-violation 'transport-abort! "a transport made without an abort"))))
      ((write read-start read-stop close deadline on-drain on-close abort)
       (for-each (lambda (p)
                   (unless (procedure? p)
                     (assertion-violation 'make-transport "a transport's verbs are procedures" p)))
                 (list write read-start read-stop close deadline on-drain on-close abort))
       (%make-transport write read-start read-stop close deadline on-drain on-close abort))))

  ;; transport-write! : Transport Bytevector [Nat Nat] [(U #f ((U #f Symbol) -> Any))] -> Any
  (define transport-write!
    (case-lambda
      ((t bv)
       (unless (bytevector? bv)
         (assertion-violation 'transport-write! "not a bytevector" bv))
       (transport-write! t bv 0 (bytevector-length bv) #f))
      ((t bv start end) (transport-write! t bv start end #f))
      ((t bv start end written)
       (unless (and (bytevector? bv) (fixnum? start) (fixnum? end)
                    (fx<=? 0 start) (fx<? start end) (fx<=? end (bytevector-length bv)))
         (assertion-violation 'transport-write! "not a range of a byte or more of a bytevector"
                              start end))
       (unless (or (not written) (procedure? written))
         (assertion-violation 'transport-write! "not a procedure" written))
       ((transport-write t) bv start end written))))

  ;; transport-read-start! : Transport (Bytevector Nat Nat -> Any) (Symbol -> Any) -> Any
  (define (transport-read-start! t on-bytes on-end)
    (unless (and (procedure? on-bytes) (procedure? on-end))
      (assertion-violation 'transport-read-start! "reading takes two procedures" on-bytes on-end))
    ((transport-read-start t) on-bytes on-end))

  ;; transport-read-stop! : Transport -> Any
  (define (transport-read-stop! t) ((transport-read-stop t)))

  ;; transport-close! : Transport -> Any
  (define (transport-close! t) ((transport-close t)))

  ;; transport-abort! : Transport -> Any
  (define (transport-abort! t) ((transport-abort t)))

  ;; transport-deadline! : Transport (U Nat #f) [(-> Any)] -> Any
  (define transport-deadline!
    (case-lambda
      ((t ms)
       (when ms
         (assertion-violation 'transport-deadline! "a deadline is armed with a procedure" ms))
       ((transport-deadline t) #f #f))
      ((t ms on-passed)
       (unless (and (fixnum? ms) (fx>=? ms 0) (procedure? on-passed))
         (assertion-violation 'transport-deadline!
           "a deadline is a count of milliseconds and a procedure" ms on-passed))
       ((transport-deadline t) ms on-passed))))

  ;; transport-on-drain! : Transport (-> Any) -> Any
  (define (transport-on-drain! t thunk)
    (unless (procedure? thunk)
      (assertion-violation 'transport-on-drain! "not a procedure" thunk))
    ((transport-on-drain t) thunk))

  ;; transport-on-close! : Transport (-> Any) -> Any
  (define (transport-on-close! t thunk)
    (unless (procedure? thunk)
      (assertion-violation 'transport-on-close! "not a procedure" thunk))
    ((transport-on-close t) thunk)))
