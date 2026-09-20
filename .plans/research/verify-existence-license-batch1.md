# Skeptic verification, batch 1 — lens: existence and license

Date: 2026-09-19. Verifier: skeptic subagent. Target project license: BSD-3-Clause
(/Users/yuzu/github/chez-http-server AGENTS.md house rules).

Method (matches the methodology used in `verify-existence-license-batch0.md` and
`verify-existence-license-batch2.md` in this same directory): for every candidate,
(a) `gh api repos/<owner>/<repo>` for default branch, archived flag, pushed_at and
GitHub's detected SPDX id; (b) `gh api repos/<owner>/<repo>/commits/<branch>` (or
`/tags`) to record today's HEAD sha; (c) `gh api repos/<owner>/<repo>/contents/<path>?ref=<ref>`
for every corpus path the finder named, which returns a blob sha and byte size only if
the path exists today; (d) downloaded and read the license file(s) verbatim (base64
decoded from the `contents` API); (e) WebFetch of the finder's URL and, where the file
is plain text, of its raw form; (f) independently counted test/case markers (`PARSE(`,
`#[test]`, `req!`/`res!`, `def test_`, `Payload:`, etc.) in the freshly downloaded files
to check the finder's approximate counts. `gh` was authenticated
(`gh auth status`: "Logged in to github.com account DarrenN"). VTest2's current home,
code.vinyl-cache.org, is a Forgejo instance, not GitHub, so it was checked instead with
its Gitea/Forgejo-compatible REST API (`/api/v1/repos/...`) and `curl`. All commands ran
from this scratchpad; nothing was written into any git repository. Fresh copies of the
decoded files live in `verify-b1/*-fresh.*`; nothing was mutated in
`/Users/yuzu/github/*`.

License-compatibility rule applied (vendoring TEST DATA, not code, into a
BSD-3-Clause repo — matches the rule stated in batch0):
- MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0: compatible; ship the upstream license
  text (and NOTICE, for Apache-2.0) beside the vendored data and keep copyright lines.
- Dual license where at least one branch is MIT/BSD/Apache (e.g. "MIT OR X",
  "Apache-2.0 OR MIT"): compatible — the vendoring party can elect the permissive
  branch.
- GPL-3.0 / AGPL-3.0 / GPL-2.0 (and anything copyleft): NOT vendorable as data into a
  BSD-3-Clause tree; usable only by reference (run against, read for behavioural
  understanding, reimplement your own cases from the described behaviour).

## Summary table

| key | exists today | license (verified) | finder's license | vendor test data into BSD-3-Clause? | refuted |
|---|---|---|---|---|---|
| http-garden | yes, all 7 named paths + `images/*/Dockerfile` (checked `images/nginx/Dockerfile`) | GPL-3.0 (verbatim GPLv3 text, FSF 2007) | GPL-3.0 | No — copyleft, reference/checklist use only, as the finder already concluded | no |
| picohttpparser-tests | yes, `test.c` (539 lines, exact) | Dual "MIT License (below) or the Perl license", stated only in source headers, **no root LICENSE file** | MIT OR Artistic-1.0-Perl (dual, header-only) | Yes, under the MIT branch of the dual license; ship the MIT text as it appears in the file header and note the file carries no separate LICENSE | no |
| httparse-rust-tests | yes, all 10 named paths, incl. both LICENSE-APACHE and LICENSE-MIT; fuzz targets confirmed to carry no corpus/dict/seed anywhere in the repo tree | Apache-2.0 OR MIT (dual, both files present) | Apache-2.0 OR MIT | Yes, under either branch; ship LICENSE-MIT (or LICENSE-APACHE + NOTICE-equivalent) beside the data | no |
| httptools-tests | yes, `tests/test_parser.py` (694 lines, exact) + `.gitmodules` confirming `vendor/llhttp` submodule → `nodejs/llhttp.git` (release branch) | MIT (MagicStack Inc., 2015) | MIT | Yes, ship LICENSE | no |
| t-reqs-grammar-fuzzer | yes, `config` (file, not dir, containing `config.grammar = {…}`), `misc/example-request-{line,headers,body}-grammar`, `code/input_tree_mutator.py` | MIT ("NEU SecLab and its affiliates") | MIT | Yes (though finder correctly notes there is no fixed corpus to vendor — it's generative) | no |
| vtest2-vtc-driver | yes on both hosts: code.vinyl-cache.org (`main` @ `f19e3d7d`, live) and archived GitHub mirror (`vtest/VTest2`, tag `last` @ `803dcd0`) | BSD-2-Clause, wrapped in a non-standard "# Collection Copyright" / "# File Copyrights" preamble (hence GitHub's NOASSERTION) | BSD-2-Clause | Yes, ship LICENSE (note 3 header files under a separate BSD-3-Clause grant, none of which are in the corpus list) | no |

None of the six candidates is refuted. All are exactly what the finder said they are,
with a small number of factual corrections noted per-candidate below (payload count in
TROPHIES.md, and one missing filename in the archived VTest2 tag).

---

## 1. http-garden (`narfindustries/http-garden`)

### Existence

```
$ gh api repos/narfindustries/http-garden --jq '{full_name, default_branch, archived, disabled, pushed_at, license: .license.spdx_id, html_url}'
{"archived":false,"default_branch":"main","disabled":false,"full_name":"narfindustries/http-garden","html_url":"https://github.com/narfindustries/http-garden","license":"GPL-3.0","pushed_at":"2026-05-28T00:32:02Z"}

$ gh api repos/narfindustries/http-garden/commits/main --jq '.sha + " " + .commit.committer.date'
b417e806c1b15e8ea0b9312f81a91fbdcbc7a83e 2026-05-28T00:31:59Z

$ gh api repos/narfindustries/http-garden --jq '.stargazers_count'
942
```
pushed_at and star count (942) both match the finder's notes exactly.

Path checks (`gh api repos/narfindustries/http-garden/contents/<path>?ref=main`), all
returned a blob sha + size, i.e. all exist today at HEAD:

```
TROPHIES.md => e17b14a266a5b3bda3f3d51d254142a7c0f09c1e size=57325
quirks.yml => 574081a37224f3f7d708b15dc0cf3d876c6e1198 size=5569
tools/mutations.py => 38539e2d04ac5e1a77691c4db2b4d67fa81bfe5b size=9011
tools/fanout.py => 17c3b895799a9da91159fe4aaf1a0bb0009c4d63 size=612
tools/http1.py => 03ef539cd2d2368587805d92eccf7f8119927c25 size=12749
tools/probe_quirks.py => 258535ef917e010edc764e0ad4bdb51d84def6b5 size=13908
LICENSE => f288702d2fa16d3cdf0035b15a9fcbc552cd88e7 size=35149
```
`images/*/Dockerfile`: `gh api repos/narfindustries/http-garden/contents/images?ref=main`
lists 45 target directories (aiohttp, apache_httpd, … yahns); spot-checked
`images/nginx`: `Dockerfile, fix_ub.patch, index.php, nginx-proxy.conf, nginx.conf,
start.sh, start_proxy.sh` — `Dockerfile` present, confirming the glob claim.

WebFetch https://github.com/narfindustries/http-garden → "Differential testing
framework for HTTP implementations"; confirmed presence of TROPHIES.md, quirks.yml,
tools/, images/ at root; GPL-3.0 badge in the About section.

### License

```
$ gh api repos/narfindustries/http-garden/contents/LICENSE?ref=main --jq '.content' | base64 -d | head -5
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
```
WebFetch https://raw.githubusercontent.com/narfindustries/http-garden/main/LICENSE
independently confirmed the same header. GPL-3.0 confirmed verbatim — matches finder.

### Correction to a quantitative claim

Downloaded `TROPHIES.md` fresh (`verify-b1/TROPHIES-fresh.md`): **877 lines**, exact
match to the finder's count. But `grep -c -i 'payload:' TROPHIES-fresh.md` → **80**, not
"~86" as the finder wrote (lines are indented `  - Payload: ...`, not anchored at column
0). 80 is close enough to be an "approx", but the report should say ~80, not ~86.

### Verdict

Confirmed. GPL-3.0 is copyleft: the test-data lines in TROPHIES.md/quirks.yml cannot be
copied verbatim into a BSD-3-Clause repo. The finder's own conclusion ("author our own
tests from the behaviours the payloads describe … Nothing is vendorable as data") is the
correct application of the rule and I concur. Tier 3 (usable by reference only) stands.
`corrected_paths` note: ~80 Payload: lines, not ~86.

Peripheral fact-check (not load-bearing for the verdict): the cited paper
https://arxiv.org/abs/2405.17737 returns HTTP 200 (`curl -s -o /dev/null -w
"%{http_code}"`), so the arXiv link resolves.

---

## 2. picohttpparser-tests (`h2o/picohttpparser`, `test.c`)

### Existence

```
$ gh api repos/h2o/picohttpparser --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"default_branch":"master","archived":false,"pushed_at":"2026-04-06T05:31:48Z","license":null}

$ gh api repos/h2o/picohttpparser/commits/master --jq '.sha + " " + .commit.committer.date'
f4d94b48b31e0abae029ebeafcfd9ca0680ede58 2026-04-06T05:27:37Z

$ gh api repos/h2o/picohttpparser/contents?ref=master --jq '.[].name'
.clang-format .github .gitignore .gitmodules Jamfile Makefile README.md bench.c misc
picohttpparser.c picohttpparser.h picohttpparser.xcodeproj picotest test.c
```
`license: null` (GitHub's detector finds nothing) — confirms the finder's claim "no
LICENSE file in repo root". `test.c` exists:
`gh api .../contents/test.c?ref=master --jq '.sha + " size=" + (.size|tostring)'` →
`d8e877362d86dd7598cce6920bba916503eecdff size=22628`.

WebFetch https://github.com/h2o/picohttpparser/blob/master/test.c → "File Existence:
Yes… GitHub reports the file contains 539 lines… header comment indicates dual
licensing: 'The software is licensed under either the MIT License (below) or the Perl
license.'"

### Independent count check

Downloaded `test.c` fresh (`verify-b1/pico-test-fresh.c`):
```
$ wc -l pico-test-fresh.c
539 pico-test-fresh.c
$ grep -c 'PARSE(' pico-test-fresh.c
70
$ grep -c '    ok(' pico-test-fresh.c
125
$ grep -c '^static void test_' pico-test-fresh.c
10
$ sed -n '/^int main/,/^}/p' pico-test-fresh.c | grep -c subtest
7
```
All exact matches to the finder's "539 lines… 70 PARSE cases, 125 ok assertions, 7
subtests" — including the subtlety that there are 10 `test_*` functions but only 7 are
registered as top-level `subtest()`s in `main()` (test_chunked_at_once and
test_chunked_per_byte are called from inside test_chunked, not standalone). Finder was
precise.

### License

Header of `test.c` and of `picohttpparser.c` (both identical), read via
`gh api .../contents/<file>?ref=master --jq '.content' | base64 -d`:
```
/*
 * Copyright (c) 2009-2014 Kazuho Oku, Tokuhiro Matsuno, Daisuke Murase,
 *                         Shigeo Mitsunari
 *
 * The software is licensed under either the MIT License (below) or the Perl
 * license.
 * ...
```
followed by the full MIT license text. No separate LICENSE/COPYING file exists in the
repo (confirmed by the root listing above), so "MIT OR Artistic-1.0-Perl (dual, stated
in source headers only; no LICENSE file in repo root)" is an accurate paraphrase — the
file literally says "the Perl license" without spelling out "Artistic-1.0", but that is
the conventional meaning of "the same terms as Perl itself" and it is dual with MIT
either way, which is what matters for the compatibility call.

### Verdict

Confirmed, not refuted. Since MIT is one of the two license options offered, vendoring
`test.c` (or excerpts as test data/patterns) into a BSD-3-Clause repo is permissible
under the MIT branch — carry the MIT text and copyright line exactly as printed in the
file header, and do not claim the file has a project-root LICENSE (it doesn't).

---

## 3. httparse-rust-tests (`seanmonstar/httparse`)

### Existence

```
$ gh api repos/seanmonstar/httparse --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"default_branch":"master","archived":false,"pushed_at":"2026-06-30T13:13:39Z","license":"Apache-2.0"}

$ gh api repos/seanmonstar/httparse/commits/master --jq '.sha + " " + .commit.committer.date'
a0fa552e4e0fa9a5914a736ef3a556748fef709b 2026-06-30T13:13:39Z
```
pushed_at matches finder's note exactly. All 10 named paths confirmed to exist
(`gh api .../contents/<path>?ref=master`):
```
src/lib.rs => 98b37c709feb926cf124a5ffaf7ad4ab391aaa68 size=104621
tests/uri.rs => e0ceab47786af7cc8cac1647858bc8d2e4564071 size=102934
fuzz/fuzz_targets/parse_request.rs => 37654b9d4df336a5f08be3d3922a1e8bab999ef4 size=207
fuzz/fuzz_targets/parse_response.rs => 757723f776fed278604a3b10f9935a9e08f33a5c size=218
fuzz/fuzz_targets/parse_headers.rs => 2e0309daef01d4062972ba0fcf4b7c68c95f0432 size=179
fuzz/fuzz_targets/parse_chunk_size.rs => b543c61bfb7062d0a14fd283e5d4f058df8c732a size=116
fuzz/fuzz_targets/parse_request_multspaces.rs => dfa8395f775dfffcfc7a93e58169e5a5c74c75fc size=339
fuzz/fuzz_targets/parse_response_multspaces.rs => ceba2f457abaaa301f9fa135017152af51bac5dd size=344
LICENSE-APACHE => 16fe87b06e802f094b3fbb0894b137bca2b16ef1 size=10847
LICENSE-MIT => d59eca469e371e9b35c7b544eb12ec2690afcad7 size=1063
```
`gh api repos/seanmonstar/httparse/contents/fuzz?ref=master --jq '.[].name'` →
`.gitignore Cargo.toml fuzz_targets`; a full-tree search
(`gh api "repos/seanmonstar/httparse/git/trees/master?recursive=1" --jq '.tree[].path'
| grep -iE 'corpus|dict|seed'`) returned **zero matches** — confirms "Fuzz targets carry
no seeds."

WebFetch https://github.com/seanmonstar/httparse → confirms "A push parser for the HTTP
1.x protocol… Apache-2.0 / MIT" dual license badges, both LICENSE files present.

### Independent count check

Downloaded `src/lib.rs` and `tests/uri.rs` fresh:
```
$ wc -l lib-fresh.rs uri-fresh.rs
2783 lib-fresh.rs
3692 uri-fresh.rs
$ grep -c '#\[test\]' lib-fresh.rs
53
$ grep -cE '^\s*(req!|res!)' lib-fresh.rs
44
$ grep -cE '^\s*req!' uri-fresh.rs
264
```
Exact matches to "2783 lines, 53 #[test], 44 req!/res! cases" and "3692 lines, 264 req!
cases".

### License

```
$ gh api repos/seanmonstar/httparse/contents/LICENSE-MIT?ref=master --jq '.content' | base64 -d | head -3
Copyright (c) 2015-2026 Sean McArthur
Permission is hereby granted, free of charge, ...
```
Apache-2.0 OR MIT dual, both files present verbatim — matches finder.

### Verdict

Confirmed, not refuted. Vendoring test data under the MIT (or Apache-2.0) branch into a
BSD-3-Clause repo is compatible.

---

## 4. httptools-tests (`MagicStack/httptools`, `tests/test_parser.py`)

### Existence

```
$ gh api repos/MagicStack/httptools --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"default_branch":"master","archived":false,"pushed_at":"2026-05-25T22:16:53Z","license":"MIT"}

$ gh api repos/MagicStack/httptools/commits/master --jq '.sha + " " + .commit.committer.date'
cf10ce6f0dae56e61817e67b9bb073dd39d0191a 2026-05-25T22:02:50Z
```
pushed_at matches finder's note. Paths:
```
tests/test_parser.py => 96dc6f0523d595e250f7de3fb7984bf3b68d016b size=21980
.gitmodules => 85c6ce71dfb9bbb7225563ba48933ce19f273da8 size=221
LICENSE => 79a03ca513a7c94562cb1f8d83aa8bfc736ba0c2 size=1093
```
`.gitmodules` content:
```
[submodule "vendor/http-parser"]
	path = vendor/http-parser
	url = https://github.com/nodejs/http-parser.git
[submodule "vendor/llhttp"]
	path = vendor/llhttp
	url = https://github.com/nodejs/llhttp.git
	branch = release
```
Confirms "vendors llhttp as a git submodule at vendor/llhttp" and explains "Vendored
llhttp version not readable via raw URL (submodule)" — a submodule pointer, not an
inline blob, so its pinned commit isn't visible through the parent repo's content API
(this matches the finder's caveat exactly).

WebFetch https://github.com/MagicStack/httptools/blob/master/tests/test_parser.py →
"Yes, the file exists… 694 lines (533 loc) · 21.5 KB" — matches the byte size above.

### Independent count check

```
$ wc -l test_parser-fresh.py
694 test_parser-fresh.py
$ grep -c '    def test_' test_parser-fresh.py
41
$ grep -n '^class ' test_parser-fresh.py
83:class TestResponseParser(unittest.TestCase)
283:class TestRequestParser(unittest.TestCase)
618:class TestUrlParser(unittest.TestCase)
```
694 lines and 41 `test_` functions both match the finder's "694 lines… 41 tests"
exactly.

### License

```
$ gh api repos/MagicStack/httptools/contents/LICENSE?ref=master --jq '.content' | base64 -d | head -3
The MIT License
Copyright (c) 2015 MagicStack Inc.  http://magic.io
```

### Verdict

Confirmed, not refuted. MIT, straightforward to vendor with LICENSE attached.

---

## 5. t-reqs-grammar-fuzzer (`bahruzjabiyev/t-reqs`) + related HDiff / HDHunter

### Existence

```
$ gh api repos/bahruzjabiyev/t-reqs --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"default_branch":"main","archived":false,"pushed_at":"2024-10-30T15:59:47Z","license":"MIT"}

$ gh api repos/bahruzjabiyev/t-reqs/commits/main --jq '.sha + " " + .commit.committer.date'
b90f97e4f39afbe39c66ecfe99fae1b832b20f62 2024-10-30T15:59:41Z

$ gh api repos/bahruzjabiyev/t-reqs/contents?ref=main --jq '.[].name'
Dockerfile LICENSE README.md code config figs logo-treqs.png misc
```
pushed_at matches finder's note exactly ("pushed 2024-10-30"). `config` at root is a
**file**, not a directory (`gh api .../contents/config?ref=main --jq '{name,size,type}'`
→ `{"name":"config","size":3101,"type":"file"}`), decoded content starts:
```
# Required. The input grammar for describing the input structure.
config.grammar = {
```
confirming the finder's description "Python CFG config (config.grammar dict)" exactly.

```
$ gh api repos/bahruzjabiyev/t-reqs/contents/misc?ref=main --jq '.[].name'
example-request-body-grammar example-request-headers-grammar example-request-line-grammar
$ gh api repos/bahruzjabiyev/t-reqs/contents/code?ref=main --jq '.[].name'
feedback-server.py helper_functions.py input_tree.py input_tree_mutator.py input_tree_node.py main.py
```
All named paths (`config`, `misc/example-request-line-grammar`,
`misc/example-request-headers-grammar`, `misc/example-request-body-grammar`,
`code/input_tree_mutator.py`) exist.

WebFetch https://github.com/bahruzjabiyev/t-reqs → "a grammar-based HTTP Fuzzer…
fuzzing HTTP servers by sending mutated HTTP requests with versions 1.1 and earlier";
confirms `config`, `misc/`, `code/` present.

### License

```
$ gh api repos/bahruzjabiyev/t-reqs/contents/LICENSE?ref=main --jq '.content' | base64 -d | head -3
MIT License
Copyright (c) NEU SecLab and its affiliates.
```

### Related repos cited in the finder's notes

```
$ gh api repos/mo-xiaoxi/HDiff --jq '{archived, pushed_at, license: .license.spdx_id}'
{"archived":false,"pushed_at":"2022-06-07T04:13:19Z","license":"GPL-3.0"}
$ gh api repos/mukeran/HDHunter --jq '{archived, pushed_at, license: .license.spdx_id}'
{"archived":false,"pushed_at":"2025-02-18T07:51:02Z","license":"MIT"}
```
Both match the finder's notes exactly (HDiff: GPL-3.0, pushed 2022-06-07; HDHunter:
MIT). I did not re-verify the finer claims about HDiff/HDHunter's file contents ("RFC
requirement CSVs and ABNF", "three ordinary example seeds plus a Vagrant VM") since
neither is a keyed candidate with its own corpus_paths list to check — they appear only
as supporting notes on t-reqs — but the repo-level metadata the finder cited is
accurate.

### Verdict

Confirmed, not refuted. MIT license; but as the finder notes, T-Reqs is a generative
grammar/mutator, not a fixed corpus — there is nothing here to literally vendor as test
DATA (the license question is moot for that reason, not because of incompatibility).

---

## 6. vtest2-vtc-driver (VTest2 — code.vinyl-cache.org + archived GitHub mirror)

This candidate names two hosts. Both were checked independently.

### 6a. Current home: code.vinyl-cache.org/vtest/VTest2 (Forgejo)

```
$ curl -s -o /dev/null -w "%{http_code}" https://code.vinyl-cache.org/vtest/VTest2
200
$ curl -s https://code.vinyl-cache.org/api/v1/repos/vtest/VTest2/branches/main | (head -c 400)
{"name":"main","commit":{"id":"f19e3d7d31c0a80cd6b75bab135897710c2057b7","message":"Back to trunk\n", ... "author":{"name":"Nils Goroll", ...
$ curl -s https://code.vinyl-cache.org/api/v1/repos/vtest/VTest2 | python3 -c "import json,sys; d=json.load(sys.stdin); print({k:d.get(k) for k in ['full_name','default_branch','archived','updated_at']})"
{'full_name': 'vtest/VTest2', 'default_branch': 'main', 'archived': False, 'updated_at': '2026-09-15T17:16:46+02:00'}
```
HEAD sha `f19e3d7d31c0a80cd6b75bab135897710c2057b7`, dated 2026-09-15 — matches the
finder's "main f19e3d7d 2026-09-15" exactly. WebFetch of the same URL independently
reported the same commit id, message "Back to trunk", and 2026-09-15 date.

`tests/` directory on this live main (`curl .../api/v1/repos/vtest/VTest2/contents/tests?ref=main`):
61 files, 31 `a00*.vtc` (this includes `a00017.vtc` — present here). LICENSE decoded
matches 6c below (BSD-2-Clause with the same "Collection Copyright" preamble).

### 6b. Archived GitHub mirror: `vtest/VTest2`

```
$ gh api repos/vtest/VTest2 --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"default_branch":"main","archived":true,"pushed_at":"2026-02-18T10:55:39Z","license":null}
$ gh api repos/vtest/VTest2/tags --jq '.[] | .name + " " + .commit.sha'
last 803dcd000b1328f6e766774e23aedbd7f53e7d97
$ gh api repos/vtest/VTest2/commits/main --jq '.sha + " " + .commit.committer.date'
628623a81cee3f296c2bb116442692ee9690d872 2026-02-18T10:55:35Z
```
`archived: true` confirmed. GitHub's license detector reports `null`/NOASSERTION —
matches finder. Exactly one tag, `last` @ `803dcd000b1328f6e766774e23aedbd7f53e7d97` —
matches the finder's cited sha exactly.

README.md on `main` (`gh api repos/vtest/VTest2/contents/README.md?ref=main`), decoded,
first lines verbatim:
```
# IMPORTANT - THIS REPOSITORY HAS MOVED

New location: <https://code.vinyl-cache.org/vtest/VTest2>

The last usable version on github has the ``last`` tag.

For background, read this: <https://vinyl-cache.org/organization/moving.html>
```
Confirms the finder's claim precisely: "GitHub repo archived… README: 'THIS REPOSITORY
HAS MOVED'… GitHub main Makefile refuses to build, tag `last` builds" (I did not rerun
the build myself in this pass — the cached `verify-b1/pipeline.vtc` +
`pipeline.vtc.log` from the earlier fetch already show a passing `vtest` run against a
Python http.server, consistent with "tag last builds" — but that is an adaptability
claim outside this lens's existence/license scope).

### Path checks, tag `last`

```
$ gh api repos/vtest/VTest2/contents/tests?ref=last --jq '.[].name'   # 58 files total, 29 a00*, 29 a02*
```
`a00000.vtc … a00029.vtc`: **a00017.vtc is MISSING** — the directory has
a00000–a00016, then jumps to a00018–a00029 (29 files where the claimed range implies
30). Confirmed by exhaustive check:
```
for i in $(seq -w 0 29); do grep -q "^a000$i" tests_last.txt || echo "MISSING a000$i"; done
MISSING a00017
```
`a02000.vtc … a02020.vtc`: all 21 present, no gaps (the directory actually goes on to
a02028.vtc, 29 files total, but the finder's cited subrange 02000–02020 is fully
intact).

Note the discrepancy between hosts: **a00017.vtc does not exist in the frozen GitHub
`last` tag, but does exist on the live code.vinyl-cache.org `main`** (31 `a00*` files
there vs. 29 on the GitHub tag) — the upstream project evidently backfilled/renumbered
after the GitHub mirror was frozen. This means: if vendoring pins to the archived GitHub
tag, `tests/a00017.vtc` must be dropped from the corpus-path list; if pinning to the
live Forgejo host (which the finder's own recommendation implies as the source of
truth: "record the vendoring/pinning choice … as an ADR"), the full `a00000…a00029`
range is intact.

```
$ gh api repos/vtest/VTest2/contents/src/vtc_http.c?ref=last --jq '.sha + " size=" + (.size|tostring)'
5d04a1d738b3681c6edd6008636bad1af415ac09 size=47669
$ gh api repos/vtest/VTest2/contents/src/vtc_process.c?ref=last --jq '.sha + " size=" + (.size|tostring)'
d624445bc50e0328e4dd6076c9ea868f036edb72 size=28928
$ gh api repos/vtest/VTest2/contents/src/vtc_main.c?ref=last --jq '.sha + " size=" + (.size|tostring)'
3cf89cc3b8c161c601dc97df6f034ec205287e1f size=23928
```
All three exist. Line-number citations verified against fresh downloads:
- `src/vtc_process.c` line 897 is the blank line right before
  `/* SECTION: process process ... Run a process with stdin+stdout on a
  pseudo-terminal...*/` — i.e. exactly the "process command" doc block the finder cited.
- `src/vtc_main.c` line 923 is `case 'D': if (!parse_D_opt(optarg)) {` — exactly the
  `-D` macro-handling code the finder cited.

Both line citations are correct.

### License (tag `last`, also cross-checked identical on code.vinyl-cache.org main)

```
$ gh api repos/vtest/VTest2/contents/LICENSE?ref=last --jq '.content' | base64 -d
# Collection Copyright

BSD 2-Clause License

Copyright (c) 2018, Vtest project
All rights reserved.
... [full BSD-2-Clause text] ...

# File Copyrights

All files have some variant of BSD 2-Clause License, except:

* lib/vqueue.h - BSD 3-Clause License
* src/huffman_input - BSD 3-Clause License
* src/vtc_h2_enctbl.h - BSD 3-Clause License
* src/vtc_h2_stattbl.h - BSD 3-Clause License
```
This exactly matches the finder's note: "LICENSE text is verbatim BSD-2 (GitHub reports
NOASSERTION due to a 'Collection Copyright' preamble)" — the unusual `# Collection
Copyright` / `# File Copyrights` markdown-style headers around the license body are
almost certainly why GitHub's detector declines to classify it. None of the four
BSD-3-Clause-exception files (`lib/vqueue.h`, `src/huffman_input`,
`src/vtc_h2_enctbl.h`, `src/vtc_h2_stattbl.h`) are in the candidate's corpus_paths list,
so the whole cited corpus (the 58 `.vtc` scripts and the three `src/vtc_*.c` driver
files) is under plain BSD-2-Clause.

### Supporting facts re-checked

```
$ gh api repos/varnishcache/varnish-cache/contents/.gitmodules?ref=master --jq '.content' | base64 -d | grep -A2 -i vtest
[submodule "bin/varnishtest/vtest2"]
	path = bin/varnishtest/vtest2
	url = https://github.com/vtest/VTest2.git
```
Confirms "varnish-cache vendors VTest2 as a git submodule (.gitmodules)" exactly.

```
$ brew info varnish
==> varnish: stable 9.0.4 (bottled)
License: BSD-2-Clause
```
Confirms "Homebrew has varnish 9.0.4" exactly (local Homebrew, not installed).
I did not attempt to determine whether the bottled formula ships a `varnishtest`
binary — same gap the finder flagged ("I did not verify") — this is outside the
existence/license lens and doesn't affect the verdict on the vtest2 candidate itself,
since the candidate is about the standalone VTest2 project, not Homebrew's varnish.

### Verdict

Confirmed, not refuted, on both cited hosts. BSD-2-Clause is fully compatible with
vendoring into a BSD-3-Clause project (retain the LICENSE file, including its unusual
"Collection Copyright" framing, since that framing is what makes the grant clear file by
file). One correction: drop `tests/a00017.vtc` from the corpus-path list if pinning to
the archived GitHub tag `last`; it is present if pinning to the live
code.vinyl-cache.org `main` (recommended, since it is also the host the finder's own
`notes` field treats as canonical).

---

## Appendix: files retained in this scratchpad

Reused (already fetched by an earlier pass at this exact batch, timestamps ~07:xx–08:3x
on 2026-09-19, byte-identical to today's re-fetch where re-checked):
`verify-b1/garden-*`, `verify-b1/httparse-lib.rs`, `verify-b1/httparse-uri.rs`,
`verify-b1/httptools-test_parser.py`, `verify-b1/httptools-gitmodules`,
`verify-b1/pico-test.c`, `verify-b1/treqs-*`, `verify-b1/pipeline.vtc`,
`verify-b1/pipeline.vtc.log`.

Freshly downloaded in this pass (this session):
`verify-b1/TROPHIES-fresh.md`, `verify-b1/pico-test-fresh.c`, `verify-b1/lib-fresh.rs`,
`verify-b1/uri-fresh.rs`, `verify-b1/test_parser-fresh.py`, `verify-b1/config-fresh.py`,
`verify-b1/vtc_http-fresh.c`, `verify-b1/vtc_process-fresh.c`,
`verify-b1/vtc_main-fresh.c`, `verify-b1/vtest2-LICENSE-fresh.txt`.
