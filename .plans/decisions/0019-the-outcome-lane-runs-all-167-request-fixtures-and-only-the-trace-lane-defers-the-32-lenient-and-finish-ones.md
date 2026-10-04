# 0019: the outcome lane runs all 167 request fixtures, and only the trace lane defers the 32 lenient and finish ones

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, in discussion: "A")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §2.1, §11, §14's open list

## Context

The llhttp corpus holds 167 request fixtures. 135 are `type=request`. The other 32 are
29 that llhttp recorded under a lenient flag (ten `request-lenient-*` types) and 3
`request-finish` ones, whose logs end with what `llhttp_finish()` returns, a call the
server never makes. Plan §2.1 had the ratchet defer the 32 in both corpus lanes, by
their type, and §11 made promoting any of them a decision record. Plan §14's open list
carried them.

The two lanes compare different things. The trace lane compares each fixture's
recorded log with the trace our path renders, under the fixture's own init (design
§8.1, property 1). The outcome lane feeds the bytes to one fake connection, which
parses with the server's own parser, and checks that what the connection did is the
same at every chunk size (property 2). It reads no log.

Measured 2026-10-04 on Darwin arm64, Chez 10.4.1, at a4c5191 (chez-httparse v0.4.5):
- **chez-httparse gates them already.** Its own ratchet has 274 entries passing, all
  167 request fixtures among them, none deferred.
- **Their logs, through our path.** Under their own flags, the 29 lenient traces equal
  their logs at size 1 and whole. The 3 finish traces stop one line short, at the
  `finish=` line.
- **Their logs, under the server's parser** (strict but for llhttp's version leniency,
  decision 0006's amendment of 2026-10-04), read whole. 4 equal their logs:
  `lenient-version.md#1`, whose one flag is the server's, and
  `lenient-header-value-relaxed.md#3` to `#5`, which llhttp refuses even relaxed. The
  other 25 differ, and every one stops in a parser error.
- **Their outcomes.** All 32 give the same outcome at every chunk size, at size 1 and
  whole and at every size, with a handler that reads every body and with one that
  reads none. With the first, the server answers 22 with a 400 before any handler,
  `HTTP/5.6` with a 505, and 4 with a 400 after a handler: three chunked bodies
  framed badly, and a second request with a form feed in a header value after the
  first got its 200. It serves 2 and closes before the bytes their leniency was for
  (HTTP/1.0, `Connection: close`), serves a complete GET, and closes 2 cut off in their
  heads, with no answer.
- **What they add to the outcome lane.** 15 of the 32 inputs are byte for byte a strict
  fixture's. Under the server's parser the 32 reach 15 distinct parser errors, every
  one of which the 135 reach too. One outcome is new: a request answered, then the next
  refused on the same connection (`lenient-headers.md#2`).
- **The cost.** The lane goes from 253 runs to 317 at size 1 and whole, and from 9,394
  to 14,070 at every size, which ran in 0.97 s. The outcome suite and the ratchet took
  0.60 to 1.01 s each, two runs each, against 0.63 to 0.86 s on a4c5191.

## Decision

1. **The outcome lane runs all 167 request fixtures.** The 32 enter the ratchet as
   `passing` there: 167 passing, none deferred. The outcome suite counts and compares
   one list, every request fixture.
2. **The trace lane keeps the 32 deferred**, derived from each fixture's `type` as
   before. Their logs are llhttp's under a lenient flag or with the finish call.
   `lenient-version.md#1` stays deferred too, though the server's parser sets its flag.
3. **The ratchet derives its split per lane**: the trace lane's from each fixture's
   meta, so a corpus refresh still cannot slip a lenient fixture in; every request
   fixture is in the outcome lane's scope.

## Consequences

- The ratchet counts move: outcome 167 passing and 0 deferred, against 135 and 32.
  Trace stays at 135 passing and 32 deferred.
- The trace lane checks the corpus's parse, under each fixture's own init. For a strict
  fixture that init is the server's but for the version leniency. One strict fixture
  reads differently under the server's parser: `invalid.md#19`, `GET / HTTP/5.6`,
  which a strict parser refuses at the version and the server's reads on, as
  `lenient-version.md#1` records. Its input has no line end, so the server waits for
  one and closes at the client's eof. `(trace-lane)` and plan §2.1 say so.
- The 32 are compared, not only counted. Two mutants of the core that make outcomes
  depend on the chunk size name four of them, each among strict fixtures. No mutant
  was found that fails a check through the 32 alone, as the measured overlap
  predicted. The mutants are in `.superpowers/sdd/m8-mutations.md`.
- Weighed and not taken: the trace lane taking `lenient-version.md#1` too (136
  fixtures, its scope "the fixture's init is the server's parser's"); keeping all 32
  deferred; and the trace lane running the 29 under their own flags, which only
  repeats chez-httparse's gate for parsers the server never makes.
- `tests/ratchet.txt` had cited "0009" for the deferral. It was written on 2026-09-20
  and meant chez-httparse's decision 0009; this repository's 0009, on redirects, came
  on 2026-09-24. The manifest now cites plan §2.1 and this record.
