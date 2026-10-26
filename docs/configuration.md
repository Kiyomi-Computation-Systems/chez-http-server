# Configuration

Every setting comes from an environment variable, as the
[twelve-factor app](https://12factor.net/config) asks: where the server
listens, and every limit in the tables below, has a default you can
override. A few protocol limits are fixed; they are named as such further
down.

- Timeouts are in whole **seconds**; the tick is in milliseconds; sizes and
  counts are in their own unit.
- A number is written in the digits `0` to `9` and nothing else: `0080` is
  80, while `-1`, `+80`, `#x50`, `80.0` and `160/2` are malformed.
- An unset or empty variable keeps the default.
- A malformed value is refused, not ignored: `serve` raises an
  `&http-server-config-error` naming the variable, before it listens.

## Where the server listens

| Variable | Default | What it sets |
|:--|:--|:--|
| `CHEZ_HTTP_HOST` | `127.0.0.1` | the IP address to listen on |
| `CHEZ_HTTP_PORT` | `8080` | the port, 0 to 65535; `0` takes any free one |

The default listens on this machine only, so nothing outside can reach the
server until you ask. In a container, set `CHEZ_HTTP_HOST=0.0.0.0` (or `::`
for IPv6 and IPv4 both). The host must be an IP address: a name such as
`localhost` is refused. Platforms that set `PORT` (Heroku, Cloud Run, Render,
Fly) need it passed on: `CHEZ_HTTP_PORT=$PORT`. The server's first log line
says where it listens, with the port it got: `listening 127.0.0.1 8080`.

## Limits

| Variable | Default | What it bounds |
|:--|:--|:--|
| `CHEZ_HTTP_READ_HEADER_TIMEOUT` | 60 s | time to receive the whole request head |
| `CHEZ_HTTP_IDLE_TIMEOUT` | 75 s | keep-alive idle time between requests |
| `CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT` | 60 s | longest gap between body reads |
| `CHEZ_HTTP_LINGER_TIMEOUT` | 30 s | how long a close waits for the client |
| `CHEZ_HTTP_WRITE_TIMEOUT` | 60 s | time for each write to complete |
| `CHEZ_HTTP_DRAIN_TIMEOUT` | 10 s | time a shutdown gives connections to end |
| `CHEZ_HTTP_TICK_MS` | 250 ms | how often deadlines are checked |
| `CHEZ_HTTP_MAX_HEADER_BYTES` | 16384 | all header names and values together |
| `CHEZ_HTTP_MAX_HEADER_COUNT` | 100 | number of header fields |
| `CHEZ_HTTP_MAX_HEADER_FIELD_BYTES` | 8192 | one header name |
| `CHEZ_HTTP_MAX_HEADER_VALUE_BYTES` | 8192 | one header value |
| `CHEZ_HTTP_MAX_TARGET_BYTES` | 8192 | size of the request-target |
| `CHEZ_HTTP_MAX_BODY_BYTES` | unbounded | every request body (`unbounded`: none) |
| `CHEZ_HTTP_READ_BUFFER_SIZE` | 16384 | per-connection read buffer |
| `CHEZ_HTTP_MAX_CONNECTIONS` | 10000 | connections open at once |
| `CHEZ_HTTP_BACKLOG` | 511 | connections waiting to be accepted |
| `CHEZ_HTTP_REQUIRE_HOST` | true | HTTP/1.1 requests must send `Host` |
| `CHEZ_HTTP_WRITE_HIGH_WATER` | 262144 | bytes unsent before a stream waits |
| `CHEZ_HTTP_WRITE_LOW_WATER` | 65536 | bytes unsent when it goes on again |

These are nginx-style bounded defaults: every wait and every buffer has an
end.

### Timeouts

What happens to a client that runs past a timeout, and to the connections
still open at a shutdown, is in [Connections](connections.md).

`CHEZ_HTTP_TICK_MS` is the one duration in **milliseconds**: its default,
250 ms, has no whole-second spelling. It must be from 1 to 1000. The server
checks deadlines once a tick, so a timeout acts at most one tick, and so at
most a second, after it passes.

### Sizes

- A request over any of the four header limits gets `431`, one whose target
  is over its limit gets `414`, and one whose body is over
  `CHEZ_HTTP_MAX_BODY_BYTES` gets `413`. Either way the connection closes.
- `read-whole-body` has a cap of its own, 1 MiB unless you give another
  ([Bodies and streaming](bodies.md)).
- A header value's limit, and the section's, count the spaces or tabs before
  the value too: in `Accept: */*` the value is 4 bytes, its space and `*/*`.
- A chunked body can carry fields after its last chunk (trailers). They are
  held to the same four header limits, counted apart from the headers: over
  one, `431`.
- **Fixed:** a chunk can carry extensions after its size (`5;name=value`). A
  body's extensions may come to 16 KiB in all: more gets `413`. A chunk size
  may have 16 hex digits, leading zeros included: more gets `400`.
- **Fixed:** before a request line the server skips up to 4 bytes of empty
  lines (two CRLFs), and between its parts it takes one space each: more of
  either gets `400`.

What else a target must be is in [Requests](requests.md).

### Connections

- A connection that arrives while `CHEZ_HTTP_MAX_CONNECTIONS` are open is
  closed at once. The first refusal is logged (`refusing`), and so is how
  many were refused (`refused`), once a connection is accepted again or the
  server stops: two lines, however many are refused.
- Each open connection uses a file descriptor, so set the process's
  open-file limit (`ulimit -n`) above `CHEZ_HTTP_MAX_CONNECTIONS`. A server
  out of descriptors closes new connections at once, without a log.
- Each idle connection holds about 17 KiB of memory, most of it its read
  buffer (`CHEZ_HTTP_READ_BUFFER_SIZE`, 16 KiB). So 10,000 open connections
  hold about 170 MB ([Performance](performance.md)).
- `CHEZ_HTTP_BACKLOG` is how many connections the kernel keeps waiting for
  the server to accept them, at most 2147483647; the kernel may cap it lower
  (`somaxconn`).
- `CHEZ_HTTP_REQUIRE_HOST` is `true` or `false`, nothing else. With `false`,
  an HTTP/1.1 request with no `Host` is served instead of getting `400`. The
  other `Host` rules always apply ([Requests](requests.md)).

### Streaming

The two water marks bound a streamed response
([Bodies and streaming](bodies.md)). The server asks the producer for the
next piece only while at most `CHEZ_HTTP_WRITE_HIGH_WATER` bytes are written
and not yet taken by the client. Once past it, it waits until no more than
`CHEZ_HTTP_WRITE_LOW_WATER` are. It also waits once 64 pieces are
outstanding, until 16 are: each piece costs the server work whatever its
size, and the count bounds it. Those two counts are fixed. A low water above
the high water is refused at startup.

## Configuring from code

`serve` reads the process's environment by default. Its optional second
argument replaces it: a procedure from a variable's name to its value, or
`#f` for unset ([Handlers](handlers.md#when-the-server-will-not-start)).

The limits live in the pure library `(http-server limits)`: the shell reads
the environment once and hands the values to the core, which is how the
tests exercise every limit with no environment at all.
