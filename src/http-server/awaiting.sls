#!r6rs
;;; (http-server awaiting) — the answer of a handler that waits (decision
;;; 0014; M7.1).
;;;
;;; A handler answers a response or a reader (decision 0013), or, to wait,
;;; `(awaiting thunk)`: the server runs `thunk` on a coroutine of its own,
;;; from its scheduler's drain, and what `thunk` returns is the handler's
;;; answer, a response or a reader, or another `awaiting`, which waits
;;; again.  The reader or the producer it answers with is called on
;;; coroutines too, so it may wait as well.  Only code a coroutine runs may
;;; wait: anywhere else a wait is refused (design §5.3, R1 and R2), and the
;;; handler has failed.
;;;
;;; PURE: imports only (rnrs).
(library (http-server awaiting)
  (export awaiting awaiting? awaiting-thunk)
  (import (rnrs))

  ;; awaiting : (-> Answer) -> Awaiting
  ;;   Answer = Response | BodyReader | Awaiting
  ;; The answer of a handler that waits: `thunk`, run on a coroutine, gives
  ;; the answer.  A thunk that is not a procedure is an assertion violation.
  ;; awaiting? : Any -> Boolean
  ;; awaiting-thunk : Awaiting -> (-> Answer)
  (define-record-type (awaiting-answer awaiting awaiting?)
    (fields (immutable thunk awaiting-thunk))
    (protocol
     (lambda (new)
       (lambda (thunk)
         (unless (procedure? thunk)
           (assertion-violation 'awaiting "not a procedure" thunk))
         (new thunk))))
    (sealed #t)))
