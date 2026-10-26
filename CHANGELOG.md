# Changelog

All notable changes to chez-http-server are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A handler can list every header.** `(request-header-list r)` gives each field line
  of the head, in the order they came, as a pair: its name as sent, in its own case, and
  its value as `request-header` gives it. A name on several lines comes as several
  pairs. A handler that logs a request, proxies it or hands its headers on can see a
  field it does not know by name (decision 0032).
- **The request's HTTP version, from `(http-server)`.** `request-http-major`
  and `request-http-minor`, each `Request -> Nat`, give the version the
  request names: `HTTP/1.2` reads 1 and 2, though the server answers it as
  HTTP/1.1. A handler that logs requests, or a layer that hands the version
  on, no longer needs `(http-server request)`, which the docs do not cover.
  They are that library's own accessors, so code that imports them from
  there as well still works. A program that imports all of `(http-server)`
  and defines either name itself no longer loads: rename its own, or import
  `(except (http-server) request-http-major request-http-minor)`.
- **A sized body: a producer with its length declared.** `(sized-body n
  producer)`, from `(http-server)` and `(http-server response)`, is a body
  `make-response` takes beside a bytevector, a producer and `#f`. It is sent
  with `Content-Length: n`, a HEAD's answer too, its pieces unframed, so a
  file streams with its size and an HTTP/1.0 client that asked to keep its
  connection keeps it. The producer is called as any producer is, and asked
  for no more once `n` bytes are written. A piece that would go past `n` is
  not written, and an end short of it ends the body there: either is logged
  `body-length-mismatch n given`, and the connection closes after the bytes
  written, staged, so the client reads the body short; an end short of `n`
  once the client has closed is its doing, and is not logged. A length of 0
  is an empty body, its producer never called (decision 0033). A program
  that imports all of `(http-server)` and defines `sized-body` itself no
  longer loads: rename its own, or import `(except (http-server)
  sized-body)`.
- **A handler can ask whether a request has a body.** `(request-has-body? r)`,
  `Request -> Boolean`, gives the server's own answer: `#t` when the head
  announces a body, chunked or with a `Content-Length` above 0, so `00` is
  none, and `#f` otherwise. A handler that answers a reader only when a body
  follows no longer copies the rule from the headers, and asking allocates
  nothing: the request holds the answer, made once with it. It takes the
  place of `(http-server request)`'s `request-body`, which was `#f` for
  every request, so `make-request`'s sixth argument is now this Boolean. A
  program that imports all of `(http-server)` and defines `request-has-body?`
  itself no longer loads: rename its own, or import
  `(except (http-server) request-has-body?)`.
- **`(request-on-done! request proc)`: a handler hears when its response is
  done, and how it ended.** The server calls `proc` once, with `written` when
  every write of the response completed, `client-closed` when the client
  closed or reset the connection before that (a failed write included), or
  `failed` when the server ended it: a `500` or a stream cut short because
  the code raised, a status of its own in place of the handler's, the write
  deadline, or a close of its own. Any code that holds the request may
  register, as often as it likes; the procedures are called in place, newest
  first, before the next request on a kept-alive connection, or, while the
  request's code still waits on a coroutine, once it stops. A raise from one
  is logged `on-done-failed` and changes nothing, and one registered once the
  response is done is called at once, in the caller. A producer can now close
  the port it reads when its client leaves mid-stream (docs/bodies.md), and
  `examples/file-server.sps` does. A request with nothing registered costs
  nothing more. A program that imports all of `(http-server)` and defines
  `request-on-done!` itself no longer loads: rename its own, or import
  `(except (http-server) request-on-done!)`.
- **A handler can read the addresses of the connection a request came on.**
  `request-remote-address` and `request-local-address`, each
  `Request -> (U String #f)`, and `request-remote-port` and
  `request-local-port`, each `Request -> (U Nat #f)`, give the address and
  port of the connection's other end and of the end it came in on, `#f`
  where the server can't say. The server reads them once, as it accepts the
  connection, so every request on it reads the same. A handler can now
  trust `X-Forwarded-For` only when the request came from its own proxy,
  and log or limit by peer (decision 0037). A program that imports all of
  `(http-server)` and defines one of the four names itself no longer loads:
  rename its own, or import it with `except`.
- **A handler that waits can read its body by waiting.** In its `awaiting`
  thunk, before it answers, `(next-body-piece)` gives the body's next piece,
  a bytevector of its own, or the eof object at the end, and
  `(body-input-port)` is a binary input port over it, so code that reads a
  port reads the body as it arrives. The first call sends `100 Continue` to
  a client that waits for it; the server reads only as the pieces are taken,
  one read ahead at most; a cap of its own goes to the first call. A body
  that fails while pulled, past a cap, malformed or stalled, raises
  `&body-failed`, whose `body-failed-reason` and `body-failed-status` say why
  and what the server answers if the raise is let out; caught, the handler's
  own answer is sent. Either way, and for an answer before the body's end,
  the connection closes after it. A pulled body runs on the thunk's one
  coroutine whatever its size (decision 0036), and pulls under
  `(http-server testing)`'s host as under the server. A program that imports
  all of `(http-server)` and defines one of the six new names itself no
  longer loads: rename its own, or import `(except (http-server) ...)`.

- **Test a handler that waits, with no socket: `(http-server testing)`.**
  `make-test-host` hosts a handler, with settings from an environment
  procedure as `serve` takes one, and `test-host-connect!` connects clients
  to it. A client sends bytes as they go on the wire (`test-client-send!`),
  so a request can be malformed, pipelined or have its body sent in pieces,
  and it can close or reset while the handler waits. The clock moves only
  with `test-host-advance!`: each sleep and deadline ends at its own time,
  and each of the server's timeouts fires at the earliest time it can,
  where the server fires it up to `CHEZ_HTTP_TICK_MS` later, so a test
  should not pin one to the millisecond. `test-host-answer!` answers a
  `resolve`. What the client read comes back as responses, parsed, beside
  the raw bytes; `test-host-log` holds what the server would log, and
  `test-client-waiting?` reports a handler still waiting. The package
  installs it; `docs/testing.md` shows how. It runs over the fake shell the
  server's own suites use, now `(http-server private fake-shell)`:
  `tests/fake-shell.sls` re-exports it as `(fake-shell)`, as before, and a
  connection there may now be given a scheduler to share (decision 0038).

### Changed

- **The fake shell's dispatch cap is each event's.** An event and all it
  leads to may dispatch 100,000 times before the fake calls it stuck; the
  count no longer runs over a connection's whole life, so a long test on
  one connection no longer hits it.

### Fixed

- **`docs/waiting.md` says a lookup a deadline ends always answers.** It
  said one not yet begun is cancelled, as if that were the end of it. A
  cancelled lookup answers too, as cancelled, so the server logs
  `late-resume resolve` either way.

- **`docs/waiting.md` gives today's costs.** It said `guard` costs about
  3.7 KB inside a handler that waits, a figure from before waits parked on a
  full continuation. It costs about 0.4 KB, and about 1.2 KB when it catches
  an `error`; `with-exception-handler` costs about 0.15 KB, not next to
  nothing. The page now warns that an escape by `call/1cc` costs 3.4 KB or
  more once the code inside it waits or raises with `error`.
- **`docs/waiting.md` says what a wait does to `dynamic-wind`.** A wait runs
  the after thunk of each `dynamic-wind` around it, and the resume its before
  thunk, so a resource released in an after thunk is released at every wait,
  and Chez's `critical-section` and `with-mutex` do not hold across one.

## [0.8.0] - 2026-10-24

The ninth release, and the first public one: the repository and its docs
site are open to everyone, and the server is an Akku package. The server's
code is v0.7.0's; only its comments changed. What is new is around it: five
examples, the guides as seventeen Markdown pages published on GitHub Pages,
an Akku package, SECURITY.md, NOTICE and CONTRIBUTING.md, and development
containers for Guix and Docker. A checkout whose path holds a space now
builds. chez-httparse moves to v0.5.0 and uriparse to v0.8.0, both with
byte-machine v0.8.0, the versions on the Akku index. Nothing the server
calls behaves differently, but code that uses them itself meets their
changes, and the package's ranges admit no older one, so the release is
0.8.0. chez-libuv v0.11.0 is 0.7.0's.

### Added

- **`examples/`: five small servers, each one file.** `hello.sps`; `echo.sps`,
  reading a request and its body; `stream.sps`, a streamed response and
  server-sent events; `long-poll.sps`, a handler that waits for another
  request, with a deadline; and `file-server.sps`, which serves a directory as
  `python3 -m http.server` does. `tests/test-examples.sps` starts each one and
  checks what it answers.
- **`make run` passes `ARGS` to the program:**
  `make run PROGRAM=examples/file-server.sps ARGS="8000 --directory ."`.
- **The docs render to a static site: `make site`** writes `build/site/`, one
  page per `docs/*.md`, with a nav in the home page's order, an "On this page"
  rail, previous and next links, and a light and dark theme. `make
  check-site` fails on a page missing from the nav, a link or anchor that
  resolves to nothing, or an anchor GitHub spells differently; CI runs it.
  The site renders through chez-cmark-gfm 2.0.0, which `Akku.lock` pins and
  `make site-deps` fetches, checked by its sha256; it needs the system
  cmark-gfm library. `make test` needs none of it. `Akku.manifest` names it
  as a development dependency, and `make check-akku-lock` checks `akku lock`
  still makes `Akku.lock` from it.
- **The docs site is published on GitHub Pages,**
  https://kiyomi-computation-systems.github.io/chez-http-server/, from each
  release tag or by hand, after `make check-site` passes. `make check-site`
  now clones chez-srfi alone (`make srfi`) and builds no shim, so the site
  builds with Chez and cmark-gfm alone; CI's `site` job checks that it does.
- **SECURITY.md and NOTICE.** SECURITY.md asks for vulnerabilities to be
  reported privately, through GitHub's "Report a vulnerability". NOTICE
  lists the third-party software the repository holds, builds with,
  downloads or tests with, and each one's license: the submodules under
  `vendor/`, the test corpora under `test/vendor/`, chez-cmark-gfm and oha,
  what the build needs but does not bundle, and the docs site's palette.
  `make check-notice`, in CI, fails when NOTICE leaves out a submodule or a
  corpus, or no longer repeats a corpus's own NOTICE text.
- **CONTRIBUTING.md, and templates for pull requests and issues.**
  CONTRIBUTING.md says how to set up, which checks CI runs, what to do when
  changing a pin, NOTICE, the Makefile, the docs or the containers, and the
  house rules for code, tests and pull requests. The pull-request template
  asks for where the change was tested and has a checklist; the bug report
  asks for the platform, the versions and a request that shows it.
  `make check-help` now also fails when CONTRIBUTING.md or the pull-request
  template quotes a `make` target the Makefile lacks.
- **An Akku package.** `Akku.manifest` describes the server for the
  [Akku](https://akkuscm.org) index: the libraries under `src/`, depending on
  chez-libuv `^0.11.0`, chez-httparse `^0.5.0`, chez-uri `^0.8.0` and
  byte-machine `^0.8.0`, each range starting at the version vendored under
  `vendor/`. In a project that uses Akku, `akku install chez-http-server`
  fetches them all, and chez-libuv's install hook builds the shim; it needs
  libuv 1.48 or newer where `pkg-config` sees it. `make check-pins` now also
  fails when `Akku.manifest`, a vendored copy and `Akku.lock` name different
  versions, or when the package's version is not the latest release here,
  and needs Chez to read them. `make check-akku`, which needs akku, installs
  the checkout into a scratch project as a consumer would and serves a
  request on Akku's library path. Release archives leave out `.plans/`,
  `.superpowers/` and `AGENTS.md`.
- **A pinned Guix development container: `scripts/guix-env`.** On a Guix
  host, `scripts/guix-env make test` runs any target in a container built
  from the Guix commit in `channels.scm` and the toolchain in `manifest.scm`:
  Chez Scheme 10.4.1, libuv 1.52.1, gcc, the clients the suites run, and
  cmark-gfm for the docs site. It has the network, so a fresh clone needs
  nothing else, and nothing of the user's home directory. `make check-guix`
  tests the launcher on the host, then checks the container from inside and
  runs every suite and the docs site's checks there.
- **A Docker development container: `scripts/docker-env`.** For a host
  without the toolchain, `scripts/docker-env make test` runs any target in a
  container built from `docker/dev.Dockerfile`: the Ubuntu and packages CI
  uses, and Chez Scheme 10.4.1 built from source. It runs as the user,
  mounts the checkout and nothing else of the machine, and has the network,
  so a fresh clone needs nothing else. `-p PORT` serves on the host's
  127.0.0.1:PORT. `make check-docker` tests the launcher on the host, checks
  the container from inside and runs every suite and the docs site's checks
  there, then asks a server it runs from the host.

### Changed

- **chez-httparse is pinned at v0.5.0 and uriparse at v0.8.0, both with
  byte-machine v0.8.0,** the versions the Akku index lists. Nothing the server
  calls behaves differently. chez-httparse's generated message parser changes
  six lines, so a digit of `Content-Length`, a chunk size or a status code no
  longer allocates a bignum; its URL parser and uriparse's scanner are
  byte-identical. uriparse adds `(uri easy)` and `(uri query)`, which the
  server does not use; of the libraries it does use, only the text of one
  assertion's message in `(uri charset)` changes. Every suite passes as many
  checks as before.
- **The guides in `docs/` are Markdown, rewritten as seventeen pages** for a
  static site, home first (`docs/README.md`): installing, a quickstart, the
  examples, handlers, bodies and streaming, waiting, upgrades, requests,
  responses, connections, configuration, deploying, how it works,
  performance, an API reference, and building and testing. The six `.org`
  pages they replace are gone; their content is in the new pages.
  `docs/performance.md` gives fresh measurements, among them requests a
  second with oha, the file server beside `python3 -m http.server`, and
  both beside Racket's `web-server` and Node's `http`.

### Fixed

- **A checkout whose path holds a space builds and passes every suite.** The
  step that links SRFI-64 into `build/scheme-libs` split such a path, so no
  suite could load its test framework. Worse, the link loop then ran over the
  root directory, trying to replace `/lib` and its neighbours with links to
  themselves: denied for a user, but under `sudo` it would break the system.
  Its paths are now quoted, and it stops unless both directories exist.
  `tests/srfi-links.sh`, in `make check-site-deps`, runs it in a checkout
  under a folder named `with space`.
- **`make submodules` brings an inner checkout along when a pin moves.** A
  clone made with `git clone --recursive` holds uriparse's own byte-machine;
  when uriparse's pin moved, that copy stayed at the old commit and
  `make check-pins` called it a local edit. `make submodules` now moves an
  inner submodule already checked out to the commit its parent records, and
  still clones none. `make check-submodules`, in CI, checks both.
- **`make check-akku-lock` says when akku's index is out of date.** An index
  older than a dependency's release made `akku lock` fail with "dependency
  hell"; the check now names each package akku does not know and says to run
  `akku update`.

## [0.7.0] - 2026-10-16

The eighth release. The test fake's door, which a taker's own tests load, now acts as
the server does in two more places: it keeps what a client sends while the taker reads
nothing, and it bounds a taker's close by the write timeout. A taker's test that ends
a connection while the taker has stopped reading no longer hears that end until the
taker reads again. What a taker's tests see changes, so the release is 0.7.0, though
no export of the server changes. One fix comes with it: a waiting taker's thunk may
end with no values. chez-libuv is pinned at v0.11.0, which still needs libuv 1.48 or
later; nothing the server calls behaves differently, but code that calls chez-libuv
itself meets v0.10.0's changes. chez-httparse v0.4.5 with byte-machine v0.7.0, and
uriparse v0.6.2, are 0.6.0's.

### Changed

- **chez-libuv is pinned at v0.11.0.** Run `make build` after pulling: the shim's
  source changed in v0.10.0, so it relinks, though a release shim compiles to the same
  code and exports nothing new. libuv 1.48 or later is still enough. Nothing the server
  calls behaves differently. For code that calls chez-libuv itself, v0.10.0 changed
  three things: `uv-kill!` refuses a pid outside a C int, `uv-write*!` refuses a list
  of 2^32 segments or more, and `(libuv dns)` no longer exports `addrinfo-chain->list`.
  v0.11.0 changes no library; it adds an install hook for projects that get chez-libuv
  through Akku (chez-libuv's CHANGELOG has the rest).
- **The test fake keeps what a taker's client sends while the taker reads nothing,**
  as the server does. `tests/fake-shell.sls`: a read or the client's end given to
  `fake-shell-deliver!` before a taker's `transport-read-start!`, or after its
  `transport-read-stop!`, is kept and read on the turn after reading starts again, at
  a read-start or at the close. Before, it went to the taker at once: to an `on-bytes`
  not yet given, a failure that aborted the stream, or to a taker that had stopped
  reading. A taker's own test that ends a connection while the taker has stopped
  reading no longer hears that end until the taker reads again, since the server never
  tells it then: chez-websocket's binding suite has one such check.
- **The test fake bounds a taker's close as the server does.** `tests/fake-shell.sls`:
  once a taker has asked to close, each write the close waits for gets the write
  timeout, from the close and again from each write's end, and past it the stream is
  aborted, its writes told `ECANCELED` (decision 0027). Before, the fake held such a
  close open until the taker's own deadline, or a test's later turn, ended it. The
  taker's own deadline still runs beside the bound, the earlier first.

### Fixed

- **A waiting taker's thunk may end with no values.** What the thunk of a take-over's
  `(awaiting thunk)` returns is dropped, as decision 0023 says, however many values.
  Before, a thunk that ended with none, as one whose last call is `sleep-ms` does, or
  with several, was taken as a raise: `taker-failed` was logged and the stream closed.
  The test fake drops them too.

## [0.6.0] - 2026-10-12

The seventh release. A taker's `transport-close!` no longer waits forever on a client
that reads nothing: each write it waits for gets `CHEZ_HTTP_WRITE_TIMEOUT`, and the
stream is aborted past it (decision 0027). What a taker sees changes, so the release is
0.6.0, though no export changes. Four fixes come with it: what a client sends after the
`101` waits for a taker that starts reading late, a taker hears its client's end once,
a signal sent the moment `serve` logs `listening` drains the server, and a waiting
coroutine lets go of what woke it. The pins are 0.5.0's: chez-libuv v0.9.0,
chez-httparse v0.4.5 with byte-machine v0.7.0, and uriparse v0.6.2.

### Changed

- **A taker's close no longer waits forever on a client that reads nothing.** Once a
  taker calls `transport-close!`, each write the close still waits for gets
  `CHEZ_HTTP_WRITE_TIMEOUT` (60 s), as the server's own writes do, and the stream is
  aborted past it: each write is told `ECANCELED`, and the close call runs. A taker
  that armed no deadline of its own held such a client, and its connection slot, until
  the server drained. A deadline the taker arms still runs, and the earlier of the two
  comes first, so chez-websocket's 10 s close timeout is unchanged (decision 0027).
- **The test fake's door, which a taker's own tests load, keeps closer to the
  server.** `tests/fake-shell.sls`: a taker's deadline passing, and
  `fake-shell-settle!`, now run the connection's scheduler afterwards unless it is
  held, as a delivery does, so a coroutine they wake runs without a
  `fake-shell-schedule!`. A write asked for after the close is told `ECANCELED` on the
  next turn, not at the next completion. A taker that starts reading after its
  client's end is told it once. `fake-shell-deliver-later!` takes a taker's write's
  outcome, and `event->door-read` and `door-read->event` are exported.

### Fixed

- **A taker no longer loses what its client sends before it starts reading.** Once the
  `101` was written, the server read on for itself until the taker called
  `transport-read-start!`, and dropped what it read: a taker that started reading
  later, from a thunk that waits or at a deadline, never got what the client sent
  first. Now nothing is read until the taker starts reading or closes, and those
  bytes wait for it; once it closes, what the client sends is read and dropped. A
  taker that starts reading in its take-over, as chez-websocket's does, lost nothing.
- **A taker hears its client's end once.** A taker that called
  `transport-read-start!` again after its `on-end` was told the end a second time,
  since the system reports it again to each new read. Now a stream that has ended
  starts no reads. An end that came while the `101` was being written is told by the
  server itself, on the turn after the taker's read-start, instead of relying on the
  system to report it twice.
- **A signal sent the moment `serve` logs `listening` drains the server.** `serve`
  watched for SIGTERM and SIGINT only after writing the line, so a supervisor that
  signalled as soon as it read it could end the process at once, with no drain and
  nothing logged. `serve` now watches for them first. The gap showed in an x86_64
  image run under emulation, where the serve suite's own signal check went red in three
  runs of three.
- **A waiting coroutine no longer keeps what woke it.** The value given to an `await`'s
  `resume` stayed on the heap while the code waited again, until its next wake, even
  once the code had let it go: a taker whose code resumed its wait with each read's
  bytes kept the last read. A value given while `register` ran stayed for as long as
  whoever registered kept the resume, and so did the coroutine that waited, with what it
  ended with, after it had ended. Each is let go once used, at no cost per wake.

## [0.5.0] - 2026-10-11

The sixth release. A taker's `transport-close!` now closes as the server's own closes
do: it half-closes, throws away what the client still sends, and closes once the client
closes too. A client still sending reads the taker's last words where it got a reset.
chez-websocket asked for it, for its close frame (decision 0026). What a taker sees
changes: its close call, and a waiting taker's `&client-closed`, come once the client
has closed, up to `CHEZ_HTTP_LINGER_TIMEOUT` later, and the test fake's door closes the
same way. So the release is 0.5.0, though no export changes. chez-libuv is pinned at
v0.9.0, which still needs libuv 1.48 or later. chez-httparse v0.4.5 with byte-machine
v0.7.0, and uriparse v0.6.2, are 0.4.1's.

### Changed

- **chez-libuv is pinned at v0.9.0.** Run `make build` after pulling: its C shim gained
  two functions. libuv 1.48 or later is still enough. A loop run that would leave its
  thread too little C stack is now refused with chez-libuv's `&uv-stack-exhausted`,
  where before it could crash the thread. The server never leaves a libuv callback
  without returning, which is what uses that stack up, so it should never see one: if
  it does, that is a bug to report.
- **A taker's close is gentle, as the server's own closes are.** `transport-close!`
  stops handing the taker reads but keeps reading, throwing away what the client
  still sends. Once the taker's writes are out it half-closes, and it closes when the
  client closes too, or after `CHEZ_HTTP_LINGER_TIMEOUT` (30 s). It closed the socket
  at once, and a client still sending got a reset that could lose the taker's last
  words. On macOS a WebSocket client in Node read the close frame in 14 of 100 tries,
  and now in 100 of 100; on Linux, 46 to 56 of 100 clients ended in a reset, and now
  none. The close call, and a waiting taker's `&client-closed`, come once the client
  has closed. `transport-abort!` still closes at once (decision 0026).
- **The test fake's door closes the same way** (`tests/fake-shell.sls`, which a taker's
  own tests may put on their library path). After `transport-close!` it reads on,
  dropping what comes. Once the writes are out it shuts its write side, which the new
  `(fake-shell-shut? sh)` tells, and lingers, the linger deadline armed on the fake
  clock in the taker's deadline's place. The client's end (`(fake-shell-deliver! sh
  '(eof))`), a read error, or the linger passing (`fake-shell-advance!`, then
  `fake-shell-fire!`) closes it. A test that read the stream closed just after the
  close now delivers the client's end first (decision 0026).

### Fixed

- **A malformed setting reaches your handlers as itself.** Raised out of `serve` through
  a `guard` whose clauses did not match it, the `&http-server-config-error` reached the
  handlers further out as chez-libuv's `&uv-handle-closed` (chez-libuv #120). It now
  arrives as itself. `serve` allocates about 256 B more, once (chez-libuv's figure).

## [0.4.1] - 2026-10-09

The fifth release, a patch. A handler that waits, or a taker's thunk that waits, keeps
about 3 KB less, and a wait entered a second time ends the handler that did it
(decision 0025). Nothing an embedder calls changes, so the release is 0.4.1.
chez-libuv is pinned at v0.8.0, which needs libuv 1.48 or later: with an older one, as
Debian 12's 1.44 is, the build makes its own, and needs CMake. chez-httparse v0.4.5
with byte-machine v0.7.0, and uriparse v0.6.2, are 0.4.0's.

### Changed

- **libuv 1.48 or later is needed.** chez-libuv is pinned at v0.8.0, which refuses a
  libuv older than 1.48 when it loads, where the floor was 1.44. Ubuntu 24.04's libuv
  is 1.48. Where the system's is older, as Debian 12's 1.44 is, the build makes its
  own copy with CMake. What a handler sees, and what a request allocates, is unchanged.
- **A waiting handler, or a taker's waiting thunk, keeps about 3 KB less.** A coroutine
  is now entered, and parks, on full continuations. A one-shot park kept a stack segment
  for as long as the coroutine waited. One parked at an `await` keeps 690 to 754 B, where
  it kept 3,676 to 3,848 B, and about 16 B more for each call deeper. A request that
  waits once allocates what it did: 7,160 to 7,877 B through the server, where 6,977 to
  7,980 (decision 0025 and its review).
- **A wait entered a second time ends the handler.** When a handler's own continuation
  jumps back into a wait that has already returned, the handler fails as if it raised,
  with an assertion naming the wait (`await`, `sleep-ms` or `resolve`), and the code
  after the wait does not run again. A guard around the wait does not see it, and
  another handler still waiting is untouched. Chez's refusal of the one-shot
  continuation was raised where the jump landed, so a guard there caught it and the code
  after the wait ran twice (decision 0025's review).

## [0.4.0] - 2026-10-09

The fourth release. A taker can abort its stream, and a handler can read every line of
a field: the second change chez-websocket needs from this server (decision 0024). One
change refuses what 0.3.0 accepted, so the release is 0.4.0: a numeric setting written
in anything but ASCII digits now stops the server at startup, naming its variable.
`make-transport` still takes the seven procedures 0.3.0's did. chez-libuv is pinned at
v0.7.4; chez-httparse v0.4.5 with byte-machine v0.7.0, and uriparse v0.6.2, are
0.3.0's.

### Added

- **A taker can abort its stream.** `(transport-abort! t)` closes it at once: reading
  stops, and each write not yet sent is dropped, its `done` told `ECANCELED`. A client
  that reads again may still get part of a write already under way.
  `transport-close!` waits for the writes, so a client that stopped reading kept the
  stream open until it went or the server shut down, and a deadline could only ask for
  the same close again. A deadline that aborts now closes it. `make-transport` takes the
  abort as an eighth procedure; a transport made of seven, as before, still works, and
  refuses the abort (decision 0024).

- **A handler can read every line of a field.** `(request-header-values r name)` gives
  the value of each field of that name, in the order they came, or none; `request-header`
  still gives the first. A list such as `Connection` may run over several lines (RFC 9110
  §5.3), and a client may send a field twice (decision 0024).

### Changed

- **A numeric setting is written in ASCII digits alone.** The 19 numeric `CHEZ_HTTP_`
  variables, the port's among them, were read by Chez's `string->number`, which also
  takes a sign, a radix or exactness prefix, a fraction and a complex number with no
  imaginary part: `CHEZ_HTTP_PORT=#x1F90` listened on 8080, and `+5`, `#e1e3`, `10/2`
  or `5+0i` started a server too. Each is now refused at startup, naming its variable,
  as `-1` and `five` were. Leading zeros are still digits: `08080` is 8080 (decision
  0005's amendment of 2026-10-05).

- **A request allocates about a quarter less.** Through the whole server, a GET kept
  alive allocated about 10.0 KB at one connection and 8.4 KB at 50; it now allocates
  7.3 KB and 7.0 KB, on Darwin and Linux alike. The server sets up its protection
  against a raise once for a run of turns, a dispatch or a handler's failure, where it
  set it up for every turn, every part of a dispatch and every handler call. What a
  handler sees, and what a raise does, is unchanged.

- **A request allocates about 30% less again.** chez-libuv is pinned at v0.7.4, which
  sets up one protection for each callback where it set up several, and answers libuv's
  request for a read buffer without running Scheme (chez-libuv #45, this project's
  ask). A GET kept alive allocated 7.3 KB at one connection and 7.0 KB at 50; it now
  allocates 5.2 KB and 5.0 KB. What a handler sees is unchanged. A check now holds a
  GET to 5.25 KiB (decision 0002's amendments of 2026-10-05 and 2026-10-08).

### Fixed

- **The test fake's door now behaves as the server's does for a client that stops
  reading** (`tests/fake-shell.sls`, which a taker's own tests may put on their library
  path). A close it is asked for waits for the writes outstanding, so a deadline asked
  for meanwhile is armed. A raise in any of the taker's calls is recorded as its failure
  and closes the stream at once, where it escaped to the test, or waited behind the
  writes. An aborted write's bytes no longer count as read by the client, and once the
  close has been asked for the taker is read nothing more, its end told once (decision
  0024).

## [0.3.0] - 2026-10-04

The third release. A taker can now wait: a take-over may answer `(awaiting thunk)`,
as a handler does, and its thunk runs on a coroutine. It is the one change that
chez-websocket, a WebSocket library to be built on this server, needs from it
(decisions 0022 and 0023). Nothing breaks: a take-over that answers anything else
runs as before. The pinned libraries are 0.2.0's: chez-libuv v0.7.3, chez-httparse
v0.4.5 with byte-machine v0.7.0, and uriparse v0.6.2.

### Added

- **A taker can wait.** A take-over that answers `(awaiting thunk)`, as a handler
  does, has the thunk run on a coroutine, where it can `await`, `sleep-ms`,
  `with-deadline` and `resolve`; its read callback can wake it. Once the stream has
  closed, whoever closed it, the wait the thunk is in, or else its next, raises
  `&client-closed`, once; let out, nothing is logged. Anything else it raises is
  logged `taker-failed` and closes the stream. A take-over that answers anything
  else runs as before (decision 0023; `docs/handlers.org`).

## [0.2.0] - 2026-10-04

The second release. A handler that waits is now told when its client leaves, a
request in HTTP/1.2 to 1.9 is served as 1.1, and every version that is not 1.x is
answered `505`. One change breaks 0.1.0's API: the pipeline cap is removed, so
`make-limits` takes nineteen fields, not twenty. The
pinned libraries are 0.1.0's: chez-libuv v0.7.3, chez-httparse v0.4.5 with
byte-machine v0.7.0, and uriparse v0.6.2.

### Added

- **A waiting handler is told when its client closes the connection.** If the
  client closes or resets it while a handler, a reader or a producer waits, the wait
  it is in, or else its next, raises `&client-closed` (`client-closed?`), once. A
  handler that lets it raise is answered nothing, and the connection closes; one that
  catches it may answer anyway, and a client that only half-closed reads it. Behind
  Caddy, a client that leaves makes Caddy close its connection, so the handler is
  told then (decision 0020).

### Changed

- **The server reads while a handler runs, only to notice the client close.** A
  client that closes is seen at once, not when the handler answers. A request the
  client sends meanwhile is held, reading stops, and it is answered after, in order,
  as before. A client that closes after sending more requests still gets every
  answer; the connection then closes at once, with no linger (decision 0020).

- **A request line in HTTP/1.2 to 1.9 is served as HTTP/1.1**, as RFC 9110 §6.2 asks,
  where it was answered `400`. **Every other version that is not 1.x is answered `505`**,
  HTTP/3.0 among them, where it was `400`; HTTP/0.9 and 2.0 already were. A version the
  server cannot read at all, such as `HTTP/1.x`, is still `400`. The parser now runs
  llhttp's version leniency and no other (decision 0006's amendment of 2026-10-04).

### Removed

- **The pipeline cap**: `CHEZ_HTTP_PIPELINE_CAP`, and the limits field
  `pipeline-cap` with its accessor `limits-pipeline-cap`. It accepted only 1: the
  server answers the requests on a connection one at a time, and is not to parse
  ahead (decision 0004). The variable is no longer read, so a deployment that sets
  it, which v0.1.0 allowed only as 1, starts as before. `make-limits` takes
  nineteen fields, not twenty.

### Fixed

- **A taker's `done` is no longer lost when `serve` returns.** The `done` of a
  `transport-write!` refused, after `transport-close!` or as it is asked for,
  comes on the server's next turn. If the server stopped first, it never came;
  now it comes before `serve` returns. A write asked for in a `done` that comes
  then gets no `done` (`docs/handlers.org`).

## [0.1.0] - 2026-10-04

The first release: an HTTP/1.1 server for Chez Scheme on libuv. `serve` runs your
handler on one libuv loop, on one thread, and answers each connection's requests
one at a time. The server is a composition layer over three pinned libraries
([0001](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/main/.plans/decisions/0001-the-project-is-the-composition-layer-and-where-it-stops.md)):
- chez-libuv v0.7.3, for the loop and the sockets;
- chez-httparse v0.4.5, for the request parser, with byte-machine v0.7.0 under it;
- uriparse v0.6.2, for request targets.

### Added

- **`serve`** listens where the environment says, `CHEZ_HTTP_HOST` and
  `CHEZ_HTTP_PORT` (127.0.0.1:8080 unless set), and returns once the server has
  stopped (`docs/configuration.org`).
- **A handler reads the request through accessors**: `request-method`,
  `request-path`, `request-query`, `request-header` and `request-host`. It reads
  a body as it arrives with `read-body`, or whole with `read-whole-body`, and
  answers with `make-response`. A response's body is a bytevector, or a producer
  the server calls for each piece, so neither an upload nor a download is held in
  memory whole (`docs/handlers.org`; decisions 0012 and 0013).
- **A handler can wait.** It answers `awaiting` with a thunk, which runs on a
  coroutine and can wait with `await`, `sleep-ms`, `with-deadline` and `resolve`
  (decisions 0014 and 0015).
- **A handler can take an upgrade**, a WebSocket's for example. It answers
  `switch-protocols`, the server writes the `101`, and the handler speaks the new
  protocol over a transport that the server keeps (decision 0016).
- **The server writes the framing**: `Content-Length` or chunked, `Connection`
  and `Date`. A response it cannot write safely is answered `500` instead
  (decision 0010). HTTP/1.0 is served. HTTP/0.9 and HTTP/2.0 request lines, and
  the HTTP/2 preface, are answered `505` (decision 0006).
- **Every limit has a default and an environment override, and every deadline is
  enforced**: receiving the head, idle time between requests, gaps in a body, each
  write, the close, and the drain (`docs/configuration.org`; decision 0005).
- **It shuts down gracefully** on SIGTERM or SIGINT. It finishes the requests in
  flight and closes what is left after `CHEZ_HTTP_DRAIN_TIMEOUT`
  (`docs/connections.org`).
- **The tests hold it to other code's verdicts**: llhttp's request fixtures,
  libhtp's streams, AWS http-desync-guardian's cases, and the strict request tests
  of Kestrel, httpd and lighttpd. Real clients run against a port: curl, ab,
  vtest2's scripts, and oha's load smoke, which checks that every one of 22,000
  requests is answered `200` with its body and none fails. `make test` runs 50
  suites and 1,882 checks.

### Measured

Measured 2026-10-04 on an Apple M1 (8 cores, 16 GB). On macOS 26 (Darwin 25.6.0,
arm64): Chez Scheme 10.4.1 `tarm64osx` and libuv 1.52.1. On Linux 6.12 (aarch64,
Debian 12 in Docker on the same machine): Chez Scheme 10.4.1 `tarm64le` and libuv
1.44.2. A macOS Bluetooth daemon (BTLEServer) was using about one core whenever it
was checked, before and after the runs.

**Throughput.** oha 1.16.0 sent 50,000 GETs over kept-alive connections to a server
answering `200` with a 6-byte body. Node's `http` module answered the same way on the
same machine, the two alternating. Figures are thousands of requests per second over
two runs of three rounds (`.plans/research/spike/m8-load.sh`):

| connections | 1 | 10 | 50 | 100 | 500 |
|---|---|---|---|---|---|
| macOS, this server | 9.9–10.5 | 31.3–32.8 | 32.8–34.0 | 32.6–34.0 | 23.7–31.5 |
| macOS, Node 20.10 | 10.3–10.7 | 34.0–35.5 | 35.4–36.1 | 34.4–36.1 | 31.1–32.0 |
| Linux, this server | 14.0–14.4 | 61.5–64.4 | 82.8–86.8 | 78.3–88.0 | 62.4–72.8 |
| Linux, Node 18.20 | 14.1–14.4 | 53.6–55.6 | 50.9–60.4 | 50.6–55.9 | 43.8–46.8 |

- Every request was answered `200`, and none failed.
- At 10 connections or more, the server spent 28–32 µs of CPU per request on macOS
  and 11–16 µs on Linux, on one core.
- At 50 connections, the median latency was 1.1–1.7 ms on macOS and 0.55–0.58 ms on
  Linux, and the 99th percentile 2.2–2.6 ms and 0.71–0.81 ms.
- Each request on a connection of its own, 20,000 at 10, 100 and 500 at a time, was
  answered too, on macOS (`m8-no-keepalive.sh`).
- These numbers are a baseline, not a goal: v0.1.0 sets no throughput goal
  ([0002](https://github.com/Kiyomi-Computation-Systems/chez-http-server/blob/main/.plans/decisions/0002-the-connection-is-a-pure-state-machine-with-an-action-interpreter.md)'s
  amendment of 2026-10-04).

**Memory.**
- An idle connection holds about 20 KB, 16 KiB of it the read buffer and about 2 KB
  the server's own state. 10,000 idle connections, the default `max-connections`,
  held 199–202 MB on both platforms (`m8-max-connections.sps`).
- A GET kept alive allocates about 10.4 KB through the whole server, the libuv shell
  and chez-libuv included, at one connection, and 8.9 KB at 50, where each turn of the
  loop serves many requests, on both platforms (`m8-request-alloc.sps`). The handler
  answered with one response built once, so this is the server's own.
- Of that, parsing a request, stepping the connection through it and framing its
  response allocate:

  | request | bytes allocated |
  |---|---|
  | curl's GET | 1,840 B (the ratchet is 3,072 B) |
  | `ab -k`'s GET | 2,112 B |
  | a JSON POST, body streamed | 2,432 B |
  | a JSON POST, body read whole | 2,624 B |
  | a browser's GET with eleven fields | 3,312 B |

[Unreleased]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/releases/tag/v0.1.0
