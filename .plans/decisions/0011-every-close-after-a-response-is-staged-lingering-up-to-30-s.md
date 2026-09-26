# 0011: Every close after a response is staged, lingering up to 30 s for the client to close

Date: 2026-09-26
Status: accepted (user decisions, 2026-09-25 and 2026-09-26)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §7, M3.5

## Context

When a server closes a connection whose input it has not read all of, its TCP stack
answers with a reset (RFC 2525 §2.17) instead of the stream's usual end. RFC 9112 §9.6
warns that a server's immediate close risks the client never reading the last response,
and describes the close in stages that servers use instead: shut the write side, read on
until the client closes or the response has surely arrived, then close.

M3.4 closed at once after every response that closes the connection. On 2026-09-25 the
owner decided to close in stages, in the core, as M3.5. That decision rested on a
measurement which said the reset erased a 431 the client had already received, and the
measurement was wrong. Its spike counted a client that read the 431 and then met a reset
as one whose read failed.

M3.5 measured again, 2026-09-26, over loopback on Darwin arm64 and on Linux 6.12
(linuxkit, in Docker). The spikes are `research/spike/staged-close-*.py`, and their
outputs are in `research/spike/out/staged-close-*.txt`.

**A reset does not erase what the client has received.** A client sent 8 KiB or 64 KiB
past a refusal. It read the 431 in 100 of 100 runs on both platforms, even with its first
read 50 ms after the reset; the reset failed only the read after it. curl, Python's
http.client and Node's fetch each reported the 431 in 20 of 20 runs, after a 64 KiB head.

**What a reset does lose,** 20 runs each, per platform:

| Case | Closed at once | Closed in stages |
|---|---|---|
| a 4 MiB upload refused (M6's 413): curl | the 413, 20/20 | 20/20 |
| the same: Python's http.client and Node's fetch | the 413 in 0/20: each reported a reset or a broken pipe | 20/20 |
| a handler's 4 MiB response with `Connection: close`, a pipelined request unread | cut short in 8/20 on Darwin and 13/20 on Linux: 56–99% read, then a reset or 3 s of nothing | whole, 20/20 |

- A client blocked sending never gets to read the status.
- The reset throws away whatever of the response the server's kernel had not yet sent.
- The core stops reading while a handler runs (decision 0004), so a pipelined request
  waits unread in the kernel, where the core cannot see it.

**How long a staged close lasts** with a client that reads and then closes, measured on
loopback:
- after a refusal, a median of 0.05–0.10 ms;
- with a pipelined request unread, 0.2–0.4 ms.

The client's close ends it, not a deadline.

**What others do**, read on master, 2026-09-26:
- **nginx** lingers when more input may come: an unread body, a header error, input
  already buffered, the socket readable, or pipelining. The limits are 30 s in all
  (`lingering_time`) and 5 s between reads (`lingering_timeout`).
- **Apache httpd** lingers on every close. The limits are 30 s in all
  (`MAX_SECS_TO_LINGER`) and 2 s between reads (`SECONDS_TO_LINGER`), and 2 s in all for
  a "short" linger.
- **Go** shuts its write side and waits 500 ms without reading (`rstAvoidanceDelay`). It
  does so after a 431, or after a response whose request body was not all read.
- **Node** does not linger. It destroys the socket after a client error's status, and
  after a last response once its end is flushed.

## Decision

1. **Every close after a response is staged** (RFC 9112 §9.6).
   - **When it starts.** The last write of a response that closes the connection
     completes. The core then asks for `shutdown`, the half-close, and the connection
     lingers.
   - **What lingering does.** The connection reads and drops what arrives. It closes when
     the client closes, when a read fails, or when the linger deadline passes.
   - **Which closes.** The core's own statuses (design §6.5, and decision 0009's 301),
     and every close a request or a handler asks for:
     - `Connection: close`;
     - HTTP/1.0 without keep-alive;
     - an upgrade;
     - a handler's `Connection: close`;
     - in M6, a close-delimited body.
   - **Which closes are at once.** A close with no response to protect: the client's
     end, a read error, or the idle deadline.
2. **One limit, `linger-timeout-ms`: 30 000.** It is a new row in decision 0005's table.
   - It is armed once, when the connection starts lingering, and never re-armed, so a
     client that keeps sending cannot hold the connection past it.
   - It can be overridden by `CHEZ_HTTP_LINGER_TIMEOUT`, in whole seconds.
   - It matches nginx's `lingering_time` and Apache's total.
   - A client that neither sends nor closes holds its connection for up to 30 s. That is
     less than the 75 s an idle connection is already allowed.
3. **Also settled here, and flagged to the owner with the slice:**
   - The connection lingers in a tenth state, `lingering` (design §4.3). In it the
     connection reads, its write side is shut, and the linger deadline is armed.
   - A state that reads stops reading when it refuses a request, as design §4.3 says
     `responding` does (M3.4 had left it reading). It reads again when it lingers. So an
     end the client sends while the status is written waits in the kernel for the
     linger, and no state has to remember it.
   - The close names the reason the connection closes after its response, whichever way
     the linger ends.
   - The core ignores `shutdown-completed`: the client's close, not the half-close's
     completion, ends a linger.

The alternatives weighed, by form, with their rough sizes:
- Which closes linger:
  - only the core's own statuses, as M3.4 worded it: about 5 more core lines, and the
    truncation stays;
  - nginx's rule, the core's statuses plus a response when the core already holds more
    input: about 15 more. It would miss most of the truncations, since the core cannot
    see a pipelined request waiting in the kernel while reading is stopped.
- The limit:
  - 5 s, one limit, nginx's between-reads timeout used as the whole limit: the same
    code. A silent client is let go sooner, but an upload that needs more than 5 s to
    finish arriving gets the reset.
  - nginx's two limits, 30 s in all and 5 s between reads: about 100 more lines. The
    core has one deadline per connection, so this would need two, with the tick naming
    which one fired, and M5's wheel keeping two.

## Consequences

- A client still sending when it is answered reads the answer, and a response written
  before a close reaches the client whole. A conforming client's close ends the linger
  within about a round trip.
- A connection that closes now holds its slot until its client closes, for up to 30 s,
  where before it was released at once.
- The core arms a fifth deadline kind, `linger`. M5's wheel turns it into an instant from
  `linger-timeout-ms`.
- The shell's half is M4.2's. It performs `shutdown` as `uv_shutdown`, reports
  `shutdown-completed`, and reads on until the core asks for `close`. M4.4's socket lane
  gets the measurement as a test: a client that uploads past a refusal reads the status,
  where a close at once gives it a reset.
- Design §4.3 and §4.4, decision 0005's table and plan §7 carry dated notes. M3.4's
  records, which said the reset erased the 431, carry corrections.
- Tests:
  - `tests/test-connection-linger.sps`;
  - the table's rows;
  - `tests/test-connection-originated.sps`, whose rows now follow each close to its end.

  Mutations are in `.superpowers/sdd/m3-mutations.md`.
