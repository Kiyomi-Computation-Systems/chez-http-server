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
;;; What a wait raises is here too, so that a handler can catch it: once a
;;; deadline has passed, a wait inside it raises `&deadline-passed`; and a
;;; name that does not resolve raises `&resolve-error` (decision 0015;
;;; `with-deadline` and `resolve`, the private waits library's).  Once the
;;; request's client has closed or reset its connection, the wait its code
;;; is in, or else the next one, raises `&client-closed`, once (decision
;;; 0020).
;;;
;;; PURE: imports only (rnrs).
(library (http-server awaiting)
  (export awaiting awaiting? awaiting-thunk
          &deadline-passed make-deadline-passed deadline-passed?
          &client-closed make-client-closed client-closed?
          &resolve-error make-resolve-error resolve-error? resolve-error-reason)
  (import (rnrs))

  ;; &deadline-passed : what a wait raises once a deadline it waits inside
  ;; has passed, an `&error`.
  ;; make-deadline-passed : -> DeadlinePassed
  ;; deadline-passed? : Any -> Boolean
  (define-condition-type &deadline-passed &error
    make-deadline-passed deadline-passed?)

  ;; &client-closed : what a wait raises, once, after the request's client
  ;; has closed or reset its connection (decision 0020), an `&error`.
  ;; make-client-closed : -> ClientClosed
  ;; client-closed? : Any -> Boolean
  (define-condition-type &client-closed &error
    make-client-closed client-closed?)

  ;; &resolve-error : what `resolve` raises when a name does not resolve, an
  ;; `&error`.  Its reason is the resolver's error, such as EAI_NONAME, or
  ;; `invalid-name` for a name it cannot be asked about.
  ;; make-resolve-error : Symbol -> ResolveError
  ;; resolve-error? : Any -> Boolean
  ;; resolve-error-reason : ResolveError -> Symbol
  (define-condition-type &resolve-error &error
    make-resolve-error resolve-error?
    (reason resolve-error-reason))

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
