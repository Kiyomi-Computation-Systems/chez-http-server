# 0016: An upgrade is taken by answering `switch-protocols`, and handed over as a transport the server keeps

Date: 2026-10-03
Status: accepted (user decision, 2026-10-03)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M8.2, and §9's three questions

## Context

Decision 0006 item 3 promised one hand-off hook. Its amendment of 2026-09-25 had v1 serve
an upgrade like any request and close the connection after it, the hook left as the door
M8 opens for a handler that takes upgrades. A WebSocket is a library of its own that
takes a stream through that door (decision 0001 items 3 and 4). Plan §9 (noted
2026-09-26) set three questions the door's shape must answer first: who writes the
`101`; what the handed-off stream still belongs to; and what the door hands over.

Measured on main at 70b7adf (2026-10-03, Darwin arm64, Chez 10.4.1 `tarm64osx`), through
the fake shell with the real parser, adapter and core: `research/spike/m8-today-101.sps`
and `m8-door-pending.sps`, two identical runs each.
- **Today a handler cannot take an upgrade.** A WebSocket handshake answered with a 101,
  with or without `Connection: upgrade`, is answered 500 and logged `invalid-response
  invalid-status`. Answered 200, it is served, and the connection closes after it, for
  `upgrade`.
- **The core already holds what the door must hand over.** At on-message-complete it
  pauses the parser and stops reading (decision 0004 item 1), so when the handler is
  asked, its pending input is the rest of the last read, from `parser-result-next`, and
  what the client sent after that waits in the kernel. Over six inputs at every delivery
  size, 525 runs, the pending input then, followed by what reading on brings, was exactly
  the bytes after the request, and began at the request's end, in every run: a WebSocket
  handshake alone (72 sizes), and with a masked frame sent before the 101 (80); an
  upgrade with a 4-byte body and a frame after it (93); a CONNECT with 6 bytes after it
  (65); `Upgrade: h2c` with the HTTP/2 preface after it (144); and an HTTP/1.0 handshake
  with a frame (71).

The servers surveyed (`research/server-*.md`, read 2026-09-19, and the sources named):
- **h2o** writes the 101 itself, with `Connection: upgrade` (`h2o_http1_upgrade`,
  `http1.c:1341-1359`), and once it is written hands over the raw socket and the size of
  the request still at the front of its input (`http1.c:914-932`). It honours `Upgrade`
  only on a request with no body (`http1.c:510-513`).
- **hyper** writes the handler's 101, with no framing, then hands over the raw I/O and
  the bytes it read past the request (`Upgraded::new(io, read_buf)`). A graceful shutdown
  of an upgraded connection is a no-op.
- **Node** hands an `upgrade` listener the raw socket and the bytes after the head, and
  the listener writes the 101. **Go**'s handler hijacks the connection and writes it, and
  Go's `Shutdown` "does not attempt to close nor wait for hijacked connections such as
  WebSockets"; `RegisterOnShutdown` is how its caller tells them (net/http `server.go`,
  read 2026-10-03).
- **nginx** writes `Connection: upgrade` for a handler's 101.
- **Kestrel** counts an upgraded connection against `MaxConcurrentUpgradedConnections`
  instead of `MaxConcurrentConnections`, unlimited by default (its API reference, read
  2026-10-03).

What the RFCs require, read 2026-10-03. RFC 9110 §7.8: a server that sends a 101 "MUST
send an Upgrade header field"; "A server MUST NOT switch to a protocol that was not
indicated by the client in the corresponding request's Upgrade header field"; "A sender
of Upgrade MUST also send an 'Upgrade' connection option in the Connection header field";
"A server that receives an Upgrade header field in an HTTP/1.0 request MUST ignore that
Upgrade field". §15.2: "a server MUST NOT send a 1xx response to an HTTP/1.0 client", and
a 1xx "cannot contain content or trailers". RFC 6455 §4.1: a handshake's method "MUST be
GET", and once it is sent, "the client MUST wait for a response from the server before
sending any further data".

## Decision

Decided on the owner's word, by form, the recommended answer to each of four questions.
The second was answered on a second form, after the owner asked what the server keeping
the stream gains, when the servers surveyed hand over a raw handle.

1. **The server writes the 101.** A handler takes an upgrade by answering
   `(switch-protocols headers take-over)`. The server writes `HTTP/1.1 101 Switching
   Protocols`, the handler's fields and `Connection: upgrade`. Once the 101 is written it
   calls `(take-over transport retained)`: the transport (item 2), and the bytes the
   client sent after the request that the server has already read, `parser-result-next`
   onward (0006 item 3's contract). A switch the server cannot write safely is answered
   500, as such a response is (decision 0010 item 2): one whose `Upgrade` field is
   missing, or names a protocol the request's did not, or that carries a framing field or
   a `Connection` field.
2. **The taker gets a transport, and the server keeps the stream.** The transport is a
   record of verbs: write, start and stop reading, close, one deadline, and calls when the
   server drains and when the stream has closed. The server's shell implements them over
   chez-libuv, and a fake implements them for tests, so a taker imports no chez-libuv. The
   stream stays in the connection table: it counts against `max-connections`, its close
   goes through `handle-close!`, its deadline rides the wheel and its one timer (decision
   0005), and a taker that raises has its stream closed, logged.
3. **The drain tells a taken stream, then waits.** As the drain begins, the taker's drain
   call runs, so a WebSocket can send 1001, "going away"; the drain waits for the stream's
   close, and at `drain-timeout-ms` closes whatever is left (M8.1).
4. **The door opens for upgrades only:** an HTTP/1.1 request the parser marks as one,
   `Connection: upgrade` with `Upgrade`, that has no body. A CONNECT, an HTTP/1.0 request
   and one with a body are still served, then closed (0006's amendment), and a switch
   answered to one is a 500.

Weighed on the forms: the handler writing the 101 (Node, Go), for which decision 0010
would need an exception. The raw handle and the loop (h2o, hyper, Node, Go), the
smallest change in the server, with all of libuv for the taker; but the server then
forgets the stream: not counted, its close unseen, no drain to tell it or wait for it,
and closed with no goodbye when `serve` returns and the loop is torn down. A drain that
closes a taken stream at once, as an idle connection, where a WebSocket client sees 1006,
closed with no close frame; or one that waits for it untold, where an open WebSocket
holds every drain the full timeout. CONNECT tunnels too (hyper, h11), which no v1 taker
needs.

## Consequences

- Public API, exported by the facade: `switch-protocols`; the transport's verbs and
  `make-transport`, with which a taker's tests make a fake. Still no `uv-` name
  (`tests/test-exports.sps`).
- The door is not the parser's own hand-off. The core pauses at every message's end and
  never resumes the parser onto an upgrade, so design §4.4's `head`/`body` hand-off row
  stays unreached. The door is a row of `responding`, at the 101's last completion, where
  the core hands over its pending input.
- The hook's contract test lands (0006 item 3): at every delivery size, the bytes handed
  over are exactly `parser-result-next` onward.
- A taker's code runs in place, in the shell's callbacks, whether or not its handler
  waited, so it cannot wait with `await`.
- A taken stream keeps its connection's read buffer, 16 KiB by default, until it closes
  (design §7.2), and its place in `max-connections`.
- The HTTP/2 preface is still answered 505 (0006 item 2).

## Chosen while building, and flagged for review

M8.2 was built in one working tree on 2026-10-03, from main at 70b7adf.

**The core** (`(http-server connection)`, `(http-server serializer)`, `(http-server
switch)`):

- **The door is a row of `responding`.** A switch answered through an open door is
  written as its 101 and the take-over kept; the core hands the stream over at the 101's
  last completion, as h2o calls its callback once the 101 is written. Until then reading
  stays stopped, as it is from the message's end, so nothing the client sends is read
  early or lost. The hand-off is `(hand-off take-over retained)`, `retained` the core's
  pending input, `(bv start end)`, or #f. It replaces M2.5's `(hand-off request)`.
- **The parser's own hand-off is refused.** Design §4.4's `head`/`body` row, T7 in the
  table, was unreachable: the core pauses every message's end and never resumes the
  parser onto an upgrade. A pause for an upgrade there is now an assertion violation, the
  shell's bug, and T7 is retired.
- **A switch the door does not open for is a fault, `not-an-upgrade`**, answered 500 and
  logged `invalid-response`, as a response the server cannot write safely is: the
  handler's answer is wrong for the request. Not served as a plain response.
- **The 101 carries no Date**, as the server's `100 Continue` carries none (RFC 9110
  §6.6.1: a server MAY send one in a 1xx). A handler's own Date is written.
- **A request that expects 100-continue is sent the 100 first**, in the 101's one write:
  RFC 9110 §7.8 says a server that receives Upgrade and that expectation MUST send the
  100 before the 101. The door's request has no body, so M6.4 sent it no 100.
- **A handler's `Connection` on a switch may say `upgrade` alone**, and is not copied:
  the server writes its own. WebSocket code builds `Connection: Upgrade` itself (RFC 6455
  §4.2.2), and refusing it would make every such handler a 500.
- **Protocols are compared whole, without regard to case**: §7.8's SHOULD names the
  protocol-name, and the version is compared the same way. An Upgrade element that is
  empty names nothing; a switch must name at least one.
- **The core lets go of what it no longer needs**: handed off, its input, its request and
  the take-over; and a 101 a read error cuts short closes with the take-over let go, so a
  closed connection holds no handler's code. Each has a check.

**The transport** (`(http-server transport)`, both shells):

- **Seven verbs**: plan §9's five, the drain call item 3 needs, and a call when the
  stream has closed, whoever closed it, since a stream the drain's deadline closes would
  otherwise close under a taker that is not reading. Each verb checks its arguments
  before calling its procedure, so a fake and the shell refuse a taker's mistake alike.
- **A write of no bytes is refused**: chez-libuv completes a write that ends in an empty
  span a turn late, and a close then cancels it.
- **A taker's write is one `uv-write*!` of its own**, never held for the turn's write
  (the shell's write batching, decided 2026-09-29): it runs in the taker's callbacks,
  outside the drain whose end sends what is held.
- **`transport-close!` waits for the writes outstanding, then closes at once.** A taken
  stream has no staged close (decision 0011): a taker says goodbye in its own protocol
  first, a WebSocket's closing handshake. A write asked for once the close has been is
  not written, and its callback is told ECANCELED after the turn; so is one libuv refuses
  at the call, with its errno.
- **Reading started again while it reads is stopped, then started** with the new
  callbacks.
- **A drain call registered while the server drains runs at once**, so a switch
  answered during a drain says goodbye too.
- **A taker's code runs in place**, in the shell's callbacks, and each call into it is
  guarded: one that raises is logged `taker-failed`, its stream closed. What a call
  returns is dropped. Found while building: a close call that ended with no values made
  chez-libuv's close callback raise, and the run loop with it.
- **A taken stream keeps what an open connection keeps**, its parser among it, and its
  one wheel entry is the taker's deadline.
- **Nothing is logged for a switch**, as nothing is for a response; only a taker's raise.

**The review** (a /code-review high of the uncommitted branch; ten found, the owner's
form deciding which to fix, 2026-10-03):

- **Fixed:** a write is counted outstanding only once libuv has taken it, so a call
  refused for no transport's failure (off the loop's thread, `&uv-wrong-thread`) leaves
  nothing for the close to wait for; the test lanes render a hand-off by the bytes it
  hands over, not as a request; the fake transport arms no deadline on a stream that has
  closed, as the shell's does not; a close call registered once the stream has closed
  runs at once; and the serializer reads a switch's Upgrade with `(http-server
  headers)`' `field-elements`, shared, not a scan of its own.
- **Nothing bounds a taker's writes outstanding but the taker**, decided by form: each
  write's callback tells it what the write has become, so it can count what is still
  outstanding and stop past a bound of its own, and a deadline closes a client that
  stops reading; the docs show how. Measured: a client that sent 4 MiB to an echoing
  taker and read nothing left 28 and 107 writes outstanding in two runs (0.4 and 1.7
  MiB). Weighed: a verb giving what is outstanding; the server closing a stream whose
  write waits past `write-timeout-ms`, which would need a second deadline a stream.
- **Noted, not changed:** a 101 that lists protocol layers, the one in use among them
  (RFC 2817's `Upgrade: TLS/1.0, HTTP/1.1`), is refused, as HTTP/1.1 was not offered: no
  v1 taker upgrades to TLS, and the owner's deployments terminate TLS in Caddy. The door
  reads the parser's upgrade flag from the close-after reason, which only
  on-headers-complete sets for an upgrade. A taker's callbacks deferred to the next turn
  are lost if `serve` returns first. A taker's writes are a write request each, not
  batched as the core's are under 4 KiB. After the PRs opened, on the owner's word, the
  last two went into `docs/handlers.org` and all four into plan §14's open list.
  Measured then: the `done` of a write asked for in a taker's close call was still
  uncalled when `serve`'s loop returned, and was told ECANCELED a turn later.

**The checks:**

- **The hook's contract test is the fake shell's**, at every delivery size
  (`tests/test-connection-switch.sps`), with the socket suite's on a real socket. The
  cross-shell contract test (design §8.4) holds no door script: a taker's reads and
  writes are no events of the core's, which that test replays.
- **The fake shell drains** (`fake-shell-drain!`): the core told `shutdown-requested`,
  or a taker's drain call run.


## Amendment (2026-10-04) — the four findings noted are settled

Decided on the owner's word on 2026-10-04, after a discussion of each: "close all but 6,
lets talk about what it would take to fix 6", then "build the targeted fix".

- **Closed, not wanted: the fourth,** a 101 listing protocol layers refused. Only a taker
  upgrading to TLS meets it, TLS is outside the project (decision 0001), the owner's
  deployments end TLS at Caddy, and a WebSocket's 101 lists one protocol. It stays
  refused: 500, logged `invalid-upgrade`.
- **Closed, not wanted: the fifth,** the door reading the upgrade flag from the
  close-after reason. Only the head's completion sets `upgrade`. Four other rows set a
  reason only when none is set, and `respond` sets the core's refusal reasons or
  `parser-error`, never `upgrade`. The switch suite holds the door shut for a request
  that does not upgrade (`not-an-upgrade`), an HTTP/1.0 upgrade, a CONNECT and one with
  a body.
- **Closed, not wanted: the tenth,** a taker's writes not joined. Measured for the core's
  response pieces (#79, Linux aarch64): 100-byte pieces went from 32.4 to 180.8 MB/s
  joined by the server, and to 852.6 MB/s gathered by the handler into 16 KiB pieces.
  Joining where the bytes are made does better, as `docs/handlers.org` asks of a taker.
- **Fixed: the sixth.** A taker's calls deferred to a turn, each refused write's `done`,
  wait in the shell's own queue, which the drain's calls take from, oldest first.
  `serve`'s run (`run-until-stopped!`) makes those still waiting once its server has
  stopped, before its loop is torn down (`shell-call-deferred!`): one pass, so a call
  they defer in turn waits for a turn `serve` does not run. Nothing else the scheduler
  holds is run. Weighed and not taken: draining the whole scheduler there, which would
  resume a handler's coroutine woken in the last turn.

Measured (2026-10-04, Darwin arm64, Chez 10.4.1, libuv 1.52.1):
- **The request's path is not touched.** Through the whole server, a GET kept alive
  allocates 10,433 B at one connection on main and with the fix, and at 50, 8,900 to
  8,903 B on main and 8,902 to 8,904 B with the fix: the difference over 100,000 GETs,
  two rounds each, the trees alternating (`research/spike/m8-request-alloc.sps`, given
  its new LARGE; `out/taker-deferred-request-alloc-105k.darwin.txt`). Over M8.4's
  20,000, the fix read 1 B more at one connection
  (`out/taker-deferred-request-alloc.darwin.txt`), a step of the counter's over a run
  that five times as many GETs leave out.
- **A refused write costs a little more.** It allocates 96 B as it is asked for and 425 B
  as its `done` is made, against 64 B and 409 B on main: three batches of 10,000 each,
  the same each time (`research/spike/taker-deferred-cost.sps`;
  `out/taker-deferred-cost.darwin.txt`).
- **The checks:** `tests/test-serve.sps` runs `serve`'s run on a loop of its own, the
  server shut down with a taker's writes refused as its stream closes. Each `done` is
  told `ECANCELED` before the run returns, in order and once, and a `done`'s own write
  waits. Red before the fix; six mutants each red (m8-mutations.md, "After M8").

Plan §14's open list drops the item.


## Amendment (2026-10-04) — a taker can wait (decision 0023)

The consequence that a taker's code "runs in place, in the shell's callbacks ... so it
cannot wait with `await`" still holds for the take-over and the taker's callbacks. A
take-over may now answer `(awaiting thunk)`: the thunk runs on a coroutine, where it may
wait, and its waits are told when the stream closes.


## Amendment (2026-10-08) — a taker may abort its stream (decision 0024)

The transport's advice that "a deadline closes a client that stops reading" did not
hold: a deadline's call could only ask for `transport-close!`, which waits for the
writes a client that stops reading never takes. A taker may now abort its stream,
`transport-abort!`, which drops what is unsent. `make-transport` takes an eighth
procedure for it; a transport made of seven refuses the abort. And a handler may read
every line of a field, `request-header-values`.
