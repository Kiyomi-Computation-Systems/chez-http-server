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
