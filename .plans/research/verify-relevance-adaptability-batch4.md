# Skeptic verification — batch 4 (relevance & adaptability)

Lens: is each candidate genuinely HTTP/1.x **server-side / connection-semantics** material
(keep-alive, pipelining, framing precedence, close, upgrade, limits, timeouts, smuggling), as
opposed to parser-only (redundant with the already-vendored llhttp corpus), client-only, or
HTTP/2-only? Can it be turned into byte streams / scripted client sessions chez-http-server can
replay? All six candidates were checked against either files already cached in this scratchpad
from earlier research passes (`go-src/`, `hyper-src/`, `research/node-src/tests/`,
`research/*.tsv`) or freshly fetched via `curl`/`gh api` into `scratchpad/verify-b4/`.

Verdict summary: **none of the six candidates is refuted.** All are confirmed as real,
current-ish, server-side HTTP/1.x connection-semantics material, with specific line-number and
quote citations from the finder's report verified against actual file content in nearly every
case I checked. Where I found the finder's *case-count* estimates to be off (sometimes
overstated, sometimes understated), I note it below — it affects the effort estimate, not the
relevance verdict, and in no case did I find the case-count error large enough to flip a tier.

---

## 1. go-net-http-server-tests — NOT REFUTED, tier unchanged (1 for tables / 2 for whole file)

Source used: locally cached `scratchpad/go-src/net/http/*.go` (fetched by an earlier agent from
`golang/go` master, `GO_VERSION=go1.27.1`, i.e. a **later** snapshot than the candidate's cited
SHA `46f508b`; some drift vs. the finder's line numbers/counts is expected and observed).

- `readrequest_test.go`: `var reqTests = []reqTest{` at line 30 (not 18 as claimed — off by 12
  lines, expected drift). Counted top-level `\t{` entries in the `reqTests` slice
  (`awk 'NR==30,NR==419'... | grep -cE '^\t\{$'`) → **16**, exact match to the claim
  ("reqTests 16 rows").
  `var badRequestTests` at line 459 (claim: "455-483", close). Printed the full block
  (`sed -n '459,491p'`) → exactly 5 entries: `bad_connect_host`,
  `smuggle_two_contentlen`, `smuggle_two_content_len_head`, `leading_space_in_header`,
  `leading_tab_in_header` — **exact match** to claim ("badRequestTests 5 rows", content
  "duplicate Content-Length, leading space/tab in header, bad CONNECT host"). This table is
  genuinely (c)-shaped (raw bytes → parse verdict) and genuinely server-relevant (smuggling via
  duplicate Content-Length is exactly the framing-precedence class of bug chez-http-server needs
  to guard against).
- `serve_test.go` (local copy 231388 bytes vs. tsv-recorded 243605 bytes — different fetch
  passes, expected): `grep -c "^func Test"` → **173** top-level Test funcs, not the claimed 280;
  `grep -c "net\.Dial\|Dial("` → **39**, not the claimed 79. This is a real overcount by the
  finder (roughly 1.6–2x), likely from counting subtests (`t.Run`) or a much larger historical
  revision of the file. However every *specific* table the finder named was verified present and
  accurate:
  - `TestServerValidatesHostHeader` at line 5271 (claim: 5271 area — exact), table starts
    immediately after with rows like `{"HTTP/0.9", "", 505}`, `{"HTTP/1.1", "", 400}`.
  - `TestServerValidatesHeaders` at line 5385 (claim: 5385 — exact).
  - `serverExpectTests` var at line 2136, used at line 2259 (claim: 2180/2259 area — close).
  - `TestInvalidChunkedBodies` at line 7840 (claim: 7868 — close).
  So the *qualitative* content claims hold; the *quantitative* "~100 relevant rows, 1 hour" /
  "~40 named cases, 1-2 days" adaptability estimate in the original report is still a reasonable
  order-of-magnitude even with the func-count correction, since the named tables (the actual
  extraction targets) all check out.
- `clientserver_test.go`: local copy has **50** `func Test` (not 76 as claimed — another
  overcount, ~35%). Confirmed this file mixes true HTTP/1-relevant framing tests
  (`TestH12_HeadContentLengthNoBody` etc., run against both h1 and h2 via a shared harness) with
  HTTP/2-only variants (`TestH2_204NoBody`, `TestH2_304NoBody`, `TestH2_404NoBody`) — so a
  fraction of this specific file's cases (though not the file as a whole) are h2-only and must be
  filtered during extraction, exactly as the finder's tier-2 "manual translation, pick relevant
  cases" framing already implies.
- License: BSD-3-Clause + PATENTS, as claimed (well-established, not independently re-verified
  this pass).

**Correction:** case-count claims for `serve_test.go` (280 funcs / 79 raw-dial usages) and
`clientserver_test.go` (76 funcs) are overstated by roughly 1.4–2x against the currently-fetched
snapshot. This does not change relevance or tier — the specific tables cited (reqTests,
badRequestTests, TestServerValidatesHeaders, TestServerValidatesHostHeader, serverExpectTests,
TestInvalidChunkedBodies) are all real, accurately cited, and squarely on-lens (framing
precedence, header/Host validation, Expect handling, chunked-body errors). Tier stands as given:
1 for the pure-data tables, 2 for `serve_test.go`/`clientserver_test.go` as wholes.

---

## 2. hyper-server-and-h1-tests — NOT REFUTED, tier unchanged (2)

Source used: locally cached `scratchpad/hyper-src/{tests_server.rs.testnames.txt,
src_proto_h1_conn.rs, src_proto_h1_decode.rs, src_proto_h1_io.rs, src_proto_h1_dispatch.rs,
src_proto_h1_encode.rs, src_proto_h1_role.rs}` from an earlier fetch of hyperium/hyper at the
candidate's cited SHA `e89d0d93d9566210ee95aea234a00952ebc4a202`.

- `tests_server.rs.testnames.txt` has **94** entries (claim: 96, close). Of these, only
  **18** are HTTP/2-labeled (`http2_*`, `h2_connect*`), leaving **76** genuinely HTTP/1 tests —
  *more* than the finder's own "~60 HTTP/1, rest h2" estimate, i.e. the finder actually
  **understated** the HTTP/1 relevance of this file rather than overstating it. This strengthens
  rather than weakens the candidate.
- `src/proto/h1/conn.rs`: confirmed `fn conn_accepts_eof_when_idle()` (line 1337) and
  `fn conn_rejects_eof_during_partial_head()` (line 1346) exist exactly as described — this is
  real, specific EOF-during-partial-head vs. EOF-while-idle framing logic directly applicable to
  the libuv `on-eof` callback / read-stop decisions in chez-http-server. 11 test functions total
  (claim: 12, close).
- `decode.rs`: initial `grep -c "#\[test\]"` only found 2 (undercounting because most tests are
  `#[tokio::test] async fn test_...`, not the plain `#[test]` attribute); re-counting by
  `fn test_...` name found **19** distinct test functions
  (`test_read_chunk_size`, `test_read_sized_early_eof`, `test_read_chunked_early_eof`,
  `test_read_chunked_with_missing_zero_digit`, `test_read_chunked_extensions_over_limit`,
  `test_read_chunked_trailer_with_missing_lf`, `test_read_chunked_after_eof`,
  `test_decode_trailers`, `test_trailer_max_headers_enforced`, etc.) — **exact match** to the
  claim ("decode.rs 19"). Good confirmation of chunked-decoder edge cases (missing final digit,
  extension-length limits, trailer-size limits) that are directly useful for chez-http-server's
  own chunked-body framing.
- `io.rs`: 12 test fns found (claim: 14, close). `dispatch.rs`: 4 (claim: 4, exact).
  `encode.rs`: 10 (claim: 11, close).
- License: MIT, as claimed.

**No correction.** All specific technical claims (EOF states, decode.rs edge cases, h1/h2 test
split) check out or are actually more favorable to the candidate than stated. Adaptability
assessment (manual port of tests/server.rs cases via a Scheme handler stub; conn.rs EOF cases as
a spec for the libuv on-eof layer) is sound and matches chez-libuv's actual on-eof/read-stop
semantics described in the project brief.

---

## 3. bandit-http1-protocol-tests — NOT REFUTED, tier unchanged (2, "borderline tier 1" affirmed)

Source: freshly fetched `https://raw.githubusercontent.com/mtrudel/bandit/main/test/bandit/http1/protocol_test.exs`.
`gh api repos/mtrudel/bandit/commits/main --jq '.sha'` → `22dade4353ee7b3635975d0d3670c85ab30b0dd4`,
**exactly** the SHA the finder cited — this candidate's citations are pinned to a commit that is
still `main`'s HEAD, the strongest possible confirmation available.

- File is 3142 lines. `grep -c "^  describe "` → **22** (claim: 23, off by one).
  `grep -c "    test "` → **189** — **exact match** to the claim.
  `grep -n "^  describe "` reproduced all 22 describe-block headers, and every one carries an
  explicit RFC 9112/9110 section label exactly as quoted in the candidate, e.g.:
  - `describe "content-length request bodies (RFC9112§6.2, §6.3)"` (line 640)
  - `describe "chunked request bodies (RFC9112§7.1)"` (line 1311)
  - `describe "upgrade handling (RFC9110§7.8, RFC6455)"` (line 2510)
  - `describe "connection persistence / keepalive (RFC9112§9.3)"` (line 2848)
- Printed lines 2848–2900 verbatim and it matches the candidate's citation exactly: tests named
  `"silently exits if client closes during keepalive"`,
  `"closes the connection by default for HTTP/1.0 requests with no connection header"`,
  `"closes the connection when an HTTP/1.1 client explicitly requests it"`,
  `"closes the connection when an HTTP/1.1 client requests it via a comma-separated list"`,
  `"handles pipeline requests"` — all genuine connection-semantics tests, all driven over a raw
  `SimpleHTTP1Client.tcp_client`/`send`/`recv_reply` TCP harness exactly as described, i.e.
  directly (a)/(b)-shaped: bytes out, bytes/close-state in.
- License: MIT (well-known; not independently re-verified this pass, matches candidate claim).

**No correction.** This is the most precisely-cited candidate in the batch — every quantitative
and qualitative claim checked came back exact or within one unit. It is squarely server-side
connection semantics (not parser-only — llhttp has no notion of "does the server keep the
connection open," "does it drain an unread body before the next pipelined request," etc.), not
client-only, not HTTP/2 (Bandit's HTTP/1 test suite is HTTP/1-only by construction). Tier 2
(manual-but-regular client-harness translation) is the right call; I see no basis to force it to
tier 1 given a Scheme equivalent of `SimpleHTTP1Client` still needs to be written before any case
can be replayed.

---

## 4. netty-codec-http-tests — NOT REFUTED, tier unchanged (2)

Source: freshly fetched from `https://raw.githubusercontent.com/netty/netty/4.2/codec-http/src/test/java/io/netty/handler/codec/http/*.java`.
`gh api repos/netty/netty/commits/4.2 --jq '.sha'` → `8af38d14870e6c0d009c348cadbe6d8df87f2d7d`
(branch has moved past the candidate's cited `b3231b3`, expected drift — branch tests are stable
in structure even as the branch advances).

- `HttpRequestDecoderTest.java`: confirmed the exact fragmentation-loop pattern the candidate
  describes — `private static void testDecodeWholeRequestInMultipleSteps(byte[] content, ...)`
  contains `for (int i = 1; i < content.length; i++) { testDecodeWholeRequestInMultipleSteps(content, i, ...); }`,
  i.e. **every** request byte-split point from 1 to `content.length-1` is exercised, exactly as
  claimed ("loops fragment size 1..len"). `@Test` count 73 + `@ParameterizedTest` count 5 =
  **78**, an **exact match** to the claim ("HttpRequestDecoderTest 78"). Confirmed
  `EmbeddedChannel`/`Unpooled.copiedBuffer` usage, i.e. genuinely sans-I/O (c)-shaped: byte array
  in, decoded `HttpRequest`/`HttpContent`/`LastHttpContent` (with `decoderResult()` failure state)
  out.
- `HttpObjectAggregatorTest.java`: 26 `@Test` — **exact match** to claim ("26").
- `HttpServerCodecTest.java`: 15 `@Test` — **exact match** to claim ("15").
- `HttpServerKeepAliveHandlerTest.java`: 1 `@Test` + 4 `@ParameterizedTest` = 5 total —
  matches the claimed total ("5") though the claim's "(2 parameterized)" undercounts the
  parameterized-method count (4 methods, not 2 — likely the finder counted parameterized
  *test-invocation groups* rather than methods; immaterial to relevance/tier).
- `LICENSE.txt` fetched: 202 lines, standard Apache-2.0 text; `NOTICE.txt` returns HTTP 200 —
  confirms the candidate's Apache-2.0 + NOTICE-carry-forward warning is accurate and actionable.

**No correction.** This candidate's quantitative claims were the most exactly verified of the
whole batch (78/78, 26/26, 15/15 exact matches on three separate files). The
`EmbeddedChannel`-driven, sans-I/O format is a strong match for a parser+connection-layer
differential harness. Genuinely connection-level (not parser-only): `HttpServerCodecTest`,
`HttpObjectAggregatorTest`, and `HttpServerKeepAliveHandlerTest` all encode decisions llhttp
itself does not make (keep-alive verdict given TE+CL conflicts, oversized-body → 413 with/without
keep-alive, "both TE and CL → close after response" precedence). Tier 2 stands — no plain byte
tables here, translation of Java assertions against decoded objects is real work.

---

## 5. nodejs-test-http-server-tests — NOT REFUTED, tier unchanged (2)

Source: locally cached `scratchpad/research/node-src/tests/*.js` (81 files fetched by an earlier
pass) plus `scratchpad/research/node-raw-socket-server-tests.txt` (the finder's own list of the
55 server-side raw-socket files), cross-checked against a fresh GitHub tree listing and two fresh
file fetches.

- `gh api "repos/nodejs/node/git/trees/main?recursive=1"` filtered to
  `^test/parallel/test-http-.*\.js$` → **407** files (claim: 413, ~1.5% drift, expected — the
  tree moves daily). Filtered to `^test/sequential/test-http-.*\.js$` → **7** files, an **exact
  match** to the claim's "+7 in test/sequential", and the actual filenames
  (`test-http-econnrefused.js`, `test-http-keep-alive-large-write.js`,
  `test-http-keepalive-maxsockets.js`, `test-http-regr-gh-2928.js`,
  `test-http-server-keep-alive-timeout-slow-client-headers.js`,
  `test-http-server-keep-alive-timeout-slow-server.js`,
  `test-http-server-request-timeouts-mixed.js`) are all genuinely server-timeout/keep-alive
  material, on-lens.
- `node-raw-socket-server-tests.txt` has exactly **55** lines — exact match to the claim's "55
  raw-socket server-side" count.
- Spot-fetched two files directly from `raw.githubusercontent.com/nodejs/node/main/test/parallel/`:
  - `test-http-pipeline-flood.js`: confirmed `http.createServer(function(req,res){...})` at
    line 31 and `net.connect({port})` at line 69 — genuine server-side raw-socket backpressure
    test, matching the claim's "pipeline flood backpressure (read cork on write buffer full)".
  - `test-http-transfer-encoding-smuggling.js`: confirmed a literal raw request with duplicate
    `Transfer-Encoding: chunked` / `Transfer-Encoding: chunked-false` headers plus a smuggled
    second request (`GET /flag HTTP/1.1`) in the chunked body, driven at
    `http.createServer(common.mustNotCall(...))` + `net.connect(...)` — this is a textbook
    HTTP request-smuggling regression test, exactly the class of case the task brief flags as
    high-value (framing-precedence / smuggling).
- License: MIT for the Node.js-authored test files (per candidate's own caveat about the
  aggregate repo LICENSE being NOASSERTION due to bundled dependency licenses — accurate, not
  independently re-litigated here).

**No correction.** Every specific number and every specific file I checked came back accurate.
This is clearly the largest and most smuggling/timeout-focused of the six corpora, and its
raw-socket subset is unambiguously server-side and connection-level, not parser-only (Node's own
parser tests, correctly flagged by the finder as llhttp-redundant, are a disjoint, smaller set of
~11 files the finder explicitly excludes from the "relevant" count).

---

## 6. puma-server-protocol-tests — NOT REFUTED, tier unchanged (2)

Source: freshly fetched all 8 candidate files from
`https://raw.githubusercontent.com/puma/puma/main/test/*.rb`.
`gh api repos/puma/puma/commits/main --jq '.sha'` → `306daddfd07fdf0ca902eb7ea89ceb7dd6139050`
— an **exact match** to the candidate's cited SHA, i.e. `main` has not moved since the finder's
research; this is the single most precisely time-stamped candidate in the batch.

Test-method counts (`grep -c "^  def test_"`), all against freshly fetched files:

| file | counted | claimed |
|---|---|---|
| test_puma_server.rb | 134 | 134 (exact) |
| test_persistent.rb | 17 | 17 (exact) |
| test_request_invalid_multiple.rb | 6 | 6 (exact) |
| test_request_single.rb | 71 | 71 (exact) |
| test_http11.rb | 14 | 14 (exact) |
| test_http10.rb | 1 | 1 (exact) |
| test_response_header.rb | 14 | 14 (exact) |
| test_puma_server_hijack.rb | 6 | 6 (exact) |

Every single count is an **exact match**. This is the strongest quantitative confirmation in the
whole batch.

- Confirmed `test_http11.rb` genuinely drives Puma's own bundled Ragel-generated parser
  (`require "puma/puma_http11"`; `Puma::HttpParser.new`; `parser.execute(req, http, 0)`) — the
  candidate's own note that this file "duplicates llhttp coverage" and should be treated as
  parser-only (lower priority) is accurate and correctly self-flagged by the finder, not a flaw
  to refute on.
- Confirmed the "13 chunked-request pause positions" claim in `test_puma_server.rb`: grepped
  `def test_chunked_.*pause|def test_chunked_body_pause` → **11** matches
  (`test_chunked_request_pause_before_value` line 1044,
  `test_chunked_request_pause_between_chunks` 1065, `..._pause_mid_count` 1086,
  `..._pause_before_count_newline` 1107, `..._pause_mid_value` 1128,
  `..._pause_between_cr_lf_after_size_of_second_chunk` 1149,
  `..._pause_between_closing_cr_lf` 1179, `..._pause_before_closing_cr_lf` 1201,
  `..._pause_after_last_chunk_1` 1223, `..._pause_after_last_chunk_2` 1243,
  `test_chunked_body_pause_within_chunk_size_hex` 1268) — a minor undercount by the finder
  (claimed 13, found 11), immaterial to relevance: this is exactly the split-point series the
  candidate's own adaptability note recommends as "a ready list of framing-boundary split points
  for the (c) driver," and it is verifiably real and byte-stream-replayable (each test sends a
  partial chunk, sleeps, then sends the rest via a raw socket helper).
- Printed the `test_chunked_request_pause_before_value` body (lines 1044–1063): raw `send_http`
  call with literal `"GET / HTTP/1.1\r\nHost: test.com\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n"`
  followed by a delayed `socket << "h\r\n4\r\nello\r\n0\r\n\r\n"` — confirms this is genuinely
  (a)/(c)-shaped byte-stream-with-a-pause material, directly portable to a chez-libuv test that
  writes partial chunks with a delay between `uv-write!` calls.
- License: BSD-3-Clause, as claimed (well-known; not independently re-verified this pass).

**No correction.** All file-level case counts matched exactly; the one sub-count that didn't
(pause-test series, 11 vs. 13) doesn't change the value of the material. Tier 2 stands — this is
manual-but-regular Ruby-heredoc translation work, same class of effort as hyper/netty/node/bandit.

---

## Commands / URLs relied on (for traceability)

- `gh api repos/netty/netty/commits/4.2 --jq '.sha'` → `8af38d14870e6c0d009c348cadbe6d8df87f2d7d`
- `curl -sL https://raw.githubusercontent.com/netty/netty/4.2/codec-http/src/test/java/io/netty/handler/codec/http/HttpRequestDecoderTest.java`
- `curl -sL https://raw.githubusercontent.com/netty/netty/4.2/codec-http/src/test/java/io/netty/handler/codec/http/HttpServerKeepAliveHandlerTest.java`
- `curl -sL https://raw.githubusercontent.com/netty/netty/4.2/codec-http/src/test/java/io/netty/handler/codec/http/HttpObjectAggregatorTest.java`
- `curl -sL https://raw.githubusercontent.com/netty/netty/4.2/codec-http/src/test/java/io/netty/handler/codec/http/HttpServerCodecTest.java`
- `curl -sL https://raw.githubusercontent.com/netty/netty/4.2/LICENSE.txt`
- `gh api repos/mtrudel/bandit/commits/main --jq '.sha'` → `22dade4353ee7b3635975d0d3670c85ab30b0dd4`
- `curl -sL https://raw.githubusercontent.com/mtrudel/bandit/main/test/bandit/http1/protocol_test.exs`
- `gh api repos/puma/puma/commits/main --jq '.sha'` → `306daddfd07fdf0ca902eb7ea89ceb7dd6139050`
- `curl -sL https://raw.githubusercontent.com/puma/puma/main/test/{test_puma_server.rb,test_persistent.rb,test_request_invalid_multiple.rb,test_request_single.rb,test_http11.rb,test_http10.rb,test_response_header.rb,test_puma_server_hijack.rb}`
- `gh api "repos/nodejs/node/git/trees/main?recursive=1" --paginate --jq '.tree[]...'`
- `curl -sL https://raw.githubusercontent.com/nodejs/node/main/test/parallel/test-http-pipeline-flood.js`
- `curl -sL https://raw.githubusercontent.com/nodejs/node/main/test/parallel/test-http-transfer-encoding-smuggling.js`
- Local, previously-cached-in-this-scratchpad files used as primary evidence (from earlier
  research passes in this same session/scratchpad, verified still on disk and re-read fresh this
  pass):
  - `scratchpad/go-src/net/http/readrequest_test.go` (GO_VERSION=go1.27.1, per
    `scratchpad/go-src/GO_VERSION`)
  - `scratchpad/go-src/net/http/serve_test.go`
  - `scratchpad/go-src/net/http/clientserver_test.go`
  - `scratchpad/hyper-src/tests_server.rs.testnames.txt`
  - `scratchpad/hyper-src/src_proto_h1_{conn,decode,io,dispatch,encode,role}.rs`
  - `scratchpad/research/node-src/tests/*.js` (81 files) and
    `scratchpad/research/node-raw-socket-server-tests.txt` (55-line list)
  - `scratchpad/research/netty-codec-http-tests.tsv` (file-size listing, used to sanity-check
    which netty files exist before re-fetching them fresh)

All raw fetched files from this pass are saved under
`scratchpad/verify-b4/` (`HttpRequestDecoderTest.java`, `HttpServerKeepAliveHandlerTest.java`,
`HttpObjectAggregatorTest.java`, `HttpServerCodecTest.java`, `LICENSE.txt`, `protocol_test.exs`,
`puma_test_*.rb` ×8) for any downstream agent that wants to re-inspect them without re-fetching.
