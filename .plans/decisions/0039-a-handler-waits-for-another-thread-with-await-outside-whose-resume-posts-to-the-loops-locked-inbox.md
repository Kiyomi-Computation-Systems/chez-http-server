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
   - A taker's coroutine has it on the same rules as `await` (the owner: "Yes, same
     rules"; decision 0023).
   - The name is the proposal's (the owner: "await-outside").
2. **`resume : Any -> Boolean`, from any thread, the loop's own included.**
   - `#t`: the value is posted, and the loop will look at it. Not delivery: the wait may
     end first.
   - `#f`: nothing is posted. This `resume` was called before, or its inbox has closed.
   - It never raises, never blocks beyond the inbox's lock, and never runs handler code.
   - A second call, and each after it, answers `#f`. While the inbox is open, it posts a
     notice instead, and the loop's thread logs `late-resume await-outside`. The caller's
     thread never writes the log.
   - No third answer, such as `'abandoned` (the owner: "#t or #f only").
3. **A value never arrives while `register` runs.** Delivery is on the loop's thread,
   after the turn's poll, so a wait always parks, even when `register` calls `resume`
   itself. An outside wait has no `'early` state.
4. **A value posted to a wait already ended is dropped, and not logged** (the owner:
   "Drop it silently"). That covers a deadline, a client's close and a `register` that
   raised. A worker can't be stopped mid-call, so for an outside wait this is the normal
   case. Only a second call of the same `resume` is logged.
5. **Whichever reaches the wait first on the loop's thread wins,** and the other is
   dropped (the owner: "First on the loop wins").
   - In one libuv turn the inbox's callback runs in the poll, before the timers. So a
     value posted before a turn beats a deadline that falls due in it. That needs no
     code and reads no clock across threads.
   - The test host does the same: an acting call delivers what was posted since the last
     one, at the host's current time, before it moves the clock or fires anything.
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
   - A post takes the mutex. If the flag is set and the `resume` is fresh, it queues
     `(cell . value)`, marks the `resume` used and sends the wake, all under the mutex.
   - Closed when the shell serves no more, where `release-timer!` closes the signal
     handles: the flag is cleared under the mutex, the handle closed through
     `handle-close!`, and the queue emptied once more. A later outside wait opens a fresh
     inbox, and every `resume` of the closed one answers `#f`.
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
   complete and deterministic over its states and events, and each row is driven against
   the test host, as `tests/test-connection-table.sps` holds the core's table. The tables
   here are written by hand.
9. **Not here:** circuit's re-export and its worker, a thread with a bounded queue, and
   its inline double for tests (the proposal's §9). They are circuit's to build once a
   release of the server has the verb.

### The wait

Every transition is on the loop's thread.

| State | Event | Next | What happens |
|---|---|---|---|
| registering | `register` returns | parked | The coroutine parks. |
| registering | `register` raises | dead | The raise leaves `await-outside`. No wait began. |
| parked | a posted value is delivered | resumed | The coroutine is ready; `await-outside` answers the value. |
| parked | a deadline passes | abandoned | `await-outside` raises `&deadline-passed`. |
| parked | the client closes | abandoned | `await-outside` raises `&client-closed`. |
| abandoned | a posted value is delivered | abandoned | Dropped, not logged (item 4). |
| dead | a posted value is delivered | dead | Dropped, not logged. |

A second delivery to a resumed wait can't happen, since a `resume` posts once (below).

### The `resume`

Each transition is under the inbox's mutex, on whichever thread calls it.

| State | Called while the inbox is | Next | Answer | What happens |
|---|---|---|---|---|
| fresh | open | used | `#t` | The value is queued; the loop is woken. |
| fresh | closed | refused | `#f` | Nothing. |
| used | open | used | `#f` | A notice is queued; the loop logs `late-resume await-outside`. |
| used | closed | used | `#f` | Nothing. |
| refused | open or closed | refused | `#f` | Nothing. |

### The inbox

One per loop.

| State | Event | Next | What happens |
|---|---|---|---|
| absent | an outside wait | open | The opener makes the handle; the flag is set. |
| open | a post | open | Queued; the wake is sent. |
| open | the handle's callback | open | The queue is emptied; each item is delivered. It may find the queue empty. |
| open | the shell serves no more | closed | The flag is cleared under the mutex; the handle is closed; the queue is emptied once more. |
| open | a wake meets a closed handle | closed | The post takes its item back; its `resume` answers `#f`. |
| closed | a post | closed | Refused: `resume` answers `#f`. |
| closed | an outside wait | open | A fresh inbox, with a handle of its own. |

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
- **A wait still parked when the shell serves no more never ends.** Its `resume` answers
  `#f` from then on. On a loop with several shells, which `serve` never makes, the first
  shell to serve no more closes the loop's inbox, so the others' outside waits parked
  then are refused too.
