# Skeptic verification — batch10 (load-generation tools)

Role: SKEPTIC. Lens: relevance and adaptability for chez-http-server (an HTTP/1.1
**server**). Question for each candidate: is this HTTP/1.x server-side /
connection-semantics material, or is it parser-only (redundant with the llhttp
corpus we already vendor), client-only, or HTTP/2-only? Can it become byte
streams or scripted client sessions we replay against our server? All six
candidates in this batch are load-generation tools (client software), so the
sub-question that actually separates them is: does using the tool as a
*harness* against our server exercise genuine HTTP/1.1 connection semantics
(keep-alive, pipelining, close, framing, backpressure), or is it just generic
throughput measurement that duplicates what another candidate in the batch, or
the llhttp corpus, already gives us?

All commands below were run on 2026-09-19 from
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research`,
fetching upstream `master`/`trunk` branches live. Raw files saved there:
`ab.c`, `h2load.1.rst`, `h2load_http1_session.cc`, `siegerc.in`,
`siege_http.c`, `siege_version.c`, `siege_COPYING`, `bombardier_README.md`,
`oha_tests.rs`, `autocannon_README.md`, `autocannon_httpClient.js`,
`autocannon_pipelinedRequestsQueue.js`.

---

## 1. autocannon

**Verdict: NOT refuted. Tier 2 confirmed.**

Verified facts:
- `package.json` on `master` → version `8.0.0`, license `MIT`. npm registry
  `GET https://registry.npmjs.org/autocannon/latest` also returns
  `"version":"8.0.0"` — confirms finder's "npm registry latest 8.0.0" claim
  exactly (checked 2026-09-19).
- All seven `corpus_paths` return HTTP 200 from
  `raw.githubusercontent.com/mcollina/autocannon/master/...`:
  `test/pipelinedRequestsQueue.test.js`, `test/httpClient.test.js`,
  `test/httpRequestBuilder.test.js`, `test/parseHAR.test.js`,
  `test/runRate.test.js`, `package.json`, `LICENSE`.
- `autocannon_README.md:45-46` confirms the CLI flag exactly as claimed:
  `-p/--pipelining NUM` — "The number of pipelined requests to use. default: 1."
- `autocannon_pipelinedRequestsQueue.js` (fetched in full, 80 lines) is a real
  FIFO queue that matches server responses to pipelined requests **in order**,
  per RFC 7230 §6.3.2 pipelining semantics — this is genuine wire-level HTTP
  pipelining, not just N concurrent keep-alive connections. That means
  pointing `autocannon -p N` at chez-http-server is a real test of the
  server's pipelined-request framing/ordering, something the llhttp corpus
  (static per-message fixtures) cannot exercise at all since it never models a
  second message arriving before the first is answered.
- One caveat surfaced during verification: `autocannon_README.md:307` says of
  the *embeddable* `Client` API option `pipelining`: "Will cause the `Client`
  API to throw when greater than 1." This refers to the low-level
  single-connection `Client` class in `lib/httpClient.js`, not the top-level
  `autocannon()`/CLI orchestration (which is what `-p` drives, and which uses
  `PipelinedRequestsQueue` as shown above) — so this is not a blocker, just a
  detail to know if scripting against the low-level API directly.
- `autocannon_httpClient.js:1-40` shows the client is built on
  `require('http-parser-js').HTTPParser` (a JS port of the original Node.js
  `http_parser`, i.e. a lineage independent of llhttp) wired to a hand-rolled
  `net.Socket`-based `Client` class with its own pipelining queue. So the
  finder's phrase "hand-rolled TCP client... is a second, differently-lenient
  HTTP/1.1 peer" is accurate for the TCP/pipelining wiring, though the
  underlying parser itself is a named library (`http-parser-js`), not
  hand-written from scratch — a minor wording correction, not a substantive
  one, since `http-parser-js` genuinely is a different implementation lineage
  from llhttp and therefore a useful point of contrast.

Correction to note (not a refutation): the listed `corpus_paths` are
autocannon's *own* dev/unit tests of its client — they test autocannon's
request-building and HAR-parsing logic, not our server, and are not
byte-stream fixtures we can lift directly. The actual adaptable value is the
installed CLI/API used as a harness (`-p`, `-E/--expectBody`, `--har`) against
our server, exactly as the finder's `adaptability` field (not `corpus_paths`)
describes. Effort estimate of "none" for getting the tool running is fair;
budget a few hours to write the actual pipelining/keep-alive assertions since
none exist off the shelf.

---

## 2. oha-and-hey

**Verdict: NOT refuted. Tier 2 confirmed.**

Verified facts:
- `Cargo.toml` on `master` → oha version `1.16.0`. `formulae.brew.sh/api/formula/oha.json`
  → `"stable":"1.16.0"` (checked 2026-09-19) — matches finder exactly.
- `tests/tests.rs` (1325 lines) contains 34 `fn`/`async fn` items whose name
  starts with `test_` (`grep -n "^async fn test_\|^fn test_" oha_tests.rs`),
  two of which (`test_request_count`, `test_proxy_with_setting`) are parameterized
  helper functions rather than standalone `#[test]`/`#[tokio::test]` cases,
  putting the real test count in the low-to-mid 30s — close enough to the
  finder's "31" to not be a material discrepancy (an initial WebFetch
  AI-summarized pass over the same file mis-stated "41" total while its own
  enumerated list only showed 31 names, illustrating why raw `grep` over the
  actual file, not an LLM's paraphrase, is the reliable check here).
- Confirms the finder's own caveat that oha's suite is testing oha's *client*
  behavior against ad hoc local servers it spins up itself (header/redirect/
  proxy/query handling), not shipped server-fixtures; one test literally calls
  out to `google.com` (`test_google`, `oha_tests.rs:1109`), which is dead
  weight for us and confirms it is not a portable corpus to lift wholesale.
- `formulae.brew.sh/api/formula/bombardier.json` and other brew checks done
  alongside (see candidate 3) corroborate the finder's general diligence
  pattern across this batch.
- hey: `api.github.com/repos/rakyll/hey/license` → `"spdx_id":"Apache-2.0"`,
  confirming finder's license claim. `git/trees/master?recursive=1` on
  `rakyll/hey` shows exactly two `_test.go` files (`hey_test.go`,
  `requester/requester_test.go`), consistent with "9 Go tests" being individual
  test functions inside those two files, not 9 files.

Assessment: unlike its own test suite, the **compiled CLI** is the actual
asset — real independent client stacks (Rust `hyper` for oha, Go `net/http`
for hey), rate-controlled load (`-q`/`--latency-correction`), and an explicit
`--disable-keepalive` toggle for connection-churn testing. Given the project's
own documented constraint that chez-libuv has **no bounded write queue**
(ADR-0018) and the consumer must watch `uv-stream-write-queue-size` as a
congestion signal, a rate/concurrency-controllable, keep-alive-toggleable load
generator is directly on-point for exercising that exact codepath — arguably
undervalued rather than overvalued by the finder, but I am not raising the
tier further since I have no baseline for what would justify tier 1 in this
project's schema (tier 1 is presumably reserved for primary/must-have
material like the llhttp corpus itself). Tier 2, not refuted.

---

## 3. bombardier

**Verdict: NOT refuted. Tier 2 confirmed.**

Verified facts:
- `bombardier_README.md:21` (fetched raw, `wc -l` = 56 lines total) reads
  verbatim: *"AFAIK, it's impossible to pass Host header correctly with
  `fasthttp`, you can use `net/http`(`--http1`/`--http2` flags) to workaround
  this issue."* — exact match to the finder's claim and line citation.
- `api.github.com/repos/codesenberg/bombardier/license` → `"key":"mit"`,
  `"spdx_id":"MIT"` — confirms license.
- `formulae.brew.sh/api/formula/bombardier.json` → `"stable":"2.0.2"` —
  matches finder exactly.
- Ubuntu apt gotcha independently confirmed: `packages.ubuntu.com/noble/bombardier`
  shows the noble package `bombardier` is version `0.8.3+nmu3`, section
  **games**, with page keywords "games, 0.8.3+nmu3" — this is indeed "The GNU
  Bombing utility" (an old X11 game), not the Go load tool. Finder's warning
  not to `apt install bombardier` on Ubuntu expecting the HTTP tool is
  accurate and worth keeping in the writeup verbatim.

Assessment: the fasthttp-vs-net/http switch is a genuinely distinct,
verified capability among this batch — it lets us tell whether an
observed server quirk is provoked by a non-RFC-strict client (fasthttp, which
per the README cannot even set Host correctly) versus a conforming one
(net/http), which is squarely "connection-semantics" material per the task's
own lens. Tier 2, not refuted.

---

## 4. h2load-http1

**Verdict: NOT refuted, but TIER DOWNGRADED from 2 to 3.**

This is the one candidate where deeper verification surfaced a real,
citable reason to discount the finder's rating.

Verified facts:
- `doc/h2load.1.rst:226-230` (fetched raw, 451 lines total) confirms
  the `--h1` text verbatim: *"Short hand for `--alpn-list`\=http/1.1
  `--no-tls-proto`\=http/1.1, which effectively force http/1.1 for both
  http and https URI."* — matches finder's citation exactly.
- `doc/h2load.1.rst:115-121` (`-p, --no-tls-proto=<PROTOID>`): *"Specify ALPN
  identifier of the protocol to be used when accessing http URI without
  SSL/TLS. Available protocols: h2c and http/1.1. Default: `h2c`"* — this is
  the option that actually governs plain `http://` targets, and its default
  is HTTP/2-cleartext prior-knowledge, **not** HTTP/1.1. `doc/h2load.1.rst:216-224`
  (`--alpn-list`, default `h2,http/1.1`) governs the *TLS* ALPN
  negotiation list, a separate option. So the finder's one-sentence gloss
  ("default alpn list h2,http/1.1 means plain http:// without --h1 attempts
  h2c prior knowledge") conflates two different options in its wording, but
  the underlying conclusion is verified correct: **omit `--h1` against a
  plain-http chez-http-server and h2load will send an HTTP/2 cleartext
  preface, not HTTP/1.1 request bytes.** This is a real, confirmed footgun,
  and the finder's operational guidance ("must always pass --h1") is sound.
- New finding not in the original candidate brief: `-m,
  --max-concurrent-streams=<N>` (`doc/h2load.1.rst:68-74`) states *"When
  http/1.1 is used, this specifies the number of HTTP pipelining requests
  in-flight. Default: 1"* — so h2load-h1 does support pipelining depth
  control, a capability the finder's `covers` list omitted.
- **Load-bearing new finding**: fetched
  `src/h2load_http1_session.cc` (281 lines) directly from the nghttp2 repo.
  Its HTTP/1.1 response-parsing path is built directly on **llhttp**, the
  exact library our own corpus is drawn from:
  ```
  43:int htp_msg_begincb(llhttp_t *htp) {
  56:int htp_statuscb(llhttp_t *htp, const char *at, size_t length) {
  72:int htp_msg_completecb(llhttp_t *htp) {
  80:  client->final = llhttp_should_keep_alive(htp) == 0;
  109:int htp_hdr_keycb(llhttp_t *htp, const char *data, size_t len) {
  120:int htp_hdr_valcb(llhttp_t *htp, const char *data, size_t len) {
  131:int htp_hdrs_completecb(llhttp_t *htp) {
  137:int htp_body_cb(llhttp_t *htp, const char *data, size_t len) {
  148:constexpr llhttp_settings_t htp_hooks = { ... };
  159:  llhttp_init(&htp_, HTTP_RESPONSE, &htp_hooks);
  193:  auto htperr = llhttp_execute(...);
  ```
  This means h2load's own opinion of whether a chez-http-server response is
  well-formed, and whether the connection is keep-alive-eligible
  (`llhttp_should_keep_alive`), is generated by the **same parser** whose
  fixture corpus (`llhttp/test/response/*.md`) we already have vendored.
  Unlike autocannon (`http-parser-js`, an independent lineage), oha (Rust
  `hyper`), and bombardier (`fasthttp` / Go `net/http`), h2load-h1 provides
  **no independent second opinion** on our response framing — running it
  against our server is closer to "does llhttp agree with llhttp" than a
  genuine interoperability cross-check. It still exercises something llhttp's
  static corpus cannot (live concurrency, rate control, and, per the `-m`
  finding above, real pipelining depth over an actual TCP connection), so it
  is not "parser-only" in the fully-refuted sense, but its distinguishing
  value against the three other load tools already tier-2'd in this batch is
  materially weaker than the finder credited.
- Packaging claims cross-checked: `formulae.brew.sh/api/formula/nghttp2.json`
  → `"stable":"1.70.0"`, matching the finder's brew version. (Homebrew
  `--enable-app` build-flag claim and the Ubuntu `nghttp2-client` package
  claim were not independently re-derived beyond confirming the noble package
  `nghttp2-client` exists at `packages.ubuntu.com/noble/nghttp2-client`, which
  loaded successfully.)

Recommendation: keep h2load-http1 as a candidate (it is a real, portable,
fast C binary and the `-m` pipelining-depth control is useful), but at tier 3
alongside siege rather than tier 2 — it duplicates rate/concurrency
capability already covered by autocannon/oha/bombardier, its one distinctive
capability (raw C speed) isn't a connection-semantics differentiator, its
default silently switches wire protocols if you forget one flag, and its
response-conformance opinion is not independent of the llhttp corpus we
already hold.

---

## 5. ab-apachebench

**Verdict: NOT refuted. Tier 2 confirmed.**

Verified facts, all against `support/ab.c` fetched raw from
`apache/httpd` `trunk` (3493 lines total):
- `ab.c:2302` and `ab.c:2312` both contain the literal format string
  `"%s %s HTTP/1.0\r\n"` — confirms ab always sends an HTTP/1.0 request line,
  never 1.1, regardless of flags.
- `ab.c:2307` and `ab.c:2320` both contain
  `keepalive ? "Connection: Keep-Alive\r\n" : ""` — confirms `-k` is required
  to add the header at all.
- `ab.c:2109` contains exactly
  `c->keepalive = (keepalive && xstrcasestr(c->cbuff, "Keep-Alive"));` —
  confirms ab decides whether to reuse the connection via a **case-insensitive
  substring search** for the literal text "Keep-Alive" anywhere in the
  response headers buffer, not a proper `Connection` header token parse. This
  is worth calling out explicitly in follow-on work: it means ab's keep-alive
  detection could be fooled by an unrelated header merely containing the
  substring "Keep-Alive" (e.g. `X-Debug: Keep-Alive-Test`), so it is a crude
  probe, not a conformance oracle — consistent with, and reinforcing, the
  finder's own caveat that ab is "inaccurate as a benchmark."

Assessment: this crude, independent (no shared code with any of the other
five tools) substring-based keep-alive probe is exactly the kind of
HTTP/1.0-specific connection-semantics edge case (explicit-opt-in keep-alive,
substring rather than token-aware detection) that the task lens calls out,
and it ships on macOS by default (`/usr/sbin/ab`) with zero install effort.
Tier 2, not refuted.

---

## 6. siege

**Verdict: NOT refuted. Tier 3 confirmed (finder's own downgrade holds up), one
license-precision correction.**

Verified facts:
- `src/version.c:7` → `const char *version_string = "4.2.0";` (file is only
  15 lines; the whole file was read). `formulae.brew.sh/api/formula/siege.json`
  → `"stable":"4.2.0"` — matches finder exactly.
- `doc/siegerc.in:213` → `protocol = HTTP/1.1` and `doc/siegerc.in:268` →
  `connection = close` — both confirmed verbatim (file fetched in full, 645
  lines), corroborating the finder's "connection-churn by default" claim.
- License correction: `siege_COPYING` (fetched in full) is the plain GPLv3
  text, and GitHub's own license detector
  (`api.github.com/repos/JoeDog/siege/license`) reports
  `"key":"gpl-3.0","spdx_id":"GPL-3.0"` — **not** "GPL-3.0-or-later" as the
  finder wrote. Digging further, `src/http.c:9-11` (a source file, not the
  packaged license) actually carries an *older* header reading "the GNU
  General Public License as published by the Free Software Foundation;
  either **version 2** of the License, or (at your option) any later
  version" — i.e. the repository's own file headers and its COPYING file
  disagree (a stale v2-or-later boilerplate left in at least one `.c` file
  while the shipped COPYING is v3). The safe, verifiable label is plain
  **GPL-3.0** (per COPYING/GitHub detection), not the more specific
  "-or-later" suffix the finder asserted without a citation for it. This is a
  correction, not a reason to change the substance of the finder's
  conclusion: it is still copyleft, still "tool use only, vendor nothing
  into the BSD-3-Clause repo."

Assessment: I agree with the finder's own reasoning for keeping this at the
lowest tier — GPL licensing (tool-only), an asset-fetching default that must
be disabled, and its one distinguishing capability (default connection-churn,
i.e. `connection = close`) is already covered by `oha --disable-keepalive`
and by `ab` without `-k`, both already tier-2'd in this same batch. Tier 3,
not refuted, `corrected_license` set to `GPL-3.0`.

---

## Summary table

| key | finder tier | corrected tier | refuted | headline reason |
|---|---|---|---|---|
| autocannon | 2 | 2 | false | real wire-level pipelining verified in source; independent parser lineage (http-parser-js) |
| oha-and-hey | 2 | 2 | false | independent client stacks (hyper/net-http); directly exercises the project's documented backpressure/congestion gap (ADR-0018) |
| bombardier | 2 | 2 | false | verified fasthttp Host-header defect + net/http strict-mode switch is genuine connection-semantics leverage |
| h2load-http1 | 2 | **3** | false | response parsing is llhttp itself (verified in `h2load_http1_session.cc`) — not an independent cross-check; redundant with the other three load tools; h2c-by-default footgun |
| ab-apachebench | 2 | 2 | false | verified crude substring-based (not token-aware) Keep-Alive detection is a distinctive HTTP/1.0 edge-case probe |
| siege | 3 | 3 | false | finder's own downgrade confirmed; license corrected to GPL-3.0 (not "-or-later", unverifiable and contradicted by a stale v2 header in one source file) |
