# 0004: Pipelining is strictly serial with read-stop in v1; the cap is data in the core

Date: 2026-09-19
Status: accepted (user decision, 2026-09-19)
Plan: [the brief](../2026-09-19-chez-http-server-project-brief.md) "What is settled"

## Context

nginx, Go's `net/http` and h2o serve one request per connection at a time and never build a response-reordering layer; Node parses ahead with an `outgoing[]` FIFO. Browsers disabled pipelining years ago and curl does not pipeline by default. The parser gives an exact boundary: `callback-pause` from `on-message-complete` makes `parser-result-consumed` mark the end of message N and `parser-result-next` the start of the retained remainder (measured: 51 then 47 bytes). In strict mode the parser errors on any byte after a close-marked message, so the connection layer must stop feeding at that boundary regardless.

## Decision

1. At `on-message-complete` the core answers `(reply-parser pause)`, emits `(read-stop)`, retains the delivery's remainder as `pending-input`, and emits `(call-handler request)`. When the response has been written it emits `(resume-parser)`, `(feed-parser pending)`, `(read-start)`.
2. `max-pipeline` is a field of the limits record with default 1. The `inflight`/`ready`/`head` ordering machinery stays in the core with a test that the wire carries responses in strictly increasing id, so raising the cap is a setting and a test.
3. During a handler the connection does not read. A client reset during a long handler is seen when reading resumes (write failure or read error). Node's read-while-handling with a bounded inbox is recorded as the alternative if that latency ever matters.
4. After a `Connection: close` message, or an HTTP/1.0 message without keep-alive, `bytes-arrived` produces no `feed-parser`; the parser's `closed-connection` error is ignored if it fires first.

## Consequences

- No response-ordering queue is exercised in v1; memory per connection is one request.
- `pending-input` and the pause protocol are pinned by tests at every chunk size (M2), including byte-machine's need for one more feed after a pause on the last body byte.

## Amendment (2026-09-20)

The limits field named `max-pipeline` in decision 2 above shipped in M0 as
`pipeline-cap` (environment override `CHEZ_HTTP_PIPELINE_CAP`). The decision is
unchanged. ADR-0005's amendment records the full set of M0 limits-naming changes.

## Amendment (2026-09-25) — the remainder is kept one step after the pause

M2.4 built item 1's cycle, with one change of timing and one clarification.

- **The remainder is kept by the result that follows the pause.** The parser says
  where it stopped, `parser-result-next`, only when the feed returns, so the core
  cannot keep the remainder at `on-message-complete`. It keeps it when the
  `parser-result` that follows the pause arrives, with the connection in `handling`,
  before any queued action runs. The remainder is always the end of the last
  delivery the core fed: reading stops at the pause and the remainder is fed before
  reading starts again. Measured at the pin on `research/spike/pipeline-pause.sps`'s
  three messages, 117 bytes, the parser stops at 51 and then at 98 (2026-09-25,
  Darwin arm64, Chez 10.4.1 `tarm64osx`), as it did on 2026-09-19.
- **Item 4's error cannot fire.** The core pauses at every message's end and drops the
  remainder after a close-marked message, so the parser is never fed past one, and
  its `closed-connection` error ("Data after `Connection: close`") never comes. If it
  did, it would not be answered; the connection table's P2 row holds that.
