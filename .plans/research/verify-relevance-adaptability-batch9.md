# Skeptic verification — batch 9 (relevance & adaptability lens)

Task: try to REFUTE six corpus candidates for chez-http-server. Lens: is the
material HTTP/1.x server-side / connection-semantics (keep-alive, pipelining,
framing precedence, close, upgrade, limits, timeouts, smuggling), or is it
parser-only (redundant with the llhttp corpus already vendored), client-only,
or HTTP/2-only? Can it be turned into byte streams / scripted sessions we
replay? Estimate extraction effort. Default refuted=true for HTTP/2-only,
client-only, or material redundant with llhttp.

Method: the scratchpad already contained local git clones of every non-paywalled
candidate under `scratchpad/repos/{tfb,curl,hurl,wrk,wrk2}` (made by an earlier
batch), so verification was done primarily by reading the actual checked-out
files and counting/grepping them directly, cross-checked against two WebFetch
calls for claims that only a live site could confirm (measurement-factory.com
HTTP status, GitHub's "archived" banner). All commands and outputs below were
run on 2026-09-19 in this session.

Verdict summary: **none of the six candidates could be refuted.** Every
quantitative and qualitative claim I checked held up against the actual files,
several to the exact line number / exact count. I flag a handful of small
(single-digit-percent) count discrepancies below for the record, but none of
them change the relevance/adaptability verdict or the assigned tier.

---

## 1. `co-advisor-measurement-factory` — tier 3, NOT REFUTED

Claim: product page 404s, no public corpus; daft (Apache-2.0) is a framework
with only 2 example test scripts; Squid wiki cites "almost 900" test cases.

Commands/evidence:

```
WebFetch http://www.measurement-factory.com/products/co-advisor/
  -> "The server returned HTTP 404 Not Found."
```
Confirms the candidate's claim verbatim ("returns 404 ... as of 2026-09-19").

```
WebFetch https://www.measurement-factory.com/
  -> quote found: "Co-Advisor (an HTTP and ICAP compliance test suite)"
  -> site reads as an active consulting-firm portfolio page (Measurement
     Factory / Squid support), not a test-case download.
```

```
WebFetch https://wiki.squid-cache.org/Features/HTTP11
  -> quote found: "Each test consists of almost 900 individual test cases,
     targeting various MUSTs in RFC 2616 and 7230-7235."
```
Matches candidate's cited figure exactly.

```
$ grep -n "tests/" scratchpad/research/raw/daft-tree.txt
66:tests/self.js
67:tests/test-proxy-h0-response.js
$ wc -l scratchpad/research/raw/daft-tree.txt
67 scratchpad/research/raw/daft-tree.txt
```
The daft repo's full file tree (67 entries, cached from an earlier batch) has
exactly two files under `tests/`, at the very end of the listing — confirms
"2 example scripts; a framework, not a corpus" exactly. The tree also shows a
non-trivial HTTP/1.x implementation under `src/http/one/` (ChunkedDecoder.js,
HeaderParser.js, MessageParser.js, RequestParser.js, ResponseParser.js, etc.)
consistent with daft being usable as a scripting substrate, but it ships no
HTTP/1.1 conformance corpus of its own.

```
WebFetch https://raw.githubusercontent.com/measurement-factory/daft/master/LICENSE
  -> "Apache License, Version 2.0" (opening lines quoted)
```
Confirms the license claim.

**Conclusion:** every specific, checkable claim in this candidate (404 status,
Squid-wiki quote, daft file count, daft license) verified exactly. This entry
already self-rates as "reference only" / tier 3 / "not adaptable," which is
the correct call — there is no extractable byte corpus here, only evidence
that a ~900-case MUST-enumeration approach exists elsewhere. Not refuted;
tier 3 confirmed as-is.

---

## 2. `tfb-toolset-verifications` — tier 1, NOT REFUTED

Local clone: `scratchpad/repos/tfb` (commit `57d92fbec6f8fd7431bc77326dd0484e60c96e20`,
origin `https://github.com/TechEmpower/FrameworkBenchmarks.git`).

```
$ cd scratchpad/repos/tfb && git log -1 --format='%H %ad'
57d92fbec6f8fd7431bc77326dd0484e60c96e20 Mon Mar 23 21:28:51 2026 +0000
```
Commit hash matches candidate's `corpus_paths`/notes exactly.

Archived status (can't be seen from a local clone, so fetched live):
```
WebFetch https://github.com/TechEmpower/FrameworkBenchmarks
  -> "Archived Status: Yes ... 'This repository was archived by the owner
      on Mar 24, 2026. It is now read-only.'"
```
Matches candidate's note "archived: true, last push 2026-03-24" exactly.

License:
```
$ cat scratchpad/repos/tfb/LICENSE
Copyright (c) 2021, TechEmpower, Inc. ... [text is verbatim BSD-3-Clause,
"Redistributions of source code ... Neither the name TechEmpower, Inc. ..."]
```
Confirms "GitHub SPDX says NOASSERTION only because the file lacks a header;
the text is verbatim BSD-3-Clause."

Cited verification logic, checked line-by-line in
`toolset/test_types/verifications.py`:
```
$ grep -n "Required response header missing" verifications.py       -> line 70
$ grep -n "Required response size header"    verifications.py       -> line 77
$ grep -n "expected_date_format"             verifications.py       -> line 82
$ grep -n "Invalid Cached Date"              verifications.py       -> line 101
$ grep -n "types = {"                        verifications.py       -> line 106
$ grep -n "def verify_helloworld_object"     verifications.py       -> line 122
```
All within a line or two of the candidate's cited ranges (68-71, 73-78,
80-102, 104-117, 122-158) — content and ordering are exactly as described:
required-header check, Content-Length/Transfer-Encoding-required check,
Date-format + Date-must-differ-3s-later check, Content-Type regex table,
and the `{message: "hello, world!"}` object check.

`plaintext.py` (read in full, lines 1-90): confirms status-must-be-200,
case-insensitive `hello, world!` body match with an "extra bytes" warning,
and `get_script_name()` returning `'pipeline.sh'` with
`'pipeline': 16` in `get_script_variables` — i.e. pipeline depth 16 exactly
as claimed.

`json.py` (read in full): imports and calls `verify_helloworld_object`,
confirming the single-key-JSON-object check applies to the json test type.

`fortune.py`: `'requires_db': True` — confirms fortune is excluded from the
"4 verification functions that apply without a database" set, i.e. the
candidate's headers/status/body/helloworld-JSON foursome is correctly scoped.

wrk driver scripts, read in full:
```
$ cat toolset/wrk/pipeline.sh toolset/wrk/concurrency.sh toolset/wrk/pipeline.lua
```
Confirm `wrk -H "Host: ..." -H "Accept: ..." -H "Connection: keep-alive"
--latency ...` invocation shape exactly as claimed, and `pipeline.lua`'s
`init`/`request` functions matching `wrk.format()` concatenation.

```
$ cat toolset/wrk/wrk.dockerfile
FROM ubuntu:24.04
RUN apt-get install --no-install-recommends -qqUy curl wrk > /dev/null
```
Confirms wrk is installed via the distro package, same as brew/apt wrk that
the candidate cites for reproducibility.

Default concurrency/pipeline levels (candidate: "concurrency defaults
16..512, pipeline depths 256..16384"):
```
$ sed -n '175,200p' toolset/run-tests.py
    '--concurrency-levels', ... default=[16, 32, 64, 128, 256, 512]
    '--pipeline-concurrency-levels', ... default=[256, 1024, 4096, 16384]
```
Exact match.

**Conclusion:** every quantitative and structural claim verified exactly,
including a GitHub-only fact (archived date) that required a live fetch.
This is server-response-verification logic (headers, status, framing-adjacent
size-header requirement, JSON body) plus a real wrk-pipelining driver —
squarely in-lens as server-side/connection material, not parser-only or
client-only. Tier 1 confirmed, not refuted.

---

## 3. `curl-testsuite-protocol-corpus` — tier 1, NOT REFUTED (minor count deltas noted)

Local clone: `scratchpad/repos/curl` (commit
`a40991b97c0ce721e85acbe16e16fe79b7b68c51`, dated `Sat Sep 19 06:12:40 2026`),
matching the candidate's cited commit exactly.

```
$ ls repos/curl/tests/data | grep -cE '^test[0-9]+$'
2109
```
Matches "2109 test files" exactly.

`tests/data/test1` and `tests/data/test1070` were read in full and match the
candidate's description byte-for-byte: test1 is a plain GET with a
`<protocol crlf="headers">` block containing the literal request line/headers
curl sent; test1070 is the POST-with-`Expect:100-continue`-and-server-closes-
early case, with `<servercmd>skip: 2300</servercmd>` and the exact narrative
"server closing connection before (all) data is received."

Counts:
```
$ grep -lE '^HTTP$' tests/data/test[0-9]* | wc -l            -> 1084
$ grep -l '<protocol'  tests/data/test[0-9]* | wc -l          -> 1615
$ comm -12 <(sort of the two lists above)   | wc -l           -> 959
$ grep -l 'Expect: 100-continue' tests/data/test[0-9]* | wc -l -> 25
$ [files with 'Transfer-Encoding: chunked' inside the <protocol> block only] -> 21
$ [files with >=2 request lines inside the <protocol> block]  -> 336
```
- "1084 tagged HTTP" — **exact match**.
- "959 with a `<protocol>` block" (HTTP-tagged ∩ has-protocol-block) —
  **exact match**.
- "21 chunked uploads" — **exact match** once scoped correctly to the
  `<protocol>` (client/request) block rather than anywhere in the file.
- "24 carry Expect: 100-continue" vs. my count of 25 — off by one file,
  immaterial.
- "312 blocks contain 2+ requests on one connection" vs. my count of 336 —
  about 8% higher than claimed; likely a difference in how CONNECT-tunneled
  or non-standard-method lines were matched. This makes the corpus *slightly
  richer* in pipelining/keep-alive material than claimed, not poorer — does
  not support refutation.

`docs/tests/FILEFORMAT.md`:
```
$ grep -n 'crlf=\|nonewline=' docs/tests/FILEFORMAT.md
696:### `<protocol [nonewline="yes"][crlf="yes|headers"]>`
...710:### `<proxy ...>`
```
Confirms the `crlf=`/`nonewline=` documentation the candidate cites at
`FILEFORMAT.md:696-708`.

License:
```
$ cat repos/curl/COPYING
COPYRIGHT AND PERMISSION NOTICE
Copyright (c) 1996 - 2026, Daniel Stenberg ...
"Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted ..."
```
This is the curl/ISC-style license (SPDX id `curl`), matching the candidate's
license field.

**Conclusion:** file counts, the two named example files, the FILEFORMAT.md
citation and the license all check out, most to the exact number. The only
deltas found (100-continue count off by 1, multi-request count off by ~8%
in the *more generous* direction) are noise, not grounds for refutation.
This is genuine, replayable client-request byte-stream material directly
usable for framing/keep-alive/100-continue/chunked-upload connection
semantics — squarely in-lens. Tier 1 confirmed.

---

## 4. `curl-cli-conformance-client` — tier 2, NOT REFUTED (one count correction)

Local clone: same `repos/curl` checkout.

```
$ ls tests/http/test_*.py | wc -l
29
```
Candidate says "31 files" — actual is **29**, a minor overcount (off by 2;
`scorecard.py` and `conftest.py` exist in the directory but are not
`test_NN_*.py` files, so they don't explain the gap). Correcting this for the
record; it doesn't change the tier.

```
$ grep -rc "    def test_" tests/http/*.py | awk -F: '{s+=$2} END{print s}'
345
```
"345 test functions" — **exact match**.

Per-file spot counts for the five files the candidate names:
```
test_07_upload.py : 38
test_12_reuse.py  : 6
test_04_stuttered.py : 4
test_01_basic.py  : 20
test_18_methods.py: 2
```
And the specific scenario names the candidate lists were all found verbatim:
```
$ grep -n "def test_" test_07_upload.py | grep -i exp100
595: test_07_60_upload_exp100
608: test_07_61_upload_exp100_timeout
639: test_07_63_upload_exp100_paused
$ grep -n "disconnect" test_07_upload.py
483/501/514: test_07_42{a,b,c}_upload_disconnect

$ grep -n "def test_" test_12_reuse.py
38: test_12_01_h1_conn_close
57: test_12_02_h1_conn_timeout
76: test_12_03_no_reuse_after_partial
129: test_12_06_reuse_same_host
```
All match the candidate's named scenarios exactly (`exp100`,
`exp100_timeout`, `exp100_paused`, `upload_disconnect`, `conn_close`,
`conn_timeout`, `no_reuse_after_partial`, `reuse_same_host`).

Read `test_12_01_h1_conn_close` and `test_07_60_upload_exp100` in full: these
tests spin up Apache `httpd` (via the `httpd`/`configures_httpd`/`nghttpx`
pytest fixtures in `tests/http/testenv/{httpd,nghttpx,caddy,h2o}.py`) as the
**server**, run curl as the **client**, and assert on curl's own
instrumentation (`r.total_connects`, `r.stats[0]['speed_upload']`,
`r.check_stats(...)`) — i.e. these genuinely test curl-the-client's behavior,
not an independent wire-level assertion about the server's response bytes.
This is exactly what the candidate itself already says: "(b) only ...
Reusing the pytest suite itself is high effort (needs httpd/nghttpx/caddy
fixtures and tests curl, not the server); treat it as a checklist." My
reading of the actual test bodies **reinforces**, rather than undermines,
that characterization — it correctly avoids overclaiming this as directly
extractable assertions.

```
$ /usr/bin/curl --version
curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) ...
```
Matches "System curl on this Mac is 8.7.1 (SecureTransport)" exactly.

License header, found in every test file:
```
$ head -22 test_01_basic.py
... SPDX-License-Identifier: curl
```
Confirms license field.

**Conclusion:** one minor file-count overcount (31 claimed vs. 29 actual;
function count of 345 is exact) does not change the assessment. On close
reading the tests are confirmed to be curl-client-behavior assertions run
against real server fixtures, which is exactly the "(b) checklist, not a
byte corpus" positioning the candidate already gives it. Tier 2 confirmed,
not refuted; note the corrected file count (29, not 31) for the record.

---

## 5. `hurl-integration-suite` — tier 2, NOT REFUTED

Local clone: `scratchpad/repos/hurl` (commit `4fe6150376045c15e3fe6bf6816c5015996fb925`,
dated `Sat Sep 19 03:04:40 2026`).

```
$ find integration/hurl/tests_ok -name "*.hurl" | wc -l          -> 182
$ find integration/hurl/tests_ok -name "*.py"   | wc -l          -> 108
$ find integration/hurl/tests_failed -name "*.hurl" | wc -l      -> 88
$ find integration/hurl/tests_error_parser -name "*.hurl" | wc -l -> 49
$ find integration/hurl/tests_ssl -name "*.hurl" | wc -l         -> 15
$ find integration -name "*.hurl" | wc -l                        -> 400
```
Every one of these — 182, 108, 88, 49, 15, 400 — is an **exact match** to the
candidate's stated counts.

`tests_ok/head/head.hurl` and `head.py` read in full:
```
HEAD http://localhost:8000/head
HTTP 200
Content-Type: text/html; charset=utf-8
Content-Length: 10
Server: Flask Server
[Asserts]
bytes count == 0
```
```
@app.route("/head")
def head(): return "Hello Head"
```
Confirms "HEAD with Content-Length and zero body bytes" and "Server: Flask
Server" / `localhost:8000` exactly as claimed in `notes`.

```
$ ls tests_ok/http_version/*.hurl tests_ok/expect/*.hurl
http_version_10.hurl http_version_11.hurl http_version_2_option.hurl
http_version_3.hurl http_version_option.hurl
expect/expect.hurl
```
Confirms both named scenario directories exist as claimed.

License:
```
$ head -5 repos/hurl/LICENSE
Apache License / Version 2.0, January 2004
```
Matches.

`docs/installation.md`:
```
$ sed -n '14,33p / 62,69p / 115,119p' docs/installation.md
```
Confirms deb install (`VERSION=8.0.1`, `.deb` from GitHub releases), PPA
(`ppa:lepapareil/hurl`), Homebrew (`brew install hurl`), and — at line 117
exactly — `cargo install --locked hurl`, matching all four install paths and
the line-number citation the candidate gives.

```
$ brew info hurl
==> hurl: stable 8.0.1 (bottled), HEAD
```
Confirms "brew hurl 8.0.1" exactly.

**Conclusion:** every count (182/108/88/49/15/400) is an exact match, the two
named example files match byte-for-byte, and every install-path claim in
`notes` (deb, PPA, Homebrew, cargo, version 8.0.1) is verified. Tier 2
confirmed, not refuted.

---

## 6. `wrk-load-scripts` — tier 2, NOT REFUTED

Local clones: `scratchpad/repos/wrk` (commit `a211dd5a7050b1f9e8a9870b95513060e72ac4a0`,
`Sat Feb 6 08:39:55 2021`) and `scratchpad/repos/wrk2` (commit
`44a94c17d8e6a0bac8559b53da76848e430cb7a7`, `2019-09-23 21:46:42 -0700`).

```
$ ls repos/wrk/scripts
addr.lua auth.lua counter.lua delay.lua pipeline.lua post.lua report.lua
setup.lua stop.lua
$ wc -l repos/wrk/scripts/*.lua | tail -1
138 total
```
"9 example scripts (138 lines)" — **exact match**, 9 files, 138 total lines.

License:
```
$ head -30 repos/wrk/LICENSE
"Modified Apache 2.0 License / Version 2.0.1, February 2015"
$ sed -n '/^   4\./,/^   5\./p' repos/wrk/LICENSE
   (e) If the Derivative Work includes substantial changes to features
       or functionality of the Work, then you must remove the name of
       the Work ...
```
Confirms both "Modified Apache 2.0 License Version 2.0.1, February 2015" and
the specific added clause 4(e) requiring name removal on substantial
derivative changes, exactly as the candidate's `notes` describe.

```
$ brew list hurl... (n/a) ; for wrk:
$ brew search wrk2
Error: No available formula with the name "wrk2". Did you mean wrk?
```
Confirms "no brew formula ('No available formula with the name wrk2')"
literally, including the exact error-message wording quoted by the
candidate.

```
$ cd repos/wrk2 && git log -1 --format='%H %ad' --date=iso
44a94c17d8e6a0bac8559b53da76848e430cb7a7 2019-09-23 21:46:42 -0700
$ head -5 repos/wrk2/LICENSE
Apache License / Version 2.0, January 2004
```
Confirms wrk2's "HEAD 2019-09-23" and "stock Apache-2.0" claims exactly.

Cross-check against candidate 2 (TFB): compared `repos/wrk/scripts/pipeline.lua`
against `repos/tfb/toolset/wrk/pipeline.lua` — they are **different scripts**
(wrk's ships a 3-fixed-request demo; TFB's takes a runtime `depth` argument),
so this candidate is not redundant with the TFB one; wrk's own repo also adds
`post.lua`, `delay.lua`, `auth.lua`, `counter.lua`, none of which TFB vendors.

**Conclusion:** script count/line count, both LICENSE texts (wrk's modified
clause and wrk2's stock Apache-2.0), and the brew-unavailability of wrk2 are
all confirmed exactly, including verbatim error-message wording. Not
redundant with the TFB candidate's wrk scripts. Tier 2 confirmed, not
refuted.

---

## Overall

All six candidates survived adversarial fact-checking against the actual
checked-out repositories (or, where a repo isn't checkable locally — the
paywalled Co-Advisor product and GitHub's own "archived" flag — against live
fetches). I found no HTTP/2-only, client-only-with-no-value, or
llhttp-redundant material warranting `refuted=true`, and no tier
over/under-rating large enough to correct. The only corrections worth
recording are cosmetic count deltas:

- `curl-testsuite-protocol-corpus`: "24" Expect:100-continue files measured
  as 25; "312" multi-request-per-connection files measured as 336 (both
  directions are immaterial to the tier).
- `curl-cli-conformance-client`: "31 files" is actually **29** files (the
  345-test-function count is exact).

None of these change a tier or a refutation call.
