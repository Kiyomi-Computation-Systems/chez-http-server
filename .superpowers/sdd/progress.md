# chez-http-server — subagent-driven development ledger

`progress.md` is the spine; `global-constraints.md` binds every task brief. Read both before starting slice work. Close-outs are recorded here.

---

## Closed milestones

A closed milestone's entries live in its own `mN-progress.md`, beside its `mN-mutations.md`; M-1's are in `m0-progress.md`. They moved there verbatim on 2026-10-05, on the owner's form.

| Milestone | PRs | Closed by | `make test` on main at the close | Archive |
|---|---|---|---|---|
| M-1, planning | #1 | bb81cc1 (#1) | none: no Makefile yet | `m0-progress.md` |
| M0, the skeleton and pure records | #2–#5 | 592c2a0 (#5) | 5 suites, 55 expected passes | `m0-progress.md` |
| M1, the instrument, with no server | #6 | 6b80953 (#6) | 10 suites, 95 | `m1-progress.md` |
| M2, the pure connection core | #7–#30 | ae1ef45 (#30) | 21 suites, 401 | `m2-progress.md` |
| M3, the response path | #31–#45 | 4b65a98 (#45) | 27 suites, 706 | `m3-progress.md` |
| M4, the libuv shell and the first real server | #46–#57 | 21d041f (#57) | 35 suites, 891 | `m4-progress.md` |
| M5, timeouts and limits | #58–#68 | 06b7946 (#68) | 37 suites, 973 | `m5-progress.md` |
| M6, body streaming and backpressure | #69–#94 | d9949f6 (#94) | 44 suites, 1,439 | `m6-progress.md` |
| M7, the scheduler and awaiting handlers | #95–#105 | d3ad473 (#105) | 47 suites, 1,645 | `m7-progress.md` |
| M8, shutdown, hand-off, black-box and release | #106–#117 | fa9e745 (#117), tagged v0.1.0 | 50 suites, 1,882 | `m8-progress.md` |

## Tagged releases

A tagged release's entries, from the tag before it to its own, live in its own `vX.Y.Z-progress.md`: its work, its release, and its merge and tag. They move there verbatim at the next release, on the owner's form of 2026-10-09; v0.2.0's to v0.4.0's moved at v0.4.1's, and v0.4.1's at v0.5.0's. This file keeps the entries since the last release archived.

| Release | PRs | Tagged on | `make test` on main at the tag | Archive |
|---|---|---|---|---|
| v0.2.0 | #118–#130 | 1c86771 (#130) | 51 suites, 1,949 | `v0.2.0-progress.md` |
| v0.3.0 | #131–#133 | 5528fa4 (#133) | 51 suites, 1,957 | `v0.3.0-progress.md` |
| v0.4.0 | #134–#151 | 388ec43 (#151) | 51 suites, 1,983 | `v0.4.0-progress.md` |
| v0.4.1 | #152–#160 | 520f70e (#160) | 51 suites, 1,989 | `v0.4.1-progress.md` |

---

**Plan §14's open list gains what the full drain keeps after a big read, on `docs/open-drain-retention` (2026-10-09),** from chez-websocket#57's review (its decision 0007), by form ("Server plan's open list (Recommended)"; weighed: a server check now, and fixing it in a v0.4.2 before chez-websocket pins). Docs only; nothing under `src/` or `tests/` moved.
- **What.** Measured through chez-websocket's socket suite on v0.4.1 (Darwin arm64): after a 4,000-byte message the heap stays 2,832 to 2,952 B above the heap after a 1-byte one, whatever the message's size, and 9,344 to 9,360 B with ten connections, about 620 B a connection more than v0.4.0. With the drain alone one-shot again it is 0 to 200 B. Not explained, and nothing here bounds it.
- **Where.** The plan's "Open, and not sliced" list, dated, with the measures and the two ways to settle it. chez-websocket's S-LETGO now allows up to 8,004 B at 16,000 bytes (its 0007).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,989 expected passes, every pin ok. Nothing tested changed: the plan and the ledger only.

NEXT: in chez-websocket, #57 and its review's stacked PR, then the pin to v0.4.1 alone, then M5. Here, plan §14's open list holds three items.

MERGED to main on 2026-10-09, on the owner's "all green, do closing ritual": **plan §14's open list gains what the full drain keeps, #161** (the entry above). 6252524 was squashed as aa7dc93 (tree the tested head's, parent 440051c).
- **CI.** Its run, 38005726235, passed on 6252524: fifty-one suites, 1,989 expected passes on ubuntu-24.04. Main's run on the squash, 38006078331, passed with the same counts.
- **Branches.** `--delete-branch` deleted the remote branch; the local one was deleted by hand once main was fast-forwarded. No PR is open.
- **Alongside**, in chez-websocket: #57 and its review #58, the v0.4.1 fit, merged the same hour (its ledger).

`make test` green on main: fifty-one suites, 1,989 expected passes, every pin ok.

NEXT: in chez-websocket, the pin to v0.4.1 (520f70e) alone, then M5. Here, plan §14's open list holds three items.

**The held shutdown's check timed by the loop's clock, on `test/held-shutdown-loop-clock` (2026-10-10),** from chez-websocket#66, whose record (`.plans/research/2026-10-10-s-silent-clock.md`, after its CI run 38051169931) named this check as carrying S-SILENT's hazard. Cut from 6191d47. Tests only: nothing under `src/` moved.
- **The hazard.** The shell suite's "a shutdown asked once the loop has been held 300 ms dates its drain after the hold" read `before` on the loop's clock, held the loop 300 ms of Chez's monotonic clock (`hold!`), and took the drain's date at `before + 299` or later, saying the two clocks "may round apart by one". Chez's clock is CLOCK_MONOTONIC. libuv's loop clock is `uv__hrtime(UV_CLOCK_FAST)`, which on Linux is CLOCK_MONOTONIC_COARSE wherever it ticks every millisecond or finer: in the noble image, and by that record's inference on CI. How far it trails CLOCK_MONOTONIC changes, so one millisecond was not a derived bound.
- **Measured first,** by a probe repeating the check with the real shell (`.plans/research/spike/held-shutdown-clock.sps`; the table is in m8-mutations.md):
  - four processes at once in the noble image, the drain was dated under the bound in 53 rounds of 1,200, as low as 269 ms;
  - alone there, never in 300, and on Darwin never in 500, but at the bound itself, 299, in 285 and 437 of them;
  - timed by a second loop's clock, never under 300 in 2,000 rounds on either.
- **Changed.** `hold-until!` keeps the thread busy until libuv's loop clock, read on a loop made for the hold (`call-with-uv-loop`) and brought up to date each turn, reads `before + 300`. Every loop in a process reads one clock, which never steps back (libuv 1.52.1's `uv__hrtime`: Linux's one fast clock id a process, Darwin's `mach_continuous_time`, Windows' performance counter). So the shutdown, dated by the suite's loop brought up to date after the hold, reads `before + 300` or later, and the check's bound is `slow-ms`, exact.
- **Why a loop of its own.** The suite's loop keeps its time from before the hold, so a shutdown dated without bringing it up to date (M8H-9) reads `before`: 0 ms on, red. Spun on the suite's loop, the hold would leave that loop's time at its end, and M8H-9 would pass (HS-SAME+M8H-9, green).
- **Not changed.** The suite's other 300 ms holds stay on Chez's clock: none of their checks can fail by it. The Date check needs 200 of the loop's milliseconds from the hold. The three idle-deadline checks compare a deadline with the loop's own time; only their mutants' kills need the hold to run past 250 of the loop's, and the probe's least was 269.
- **Mutants:** four rows over every suite, 0 mismatches (m8-mutations.md). M8H-9, re-cut, reddens the check alone. HS-SAME+M8H-9 survives, a scope statement. On Linux, each three times on the shell suite, the same.
- **Soak.** Two rounds of eight containers at once in the noble image, four on main's tree and four on this one, the shell suite 25 times in each: 200 runs a tree. This check went red once on main's tree, `(#f stopped)`, and never on this one.
  - Three other shell checks went red under that load, on both trees or this one, none of them changed here:
    - "a connection held in its handler, nothing armed, the timer stopped, is closed at the drain's deadline, on time", three times on each tree. Each time, its wait for the timer's next firing ran out of iterations (`iterations-exhausted`). #139's run saw it once, under load.
    - "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 18 ms or more by the monotonic clock; …", twice on this tree, never on main's. Its sleep is armed on the loop's clock and measured on Chez's, its comment allowing the loop's clock to trail by one millisecond: this hazard again. It runs before the changed check, and nothing it runs calls `hold-until!`.
    - "a taker's deadline, armed with the timer stopped, passes the first time the timer fires at or after it, once", once on this tree. Its values were not kept in that round. Read, not measured: it takes `armed` from the loop's time before the taker's arm brings it up to date.
  - The new hold's loop is torn down before the shutdown is asked, and the suite's last counter check still counts one loop.
- **Records.** This entry, the mutation log's section and the probe. No CHANGELOG entry: nothing an embedder meets changed.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,989 expected passes, every pin ok; the shell suite's 204, as before. In the noble image (aarch64, libuv 1.48.0), every suite once: fifty green, 1,951 expected passes; the clients suite stops at its first tool, `ab`, which the image lacks, as on main's tree.

NEXT: this PR, then the closing ritual when the owner asks. Here, plan §14's open list holds three items. In chez-websocket, the v0.4.1 pin (#59), M5 (#60 to #65) and #66 are merged.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **the held shutdown's check timed by the loop's clock, #162** (the entry above). 3896f38 was squashed as 9b1b5f8 (tree 10f6b1c, the tested head's; parent 6191d47).
- **CI.** Actions is billing-blocked. The PR's run, 38103643691, and main's on the squash, 38138878516, each ended with its `linux` job not started: 0 steps, and the annotation "The job was not started because recent account payments have failed or your spending limit needs to be increased". The local runs in the entry above stood in for it, as the PR body said, and it merged past the red check on the owner's word.
- **Branches.** Deleted on the remote and here. The shared checkout, clean on `main`, was fast-forwarded.
- **Follow-ups**, each in a session of its own: the 20 ms sleep check timed by the loop's clock; the drain-deadline and taker-deadline checks red under load. Another session's #163, `test/taker-arm-refreshes-clock` (chez-websocket#66's SC-1), is open. Each appends to this file, so it rebases onto this.

`make test` green on main: fifty-one suites, 1,989 expected passes, every pin ok.

NEXT: the follow-ups' PRs, then the closing ritual for each when the owner asks. When Actions returns, re-run main's latest run once. Here, plan §14's open list holds three items.

**A taker's arm brings the loop's clock up to date, now held by a check, on `test/taker-arm-refreshes-clock` (2026-10-10, rebased 2026-10-11),** from chez-websocket's #66, whose mutant SC-1 (`taker-deadline!` without its `uv-update-time!`) survived every server suite. Cut from 6191d47 and opened as #163; rebased onto 67024b0 once #162 merged, on the owner's word. Tests only: nothing under `src/` moved.
- **The check.** `tests/test-shell.sps` gains "a taker that holds the loop 300 ms as it takes the stream arms its deadline after the hold, at the loop's time brought up to date". Its taker reads the loop's time, holds the loop 300 ms with #162's `hold-until!`, arms a deadline of a minute and reads it back. The check holds that the hold left the loop's time as it was, and that the deadline, less the minute, is at least 300 ms past that time.
- **The rebase.** #163 first held the loop with a helper of its own, `hold-past!`, the same as #162's `hold-until!`; it is gone, and the taker calls `hold-until!`. The test mutants of the hold are cut at the taker's call, so they cannot reach #162's check.
- **Watched to fail** (m8-mutations.md): six rows, each red set and value named and hashed before each run. Run 1 on the first tree: 0 mismatches. On the rebased tree: run 2, one prediction error (the clients suite green, its tools since built); run 3, re-predicted, one red under load on an older drain check, green alone five of five. SC-1 answers `0` where the check wants at least 300, on Darwin and Linux. Main's suite under SC-1 stays green, three runs of three, before and after #162.
- **Measured on the rebased tree.** Darwin arm64: the shell suite 205. Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0): every suite 1,951 passes, the clients suite at status 2 with no tools built. The shell suite ran 100 times there, four containers at a time beside another session's eight, and the new check passed every time; seven runs were red on older checks that run before it (m8-mutations.md). Linux x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`): the shell suite 205, SC-1 red by value, every suite 1,951 passes. On both, the serve suite's SIGINT-after-return check was red: it waits on a child by loop turns, and its suite and `src/` are main's, whose CI passed it on real x86_64.
- **CI** is billing-blocked to month's end; the Linux runs above stand in for its `linux` job.
- **Records.** m8-mutations.md's new section and this entry. No CHANGELOG entry: nothing a client or an embedder meets changed.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,990 expected passes, every pin ok; the clients suite read 5,157 B a GET.

NEXT: #163's closing ritual when the owner asks. chez-websocket's m4-mutations.md still calls SC-1 a scope statement; the server's shell suite now kills it.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **a taker's deadline armed at the loop's time brought up to date, #163** (the entry above). 54c4c91 was squashed as 5f97368 (tree 93aec9e, the tested head's; parent 67024b0).
- **CI.** The PR's run on 54c4c91, 38140550760, ran and passed on ubuntu-24.04: fifty-one suites, 1,990 expected passes, the clients suite 5,144 B a GET, as counted here. The squash's tree is that head's. The block is not over: main's run on the squash, 38140866674, and on 67024b0 before it, 38139099120, each ended with its `linux` job not started (0 steps, the payments annotation), as did the PR's first run, on d85c5cc (38103733108).
- **Branches.** Deleted on the remote and here; this session's worktree was left detached at the squash for this reflect. The shared checkout, clean on `main`, is fast-forwarded after it.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: the follow-ups' PRs (the 20 ms sleep check and the timer's waits under load, each in a session of its own), then the closing ritual for each when the owner asks. When main's runs start again, re-run main's latest run once. Here, plan §14's open list holds three items.

**The 20 ms sleep's check timed by the loop's clock, on `test/sleep-by-loop-clock` (2026-10-11),** from #162's soak, which saw it red twice in 200 runs on that branch's tree and named it as carrying the held shutdown's hazard. Cut from 9b1b5f8, #162's squash, and opened as #166; rebased onto 455a88d once #163 merged, on the owner's "do closing ritual", ahead of #164 (the two touch different parts of the shell suite and both append to the ledgers). Tests only: nothing under `src/` moved.
- **The hazard.** The shell suite's "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 18 ms or more by the monotonic clock; …" armed its sleep on the loop's clock and timed it on Chez's, taking 18,000 µs or more: its comment let the loop's clock "trail the monotonic clock by one". On Linux the loop's clock is CLOCK_MONOTONIC_COARSE (#162's entry), so that bound was not derived.
- **Measured first,** by a probe repeating the handler with the real shell (`.plans/research/spike/sleep-clock.sps`; the tables are in m8-mutations.md):
  - by Chez's clock, on Linux, the sleep fell under 18,000 µs in 5 rounds of 300 alone and 35 of 1,200 four at once, as low as 8,295 µs for a sleep of 24 of the loop's ms. On Darwin it never fell under 19,281 µs;
  - by the loop's clock, read on a loop of its own, it never fell under 20 ms in 5,000 rounds on either.
- **Changed, first.** `loop-ms`, beside `hold-until!`, reads the loop's clock on a loop made for the read (`call-with-uv-loop`, then `uv-update-time!` and `uv-now`). The `/sleep` handler holds until the loop's clock reads 30 ms on (`hold-until!`), reads `before` by `loop-ms`, sleeps 20 ms, and answers `loop-ms` less `before`. The sleep is armed at the loop's time brought up to date, no earlier than `before`, and ends only once a reading brought up to date is 20 ms past it, so the bound, 20, is exact. `monotonic-us`, which nothing else read, is gone.
- **Found: M7T-21's red was not derived.** M7T-21 (the waits' clock read with no update) arms the sleep on the loop's time as the hold left it, 30 ms behind, so the sleep is due at once and lasts only as long as its wake takes. In Linux's fourth run of the shell suite under it, the check passed. With `sleep-witness.sps` the length let M7T-21 pass in 26 rounds of 1,000, 20 of 600 on Linux and 6 of 400 on Darwin, with other sessions' containers running. In 23 of them Chez's clock moved within a millisecond of the loop's or more: real pauses, up to 210 ms. The old check had the same exposure at 18 ms.
- **DECIDED by form** ("Add the witness (Recommended)"; weighed: the length check only, and a bigger margin, a hold of 300 ms and a sleep of 200). Before the sleep, the handler starts a timer on the suite's loop from its cached time, due at `before` plus 19, which reads `shell-waits-timed` as it fires. libuv runs due timers in the order they are due (1.52.1 `src/timer.c`, the same since 1.48.0), and the waits' timer is due at 20 past `before` or later, so the witness reads the sleep: 1. Under M7T-21 the sleep is due first, and the witness reads 0 or has not fired, whatever the wake's latency. As built it read 1 in all 1,000 probe rounds; under M7T-21, in none of 1,000. The check now reads "… sleeps 20 ms or more by the loop's clock, a timer due 19 ms in firing while the sleep is armed; …".
- **Why loops of their own.** Read on the suite's loop, `before` would bring it up to date, and M7T-21 would pass both parts (SL-SAME+M7T-21, green). That is why M7.2 moved this check to Chez's clock; a second loop reads the loop's clock without that.
- **Mutants:** the first run, four rows against the length alone, three runs, matched its red sets (one value missed: M7T-21's 8 where I predicted 0 or 1). The second, eight rows against the witness, 0 mismatches. M7T-21 reddens both parts, `(200 3 not-fired)`; W-PAUSE+M7T-21, a pause in its wake, the witness alone; W-STALE+M7T-21, the witness timed from the cached time, the length alone. SL-SAME+M7T-21 survives, a scope statement. Lone reds in checks this PR does not touch (the serve suite's SIGINT check, a contract script, and twice the MiB write's tick check) were green when run again: load.
- **Soaks,** in the noble image, the shell suite with a `(testing)` that prints a failing check's values:
  - against the length alone, two containers on main's tree and two on this one, 30 runs each (60 a tree), beside another session's eight: this check never went red on either tree. The reds were other checks', on both: the drain's deadline (5 on main's tree, 4 on this one, `iterations-exhausted`), the MiB write's tick (3 and 1), the slow body (1 and 0) and the taker's deadline (1 and 0);
  - against the witness, four containers of 25 runs: stopped partway on the owner's form ("Land two, stop two", relayed by the review session), which lands this fix with no more soaks. Up to the stop this check never went red; the drain's deadline did once.
- **Records.** This entry, the mutation log's section and the two probes. No CHANGELOG entry: nothing an embedder meets changed. No follow-up tasks, on the same form.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,989 expected passes, every pin ok; the shell suite's 204, as before. In the noble image (aarch64, libuv 1.48.0): every suite once on the tree before the witness, fifty green, 1,951 expected passes, the clients suite stopping at its first tool, `ab`, which the image lacks, as on main's tree; and on the tree as committed, the shell suite three times (W-0), 204 each. Since that run, only `tests/test-shell.sps` and the probes changed.
- Rebased onto 455a88d: `make test` green (Darwin arm64), fifty-one suites, 1,990 expected passes, every pin ok; the shell suite's 205, #163's check among them. The change to `tests/` and the probes is the tested one, line for line.

NEXT: #166's closing ritual, on the owner's "do closing ritual". #164 (`test/timer-waits-under-load`) then rebases onto it, its ledger entries after these.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **the 20 ms sleep's check timed by the loop's clock, with a witness, #166** (the entry above), ahead of #164. 0efcb58 was squashed as 906cf76 (tree cdac5e0, the tested head's; parent 455a88d).
- **CI.** The PR's run, 38144086377, and main's run on the squash, 38144150799: the billing block, the `linux` job with 0 steps and the payments annotation. The local runs in the entry stand in.
- **Branches.** The shared checkout held `main`, so the merge ran without `--delete-branch`: the branch was deleted on the remote and here by hand, and the shared checkout's `main` fast-forwarded.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: #164 rebases onto main, its ledger entries after these, then its closing ritual when the owner asks. When main's runs start again, re-run main's latest run once. Here, plan §14's open list holds three items.

**The timer-stop waits read from the trace, and the taker's arm time read after it, on `test/timer-waits-under-load` (2026-10-11),** one of #162's follow-ups: the drain-deadline and taker-deadline checks red under load. Cut from e20d9cb and opened as #164; rebased onto 455a88d once #163 merged, its check joining the suite, and onto 68ce7ad once #166 merged, the 20 ms sleep check's fix. Tests only: nothing under `src/` moved.
- **The hazard.** Two shell checks read `fired`, the count of the shell's firings, once the suite saw what emptied the wheel, then waited for one more firing: "a connection held in its handler, nothing armed, the timer stopped, is closed at the drain's deadline, on time" once the handler waited, and "a taker's deadline, armed with the timer stopped, passes the first time the timer fires at or after it, once" once the stream was handed off. The firing that stops the timer is the first one after the wheel empties. It can come in the turn the suite's wait ends on, before the suite reads `fired`, and then no later firing comes.
- **Measured first,** by a copy of the suite printing, per run, the firings traced since the connection's last disarm when the suite looked, and the wait's turns and loop milliseconds. Eight containers at once in the noble image, 50 runs each, 400 on main's tree (the table is in m8-mutations.md):
  - the held-connection check went red 20 times and the taker check once, with #162's values (`iterations-exhausted` in the third and second places);
  - every red run had its stopping firing before the suite looked, and every such run was red;
  - **what spent the turns:** the suite's own 1 ms ticker. Each red run's one firing came 0 to 51 ms before the wait began and none in it: 4,097 turns over 10.8 to 25.6 s of the loop's clock, 2.6 to 6.3 ms a turn. The green runs' waits took 2 to 7 turns and 3 to 62 ms;
  - the taker's `armed`, read before its arm, trailed the loop's time after the arm by 0 ms in 386 runs, 1 in 12 and 2 in 2. Its "no firing between" leg never went false here.
- **Reproduced on main's tree,** each with its soak values, by a hold of the suite's own (`holding-at`, matched there on the action's verb, and `hold-until!`; m8-mutations.md): LOAD-1, the loop held 300 ms as the held connection's handler is asked for, reddens the held-connection check; LOAD-2, held at the door's hand-off, reddens the taker check; STALE, the taker holding the loop 30 ms by libuv's clock between noting `armed` and arming, reddens the taker check's "no firing between" leg.
- **Changed.**
  - `fired-since-emptied?`: whether the shell's timer has fired since its one connection left the wheel empty, from the trace: a firing traced after the first `disarm-deadline` that followed the connection's last `arm-deadline`. The shell traces a firing after deciding its stop, and an action before performing it. A later disarm leaves the timer stopped, and only an arm starts it, so the first disarm after the last arm is the one that counts. The door's connection disarms again at the hand-off, after the 101's write armed a deadline.
  - Both checks wait for it in place of one more firing. The iteration cap stays.
  - The `/door-timed` taker notes `armed` after its arm: the loop's time as the arm left it, which `taker-deadline!` brought up to date and counts the deadline from. Before the arm it is the time the turn read.
  - The header's oracles name both.
- **Not changed.** No other check waits on a firing count after the suite looks. chez-websocket's SC-1, a taker's arm not bringing the clock up to date, is #163's check's to kill: the taker check reads `armed` as the arm left it either way, so it passes SC-1, as before.
- **Mutants:** thirteen rows, run on each of the branch's three trees, and four on main's, values read from a shadow of `(testing)` (m8-mutations.md). The held-connection check's killers by value are M8H-4 and M8H-2, re-cut; the taker check's are M8DH-8 and M8DC-2, re-cut, and FW-EARLY and FW-LATE, a taker's deadline armed 20 ms early or late, one for each of the legs `armed` feeds. LOAD-1, LOAD-2 and STALE are green on this tree. Left out, the held-connection check's wait lets M8H-4 survive (FW-NP1+M8H-4), and the taker check goes red without its own (FW-NP2). Two predictions missed: FW-NP1+M8H-4's other three shell reds, which follow from the held connection left open, went green with it; and FW-EARLY, four at a time on the second tree, left #163's check green, though alone there it reddened it three times in three (`280`, `280`, `282` where it wants 300), and on the third tree four at a time too (`280`). On Linux (the noble image, the shell suite, each row once, each tree), the same values.
- **Soak of this tree,** as above, 400 runs on each of its three trees. Before the rebases: neither check red; in 8 the held connection's timer had stopped before the suite looked, which main's wait could not outlast, and each wait was met in its first turn; six runs red elsewhere, the 20 ms sleep check 3 times and the MiB write's tick 3. Rebased onto 455a88d: neither check red; in 6 the held connection's timer had stopped before the suite looked, each wait met in its first turn; three runs red elsewhere, the 20 ms sleep check and the MiB write's tick once each, and once "and the connection closes once its client does, before the drain's deadline asks for anything" (`on-time` where it wants `never-forced`), a drain check that runs before both, its code unchanged. On the tree as committed: neither check red; in 11 the held connection's timer had stopped before the suite looked, each wait met in its first turn; one run red elsewhere, the MiB write's tick (`10`), and the 20 ms sleep check, now #166's, never.
- **Records.** This entry and the mutation log's section. No CHANGELOG entry: nothing an embedder meets changed.
- **Found, not fixed** (a chip each): "a MiB answer's write holds the loop less than a tick" went red 4 times on main's tree, and 3, 1 and 1 on this branch's three trees (actual `10`), slowhttptest's slow body once on main's (its `armed >= sent` false), and the drain check above once on 455a88d's tree. The 20 ms sleep check, #162's other follow-up, went red 11 times on main's tree, and 3 and 1 on this branch's first two; #166 fixed it, and on the third it never did.
- `make test` green before the commit (Darwin arm64), on the tree as committed: fifty-one suites, 1,990 expected passes, every pin ok; the shell suite's 205, as on main; the clients suite read 5,155 and 5,154 B a GET over two runs. On 455a88d's tree the same counts, 5,154 and 5,156 B; before the rebases, 1,989 and 204. In the noble image (aarch64, libuv 1.48.0), every suite once on the tree as committed, and on 455a88d's: fifty green, 1,952 expected passes; the clients suite stops at its first tool, `ab`, which the image lacks, as on main's tree.

NEXT: this PR, #164, then the closing ritual when the owner asks. Here, plan §14's open list holds three items.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **the timer-stop waits read from the trace, and the taker's arm time read after it, #164** (the entry above). 3ebc20a was squashed as fd45967 (tree 48f0a64, the tested head's; parent 68ce7ad).
- **CI.** The PR's run, 38145693708, and main's run on the squash, 38145842069: the billing block, the `linux` job with 0 steps and the payments annotation. The local runs in the entry stand in, as the PR body said.
- **The owner's form** ("Land two, stop two", relayed by the review session and confirmed here with "do closing ritual"): #164 lands; no more soaks, and no follow-up tasks from them. Of the chips the entry names, the MiB write's and the slow body's were stopped and archived on that form. A stopping rule for timing checks goes into AGENTS.md through #165.
- **Branches.** The shared checkout held `main`, so the merge ran without `--delete-branch`: the branch was deleted on the remote and here by hand, and this session's worktree was left detached at the squash for this reflect. The shared checkout's `main` is fast-forwarded after it.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: #165 (the stopping rule) rebases onto main, its entries after these, then its closing ritual when the owner asks. When main's runs start again, re-run main's latest run once. Here, plan §14's open list holds three items.

**The timing work cut back, by the owner's form (2026-10-11),** on `docs/timing-stopping-rule`, cut from 455a88d and rebased onto 58f9307. The owner asked for a review of the sessions in flight: several were fixing shell checks that went red only under load, and it looked like diminishing returns. Docs only.
- **In flight at the review.** Four chez-http-server sessions were chasing timing checks, each 700 to 1,000 messages long; a fifth, #163's, had moved on to chez-websocket's lost close (`feat/taker-close-lingers`), product work.
  - #164: the shell's timer-stop waits read the trace. A real race: the firing that stops the timer could come before the suite counts. PR open, finished.
  - The 20 ms sleep check timed by the loop's clock (`test/sleep-by-loop-clock`): mutants run, ledger written, not yet committed.
  - The slow body's 408 check, and a MiB write's hold, both spawned as follow-ups by #164's session from its soaks. Edits under way, nothing measured recorded.
  - It started with #162's soak, which raised the first two as follow-ups; each soak at eight containers on an 8-core VM found another check near its margin.
- **The deciding datum.** CI ran the full suite 214 times from 2026-10-01 20:57Z (after #88) to the 2026-10-10 billing block, with no test failure (and 18 runs cancelled by the concurrency group). Every check those sessions were fixing ran in each. They went red only under synthetic load: in 0.5 to 5% of runs, the most #164's held-connection check, 20 of 400 on main's tree.
- **DECIDED by form:**
  - "Land two, stop two (Recommended)": #164 and the sleep check land, with no more soaks; the slow-body and MiB sessions stop. Weighed: stopping all four, which throws away two finished pieces; letting all four finish.
  - "AGENTS.md, via a PR (Recommended)": the stopping rule binds every session. Weighed: memory only; no rule.
  - Later the same day, on the chez-libuv session's handoff of v0.9.0 (tag on 3c4e7f0): "Bump after #165 lands (Recommended)", one PR, the pin alone. Weighed: bumping now in parallel; staying on v0.8.0.
- **Done.**
  - The slow-body and MiB sessions were stopped and archived. Their background runs were ended: a mutation run, three orphaned serve suites, a container. Their worktrees were discarded and their local branches deleted; neither had been pushed or held a commit.
  - #164's and the sleep session were each told to stop soaking and raise no follow-ups. Each merged on the owner's word in its own session: the sleep check first, as #166 (906cf76, reflect 68ce7ad), then #164 rebased onto it (fd45967, reflect 58f9307).
- **Recorded.**
  - AGENTS.md's testing discipline gains the rule: chase a timing flake only when it fails on CI, or locally with no added load. One seen only under synthetic load gets a line in the plan's open list, not a fix, and a soak raises no follow-up tasks.
  - Plan §14's open list gains the two stopped checks, each with what was known. How often each went red was not recorded.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,990 expected passes, every pin ok. Nothing tested changed: AGENTS.md, the plan and the ledger only.

NEXT: this PR's closing ritual, then the chez-libuv v0.9.0 pin alone. Then the lost close (`feat/taker-close-lingers`). Here, plan §14's open list holds five items.

MERGED to main on 2026-10-11, on the owner's "do closing ritual on #165 once the others land": **the timing work cut back, #165** (the entry above), after #166 and #164. f71c29e was rebased onto 58f9307 as 7b500e7 (the ledger rebuilt as main's text plus this entry), `make test` green on that tree (fifty-one suites, 1,990 expected passes, every pin ok), pushed with the lease, and squashed as 16102ed (tree e5d11b4, the tested head's; parent 58f9307).
- **CI.** Billing-blocked: the PR's run 38146145470 and main's run on the squash 38146175945 each ended with the `linux` job not started, 0 steps, and the payments annotation. Nothing tested changed.
- **Branches.** Deleted on the remote and here. The shared checkout, clean on `main`, was fast-forwarded. No PR is open.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: the chez-libuv v0.9.0 pin alone, by the owner's form. Then the lost close (`feat/taker-close-lingers`). Here, plan §14's open list holds five items.

**THE CHEZ-LIBUV v0.9.0 PIN, on `chore/chez-libuv-v0.9.0` (2026-10-11),** by the owner's form ("Bump after #165 lands (Recommended)"), after the chez-libuv session's handoff of the release. Cut from 9690cca. `vendor/chez-libuv` is at 3c4e7f0.
- **UPSTREAM.** chez-libuv tagged v0.9.0, "headroom" (annotated tag object 7ba5886 on 3c4e7f0, 14 commits past v0.8.0), a minor release. It carries no ask of ours, so decision 0008 is unchanged.
- **Checked against chez-libuv's history between the tags, and against the server:**
  - the facade, `(libuv)`, gains six names and loses none: `&uv-stack-exhausted`, `make-uv-stack-exhausted`, `uv-stack-exhausted?`, `uv-stack-exhausted-who`, `uv-stack-exhausted-headroom` and `uv-stack-exhausted-floor`. No library or suite of ours defines any of them;
  - the shim's C changed (`libuv-shim.c` and `.h`, 60 lines added and 2 removed: two exports, `chez_uv_stack_pointer` and `chez_uv_stack_bottom`), so `make build` rebuilt it;
  - `tests/uv-testing.sls` is byte-identical, and the libuv floor is still 1.48.0;
  - `src/` imports no `(libuv private …)` library (`make check-imports`). Two suites import `live-counts` from `(libuv private native)`, still exported;
  - `call-with-uv-loop` is used in `serve` (serve.sls:75) and in the shell suite's clock helpers. No suite or library reads `&uv-wrong-thread`'s fields.
- **The fix that reaches an embedder, measured** (`.plans/research/spike/serve-raise-through-guard.sps`, Darwin arm64). A malformed setting raised out of `serve` through a `guard` whose clause does not match it:
  - at v0.8.0, it reached the guard outside as `&uv-handle-closed`, with the server's tree and v0.8.0's shim built from an export;
  - at v0.9.0, as `&http-server-config-error`;
  - with no guard between, as `&http-server-config-error` at both.
- **The stack refusal.** `uv-run` raises `&uv-stack-exhausted` with under 128 KiB of C stack left, and a teardown's drain with under 64 KiB. Only a continuation or engine leaving a libuv callback without returning spends that stack. The scheduler refuses waits and drains inside a callback (R1), and no suite raised the refusal.
- **Watched to fail.** With the checkout moved and its gitlink staged, and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). With both moved, it passes.
- `make test` green at v0.8.0 (main, 9690cca) and at v0.9.0 on this branch (Darwin arm64, libuv 1.52.1): fifty-one suites, 1,990 expected passes, every suite's count the same. The clients suite read 5,156 B a GET at v0.8.0 and 5,144 B at v0.9.0, inside #155's spread at v0.8.0 (5,143 to 5,157 B).
- **Linux** (CI is billing-blocked), every suite once at v0.9.0: in `chez-libuv-noble-scratch:10.4.1` (aarch64, libuv 1.48.0), fifty green, 1,952 expected passes. In `chez-websocket-ci-amd64:10.4.1` (x86_64 under emulation, libuv 1.48.0), forty-nine green, 1,951 expected passes. In each the clients suite stops at its first tool, `ab`, which the images lack, as on main.
- **Found under emulation, not the pin's.** In the amd64 image the serve suite's "once serve has returned, a SIGINT ends the process at once" was red in three runs of three, with the same value at v0.9.0 and at v0.8.0: `(satisfied satisfied () (0 sigterm))`, where `(satisfied satisfied ("draining 0" "stopped") (0 sigint))`. The child died of the parent's SIGTERM, with no drain logged.
  - Read, not measured further: `start-server` logs `listening`, and only then does `serve` watch signals (serve.sls:75-80). The parent sends SIGTERM once it reads `listening`, so under emulation the signal lands before the watch, at its default disposition.
  - CI's x86_64 runs passed the check in every run. Natively the gap is too short to hit, so under AGENTS.md's rule this is noted, not fixed. A supervisor that signals as soon as `listening` appears would meet the same gap.
- **Records.** The Makefile's pin, test-integration's version comment, global-constraints (the pin and what v0.9.0 adds), CHANGELOG.md's Unreleased (Changed: the pin; Fixed: the setting's raise), the probe.

NEXT: this PR, then the closing ritual when the owner asks. Then the lost close (`feat/taker-close-lingers`). Here, plan §14's open list holds five items.

MERGED to main on 2026-10-11, on the owner's "do closing ritual on #167": **the chez-libuv v0.9.0 pin, #167** (the entry above). 13b99f8 was squashed as 6afa7ea (tree 57b0dc0, the tested head's; parent 9690cca). Main's gitlink and the Makefile's `LIBUV_PIN` both name 3c4e7f0.
- **CI.** Billing-blocked: the PR's run 38146936058 and main's run on the squash 38147064359 each ended with the `linux` job not started, 0 steps, and the payments annotation. The local runs in the entry above stood in.
- **Branches.** Deleted on the remote and here. The shared checkout, clean on `main`, was fast-forwarded. Its chez-libuv store lacked 3c4e7f0, so v0.9.0 was fetched into it from the sibling checkout, offline, and `make build` checked it out and rebuilt the shim; `make check-pins` reads it ok.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: the lost close (`feat/0026-linger`, another session's). Here, plan §14's open list holds five items. chez-websocket meets v0.9.0 through the server release that carries this pin.

**Plan §14's open list gains the signal gap after `listening`, on `docs/open-sigterm-gap` (2026-10-11),** on the owner's "add the SIGTERM gap to plan §14's open list", after #167. Docs only; nothing under `src/` or `tests/` moved.
- **What.** `start-server` logs `listening` (serve.sls:107) before `serve` watches SIGTERM and SIGINT (serve.sls:78), so a signal between the two ends the process at its default disposition, with no drain. Seen only in the amd64 image under emulation, three runs of three at both chez-libuv pins (#167's entry); CI's native x86_64 runs never failed it.
- **Where.** The plan's "Open, and not sliced" list, dated, with the evidence and the fix that would close it: watching the signals before logging `listening`. Noted, not fixed, as the owner asked.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,990 expected passes, every pin ok. Nothing tested changed: the plan and the ledger only.

NEXT: this PR, then the closing ritual when the owner asks. Then the lost close (`feat/0026-linger`, another session's). Here, plan §14's open list holds six items.

MERGED to main on 2026-10-11, on the owner's "do closing ritual on #168": **plan §14's open list gains the signal gap after `listening`, #168** (the entry above). 0dcd4e4 was squashed as 758be06 (tree 6ba4019, the tested head's; parent 68f29e5).
- **CI.** Billing-blocked: the PR's run 38147512689 and main's run on the squash 38148076851 each ended with the `linux` job not started, 0 steps, and the payments annotation. Nothing tested changed.
- **Branches.** Deleted on the remote and here. The shared checkout, clean on `main`, was fast-forwarded. No PR is open.

`make test` green on main: fifty-one suites, 1,990 expected passes, every pin ok.

NEXT: the lost close (`feat/0026-linger`, another session's). Here, plan §14's open list holds six items.

**Decision 0026, a taken stream's close half-closes and lingers (2026-10-11),** on the owner's "lets start the server slice for the lost close", once #163 had merged. chez-websocket's decision 0008, item 6, asked for it ("Server slice after the lane"). Three stacked branches by form ("Three stacked PRs (Recommended)"), cut from 455a88d and rebased onto f672faf before the PRs: `docs/0026-linger-decision` (the records), `feat/0026-linger` (the code and its checks) and `docs/0026-ledger`.
- **Measured first** (Darwin arm64, and Linux aarch64 in the noble image; the spike `research/spike/taker-close-*`, 100 runs a cell). A taker reads 1 MiB, writes a close frame (1009) and calls `transport-close!`, while its client streams 4 MiB.
  - On main a Node client read the close in 14 of 100 runs (70 EPIPE, 25 ECONNRESET). C clients read it, but 94 and 100 of 100 ended in a reset on Darwin, and 46 and 56 of 100 on Linux.
  - A prototype that reads on, dropping, half-closes once the writes are out and lingers: every cell 100 of 100, clean.
  - python-websockets 17.2 and ws 8.22.0 close a failing connection that way (chez-websocket's research record of 2026-10-09).
- **DECIDED by form**, the recommended of each: `transport-close!` always lingers; its bound is `CHEZ_HTTP_LINGER_TIMEOUT`; the close call runs once the socket has closed; three stacked PRs. Weighed: an opt-in verb, a half-close verb only, the taker's own deadline, a shorter limit of its own, the close call at the half-close, one PR.
- **Built.** The libuv shell's close is staged: `drop-reads!`, `taker-dropped-end!`, `taker-linger!`, the taker's `ended?` and `lingering?`. The fake shell's door does the same, its linger on its clock. Settled by precedent and flagged in the decision:
  - a client that has already ended is closed once the writes are out, with no half-close;
  - a half-close refused at the call closes the stream;
  - from the close on, the taker's read-stop is ignored, and once the stream lingers its deadline too;
  - the drain is unchanged.
- **Tests first,** four stages, each named and hashed before its run (m8-mutations.md): 1,992 and six red by value; 1,995; 1,998; then the check that the linger is armed after a hold, red on main's shell and green: 1,999. Stage 0's in-suite client read the close and then `ECONNRESET`: the lost close, inside the suite.
- **Mutants:** 25 rows, 24 mutants and the baseline.
  - Run 1: 5 mismatches, four of them prediction errors. The fifth was a weak check: F2 read "not closed yet" before the fake's close could show, so it now settles first. late-raises was put back as main's.
  - Run 2: 1 mismatch, load.
  - Every new or changed check has a killer by value. LS-6 is equivalent: libuv reports EOF again.
- **Measured on the finished tree.**
  - The spike, Darwin: Node read the close in 100 of 100 runs, clean, and C in 100 of 100. Linux aarch64: 100 of 100, clean.
  - Linux aarch64: every suite, 1,961 expected passes, the clients suite at status 2 with no tools built. The shell suite ran 100 times, four at once, none red.
  - Linux x86_64 under emulation: 1,960, the serve suite's SIGINT-after-return check red as on main's code there.
- **Rebased onto f672faf** (#164 to #168 and their reflects) before the PRs, the three branches together; #168 is docs only.
  - #164 changed the door-timed check, which this slice changed too; the two merged without a conflict. CHANGELOG.md's Unreleased keeps the v0.9.0 pin's entry first.
  - Re-measured at chez-libuv v0.9.0, the shim rebuilt: `make test` 1,990, 1,999 and 1,999 on the three layers; run 3, the 25 rows and their predictions unchanged, 0 mismatches.
  - Linux aarch64: every suite, 1,961 expected passes; the spike's two cells 100 of 100, clean. Linux x86_64 under emulation: 1,960, the shell suite 210 and the switch suite 38; the serve suite's SIGINT check red, as at main (#167's reading).
- **A correction to #163's record.** It said the serve suite's "once serve has returned, a SIGINT ends the process at once", red under emulation, ran out of loop turns waiting on a slow child. That was a guess. #167 read the cause: the parent's SIGTERM lands before `serve` watches signals (serve.sls:75-80).
- **Records:** decision 0026; 0016's amendment; the design's door note; plan §15; `docs/handlers.org` and `docs/connections.org`; the transport's notes; CHANGELOG.md's Unreleased (Changed).
- `make test` green on each layer before its commit (Darwin arm64), and again on each after the rebase, at v0.9.0: fifty-one suites, and 1,990, 1,999 and 1,999 expected passes; every pin ok.

NEXT: the PRs; review and the closing ritual when the owner asks; then the server's next release, for chez-websocket to pin alone and measure `none` again for 3.4, 4.1.5 and 4.2.5.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **decision 0026, a taken stream's close half-closes and lingers, as three stacked PRs** (the entry above), bottom-up.
- **The squashes.** Each has the tree of its tested head, and sits on the squash below:
  - #169, the records: a767a80 squashed as 227165c, on f672faf;
  - #170, the code and its checks: retargeted to main and rebased from a767a80 onto 227165c, 8661a53 becoming 10cb0d3 (tree cb4a008, unchanged), squashed as a0477fd;
  - #171, the ledger: retargeted and rebased from 8661a53 onto a0477fd, fda2ac6 becoming 96d5d8f (tree 26f7ece, unchanged), squashed as 56e621b.

  Each rebased tree was proved equal to its tested tip's before the push, made with the lease read from `ls-remote`.
- **CI.** Billing-blocked throughout. Each run ended with its `linux` job not started (0 steps, the payments annotation): the PRs' runs 38149047139, 38149071168 and 38149081293, the rebased heads' 38149725830 and 38149786477, and main's on each squash, 38149701029, 38149760883 and 38149825092. The local and Linux runs in the entry above stood in, as the PR bodies said. The stack merged past the red check on the owner's word.
- **Branches.** All three deleted, local and remote. This session's worktree was left detached at 56e621b for this reflect; the shared checkout, clean on `main`, is fast-forwarded after it. No PR of this slice is open.

`make test` green on main: fifty-one suites, 1,999 expected passes, every pin ok.

NEXT: the server's next release, carrying decision 0026 and the chez-libuv v0.9.0 pin, for chez-websocket to pin alone and measure `none` again for 3.4, 4.1.5 and 4.2.5. When main's runs start again, re-run main's latest run once. Here, plan §14's open list holds six items.

**v0.4.1's entries archived, on `docs/ledger-archive-v0.4.1` (2026-10-11),** on the owner's "let's cut the next release", by the rule #159 set: a tagged release's entries move out of this file verbatim at the next release. Cut from 6497ab6; 0.5.0's release stacks on it, as v0.4.1's stacked on #159.
- **Moved.** Lines 36 to 219 at 6497ab6, #152 to #160, went into `v0.4.1-progress.md`, with a six-line header naming them: the chez-libuv v0.8.0 pin, decision 0025 and its review, the archive by release, v0.4.1's release, and its merge and tag. 24,710 B with the header. Both cuts fall on a blank line between entries: the archive ends with the tag's NEXT, and #161's entry, the first after the tag, now opens this file's entries.
- **What stays.** This file keeps:
  - its header, and the milestones' table;
  - the tagged releases' table, with a row for v0.4.1: #152 to #160, tagged on 520f70e (#160), fifty-one suites and 1,989 expected passes, from its merge entry's `make test` on main. The table's note now says v0.4.1's entries moved at v0.5.0's release;
  - the entries since v0.4.1's tag, #161 to #171: lines 220 to 460.

  460 lines and 72,477 B became 277 lines and 48,176 B before this entry.
- **Proved** byte for byte with `cmp`: 6497ab6's lines 1 to 25 and 27 to 32 are this file's; its lines 33 to 35 are this file's 34 to 36; the archive past its header is its lines 36 to 219; and this file's lines from 37 are its lines from 220. The line count is the old one less 184, plus the row. Only line 26 and the row are new.
- **Watched to fail.** Four mutants of the split, each named red and hashed before the run (sha256 1f1d2f5b…), and each red at the segment named; the split itself green:
  - a line of text dropped from the archive: "archive differs";
  - the archive's last line, the blank, dropped: "archive differs";
  - this file's kept part read from one line late: "kept part differs";
  - the new row put after the table's blank line: "33-35 differs".
- **Records.** This entry only. No CHANGELOG entry: the ledger is the project's process, not anything a client or an embedder meets.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,999 expected passes, every pin ok. Nothing tested changed: the ledger only.

NEXT: 0.5.0's release, stacked on this, by the owner's form ("0.5.0 (Recommended)", "Tag on local runs (Recommended)"). Then chez-websocket's pin to it alone, and `none` measured again for 3.4, 4.1.5 and 4.2.5.

**0.5.0's release, on `chore/release-0.5.0` (2026-10-11),** on the owner's "let's cut the next release", after decision 0026's merges: the release chez-websocket's next pin waits for. Stacked on `docs/ledger-archive-v0.4.1`.
- **What it carries.** Every PR since v0.4.1, #161 to #171, was read against CHANGELOG.md's Unreleased.
  - The two an embedder meets are in it: the chez-libuv v0.9.0 pin (#167), under Changed, and under Fixed for the config error's raise; and decision 0026 (#170), under Changed. #170 also changed the test fake's door, which a taker's own tests load (chez-websocket's `test-binding` and `test-driver` do), and had no entry: one is added under Changed. Since v0.4.1 only those two touched `src/`, `docs/`, README.org, the Makefile, `vendor/` or `tests/fake-shell.sls`.
  - The other nine are records or checks only: #161, #162, #163, #164, #165, #166, #168, #169 and #171.
- **Semantic versioning, by form** ("0.5.0 (Recommended)"; weighed: 0.4.2). No export line changed: under `src/` only the shell's body and the transport's notes did, and `CHEZ_HTTP_LINGER_TIMEOUT` was already read, for the server's own closes. But what `transport-close!` does changes as a taker sees it: its close call, and a waiting taker's `&client-closed`, come once the client has closed, up to the linger later, and the stream counts toward `CHEZ_HTTP_MAX_CONNECTIONS` until then. The test fake's door closes the same way: three of this server's own fake checks had to deliver the client's end first. 0.4.1 was a patch because nothing an embedder calls changed, and 0.3.0 a minor for an addition. No decision named this version.
- **The pins.** chez-libuv moved from ad3bb47 (v0.8.0) to 3c4e7f0 (v0.9.0), by #167. The rest are v0.4.1's: chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0 at c338a57), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Built.**
  - CHANGELOG.md: Unreleased moved under `[0.5.0] - 2026-10-11`, with an intro naming the minor, what changes and the pins, and the fake's entry added.
  - A fresh, empty Unreleased above it, and `[0.5.0]` comparing v0.4.1 with v0.5.0.
  - README.org's status names v0.5.0 the current release and what it changes.
- **Not re-measured.** The Changed entry's 14 of 100 and 46 to 56 of 100 are decision 0026's measured cells, so the spike was not run again.
- **CI is billing-blocked.** Main's run on 6497ab6, 38149945307, ended with `linux` not started (0 steps, the payments annotation). By the owner's form ("Tag on local runs (Recommended)"; weighed: waiting for CI), these runs stand in, on this branch's tree before this entry:
  - Darwin arm64, `make test`: fifty-one suites, 1,999 expected passes, every pin ok;
  - Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0), every suite once: fifty green, 1,961 expected passes, each suite's count the 0026 slice's on its rebased tree; the clients suite at status 2 with no tools built, as before;
  - Linux x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`, libuv 1.48.0), every suite once: forty-nine green, 1,960 expected passes, each suite's count the 0026 slice's on its rebased tree; the clients suite at status 2 with no tools built, and the serve suite's "once serve has returned, a SIGINT ends the process at once" red, as at main (#167's reading: the SIGTERM lands before `serve` watches signals; plan §14's open list since #168).
- **The tag.** After the merges, the billing block proved again on main's run on the release's squash, `v0.5.0` goes on that squash, annotated and signed as v0.4.1 was: "chez-http-server v0.5.0 — a taker's close half-closes and lingers", its body pointing at CHANGELOG.md's `[0.5.0]`. Main's run is read once when CI returns. The merges and the tag wait for "do closing ritual".
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,999 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

NEXT: the closing ritual for both PRs, bottom-up, and the tag, when the owner asks. Then, in chez-websocket: the pin to v0.5.0 alone, and `none` measured again for 3.4, 4.1.5 and 4.2.5.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **v0.4.1's entries archived and 0.5.0's release, as two stacked PRs** (the two entries above), bottom-up.
- **#172, v0.4.1's entries archived:** 72be3e6 squashed as 9b8ae31 (tree d7c94e7, the tested head's; parent 6497ab6). It merged without `--delete-branch`, since #173 was based on it.
- **#173, 0.5.0's release:** retargeted to main and rebased from 72be3e6 onto 9b8ae31, f6fa952 becoming 05a0d3a (tree ffb75bb, unchanged), pushed with the lease read from `ls-remote`. It squashed as 02ef95d (tree ffb75bb; parent 9b8ae31).
- **CI.** Billing-blocked throughout. Each run ended with its `linux` job not started (0 steps, the payments annotation): the PRs' 38150851248 (72be3e6) and 38151025131 (f6fa952), the rebased head's 38152994583 (05a0d3a), and main's on each squash, 38152962174 (9b8ae31) and 38153031784 (02ef95d). By the owner's form ("Tag on local runs (Recommended)"), the release entry's local runs stood in: Darwin 1,999 expected passes, Linux aarch64 1,961, and x86_64 under emulation 1,960.
- **TAGGED v0.5.0** on 02ef95d, annotated and signed as v0.4.1 was: "chez-http-server v0.5.0 — a taker's close half-closes and lingers", its body pointing at CHANGELOG.md's `[0.5.0]`. `git verify-tag` read a good signature. `git ls-remote --tags` shows the tag object 38fe965 and its commit 02ef95d. No GitHub Release, as for the earlier tags.
- **Branches.** Both deleted, local and remote. This session's worktree was left detached at 02ef95d for this reflect; the shared checkout, clean on `main`, is fast-forwarded after it. No PR is open.

`make test` green on main: fifty-one suites, 1,999 expected passes, every pin ok.

NEXT: in chez-websocket, its own repository: the pin to v0.5.0 (02ef95d) alone. Its `test-binding` and `test-driver` load this server's fake, whose door's close now lingers. Then `none` measured again for 3.4, 4.1.5 and 4.2.5. Here, v0.5.0's entries move to `v0.5.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds six items.

**The signals watched before `listening`, on `fix/signals-before-listening` (2026-10-11),** on the owner's "let's work on the §14 open list": its first item, noted from #167's run in an amd64 image. Cut from 9ee88b2.
- **What was wrong.** `start-server` logged `listening HOST PORT`, and only once it had returned did `serve` watch SIGTERM and SIGINT. A signal in between met its default disposition: the process ended at once, with no drain and nothing logged. The serve suite's "once serve has returned, a SIGINT ends the process at once" sends SIGTERM as soon as it reads the line, and was red there in three runs of three under x86_64 emulation (#167).
- **The fix.** `start-server` takes an optional `ready`, called with the shell once it listens and before it logs `listening`; `serve` passes `shell-watch-signals!`. Started with four arguments it watches nothing, as before.
- **Three checks,** in the serve suite:
  - the child's: the child, started with `sigterm-at-listening`, sends itself SIGTERM from inside the write of the `listening` line, so the signal lands in the gap on every run;
  - the default's: a four-argument start watches no signal;
  - the order's: `ready` sees the listener open and nothing logged.
- **Test first**, each prediction hashed before its run (m8-mutations.md, its last section). On main's `serve.sls` the child's check went red alone, by value `(satisfied #t () (0 sigterm))`. The first run tested nothing: the child used `parameterize` without importing it from `(chezscheme)`, and did not load.
- **Mutants:** six rows in two runs. Run 1, five rows over every suite: 1 mismatch, a prediction error. SG-3 also reddened the clients suite's "and the listener is the one handle left, beside the timer the shell keeps", a check that already held the default. SG-5, `ready` before the bind, was green and loaded. No check held the docstring's "once it listens", so the order's check was added. Run 2, the six rows on the serve suite: 0 mismatches. Every new check has a killer by value.
- **Measured on Linux,** on the tree before the order's check:
  - aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0): main's `serve.sls` reddened the child's check alone, by the same value;
  - x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`): main's `serve.sls` red in three runs of three, the child's check and the SIGINT one, each at `(0 sigterm)`; the fix green in three of three.
- **On the final tree:** every suite once in each image, the clients suite at status 2 with no tools built, as before, and every other green: aarch64 1,964 expected passes, x86_64 under emulation 1,964 (main's 1,960 there, the SIGINT check green again, and the three). The serve suite 21 in both.
- **Records:** the plan's open list (the item settled, five left); the design's signal note; `docs/connections.org`; CHANGELOG.md's Unreleased (Fixed).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,002 expected passes (main's 1,999 and the three checks), every pin ok.

NEXT: the PR; the closing ritual when the owner asks. Plan §14's open list holds five items: the next are what the full drain keeps after a big read, a door script in the cross-shell contract test, and a taken stream's close bounded from the server's side, which is the owner's to decide; the two load-only timing items stay stopped by the owner's form.

**Decision 0027, a taken stream's close gives each write it waits for the write timeout (2026-10-11),** on the owner's "let's work on the §14 open list": its item "a taken stream's close bounded from the server's side", from 0024's review. Three stacked branches, as 0026's were, cut from `fix/signals-before-listening` (a0cdafa): `docs/0027-close-bound` (the records), `feat/taker-close-write-timeout` (the code and its checks) and `docs/0027-ledger`.
- **Measured first** (Darwin arm64, at a0cdafa). With `CHEZ_HTTP_WRITE_TIMEOUT` and `CHEZ_HTTP_LINGER_TIMEOUT` at 1 s, the client reading nothing:
  - a taker that wrote 32 MiB and called `transport-close!`, arming no deadline, still had its stream in the table after 6.5 s, and had been told nothing;
  - a response of 32 MiB was closed.
- **Peers**, read from source by a Sonnet agent, and every cited line checked against its saved copy:
  - Go clears the deadlines at `Hijack`, Node removes its timeout listener at an upgrade, and hyper's `Upgraded` has no timer;
  - ws and python-websockets, which hold their socket, bound their own close: 30 s from `close()`, and 10 s, then abort.
- **DECIDED by form**, "Write timeout after close (Recommended)". Weighed: leaving it to the taker, M8.2's form; and the linger armed from the close call. Settled by precedent and flagged in the decision:
  - the taker's own deadline runs beside the bound, the earlier first;
  - nothing is logged at the bound;
  - the fake shell is unchanged, since its writes never outlast a turn.
- **Built.** The taker keeps two instants, `due` and `bound`. `taker-arm!` arms the stream's one wheel entry at the earlier of the two. `taker-bound!` arms the bound at the close and again at each write's end, from the loop's time brought up to date. `taker-passed!` aborts once the bound has passed; otherwise it makes the taker's call and arms the rest again.
- **Five checks** in the shell suite, on a 300 ms write timeout: the bound alone; each write; the taker's own deadline earlier, and later; a held loop.
  - Test first: C1 to C4 red by value on #174's shell.
  - C2 was red in two of five runs at first. That was the check: through the 4 KiB send buffer, the client needed more than 150 ms to read the first write, so the server's send buffer now widens to 1 MiB once the client reads. Then 20 of 20 green.
  - C5 was added for the bound's `uv-update-time!`.
  - Eight mutant rows over every suite: 0 mismatches, and every check has a killer by value (m8-mutations.md, its last section).
- **One red not chased.** 0026's linger check, "a client that reads the close and never closes …", went red once in 64 runs of this shell, in a full `make test`; its values were not captured. It was green in the other 63, and in 10 on #174's shell. Other sessions' Chez suites were running on the machine. 0027 leaves that check's path as it was. Noted in plan §14's open list, under AGENTS.md's rule for timing flakes.
- **Measured on Linux,** every suite once: Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0) and x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`), 1,969 expected passes each (#174's 1,964 and the five), the shell suite 215 in both, and the clients suite at status 2 with no tools built, as before.
- **Records:** decision 0027; 0016's amendment; the design's door note; the plan's open list (the item settled, and the linger check's red noted); `docs/handlers.org` and `docs/connections.org`; the transport's notes; CHANGELOG.md's Unreleased (Changed).
- `make test` green before each commit (Darwin arm64): fifty-one suites; 2,002 on the records, 2,007 on the code and on this ledger; every pin ok.

NEXT: the PRs, #174 then these three; the closing ritual when the owner asks, bottom-up. Plan §14's open list then holds five items: what the full drain keeps after a big read, a door script in the cross-shell contract test, the two load-only timing items the owner's form stopped, and the linger check's one red.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **the signals watched before `listening` and decision 0027, as four stacked PRs** (the two entries above), bottom-up.
- **The squashes.** Each has the tree of its tested head, and sits on the squash below:
  - #174, the signals: a0cdafa squashed as 8528ab1, on 9ee88b2. It merged without `--delete-branch`, since #175 was based on it.
  - #175, 0027's records: retargeted to main and rebased from a0cdafa onto 8528ab1, 542e8a1 becoming faec604 (tree f81d1de, unchanged), squashed as c1e024a;
  - #176, the code and its checks: rebased from 542e8a1 onto c1e024a, 882f4d4 becoming 6854bc2 (tree fddff40, unchanged), squashed as bc53039;
  - #177, the ledger: rebased from 882f4d4 onto bc53039, 969851f becoming 94973e0 (tree de58438, unchanged), squashed as 25ad9b7.

  Each rebased tree was proved equal to its tested tip's before the push, made with the lease read from `ls-remote`.
- **CI.** Billing-blocked throughout. Each run ended with its `linux` job not started (0 steps, the payments annotation):
  - the PRs' runs: 38166028144, 38169304601, 38169322629 and 38169332736;
  - the rebased heads': 38169788953, 38169838910 and 38169879635;
  - main's on the squashes: 38169766908, 38169817476 and 38169860536.

  The local and Linux runs in the entries above stood in, as the PR bodies said. The stack merged past the red check on the owner's word.
- **Branches.** All four deleted, local and remote. This session's worktree was left detached at 25ad9b7 for this reflect; the shared checkout, clean on `main`, is fast-forwarded after it. No PR is open.

`make test` green on main: fifty-one suites, 2,007 expected passes, every pin ok.

NEXT: plan §14's open list holds five items: what the full drain keeps after a big read (measure first); a door script in the cross-shell contract test; the two load-only timing items the owner's form stopped; and the linger check's one red. Main's run is read once when CI returns. 0027 and the signal fix are Unreleased, for the server's next release.

**What the full drain keeps after a big read, settled; what a wake gave, let go (2026-10-11),** on the owner's "let's keep working on the §14 open list". One branch, `fix/wake-value-let-go`, cut from main at ab5062c.
- **Measured first** (Darwin arm64, at ab5062c). The full drain keeps nothing after a big read:
  - S-LETGO's shape, through chez-websocket's binding on this server's main: a big message then a small one read 2,888 to 3,064 B apart, and two 1-byte messages 2,872 to 3,088 B, two runs each at 4,000 and 16,000 bytes. The 2.9 KB was the heap falling between the readings.
  - The fall: each wake's full capture uses up the thread's stack segment by the drain's depth, until Chez gives it a fresh one. The scheduler alone, its drain 0, 50 and 200 calls deep: about 248, 648 and 1,848 B a wake, then a rise of 62,504 to 64,240 B every 244, 97 and 34 wakes. With no scheduler, a capture each step, full, one-shot or none, the heap did not fall.
  - Bounded: 400 messages through the libuv shell, each hundred spanning 63,376 to 65,432 B, one segment's band.
  - Ten connections, measured at the review: 9,216 to 9,344 B for a big message then a small one, 8,480 to 9,336 B for two 1-byte ones.
- **What the measuring found instead.** A waiting coroutine kept the last value a wake handed it, until its next wake: a taker whose code resumed its wait with a 4,000-byte read's copy kept about 4,000 B while it waited (a step −1,744 to −2,080 B, against −5,976 to −6,192 B, four runs). A shadow scheduler that clears the field kept none. Peers keep nothing of a value handed to a waiter: Go clears its waiting record's pointer (`chan.go` 339-342 at go1.27.2), and CPython pushes a sent value onto the generator's frame stack (`genobject.c` 244-246 at v3.14.0).
- **DECIDED by form**, "Fix it, settle the item (Recommended)"; weighed: settling the item and noting the value on the open list. And "A docs PR there, after (Recommended)" for chez-websocket's four records of the 2.9 KB.
- **Built.** `resume!` hands the coroutine its wake's value and clears the field. Checking the fix's reach found a second holder: a wait answered while `register` runs kept its value in the cell, which whoever registered keeps with the resume. `wait!` clears it as it answers. **Flagged to the owner**: the form named the drain's holder; this is the same defect in the waits' cell. Each costs nothing: a wake and park allocates 288 B, as before.
- **Three checks, by weak pairs** (five after the review): the scheduler suite's (with its calibration, a value the coroutine keeps is held); the waits suite's (early and parked, the resume kept); the shell suite's (a waiting taker woken with a read's bytes, `/door-woken`).
  - Test first, each prediction hashed: red alone by value on main, `(waiting held held)`, `(satisfied satisfied held)`; the waits suite's on the scheduler's fix, its early value held.
  - Mutants: four rows, three over every suite, 0 mismatches (m8-mutations.md, its last section).
- **The review** (a code review, eight findings, on the owner's "fix all of them"):
  - the ten-connection figure measured (above), and the wake value's steps quoted right;
  - more of the same defect, fixed test first: a coroutine's record let its thunk go once entered, and what it ended with and its end procedure once its end is handed over; a wait's cell lets its coroutine go once the wait is over. Two checks: the scheduler suite's second and the waits suite's second;
  - the shell check reads the suite's own instrument, resets its state and asserts its teardown; the CHANGELOG's and the plan's words.
  - Two prediction errors, each the check's: Chez folded the closures' `bytevector-length`, so they captured nothing (they read a byte now); and the first scheduler check's calibration was held only through the thunk the record kept (it reads its box after the collection now).
  - Ten rows, three over every suite: 0 mismatches. Every new check has a killer by value.
- **Measured on Linux,** every suite once, on the final tree: Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0) and x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`), 1,974 expected passes each (main's 1,969 and the five), the clients suite at status 2 with no tools built, as before. The first tarball carried macOS's AppleDouble `._` files, which doubled every corpus count and reddened six lane suites in both images; made with `COPYFILE_DISABLE=1`, it was the tree.
- **chez-websocket on this branch:** its main (3637f8a), exported, its fifteen suites: 394 expected passes, all green.
- **Records:** the plan's open list (the item settled, with the measures and the fix); the design's §5.2 note; CHANGELOG.md's Unreleased (Fixed).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,012 expected passes (main's 2,007 and the five checks), every pin ok.

NEXT: the PR; the closing ritual when the owner asks; then a docs-only PR in chez-websocket, by the owner's form, for its four records of the 2.9 KB (decision 0007, its research record of 2026-10-09, its design doc, test-socket.sps's oracle note). Plan §14's open list holds four items: a door script in the cross-shell contract test, the two load-only timing items the owner's form stopped, and the linger check's one red.

MERGED to main on 2026-10-11, on the owner's "do closing ritual": **what a wake gave, let go, and the drain item settled**, #178 (the entry above).
- **The squash.** de34c39 squashed as e5be01a, on ab5062c, with `--match-head-commit` on the full SHA. Its tree, e0d78af, is the tested tip's.
- **CI.** Billing-blocked. Each run's `linux` job was not started (0 steps, the payments annotation): the PR's 38174485112, and main's 38174999623 on the squash. The runs in the entry above stood in, as the PR body said. It merged past the red check on the owner's word.
- **Branches.** `fix/wake-value-let-go` deleted on the remote by the merge, and locally once this session's worktree was detached at e5be01a for this reflect. The shared checkout, clean on `main`, is fast-forwarded after it. No PR is open.

`make test` green on main: fifty-one suites, 2,012 expected passes, every pin ok.

NEXT: the docs-only PR in chez-websocket, by the owner's form, for its four records of the 2.9 KB: decision 0007, its research record of 2026-10-09, its design doc, and test-socket.sps's oracle note. Plan §14's open list holds four items: a door script in the cross-shell contract test, the two load-only timing items the owner's form stopped, and the linger check's one red. Main's run is read once when CI returns. The wake-value fix, 0027 and the signal fix are Unreleased, for the server's next release.

**A door script, measured; what a client sends after the 101 waits for the taker (2026-10-11),** on the owner's "let's keep working on the §14 open list". Two stacked branches from main at f357adb: `fix/hand-off-read-stop`, then `test/door-replay` on it.
- **Measured first, by a prototype door replay** (Darwin arm64, at f357adb). It added five trace points in the libuv shell's door, three in the fake's, and ten door scripts in the contract test, and replayed the libuv shell's door events into the fake. The traced events are each read and end, whether to the taker or dropped while its close lingers, each write's completion, and each pass of its wheel entry. 224 checks passed and 9 parted: 6 were one bug, and 3 were the fake.
- **The bug.** After the 101, the libuv shell read on with the core's callbacks until the taker called `transport-read-start!`, and the core, handed off, dropped what it read.
  - A taker that started reading 50 ms after its take-over never got the `hello` its client sent once it had the 101. The handed-off core's trace read `(event (bytes-arrived "hello"))`, then the taker got only the end.
  - A taker that reads in its take-over, as chez-websocket's does, lost nothing.
  - The fake instead called an `on-bytes` not yet given, a taker failure that aborted the stream.
  - Why: 0016's context had what the client sends next waiting in the kernel, by decision 0004's stop at a message's end. Decision 0020 reads on past a request's end, and nothing stopped reading again at the hand-off.
  - Peers keep these bytes: Go's hijack aborts its pending read and hands over what it read (`net/http/server.go` 318-337, go1.27.2). Node sets `readableFlowing = null` before its `upgrade` event (`lib/_http_server.js` 1048-1066, v24.21.0).
  - The fake's three: an abort after a write libuv had already sent at the call is ECANCELED in the fake but `#f` in libuv, and its client read the write; and a write after the close is told ECANCELED at the fake's next completion, where libuv tells it at the next turn.
- **DECIDED by form**, both recommended:
  - "Keep them"; weighed: documenting it.
  - "Land the replay"; weighed: paired checks only, with the item closed as not wanted.
  - Stacked: the fix first, the replay on it.
- **Built (`fix/hand-off-read-stop`).** The core's hand-off row stops reading before the hand-off: `(disarm-deadline) (read-stop) (hand-off ...)`. A read-start the take-over makes stands, and what the client sends next waits in the kernel for the taker, in both shells. Records: decision 0016's amendment, the design's row, `docs/handlers.org`, CHANGELOG.md's Unreleased (Fixed), and plan §14's door item.
- **Checks:**
  - the table's W2 (both instances) and the switch suite's "the core's part" hold the read-stop;
  - new, the switch suite's "a taker that starts reading once its deadline passes reads what the client sent after the 101, none of it read before";
  - new, the shell suite's "a waiting taker that starts reading after a sleep reads what its client sent once it had the 101", through `/door-read-later`.
  - Test first, each prediction hashed: red alone by value on main, `(19 #vu8() 1 closed)` and `(satisfied iterations-exhausted <the 101> satisfied ((eof)))`.
  - Four mutation rows, one prediction error (m8-mutations.md, its last section).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,014 expected passes (main's 2,012 and the two checks), every pin ok.

NEXT: the replay on `test/door-replay`: the door scripts, the trace points guarded so nothing is built untraced, and the fake's two differences fixed. Then the PRs, stacked.

**The cross-shell contract test replays the door (2026-10-11),** on `test/door-replay`, stacked on `fix/hand-off-read-stop` (the entry above), on the owner's form ("Land the replay").
- **Built.**
  - The libuv shell traces each event of a taken stream's as `door`: each read and end, whether the taker's or dropped while the close lingers; each write's completion; its wheel entry passing; and the close's two stages, the half-close and the close begun. Each datum is made by a guarding macro only when the shell has a trace.
  - The fake traces its own door the same.
  - The replay gives the fake each event, a write's completion with the libuv shell's outcome. The close's stages are held by the traces alone.
  - The taker's code marks its calls and what it is told into each shell's trace.
  - Twelve door scripts: eleven to the direct and the coroutine shell, one stalled under short limits. That is 91 checks; the contract suite has 291.
- **The fake's two differences, fixed.**
  - `fake-shell-deliver-later!` takes an outcome, which the replay gives a taker's write, since whether libuv had written it when its stream was aborted is the kernel's.
  - A write after the close is told ECANCELED at the fake's next drain, as the libuv shell's is on its next turn.
- **Measured: the trace points cost nothing untraced.** A probe ran five rounds of 1,000 taker reads with no trace: 4,240.8 to 4,345.3 B a read here, against 4,239.7 to 4,345.5 on `fix/hand-off-read-stop`. A trace point that built its datum anyway read 4,307.8 to 4,408.5, about 64 B more at each rank.
- **Mutants** (m8-mutations.md, its last section).
  - Fifteen rows, one prediction error: DR-14, a fake that never lingers, reddened only the stalled script. The replay completes the fake's close where libuv's completed, and nothing traced when a close began, so the close's stages are traced now.
  - Rerun on the final tree with four rows for the stages: 0 mismatches.
  - Three rows re-cut from M7.3 kill the door scripts' two alike checks. Their one prediction error is outside the door: the suite drives every shell through the direct shell's guard, so a plain handler's raise on another shell went unanswered under DA-1.
  - Every new check has a killer by value. A read error on a taken stream is reached by no script, and paired checks hold it.
- **Records:** design §8.4's note, decision 0016's amendment, and plan §14 (the item settled; the open list holds three).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,105 expected passes (2,014 and the contract suite's 91), every pin ok.

NEXT: the Linux runs and chez-websocket's suites on this branch; then the two PRs, stacked. Plan §14's open list holds three items: the two load-only timing items the owner's form stopped, and the linger check's one red. The late-bytes fix is Unreleased, beside 0027, the signal fix and the wake-value fix.

**The review of #179 and #180 (2026-10-12),** a `/code-review` at xhigh over both: fourteen findings. On the owner's "Fix those two first", its first two.
- **The first, on `test/door-replay`: a write after the close, told on no turn.** #180 moved its ECANCELED to the fake's scheduler. `fake-shell-fire!`'s taker branch and `fake-shell-settle!` never drained it, so a write asked for after the close from a deadline's call, or between turns, was never told.
  - Now each drains the connection's scheduler unless held: a taker's deadline ends its turn as a delivery does, and each later turn begins with the drain, as the libuv shell's does. The contract test's fake is held, so its replay is unchanged.
  - New, the switch suite's "a write a deadline's call asks for after its close is told ECANCELED once the timer's turn ends" and "a write asked for between turns after the close is told ECANCELED at the next turn, not in its call". Test first, red alone by value: `()` and `(() ())`.
  - Mutants FX-1 to FX-3 (m8-mutations.md, its last section).
  - `make test` green before the commit (Darwin arm64): fifty-one suites, 2,107 expected passes (2,105 and the two checks), every pin ok.
- **The second, on `fix/taker-end-once`, stacked on `test/door-replay`: a client's end read before the hand-off.** An end that came while the 101 was written was read by the core, told to the request's code (decision 0020), then dropped at the hand-off.
  - Measured with a 101 too big to complete while the client read nothing: on Darwin (libuv 1.52.1) and Linux (1.48.0) the taker reading in its take-over still got `eof`, since libuv reads the end again at a new read-start. The fake's taker heard nothing, and its stream stayed open with nothing armed.
  - Go keeps no such end for a hijacker: `handleReadErrorLocked` cancels the request's context, and the hijacked connection's next read goes to the kernel (`net/http/server.go` 745-783, 813-821 and 318-338, go1.27.2).
- **DECIDED by form**, the recommended option: "Core hands the end over"; weighed: the fake mimicking the kernel, and noting it only.
- **Built.** The hand-off is `(hand-off take-over retained ended?)`. Given the end, each shell counts the stream as ended: the taker's read-start is told `eof` after the turn, from the scheduler, unless the stream is closing by then, and its close closes at once. A stream that has ended starts no reads, which fixes the review's third finding too: a taker that started reading again after its end was told it twice, libuv reading it again.
  - Records: decision 0016's amendment of 2026-10-12, the design's hand-off row and its note, CHANGELOG.md's Unreleased (Fixed).
- **Checks:**
  - the table's W2 holds `ended?`: its two instances `#f`, and two new ones `#t`, the end read while the 101 is written, with bytes held and with none;
  - new, the switch suite (the fake): the taker reading is told `eof` on the next turn, not in its read-start, and its close closes at once; one that closes in its take-over is told nothing; one told its end that starts reading again reads no more;
  - new, the shell suite (libuv), a client that reads nothing keeping the 101 outstanding (`door-pad`, 8 MiB): the same two, no read started for the end; and a taker told its end that starts reading again is told nothing more.
  - Test first, red alone by value: W2's four; the switch suite's `(() handed-off 0 30000)` and `((eof) #t)`; the shell suite's `(satisfied satisfied ((eof)) 1)` and `(satisfied satisfied ((eof) (eof)) (()))`.
  - Mutants HE-1 to HE-12, one prediction error, HE-8 (m8-mutations.md, its last section).
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,115 expected passes (2,107 and the eight checks: the table's two, the switch suite's three, the shell suite's three), every pin ok.

NEXT: the Linux runs and chez-websocket's suites on `fix/taker-end-once`; #180 updated with the first fix, and the second as a PR stacked on it; the closing ritual on the owner's word, bottom-up. The review's other eleven findings wait for the owner's word.
