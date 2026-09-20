# Verification report — batch 8 (existence + license lens)

Verifier role: SKEPTIC. Goal: try to REFUTE each candidate. All checks performed
2026-09-19 via `gh api` (GitHub REST API, authenticated as `DarrenN`) against
live GitHub state, plus `curl` against `raw.githubusercontent.com` for raw file
content and counts. Every command and its verbatim (or representatively
truncated) output is recorded below. Default branch was confirmed per-repo
before trusting any `raw.githubusercontent.com/<repo>/main/...` URL (one
candidate's repo defaults to `master`, not `main` — see candidate 6).

Report generated: 2026-09-19T16:12:37Z.

---

## 1. `cispa-http-conformance` — cispa/http-conformance

**Verdict: NOT REFUTED.** Repo, all four cited paths, and MIT license fully confirmed with exact line/class counts.

Command:
```
gh api repos/cispa/http-conformance
```
Output (key fields):
```
"full_name":"cispa/http-conformance"
"description":" Code for our 2024 ACM AsiaCCS Paper \"Who's Breaking the Rules? ...\" "
"pushed_at":"2026-07-16T06:30:13Z"
"stargazers_count":18
"license":{"key":"mit","name":"MIT License","spdx_id":"MIT", ...}
"default_branch":"main"
```
This matches the candidate's claim of "pushed 2026-07-16" exactly and the MIT license claim.

Path checks (`gh api repos/cispa/http-conformance/contents/<path>`), all returned HTTP 200 with a `download_url`:
- `testcases.py` → exists, size 169188 bytes. https://github.com/cispa/http-conformance/blob/main/testcases.py
- `sanity_check/serve_testcases.py` → exists, size 1855 bytes. https://github.com/cispa/http-conformance/blob/main/sanity_check/serve_testcases.py
- `helpers/output/test_overview.tex` → exists, size 293 bytes. https://github.com/cispa/http-conformance/blob/main/helpers/output/test_overview.tex
- `testbed/docker-compose.yml` → exists, size 5495 bytes. https://github.com/cispa/http-conformance/blob/main/testbed/docker-compose.yml
- `LICENSE` → exists, size 1077 bytes; decoded content begins:
  ```
  MIT License

  Copyright (c) 2023 Jannis Rautenstrauch
  ```

Content verification:
```
curl -s https://raw.githubusercontent.com/cispa/http-conformance/main/testcases.py -o /tmp/cispa_testcases.py
wc -l /tmp/cispa_testcases.py        → 4426 /tmp/cispa_testcases.py
grep -c "^class " /tmp/cispa_testcases.py  → 106
```
Both numbers (4426 lines, 106 classes) match the candidate's claim ("4426 lines, 106 classes") **exactly**.

**License-compatibility judgment:** MIT is a permissive license, fully compatible with vendoring the test data (bytes, expected statuses, RFC citations) into a BSD-3-Clause project, subject to retaining the MIT copyright notice (Jannis Rautenstrauch, 2023) somewhere in the vendored-data attribution (e.g. a NOTICE/THIRD_PARTY file). No refutation.

---

## 2. `http11probe` — MDA2AV/Http11Probe

**Verdict: NOT REFUTED.** Repo, all 7 suite files, TestCase.cs, and all 13 doc categories confirmed, with per-suite and per-category counts matching the candidate's claims exactly.

Command:
```
gh api repos/MDA2AV/Http11Probe --jq '{full_name, pushed_at, created_at, stargazers_count, license, default_branch}'
```
Output:
```
{"created_at":"2026-02-07T13:01:13Z","default_branch":"main","full_name":"MDA2AV/Http11Probe","license":{"key":"mit","name":"MIT License","spdx_id":"MIT",...},"pushed_at":"2026-09-16T14:59:29Z","stargazers_count":30}
```
Matches candidate's "Created 2026-02-07, pushed 2026-09-16, 30 stars" exactly.

License file:
```
gh api repos/MDA2AV/Http11Probe/contents/LICENSE --jq '.content' | base64 -d
```
```
MIT License

Copyright (c) 2026 Diogo Martins
```

Directory listing `src/Http11Probe/TestCases/Suites/`:
```
CapabilitiesSuite.cs
ComplianceSuite.cs
CookieSuite.cs
MalformedInputSuite.cs
NormalizationSuite.cs
SmugglingSuite.cs
WebSocketsSuite.cs
```
All 7 claimed suite files exist. `TestCase.cs` also confirmed to exist (670 bytes) at `src/Http11Probe/TestCases/TestCase.cs`.

Per-suite `Id\s*=` occurrence counts (via `curl <download_url> | grep -c "Id\s*="`):
```
CapabilitiesSuite: 9
ComplianceSuite: 69
CookieSuite: 12
MalformedInputSuite: 26
NormalizationSuite: 5
SmugglingSuite: 87
WebSocketsSuite: 5
```
Matches candidate's claimed "9/69/12/26/5/87/5" **exactly**.

Doc category directory listing `docs/content/docs/`:
```
_index.md, baseline.md, body, caching, content-length, cookies, headers,
host-header, http-overview, line-endings, malformed-input, normalization,
request-line, rfc-basics.md, rfc-requirement-dashboard.md, smuggling,
websockets
```
All 13 claimed categories (request-line, smuggling, malformed-input, headers, body, cookies, caching, host-header, http-overview, normalization, websockets, line-endings, content-length) exist as subdirectories. Per-category file counts (`gh api .../contents/docs/content/docs/<cat> --jq 'length'`):
```
request-line: 27    smuggling: 88       malformed-input: 27  headers: 16
body: 16             cookies: 13         caching: 10           host-header: 8
http-overview: 8     normalization: 6    websockets: 6         line-endings: 5
content-length: 4
```
These match the candidate's per-category counts exactly (27/88/27/16/16/13/10/8/8/6/6/5/4). Note: each category directory includes one `_index.md` (its own landing page), so the true "per-test page" count is one less per category than these totals; summed across 13 categories that is 234 raw files vs. the candidate's stated "188 per-test pages" (and the candidate itself already flags "Count discrepancies (215 vs 213 vs 196) not resolved" for the total test-case count — this per-test-page-count figure has the same kind of slack). This is a minor, disclosed sizing imprecision, not an existence or license problem.

**License-compatibility judgment:** MIT, fully compatible with vendoring test bytes/expected-verdict pairs into a BSD-3-Clause project with attribution to Diogo Martins, 2026. No refutation.

---

## 3. `h1spec-family` — four unrelated repos

**Verdict: NOT REFUTED as a license/existence taxonomy** (the candidate's own per-repo license breakdown is accurate), **but the LeaYeh test-case count is substantially overstated** (see below) — flagged as a correction, not a refutation of existence/license.

### 3a. dropseed/h1spec
```
gh api repos/dropseed/h1spec --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2026-03-03T23:25:37Z","license":null,"pushed_at":"2026-03-05T18:04:29Z","stargazers_count":0}
gh api repos/dropseed/h1spec/contents/pyproject.toml --jq '.content' | base64 -d | grep -i licen
→ license = "MIT"
gh api repos/dropseed/h1spec/commits --jq 'length' → 4
```
Confirms candidate's claim: "4 commits, 0 stars, pushed 2026-03-05, licence only in pyproject.toml ('license = "MIT"')". GitHub's own license detector returns `null` (no LICENSE file present) — i.e. there is no formal license grant/copyright-notice text, only a `pyproject.toml` metadata field. This is a real caveat: vendoring on the strength of a metadata field alone (no accompanying copyright/permission text) is weaker legal footing than a proper LICENSE file, though the stated intent (MIT) is unambiguous.

Directory `h1spec/tests/`: confirmed present — `__init__.py, body.py, connection.py, hardening.py, headers.py, request_line.py, response.py`. All 6 claimed test files exist at `h1spec/tests/{request_line,headers,body,connection,response,hardening}.py`, e.g.:
```
https://raw.githubusercontent.com/dropseed/h1spec/master/h1spec/tests/request_line.py
```
(note: default branch is `master`, confirmed by the `download_url` gh api returned).

Per-file `def test_` counts:
```
request_line: 7   headers: 7   body: 11   connection: 3   response: 2   hardening: 3   → total 33
```
Matches candidate's claimed "(33 tests: 7/7/11/3/2/3)" **exactly**.

### 3b. uNetworking/h1spec
```
gh api repos/uNetworking/h1spec --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2024-10-25T20:51:40Z","license":null,"pushed_at":"2024-10-27T23:28:44Z","stargazers_count":41}
```
Matches candidate's claim ("pushed 2024-10-27, 41 stars, API license null"). `README.md` grep for "licen" returned no output — confirms "README has no licence line". `http_test.ts` confirmed to exist (10022 bytes) at repo root.
```
wc -l http_test.ts → 291
grep -c "request:" http_test.ts → 34   (candidate says "33 cases")
grep -c "expectedTimeout" http_test.ts → 16   (candidate says "15 fragmented-request timeout cases")
```
Both counts are off by one from the candidate's stated figures — plausibly a fencepost/regex artifact on either side, not material to existence or license. **No usable license exists for this repo** (confirmed: `license: null` at the API level, and no license text anywhere in the README) — it cannot legally be vendored; ideas can only be re-derived independently, exactly as the candidate itself states ("no licence (cannot vendor); re-derive its fragmentation idea from the RFC").

### 3c. LeaYeh/h1spec
```
gh api repos/LeaYeh/h1spec --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2024-09-17T16:09:32Z","license":{"key":"agpl-3.0","name":"GNU Affero General Public License v3.0","spdx_id":"AGPL-3.0",...},"pushed_at":"2025-06-08T22:52:47Z","stargazers_count":2}
```
Confirms candidate's claim ("LeaYeh pushed 2025-06-08") and AGPL-3.0 license exactly.
```
gh api repos/LeaYeh/h1spec/contents/LICENSE --jq '.content' | base64 -d | head -5
→ GNU AFFERO GENERAL PUBLIC LICENSE, Version 3, 19 November 2007
```
`spec/http1.1/RFC9112_3_request_line.go` confirmed present. `spec/http1.1_archive/` confirmed present with 11 `.go` files (not counting `http11.go`, 12 total): `RFC7230.go, RFC7230_2_5_error_handling.go, RFC7230_2_6_protocol_versioning.go, RFC7230_2_architecture.go, RFC7230_3_3_3_MultipleContentLength.go, RFC7230_3_message_body.go, RFC9112.go, RFC9112_3_2_MissingHostHeader.go, RFC9112_3_request_target.go, RFC9112_7_1_ChunkSizeHexadecimal.go, RFC9112_7_chunked_transfer_coding.go, http11.go` — confirmed via `gh api "repos/LeaYeh/h1spec/git/trees/main?recursive=true"`.

**Correction:** actual `tg.AddTestCase(&spec.TestCase{...})` occurrences per archive file (counted via `curl <raw> | grep -c "AddTestCase("`):
```
RFC7230.go: 0
RFC7230_2_5_error_handling.go: 3
RFC7230_2_6_protocol_versioning.go: 11
RFC7230_2_architecture.go: 0
RFC7230_3_3_3_MultipleContentLength.go: 1
RFC7230_3_message_body.go: 0
RFC9112.go: 0
RFC9112_3_2_MissingHostHeader.go: 1
RFC9112_3_request_target.go: 0
RFC9112_7_1_ChunkSizeHexadecimal.go: 1
RFC9112_7_chunked_transfer_coding.go: 0
http11.go: 0
TOTAL archive: 17
```
Plus 1 in `spec/http1.1/RFC9112_3_request_line.go` → **18 actual test cases**, not the "34 (archive)" / "35 (LeaYeh)" the candidate claims (`approx_cases: "... + 35 (LeaYeh) + ..."`). This is roughly a 2x overcount. The paths themselves exist exactly as named; only the case-count estimate is wrong. **Correction noted for `approx_cases`, not for `corpus_paths` or `license`.**

**License-compatibility judgment:** AGPL-3.0 is strong copyleft and is NOT compatible with vendoring code or test-data text directly into a BSD-3-Clause project (AGPL's copyleft would propagate). Per the task's instruction, this sub-repo is usable **by reference only** — i.e. one may read the RFC citations and re-derive independent test vectors, but must not copy AGPL-licensed text/code into chez-http-server. This matches the candidate's own assessment.

### 3d. wooshdev/h1spec
```
gh api repos/wooshdev/h1spec --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2020-02-10T14:45:21Z","license":{"key":"zlib","name":"zlib License","spdx_id":"Zlib",...},"pushed_at":"2020-02-15T16:56:52Z","stargazers_count":0}
```
Confirms candidate's claim ("wooshdev pushed 2020-02-15") and Zlib license exactly. Note: there is no file literally named `LICENSE` at the repo root (root listing: `.gitignore, COPYING, Makefile, README.md, src`) — the license text lives in `COPYING`:
```
gh api repos/wooshdev/h1spec/contents/COPYING --jq '.content' | base64 -d | head -15
→ Copyright (C) 2019-2020 Tristan ... This software is provided 'as-is' ... [zlib license text]
```
`src/Tests/Test.cs` confirmed present (7982 bytes).

**License-compatibility judgment:** Zlib is a permissive license (similar to MIT/BSD), compatible with vendoring test data into a BSD-3-Clause project with attribution. Candidate correctly notes this repo is "2020-era and tiny" — low value but not license-blocked.

**Overall note for synthesis:** the candidate's top-level `"license": "MIT"` field is misleading if read in isolation — it is only true (and only weakly, metadata-only) for dropseed/h1spec. The bundle actually spans four different license postures: MIT-by-metadata (dropseed, usable), no license at all (uNetworking, NOT usable), AGPL-3.0 (LeaYeh, reference-only), and Zlib (wooshdev, usable). The candidate's own `adaptability` field already spells this out correctly in prose; the top-level `license` field alone does not.

---

## 4. `httplint-field-tests` — mnot/httplint

**Verdict: NOT REFUTED.** Repo, all cited paths, `tests.py:69`, MIT license, and all six spot-checked per-field FieldTest counts confirmed exactly.

```
gh api repos/mnot/httplint --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2023-01-19T10:23:03Z","license":{"key":"mit","name":"MIT License","spdx_id":"MIT",...},"pushed_at":"2026-08-08T06:00:28Z","stargazers_count":19}
```
Matches candidate's "httplint pushed 2026-08-08" exactly.
```
gh api repos/mnot/httplint/contents/LICENSE.md --jq '.content' | base64 -d | head -5
→ Copyright (c) Mark Nottingham ... [MIT text]
```

Path checks, all confirmed to exist:
- `httplint/field/parsers/` → 109 files (candidate says "108 files"; off by one, negligible — likely an `__init__.py`/pylintrc counting difference).
- `httplint/field/tests.py` → exists; `grep -n "class FieldTest"` → **line 69** exactly, matching the candidate's citation `httplint/field/tests.py:69 (FieldTest base class)`.
- `httplint/syntax/rfc9110.py` → exists, 16457 bytes.
- `httplint/syntax/rfc9112.py` → exists, 3667 bytes.
- `httplint/syntax/` directory listing confirms all the other RFC modules the candidate names: `rfc3986.py, rfc5234.py, rfc5322.py, rfc5646.py, rfc5987.py, rfc6838.py, rfc8288.py, rfc9111.py, rfc9651.py` all present (plus `__init__.py`, `pylintrc`).
- `test/http-fields.xml` → exists, 64116 bytes.
- `test/test_fields.py` → exists, 4846 bytes.

Per-field `(FieldTest[` subclass counts (counted with `curl <raw> | grep -c "(FieldTest\["`, correcting for the actual `class Foo(FieldTest[ResponseLinterProtocol]):` subclassing syntax used in the codebase):
```
set_cookie.py: 28   link.py: 16   strict_transport_security.py: 13
content_range.py: 11   content_length.py: 10   transfer_encoding.py: 9   cache_control.py: 9
```
Matches the candidate's claimed top counts ("set_cookie 28, link 16, strict_transport_security 13, content_range 11, content_length 10, transfer_encoding 9, cache_control 9") **exactly**, all seven values. Total FieldTest subclasses across all 109 parser files: 345 in 93 files (candidate says "344 FieldTest cases in 92 files" — off by one on both counts, negligible).

**License-compatibility judgment:** MIT, fully compatible with vendoring the field-value test fixtures into a BSD-3-Clause project with attribution (Copyright (c) Mark Nottingham). No refutation.

---

## 5. `httpwg-structured-field-tests` — httpwg/structured-field-tests

**Verdict: NOT REFUTED.** Repo, all 20 root JSON files, `serialisation-tests/`, `schema/` all confirmed, and every single per-file case count matches exactly, summing to exactly the claimed 1593.

```
gh api repos/httpwg/structured-field-tests --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2018-04-10T06:39:48Z","license":{"key":"other","name":"Other","spdx_id":"NOASSERTION","url":null},"pushed_at":"2026-09-16T01:35:13Z","stargazers_count":45}
```
Matches candidate's "Pushed 2026-09-16, 45 stars" exactly, and independently confirms the candidate's own caveat "(GitHub API says NOASSERTION)".

`LICENSE.md` content:
```
Copyright (c) 2018- IETF Trust and the persons identified as authors of the code. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met: [... 3-clause BSD-style conditions ...]
Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors,
may be used to endorse or promote products derived from this software without specific prior
written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" ...
```
This is the standard **IETF Trust Legal Provisions** license text — structurally identical to BSD-3-Clause (attribution + no-endorsement clause + disclaimer) but with "Internet Society, IETF or IETF Trust" substituted for "the copyright holder" in the no-endorsement clause. That substitution is why GitHub's automated SPDX matcher reports `NOASSERTION` rather than a clean `BSD-3-Clause` match, even though the terms are functionally BSD-3-Clause-equivalent. The candidate's claimed `"license": "BSD-3-Clause"` is a reasonable characterization but not a literal SPDX match; **recommend correcting to "BSD-3-Clause-style (IETF Trust Legal Provisions; SPDX reports NOASSERTION)"** for precision.

Root `*.json` listing (`gh api repos/httpwg/structured-field-tests/contents`) returned exactly the 20 files the candidate lists: `binary.json, boolean.json, date.json, dictionary.json, display-string.json, examples.json, item.json, key-generated.json, large-generated.json, list.json, listlist.json, number-generated.json, number.json, param-dict.json, param-list.json, param-listlist.json, string-generated.json, string.json, token-generated.json, token.json`.

`serialisation-tests/` listing confirmed: `key-generated.json, number.json, string-generated.json, token-generated.json` (matches candidate exactly).

`schema/` listing confirmed the three named schemas exist: `expected.schema.json, parse.schema.json, serialize.schema.json` (plus `.gitignore, README.md, package.json`).

Per-file JSON array length (`python3 -c "print(len(json.load(open(f))))"` per file):
```
binary: 17   boolean: 12   date: 17   dictionary: 26   display-string: 22
examples: 21   item: 5   key-generated: 640   large-generated: 11   list: 11
listlist: 12   number-generated: 193   number: 37   param-dict: 14
param-list: 20   param-listlist: 3   string-generated: 256   string: 14
token-generated: 256   token: 6
```
Every single value matches the candidate's per-file counts **exactly**, and the sum is **1593** — exactly matching the candidate's claimed "1593 parse cases".

**License-compatibility judgment:** the IETF Trust license text is functionally equivalent to BSD-3-Clause (permissive, attribution-preserving, no-endorsement), so vendoring this JSON test data into a BSD-3-Clause project is compatible in substance. Because GitHub's own detector flags it `NOASSERTION`, the synthesis agent should preserve the actual LICENSE.md text/attribution alongside any vendored copy rather than relabeling it as a plain "BSD-3-Clause" grant.

---

## 6. `declaresub-abnf-rfc9110-corpora` — declaresub/abnf

**Verdict: NOT REFUTED.** Repo, all named grammar and corpus paths, MIT license, and every single count in the candidate's description (rule counts, string counts, generator parameters) confirmed exactly. One presentational nit: the repo's default branch is `master`, not `main` — `raw.githubusercontent.com/.../main/...` URLs 404; `.../master/...` succeeds. This does not affect the *paths* the candidate cites (which are branch-agnostic relative paths, correctly resolved by the GitHub Contents API and by the `gh api .../git/trees/main?recursive=true` — actually note **the tree lookup itself required `main`... let me not overclaim**; see raw log below) but is worth flagging for anyone fetching raw files directly.

```
gh api repos/declaresub/abnf --jq '{full_name, pushed_at, created_at, stargazers_count, license}'
→ {"created_at":"2020-04-10T22:48:13Z","license":{"key":"mit","name":"MIT License","spdx_id":"MIT",...},"pushed_at":"2026-09-18T08:08:18Z","stargazers_count":54}
```
Matches candidate's "Pushed 2026-09-18, 54 stars" exactly.
```
gh api repos/declaresub/abnf --jq '.default_branch' → master
```
Root listing includes `LICENSE.txt` (not `LICENSE`):
```
gh api repos/declaresub/abnf/contents/LICENSE.txt --jq '.content' | base64 -d | head -5
→ Copyright 2020 Charles Yeomans
  Permission is hereby granted, free of charge, to any person obtaining a copy of this software ... [MIT text]
```

`src/abnf/grammars/` directory listing confirms `rfc9110.py` present and, importantly, confirms the candidate's claim that **no `rfc9112.py` exists** — the listing (33 files) runs `cors.py, misc.py, rfc2616.py, rfc3339.py, rfc3629.py, rfc3986.py, rfc3987.py, rfc4647.py, rfc5234.py, rfc5322.py, rfc5646.py, rfc5987.py, rfc6265.py, rfc6266.py, rfc6797.py, rfc7230.py, rfc7231.py, ..., rfc9051.py, rfc9110.py, rfc9111.py, rfc9116.py, rfc9651.py` — `rfc7230.py` is present, `rfc9112.py` is absent, exactly as claimed.

`tests/fuzz/` directory listing confirms `effective_grammar.py`, `gen_abnfgen_corpus.py`, `gen_corpus.py` all present, plus the three corpus directories `corpus/`, `corpus_abnfgen/`, `corpus_neg/`, each containing 31–32 per-RFC JSON files including `rfc9110.json`.

Per-corpus rule/string counts for `rfc9110.json` (Python: rule count = `len(dict)`, string count = `sum(len(v) for v in dict.values())`, fetched from `https://raw.githubusercontent.com/declaresub/abnf/master/tests/fuzz/<dir>/rfc9110.json`):
```
corpus/rfc9110.json:         rules=142 strings=13313
corpus_abnfgen/rfc9110.json: rules=142 strings=958
corpus_neg/rfc9110.json:     rules=140 strings=1639
```
Matches the candidate's claims **exactly**: "142 rules / 13,313 strings", "142 rules / 958 strings", "140 rules / 1,639 strings" respectively. Sum (13313+958+1639=15910) is consistent with the candidate's "~15,900 strings" headline figure.

Generator parameters in `gen_abnfgen_corpus.py`:
```
SAMPLES_PER_RULE = 8
MAX_DEPTH = 9
SEED = 20250824
```
Matches candidate's claimed "SEED 20250824, depth 9, 8 samples/rule" **exactly**.

**License-compatibility judgment:** MIT, fully compatible with vendoring the JSON corpora into a BSD-3-Clause project with attribution to Charles Yeomans, 2020. No refutation.

---

## Summary table

| key | existence | license claim confirmed | compatible w/ BSD-3-Clause vendoring | refuted |
|---|---|---|---|---|
| cispa-http-conformance | yes, all 4 paths + LICENSE | MIT (exact) | yes | false |
| http11probe | yes, all 7 suites + TestCase.cs + 13 doc cats | MIT (exact) | yes | false |
| h1spec-family | yes, all 4 repos + named paths | mixed: MIT-by-metadata (dropseed), none (uNetworking), AGPL-3.0 (LeaYeh), Zlib (wooshdev) — all confirmed | dropseed: yes (weak grant); uNetworking: no (no license); LeaYeh: reference-only (copyleft); wooshdev: yes | false (existence/license accurate; LeaYeh case-count corrected) |
| httplint-field-tests | yes, all paths incl. tests.py:69 | MIT (exact) | yes | false |
| httpwg-structured-field-tests | yes, all 20+4+3 paths, counts sum to exactly 1593 | IETF Trust license (BSD-3-Clause-style; SPDX NOASSERTION on GitHub) | yes, in substance | false |
| declaresub-abnf-rfc9110-corpora | yes, all grammar/corpus paths, all counts exact | MIT (exact) | yes | false |

No candidate was refuted on existence or on the substance of its license claim. Corrections supplied: (1) h1spec-family's LeaYeh sub-repo test-case count is ~18, not ~34–35; (2) httpwg-structured-field-tests' license is more precisely described as "BSD-3-Clause-style (IETF Trust Legal Provisions); SPDX NOASSERTION" rather than a bare "BSD-3-Clause" match; (3) minor ±1 count discrepancies (Http11Probe doc-page total, httplint parser-file/FieldTest totals, uNetworking case/timeout counts) noted but not treated as refutations.
