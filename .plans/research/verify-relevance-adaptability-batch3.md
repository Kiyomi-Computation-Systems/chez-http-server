# Skeptic verification — corpus candidates batch 3 (relevance & adaptability lens)

Date of verification: 2026-09-19. All fetches below done live via `curl`/`gh api` against the
URLs/SHAs the finder cited, or the current `HEAD` where a specific SHA was not resolvable, with
diffs noted. Working files saved under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/fetched2/`.

Role: SKEPTIC. Lens: is the candidate HTTP/1.x **server-side or connection-semantics** material
(keep-alive, pipelining, framing precedence, close, upgrade, limits, timeouts, smuggling), or is
it parser-only (redundant with the llhttp corpus already vendored via chez-httparse), client-only,
or HTTP/2-only? Can it become byte streams / scripted sessions we replay? Default `refuted=true`
for HTTP/2-only, client-only, or material redundant with llhttp.

---

## 1. `ats-gold-tests-replay-yaml` — Apache Traffic Server gold_tests + Proxy Verifier

**Verdict: NOT REFUTED. Tier 2 confirmed (no correction).**

Fetched directly:
- `https://raw.githubusercontent.com/apache/trafficserver/master/tests/gold_tests/chunked_encoding/replays/malformed_chunked_header.replay.yaml` (344 lines). Confirms the claimed format exactly: `sessions: - transactions: - client-request: {method, version, url, headers.fields, content: {transfer: plain, encoding: uri, data: <percent-encoded bytes>}}` / `server-response: {status}`. Sample transaction (lines 22–40):
  ```
  client-request: method POST, url /malformed/chunk/header, headers Host/Transfer-Encoding: chunked/uuid
  content.data: z%0D%0Aabcwxyz%0D%0A0%0D%0A%0D%0A   # chunk size "z" is invalid hex
  ```
  This decodes trivially (percent-decode) to a raw byte stream a Scheme test can feed straight into our connection layer.
- Counted request-side vs response-side blocks with `grep -n "client-request:\|server-response:"` (line 22 → 344): **exactly 8 request-side malformed-chunk-header transactions (lines 22–178) followed by exactly 7 response-side ones (lines 186–344)**, each clearly commented `"Now repeat the above two malformed chunk header tests, but on the server side."` at line 182. This matches the finder's "8 request-side + 7 response-side" claim exactly.
  - **Correction to the finder's framing (not a refutation):** the 7 response-side cases test what ATS does when *its own origin/upstream* sends a malformed chunked response — i.e. proxy behavior, not directly applicable to chez-http-server (an origin server, not a reverse proxy). Only the 8 request-side cases (and the analogous request-side cases in the other 11 files in that directory) map onto "what should our server do when a client sends a malformed chunked request." This halves the directly-usable fraction of `malformed_chunked_header.replay.yaml` specifically, though the other files in the directory (`chunked_not_last`, `chunk_trailer_bare_lf`, `chunk_extension_quoted_string`, `chunked_in_http_1_0`, `large_chunked`) are predominantly client→server (request-side) and remain fully relevant.
- `https://raw.githubusercontent.com/apache/trafficserver/master/tests/gold_tests/bad_http_fmt/bad_http_fmt.test.py` (186 lines). Confirms literal `printf '...' | nc localhost $port` raw byte injection for request-line malformation cases (missing space before version, `<` in target, `HTTP/1.2`, `HTTP/0.9`, unknown method, IPv6 target). Counted `grep -c AddTestRun` = 10, `grep -c printf` = 9 → **exactly 9 raw-byte test runs**, matching the finder's "9 raw requests" claim exactly. The non-ATS scaffolding (`Test.MakeATSProcess`, `records_config`, `ip_allow_yaml`, remap config) is indeed not reusable, confirming the finder's "autest scaffolding is not reusable" claim — but the 9 `printf` payload strings themselves lift out mechanically.
- `https://raw.githubusercontent.com/apache/trafficserver/master/tests/gold_tests/chunked_encoding/smuggle-client.c` (128 lines, Apache-2.0 header). Contains a literal classic CL/TE request-smuggling payload:
  `"GET / HTTP/1.1\r\nConnection: close\r\nHost: foo.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 301\r\n\r\n0\r\n\r\nPOST http://sneaky.com/ HTTP/1.1\r\n..."` — directly relevant smuggling-corpus material, trivially extractable (it's a C string literal).
- Directory listing of `tests/gold_tests/chunked_encoding/replays/` via GitHub contents API: 12 files, matching the finder's list exactly (`chunk_extension_quoted_string`, `chunk_trailer_bare_lf`, `chunked`, `chunked_h1_flow_control`, `chunked_h2_flow_control`, `chunked_in_http_1_0`, `chunked_not_last`, `chunked_passthru_flow_control`, `chunked_trailer_dropped`, `chunked_trailer_proxied`, `large_chunked`, `malformed_chunked_header`). Note `chunked_h2_flow_control.replay.yaml` is HTTP/2-only and was correctly *not* included in the finder's `corpus_paths`.

**Repo-wide count check** (the finder's "587 .test.py and 323 replay yaml/json repo-wide" claim), via `GET /repos/apache/trafficserver/git/trees/<sha>?recursive=1` at the finder's own cited commit `f6e6ff94acd1f43bcd3b45ffd83fb5b83cb0b7b9` (confirmed to exist, dated 2026-09-19T00:43:58Z — i.e. today, same-day churn is expected):
```
test.py count under tests/gold_tests/: 587   <- exact match
replay count under tests/gold_tests/ (*.replay.yaml + *.replay.json): 302   <- finder claimed 323
```
Tried broader patterns (`*.replay.yml`, any file under a `replays/` directory) and still topped out at 305/57 respectively — never reached 323. **This is a genuine ~7% overcount in the finder's "approx_cases" repo-wide replay total** (587 vs. 587 is exact; 323 vs. 302 is off). This is a minor factual inaccuracy in an ancillary scale figure, not in the actual corpus_paths list, and doesn't change relevance or adaptability. Noting it as a correction, not a refutation.

**License**: confirmed Apache-2.0 for both `apache/trafficserver` and `yahoo/proxy-verifier` via `gh api repos/.../license` → `spdx_id: Apache-2.0` for both. Matches.

**Proxy Verifier adaptability claim — partially overstated.** Fetched
`https://raw.githubusercontent.com/yahoo/proxy-verifier/master/README.md` (2500 lines).
- Confirmed the `verifier-client run --connect-http 127.0.0.1:PORT --client-cert ... --ca-certs ... <replay_dir>` invocation is real (README lines 2160–2170).
- Confirmed it needs a C++/CMake/OpenSSL 3.5+ build (README "Building from Source", lines 1873–1974) — **but** the README also documents prebuilt statically-linked Linux/Mac binaries under GitHub Releases ("Prebuilt Binaries" section, ~line 1858): "If you do not need your own customized build ... download the proxy-verifier tar.gz ... untar it ... copy the verifier-client and verifier-server binaries." So the finder's "needs a C++/OpenSSL build" is an overstatement of the cost — a prebuilt binary is likely available, lowering the adaptability barrier for approach (b).
- More importantly: pointing `verifier-client` directly at our server (instead of at a real ATS proxy in front of a `verifier-server`) only cleanly validates the *"connection dropped, no response"* class of expectations in these malformed-chunk replay files (which is literally what the YAML comments say: "The connection will be dropped and this response will not go out."). For any replay file where `server-response` contains real expected header/status content (i.e. anything besides the malformed-chunk-header files), `verifier-client` would be checking our response against content authored to match ATS's specific behavior, which will generally not match our server's output — so it would NOT "just work" as a general verification tool against our server without rewriting every `server-response` block. This nuance is missing from the finder's adaptability note but doesn't invalidate use of the **YAML files as raw data** (decode `content.data`, feed as bytes, assert connection is closed) independent of the Proxy Verifier tool itself.

**Effort estimate**: ~6–8 hours to write a percent-decode/YAML extractor for the ~20 relevant request-side transactions across the 6 most relevant replay files + hand-lift the 9 `bad_http_fmt` printf payloads + the smuggle-client.c literal, producing a Scheme fixture table. Using Proxy Verifier itself (vs. just its data) is a separate, larger effort (build or fetch prebuilt binary, author replay files with OUR expected responses) — call it +4–6 hours if pursued, and not required for value.

---

## 2. `envoy-http1-codec-tests` — Envoy `codec_impl_test.cc`

**Verdict: NOT REFUTED. Tier 3 confirmed (no correction).**

Fetched `https://raw.githubusercontent.com/envoyproxy/envoy/main/test/common/http/http1/codec_impl_test.cc` (5435 lines — matches finder's line count exactly).
- `grep -c "^TEST_F(Http1ServerConnectionImplTest"` = **153**, `grep -c "^TEST_F(Http1ClientConnectionImplTest"` = **86**. Sum = 239. All three numbers match the finder's claim exactly.
- Sampled `HostWithLWS` (line 834) and `InnerLWSIsPreserved` (line 855): confirmed the claimed shape — literal `"GET / HTTP/1.1\r\nHost: host \r\n\r\n"` style payloads fed via `sendAndValidateRequestAndSendResponse(...)` against a `TestRequestHeaderMapImpl` expected-header map. This is genuinely close to a clean (request-bytes → expected-headers) fixture and confirms the "sans-I/O... hand-extract into fixtures" adaptability claim for well-chosen cases.
- Fetched the fuzz corpus directory (`GET /repos/envoyproxy/envoy/contents/test/common/http/http1/http1_connection_corpus?ref=main`): **exactly 72 files**, matching the claim. Downloaded 3 samples (`case000`, `case010`, `case030`) and hex-dumped them: all three share an obviously templated tail (`transfer-encoding: deflate\r\ngrpc-timeout: empty\r\n...-force-trace: empty\r\nearly-data: empty\r\n:scheme: https\r\n-original-p...`), with only the request line varying (`GET / HTTP/1.0`, `HEAD / HTTP/1.1`, even a nonsensical `PUT / HTTP/3`). This directly confirms the finder's "low diversity: one template" and "nearly worthless as a corpus" characterization — verified by inspection, not just asserted.
- Fetched `balsa_parser_test.cc` (166 lines): `grep -c "^TEST("` = **8**, matching "8 balsa token tests" exactly.
- License: Apache-2.0 (Envoy repo standard), compatible.

**This is genuine server-side connection-semantics material** (chunked-body-across-dispatches, invalid chunk header, Host LWS/inner-LWS preservation, stream-error-vs-connection-error policy, HTTP/1.0, CONNECT without authority, absolute-form URLs, upgrade) and is not parser-only, client-only, or HTTP/2-only, so it does not hit the default-refute criteria — but the finder's own conservative tier-3 call is justified: most of the value is locked behind Envoy-specific test scaffolding (mock decoders, `codec_settings_.allow_absolute_url_`/`enable_trailers_` toggles) that must be manually re-expressed per case, and only ~20 of 239 tests are worth the effort. Confirmed, no change.

**Effort estimate**: ~4–6 hours to hand-extract the ~20 clean payload+expectation pairs into fixtures (chunked-across-dispatches, invalid-chunk-header, Host LWS, HTTP/1.0 handling, CONNECT-without-authority). The 72-file fuzz corpus is not worth extracting (near-zero marginal value confirmed by inspection).

---

## 3. `curl-tests-data` — curl `tests/data`

**Verdict: REFUTED (correcting the finder, who left it un-refuted at tier 3).**

All of the finder's factual claims check out with unusual precision — I extracted the exact same
tarball (`https://github.com/curl/curl/archive/refs/heads/master.tar.gz`, using the same
tag-at-fetch-time methodology the finder describes) and recomputed every statistic independently:

```
test files (tests/data/test<N>):                2109   <- exact match
files tagged HTTP (grep -l -E '^HTTP$' keywords): 1084  <- exact match
files with a <protocol> section:                 1615  <- exact match
chunked responses (Transfer-Encoding: chunked):     60  <- exact match
swsclose:                                          339  <- exact match
%CR / %LF escapes:                                 114  <- exact match
HTTP/1.0 responses (line-start match):              63  <- finder said 61 (minor, ±2, likely different match regex)
Expect: 100-continue:                               25  <- exact match
```
Also confirmed `docs/tests/FILEFORMAT.md` returns HTTP 200 while `tests/FILEFORMAT.md` returns 404
— matches the finder's specific note about the file's real location. Fetched `test207` in full
and confirmed the exact XML-ish `<testcase><reply><data>...<datacheck>...<client><command>...
<verify><protocol crlf="headers">...<errorcode>` structure described. License: `gh api
repos/curl/curl/license` → `spdx_id: NOASSERTION`, `key: other`, with `LICENSES/curl.txt` present —
matches the finder's note exactly.

Given the extremely high fidelity of the finder's own research here, the refutation is **not**
about facts — it is about applying the task's lens correctly. The instructions are explicit:
*"Default refuted=true for HTTP/2-only, client-only, or material that adds nothing over llhttp."*
`tests/data` is, in aggregate and in the specific candidate framing, a **curl client conformance
suite**: `<verify><protocol>` asserts what curl (the client) sends, and `<reply><data>` is data
that curl (the client) must tolerate or reject. Neither of these tests server behavior:
- The "benign request byte streams from `<protocol>`" angle gives us well-formed, boring requests
  — exactly what our project does **not** need a third-party corpus for (we already have live
  request construction, and llhttp/chez-httparse's 274 fixtures already cover well-formed-request
  parsing at every chunk size). It adds no edge-case coverage.
- The "`<reply><data>` as a check on our response serializer" angle tests whether *curl-the-client*
  accepts *our* output — that's an interop/serializer smoke-check, not a corpus of inputs that
  exercises our server's HTTP/1.x connection-semantics decision points (keep-alive, pipelining,
  framing precedence, close, upgrade, limits, timeouts, smuggling). It is fundamentally the wrong
  direction of data flow for a "requests our server must handle" corpus.
The finder's own write-up concedes this ("Tier 3 for the server: it is a client suite") but stops
short of applying the stated default-refute rule. Applying it here: **refuted=true**. This is a
correction of the verdict, not of the finder's factual work, which was excellent.

---

## 4. `squid-http1-parser-tests` — Squid `testHttp1Parser.cc`

**Verdict: REFUTED (correcting the finder, who left it un-refuted at tier 3).**

Fetched `https://raw.githubusercontent.com/squid-cache/squid/master/src/tests/testHttp1Parser.cc`
(1202 lines — matches). Confirmed:
- `grep -c "CPPUNIT_TEST("` inside the `CPPUNIT_TEST_SUITE` block = **7** (`testParserConstruct`,
  `testDripFeed`, `testParseRequestLineMethods`, `testParseRequestLineProtocols`,
  `testParseRequestLineTerminators`, `testParseRequestLineStrange`,
  `testParseRequestLineInvalid`) — matches "7 CppUnit tests" exactly.
- `grep -c "input.append("` = **41** — matches "41 inputs" exactly.
- License: `gh api repos/squid-cache/squid/license` → `spdx_id: GPL-2.0` — matches, and does block
  vendoring into a project the target repo's AGENTS.md commits to BSD-3-Clause.

The finder's own material is accurate and their own conclusion ("read only as a decision
reference... test-suite/ has no HTTP corpus") is functionally the same as "not usable as a corpus
candidate." Applying the task's stated default: this is **parser-only** ("layer": "parser", as the
finder's own JSON labels it) content — request-line syntax/version-tolerance/CR-LF handling and
byte-at-a-time incremental parsing — that is **squarely redundant with the llhttp corpus chez-httparse
already vendors and passes at every chunk size** (per the PROJECT CONTEXT: 274 llhttp fixtures at
every chunk size, plus a live differential — Squid's drip-feed test is the same idea, already
covered). Combined with the GPL-2.0 license blocking actual reuse of the test data/strings, this
candidate meets *two* of the three explicit default-refute criteria ("parser-only... redundant
with the llhttp corpus" and, separately, a hard license block on adaptability). **refuted=true.**
Corrected reasoning, not corrected facts — the finder's tier-3 rating undersold how little this
adds once you accept it can only ever be a design reference, never actual corpus material.

---

## 5. `cowboy-rfc7230-rfc7231-suites` — Cowboy conformance suites

**Verdict: NOT REFUTED. Tier 1 confirmed (no correction) — the strongest candidate in this batch.**

Fetched all six cited files directly and recomputed test-function counts by counting
`^[a-z][a-zA-Z0-9_]*(Config) ->` top-level clauses (the common_test case-function convention this
suite uses):
```
rfc7230_SUITE.erl:    2438 lines, 155 test cases   <- exact match ("rfc7230 155")
rfc7231_SUITE.erl:     949 lines,  74 test cases   <- exact match ("rfc7231 74")
http_SUITE.erl:       1367 lines,  50 test cases   <- exact match ("http_SUITE 50")
req_SUITE.erl:        1496 lines, 101 test cases   <- exact match ("req_SUITE 101")
security_SUITE.erl:    438 lines,  18 test cases   <- exact match ("security 18")
rfc6585_SUITE.erl:      78 lines,   4 test cases   <- exact match ("rfc6585 4")
```
License: `gh api repos/ninenines/cowboy/license` → `spdx_id: ISC` — matches, and ISC is a
permissive license fully compatible with vendoring into a BSD-3-Clause project.

Spot-checked the finder's specific line citation (`rfc7230_SUITE.erl:1009-1032`): fetched lines
1005–1035 and found `reject_duplicate_content_length_header/1` starting at **line 1009** exactly,
containing exactly the format the finder described:
```erlang
reject_duplicate_content_length_header(Config) ->
    doc("Requests with duplicate content-length headers must be rejected "
        "with a 400 status code and the closing of the connection. (RFC7230 3.3.2)"),
    #{code := 400, client := Client} = do_raw(Config, [
        "POST / HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Content-length: 12\r\n"
        "Content-length: 12\r\n"
        "\r\n"
        "Hello world!"]),
    {error, closed} = raw_recv(Client, 0, 1000).
```
This is genuinely mechanical to extract: RFC citation in `doc()`, literal request bytes in
`do_raw`, expected status/header map, and expected close-vs-timeout behavior via `raw_recv`.

Verified the `cowboy_test.erl` raw-socket helper API the finder cited (`raw_open`/`raw_send`/
`raw_recv_head`/`raw_recv_rest`/`raw_recv`) at lines 198–235 (finder cited 198–231, off by a few
lines but functionally the same block — confirmed present and matching described semantics:
`gen_tcp`/`ssl` raw connect, blocking send/recv with an explicit 10000ms timeout, head/body-length
split on `\r\n\r\n`).

One correction: the finder's cited file-history SHA `c965d1a` does not match this file's most
recent commit as of my fetch (`447edc0c...`, dated 2026-07-27); `c965d1a3bffa0708b0570e83233ddd3bf77b97c1`
does exist as a real repo commit (dated 2026-09-16, "Remove unnecessary section in AGENTS.md") but
touches a different file. This looks like the finder cited a repo-HEAD SHA rather than a
file-specific commit SHA — a labeling slip, not a factual problem with the corpus content itself,
which I independently reproduced in full. Given active development (tag `2.19.0` and the file
itself confirmed present and ISC-licensed both now and at every SHA checked), this doesn't affect
the verdict.

This is exactly the "server raw bytes in, status/headers/socket-state out" shape the target project
needs, covers connection-semantics precisely per the task's lens (keep-alive/close, pipelining,
Content-Length/Transfer-Encoding precedence, duplicate-header rejection, chunk validity, timeouts,
Expect: 100-continue, HEAD/204/304 framing) and is licensed for reuse. **Tier 1 stands.**

**Effort estimate**: ~1 day (matches finder's own estimate), given the doc()/do_raw/match/raw_recv
quadruple is close to a fixed grammar across all ~155+74+50+18+4 ≈ 300 non-timing cases; timing-
sensitive cases (slowloris, idle/request timeouts) need a slower, harness-specific adaptation pass
and should be budgeted separately (+3–4 hours).

---

## 6. `kestrel-http1-parsing-data-and-inmemory-tests` — ASP.NET Core Kestrel

**Verdict: NOT REFUTED. Tier 1 (HttpParsingData.cs) / Tier 2 (InMemory.FunctionalTests) confirmed
as the finder split them — no correction.**

Fetched `https://raw.githubusercontent.com/dotnet/aspnetcore/main/src/Servers/Kestrel/shared/test/HttpParsingData.cs`
(554 lines). License: `gh api repos/dotnet/aspnetcore/license` → `spdx_id: MIT` — matches, fully
compatible with vendoring.
- `RequestLineInvalidData` (lines 142–242): counted 90 literal quoted-string entries via
  `grep -c '^\s*"'` over that range → **exactly 90**, matching "90 invalid request lines" exactly.
- `RequestHeaderInvalidData`'s embedded `invalidHostValues` array: counted exactly **9** literal
  strings (`""`, `"   "`, `"contoso.com:4000"`, `"contoso.com/"`, `"not-contoso.com"`,
  `"user@password:contoso.com"`, `"user@contoso.com"`, `"http://contoso.com/"`,
  `"http://contoso.com"`), matching the finder's "9 invalid host" figure exactly (the finder's
  count method — counting literal source strings, not the Cartesian-product-expanded row count —
  is the right read here and is honestly disclosed in their own note about `TargetInvalidData`
  reporting 0 for the same reason).
- Confirmed the cited SHA `1fcd7ef305697a1888f3ede076010350ae9f4f8d` is a real, very recent commit
  (dated 2026-09-18T21:54:03Z, i.e. the day before "today" in the project's stated measurement
  window) — consistent with a live, accurate snapshot.

Fetched two InMemory.FunctionalTests files to check the "Send/Receive/ReceiveEnd script" format
claim and spot-check counts:
- `ChunkedRequestTests.cs` (1368 lines): `grep -c '\[Fact\]\|\[Theory\]'` = **22**, matching exactly.
  Confirmed the literal format:
  ```csharp
  await connection.Send("POST / HTTP/1.1", "Host:", "Transfer-Encoding: chunked", ...);
  await connection.ReceiveEnd("HTTP/1.1 400 Bad Request", "Content-Length: 0", "Connection: close", ...);
  ```
  with `[InlineData("2;\rxx\r\nxy\r\n0")]`-style raw chunk-extension payloads (CR/LF/space/multiple
  `;` in chunk extensions) — directly maps onto a (send-bytes, expect-bytes-or-close) fixture.
- `BadHttpRequestTests.cs` (625 lines): `[Fact]/[Theory]` count = **20**, `[InlineData` count =
  **28** — both match the finder's "20 (28 InlineData)" exactly.
- `KeepAliveTimeoutTests.cs`: `[Fact]/[Theory]` count = **6** — matches exactly.

Every specific count I checked across this candidate (5 independent spot-checks) matched the
finder's claim exactly. This is genuine, directly-relevant server connection-semantics material
(request-line/header syntax verdicts, Host validation, CL vs. TE precedence, chunked body framing
incl. malformed chunk extensions, keep-alive defaults, timeouts, limits, upgrade framing) in a
license (MIT) that permits reuse, and in a format ("send these bytes, expect this response or this
close behavior") that maps almost directly onto a sans-I/O connection-layer replay driver. **Tier 1
/ Tier 2 split as rated, no correction.**

**Effort estimate**: ~3–4 hours to mechanically extract `HttpParsingData.cs`'s ~280 rows
(un-escaping C#'s `\r\n`/`\0`/Latin-1 literals) into a Scheme table (Tier 1 portion). ~10–12 hours
to adapt the ~150+ most relevant InMemory.FunctionalTests cases (chunked, bad-request, keep-alive/
header/body timeouts, request/header/body size limits, upgrade) into our own replay-script driver,
since each C# test's inline assertion lambda must be re-expressed by hand even though the
send/receive byte sequences lift out mechanically (Tier 2 portion, matches finder's own
characterization of "semi-mechanical, adapt later").

---

## Summary table

| key | finder tier | my verdict | corrected tier | basis |
|---|---|---|---|---|
| ats-gold-tests-replay-yaml | 2 | not refuted | — | request-side chunked/bad-http-fmt/smuggling data verified byte-for-byte; response-side half of malformed_chunked_header is proxy-specific (noted, doesn't change tier); repo-wide replay count off by ~7% (302 actual vs 323 claimed) |
| envoy-http1-codec-tests | 3 | not refuted | — | 239 TEST_F, 72-seed fuzz corpus (confirmed near-worthless by inspection), 8 balsa tests — all exact matches; genuinely connection-semantics but low extraction yield, as finder already conceded |
| curl-tests-data | 3 (not refuted) | **refuted** | — | every statistic independently reproduced exactly; but material is fundamentally client-conformance data (what curl sends / what curl must tolerate), which the task's lens defaults to refuting regardless of tier |
| squid-http1-parser-tests | 3 (not refuted) | **refuted** | — | parser-only, redundant with the llhttp/chez-httparse incremental-parse coverage already in hand, and GPL-2.0 blocks any actual vendoring — two independent default-refute triggers |
| cowboy-rfc7230-rfc7231-suites | 1 | not refuted | — | every count across 6 files matched exactly; cited line range and helper API verified byte-for-byte; ISC license; best-fit format for the target project |
| kestrel-http1-parsing-data-and-inmemory-tests | 1 (data) / 2 (InMemory) | not refuted | — | every count across HttpParsingData.cs + 3 InMemory test files matched exactly; MIT license; format is directly replay-able |

## Files/commands used for verification

All raw files fetched with `curl -s <raw.githubusercontent.com URL> -o <file>` and inspected with
`wc -l`/`grep -c`/`sed -n`; license checks with `gh api repos/<owner>/<repo>/license`; repo-wide
tree counts with `gh api`-style `GET /repos/<owner>/<repo>/git/trees/<sha>?recursive=1` piped
through a small Python filter; curl's own full test corpus was verified by downloading
`https://github.com/curl/curl/archive/refs/heads/master.tar.gz` and extracting `tests/data/` with
`bsdtar` (GNU-tar `--wildcards` is not supported by the macOS-shipped `bsdtar`; the working
invocation was `tar xzf curl-master.tar.gz -C curl-extract 'curl-master/tests/data/*'`). All
working files are under `fetched2/` in this directory; nothing was written to any git repository.
