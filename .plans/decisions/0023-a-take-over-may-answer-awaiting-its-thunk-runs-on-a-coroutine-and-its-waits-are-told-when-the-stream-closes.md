# 0023: A take-over may answer `awaiting`: its thunk runs on a coroutine, and its waits are told when the stream closes

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, by form: "take-over answers awaiting")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §15
Amends: [0016](0016-an-upgrade-is-taken-by-answering-switch-protocols-and-handed-over-as-a-transport-the-server-keeps.md)'s
consequence that a taker's code "cannot wait with `await`"

## Context

Decision 0022 has WebSocket code read with a call that waits for the next message. A
taker's code runs in place, in the shell's callbacks (0016), and only code a coroutine
runs may wait (0014; design §5.3). `await` itself is general: `(await register)` parks
until something calls the `resume` it handed out, so a read callback, running in place,
can wake a coroutine waiting for a message. What a taker lacked was a coroutine.

The shells already run a handler's `(awaiting thunk)` that way (`call-waiting!`), with
the request's notice attached (decision 0020). The libuv shell calls a take-over through
`taker-call!`, which drops what it answers.

## Decision

By form, the recommended of three:

1. **A take-over may answer `(awaiting thunk)`**, as a handler does (0014). It is still
   called in place once the 101 is written. Given an `awaiting`, the shell runs its thunk
   on a coroutine, from the scheduler's drain. Anything else a take-over answers is
   dropped, as before, so a taker that does not wait is unchanged and runs no coroutine.
2. **Its waits are told when the stream closes, whoever closed it.** The thunk's
   coroutine is given a notice of the taker's own (0020's), which is closed as the
   stream's close completes. So the wait it is in, or else its next, raises
   `&client-closed`, once.
3. **A raise of that close is no failure**: nothing is logged. Anything else the thunk
   raises is logged `taker-failed` and closes the stream, as a take-over that raises
   does. What the thunk returns is dropped, and the stream stays open.

## Consequences

- The libuv shell and the fake shell do the same.
- The fake now drains its scheduler after a delivery to a taker and after a taker's
  completion, unless held. Each is a turn of the libuv shell's, which drains as its turn
  begins. The cross-shell contract test holds no door script (0016), so its replay is
  unchanged.
- A thunk parked in a wait holds a coroutine until the wait ends, as a handler that waits
  does (design §5.2: 3,637 to 3,644 B parked).
- The taker's notice is made as its thunk is spawned, in `hand-off!`, before the stream
  can have closed: a stream's close completes in a later callback. A first draft also
  closed a new notice at once "if the stream has closed already"; nothing reaches that
  case, so it went.
- The docs' example (`docs/handlers.org`, "A taker that waits") was run as written
  against the fake shell: it wrote back three reads in order, one of which came while its
  loop was busy, and the client's end closed the stream with nothing logged.
- The checks: five in the fake's door suite (`tests/test-connection-switch.sps`) and
  three on a real socket (`tests/test-shell.sps`); sixteen mutants, each red
  (`.superpowers/sdd/m8-mutations.md`, "After M8").
- Weighed and not taken:
  - every take-over on a coroutine: no ceremony, but it changes 0016's contract for every
    taker, starts each a turn later, and costs each a coroutine;
  - a spawn verb, `(transport-spawn! t thunk)`: as many coroutines as wanted, but more
    public API, each with a notice and a lifetime of its own.

## Amendment (2026-10-16) — the thunk's values are dropped, however many

Found while mutating the fake's write bound (decision 0027's amendment of this date).
- **What did not hold.** Item 3's "what the thunk returns is dropped". The shells spawned
  the thunk itself, and the scheduler keeps the one value a coroutine returns. So a thunk
  that ended with no values, as one whose last call is `sleep-ms` does, or with two, was
  taken as a raise: `taker-failed` was logged and the stream closed. A probe on the libuv
  shell showed it three times in three runs. A thunk that ended with one value was fine.
- **Now** each shell's `taker-wait!` spawns `(lambda () (thunk) #t)`, as a waiting
  handler's reader's piece is spawned (the M7 exit). The scheduler is unchanged, since its
  other callers read that value.
- **Held by** one check in each shell's suite: a thunk that ends with no values, and one
  that ends with two, leaves its stream open, nothing logged. Four mutants, each red only
  where predicted (`.superpowers/sdd/m8-mutations.md`, the last section). The wrap's
  closure costs a waiting taker about 16 B, once.
