#!r6rs
;;; (http-server private adapter) — chez-httparse's parser, bound to the core.
;;;
;;; The binding list chez-httparse requires: all twenty-five callbacks, built
;;; once and shared by every connection, which reaches its callbacks through
;;; the parser's user-context argument (design §7.5: a list per connection
;;; would cost 1,216 B each).  Each callback enters the core directly, with
;;; its own arguments, so nothing is allocated to carry it (0002's third
;;; amendment); on-headers-complete also reads the parser fields the core
;;; needs from it (0002 item 4): the five the parser's reset between messages
;;; would otherwise lose, and `upgrade`, llhttp's answer to whether the message
;;; upgrades, which is this message's only from on-headers-complete on
;;; (chez-httparse v0.4.1, #47).  Every event callback also passes the
;;; parser's position, `parser-stream-offset`, the bytes it has read, which
;;; its runtime commits before calling it (chez-httparse's docs/api.org,
;;; "Where a callback is in the stream", since v0.4.4 for its #55): the core
;;; measures by it what the parser reads and hands no span of (the padding
;;; PR).  And the event a feed's result becomes is built here, once, for both
;;; shells, from the result alone: at an error, with the refused byte's
;;; position and the span the error abandoned, by which the core judges what
;;; the error cut off (the cut-off-span PR).
;;;
;;; The core's first action is its `reply-parser`, and that one is answered
;;; here, inside the callback (0002 item 3): continue, pause, or a failure
;;; carrying the core's reason as its code.  The rest go, in order, to the
;;; queue the shell gave the connection's context, and the shell runs them
;;; once the feed has returned: nothing but the reply runs at parser depth
;;; (design §4.5; M2.4's fake shell checks it).
;;;
;;; Brought forward from M4.1 (milestone plan §8), because M2.2's checks need
;;; the core driven by the real parser: the head's tests, and the trace lane
;;; with these bindings installed.  The shell's closures are (http-server
;;; private shell)'s (M4.2), and tests/test-connection-allocation.sps checks
;;; the list is shared (M4.1).  Imports no chez-libuv.
(library (http-server private adapter)
  (export make-conn-context conn-context? conn-context-state
          conn-context-step!
          adapter-bindings make-conn-parser parser-result-event)
  (import (rnrs)
          (byte-machine runtime) (generated httparse-message) (httparse modes)
          (http-server connection))

  ;; make-conn-context : ConnState ((Listof Action) -> Any) -> ConnContext
  ;; One connection as the parser sees it: the core's state, and `queue!`,
  ;; where the actions its callbacks ask for go.  `queue!` is the shell's.
  ;; It is called inside a parser callback with the actions after the reply,
  ;; in order, when there are any, and must only queue them: the shell runs
  ;; them after the feed has returned (design §4.5).
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
  ;; `(parser-result status offset next code span)` (decision 0002's
  ;; amendments of 2026-10-01).  `offset` is the parser's count of the bytes
  ;; it has taken, `parser-result-stream-offset`; at an error of the
  ;; parser's own, the refused byte's position: the count, less one where
  ;; the parser took the byte before refusing it, an error whose position
  ;; kind is `boundary`.  That byte is never the token's in this grammar,
  ;; which byte-machine leaves to the grammar to say (its .reference/
  ;; transition-and-cursor-semantics.md §4).  A callback's failure, the
  ;; core's own refusal, refuses no byte, and keeps the count.  `code` is the
  ;; error's code or the pause's, since a result has one or neither, or #f.
  ;; `span` is, at an error with a span open, the span the error abandoned
  ;; and where its withheld bytes begin, `(name . offset)`, as the error
  ;; records them (`parser-error-span`, `parser-error-span-offset`, since
  ;; byte-machine v0.7.0 for its #145), and otherwise #f.
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

  ;; make-conn-parser : ConnContext -> Parser
  ;; A request parser for one connection, strict (no lenient flags), carrying
  ;; the context to every callback.
  (define make-conn-parser
    (let ((inits (list (cons 'type (httparse-message-type-value 'request)))))
      (lambda (ctx)
        (make-parser httparse-message-machine adapter-bindings ctx inits)))))
