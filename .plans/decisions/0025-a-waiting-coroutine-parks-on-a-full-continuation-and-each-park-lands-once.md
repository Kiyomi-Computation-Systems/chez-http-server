# 0025: A waiting coroutine parks on a full continuation, and each park lands once

Date: 2026-10-09
Status: accepted (user decision, 2026-10-09, by form: "A server slice next", in
chez-websocket's M4.3 step 3 review, and "Number each park", here)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §15
Amends: the scheduler's park, built in M7.1 on a one-shot continuation
([0014](0014-every-handler-is-called-after-libuvs-turn-and-one-that-waits-answers-with-a-thunk-run-on-a-coroutine.md));
design §5.2

## Context

chez-websocket's M4.3 step 3 measured what a connection costs on a real socket. An idle
WebSocket waiting in a receive held 11.1 to 11.4 KB. About 3 KB of that was its own
wait, by a one-shot continuation, which it moved to a full one (its decision 0005's
amendment). Most of the rest was this server's park. Its review asked why the server
parks on one-shot continuations, and what a full one would cost.

**Why one-shot.** The records give two reasons.
- Suspending and resuming cost the same either way: 30 to 36 ns (design §5.2, E3b).
- A one-shot continuation entered a second time fails loudly, with
  `attempt to invoke shot one-shot continuation`. A full one ran the code after it
  again: under a C frame, `uv-run` and the rest of the program (design §5.1, E1/E2).

R1 and R2 keep every continuation off C frames. Inside the scheduler, that loud failure
was a tripwire no check named. No record had measured what a parked coroutine keeps on
the heap with a full continuation.

**Measured by chez-websocket's review** (Darwin arm64; the server's spike method), with
`suspend!` by `call/cc`:
- A coroutine parked at an `await` held 3,639 to 3,660 B with `call/1cc`, and 640 to
  679 B with `call/cc`.
- By depth, 2,000 parked at once: 3,836 → 727 B at 4 calls deep, and 7,696 → 4,761 B at
  256.
- A wake and park: 403 → 493 B, and 125–143 → 146–336 ns.
- The scheduler, waits, shell and contract suites passed on that shadow.

**Measured here, before the form** (2026-10-09; Darwin arm64, and Linux 6.12.76-linuxkit
aarch64 in Docker, alike). With `call/cc` and no check, a park's continuation entered a
second time:
- *by a handler's own continuation*: a `dynamic-wind` before thunk captures the
  continuation it runs in as the park is resumed, and the coroutine calls it once
  landed. The code after the park ran twice, and the coroutine ended normally.
  `call/1cc` raised.
- *by the scheduler*, with both of its guards removed (the wake's check, and resume
  clearing the continuation it takes): the code after the park ran twice, and the end
  procedure was called twice. `call/1cc` raised.
- *by a coroutine returning into an old drain* (R3 broken): the program re-ran from
  that drain. `call/1cc` raised. The scheduler suite's R3 row reddens either way.

**Peers, measured locally:** Python 3.14.5 generators, Ruby 2.6.10 fibers, Node 20.10.0
generators and Racket 9.3's `racket/generator` each refuse to resume a coroutine that is
running. Each checks at the resume (`ValueError`, `FiberError` "double resume",
`TypeError`, an `exn`). None checks where a suspension lands. Racket's generator, whose
yield is a continuation, ran the code after a yield twice in the same `dynamic-wind`
case.

## Decision

By form, the recommended of each:

1. **A coroutine parks on a full continuation** (`call/cc`), in the scheduler's
   `suspend!`, for a park and a yield alike. The drain still enters and resumes
   coroutines on a one-shot continuation of its own.
2. **Each park lands once.**
   - `suspend!` numbers the park on its coroutine before capturing it.
   - Its landing checks that number is still the one waiting, and marks it landed.
   - A second landing raises an assertion naming the verb, `coroutine-park!` or
     `coroutine-yield!`, where Chez's refusal of a one-shot continuation named no one.

   Weighed on the form, and not taken:
   - **checking the state at the resume**, as the peers do. It catches only the
     scheduler resuming twice, which the wake's check already refuses, so no test could
     reach it;
   - **numbering the drain's continuation too.** A coroutine that returned into an old
     drain would raise where it returns. The R3 row reddens without it, and it costs
     8 B more a parked coroutine.

## Consequences

- **What a parked coroutine keeps.** 4 calls deep: 745 B on the heap, where it kept
  3,691 to 3,692 B (the scheduler suite's measure; Darwin arm64, and Linux aarch64 and
  x86_64, the last under emulation). At an `await`, 2,000 parked at once: 654 to 688 B,
  where 3,634 to 3,644 (the M7 exit's measure; Darwin arm64 and Linux aarch64).
- **A park still allocates a stack segment:** 3,919 to 3,984 B a park, where 3,772. The
  drain goes on in a fresh one. What differs is what the parked coroutine keeps.
- **A wake and park allocates more:**
  - 419 B with the scheduler alone, where 291;
  - 532 B through `await`, where 403;
  - the number is 39 to 71 B of it, the frame the landing keeps, and 40 B of the 745
    parked.

  Times are within the noise, with the scheduler alone: 100 to 111 ns against 96 to
  129 on Darwin, and 103 to 115 against 98 to 107 on Linux.
- **The scheduler suite holds both.**
  - A park's or a yield's continuation entered a second time is refused, naming the
    verb, and the code after it runs once.
  - A coroutine parked 4 calls deep keeps under half of what a one-shot continuation
    held at the same depth keeps. The reference is measured in the run (3,419 to
    3,420 B), and should it keep under 2 KiB the suite stops as a provenance failure.
- **Not caught:** a coroutine returning into an old drain, R3 broken, re-runs that drain
  where `call/1cc` refused it. The R3 row holds R3.
- **chez-websocket's socket suite** calibrates its heap check with a wait by `call/1cc`
  around an `await` (S-PARK). On this scheduler the park's capture promotes that wait,
  which then keeps no segment. Run with this change shadowed in, S-PARK stopped as a
  provenance failure: 196 B a connection over a bare `await`. Its reference has to
  change before its pin moves to this release.
- **Release:** server 0.4.1, a patch. Nothing an embedder calls changes. What changes is
  what a parked coroutine keeps, and the assertion a second landing raises.
- `docs/handlers.org`'s "about 3.6 KB" for a waiting handler, and for a thunk that
  waits, is now about 0.7 KB.
