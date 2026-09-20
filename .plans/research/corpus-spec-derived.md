# Corpus finder report — lens: SPECIFICATION-derived

Date measured: 2026-09-19, on macOS arm64, Chez 10.4.1, chez-httparse v0.2.0 at /Users/yuzu/github/chez-httparse.
Raw downloads, generated corpora and probe programs are under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/raw/` (referred to below as `raw/`).
Nothing was written into any git repository.

Legend for fit: (a) in-process loopback via chez-libuv client verbs; (b) black-box external client against a port; (c) sans-I/O connection driver replaying byte streams at every chunk size.
Tier: 1 = vendor now with PROVENANCE; 2 = adapt later; 3 = reference only.

---

## 0. What the sibling repos already vendor (local, verified)

```
$ ls uriparse/test/conformance/rfc3986
PROVENANCE dot-segments.scm example-uris.scm resolution.scm rfc3986.abnf
$ cat uriparse/test/conformance/rfc3986/PROVENANCE   (excerpt)
  https://www.rfc-editor.org/rfc/rfc3986.txt
  vendored verbatim at test/vendor/rfc3986.txt
  sha256 3102dae4b68cebe40337730312fcb612297b8928547267e8b3d1ee6002b2d683
  ...
  rfc3986.abnf      Appendix A -- the Collected ABNF, 36 rules over 60 lines.
                    ... decision 0012 makes it the source of the generated positive corpus
```
- uriparse ADR 0012 (`/Users/yuzu/github/uriparse/.plans/decisions/0012-the-corpus-instruments-abnfgen-and-mutation.md`) already adopts abnfgen with committed corpus + seed + count, and records that abnfgen's licence is unstated and it generates only valid input.
- uriparse ADR 0005 (`.../0005-the-corpus-is-the-rfcs-own-vectors.md`) sets the pattern: RFC's own vectors, cited by section, never edited; project-authored vectors counted separately.
- chez-httparse vendors llhttp fixtures with a checksummed PROVENANCE (`/Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE`: `upstream-ref: v9.4.3-1-gee51043`, 24 files, sha256 per file). It does **not** vendor any RFC ABNF:
```
$ rg -n -i 'rfc ?(9110|9112|7230|7231|2616)|abnf|abnfgen' chez-httparse byte-machine --glob '!build/**' --glob '!vendor/**' --glob '!*.html' -S
chez-httparse/src/httparse/grammar.sls:111:  ;; tchar = ALPHA / DIGIT / "!#$%&'*+-.^_`|~"  (RFC 9110 5.6.2)
chez-httparse/src/httparse/grammar.sls:653:     ;; RFC 7230 3.3.3 again: ...
chez-httparse/src/httparse/grammar.sls:1650:      ;; `forbidAfterChunkedInRequest`, and RFC 7230 3.3.3 ...
chez-httparse/src/httparse/grammar.sls:2087:      ;; ... RFC 7230 3.3.3 gives the two kinds
chez-httparse/test/common/response-framing-tests.sps:324:    ;; RFC 7230 3.3.3 ...
```
byte-machine has no RFC/ABNF files at all (find over `*rfc*`, `*abnf*`, `*.txt` returned only CMake/LICENSE files).

---

## 1. RFC 9110 / RFC 9112 text: collected ABNF (Appendix A) + the RFCs' own vectors — TIER 1

**URLs** (fetched, sha256 measured):
```
$ curl -sSL -o rfc9110.txt https://www.rfc-editor.org/rfc/rfc9110.txt ; shasum -a 256 rfc9110.txt
21c1cdce6ab0e5509b04d84a28000836c7a087cf786efe6f04877ebfff47232a  rfc9110.txt   (10785 lines)
$ curl -sSL -o rfc9112.txt https://www.rfc-editor.org/rfc/rfc9112.txt ; shasum -a 256 rfc9112.txt
e4f426bac6206b67fdf9e0da826154f70588db2133a0a86b15cde4ff725d8937  rfc9112.txt   (2461 lines)
```
**Licence**: IETF Trust Legal Provisions (TLP 5) §4.c: Code Components "are also licensed ... on the terms of the 'Revised BSD License'" (https://trustee.ietf.org/documents/trust-legal-provisions/tlp-5/). The Code Components list (https://trustee.ietf.org/documents/trust-legal-provisions/code-components-list-3/) explicitly names "ABNF definitions". Vendoring the whole RFC text verbatim follows the uriparse precedent (`test/vendor/rfc3986.txt`). SPDX for the derived ABNF: BSD-3-Clause (IETF Trust).

**Where the data is (file:line in the vendored .txt)**:
```
$ rg -n '^Appendix A\.  Collected ABNF' rfc9112.txt   → 2047   ; Appendix B at 2115
$ rg -n '^Appendix A\.  Collected ABNF' rfc9110.txt   → 9748   ; Appendix B at 9978
$ rg -c '^   [A-Za-z][A-Za-z0-9-]* = ' rfc9112-appendixA.txt  → 42
$ rg -c '^   [A-Za-z][A-Za-z0-9-]* = ' rfc9110-appendixA.txt  → 142
```
Of those, prose-value cross references (dropped for generation, resolved from the other document / RFC 3986) are 15 in 9112 and 12 in 9110:
```
BWS/OWS/RWS/field-name/field-value/obs-text/quoted-string/token/transfer-coding/absolute-path = <..., see [HTTP]>
URI-reference/absolute-URI/authority/path-abempty/port/query/relative-part/segment = <..., see [URI]>
uri-host = <host, see [URI], Section 3.2.2>
language-range = <..., [RFC4647]>   language-tag = <Language-Tag, [RFC5646]>   mailbox = <..., [RFC5322]>
```
So the closed grammar for HTTP/1.1 messages = 9112 App. A (27 real rules) + 9110 App. A (130 real rules) + RFC 3986 App. A (36 rules, already vendored by uriparse) + RFC 5234 core rules, with three stubs (Language-Tag, language-range, mailbox) only needed for Accept-Language / Content-Language / From.

**RFC-native vectors (the analogue of uriparse's §5.4 set)** — all in rfc9110.txt / rfc9112.txt at the cited lines:
- RFC 9112 request-line examples (lines 473, 494, 535, 549, 559, 563, 605, 614): `GET /where?q=now HTTP/1.1` + `Host: www.example.org`; `GET http://www.example.org/pub/WWW/TheProject.html HTTP/1.1`; `CONNECT www.example.com:80 HTTP/1.1`; `OPTIONS * HTTP/1.1`; `OPTIONS http://www.example.org:8001 HTTP/1.1`; `GET /pub/WWW/TheProject.html HTTP/1.1`. Field examples: line 821 `Transfer-Encoding: gzip, chunked`, 1227 `TE: deflate`, 1229 `TE: trailers, deflate;q=0.5`, 1506 `Connection: close`.
- RFC 9110 start-line examples: 16 (`rg -n '^ {3,}(GET|...) [^ ]+ HTTP/1\.[01]$|^ {3,}HTTP/1\.[01] [0-9]{3}' rfc9110.txt` → lines 1000, 1007, 2434, 2843, 2871, 3681, 3690, 3708, 4276, 4310, 4448, 6727, 7115, 7142, 7773, 7844) and 132 `Name: value` field-line examples (`rg -c '^ {3,}[A-Z][A-Za-z-]+: ' rfc9110.txt` → 132; e.g. lines 1001–1015 the full curl exchange, 2721/2733/2737 `Via`, 2844–2846 `Connection: upgrade` / `Upgrade: websocket, IRC/6.9, RTA/x11`).
- Normative tables with expected results:
  - §5.6.1.2 list rule: valid `"foo,bar"`, `"foo ,bar,"`, `"foo , ,bar,charlie"`; invalid `""`, `","` (rfc9110.txt around the `#element` expansion; found via `sed -n` from the §5.6.1.2 heading, lines +25..+33).
  - §8.8.3.2 ETag comparison table (4 rows): `W/"1"` vs `W/"1"` strong no-match/weak match; `W/"1"` vs `W/"2"` no/no; `W/"1"` vs `"1"` no/match; `"1"` vs `"1"` match/match.
  - §12.5.1 Accept quality table (lines 5468–5480): `Accept: text/*;q=0.3, text/plain;q=0.7, text/plain;format=flowed, text/plain;format=fixed;q=0.4, */*;q=0.5` → text/plain;format=flowed 1, text/plain 0.7, text/html 0.3, ... (erratum 7138 is Verified against this table — check it).
  - §14.1.2 byte-range examples (lines 6406–6447): `bytes=0-499`, `bytes=500-999`, `bytes=-500`, `bytes=9500-`, `bytes=0-0,-1`, `bytes=500-600,601-999`, `bytes=500-700,601-999`.
  - §5.6.7 date formats (lines 1848–1853): `Sun, 06 Nov 1994 08:49:37 GMT` / `Sunday, 06-Nov-94 08:49:37 GMT` / `Sun Nov  6 08:49:37 1994`.
- Requirement density: `rg -c MUST rfc9112.txt` → 86 lines; `rfc9110.txt` → 205 lines.

**Errata (must be adjudicated at vendoring time, as uriparse ADR 0015 does)** — fetched from https://errata.rfc-editor.org/rfc9112 and https://errata.rfc-editor.org/rfc9110:
- RFC 9112: 4 errata. 7744 Verified/Editorial §1.2 (obs-text cross-ref); 8284 Verified/Editorial §C.3; 7214 Rejected (HEXDIG case); 7633 Rejected (bare-LF leniency does not extend to chunked: "A chunked parser is not a start line or field parser").
- RFC 9110: 14 errata — Verified 6 (7138 §12.5.1, 7306 §14.1.1 range ABNF, 7419 §8.3.2, 7105 §B.1, 7109 §15.4.9, 8268 §B.2), Reported 2 (9162 §5.2 comma-SP wording; **9164 Appendix A**), Rejected 6 (7107, 7599, 7870, 8138, 8459, 7530).
- Erratum 9164 (https://errata.rfc-editor.org/eid9164, Reported/Technical) matters for a transcription check: Appendix A applies three undeclared transformations beyond list expansion — "Adjacent quoted terminals combined (3 rules)", "Case-sensitive strings rewritten in hexadecimal (2 rules)", "Repetition bounds shortened (2 rules)". Consequence: compare a vendored grammar against Appendix A itself, not against the body text.

**Fit / adaptation**: (c) first — the ABNF is the grammar the connection driver's fixtures should cite, and the in-text examples become request/response fixtures with section citations; (a)/(b) for the example exchanges as end-to-end smoke. Provenance discipline: vendor the two .txt files verbatim with sha256, derive `rfc9110.abnf`/`rfc9112.abnf` and `examples.scm` by script (as uriparse's `cmake/UriCorpus.cmake` does), never hand-edit.

Notes on the httpwg/http-core repo (https://github.com/httpwg/http-core, "Core HTTP Specifications", no LICENSE file; API `license: null`): it ships `httpbis.abnf` (10088 bytes, 265 lines, 173 rules across 9110/9111/9112) but the last commit touching it is `df5a4b2 2021-07-23 "switch to named references instead of RFC numbers"` — pre-publication (RFCs published June 2022) and its banner still says "extracted from the IETF HTTPbis WG Internet Drafts". Do not vendor it; use Appendix A. Its tooling is worth knowing: `Makefile:96-103,123-124` build per-document ABNF via `lib/extract-artwork.xslt` and check/normalise it with `bap/` (Bill's ABNF Parser: `parser.y`, `scanner.l`, `main.c`, `core.abnf` = RFC 5234 core rules, 52 lines) and `lib/common-abnf.sh`. No test artifacts exist in http-core, and the httpwg org has no HTTP/1.1 test repo (`gh api orgs/httpwg/repos` → admin, compression-test, datatracker-tweet, http-core, http-extensions, http2-spec, httpbis-issues, httpwg.github.io, structured-field-tests, theme, wg-materials, wiki). The `http-tests` org has exactly one repo (cache-tests). So "IETF httpbis test cases" = cache-tests + structured-field-tests, nothing else.

---

## 2. abnfgen over the collected ABNF as a generated corpus — TIER 1 (tool is contributor-side; the generated corpus is committed)

**URL**: https://www.quut.com/abnfgen/ — version 0.21, "last updated June 3rd, 2023"; tarball https://www.quut.com/abnfgen/abnfgen-0.21.tar.gz. Licence: the page says "copyrighted" but "free for any use"; the man page carries `Copyright (c) 2002, 2006 Jutta Degener` and no licence text → SPDX "unknown" (same status uriparse ADR 0012 records). Built cleanly in the scratchpad:
```
$ ./configure && make ; ./abnfgen -h
abnfgen version 0.21; send bugs to <jutta@pobox.com>
   -c              Attempt full coverage
   -r n            Seed random generator with <n>
   -s nonterminal  Start symbol is <nonterminal>
   -t file         Include tentative definitions in <file>
   -x              Exclude (don't preload) the core syntax
```
Man page `-c`: "Try for complete coverage. Rather than randomly picking productions, try to cover each leaf and branch of the grammar." `-r`: "For the same grammar and version of the software, the same seed always creates the same subtree." (abnfgen warns that seeds for other than the first run of `-c` are not reproducible; without `-c` two runs with `-r 42` produced IDENTICAL files — `diff -r out-d1 out-d2` → identical, 5 files.)

**Grammar assembly (measured pitfalls)** — files `raw/g9112.abnf`, `raw/g9110.abnf`, `raw/g3986-renamed.abnf`, `raw/stubs.abnf`, merged `raw/http-merged.abnf` (162 rules):
1. ABNF rule names are case-insensitive (RFC 5234 §2.1): RFC 3986 `host` collides with RFC 9110 `Host` → `abnfgen: redefinition of <host>`; fix = rename 3986's `host` to `uri-host` (the name 9110 uses). declaresub/abnf's `tests/fuzz/effective_grammar.py` documents the same two issues.
2. `method = token` appears in both 9112 and 9110 Appendix A → de-duplicate (kept first).
3. Prose-val rules must be dropped and supplied from the referenced grammar; `-t stubs.abnf` supplies Language-Tag / language-range / mailbox only if undefined.

**Generation results**:
```
$ abnfgen -c -r 1 -s HTTP-message -n 300 -d out-msg -t stubs.abnf http-merged.abnf
files: 300 ; start-line class: 271 request / 29 status ; 97 distinct HTTP-versions (HTTP/0.8, HTTP/3.4, ...)
field-line count per message: 150×0, 76×1, 36×2, 18×3, 10×4, 4×5, 1×6, 5×7 ; total 10315 bytes, max 127
$ abnfgen -c -r 7 -s request-line -n 100 ...   → e.g. "DYU * HTTP/1.4", "wnxNB 246.234.62.254: HTTP/9.7", "% /~:%aA@&L'%cC=%BE$()!///%F9 HTTP/4.7"
$ abnfgen -c -r 3 -s chunked-body -n 4 ...     → e.g. "bc3fCdFAaeBED277370\r\nT\r\n4\r\n...\r\n0;y2o\r\n..." (chunk-ext with quoted-string, trailer fields)
```
**What chez-httparse (strict request mode, llhttp-compatible) says about them** — probe program `raw/feed-probe.sps`, run with `chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program feed-probe.sps <dir> <n> <mode>`:
```
raw grammar, request-line docs (100) + "Host: x":            err:invalid-method 100
raw grammar, HTTP-message docs (300):                          err:invalid-method 300
method := IANA methods as "GET"/... (case-insensitive), HTTP-version := "HTTP/1." ("0"/"1"):
   request-lines (200): err:invalid-method 164, err:invalid-url 28, need-input 7, paused 1
method := IANA methods as %s"GET"/... (RFC 7405 case-sensitive), HTTP/1.x:
   request-lines (200): need-input 14, paused 6, err:invalid-method 48, err:invalid-url 132
   HTTP-request  (300): need-input 5, paused 8,  err:invalid-method 81, err:invalid-url 206
```
Interpretation (each is a design fact for the server, not a defect in the generator):
- `method = token` is far wider than what an llhttp-derived parser accepts; llhttp rejects at byte 0–2, so the server can never answer 501 for such requests (RFC 9110 §9.1 wants 501 for unrecognised methods) — it will be a 400 from the parser.
- Quoted ABNF strings are case-insensitive; coverage mode emits `propfind` and the parser rejects it (methods are case-sensitive, RFC 9110 §9.1). Use `%s"..."` when narrowing `method`.
- The collected ABNF does not tie request-target form to method (authority-form only for CONNECT, RFC 9112 §3.2.3; asterisk-form only for OPTIONS, §3.2.4) nor scheme to `//`; llhttp's URL checker is narrower than RFC 3986 `absolute-URI`. Samples rejected as invalid-url: `POST 37.10.253.228:15 HTTP/1.1` (consumed 5), `GET GA: HTTP/1.0` (8), `MKCALENDAR M:/? HTTP/1.0` (14), `UNCHECKOUT [::]:6 HTTP/1.1`.
- Per-method probe (`raw/methods-probe.sps`, `M / HTTP/1.1\r\nHost: x\r\n\r\n` for each of the 41 registry rows): **ACCEPTED 29 / REJECTED 12**; rejected = `BASELINE-CONTROL CHECKIN LABEL MKREDIRECTREF MKWORKSPACE ORDERPATCH PRI UNCHECKOUT UPDATE UPDATEREDIRECTREF VERSION-CONTROL *` (PRI is llhttp's h2-preface special case; `*` is not a method). llhttp's own table (`/Users/yuzu/github/llhttp/src/llhttp/constants.ts`, `export const METHODS`, 50 entries incl. RTSP/ICE) has 10 IANA methods missing.

**Fit / adaptation**: (c) — commit generated `.tst` files + seed + count + grammar (uriparse ADR 0012 shape); the property is "never crashes, never misframes; outcome ∈ {accept, 400, 501, 505}" and "same result at every chunk size". (a) — the same bytes over loopback. Lower start symbols (`field-line`, `chunked-body`, `request-target`) are the useful ones for the parser layer; `HTTP-message` is a server-level fuzz seed. abnfgen generates only valid strings; negatives need a charset-aware mutator (uriparse ADR 0012 item 4) or declaresub's `corpus_neg` approach (finding 12).

---

## 3. IANA HTTP registries as data files — TIER 1

**Licence**: https://www.iana.org/help/licensing-terms — "IANA and IETF intend that the Protocol Registries may be freely used by any party for any purpose" (CC0 1.0). SPDX: CC0-1.0.

**Files (downloaded, counted; header row excluded from counts)**:
```
https://www.iana.org/assignments/http-fields/field-names.csv            260 rows  (Field Name,Status,Structured Type,Reference,Comments)
   status: 185 permanent + 4 "Permanent" (capitalisation inconsistency!), 23 provisional, 39 obsoleted, 8 deprecated, 1 blank
   registry <created>2021-10-01</created> <updated>2026-08-28</updated> (http-fields.xml)
https://www.iana.org/assignments/http-methods/methods.csv                41 rows  (Method Name,Safe,Idempotent,Reference) incl. "*"; page says updated 2026-06-17
https://www.iana.org/assignments/http-status-codes/http-status-codes-1.csv  75 rows (Value,Description,Reference) incl. Unassigned ranges; updated 2025-09-15
https://www.iana.org/assignments/http-parameters/transfer-coding.csv       8 rows  (chunked, compress, deflate, gzip, identity(withdrawn), trailers(reserved), x-compress, x-gzip)
https://www.iana.org/assignments/http-parameters/content-coding.csv       13 rows
https://www.iana.org/assignments/http-parameters/range-units.csv           2 rows
https://www.iana.org/assignments/http-parameters/forwarded.csv             4 rows ; preferences.csv 41 rows
https://www.iana.org/assignments/http-upgrade-tokens/http-upgrade-tokens-1.csv  7 rows (HTTP, TLS, WebSocket, h2c, ...)
```
**Fit / adaptation**: data, not tests, for all of (a)/(b)/(c): method table drives 501-vs-405 and the safe/idempotent bits; status table supplies reason phrases; field-name table drives a case-insensitive header registry and the `Structured Type` column tells which fields are SF-typed; transfer-coding table validates `Transfer-Encoding` (note `identity` withdrawn). Vendor CSVs verbatim with retrieval date + sha256 and generate `.sls` tables from them. Caveat measured above: chez-httparse accepts only 29 of the 40 registered methods.

---

## 4. web-platform-tests `fetch/h1-parsing` (+ `fetch/content-length`) — TIER 2

**URL**: https://github.com/web-platform-tests/wpt/tree/master/fetch/h1-parsing ; licence BSD-3-Clause (`LICENSE.md`: "The 3-Clause BSD License / Copyright © web-platform-tests contributors"; API reports NOASSERTION because of the file name).
README (fetched): "This directory tries to document 'rough consensus' on where HTTP/1 parsing should end up between browsers." Context: whatwg/fetch issue #1156.

**Paths and counts**:
- `fetch/h1-parsing/resources/*.asis` — 103 files (`gh api ... | select(.name|endswith(".asis")) | length` → 103): 102 generated by `fetch/h1-parsing/tools/generate_parsing_asis.py` (6 symbols LF/CR/HTAB/SP/NUL/COLON × 17 insertion positions in a fixed `HTTP/1.1 200 OK` + `X-Frame-Options:DENY` response) + `blue-with-0x00-in-a-header.asis`. Sample (`parsing_CR_in-name.asis`, xxd): `HTTP/1.1 200 OK\r\nX-Frame\r-Options:DENY\r\nContent-Length: 5\r\n\r\nTest.`
- `fetch/h1-parsing/h1-parsing.tentative.html` — the expectation matrix (`expected = { 'LF': {...}, 'CR': {...}, 'HTAB': ...}` from line 41), each block citing RFC 9112 §2.2 / §4 verbatim ("A recipient of such a bare CR MUST consider that element to be invalid or replace each bare CR with SP").
- `fetch/h1-parsing/lone-cr.window.js` — 10 raw response strings expected to be network errors ("HTTP/1.1\r200 OK\n\nBODY", "HTTP/1.1 200 OK\nHeader\r: Value\n\nBODY", ...).
- `fetch/h1-parsing/status-code.window.js` — 16 status-line vectors (`"0 OK"→0`, `"099 HELLO"→99`, `"200"→200/""`, `"999 DOES IT MATTER"→999`, `"1000 BOO"→null`, `"0200 BOO"→null`, `"-200 TEST"→null`, `"0xA"→null`, `"C8"→null`, ...).
- `fetch/content-length/resources/content-lengths.json` — 35 `input→output` vectors, e.g. `"Content-Length: 42,42"→42`, `"Content-Length: 30,42"→null`, `"Content-Length: 30,"→null`, `"Content-Length: aaaah"→42` (=treated as no CL), `"Content-Length: 030"→30`, `"Content-Length: 030\r\nContent-Length: 30"→null`, `"Content-Length: -1"→42`, `"Content-Length: \"30\""→42`.
- Also present but not inspected in depth: `fetch/range/` (206/416 behaviour), `fetch/http-cache/` (browser mirror of cache-tests).

**Fit / adaptation**: these are **response**-parsing expectations for browsers, so for a server they map to (i) a negative corpus for the response serializer ("never emit these bytes"), (ii) the Content-Length and status-line vectors transpose directly to request-side rules (RFC 9112 §6.3: identical list members OK, differing → reject) — but note WPT's "invalid CL ⇒ ignore" outcome differs from §6.3's "reject" for requests, so expectations must be re-derived from the RFC, not copied; (iii) exact (c) fixtures if/when a client-side response parser exists (chez-httparse already runs llhttp's response fixtures). Fit: (c) after re-derivation; (b) only through a browser. `.asis` files are raw bytes and the `.js` arrays are trivially extractable.

---

## 5. http-tests/cache-tests (cache-tests.fyi) — TIER 2

**URL**: https://github.com/http-tests/cache-tests ; licence **BSD-3-Clause** (`gh api` → `"license":"BSD-3-Clause"`, pushed 2026-09-18, 139 stars). README: "not a conformance test suite" but "a tool to assess how a cache behaves"; cache-tests.fyi "collects results from caches in browsers, reverse proxies, and CDNs ... to help the HTTP Working Group".

**Paths and counts**:
- `tests/*.mjs` — 25 suite files (age-parse, authorization, cc-freshness, cc-parse, cc-request, cc-response, cdn-cache-control, conditional-etag, conditional-lm, expires-freshness, expires-parse, headers, heuristic-freshness, interim, invalidation, method, other, partial, pragma, stale, status, update304, updateHead, vary-parse, vary), `tests/index.mjs` lists them, `tests/lib/templates.mjs` (fresh/stale/becomeStale templates).
- Test count: `cat cache-tests-*.mjs | rg -c "^\s*id: ['\"]"` → **262** (per-suite: cc-freshness 25, cdn-cache-control 25, conditional-etag 22, vary 21, cc-response 18, expires-parse 17, age-parse 16, cc-parse 16, other 14, cc-request 13, partial 11, ...). Explicit `kind`: 78 optimal, 70 check, 3 required; CONTRIBUTING says `required` is the default, so ≈114 are conformance tests. Flags: 34 `browser_skip`, 24 `cdn_only`, 5 `browser_only`.
- Format: `CONTRIBUTING.md` lines 9–110 ("## Test Format": `id`, `name`, `kind`, `requests[]` with `request_headers`, `request_method`, `response_headers`, `response_status`, `response_body`, `interim_responses`, `expected_type` cached|not_cached, `expected_status`, `expected_request_headers`, `expected_response_headers`, `disconnect`, `response_pause`, `setup`, `magic_ims`, ...). Machine schema: `test-engine/lib/testsuite-schema.json` (20997 bytes, title "Cache Tests"). Every test carries `spec_anchors` into RFC 9111.
- Origin protocol the JS server implements (`test-engine/server/server.mjs` + `handle-config.mjs` + `handle-test.mjs`, ≈6.5 KB total): `PUT /config/<uuid>` (201; 405 if not PUT; 409 if exists) stores the JSON test; `GET /test/<uuid>` replays it (`response_pause` via setTimeout; interim `102` and `103` via `writeEarlyHints`; other 1xx "not yet supported"; `disconnect` → `response.socket.destroy()`); `GET /state/<uuid>` returns observed requests; anything else = static file.

**How many apply to an origin server**: strictly, none test the origin — the suite scripts the origin and judges the cache. The origin-facing value is: (1) the 262 scripted responses are a corpus of well-formed Cache-Control / Age / Expires / Vary / ETag / Last-Modified / Content-Range header values with RFC 9111 anchors (cc-parse 16, age-parse 16, expires-parse 17, vary-parse 8 cover the syntax edge cases: quoted `max-age="3600"`, trailing commas, RFC 850 dates via `rfc850date`); (2) porting the ~6.5 KB origin (config/test/state routes, 1xx interim, disconnect, pause, PUT bodies) is a compact, well-specified **application-level milestone** for (b): `npm run --silent cli --base=http://127.0.0.1:PORT/` against our server with no cache in the path should produce the "no cache" baseline (every `expected_type: cached` fails by design; setup requests, PUTs, 1xx and disconnects must work).
**Fit**: (b) as the origin under the upstream Node client; (c) only for the header-value strings. Tier 2 because the assertions are about caches.

---

## 6. cispa/http-conformance ("Who's Breaking the Rules?", ACM AsiaCCS 2024) — TIER 2

**URL**: https://github.com/cispa/http-conformance ; licence **MIT** (`gh api` → MIT; LICENSE 1077 bytes), pushed 2026-07-16, 18 stars. Paper: https://dl.acm.org/doi/10.1145/3634737.3637678 ; follow-up "HTTP Conformance vs. Middleboxes" (PAM 2025) reuses the same repo.

**Paths and counts** (from `raw/cispa-testcases.py`, 4426 lines):
```
$ rg -c '^class ' cispa-testcases.py → 106        ; rg -c '^\s+def test' → 106
activity: 11 Activity.DIRECT (send crafted request bytes, judge status), 89 Activity.PROXY (probe a recorded response via mitmproxy), 6 Activity.RETRO
type:     41 Level.REQUIREMENT, 27 Level.RECOMMENDATION, 38 Level.ABNF
category: 54 "HTTP Headers", 20 "Statuscodes", 9 "HTTP", 5 "HTTP Methods", 5 "HTTP/1.1", 5 "HTTP/2", 4 "Cache-Control", 4 "HTTP Cookies"
source:   55 rfc9110, 10 rfc9112, 7 rfc9111, 5 rfc9113 (HTTP/2, N/A), 5 rfc6797, 4 rfc6265, 2 rfc5789
valid()/invalid() wptserve handlers: 106 / 106  (sanity_check/serve_testcases.py registers "/<name>/valid" and "/<name>/invalid")
helpers/output/test_overview.tex: Considered 106, Broken 75, Probe 89, Direct 11, Retro 6, Requirements 41, Recommendations 27, ABNFs 38
```
The 11 DIRECT tests and their anchors: continue_before_upgrade (rfc9110#name-upgrade), reject_fields_contaning_cr_lf_nul (rfc9110#name-field-values), code_400_after_bad_host_request (rfc9112#name-request-target), code_501_unknown_methods, code_405_blocked_methods (rfc9110#name-overview), content_head_request (rfc9110#name-head), allow_crlf_start, reject_msgs_with_whitespace_between_startline_and_first_header_field (rfc9112#name-message-parsing), code_400_if_msg_with_whitespace_between_header_field_and_colon (rfc9112#name-field-line-parsing), content_length_2XX_connect (rfc9110#name-content-length), transfer_encoding_2XX_connect (rfc9112#field.transfer-encoding).
Each class carries `title`, `description` (the RFC sentence verbatim), `source` URL, `type`, and `build_request(...)` raw bytes; e.g. reject_fields_contaning_cr_lf_nul sends `Invalid: a\x00\r\n`, `a\r\r\n`, `a\n\r\n` and expects 400.

**Fit / adaptation**: DIRECT → (b) black-box and, by copying the `build_request` bytes + expected codes, (a)/(c); PROXY → response-side checks (RFC 9110 field rules, 1xx/204 Content-Length, duplicate fields, Cache-Control directives) that can be run over responses captured in-process (a); the paired `valid()`/`invalid()` handlers are 212 example responses that serve as a response-serializer positive/negative corpus. Extraction effort: moderate (Python classes, mitmproxy/dpkt/redbot deps — not needed for the bytes). Tier 2: highest-provenance server-side rule set found (each rule quotes its RFC sentence), but it needs transcription and 5 rules are HTTP/2-only.

---

## 7. Http11Probe (MDA2AV) — TIER 2

**URL**: https://github.com/MDA2AV/Http11Probe ; licence **MIT** (LICENSE: "MIT License / Copyright (c) 2026 Diogo Martins"); created 2026-02-07, pushed 2026-09-16, 30 stars; results site https://www.http-probe.com/ (redirect target of mda2av.github.io/Http11Probe/). README: "The same 215 tests run against 41 reference servers written in 12 languages ... scored against the MUST/SHOULD/MAY wording ... Pass, Fail, or Warn"; CLI `dotnet run --project src/Http11Probe.Cli -- --host localhost --port 8080 --output results.json`, `--category Compliance|Smuggling|MalformedInput|Normalization|Cookies|Capabilities`, `--test <ID>`; requires .NET 10 SDK.

**Paths and counts**:
- `src/Http11Probe/TestCases/Suites/*.cs` — `Id =` occurrences: CapabilitiesSuite 9, ComplianceSuite 69, CookieSuite 12, MalformedInputSuite 26, NormalizationSuite 5, SmugglingSuite 87, WebSocketsSuite 5 (=213; 196 distinct quoted `AAA-BBB` ids by regex; README says 215 — counts differ by a handful, not verified further).
- `TestCase.cs` fields: `Id`, `Description`, `Category`, `RfcReference` (e.g. "RFC 9112 §2.2"), `RfcLevel` (Must/Should/May/NotApplicable), `PayloadFactory : Func<TestContext, byte[]>`, `Expected : ExpectedBehavior` (`ExpectedStatus = StatusCodeRange...` or a `CustomValidator` lambda), `Scored`. Sample: `RFC9112-2.2-BARE-LF-REQUEST-LINE` sends `GET / HTTP/1.1\nHost: ...\r\n\r\n`, "400 or close (pass), 2xx (warn)".
- `docs/content/docs/<category>/<test>.md` — 188 per-test pages (request-line 27, smuggling 88, malformed-input 27, headers 16, body 16, cookies 13, caching 10, host-header 8, http-overview 8, normalization 6, websockets 6, line-endings 5, content-length 4), each with a table (Test ID, Category, RFC link, RFC Level, Expected) and a "What it sends" code block (e.g. `COMP-VERSION-CASE`: `GET / http/1.1` → "400 or connection close", quoting RFC 9112 §2.3).

**Fit / adaptation**: (b) directly (raw TCP prober, target-agnostic). For (a)/(c) the markdown pages are closer to data than the C# (whose expectations are partly lambdas): a script over `docs/content/docs/**.md` yields request bytes + expected verdict + RFC anchor for ~188 cases. Overlaps the security lens (88 smuggling cases) but every test is RFC-cited, which is why it is listed here.

---

## 8. h1spec family (four unrelated repos of that name) — TIER 2 (dropseed) / 3 (others)

- **dropseed/h1spec** https://github.com/dropseed/h1spec — Python, "HTTP/1.1 conformance testing tool in the spirit of h2spec"; no LICENSE file but `pyproject.toml:7 license = "MIT"`; 4 commits, 0 stars, pushed 2026-03-05. Tests: `h1spec/tests/{request_line,headers,body,connection,response,hardening}.py` → `cat dropseed/*.py | rg -c '^def test_'` = **33** (request_line 7, headers 7, body 11, connection 3, response 2, hardening 3), each = raw bytes via `send_recv(addr, b"...")` + accepted status set (e.g. `GET / HTTP/2.0` → 400 or 505; `GET /\r\nHost:...` → 400; `OPTIONS *`, absolute-form, `CONNECT example.com:443` must not 400). Sections cite RFC 9112 §3/§5/§6-7/§9 and RFC 9110. Run: `uvx --from git+https://github.com/dropseed/h1spec h1spec localhost:8000`. README caveats: no TLS, cannot test smuggling. Fit (b); trivially transcribable to (a)/(c) (bytes + status set). Tier 2 — tiny but clean and RFC-9112-based; young repo.
- **uNetworking/h1spec** https://github.com/uNetworking/h1spec — Deno/TypeScript, `http_test.ts` (291 lines) with `testCases: TestCase[]` = **33** entries (`rg -c '^\s+request: "'` → 33): 15 fragmented-request cases expecting a timeout (server must wait, not respond), plus missing Host, duplicate Host, negative/overflowing Content-Length, `X-Invalid[]` header name, chunked TE, "Conflicting Transfer-Encoding and Content-Length in varying case"; expects the server to echo bodies. **No licence file or statement** (API `license: null`; README has no licence line) → cannot vendor; pushed 2024-10-27; 41 stars. Fit (b). Tier 3 for provenance reasons, though the fragmentation cases are a good idea to re-derive.
- **LeaYeh/h1spec** https://github.com/LeaYeh/h1spec — Go, **AGPL-3.0** (incompatible with vendoring into a BSD-3 repo); `spec/http1.1/RFC9112_3_request_line.go` has 1 active case; `spec/http1.1_archive/*.go` has 34 RFC 7230-era cases (protocol versioning 22, error handling 6, multiple Content-Length 2, missing Host 2, chunk-size hex 2); pushed 2025-06-08. Tier 3.
- **wooshdev/h1spec** https://github.com/wooshdev/h1spec — C# (`src/*.cs`), Zlib, last push 2020-02-15, 13 commits; `src/Tests/Test.cs` (207 lines) has a handful of RFC 7230 §3.2 OWS tests. Tier 3.

---

## 9. mnot/httplint field tests (and redbot) — TIER 2

**URL**: https://github.com/mnot/httplint ; licence **MIT** (API), pushed 2026-08-08; "Python library to lint HTTP messages". REDbot (https://github.com/mnot/redbot, MIT per `LICENSE.md` "Copyright (c) 2008- Mark Nottingham") delegates all message checks to httplint; redbot's own `test/` is UI/daemon tests, not a corpus.

**Paths and counts**:
- `httplint/field/parsers/*.py` — 108 files, one per field (accept … www_authenticate, plus typo-catchers `connectiox.py`, `cteonnt_length.py`). Embedded test classes: `cat httplint-parsers/*.py | rg -c 'FieldTest\['` → **344** cases in 92 files (16 files have none); top: set_cookie 28, link 16, strict_transport_security 13, content_range 11, content_length 10, transfer_encoding 9, cache_control 9, content_security_policy 9.
- Format (`httplint/field/tests.py:69` `class FieldTest(unittest.TestCase, Generic[TMessage])`): `name`, `inputs: List[bytes]`, `expected_out`, `expected_notes`, optional `set_response_context`. Example from `content_length.py`: inputs `[b"1"]`→1; `[b"a"]`→None + CL_BAD_SYNTAX; `[b"1;"]`→None; `[b" 1 "]`→1; `[b"9"*999]`→int + CL_TOO_LARGE; `[b"1", b"1"]`→1 + SINGLE_HEADER_REPEAT; `[b"1, 1"]`→None + CL_BAD_SYNTAX; `[b"1", b"2"]`→1 + SINGLE_HEADER_REPEAT; `[b"1"]` with transfer-encoding present → CL_AND_TE_PRESENT (quoting RFC 9110 §8.6).
- `httplint/syntax/rfc9110.py` (667 lines, 133 regex rules transcribed from the ABNF, `SPEC_URL = "http://httpwg.org/specs/rfc9110"`), `rfc9112.py` (162 lines, 32 rules), plus rfc3986/5234/5322/5646/5987/6838/8288/9111/9651 — an independent, MIT-licensed transcription of the same grammar to diff a Scheme transcription against.
- `test/http-fields.xml` (IANA registry snapshot) + `test/test_fields.py` `checkRegistryCoverage` — the pattern "every registered field has a handler" is worth copying.
**Fit / adaptation**: (c)-style unit fixtures for a header-semantics layer (Content-Length/Transfer-Encoding/Connection/Host/Expect/Upgrade/Range/Content-Range...). Extraction = a small Python script over the class attributes; note `expected_notes` are httplint's own vocabulary while `expected_out` is the parsed value. Note: some CL cases are a lint's view (`" 1 "` → 1), whereas RFC 9112 §6.3 for a server is stricter — re-derive expectations.

---

## 10. httpwg/structured-field-tests — TIER 3 (becomes 2 if the server parses Structured Fields)

**URL**: https://github.com/httpwg/structured-field-tests ; licence **BSD-3-Clause** (`LICENSE.md`: "Copyright (c) 2018- IETF Trust and the persons identified as authors of the code ... Redistribution and use in source and binary forms..."); pushed 2026-09-16, 45 stars. RFC 8941 → RFC 9651.
**Paths and counts** (`jq length` per file): binary 17, boolean 12, date 17, dictionary 26, display-string 22, examples 21, item 5, key-generated 640, large-generated 11, list 11, listlist 12, number-generated 193, number 37, param-dict 14, param-list 20, param-listlist 3, string-generated 256, string 14, token-generated 256, token 6 → **1593** parse cases; plus `serialisation-tests/{key-generated,number,string-generated,token-generated}.json`; JSON schemas in `schema/{parse,expected,serialize}.schema.json`.
**Fit**: (c) for a field-value layer only (Priority, Cache-Status, Proxy-Status, Accept-CH are SF-typed per the IANA `Structured Type` column). Not HTTP/1.1 framing; reference only for the first milestones.

---

## 11. declaresub/abnf — RFC 9110 grammar transcription + committed per-rule corpora — TIER 2

**URL**: https://github.com/declaresub/abnf ; licence **MIT**; pushed 2026-09-18, 54 stars; "Python parser generator for ABNF grammars".
**Paths and counts**:
- `src/abnf/grammars/rfc9110.py` (RFC 9110 rules as ABNF text with imports from rfc3986/4647/5322/5646), `rfc7230.py`, `rfc9111.py`, `rfc9651.py` — **no rfc9112.py** (`rg -c rfc9112 abnf-tree.txt` → 0).
- `tests/fuzz/corpus/rfc9110.json` — 142 rules / 13,313 strings (Hypothesis-generated from the *built* parser by `tests/fuzz/gen_corpus.py`; self-referential, replayed by `test_corpus_modules.py`).
- `tests/fuzz/corpus_abnfgen/rfc9110.json` — 142 rules / 958 strings (`gen_abnfgen_corpus.py`: abnfgen over the module's *effective grammar text*, `SEED = 20250824`, `MAX_DEPTH = 9`, `SAMPLES_PER_RULE = 8`; docstring: "abnfgen reads ABNF *text*, so it is an independent oracle").
- `tests/fuzz/corpus_neg/rfc9110.json` — 140 rules / 1,639 strings ("a valid string with one *grammar-alien* character injected — a character no terminal of the rule can match", verified rejected); sample `Accept: "\u0000"`, `"!\u0000/!"`.
- `tests/fuzz/effective_grammar.py` — documents exactly the case-folding and `host`→`uri-host` renaming issues hit in finding 2.
**Fit / adaptation**: (c) unit fixtures per RFC 9110 rule (token, quoted-string, field-content, Content-Length, Transfer-Encoding, Via, Date, …): plain JSON `{rule: [strings]}`; provenance is "declaresub's transcription + generator", one step removed from the RFC — cite as such. Tier 2.

---

## 12. Co-Advisor (Measurement Factory) and daft — TIER 3

- **Co-Advisor**: http://www.measurement-factory.com/products/co-advisor/ → HTTP 404 (both http and https, fetched 2026-09-19); the company root https://www.measurement-factory.com/ still lists "Co-Advisor (an HTTP and ICAP compliance test suite)". Squid wiki (https://wiki.squid-cache.org/Features/HTTP11): "almost 900 individual test cases, targeting various MUSTs in RFC 2616 and 7230-7235"; W3C QA position paper (https://www.w3.org/2001/01/qa-ws/pp/alex-rousskov-measfact.html): "Project members get certain privileges. Non-paying users get restricted free access to the tool." No public source or test-case download found (WebSearch found none; web.archive.org is not fetchable from this tool). Licence: proprietary/unknown. Reference only — the closest thing to a full RFC-MUST enumeration for HTTP/1.1 that ever existed, but not obtainable.
- **measurement-factory/daft** https://github.com/measurement-factory/daft — Apache-2.0, ""Do as told" HTTP functionality testing tools, including an HTTP proxy"; README: client/server/proxy agents in ECMAScript 2017, e.g. `src/cli/daft.js run tests/proxy-update-headers-after-304.js`; `tests/` has 2 scripts (`self.js`, `test-proxy-h0-response.js`). A framework, not a corpus. Tier 3.

---

## Searches that found nothing further
- "HTTP/1.1 conformance test suite" / "http1-conformance" / "h1spec": only the four h1spec repos, dropseed, Http11Probe and cispa above.
- IETF httpbis test cases: none beyond cache-tests and structured-field-tests (httpwg + http-tests org listings above).
- `httpwg/wiki` tree contains no test/implementation pages (`rg -i 'test|implement'` over its blob list → empty).

## Commands index (all run from `raw/`)
- Repo metadata/licences: `gh api repos/<owner>/<repo> --jq '{license: .license.spdx_id, default_branch, pushed_at, stars: .stargazers_count}'` for every repo named above (outputs quoted inline).
- Trees: `gh api "repos/<owner>/<repo>/git/trees/HEAD?recursive=1" --jq '.tree[] | select(.type=="blob") | .path'` → `*-tree.txt`.
- Counts: as quoted per finding; the abnfgen and chez-httparse probes are `feed-probe.sps`, `methods-probe.sps`, `which-url.sps`, `err-shape.sps` in `raw/`, run with `chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program <file> ...`.
- chez-httparse error record shape (from `err-shape.sps` on `DYU * HTTP/1.4`): `(error 1 #(#(byte-machine-parser-error) machine invalid-method "Invalid method encountered" #f e-bad-method-open 392 1 byte))`.
