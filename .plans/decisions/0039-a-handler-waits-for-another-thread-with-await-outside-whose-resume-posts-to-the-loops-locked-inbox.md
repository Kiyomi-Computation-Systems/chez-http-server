# 0039: A handler waits for another thread with `await-outside`, whose `resume` posts to the loop's locked inbox

Date: 2026-11-22
Status: accepted (user decision, 2026-11-22: issue #260, Techo's proposal, picked up with
"let's tackle issue 260"; its seven questions answered by form)
Plan: none; the issue is the design, as the answers below amend it

## Context

- **The server is one loop on one thread** (`docs/how-it-works.md`). A blocking call in
  a handler stops everyone: circuit's `docs/waiting.md` measured a request for `/` taking
  1.7 s while one handler slept 2 s with Chez's `sleep`.
- **Some work can only block.** A SQLite query through chez-sqlite3 is `sqlite3_step`, a
  C call, and its connection is bound to the thread that opened it. A password hash
  (argon2id) is CPU on purpose, 100 ms or more. Neither has a file descriptor to poll.
- **Today there is no way out.** Read at fa9c46a, where `src/` is the issue's 12e8a6f
  byte for byte (`git diff --stat 12e8a6f fa9c46a -- src` is empty):
  - `resume!` (`src/http-server/private/waits.sls`) and `coroutine-wake!`
    (`src/http-server/private/scheduler.sls`) change the cell and the ready queue with no
    lock. Decision 0015 item 1: `resume` is called "by anything the loop's thread runs".
  - With nothing ready, `scheduler-turn!` polls with `uv-run` in `'once`, which sleeps
    until libuv has something: a resume from another thread would not wake it.
  - The facade exports no libuv name or handle (decision 0003, `tests/test-exports.sps`).
- **The door was left open.** Decision 0003's dated note: the worker-pool route is
  admissible from chez-libuv v0.6.0 on, which has `__collect_safe` and `uv_async`.
- **chez-libuv's recipe** (`docs/threads.md`, "Wake a loop from another thread"), at the
  v0.11.0 pin: `uv-async-send!` is the one verb any thread may call; sends coalesce; a
  close drops wakes still pending; a send that meets a close raises `&uv-handle-closed`
  without touching the handle; an open async handle keeps `uv-run 'default` from
  returning. To know which items are handled: a mutex, a queue and an open flag; a
  sender queues and sends under the mutex only while the flag is set; `on-wake` empties
  the queue under the mutex; to shut down, clear the flag under the mutex, close the
  handle, then empty the queue once more.
- **libuv's turn, read in its source** (1.52.1, `src/unix/core.c` and `src/win/core.c`,
  `uv_run`): in `'once` and `'nowait`, the modes the scheduler polls with, a turn polls,
  which runs the async handles' callbacks, before it runs the timers. The proposal's
  suggestion for its row 9, that a deadline due in the same turn as a value wins,
  contradicts this order.

## Decision

1. **The verb.** `(await-outside register)`, exported by `(http-server)` beside `await`:
   - `register` is called once, on the coroutine, on the loop's thread, with `resume`.
   - The coroutine then parks until a value `resume` posted is delivered, and
     `await-outside` answers it.
   - It is refused where `await` is, before `register` runs: inside a libuv callback (R1),
     on no coroutine (R2), inside a feed (R5). A wait on waits the shell gave no inbox
     opener is an assertion violation, as a lookup on waits with no resolver is.
   - Every wait, this one, `await` and the rest, is refused as R2 on any thread but the
     loop's, before anything else. The scheduler keeps the thread its drain runs on.
     The review found the hole: a wait on a worker read the loop thread's running
     coroutine. With one running, it ran `register` on the worker and parked into the
     loop thread's drain, and the process died with "attempt to return to stale foreign
     context" (`build/review-probe/offthread-park.sps`). The hole is older than this
     verb, but this verb puts code on other threads.
   - A taker's coroutine has it on the same rules as `await` (the owner: "Yes, same
     rules"; decision 0023).
   - The name is the proposal's (the owner: "await-outside").
2. **`resume : Any -> Boolean`, from any thread, the loop's own included.**
   - `#t`: the value is posted, and the loop will look at it. Not delivery: the wait may
     end first.
   - `#f`: nothing is posted. This `resume` was called before, or its inbox has closed.
   - It never raises, never blocks beyond the inbox's lock, and never runs handler code.
     The lock is held with interrupts disabled. Otherwise an engine expiring mid-post
     left it held for ever (the review's `engine.sps`), and the loop's next delivery
     would have blocked.
   - The trade: a thread waiting for the lock with interrupts disabled is not
     deactivated, so a collection anywhere in the process waits for it to get the lock.
     It is safe because every section that holds the lock waits on nothing, the wake a
     send inside chez-libuv's own interrupt-free fence; chez-libuv's `with-step-lock`
     makes the same trade. A probe of a thread blocked on a mutex held for ever hangs
     the process with interrupts disabled, and collects with them enabled.
   - A second call, and each after it, answers `#f`. While the inbox is open, it posts a
     notice instead, and the loop's thread logs `late-resume await-outside`. The caller's
     thread never writes the log.
   - No third answer, such as `'abandoned` (the owner: "#t or #f only").
3. **A value is handed over at a delivery, a later step of the loop's thread,** so a
   wait parks even when `register` calls `resume` itself.
   - The one exception is a `register` that itself waits, such as for room in a
     bounded job queue. A value delivered while it waits is kept, as `await`'s early
     resume is, and `await-outside` answers it as `register` returns, without parking.
   - Dropping that value would be wrong. The first build dropped it, and `resume`
     answered `#t` while the handler waited for ever. A probe found it: `register`
     sleeping 10 ms, a value posted meanwhile.
   - A `register` that raised keeps a value posted to it, beside the coroutine it
     already keeps, until its `resume` is let go, as `await`'s does.
4. **A value posted to a wait already ended is dropped, and not logged** (the owner:
   "Drop it silently"). That covers a deadline, a client's close and a `register` that
   raised. A worker can't be stopped mid-call, so for an outside wait this is the normal
   case. Only a second call of the same `resume` is logged.
5. **Whichever reaches the wait first on the loop's thread wins,** and the other is
   dropped (the owner: "First on the loop wins").
   - In one libuv turn the inbox's callback runs in the poll, before the timers. So a
     value posted before a turn beats a deadline that falls due in it. That needs no
     code and reads no clock across threads.
   - The value wins, but the deadline still passes in that turn, before the coroutine
     runs. So `await-outside` answers the value, and the next wait inside that deadline
     raises.
   - The test host delivers first too: an acting call delivers what was posted since the
     last one, at the host's current time, before it moves the clock or fires anything.
     But it runs what the value wakes before the clock moves, so it shows a value that
     came in time. The review measured the difference with `value-then-wait.sps`: 504 on
     the server, 200 on the host. `docs/testing.md` says so.
6. **The inbox: one per loop, the waits'.**
   - It is a mutex, a queue and an open flag, in `(http-server private waits)`, so the
     test host and the libuv shell run one implementation of the machines below.
   - The wake is the shell's. The shell gives the waits an opener, as it gives them a
     clock and a resolver. The opener makes one libuv async handle and answers a `wake!`
     any thread may call, which says whether the wake was sent.
   - The handle's callback, on the loop's thread, takes the queue under the mutex,
     releases it, then delivers each item. It only wakes coroutines (R1).
   - Made by the first outside wait that finds no inbox open (the owner: "At the first
     outside wait"). A server that never waits outside makes no handle.
   - The opener answers `#f` in place of `wake!` when the loop takes no posts. The shell
     counts the shells on the loop that serve, and the loop takes no posts once none
     does. The waits then make that inbox closed from the start, so its `resume` answers
     `#f`, and no handle is made. The review found that, without this, a coroutine that
     outlived its connection and waited outside after the stop opened a handle no one
     closed (`reopen-leak.sps`).
   - A post takes the mutex. If the flag is set and the `resume` is fresh, it queues
     `(cell . value)`, marks the `resume` used and sends the wake, all under the mutex.
   - Closed when the last shell on the loop serves no more, where `release-timer!` closes
     the signal handles: the flag is cleared under the mutex, the handle closed through
     `handle-close!`, and the queue emptied once more. The handle it keeps is closed even
     when a failed wake closed the inbox first. While a shell on the loop serves, a later
     outside wait opens a fresh inbox, and every `resume` of the closed one answers `#f`.
   - A wake that meets a handle someone else closed, as a loop's teardown does, answers
     `#f`. The post then takes its item back and closes the inbox, so its `resume`
     answers `#f` and never raises.
7. **The test host gains two calls:**
   - `(test-host-posted host)`: how many posted values wait to be delivered.
   - `(test-host-stop-posts! host)`: an acting call that closes the inbox, delivering
     what was queued, so a test reaches a refused `resume`.

   The proposal's `test-host-deliver!` is not added. Every acting call delivers first,
   and `(test-host-advance! host 0)` already runs what is ready, as `docs/testing.md`
   teaches for a `resume` the test calls itself.
8. **The machines are rows of data in the suite** (the owner: "Rows as data, tables by
   hand"). Each table below is a list of `(state event next effect)` rows, checked
   complete and deterministic over its states and events, and each row is driven, as
   `tests/test-connection-table.sps` holds the core's table. The wait's rows are driven
   against the test host; the resume's and the inbox's against waits with an opener of
   the test's own. The tables here are written by hand.
9. **Not here:** circuit's re-export and its worker, a thread with a bounded queue, and
   its inline double for tests (the proposal's §9). They are circuit's to build once a
   release of the server has the verb.

### The wait

Every transition is on the loop's thread.

| State | Event | Next | What happens |
|---|---|---|---|
| registering | `register` returns | parked | The coroutine parks. |
| registering | `register` raises | dead | The raise leaves `await-outside`. No wait began. |
| registering | a posted value is delivered | early | Only while `register` itself waits: the value is kept (item 3). |
| early | `register` returns | resumed | `await-outside` answers the value without parking. |
| early | `register` raises | dead | The raise leaves `await-outside`; the value is kept, unseen (item 3). |
| parked | a posted value is delivered | resumed | The coroutine is ready; `await-outside` answers the value. |
| parked | a deadline passes | abandoned | `await-outside` raises `&deadline-passed`. |
| parked | the client closes | abandoned | `await-outside` raises `&client-closed`. |
| abandoned | a posted value is delivered | abandoned | Dropped, not logged (item 4). |
| dead | a posted value is delivered | dead | Not handed to anyone, not logged. |

A second delivery to a resumed or early wait can't happen, since a `resume` posts
once (below).

### The `resume`

Each transition is under the inbox's mutex, on whichever thread calls it. A `resume`
posts to the inbox open as its `register` ran, its own, whatever inbox is open since.

| State | Called while its inbox is | Next | Answer | What happens |
|---|---|---|---|---|
| fresh | open | used | `#t` | The value is queued; the loop is woken. |
| fresh | closed | refused | `#f` | Nothing. |
| used | open | used | `#f` | A notice is queued; the loop logs `late-resume await-outside`. |
| used | closed | used | `#f` | Nothing. |
| refused | closed | refused | `#f` | Nothing. |

A refused `resume` can't find its inbox open: it is refused only once its inbox has
closed, and a closed inbox never opens again.

### The inbox

One per loop.

| State | Event | Next | What happens |
|---|---|---|---|
| absent | an outside wait, the loop taking posts | open | The opener makes the handle; the flag is set. |
| absent or closed | an outside wait, the loop taking none | closed | The opener makes no handle; the wait's `resume` is refused. |
| absent | the shell serves no more | absent | Nothing: no handle to close. |
| open | an outside wait | open | The wait's `resume` posts to it. |
| open | a post | open | Queued; the wake is sent. |
| open | the handle's callback | open | The queue is emptied; each item is delivered. It may find the queue empty. |
| open | the last shell on the loop serves no more | closed | The flag is cleared under the mutex; the handle is closed; the queue is emptied once more. |
| open | a wake meets a closed handle | closed | The post takes its item back; its `resume` answers `#f`. |
| closed | a post | closed | Refused: `resume` answers `#f`. |
| closed | the shell serves no more | closed | Nothing: its handle is closed already, or a teardown closed it. |
| closed | an outside wait, the loop taking posts | open | A fresh inbox, with a handle of its own. |

## Consequences

- **Only `resume` from `await-outside` crosses threads.** Request accessors, transports,
  responses and a plain `await`'s `resume` stay loop-thread only.
- **The traps the documents name** (the proposal's §7):
  - A worker's blocking C call that is not `__collect_safe` freezes the loop at its next
    collection.
  - `register` runs on the loop's thread.
  - A worker that raises wakes no one, so a worker catches and posts.
  - A deadline doesn't stop the worker.
  - `#t` is not delivery.
  - Wakes coalesce.
  - Only `resume` crosses threads.
  - Thread parameters don't cross.
  - `with-mutex` doesn't hold across a wait.
  - The worker must be a Chez thread.
  - A `resume` kept after the stop answers `#f`.
  - Order is per thread only.
- **A wait still parked when the last shell serves no more never ends.** Its `resume`
  answers `#f` from then on, and so does that of a wait begun after.
- **What is kept.** Values posted (`#t`) before a teardown closed the handle stay queued,
  with their cells, until the loop is let go. A `resume` a worker keeps holds its cell,
  and through it the loop's waits and the opener's closure.
- **Left as they are:**
  - A shell is counted as it is made, so one whose listen raises stays counted. `serve`
    makes a loop of its own and tears it down, so only a caller of the private
    `start-server` on a loop it keeps sees it: an inbox a later shell opens there stays
    open until the loop's teardown.
  - A timed wait still armed when the last shell serves no more leaves the waits' timer
    open until it fires. It keeps no `uv-run 'default` running for ever. This predates
    the verb.
  - Two cases no code reaches, since a send on an open handle can't fail: a wake that
    fails on an open handle, followed by a fresh inbox, would leave the old handle
    unclosed; and values queued before such a wake are not delivered again at the stop.
- **The costs** (the proposal's §8.4), on the final tree, Linux x86_64, Chez 10.4.1
  `ta6le`, four runs of `.plans/research/spike/outside-waits.sps`, load 1.1–1.4:
  - 10,000 waits ended in one turn: an outside wait 1,624 B and 0.56–0.57 µs, against
    `await`'s 1,256 B and 0.38–0.39 µs. One at a time, 2,527 B and 1.4 µs, against
    1,256 B and 0.2–0.3 µs: each takes a turn of the loop.
  - Each `resume` called by one worker, one at a time: 2,236 B, 5.8–6.3 µs of CPU, the
    two threads together.
  - The first outside wait on a fresh loop: 3,168 B, and one async handle. Every other
    fresh loop reads 68,688 B, as after `await` waits and in a window with no inbox:
    the runtime's, not the inbox's.
  - Resume to run: median 9.5–11.5 µs at rest; 0.27–0.31 ms, 99th percentile up to
    1.1 ms, with 8 workers answering 256 waits, about 250 values a turn.
  - An idle open inbox: one turn a second asleep and 6.4–14 µs a turn ticking, either
    way. A GET: 5,139–5,154 B, either way.
- **The review** (read-only, Opus) found seven things on the branch's first build. Four
  it reproduced and three it reasoned; all are fixed above or in the docs. The other
  three: a check of a post made during the drain was missing; the idle-window check
  assumed the tick timer had stopped; and the docs' reason not to hold a lock over a
  wait was incomplete, since the wait takes the lock again as it resumes, on the loop's
  thread.
  Its probes were scratch programs under `build/`; the suites now hold what each showed,
  each check watched to fail under a mutation.
