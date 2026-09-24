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
;;; PARSER CALLBACKS ALSO ENTER DIRECTLY (0002's third amendment).  A tagged
;;; list per callback was the largest cost the core added per request, so the
;;; adapter calls `conn-parser-step` or `conn-headers-complete-step` with the
;;; callback's own arguments and nothing is allocated to carry them.  The
;;; `parser-event` payload has three shapes, one per way in:
;;;
;;;   (parser-event name)                  an event callback
;;;   (parser-event name bv from to)       a span callback
;;;   (parser-event on-headers-complete method http-major http-minor
;;;                 flags content-length)
;;;
;;; and `conn-step` only unpacks it and calls the entry point, so the
;;; transitions live in one place.  Either way, the first action answering a
;;; parser callback is always its `reply-parser`.
;;;
;;; THE HEAD IS KEPT AS SPANS (design §7.1).  From on-message-begin to
;;; on-headers-complete the core keeps the request-target and each header
;;; name and value as a span of the delivery it arrived in, and copies only a
;;; name or value that arrived in more than one delivery, once, when it
;;; completes.  The method and version come from on-headers-complete's
;;; fields, so the request line's other spans are not kept.  The keep-alive
;;; decision is `should-keep-alive?` over the flags read there (0002 item 4,
;;; decision 0006 item 1).  The target's limit and the four header limits are
;;; checked as the bytes arrive; one tripped is answered
;;; `(reply-parser (fail reason))`, and when the parser's error comes back the
;;; status is the reason's, not the parser's (design §6.3): 414 for the
;;; target, 431 for the headers.
;;;
;;; THE TARGET IS JUDGED at on-headers-complete, where the method is known
;;; (M2.3): it must be the RFC 9112 §3.2 form its method and first byte call
;;; for, with bytes uriparse finds valid, or the message is refused as
;;; 'invalid-target, answered 400.  (http-server target) holds the rules and
;;; one judge per connection.  For the rare absolute-form and CONNECT targets
;;; the judge runs uriparse's own scanner, never the parser calling the core
;;; (0002's amendment of 2026-09-24).  One refusal is a redirect instead
;;; (decision 0009): bracket params and pipes in a GET or HEAD, the bytes
;;; browsers send unencoded, are answered 301 with the target encoded as the
;;; Location.
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
          conn-parser-callbacks conn-span-callbacks
          make-conn-state conn-state?
          conn-phase conn-deadline conn-close-after conn-outstanding
          conn-pending conn-request conn-limits
          conn-step conn-parser-step conn-headers-complete-step)
  (import (rnrs)
          (http-server response) (http-server request) (http-server span)
          (http-server limits) (http-server decisions) (http-server target)
          (only (httparse decisions) should-keep-alive?)
          (only (httparse methods) httparse-method-numbers))

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

  ;; conn-parser-callbacks : (Listof Symbol)
  ;; chez-httparse's twenty-five parser callbacks (design §4.2), in llhttp's
  ;; trace order: the closed set the two parser entry points accept.
  (define conn-parser-callbacks
    '(on-reset on-message-begin on-method-data on-method-complete
      on-url-data on-url-complete on-protocol-data on-protocol-complete
      on-version-data on-version-complete on-status-data on-status-complete
      on-header-field-data on-header-field-complete
      on-header-value-data on-header-value-complete
      on-headers-complete on-body-data on-chunk-header
      on-chunk-extension-name-data on-chunk-extension-name-complete
      on-chunk-extension-value-data on-chunk-extension-value-complete
      on-chunk-complete on-message-complete))

  ;; conn-span-callbacks : (Listof Symbol)
  ;; The ten of them that carry a span, `bv from to`.  The other fifteen carry
  ;; nothing, except on-headers-complete, which has an entry point of its own.
  (define conn-span-callbacks
    '(on-method-data on-url-data on-protocol-data on-version-data
      on-status-data on-header-field-data on-header-value-data on-body-data
      on-chunk-extension-name-data on-chunk-extension-value-data))

  ;; make-conn-state :
  ;;   Phase Deadline CloseAfter Nat Pending Request Limits -> ConnState
  ;;   Phase      = one of conn-states (anything else is an assertion violation)
  ;;   Deadline   = (U #f 'idle 'header 'body 'write) — the kind armed, if any
  ;;   CloseAfter = (U #f Symbol) — #f keeps the connection after the response;
  ;;                a symbol closes it once the response is written, naming why
  ;;   Nat        = writes issued and not yet completed
  ;;   Pending    = (U #f (List Bytevector Nat Nat)) — input retained at a pause
  ;;   Request    = (U #f Request) — the request in flight
  ;;   Limits     = the policy the core enforces (decision 0005); anything but
  ;;                a limits record is an assertion violation
  ;; conn-state? : Any -> Boolean
  ;; conn-phase / -deadline / -close-after / -outstanding / -pending /
  ;;   -request / -limits : ConnState -> the corresponding field
  ;; The request head being read is kept in the state too, and so is the
  ;; connection's target judge (M2.3); neither is exported.
  (define-record-type (conn-state make-conn-state conn-state?)
    (fields (mutable phase       conn-phase       conn-phase-set!)
            (mutable deadline    conn-deadline    conn-deadline-set!)
            (mutable close-after conn-close-after conn-close-after-set!)
            (mutable outstanding conn-outstanding conn-outstanding-set!)
            (mutable pending     conn-pending     conn-pending-set!)
            (mutable request     conn-request     conn-request-set!)
            (immutable limits    conn-limits)
            (immutable head      conn-head)
            (immutable judge     conn-judge))
    (protocol
     (lambda (new)
       (lambda (phase deadline close-after outstanding pending request limits)
         (unless (memq phase conn-states)
           (assertion-violation 'make-conn-state "not a connection state" phase))
         (unless (limits? limits)
           (assertion-violation 'make-conn-state "not a limits record" limits))
         (new phase deadline close-after outstanding pending request limits
              (make-head) (make-target-judge))))))

  ;; The request head being read: the target and the header fields so far,
  ;; and the running sizes the header limits are checked against.  One per
  ;; connection, rolled at each on-message-begin.
  ;;   target   the request-target, once on-url-complete has run
  ;;   fields   the completed (name . value) pairs, newest first
  ;;   count    the header names completed so far
  ;;   total    the header name and value bytes so far
  ;;   name     the completed name waiting for its value
  ;;   piece    the span being read: #f, a Span, or several, newest first
  ;;   size     the bytes of the piece so far
  ;;   refusal  #f, or the reason the core answered a callback with fail
  ;;   location #f, or where a redirected target points (decision 0009)
  (define-record-type head
    (fields (mutable target) (mutable fields) (mutable count) (mutable total)
            (mutable name) (mutable piece) (mutable size) (mutable refusal)
            (mutable location))
    (protocol (lambda (new) (lambda () (new #f '() 0 0 #f #f 0 #f #f)))))

  ;; head-roll! : Head -> Void — empty the head for the next message.
  (define (head-roll! h)
    (head-target-set! h #f)
    (head-fields-set! h '())
    (head-count-set! h 0)
    (head-total-set! h 0)
    (head-name-set! h #f)
    (head-piece-set! h #f)
    (head-size-set! h 0)
    (head-refusal-set! h #f)
    (head-location-set! h #f))

  ;; The value of a piece that arrived with no bytes, such as an empty header
  ;; value: one span, shared.
  (define empty-span (make-span (make-bytevector 0) 0 0))

  ;; add-fragment! : Head Bytevector Nat Nat -> Void
  ;; One more fragment of the piece being read.  The first is kept as a span;
  ;; a piece that arrives in several, split across deliveries, is kept as a
  ;; list until it completes.
  (define (add-fragment! h bv from to)
    (let ((span (make-span bv from to)) (piece (head-piece h)))
      (head-piece-set! h (cond ((not piece) span)
                               ((span? piece) (list span piece))
                               (else (cons span piece))))
      (head-size-set! h (fx+ (head-size h) (fx- to from)))))

  ;; take-piece! : Head -> Span
  ;; The piece read so far, as one span, and start the next.  A piece that
  ;; arrived in one fragment is that fragment's span, with nothing copied.  One
  ;; that arrived in several is copied into a fresh bytevector, once.
  (define (take-piece! h)
    (let ((piece (head-piece h)) (size (head-size h)))
      (head-piece-set! h #f)
      (head-size-set! h 0)
      (cond ((not piece) empty-span)
            ((span? piece) piece)
            (else
             (let ((out (make-bytevector size)))
               (let loop ((spans (reverse piece)) (at 0))
                 (if (null? spans)
                     (make-span out 0 size)
                     (let ((sp (car spans)))
                       (bytevector-copy! (span-bytevector sp) (span-start sp)
                                         out at (span-length sp))
                       (loop (cdr spans) (fx+ at (span-length sp)))))))))))

  ;; method-symbols : (Vectorof (U Symbol #f))
  ;; llhttp's method numbers, as the symbols (httparse methods) names them,
  ;; indexed by number, so naming a request's method allocates nothing.
  (define method-symbols
    (let ((v (make-vector (fx+ 1 (fold-left (lambda (m row) (fxmax m (cdr row)))
                                            0 httparse-method-numbers))
                          #f)))
      (for-each (lambda (row) (vector-set! v (cdr row) (string->symbol (car row))))
                httparse-method-numbers)
      v))

  ;; method-name : Nat -> Symbol — the method llhttp numbers `n`; any other
  ;; number is an assertion violation.
  (define (method-name n)
    (or (and (fixnum? n) (fx<? -1 n (vector-length method-symbols))
             (vector-ref method-symbols n))
        (assertion-violation 'conn-headers-complete-step "not an llhttp method number" n)))

  ;; conn-step : ConnState Event -> (values ConnState (Listof Action))
  ;; One event in, the state it leaves (the same object, updated) and the
  ;; actions to perform, in order.  A vocabulary event with no transition from
  ;; the current state changes nothing and asks for nothing, except that a
  ;; parser callback is always answered.
  (define (conn-step s ev)
    (case (and (pair? ev) (car ev))
      ((bytes-arrived)      (on-bytes-arrived s ev))
      ((eof)                (on-eof s))
      ((read-error)         (on-read-error s (cadr ev)))
      ((write-completed)    (on-write-completed s))
      ((tick)               (on-tick s))
      ((parser-event)       (on-parser-event s (cadr ev) (cddr ev)))
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

  ;; idle, bytes-arrived -> idle: feed the delivery to the parser.  head and
  ;; body feed it too, for a message that arrives in more than one delivery.
  (define (on-bytes-arrived s ev)
    (case (conn-phase s)
      ((idle head body) (values s (list (cons 'feed-parser (cdr ev)))))
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
                  (respond-and-close s 'header-timeout '()))
           (values s '())))
      (else (values s '()))))

  ;; A parser callback as a tagged list: unpack the payload and call the entry
  ;; point the adapter calls directly (0002's third amendment, item 3).  A
  ;; payload of the wrong length is an assertion violation, from the entry
  ;; point's own check or from the call itself.
  (define (on-parser-event s name payload)
    (cond
     ((eq? name 'on-headers-complete)
      (apply conn-headers-complete-step s payload))
     ((null? payload) (conn-parser-step s name))
     (else (apply conn-parser-step s name payload))))

  ;; conn-parser-step : ConnState Symbol -> (values ConnState (Listof Action))
  ;; conn-parser-step : ConnState Symbol Bytevector Nat Nat
  ;;                    -> (values ConnState (Listof Action))
  ;; A parser callback, entered with the callback's own arguments: its name
  ;; alone for an event callback, its name and span for a span callback.  The
  ;; first action is always the callback's (reply-parser outcome).  A name
  ;; outside conn-parser-callbacks, on-headers-complete (which enters through
  ;; conn-headers-complete-step) or a span given to the wrong kind of callback
  ;; is an assertion violation.
  (define conn-parser-step
    (case-lambda
      ((s name)
       (check-callback name #f)
       (on-callback s name #f 0 0))
      ((s name bv from to)
       (check-callback name #t)
       (on-callback s name bv from to))))

  ;; check-callback : Symbol Boolean -> Void
  ;; Refuse a callback outside the closed set, or one given the wrong shape.
  (define (check-callback name span?)
    (cond
     ((not (memq name conn-parser-callbacks))
      (assertion-violation 'conn-parser-step "not a parser callback" name))
     ((eq? name 'on-headers-complete)
      (assertion-violation 'conn-parser-step
        "on-headers-complete enters through conn-headers-complete-step" name))
     ((and span? (not (memq name conn-span-callbacks)))
      (assertion-violation 'conn-parser-step "an event callback carries no span" name))
     ((and (not span?) (memq name conn-span-callbacks))
      (assertion-violation 'conn-parser-step "a span callback needs its span" name))))

  ;; The callbacks' transitions.  idle, on-message-begin -> head, with a fresh
  ;; head; in head, the target and the header fields are kept, each refused
  ;; once it grows past its limit; body,
  ;; on-body-data -> body; body, on-message-complete -> handling, pausing the
  ;; parser and stopping reads in the same step, so one delivery carrying two
  ;; messages cannot start a second handler (design §4.4).  Every other
  ;; callback, and these outside their states, changes nothing and answers
  ;; continue: the parser always gets an answer.
  (define (on-callback s name bv from to)
    (case name
      ((on-message-begin)
       (case (conn-phase s)
         ((idle)
          (head-roll! (conn-head s))
          (conn-request-set! s #f)
          (conn-phase-set! s 'head)
          (conn-deadline-set! s 'header)
          (values s '((reply-parser continue) (disarm-deadline) (arm-deadline header))))
         (else (continue s))))
      ((on-url-data)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (add-fragment! h bv from to)
            (if (fx>? (head-size h) (limits-max-target-bytes (conn-limits s)))
                (refuse s 'target-too-large)
                (continue s))))
         (else (continue s))))
      ((on-url-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s))) (head-target-set! h (take-piece! h)))
          (continue s))
         (else (continue s))))
      ((on-header-field-data)
       (case (conn-phase s)
         ((head) (header-bytes s bv from to limits-max-header-field-bytes
                               'header-field-too-large))
         (else (continue s))))
      ((on-header-field-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (head-count-set! h (fx+ (head-count h) 1))
            (head-name-set! h (take-piece! h))
            (if (fx>? (head-count h) (limits-max-header-count (conn-limits s)))
                (refuse s 'too-many-headers)
                (continue s))))
         (else (continue s))))
      ((on-header-value-data)
       (case (conn-phase s)
         ((head) (header-bytes s bv from to limits-max-header-value-bytes
                               'header-value-too-large))
         (else (continue s))))
      ((on-header-value-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (head-fields-set! h (cons (cons (head-name h) (take-piece! h)) (head-fields h)))
            (head-name-set! h #f)
            (continue s)))
         (else (continue s))))
      ((on-body-data)
       (case (conn-phase s)
         ((body)
          (conn-deadline-set! s 'body)
          (values s (list '(reply-parser continue)
                          (list 'deliver-body bv from to)
                          '(arm-deadline body))))
         (else (continue s))))
      ((on-message-complete)
       (case (conn-phase s)
         ((body)
          (conn-phase-set! s 'handling)
          (conn-deadline-set! s #f)
          (values s (list '(reply-parser pause) '(read-stop) '(disarm-deadline)
                          (list 'call-handler (conn-request s)))))
         (else (continue s))))
      (else (continue s))))

  ;; header-bytes : ConnState Bytevector Nat Nat (Limits -> Nat) Symbol
  ;;                -> (values ConnState (Listof Action))
  ;; A fragment of a header name or value: keep it, and refuse the message
  ;; once the name or value, or the header section, grows past its limit.
  (define (header-bytes s bv from to piece-limit piece-reason)
    (let ((h (conn-head s)) (limits (conn-limits s)))
      (add-fragment! h bv from to)
      (head-total-set! h (fx+ (head-total h) (fx- to from)))
      (cond ((fx>? (head-size h) (piece-limit limits)) (refuse s piece-reason))
            ((fx>? (head-total h) (limits-max-header-bytes limits))
             (refuse s 'headers-too-large))
            (else (continue s)))))

  ;; refuse : ConnState Symbol -> (values ConnState (Listof Action))
  ;; A limit tripped inside a parser callback (design §6.3): tell the parser to
  ;; fail with the reason as its code, and hold the reason for the parser's
  ;; error result, which is answered with the reason's status.  The state
  ;; stays where it is until that result arrives (design §4.4's head row).
  (define (refuse s reason)
    (head-refusal-set! (conn-head s) reason)
    (values s (list (list 'reply-parser (list 'fail reason)))))

  ;; conn-headers-complete-step :
  ;;   ConnState Nat Nat Nat Nat Nat -> (values ConnState (Listof Action))
  ;;   method http-major http-minor flags content-length
  ;; on-headers-complete, entered with the five parser fields the adapter reads
  ;; inside the callback (0002 item 4): llhttp's method number, the version,
  ;; llhttp's flag bits and the content-length.  Read there, content-length is
  ;; the declared length, since it counts down as the body arrives, and the
  ;; parser's reset after each message zeroes it and the flags.  Nothing
  ;; downstream re-reads the parser.  The content-length is the body's, M6's.
  ;; The target is judged here, where the method is known (M2.3; see
  ;; (http-server target)).  One that is not the form its method calls for,
  ;; or whose bytes uriparse refuses, is refused, and the state stays in head
  ;; until the parser's error arrives:
  ;;   - as 'target-redirect, answered 301 with a Location, when it is the
  ;;     narrow case decision 0009 redirects: bracket params and pipes in a
  ;;     GET or HEAD, encoded to a target within max-target-bytes;
  ;;   - as 'invalid-target, answered 400, otherwise.
  ;; An accepted target moves head -> body: the request is built from the
  ;; head, the connection is marked to close after the response unless the
  ;; message keeps it alive (decision 0006 item 1), and the header deadline
  ;; gives way to the body's.
  (define (conn-headers-complete-step s method http-major http-minor flags content-length)
    (case (conn-phase s)
      ((head)
       (let* ((h (conn-head s))
              (name (method-name method))
              (target (or (head-target h) empty-span)))
         (cond
          ((not (target-fault (conn-judge s) name target))
           (conn-request-set! s (make-request name target http-major http-minor
                                              (reverse (head-fields h)) #f))
           (unless (should-keep-alive? http-major http-minor 'request 0 flags)
             (conn-close-after-set! s 'not-keep-alive))
           (conn-phase-set! s 'body)
           (conn-deadline-set! s 'body)
           (values s '((reply-parser continue) (disarm-deadline) (arm-deadline body))))
          ((redirect-location s name target)
           => (lambda (location)
                (head-location-set! h location)
                (refuse s 'target-redirect)))
          (else (refuse s 'invalid-target)))))
      (else (continue s))))

  ;; redirect-location : ConnState Symbol Span -> (U #f Bytevector)
  ;; Where a refused target is redirected: (http-server target)'s answer, if
  ;; the target it names is within max-target-bytes, so that a Location is
  ;; always a target this connection accepts.
  (define (redirect-location s name target)
    (let ((location (target-redirect (conn-judge s) name target)))
      (and location
           (fx<=? (bytevector-length location) (limits-max-target-bytes (conn-limits s)))
           location)))

  ;; continue : ConnState -> (values ConnState (Listof Action))
  ;; Answer a parser callback and change nothing.  The list is a constant, so
  ;; this allocates nothing.
  (define (continue s) (values s '((reply-parser continue))))

  ;; head/body, a parser result: a pause that carries a reason hands the
  ;; stream off (0006 item 3); an error is answered with a status, then close.
  ;; Only the pause channel is read here; M2.5 adds the h2c error channel.  An
  ;; error the core asked for with `fail` is answered with its reason's status
  ;; (design §6.3); any other is a parser error, 400 until M2.5 reads the
  ;; parser's code through (http-server decisions)' map.
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
          ((eq? status 'error)
           (respond-and-close s (or (head-refusal (conn-head s)) 'parser-error)
                             (refusal-headers (conn-head s))))
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
      ((handling) (respond-and-close s 'handler-failed '()))
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

  ;; respond-and-close :
  ;;   ConnState Symbol Headers -> (values ConnState (Listof Action))
  ;; Enter `responding` with a status the core originates, closing afterwards
  ;; for `reason` (design §6.5: every originated status closes).  The status
  ;; is the reason's, from (http-server decisions).  The record carries no
  ;; reason phrase, and no headers but `headers`, a redirect's Location: M3's
  ;; serializer derives the phrase and adds `Connection: close`.
  (define (respond-and-close s reason headers)
    (conn-phase-set! s 'responding)
    (conn-close-after-set! s reason)
    (conn-outstanding-set! s (+ (conn-outstanding s) 1))
    (values s (list (list 'write (make-response (reason-status reason) #f headers #f)))))

  ;; refusal-headers : Head -> Headers
  ;; The headers a refused message's response carries: a redirect's
  ;; Location, or none.
  (define (refusal-headers h)
    (let ((location (head-location h)))
      (if location (list (cons location-name location)) '())))

  ;; The Location header's name, shared by every redirect.
  (define location-name (string->utf8 "Location")))
