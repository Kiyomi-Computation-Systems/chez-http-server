# Changelog

All notable changes to chez-http-server are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
([0001](.plans/decisions/0001-the-project-is-the-composition-layer-and-where-it-stops.md)):
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
  ([0002](.plans/decisions/0002-the-connection-is-a-pure-state-machine-with-an-action-interpreter.md)'s
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

[Unreleased]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Kiyomi-Computation-Systems/chez-http-server/releases/tag/v0.1.0
