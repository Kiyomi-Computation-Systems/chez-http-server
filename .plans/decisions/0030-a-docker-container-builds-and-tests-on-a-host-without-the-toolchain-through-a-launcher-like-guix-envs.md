# 0030: a Docker container builds and tests on a host without the toolchain, through a launcher like guix-env's

Date: 2026-10-17
Status: accepted (user decisions, 2026-10-17, by form: "Launcher script (Recommended)", weighed: "Launcher + devcontainer" and "Compose file"; "Opt-in port (Recommended)", weighed: "Host network" and "Always publish 8080"; "Document make clean (Recommended)", weighed: "Detect and clean" and "Detect and refuse")
Plan: none; the owner asked for it directly

## Context

The owner, in their words: "I'd like to setup Docker for this project so non-Guix developers
can easily work on this without installing all of the deps on their host machines".

Decision 0029 gave a Guix host a pinned container, `scripts/guix-env`. A developer without
Guix needs Chez 10.4.1 threaded, which no common package manager ships at the floor, libuv
1.48 or later, a C compiler, curl, ab, pcre2, zlib, python3, cmark-gfm and git.

What was there to build on:
- **ci.yml's linux job** is a recipe already proven against every suite: Ubuntu 24.04, one apt
  line, and Chez built from its release tag.
- **chez-libuv's `docker/valgrind.Dockerfile`** builds Chez the same way for its memory gate.
  Its Makefile copies the checkout into the container and never mounts it read-write, because
  "a Linux `make build` would otherwise overwrite the host's build/ artifacts and the generated
  config.sls".
- **No sibling** has a Docker development container.

The host is x86_64 Pop!_OS 22.04 with Docker Engine - Community 29.8.1, on the kernel: its
bind mounts pass through no file-sharing layer, as Docker Desktop's on a Mac do.

## Decision

1. **`scripts/docker-env` has guix-env's shape.** `scripts/docker-env CMD…` runs a command, and
   with none, bash. It builds the image if missing, having first checked the daemon answers,
   since `docker image inspect` fails the same way when Docker is not running. Then it runs
   `docker run --rm --interactive --init --user UID:GID --mount <checkout> [--mount <common dir>]
   --workdir <checkout> --env HOME=/tmp --env TERM --env COLORTERM --env LANG [-p's flags] IMAGE CMD…`.
   - The checkout is mounted read-write at its own path, so paths match inside and out.
   - In a linked worktree it also mounts the git common directory. It refuses one that holds
     the checkout or HOME, or has no `HEAD`, as guix-env does.
   - `--mount`'s fields are CSV, so each is quoted, any quote doubled. A path with a space,
     `,`, `"`, `=` or `:` mounts; without the quoting, `,` and `"` broke docker's parse.
     guix-env's `=` refusal has no counterpart.
   - `--tty` only when stdin and stdout are terminals. `--init` forwards signals and reaps.
   - It runs as the host's uid and gid, so files it writes are the user's.
   - Docker passes `--env NAME` only when NAME is set. Nothing else of the host's environment
     enters.
2. **The image is `docker/dev.Dockerfile`:** Ubuntu 24.04 and ci.yml's toolchain step package
   for package, plus ca-certificates; Chez cloned at `v$CHEZ_VERSION`, configured `--threads`,
   `make -j`, installed under /usr/local, as ci.yml does; `ENV CHEZ=scheme`, with no `chez`
   symlink, since Chez finds its boot files by the name it runs as; and
   `git config --system --add safe.directory '*'`.
3. **The image is named for its inputs:** `chez-http-server-dev:<floor>-<cksum of the floor and
   the Dockerfile>`. The floor is ci.yml's `CHEZ_FLOOR_VERSION`, passed as a build arg, so it is
   stated in one place. An edit to either builds a new image, and the same inputs reuse one
   across checkouts. `cksum`, not `sha256sum`, which macOS lacks; a cache key needs no more.
4. **`-p PORT`, first or not at all,** publishes `127.0.0.1:PORT:PORT` and sets
   `CHEZ_HTTP_HOST=0.0.0.0` and `CHEZ_HTTP_PORT=PORT` inside. A published port reaches the
   container's own interface, not its loopback, where the server listens by default. A later
   `-p` is the command's own (`make -p`). A port outside 1 to 65535, a leading zero, or
   nothing after `-p` is refused.
5. **The network is Docker's default bridge,** on Linux and macOS alike: `make submodules`,
   `make oha` and `make site-deps` fetch the first time.
6. **`make check-docker`** runs `tests/docker-env-launcher.sh` on the host (113 checks against a
   fake `docker` that logs its calls, so the build-if-missing path is tested too; no Docker
   needed; the `--tty` cases run under util-linux `script` and are skipped without it), then `scripts/docker-env-selftest` in the container, then
   `tests/docker-env-publish.sh` on the host. The self-test asserts:
   - `isolated-mounts`: every mount point is Docker's own (the kernel's filesystems,
     `/etc/resolv.conf`, `/etc/hostname`, `/etc/hosts`, docker-init) or the checkout or common
     directory;
   - `isolated-env`: only PATH, HOSTNAME, HOME, CHEZ, the terminal's three, the shell's own
     and the proxy variables Docker's CLI adds from the user's Docker config are set, and HOME
     is `/tmp`;
   - `host-user`: not root, and a file it writes has the checkout's owner, which holds however
     a file-sharing layer reports owners;
   - `tool-path`: scheme, cc, gcc, pkg-config, git, make, curl, ab, python3 and awk are the
     image's, on make's PATH and in both login-shell forms;
   - `chez-variable`, `chez-floor` and `chez-threaded`;
   - `libuv-headers` and `libuv-floor`, as guix-env's, the library under /usr/lib;
   - `network`: https://github.com/ answers, through DNS and the CA bundle;
   - `ca-bundle`, `git-reads-repo` and `no-git-credentials`;
   - `make check-help test check-site-deps check-site`.
   The publish test serves `examples/hello.sps` through `-p`, asks it with the host's curl, then
   sends the launcher SIGTERM and checks the container is gone and the port free.
7. **Switching toolchains takes `make clean`,** and the docs and AGENTS.md say so. The
   container shares `build/` and chez-libuv's generated `config.sls` with the host.

### Rejected

- **A devcontainer, and a compose file,** weighed in the form. The launcher gives one interface
  with guix-env, and `make check-docker` tests all of it.
- **Host networking,** weighed in the form. It matches guix-env on Linux, but on Docker Desktop
  for Mac it reaches the host only with host networking switched on in its settings.
- **Publishing 8080 on every run,** weighed in the form. A shell and a test run at once would
  collide on the port.
- **Detecting a switch, and cleaning or refusing,** weighed in the form. It would take a stamp
  naming each environment, written by both launchers and read by the Makefile.
- **Copying the checkout in,** chez-libuv's way. The host's edits would not reach a running
  container, and `build/site` would stay inside.
- **Named volumes over `build/`.** chez-libuv's `config.sls` lives in its source tree, so a
  switch would still break.
- **A published image** (GHCR). It needs a CI job and a registry, and CI's runs have not
  started since the billing block.
- **`-v` for the mounts.** It splits at `:`, and creates a missing source as root where
  `--mount` refuses.
- **A path refusal like guix-env's `=` one.** CSV quoting mounts every path tried.

## Consequences

- **The container isolates the toolchain; it is not a sandbox.** The checkout, and in a
  worktree the git common directory, are mounted read-write, and the host later runs what the
  container writes there.
- **SIGTERM ends the container but does not drain the server.** GNU make passes SIGTERM to no
  recipe; on a host it leaves the server running, and here the container ends with make. At a
  terminal, Ctrl-C signals the whole foreground group, and the server drains.
- **The image is not reproducible.** `apt-get` installs whatever 24.04 has that day, and the
  tag `ubuntu:24.04` moves, as CI's image does. The image is rebuilt only when its inputs
  change, so a developer keeps one until then.
- **A checkout whose path holds a space builds nowhere,** in the container or out. `make
  deps` assigns `src=$(abspath $(SRFI_DIR))` unquoted, so the shell splits the path and
  `build/scheme-libs/srfi` stays empty; every suite then fails to find `(srfi :64)`. The
  launcher mounts such a path, and its tests use one.
- **What the container reaches and sees beyond the mounts.** Over the bridge it reaches the
  host's own services (here sshd, through the gateway 172.17.0.1). Docker's CLI adds the
  proxy variables in the user's Docker config, credentials in their URLs included. The
  repository's own `.git/config` is mounted, so a per-repository identity or a token in a
  remote's URL is there too, and `no-git-credentials` then fails `make check-docker`.
- **Untested here:** Docker Desktop's file sharing on any OS, since this host's engine mounts
  directly, and the uid 501 run used a volume; arm64 (Apple Silicon), since this host has no
  arm64 emulation; rootless Docker and Podman, where `--user` maps to a subordinate uid; and
  SELinux hosts, where a bind mount needs relabelling.

## Measured, 2026-10-17

On this host, x86_64, 18 cores, Docker Engine - Community 29.8.1:
- **The first build:** 150 s, then the command. The image is 789 MB. A later run starts in
  0.29 s.
- **The self-test on a checkout last built by the Guix container:** test-shell and
  test-clients failed. chez-libuv's `config.sls` named Guix's libuv, and `build/vtest` was
  linked against Guix's glibc. chez-libuv relinks when its acquisition mode changes, not its
  libuv's path, and both containers use pkg-config. After `make clean`: 67 s, all 42 self-test
  checks, `make test` at 53 suites and 2,181 expected passes (main's counts), and
  `make check-site`.
- **As uid 501:20, with no entry in the image's passwd,** as a Mac's user has: the checkout
  copied to a volume that uid owns, the whole self-test green in 68 s. A volume, not a bind
  mount: it shows that uid's lack of a passwd entry costs nothing, not how a Mac shares files.
- **`-p`:** the host's curl got `Hello` from `make run`. Under a pseudo-terminal, Ctrl-C
  drained the server ("draining 0", "stopped"), the launcher exited 130, and the port was
  free.
- **A fresh clone's `make check-docker`,** the image built, before the review: 75 s, all green.
  That covered the 105 host checks of then; cloning the submodules, building vtest2, and fetching oha and the
  chez-cmark-gfm archive; 42 self-test checks, with 53 suites at 2,181 expected passes and
  `make check-site`; and both publish checks.
- **The same at a path with a space** (`fresh clone`): every suite failed to find
  `(srfi :64)`. The cause is the Makefile's `deps` recipe (Consequences), and the run was
  repeated at `fresh-clone`.
- **Watched to fail:**
  - Launcher: 18 mutants, each failing the checks it names: no `--init`, no `--user`, an agent
    socket passed, HOME mounted, publishing on every address, no `CHEZ_HTTP_HOST`, no CSV
    quoting, the build's output on stdout, building every time, a tag that ignores the
    Dockerfile, no worktree mount, no port range check, `--tty` always, no HOME, mounting the
    checkout's parent, a failed build ignored, no floor required, no docker check.
  - Self-test: 17 runs in the container, each failing its assertion by name: an extra mount,
    `GH_TOKEN`, HOME elsewhere, root, another uid, a stub curl first on PATH, `CHEZ` unset, an
    unthreaded `scheme`, `HAVE_PKG` set, no network, an empty CA bundle, `GIT_DIR` elsewhere,
    a git identity, a credential helper, a URL with a token, no `uv/` headers, and a libuv of
    1.40.0. Run on the host, it refuses.
  - The make loop failed by name on the Guix-built checkout above (`make-test`).
  - The publish test's first version also wanted the server's "stopped" after SIGTERM; it
    failed, which is how make's SIGTERM came to light.
  - Unwatched: libuv-floor's "chose not pkg-config" and "not under /usr/lib" branches.
    `HAVE_PKG=no` in the environment does not change chez-libuv's choice.
- **The read-only review** (Opus) found, each reproduced before it was acted on:
  - The records called this host's engine Docker Desktop's. It is Docker Engine - Community;
    the `docker-desktop://` line in the build's output is buildx's link, printed anyway.
    Corrected above.
  - A proxy in the Docker config reached the container (`HTTP_PROXY=http://user:pw@…`), and
    `isolated-env` failed on it. The variables are now allowed, and the docs name them.
  - The container reached this host's sshd through the gateway, so the docs' "sees this
    checkout and nothing else" became "mounts", with a line that it is not a sandbox.
  - installing.md said to skip the prerequisites for the whole page, but using the server
    from one's own project cannot go through the container. It now says so.
  - The docs' git claims ignored the mounted `.git/config`; they now name it.
  - With Docker not started, the launcher announced a build that then failed on the daemon.
    It now checks the daemon first, and says to start Docker.
  - The whole-command checks built the expected `--mount` with a copy of the launcher's own
    quoting; one check now spells it by hand. The `--tty` condition was untested; three
    cases under `script` now test it.
  - `network` counted interfaces; it now asks https://github.com/.
  - `host-user` compared the uid with the checkout's owner, which a file-sharing layer may
    report as whoever asks; it now compares a written file's owner with the checkout's.
  - The "set a variable" example had no `-p`, so its server could not be reached, and
    nothing said `CHEZ_HTTP_PORT` inside defeats `-p`.
  - Not acted on, not reproduced: a buildx builder with the docker-container driver would not
    load the image.
- **Watched to fail after the review:** 4 launcher mutants (each half of the `--tty` test, no
  quote doubling, no daemon check), and in the container root, another uid (now "cannot
  write"), no network (now a DNS failure) and `GH_TOKEN`, each by name; with a proxy in the
  Docker config, `isolated-env` passed. Unwatched: `host-user`'s "a written file has another
  owner" branch, which a Linux host cannot produce.
- **A fresh clone's `make check-docker` after the review:** 76 s, all green: 113 host checks, the
  self-test's 42 with the new `network`, `host-user` and `isolated-env`, 53 suites at 2,181
  expected passes, `make check-site`, and both publish checks.
