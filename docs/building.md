# Building and testing

How to work on the server itself: building it, running the tests, and what
the tests check. To use the server in a project, [Installing](installing.md)
is enough.

## Build

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-http-server.git
cd chez-http-server
make build
```

`make help` lists every target. The ones you will use most:

| Target | Does |
|:--|:--|
| `make build` | builds the chez-libuv shim and assembles the library path |
| `make test` | runs every suite, `tests/test-*.sps` |
| `make run PROGRAM=... [ARGS="..."]` | runs a program on the library path |
| `make dev` | starts a Chez REPL with everything on the library path |
| `make check-pins` | checks every submodule sits at its pinned commit |
| `make prod` | rebuilds the shim optimized and runs the suite on it |
| `make clean` | removes build artifacts |

## Test

```sh
make test
```

For the test run you also need the clients the suites drive the server
with: **curl**, **ab** (`apache2-utils` on Linux), **python3** and **awk**,
plus **pcre2** and **zlib** where `pkg-config` sees them (`brew install
pcre2`, or `apt install libpcre2-dev zlib1g-dev`). `make test` builds
**vtest2** from its pinned source and downloads **oha**, checked by its
sha256, the first time.

To run one suite:

```sh
make test TESTS=tests/test-examples.sps
```

Every suite exits with one of four statuses: `0` all passed, `1` a check
failed, `2` the suite itself broke or ran no check, `3` a vendored file no
longer matches its recorded checksum. `make test` runs them all, keeps going
past a failure, and reports `ALL SUITES PASSED` only when every one passed.

## What the suites check

| Kind | Checks | Against |
|:--|:--|:--|
| the pure core | every row of the connection's transition table, the limits, the serializer, targets, `Host` | the table written out as data, RFC 9110 and 9112 |
| the parser corpora | how the server answers each request, however its bytes are split into reads | llhttp's fixtures, libhtp's streams |
| strictness and robustness | which requests are refused, and with what | Kestrel's, Apache httpd's and lighttpd's tests; AWS http-desync-guardian; request-smuggling vectors |
| the shell | sockets, timeouts, backpressure, drain, upgrades | a real libuv loop on loopback |
| real clients | that what they see is right | curl, ApacheBench, vtest2 scripts, an oha load test |
| allocation | the bytes a request allocates | a ceiling the suite fails above |
| the examples | that each example answers as its page says | each started as its own process |

The corpus suites try a sample of the ways to split each input by default;
`CORPUS=full make test` tries every split.

The vendored corpora live in `test/vendor/`, each with a `PROVENANCE` file
giving its source and the sha256 of every file. They are never edited by
hand; `make corpus-refresh` re-vendors one from an upstream checkout.

## On a Guix host

With [Guix](https://guix.gnu.org) installed, one script gives you every
tool the build, the tests and the docs site need, without installing any of
them into your system:

```sh
scripts/guix-env make test    # run one command
scripts/guix-env              # or open a shell
```

The command runs in a container built from the Guix commit pinned in
`channels.scm` and the packages in `manifest.scm`: Chez Scheme 10.4.1,
libuv 1.52.1, gcc, curl, ab, what vtest2 builds with, and cmark-gfm.

- **The first run is slow.** Guix fetches its pinned commit and the
  packages, then builds Chez from source, which alone takes about two
  minutes. Later runs start in a few seconds, so batch commands:
  `scripts/guix-env sh -c 'make test && make check-site'`.
- **A fresh clone needs nothing else.** The container has the network, so
  `make test` clones the submodules and fetches oha itself.
- **It sees this checkout and nothing else of your home directory** (in a
  linked worktree, also the main repository's `.git`): no git identity, no
  keys, no tokens. Edit, commit and push outside it.
- **It sets `CHEZ` and `CC`,** so no `CHEZ=` is needed.
- **A server it runs answers on your machine.** It shares the network, so
  after `scripts/guix-env make run PROGRAM=examples/hello.sps`,
  `curl http://127.0.0.1:8080/` from outside answers `Hello`.
- **Your environment stays outside,** except `TERM`, `COLORTERM` and
  `LANG`. Set a variable inside instead:
  `scripts/guix-env env CHEZ_HTTP_PORT=3000 make run PROGRAM=examples/hello.sps`.

`make check-guix`, run outside the container, tests the script, then checks
the container from inside: the pinned tools, Chez and libuv at their floors,
the isolation, and finally `make test` and `make check-site`. To move the
pin, change the commit in `channels.scm` (`guix describe -f channels` prints
yours) and run `make check-guix`.

## The docs site

These pages render to a small static site:

```sh
make site          # writes build/site/; open build/site/index.html
make check-site    # every page listed, every link and anchor resolving
```

The site is built by `build-site.sps` and the libraries in `site/`, through
[chez-cmark-gfm](https://github.com/Kiyomi-Computation-Systems/chez-cmark-gfm),
which needs the system **cmark-gfm** library (`brew install cmark-gfm`, or
`apt install cmark-gfm`). `make site` fetches chez-cmark-gfm the first time,
as `Akku.lock` pins it, or uses `.akku/` after `akku install`;
`make check-akku-lock` checks `Akku.lock` is what `akku lock` makes of
`Akku.manifest`. A new page goes
in `docs/` and in `site/pages.sls`, the nav's order; `make check-site` fails
until both name it.

## House rules

- **Functional core, imperative shell.** Rules go in the pure libraries
  under `src/http-server/`, which import no libuv; effects go in
  `src/http-server/private/`. `make check-imports` enforces it.
- **A test is finished when it has been seen to fail.** Break the code it
  guards, watch the check go red, then put the code back.
- **Every exported procedure has a signature comment**, Typed Racket style:
  `;; reason-status : Symbol -> Nat`.
- **Comments describe the code as it is**, not how it came to be.

CI runs `make test` and `make check-site` on Linux for every pull request.
