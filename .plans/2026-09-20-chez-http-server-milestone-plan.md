# chez-http-server milestone plan: slices, exits and mutation obligations

Date: 2026-09-20
Status: accepted — schedules [the project brief](2026-09-19-chez-http-server-project-brief.md)'s M0–M8 against [the design document](2026-09-20-chez-http-server-design.md)
Decisions: [0001–0008](decisions/) settle the questions this plan sequences; it cites them and re-argues none
Ledger: [`.superpowers/sdd/progress.md`](../.superpowers/sdd/progress.md); house rules in [`global-constraints.md`](../.superpowers/sdd/global-constraints.md)
Tree at the time of writing: `main` at `11de638` — M0 merged as `d0c522b`, the design document as `1d59d50`, decisions 0004/0005 amended for M0's limits naming as `9e010ca`. `make test` green: five suites, 55 expected passes, exit 0
Depth: **M1–M4 are sliced. M5–M8 carry entry conditions and hazards only** and are sliced in a dated amendment when M4 lands (§10 says why)

The brief says what is built and what each milestone must prove. The design document
says how the parts compose and where the mechanism lives. Neither says what order the
work inside a milestone goes in, which slice is allowed to be red, or which named
mutation finishes which test. That is this document.

It adds exactly three things: **slices** with entry and exit conditions, a **named
mutation per slice** so no test is finished by inspection, and the **measured lane
sizes** M1 and M2 are gated on. Everything else it cites.

---

## 1. The rules every slice obeys

These are [`global-constraints.md`](../.superpowers/sdd/global-constraints.md) restated
as the shape of a slice, so a slice can be judged without re-reading it.

1. **A milestone is a branch and a pull request; a slice is a commit inside it.** A
   slice whose diff passes roughly 400 lines gets its own PR instead, so review stays
   possible. M0 landed as a single PR of 845 insertions across 22 files (`d0c522b`),
   which is over that threshold — this rule is a change from M0's practice, not a
   description of it, and M2 and M4 are marked below as likely two PRs because of it.
2. **Red before green.** The test that names the property is written and *watched to
   fail* before the code that satisfies it exists. A slice that opens green has not
   been tested; it has been observed.
3. **Every test is finished by a named mutation.** The mutation breaks the asserted
   property and nothing else, is recorded in `.superpowers/sdd/m<N>-mutations.md` with
   the suite, the exact edit, the observed exit status and the failure count, and is
   reverted. [`m0-mutations.md`](../.superpowers/sdd/m0-mutations.md) is the template.
   A survivor is a missing test, a scope statement, or the finding itself, and which
   one it is gets measured rather than guessed.
4. **The mutation goes in the thing under test, not in the test's oracle.** M0's pin
   test is the pattern: it mutated the *vendored constant* `F-CONNECTION-CLOSE`, not
   the test's assertion, so the failure was exactly the upstream drift the pin guards
   against. Mutating an expected number proves only that `=` works.
5. **Numbers come from an oracle** — a fixture, a measured libuv fact, an RFC vector —
   never from running the code under test, and never carried forward by arithmetic.
   Every count that enters a record is re-measured on the tree at the time of writing,
   dated and platform-stamped.
6. **`make test` is green before every commit**, and `make test` already implies
   `check-pins` and `check-imports` (`Makefile:109`).
7. **Prefer a check to a comment.** A load-bearing invariant becomes a make target, a
   test or an assertion. Each slice below names the check it adds, not the paragraph it
   would have written.
8. **A pin moves alone, on its own commit,** with a fingerprint or byte-identity check.
9. **No new dependency without a decision record**, and no scope growth without
   re-planning in the ledger first (brief risk 6).

---

## 2. The lane sizes, measured

Everything M1 and M2 are gated on is a count, and every count below was measured on
this tree rather than assumed. Re-measure before quoting any of them in a record.

**Measured 2026-09-20, Darwin arm64, Chez Scheme 10.4.1 `tarm64osx`**, over the llhttp
corpus vendored inside chez-httparse at its pinned v0.4.0 (`1cddba8`), read through
chez-httparse's own `(httparse test corpus-load)`, `(httparse test corpus-decode)` and
`(httparse test conformance)` with the harness directory added to the library path:

```
CHEZSCHEMELIBDIRS="src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src\
:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs\
:vendor/chez-httparse/test/support/harness" chez --program <measure>.sps
```

### 2.1 The request lane is 135 fixtures, not 167

`vendor/chez-httparse/test/vendor/llhttp/request/` holds **167** fixtures in 13 files,
every one `passing` in chez-httparse's own ratchet
(`vendor/chez-httparse/test/conformance/ratchet.txt`, 274 entries: 167 request, 86
response, 21 url; 274 passing, 0 not-yet, 0 deferred).

The brief's phrase is "every `type=request` fixture", and that is **135**, not 167. The
other 32 carry a `request-lenient-*` or `request-finish` type, which names the init hook
upstream compiles in and therefore the lenient flags the parser is built with:

| `type` meta | count |
|---|---|
| `request` | **135** |
| `request-lenient-headers` | 11 |
| `request-lenient-optional-lf-after-cr` | 4 |
| `request-lenient-header-value-relaxed` | 4 |
| `request-finish` | 3 |
| `request-lenient-keep-alive` | 2 |
| `request-lenient-chunked-length` | 2 |
| `request-lenient-transfer-encoding` | 2 |
| `request-lenient-all` | 1 |
| `request-lenient-version` | 1 |
| `request-lenient-optional-crlf-after-chunk` | 1 |
| `request-lenient-spaces-after-chunk-size` | 1 |
| | **167** |

**The file a fixture lives in does not decide its type**, and it is wrong in both
directions. The 11 `request-lenient-headers` fixtures are spread over six files —
`connection.md` 3, `lenient-headers.md` 3, `sample.md` 2, and one each in
`content-length.md`, `invalid.md` and `transfer-encoding.md`. And `lenient-headers.md`
itself holds 4 fixtures, of which only 3 are lenient: its third
(`lenient-headers.md#3`, line 84) is a plain `type=request` and belongs in the strict
lane. A lane built by globbing filenames would both miss lenient fixtures and swallow a
strict one, which is why M1.1 reads `fixture-meta-ref` and asserts the split.

**The server runs strict.** The 32 lenient fixtures enter the ratchet as `deferred`
with their type as the class word, exactly as chez-httparse's own manifest defers by
class. Promoting any of them is a decision record, not a milestone.

### 2.2 What the strict lane costs to run

Of the 135: **17** are `noScan` (whole-buffer only), **13** carry a `pause` naming the
callback to pause in, **1** carries `skipBody`. Decoded input is **10,364 bytes**;
across all 167 it is 15,040, median fixture 66 bytes, longest 2,044.

| selection | chunk-size runs | parser feeds |
|---|---|---|
| `'extremes` (size 1 and whole buffer) | **253** | **9,512** |
| `'full` (every size 1..n) | **9,394** | **53,172** |

That gap is the whole justification for the `pr` / `release` split the brief asks for,
and the split is not something we build: it **is** `corpus-scan-sizes`'s `selection`
argument (design §8.1). `'extremes` runs in `make test`; `'full` runs behind an explicit
variable and in the release lane.

### 2.3 What is not measured here

**libhtp's 102 `.t` files is a survey figure**, dated 2026-09-19 in
[the corpus survey](2026-09-19-test-corpus-survey.md) line 15, not a measurement on
this tree — nothing libhtp is vendored yet. The repository was archived in July 2026 so
the count should be stable, but M1.3 re-measures it at the retrieval commit and the
ledger records what it finds, not what the survey said.

---

## 3. The nine limits that are not fields yet, assigned

Decision [0005](decisions/0005-bounded-nginx-style-defaults-one-tick-timer-and-a-timing-wheel.md)'s
table names eighteen limits in fifteen rows; `(http-server limits)` ships nine fields.
Its 2026-09-20 amendment says the rest "arrive with later milestones under the same
`CHEZ_HTTP_` prefix" and leaves which milestone open. **This is where that is settled.**
Defaults and on-breach behaviour are 0005's, unchanged.

| Limit | Default (0005) | On breach | Arrives | Because |
|---|---|---|---|---|
| `max-header-field-bytes` | 8 192 | 431, close | **M2** | enforced in `on-header-field-complete` |
| `max-header-value-bytes` | 8 192 | 431, close | **M2** | enforced in `on-header-value-complete` |
| `write-high-water` | 262 144 outstanding | read-stop | **M3** | brief M3's write accounting |
| `write-low-water` | 65 536 outstanding | read-start | **M3** | same |
| `max-connections` | 10 000 | refuse | **M4** | `server-step`'s `refuse` action (design §4.6) |
| `backlog` | 511 | — | **M4** | the `uv-listen!` argument |
| `write-timeout-ms` | 60 000 per completion | close | **M5** | only enforceable once the wheel exists |
| `tick-ms` | 250 | — | **M5** | the wheel's bucket width |
| `drain-timeout-ms` | 10 000 after SIGTERM | force-close all | **M8** | the drain deadline |

Each one arrives with four things, not one: the field, a value test against 0005's
default, its name appended to `limits-environment-variables`, and the existing
"`default-limits` equals the empty environment" drift guard extended to cover it. That
guard is not theoretical — M0's mutation M2 showed it fires as the second failure
whenever a default moves.

*Amended 2026-09-25 (decision 0010 item 5, on the owner's word):* `write-high-water`
and `write-low-water` arrive in **M6**, not M3. In v1 a handler's response is written
with reading already stopped, and only one response is outstanding, so their read-stop
could never fire in M3. M6 streams response bodies, and settles what crossing them does.

*Amended 2026-09-26 (decision 0011, on the owner's word):* a limit 0005's table did not
have arrived in **M3.5**: `linger-timeout-ms`, 30 000, how long a connection that closes
after a response waits for its client to close. It came with the four things above, and
its variable, `CHEZ_HTTP_LINGER_TIMEOUT`, is in whole seconds like the other durations.
The core arms its kind, `linger`; M5's wheel turns the kind into an instant.

**`tick-ms` is the one duration that cannot take the seconds convention.** Every
timeout override in `(http-server limits)` is given in whole seconds and stored in
milliseconds (`env-seconds->ms`, `src/http-server/limits.sls:91-93`). A 250 ms tick has
no whole-second spelling, so its variable is `CHEZ_HTTP_TICK_MS` and it is read by
`env-integer` in its stored unit. **The prefix is not the exception — the unit is.**
`CHEZ_HTTP_` holds for all nine; `tick-ms` is simply the one whose override is given in
milliseconds. Naming it `CHEZ_HTTP_TICK` would be a trap: it would
read like the duration variables that *are* in seconds — the three M0 shipped,
`write-timeout` and `drain-timeout`, and since M3.5 `linger-timeout` (six, amended
2026-09-26) — and mean something else. M5 adds a note to
[`docs/configuration.org`](../docs/configuration.org) saying so beside the variable.

---

## 4. M0 — the skeleton and the pure records — **DONE**

Merged as `d0c522b` (2026-09-19). `Makefile` with the canonical targets plus
`check-pins`, `check-imports` and `check-help`; five pinned submodules; Linux CI;
`(http-server limits|headers|request|response)`; the `(testing)` bridge; the flag pin
test. `make test` green at 55 expected passes across five suites, five mutations
recorded in [`m0-mutations.md`](../.superpowers/sdd/m0-mutations.md).

Two things M0 left for M1, both found after it merged and neither a defect:

- the harness library path (design §3.2), which M1.1 opens with;
- **status 3 has never been exercised.** `(testing)` defines a provenance failure and
  no suite raises one, because M0 vendored no corpus. M1.3 is the first slice that can,
  and it must — an unexercised status is an untested branch of the harness itself.

---

## 5. M1 — the instrument, with no server

Implements design §8.1, §8.2, §8.4, §8.6 and discharges §3.2's obligation.
**Zero connection semantics**: nothing in M1 knows what a request means.

**Entry:** `main` at `11de638` or later, `make test` green.
**Branch:** `feat/m1-instrument`.
**Mutation log:** `.superpowers/sdd/m1-mutations.md`.

### M1.1 — the harness path, and the corpus counted

Add `vendor/chez-httparse/test/support/harness` to `LIBDIR_LIST` (`Makefile:34-39`).
It is a test-only path, so `make check-imports` must see nothing new under
`src/http-server/` — that is part of the exit, not an assumption.

Then `tests/test-corpus-inventory.sps`: load all 13 `request/*.md` files through
`corpus-parse-file`, decode through `corpus-decode-input`, and assert §2's split — 167
fixtures, 135 `type=request`, 17 `noScan`, 13 with a `pause` key, 1 `skipBody`, 10,364
decoded bytes in the strict lane. The oracle is the vendored corpus at the pin, so this
is a **drift guard on the pin**: move chez-httparse and it goes red, and the numbers in
§2 get re-measured instead of silently aging.

- **Check added:** the inventory suite itself, plus `check-imports` unchanged.
- **Mutation A:** drop the harness directory from `LIBDIR_LIST`. Expect a load failure
  naming `(httparse test corpus-load)` — m0-mutations M5's shape, which proved the same
  way that the fourth library path was load-bearing.
- **Mutation B:** remove one `"pause"` key from a fixture's meta in
  `vendor/chez-httparse/test/vendor/llhttp/request/pausing.md`. Expect exactly one
  failure, the pause count at 12. This witnesses that the inventory reads meta rather
  than counting files or filenames — the §2.1 trap. Revert; vendored bytes are never
  edited outside a witnessed, reverted mutation.

### M1.2 — the trace lane: our path, their comparator

Drive each of the 135 strict fixtures through `make-parser` with
`trace-recorder-bindings`, render with `(httparse test trace-format)`, and
`trace-compare` against `fixture-expected` at the `'extremes` selection.

This proves nothing about our server and everything about our instrument: it re-derives
chez-httparse's own result through *our* library path, our Chez, our submodule pins. An
uncalibrated instrument cannot measure a parser, and this is the calibration.

The `pr` / `release` split lands here as `CORPUS=full`, justified by §2.2's table
rather than by preference.

- **Check added:** `make test` runs `'extremes`; the release lane runs `'full`.
- **Mutation:** perturb our rendering shim so one line drops its `off=` field. Expect
  `trace-compare` to report a mismatch with the differing index, expected and actual —
  not a bare `#f`. A comparator that answers `#f` has not been watched to work.

### M1.3 — libhtp's streams, and the first provenance failure

Vendor `test/vendor/libhtp/` with `LICENSE` (BSD-3-Clause), a `PROVENANCE` file (URL,
ref, commit, retrieval date, sha256 per file) and a `make corpus-refresh` target that
re-fetches and re-checksums (decision
[0007](decisions/0007-corpora-are-vendored-as-data-with-provenance-llhttp-through-chez-httparse.md)).
The loader splits on `>>>` / `<<<`, strips one trailing CR per chunk as libhtp's own
`test.c` does, and yields an ordered list of `(direction . bytes)`.

**No expectations in this slice.** The `<<<` chunks are a recorded origin's replies, not
an oracle; our expectations are ours and they are M2's. M1 proves only that the streams
load and that the bytes are the bytes we fetched.

- **Check added:** the checksum manifest, verified on every run; the loader **refuses** a
  malformed marker rather than guessing.
- **Mutation:** corrupt one sha256 in the manifest. Expect **exit 3** and a
  `PROVENANCE-ERROR` line — the first use of `provenance-failure` in this repository,
  which is why §4 flags status 3 as an untested branch of the harness.
- **Re-measure:** record the actual `.t` count at the retrieval commit in the ledger.
  The survey says 102 (§2.3); if it differs, the survey is what gets the dated note.

### M1.4 — the fake shell, and the ratchet opened

The fake shell delivers scripted events and records actions, with a **fake clock** —
`(tick now)` is driven directly and nothing sleeps (0005, consequences).

It has no core to drive yet: `conn-step` is M2. So M1's fake shell is exercised against
a **stub step procedure supplied by the test**, which is the honest scope — it proves
the shell records faithfully, queues in order, and takes its clock by injection, none of
which depends on connection semantics.

The ratchet manifest opens with a status per fixture **per lane**. Design §8.1 gates
two independent properties over the same fixtures, and §8.2 adds a third lane with
expectations of its own — so one status per fixture would have to average three answers
into one:

| lane | property | opens at |
|---|---|---|
| trace | the rendered parser trace equals the recorded log | 135 passing (M1.2) |
| outcome | the connection-level outcome is chunk-size invariant | 0 passing, 135 not-yet |
| libhtp | our per-file expectations hold | 0 passing, all not-yet |

plus the 32 lenient fixtures as `deferred`, class word from their `type`. The gate is
**two-way** from the first commit: a `not-yet` that starts passing fails the lane too,
because an unexplained improvement usually means the comparator stopped comparing.

- **Check added:** the ratchet, both directions; the deferred/in-scope split derived
  from each fixture's own meta and checked against the manifest, so a refresh cannot
  smuggle a lenient fixture in as `not-yet`.
- **Mutation:** flip one manifest entry from `not-yet` to `passing` without touching
  code. Expect red in the improvement direction.

### M1 exit

The brief's gate — every request fixture loads with checksums verified, the comparator
is mutation-witnessed, zero connection semantics — plus, measured on the tree:

- 135 strict fixtures render traces byte-identical to their recorded logs at
  `'extremes` (253 runs, 9,512 feeds); `CORPUS=full` green at 9,394 runs;
- the libhtp streams load with checksums verified, count recorded;
- the ratchet stands at trace 135 / outcome 0 / libhtp 0, 32 deferred;
- `make check-imports` reports no new import under `src/http-server/`;
- `m1-mutations.md` records the five mutations named above — M1.1's two, then one
  each for M1.2, M1.3 and M1.4 — each reverted, `make test` green after.

---

## 6. M2 — the pure connection core, request path

Implements design §4 in full, §6.2–6.3, §7.1 and §7.5's gate. This is the milestone the
design document was written for.

**Entry:** M1 merged; the fake shell and the ratchet exist.
**Branch:** `feat/m2-connection-core`. **Mutation log:** `m2-mutations.md`.
**Likely two PRs**: M2.1–M2.2, then M2.3–M2.5.

### M2.1 — the vocabulary and the table

The nine states, fifteen events and fifteen actions as closed sets;
`conn-step : ConnState × Event → (values ConnState (Listof Action))`; an unknown event
is an `assertion-violation` and never a runtime path (0002 item 2).

Design §4.4's transitions go in **as data**: 19 rows in two tables — 10 on the happy
path and 9 on termination and error. One row per decision, driven by synthetic events,
no parser in this slice.

- **Check added:** the table is the specification; the implementation is what has to
  agree with it. A row with no test fails the lane by being absent from the coverage
  count.
- **Mutation:** swap the target states of the two `responding` completion rows
  (`close-after? = #f` and `= #t`). Expect exactly the two rows red and nothing else —
  if more go red, the rows are not independent and the table is lying.

### M2.2 — the head, and the request accumulator

`on-message-begin` through `on-headers-complete`. Method, version, flags and
content-length are read **inside `on-headers-complete`** because the inter-message reset
zeroes them (0002 item 4); the event carries them forward and nothing downstream
re-reads the parser. The header list is built from retained spans of the delivered
bytevector, copying only what outlives the message (design §7.1).

`(http-server decisions)` arrives here with the error-to-status map and framing
precedence only — `should-keep-alive?` and `message-needs-eof?` stay imported from
`(httparse decisions)`, as M0 already does.

`max-header-bytes`, `max-header-count`, `max-header-field-bytes` and
`max-header-value-bytes` are answered with `(reply-parser (fail code))`; the status
comes from the policy the core already holds, not from the parser's callback-domain
error (design §6.3).

- **Check added:** the trace lane's property 1 still holds with *our* bindings
  installed — the connection layer must not perturb parsing — at `'extremes` for all 135.
- **Mutation:** read `flags` at `on-message-complete` instead of `on-headers-complete`.
  Expect every keep-alive decision to go wrong in the same direction, which is what
  makes this the mutation worth recording: it is silent in a single-request test and
  only the pipelining rows catch it.

### M2.3 — the request-target, through uriparse

One collector per connection, reset with `uri-collector-reset!`, validated with
`uri-parse-result-validate` (uriparse #18, v0.4.0). Origin-form and absolute-form take
that path; `CONNECT` takes `uri-parse-authority-form-validate` with a fresh parse, which
is accepted because CONNECT is rare and never on the keep-alive hot path; `*` is a
literal check. Over `max-target-bytes` is 414.

- **Check added:** an allocation assertion, not a comment. Design §7.5 records 1,584
  bytes and ~0.85 µs for a 46-byte origin-form target at the v0.4.0 pin; **M2.3
  re-measures on this tree and records its own number** — the design document's figure
  is the prior, not the oracle.
- **Mutation:** build a fresh collector per request instead of resetting one. Expect the
  allocation assertion red and the correctness tests green, which is exactly the point:
  a performance invariant that no test can distinguish from correct code is not an
  invariant.

### M2.4 — the message loop: pause, read-stop, pending input

Decision [0004](decisions/0004-pipelining-is-strictly-serial-with-read-stop-in-v1.md)
item 1's cycle, and the whole of serial pipelining. At `on-message-complete`:
`reply-parser pause`, `read-stop`, retain `pending-input` from **`parser-result-next`**,
`call-handler`. After the response: `resume-parser`, `feed-parser` pending, `read-start`.
After a close-marked message the core stops feeding, and the parser's
`closed-connection` error is ignored if it fires first (0004 item 4).

Run-to-completion is enforced here against the fake shell: a depth counter around the
feed and around the drain, and **no action but `reply-parser` executes at non-zero
depth**. Design §6.4 explains why that is a check and not a comment — byte-machine
poisons a parser whose callback escapes while chez-libuv swallows and re-raises later,
so getting this wrong is silent. M4 re-asserts it against the real shell.

- **Check added:** the depth assertion; outcome chunk-invariance over all 135.
- **Mutation A:** retain `parser-result-consumed` instead of `parser-result-next`.
  Expect the re-feed to replay the fragment already delivered to the pausing callback.
  The oracle is the measured boundary in `research/spike/pipeline-pause.sps`
  (2026-09-19, Darwin arm64, Chez 10.4.1 `tarm64osx`): consumed 51 at the first
  `on-message-complete`, then 47 at the second, stream offset 98.
- **Mutation B:** execute the action queue inside the callback instead of after the
  outermost dispatch. Expect the depth assertion red.

### M2.5 — the hand-off door, and the error rows

Both hand-off channels checked, because llhttp uses two: a CONNECT tunnel,
`Connection: upgrade` and a 101 arrive as `status = 'paused` with `parser-result-pause`
code `paused-upgrade`; the h2c preface arrives as `status = 'error` with
`parser-result-error` code `paused-h2-upgrade`. A plain pipelining pause is also
`'paused` and carries **no** pause reason, and that absence is how the core tells them
apart. `result-hands-off-stream?` is embedder code in chez-httparse's `docs/api.org`, so
it becomes a procedure in `(http-server decisions)` with the doc cited beside it.

Parser errors map through design §6.5; `invalid-transfer-encoding` splits by
`parser-error-node-name` (`e-request-invalid-te` → 501, every other node → 400), never
by reason string.

*Amended 2026-09-26, on the owner's word:* the split is gone. Every parser error is a
400, and the 501 is the core's own refusal of a coding before a final `chunked` (design
§6.3's amendment).

- **Check added:** the four hand-off rows verified at the pin by
  `research/spike/smoke-v040.sps` (ledger, 2026-09-19 night) become tests: CONNECT,
  Upgrade and h2c answer `#t`, the plain pipelining pause answers `#f`.
- **Mutation:** check only the `parser-result-pause` channel. Expect the h2c row red
  and the other three green — the single-channel bug this slice exists to prevent.

*Amended 2026-09-25 (decision 0006's amendment, on the owner's word):* the door. An
upgrade request is served and the connection closed after it, so the core's own flow
never reaches the pause channel's hand-off; the error channel's, the HTTP/2 preface, is
answered 505. The ledger's M2.5 entry has the measurements the owner chose from.

### M2 exit

The brief's gate, plus measured on the tree:

- ratchet outcome lane at 135 passing at `'extremes` **and** `'full`;
- outcome chunk-invariance: the `call-handler` sequence, the keep-alive decision and the
  close reason identical at size 1 and whole-buffer;
- libhtp's pipelining and multi-packet files pass with our expectations, promoted in the
  ratchet by name;
- **allocation ≤ 3 KiB per request** on the CPS spike's workload, re-measured here
  (brief risk 1; design §7.5 records 2,672 B for the CPS prototype and 6,832 B for the
  naive one as the priors);
- `m2-mutations.md` complete; `make check-imports` still clean.

*Settled 2026-09-25, on the owner's word:* the pipelining and multi-packet files are
the twelve whose client packets carry two or more requests, or a request split across
packets, as a strict parser counts them over all 102:
- pipelined: 07, 08, 10, 20, 39 and 61;
- a head across packets: 09 and 67;
- a body across packets: 04, 27, 35 and 66.

The lane runs like the llhttp lanes, with no Host required. `tests/test-libhtp-lane.sps`
holds the scope and the expectations.

---

## 7. M3 — the response path

Implements `(http-server serializer)` (design §3.1, introduced there and recorded in no
decision), §7.3 and §6.5.

**Entry:** M2 merged; the outcome lane green.
**Branch:** `feat/m3-response-path`. **Mutation log:** `m3-mutations.md`.

### M3.1 — the serializer as a total function

A `response` record plus the connection's framing decision to a list of wire segments:
status line, header block, first body chunk, **separate**, for one `uv-write*!` — one
request, one completion, no concatenation. It is a total function of its arguments, so
it is tabled independently of any connection state, which is the reason it is its own
library rather than part of `(http-server connection)`.

*Amended 2026-09-25 (decision 0010):* a fixed 37-byte Date slot follows the status line,
and the shell fills it. A handler's response the serializer cannot write safely is a
fault, answered 500.

- **Mutation:** concatenate the segments into one bytevector. The wire bytes are
  identical, so only the segment-count assertion goes red — which is the assertion
  earning its place.

### M3.2 — framing, and the suppression rules

`Content-Length` versus chunked versus close-delimited; HEAD, 1xx, 204 and 304 body
suppression; HTTP/1.0's rules; `Connection: close` on the last response.

- **Mutation** (the brief names this one): emit chunked framing to a 1.0 client. Expect
  the 1.0 table rows red.

### M3.3 — write accounting

Bytes outstanding and request count, with `write-high-water` / `write-low-water`
arriving per §3 (*amended 2026-09-25:* in M6). Design §7.3 is the load-bearing fact: chez-libuv copies each write
payload into request-owned foreign memory at the call
(`vendor/chez-libuv/src/libuv/stream.sls:88-128`), so the core does **not** retain
response bytevectors until completion. Accounting tracks bytes, not buffers.

- **Check added:** an assertion that the write executor holds no reference to the
  segment list once `uv-write*!` has returned.
- **Mutation:** retain the segment list until the completion callback. Expect the
  retention assertion red and every wire test green — the same shape as M2.3, and the
  reason both are worth writing.

*Noted 2026-09-25 (M3.3):* the check is the core's half, as decision 0010 item 5 words
it. A connection as the shell holds one (the core's state in the adapter's context, and
its parser) keeps no part of a response once its write is issued. Weak pointers see it
across a full collection (`tests/test-connection-retention.sps`). The write executor
itself is M4.2's shell, which carries the other half.

### M3.4 — the eight originated statuses

Every status in design §6.5 — 400, 408, 413, 414, 431, 500, 501, 505 — produced
end-to-end through the serializer, each closing the connection.

*Noted 2026-09-25:* nothing produces 413 before M6's buffering helper (decision 0005's
`max-body-bytes` row), so 413 goes through the serializer alone here. Decision 0009 added
a ninth originated status, 301, which closes too.

- **Mutation:** make one of them keep the connection alive. Expect the close assertion
  red for that status alone.

*Noted 2026-09-25 (M3.4):* `tests/test-connection-originated.sps` drives each end to
end: one row per reason the core closes with after a status of its own, and one for each
of a parser error's two statuses. A row states what the client reads back through
chez-httparse's strict response parser, that nothing sent after the offending request is
fed or answered, and the close. `(http-server decisions)` exports its reasons as
`originated-reasons`, so a reason added without a row fails the suite. The mutation ran
once per reason, and each turned that reason's rows red and no other row. The 408 had no
end-to-end test before: only the table's rows made one, from a state they built.

### M3.5 — the staged close

*Added 2026-09-25, on the owner's word (ledger, M3.4).* After a status the core
originates is written, the connection closes in stages, as RFC 9112 §9.6 describes. The
core asks for `shutdown`, the half-close, so the client reads the status and then the
stream's end. It reads on and drops what arrives, and it closes when the client closes or
a linger deadline passes. Closing at once while the client is still sending makes the
server's TCP stack send a reset, which erased a 431 already written in every run of the
measurement behind the decision. The slice settles, measuring first, the linger limit and
its default (a row in decision 0005's table, by a decision record), the state the
connection lingers in, and which closes linger. The shell's half is M4.2's.

- **Mutation:** close at once when the write completes, as M3.4 left it. Expect the
  staged close's rows red.

*Noted 2026-09-26 (M3.5; decision 0011, on the owner's word):*
- **Measured first, and the premise corrected.** The reset did not erase the 431: M3.4's
  spike had counted a read that succeeded, then met a reset, as a failure. What a reset
  does lose, on Darwin and Linux:
  - a client still sending never reads the status. After a 4 MiB upload was refused,
    Python and Node read it in 0 of 20 runs, and curl in 20;
  - the part of a response not yet sent is thrown away. A handler's 4 MiB response,
    closed at once behind an unread pipelined request, was cut short in 8 of 20 runs
    and 13 of 20.
- **Decided by form.** Every close after a response lingers, the core's own statuses
  and a handler's close alike. There is one limit, `linger-timeout-ms`, 30 000, armed
  once.
- **Landed.** The connection lingers in a tenth state, `lingering`, and a state that
  reads stops reading when it refuses a request. `tests/test-connection-linger.sps`
  drives the closes a request or a handler asks for, and each way a linger ends. The
  originated suite follows each status's close to its end.
- **Mutations.** The plan's mutation turned the staged close's rows red: 78 checks in
  six suites on the second PR's tree, and 8 of the linger suite's 9 on the third's.
  The other mutants are in the mutation log, all killed.

### M3 exit

Brief's gate: table tests; the corpus lane still green; the chunked-to-1.0 mutation
witnessed. Plus: the allocation gate re-measured with the response path in the loop, and
the serializer's segment count asserted rather than assumed.

*Noted 2026-09-26 (the M3 exit):* all of it holds.
- `make test` passes. The corpus lanes hold at 'full (9,394 runs).
- The chunked-to-1.0 mutation (M3.2-A) turns the decision's 1.0 rows red, and nothing
  else can see it before M6. The segment-count mutation (M3.1-A) turns the serializer's
  counts red, and the core's write rows.
- The gate fits with the response path in the loop (decision 0002's note of this date).
  Two response shapes became checks: a body is never copied, and a status line is made
  once.

Measuring requests a server meets beside the gate's GET found byte-machine #139. Its
keyword matcher cost a field the parser reads by name 1 to 4.4 KB. On the owner's word,
M3's close waited for the fix: byte-machine v0.6.1, pinned through chez-httparse v0.4.3
and uriparse v0.6.1. The gate's GET then costs 1,840 B, and two requests a server meets
join the gate: a JSON POST, and ab -k's HTTP/1.0 keep-alive GET.

---

## 8. M4 — the libuv shell and the first real server

Implements design §5.2, §6.4, §8.4's contract test and §8.5's socket lane. **This is the
milestone that produces a usable server**; everything after it is scoped by the brief's
exits (brief risk 6).

**Entry:** M3 merged. **Branch:** `feat/m4-libuv-shell`. **Mutation log:**
`m4-mutations.md`. **Likely two PRs**: M4.1–M4.2, then M4.3–M4.4.

### M4.1 — the adapter, and the closures the shell owns

`(http-server private adapter)`: the 25 required parser callbacks, **one binding list
per server**, passing the connection through the parser's user-context argument. The
ten libuv-side closures decision 0003 names are the shell's, not the adapter's, and
land in M4.2. That
sharing is load-bearing and measured — a fresh 25-entry list per connection would add
1,216 bytes each (design §7.5).

No continuation is captured under a C frame, which is decision
[0003](decisions/0003-direct-callbacks-in-the-shell-coroutines-only-for-awaiting-handlers.md)'s
whole reason for existing.

- **Mutation:** build the binding list per connection. Expect the per-connection
  allocation assertion red.

*Noted 2026-09-26 (M4.1):* the adapter came in M2.2, so M4.1 is its check. A
connection's parser costs what `make-parser` does on a binding list made once,
1,056 B, and the mutation's list per connection costs 1,584 B more: the adapter's
bindings are closures, where §7.5's 1,216 B was a plain list. The tracing hook the
ledger carried here is the shell's. Parser callbacks reach the core directly, and
the actions they queue are traced where the shell runs them, which is what M4.4's
contract test compares.

### M4.2 — the shell: close ownership, depth, and the two hazards

`connection-close!` as the only `uv-close!` caller, with the `rg` gate in `make test`;
handler-facing libraries export no `uv-*` name; the depth counter around `parser-feed!`
**and** `drain!`.

The two composition hazards from design §6.4 become checks here:

1. The run loop guards on `condition?` with an explicit `byte-machine-contract-condition?`
   arm, because `&byte-machine-contract` derives from `&condition` and **not** `&error`
   (`vendor/chez-httparse/vendor/byte-machine/src/byte-machine/private/conditions.sls:21`)
   — a catch-all `error?` guard would silently miss `reentrancy` and `poisoned-parser`.
2. No action but `reply-parser` runs at parser depth, re-asserted against the real
   shell rather than the fake one.

- **Mutation A:** narrow the run-loop guard to `error?`. Expect a raised
  `&byte-machine-contract` to escape uncaught.
- **Mutation B:** remove the `rg` close-ownership gate and add a second `uv-close!`
  caller. Expect the gate red — and note the gate is the test here, not a suite.

*Noted 2026-09-26 (M4.2):* Mutation A's expectation does not hold for a callback's
raise, which is where every parser feed runs in the direct shell. chez-libuv raises
it again from `uv-run` composed with `&uv-callback-error`, an `&error`, so a guard
narrowed to `error?` catches it and runs on. What keeps a poisoned parser fatal is
the contract arm's place before the callback-error arm. The mutation still turns the
check red, by running on rather than by escaping (`m4-mutations.md`). M4.2's suite
listens on a listener of its own; M4.3 brings the server's.

*Carried from M3.3 (2026-09-25):* the write executor holds no reference to the segment
list once `uv-write*!` has returned: its `on-complete` closure keeps the byte count the
completion reports, never the segments. M3.3's retention check, run against the real
shell, is its test, watched to fail by a closure that captures the segments.

*Carried from M3.4 (2026-09-25):* the shell's half of M3.5's staged close. The shell
performs the core's `shutdown` as `uv_shutdown`, reporting `shutdown-completed`, and reads
on, handing the core what arrives, until the core asks for `close`. M4.4's socket lane
gets the measurement that decided it (ledger, M3.4) as a test: a client that sends past a
refusal reads the status back, where a close at once gives it a reset.

*Corrected 2026-09-26 (M3.5):* the measurement is decision 0011's. A client that sends
past a refusal loses the status to an immediate close only while its send is still
under way, as with a 4 MiB upload; a small remainder is read either way. So the socket
lane's test uploads past a refusal. The shell performs `read-start` when the core
lingers, since reading stopped at the refusal or at the pause.

### M4.3 — the listener and `server-step`

`server-step` with its own events and actions (design §4.6): `accept`, `refuse` over
`max-connections`, `close-listener`, `force-close-all`, `log`. `backlog` arrives per §3.
Keeping it a second pure step is what lets SIGTERM drain be table-tested with a fake
clock in M8 instead of being shell code nobody can test.

- **Mutation:** make `refuse` accept anyway above the cap. Expect the connection-count
  row red.

### M4.4 — the contract test, and the socket lane

The gate that keeps the shells honest: the same scripted event stream through the fake
shell and the direct libuv shell must produce **identical wire bytes and identical
action traces**. Written here with two shells; extended to the coroutine shell in M7.

The socket lane in chez-libuv's `tests/test-echo.sps` shape: bind `127.0.0.1:0`, clients
on the same loop, cap by **iteration count and never wall-clock**, assert on bytes and
verb sequences only — never on how libuv fragmented the stream, which is kernel policy.

- **Mutation:** introduce a one-byte divergence in the libuv shell's write path. Expect
  the contract test red with the differing byte named, and the socket lane green — which
  is exactly what makes the contract test worth having, since the socket lane asserts on
  verb sequences and cannot see it.

### M4.5 — the facade, and what a handler sees (added 2026-09-26)

*Re-planned in the ledger (brief risk 6):* no slice held `(http-server)`, decision
0001's facade, and the exit needs a server that curl and ab can reach. Decision
[0012](decisions/0012-a-handler-reads-the-request-through-accessors-and-the-server-listens-where-the-environment-says.md)
settles its two questions. A handler reads the request through accessors that copy
what it asks for, with the host by RFC 9112 §3.2.2. The server listens where
`CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, defaulting to 127.0.0.1 and 8080. A facade
that builds limits refuses a pipeline cap other than 1 (ledger, M2.4).

- **Mutation:** an absolute-form request's host read from its Host field. Expect the
  host row red.

### M4 exit

Brief's gate: `curl` and `ab` get correct responses; counters return to zero; the
contract test passes. Plus: the connection table reconciled against
`uv-loop-live-handles` at one place in the run loop, and the per-connection resident
budget re-measured against design §7.5's 16,384 + 264 + 1,072 and recorded.

---

## 9. M5–M8 — entry conditions, not yet sliced

These four carry the brief's exits unchanged, the design sections they implement, the
limits that arrive, and the hazard each will have to answer. **They are deliberately not
sliced** — §10 says why.

### M5 — timeouts and limits
Design §4.3's per-state deadlines, `(http-server wheel)`, §6.3's policy family.
Limits arriving: `write-timeout-ms`, `tick-ms`.
*Noted 2026-09-26 (M3.5):* the kinds the wheel turns into instants include `linger`
(decision 0011), whose duration, `linger-timeout-ms`, arrived in M3.5.
**Hazard:** the wheel is the first thing whose correctness is a *timing* property, and
the fake clock is the only reason it is testable at all. A deadline of D ms fires within
`[D, D + tick-ms]`, so every assertion is an interval, not a point.
**Exit (brief):** fake-clock table tests; slow-client socket tests close within a tick of
the deadline; **no per-connection timer handle exists** — one tick timer per loop.

### M6 — body streaming and backpressure
Design §4.1's body events, §7.2's read-stop/read-start.
Limits arriving: none new; the buffering helper's own 1 MiB cap (0005 row
`max-body-bytes`) is introduced here, distinct from the `#f` field that means bodies
stream.
**Hazard:** brief risk 3 — a pause inside `on-body-data` needs the re-feed to start at
`parser-result-next`, and byte-machine needs one more feed, possibly empty, after a
pause on the last body byte. Both get pinned tests.
**Exit (brief):** 16 MiB each way against a slow peer with bounded memory; libhtp's
Expect and early-response files pass.
*Carried from M3.2 (2026-09-25):* the core closes the connection after a close-delimited
body (`write-action`, `'close-delimited`), which the framing decision gives only to a body
of unknown length. No response has one before M6, so no row reaches that arm yet: M6's
first HTTP/1.0 stream is its row, watched to fail by dropping the arm.

### M7 — the scheduler and awaiting handlers
Design §5.2 and §5.3's invariants R1–R5.
**Hazard:** the `phase` cell is the only thing standing between this and the stale
foreign context trap that decision 0003 exists to avoid.
**M7's gate is five mutations, not seven.** The two-level proposal carries seven
invariants; decision 0003 item 2 adopts R1–R5 as M7's checks, and design §5.3 records
that the other two are already project rules enforced elsewhere — exactly one procedure
calls `uv-close!` (M4.2's `rg` gate) and v1 is single-threaded (design §7.4). Nothing
about the count is open.
**Exit (brief):** a handler awaiting `uv-getaddrinfo!` inside a pipelined connection
keeps response order; **each of R1–R5 has a mutation that goes red** — that is the
milestone's real gate. Design §5.3 already names three of them: swap `'once`/`'nowait`,
remove the one-shot check in the resume cell, call a handler from inside `on-data`.

### M8 — shutdown, hand-off, black-box, release
Design §4.6, §4.4's hand-off row, §8.8's later lanes.
Limits arriving: `drain-timeout-ms`.
**Hazard:** the upgrade hook is a door for code we do not write. Its shape is fixed here
and its only v1 user is h2c → 505 + close (0006 item 2); the WebSocket shape is reserved,
not built.
*Amended 2026-09-25 (decision 0006's amendment, M2.5):* the core answers the HTTP/2
preface 505 itself, so the hook has no v1 user. M8 opens the door at the message's end,
for a handler that takes upgrades; until then an upgrade is served and the connection
closed.
**Exit (brief):** v0.1.0 tagged with the measured numbers in `CHANGELOG.md`.

---

## 10. Why M5–M8 are not sliced

Because slices written now would be fiction, and there is a sibling's record proving it.

chez-httparse's own milestone plan (`.plans/2026-09-13-gate0-http-parser-milestone-plan.md`
in that repository) wrote forward "reachable ceilings" for each milestone
and then had to correct nearly every one after measuring — M3's ceiling was written as
44 cumulative and achieved 29, and the plan's own note says the error was "the
methodology, not the arithmetic": a fixture's deepest event does not say which capability
its failure needs. Its conclusion is the rule this document adopts —

> Every future ceiling is a bucket count until the slice runs, and the ratchet is the
> measurement.

M5's deadline intervals, M6's memory bound, M7's invariant set and M8's drain semantics
all depend on numbers M2, M3 and M4 will produce. Writing slices for them today would
produce detail that a dated amendment then has to retract, which is more work and less
truth than leaving them at milestone grain and saying so.

**The amendment is part of M4's close-out**, not a separate task: when M4 merges, this
document gets a dated section slicing M5–M8 against what M2–M4 measured.

---

## 11. Out of scope for this plan

- **Anything M0 already shipped.** Re-planning merged work is how a ledger starts lying.
- **Re-arguing decisions 0001–0008.** A slice that wants a different answer opens a
  decision record; it does not relitigate in a plan.
- **The lenient corpus lane.** The 32 `request-lenient-*` fixtures are `deferred` by
  class (§2.1). Promoting them is a decision record.
- **HTTP/2, TLS, and a handler framework** — all three are outside the project by
  decision [0001](decisions/0001-the-project-is-the-composition-layer-and-where-it-stops.md).
- **New upstream asks.** All fourteen filed asks landed before M0 and every pin is at a
  release tag (0008). A new gap found during M1–M4 is filed upstream first and carried
  with a recorded workaround, exactly as 0008 prescribes — it does not become a fork.

---

## 12. Standing risks, and where each is discharged

The brief's six, with the slice that answers each. A risk with no slice is a risk nobody
owns.

| # | Risk | Discharged by |
|---|---|---|
| 1 | Allocation per request (gate ≤ 3 KiB) | **M2.3** (the collector) and **M2 exit**, re-measured at **M3 exit** with the response path in the loop, where two requests a server meets joined the gate once byte-machine #139 was fixed (2026-09-26) |
| 2 | The 64 KiB read buffer dominates per-connection cost | already answered in M0 — `read-buffer-size` defaults to 16,384 — and **re-measured at M4 exit** against the real handle |
| 3 | Pause protocol edges | **M2.4** (mutation A, against the measured 51/47 boundary) and **M6** (the empty-feed-after-pause case) |
| 4 | Close-delimited response bodies need `parser-finish!` | **not this server's path** — only the test client and a future proxy see it. Named in **M8**'s black-box lane, where the test client exists |
| 5 | The corpus is parser truth, not server truth | **M1.4**'s three-lane ratchet, which is the structural answer: the trace lane, the outcome lane and the libhtp lane are gated separately, so parser truth can never vouch for server truth |
| 6 | "Comprehensive" has no natural stopping point | **M4** produces a usable server; §10's amendment rule and §11's scope list are the brake |

---

## 13. What this plan does not settle

One thing, and it is the owner's rather than a slice's.

**CI has never run a job on this repository.** Measured 2026-09-20: all **ten** GitHub
Actions runs — every run since the M0 pull request — ended `failure` with **zero steps
executed**, aborted at the account billing check ("recent account payments have failed
or your spending limit needs to be increased"). The Linux leg is therefore unverified
for M0 and for all three documentation pull requests, and the red check carries no
information about any of them.

Nothing in this plan is blocked by it: `make test` runs locally on Darwin arm64, and
that is the only signal the repository has had since it began. But **M1's exit is the
first that would genuinely benefit from the Linux leg**, because the corpus lane is the
first lane whose result could plausibly differ by platform — decoded byte counts, chunk
ladders and trace rendering all go through string and bytevector paths that a different
Chez build could disagree about. It is an account setting, not a repository change.
