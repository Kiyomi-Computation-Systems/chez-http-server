# 0005: Bounded, nginx-style default limits and timeouts; one tick timer and a timing wheel per loop; every limit from the environment

Date: 2026-09-19
Status: accepted (user decision, 2026-09-19)
Plan: [the brief](../2026-09-19-chez-http-server-project-brief.md); reference-server survey in research/server-*.md

## Context

Go ships unlimited timeouts and warns about it; nginx re-arms an independent deadline per phase (header 60 s, body 60 s, keep-alive 75 s, send 60 s); Node bounds headers (60 s), the whole request (300 s) and idle (65 s); warp uses one tickled idle timer; h2o uses 10 s for both. Header caps range from 16 KiB (Node, h11) to 1 MiB (Go). One `uv_timer_t` costs 152 B and a registry entry; 10k per-connection timers are affordable but pointless, and warp's classic timeout manager shows one shared timer suffices.

## Decision

Defaults, all fields of `(http-server limits)` and all overridable by `HTTP_SERVER_<NAME>` environment variables parsed once by the shell:

| Limit | Default | On breach |
|---|---|---|
| `header-timeout-ms` | 60 000 (armed at `on-message-begin`, disarmed at `on-headers-complete`) | 408, close |
| `body-timeout-ms` | 60 000 inactivity, re-armed on every `on-body-data` | 408, close |
| `idle-timeout-ms` | 75 000 (keep-alive, armed when nothing is in flight) | close, no response |
| `write-timeout-ms` | 60 000 per write completion | close |
| `drain-timeout-ms` | 10 000 after SIGTERM | force-close all |
| `max-header-bytes` | 16 384 total | 431, close |
| `max-header-count` | 100 | 431, close |
| `max-header-field-bytes` / `max-header-value-bytes` | 8 192 | 431, close |
| `max-target-bytes` | 8 192 | 414, close |
| `max-body-bytes` | #f — bodies stream to the handler; only the buffering helper takes a limit, default 1 MiB | 413 |
| `max-pipeline` | 1 | pause + read-stop |
| `write-high-water` / `write-low-water` | 262 144 / 65 536 bytes outstanding | read-stop / read-start |
| `read-buffer-size` | 16 384 | — |
| `max-connections` / `backlog` | 10 000 / 511 | refuse in `on-connection` |
| `tick-ms` | 250 | — |

Deadlines are data in the pure state (`deadline`, `deadline-kind`); the shell keeps a hashed timing wheel keyed by `(deadline div tick-ms)` and dispatches `(tick now)` only to connections in expired buckets. The tick timer is the only timer handle; it is stopped when the wheel is empty. A deadline of D ms fires within [D, D + tick-ms].

## Consequences

- Timeout tests drive `(tick now)` with a fake clock and never sleep.
- The idle server sleeps in `uv-run 'once` with no periodic wake-up.
- A future millisecond-exact option (one `uv-timer` per connection, `uv-timer-again!`) changes only the `arm-deadline` executor, not the core.

## Amendment (2026-09-20) — names as shipped in M0

M0 implemented `(http-server limits)` (`src/http-server/limits.sls`) with two
naming changes from the table above; recorded here in full so this decision matches
the code and stands on its own:

- **Environment prefix:** overrides use `CHEZ_HTTP_<NAME>` (e.g.
  `CHEZ_HTTP_READ_HEADER_TIMEOUT`), not `HTTP_SERVER_<NAME>`.
- **Three field renames:** `header-timeout-ms` → `read-header-timeout-ms`;
  `body-timeout-ms` → `body-inactivity-timeout-ms`; `max-pipeline` → `pipeline-cap`
  (`max-pipeline` is also named in ADR-0004).

Every other shipped field keeps its table name, and all defaults and on-breach
behaviour are unchanged. The remaining limits (write/drain/header-field/water-mark/
connection/tick) are not yet in the M0 record; they arrive with later milestones
under the same `CHEZ_HTTP_` prefix. The rung-2 design document carries the same
field map with rationale.

## Amendment (2026-09-25) — one switch rides with the limits: CHEZ_HTTP_REQUIRE_HOST

RFC 9112 §3.2 says a server MUST answer 400 to an HTTP/1.1 request with no
Host. Decided on the owner's word on 2026-09-25, the server does so by default,
behind a switch:

- **The field.** `(http-server limits)` gains a twelfth field, `require-host?`
  (`limits-require-host?`), default `#t`, read from `CHEZ_HTTP_REQUIRE_HOST`.
  The value is exactly `true` or `false`; anything else is refused, as a
  malformed size is. An unset or empty variable keeps the default.
- **Why a switch.** Node's HTTP server has the same one (`requireHostHeader`,
  default on). The corpus lane runs the core with it off, because 61 of the
  135 strict llhttp fixtures are HTTP/1.1 requests with no Host. Refused, they
  would be checked only up to their headers, losing the body, pausing and
  pipelining coverage they give.
- **What it does not switch.** Two Host lines, or a Host value that is not
  `uri-host [ ":" port ]`, are refused with 400 whatever it says: the corpus
  has neither, and RFC 9112 §3.2 gives them no exception.

It is the one field that is not a bound. It rides here because the core reads
every connection setting from this record, and the shell fills it from the
environment the same way.

## Amendment (2026-09-25) — the pipeline cap accepts only 1

The table's `max-pipeline` row, shipped as `pipeline-cap`, is no longer a bound anyone
can raise. Decision 0004's amendment of the same day makes v1 serial by design, so
`CHEZ_HTTP_PIPELINE_CAP` accepts 1 and refuses any other value at startup, as a
malformed value is refused. The field stays in the record, so a future parse-ahead
design keeps its name.

## Amendment (2026-09-25) — the write watermarks arrive in M6

Decided on the owner's word on 2026-09-25, when M3 began
([decision 0010](0010-the-server-writes-framing-connection-and-date-and-refuses-a-response-it-cannot-write-safely.md)
item 5). The table's `write-high-water` / `write-low-water` row says to stop reading
above 262,144 bytes outstanding and to start again below 65,536. In v1 that read-stop
can never fire. A handler's response is written with reading already stopped (decision
0004 item 1), and only one response is ever outstanding.

- **The two fields arrive in M6**, not in M3 as the milestone plan's §3 had it. M6
  streams response bodies, which is the first time a response can outrun its client
  and a test can watch the watermarks act. M6 settles what crossing them does, and
  this row's on-breach column is not in force until then.
- **M3 keeps the accounting.** Its write action carries the write's byte count, and
  the core tracks the bytes and writes outstanding.
- The defaults are unchanged.

## Amendment (2026-09-26) — a row for the staged close: linger-timeout-ms

Decided on the owner's word on 2026-09-26
([decision 0011](0011-every-close-after-a-response-is-staged-lingering-up-to-30-s.md)):
every close after a response is staged. The connection lingers, reading and dropping
what arrives, until its client closes or this limit passes.

| Limit | Default | On breach |
|---|---|---|
| `linger-timeout-ms` | 30 000, armed once when the connection starts lingering, never re-armed | close |

It is the thirteenth field of `(http-server limits)`, read from
`CHEZ_HTTP_LINGER_TIMEOUT` in whole seconds, as the other timeouts are. It matches
nginx's `lingering_time` and Apache's total linger. As with the other durations, the
core never reads it: it arms the `linger` kind, and M5's wheel turns the kind into an
instant.

## Amendment (2026-09-26) — the connection cap and the listener, as M4.3 built them

Decided on the owner's word on 2026-09-26, by form (the ledger's M4.3 entry has the
options weighed).

- **The table's row is unchanged**: `max-connections` 10 000 and `backlog` 511, read
  from `CHEZ_HTTP_MAX_CONNECTIONS` and `CHEZ_HTTP_BACKLOG`. A refused connection is
  accepted and closed at once, as nginx closes one its `worker_connections` cannot
  hold: libuv takes a connection off the socket before the listener's callback runs,
  and stops watching the listener until it is accepted.
- **The backlog is at most 2147483647**, the largest C `int`, which is what libuv's
  `uv_listen` takes; a larger value is refused at startup like a malformed one.
- **A refusal episode is logged twice at most**: its first refusal, then how many
  were refused, when a connection is next accepted or the server stops listening. A
  flood of refused connections cannot fill the log. Weighed: every refusal, as nginx
  does.
- **A listener that fails shuts the server down**: the failure is logged, the listener
  closed, and the server drains, so the process ends once its connections finish and
  whatever supervises it starts it again. libuv reports such a failure only on Windows,
  where the listener has already stopped. Weighed: logging only, which leaves a server
  that runs and never accepts; listening again, which needs M5's timer for a delay.

## Amendment (2026-09-27) — the tick is at most a second

Decided on the owner's word on 2026-09-27, by form, after M5.1's review.

- **`tick-ms` is 1 to 1 000.** Every timeout is given in whole seconds, so a tick over a
  second would make one late by more than its own unit. The default, 250, is unchanged,
  and a larger value is refused at startup as a malformed one is. Weighed: 2^64 − 1,
  the most libuv's timer takes, which still accepts a tick that never fires.

## Amendment (2026-09-27) — the wheel fires by deadline, and each connection keeps its entry

Decided on the owner's word on 2026-09-27, by form, after M5.1's review.

- **The wheel fires each deadline as `now` reaches it, not a bucket once it has
  expired.** Buckets, `(deadline div tick-ms)`, only say where to look. The rule above,
  dispatching "only to connections in expired buckets", cannot keep the bound it states,
  because libuv's timer does not tick on bucket boundaries. With D = 1000, in the bucket
  1000–1249, and ticks at 1100 and 1350, the bucket rule fires at 1350, D + 350; fired by
  its own deadline, it fires at 1100. The bound stands: a deadline of D fires within
  [D, D + tick-ms], never before D. Its instants are the loop's clock, `uv_now`, which
  never steps, not the wall clock the `Date` line is made from.
- **Each connection keeps its own entry in the wheel,** so arming and disarming a
  deadline allocate nothing: a disarm then an arm measured 96 B with the wheel keeping a
  table from connection to entry, which was weighed, and 0 B this way.

## Amendment (2026-09-28) — max-body-bytes, as M6.1 built it

Decided on the owner's word on 2026-09-28, by form
([decision 0013](0013-a-handler-reads-a-body-through-a-reader-it-answers-with-at-the-head-and-streams-one-out-through-a-thunk.md)
item 5). The table's row is read as its words say: bodies stream to the handler, and
nothing caps them by default.

- **`max-body-bytes`, when set, caps every body**, streamed or buffered, from
  `CHEZ_HTTP_MAX_BODY_BYTES` in bytes (`unbounded`, or unset, for none). A declared
  Content-Length past it is answered `413`, then close, before the handler is asked; a
  chunked body at the piece that passes it, a streaming reader handed the piece up to
  the cap first.
- **The buffering helper, `read-whole-body`, takes a cap of its own**, 1 MiB
  (1,048,576 B) unless the handler gives another, answered the same way. The lower of
  the two caps is the one a body meets.
- The default is unchanged.

## Amendment (2026-09-28) — the write water marks, as M6.3 built them

The amendment of 2026-09-25 left the on-breach column of the `write-high-water` /
`write-low-water` row out of force until M6 settled what crossing them does. M6.3
settles it as plan §14 and
[decision 0013](0013-a-handler-reads-a-body-through-a-reader-it-answers-with-at-the-head-and-streams-one-out-through-a-thunk.md)
item 8 set it out, with no new decision:

| Limit | Default | On breach |
|---|---|---|
| `write-high-water` | 262 144 bytes outstanding | a streamed response's producer waits |
| `write-low-water` | 65 536 bytes outstanding | the producer is asked again |

- **They pace the producer, not reading.** A producer is asked for a piece only while
  the bytes written and not yet completed are at or below the high water, so at most one
  piece passes it; past it, it waits until a completion brings them to the low water.
  Reading is not touched: a connection reads nothing while it writes a response
  (decision 0004 item 1), so the row's read-stop and read-start had nothing to act on.
- **The four things.** They are the eighteenth and nineteenth fields of
  `(http-server limits)`, read in bytes from `CHEZ_HTTP_WRITE_HIGH_WATER` and
  `CHEZ_HTTP_WRITE_LOW_WATER`; each has a value test against this table's default, its
  variable in `limits-environment-variables`, and the drift guard over it.
- **A low water above the high water is refused** at startup, as a malformed value
  is, whichever of the two was set: the producer would go on before it had waited.
  Equal marks, and marks of 0, are accepted. At a high water of 0 the producer is asked
  again only once every write has completed. `limits-with`, which checks no value,
  can still make one; the core then asks a waiting producer at or below both marks, so
  never past the high water (M6.3's review).
- The defaults are unchanged.

## Amendment (2026-09-29) — the writes outstanding are bounded too

M6.3's second review, on the owner's ask to check the empty piece's fix for safety and
performance, found the water marks blind to small pieces. They count bytes, and each
piece a producer answers is a write of its own, which holds the loop and memory the same
whatever its size: its request, a `uv_write_t` (192 bytes at libuv 1.52.1 on Darwin
arm64), 16 bytes a segment, and chez-libuv's records. So a turn asked for pieces until
256 KiB was outstanding: some 2,500 times for 100-byte pieces, and some 43,700 for 1-byte
ones chunked. Measured on Linux (Debian 12, libuv 1.44.2, in Docker, aarch64), one run
each, a client reading as fast as it could: another client's request waited 50.6 ms at
the median behind 100-byte pieces and 1,019 ms behind 1-byte ones, where 16 KiB pieces
kept it at 0.11 ms; and a client that never read held 0.71 MB of 100-byte pieces,
21.6 MB of 1-byte ones chunked, and 129.5 MB of them to HTTP/1.0. On Darwin arm64
(libuv 1.52.1): 250 ms and over 5 s, and 0.69, 12.4 and 102.7 MB.

Decided on the owner's word, by form (2026-09-29): the writes outstanding are bounded as
well, by fixed values, not settings.

| Bound | Value | On breach |
|---|---|---|
| writes outstanding, high | 64 | a streamed response's producer waits |
| writes outstanding, low | 16 | a waiting producer is asked again |

- A producer is asked only while the bytes are at or below `write-high-water` and fewer
  than 64 writes are outstanding; once past either, it waits until the bytes are at or
  below `write-low-water` (and the high water) and 16 or fewer writes are. The core's
  `stream-writes-high` and `stream-writes-low` hold them; `(http-server limits)` is
  unchanged.
- 64 writes of 4 KiB are the high water, 256 KiB, so pieces of 4 KiB or more meet the
  byte marks first, as before; 16 keeps the marks' four to one.
- Measured on the final code, the same Linux run: another client's request waited
  0.91 ms behind 100-byte pieces and 0.90 ms behind 1-byte ones; a client that never
  read held 0.07 MB of 100-byte pieces and no growth measurable of 1-byte ones; 16 KiB
  pieces are unchanged, 0.11 ms, 2,097.9 MB/s and 0.26 MB.
- It bounds, and does not speed: 100-byte pieces stream about 31 MB/s either way, each a
  write of its own. A handler that gathered them into 16 KiB pieces streamed 873.0 MB/s,
  and handlers.org says to gather them.
- Weighed: the cap and the server gathering small pieces into writes of about 16 KiB
  itself, about 28 times the throughput, but a change to the core's pacing and to the
  serializer's framing, and a copy of every small piece, since a producer may hand out
  one bytevector again; left for work of its own. Docs alone, which would have left the
  stall for every handler that missed them. And the two counts as settings; kept fixed.
- **Prior art** (checked on 2026-09-29 against each project's source and documentation,
  on the owner's ask). Of the servers this decision compares, none counts the writes a
  response has queued against a limit, as this amendment does. Most copy small pieces
  together into fewer writes, h2o keeps one send in flight, and those that run a handler
  on a thread or goroutine of its own block it while the client is behind:
  - h2o pulls, as this core does: it calls a generator's `proceed` for more once the
    last send's write has completed, and the generator waits for it before sending again,
    so a response has one send in flight. One send may carry many pieces, and HTTP/1
    frames them as one chunk in one write (`include/h2o.h`, `lib/http1.c`).
  - nginx copies a proxied response into a fixed number of fixed-size buffers
    (`proxy_buffers 8 4k|8k`), holds output back until 1,460 bytes are ready
    (`postpone_output`), and limits one send to `sendfile_max_chunk` (2 MiB since
    1.21.4), leaving the rest to the next loop iteration so one fast connection does not
    seize the worker. One `writev` gathers at most 64 buffers (`NGX_IOVS_PREALLOCATE`).
  - Node counts bytes only: a writable's `highWaterMark` (64 KiB since v22, 16 KiB
    before and on Windows) is reported by `write()`, not enforced. A socket keeps one
    native write in flight, and what is written meanwhile goes out as one `writev`.
  - Go's `net/http` copies a handler's writes into a 2,048-byte buffer
    (`bufferBeforeChunkingSize`), so small writes leave as chunks of about 2 KiB, and a
    write blocks the handler's goroutine while the socket is backed up.
  - warp writes into a 16 KiB buffer and blocks its thread; each write is still framed
    as a chunk of its own.
  - Apache httpd 2.4 holds a brigade back under 4,096 bytes (`THRESHOLD_MIN_WRITE`),
    copies small writes into 8,000-byte buckets, and blocks past `FlushMaxThreshold`
    (65,535 bytes by its docs).

  Outside that set, hyper does what this amendment does: for vectored IO, its write
  queue takes a buffer only while it holds fewer than 16 (`MAX_BUF_LIST_BUFFERS`) and
  fewer than 417,792 bytes (`DEFAULT_MAX_BUFFER_SIZE`), and it flushes before polling
  the body again; for other IO it copies the pieces into one buffer
  (`src/proto/h1/io.rs`). libuv itself, under the shell, finishes at most 33 queued
  write requests in one pass of `uv__write` before it yields, to "prevent loop
  starvation" (`src/unix/stream.c`). The 64 here sits among those counts. The copying
  the others do is the gathering weighed above, left for work of its own.

## Amendment (2026-09-29) — the shell gathers a turn's small writes

The gathering the amendment above left for work of its own. Decided on the owner's word,
by form (2026-09-29), while M6.3's five PRs were open: its own PR, after them. Weighed: a
sixth stacked PR; a note for later.

- **The libuv shell holds a write under 4,096 bytes** and sends a turn's held writes as
  one libuv write, where each was one, with its request and its completion. What is held
  goes out once the drain has run the queue empty, and first before a shutdown, a close,
  or a larger write, which goes out alone as before. The core, its events, the water
  marks and the 64-write cap are unchanged: the write's completion reports each write it
  carried, in order.
- **A held write is copied as it is held**, since a producer may hand out one bytevector
  again, refilled; a prototype that held pieces by reference sent every piece of a turn
  as its last.
- **Measured on Linux**, as the amendment above measured (Debian 12, libuv 1.44.2, in
  Docker, aarch64), three runs each, the median: 100-byte pieces stream 182.9 MB/s where
  they streamed 32.8, and 1-byte pieces 11.4 where they streamed 1.9; another client's
  request waits 0.19 ms at the median behind the 100-byte pieces, where it waited 0.85;
  16 KiB pieces are unchanged, 2,066.0 MB/s. A handler that gathers 100-byte rows into
  16 KiB pieces still streams them faster, 851.1 MB/s, about 4.7 times, where it was
  about 26: each piece still costs a producer's call, the core's step and its framing.
- **The cap stays.** It bounds how many pieces a turn asks the producer for, and libuv's
  own guard, 33 requests a pass, counts writes, now one a turn.
- **The head goes out first** (decided on the owner's word, by form, after the PR's
  review): what is held goes out before the drain first calls a producer, so a stream's
  head never waits for its pieces, which go out a turn at a time. A producer that took
  2 ms a piece had delayed its head from 0.14 ms to 126.3; it arrives at 0.19 now, where
  main sent it at 0.20. Weighed: the docs alone; sending what had been held a
  millisecond before each producer call, which cost fast small pieces 5 to 17 %.
- Design §7.3's note of this day has the three shapes tried and the cutoff's
  measurement.

## Amendment (2026-09-29) — a chunked body's trailers and chunk extensions are bounded (M6.4)

Decided on the owner's word, by form (2026-09-29), when M6.4 opened. Until M6.4 a chunked
body's trailer fields and chunk extensions were held to no limit: measured on the tree
before it (Darwin arm64, the fake shell), 101 trailer fields, a 9,000-byte trailer value
and 16 MB of trailers were each answered 200, and so was a 16-byte body carrying 16 MB of
extensions. The server keeps neither, so the bound is on the work a client can make the
server do, not on memory: the body deadline is re-armed by each piece of data, not by
these bytes.

- **A trailer section is held to the four header limits** (`max-header-bytes`,
  `max-header-count`, `max-header-field-bytes`, `max-header-value-bytes`), counted afresh,
  so the head's fields leave the trailers theirs. Past one, `431`, then close, as a head.
  hyper holds its trailers the same way, to 16 KiB and its field count. Weighed: one
  budget with the head; the body's cap, as freenginx counts trailers and extensions
  together, which would leave them unbounded here by default.
- **A body's chunk extensions, their names' and values' bytes, all of them together, are
  held to 16 KiB**, fixed, not a setting, as hyper holds a body's, and as RFC 9112 §7.1.1
  advises a limit on the total in a request. Past it, `413`, then close, as a body past a
  cap, logged as `chunk-extensions-too-large`. Weighed: leaving them for M8.3's robustness
  lane. *Corrected in M6.4's review, the same day:* the form called 16 KiB "hyper's and
  Node's figure", and this bullet had Node holding a body's; Node holds each chunk's to
  16 KiB (since CVE-2024-22019), its count restarted at every chunk. Weighed again, on the
  owner's word by form, over the eight servers researched: hyper, h2o and Go bound a body
  (h2o and Go by a share of the data), as freenginx does within its body cap; Node bounds
  each chunk, h11 and Racket each line; nginx and Warp nothing. Kept.
- **What the parser reads and hands the core no span of is not counted**, found while
  building: the spaces between a field's colon and its value, in a head or a trailer
  section, and a chunk size's leading zeros. A megabyte of either was accepted. The
  owner's word the same day gives them their own PR, after M6.4, its design by form on
  measurements. Go refuses a chunk size of more than 16 hex digits, and a size line over
  4 KiB; nginx a header line over 8 KiB.

## Amendment (2026-09-30) — what the parser reads and hands no span of is bounded (the padding PR)

Decided on the owner's word, by form (2026-09-30), on measurements of main (Darwin arm64,
the fake shell, the default limits, 16 KiB reads). The parser reads four runs of bytes it
hands the core in no span, and a megabyte of each was answered 200: spaces or tabs before
a field's value, in a head or a trailer section; zeros before a chunk size; spaces past
the one between the request line's parts; and empty lines before a request line. The
last two were found at that step. Like M6.4's, the bound is on the work a client can make
the server do: none of these bytes is kept, and none re-arms a deadline.

- **The whitespace before a field's value counts with the value**, against
  `max-header-value-bytes` and `max-header-bytes`, `431` past either, in a head and in a
  trailer section, as the whitespace after it already did, inside the value's span. So a
  field at an exact limit moves by the space after its colon. Every server researched but
  Node counts it, in a head or a line budget. Weighed: every byte of each line, the peers'
  way, which would move the limits by about 4 bytes a field.
- **A chunk size has at most 16 hex digits, leading zeros included**, fixed, not a
  setting; more is `400`, logged as `chunk-size-too-long`. Go and h2o hold it there;
  h11 holds 20, Racket a size line to 8 KiB, and nginx, freenginx, hyper, Node and Warp
  only overflow. Weighed: 20; Go's allowance for bytes that are not data.
- **One space between the request line's parts**, as RFC 9112 §3's grammar has it;
  more is `400`, logged as `request-line-spaces`. Go, hyper, h11 and Warp answer 400;
  nginx, h2o and Racket count the spaces in their request line. Weighed: counted with the
  target, `414`.
- **Two empty lines, 4 bytes, before a request line**, at a connection's start or between
  requests; more is `400`, logged as `empty-lines`. RFC 9112 §2.2 asks a server to ignore
  at least one; freenginx (since 2024) and h2o skip one, Go 4 bytes after a POST, hyper
  any number within its read buffer; nginx and Node any number, bounded only by a timer.
  Decided first as one, then, on the owner's word by a second form, two: llhttp's own
  fixture "CRLF between requests, implicit keep-alive" has a POST's body followed by two,
  which one refused, and the trace lane holds the core to never changing what the parser
  does. Weighed: two after a body only; one, the fixture a recorded exception.

The core measures them by the parser's position, which every event callback now carries
(design §4.2's amendment of this day): from where one piece ends to where the next begins,
at the callback that ends a run and, while it runs, at every read's end, so a run is
refused within the read that passes its limit, whatever the split. At the parser's error
only the whitespace is judged: a span the error cut off is never handed on, so its bytes
would count as the run's.

## Amendment (2026-09-30, later) — the padding PR's review

A /code-review max of the padding PR found four places where the rules above did not hold
at every split, or did not count what they said. Each was decided on the owner's word, by
form (2026-09-30), after every option was measured in a scratch copy (Darwin arm64, the
fake shell, every delivery size).

- **A chunk's extensions count every byte, an empty one's too.** M6.4's 16 KiB counted
  the bytes of names and values only. The strict parser takes empty ones, a size line of
  `;=` or `;` over and over, so a megabyte of them was served 200 in about 92 ms of CPU.
  The cost grew linearly, and only the body deadline bounded it. Now each name and each
  value counts a byte as it ends, for the `;` or `=` before it. A quoted value's quotes
  are in its span, so by a line's end every byte of its extensions has counted. A
  megabyte of `;=` is refused 413 within its second 16 KiB read, in about 2 ms.
  Weighed: every byte by position, a run from the `;` to the CR (the same answers, but
  one large delivery parsed whole before the refusal); Go's 4 KiB a size line alone
  (still served a megabyte spread over short lines, and split 400 from 413).
- **A 431 names the limit its bytes passed first.** One stretch of bytes could pass both
  a field's own limit and the section's, and which one the refusal named depended on
  where the reads ended. 496 of 2,856 swept trailer inputs split that way, 224 of them
  already on main. Now the reason is the limit passed at the earlier byte, and the
  field's if both are passed at the same byte. None of 56,692 swept and fuzzed inputs
  splits. Weighed: leaving it, since the status is 431 either way.
- **An empty value's line end does not count.** The parser hands an empty value over
  only after its CRLF, so the whitespace counted those 2 bytes too. 8,191 spaces and a
  CRLF were refused where 8,191 spaces and a one-byte value were served. Now the line end
  is left out, and at a read's end the whitespace is judged on its length less 2.
  - Where the parser ends an empty value at a byte it then refuses, the 2 bytes are left
    out too. Such a value at most 2 bytes past its limit gets the parser's 400, not 431,
    the same at every split.
  - Weighed: counting the line end, and saying so in the docs.
- **The spaces after a target are counted however the target ends.** The parser ends a
  target at a space, a CRLF or a bare LF, and does not say which. The core had counted
  only from one byte past the target, taking that byte for a space. So a request line
  with no version, ended by a bare LF, was refused 400 or served 200 depending on where
  reads ended.
  - Now the count opens however the target ends, and a field or the head's end lets it
    go. A read may end one byte past its limit without a refusal: a versionless line's
    CR.
  - The only change in behaviour: a client that stops after one extra space now waits
    for the header timeout instead of getting 400 at once.
  - Weighed: checking that byte for a space (the same answers, but hand-built table rows
    then need a delivery).

Also by form: a run past its limit, then a parse error, is answered 400 at every split.
Its reason, though, is the run's or the parser's depending on where reads end. That goes
with the PR after this one, with main's own span cut off by an error, since both need to
know where a span the error cut off began (plan §14).

## Amendment (2026-10-01) — what the parser's error cuts off

A malformed byte ends the parse, and the span the parser was reading is abandoned, never
handed on (chez-httparse `docs/api.org`: "an error abandons an open span rather than
flushing it"). Only a target's and a field name's can be: a value, an extension and the
protocol are handed on before their errors (11,790 errors, every byte of seven requests
replaced and preceded by 22 values). So a target or a field name past its limit, then such
a byte, was answered for the limit where a read ended between the two, and 400 where one
read held both. On main a 9,000-byte target and then a control byte was 414 at 111 of 174
delivery sizes and 400 at 63, and of 40,000 fuzzed malformed requests, 980 split: 326 by
status, 654 by reason only, the run-then-error reasons the review above sent here.

Now at the parser's error the core judges what it cut off as a read's end would have: the
span's bytes it was not handed, up to the byte the parser refused, and then the run still
open. The first limit passed, in the order of the bytes, names the response at every split,
as it does when every read is one byte. None of the 40,000 splits; on 20,000 more, every
answer is the one-byte reads'. The corpora's lanes print what they printed.

Where a cut-off span began the parser does not say. Until byte-machine #145 lands (decision
0008), the core places it: a field name where its line begins, which the event before it
gives, and a target one byte after the method's space, unless that byte is another space,
when the spaces passed their limit first.

Decided on the owner's word, by form (2026-10-01), after the owner asked whether the change
would make byte-machine a better product. Weighed: building only once #145 lands; the core
alone, with no ask.

*Since the pin PR (2026-10-01):* byte-machine v0.7.0's error records where the span it
abandoned withheld its bytes (its #145), and the core reads that in place of placing the
span. A target's or a name's withheld bytes run from there to the refused byte, after the
ones a read's end handed on; a target that began in the read that failed has the spaces
before it judged first, as its first bytes would have. Over the 40,000 fuzzed requests at
every delivery size, the error's offset and the core's own placement agreed at all 615,192
targets and names cut off, and every answer is unchanged.

## Amendment (2026-10-02) — a second timer a loop, for the waits (decision 0015, M7.2)

The tick timer is no longer the only timer handle. A handler's sleeps and deadlines
(`sleep-ms`, `with-deadline`) are timed to the millisecond by a second timer a loop, the
waits', armed for the earliest of a binary heap of them (`(http-server heap)`). Like the
tick timer it is stopped while nothing is armed, so an idle server still sleeps, and
closed by a shell that serves no more. The connections' deadlines keep the wheel and its
tick. Measured for decision 0015 (`research/spike/m7-waits.sps`): on the wheel's 250 ms
tick, a 10 ms sleep took 250.7 to 256.2 ms; on the waits' timer, 10.2 to 13.7 ms.

## Amendment (2026-10-03) — drain-timeout-ms, as M8.1 built it

The table's `drain-timeout-ms` row arrives in M8.1 (milestone plan §3 and §14), with
its default and on-breach column unchanged: once a shutdown is asked for, the server
waits 10 000 ms for its connections to finish, then closes the rest at once.

- **The four things.** It is the twentieth field of `(http-server limits)`, read from
  `CHEZ_HTTP_DRAIN_TIMEOUT` in whole seconds, as the other timeouts are; 0 is accepted,
  and closes what is open at the first tick. It has a value test against this table's
  default, its variable in `limits-environment-variables`, and the drift guard over it.
- **The deadline is the server's,** not a connection's: `server-step` sets it at the
  shutdown's instant plus this limit, and the first tick at or after it asks for every
  connection still open to be closed. So it fires within [D, D + `tick-ms`], as the
  connections' deadlines do, and the tick timer runs while the server drains, whatever
  the wheel holds.
- **"After SIGTERM" reads "after SIGTERM or SIGINT".** Decided on the owner's word, by
  form (2026-10-03), on measurements of main: Ctrl-C left an idle `serve` running, and
  its next request was reset. Weighed: SIGTERM alone, as the table and the brief say. A
  listener that fails (the amendment of 2026-09-26) drains the same way. On Windows
  libuv delivers no SIGTERM (its `docs/src/signal.rst`), so Ctrl-C alone drains there.
- **The drain is logged** (decided the same day, by form): `draining` with the
  connections it waits for, `drain-timeout` when this limit closes what is left, and
  `stopped` at its end. Weighed: no new lines.
