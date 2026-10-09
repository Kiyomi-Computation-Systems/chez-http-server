# 0024: A taker may abort its stream, dropping what is unsent, and a handler may read every line of a field

Date: 2026-10-08
Status: accepted (user decision, 2026-10-08, by form in chez-websocket's M4.2: "Door change:
abort" and "Every line, in the release")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §15
Amends: [0016](0016-an-upgrade-is-taken-by-answering-switch-protocols-and-handed-over-as-a-transport-the-server-keeps.md)'s
transport, and its docs' advice that a deadline closes a client that stops reading

## Context

chez-websocket, building its binding over the door (decisions 0022 and 0023), found two
gaps. Each was measured on v0.3.0, Darwin arm64, on 2026-10-08.

1. **A close the transport cannot force.**
   - `transport-close!` closes the stream once no write is outstanding (`taker-close!`,
     `taker-wrote!`). So a client that stops reading keeps the stream open until it goes
     or the server drains.
   - `docs/handlers.org` advises a deadline to close such a client, and the transport's
     header says one does. But a deadline's call can only ask for the same close again.
   - Measured on a real socket:
     - the taker wrote 16 MiB to a client that read nothing, asked for the close, then
       armed a deadline of 300 ms;
     - the deadline passed at 496 ms, and the stream stayed open until the client left at
       2,998 ms;
     - made to raise there instead, the deadline's call closed the stream at 497 ms, and
       the server logged `taker-failed`. That is the one way through today.
2. **A field's first line only.**
   - `request-header` gives the value of the first field of a name.
   - RFC 9110 lets a list run over several lines (§5.2, §5.3). The door itself reads every
     `Connection` line, through llhttp's upgrade flag.
   - Measured through the fake shell's parse, by chez-websocket's handshake, with each
     field reading its first line:
     - `Connection: keep-alive` and `Connection: Upgrade` on two lines open the door, but
       the handshake reads `keep-alive` and refuses them 400. So does `Upgrade` over two
       lines.
     - A `Sec-WebSocket-Protocol` over two lines loses the offers on the second.
     - Two `Sec-WebSocket-Key` lines are accepted, using the first, where websockets, coder
       and ws refuse them. So are two `Sec-WebSocket-Version` lines.

And the fake shell's door does not do what the libuv shell's does for a client that
stops reading. Measured against chez-websocket's driver prototype:
- a deadline asked for after the close, while a write is outstanding, is armed by the
  libuv shell and not by the fake;
- a raise in a taker's call, such as its deadline's, escapes the fake to its caller,
  where the libuv shell logs it and closes the stream at once;
- a waiting thunk's raise closes the fake's stream only after the write outstanding has
  completed, where the libuv shell cancels it;
- the fake does not guard the take-over itself either;
- and, found while mapping this change's mutants, a deadline armed before the close
  stays armed in the fake, and passes on a closed stream, where the libuv shell's close
  disarms it.

## Decision

By form, the recommended of each:

1. **`(transport-abort! t)` closes the stream at once.**
   - Reading stops, and what is unsent is dropped: each write outstanding has its
     `written` told `ECANCELED`.
   - The close call runs once the close completes, as for any close.
   - `make-transport` takes an eighth procedure for it. A transport made of seven, as
     before, is still a transport, and refuses `transport-abort!`, naming it.
   - `transport-close!` is unchanged: it still waits for the writes.
2. **`(request-header-values r name)` gives the value of every field line named `name`.**
   - The values come in the order they came, the name matched without regard to ASCII
     case, and the spaces around each value trimmed; `'()` when there is none.
   - `request-header` is unchanged.
3. **The fake shell's door does what the libuv shell's does** for a client that stops
   reading:
   - Asked for, the close waits for the writes outstanding, so a deadline asked for
     meanwhile is armed; begun, it disarms the deadline.
   - Every call into the taker's code is guarded, the take-over itself among them. A
     raise is the taker's failure, recorded, and closes the stream at once, as a waiting
     thunk's raise does.
   - The fake aborts as item 1 has it.

## Consequences

- **The abort, measured as a prototype**, on the same socket, as the deadline's call:
  the stream closed at 498 ms, the write was told `ECANCELED`, and nothing was logged.
- **The docs' advice now works:** a deadline whose call aborts closes a client that never
  catches up.
- **chez-websocket is to use both** (its design §9).
  - Its binding is to abort where it must close a client that does not read, such as at
    its close timeout.
  - Its handshake is to read each field's lines joined with a comma. A list then reads
    whole, and two keys or two versions are refused 400, as measured above.
- **Release.** Server 0.4.0 carries all three, for chez-websocket to pin. CHANGELOG.md's
  Unreleased already makes the next release 0.4.0 (decision 0005's amendment of
  2026-10-05).
- **Not done:** a door script in the cross-shell contract test (0016 has none). Paired
  checks in the two suites hold the fake's door to the libuv shell's, not a replay.
- **Weighed and not taken**, on chez-websocket's form:
  - the binding raising at its bound: no server change, but every client that merely
    stopped reading would be logged `taker-failed`, and the fake could not show it;
  - a field's first line, documented: no change;
  - chez-websocket reading the server's internal libraries for every line: no release,
    but no promise across versions.
