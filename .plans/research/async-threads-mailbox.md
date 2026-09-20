# Proposal: OS threads for handlers, one loop thread for I/O (key: `threads-mailbox`)

Angle: Chez 10.4.1 threaded build. The loop thread owns every libuv handle;
handlers run on a fixed worker pool and talk to the loop through
mutex/condition mailboxes. Everything measured below was measured on this
machine on 2026-09-19 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1, 8 cores,
16 GiB); every spike script is under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spikes/`
and its verbatim output is reproduced in §12.

---

## 0. Summary (what the judges should take away)

1. **The model.** One loop thread (the main thread) runs `uv-run`, owns the
   loop, the listener, every connection handle, every timer, *and every
   parser*. N worker threads (`fork-thread`, N = cores by default, an env
   var) run handlers. The loop thread hands a worker a fully materialised
   request record via a shared job queue; the worker sends *commands* back
   (write, end, read-more, close, resolve-await) through a loop-owned inbox
   and a wakeup. Nothing except the loop thread ever calls a `uv-*`
   procedure — the handle registry is an unsynchronised `eqv` hashtable
   (`handles.sls:218`) and libuv itself is "not thread-safe except where
   stated otherwise" (libuv design doc, §12.7).
2. **The parser runs on the loop thread.** Measured: a full 25-callback
   binding that copies every span parses an 81-byte request in **1.86 µs**
   (spike E). A worker round trip through a mutex/condition mailbox is
   **3.9 µs** (spike C). Moving the parser off the loop would cost more than
   the parser does; and the parser's span callbacks index the caller's
   bytevector, which is exactly the fresh per-delivery bytevector `on-data`
   hands the loop thread (ADR-0009), so body chunks can be handed to the
   worker *without a second copy*.
3. **The wakeup mechanism — the decisive measurement of this proposal.**
   With the loop thread blocked in the binding's plain `uv-run` and nothing
   due, a worker thread that merely *allocates* stalls until the loop thread
   next returns to Scheme — **3005 ms** in spike A — because Chez's
   collector rendezvous cannot complete while a thread is active inside C
   (CSUG §4.9: "active threads operating in C code prevent the storage
   management system from garbage collecting"). This is independent of
   mailbox latency: it happens with *no* messages in flight. Therefore:
   - **Tier 1 (works today, no upstream change):** a repeating
     heartbeat timer on the loop (1 ms while any worker is busy, 50 ms when
     idle) that both drains the inbox and bounds the GC stall to one period.
     Cost: 1 ms heartbeat = ~10 ms CPU per idle second (1 %); handoff
     latency mean 573 µs (spike D).
   - **Tier 2 (recommended prerequisite, an upstream chez-libuv v0.6
     slice):** bind `uv_async` (one new locked trampoline, `async`,
     `(uptr) -> void`, the same arity as `timer`/`close`) and re-bind
     `uv_run` as `__collect_safe` with every trampoline declared
     `__collect_safe`. Spike B shows this works on raw libuv: 2000/2000
     timer fires exact with `(collect)` every 100 fires, close callback
     delivered, `uv_loop_close = 0`, and the concurrently-allocating worker's
     worst stall drops from **3001 ms to 1 ms**. Spike D shows
     `uv_async_send` from a `fork-thread`'d Scheme worker wakes the loop
     with **13 µs mean** handoff latency and 1 ms CPU per idle second.
     FINDINGS.md names exactly this experiment as the gap that "must be
     re-opened before any multi-threaded or `__collect_safe` use of
     `uv_run`"; this proposal re-opens it and reports the result.
4. **Thread-per-request is out.** One idle forked Chez thread costs
   **~244–250 KiB RSS** and **~800 KiB of Scheme-heap allocation** (spike C:
   `bytes-allocated` delta 802,400 for one idle thread). 10k in-flight
   requests as threads would be ~2.4 GiB RSS before any work. A pool of
   `cores` threads is ~2 MiB. Pool it is; the request queue in front of the
   pool is the admission-control point (503 on overflow, written by the loop
   thread without a worker).
5. **Honest verdict against the obvious alternative** (everything on the
   loop thread, CPS/callback handlers): this angle costs two mailbox hops
   (~4 µs) and stop-the-world GC across N threads per request; it *only*
   pays off when handlers do real CPU work or call blocking foreign code,
   and it adds an unkillable-thread hazard (Chez has no thread cancel).
   Where handlers are I/O-bound and cheap, the single-thread design is
   simply better. §11 lists the rest.

---

## 1. Sources read (with the facts relied on)

| Source | Fact used |
|---|---|
| `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` | §5 connection is the central abstraction; §7 backpressure via read-stop/start; §10 pipelining policy "preserve response ordering, limit outstanding"; §12 error classes; §14 socket tests list. |
| `/Users/yuzu/github/chez-libuv/docs/api.md` | `uv-read-start!` callbacks `(bv start end)`/`()`/`(condition)`; `uv-read-stop!` idempotent, guard with `uv-handle-open?`; 64 KiB read buffer fixed by the first `uv-read-start!`, freed at close; `uv-stream-write-queue-size` is "a congestion signal, not a memory gauge"; bound memory by outstanding payload bytes + request count incremented "only after `uv-write!` returns successfully"; `uv-getaddrinfo!` `(loop node service [hints] on-complete)`, "no Scheme ever runs off the loop thread"; signal oneshot SIGTERM pattern; "A second `uv-close!` silently discards its callback"; `uv-timer-start!` `(timer on-timeout timeout-ms repeat-ms)`. |
| `/Users/yuzu/github/chez-libuv/docs/quickstart.md` | The three rules: close is asynchronous; EOF is not an error; a raising callback is stored, loop stopped, re-raised from `uv-run` as `&uv-callback-error`. |
| `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md` lines 355–380 and 383–700 | Q1: "`__collect_safe` × callback re-entry … **not** exercised here … must be re-opened before any multi-threaded or `__collect_safe` use of `uv_run`". Q2: an unguarded raise exits 255; escape leaves EBUSY at teardown; store-and-reraise retained. |
| `.plans/decisions/0007-*.md` | No guardians; `uv-close!` is the only close path; leaks are visible not GC-timed. |
| `.plans/decisions/0008-*.md` | Thirteen locked trampolines, one per callback *type*; `dispatch-guarded` carries store-and-reraise; the late-install seam (`install-dispatch-procedure!`) is how a 14th (`async`) slot would be added. |
| `.plans/decisions/0009-*.md` | Reads copied out per delivery (`handles.sls:405` `(on-data (copy-out …) 0 nread)`); writes copied in and freed **before** `on-complete`; read-stop does not make a retained span safe (close frees the foreign buffer). |
| `.plans/decisions/0018-*.md` | No bounded write queue in the binding; consumer tracks outstanding bytes/requests. |
| `src/libuv/loop.sls:50–65` | `uv-run` refuses re-entry (`'loop-running`); `dynamic-wind` sets/clears `running`; pending error delivered after `uv_run` returns. |
| `src/libuv/private/handles.sls:218,302–304,390–434` | `registry` is `(make-eqv-hashtable)`; `dispatch-guarded` = `guard` + `loop-record-error!`; `read-dispatch` branches on nread; `close-dispatch` deregisters, frees read buffer, frees handle, then runs `on-close`. |
| `src/libuv/stream.sls:60–130` | `uv-write!`/`uv-shutdown!` submit immediately; `uv-read-start!` stores callbacks only after libuv accepts; `ensure-read-buffer!` fixes the size on first start. |
| `tests/test-echo.sps` | The canonical server shape: per-connection closures over a record; on-eof → shutdown → close in the shutdown callback; on-error → close; read-stop from inside a delivery, read-start from another delivery. |
| `tests/uv-testing.sls:102–125` | `run-until/ticking`: a 1 ms timer so `'once` cannot block forever; iteration caps not wall-clock. |
| `/Users/yuzu/github/chez-httparse/docs/api.org` | 25 callbacks all required; span `(parser ctx bv from to)` into the caller's bytevector, copy before returning; outcomes `callback-continue`/`callback-pause`/`make-callback-failure`; `on-headers-complete` may answer `'skip-body`; `on-reset` between pipelined messages; `parser-field-ref` `'flags 'content-length 'method …` read inside callbacks; `parser-resume!`, `parser-reset!`, `parser-finish!`. |
| `chez-httparse/src/httparse/grammar.sls:301–304` | `F-CONNECTION-KEEP-ALIVE 1`, `F-CONNECTION-CLOSE 2`, `F-CONNECTION-UPGRADE 4`, `F-CHUNKED 8` (llhttp's bits; not exported — the server layer must define them itself, and the test pins them). |
| `chez-httparse/test/support/harness/httparse/test/{corpus-load,conformance,drive}.sls` | `corpus-parse-file`, `fixture-*`; `corpus-scan-sizes length no-scan? 'full` = every size 1..len; `corpus-chunk-bounds length size`; `drive-chunk-ladder` (1 2 3 5 8 13 21 34 len for long fixtures). |
| CSUG 10 `threads.html` | quoted in §7. |
| CSUG 10 `foreign.html` §4.2/§4.3/§4.9 | quoted in §7. |
| CSUG 10 `smgmt.html` §13.1 | quoted in §7. |
| libuv `design.html`, `async.html` | quoted in §12.7. |

---

## 2. Architecture

```
                 loop thread (main)                        worker pool (N = cores)
  ┌─────────────────────────────────────────┐      ┌──────────────────────────────┐
  │ uv-run                                   │      │ worker k:                    │
  │  on-connection ─► accept, conn record    │      │  loop: job ← (dequeue jobs)  │
  │  on-data ──► parser-feed! ──► core step  │ jobs │        (guard (handler req)) │
  │        ► request complete ─────────────────────►│        post! commands ──┐    │
  │  on-eof / on-error / on-complete / timer │      │        wait on req cond │    │
  │  heartbeat|async ─► drain inbox ─► apply │◄─────┘                         │    │
  │  commands: write/end/read-more/close/… ◄─┼───────────────────────────────┘    │
  └─────────────────────────────────────────┘   inbox (mutex+list) + wake!
```

Ownership rules (enforced by construction, checked by tests):

- **Loop thread only:** every `uv-*` call, every parser, every handle, the
  connection table, the timing wheel, the inbox *drain*.
- **Worker only:** the handler body. A worker never sees a handle; it sees a
  `request` record (immutable, fully copied) and a `response` capability
  whose operations are all "post a command, maybe wait".
- **Shared, mutex-protected:** the job queue (loop → workers), the inbox
  (workers → loop), each request's *channel* record (body chunks loop →
  worker; write-credit and await results loop → worker).
- **No continuation is ever captured inside a libuv callback.** Workers
  block with `condition-wait`; the loop thread never blocks on anything but
  `uv_run`. This design is therefore insensitive to the live continuation
  spike either way (§7, assumption A6).

### 2.1 Where the parser runs, and why

The parser runs on the loop thread, inside `on-data`. Three reasons:

1. Cost: 1.86 µs/request for parse + 25 callbacks + span copies (spike E);
   a mailbox hop is 3.9 µs round trip (spike C). Shipping raw bytes to a
   worker to parse would double the hops for pipelined connections and cost
   more than it saves.
2. Backpressure decisions (`uv-read-stop!`, `callback-pause`) are taken
   *inside* parser callbacks and must be executed on the loop thread
   anyway. Parsing elsewhere would turn every backpressure decision into a
   cross-thread message with a race against the next delivery.
3. Ordering: the parser is the thing that knows message boundaries; keeping
   it with the connection record makes pipelining a local queue, not a
   distributed one.

What is copied where: header spans are appended into a per-request builder
on the loop thread (they may straddle deliveries). Body spans are **not
copied**: `on-body-data` receives `(bv from to)` where `bv` *is* the fresh
delivery bytevector from `read-dispatch` (`handles.sls:405`); the loop
thread pushes `(bv from to)` onto the request's body channel and the worker
reads it later. Nothing mutates that bytevector after delivery, so sharing
it across threads is safe (CSUG: bytevectors are ordinary Scheme data;
sharing an unmutated object needs no lock).

---

## 3. Handler API (worker side)

```scheme
#!r6rs
;; (http handler-api) -- what a handler sees. Every procedure here is called
;; ON A WORKER THREAD and never touches libuv.
(library (http handler-api)
  (export request-method request-target request-version request-headers
          request-header-ref request-content-length request-chunked?
          request-read-body!            ; (3) incremental body
          respond!                      ; (1) trivial
          response-start! response-write! response-end!   ; (2) streaming
          await                          ; (4) external async result
          handler-context-loop-call!)
  (import (rnrs) (only (chezscheme) make-mutex make-condition with-mutex
                       condition-wait condition-signal make-time))

  ;; request : an immutable record built by the loop thread.
  ;;   method  : Symbol            e.g. 'GET  (from llhttp's method number)
  ;;   target  : Bytevector        raw request-target (uriparse on demand)
  ;;   version : (Pair Nat Nat)
  ;;   headers : (Listof (Pair Bytevector Bytevector))  in wire order
  ;;   flags   : Nat               llhttp flag bits read inside on-headers-complete
  ;;   content-length : Nat or #f  the DECLARED length (read inside on-headers-complete)
  ;;   chan    : channel           body chunks + write credit + awaits (below)

  ;; channel : the one mutable object shared by loop thread and worker for
  ;; a request. Every field is read or written ONLY under `mutex`.
  (define-record-type channel
    (fields mutex cond
            (mutable body-chunks)      ; queue of (bv from to), oldest first
            (mutable body-bytes)       ; bytes queued and not yet read
            (mutable body-eof?)        ; loop set it: message complete or aborted
            (mutable outstanding)      ; response bytes posted, not yet on-complete
            (mutable aborted)          ; #f or a condition (transport/parse error)
            (mutable await-slot)))     ; 'empty | (cons err value)

  ;; post! : Connection Command -> unspecified
  ;; Append a command to the loop inbox and wake the loop. Thread-safe.
  ;; (Supplied by (http server); see §4.3.)

  ;; ------------------------------------------------------------------
  ;; (1) trivial respond
  ;; respond! : Response Nat (Listof (Pair String String)) Bytevector -> unspecified
  (define (respond! rsp status headers body)
    (post! (response-conn rsp)
           `(respond ,(response-id rsp) ,status ,headers ,body)))

  ;; ------------------------------------------------------------------
  ;; (2) streaming a large body with backpressure
  ;; response-start! : Response Nat Headers -> unspecified   (chunked unless Content-Length given)
  (define (response-start! rsp status headers)
    (post! (response-conn rsp) `(start ,(response-id rsp) ,status ,headers)))

  ;; response-write! : Response Bytevector -> unspecified
  ;; Blocks the WORKER while this connection's outstanding response bytes are
  ;; at or above the high-water mark. Credit is returned by the loop thread
  ;; from uv-write!'s on-complete. Raises &response-aborted if the connection
  ;; died, and &write-timeout after `write-timeout` with no progress.
  (define (response-write! rsp bv)
    (let* ((ch (response-channel rsp)) (m (channel-mutex ch)))
      (with-mutex m
        (let wait ()
          (cond ((channel-aborted ch) => (lambda (c) (raise (make-response-aborted c))))
                ((>= (channel-outstanding ch) (response-high-water rsp))
                 (unless (condition-wait (channel-cond ch) m (response-write-deadline rsp))
                   (raise (make-write-timeout)))
                 (wait))
                (else
                 ;; credit is charged HERE, on the worker, so the check above
                 ;; and the charge are one critical section.
                 (channel-outstanding-set! ch (+ (channel-outstanding ch) (bytevector-length bv)))))))
      (post! (response-conn rsp) `(write ,(response-id rsp) ,bv))))

  ;; response-end! : Response -> unspecified
  (define (response-end! rsp)
    (post! (response-conn rsp) `(end ,(response-id rsp))))

  ;; ------------------------------------------------------------------
  ;; (3) consuming a large request body incrementally
  ;; request-read-body! : Request -> Bytevector | Eof
  ;; Returns the next chunk as a fresh span copy? NO: returns the loop's own
  ;; delivery bytevector sub-range as (values bv from to) -- zero copy. The
  ;; convenience wrapper below copies. When the queue falls below low-water
  ;; the worker posts (read-more) and the loop thread does uv-read-start!.
  (define (request-read-body!/span req)
    (let* ((ch (request-channel req)) (m (channel-mutex ch)))
      (with-mutex m
        (let wait ()
          (cond ((channel-aborted ch) => (lambda (c) (raise (make-request-aborted c))))
                ((pair? (channel-body-chunks ch))
                 (let* ((item (car (channel-body-chunks ch)))
                        (n (- (cddr item) (cadr item))))
                   (channel-body-chunks-set! ch (cdr (channel-body-chunks ch)))
                   (channel-body-bytes-set! ch (- (channel-body-bytes ch) n))
                   (when (< (channel-body-bytes ch) (request-low-water req))
                     (post! (request-conn req) `(read-more ,(request-id req))))
                   (values (car item) (cadr item) (cddr item))))
                ((channel-body-eof? ch) (values (eof-object) 0 0))
                (else
                 (unless (condition-wait (channel-cond ch) m (request-body-deadline req))
                   (raise (make-body-timeout)))
                 (wait)))))))

  (define (request-read-body! req)
    (let-values (((bv from to) (request-read-body!/span req)))
      (if (eof-object? bv) bv
          (let ((out (make-bytevector (- to from))))
            (bytevector-copy! bv from out 0 (- to from)) out))))

  ;; ------------------------------------------------------------------
  ;; (4) awaiting an external async result (e.g. uv-getaddrinfo!)
  ;; await : Request (Procedure (Loop Resolve) -> unspecified) [Time] -> (values err value)
  ;; `start` runs ON THE LOOP THREAD (posted as a thunk); it must arrange for
  ;; `resolve` to be called exactly once, on the loop thread, with (err value).
  ;; `resolve` is thread-safe: it stores under the channel mutex and signals.
  (define (await req start . deadline)
    (let* ((ch (request-channel req)) (m (channel-mutex ch)))
      (with-mutex m (channel-await-slot-set! ch 'empty))
      (post! (request-conn req)
             `(loop-call ,(lambda (loop)
                            (start loop
                                   (lambda (err value)
                                     (with-mutex m
                                       (channel-await-slot-set! ch (cons err value))
                                       (condition-signal (channel-cond ch))))))))
      (with-mutex m
        (let wait ()
          (let ((slot (channel-await-slot ch)))
            (cond ((pair? slot) (values (car slot) (cdr slot)))
                  ((channel-aborted ch) => (lambda (c) (values c #f)))
                  (else
                   (unless (condition-wait (channel-cond ch) m
                                           (if (pair? deadline) (car deadline) #f))
                     (raise (make-await-timeout)))
                   (wait)))))))))
```

A handler, showing all four shapes:

```scheme
(define (handler req rsp)
  (case (request-method req)
    ;; (1) trivial
    ((GET)
     (if (bytevector=? (request-target req) (string->utf8 "/"))
         (respond! rsp 200 '(("content-type" . "text/plain")) (string->utf8 "hello\n"))
         ;; (2) a large streamed body, e.g. 1 GiB of zeros, chunked
         (begin
           (response-start! rsp 200 '(("content-type" . "application/octet-stream")))
           (let ((block (make-bytevector 65536 0)))
             (do ((i 0 (+ i 1))) ((= i 16384))
               (response-write! rsp block)))      ; blocks under backpressure
           (response-end! rsp))))
    ;; (3) consume a large upload incrementally, never buffering it whole
    ((PUT POST)
     (let loop ((total 0))
       (let ((chunk (request-read-body! req)))     ; blocks; loop re-arms reads
         (if (eof-object? chunk)
             (respond! rsp 200 '() (string->utf8 (number->string total)))
             (loop (+ total (bytevector-length chunk)))))))
    ;; (4) await a DNS lookup performed by the loop thread's libuv
    ((CONNECT)
     (let-values (((err results)
                   (await req
                          (lambda (loop resolve)
                            (uv-getaddrinfo! loop (utf8->string (request-target req)) "80"
                                             '((socktype . stream))
                                             (lambda (err results) (resolve err results))))
                          (make-time 'time-duration 0 5))))
       (if err
           (respond! rsp 502 '() (string->utf8 (symbol->string (uv-errno-error-errno err))))
           (respond! rsp 200 '() (string->utf8 (uv-addrinfo-address (car results)))))))
    (else (respond! rsp 405 '() (make-bytevector 0)))))
```

Notes on the API contract:

- A handler must call exactly one of `respond!` or
  `response-start! … response-end!`. The loop thread enforces the state
  machine (a second `start` for the same request id is a policy error →
  the connection is aborted and the bug logged); the worker cannot corrupt
  wire framing because only the loop thread serialises.
- `response-write!` charges credit *on the worker* under the channel mutex,
  so the high-water check and the charge are atomic with respect to the
  loop's `on-complete` credit return.
- The DNS example shows the general rule for anything libuv-backed: the
  worker never calls `uv-getaddrinfo!`; it ships a thunk to the loop, which
  calls it, and the completion (delivered on the loop thread, api.md: "no
  Scheme ever runs off the loop thread") resolves the worker.

---

## 4. Connection driver (loop thread)

### 4.1 Records

```scheme
(define-record-type conn
  (fields id tcp server parser builder            ; builder: current request under construction
          (mutable state)          ; 'open | 'draining | 'closing | 'closed
          (mutable reading?)       ; our belief about uv-read-start!/stop!
          (mutable read-stop-reasons) ; subset of '(pipeline body-hw write-hw peer-closed close-marked)
          (mutable paused-tail)    ; #f or (bv start end): bytes not yet fed because the parser is paused
          (mutable queue)          ; complete requests not yet dispatched, oldest first (max-pipeline)
          (mutable inflight)       ; #f or the request whose response is being produced
          (mutable outstanding-bytes) (mutable outstanding-reqs)   ; uv-write! accounting (ADR-0018)
          (mutable close-after?)   ; Connection: close seen, or HTTP/1.0 without keep-alive, or draining
          (mutable deadline)       ; timing-wheel slot (uv-now ms) or #f
          (mutable deadline-kind))) ; 'header | 'body | 'idle | 'write | 'drain
```

Exactly **one** request is in flight per connection at a time; queued
requests wait in `queue`. That single rule gives response ordering for
free and makes "cap on outstanding requests" = `(length queue) < max-pipeline`.

### 4.2 libuv callback → model

| libuv callback (chez-libuv name) | Loop-thread action |
|---|---|
| `uv-listen!` `on-connection` | If `err`: log, ignore. Else `uv-accept!` (guarded: EAGAIN is not fatal). If `(>= live-connections max-connections)`: write a canned `503` and `connection-close!`. Else make `conn` (fresh parser, `type=request`, strict), register in the server table, arm `'header` deadline, `uv-tcp-nodelay!`, `uv-read-start!` with the three closures below (buffer size from config: 16 KiB default for this server, see §10). |
| `on-data (bv start end)` | If `paused-tail` is set: append (it cannot happen — reads are stopped while paused — so this is an invariant check that raises a bug condition). Else `feed!` (§4.4). |
| `on-eof ()` | `parser-finish!`: `'finished` → nothing pending; `'error` → treat as parser error (§8). Mark `peer-closed`; `uv-read-stop!` (guarded). If nothing in flight and queue empty → `uv-shutdown!` then `connection-close!` from the shutdown callback (test-echo shape). Else let the in-flight/queued responses complete; `close-after?` := #t. |
| `on-error (condition)` | Transport error. Abort in-flight request (set `channel-aborted`, signal), drop queue, `connection-close!`. No response is attempted (the socket is gone). |
| `uv-write!` `on-complete (err)` | Decrement `outstanding-bytes`/`outstanding-reqs`. Return credit to the in-flight request's channel (`outstanding` −= n, `condition-signal`). If `err`: transport error path. If `outstanding-bytes < low-water` and `'write-hw` ∈ `read-stop-reasons`: remove reason, maybe `uv-read-start!`. If the response has ended and `close-after?` and nothing outstanding: `uv-shutdown!` → close. |
| `uv-shutdown!` `on-shutdown (err)` | `connection-close!` regardless of `err` (ENOTCONN when the peer already closed is normal). |
| `uv-close!` `on-close ()` | Deregister from the server table; free the parser (drop the reference); abort any channel still waiting (signal); decrement live count; if the server is draining and the table is empty: finish shutdown (§9). |
| timer `on-timeout` (the ONE server timer, 100 ms repeat) | (a) drain the inbox (tier 1), (b) advance the timing wheel: for every connection whose `deadline <= (uv-now loop)`: apply §6's action, (c) adapt: if inbox was non-empty or any worker is busy, ensure the heartbeat is at 1 ms (`uv-timer-set-repeat!`); if idle for > 1 s, relax to 50 ms. (Tier 2: `uv-async` drains the inbox; the timer keeps (b) and (c) at 100 ms.) |
| `uv-signal-start-oneshot!` `sigterm` | Begin graceful shutdown (§9). |
| `uv-getaddrinfo!` etc. `on-complete` | Only ever invoked from a `loop-call` thunk; the thunk's closure resolves the awaiting worker (§3 (4)). |

Every closure above is *additionally* wrapped by the server in
`(guard (e ((not (bug-condition? e)) (abort-connection! conn e))) …)`.
The binding's own `dispatch-guarded` (`handles.sls:302`) would otherwise
turn an ordinary handler-side mistake into a stopped loop and a re-raise
from `uv-run` (§8).

### 4.3 The inbox and the drain

```scheme
;; server-side, loop-owned
(define inbox-mutex (make-mutex)) (define inbox '())           ; newest first
(define (post! conn cmd)
  (with-mutex inbox-mutex (set! inbox (cons (cons conn cmd) inbox)))
  (wake-loop! (conn-server conn)))      ; tier 1: no-op (timer polls); tier 2: uv-async-send!

(define (drain-inbox! server)
  (let ((batch (with-mutex inbox-mutex (let ((b (reverse inbox))) (set! inbox '()) b))))
    (for-each (lambda (item) (apply-command! server (car item) (cdr item))) batch)))
```

`apply-command!` runs on the loop thread, under a guard, and **checks the
connection state first**: a command for a `'closing`/`'closed` connection,
or for a request id that is no longer in flight, is dropped and counted
(`late-commands` metric). That is what makes worker-side timing irrelevant
to close-ownership (§9.2).

| Command | Action |
|---|---|
| `(respond id status headers body)` | Serialise status line + headers (+ `Content-Length`, `Connection: close` if `close-after?`, `Date`); `uv-write!` head then body as two writes (no vectored writes in the binding; `uv-write*!` is reserved); account bytes; mark response ended; `finish-request!`. |
| `(start id status headers)` | As above without the body; chunked framing unless the handler gave `Content-Length`. HEAD/204/304 → body suppressed (the loop knows the method). |
| `(write id bv)` | If chunked: write `size\r\n`, `bv`, `\r\n` (three `uv-write!`s, or one copy — measure). Account. If `outstanding-bytes >= write-high-water` add `'write-hw` to read-stop reasons and `uv-read-stop!`. |
| `(end id)` | Chunked: write `0\r\n\r\n`. Mark ended; `finish-request!`. |
| `(read-more id)` | If `'body-hw` ∈ reasons and the channel's `body-bytes < low-water`: remove reason; maybe `uv-read-start!`. |
| `(handler-failed id condition)` | §8. |
| `(loop-call thunk)` | `(thunk loop)` under guard. |
| `(close id)` | Handler asked to abort: `connection-close!`. |

`finish-request!`: set `inflight` := #f; if `close-after?` and `outstanding-bytes = 0`
→ shutdown/close; else if `queue` non-empty → dispatch its head (and maybe
remove `'pipeline` from reasons → `uv-read-start!`); else arm `'idle`
deadline.

### 4.4 `feed!` and the 25 parser callbacks

```scheme
(define (feed! conn bv start end)
  (let ((r (parser-feed! (conn-parser conn) bv start end)))
    (case (parser-result-status r)
      ((need-input) (void))
      ((paused)  ; a callback returned callback-pause: pipeline cap reached
       (let ((k (+ start (parser-result-consumed r))))
         (conn-paused-tail-set! conn (list bv k end))
         (add-read-stop-reason! conn 'pipeline)))
      ((error)   (parser-error! conn (parser-result-error r)))
      ((finished stopped) (void)))))          ; not produced in request mode

(define (unpause! conn)        ; called from finish-request! when the queue has room
  (parser-resume! (conn-parser conn))
  (let ((tail (conn-paused-tail conn)))
    (conn-paused-tail-set! conn #f)
    (remove-read-stop-reason! conn 'pipeline)
    (when tail (apply feed! conn tail))))    ; may pause again; reads restart only if no reasons remain
```

The binding list (all 25, a hole is refused by `make-parser`). `ctx` is the
`conn` record. Every callback returns `callback-continue` unless stated.

| Callback | Loop-thread action |
|---|---|
| `on-message-begin` | If `(length queue) >= max-pipeline` → **`callback-pause`** (before any state changes; the resumed run re-enters here). Else reset `builder`; if this is the first message: disarm nothing; else re-arm `'header` deadline (idle → header). |
| `on-method-data` / `on-method-complete` | Append span to builder; on complete `parser-field-ref 'method` → symbol via llhttp's method table. |
| `on-url-data` / `on-url-complete` | Append; enforce `max-url-bytes` incrementally → `(make-callback-failure 'uri-too-long)` → 414. |
| `on-protocol-data` / `-complete`, `on-version-data` / `-complete` | Append (protocol kept for RTSP/ICE refusal: anything but `HTTP` → 400). Version from `'http-major`/`'http-minor` at complete. |
| `on-status-data` / `on-status-complete` | Unreachable in request mode; bound to a callback that returns `(make-callback-failure 'response-in-request-mode)` so a mode misconfiguration fails loudly (prefer a check to a comment). |
| `on-header-field-data` / `-complete` | Append; enforce `max-header-name-bytes`; `max-headers` count on complete → 431. |
| `on-header-value-data` / `-complete` | Append; enforce `max-header-value-bytes` and `max-total-header-bytes` → 431. On complete push `(name . value)` (both fresh bytevectors) onto the builder. |
| `on-headers-complete` | Read **inside** the callback: `'flags`, `'content-length` (declared), `'method`, `'upgrade`, `'http-major/minor`. Compute `keep-alive?` = HTTP/1.1 ∧ ¬CLOSE, or HTTP/1.0 ∧ KEEP-ALIVE. `close-after?` := ¬keep-alive. If `F-UPGRADE`/`CONNECT`: v1 policy → answer nothing, then 501 at message-complete and close (upgrade is out of scope). `Expect: 100-continue` → write `HTTP/1.1 100 Continue\r\n\r\n` now. Freeze the builder into an immutable `request` with a fresh `channel`; disarm `'header`, arm `'body` if a body is expected. Answer `'skip-body` never (requests). |
| `on-body-data` | Push `(bv from to)` onto the request channel (under its mutex; signal). `body-bytes += n`. If `body-bytes >= body-high-water`: add `'body-hw` reason, `uv-read-stop!` (guarded). Note the request may not be dispatched yet (pipelined behind an in-flight one); the high-water bound still holds per connection. Re-arm `'body` deadline. |
| `on-chunk-header` / `on-chunk-complete` | Re-arm `'body` deadline; nothing else (chunk sizes are the parser's business). |
| `on-chunk-extension-name-data` / `-complete`, `on-chunk-extension-value-data` / `-complete` | Ignored but bounded: total extension bytes > `max-chunk-ext-bytes` → callback failure → 400. |
| `on-message-complete` | Set `channel-body-eof?` (signal). Push the request onto `queue`; if `inflight` is #f, dispatch immediately. If `close-after?` (CLOSE flag or HTTP/1.0): add `'close-marked` reason, `uv-read-stop!`, and **do not feed the rest of this delivery** — return `callback-pause` so `parser-feed!` returns `'paused` with `consumed` at the message boundary; the tail is discarded, not stashed (measured: llhttp answers `closed-connection "Data after Connection: close"` at the first byte after the message — spike E). Arm `'idle` deadline if keep-alive and the queue is now empty. |
| `on-reset` | Reset per-message builder bookkeeping (nothing else: `flags` are already consumed into the frozen request). Invariant check: `builder` must be empty here. |

`dispatch!` = `(enqueue-job! server (lambda () (run-handler server conn req)))`
on the shared job queue (mutex + condition, workers `condition-wait`). If
the job queue length ≥ `max-queued-jobs`, the loop thread writes a canned
`503 Service Unavailable` with `Retry-After` and `Connection: close` itself
— no worker needed — and marks `close-after?`.

### 4.5 Response ordering and the pipeline cap

- Strictly one in-flight request per connection ⇒ responses go out in
  request order, and a handler cannot interleave with another handler's
  writes on the same socket.
- `max-pipeline` (default 8) bounds parsed-but-undispatched requests per
  connection; enforcement is `callback-pause` at `on-message-begin`, which
  is exact even when one 64 KiB delivery carries 4 000 tiny requests.
- The **process-wide** bound is the job queue cap; beyond it the loop
  answers 503 without a worker.
- Optional later: dispatch up to `k` pipelined requests concurrently and
  sequence their responses through a per-connection response buffer. Not in
  v1: it adds a memory bound (buffered responses) for a gain only when
  clients actually pipeline, which browsers do not.

---

## 5. Backpressure (both directions)

**Read side** — `read-stop-reasons` is a set; reads are started only when the
set is empty; every `uv-read-stop!` is guarded by `uv-handle-open?`
(api.md's pairing invariant), every `uv-read-start!` omits the size argument
(the size is fixed by the first call).

| Reason | Added | Removed |
|---|---|---|
| `'pipeline` | `on-message-begin` when `queue` is full | `finish-request!` when `queue` has room (then `unpause!` re-feeds the tail) |
| `'body-hw` | `on-body-data` when the channel holds ≥ `body-high-water` bytes (default 256 KiB) | `(read-more)` from the worker once below `body-low-water` (default 64 KiB) |
| `'write-hw` | any write that lifts `outstanding-bytes` ≥ `write-high-water` (default 1 MiB) | `on-complete` bringing it under `write-low-water` (256 KiB) |
| `'close-marked` | `on-message-complete` for a close-marked message | never (the connection closes) |
| `'peer-closed` | `on-eof` | never |

Per-connection resident input is therefore bounded by
`body-high-water + one delivery (≤ read-buffer size) + the paused tail (≤ one delivery)`.

**Write side** — two mechanisms, both consumer-owned as ADR-0018 requires:

1. Exact accounting: `outstanding-bytes` and `outstanding-reqs` per
   connection, incremented only after `uv-write!` returned normally,
   decremented in `on-complete` (api.md "Bounding write memory"). The
   worker's `response-write!` blocks on this via the channel's `outstanding`
   mirror (§3), so a fast handler streaming to a slow client parks its
   thread instead of growing foreign memory.
2. Congestion signal: the loop samples `uv-stream-write-queue-size` when it
   crosses the high-water mark and exports it as a metric; it is *not* used
   to gate writes ("a congestion signal, not a memory gauge … not a portable
   measure of kernel occupancy" — api.md). Where it earns its keep: the
   timing wheel's `'write` deadline fires only if the gauge has not moved
   since the last tick — distinguishing "peer is slow" from "peer is dead".

A subtlety this angle introduces: a worker blocked in `response-write!`
holds a pool slot. With N = 8 workers and 8 slow clients, the pool is
stalled. Mitigation: `max-blocked-writers` (default N/2); beyond it the
loop thread aborts the *oldest* stalled connection with a `'write` timeout
rather than letting the pool wedge. This is a real cost of the angle (§11).

---

## 6. Timeouts, timers, limits

**One timer handle per server**, `uv-timer-start!` at 100 ms repeat (the
same handle is the tier-1 heartbeat, re-tuned to 1 ms while busy via
`uv-timer-set-repeat!`/`uv-timer-again!`). Per-connection deadlines are a
single `(deadline . kind)` pair on the record plus a **hashed timing wheel**:
a vector of 1024 buckets of 100 ms, each a list of conns; arming is
`O(1)` (cons onto the bucket for `(deadline-ms / 100) mod 1024`), firing is
"walk the buckets between last-tick and now, re-check each conn's current
deadline (it may have been re-armed), act on the ones that are due". 10k
connections cost 10k list cells, zero extra handles. `make-uv-timer` per
connection would be 10k × (152 B foreign + registry entry + a locked-free
but still registered handle) and 10k close callbacks at shutdown — rejected.

| Kind | Armed | Fires → |
|---|---|---|
| `'header` | accept; and at `on-message-begin` after a keep-alive idle | `408 Request Timeout` + close (only if no response has started) |
| `'body` | headers-complete with a body; re-armed on every body byte/chunk | `408` if no response started, else abort |
| `'idle` | `finish-request!` with an empty queue on a keep-alive connection | close silently (no response) |
| `'write` | first `uv-write!` of a response; re-armed on every `on-complete` | abort connection (peer not draining) |
| `'handler` | dispatch | see below |
| `'drain` (server-wide) | SIGTERM | force-close everything (§9) |

**Handler timeout is the weak point of this angle.** Chez has no thread
cancel; a handler that spins or blocks forever cannot be stopped. The
`'handler` deadline therefore does *not* stop the worker: it aborts the
connection (503 if headers not sent, else close), marks the request
`aborted` (so the worker's next `response-write!`/`request-read-body!`/`await`
raises `&response-aborted` and unwinds), and counts the slot as *lost* until
the thread returns. `lost-workers` is exported as a metric; if it reaches
`N`, the server is effectively down and logs at error level. Engines could
bound *CPU* time inside a handler but not a blocking foreign call, and CSUG
warns engines are built on the timer interrupt; not used in v1.

**Limits (all from the environment, 12-factor):**
`HTTP_WORKERS` (cores), `HTTP_MAX_CONNECTIONS` (10 000),
`HTTP_MAX_PIPELINE` (8), `HTTP_MAX_QUEUED_JOBS` (4 × workers),
`HTTP_MAX_URL_BYTES` (8 KiB), `HTTP_MAX_HEADERS` (100),
`HTTP_MAX_HEADER_BYTES` (32 KiB total), `HTTP_BODY_HIGH_WATER` (256 KiB),
`HTTP_WRITE_HIGH_WATER` (1 MiB), `HTTP_READ_BUFFER` (16 384 — see §10),
`HTTP_HEADER_TIMEOUT_MS` (10 000), `HTTP_BODY_TIMEOUT_MS` (30 000),
`HTTP_IDLE_TIMEOUT_MS` (60 000), `HTTP_WRITE_TIMEOUT_MS` (30 000),
`HTTP_HANDLER_TIMEOUT_MS` (30 000), `HTTP_DRAIN_TIMEOUT_MS` (15 000).

---

## 7. GC interaction and the Chez facts relied on

### 7.1 The measured hazard

CSUG §4.9 (`foreign.html`, verbatim): *"Since active threads operating in C
code prevent the storage management system from garbage collecting, a
thread should be deactivated via Sdeactivate_thread or through a
foreign-procedure __collect_safe declaration whenever the thread may spend
a significant amount of time in C code. This is especially important
whenever the thread calls a C library function, like read, that may block
indefinitely."*

CSUG §13.1 (`smgmt.html`): *"In the threaded versions of Chez Scheme, the
collect-request handler is invoked by a single thread with all other
threads temporarily suspended."* and *"All running threads are coordinated
so that one of them calls the collect-request handler, while the other
threads pause until the handler returns."*

`uv_run` is bound plain in chez-libuv (`native.sls:242`
`(foreign-procedure "uv_run" (uptr int) int)`), and a server loop spends
almost all its time inside it, blocked in `kqueue`/`epoll`. Spike A, through
the public binding: worker allocating 64 KiB bytevectors, loop thread in
`(uv-run loop 'default)` with a single 3 s timer → `max-gap-ms=3005`; with a
1 ms repeating timer → `max-gap-ms=1`. Spike B, raw libuv, `uv_run` bound
`__collect_safe` and callables `__collect_safe`, 3 s timer →
`worker-max-gap-ms=1`, callback delivered, close delivered,
`uv_loop_close=0`; the same with plain `uv_run` → `3001`.

Consequences for the design:

- Tier 1 keeps a heartbeat timer whose period is the worst-case GC stall
  for every worker. 1 ms while busy is ~1 % of one core (spike D: 10 ms
  CPU per idle second).
- Tier 2 changes chez-libuv: `uv_run` → `__collect_safe`; all thirteen
  trampolines → `__collect_safe` (CSUG §4.2: *"If a foreign procedure that
  is called with __collect_safe can invoke callables, then each callable
  should also be declared with __collect_safe so that the callable
  reactivates the thread."*). CSUG §4.2 also: *"Refrain from passing
  collectable memory to a __collect_safe foreign procedure"* — `uv_run`
  takes only a `uptr`, and the string-typed argument prohibition does not
  apply to it. The `walk` trampoline fires synchronously inside `uv_walk`
  from an active thread; `__collect_safe` on a callable "activates a calling
  thread if the thread is not already activated" (CSUG §4.3), so it is
  harmless there.
- Stop-the-world across N+1 threads means every collection pauses all
  handlers. Keep per-request garbage small (§10), and consider
  `(collect-trip-bytes)` tuning (default here 8 388 608) and
  `thread-preserve-ownership!` on workers for parallel collection (CSUG
  §15.1: *"Provides a hint to the storage manager that thread … can
  particularly benefit from tracking the objects that it allocates for
  parallel collection."*).

### 7.2 What is safe to share, and how

- CSUG ch. 15 intro: *"Most primitive Scheme procedures are thread-safe …
  Simple mutation operators, like set-car!, vector-set!, and record field
  mutators are thread-safe. … Use of operators that are not thread-safe
  without proper synchronization can corrupt the objects upon which they
  operate."* Hashtables are not in the safe list — hence the registry rule
  and the loop-only connection table.
- Every cross-thread field in this design is read and written under a
  mutex (`with-mutex`), and every wait is `condition-wait` with a timeout
  (CSUG §15.3: *"The calling thread must have acquired the mutex … mutex is
  released as a side effect of the call to condition-wait"*; returns *"#t if
  the calling thread was awakened by the condition, #f if the calling thread
  timed out waiting"*).
- Bytevectors delivered by `on-data` are never mutated after delivery, so
  sharing `(bv from to)` triples with a worker needs no lock beyond the
  channel's queue mutex.
- `fork-thread` threads *"start in the active state and need not be
  activated"* (CSUG §4.9); `thread-join` *"Waits until thread has
  completed"* (CSUG §15.1) — used at shutdown.
- Thread parameters: *"the current value (not location) of each thread
  parameter is inherited from the forking thread"* — `current-output-port`
  etc. are fine; a per-worker logger buffer uses `make-thread-parameter`.

### 7.3 Continuations (assumption, not reliance)

CSUG §4.4: *"Scheme continuations may be used to throw control either
upwards or downwards logically through any mix of Scheme and foreign
frames."* This design does **not** capture a continuation inside any
libuv callback and never re-enters a callback's continuation after it
returned; the worker/handler blocks with `condition-wait`, not with
`call/1cc`. Whatever the live continuation spike concludes, this proposal is
unaffected. It is listed as A6 so the judges can see it was considered.

---

## 8. Error propagation

| Error class | Where detected | Loop-thread action | Worker-side effect |
|---|---|---|---|
| **Parser error** (`parser-result-status 'error`; `parser-error-code` e.g. `invalid-header-token`) | `feed!` | If no response started on this connection: write canned `400 Bad Request` (`431`/`414` for size-limit callback failures, `501` for unsupported upgrade), `Connection: close`, `uv-read-stop!`, shutdown → close. If a response is in flight: mark `close-after?`, stop reading, let it finish. The parser is dead after `'error` (api.org) — never fed again. | The in-flight request (if any) is unaffected; queued-but-undispatched requests are dropped (their channels get `aborted`). |
| **Policy error** (limits, timeouts) | callbacks / wheel | 408 / 413 / 431 / 503 as in §6, then close. | As above. |
| **Handler exception** | worker's `(guard (e (#t (post! conn `(handler-failed ,id ,e)))) (handler req rsp))` | If headers not sent: `500` + `Connection: close`. If a streaming response is mid-body: close the socket without the terminating chunk (the client sees a truncated chunked body, which is the correct signal). Log the condition with the request id. | The worker is free again. An unguarded raise in a forked thread is not an option: the guard is the job runner's, not the handler's. |
| **Transport error** (`on-error` condition; `on-complete` err; `uv-write!` raising synchronously e.g. `&uv-handle-closed`) | callbacks / `apply-command!` | `abort-connection!`: set `channel-aborted` on the in-flight request (signal), drop the queue, `connection-close!`. | Next blocking call raises `&response-aborted`/`&request-aborted`, which the job runner catches and discards (the connection is gone). |
| **Bug in the loop-thread code** (an assertion, an unexpected condition type) | the server's own guard around every callback | Re-raised. The binding's `dispatch-guarded` stores it, stops the loop, and `uv-run` re-raises it wrapped in `&uv-callback-error` (`loop.sls:64`). The server's run procedure treats that as fatal: log, begin forced shutdown with a short deadline, exit non-zero. An *unguarded* raise "kills the process" with exit 255 (FINDINGS Q2) — which is why every closure the server hands to libuv is guarded twice: once by the server (recoverable → connection abort), once by the binding (unrecoverable → stop and re-raise). |
| **Late commands** (worker posts after close) | `apply-command!` | Dropped, counted. | None. |

Store-and-reraise is respected: nothing raised in a callback ever unwinds
into libuv; the binding's policy stays the last line, and the server's own
guard makes it the line that is never reached in normal operation
(`test-lifecycle`'s counters-return-to-baseline check is the model for the
server's own "no callback ever reached `uv-loop-deferred-errors`" test).

---

## 9. Graceful shutdown and close ownership

### 9.1 SIGTERM

```scheme
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    (uv-close! listener)                          ; 1. stop accepting
    (server-state-set! server 'draining)
    (for-each (lambda (conn)                      ; 2. idle connections close now
                (when (and (not (conn-inflight conn)) (null? (conn-queue conn)))
                  (connection-close! conn)))
              (server-connections server))
    (arm-server-deadline! server 'drain drain-timeout-ms)   ; 3. deadline
    (uv-close! watcher)))                         ; second SIGTERM → SIG_DFL → kill
```

Busy connections: `close-after?` := #t so the response in flight (or the
queued ones, up to `max-pipeline`) get `Connection: close` if headers are not
yet sent and the connection is shut down after the last `on-complete`.
Reads are stopped (`'peer-closed`-like reason `'draining`) so no *new*
requests are parsed. The job queue refuses new jobs (queued ones still run).
When the `'drain` deadline fires: `abort-connection!` on everything left.
When the connection table empties (checked in `on-close`): post `'exit` to
every worker, `thread-join` them, `uv-close!` the server timer, then
`uv-loop-teardown!` — which also cancels in-flight DNS requests (api.md
"Teardown cancels, then drains"). The loop-thread order matters: workers
must be joined *before* teardown because a worker could still `post!`, and
`post!` in tier 2 calls `uv-async-send!` on a handle that teardown closes.

### 9.2 Close ownership

`connection-close!` is the **only** procedure that calls `uv-close!` on a
connection's tcp handle, and it is idempotent by the connection's own
state, not by the handle's:

```scheme
(define (connection-close! conn)
  (when (memq (conn-state conn) '(open draining))
    (conn-state-set! conn 'closing)
    (when (uv-handle-open? (conn-tcp conn))
      (uv-close! (conn-tcp conn) (lambda () (on-connection-closed! conn))))))
```

Because the binding discards the callback of a *second* `uv-close!` on a
closing handle (api.md), a design in which both a shutdown callback and an
error callback could each call `uv-close!` would lose the deregistration.
Here: the shutdown callback, the error path, the timeout path, the drain
path and the `(close)` command all call `connection-close!`; the first
wins, registers the one `on-close`, and the rest are no-ops by `state`.
Workers cannot close anything; they post. `on-connection-closed!` is the
only place a connection leaves the table, so `live-connections` and the
debug counters agree, and the test that closes a connection from two paths
in the same iteration asserts exactly one `on-close` ran.

---

## 10. Performance

Per request (loop thread): `parser-feed!` + 25 callbacks + span copies
**1.86 µs** for an 81-byte GET (spike E; byte-at-a-time feeding 6.6 µs).
Allocation per request: the header alist (one pair + two fresh bytevectors
per header), the request record, the channel record (mutex + condition +
6 fields), one job closure, ~4 command lists — on the order of 1–2 KiB of
young garbage, all dying young. `bytes-allocated` deltas in spike E were
confounded by collections and are not claimed; the follow-up measures with
`(collect-request-handler void)`.

Per request (threads): two mailbox hops. Measured round trip through two
mutex/condition pairs **3.87 µs** (20 000 round trips, spike C); the
hand-off from a worker to the loop through `uv_async_send` **13 µs mean,
422 µs max** (spike D, includes the loop's poll return), versus **573 µs
mean / 2.4 ms max** with a 1 ms polling timer and **5.3 ms / 11 ms** at
10 ms. Tier 1's latency floor is the heartbeat period; tier 2's is tens of
microseconds.

Per connection resident:

| Item | Bytes | Source |
|---|---|---|
| `uv_tcp_t` foreign block | 264 | `spike/probe` `uv_handle_size(UV_TCP)` |
| chez-libuv read buffer | 65 536 default; **16 384 proposed** | api.md flow-control table; the lever is `uv-read-start!`'s 5th argument |
| parser record | 1 104 | spike F `bytes allocated per make-parser` (the 1.7 MB `compute-size` is the shared machine, counted once per process) |
| conn record + 3 read closures + registry entry + builder | ~600 (estimate) | — |
| timing-wheel cell | 16 | — |
| **Total, 16 KiB buffer** | **≈ 18.4 KiB** → ~180 MiB at 10k | |
| Total, 64 KiB buffer | ≈ 67.5 KiB → ~660 MiB at 10k | api.md's 625 MiB figure for buffers alone |

The read-buffer size is chosen per server, not per binding default:
api.md's measurement shows 4–16 KiB "close to free" for many-connection
small-message traffic; bulk-upload servers keep 64 KiB. `HTTP_READ_BUFFER`
exposes it.

Threads: **41–57 µs to fork** a thread, **~244–250 KiB RSS** per idle
thread, **~800 KiB Scheme-heap allocation** per fork (spike C). A pool of 8
costs ~2 MiB RSS. Thread-per-request at 1 000 concurrent would be 245 MiB
RSS and 800 MB of allocation churn per 1 000 requests — that is the
number that rules it out, not creation latency.

GC: stop-the-world across N+1 threads; a collection's pause is paid by
every handler. Chez's collector is generational; young garbage per request
is cheap. The heartbeat (tier 1) or `__collect_safe` (tier 2) decides
whether a worker's collection request waits 1 ms or an unbounded time.

Idle cost: 1 ms heartbeat ≈ 10 ms CPU/s (1 %); 10 ms ≈ 3 ms CPU/s;
`uv_async`-only ≈ 1 ms CPU/s (spike D). Tier 1 relaxes the heartbeat to
50 ms when no worker is busy (a GC stall then costs ≤ 50 ms, but an idle
worker does not allocate).

---

## 11. Risks — including where this angle is simply worse

1. **It needs an upstream change to be good.** Without `uv_async` and
   `__collect_safe uv_run` in chez-libuv, the loop must poll (latency ≥
   heartbeat, 1 % idle CPU) *and* every worker's GC waits on the poll. The
   raw-libuv spikes show the change is small and works, but it is a
   chez-libuv v0.6 slice with its own ADR (a 14th trampoline; a first verb
   documented as callable from any thread; the `__collect_safe` re-binding
   of `uv_run` and all trampolines; `test-loop`/`test-native`'s frozen
   thirteen-name literal widened, watched to fail).
2. **Two hops per request, ~4 µs plus a poll or async wake.** For handlers
   that cost less than that — most "hello world" and most proxying — the
   single-threaded design wins outright on latency and throughput. This
   angle pays off only when handlers burn CPU (templating, compression,
   crypto) or call blocking foreign code (a database driver without an
   async API). If the workload is unknown, the single-thread angle is the
   safer default.
3. **Stop-the-world GC across threads.** Parallel handlers do not scale
   linearly if they allocate heavily; every collection pauses all of them.
   Not measured under load here; a risk to measure before committing.
4. **Unkillable handlers.** No thread cancel in Chez; a wedged handler
   permanently loses a pool slot. Mitigated by metrics and by the abort
   protocol, not solved.
5. **Blocked writers wedge the pool.** A worker parked in
   `response-write!` behind a slow client occupies a slot; `max-blocked-writers`
   bounds it by aborting connections, which is a worse client experience
   than a single-threaded server that simply has nothing to park.
6. **Nondeterministic tests for the threaded half.** The FCIS split (§13)
   keeps the connection state machine and the parser mapping deterministic
   and socket-free, but the pool, the inbox and the wakeup are inherently
   timing-dependent; they need iteration caps and sentinel values, not
   sleeps, and a mutation lane that can still go red *by name*.
7. **Memory-model subtleties.** Chez documents thread-safety of primitives,
   not a memory model for unsynchronised reads of `set!` variables across
   threads. This proposal never reads shared state without the mutex; a
   reviewer must hold that line (a `prefer a check` lint: no `set!` on a
   shared record outside `with-mutex`).
8. **The 64 KiB foreign read buffer is untouched by this angle**; the
   memory story at 10k connections is the read-buffer lever, identical for
   every angle.
9. **Windows** is deferred by the house rules, but nothing here is
   POSIX-specific: `fork-thread`, mutexes and conditions are Chez's, and
   `uv_async` is portable. `uv-stream-write-queue-size` semantics differ on
   Windows (api.md), which is why it is a signal only.
10. **Ordering of `uv-shutdown!` after writes** is preserved because the
    loop thread issues both in command order (ADR-0018's FIN-before-data
    hazard is exactly what a worker-side write queue would reintroduce —
    hence there is none; the worker's only queue is the loop's inbox, in
    order).

---

## 12. Evidence: commands and verbatim output

All spikes live in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spikes/`.
Nothing in any git repository was written or mutated.

### 12.0 Toolchain

```
$ chez --version
10.4.1
$ chez --program probe-threaded.sps      ; (list (threaded?) (machine-type) (collect-trip-bytes) (collect-generation-radix))
(#t tarm64osx 8388608 4)
$ sysctl -n hw.ncpu hw.memsize
8
17179869184
$ pkg-config --libs --cflags libuv
-I/opt/homebrew/Cellar/libuv/1.52.1/include -L/opt/homebrew/Cellar/libuv/1.52.1/lib -luv -lpthread -lm
$ CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program spikes/smoke.sps
libuv 1.52.1 threaded #t ok
```

`/Users/yuzu/github/chez-libuv/spike/probe` (constants): `UV_ASYNC 1`,
`UV_TCP 12`, `UV_TIMER 13`, `UV_RUN_DEFAULT 0`, `uv_handle_size(UV_TCP) 264`,
`uv_handle_size(UV_TIMER) 152`, `uv_req_size(UV_WRITE) 192`, `uv_loop_size() 1072`.

### 12.1 Spike A — GC interlock through the public binding (`spikes/a-gc-interlock.sps`)

Loop thread: `(uv-run loop 'default)` with one 3000 ms one-shot timer
(`idle`) or additionally a 1 ms repeating timer (`tick`). Worker
(`fork-thread`): 3 200 × `(make-bytevector 65536 0)`, retaining every 50th,
recording the largest gap between iterations.

```
$ CHEZSCHEMELIBDIRS=... gtimeout 60 chez --program spikes/a-gc-interlock.sps idle
mode=idle collect-trip-bytes=8388608 worker-iters=3200 worker-elapsed-ms=3033 max-gap-ms=3005 loop-elapsed-ms=3005
$ ... spikes/a-gc-interlock.sps tick
mode=tick collect-trip-bytes=8388608 worker-iters=3200 worker-elapsed-ms=31 max-gap-ms=1 loop-elapsed-ms=3000
```

Reading: 200 MiB of allocation takes 31 ms when the loop thread returns to
Scheme every millisecond, and 3 033 ms — one stall of 3 005 ms — when it
does not. The worker was blocked at its first collection request until the
loop thread's timer callback ran.

### 12.2 Spike B — `__collect_safe uv_run` on raw libuv (`spikes/b-collect-safe.ss`)

`uv_run` bound `(foreign-procedure __collect_safe "uv_run" (uptr int) int)`
(`safe`) or plain; the timer and close callables bound with the same
convention as the run; the timer callback allocates 500 pairs per fire and
calls `(collect)` every 100 fires; a worker allocates 20 000 × 64 KiB
concurrently.

```
$ gtimeout 120 chez --script spikes/b-collect-safe.ss safe 1
mode=safe period=1 fires=2000 (target 2000) closes=1 loop-ms=2319 worker-max-gap-ms=3 worker-done=#t uv_loop_close=0
$ gtimeout 120 chez --script spikes/b-collect-safe.ss plain 1
mode=plain period=1 fires=2000 (target 2000) closes=1 loop-ms=2367 worker-max-gap-ms=5 worker-done=#t uv_loop_close=0
$ gtimeout 120 chez --script spikes/b-collect-safe.ss safe 3000
mode=safe period=3000 fires=1 (target 1) closes=1 loop-ms=3000 worker-max-gap-ms=1 worker-done=#t uv_loop_close=0
$ gtimeout 120 chez --script spikes/b-collect-safe.ss plain 3000
mode=plain period=3000 fires=1 (target 1) closes=1 loop-ms=3001 worker-max-gap-ms=3001 worker-done=#t uv_loop_close=0
```

Reading: callback re-entry from a `__collect_safe` `uv_run` into
`__collect_safe` callables is exact (2000/2000, close delivered,
`uv_loop_close = 0`) under GC pressure from both the callback and a
concurrent thread; and it removes the stall entirely (1 ms vs 3001 ms).
This is the FINDINGS.md "deliberately untested" gap, now measured on one
platform (darwin/arm64); Linux must be re-run under the house CI.

### 12.3 Spike C — thread cost and mailbox latency (`spikes/c-thread-cost.ss`)

```
$ gtimeout 120 chez --script spikes/c-thread-cost.ss 100
threads=100 create-us-per-thread=41 rss-delta-kb=25008 rss-kb-per-thread=250 join-all-ms=12
mailbox round-trips=20000 total-ms=77 us-per-round-trip=3.8719
bytes-allocated delta for one idle forked thread=802400
$ gtimeout 120 chez --script spikes/c-thread-cost.ss 1000
threads=1000 create-us-per-thread=57 rss-delta-kb=244976 rss-kb-per-thread=244 join-all-ms=50
mailbox round-trips=20000 total-ms=77 us-per-round-trip=3.8605
bytes-allocated delta for one idle forked thread=802976
```

RSS via `ps -o rss= -p <pid>` before and after forking N threads that
immediately `condition-wait`. The round trip is two `with-mutex` +
`condition-signal` + `condition-wait` pairs (ping and pong).

### 12.4 Spike D — wakeup mechanisms on raw libuv (`spikes/d-wakeup.ss`)

The loop thread runs `uv_run` (`__collect_safe`). `timer P`: a repeating
P ms timer drains a mutex-protected queue. `async`: the worker calls
`uv_async_send` (a plain `foreign-procedure`) after each push; the
`uv_async_t`'s callback drains. Idle phase: 1 s with nothing pushed but a
final stop token. Handoff phase: 2 000 pushes of `(now-us)` spaced ~0.5 ms.

```
$ gtimeout 60 chez --script spikes/d-wakeup.ss timer 1
mode=timer period=1 idle: wall-ms=1002 cpu-ms=10 stop-seen=#t
mode=timer period=1 handoff: n=2000 mean-us=573 max-us=2366 wall-ms=1282 cpu-ms=31
uv_loop_close=0
$ gtimeout 60 chez --script spikes/d-wakeup.ss timer 10
mode=timer period=10 idle: wall-ms=1012 cpu-ms=3 stop-seen=#t
mode=timer period=10 handoff: n=2000 mean-us=5348 max-us=11027 wall-ms=1275 cpu-ms=17
uv_loop_close=0
$ gtimeout 60 chez --script spikes/d-wakeup.ss async
mode=async period=1 idle: wall-ms=1005 cpu-ms=1 stop-seen=#t
mode=async period=1 handoff: n=2000 mean-us=13 max-us=422 wall-ms=1285 cpu-ms=40
uv_loop_close=0
```

Also observed while debugging the first version of this spike: `uv_stop`
called from a worker thread while the loop is blocked in the poll does not
wake it (the flag is honoured at the next iteration), and a stop flag set
while no `uv_run` is active makes the *next* `uv_run` return immediately.
Consistent with libuv's "not thread-safe except where stated"; the design
never calls `uv-stop!` off the loop thread.

### 12.5 Spike E — parser cost and the close boundary (`spikes/e-parser-cost.sps`)

```
$ gtimeout 120 chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program spikes/e-parser-cost.sps
close-then-pipelined: status=error consumed=47/74 error=(closed-connection Data after `Connection: close` 47)
events (oldest first): (begin method method-done url url-done protocol protocol-done version version-done hf hf-done hv hv-done hf hf-done hv hv-done headers-complete complete)
keep-alive pipelined: status=need-input consumed=55/55
events: (begin method method-done url url-done protocol protocol-done version version-done hf hf-done hv hv-done headers-complete complete reset begin method method-done url url-done protocol protocol-done version version-done hf hf-done hv hv-done headers-complete complete)
parse+copy-spans: 100000 requests of 81 bytes: 1.86342 us/request, -191 bytes allocated/request
byte-at-a-time: 6.6395 us/request
```

The `-191 bytes` is an artefact of collections during the run and is not
relied on. The first two lines are the pipelining facts the driver is built
on: after a close-marked message, `consumed` stops exactly at the message
boundary (47 of 74) with `closed-connection`; between keep-alive messages
`on-reset` fires before the second `on-message-begin`.

### 12.6 Spike F — per-parser memory (`spikes/f-parser-size.sps`)

```
compute-size of one parser (excluding shared machine/bindings? no: reachable graph) = 1706080 bytes
compute-size of the machine alone = 1709616 bytes; bindings list = 290784 bytes
bytes allocated per make-parser (1000 parsers, no collect between) = 1104
parsers retained: 1000
```

The 1.7 MB reachable from a parser is the shared compiled machine;
`make-parser` itself allocates 1 104 bytes.

### 12.7 libuv documentation quoted

- `https://docs.libuv.org/en/v1.x/design.html`: *"The libuv event loop (or
  any other API involving the loop or handles, for that matter) is not
  thread-safe except where stated otherwise."*; *"It … is meant to be tied
  to a single thread."*; poll timeout: *"the timeout of the closest timer is
  taken, or if there are no active timers, infinity."*
- `https://docs.libuv.org/en/v1.x/async.html`: `uv_async_send`: *"It's safe
  to call this function from any thread. The callback will be called on the
  loop thread."*; *"libuv will coalesce calls to uv_async_send(), that is,
  not every call to it will yield an execution of the callback."*;
  `uv_async_init`: *"Unlike other handle initialization functions, it
  immediately starts the handle."* Coalescing is why the inbox is drained
  to empty on every wake rather than one item per wake.

### 12.8 Chez documentation quoted

- `https://cisco.github.io/ChezScheme/csug10.0/foreign.html` §4.2, §4.3,
  §4.4, §4.9 — quoted in §7.1, §7.3.
- `https://cisco.github.io/ChezScheme/csug10.0/threads.html` §15.1–15.3,
  15.8 — quoted in §7.2.
- `https://cisco.github.io/ChezScheme/csug10.0/smgmt.html` §13.1 — quoted
  in §7.1.
- `https://cisco.github.io/ChezScheme/csug10.0/control.html` §6.3/§6.4:
  call/1cc *"A one-shot continuation should not be returned to multiple
  times"*; engines *"Do not use the timer interrupt (see set-timer) and
  engines at the same time, since engines are implemented in terms of the
  timer."* — the reason engines are not used for handler CPU bounds in v1.

---

## 13. Testability under FCIS / TDD / mutation

### 13.1 The functional core

`(http connection-core)`: a pure step function over an explicit state
record, with the parser inside it (the parser is deterministic Scheme):

```scheme
;; connection-step : ConnState Event -> (values ConnState (Listof Command))
;; Event   = (data bv start end) | (eof) | (read-error cond) | (write-done id n err)
;;         | (tick now-ms) | (cmd <worker command>) | (job-result …)
;; Command = (write bv) | (read-stop) | (read-start) | (shutdown) | (close)
;;         | (dispatch request) | (arm kind deadline) | (log …) | (metric …)
```

Every `uv-*` call and every mutex lives in the shell
(`(http connection-shell)`), which is a table from Command to the libuv verb
plus the three closures that turn libuv callbacks into Events. The shell is
small enough to be covered by the socket tests alone.

### 13.2 The llhttp corpus through the connection layer, no sockets

Reuse `(httparse test corpus-load)` (`corpus-parse-file`, `fixture-input-text`,
`fixture-expected`, `fixture-meta-ref`) and `(httparse test conformance)`
(`corpus-scan-sizes len #f 'full` → every size 1..len; `corpus-chunk-bounds`)
from `/Users/yuzu/github/chez-httparse/test/support/harness/httparse/test/`.
For each request-mode fixture and each chunk size:

1. Start from `(initial-conn-state config)`; feed `(data bv a b)` for each
   `(a . b)` in `(corpus-chunk-bounds len size)`; then `(eof)`.
2. Fold the emitted Commands into a *connection trace*: the sequence of
   `dispatch` records (method, target, headers, body bytes concatenated from
   the channel), `read-stop`/`read-start` pairs, the error classification
   (`400`/`431`/…) and the final `close`.
3. Compare against an expected connection trace derived from the fixture's
   llhttp trace (method, url span, headers, body spans, `flags`, error
   line) — a small pure translator in the test support library — so the
   assertion is "the connection layer's view of this message is
   fragmentation-independent and agrees with llhttp".
4. The `drive-chunk-ladder` sizes (1 2 3 5 8 13 21 34 len) are the default
   lane; `'full` is the nightly lane (274 fixtures × every size is minutes,
   as chez-httparse already runs).

Fixtures with `Connection: close` + trailing data assert `consumed` stops
at the boundary and the tail is discarded; pipelined fixtures assert
`dispatch` order and that the `max-pipeline` cap produces exactly one
`read-stop` at the right byte when the cap is set to 1 or 2. With sockets:
the same fixtures are written by an in-process client (test-echo shape,
`run-until/ticking`), and the trace is reconstructed from what the server
actually wrote back (a canned echo handler that serialises the request it
received). Iteration caps, never wall-clock.

### 13.3 The threaded half

- The job queue, inbox and channel are libraries that take `wake!` as a
  procedure; tests inject a counter. Their tests fork real threads but wait
  with `condition-wait` + timeout and assert sentinel symbols, never
  booleans (SRFI-64 turns a raise into `#f`).
- `await`, `response-write!` backpressure and `request-read-body!` are
  tested against a fake loop that is just a thunk runner on the test's
  thread; the socket tests then cover the real loop.
- Mutations that must go red by name (a starting list, each watched to fail):
  drop the `'write-hw` reason removal in `on-complete` (test: streaming a
  4 MiB body to a client that reads slowly ends with `iterations-exhausted`);
  make `connection-close!` non-idempotent (test: EOF and write error in the
  same iteration → two `on-close` registrations → the live-handle snapshot
  never empties); feed the tail after a close-marked message (test: the
  corpus fixture answers `closed-connection`); dispatch a queued request
  before the in-flight one ended (test: responses arrive out of order on
  the socket); post from a worker after close (test: `late-commands` = 1,
  no raise); remove the server-side guard (test: a handler-side mistake
  reaches `uv-loop-deferred-errors`).

### 13.4 Checks over comments

- A test pins the flag bits `F-CONNECTION-CLOSE = 2` etc. against
  `parser-field-ref 'flags` after parsing a `Connection: close` message
  (they are not exported by chez-httparse).
- A test asserts that no exported procedure of `(http handler-api)` names a
  `uv-` identifier (a grep-level check at test time over the library's
  source, the same trick test-echo uses for its import list).
- A test asserts the trampoline-name literal of chez-libuv at the version
  this server pins (so the tier-2 upgrade fails loudly if the name set
  changes under it).

---

## 14. Build order for this angle

1. `(http limits)`, `(http request)`, `(http response-encode)` — pure.
2. `(http connection-core)` with the 25-callback mapping; corpus replay at
   every chunk size, no sockets (13.2).
3. `(http connection-shell)` + the single-threaded server with an inline
   handler (the worker pool disabled: `HTTP_WORKERS=0` runs handlers on
   the loop thread) — this is the fallback if the angle loses.
4. Job queue / inbox / channel libraries; tier-1 heartbeat; `await`.
5. Timing wheel, limits, graceful shutdown.
6. Upstream chez-libuv slice: `uv_async` + `__collect_safe` (tier 2);
   `wake-loop!` switches by feature detection on the binding's exports.
