# Gap analysis: byte-machine v0.6.0, and composing it with chez-libuv / chez-httparse / uriparse for chez-http-server

Scope: byte-machine at `/Users/yuzu/github/byte-machine` (tag `v0.6.0`, commit `0245db3059504c462b881a550310300fece55216`), read against what `chez-http-server` needs per `.plans/chez-http-server-architecture.md`. All file:line citations were read directly from the source with `sed -n`/`rg -n` on 2026-09-19; every runtime claim below that could be settled by running code was run, and the exact command + output is included.

All paths below are absolute unless noted. Line numbers are for the exact commit above (`git rev-parse HEAD` in `/Users/yuzu/github/byte-machine` = `0245db3059504c462b881a550310300fece55216`, same as the gitlink both `chez-httparse` and `uriparse` vendor).

---

## 1. Callback dispatch cost, and whether `ctx` can be a mutable record updated per callback with no allocation

**Status: present, and empirically confirmed allocation-free.**

- The user context is passed through untouched. `parser-user-context` is documented in-line as "application-owned and may be mutable, so the runtime neither copies nor interprets it" — `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:544-552` (accessor at `:552`, `(define (parser-user-context p) (vector-ref p 11))`). It rides parser slot 11, set once at `make-parser` time and never rewritten by the runtime.
- Every callback invocation calls it with exactly `(f parser (parser-user-context parser))` — `runtime.sls:725` inside `byte-machine-callback-step/v2` (`runtime.sls:719-728`). No copy, no boxing, no interpretation: whatever record you pass at `make-parser` time is the exact object every callback receives, every time.
- **Callback outcomes are allocation-free singletons.** `callback-continue`/`callback-pause` are each a single `(vector 'sym)` built ONCE at library load (`runtime.sls:59,61`), and a callback failure is application-allocated, not runtime-allocated (`runtime.sls:688-693` "the contract-violation failure is built once", the shared no-detail singleton `contract-violation-failure` defined at `:692-693`). Decision [0052](file:///Users/yuzu/github/byte-machine/.decisions/0052-a-callback-outcome-is-the-object.md) (2026-09-17) rewired the classifier (`classify-callback-result`, `runtime.sls:694-700`) to answer the outcome object itself rather than a freshly-consed `(goto TARGET)`/`(pause)`/`(failure CODE DETAIL)` list, which had been costing 32 bytes × 2 conses = **128 bytes of garbage per HTTP header** (traced to the `many-small-headers` vs `short-normal-requests` allocation-bytes-per-message delta in the committed baseline, `bench/fixtures/baseline-tarm64osx.sls`). This is the current shipped shape (ABI 9).
- **This is asserted by byte-machine's own test suite, not just claimed in a decision doc:** `test/common/allocation-audit-tests.sps:205-206` — `(check-equal "disabled: per-header slope zero" disabled 0)` and `(check-equal "bound: per-header slope zero" with-callbacks 0)`, i.e. the generated lane's per-header allocation slope is asserted `0` **with callbacks bound**, not merely with them disabled.
- **Dispatch cost (the state/byte/goto/feed-entry cases), with real numbers.** README.org's "v0.6.0" status paragraph and `.plans/milestone-14-close.md` (closed 2026-09-18) record the whole story: Chez's `case` over many integer keys is a *linear scan*, and v0.6 (decisions [0049](.decisions/0049-a-state-is-a-procedure-not-a-case-arm.md)–[0053](.decisions/0053-the-feed-entry-is-a-search.md)) replaced all four nested dispatches:

  | what was linear | after | measured |
  |---|---|---|
  | the state `case`, re-entered per transition | one procedure per state, direct tail call | **0.80 ns** vs 185.85 ns |
  | the byte `case`, one arm per byte of a class | one clause per run of consecutive bytes | **1.25 ns** vs 21.60 ns |
  | the callback `goto` | the literal the arm already wrote | (0052, above — allocation, not time) |
  | the feed entry (last one standing) | balanced binary search, `ceil(log2 N)` | ships without meeting the 20%-on-3-workloads bar (see file) |

  (source: `.plans/milestone-14-close.md`, table under "What shipped"). Whole-request throughput: `many-small-headers` 90 ms → 51 ms per 16000×200 iterations on `tarm64osx`; downstream in `chez-httparse`, a 308-byte request parses at **175,342 msg/s vs 14,925** before this milestone — **twelve times faster**, llhttp differential unchanged (`milestone-14-close.md`, "Evidence" section).

- **My own measurement**, isolating the callback+ctx path end to end on the real 217-state `(byte-machine test http-machine)` fixture (a mutable `(define-record-type ctx (fields (mutable begins) (mutable completes)))` bound to two `event` callbacks that do plain `field-set!` mutation, `callback-continue`, nothing else): reused-parser cost including 2 callback firings + `parser-reset!` averaged **432.04 bytes/iteration** over 20,000 iterations after a 2,000-iteration warmup (script and full output under "Measured" below). Since byte-machine's own audit (above) already isolates the callback seam at exactly 0 B/callback, this 432 B is attributable to `parser-reset!`'s field-vector copy and the grammar's own per-message work, not to the ctx/callback mechanism — consistent with the two results being complementary rather than contradictory.

**Consequence for chez-http-server:** the connection layer can hold one small mutable record (parse state, response-writer state, backpressure counters) per connection, hand it to `make-parser` once, and mutate it from callbacks with ordinary `set!`/`field-set!` — this is the intended, zero-overhead usage, not a workaround.

---

## 2. What `parser-feed!` returns at `paused` (`consumed`, `next`), and how resumption re-feeds

**Status: present, fully specified, and traced through the source for both lanes.**

- A `pause` node commits `current` PAST the pause (to the node's declared continuation) before returning: `runtime.sls:1105-1109` (interpreted lane) — `(parser-set-current! parser (op 'pause-target node)) (make-parser-result 'paused pos (- pos start) (parser-offset parser) #f ...)`. So **`next` = `pos`**, the absolute index into the CURRENT call's `bv` at which the parser stopped (i.e., where it would resume reading), and **`consumed` = `pos - start`**, exactly like a `need-input`/`stopped` result — a pause is not distinguished from the others by its consumed/next shape, only by `parser-result-status` and the extra `parser-result-pause` slot.
- A callback-requested pause (a callback returning `callback-pause`) behaves identically but parks on the node's declared pause continuation instead (`runtime.sls:1148-1157`): "A callback-requested pause occurs after the callback's delivered event has been committed. Resume continues after that event; it is never delivered twice."
- The v2 (generated) lane's boundary (`parser-feed-v2!`, `runtime.sls:1290-1311`) routes the SAME contract: `next = (feed-outcome-next o)`, `consumed = (- (feed-outcome-next o) start)`.
- The optional pause REASON (decision [0046](.decisions/0046-a-pause-carries-a-reason.md), 2026-09-14, ABI 6→7) rides a SEPARATE 7th `parser-result` slot, `parser-result-pause` (`runtime.sls:229-236`), never the error slot — `parser-result-error` stays `#f` for a pause (so "does this result carry an error" and "is this result a pause" cannot be confused by a consumer that only checks the error slot).
- **Resumption is lifecycle-only — no callback, no input, no executor run**: `parser-resume!` (`runtime.sls:1604-1619`) is a 2-row table, `paused-feed -> ready` / `paused-finish -> finish-ready`, and nothing else runs. The comment at `runtime.sls:1602-1603` is explicit: "resume changes lifecycle only — no callback, no input, no executor run." After `parser-resume!`, the caller re-feeds via an ordinary `parser-feed!` call; because `current` was already parked past the pause point at pause time, the parser continues correctly from whatever new `bv`/`start`/`end` the caller supplies next — the pause does NOT retain a reference to the old buffer (byte-machine copies nothing across the FFI/feed boundary by design, matching chez-libuv's own ADR-0009 buffer-copy discipline).
- Calling `parser-feed!` on a `paused-feed`/`paused-finish` parser without resuming first is a `lifecycle-violation` contract violation (`runtime.sls:986-988`), and calling `parser-resume!` on anything but a paused parser is refused with distinct codes per row (`reentrancy` if `busy`, `poisoned-parser` if poisoned, `lifecycle-violation` otherwise — `runtime.sls:1610-1619`).

**Consequence for chez-http-server:** the connection layer's "upgrade"/CONNECT pause handling (llhttp's `PAUSED_UPGRADE`) is: on `'paused`, stop feeding, hand the connection off (e.g. to a raw-TCP tunnel or WebSocket path) or however the app wants to react to the reason in `parser-result-pause`; to go back to HTTP parsing later, call `parser-resume!` then feed the next bytes — there is no separate "give it back its state" step.

---

## 3. Can a parser be reused across pipelined messages without reset, and across connections (`parser-reset!` vs `make-parser` cost — pooling)?

**Status: present for pipelining (empirically confirmed with NO reset call at all); `parser-reset!` measurably cheaper than `make-parser` (empirically confirmed, ~2x on allocation).**

### 3a. Pipelining without any reset call

byte-machine's runtime has **no concept of "message" or "reset between messages" at all** — that is entirely a property of how the MACHINE GRAPH is authored, not of the runtime. The runtime's `parser-reset!` is a full reset to the just-constructed state (see 3b); it is a different, heavier operation than what pipelining needs.

The real HTTP test/bench fixture, `(byte-machine test http-machine)` (`/Users/yuzu/github/byte-machine/test/support/harness/byte-machine/test/http-machine.sls`), demonstrates the intended pattern directly: its `message-complete` callback node chains into a **field-clearing chain that loops back to `idle`**, not into a `stop`/`finish` terminal:

```
;; message-complete, then the completion clear chain resets the message
;; fields (§21.3:1150) and loops to idle; the absolute offset is untouched.
;; `clear` is infallible, so the chain takes no error edge (decision 0037).
(make-callback-node 'msg-complete 'message-complete 'clear-cl '() 'clear-cl #f)
(make-field-action-node 'clear-cl 'clear '(content-length) 'clear-hascl #f #f)
(make-field-action-node 'clear-hascl 'clear '(has-cl) 'clear-haste #f #f)
(make-field-action-node 'clear-haste 'clear '(has-te) 'clear-chunk #f #f)
(make-field-action-node 'clear-chunk 'clear '(chunk-size) 'idle #f #f)
(make-finish-node 'fin #f)
```
— `http-machine.sls:481-487`. Because `idle` is an ordinary dispatch node (not a terminal), the parser's `lifecycle` never leaves `'ready`/`'busy` across a message boundary — it only drops to a sticky terminal (`stopped`/`finished`/`error`) if the GRAMMAR routes there, which this one deliberately never does mid-stream.

This is exactly what byte-machine's own committed benchmark exercises: `bench/runner/benchmark.sps:84` builds `pipelined = (rep-str 5 short-normal)` (5 concatenated `GET / HTTP/1.1...` requests in one bytevector) and `run-once` (`bench/runner/benchmark.sps:108-112`) feeds the WHOLE thing to **one** `make-parser`-built parser in **one** `parser-feed!` call — no reset between the 5 messages. The committed baseline (`bench/fixtures/baseline-tarm64osx.sls`, `pipelined-requests` workload) shows this working at 941,176 req/s (generated lane) with the SAME 1168 B/message allocation as the single-request workloads, i.e. no per-message-boundary allocation spike.

**I confirmed this myself, directly, with no reset call anywhere** (see "Measured" §3a below): one parser fed the identical 39-byte GET request 20,000 times in a row with only `parser-feed!` — zero `parser-reset!` calls — and `message-begin`/`message-complete` each fired exactly 20,000 times, with the parser ending in lifecycle `'ready`.

**Caveat, read from the source rather than measured:** this property is NOT something byte-machine's runtime *guarantees* for an arbitrary machine — it is a property `chez-httparse`'s grammar was deliberately built to have (decision 0037 "clear is infallible", cited in the comment above). A machine whose message-complete equivalent routes through a `stop` node would make the SAME lifecycle sticky (`runtime.sls:989`, `(stopped) (make-parser-result 'stopped start 0 ...)` — every subsequent `parser-feed!` short-circuits with 0 consumed until reset), so chez-http-server should confirm `chez-httparse`'s own grammar keeps this "loop to idle" shape rather than assume it from byte-machine alone. (I did not re-derive this from chez-httparse's own `src/httparse/grammar.sls` in this pass — flagged as an open question below, though the generated `httparse-message.sls`'s state list visibly contains `restart-clear-flags`/`restart-mark`/`amc-*` states that read the same way.)

### 3b. `parser-reset!` cost vs `make-parser` cost

Reading the code: `parser-reset!` (`runtime.sls:1668-1686`) does a `busy` reentrancy check (`:1678-1680`), four `vector-set!`s (current/offset/lifecycle/stored-error, `:1681-1684`), `byte-machine-span-close/v1` (three more `vector-set!`s), and ONE allocation — `(vector-set! parser 8 (copy-values (parser-field-initials parser)))` (`runtime.sls:1686`, `copy-values` itself defined at `:419-422`), a fresh vector sized to the field count. It does **not** re-validate callback bindings, does not touch the callback-slot vector, does not re-check `compiled-machine?`, and does not build a new 18-slot parser vector.

`make-parser` (`runtime.sls:486-527`), by contrast, on every call: checks `compiled-machine?`; walks `resolve-callbacks` (`runtime.sls:373-412`) which validates every binding twice (duplicate check, then "names an unknown declaration" check) and allocates a fresh callback-slot vector sized to the declared-callback count; walks `resolve-field-initials` (`runtime.sls:447-476`) to merge any embedder overrides; allocates a fresh field-values vector via `copy-values`; and allocates the entire new 18-slot parser vector itself.

**I measured this directly** (script + output under "Measured" §3b/§3c below), on the same 217-state HTTP fixture, reusing one `ctx` record and one compiled machine, 20,000 iterations each after a 2,000-iteration warmup:

| | bytes/iteration | wall time |
|---|---:|---:|
| `parser-reset!` + `parser-feed!` (one parser reused) | **432.04 B** | 0.40 µs |
| `make-parser` + `parser-feed!` (fresh parser every message) | **880.07 B** | 0.50 µs |

`make-parser` allocates just over **2× as much** as `parser-reset!` for the same one-message workload, consistent with the source-level accounting above (reset skips callback-binding re-validation and the whole-vector re-allocation that make-parser cannot skip).

**Recommendation:** chez-http-server should pool parsers per connection (build one at accept time, `parser-reset!` it — not `make-parser` again — whenever a NEW message begins after an error/close that left the parser terminal, or simply never reset it at all across the connection's lifetime if the grammar loops to idle as shown in §3a) rather than constructing a fresh parser per request. A connection-scoped pool (parser + its `ctx` record reused across many requests on a keep-alive connection, `parser-reset!` only used to recover a parser left in a terminal/poisoned lifecycle by an error) is both the cheaper and the more idiomatic use of this API.

---

## 4. Is the runtime safe to call re-entrantly (a callback calling `parser-feed!` on the same parser)?

**Status: forbidden AND detected — confirmed empirically, not just from reading source.**

`parser-feed!` sets the parser's lifecycle to `'busy` BEFORE running the executor or any callback (`runtime.sls:1020`, inside the `'ready` arm), and the very first check any nested `parser-feed!`/`parser-finish!`/`parser-resume!`/`parser-reset!` call makes is a `case` on lifecycle:

- `parser-feed!`, `busy` arm: `runtime.sls:998-1000` — `(byte-machine-contract-violation 'parser-feed! 'reentrancy (list (parser-lifecycle parser) 'feed))`.
- `parser-finish!`, `busy` arm: `runtime.sls:1343-1345`, same shape.
- `parser-resume!`, `busy` arm: `runtime.sls:1611-1614`.
- `parser-reset!`, `busy` guard: `runtime.sls:1678-1680` — the ONE place `busy` is checked before any mutation happens ("a callback may not reset the parser it is running inside").

The comment at `runtime.sls:993-997` names the design explicitly: "THREE distinct codes — lifecycle violation, reentrancy, poisoned parser: a caller who fed a paused parser made a sequencing mistake, a callback that fed the parser it is running inside made a reentrancy mistake, and a caller who fed a parser an escaped callback left behind is holding something only reset can reuse."

If a callback raises an uncaught condition or performs a non-local escape (rather than catching the violation itself), the enclosing `dynamic-wind` in `parser-feed!`/`parser-finish!` (`runtime.sls:1024-1027, 1030-1032, 1103-1110` for feed; mirrored for finish) marks the parser **`'poisoned`** — a stronger-than-`busy` state that every operation refuses except `parser-reset!`, which is documented as "the ONLY operation that lets a poisoned parser run" (`runtime.sls:1669-1674`).

**I confirmed this empirically** (script + output under "Measured" §4 below): a `message-begin` callback on the real HTTP fixture called `parser-feed!` on its OWN parser. `(parser-lifecycle parser)` read from inside the callback was `'busy`; the re-entrant `parser-feed!` call raised a `&byte-machine-contract` condition with `code = 'reentrancy`, `who = 'parser-feed!`, `detail = (busy feed)` — matching `runtime.sls:998-1000` exactly. After catching that condition INSIDE the callback (so it never escapes and poisons the outer parse) and returning `callback-continue`, the OUTER `parser-feed!` call completed normally and the parser's final lifecycle was `'ready` — confirming the poison-on-escape path is specifically about an ESCAPING condition/continuation, not about the reentrancy attempt itself.

**Consequence for chez-http-server:** nothing in the connection layer may call `parser-feed!`/`parser-finish!`/`parser-reset!`/`parser-resume!` on a parser from inside one of that SAME parser's own callbacks (directly or through a nested call). Given chez-libuv's own constraint that "callbacks run only inside `uv-run` on the loop thread" and "`uv-run` refuses re-entry from a callback," this composes cleanly: a byte-machine callback that wants to trigger MORE i/o should queue a deferred action (e.g. `uv-write!` outside the callback, or defer to the next `uv-run` iteration) rather than re-enter either library synchronously.

---

## 5. Thread-safety: is there any global mutable state in `runtime.sls`?

**Status: confirmed — no global mutable state.**

```
$ rg -n "^\s*\(define [a-zA-Z*!?-]+\s*\(make-" src/byte-machine/runtime.sls
190:  (define empty-bv (make-bytevector 0))

$ rg -n "^\(set!" src/byte-machine/runtime.sls
(no output)

$ rg -n "hashtable|registry" src/byte-machine/runtime.sls
(no output)
```

The ONE top-level `(define name (make-...))` in the whole 1686-line file is `empty-bv`, a zero-length bytevector used as the slice argument for `parser-finish!`'s EOF walk (`runtime.sls:1338` area, `exec ... empty-bv 0 0 #t ...`). It is immutable by construction (length 0, nothing to write), created once at library-instantiation time, and shared read-only by every parser — this is not shared MUTABLE state. There is no `set!` at the top level of the library body anywhere, and no hashtable/registry (contrast this explicitly with `chez-libuv`'s handle registry, which the project brief already notes is "an unsynchronised eqv-hashtable, single-thread only" — byte-machine has no such thing at all).

Every other piece of state lives inside the per-parser 18-slot vector allocated fresh by `make-parser` (`runtime.sls:462-514`, the vector literal at `:495-497`/`:508-511`) — `current`, `offset`, `lifecycle`, `field-values`, the callback-slot vector, `user-context`, span bookkeeping, all mutated only through `vector-set!` on THAT parser's own vector. Two parsers built from the same `compiled-machine` share the compiled machine's immutable metadata (field decls, callback decls, state-names table — all read-only vectors baked in at `byte-machine-make-compiled-machine`, `runtime.sls:128-152`) but nothing mutable; the comment at `runtime.sls:333-338` makes this an explicit design constraint: "The storage cannot live in the shared op/exec closure... many parsers are built per compiled machine inside per-byte loops, so closure-held storage would let one parser's writes be read by another."

**Nuance worth stating precisely, since the docs are silent on it** (`rg -i thread .reference/*.md README.org` returns nothing about parser thread-safety): the `'busy` lifecycle guard (§4 above) is a **same-call-stack re-entrancy detector**, not a concurrency lock. It is a plain `vector-ref`/`case` comparison with no memory barrier or mutex, so it does NOT protect against two OS threads calling `parser-feed!` on the SAME parser object concurrently — that would be a genuine data race on the parser's vector slots (a `vector-set!` from one thread racing a `vector-ref` from another is unsynchronized in Chez, same as any other mutable Scheme object). The safe reading, consistent with chez-libuv's own single-loop-thread callback model, is: one parser belongs to exactly one OS thread at a time (in chez-http-server's case, the libuv loop thread), and if chez-http-server ever runs multiple libuv loops on multiple threads (one loop per thread, a common libuv pattern), each thread's connections must use their OWN parser instances — never share one parser across loop threads. Two DIFFERENT parsers (even from the same `compiled-machine`) on two different threads are safe simultaneously, because they share no mutable state (confirmed above); the compiled-machine's own metadata is read-only.

---

## 6. How should chez-http-server vendor/depend on the generated `httparse-message.sls`, and what `CHEZSCHEMELIBDIRS` layout does a consumer need?

**Status: present — both siblings already establish and use the exact pattern; verified end to end with a real combined program.**

### The pattern both `chez-httparse` and `uriparse` already use

Both projects vendor byte-machine as a **git submodule pinned by gitlink**, at `vendor/byte-machine`:

```
$ cd /Users/yuzu/github/chez-httparse && git submodule status vendor/byte-machine
 0245db3059504c462b881a550310300fece55216 vendor/byte-machine (v0.6.0)
$ cd /Users/yuzu/github/uriparse && git submodule status vendor/byte-machine
 0245db3059504c462b881a550310300fece55216 vendor/byte-machine (v0.6.0)
```
Both currently pin the IDENTICAL commit, and it is exactly the commit byte-machine's own `v0.6.0` tag points to: `v0.6.0` is an annotated tag (`git rev-parse v0.6.0` returns the tag object `fc8f4a236a164ec114f77bfdcafc77e6491ba66f`, distinct from the commit it names), and `git log --oneline -1 v0.6.0` dereferences it to commit `0245db3`, `"docs(release): Milestone 14 — the close, and v0.6.0 (#138)"` — the exact commit both `chez-httparse` and `uriparse` pin.

`chez-httparse`'s own decision record for this, [0005](file:///Users/yuzu/github/chez-httparse/.plans/decisions/0005-byte-machine-pinned-by-gitlink-generated-abi-5.md) (amended four times as the ABI moved 5→6→7→8, title kept for link stability), states the rule explicitly: "The gitlink, not the tag, is the pin"; "The pin is expected to move, and moving it is a first-class event, not an accident... a CHANGELOG.md entry here as well as there"; "The ABI number is re-read, never remembered" — every bump re-derives `current-abi-version` from the pinned tree rather than trusting a remembered number.

**The generated parser is committed, not built by the consumer at their build time.** `src/generated/httparse-message.sls` (and `httparse-url.sls`) are tracked in git (`git ls-files src/generated/` in `chez-httparse` lists both), NOT in `.gitignore`. Regeneration is a first-class, named Makefile target: `chez-httparse/Makefile:76-77` — `parser-refresh: configure   ## re-emit the checked-in generated parser` → `$(CMAKE) --build build/dev --target httparse_parser_refresh`, with the comment "src/generated/ is DERIVED: emitted from src/httparse/grammar.sls, committed so that what this project ships is reviewable as a diff and loadable without a generator. The determinism lane re-emits and compares bytes, so a grammar edit without a refresh reddens rather than shipping a stale artifact." `uriparse` does the same for `src/generated/uri-scanner.sls` (`uriparse/Makefile:78`).

The generated file's own header documents its two-line dependency footprint: `(import (rnrs) (byte-machine runtime))` — `chez-httparse/src/generated/httparse-message.sls:3`, `uriparse/src/generated/uri-scanner.sls:3`. Both generated files embed the literal ABI they were built against: `(byte-machine-make-compiled-machine 9 ...)` at `chez-httparse/src/generated/httparse-message.sls:3863` and `uriparse/src/generated/uri-scanner.sls:437` — both **9**, matching the pinned byte-machine v0.6.0's `current-abi-version` (`runtime.sls:92`).

`chez-httparse`'s own `docs/api.org:9-16` gives the consumer-facing import list directly:
```scheme
(import (generated httparse-message)   ; httparse-message-machine
        (httparse modes)               ; the mode tables, pure
        (byte-machine runtime))        ; make-parser, parser-feed!, ...
```

### What CHEZSCHEMELIBDIRS layout works — verified by actually running it

I wrote and ran a program importing ALL FIVE libraries at once (`libuv`, the generated httparse parser, httparse's mode tables, byte-machine's runtime, and uriparse's collector), from a single `CHEZSCHEMELIBDIRS`:

```
$ CHEZSCHEMELIBDIRS="/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src:/Users/yuzu/github/uriparse/src" \
  chez --program combined-import-test.sps
libuv make-uv-loop: #t
httparse-message-machine compiled?: #t
httparse mode request value: 1
byte-machine make-parser proc?: #t
uri-parse proc?: #t
ALL IMPORTS OK
```
(program: `combined-import-test.sps`, full text under "Measured" §6 below). Five colon-separated roots, one `(byte-machine runtime)` resolved from `chez-httparse/vendor/byte-machine/src` (first match), and every one of the five target libraries imports and works with no conflict.

**I also tested the failure mode this raises** — putting BOTH `chez-httparse/vendor/byte-machine/src` AND `uriparse/vendor/byte-machine/src` on the path simultaneously (i.e., what happens if chez-http-server naively includes every sibling's own vendor copy):
```
$ CHEZSCHEMELIBDIRS="...:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src:...:/Users/yuzu/github/uriparse/vendor/byte-machine/src" \
  chez --program combined-import-test.sps
ALL IMPORTS OK   (identical output)
```
This works TODAY only because both pins happen to be byte-for-byte identical (verified above). Chez resolves a library from the FIRST root on the path that has it and does not detect or warn about a second, different copy further down the path — this is documented as deliberate upstream behavior in byte-machine's own build tooling: "Chez consults library-directories entries in order and takes the first source it can resolve" (`/Users/yuzu/github/byte-machine/cmake/ByteMachineSchemeLane.cmake:146` comment, "library-directories becomes both halves of the pair"). If `chez-httparse` and `uriparse` ever bump their byte-machine pins independently and land on DIFFERENT commits, this silently resolves to whichever one is listed first — the loser's `(generated ...)` library would then carry an ABI literal computed against a DIFFERENT `current-abi-version` than the runtime actually loaded, which `byte-machine-make-compiled-machine`'s version check (`runtime.sls:128-138`) WOULD catch (assertion-violation "generated-runtime ABI mismatch") — so a divergence fails loudly at parser construction, not silently, but only at run time, not at build/CI time.

**Recommendation for chez-http-server:**
1. **Vendor exactly one byte-machine submodule directly** in chez-http-server (`vendor/byte-machine`, gitlink-pinned, following `chez-httparse`/`uriparse`'s own decision 0005 pattern), and put ITS `src/` on the library path ahead of (or instead of) the two siblings' own `vendor/byte-machine/src` copies. chez-http-server does not need to construct or emit any byte-machine machine of its own (that is `chez-httparse`'s job per the architecture doc), so this vendored copy exists purely to supply `(byte-machine runtime)` at one, chez-http-server-controlled version.
2. **Add a `check-pins`-style Makefile target** (mirroring `chez-libuv`'s own `check-pins`, `/Users/yuzu/github/chez-libuv/Makefile:174` area) that asserts chez-http-server's own byte-machine gitlink matches — or is at least ABI-compatible with — whatever `chez-httparse` and `uriparse` each declare in THEIR `.gitmodules`/gitlinks, so a silent three-way pin drift is caught in CI rather than discovered as a run-time ABI-mismatch assertion.
3. **The full CHEZSCHEMELIBDIRS layout a consumer needs, in one variable**, is the concatenation of: `chez-libuv/src` + `chez-libuv/build/scheme-libs` (the vendored srfi shim dependency) + `chez-httparse/src` (for `(generated httparse-message)`, `(httparse modes)`) + ONE `.../vendor/byte-machine/src` (for `(byte-machine runtime)`) + `uriparse/src` (for `(generated uri-scanner)`, `(uri collect)` and friends) — five roots, verified working together above.

---

## 7. Ahead-of-time compilation of the whole stack

**Status: present — the pattern is used by all three sibling projects' own test/CI AOT lane; reproduced end to end for the full 5-library, 27-file combined stack.**

byte-machine's own AOT lane (`test/support/launchers/chez-compile.ss`) is the reference implementation. Its load-bearing lines:

```scheme
(compile-imported-libraries #t)   ; chez-compile.ss:137
(generate-wpo-files #f)           ; chez-compile.ss:144 -- DECLINED, deliberately
(source-directories '())          ; chez-compile.ss:152
(library-directories (map cons library-roots object-dirs))  ; chez-compile.ss:153
(compile-program program output)  ; chez-compile.ss:155
```
`generate-wpo-files` is explicitly declined, not merely left at a default: "whole-program optimisation would add a second compiled-artifact shape (a .wpo file) for the fingerprint binding mechanism to track, and a portability proof does not need the extra optimisation it buys" (`chez-compile.ss:139-143`). `library-directories` is a list of `(source-root . object-dir)` pairs, one per library root the program transitively imports — `compile-program` then compiles every transitively-imported `.sls` it finds under a source root into the paired object dir as it goes (visible directly in my run below: `compile-imported-libraries #t` makes ONE `compile-program` call recursively compile all 27 libraries the entry program imports).

To LOAD a compiled program without any chance of falling back to source, the companion `chez-aot.ss` launcher pairs every OBJECT directory with one always-EMPTY "source guard" directory on `library-directories`, and empties `source-directories` too — this is what stops Chez from silently re-expanding source it finds alongside (or ahead of) a compiled `.so` (`chez-aot.ss` header comment, "WHY THE LIBRARY PATH PAIRS EVERY OBJECT DIRECTORY WITH AN EMPTY SOURCE GUARD").

**I reproduced this for the ENTIRE composed stack** (chez-libuv + chez-httparse's generated parser + its vendored byte-machine + uriparse), compiling the same `combined-import-test.sps` from §6:

```
$ time chez --script chez-aot-compile.ss
compiling .../combined-import-test.sps with output to .../combined-import-test.so
compiling /Users/yuzu/github/chez-libuv/src/libuv.sls with output to .../aot-objs/libuv-src/libuv.so
  ... (16 chez-libuv .sls files) ...
compiling /Users/yuzu/github/chez-httparse/src/generated/httparse-message.sls with output to .../aot-objs/httparse-src/generated/httparse-message.so
compiling /Users/yuzu/github/chez-httparse/vendor/byte-machine/src/byte-machine/runtime.sls with output to .../aot-objs/httparse-bm/byte-machine/runtime.so
  ... (2 more byte-machine private .sls files) ...
compiling /Users/yuzu/github/chez-httparse/src/httparse/modes.sls with output to .../aot-objs/httparse-src/httparse/modes.so
compiling /Users/yuzu/github/uriparse/src/uri/collect.sls with output to .../aot-objs/uriparse-src/uri/collect.so
  ... (5 more uriparse .sls files) ...
compiled: .../combined-import-test.so
chez --script chez-aot-compile.ss  0.72s user 0.04s system 97% cpu 0.774 total
```
27 `.sls` files compiled to 27 `.so` object files (716 KB total) plus a 4.0 KB top-level program object, in **0.774 s wall** on this machine (Chez 10.4.1, tarm64osx). Then loading and RUNNING the compiled program, with `library-directories` paired to empty source-guard dirs exactly as `chez-aot.ss` does:

```
$ time chez --script chez-aot-run.ss
libuv make-uv-loop: #t
httparse-message-machine compiled?: #t
httparse mode request value: 1
byte-machine make-parser proc?: #t
uri-parse proc?: #t
ALL IMPORTS OK
chez --script chez-aot-run.ss  0.03s user 0.01s system 80% cpu 0.058 total
```
**0.058 s** to load-and-run the AOT-compiled program, vs **0.376-0.398 s** for the equivalent plain source-mode run of the same program over the same five library roots (measured immediately after, same machine, both cold and warm — Chez re-expands from source every time in source mode; there is no persistent compiled-object cache written by plain `chez --program`):
```
$ time CHEZSCHEMELIBDIRS="..." chez --program combined-import-test.sps
... CHEZSCHEMELIBDIRS="..." chez --program combined-import-test.sps  0.36s user 0.03s system 97% cpu 0.398 total
$ time CHEZSCHEMELIBDIRS="..." chez --program combined-import-test.sps   # run again
... 0.36s user 0.02s system 99% cpu 0.376 total
```
About **6-7× faster startup** for this stack's size once AOT-compiled — consistent with byte-machine's own committed baseline, which separately records `generation-time-ms 5` and `aot-object-size-bytes 71370` for just the HTTP grammar alone (`bench/fixtures/baseline-tarm64osx.sls:1`, `one-time-metrics`).

**Recommendation for chez-http-server:** for a deployable server binary, follow the exact `chez-compile.ss`/`chez-aot.ss` two-step pattern: one `library-directories` mapping (each source root paired to ITS OWN object directory, never sharing one) for the compile step with `compile-imported-libraries #t` and `generate-wpo-files #f`, and a SEPARATE load-time `library-directories` mapping (each object directory paired to a shared EMPTY source-guard directory) so the deployed binary can never silently fall back to — or be shadowed by — source. Do not turn on `generate-wpo-files`; none of the three sibling projects use it, for the reason `chez-compile.ss:139-143` gives, and turning it on would add a `.wpo`-file dimension to chez-http-server's own build caching that no sibling's tooling currently handles.

---

## 8. Makefile/CMake conventions across the siblings, and a recommendation for chez-http-server

**Status: present — three of the four siblings already share one convention; the fourth is a deliberate, motivated exception.**

```
$ wc -l chez-libuv/Makefile byte-machine/Makefile chez-httparse/Makefile uriparse/Makefile
     690 chez-libuv/Makefile
      69 byte-machine/Makefile
      77 chez-httparse/Makefile
      82 uriparse/Makefile
$ ls */CMakeLists.txt
byte-machine/CMakeLists.txt  chez-httparse/CMakeLists.txt  uriparse/CMakeLists.txt
(chez-libuv/CMakeLists.txt: No such file or directory)
```

**byte-machine, chez-httparse, and uriparse** all use the SAME shape: a small (69-82 line) Makefile that is a thin, self-documenting front over `CMakePresets.json` + `CMakeLists.txt`, with an IDENTICAL core target set —
```
.PHONY: all help doctor configure build dev test test-all prod clean [+ project-specific extras]
all: build
help:    ## awk-scans this Makefile's own '## ' comments (self-documenting, cannot drift)
doctor:  ## $(CMAKE) --preset dev   (discovery only, then stop)
configure: $(CMAKE) --preset dev
build: configure  $(CMAKE) --build --preset dev
dev: build   $(CTEST) --preset harness
test: build  $(CTEST) --preset pr
test-all: build  $(CTEST) --preset release
prod: $(CMAKE) --preset prod && --build --preset prod
clean: $(CMAKE) -E rm -rf build
```
(`byte-machine/Makefile:21-69`; `chez-httparse/Makefile:21-60` identical shape plus `corpus-refresh`/`parser-refresh`; `uriparse/Makefile:21-63,72-81` identical shape plus its own `no-scheme`/`corpus-refresh`/`parser-refresh`). The presets work identically without `make` — `cmake --preset dev` — which matters on Windows (`byte-machine/README.org`, "Building and testing" section), and the two parser-generating siblings each add exactly one project-specific pair of targets: `corpus-refresh` (re-vendor the upstream conformance corpus) and `parser-refresh` (re-emit the checked-in generated `.sls`, `chez-httparse/Makefile:76-77`, `uriparse/Makefile:78`).

**chez-libuv is a deliberate, motivated exception**, not a fourth variant of the same pattern: its 690-line Makefile does everything itself with NO CMake at all — native shim compilation, `pkg-config`-vs-vendored libuv acquisition, chez-srfi submodule vendoring with symlink-based percent-decoding, `check-pins` (verifying THREE independent version-pin sources agree), `check-purity`, Valgrind/ASan memory-testing lanes including a Docker fallback, and root-gated privileged tests (`chez-libuv/Makefile:157-689`, targets `deps-info`, `deps`, `check-pins`, `check-purity`, `test-root`, `test-memory`, `test-memory-docker`, `check-prod`). This is exactly the shape you'd expect for the ONE project in the set that compiles and links a native C shim against a system library with a version range, rather than being a pure-Scheme code generator/library.

**Recommendation for chez-http-server:** chez-http-server is, like byte-machine/chez-httparse/uriparse, a pure-Scheme composition with no C shim of its own to build (it depends on chez-libuv's ALREADY-BUILT shim, not on building one) — so it should follow the byte-machine/chez-httparse/uriparse Makefile-front-over-CMake-presets convention, not chez-libuv's from-scratch pattern. AGENTS.md's request for `make build/dev/test/clean/prod` (plus `help`) maps directly onto the shared target set above with zero renaming needed. CMake's role here would be narrower than in the parser-generating siblings (no `corpus-refresh`/`parser-refresh` — chez-http-server generates no byte-machine grammar of its own) but still earns its keep for: (a) the same `doctor`/toolchain-discovery pattern all three siblings use to find Chez without a hardcoded path, (b) CTest presets to run the pull-request vs full test selection distinctly (matching the `test`/`test-all` split AGENTS.md's TDD discipline implies), and (c) the AOT `compile-program`/`compile-file` lane from §7, which chez-httparse and uriparse both already drive through their own CMake presets (their `aot`-mode Scheme lanes, `byte-machine/cmake/ByteMachineSchemeLane.cmake:130-152` shows the exact command shape) rather than hand-rolling it in the Makefile the way chez-libuv would have to for its native build. If chez-http-server ever needs no-C-toolchain-required specification tests (mirroring byte-machine's `no-scheme` preset, `byte-machine/README.org` "Building and testing"), the same `cmake --preset no-scheme && ctest --preset no-scheme` pattern is directly reusable.

---

## Measured: commands and verbatim output

All commands run against byte-machine commit `0245db3059504c462b881a550310300fece55216` (v0.6.0), Chez 10.4.1, `tarm64osx`, on 2026-09-19. Scripts referenced below are saved under this scratchpad's root (not under `research/`):
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/{combined-import-test.sps, chez-aot-compile.ss, chez-aot-run.ss, ctx-and-reset-bench.sps, reentrancy-test.sps}`.

### §6/§7 — `combined-import-test.sps` (imports all five libraries at once)

```scheme
(import (rnrs)
        (libuv)
        (generated httparse-message)
        (httparse modes)
        (byte-machine runtime)
        (uri collect))

(display "libuv make-uv-loop: ") (display (procedure? make-uv-loop)) (newline)
(display "httparse-message-machine compiled?: ") (display (compiled-machine? httparse-message-machine)) (newline)
(display "httparse mode request value: ") (display (httparse-message-type-value 'request)) (newline)
(display "byte-machine make-parser proc?: ") (display (procedure? make-parser)) (newline)
(display "uri-parse proc?: ") (display (procedure? uri-parse)) (newline)
(display "ALL IMPORTS OK") (newline)
```

Run:
```
$ CHEZSCHEMELIBDIRS="/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src:/Users/yuzu/github/uriparse/src" chez --program combined-import-test.sps
libuv make-uv-loop: #t
httparse-message-machine compiled?: #t
httparse mode request value: 1
byte-machine make-parser proc?: #t
uri-parse proc?: #t
ALL IMPORTS OK
```
(Also re-run successfully with BOTH `chez-httparse/vendor/byte-machine/src` and `uriparse/vendor/byte-machine/src` on the path simultaneously — identical output — see §6 discussion above.)

Source-mode timing (two runs, for comparison with the AOT numbers in §7):
```
$ time CHEZSCHEMELIBDIRS="..." chez --program combined-import-test.sps
...  0.36s user 0.03s system 97% cpu 0.398 total
$ time CHEZSCHEMELIBDIRS="..." chez --program combined-import-test.sps
...  0.36s user 0.02s system 99% cpu 0.376 total
```

### §7 — AOT compile (`chez-aot-compile.ss`) and load (`chez-aot-run.ss`)

`chez-aot-compile.ss` (library-directories pairs each of the 5 source roots to its own object dir under `scratchpad/aot-objs/`; mirrors byte-machine's `test/support/launchers/chez-compile.ss:137-155`):
```scheme
(compile-imported-libraries #t)
(generate-wpo-files #f)
(source-directories '())
(library-directories
 (list (cons "/Users/yuzu/github/chez-libuv/src" ".../aot-objs/libuv-src")
       (cons "/Users/yuzu/github/chez-libuv/build/scheme-libs" ".../aot-objs/libuv-shim")
       (cons "/Users/yuzu/github/chez-httparse/src" ".../aot-objs/httparse-src")
       (cons "/Users/yuzu/github/chez-httparse/vendor/byte-machine/src" ".../aot-objs/httparse-bm")
       (cons "/Users/yuzu/github/uriparse/src" ".../aot-objs/uriparse-src")))
(compile-program ".../combined-import-test.sps" ".../combined-import-test.so")
```
```
$ time chez --script chez-aot-compile.ss
compiling .../combined-import-test.sps with output to .../combined-import-test.so
compiling /Users/yuzu/github/chez-libuv/src/libuv.sls ...
  [16 chez-libuv .sls files, all under libuv-src/]
compiling /Users/yuzu/github/chez-httparse/src/generated/httparse-message.sls ...
compiling /Users/yuzu/github/chez-httparse/vendor/byte-machine/src/byte-machine/runtime.sls ...
compiling /Users/yuzu/github/chez-httparse/vendor/byte-machine/src/byte-machine/private/conditions.sls ...
compiling /Users/yuzu/github/chez-httparse/vendor/byte-machine/src/byte-machine/private/names.sls ...
compiling /Users/yuzu/github/chez-httparse/src/httparse/modes.sls ...
compiling /Users/yuzu/github/uriparse/src/uri/collect.sls ...
compiling /Users/yuzu/github/uriparse/src/generated/uri-scanner.sls ...
compiling /Users/yuzu/github/uriparse/src/uri/components.sls ...
compiling /Users/yuzu/github/uriparse/src/uri/vocabulary.sls ...
compiling /Users/yuzu/github/uriparse/src/uri/charset.sls ...
compiling /Users/yuzu/github/uriparse/src/uri/percent.sls ...
compiled: .../combined-import-test.so
chez --script chez-aot-compile.ss  0.72s user 0.04s system 97% cpu 0.774 total

$ find aot-objs -name "*.so" | wc -l
27
$ du -sh aot-objs combined-import-test.so
716K  aot-objs
4.0K  combined-import-test.so
```

`chez-aot-run.ss` (each object dir paired to one shared empty source-guard dir, mirroring `chez-aot.ss`):
```scheme
(library-directories
 (list (cons ".../scratchpad/empty-guard" ".../aot-objs/libuv-src")
       (cons ".../scratchpad/empty-guard" ".../aot-objs/libuv-shim")
       (cons ".../scratchpad/empty-guard" ".../aot-objs/httparse-src")
       (cons ".../scratchpad/empty-guard" ".../aot-objs/httparse-bm")
       (cons ".../scratchpad/empty-guard" ".../aot-objs/uriparse-src")))
(source-directories '())
(load-program ".../combined-import-test.so")
```
```
$ time chez --script chez-aot-run.ss
libuv make-uv-loop: #t
httparse-message-machine compiled?: #t
httparse mode request value: 1
byte-machine make-parser proc?: #t
uri-parse proc?: #t
ALL IMPORTS OK
chez --script chez-aot-run.ss  0.03s user 0.01s system 80% cpu 0.058 total
```

### §1/§3 — `ctx-and-reset-bench.sps` (run against `(byte-machine test http-machine)`, `--libdirs test/support/harness:src` from inside `/Users/yuzu/github/byte-machine`)

```
$ chez --libdirs test/support/harness:src --program ctx-and-reset-bench.sps
=== (0) SAME parser, NO reset at all, N sequential messages ===
ctx begins/completes after 20000 messages via the SAME parser, NEVER reset: 20000/20000
lifecycle after run: ready

=== (1) callback dispatch allocation, mutable-record ctx ===
iterations: 20000
ctx begins/completes after run: 22000/22000
total bytes allocated: 8640816
bytes / iteration (feed + 2 callbacks + reset): 432.0408

=== (3a) parser-reset! cost: reuse ONE parser across N messages ===
bytes/iter (reset+feed): 432.0408
ms total: 8
us/iter: 0.4

=== (3b) make-parser cost: FRESH parser per message, N times ===
bytes/iter (make-parser+feed): 880.0736
ms total: 10
us/iter: 0.5
```
(22000 = 2000 warmup + 20000 measured, for the run that shares the warmed-up parser between the display and the timed loop — consistent.)

Full script:
```scheme
(import (rnrs) (rnrs eval)
        (only (chezscheme) load statistics sstats-bytes collect real-time)
        (byte-machine test http-machine)
        (byte-machine verify)
        (byte-machine compile)
        (byte-machine runtime))

(define req (string->utf8 "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
(define N 20000)
(define comp (compile-machine (make-http-machine) '()))
(unless (compilation-ok? comp)
  (assertion-violation 'bench "verification failed" (compilation-diagnostics comp)))
(define gen-file ".../ctx-bench-gen.sls")
(call-with-port (open-file-output-port gen-file (file-options no-fail))
  (lambda (p) (emit-machine comp 'ctx-bench-machine p)))

(define-record-type ctx (fields (mutable begins) (mutable completes)))
(define (make-callbacks)
  (list (list 'message-begin (lambda (parser c) (ctx-begins-set! c (+ 1 (ctx-begins c))) callback-continue))
        (list 'message-complete (lambda (parser c) (ctx-completes-set! c (+ 1 (ctx-completes c))) callback-continue))))

(load gen-file)
;; library name is (generated <machine-name>) = (generated httpreq), NOT the
;; emit-machine binding -- make-http-machine's machine-name is 'httpreq
;; (http-machine.sls:114).
(define cm (eval 'ctx-bench-machine (environment '(generated httpreq))))

;; (0), (1), (3a), (3b) as shown in the output above -- see the scratchpad
;; file for the full timing/allocation loops (do-loops around parser-feed!,
;; parser-reset!, and make-parser, bracketed by (collect) and sstats-bytes).
```

### §4 — `reentrancy-test.sps`

```
$ chez --libdirs test/support/harness:src --program reentrancy-test.sps
lifecycle observed FROM WITHIN the callback (should be 'busy): busy
exception object caught by the re-entrant parser-feed! call: #<condition &byte-machine-contract>
condition? #t
who-condition (if any): n/a
message-condition (if any): n/a
irritants (if any): n/a
byte-machine-contract-condition? #t
  code: reentrancy
  who: parser-feed!
  detail: (busy feed)
parser lifecycle AFTER the outer feed returned: ready
```
```scheme
(import (rnrs) (rnrs eval)
        (only (chezscheme) load)
        (byte-machine test http-machine)
        (byte-machine verify)
        (byte-machine compile)
        (byte-machine runtime)
        (byte-machine private conditions))

(define req (string->utf8 "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
(define comp (compile-machine (make-http-machine) '()))
(define gen-file ".../reentrancy-gen.sls")
(call-with-port (open-file-output-port gen-file (file-options no-fail))
  (lambda (p) (emit-machine comp 'reentrancy-machine p)))
(load gen-file)
(define cm (eval 'reentrancy-machine (environment '(generated httpreq))))

(define p #f) (define caught #f) (define lifecycle-during #f) (define lifecycle-after #f)

(define (on-message-begin parser ctx)
  (set! lifecycle-during (parser-lifecycle parser))
  (call/cc
    (lambda (k)
      (with-exception-handler
        (lambda (e) (set! caught e) (k callback-continue))
        (lambda ()
          (parser-feed! parser req 0 (bytevector-length req))  ; RE-ENTRANT call
          (k callback-continue))))))
(define (on-message-complete parser ctx) callback-continue)

(set! p (make-parser cm (list (list 'message-begin on-message-begin)
                               (list 'message-complete on-message-complete)) #f))
(parser-feed! p req 0 (bytevector-length req))
(set! lifecycle-after (parser-lifecycle p))
;; ... display forms shown in the output above ...
```

---

## Open questions (not settled in this pass)

1. **Does `chez-httparse`'s own grammar (`src/httparse/grammar.sls`) actually route `message-complete` the same "loop to idle, no reset needed" way the test fixture `(byte-machine test http-machine)` does?** I confirmed the PATTERN exists and works (both in byte-machine's own test fixture and empirically in my own run), and the generated `httparse-message.sls`'s state list visibly contains `restart-clear-flags`/`restart-mark`/`amc-*` (after-message-complete) states that read the same way, plus the project brief's own measured fact ("feeding two pipelined requests... yields on-message-complete for the first message" — i.e. it DOES continue past one message without erroring) is consistent with this. But I did not walk `chez-httparse/src/httparse/grammar.sls` node-by-node to confirm it never routes through a `stop` node between messages the way this report confirms for byte-machine's OWN fixture. This is chez-httparse-specific, not a byte-machine gap, and is better answered by whichever gap-analysis pass covers chez-httparse directly.
2. **Cross-process/cross-loop-thread parser sharing** (§5's nuance) is my own analysis from the source, not something byte-machine's docs state one way or the other — worth a direct question to the byte-machine maintainers (or a `.decisions/` entry) if chez-http-server ever adopts a multi-loop-thread architecture, since it currently has none written down.
3. **`current-abi-version` will move again** (it has moved 4 times across byte-machine's own milestones 5→6→7→8→9) — chez-http-server's own `check-pins`-equivalent (recommended in §6) should assert the number is READ from the vendored tree at CI time, per chez-httparse's decision 0005 item 5 ("The ABI number is re-read, never remembered"), rather than hardcoded anywhere in chez-http-server's own docs or code.
