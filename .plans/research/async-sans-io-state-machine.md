# chez-http-server asynchrony model — proposal: Sans-I/O connection state machine with an action interpreter

- key: `sans-io-state-machine`
- date: 2026-09-19
- machine: macOS arm64, Chez 10.4.1 (`chez --version` → `10.4.1`), libuv 1.52.1 (measured: `libuv=1.52.1` in the sizes spike below)
- prototype (runnable, in the scratchpad, never in a repo):
  - `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/sansio/core.sls` — the pure core
  - `.../spike/sansio/adapter.sls` — the parser-callback→event adapter and run-to-completion action queue (shared by both shells)
  - `.../spike/sansio-shell.sps` — the socket-free shell (no libuv import anywhere)
  - `.../spike/libuv-shell.sps` — the same core+adapter driven by chez-libuv over loopback
  - `.../spike/sizes.sps` — libuv handle sizes through the binding

Everything below that says MEASURED was run on this machine today; commands and verbatim output are in §12.

---

## 0. One-paragraph summary

The HTTP connection is a pure function `conn-step : State × Event → State × [Action]`. Events are what the world tells the connection (`bytes-arrived`, `eof`, `read-error`, `write-completed`, `tick`, `parser-event …`, `parser-result …`, `handler-responded`, `handler-body-chunk`, `body-credit`, `handler-failed`, `shutdown-requested`); actions are what the connection asks the world to do (`feed-parser`, `reply-parser`, `resume-parser`, `write`, `read-stop`, `read-start`, `call-handler`, `deliver-body`, `notify-producer`, `arm-deadline`, `shutdown`, `close`). The imperative shell is ~120 lines: each libuv callback builds an event and calls `dispatch!`; each parser callback builds a `parser-event`, calls `dispatch!` *synchronously inside `parser-feed!`*, and returns whatever `reply-parser` the step produced (`continue` / `pause` / `skip-body` / `(fail code)`); effect actions are queued and executed only after the outermost dispatch returns (run-to-completion), which is what makes the parser's own re-entrancy and poisoning rules (byte-machine `runtime.sls:978-1059`) unreachable. The prototype runs the same core under a socket-free fake loop (pipelining at every chunk size 1..135, LIFO handler responses, a pipeline cap that pauses the parser and stops reads, `Connection: close` followed by more data, HTTP/1.0, handler exception → 500, parser error → 400+close, EOF with a request in flight — 13/13 checks) and under a real chez-libuv loop over loopback (four pipelined requests, handlers answering 4,3,2,1 via timers and `uv-getaddrinfo!`, responses written 1,2,3,4, `Connection: close` honoured, connection table empty at exit). Measured allocation: 6,832 B/request for the naive pure core alone, 14,054 B/request for core+adapter+parser+fake shell. Per-connection resident cost is dominated by chez-libuv's 64 KiB read buffer, not by this model (zero timer handles per connection, zero continuations).

---

## 1. The model

### 1.1 Types (proposal; the prototype uses tagged lists for the same shapes)

```scheme
;; --- events: the world -> the connection -----------------------------------
;; (bytes-arrived bv start end)        libuv on-data. bv is FRESH per delivery (ADR-0009)
;; (eof)                               libuv on-eof
;; (read-error errno)                  libuv on-error, errno the &uv-errno-error symbol
;; (write-completed nbytes err)        libuv uv-write! on-complete
;; (shutdown-completed err)            libuv uv-shutdown! on-complete
;; (closed)                            libuv on-close — terminal, shell deregisters
;; (tick now-ms)                       the shared per-loop timer (see §6)
;; (parser-event name . args)          one of the 25 chez-httparse callbacks, fired INSIDE feed
;; (parser-result status consumed next end bv)   what parser-feed! answered
;; (handler-responded id status headers body-or-#f)  the handler's respond procedure
;; (handler-body-chunk id bv start end)          streaming response chunk from the handler
;; (handler-body-end id)                        streaming response finished
;; (handler-failed id condition)                the handler raised
;; (body-credit id n)                           the handler wants up to n more body bytes
;; (shutdown-requested)                         server draining (SIGTERM)

;; --- actions: the connection -> the world ----------------------------------
;; (reply-parser continue|pause|skip-body|(fail code))  answered SYNCHRONOUSLY by the parser callback
;; (feed-parser bv start end)          parser-feed! (never while a feed is running)
;; (resume-parser)                     parser-resume! (must precede the next feed-parser)
;; (write bv)                          uv-write!, completion becomes write-completed
;; (read-stop) (read-start)            uv-read-stop! / uv-read-start! (guarded, §7)
;; (call-handler request)              invoke the application handler
;; (deliver-body id bv start end) (deliver-body-end id)   push body to the streaming consumer
;; (notify-producer id)                tell a streaming response producer it may write again
;; (arm-deadline kind ms) (disarm-deadline)   deadline bookkeeping for the shared tick (§6)
;; (shutdown)                          uv-shutdown!, then close on shutdown-completed
;; (close reason)                      uv-close!, exactly once, owned by the shell (§9)
;; (log level datum)                   structured log line (12-factor: stdout)

;; conn-step : ConnState Event -> (values ConnState (Listof Action))
```

`ConnState` is an immutable record: `phase`, `cur` (the request being parsed), `next-id`, `inflight` (ids awaiting a response, oldest first), `ready` (responses that arrived out of order, by id), `head` (the id whose response is written next), `out-bytes`, `reading?`, `pending-input` (the unconsumed remainder after a parser pause: `(bv from to)`), `parser-paused?`, `close-after?`, `eof-seen?`, `deadline` + `deadline-kind`, `body-credit`, `pending-body`, and `limits`. Prototype: `core.sls:41-57`.

### 1.2 The two action classes and run-to-completion

The parser fires its callbacks synchronously inside `parser-feed!` and *requires* an answer from each callback (`docs/api.org` "Callbacks": an outcome is `callback-continue`, `callback-pause`, or a `make-callback-failure`; `on-headers-complete` answers `'skip-body` or nothing). So one action class must be consumed synchronously: `reply-parser`. Every other action is an effect, and effects are **queued** while a feed is running and executed only when the outermost `dispatch!` returns. Prototype `adapter.sls:27-52` (`conn-dispatch!` / `conn-drain!` with a depth counter); `conn-run-parser-feed!` (`adapter.sls:54-59`) bumps depth around `parser-feed!`.

Why this is forced, not chosen:

- byte-machine refuses re-entrant feeds: `parser-feed!` sets the lifecycle to `busy` before running and a callback that feeds again meets the `reentrancy` contract violation (`/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:998-1000`: `((busy) (byte-machine-contract-violation 'parser-feed! 'reentrancy …))`; same arm for `parser-finish!` at `:1343` and `parser-resume!` at `:1612`).
- a callback that escapes non-locally poisons the parser (`runtime.sls:1057`, the `dynamic-wind` after-thunk: `(unless completed (parser-set-lifecycle! parser 'poisoned))`; the wind begins at `:1021`). Deferring effects means nothing that can raise (a `uv-write!` on a closing handle, a handler) ever runs inside a parser callback; only `conn-step` runs there, and `conn-step` is total over the event alphabet (its `else` is an `assertion-violation` on an unknown event, i.e. a test-caught bug, not a runtime path).
- chez-libuv refuses `uv-run` re-entry from a callback (`/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:55-56`: `(when (loop-running? loop) (raise (make-uv-invalid-argument 'uv-run 'loop-running)))`), so a shell can never "pump the loop" from inside a callback to wait for anything. Every wait is an event that arrives later. That is exactly the Sans-I/O discipline.

### 1.3 Purity boundary

`conn-step` allocates only Scheme data, calls no chez-libuv or byte-machine procedure, and reads no clock — `tick` carries `now` (the shell stamps it from `uv-now`, libuv's cached per-iteration time, `docs/api.md` "The loop" table). The `feed-parser` action carries the bytevector by reference; that is safe because chez-libuv hands `on-data` a fresh copy per delivery (ADR-0009 "Reads: … delivered to `on-data` as a freshly copied bytevector"). Span callbacks index the caller's bytevector (api.org: "`[from,to)` indexes the bytevector *you* passed to `parser-feed!`"), which is that same fresh delivery, so the core may either copy spans (prototype does: `core.sls` `span-copy`) or retain `(bv from to)` triples referencing the delivery — the latter is an allocation optimisation with a retention cost (§10).

---

## 2. Handler API

```scheme
;; A handler is a plain procedure. It may respond now or later, from any
;; libuv callback (timer, DNS, another socket's read, …), by calling the
;; procedures it was given. Those procedures do nothing but dispatch EVENTS.
;;
;; handler : Request Responder -> unspecified
;; Request (immutable record):
;;   request-id        : Nat                       ; per-connection sequence, 1-based
;;   request-method    : Symbol                    ; from llhttp's method number
;;   request-target    : Bytevector                ; the whole span[url]
;;   request-uri       : (U UriComponents #f)      ; uriparse (uri collect) uri-parse, mode uri-reference
;;   request-version   : (Pair Nat Nat)
;;   request-headers   : (Listof (Pair String Bytevector))   ; name lower-cased, value raw
;;   request-keep-alive? : Boolean
;;   request-body-length : (U Nat 'chunked 'none)
;;   request-body      : (U Bytevector 'streaming)  ; buffered up to max-buffered-body, else 'streaming
;; Responder (record of procedures; every one is (lambda (...) (dispatch! conn EVENT)) and returns immediately)
;;   (respond r status headers body)               ; (1) whole response, body a bytevector
;;   (respond-stream r status headers)  -> Sink    ; (2) begin a streaming response
;;   (sink-write! sink bv [start end] on-ready)    ;     one chunk; on-ready is a thunk called when the
;;                                                 ;     connection has drained below low-water
;;   (sink-end! sink)                              ;     last chunk sent (chunked encoding: 0\r\n\r\n)
;;   (body-read! r on-chunk)                       ; (3) ask for the next request-body chunk:
;;                                                 ;     on-chunk : (bv start end) or (eof)
;;   (respond-error r condition)                   ; explicit 500
```

Every one of those procedures is a closure over the connection cell created by the shell (`libuv-shell.sps:66-71` shows `respond` as `(lambda (status headers body) (conn-dispatch! c (list 'handler-responded id …)))`). The handler never sees the `uv-tcp` handle, so it cannot write out of order, cannot close, and cannot feed the parser.

### 2.1 (1) trivial respond

```scheme
(define (hello req respond)
  (respond 200 '(("content-type" . "text/plain")) (string->utf8 "hello\n")))
```

Inside the core, `handler-responded` stores the response under its id in `ready`; `flush-ready` writes every response whose id equals `head`, in order (`core.sls` `flush-ready`). MEASURED (§12.1, "lifo response order (handler side): (3 2 1)" and the wire shows /aaa,/bbb,/ccc): three pipelined requests answered newest-first still go out in request order.

### 2.2 (2) streaming a large response body with backpressure

```scheme
(define (big-file req respond)
  (let* ((sink (respond-stream req 200 '(("content-type" . "application/octet-stream"))))
         (chunks (open-chunk-source ...)))          ; anything that yields bytevectors
    (let pump ()
      (let ((bv (next-chunk chunks)))
        (if (not bv)
            (sink-end! sink)
            ;; sink-write! dispatches (handler-body-chunk id bv 0 n). The core issues
            ;; (write bv), adds n to out-bytes, and, if out-bytes > high-water, emits
            ;; (read-stop) AND withholds (notify-producer id) until write-completed
            ;; events bring out-bytes under low-water. `pump` is then called again
            ;; from the interpreter, i.e. from inside a write completion callback.
            (sink-write! sink bv pump))))))
```

Two backpressure signals are combined in the core, per ADR-0018 ("Queueing and admission remain server policy"): the byte/request counts the server keeps itself (api.md "Bounding write memory": increment "only after `uv-write!` returns successfully", decrement "from the matching `on-complete`"), and the congestion gauge `uv-stream-write-queue-size` which the shell samples on each `write-completed` and passes in the event as a third field (`(write-completed n err queued)`) — "a congestion signal, not a memory gauge" (api.md). The producer is never told to write while `out-bytes > high-water`; on `write-completed` the core checks `out-bytes <= low-water` and emits `(notify-producer id)` once. Because the producer's `on-ready` thunk runs from the interpreter, it is not re-entrant with the handler's own frame — the handler returned long ago.

Streaming responses interact with pipelining: a streaming response for id *k* holds `head` at *k* until `handler-body-end`; later responses queue in `ready`. That is the correct HTTP/1.1 behaviour and the reason the cap on outstanding requests (§4) must count the streaming one.

### 2.3 (3) consuming a large request body incrementally

```scheme
(define (upload req respond)
  (let ((sink (open-output-file/async ...)))       ; whatever the app does with bytes
    (let next ()
      (body-read! req
        (lambda (bv start end)                       ; or the symbol 'eof
          (if (eq? bv 'eof)
              (begin (close-it sink) (respond 201 '() #vu8()))
              (begin (consume sink bv start end)
                     (next))))))))                    ; ask for more only when ready
```

Handlers for streaming uploads are dispatched at **headers-complete**, not message-complete (a server option `dispatch: 'headers` or a per-route flag; the core carries it in `limits`). The mechanism is credit-based and uses the parser's own pause:

- `body-read!` dispatches `(body-credit id 1)`. If `pending-body` holds a chunk it is delivered with `(deliver-body …)`; otherwise the credit is recorded.
- When `on-body-data` fires with no credit, the core copies the span into `pending-body`, answers `(reply-parser pause)` and emits `(read-stop)`. `parser-feed!` returns `'paused`; the `parser-result` event's `next`/`end` let the core retain the unconsumed remainder as `pending-input` (safe: the delivery bytevector is ours, ADR-0009).
- When credit arrives and `pending-body` is drained, the core emits `(resume-parser)`, `(feed-parser bv next end)` for the remainder, then `(read-start)` — in that order, which the interpreter executes in that order. This is *exactly* the same sequence the pipeline cap uses, and it is the sequence MEASURED in §12.1 ("cap=2 trace: … (read-stop) (write 49) (write 49) (resume-parser) (feed-parser) (call-handler 3 "/ccc") (read-start) …").

`parser-resume!` "changes the lifecycle only: no callback runs, no input is read" (api.org "Lifecycle"), and a resumed run "re-enters past the callback" (`chez-httparse/test/support/harness/httparse/test/drive.sls:65-76`, the harness's own resume loop), so no byte is fed twice. Pausing at message-complete is corpus-covered (`llhttp/test/request/pausing.md` "on_message_complete"; conformance.org: "A PAUSE FROM A FEED IS DIFFERENT: 24 fixtures record one, and this parser matches all of them at every chunk size"). Pausing inside `on-body-data` is not corpus-covered for this exact site and is listed as a risk (§11).

### 2.4 (4) awaiting an external async result (DNS)

```scheme
(define (whois req respond)
  (uv-getaddrinfo! loop (header-ref req "host") #f '((socktype . stream))
    (lambda (err results)                            ; a libuv callback, on the loop thread
      (if err
          (respond 502 '() (string->utf8 (symbol->string (uv-errno-error-errno err))))
          (respond 200 '() (string->utf8 (uv-addrinfo-address (car results))))))))
```

MEASURED end to end (§12.2): the `/dns` request was answered with `dns (::1 127.0.0.1)` and, because handlers 1–3 were timer-delayed 30/20/10 ms, the handler-side order was `4 3 2 1` while the wire order was 1,2,3,4. `uv-getaddrinfo!`'s completion "delivered on the loop thread like every other callback" (api.md "DNS"), so `respond` needs no lock: it is just `dispatch!`.

Rule that makes (4) safe: **a handler may call `respond` from any libuv callback, at any later time, at most once per request; a `respond` after the connection closed is a no-op event** (the core's `closed` phase drops it with a `(log …)` action). The shell keeps the connection cell alive until `on-close` has run, so a late `respond` never touches a freed handle.

What (4) does **not** cover: handler work on another Chez thread. `uv_async` is not bound (task statement; ADR-0008's trampoline set has no async slot) and the handle registry is an unsynchronised eqv-hashtable, so `respond` must not be called from a `fork-thread` thread. Bridge options are in §11.

---

## 3. The connection driver (imperative shell)

### 3.1 libuv callbacks → events

| chez-libuv callback | shape (api.md / stream.sls) | event dispatched |
|---|---|---|
| `uv-listen!` on-connection `(err)` | `tcp.sls` | server-level: `(accept)` → shell does `uv-accept!`, builds the cell, registers it, `uv-read-start!` |
| `uv-read-start!` on-data `(bv start end)` | `stream.sls:80-97` | `(bytes-arrived bv start end)` |
| on-eof `()` | "EOF is not an error… its own callback, taking no arguments" (quickstart) | `(eof)` |
| on-error `(condition)` | "delivered to `on-error` as a condition *object* — never raised" (quickstart) | `(read-error errno)` |
| `uv-write!` on-complete `(err)` | `stream.sls:24-59`; the block is freed *before* on-complete (ADR-0009 correction) | `(write-completed n err (uv-stream-write-queue-size tcp))` — `n` closed over at issue time |
| `uv-shutdown!` on-shutdown `(err)` | `stream.sls:62-70` | `(shutdown-completed err)` → core answers `(close reason)` |
| `uv-close!` on-close `()` | `handle.sls:101-104`, `handles.sls:479-486` | `(closed)` — shell deregisters; no further events accepted |
| per-loop tick timer `(timer)` | `timer.sls:33-45` | `(tick (uv-now loop))` to every connection whose deadline bucket expired (§6) |
| `uv-signal-start-oneshot!` `(sig)` | api.md "Signals" | server-level `(sigterm)` (§8) |
| `uv-getaddrinfo!` on-complete `(err results)` | `dns.sls:78-108` | not a connection event; the handler turns it into `handler-responded` via `respond` |

The prototype's executor is `libuv-shell.sps:55-83`; its read callbacks are three one-liners (`libuv-shell.sps:50-52`).

### 3.2 The 25 parser callbacks → events

The adapter binds all twenty-five (a hole is refused at `make-parser`, api.org "Every REQUIRED callback must be bound"). Prototype `adapter.sls:70-102`:

| callback group | binding | event | what the core does |
|---|---|---|---|
| 10 span callbacks: `on-method-data on-url-data on-protocol-data on-version-data on-status-data on-header-field-data on-header-value-data on-body-data on-chunk-extension-name-data on-chunk-extension-value-data` | `(lambda (p ctx bv from to) (dispatch! c (list 'parser-event NAME bv from to)) (reply->outcome c))` | `(parser-event NAME bv from to)` | copies or retains the span into `cur`; `on-body-data` goes to the body path (§2.3); every span checks its limit (§5) and can answer `(fail code)` |
| 14 event callbacks: `on-reset on-message-begin on-method-complete on-url-complete on-protocol-complete on-version-complete on-status-complete on-header-field-complete on-header-value-complete on-chunk-header on-chunk-extension-name-complete on-chunk-extension-value-complete on-chunk-complete on-message-complete` | `(lambda (p ctx) (dispatch! c (list 'parser-event NAME)) (reply->outcome c))` | `(parser-event NAME)` | `on-message-begin` arms the header deadline; `on-header-value-complete` finalises a header; `on-message-complete` builds the Request, decides keep-alive, enqueues, emits `(call-handler …)` and possibly `pause`+`read-stop`; `on-reset` is the pipelining boundary, used only for a consistency check (`cur` must be `#f`) |
| 1 decision callback: `on-headers-complete` | `(lambda (p ctx) (dispatch! c (list 'parser-event 'on-headers-complete (parser-field-ref p 'method) (parser-field-ref p 'http-major) (parser-field-ref p 'http-minor) (parser-field-ref p 'flags) (parser-field-ref p 'content-length))) (reply->outcome c))` | `(parser-event on-headers-complete method major minor flags content-length)` | this is where flags are read — **inside the callback**, because "the restart between two pipelined messages … stores zero over `flags`" (api.org "Set once, not once per message") and `content-length` "counts *down* as the body arrives … Read it inside `on-headers-complete` if you want the declared length" (api.org "Reading parser state"). The core decides `skip-body` (never for a request server; `HEAD` affects the *response*), dispatch-at-headers, and body limits |

`reply->outcome` (`adapter.sls:61-68`) maps `continue`→`callback-continue`, `pause`→`callback-pause`, `skip-body`→`'skip-body`, `(fail code)`→`(make-callback-failure code #f)`.

After `parser-feed!` returns, the adapter dispatches `(parser-result status consumed next end bv)` (`adapter.sls:54-59`). The core's arms (`core.sls` `on-parser-result`):

- `need-input` — nothing (this is "the ordinary outcome, including *after a complete message*", api.org).
- `paused` — retain `(bv next end)` as `pending-input` when `next < end`.
- `error` — if `close-after?` is already set, ignore (this is llhttp's data-after-close, MEASURED §12.1: `status=error consumed=47 next=47 error=(closed-connection "Data after `Connection: close`" 47)`); otherwise `(read-stop) (write-status 400) (close parser-error)`. A `callback-failure` from a limit check arrives here too, with the code the core chose, and maps to 431/413/414.
- `finished`/`stopped` — treated as `close`.

`parser-finish!` is issued on `eof` only when a message is mid-flight (`cur` non-`#f`), to distinguish a truncated body (→ 400) from a clean close; the corpus never calls it (api.org "The corpus never calls `parser-finish!`"), so this path is covered by our own tests only.

### 3.3 The interpreter loop

```scheme
;; dispatch! : Conn Event -> unspecified
(define (dispatch! c ev)
  (let-values (((s* acts) (conn-step (conn-state c) ev)))
    (conn-state-set! c s*)
    (for-each (lambda (a) (if (eq? (car a) 'reply-parser) (set-reply! c (cadr a)) (enqueue! c a))) acts)
    (when (zero? (conn-depth c)) (drain! c))))
```

`drain!` pops FIFO and calls the executor; an executor that raises is caught *per action* and turned into a `(transport-error condition)` event (the prototype does not yet do this; `libuv-shell.sps:66-71` does it for `call-handler` only). Nothing raised by the shell ever reaches chez-libuv's `dispatch-guarded` (`handles.sls:302-304`) in normal operation; if something does, store-and-reraise is the backstop (§7).

---

## 4. Pipelining, response ordering, outstanding cap

State: `inflight` (ids awaiting a response, in arrival order), `ready` (responses by id), `head`. Invariant, checked by the core's own tests: the wire carries responses in strictly increasing id with no gaps; a response for id ≠ head waits in `ready`.

Cap: `limits-max-pipeline`. At `on-message-complete`, after enqueueing id *k*, if `(length inflight) >= max-pipeline` the core answers `(reply-parser pause)` and emits `(read-stop)`; the delivery's remainder is retained as `pending-input`. When `flush-ready` brings `inflight` below the cap, `maybe-resume` emits `(resume-parser)`, `(feed-parser pending)`, `(read-start)` (`core.sls` `maybe-resume`). MEASURED at cap 2 with three requests in one delivery and LIFO handlers (§12.1 "cap=2 trace"): pause, two writes, resume, feed of the remainder producing `call-handler 3`, read restart, third write — and "cap=2: identical output at every chunk size (lifo)".

Data after a close-marked message: once `close-after?` is set (`Connection: close`, or HTTP/1.0 without keep-alive, or `eof`), `bytes-arrived` produces **no** `feed-parser` (`core.sls` `on-bytes`), and `(read-stop)` is emitted at that message's completion. MEASURED §12.1: "Connection: close at chunk=1 — second request never fed to the parser" and, whole-buffer, exactly one `call-handler` with the parser's `closed-connection` error ignored. keep-alive decision = llhttp's flags, read inside `on-headers-complete`: `F-CONNECTION-CLOSE` → no; `F-CONNECTION-KEEP-ALIVE` → yes; else HTTP/1.1 → yes, 1.0 → no (`core.sls` `keep-alive?`; constants from `chez-httparse/src/httparse/grammar.sls:301-319`). This matches `llhttp/test/request/connection.md:81-105` ("No restart when keep-alive is off (1.0)": `off=22 error code=5 reason="Data after `Connection: close`"`), i.e. the corpus itself says the second request is an error at the parser and must be handled above it.

`on-reset` fires "between pipelined messages on one parser, before `on-message-begin` of the next" (api.org); the core uses it only to assert `cur = #f` and returns `continue`.

---

## 5. Backpressure in both directions

**Read side.** Verbs: `uv-read-stop!` / `uv-read-start!` (api.md "Streams": stop is "Idempotent; the buffer and callbacks are kept for the next start"; a restart with no size argument is "always accepted", api.md "read-buffer sizing contract"). The core emits `read-stop` in four situations: pipeline cap reached; no body credit; `out-bytes > high-water` (a slow reader must not be allowed to keep sending requests whose responses we cannot drain); `close-after?`. It emits `read-start` only from `maybe-resume`, and only when *all* of {cap not reached, body credit or no body pending, `out-bytes <= low-water`, not `close-after?`} hold — one place, one predicate, one test per conjunct (mutation-friendly). Shell guard, verbatim from api.md ("The read-stop/read-start pairing invariant"): `(when (uv-handle-open? stream) (uv-read-stop! stream))` — `libuv-shell.sps:72-73` applies it to both verbs.

Why read-stop matters beyond Scheme memory: api.md's flow-control section measured kernel memory per connection at "~11–15 KiB" idle vs "~530 KiB" when "data pushed and **never read**" — so the receive side "becomes the dominant cost exactly when the application has stopped reading". Our `read-stop` is deliberate and bounded by the same limits that bound Scheme memory; it is never left on indefinitely because every `read-stop` has a matching resume condition in `maybe-resume`, and the idle deadline (§6) closes a connection that stays stopped with nothing in flight.

**Write side.** ADR-0018: "The binding will not hold unsubmitted write blocks, will not enforce a queue-depth or byte cap, and `uv-write!` will not refuse." So the core holds the two counters api.md tells consumers to keep (outstanding payload bytes and outstanding request count — the prototype keeps bytes only, `out-bytes`; the real one keeps both, since "a **zero-length write allocates a full request block**"). The shell samples `uv-stream-write-queue-size` on each completion and passes it in the event; the core treats it as advisory ("Unix counts bytes not yet handed to the kernel … Windows counts the opposite direction", api.md) and may lower its effective high-water when it grows. High/low water are `limits` (defaults 64 KiB / 16 KiB in the loop prototype: `libuv-shell.sps:47`).

Because responses are only *issued* from `flush-ready`, a slow client with many pipelined requests hits the cap (parser paused, reads stopped) before it can accumulate unbounded `ready` responses; worst-case queued response bytes are `max-pipeline × max-response-bytes-before-streaming`.

---

## 6. Timeouts, limits, and timer-handle economy at 10k connections

Deadlines are **data in the pure state**: `(arm-deadline kind ms)` is an action for the shell's *bookkeeping*, but the core itself stores `deadline = now + ms` using the `now` carried by the most recent event (the shell stamps every event with `(uv-now loop)`; the prototype omits this). Kinds: `header` (armed at `on-message-begin`, disarmed at `on-headers-complete`), `body` (armed at headers-complete, re-armed on every `on-body-data`, disarmed at message-complete), `idle` (armed when `inflight` is empty and nothing is pending, disarmed at the next `on-message-begin`), `drain` (server-wide, §8). On `(tick now)` the core compares and, if expired, emits `(write-status 408) (close timeout)` for header/body/idle.

Timer handles: **zero per connection**. One `make-uv-timer` per loop, repeating every `tick-ms` (default 500 ms); the shell keeps a timing wheel — a vector of buckets keyed by `(deadline div tick-ms)` — and on each tick dispatches `(tick now)` only to connections in expired buckets. MEASURED: `uv_handle_size(UV_TIMER)=152` bytes (§12.3), so 10k per-connection timers would cost ~1.5 MiB of foreign memory plus 10k registry entries in the unsynchronised eqv-hashtable and 10k timer callbacks per period — affordable but pointless. Granularity: a deadline of D ms fires within [D, D+tick-ms]; the tests drive `(tick now)` directly with a fake clock, so timeout behaviour is tested without sleeping. Alternative retained as a switch: one `uv-timer` per connection with `uv-timer-again!`, for deployments that want millisecond-exact timeouts; the core does not change, only the shell's `arm-deadline` executor.

Limits (all in the `limits` record, all server policy per architecture §11): `max-request-target` (checked on `on-url-data`, → 414), `max-header-field`, `max-header-value`, `max-header-bytes`, `max-headers` (→ 431), `max-buffered-body` (→ 413 when the handler is not streaming), `max-pipeline`, `high-water`/`low-water` (write bytes), `max-outstanding-write-reqs`, `header-timeout`, `body-timeout`, `idle-timeout`, `drain-timeout`, `read-buffer-size` (passed to the first `uv-read-start!`; see §10). A limit breach inside a span callback answers `(reply-parser (fail code))`, which makes `parser-feed!` return `'error` with our code (api.org: a callback outcome may be `make-callback-failure`); the `parser-result` arm maps code → status and closes.

---

## 7. Error propagation

| source | where it surfaces | what the core does |
|---|---|---|
| parser error (malformed) | `(parser-result error …)` with llhttp's code/reason/offset (api.org "Errors") | `(read-stop) (write-status 400) (close parser-error)`; ignored when `close-after?` (data-after-close). MEASURED §12.1 "parser error: 400 and close" |
| policy error (limit) | `(reply-parser (fail code))` → `(parser-result error …)` with our code | 413/414/431 then close |
| handler exception (synchronous, in `call-handler`) | the executor's `guard` → `(handler-failed id condition)` (`libuv-shell.sps:69`) | 500 if nothing of that response was written, else `(close handler-error)`; connection otherwise continues. MEASURED §12.1 "handler raise: 500 written" |
| handler exception (later, inside a `respond` called from a timer/DNS callback) | `respond` is `(lambda … (dispatch! …))`; the raise happens *before* `respond` in the handler's own callback frame, i.e. in some other libuv callback | the handler is responsible for its own `guard` there; if it does not, chez-libuv's `dispatch-guarded` stores the condition and stops the loop (below). Mitigation: the Responder's procedures are documented as never raising, and a `with-handler-guard` helper wraps user callbacks |
| transport error (`ECONNRESET`, write failure) | `(read-error errno)` / `(write-completed n err)` — conditions as values, never raised (quickstart "The three rules") | `(close read-error)` / `(close write-error)`; pending responses dropped; late `respond`s become no-ops |
| shell bug (an executor raises: e.g. `&uv-handle-closed` from a verb on a closed handle) | caught per action in `drain!` → `(transport-error condition)` | close; log |
| anything that still escapes a callback | chez-libuv's store-and-reraise: `dispatch-guarded` → `loop-record-error!` stores the first, `uv_loop_stop`s, defers the rest (`handles.sls:290-304`); `uv-run` returns and re-raises `&uv-callback-error` composed with the original (`loop.sls:40-45`) | the server's run loop `(guard (e ((uv-callback-error? e) (log e) (run-again)))` — the loop is in a defined state because the iteration finished (`spike/FINDINGS.md` "Q2 verdict" item 4); the connection whose callback raised has already been closed by the per-action guard, or is closed by a reconciliation pass over `uv-loop-live-handles` against the connection table |
| an UNGUARDED raise | kills the process: FINDINGS Q2 "Scenario `bare` — no guard anywhere. Exit code **255**" and "nothing after `uv_run` runs: no teardown" | no such path exists in this design: the only Scheme that runs inside a parser callback is `conn-step` (total), and every executor call is guarded |

The design deliberately never lets a condition cross libuv frames even though FINDINGS Q2 measured that it *works* on this platform ("The condition **does** cross libuv's C stack frames and arrive at a `guard`"), because the same document measured the cost: "the callback's own cleanup never ran at escape time", "nothing re-runs the loop automatically", `uv_loop_close` → `-16 (EBUSY)`. With everything reified as events and actions there is nothing to escape *from*: an error is an event like any other.

---

## 8. Graceful shutdown

Server-level pure machine (`server-step : ServerState × Event → ServerState × [Action]`) with events `(sigterm)`, `(connection-opened id)`, `(connection-closed id)`, `(tick now)`; actions `(close-listener)`, `(broadcast shutdown-requested)`, `(arm-deadline drain ms)`, `(force-close-all)`, `(stop-loop)`.

- `uv-signal-start-oneshot! watcher 'sigterm …` (api.md "Signals": "first `SIGTERM` drains, a second one kills (the disposition reverts to `SIG_DFL` once the oneshot fires)"). Its callback dispatches `(sigterm)`.
- `(close-listener)` = `uv-close!` on the listening tcp (owned by the server shell), so no new accepts.
- `(broadcast shutdown-requested)`: each connection's core sets `close-after?`, stops reading, finishes `inflight` responses (writing `Connection: close` on the last), then `(shutdown)` → `(close done)`. Idle connections (empty `inflight`) close immediately.
- `(arm-deadline drain ms)`: on expiry, `(force-close-all)` = `(close forced)` to every remaining connection; then `(stop-loop)` = `uv-stop!` (legal from a callback, api.md), after which the run loop calls `uv-loop-teardown!` ("Close every handle, drain, then close the loop"; it also "best-effort-cancels the loop's in-flight DNS requests", api.md "DNS").
- The signal watcher is closed from its own callback, exactly as the api.md example does.

Because the server machine is pure too, "SIGTERM with 3 connections, one mid-body, deadline 2 s" is a table test.

---

## 9. Close-ownership protocol

Binding fact: "A second `uv-close!` silently discards its callback… a close issued against a handle that is already `'closing` stores nothing and the supplied `on-close` never runs" (api.md "Child processes", applied to every handle kind); source: `handles.sls:483-486` `(when (eq? (handle-state handle) 'open) (set-handle-on-close! …) (set-handle-state! handle 'closing) (uv-close-native …))`.

Protocol (v0.5 design §9, "capture peer identity immediately on accept, register before the first read, centralize *all* close initiation through the owner, deregister only from the first `on-close`"):

1. The shell is the only code with the `uv-tcp` handle. Handlers never see it (§2).
2. The only `uv-close!` call for a connection handle is in the executor's `close` arm, guarded by a per-cell `closing?` flag (`libuv-shell.sps:74-81`), so the *first* close action wins and carries the deregistering `on-close`; later `close` actions (e.g. `eof` arriving after `timeout`) are no-ops.
3. Graceful path is `(shutdown)` → `uv-shutdown!` → on completion `(close …)`; never `uv-close!` directly while writes are queued, because close "flushes the queue with `UV_ECANCELED`" (v0.5 design §9).
4. `on-close` dispatches `(closed)` and removes the cell from the connection table; from then on `dispatch!` on that cell is a no-op (the core's `closed` phase).
5. Teardown (`uv-loop-teardown!`) may close handles the shell did not: the table is reconciled against `uv-loop-live-handles` after teardown in tests (test-echo.sps asserts `'()` there).

MEASURED §12.2: `(peer-closed 0 done)` and `connection table empty` after the `Connection: close` request.

---

## 10. Performance

MEASURED (§12.1, `sansio-shell.sps` sections 9–10):

- pure core alone, one GET with three headers replayed as 14 parser events + `handler-responded` + `write-completed`, 20,000 iterations: **6,832 bytes/request**. This is the *naive* prototype: every event copies a 13-field record via an alist-driven updater (`core.sls` `update`), each header value is `bv-concat`'d and converted to a string, and the `partial` record is rebuilt per span. Straightforward reductions: keep `cur` as a single mutable accumulator owned by the state (linear use; still referentially transparent from the shell's point of view), retain `(bv from to)` spans instead of copying, lower-case header names into an interned symbol table, and build the response head with one `bytevector` write. A 1–2 KiB/request core is realistic; 0 is not (the Request record and header list are handed to the handler).
- core + adapter + chez-httparse parser + the fake loop (which keeps a full action trace list per run, so this overstates): **14,054 bytes/request** at one request per delivery.
- per connection resident: chez-libuv's read buffer **65,536 bytes**, "committed the moment `uv-read-start!` runs, whether or not a byte ever arrives, and not reclaimed until close" (api.md); at 10,000 connections "~625 MiB" for 64 KiB vs "~40 MiB" for 4 KiB (api.md table). The design passes `read-buffer-size` from `limits` to the first `uv-read-start!`; the same api.md section measured that 4–16 KiB is "close to free" for small-message traffic. Plus `uv_handle_size(UV_TCP)=264` B (§12.3), one registry entry, one parser object (byte-machine's vector-of-slots), one `ConnState` (~15 words) and the cell (~8 words). No timer handle (§6). Each in-flight `uv-write!` is `uv_req_size(UV_WRITE)=192` B + 16-byte alignment + payload (`stream.sls:41-46`).
- continuation / thread cost: **none**. There is no `call/cc`, `call/1cc`, engine or thread anywhere in the model; handler asynchrony is closures. The comparison point: a coroutine-per-request design pays a captured continuation (a stack segment) per suspended request and must answer the foreign-callable re-entry question (§13, A2); this design does not need to ask it.
- steady-state throughput is bounded by the parser and by libuv, not by the core: the core does no I/O and no syscalls; its cost is the record copies above. The one structural overhead is that every parser callback becomes a `conn-step` call (25 kinds, ~14 per small request), i.e. a closure call plus a record copy each; with a mutable accumulator that becomes a closure call plus a field store.

---

## 11. Risks — and where this angle is simply worse

1. **Indirection tax.** Every effect is a datum interpreted elsewhere. The two-phase ordering (synchronous `reply-parser` vs deferred effects) is a real place for bugs: I hit one in the prototype — the `Connection: close` header was decided when a response *arrived* rather than when it was *written*, so with out-of-order handlers the last response lost it (§12.2 first run, `FAIL`; fixed by serialising in `flush-ready`). The direct-callback design would have had the same bug, but it is fair to say this model gives you more places to put a decision.
2. **The interpreter is not covered by the socket-free tests.** The sans-I/O suite proves the core; the executor's mapping (verb order, guards, `closing?` flag, gauge sampling) needs loopback tests exactly like `test-echo.sps`. The mitigation is that the interpreter is tiny and *contract-tested*: the same action stream fed to the fake shell and the libuv shell must yield the same wire bytes (`libuv-shell.sps` vs `sansio-shell.sps` compare the same three responses today).
3. **Streaming through events costs a round trip per chunk** (handler → event → core → `write` action → executor → `uv-write!`; completion → event → core → `notify-producer` → executor → producer thunk). A direct design writes from the producer. Per chunk this is two `conn-step` calls and a few conses; at 64 KiB chunks it is noise, at 1 KiB chunks it is not.
4. **Retention after a pause.** `pending-input` retains the whole delivery bytevector (up to `read-buffer-size`) per paused connection until resumed. With `max-pipeline` small this is bounded by connection count × buffer size in the worst case — the same order as the read buffer itself, but it *doubles* it for paused connections. Alternative: copy the remainder (usually small) — a tunable.
5. **Pause inside `on-body-data`.** The credit-based body path pauses in a span callback. Byte-machine supports pausing anywhere a callback answers `callback-pause` and the corpus covers 24 requested pauses "at every chunk size" (conformance.org), and `connection.md` "Emitting part of body and pausing" pauses right after a body span — but whether the resume point after a *span* pause is exactly `to` for our grammar is something the connection-layer replay (§12.4 plan) must pin with a test before it is relied on. If it is not, the fallback is to pause at `on-chunk-complete`/message boundaries and buffer one body span.
6. **Handler ergonomics.** Callback style, no `await`. A proposal built on engines or one-shot continuations will read better in the handler. This design does not preclude layering coroutines *on top* (a coroutine runtime is just another producer of `handler-responded` events), but it does not provide them, and if the separate spike shows continuations captured in a foreign-callable cannot be re-entered after the callable returned, those layers would have to be built with `fork-thread`+`uv_async` instead — which is not bound (task statement; ADR-0008's callback typology).
7. **Cross-thread handlers unsupported.** No `uv_async` binding and an unsynchronised registry mean `respond` is loop-thread-only. Bridge: a `(libuv async)` module later (one more trampoline type under ADR-0008's rule), or, today, a shared queue polled from the tick timer (latency = tick).
8. **Naive purity is allocation-heavy** (6.8 KiB/request measured). The fix (linear mutable accumulator) makes the core "pure by contract" rather than "pure by construction" — the tests still drive it by events, but reviewers must hold the line that `conn-step` never reads anything but its arguments.
9. **The step function's event alphabet is wide** (17 event kinds × ~8 phases). The table is bigger than the equivalent callback code. The gain is that every cell is a unit test; the cost is that unknown-event arms are `assertion-violation`s that must never be reachable in production — a raise inside a parser callback would poison the parser (`runtime.sls:1057`) and, if it escaped the shell, stop the loop.
10. **`uv-now` granularity and the shared tick** make timeouts ±tick-ms; deployments needing exact per-connection timers pay 152 B + a callback per connection (switchable, §6).
11. **Data-after-close is a policy, not a parser fact.** We rely on the core stopping the feed after a close-marked message; enabling the lenient `data-after-close` flag would silently change behaviour. Kept strict; tested by the chunk=1 replay.

Where the obvious alternative (direct callbacks mutating a connection record, as in `test-echo.sps`) is simply better: fewer lines, one fewer layer to read, no reply-vs-effect split, no interpreter contract to test. Where it is worse: every connection-semantics test needs a socket or a hand-built fake `uv-tcp`, and pause/resume, cap, backpressure and timeout logic get interleaved with libuv verb calls inside callbacks — which is precisely where `test-echo.sps` needed its own `finishing` flag and `uv-handle-open?` guard to stay correct.

---

## 12. Evidence

### 12.1 Socket-free shell — command and verbatim output

```
cd /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
gtimeout 300 chez --libdirs .:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program sansio-shell.sps
```

Output (final run; the `whole-buffer output:` block and per-section prints elided where they repeat the wire bytes shown in §12.2):

```
whole-buffer trace: ((feed-parser) (call-handler 1 "/aaa") (call-handler 2 "/bbb") (call-handler 3 "/ccc") (write 49) (write 49) (write 49) (close eof))
closed: eof
ok   pipelined: identical output at every chunk size 1..135 (sync)
lifo response order (handler side): (3 2 1)
ok   pipelined: handlers responded newest-first, wire order still 1,2,3
cap=2 trace: ((feed-parser) (call-handler 1 "/aaa") (call-handler 2 "/bbb") (read-stop) (write 49) (write 49) (resume-parser) (feed-parser) (call-handler 3 "/ccc") (read-start) (write 49) (close eof))
ok   cap=2: output identical
ok   cap=2: parser paused and read stopped, then resumed, remainder fed, read restarted
ok   cap=2: identical output at every chunk size (lifo)
close then data, whole buffer: trace=((feed-parser) (call-handler 1 "/") (read-stop) (write 64) (close done)) closed=done
output:
HTTP/1.1 200 OK
Content-Length: 7
Connection: close

echo /

ok   Connection: close -- exactly one handler call, one response, then close
ok   Connection: close at chunk=1 -- second request never fed to the parser
raw parser on close-then-data: status=error consumed=47 next=47 error=(closed-connection "Data after `Connection: close`" 47)
ok   HTTP/1.0 no keep-alive: response then close
handler raise: HTTP/1.1 500 OK
Content-Length: 14

handler failedok   handler raise: 500 written, connection stays open until the fake client's EOF
parser error: trace=((feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (read-stop) (write-status 400) (close parser-error)) closed=parser-error
ok   parser error: 400 and close
ok   eof while handler pending: response still written, then close
allocation (core+adapter+parser+fake shell, sync handler, 1 request/delivery): 2000 requests, 28108512 bytes total, 14054 bytes/request
ok   2000 keep-alive GETs answered
allocation (pure core only, 14 parser events + response + write-completed per request): 6832 bytes/request
failures: 0
```

Notes on what each row proves:
- "identical output at every chunk size 1..135": the same 135-byte pipelined buffer (`sansio-shell.sps:72-76`, the three requests of `llhttp/test/request/pipelining.md`) delivered as 1..135-byte `bytes-arrived` events produces byte-identical wire output and the identical `call-handler`/`close` sequence. The trace's *interleaving* of writes and feeds legitimately differs per chunk size, so the comparison is on wire bytes + handler-call sequence.
- The `raw parser` line is the task's "MEASURED TODAY" fact reproduced: the first message completes and the parser then reports llhttp's `closed-connection` at offset 47 (the first byte of the second request).
- The allocation lines use `(sstats-bytes (statistics))` (cumulative) after a `(collect)`; the first includes the fake loop's trace list and closures.
- The first two runs of this program FAILED for prototype reasons recorded here for honesty: (i) a `syntax-rules` functional-update macro whose let-bound field names shadowed the caller's locals (`(inflight inflight)` rebound to the *old* value) — replaced by a procedural updater; (ii) `cdr` of an empty `inflight`; (iii) my own assertions expecting `'done` where the fake client's EOF makes `'eof` correct.

### 12.2 libuv shell — command and verbatim output

```
cd /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
CHEZSCHEMELIBDIRS=.:/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src gtimeout 120 chez --program libuv-shell.sps
```

Output (timer bookkeeping actions filtered with `rg -v "stop-timer|start-timer"`):

```
client received (225 bytes):
HTTP/1.1 200 OK
Content-Length: 10

echo /aaa
HTTP/1.1 200 OK
Content-Length: 10

echo /bbb
HTTP/1.1 200 OK
Content-Length: 10

echo /ccc
HTTP/1.1 200 OK
Content-Length: 20
Connection: close

dns (::1 127.0.0.1)

server actions, in order:
  (action (feed-parser))
  (action (call-handler #[#{request ny43oce04v2ibnyfpxtn647a3-38} 1 3 "/aaa" (("Content-Length" . "3")) (#vu8(65 65 65)) #t]))
  (action (call-handler #[#{request ny43oce04v2ibnyfpxtn647a3-38} 2 4 "/bbb" (("Content-Length" . "4")) (#vu8(66 66 66 66)) #t]))
  (action (call-handler #[#{request ny43oce04v2ibnyfpxtn647a3-38} 3 28 "/ccc" (("Content-Length" . "5")) (#vu8(67 67 67 67 67)) #t]))
  (action (call-handler #[#{request ny43oce04v2ibnyfpxtn647a3-38} 4 1 "/dns" (("Host" . "x") ("Connection" . "close")) () #f]))
  (action (read-stop))
  (handler-responded 4)
  (handler-responded 3)
  (handler-responded 2)
  (handler-responded 1)
  (action (write))
  (action (write))
  (action (write))
  (action (write))
  (action (close done))
  (peer-closed 0 done)
ok  : responses in request order despite out-of-order handlers; connection closed after Connection: close; connection table empty
```

The client wrote the 4-request buffer in two uneven `uv-write!`s (0..50 and 50..end, `libuv-shell.sps:111-113`) so request boundaries did not align with deliveries; one `feed-parser` action is shown because the loopback coalesced both into one delivery on this run (kernel policy, not asserted — cf. `test-echo.sps`'s "NOTHING HERE ASSERTS … how libuv FRAGMENTED the stream"). The first run of this program printed `FAIL` because the last response lacked `Connection: close` (§11 item 1); the fix was in the core, not the shell.

### 12.3 Handle sizes through the binding

```
CHEZSCHEMELIBDIRS=.:/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program sizes.sps
uv_handle_size(UV_TIMER)=152 uv_handle_size(UV_TCP)=264 uv_req_size(UV_WRITE)=192 libuv=1.52.1
```
(`uv-handle-size` is `(foreign-procedure "uv_handle_size" (int) size_t)`, `chez-libuv/src/libuv/private/native.sls:237`; the type constants come from `src/libuv/private/constants.sls:212-215`.)

### 12.4 How the llhttp corpus and every connection-semantics test run with NO sockets (test plan)

1. **Corpus through the connection layer.** Reuse chez-httparse's loader and chunking (`(httparse test corpus-load)`, `corpus-chunk-bounds` used by `drive.sls:120`; upstream "replays every size from 1 to the length", `drive.sls:43-51`). For every `type=request` fixture in `llhttp/test/request/*.md` (8951 lines of fixtures with recorded traces in total across request/response/url), instantiate `make-conn` with a **recording adapter**: the same 25 bindings as `adapter.sls`, each additionally pushing the trace line the harness's `trace-recorder-bindings` would (`trace-recorder-bindings`, chez-httparse `test/support/harness/httparse/test/adapter.sls:443-490`) before returning the core's reply. Feed the fixture's bytes as `bytes-arrived` events at every chunk size. Assert: (a) the rendered parser trace still equals the fixture's recorded log — proving the connection layer's callbacks do not perturb parsing; for fixtures whose meta requests a `pause` or `skipBody`, the core is given a test-only `policy` field that answers the fixture's pause/skip at the named callback, so the same rows are exercised through our adapter; (b) the connection-level outcome is chunk-size-invariant: the `call-handler` sequence (method/url/headers/body bytes), the keep-alive decision per message, the `close` reason, the 400 offset for error fixtures; (c) for `connection.md`'s keep-alive/close fixtures, the outcome agrees with the recorded `flags=` and with the `Data after Connection: close` line (i.e. one `call-handler`, then close, no second feed). `type=response` fixtures are skipped by this lane (a server core has no response mode) and stay covered by chez-httparse's own ratchet.
2. **Connection-semantics tables.** Pure tests on `conn-step`: for each (state, event) → expected (state', actions), written as data. Pipelining cap, LIFO responses, high/low water, credit-based body, deadlines with a fake `now`, shutdown broadcast, late `respond` after close, `read-stop`/`read-start` conjuncts one at a time.
3. **Mutation discipline.** Each row is written to fail first; then the branch is inverted (e.g. `keep-alive?` for 1.0 → `connection.md` "No restart when keep-alive is off (1.0)" must go red; drop `(read-stop)` from the cap arm → the cap row must go red; serialise `Connection: close` at arrival time → the libuv-shell ordering test must go red, as it did).
4. **Same core under the real loop.** `libuv-shell.sps`'s shape, extended in the style of `test-echo.sps`: eight clients, uneven writes, one client that stops reading (server must hit high-water and `read-stop`; `uv-stream-write-queue-size` must grow), disconnect mid-body (`read-error`/`eof` with a pending handler), header timeout via a shortened tick, SIGTERM drain, counters back to zero via `uv-loop-live-handles`.

---

## 13. Chez Scheme assumptions (stated, with what each rests on)

- **A1 — every callback runs on the loop thread, inside `uv-run`.** chez-libuv docs: "Callbacks run here and nowhere else" (quickstart, comment above `(uv-run loop 'default)`); DNS: "completions are delivered on the loop thread like every other callback" (api.md). Consequence: the connection cells and the registry need no locks; `respond` from another thread is forbidden (§11 item 7).
- **A2 — nothing in this design captures a continuation inside a foreign-callable.** So the open question "may a continuation captured inside a foreign-callable be invoked after that callable returned" is **not load-bearing** here. What CSUG 10 §4.4 does say, quoted: "Chez Scheme handles this interaction in a general manner by trapping attempts to return to stale foreign contexts rather than by restricting the use of continuations directly. A foreign context is a foreign frame and return point corresponding to a particular call from a foreign language, e.g., C, into Scheme. A foreign context becomes stale after a normal return to the context or after a return to some other foreign context beneath it on the control stack. As a result of this treatment, Scheme continuations may be used to throw control either upwards or downwards logically through any mix of Scheme and foreign frames. Furthermore, until some return to a foreign context is actually performed, all return points remain valid. In particular, this means that programs that use continuations exclusively for nonlocal exits never attempt to return to a stale foreign context. (Nonlocal exits themselves are no problem and are implemented by the C library function longjmp or the equivalent.) Programs that use continuations more generally also function properly as long as they never actually return to a stale foreign context, even if control logically moves past stale foreign contexts via invocation of continuations." (https://cisco.github.io/ChezScheme/csug10.0/foreign.html, "Section 4.4. Continuations and Foreign Calls"). I read "trapping attempts to return to stale foreign contexts" as: re-entering a continuation whose frames include a returned foreign-callable frame will be *trapped* (an error), not silently corrupt — but that is my reading, the separate spike measures it, and this design does not depend on either outcome.
- **A3 — `guard` inside a callback is an ordinary non-local exit within one foreign context** and therefore safe by the same §4.4 text ("Nonlocal exits themselves are no problem"). Used in every executor arm and in chez-libuv's own `dispatch-guarded` (`handles.sls:302-304`).
- **A4 — `call/1cc` is not used; if a later coroutine layer used it**, CSUG 10 §6.3: "A one-shot continuation should not be returned to multiple times, either by invoking the continuation or returning normally from procedure more than once. A one-shot continuation is 'promoted' into a normal (multishot) continuation, however, if it is still active when a normal continuation is obtained by call/cc." (https://cisco.github.io/ChezScheme/csug10.0/control.html).
- **A5 — engines are not used**, and could not be combined with any timer-interrupt scheme: CSUG 10 §6.4: "Do not use the timer interrupt (see set-timer) and engines at the same time, since engines are implemented in terms of the timer." (control.html). Engines also capture continuations across whatever frame is live, which would raise A2 again.
- **A6 — threads.** CSUG 10 threads.html: "Most primitive Scheme procedures are *thread-safe*"; foreign.html: "Any thread that has been deactivated, and any thread created by some mechanism other than fork-thread must, however, be activated before it can access Scheme data or execute Scheme code." libuv's threadpool workers never run Scheme ("pure C; no Scheme ever runs off the loop thread", api.md DNS), so no activation question arises. Threaded build (`tarm64osx` per task) is assumed only so `fork-thread` remains available to future bridges.
- **A7 — `dynamic-wind` semantics** as R6RS (CSUG control.html: "The first form is identical to the Revised6 Report dynamic-wind"), which is what byte-machine relies on to poison a parser after an escape (`runtime.sls:1021-1057`); hence the rule that no executor runs inside a parser callback.
- **A8 — `(sstats-bytes (statistics))` is cumulative allocation**, used for the per-request numbers; `bytes-allocated` is not (it fell during GC in the first attempt, giving a negative figure).
- **A9 — `uv-now` (libuv's cached time, "updated once per iteration", api.md)** is sufficient for deadline arithmetic at tick granularity.
- **A10 — chez-libuv's `on-data` bytevector is fresh per delivery and never reused by the binding** (ADR-0009 "Reads", and the v0.5 amendment describing `uv__read`'s loop reusing only the *foreign* buffer), so retaining it as `pending-input` across callbacks is safe. The ADR's use-after-free warning applies to a future zero-copy *borrowed span* variant only; if that variant ships, `pending-input` must copy.

---

## 14. Sources consulted (paths and URLs)

- `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` (§5 connection layer, §7 backpressure, §10 pipelining, §11 limits, §12 error model, §13 application API, §14 testing)
- `/Users/yuzu/github/chez-http-server/AGENTS.md` (FCIS, TDD/mutation, "prefer a check to a comment", signatures)
- `/Users/yuzu/github/chez-libuv/docs/api.md` (loop, handles, streams, flow control incl. read-buffer table and write-queue gauge contract, signals, DNS, timers, conditions)
- `/Users/yuzu/github/chez-libuv/docs/quickstart.md` ("The three rules")
- `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md` lines 383-720 (Q2: `bare` exit 255; `escape`; `store`; EOF redelivered; EBUSY)
- `/Users/yuzu/github/chez-libuv/.plans/decisions/0007-no-guardians-explicit-close.md`, `0008-static-trampolines-and-handle-registry.md`, `0009-copy-at-the-boundary.md` (with the 2026-08-30 amendment), `0018-unbuffered-write-submission.md`
- `/Users/yuzu/github/chez-libuv/.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md` §9 (lines 453-478)
- `/Users/yuzu/github/chez-libuv/tests/test-echo.sps` (server shape; `finishing` flag; `uv-handle-open?` guard before restart)
- `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:40-70`; `src/libuv/stream.sls:24-135`; `src/libuv/timer.sls:25-70`; `src/libuv/handle.sls:101-104`; `src/libuv/private/handles.sls:290-324, 479-486`; `src/libuv/dns.sls:78-108`; `src/libuv/private/native.sls:237`; `src/libuv/private/constants.sls:212-215`
- `/Users/yuzu/github/chez-httparse/docs/api.org` (whole), `docs/conformance.org` lines 1-120, `test/support/harness/httparse/test/drive.sls` (whole), `test/support/harness/httparse/test/adapter.sls:440-520`, `src/httparse/grammar.sls:301-319`, `src/httparse/modes.sls:17-91`, `src/generated/httparse-message.sls:3863` (the 25-callback declaration vector)
- `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:227-241, 978-1059, 1326-1343, 1604-1612, 1633, 1668`
- `/Users/yuzu/github/uriparse/src/uri/collect.sls:19-24`
- `/Users/yuzu/github/llhttp/test/request/pipelining.md:1-80`, `test/request/connection.md:34-110, 677-760`, `test/request/pausing.md:1-60`
- https://cisco.github.io/ChezScheme/csug10.0/foreign.html (§4.3 Calling into Scheme; §4.4 Continuations and Foreign Calls; activation) — fetched with `curl -sL … -o csug-foreign.html` and extracted with a Python tag-stripper (verbatim paragraphs quoted in §13)
- https://cisco.github.io/ChezScheme/csug10.0/control.html (§6.3 call/1cc; §6.4 engines) — same method
- https://cisco.github.io/ChezScheme/csug10.0/threads.html — via WebFetch (thread-safety and activation sentences quoted in §13)
