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
;;; never raises on a well-formed event.  An event outside the vocabulary, or
;;; one the state says cannot have happened, such as a completion for bytes
;;; the core did not write (M3.3), is a caller bug and an assertion violation
;;; — never a runtime path.
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
;;;            (resume-parser)  (write segments nbytes)  (read-stop)  (read-start)
;;;            (call-handler request)  (deliver-body bv start end)
;;;            (deliver-body-end)  (notify-producer)  (arm-deadline kind)
;;;            (disarm-deadline)  (shutdown)  (close reason)
;;;            (log what . details)  (hand-off request)
;;;
;;; A parser-result's `error` is #f or the error's code, and its `pause` #f
;;; or the pause's code.  A span payload `bv start end` indexes the delivery
;;; the shell handed in; the core never copies it (design §7.1).
;;; `reply-parser` is the one action the shell answers inside the parser
;;; callback that produced it (0002 item 3).
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
;;;                 flags content-length upgrade)
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
;;; THE HOST IS JUDGED FIRST, at the same moment (RFC 9112 §3.2; decided on
;;; the owner's word, 2026-09-25): two Host lines, a Host value that is not
;;; `uri-host [ ":" port ]`, and no Host on HTTP/1.1 unless the limits'
;;; switch is off, are refused as 'invalid-host, answered 400.  The 400 is a
;;; MUST, so a target the redirect would take never reaches it.
;;; (http-server host) holds the rules; the value is judged in place.
;;;
;;; THE TRANSFER-ENCODING IS JUDGED TOO, from the parser's flags (RFC 9112
;;; §6.1; decided on the owner's word, 2026-09-26).  A request below HTTP/1.1
;;; that carries it has faulty framing: it is refused as 'faulty-framing,
;;; answered 400, right after the Host, since both rules are MUSTs.  The
;;; codings come last, once the target is accepted.  The server implements
;;; one coding, chunked, so when the parser frames the body by a final
;;; chunked (its F-CHUNKED flag) and the Transfer-Encoding lists another
;;; coding beside it, the request is refused as 'unsupported-transfer-coding,
;;; answered 501.  Every other invalid Transfer-Encoding the parser refuses
;;; itself, and its error is a 400.  (http-server transfer-coding) holds both
;;; rules.
;;;
;;; THE PAUSE KEEPS THE REST OF THE DELIVERY (M2.4; decision 0004 item 1).
;;; At on-message-complete the core pauses the parser, stops reading and
;;; calls the handler, all in one step, so a delivery carrying two messages
;;; cannot start a second handler before the first response is written.
;;; Where the parser stopped is known only once the feed returns, so the
;;; `parser-result` that follows keeps the delivery's rest, from
;;; `parser-result-next`, as the pending input, and the resume after the
;;; response feeds it.  The rest is always the end of the last delivery the
;;; core fed: reading stops at the pause and the rest is fed before reading
;;; starts again, so no other delivery comes between.  The core remembers
;;; that delivery for this.  After a close-marked message the rest is
;;; dropped, never fed (0004 item 4), so llhttp's "Data after `Connection:
;;; close`" error cannot fire; an error result after the pause is not
;;; answered.
;;;
;;; AN UPGRADE IS SERVED, THEN THE CONNECTION CLOSES (M2.5; decision 0006's
;;; amendment, on the owner's word, 2026-09-25).  A request that asks to
;;; switch protocols, by llhttp's rule a CONNECT or `Connection: upgrade` with
;;; `Upgrade`, which the parser's `upgrade` field answers (chez-httparse
;;; v0.4.1, #47), reaches the handler like any other, and
;;; the connection closes after the response, as a close-marked message's
;;; does.  So its pause at on-message-complete is the last: the parser is
;;; never resumed onto its own hand-off, and the bytes after the request,
;;; another protocol's, are never read.  v1 has nothing to hand them to.
;;; `Upgrade: h2c` is such a request.  The HTTP/2 preface is not a request: it
;;; hands off on the parser's error channel (`result-hands-off-stream?` checks
;;; both), and the core answers it 505, then close.  The pause channel's
;;; hand-off (design §4.4's head/body row, `handed-off`) is the door M8 opens
;;; for a handler that takes upgrades; the core's own flow never reaches it.
;;;
;;; A RESPONSE IS WRITTEN AS SEGMENTS (M3.2; design §7.3; decision 0010).
;;; `(write segments nbytes)` is one write: (http-server serializer)'s
;;; segments, the Date slot among them as the symbol `date` for the shell to
;;; fill, and the bytes they come to.  The framing is (http-server
;;; decisions)', for the request being answered: its method, its version and
;;; the response's status and body.  The Connection field says `close` when
;;; the connection closes after the response, which a close-delimited body
;;; always does.  A handler's response the serializer cannot write safely is
;;; answered 500 instead, then close, with `(log invalid-response fault)`
;;; before it, and a handler's `Connection: close` closes the connection
;;; after its response.  The core's own responses are framed the same way,
;;; with no body.  Every entry into `responding` arms the write deadline
;;; (design §4.3), the core's own responses included.
;;;
;;; A WRITE IS COUNTED, NOT KEPT (M3.3; design §7.3; decision 0010 item 5).
;;; Each write is outstanding, with the bytes it comes to, until the shell
;;; reports `(write-completed nbytes)`, in `responding` or, for a write a
;;; close cut short, in `closing`.  A completion the core did not ask for is
;;; an assertion violation.  M6's write watermarks will read
;;; the bytes outstanding.  The core keeps nothing of the response itself:
;;; chez-libuv copies the segments when the write is issued, so nothing
;;; needs them after that (tests/test-connection-retention.sps checks it).
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
          conn-outstanding-bytes conn-pending conn-request conn-limits
          conn-step conn-parser-step conn-headers-complete-step)
  (import (rnrs)
          (http-server response) (http-server request) (http-server span)
          (http-server limits) (http-server decisions) (http-server target)
          (only (http-server host) host-fault)
          (only (http-server transfer-coding) unsupported-transfer-coding? faulty-framing?)
          (only (http-server serializer)
                serialize-response serialize-checked-response response-fault response-closes?)
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
  ;;   Phase Deadline CloseAfter Nat Nat Pending Request Limits -> ConnState
  ;;   Phase      = one of conn-states (anything else is an assertion violation)
  ;;   Deadline   = (U #f 'idle 'header 'body 'write) — the kind armed, if any
  ;;   CloseAfter = (U #f Symbol) — #f keeps the connection after the response;
  ;;                a symbol closes it once the response is written, naming why
  ;;   Nat, Nat   = the writes issued and not yet completed, and the bytes
  ;;                they come to: counts, zero together, since every write
  ;;                has bytes, a status line at least (anything else is an
  ;;                assertion violation)
  ;;   Pending    = (U #f (List Bytevector Nat Nat)) — input retained at a pause
  ;;   Request    = (U #f Request) — the request in flight
  ;;   Limits     = the policy the core enforces (decision 0005); anything but
  ;;                a limits record is an assertion violation
  ;; conn-state? : Any -> Boolean
  ;; conn-phase / -deadline / -close-after / -outstanding / -outstanding-bytes
  ;;   / -pending / -request / -limits : ConnState -> the corresponding field
  ;; The request head being read is kept in the state too, and so are the
  ;; connection's target judge (M2.3) and the last delivery it fed the
  ;; parser, `(bv start end)` or #f (M2.4); none of them is exported.
  (define-record-type (conn-state make-conn-state conn-state?)
    (fields (mutable phase       conn-phase       conn-phase-set!)
            (mutable deadline    conn-deadline    conn-deadline-set!)
            (mutable close-after conn-close-after conn-close-after-set!)
            (mutable outstanding conn-outstanding conn-outstanding-set!)
            (mutable outstanding-bytes conn-outstanding-bytes conn-outstanding-bytes-set!)
            (mutable pending     conn-pending     conn-pending-set!)
            (mutable request     conn-request     conn-request-set!)
            (immutable limits    conn-limits)
            (immutable head      conn-head)
            (immutable judge     conn-judge)
            (mutable delivery    conn-delivery    conn-delivery-set!))
    (protocol
     (lambda (new)
       (lambda (phase deadline close-after outstanding outstanding-bytes pending request limits)
         (unless (memq phase conn-states)
           (assertion-violation 'make-conn-state "not a connection state" phase))
         (unless (limits? limits)
           (assertion-violation 'make-conn-state "not a limits record" limits))
         (unless (and (fixnum? outstanding) (fx>=? outstanding 0)
                      (fixnum? outstanding-bytes) (fx>=? outstanding-bytes 0)
                      (eq? (fxzero? outstanding) (fxzero? outstanding-bytes)))
           (assertion-violation 'make-conn-state
             "not writes and bytes outstanding, counts that are zero together"
             outstanding outstanding-bytes))
         (new phase deadline close-after outstanding outstanding-bytes pending request limits
              (make-head) (make-target-judge) #f)))))

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
  ;; parser callback is always answered.  An event the state says cannot
  ;; have happened is an assertion violation (see the header).
  (define (conn-step s ev)
    (case (and (pair? ev) (car ev))
      ((bytes-arrived)      (on-bytes-arrived s ev))
      ((eof)                (on-eof s))
      ((read-error)         (on-read-error s (cadr ev)))
      ((write-completed)    (on-write-completed s (cdr ev)))
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
  ;; The delivery is remembered, sharing the event's `(bv start end)`, for
  ;; a pause to keep its rest.  No other state reads, so after a close-marked
  ;; message nothing more is fed (decision 0004 item 4).
  (define (on-bytes-arrived s ev)
    (case (conn-phase s)
      ((idle head body)
       (conn-delivery-set! s (cdr ev))
       (values s (list (cons 'feed-parser (cdr ev)))))
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

  ;; responding, write-completed: the write and its bytes are no longer
  ;; outstanding.  Keep waiting while writes are; on the last one, close if
  ;; the response closes the connection, otherwise resume parsing what was
  ;; retained and read again.  After a close-marked message the retained
  ;; input is dropped, never fed (decision 0004 item 4).
  ;; closing, write-completed: a write the close cut short, after a read
  ;; error in responding, is settled the same way, and nothing more is asked.
  ;; In the other states no write is outstanding, and nothing changes.
  (define (on-write-completed s fields)
    (case (conn-phase s)
      ((responding)
       (complete-write! s fields)
       (let ((left (conn-outstanding s)))
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
      ((closing)
       (complete-write! s fields)
       (values s '()))
      (else (values s '()))))

  ;; complete-write! : ConnState (Listof Any) -> Void
  ;; `(nbytes)`, a write-completed's fields: one write and its bytes are no
  ;; longer outstanding.  A completion with no write outstanding, with no
  ;; count or one that is not a count, for more bytes than are outstanding,
  ;; or for fewer than the last write left, is the shell's bug: an assertion
  ;; violation.
  (define (complete-write! s fields)
    (let ((nbytes (and (pair? fields) (car fields)))
          (writes (conn-outstanding s))
          (bytes (conn-outstanding-bytes s)))
      (unless (and (fixnum? nbytes) (fx>? writes 0) (fx<=? 0 nbytes bytes)
                   (or (fx>? writes 1) (fx=? nbytes bytes)))
        (assertion-violation 'conn-step "a completion the core did not ask for" fields bytes))
      (conn-outstanding-set! s (fx- writes 1))
      (conn-outstanding-bytes-set! s (fx- bytes nbytes))))

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
           (respond-and-close s 'header-timeout '())
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
  ;;   ConnState Nat Nat Nat Nat Nat Nat -> (values ConnState (Listof Action))
  ;;   method http-major http-minor flags content-length upgrade
  ;; on-headers-complete, entered with the six parser fields the adapter reads
  ;; inside the callback (0002 item 4): llhttp's method number, the version,
  ;; llhttp's flag bits, the content-length, and `upgrade`, 1 when the message
  ;; upgrades (chez-httparse v0.4.1 documents it as llhttp's
  ;; `llhttp_get_upgrade`, #47).  Read there, content-length is the declared
  ;; length, since it counts down as the body arrives, and the parser's reset
  ;; after each message zeroes it and the flags; `upgrade` is not reset, and is
  ;; this message's only from on-headers-complete on.  Nothing downstream
  ;; re-reads the parser.  The content-length is the body's, M6's.
  ;; The Host lines are judged here first (RFC 9112 §3.2; see (http-server
  ;; host)): a request whose Host is missing on HTTP/1.1 (when the limits
  ;; require one), doubled or invalid is refused as 'invalid-host, answered
  ;; 400.  Then the framing: a request below HTTP/1.1 with Transfer-Encoding
  ;; is refused as 'faulty-framing, answered 400 (see (http-server
  ;; transfer-coding)).  Then the target, where the method is known (M2.3; see
  ;; (http-server target)).  One that is not the form its method calls for,
  ;; or whose bytes uriparse refuses, is refused, and the state stays in head
  ;; until the parser's error arrives:
  ;;   - as 'target-redirect, answered 301 with a Location, when it is the
  ;;     narrow case decision 0009 redirects: bracket params and pipes in a
  ;;     GET or HEAD, encoded to a target within max-target-bytes;
  ;;   - as 'invalid-target, answered 400, otherwise.
  ;; Then the transfer codings (see (http-server transfer-coding)): when the
  ;; parser frames the body by a final chunked, another coding beside it is
  ;; refused as 'unsupported-transfer-coding, answered 501.
  ;; A request accepted on all four moves head -> body: the request is built
  ;; from the head, and the header deadline gives way to the body's.  The
  ;; connection is marked to close after the response unless the message
  ;; keeps it alive (decision 0006 item 1), or, when it does, if the parser
  ;; says it upgrades (M2.5).
  (define (conn-headers-complete-step s method http-major http-minor flags content-length upgrade)
    (case (conn-phase s)
      ((head)
       (let* ((h (conn-head s))
              (name (method-name method))
              (target (or (head-target h) empty-span)))
         (cond
          ((host-fault (head-fields h) http-major http-minor
                       (limits-require-host? (conn-limits s)))
           (refuse s 'invalid-host))
          ((faulty-framing? http-major http-minor flags)
           (refuse s 'faulty-framing))
          ((target-fault (conn-judge s) name target)
           (cond ((redirect-location s name target)
                  => (lambda (location)
                       (head-location-set! h location)
                       (refuse s 'target-redirect)))
                 (else (refuse s 'invalid-target))))
          ((unsupported-transfer-coding? (head-fields h) flags)
           (refuse s 'unsupported-transfer-coding))
          (else
           (conn-request-set! s (make-request name target http-major http-minor
                                              (reverse (head-fields h)) #f))
           (cond ((not (should-keep-alive? http-major http-minor 'request 0 flags))
                  (conn-close-after-set! s 'not-keep-alive))
                 ((eqv? upgrade 1)
                  (conn-close-after-set! s 'upgrade)))
           (conn-phase-set! s 'body)
           (conn-deadline-set! s 'body)
           (values s '((reply-parser continue) (disarm-deadline) (arm-deadline body)))))))
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

  ;; head/body: a hand-off, on either of the parser's channels
  ;; (`result-hands-off-stream?`), is the door (M2.5).  The HTTP/2 preface, on
  ;; the error channel, is answered 505, then close (decision 0006 item 2).
  ;; A pause for an upgrade stops reading and hands the stream off (0006
  ;; item 3): the door M8 opens for a handler that takes upgrades, which the
  ;; core's own flow never reaches, since it pauses at every message's end
  ;; and closes after an upgrade.  Any other error is answered with a status,
  ;; then close: one the core asked for with `fail` gets its reason's status
  ;; (design §6.3), and any other the status (http-server decisions) gives
  ;; its code.
  ;; handling: the core's own answer to on-message-complete paused the
  ;; parser, a pause with no reason, so the rest of the last delivery, from
  ;; `next`, is kept as the pending input the resume feeds (decision 0004
  ;; item 1).  Any other result there is not answered, llhttp's "Data after
  ;; `Connection: close`" included (0004 item 4).
  (define (on-parser-result s ev)
    (let ((status (list-ref ev 1))
          (next   (list-ref ev 3))
          (pause  (list-ref ev 5)))
      (case (conn-phase s)
        ((handling)
         (when (and (eq? status 'paused) (not pause) (conn-delivery s))
           (conn-pending-set! s (rest-of (conn-delivery s) next)))
         (values s '()))
        ((head body)
         (let ((err (list-ref ev 4)))
           (cond
            ((result-hands-off-stream? status err pause)
             (if (eq? status 'error)
                 (respond-and-close s 'http2-preface '())
                 (begin
                   (conn-phase-set! s 'handed-off)
                   (conn-deadline-set! s #f)
                   (values s (list '(read-stop) (list 'hand-off (conn-request s)))))))
            ((not (eq? status 'error)) (values s '()))
            ((head-refusal (conn-head s))
             => (lambda (reason)
                  (respond-and-close s reason (refusal-headers (conn-head s)))))
            (else
             (respond s (parser-error-status err) 'parser-error '())))))
        (else (values s '())))))

  ;; rest-of : (List Bytevector Nat Nat) Nat -> Pending
  ;; The delivery's bytes from `next` on, or #f when the parser took them all.
  (define (rest-of delivery next)
    (let ((end (caddr delivery)))
      (and (fx<? next end) (list (car delivery) next end))))

  ;; handling, handler-responded -> responding: write it, arm the write
  ;; deadline.  A response with a fault is answered 500 instead, then close,
  ;; the log naming the fault (decision 0010 item 2).  A handler's
  ;; `Connection: close` closes the connection after its response (item 3),
  ;; unless it closes already for a reason of its own.
  (define (on-handler-responded s response)
    (case (conn-phase s)
      ((handling)
       (cond
        ((response-fault response)
         => (lambda (fault)
              (let-values (((s actions) (respond-and-close s 'invalid-response '())))
                (values s (cons (list 'log 'invalid-response fault) actions)))))
        (else
         (when (and (not (conn-close-after s)) (response-closes? response))
           (conn-close-after-set! s 'handler-close))
         (conn-phase-set! s 'responding)
         (conn-deadline-set! s 'write)
         (values s (list (write-action s response serialize-checked-response)
                         '(arm-deadline write))))))
      (else (values s '()))))

  ;; write-action : ConnState Response Serializer -> Action
  ;;   Serializer = serialize-response, or serialize-checked-response for a
  ;;                handler's response the core has found no fault in, so
  ;;                that its fields are not read for faults twice
  ;; `(write segments nbytes)`: the response as the segments of one write,
  ;; framed for the request being answered, and saying `close` when the
  ;; connection closes after it (http-server decisions).  A close-delimited
  ;; body ends only with the connection (RFC 9112 §6.3 rule 8), so it closes
  ;; the connection after the response when nothing else does; the decision
  ;; gives that mode only to a body of unknown length, which a response
  ;; first has in M6.  A response the core originates before a request is
  ;; built answers none: it has no body and always closes, so the version,
  ;; which only a body of unknown length or a connection that stays would
  ;; read, is taken as 1.1.  The write is outstanding, with its bytes, until
  ;; the shell reports it completed (M3.3).
  (define (write-action s r serialize)
    (let* ((req (conn-request s))
           (major (if req (request-http-major req) 1))
           (minor (if req (request-http-minor req) 1))
           (body (response-body r))
           (mode (response-framing (and req (request-method req)) major minor
                                   (response-status r) (and body (bytevector-length body)))))
      (when (and (eq? mode 'close-delimited) (not (conn-close-after s)))
        (conn-close-after-set! s 'close-delimited))
      (let-values (((segments bytes)
                    (serialize r mode (response-connection (and (conn-close-after s) #t)
                                                           major minor))))
        (conn-outstanding-set! s (+ (conn-outstanding s) 1))
        (conn-outstanding-bytes-set! s (+ (conn-outstanding-bytes s) bytes))
        (list 'write segments bytes))))

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
  ;; is the reason's, from (http-server decisions).
  (define (respond-and-close s reason headers)
    (respond s (reason-status reason) reason headers))

  ;; respond :
  ;;   ConnState Nat Symbol Headers -> (values ConnState (Listof Action))
  ;; Enter `responding` with `status`, closing afterwards for `reason`, and
  ;; arm the write deadline, as every entry into `responding` does (design
  ;; §4.3; the deadline armed before, a header or body one, gives way to it).
  ;; The response has no body and no headers but `headers`, a redirect's
  ;; Location; the serializer writes its phrase, and its framing and
  ;; `Connection: close` (decision 0010 item 6).  The core's own response is
  ;; read for faults as any caller's is.
  (define (respond s status reason headers)
    (conn-phase-set! s 'responding)
    (conn-deadline-set! s 'write)
    (conn-close-after-set! s reason)
    (values s (list (write-action s (make-response status #f headers #f) serialize-response)
                    '(arm-deadline write))))

  ;; refusal-headers : Head -> Headers
  ;; The headers a refused message's response carries: a redirect's
  ;; Location, or none.
  (define (refusal-headers h)
    (let ((location (head-location h)))
      (if location (list (cons location-name location)) '())))

  ;; The Location header's name, shared by every redirect.
  (define location-name (string->utf8 "Location")))
