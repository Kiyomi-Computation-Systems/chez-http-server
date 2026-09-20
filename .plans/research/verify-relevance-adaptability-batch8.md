# Skeptic verification — batch 8 (relevance & adaptability lens)

Verifying 6 corpus candidates for chez-http-server. Lens: is the material HTTP/1.x
SERVER-SIDE / connection-semantics (keep-alive, pipelining, framing precedence, close,
upgrade, limits, timeouts, smuggling), or is it parser-only (redundant with the llhttp
corpus already vendored), client-only, or HTTP/2-only? Can it be turned into byte
streams / scripted sessions we replay? What's the real extraction effort?

All fetches done live via `curl` against raw.githubusercontent.com and
api.github.com on 2026-09-19. Saved copies of every file quoted below are in
`fetched8/` next to this report.

---

## 1. cispa/http-conformance

**Repo metadata** (`https://api.github.com/repos/cispa/http-conformance`):
`default_branch=main`, `pushed_at=2026-07-16T06:30:13Z`, `stargazers_count=18`.

**License** — `https://raw.githubusercontent.com/cispa/http-conformance/main/LICENSE`
(fetched8/cispa-LICENSE): `MIT License / Copyright (c) 2023 Jannis Rautenstrauch`.
Confirms MIT as claimed.

**testcases.py** — `https://raw.githubusercontent.com/cispa/http-conformance/main/testcases.py`
(fetched8/cispa-testcases.py, 4426 lines). `grep -c "^class "` → **106** classes,
matching the claimed rule count exactly.

Activity-type breakdown (`grep -o "activity = Activity\.[A-Z]*" | sort | uniq -c`):
```
  11 activity = Activity.DIRECT
  89 activity = Activity.PROXY
   6 activity = Activity.RETRO
```
Exact match to the candidate's claimed 11/89/6 split.

HTTP/2-only rules: `grep -c 'category = "HTTP/2"'` → **5**, matching the "5 HTTP/2-only
rules" note (the candidate's own `covers` field additionally rounds this to "5
HTTP/2-only rules (N/A)").

**helpers/output/test_overview.tex** —
`https://raw.githubusercontent.com/cispa/http-conformance/main/helpers/output/test_overview.tex`
(200 OK, fetched8/cispa-test_overview.tex):
```
Considered tests &  106 \\
Probe tests      &   89 \\
Direct tests     &   11 \\
Retro tests      &    6 \\
Requirements     &   41 \\
Recommendations  &   27 \\
ABNFs            &   38 \\
```
Exact match to every number in the candidate's `corpus_paths` annotation.

**sanity_check/serve_testcases.py** and **testbed/docker-compose.yml** both return
200 at the claimed paths — file layout confirmed.

**Format check** — read the first two classes in full (fetched8/cispa-testcases.py:23-89,
130-193). `continue_before_upgrade` (DIRECT) builds a raw request via
`build_request(...)` with literal `Connection`/`Upgrade`/`Expect` header bytes, sends
it, and inspects the returned status-code sequence — this is genuinely a byte-level,
server-side test with an unambiguous expected outcome, trivially transcribable to (a)
raw bytes + expected status. `code_400_after_bad_host_request` (also DIRECT despite
having `valid()`/`invalid()` handlers — those are for the differently-activitied
sibling classes) constructs three malformed-Host requests and checks for 400; its
`valid()`/`invalid()` pair is a positive/negative response-serializer fixture as
claimed.

**Skeptic check — connection-semantics coverage is thin.** `grep -ni
"pipelin|keep-alive|keepalive|smuggl|timeout"` over the whole 4426-line file returns
**zero** matches — this corpus has no pipelining, keep-alive, smuggling, or timeout
tests at all, despite covering the same RFC 9112 family. The one framing/close-adjacent
test is `close_option_in_final_response` (fetched8/cispa-testcases.py:3094-3128,
source `rfc9112#name-tear-down`), which checks a single request/response pair, not a
multi-message close sequence. The closest thing to "framing precedence" is
`content_length_2XX_connect` / `transfer_encoding_2XX_connect` (CL/TE on a 2xx CONNECT
response) and `content_length_1XX_204` — narrow, not general CL+TE-conflict smuggling
tests. This doesn't contradict the finder's own `covers` list (which never claimed
pipelining/keep-alive/smuggling), but it does mean this corpus mainly targets
field-syntax and status-code compliance rather than the connection-state-machine
material the task lens is prioritizing.

**Verdict: not refuted.** Every specific claim in the candidate (paths, counts, format,
license, HTTP/2 count) checked out exactly against the live repo — this is the most
accurately described candidate in the batch. Tier 2 is appropriate; it is real,
byte-level, server-side, non-redundant with llhttp (llhttp doesn't check response-side
behavior or the 89 PROXY rules' semantics at all), and directly adaptable. Its
connection-semantics coverage (pipelining/keep-alive/smuggling) is essentially nil,
which the finder didn't overclaim. Extraction estimate for the useful DIRECT subset
(11 classes, each ~30-60 lines of simple byte-construction + status check): roughly
1 hour/class to hand-port → **~10-12 hours** for all 11; cherry-picking the dozen or so
PROXY rules that are genuinely framing-relevant (duplicate fields, CL/TE-on-2xx/1xx/204,
close option) adds roughly another **6-8 hours** since those need to be reframed as
response-generation fixtures rather than live-probe checks.

---

## 2. MDA2AV/Http11Probe

**Repo metadata** (`https://api.github.com/repos/MDA2AV/Http11Probe`):
`pushed_at=2026-09-16T14:59:29Z`, `stargazers_count=30`,
license = MIT (`https://raw.githubusercontent.com/MDA2AV/Http11Probe/main/LICENSE`,
fetched8/http11probe-LICENSE: "MIT License / Copyright (c) 2026 Diogo Martins").

**Suite files** — full repo tree via
`https://api.github.com/repos/MDA2AV/Http11Probe/git/trees/main?recursive=1`
(fetched8/http11probe-tree.json) confirms exactly the 7 files claimed:
`src/Http11Probe/TestCases/Suites/{Capabilities,Compliance,Cookie,MalformedInput,
Normalization,Smuggling,WebSockets}Suite.cs`.

Per-file `Id = ` counts (`grep -c "Id = "`):
```
CapabilitiesSuite   9
ComplianceSuite    69
CookieSuite        12
MalformedInputSuite 26
NormalizationSuite   5
SmugglingSuite      87
WebSocketsSuite      5
```
Sum = **213**, exactly matching the candidate's "213 'Id =' in suites" claim.
(SmugglingSuite is 87, one less than the "88" figure used elsewhere in the
candidate's prose — trivial rounding, not a real discrepancy.)

**Format and quality** — read `SmugglingSuite.cs` in full (fetched8/http11probe-SmugglingSuite.cs,
3023 lines). It is genuinely sophisticated: purpose-built `AnalyzeClTeBoth`,
`AnalyzeDuplicateCl`, `AnalyzeTeWithClFallback` behavioral analyzers decode which
framing (CL vs TE) a server actually used from the echoed response body, plus a
`CountHttpStatusLines` helper to detect request smuggling (two responses arriving on
one read = desync). Concrete example test cases read in full
(fetched8/http11probe-SmugglingSuite.cs:166-230): `SMUG-TE-XCHUNKED` (rejects
`Transfer-Encoding: xchunked` treated as chunked, RFC 9112 §6.1),
`SMUG-TE-TRAILING-SPACE`, `SMUG-TE-SP-BEFORE-COLON` — each carries a literal raw
request string via `PayloadFactory` and either a plain status-range check or a short,
readable `CustomValidator` lambda. This is directly transcribable to (a) byte fixtures;
the "expectations are partly lambdas" caution in the candidate is real but overstated —
the lambdas actually read (e.g. "400/501 or close" logic) are short and mechanical, not
opaque.

**Skeptic correction — docs-page count is internally inconsistent and off from the
live repo.** The candidate states "188 per-test pages" with a category breakdown
(request-line 27, smuggling 88, malformed-input 27, headers 16, body 16, cookies 13,
caching 10, host-header 8, http-overview 8, normalization 6, websockets 6,
line-endings 5, content-length 4) that itself **sums to 234, not 188** — an internal
arithmetic error in the candidate. Actual fetch of the repo tree
(fetched8/http11probe-tree.json) and count of non-`_index.md` files under
`docs/content/docs/<category>/` gives:
```
smuggling 87, malformed-input 26, request-line 26, body 15, headers 15, cookies 12,
caching 9, host-header 7, http-overview 7, normalization 5, websockets 5,
line-endings 4, content-length 3   (total 221 per-test pages)
```
Every category is exactly one less than the candidate's figure — consistent with the
finder having accidentally counted each category's own `_index.md` as a per-test page.
This is a minor citation/count error, not a substance problem: it doesn't change
whether the corpus is real or extractable, since the primary extraction target is the
`.cs` suite files (whose counts check out exactly), with the Markdown pages as a
secondary aid.

**Minor correction — toolchain requirement.** `Http11Probe.csproj` targets
`net8.0;net9.0;net10.0` (fetched8, `grep TargetFrameworks`), not exclusively .NET 10 as
the candidate's notes imply — irrelevant to us anyway since we'd only be reading the
source as data, not running it.

**Verdict: not refuted.** Genuinely server-side, byte-level, heavily weighted toward
exactly the connection-semantics/smuggling material the task lens asks for (87 of 213
cases are CL/TE-desync tests with real behavioral analysis, not just status-code
checks). Tier 2 confirmed. Extraction estimate: the `.cs` payload+expectation pairs are
short and mechanical (~15-25 lines each); porting the full 213 would be roughly
**20-30 hours**, but the highest-value subset — the 87 SmugglingSuite cases plus the ~30
Compliance cases touching framing/Host/chunking — could be done in roughly **12-16
hours** given the uniform `PayloadFactory`/`Expected` shape.

---

## 3. The four "h1spec" repos

### 3a. dropseed/h1spec

Repo metadata (`https://api.github.com/repos/dropseed/h1spec`): `default_branch=master`,
`pushed_at=2026-03-05T18:04:29Z`, `stargazers_count=0`, GitHub API `license: null`.
`https://raw.githubusercontent.com/dropseed/h1spec/main/LICENSE` → 404 (no LICENSE
file at all, confirmed by re-checking on the correct `master` branch too — still no
LICENSE file in the tree). `pyproject.toml`
(`https://raw.githubusercontent.com/dropseed/h1spec/master/pyproject.toml`,
fetched8/dropseed-pyproject.toml) does contain `license = "MIT"` — confirms the
candidate's "licence only in pyproject.toml" claim exactly.

Repo tree (fetched8/dropseed-tree.json) confirms the claimed module layout:
`h1spec/tests/{request_line,headers,body,connection,response,hardening}.py`. Per-file
`def test_` counts:
```
request_line 7, headers 7, body 11, connection 3, response 2, hardening 3   (= 33)
```
Exact match to the candidate's "33 (7/7/11/3/2/3)" claim.

Read `connection.py` in full (fetched8/dropseed-connection.py, 79 lines) — it is a
genuine, small, live-socket test module: `test_keepalive_default` opens one socket,
sends two sequential `GET` requests, and checks both get valid responses (real
HTTP/1.1 keep-alive verification); `test_connection_close` and `test_http10_closes`
send a request and assert the server actually closes the TCP connection afterward.
This is exactly the connection-semantics material the task lens is looking for, and it
is small, clean Python trivially portable to a Scheme byte-stream test.

### 3b. uNetworking/h1spec

Repo metadata: `default_branch=main`, `pushed_at=2024-10-27T23:28:44Z`,
`stargazers_count=41`, GitHub API `license: null` — confirmed no license.

Repo tree (fetched8/unet-tree.json): `http_test.ts`, `test_subjects/{bun,deno,nodejs}_test_subject.*`
— confirms format. `http_test.ts`
(`https://raw.githubusercontent.com/uNetworking/h1spec/main/http_test.ts`, 291 lines,
fetched8/unet-http_test.ts) defines `interface TestCase { request: string; description:
string; expectedStatus: [number, number][] }` plus `expectedTimeout`, matching the
candidate's schema claim exactly; `grep -c "description:"` → 34 (candidate says 33,
off by one, negligible). README
(`https://raw.githubusercontent.com/uNetworking/h1spec/main/README.md`,
fetched8/unet-README.md) documents it as a real server conformance checker used
against Deno/Node/Bun/uWS/mrhttp with a results table, confirming server-side
relevance and the "fragmented-request timeout" idea (15 `expectedTimeout: true` cases
sending partial request lines to verify the server *waits* rather than responding
early — a genuinely useful, connection-state-machine-relevant idea, though
unlicensed so it can only be reimplemented from the idea, not copied).

### 3c. LeaYeh/h1spec

Repo metadata: `default_branch=main`, `pushed_at=2025-06-08T22:52:47Z`,
`stargazers_count=2`, GitHub API license = `agpl-3.0` (fetched8/leayeh-repo.json) —
confirms AGPL-3.0, correctly flagged by the finder as incompatible with a BSD-3-Clause
target repo.

**Skeptic correction — case count is overstated by roughly 2x.** The candidate claims
"spec/http1.1/RFC9112_3_request_line.go (1) and spec/http1.1_archive/*.go (34, RFC
7230-era)" for **35** total. Direct fetch of every file in `spec/http1.1_archive/`
(fetched8/leayeh-archive-*.go) and counting `AddTestCase` calls gives:
```
RFC7230_2_5_error_handling.go        3
RFC7230_2_6_protocol_versioning.go  11
RFC7230_2_architecture.go            0
RFC7230_3_3_3_MultipleContentLength.go 1
RFC7230_3_message_body.go            0
RFC9112_3_2_MissingHostHeader.go     1
RFC9112_3_request_target.go          0
RFC9112_7_1_ChunkSizeHexadecimal.go  1
RFC9112_7_chunked_transfer_coding.go 0
http11.go / RFC7230.go / RFC9112.go  0 each
```
Total archive test cases = **17**, not 34. Combined with the 1 current-tree test
(`spec/http1.1/RFC9112_3_request_line.go`, read in full, fetched8/leayeh-current.go),
the real total is **18**, not 35. Several "0 test case" files
(e.g. `RFC7230_3_message_body.go`, read in full, fetched8/leayeh-archive-RFC7230_3_message_body.go)
are just group-registration stubs: `// DO NOT implement ... in this file / Reference
Implementation will be in the future files` — confirming this is an unfinished
skeleton, not a complete suite. The README
(`https://raw.githubusercontent.com/LeaYeh/h1spec/main/README.md`,
fetched8/leayeh-README.md) itself describes the project structure in future tense.
Since this repo is AGPL anyway (unusable to vendor directly, only usable as an idea
source), the overcount mostly matters for correctly sizing the "family"'s aggregate
yield, addressed below.

### 3d. wooshdev/h1spec

Repo metadata: `pushed_at=2020-02-15T16:56:52Z`, `stargazers_count=0`,
license = zlib (confirmed). Tree (fetched8/wooshdev-tree.json) and
`src/Tests/Test.cs` (fetched8/wooshdev-Test.cs, 207 lines) confirm this is a tiny,
6-year-old, minimal C# harness (e.g. a `Get` test that just checks the server doesn't
throw) — matches the candidate's "2020-era and tiny" characterization exactly.

**Verdict on the family: not refuted, but corrected_tier = 3 (down from 2).**
Reasoning: of the four repos, only **dropseed** is simultaneously (a) accurately
described, (b) genuinely server-side/connection-semantics relevant, and (c) not
blocked by licensing — but it is only 33 small test cases with license stated solely
in `pyproject.toml` (no LICENSE file), a real legal caveat the finder already flagged.
uNetworking is idea-only (no license). LeaYeh is both license-incompatible (AGPL) *and*
now shown to be roughly half the size claimed (18 real cases, not 35, many files being
unimplemented stubs). wooshdev is negligible. The finder's own per-repo caveats were
accurate, but the *aggregate* framing as a tier-2 "family" overstates the real,
usable yield once AGPL and license-null material are set aside — in practice this
bundle nets out to dropseed's ~33 cases plus a couple of reimplementable ideas from
uNetworking, which is better sized as tier 3. Extraction effort for the actually
usable part (dropseed only): **~4-6 hours** (33 small, uniform Python functions).

---

## 4. mnot/httplint field tests

Repo metadata (`https://api.github.com/repos/mnot/httplint`): `default_branch=main`,
license = MIT, `pushed_at=2026-08-08T06:00:28Z`, `stargazers_count=19`.
`https://raw.githubusercontent.com/mnot/httplint/main/LICENSE.md` → 200 (confirmed).

`httplint/field/tests.py`
(`https://raw.githubusercontent.com/mnot/httplint/main/httplint/field/tests.py`,
fetched8/httplint-tests.py) — `class FieldTest(unittest.TestCase, Generic[TMessage])`
found at **line 69** exactly, matching the candidate's `httplint/field/tests.py:69`
citation precisely.

Parser file count: full repo tree
(`https://api.github.com/repos/mnot/httplint/git/trees/main?recursive=1`,
fetched8/httplint-tree.json) → **108** files under `httplint/field/parsers/*.py`,
matching the claimed "108 files" exactly.

Read `content_length.py` and `transfer_encoding.py` in full
(fetched8/httplint-content_length.py, fetched8/httplint-te.py) — confirms the
FieldTest shape (`name`, `inputs: List[bytes]`, `expected_out`, `expected_notes`) and
that these are genuinely **field-value-only** fixtures: `inputs` is already an
isolated header value (e.g. `b" 1 "`, `b"chunked; foo=bar"`), never a full request or
even a full header line — there is no request-line, no multi-header interaction, no
socket, no connection-lifecycle behavior anywhere in this file's tests.

**Skeptic confirmation of the finder's own caveat.** `ContentLengthSpaceTest`
(fetched8/httplint-content_length.py) treats `b" 1 "` as parsing to `1` cleanly (no
warning at all) — a linter's tolerant view; RFC 9112 §6.3's `obs-fold`/whitespace
rules are stricter for a real server, so this exact fixture would need inverting for a
server-conformance suite, exactly as the finder warned. Likewise
`BadTransferEncodingTest` in `transfer_encoding.py` accepts `b"chunked=foo"` as a
recognized (if flagged) token rather than a hard parse failure — again a lint-tolerant
verdict that a strict HTTP/1.1 server parser should not necessarily copy.

**Verdict: not refuted.** Every specific citation (line 69, 108 files, MIT license)
checked out exactly. This is legitimately additive over llhttp (llhttp validates
message *framing*, not the semantic value-grammar of ~90 non-framing header fields
like Set-Cookie/CSP/HSTS/Cache-Control), and it is exactly what the finder already
scoped it as: a `layer: spec` fixture set for a future field-value-semantics module,
not connection-semantics material. Under this task's specific lens (keep-alive,
pipelining, framing precedence, close, upgrade, limits, timeouts, smuggling) it
contributes essentially nothing — no test here touches the wire, a socket, or
multi-message behavior. I'm leaving tier at 2 as rated since the finder already scoped
it correctly and didn't oversell it against this lens, but flagging for the synthesis
step that this is peripheral to the connection-semantics priority, useful only once a
field-value linting layer is actually being built.

---

## 5. httpwg/structured-field-tests

Repo metadata (`https://api.github.com/repos/httpwg/structured-field-tests`):
`default_branch=main`, `pushed_at=2026-09-16T01:35:13Z`, `stargazers_count=45`,
GitHub API `license.spdx_id = NOASSERTION`.
`https://raw.githubusercontent.com/httpwg/structured-field-tests/main/LICENSE.md`
(fetched8/sf-LICENSE.md) opens: "Copyright (c) 2018- IETF Trust and the persons
identified as authors of the code... Redistribution and use in source and binary
forms... are permitted provided that..." — a BSD-style redistribution license, exactly
as the candidate describes (explaining the NOASSERTION/API mismatch).

File listing (`https://api.github.com/repos/httpwg/structured-field-tests/git/trees/main?recursive=1`,
fetched8/sf-tree.json): 20 top-level `*.json` test files (binary, boolean, date,
dictionary, display-string, examples, item, key-generated, large-generated, list,
listlist, number-generated, number, param-dict, param-list, param-listlist,
string-generated, string, token-generated, token) — matches the candidate's file list
exactly, plus the 4 `serialisation-tests/*.json` files and 3 schema files also
confirmed present.

**Verdict: not refuted.** This is Structured Field grammar material (RFC 8941/9651),
confirmed genuinely unrelated to HTTP/1.1 framing/connection semantics as the finder
already stated outright ("Not HTTP/1.1 framing"). Tier 3 as rated is correct — it's
real, well-provenanced, and trivially loadable JSON, but only becomes relevant once/if
the server parses an SF-typed header, which is speculative for a v0 HTTP/1.1 server.

---

## 6. declaresub/abnf RFC 9110 corpora

Repo metadata (`https://api.github.com/repos/declaresub/abnf`): `default_branch=master`,
license = MIT, `pushed_at=2026-09-18T08:08:18Z`, `stargazers_count=54`.

Confirmed **no** `rfc9112.py` or `rfc9112.json` anywhere in the tree
(`https://api.github.com/repos/declaresub/abnf/git/trees/master?recursive=1`,
fetched8/abnf-tree.json) — only `rfc7230.py`/`rfc7230.json` exist alongside the
`rfc9110.*` files, exactly matching the candidate's "RFC 9112 (framing) rules are
absent; only RFC 7230's older transcription exists" claim.

Fetched all three RFC 9110 corpus files in full and computed rule/string counts in
Python:
```
tests/fuzz/corpus/rfc9110.json         rules=142  strings=13313
tests/fuzz/corpus_abnfgen/rfc9110.json rules=142  strings=958
tests/fuzz/corpus_neg/rfc9110.json     rules=140  strings=1639
```
All three numbers match the candidate's claims exactly
(142/13,313, 142/958, 140/1,639).

Spot-checked `corpus_neg/rfc9110.json` content
(fetched8/abnf-corpus_neg-rfc9110.json): e.g. `"Accept": ["\x00", "!\x00/!",
"!!\x00/!;"]`, `"Accept-Language": ["\x00", "*\x00", "*\t;\x00\tQ=1"]` — confirms the
"single grammar-alien character (NUL) injected into an otherwise valid string" pattern
claimed, not a corpus of realistic near-miss HTTP syntax mutations.

**Verdict: not refuted.** Every count and structural claim verified exactly.
Parser/field-grammar layer as the finder already scoped it (`layer: parser`), not
connection-semantics — legitimate for fuzzing a future SF/ABNF-adjacent layer but not
for keep-alive/pipelining/smuggling work. Tier 2 as rated.

---

## Summary table

| key | refuted | corrected_tier | headline reason |
|---|---|---|---|
| cispa-http-conformance | false | — (2) | Every specific claim verified exactly; genuinely server-side byte-level DIRECT+PROXY tests, MIT; but zero pipelining/keep-alive/smuggling tests exist in it. |
| http11probe | false | — (2) | Suite/case counts verified exactly (213); sophisticated CL/TE-desync smuggling analyzers confirmed by reading source in full; docs-page count claim (188) is internally inconsistent (sums to 234) and off from the actual 221 — minor citation error only. |
| h1spec-family | false | 3 (down from 2) | dropseed (33 cases, real keep-alive/close tests) verified legit but license-only-in-pyproject; uNetworking has no license (confirmed); LeaYeh is AGPL (confirmed) **and** its case count is overstated ~2x (18 real cases, not 35 — many files are unimplemented stubs); wooshdev is negligible. Real usable yield is much smaller than the bundle framing suggests. |
| httplint-field-tests | false | — (2) | Citations (line 69, 108 files) verified exactly; genuinely additive over llhttp for field-value semantics, but contributes nothing to the connection-semantics lens (pure value-level linting, no wire/socket/multi-message behavior anywhere). |
| httpwg-structured-field-tests | false | — (3) | File list and license text verified exactly; confirmed SF-grammar-only, not HTTP/1.1 framing, as already scoped. |
| declaresub-abnf-rfc9110-corpora | false | — (2) | All three corpus files' rule/string counts verified exactly; RFC 9112 absence confirmed; negative corpus confirmed to be single-alien-char injections, not framing mutations. |
