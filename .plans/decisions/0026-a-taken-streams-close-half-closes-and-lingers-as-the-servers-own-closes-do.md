# 0026: A taken stream's close half-closes and lingers, as the server's own closes do

Date: 2026-10-11
Status: accepted (user decision, 2026-10-11, by form: "transport-close! always",
"CHEZ_HTTP_LINGER_TIMEOUT", "Once the socket has closed", "Three stacked PRs")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §15
Amends: [0016](0016-an-upgrade-is-taken-by-answering-switch-protocols-and-handed-over-as-a-transport-the-server-keeps.md)'s
"A taken stream has no staged close"; extends
[0011](0011-every-close-after-a-response-is-staged-lingering-up-to-30-s.md)'s staged close
to a taken stream's

## Context

chez-websocket's Autobahn lane found a close lost to a reset (its decision 0008, item 6,
"Server slice after the lane"). Its binding fails a client that is still sending, say at
a message over its cap, by writing a close frame and calling `transport-close!`. The
server writes the frame, then closes the socket with the client's bytes unread, and the
kernel answers with a reset (RFC 2525 §2.17), as 0011 found for HTTP.

Measured here on 2026-10-11 with `research/spike/taker-close-*`. A `serve` taker reads
1 MiB, writes a close frame (1009), and calls `transport-close!`. Each client sends 4 MiB
in 64 KiB writes. 100 runs a cell, outputs in `research/spike/out/taker-close-*.txt`.
Darwin 25.6.0 arm64 with libuv 1.52.1; Linux 6.12.76 aarch64 in the noble image with
libuv 1.48.0, beside another session's eight containers.

| client | close frame read | the stream's end | all 4 MiB sent |
|---|---|---|---|
| Node 20.10.0, Darwin: writes as the socket drains, reads as data comes (ws's shape) | 14 | 70 EPIPE, 25 ECONNRESET, 5 clean | — |
| C, a thread reading, Darwin | 100 | 94 reset | 0 |
| C, sends all, then reads, Darwin | 100 | 100 reset | 1 |
| C, a thread reading, Linux | 100 | 46 reset | 27 |
| C, sends all, then reads, Linux | 100 | 56 reset | 56 |
| the control, 6 bytes then nothing, each shape | 100 | 100 clean | 100 |

- **The reset does not erase what the client has received**, as 0011 found: the C clients
  read the frame every time, and the kernel reports the reset after it.
- **The client's handling of the reset loses it.** Node reports its write's EPIPE and
  destroys the socket before reading the frame buffered for it. A WebSocket library built
  that way reports 1006 where the server sent 1009.

**A prototype** of about 40 lines in the shell kept reading, dropping each read. Once the
writes were out, it half-closed and lingered until the client ended, a read failed, or
`linger-timeout-ms` passed.
- Every cell above went 100 of 100: the frame read, the end clean, all 4 MiB sent.
- A run took a median of 3 to 20 ms where it had taken 6 to 8: the server now reads what
  the client is still sending.
- One cell's first try ended at its first connect, refused, while one server log was
  shared across cells. Given a log each, it ran twice, 100 of 100 each. Not explained.

**What others do**, from source at tags (chez-websocket's
`.plans/research/2026-10-09-autobahn-lane.md`):
- python-websockets 17.2, failing a connection, sends its close, half-closes, and drops
  what arrives until the client's end (`protocol.py`, `fail`, `discard`);
- ws 8.22.0 stops parsing but reads on, dropping, sends its close and ends the socket. It
  destroys the socket after 30 s if the client never ends (`websocket.js`).
- Servers that hand the socket over leave this to the library: Go's net/http forgets a
  hijacked connection (0016), and Node's `upgrade` gives ws the socket. Here the transport
  is a taker's only reach to its socket, so the server stages the close.

## Decision

By form, the recommended of each:

1. **`transport-close!` stages the close**, as the server stages its own (0011):
   - Asked for, the taker is read nothing more, but the stream reads on, dropping each
     read. Reading the taker had stopped starts again.
   - Once no write is outstanding, the write side is shut (the half-close), and the
     stream lingers.
   - It closes when the client ends, when a read fails, or when the linger deadline
     passes.
   - `transport-abort!` is unchanged: it closes at once, at any stage.
2. **The bound is the server's linger limit**, `linger-timeout-ms`
   (`CHEZ_HTTP_LINGER_TIMEOUT`, 30 s). It is armed once at the half-close, from the
   loop's time brought up to date, in the taker's deadline's place.
3. **The close call runs once the socket has closed**, whoever closed it, as before: after
   the linger. A waiting taker's notice is told then too.
4. **Three stacked PRs:** the records, the code and its checks, the ledger.

Settled here by precedent, and flagged to the owner with the slice:
- **A client that has already ended** has nothing more to send. Once the close's writes
  are out, its stream closes, with no half-close and no linger.
- **A half-close refused at the call** closes the stream at once, as a read error does.
  One that fails as it completes is left to the reads, which a failed write side fails
  too, and to the linger deadline.
- **The taker's deadline before the half-close still runs its call**, so a deadline that
  aborts still closes a client that never reads (0024).
- **The close's reading is the server's.** From the close on, `transport-read-stop!`
  leaves the stream reading. Once the stream lingers, a deadline asked for is ignored, and
  so is its cancel.
- **The drain is unchanged.** A lingering stream is a connection the drain waits for,
  closed at `drain-timeout-ms` if its client has not closed. A drain call registered runs
  as before.
- **The fake shell's door stages its close the same way**, its linger on its own clock.
  A delivery during the close is dropped, the client's end closes the stream, and its
  timer firing at the linger deadline closes it.

## Consequences

- A client still sending when a taker fails it reads the close and a clean end, and its
  sends go through, dropped.
- A taken stream that closes holds its slot until its client closes, for up to 30 s,
  where it was let go once its writes were out. The close call, and a waiting taker's
  `&client-closed`, come then.
- RFC 6455 §7.1.1 has the server close the TCP connection first, which the half-close
  does; a client then closes its side, which ends the linger.
- **Release:** the server's next release carries it, for chez-websocket to pin alone.
  Then its lane measures again the `none` verdicts it lists for 3.4, 4.1.5 and 4.2.5
  (its 0008, item 6).
- **Weighed and not taken**, on the form:
  - an opt-in verb, `transport-close!` unchanged: other takers keep the reset, and
    `make-transport` takes a ninth procedure;
  - a half-close verb only: every taker writes its own linger and its own bound;
  - the taker's own deadline as the bound: with none armed, a silent client holds the
    stream until the server drains;
  - a shorter limit of its own: one more setting, for what 0011's limit already bounds;
  - the close call at the half-close: the call would no longer mean the socket is gone,
    while the stream still counts against `max-connections`;
  - one PR.
