#!r6rs
;;; (http-server connection) — the pure connection core (design §4).
;;;
;;; `conn-step` is the connection: every libuv callback and every parser
;;; callback becomes an EVENT, and the step answers with ACTIONS for the shell
;;; to perform (decision 0002).  M2.1 fixes the vocabulary and design §4.4's
;;; nineteen transitions; the request head (M2.2), the request-target (M2.3),
;;; the pause loop (M2.4) and the hand-off door (M2.5) build on it.
;;;
;;; PURE BY CONTRACT (0002 item 1; design §6.1): a step allocates only Scheme
;;; data, calls no chez-libuv or byte-machine procedure, reads no clock, and
;;; never raises on a well-formed event.  An event outside the vocabulary is a
;;; caller bug and an assertion violation — never a runtime path.
;;;
;;; THE STATE IS LINEAR.  `conn-step` updates the state it is given in place
;;; and returns it, so a caller threads the returned state and never reuses
;;; the one it passed.  A step then allocates nothing for the state itself; the
;;; naive core that copied a record per event measured 6,832 B per request
;;; against the 3 KiB gate (design §7.5).
;;;
;;; Events and actions are tagged lists, (kind field ...):
;;;
;;;   events   (bytes-arrived bv start end)  (eof)  (read-error errno)
;;;            (write-completed nbytes)  (shutdown-completed)  (closed)
;;;            (tick now)  (parser-event callback-name . payload)
;;;            (parser-result status consumed next error pause)
;;;            (handler-responded response)  (handler-body-chunk bv start end)
;;;            (handler-body-end)  (handler-failed raised)  (body-credit n)
;;;            (shutdown-requested)
;;;
;;;   actions  (reply-parser continue|pause)  (feed-parser bv start end)
;;;            (resume-parser)  (write response)  (read-stop)  (read-start)
;;;            (call-handler request)  (deliver-body bv start end)
;;;            (deliver-body-end)  (notify-producer)  (arm-deadline kind)
;;;            (disarm-deadline)  (shutdown)  (close reason)
;;;            (log what . details)  (hand-off request)
;;;
;;; A span payload `bv start end` indexes the delivery the shell handed in; the
;;; core never copies it (design §7.1).  `reply-parser` is the one action the
;;; shell answers inside the parser callback that produced it (0002 item 3).
;;;
;;; DEADLINES ARE KINDS, NOT INSTANTS.  `(arm-deadline kind)` names which of
;;; the connection's one deadline — idle, header, body or write (design §4.3) —
;;; to arm, and carries no time: no event but `tick` carries `now`, so the core
;;; cannot turn a duration into an instant.  The shell's timing wheel does,
;;; from the limits (decision 0005, M5), and ticks a connection only once the
;;; deadline it armed has passed.  The state records the armed kind, so a tick
;;; is acted on only while the core still has a deadline of that kind armed.
(library (http-server connection)
  (export conn-states conn-events conn-actions
          make-conn-state conn-state?
          conn-phase conn-deadline conn-close-after conn-outstanding
          conn-pending conn-request
          conn-step)
  (import (rnrs) (http-server response))

  ;; conn-states : (Listof Symbol)
  ;; The nine connection states, design §4.3.  Only `idle`, `head` and `body`
  ;; read from the socket; `closed` is terminal.
  (define conn-states
    '(idle head body handling responding draining handed-off closing closed))

  ;; conn-events : (Listof Symbol)
  ;; The fifteen event kinds, decision 0002 item 2 — the closed set `conn-step`
  ;; accepts.
  (define conn-events
    '(bytes-arrived eof read-error write-completed shutdown-completed closed
      tick parser-event parser-result handler-responded handler-body-chunk
      handler-body-end handler-failed body-credit shutdown-requested))

  ;; conn-actions : (Listof Symbol)
  ;; The sixteen action kinds: decision 0002 item 2's fifteen, and the
  ;; `hand-off` that decision 0006 item 3 has the core emit for an upgrade.
  (define conn-actions
    '(reply-parser feed-parser resume-parser write read-stop read-start
      call-handler deliver-body deliver-body-end notify-producer
      arm-deadline disarm-deadline shutdown close log hand-off))

  ;; make-conn-state : Phase Deadline CloseAfter Nat Pending Request -> ConnState
  ;;   Phase      = one of conn-states (anything else is an assertion violation)
  ;;   Deadline   = (U #f 'idle 'header 'body 'write) — the kind armed, if any
  ;;   CloseAfter = (U #f Symbol) — #f keeps the connection after the response;
  ;;                a symbol closes it once the response is written, naming why
  ;;   Nat        = writes issued and not yet completed
  ;;   Pending    = (U #f (List Bytevector Nat Nat)) — input retained at a pause
  ;;   Request    = (U #f Request) — the request in flight
  ;; conn-state? : Any -> Boolean
  ;; conn-phase / -deadline / -close-after / -outstanding / -pending / -request :
  ;;   ConnState -> the corresponding field
  (define-record-type (conn-state make-conn-state conn-state?)
    (fields (mutable phase       conn-phase       conn-phase-set!)
            (mutable deadline    conn-deadline    conn-deadline-set!)
            (mutable close-after conn-close-after conn-close-after-set!)
            (mutable outstanding conn-outstanding conn-outstanding-set!)
            (mutable pending     conn-pending     conn-pending-set!)
            (mutable request     conn-request     conn-request-set!))
    (protocol
     (lambda (new)
       (lambda (phase deadline close-after outstanding pending request)
         (unless (memq phase conn-states)
           (assertion-violation 'make-conn-state "not a connection state" phase))
         (new phase deadline close-after outstanding pending request)))))

  ;; conn-step : ConnState Event -> (values ConnState (Listof Action))
  ;; One event in, the state it leaves (the same object, updated) and the
  ;; actions to perform, in order.  A vocabulary event with no transition from
  ;; the current state changes nothing and asks for nothing.
  (define (conn-step s ev)
    (case (and (pair? ev) (car ev))
      ((bytes-arrived)      (on-bytes-arrived s ev))
      ((eof)                (on-eof s))
      ((read-error)         (on-read-error s (cadr ev)))
      ((write-completed)    (on-write-completed s))
      ((tick)               (on-tick s))
      ((parser-event)       (on-parser-event s ev))
      ((parser-result)      (on-parser-result s ev))
      ((handler-responded)  (on-handler-responded s (cadr ev)))
      ((handler-failed)     (on-handler-failed s))
      ((shutdown-requested) (on-shutdown-requested s))
      ((closed)             (on-closed s))
      ;; No M2.1 row reads these: body streaming (M6) and the drain lifecycle
      ;; (M8) give them transitions.
      ((shutdown-completed handler-body-chunk handler-body-end body-credit)
       (values s '()))
      (else (assertion-violation 'conn-step "not a connection event" ev))))

  ;; The transitions, one procedure per event kind.  Each names the design
  ;; §4.4 row it implements.

  ;; idle, bytes-arrived -> idle: feed the delivery to the parser.
  (define (on-bytes-arrived s ev)
    (case (conn-phase s)
      ((idle) (values s (list (cons 'feed-parser (cdr ev)))))
      (else (values s '()))))

  ;; any reading state, eof -> closing: close, with no response.
  (define (on-eof s)
    (case (conn-phase s)
      ((idle head body) (close s 'eof '()))
      (else (values s '()))))

  ;; any live state, read-error -> closing: log it, close, no response.
  (define (on-read-error s errno)
    (case (conn-phase s)
      ((idle head body handling responding draining)
       (close s 'read-error (list (list 'log 'read-error errno))))
      (else (values s '()))))

  ;; responding, write-completed: keep waiting while writes are outstanding;
  ;; on the last one, close if the response closes the connection, otherwise
  ;; resume parsing what was retained and read again.  After a close-marked
  ;; message the retained input is dropped, never fed (decision 0004 item 4).
  (define (on-write-completed s)
    (case (conn-phase s)
      ((responding)
       (let ((left (- (conn-outstanding s) 1)))
         (conn-outstanding-set! s left)
         (cond
          ((> left 0)
           (conn-deadline-set! s 'write)
           (values s '((arm-deadline write))))
          ((conn-close-after s)
           => (lambda (reason)
                (conn-phase-set! s 'closing)
                (conn-deadline-set! s #f)
                (values s (list (list 'close reason)))))
          (else
           (let ((pending (conn-pending s)))
             (conn-phase-set! s 'idle)
             (conn-deadline-set! s 'idle)
             (conn-pending-set! s #f)
             (values s `((resume-parser)
                         ,@(if pending (list (cons 'feed-parser pending)) '())
                         (read-start)
                         (arm-deadline idle))))))))
      (else (values s '()))))

  ;; A tick means the wheel found this connection's armed deadline expired
  ;; (0005).  idle past the idle deadline -> closing, with no response; head
  ;; past the header deadline -> responding 408.  A tick with no deadline of
  ;; that kind armed changes nothing.
  (define (on-tick s)
    (case (conn-phase s)
      ((idle)
       (if (eq? (conn-deadline s) 'idle)
           (close s 'idle-timeout '())
           (values s '())))
      ((head)
       (if (eq? (conn-deadline s) 'header)
           (begin (conn-deadline-set! s #f)
                  (respond-and-close s 408 'header-timeout))
           (values s '())))
      (else (values s '()))))

  ;; The parser's callbacks.  idle, on-message-begin -> head; head, the
  ;; header callbacks -> head; head, on-headers-complete -> body; body,
  ;; on-body-data -> body; body, on-message-complete -> handling, pausing the
  ;; parser and stopping reads in the same step, so one delivery carrying two
  ;; messages cannot start a second handler (design §4.4).
  (define (on-parser-event s ev)
    (let ((name (cadr ev)))
      (case (conn-phase s)
        ((idle)
         (case name
           ((on-message-begin)
            (conn-phase-set! s 'head)
            (conn-deadline-set! s 'header)
            (values s '((reply-parser continue) (disarm-deadline) (arm-deadline header))))
           (else (values s '()))))
        ((head)
         (case name
           ((on-header-field-data on-header-field-complete
             on-header-value-data on-header-value-complete)
            (values s '((reply-parser continue))))
           ((on-headers-complete)
            (conn-phase-set! s 'body)
            (conn-deadline-set! s 'body)
            (values s '((reply-parser continue) (disarm-deadline) (arm-deadline body))))
           (else (values s '()))))
        ((body)
         (case name
           ((on-body-data)
            (conn-deadline-set! s 'body)
            (values s (list '(reply-parser continue)
                            (cons 'deliver-body (cddr ev))
                            '(arm-deadline body))))
           ((on-message-complete)
            (conn-phase-set! s 'handling)
            (conn-deadline-set! s #f)
            (values s (list '(reply-parser pause) '(read-stop) '(disarm-deadline)
                            (list 'call-handler (conn-request s)))))
           (else (values s '()))))
        (else (values s '())))))

  ;; head/body, a parser result: a pause that carries a reason hands the
  ;; stream off (0006 item 3); an error is answered with a status, then close.
  ;; Only the pause channel is read here; M2.5 adds the h2c error channel.
  ;; The status is 400 until M2.2's error-to-status map arrives (design §6.5).
  (define (on-parser-result s ev)
    (let ((status (list-ref ev 1))
          (pause  (list-ref ev 5)))
      (case (conn-phase s)
        ((head body)
         (cond
          ((and (eq? status 'paused) pause)
           (conn-phase-set! s 'handed-off)
           (conn-deadline-set! s #f)
           (values s (list '(read-stop) (list 'hand-off (conn-request s)))))
          ((eq? status 'error) (respond-and-close s 400 'parser-error))
          (else (values s '()))))
        (else (values s '())))))

  ;; handling, handler-responded -> responding: write it, arm the write deadline.
  (define (on-handler-responded s response)
    (case (conn-phase s)
      ((handling)
       (conn-phase-set! s 'responding)
       (conn-deadline-set! s 'write)
       (conn-outstanding-set! s (+ (conn-outstanding s) 1))
       (values s (list (list 'write response) '(arm-deadline write))))
      (else (values s '()))))

  ;; handling, handler-failed -> responding 500, then close.  (The bare close
  ;; for a failure after the head is on the wire needs a streamed body: M6.)
  (define (on-handler-failed s)
    (case (conn-phase s)
      ((handling) (respond-and-close s 500 'handler-failed))
      (else (values s '()))))

  ;; idle, shutdown-requested -> draining: nothing is in flight, so shut down.
  ;; The in-flight states wait for M8, which writes the rows draining leaves by.
  (define (on-shutdown-requested s)
    (case (conn-phase s)
      ((idle)
       (conn-phase-set! s 'draining)
       (values s '((shutdown))))
      (else (values s '()))))

  ;; closing, closed -> closed.
  (define (on-closed s)
    (case (conn-phase s)
      ((closing) (conn-phase-set! s 'closed) (values s '()))
      (else (values s '()))))

  ;; close : ConnState Symbol (Listof Action) -> (values ConnState (Listof Action))
  ;; Enter `closing`: the transport leaves the wheel with the handle, so no
  ;; deadline stays armed.  `before` precedes the close.
  (define (close s reason before)
    (conn-phase-set! s 'closing)
    (conn-deadline-set! s #f)
    (values s (append before (list (list 'close reason)))))

  ;; respond-and-close : ConnState Nat Symbol -> (values ConnState (Listof Action))
  ;; Enter `responding` with a status the core originates, closing afterwards
  ;; (design §6.5: every originated status closes).  The record carries no
  ;; reason and no headers: M3's serializer derives the phrase and adds
  ;; `Connection: close`.
  (define (respond-and-close s status reason)
    (conn-phase-set! s 'responding)
    (conn-close-after-set! s reason)
    (conn-outstanding-set! s (+ (conn-outstanding s) 1))
    (values s (list (list 'write (make-response status #f '() #f))))))
