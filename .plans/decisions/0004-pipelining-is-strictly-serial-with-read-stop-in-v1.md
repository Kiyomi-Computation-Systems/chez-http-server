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

## Amendment (2026-09-25) — item 2: serial by design

Decided on the owner's word on 2026-09-25, after M2.4 found that no slice builds item 2's
ordering machinery and that `pipeline-cap` was read by nothing.

1. **Item 2 is withdrawn.** v1 answers the requests on a connection one at a time, by
   design, not as a default. The core has no `inflight`/`ready`/`head` ordering
   machinery. So raising the cap is no longer "a setting and a test". The nine states
   of design §4.3 serve one message in flight: `handling` does not read. A cap above
   1 would need the connection to read while it answers, which means:
   - about half of the connection table's 22 rows change (H6–H10, T1, T3, T4, T6, T7
     and P1);
   - handler events need request ids;
   - one deadline per connection no longer holds.
2. **The cap accepts only 1.** `pipeline-cap` stays a limits field, so a future
   design keeps its name, but `CHEZ_HTTP_PIPELINE_CAP` refuses any other value at
   startup rather than accepting it and ignoring it.
3. **Parse-ahead, if ever wanted, is a new decision** with its own design, set against
   a throughput goal. M8's load test is the first place to set one (decision 0002's
   amendment on what the allocation gate measures).
4. **Item 3's alternative is untouched.** Reading during a handler only to notice a
   client leave, with a bounded inbox and nothing parsed ahead, stays open as item 3
   records it.

What was weighed, measured 2026-09-25 on Darwin arm64, Chez 10.4.1 `tarm64osx`:
- **What parsing ahead would save the parser.** On 16 pipelined GETs in one buffer,
  pausing at every message's end costs 47 to 69 ns (3–5%) and 384 B per request, one
  feed more per message (`research/spike/pipeline-parse-ahead.sps`, two runs).
  Requests that do not arrive pipelined gain nothing. Writing a batch of responses in
  one call might gain more, and cannot be measured before M3 and M4.
- **Who pipelines.** Browsers turned pipelining off years ago (the context above), and
  libcurl disabled HTTP/1 pipelining in 7.62.0. TechEmpower's plaintext test assumes
  pipelining support, which a serial server gives: it answers pipelined requests in
  order. 2 of the 135 strict llhttp fixtures and 1 of libhtp's 102 streams carry more
  than one request.
- **What parsing ahead costs.** Each request in flight holds its delivery, up to
  `read-buffer-size` (16 KiB by default), and its response waits its turn. Reading
  while handling loses read-stop's backpressure. A request body must be read through,
  and buffered, to reach the next request. Node, which parses ahead, needed flood
  throttling after CVE-2013-4450 (pipelined requests whose responses were never read
  exhausted its memory) and discards bodies its handlers never read.
- **The alternatives.** For item 2: plan the machinery for M7, the first milestone
  whose handlers can wait; or build it now, before M2.5. For the variable: remove the
  field; or leave it accepting any value, with the docs saying only 1 takes effect.
