# Judge report — lens: performance and operability at 10k connections on one loop

- date: 2026-09-19; machine: Chez 10.4.1 threaded `tarm64osx`, libuv 1.52.1, chez-libuv v0.5.0, chez-httparse v0.2.0, macOS arm64
- inputs read in full: `research/spike-control-flow.md` (2297 lines), the six proposals (`research/async-*.md`), and one other judge's spike output found in `scratchpad/judge/` (J1, quoted in §2.3)
- new measurements made by this judge today: §2 (commands and verbatim output); scripts and raw outputs in `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/judge/`
- nothing was written into any git repository

Scoring criteria (1–5, 5 best): simplicity · correctness under Chez/libuv constraints · testability (FCIS) · backpressure fidelity · performance · extensibility. Lens-specific sub-questions: allocation per request, per-connection resident memory, timer-handle economy, continuation/thread cost, GC pressure, tail latency under pipelining, observability (outstanding requests, bytes queued, connection states), graceful shutdown, and cost of adding HTTP/1.0, `Expect: 100-continue`, upgrade, and later TLS.

---

## 1. What the live spike settles, and what it does not

Facts from `research/spike-control-flow.md` that bear on this lens (section names as in that file):

| Spike | Finding relied on | Consequence for the proposals |
|---|---|---|
| **E1a / E1b** (`call/1cc` captured in timer A, invoked from timer B / from top level) | Both runs byte-identical: `Exception: attempt to invoke shot one-shot continuation` stored by `dispatch-guarded`, then `Exception: attempt to return to stale foreign context` raised as a **bare `&assertion` escaping `uv-run` unwrapped**; A's body never resumed. | A callback-captured continuation that is *returned through normally* is invalid. |
| **E2a / E2b / E2c** (full `call/cc`) | A's body **does** resume ("A: call/cc returned from-B"), the trap fires only at the return to the stale context; `uv-loop-teardown!` → `ok`; after the trap "both original timer handles were still `open`, the new timer fired on the second `uv-run`". | Control *can* move into a callback-captured continuation; the loop survives the trap. This is the door the promise proposal's Tier 1 walks through (§2.1 below). |
| **Conclusion 2** | "Any design that stores a callback-captured continuation must never invoke it -- there is no way to make it valid." | **Overstated** as written: E1a/E2a only exercised the normal-return case. My rerun of the promise proposal's `await-timer.sps` (§2.1) shows 1000 capture-in-A/resume-in-B rounds ran dry twice when the resumed computation *escapes* instead of returning. What the spike does establish is that the failure mode is an unwrapped `&assertion` out of `uv-run` (operability: the whole loop iteration is abandoned). |
| **E3 / E3b** | Two-level loop works: handler through three nested Scheme frames, ticker interleaving, "No continuation error of any kind"; 30–36 ns per suspend/resume, `call/1cc` ≈ `call/cc`; ~13 µs per suspend → `uv-run 'once` → timer → resume round trip (131–138 ms wall / 17–20 ms CPU for 10,000). | two-level-coroutines' A1 confirmed independently of its own M1/M2. |
| **E4a / E4b** | Engines resumed after `uv-run 'once`/`'nowait` complete correctly (600 slices, correct sum). | engines' scheduler shape works. |
| **E4c / E4d** | Engine expiry **inside** a callback does not stale the frame but leaves `uv_run`'s C frames suspended and **clears chez-libuv's `loop-running` flag via `dynamic-wind`**, so a nested `uv-run` "is accepted and actually re-enters libuv's `uv_run` (E4d: 200 nested runs ... no crash in 2/2 runs)". Conclusion 4: "a design that uses engines must guarantee that no callback ever runs inside an engine slice, or re-guard `uv-run` itself." | engines' invariant E1 holds for the *scheduler*, but nothing in the proposal refuses a handler's own `(uv-run ...)` inside a slice (E4b shows the binding does not refuse it). An explicit re-guard is required; it is not in the proposal. |
| **E5b2** | Cross-thread `uv-write!`: hang with lost data (`exit=124`), `invalid memory reference`, registry corruption `0 is not of type #<record type registry-entry>` across four runs. | threads-mailbox correctly never does this. |
| **E5c** | Worker allocation loop: 26–28 ms baseline; **10266–10272 ms** with the loop blocked in `uv-run 'once` behind a 300 ms timer; 91–93 ms with a 1 ms timer. "A blocking `uv-run` on the loop thread freezes every other Scheme thread at its next allocation-triggered collection for the length of the poll." | threads-mailbox's Tier 1 heartbeat is a *necessity*, not a tuning; Tier 2 (`__collect_safe uv_run` + `uv_async`) does not exist in chez-libuv v0.5.0. |
| **E6** | `uv-run` from a callback raises `&uv-invalid-argument who: uv-run reason: loop-running` synchronously and catchably. | All single-thread designs that "never pump the loop from a callback" are consistent with the binding. |

No proposal rests on an assumption the spike **refuted**. Two rest on assumptions the spike **qualifies**: promise-combinators Tier 1 (works only under an escape discipline whose failure mode abandons a loop iteration) and engines (the binding's re-entry guard is defeated by expiry inside a callback; plus J1 below).

---

## 2. Measurements made by this judge

Library path for all runs: `CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs`, `gtimeout` from `/opt/homebrew/bin/gtimeout`.

### 2.1 Re-run of the promise proposal's M2/M3 (`scratchpad/spike-promise/await-timer.sps`), twice

Command (per run; `cd /Users/yuzu/github/chez-libuv` as the proposal did):

```
gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike-promise/await-timer.sps guarded
```

Run 1 (head, then tail):
```
(scenario guarded outcome ran-dry rounds 1000 ms 1252)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
  (caught-after-resume "after-resume")
  (B-step finished)
  B-return-to-C
  ...
(live-handles 0)
teardown ok
```
Run 2: identical apart from `ms 1284`. Unguarded variant (once):
```
(scenario unguarded outcome (uv-run-raised other attempt to return to stale foreign context) rounds 0 ms 1)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
(live-handles 2)
(teardown-raised #<compound condition>)
```

Reading: the proposal's Tier 1 claim reproduces 2/2 — the escape discipline (never return normally into the capturing callback's frames; the library's catch-all is innermost) is sufficient on this platform, consistent with CSUG §4.4 ("function properly as long as they never actually return to a stale foreign context"). The unguarded case reproduces the spike's E1a/E2a failure shape: a bare condition out of `uv-run`, two handles left open, teardown raising. So Tier 1 is **not refuted**, but its failure mode is a whole-loop event, one uncaught `raise` away.

### 2.2 New: resident memory of a suspended callback-captured `await` coroutine (promise A6, previously unmeasured)

Script `scratchpad/judge/perf-await-memory.sps` (verbatim in that file): one timer callback per capture, the promise Tier 1 shape (`run-step` root via `call/1cc`, handler nests `depth` frames, `call/1cc` at the await, `(root 'suspended)`, callback returns to C), 10,000 captures, full collection, `bytes-allocated` delta / N, then references dropped and re-collected to show the residual.

Command (twice):
```
gtimeout 120 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/judge/perf-await-memory.sps
```
Run 1 (`scratchpad/judge/out-perf-await-memory.run1.txt`):
```
depth=4 parked=10000 bytes/parked-await-coroutine=4120
  after dropping references: residual bytes/coroutine=-8
depth=16 parked=10000 bytes/parked-await-coroutine=4506
  after dropping references: residual bytes/coroutine=-4
depth=64 parked=10000 bytes/parked-await-coroutine=6112
  after dropping references: residual bytes/coroutine=-9
loop alive? #f
done
exit=0
```
Run 2: `4120 / 4509 / 6117`, residuals `-8 / -1 / -3`, `exit=0`.

Same-session re-run of the two-level proposal's `scratchpad/spike/coro-memory.sps` (`chez --program coro-memory.sps`, saved as `scratchpad/judge/out-coro-memory.rerun.txt`):
```
depth=4 parked=10000 bytes/parked-coroutine=3449
depth=16 parked=10000 bytes/parked-coroutine=3815
depth=64 parked=10000 bytes/parked-coroutine=5635
```
Same-session re-run of the engines proposal's `scratchpad/engines/bench.ss` (`chez --script bench.ss`, saved as `scratchpad/judge/out-engines-bench.rerun.txt`):
```
create 10000 engines: 1280000 bytes (128/engine), 0 ms
block 10000 engines once: 6521472 bytes (652/engine), 7 ms
after collect, blocked engines still referenced: bytes-allocated 25225760
resume 10000 engines to completion: 5 ms, first=9999 last=0
round-trips 100000: 47 ms, 2531552 bytes (25/round-trip)
Exception in engine: cannot nest engines
```

**Continuation-cost table for the lens (all measured on this machine, this session or the proposals' own runs today):**

| Model | Resident per suspended handler/connection | ×10k | Notes |
|---|---|---|---|
| cps-callbacks | one closure per pending step, ~32–96 B (proposal §14, bounded by 2672 B/request measured) | < 1 MB | no stack retained |
| sans-io-state-machine | 0 (state record ~15 words) | ~1 MB | plus `pending-input` retention of one delivery while paused (§11.4) |
| engines | ~652 B shallow / ~804 B at 30 frames (proposal §12.1–12.2; 652 reproduced here — note the 652 figure is allocation *during* block, the 804 figure is after-collect retention) | 6.5–8 MB | smallest continuation cost |
| two-level-coroutines | 3449 / 3815 / 5635 B at depth 4/16/64 (reproduced here) | 34–56 MB | segments scanned by major GC |
| promise-combinators Tier 1 | **4120 / 4506 / 6112 B** at depth 4/16/64 (new, §2.2) | 41–61 MB | ~20% above two-level because the retained segment also holds the trampoline + `dispatch-guarded` frames of the capturing callback |
| threads-mailbox | ~244–250 KiB RSS + ~800 KiB heap per **thread** (proposal spike C); pool of 8 ≈ 2 MiB | n/a | thread-per-request rejected by the proposal itself |

### 2.3 Another judge's engine experiment J1 (found in `scratchpad/judge/`, not mine, quoted because it changes the engines score)

`scratchpad/judge/engine-preempt-feed.sps` slices an engine *inside* `parser-feed!`. Both runs (`out-engine-preempt-feed.run1.txt`, `.run2.txt`) are byte-identical:
```
baseline: status=need-input consumed=76 lifecycle-after=ready events=39
engine: slices=28 lifecycle-at-expiry(distinct)=(poisoned) poisoned-expiries=28
engine: status=need-input consumed=76 lifecycle-after=ready
engine: events identical to baseline? #t
engine: lifecycles observed by callbacks (distinct): (busy poisoned)
touch-between-slices: (raised (&byte-machine-contract))
engine2: status=need-input lifecycle-after=ready
abandoned mid-feed: abandoned lifecycle=poisoned next feed -> (raised (&byte-machine-contract))
done
exit=0
```
Reading: byte-machine's `dynamic-wind` after-thunk (`runtime.sls:1057`) marks the parser `poisoned` at **every** slice expiry inside a feed; the feed still completes correctly on resume, but (a) any parser operation between slices raises `&byte-machine-contract`, (b) the parser's own callbacks observe `poisoned` after a resume, and (c) an engine abandoned mid-feed (connection closed at a slice boundary) leaves a permanently poisoned parser. The engines proposal's risk 7 anticipated (a); (b) and (c) are new sharp edges that a wheel/timeout path or a close path must handle (`parser-reset!` on abandon).

---

## 3. Per-proposal judgement

### 3.1 `cps-callbacks` — Pure callback / CPS

**Measured facts relied on** (proposal §14, Appendix A): 2672 B allocated/request for the CPS core incl. request-builder copies; 1600 B for the parser alone; 5863 B/request for the loopback server *including the in-process client*; `make-parser` with shared bindings 1072 B/connection (a per-connection 25-entry binding list would add 1216 B — the proposal avoids it); `uv_handle_size(UV_TCP)=264`, `(UV_TIMER)=152`, `uv_req_size(UV_WRITE)=192`; 200 pipelined requests served in order with one `uv-read-stop!` at cap=4; the arity slip `(k err)` that "stopped the whole loop via store-and-reraise" (A.3 run 1: `uv-run raised: uv-callback-error ... responses(200)=0`).

Lens assessment:
- **Allocation/request:** best measured of the six (2.7 KB core). Per pending step one closure. Zero continuation or thread cost; "Every libuv callback returns to C with an empty Scheme stack" (§14).
- **Per-connection resident:** ≈18 KiB with a 16 KiB read buffer, of which ~2 KiB is Scheme (§14). Best.
- **Timer economy:** one repeating `uv_timer_t` per loop, sweep O(live) per 1 s tick (10k field reads/s), wheel optional (§7). Good; the sweep is fine at 10k.
- **GC:** minimal live set; no stack segments; young garbage only.
- **Tail latency under pipelining:** parse-ahead to `cap` inside the same delivery (pump bounded by cap, §5.3), serial handler dispatch per connection (v1); latency for the k-th pipelined request = sum of the previous handlers, inherent to HTTP/1.1 ordering. Synchronous-completion re-entrancy (§16.6) can run a whole chain inline inside one callback — bounded stack by design, but a long synchronous chain delays other connections' callbacks in that iteration (same as any inline handler).
- **Observability:** explicit `outstanding-bytes`/`outstanding-writes`, `queue-length`, `busy?`, `reading?`, `closed?`, `pending`, `server-internal-errors`, live-connection count (§5.3, §9, §10, §11). Good.
- **Graceful shutdown:** §11 is complete (listener close, draining flag, idle close, drain deadline via the tick, live-count → teardown).
- **Extensibility:** HTTP/1.0 = `close?` at headers-complete (§6); `Expect: 100-continue` = an interim write queued at `on-headers-complete` (§5.2) — trivial in v1's serial mode; upgrade = hand `tcp + pending` to the handler (§6) — feasible because the driver owns the handle; TLS = a byte transform between `on-data` and `conn-feed!` and around `uv-write!`; the proposal's own §13 already frames the core as `conn-step : State Event -> State × Commands`, so a TLS record layer is another command interpreter. Handler-side ergonomics (await) can be layered later (§16.9).
- **Correctness/operability risk:** the proposal *measured* its own worst failure: one arity slip stopped service for every connection. `cps-guard`/`with-conn`/dispatcher guards cover the driver and handlers, but "a handler that hands its *own* lambda to `uv-getaddrinfo!` is guarded only if the framework's `http-request-loop` returns a proxy" (§16.5). This is the single operability hole at 10k connections; it is closable (mandatory `http-await` proxy + a `rg` gate that handler code imports no `uv-*` names), but it is by rule, not by construction.

Scores: simplicity **5**, correctness **4**, testability **5**, backpressure **5**, performance **5**, extensibility **4**. Fatal flaw: none.

### 3.2 `two-level-coroutines` — scheduler + one coroutine per connection

**Measured facts relied on** (proposal §2, Appendix A; reproduced/corroborated by spike E3/E3b and my §2.2): 402/402 ms blocked in `uv-run` over 6 calls, no busy loop (M1); 24 ns and ~7 B per yield/resume, 359 ns from 200 frames deep (M2); 3449/3815/5635 B per parked coroutine (M3, reproduced); exact pipelining boundary via `callback-pause` at `on-message-complete` (`consumed 51`, `47`) and `closed-connection` error at offset 99 on data after close (M4); guard inside a coroutine catches after resume, `dynamic-wind in=2 out=2` per park, uncaught coroutine raise lands in the scheduler's plain guard (M5); R3 crash mode found twice (`Exception in +: go is not a number`).

Lens assessment:
- **Allocation/request:** estimated < 2 KiB excluding the delivery (§17), *not measured*; zero per-write closures (one `on-write-done` per connection, sizes carried in a FIFO), ~2 conses per inbox event, 2–3 switches (~70 ns, ~20 B). Plausible but the only top-three proposal without a per-request number.
- **Per-connection resident:** ≈16 KiB foreign + ~5 KiB heap ≈ 21 KiB (§17), of which the parked coroutine is 3.4 KiB (≈15%). ~210 MiB at 10k with a 16 KiB buffer; the 35 MB of stack segments is scanned by major collections ("Not measured under load — listed as a risk").
- **Timer economy:** one `uv_timer_t` + hashed wheel, 250 ms tick, timer stopped when the wheel is empty (§11). Best-in-class detail (lazy rebucketing, `with-deadline` cells, `uv-cancel!` for DNS).
- **Continuation cost:** capture/resume copies the live segment (A7): cheap at shallow depth, 359 ns at 200 frames — handlers should await at modest depth; documented.
- **Tail latency under pipelining:** no parse-ahead (parser only fed by the coroutine), so request N+1 is parsed after response N is issued — one extra parse latency per pipelined request but strictly less memory than parse-ahead; one extra hop (`callback → inbox → uv-run returns → scheduler`) per delivery, batched naturally under load (§17). Extra `'nowait` poll (~13 µs, engines §12.6) only when a coroutine `yield!`ed.
- **Observability:** best of the single designs: every connection carries `coroutine-state` (`ready/running/parked/finished/faulted`), `waiting-for` (`input/drain/shutdown/closed`), `inbox-bytes`, `out-bytes/out-count`, `close-requests` counter, `late-fulfilment` records — "what is every one of 10k connections waiting for" is a table scan.
- **Graceful shutdown:** §14 acceptor coroutine with `with-deadline` on the all-closed cell; idle vs busy distinction; second SIGTERM kills. Complete.
- **Operability property unique to this design:** "because handler code never executes in a callback, the 'loop stopped by a raise' failure mode ... cannot be triggered by application code at all" (§13). At 10k connections that is the difference between one 500 and a total outage. Checked at runtime by the `phase` assertion (R1/R2/R5).
- **Extensibility:** HTTP/1.0 (`conn-must-close?`), `Expect: 100-continue` (the coroutine writes the interim before the first `request-read!`, §8.2), upgrade (the coroutine already owns tcp + inbox; a handler keeps using `await-event!`/`transport-write!`), TLS (a record-layer transform between inbox and parser in direct style), v2 per-request coroutines additive (§6). Best.
- **Risks that matter for the lens:** 35–56 MB extra at 10k and its GC scan cost (unmeasured under load); no preemption (same as CPS); no `uv_async` (same as all); retaining deliveries in the inbox was not what chez-libuv measured its 16 KiB recommendation against (§19.9).

Scores: simplicity **4**, correctness **5**, testability **4**, backpressure **5**, performance **4**, extensibility **5**. Fatal flaw: none.

### 3.3 `sans-io-state-machine` — pure `conn-step` + action interpreter

**Measured facts relied on** (proposal §12): 13/13 socket-free checks incl. identical wire bytes at every chunk size 1..135 for the llhttp pipelining fixture, LIFO handlers written in order, cap=2 pause/read-stop/resume/feed/read-start trace, `Connection: close` then data (second request never fed; raw parser: `status=error consumed=47 next=47 error=(closed-connection ...)`), HTTP/1.0, handler raise → 500, parser error → 400+close; the same core over loopback with timers + `uv-getaddrinfo!` answering 4,3,2,1 and wire order 1,2,3,4, table empty; **6,832 B/request pure core, 14,054 B/request core+adapter+parser+fake shell**; `uv_handle_size(UV_TIMER)=152`.

Lens assessment:
- **Allocation/request:** worst measured: 6.8 KB for the naive pure core alone (record copies per event via an alist updater, `bv-concat` per header, string conversion), 2.5× the CPS core's 2.7 KB. The proposal's fix (linear mutable accumulator, retained spans, interned header names) makes the core "pure by contract rather than by construction" (§11.8) — plausible to reach 1–2 KiB, **unproven**. Streaming costs two `conn-step` round trips per chunk (§11.3).
- **Per-connection resident:** zero continuations, zero timers, ~15-word `ConnState` + cell; but `pending-input` retains a whole delivery (≤ read-buffer-size) per paused connection — doubling the buffer footprint for paused connections (§11.4). Tunable by copying the remainder.
- **Timer economy:** one tick timer (500 ms) + wheel in the shell; deadlines are data in the pure state (§6). Good; switchable to per-connection timers.
- **GC:** the naive core's allocation is the GC story; nothing else retained.
- **Tail latency:** effects are queued and run after the outermost dispatch (run-to-completion) — deterministic, no extra loop iteration; parse-ahead to `max-pipeline` with exact boundaries.
- **Observability:** the best possible: the connection *is* an inspectable immutable record (`phase`, `inflight`, `ready`, `head`, `out-bytes`, `reading?`, `pending-input`, `deadline-kind`), and the event/action streams are loggable data (`(log level datum)` actions). A "dump every connection's state" endpoint is a `for-each` over records; a replayable trace is free.
- **Graceful shutdown:** a second pure machine (`server-step`) — "SIGTERM with 3 connections, one mid-body, deadline 2 s is a table test" (§8). Best.
- **Extensibility:** HTTP/1.0 measured; `100-continue` = one more action at headers-complete; upgrade = a phase plus handing `pending-input` + tcp to the handler; **TLS is where sans-I/O wins outright**: a TLS record layer is another `State × Event → State × [Action]` layer between the transport events and the HTTP core, testable without sockets, exactly h11/hyper-style. Coroutines can be layered as another producer of `handler-responded` events.
- **Risks:** indirection tax (the prototype hit the reply-vs-effect ordering bug on `Connection: close`, §11.1); the interpreter is covered only by loopback tests; pause inside `on-body-data` not pinned by corpus (§11.5); `assertion-violation` on an unknown event inside a parser callback would poison the parser (§11.9); later-callback handler raises (timer/DNS) still reach `dispatch-guarded` unless the handler guards (§7) — the same hole CPS has.

Scores: simplicity **3**, correctness **4**, testability **5**, backpressure **4**, performance **3**, extensibility **5**. Fatal flaw: none.

### 3.4 `engines` — cooperative time-slicing

**Measured facts relied on** (proposal §12, reproduced §2.2 here, plus spike E4a–E4d and J1): engines cannot nest; ~652–804 B parked; 25 B / ~0.5 µs per block+resume; a tight loop is preempted, a C call (`usleep(20000)`) is not (7 ticks left after 40 ms); `dynamic-wind` `(in out)` per block and `parameterize` unwound/restored per slice; a raise escaping an engine consumes it; **`uv-run 'nowait` on an idle loop ≈ 13 µs**; `sched-spike.sps` ran a hog, timer awaits and a DNS await to `(idle 70)` and clean teardown; TCP read/write paths under the scheduler **not measured** (§14.13).

Lens assessment:
- **Allocation/request:** engine share ≈ 25 B + queue op; the parser/copies dominate (§10.2 estimates 7–8 KB but that figure inherits performance.org's 6.1 KB whole-buffer parse; the CPS spike measured the parser at 1.6 KB/request in keep-alive mode with silent bindings, so the engine total is likely ~3 KB). Fine either way.
- **Per-connection resident:** ~800 B parked engine — the cheapest continuation of the direct-style designs (8 MB at 10k). 16 KiB read buffer proposed.
- **Timer economy:** one wheel timer, 1 s tick, 64 buckets, generation counters (§7.1). Good.
- **Scheduler overhead:** every slice pays `parameterize ((current-connection conn))` (§4.5) plus the engine's own `dynamic-wind` churn; the 13 µs poll is amortised only with `batch-max ≥ ~100`; `slice-ticks` has no time meaning ("Your mileage may vary") and must be benchmarked per platform — two knobs that decide p99 under load.
- **Tail latency:** the one thing engines buy: worst-case added latency for a request behind k runnable tasks is k × one slice, and libuv is polled at least every `batch-max` slices — **bounded regardless of handler behaviour** (§4.5, §10.4). None of the other five can promise that against a CPU-hogging handler. Caveat A4: a foreign call (TLS handshake in C, a blocking libc call) is not preemptible, so the bound is on Scheme code only.
- **Correctness under Chez constraints:** three sharp edges. (1) J1 (§2.3): a slice landing inside `parser-feed!` marks the parser `poisoned` at every expiry; callbacks observe `poisoned`; an abandoned mid-feed engine poisons the parser permanently — the close/timeout path must `parser-reset!` or never touch a parser whose engine is mid-slice; the proposal's risk 7 covers only the "nothing else touches it" half. (2) E4b/E4d: the binding does not refuse `uv-run` from inside an engine, and expiry inside a callback defeats chez-libuv's `loop-running` guard; the proposal's E1 constrains the scheduler but a handler calling `uv-run` is not refused — needs an explicit wrapper (a check, not a comment). (3) `cannot nest engines` and "Do not use the timer interrupt ... and engines at the same time" (CSUG §6.4) forbid any handler library that uses engines or `set-timer` — a `set-timer` user would corrupt slicing silently rather than raise.
- **Observability:** `run-state`, `inbox-bytes`, `out-bytes/out-count`, `deadline-kind`, run-queue length; ticks consumed per connection is a free CPU metric. Good.
- **Graceful shutdown:** §8.4 complete; forced sweep via `connection-close!` is idempotent by state.
- **Extensibility:** same direct-style API as two-level (§13.3); v2 sibling engines; upgrade/TLS natural inside the engine (but TLS in C is unpreemptible, so the fairness argument weakens exactly where it would matter most).

Scores: simplicity **3**, correctness **3**, testability **4**, backpressure **4**, performance **4**, extensibility **3**. Fatal flaw: none, but see the three edges above; J1's poisoning and the missing `uv-run` re-guard must be closed before this is safe.

### 3.5 `promise-combinators` — promises + optional `await`

**Measured facts relied on** (proposal §2, Appendix A; my §2.1 and §2.2): parser pause in `on-body-data` is clean (`consumed 54`, `5`, spans delivered once, flags 32); 1000 A→B rounds with `(collect)` each ran dry (reproduced 2/2); the negative case escapes `uv-run` as a plain condition and the stored error is delivered on the next `uv-run`; ~40 ns bare / 120–150 ns wrapped per suspend+resume; 28 B / ~20 ns per `then` link; **4120 B resident per suspended `await` at depth 4 (new, §2.2)**.

Lens assessment:
- **Allocation/request (Tier 0):** ~20 small objects incl. one promise per write, a `ready` promise per response, the handler promise, ~3 reaction closures + FIFO conses (§14) — roughly CPS + 200–300 B. The microtask FIFO drain runs inside every callback before returning to C (§3.2): bounded, but it is a scheduler in miniature the proposal owns up to.
- **Per-connection resident:** Scheme ≈ 1–2 KiB idle; Tier 1 suspended awaits cost **4.1 KiB each** (41 MB at 10k), about 20% above the two-level coroutine because the captured segment includes the capturing callback's trampoline and `dispatch-guarded` frames — and those frames are *live* dynamic context on resume (A3), which is the M3 hazard.
- **Timer economy:** one wheel timer + intrusive per-kind FIFOs + a heap for arbitrary `promise-timeout`s (§9.1). Good.
- **Tail latency:** same shape as CPS; `ready` gating per response; `max-handlers-started` allows overlap without buffering (§7).
- **Observability:** outstanding bytes/writes, FIFO length, promise `state`/`value`, `unhandled-rejection-hook` — but reactions are opaque closures, and a suspended Tier 1 coroutine's backtrace "contains frames of a callback that finished long ago" (§16.7). Middling.
- **Graceful shutdown:** `promise-all` of `connection-closed` under `promise-timeout` (§11). Clean and small.
- **Correctness/operability:** Tier 0 is as safe as CPS. Tier 1's discipline holds (2/2), but the failure is "one escaped `raise` away" (§16.3) and its symptom is a bare `&assertion` out of `uv-run` that abandons the rest of that loop iteration's callbacks (spike E2a/E2c: "Whether the abandoned iteration's remaining phases ... were skipped is not visible here"). At 10k connections that is a correlated hiccup across every connection with a pending callback in that iteration. Also: `dynamic-wind`/`parameterize` around a step are "silently wrong after a resume" (§16.9); write cancellation is cosmetic (§16.6).
- **Extensibility:** `then`-chains for everything; upgrade/TLS as in CPS (the core has tag indirection, so a TLS layer is a shell concern). No perf or operability win over CPS to pay the extra layer for.

Scores: simplicity **3**, correctness **3**, testability **4**, backpressure **4**, performance **4**, extensibility **4**. Fatal flaw: none for Tier 0; Tier 1 is not refuted by the spike (my rerun) but is the only proposal whose failure mode is an *unwrapped* escape from `uv-run` reachable from handler code.

### 3.6 `threads-mailbox` — worker pool + loop-thread I/O

**Measured facts relied on** (proposal §12; spike E5a/E5b2/E5c): 3005 ms worker stall with the loop blocked in plain `uv-run` (spike A; E5c: 10.27 s vs 27 ms); 1 ms heartbeat → 1 ms max gap; `__collect_safe uv_run` on raw libuv removes the stall (2000/2000 fires, `uv_loop_close=0`); mailbox round trip 3.87 µs; **handoff 573 µs mean / 2.4 ms max at a 1 ms heartbeat, 13 µs mean / 422 µs max with `uv_async_send`**; ~244–250 KiB RSS and ~800 KiB heap per forked thread; parser 1.86 µs/request on the loop thread.

Lens assessment:
- **Allocation/request:** 1–2 KiB young garbage **plus a `make-mutex` + `make-condition` per request** (the per-request `channel`, §3) — these are foreign-backed objects (pthread mutex/cond) with creation and finalisation cost the proposal did not measure; plus one job closure and ~4 command lists.
- **Per-connection resident:** 18.4 KiB with a 16 KiB buffer (§10) — identical to the others; the pool is ~2 MiB.
- **Latency floor:** Tier 1's heartbeat sets a **0.5 ms mean / 2.4 ms max** floor on every response (spike D) and 1% idle CPU; Tier 2's 13 µs needs a chez-libuv v0.6 slice (`uv_async` as a 14th trampoline, `__collect_safe` rebinding of `uv_run` and all thirteen trampolines) that does not exist and has not been measured on Linux.
- **GC:** stop-the-world across N+1 threads; every collection pauses all handlers; with Tier 1 every worker's collect waits for the loop thread's next return to Scheme (≤ heartbeat).
- **10k connections vs 8 pool slots — the structural problem for this lens:** a worker parked in `response-write!` behind a slow client holds a slot; `max-blocked-writers` (default N/2 = 4) then **aborts the oldest stalled connection** (§5) — i.e. at 10k concurrent connections with a handful of slow readers the server sheds connections to protect the pool. The single-threaded designs park nothing and shed nothing. Backpressure fidelity is therefore compromised at exactly the target scale.
- **Unkillable handlers:** no thread cancel in Chez; a wedged handler permanently loses a slot (`lost-workers` metric); shutdown `thread-join`s workers before teardown (§9.1), so one wedged handler can hang graceful shutdown.
- **Observability:** good (`read-stop-reasons` set is a nice touch; `late-commands`, `lost-workers`, inbox length).
- **Testability:** pure `connection-step` core; the threaded half is nondeterministic by nature (§11.6).
- **Extensibility:** upgrade is awkward (the handler thread can never touch the socket; all I/O by command); TLS must run on the loop thread anyway, so the one CPU-heavy thing this design could parallelise, it cannot.

Scores: simplicity **2**, correctness **3**, testability **3**, backpressure **2**, performance **2**, extensibility **3**. Fatal flaw (for this lens, as a v1 primary architecture): **the design is only good after an upstream chez-libuv change** — without `__collect_safe uv_run` + `uv_async` every worker allocation stalls on the loop's poll (E5c: 370× slowdown at a 300 ms poll) and the heartbeat imposes a ~0.5 ms latency floor; and a fixed pool cannot serve 10k concurrent connections whose handlers block on slow clients without shedding them.

---

## 4. Ranking (lens: performance and operability at 10k on one loop)

1. **cps-callbacks** — every number measured favours it (2.7 KB/request, ~2 KiB heap/connection, zero continuation cost, one timer); observability explicit; the single hole (a raw `uv-*` callback from handler code stops the loop) is closable with a proxy API and a source gate.
2. **two-level-coroutines** — the best *operability* property (application code cannot stop the loop, by construction, checked at runtime), the richest per-connection state view, direct-style handlers, one timer; pays 3.4 KiB/connection (35 MB at 10k, major-GC scanned) and one hop per delivery; per-request allocation unmeasured.
3. **sans-io-state-machine** — best observability, testability, shutdown and TLS story; loses on measured allocation (6.8 KB/request naive core, fix unproven) and streaming round trips.
4. **engines** — the only design with bounded tail latency against a CPU hog, cheapest parked continuation; but tuning knobs decide p99, `dynamic-wind`/`parameterize` churn per slice, no-nesting/no-`set-timer` restrictions, the missing `uv-run` re-guard (E4b/E4d), and J1's parser poisoning at slice boundaries.
5. **promise-combinators** — Tier 0 ≈ CPS plus a layer that buys no performance; Tier 1 works (reproduced) but is one uncaught raise away from an unwrapped escape out of `uv-run`, and costs 4.1 KiB per suspended await.
6. **threads-mailbox** — needs an upstream binding change to avoid a 0.5 ms latency floor and worker GC stalls; a fixed pool sheds connections under slow-client backpressure at 10k.

---

## 5. Hybrid recommendation — yes, a hybrid beats every single proposal under this lens

All three top proposals already converge on the same core: CPS §13 ("`conn-step : ConnState Event -> (values ConnState (Listof Command))`"), two-level §16 ("`(conn-step state event) → (values state' actions)` with symbolic actions"), sans-io §1 (the whole proposal). They differ only in the shell's control flow. So the hybrid is not a compromise between incompatible designs; it is choosing each layer's proven shape:

1. **Core: sans-I/O `conn-step`** (the sans-io proposal's event/action alphabet, its `reply-parser` vs deferred-effect split and run-to-completion queue, its pure `server-step` for shutdown), **with the allocation discipline of the CPS core**: a linear mutable request accumulator, `(bv from to)` spans retained from the fresh delivery instead of copied, interned lower-cased header names, a shared 25-entry binding list per server (1072 B/connection instead of +1216). Acceptance gate: ≤ 3 KiB/request on the CPS spike's workload (measured target: CPS 2672 B; sans-io naive 6832 B). This gives the observability (state record + action log), the socket-free corpus replay at every chunk size, the table-tested shutdown, and the TLS-as-another-layer path.

2. **Connection shell: direct callbacks (CPS shape), no per-connection coroutine.** `on-data` feeds the parser inside the callback (parse-ahead to `max-pipeline`, `callback-pause` at `on-message-complete` for exact boundaries, one-slot body mailbox with `callback-pause` in `on-body-data`, `uv-read-stop!`/`uv-read-start!` guarded), writes issued from the interpreter, one `on-write-done` closure per connection carrying sizes in a FIFO (two-level §7.2), one tick timer + timing wheel per loop, 16 KiB read buffer. Idle keep-alive connections therefore cost ~2 KiB of Scheme, not 5–6 KiB, and the common synchronous handler pays zero scheduler cost.

3. **Handlers: the two-level scheduler, used only for handlers that await.** `http-server-run!` is the two-level turn (`drain-ready!` then `uv-run 'once`/`'nowait`), so it costs nothing when no coroutine exists (one Scheme→C call per iteration). A handler is dispatched inline from the `call-handler` action; if it returns a response, done (CPS path). If it calls `spawn`/`await`, the coroutine is created and resumed only from the scheduler drain — never inside a callback (R1/R2, the `phase` assertion), so application code that awaits can never trigger store-and-reraise, and no continuation is ever captured under a C frame (spike E1a/E2a irrelevant by construction). Resume cells fulfilled from libuv callbacks (two-level §5.2) are the only bridge. Per suspended handler: 3.4 KiB (measured), paid only while a handler is actually parked, not per connection.

4. **Do not take from the others:** engines' preemption (J1 parser poisoning, `uv-run` re-guard, `set-timer` conflict — revisit only if a benchmark shows CPU-hog handlers are a real workload); promise Tier 1 (callback-captured continuations: 4.1 KiB each and an unwrapped escape one raise away); threads (until chez-libuv binds `uv_async` and rebinds `uv_run` `__collect_safe`; then a worker pool for CPU-bound handlers can be added behind the same command inbox, with the loop still owning every handle).

5. **Operability gates to put in `make test`:** a `rg` gate that handler-facing libraries export no `uv-*` names (threads §13.4, two-level §15.2); the `phase` assertion; a double-close test asserting exactly one `on-close`; a mutation row that removes `cps-guard`/the scheduler guard and must turn red; the flag-bit pin test for `F-CONNECTION-CLOSE = 2` etc. (grammar.sls:301-306, not exported).

Why this beats each single proposal under the lens: vs CPS alone — awaiting handlers get direct style and cannot stop the loop; vs two-level alone — 10k idle connections do not carry 35 MB of parked stack segments or an extra hop per delivery; vs sans-io alone — the CPS allocation discipline and a direct shell remove the 2.5× allocation and the per-chunk streaming round trips while keeping the pure core and its tests.

---

## 6. Citations index

- Spike: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/spike-control-flow.md` — sections E1a, E1b, E2a, E2b, E2c, E3, E3b, E4a–E4d, E5b2, E5c, E6, "Conclusions" items 1–7; chez-libuv facts quoted there: `native.sls:242` (`uv_run` bound plain), `native.sls:650-744` (trampolines plain), `loop.sls:55-63` (re-entry refusal under `dynamic-wind`), `handles.sls:302-304` (`dispatch-guarded`), `handles.sls:316-324`, `loop.sls:38-44`, `loop.sls:115-146`.
- Proposals: `research/async-cps-callbacks.md` §2, §3, §5.2, §5.3, §6, §7, §9, §10, §11, §13, §14, §15, §16, Appendix A.1–A.7; `research/async-two-level-coroutines.md` §0, §2 (M1–M6), §3.2 (R1–R7), §4, §5, §6, §7.2, §8.2, §9–§19, Appendix A.1–A.5; `research/async-engines.md` §2.1 (E1–E3), §3, §4.5, §5, §6, §7, §8, §10, §11 (A1–A9), §12.1–12.7, §13, §14; `research/async-threads-mailbox.md` §0, §2, §3, §4.3, §5, §6, §7.1, §9, §10, §11, §12.1–12.6, §13, §14; `research/async-promise-combinators.md` §0, §2 (M1–M4), §3.2, §4.1–4.5, §7, §8, §9.1, §10, §11, §14, §15 (A1–A8), §16, Appendix A.1–A.4; `research/async-sans-io-state-machine.md` §0, §1.2, §2.2–2.4, §3.2–3.3, §4, §5, §6, §7, §8, §9, §10, §11, §12.1–12.4, §13.
- Other judge's spike: `scratchpad/judge/engine-preempt-feed.sps`, outputs `out-engine-preempt-feed.run1.txt`, `.run2.txt` (quoted verbatim in §2.3).
- My scripts/outputs: `scratchpad/judge/perf-await-memory.sps`, `out-perf-await-memory.run1.txt`, `.run2.txt`, `out-coro-memory.rerun.txt`, `out-engines-bench.rerun.txt`; reruns of `scratchpad/spike-promise/await-timer.sps` (guarded ×2, unguarded ×1) — outputs verbatim in §2.1.
- Chez Scheme User's Guide 10.0 (as quoted by the spike and proposals, fetched today by them): https://cisco.github.io/ChezScheme/csug10.0/foreign.html §4.4 ("trapping attempts to return to stale foreign contexts", "A foreign context becomes stale after a normal return to the context", "Programs that use continuations more generally also function properly as long as they never actually return to a stale foreign context"), §4.3/§4.9 (`__collect_safe`, "active threads operating in C code prevent the storage management system from garbage collecting"); https://cisco.github.io/ChezScheme/csug10.0/control.html §6.3 (`call/1cc`), §6.4 ("Do not use the timer interrupt (see set-timer) and engines at the same time"); https://cisco.github.io/ChezScheme/csug10.0/threads.html.
- libuv docs (as quoted by the spike): https://docs.libuv.org/en/v1.x/loop.html ("uv_run() is not reentrant. It must not be called from a callback."), https://docs.libuv.org/en/v1.x/design.html ("not thread-safe except where stated otherwise"), https://docs.libuv.org/en/v1.x/async.html (`uv_async_send` "safe to call ... from any thread"; not bound by chez-libuv v0.5.0).
- byte-machine: `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:998-1000` (reentrancy refusal), `:1021-1057` (`dynamic-wind` poisoning), `:1144-1148` (zero-width step after pause); chez-httparse `src/httparse/grammar.sls:301-306` (flag constants, not exported).
