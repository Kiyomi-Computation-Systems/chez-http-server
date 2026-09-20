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
