# Judge report: correctness and safety under the real Chez + chez-libuv constraints

- lens: `correctness`
- date: 2026-09-19
- machine: Chez Scheme 10.4.1 threaded, `tarm64osx`, libuv 1.52.1, chez-libuv v0.5.0, chez-httparse v0.2.0, byte-machine v0.6.0 (all as measured in `spike-control-flow.md` "Toolchain")
- inputs read in full: `spike-control-flow.md` (2298 lines), `async-cps-callbacks.md` (834), `async-two-level-coroutines.md` (746), `async-engines.md` (936), `async-threads-mailbox.md` (1131), `async-promise-combinators.md` (1162), `async-sans-io-state-machine.md` (501), all under `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/`
- my own experiments (commands and verbatim output in §A): J1 `engine-preempt-feed.sps`; reruns of the promise proposal's `await-timer.sps` (guarded/unguarded) and `stale-detail.sps`

## 0. Verdict in five lines

1. No proposal rests on an assumption the live spike *refuted*. The one design that depends on a callback-captured continuation (promise-combinators Tier 1) uses a shape the spike did **not** test (escape-to-current-root, never a normal return); I reran its script and it holds for 1000 rounds (§A.2). It is *not refuted*, but it is one escaped `raise` away from a bare `&assertion` that abandons `uv_run`'s C frames (§A.2 unguarded, §A.3), which is strictly worse than store-and-reraise.
2. The engines proposal has a measured defect it did not find: engine expiry inside `parser-feed!` runs byte-machine's `dynamic-wind` after-thunk and marks the parser **`poisoned`** at every preemption (28/28 in J1, §A.1). The feed completes only because byte-machine's completion arm overwrites the lifecycle afterwards. That is an implementation accident of a dependency, not a contract; between slices the parser is unusable and an abandoned engine leaves it permanently poisoned. Not fatal (feeds can be made non-preemptible with `with-interrupts-disabled`), but that repair removes the proposal's headline benefit.
3. The threads proposal is correct only by discipline the language cannot check and needs an upstream chez-libuv change (`uv_async`, `__collect_safe` re-binding of `uv_run` and all thirteen trampolines) to avoid a 10 s GC stall (E5c) and 1 % idle polling. E5b2 shows what one slip costs: registry corruption and an invalid memory reference. It is last.
4. Two-level coroutines and the sans-I/O state machine are the two designs whose every safety property is either structural or measured (E3, E3b, M1–M6; 13/13 + loopback). Two-level is the only design under which application code can never trigger chez-libuv's loop-stopping store-and-reraise, because no user code ever runs under a C frame; sans-I/O is the only design whose connection semantics were proven chunk-size-invariant with adversarial (LIFO) handlers both socket-free and over loopback.
5. A hybrid — the sans-I/O `conn-step` core as the connection layer, driven by the two-level scheduler as its shell, with handlers as coroutines started from the scheduler — beats every single proposal on this lens (§4).

## 1. The constraints, with the spike evidence each one rests on

| Constraint | Evidence (experiment / file:line) |
|---|---|
| A continuation captured in a callback and returned to normally later is trapped: `attempt to return to stale foreign context`, a bare `&assertion` escaping `uv-run` unwrapped; with `call/1cc` the body does not even resume (`attempt to invoke shot one-shot continuation`, recorded by `dispatch-guarded`) | spike E1a/E1b, E2a/E2b (`spike-control-flow.md` §E1a–E2b, Conclusions 1–2) |
| The loop survives that trap and can be run again; handles stay open | E2c |
| A two-level loop (capture only in scheduler-entered Scheme frames, callbacks only enqueue) is correct and cheap: 30–36 ns per suspend/resume, no busy loop | E3, E3b; two-level proposal M1 (`uv-run-blocked-ms=402` of 402) |
| Engines driven from top level work; engine expiry inside a callback does not stale the frame but **clears chez-libuv's `loop-running` flag via `dynamic-wind`** so a nested `uv-run` is accepted — a genuine libuv re-entry | E4a–E4d; `loop.sls:55-63` |
| `uv-run` from inside a callback raises `&uv-invalid-argument who=uv-run reason=loop-running`, synchronously, catchable | E6 |
| `uv-write!` from another thread corrupts the unsynchronised registry (`handles.sls:218` `(make-eqv-hashtable)`) and faults | E5b2 (4 runs: hang with lost data + gtimeout kill; 2× `invalid memory reference`; `registry-entry-loop: 0 is not of type #<record type registry-entry>`) |
| A loop thread blocked in plain `uv_run` (`native.sls:242`, no `__collect_safe`) freezes every other thread's collection | E5c (27 ms of allocation took 10 266–10 272 ms with a 300 ms poll) |
| Every callback runs under `dispatch-guarded`; the first raise is stored, `uv_loop_stop` is called, `uv-run` re-raises `&uv-callback-error` | `handles.sls:290-304`, `loop.sls:50-66` (read today, §A.4) |
| A second `uv-close!` on a `'closing` handle stores nothing (callback lost) | `handles.sls:479-486` `(when (eq? (handle-state handle) 'open) ...)` |
| byte-machine `parser-feed!` refuses re-entry (`busy` → `reentrancy`), and its `dynamic-wind` after-thunk sets `poisoned` on any exit with `completed = #f` | `runtime.sls:998-1003`, `1021-1057` (§A.4) |
| `on-data` bytevector is fresh per delivery (retaining it is safe); span callbacks index the caller's bytevector | ADR-0009; `handles.sls:399-405` (`copy-out`) |

## 2. Scores (1–5, 5 best) and the reasoning behind each

Criteria: simplicity (S), correctness under Chez + chez-libuv constraints (C), testability under FCIS (T), backpressure fidelity (B), performance (P), extensibility (E).

| key | S | C | T | B | P | E | fatal flaw |
|---|---|---|---|---|---|---|---|
| two-level-coroutines | 3 | 5 | 4 | 5 | 4 | 4 | none |
| sans-io-state-machine | 3 | 5 | 5 | 4 | 3 | 4 | none |
| cps-callbacks | 4 | 4 | 4 | 4 | 5 | 3 | none |
| promise-combinators | 3 | 3 | 4 | 4 | 4 | 4 | none (Tier 1 is hazardous, not refuted) |
| engines | 2 | 2 | 3 | 4 | 3 | 3 | none strictly, but J1 shows the parser is poisoned at every mid-feed preemption; correctness rests on a dependency's implementation accident |
| threads-mailbox | 1 | 2 | 2 | 3 | 2 | 3 | none strictly; correct only with an unbound `uv_async` + a `__collect_safe` re-binding of the whole binding, and by memory-model discipline the language cannot check |

### 2.1 two-level-coroutines (C=5)

Why 5 on correctness:

- Rests on nothing the spike refuted: continuations are captured and invoked only in scheduler-entered frames (`R2`, §3.2), which is exactly E3's shape (E3: TCP `on-data`/write-completion/timer wakeups through three nested Scheme frames, "No continuation error of any kind"). Its A2 explicitly does not depend on the open question.
- **Store-and-reraise is unreachable by application code** (§13 "Store-and-reraise compatibility"): handlers, parser callbacks and all 25 span/event bodies run inside a coroutine under the scheduler, never under a foreign context. The only thing that can raise `&uv-callback-error` is one of ten library-owned O(1) closures (§8.1), i.e. a server bug, which the design correctly treats as fatal rather than retrying. No other single proposal has this property; CPS and sans-I/O both leave "a handler's own lambda handed to `uv-getaddrinfo!` raises" as a path that stops the loop for every connection (cps §16.5; sans-I/O §7 row "handler exception (later ...)").
- `uv-run` non-re-entrancy: `poll!` is the only `uv-run` call site and is never inside a coroutine (`phase` check, §3.2 R1/R5). Contrast E4d: the engine design's re-entry safety is *not* protected by the binding's flag.
- Parser non-re-entrancy: R5 — callbacks return `callback-pause`, the coroutine awaits after `parser-feed!` returned; the parser runs only in the coroutine (§8.2). M4 measured the three pause points.
- Span lifetime: the inbox retains fresh delivery bytevectors (ADR-0009, `handles.sls:405`), sub-spans `(bv start' end)` never re-copied; `on-body-data` stores a triple into the delivery it owns (§8.2). Correct.
- Single-thread registry: R7.
- Close ownership: `connection-close!` is the only `uv-close!` caller for a connection handle, enforced by an `rg` gate in `make test` (§15.2); peers refused at accept are closed with no callback to lose (§15.6).
- Deadlock / busy loop: M1 measured 6 `uv-run` calls over 402 ms with 100 % of wall time blocked; `'nowait` only when a coroutine `yield!`ed (§4). Lost wakeups are impossible: single thread, callbacks only inside `uv-run`, ready queue inspected after `uv-run` returns. Every park has a wheel deadline (§11).
- Response ordering: v1 is one coroutine per connection executing handlers sequentially — provable by construction (§9). v2's `conn-next-to-write` gate is the standard sequence gate.
- Error propagation across await measured (M5: guard catches after resume; uncaught raise lands in the scheduler's plain Scheme guard).

Weaknesses that keep it from being a clean sweep (they cost S/T/P, not C):

- **Double-resume hazard in the sketch.** `wake-if-waiting!` (§5.1) checks `state = 'parked` and the `waiting-for` tag, but `fulfil!` (§5.2) checks only the *cell*. A coroutine parked in `await` (a resume cell, `waiting-for` = `#f`) can be woken by a transport error (`'any`, which matches any tag) *and* then by the cell: the second push resumes a used one-shot `k` → `attempt to invoke shot one-shot continuation` in the scheduler. Fix is one line (`fulfil!` must also require `state = 'parked`, and a cell-parked coroutine must record what it is waiting on), and the proposal's own R4 test would have to be extended to cover it. Sketch bug, not design flaw.
- Safety rules R1/R2/R5 are policed at runtime by the `phase` assertion; a violation is a fatal `&uv-callback-error`. That is the right failure mode for a library bug, but it is a bug class the callback designs do not have.
- 3.4–5.6 KiB resident per parked coroutine (M3) is scanned by major collections — unmeasured under load (its own risk 2).
- A4: `dynamic-wind` winders re-run on every suspend/resume (M5: in=2 out=2) — correct but a footgun for `parameterize`-heavy handlers.

### 2.2 sans-io-state-machine (C=5)

Why 5 on correctness:

- Zero continuations, zero threads, zero engines (§10): nothing in E1–E5 applies. A2 is explicitly not load-bearing.
- **Run-to-completion is forced, not chosen** (§1.2): `reply-parser` is the only action consumed synchronously inside a parser callback; every effect is queued and executed after the outermost `dispatch!` returns. That makes byte-machine's `busy → reentrancy` arm (`runtime.sls:998-1000`) and its poisoning after-thunk (`runtime.sls:1057`) unreachable by construction, and it is the only proposal that makes "no code that can raise runs inside a parser callback" a structural property rather than a rule (`conn-step` is total; its `else` is an assertion-violation, §11.9).
- `uv-run` non-re-entrancy respected trivially (no code ever waits inside a callback; every wait is a later event).
- Span lifetime: `pending-input` retains the fresh delivery (A10/A11, ADR-0009); spans copied or retained by reference to that delivery (§1.3).
- Close ownership: the executor's `close` arm guarded by a per-cell `closing?` flag is the only `uv-close!` (§9.2); a late `respond` after close is a logged no-op (§2.4); measured `connection table empty` after `Connection: close` (§12.2).
- **Response ordering is measured, not just argued**: LIFO handler responses (`(3 2 1)`) written in wire order 1,2,3 at every chunk size 1..135 socket-free (§12.1), and 4,3,2,1 handlers via timers and `uv-getaddrinfo!` over loopback with wire order 1,2,3,4 (§12.2). This is the strongest ordering evidence among the six.
- Data-after-close handled above the parser (measured `closed-connection` at offset 47, second request never fed at chunk=1, §12.1).
- Pipeline cap: pause + read-stop + resume + feed remainder + read-start measured in order at cap=2 (§12.1 "cap=2 trace").

What keeps it from beating two-level on this lens:

- Handler code runs inside libuv callbacks (the `call-handler` executor runs inside `on-data`'s dispatch; a `respond` from a DNS completion runs inside that callback). A raise in a handler's *own* libuv callback reaches `dispatch-guarded` and stops the loop for every connection (§7, "the handler is responsible for its own guard there"); the mitigation is a helper the author may forget. Two-level closes this structurally.
- The `run-again` policy after `&uv-callback-error` (§7 "anything that still escapes a callback") restarts the loop after a *driver bug* with a reconciliation pass; FINDINGS Q2 `store` shows the loop is in a defined state, but a design that keeps serving after an invariant broke is less safe than one that stops (two-level §13 does stop).
- Nested `drain!`: a synchronous `respond` inside `call-handler` re-enters `dispatch!` with depth 0 and drains from inside an executor. FIFO order is preserved, but the interpreter is re-entrant in a way the prototype tolerated rather than designed; the depth counter should wrap `drain!`, not only `parser-feed!` (§3.3, `adapter.sls:27-52`).
- Pause inside `on-body-data` is admitted as unpinned (§11.5); the promise proposal's M1 measured that exact site (`consumed` includes the delivered span, re-feed from `consumed`), which reduces this risk for any design that adopts it.
- P=3: 6,832 B/request naive core, 14,054 with adapter+parser+fake shell (§10); the fix ("pure by contract" mutable accumulator) is a review-discipline cost.

### 2.3 cps-callbacks (C=4)

- Correct against every spike result: no captured continuation, no thread, no engine (§2 rule 4, §15.1). Store-and-reraise respected by `cps-guard` at every boundary; close ownership via `conn-close!` (§12, measured `closed-conns=1` with EOF, `Connection: close` and shutdown racing); read-stop guarded with `uv-handle-open?`; ordering by serial dispatch (`busy?`), measured 200 pipelined requests in order with one 500 in the middle (A.3).
- Why not 5: the safety argument is *discipline* at every site. The proposal's own spike stopped the whole loop from a one-token arity slip (`(k err)` vs `(lambda (err v) ...)`, A.3 run 1: `uv-run raised: uv-callback-error ... responses(200)=0`) — precisely the failure mode store-and-reraise makes global. A forgotten `k` hangs silently until `response-timeout`. "Every boundary needs `cps-guard`" (§16.5) includes handler-supplied lambdas handed straight to `uv-getaddrinfo!`, which are unguarded unless routed through an `http-await` proxy.
- Handler code runs **inside the parser's dynamic extent**: §4.3 delivers a body span to a waiting reader `k` synchronously from `on-body-data`, so the handler's continuation (and anything it calls — `respond`, `uv-write!`) executes under byte-machine's `dynamic-wind` (`runtime.sls:1021-1057`). Any raise that escapes `cps-guard` there poisons the parser as well as stopping the loop; any handler that reached `parser-resume!`/`parser-feed!` from that continuation would hit the `reentrancy` arm. The spike passed every chunk size, so the paths are consistent today, but it is a re-entrancy surface the sans-I/O run-to-completion queue removes.
- Synchronous-completion re-entrancy (§16.6) is a genuine bug class: "state mutated after the call sees the future".
- Recursion in `pump → feed → pump` is bounded by `cap` (§5.3) — fine as long as `cap` is validated at construction.

### 2.4 promise-combinators (C=3)

- Tier 0 is exactly as safe as CPS (no Chez assumption beyond chez-libuv's own) and better in one respect: the microtask FIFO drained by `with-step` before returning to C (§3.2) is what keeps handler reactions out of the parser's frame — the same reason sans-I/O queues effects. Tag indirection makes the core testable without promises (§6.1, §13.1).
- Tier 1 (`await`) is the interesting case. The spike's conclusion 2 says a callback-captured continuation "must never [be] invoke[d] — there is no way to make it valid". That is an overclaim: E1a/E1b/E2a/E2b all *return normally* into the capturing callback's frames (E1a's `call/1cc` body returns `'first-time`, shooting the one-shot; E2a's resumed body returns through A's trampoline). The promise design forbids exactly that: `await` leaves by `(current-root 'suspended)` and completion leaves by `(current-root 'finished)` (§4.1–4.2), which is the CSUG §4.4 sentence "Programs that use continuations more generally also function properly as long as they never actually return to a stale foreign context". **I reran its script: 1000 A→B rounds with a `(collect)` per round, `ran-dry`, `live-handles 0`, `teardown ok` (§A.2).** So Tier 1 is not refuted.
- Why it still scores 3: the failure mode when the discipline slips is *worse* than store-and-reraise. In the unguarded run (§A.2) the raise reached A's stale `dispatch-guarded` guard (the handler stack travels with the continuation, A3), whose escape returned to the stale context: `uv-run` raised a bare `&assertion` (`uv-callback-error? #f`, §A.3), B's `uv_run` iteration's C frames were abandoned (CSUG §4.4: the C stack pointer is not restored; FINDINGS Q2: escapes leave invisible cleanup obligations), two handles were left live, and the stored `boom` was re-raised as `&uv-callback-error` on the *next* `uv-run`. The library-owned innermost catch-all (§4.2) is mandatory and un-checkable; user code capturing a full continuation inside a handler is a trap (§16.3). Debuggability of a continuation chain containing frames of a finished callback is poor (§16.7). Suspended-coroutine memory is unmeasured (A6).
- Also: `spawn` wraps the body in `parameterize ((in-coroutine #t))`; every suspension escapes through that winder and every resume re-enters it — correct here, but §4.4's "no non-idempotent `dynamic-wind` around a step" rule is one more rule policed by review.
- Ordering: a `ready` promise per response (§7) is a correct sequence gate but more machinery than a head index; `max-handlers-started 1` default makes v1 provable.

### 2.5 engines (C=2)

- Structurally sound against E1/E2: continuations are captured only by `engine-block`/expiry in engine code that never runs inside a callback (E2 invariant); the scheduler calls `uv-run` only between batches (§4.5), so E4d's nested-`uv_run` hazard is avoided *by rule* — but note E4d shows the binding's own guard would **not** catch a violation (the `loop-running` flag is cleared by `dynamic-wind` on expiry), so unlike E6 there is no runtime net.
- **J1 (§A.1, run twice, byte-identical):** with the parser pulled inside the engine (§2.2), every engine expiry that lands inside `parser-feed!` runs byte-machine's after-thunk `(unless completed (parser-set-lifecycle! parser 'poisoned))` (`runtime.sls:1057`): 28 of 28 expiries observed lifecycle `poisoned`; callbacks in the resumed feed observed `(busy poisoned)`; a `parser-feed!` between slices raised `&byte-machine-contract` (`poisoned-parser`); an engine abandoned mid-feed left the parser permanently poisoned (`next feed -> (raised (&byte-machine-contract))`). The resumed feed completed with results and events identical to the baseline **only** because byte-machine's completion arm writes `'ready` and sets `completed` afterwards — the proposal's own A5 measured the winder behaviour ("(in out) after block") but did not connect it to `runtime.sls:1057`. The proposal's risk 7 ("correct only while nothing outside the engine touches that parser") understates it: the parser passes through a state byte-machine documents as terminal ("only full reset may reuse it", `runtime.sls:1660-1672`) on every preemption, and the design relies on the dependency not checking it. Repair: wrap `parser-feed!` (and `parser-resume!`/`parser-finish!`) in `with-interrupts-disabled` (CSUG system.html `disable-interrupts`/`with-interrupts-disabled`/`critical-section`), which makes feeds non-preemptible and deletes the "parsing 64 KiB of hostile headers is preemptible" benefit (§2.2).
- The same invisible-preemption-point problem applies to every engine-side read-modify-write of a field a callback also mutates (`out-bytes`, `out-count`, `inbox-bytes`, §4.2/§6.2): the tick counter decrements at nonleaf calls (A4), so a slice can end between `uv-write!` returning and the counter increment, and a completion callback can then run. E1 ("a callback and an engine slice never interleave") is true at slice granularity and false at statement granularity. Same repair, same cost.
- No nesting (A2, measured) is a user-facing restriction that fails at runtime; `dynamic-wind`/`parameterize` re-execute at every slice (A5) — including `current-connection` (§3), re-established per slice by design.
- Ordering (v1 sequential) and close ownership (E3) are fine. Backpressure design is fine (B=4).
- Spike coverage: timers and DNS only; no TCP read/write under the scheduler (its risk 13).

### 2.6 threads-mailbox (C=2)

- It respects the registry constraint by construction (workers never call `uv-*`), and E5b2 shows why that matters: one slip corrupts the registry and faults.
- E5c / its own spike A: the loop thread blocked in plain `uv_run` freezes every worker's collection (3005 ms). Tier 1 bounds that with a 1 ms heartbeat (1 % idle CPU, 573 µs mean handoff); tier 2 needs an unbound `uv_async` (a fourteenth trampoline under ADR-0008) **and** re-binding `uv_run` and all thirteen trampolines `__collect_safe` — FINDINGS.md's "deliberately untested" gap, measured here on darwin/arm64 only (spike B), never on the Linux CI host. A design that is only good after an upstream change to the binding's foreign-call convention is not a v1 candidate on this lens.
- Chez documents thread-safety of primitives, not a memory model for unsynchronised `set!` visibility (its A4/risk 7); every shared field must be touched under `with-mutex` by rule; a lint is proposed, not a check.
- **Bytevector reuse race** (not acknowledged): `response-write!` posts `(write id bv)` to the inbox and returns; the copy into the foreign block (ADR-0009) happens on the loop thread at drain time. A handler that refills and re-posts the same buffer (the natural streaming loop) mutates it while the loop thread may still be copying it. Either `post!` must copy or the API must forbid reuse until credit returns; neither is stated.
- No thread cancel in Chez (A5): a wedged handler loses a pool slot forever; blocked writers wedge the pool (`max-blocked-writers` aborts connections to protect it). Deadlock is bounded only by `condition-wait` timeouts.
- Ordering (one in-flight per connection) and close ownership (`connection-close!`; workers post `close`) are correct. Parser on the loop thread is the right call (1.86 µs parse vs 3.9 µs hop).
- Tests for the threaded half are nondeterministic by nature (its risk 6).

## 3. Ranking (correctness lens)

1. **two-level-coroutines** — the only design under which application code cannot trigger the binding's loop-stopping policy, measured no-busy-loop, ordering by construction, and the spike (E3) validated its exact shape. Its sketch has one fixable double-resume hazard (§2.1).
2. **sans-io-state-machine** — zero continuations, run-to-completion forced by byte-machine's contracts, the strongest measured ordering and chunk-invariance evidence; loses only on handler code still running under C frames and the `run-again` policy.
3. **cps-callbacks** — correct and smallest, but safety is per-site discipline; its own spike demonstrated the global failure mode from a one-token slip, and handler code runs inside the parser's dynamic extent.
4. **promise-combinators** — Tier 0 is CPS with a FIFO; Tier 1 works (verified) but its failure mode abandons C frames and its safety is a library-owned catch-all nobody can check.
5. **engines** — J1 shows the parser is poisoned at every mid-feed preemption; correctness rests on a dependency's implementation accident, and the repair removes the reason to use engines.
6. **threads-mailbox** — needs an unbound verb and a binding-wide `__collect_safe` re-binding to avoid E5c; memory-model discipline by rule; unkillable handlers; a bytevector-reuse race.

## 4. Hybrid recommendation: does one beat every single proposal?

Yes. **Sans-I/O core, two-level shell, coroutine handlers.**

- Connection layer = the sans-I/O `conn-step : State × Event → State × [Action]` (its §1), parser included via the `feed-parser`/`reply-parser` split with run-to-completion. This keeps the socket-free corpus lane (every fixture at every chunk size, LIFO handlers, cap, close, timeouts with a fake `now`) and the measured ordering invariant unchanged.
- Shell = the two-level scheduler (its §4–§5): libuv callbacks only enqueue `bytes-arrived`/`eof`/`read-error`/`write-completed`/`tick` into a per-connection inbox and mark the connection runnable; each scheduler turn drains inboxes through `conn-step` and executes actions; `(uv-run loop 'once)` when nothing is runnable. Now **no application code and no parser callback ever runs under a C frame**, so store-and-reraise is reachable only by the ten library-owned closures, and the E1/E2 question is moot (E3 shape).
- Handlers = coroutines spawned by the `call-handler` action from a scheduler frame (`call/1cc` per two-level R2), with direct-style verbs (`respond!`, `sink-write!`, `body-read!`, `await`, `with-deadline`) that are nothing but events into the core (`handler-responded`, `handler-body-chunk`, `body-credit`, ...). A handler that never awaits costs nothing extra beyond the coroutine record; the 3.4–5.6 KiB parked stack is paid only while parked.
- What to take from the others: the promise proposal's M1 protocol for pausing inside `on-body-data` (`consumed` includes the delivered span; re-feed from `consumed` after `parser-resume!`) pins the sans-I/O risk 5; CPS's `once`/arity discipline is unnecessary because the core's events are data; the threads proposal's spike B/D is the right *upstream* ask (`uv_async` as a fourteenth trampoline) for cross-thread work later, but not a v1 dependency.
- Explicitly rejected for v1: engines (J1), OS-thread handlers (E5b2/E5c + unbound `uv_async`), and callback-captured `await` (promise Tier 1) — the two-level scheduler gives the same direct-style ergonomics without the stale-context hazard.
- Required fixes carried into the hybrid: (a) resume cells and inbox wakes must be mutually exclusive (`fulfil!` checks `state = 'parked`; a cell-parked coroutine records its cell), with the R4 test extended; (b) the interpreter's depth counter wraps `drain!`, not only `parser-feed!`; (c) a handler timeout is delivered at the next park (no preemption — same as every non-engine design).

The alternative hybrid named in the task — callbacks at the connection layer with coroutines only in handlers — is strictly weaker than this one: the connection layer's callbacks would still run parser callbacks under C frames and handler coroutines could only be resumed from the scheduler if the connection layer *also* enqueued, at which point it is the two-level shell anyway.

## A. Commands and verbatim output (mine, today)

Working directory for my scripts: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/judge/`. Nothing was written into any git repository.

### A.1 J1 — engine expiry inside `parser-feed!` (`engine-preempt-feed.sps`)

Script: feeds a two-request buffer (76 bytes) to a chez-httparse request parser (a) at top level as a baseline, (b) inside a `make-engine` with a 50-tick budget so expiry lands inside `parser-feed!`, recording `parser-lifecycle` at every expiry and inside every callback; (c) the same but with `(parser-feed! p2 input 0 1)` attempted between slices 1 and 2; (d) an engine abandoned at its first expiry, then fed again.

Command (run twice):

```sh
cd /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/judge
gtimeout 60 chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program engine-preempt-feed.sps
```

Run 1 (`out-engine-preempt-feed.run1.txt`):

```text
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

Run 2 (`out-engine-preempt-feed.run2.txt`): byte-identical to run 1.

Two earlier attempts of this script failed at load for reasons unrelated to the finding (the machine is exported as `httparse-message-machine`, not `httparse-message`; `make-parser` wants `(list (cons 'type (httparse-message-type-value 'request)))`, and my guard used `condition-message` on a `&byte-machine-contract` condition that carries no `&message`); each was fixed and the run repeated.

Reading against source: `runtime.sls:1021-1057` (§A.4) — the after-thunk `(unless completed (parser-set-lifecycle! parser 'poisoned))` runs on every engine expiry because engine expiry unwinds `dynamic-wind` (engines proposal §12.2 row "dynamic-wind log after block: (in out)"); the before-thunk is `(lambda () #t)` and restores nothing; on completion the result arm sets `'ready` (line 1045) and then `(set! completed #t)` (line 1047), which is why the final state is correct.

### A.2 Promise proposal M2/M3 rerun (`spike-promise/await-timer.sps`)

Command:

```sh
cd /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike-promise
for m in guarded unguarded; do CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs gtimeout 60 chez --program await-timer.sps $m; done
```

Output, `guarded` (trace truncated by me at 30 lines with `head -30`; the script itself caps its trace at 40 entries):

```text
(scenario guarded outcome ran-dry rounds 1000 ms 1257)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
  (caught-after-resume "after-resume")
  (B-step finished)
  B-return-to-C
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 1)
  (caught-after-resume "after-resume")
  (B-step finished)
  B-return-to-C
  ...
exit=0
```

Output, `unguarded`:

```text
(scenario unguarded outcome (uv-run-raised other attempt to return to stale foreign context) rounds 0 ms 2)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
(live-handles 2)
(teardown-raised #<compound condition>)
exit=0
```

The script's shape (read from its source, lines 15-33): `run-step` = `(call/1cc (lambda (root) (set! current-root root) (thunk) 'returned-normally))`; `await-wakeup` = `(call/1cc (lambda (k) (set! waiter k) (current-root 'suspended)))`; `resume!` = `(run-step (lambda () (k v)))`; `start-coroutine` ends with `(current-root 'finished)`. Contrast spike E1a, whose `call/1cc` body returns `'first-time` normally (shooting the one-shot) and whose B invocation therefore fails with `attempt to invoke shot one-shot continuation`.

### A.3 Promise proposal `stale-detail.sps` rerun

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs gtimeout 60 chez --program stale-detail.sps
```

```text
uv-run raised: (uv-callback-error? #f error? #f who #f message attempt to return to stale foreign context irritants ())
(deferred ())
(second-uv-run (raised callback-error? #t cause boom))
teardown ok
exit=0
```

### A.4 Source lines read today

`/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:998-1003` (busy/poisoned arms), `:1021-1057` (the `dynamic-wind` around the executor; after-thunk poisons when `completed` is `#f`), `:1346`, `:1393`, `:1615` (`parser-finish!`/`parser-resume!` poisoned arms), `:1660-1672` ("only full reset may reuse it").

`/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:290-304`:

```scheme
  (define (loop-record-error! loop obj)
    (require-loop loop 'uv-loop-record-error!)
    (if (loop-has-pending-error? loop)
        (set-loop-deferred-error-list!
         loop (cons obj (loop-deferred-error-list loop)))
        (begin
          (set-loop-pending-error! loop obj)
          (when (and (eq? (loop-state loop) 'open)
                     (valid-pointer? (loop-ptr loop)))
            (uv-loop-stop (loop-ptr loop))))))

  ;; Catch every raised object, not just conditions.
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))
```

`handles.sls:218` `(define registry (make-eqv-hashtable))`; `handles.sls:479-486` `real-close-handle!` (`(when (eq? (handle-state handle) 'open) ...)`); `loop.sls:50-66` (`uv-run`: `'loop-running` refusal, `dynamic-wind` around `uv-loop-run`, `deliver-pending-callback-error!`); `native.sls:242` `(define uv-loop-run (foreign-procedure "uv_run" (uptr int) int))` (no `__collect_safe`).

CSUG `system.html` (fetched copy at `.../research/csug-system.html`) documents `disable-interrupts`, `with-interrupts-disabled` and `critical-section` — the repair named in §2.5.

### A.5 Spike experiments cited by name

From `spike-control-flow.md`: E0 (CSUG §4.4 verbatim), E1a, E1b, E2a, E2b, E2c, E3, E3b, E4a, E4b, E4c, E4d, E5a, E5b, E5b2, E5c, E6, Conclusions 1–7. From the proposals: cps A.1–A.6; two-level M1–M6; engines §12.1–12.7; threads spikes A–F; promise M1–M4; sans-I/O §12.1–12.3.
