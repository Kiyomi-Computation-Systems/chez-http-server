# How Scheme meets libuv's async model — the options, the evidence, the choice

Date: 2026-09-19
Status: settled by decisions 0002 and 0003; kept as the record of what was compared and why
Evidence: six independent proposals ([`research/async-*.md`](research/)), one live spike ([`research/spike/spike-control-flow.md`](research/spike/spike-control-flow.md), every experiment run twice), three judges ([`research/judge-*.md`](research/))

## The constraint everything else follows from

chez-libuv delivers every callback from inside a `foreign-callable` invoked by libuv's C code, deep inside `uv_run`. Chez's rule for that situation (CSUG §4.4, fetched and quoted verbatim in the spike):

> Chez Scheme handles this interaction in a general manner by trapping attempts to return to stale foreign contexts rather than by restricting the use of continuations directly. A foreign context becomes stale after a normal return to the context or after a return to some other foreign context beneath it on the control stack.

Measured consequence on this machine (Chez 10.4.1 threaded, libuv 1.52.1, macOS arm64):

| Experiment | What was tried | Result |
|---|---|---|
| E1a/E1b | `call/1cc` captured in timer A's callback, invoked from timer B's callback, or from top level after `uv-run` returned | `attempt to invoke shot one-shot continuation`, then `attempt to return to stale foreign context`; a bare `&assertion` escaping `uv-run` unwrapped; loop survives, teardown works |
| E2a/E2b | same with full `call/cc` | callback body resumes, then the stale-context trap at the trampoline's return to C; the continuation includes `uv-run` and the rest of the program, so top level re-runs (the unguarded first version looped forever) |
| E3/E3b | coroutines started from top level; callbacks only enqueue; scheduler alternates ready queue and `uv-run 'once` | works for timer, TCP on-data and write-completion wake-ups through three nested Scheme frames; ~30–36 ns per pure suspend/resume, ~13 µs per turn including a 0 ms timer and one `uv-run 'once` |
| E4a–E4d | Chez engines as handlers | work from a top-level scheduler; but expiry inside a callback leaves `uv_run`'s C frames suspended and clears chez-libuv's `loop-running` flag via `dynamic-wind`, so a nested `uv-run` is accepted and re-enters libuv (200 nested runs, no crash, invariant defeated) |
| E5a | worker thread → mutex-protected queue → loop-thread 1 ms timer → `uv-write!` | works |
| E5b/E5b2 | worker thread calls `uv-write!` directly | one call succeeded by luck; 2000 concurrent calls: hang with lost data, `invalid memory reference` in `uv-run`, registry corruption at teardown |
| E5c | worker allocates while the loop blocks in `uv-run` | 27 ms of work took 10.27 s with a 300 ms poll; `uv_run` is bound without `__collect_safe` (chez-libuv #19). The 92 ms seen with a 1 ms poll is not a workaround (E5d/E5e) |
| E5d | chez-libuv's threading-spike harness (raw FFI, plain `uv_run`, 1 ms ticker) with one knob: what the loop thread runs per tick | the ticker opens GC windows only when the loop thread executes a few hundred procedure calls per tick: 0 calls 439–447 ms, 100 calls 82–85, 300 calls 29–32, 1000+ calls 9–20; an uncontended mutex per tick 437–438; `(sleep 0)` 9–12; `__collect_safe` 6–10. Chez services a collect request only at `$event`, and firing the collector does not shorten the 1000-tick trap budget |
| E5e | E5c's worker with the loop thread never leaving `uv-run 'default` | 1 ms timer 44–92 ms, 300 ms timer 10.2 s: chez-libuv's dispatch path alone reaches `$event`, which is why E5c saw 3× and chez-libuv's T2b saw 75× |
| E5f | plain vs `__collect_safe` per callback, single-threaded, poll amortized over 256 idle handles | 177–192 ns vs 235–249 ns per callback, about 60 ns for the reactivate/deactivate pair |
| E6 | `uv-run` from inside `on-data` | `&uv-invalid-argument` with `who = uv-run`, `reason = loop-running`, raised synchronously at the call site |

Two judges reran the promise proposal's disciplined variant (capture in callback A, resume in callback B, then *escape* rather than return normally) and found it survives 1000 rounds. It is unrefuted but rests on never returning through the stale frame, with a bare `&assertion` one mistake away; both judges excluded it on those grounds.

## The six proposals

| Key | Shape | Strongest property | Why not alone |
|---|---|---|---|
| `cps-callbacks` | connection layer and handlers in continuation-passing style over the binding's own callbacks; six ~10-line combinators | smallest surface, no continuation question, 2.7 KB/request measured, a working loopback server in the proposal's own spike | handler ergonomics: nested lambdas, no dynamic extent across an await, exactly-once `k` discipline unchecked by the language (an arity slip stopped the whole loop via store-and-reraise) |
| `two-level-coroutines` | scheduler at top level; callbacks enqueue; one coroutine per connection on `call/1cc`; direct-style handlers | direct-style `await`; application code never runs under a C frame so store-and-reraise is unreachable; 24 ns per switch, 3.4–5.6 KiB per parked coroutine measured | connection semantics live in coroutine control flow, so the corpus replay needs the scheduler; 10k idle connections carry parked stacks |
| `engines` | handlers as Chez engines, slices interleaved with `uv-run 'nowait` | preemption of CPU-hog handlers | E4c/E4d hazards; every expiry inside `parser-feed!` poisons the parser (judge J1: 28/28); preemption is not a v1 requirement |
| `threads-mailbox` | handlers on a thread pool, loop thread owns handles | only route to multi-core within one process | needs `uv_async` and `__collect_safe` that do not exist yet (E5b2, E5c; planned upstream on 2026-09-19 as chez-libuv's threading arc, #19 then #20); nondeterministic tests |
| `promise-combinators` | then/catch/all/race over callbacks, optional `await` sugar | ergonomic composition without a scheduler | Tier 1 `await` captures under a C frame (see above); 4.1 KiB per suspended await |
| `sans-io-state-machine` | `conn-step : State × Event → State × [Action]`; parser callbacks are events answered synchronously; effects run-to-completion | the whole llhttp corpus and every semantics table run with no sockets (13/13 checks in its spike); zero timers and zero continuations per connection | naive prototype allocated 6.8 KB/request; handler asynchrony is closures unless a shell adds coroutines |

Judges' totals over six criteria (max 90): two-level 78, CPS 77, sans-I/O 72, promises 66, engines 56, threads 44. The correctness judge ranked two-level first, the testability judge sans-I/O first, the performance judge CPS first — and all three wrote that a hybrid beats every single proposal.

## The chosen hybrid

```
  libuv callbacks ──► events ──► conn-step (pure) ──► actions ──► libuv verbs
        │                                                  │
        │ on-data, on-eof, on-error, on-write-done,        │ feed-parser, reply-parser, write,
        │ on-shutdown, on-close, tick, signal              │ read-stop/start, arm-deadline,
        │                                                  │ call-handler, shutdown, close
        │                                                  ▼
        │                                     call-handler: synchronous handler → done (no scheduler)
        │                                                  awaiting handler → coroutine spawned by the
        │                                                  scheduler, resumed only from Scheme frames
        └──────────────────────────────────────────────────┘
                     scheduler turn:  drain-ready! ; (uv-run loop 'once | 'nowait)
```

1. **Core** = the sans-I/O `conn-step`, with the CPS proposal's allocation discipline (linear mutable request accumulator, retained `(bv from to)` spans from the fresh delivery, interned lower-cased header names, one shared 25-entry binding list per server). Acceptance gate: ≤ 3 KiB per request on the CPS spike's workload.
2. **Connection shell** = direct callbacks. Parse inside `on-data`; pause at `on-message-complete` for exact boundaries (measured: `consumed` marks the boundary, the remainder is retained from `parser-result-next`); pause in `on-body-data` for the one-slot body mailbox; guarded `uv-read-stop!`/`uv-read-start!`; one `on-write-done` closure per connection carrying sizes in a FIFO; one tick timer and a timing wheel per loop; 16 KiB read buffer. An idle keep-alive connection costs the read buffer plus ~2 KiB of Scheme.
3. **Handlers** = plain procedures. One that returns a response is done. One that calls `await` is created and resumed only from the scheduler's drain, never inside a callback (phase assertion R1/R2); resume cells fulfilled from libuv callbacks are the only bridge, and they are one-shot (R4). The measured 3.4 KiB per parked coroutine is paid only while a handler is actually parked.
4. **Run-to-completion.** Parser callbacks run `conn-step` and nothing else, because byte-machine refuses re-entrant feeds and poisons a parser whose callback escapes; every other action is queued and executed after the outermost dispatch returns. Nothing that can raise runs inside a parser callback, and nothing the application writes runs under a C frame.

Rejected for v1, with the evidence that rejects them: engines (E4c/E4d, J1), OS-thread handlers (E5b2, E5c, no `uv_async`), callback-captured `await` (E1/E2 and the escape-only discipline). The threads route stays open as chez-libuv #19 and #20, planned upstream on 2026-09-19 as Stage 1 and 2 of one arc; until Stage 1 lands no timer trick substitutes for `__collect_safe` (E5d/E5e).

## What each layer of the hybrid is tested by

- **Core**: SRFI-64 tables over `conn-step`, one row per decision, each watched to fail first; the llhttp request fixtures at every chunk size through a recording adapter with a ratchet; libhtp's connection streams with explicit packet boundaries.
- **Shell**: the fake shell (scripted events, recorded actions, fake clock) and the direct libuv shell must produce identical wire bytes and action traces for the same script — one contract test gates both, and the coroutine shell joins it in M7.
- **Scheduler**: `poll!` is the single injection point; unit tests script "callbacks landed" batches and never touch libuv. The named mutations (swap `'once`/`'nowait`; remove the one-shot check in `fulfil!`; call a handler from inside `on-data`) each have a test that goes red.
- **Sockets**: chez-libuv's ADR-0010 shape, iteration caps, assertions on bytes and verb sequences only.

## Handler API, as the hybrid presents it

```scheme
;; The whole contract. respond is callable once; body is a bytevector,
;; a procedure (streaming producer), or #f.
(define (handler request respond)
  (respond 200 '((content-type . "text/plain")) (string->utf8 "hello\n")))

;; Streaming a large response with backpressure: the producer is called
;; again only after the previous chunk's write completed and out-bytes
;; fell below low-water (the notify-producer action).
(define (handler request respond)
  (respond 200 '((content-type . "application/octet-stream"))
           (lambda (emit done) (emit chunk) ... (done))))

;; Consuming a large request body incrementally: the sink is called per
;; delivery; returning 'more grants one more credit, 'pause stops reading.
(define (handler request respond)
  (request-body-sink! request (lambda (bv start end) 'more))
  (respond 200 '() #f))

;; Awaiting an external result: this handler is run as a coroutine.
(define (handler request respond)
  (let ((addrs (await (dns-lookup "example.com"))))
    (respond 200 '() (string->utf8 (format-addrs addrs)))))
```

The verbs a handler sees export no `uv-*` name; `make test` carries an `rg` gate for that.

## Numbers to hold onto

| Quantity | Measured | Where |
|---|---|---|
| suspend/resume on the two-level scheduler | 24–36 ns | spike E3b; two-level M2 |
| one scheduler turn with a 0 ms timer and `uv-run 'once` | ~13 µs | spike E3b |
| `__collect_safe` reactivate/deactivate per callback, single-threaded (after chez-libuv #19) | ~60 ns (177–192 ns plain, 235–249 ns safe) | spike E5f |
| parked coroutine, resident | 3.4–5.6 KiB | two-level M3 |
| naive pure core, per request | 6,832 B | sans-I/O §12.1 |
| CPS core, per request | 2,672 B | CPS proposal |
| chez-libuv read buffer per connection | 65,536 B default | chez-libuv api.md |
| `uv_timer_t` / `uv_tcp_t` / `uv_write_t` | 152 / 264 / 192 B | sans-I/O §12.3 |
