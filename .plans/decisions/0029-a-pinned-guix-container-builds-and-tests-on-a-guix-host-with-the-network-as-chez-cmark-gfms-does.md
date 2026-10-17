# 0029: a pinned Guix container builds and tests on a Guix host, with the network, as chez-cmark-gfm's does

Date: 2026-10-17
Status: accepted (user decision, 2026-10-17, by form: "Always network (cmark-gfm)"; weighed: "Offline + --network opt-in (Recommended)" and "Always offline (chez-libuv)")
Plan: none; the owner asked for it directly

## Context

The owner, in their words: "I want to set this project up with a Guix profile similar to
chez-libuv and chez-cmark-gfm which are also on this machine. Guix users should be able to
launch and develop this project in a guix container."

The machine is x86_64 Linux, a foreign distro (Ubuntu 22.04's glibc 2.35) with Guix Home at
`b532aa7d…`. It has no `chez`: Guix Home's `scheme` is 10.4.0, below the floor. It has no
`ab` either.

The peers each have a pinned container, `scripts/guix-env`, and differ on the network:
- **chez-cmark-gfm** (its ADR-0018 and ADR-0019): `--network`, `CHEZ` set by a search-path
  package, Guix's own Chez.
- **chez-libuv** (its ADR-0020, copied from chez-curl's ADR-0006): no network. It also has
  `scripts/guix-env-enter`, which exports `CHEZ` and `CC`, a Chez 10.4.1 variant of Guix's
  recipe, `libuv-for-node-lts`, git in the container, the git common directory shared for a
  linked worktree, and a self-test with eleven assertions.

What this repository needs that neither has in full:
1. **Chez 10.4.1, threaded, and libuv 1.48.0 or later**, which are chez-libuv's needs too.
2. **git**, for `make submodules` and `make check-pins`.
3. **The clients `make test` runs:** curl and ab. vtest2 is built from its pin with gcc,
   pcre2, zlib, python3 and awk. oha's release binary is fetched at its pin; it is static-pie,
   so it runs anywhere. The pin packages no oha.
4. **cmark-gfm**, for `make site` and `make check-site`.
5. **The network, the first time.** `make submodules` clones, `make test` fetches oha, and
   `make site-deps` fetches the chez-cmark-gfm archive. Every later run needs none of it.

## Decision

1. **The launcher is chez-libuv's, with the network.** `scripts/guix-env` runs
   `guix time-machine -C channels.scm -- shell -m manifest.scm --container --network
   --emulate-fhs --expose=<root>/scripts/guix-env-nsswitch.conf=/etc/nsswitch.conf
   --preserve=^(TERM|COLORTERM|LANG)$ -- sh scripts/guix-env-enter CMD…`.
   - The default command is `bash`. It refuses to run inside a Guix environment.
   - In a linked worktree it also shares the git common directory, refusing a directory that
     holds the checkout or HOME, one with no `HEAD`, and a path with `=`.
   - It refuses a checkout whose path holds `=`, since guix would split the `--expose` there.
   - `GUIX_ENV_DRY_RUN=1` prints the command for the host-side tests.
2. **`--emulate-fhs` stays,** for chez-cmark-gfm. It finds libcmark-gfm by searching the
   usual system directories. Without the flag, `make check-site` in the container raised
   `&cmark-library-unavailable` (`not-found`).
3. **The container gets its own `/etc/nsswitch.conf`.** `--network` brings the host's,
   which here names `mdns4_minimal`, `myhostname` and `systemd`. The container's glibc
   (2.41) cannot load those modules, so every name that does not resolve failed as
   `EAI_SYSTEM`. test-shell's lookup row expects `EAI_NONAME` for `a..b`, and it failed.
   `scripts/guix-env-nsswitch.conf` names only `files` and `dns`. Mounted over the host's, it
   gives `a..b` and `nosuch.invalid` `EAI_NONAME`, while real names and passwd lookups still
   resolve.
4. **The pin** is `b532aa7d0bb345aafabf6b63cbfbda45abbec091`, the peers' pin and this host's
   Guix.
5. **The manifest:**
   - chez-libuv's Chez 10.4.1 variant, unchanged, so the two share one store item. Here it
     was already built, so the first profile took under 4 s.
   - `libuv-for-node-lts` (1.52.1), `pkg-config` and `gcc-toolchain`.
   - pcre2, zlib and python, for vtest2.
   - curl, and httpd for ab.
   - cmark-gfm.
   - git and nss-certs.
   - The shell tools the Makefile and scripts call, tar and xz among them.
   - No cmake: the vendored libuv is never cloned. No Valgrind: there is no memory gate here.
6. **`scripts/guix-env-enter`** exports `CHEZ` (the profile's `scheme`) and `CC` (its gcc),
   and refuses a profile with no `bin/scheme`, `bin/gcc` or `lib/pkgconfig/libuv.pc`.
   `tests/test-examples.sps` starts each example with `CHEZ`, and vtest2's make takes `CC`
   from the environment.
7. **`make check-guix`** runs `tests/guix-env-launcher.sh` on the host (80 checks, no Guix;
   they run on a host without guix too, before the target says guix is missing), then
   `scripts/guix-env-selftest` in the container. The self-test asserts:
   - `isolated-home`: HOME holds only the path to the checkout and the shared common
     directory;
   - `tool-path`: scheme, gcc, pkg-config, git, make, curl, ab, python3 and awk are the
     profile's, on make's PATH and in both login-shell forms;
   - `chez-variable`, `chez-floor` (ci.yml's `CHEZ_FLOOR_VERSION`) and `chez-threaded`;
   - `cc-variable`, and `libuv-headers`, a program built and run against `<uv.h>`;
   - `libuv-floor`: after `make submodules`, which clones them in a fresh clone,
     pkg-config's libuv is at chez-libuv's `UV_FLOOR_DOTTED`, chez-libuv's `deps-info`
     chooses pkg-config, and the library is in the store;
   - `network`: an interface besides `lo`;
   - `nsswitch`: `/etc/nsswitch.conf` is `scripts/guix-env-nsswitch.conf`, the mount;
     test-shell's lookup rows check what it names;
   - `ca-bundle`: `GIT_SSL_CAINFO` and `CURL_CA_BUNDLE` name a non-empty bundle in the
     profile;
   - `git-reads-repo` and `no-git-credentials`, as chez-libuv's;
   - `make check-help test check-site-deps check-site`.
8. **People and agents edit, commit and push on the host.** Builds and tests go through
   `scripts/guix-env`, which AGENTS.md says.

### Rejected

- **No network (chez-libuv's).** On a fresh clone, the host would have to clone the
  submodules and fetch oha and the archive itself, with make, curl, sha256sum, tar and xz.
  The owner chose otherwise by form.
- **A `--network` opt-in on an offline default.** Weighed in the form, not chosen.
- **`CHEZ` through a search-path package (chez-cmark-gfm's).** `CC` is needed too, and the
  entry script refuses an incomplete profile by name. The cost: plain `guix shell -m
  manifest.scm` sets neither variable.
- **Guix's Chez 10.4.0.** It is below the floor the README promises and CI asserts.
- **`CHEZ_CMARK_GFM_LIBS` instead of `--emulate-fhs`.** It works only where the variable
  is set. The flag gives the container the system directories every FHS host has, as
  chez-libuv's container does.
- **chez-libuv's `scripts/require-tools`,** whose Makefile hooks point a bare `make` on a
  Guix host at the container. Here it would add a prerequisite to `build`. The vendored
  chez-libuv's own `require-toolchain` already gives that hint, naming its goal, `build`.
- **A CI job for the container.** CI keeps its own toolchain.

## Consequences

- **No test is kept off the network by the environment.** The suites reach loopback only by
  construction; nothing checks it in the container.
- **The container isolates the toolchain; it is not a sandbox.** The checkout, and in a
  worktree the git common directory, are shared read-write, and the host later runs what
  the container writes there.
- **It uses the host's `/etc/hosts` and `/etc/resolv.conf`,** which `--network` brings.
  There, `localhost` resolves to 127.0.0.1 alone, while the host's glibc also answers ::1.
  test-shell's lookup row holds to whatever `uv-getaddrinfo!` answers in the same process, so
  it passes either way.
- **Every call pays a few seconds of `time-machine` start-up.** Batch commands:
  `scripts/guix-env sh -c 'make a && make b'`.
- **Bumping the pin** means changing `channels.scm` and running `make check-guix`. When
  Guix packages Chez 10.4.1 or later, the variant goes, and `chez-floor` says whether the
  pin's own Chez will do.

## Measured, 2026-10-17

On this host, x86_64, at the pin:
- **A fresh checkout, empty submodules:** `scripts/guix-env make test` took 72 s. That
  covered cloning the six submodules, building the shim and vtest2, fetching oha, and
  running 53 suites. One row failed, test-shell's lookup (decision 3).
- **`make check-guix`**, the profile cached: 87 s, all green. That is 80 host checks, 39
  self-test lines, `make test` (53 suites, 2,181 expected passes, main's counts) and
  `make check-site`.
- **Watched to fail:**
  - Launcher: 10 mutants, each failing the checks it names: no `--network`, two of them, no
    `--expose`, the wrong source, an extra `--expose` of a HOME file, no `=` refusal,
    `GH_TOKEN` preserved, no worktree share, no `--container`, no `--emulate-fhs`.
  - Entry script: 6 mutants.
  - Self-test: 18 runs in the container, each failing its assertion by name: a HOME file
    exposed, a stub curl first on PATH, `CHEZ` bare, below the floor and unthreaded, `CC`
    bare and broken, no libuv on `PKG_CONFIG_PATH`, no network, the host's nsswitch,
    `GIT_SSL_CAINFO` unset, a CA bundle outside the profile and one missing, `GIT_DIR`
    elsewhere, and an identity, a credential helper, a token and a URL with userinfo.
  - One full run without the nsswitch mount, with a broken anchor in `docs/building.md`:
    `nsswitch`, `make-test` (test-shell) and `make-check-site` failed.
  - One T16 check caught its own test: `env` took the launcher's path, which holds an `=`,
    for a variable assignment. The case now runs the launcher by relative path.
- **The read-only review** found that `make check-guix` failed on a fresh clone.
  `libuv-floor` read chez-libuv's Makefile before anything had cloned the submodules. It
  now runs `make submodules` first. Offline, in a fresh clone, that branch failed by
  name (`make submodules failed`).
- **A fresh clone's `make check-guix`**, with the fix: 75 s, all green. That covered cloning
  the submodules, building vtest2, fetching oha and the chez-cmark-gfm archive, 53 suites
  (2,181 expected passes) and `make check-site`.
