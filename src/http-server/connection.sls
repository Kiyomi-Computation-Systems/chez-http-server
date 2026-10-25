#!r6rs
;;; (http-server connection) — the pure connection core.
;;;
;;; `conn-step` is the connection: every libuv callback and every parser
;;; callback becomes an EVENT, and the step answers with ACTIONS for the shell
;;; to perform.
;;;
;;; PURE BY CONTRACT: a step allocates only Scheme data, calls no chez-libuv
;;; or byte-machine procedure, reads no clock, and never raises on a
;;; well-formed event.  An event outside the vocabulary, or one the state
;;; says cannot have happened, such as a completion for bytes the core did
;;; not write, is a caller bug and an assertion violation — never a runtime
;;; path.
;;;
;;; THE STATE IS LINEAR.  `conn-step` updates the state it is given in place
;;; and returns it, so a caller threads the returned state and never reuses
;;; the one it passed.  A step then allocates nothing for the state itself;
;;; a core that copied a record per event would allocate more per request
;;; than the 3,072 B tests/test-connection-allocation.sps allows.
;;;
;;; Events and actions are tagged lists, (kind field ...):
;;;
;;;   events   (bytes-arrived bv start end)  (eof)  (read-error errno)
;;;            (write-completed nbytes)  (shutdown-completed)  (closed)
;;;            (tick now)  (parser-event callback-name . payload)
;;;            (parser-result status offset next code span)
;;;            (handler-responded answer [credit])  (handler-body-chunk bv start end)
;;;            (handler-body-end)  (handler-failed raised)  (body-credit n)
;;;            (shutdown-requested)
;;;
;;;   actions  (reply-parser continue|pause)  (feed-parser bv start end)
;;;            (resume-parser)  (write segments nbytes)  (read-stop)  (read-start)
;;;            (call-handler request)  (deliver-body bv start end)
;;;            (deliver-body-end)  (notify-producer)  (arm-deadline kind)
;;;            (disarm-deadline)  (shutdown)  (close reason)
;;;            (log what . details)  (hand-off take-over retained ended?)
;;;            (client-closed)
;;;
;;; A parser-result's `offset` is the parser's own count of the bytes it has
;;; taken since it was made (chez-httparse's `parser-result-stream-offset`),
;;; or at an error of the parser's own, the position of the byte it refused;
;;; its `code` is #f, or the error's or the pause's code, as its status says;
;;; and its `span` is #f, or at an error the span the error abandoned and
;;; where its withheld bytes begin, `(name . offset)` (WHAT THE PARSER'S
;;; ERROR CUTS OFF, below).  A span payload `bv start end` indexes the
;;; delivery the shell handed in; the core never copies it.
;;; `reply-parser` is the one action the shell answers inside the parser
;;; callback that produced it.
;;;
;;; PARSER CALLBACKS ALSO ENTER DIRECTLY.  A tagged list per callback would
;;; be the largest cost the core adds per request, so the adapter calls
;;; `conn-parser-step` or `conn-headers-complete-step` with the callback's
;;; own arguments and nothing is allocated to carry them.  The
;;; `parser-event` payload has three shapes, one per way in:
;;;
;;;   (parser-event name at)               an event callback
;;;   (parser-event name bv from to)       a span callback
;;;   (parser-event on-headers-complete method http-major http-minor
;;;                 flags content-length upgrade at)
;;;
;;; and `conn-step` only unpacks it and calls the entry point, so the
;;; transitions live in one place.  Either way, the first action answering a
;;; parser callback is always its `reply-parser`.  An event's `at` is the
;;; parser's position, the bytes of the connection it has read before the
;;; callback, which its runtime commits before calling it (byte-machine's
;;; `parser-stream-offset`); the core measures by it what the parser reads
;;; and hands no span of (WHAT THE PARSER READS AND HANDS NO SPAN OF, below).
;;;
;;; THE HEAD IS KEPT AS SPANS.  From on-message-begin to on-headers-complete
;;; the core keeps the request-target and each header name and value as a
;;; span of the delivery it arrived in, and copies only a name or value that
;;; arrived in more than one delivery, once, when it completes.  The method
;;; and version come from on-headers-complete's fields, so the request
;;; line's other spans are not kept.  The keep-alive decision is
;;; `should-keep-alive?` over the flags read there.  The target's limit and
;;; the four header limits are checked as the bytes arrive; one tripped is
;;; answered `(reply-parser (fail reason))`, and when the parser's error
;;; comes back the status is the reason's, not the parser's: 414 for the
;;; target, 431 for the headers.
;;;
;;; THE TARGET IS JUDGED at on-headers-complete, where the method is known:
;;; it must be the RFC 9112 §3.2 form its method and first byte call for,
;;; with bytes uriparse finds valid, or the message is refused as
;;; 'invalid-target, answered 400.  (http-server target) holds the rules and
;;; one judge per connection.  For the rare absolute-form and CONNECT
;;; targets the judge runs uriparse's own scanner, never the parser calling
;;; the core.  One refusal is a redirect instead: bracket params and pipes
;;; in a GET or HEAD, the bytes browsers send unencoded, are answered 301
;;; with the target encoded as the Location.
;;;
;;; THE VERSION IS JUDGED FIRST, at the same moment: a request whose version
;;; is not 1.x is refused as 'version-not-supported, answered 505 (RFC 9110
;;; §15.6.6).  The parser reads a request line with no version, or one that
;;; says HTTP/0.9, as HTTP/0.9, the lines after it as its fields; and,
;;; running llhttp's version leniency (the adapter's), any other HTTP/D.D,
;;; HTTP/2.0 and 3.0 among them, HTTP/2.0's preface handed off apart.  The
;;; server speaks HTTP/1.1 and 1.0 only, and a version it does not speak
;;; frames nothing.  A 1.x past 1.1, HTTP/1.2 say, is served as HTTP/1.1, as
;;; RFC 9110 §6.2 asks.  A version the parser cannot read, HTTP/1.x or
;;; HTTP/10.0, is its error, a 400.
;;;
;;; THE HOST IS JUDGED NEXT, at the same moment (RFC 9112 §3.2): two Host
;;; lines, a Host value that is not `uri-host [ ":" port ]`, and no Host on
;;; HTTP/1.1 unless the limits' switch is off, are refused as
;;; 'invalid-host, answered 400.  The 400 is a MUST, so a target the
;;; redirect would take never reaches it.  (http-server host) holds the
;;; rules; the value is judged in place.
;;;
;;; THE TRANSFER-ENCODING IS JUDGED TOO, from the parser's flags (RFC 9112
;;; §6.1).  A request below HTTP/1.1 that carries it has faulty framing: it
;;; is refused as 'faulty-framing, answered 400, right after the Host, since
;;; both rules are MUSTs.  The codings come last, once the target is
;;; accepted.  The server implements one coding, chunked, so when the parser
;;; frames the body by a final chunked (its F-CHUNKED flag) and the
;;; Transfer-Encoding lists another coding beside it, the request is refused
;;; as 'unsupported-transfer-coding, answered 501.  Every other invalid
;;; Transfer-Encoding the parser refuses itself, and its error is a 400.
;;; (http-server transfer-coding) holds both rules.
;;;
;;; THE PAUSE KEEPS THE REST OF THE DELIVERY.  At on-message-complete the
;;; core pauses the parser and calls the handler, in one step, so a delivery
;;; carrying two messages cannot start a second handler before the first
;;; response is written.  Where the parser stopped is known only once the
;;; feed returns, so the `parser-result` that follows keeps the delivery's
;;; rest, from `parser-result-next`, as the pending input, and the resume
;;; after the response feeds it.  The rest is always the end of the last
;;; delivery the core fed: reading goes on past the pause only to notice the
;;; client close, and the first delivery that comes before the response is
;;; held after the rest, as one, and reading stops (A CLIENT'S CLOSE,
;;; below), so the input is fed in order.  The core remembers that delivery
;;; for this.  After a close-marked message the rest is dropped, never fed,
;;; so llhttp's "Data after `Connection: close`" error cannot fire; an error
;;; result after the pause is not answered.
;;;
;;; A CLIENT'S CLOSE IS NOTICED WHILE ITS REQUEST IS ANSWERED.  From a
;;; request's end until its response is written, in `handling` and
;;; `responding`, the connection reads only to notice the client close or
;;; reset it.  Bytes that arrive are the next request's: held after the
;;; pause's rest, and reading stops, so a client that pipelines is noticed
;;; no more.  The client's end, its FIN, tells the request's code,
;;; `(client-closed)`, and the response, if the handler still gives one, is
;;; written, since a client that only half-closed still reads (RFC 9112
;;; §9.6); the connection then closes at once, with nothing left to linger
;;; for.  An end that comes with requests held behind the one answered tells
;;; no one: the client sent them, and waits for their answers, which it gets
;;; before the connection closes.  A read error tells the code too, and
;;; closes.  The shell ends the wait the request's code is in, or its next,
;;; with `&client-closed` (the waits library's notice), and a handler that
;;; lets that raise out is answered nothing, the connection closing for
;;; `client-closed`.  While the body is still being read, reading stops when
;;; the reader falls behind, so the client's close waits for the next read.
;;;
;;; AN UPGRADE IS SERVED, THEN THE CONNECTION CLOSES.  A request that asks
;;; to switch protocols, by llhttp's rule a CONNECT or `Connection: upgrade`
;;; with `Upgrade`, which the parser's `upgrade` field answers
;;; (chez-httparse v0.4.1 or later), reaches the handler like any other, and
;;; unless the handler takes it through the door (below), the connection
;;; closes after the response, as a close-marked message's does.  So its
;;; pause at on-message-complete is the last: the parser is never resumed
;;; onto its own hand-off, and the bytes after the request, another
;;; protocol's, are never fed to it.  `Upgrade: h2c` is such a request.  The
;;; HTTP/2 preface is not a request: it hands off on the parser's error
;;; channel (`result-hands-off-stream?` checks both), and the core answers
;;; it 505, then close.  The parser's hand-off on its pause channel never
;;; comes, since the core never resumes the parser onto an upgrade: one that
;;; did would be the shell's bug, refused.
;;;
;;; THE DOOR.  A handler takes an upgrade by answering a switch,
;;; (http-server switch)'s record, instead of a response.  The door opens
;;; for an HTTP/1.1 request the parser marks as an upgrade, `Connection:
;;; upgrade` with `Upgrade`, kept alive, that is no CONNECT and has no body:
;;; its 101 is written, (http-server serializer)'s, and once the 101's write
;;; has completed the core hands the stream over, `(hand-off take-over
;;; retained ended?)`: the switch's take-over, and the bytes read past the
;;; request, the pending input the message's pause kept, `(bv start end)`,
;;; or #f when the read ended with the request.  A request that expects
;;; 100-continue has the 100 written first, in the 101's one write (RFC 9110
;;; §7.8).  The connection is then `handed-off`, its input forgotten, its
;;; deadline disarmed and its reading stopped, so what the client sends next
;;; waits for the taker's read-start; the shell hands the taker the stream,
;;; with the client's end if it was read as the 101 was written, and the
;;; core asks for nothing more but ends at the stream's close.  A switch
;;; answered to any other request, and one the serializer finds a fault in
;;; (switch-fault), is answered 500, logged `invalid-response`, as a
;;; response with a fault is.
;;;
;;; A RESPONSE IS WRITTEN AS SEGMENTS.  `(write segments nbytes)` is one
;;; write: (http-server serializer)'s segments, the Date slot among them as
;;; the symbol `date` for the shell to fill, and the bytes they come to.
;;; The framing is (http-server decisions)', for the request being answered:
;;; its method, its version and the response's status and body.  The
;;; Connection field says `close` when the connection closes after the
;;; response, which a close-delimited body always does.  A handler's
;;; response the serializer cannot write safely is answered 500 instead,
;;; then close, with `(log invalid-response fault)` before it, and a
;;; handler's `Connection: close` closes the connection after its response.
;;; The core's own responses are framed the same way, with no body.  Every
;;; entry into `responding` arms the write deadline, the core's own
;;; responses included.
;;;
;;; A WRITE IS COUNTED, NOT KEPT.  Each write is outstanding, with the bytes
;;; it comes to, until the shell reports `(write-completed nbytes)`: in
;;; `responding`; in `body`, `handling` or `awaiting-credit` for a `100
;;; Continue`, written while the request is still read or answered (EXPECT,
;;; below); or, for a write a close cut short, in `closing`.  A completion
;;; the core did not ask for is an assertion violation.  The write water
;;; marks read the bytes outstanding (A BODY OF UNKNOWN LENGTH, below).  The
;;; core keeps nothing of the response itself: chez-libuv copies the
;;; segments when the write is issued, so nothing needs them after that
;;; (tests/test-connection-retention.sps checks it).
;;;
;;; A CONNECTION CLOSES IN STAGES (RFC 9112 §9.6).  Once the last write of a
;;; response that closes the connection completes, the core asks for
;;; `shutdown`, the half-close, so the client reads the response and then
;;; the stream's end, and it lingers: it reads again, drops what arrives,
;;; and closes when the client closes, when a read fails, or when the linger
;;; deadline passes.  Closing at once while the client still sends makes the
;;; server's TCP stack reset the connection, which fails a client's send
;;; before it reads the response and throws away what of the response the
;;; kernel has not yet sent.  Every close after a response lingers, the
;;; core's own statuses and a handler's close alike; a close with no
;;; response (the client's end, a read error, the idle deadline) is at once,
;;; and so is one after a response to a client that has closed already.
;;; The deadline is armed once, so a client that keeps sending cannot hold
;;; the connection past it, and the close names the reason the connection
;;; closes after its response.  A state that reads stops reading when it
;;; refuses a request, so the client's end waits in the kernel for the
;;; linger, and nothing has to remember it.
;;;
;;; A BODY IS READ BY A READER.  A request whose framing announces a body,
;;; chunked or a Content-Length above 0, is handed to the handler once the
;;; feed that completed its head has returned, before any of its body: the
;;; `call-handler` comes with that feed's `parser-result`.  The handler
;;; answers a response or a reader, (http-server body)'s, as
;;; `handler-responded`.  A reader is handed each piece the parser meets as
;;; `deliver-body`, the read's own span, in order, and `deliver-body-end`
;;; once the message has ended; the reader's response comes back as
;;; `handler-responded` too.  A whole reader is handed its body instead as
;;; one piece at the end, which the core copies from the pieces as they
;;; arrive, into one bytevector grown to the declared length, or joined
;;; when chunked.  A response given instead of a reader is sent at once, and
;;; the connection closes after it, as 'unread-body: the body is not read.
;;; A body past a cap is refused as 'body-too-large, answered 413: the
;;; limits' max-body-bytes caps every body, and a reader may carry a cap of
;;; its own.  A declared length past the limits' cap is refused before the
;;; handler is asked, past a reader's once it answers, and a counted one at
;;; the piece that passes it, a streaming reader handed the piece up to the
;;; cap.  A request with no body is handed over at its end, and a reader
;;; answered for one is handed its end at once.  The parser is never paused
;;; inside a body.  The shells find the reader a piece goes to with
;;; `conn-body-reader`.
;;;
;;; READING WAITS FOR A READER'S CREDIT.  Whether it must is the shell's to
;;; say, since the shell hands the pieces over: one that hands a streaming
;;; reader its pieces on credit answers with the reader and `credit`,
;;; `(handler-responded reader credit)`, as the shells do for a handler that
;;; waits, handing each piece to the handler's coroutine.  Such a reader
;;; owes credit for each byte it is handed.  Once a read's feed has
;;; returned, or its answer has taken the pieces kept for it, with credit
;;; owed, the connection waits in `awaiting-credit`: reading stops, and the
;;; body deadline is disarmed, since the server, not the client, is the one
;;; waiting.  `(body-credit n)` says the reader has taken `n` more bytes;
;;; once its credit covers what it was handed, reading starts again and the
;;; body deadline is armed again.  So a slow reader holds at most one read.
;;; A shell that calls a reader in place answers with no word of credit, so
;;; the reader takes each piece as it is handed over, and reading goes on at
;;; once.  A whole reader's pieces are the core's to copy, so it never owes
;;; credit.
;;;
;;; A HANDLER ANSWERS AFTER THE DRAIN THAT ASKS IT.  The shells call a
;;; handler once their drain has ended, the libuv shell after libuv's turn,
;;; so its answer is a later event, never one of the drain that emitted
;;; `call-handler`.  A request whose body is still arriving when its handler
;;; is asked waits on it in handling, as one whose body has ended does:
;;; reading stops, and the body deadline with it, since the server is the
;;; one waiting, and the handler's reader reads again (`read-on`), with the
;;; body deadline, or waits for its credit.
;;;
;;; A BODY OF UNKNOWN LENGTH IS WRITTEN A PIECE AT A TIME.  A response whose
;;; body is a producer, a procedure the server calls for each piece, is
;;; written as its head, framed chunked to HTTP/1.1 and close-delimited to
;;; 1.0 (http-server decisions), and then, a piece at a time, as the
;;; producer answers: `(notify-producer)` asks the shell to call it, and its
;;; answer comes back as `(handler-body-chunk bv start end)`, or
;;; `(handler-body-end)` at the end (`producer-event` says which), or as
;;; `handler-failed` if it raised or answered neither a piece of a byte or
;;; more nor the eof object.  Each piece is a write of its own, and the end
;;; of a chunked body is its last chunk.  The limits' write water marks
;;; bound what is outstanding: the producer is asked only while the bytes
;;; written and not yet completed are at or below the high water, so at
;;; most one piece passes it, and once past it, it waits until a completion
;;; brings them to the low water, and to the high water too, whatever
;;; limits the connection was given, then is asked again.  The writes
;;; outstanding are bounded as well, at 64, and a waiting producer is asked
;;; again at 16 or fewer (`stream-writes-high`, `-low`): a write holds the
;;; loop and memory the same whatever its size, so small pieces would
;;; otherwise make a turn ask thousands of times.  The response is written
;;; once its end has come and every write has completed, and a
;;; close-delimited one then closes, in stages, as every close after a
;;; response does.  No body is written to a HEAD, a 204 or a 304, so their
;;; producer is never called.  A producer that fails once the head is on
;;; the wire gets a bare close: no status can be written after the head, and
;;; the client reads the body cut short.  The shells find the producer to
;;; call with `conn-producer`.
;;;
;;; EXPECT: 100-CONTINUE IS ANSWERED WHEN THE HANDLER PULLS THE BODY.  A
;;; client that sends `Expect: 100-continue` with a head that announces a
;;; body may wait for `100 Continue` before it sends the body (RFC 9110
;;; §10.1.1).  Answering with a reader is pulling the body, so the 100 is
;;; written then, its status line and the blank line, before anything else
;;; the answer brings, however much of the body has arrived, so that what
;;; happens does not depend on how the bytes were split into reads.  A
;;; response given instead, a reader whose cap the declared length passes,
;;; and a handler that raises write their final status and no 100.  What
;;; the head's feed met in the body, an error or a body past the reader's
;;; cap, is answered after the 100, as it would be had it come in a later
;;; read.  Until the 100 the server is the one waiting, so the head arms no
;;; body deadline, and the 100 arms it; a piece the client sends without
;;; waiting arms it too, as any piece does.  The 100 is a write like any
;;; other, outstanding until the shell reports it completed, in whatever
;;; state that finds the connection.  The expectation is ignored on
;;; HTTP/1.0, as RFC 9110 says it must be, on a request with no body, and
;;; when it is not 100-continue.
;;;
;;; WHAT A CHUNKED BODY CARRIES BESIDE ITS DATA IS HELD TO LIMITS.  Its
;;; trailer fields arrive as header callbacks in `body`, once the last chunk
;;; is read, and are held to the four header limits, as a head's fields
;;; are, counted afresh: the head's fields leave the trailers their own, and
;;; none is kept.  Its chunk extensions, the bytes of their names and values
;;; and a byte as each ends, for the `;` or `=` before it, all of a body's
;;; together, are held to 16 KiB (`max-chunk-extension-bytes`), fixed, not
;;; a setting, as hyper holds a body's and RFC 9112 §7.1.1 advises a total
;;; for a request (Node holds each chunk's to 16 KiB instead).  One past a
;;; limit is refused as a head's field is, `(reply-parser (fail reason))`: a
;;; trailer for the head's reason, answered 431, and the extensions as
;;; 'chunk-extensions-too-large, answered 413, as a body past a cap.
;;;
;;; WHAT THE PARSER READS AND HANDS NO SPAN OF IS HELD TO LIMITS TOO.  Four
;;; runs of it, which the parser reads without limit: the empty lines before
;;; a request line, the spaces between its parts, the whitespace before a
;;; field's value, and a chunk size's digits.  Every event carries the
;;; parser's position, and a span's is its delivery's base plus its bound,
;;; so a run is measured from where one piece ends to where the next begins
;;; (`open-run!`).  Two empty lines, 4 bytes, are skipped, and more are
;;; refused as 'empty-lines; one space between the request line's parts,
;;; and more as 'request-line-spaces; a chunk size has 16 hex digits at
;;; most, zeros included, and more is refused as 'chunk-size-too-long: all
;;; three answered 400 (`run-limits`).  The whitespace before a value counts
;;; with it, against its limit and the section's, as the whitespace after it
;;; does, 431 past one, named for the limit its bytes passed first
;;; (`first-past`); an empty value's line end, which the parser reads before
;;; it hands the value over, does not count.  A run is judged at the
;;; callback that ends it and, while it runs, at every read's end, so it is
;;; refused within the read that passes its limit, whatever the split
;;; (`run-past-limit`); one refused at a read's end is answered as a
;;; callback's refusal is when the parser's error comes back.  The parser
;;; ends a target at a space, a CRLF or a bare LF, and does not say which,
;;; so the spaces after it are counted from each, and a request line with no
;;; version lets them go at its first field or its head's end.  At the
;;; parser's error the run still open is judged as at a read's end, once
;;; what the error cut off is placed (below).
;;;
;;; WHAT THE PARSER'S ERROR CUTS OFF IS JUDGED TOO.  A malformed byte ends
;;; the parse, and the span the parser was reading is abandoned, never
;;; handed on: a target's or a field name's, since a value, an extension and
;;; the protocol are handed on first.  Unjudged, a target or a name past its
;;; limit would be answered for the limit where a read ended between that
;;; byte and the malformed one, and 400 where one read held both.  At an
;;; error the shell hands the core the position of the byte the parser
;;; refused, and the span the error abandoned with where its withheld bytes
;;; begin, which the error records (byte-machine's `parser-error-span` and
;;; `parser-error-span-offset`, v0.7.0 or later; the adapter's
;;; `parser-result-event`).  The core judges what was cut off as a read's
;;; end would have, the span's withheld bytes, up to the refused byte, and
;;; then the run still open (`cut-off-past-limit`): the first limit passed,
;;; in the order of the bytes, names the response, whatever the split, as
;;; reads of a byte at a time would.
;;;
;;; WHAT HAPPENS NEVER DEPENDS ON HOW THE BYTES WERE SPLIT INTO READS.  The
;;; feed that completes a head can go on into its body before the handler
;;; is asked.  What it meets there waits for the handler's answer, as it
;;; would have come after it had the body arrived in a later read: the
;;; pieces are kept, and handed to a reader once it answers; and an error
;;; the parser meets, or a cap the body passes, is kept too, and answered
;;; after those pieces, or not at all if the handler answers with a
;;; response, since the body is then not read.
;;;
;;; DEADLINES ARE KINDS, NOT INSTANTS.  `(arm-deadline kind)` names which of
;;; the connection's one deadline — idle, header, body, write or linger — to
;;; arm, and carries no time: no event but `tick` carries `now`, so the core
;;; cannot turn a duration into an instant.  The shell's timing wheel does,
;;; from the limits, and ticks a connection only once the deadline it armed
;;; has passed, and only as it lets that deadline go.  The state records the
;;; armed kind, so a tick is acted on only while the core still has a
;;; deadline of that kind armed, and every kind has its tick row.  The
;;; record and the actions agree: wherever the core lets a deadline go of
;;; its own accord, it emits `(disarm-deadline)`, so every way it lets a
;;; connection go, a close or the hand-off, takes the connection out of the
;;; wheel.  A tick clears the record with no disarm, since the wheel has
;;; already let the deadline go.
(library (http-server connection)
  (export conn-states conn-events conn-actions conn-deadline-kinds
          conn-parser-callbacks conn-span-callbacks
          make-conn-state conn-state?
          conn-phase conn-deadline conn-close-after conn-outstanding
          conn-outstanding-bytes conn-pending conn-request conn-limits conn-body-reader
          conn-body-buffered conn-producer conn-taker producer-event
          conn-step conn-parser-step conn-headers-complete-step)
  (import (rnrs)
          (http-server response) (http-server request) (http-server span)
          (http-server limits) (http-server decisions) (http-server target)
          (only (http-server body) body-reader? body-reader-max-bytes body-reader-whole?)
          (only (http-server host) host-fault)
          (only (http-server transfer-coding) unsupported-transfer-coding? faulty-framing?)
          (only (http-server serializer)
                serialize-response serialize-checked-response serialize-piece serialize-end
                serialize-continue serialize-switch response-fault response-closes? switch-fault)
          (only (http-server switch) switch? switch-take-over)
          (only (http-server awaiting) client-closed?)
          (only (http-server headers) field-lists?)
          (only (httparse decisions) should-keep-alive? F-CHUNKED)
          (only (httparse methods) httparse-method-numbers))

  ;; conn-states : (Listof Symbol)
  ;; The ten connection states, among them `lingering`, where a connection
  ;; that closes after its response waits for the client to close, and
  ;; `awaiting-credit`, where a body waits for its reader's credit.  `idle`,
  ;; `head`, `body` and `lingering` read from the socket, and from a
  ;; request's end to its response's, so do `handling` and `responding`,
  ;; only to notice the client close; `closed` is terminal.
  (define conn-states
    '(idle head body awaiting-credit handling responding lingering handed-off
      closing closed))

  ;; conn-events : (Listof Symbol)
  ;; The fifteen event kinds: the closed set `conn-step` accepts.
  (define conn-events
    '(bytes-arrived eof read-error write-completed shutdown-completed closed
      tick parser-event parser-result handler-responded handler-body-chunk
      handler-body-end handler-failed body-credit shutdown-requested))

  ;; conn-actions : (Listof Symbol)
  ;; The seventeen action kinds, among them `hand-off`, which hands an
  ;; upgrade's stream to the switch that takes it, and `client-closed`,
  ;; which tells the request's code its client has closed or reset the
  ;; connection.
  (define conn-actions
    '(reply-parser feed-parser resume-parser write read-stop read-start
      call-handler deliver-body deliver-body-end notify-producer
      arm-deadline disarm-deadline shutdown close log hand-off client-closed))

  ;; conn-deadline-kinds : (Listof Symbol)
  ;; The five kinds of deadline the core arms, `(arm-deadline kind)`: idle,
  ;; header, body, write and linger.  How long each lasts is the limits'
  ;; (limits-deadline-ms); the shell's wheel turns it into an instant.
  (define conn-deadline-kinds '(idle header body write linger))

  ;; conn-parser-callbacks : (Listof Symbol)
  ;; chez-httparse's twenty-five parser callbacks, in llhttp's trace order:
  ;; the closed set the two parser entry points accept.
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
  ;; the parser's position, and on-headers-complete enters through an entry
  ;; point of its own, with the fields read inside it.
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
  ;;   Limits     = the policy the core enforces; anything but a limits
  ;;                record is an assertion violation
  ;; conn-state? : Any -> Boolean
  ;; conn-phase / -deadline / -close-after / -outstanding / -outstanding-bytes
  ;;   / -pending / -request / -limits : ConnState -> the corresponding field
  ;; The request head being read is kept in the state too, and so are the
  ;; request body being read, the connection's target judge, the last
  ;; delivery it fed the parser, `(bv start end)` or #f, and a streamed
  ;; response's producer, how its pieces are framed, and whether a piece
  ;; has been asked for and its answer is to come; only the producer is
  ;; exported, for the shells.  And where the parser is: the bytes it has
  ;; taken, as its last read's result counts them; the parser's position of
  ;; index 0 of the delivery being fed; and the run of bytes it reads and
  ;; hands no span of that is open, where it began and what it is (see
  ;; open-run!).  A state is made at a connection's first byte, so the empty
  ;; lines before its first request line are open from there.  A state made
  ;; in `handling` has a message that has ended, and is waiting for its
  ;; handler's answer, as a request with no body is.  And whether the
  ;; client's end has come while its requests were answered.
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
            (mutable delivery    conn-delivery    conn-delivery-set!)
            (mutable producer    conn-producer    conn-producer-set!)
            (mutable pieces      conn-pieces      conn-pieces-set!)
            (mutable asked?      conn-asked?      conn-asked?-set!)
            (mutable parsed      conn-parsed      conn-parsed-set!)
            (mutable base        conn-base        conn-base-set!)
            (mutable mark        conn-mark        conn-mark-set!)
            (mutable run         conn-run         conn-run-set!)
            (mutable taker       conn-taker       conn-taker-set!)
            (mutable ended?      conn-ended?      conn-ended?-set!))
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
                (make-head) body (make-target-judge) #f #f #f #f 0 0 0 'lines #f #f))))))

  ;; conn-body-reader : ConnState -> (U #f BodyReader)
  ;; The reader the handler answered with, while the core hands it the body:
  ;; the one each `deliver-body` and `deliver-body-end` goes to, until its
  ;; response comes back, and #f otherwise.
  (define (conn-body-reader s) (body-reader-of (conn-body s)))

  ;; conn-producer : ConnState -> (U #f (-> Any))
  ;; The producer a streamed response's body is written from, while it is:
  ;; the one each `notify-producer` asks the shell to call, and #f otherwise.

  ;; conn-taker : ConnState -> (U #f (Transport Bytevector -> Any))
  ;; The take-over of the switch whose 101 is being written, while it is: the
  ;; one the hand-off carries once the 101 is written, and #f otherwise.

  ;; producer-event : Any -> Event
  ;; The event a producer's answer is to the core: a bytevector of a byte or
  ;; more, one more piece, `(handler-body-chunk bv 0 n)`; the eof object, the
  ;; end, `(handler-body-end)`.  Anything else is an assertion violation,
  ;; which a shell that calls the producer inside its guard reports as
  ;; `handler-failed`, as it reports the producer's own raise.  An empty
  ;; bytevector among them: `get-bytevector-some` never answers one, and a
  ;; producer asked again at once for as long as it answered one would hold
  ;; the loop, every connection's, until it had something.  The violation
  ;; names the answer by its kind and length (answer-kind), never holds it:
  ;; the shells log it, and the answer is the response's data, a whole page
  ;; when a string was answered for its bytes.
  (define (producer-event x)
    (cond ((and (bytevector? x) (fx>? (bytevector-length x) 0))
           (list 'handler-body-chunk x 0 (bytevector-length x)))
          ((eof-object? x) '(handler-body-end))
          (else (assertion-violation 'producer-event
                  "a producer answers a bytevector of a byte or more, or the eof object at the end"
                  (answer-kind x)))))

  ;; answer-kind : Any -> (Listof (U Symbol Nat))
  ;; What an answer that is no piece is, by its kind and, where it has one,
  ;; its length: `(string 5)`, `(list 2)`, `(symbol)`, and `(other)` for a
  ;; kind not named.
  (define (answer-kind x)
    (cond ((bytevector? x) (list 'bytevector (bytevector-length x)))
          ((string? x) (list 'string (string-length x)))
          ((vector? x) (list 'vector (vector-length x)))
          ((list? x) (list 'list (length x)))
          ((pair? x) '(pair))
          ((symbol? x) '(symbol))
          ((char? x) '(char))
          ((number? x) '(number))
          ((boolean? x) '(boolean))
          ((procedure? x) '(procedure))
          (else '(other))))

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
  ;; connection, rolled at each on-message-begin.  Once the head is
  ;; complete, the sizes count the trailer fields instead, afresh, and the
  ;; trailers are not kept.
  ;;   target   the request-target, once on-url-complete has run
  ;;   fields   the completed (name . value) pairs, newest first
  ;;   count    the header names completed so far
  ;;   total    the header name and value bytes so far, and the whitespace
  ;;            before each value
  ;;   name     the completed name waiting for its value
  ;;   piece    the span being read: #f, a Span, or several, newest first
  ;;   size     the bytes of the piece so far, or of the trailer's name or
  ;;            value
  ;;   refusal  #f, or the reason the core answered a callback with fail
  ;;   location #f, or where a redirected target points
  ;;   pad      the whitespace before the value being read, counted with it
  (define-record-type head
    (fields (mutable target) (mutable fields) (mutable count) (mutable total)
            (mutable name) (mutable piece) (mutable size) (mutable refusal)
            (mutable location) (mutable pad))
    (protocol (lambda (new) (lambda () (new #f '() 0 0 #f #f 0 #f #f 0)))))

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
    (head-location-set! h #f)
    (head-pad-set! h 0))

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

  ;; The request body being read: how its framing announced it, the bytes
  ;; of it met, the handler's answer, and what is kept for that answer.  One
  ;; per connection, rolled with the head.
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
  ;;   credit?   whether the shell hands the reader its pieces on credit, as
  ;;             it said with the reader
  ;;   owed      the bytes handed to a streaming reader on credit, and not
  ;;             yet credited; a whole reader's pieces the core copies, so
  ;;             it owes none
  ;;   continue? whether the client waits for `100 Continue` and it is still
  ;;             to be written
  ;;   extensions the bytes of the chunk extensions' names and values met
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
            (mutable filled    body-filled    body-filled-set!)
            (mutable credit?   body-credit?   body-credit?-set!)
            (mutable owed      body-owed      body-owed-set!)
            (mutable continue? body-continue? body-continue?-set!)
            (mutable extensions body-extensions body-extensions-set!))
    (protocol (lambda (new) (lambda () (new #f #f 0 #f '() #f #f #f #f 0 #f 0 #f 0)))))

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
    (body-filled-set! bd 0)
    (body-credit?-set! bd #f)
    (body-owed-set! bd 0)
    (body-continue?-set! bd #f)
    (body-extensions-set! bd 0))

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
  ;; let a head alone take up to the reader's cap.
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
  ;; more at its peak.
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
      ((handler-responded)  (on-handler-responded s (cadr ev) (cddr ev)))
      ((handler-body-chunk) (on-body-chunk s (cdr ev)))
      ((handler-body-end)   (on-body-end s))
      ((handler-failed)     (on-handler-failed s (cadr ev)))
      ((body-credit)        (on-body-credit s (cdr ev)))
      ((shutdown-requested) (on-shutdown-requested s))
      ((closed)             (on-closed s))
      ;; The half-close's completion changes nothing: the client's close, not
      ;; it, ends a linger.
      ((shutdown-completed) (values s '()))
      (else (assertion-violation 'conn-step "not a connection event" ev))))

  ;; The transitions, one procedure per event kind, each headed by the rows
  ;; it implements: `state, event -> state`.

  ;; idle, bytes-arrived -> idle: feed the delivery to the parser.  head and
  ;; body feed it too, for a message that arrives in more than one delivery.
  ;; The delivery is remembered, sharing the event's `(bv start end)`, for
  ;; a pause to keep its rest.  In every other state nothing is fed, so after
  ;; a close-marked message nothing more is; lingering reads, and drops what
  ;; arrives.
  ;; handling or responding, bytes-arrived -> the same: past a request's end
  ;; the connection reads only to notice the client close, so the delivery
  ;; is the next request's, held after the pause's rest as one, and reading
  ;; stops (hold!).
  (define (on-bytes-arrived s ev)
    (case (conn-phase s)
      ((idle head body)
       (conn-delivery-set! s (cdr ev))
       (feeding! s (caddr ev))
       (values s (list (cons 'feed-parser (cdr ev)))))
      ((handling responding) (hold! s (cadr ev) (caddr ev) (cadddr ev)))
      (else (values s '()))))

  ;; hold! : ConnState Bytevector Nat Nat -> (values ConnState (Listof Action))
  ;; bv[start, end), a delivery that came before the response, held as the
  ;; pending input the resume feeds: after the pause's rest, the two copied
  ;; into a bytevector of their own, or alone.  It is the delivery the parser
  ;; is fed next, so it is remembered as the last one, and the parser's
  ;; position of its index 0 is where the parser stopped less the index its
  ;; bytes begin at, as feeding! keeps it for a delivery fed at once.
  (define (hold! s bv start end)
    (let* ((rest (conn-pending s))
           (held (if rest
                     (let* ((n (fx- (caddr rest) (cadr rest)))
                            (o (make-bytevector (fx+ n (fx- end start)))))
                       (bytevector-copy! (car rest) (cadr rest) o 0 n)
                       (bytevector-copy! bv start o n (fx- end start))
                       (list o 0 (bytevector-length o)))
                     (list bv start end))))
      (conn-pending-set! s held)
      (conn-delivery-set! s held)
      (feeding! s (cadr held))
      (values s '((read-stop)))))

  ;; feeding! : ConnState Nat -> Void
  ;; A feed from index `start` of a delivery: the parser reads it from the
  ;; bytes it has taken, so index 0 is that less `start`.  The rest a pause
  ;; keeps is its delivery's own bytes, from where the parser stopped, so it
  ;; is fed with the delivery's base, unchanged.
  (define (feeding! s start)
    (conn-base-set! s (- (conn-parsed s) start)))

  ;; idle, head or body, eof -> closing: close, with no response.
  ;; handling or responding, eof -> the same: the client has closed, and
  ;; reading stops.  With nothing held, the request is the one the client
  ;; waits on: its code is told, and the connection closes for the client
  ;; once its response is written.  With a delivery held,
  ;; the client sent more before its end, so it waits for their answers
  ;; too: no one is told, and the requests held are answered, the
  ;; connection closing once none is left (read-result, response-written).
  ;; lingering, eof -> closing: the client closed, so close, for the reason
  ;; the connection closes after its response.
  (define (on-eof s)
    (case (conn-phase s)
      ((idle head body) (close s 'eof '()))
      ((handling responding)
       (conn-ended?-set! s #t)
       (if (conn-pending s)
           (values s '((read-stop)))
           (begin
             (conn-close-after-set! s 'client-closed)
             (values s '((read-stop) (client-closed))))))
      ((lingering) (close s (conn-close-after s) '()))
      (else (values s '()))))

  ;; any live state, read-error -> closing: log it, close, no response.
  ;; ECANCELED is a request only the shell's own close cancels: a close from
  ;; outside the core, at a drain's deadline or for a bug, with a write or
  ;; the half-close outstanding.  No transport failed, so it closes for
  ;; `cancelled`, and logs nothing.
  ;; From handling or responding, the request's code is told first, as at
  ;; the client's end.
  (define (on-read-error s errno)
    (case (conn-phase s)
      ((idle head body awaiting-credit handling responding lingering)
       (cond ((eq? errno 'ECANCELED) (close s 'cancelled '()))
             ((memq (conn-phase s) '(handling responding))
              (close s 'read-error (list '(client-closed) (list 'log 'read-error errno))))
             (else (close s 'read-error (list (list 'log 'read-error errno))))))
      (else (values s '()))))

  ;; responding, write-completed: the write and its bytes are no longer
  ;; outstanding.  Keep waiting while writes are.  On the last one, a
  ;; response that closes the connection is followed by the staged close:
  ;; lingering, the write side shut, reading again to drop what arrives,
  ;; the linger deadline armed, and nothing of the input kept.  Otherwise
  ;; resume parsing what was retained and read again.  After a close-marked
  ;; message the retained input is dropped, never fed.
  ;; While a streamed response's body is written, its end still to come, a
  ;; completion is the stream's: `stream-completed`.
  ;; closing, write-completed: a write the close cut short, after a read
  ;; error in responding, is settled the same way, and nothing more is asked.
  ;; body, handling or awaiting-credit, write-completed: a `100 Continue` is
  ;; settled, and nothing more is asked: the request is still read, or
  ;; answered, as before it.
  ;; In the other states no write is outstanding, and nothing changes.
  (define (on-write-completed s fields)
    (case (conn-phase s)
      ((responding)
       (complete-write! s fields)
       (cond
        ((conn-producer s) (stream-completed s))
        ((> (conn-outstanding s) 0)
         (conn-deadline-set! s 'write)
         (values s '((arm-deadline write))))
        (else (response-written s))))
      ((closing body handling awaiting-credit)
       (complete-write! s fields)
       (values s '()))
      (else (values s '()))))

  ;; response-written : ConnState -> (values ConnState (Listof Action))
  ;; responding -> the response is written, every write completed: the
  ;; staged close, or idle, as on-write-completed says.  Once the client's
  ;; end has come, a close is at once, the end the linger waits for having
  ;; come, and with nothing more held it closes; otherwise what is held is
  ;; fed, and reading never starts again.
  (define (response-written s)
    (cond
     ((conn-taker s) (hand-off s))
     ((conn-close-after s)
      (forget-input! s)
      (if (conn-ended? s)
          (close s (conn-close-after s) '())
          (begin
            (conn-phase-set! s 'lingering)
            (conn-deadline-set! s 'linger)
            (values s '((shutdown) (read-start) (arm-deadline linger))))))
     ((and (conn-ended? s) (not (conn-pending s)))
      (close s 'eof '()))
     (else
      (let ((pending (conn-pending s)))
        (conn-phase-set! s 'idle)
        (conn-deadline-set! s 'idle)
        (conn-pending-set! s #f)
        (values s `((resume-parser)
                    ,@(if pending (list (cons 'feed-parser pending)) '())
                    ,@(if (conn-ended? s) '() '((read-start)))
                    (arm-deadline idle)))))))

  ;; hand-off : ConnState -> (values ConnState (Listof Action))
  ;; responding, the 101's last write completed -> handed-off: the deadline
  ;; disarmed, reading stopped, and the hand-off, with the switch's
  ;; take-over and the bytes read past the request, the pending input the
  ;; message's pause kept, or #f, and whether the client's end has come,
  ;; read while the 101 was written.  The input is forgotten, and the
  ;; take-over with it.  Reading stops before the take-over is called, so a
  ;; read-start it makes stands, and nothing is read for the core, which
  ;; drops what it reads once handed off: what the client sends next waits
  ;; for the taker.  The end is the taker's to hear, and the shell tells it,
  ;; not the kernel.
  (define (hand-off s)
    (let ((take-over (conn-taker s)) (retained (conn-pending s)) (ended? (conn-ended? s)))
      (conn-taker-set! s #f)
      (forget-input! s)
      (conn-phase-set! s 'handed-off)
      (conn-deadline-set! s #f)
      (values s (list '(disarm-deadline) '(read-stop) (list 'hand-off take-over retained ended?)))))

  ;; stream-completed : ConnState -> (values ConnState (Listof Action))
  ;; A completion while a streamed body is written.  A producer that waits,
  ;; past the high water, is asked again once the bytes outstanding are at
  ;; or below the low water, and at or below the high water too: a producer
  ;; is never asked past it, whatever limits the connection was given, and
  ;; limits-with, unlike the environment, accepts a low water above the
  ;; high.  One that waits at 64 writes outstanding is asked again once they
  ;; are 16 or fewer too.  The write deadline stays armed while a write is
  ;; outstanding; with none, none is, since the producer is then the one
  ;; waited on, and the limits have no deadline for a handler.
  (define (stream-completed s)
    (let ((writing? (> (conn-outstanding s) 0)))
      (conn-deadline-set! s (and writing? 'write))
      (cond
       ((and (not (conn-asked? s))
             (below-high-water? s)
             (<= (conn-outstanding-bytes s) (limits-write-low-water (conn-limits s)))
             (<= (conn-outstanding s) stream-writes-low))
        (conn-asked?-set! s #t)
        (values s (if writing?
                      '((arm-deadline write) (notify-producer))
                      '((disarm-deadline) (notify-producer)))))
       (writing? (values s '((arm-deadline write))))
       (else (values s '((disarm-deadline)))))))

  ;; responding, handler-body-chunk bv start end: the piece the producer was
  ;; asked for.  It is written, framed as the head framed the body,
  ;; and the write deadline armed; then the producer is asked for the next
  ;; one while the bytes outstanding are at or below the high water and
  ;; fewer than 64 writes are, and waits otherwise.  A piece no one asked
  ;; for, or one of no bytes, which `producer-event` never makes, is the
  ;; shell's bug: an assertion violation.  In any other state the producer
  ;; has been let go, and nothing changes.
  (define (on-body-chunk s fields)
    (case (conn-phase s)
      ((responding)
       (unless (conn-asked? s)
         (assertion-violation 'conn-step "a piece the core did not ask for" fields))
       (let ((bv (car fields)) (start (cadr fields)) (end (caddr fields)))
         (unless (and (fixnum? start) (fixnum? end) (fx<? start end))
           (assertion-violation 'conn-step "a piece of no bytes" fields))
         (let-values (((segments bytes) (serialize-piece (conn-pieces s) bv start end)))
           (let ((w (count-write! s segments bytes)))
             (conn-deadline-set! s 'write)
             (if (below-high-water? s)
                 (values s (cons w '((arm-deadline write) (notify-producer))))
                 (begin (conn-asked?-set! s #f)
                        (values s (cons w '((arm-deadline write))))))))))
      (else (values s '()))))

  ;; responding, handler-body-end: the producer's body has ended, and the
  ;; producer is let go.  A chunked body's last chunk is written, and the
  ;; write deadline armed.  A close-delimited body has nothing more to write,
  ;; since the close ends it: with a write outstanding, its completion writes
  ;; the response; with none, it is written now.  An end no one asked for is
  ;; the shell's bug, an assertion violation; in any other state, nothing.
  (define (on-body-end s)
    (case (conn-phase s)
      ((responding)
       (unless (conn-asked? s)
         (assertion-violation 'conn-step "an end the core did not ask for" (conn-producer s)))
       (let ((framing (conn-pieces s)))
         (end-stream! s)
         (let-values (((segments bytes) (serialize-end framing)))
           (cond
            ((pair? segments)
             (let ((w (count-write! s segments bytes)))
               (conn-deadline-set! s 'write)
               (values s (cons w '((arm-deadline write))))))
            ((> (conn-outstanding s) 0) (values s '()))
            (else (response-written s))))))
      (else (values s '()))))

  ;; count-write! : ConnState (Listof Segment) Nat -> Action
  ;; `(write segments bytes)`, outstanding, with its bytes, until the shell
  ;; reports it completed.
  (define (count-write! s segments bytes)
    (conn-outstanding-set! s (+ (conn-outstanding s) 1))
    (conn-outstanding-bytes-set! s (+ (conn-outstanding-bytes s) bytes))
    (list 'write segments bytes))

  ;; below-high-water? : ConnState -> Boolean — whether the bytes
  ;; outstanding are at or below the limits' write high water, and fewer
  ;; than `stream-writes-high` writes are, where a producer may be asked for
  ;; a piece.
  (define (below-high-water? s)
    (and (<= (conn-outstanding-bytes s) (limits-write-high-water (conn-limits s)))
         (< (conn-outstanding s) stream-writes-high)))

  ;; stream-writes-high, stream-writes-low : Nat
  ;; The most writes a stream has outstanding, 64, and how few it falls to
  ;; before a producer waiting at 64 is asked again, 16: fixed, not
  ;; settings.  Each piece is a write of its own, and a write holds the loop
  ;; and memory the same whatever its size, which the water marks, counting
  ;; bytes, do not see: with no bound on writes, small pieces let a turn ask
  ;; thousands of times.  At 64 writes, pieces of 4 KiB or more meet the
  ;; byte marks first (64 x 4 KiB is the default high water, 256 KiB), and
  ;; 16 keeps the marks' four to one.
  (define stream-writes-high 64)
  (define stream-writes-low 16)

  ;; end-stream! : ConnState -> Void — let a streamed body's producer go.
  (define (end-stream! s)
    (conn-producer-set! s #f)
    (conn-pieces-set! s #f)
    (conn-asked?-set! s #f))

  ;; forget-input! : ConnState -> Void
  ;; Drop all the connection holds of the input it has read: the pause's
  ;; pending input, the last delivery, the request, and the head and the
  ;; body, whose spans point into the deliveries.  A lingering connection
  ;; reads only to drop what arrives, for up to its linger deadline, so it
  ;; keeps none of them (tests/test-connection-retention.sps).
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

  ;; A tick means the wheel found this connection's armed deadline passed,
  ;; and has let it go: an advance returns its keys already disarmed.  So
  ;; the kind the state records is read, then cleared, and a row that keeps
  ;; the connection arms what it needs.  Every kind the core arms has its
  ;; row:
  ;;   idle past the idle deadline -> closing, with no response;
  ;;   head past the header deadline -> responding 408;
  ;;   body past the body deadline -> responding 408, the request in flight's;
  ;;   responding past the write deadline -> closing, with no response: the
  ;;     client is not reading, so nothing more can be written to it.  The
  ;;     close is logged, with the bytes still outstanding, and names the
  ;;     write deadline, whatever the connection would have closed for after
  ;;     its response.  The write it cuts short is settled in `closing`;
  ;;   lingering past the linger deadline -> closing, for the reason it closes
  ;;     after its response.
  ;; A tick with no deadline of that kind recorded asks for nothing.
  (define (on-tick s)
    (let ((kind (conn-deadline s)))
      (conn-deadline-set! s #f)
      (case (conn-phase s)
        ((idle)
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
  ;; point the adapter calls directly.  A payload of the wrong length is an
  ;; assertion violation, from the entry point's own check or from the call
  ;; itself.
  (define (on-parser-event s name payload)
    (if (eq? name 'on-headers-complete)
        (apply conn-headers-complete-step s payload)
        (apply conn-parser-step s name payload)))

  ;; conn-parser-step : ConnState Symbol Nat -> (values ConnState (Listof Action))
  ;; conn-parser-step : ConnState Symbol Bytevector Nat Nat
  ;;                    -> (values ConnState (Listof Action))
  ;; A parser callback, entered with the callback's own arguments: an event
  ;; callback's name and the parser's position, a span callback's name and
  ;; span.  The first action is always the callback's (reply-parser
  ;; outcome).  A name outside conn-parser-callbacks, on-headers-complete
  ;; (which enters through conn-headers-complete-step), a callback given the
  ;; other kind's arguments, or one given neither, is an assertion violation.
  (define conn-parser-step
    (case-lambda
      ((s name at)
       (check-callback name #f)
       (on-callback s name #f 0 0 at))
      ((s name bv from to)
       (check-callback name #t)
       (on-callback s name bv from to #f))))

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
  ;; once it grows past its limit; in body, the trailer fields are counted
  ;; against the same limits, and the chunk extensions against theirs, and
  ;; none is kept; and a run the parser reads and hands no span of opens at
  ;; the event before it and is judged at the span or event after it, and
  ;; refused past its limit as a limit tripped here is: the empty lines at
  ;; on-message-begin, the request line's spaces at the target's and the
  ;; protocol's first bytes, the whitespace at a value's first bytes, a
  ;; chunk size's digits at its first extension or at on-chunk-header; body,
  ;; on-body-data -> body; body, on-message-complete -> handling, pausing the
  ;; parser in the same step, so one delivery carrying two messages cannot
  ;; start a second handler.  Every other callback, and these outside their
  ;; states, changes nothing and answers continue: the parser always gets an
  ;; answer.
  (define (on-callback s name bv from to at)
    (case name
      ((on-message-begin)
       (case (conn-phase s)
         ((idle)
          (let ((reason (close-judged! s 'lines at)))
            (begin-head! s)
            (if reason
                (let-values (((s actions) (refuse s reason)))
                  (values s (append actions '((disarm-deadline) (arm-deadline header)))))
                (values s '((reply-parser continue) (disarm-deadline) (arm-deadline header))))))
         (else (continue s))))
      ((on-method-complete)
       (case (conn-phase s)
         ((head) (open-run! s 'after-method at) (continue s))
         (else (continue s))))
      ((on-url-data)
       (case (conn-phase s)
         ((head)
          (let ((reason (close-judged! s 'after-method (position s from))))
            (if reason
                (refuse s reason)
                (let ((h (conn-head s)))
                  (add-fragment! h bv from to)
                  (let ((reason (target-past (conn-limits s) (head-size h))))
                    (if reason (refuse s reason) (continue s)))))))
         (else (continue s))))
      ((on-url-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (head-target-set! h (take-piece! h))
            ;; The spaces after the target's one, up to the protocol's first
            ;; bytes.  The parser ends a target at a space, a CRLF or a bare
            ;; LF, and does not say which, so the run opens at each; a request
            ;; line with no version lets it go at its first field or the
            ;; head's end.
            (open-run! s 'after-target at))
          (continue s))
         (else (continue s))))
      ((on-protocol-data)
       (case (conn-phase s)
         ((head)
          (let ((reason (close-judged! s 'after-target (position s from))))
            (if reason (refuse s reason) (continue s))))
         (else (continue s))))
      ((on-header-field-data)
       (case (conn-phase s)
         ((head)
          (when (eq? (conn-run s) 'after-target) (conn-run-set! s #f))
          (header-bytes s bv from to limits-max-header-field-bytes 'header-field-too-large))
         ((body) (trailer-bytes s from to limits-max-header-field-bytes
                                'header-field-too-large))
         (else (continue s))))
      ((on-header-field-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (head-name-set! h (take-piece! h))
            (open-run! s 'whitespace at)
            (field-counted s)))
         ((body)
          (head-size-set! (conn-head s) 0)
          (open-run! s 'whitespace at)
          (field-counted s))
         (else (continue s))))
      ((on-header-value-data)
       (case (conn-phase s)
         ((head)
          (whitespace-counted! s from to)
          (header-bytes s bv from to limits-max-header-value-bytes 'header-value-too-large))
         ((body)
          (whitespace-counted! s from to)
          (trailer-bytes s from to limits-max-header-value-bytes 'header-value-too-large))
         (else (continue s))))
      ((on-header-value-complete)
       (case (conn-phase s)
         ((head)
          (let ((h (conn-head s)))
            (head-fields-set! h (cons (cons (head-name h) (take-piece! h)) (head-fields h)))
            (head-name-set! h #f)
            (head-pad-set! h 0)
            (continue s)))
         ((body)
          (head-size-set! (conn-head s) 0)
          (head-pad-set! (conn-head s) 0)
          (continue s))
         (else (continue s))))
      ((on-chunk-extension-name-data on-chunk-extension-value-data)
       (case (conn-phase s)
         ((body)
          (let ((reason (and (eq? name 'on-chunk-extension-name-data)
                             (close-judged! s 'digits (- (position s from) 1)))))
            (if reason (refuse s reason) (extension-bytes s from to))))
         (else (continue s))))
      ;; An extension's name stands for the `;` before it, and its value for
      ;; the `=`: each counts a byte as it ends, so by its line's end every
      ;; byte of a chunk's extensions has counted, an empty one's too.
      ((on-chunk-extension-name-complete on-chunk-extension-value-complete)
       (case (conn-phase s)
         ((body) (extension-bytes s 0 1))
         (else (continue s))))
      ((on-chunk-header)
       (case (conn-phase s)
         ((body)
          (let ((reason (close-judged! s 'digits (- at 2))))
            (if reason (refuse s reason) (continue s))))
         (else (continue s))))
      ((on-chunk-complete)
       (case (conn-phase s)
         ((body) (open-run! s 'digits at) (continue s))
         (else (continue s))))
      ((on-body-data)
       (case (conn-phase s)
         ((body) (body-piece s bv from to))
         (else (continue s))))
      ((on-message-complete)
       (case (conn-phase s)
         ((body)
          (let ((bd (conn-body s)))
            (open-run! s 'lines at)
            (conn-phase-set! s 'handling)
            (conn-deadline-set! s #f)
            (body-complete?-set! bd #t)
            (case (body-answer bd)
              ((#f)
               (body-answer-set! bd 'asked)
               (values s (list '(reply-parser pause) '(disarm-deadline)
                               (list 'call-handler (conn-request s)))))
              ((stream)
               (body-answer-set! bd 'ending)
               (values s '((reply-parser pause) (disarm-deadline) (deliver-body-end))))
              ((whole)
               (let-values (((s handed) (hand-over-whole s)))
                 (values s (cons* '(reply-parser pause) '(disarm-deadline) handed))))
              (else (values s '((reply-parser pause) (disarm-deadline)))))))
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
  ;; for the answer while it has not come.  With no answer to come, it is
  ;; dropped.
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
         (owe! bd (fx- to from))
         (values s (cons (car answer) (cons (list 'deliver-body bv from to) (cdr answer)))))
        ((whole)
         (buffer-add! bd bv from to)
         (values s answer))
        ((call asked)
         (body-held-set! bd (cons (list 'deliver-body bv from to) (body-held bd)))
         (values s answer))
        (else (values s answer)))))

  ;; owe! : BodyState Nat -> Void
  ;; `n` more bytes handed to the reader: owed its credit, if the shell hands
  ;; it its pieces on credit.
  (define (owe! bd n)
    (when (body-credit? bd)
      (body-owed-set! bd (fx+ (body-owed bd) n))))

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
    (add-fragment! (conn-head s) bv from to)
    (field-bytes s (fx- to from) piece-limit piece-reason))

  ;; trailer-bytes : ConnState Nat Nat (Limits -> Nat) Symbol
  ;;                 -> (values ConnState (Listof Action))
  ;; A fragment of a trailer field's name or value: counted, not kept, and
  ;; the message refused as a head's is.
  (define (trailer-bytes s from to piece-limit piece-reason)
    (let ((h (conn-head s)))
      (head-size-set! h (fx+ (head-size h) (fx- to from)))
      (field-bytes s (fx- to from) piece-limit piece-reason)))

  ;; field-bytes : ConnState Nat (Limits -> Nat) Symbol
  ;;               -> (values ConnState (Listof Action))
  ;; `n` more bytes of the name or value being read, whose size the head
  ;; holds already, added to the section's: the message is refused once the
  ;; name or value, a value with the whitespace before it, or the section,
  ;; is past its limit, for the limit its bytes passed first (`first-past`).
  (define (field-bytes s n piece-limit piece-reason)
    (let ((h (conn-head s)) (limits (conn-limits s)))
      (head-total-set! h (fx+ (head-total h) n))
      (let ((reason (first-past (fx+ (head-size h) (head-pad h)) (piece-limit limits) piece-reason
                                (head-total h) (limits-max-header-bytes limits))))
        (if reason (refuse s reason) (continue s)))))

  ;; first-past : Integer Nat Symbol Integer Nat -> (U #f Symbol)
  ;; Bytes just counted to a piece, a name, or a value with the whitespace
  ;; before it, and to the section, the two counts now `piece` and `total`:
  ;; the reason for the limit they passed first, if they passed one.  Each
  ;; of the bytes added one to both counts, so the count further past its
  ;; limit passed it at an earlier byte; past both at the same byte, the
  ;; piece's.  The reason is the first byte's to pass a limit, whatever the
  ;; split into reads.
  (define (first-past piece piece-max piece-reason total total-max)
    (let ((over (- piece piece-max)) (section-over (- total total-max)))
      (cond ((and (> over 0) (>= over section-over)) piece-reason)
            ((> section-over 0) 'headers-too-large)
            (else #f))))

  ;; field-counted : ConnState -> (values ConnState (Listof Action))
  ;; One more field name complete, a head's or a trailer's: counted, and the
  ;; message refused once the fields are more than max-header-count.
  (define (field-counted s)
    (let ((h (conn-head s)))
      (head-count-set! h (fx+ (head-count h) 1))
      (if (fx>? (head-count h) (limits-max-header-count (conn-limits s)))
          (refuse s 'too-many-headers)
          (continue s))))

  ;; extension-bytes : ConnState Nat Nat -> (values ConnState (Listof Action))
  ;; A fragment of a chunk extension's name or value: counted with all the
  ;; body's others, and the message refused as
  ;; 'chunk-extensions-too-large once they come to more than
  ;; `max-chunk-extension-bytes`.
  (define (extension-bytes s from to)
    (let* ((bd (conn-body s)) (n (fx+ (body-extensions bd) (fx- to from))))
      (body-extensions-set! bd n)
      (if (fx>? n max-chunk-extension-bytes)
          (refuse s 'chunk-extensions-too-large)
          (continue s))))

  ;; max-chunk-extension-bytes : Nat
  ;; The most bytes a body's chunk extensions, their names and values, may
  ;; come to together: 16 KiB, fixed, not a setting.  hyper holds a body's
  ;; to 16 KiB, as RFC 9112 §7.1.1 advises a total for a request; Node holds
  ;; each chunk's to 16 KiB, since CVE-2024-22019, whose server read a
  ;; chunk's extensions without limit.  The server keeps no extension, so
  ;; the bound is on the work, not on memory.
  (define max-chunk-extension-bytes 16384)

  ;; max-empty-line-bytes : Nat
  ;; The most bytes of empty lines skipped before a request line: two lines'
  ;; CRLFs.  RFC 9112 §2.2 asks a server to ignore at least one; llhttp's
  ;; own fixture has a POST's body followed by two, and Go forgives 4 bytes
  ;; of them after a POST.  Four bare LFs come to as much, and pass too.
  (define max-empty-line-bytes 4)

  ;; max-size-digits : Nat
  ;; The most hex digits a chunk size may have, leading zeros included, as
  ;; Go and h2o hold it: a 64-bit size's, and a 17th significant digit is
  ;; the parser's overflow.
  (define max-size-digits 16)

  ;; run-limits : (Listof (List Symbol Nat Symbol Symbol Nat))
  ;; The runs but the whitespace, each with its limit, in one place: the
  ;; most bytes the run may have; the reason it is refused for past them,
  ;; answered 400; the phase it is read in; and how many bytes past them a
  ;; read may end without a refusal, ones that may end the run and that the
  ;; parser reads with no callback: a chunk size's `;` or CR, a request
  ;; line's CR where it has no version.  The whitespace before a value is
  ;; held to the value's and the section's limits (`whitespace-past-limit`).
  (define run-limits
    `((lines ,max-empty-line-bytes empty-lines idle 0)
      (after-method 1 request-line-spaces head 0)
      (after-target 0 request-line-spaces head 1)
      (digits ,max-size-digits chunk-size-too-long body 1)))

  ;; run-refusal : Symbol (U #f Integer) Nat -> (U #f Symbol)
  ;; The reason to refuse a run of `kind` of `n` bytes, `slack` of them
  ;; perhaps not the run's own; #f within its limit, or when `n` is #f.
  (define (run-refusal kind n slack)
    (let ((limit (assq kind run-limits)))
      (and n (> n (+ (cadr limit) slack)) (caddr limit))))

  ;; open-run! : ConnState Symbol Nat -> Void
  ;; A run of bytes the parser reads and hands no span of begins at the
  ;; parser's position `at`: `lines`, the empty lines before a request line;
  ;; `after-method` and `after-target`, the spaces after the method and
  ;; after the target's one; `whitespace`, before a field's value; `digits`,
  ;; a chunk size's.  One is open at a time, and opening one lets the last
  ;; go.
  (define (open-run! s kind at)
    (conn-mark-set! s at)
    (conn-run-set! s kind))

  ;; close-run! : ConnState Symbol Nat -> (U #f Integer)
  ;; The bytes of the run of `kind` that ends at the parser's position `end`,
  ;; the run closed; #f when no such run is open, as for a span's later
  ;; fragments.
  (define (close-run! s kind end)
    (and (eq? (conn-run s) kind)
         (begin (conn-run-set! s #f) (- end (conn-mark s)))))

  ;; close-judged! : ConnState Symbol Nat -> (U #f Symbol)
  ;; Close the run of `kind` that ends at the parser's position `end`, if it
  ;; is open, and answer the reason to refuse it if it is past its limit.
  (define (close-judged! s kind end)
    (run-refusal kind (close-run! s kind end) 0))

  ;; position : ConnState Nat -> Nat
  ;; The parser's position of index `i` of the delivery being fed: a span's
  ;; bounds index the delivery, and the parser read to its start before it.
  (define (position s i) (+ (conn-base s) i))

  ;; whitespace-counted! : ConnState Nat Nat -> Void
  ;; A value's first bytes, bv[from, to) of the delivery: the whitespace
  ;; since its name's colon, the run they end, counted with the value, as
  ;; its `pad`, and with the section.  An empty value is handed over after
  ;; its line end, which the run holds too and is not counted.
  (define (whitespace-counted! s from to)
    (let ((n (close-run! s 'whitespace (position s from))))
      (when n
        (let ((h (conn-head s)) (pad (if (fx=? from to) (- n line-end-bytes) n)))
          (head-pad-set! h pad)
          (head-total-set! h (+ (head-total h) pad))))))

  ;; line-end-bytes : Nat
  ;; An empty value's line end: CRLF, the only one the strict parser takes
  ;; (llhttp's header_value_discard_ws and its _almost_done), which hands
  ;; the value over at the byte after it.  At a read's end the whitespace
  ;; run may hold as much of it, so it is judged on its length less this.
  ;; Where the parser ends an empty value at a byte it then refuses, the
  ;; whitespace is counted less this too, below 0 if it is shorter, and the
  ;; parser's error, which comes next, answers it with 400.
  (define line-end-bytes 2)

  ;; begin-head! : ConnState -> Void
  ;; idle -> head, for a request line's first byte: a fresh head and body,
  ;; no request, the header deadline recorded.
  (define (begin-head! s)
    (head-roll! (conn-head s))
    (body-roll! (conn-body s))
    (conn-request-set! s #f)
    (conn-phase-set! s 'head)
    (conn-deadline-set! s 'header))

  ;; run-past-limit : ConnState -> (U #f Symbol)
  ;; At a read's end, and at the parser's error where it cut off no target
  ;; or name (`cut-off-past-limit`), the reason to refuse the run still
  ;; open, if it is past its limit in the phase it is read in: its bytes run
  ;; from its start to the parser's position, or to the byte it refused, less
  ;; the ones a read may end on (`run-limits`; the whitespace, an empty
  ;; value's line end).
  (define (run-past-limit s)
    (let ((run (conn-run s)) (phase (conn-phase s)))
      (and run
           (let ((n (- (conn-parsed s) (conn-mark s))))
             (if (eq? run 'whitespace)
                 (and (memq phase '(head body)) (whitespace-past-limit s (- n line-end-bytes)))
                 (let ((limit (assq run run-limits)))
                   (and (eq? phase (cadddr limit))
                        (run-refusal run n (car (cddddr limit))))))))))

  ;; whitespace-past-limit : ConnState Integer -> (U #f Symbol)
  ;; `n` bytes of whitespace before a value, past the value's limit or,
  ;; with the section's bytes so far, the section's: the reason for the one
  ;; they passed first (`first-past`).
  (define (whitespace-past-limit s n)
    (let ((limits (conn-limits s)))
      (first-past n (limits-max-header-value-bytes limits) 'header-value-too-large
                  (+ (head-total (conn-head s)) n) (limits-max-header-bytes limits))))

  ;; refuse : ConnState Symbol -> (values ConnState (Listof Action))
  ;; A limit tripped inside a parser callback: tell the parser to fail with
  ;; the reason as its code, and hold the reason for the parser's error
  ;; result, which is answered with the reason's status.  The state stays
  ;; where it is until that result arrives.
  (define (refuse s reason)
    (head-refusal-set! (conn-head s) reason)
    (values s (list (list 'reply-parser (list 'fail reason)))))

  ;; conn-headers-complete-step :
  ;;   ConnState Nat Nat Nat Nat Nat Nat Nat -> (values ConnState (Listof Action))
  ;;   method http-major http-minor flags content-length upgrade at
  ;; on-headers-complete, entered with the six parser fields the adapter reads
  ;; inside the callback: llhttp's method number, the version, llhttp's flag
  ;; bits, the content-length, and `upgrade`, 1 when the message upgrades
  ;; (chez-httparse v0.4.1 or later documents it as llhttp's
  ;; `llhttp_get_upgrade`); and the parser's position, as every event
  ;; callback's.  Read there, content-length is the declared length, since
  ;; it counts down as the body arrives, and the parser's reset after each
  ;; message zeroes it and the flags; `upgrade` is not reset, and is this
  ;; message's only from on-headers-complete on.  Nothing downstream
  ;; re-reads the parser.  The flags and the content-length say whether a
  ;; body follows: one chunked, or with a Content-Length above 0.
  ;; The version is judged here first: one that is not 1.x, HTTP/0.9, 2.0 or
  ;; 3.0 say, is refused as 'version-not-supported, answered 505, and a 1.x
  ;; past 1.1 goes on as HTTP/1.1 (RFC 9110 §6.2).  Then the Host lines (RFC
  ;; 9112 §3.2; see (http-server host)): a request whose Host is missing on
  ;; HTTP/1.1 (when the limits require one), doubled or invalid is refused
  ;; as 'invalid-host, answered 400.  Then the framing: a request below
  ;; HTTP/1.1 with Transfer-Encoding is refused as 'faulty-framing, answered
  ;; 400 (see (http-server transfer-coding)).  Then the target, where the
  ;; method is known (see (http-server target)).  One that is not the form
  ;; its method calls for, or whose bytes uriparse refuses, is refused, and
  ;; the state stays in head until the parser's error arrives:
  ;;   - as 'target-redirect, answered 301 with a Location, when it is the
  ;;     narrow case the server redirects: bracket params and pipes in a
  ;;     GET or HEAD, encoded to a target within max-target-bytes;
  ;;   - as 'invalid-target, answered 400, otherwise.
  ;; Then the transfer codings (see (http-server transfer-coding)): when the
  ;; parser frames the body by a final chunked, another coding beside it is
  ;; refused as 'unsupported-transfer-coding, answered 501.
  ;; A request accepted on all five moves head -> body: the request is built
  ;; from the head, holding whether a body follows, and the header deadline
  ;; gives way to the body's.  The connection is marked to close after the
  ;; response unless the message keeps it alive, or, when it does, if the
  ;; parser says it upgrades.  A
  ;; body it announces is noted, for the handler to be asked once the feed
  ;; has returned, and a declared length past the limits' max-body-bytes is
  ;; refused as 'body-too-large, answered 413, before any of the body is
  ;; met.  So is whether its client waits for `100 Continue`, an HTTP/1.1
  ;; request whose Expect lists 100-continue: then no body deadline is armed
  ;; until the 100 is written.  The head's sizes start again for the
  ;; trailers.  A chunked body's first size line begins where the head ends,
  ;; its digits to be counted.
  (define (conn-headers-complete-step s method http-major http-minor flags content-length upgrade
                                      at)
    (case (conn-phase s)
      ((head)
       (let* ((h (conn-head s))
              (name (method-name method))
              (target (or (head-target h) empty-span)))
         (cond
          ((not (fx=? http-major 1)) (refuse s 'version-not-supported))
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
           (let* ((chunked? (not (fxzero? (fxand flags F-CHUNKED))))
                  (declared (and (not chunked?) content-length))
                  (framed? (or chunked? (> content-length 0)))
                  (bd (conn-body s)))
             (conn-request-set! s (make-request name target http-major http-minor
                                                (reverse (head-fields h)) framed?))
             (cond ((not (should-keep-alive? http-major http-minor 'request 0 flags))
                    (conn-close-after-set! s 'not-keep-alive))
                   ((eqv? upgrade 1)
                    (conn-close-after-set! s 'upgrade)))
             (body-roll! bd)
             (body-framed?-set! bd framed?)
             (body-declared-set! bd declared)
             (cond
              ((and framed? (over? (limits-max-body-bytes (conn-limits s)) declared))
               (refuse s 'body-too-large))
              (else
               (when framed? (body-answer-set! bd 'call))
               (head-count-set! h 0)
               (head-total-set! h 0)
               (conn-phase-set! s 'body)
               (if chunked? (open-run! s 'digits at) (conn-run-set! s #f))
               (cond
                ((and framed? (http/1.1? http-major http-minor)
                      (field-lists? (head-fields h) expect-name continue-token))
                 (body-continue?-set! bd #t)
                 (conn-deadline-set! s #f)
                 (values s '((reply-parser continue) (disarm-deadline))))
                (else
                 (conn-deadline-set! s 'body)
                 (values s '((reply-parser continue) (disarm-deadline) (arm-deadline body))))))))))))
      (else (continue s))))

  ;; The Expect field's name, and the one expectation the server meets
  ;; (RFC 9110 §10.1.1).
  (define expect-name (string->utf8 "expect"))
  (define continue-token (string->utf8 "100-continue"))

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
  ;; asked now: `ask-handler`.  If that feed went on into the body and met
  ;; an error there, or passed a cap, the error waits for the handler's
  ;; answer, in handling, reading stopped: it is answered after the pieces
  ;; met before it if the handler answers with a reader,
  ;; and not at all if it answers with a response, as it would had the body
  ;; come in a later read.
  ;; head/body: a hand-off, on either of the parser's channels
  ;; (`result-hands-off-stream?`).  The HTTP/2 preface, on the error
  ;; channel, is answered 505, then close.  A pause for an upgrade never
  ;; comes, since the core pauses the parser at every message's end and
  ;; never resumes it onto an upgrade: the door is a switch's, at its 101's
  ;; completion (switch-with), and a pause for one here is the shell's bug,
  ;; an assertion violation.  Any other error is answered with a status,
  ;; then close: one the core asked for with `fail` gets its reason's
  ;; status, and any other the status (http-server decisions) gives its
  ;; code.
  ;; handling: the core's own answer to on-message-complete paused the
  ;; parser, a pause with no reason, so the rest of the last delivery, from
  ;; `next`, is kept as the pending input the resume feeds.  Any other
  ;; result there is not answered, llhttp's "Data after `Connection: close`"
  ;; included.
  ;; idle, head or body: first, the parser's own count of the bytes it has
  ;; taken is kept, and a run it reads and hands no span of, still open and
  ;; past its limit, is refused as a callback's refusal is
  ;; (`run-past-limit`).  At the parser's own error, with no refusal of the
  ;; core's held, whose callback came first, the offset is the refused
  ;; byte's, and what the error cut off is judged first: a target's or a
  ;; name's bytes it withheld, then the run (`cut-off-past-limit`).  The
  ;; result is read whole first: one short of its fields is refused.
  (define (on-parser-result s ev)
    (let* ((status (cadr ev)) (more (cddr ev)) (offset (car more))
           (next (cadr more)) (code (caddr more)) (abandoned (cadddr more)))
      (conn-parsed-set! s offset)
      (let ((reason (if (eq? status 'error)
                        (and (not (head-refusal (conn-head s)))
                             (cut-off-past-limit s abandoned offset))
                        (run-past-limit s))))
        (if reason
            (refuse-run s reason)
            (read-result s status next (and (eq? status 'error) code)
                         (and (eq? status 'paused) code))))))

  ;; cut-off-past-limit : ConnState (U #f (Pair Symbol Nat)) Nat -> (U #f Symbol)
  ;; At the parser's own error, at `end`, the refused byte's position: the
  ;; reason to refuse what the error cut off, as a read's end would have
  ;; refused it.  `abandoned` is the span the error abandoned and where its
  ;; withheld bytes begin, as the error records them.  A target's or a field
  ;; name's withheld bytes run from there to `end`, after the ones a read's
  ;; end handed on.  A target that began in the read that failed handed on
  ;; none, and the spaces before it are judged first, as its first bytes
  ;; would have judged them (`close-judged!`).  The limit passed first names
  ;; the reason: the spaces', the target's, or a name's or the section's
  ;; (`first-past`).  With no such span cut off, the run still open is
  ;; judged (`run-past-limit`).
  (define (cut-off-past-limit s abandoned end)
    (let ((h (conn-head s)) (limits (conn-limits s)))
      (case (and abandoned (car abandoned))
        ((url-span)
         (let ((from (cdr abandoned)))
           (or (close-judged! s 'after-method from)
               (target-past limits (+ (head-size h) (- end from))))))
        ((header-field-span)
         (let ((n (- end (cdr abandoned))))
           (first-past (+ (head-size h) n) (limits-max-header-field-bytes limits)
                       'header-field-too-large
                       (+ (head-total h) n) (limits-max-header-bytes limits))))
        (else (run-past-limit s)))))

  ;; target-past : Limits Integer -> (U #f Symbol)
  ;; 'target-too-large for a target of `n` bytes, past the limits'
  ;; max-target-bytes; #f within it.
  (define (target-past limits n)
    (and (> n (limits-max-target-bytes limits)) 'target-too-large))

  ;; refuse-run : ConnState Symbol -> (values ConnState (Listof Action))
  ;; A run past its limit at a read's end, or what the parser's error cut
  ;; off, closed and refused for `reason`: from idle, the empty lines, as
  ;; their request line's first byte would be, in head.
  (define (refuse-run s reason)
    (conn-run-set! s #f)
    (when (eq? (conn-phase s) 'idle) (begin-head! s))
    (head-refusal-set! (conn-head s) reason)
    (answer-refusal s #f))

  ;; read-result : ConnState Symbol Nat (U #f Symbol) (U #f Symbol)
  ;;               -> (values ConnState (Listof Action))
  ;; A parser-result's status, where to resume, and its error's and pause's
  ;; codes, the parser's count kept: the rows above.
  ;; After the client's end, the input held is all there is, so a read that
  ;; ends wanting more closes, as the end itself does in idle, head or body.
  (define (read-result s status next err pause)
    (case (conn-phase s)
      ((handling)
       (when (and (eq? status 'paused) (not pause) (conn-delivery s))
         (conn-pending-set! s (rest-of (conn-delivery s) next)))
       (ask-handler s))
      ((idle) (if (and (conn-ended? s) (eq? status 'need-input)) (close s 'eof '()) (values s '())))
      ((head body)
       (cond
        ((result-hands-off-stream? status err pause)
         (if (eq? status 'error)
             (respond-and-close s 'http2-preface '())
             (assertion-violation 'conn-step
               "a hand-off the core never asks for: it pauses the parser at every message's end"
               pause)))
        ((and (conn-ended? s) (eq? status 'need-input)) (close s 'eof '()))
        ((not (eq? status 'error))
         (if (fxzero? (body-owed (conn-body s))) (ask-handler s) (await-credit s)))
        (else (answer-refusal s err))))
      (else (values s '()))))

  ;; answer-refusal : ConnState (U #f Symbol) -> (values ConnState (Listof Action))
  ;; A read that ended in the parser's error, `err` its code, or in a
  ;; refusal of the core's, whose reason the head holds.  When the feed
  ;; that completed a head announcing a body met it, it waits for the
  ;; handler's answer, in handling, reading stopped; otherwise it is
  ;; answered with the refusal's status, or the error's, then close.
  (define (answer-refusal s err)
    (cond
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
      (respond s (parser-error-status err) 'parser-error '()))))

  ;; await-credit : ConnState -> (values ConnState (Listof Action))
  ;; body -> awaiting-credit: the reader has been handed pieces it has not
  ;; credited, so reading stops, and the body deadline with it, since the
  ;; server is the one waiting.
  ;; handling -> awaiting-credit: the same, with reading stopped and
  ;; nothing armed already, as the request waited on its handler.
  (define (await-credit s)
    (let ((handling? (eq? (conn-phase s) 'handling)))
      (conn-phase-set! s 'awaiting-credit)
      (conn-deadline-set! s #f)
      (values s (if handling? '() '((read-stop) (disarm-deadline))))))

  ;; ask-handler : ConnState -> (values ConnState (Listof Action))
  ;; `(call-handler request)`, once, for a request whose head announced a
  ;; body; nothing otherwise.  The answer comes after the drain that asks
  ;; for it, so a request whose body is still arriving waits on its handler
  ;; in handling: reading stops, and the body deadline with it, until the
  ;; answer, since the server is the one waiting.  One whose body has ended
  ;; is in handling already.
  (define (ask-handler s)
    (let ((bd (conn-body s)))
      (cond
       ((not (eq? (body-answer bd) 'call)) (values s '()))
       ((eq? (conn-phase s) 'body)
        (body-answer-set! bd 'asked)
        (conn-phase-set! s 'handling)
        (conn-deadline-set! s #f)
        (values s (list '(read-stop) '(disarm-deadline) (list 'call-handler (conn-request s)))))
       (else
        (body-answer-set! bd 'asked)
        (values s (list (list 'call-handler (conn-request s))))))))

  ;; read-on : ConnState (Listof Action) -> (values ConnState (Listof Action))
  ;; `actions`, and then, for a request that waited on its handler in
  ;; handling with its body still to come, reading again: back in body,
  ;; reading started and the body deadline armed.
  (define (read-on s actions)
    (cond
     ((eq? (conn-phase s) 'handling)
      (conn-phase-set! s 'body)
      (conn-deadline-set! s 'body)
      (values s (append actions '((read-start) (arm-deadline body)))))
     (else (values s actions))))

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
  ;; response.  After the answer comes `credit`, when the shell hands a
  ;; streaming reader its pieces on credit, or nothing; anything else is an
  ;; assertion violation.
  ;;   - Asked, a reader: `accept-reader`.
  ;;   - Asked about a request whose head announced a body, a response: sent
  ;;     at once, and the connection closes after it, as 'unread-body, unless
  ;;     it closes already for a reason of its own; the body is not read,
  ;;     and an error kept for the answer is not answered.
  ;;   - Asked about a request with no body, or the reader's response: the
  ;;     response, `respond-with`.
  ;; An answer the core did not ask for changes nothing.
  (define (on-handler-responded s answer rest)
    (unless (or (null? rest) (equal? rest '(credit)))
      (assertion-violation 'conn-step "after the answer, credit or nothing" rest))
    (case (conn-phase s)
      ((body handling)
       (let ((bd (conn-body s)))
         (case (body-answer bd)
           ((asked)
            (cond ((body-reader? answer) (accept-reader s answer (pair? rest)))
                  ((switch? answer) (switch-with s answer))
                  ((body-framed? bd)
                   (unless (conn-close-after s) (conn-close-after-set! s 'unread-body))
                   (respond-with s answer))
                  (else (respond-with s answer))))
           ((ending) (if (switch? answer) (switch-with s answer) (respond-with s answer)))
           (else (values s '())))))
      (else (values s '()))))

  ;; accept-reader : ConnState BodyReader Boolean -> (values ConnState (Listof Action))
  ;; A reader, answered for the request being read, and whether the shell
  ;; hands it its pieces on credit.  A declared length past the reader's cap
  ;; is answered 413 at once, then close: the head says so, so a client that
  ;; waits for `100 Continue` is sent none.  Otherwise the reader reads
  ;; (`read-with`), and a client that waits for the 100 is sent it first,
  ;; whatever reading brings, a 413 for a body met past the cap
  ;; among it, since the 100 would have gone first had that body come later:
  ;; the body deadline is armed after it, as reading starts again, and does
  ;; not wait for the reader's credit.
  (define (accept-reader s r credit?)
    (let ((bd (conn-body s)))
      (cond
       ((over? (body-reader-max-bytes r) (body-declared bd))
        (respond-and-close s 'body-too-large '()))
       ((body-continue? bd)
        (body-continue?-set! bd #f)
        (let ((w (let-values (((segments bytes) (serialize-continue)))
                   (count-write! s segments bytes))))
          (let-values (((s actions) (read-with s r credit?)))
            (values s (cons w actions)))))
       (else (read-with s r credit?)))))

  ;; read-with : ConnState BodyReader Boolean -> (values ConnState (Listof Action))
  ;; The reader accepted reads.  A body met so far past its cap is answered
  ;; 413 at once, then close.  Otherwise the pieces kept for it are handed
  ;; over now, as `deliver-body` to a streaming one and into its buffer for
  ;; a whole one; then an error kept for the answer is answered, or once the
  ;; message has ended, the reader is handed its end, or a streaming reader
  ;; on credit owes for those pieces, and reading waits for its credit, or
  ;; else reading starts again for the rest of the body (`read-on`).
  (define (read-with s r credit?)
    (let ((bd (conn-body s)))
      (if (over? (body-reader-max-bytes r) (body-count bd))
          (respond-and-close s 'body-too-large '())
          (let ((held (reverse (body-held bd))) (error (body-error bd)))
            (body-held-set! bd '())
            (body-reader-set! bd r)
            (body-credit?-set! bd credit?)
            (cond
             ((and error (body-reader-whole? r)) (answer-error s error))
             (error
              (let-values (((s answered) (answer-error s error)))
                (values s (append held answered))))
             ((body-reader-whole? r)
              (body-answer-set! bd 'whole)
              (buffer-start! bd)
              (for-each (lambda (a) (buffer-add! bd (cadr a) (caddr a) (cadddr a)))
                        held)
              (if (body-complete? bd) (hand-over-whole s) (read-on s '())))
             ((body-complete? bd)
              (body-answer-set! bd 'ending)
              (values s (append held '((deliver-body-end)))))
             (else
              (body-answer-set! bd 'stream)
              (for-each (lambda (a) (owe! bd (fx- (cadddr a) (caddr a)))) held)
              (if (fxzero? (body-owed bd))
                  (read-on s held)
                  (let-values (((s waiting) (await-credit s)))
                    (values s (append held waiting))))))))))

  ;; respond-with : ConnState Response -> (values ConnState (Listof Action))
  ;; -> responding: write the response, arm the write deadline, and let the
  ;; body go.  From body, reading stops with the write, since `responding`
  ;; does not read.  A response with a fault is answered 500 instead, then
  ;; close, the log naming the fault.  A handler's `Connection: close`
  ;; closes the connection after its response, unless it closes already for
  ;; a reason of its own.  A producer's body is written a piece at a time
  ;; after its head: the producer is asked for its first piece once the
  ;; head is written, if the head leaves the bytes outstanding at or below
  ;; the high water (below-high-water?), and waits otherwise.
  (define (respond-with s response)
    (cond
     ((response-fault response) => (lambda (fault) (refuse-answer s fault)))
     (else
      (when (and (not (conn-close-after s)) (response-closes? response))
        (conn-close-after-set! s 'handler-close))
      (let ((reading? (eq? (conn-phase s) 'body)))
        (conn-phase-set! s 'responding)
        (conn-deadline-set! s 'write)
        (body-roll! (conn-body s))
        (let* ((w (write-action s response serialize-checked-response))
               (head (if reading?
                         (list w '(read-stop) '(arm-deadline write))
                         (list w '(arm-deadline write)))))
          (cond ((not (conn-producer s)) (values s head))
                ((below-high-water? s)
                 (conn-asked?-set! s #t)
                 (values s (append head '((notify-producer)))))
                (else (values s head))))))))

  ;; refuse-answer : ConnState Symbol -> (values ConnState (Listof Action))
  ;; An answer the server cannot write safely, for `fault`: 500 instead, then
  ;; close, logged `invalid-response` with the fault.
  (define (refuse-answer s fault)
    (let-values (((s actions) (respond-and-close s 'invalid-response '())))
      (values s (cons (list 'log 'invalid-response fault) actions))))

  ;; switch-with : ConnState Switch -> (values ConnState (Listof Action))
  ;; handling, a switch: through the door, if it is open (door-open?) and
  ;; the switch has no fault, -> responding: the 101's write, the write
  ;; deadline armed, the take-over kept for the hand-off once the 101 is
  ;; written (response-written).  Otherwise 500, for `not-an-upgrade` or
  ;; the switch's fault (refuse-answer).
  (define (switch-with s sw)
    (cond
     ((not (door-open? s)) (refuse-answer s 'not-an-upgrade))
     ((switch-fault sw (request-headers (conn-request s))) => (lambda (fault) (refuse-answer s fault)))
     (else
      (conn-taker-set! s (switch-take-over sw))
      (conn-phase-set! s 'responding)
      (conn-deadline-set! s 'write)
      (body-roll! (conn-body s))
      (let-values (((segments bytes) (switch-segments s sw)))
        (values s (list (count-write! s segments bytes) '(arm-deadline write)))))))

  ;; switch-segments : ConnState Switch -> (values (Listof Segment) Nat)
  ;; The 101's one write, the `100 Continue` before it when the request's
  ;; Expect lists 100-continue: RFC 9110 §7.8 says a server that receives
  ;; Upgrade and that expectation MUST send the 100 before the 101, and the
  ;; door's request has no body, so no 100 was sent for one.
  (define (switch-segments s sw)
    (let-values (((segments bytes) (serialize-switch sw)))
      (if (field-lists? (request-headers (conn-request s)) expect-name continue-token)
          (let-values (((continuing continued) (serialize-continue)))
            (values (append continuing segments) (fx+ continued bytes)))
          (values segments bytes))))

  ;; door-open? : ConnState -> Boolean
  ;; Whether the request being answered may be taken: one the parser marks
  ;; as an upgrade and that keeps the connection, its close-after
  ;; `upgrade`, HTTP/1.1 (RFC 9110 §7.8: a server MUST ignore an HTTP/1.0
  ;; request's Upgrade, and §15.2: send it no 1xx), no CONNECT, which
  ;; llhttp's rule upgrades whatever its fields say, and with no body
  ;; (h2o's rule; RFC 6455 §4.1's handshake is a GET).
  (define (door-open? s)
    (let ((r (conn-request s)))
      (and r
           (eq? (conn-close-after s) 'upgrade)
           (http/1.1? (request-http-major r) (request-http-minor r))
           (not (eq? (request-method r) 'CONNECT))
           (not (body-framed? (conn-body s))))))

  ;; write-action : ConnState Response Serializer -> Action
  ;;   Serializer = serialize-response, or serialize-checked-response for a
  ;;                handler's response the core has found no fault in, so
  ;;                that its fields are not read for faults twice
  ;; `(write segments nbytes)`: the response as the segments of one write,
  ;; framed for the request being answered, and saying `close` when the
  ;; connection closes after it (http-server decisions).  A close-delimited
  ;; body ends only with the connection (RFC 9112 §6.3 rule 8), so it closes
  ;; the connection after the response when nothing else does; the decision
  ;; gives that mode only to a body of unknown length.  A response the core
  ;; originates before a request is built answers none: it has no body and
  ;; always closes, so the version, which only a body of unknown length or
  ;; a connection that stays would read, is taken as 1.1.  The write is
  ;; outstanding, with its bytes, until the shell reports it completed.  A
  ;; producer's body is of unknown length: where its framing writes a body,
  ;; chunked or close-delimited, the state keeps the producer and the
  ;; framing for its pieces; where none is written, the producer is never
  ;; called.
  (define (write-action s r serialize)
    (let* ((req (conn-request s))
           (major (if req (request-http-major req) 1))
           (minor (if req (request-http-minor req) 1))
           (body (response-body r))
           (mode (response-framing (and req (request-method req)) major minor
                                   (response-status r)
                                   (cond ((bytevector? body) (bytevector-length body))
                                         ((procedure? body) 'unknown)
                                         (else #f)))))
      (when (and (eq? mode 'close-delimited) (not (conn-close-after s)))
        (conn-close-after-set! s 'close-delimited))
      (when (and (procedure? body) (memq mode '(chunked close-delimited)))
        (conn-producer-set! s body)
        (conn-pieces-set! s mode))
      (let-values (((segments bytes)
                    (serialize r mode (response-connection (and (conn-close-after s) #t)
                                                           major minor))))
        (count-write! s segments bytes))))

  ;; handling or body, handler-failed -> responding 500, then close: the
  ;; handler raised, or its reader did, whether the body was still being read
  ;; or had ended.  The reader is let go at once, so a piece already asked
  ;; for never reaches a reader that raised.
  ;; responding, handler-failed with a piece asked for -> closing: the
  ;; producer raised, or answered what is not a piece, once the head was on
  ;; the wire, so no status can be written: a bare close, at once.  A
  ;; failure in responding with no piece asked for, a reader's raise after
  ;; the core refused its request, changes nothing.
  (define (on-handler-failed s raised)
    (case (conn-phase s)
      ((handling body awaiting-credit)
       (body-roll! (conn-body s))
       (if (closed-quietly? s raised)
           (close s 'client-closed '())
           (respond-and-close s 'handler-failed '())))
      ((responding)
       (if (conn-asked? s)
           (close s (if (closed-quietly? s raised) 'client-closed 'handler-failed) '())
           (values s '())))
      (else (values s '()))))

  ;; closed-quietly? : ConnState Any -> Boolean
  ;; The request's code let the close's raise out once its client had
  ;; closed: it is answered nothing.  Raised before, it is
  ;; a failure like any other.
  (define (closed-quietly? s raised)
    (and (eq? (conn-close-after s) 'client-closed) (client-closed? raised)))

  ;; body-credit n: the reader on credit has taken `n` more bytes of what it
  ;; was handed.
  ;;   - awaiting-credit: once the credit covers all it was handed ->
  ;;     body, reading starts again and the body deadline is armed again.
  ;;   - body: reading goes on only once all that was handed is credited,
  ;;     since the core waits at the end of every feed that hands a reader on
  ;;     credit a piece, so nothing is owed, and only a credit of none is
  ;;     taken.
  ;; A credit for more than the reader was handed and has not credited, or
  ;; one that is not a count, is a caller bug: an assertion violation.  In
  ;; every other state the message has ended, and reading waits for the
  ;; response, or the reader has been let go: nothing changes.
  (define (on-body-credit s fields)
    (case (conn-phase s)
      ((awaiting-credit)
       (let ((bd (conn-body s)))
         (credit! bd fields)
         (if (fxzero? (body-owed bd))
             (begin
               (conn-phase-set! s 'body)
               (conn-deadline-set! s 'body)
               (values s '((read-start) (arm-deadline body))))
             (values s '()))))
      ((body)
       (credit! (conn-body s) fields)
       (values s '()))
      (else (values s '()))))

  ;; credit! : BodyState (Listof Any) -> Void
  ;; `(n)`, a body-credit's fields: `n` bytes of what the reader owes are
  ;; credited.  A count past what it owes, or no count, is refused.
  (define (credit! bd fields)
    (let ((n (and (pair? fields) (null? (cdr fields)) (car fields))))
      (unless (and (fixnum? n) (fx<=? 0 n (body-owed bd)))
        (assertion-violation 'conn-step "a credit for bytes the reader was not handed"
                             fields (body-owed bd)))
      (body-owed-set! bd (fx- (body-owed bd) n))))

  ;; The server's drain has told the connection to finish.
  ;; idle, shutdown-requested -> closing: nothing is in flight, so close at
  ;; once, with no response, as at the idle deadline: a close with no
  ;; response is at once.
  ;; head, body, awaiting-credit, handling or responding, shutdown-requested:
  ;; the request in flight is finished by the rows it is under way in, and
  ;; the connection closes after its response, for a reason of its own if it
  ;; has one, or else `shutdown`: the response says `Connection: close` if
  ;; its head is not yet written, the pipelined rest is dropped, and the
  ;; connection lingers, as every close after a response does.
  ;; Every other state asks for nothing: lingering closes after its response
  ;; already, and closing and closed are closing.
  (define (on-shutdown-requested s)
    (case (conn-phase s)
      ((idle) (close s 'shutdown '()))
      ((head body awaiting-credit handling responding)
       (unless (conn-close-after s) (conn-close-after-set! s 'shutdown))
       (values s '()))
      (else (values s '()))))

  ;; closing, closed -> closed.  handed-off too: the stream the taker was
  ;; handed has closed.
  (define (on-closed s)
    (case (conn-phase s)
      ((closing handed-off) (conn-phase-set! s 'closed) (values s '()))
      (else (values s '()))))

  ;; close : ConnState Symbol (Listof Action) -> (values ConnState (Listof Action))
  ;; Enter `closing`, disarming the deadline, armed or not, before the
  ;; close: the shell's wheel holds a connection until its deadline is
  ;; disarmed or passes.  `before` precedes both.  A body being read goes,
  ;; its reader with it, and so does a body being written, its producer
  ;; with it.
  (define (close s reason before)
    (conn-phase-set! s 'closing)
    (conn-deadline-set! s #f)
    (body-roll! (conn-body s))
    (end-stream! s)
    (conn-taker-set! s #f)
    (values s (append before (list '(disarm-deadline) (list 'close reason)))))

  ;; respond-and-close :
  ;;   ConnState Symbol Headers -> (values ConnState (Listof Action))
  ;; Enter `responding` with a status the core originates, closing afterwards
  ;; for `reason`: every status the core originates closes.  The status is
  ;; the reason's, from (http-server decisions).
  (define (respond-and-close s reason headers)
    (respond s (reason-status reason) reason headers))

  ;; respond :
  ;;   ConnState Nat Symbol Headers -> (values ConnState (Listof Action))
  ;; Enter `responding` with `status`, closing afterwards for `reason`, and
  ;; arm the write deadline, as every entry into `responding` does (the
  ;; deadline armed before, a header or body one, gives way to it).  From
  ;; head or body, which read, reading stops with the write, since
  ;; `responding` does not read the request; from handling it stays as
  ;; handling left it: stopped, or reading only to notice the client close.
  ;; What the body keeps for the answer is let go, a whole reader's buffer
  ;; among it, but not the reader: the pieces already asked for, a prefix up
  ;; to a cap or those met before an error, still go to it, and it is let go
  ;; once the connection lingers or closes.  Nothing asks for its end.
  ;; The response has no body and no headers but `headers`, a redirect's
  ;; Location; the serializer writes its phrase, and its framing and
  ;; `Connection: close`.  The core's own response is
  ;; read for faults as any caller's is.
  (define (respond s status reason headers)
    (let ((reading? (memq (conn-phase s) '(head body))))
      (conn-phase-set! s 'responding)
      (conn-deadline-set! s 'write)
      (unless (eq? (conn-close-after s) 'client-closed) (conn-close-after-set! s reason))
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
