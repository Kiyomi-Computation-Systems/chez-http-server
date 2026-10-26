#!r6rs
;;; (http-server private adapter) — chez-httparse's parser, bound to the core.
;;;
;;; The binding list chez-httparse requires: all twenty-five callbacks, built
;;; once and shared by every connection, which reaches its callbacks through
;;; the parser's user-context argument, where a list per connection would cost
;;; 1,216 B each.  Each callback enters the core directly, with its own
;;; arguments, so nothing is allocated to carry it; on-headers-complete also
;;; reads the parser fields the core needs from it: the five the parser's
;;; reset between messages would otherwise lose, and `upgrade`, llhttp's
;;; answer to whether the message upgrades, which is this message's only from
;;; on-headers-complete on (chez-httparse v0.4.1 or later).  Every event
;;; callback also passes the parser's position, `parser-stream-offset`, the
;;; bytes it has read, which its runtime commits before calling it
;;; (chez-httparse v0.4.4 or later, its docs/api.org, "Where a callback is in
;;; the stream"): the core measures by it what the parser reads and hands no
;;; span of.  And the event a feed's result becomes is built here, once, for
;;; both shells, from the result alone: at an error, with the refused byte's
;;; position and the span the error abandoned, by which the core judges what
;;; the error cut off.
;;;
;;; The core's first action is its `reply-parser`, and that one is answered
;;; here, inside the callback: continue, pause, or a failure carrying the
;;; core's reason as its code.  The rest go, in order, to the queue the shell
;;; gave the connection's context, and the shell runs them once the feed has
;;; returned: nothing but the reply runs at parser depth (the message-loop
;;; suite checks it).
;;;
;;; Both shells bind the parser here, the libuv shell, (http-server private
;;; shell), and the tests' fake shell, so the core's checks and the trace lane
;;; run on the real parser; tests/test-connection-allocation.sps checks the
;;; list is shared.  Imports no chez-libuv.
(library (http-server private adapter)
  (export make-conn-context conn-context? conn-context-state
          conn-context-step!
          adapter-bindings request-parser-inits make-conn-parser parser-result-event)
  (import (rnrs)
          (byte-machine runtime) (generated httparse-message) (httparse modes)
          (http-server connection))

  ;; make-conn-context : ConnState ((Listof Action) -> Any) -> ConnContext
  ;; One connection as the parser sees it: the core's state, and `queue!`,
  ;; where the actions its callbacks ask for go.  `queue!` is the shell's.
  ;; It is called inside a parser callback with the actions after the reply,
  ;; in order, when there are any, and must only queue them: the shell runs
  ;; them after the feed has returned.
  ;; conn-context? : Any -> Boolean
  ;; conn-context-state : ConnContext -> ConnState
  (define-record-type (conn-context make-conn-context conn-context?)
    (fields (mutable state conn-context-state conn-context-state-set!)
            (immutable queue! conn-context-queue!)))

  ;; conn-context-step! : ConnContext Event -> (Listof Action)
  ;; Deliver one of the shell's events to the core, keep the state it leaves,
  ;; and answer the actions it asks for.
  (define (conn-context-step! ctx event)
    (let-values (((s actions) (conn-step (conn-context-state ctx) event)))
      (conn-context-state-set! ctx s)
      actions))

  ;; answer! : ConnContext ConnState (Listof Action) -> Outcome
  ;; Keep the state, hand every action but the first to the shell's queue,
  ;; and turn the first, the reply, into the parser's outcome.
  (define (answer! ctx s actions)
    (conn-context-state-set! ctx s)
    (unless (and (pair? actions) (pair? (car actions))
                 (eq? (caar actions) 'reply-parser))
      (assertion-violation 'adapter "the core did not answer the callback first" actions))
    (unless (null? (cdr actions))
      ((conn-context-queue! ctx) (cdr actions)))
    (let ((outcome (cadar actions)))
      (cond ((eq? outcome 'continue) callback-continue)
            ((eq? outcome 'pause) callback-pause)
            ((and (pair? outcome) (eq? (car outcome) 'fail))
             (make-callback-failure (cadr outcome) #f))
            (else (assertion-violation 'adapter "not a reply-parser outcome" outcome)))))

  ;; adapter-bindings : (Listof (List Symbol Procedure))
  ;; The twenty-five bindings, in conn-parser-callbacks' order: a span
  ;; callback's procedure takes (parser context bv from to), every other one
  ;; (parser context).  The context is the connection's ConnContext.
  (define adapter-bindings
    (map (lambda (name)
           (list name
                 (cond
                  ((eq? name 'on-headers-complete)
                   (lambda (p ctx)
                     (let-values (((s actions)
                                   (conn-headers-complete-step
                                    (conn-context-state ctx)
                                    (parser-field-ref p 'method)
                                    (parser-field-ref p 'http-major)
                                    (parser-field-ref p 'http-minor)
                                    (parser-field-ref p 'flags)
                                    (parser-field-ref p 'content-length)
                                    (parser-field-ref p 'upgrade)
                                    (parser-stream-offset p))))
                       (answer! ctx s actions))))
                  ((memq name conn-span-callbacks)
                   (lambda (p ctx bv from to)
                     (let-values (((s actions)
                                   (conn-parser-step (conn-context-state ctx) name bv from to)))
                       (answer! ctx s actions))))
                  (else
                   (lambda (p ctx)
                     (let-values (((s actions) (conn-parser-step (conn-context-state ctx) name
                                                                 (parser-stream-offset p))))
                       (answer! ctx s actions)))))))
         conn-parser-callbacks))

  ;; parser-result-event : ParserResult -> Event
  ;; What a feed's result tells the core, as both shells hand it over:
  ;; `(parser-result status offset next code span)`.  `offset` is the
  ;; parser's count of the bytes it has taken, `parser-result-stream-offset`;
  ;; at an error of the parser's own, the refused byte's position: the
  ;; count, less one where the parser took the byte before refusing it, an
  ;; error whose position kind is `boundary`.  That byte is never the
  ;; token's in this grammar, which byte-machine leaves to the grammar to
  ;; say.  A callback's failure, the core's own refusal, refuses no byte,
  ;; and keeps the count.  `code` is the
  ;; error's code or the pause's, since a result has one or neither, or #f.
  ;; `span` is, at an error with a span open, the span the error abandoned
  ;; and where its withheld bytes begin, `(name . offset)`, as the error
  ;; records them (`parser-error-span`, `parser-error-span-offset`,
  ;; byte-machine v0.7.0 or later), and otherwise #f.
  (define (parser-result-event r)
    (let ((e (parser-result-error r)) (offset (parser-result-stream-offset r)))
      (list 'parser-result (parser-result-status r)
            (if (and e (eq? (parser-error-domain e) 'machine)
                     (eq? (parser-error-position-kind e) 'boundary))
                (- offset 1)
                offset)
            (parser-result-next r)
            (let ((c (or e (parser-result-pause r)))) (and c (parser-error-code c)))
            (and e (parser-error-span e)
                 (cons (parser-error-span e) (parser-error-span-offset e))))))

  ;; request-parser-inits : (Listof (Pair Symbol Any))
  ;; The settings a request parser is made with: it reads requests, and is
  ;; strict but for one of llhttp's lenient flags, its version: it reads any
  ;; HTTP/D.D, and leaves the version to the core, which serves 1.x and
  ;; refuses every other version 505.
  (define request-parser-inits
    (list (cons 'type (httparse-message-type-value 'request))
          (cons 'lenient-flags (httparse-lenient-flags-value '(version)))))

  ;; make-conn-parser : ConnContext -> Parser
  ;; A request parser for one connection, carrying the context to every
  ;; callback, made with request-parser-inits.
  (define (make-conn-parser ctx)
    (make-parser httparse-message-machine adapter-bindings ctx request-parser-inits)))
