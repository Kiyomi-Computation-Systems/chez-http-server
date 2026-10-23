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

**0.7.0's release, on `chore/release-0.7.0` (2026-10-16),** on the owner's "cut the server's next release". Stacked on `docs/ledger-archive-v0.6.0`.
- **#189 first, by form** ("Merge #189 first (Recommended)"; weighed: releasing without it). #189, the entry above, squashed as 04639fa (tree 8243926, the tested head a8ecde4's; parent f6a76f1) once its run, 38907192718, was proved the billing block (0 steps, the payments annotation). Its remote branch was deleted. Its local branch was held by another session's worktree, clean at a8ecde4; that worktree was detached in place and the branch deleted. The shared checkout, clean on `main`, was fast-forwarded to 04639fa; no pin moved, so nothing rebuilt.
- **What it carries.** Every PR since v0.6.0, #185 to #189, was read against CHANGELOG.md's Unreleased, and nothing was missing:
  - the chez-libuv pins, v0.10.0 (#185) and v0.11.0 (#186), one entry under Changed;
  - the fake's kept reads (#187) and its write bound (#188), under Changed, since a taker's own tests load the fake;
  - the no-values thunk (#189), under Fixed.
- **Semantic versioning, by form** ("0.7.0 (Recommended)"; weighed: 0.6.1). No export line of the server changed since v0.6.0, and `src/` changed only in #189's two `taker-wait!`s. But the fake's door changes what a taker's tests see: chez-websocket's binding check "a send waiting when the connection ends is woken at once, before the client reads" is red on it, by #187's form. And the carried chez-libuv took `addrinfo-chain->list` out of `(libuv dns)` in v0.10.0. v0.6.0 was a minor for a change a taker sees, with no export changed.
- **The pins:** chez-libuv afe79a5 (v0.11.0), chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0 at c338a57), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Built.**
  - CHANGELOG.md: Unreleased moved under `[0.7.0] - 2026-10-16`, with an intro naming the minor, what changes and the pins.
  - A fresh, empty Unreleased above it, and `[0.7.0]` comparing v0.6.0 with v0.7.0.
  - README.org's status names v0.7.0 the current release and what it changes.
- **CI is billing-blocked.** Main's run on 04639fa, 38916351560, ended with `linux` not started (0 steps, the payments annotation). By the owner's form ("Tag on local runs (Recommended)"; weighed: waiting for CI), these runs stand in, one after another, on this branch's tree before this entry:
  - Darwin arm64, `make test`: fifty-one suites, 2,128 expected passes, every pin ok;
  - Linux aarch64 (`chez-libuv-noble-scratch:10.4.1`, libuv 1.48.0), every suite once: fifty green, 2,090 expected passes; the clients suite at status 2 with no tools built, as before;
  - Linux x86_64 under emulation (`chez-websocket-ci-amd64:10.4.1`, libuv 1.48.0), every suite once: fifty green, 2,090, the same;
  - chez-websocket's main (6caf10b), exported, its fifteen suites on this tree: 396 expected passes. The one red is the binding check above, as on #187; nothing else moved.
- **The tag.** After the merges, the billing block proved again on main's run on the release's squash, `v0.7.0` goes on that squash, annotated and signed as v0.6.0 was: "chez-http-server v0.7.0 — the test fake's door acts as the server does", its body pointing at CHANGELOG.md's `[0.7.0]`. Main's run is read once when CI returns. The merges and the tag wait for "do closing ritual".
- `make test` green before the commit (Darwin arm64): fifty-one suites, 2,128 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

NEXT: the closing ritual for both PRs, bottom-up, and the tag, when the owner asks. Then, in chez-websocket: the pin to v0.7.0 alone, which rewrites its binding check (#187's entry).

MERGED to main on 2026-10-16, on the owner's "Do closing ritual": **v0.6.0's entries archived and 0.7.0's release, as two stacked PRs** (the two entries above), bottom-up.
- **#190, v0.6.0's entries archived:** f080082 squashed as 56c1505 (tree 0e06446, the tested head's; parent 04639fa). It merged without `--delete-branch`, since #191 was based on it and the shared checkout holds `main`.
- **#191, 0.7.0's release:** retargeted to main and rebased from f080082 onto 56c1505, c290f92 becoming 815168f (tree 361c29a, unchanged), pushed with the lease read from `ls-remote`. It squashed as a9f0ef5 (tree 361c29a; parent 56c1505).
- **CI.** Billing-blocked throughout. Each run ended with its `linux` job not started (0 steps, the payments annotation): the PRs' 38917642314 (f080082) and 38917695069 (c290f92), the rebased head's 38933284838 (815168f), and main's on each squash, 38933245091 (56c1505) and 38933331846 (a9f0ef5). By the owner's form ("Tag on local runs (Recommended)"), the release entry's local runs stood in: Darwin 2,128 expected passes, Linux aarch64 and x86_64 under emulation 2,090 each, and chez-websocket's fifteen suites 396 with the one red #187 named.
- **TAGGED v0.7.0** on a9f0ef5, annotated and signed as v0.6.0 was: "chez-http-server v0.7.0 — the test fake's door acts as the server does", its body pointing at CHANGELOG.md's `[0.7.0]`. `git tag -v` read a good signature. `git ls-remote` shows the tag object a65c5b0 and its commit a9f0ef5. No GitHub Release, as for the earlier tags.
- **Branches.** Both deleted, remote and local. This session's worktree was left detached at a9f0ef5 for this reflect; the shared checkout, clean on `main`, was fast-forwarded after each squash and is again after this. No PR is open.

`make test` green on main: fifty-one suites, 2,128 expected passes, every pin ok.

NEXT: in chez-websocket, its own repository: the pin to v0.7.0 (a9f0ef5) alone. Its binding check "a send waiting when the connection ends is woken at once, before the client reads" is red on this tree, by #187's form, and is rewritten there; its other fourteen suites passed. Here, v0.7.0's entries move to `v0.7.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds seven items.

MERGED to main on 2026-10-16, on the owner's "do closing ritual": **the public-release comment sweep, four PRs, and CI without a read token, one stacked on them.** Scope by the owner's form (all four recommended): sweep `src/`, `tests/`, README.org, `docs/`, the Makefile and CI; rewrite comments as reference, history out, contracts, RFC citations and signatures kept; `.plans/` and `.superpowers/` stay in the tree, unreferenced from code and docs; no issue numbers (every upstream ask in decision 0008 had landed), a dependency version kept where behaviour needs it. CHANGELOG.md and AGENTS.md unchanged.
- **#193, README.org, `docs/`, the Makefile, CI and the vendored corpus headers:** 26e714a squashed as 3d3bb08 (tree 8cf1c04, the tested head's; parent d9d28b2), without `--delete-branch`, since #196 was based on it. README.org's status history is a features list and a pre-1.0 line; the vendored PROVENANCE and `.gitattributes` headers drop "(decision 0007)" as their recipes now write them, no corpus byte or checksum changed.
- **#196, CI clones the submodules without a read token.** The owner made chez-libuv, chez-httparse, uriparse and byte-machine public (chez-http-server itself is still private), and a fork's PR gets no secrets. Retargeted to main and rebased from 26e714a onto 3d3bb08, 890e797 becoming 430f266 (tree fdf4984, unchanged), pushed with the lease read from `ls-remote`; squashed as 00acfdb (tree fdf4984; parent 3d3bb08). Checked before: each sibling clones over HTTPS with no credentials and holds its pin (the private superproject, the control, is refused); a fresh clone with no credentials passes `make submodules` and `make check-pins`; actionlint passes. The `SUBMODULES_READ_TOKEN` secret and its PAT can go.
- **#192 `src/`, #194 the connection and shell suites, #195 the other tests:** independent of each other and off d9d28b2, on disjoint files, so not rebased. They squashed as 694d300, 977b8ef and 8554560, each parent the squash before it, each squash's patch-id the PR's (5f343cb, 1639f6c, c005145).
- **The whole.** Main's tree at 8554560, 672db1b, equals the tested union: d9d28b2 with the four sweep tips' changed paths and #196's `ci.yml`.
- **Evidence.** A Chez-reader atom diff of every changed `.sls`/`.sps` against main (watched to fail on a changed number, arity and string): no code atom differs; 37 check labels do. Non-Scheme files change `#` comment lines only, beside the corpus headers' text. Darwin arm64 `make test` on the four sweep branches together: fifty-one suites, 2,128 expected passes. One snag: `check-imports` greps source text, so a comment spelling `(http-server private waits)` failed it, and was reworded; #197, another session's, makes the audit read import forms.
- **CI.** Billing-blocked throughout. Every run ended with its `linux` job not started (0 steps, the payments annotation): the heads' 38958469604 (#192), 38958476430 (#193), 38958479773 (#194), 38958486941 (#195) and 38959021819 (#196), the rebased head's 38959596776, and main's on each squash, 38959545239, 38959666833, 38959724352, 38959763725 and 38959797469. Merged on local evidence, on the owner's word.
- **Branches.** All five deleted, remote and local. The primary checkout is on `main` at 8554560. Open: #197, whose Makefile conflicts with #193's comments above `check-imports`.

`make test` green on main: fifty-one suites, 2,128 expected passes, every pin ok.

NEXT: #197's closing ritual when the owner asks, once it is rebased onto 8554560 (its Makefile meets #193's comment block above `check-imports`). chez-websocket's pin to v0.7.0 merged there as #81 (04a68ba). For the public release, chez-http-server itself is still private. Here, v0.7.0's entries move to `v0.7.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds seven items.

**THE IMPORT AUDIT READS IMPORT FORMS, on `claude/distracted-diffie-2a436f` (2026-10-16),** for the release's comment sweep: ";;; `resolve` is (http-server private waits)'s" in `src/http-server/awaiting.sls` tripped `make check-imports`'s grep, which read text, though nothing imported the waits.
- **Built.** `tests/test-imports.sps`, a suite, holds the grep's four rules: (chezscheme) and (libuv ...) only under `src/http-server/private/`, the facade included; no (uv-testing) or (httparse test ...) in `src/`; no (libuv private ...) in `src/`; no (http-server private ...) in `src/http-server/*.sls`, and no scheduler, waits, shell or serve in the adapter. It reads each library with Chez's own reader and takes the names its (import ...) and (import-only ...) forms give, wherever they sit, through only, except, prefix, rename, for, Chez's alias, add-prefix and drop-prefix, and (library ...), its version left off; and the quoted arguments to `environment`. Each rule's message is the grep's, followed by `<path> imports <name>` lines, and the "import audit ok" line prints when all four hold. `make check-imports` runs it alone, after `build`; `make test` runs it with the others and no longer takes `check-imports` first, as with `check-close-ownership`. Design §3.3 amended.
- **Watched to fail.** With `imports` a stub, 14 checks red: every breach fixture and the read guard. On `src/`, each rule reddened on a planted import with its own message and stayed green on a planted comment naming the same library, where the old grep (HEAD's Makefile, by `make -f`) reddened on both: (chezscheme) in body.sls; (libuv) in the facade's import form; (uv-testing) and (prefix (httparse test corpus) t:) in the shell; (only (libuv private handles) loop-pointer) in the shell; (http-server private waits) in awaiting.sls; (http-server private scheduler) in the adapter. A first facade plant landed in a comment on line 37 and the new audit rightly stayed green. Mutants of the suite, each red by a named fixture or check: wrappers not unwrapped, the library escape, the version kept, `environment` not read, no import inside a definition, private/ not exempt, `pure?` reaching below `src/http-server/`, serve off the adapter's list, `starts?` as an exact match, the test-only rule off, the libuv-private rule off, files read as no imports, the tree read from `tests/`.
- **Rebased onto the comment sweep (#192-#196, reflect ec33bec).** #193 had rewritten the comment block above `check-imports` to cite no plans, so the Makefile conflicted: this one's recipe, with its comment citing no plans either, and the suite's header the same. The plantings above ran again on the rebased tree, against main's grep by `make -f`, each as before.
- `make test` green on the rebased code (Darwin arm64): fifty-two suites, 2,156 expected passes (main's 2,128 and this suite's 28), every pin ok.

MERGED to main on 2026-10-16, on the owner's "do closing ritual": **#197, the import audit reads import forms** (the entry above).
- **Before merging, main had moved twice.** #192-#196 merged and the PR conflicted in the Makefile, so it was rebased onto 8554560: the conflict was resolved and `make test` run (the entry's last two bullets). The sweep's reflect, ec33bec, then appended to this file, and the rebase onto it resolved this file as main's text followed by this entry. Every other path is byte-identical to the tested 9419225 (`git rev-parse` per path). The new head, 593cfc7, was pushed with the lease from `ls-remote`, and the PR body was brought up to date.
- **The squash:** 593cfc7 squashed as 20a112e (tree 2fcfb83, the head's; parent ec33bec), with `--match-head-commit` and without `--delete-branch`. `main` was held by no checkout (the primary checkout is on another session's `docs/agents-comment-rule`, with a `make test` running), so `git fetch origin main:main` fast-forwarded it.
- **CI.** Billing-blocked throughout. Each run's `linux` job did not start (0 steps, with the payments annotation): the heads' 38959486463 (0603ea1) and 38960424685 (593cfc7), and main's on the squash, 38960502236.
- **Branches.** `claude/distracted-diffie-2a436f` deleted, remote and local. This session's worktree is detached at 20a112e for this reflect. Open: #198 (another session's AGENTS.md rule, which touches AGENTS.md only).

`make test` green on main: fifty-two suites, 2,156 expected passes, every pin ok.

NEXT: #198's closing ritual when the owner asks. chez-websocket's pin to v0.7.0 merged there as #81 (04a68ba). For the public release, chez-http-server itself is still private. Here, v0.7.0's entries move to `v0.7.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds seven items.

MERGED to main on 2026-10-16, on the owner's "do closing ritual on 198": **#198, AGENTS.md: comments and docs cite no plans or dates** (another session's PR, one commit, AGENTS.md alone).
- **The squash:** fdff776, based on ec33bec, squashed onto 43935ce as 65e938e (parent 43935ce) with `--match-head-commit` and without `--delete-branch`, not rebased. Main's commits since its base touch no file it touches. Proved: the squash's patch-id is the PR's (f2eddea), its diff is AGENTS.md alone, and that blob is the head's (3424e11). `main` was held by no checkout (the primary checkout is on another session's `feat/examples`), so `git fetch origin main:main` fast-forwarded it.
- **CI.** Billing-blocked. Each run's `linux` job did not start (0 steps, with the payments annotation): the head's 38960563855 and main's on the squash, 38962660344.
- **Branches.** `docs/agents-comment-rule` deleted, remote and local (no worktree held it). This session's worktree is detached at 65e938e for this reflect. No PR is open.
- **`make test` on main went red once, under load.** The clients suite's keep-alive load smoke failed at 1,475 requests a second while another session's `make test` and its example server ran. The suite alone straight after was green (38 passes, 19,781 a second). Under AGENTS.md's rule it is noted in plan §14's open list and not chased.

`make test` on main: fifty-two suites, 2,155 expected passes and the one load red above; every other suite and every pin ok. The clients suite alone: 38 expected passes.

NEXT: no PR is open. chez-websocket's pin to v0.7.0 merged there as #81 (04a68ba). For the public release, chez-http-server itself is still private. Here, v0.7.0's entries move to `v0.7.0-progress.md` at the next release. When main's runs start again, re-run main's latest run once. Plan §14's open list holds eight items.

**THE DOCS SITE (decision 0028), on `docs/site` (2026-10-16),** stacked on `docs/markdown`, on the brief of the session that rewrote `docs/` (port chez-libuv's site generator so `make site` renders `docs/*.md` to `build/site/`). The pin and CI by the owner's form: "Akku.lock, as chez-libuv" (weighed: a submodule at v2.0.0, recommended; a named checkout, as chez-httparse) and "A step in the linux job (Recommended)".
- **Ported** from chez-libuv's `build-site.sps`, `site/*.sls` (io, links, pages, render, serializer, slug, template, transform, style.css), `scripts/fetch-akku-lock` and `tests/fetch-akku-lock.sh`. `site/pages.sls` lists the seventeen pages in `docs/README.md`'s "Read next" order, Home first; `repo-blob` names this repository. chez-libuv's `site/reference.sls` and `check-reference` are not ported: they check its own reference page against its exports.
- **Departures from chez-libuv's copy.** `page-file-name` lives in `(site pages)`, used by the template and the writer alike, so `tests/site-unit.sps` imports no `(site io)` and runs with no chez-cmark-gfm on its path (a planted `(cmark gfm)` import in `site/slug.sls` stopped it at import, `make` exit 2). A link's dangling test asks `registry-has?` when it has an anchor and `assoc` when it has none: chez-libuv's asked both for an anchored link, and the mutant making `registry-has?` answer #t for an absent page (L20) survived until the redundant guard went. The suites run through `(testing)`'s `run-suite`. `Akku.lock` is `akku lock`'s output for `Akku.manifest` (the bullet below).
- **Checks.** `tests/site-unit.sps` 59, `tests/site-render-unit.sps` 17, `tests/site-check.sps` seven invariants on the real `docs/` and a probe of its own link scan, `tests/fetch-akku-lock.sh` 9. Beyond chez-libuv's: an http and an https URL ending in `.md` left alone, page-naming text in a code block left alone (it replaced the `javascript:` text, which no string-rewriting mutant could change), a `../` escape pinned to the ref given, danglers in document order within and across pages, the toc's levels, the page title.
- **Watched to fail.** 69 mutants and a baseline over the three Scheme programs, each with a predicted red set per program, hashed before each run: every check and invariant reddened by at least one. One mismatch: S6 (a heading's code spans dropped) also failed the GitHub-anchor invariant, through "Waiting for a time: `sleep-ms` and `with-deadline`", whose two code spans leave a double space. The fetch script: 8 mutants and a baseline, every row red; F5 (the old tree kept) also reddened row 7 through row 6's leftover tree. Row 8 took the bsdtar branch here; its GNU tar branch runs on Linux only.
- **On Linux.** CI is billing-blocked, so the docs step ran in the local noble arm64 image (chez-libuv-noble-scratch, Chez 10.4.1, apt cmark-gfm): `make check-site-deps` 9 passes, row 8 by its GNU tar branch; `make -o deps check-site` green; `make site SITE_REF=v9.9.9` pinned the examples' links to that ref.
- **Measured.** `make site` 0.26-0.28 s for 148,622 B of HTML; each check program 0.16-0.18 s; the fetch test 0.67 s; the archive 403,224 B in 0.87 s. `make check-site` and `make check-help` green; `make test` green, fifty-three suites, 2,181 expected passes, none of them the site's.
- **One PR, by the owner's form** ("One PR (Recommended)"; weighed: two stacked, the pin then the generator), after a plan-vs-landed walkthrough: 1,847 inserted lines, about 420 of them not in chez-libuv's copies.
- **A dev-only `Akku.manifest`, on the owner's word** relayed by the parent session ("add a dev-only Akku.manifest (chez-http-server 0.7.0, depends/dev chez-cmark-gfm ^2.0.0) to #201, with a check that akku lock reproduces Akku.lock where akku works"); decision 0028 amended. `akku lock` for it wrote the committed lock byte for byte. `.akkuignore` keeps `akku install` to chez-cmark-gfm: without it, a full checkout's install linked 69 entries, vendor/'s libraries and tests among them, and chez-libuv's `site/*.sls` shadowed ours. `make check-akku-lock` compares the locks project by project and skips where akku is missing or fails a no-dependency probe; the real akku (macOS: `--version` exits 1, `lock` works) failed it on a planted sha256 and on `^9.0.0`. `tests/check-akku-lock.sh`, 11 rows with a fake akku, runs in `make check-site-deps` (green under mawk in the noble image). Watched to fail: 10 mutants and a baseline, every row red; K2's first cut (`false && probe || no-lock`) skipped every row instead and was re-cut, and K8 (first project only) also reddened row 10 through its project count.

MERGED to main on 2026-10-16, on the owner's "do closing ritual": **the examples, the Markdown docs and the docs site, three stacked PRs**, bottom-up.
- **#199, `examples/`:** five small servers (hello, echo, stream, long-poll, and file-server.sps, which serves a directory as `python3 -m http.server` does), `tests/test-examples.sps` (25 checks, each watched to fail under one of 23 mutants), and `make run ARGS=`. 8523dde squashed as baa43b3 (tree 65f2d66, the tested head's; parent e2b8301), without `--delete-branch`, since #200 was based on it.
- **#200, the guides as Markdown:** seventeen pages in chez-libuv's shape, `docs/README.md` the home; the six `.org` pages gone; `docs/performance.md` measured on an Apple M1, not carried (oha 1.16.0: 26,800-30,700 requests a second on 50 kept-alive connections; the file server at 16,200-17,300 against Python 3.14's http.server at 4,100; an idle connection 16.5-17.1 KiB). Retargeted to main and rebased from 8523dde onto baa43b3, 52948eb becoming 2bff2b9 (tree f151f78, unchanged), pushed with the lease read from `ls-remote`; squashed as ca82ff5 (tree f151f78; parent baa43b3), without `--delete-branch`, since #201 was based on it.
- **#201, the docs site** (the site session's, local_d8128bc9, started from this session's proposal): `make site` and `make check-site` (the entries above), and the dev-only `Akku.manifest` with `make check-akku-lock`. Its two commits, bc225b2 and fcb195f, were rebased detached from 52948eb onto ca82ff5, becoming 44f93a1 (tree 5f5ba62, unchanged), and pushed to `docs/site` with the lease; squashed as 427e377 (tree 5f5ba62; parent ca82ff5), one message from both commits.
- **CI.** Billing-blocked throughout. Every run ended with its `linux` job not started (0 steps, the payments annotation): the heads' 38966103096 (8523dde), 38966107405 (52948eb) and 38976182649 (fcb195f), the rebased heads' 38986534275 (2bff2b9) and 38986596584 (44f93a1), and main's on each squash, 38986510723, 38986570274 and 38986625645. Merged on local evidence, on the owner's word.
- **Branches.** All three deleted, remote and local. `docs/site` was held by the site session's worktree (festive-kepler-ff14e6, clean at fcb195f), which was detached in place before `branch -D`. The primary checkout is on `main` at 427e377. No PR is open.

`make test` green on main: fifty-three suites, 2,181 expected passes, every pin ok. `make check-site` green.

MERGED to main on 2026-10-16, on the owner's "do closing ritual": **#202, `docs/performance.md` beside Racket's web server.** The owner asked whether we had measured against Racket's HTTP server (we had not: Python's http.server was the only peer), then "yes please". Racket v9.3 CS with web-server-lib 1.13, a servlet answering `Hello\n` and the files dispatcher on the 254-byte file, under oha 1.16.0 with the two servers taking turns: with keep-alive ours answered 1.7-2.9 times as many requests (hello at 50 connections 33,100-33,800 against 11,600-12,800 a second); without it at most 1.3 times apart, Racket's a little ahead on hello at 50. Racket's server ran on one OS thread at about 96% CPU, so both are one core. The page's Racket snippet was run as printed. dede87e squashed as dfdf6df (tree cac1190, the tested head's; parent d14f389) with `--delete-branch`, which switched the checkout to main and deleted the branch, local and remote. CI billing-blocked: the head's 38988611880 and main's 38988876158 each a `linux` job not started (0 steps, the payments annotation); merged on local evidence. `make test` green on main: fifty-three suites, 2,181 expected passes, every pin ok; `make check-site` green. Not re-measured: the page's line that Python's http.server is a little faster than the file server on one connection without keep-alive (2,700 against 3,100 then; 3,400 here today), all single 2-second runs.

MERGED to main on 2026-10-17, on the owner's "do closing ritual": **#203, `docs/performance.md` beside Node, and the Python one-connection claim corrected.** The owner asked whether we had compared against Node (only M8.4's spike, 2026-10-04, in `.plans/research/spike/`, never on the page), then "yes please", then "verify the python claim". Node 26.0.0 (Homebrew): `http.createServer` for hello and a 16-line `fs.createReadStream` file server, printed on the page and run as printed; with the two servers taking turns, hello within 10% in every row; the file Node 1.2-1.3 times ahead at 50 kept-alive connections, where it kept 1.65 cores busy over a 3-second sample (fs work on libuv's thread pool), ours ahead in the other three rows. The Python claim ("a little faster" on one connection without keep-alive) had come from one 2-second run each, ours a noisy one (99th percentile 1.52 ms); three rounds taking turns put the two even, 3,200-3,500 a second here against 3,100-3,200, ours ahead in two, so the page now says so and counts each column's runs. f3479d8 (atop 89176c6) squashed as 8b07bd4 (tree 6aaf984, the tested head's; parent 036925d) with `--delete-branch`, which switched the checkout to main and deleted the branch, local and remote. CI billing-blocked: the head's 38992713621 and main's 39026461225 each a `linux` job not started (0 steps, the payments annotation); merged on local evidence. `make test` green on main: fifty-three suites, 2,181 expected passes, every pin ok; `make check-site` green.

---

**THE GUIX DEVELOPMENT CONTAINER, on `chore/guix-env` (2026-10-17),** decision 0029. The owner asked for "a Guix profile similar to chez-libuv and chez-cmark-gfm", so that Guix users "launch and develop this project in a guix container". By form: "Always network (cmark-gfm)" (weighed: an offline default with a `--network` opt-in, recommended, and chez-libuv's always-offline container).
- **Built:**
  - `channels.scm`, the peers' pin, b532aa7d;
  - `manifest.scm`: chez-libuv's Chez 10.4.1 variant unchanged, which shares its store item, then libuv-for-node-lts 1.52.1, gcc, the clients, vtest2's libraries, cmark-gfm, git and nss-certs;
  - `scripts/guix-env`, `scripts/guix-env-enter`, `scripts/guix-env-selftest`, and `scripts/guix-env-nsswitch.conf`;
  - `tests/guix-env-launcher.sh` (80 checks) and `make check-guix`;
  - docs/building.md's "On a Guix host", a line in README.org, AGENTS.md's "Guix development container", and CHANGELOG.md's Unreleased, under Added.
- **Found on the way.** `--network` brings the host's `/etc/nsswitch.conf`. This host's names NSS modules the container's glibc 2.41 cannot load, so test-shell's lookup row got `EAI_SYSTEM` for `a..b`, not `EAI_NONAME`: the one failure in a fresh checkout's first `make test` in the container. The launcher now mounts `scripts/guix-env-nsswitch.conf` (files, dns) over it. `--emulate-fhs` is kept for chez-cmark-gfm's library search; without it, `make check-site` raised `&cmark-library-unavailable`.
- **Measured** (x86_64, this host):
  - a fresh checkout's `scripts/guix-env make test`, cloning the submodules, building the shim and vtest2 and fetching oha: 72 s;
  - `make check-guix`: 87 s, all green, `make test` at fifty-three suites and 2,181 expected passes, main's counts, and `make check-site` green.
- **Watched to fail** (decision 0029's Measured section):
  - 10 launcher mutants, 6 for the entry script, and 18 container runs, each failing its self-test assertion by name. Unwatched: chez-floor's empty-ci.yml branch, libuv-floor's vendored and not-in-the-store branches, and make-check-help and make-check-site-deps;
  - one full run without the nsswitch mount and with a broken docs anchor, which failed `nsswitch`, `make-test` and `make-check-site`.
  - T16's "says why" caught its own case: `env` took the launcher's path, which holds an `=`, for a variable assignment.

- **The read-only review** (Opus) found one defect. `make check-guix` failed on a fresh clone: `libuv-floor` read chez-libuv's Makefile before any submodule was cloned. The self-test now runs `make submodules` first, and that branch was watched failing offline. The review's other findings were wording and coverage, and all were taken:
  - docs/building.md's first-run time now includes fetching the pinned Guix;
  - it now says a worktree shares the main repository's `.git`;
  - README.org's link dropped the Markdown anchor;
  - the nsswitch assertion's comment now says it checks the mount;
  - the launcher's 80 checks now run on a host without guix;
  - the unwatched branches are named above.
- **A fresh clone's `make check-guix`**, with the fix: 75 s, all green, fifty-three suites, 2,181 expected passes, and `make check-site` green.
- **More in `docs/`, on the owner's ask** ("We should add mention of the guix container to the `docs/`"):
  - docs/installing.md points a Guix host at `scripts/guix-env` from "What you need";
  - docs/README.md's "Read next" says building works with or without Guix;
  - docs/building.md says a server run inside answers on the host, and that the environment stays out but for `TERM`, `COLORTERM` and `LANG`.
  - Both facts were checked before they were written. The host's curl got `Hello` from `make run` in the container. A host `CHEZ_HTTP_PORT` arrived unset, and `env CHEZ_HTTP_PORT=3000` set it.
  - The new anchor was broken once to watch `make check-site` name it.

MERGED to main on 2026-10-17, on the owner's "do closing ritual": **#204, the Guix development container.** 467024b squashed as 3b86051 (tree 6145a96, the tested head's; parent cf3cf7d) with `--match-head-commit` and `--delete-branch`, which switched the checkout to main and deleted the branch, local and remote. CI billing-blocked: the head's 39045303447 and main's 39053174414 each a `linux` job not started (0 steps, the payments annotation); merged on local evidence, the fresh clone's `make check-guix` above. On main: `tests/guix-env-launcher.sh` 80 passed, and in the container every pin ok and `make check-site` green.

---

**THE DOCKER DEVELOPMENT CONTAINER, on `chore/docker-env` (2026-10-17),** decision 0030. The owner asked for Docker "so non-Guix developers can easily work on this without installing all of the deps on their host machines". By form: "Launcher script (Recommended)" (weighed: the launcher with a devcontainer, and a compose file); "Opt-in port (Recommended)" (weighed: host networking, and always publishing 8080); "Document make clean (Recommended)" (weighed: detecting a switch and cleaning, or refusing).
- **Built:**
  - `docker/dev.Dockerfile`: ci.yml's linux job as an image, Ubuntu 24.04, its apt line and ca-certificates, Chez from `v$CHEZ_VERSION` as ci.yml builds it, `CHEZ=scheme`;
  - `scripts/docker-env`, guix-env's interface: it builds the image when missing, named for the floor and a cksum of the Dockerfile, then runs as the host user with only the checkout mounted (and a worktree's common directory), HOME `/tmp`, and the terminal's three variables; `-p PORT` publishes 127.0.0.1:PORT and sets `CHEZ_HTTP_HOST=0.0.0.0` and `CHEZ_HTTP_PORT` inside;
  - `scripts/docker-env-selftest`, `tests/docker-env-launcher.sh` (113 checks against a fake docker), `tests/docker-env-publish.sh`, and `make check-docker`;
  - docs/building.md's "In Docker", docs/installing.md and docs/README.md pointing there, a line in README.org, AGENTS.md's "Docker development container", and CHANGELOG.md's Unreleased, under Added.
- **Found on the way:**
  - A checkout last built by the Guix container failed test-shell and test-clients in Docker: chez-libuv's `config.sls` named Guix's libuv, and `build/vtest` was linked against Guix's glibc. chez-libuv relinks on a change of acquisition mode, not of libuv's path. `make clean` fixed it, and the owner chose to document that.
  - GNU make passes SIGTERM to no recipe, so a SIGTERM to the launcher ends the container without draining the server. Ctrl-C at a terminal drains it, watched under a pseudo-terminal.
  - `--mount` breaks on `,` and `"` unquoted; CSV-quoted, every path tried mounts.
  - **A checkout path with a space builds nowhere,** in or out of a container: `make deps` assigns `src=$(abspath $(SRFI_DIR))` unquoted. Not fixed here; a separate change.
- **Measured** (x86_64, 18 cores, Docker Engine - Community 29.8.1 on Pop!_OS 22.04, not Docker Desktop: no file-sharing layer):
  - the first image build 150 s, 789 MB; a later start 0.29 s;
  - the self-test after `make clean` 67 s, and as uid 501:20 with no passwd entry, on a volume (not a bind mount), 68 s, both green;
  - a fresh clone's `make check-docker` before the review: 75 s, all green, fifty-three suites, 2,181 expected passes, `make check-site`, and both publish checks.
- **Watched to fail** (decision 0030's Measured section): 18 launcher mutants; 17 self-test runs in the container, each failing its assertion by name; the make loop on the Guix-built checkout; the self-test on the host. Unwatched: libuv-floor's "chose not pkg-config" and "not under /usr/lib" branches.
- **The read-only review** (Opus, 154,552 tokens, 35 tool uses, about 12 min) found, each reproduced: the records called this host's engine Docker Desktop's (buildx's `docker-desktop://` link misled; corrected); a Docker-config proxy reached the container, `HTTP_PROXY` with its password, and failed `isolated-env` (now allowed, and the docs name it); the container reached this host's sshd through the gateway ("sees" became "mounts", and the docs say it is not a sandbox); installing.md's "skip the list" covered using the server from one's own project; the docs' git claims ignored the mounted `.git/config`; with Docker not started the launcher announced a build (it now checks the daemon); the `--mount` expectation copied the launcher's quoting, and `--tty` was untested (a hand-spelled check, and three `script` cases); `network` counted interfaces (it now asks https://github.com/); `host-user` trusted the checkout's reported owner (it now compares a written file's); the "set a variable" example had no `-p`. Not reproduced, not acted on: a docker-container buildx driver would not load the image. After it, 4 launcher mutants and 4 container runs failed by name, and a fresh clone's `make check-docker` was green again in 76 s.
- **Untested:** Docker Desktop's file sharing on any OS (Mac included), arm64 (no emulation on this host), rootless Docker, Podman and SELinux.
- **The checkout here is now Docker-built.** Before the next `scripts/guix-env make test`, run `make clean`.

MERGED to main on 2026-10-17, on the owner's "do closing ritual": **#205, the Docker development container.** ac9df35 squashed as db73a1f (tree 65c0695, the tested head's; parent d3bb7f4) with `--match-head-commit` and `--delete-branch`, which switched the checkout to main and deleted the branch, local and remote. CI billing-blocked: the head's 39063240128 and main's 39063309342 each a `linux` job not started (0 steps, the payments annotation); merged on local evidence, the fresh clone's `make check-docker` above. On main: `tests/docker-env-launcher.sh` 113 passed, `tests/guix-env-launcher.sh` 80, and in the container `make check-pins` and `make check-site` green.

NEXT: the next release carries CHANGELOG.md's Unreleased (the examples, the Markdown docs, the docs site and its Akku.manifest, the Guix container and the Docker one), with v0.7.0's entries moved to `v0.7.0-progress.md`. For the public release, chez-http-server itself is still private. When main's runs start again, re-run main's latest run once; the docs step in CI then runs for the first time. Open: the `make deps` space-in-path bug, when the owner asks for it.

---

**THE AKKU PACKAGE, on `chore/akku-package` (2026-10-23),** decision 0031. The owner: "The following akku packages are now published: Chez-libuv, Chez-httparse, Chez-uri". By form: "Package it, keep submodules (Recommended)" (weighed: replacing the submodules with Akku, and only moving the pins).
- **The index,** fetched with a good signature from the Akku archive's 2018 key: chez-libuv 0.11.0 (its install hook in `scripts`), chez-httparse 0.5.0, chez-uri 0.8.0 (the uriparse repository's package) and byte-machine 0.8.0. Each archive's sha256 is the index's.
- **The pins, a commit of their own:** chez-httparse v0.4.5 → v0.5.0 (52a62e5) and uriparse v0.6.2 → v0.8.0 (9416299), each carrying byte-machine c1f7791 (v0.8.0). Both tags are signed with key 6362A78F…, which signed v0.4.5 and v0.6.2. This host has no copy of the public key, so the signatures themselves were not checked. Both commits are on their repositories' main. `make test` passed in Docker (libuv 1.48.0) and in the Guix container (libuv 1.52.1): fifty-three suites, 2,181 expected passes each, each suite's count main's. The whole-server GET allocates 5,159 B in Docker against 5,131 to 5,158 B before, and 5,139 B under Guix.
  - Trap: `make test` runs `git submodule update`, which put an unstaged gitlink back on the recorded commit. Stage a pin before you test it.
- **Built:**
  - `Akku.manifest`'s `depends`: chez-libuv `^0.11.0`, chez-httparse `^0.5.0`, chez-uri `^0.8.0` and byte-machine `^0.8.0`. `src/` imports `(byte-machine runtime)` and `(byte-machine private conditions)` itself;
  - `Akku.lock` remade by `akku lock` (akku 1.1.0, from Guix): five projects, chez-libuv's carrying its hook;
  - `.akkuignore` without `src`, and `.gitattributes` export-ignoring `.plans`, `.superpowers` and `AGENTS.md`;
  - `scripts/check-akku-manifest.ss` in `make check-pins`, with `AKKU_VENDORED` mapping each package to its vendored copy, and `tests/check-akku-manifest.sh` (14 rows) in `make check-site-deps`;
  - `scripts/check-akku` and `make check-akku`, which runs `make check-akku-lock` first;
  - docs/installing.md's "With Akku", docs/building.md's "The Akku package", docs/README.md, README.org, AGENTS.md's Dependencies, CHANGELOG.md's Unreleased (Added, and the pins under Changed). CHANGELOG.md's two relative `.plans` links now point at GitHub, since archives leave `.plans` out;
  - decision 0031, and 0028's dev-only manifest marked superseded.
- **Found on the way:**
  - `akku lock` on a consumer that depends on a directory locks that directory alone: Akku takes a package's dependencies only from its index. So `check-akku` writes the consumer's lock itself, from `Akku.lock`'s entries.
  - Akku leaves `tests/*.sls` out with or without `.akkuignore`, but installs `site/*.sls` unless `.akkuignore` names `site`.
  - akku 1.1.0 asked nothing on a pipe.
- **Watched to fail** (decision 0031's Mutation testing section):
  - all 15 mutants of the manifest check, after three loose rows were tightened; two of them came after the review;
  - 10 of 11 `check-akku` mutants, each by the check named. The survivor, `tests` out of `.akkuignore`, is equivalent.
- **Measured:**
  - `make check-akku`, about 20 s with the archives cached;
  - `make check-docker`, 66 s, all green: the launcher, the container (every pin, the manifest at its pins, fifty-three suites, `check-site-deps` and `check-site`), and both publish checks;
  - `make check-akku-lock` with the real akku: Akku.lock is `akku lock`'s output (5 projects).
- **The read-only review** (Opus, 231,523 tokens, 75 tool uses, about 16 min) found no high-severity defect. Each finding was reproduced, then acted on:
  - the docs offered `akku install chez-http-server`, which fails until a release is on the index. installing.md now says the route needs one, and shows how to look (`akku show` answers a missing package with a backtrace; `akku list | grep` does not); README.org drops the command;
  - building.md promised the code the suites ran against, though a later patch meets the range;
  - `make check-pins` failed with `make: chez: No such file or directory` where Chez is `scheme`. It now names `CHEZ=scheme`, and installing.md says every `make` command takes it there;
  - the version check was undocumented;
  - `check-akku` did not check the lock first;
  - three stale comments;
  - the manifest check passed duplicate `depends` entries and an empty `AKKU_VENDORED`. Two rows were added and watched to fail, then the check was fixed.

  Moot: `.gitattributes` staged beside the pins, since the pin commit comes from the tree saved before (a97859d), and the untracked new files. Its "not measured" consequence was measured after: `akku install` in a copy of the tracked files installs the checkout's 26 entries, the dependencies and chez-cmark-gfm, and `make site` then writes seventeen pages from `.akku/lib` in an `--emulate-fhs` Guix container.
- **After the review:** in the Guix container, `check-help`, `check-pins`, `check-site-deps` and `check-site` are green; `make check-akku` is green.
- **Untested:** `make check-akku` on macOS, with Akku 1.1.1, and on arm64.
- **The checkout here is now Guix-built.** Before the next `scripts/docker-env make test`, run `make clean`.
- **Open:** publishing chez-http-server to the Akku index is a release step, from the tag. Until then, `akku install chez-http-server` finds nothing.

MERGED to main on 2026-10-23, on the owner's "Let's go ahead and do the closing ritual": **the pins and the Akku package, as two stacked PRs** (the entry above), bottom-up. The owner made this repository and chez-websocket public first, so CI runs again.
- **#206, the pins:** e114bfd squashed as baae015 (tree a97859d, the tested head's; parent f833fb5) with `--match-head-commit` on the full SHA, and without `--delete-branch`, since #207 was based on it.
- **#207, the package:** retargeted to main and rebased from e114bfd onto baae015, 844cfe4 becoming 18f45b7 (tree 33c65a4, unchanged), pushed with the lease read from `ls-remote`. It squashed as 710e0fe (tree 33c65a4; parent baae015) with `--delete-branch`.
- **CI, running again.** Each PR's run, billing-blocked when pushed, was re-run once the repository was public, and passed: 40000128625 on e114bfd (11 min, Chez built from source) and 40000165586 on 844cfe4 (4.5 min, Chez from the cache), each with `ALL SUITES PASSED`, `check-site` all green and `make check-help`, #207's with the manifest check's `akku ok` lines and its 14 rows. The rebased head's tree is the one tested, so no run on 18f45b7 was waited for. Main's run on baae015, 40037767107, was cancelled by the one on 710e0fe, 40037814899, which passed (`ALL SUITES PASSED`, the docs step, `check-help`): main's first green run since the billing block, and its docs step's first run.
- **Branches.** Both deleted, remote and local. The shared checkout fast-forwarded to 710e0fe. It is Guix-built: `make clean` before the next `scripts/docker-env make test`.

NEXT: the next release carries CHANGELOG.md's Unreleased (the examples, the Markdown docs, the docs site, the Guix container and the Docker one, the pins and the Akku package), with v0.7.0's entries moved to `v0.7.0-progress.md`, and publishes the package to the Akku index from its tag. Open: the `make deps` space-in-path bug, when the owner asks for it.
