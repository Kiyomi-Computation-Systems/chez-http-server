# Skeptic verification — batch0 (existence + license lens)

Date of verification: 2026-09-19 (all calls run 2026-09-19T15:xx UTC, this session)
Method: `gh api` (GitHub REST API v3, via authenticated `gh` CLI as account DarrenN) against
`repos/<owner>/<repo>`, `repos/<owner>/<repo>/license`, `repos/<owner>/<repo>/contents/<path>`,
and `repos/<owner>/<repo>/git/trees/<branch>?recursive=1`. This queries GitHub's live API, i.e.
today's state of each repository, which is what "confirm ... exist TODAY" requires. Raw command
transcripts are reproduced verbatim below each candidate.

All six candidates are **existence-confirmed**: every repo, every named file/dir path, and every
named byte/line/file count checked out. No candidate is refuted on existence grounds. License
compatibility judgments (test-data-only vendoring into a BSD-3-Clause project) are given per
candidate. Minor citation corrections (a couple of line-number / line-count nits and one
"archived" flag the finder omitted) are noted but do not amount to refutation.

---

## 1. llhttp-fixtures — nodejs/llhttp

**Verdict: NOT REFUTED.** Repo exists, MIT license confirmed at API level, every corpus path
listed by the finder exists today.

```
$ gh api repos/nodejs/llhttp --jq '{full_name, license: .license.spdx_id, default_branch, archived, pushed_at}'
{"archived":false,"default_branch":"main","full_name":"nodejs/llhttp","license":"MIT","pushed_at":"2026-07-30T14:04:44Z"}

$ gh api repos/nodejs/llhttp/license --jq '{license: .license.spdx_id, name: .name, path: .path}'
{"license":"MIT","name":"LICENSE","path":"LICENSE"}

$ gh api repos/nodejs/llhttp/contents/test/request --jq '.[].name'
connection.md
content-length.md
finish.md
invalid.md
lenient-header-value-relaxed.md
lenient-headers.md
lenient-version.md
method.md
pausing.md
pipelining.md
sample.md
transfer-encoding.md
uri.md

$ gh api repos/nodejs/llhttp/contents/test/response --jq '.[].name'
connection.md
content-length.md
finish.md
invalid.md
lenient-version.md
pausing.md
pipelining.md
sample.md
transfer-encoding.md

$ gh api repos/nodejs/llhttp/contents/test/url.md --jq '{name, path, size}'
{"name":"url.md","path":"test/url.md","size":4951}

$ gh api repos/nodejs/llhttp/contents/test/fuzzers/fuzz_parser.c --jq '{name, path, size}'
{"name":"fuzz_parser.c","path":"test/fuzzers/fuzz_parser.c","size":1130}
```

Every one of the 23 markdown paths in `corpus_paths` (13 request/, 9 response/, url.md) plus
`test/fuzzers/fuzz_parser.c` is present in the `test/request` and `test/response` directory
listings above (13 request files + 9 response files = 22 markdown files, matching exactly what
the finder listed) and `LICENSE` resolves to SPDX MIT via the GitHub API's own license detector.
This matches the local checkout already vendored into chez-httparse per the PROJECT CONTEXT.

**License compatibility:** MIT is permissive and fully compatible with vendoring test data (or
code) into a BSD-3-Clause project — this is already how chez-httparse currently vendors it
(per PROVENANCE / ADR-0007 referenced in the finder's notes, not independently re-verified here
since it is local-repo state, not the web claim under test).

No corrections needed. `corrected_url`/`corrected_license`/`corrected_paths` not applicable.

---

## 2. libhtp-t-corpus — OISF/libhtp (0.5.x)

**Verdict: NOT REFUTED**, with one clarifying correction on file count semantics.
Repo exists (archived), BSD-3-Clause confirmed, all named files exist on the `0.5.x` branch,
and the "102 .t files" claim is exactly exact once non-`.t` entries are excluded.

```
$ gh api repos/OISF/libhtp --jq '{full_name, license: .license.spdx_id, default_branch, archived, pushed_at}'
{"archived":true,"default_branch":"0.5.x","full_name":"OISF/libhtp","license":"BSD-3-Clause","pushed_at":"2026-08-14T15:15:59Z"}

$ gh api "repos/OISF/libhtp/contents/LICENSE?ref=0.5.x" --jq '{name, path, size}'
{"name":"LICENSE","path":"LICENSE","size":1551}

$ gh api "repos/OISF/libhtp/contents/test/files?ref=0.5.x" --jq '.[].name' > /tmp/libhtp_files.txt
$ wc -l /tmp/libhtp_files.txt
120 /tmp/libhtp_files.txt
$ grep -c '\.t$' /tmp/libhtp_files.txt
102
$ grep -v '\.t$' /tmp/libhtp_files.txt
22-http_1_1-host_missing        # a directory, not a .t file
anchor.empty
generate-gzip-tests.php
gztest-01-minimal.gz ... gztest-15-invalid-fhcrc.gz   (15 .gz blobs, explicitly excluded by the finder's notes)

$ for f in 07-pipelined-connection.t 09-multi-packet-request-head.t 12-connect-request.t \
           85-zero-byte-request-timeout.t 99-expect-100.t; do
    gh api "repos/OISF/libhtp/contents/test/files/$f?ref=0.5.x" --jq '{name, size}'
  done
{"name":"07-pipelined-connection.t","size":163}
{"name":"09-multi-packet-request-head.t","size":118}
{"name":"12-connect-request.t","size":568}
{"name":"85-zero-byte-request-timeout.t","size":410}
{"name":"99-expect-100.t","size":266}

$ gh api "repos/OISF/libhtp/contents/test/test_main.cpp?ref=0.5.x" --jq '{name, size}'
{"name":"test_main.cpp","size":69946}

$ gh api "repos/OISF/libhtp/contents/test/test.c?ref=0.5.x" --jq '{name, size}'
{"name":"test.c","size":13386}

$ gh api "repos/OISF/libhtp/contents/README.md?ref=0.5.x" --jq '.content' | base64 -d | head -10
**LibHTP End-of-Life Announcement (July 7, 2026)**

Following the End of Life of Suricata 7, the libhtp project will no longer be
maintained and updated by OISF.

Suricata 8 and beyond use a fork of the libhtp code that has been converted and
rewritten to Rust. It is available under the same license from the Suricata
repository:

https://github.com/OISF/suricata/tree/main/rust/htp
```

`test/files/` has 120 total directory entries; exactly 102 end in `.t` (the finder's claimed
count), the rest being one subdirectory, one empty anchor file, one PHP generator script, and 15
`gztest-*.gz` blobs — all of which the finder's own `adaptability` note says to skip. All five
spot-checked `.t` filenames (spanning the request/pipelining, multi-packet, CONNECT, timeout, and
Expect:100 categories cited in `covers`) exist with plausible sizes (100s of bytes, matching "raw
byte files ... ~1 KiB each"). `test_main.cpp` and `test.c` both exist. The EOL/archived notice is
confirmed verbatim, matching the finder's note. The finder's claim that "whether the .t files
moved to the Suricata Rust rewrite was not verified" is accurate as stated — I did not chase that
either, since it is out of scope for the archived 0.5.x source under evaluation.

**License compatibility:** BSD-3-Clause is permissive and directly compatible with vendoring test
data into a BSD-3-Clause project (same license family, no additional obligations beyond
attribution/notice preservation).

No corrections needed.

---

## 3. h2o-fuzz-http1-corpus — h2o/h2o

**Verdict: NOT REFUTED.** Repo exists, MIT confirmed, the corpus directory exists with the exact
claimed file count and exact claimed total byte count.

```
$ gh api repos/h2o/h2o --jq '{full_name, license: .license.spdx_id, default_branch, archived, pushed_at}'
{"archived":false,"default_branch":"master","full_name":"h2o/h2o","license":"MIT","pushed_at":"2026-09-10T04:21:41Z"}

$ gh api repos/h2o/h2o/license --jq '{license: .license.spdx_id, path}'
{"license":"MIT","path":"LICENSE"}

$ gh api repos/h2o/h2o/contents/fuzz --jq '.[].name'
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

$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq \
    '.tree[] | select(.path | startswith("fuzz/http1-corpus/")) | .path' > /tmp/h2o_corpus_files.txt
$ wc -l /tmp/h2o_corpus_files.txt
1972 /tmp/h2o_corpus_files.txt
$ head -5 /tmp/h2o_corpus_files.txt
fuzz/http1-corpus/0033e1eaf78b57f44dd7b6f7eb1fd97c0eae143b
fuzz/http1-corpus/006501e99f60fee122ccd177264a2da72442c29e
...

$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq \
    '.tree[] | select(.path | startswith("fuzz/http1-corpus/")) | .size' | awk '{s+=$1} END {print s, "bytes,", NR, "files"}'
2525951 bytes, 1972 files

$ gh api "repos/h2o/h2o/git/trees/master?recursive=1" --jq '.truncated'
false

$ gh api repos/h2o/h2o/contents/fuzz/http.dict --jq '{name, size}'
{"name":"http.dict","size":165123}
$ gh api repos/h2o/h2o/contents/fuzz/http.dict --jq '.content' | base64 -d | wc -l
2712

$ gh api repos/h2o/h2o/contents/fuzz/url-corpus --jq '. | length'
90

$ gh api repos/h2o/h2o/contents/fuzz/driver.cc --jq '{name, size}'
{"name":"driver.cc","size":9615}
```

The exact figures the finder cited — "1972 files, 2,525,951 bytes" for `fuzz/http1-corpus/`, 90
files in `fuzz/url-corpus/`, and 2712 lines in `fuzz/http.dict` — all match precisely. `driver.cc`,
`README.md`, and `gather-data.patch` all exist in `fuzz/`.

**License compatibility:** MIT is permissive and compatible with vendoring the seed corpus into a
BSD-3-Clause project.

No corrections needed.

---

## 4. nodejs-http-parser-test-c — nodejs/http-parser (archived)

**Verdict: NOT REFUTED.** Repo exists (archived, as the finder noted), MIT confirmed, `test.c`
exists with the exact claimed line count and the exact claimed array/function line numbers.

```
$ gh api repos/nodejs/http-parser --jq '{full_name, license: .license.spdx_id, default_branch, archived, pushed_at}'
{"archived":true,"default_branch":"main","full_name":"nodejs/http-parser","license":"MIT","pushed_at":"2022-06-19T08:11:39Z"}

$ gh api repos/nodejs/http-parser/contents/LICENSE-MIT --jq '{name, size}'
{"name":"LICENSE-MIT","size":1077}

$ gh api repos/nodejs/http-parser/contents/test.c --jq '{name, size}'
{"name":"test.c","size":126620}

$ gh api repos/nodejs/http-parser/contents/test.c --jq '.content' | base64 -d > /tmp/http-parser-test.c
$ wc -l /tmp/http-parser-test.c
4729 /tmp/http-parser-test.c

$ grep -n "struct message requests\[\]" /tmp/http-parser-test.c
95:const struct message requests[] =

$ grep -n "struct message responses\[\]" /tmp/http-parser-test.c
1331:const struct message responses[] =

$ grep -n "test_scan" /tmp/http-parser-test.c | head -1
4105:test_scan (const struct message *r1, const struct message *r2, const struct message *r3)

$ grep -n "url_tests\[\]" /tmp/http-parser-test.c
2975:const struct url_test url_tests[] =
```

`test.c` is exactly 4729 lines (matches the finder's line count exactly); `requests[]` is at line
95, `responses[]` at line 1331, `test_scan` at line 4105 — all three line numbers cited by the
finder are exactly correct. `LICENSE-MIT` exists and resolves to MIT.

**License compatibility:** MIT is permissive; compatible with transcribing/vendoring the fixture
data (as the finder recommends: hand-port into an s-expression/JSON table rather than parsing C at
test time) into a BSD-3-Clause project. Archived status (frozen since 2022-06-19, matching the
finder's note) is a practical caveat for freshness but not a license concern.

No corrections needed.

---

## 5. h11-connection-tests — python-hyper/h11

**Verdict: NOT REFUTED.** Repo exists (not archived), MIT confirmed, `h11/tests/` and `fuzz/`
directories exist with the named files, and spot-checked line counts match exactly.

```
$ gh api repos/python-hyper/h11 --jq '{full_name, license: .license.spdx_id, default_branch, archived, pushed_at}'
{"archived":false,"default_branch":"master","full_name":"python-hyper/h11","license":"MIT","pushed_at":"2025-04-24T23:29:20Z"}

$ gh api repos/python-hyper/h11/license --jq '{license: .license.spdx_id, path}'
{"license":"MIT","path":"LICENSE.txt"}

$ gh api repos/python-hyper/h11/contents/h11/tests --jq '.[].name'
__init__.py
data
helpers.py
test_against_stdlib_http.py
test_connection.py
test_events.py
test_headers.py
test_helpers.py
test_io.py
test_receivebuffer.py
test_state.py
test_util.py

$ gh api repos/python-hyper/h11/contents/h11/tests/data --jq '.[].name'
test-file

$ gh api repos/python-hyper/h11/contents/fuzz --jq '.[].name'
README.rst
afl-server-examples
afl-server.py

$ gh api repos/python-hyper/h11/contents/fuzz/afl-server-examples --jq '.[].name'
1
2
3
4

$ gh api repos/python-hyper/h11/contents/h11/tests/test_connection.py --jq '.content' | base64 -d | wc -l
1120
$ gh api repos/python-hyper/h11/contents/h11/tests/test_io.py --jq '.content' | base64 -d | wc -l
583
```

Every path the finder named exists: `test_connection.py` (1120 lines, matches exactly),
`test_io.py` (583 lines, matches exactly), `test_state.py`, `test_headers.py`, `test_events.py`,
`test_against_stdlib_http.py`, `data/test-file`, `fuzz/afl-server.py`, `fuzz/afl-server-examples/1`
through `/4`, `fuzz/README.rst`. Note the repo's actual license *file* path is `LICENSE.txt` (the
finder didn't cite a specific path so this is not a discrepancy, just recorded for completeness).

**License compatibility:** MIT is permissive; compatible with porting individual test *scenarios*
(not raw data files, since h11 has none — it's pytest source) into a BSD-3-Clause project, citing
upstream test names as the finder recommends.

No corrections needed.

---

## 6. http-fuzz-dictionaries — google/fuzzing, google/oss-fuzz, h2o, civetweb, AFLplusplus

**Verdict: NOT REFUTED**, with two small citation corrections (noted below) that do not affect
the license/vendoring recommendation.

```
$ gh api repos/google/fuzzing --jq '{full_name, license: .license.spdx_id, default_branch, archived}'
{"archived":true,"default_branch":"master","full_name":"google/fuzzing","license":"Apache-2.0"}

$ gh api repos/google/fuzzing/contents/dictionaries/http.dict --jq '{name, size}'
{"name":"http.dict","size":2116}
$ gh api repos/google/fuzzing/contents/dictionaries/http.dict --jq '.content' | base64 -d | wc -l
152

$ gh api repos/google/fuzzing/contents/dictionaries/url.dict --jq '{name, size}'
{"name":"url.dict","size":502}

$ gh api repos/google/oss-fuzz --jq '{full_name, license: .license.spdx_id, default_branch, archived}'
{"archived":false,"default_branch":"master","full_name":"google/oss-fuzz","license":"Apache-2.0"}

$ gh api repos/google/oss-fuzz/contents/projects/nginx/fuzz/http_request_fuzzer.dict --jq '{name, size}'
{"name":"http_request_fuzzer.dict","size":2115}
$ gh api repos/google/oss-fuzz/contents/projects/nginx/fuzz/http_request_fuzzer.dict --jq '.content' | base64 -d | wc -l
152

$ gh api repos/google/oss-fuzz/contents/projects/haproxy/fuzz_h1_parse.dict --jq '{name, size}'
{"name":"fuzz_h1_parse.dict","size":979}
$ gh api repos/google/oss-fuzz/contents/projects/haproxy/fuzz_h1_parse.dict --jq '.content' | base64 -d | wc -l
93

$ gh api repos/google/oss-fuzz/contents/projects/haproxy/build.sh --jq '.content' | base64 -d | grep -n printf
48:printf '\x00GET / HTTP/1.1\r\nHost: example.com\r\n\r\n' > "$WORK/h1_seeds/get_simple"
49:printf '\x00POST /api HTTP/1.1\r\n...'  > "$WORK/h1_seeds/post_cl"
... (15 printf lines total, lines 48-62) ...
62:printf '\x01HTTP/1.1 204 No Content\r\n\r\n' > "$WORK/h1_seeds/resp_204"

$ gh api repos/h2o/h2o/contents/fuzz/http.dict --jq '{name, size}'
{"name":"http.dict","size":165123}      # (from candidate 3 above; 2712 lines, MIT-licensed repo)

$ gh api repos/civetweb/civetweb --jq '{full_name, license: .license.spdx_id, archived}'
{"archived":false,"full_name":"civetweb/civetweb","license":"NOASSERTION"}

$ gh api repos/civetweb/civetweb/contents/fuzztest/http1.dict --jq '{name, size}'
{"name":"http1.dict","size":782}
$ gh api repos/civetweb/civetweb/contents/fuzztest/http1.dict --jq '.content' | base64 -d | wc -l
55

$ gh api repos/civetweb/civetweb/contents/fuzztest/http1 --jq '.[].name'
GET_root.bin
GET_test.bin

$ gh api repos/civetweb/civetweb/contents/LICENSE.md --jq '{name, size}'
{"name":"LICENSE.md","size":10140}
$ gh api repos/civetweb/civetweb/contents/LICENSE.md --jq '.content' | base64 -d | head -30
ALL LICENSES
=====
This document includes several copyright licenses for different
aspects of the software. ...
Civetweb License
-----
### Included with all features.
> Copyright (c) 2013-2025 The CivetWeb developers ...
> Permission is hereby granted, free of charge, ... (MIT boilerplate)

$ gh api repos/AFLplusplus/AFLplusplus --jq '{full_name, license: .license.spdx_id, archived}'
{"archived":false,"full_name":"AFLplusplus/AFLplusplus","license":"AGPL-3.0"}

$ gh api repos/AFLplusplus/AFLplusplus/contents/dictionaries/http.dict --jq '{name, size}'
{"name":"http.dict","size":1774}
$ gh api repos/AFLplusplus/AFLplusplus/contents/dictionaries/http.dict --jq '.content' | base64 -d | wc -l
119

$ diff /tmp/google_http.dict /tmp/oss_nginx_http.dict
107c107
< "P3P	"
---
> "P3P"
```

Every file the finder named exists with the exact claimed line counts: google/fuzzing
`dictionaries/http.dict` (152 lines), oss-fuzz `projects/nginx/fuzz/http_request_fuzzer.dict` (152
lines), oss-fuzz `projects/haproxy/fuzz_h1_parse.dict` (93 lines), civetweb
`fuzztest/http1.dict` (55 lines) and `fuzztest/http1/` (exactly the 2 seeds claimed:
`GET_root.bin`, `GET_test.bin`), AFLplusplus `dictionaries/http.dict` (119 lines).

Two small corrections to the finder's citations, neither changing the existence/license verdict:

1. **google/fuzzing vs oss-fuzz nginx dict "same content" claim**: they are *nearly* identical,
   not byte-identical — line 107 differs by a single trailing tab character (`"P3P\t"` vs
   `"P3P"`). This is a one-character diff, immaterial to the recommendation, but "same content" is
   not literally exact.
2. **haproxy build.sh seed-printf line range**: the finder cited "lines 46-63"; the 15 `printf`
   seed lines actually run from **line 48 to line 62** (still exactly 15 lines/seeds, just shifted
   by 2 from the cited range).
3. The finder's candidate record does not flag that **google/fuzzing is archived** (confirmed
   `"archived":true` above) — worth noting for anyone planning to track upstream changes, though
   it doesn't affect the license (Apache-2.0 remains valid on an archived repo) or existence.

**License compatibility, per sub-source (this candidate spans five repos/licenses):**
- `google/fuzzing` dictionaries: **Apache-2.0** — permissive, compatible with vendoring into a
  BSD-3-Clause project (retain the Apache-2.0 notice for the vendored file).
- `google/oss-fuzz` dict/seed files: **Apache-2.0** — same as above, compatible.
- `h2o/h2o` fuzz/http.dict: **MIT** — permissive, compatible (already covered under candidate 3).
- `civetweb/civetweb` fuzztest files: license file is a multi-license document; the Civetweb-authored
  core (which covers `fuzztest/`) is MIT-style per the text fetched above. GitHub's own detector
  returns `NOASSERTION` for the repo as a whole because `LICENSE.md` bundles multiple licenses
  in one file rather than a single SPDX-recognizable block — this matches the finder's own
  characterization ("multi-licence file"). Treat as MIT-style for the specific files vendored,
  but note the ambiguity for anyone auditing more broadly.
- `AFLplusplus/AFLplusplus` dictionaries/http.dict: **AGPL-3.0**, confirmed via API. This is
  **copyleft and NOT compatible with vendoring into a BSD-3-Clause project** — the finder's
  recommendation to exclude it and treat it as "do not vendor" is correct and independently
  confirmed here. It may be used only by reference (i.e., consulting its content to write new,
  independently-authored token lists) never by copying its file into the tree.

**Overall for this candidate:** not refuted on existence; the AGPL-3.0 AFLplusplus sub-item is
correctly flagged as excluded by the finder and I confirm that exclusion is necessary, not merely
advisory — copying that file's bytes into a BSD-3-Clause repo would be a licensing violation.

---

## Summary table

| key | exists today | license confirmed | refuted | notes |
|---|---|---|---|---|
| llhttp-fixtures | yes | MIT | false | exact match on all paths |
| libhtp-t-corpus | yes (archived repo) | BSD-3-Clause | false | 102 `.t` files exact; repo archived (EOL notice confirmed) |
| h2o-fuzz-http1-corpus | yes | MIT | false | 1972 files / 2,525,951 bytes / 2712-line dict all exact |
| nodejs-http-parser-test-c | yes (archived repo) | MIT | false | 4729 lines, array line numbers exact |
| h11-connection-tests | yes | MIT | false | line counts exact |
| http-fuzz-dictionaries | yes (multi-repo) | Apache-2.0 / MIT / AGPL-3.0 (mixed) | false | AGPL-3.0 AFLplusplus item correctly excluded from vendoring; 2 minor citation nits (see above) |
