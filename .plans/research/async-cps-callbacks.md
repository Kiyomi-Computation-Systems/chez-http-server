# chez-http-server asynchrony model — Proposal: pure callback / CPS (Node-style)

key: `cps-callbacks`
date measured: 2026-09-19, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, chez-libuv v0.5.0, chez-httparse v0.2.0.
Author: independent proposal, one of six angles; judged against the others.

## 0. Thesis in one paragraph

Write the connection layer and the handler API directly in continuation-passing
style over chez-libuv's callbacks. No continuation is ever captured, no thread is
ever forked, no engine is ever built. Every asynchronous step is a procedure that
takes a *continuation* `k : (err value) -> unspecified` and calls it exactly once,
later, from inside some libuv callback. This is precisely the shape chez-libuv
already has (`uv-write! ... on-complete`, `uv-getaddrinfo! ... on-complete`,
`uv-read-start! on-data on-eof on-error`), so the connection layer adds no
mechanism, only discipline. The discipline is captured by about six small
combinators (§3) and one hard rule: **a callback never lets a raise reach
chez-libuv's trampoline**, because the trampoline's store-and-reraise policy stops
the whole loop for every connection (measured, §10). Two spikes were run today
(§14, Appendix A): a socket-less CPS connection core over chez-httparse that
replays a body at every chunk size, and a loopback CPS HTTP/1.1 server that
pipelines 200 requests through one connection, awaits `uv-getaddrinfo!` inside a
handler, survives a handler exception with a 500, applies the parse-ahead cap
with `uv-read-stop!`, and closes exactly once. Both work. Where this angle is
weaker than the obvious alternative (a coroutine per request) is stated in §16.

## 1. Sources read (file:line citations used throughout)

- `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` — whole file. §5 "connection object", §7 backpressure, §10 pipelining, §11 limits, §12 error model, §13 application API `(lambda (request respond) ...)`, §14 testing strategy.
- `/Users/yuzu/github/chez-libuv/docs/api.md` — whole file; the Flow control section (read buffer 64 KiB, `uv-read-stop!` guard, write-bound bookkeeping, write-queue gauge contract); Signals (`uv-signal-start-oneshot!` sigterm pattern); DNS (`uv-getaddrinfo!` → `(err results)`); Timers.
- `/Users/yuzu/github/chez-libuv/docs/quickstart.md` — "The three rules".
- `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md:383-470, 658-720` — Q2 (raise across C; `bare` exit 255; `escape` scenario; verdict).
- `/Users/yuzu/github/chez-libuv/.plans/decisions/0007-no-guardians-explicit-close.md`, `0008-static-trampolines-and-handle-registry.md`, `0009-copy-at-the-boundary.md`, `0018-unbuffered-write-submission.md`.
- `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:47-64` (uv-run refuses re-entry: `(when (loop-running? loop) (raise (make-uv-invalid-argument 'uv-run 'loop-running)))`), `src/libuv/private/handles.sls:290-304` (`loop-record-error!` stores the first error and calls `uv-loop-stop`; `dispatch-guarded` is `(guard (e (#t (loop-record-error! loop e))) (thunk))`), `:314-315` ("Handle callbacks require open state; request callbacks remain deliverable while their handle is closing"), `:390-417` (`read-dispatch`: `on-data` gets `(copy-out buf nread) 0 nread`, EOF and error are separate deliveries), `:421-430` (`close-dispatch` frees read buffer then handle, then runs `on-close`), `:479-486` (`real-close-handle!`: `(when (eq? (handle-state handle) 'open) ...)` — a second close stores nothing).
- `/Users/yuzu/github/chez-libuv/src/libuv/stream.sls:20-60` (`uv-write!` signature and copy-in), `:76-104` (`uv-read-start!`, `start-reading!`, buffer fixed at first start).
- `/Users/yuzu/github/chez-libuv/src/libuv/timer.sls:17-33`, `dns.sls:73-82`, `signal.sls:59-63`, `tcp.sls:137-140` (signatures).
- `/Users/yuzu/github/chez-libuv/tests/test-echo.sps:203-256` (the canonical server shape: three closures per peer, shutdown-then-close from the shutdown callback, `guard` around `uv-accept!`), `tests/uv-testing.sls:14-19,157-165` (`bind-loopback!`, `connect-loopback!`).
- `/Users/yuzu/github/chez-httparse/docs/api.org` — whole file (25 callbacks all required; span callbacks index the caller's bytevector; `callback-continue`/`callback-pause`/failure; `on-headers-complete` decision; `on-reset` between pipelined messages; `parser-field-ref`; `parser-resume!`; `parser-finish!`).
- `/Users/yuzu/github/chez-httparse/docs/conformance.org:38-45` ("Every in-scope fixture is replayed at every chunk size from 1 to its length and the parser's rendered trace is compared byte for byte").
- `/Users/yuzu/github/chez-httparse/src/httparse/grammar.sls:301-306` (`F-CONNECTION-KEEP-ALIVE 1`, `F-CONNECTION-CLOSE 2`, `F-CONNECTION-UPGRADE 4`, `F-CHUNKED 8`, `F-UPGRADE 16`, `F-CONTENT-LENGTH 32` — NOT exported; `src/httparse/modes.sls:17-19` exports only the lenient-flag helpers).
- `/Users/yuzu/github/chez-httparse/test/common/allocation-tests.sps:1-45,70-92` and `test/support/harness/httparse/test/harness.sls:182-192` (`adapter-bytes-allocated` is `(sstats-bytes (statistics))`, cumulative; Chez's `bytes-allocated` is live heap and goes negative across a GC — I reproduced exactly that mistake, Appendix A.4).
- `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:1140-1160` (a callback pause parks the parser *past* the delivered event: "Resume continues after that event; it is never delivered twice"; result is `(make-parser-result 'paused pos (- pos start) ...)`, i.e. `consumed` is relative to this feed's `start`).
- Chez Scheme User's Guide 10.0: <https://cisco.github.io/ChezScheme/csug10.0/foreign.html>, <https://cisco.github.io/ChezScheme/csug10.0/control.html>, <https://cisco.github.io/ChezScheme/csug10.0/threads.html> (quotes in §15).

## 2. What "pure CPS" means here, precisely

Conventions (the whole "framework" is these five lines of policy):

1. **A step** is `(lambda (k) ...)`. **A continuation** `k` is a procedure of two arguments `(err value)`; `err` is `#f` on success, otherwise a condition or a symbol. Node's `(err, value)` order is kept so that every chez-libuv completion callback (`(lambda (err) ...)`, `(lambda (err results) ...)`) adapts with a one-line wrapper or none.
2. **Exactly once.** A step calls `k` once, later or now. "Now" is allowed (synchronous completion is not an error) — so a caller must never assume its code after a step call runs before `k` does.
3. **Never raise across a step boundary.** Every step body is wrapped in `cps-guard`, which converts a synchronous raise into `(k e #f)`. This is what keeps chez-libuv's `dispatch-guarded` from ever seeing a condition (§10).
4. **No captured continuations, no threads, no engines.** `call/cc`, `call/1cc`, `fork-thread`, `make-engine` do not appear in the server. Nothing in this proposal depends on invoking a continuation captured inside a `foreign-callable` after it returned (§15).
5. **State lives in records, not in the stack.** Because each libuv callback returns to C before the next one fires, all connection state must be reachable from the connection record. This is a feature: the connection record *is* the functional core's state value (§13).

## 3. The combinators (~60 lines, the entire runtime support)

```scheme
;; k : Err Any -> Unspecified     Err = #f | Condition | Symbol
;; Step : (Err Any -> Unspecified) -> Unspecified

;; cps-guard : Step K -> Unspecified
;; A synchronous raise inside `step` becomes (k e #f). It does NOT protect code
;; running later inside other callbacks -- each of those wraps itself.
(define (cps-guard step k)
  (guard (e (#t (k e #f))) (step k)))

;; once : K -> K   -- enforce "exactly once"; the second call is a bug we want to see.
(define (once k)
  (let ((called #f))
    (lambda (err v)
      (if called
          (internal-error 'continuation-called-twice err v)   ; §10: recorded, never raised into libuv
          (begin (set! called #t) (k err v))))))

;; cps-bind : Step (Any -> Step) -> Step     -- sequencing ("then")
(define (cps-bind step f)
  (lambda (k)
    (cps-guard step (lambda (err v) (if err (k err #f) (cps-guard (f v) k))))))

;; cps-seq : Step ... -> Step                 -- run in order, stop at the first error
(define (cps-seq . steps)
  (lambda (k)
    (let loop ((ss steps) (last #f))
      (if (null? ss) (k #f last)
          (cps-guard (car ss) (lambda (err v) (if err (k err #f) (loop (cdr ss) v))))))))

;; cps-each : (Listof A) (A -> Step) -> Step  -- ordered iteration
(define (cps-each items f)
  (lambda (k)
    (let loop ((xs items))
      (if (null? xs) (k #f #f)
          (cps-guard (f (car xs)) (lambda (err v) (if err (k err #f) (loop (cdr xs)))))))))

;; cps-while : (-> Boolean) Step -> Step      -- async loop; the body is re-entered
;; from the completion callback, so a million iterations use O(1) stack.
(define (cps-while more? body)
  (lambda (k)
    (let loop ()
      (if (more?) (cps-guard body (lambda (err v) (if err (k err #f) (loop)))) (k #f #f)))))

;; cps-all : (Listof Step) -> Step            -- run concurrently, gather in order
(define (cps-all steps)
  (lambda (k)
    (let* ((n (length steps)) (out (make-vector n #f)) (left n) (failed #f))
      (if (zero? n) (k #f '())
          (let loop ((i 0) (ss steps))
            (unless (null? ss)
              (cps-guard (car ss)
                         (lambda (err v)
                           (cond (failed #f)
                                 (err (set! failed #t) (k err #f))
                                 (else (vector-set! out i v) (set! left (- left 1))
                                       (when (zero? left) (k #f (vector->list out)))))))
              (loop (+ i 1) (cdr ss))))))))
```

One caveat about `cps-while`/`cps-each`: if `body` completes *synchronously* (calls `k` before returning), `loop` recurses on the Scheme stack. Chez's stack is segmented and grows on demand, so this is not a crash, but a million synchronous iterations would be a million live frames until the last one returns. The connection driver's pump (§5.3) is written to bound such recursion by the pipelining cap.

The spike (`scratchpad/spike/cps-server.sps:23-33`) used only `cps-guard` and `cps-each`; that was enough to build the whole server. The rest exist for handlers.

## 4. Handler API

The architecture plan's target is `(lambda (request respond) ...)` (architecture.md §13). In CPS that is already the natural shape: `respond` is the continuation of the request. The library adds a *streaming* variant and a *body-reader* to the request record.

```scheme
;; A handler : Request Responder -> Unspecified
;; Request accessors (all pure over a record built by the parser callbacks, §5.2):
;;   http-request-method   : Request -> Symbol            ; llhttp method number mapped once
;;   http-request-target   : Request -> Bytevector        ; raw; uriparse on demand
;;   http-request-headers  : Request -> (Listof (Pair Bytevector Bytevector))
;;   http-request-loop     : Request -> UvLoop            ; for uv-getaddrinfo!, timers, ...
;;   http-request-read-body! : Request K -> Unspecified   ; k gets (err chunk-or-#f); #f = end
;; Responder:
;;   (respond status headers body-bytevector)                       ; (1) one shot
;;   (respond status headers 'stream) -> Sink                       ; (2) streaming
;;   sink-write! : Sink Bytevector K -> Unspecified                  ; k fires on write completion
;;   sink-end!   : Sink K -> Unspecified
;;   sink-writable? : Sink -> Boolean                                ; outstanding bytes < high-water
```

### 4.1 Trivial respond

```scheme
(define (hello req respond)
  (respond 200 '(("Content-Type" . "text/plain")) (string->utf8 "hello\n")))
```

Nothing async: `respond` serializes head+body into one bytevector, calls
`uv-write!`, and the connection's `on-complete` continuation advances the
pipeline (§5.3). The handler returns immediately.

### 4.2 Streaming a large response with backpressure

```scheme
;; Stream N chunks of a generated body; never queue more than the sink's high-water mark.
(define (big req respond)
  (let* ((sink (respond 200 '(("Content-Type" . "application/octet-stream")) 'stream))
         (i 0) (n 100000))
    ((cps-while (lambda () (< i n))
                (lambda (k)                          ; one chunk per step
                  (set! i (+ i 1))
                  (sink-write! sink (make-chunk i) k)))   ; k fires when libuv completed THIS write
     (lambda (err v)
       (if err
           (sink-abort! sink err)                    ; connection layer closes; nothing else to do
           (sink-end! sink (lambda (err v) #f)))))))
```

`sink-write!` calls `k` from the write's `on-complete`, so the producer is
naturally paced at one-write-in-flight. For more throughput, `sink-write!`
can call `k` *immediately* while `outstanding-bytes < high-water` and defer
it otherwise (the connection records the deferred `k` and calls it from the
next `on-complete` that drops outstanding bytes below `low-water`). Both
are pure CPS; the second is the "drain" event of Node streams without an
event emitter. The connection layer tracks `outstanding-bytes` and
`outstanding-requests` exactly as api.md "Bounding write memory" prescribes
(increment only after `uv-write!` returns, decrement in `on-complete`), and reads
`uv-stream-write-queue-size` only as a congestion hint (ADR-0018).

### 4.3 Consuming a large request body incrementally

```scheme
;; Hash the body without ever holding more than one delivery.
(define (upload req respond)
  (let ((h (make-hasher)))
    (let pull ()
      (http-request-read-body! req
        (lambda (err chunk)
          (cond (err (respond 400 '() (string->utf8 "bad body\n")))
                ((not chunk) (respond 200 '() (hasher-digest h)))     ; end of body
                (else (hasher-add! h chunk) (pull))))))))
```

Under the hood (§5.2 `on-body-data`): if a reader `k` is waiting, the span is
copied and handed to it and the parser continues; if none is waiting, the
copy is parked in a one-slot mailbox and the callback returns
`callback-pause`. `parser-feed!` then returns `'paused` with `consumed` at the
byte after that span; the connection stores the unconsumed remainder (safe: the
bytevector is a fresh copy per delivery, ADR-0009) and, if it still holds
unconsumed bytes, calls `uv-read-stop!`. When the handler pulls, the mailbox
is emptied into `k`, `parser-resume!` runs, and the remainder is fed. **Measured
subtlety (Appendix A.2):** after a pause on the *last* body byte, the parser is
parked before a zero-width step (`on-message-complete`); the connection must
feed once more *even with an empty range*, or the message never completes.
The spike's first version hung on exactly this; the fix is one `resumed?` flag.

Body delivery order and content are identical at every chunk size 1..60 for
the test POST once body fragments are coalesced (Appendix A.2), which is the
property the corpus test in §13 asserts.

### 4.4 Awaiting an external async result (DNS)

```scheme
(define (resolve req respond)
  (uv-getaddrinfo! (http-request-loop req) "example.org" #f '((socktype . stream))
    (lambda (err results)
      (if err
          (respond 502 '() (string->utf8 "resolver failed\n"))
          (respond 200 '() (string->utf8 (uv-addrinfo-address (car results))))))))
```

That is the whole thing; `uv-getaddrinfo!`'s `on-complete` is already a CPS
continuation. The spike ran exactly this shape against `"localhost"` inside a
pipelined request and got `dns-answers=1`, a 200, and correct ordering
(Appendix A.3). A database client written for chez-libuv would look the same:
`(db-query conn sql (lambda (err rows) ...))`. Chaining three awaits is
`cps-seq`/`cps-bind`, or just nesting — which is where the "pyramid" cost of this
angle starts (§16).

## 5. The connection driver

### 5.1 libuv callback → model mapping

| chez-libuv callback | signature (source) | what the driver does |
|---|---|---|
| `uv-listen!` on-connection | `(err)` (test-echo.sps:245-256) | `guard` around `uv-accept!` (EAGAIN is a condition, not a crash); build `conn` record; `make-parser` with ctx = conn; `uv-read-start!` with the three per-conn closures; arm header deadline (§7) |
| `uv-read-start!` on-data | `(bv start end)`, fresh copy (handles.sls:405) | `conn-feed!` (§5.3); the bytevector may be retained as the pending remainder |
| on-eof | `()` | if a message is mid-parse: `parser-finish!` → 400 or drop; if responses outstanding: mark `half-closed`, finish writes, then `uv-shutdown!` → `conn-close!`; else `conn-close!` |
| on-error | `(condition)`, handle NOT closed (quickstart "EOF is not an error") | `conn-close! 'read-error` |
| `uv-write!` on-complete | `(err)`; foreign block already freed (ADR-0009) | decrement outstanding bytes/requests; on err → `conn-close!`; else call the response slot's continuation (§6) |
| `uv-shutdown!` on-shutdown | `(err)` (stream.sls:111-120 via ADR-0018) | `conn-close!` (test-echo.sps:229-236 pattern) |
| `uv-close!` on-close | `()` (handles.sls:432-434) | deregister conn from the server table, decrement live count, cancel deadline entry (§7), maybe finish graceful shutdown (§11) |
| `uv-timer-start!` on-timeout | `(timer)` (timer.sls:30-33) | the single loop tick: sweep the deadline list (§7) |
| `uv-signal-start-oneshot!` on-signal | `(sig)` | begin graceful shutdown (§11) |
| `uv-getaddrinfo!` on-complete | `(err results)` | handler-level continuation; nothing in the driver |

Every one of these bodies is wrapped by the driver in `with-conn` (§10), which
is `cps-guard` plus "drop the event if `(conn-closed? c)`".

### 5.2 The 25 parser callbacks → model mapping

The parser is constructed once per connection with **one binding list shared
by every connection** (the callbacks take the connection as `ctx`, so no
per-connection closures are needed; a fresh 25-entry list would cost 1216
bytes per connection, Appendix A.5). Flags are read *inside*
`on-headers-complete` (api.org "Reading parser state"; the inter-message reset
zeroes them — confirmed: `close?=#t` was captured there in Appendix A.1/3).

| callback | kind | driver action (all synchronous, all pure over the `conn` record except where marked) |
|---|---|---|
| `on-reset` | event | assert previous message was enqueued; nothing else (it fires *before* `on-message-begin`) |
| `on-message-begin` | event | `conn-cur := fresh request builder`; start body-limit/header-limit counters; arm header deadline |
| `on-method-data` / `-complete` | span/event | append copy / finalize method bytes → llhttp method int via `parser-field-ref 'method` |
| `on-url-data` / `-complete` | span/event | append copy, check `max-target-bytes` → `make-callback-failure 'target-too-long` |
| `on-protocol-data` / `-complete`, `on-version-data` / `-complete` | span/event | ignore spans; at `on-version-complete` read `http-major/minor` |
| `on-status-data` / `-complete` | span/event | request mode: never fire; bound to a callback that returns a failure (a check, not a comment) |
| `on-header-field-data` / `-complete` | span/event | append; count header bytes/number → failure on limit |
| `on-header-value-data` / `-complete` | span/event | append; at complete, push `(name . value)` |
| `on-headers-complete` | decision | read `flags` (`F-CONNECTION-CLOSE`, `F-CHUNKED`, `F-UPGRADE`, `F-CONTENT-LENGTH`) and declared `content-length`; enforce `max-body-bytes` when declared; HEAD/1xx/204/304 → `'skip-body` where applicable; switch deadline from header to body; `Expect: 100-continue` → **effect**: queue an interim `100 Continue` write |
| `on-body-data` | span | if a reader `k` waits: copy + deliver, `callback-continue`; else park one copy, `callback-pause` (§4.3); count bytes → failure on `max-body-bytes` |
| `on-chunk-header` / `on-chunk-complete` | event | body-limit bookkeeping only |
| `on-chunk-extension-*` (4) | span/event | ignore (bounded by header-byte limit) |
| `on-message-complete` | event | seal the request; enqueue it; **return `callback-pause`** so `consumed` marks the message boundary (Appendix A.1: `consumed=28` for a 28-byte message, second message at offset 56) |

Pausing at `on-message-complete` is the key trick: it turns llhttp's
"keep parsing into the next message" behaviour into a boundary the driver
controls, which is what makes the pipelining cap (§6) and the
`Connection: close` rule (§6) enforceable. With the pause, the driver never
feeds the bytes after a close-marked message, so llhttp's `closed-connection`
error (Appendix A.1 case 3: `code=closed-connection reason="Data after
\`Connection: close\`" offset=47`) is never reached; case 3b shows the pause
stopping at `consumed=46` with `close?=#t`.

### 5.3 The feed loop and the pump (the spike's actual code, `cps-server.sps:66-99`)

```scheme
;; conn-feed! : Conn Bytevector Nat Nat -> Unspecified
(define (conn-feed! c bv start end)
  (let ((r (parser-feed! (conn-parser c) bv start end)))
    (case (parser-result-status r)
      ((need-input) (conn-pending-set! c #f) (conn-pump! c))
      ((paused)
       (let ((next (+ start (parser-result-consumed r))))
         (conn-pending-set! c (if (< next end) (vector bv next end) #f))   ; fresh bv: safe to retain
         (parser-resume! (conn-parser c))
         (conn-pump! c)))
      ((error) (respond-error! c 400 (parser-result-error r) (lambda (err v) (conn-close! c 'parser-error))))
      (else (conn-close! c 'terminal)))))

;; conn-pump! : Conn -> Unspecified   -- the ONE scheduler of the connection
(define (conn-pump! c)
  (cond ((and (not (conn-busy? c)) (pair? (conn-queue c)))        ; 1. dispatch the head request
         (dispatch-head! c) (conn-pump! c))                        ;    then keep pumping (parse ahead)
        ((and (conn-pending c) (< (queue-length c) cap))          ; 2. parse ahead, bounded by cap
         (let ((p (conn-pending c))) (conn-feed! c (vector-ref p 0) (vector-ref p 1) (vector-ref p 2))))
        ((and (conn-pending c) (conn-reading? c))                 ; 3. cap reached with bytes buffered: stop the socket
         (when (uv-handle-open? (conn-tcp c)) (uv-read-stop! (conn-tcp c)) (conn-reading?-set! c #f)))
        ((and (not (conn-pending c)) (not (conn-reading? c)) (uv-handle-open? (conn-tcp c)))
         (uv-read-start! (conn-tcp c) (on-data c) (on-eof c) (on-error c)) (conn-reading?-set! c #t))   ; 4. resume the socket
        (else #f)))
```

Recursion depth of `pump → feed → pump` is bounded by `cap` (branch 2 stops
feeding at `cap` queued requests), so a 64 KiB delivery containing thousands of
pipelined 30-byte requests costs at most `cap` nested frames, not thousands.
The spike measured `read-stops=1` for 200 pipelined requests with `cap=4`
(Appendix A.3, second run).

In the real implementation `conn-feed!`/`conn-pump!` are the *shell*; the
decisions inside them are a pure function `conn-step : State Event -> (values
State (Listof Command))` (§13), and the shell interprets the commands
(`(write bv k)`, `(read-stop)`, `(read-start)`, `(close why)`, `(dispatch req)`).

## 6. Pipelining, response ordering, cap

Policy (architecture.md §10 "conservative implementation"):

- **Parse-ahead up to `max-pipelined` (default 8)** requests beyond the one in
  flight; beyond that, the unconsumed bytes stay in `pending` and the socket is
  read-stopped (§5.3 branch 3). Memory bound: one delivery (≤ read-buffer size)
  plus `cap` sealed request records.
- **Serial handler execution per connection (v1).** The head of the queue is
  dispatched only when `busy?` is false; `busy?` clears in the response's final
  write completion. Response order therefore equals request order by
  construction; no reordering buffer exists. This is what the spike did and
  it served 200 pipelined requests in order (199×200 + 1×500, Appendix A.3).
- **Concurrent handlers with ordered writes (v2, optional).** Each dispatched
  request gets a *response slot*; a slot's writes go straight to `uv-write!`
  only while it is the head slot, otherwise they are held in the slot (a
  Scheme-side list, bounded by `max-held-response-bytes`; exceeding it fails
  the slot with `'response-buffer-exceeded`). When the head slot ends, the next
  slot flushes its held writes and becomes head. This is a small amount of
  pure state and fits the command-stream core; it is *not* needed for v1.
- **`Connection: close` / HTTP/1.0 without keep-alive**: at
  `on-message-complete` the sealed request carries `close?` (read in
  `on-headers-complete`); the driver marks the connection `closing-after` that
  request and *does not feed* the remainder (any bytes after it are discarded,
  not parsed). After that response's final write: `uv-shutdown!` → `conn-close!`.
- **Upgrade / CONNECT**: `F-UPGRADE` at `on-headers-complete` → the driver
  seals the request, stops feeding, and hands the connection (tcp + pending
  bytes) to the handler as an opaque duplex; v1 answers 501 and closes.

## 7. Timeouts and timer economy

Deadlines: `header-timeout` (from connection open / message begin until
`on-headers-complete`), `body-timeout` (until `on-message-complete`),
`idle-timeout` (between messages on a keep-alive connection),
`response-timeout` (from dispatch until final write completion, protects
against a handler that never calls `k`) and the shutdown `drain-deadline` (§11).

**One `uv_timer_t` per loop, not per connection.** `uv_handle_size(UV_TIMER)`
= 152 bytes on this machine (Appendix A.6) — small — but each timer is also a
Scheme handle record, a registry entry, a `uv-timer-start!`/`uv-timer-stop!`
pair per state change, and above all a *close obligation*: ADR-0007 says every
handle must be `uv-close!`d explicitly and asynchronously, and a second
`uv-close!` on a closing handle discards its callback (handles.sls:479-486).
At 10k connections that is 10k extra asynchronous close protocols to get
right. Instead:

```scheme
;; The server owns ONE repeating timer (tick = 1000 ms by default) and a deadline structure.
;; Each conn carries (mutable deadline-ms) and (mutable deadline-kind).
;; Arm/disarm are field writes: O(1), allocation-free.
(define (conn-arm! c kind ms) (conn-deadline-kind-set! c kind) (conn-deadline-ms-set! c (+ (uv-now loop) ms)))
(define (conn-disarm! c) (conn-deadline-ms-set! c #f))
;; The tick: sweep. O(live connections) per second; at 10k that is 10k field reads,
;; well under a millisecond. A timing wheel of 64 buckets keyed by (deadline-ms / tick)
;; makes it O(expiring) if the sweep ever shows up in a profile.
(uv-timer-start! tick (lambda (t) (for-each-live-conn (lambda (c) (when (expired? c) (conn-timeout! c))))) 1000 1000)
```

Granularity is one tick (1 s), which is fine for header/idle/body timeouts
measured in seconds. `uv-now` is libuv's cached time, updated once per loop
iteration (api.md), so a sweep never calls the clock. `conn-timeout!` writes
`408 Request Timeout` (header/body) or nothing (idle) and calls `conn-close!`.

## 8. Limits (server policy, not grammar — architecture.md §11)

Enforced inside the parser callbacks by returning `make-callback-failure`
with a server error code, so the parser reports `'error` at the exact offset
and the driver answers with the right status before closing:

| limit | where | response |
|---|---|---|
| `max-target-bytes` (8 KiB) | `on-url-data` | 414 |
| `max-header-field-bytes`, `max-header-value-bytes`, `max-header-count`, `max-headers-total-bytes` (64 KiB) | header spans/completes | 431 |
| `max-body-bytes` (declared: `on-headers-complete`; actual: `on-body-data`/`on-chunk-header`) | | 413 |
| `max-pipelined` | `on-message-complete` count vs queue | read-stop (no error) |
| `max-outstanding-write-bytes` / `max-outstanding-writes` per connection | `sink-write!` | defer `k` (backpressure), never refuse silently |
| `max-held-response-bytes` (v2 slots) | slot | 500 + close |
| `max-connections` | on-connection | accept then `uv-close!` immediately (libuv has already accepted; closing is the only way to shed) |
| read buffer size | first `uv-read-start!` | 16 KiB default for this server (api.md "In practice": many small-message connections; 64 KiB stays configurable) |

## 9. Backpressure, both directions

**Inbound (peer → server):** two levels. (a) Parser-level: `callback-pause`
from `on-body-data` when no reader is waiting and from `on-message-complete`
always; `consumed` tells the driver where to resume. (b) Socket-level:
`uv-read-stop!` whenever `pending` holds unconsumed bytes and either the
pipeline cap is reached or a body reader has not pulled; `uv-read-start!`
(without a size argument — api.md: "a call that omits the size is always
accepted") when `pending` is empty again. The read-stop is guarded by
`uv-handle-open?` (api.md "The read-stop/read-start pairing invariant"). While
stopped, the kernel's receive buffer absorbs the peer up to `SO_RCVBUF` and TCP
flow control does the rest; api.md's measured table says this is exactly the
regime where kernel memory per connection grows (~530 KiB when data is pushed
and never read), so `body-timeout` must keep running while stopped so a
handler that never pulls cannot pin memory forever.

**Outbound (server → peer):** the driver keeps `outstanding-bytes` and
`outstanding-writes` per connection (api.md "Bounding write memory": increment
only after `uv-write!` returns, decrement in `on-complete`). `sink-write!`
calls its `k` immediately while `outstanding-bytes < high-water` (default
64 KiB) and otherwise stores `k` as the connection's `drain-k`, invoked from
the next `on-complete` that brings the count under `low-water` (16 KiB). The
gauge `uv-stream-write-queue-size` is sampled only for a log/metric and for an
optional "hard stop" (if it exceeds a platform-calibrated threshold, defer `k`
regardless), per ADR-0018 and api.md's portability warning (Unix counts
un-submitted bytes; Windows counts accepted-but-incomplete sends).

Neither direction needs anything beyond a stored `k`: backpressure in CPS is
literally "do not call the continuation yet".

## 10. Error propagation

Four classes (architecture.md §12), one rule: **the driver is the last
handler.** chez-libuv wraps every callback in `dispatch-guarded`
(handles.sls:302-304), and `loop-record-error!` (handles.sls:290-299) stores the
*first* raise, calls `uv_loop_stop`, and `uv-run` re-raises it as
`&uv-callback-error` — for *every* connection on the loop. I measured this by
accident: an arity mistake in one continuation (`(k err)` where `k` took two
arguments) produced `uv-run raised: uv-callback-error ... responses(200)=0`
(Appendix A.3, first run) — the server served nothing further. And an
unguarded raise with no `guard` around `uv-run` kills the process with exit 255
(FINDINGS.md Q2 `bare`). So:

| class | example | driver behaviour |
|---|---|---|
| transport | `ECONNRESET` in on-error; `err` in write `on-complete` | `conn-close!`; no response attempted; counted |
| parser | `parser-feed!` → `'error` (llhttp code/reason/offset) | if nothing written for this message yet: 400 with `Connection: close`, then `conn-close!`; else just close |
| policy | limit failures (§8), timeouts (§7) | mapped status (413/414/431/408) + close |
| handler exception | synchronous raise inside the handler or inside any continuation the handler passed | `cps-guard` turns it into `(k e #f)`; the dispatcher writes 500 if the response head has not been sent, otherwise aborts the response and closes. The spike's `/boom` request (`(error 'handler "deliberate")`) produced one 500 and the connection *kept serving* the remaining 198 requests (Appendix A.3) |
| handler never calls `k` | bug | `response-timeout` (§7) → 500/close; `once` catches a double call |
| driver bug | a raise inside `conn-feed!`/`conn-pump!` themselves | caught by `with-conn` at the callback boundary → `conn-close! 'internal`, condition appended to `server-internal-errors` and passed to the server's `on-internal-error` hook (default: write to stderr). In `strict` mode (tests, dev) the hook re-raises, which then reaches `dispatch-guarded` and stops the loop deterministically — the house rule "a test that passes whether the code is right or wrong is worse than no test" argues for strict in every test |

Because store-and-reraise means the *loop* stops, the top-level `http-server-run!`
wraps `uv-run` in a `guard` that logs `&uv-callback-error` (with the composed
cause), then decides: in `strict` mode re-raise; otherwise resume `uv-run`
(FINDINGS.md Q2 `store` scenario: the loop is in a defined state and a second
`uv-run` works) — but only the driver-bug path can get there, since every
other class is converted before the trampoline sees it.

`dynamic-wind`/`parameterize` do **not** span asynchronous steps in CPS: a
`(parameterize ((current-request-id ...)) ...)` established in a handler is
gone by the time its continuation runs from a later libuv callback. Logging
context must be carried in the request record. This is a real ergonomic cost
(§16).

## 11. Graceful shutdown

```scheme
(define watcher (make-uv-signal loop))
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    (uv-close! listener)                          ; 1. stop accepting (a new connection now gets RST/ECONNREFUSED)
    (server-draining-set! srv #t)                 ; 2. every response from now on adds Connection: close
    (for-each-live-conn                           ;    idle keep-alive connections close immediately
      (lambda (c) (when (conn-idle? c) (conn-close! c 'shutdown))))
    (conn-arm-server-deadline! srv drain-deadline-ms)   ; 3. tick-driven: force-close survivors
    (uv-close! watcher)))                         ; oneshot: disposition reverts to SIG_DFL, so a 2nd SIGTERM kills (api.md Signals)
```

Completion: each `on-close` decrements `live-connections`; when it reaches 0
and the server is draining, the tick timer is `uv-timer-stop!`ed and
`uv-close!`d, the loop runs dry, `uv-run` returns `#f`, and `http-server-run!`
calls `uv-loop-teardown!` (which also cancels in-flight DNS requests and drains
them, api.md DNS). Connections mid-body when the deadline passes get
`conn-close!` without a response.

## 12. Close-ownership protocol

Facts: `uv-close!` is idempotent but a second call on a `'closing` handle
stores nothing, so its `on-close` never runs (handles.sls:479-486, api.md
process notes); request callbacks (write/shutdown completions) may still fire
while the handle is closing (handles.sls:314-315); the close dispatcher frees
the read buffer unconditionally, so a retained span is a use-after-free after
close (ADR-0009 amendment) — irrelevant here because on-data hands a *copy*,
but it means no zero-copy variant can be adopted without a borrow token.

Protocol:

1. `conn-close! : Conn Symbol -> Unspecified` is the **only** call site of
   `uv-close!` for a connection's tcp handle. It sets `closed? := #t`
   synchronously (before `uv-close!`), records `why`, disarms the deadline, and
   passes the *server's* `on-close` (deregister, decrement live count, maybe
   finish shutdown). Second and later calls are no-ops (the spike:
   `closed-conns=1` with EOF, `Connection: close` and shutdown all racing).
2. Nothing else (`uv-loop-teardown!` excepted, and it runs only after the loop
   is dry) ever calls `uv-close!` on a connection handle. The teardown sweep is
   therefore never a *second* closer with a lost callback.
3. Every callback body begins `(unless (conn-closed? c) ...)`, so late write
   completions after a close are dropped (their `k` is not called; the request
   is already dead). `outstanding-bytes` bookkeeping still runs so the
   server-wide total stays honest.
4. The shutdown-then-close sequence (`uv-shutdown!` on-shutdown → `conn-close!`,
   test-echo.sps:229-236) is the *normal* close; `conn-close!` directly is the
   *abort* close. Both go through step 1.

## 13. Testability under FCIS / TDD / mutation

**Functional core.** `(chez-http-server connection-core)`: a pure module.

```scheme
;; conn-step : ConnState Event -> (values ConnState (Listof Command))
;; Event   = (data bv start end) | (eof) | (read-error cond) | (write-done slot err)
;;         | (handler-done slot err) | (body-pull slot) | (tick now-ms) | (shutdown)
;; Command = (feed bv start end) | (write slot bv) | (read-stop) | (read-start) | (close why)
;;         | (dispatch request) | (deliver-body slot chunk-or-#f) | (arm kind ms) | (disarm)
```

The parser sits *inside* the core (it is itself pure over its record and the
caller's bytevector), driven by the `feed` command, which the core issues to
itself; the 25 callbacks fold into the builder record and produce only
`enqueue`/`park-body`/`limit-failure` — data, not effects. Everything with a
`uv-` prefix lives in the shell `(chez-http-server connection-driver)`, which
is the ~40-line interpreter of `Command` from §5.3 plus `with-conn`.

**Corpus replay through the connection layer, without sockets.** For each
of the 274 llhttp fixtures (`/Users/yuzu/github/llhttp/test/request/*.md` etc.,
vendored and checksummed in chez-httparse), for each chunk size 1..len:
construct a fresh `ConnState`, push `(data chunk)` events, interpret only the
*pure* commands (feed back into the core; record `write`, `read-stop`,
`read-start`, `dispatch`, `close`), answer every `dispatch` with a canned
`handler-done`. Assert the recorded command stream equals the whole-buffer
stream **after coalescing adjacent body deliveries** (Appendix A.2: raw event
streams legitimately differ in fragment count; coalesced ones must not).
Cost: the same order as chez-httparse's own conformance lane, which already
runs every fixture at every chunk size. Add: (a) the pipelined fixtures must
produce `dispatch` commands whose count and order match the fixture's message
count; (b) a `Connection: close` fixture followed by garbage must produce no
second `dispatch` and no parser error (§6); (c) a pause at the last body byte
must still yield `dispatch` (the zero-width step, §4.3) — this test fails
against the first spike version and passes against the second: watched to fail.

**With sockets.** The same driver behind a loopback server, one loop, an
in-process client (test-echo.sps / uv-testing `bind-loopback!`,
`connect-loopback!`), iteration caps instead of wall-clock timeouts
(test-echo.sps:98-102). A sample of fixtures × a sample of chunk sizes, with
the client writing the fixture in those chunks and (optionally) `uv-read-stop!`
on its own side to force the server's write backpressure path. `strict` mode
on, so any driver raise fails the run instead of being logged.

**Mutation discipline** (AGENTS.md; chez-httparse AGENTS.md "Mutate by
inverting a branch, not by collapsing one"): invert `(< queue-length cap)` →
the read-stop test fails; invert `close?` → the after-close discard test
fails; drop the `resumed?` re-feed → the zero-width test fails; make
`conn-close!` non-idempotent → the "on-close ran exactly once" counter
fails; replace `callback-pause` at `on-message-complete` with
`callback-continue` → the pipelining boundary test fails (consumed ≠ 28).
Each is a one-token mutation with a named red row.

**Handler tests** are plain: a handler is a procedure taking `(req respond)`;
call it with a fake `respond` that records its arguments and a fake request
whose `read-body!` feeds canned chunks. No loop needed. Awaiting DNS in a test
needs either the real loop (offline-deterministic per chez-libuv ADR-0013) or
a request-record hook that lets the test substitute the resolver — the
`http-request-loop` accessor is the seam.

## 14. Performance

Measured (Appendix A):

| quantity | value | source |
|---|---|---|
| parser alone, one keep-alive GET (4 headers), silent bindings | 1600 B allocated / request | A.4 (4b) |
| CPS core with request builder copying method, URL, 3 header pairs, pause+resume | 2672 B / request | A.4 (4) |
| loopback server + in-process client, 200 pipelined GETs, one connection, incl. client-side accumulation and response serialization | 5863 B / request (upper bound on the server's share) | A.3 |
| `make-parser` with shared bindings | 1072 B / connection | A.5 |
| a per-connection 25-entry binding list (avoid) | +1216 B / connection | A.5 |
| `uv_handle_size(UV_TCP)` / `(UV_TIMER)` / `uv_req_size(UV_WRITE)` / `(UV_GETADDRINFO)` / `(UV_SHUTDOWN)` | 264 / 152 / 192 / 320 / 96 B | A.6 |
| chez-libuv read buffer per connection | 65536 B by default, 16384 if requested at first `uv-read-start!` | api.md Flow control table (~625 MiB vs ~160 MiB at 10k) |

Per-connection resident estimate (16 KiB read buffer): 16384 (foreign) + 264
(`uv_tcp_t`) + 1072 (parser) + ~300 (conn record, three read closures, registry
entry) ≈ 18 KiB; with the default 64 KiB buffer ≈ 67 KiB. The 64 KiB buffer
dominates everything the CPS model adds by more than an order of magnitude —
the decision that matters at 10k connections is the buffer size, not the
asynchrony model.

Continuation/thread cost: zero. There is no captured continuation, no
stack copy, no thread stack (a Chez thread would carry a C stack of platform
default size, typically 512 KiB–8 MiB of address space each), no engine timer
interrupts. Each pending asynchronous step costs one closure (a few words plus
free variables) — on the order of 32–96 bytes — which is what the 2672 B
figure already includes. Every libuv callback returns to C with an empty
Scheme stack, so `uv-run`'s C frame depth is constant.

Throughput was not measured (loopback single-connection numbers would mostly
measure the kernel); the allocation figures are the ones the collector's cost
scales with.

## 15. Chez assumptions (stated, with quotes)

1. **Not relied upon: invoking a continuation captured inside a
   `foreign-callable` after that callable returned.** CPS never captures one.
   For the judges' spike: CSUG 10.0 foreign.html §4.4 says "One implication of
   this mechanism is that the C stack pointer is not automatically restored to
   its base value when a continuation is used on the Scheme side to perform a
   nonlocal exit" and "A foreign context becomes stale after a normal return to
   the context or after a return to some other foreign context beneath it on
   the control stack", with the system "trapping attempts to return to stale
   foreign contexts". Reading: returning *into* a returned callable is trapped;
   escaping *out* works (FINDINGS.md Q2). Whether a continuation captured
   inside a callable may be *resumed later from a different callable* — which
   is what a coroutine design needs — is exactly the stale-context question
   and is left to the live spike. This proposal is correct either way.
2. **Relied upon:** a `guard` established inside a `foreign-callable` that
   catches and does *not* escape is safe. chez-libuv itself depends on this
   (`dispatch-guarded`, handles.sls:302-304) and its test suites pass on both
   platforms; my `cps-guard` is the same construct one level up.
3. **Relied upon:** allocation and garbage collection inside a
   `foreign-callable` are ordinary. test-echo.sps calls `(collect)` inside
   every callback ("design spec S11's GC-pressure rule", test-echo.sps:68).
4. **Relied upon:** callbacks run only on the loop thread, one at a time, and
   `uv-run` refuses re-entry from a callback (loop.sls:55-56). Hence no
   mutex around connection state; the registry is an unsynchronised
   eqv-hashtable and this design never touches it from another thread.
   threads.html: "Threads created by foreign code using some means other than
   fork-thread must call Sactivate_thread ... before touching any Scheme data"
   — not relevant here because libuv's threadpool never runs Scheme (api.md
   DNS: "no Scheme ever runs off the loop thread").
5. **Relied upon:** Chez's segmented stack makes synchronous recursion in the
   pump safe up to `cap` frames (bounded by design anyway).
6. **Assumed, unmeasured:** closure allocation per step is on the order of a
   few dozen bytes; the 2672 B/request figure bounds it.
7. Not used, for the record: `call/1cc` ("A one-shot continuation should not
   be returned to multiple times", control.html), engines
   ("engine-block ... create a new engine capable of continuing the
   computation"), `fork-thread`.

## 16. Risks, and where CPS is simply worse

1. **Continuation arity and exactly-once are unchecked by the language.** I
   hit both failure modes in a 200-line spike: `(k err)` for a two-argument `k`
   stopped the whole loop (Appendix A.3, run 1); a shutdown-ordering mistake
   hung the process (never a `k`, so nothing ever completed). `once` catches
   double calls at runtime; nothing catches a forgotten call except
   `response-timeout`. A coroutine model turns both into ordinary returns.
2. **The pyramid.** A handler that awaits three things in sequence and
   streams a body is three nested lambdas plus a `cps-while`; `cps-seq`/`cps-bind`
   flatten it into a monadic pipeline, which is readable but foreign to most
   Scheme programmers and hostile to `let`-style local naming across steps.
   `define-syntax` sugar (`(async-let* ((rows (db-query ...)) ...) body)`) is
   possible and recommended if this angle is chosen, but then the codebase has
   a second sub-language.
3. **Dynamic extent does not survive a step.** `parameterize`,
   `with-exception-handler`, `dynamic-wind`, `current-output-port` redirection —
   none of them span an await. Request-scoped context must be explicit in the
   request record. Coroutines keep dynamic extent naturally.
4. **Stack traces stop at the callback.** A condition raised in a continuation
   shows the libuv trampoline as its root, not the handler that scheduled it.
   Mitigation: `cps-guard` wraps the condition with the request id and step
   name (a `&who` + message), cheap but manual.
5. **Every boundary needs `cps-guard`.** Forgetting one lets a raise reach
   `dispatch-guarded`, which stops the loop for every connection. The
   `with-conn` wrapper covers the driver's own callbacks; handlers are covered
   by the dispatcher; but a handler that hands its *own* lambda to
   `uv-getaddrinfo!` is guarded only if the framework's `http-request-loop`
   returns a proxy — recommended: `http-await : Request (K -> Unspecified) K ->
   Unspecified` that wraps the continuation, and documentation that raw
   `uv-*` calls are allowed but unguarded.
6. **Synchronous completion re-entrancy.** A step that calls `k` before
   returning (cache hit, empty body) runs the rest of the pipeline *inside* the
   caller's frame; state mutated after the call sees the future. Rule 2 (§2)
   exists for this; it is a class of bug a scheduler-based model does not have.
7. **The httparse flag constants are not exported** (grammar.sls:301-306) —
   the server must restate llhttp's integers and pin them with a test against
   `parser-field-ref` on known inputs (as the spike did for `F-CONNECTION-CLOSE`).
   Not CPS-specific, but every proposal inherits it.
8. **Zero-width step after pause** (§4.3) is a byte-machine contract the
   driver must know; it is documented in runtime.sls:1144-1148 but easy to miss.
   Not CPS-specific either; discovered here because CPS made the feed loop
   explicit.
9. **Where CPS is plainly worse than the obvious alternative (one coroutine
   per connection over `call/1cc` or threads):** handler authoring ergonomics
   (1–4 above). Where it is plainly better: zero dependence on the
   continuation-across-C question (§15.1), zero per-request control-state
   cost, the smallest possible surface over chez-libuv (the binding is already
   CPS), a trivially pure core (§13), and deterministic single-threaded
   execution with no scheduler to test. If the live spike shows that
   continuations captured inside a callable can be resumed from another one,
   the ergonomic gap can be closed *later* by building `await` on top of this
   driver without changing it; the reverse is not true.

## Appendix A — Commands and verbatim output

All spike sources are in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/`
(`cps-core.sps`, `cps-server.sps`, `parser-alloc.sps`, `sizes.sps`). Nothing
was written into any git repository.

### A.1 / A.2 / A.4 — Spike A, socket-less CPS core over chez-httparse

Command:

```
cd .../scratchpad/spike && chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program cps-core.sps
```

Final output (verbatim):

```
1a status=paused consumed=28 (first message is 29 bytes) offset=28
1a resume -> feed-ready
1b status=paused consumed=28 offset=56
1b events of 2nd message (oldest first): (begin method url protocol version field value (headers-complete flags 0 cl 0) complete)
1b urls: (/a /b)
2 whole-buffer: pauses=2 body="hello world"
2 every chunk size 1..60: body identical=#t, coalesced-event-sequence identical=#t, distinct pause counts=(2 3 4 5 7 12)
3 status=error consumed=47 done=1 close?=#t
3 error code=closed-connection reason="Data after `Connection: close`" offset=47
3b with pause-on-complete: status=paused consumed=46 (first msg = 47 bytes) close?=#t
4 bytes allocated per request (parser + builder copies of method/url/3 headers): 2672
4b bytes allocated per request, parser alone (silent bindings, no pause): 1600
```

Notes: the "(first message is 29 bytes)" label is my arithmetic error in the
print string; `"GET /a HTTP/1.1\r\nHost: x\r\n\r\n"` is 28 bytes and `consumed=28` is
correct. Likewise "first msg = 47 bytes" should read 46. `on-reset` does not
appear in the second message's event list because it fires *before*
`on-message-begin` creates the new builder, so it was recorded on the previous
builder — consistent with api.org ("`on-reset` fires between pipelined
messages on one parser, before `on-message-begin` of the next").

Earlier runs of the same file, kept as evidence of two findings:

```
2 every chunk size 1..60: body identical=#f, event-sequence identical=#f, distinct pause counts=(2 3 4 5 7 12)
```
(raw event sequences differ by body fragment count; coalescing fixes the
comparison — §13.)

```
Exception in car: () is not a pair
```
(first version: after a pause on the last body byte, `ctx-done` was empty
because `on-message-complete` is a zero-width step needing one more feed —
§4.3.)

```
4 bytes allocated per request (parser + builder copies of method/url/3 headers): -87
4b bytes allocated per request, parser alone (silent bindings, no pause): -77
```
(using Chez `bytes-allocated`, which is live heap; switched to
`(sstats-bytes (statistics))` as chez-httparse's harness does, harness.sls:182-192.)

### A.3 — Spike B, loopback CPS HTTP/1.1 server

Command:

```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/Users/yuzu/github/chez-libuv/tests:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src chez --program cps-server.sps
```

Run 1 (continuation arity bug `(k err)` vs `(lambda (err v) ...)` inside the
DNS completion — the store-and-reraise policy stopped the loop):

```
uv-run raised: uv-callback-error
uv-run result=raised client-eof=#f responses(200)=0 responses(500)=0 dns-answers=1 closed-conns=0
server conn: served=0 read-stops=0 queue-left=0 pending=#t out-bytes=0
bytes allocated during uv-run (server+client, N=200): 27200 total, 136 per request
```

Run 2 (arity fixed; pump did not parse ahead, so the cap never triggered):

```
uv-run result=#f client-eof=#t responses(200)=199 responses(500)=1 dns-answers=1 closed-conns=1
server conn: served=200 read-stops=0 queue-left=0 pending=#f out-bytes=0
bytes allocated during uv-run (server+client, N=200): 1164400 total, 5822 per request
```

Run 3 (pump keeps pumping after a dispatch; cap=4 → one `uv-read-stop!`, later `uv-read-start!`):

```
uv-run result=#f client-eof=#t responses(200)=199 responses(500)=1 dns-answers=1 closed-conns=1
server conn: served=200 read-stops=1 queue-left=0 pending=#f out-bytes=0
bytes allocated during uv-run (server+client, N=200): 1172688 total, 5863 per request
```

An earlier version hung (killed by a 45 s watchdog): the client's EOF closed
the client handle but nothing closed the listener, so `uv-run 'default` never
returned. Fixed by closing the listener from the client's EOF callback
(spike-only shutdown; the real server's path is §11).

### A.5 — per-connection parser allocation

```
chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program parser-alloc.sps
make-parser (shared bindings): 1072 bytes each
a fresh 25-entry binding list per connection would add: 1216 bytes each
```

### A.6 — libuv handle/request sizes on this machine

```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program sizes.sps
uv_handle_size(12) = 264      ; UV_TCP
uv_handle_size(13) = 152      ; UV_TIMER
uv_handle_size(16) = 152      ; UV_SIGNAL
uv_req_size(2) = 96           ; UV_SHUTDOWN
uv_req_size(3) = 192          ; UV_WRITE
uv_req_size(5) = 320          ; UV_GETADDRINFO
libuv 1.52.1 chez Chez Scheme Version 10.4.1 machine tarm64osx
```
(Full table of indices 0..17 / 0..7 in the run output; enum order is libuv's
`UV_HANDLE_TYPE_MAP`/`UV_REQ_TYPE_MAP` in `uv.h`: TCP=12, TIMER=13, SIGNAL=16;
SHUTDOWN=2, WRITE=3, GETADDRINFO=5.)

### A.7 — CSUG quotes relied upon (fetched 2026-09-19)

- foreign.html §4.4: "One implication of this mechanism is that the C stack pointer is not automatically restored to its base value when a continuation is used on the Scheme side to perform a nonlocal exit." / "A foreign context becomes stale after a normal return to the context or after a return to some other foreign context beneath it on the control stack." / the system handles this by "trapping attempts to return to stale foreign contexts". / §4.3 on callables: "it will not be relocated by the storage management system, but it may be reclaimed if the code object becomes unreachable on the Scheme side; lock the code object (using lock-object) or otherwise retain it".
- control.html: "call/1cc obtains its continuation and passes it to procedure, which should accept one argument." / "A one-shot continuation should not be returned to multiple times, either by invoking the continuation or returning normally from procedure more than once." / engines: "This causes a running engine to stop, create a new engine capable of continuing the computation, and pass the new engine to the original engine's third argument (the expire procedure)."
- threads.html: "Threads created by foreign code using some means other than fork-thread must call Sactivate_thread (Section 4.9) before touching any Scheme data or calling any Scheme procedures." / "When a new thread is created (see fork-thread), the current value (not location) of each thread parameter is inherited from the forking thread by the new thread."
