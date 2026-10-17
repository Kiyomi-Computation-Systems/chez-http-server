# AGENTS.md

## Project guidelines

### Architecture & portability

* Use the functional core / imperative shell pattern
* Follow the 12 Factor Apps philosophy
* Project is built for Chez Scheme
* Project should be portable across macos (darwin), linux, and windows
* Project should be portable across amd64 and arm64
* **DO NOT** setup macos CI runners: linux only!
* Exported functions should have a comment with a Typed Racket style type signature

### Dependencies

* chez-libuv https://github.com/Kiyomi-Computation-Systems/chez-libuv
* chez-httparse https://github.com/Kiyomi-Computation-Systems/chez-httparse
* uriparse https://github.com/Kiyomi-Computation-Systems/uriparse

### Layout, process & libraries

* Plans live in `/.plans`, decision records in `/.plans/decisions`
* Code comments, `README.org` and `/docs` describe the code as it is: never
  cite a plan, milestone, decision record, design or plan section, review,
  date, or PR or issue number. State the fact or the reason itself, in the
  present tense. History belongs in `/.plans`, the ledger, `CHANGELOG.md`
  and git. RFC sections and dependency versions are fine.
* The subagent-driven development ledger lives in `/.superpowers/sdd/` —
  `progress.md` is the spine and `global-constraints.md` binds every task
  brief. Read both before starting slice work; close-outs are recorded there.
  A closed milestone's entries live in its `mN-progress.md`, beside its
  `mN-mutations.md`. A tagged release's entries live in its
  `vX.Y.Z-progress.md`, moved out of `progress.md` verbatim at the next
  release.
* Add entries to `CHANGELOG.md` for each release
* `/docs` is for user facing documentation only.
* Documentation should be very concise, focused, to the point, ELI5 style.
* `Makefile` should have a `help` command which lists all of its commands
* Libraries are R6RS `.sls`; libraries and programs contain their own code —
  no shared include bodies. R6RS forbids assigning an exported variable —
  reach mutable state through procedures.

### Testing & mutation discipline

* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
* A test is not finished when it passes. It is finished when you have watched
  it fail.
* Prefer a check to a comment.
* **Do not** write tests that rely on reading code comments
* Chase a timing flake only when it fails on CI, or locally with no added load.
  One seen only under synthetic load (suites or containers run at once) gets a
  line in the plan's open list, not a fix, and a soak raises no follow-up
  tasks.

### Guix development container

* On a Guix host, run every build and test through `scripts/guix-env`,
  e.g. `scripts/guix-env make test`; a bare `make` there has no `chez`.
  Batch with `scripts/guix-env sh -c 'make a && make b'`: each call takes
  a few seconds to start. With no command and no terminal, it exits at
  once.
* Edit, commit and push on the host. The container has git and the
  network, but no identity, credentials or agent, and nothing of `HOME`.
* The container exports `CHEZ` (the real `scheme` binary) and `CC` (gcc;
  the toolchain has no `cc`), and mounts `scripts/guix-env-nsswitch.conf`
  over the host's `/etc/nsswitch.conf`. In a linked worktree it also
  shares the main repository's `.git`.
* Verify a change to `channels.scm`, `manifest.scm` or the `guix-env`
  scripts with `make check-guix`, run on the host.

## Closing ritual

We run this when we're done and ready to merge the PR.

**Important**: ALWAYS ask before running this.

1. Squash merge the PR.
2. Catch up local `main`.
3. Clean up branches. Delete the merged branch locally and on the remote.
4. Reflect.
