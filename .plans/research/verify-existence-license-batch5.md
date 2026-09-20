# Skeptic verification — batch 5 (existence + license lens)

Verification date: 2026-09-19. Method: `gh api` (authenticated GitHub REST API, account DarrenN)
against each repo's Contents API and Git Trees API, fetching directory listings and file/LICENSE
content directly (no cloning, no WebFetch needed — `gh` was available and authenticated). All
`gh api repos/<owner>/<repo>/contents/<path> --jq '.content'` outputs were base64-decoded locally.

Goal: for each candidate, confirm (1) the repo and every named corpus path exist TODAY, (2) the
SPDX license reported by GitHub and the LICENSE file text agree with the finder's claim, and (3)
whether vendoring the *test data* (not code) into a BSD-3-Clause project (chez-http-server) is
license-compatible. Default `refuted=true` on any existence failure.

---

## 1. `warp-run-and-connection-specs` — yesodweb/wai warp/test

**Repo check:**
```
$ gh api repos/yesodweb/wai --jq '.license, .default_branch'
{"key":"mit","name":"MIT License","node_id":"MDc6TGljZW5zZTEz","spdx_id":"MIT","url":"https://api.github.com/licenses/mit"}
master
```
Matches candidate's claimed `MIT` and the `tree/master` in the URL.

**Directory listing** (`gh api repos/yesodweb/wai/contents/warp/test --jq '.[].name'`):
```
BufferSpec.hs
ConduitSpec.hs
ConnectionSpec.hs
EarlyHintsSpec.hs
ExceptionSpec.hs
FdCacheSpec.hs
FileSpec.hs
GracefulShutdownSpec.hs
HTTP.hs
PackIntSpec.hs
ReadIntSpec.hs
RequestSpec.hs
ResponseHeaderSpec.hs
ResponseSpec.hs
RunSpec.hs
SendFileSpec.hs
ServerStateSpec.hs
Spec.hs
WithApplicationSpec.hs
doctests.hs
head-response
inputFile
```
All 7 named corpus paths (`RunSpec.hs`, `RequestSpec.hs`, `ConnectionSpec.hs`,
`GracefulShutdownSpec.hs`, `ResponseSpec.hs`, `ExceptionSpec.hs`, `SendFileSpec.hs`) exist. Bonus:
`ResponseHeaderSpec.hs` (mentioned in `approx_cases` as "ResponseHeader 5") also exists but was not
listed in `corpus_paths` — worth adding but not a refutation.

**LICENSE content** (`gh api repos/yesodweb/wai/contents/LICENSE`):
```
Copyright (c) 2012-2017 Michael Snoyman, http://www.yesodweb.com/

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, ...
```
Standard MIT text. Confirms `license: MIT`.

**Verdict: NOT REFUTED.** Repo, all 7 corpus paths, and MIT license confirmed live. MIT is
maximally permissive; vendoring the `.hs` spec files' *test-case data* (request/response byte
fixtures embedded in the specs) as inspiration/checklist, or verbatim with the MIT notice
retained, is fully compatible with a BSD-3-Clause project. Candidate's own plan (manual
translation, not verbatim vendoring) is conservative and safe either way.

---

## 2. `aiohttp-parser-and-web-protocol-tests` — aio-libs/aiohttp tests

**Repo check:**
```
$ gh api repos/aio-libs/aiohttp --jq '.license, .default_branch'
{"key":"apache-2.0","name":"Apache License 2.0","node_id":"MDc6TGljZW5zZTI=","spdx_id":"Apache-2.0","url":"https://api.github.com/licenses/apache-2.0"}
master
```
Matches candidate's `Apache-2.0` and `tree/master`.

**Directory listing** (`gh api repos/aio-libs/aiohttp/contents/tests --jq '.[].name'`, filtered):
```
test_base_protocol.py
test_http_parser.py
test_http_writer.py
test_web_functional.py
test_web_protocol.py
test_web_request_handler.py
test_web_server.py
```
All 6 of the `tests/*.py` paths named in `corpus_paths` exist (`test_http_parser.py`,
`test_web_protocol.py`, `test_web_server.py`, `test_web_functional.py`,
`test_web_request_handler.py`, `test_base_protocol.py`). `aiohttp/_http_parser.pyx` confirmed
present. `vendor/` directory confirmed present with `README.rst` and an `llhttp` subdirectory,
matching the candidate's note that aiohttp vendors llhttp as its C parser.

**LICENSE.txt content** (`gh api repos/aio-libs/aiohttp/contents/LICENSE.txt`):
```
Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
   1. Definitions. ...
```
Standard Apache-2.0 text, filename `LICENSE.txt` (candidate said `Apache-2.0`, correct).
Checked for a repo-root `NOTICE` file (Apache-2.0 §4(d) requires NOTICE preservation only if
one exists upstream): `gh api repos/aio-libs/aiohttp/contents/NOTICE` → `404 Not Found`. No
NOTICE file exists, so only the LICENSE text itself needs to travel with any vendored copy.

**Verdict: NOT REFUTED.** Repo, all 8 corpus paths, and Apache-2.0 confirmed. Apache-2.0 is
permissive and compatible with a BSD-3-Clause project (attribution + LICENSE text required, no
NOTICE file to preserve). Candidate itself correctly demotes this to tier 3 "reference only"
since the parser tests exercise llhttp (already covered by chez-httparse's own llhttp fixture
suite) and the raw-socket functional tests are small in number — this is a sound assessment,
not something to refute.

---

## 3. `cpython-httpservers-httplib-tests` — python/cpython Lib/test

**Repo check:**
```
$ gh api repos/python/cpython --jq '.license, .default_branch'
{"key":"other","name":"Other","node_id":"MDc6TGljZW5zZTA=","spdx_id":"NOASSERTION","url":null}
main
```
GitHub's repo-level SPDX detector reports `NOASSERTION` (composite license file confuses the
detector), exactly as the candidate's `notes` field claims. Confirms the candidate did not
mis-cite this — `NOASSERTION` at the repo-metadata level is real and expected.

**File existence:**
```
$ gh api repos/python/cpython/contents/Lib/test/test_httpservers.py --jq '.name, .size'
test_httpservers.py
72440
$ gh api repos/python/cpython/contents/Lib/test/test_httplib.py --jq '.name, .size'
test_httplib.py
109455
```
Both files exist on `main` today, non-trivial sizes (72 KB / 109 KB) consistent with the claimed
~103 and ~131 test cases respectively.

**LICENSE content** (`gh api repos/python/cpython/contents/LICENSE`, lines 60–95):
```
Python software and documentation are licensed under the
Python Software Foundation License Version 2.
...
PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2
--------------------------------------------
1. This LICENSE AGREEMENT is between the Python Software Foundation
("PSF"), and the Individual or Organization ("Licensee") ...
```
This confirms the actual SPDX identifier for the bulk of the CPython tree is `PSF-2.0`
(candidate said `PSF-2.0`), matching. Note the candidate's `notes` field cited "line 73" for the
PSF marker; on the currently fetched copy the "PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2"
heading is at decoded line 74 (off by one, immaterial — the substance of the claim is correct:
the license is composite and the PSF-2.0 terms are what govern `Lib/test/*`).

**Verdict: NOT REFUTED** (minor line-number correction only, not existence/license-worthy).
PSF-2.0 is a permissive, BSD-style license (not copyleft) but carries a non-standard clause
(§3: derivative works must include "a brief summary of the changes made to Python") that doesn't
transplant cleanly onto a small vendored test-data excerpt — this is a reason to treat it as
"reference only" (as the candidate already does, tier 3), not a reason to refute existence or
mis-license. Compatible for reference/adaptation into BSD-3-Clause; verbatim vendoring would need
the PSF notice retained and is unusual for a small excerpt, so citation-based reuse (as the
candidate proposes) is the right call.

---

## 4. `aws-http-desync-guardian` — aws/http-desync-guardian test YAMLs

**Repo check:**
```
$ gh api repos/aws/http-desync-guardian --jq '.license, .default_branch'
{"key":"apache-2.0","name":"Apache License 2.0","node_id":"MDc6TGljZW5zZTI=","spdx_id":"Apache-2.0","url":"https://api.github.com/licenses/apache-2.0"}
main
```
Matches candidate's `Apache-2.0`.

**`tests/` directory listing:**
```
README.md
acceptable.yaml
ambiguous.yaml
bad-header-characters.yaml
edge-cases.yaml
more-compliant-tests.yaml
real-life-test-cases.yaml
rfc-compliant.yaml
severe.yaml
single-case.yaml
uri-specific-test-cases.yaml
```
All 10 of the `tests/*.yaml` + `tests/README.md` paths named exist.

**`docs/` directory listing:**
```
README.md
close-be-connections-layer-in-front.png
close-be-connections.png
close-fe-be-connections.png
diagrams
http-desync-guardian-logo.png
```
`docs/README.md` exists as claimed.

**Root listing confirms** `LICENSE` and `NOTICE` both present:
```
LICENSE
NOTICE
```
`NOTICE` content (base64-decoded): `Copyright Amazon.com, Inc. or its affiliates. All Rights
Reserved.` — this is real and, per Apache-2.0 §4(d), must be preserved/reproduced by anyone
redistributing (including vendoring) the material.

**`tests/README.md` content** (excerpt) confirms the format description in the candidate's
`format` field is accurate — "Testing tenet: Focus on reviewability. The test suite must require
no knowledge about the library/programming languages but only about HTTP protocol," RFC 7230
§3.2 ABNF definitions quoted, YAML schema documented with `name/uri/method/version/headers/tier`
fields — matches candidate's `format` and `adaptability` description essentially verbatim.

**Verdict: NOT REFUTED.** Repo, all 12 named paths, and Apache-2.0 confirmed live, plus a real
NOTICE file the candidate should have flagged as a preservation requirement (it mentions
Apache-2.0 permits vendoring but doesn't explicitly call out the NOTICE obligation — worth adding
to the corpus write-up, not grounds for refutation). Apache-2.0 test-data vendoring into
BSD-3-Clause is compatible and precedented exactly as chez-httparse already vendors llhttp
fixtures with a PROVENANCE file; the same pattern (LICENSE + NOTICE + PROVENANCE) should be used
here.

---

## 5. `h2o-http1-corpus` — h2o/h2o fuzz/http1-corpus

**Repo check:**
```
$ gh api repos/h2o/h2o --jq '.license, .default_branch'
{"key":"mit","name":"MIT License","node_id":"MDc6TGljZW5zZTEz","spdx_id":"MIT","url":"https://api.github.com/licenses/mit"}
master
```
Matches candidate's `MIT`.

**`fuzz/` directory listing:**
```
README.md
driver.cc
driver_common.cc
driver_common.h
driver_h3.cc
driver_url.cc
gather-data.patch
h3_header_generator.c
http.dict
http1-corpus
http2-corpus
http3-corpus
http3-test-inputs
quicly_mock.c
quicly_mock.h
url-corpus
```
`fuzz/http1-corpus/`, `fuzz/url-corpus/`, `fuzz/README.md`, `fuzz/http.dict`, `fuzz/driver.cc` all
confirmed present.

**File-count verification** via the Git Trees API (recursive, non-truncated —
`gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq '.truncated'` → `false`, so the count is
exhaustive, not paginated/estimated):
```
$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq '.tree[] | select(.path | startswith("fuzz/http1-corpus/")) | .path' | wc -l
1972
$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq '.tree[] | select(.path | startswith("fuzz/url-corpus/")) | .path' | wc -l
90
```
Both exactly match the candidate's claimed counts (1972 files in http1-corpus, 90 in url-corpus),
and independently corroborate the candidate's own note that the naive Contents-API listing
under-reports (GitHub's Contents API paginates directory listings at 1000 entries; the Git Trees
API with `recursive=1` is the correct way to get an exhaustive count, and it agrees with the
candidate's claimed method and figure exactly).

**Marker mechanism verification** — the candidate's `format` field claims each corpus file
self-encodes chunk boundaries via a literal `\n--MARK--\n` marker split by the fuzzer driver at
`fuzz/driver.cc:153`. Confirmed:
```
$ gh api repos/h2o/h2o/contents/fuzz/driver.cc --jq '.content' | base64 -d | grep -n MARK
153:#define MARKER "\n--MARK--\n"
156:                char *p = (char *)memmem(buf + pos, len - pos, MARKER, sizeof(MARKER) - 1);
161:                    pos += sizeof(MARKER) - 1;
```
Line number (153) and marker string match the candidate's claim exactly.

**LICENSE content:** `Copyright (c) 2014 DeNA Co., Ltd.` + standard MIT permission/warranty text
— matches candidate's `notes` field verbatim ("MIT (LICENSE = 'Copyright (c) 2014 DeNA Co.,
Ltd.')").

**Verdict: NOT REFUTED.** This candidate's every specific, checkable claim (file counts, marker
line number, license copyright holder) was independently reproduced exactly. MIT is maximally
permissive; vendoring the corpus (a 2.5 MB directory of raw byte fixtures, no code) verbatim into
`test/vendor/h2o-http1-corpus/` with a PROVENANCE file (as the candidate proposes, mirroring
chez-httparse's existing llhttp vendoring pattern) is fully compatible with BSD-3-Clause.

---

## 6. `nodejs-smuggling-tests` — nodejs/node HTTP smuggling regression tests

**Repo check:**
```
$ gh api repos/nodejs/node --jq '.license, .default_branch'
{"key":"other","name":"Other","node_id":"MDc6TGljZW5zZTA=","spdx_id":"NOASSERTION","url":null}
main
```
GitHub reports `NOASSERTION` at repo-metadata level (composite LICENSE, as candidate's `notes`
states) but the actual LICENSE file's *first* section (the one covering Node's own code,
including `test/`) is plain MIT:
```
$ gh api repos/nodejs/node/contents/LICENSE --jq '.content' | base64 -d | head -25
Node.js is licensed for use as follows:
"""
Copyright Node.js contributors. All rights reserved.
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions: ...
"""
This license applies to parts of Node.js originating from the
https://github.com/joyent/node repository:
"""
Copyright Joyent, Inc. and other Node contributors. All rights reserved.
...
```
Confirms candidate's `license: MIT` for the core tree (the `test/parallel/*.js` files fall under
this top MIT block, not any of the third-party vendored-dependency licenses further down the same
composite file). Saved full LICENSE text to
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/nodejs_LICENSE.txt`.

**File existence** — all 8 named paths confirmed present on `main` via Contents API (each
returned its filename, none 404'd):
```
test-http-chunked-smuggling.js
test-http-transfer-encoding-smuggling.js
test-http-transfer-encoding-repeated-chunked.js
test-http-dummy-characters-smuggling.js
test-http-request-smuggling-content-length.js
test-http-server-reject-chunked-with-content-length.js
test-http-double-content-length.js
test-http-content-length-mismatch.js
```

**Content spot-check** — fetched `test-http-transfer-encoding-smuggling.js` and
`test-http-transfer-encoding-repeated-chunked.js` in full. Confirmed the described payload shapes:
the smuggling test sends `Transfer-Encoding: chunked` + `Transfer-Encoding: chunked-false` with a
smuggled second request and asserts the handler is never called
(`common.mustNotCall((req, res) => {...}, 1)`) and the client sees exactly
`HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n`; the repeated-chunked test sends
`Transfer-Encoding: chunkedchunked` and asserts `req.on('data', common.mustNotCall())`. Both match
the candidate's `covers` field precisely.

**CVE-mapping verification** — the candidate's `notes` field claims specific git-blame CVE
mappings. Pulled commit history via `gh api "repos/nodejs/node/commits?path=<file>"`:
- `test-http-transfer-encoding-smuggling.js` commit messages include:
  `CVE-ID: CVE-2024-27982` (OBS fold), `CVE-ID: CVE-2022-32213, CVE-2022-32215, CVE-2022-35256`
  (OBS fold disables chunked), `CVE-ID: CVE-2022-32215,CVE-2022-32214,CVE-2022-32212` (stricter
  TE/separator parsing), `CVE-ID: CVE-2020-8287` (original test add, `nodejs-private/llhttp-private#3`).
  Union: {CVE-2020-8287, CVE-2022-32212, CVE-2022-32213, CVE-2022-32214, CVE-2022-32215,
  CVE-2022-35256, CVE-2024-27982} — **exactly** matches the candidate's claimed set for this file.
- `test-http-transfer-encoding-repeated-chunked.js` commit messages include:
  `CVE-ID: CVE-2022-32215,CVE-2022-32214,CVE-2022-32212` — matches the candidate's claimed
  `CVE-2022-32212/14/15` for this file.

**Verdict: NOT REFUTED.** Repo, all 8 paths, license, content shape, and every specific CVE
mapping the candidate cited were independently reproduced from git commit trailers. MIT license
on the core tree (including `test/`) is maximally permissive; the candidate's plan to
re-implement the byte payloads as original Scheme fixtures (citing the Node file + CVE) rather
than copying the JS harness verbatim is conservative and clean either way — even verbatim
byte-literal extraction would be MIT-compatible with attribution.

---

## Summary table

| key | existence | license as claimed | vendoring compatible w/ BSD-3-Clause | refuted |
|---|---|---|---|---|
| warp-run-and-connection-specs | confirmed, all 7 paths | MIT confirmed | yes (permissive) | false |
| aiohttp-parser-and-web-protocol-tests | confirmed, all 8 paths | Apache-2.0 confirmed, no NOTICE file exists | yes (permissive, reference-only per finder — sound) | false |
| cpython-httpservers-httplib-tests | confirmed, both files + LICENSE | PSF-2.0 confirmed (repo-level NOASSERTION is real but expected, matches finder's own caveat) | yes as reference/citation; verbatim vendoring needs PSF derivative-summary clause honored | false |
| aws-http-desync-guardian | confirmed, all 12 paths incl. docs/README.md | Apache-2.0 confirmed; NOTICE file exists (Amazon copyright) and must be preserved on vendoring | yes, precedented (mirrors chez-httparse's llhttp vendoring) | false |
| h2o-http1-corpus | confirmed, exact file counts reproduced (1972 / 90) via non-truncated git tree | MIT confirmed, copyright holder matches | yes (permissive) | false |
| nodejs-smuggling-tests | confirmed, all 8 files + content + CVE mappings reproduced from commit trailers | MIT confirmed (core-tree block of composite LICENSE) | yes (permissive) | false |

No candidate was refuted. No `corrected_url` / `corrected_license` / `corrected_paths` are
needed for any candidate — every URL, path, and license claim checked out exactly as the finder
reported it. Two small addenda worth passing to the synthesis agent (not refutations):
1. Candidate 4 (aws-http-desync-guardian) should explicitly carry forward its NOTICE file
   (`Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.`) alongside its LICENSE
   when vendored, per Apache-2.0 §4(d).
2. Candidate 3 (cpython)'s "line 73" citation for the PSF-2.0 heading is off by one on the
   currently fetched `main` copy (it's at decoded line 74) — immaterial, the substantive claim is
   correct.
