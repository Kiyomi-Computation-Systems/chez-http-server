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
