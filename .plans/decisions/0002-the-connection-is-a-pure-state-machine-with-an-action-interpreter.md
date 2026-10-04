# 0002: The connection is a pure state machine; the shell interprets its actions

Date: 2026-09-19
Status: accepted
Plan: [async-model options](../2026-09-19-async-model-options.md) "The chosen hybrid"

## Context

chez-httparse fires its 25 callbacks synchronously inside `parser-feed!` and requires an answer from each; byte-machine refuses a re-entrant feed and poisons a parser whose callback escapes (`runtime.sls:998-1059`); chez-libuv refuses `uv-run` from a callback. So every wait is an event that arrives later, and nothing that can raise may run inside a parser callback. The sans-I/O proposal built and measured exactly this shape: 13/13 connection-semantics checks with no sockets, the same core under a real loop over loopback.

## Decision

1. `conn-step : ConnState × Event → (values ConnState (Listof Action))` is pure: it allocates only Scheme data, calls no chez-libuv or byte-machine procedure, and reads no clock (`tick` carries `now`).
2. Events: `bytes-arrived`, `eof`, `read-error`, `write-completed`, `shutdown-completed`, `closed`, `tick`, `parser-event`, `parser-result`, `handler-responded`, `handler-body-chunk`, `handler-body-end`, `handler-failed`, `body-credit`, `shutdown-requested`. Actions: `reply-parser`, `feed-parser`, `resume-parser`, `write`, `read-stop`, `read-start`, `call-handler`, `deliver-body`, `deliver-body-end`, `notify-producer`, `arm-deadline`, `disarm-deadline`, `shutdown`, `close`, `log`. An unknown event is an assertion violation (a test-caught bug, never a runtime path).
3. `reply-parser` is the one action consumed synchronously, inside the parser callback that produced it. Every other action is queued while a feed is running and executed after the outermost `dispatch!` returns (run-to-completion, depth-counted around `drain!` as well as `parser-feed!`).
4. Parser flags, method, version and content-length are read inside `on-headers-complete` and carried in the event, because the inter-message reset zeroes them. (2026-09-25) So is `upgrade`, the parser's own answer to whether the message upgrades, since chez-httparse v0.4.1 documents it (#47). The reset does not zero it, but before `on-headers-complete` it still holds the previous message's answer.
5. A server-level `server-step` of the same shape owns accept, drain and shutdown.

## Consequences

- The llhttp request fixtures replay through the core at every chunk size with a recording adapter; the ratchet lists every fixture. Connection-semantics tests are `(state, event) → (state', actions)` tables.
- The allocation gate for the core is ≤ 3 KiB per request on the CPS spike's workload (naive prototype: 6,832 B; CPS: 2,672 B), met by a linear mutable accumulator and retained spans.
- One contract test gates every shell: identical wire bytes and action traces for the same scripted events.

## Amendment (2026-09-23) — the sixteenth action

Decision 2's action list above names fifteen actions and misses one:
[0006](0006-http10-is-supported-h2c-answers-505-one-upgrade-hand-off-hook.md) item 3
has the core emit `(hand-off request unconsumed-bytes)` when the parser pauses for an
upgrade. The closed action set is therefore sixteen: the fifteen above plus `hand-off`.
M2.1 ships it that way as `conn-actions` in `src/http-server/connection.sls` (PR #7,
85e7d81), and `tests/test-connection-table.sps` fails if `hand-off` is dropped
(mutation M2.1-F, `.superpowers/sdd/m2-mutations.md`). M2.1 emits `(hand-off request)`;
the unconsumed bytes join it once the pause loop retains them (M2.4), and 0006 puts
the contract test in M8. The fifteen events and the rest of this decision are
unchanged. Design §4.1 and the milestone plan's M2.1 entry repeat decision 2's
fifteen; this amendment is where the sixteenth is recorded.

## Amendment (2026-09-23) — what the allocation gate measures

The consequence above sets the gate at "≤ 3 KiB per request on the CPS spike's
workload" and cites two priors that measured different things. This note pins down
what it means.

1. **Where the number comes from.** It was set in the research phase's performance
   review (`research/judge-performance-operability.md` §5) as the CPS prototype's
   measured 2,672 B rounded up to the next KiB, with the naive prototype's 6,832 B as
   the design to avoid. No throughput or latency target lies behind it, and the brief
   sets none. It is a regression ratchet ("no worse than the known-good design"), not
   a derived requirement.
2. **It is a total.** The 2,672 B it was set from was measured over the whole feed
   (`research/spike/cps-core.sps` §4), parser included. On the same workload the parser
   alone costs 1,600 B of it (re-measured at the v0.4.0 pin on 2026-09-23 by
   `research/spike/m2-event-alloc.sps`). So the gate counts every byte allocated per
   request (parser, adapter and core), read as a difference of the cumulative
   `sstats-bytes` counter and never of the live heap. The naive prior measured the pure
   core alone, so it is not comparable; it stays only as the counterexample.
   cps-core's handler writes no response, so the response path is outside the
   anchor: M3 re-measures with it in the loop (milestone plan §7) and records here
   whether it fits.
3. **Shape is the real guard.** A total catches a regression only once the sum
   crosses the line. M2.1's per-callback event lists cost 1,248 B per request and put
   its cycle at 3,280 B before any request bytes were copied. So, following
   chez-httparse's allocation lane ("the claim is a shape, not a number"), M2.2 and
   M2.3 add shape checks beside the total:
   - no allocation per parser callback unless the core keeps that callback's data;
   - no allocation that grows with header or target length (retained spans, not
     copies);
   - a cost per request that stays constant, rather than growing per callback or per
     byte.
4. **A byte target waits for a throughput goal.** None exists yet, and M8's load
   smoke is the first place one can come from. Until then 3 KiB stands as the
   ratchet, and a measured reason to move it gets a dated note here, as the milestone
   plan's §10 expects of every ceiling.

## Amendment (2026-09-23) — parser callbacks enter directly

Item 1's `conn-step` stays the one interface for every event, and it is still what the
table tests and the fake shell drive. Parser callbacks also get a second way into the
same transitions, one that allocates nothing. The reason is that the tagged list built
per callback is the largest cost the core adds. In `research/spike/m2-event-alloc.sps`
(2026-09-23), M2.1's lists cost 1,248 B of its 3,280 B per-request cycle, and the same
cycle with no event per callback measured 2,032 B. The rules:

1. **The adapter passes the callback's own arguments**, so nothing is allocated to
   carry them. There are two shapes:
   - one for the 24 callbacks that carry a span or nothing: the callback name, plus
     `bv from to` when there is a span;
   - one for `on-headers-complete`. Its method, version, flags and content-length are
     read by the adapter inside the callback (item 4) and passed as arguments, since
     the core calls no byte-machine procedure. On this path, item 4's "carried in the
     event" means carried in those arguments. (2026-09-25: `upgrade` is a sixth, since
     chez-httparse v0.4.1; see item 4.)
2. **It returns what `conn-step` returns**: the state and the action list, with
   `reply-parser` first, as item 3 requires.
3. **One implementation.** `conn-step`'s `parser-event` arm only unpacks the tagged
   list and calls the entry point, so the transitions live in one place. A test drives
   the same callbacks both ways and requires the same states and actions.
4. **The core builds whatever it keeps from a span**, since there is no event tail left
   to share. It allocates only for data it retains, which is the first shape check in
   the previous amendment.
5. **The callback names are a closed set**, like the events: an unknown name is an
   assertion violation.

A consequence: the real shell's parser events are no longer data, so tracing them
needs an explicit hook in the adapter (M4). The work is M2.2's first step, before the
request accumulator.

## Amendment (2026-09-24) — two rare target forms run uriparse's scanner

Item 1 says `conn-step` calls no byte-machine procedure. M2.3 judges the
request-target at `on-headers-complete` (milestone plan §6), and two of RFC 9112
§3.2's four forms can only be judged by a parse. The rules:

1. **What changes.** For an absolute-form target, and for CONNECT's
   authority-form target, the core runs uriparse's own scanner through
   `(http-server target)`. Absolute-form uses one collector per connection,
   made on the connection's first absolute-form target and reset before each
   one, and judged with `uri-parse-result-validate`. CONNECT uses the strict
   `uri-parse-authority-form-validate`, which parses fresh. Both are byte-machine
   parsers, and they run inside the chez-httparse callback that entered the core.
2. **What does not change.** The core never feeds, resumes, resets or reads the
   chez-httparse parser that calls it, and the adapter still reads that parser's
   fields (the third amendment). Origin-form, the form nearly every request
   carries, runs no parser at all. Its path and query go to `(uri charset)`'s
   `validate-component`, which is pure.
3. **Why item 1's reason still holds.** The rule exists because nothing that
   can raise may run inside a parser callback (the context above). byte-machine's
   reentrancy guard is per parser (`runtime.sls:985-1059`), so running a second
   parser inside the first one's callback is not re-entry. The judge owns its
   collector, resets it before every target, and feeds it one whole target in one
   call. uriparse returns every verdict as data (design §6.2). A contract
   violation from the scanner would be a bug in the judge, just as an unknown
   event is a bug in the core.
4. **What it costs.** Measured 2026-09-24 on Darwin arm64, Chez 10.4.1
   `tarm64osx`, by `research/spike/m2.3-target-alloc.sps` and
   `tests/test-connection-allocation.sps`:
   - an absolute-form request costs 4,336 B against origin-form's 2,640 B. That
     is one reused collector's parse in place of the path's copy, and the
     allocation suite holds it to exactly that, so a collector made per request
     turns it red;
   - a CONNECT target's fresh parse costs 3,696 B.

   Neither form is on the workload the ratchet measures, and design §7.5 already
   accepted CONNECT's fresh parse.

   Since 2026-09-24, evening, origin-form copies nothing (the next amendment's
   closing note). Absolute-form still costs 4,336 B, now one reused collector's
   parse more than origin-form's 2,624 B, and the allocation suite holds it to
   exactly that.

Decided on the owner's word on 2026-09-24, together with the origin-form route and
the three form rules recorded in the ledger's M2.3 entry.

## Amendment (2026-09-24) — the target-length shape is carried until uriparse #21

The second amendment's second shape says no allocation grows with the target's
length. M2.3 carries one exception, decided on the owner's word on 2026-09-24:

- **The exception.** To judge an origin-form target, its path and query are
  copied before `(uri charset)`'s `validate-component` sees them. That validator
  takes a whole bytevector and has no range.
- **What it costs.** A request grows by about one byte per target byte. On the
  CPS workload it costs 2,640 B, against 2,624 B with no validation, and the same
  request with a 500-byte target costs 3,136 B (measured 2026-09-24, Darwin arm64,
  Chez 10.4.1 `tarm64osx`).
- **The request.** uriparse #21 (filed 2026-09-24) asks for a validator that
  takes a range. Until it lands, `tests/test-connection-allocation.sps` holds the
  growth to exactly the copy. Header length still costs nothing. Once #21 lands,
  the check falls back to "a 500-byte target costs what a short one does".
- **Closed (2026-09-24, evening).** uriparse v0.5.0 (4d95118) released #21, and
  the judge now reads an origin-form target's path and query in place: it copies
  nothing. The CPS workload costs 2,624 B, the figure with no validation, and a
  500-byte path or a 500-byte query costs the same (measured the same day, on the
  same platform). The check has fallen back as planned, and this exception is
  closed. The second shape holds on the workload the gate measures: origin-form
  requests that arrive in one delivery. Three costs still grow with a target's
  length, and none of them was this exception:
  - a target split across deliveries is joined into one bytevector by the core,
    once, as a header is (`connection.sls`, `take-piece!`);
  - absolute-form's reused collector assembles the target's components as it
    parses;
  - CONNECT's target is copied and parsed fresh (design §7.5).

## Amendment (2026-09-25) — the shell owns item 3's queue

Item 3's queue belongs to the shell (M2.4). The adapter hands each parser callback's
actions after its reply to a procedure the shell gave the connection's context, and
the shell runs them from its one queue once the feed has returned. Before, the adapter
kept a list of its own and copied it out after each feed, the 112 B per request that
M2.2's fourth step measured. With that copy gone the CPS workload costs 2,512 B per
request, and an absolute-form request 4,224 B, still one reused collector's parse more
(measured 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`). The shapes hold: a
500-byte header value, target, query or Host costs what a short one does.

M2.4's fake shell checks item 3 itself, with one depth counter around `drain!` and
`parser-feed!`: every action must run from the outermost drain, at depth 1. An action
run inside a feed or in a nested drain is a violation the shell records, and the
message-loop suite and the outcome lane fail on it.

## Note (2026-09-26) — the M3 exit: the response path is in the loop, and requests a server meets join the gate

The second amendment's item 2 left this to M3: the gate's anchor wrote no response, so
M3 re-measures with the response path in the loop and records here whether it fits. It
fits. The workload is unchanged, answered as a shell will answer it: `handler-responded`,
the framing decision, the serializer's segments, and `write-completed`. Measured on M3's
merged tree (main at 160d638; Darwin arm64, Chez 10.4.1 `tarm64osx`):
- **The gate:** 2,736 B per request, against the 3,072 B ratchet, answering an empty
  200. It was 2,512 B at the M2 exit, before the core wrote through the serializer, so
  the response path costs 224 B. A 200 with `Content-Type` and a 13-byte body costs
  2,784 B.
- **Two shapes on the response side**, each a check now:
  - a response's body is a segment of the write, never copied: a 999-byte body costs
    what a 100-byte one does;
  - a registered status's line is made once and shared, so a response allocates
    nothing for it. Only a comment had said so.
- **What a handler's fields cost.** They are copied once, into the header block, which
  is one segment by design (M3.1-D). A 500-byte field value costs 3,248 B in all.

**Requests a server meets.** The same measurement over requests a server meets found
the parser's largest cost, one the gate's workload hid. byte-machine's keyword matcher
copied the prefix it had matched on every byte, so a field the parser reads by name
cost 1 to 4.4 KB more, growing with the square of the match. That put:
- a JSON POST with `Content-Type` and `Content-Length` at 6,800 B;
- `ab -k`'s HTTP/1.0 keep-alive GET at 5,824 B;
- a browser's GET, with `Connection: keep-alive`, at 8,144 B.

It was filed as byte-machine #139 on the owner's word, and the owner held M3's close for
the fix. byte-machine v0.6.1 reads the prefix in place, and the pin moved to it through
chez-httparse v0.4.3 and uriparse v0.6.1 (decision 0008). At the new pin:

| request | before | after |
|---|---|---|
| the gate's GET | 2,736 B | 1,840 B |
| curl's GET | 2,736 B | 1,840 B |
| a JSON POST | 6,800 B | 2,384 B |
| ab -k's GET | 5,824 B | 2,112 B |
| a browser's GET, eleven fields | 8,144 B | 3,312 B |

On the owner's word (2026-09-26), two requests a server meets join the gate beside the
CPS workload, each held to the 3,072 B ratchet: the JSON POST, and ab -k's. The owner
chose three. Review found that curl's GET has the CPS workload's shape, the same three
fields, so every mutant moved the two checks together. It is printed rather than gated
twice. The browser's GET is printed too, since its cost counts its fields: eight more than
the CPS workload's three, at 176 B each (the parser's 64 B and the core's 112 B), and 64 B
for the keyword table its `Connection` value is read through. A third shape joins the other two: a field name costs the same
however much of a parser keyword it matches. The research spike
`research/spike/m3-exit-keyword-alloc.sps` records every number here, at both pins.

## Amendment (2026-09-30) — every event callback carries the parser's position

The third amendment's first shape changes for the fifteen event callbacks: the adapter
passes the parser's position with each, the bytes of the connection it has read, which
byte-machine's runtime commits before calling any callback (`parser-stream-offset`; the
generated lane commits it at callback entry, and byte-machine's differential lane checks
it against the interpreted one). `on-headers-complete`'s arguments gain it too, after
`upgrade`. The tagged list follows: `(parser-event name at)`, and on-headers-complete's
payload's seventh field. A callback given its old shape is an assertion violation, as any
wrong shape is.

The reason is the padding PR's (decision 0005's amendment of this day): the parser reads
four runs of bytes it hands on in no span, and only positions can measure them. At every
delivery size an event sees the same position (45 of 45 sizes for a padded head, 95 of 95
for padded chunks, a scratch probe). A span needs none: its position is its delivery's
base plus its bound, and the core knows each base, the bytes each read's result took, and
where each delivery it feeds begins. Nothing is allocated for it: the position is a
fixnum argument, and curl's GET costs 1,840 B a request, as before.

## Amendment (2026-09-30, later) — a parser-result carries the parser's own count

A `parser-result`'s second field was the bytes one feed consumed, and the padding PR
summed them into the core's count of the parser's bytes. The field is now the parser's
own count, `parser-result-stream-offset` (chez-httparse `docs/api.org`): the bytes taken
since the parser was made. The event reads `(parser-result status offset next error
pause)`. Both shells pass it, and the core keeps it instead of adding.

Decided on the owner's word, by form, at the padding PR's review. A lane that passes on
only some of the parser's results, as the trace lane does by design, left the summed
count behind on 80 of its 141 reads. That was harmless only because no run is judged
while a handler is asked. A delivery's base is still that count less where the feed
starts.

Weighed:
- spans carrying the parser's position too: 17 code lines for 20, and 73 hand-built
  events, with a shell that passed a wrong count caught by no check without one more;
- keeping the sum.

A result is read whole before it is answered, so one short of its fields is an assertion
violation, as any wrong shape is. The parser's offset inside a callback was asked of
chez-httparse's docs as its #55, and is documented there since v0.4.4 (2026-10-01), held
over its corpus by `unit.stream-offset`.

## Amendment (2026-10-01) — a parser-result carries one code and the open span

The event reads `(parser-result status offset next code span)`. A result has an error or
a pause, never both, so their codes share one field, `code`, which the status reads. `span`
is the span the parser has open, `parser-active-span`; after an error it is the one the
error cut off and never handed on. At an error of the parser's own, `offset` is the
refused byte's position: the parser's count, less one where it took the byte before
refusing it, an error whose position kind is `boundary` (byte-machine's
`.reference/transition-and-cursor-semantics.md` §4). Over 11,273 errors, every byte of
seven requests replaced and preceded by 22 values, that was the byte whose one-byte feed
fails, at every one. A callback's failure, the core's own refusal, refuses no byte and keeps
the count. The adapter builds the event, `parser-result-event`, and both shells hand it on,
so its shape is made in one place.

With them the core judges what the parser's error cut off (decision 0005's amendment of
this day). Nothing is allocated for it: still five fields, and curl's GET costs 1,840 B a
request.

Decided on the owner's word, by form, for the cut-off-span PR. Weighed: a sixth field, the
two codes kept apart, 16 B more a read (curl's GET 1,856 B).

## Amendment (2026-10-01, the pin PR) — the result's span is the one its error abandoned

byte-machine v0.7.0 records on a parse error the span it abandoned and where that span's
withheld bytes begin (`parser-error-span`, `parser-error-span-offset`; its #145, decision
0008). So the event's `span` is now the error's: `(name . offset)` at an error with a span
open, the bytes from `offset` to the refused byte being the ones the parser took for it and
never handed on, and #f on every other result, where the core never read it. The adapter
builds the event from the result alone, and both shells call `(parser-result-event r)`.

Still five fields, and a read allocates nothing more: curl's GET costs 1,840 B a request,
and an error with a span open allocates one pair. Decided on the owner's word, by form, for
the pin PR. Weighed: a sixth field beside the open span, 16 B more a read (curl's GET
1,856 B), each result the tests build by hand gaining one.

## Amendment (2026-10-04, M8.4) — v0.1.0 sets no throughput goal

Item 4 waited for M8's load smoke, the first place a throughput goal could come from. M8.4
measured it with `research/spike/m8-load.sh`. oha sent 50,000 GETs over kept-alive
connections, with Node's `http` module beside the server on the same Apple M1. Two runs of
three rounds, in thousands of requests a second:

| connections | 1 | 10 | 50 | 100 | 500 |
|---|---|---|---|---|---|
| Darwin arm64, this server | 9.9–10.5 | 31.3–32.8 | 32.8–34.0 | 32.6–34.0 | 23.7–31.5 |
| Darwin arm64, Node 20.10 | 10.3–10.7 | 34.0–35.5 | 35.4–36.1 | 34.4–36.1 | 31.1–32.0 |
| Linux aarch64, this server | 14.0–14.4 | 61.5–64.4 | 82.8–86.8 | 78.3–88.0 | 62.4–72.8 |
| Linux aarch64, Node 18.20 | 14.1–14.4 | 53.6–55.6 | 50.9–60.4 | 50.6–55.9 | 43.8–46.8 |

The server runs on one core. At 10 connections or more it spent 28.4 to 31.6 µs of CPU a
request on Darwin and 11.4 to 16.2 µs on Linux. Linux ran in Docker on the same machine.
Through the whole server, a GET kept alive allocated about 10.4 KB at one connection and
8.9 KB at 50, on both (`research/spike/m8-request-alloc.sps`). The gate's 1,840 B is the
parser's, adapter's and core's part of it; the rest is the shell's and chez-libuv's.

Decided on the owner's word, by form ("No goal; record a baseline"): v0.1.0 sets no
throughput goal. CHANGELOG.md records these numbers, with their platforms, as its baseline.
The 3 KiB gate stays a regression ratchet (item 1), with its shape checks. A goal waits for
a need, such as a deployment that outgrows one core. What was weighed:
- holding within 15% of Node's http, checked by hand before each release. Round by round,
  Darwin is 2% to 10% under Node 20.10 at 10 connections or more, but for one round at 500
  that was 25% under, and Linux is 12% to 66% over Node 18.20;
- a floor on the smoke's rate in CI. Shared runners vary from run to run, so it would flake
  or be set too low to catch much.

The runs are `out/m8-load.{darwin,linux}.run{1,2}.txt` and
`out/m8-request-alloc.{darwin,linux}.txt`.
