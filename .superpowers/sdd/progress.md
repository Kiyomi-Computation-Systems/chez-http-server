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

A tagged release's entries, from the tag before it to its own, live in its own `vX.Y.Z-progress.md`: its work, its release, and its merge and tag. They move there verbatim at the next release, on the owner's form of 2026-10-09; v0.2.0's to v0.4.0's moved at v0.4.1's. This file keeps the entries since the last release archived.

| Release | PRs | Tagged on | `make test` on main at the tag | Archive |
|---|---|---|---|---|
| v0.2.0 | #118–#130 | 1c86771 (#130) | 51 suites, 1,949 | `v0.2.0-progress.md` |
| v0.3.0 | #131–#133 | 5528fa4 (#133) | 51 suites, 1,957 | `v0.3.0-progress.md` |
| v0.4.0 | #134–#151 | 388ec43 (#151) | 51 suites, 1,983 | `v0.4.0-progress.md` |

---

THE CHEZ-LIBUV v0.8.0 PIN, on the owner's form ("Bump now, one PR (Recommended)"; weighed: staying on v0.7.4), after the libuv:issues session's note of the release. Branch chore/chez-libuv-v0.8.0, cut from main at 6c451bb in a worktree of its own; 2026-10-09, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at ad3bb47.

UPSTREAM: chez-libuv tagged v0.8.0 (ad3bb47; annotated, 11 commits past v0.7.4). It carries no ask of ours, so decision 0008 is unchanged. It finishes v0.7.4's one-step work (#85, #86): every verb checks its handle or loop, and its owner, and calls libuv in one step that no engine splits. Besides that:
- the libuv floor rises from 1.44.0 to 1.48.0. The build passes a system libuv below it over for chez-libuv's vendored one, and the generated `config.sls` refuses one below it at load (`&uv-version-incompatible`); here it reads `(#x013000 . #x01ffff)`;
- seven verbs return nothing where they returned 0: `uv-timer-start!`, `uv-timer-stop!`, `uv-timer-again!`, `uv-signal-stop!`, `uv-listen!`, `uv-tcp-nodelay!` and `uv-tcp-keepalive!`;
- new refusals by name: a timer verb given another kind of handle, and a timeout, repeat, keepalive delay or backlog out of range.

Checked against chez-libuv's history between the tags, and against the server:
- the shim's C and header are byte-identical, so `make test` did not recompile it; it regenerated `config.sls`. No public library's export list changed, and `tests/uv-testing.sls` is byte-identical;
- no result of the seven verbs is read. Their seven call sites in `src/` are in the shell: `loop-clock!`'s start and stop, the listen, the nodelay under its guard, and the tick timer's again, start and stop. The waits call the clock's start for its effect only: in `arm-at!` under a `when`, and as `waits-fire!`'s last call, whose value the timer's callback drops. No suite reads one either;
- the backlog is already held to 2,147,483,647 (`limits.sls`), and the server makes no engine;
- CI's libuv is ubuntu-24.04's apt 1.48.0 (`pkg-config --modversion` in #144's run), exactly the floor.

Watched to fail: with the checkout moved and its gitlink staged, and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). With both moved, it passes.

`make test` green at v0.7.4 and at v0.8.0 on this branch: fifty-one suites, 1,983 expected passes, every suite's count the same. The clients suite read 5,143 B a GET at v0.7.4, and 5,157 and 5,143 B over two runs at v0.8.0.

MEASURED at both pins the same day, Darwin arm64: a GET through the whole server, `hoist-request-alloc.sps`, two rounds, 5,143 to 5,150 B at one connection and 5,014 to 5,020 at 50 at v0.7.4, and 5,150 B and 5,015 to 5,019 at v0.8.0, unchanged. By `libuv-callback-alloc.sps`, three runs, a write's round 1,354 to 1,355 B against 1,350 to 1,352, a timer's firing 513 B against 516, and an idle `uv-run` 16 B at both. v0.8.0's cuts are in the calls a GET does not make here: connect, bind, the lookups and the address queries.

Records: the Makefile's pin, test-integration's version comment, README.org's libuv floor, global-constraints (the floor and the pin), CHANGELOG.md's Unreleased.

MERGED to main on 2026-10-09, on the owner's "do closing ritual": **the chez-libuv v0.8.0 pin**, #155.
- 6682146 was squashed as 5a1eccc (tree e210091, the tested head's; parent 6c451bb).
- Its run, 37987345199, passed on ubuntu-24.04 with libuv 1.48.0, the new floor: fifty-one suites, 1,983 expected passes; the clients suite read 5,156 B a GET.
- The branch was deleted on the remote and here, and this session's worktree removed. The shared checkout held another session's branch (fix/0025-review) with uncommitted work, so it was left alone; local `main` was fast-forwarded by fetch.

`make test` green on main: fifty-one suites, 1,983 expected passes; the clients suite read 5,143 B a GET.

NEXT: chez-websocket's M4.2, in its own repository: pin v0.4.0, put this server's `tests/` on its test path for the fake shell, and record its decision 0004. Here, plan §14's open list holds decision 0024's review's two noted items.

**Decision 0025, a coroutine parks on a full continuation and each park lands once (2026-10-09),** on the owner's "lets start the server slice". It is the slice chez-websocket's M4.3 step 3 review asked for by form ("A server slice next"). Three stacked branches, by form ("Three stacked PRs (Recommended)"), cut from 6c451bb: `docs/0025-park-decision` (the records), `feat/0025-park` (the code) and `docs/0025-ledger`.
- **Measured first** (Darwin arm64, and Linux aarch64 in Docker, alike; the heap check's numbers on Linux x86_64 too, under emulation), in the scratch `srv-park/`:
  - **What a park keeps.** Main's park, by `call/1cc`, kept the stack segment it was captured on: a coroutine parked 4 calls deep held 3,691 B on the heap, and one at an `await` 3,634 to 3,644 B. By `call/cc` alone, on the tree before the numbering, 705 B 4 calls deep. A park still *allocates* a segment either way (3,772 B, against 3,887 to 3,984 by `call/cc` alone), so only the heap tells them apart. (The numbered tree's figures are decision 0025's: 745 B, and 3,919 to 3,984.)
  - **What a continuation entered twice does.** With `call/cc` and no check, the code after a park ran twice in three cases, where `call/1cc` raised each time:
    - a handler's own `dynamic-wind` before thunk re-entering the park;
    - the scheduler resuming a park twice, with both of its guards removed;
    - a coroutine returning into an old drain (R3 broken), which re-ran the program from that drain.
  - **What the checks would cost.** Numbering each park: +39 B through `await` and 39 to 71 B with the scheduler alone, per wake and park, and +40 B parked. Checking the state at resume: nothing. Numbering the drain too: 8 B more parked.
  - **Peers.** Python, Ruby, Node and Racket each refuse to resume a running coroutine, at the resume. Racket's generator ran the code after a yield twice in the `dynamic-wind` case.
  - **chez-websocket's S-PARK.** With this scheduler shadowed in, its socket suite stopped as a provenance failure: its `call/1cc` reference, promoted by the park's capture, sat 196 B over a bare `await`.
- **DECIDED by form** ("Number each park (Recommended)"), decision 0025. Weighed and not taken: the state at resume, as the peers check, which no test could reach; and numbering the drain's continuation too, which the R3 row holds already.
- **Built.** `suspend!` parks and yields by `call/cc`. It numbers the park on its coroutine first, a new field `parks`, and the landing refuses a second landing, an assertion naming the verb. The drain's `call/1cc` is unchanged.
- **The suite.** `tests/test-scheduler.sps` gains two checks, now 23:
  - a park's or a yield's continuation entered a second time is refused, naming the verb, and the code after it runs once (a `dynamic-wind` before thunk re-enters it);
  - a coroutine parked 4 calls deep keeps under half of what a one-shot continuation held 4 calls deep keeps. The reference is measured in the run, and the suite stops as a provenance failure if it keeps under 2 KiB.
  - The calibration row now says "allocate", since a parked coroutine no longer keeps its segment.
- **Tests first**, in three stages (m8-mutations.md). Stage 0 was first run before its prediction was named, a slip: its red set was seen, its values were predicted blind and matched. Stages 1 and 2 matched as named.
- **Mutants:** 17 rows, 16 mutants and the baseline.
  - Run 1: 2 mismatches, one prediction error. M7S-B and M7S-R, re-cut from M7's log, also reddened `connection-switch` and `message-loop`, whose waiting rows came after it.
  - Run 2, those two re-predicted: 0 mismatches, the same counts.
  - Every new or changed check has a killer by value. M7X-1 survives, as at the M7 exit.
- **Docs.** `docs/handlers.org`: a waiting handler, and a thunk that waits, hold about 0.7 KB, where 3.6. CHANGELOG.md's Unreleased gains two Changed entries.
- **Records.** Decision 0025, new; design §5.2's amendment; plan §15.
- `make test` green on each layer before its commit (Darwin arm64): fifty-one suites, and 1,983, 1,985 and 1,985 expected passes; every pin ok.

NEXT: the PRs by form; review and the closing ritual when the owner asks; then 0.4.1's release. Then, in chez-websocket, S-PARK's reference moves to one held outside the scheduler, before the pin moves to v0.4.1 alone.

**Decision 0025's review, as three more stacked branches by form ("Three stacked PRs (Recommended)"): `docs/0025-review-records`, `fix/0025-review` and `docs/0025-review-ledger`, on `docs/0025-ledger` (2026-10-09):** a /code-review xhigh over #152 to #154 reported eight findings. On the owner's "fix all", all eight were fixed. One, finding 6, turned out larger than reported, and two forms decided it.
- **Measured first.**
  - **Finding 6, a fresh coroutine that waits once.** A 16 MiB upload whose reader waited on every piece allocated 24,025 B a piece, where main's allocated about 21,000. That isolated to a coroutine that parks once, 4 calls deep: 4,256 to 4,257 B, where main's 720. The drain's one-shot continuation, made multi-shot by the park's full capture, cost each such coroutine a fresh stack segment.
  - **Through the server** (Darwin arm64, `oha`, 20,000 requests a route), a request that waited once allocated 10,255 to 10,556 B, where main's 6,977 to 7,980. One that answered at once, or answered awaiting without waiting, was unchanged.
  - **The drain full too:** 7,158 to 7,868 B a request, and 21,106 to 21,187 B a waiting piece. A parked coroutine keeps what it did, 738 B.
  - **The refusal's two gaps, on main and the branch alike.**
    - A guard around the wait caught the refusal, and the code after the wait ran twice.
    - Entered from another coroutine, the wrong coroutines ended: the entering one was reported returning `#f`, and the parked one was marked ended, so its next wake raised inside a libuv callback.
- **DECIDED by form:**
  - "Drain full too (Recommended)": the drain enters and resumes coroutines by `call/cc`.
  - "End the one running (Recommended)", after the owner asked how peers handle it. The refusal ends the coroutine whose turn it is, through the drain, naming the wait, so no guard on the frames entered sees it, and a parked coroutine stays parked.
- **Built:**
  - `resume!` by `call/cc`, so the scheduler imports `(rnrs)` alone;
  - `refuse-landing!`;
  - `coroutine-park!` takes the waiting verb's name, which `wait!` passes;
  - the comments re-measured.
- **The suites** (scheduler 26, waits 38):
  - the guarded row;
  - the cross-coroutine row, which holds the park's number rather than its parity (finding 2);
  - a coroutine that waits once allocates under half of a one-shot reference;
  - the calibration moved to that reference, since parks no longer allocate a segment;
  - the waits suite's `await` row;
  - `heap` shared in `(testing)` (finding 8).
- **Records:** the stale R3 text (finding 1), in the suite's header and design §5.3's amendment; design §5.2's amendment; decision 0025's review amendment; `docs/handlers.org`, the size growing with depth (finding 5); CHANGELOG.md; the first entry's numbers labelled by tree (finding 7).
- **Tests first**, in four stages, each named and hashed before its run (m8-mutations.md). All four matched: 1,985 passes and the 4 new rows red; then 1,986, 1,988 and 1,989.
- **Mutants:** 28 rows, 27 mutants and the baseline, against every suite but where the log says.
  - Run 1, read from the suites' own logs: 1 mismatch, a prediction error. PT-1b, the allocation reference by a full continuation, is equivalent: one captured and left allocates a segment too, 3,484 B.
  - PK-4's ninth red row was in its suite's log, not the runner's report, which prints eight. The comparison now reads the logs.
  - Run 2, PK-4 and PT-1b, the latter re-predicted: 0 mismatches.
  - Every new or changed check has a killer by value.
  - M7X-1, a survivor since the M7 exit, now reddens the shell suite's idle check: a full drain continuation kept would hold the last coroutine.
- **Measured on the finished tree,** the scheduler-alone figures on Darwin arm64 and Linux aarch64, the rows' on x86_64 too, alike:
  - a coroutine parked 4 calls deep keeps 802 B (main 3,691 to 3,692);
  - at an `await`, 690 to 754 B (main 3,676 to 3,848), about 16 B more a call deeper;
  - a coroutine that waits once allocates 1,177 to 1,242 B (main 720);
  - through the server, a request that waits once allocates 7,160 to 7,877 B (main 6,977 to 7,980), and a waiting piece 21,073 to 21,154 B (main about 21,000).
- `make test` green on each layer before its commit (Darwin arm64): fifty-one suites, and 1,985, 1,989 and 1,989 expected passes; every pin ok.
- **Rebased onto c7bfd48** once #155, another session's chez-libuv v0.8.0 pin, had merged to main. All six branches moved with `--update-refs`; CHANGELOG.md's Unreleased kept both entries, the pin's first. Re-run on v0.8.0 (Darwin arm64), the server's figures fall within the ranges above but one: a request that answers awaiting without waiting allocates 6,325 to 6,526 B (main 6,404 to 6,803). Otherwise: a request that waits once, 7,161 to 7,874 B (main 7,019 to 7,973); a waiting piece, 21,090 to 21,154 B (main 21,039 to 21,056).
- **The PRs:** #152 to #154 for the slice; #156 to #158 for the review (#155 was the pin).

NEXT: the closing ritual for #152 to #154 and #156 to #158, bottom-up, when the owner asks; then 0.4.1's release. Then, in chez-websocket, S-PARK's reference moves to one held outside the scheduler, before the pin moves to v0.4.1 alone.

MERGED to main on 2026-10-09, on the owner's "all green lets do the closing ritual": **decision 0025 and its review, as six stacked PRs** (the two entries above), bottom-up, each after main's run on the squash below had passed.
- **The squashes.** Each has the tree of the head CI tested, and sits on the squash below:
  - #152, the records: ccd4e72 squashed as 39cf0b3, on c7bfd48;
  - #153, the park: 2edcbf9 rebased as a52c8e6, squashed as ac32251;
  - #154, the ledger: f582156 rebased as 1eddaaf, squashed as a4b310e;
  - #156, the review's records: 69213ab rebased as f74738e, squashed as 0a1021c;
  - #157, the review's code: 3bf8db3 rebased as 93b2c3d, squashed as cab5b04;
  - #158, the review's ledger: 7b6c84d rebased as d6186bf, squashed as 6133001.

  Each rebased tree was proved equal to its tested tip's before the push, made with the lease read from `ls-remote`.
- **CI.** Every head merged passed on `linux`, its log tallied against the local count: #152 on ccd4e72 (run 37991325524), fifty-one suites, 1,983 expected passes; #153 on a52c8e6 (37992568262), 1,985; #154 on 1eddaaf (37992875736), 1,985; #156 on f74738e (37993177799), 1,985; #157 on 93b2c3d (37993465618), 1,989; #158 on d6186bf (37993748288), 1,989. Main's runs on 39cf0b3 (37992539801), ac32251 (37992860644), a4b310e (37993161630), 0a1021c (37993452085) and cab5b04 (37993734534) each passed before the next merge; main's run on 6133001 (37994037273) passed, fifty-one suites and 1,989 expected passes, before this reflect was pushed.
  - #156's earlier red was a duplicate run (37991325226), cancelled by the workflow's concurrency group before it ran a step, when all six branches were pushed at once; the other run on the same head (37991325187) had passed. Its rebased head's only run passed.
- **Branches.** All six deleted, local and remote. No PR is open.

**Decision 0025 is on main:**
- coroutines entered, and parked, on full continuations;
- each park numbered, and a park entered again ending the coroutine whose turn it is, naming the wait.

CHANGELOG.md's Unreleased holds two Changed entries for it, beside the chez-libuv v0.8.0 pin's.

`make test` green on main: fifty-one suites, 1,989 expected passes, every pin ok.

NEXT: 0.4.1's release, when the owner asks. Then, in chez-websocket: S-PARK's reference moves to one held outside the scheduler, then the pin moves to v0.4.1 alone, then M5.

**The ledger archived by release, on `docs/ledger-archive-by-release` (2026-10-09),** on the owner's form ("A file per closed release (Recommended)", "Its own PR, below the release (Recommended)"), after "lets do the v0.4.1 release". Cut from 86b99dc; v0.4.1's release stacks on it.
- **Why now.** AGENTS.md said that at each release the entries before it move out of `progress.md` into an archive file, verbatim. #138's entry set that to start at the next release, which was v0.4.0, and v0.4.0's release did not do it. At 86b99dc this file was 835 lines and 122,171 B (sha256 57c45afb…425a81c1).
- **Weighed, not taken:**
  - everything before this release, v0.4.1's own work (#155 to #158) too: the literal reading, which parts v0.4.1's release and merge entries from the work they release;
  - one file for the 0.x line, added to at each release, as Node keeps a changelog per major line (27 files under `doc/changelogs`). CPython keeps a file per release (119 under `Misc/NEWS.d`), and Rust one file it never splits (`RELEASES.md`, 930 KB).
- **Moved.** Lines 26 to 713 went into three files, each with a six-line header naming the lines it holds:
  - `v0.2.0-progress.md`, lines 26 to 197, #118 to #130: 35,552 B;
  - `v0.3.0-progress.md`, lines 198 to 252, #131 to #133: 8,609 B;
  - `v0.4.0-progress.md`, lines 253 to 713, #134 to #151: 60,269 B.

  Every cut falls on a blank line between entries, and each file holds its release's work, its release, and its merge and tag.
- **What stays.** This file keeps:
  - its header, and the milestones' table;
  - a new table of the tagged releases. Each row's PRs and squash come from main's log, and its counts from the release's last `make test` on main;
  - the entries since v0.4.0's tag, #155 to #158: lines 714 to 835, 16,041 B.
- **AGENTS.md** says a tagged release's entries live in its `vX.Y.Z-progress.md`, moved out verbatim at the next release. v0.4.1's move at the release after it.
- **Proved.** 86b99dc's first 25 lines, each archive past its header, and this file's lines 36 to 157 equal the old file byte for byte (`cmp`). Before this entry the file was 157 lines and 18,294 B.
- **Watched to fail.** Four mutants of the split, each named red and hashed before the run, and each red; the split itself green:
  - a line dropped from `v0.3.0-progress.md`;
  - `v0.2.0-progress.md` and `v0.4.0-progress.md` swapped;
  - `v0.4.0-progress.md`'s last line dropped;
  - this file's kept part read from one line late.

  The first run answered 127 for each, a slip in the harness: zsh does not split a variable into words, so no proof ran. Run again with the script named directly, each was red. The first mutant then dropped a blank line; it was re-cut to drop a line of text, and was red again.
- **Records.** This entry only. No CHANGELOG entry: the ledger is the project's process, not anything a client or an embedder meets.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,989 expected passes, every pin ok. Nothing tested changed: the ledger and AGENTS.md only.

NEXT: v0.4.1's release, stacked on this, by the owner's form. Then, in chez-websocket: S-PARK's reference moves to one held outside the scheduler, then the pin moves to v0.4.1 alone, then M5.

**v0.4.1's release, on `chore/release-0.4.1` (2026-10-09),** on the owner's "lets do the v0.4.1 release", after decision 0025's merges: the release chez-websocket's next pin waits for. Stacked on `docs/ledger-archive-by-release`, by the owner's form.
- **What it carries.** Every PR since v0.4.0, #152 to #158, was read against CHANGELOG.md's Unreleased.
  - The three an embedder meets are in it, all under Changed: the chez-libuv v0.8.0 pin (#155), and decision 0025's park (#153) and its review's drain and refusal (#157).
  - The other four are records only: #152, #154, #156 and #158.
- **Semantic versioning.** Decision 0025 named 0.4.1, a patch, before #155 raised the libuv floor from 1.44 to 1.48, so the patch was checked again:
  - nothing an embedder calls changes. Since v0.4.0 only `private/scheduler.sls` and `private/waits.sls` changed under `src/`, and no export line;
  - chez-websocket gets chez-libuv only through this server's checkout, and calls none of the seven verbs whose results v0.8.0 changed (its `src/` and `tests/` at 43b18e7);
  - Debian 12's libuv, 1.44.2, built 0.4.0. 0.4.1 builds chez-libuv's own libuv 1.52.1 there, and Debian 12's own CMake, 3.25.1, built it with chez-libuv's flags (in chez-libuv's Debian 12 image, 2026-10-09). Ubuntu 24.04's libuv and Homebrew's are used as before.

  So the release is 0.4.1. chez-libuv tagged its floor v0.8.0, a minor, since seven of its verbs' results changed; the server reads none of them (#155's entry).
- **A record corrected.** README.org said chez-libuv's own libuv build needs CMake 3.26+, and global-constraints.md "CMake 3.26 where CMake is used". This server's build runs CMake only for that libuv, whose CMakeLists asks for 3.10 (3.13 only under UBSAN). The 3.26 is chez-httparse's, uriparse's and byte-machine's own floor, set by CMake presets this build never runs, restated in M-1's planning (bb81cc1). Both now say 3.10, and that Debian 12's own builds it.
- **The pins.** chez-libuv moved from 27d84bb (v0.7.4) to ad3bb47 (v0.8.0), by #155. The rest are v0.4.0's: chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Built.**
  - CHANGELOG.md: Unreleased moved under `[0.4.1] - 2026-10-09`, with an intro naming the patch, what changes and the pins.
  - A fresh, empty Unreleased above it, and `[0.4.1]` comparing v0.4.0 with v0.4.1.
  - README.org's status names v0.4.1 the current release and what it changes.
- **Not re-measured.** The intro's "about 3 KB less" is the Changed entry's, measured by #157 on its finished tree (Darwin arm64, Linux aarch64 and x86_64), and README.org's 0.7 KB is `docs/handlers.org`'s. So the load smoke was not run again.
- **The tag.** After the merges, once main's run on the release's squash is green, `v0.4.1` goes on that squash, annotated and signed as v0.4.0 was: "chez-http-server v0.4.1 — a waiting handler keeps about 3 KB less", with a body pointing at CHANGELOG.md. The owner's "lets do the v0.4.1 release" asks for it; the merges wait for "do closing ritual".
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,989 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

NEXT: the closing ritual for both PRs, bottom-up, and the tag, when the owner asks. Then, in chez-websocket: S-PARK's reference moves to one held outside the scheduler, then the pin moves to v0.4.1 alone, then M5.

MERGED to main on 2026-10-09, on the owner's "ci is green, do closing ritual": **the ledger archive and v0.4.1's release, as two stacked PRs** (the two entries above), bottom-up.
- **#159, the ledger archived by release,** as 5e09f79 (tree d7f5bd0's, parent 86b99dc). Its run, 37996804554, passed on d7f5bd0: fifty-one suites, 1,989 expected passes on ubuntu-24.04. It merged without `--delete-branch`, since #160 was based on it. Main's run on the squash, 37997095845, passed before #160 merged.
- **#160, v0.4.1's release,** retargeted to main and rebased from d7f5bd0 onto 5e09f79: 33b6187 became 1e671cd (the tested tree), pushed with the lease. CI passed on both heads (37996827716 on 33b6187, 37997130602 on 1e671cd), each fifty-one suites and 1,989 expected passes. It merged as 520f70e (tree 1e671cd's, parent 5e09f79). Main's run on the squash, 37997420381, passed before the tag.
- **Branches.** Both were deleted, local and remote; this checkout is on main, fast-forwarded. No PR is open.
- **TAGGED v0.4.1** on 520f70e, annotated and signed as v0.4.0 was: "chez-http-server v0.4.1 — a waiting handler keeps about 3 KB less", its body pointing at CHANGELOG.md's `[0.4.1]`. `git verify-tag` read a good signature. `git ls-remote --tags` shows the tag object 947d782 and its commit 520f70e. No GitHub Release, as for the earlier tags.

`make test` green on main: fifty-one suites, 1,989 expected passes, every pin ok.

NEXT: in chez-websocket, its own repository: S-PARK's reference moves to one held outside the scheduler, then its pin moves to v0.4.1 alone, then M5. Here, v0.4.1's entries move to `v0.4.1-progress.md` at the next release.

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
