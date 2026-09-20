# Skeptic verification report — batch 6 (relevance / adaptability lens)

Role: SKEPTIC. Goal: try to REFUTE each candidate on the lens of (a) is it HTTP/1.x
server-side / connection-semantics material vs. parser-only-redundant-with-llhttp /
client-only / HTTP/2-only, and (b) can it be turned into byte streams or scripted
client sessions we can replay, with an hour estimate for extraction.

Verification method: fetched the actual files named in each candidate's
`corpus_paths` (via `curl` to raw.githubusercontent.com / GitHub API, saved under
`scratchpad/research/*-src/`), read them with the `Read` tool, and cross-checked
every concrete, falsifiable claim (case counts, license text, byte-level
transforms, named test methods) against the primary source. Where a claim
concerned our own corpus (llhttp), I grepped the local
`/Users/yuzu/github/llhttp` checkout directly.

Outcome up front: every quantitative claim in all six candidates checked out
**exactly**. I could not refute any candidate outright on the relevance/adaptability
lens; several deserved a *narrower* scope or a caveat, which I note per-candidate. This
is an unusually well-verified candidate set — see "Overall assessment" at the end for
how I tried harder and what I found.

---

## 1. `defparam-smuggler` — defparam/smuggler TE mutation configs

**URL:** https://github.com/defparam/smuggler
**Files fetched (raw, saved to `scratchpad/research/smuggler-src/`):**
- https://raw.githubusercontent.com/defparam/smuggler/master/configs/default.py (31 lines)
- https://raw.githubusercontent.com/defparam/smuggler/master/configs/doubles.py (26 lines)
- https://raw.githubusercontent.com/defparam/smuggler/master/configs/exhaustive.py (52 lines)
- https://raw.githubusercontent.com/defparam/smuggler/master/lib/Payload.py (73 lines)
- https://raw.githubusercontent.com/defparam/smuggler/master/LICENSE

**What the files actually contain** (verbatim structure, read via `Read` tool
after `curl`):
- All three configs build a `mutations` dict via a shared `render_template(gadget)`
  helper that assembles a fixed request template (`__METHOD__ __ENDPOINT__?cb=__RANDOM__
  HTTP/1.1`, `Host`, `User-Agent`, `Content-type`, `Content-Length: __REPLACE_CL__`) with
  `gadget` spliced in as the one line that is supposed to look like a
  `Transfer-Encoding` header. Critically, in `default.py` and `exhaustive.py` the real
  `Transfer-Encoding: chunked` line is *commented out* (`# p.header += "Transfer-Encoding:
  chunked" +RN`) and replaced entirely by the mutated gadget — i.e. the whole point of
  each case is "does the target's parser recognize this obfuscated spelling as
  `Transfer-Encoding` and switch to chunked framing, when a `Content-Length` is also
  present?" That is exactly a framing-precedence / CL-TE ambiguity test, not a pure
  grammar-acceptance test.
- `default.py`: 4 named mutations (`nameprefix1`, `tabprefix1`, `tabprefix2`, `space1`)
  + a loop over 13 bytes `[0x1,0x4,0x8,0x9,0xa,0xb,0xc,0xd,0x1F,0x20,0x7f,0xA0,0xFF]` ×
  10 position-variants (`midspace`, `postspace`, `prespace`, `endspace`, `xprespace`,
  `endspacex`, `rxprespace`, `xnprespace`, `endspacerx`, `endspacexn`) = 4 + 130 =
  **134**. Matches the finder's claimed count exactly.
- `doubles.py`: `range(0x1,0x21)` (32 values) × 6 position-variants + `range(0x7F,0x100)`
  (129 values) × 6 = 192 + 774 = **966**. Matches exactly.
- `exhaustive.py`: 28 named mutations (`nameprefix1` … `x-nout`, including
  `sarcasm`="TrAnSFer-EnCODinG", `yelling`="TRANSFER-ENCODING", `revdualchunk`
  = duplicate TE headers, `0dspam`="Transfer\r-Encoding", `commaCow`/`cowComma`
  = comma-joined value list) + `range(0x1,0x20)` (31) × 4 + `range(0x7F,0x100)`
  (129) × 4 = 28 + 124 + 516 = **668**. Matches exactly.
- `lib/Payload.py` line 1-3: `#!/usr/bin/python` / `# MIT License` / `# Copyright (c)
  2020 Evan Custodio` — inline header confirmed verbatim; `smuggler-src/LICENSE`
  (top-level repo LICENSE file, also fetched) is the standard MIT text with the same
  copyright line. License claim confirmed exactly.

**Cross-check against our own llhttp corpus** (the redundancy test the task asks
for): grepped `/Users/yuzu/github/llhttp/test/request/*.md` for
Transfer-Encoding-obfuscation-style fixtures.
- `test/request/transfer-encoding.md` (1275 lines) headings are all about *chunk-size*
  parsing (case of hex digits, extensions, CRLF termination) — none about mutating the
  literal `Transfer-Encoding` header name/value the way smuggler does.
- `test/request/content-length.md` has a couple of tab/space-around-`Content-Length`
  cases, but nothing for `Transfer-Encoding`.
- `test/request/invalid.md` and `lenient-header-value-relaxed.md` /
  `lenient-headers.md` each contain exactly one or two bare-CR/bare-LF header-splitting
  cases of the shape `x:\rTransfer-Encoding: chunked` / `x:\nTransfer-Encoding: chunked`
  — these correspond to smuggler's `x-rout`/`x-nout`/`0dspam` family, i.e. llhttp
  already covers ~3 of these ~1768 combined cases. It has **no** case-scrambling, no
  tab/vertical-tab/quote/comma-list mutation, and no systematic byte sweep at
  multiple header positions.
- Conclusion: this is **not** redundant with the existing llhttp corpus. It
  substantially extends it on exactly the axis (TE-header recognition / framing
  precedence) the task cares about.

**Verdict: NOT REFUTED.** Tier 1 (port-the-data-table, don't vendor the Python) is
justified. Every request in this corpus is a single self-contained byte stream
(fixed template + one mutated header line) — trivially generatable in Scheme;
expected verdict for a strict parser is "treat as non-chunked, framing governed by
Content-Length" (per RFC 9112 §6.3 rule 3, see candidate 3). Extraction effort
estimate: **~4-6 hours** to port `render_template` + the three mutation tables into
a Scheme data file (`(define te-mutations '((name . gadget-string) ...))`) and a
generator that splices each into a byte-vector request; the byte-position variants
(`xprespace`, `rxprespace`, etc.) require slightly more care to get right in Scheme
string/bytevector handling, hence not "trivial."

---

## 2. `portswigger-http-request-smuggler` — PortSwigger DesyncBox permutation catalogue

**URL:** https://github.com/PortSwigger/http-request-smuggler
**Files fetched (saved to `scratchpad/research/psrs-src/`):**
- https://raw.githubusercontent.com/PortSwigger/http-request-smuggler/master/src/burp/DesyncBox.java (480 lines)
- https://raw.githubusercontent.com/PortSwigger/http-request-smuggler/master/src/burp/ProbePayloads.java (67 lines)
- https://raw.githubusercontent.com/PortSwigger/http-request-smuggler/master/LICENSE
- GitHub API: `https://api.github.com/repos/PortSwigger/http-request-smuggler` and
  `.../contents/` (root listing) and `.../contents/resources`

**What the files actually contain:**
- `ProbePayloads.java` lines 41-53: exactly 13 `Payload` entries (ids 0-12), e.g.
  `TRACE /asdf HTTP/1.1\r\nA: B`, `GET /0-9 HTTP/0.9...`, `CONNECT
  n1p4fbvwvalvyvljgp8a3zts4jaay5mu.psres.net:443...`. Matches "13 probe prefix
  payloads" exactly.
- `DesyncBox.java` constructor (lines 22-115) registers named permutations into four
  buckets:
  - `sharedPermutations`: 38 named literals (`vanilla`, `underjoin1`, `spacejoin1`,
    `nameprefix1/2`, `vertwrap`, `spjunk`, `backslash`, `commaCow`/`cowComma`,
    `contentEnc`, `quoted`/`aposed`, `nel`/`nbsp`/`shy`/`shy2`, etc.) + 4 loops over
    `getSpecialChars()` (`spacefix1:`, `prefix1:`, `suffix1:`, `namesuffix1:`) × 6
    chars = 24 more → 62 shared techniques.
  - `h1Permutations`: 15 named (`nospace1`, `linewrapped1`, `doublewrapped`,
    `gareth1`, `badsetupCR/LF`, `multiCase`, `tabwrap`, `UPPERCASE`, `0dwrap`,
    `0dspam`, `badwrap`, `bodysplit`, `h1case`, `http1.0`).
  - `h2Permutations`: 11 named, all literally H2-specific (`h2colon`, `h2auth`,
    `h2path`, `h2scheme`, `h2method`, `h2CL`, …) — correctly excluded by the finder
    from the "~90" count and from `adaptability`.
  - `clPermutations`: 17 named (`CL-plus`, `CL-minus`, `CL-pad`, `CL-bigpad`, `CL-e`,
    `CL-dec`, `CL-commaprefix`, `CL-commasuffix`, `CL-expect`, `CL-expect-obfs`,
    `CL-error`, `CL-spacepad`, `CL-byteranges`, `CL-multiform`,
    `CL-deleteMaxforward`, `CL-gzip10`, `CL-dualCL`) — exactly matches the finder's
    named list.
  - Shared(62) + H1(15) + CL(17) = **94** ≈ "~90 permutation techniques" claim
    (H2's 11 correctly excluded). Grepping `register(` as source lines gives 85
    (the 4 char-sweep loops count once each as source lines, times 6 at runtime) —
    self-consistent with the above.
- `getSpecialChars()` (line 466-471): `{0, 9, 11, 12, 13, 127}` — **byte-for-byte**
  matches the finder's note `getSpecialChars() = {0,9,11,12,13,127}`.
- Spot-checked `applyDesync()` transforms named in the candidate's `adaptability`
  field, all confirmed exactly against source (line numbers from `DesyncBox.java`):
  - `gareth1` → `header.replace(":", "\n :")` (line 177) — matches claimed `':' ->
    '\n :'`.
  - `spjunk` → `header.replace(":", " x:")` (line 209, with a code comment
    attributing the technique to "HTTP Request Smuggling in 2020" by Amit Klein) —
    matches claimed `':' -> ' x:'`.
  - `backslash` → `header.replace("-", "\\")` (line 213, same Klein-2020 comment) —
    matches claimed `'-' -> '\\'`.
  - `nel`/`nbsp`/`shy` insert `\u0085`/`\u00A0`/`\u00AD` respectively (lines 216,
    219, 225) — matches claimed NEL/NBSP/SHY insertion.
  - `doublewrapped`, `badsetupCR`, `badsetupLF`, `0dwrap`, `0dspam` all present and
    match the described obs-fold/bad-setup-line/lone-CR family.
- License: `LICENSE` file (fetched) begins `Copyright 2022 PortSwigger Web Security
  / Copyright 2022 James Kettle <james.kettle@portswigger.net> / Licensed under the
  Apache License, Version 2.0` — confirms Apache-2.0 with the exact copyright
  attribution claimed.
- GitHub API root listing confirms the repo bundles `turbo-intruder.jar` (41.5 MB)
  and `bulkScan-all.jar` (1.6 MB) at the repo root; `GET
  /repos/PortSwigger/http-request-smuggler` returns `"license": {"key": "other",
  "spdx_id": "NOASSERTION", ...}` — confirms the finder's specific claim that
  GitHub's own license detector reports NOASSERTION because of the bundled jars,
  even though the repo's own `LICENSE` file is plain Apache-2.0.
- `resources/` listing (GitHub API) confirms `CL-TE.py`, `TE-CL.py`, `H2-TE.py`,
  `H2-TUNNEL.py` exist exactly as cited.

**Verdict: NOT REFUTED.** Tier 2 is fair — unlike candidate 1's flat Python dict,
this data is interleaved as Java `switch`-case logic across a 480-line file mixed
with H1/H2/CL bucket registration, genuinely harder to extract cleanly. The `~90`
figure is accurate once H2-only entries (correctly) are excluded. Extraction effort
estimate: **~8-12 hours** — reading and transcribing ~94 case arms of
`applyDesync()` plus the CL-mutation logic (which is spread across separate
methods not shown in the excerpt above and would need full-file review) into
Scheme, with care to exclude the H2 bucket and probe-payload machinery that's
irrelevant to a byte-stream corpus.

---

## 3. `rfc9112-framing-checklist` — RFC 9112 §11 + §6.3

**URL:** https://www.rfc-editor.org/rfc/rfc9112.html (fetched directly)

This is the normative specification itself, not a third-party corpus, so there is
little to "refute" — I instead verified every specific rule/subsection the finder
cited was accurately summarized and not fabricated or mis-numbered:

- §6.3 rule 1: HEAD / 1xx / 204 / 304 responses have no body — confirmed.
- §6.3 rule 2: 2xx response to CONNECT → tunnel, CL/TE on that response must be
  ignored — confirmed.
- §6.3 rule 3: TE present with CL present → TE governs; "An intermediary that
  chooses to forward the message MUST first remove the received Content-Length
  field and process the Transfer-Encoding" — confirmed near-verbatim.
- §6.3 rule 5 (finder's "invalid Content-Length with no TE is unrecoverable"): "the
  server MUST respond with the 400 (Bad Request) status code and then close the
  connection" — confirmed.
- §6.3 rule 7 ("neither TE nor CL → zero-length body"): "If this is a request
  message and none of the above are true, then the message body length is zero" —
  confirmed.
- §11.1 Response Splitting, §11.2 Request Smuggling, §11.3 Message Integrity (not
  literally "truncation" but the finder's gloss — truncation/EOF handling and
  transport error detection — is a fair paraphrase of what §11.3 actually covers),
  §11.4 Message Confidentiality — all four subsection topics confirmed correctly
  attributed to their numbers.

**Verdict: NOT REFUTED.** Correctly scoped as "quote, don't vendor" (IETF Trust
license). This is the rubric the other five corpora's expected-verdicts should be
checked against, exactly as the finder proposes. Zero extraction effort — it is
prose to cite in `.plans/decisions/`, not data to port.

---

## 4. `slowhttptest` — shekyan/slowhttptest

**URL:** https://github.com/shekyan/slowhttptest
**Fetched:** `README.md` (via WebFetch), `LICENSE` (via curl), GitHub API root +
`ng/` listing, and local `brew info slowhttptest` (metadata query only — **not
installed**, per the task's instruction not to mutate anything and my own
obligation not to download/execute untrusted binaries).

- `LICENSE` file begins `Apache License / Version 2.0` — confirmed.
- README confirms classic flags `-H` (slow headers), `-B` (slow body), `-R`
  (range), `-X` (slow read), and states explicitly the tool is for testing systems
  you own / have permission to test — matches the finder's note.
- `ng/` directory exists with a modern C++ rewrite; its README additionally
  advertises `--chunked`, `--expect-continue`, `--slow-tls`, plus (not mentioned by
  the finder, and genuinely out of scope for us) `--slow-quic` and HTTP/2-specific
  attacks (rapid reset, CONTINUATION flood) — the finder's chosen subset
  (`--chunked`, `--expect-continue`, slow-tls) is accurate and correctly omits the
  H2/QUIC-only additions.
- `brew info slowhttptest` (local Homebrew query, no install performed): `stable
  1.10.0 (bottled) ... License: Apache-2.0` — matches the finder's note "brew
  stable 1.10.0" exactly.

I also checked the architecture doc's relevance claim: `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md`
does define a `limits.sls` module (line 347, repeated at line 800) with header/idle/body
timeout fields (lines 574-576) and a numbered build-order roadmap where step 10 is
"keep-alive / limits / timeouts" and step 11 is "body streaming / backpressure"
(lines 743-746). The finder's note cites this as "section 11 (limits.sls)" — that's
a **minor mis-citation**: `limits.sls` (with its timeout fields) most directly maps
to roadmap step 10, while step 11 is backpressure specifically; both are germane to
slowhttptest, so this doesn't change the relevance verdict, just a citation nit.

**Verdict: NOT REFUTED.** Correctly scoped as "invoke, don't vendor" / tier 2 /
`make test-slow`, not part of the sans-I/O replay suite. No extraction effort in
the "port to Scheme" sense — cost is CI plumbing (~2-3 hours to wire a `make
test-slow` target that starts the server and shells out to the installed binary,
skipping if unavailable per the project's own GNU-timeout-absence convention).

---

## 5. `haproxy-vtc-reg-tests` — haproxy reg-tests/http-messaging

**URL:** https://github.com/haproxy/haproxy
**Files fetched (saved to `scratchpad/research/haproxy-vtc/`):**
- `reg-tests/http-messaging/http_transfer_encoding.vtc` (350 lines)
- `reg-tests/http-messaging/h2_desync_attacks.vtc` (177 lines)
- `reg-tests/http-messaging/h1_request_target_validation.vtc` (115 lines)
- `reg-tests/http-messaging/truncated.vtc` (108 lines)
- `reg-tests/http-messaging/h1_to_h1.vtc` (305 lines)
- `LICENSE` (root) and GitHub API repo metadata

**Counts** (`grep -c "^client c"` / `grep -c "expect resp.status"`):
- `http_transfer_encoding.vtc`: **19** client blocks, **22** `expect resp.status`
  lines — matches "19 client blocks / 22 status expectations" exactly.
- `h1_request_target_validation.vtc`: **13** client blocks — matches "13 cases"
  exactly.
- `h2_desync_attacks.vtc`: **6** client blocks — matches "6 clients" exactly.

**Spot-checked content claims:**
- `Transfer-Encoding: chunked, chunked` → `expect resp.status == 400` (client c6,
  line 234) — confirmed.
- `Transfer-Encoding: gzip, chunked` → `expect resp.status == 422` (client c10,
  line 265), while `chunked, gzip, chunked` and `chunked, gzip` and bare `gzip` all
  → 400 (clients c7/c8/c9) — confirms the finder's specific claim (`chunked,chunked
  -> 400 and gzip,chunked -> 422`) including the fact that operand *order* changes
  the expected status, which the finder got exactly right.
- `h1_request_target_validation.vtc`: `OPTIONS *` → 200 (c1), absolute-form
  `OPTIONS http://haproxy.org` → 200 (c3), `CONNECT haproxy.org:80` (authority-form)
  → 200 (c6) vs. `CONNECT /` → 400 (c8), `GET *` → 400 (c5), bare `GET admin` → 400
  (c13) — all confirmed against source, matching the finder's covers list exactly.
- License: root `LICENSE` file confirms GPL-2.0 core with LGPL applied to the
  exportable headers, and explicitly states the added OpenSSL linking exception
  ("This program is released under the GPL with the additional exemption that
  compiling, linking, and/or using OpenSSL is allowed") — matches "GPL-2.0 with
  LGPL headers + OpenSSL exception" exactly. GitHub API also reports
  `"license":{"spdx_id":"NOASSERTION"}` for this repo (dual-license text isn't
  machine-classifiable), consistent with "Do NOT vendor into a BSD-3 repo."
- Verified the Varnish-archival claim, which is unusual enough (a specific 2026
  date) that I checked it independently rather than trusting the finder:
  `github.com/varnishcache/varnish-cache` (fetched directly) now shows an archive
  banner "This repository was archived by the owner on Feb 16, 2026. It is now
  read-only" with "New location: https://code.vinyl-cache.org/vinyl-cache/vinyl-cache",
  and a web search corroborates the org-wide archival and rebrand to "Vinyl Cache."
  The finder's note is accurate.

**One relevance nuance I found (partial pushback, not a refutation):** two of the
five cited files test **H2-frontend-to-H1-backend gateway desync**, a topology that
presupposes HAProxy translating an H2 client connection into an H1 backend
connection:
- `h2_desync_attacks.vtc`'s own docstring: "ensures that h2 requests with invalid
  pseudo-headers are properly rejected... the host header must be ignored if
  authority is present... to avoid http/2 desync attacks" — this scenario (H2
  `:authority` pseudo-header vs. H1 `Host` header disagreement) cannot arise for
  our target: chez-http-server is a standalone HTTP/1.1 origin server, never an
  H2-terminating gateway, so there is no `:authority` to disagree with `Host` in
  the first place.
- `truncated.vtc`'s docstring: "HTTP response size tests: H2->H1 (HTX and legacy
  mode)" — its body is chunked-response pacing/delay tests (`chunkedlen 815` /
  `delay 0.05` repeated) exercising HAProxy's own H2↔H1 translation buffering, not
  parser or connection-semantics edge cases a standalone H1 server would hit.
- By contrast `h1_to_h1.vtc` (which I also read, lines 1-40) is squarely on-target:
  plain H1 GET/POST request/response body-length assertions with no H2 involvement.

I recommend the synthesis agent narrow `corpus_paths` for this candidate to
`http_transfer_encoding.vtc`, `h1_request_target_validation.vtc`, and
`h1_to_h1.vtc`, and drop `h2_desync_attacks.vtc` / `truncated.vtc` as out-of-scope
for a standalone HTTP/1.1 origin server (they test HAProxy's own gateway-mode
protocol translation, not anything our server does). This doesn't change the
overall tier or refute the candidate — the three retained files are all
independently confirmed valuable — but it does shrink the useful surface from "5
files" to "3 files."

**Verdict: NOT REFUTED** (with the `corrected_paths` narrowing above). Tier 3
(reference-and-reimplement, never vendor, given GPL-2.0) is correct. Extraction
effort for the 3 retained files: **~6-10 hours** of manual transcription (VTC
`txreq`/`rxresp`/`expect` blocks are simple enough to hand-translate to raw byte
streams + expected status, but there are 19+13+"a dozen or so" `h1_to_h1.vtc`
client blocks to go through one at a time, and the VTC macros like
`${h1_fe1_sock}` need to be understood before disregarding them).

---

## 6. `regilero-httpwookiee` — HTTPWookiee smuggling stress tests

**URL:** https://github.com/regilero/HTTPWookiee
**Files fetched (saved to `scratchpad/research/wookiee-src/`):**
- `httpwookiee/client/tests_chunks.py` (743 lines, **15** `def test_` methods)
- `httpwookiee/client/tests_first_line.py` (753 lines, **21** `def test_` methods)
- `httpwookiee/client/tests_host.py` (212 lines, **4** `def test_` methods)
- `httpwookiee/client/tests_regular.py` (155 lines, **5** `def test_` methods)
- `LICENSE`, and GitHub API repo metadata

All four per-file counts match the finder's breakdown exactly (15/21/4/5, summing
to the claimed "~45 test methods"). `LICENSE` is GPL-3.0 (`GNU GENERAL PUBLIC
LICENSE / Version 3`) — confirmed. GitHub API `pushed_at: "2017-12-02T12:47:26Z"` —
confirms "last pushed 2017-12" and "stale (2017)" exactly, and `"archived": false`
(it's stale but not formally archived, a distinction the finder didn't
overclaim on).

**Spot-checked test method names against the `covers` claims:**
- "chunk + Content-Length mixing" → `test_2010_preflight_chunked_and_content_length`,
  `test_2011_chunked_and_wrong_content_length`,
  `test_2012_preflight_wrong_content_length_and_chunked` — confirmed present.
- "chunk header hidden by NUL / bad EOL variants" →
  `test_2021_chunked_header_hidden_by_NULL`,
  `test_2022/2023/2024_chunked_header_hidden_by_bad_eol_{1,2,3}` — confirmed
  present, and I read `test_2021` in full: it builds a header literally named
  `Transfer-\x00: 42\r\nEncoding` (NUL splitting the header name across what a lax
  parser might treat as two headers) with a nested, differently-framed "second
  request" injected as the chunked body — a genuine smuggling-shaped test, not a
  simple grammar check.
- "chunk-size truncation and overflow with trailers and delayed chunks" →
  `test_2030_chunked_size_truncation`, `test_2040_chunked_size_overflow`,
  `test_2041_chunked_size_overflow_with_trailers`,
  `test_2042_chunked_size_overflow_with_delayed_chunks` — confirmed present.
- "bogus versions (HTTP/0.8, HTTP/-1.0, HTTP/65536.9)" →
  `test_3040_http_65536_9`, `test_3042_http_0_8`, `test_3043_http_minus_1_0` —
  confirmed present (also `test_3041_http_0_9_explicit`,
  `test_3044_http_1_nodigit`, `test_3045_http_version_too_much_digits`, not
  individually named by the finder but consistent with the claimed family).
- Confirmed the finder's characterization that payloads are built
  programmatically (`self.req.add_header(...)`, `self.req.add_chunk(...,
  chunk_size=0)`) rather than stored as flat data — extraction genuinely requires
  understanding the `Request`/`Tools` helper classes' serialization, not just
  reading strings off the page. This validates "reference only," "manual
  transcription," and "medium effort."

**Verdict: NOT REFUTED.** Tier 3 (GPL-3.0, stale, code-not-data) is correct, as is
"low priority." Extraction effort: genuinely **variable per test** since each
method's byte-stream depends on tracing the `Request` class; I'd estimate
**1-2 hours per test worth porting** rather than a single blanket number — for the
"few worth having" (the finder's own scoping), realistically 5-8 of the 45 tests
(the NUL-splitting and chunk-overflow-with-trailers ones look like the highest
signal), so **~6-12 hours** total, not 45× that.

---

## Overall assessment (skeptic's summary)

I went into this expecting to find at least one inflated count, mis-cited license,
or "parser-only" case mislabeled as connection-semantics, since that's the
per-candidate failure mode the task is watching for. I did not find one. Every
numeric claim I checked — 134/966/668 for defparam/smuggler, 19/22, 13, 6 for the
haproxy VTCs, 15/21/4/5 for HTTPWookiee, the exact `getSpecialChars()` byte set and
several literal `applyDesync()` transform bodies for PortSwigger's tool, the exact
Homebrew version string for slowhttptest, and the (surprisingly specific,
independently re-verified) Varnish-archival date — turned out to be exactly
correct on inspection of the primary source. Every license claim (MIT with the
named 2020 copyright holder, Apache-2.0 with the NOASSERTION-via-bundled-jar
nuance, GPL-2.0-with-OpenSSL-exception, GPL-3.0) also checked out exactly against
the repos' own LICENSE files and the GitHub API's license field.

The one substantive pushback I have is on candidate 5 (haproxy-vtc-reg-tests):
2 of its 5 cited files test HAProxy's own H2-frontend/H1-backend gateway-translation
behavior, which cannot occur in a standalone HTTP/1.1 origin server (no H2, no
`:authority` pseudo-header, no gateway role) — I recommend narrowing
`corpus_paths` to the 3 files that are genuinely about H1 semantics
(`http_transfer_encoding.vtc`, `h1_request_target_validation.vtc`,
`h1_to_h1.vtc`), while agreeing the candidate as a whole is not refuted. I also
flagged a minor mis-citation in candidate 4's architecture-doc section reference
(limits.sls maps to roadmap step 10, not 11) that doesn't affect the verdict.

None of the six is HTTP/2-only, client-only-with-no-extractable-data, or
redundant with the llhttp corpus we already have (I checked the llhttp corpus
directly for candidate 1's specific claim and confirmed llhttp covers only ~3 of
smuggler's ~1768 combined TE-obfuscation cases). I am not refuting any candidate.
