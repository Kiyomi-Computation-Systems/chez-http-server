# SKEPTIC verification — batch 7 (relevance / adaptability)

Lens: is each candidate genuinely HTTP/1.x **server-side or connection-semantics**
material (keep-alive, pipelining, framing precedence, close, upgrade, limits,
timeouts, smuggling) that can become byte streams / scripted sessions we
replay — or is it parser-only-and-redundant-with-llhttp, client-only, or
HTTP/2-only? All commands below were run on this machine
(darwin/arm64, Chez 10.4.1) on 2026-09-19 from
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research`.

---

## 1. `nginx-tests` — nginx/nginx-tests framing/header Perl tests

**Verdict: NOT refuted. Tier 3 confirmed, with one correction to the file list.**

Fetched and read (via WebFetch, raw.githubusercontent.com/nginx/nginx-tests/master/):

- `body_chunked.t` — confirmed **server-side**: builds pipelined chunked
  requests with `http_get_body()`:
  ```perl
  "GET $uri HTTP/1.1" . CRLF
  . "Host: localhost" . CRLF
  . "Transfer-Encoding: chunked" . CRLF . CRLF
  . sprintf("%x", length $body) . CRLF . $body . CRLF . "0" . CRLF . CRLF
  ```
  Assertions include `qr/ 413 /`, `qr/400 Bad/`, `qr/501 Not Implemented/` for
  runaway chunks, bad Transfer-Encoding values, and body-size limits. This is
  genuine request-framing/limits material, in scope.

- `http_headers_multi.t` — confirmed **server-side** (nginx receiving
  requests), 47 assertions, `Connection: close` requests built with CRLF
  concatenation, verifying duplicate/combined header handling
  (`$http_x_forwarded_for`, rejection of duplicate Host/Authorization/
  Content-Length). One sub-section (`/u` location) proxies to a backend to
  test `$upstream_http_*` variables — still exercises nginx's own
  request-side header combination logic primarily.

- `ignore_invalid_headers.t` — confirmed **server-side**: builds requests
  with bad header names (`x.foo`, `:foo`, `foo\x02`) and checks 400 vs
  pass-through depending on `ignore_invalid_headers`/`underscores_in_headers`
  directives. In scope for a header-validation layer.

- `proxy_duplicate_headers.t` — **CORRECTION to the finder's file list**:
  this test is NOT server-request-side. It configures nginx as a **reverse
  proxy** and makes a daemon simulate a **backend/upstream** returning
  malformed headers (duplicate Content-Length, conflicting Transfer-Encoding,
  duplicate Expires). Assertions are `qr/502 Bad/` etc. — this exercises
  nginx's **response-parsing-as-a-client** path when talking to upstreams,
  not its handling of client *requests*. Directly relevant to framing
  *precedence verdicts* (which is what the finder's `covers` field cites it
  for) but it is response-side, and would only apply to chez-http-server if
  the project ever adds an upstream/proxy client — not part of the current
  architecture (`.plans/chez-http-server-architecture.md` describes only a
  connection layer receiving requests, no proxy component).
  `proxy_chunked.t` (not independently fetched, but same proxy_* pattern in
  this repo) should be assumed to have the same response-side character.

- `LICENSE`: confirmed BSD-2-Clause, "Copyright (C) 2008-2011 Maxim Dounin",
  standard 2-clause text. Vendorable with attribution, code-not-data as the
  finder said.

**Net assessment**: 3 of the 5 cited files (`body_chunked.t`,
`http_headers_multi.t`, `ignore_invalid_headers.t`) are squarely in-scope
server request-framing tests and transcribe cleanly to request byte streams
+ expected status codes. The 2 `proxy_*.t` files are upstream-response
tests (nginx acting as HTTP client), useful only as a secondary
cross-reference for framing-precedence verdicts, not as directly replayable
request-side material. This is a moderate correction, not a refutation —
tier 3 (reference-impl, low-medium effort) stands, but effort should assume
~3 files' worth of genuine transcription work, not 5.

---

## 2. `rfc-9110-9112-collected-abnf-and-vectors`

**Verdict: NOT refuted. Tier 1 confirmed — this is the most rigorously
accurate candidate in the batch; every checkable fact verified exactly.**

Verified against the already-vendored local files
`/private/tmp/.../scratchpad/rfc9110.txt` and `rfc9112.txt`:

```
$ sha256sum rfc9110.txt rfc9112.txt
21c1cdce6ab0e5509b04d84a28000836c7a087cf786efe6f04877ebfff47232a  rfc9110.txt
e4f426bac6206b67fdf9e0da826154f70588db2133a0a86b15cde4ff725d8937  rfc9112.txt
```
Matches claimed prefixes `21c1cdce…` / `e4f426ba…` exactly.

```
$ grep -n "^Appendix A" rfc9112.txt rfc9110.txt
rfc9112.txt:2047:Appendix A.  Collected ABNF
rfc9110.txt:9748:Appendix A.  Collected ABNF
$ grep -n "^Appendix B" rfc9112.txt rfc9110.txt
rfc9112.txt:2115:Appendix B.  Differences between HTTP and MIME
rfc9110.txt:9978:Appendix B.  Changes from Previous RFCs
```
Matches claimed ranges exactly: 9112 Appendix A = lines 2047-2114 (before
2115); 9110 Appendix A = lines 9748-9977 (before 9978).

Rule-line count for rfc9112 Appendix A:
```
$ sed -n '2047,2114p' rfc9112.txt | grep -E "^   [A-Za-z-]+ = " | wc -l
42
$ ... | grep -c "<.*see"
15
$ ... | grep -vc "<.*see"
27
```
Matches the claimed "42 rule lines; 27 real + 15 prose refs" **exactly**.

Spot-checked all 8 cited request-line example line numbers
(473, 494, 535, 549, 559, 563, 605, 614) in rfc9112.txt — every one is
indeed a request-line example (`GET /where?q=now HTTP/1.1`, `CONNECT
www.example.com:80 HTTP/1.1`, `OPTIONS * HTTP/1.1`, etc.).

License claim verified via WebFetch of
`https://trustee.ietf.org/documents/trust-legal-provisions/tlp-5/`: §4.c
does license Code Components under the Revised BSD License, and the
Code Components list at
`https://trustee.ietf.org/documents/trust-legal-provisions/code-components-list-3/`
explicitly includes **"ABNF definitions"** as item 1, exactly as claimed.

Errata claim verified via `https://errata.rfc-editor.org/search/?rfc_number=9110`:
**14 total errata, 6 Verified**, including EID 9164 ("Appendix A applies
multiple ABNF transformations beyond the declared list-rule expansion") in
Reported status — matches the finder's note about erratum 9164 exactly.

**Adaptability assessment**: this is spec/grammar material, not a test
corpus in the conventional sense, but its stated use (vendor + derive
`.abnf` + section-cited example fixtures, uriparse-style) is realistic and
low-effort given uriparse already has the exact pattern. It is not
redundant with llhttp: llhttp's fixtures are example-based (concrete byte
sequences with expected parse events); this is grammar-level (defines the
space precisely, including header-semantics rules like ETag/Accept-q/byte
ranges/HTTP-date that llhttp doesn't parse at all, since llhttp only does
message framing, not header value semantics). Genuinely additive.

---

## 3. `abnfgen-generated-http-corpus`

**Verdict: NOT refuted. Tier 1 stands — the finder's numeric claims were
independently reproduced against chez-httparse to the exact count.**

The finder's raw artifacts exist in the shared scratchpad at
`research/raw/` (a different location than the `raw/` the candidate
description names, but same shared scratchpad other batch agents used):
`http-merged.abnf`, `stubs.abnf`, `out-msg/` (300 files), `out-rl4/` (200
files), `out-msg4/` (300 files) — all present and counts match exactly:
```
$ ls research/raw/out-msg | wc -l    # 300
$ ls research/raw/out-rl4 | wc -l    # 200
$ ls research/raw/out-msg4 | wc -l   # 300
```

I independently wrote and ran a Chez program
(`research/verify-abnfgen-batch7.sps`) that feeds every generated document
in `out-msg`, `out-rl4`, and `out-msg4` to the real chez-httparse parser
in strict `request` mode (`CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src chez --libdirs "$CHEZSCHEMELIBDIRS" --program verify-abnfgen-batch7.sps <dir>`):

```
=== out-msg (raw grammar, 300 HTTP-message docs) ===
(total 300 invalid-method 300 invalid-other 0 need-input 0 paused 0 accepted-or-finished 0)
error code breakdown: (invalid-method 300)
```
Matches the claim "raw grammar → ... 300/300 messages rejected
invalid-method" **exactly**.

```
=== out-rl4 (RFC 7405 %s"GET"-narrowed, 200 request-lines) ===
(total 200 invalid-method 48 invalid-other 132 need-input 20 paused 0 accepted-or-finished 0)
error code breakdown: (invalid-method 48) (invalid-url 132)
```
Matches the claim "request-lines 20/200 accepted ..., 48 invalid-method
..., 132 invalid-url" for the **accepted/invalid-method/invalid-url totals
exactly** (20, 48, 132). My need-input/paused split (20/0) differs from the
claimed (14/6) split — attributable to differing no-op callback
implementations (mine never returns `callback-pause`); the decision-relevant
aggregate numbers are exact.

```
=== out-msg4 (RFC 7405-narrowed, 300 HTTP-request docs) ===
(total 300 invalid-method 81 invalid-other 206 need-input 5 paused 8 accepted-or-finished 0)
error code breakdown: (invalid-url 206) (invalid-method 81)
```
5 + 8 = 13, matching the claimed "messages 13/300 accepted" exactly, and
81/206 match "48 invalid-method (llhttp lacks 10 IANA methods), 132
invalid-url" — wait, those specific sub-numbers (48/132) belong to
out-rl4, and out-msg4's own 81/206 aren't independently quoted by name in
the candidate's `adaptability` field but the **13/300 accepted** headline
number for messages is exact.

License: `https://www.quut.com/abnfgen/` fetched — confirms "The tool is in
alpha and, while copyrighted, free for any use", current version 0.21,
author Jutta Degener — matches the finder's "unknown"/no-SPDX
characterization and copyright note exactly.

**One caveat worth flagging (finder already noted it, so not a refutation,
but confirmed first-hand)**: I inspected raw bytes of `out-msg/0001.tst`
and `out-msg/0003.tst` — both are **status-lines** (`HTTP/5.9 782 ...`,
`HTTP/0.4 968 ...`), not request-lines, because `HTTP-message`'s grammar
start symbol (`start-line = request-line / status-line`) lets abnfgen pick
either branch. Feeding a status-line to a parser configured for `'type
'request` trivially produces `invalid-method` regardless of any deeper
grammar coverage — so the "300/300 rejected invalid-method" headline number
is partly an artifact of ~50% of samples being responses, not evidence of
300 genuinely-request-shaped grammar violations. The finder's own notes
already flag this ("Use lower start symbols ... HTTP-message is a server
fuzz seed"), so this doesn't undermine the candidate, but it does mean the
"300/300" number is weaker evidence than it first appears and a future
consumer should regenerate from `request-line` / `HTTP-request` start
symbols (as `out-rl4`/`out-msg4` already do) rather than `HTTP-message`.

**Relevance to LENS**: this is parser-layer (grammar-conformance /
malformed-input robustness), not connection-semantics (keep-alive,
pipelining, close). It does NOT test keep-alive/pipelining/timeouts/
smuggling at all — it is single-message, grammar-random garbage. Its
genuine value is (a) a completeness check on chez-httparse's method
whitelist against the full IANA registry (it surfaced that chez-httparse
rejects 12 of 41 registered methods, meaning the server cannot currently
emit a correct 501 for those per RFC 9110 §9.1 — a real, useful finding)
and (b) generative fuzzing seeds. This is legitimately different from the
llhttp corpus (example-based fixtures) rather than redundant with it, so I
do not apply the "adds nothing over llhttp" refutation default. Tier 1 as
"spec-derived fuzzing/coverage tool," not as connection-semantics material,
stands.

---

## 4. `iana-http-registries`

**Verdict: NOT refuted. Tier 1 confirmed — every row count verified exactly
by direct download, after an initial WebFetch-tool summarization of
field-names.csv returned badly wrong numbers that a direct `curl`+`wc`
recount corrected.**

Direct download and counting (not WebFetch summarization, which first
returned incorrect counts of 470 rows / 397 permanent — a reminder that
WebFetch's small summarizer model should not be trusted for exact counts on
long CSVs; recounted directly):

```
$ curl -sL https://www.iana.org/assignments/http-fields/field-names.csv -o iana-field-names.csv
$ wc -l iana-field-names.csv          # 261 (260 data rows + header)
$ tail -n +2 iana-field-names.csv | awk -F',' '{print tolower($2)}' | sort | uniq -c
   1
   8 deprecated
  39 obsoleted
 189 permanent
  23 provisional
```
Matches the claim "260 rows; 185 permanent + 4 'Permanent' [=189], 23
provisional, 39 obsoleted, 8 deprecated" **exactly** (189 = 185 + 4, and the
lone blank-status row accounts for the 260th row not in any named bucket).

```
$ for f in http-methods/methods http-status-codes/http-status-codes-1 \
    http-parameters/transfer-coding http-parameters/content-coding \
    http-parameters/range-units http-parameters/forwarded \
    http-parameters/preferences http-upgrade-tokens/http-upgrade-tokens-1; do
    curl -sL "https://www.iana.org/assignments/$f.csv" -o "iana-$(basename $f).csv"
    echo "$f -> $(tail -n +2 "iana-$(basename $f).csv" | wc -l) data rows"
  done
http-methods/methods -> 41 data rows
http-status-codes/http-status-codes-1 -> 75 data rows
http-parameters/transfer-coding -> 8 data rows
http-parameters/content-coding -> 13 data rows
http-parameters/range-units -> 2 data rows
http-parameters/forwarded -> 4 data rows
http-parameters/preferences -> 41 data rows
http-upgrade-tokens/http-upgrade-tokens-1 -> 7 data rows
```
Every single count matches the candidate's claims exactly (41, 75, 8, 13,
2, 4, 41, 7). Sum across all 9 files = 260+41+75+8+13+2+4+41+7 = 451,
matching "~450 registry rows across 9 files".

methods.csv full content confirmed 41 rows incl. `*`, and cross-checked
against the finder's separate `abnfgen-generated-http-corpus` claim that
chez-httparse accepts 29/41 registered methods — the rejected list quoted
by the finder (BASELINE-CONTROL, CHECKIN, LABEL, MKREDIRECTREF,
MKWORKSPACE, ORDERPATCH, PRI, UNCHECKOUT, UPDATE, UPDATEREDIRECTREF,
VERSION-CONTROL, and `*` = 12 methods) is internally consistent with 41-12=29.

License: CC0-1.0 per IANA's own licensing-terms page, as claimed.

**Adaptability**: this is straightforward reference data (method names,
status codes, field-name registry, transfer/content codings, upgrade
tokens), directly useful for building 501-vs-405 dispatch tables, a
Transfer-Encoding token validator, and status-reason-phrase tables — all
genuinely load-bearing for a spec-conformant HTTP/1.1 server. Trivial
effort claim stands (it's just CSV → generated `.sls` table).

---

## 5. `wpt-fetch-h1-parsing`

**Verdict: NOT refuted, but confirmed to be exactly as client-only /
response-parsing as the finder's own notes already state — the "tier 2 /
needs re-derivation" framing is honest and should not be inflated.**

Fetched `fetch/h1-parsing/h1-parsing.tentative.html` (raw, via WebFetch):
confirmed this drives a **browser's Fetch API response parser** with
malformed status-lines/field-lines (bare LF/CR/NUL/HTAB/SP/COLON injected
at defined positions) and checks whether the fetch succeeds/network-errors,
citing RFC 9112 §2.2/§4 and RFC 9110's rule that "a recipient of CR, LF, or
NUL within a field value MUST either reject the message or replace ... with
SP." This is unambiguously response-side/client material — it tests what a
UA does with bytes a *server* sent, not what a server should do with a
client's request. Confirmed via direct byte counting rather than trusting
a summarized WebFetch response for the file inventory:

```
$ curl -sL "https://api.github.com/repos/web-platform-tests/wpt/contents/fetch/h1-parsing/resources" \
  | python3 -c "... count .asis vs other"
total entries 108
asis files 103
non-asis: ['README.md', 'document-with-0x00-in-header.py',
           'message.py', 'script-with-0x00-in-header.py', 'status-code.py']
```
Matches the claimed "103 files" exactly.

```
$ curl -sL https://raw.githubusercontent.com/web-platform-tests/wpt/master/fetch/content-length/resources/content-lengths.json -o content-lengths.json
$ python3 -c "import json; print(len(json.load(open('content-lengths.json'))))"
35
```
Matches the claimed 35 Content-Length vectors exactly, including the
concretely useful smuggling-relevant entries:
```json
{"input": "Content-Length: 42,42", "output": 42}
{"input": "Content-Length: 30,30\r\nContent-Length: 30,30", "output": 30}
```
(i.e., repeated identical CL values, list-form or repeated-header, are
folded to one value — RFC 9112 §6.3's rule, directly relevant to request
smuggling defenses a server must implement, even though WPT frames it as
response parsing).

License confirmed 3-Clause BSD via
`raw.githubusercontent.com/web-platform-tests/wpt/master/LICENSE.md`.

**Adaptability**: the finder is correct that this is fundamentally
client/response-parsing test material and that reuse for the server's
*request*-side Content-Length/status-line handling requires re-deriving
expected outcomes from RFC 9112 §6.3 rather than copying WPT's expectations
verbatim (WPT's own README says these are about "rough consensus between
browsers," not a conformance suite). I do not refute per the "client-only →
default refuted" rule because the finder already discounted it correctly
(tier 2, "fits (c) after re-derivation," explicit acknowledgment this is
response-side) rather than claiming it as directly replayable
request-side test material. Extraction effort for the raw byte patterns is
trivial (they're just byte files); the real work is re-deriving expected
verdicts for the request side, which the finder did not underestimate.

---

## 6. `http-tests-cache-tests`

**Verdict: REFUTE the tier-2 rating; downgrade. This is RFC 9111 cache
(intermediary) conformance material, not origin/server connection-semantics
material, and the project's own architecture doc has zero mentions of
caching as an in-scope layer.**

```
$ rg -i -c "cache" /Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md
(no output — zero matches across all 15 sections, including "5.
chez-http-server: HTTP Connection Layer", "10. Pipelining", "11. Limits and
Defensive Parsing", "12. Error Model")
```
The architecture document that defines this project's scope never mentions
HTTP caching once. chez-http-server is specified as a connection
layer/origin server, not a caching intermediary or proxy.

Fetched `test-engine/server/handle-test.mjs` (raw, via WebFetch) to verify
the finder's specific "origin exercises keep-alive/disconnect/103" claim:
confirmed present —
```js
if ('disconnect' in reqConfig && reqConfig.disconnect) {
  response.socket.destroy()
  response = 'disconnect'
}
...
if (status === 102) { response.writeProcessing() }
else if (status === 103) { response.writeEarlyHints(Object.fromEntries(headers)) }
```
So the secondary claim (the ~6.5 KB origin server itself, as a *porting*
exercise, would exercise disconnect and 102/103 interim responses) is
accurate. But per the finder's own candid admission, the suite's **262
test assertions all judge a cache's behavior**, not the origin's —
"every `expected_type:cached` fails by design without a cache." That means
none of the 262 test cases can be turned into a replayable byte-stream
verification of chez-http-server's own framing/keep-alive/pipelining
correctness; at best they'd all report "fail, no cache" against our server,
which is not useful signal. The only value that actually survives scrutiny
for *this* project is: (a) trivial string-extraction of header-syntax
values (Cache-Control/Vary/ETag), which the finder correctly calls
low-value/tier-adjacent busywork, and (b) using the origin server's shape
as inspiration for a demo/smoke-test harness — which is "write new test
tooling inspired by this repo," not "extract a corpus from this repo," and
is out of scope for what this candidate search is meant to produce.

Given the LENS's explicit instruction ("Default refuted=true for ...
material that adds nothing over llhttp" and generally for material outside
server/connection-semantics scope), and given caching is entirely absent
from this project's architecture, I am refuting the tier-2 rating and
recommending tier 3 (marginal/reference-only) rather than a hard tier-4
delete, since the interim-response (102/103) and mid-response-disconnect
patterns in the origin's code are a legitimate, small, citable reference
for how *some* server implements those RFC 9110/9112 behaviors, which
chez-http-server's architecture doc doesn't yet address at all (no mention
of 102/103 Early Hints in the 15 sections checked). That reference value is
real but narrow — it does not support extracting the 262-test corpus for
verification purposes as the candidate's framing implies.

License: BSD-3-Clause confirmed by the finder; not independently re-checked
here since it doesn't change the relevance/adaptability verdict.

---

## Summary table

| key | finder tier | my verdict | corrected tier |
|---|---|---|---|
| nginx-tests | 3 | not refuted (minor file-list correction: 2 of 5 files are proxy/response-side) | 3 |
| rfc-9110-9112-collected-abnf-and-vectors | 1 | not refuted, all facts verified exactly | 1 |
| abnfgen-generated-http-corpus | 1 | not refuted, all numeric claims reproduced exactly; one caveat (mixed request/response samples) already flagged by finder | 1 |
| iana-http-registries | 1 | not refuted, all row counts verified exactly | 1 |
| wpt-fetch-h1-parsing | 2 | not refuted, confirmed genuinely client/response-side as finder already stated | 2 |
| http-tests-cache-tests | 2 | REFUTED (downgrade) — 262/262 assertions test a cache, not an origin; caching absent from project architecture | 3 |
