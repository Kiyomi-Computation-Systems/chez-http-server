# 0014: Every handler is called after libuv's turn, and one that waits answers with a thunk run on a coroutine

Date: 2026-10-02
Status: accepted (user decision, 2026-10-02)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M7.1

## Context

M7 lets a handler wait: on a DNS answer, a timer, another socket. Decision 0003 item 2
says a handler that returns a response is finished with no scheduler involved, and one
that calls `await` runs as a coroutine created and resumed only from the scheduler's
`drain-ready!`. Plan §14's M7.1 builds "a coroutine per awaiting handler". Neither says
how the server comes to know that a handler waits. In v1 both shells call a handler in
place, inside libuv's read callback, where a continuation captured can never be resumed
(design §5.1). So how a handler comes to wait is public API, settled before M7.1.

Measured by `research/spike/m7-handler-coroutines.sps`, `m7-handler-turns.sps` with
`m7-handler-turns.sh`, and `m7-handler-streams.sh` (2026-10-02; Darwin arm64, and Linux
6.12.76-linuxkit aarch64 in Docker's `chez-libuv-valgrind:10.4.1` image; Chez 10.4.1;
two runs of the first on each, one of each script). A prototype coroutine shell,
`m7-coroutine-shell.patch` on the libuv shell at 4a7748b, calls a handler from the
drain of a two-level scheduler (`m7/scheduler.sls`, design §5.2's sketch).

Per request, through the real parser, adapter and core (the allocation gate's GET):

| the handler called | bytes | ns, Darwin | ns, Linux |
|---|---|---|---|
| in place, as in v1 | 1,840 | 2,204–2,346 | 2,333–2,744 |
| on a coroutine that does not wait | 2,029–2,035 | 2,274–2,486 | 2,597–2,945 |
| on a coroutine that waits once | 2,269 | 2,385–2,530 | 2,532–2,826 |

Through a small shell of the spike's own, what each way adds to each request, the same
on both platforms: the handler's call made from the drain, in place, 64 B for each of
the gate's GET, a JSON POST read by `read-body` and by `read-whole-body`, and a GET
answered with a producer of 8 pieces; every call into handler code on a coroutine of
its own (the handler, each piece, the end, each producer call), 195, 554, 522 and
1,669 B. The floor, `call/1cc` alone, is 64 B. The allocation suite's JSON POST read
whole costs 2,624 B today, so 2,688 B the first way and 3,146 B the second, over the
3,072 B gate. A handler parked 4 or 16 calls deep holds 3,515 B, 64 deep 3,879 B.

`ab -k`, 50,000 GETs a run, three rounds, the modes' order rotating:

| requests a second | today | the handler after the turn, in place | every call on a coroutine |
|---|---|---|---|
| Linux, 32 connections | 64,574–64,998 | 87,435–90,918 | 87,141–89,769 |
| Linux, 1 connection | 14,762–15,556 | 15,089–15,220 | 14,988–15,240 |
| Darwin, 32 connections | 33,331–33,516 | 33,966–34,511 | 33,750–34,519 |
| Darwin, 1 connection | 11,979–11,989 | 11,708–11,758 | 11,546–11,730 |

The handler's call made from the drain on a coroutine that does not wait served as
the in-place call did, 87,699–91,586 on Linux at 32 connections: the gain is the
deferral's, not the coroutine's. Its cause is not established; a turn's reads are all
taken in before their answers are written.

16 MiB with curl over loopback: nine downloads and six uploads of each, three of each
to each server, the first upload to each server left out. Every call on a coroutine
here runs each drain until nothing is ready:

| milliseconds | today | the handler after the turn, in place | every call on a coroutine |
|---|---|---|---|
| Linux, download | 8.4–9.2 | 8.4–9.3 | 10.4–11.6 |
| Linux, upload | 7.8–8.7 | 8.0–8.8 | 9.7–11.0 |
| Darwin, download | 24.0–24.7 | 23.9–24.8 | 25.3–26.0 |
| Darwin, upload | 15.6–16.0 | 15.3–16.3 | 15.3–19.5 |

Every call on a coroutine costs a streamed 16 KiB piece about 2 µs on Linux. Its
Darwin downloads took 43.3–44.0 ms when a drain stopped at the coroutines ready as it
began, as the two-level proposal's sketch has it (research/async-two-level-coroutines.md
§4), so each producer call waited a turn; on Linux that way took 10.2–10.9 ms.

## Decision

1. **Every handler is called after libuv's turn.** The shell queues the call where it
   called the handler in place, and the scheduler's drain makes it, once `uv-run` has
   returned. A handler that answers a response or a reader has answered there, on no
   coroutine.
2. **A handler that waits answers `(awaiting thunk)`.** The thunk runs on a coroutine
   of its own, created and resumed only from the scheduler's drain (0003 item 2), and
   what it returns is the handler's answer, a response or a reader. The reader's pieces
   and end, and the producer of the response it answers with, are called on coroutines
   too, so they may wait, and such a reader is answered on credit (M6.2). Every other
   reader and producer is called in place, as in v1.
3. **A wait outside a coroutine is refused**: a waiting verb called by a handler that
   did not answer `awaiting`, or by an ordinary handler's reader or producer. R2's
   check (design §5.3) raises where no coroutine runs, in the drain that calls an
   ordinary handler, and R1's inside a libuv callback, where an ordinary reader is
   handed a later read's piece; either way the handler has failed: 500, and
   `handler-failed` logged. *Amended 2026-10-02 (M7.1's review):* as first written,
   this item named R1's check alone.
4. **The verbs a handler waits with are M7.2's**, decided there (plan §14).

Weighed: every call into handler code on a coroutine after the turn, so any of it may
wait, with no wrapper: about 190 B a call with a simple scheduler, a JSON POST read
whole over the gate unless the scheduler is built near its 64 B floor, and about 2 µs
a streamed 16 KiB piece. And a handler called inside the read, as in v1, with the
wrapper: nothing added, nothing changed, and no gain at the wire.

## Consequences

- Decision 0003 item 2 is amended: a handler that returns a response is finished on
  no coroutine, but it is called from the scheduler's drain.
- The run loop is the scheduler's turn, the drain then `(uv-run loop 'once)`, or
  `'nowait` when a coroutine is ready (design §5.2). Measured: turns of `'once` serve as
  `'default` does.
- An answer never comes in the drain that asked for it, so the core waits for every
  answer as for a later event. A request whose body is still arriving would keep its
  pieces until the handler answers, and plan §14's note of M6.2 already has M7 stop
  reading while such a handler has not answered. Those rows are M7.1's.
- The fake shell calls a handler after its drain too, so the contract test (design
  §8.4) compares shells that call alike.
- A handler that waits costs a coroutine, and holds about 3.5 KB while parked; one that
  does not costs the deferral, 64 B in the spike's way of queueing it.
- The facade exports `awaiting`. A forgotten wrapper is a 500 and a log line, found the
  first time the handler runs.

## Chosen while building, and flagged for review

M7.1 is built in three steps (plan §14's M7.1 note), a PR each, on 2026-10-02.
Each step's choices are under its name.

**The scheduler** (the first step):

- **A drain runs until nothing is ready.** Only a coroutine that yields waits for the
  poll. The two-level proposal's sketch stopped at what was ready as the drain began,
  which made each produced piece wait a turn (the spike: 43 ms for 16 MiB on Darwin,
  where draining all took 25 ms). A drain cannot loop for ever on its own: in M7 only a
  libuv callback, the core's pacing, or a yield makes a coroutine ready.
- **Spawning only enqueues**, so it is allowed anywhere, a callback included, as a
  callback may make a coroutine ready. R1 is checked where a coroutine is entered,
  resumed, parks or yields, and where a drain is made. The design's sketch has spawn
  assert the phase too.
- **The phase, and the coroutine running, are the process's**, not a scheduler's: v1
  is one thread (design §7.4), one turn runs at a time, and a waiting verb has no
  scheduler to name.
