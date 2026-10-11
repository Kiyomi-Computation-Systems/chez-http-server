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
- **Branches.** Deleted on the remote and here. The shared checkout, clean on `main`, was fast-forwarded. No PR is open.
- **Follow-ups**, each in a session of its own: the 20 ms sleep check timed by the loop's clock; the drain-deadline and taker-deadline checks red under load. Another session has `test/taker-arm-refreshes-clock` (chez-websocket#66's SC-1). Each appends to this file, so it rebases onto this.

`make test` green on main: fifty-one suites, 1,989 expected passes, every pin ok.

NEXT: the follow-ups' PRs, then the closing ritual for each when the owner asks. When Actions returns, re-run main's latest run once. Here, plan §14's open list holds three items.
