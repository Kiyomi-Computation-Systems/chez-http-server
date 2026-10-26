# 0038: A handler is tested through (http-server testing), a second facade over the fake shell, which the package installs

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25: the owner's issue #230, picked up with
"do issue 230")
Plan: none; the issue is the design

## Context

- A handler that waits can't be tested by calling it: `await`, `sleep-ms`,
  `with-deadline` and `resolve` work only on the coroutine of a handler that answered
  `awaiting`. Testing one needs a host: the real server over loopback, with real time,
  or the fake shell.
- The fake shell, `tests/fake-shell.sls` at v0.8.0, has what such a test wants:
  - the real core and parser, with no I/O;
  - a fake clock;
  - a scripted resolver;
  - credit;
  - the client's bytes.

  But it isn't supported:
  - The Akku package leaves `tests/` out (`Akku.manifest`, `.akkuignore`).
  - Its surface is the core's events, limits and actions.
  - It imports three private libraries that `docs/reference.md` documents none of.
- chez-websocket and circuit vendor the server's checkout to reach it. circuit, a
  Ring-like layer, runs every app on a coroutine, so its adapter, its timeout
  middleware and any app that waits can only be tested through such a host.
- The import audit (`tests/test-imports.sps`) holds that nothing a parser feed runs can
  reach the scheduler. It does so by treating every library directly in
  `src/http-server/` as pure, and a pure library may import no private one.

## Decision

1. **`(http-server testing)`, at `src/http-server/testing.sls`, is a second facade.**
   - Its surface is a handler's: hosts, clients and responses read. No core event,
     limits record or action appears in it.
   - `make-test-host` takes the handler and, optionally, the environment procedure
     `serve` takes, and reads the settings through `serve`'s own `settings`.
   - A client sends wire bytes, closes and resets, and reads its responses: status,
     reason, headers, body de-chunked, raw bytes, and complete or not, with whether the
     connection closed.
   - The host keeps:
     - a clock from 0, advanced by the test, stopping at each instant something is due;
     - the lookups `resolve` asks for, answered by the test;
     - what the server logs, as `(what . details)`;
     - which clients' handler code still waits.
   - Each acting call runs the host until it is quiet. A host that never goes quiet
     raises at a cap rather than hang, and a call that acts made from the host's own
     code is refused.
2. **The harness moves to `src/http-server/private/fake-shell.sls`** as
   `(http-server private fake-shell)`, so the package installs it.
   - `tests/fake-shell.sls` stays as a shim re-exporting the same names, so no suite's
     imports change.
   - The move is a script that a later base can rerun (the ledger keeps it). The moved
     file differs from the old one only in its library name and the header's first line.
3. **The harness gains three things for the host, and its behaviour is otherwise as it
   was:**
   - an export of `fake-shell-calling?`, an accessor its record already defines;
   - an optional scheduler for `make-fake-connection`, so a host's connections share one
     scheduler and one set of waits, as a loop's connections share the libuv shell's.
     The connection then makes no waits of its own;
   - a dispatch cap counted per event, as its header always said, not over a
     connection's life.
4. **The audit treats the testing library as a second facade.**
   - `pure?` leaves it out.
   - A pure library may import no `(http-server private ...)` library, nor the facade
     or the testing library, which reach them.
   - The adapter may import neither the fake shell, the facade nor the testing library.
   - The tree check requires the testing library to exist, so the exemption can't go
     stale.
   - This is stronger than before: a pure library importing the facade went uncaught.
5. **Shared, not copied.** `serve.sls` exports `settings`, and the adapter exports
   `request-parser-inits`, so the host reads settings and requests as the server does.

## Consequences

- **Measured** in the Guix container, Linux amd64, on base 77ace4e:
  - 54 suites and 2,189 expected passes before the move;
  - the same, per suite, after the move alone;
  - 55 suites and 2,247 after all of it.

  `tests/test-handler-testing.sps` has 49 rows, each a real handler, `examples/long-poll.sps`'s
  among them. A stub that exports every name and does nothing failed all 32 of round 1's.
- **Mutants:** 43 of the library and harness. All fail but one equivalent mutant, which
  drops `busy?`'s `scheduler-ready?`; the shared scheduler is drained after every
  dispatch. One harness mutant fails only `tests/test-fake-shell.sps`.
- **The host is a model, and says where it differs** (docs/testing.md, "What it leaves
  out"):
  - The server's own timeouts fire at their earliest instant here, and up to
    `CHEZ_HTTP_TICK_MS` later in the server.
  - A write after a reset the server hasn't read yet goes through.
  - A raise from a call that ends after its connection has closed isn't logged.
  - A request and a reset in one moment always reach the handler.
  - No slow reader, write timeout, connection cap or drain.
  - A non-literal `CHEZ_HTTP_HOST` isn't refused, since only a bind refuses it.
- **A reset is read after the bytes sent before it,** as a close is, before and after a
  handoff. It is one rule for every connection, where the first build dropped unread
  bytes before a handoff and kept them after it. What a kernel does with data queued
  before a reset is not measured here, and RFC 793 would have it flushed. So a test
  shouldn't rely on bytes sent just before a reset.
- **The log is built from the fake shell's traces,** so a line the libuv shell gains must
  be added here too. `on-done-failed` came with `request-on-done!` while this was built:
  the fake shell records those raises without tracing them. So the host logs each one
  before its next entry, its next trace and the end of each round, which keeps it in the
  order it was raised.
- **docs/waiting.md is corrected:** a lookup a deadline ends answers later either way.
  Cancelled, it answers `EAI_CANCELED` (chez-libuv's docs/dns.md), and the server logs
  `late-resume resolve`. The host does the same.
- **Not done:** a contract lane holding the host to `serve` over loopback, the way
  `tests/test-contract.sps` holds the fake shell to the libuv shell. It would take one
  script of scenarios run by both, a resolver the libuv shell can be given, and timing
  rows with a tick's slack.
- **Weighed and not taken:**
  - A name outside `src/http-server/`, such as `(http-server-testing)`: the audit needs
    the same amendment, or a pure library importing it goes uncaught, as the facade did.
  - `(http-server private testing)`: "private" says unsupported.
  - Exporting the fake shell itself: its surface is the core's.
  - Per-connection schedulers: coroutines on different connections would run in
    connection order, where the server runs them in wake order.
  - Moving the condition types out of `serve.sls`, so loading the library loads no
    libuv: the facade loads it already, and a consumer has chez-libuv installed with
    the server.
