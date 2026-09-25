# 0002: The connection is a pure state machine; the shell interprets its actions

Date: 2026-09-19
Status: accepted
Plan: [async-model options](../2026-09-19-async-model-options.md) "The chosen hybrid"

## Context

chez-httparse fires its 25 callbacks synchronously inside `parser-feed!` and requires an answer from each; byte-machine refuses a re-entrant feed and poisons a parser whose callback escapes (`runtime.sls:998-1059`); chez-libuv refuses `uv-run` from a callback. So every wait is an event that arrives later, and nothing that can raise may run inside a parser callback. The sans-I/O proposal built and measured exactly this shape: 13/13 connection-semantics checks with no sockets, the same core under a real loop over loopback.

## Decision

1. `conn-step : ConnState × Event → (values ConnState (Listof Action))` is pure: it allocates only Scheme data, calls no chez-libuv or byte-machine procedure, and reads no clock (`tick` carries `now`).
2. Events: `bytes-arrived`, `eof`, `read-error`, `write-completed`, `shutdown-completed`, `closed`, `tick`, `parser-event`, `parser-result`, `handler-responded`, `handler-body-chunk`, `handler-body-end`, `handler-failed`, `body-credit`, `shutdown-requested`. Actions: `reply-parser`, `feed-parser`, `resume-parser`, `write`, `read-stop`, `read-start`, `call-handler`, `deliver-body`, `deliver-body-end`, `notify-producer`, `arm-deadline`, `disarm-deadline`, `shutdown`, `close`, `log`. An unknown event is an assertion violation (a test-caught bug, never a runtime path).
3. `reply-parser` is the one action consumed synchronously, inside the parser callback that produced it. Every other action is queued while a feed is running and executed after the outermost `dispatch!` returns (run-to-completion, depth-counted around `drain!` as well as `parser-feed!`).
4. Parser flags, method, version and content-length are read inside `on-headers-complete` and carried in the event, because the inter-message reset zeroes them.
5. A server-level `server-step` of the same shape owns accept, drain and shutdown.

## Consequences

- The llhttp request fixtures replay through the core at every chunk size with a recording adapter; the ratchet lists every fixture. Connection-semantics tests are `(state, event) → (state', actions)` tables.
- The allocation gate for the core is ≤ 3 KiB per request on the CPS spike's workload (naive prototype: 6,832 B; CPS: 2,672 B), met by a linear mutable accumulator and retained spans.
- One contract test gates every shell: identical wire bytes and action traces for the same scripted events.

## Amendment (2026-09-23) — the sixteenth action

Decision 2's action list above names fifteen actions and misses one:
[0006](0006-http10-is-supported-h2c-answers-505-one-upgrade-hand-off-hook.md) item 3
has the core emit `(hand-off request unconsumed-bytes)` when the parser pauses for an
upgrade. The closed action set is therefore sixteen: the fifteen above plus `hand-off`.
M2.1 ships it that way as `conn-actions` in `src/http-server/connection.sls` (PR #7,
85e7d81), and `tests/test-connection-table.sps` fails if `hand-off` is dropped
(mutation M2.1-F, `.superpowers/sdd/m2-mutations.md`). M2.1 emits `(hand-off request)`;
the unconsumed bytes join it once the pause loop retains them (M2.4), and 0006 puts
the contract test in M8. The fifteen events and the rest of this decision are
unchanged. Design §4.1 and the milestone plan's M2.1 entry repeat decision 2's
fifteen; this amendment is where the sixteenth is recorded.

## Amendment (2026-09-23) — what the allocation gate measures

The consequence above sets the gate at "≤ 3 KiB per request on the CPS spike's
workload" and cites two priors that measured different things. This note pins down
what it means.

1. **Where the number comes from.** It was set in the research phase's performance
   review (`research/judge-performance-operability.md` §5) as the CPS prototype's
   measured 2,672 B rounded up to the next KiB, with the naive prototype's 6,832 B as
   the design to avoid. No throughput or latency target lies behind it, and the brief
   sets none. It is a regression ratchet ("no worse than the known-good design"), not
   a derived requirement.
2. **It is a total.** The 2,672 B it was set from was measured over the whole feed
   (`research/spike/cps-core.sps` §4), parser included. On the same workload the parser
   alone costs 1,600 B of it (re-measured at the v0.4.0 pin on 2026-09-23 by
   `research/spike/m2-event-alloc.sps`). So the gate counts every byte allocated per
   request (parser, adapter and core), read as a difference of the cumulative
   `sstats-bytes` counter and never of the live heap. The naive prior measured the pure
   core alone, so it is not comparable; it stays only as the counterexample.
   cps-core's handler writes no response, so the response path is outside the
   anchor: M3 re-measures with it in the loop (milestone plan §7) and records here
   whether it fits.
3. **Shape is the real guard.** A total catches a regression only once the sum
   crosses the line. M2.1's per-callback event lists cost 1,248 B per request and put
   its cycle at 3,280 B before any request bytes were copied. So, following
   chez-httparse's allocation lane ("the claim is a shape, not a number"), M2.2 and
   M2.3 add shape checks beside the total:
   - no allocation per parser callback unless the core keeps that callback's data;
   - no allocation that grows with header or target length (retained spans, not
     copies);
   - a cost per request that stays constant, rather than growing per callback or per
     byte.
4. **A byte target waits for a throughput goal.** None exists yet, and M8's load
   smoke is the first place one can come from. Until then 3 KiB stands as the
   ratchet, and a measured reason to move it gets a dated note here, as the milestone
   plan's §10 expects of every ceiling.

## Amendment (2026-09-23) — parser callbacks enter directly

Item 1's `conn-step` stays the one interface for every event, and it is still what the
table tests and the fake shell drive. Parser callbacks also get a second way into the
same transitions, one that allocates nothing. The reason is that the tagged list built
per callback is the largest cost the core adds. In `research/spike/m2-event-alloc.sps`
(2026-09-23), M2.1's lists cost 1,248 B of its 3,280 B per-request cycle, and the same
cycle with no event per callback measured 2,032 B. The rules:

1. **The adapter passes the callback's own arguments**, so nothing is allocated to
   carry them. There are two shapes:
   - one for the 24 callbacks that carry a span or nothing: the callback name, plus
     `bv from to` when there is a span;
   - one for `on-headers-complete`. Its method, version, flags and content-length are
     read by the adapter inside the callback (item 4) and passed as arguments, since
     the core calls no byte-machine procedure. On this path, item 4's "carried in the
     event" means carried in those arguments.
2. **It returns what `conn-step` returns**: the state and the action list, with
   `reply-parser` first, as item 3 requires.
3. **One implementation.** `conn-step`'s `parser-event` arm only unpacks the tagged
   list and calls the entry point, so the transitions live in one place. A test drives
   the same callbacks both ways and requires the same states and actions.
4. **The core builds whatever it keeps from a span**, since there is no event tail left
   to share. It allocates only for data it retains, which is the first shape check in
   the previous amendment.
5. **The callback names are a closed set**, like the events: an unknown name is an
   assertion violation.

A consequence: the real shell's parser events are no longer data, so tracing them
needs an explicit hook in the adapter (M4). The work is M2.2's first step, before the
request accumulator.

## Amendment (2026-09-24) — two rare target forms run uriparse's scanner

Item 1 says `conn-step` calls no byte-machine procedure. M2.3 judges the
request-target at `on-headers-complete` (milestone plan §6), and two of RFC 9112
§3.2's four forms can only be judged by a parse. The rules:

1. **What changes.** For an absolute-form target, and for CONNECT's
   authority-form target, the core runs uriparse's own scanner through
   `(http-server target)`. Absolute-form uses one collector per connection,
   made on the connection's first absolute-form target and reset before each
   one, and judged with `uri-parse-result-validate`. CONNECT uses the strict
   `uri-parse-authority-form-validate`, which parses fresh. Both are byte-machine
   parsers, and they run inside the chez-httparse callback that entered the core.
2. **What does not change.** The core never feeds, resumes, resets or reads the
   chez-httparse parser that calls it, and the adapter still reads that parser's
   fields (the third amendment). Origin-form, the form nearly every request
   carries, runs no parser at all. Its path and query go to `(uri charset)`'s
   `validate-component`, which is pure.
3. **Why item 1's reason still holds.** The rule exists because nothing that
   can raise may run inside a parser callback (the context above). byte-machine's
   reentrancy guard is per parser (`runtime.sls:985-1059`), so running a second
   parser inside the first one's callback is not re-entry. The judge owns its
   collector, resets it before every target, and feeds it one whole target in one
   call. uriparse returns every verdict as data (design §6.2). A contract
   violation from the scanner would be a bug in the judge, just as an unknown
   event is a bug in the core.
4. **What it costs.** Measured 2026-09-24 on Darwin arm64, Chez 10.4.1
   `tarm64osx`, by `research/spike/m2.3-target-alloc.sps` and
   `tests/test-connection-allocation.sps`:
   - an absolute-form request costs 4,336 B against origin-form's 2,640 B. That
     is one reused collector's parse in place of the path's copy, and the
     allocation suite holds it to exactly that, so a collector made per request
     turns it red;
   - a CONNECT target's fresh parse costs 3,696 B.

   Neither form is on the workload the ratchet measures, and design §7.5 already
   accepted CONNECT's fresh parse.

   Since 2026-09-24, evening, origin-form copies nothing (the next amendment's
   closing note). Absolute-form still costs 4,336 B, now one reused collector's
   parse more than origin-form's 2,624 B, and the allocation suite holds it to
   exactly that.

Decided on the owner's word on 2026-09-24, together with the origin-form route and
the three form rules recorded in the ledger's M2.3 entry.

## Amendment (2026-09-24) — the target-length shape is carried until uriparse #21

The second amendment's second shape says no allocation grows with the target's
length. M2.3 carries one exception, decided on the owner's word on 2026-09-24:

- **The exception.** To judge an origin-form target, its path and query are
  copied before `(uri charset)`'s `validate-component` sees them. That validator
  takes a whole bytevector and has no range.
- **What it costs.** A request grows by about one byte per target byte. On the
  CPS workload it costs 2,640 B, against 2,624 B with no validation, and the same
  request with a 500-byte target costs 3,136 B (measured 2026-09-24, Darwin arm64,
  Chez 10.4.1 `tarm64osx`).
- **The request.** uriparse #21 (filed 2026-09-24) asks for a validator that
  takes a range. Until it lands, `tests/test-connection-allocation.sps` holds the
  growth to exactly the copy. Header length still costs nothing. Once #21 lands,
  the check falls back to "a 500-byte target costs what a short one does".
- **Closed (2026-09-24, evening).** uriparse v0.5.0 (4d95118) released #21, and
  the judge now reads an origin-form target's path and query in place: it copies
  nothing. The CPS workload costs 2,624 B, the figure with no validation, and a
  500-byte path or a 500-byte query costs the same (measured the same day, on the
  same platform). The check has fallen back as planned, and this exception is
  closed. The second shape holds on the workload the gate measures: origin-form
  requests that arrive in one delivery. Three costs still grow with a target's
  length, and none of them was this exception:
  - a target split across deliveries is joined into one bytevector by the core,
    once, as a header is (`connection.sls`, `take-piece!`);
  - absolute-form's reused collector assembles the target's components as it
    parses;
  - CONNECT's target is copied and parsed fresh (design §7.5).

## Amendment (2026-09-25) — the shell owns item 3's queue

Item 3's queue belongs to the shell (M2.4). The adapter hands each parser callback's
actions after its reply to a procedure the shell gave the connection's context, and
the shell runs them from its one queue once the feed has returned. Before, the adapter
kept a list of its own and copied it out after each feed, the 112 B per request that
M2.2's fourth step measured. With that copy gone the CPS workload costs 2,512 B per
request, and an absolute-form request 4,224 B, still one reused collector's parse more
(measured 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`). The shapes hold: a
500-byte header value, target, query or Host costs what a short one does.
