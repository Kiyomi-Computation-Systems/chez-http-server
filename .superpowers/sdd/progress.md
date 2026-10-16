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

A tagged release's entries, from the tag before it to its own, live in its own `vX.Y.Z-progress.md`: its work, its release, and its merge and tag. They move there verbatim at the next release, on the owner's form of 2026-10-09; v0.2.0's to v0.4.0's moved at v0.4.1's, v0.4.1's at v0.5.0's, v0.5.0's at v0.6.0's, and v0.6.0's at v0.7.0's. This file keeps the entries since the last release archived.

| Release | PRs | Tagged on | `make test` on main at the tag | Archive |
|---|---|---|---|---|
| v0.2.0 | #118–#130 | 1c86771 (#130) | 51 suites, 1,949 | `v0.2.0-progress.md` |
| v0.3.0 | #131–#133 | 5528fa4 (#133) | 51 suites, 1,957 | `v0.3.0-progress.md` |
| v0.4.0 | #134–#151 | 388ec43 (#151) | 51 suites, 1,983 | `v0.4.0-progress.md` |
| v0.4.1 | #152–#160 | 520f70e (#160) | 51 suites, 1,989 | `v0.4.1-progress.md` |
| v0.5.0 | #161–#173 | 02ef95d (#173) | 51 suites, 1,999 | `v0.5.0-progress.md` |
| v0.6.0 | #174–#184 | 47c787d (#184) | 51 suites, 2,115 | `v0.6.0-progress.md` |

---

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

**THE CHEZ-LIBUV v0.11.0 PIN, on `chore/chez-libuv-v0.11.0` (2026-10-15),** after the chez-libuv session's handoff (yuzu-libuv-issues-a). Measured first, then by the owner's form: "Pin now, one PR (Recommended)" (weighed: staying on v0.10.0). The release is still held for the server's next one (#185's form), so this pin replaces v0.10.0 in Unreleased.
- **The tag.** v0.11.0 is afe79a5, a signed annotated tag (object 40a0172); `git verify-tag` read a good signature (the Kiyomi release key).
- **The handoff's claims, checked** against chez-libuv's history from abe6690 to afe79a5:
  - `git diff v0.10.0 v0.11.0 -- src/ 'tests/*.sls'` is empty: no library, export or condition changed, and neither did `(uv-testing)`;
  - no submodule inside chez-libuv moved, and the libuv floor is still 1.48.0;
  - chez-libuv's Makefile gains the variables `WERROR`, `SHIM_LDFLAGS`, `CONFIG_EXPORTS` and `CONFIG_GENERATOR` and the target `akku-facts`, each defaulting to the old build. Our Makefile sets none of those names, and calls only chez-libuv's `build`, `prod`, `check-prod` and `clean`;
  - the rest is Akku's install hook (`scripts/akku-install`, `scripts/find-cc`), `.akkuignore`, Akku.manifest, CI and the docs site. None of it touches a submodule build;
  - decision 0008 records no ask of chez-libuv still open, so it is unchanged.
- **Measured** on this branch's tree (the gitlink and `LIBUV_PIN` only):
  - Darwin arm64, `make build`, exit 0. `make test`: fifty-one suites, 2,115 expected passes, each suite's count v0.10.0's (#185's run on main), every pin ok, and no `Exception` or `HARNESS` line.
  - `make prod`: exit 0, and both check-prod runs passed ("the shim is a prod build"). The suite on the prod shim passed 2,109, each suite's count v0.10.0's prod run; the clients suite's one counter check and the shell suite's five are not read on a prod shim, by design, each saying so. `make build` afterwards restored the dev shim.
  - Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`) and x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`), libuv 1.48.0, every suite once: 2,077 each, each suite's count #185's runs at v0.10.0; the clients suite at status 2 with no tools built, as before.
  - chez-websocket's main (50017c4), exported, its fifteen suites on this tree: 395 expected passes, all green.
- **Built.** The gitlink and the Makefile's `LIBUV_PIN`, global-constraints' pin line, the integration test's import comment, and CHANGELOG.md's Unreleased entry, which now names v0.11.0 and keeps v0.10.0's three changes. The measurements went to the chez-libuv session.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,115 expected passes, every pin ok.

NEXT: the PR, and its closing ritual when the owner asks. The pin waits in Unreleased for the server's next release, by #185's form; chez-websocket reaches chez-libuv v0.11.0 through it, and its pin to v0.6.0 is still to do. Plan §14's open list holds nine items.

MERGED to main on 2026-10-16, on the owner's "Do closing ritual": **the chez-libuv v0.11.0 pin, #186** (the entry above). cc793b0 was squashed as 4fec604 (tree b86ce88, the tested tip's; parent 532cdc5), with `--match-head-commit` on the full SHA, its gitlink afe79a5.
- **CI.** Billing-blocked. Each run's `linux` job was not started (0 steps, the payments annotation): the PR's 38882774720 and main's 38898493983 on the squash. The runs in the entry above stood in, as the PR body said. It merged past the red check on the owner's word.
- **The shared checkout.** Its chez-libuv store lacked afe79a5, so the v0.11.0 tag was fetched into it from origin before the fast-forward. `make build` there then checked the submodule out at afe79a5; `check-pins` reads it ok, and its status is clean.
- **Branches.** `chore/chez-libuv-v0.11.0` deleted, remote and local, once this session's worktree was detached at 4fec604 for this reflect. No PR is open.

`make test` green on main: fifty-one suites, 2,115 expected passes, every pin ok (chez-libuv at afe79a5).

NEXT: the pin waits in Unreleased for the server's next release, by #185's form; chez-websocket reaches chez-libuv v0.11.0 through it, and its pin to v0.6.0 is still to do. When main's runs start again, re-run main's latest run once. Plan §14's open list holds nine items.

**THE FAKE KEEPS WHAT A TAKER IS NOT READING, on `fix/fake-door-kept-reads` (2026-10-16),** plan §14's first review note, on the owner's "fix items 4 and 5 from the open list" (item 5, the fake's write bound, is the PR stacked on this one).
- **The note.** `fake-shell-deliver!`'s taker branch did not ask `fake-shell-reading?`: bytes delivered before a taker's read-start reached an `on-bytes` not yet given, a taker failure that aborted the stream, and a delivery after its read-stop reached it all the same.
- **Probed first** on the libuv shell (Darwin arm64, libuv 1.52.1, three runs alike): a taker that stopped at its first read heard nothing through fifty turns while its client sent "cd" and shut its write side; reading again, it read "cd", then `eof`.
- **Landed.** The fake keeps what comes while the stream is not read, reads and the end alike, in order (`fake-taker-kept`), and reads it on the turn after reading starts again, at a read-start or at the close (decision 0026), ahead of what comes after, each read traced as it is read (`reading-begun!`, `read-kept!`).
- **Three checks in the switch suite**, red on main's fake by value; eight mutation rows, every one red where predicted (m8-mutations.md, the last section).
- **chez-websocket.** Its main (6caf10b, which pins this server's v0.6.0 since its #79) passed 397 on main's fake and 396 on this one: the binding suite's "a send waiting when the connection ends is woken at once, before the client reads" ends its connection while the binding has stopped reading, its client behind, which the server never tells (the probe). Decided by the owner's form: "Land it; fix ws's check at its next pin (Recommended)" (weighed: the fake still handing an end to a stopped taker; changing the check first). chez-websocket loads the fake from its pinned server release, so the check meets it at its pin of the server's next release.
- **Records.** Plan §14 (the item settled; the open list holds eight), CHANGELOG.md's Unreleased under Changed, the fake's header.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,118 expected passes, every pin ok.

NEXT: the fake's write bound (decision 0027), stacked on this branch; then both PRs, and their closing ritual when the owner asks. chez-websocket's pin of the server's next release rewrites its binding check (above). Plan §14's open list holds eight items.

**THE FAKE'S WRITE BOUND (decision 0027), on `fix/fake-door-write-bound` (2026-10-16),** plan §14's second review note, stacked on `fix/fake-door-kept-reads`, on the same word of the owner's.
- **The note.** A taker's entry passing made its deadline call in the fake, where the libuv shell aborts the stream once the close's write bound has passed; 0027 had said the bound never applies in the fake, since a fake write is the client's at its turn. But a test that delivers no later turn plays a client that reads nothing (decision 0024), so a fake write can be held.
- **Landed.** The fake keeps the taker's own deadline and the bound as two instants, its one wheel entry armed at the earlier (`taker-arm!`), the bound from the close and again from each write's end (`taker-bound!`), and a pass handled as the libuv shell's (`taker-passed!`): lingering, the close; the bound passed, the abort; else the taker's call, then whichever is still armed armed again. `hand-off!` takes the limits for the write timeout.
- **Checks.** Five in the switch suite, and a thirteenth door script in the contract test, played to the quick shell, whose limits gain a 300 ms write timeout: its client stops reading once it has the 101 (`(stop-reading)`), its taker writes 16 MiB at the client's "go" and closes, and `(bounded)` holds that the libuv shell told that write ECANCELED. On item 4's fake each was red by value, the script's traces parting at the libuv shell's pass.
- **Mutation.** Eleven rows on every suite, then BR-1b, CT-1, CT-2 and SH-1 alone (m8-mutations.md, the last section). Four prediction errors are recorded there. One found a gap of its own: a waiting taker's thunk that ends with no values is taken as a raise, though decision 0023 drops its value. That is flagged as a separate task, not fixed here. The rows ran before `(bounded)` was added; it changes only the script's check 1, which none of them reddens.
- **chez-websocket** (6caf10b) on this tree: 396, the one binding check of the entry above; the bound changes none of its checks.
- **Records.** Decision 0027's amendment of this date (its "the fake shell is unchanged" corrected), plan §14 (the item settled; the open list holds seven), CHANGELOG.md's Unreleased under Changed, the fake's header, the switch and contract suites' headers.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,126 expected passes, every pin ok.

NEXT: both PRs (this one stacked on the kept reads'), and their closing ritual when the owner asks. chez-websocket's pin of the server's next release rewrites its binding check. The no-values thunk is a task of its own. Plan §14's open list holds seven items.

MERGED to main on 2026-10-16, on the owner's "Do closing ritual": **the fake keeps what a taker is not reading, and the fake's write bound, as two stacked PRs** (the two entries above), bottom-up.
- **#187** a176c82 was squashed as c1d1be2 (tree 69ab334, the tested tip's; parent 988d67d), with `--match-head-commit` on the full SHA, and without `--delete-branch`, since #188 was based on it.
- **#188** was retargeted to main and rebased from a176c82 onto c1d1be2: 4fa96c3 became 8e45e65, its tree 4a7e287 unchanged, pushed with a lease read from `ls-remote`. It was squashed as 47e5ab8 (tree 4a7e287; parent c1d1be2).
- **CI.** Billing-blocked. Each run's `linux` job was not started (0 steps, the payments annotation): the PRs' 38904661224 and 38904668200, the rebased #188's 38905146677, and main's 38905103653 and 38905199827 on the squashes. The runs in the entries above stood in, as the PR bodies said. It merged past the red checks on the owner's word.
- **The shared checkout** fast-forwarded to 47e5ab8, clean. Neither PR moved a pin or the Makefile, so nothing was rebuilt.
- **Branches.** `fix/fake-door-kept-reads` and `fix/fake-door-write-bound` deleted, remote and local, once this session's worktree was detached at 47e5ab8 for this reflect. No PR is open.

`make test` green on main: fifty-one suites, 2,126 expected passes, every pin ok.

NEXT: chez-websocket's pin of the server's next release rewrites its binding check (the kept reads' entry). The no-values taker thunk is a task of its own (another session). The chez-libuv v0.11.0 pin waits in Unreleased for the server's next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds seven items.

**A WAITING TAKER'S THUNK MAY END WITH NO VALUES, on `fix/taker-thunk-no-values` (2026-10-16),** the task #188's mutation found (BR-1), on the owner's brief. Cut from 988d67d, rebased onto f6a76f1 once #187 and #188 had merged.
- **The gap.** Decision 0023 drops what a waiting taker's thunk returns, but each shell's `taker-wait!` spawned the thunk itself, and the scheduler's `enter!` keeps a coroutine's one value. A thunk that ended with no values, as one whose last call is the public `sleep-ms` does, or with two, raised there: `taker-failed` was logged and the stream closed. It is the third of its kind, after a waiting reader's piece (the M7 exit) and a taker's call (M8.2).
- **Probed first** on the libuv shell (Darwin arm64, libuv 1.52.1, three runs alike), through `make-shell` and `(shell-testing)`'s `open-client`: a thunk ending `(values)` logged `taker-failed` ("returned ~a values to single value return context"), the client read the 101 and `eof`, and the connection was gone; one ending `'done` logged nothing, stayed `handed-off` and echoed "Hi". The fake recorded the same failure and aborted.
- **Landed.** Each shell's `taker-wait!` spawns `(lambda () (thunk) #t)`, as a waiting reader's piece is spawned. The scheduler is unchanged: its other callers read the value.
- **Checks.** One in the switch suite (two fake streams) and one in the shell suite (`/door-wait-no-values`, `/door-wait-two-values`): a thunk that ends with no values, or with two, leaves its stream open, its taker reading on, nothing failed. Each red on main's shells by value; five mutation rows, each red only where predicted (m8-mutations.md, the last section).
- **Allocation.** No allocation check holds a taker. On the fake, a waiting hand-off allocates 15 to 16 B more (37,535.5 to 37,550.7 B, the median of nine runs of 300 less 100 hand-offs): the wrap's one closure, once per stream, nothing per read. The libuv shell's wrap is the same closure.
- **chez-websocket** (6caf10b) on this tree: fifteen suites, 396, the one binding check #187's entry names; nothing else moves.
- **Records.** Decision 0023's amendment of this date, CHANGELOG.md's Unreleased under Fixed, the shell suite's header.
- **Linux**, aarch64 (`chez-libuv-noble-scratch:10.4.1`) and x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`), libuv 1.48.0, every suite once: 2,090 each, #188's 2,088 and the two checks; the clients suite at status 2 with no tools built, as before.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,128 expected passes, every pin ok.

NEXT: the PR, and its closing ritual when the owner asks. The fix waits in Unreleased for the server's next release, beside the chez-libuv v0.11.0 pin and the fake's two changes; chez-websocket's pin of that release rewrites its binding check (the kept reads' entry). When main's runs start again, re-run main's latest run once. Plan §14's open list holds seven items.

**v0.6.0's entries archived, on `docs/ledger-archive-v0.6.0` (2026-10-16),** on the owner's "cut the server's next release", by the rule #159 set: a tagged release's entries move out of this file verbatim at the next release.
- **Moved.** Lines 38 to 275 at 04639fa, #174 to #184, went into `v0.6.0-progress.md`, with a six-line header naming them: the signals watched before `listening`, decision 0027, the wake value let go, the door script and its replay, their review, v0.5.0's entries archived, and v0.6.0's release, merge and tag.
- **What stays.** This file keeps:
  - its header, and the milestones' table;
  - the tagged releases' table, with a row for v0.6.0: #174 to #184, tagged on 47c787d (#184), fifty-one suites and 2,115 expected passes, from its merge entry's `make test` on main. The table's note now says v0.6.0's entries moved at v0.7.0's;
  - the entries since v0.6.0's tag, #185 to #189: lines 39 to 137.
  374 lines and 58,844 B became 137 lines and 20,756 B before this entry.
- **Proved** byte for byte by a script: 04639fa's lines 1 to 25 and 27 to 34 are this file's; its lines 35 to 37 are this file's 36 to 38; the archive past its header is its lines 38 to 275; and this file's lines from 39 on are its lines from 276.
- **Watched to fail.** Four mutants of the split, each named red and hashed before the run (sha256 44e3495d…), and each red at the segment named; the split itself green:
  - a line of text dropped from the archive: "archive differs";
  - the archive's last line, the blank, dropped: "archive differs";
  - this file's kept part read from one line late: "kept part differs";
  - the new row put after the table's blank line: "35-37 differs".
- **Records.** This entry only. No CHANGELOG entry: the ledger is the project's process, not anything a client or an embedder meets.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,128 expected passes, every pin ok. Nothing tested changed: the ledger only.

NEXT: 0.7.0's release, stacked on this, by the owner's form ("Merge #189 first (Recommended)", "0.7.0 (Recommended)", "Tag on local runs (Recommended)"). Then chez-websocket's pin to it alone, which rewrites its binding check.
