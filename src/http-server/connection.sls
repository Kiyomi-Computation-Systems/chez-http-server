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
;;; A CONNECTION CLOSES IN STAGES (M3.5; RFC 9112 §9.6; decided on the
;;; owner's word, 2026-09-26, decision 0011).  Once the last write of a
;;; response that closes the connection completes, the core asks for
;;; `shutdown`, the half-close, so the client reads the response and then the
;;; stream's end, and it lingers: it reads again, drops what arrives, and
;;; closes when the client closes, when a read fails, or when the linger
;;; deadline passes.  Closing at once while the client still sends makes the
;;; server's TCP stack reset the connection, which fails a client's send
;;; before it reads the response and throws away what of the response the
;;; kernel has not yet sent.  Every close after a response lingers, the
;;; core's own statuses and a handler's close alike; a close with no response
;;; (the client's end, a read error, the idle deadline) is at once.  The
;;; deadline is armed once, so a client that keeps sending cannot hold the
;;; connection past it, and the close names the reason the connection closes
;;; after its response.  A state that reads stops reading when it refuses a
;;; request, as design §4.3 says `responding` does, so the client's end
;;; waits in the kernel for the linger, and nothing has to remember it.
;;;
;;; A BODY IS READ BY A READER (M6.1; decision 0013).  A request whose
;;; framing announces a body, chunked or a Content-Length above 0, is handed
;;; to the handler once the feed that completed its head has returned, before
;;; any of its body: the `call-handler` comes with that feed's
;;; `parser-result`.  The handler answers a response or a reader, (http-server
;;; body)'s, as `handler-responded`.  A reader is handed each piece the parser
;;; meets as `deliver-body`, the read's own span, in order, and
;;; `deliver-body-end` once the message has ended; the reader's response
;;; comes back as `handler-responded` too.  A whole reader is handed its body
;;; instead as one piece at the end, which the core copies from the pieces as
;;; they arrive, into one bytevector grown to the declared length, or joined
;;; when chunked.  A response given instead of a reader is sent at once, and the
;;; connection closes after it, as 'unread-body: the body is not read.  A body
;;; past a cap is refused as 'body-too-large, answered 413: the limits'
;;; max-body-bytes caps every body, and a reader may carry a cap of its own.
;;; A declared length past the limits' cap is refused before the handler is
;;; asked, past a reader's once it answers, and a counted one at the piece
;;; that passes it, a streaming reader handed the piece up to the cap.  A
;;; request with no body is handed over at its end, as before, and a reader
;;; answered for one is handed its end at once.  The parser is never paused
;;; inside a body (decision 0013 item 3).  The shells find the reader a piece
;;; goes to with `conn-body-reader`.
;;;
;;; WHAT HAPPENS NEVER DEPENDS ON HOW THE BYTES WERE SPLIT INTO READS (design
;;; §8.1's second property).  The feed that completes a head can go on into
;;; its body before the handler is asked.  What it meets there waits for the
;;; handler's answer, as it would have come after it had the body arrived in
;;; a later read: the pieces are kept, and handed to a reader once it
;;; answers; and an error the parser meets, or a cap the body passes, is kept
;;; too, and answered after those pieces, or not at all if the handler
;;; answers with a response, since the body is then not read.
;;;
;;; DEADLINES ARE KINDS, NOT INSTANTS.  `(arm-deadline kind)` names which of
;;; the connection's one deadline — idle, header, body, write (design §4.3) or
;;; linger (decision 0011) — to arm, and carries no time: no event but `tick`
;;; carries `now`, so the core cannot turn a duration into an instant.  The
;;; shell's timing wheel does, from the limits (decision 0005, M5), and ticks
;;; a connection only once the deadline it armed has passed, and only as it
;;; lets that deadline go.  The state records the armed kind, so a tick is
;;; acted on only while the core still has a deadline of that kind armed, and
;;; every kind has its tick row (M5.2).  The record and the actions agree:
;;; wherever the core lets a deadline go of its own accord, it emits
;;; `(disarm-deadline)`, so every way it lets a connection go, a close or the
;;; hand-off, takes the connection out of the wheel.  A tick clears the record
;;; with no disarm, since the wheel has already let the deadline go.
(library (http-server connection)
  (export conn-states conn-events conn-actions conn-deadline-kinds
          conn-parser-callbacks conn-span-callbacks
          make-conn-state conn-state?
          conn-phase conn-deadline conn-close-after conn-outstanding
          conn-outstanding-bytes conn-pending conn-request conn-limits conn-body-reader
          conn-body-buffered
          conn-step conn-parser-step conn-headers-complete-step)
  (import (rnrs)
          (http-server response) (http-server request) (http-server span)
          (http-server limits) (http-server decisions) (http-server target)
          (only (http-server body) body-reader? body-reader-max-bytes body-reader-whole?)
          (only (http-server host) host-fault)
          (only (http-server transfer-coding) unsupported-transfer-coding? faulty-framing?)
          (only (http-server serializer)
                serialize-response serialize-checked-response response-fault response-closes?)
          (only (httparse decisions) should-keep-alive? F-CHUNKED)
          (only (httparse methods) httparse-method-numbers))

  ;; conn-states : (Listof Symbol)
  ;; The ten connection states: design §4.3's nine, and `lingering`, where a
  ;; connection that closes after its response waits for the client to close
  ;; (decision 0011).  Only `idle`, `head`, `body` and `lingering` read from
  ;; the socket; `closed` is terminal.
  (define conn-states
    '(idle head body handling responding lingering draining handed-off closing closed))

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

  ;; conn-deadline-kinds : (Listof Symbol)
  ;; The five kinds of deadline the core arms, `(arm-deadline kind)`: design
  ;; §4.3's idle, header, body and write, and decision 0011's linger.  How
  ;; long each lasts is the limits' (limits-deadline-ms); the shell's wheel
  ;; turns it into an instant (M5).
  (define conn-deadline-kinds '(idle header body write linger))

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
  ;;   Deadline   = (U #f one of conn-deadline-kinds) — the kind armed, if any
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
  ;; request body being read (M6.1), the connection's target judge (M2.3)
  ;; and the last delivery it fed the parser, `(bv start end)` or #f (M2.4);
  ;; none of them is exported.  A state made in `handling` has a message that
  ;; has ended, and is waiting for its handler's answer, as a request with no
  ;; body is.
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
            (immutable body      conn-body)
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
         (let ((body (make-body-state)))
           (when (eq? phase 'handling)
             (body-answer-set! body 'asked)
             (body-complete?-set! body #t))
           (new phase deadline close-after outstanding outstanding-bytes pending request limits
                (make-head) body (make-target-judge) #f))))))

  ;; conn-body-reader : ConnState -> (U #f BodyReader)
  ;; The reader the handler answered with, while the core hands it the body:
  ;; the one each `deliver-body` and `deliver-body-end` goes to, until its
  ;; response comes back, and #f otherwise (decision 0013).
  (define (conn-body-reader s) (body-reader-of (conn-body s)))

  ;; conn-body-buffered : ConnState -> Nat
  ;; The bytes the core holds for a whole reader's body: its buffer's length,
  ;; or its copies' lengths when the body is chunked; 0 with none.
  (define (conn-body-buffered s)
    (let ((buffer (body-buffer (conn-body s))))
      (cond ((bytevector? buffer) (bytevector-length buffer))
            ((pair? buffer) (fold-left (lambda (n c) (+ n (bytevector-length c))) 0 buffer))
            (else 0))))

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

  ;; The request body being read (M6.1; decision 0013): how its framing
  ;; announced it, the bytes of it met, the handler's answer, and what is kept
  ;; for that answer.  One per connection, rolled with the head.
  ;;   framed?   whether the framing announced a body: chunked, or a
  ;;             Content-Length above 0
  ;;   declared  the Content-Length, or #f when chunked
  ;;   count     the body bytes the parser has met
  ;;   answer    #f, the handler not yet asked; call, to be asked once the
  ;;             feed has returned; asked, its answer to come; stream or
  ;;             whole, a reader reading; ending, the reader's response to
  ;;             come
  ;;   held      the pieces met before the answer, as `deliver-body`
  ;;             actions, newest first
  ;;   error     #f, or what the feed that completed the head met in the
  ;;             body before the handler was asked, kept for its answer:
  ;;             (refused reason), or (parser code), the parser's error
  ;;   complete? whether the message has ended
  ;;   reader    the reader answered, until its response comes
  ;;   buffer    a whole reader's body so far: a bytevector of the declared
  ;;             length, or the copies of a chunked body's pieces, newest first
  ;;   filled    the bytes of the body buffered
  (define-record-type (body-state make-body-state body-state?)
    (fields (mutable framed?   body-framed?   body-framed?-set!)
            (mutable declared  body-declared  body-declared-set!)
            (mutable count     body-count     body-count-set!)
            (mutable answer    body-answer    body-answer-set!)
            (mutable held      body-held      body-held-set!)
            (mutable error     body-error     body-error-set!)
            (mutable complete? body-complete? body-complete?-set!)
            (mutable reader    body-reader-of body-reader-set!)
            (mutable buffer    body-buffer    body-buffer-set!)
            (mutable filled    body-filled    body-filled-set!))
    (protocol (lambda (new) (lambda () (new #f #f 0 #f '() #f #f #f #f 0)))))

  ;; body-roll! : Body -> Void — nothing read, and nothing kept.
  (define (body-roll! bd)
    (body-framed?-set! bd #f)
    (body-declared-set! bd #f)
    (body-count-set! bd 0)
    (body-answer-set! bd #f)
    (body-held-set! bd '())
    (body-error-set! bd #f)
    (body-complete?-set! bd #f)
    (body-reader-set! bd #f)
    (body-buffer-set! bd #f)
    (body-filled-set! bd 0))

  ;; over? : (U Nat #f) (U Nat #f) -> Boolean — whether `n` is past `cap`.
  (define (over? cap n) (and cap n (> n cap)))

  ;; least-cap : (U Nat #f) (U Nat #f) -> (U Nat #f) — the lower of two caps,
  ;; either of which may be none.
  (define (least-cap a b) (cond ((not a) b) ((not b) a) (else (min a b))))

  ;; The bytes of no body: what a declared length's buffer starts from, so
  ;; nothing is allocated for it before its bytes arrive.
  (define no-bytes (make-bytevector 0))

  ;; buffer-start! : BodyState -> Void
  ;; A whole reader's buffer, empty: a bytevector that grows as a declared
  ;; length's body arrives, or a list of copies when the body is chunked.
  ;; Nothing is allocated before the body's bytes arrive: a declared length
  ;; is the client's word, and a buffer of that length made at once would
  ;; let a head alone take up to the reader's cap (M6.1's review).
  (define (buffer-start! bd)
    (body-buffer-set! bd (if (body-declared bd) no-bytes '()))
    (body-filled-set! bd 0))

  ;; buffer-add! : BodyState Bytevector Nat Nat -> Void
  ;; One more piece, copied.  A declared length's buffer grows to hold it: to
  ;; the declared length once that is at most twice what has arrived, and
  ;; doubling before, so it is never more than twice what has arrived, the
  ;; buffers it grows through come to less than twice the body, and it ends
  ;; exactly full.  A chunked body's piece is copied on its own, and the
  ;; copies are joined once, at the end: for a length not known, that
  ;; allocates less than a doubling buffer trimmed at the end, and holds no
  ;; more at its peak (the ledger, M6.1's review).
  (define (buffer-add! bd bv from to)
    (let ((buffer (body-buffer bd)) (n (fx- to from)) (filled (body-filled bd)))
      (if (bytevector? buffer)
          (let* ((need (fx+ filled n))
                 (room (cond ((fx<=? need (bytevector-length buffer)) buffer)
                             ((<= (body-declared bd) (* 2 need))
                              (grown buffer filled (body-declared bd)))
                             (else
                              (grown buffer filled (max (* 2 (bytevector-length buffer)) need))))))
            (bytevector-copy! bv from room filled n)
            (body-buffer-set! bd room))
          (let ((copy (make-bytevector n)))
            (bytevector-copy! bv from copy 0 n)
            (body-buffer-set! bd (cons copy buffer))))
      (body-filled-set! bd (fx+ filled n))))

  ;; grown : Bytevector Nat Nat -> Bytevector
  ;; A bytevector of `size` bytes holding `buffer`'s first `filled`.
  (define (grown buffer filled size)
    (let ((out (make-bytevector size)))
      (bytevector-copy! buffer 0 out 0 filled)
      out))

  ;; body-release! : BodyState -> Void
  ;; Let go of what the body keeps for the handler's answer, a whole reader's
  ;; buffer and the pieces kept, and keep the reader: a status the core
  ;; writes answers the request, and the pieces already asked for still go
  ;; to the reader.
  (define (body-release! bd)
    (body-buffer-set! bd #f)
    (body-filled-set! bd 0)
    (body-held-set! bd '()))

  ;; buffer-take! : BodyState -> Bytevector
  ;; The whole body, which the buffer lets go of: the declared length's
  ;; bytevector, full, or a chunked body's copies joined into one.
  (define (buffer-take! bd)
    (let ((buffer (body-buffer bd)) (n (body-filled bd)))
      (body-buffer-set! bd #f)
      (if (bytevector? buffer)
          buffer
          (let ((out (make-bytevector n)))
            (let loop ((copies buffer) (end n))
              (if (null? copies)
                  out
                  (let* ((copy (car copies)) (start (fx- end (bytevector-length copy))))
                    (bytevector-copy! copy 0 out start (bytevector-length copy))
                    (loop (cdr copies) start))))))))

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
      ;; No row reads these: body streaming (M6) and the drain lifecycle (M8)
      ;; give them transitions.  The half-close's completion changes
      ;; nothing: the client's close, not it, ends a linger (M3.5).
      ((shutdown-completed handler-body-chunk handler-body-end body-credit)
       (values s '()))
      (else (assertion-violation 'conn-step "not a connection event" ev))))

  ;; The transitions, one procedure per event kind.  Each names the design
  ;; §4.4 row it implements.

  ;; idle, bytes-arrived -> idle: feed the delivery to the parser.  head and
  ;; body feed it too, for a message that arrives in more than one delivery.
  ;; The delivery is remembered, sharing the event's `(bv start end)`, for
  ;; a pause to keep its rest.  In every other state nothing is fed, so after
  ;; a close-marked message nothing more is (decision 0004 item 4); lingering
  ;; reads, and drops what arrives (M3.5).
  (define (on-bytes-arrived s ev)
    (case (conn-phase s)
      ((idle head body)
       (conn-delivery-set! s (cdr ev))
       (values s (list (cons 'feed-parser (cdr ev)))))
      (else (values s '()))))

  ;; idle, head or body, eof -> closing: close, with no response.
  ;; lingering, eof -> closing: the client closed, so close, for the reason
  ;; the connection closes after its response (M3.5).
  (define (on-eof s)
    (case (conn-phase s)
      ((idle head body) (close s 'eof '()))
      ((lingering) (close s (conn-close-after s) '()))
      (else (values s '()))))

  ;; any live state, read-error -> closing: log it, close, no response.
  (define (on-read-error s errno)
    (case (conn-phase s)
      ((idle head body handling responding lingering draining)
       (close s 'read-error (list (list 'log 'read-error errno))))
      (else (values s '()))))

  ;; responding, write-completed: the write and its bytes are no longer
  ;; outstanding.  Keep waiting while writes are.  On the last one, a
  ;; response that closes the connection is followed by the staged close
  ;; (M3.5): lingering, the write side shut, reading again to drop what
  ;; arrives, the linger deadline armed, and nothing of the input kept.
  ;; Otherwise resume parsing what was retained and read again.  After a
  ;; close-marked message the retained input is dropped, never fed (decision
  ;; 0004 item 4).
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
           (forget-input! s)
           (conn-phase-set! s 'lingering)
           (conn-deadline-set! s 'linger)
           (values s '((shutdown) (read-start) (arm-deadline linger))))
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

  ;; forget-input! : ConnState -> Void
  ;; Drop all the connection holds of the input it has read: the pause's
  ;; pending input, the last delivery, the request, and the head and the
  ;; body, whose spans point into the deliveries.  A lingering connection reads only to drop
  ;; what arrives, for up to its linger deadline (decision 0011), so it keeps
  ;; none of them (tests/test-connection-retention.sps).
  (define (forget-input! s)
    (conn-pending-set! s #f)
    (conn-delivery-set! s #f)
    (conn-request-set! s #f)
    (head-roll! (conn-head s))
    (body-roll! (conn-body s)))

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

  ;; A tick means the wheel found this connection's armed deadline passed
  ;; (0005), and has let it go: an advance returns its keys already disarmed.
  ;; So the kind the state records is read, then cleared, and a row that
  ;; keeps the connection arms what it needs.  Every kind the core arms has
  ;; its row (M5.2):
  ;;   idle past the idle deadline -> closing, with no response; and so does
  ;;     draining, from idle, past the idle deadline it carried there;
  ;;   head past the header deadline -> responding 408;
  ;;   body past the body deadline -> responding 408, the request in flight's;
  ;;   responding past the write deadline -> closing, with no response: the
  ;;     client is not reading, so nothing more can be written to it.  The
  ;;     close is logged, with the bytes still outstanding, and names the
  ;;     write deadline, whatever the connection would have closed for after
  ;;     its response.  The write it cuts short is settled in `closing`
  ;;     (M3.3);
  ;;   lingering past the linger deadline -> closing, for the reason it closes
  ;;     after its response (M3.5).
  ;; A tick with no deadline of that kind recorded asks for nothing.
  (define (on-tick s)
    (let ((kind (conn-deadline s)))
      (conn-deadline-set! s #f)
      (case (conn-phase s)
        ((idle draining)
         (if (eq? kind 'idle)
             (close s 'idle-timeout '())
             (values s '())))
        ((head)
         (if (eq? kind 'header)
             (respond-and-close s 'header-timeout '())
             (values s '())))
        ((body)
         (if (eq? kind 'body)
             (respond-and-close s 'body-timeout '())
             (values s '())))
        ((responding)
         (if (eq? kind 'write)
             (close s 'write-timeout
                    (list (list 'log 'write-timeout (conn-outstanding-bytes s))))
             (values s '())))
        ((lingering)
         (if (eq? kind 'linger)
             (close s (conn-close-after s) '())
             (values s '())))
        (else (values s '())))))

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
          (body-roll! (conn-body s))
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
         ((body) (body-piece s bv from to))
         (else (continue s))))
      ((on-message-complete)
       (case (conn-phase s)
         ((body)
          (let ((bd (conn-body s)))
            (conn-phase-set! s 'handling)
            (conn-deadline-set! s #f)
            (body-complete?-set! bd #t)
            (case (body-answer bd)
              ((#f)
               (body-answer-set! bd 'asked)
               (values s (list '(reply-parser pause) '(read-stop) '(disarm-deadline)
                               (list 'call-handler (conn-request s)))))
              ((stream)
               (body-answer-set! bd 'ending)
               (values s '((reply-parser pause) (read-stop) (disarm-deadline) (deliver-body-end))))
              ((whole)
               (let-values (((s handed) (hand-over-whole s)))
                 (values s (cons* '(reply-parser pause) '(read-stop) '(disarm-deadline) handed))))
              (else (values s '((reply-parser pause) (read-stop) (disarm-deadline)))))))
         (else (continue s))))
      (else (continue s))))

  ;; body-piece : ConnState Bytevector Nat Nat -> (values ConnState (Listof Action))
  ;; body, on-body-data -> body: count the piece, and refuse the message as
  ;; 'body-too-large once the body passes the limits' max-body-bytes or the
  ;; reader's own cap.  The piece up to the cap is handed to a streaming
  ;; reader first, or kept for the handler's answer, so a reader is handed
  ;; exactly the cap's bytes, however they were split into reads.  Otherwise
  ;; re-arm the body deadline, and hand the piece on by the answer: to a
  ;; streaming reader as `deliver-body`; into a whole reader's buffer; kept
  ;; for the answer while it has not come (decision 0013).  With no answer
  ;; to come, it is dropped.
  (define (body-piece s bv from to)
    (let* ((bd (conn-body s))
           (count (+ (body-count bd) (fx- to from)))
           (reader (body-reader-of bd))
           (cap (least-cap (limits-max-body-bytes (conn-limits s))
                           (and reader (body-reader-max-bytes reader)))))
      (body-count-set! bd count)
      (cond
       ((over? cap count)
        (head-refusal-set! (conn-head s) 'body-too-large)
        (let ((cut (- to (- count cap))))
          (if (and (fx>? cut from) (memq (body-answer bd) '(stream call asked)))
              (hand-on s bv from cut refused-too-large)
              (values s refused-too-large))))
       (else
        (conn-deadline-set! s 'body)
        (hand-on s bv from to continued)))))

  ;; body-piece's two answers, without the piece: continue and re-arm the
  ;; body deadline; or refuse, past a cap.
  (define continued '((reply-parser continue) (arm-deadline body)))
  (define refused-too-large '((reply-parser (fail body-too-large))))

  ;; hand-on : ConnState Bytevector Nat Nat (Listof Action)
  ;;           -> (values ConnState (Listof Action))
  ;; `answer`, the parser's reply and what follows it, once the piece
  ;; bv[from, to) is handed on by the handler's answer: to a streaming
  ;; reader, as `deliver-body` after the reply; into a whole reader's buffer;
  ;; kept for the answer while it has not come.  With no reader, the piece is
  ;; dropped.
  (define (hand-on s bv from to answer)
    (let ((bd (conn-body s)))
      (case (body-answer bd)
        ((stream)
         (values s (cons (car answer) (cons (list 'deliver-body bv from to) (cdr answer)))))
        ((whole)
         (buffer-add! bd bv from to)
         (values s answer))
        ((call asked)
         (body-held-set! bd (cons (list 'deliver-body bv from to) (body-held bd)))
         (values s answer))
        (else (values s answer)))))

  ;; hand-over-whole : ConnState -> (values ConnState (Listof Action))
  ;; A whole reader's body, once the message has ended: its buffer handed
  ;; over as the reader's only piece, then its end, and the reader's response
  ;; to come.  An empty body is no piece, only the end.
  (define (hand-over-whole s)
    (let ((bd (conn-body s)))
      (body-answer-set! bd 'ending)
      (if (fxzero? (body-filled bd))
          (begin (body-buffer-set! bd #f) (values s '((deliver-body-end))))
          (let* ((n (body-filled bd)) (whole (buffer-take! bd)))
            (values s (list (list 'deliver-body whole 0 n) '(deliver-body-end)))))))

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
  ;; re-reads the parser.  The flags and the content-length say whether a
  ;; body follows (M6.1): one chunked, or with a Content-Length above 0.
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
  ;; says it upgrades (M2.5).  A body it announces is noted, for the handler
  ;; to be asked once the feed has returned, and a declared length past the
  ;; limits' max-body-bytes is refused as 'body-too-large, answered 413,
  ;; before any of the body is met (decision 0013 items 1 and 5).
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
           (let* ((chunked? (not (fxzero? (fxand flags F-CHUNKED))))
                  (declared (and (not chunked?) content-length))
                  (framed? (or chunked? (> content-length 0)))
                  (bd (conn-body s)))
             (body-roll! bd)
             (body-framed?-set! bd framed?)
             (body-declared-set! bd declared)
             (cond
              ((and framed? (over? (limits-max-body-bytes (conn-limits s)) declared))
               (refuse s 'body-too-large))
              (else
               (when framed? (body-answer-set! bd 'call))
               (conn-phase-set! s 'body)
               (conn-deadline-set! s 'body)
               (values s '((reply-parser continue) (disarm-deadline) (arm-deadline body))))))))))
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

  ;; head/body: a feed that completed a head announcing a body, and was
  ;; not refused before the head completed, has returned, so the handler is
  ;; asked now (decision 0013 item 1): `ask-handler`.  If that feed went on
  ;; into the body and met an error there, or passed a cap, the error waits
  ;; for the handler's answer, in handling, reading stopped: it is answered
  ;; after the pieces met before it if the handler answers with a reader,
  ;; and not at all if it answers with a response, as it would had the body
  ;; come in a later read.
  ;; head/body: a hand-off, on either of the parser's channels
  ;; (`result-hands-off-stream?`), is the door (M2.5).  The HTTP/2 preface, on
  ;; the error channel, is answered 505, then close (decision 0006 item 2).
  ;; A pause for an upgrade stops reading, disarms the deadline (M5.2) and
  ;; hands the stream off (0006 item 3): the door M8 opens for a handler that
  ;; takes upgrades, which the core's own flow never reaches, since it pauses
  ;; at every message's end and closes after an upgrade.  Any other error is
  ;; answered with a status, then close: one the core asked for with `fail`
  ;; gets its reason's status (design §6.3), and any other the status
  ;; (http-server decisions) gives its code.
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
         (ask-handler s))
        ((head body)
         (let ((err (list-ref ev 4)))
           (cond
            ((result-hands-off-stream? status err pause)
             (if (eq? status 'error)
                 (respond-and-close s 'http2-preface '())
                 (begin
                   (conn-phase-set! s 'handed-off)
                   (conn-deadline-set! s #f)
                   (values s (list '(read-stop) '(disarm-deadline)
                                   (list 'hand-off (conn-request s)))))))
            ((not (eq? status 'error)) (ask-handler s))
            ((eq? (body-answer (conn-body s)) 'call)
             (body-error-set! (conn-body s)
                              (let ((reason (head-refusal (conn-head s))))
                                (if reason (list 'refused reason) (list 'parser err))))
             (conn-phase-set! s 'handling)
             (conn-deadline-set! s #f)
             (let-values (((s asked) (ask-handler s)))
               (values s (cons* '(read-stop) '(disarm-deadline) asked))))
            ((head-refusal (conn-head s))
             => (lambda (reason)
                  (respond-and-close s reason (refusal-headers (conn-head s)))))
            (else
             (respond s (parser-error-status err) 'parser-error '())))))
        (else (values s '())))))

  ;; ask-handler : ConnState -> (values ConnState (Listof Action))
  ;; `(call-handler request)`, once, for a request whose head announced a
  ;; body; nothing otherwise.
  (define (ask-handler s)
    (let ((bd (conn-body s)))
      (if (eq? (body-answer bd) 'call)
          (begin
            (body-answer-set! bd 'asked)
            (values s (list (list 'call-handler (conn-request s)))))
          (values s '()))))

  ;; answer-error : ConnState (List Symbol Any) -> (values ConnState (Listof Action))
  ;; The status for what the feed that completed the head met in the body:
  ;; a refusal's, or the parser's error's, then close.
  (define (answer-error s error)
    (if (eq? (car error) 'refused)
        (respond-and-close s (cadr error) '())
        (respond s (parser-error-status (cadr error)) 'parser-error '())))

  ;; rest-of : (List Bytevector Nat Nat) Nat -> Pending
  ;; The delivery's bytes from `next` on, or #f when the parser took them all.
  (define (rest-of delivery next)
    (let ((end (caddr delivery)))
      (and (fx<? next end) (list (car delivery) next end))))

;; body/handling, handler-responded: the handler's answer, or a reader's
  ;; response (decision 0013).
  ;;   - Asked, a reader: `accept-reader`.
  ;;   - Asked about a request whose head announced a body, a response: sent
  ;;     at once, and the connection closes after it, as 'unread-body, unless
  ;;     it closes already for a reason of its own (item 4); the body is not
  ;;     read, and an error kept for the answer is not answered.
  ;;   - Asked about a request with no body, or the reader's response: the
  ;;     response, `respond-with`.
  ;; An answer the core did not ask for changes nothing.
  (define (on-handler-responded s answer)
    (case (conn-phase s)
      ((body handling)
       (let ((bd (conn-body s)))
         (case (body-answer bd)
           ((asked)
            (cond ((body-reader? answer) (accept-reader s answer))
                  ((body-framed? bd)
                   (unless (conn-close-after s) (conn-close-after-set! s 'unread-body))
                   (respond-with s answer))
                  (else (respond-with s answer))))
           ((ending) (respond-with s answer))
           (else (values s '())))))
      (else (values s '()))))

  ;; accept-reader : ConnState BodyReader -> (values ConnState (Listof Action))
  ;; A reader, answered for the request being read.  A declared length, or a
  ;; body met so far, past the reader's cap is answered 413 at once, then
  ;; close.  Otherwise the reader reads: the pieces kept for it are handed
  ;; over now, as `deliver-body` to a streaming one and into its buffer for a
  ;; whole one; then an error kept for the answer is answered, or once the
  ;; message has ended, the reader is handed its end.
  (define (accept-reader s r)
    (let ((bd (conn-body s)) (cap (body-reader-max-bytes r)))
      (if (or (over? cap (body-declared bd)) (over? cap (body-count bd)))
          (respond-and-close s 'body-too-large '())
          (let ((held (reverse (body-held bd))) (error (body-error bd)))
            (body-held-set! bd '())
            (body-reader-set! bd r)
            (cond
             ((and error (body-reader-whole? r)) (answer-error s error))
             (error
              (let-values (((s answered) (answer-error s error)))
                (values s (append held answered))))
             ((body-reader-whole? r)
              (body-answer-set! bd 'whole)
              (buffer-start! bd)
              (for-each (lambda (a) (buffer-add! bd (cadr a) (caddr a) (cadddr a))) held)
              (if (body-complete? bd) (hand-over-whole s) (values s '())))
             ((body-complete? bd)
              (body-answer-set! bd 'ending)
              (values s (append held '((deliver-body-end)))))
             (else
              (body-answer-set! bd 'stream)
              (values s held)))))))

  ;; respond-with : ConnState Response -> (values ConnState (Listof Action))
  ;; -> responding: write the response, arm the write deadline, and let the
  ;; body go.  From body, reading stops with the write, since `responding`
  ;; does not read.  A response with a fault is answered 500 instead, then
  ;; close, the log naming the fault (decision 0010 item 2).  A handler's
  ;; `Connection: close` closes the connection after its response (item 3),
  ;; unless it closes already for a reason of its own.
  (define (respond-with s response)
    (cond
     ((response-fault response)
      => (lambda (fault)
           (let-values (((s actions) (respond-and-close s 'invalid-response '())))
             (values s (cons (list 'log 'invalid-response fault) actions)))))
     (else
      (when (and (not (conn-close-after s)) (response-closes? response))
        (conn-close-after-set! s 'handler-close))
      (let ((reading? (eq? (conn-phase s) 'body)))
        (conn-phase-set! s 'responding)
        (conn-deadline-set! s 'write)
        (body-roll! (conn-body s))
        (let ((w (write-action s response serialize-checked-response)))
          (values s (if reading?
                        (list w '(read-stop) '(arm-deadline write))
                        (list w '(arm-deadline write)))))))))

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

  ;; handling or body, handler-failed -> responding 500, then close: the
  ;; handler raised, or its reader did, whether the body was still being read
  ;; or had ended (decision 0013 item 7).  The reader is let go at once, so a
  ;; piece already asked for never reaches a reader that raised.  (The bare
  ;; close for a failure after the head is on the wire needs a streamed body:
  ;; M6.3.)
  (define (on-handler-failed s)
    (case (conn-phase s)
      ((handling body)
       (body-roll! (conn-body s))
       (respond-and-close s 'handler-failed '()))
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
  ;; Enter `closing`, disarming the deadline, armed or not, before the close
  ;; (M5.2): the shell's wheel holds a connection until its deadline is
  ;; disarmed or passes.  `before` precedes both.  A body being read goes,
  ;; its reader with it.
  (define (close s reason before)
    (conn-phase-set! s 'closing)
    (conn-deadline-set! s #f)
    (body-roll! (conn-body s))
    (values s (append before (list '(disarm-deadline) (list 'close reason)))))

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
  ;; From head or body, which read, reading stops with the write, since
  ;; `responding` does not read; from handling it stopped at the pause (M3.5).
  ;; What the body keeps for the answer is let go, a whole reader's buffer
  ;; among it, but not the reader: the pieces already asked for, a prefix up
  ;; to a cap or those met before an error, still go to it, and it is let go
  ;; once the connection lingers or closes.  Nothing asks for its end.
  ;; The response has no body and no headers but `headers`, a redirect's
  ;; Location; the serializer writes its phrase, and its framing and
  ;; `Connection: close` (decision 0010 item 6).  The core's own response is
  ;; read for faults as any caller's is.
  (define (respond s status reason headers)
    (let ((reading? (memq (conn-phase s) '(head body))))
      (conn-phase-set! s 'responding)
      (conn-deadline-set! s 'write)
      (conn-close-after-set! s reason)
      (body-release! (conn-body s))
      (let ((w (write-action s (make-response status #f headers #f) serialize-response)))
        (values s (if reading?
                      (list w '(read-stop) '(arm-deadline write))
                      (list w '(arm-deadline write)))))))

  ;; refusal-headers : Head -> Headers
  ;; The headers a refused message's response carries: a redirect's
  ;; Location, or none.
  (define (refusal-headers h)
    (let ((location (head-location h)))
      (if location (list (cons location-name location)) '())))

  ;; The Location header's name, shared by every redirect.
  (define location-name (string->utf8 "Location")))
