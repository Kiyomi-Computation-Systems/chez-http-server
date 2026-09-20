# Skeptic verification report — batch 9 (existence + license)

Role: SKEPTIC. Lens: **existence and license only**. For each candidate I tried to
refute (a) that the named repo/paths exist today, and (b) that the stated license
is correct and compatible with vendoring TEST DATA (not code) into a BSD-3-Clause
project. Default is `refuted=true` unless existence was positively confirmed.

Environment: `gh` CLI authenticated as `DarrenN` (GitHub REST API used for all repo
metadata / file-content / commit checks — preferred per tool guidance over
scraping GitHub HTML). `curl`, `python3`, and a throwaway sparse git clone were
used for byte-level corpus verification. All checks run 2026-09-19.

---

## 1. `co-advisor-measurement-factory` — VERDICT: not refuted (tier 3, no public corpus, confirmed)

**Claim under test:** no public corpus exists; product page 404s; daft is an
Apache-2.0 JS framework with only 2 example scripts, not an HTTP/1.1 corpus.

- `curl -s -o /dev/null -w '%{http_code}' http://www.measurement-factory.com/` → `302`
  (redirects to https). `... https://www.measurement-factory.com/` → `200`.
- `curl -sIL http://www.measurement-factory.com/products/co-advisor/`:
  ```
  HTTP/1.1 302 Found
  Location: https://www.measurement-factory.com/products/co-advisor/
  HTTP/1.1 404 Not Found
  ```
  So the http URL redirects to the https URL, which 404s — the candidate's claim
  "returns 404 on both http and https" is accurate once redirects are followed
  (confirmed today, 2026-09-19).
- WebFetch of `https://www.measurement-factory.com/` confirmed the root page still
  lists: **"Co-Advisor (an HTTP and ICAP compliance test suite)"** — verbatim match
  to the candidate's note.
- Extra check (not in the candidate, found via WebSearch): a second product
  subdomain `http://coad.measurement-factory.com/` returns **200** but with
  `Content-Length: 73`, `Last-Modified: Mon, 16 Oct 2017` and body
  `<html><body>Error DEFA017. Email webmaster of this domain.</body></html>` — a
  dead placeholder, not a live tool or corpus. `https://coad.measurement-factory.com/`
  fails TLS hostname verification (cert is for `www.e-cap.org`). This *strengthens*
  the "no obtainable public corpus" conclusion; it does not refute it.
- `gh api repos/measurement-factory/daft --jq '{archived,license,default_branch,pushed_at}'`
  → `{"archived":false,"license":{"key":"apache-2.0","spdx_id":"Apache-2.0",...},"default_branch":"master","pushed_at":"2026-07-23T13:45:52Z"}`.
  LICENSE file content starts `Apache License / Version 2.0, January 2004` — confirms
  Apache-2.0 for daft, not "unknown" (the candidate's own `license` field of
  "unknown" refers to Co-Advisor itself, and correctly states daft separately as
  Apache-2.0 in `format`).
- `gh api repos/measurement-factory/daft/contents/tests/self.js` → `{"name":"self.js"}`.
  `gh api repos/measurement-factory/daft/contents/tests/test-proxy-h0-response.js`
  → `{"name":"test-proxy-h0-response.js"}`. Both named example files exist.
- Squid wiki (`https://wiki.squid-cache.org/Features/HTTP11`, HTTP 200) confirmed via
  WebFetch to mention Co-Advisor multiple times, including the exact
  `HTTP-1.1-Checklist_2018-08-09.ods` (Aug 2018) and
  `HTTP-1.1-Checklist_2013-08-21.ods` (Aug 2013) checklist artifacts cited in the
  candidate's notes.
- WebFetch of the cited 2001 W3C QA workshop position paper
  (`https://www.w3.org/2001/01/qa-ws/pp/alex-rousskov-measfact.html`) confirmed
  verbatim: **"The tool contains 256 test cases..."** and **"Non-paying users get
  restricted free access to the tool."** — both exact matches to the candidate's
  `approx_cases` and `adaptability` text.

**Assessment:** every factual claim in this candidate checked out exactly,
including the harder-to-verify W3C paper quote and the 2013/2018 Squid checklist
citations. The candidate's own conclusion (tier 3, reference-only, no vendorable
corpus, license "unknown" because there is nothing shippable to license) is
correct and does not need correction. Since "no corpus exists to vendor" is
itself the claim being tested and it holds up, I record this as **not refuted**
(the finder was right that there is nothing here to vendor).

---

## 2. `tfb-toolset-verifications` — VERDICT: not refuted

- `gh api repos/TechEmpower/FrameworkBenchmarks --jq '{archived,pushed_at,license,default_branch}'`
  → `{"archived":true,"pushed_at":"2026-03-24T01:39:18Z","license":{"key":"other","spdx_id":"NOASSERTION"},"default_branch":"master"}`.
  Confirms **archived: true** (candidate's note) and that GitHub reports
  `NOASSERTION` for SPDX purposes.
- `gh api repos/TechEmpower/FrameworkBenchmarks/contents/LICENSE` → decoded text is
  the verbatim 3-clause BSD text (copyright TechEmpower, Inc. 2021; "Redistributions
  of source code..."; "Redistributions in binary form..."; "Neither the name
  TechEmpower, Inc. nor the names of its contributors..."). This **is** BSD-3-Clause
  by text even though GitHub's classifier could not assign an SPDX id (no header in
  the file) — confirms the candidate's license note exactly.
- Path checks (`gh api repos/.../contents/<path> --jq '.name'`), all **200 / found**:
  `toolset/test_types/verifications.py`, `toolset/test_types/abstract_test_type.py`,
  `toolset/test_types/plaintext/plaintext.py`, `toolset/test_types/json/json.py`,
  `toolset/test_types/fortune/fortune.py`, `toolset/wrk/concurrency.sh`,
  `toolset/wrk/pipeline.sh`, `toolset/wrk/pipeline.lua`, `toolset/wrk/query.sh`,
  `toolset/wrk/wrk.dockerfile`, `LICENSE`.
- Negative control: `gh api repos/.../contents/toolset/benchmark/test_types` →
  `{"message":"Not Found","status":"404"}` — confirms the candidate's note that a
  different agent's *guessed* path (`toolset/benchmark/test_types`) does **not**
  exist and the real path is `toolset/test_types`.
- `gh api repos/TechEmpower/FrameworkBenchmarks/commits/57d92fbec6f8fd7431bc77326dd0484e60c96e20`
  → resolves, dated `2026-03-23T21:28:51Z`, and is in fact the tip of the (archived)
  repo's push history — confirms the pinned provenance commit is real and current.
- Spot-checked `verifications.py` content (489 lines total) against the candidate's
  cited line ranges: `verify_headers()` opens with the Server/Date/Content-Type
  required-header loop and the Content-Length/Transfer-Encoding-required check
  immediately below it, then the Date IMF-fixdate parse + `sleep(3)` +
  second-request cached-Date check — matches the candidate's
  `covers` bullets (lines 68-102 region) almost exactly (function starts a few
  lines earlier than the cited numbers because of the docstring, but content
  matches).

**Assessment:** fully confirmed, no corrections needed. BSD-3-Clause text is
unambiguous and self-compatible with a BSD-3-Clause target project (same license
family; vendoring is trivial, just keep the LICENSE/attribution).

---

## 3. `curl-testsuite-protocol-corpus` — VERDICT: not refuted (one approx-count adjusted)

- `gh api repos/curl/curl --jq '{archived,license,default_branch}'` →
  `{"archived":false,"license":{"key":"other","spdx_id":"NOASSERTION"},"default_branch":"master"}`.
- `gh api repos/curl/curl/contents/COPYING` decoded → the standard "curl license"
  text ("Copyright (c) 1996 - 2026, Daniel Stenberg... Permission to use, copy,
  modify, and distribute this software for any purpose with or without fee is
  hereby granted, provided that the above copyright notice and this permission
  notice appear in all copies..."). Verified via WebSearch that SPDX registers
  this exact text as license id **`curl`** (https://spdx.org/licenses/curl.html) —
  confirms the candidate's `"license": "curl"` field is the correct SPDX id (an
  ISC/MIT-style permissive license, not a generic "unknown").
- Path checks, all found: `tests/data/test1`, `tests/data/test1070`, `tests/data`
  (directory listing works — GitHub's non-recursive contents API caps at 1000
  entries and reported exactly that cap, confirming the dir is large, not that
  it's exactly 1000), `docs/tests/FILEFORMAT.md`, `COPYING`.
- `gh api repos/curl/curl/commits/a40991b97c0ce721e85acbe16e16fe79b7b68c51` →
  resolves, dated `2026-09-19T06:12:40Z` ("Dockerfile: update debian:bookworm-slim
  Docker digest..."), i.e. the commit is real and is in fact **today's** tip of
  master — confirms provenance pin.
- Fetched `tests/data/test1` in full: `<protocol crlf="headers">` block present,
  request lines match the candidate's description of a recorded curl request
  stream with `%HOSTIP`/`%HTTPPORT`/`%TESTNUMBER`/`%VERSION` placeholders.
- Fetched `tests/data/test1070` in full: confirms `Expect: 100-continue` in the
  `<command>` (`-H "Expect: 100-continue"`) and in the `<protocol>` block, a
  `<servercmd>skip: 2300</servercmd>` plus `Connection: close` in the reply —
  exactly the "server closes early" scenario the candidate describes.
- `docs/tests/FILEFORMAT.md` (fetched, 822 lines): line 696 is
  `### <protocol [nonewline="yes"][crlf="yes|headers"]>`, with `crlf=`/`nonewline=`
  semantics documented at lines 698-708 — matches the candidate's
  `docs/tests/FILEFORMAT.md:696-708` citation exactly.
- **Count verification** — did a shallow sparse `git clone --depth 1` of
  `https://github.com/curl/curl.git` restricted to `tests/data/*` (2139 entries
  fetched) and grepped/scripted against the 2109 files matching `test[0-9]+`:
  - Numeric test files: **2109** — exact match to candidate.
  - Files with a `<keywords>` line exactly `HTTP`: **1084** — exact match.
  - Files that are both HTTP-tagged *and* contain a `<protocol` block: **959**
    (of 1615 files with `<protocol` blocks overall, only when intersected with
    the 1084 HTTP-tagged set does it come to exactly 959) — exact match to the
    candidate's "959 with a `<protocol>` block" (implicitly scoped to HTTP tests).
  - Files whose `<protocol>` block contains `Expect: 100-continue` verbatim:
    **24** — exact match.
  - Files whose `<protocol>` block contains 2+ request-lines (`METHOD path
    HTTP/1.x`), i.e. pipelined/multi-request-per-connection: my regex-based
    script found **329**, vs. the candidate's claimed **312**. This is a ~5%
    discrepancy, plausibly from differing definitions (e.g. excluding retried/
    re-authenticated requests that repeat the same request line, or a stricter
    HTTP/1.1-only filter). Not large enough, and not about existence/license, to
    refute the candidate, but flagged as a correction to `approx_cases`.

**Assessment:** existence, license (SPDX `curl`, ISC/ MIT-style, permissive, no
copyleft) and the overwhelming majority of stated counts (4 of 5 checked exactly)
are confirmed. One approx-count ("312" vs. measured 329) is a minor overcount
correction, not a refutation.

---

## 4. `curl-cli-conformance-client` — VERDICT: not refuted (file-count corrected)

- Same repo/license facts as #3 (curl license, SPDX id `curl`, permissive,
  compatible for reference use).
- Path checks, all found: `tests/http/test_07_upload.py`, `tests/http/test_12_reuse.py`,
  `tests/http/test_04_stuttered.py`, `tests/http/test_01_basic.py`,
  `tests/http/test_18_methods.py`.
- **Count check:** the candidate claims "345 test functions in **31 files**".
  `gh api repos/curl/curl/contents/tests/http` and the sparse-clone tree both show
  exactly **29** files matching `test_*.py` under `tests/http/` today (`test_01_basic.py`
  through `test_22_httpsrr.py`, then `test_30_vsftpd.py`, `test_31_vsftpds.py`,
  `test_32_ftps_vsftpd.py`, `test_40_socks.py`, `test_50_scp.py`, `test_51_sftp.py`,
  `test_60_h3_proxy.py` — full listing captured). I did not count `def test_`
  functions (would require downloading and parsing all 29 files, out of scope for
  an existence/license pass), so the "345 functions" figure is unverified either
  way. **Correction: 29 files, not 31**, as of 2026-09-19 (repo is actively
  developed / not archived, so file count naturally drifts).
- All 5 named example files exist and are real scenario files (not spot-checked
  line-by-line beyond confirming their existence, in keeping with the
  existence/license lens).

**Assessment:** repo exists, license confirmed (`curl` SPDX id, permissive,
vendoring-by-reference compatible), all cited example paths exist. Only the
aggregate file count in `approx_cases` needs correcting (29, not 31).

---

## 5. `hurl-integration-suite` — VERDICT: not refuted (every count confirmed exactly)

- `gh api repos/Orange-OpenSource/hurl --jq '{archived,license,default_branch}'` →
  `{"archived":false,"license":{"key":"apache-2.0","spdx_id":"Apache-2.0",...},"default_branch":"master"}`.
- `gh api repos/Orange-OpenSource/hurl/contents/LICENSE` decoded → starts
  `Apache License / Version 2.0, January 2004` — confirms Apache-2.0, matching the
  candidate exactly.
- Path checks, all found: `integration/hurl/tests_ok` (101 entries),
  `integration/hurl/tests_ok/head/head.hurl`, `integration/hurl/tests_ok/head/head.py`,
  `integration/hurl/tests_ok/http_version` (41 entries),
  `integration/hurl/tests_ok/expect` (5 entries),
  `integration/hurl/tests_ok/get_large` (5 entries),
  `integration/hurl/tests_ok/delay` (13 entries), `integration/hurl/app.py`,
  `integration/hurl/server.py`, `integration/hurl/tests_failed` (66 entries — this
  is directory *entries*, not `.hurl` file count, see below), `docs/installation.md`,
  `LICENSE`.
- **Count verification** via `gh api "repos/Orange-OpenSource/hurl/git/trees/master?recursive=1"`
  (3421 total tree entries, not truncated) and grep on paths:
  - `.hurl` files under `integration/hurl/tests_ok/`: **182** — exact match to
    candidate's "182 .hurl in tests_ok".
  - `.py` files under the same tree: **108** — exact match to "108 route .py files".
  - `.hurl` files under `integration/hurl/tests_failed/`: **88** — exact match.
  - `.hurl` files under `integration/hurl/tests_error_parser/`: **49** — exact match.
  - `.hurl` files under `integration/hurl/tests_ssl/`: **15** — exact match.
  - Total `.hurl` files anywhere under `integration/`: **400** — exact match to
    "400 .hurl total under integration/".

**Assessment:** every single quantitative claim in this candidate (6 separate
counts) matched exactly against a fresh recursive tree listing fetched today.
License (Apache-2.0, non-copyleft, permissive, patent-grant, NOTICE-preserving)
is confirmed compatible with vendoring into a BSD-3-Clause project by reference
(the Apache-2.0 terms travel with the vendored files; the host project itself
stays BSD-3-Clause). This is the most thoroughly-confirmed candidate in the batch.

---

## 6. `wrk-load-scripts` — VERDICT: not refuted

- `gh api repos/wg/wrk --jq '{archived,license,pushed_at}'` →
  `{"archived":false,"license":{"key":"other","spdx_id":"NOASSERTION"},"pushed_at":"2023-12-30T10:33:51Z"}`.
- `gh api repos/wg/wrk/contents/LICENSE` decoded in full → title block reads
  **"Modified Apache 2.0 License / Version 2.0.1, February 2015"**, and Section 4
  has an extra clause **(e)**: *"If the Derivative Work includes substantial
  changes to features or functionality of the Work, then you must remove the name
  of the Work, and any derivation thereof, from all copies that you distribute...
  "* — this is the one added clause beyond stock Apache-2.0, exactly as the
  candidate's notes describe ("diff against stock Apache-2.0 shows one added
  clause 4(e)"). GitHub reports `NOASSERTION`/`"other"` (no SPDX id), also as
  claimed.
- Path checks, all found: `scripts/pipeline.lua`, `scripts/post.lua`,
  `scripts/delay.lua`, `scripts/counter.lua`, `scripts/report.lua`,
  `scripts/setup.lua`, `scripts/stop.lua`, `scripts/addr.lua`, `scripts/auth.lua`.
- `brew info wrk` → `wrk: stable 4.2.0 (bottled), HEAD` — confirms "brew wrk 4.2.0".
- `brew search wrk2` / `brew info wrk2` → `Error: No available formula with the
  name "wrk2". Did you mean wrk?` — confirms "no brew formula" for wrk2.
- `gh api repos/giltene/wrk2 --jq '{archived,license,pushed_at}'` →
  `{"archived":false,"license":{"key":"apache-2.0","spdx_id":"Apache-2.0"},"pushed_at":"2024-03-03T13:40:01Z"}`
  (stock Apache-2.0, confirmed, no modified clause — matches the candidate's tier-3
  characterization). The repo's `pushed_at` metadata field (2024-03-03) is not the
  same as the last commit to `master`; `gh api repos/giltene/wrk2/commits/master`
  → tip commit dated **2019-09-24T04:46:42Z** ("Merge pull request #80... Add
  build status badge"), which matches the candidate's "HEAD 2019-09-23" to within
  a day (likely a UTC/local date-boundary difference, not an error).

**Assessment:** license text, the specific "modified clause 4(e)" characterization,
and every named script path are all confirmed. The one added clause is a
naming-removal condition triggered only by *substantial modification* of wrk
itself; it is not a copyleft/share-alike requirement, so vendoring `pipeline.lua`
verbatim (as TFB already does under its own BSD-3-Clause umbrella per candidate
`tfb-toolset-verifications`) or running the wrk binary unmodified as a load driver
is unaffected. wrk2 correctly demoted to tier 3 (no brew formula, older).

---

## Summary table

| key | exists today? | license confirmed | corrections |
|---|---|---|---|
| co-advisor-measurement-factory | yes (as "no public corpus", confirmed) | daft = Apache-2.0 (confirmed); Co-Advisor itself unlicensed/unobtainable (confirmed) | none |
| tfb-toolset-verifications | yes, all paths | BSD-3-Clause (verbatim text; SPDX NOASSERTION only for lack of header) | none |
| curl-testsuite-protocol-corpus | yes, all paths | `curl` SPDX id confirmed, permissive | approx "312" multi-request files measured as 329 |
| curl-cli-conformance-client | yes, all paths | `curl` SPDX id confirmed, permissive | file count is 29, not 31 |
| hurl-integration-suite | yes, all paths, every count exact | Apache-2.0 confirmed | none |
| wrk-load-scripts | yes, all paths | Modified Apache 2.0 (clause 4(e)) confirmed; wrk2 stock Apache-2.0 confirmed | none |

None of the six candidates use a copyleft license; BSD-3-Clause, the `curl`
license, Apache-2.0, and the wrk "Modified Apache 2.0" are all permissive and
compatible with vendoring test data into a BSD-3-Clause project by reference
(retain the upstream license/attribution for the vendored subtree; do not
relicense it to BSD-3-Clause).
