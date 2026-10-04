# 0015: A handler waits with `await` and three verbs of the server's, each wait one-shot and timed to the millisecond

Date: 2026-10-02
Status: accepted (user decision, 2026-10-02)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M7.2

## Context

Decision 0014 lets a handler wait. One that answers `(awaiting thunk)` runs `thunk` on a
coroutine, as it does the reader and the producer it answers with. The verbs it waits
with were left to M7.2 (0014 item 4), and they are public API. The brief names `await`
and `with-deadline`, and its exit has a handler awaiting `uv-getaddrinfo!`. Design §5.3's
R4 makes a resume cell one-shot: a second fulfilment is a recorded fault, never a second
resume. Two rules stand between a handler and libuv: the facade exports no libuv name or
handle (decision 0003, design §7.6, `tests/test-exports.sps`), and a libuv callback runs
no handler code (R1).

Measured by `research/spike/m7-waits.sps` with `m7-waits.sh` (2026-10-02; Darwin arm64,
and Linux 6.12.76-linuxkit aarch64 in Docker's `chez-libuv-valgrind:10.4.1` image; Chez
10.4.1; two runs on each). Each wait is a one-shot cell on the real scheduler, whose poll
is `uv-run` on a real loop.

Found first: M7.1's scheduler allocates 3,756 B for each coroutine, even one that never
waits, where the spike's scheduler cost about 190 B (0014). The `guard` that catches a
coroutine's raise sits inside the one-shot continuation the drain enters, and with it
Chez gives each coroutine a stack of its own. An exception handler that jumps to the
drain's continuation (`m7-scheduler-escape.patch`) catches the same raises for 374 B.
The figures below are on the scheduler so patched, as M7.2's first step makes it:

| 10,000 coroutines | bytes each | ns CPU each, Darwin | ns CPU each, Linux |
|---|---|---|---|
| all at once, none waiting | 374 (today 3,756) | 60–66 | 59–60 |
| all at once, each waiting once | 4,034 (today 7,423) | 1,080–1,093 | 1,478–1,639 |
| one at a time, each waiting once | 989 (today 4,403) | 317–330 | 410–434 |

All at once, each parked coroutine keeps a stack of its own, about 3.6 KB, as 0014's
coroutine parked 4 calls deep held 3,515 B.

Three ways to time a sleep: 10,000 coroutines sleeping 1 ms at once, and one sleeping
10 ms eight times in a row.

| a sleep | bytes each | ns CPU each, Darwin / Linux | a 10 ms sleep took, Darwin / Linux | libuv handles |
|---|---|---|---|---|
| one timer a loop, armed for the earliest of a binary heap | 4,067 | 1,687–1,688 / 2,168–2,234 | 11.0 / 10.2–13.7 ms | one a loop |
| the deadlines' wheel, at its 250 ms tick | 4,160 | 2,685–2,989 / 3,673–3,919 | 250.7–252.2 / 251.3–256.2 ms | the deadlines' one |
| a libuv timer a sleep | 9,322 / 9,440–9,446 | 2,959–3,038 / 3,633–3,646 | 10.2–11.0 / 11.6–13.4 ms | one a sleep: 10,000 at once |

`uv-getaddrinfo!` of "localhost", stream sockets only, awaited 100 times in a row,
answered `("::1" "127.0.0.1")` with 4,221 B a lookup, the medians 176–181 µs on Darwin
and 120–122 µs on Linux; 100 at once took 15.2–15.9 ms in all on Darwin and 3.7–6.0 ms
on Linux. A 50 ms deadline around a wait no one ended raised at 51.0 ms on Darwin and
54.9–55.6 ms on Linux, and the resume that came later was counted and woke nothing. A
wait whose resume the handler's own libuv callback was to call, that callback raising
first: `uv-run` raised `&uv-callback-error`, and the coroutine never ended.

Read for the third question, in the servers surveyed (`research/server-*.md`): Warp and
Node let a handler run on when its client goes. Warp reads only when the app pulls the
body; Node destroys the request and response objects, while the handler's own code runs
on. Go cancels the request's context, which a wait may watch; hyper drops the handler's
future; nginx's proxy closes the upstream request by default (`proxy_ignore_client_abort
off`, in nginx's documentation).

## Decision

1. **A handler waits with four verbs**, which the facade exports with `awaiting` (0014
   item 2), and which only code on a coroutine may call (0014 item 3):
   - `(await register)`: `register` is called with `resume`, and the coroutine parks
     until `resume` is called, by anything the loop's thread runs: the server's own
     callbacks, another handler, a reader or a producer. `await` answers what `resume`
     was given. So one request can wake another.
   - `(sleep-ms n)`: the coroutine parks for at least `n` milliseconds of the loop's
     clock. Not `sleep`: Chez's own would clash on import ("multiple definitions for
     sleep").
   - `(resolve host)`: the coroutine parks until the host's resolver answers, through
     `uv-getaddrinfo!` on libuv's threadpool, stream sockets only; the answer is the
     addresses, as strings, in the resolver's order. A failure raises `&resolve-error`,
     whose reason names the resolver's error (`EAI_NONAME` and so on).
   - `(with-deadline ms thunk)`: what `thunk` returns; once `ms` milliseconds have
     passed, the wait in progress, or else the next one `thunk` begins, raises
     `&deadline-passed`. Code that does not wait is never interrupted.

   No libuv name or handle reaches a handler, so a libuv callback still runs no handler
   code (R1).
2. **A wait is one-shot (R4).** A `resume` called again, or a lookup's answer after its
   deadline, is a recorded fault, logged as `late-resume`, and wakes nothing, not even a
   coroutine that waits again.
3. **Sleeps and deadlines are timed to the millisecond** by one libuv timer a loop,
   armed for the earliest of a binary heap of the loop's timed waits. Each is armed at
   the loop's time, brought up to date, plus its milliseconds, as the shell arms its
   deadlines. The connections' deadlines keep their wheel.
4. **A wait goes on when its connection closes.** A reader or a producer waiting as its
   connection closes runs to its end, and what it answers is dropped; the connection
   makes no more calls, as in M7.1. A handler's own wait cannot see a close in v1:
   reading stops while a handler runs, and nothing is armed or written until it answers.

Weighed, on the same form: the server's verbs alone, with no `await`, so that no request
can wake another; and anything libuv offers, the loop handed to a handler, whose own
callbacks then run inside libuv, where one that raises leaves its handler parked for
good and its client unanswered (the spike's fifth part; nothing is armed while a handler
waits). The deadlines' wheel, which made a 10 ms sleep take 250 ms; and a libuv timer a
wait, 5.3 KB more a sleep and 10,000 handles at once. A wait that raises at once when its
connection closes, which frees its stack, but leaves any code after a wait in a reader or
a producer liable never to run.

## Consequences

- The facade exports `awaiting`, `await`, `sleep-ms`, `resolve` and `with-deadline`, and
  the two conditions, `&deadline-passed` and `&resolve-error`, with their predicates and
  `resolve-error-reason`. Still no `uv-` name (`tests/test-exports.sps`).
- The verbs find their loop through the coroutine running, so the libuv shell gives each
  loop's scheduler what its waits need: the loop's clock, its timer, a lookup and its
  cancel, and the log. A fake shell can give scripted ones (M7.3), so the verbs' checks
  need no libuv, as the scheduler's need none.
- A deadline that ends a lookup cancels it if libuv has not started it (`uv-cancel!`); a
  lookup already running answers late, and its answer is logged (item 2).
- A parked coroutine holds about 3.6 KB while it waits, and its connection's close does
  not free it (item 4): `with-deadline` bounds the wait.
- One libuv timer more a loop, made by the first timed wait and stopped while none is
  armed, so an idle server still sleeps (0005).
- Design §5.3's third mutation, the one-shot check removed, reddens R4's check: a resume
  called again wakes a coroutine that waits again.
- M7.1's scheduler catches a coroutine's raise without a `guard`, as M7.2's first step,
  with a check that fails on today's 3,756 B.

## Chosen while building, and flagged for review

M7.2 is built in four steps (plan §14's M7.2 note), on 2026-10-02. Each step's choices
are under its name.

**The scheduler** (the first step):

- **A coroutine's raise is caught by a handler that jumps to the drain**, not by a
  `guard`. Inside the one-shot continuation the drain enters, a `guard` gave each
  coroutine a stack of its own: 3,756 B for one that never waits, where this costs 374 B.
  Beside M7.1's scheduler, it ends a coroutine the same way in seven cases no check
  covers, a raise inside an `after` thunk among them. A `guard` that handler code runs on
  a coroutine still costs the stack, and `docs/handlers.org` says so.

**`await`** (the second step):

- **A wait asks before it begins** whether the coroutine running may park (the
  scheduler's `waiting-coroutine`, which a park asks too). One refused, as R1, R2 or R5,
  has run nothing of its own, so no resume is left registered to wake nothing.
- **A resume called while `register` runs ends the wait at once**, and the coroutine
  does not park.
- **A late resume's log line names the verb it came for**: `late-resume await`,
  `late-resume resolve` (M7.2's review: at first it named nothing).
- **The loop's waits log through the log of the first shell on the loop.** A loop's
  scheduler, and its waits, are shared by every shell on it; `serve` runs one shell a
  loop.
- **The last three steps are a verb each**, exported and documented, where the plan's
  first note had the waits first and the shell's part, the facade and the docs last.

**`sleep-ms` and `with-deadline`** (the third step):

- **A deadline is in force from its start until its thunk is left, once**: by a return,
  a raise or a continuation. A `dynamic-wind` holds it, whose after thunk a park runs
  too, and tells a park from a leaving by the scheduler's `coroutine-suspending?`. A
  raise that a handler outside continues leaves nothing, and a continuation that enters
  the thunk again does not put the deadline back. Every value the thunk returns comes
  back. First held by an exception handler, which a continuation escaping the thunk
  passed by, leaving the deadline in force, and which passed one value only (M7.2's
  review); the `dynamic-wind` costs 672 B where the handler cost 688.
- **Once passed, a deadline makes every wait inside it raise at once**, so a handler
  that catches the first raise and waits again inside it is not waiting past its time.
- **`&deadline-passed` is an `&error`, raised with `raise`**, which a handler may not
  return from; the docs catch it with `guard`.
- **A sleep and a deadline due at the same time end in the order they were armed**, and
  a sleep a deadline took back in the same advance of the timer wakes nothing.
- **The timer of the waits is closed as the tick timer is**: stopped while nothing is
  armed, closed by a shell that serves no more, made again by the next timed wait. Each
  shell keeps the box the timer lives in: read from a table of the shell library's own,
  it made every request's closures carry the table, 130 B a request more.

**`resolve`** (the fourth step):

- **A lookup asks for stream sockets alone**, so each address is answered once.
- **A name refused at the call is answered `invalid-name` at once**, so `resolve` raises
  `&resolve-error` for any name that does not resolve: libuv's EINVAL, for a name empty
  or over 255 octets, and chez-libuv's own refusal, for one with a NUL in it, are caught
  by a handler that jumps out on a one-shot continuation, 208 B a lookup where a `guard`
  costs 3,663. First the shell checked for empty names and NULs alone, and a long name's
  EINVAL came out of `resolve` as chez-libuv's (M7.2's review). Anything else refused at
  the call is raised as chez-libuv raises it.
- **`&resolve-error` carries the host among its irritants**, beside its reason.

## Amendment (2026-10-04) — a client's close ends the wait, once

Decided on the owner's word on 2026-10-04, recorded as [0020](0020-a-clients-close-is-noticed-while-its-request-is-answered-and-the-wait-its-code-is-in-raises-client-closed-once.md). Item 4 holds
for every close but the client's own: a drain's force, a deadline, the shell's. A
handler's wait can now see the client's close, since the connection reads past the
request's end: the wait the request's code is in, or else its next, raises
`&client-closed`, once ("Once", by form), and a handler that lets it out is answered
nothing ("Close quietly", by form). The alternative weighed above, a wait that raises
when its connection closes, is taken for the client's close alone, and once, so code
after a caught raise still runs and may wait again.
