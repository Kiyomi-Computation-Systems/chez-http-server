# Verification report — batch5 (relevance & adaptability, SKEPTIC pass)

Task: verify 6 corpus candidates for chez-http-server, trying to REFUTE each on the lens of
**relevance** (server-side/connection-semantics vs. parser-only/client-only/HTTP-2-only) and
**adaptability** (can the cases become byte streams or scripted client sessions we replay).

Method: this scratchpad already contained full/partial git clones and fetched files from earlier
batches of the same research effort (`corpus-dl/`, `research/files/`, `research/node-src/`,
`research/verify0/`). I read the actual test/corpus files directly (not just the finder's
summaries), cross-checked exact case counts with `grep`/`wc`/a real YAML parser, and cross-checked
byte-for-byte / commit-for-commit against the live GitHub repos with `gh api` where a local clone
existed, to catch any staleness or miscounting. All commands and outputs below are what I actually
ran in this session.

---

## 1. `warp-run-and-connection-specs`

**Verdict: NOT refuted. Tier 2 confirmed.**

Local clone: `corpus-dl/wai` (git remote `https://github.com/yesodweb/wai.git`, HEAD
`9581c256dc343ab8793094fa008626db24f69633`, 2026-09-18 — matches the candidate's cited SHA
`9581c25` exactly).

```
$ cd corpus-dl/wai && git log -1 --format="%H %ai"
9581c256dc343ab8793094fa008626db24f69633 2026-09-18 12:12:25 +0200
$ git remote -v
origin  https://github.com/yesodweb/wai.git (fetch)
```

Counted `it`/`prop`/`testClose` occurrences directly in each file:

```
$ grep -c '  it "' warp/test/RunSpec.hs              -> 30   (claim: 30 it)          MATCH
$ grep -c '  it "' warp/test/RequestSpec.hs           -> 13 it + 1 `prop "random chunking"` = 14
                                                          (claim: 14 incl. 1 QuickCheck prop) MATCH
$ grep -c '  it "' warp/test/ConnectionSpec.hs        -> 1 it + 6 testClose calls
                                                          (claim: 1 it + 7 testClose)  OFF BY ONE
                                                          (actual testClose call sites, verified by
                                                          reading the full file, are exactly 6 — see
                                                          full listing below)
$ grep -c '  it "' warp/test/GracefulShutdownSpec.hs  -> 2   (claim: 2)               MATCH
$ grep -c '  it "' warp/test/ExceptionSpec.hs         -> 5   (claim: 5)               MATCH
$ grep -c '  it "' warp/test/SendFileSpec.hs          -> 15  (claim: 15)              MATCH
$ grep -c '  it "' warp/test/ResponseHeaderSpec.hs    -> 5   (claim: 5)               MATCH
```

`ConnectionSpec.hs` full read confirms it is exactly what the candidate describes — `testClose`
helper asserts `Connection: close` is echoed back for: (1) HTTP/1.0 Keep-Alive without
Content-Length, (2) plain HTTP/1.0 GET, (3) HTTP/1.1 GET with explicit `Connection: close` (200),
(4) same for HEAD, (5) 204 No Content, (6) 500 Internal Server Error — 6 calls, not 7 as the
finder's `approx_cases` field states. Also confirms the separate `it "does NOT send
\"Connection: close\" for HTTP/1.1 HEAD request"` case. This is a real (minor) miscount in the
finder's numbers, not a relevance/adaptability problem.

`warp/test/ResponseSpec.hs` is listed in `corpus_paths` but is **not counted anywhere** in
`approx_cases` — it actually contains 1 `it` (`sanitizeHeaderValue`) + 6 `testRange` + 3
`testPartial` generated specs (10 more cases), mostly about Range/partial-content responses, which
is response-generation rather than connection-semantics — a second, smaller finder omission, in
the direction of under-counting this time.

`RunSpec.hs` `it` titles (grep'd directly) confirm the claimed pipelining × body-handling matrix
verbatim — lines 209-262 are exactly the 2×(no body / has body / chunked body)×(read/ignore)
= 12 cases the candidate describes, split into a `"pipelining"` describe block and a non-pipelining
one. `GracefulShutdownSpec.hs` has exactly the 2 titled cases claimed
("waits for a connection accepted just before it stopped accepting" and
"serves the request in flight, then closes keep-alive connections and exits").

License: `corpus-dl/wai/LICENSE` — standard MIT text, "Copyright (c) 2012-2017 Michael Snoyman" —
matches claim. `warp/warp.cabal` `version: 3.4.16` matches the candidate's parenthetical
"(warp 3.4.16)".

**Assessment**: this is genuine server-side, raw-socket-driven (`withMySocket`/`msWrite`/`msRead`)
connection-semantics material — Connection-header close behavior, pipelining × body-consumption
matrix, graceful shutdown, chunked-body timeouts, obs-fold/no-space-after-colon header parsing at
the connection layer. It is exactly the kind of checklist our lens is looking for, and it is small
enough (~65 real cases once ResponseSpec.hs is added) to port by hand into Scheme byte-stream
fixtures. Tier 2 (not tier 1, because it requires manual Haskell→Scheme transcription and the
volume is modest) is the right call.

---

## 2. `aiohttp-parser-and-web-protocol-tests`

**Verdict: NOT refuted, but the "reference only" framing undersells the 10 raw-TCP functional
tests, which ARE directly extractable byte fixtures. Tier 3 confirmed as the bundle rating.**

Local clone: `corpus-dl/aiohttp` (git remote `https://github.com/aio-libs/aiohttp.git`, HEAD
`3497f81087cc8dee900f22cc4c431ccba6aff419`, matches the candidate's cited SHA `3497f81` exactly).

Exact test-function counts (`^async def test_|^def test_|    async def test_|    def test_`):

```
test_http_parser.py     231   (claim: 231)   MATCH
test_web_protocol.py     12   (claim: 12)    MATCH
test_web_server.py       15   (claim: 15)    MATCH
test_web_functional.py  120   (claim: 120)   MATCH
test_base_protocol.py    19   (claim: 19)    MATCH
```

The candidate's claim of "~10 raw-socket pipelining/upgrade-tail cases" in
`test_web_functional.py`: I first grepped for `socket.socket`/`sock.connect` and got **zero**
hits — the phrase "raw-socket" is loose. The actual mechanism is `asyncio.open_connection()`
(a real raw TCP connection bypassing aiohttp's own client), used at exactly 10 call sites (lines
1772, 1835, 1892, 1950, 2036, 2104, 2146, 2207, 2269, 2329), backing these tests:
`test_http1_pipelined_requests_are_count_limited`,
`test_http1_pipelined_queue_resumes_after_drain`,
`test_http1_pipelined_behind_declined_upgrade_served_once`,
`test_upgrade_tail_is_byte_limited`,
`test_upgrade_tail_resumes_reading_after_websocket_prepare`,
`test_bad_pipelined_data_behind_declined_upgrade_answers_400`,
`test_pipelined_requests_after_deferred_upgrade_are_served`,
`test_declined_websocket_upgrade_reads_body`, plus 2 more — count matches "10" precisely.

I read `test_bad_pipelined_data_behind_declined_upgrade_answers_400` in full — it writes a literal
byte payload (`b"GET /upgrade HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade:
websocket\r\n\r\n" + b"\x00" * 64`) and asserts the response contains both `b"declined"` and
`b" 400 "`. This is directly liftable into a Scheme bytevector fixture exactly the way the
Node.js smuggling tests are (candidate #6) — so calling this "design reference rather than a
corpus" (as the candidate's `adaptability` field does for `test_web_protocol.py`) is too dismissive
for these specific 10 tests; they belong in category (a)/(b), not just "reference."

License check: `corpus-dl/aiohttp/LICENSE.txt` starts with the standard Apache License 2.0 header
— matches claim. `vendor/README.rst` (top of file) confirms: "When building aiohttp from source,
there is a pure Python parser used by default... To build this `llhttp` parser..." — confirms the
candidate's citation that aiohttp's C parser is llhttp, so `test_http_parser.py`'s 231 cases (60%
of this candidate's total case count) genuinely duplicate coverage chez-httparse already has via
the llhttp fixture corpus.

**Assessment**: tier 3 / "reference" is a fair aggregate rating given that the majority of the
material (parser tests) is llhttp-redundant, but the 10 raw-TCP functional tests specifically
(pipelining count limits, queue-resume-after-drain, upgrade-tail byte limiting, bad-data-behind-
declined-upgrade → 400) are real, literal, server-side connection-semantics byte fixtures worth
extracting individually rather than treated purely as design inspiration.

---

## 3. `cpython-httpservers-httplib-tests`

**Verdict: NOT refuted. Tier 3 confirmed.**

Local clone: `corpus-dl/cpython` (partial checkout of `Lib/test/test_httpservers.py` +
`Lib/test/test_httplib.py` + `LICENSE`).

Exact counts (`    def test_`):

```
Lib/test/test_httpservers.py   103 test methods   (claim: 103)   MATCH
Lib/test/test_httplib.py       131 test methods   (claim: 131)   MATCH
FakeSocket( uses in test_httplib.py: 92            (claim: 92)   MATCH
```

Per-class counts inside `test_httpservers.py` (via `awk` range + grep):

```
BaseHTTPServerTestCase                : 22   (claim: 22)   MATCH
HTTP09ServerTestCase                  : 3    (claim: ~4)   close, "~4" was a hedge
BaseHTTPRequestHandlerTestCase (socketless): 19   (claim: 19)   MATCH
```

Spot-checked the request-line/version verdict claim: `test_version_bogus` sets
`_http_vsn_str = 'FUBAR'`, `test_version_digits` sets `'HTTP/9.9.9'`,
`test_version_invalid` sets `'HTTP/9.9'`, and line 1108 has
`(b'GET / FUBAR\r\n\r\n', 400)` — all match the candidate's description verbatim.

License: `LICENSE` line 73 is literally `PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2` — matches
the candidate's citation `LICENSE:73` exactly.

**Assessment**: this candidate's numbers are precisely accurate and well-cited. The finder's own
"Reference only" / tier 3 framing is correctly conservative: `http.server` used by
`BaseHTTPServerTestCase` is HTTP/1.0-only and does not pipeline, so it's weak evidence for
HTTP/1.1 server correctness; `test_httplib.py`'s 131 cases are predominantly about the *client*
library parsing *responses* (the reverse direction from what our server needs to parse), which
the candidate itself flags as only useful to "seed the response reader of our loopback test
client," not the server under test. That's an accurate self-assessment, not an overstatement.

---

## 4. `aws-http-desync-guardian`

**Verdict: NOT refuted — material is real, on-lens, and adaptable — but the finder's case-count
claim (668) is wrong by roughly 4×. Corrected total: 162 named cases. Tier 1 still justified on
quality/relevance grounds despite the volume correction.**

Local files: `research/files/desync-guardian/*.yaml` (+ README, LICENSE, docs-README).

I counted top-level test cases three independent ways — `grep -c "^- name:"`, `grep -c "^  expected:"`
(one per case), and an actual `python3 -c "import yaml; ... len(data)"` parse — all three agreed:

```
                              grep "^- name:"   python3 yaml.safe_load len()   candidate's claim
severe.yaml                        27                    27                        70
ambiguous.yaml                     40                    40                        90
bad-header-characters.yaml         15                    15                        38
real-life-test-cases.yaml          24                    24                       240
more-compliant-tests.yaml          10                    10                       117
rfc-compliant.yaml                 14                    14                        34
acceptable.yaml                     9                     9                        22
edge-cases.yaml                     8                     8                        26
uri-specific-test-cases.yaml       14                    14                        28
single-case.yaml                    1                     1                         3
--------------------------------------------------------------------------------------
TOTAL                             162                   162                       668
```

To rule out a stale local clone being the source of the discrepancy, I compared local byte sizes
against the live repo via `gh api repos/aws/http-desync-guardian/contents/tests`:

```
                          local wc -c    live gh api size
acceptable.yaml               3293            3293
ambiguous.yaml                14259           14259
bad-header-characters.yaml    5162            5162
edge-cases.yaml                3748            3748
more-compliant-tests.yaml     11498           11498
real-life-test-cases.yaml     23456           23456
rfc-compliant.yaml             4277            4277
severe.yaml                   10621           10621
single-case.yaml                485             485
uri-specific-test-cases.yaml   3864            3864
```

Every byte size matches exactly — the local files are current and complete, not truncated, so the
668-case figure in the candidate is simply a counting error (roughly 2.3×-10× overcount per file;
I have no explanation for how it was produced — possibly nested `headers:` sub-entries or line
counts were conflated with top-level cases somewhere in the finder's process). This is a material
factual defect that a synthesis agent should not repeat.

Other claims checked and confirmed:
- Format sample (`severe.yaml` head) matches the documented `{name, uri, method, version, headers:
  [{name,value,tier}], expected:{tier,reason,required_message_items}}` schema exactly, and
  `tests-README.md` (fetched from the repo) documents this schema verbatim, including the full
  `reason` enum (`MultipleContentLength`, `BothTeClPresent`, etc.) the candidate refers to.
- License: `LICENSE` — Apache License, Version 2.0 header confirmed.
- The "1614-byte body" caveat: confirmed real — `real-life-test-cases.yaml:816` has
  `- name: Send small (1614 bytes) request, transfer encoded request`.
- `src/request_analyzer.rs` exists in the live repo (`gh api repos/aws/http-desync-guardian/contents/src`
  → 89368 bytes) — confirms the "reference implementation of the classification" claim.

**Assessment**: this remains the strongest relevance/adaptability match in the whole batch —
sans-I/O by design (the repo's own stated tenet is "no knowledge of the language, only HTTP"),
directly keyed to RFC 9112 §6.3 framing ambiguity (CL/TE conflicts, duplicate Content-Length,
obs-fold, suspicious-header obfuscation) which is precisely our smuggling/framing-precedence lens.
162 real cases (not 668) is still a large, high-quality, directly-portable YAML→bytevector corpus
and easily justifies tier 1 on its own; the count correction matters for planning extraction
effort (which was already estimated generously at "~1 day" and remains plausible at the smaller,
correct volume) but does not change the tier verdict.

---

## 5. `h2o-http1-corpus`

**Verdict: NOT refuted. Tier 1 confirmed — every quantitative claim verified exactly against the
live repo.**

```
$ wc -l research/verify0/h2o-http1-corpus.tsv         -> 1972
$ awk '{sum+=$2} END {print sum}' ... .tsv            -> 2525951

$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" | python3 -c "... count fuzz/http1-corpus/* blobs"
truncated: False
http1-corpus files: 1972
url-corpus files: 90
total bytes: 2525951
```

Both the pre-existing local tree listing and a fresh live `git/trees` API call against
`h2o/h2o@master` agree exactly: **1972 files, 2,525,951 bytes, 90 files in `url-corpus`** — all
three numbers in the candidate match precisely (1972 files, 2,525,951 bytes, 90 url-corpus files).
This also confirms the candidate's own correction note ("Naive Contents-API listing pages at 1000
and under-reports; the true count 1972 was confirmed from the git tree") is itself accurate.

`fuzz/driver.cc` marker logic confirmed:
```
$ grep -n "MARK" research/files/h2o/driver.cc
153:#define MARKER "\n--MARK--\n"
156:  char *p = (char *)memmem(buf + pos, len - pos, MARKER, sizeof(MARKER) - 1);
```
— matches the candidate's citation `fuzz/driver.cc:153` exactly.

Fetched a sample corpus file directly from the live repo
(`gh api repos/h2o/h2o/contents/fuzz/http1-corpus/0033e1...`, 6450 bytes) — content is
coverage-minimized fuzzer noise mixing `GET /chunked-test...` fragments with reproxy-URL header
junk and no `--MARK--` delimiter in this particular seed (not every seed splits into multiple
writes) — consistent with "coverage-minimized malformed HTTP/1 requests."

License: `gh api repos/h2o/h2o/contents/LICENSE` → "Copyright (c) 2014 DeNA Co., Ltd." + standard
MIT terms — matches claim exactly.

**One nuance for the synthesis agent**: the candidate's own `layer` field is `"parser"`, and h2o's
HTTP/1 parsing is done by `picohttpparser.c` (bundled in `h2o-src/`), a **different** parser
lineage from llhttp — so despite being parser-layer material, it is *not* redundant with the
llhttp/chez-httparse fixture corpus already in hand; it exercises a differently-generated
coverage-minimized fuzz corpus and (via the `--MARK--` write-splitting convention) can simulate
some multi-write/pipelining scenarios too. No expected outputs ship (this is a fuzzer corpus, not
an oracle), so its correct use is exactly as the candidate describes: crash-freedom assertions and
feeding it into chez-httparse's existing live llhttp differential oracle, not literal server-
behavior verdicts.

---

## 6. `nodejs-smuggling-tests`

**Verdict: NOT refuted. Tier 1 confirmed — this is the most rigorously verifiable candidate in the
batch; every cited CVE checks out against real commit messages.**

Local clone: `corpus-dl/node` (shallow, HEAD `357ba2f676126e2c0e54dca4c47085fce975836b`,
2026-09-19). All 8 claimed `corpus_paths` files exist locally and were cross-verified to exist in
three separate scratchpad locations (`research/files/node/`, `research/node-src/tests/`,
`corpus-dl/node/test/parallel/`) — consistent, not fabricated paths.

License: `corpus-dl/node/LICENSE` opens "Node.js is licensed for use as follows: ... Copyright
Node.js contributors... [MIT text]" — confirms "Core LICENSE is MIT" claim.

CVE mapping verified via `gh api` commit history (the local clone is shallow so I used the GitHub
API directly against `nodejs/node`, not the stale local git log):

```
$ gh api "repos/nodejs/node/commits?path=test/parallel/test-http-transfer-encoding-smuggling.js"
  029703100f  "http: add test for http transfer encoding smuggling"
  d9b71f4c24  "http: stricter Transfer-Encoding and header separator parsing"
  2e92e5b71d  "http: disable chunked encoding when OBS fold is used"
  04e16463d1  "http: do not allow OBS fold in headers by default"

$ gh api repos/nodejs/node/commits/029703100f  -> commit message contains:
  "CVE-ID: CVE-2020-8287"
$ gh api repos/nodejs/node/commits/d9b71f4c24  -> commit message contains:
  "CVE-ID: CVE-2022-32215,CVE-2022-32214,CVE-2022-32212"
$ gh api repos/nodejs/node/commits/2e92e5b71d  -> commit message contains:
  "CVE-ID: CVE-2022-32213, CVE-2022-32215, CVE-2022-35256"
$ gh api repos/nodejs/node/commits/04e16463d1  -> commit message contains:
  "CVE-ID: CVE-2024-27982"
```

This exactly reproduces every CVE the candidate lists for
`test-http-transfer-encoding-smuggling.js`: CVE-2020-8287, CVE-2022-32212/13/14/15,
CVE-2022-35256, CVE-2024-27982 — all present, none fabricated.

```
$ gh api "repos/nodejs/node/commits?path=test/parallel/test-http-transfer-encoding-repeated-chunked.js"
  febb5390aa  "test: remove unnecessary .toString() calls in HTTP tests"
  d9b71f4c24  "http: stricter Transfer-Encoding and header separator parsing"
```
— `d9b71f4c24`'s CVE-ID line (`CVE-2022-32215,CVE-2022-32214,CVE-2022-32212`) matches the
candidate's claim for `repeated-chunked.js` exactly.

Read `test-http-transfer-encoding-smuggling.js` in full: it constructs a raw-socket
(`net.connect`) client, writes a literal `\r\n`-joined byte payload with duplicate/conflicting
`Transfer-Encoding` headers plus a smuggled second request (`GET /flag HTTP/1.1`), asserts the
handler is `common.mustNotCall`'d (never invoked) and the client sees exactly
`'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'` — precisely matching the candidate's
description ("assert server answers 400/closes and handler is never invoked").

File sizes (26–100 lines each) confirm these are small, easily-portable fixtures. There are in
fact more related node smuggling/chunked/content-length test files in `test/parallel/` than the 8
listed (16 total, including an HTTP/2 one the candidate correctly excluded) — consistent with the
"~14 files" hedge in `approx_cases`, which apparently refers to the broader related-file count
rather than exactly the 8 in `corpus_paths`; not an error, just a loosely worded field.

**Assessment**: no defects found. This is real, server-side, directly-portable byte-level
smuggling regression material with a verifiable CVE trail, exactly matching our lens
(smuggling, framing precedence, TE/CL conflicts). Tier 1 fully justified.

---

## Summary table

| key | finder's tier | my verdict | corrected tier | headline issue |
|---|---|---|---|---|
| warp-run-and-connection-specs | 2 | not refuted | — | minor count slips (6 vs 7 testClose; ResponseSpec.hs uncounted); otherwise solid |
| aiohttp-parser-and-web-protocol-tests | 3 | not refuted | — | counts exact; the 10 functional tests are more directly usable byte fixtures than "reference only" implies |
| cpython-httpservers-httplib-tests | 3 | not refuted | — | counts exact; correctly self-scoped as weak/reference |
| aws-http-desync-guardian | 1 | not refuted | 1 (unchanged) | case count is 162, not 668 (verified 3 ways + against live repo); material quality/relevance unaffected |
| h2o-http1-corpus | 1 | not refuted | — | all counts verified exactly against live GitHub tree API; not llhttp-redundant (different parser: picohttpparser) |
| nodejs-smuggling-tests | 1 | not refuted | — | every CVE citation verified against real commit messages; best-verified candidate in the batch |

No candidate in this batch met the "default refute" bar (HTTP/2-only, client-only, or pure
llhttp-duplicate parser material) once actually read. The one substantive correction is the
`aws-http-desync-guardian` case count (668 claimed → 162 actual), which should be corrected in any
downstream synthesis but does not change its tier-1 standing.
