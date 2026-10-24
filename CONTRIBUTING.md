# Contributing to chez-http-server

Thanks for helping. A **small fix**, such as a typo, a doc fix, or a bug with a
test that shows it, needs only the checks below. **Bigger work**, such as a new
export, a new dependency, or a change to what the server accepts or refuses,
starts as an issue, so the design is agreed before the code is written. What
the server accepts and refuses is held to request-smuggling vectors and other
servers' strict tests, so changing it is a design decision, not a fix.

## Setup

You need Chez Scheme 10.4.1 or newer (threaded), libuv 1.48 or newer, and a
C compiler. [docs/building.md](docs/building.md) lists the rest, including
the clients the tests run.

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-http-server.git
cd chez-http-server
make test
```

`make help` lists every target.

Without the toolchain, `scripts/docker-env make test` runs any target in a
container that has all of it, and on a Guix host `scripts/guix-env make test`
does the same ([In Docker](docs/building.md#in-docker),
[On a Guix host](docs/building.md#on-a-guix-host)).

## The checks

CI runs these on every pull request, on Linux. Keep them green:

- `make test`: every suite passes (`ALL SUITES PASSED`).
- `make check-pins`: each submodule sits at its pin, and `Akku.manifest` and
  `Akku.lock` name the same versions.
- `make check-notice`: NOTICE names every submodule and test corpus.
- `make check-submodules`: `make submodules` still follows a pin when it
  moves.
- `make check-site-deps` and `make check-site`: the docs site builds, and
  every link and anchor in it resolves.
- `make check-help`: every target has a description in `make help`.

The containers have everything these need, the docs site's cmark-gfm
included.

## When you change…

- **A submodule pin:** move the pin, `Akku.manifest`'s range for it and
  `Akku.lock` (`akku lock` writes it) together, on a commit of their own.
  `make check-pins` fails until all three agree. Where akku is installed,
  `make check-akku` installs the package as a user would.
- **Third-party code or a test corpus:** name it and its license in NOTICE.
  Files under `test/vendor/` are never edited by hand; `make corpus-refresh`
  re-vendors one from upstream.
- **The Makefile:** give each new target a `## ` description, so
  `make help` lists it.
- **`docs/`:** it is for people using the server. Keep it short and plain.
  A new page goes in `docs/` and in `site/pages.sls`, the nav's order;
  `make check-site` fails until both name it.
- **The containers:** run `make check-guix` after changing `channels.scm`,
  `manifest.scm` or `scripts/guix-env*`, and `make check-docker` after
  changing `docker/dev.Dockerfile` or `scripts/docker-env*`. Both run on the
  host, not inside a container.

## Code

- Libraries are R6RS `.sls` files under `src/`, and each holds its own code:
  no shared include files.
- **Functional core, imperative shell.** The rules go in the pure libraries
  under `src/http-server/`, which import no libuv. Sockets, timers and other
  effects go in `src/http-server/private/`. `make check-imports`, a suite
  `make test` also runs, fails when a pure library imports one.
- Each export has a comment giving its type, Typed Racket style:
  `;; awaiting : (-> Answer) -> Awaiting`.
- R6RS forbids assigning an exported variable, so reach mutable state through
  procedures.
- The server runs on macOS and Linux, on x86-64 and arm64. Keep code
  portable to Windows too, which chez-libuv does not support yet. CI runs
  Linux only, so say in the pull request where you tested.
- Comments and docs say what the code does and why, in the present tense.
  They don't cite issues, pull requests, plans or dates; that history belongs
  in commits and CHANGELOG.md.

## Tests

- Write the test first, and watch it fail before you make it pass. A test
  that passes whether the code is right or wrong is worse than none.
- A change in behavior comes with a test that fails without it.
- A suite is `tests/test-<name>.sps`, written with SRFI-64, and runs through
  `run-suite` from `(testing)`, which exits with the status `make test` reads.
  `make test TESTS=tests/test-<name>.sps` runs just that suite.
- Test what the code does, never what a comment says.

## Pull requests

- Commit messages and PR titles follow
  [Conventional Commits](https://www.conventionalcommits.org): `feat:`,
  `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.
- Name branches `feat/<slug>`, `fix/<slug>`, `docs/<slug>` and so on.
- Pull requests are squash-merged, so the PR title becomes the commit's.
- A change users can see gets an entry under `## [Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md).

## How the project is developed

Feature work starts as a design in `.plans/`, and each lasting decision gets
a numbered record in `.plans/decisions/`. [AGENTS.md](AGENTS.md) holds the
project's rules in full. Following them is encouraged for features, not
demanded of small fixes.

## Security

Don't open a public issue for a suspected vulnerability.
[SECURITY.md](SECURITY.md) says how to report it privately.
