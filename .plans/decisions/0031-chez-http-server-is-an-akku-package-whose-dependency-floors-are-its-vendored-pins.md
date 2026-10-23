# 0031: chez-http-server is an Akku package whose dependency floors are its vendored pins

Date: 2026-10-23
Status: accepted (user decision, 2026-10-23, by form: "Package it, keep submodules (Recommended)")
Plan: none; follows the owner's word that the runtime dependencies are on the Akku index

## Context

The owner, in their words: "The following akku packages are now published: Chez-libuv,
Chez-httparse, Chez-uri". Decision 0028's `Akku.manifest` is for development only,
because the index did not list the server's runtime dependencies, and says so.

The index, fetched 2026-10-23 (`akku update`: a good signature from the Akku archive's
2018 key), lists:
- **chez-libuv 0.11.0**, with its install hook in `scripts`, run in pre-install on
  darwin and linux;
- **chez-httparse 0.5.0** and **chez-uri 0.8.0** (the uriparse repository's package),
  each depending on byte-machine `^0.8.0`;
- **byte-machine 0.8.0**.
Each archive downloaded has the sha256 the index records.

The pins were chez-libuv v0.11.0, the index's, and chez-httparse v0.4.5, uriparse
v0.6.2 and byte-machine v0.7.0, each below it. An Akku caret range on 0.x admits only
its own minor, so `^0.4.5` cannot be met from the index. The libraries under `src/`
import chez-libuv, chez-httparse, uriparse's `(uri ...)` and, in
`src/http-server/private/`, `(byte-machine runtime)` and
`(byte-machine private conditions)`.

Each sibling keeps its submodules for development, and ships an `Akku.manifest` whose
dependency floors are the versions it vendors. chez-httparse's `docs.akku-manifest`
lane and uriparse's `uri.docs.akku-manifest` lane hold them there, and each sibling's
`make check-akku` installs the package into a throwaway consumer.

Weighed, by the owner's form:
- **package it, keep the submodules** (recommended);
- **replace the submodules with Akku.** It would touch `check-pins`, the Makefile's
  build, CI and both containers, which would then need akku, and no sibling does it;
- **only move the pins.**

Measured 2026-10-23 on the Linux host (Pop!_OS 22.04, x86_64):
- **The pins.** chez-httparse v0.5.0 is 52a62e5 and uriparse v0.8.0 is 9416299. Both
  tags are signed with key 6362A78F…, which also signed v0.4.5 and v0.6.2. The host
  has no copy of that public key, so the signatures themselves were not checked. Each
  commit is on its repository's main branch, and both vendor byte-machine at c1f7791,
  its v0.8.0.
- **The pins' changes.** chez-httparse's changelog: six lines of the generated message
  parser change, so a digit's overflow check needs no bignum; its URL parser is
  byte-identical. uriparse's: v0.7.0 adds `(uri easy)` and `(uri query)`; v0.8.0
  changes no library.
- **The suites on the new pins.** In the Docker container (Ubuntu 24.04, Chez 10.4.1,
  libuv 1.48.0): `make check-pins` and `make test` passed, with fifty-three suites and
  2,181 expected passes, each suite's count main's. The clients suite's GET through
  the whole server allocates 5,159 B. The Docker runs on the old pins gave 5,131 to
  5,158 B.
- **Akku.** akku 1.1.0, from Guix. `akku lock` for the new manifest locks five
  packages, each at the vendored version, and copies chez-libuv's hook into its
  entry. A consumer that depends on a directory gets, from `akku lock`, that
  directory alone: Akku takes a package's own dependencies only from the index.
- **What installs.** Akku installs no library from `tests/` whether `.akkuignore`
  names it or not: it takes a `tests` directory for test code. It installs `site/`'s
  eight unless `.akkuignore` names `site`.
- **`make check-akku`.** In a Guix shell with `manifest.scm`'s toolchain it takes
  about 20 s with the archives cached. It installs 25 libraries from `src/`, and
  `examples/hello.sps` on Akku's library path answers `Hello` and exits 0 on SIGTERM.

## Decision

1. **The pins move to the index's versions,** on a commit of their own:
   chez-httparse v0.5.0 and uriparse v0.8.0, with byte-machine v0.8.0 through both
   carriers.
2. **`Akku.manifest` names the runtime dependencies:** chez-libuv `^0.11.0`,
   chez-httparse `^0.5.0`, chez-uri `^0.8.0` and byte-machine `^0.8.0`. byte-machine
   is named because `src/` imports it itself. Each floor is the vendored version.
   chez-cmark-gfm stays a development dependency. The manifest has no `scripts`:
   chez-libuv's hook reaches a consumer through the index's lock entry.
3. **The submodules stay** for development, CI and both containers.
4. **`make check-pins` holds the manifest to the pins.** It now needs Chez, and
   names `CHEZ` when there is none. It runs `scripts/check-akku-manifest.ss`,
   which checks four things:
   - the package's version is CHANGELOG.md's latest release;
   - `depends` names exactly the packages `AKKU_VENDORED` maps to a vendored copy,
     each once;
   - each of those has the range `^VERSION`, where VERSION is the version that copy's
     own `Akku.manifest` declares under the same name;
   - `Akku.lock` locks each of them at that version.

   `tests/check-akku-manifest.sh`, fourteen rows on trees of its own, runs in
   `make check-site-deps`, which CI runs.
5. **`.akkuignore` no longer names `src`,** and **`.gitattributes` marks `.plans`,
   `.superpowers` and `AGENTS.md` export-ignore,** so release archives, the Akku
   package's among them, leave them out.
6. **`make check-akku`** (`scripts/check-akku`) needs akku, so it is opt-in and not
   in CI. It runs `make check-akku-lock` first. It installs a `git archive` of the
   checkout into a scratch consumer, beside `Akku.lock`'s own entries for the
   dependencies. It then checks five things:
   - the archive leaves out `.plans`, `.superpowers` and `AGENTS.md`, and holds the
     server;
   - chez-libuv's hook builds its shim into the consumer's `.akku/ffi`;
   - this package installs exactly `src/`'s libraries;
   - each package installed libraries, and no other package did;
   - `examples/hello.sps`, on Akku's library path alone, answers `Hello`, then stops
     on SIGTERM.
7. **Publishing to the index is part of a release,** from its tag, and is not done
   here. docs/installing.md says the Akku route needs a release on the index, and
   how to see whether there is one.

## Consequences

- From the index, `akku install chez-http-server` gives a project the server, its
  four dependencies and a release shim built by chez-libuv's hook. That needs libuv
  1.48 or newer where pkg-config sees it, since the hook has no vendored libuv to fall
  back on, and a project path make can take.
- Moving a pin now takes three edits on one commit: the submodule, its range in
  `Akku.manifest`, and `akku lock`. `make check-pins` fails until all three agree.
- A dependency's patch release on the index meets the range, so a consumer gets it
  before the suites here have run on it. Where akku sees that release,
  `make check-akku-lock` fails until `Akku.lock` is made again, and then
  `make check-pins` fails until the pin moves.
- The server imports `(byte-machine private conditions)`, a library byte-machine
  does not promise to keep. The caret range lets in a byte-machine 0.8.x that renames
  it.
- `akku install` in a checkout now also installs the four dependencies, runs
  chez-libuv's hook, and installs the checkout's own 26 library entries into
  `.akku/lib`. Measured in a copy of the tracked files: `cmark/gfm.sls` lands, and
  `make site` takes `.akku/lib` and writes all seventeen pages, in a Guix container
  with `--emulate-fhs`. A plain `guix shell` finds no libcmark-gfm for either route.
- Untested: `make check-akku` on macOS, with Akku 1.1.1, and on arm64.

## Mutation testing

- **`scripts/check-akku-manifest.ss`: fifteen mutants, each failing
  `tests/check-akku-manifest.sh`.** Two came after the review, one disabling each
  of its new guards. The first run had three survivors, each a row too
  loose, so each row was tightened:
  - the floor row's lock disagreed too, so the lock check named the floor first;
  - the caret row's `^` matched another line's;
  - the prefix row asked only for a failure, not its reason.
- **`make check-akku`: eleven mutants.** Ten were caught, each failing the check named:
  - `src` back in `.akkuignore`: the library diff, every library missing;
  - `site` out of `.akkuignore`: the library diff, `site/*.sls` extra;
  - `.superpowers` shipped, and `AGENTS.md` shipped: the archive check;
  - the hook dropped from chez-libuv's lock entry: the hook check;
  - byte-machine out of `depends`: `hello.sps` exited before it listened;
  - chez-uri absent from `Akku.lock`: the consumer's lock;
  - the check installing every locked project: the package diff, chez-cmark-gfm
    extra;
  - `hello.sps` answering `Hullo`: the answer check;
  - the check sending no SIGTERM: the stop check, after its 30 s.

  `tests` out of `.akkuignore` survived. It is equivalent: Akku leaves `tests/` out
  itself.

## Review

A read-only adversarial review on Opus found no high-severity defect. Each finding
was reproduced, and then:
- **The docs offered `akku install chez-http-server`, which fails today:** the index
  has no such package, and cannot before a release. docs/installing.md now says the
  route needs a release on the index, and README.org no longer gives the command.
- **building.md said an Akku install gets the code the suites ran against:** a later
  patch also meets the range. It now says so.
- **`make check-pins` needs a Chez called `chez` by default:** on a host whose Chez
  is `scheme` it failed with `make: chez: No such file or directory`. `make run` and
  `make test` already needed the same. It now names the fix, and
  docs/installing.md says each `make` command takes `CHEZ=scheme` there.
- **The version check was undocumented;** building.md and CHANGELOG.md now name it.
- **`check-akku` tested `Akku.lock`'s versions without checking the lock;** it runs
  `check-akku-lock` first. Its third check guards the lock it writes as much as
  the package, and its comment now says so.
- **Three comments were stale** (.gitignore, scripts/check-akku-lock, the docs
  site's paragraph in building.md), and are corrected.
- **The manifest check passed** two identical `depends` entries, and passed with no
  NAME=DIR given. Each is now a test row, watched to fail, and refused.

Two findings needed nothing:
- The review saw `.gitattributes` staged with the pins. The pin commit is made from
  the tree saved before it was staged.
- The new files were untracked; they are committed with the package.

