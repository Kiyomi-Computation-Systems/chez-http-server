# 0027: A taken stream's close gives each write it waits for the write timeout

Date: 2026-10-11
Status: accepted (user decision, 2026-10-11, by form: "Write timeout after close")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14's open
list, "A taken stream's close bounded from the server's side" (from 0024's review)
Amends: [0016](0016-an-upgrade-is-taken-by-answering-switch-protocols-and-handed-over-as-a-transport-the-server-keeps.md)'s
"Nothing bounds a taker's writes outstanding but the taker"; extends
[0026](0026-a-taken-streams-close-half-closes-and-lingers-as-the-servers-own-closes-do.md)'s
staged close

## Context

M8.2's review decided by form that nothing bounds a taker's writes outstanding but the
taker (0016). It weighed the server closing a stream whose write waits past
`write-timeout-ms`, "which would need a second deadline a stream". 0024 then gave a
taker its abort, and 0026 staged the close: once the writes are out, the stream
half-closes and lingers, bounded by `linger-timeout-ms`. Until the writes are out,
nothing but the taker bounds the close.

Measured at a0cdafa (Darwin arm64, Chez 10.4.1), with `CHEZ_HTTP_WRITE_TIMEOUT` and
`CHEZ_HTTP_LINGER_TIMEOUT` at 1 s, a client that reads nothing:
- **A taker** that writes 32 MiB and calls `transport-close!`, arming no deadline of its
  own: after 6.5 s its stream was still in the table, and the taker had been told
  nothing, no write's end and no close call.
- **A response** of 32 MiB, to the same client: its connection was closed.

So a taker that arms nothing holds the connection, and a `CHEZ_HTTP_MAX_CONNECTIONS`
slot, until the server drains.

Peers, read from their source on 2026-10-11:
- **HTTP servers hand the socket away.**
  - Go's net/http clears the deadlines at `Hijack` (`server.go`:326 at go1.27.2), after
    which it "will not do anything else with the connection" (189-191).
  - Node removes the socket's timeout listener at an upgrade (`_http_server.js`:964 at
    v22.23.3).
  - hyper's `Upgraded` holds the IO alone, with no timer (`upgrade.rs`:66-68 at v1.12.0).
- **WebSocket libraries that hold the socket bound their own close.**
  - ws's `closeTimeout`, 30,000 ms from `close()`, then `socket.destroy()`
    (`websocket.js`:1324-1326 at 8.22.0).
  - python-websockets' `close_timeout`, 10 s, then `transport.abort()`
    (`asyncio/connection.py`:51 and 957 at 17.2).

Here the server keeps the socket (0016), so once the taker has closed, the server stands
where those libraries stand.

## Decision

By form, "Write timeout after close (Recommended)":

1. **Once `transport-close!` has been asked for, each write the close waits for has
   `write-timeout-ms`** (`CHEZ_HTTP_WRITE_TIMEOUT`, 60 s). The bound is armed from the
   close and armed again at each write's end, from the loop's time brought up to date.
   The server's own writes have the same rule: the core arms `write` again at each
   completion while writes are outstanding.
2. **Past it the stream is aborted.** It closes at once, each write is told `ECANCELED`,
   and the close call runs once the socket has closed.
3. **Until the close, the taker owns its bounds**, as 0016 decided.
4. **No new setting.**

Settled here by precedent, and flagged to the owner with the slice:
- **The taker's own deadline still runs beside the bound,** as 0026 kept it until the
  half-close. The stream's one wheel entry is armed at the earlier of the two, and the
  later one is armed again once the earlier has passed.
  - A deadline that passes first makes its call. If that call does not abort, the bound
    still closes the stream.
  - chez-websocket's close timeout, 10 s (`CHEZ_WS_CLOSE_TIMEOUT`), is armed before its
    close and aborts, so its own bound comes first.
- **Once the writes are out, the linger's bound takes over**, as before (0026).
- **Nothing is logged** when the bound closes a stream, as nothing is when the linger's
  deadline does.
- **The fake shell is unchanged.** A write there is the client's at its turn and is never
  held, so no write a close waits for outlasts a turn, and the bound never applies.

## Consequences

- **A taker that arms no deadline** no longer holds a connection, and its slot, until the
  drain. Its close lasts at most `write-timeout-ms` per write it waits for.
- **A close whose writes trickle out** to a client that reads slowly is not cut while each
  write keeps ending within the limit.
- **No second wheel entry.** 0016's "second deadline a stream" is met by the taker keeping
  two instants, its one entry armed at the earlier.
- **Release:** the server's next release. chez-websocket's binding is unaffected, since
  its close timeout aborts first.
- **Weighed and not taken**, on the form:
  - **leaving it to the taker**, M8.2's form kept, as Go, Node and hyper leave a hijacked
    socket to its caller: a taker that arms nothing holds the stream until the drain;
  - **the linger from the close call**, as ws's `closeTimeout` runs from `close()`: one
    bound for the whole close, writes included. That cuts a close with more than 30 s of
    writes to a client that reads slowly, and it changes 0026's bound.

## Amendment (2026-10-16) — the fake shell bounds the close too

On the owner's "fix items 4 and 5 from the open list" (plan §14's second review note).
- **What this record said was wrong.** "The fake shell is unchanged ... no write a close
  waits for outlasts a turn, and the bound never applies." A test that delivers no later
  turn plays a client that reads nothing (decision 0024), so a fake write can be held. The
  fake then made the taker's deadline call where the libuv shell aborts the stream, and
  with no deadline of the taker's, it held the close open.
- **Now** the fake keeps the taker's own deadline and the close's write bound as two
  instants, its one wheel entry armed at the earlier, as the libuv shell does. The bound
  runs from the close and again from each write's end, and the stream is aborted past
  it.
- **Held by** five checks in the switch suite, and a contract script whose client stops
  reading once it has the `101`, its taker closing behind 16 MiB. The replay gives the
  fake the libuv shell's pass at the bound, and the two traces must agree there. The
  contract test's quick limits gain a 300 ms write timeout for it.
