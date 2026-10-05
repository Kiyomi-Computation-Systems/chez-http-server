# chez-http-server — ledger archive: M5, timeouts and limits

M5's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 2295–2824 at 64761cb). The mutation log is `m5-mutations.md`; the spine is `progress.md`.

---

M5.1 — THE WHEEL, AND ITS TWO LIMITS (plan §14 and §3; decision 0005 and its two amendments of 2026-09-27; design §2). Branches feat/m5.1-limits, cut from main at c14956c, and feat/m5.1-timing-wheel, cut from it; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m5-mutations.md, new.

Gathered before the first test, from plan §14, §3 and §9, decision 0005, and the ledger's M2.1 readings:
- plan §14: `(http-server wheel)`, pure: deadlines in `tick-ms` buckets, armed, disarmed and advanced to a `now` the caller gives. A deadline of D fires once, within [D, D + tick-ms], never before D. The plan's mutation: a deadline rounds down to its bucket's start;
- plan §3: `write-timeout-ms` (60,000 per write completion) and `tick-ms` (250) arrive with four things each, and `CHEZ_HTTP_TICK_MS` is read in milliseconds, which `docs/configuration.org` says beside it;
- 0005: the wheel is keyed by `(deadline div tick-ms)`, and the one tick timer per loop stops when the wheel is empty;
- M2.1's reading 2: the core arms kinds, not instants. So the wheel takes instants, and a shell adds the kind's limit to its now (M5.3).

Built first, then reviewed (`/code-review max`, 2026-09-27, before the first commit): a key API, in which the wheel kept its own table from key to entry, 15 checks, and the two limits with 5. Ten finder angles, one verifier for each of the 18 candidates, and a sweep:
- 11 confirmed, 5 plausible, 2 refuted, and 5 more from the sweep. The report held the 15 most severe.
- The wheel's logic held. Three reviewers ran it against a plain list of deadlines, up to 180,000 random operations, and it always agreed. The sweep also re-ran the 30 mutants recorded then, and every count matched.
- What they found was in the tests, the records, and what M5.3 will need.

DECIDED on the owner's word (2026-09-27), by form, the recommended answer to each of four questions:
- **The tick is 1 to 1,000 ms.** Every timeout is given in whole seconds, so a tick over a second would make one late by more than its own unit. Weighed: 2^64 − 1, the most libuv's timer takes (`uv_timer_start`'s `unsigned-64`; Chez's FFI raises above it, after the server listens), which still accepts a tick that never fires, since libuv clamps a timeout that overflows.
- **The wheel takes entries its caller keeps,** one per connection: a disarm then an arm allocates 0 B, where the key API's measured 96 B (an entry and its table cell, 48 B each), three times a keep-alive GET. Weighed: the key API.
- **Decision 0005 is amended:** the wheel fires by deadline, the tick's range, and the entries.
- **The other twelve findings are fixed as proposed,** the kind-to-limit mapping among them.

Found in review, and fixed on the owner's word:
- **Test gaps.** The first plain-list generator reached at most 32,767. A refusal counted whoever raised it, so an inexact deadline was refused by `vector-ref` after the table had changed. No row advanced to 0. No row accepted a 1 ms tick. And two setups sat outside their checks, so a raise there ended a suite as a harness error. Mutants P6, P7 and L12 survived the first suite and now die, and W and L15 now fail as checks, exit 1.
- **Records.** The design note's interval was half-open. 0005 still said a bucket fires once it expires. The wheel's header misdescribed the cursor after `now` went back. And the mutation log gave a false reason for running each mutant against its own suite: every mutant now ran against every suite.
- **For M5.2 and M5.3,** in plan §14's notes: the disarm at close, the first idle arm, the loop's clock, one mapping from kinds to limits, and each tick delivered under its own guard (the readings below).
- **Cut by the report's cap, six:**
  - the sort nothing consumes, about twice the work of a mass expiry: kept, and its order stays a promise;
  - the duplicated unlink, and the model's double filter: gone with the rework;
  - `wheel?` exported unused: kept, as six sibling predicates are;
  - 512 slots with a smaller tick, a few percent a tick: left to M5.3, which builds the wheel;
  - fixnum arithmetic: unsafe for the bignum deadlines the timeouts allow, and not material.
- **Refuted, two:** positional `make-limits` callers (none outside the library), and reusing uv-testing's generator (it exports bytes only).

M5.1 FIRST STEP — THE TWO LIMITS, AND HOW LONG EACH DEADLINE LASTS. Branch feat/m5.1-limits.
- `(http-server limits)`: `write-timeout-ms`, 60,000, from `CHEZ_HTTP_WRITE_TIMEOUT` in whole seconds, and `tick-ms`, 250, from `CHEZ_HTTP_TICK_MS` in milliseconds, 1 to 1,000. They are the sixteenth and seventeenth fields, after `linger-timeout-ms` with the other durations, each with plan §3's four things. Nothing reads them yet: M5.3's shells will. And `limits-deadline-ms`: how long each kind of deadline lasts, one mapping for both shells.
- `(http-server connection)`: `conn-deadline-kinds`, the five kinds the core arms, exported as its other vocabularies are.
- `tests/test-limits.sps`, 46 checks, 6 more than main's 40:
  - the two defaults;
  - the write and tick overrides, read inside their own check;
  - the tick's range: 1 and 1,000 accepted; 0, -1, 1,001 and a word refused;
  - each kind's own timeout, and `drain` refused.
  The variables' list, the drift guard and `limits-with`'s names are extended.
- `tests/test-connection-table.sps`, 3 checks more: the five kinds; the rows arm all five and no other; each lasts one of the limits.
- `docs/configuration.org`: the two variables, the tick's unit and range, and five timeouts not yet enforced.
- Decision 0005's first amendment of 2026-09-27: the tick's range.
- Watched to fail (m5-mutations.md, first step): L1 to L15, K1 and K2, one or more for every check the step added or extended. They ran against all thirty-five suites of the step's own tree and all thirty-six of the finished tree, with the same result.
- Every suite green on the step's own tree, a scratch worktree cut from main at c14956c: thirty-five suites, 900 expected passes (limits 46, connection-table 106), each exit 0. `make check-imports` is clean there.

NEXT: the second step, the wheel, stacked on this one.

M5.1 SECOND STEP — THE WHEEL. Branch feat/m5.1-timing-wheel, cut from the first.
- `src/http-server/wheel.sls`, `(http-server wheel)`, new and pure (`(rnrs)` only):
  - entries are the caller's: `make-wheel-entry key`, kept for as long as the key can have a deadline; `wheel-arm!` arms or moves one; `wheel-disarm!`; `wheel-advance!` returns the keys due by `now`, each disarmed, the earliest deadline first and equal ones in the order they were last armed; `wheel-entry-deadline`, `wheel-entry-key`, `wheel-count` (at 0 the shell stops its timer), `wheel-tick-ms`;
  - the index: bucket b in slot `(mod b slots)`, 512 slots unless given, each a doubly linked ring headed by a sentinel entry. A deadline whose bucket has passed is kept in the cursor's slot, the cursor being the furthest bucket reached. An advance visits the slots from the cursor's bucket to now's, each once at most;
  - it fires by each entry's deadline, never by its bucket; its instants are the loop's clock, `uv_now`, which never steps;
  - an unlinked entry's links are cleared, so an entry a connection keeps holds nothing of the wheel;
  - it refuses a tick or slot count below 1, an instant that is not an exact integer from 0, and what is not an entry, each by the procedure given it, before it changes anything.
- `tests/test-wheel.sps`, new, 18 checks:
  - when a deadline fires, a tick every 250 ms: at the first tick at or after it, row by row, on bucket boundaries and between them; every deadline from 1000 to 3000 ms once, within [D, D + 250), for ticks at three phases (the plan's interval row); an advance to 0; a deadline already past when armed;
  - one deadline per entry: fired once, disarmed and moved; what `wheel-entry-deadline` and `wheel-count` read;
  - an entry the caller keeps, disarmed or fired, holds nothing of the wheel. Weak pointers show it after a full collection, beside an entry still armed, which reads held;
  - the order an advance fires in; a deadline a revolution ahead; one advance over forty deadlines and five revolutions, set up inside its check;
  - the plain-list row: 4,000 operations, the same on the wheel and on a plain list, for six ticks and slot counts from 1 to 512. Its generator now reaches any bound. On the default wheel (tick 250, 512 slots) it arms 357 deadlines a revolution ahead and makes 176 advances over 512 buckets, where the first generator, capped at 32,767, made none (a scratch count);
  - the refusals, each checked to come from the procedure given it; and a refused arm leaves the entry and the count as they were.
- Records:
  - design §2's note: the wheel fires by deadline, within [D, D + tick-ms];
  - decision 0005's second amendment of 2026-09-27: fired by deadline, and entries each connection keeps;
  - plan §14's notes for M5.2 and M5.3 (the readings below).

MEASURED (scratch `wheel-alloc2.sps` and `wheel-cost2.sps`, two runs each, identical where they count bytes; cumulative `sstats-bytes`):
- entries the caller keeps, 1,000 armed, 100,000 operations each: making an entry 48 B, once a connection; a disarm then an arm, 0 B; moving a deadline, 0 B; an advance that fires nothing, 0 B;
- 10,000 entries at uv_now's scale, deadlines spread over 75 s, an advance every 250 ms until all fired: about 2 µs an advance (twenty runs, 12 and 13 ms of CPU), and about 81 B for each entry fired (807,200 B for 9,999: the list, its sort, the keys);
- the first allocation reading, 37.4 B, came from `bytes-allocated`, which is the live heap and drops at each collection; measured again with `sstats-bytes`, as the M2 spike does.

Readings, for M5.2 and M5.3 (plan §14's notes; flagged in the PR):
- M2.1's reading 2 left M5 to decide whether the core should also compare `now`. It need not. The wheel fires an entry only once its deadline has passed, so no tick reaches a connection early, and the core's kind guard (M2.1-D) stays as a defence.
- A tick to a closing or closed connection is already harmless: `on-tick` has no row for them. What is missing is the disarm. The core's close and hand-off clear the deadline without emitting `(disarm-deadline)`, so a closed connection would stay in the wheel, held there, until its deadline passed. M5.2 has them emit it. M5.3's libuv shell also disarms in `handle-close!` and `reconcile!`.
- A connection's first idle deadline is armed by no action: the state starts with `idle` recorded, and the core emits `(arm-deadline idle)` only after a write. M5.3 arms it at adoption, and a client that connects and sends nothing is its test.
- An advance returns its keys already disarmed, so M5.3 delivers each tick under its own guard.

A survivor, measured (M5.1-N): with the cursor never saved, the same keys fire, with more work. Twenty runs of the cost scenario took 157 and 161 ms of CPU, against 12 and 13 with the cursor: about 26 µs an advance against 2. The suite checks what fires, not the work: a scope statement.

Watched to fail (m5-mutations.md, second step): 29 mutants, each against all thirty-six suites:
- M5.1-A, the plan's, turns five wheel checks red, the interval row among them, and no other suite's;
- A2 to W, P1 to P10 and R, one or more for every check the step added;
- N survives, above.

`make test` green on the finished tree: thirty-six suites, 918 expected passes (wheel 18, limits 46, connection-table 106), exit 0. `make check-imports` is clean.

NEXT: two stacked PRs, on the owner's word ("commit it and open the two stacked PRs"):
- feat/m5.1-limits, the first step: 107 inserted lines of code and tests;
- feat/m5.1-timing-wheel, cut from it: 563, over plan §1 rule 1's ~400, since the wheel and its checks do not divide.
Then M5.2, the tick rows the core lacks (`body` answers 408, `responding` closes), with the disarm at close.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.1, as two stacked PRs.**
- **#58, the first step,** as b54c860. Its squash tree (64824e7) is identical to the tested tip's, 39e84c1, and its parent is c14956c. It merged first, keeping its branch, since #59 was based on it.
- **#59, the second step,** as 042260f. It was retargeted to main and rebased from #58's old tip. The rebased tip, 4986465, has the tested tree (9d3df90, d89ac4d's), and so does the squash, whose parent is b54c860.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36339388420 (#58), 36339406157 (#59 as opened) and 36339920482 (#59 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-six suites, 918 expected passes, exit 0.

M5.1 DONE and merged (b54c860, PR #58; 042260f, PR #59): the wheel, and its two limits.
- `(http-server wheel)` fires each deadline as `now` reaches it, and each connection keeps its own entry, so arming and disarming allocate nothing;
- `write-timeout-ms` and `tick-ms` (1 to 1,000) are limits, and `limits-deadline-ms` says how long each of the core's five deadline kinds lasts;
- decision 0005 is amended twice, and plan §14 carries the review's notes for M5.2 and M5.3.

NEXT: M5.2, every deadline the core arms has its tick row (plan §14): `body` past its deadline answers 408 and closes, and `responding` past the write deadline closes with no response. With them, per plan §14's note, the core's close and hand-off emit `(disarm-deadline)`. Then M5.3, one timer per loop in both shells. It starts on a fresh branch cut from main after this commit, when the owner asks.

M5.2 — EVERY DEADLINE THE CORE ARMS HAS ITS TICK ROW. Branch feat/m5.2-tick-rows, cut from main at 2dbef93.

Gathered: plan §14's M5.2 and its note of 2026-09-27; design §4.3's table of states and deadlines, and §4.4; decision 0005's table (on breach, body: 408 and close; write: close).

- `(http-server connection)`:
  - `body` past the body deadline answers 408, reads no more, and closes after the response in stages, as a head past its deadline does. The reason is `body-timeout`, and the 408 is framed for the request in flight: a HEAD's has no Content-Length;
  - `responding` past the write deadline closes at once, with no response: the client is not reading, so nothing more can be written to it. The close is logged, `(log write-timeout bytes)` with the bytes still outstanding, since nothing else would show it. It is `write-timeout`, whatever the connection would have closed for after its response. The write it cuts short is settled in `closing`, as a read error's is (M3.3's W5), and as the libuv shell reports a write its close cancels;
  - `draining`, entered from idle, carries the idle deadline, and past it closes as idle does: it had nothing in flight. It is the one draining row before M8, whose rows arm the write deadline there;
  - a tick clears the kind the state records, then acts: the wheel ticks a connection only as it lets its deadline go. So the record agrees with the wheel even where no row acts on the kind;
  - every close, and the hand-off, emits `(disarm-deadline)` first, armed or not (plan §14's note). The core cleared its record of the deadline there without saying so, which would leave a connection gone from the core in the shell's wheel until its deadline passed. Unconditional, as the core's other disarms are: a disarm with nothing armed is nothing to the wheel;
  - the comments: `on-tick`'s rows, `close`, the hand-off, and the header's deadline paragraph.
- `(http-server decisions)`: `body-timeout`, 408.
- `tests/test-connection-table.sps`, 119 checks (main's 106):
  - D1 to D4, the tick rows: the body's 408, a POST's and a HEAD's; the write deadline's logged close, and a 408 whose write stalls, which closes for `write-timeout`; draining's idle deadline; and a tick no row acts on, which leaves no deadline recorded. Each with its guard, and each outcome ends with the deadline recorded after;
  - T1, T2, T5, T7, L2, L3 and the fake shell's idle close now disarm first;
  - "after every row, the state records the deadline its actions leave armed", starting from nothing at a tick, since the wheel has let the deadline go. It would have caught the missing disarm, thirteen strays, and the stale record after a tick no row acted on;
  - "each deadline a row leaves armed, ticked in the state it leaves, moves the connection on": the slice's title as a check, over every (state, kind) a row leaves a connection in, armed there or carried in. It found draining's carried idle deadline, and a future row that leaves a kind where no tick row acts on it goes red (O);
  - each group's rows now run before its count is checked, and a raise while building them prints its cause (found on the way, below).
- `tests/test-connection-deadlines.sps`, new, 6 checks: each of the five kinds reached on a fake connection as a client reaches it, the kind read, then passed at its own limit, decision 0005's default, which the row states. Idle after a response closes; a head or a body left unfinished gets 408, then the staged close; a response the client never reads, its completion never delivered, is logged with its 77 bytes and closed, and the write settles; a linger closes. And a row for each kind.
- `tests/test-connection-originated.sps`, 21 checks (main's 20): the body's 408 end to end, read back by chez-httparse; every row's staged close ends with the disarm.
- `tests/test-connection-linger.sps` (9) and `tests/test-decisions.sps` (52): the closes' disarm; `body-timeout`'s 408, and `write-timeout` among the reasons with no status.
- `tests/read-back.sls`: `shown`, a write as its status, shared by the response, linger, originated and deadlines suites, where three copies were.
- Records:
  - design §4.4's amendment of 2026-09-27;
  - plan §14's notes for M6.2, M6.3 and M6.4 (below);
  - docs: responses.org's 408 row gains the body, and connections.org gains "Clients that stall", marked from M5, with the Expect case.

Reviewed (`/code-review high`, 2026-09-27, before the first commit): eight findings, all taken on the owner's "fix all eight":
- **A tick left a stale record.** A tick no row acted on kept the kind it found, though the wheel had let it go. Draining kept idle's. Now every tick clears it (D4, X).
- **The moves-on check read only arms,** so it missed the idle deadline T8 carries into draining. It now reads every state a row leaves, and draining got its row (D3, W).
- **Expect: 100-continue.** Until M6.4 the server never sends `100 Continue`, and a client that waits for it is answered 408 once the body deadline passes, though the server is the one waiting. Kept, not changed: without the deadline, a request that expects the 100 and never sends its body would hold its connection with no bound. Plan §14 has M6.4 arm the body deadline when the 100 is written, and connections.org says so.
- **The count guard swallowed a raise's cause.** It now prints the group and the condition. A raise from the core while rows are built still fails the group's count, exit 1, as M5.1's review had setups that raise fail as checks.
- **A write-timeout close was invisible.** It is now logged with the bytes outstanding. An idle close stays unlogged, as a client's own close is: a keep-alive connection going idle is the normal case.
- **D1 could not tell its request's framing.** A HEAD instance now shows it (Y).
- **The deadlines suite's clock was inert.** Each row now states the instant its deadline passed (Z).
- **`shown` was in three copies.** It is now one, in `(read-back)`.

Watched to fail (m5-mutations.md, M5.2): twenty-six mutants, A to AA, each against all thirty-seven suites of the finished tree. M5.2-A, the plan's, turns the write rows red: D2 in the table, the moves-on check, and the end-to-end write row. Every check the slice added or changed is reddened by one at least.

Found on the way: SRFI-64's simple runner names a failing check after the last check run inside its expression (scratch `nested-label.sps`, measured). Six of the table's count checks ran their rows inside themselves, so a count that fell failed under a row's name. Each group's rows now run first. No earlier mutation log misnames one.

Notes for M6 (plan §14):
- The body deadline's 408 assumes the client is the one stalling and no handler has answered.
- In M6.2, while reading is stopped for a handler's credit, the body deadline must not run.
- In M6.3, once a handler's head is on the wire, a stalled body gets a bare close.
- In M6.4, the body deadline of a request that expects the 100 starts when the 100 is written.

`make test` green on the finished tree: thirty-seven suites, 938 expected passes (connection-table 119, connection-deadlines 6, connection-originated 21), exit 0. `make check-imports` is clean. The allocation gate's GET is 1,840 B a request, as on main: a keep-alive request never closes. Size: 449 inserted lines of code and tests, past plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-27), by form: one PR. The disarm, the tick's clearing and the tick rows share the table suite's rows and derived checks. Weighed: two stacked PRs by layer, each proved green on its own tree.

NEXT: the PR, feat/m5.2-tick-rows. Then M5.3, one timer per loop in both shells.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.2, as one PR.**
- **#60** as 9edbe49. Its squash tree (e467aa5) is identical to the tested tip's, 3f67729, and its parent is 2dbef93.
- **CI.** The one run, 36344049731, was the billing block: the `linux` job with 0 steps, "The job was not started because recent account payments have failed or your spending limit needs to be increased."
- **Branches.** feat/m5.2-tick-rows deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 938 expected passes.

M5.2 DONE and merged (9edbe49, PR #60): every deadline the core arms has its tick row.
- a stalled body is answered 408, a stalled write closes with a log line, and a connection draining from idle closes past its idle deadline;
- a tick clears the deadline the state records, and every close and the hand-off disarm first, so the core and the wheel agree on every row, which the table checks;
- plan §14 carries notes for M6.2, M6.3 and M6.4, the Expect case among them.

NEXT: M5.3, one timer per loop in both shells (plan §14, and its notes of 2026-09-27). It starts on a fresh branch cut from main after this commit, when the owner asks.

M5.3 — ONE TIMER PER LOOP, IN BOTH SHELLS. Three stacked branches: feat/m5.3-fake-wheel, cut from main at 6fe18eb; feat/m5.3-shell-timer, cut from it; feat/m5.3-contract-deadlines, cut from that. 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

Gathered: plan §14's M5.3 and its notes of 2026-09-27; decision 0005 and its two amendments of that day; design §2's wheel note, §4.6's server events, and §8.4 and §8.5.

- `(http-server private shell)`, as it stands after the review below:
  - **the wheel.** One per shell, and one entry per connection, made as it is adopted. `arm-deadline` arms the entry at the loop's now, `uv_now`, plus the kind's limit (`limits-deadline-ms`), and `disarm-deadline` takes it out. No action arms a connection's first deadline, its idle one, so the shell arms it at adoption. A connection already closing is armed no more;
  - **the timer**, as 0005 has it:
    - one per shell, made at the first arm and firing every tick-ms;
    - stopped by the first firing that finds the wheel empty, so an idle server sleeps, and started again by the next arm (`uv-timer-again!`);
    - kept between busy periods, and closed once the shell has stopped listening and has no connection left.
    Each firing advances the wheel to the loop's now and ticks each connection whose deadline passed, each under its own guard, since the wheel has let them all go. It then tells the server the time, design §4.6's `(tick now)`, which asks for nothing yet. Once every tick is delivered, the first raise goes on and the run loop logs it. A later byte-machine contract condition goes on in its place, since the run loop keeps that one fatal;
  - **the loop's clock.** It is brought up to date as each handler returns: libuv reads `uv_now` once a turn, and a handler holds the loop. This is a workaround carried until chez-libuv #28 lands (decision 0008), and it calls `uv_update_time` through chez-libuv's private loop pointer;
  - **leaving the wheel.** handle-close! and the reconciliation take a connection out of the wheel: the two ways a connection leaves the table with no step of the core;
  - `shell-timer`, `shell-deadlines` and `connection-deadline`, which the socket lane reads.
- `tests/fake-shell.sls`: a fake connection keeps its deadline in a wheel of its own.
  - It arms at the fake clock's now plus the kind's limit, the idle deadline as it is made, at an instant its caller may give (a fourth argument).
  - `fake-shell-fire!` is its timer firing at the clock's now, and ticks the connection only once its deadline has passed. `fake-shell-tick!` delivers the raw `(tick now)` to any step, as before M5.3, and firing a stub step's shell is refused.
  - The linger, originated and deadlines suites, and the contract's replay, fire.
- `tests/test-connection-deadlines.sps`, 8 checks (main's 6):
  - every row's connection is made at 1,000 ms, not 0, so a deadline armed at its limit alone shows;
  - a firing a millisecond before the deadline asks for nothing;
  - a client that sends nothing is closed at the idle deadline its connection was made with;
  - a connection its client closed is ticked no more.
- `tests/test-fake-shell.sps`, 20 checks (main's 19): firing a stub step's shell is refused.
- `tests/test-shell.sps`, 79 checks (main's 65). The deadline clients run on a shell of their own with short limits (head 200 ms, idle 250, linger 300, tick 10), adopted through the suite's listener:
  - one that sends half a head reads 408, then the stream's end, and is closed once its linger passes;
  - an idle keep-alive connection is closed;
  - a lingering client that never closes is closed;
  - one that connects and sends nothing is closed at the idle deadline armed as it was adopted;
  - each deadline is met at the first time the timer fired at or after it: the instant it was armed, read where it was armed, plus the suite's limit. The firings are the server's ticks in the trace, and one must come at the tick's own instant;
  - after a handler that holds the loop 300 ms, past the idle limit, the deadline armed after its answer is still ahead;
  - a connection closed from outside the core just as a deadline is armed leaves with none armed;
  - with its wheel empty, the timer stops, firing at most once more in fifty turns of the loop, and the shell keeps it;
  - two connections adopted in one callback share a deadline, and the kept timer, started again, ticks both at one firing. Both ticks raise, the second with byte-machine's contract condition. Each is still ticked and closed, and the contract condition is the raise the run loop raises again;
  - four connections that send nothing, on a shell under 0005's limits, add one timer to the loop, repeating every tick, and chez-libuv counts one more;
  - a failed adoption leaves no deadline armed; the reconciliation takes the connection it drops out of the wheel;
  - a shell shut down with no connection left closes the timer it kept: `bad`'s, `quick`'s and the suite's own before the end's checks.
- `tests/test-contract.sps`, 35 checks (main's 28): two scripts whose deadlines pass on a shell with short limits:
  - a head never finished: 408, then the linger;
  - a client that sends nothing: the idle deadline armed at adoption.

  Each event is replayed with the loop's time it came at. The fake is made at the adoption instant, or at 0 when nothing was adopted (a check), and a tick is the fake's own timer firing then. The libuv shell's wall clock here is the loop's own, so both shells make each Date and arm each deadline at the same instant (ONE CLOCK).
- `tests/test-clients.sps`, 11 checks as before: an idle server holds the listener and the timer it keeps.
- Records:
  - design §2's, §8.4's and §8.5's notes;
  - plan §14's notes for M6.2 and M8, and the M5 exit's docs item marked done;
  - decision 0008's chez-libuv #28 row;
  - docs: the "from M5" notes gone from README, connections.org, responses.org and configuration.org, and the timeouts said to be acted on.

MEASURED (scratch spikes, two runs or more each, Darwin arm64):
- `arm-alloc.sps`, cumulative `sstats-bytes`: a disarm then an arm made as the shell makes them, `uv_now` plus the kind's limit into `wheel-arm!`, allocates nothing beyond the measuring loop's own. That is 160 B over a million calls, as an empty thunk and `uv-now` alone read;
- `stale/update-cost.sps`: `uv_update_time` through the private loop pointer, 14 to 15 ns a call and 0 B, over a million calls; `uv-now` 7 to 8 ns;
- `stale/stale-now2.sps` and `stale-now3.sps`, a handler that holds the loop 300 ms, before the refresh and after it:
  - a keep-alive connection with a 250 ms idle timeout was gone within 100 ms of its answer, and stayed idle with the refresh;
  - a 512 KiB answer under a 200 ms write timeout was cut off at 327,212 bytes, logged `write-timeout`, three runs of three, and arrived whole, 524,368 bytes, with the refresh;
  - a 4 MiB answer outlasted the 200 ms write timeout either way, so it showed nothing;
  - the first spike, a 77-byte answer, showed nothing either way. libuv 1.52 runs its timers at the end of a turn, after the poll's callbacks, so a write that completes at once replaces the stale deadline before any timer reads it.

Watched to fail, the first round (m5-mutations.md, M5.3):
- red before green, the tests edited and the shells as on main: connection-deadlines 6 (every early tick acted), shell 10, contract 1;
- then twenty-seven mutants, A to Z and Z2, each against all thirty-seven suites. M5.3-A, the plan's, a timer per armed deadline, turns the one-timer check red, and chez-libuv's count with it. Every check the slice added or changed is reddened by one at least;
- two survive, each a scope statement:
  - E, the libuv shell's disarm performed as nothing. Every v1 disarm is followed by an arm or a close, which disarms too, and M6.2's credit wait is its first check;
  - Y, the replay's fake made at 0. The replay ticks the fake only where the libuv shell ticked, and the deadlines suite holds the fake's start instant (T).

Found on the way:
- the guard check's first run failed on the test's own argument order: `(first-logged)` was evaluated before the run that makes it, as M5.2's `ticked` did (spike-harness pitfalls). It binds the run first now;
- mapping each check to a mutant before the run found four checks that could not fail, and each was strengthened then:
  - the on-time check was vacuous without the server's tick;
  - the short limits were equal;
  - nothing showed a connection leaving the wheel with no step of the core;
  - a closed fake connection's tick asked for nothing (m5-mutations.md).

Timing, not a stopwatch: the lane's deadlines pass in the loop's own time. A check that a tick came within tick-ms of its deadline would fail whenever the loop ran late, which libuv's repeating timer allows, since each firing re-arms from the loop's time then. So the check reads the trace instead: a deadline is met at the first time the timer fired at or after it, and the timer's repeat is tick-ms. The socket lane and the contract ran twenty-four times, eight at a time, all green: before the review and again after it.

Reviewed (`/code-review high`, 2026-09-27, before the first commit): ten findings, all fixed on the owner's "fix all ten". Finding 3 was settled by form: a carried workaround and an upstream ask, chez-libuv #28.
1. **The contract replay crashed when a client never connected.** It made the fake at the adoption time, which stays #f then. The fake is now made at 0 when nothing was adopted, and a check replays with nothing adopted. A scratch copy that plays a script to a port where nothing listens ended as a harness error, exit 2, before the fix. After it, the script fails by name, with ECONNREFUSED, exit 1.
2. **`arm!` could arm a connection already closing.** It now skips one, as `read-start!` does. A check closes a connection from outside the core just as its idle deadline is armed, through the trace's `closing-at`. The connection leaves the table with none armed. Before the fix it left armed: `(satisfied 2361711061 1)`.
3. **Deadlines were armed from a stale `uv_now` after a slow handler.**
   - Measured first. A handler that held the loop 300 ms had its 512 KiB answer cut off at 327,212 bytes under a 200 ms write timeout, three runs of three. It also closed a keep-alive connection with a 250 ms idle timeout at once.
   - DECIDED on the owner's word, by form: the shell calls libuv's `uv_update_time` after each handler, through chez-libuv's private loop pointer, 14 to 15 ns and 0 B a call. chez-libuv #28 asks for `uv-update-time!`, and decision 0008's table carries the row.
   - The socket lane's `/slow` check. Before the fix, the connection was already closed when its client had the answer.
4. **`tick!` kept only the first raise.** A later byte-machine contract condition now goes on in its place, since the run loop keeps that one fatal. The pair check raises from both ticks, the second with the contract condition.
5. **The one-timer check raced the 200 ms head deadline.** It now counts the timers four connections add, on a shell under 0005's limits, where no deadline can pass while the suite looks.
6. and 7. **The timer's lifetime** now follows 0005 to the letter:
   - made at the first arm;
   - stopped by the first firing that finds the wheel empty, and started again by the next arm (`uv-timer-again!`);
   - kept between busy periods, and closed once the shell has stopped listening and has no connection left.
   The checks: the timer stops (at most one firing in fifty turns of the loop) and is kept (the same handle); the pair's deadlines start it again; and a shell shut down with no connection left closes it (`bad`'s, `quick`'s and the suite's own). test-clients now finds the listener and the shell's timer on an idle server.
8. **Pairing could leave a held handle.** It is closed once the pairing wait ends without its pair.
9. **Docs.** The "from M5" notes are gone from README, connections.org, responses.org and configuration.org, so the M5 exit's docs item is done.
10. **`fake-shell-tick!` had two meanings.** `fake-shell-fire!` is now a fake connection's timer, and `fake-shell-tick!` delivers the raw tick to any step. Firing a stub shell is refused, which a check holds.

Watched to fail, after the review (m5-mutations.md, M5.3 after its review): each fix's check was red first, but three, each shown otherwise:
- finding 8's by a scratch copy;
- the stub's refused firing, and the timer's lifetime rewritten with its fix, by the mutants that restore the tree before the review.

Then thirty-five mutants, each against all thirty-seven suites. M5.3-A, the plan's, still turns the one-timer check red. Every check the review added or changed is reddened by one at least, and E and Y survive as before.

`make test` green on the finished tree: thirty-seven suites, 962 expected passes (shell 79, contract 35, fake-shell 20, connection-deadlines 8), exit 0. `make check-imports` is clean. Size: 794 inserted lines of code and tests (206 deleted), past plan §1 rule 1's ~400. Three layers, each meant to be green on its own tree:
- the fake shell's wheel, with its suites, 149;
- the libuv shell's wheel and timer, with the socket lane and the clients, 500;
- the contract's deadline scripts, 145.

DECIDED on the owner's word (2026-09-27), by form: three stacked PRs, each layer proved green on its own tree before it is committed. Weighed: two stacked PRs, both shells then the contract (649 and 145), and one PR (794).
- **feat/m5.3-fake-wheel**, the fake shell's wheel: `tests/fake-shell.sls` and its suites (deadlines, fake-shell, linger, originated), 149 inserted lines;
- **feat/m5.3-shell-timer**, the libuv shell's wheel and timer: `(http-server private shell)`, the socket lane and the clients, 500. With them go the records the code cites: decision 0008's chez-libuv #28 row, the docs, design §2's and §8.5's notes, and plan §14's notes;
- **feat/m5.3-contract-deadlines**, the contract's deadline scripts, 145, with design §8.4's note, this ledger entry and the mutation log.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the M5 exit, whose docs item is done.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.3, as three stacked PRs.**
- **#61, the fake shell's wheel,** as 1e87251. Its squash tree (eae845b) is identical to the tested tip's, 85d8d60, and its parent is 6fe18eb. It merged first and kept its branch, since #62 was based on it.
- **#62, the libuv shell's wheel and timer,** as 593d7bc. It was retargeted to main and rebased from #61's old tip. The rebased tip, 447c37b, has the tested tree (542ea72, 313e14f's), and so does the squash, whose parent is 1e87251. It kept its branch for #63.
- **#63, the contract's deadline scripts,** as 791852f. It was retargeted and rebased from #62's old tip, 313e14f. The rebased tip, 9ce1bf3, and the squash have the tested tree (2fbce0e, e5356d9's), and the squash's parent is 593d7bc.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36350300156 (#61), 36350323606 (#62 as opened), 36350340863 (#63 as opened), 36353017190 (#62 rebased) and 36353077286 (#63 rebased).
- **Branches.** All three deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 962 expected passes.

M5.3 DONE and merged (1e87251, PR #61; 593d7bc, PR #62; 791852f, PR #63): one timer per loop, in both shells.
- The libuv shell keeps its connections' deadlines in one wheel. One timer ticks it: it stops when the wheel empties, and the shell keeps it. The socket lane closes each stalled client at the first firing at or after its deadline.
- The fake shell's timer is the test's, and the contract replays deadlines across both shells.
- The loop's clock is brought up to date as each handler returns, a workaround carried until chez-libuv #28 lands (decision 0008). The pin then moves, and the workaround goes.

NEXT: the M5 exit (plan §14):
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

Its docs item is done. It starts on a fresh branch cut from main after this commit, when the owner asks.

UPSTREAM LANDED (2026-09-27): chez-libuv v0.7.0 is tagged (ed30206, 17:46 -0400; annotated tag 1ff5265). #28, filed that day at M5.3's review on the owner's form, closed via PR #29 (d769da0). PR #30 documents `(libuv async)` and the one-thread-per-loop rule, and the release is PR #31. `uv-update-time! : uv-loop -> unspecified` is on `(libuv loop)`, re-exported from `(libuv)`:
- it refreshes the loop's cached clock, `uv-now`, from libuv's;
- it is legal while the loop runs, and runs nothing, not even a timer already due;
- it is checked for the loop's thread, `&uv-wrong-thread` off it, since it writes the clock the loop thread rewrites each turn (its ADR-0019). `uv-now` stays unchecked.

Between the tags, the library path gains that verb alone: its binding in `(libuv private native)`, the verb in `(libuv loop)`, and their exports, the facade's included. Every other change under `src/` is a comment. The C shim and `tests/uv-testing.sls` are byte-identical, and chez-libuv's own test-loop and test-facade gained checks.

The pin moves from v0.6.0 to the v0.7.0 tag, on a commit of its own (branch chore/chez-libuv-v0.7.0): `vendor/chez-libuv` is at ed30206. Watched to fail:
- with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2);
- with the pin moved and nothing else, the shell no longer loads. The facade now exports `uv-update-time!`, the name of the shell's workaround, and Chez refuses the library: `multiple definitions for uv-update-time! in body`. Five of the 37 suites failed, each because it loads the shell: clients, contract, serve and shell exited 255 on Chez's refusal, and exports, which loads the shell through the facade inside a check, failed that check (exit 1). This is the red decision 0008 asks a carried workaround to turn when its ask lands.

So the pin's commit imports `(except (libuv) uv-update-time!)`, keeping the workaround as it was, and the next commit drops it for the facade's verb. With that one line, `make test` is green at the new pin: thirty-seven suites, 962 expected passes, exit 0.

Smoke evidence (`.plans/research/spike/smoke-libuv-v070.sps`, Darwin arm64, Chez 10.4.1, libuv 1.52.1, on the Makefile's LIBDIRS; exit 0 on both runs, `out/smoke-libuv-v070.run{1,2}.txt`; run 2 in full, and run 1 differs only in CPU times):

    (a) after a 100 ms hold, uv-now had moved (expect 0): 0
        after uv-update-time!, it had moved (expect 100 or more): 100
        a 10 ms timer, due, had run during the call (expect #f): #f | and ran after it (expect #t): #t
    (b) a 150 ms timer armed after the hold, without the refresh, fired after (expect about 50): 51
        with the refresh (expect 149 or more: libuv's clock counts whole ms): 151
    (c) off the loop's thread (expect wrong-thread uv-update-time!): (wrong-thread uv-update-time!)
    (d) eight rounds of a million calls each, the order rotated; ns per call sorted, least, median, and bytes per call:
        uv-update-time! (15 16 16 16 16 16 16 27) least 15 median 16.0 bytes (1.6e-4)
        the workaround  (14 14 14 14 14 14 15 18) least 14 median 14.0 bytes (1.6e-4)
        uv-now          (7 7 7 7 7 7 7 8) least 7 median 7.0 bytes (1.6e-4)
        nothing         (2 2 2 2 2 2 2 2) least 2 median 2.0 bytes (1.6e-4)
    done

Reading:
- (a) and (b) are #28's claim. The refresh moves the clock by the hold and runs nothing, and a 150 ms timer armed after it fires on time, where without it the timer fired 99 ms early.
- (c) is the one behaviour the workaround did not have. The shell calls the verb only from its callbacks, on the loop's thread.
- (d): eight rounds with the order rotated, so each row is measured first in two of them. In both runs the verb's median is 16 ns a call (least 15), 2 ns over the workaround's 14 (least 14). By its source, the difference is its two checks, that the loop is open and that the caller is on its thread. Three rows have one slow result of their eight, 8 to 29 ns in the two runs, which the medians set aside. It allocates nothing: every row, the empty loop's too, reads the same 160 B over a million calls, the measurement's own.

The workaround goes in the commit after the pin's. The shell imports `(libuv)` whole again, and `call-handler!` calls the facade's `uv-update-time!` where it called its own. Its definition is gone, and with it the shell's two reaches past chez-libuv's surface: `foreign-procedure` from `(chezscheme)`, and `loop-pointer` from `(libuv private handles)`. No library under `src/` imports a chez-libuv private library now; two suites still read its dev counters through `(libuv private native)`. Watched to fail: with the refresh removed from `call-handler!`, test-shell failed one check, "after a handler that holds the loop 300 ms, the idle deadline armed after its answer is still ahead when the client has it" (78 passes, 1 failure, exit 1). With the facade's verb it passes, 79. `make test` on the two commits' tree: thirty-seven suites, 962 expected passes, exit 0.

DECIDED on the owner's word (2026-09-27), by form: two stacked PRs, each layer proved green on its own tree before it is committed. Weighed: one PR, 198 lines inserted and 21 deleted, whose squash would fold the pin into the drop; and review first, both left uncommitted.
- **chore/chez-libuv-v0.7.0**, the pin alone: the gitlink, the Makefile's `LIBUV_PIN`, the shell's import leaving out the facade's new name, global-constraints, decision 0008's #28 row and dated note, the research README, test-integration's version comment, the spike and its two runs, and this entry up to its smoke evidence. 199 lines inserted and 11 deleted, besides the gitlink;
- **refactor/uv-update-time**, the workaround dropped, and this entry's rest: 10 inserted, 17 deleted (the form weighed 6 and 17, before this decision's own lines).

Reviewed (`/code-review high`, 2026-09-27, after the PRs opened): six findings, all fixed on the owner's "fix all six".
1. **The clock was refreshed only after a handler** (#65). A deadline armed after any other hold of the loop, the shell's own work, a collection, or the work before an adoption, still started from the turn's cached time. The shell now brings the clock up to date as it adopts a connection, and in `run!` before each arm and each write, ahead of the action's trace. So the trace reads the time the action does, and the deadlines' on-time checks stay exact.
   - Not inside `arm!`, as the finding put it: that refresh would come after the trace, and a response's write runs before its arm, so its Date after a slow handler would read the stale clock.
   - A keep-alive GET's trace shows four arms (header, body, write, idle) and one write: five refreshes, about 80 ns at the spike's 16 ns median, where the handler's refresh was one. Each adoption adds one.
   - Three checks written first: the shell's own work holding the loop before an idle arm, and the work before an adoption, both red on the old tree; and a Date written after a slow handler, green there, since the handler's refresh dated it. Five mutants, each killed (`m5-mutations.md`).
   - The contract's ONE CLOCK note said both shells make each Date and deadline at the same instant, untrue since M5.3's refresh. It now says the libuv shell's are that instant or a moment later: its deadlines never earlier than the fake's, and its Dates the fake's unless a second begins in that moment, a small chance of a mismatch left as it was.
2. **No check held that `src/` imports no chez-libuv private library** (#65): `make check-imports` now refuses one, watched red with the workaround's import put back.
3. **The spike measured the verb first in every round** (#64): part (d) now rotates the order over eight rounds. In both runs the verb's median is 16 ns (least 15) against the workaround's 14, so the 2 ns is the verb's, and the records quote the medians.
4. **The refresh could raise between the handler and its answer** (#65), `&uv-wrong-thread` off the loop's thread, dropping the answer. The refresh has left `call-handler!`: the answer is dispatched first, and the refresh runs with the actions, where every chez-libuv verb the shell calls is checked the same way. The shell's header now says it runs only on the loop's thread (decision 0003).
5. **"The four that load the shell, and exports"** (#64): exports fails because the facade loads the shell, and decision 0008's note, this entry and the PR now say so.
6. **The spike stopped at the first raise** (#64): each part now names how it failed, a raise, a callback that never ran or a thread that never answered, and the program goes on.

`make test` on #64's tree: thirty-seven suites, 962 expected passes, exit 0. On #65's: thirty-seven suites, 965, exit 0.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then the M5 exit, on the merged tree.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **chez-libuv v0.7.0, as two stacked PRs.**
- **#64, the pin,** as 7c4f6d3. Its squash tree (a6c97d2) is the tested tip's, ad36839's, and its parent is 21c1fec. It merged first and kept its branch, since #65 was based on it.
- **#65, the workaround dropped and the clock refreshed wherever it is read,** as 946b500. It was retargeted to main and rebased from #64's tip, ad36839. The rebased tip, be6d372, has the tested tree (5608788, b63d828's), and so does the squash, whose parent is 7c4f6d3.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36354385484 (#64 as opened), 36354393588 (#65 as opened), 36355718381 (#64's review fixes), 36356253988 (#65's review fixes) and 36356693057 (#65 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `fix/contract-write-instants`, the contract's Date comparison in a session of its own, started from #65's tip before the merge, b63d828, and was left alone.

`make test` green on main: thirty-seven suites, 965 expected passes.

DONE and merged (7c4f6d3, PR #64; 946b500, PR #65): chez-libuv is pinned at v0.7.0.
- The shell calls chez-libuv's `uv-update-time!` as it adopts a connection, and before each arm and each write, and its workaround is gone.
- No library under `src/` imports a chez-libuv private library, which `make check-imports` holds.
- All twenty filed asks have landed; nothing is open upstream.

NEXT: the M5 exit (plan §14), on a fresh branch cut from main after this commit, when the owner asks:
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

The contract's exact Date comparison runs in its own session on `fix/contract-write-instants`, which will want rebasing onto main.

THE CONTRACT'S DATES, MADE EXACT. Branch fix/contract-write-instants, cut from #65's tip, b63d828, before #64 and #65 merged, and rebased onto main at 1fc6dc9 once they had. #65's squash, 946b500, has b63d828's tree, so the code under test is the same. 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

The flake. Since #65 the libuv shell brings the loop's clock up to date before each write, and dates the write then. The contract's fake dated its write at the instant of the event the replay last gave it: the loop's time where the trace saw that event. The two differ by the turn's work, tens of microseconds. So the Dates differed, and "the client read the bytes the fake shell wrote" failed, whenever a second began in between. #65's review had left that chance in the ONE CLOCK note.

- `tests/test-contract.sps`:
  - the trace hook records the loop's time at each write the libuv shell's connection runs. The shell calls the hook once the clock is up to date, so the time is the write's own;
  - the replay hands those instants to the fake, in order. The fake's clock, and so its deadlines, stay at the events' instants, never later than the libuv shell's, so the fake still ticks wherever the libuv shell ticked;
  - a script, "two requests in one write, the second answered in the next second". The libuv shells call the handler through `held-handler`, which holds the loop into the next second for `/next-second`: the rest of the second the loop's clock reads, and 5 ms more, by Chez's monotonic clock. The loop's own clock is left alone, so the shell's refresh before the write is the first to read the next second. The fake calls the handler itself, since its clock stands still while the handler runs;
  - the ONE CLOCK note says so.
- `tests/fake-shell.sls`: `fake-shell-date-writes!` dates a connection's next writes at the instants it is given, one each, in order. Once they run out, a write is dated at the clock's now, as every write is when none is given.
- `tests/test-connection-response.sps`: a check that writes given instants are dated at them, in order, then at the clock: RFC 9110's example instant, a second and two seconds on.
- Design §8.4: a dated note. Its M5.3 note said both shells write each Date and arm each deadline at the same instant, untrue since #65.

Weighed: moving the fake's clock to each write's instant, mid-turn, which would make its deadlines the libuv shell's too. The replay would then walk events the fake has already passed, whose instants are earlier, and the fake's clock never runs backwards.

Watched to fail (m5-mutations.md, the contract's Dates):
- red before green: contract 1, three runs of three, the fake dating each write at its clock: `(differs-at 47 49 50)`, the Date's last digit a second behind. That was the script's first form, one request held; the final form's red is dates-A's. And connection-response 1, against a stub that kept the instants and dated each write at the clock;
- then eleven mutants, and three of M4.4's run again, each against all thirty-seven suites. Every check added is reddened by one at least;
- two calibrations survive, as meant. Without the hold, the script cannot tell (dates-I). A hold that refreshed the loop's clock would hide a trace that reads the time before the refresh (dates-J), which only the socket lane's check would then catch.

Measured (this tree, Darwin arm64):
- the contract suite alone, three runs: 2.27, 1.99 and 1.99 s real, 38 passes, where it took 1.49 s before the script, 35. The hold is the rest of a second: half a second on average, a second at most;
- sixteen runs, eight at a time: all green, 38 passes each, 2.85 to 2.97 s real. The eight of a batch finish together, since their holds end at the same second of the loop's clock, the machine's uptime.

`make test` green: thirty-seven suites, 969 expected passes (contract 38, connection-response 24), exit 0. Size: 123 inserted and 43 deleted lines of code and tests, one PR.

DECIDED on the owner's word (2026-09-27), by form:
- **the script stays in the suite**, at half a second a run on average. Weighed: a scratch copy only, as the brief suggested, which would leave dates-A, G and H surviving: the replay could stop handing the fake its instants, or hand them out of order, and nothing would notice;
- **one commit, and a third PR stacked on #65**, based on refactor/uv-update-time. Weighed: the PR once #64 and #65 have merged, rebased onto main; and a review first, left uncommitted. #64 and #65 merged while the form was open (7c4f6d3, 946b500; reflect 1fc6dc9), so the commit sits on main and its PR is based there.

NEXT: the PR, merged on the owner's word. Then the M5 exit (plan §14), as the NEXT above has it.

MERGED to main on 2026-09-27, on the owner's "do closing ritual": **the contract's Dates made exact, as #66,** as c694cc6. Its squash tree (f28cd51) is the tested tip's, 68a1b5c's, and its parent is 1fc6dc9.
- **CI.** Its one run was the billing block, the `linux` job with 0 steps: 36358148109.
- **Main.** The shared checkout held `main`, clean, and was fast-forwarded there (`merge --ff-only`), once after the squash and once after this commit. This worktree was left detached at `main`.
- **Branch.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 969 expected passes.

DONE and merged (c694cc6, PR #66): the contract's fake dates each write at the instant the libuv shell's trace saw it, so the two shells' Dates are compared exactly. A script that holds a request into the next second keeps it so.

NEXT: the M5 exit (plan §14), on a fresh branch cut from main after this commit, when the owner asks:
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

M5 EXIT (plan §14). Branch feat/m5-exit, cut from main at 2f730a1; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m5-mutations.md, "The M5 exit".

Gathered before the first test, from the brief's M5 and plan §14:
- the brief's exit: fake-clock table tests; slow-client socket tests, slowhttptest's shapes, closed within a tick of the deadline; no per-connection timer handle;
- plan §14: the budget spike run again with deadlines armed, so a connection's wheel entry is priced. Its docs item was done in M5.3.

Met before this branch, each with its check:
- fake-clock table tests: `tests/test-connection-table.sps` (each deadline a row leaves armed, ticked in the state it leaves, moves the connection on; each tick row has a test), `tests/test-connection-deadlines.sps` (a row for each kind), `tests/test-wheel.sps` (a deadline of D fires within [D, D + tick-ms], never before) and `tests/test-connection-linger.sps`;
- one timer, none per connection: the socket lane's "four connections open on one shell add one timer to the loop", which M5.3-A reddens, and test-clients' idle server, which holds the listener and that timer;
- slow clients closed within a tick: the socket lane's four M5.3 clients (half a head, an idle keep-alive connection, a lingering client, one that sends nothing), each met at the first firing at or after its deadline.

Missing, of slowhttptest's shapes (its slow headers, slow body and slow read; its range attack does not apply): a head sent a piece at a time, a body sent a piece at a time then stopped, and a client that never reads. The half head is slow headers' simplest form, but no socket check held what 0005 says of the pieces: a head's never move its deadline, armed once at on-message-begin, and a body's each arm it again.

BUILT:
- `tests/test-shell.sps`, 85 checks (main's 82). The deadline shell's limits gain a body, 175 ms, and a write, 225 ms, each its own:
  - slow headers: a client that sends its head in five more pieces, one every 60 ms, reads 408 once the deadline armed as the head began passes, that deadline armed once; then the stream's end, and it is closed once its linger passes;
  - slow body: a client that sends its body a piece at a time, then stops, reads 408 once the deadline armed again at its last piece passes;
  - slow read: a client that never reads a MiB answer is closed once its write's deadline passes, sent less than the whole. The connection's send buffer is made 4,096 B as the listener accepts it; the client's receive buffer is left alone (below);
  - each deadline is met at the first firing at or after it, as the lane's other clients' are. The three run beside M5.3's four, and the suite takes 4.02 to 4.04 s, three runs, against main's 3.84 to 3.87.
- `.plans/research/spike/m5-exit-budget.sps`, `m5-exit-copy.sps` and `m5-exit-rcvbuf.sps`, new, with their runs in `out/`.
- Records: decision 0008's chez-libuv #35 row and note; design §7.3's and §7.5's notes; plan §14's M5 exit and M6 notes; the research README.

MEASURED, the budget with deadlines armed (`out/m5-exit-budget.run{1,2}.txt`): every held connection had its idle deadline armed, and the loop held one timer, with 100 held or 500. The heap per held connection over sixteen readings is 1,569 to 1,746 B, median about 1,640 B, with no trend in the GETs: about 100 B above the M4 exit's median. The parts, made fresh: the core's state 192 B, the adapter's context 32 B, a parser 592 B, chez-libuv's TCP handle 200.8 to 237.2 B, and the wheel entry 48 B. A disarm then an arm, a million times, allocate 160 B, the measuring loop's own. So an idle connection holds about 18.3 KB, 16,384 B of it the read buffer. The server's one timer is a `uv_timer_t` of 152 B.

FOUND, chez-libuv's copies (now chez-libuv #35):
- The slow reader's first form asked for `/big`, 4 MiB, and the slow body check failed on its first run. In a scratch probe of the lane, the loop's timer, due every 10 ms, did not fire for 254 ms after that request, so the slow body client sent none of its pieces in that time, and its body deadline passed first.
- chez-libuv v0.7.0 copies each write's bytes into foreign memory, and each read's out of the read buffer, one byte at a time in Scheme: `copy-in!` and `copy-out` in `(libuv private native)`. `m5-exit-copy.sps` (`out/m5-exit-copy.run{1,2}.txt`) prices them at 16 KiB, 256 KiB, 1 MiB and 4 MiB: `copy-in!` 29.7 to 31.1 ns a byte and `copy-out` 28.4 to 29.7. One `memcpy` through a foreign call costs 0.01 to 0.02 ns a byte into foreign memory, and 0.02 to 0.09 ns out into a fresh bytevector. The 4 MiB answer's work before its write is under way: the body made in 0.4 ms, serialized at once, and its segments copied in 124.6 to 125.0 ms. So a 4 MiB response holds the loop 125 ms in the copy, and a full 16 KiB read 0.47 to 0.48 ms.
- The shell cannot work around it: the copies are private, and `make check-imports` refuses chez-libuv's private libraries in shipped code (#65).
- The slow reader now asks for 1 MiB (`/wide`), whose copy is 31.2 ms, and the three new clients run beside each other.

FOUND, Darwin grows a receive buffer made small after the connect (`m5-exit-rcvbuf.sps`, two runs on each platform). A server writes 512 KiB, then 2 MiB, to a client that never reads, its send buffer made 4,096 B:
- left as the kernel makes it, the client's receive buffer is 408,300 B on Darwin and 131,072 B on Linux, and neither write completes in 2 s;
- made 16,384 B after the connect, it grew to 539,008 B on Darwin, where the 512 KiB write completed after 912 and 915 ms. On Linux it read 32,768 B, and nothing completed;
- made 16,384 B before the connect, it read 326,640 B on Darwin and 32,768 B on Linux, and nothing completed.
So the slow reader leaves the client's buffer alone. The lane's first form made it small after the connect, and under M5X-C its half MiB completed (m5-mutations.md).

On Linux: the socket lane in its final form ran in Docker's `chez-libuv-valgrind:10.4.1` image (Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree with chez-libuv's shim built there: 85 passes, three runs of three, 7.08 to 7.22 s. CI's runs are still the billing block, so this is the new checks' only Linux run.

Watched to fail (m5-mutations.md, "The M5 exit"): six mutants, M5X-A to F, each against all thirty-seven suites and again against the socket lane in its final form, with two calibrations. Every check the exit added or changed is reddened by one at least, and D, E and F redden the socket lane alone.

`make test` green: thirty-seven suites, 972 expected passes (shell 85), exit 0, 20.0 s. Size: 117 inserted and 31 deleted lines of tests, and 272 of spikes: one PR.

DECIDED on the owner's word (2026-09-27), by form, after the measurements:
- **chez-libuv #35, filed from here**: copy writes and reads in bulk. Weighed: recording it for M6, and the owner filing it;
- **M5's close waits for the fix**, as M3's waited for byte-machine #139. This branch merges; the pin moves on a commit of its own when a release carries the fix, and M5 closes then. Weighed: closing M5 now on its own criteria and carrying the copies to M6.

NEXT: the PR, feat/m5-exit, merged on the owner's word. Then chez-libuv #35: when a release carries it, its pin moves on a commit of its own, and M5 closes.

UPSTREAM LANDED (2026-09-28): chez-libuv v0.7.1 is tagged (fe3cc3e, 06:04 -0400; annotated tag c62a9f3). #35, filed the day before at the M5 exit on the owner's form, closed via PR #36 (6e8a829), and the release is PR #38:
- each write's, read's and spawned argument's bytes move with one `memcpy` in the shim, and each handle's and request's block is zeroed with one `memset`;
- no API changes, but the shim gains three exports, `chez_uv_copy_in`, `chez_uv_copy_out` and `chez_uv_zero`. A shim built from older sources fails `(import (libuv))` with `&uv-shim-unavailable`, so `make build` runs again after the upgrade, as its CHANGELOG, README and docs/building.md say (the owner relayed it).

Between the tags, the library path changes in `(libuv private native)` alone, whose export list is unchanged, and gains `(uv-bulk)`, chez-libuv's own test library, which nothing here imports. `tests/uv-testing.sls` is byte-identical.

THE PIN, branch chore/chez-libuv-v0.7.1 on feat/m5-exit; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at fe3cc3e. Watched to fail:
- with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2);
- with the checkout moved and its shim not rebuilt, the socket lane refused to load, `&uv-shim-unavailable` naming `vendor/chez-libuv/build/lib/libchezlibuv.dylib` (exit 255);
- `make build` then put the checkout back at v0.7.0 and rebuilt v0.7.0's shim, since its `submodules` step checks out the commit the superproject's index records. With the gitlink staged, it rebuilt the shim from v0.7.1's sources, which exports the three.

The pin's check, in `tests/test-shell.sps`: the slow reader's MiB write holds the loop less than a tick. The lane reads the loop's time at each write the shell begins, as at each arm, and holds the time from the write's start to the write deadline armed after it under the quick shell's tick, 10 ms:
- at v0.7.0 it failed three runs of three, the write holding the loop 62, 62 and 63 ms (85 passes and 1 failure each). `m5-exit-copy.sps` prices the MiB's copy at 31.2 ms. The rest is the zeroing: v0.7.0's `uv-write*!` allocates the block it copies into with `alloc-zeroed`, which zeroes it a byte at a time (its `stream.sls` and `private/native.sls`);
- at v0.7.1 it passes three runs of three, 86 passes, the write holding the loop 0 ms by the loop's clock each time. The lane took 3.09 to 3.37 s, three runs, where the M5 exit's took 4.02 to 4.04 at v0.7.0.

Smoke evidence: `m5-exit-copy.sps` at the tag, two runs (`out/m5-exit-copy.v071.run{1,2}.txt`), beside v0.7.0's (`out/m5-exit-copy.run{1,2}.txt`):
- at 1 and 4 MiB, `copy-in!` costs 0.02 to 0.03 ns a byte, where it cost 29.72 to 29.78, and `copy-out` 0.02 to 0.1, where it cost 28.46 to 28.59. One `memcpy` there costs 0.02 to 0.03 ns a byte in and 0.02 to 0.09 out: the copies cost what it does;
- at 16 KiB, the shell's read buffer, every copy is at the clock's floor, a microsecond: `copy-out` reads 0.06 ns a byte, where it read 28.44 to 29.54;
- `copy-out` allocates what it did, 16,560 B a call at 16 KiB, at both pins;
- (c), the 4 MiB answer: its segments are copied in 0.108 and 0.12 ms, where they took 124.6 and 125.0, and its body made in 0.433 and 0.446 ms, where it took 0.418 and 0.425.

`make test` green at v0.7.1: thirty-seven suites, 973 expected passes (shell 86), exit 0, 20.1 s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree with the shim built there from v0.7.1's sources, which exports the three:
- `make test`, less its submodule and pin checks: thirty-six suites pass, 962 expected passes. The clients suite cannot start `ab` in that image (status 2);
- the clients suite, in a second container with curl 7.88.1 and ab 2.3 installed: 11 passes;
- the socket lane, three runs: 86 passes each, 5.1 to 6.0 s.

The copy is made with `COPYFILE_DISABLE=1`. macOS's tar otherwise adds `._` AppleDouble files, and five suites (corpus-inventory, exports, libhtp, libhtp-lane and ratchet) failed on them as files of their own. CI's runs are still the billing block.

Records: decision 0008's #35 row, LANDED, and its dated note (all twenty-one filed asks have landed); design §7.3's note; plan §14's M5 and M6 notes; global-constraints; the research README; test-integration's version comment; m5-mutations.md, "chez-libuv v0.7.1, the pin".

The M5 exit's own records are corrected on feat/m5-exit. Plan §14's M5 note now says a 4 MiB response holds the loop 125 ms "in the copy". Its M6 note says the 16 MiB are copied at about 30 ns a byte "as measured up to 4 MiB", where it had carried that rate to half a second, unmeasured.

M5 CLOSES with the pin: its exit is met, and the copies it was held for cost what a `memcpy` does.

DECIDED on the owner's word (2026-09-28), by form: two stacked PRs, each layer proved green on its own tree before it is committed. Weighed: review first, both left uncommitted.
- **feat/m5-exit**, the exit as built and verified at v0.7.0, with plan §14's two notes corrected: 117 inserted and 31 deleted lines of tests, and 272 of spikes;
- **chore/chez-libuv-v0.7.1**, on it: the pin, its check, and M5's close. 121 inserted and 11 deleted besides the gitlink, as the form weighed them, before this decision's own lines.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6 (plan §14), when the owner asks.

MERGED to main on 2026-09-28, on the owner's "do the closing ritual": **the M5 exit and chez-libuv v0.7.1, as two stacked PRs.**
- **#67, the M5 exit,** as fd5c2a0. Its squash tree (cb3e7f4) is the tested tip's, 53bf4d1's, and its parent is 2f730a1. It merged first and kept its branch, since #68 was based on it.
- **#68, the pin and M5's close,** as 06b7946. It was retargeted to main and rebased from #67's tip, 53bf4d1. The rebased tip, 32233bb, has the tested tree (d6e84d1, 4f06027's), and so does the squash, whose parent is fd5c2a0.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36417758819 (#67), 36417783537 (#68 as opened) and 36418170694 (#68 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #68 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: thirty-seven suites, 973 expected passes.

DONE and merged (fd5c2a0, PR #67; 06b7946, PR #68): **M5 COMPLETE.**
- The brief's M5 exit is met: fake-clock table tests; slow clients, slowhttptest's three shapes among them, closed within a tick of their deadlines; one timer per server, none per connection. The budget spike prices a connection's wheel entry at 48 B.
- chez-libuv is pinned at v0.7.1: bytes cross its FFI boundary in bulk, and the socket lane holds a MiB write under a tick.
- All twenty-one filed asks have landed; nothing is open upstream.

NEXT: M6 (plan §14), body streaming and backpressure, on a fresh branch cut from main after this commit, when the owner asks.


