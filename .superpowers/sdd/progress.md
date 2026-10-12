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

A tagged release's entries, from the tag before it to its own, live in its own `vX.Y.Z-progress.md`: its work, its release, and its merge and tag. They move there verbatim at the next release, on the owner's form of 2026-10-09; v0.2.0's to v0.4.0's moved at v0.4.1's, v0.4.1's at v0.5.0's, and v0.5.0's at v0.6.0's. This file keeps the entries since the last release archived.

| Release | PRs | Tagged on | `make test` on main at the tag | Archive |
|---|---|---|---|---|
| v0.2.0 | #118–#130 | 1c86771 (#130) | 51 suites, 1,949 | `v0.2.0-progress.md` |
| v0.3.0 | #131–#133 | 5528fa4 (#133) | 51 suites, 1,957 | `v0.3.0-progress.md` |
| v0.4.0 | #134–#151 | 388ec43 (#151) | 51 suites, 1,983 | `v0.4.0-progress.md` |
| v0.4.1 | #152–#160 | 520f70e (#160) | 51 suites, 1,989 | `v0.4.1-progress.md` |
| v0.5.0 | #161–#173 | 02ef95d (#173) | 51 suites, 1,999 | `v0.5.0-progress.md` |

---

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

- **The review's other eleven (2026-10-12),** on the owner's word ("fix 10, 6, 7, 11, and 12 - put the rest in 14s open list"), on `test/door-review-notes`, stacked on `fix/taker-end-once` (#181).
  - **Finding 10, documentation.** `docs/handlers.org` said nothing is read until `transport-read-start!`, but a close reads too, dropping what it reads (decision 0026). It says so now, and so does CHANGELOG.md's entry for #179.
  - **Findings 6 and 7, the late readers' window.** The contract test's `(heard)` waited for any byte, and neither late-reader check held that the client's bytes came between the hand-off and the read-start. A slow turn could skip the window and leave both green on main's core.
    - `(heard)` now waits for the whole 101 and the taker's `taken` mark.
    - A new step, `(sent-before-read)`, holds as the client sends that the stream was handed over with no bytes and the taker had not started reading; otherwise `(window empty? reading?)` parts check 1.
    - The shell suite's late reader holds the same as its client sends: `(handed-off ())`.
  - **Findings 11 and 12, the door's helpers once.** `event->door-read` and `door-read->event` in the fake serve the fake, the replay and check 1. `echo-reads!` in `door-taker` serves `/echo` and `/door-reads-later`.
  - **Noted in plan §14's open list:** findings 4, 5, 8, 9, 13 and 14, each with why it waits.
  - Mutants WT-1 to WT-4b, WS-1, DH-1 and DH-2; two prediction errors, WT-3 and WT-4 (m8-mutations.md, its last section).
- `make test` green before the commits (Darwin arm64): fifty-one suites, 2,115 expected passes, as before (the checks changed, none added), every pin ok.

NEXT: the Linux runs and chez-websocket's suites on `test/door-review-notes`; its PR, stacked on #181; the closing ritual on the owner's word, bottom-up: #179, #180, #181, then this one. Plan §14's open list holds nine items: the three timing items and the review's six.

MERGED to main on 2026-10-12, on the owner's "Do closing ritual": **the door replay and its review**, four stacked PRs, bottom-up (the entries above).
- **The squashes**, each with `--match-head-commit` on the full SHA, its tree the tested tip's:
  - #179 `fix/hand-off-read-stop`: 92fb208 squashed as c54bffb, on f357adb (tree b7ddd55).
  - #180 `test/door-replay`, retargeted to main and rebased from 92fb208: eabb252 squashed as ec703fd (tree 439d1d4, d9f2cc8's).
  - #181 `fix/taker-end-once`, rebased from d9f2cc8: bbe4fcc squashed as 214637a (tree 269e48f, e4b3c38's).
  - #182 `test/door-review-notes`, rebased from e4b3c38: 7db24e7 squashed as 473943c (tree ec91b17, d98f025's).
  - Each force-push took its lease from `ls-remote`; the first read after each showed the old head CONFLICTING/DIRTY, the second the rebased head mergeable.
- **CI.** Billing-blocked. Every run's `linux` job was not started (0 steps, the payments annotation): the PRs' 38183152054, 38245520481, 38245621103 and 38245709522 (read once each, two after their merge, on the same trees' blocked runs 38233378390 and 38236798476), and main's 38245452317, 38245556722, 38245645551 and 38245732218 on the squashes. The runs in the entries above stood in, as each PR body said. They merged past the red check on the owner's word.
- **Branches.** None merged with `--delete-branch`, since the shared checkout holds `main`. The four were deleted on the remote in one push, and locally once this session's worktree was detached at 473943c for this reflect. The shared checkout, clean on `main`, was fast-forwarded after each squash and is again after this. No PR is open.

`make test` green on main: fifty-one suites, 2,115 expected passes, every pin ok.

NEXT: a release when the owner asks. Unreleased since v0.5.0: the late bytes (#179) and the end told once (#181), beside 0027, the signal fix and the wake-value fix; then chez-websocket's pin. Plan §14's open list holds nine items: the three timing items and the door replay review's six. Main's runs are read once when CI returns.

**v0.5.0's entries archived, on `docs/ledger-archive-v0.5.0` (2026-10-12),** on the owner's "Prepare release", by the rule #159 set: a tagged release's entries move out of this file verbatim at the next release.
- **Moved.** Lines 37 to 328 at 605f666, #161 to #173, went into `v0.5.0-progress.md`, with a six-line header naming them: the drain item noted, the held shutdown and the taker's arm by the loop's clock, the sleep check, the timer-stop waits, the timing rule, the chez-libuv v0.9.0 pin, the signal gap noted, decision 0026, v0.4.1's entries archived, and v0.5.0's release, merge and tag.
- **What stays.** This file keeps:
  - its header, and the milestones' table;
  - the tagged releases' table, with a row for v0.5.0: #161 to #173, tagged on 02ef95d (#173), fifty-one suites and 1,999 expected passes, from its merge entry's `make test` on main. The table's note now says v0.5.0's entries moved at v0.6.0's;
  - the entries since v0.5.0's tag, #174 to #182: lines 329 to 515.
  515 lines and 87,401 B became 224 lines and 32,972 B before this entry.
- **Proved** byte for byte by a script: 605f666's lines 1 to 25 and 27 to 33 are this file's; its lines 34 to 36 are this file's 35 to 37; the archive past its header is its lines 37 to 328; and this file's lines from 38 on are its lines from 329.
- **Watched to fail.** Four mutants of the split, each named red and hashed before the run (sha256 0d764eb8…), and each red at the segment named; the split itself green:
  - a line of text dropped from the archive: "archive differs";
  - the archive's last line, the blank, dropped: "archive differs";
  - this file's kept part read from one line late: "kept part differs";
  - the new row put after the table's blank line: "34-36 differs".
- **Records.** This entry only. No CHANGELOG entry: the ledger is the project's process, not anything a client or an embedder meets.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,115 expected passes, every pin ok. Nothing tested changed: the ledger only.

NEXT: 0.6.0's release, stacked on this, by the owner's form ("0.6.0 (Recommended)", "Tag on local runs (Recommended)"). Then chez-websocket's pin to it alone.

**0.6.0's release, on `chore/release-0.6.0` (2026-10-12),** on the owner's "Prepare release", after #179-#182's merges. Stacked on `docs/ledger-archive-v0.5.0`.
- **What it carries.** Every PR since v0.5.0, #174 to #182, was read against CHANGELOG.md's Unreleased.
  - Those an embedder meets are in it: the signals watched before `listening` (#174), under Fixed; decision 0027 (#176), under Changed; the wake value let go (#178), the late bytes (#179, with #182's correction that a close reads too) and the end told once (#181), under Fixed.
  - #180, #181 and #182 changed the test fake, which a taker's own tests load (chez-websocket's `test-binding` and `test-driver` do), and had no entry: one is added under Changed.
  - The other two are records only: #175 and #177.
- **Semantic versioning, by form** ("0.6.0 (Recommended)"; weighed: 0.5.1). No export line changed since v0.5.0. But what `transport-close!` does changes as a taker sees it: a close that waited forever on a client reading nothing now ends once the write timeout passes (decision 0027), as v0.5.0 was a minor for a close a taker sees change. The core's `hand-off` action gained a field (#181), which only the shells read; no document offers `(http-server connection)` to an embedder.
- **The pins** are v0.5.0's: chez-libuv 3c4e7f0 (v0.9.0), chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0 at c338a57), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Built.**
  - CHANGELOG.md: Unreleased moved under `[0.6.0] - 2026-10-12`, with an intro naming the minor, what changes and the pins, and the fake's entry added.
  - A fresh, empty Unreleased above it, and `[0.6.0]` comparing v0.5.0 with v0.6.0.
  - README.org's status names v0.6.0 the current release and what it changes.
- **CI is billing-blocked.** Main's run on 605f666, 38245933693, ended with `linux` not started (0 steps, the payments annotation). By the owner's form ("Tag on local runs (Recommended)"; weighed: waiting for CI), these runs stand in, on this branch's tree before this entry:
  - Darwin arm64, `make test`: fifty-one suites, 2,115 expected passes, every pin ok;
  - Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0), every suite once: fifty green, 2,077 expected passes; the clients suite at status 2 with no tools built, as before;
  - Linux x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`, libuv 1.48.0), every suite once: fifty green, 2,077, the same;
  - chez-websocket's main (50017c4), exported, its fifteen suites on this tree: 395 expected passes, all green.
- **The tag.** After the merges, the billing block proved again on main's run on the release's squash, `v0.6.0` goes on that squash, annotated and signed as v0.5.0 was: "chez-http-server v0.6.0 — a taker's close gives up on a client that reads nothing", its body pointing at CHANGELOG.md's `[0.6.0]`. Main's run is read once when CI returns. The merges and the tag wait for "do closing ritual".
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,115 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

NEXT: the closing ritual for both PRs, bottom-up, and the tag, when the owner asks. Then, in chez-websocket: the pin to v0.6.0 alone.

MERGED to main on 2026-10-12, on the owner's "Do closing ritual": **v0.5.0's entries archived and 0.6.0's release, as two stacked PRs** (the two entries above), bottom-up.
- **#183, v0.5.0's entries archived:** cff63a3 squashed as 55020eb (tree 7d3eda5, the tested head's; parent 605f666). It merged without `--delete-branch`, since #184 was based on it and the shared checkout holds `main`.
- **#184, 0.6.0's release:** retargeted to main and rebased from cff63a3 onto 55020eb, bf809c1 becoming a54b940 (tree 7678e2b, unchanged), pushed with the lease read from `ls-remote`. It squashed as 47c787d (tree 7678e2b; parent 55020eb).
- **CI.** Billing-blocked throughout. Each run ended with its `linux` job not started (0 steps, the payments annotation): the PRs' 38247368667 (cff63a3) and 38247399215 (bf809c1), the rebased head's 38249181195 (a54b940), and main's on each squash, 38249101449 (55020eb) and 38249224128 (47c787d). By the owner's form ("Tag on local runs (Recommended)"), the release entry's local runs stood in: Darwin 2,115 expected passes, Linux aarch64 and x86_64 under emulation 2,077 each, and chez-websocket's fifteen suites 395.
- **TAGGED v0.6.0** on 47c787d, annotated and signed as v0.5.0 was: "chez-http-server v0.6.0 — a taker's close gives up on a client that reads nothing", its body pointing at CHANGELOG.md's `[0.6.0]`. `git tag -v` read a good signature. `git ls-remote --tags` shows the tag object ff52f41 and its commit 47c787d. No GitHub Release, as for the earlier tags.
- **Branches.** Both deleted, remote and local. This session's worktree was left detached at 47c787d for this reflect; the shared checkout, clean on `main`, was fast-forwarded after each squash and is again after this. No PR is open.

`make test` green on main: fifty-one suites, 2,115 expected passes, every pin ok.

NEXT: in chez-websocket, its own repository: the pin to v0.6.0 (47c787d) alone. Its `test-binding` and `test-driver` load this server's fake, whose door changed in #180 to #182; its fifteen suites passed on this tree. Here, v0.6.0's entries move to `v0.6.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds nine items.

**THE CHEZ-LIBUV v0.10.0 PIN, on `chore/chez-libuv-v0.10.0` (2026-10-12),** after the chez-libuv session's handoff (yuzu-libuv-issues-a, on the owner's word there). Measured first, then by the owner's form: "Pin now, one PR (Recommended)" (weighed: staying on v0.9.0) and "Hold for the next release (Recommended)" (weighed: releasing 0.6.1 for the pin alone).
- **The tag.** v0.10.0 is abe6690, a signed annotated tag (object 7030f07); `git tag -v` read a good signature, and origin agrees.
- **The handoff's claims, checked** against chez-libuv's history from 3c4e7f0 to abe6690:
  - among the ten public libraries that changed, `(libuv dns)` dropping `addrinfo-chain->list` is the only change to an export list, and the `(libuv)` facade is unchanged; nothing here uses it;
  - `uv-kill!` now refuses a pid outside a C int, and `uv-write*!` a list of 2^32 segments or more. Our calls are tests/serve-child.sps's two (the process's own pid) and the shell's two (the serializer's segments, and one segment);
  - tests/uv-testing.sls changed in comments only, and `(libuv private native)`'s `live-counts` is untouched;
  - no submodule inside chez-libuv moved, and the libuv floor is still 1.48.0;
  - every ask decision 0008 records of chez-libuv had landed before, so 0008 is unchanged.
- **Measured** on this branch's tree:
  - Darwin arm64, `make build`: the dev shim relinks. `make test`: fifty-one suites, 2,115 expected passes, each suite's count main's at v0.9.0, every pin ok. The log names the same chez-libuv conditions as v0.9.0's, and has no `Exception` or `HARNESS` line.
  - `make prod`: exit 0, and both check-prod runs passed ("the shim is a prod build"). The suite on the prod shim passed 2,109: the clients suite's one counter check and the shell suite's five are not read on a prod shim, by design, each saying so.
  - Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`) and x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`), libuv 1.48.0, every suite once: 2,077 each, each suite's count v0.9.0's on the release tree; the clients suite at status 2 with no tools built, as before.
  - chez-websocket's main (50017c4), exported, its fifteen suites on this tree: 395 expected passes, all green.
- **Built.** The gitlink and the Makefile's `LIBUV_PIN`, global-constraints' pin line, the integration test's import comment, and CHANGELOG.md's Unreleased, under Changed. The measurements went to the chez-libuv session for its downstream notes.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,115 expected passes, every pin ok.

NEXT: the PR, and its closing ritual when the owner asks. The pin waits in Unreleased for the server's next release, by the owner's form; chez-websocket reaches v0.10.0 through it. Plan §14's open list holds nine items.

MERGED to main on 2026-10-12, on the owner's "Do closing ritual": **the chez-libuv v0.10.0 pin, #185** (the entry above). 2cbd4fe was squashed as f27633d (tree 36e4c06, the tested tip's; parent f597e74), with `--match-head-commit` on the full SHA, its gitlink abe6690.
- **CI.** Billing-blocked. Each run's `linux` job was not started (0 steps, the payments annotation): the PR's 38257675234 and main's 38295216260 on the squash. The runs in the entry above stood in, as the PR body said. It merged past the red check on the owner's word.
- **The shared checkout.** Its chez-libuv store lacked abe6690, so the v0.10.0 tag was fetched into it from origin before the fast-forward. `make build` there then checked the submodule out at abe6690 and relinked its dev shim; `check-pins` reads it ok, and its status is clean.
- **Branches.** `chore/chez-libuv-v0.10.0` deleted, remote and local, once this session's worktree was detached at f27633d for this reflect. No PR is open.

`make test` green on main: fifty-one suites, 2,115 expected passes, every pin ok (chez-libuv at abe6690).

NEXT: the pin waits in Unreleased for the server's next release, by the owner's form; chez-websocket reaches chez-libuv v0.10.0 through it, and its pin to v0.6.0 is still to do. When main's runs start again, re-run main's latest run once. Plan §14's open list holds nine items.
