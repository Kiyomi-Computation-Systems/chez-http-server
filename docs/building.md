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

## House rules

- **Functional core, imperative shell.** Rules go in the pure libraries
  under `src/http-server/`, which import no libuv; effects go in
  `src/http-server/private/`. `make check-imports` enforces it.
- **A test is finished when it has been seen to fail.** Break the code it
  guards, watch the check go red, then put the code back.
- **Every exported procedure has a signature comment**, Typed Racket style:
  `;; reason-status : Symbol -> Nat`.
- **Comments describe the code as it is**, not how it came to be.

CI runs `make test` on Linux for every pull request.
