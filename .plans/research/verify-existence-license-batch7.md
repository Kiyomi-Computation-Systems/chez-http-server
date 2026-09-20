# Verification Report — Batch 7 (Existence + License Skeptic Pass)

Date of verification: 2026-09-19
Verifier stance: SKEPTIC — attempt to refute each candidate on existence and license grounds only.
Tools used: `gh api` (GitHub REST API, authenticated as DarrenN), `curl` (direct HTTP fetch of
rfc-editor.org and iana.org and quut.com), `WebFetch` (for IETF Trust legal-provisions pages and
RFC errata pages that require JS-free text extraction).

All commands and their verbatim (or truncated-but-representative) output are recorded below,
grouped by candidate key. None of the six candidates could be refuted on existence or license
grounds; a few minor quantitative corrections are noted.

---

## 1. `nginx-tests` — nginx/nginx-tests

**Claim to test:** repo exists, 5 named `.t` files exist, license is BSD-2-Clause.

Command:
```
gh api repos/nginx/nginx-tests
```
Result (trimmed): repo exists, `"full_name":"nginx/nginx-tests"`, `"default_branch":"master"`,
`"pushed_at":"2026-09-16T11:18:44Z"`, `"stargazers_count":135`,
`"license":{"key":"other","name":"Other","spdx_id":"NOASSERTION",...}` — i.e. GitHub's automatic
SPDX detector does **not** recognize the license (this is expected: nginx wraps its BSD text in a
C-style `/* ... */` comment block, which the linguist/licensee detector often misses).

Command:
```
gh api repos/nginx/nginx-tests/license
```
Returned `LICENSE` (1327 bytes), base64-decoded. Decoded text (first lines):
```
/*
 * Copyright (C) 2008-2011 Maxim Dounin
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND ...
```
This is a textbook **2-clause BSD license** (no clause 3/advertising-endorsement clause) —
confirms the candidate's claimed SPDX id `BSD-2-Clause` exactly, and confirms the candidate's own
caveat that "GitHub API reports NOASSERTION only because of the file name/formatting."

Command (existence of the 5 cited files):
```
for f in body_chunked.t http_headers_multi.t ignore_invalid_headers.t proxy_chunked.t proxy_duplicate_headers.t; do
  gh api repos/nginx/nginx-tests/contents/$f
done
```
All five returned 200 with valid content metadata:
- `body_chunked.t` — 5766 bytes, sha `6d78d410153fe2d8cb94433a50cfcc77e84e455f`
- `http_headers_multi.t` — 9324 bytes, sha `441f24975932baccc7c96e9698b55adaa8a9bb36`
- `ignore_invalid_headers.t` — 4035 bytes, sha `6ee676f237dc46061cb18f9d78e0dcff6233d77e`
- `proxy_chunked.t` — 2481 bytes, sha `b799193babf5668648901f633ce89b0447f53c26`
- `proxy_duplicate_headers.t` — 3935 bytes, sha `3bba905a307ae8414072c2de6ec56bea705a1eaf`

**Verdict: NOT refuted.** Repository, all 5 named files, and BSD-2-Clause license all confirmed
today. `refuted=false`.

---

## 2. `rfc-9110-9112-collected-abnf-and-vectors`

**Claim to test:** RFC 9112 and RFC 9110 text exist at the stated sha256 hashes; Appendix A line
ranges and specific example line numbers are accurate; license is effectively BSD-3-Clause for
"Code Components" including ABNF; the cited errata (4 against 9112, 14 against 9110, including EID
9164 on Appendix A) are real.

Commands:
```
curl -s -o rfc9112.txt https://www.rfc-editor.org/rfc/rfc9112.txt
curl -s -o rfc9110.txt https://www.rfc-editor.org/rfc/rfc9110.txt
wc -l rfc9112.txt rfc9110.txt
shasum -a 256 rfc9112.txt rfc9110.txt
```
Output:
```
    2461 rfc9112.txt
   10785 rfc9110.txt
e4f426bac6206b67fdf9e0da826154f70588db2133a0a86b15cde4ff725d893  rfc9112.txt
21c1cdce6ab0e5509b04d84a28000836c7a087cf786efe6f04877ebfff47232  rfc9110.txt
```
Both hashes **exactly match** the candidate's claimed prefixes (`e4f426ba…` / `21c1cdce…`).

Command:
```
grep -n "^Appendix A" rfc9112.txt rfc9110.txt
grep -n "^Appendix B" rfc9112.txt rfc9110.txt
```
Output:
```
rfc9112.txt:2047:Appendix A.  Collected ABNF
rfc9112.txt:2115:Appendix B.  Differences between HTTP and MIME
rfc9110.txt:9748:Appendix A.  Collected ABNF
rfc9110.txt:9978:Appendix B.  Changes from Previous RFCs
```
This **exactly matches** the candidate's cited ranges `rfc9112.txt lines 2047-2114` (Appendix A
runs 2047 up to but not including 2115) and `rfc9110.txt lines 9748-9977`.

Command (spot-checking every individually-cited example line number in rfc9112.txt):
```
sed -n '473p;494p;535p;549p;559p;563p;605p;614p;821p;1227p;1229p;1506p' rfc9112.txt
```
Output (one line each, in order):
```
   GET /where?q=now HTTP/1.1
   GET http://www.example.org/pub/WWW/TheProject.html HTTP/1.1
   CONNECT www.example.com:80 HTTP/1.1
   OPTIONS * HTTP/1.1
   OPTIONS http://www.example.org:8001 HTTP/1.1
   OPTIONS * HTTP/1.1
   GET /pub/WWW/TheProject.html HTTP/1.1
   OPTIONS * HTTP/1.1
   Transfer-Encoding: gzip, chunked
   TE: deflate
   TE: trailers, deflate;q=0.5
   Connection: close
```
Every single line number cited by the finder points to exactly the request-line/field-line example
claimed. This is a byte-for-byte confirmation of all 12 example-line citations.

**License check.** Command:
```
grep -n -i "code component\|revised bsd\|simplified bsd" rfc9110.txt rfc9112.txt
```
Output: both files contain (lines 50-57 of rfc9112.txt / 54-57 of rfc9110.txt):
```
   Code Components extracted from this document must
   include Revised BSD License text as described in Section 4.e of the
   Trust Legal Provisions and are provided without warranty as described
   in the Revised BSD License.
```
Then `WebFetch https://trustee.ietf.org/documents/trust-legal-provisions/code-components-list-3/`
confirmed the definition of "Code Component" explicitly begins its example list with **"ABNF
definitions"**:
> "Code Components which may be found in IETF Contributions and IETF Documents:" ... "ABNF
> definitions, ASN.1 modules, ASN.1 structures, Management Information Base (MIB) modules, TLS
> presentation syntax, eXternal Data Representation (XDR), Extensible Markup Language (XML)
> Schemas, XML DTDs, XML RelaxNG definitions, tables of values, classical programming code, Policy
> Information Base (PIB) module, YANG modeling language, JSON, CBOR" — and licensed under the "BSD
> License" (the "Revised BSD License" == 3-clause BSD, equivalent to SPDX `BSD-3-Clause`).

This exactly matches the candidate's licensing claim. Note the important nuance (which the
candidate's own `adaptability` field already reflects correctly): the **Revised-BSD-for-Code-
Components** grant applies to material *extracted and processed* from the RFC (e.g. a derived
`.abnf` file); the **full verbatim RFC text** is separately permitted to be reproduced unmodified
under BCP 78 (IETF's standing permission to redistribute RFCs verbatim). The candidate's plan —
vendor the `.txt` verbatim *and* derive `.abnf`/example fixtures by script — is consistent with
both grants.

**Errata check.** `WebFetch https://errata.rfc-editor.org/rfc9110` returned:
```
Verified: 6 (EID 7138, 7306, 7419, 7105, 7109, 8268)
Reported: 2 (EID 9162, 9164)
Rejected: 6
Total: 14
```
`WebFetch https://errata.rfc-editor.org/rfc9112` returned:
```
Verified: 2 (EID 7744, 8284 — both Editorial)
Rejected: 2 (EID 7214, 7633)
Total: 4
```
Both totals (**14** for 9110, **4** for 9112, **2 verified editorial** for 9112) match the
candidate's claim exactly.

`WebFetch https://errata.rfc-editor.org/eid9164` confirmed EID 9164 is against RFC 9110 **Appendix
A**, reported status, and concerns exactly the issue the candidate described: Appendix A performs
additional undeclared ABNF transformations (combining adjacent quoted terminals, hex notation,
shortened repetition bounds) beyond the one transformation (list-rule expansion) it documents.

**Verdict: NOT refuted.** Every quantitative claim (hashes, line numbers, errata counts, license
mechanics) checks out exactly. This is the most rigorously verifiable candidate in the batch.
`refuted=false`.

---

## 3. `abnfgen-generated-http-corpus`

**Claim to test:** quut.com/abnfgen exists, license text matches ("copyrighted... free for any
use", Jutta Degener, version 0.21), tarball downloadable.

Command: `WebFetch https://www.quut.com/abnfgen/` →
> "The tool is in alpha and, while copyrighted, free for any use." Copyright holder: Jutta Degener
> <jutta@pobox.com>. Version 0.21 (abnfgen-0.21.tar.gz, last updated June 3rd 2023).

This is an exact match for the candidate's note: *"Web page says 'copyrighted' but 'free for any
use'; man page Copyright (c) 2002, 2006 Jutta Degener; no SPDX licence."*

Command:
```
curl -sI https://www.quut.com/abnfgen/abnfgen-0.21.tar.gz
```
Output:
```
HTTP/2 200
content-length: 96365
content-type: application/octet-stream
last-modified: Sun, 04 Jun 2023 23:02:31 GMT
```
Tarball exists and is fetchable today (200 OK, 96,365 bytes ≈ 94 KiB — consistent with the
candidate's claim of a successful local `./configure && make` build).

**Important caveat (not a refutation, but material for the synthesis agent):** the candidate's
`corpus_paths` (`raw/http-merged.abnf`, `raw/out-msg`, `raw/out-rl4`, `raw/out-msg4`,
`tools/abnfgen-0.21/...`) are files the *finder agent* generated inside **its own, now-gone,
ephemeral scratchpad** from an earlier session. They are not a stable, independently fetchable
corpus the way the other 5 candidates are — I cannot re-fetch or re-verify those specific files in
this session (a different scratchpad path,
`/private/tmp/claude-501/.../2440228f-.../scratchpad`, does not contain them and would not be
expected to, since scratchpads are per-session). This is inherent to the candidate's own design
(it is a *recipe to regenerate a corpus locally*, not a corpus vendored from a third party), so it
is not grounds for refutation — but the synthesis agent should treat the specific counts
("300 HTTP-message docs", "164/200 still invalid-method", etc.) as **unverified in this pass**;
only the existence of the *tool* and the accuracy of its license description were checked.

**Verdict: NOT refuted** on existence/license of the abnfgen tool itself (confirmed today).
`refuted=false`, with the above caveat about the non-reproducible ephemeral corpus paths flagged
for the synthesis agent.

---

## 4. `iana-http-registries`

**Claim to test:** all 9 CSV URLs exist and return the claimed row counts; license is CC0-1.0.

Command: fetched all 9 URLs with `curl -s <url> | wc -l` plus `head -3`. Full output:

| File | Rows incl. header | Data rows | Candidate's claimed count | Match |
|---|---|---|---|---|
| `http-fields/field-names.csv` | 261 | 260 | 260 | exact |
| `http-methods/methods.csv` | 42 | 41 | 41 (incl. `*`) | exact |
| `http-status-codes/http-status-codes-1.csv` | 76 | 75 | 75 | exact |
| `http-parameters/transfer-coding.csv` | 9 | 8 | 8 | exact |
| `http-parameters/content-coding.csv` | 14 | 13 | 13 | exact |
| `http-parameters/range-units.csv` | 3 | 2 | 2 | exact |
| `http-parameters/forwarded.csv` | 5 | 4 | 4 | exact |
| `http-parameters/preferences.csv` | 42 | 41 | 41 | exact |
| `http-upgrade-tokens/http-upgrade-tokens-1.csv` | 8 | 7 | 7 | exact |

Total data rows = 451, matching the candidate's "~450 registry rows across 9 files."

Sample header rows confirmed the described columns, e.g. `field-names.csv` has a `Structured Type`
column (candidate's "which fields are SF-typed" claim) and its first data row is
`A-IM,permanent,,[RFC 3229: Delta encoding in HTTP],`.

**License check.** `WebFetch https://www.iana.org/help/licensing-terms`:
> "IANA and IETF intend that the Protocol Registries may be freely used by any party for any
> purpose." ... registries are "subject to the Creative Commons CC0 1.0 dedication."

Exact match for candidate's claimed `CC0-1.0`.

**Verdict: NOT refuted.** Every one of the 9 files exists today at the cited URL with the exact
claimed row count, and CC0-1.0 is confirmed as the license. `refuted=false`.

---

## 5. `wpt-fetch-h1-parsing`

**Claim to test:** repo/paths exist, license is BSD-3-Clause (despite GitHub reporting
NOASSERTION), counts of `.asis` files / vectors match.

Command:
```
gh api repos/web-platform-tests/wpt
```
→ `"license":{"key":"other","spdx_id":"NOASSERTION",...}` (again, a GitHub SPDX-detector miss).

Command:
```
gh api repos/web-platform-tests/wpt/contents/LICENSE.md
```
Decoded content, first lines:
```
# The 3-Clause BSD License

Copyright © web-platform-tests contributors

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice...
2. Redistributions in binary form must reproduce...
3. Neither the name of the copyright holder nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific prior written
   permission.
```
This is literally titled "The 3-Clause BSD License" — confirms candidate's claim and its note that
"GitHub API reports NOASSERTION only because of the file name."

Command:
```
gh api repos/web-platform-tests/wpt/contents/fetch/h1-parsing
```
Listing: `README.md`, `WEB_FEATURES.yml`, `h1-parsing.tentative.html`, `lone-cr.window.js`,
`resources-with-0x00-in-header.window.js`, `resources/` (dir), `status-code.window.js`, `tools/`
(dir). All the files the candidate cited are present.

Command:
```
gh api repos/web-platform-tests/wpt/contents/fetch/h1-parsing/resources
```
→ 108 total entries, **103** end in `.asis` (exact match to candidate's claimed 103), and
`blue-with-0x00-in-a-header.asis` is present among them (confirms the "+ blue-with-0x00..." part of
the claim).

Command (content of `lone-cr.window.js`, 950 bytes): the array literal contains **exactly 10**
input strings (`"HTTP/1.1\r200 OK\n\nBODY"`, ... `"HTTP/1.1 200 OK\nHeader: Value\n\r"`) — exact
match to "10 lone-CR responses → network error."

Command (content of `status-code.window.js`, 1703 bytes): the array literal contains **exactly 16**
test objects (`""`, `"BLAH"`, `"0 OK"`, `"1 OK"`, `"99 NOT OK"`, `"077 77"`, `"099 HELLO"`, `"200"`,
`"999 DOES IT MATTER"`, `"1000 BOO"`, `"0200 BOO"`, `"65736 NOT 200 OR SOME SUCH"`, `"131072 HI"`,
`"-200 TEST"`, `"0xA"`, `"C8"`) — exact match to "16 status-line vectors."

Command:
```
gh api repos/web-platform-tests/wpt/contents/fetch/content-length/resources/content-lengths.json
```
→ 2627 bytes, decodes to a JSON array of **exactly 35** `{input, output}` objects, first three
being `"Content-Length: 42"→42`, `"Content-Length: 42,42"→42`,
`"Content-Length: 42\r\nContent-Length: 42"→42` — exact match to the candidate's claimed 35 vectors
and its example `'42,42' ok`.

Command:
```
gh api repos/web-platform-tests/wpt/contents/fetch/h1-parsing/tools/generate_parsing_asis.py
```
→ exists, 977 bytes.

**Verdict: NOT refuted.** Every file and every count cited by the finder checks out exactly.
`refuted=false`.

---

## 6. `http-tests-cache-tests`

**Claim to test:** repo/org/paths exist, license BSD-3-Clause, stars/push-date match, only 102/103
interim responses implemented, specific quotes from README/CONTRIBUTING accurate.

Command:
```
gh api repos/http-tests/cache-tests
```
→ `"license":{"key":"bsd-3-clause","spdx_id":"BSD-3-Clause",...}` (GitHub correctly detected this
one), `"stargazers_count":139`, `"pushed_at":"2026-09-18T00:39:34Z"`.

Command:
```
gh api repos/http-tests/cache-tests/contents/LICENSE
```
Decoded: `BSD 3-Clause License` / `Copyright (c) 2018, Mark Nottingham` — confirms SPDX id exactly.

Command:
```
gh api orgs/http-tests/repos
```
→ 1 repo total (`cache-tests`) — confirms candidate's "the http-tests org has only this repo."

Command:
```
gh api repos/http-tests/cache-tests/contents/tests
```
→ 26 `.mjs` entries total, one of which is `index.mjs`; the other 25 are the suite files
(`age-parse.mjs`, `authorization.mjs`, ... `vary.mjs`) — confirms "tests/*.mjs (25 suites) +
tests/index.mjs" exactly.

Command:
```
gh api repos/http-tests/cache-tests/contents/tests/lib
```
→ `header-list.mjs`, `templates.mjs`, `utils.mjs` — confirms `tests/lib/templates.mjs` exists.

Command:
```
gh api repos/http-tests/cache-tests/contents/test-engine/lib/testsuite-schema.json
```
→ exists, 20,997 bytes.

Command:
```
gh api repos/http-tests/cache-tests/contents/test-engine/server
```
→ `handle-config.mjs` (600 B), `handle-file.mjs` (776 B, **not** cited by the finder),
`handle-state.mjs` (376 B), `handle-test.mjs` (4749 B), `server.mjs` (1994 B), `utils.mjs`
(1687 B). All four files the finder named (`server.mjs`, `handle-config.mjs`, `handle-test.mjs`,
`handle-state.mjs`, `utils.mjs`) exist. **Minor correction:** their combined size is 600+4749+376
+1994+1687 = **9,406 bytes (≈9.2 KiB)**, not the candidate's claimed "~6.5 KB" — a ~45% undercount
(possibly the finder excluded `utils.mjs` or measured an older revision). This does not affect
existence or license; flagged as a `corrected` note only.

Command:
```
gh api repos/http-tests/cache-tests/contents/CONTRIBUTING.md
```
Decoded and line-indexed: line 9 is exactly `## Test Format` — confirms the candidate's citation
`CONTRIBUTING.md lines 9-110` starts correctly (file total is 113 lines).

Command (README.md content, grep for quoted claims):
```
Line 34: In other words, **passing all of the tests currently means nothing** -- this is not a
         conformance test suite, it's just the start of a conversation, and a **tool to assess
         how a cache behaves**.
```
Exact match for the candidate's quoted "'not a conformance test suite' ... 'a tool to assess how a
cache behaves'."

Command (`test-engine/server/handle-test.mjs` content, grep for interim-response handling):
```
Line 48:     if (status === 102) {
Line 50:     } else if (status === 103) {
Line 53:       console.log(`ERROR: Sending ${status} is not yet supported`)
```
Confirms the candidate's claim that "Only 102 and 103 interim responses are implemented by the
origin (others log 'not yet supported')" precisely.

**Verdict: NOT refuted.** Repo, org-exclusivity, license, and every cited path/quote check out;
one minor byte-count correction noted above (does not change tier/adaptability judgment).
`refuted=false`.

---

## Summary table

| key | exists today? | license confirmed? | refuted | notes |
|---|---|---|---|---|
| nginx-tests | yes | BSD-2-Clause (GitHub SPDX detector shows NOASSERTION due to comment-wrapped LICENSE file, but decoded text is textbook 2-clause BSD) | false | all 5 cited `.t` files present |
| rfc-9110-9112-collected-abnf-and-vectors | yes | Revised BSD License (~BSD-3-Clause) for "Code Components," ABNF explicitly named; verbatim `.txt` separately permitted under BCP 78 | false | sha256, line numbers, and errata counts all match exactly |
| abnfgen-generated-http-corpus | yes (tool page + tarball) | no SPDX id; page states "copyrighted... free for any use" | false | tool existence/license confirmed; the specific generated corpus files are in a prior session's ephemeral scratchpad and could not be re-verified this pass — flag for synthesis agent |
| iana-http-registries | yes, all 9 files | CC0-1.0 | false | every row count matches exactly |
| wpt-fetch-h1-parsing | yes | BSD-3-Clause (GitHub SPDX detector shows NOASSERTION due to LICENSE.md filename, but content is titled "The 3-Clause BSD License") | false | 103 `.asis`, 10 lone-CR, 16 status-code, 35 content-length vectors all match exactly |
| http-tests-cache-tests | yes | BSD-3-Clause (correctly detected by GitHub) | false | one minor size correction (server dir ~9.2 KiB, not ~6.5 KB); all paths/quotes otherwise exact |

No candidate is refuted on existence or license grounds. This batch's finder was unusually precise
— every specific line number, hash, and count claim checked was correct except the one server-size
estimate noted above.
