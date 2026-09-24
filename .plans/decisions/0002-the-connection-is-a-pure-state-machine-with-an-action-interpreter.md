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
