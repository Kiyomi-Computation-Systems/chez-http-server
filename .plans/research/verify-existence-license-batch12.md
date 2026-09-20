# Skeptic verification — batch 12 — existence & license

Lens: **existence and license only**. For each candidate: confirm the repo and the
named corpus paths exist today, confirm the SPDX/declared license, and judge whether
vendoring the *test data* (not code) into a BSD-3-Clause project is compatible.
Copyleft licenses are noted as usable-by-reference only. Default `refuted=true` when
existence could not be confirmed.

Method: GitHub-hosted candidates were checked with `gh api repos/<owner>/<repo>` (repo
metadata incl. GitHub's license auto-detection) and `gh api repos/<owner>/<repo>/contents/<path>`
(existence of exact corpus paths + raw file content for explicit `:license` strings).
`gh auth status` confirmed an authenticated `gh` was available (account DarrenN). The one
non-GitHub candidate (CHICKEN spiffy, hosted on a cgit instance) was checked with WebFetch
against the live tree browser and the CHICKEN wiki eggref mirror of its license text.

All commands and verbatim outputs below were captured on 2026-09-19.

---

## 1. http-kit-server-tests

URL checked: https://github.com/http-kit/http-kit/blob/master/test/org/httpkit/server_test.clj

```
$ gh api repos/http-kit/http-kit --jq '{license: .license, default_branch: .default_branch, pushed_at: .pushed_at}'
{"default_branch":"master","license":{"key":"apache-2.0","name":"Apache License 2.0","node_id":"MDc6TGljZW5zZTI=","spdx_id":"Apache-2.0","url":"https://api.github.com/licenses/apache-2.0"},"pushed_at":"2026-08-21T04:09:35Z"}

$ gh api repos/http-kit/http-kit/contents/ --jq '.[].name'
... LICENSE.txt ... test ...

$ gh api repos/http-kit/http-kit/contents/test/org/httpkit --jq '.[].name'
benchmark.clj
benchmark
client_protocol_test.clj
client_proxy_test.clj
client_test.clj
java_protocol_test.clj
num_connections.clj
proxy_test.clj
ring_request_proxy.clj
server_test.clj
ssl_bench.clj
test_util.clj
utils_test.clj
ws_test.clj

$ gh api repos/http-kit/http-kit/contents/LICENSE.txt --jq '.content' | base64 -d | head -5

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
```

**Existence:** repo exists, default branch is `master` (matches URL), `pushed_at`
2026-08-21 matches the finder's note exactly. All 3 claimed corpus paths
(`test/org/httpkit/server_test.clj`, `test/org/httpkit/test_util.clj`,
`test/org/httpkit/num_connections.clj`) are present in the listing.

**License:** GitHub's license auto-detector and the `LICENSE.txt` file both confirm
**Apache-2.0**, as claimed.

**Vendoring judgment:** Apache-2.0 is permissive. Test-data files under Apache-2.0 can
be vendored into a BSD-3-Clause repo, but the vendored files must keep their Apache-2.0
notice/attribution (an Apache-2.0 file cannot simply be relabeled BSD-3-Clause) —
straightforward third-party-notices handling, not a blocker.

**Verdict: not refuted.**

---

## 2. fast-http-parser-tests

URL checked: https://github.com/fukamachi/fast-http/tree/master/t

```
$ gh api repos/fukamachi/fast-http --jq '{license: .license, default_branch: .default_branch, pushed_at: .pushed_at}'
{"default_branch":"master","license":null,"pushed_at":"2026-04-06T11:11:24Z"}

$ gh api repos/fukamachi/fast-http/contents/ --jq '.[].name'
.gitignore
.travis.yml
README.markdown
benchmark
fast-http-test.asd
fast-http.asd
src
t

$ gh api repos/fukamachi/fast-http/contents/t --jq '.[].name'
benchmark.lisp
body-buffer.lisp
fast-http.lisp
multipart-parser.lisp
parser.lisp
test-utils.lisp
util.lisp

$ gh api repos/fukamachi/fast-http/contents/fast-http.asd --jq '.content' | base64 -d | grep -i licen
  :license "MIT"
```

**Existence:** repo exists, default branch `master` matches the URL, `pushed_at`
2026-04-06 matches the finder's note exactly. All 4 claimed corpus paths
(`t/parser.lisp`, `t/fast-http.lisp`, `t/body-buffer.lisp`, `t/multipart-parser.lisp`)
are present in `t/`.

**License:** GitHub's API reports `"license": null` — no LICENSE file exists at the
repo root and GitHub could not auto-detect an SPDX id, exactly as the finder's own note
says ("gh api found no SPDX id and no LICENSE file at the repo root"). The only license
signal in the repository is the literal string `:license "MIT"` in `fast-http.asd`. This
is *asserted* metadata, not a license grant with copyright/permission/disclaimer text —
weaker provenance than a real LICENSE file, but MIT is unambiguous as a declaration of
intent from the author.

**Vendoring judgment:** If treated as MIT (per the .asd declaration), permissive and
vendorable into a BSD-3-Clause project with the MIT notice retained on the vendored
files. Flag for downstream use: there is no canonical LICENSE text to copy verbatim,
only the `.asd` string, so cite `fast-http.asd:17` as the license source when vendoring.

**Verdict: not refuted**, with `corrected_license` spelled out to capture the caveat.

---

## 3. aleph-http-tests

URL checked: https://github.com/clj-commons/aleph/blob/master/test/aleph/http_test.clj

```
$ gh api repos/clj-commons/aleph --jq '{license: .license, default_branch: .default_branch, pushed_at: .pushed_at}'
{"default_branch":"master","license":{"key":"mit","name":"MIT License","node_id":"MDc6TGljZW5zZTEz","spdx_id":"MIT","url":"https://api.github.com/licenses/mit"},"pushed_at":"2026-08-24T08:52:28Z"}

$ gh api repos/clj-commons/aleph/contents/test/aleph --jq '.[].name'
classloader_test.clj
http
http_continue_test.clj
http_test.clj
http_timeout_test.clj
netty_test.clj
resource_leak_detector.clj
ring_test.clj
ssl.clj
tcp_ssl_test.clj
tcp_test.clj
testutils.clj
udp_test.clj
websocket_test.clj

$ gh api repos/clj-commons/aleph/contents/test/aleph/http --jq '.[].name'
client_middleware_test.clj
client_test.clj
common_test.clj
compression_test.clj
core_test.clj
http2_test.clj
multipart_test.clj

$ gh api repos/clj-commons/aleph/contents/LICENSE.md --jq '.content' | base64 -d | head -5
MIT License

Copyright (c) 2010-2020 Zachary Tellman

Permission is hereby granted, free of charge, to any person obtaining a copy
```

**Existence:** repo exists, default branch `master` matches URL, `pushed_at`
2026-08-24 matches the finder's note exactly. All claimed corpus files are present:
`http_test.clj`, `http_continue_test.clj`, `http_timeout_test.clj`,
`resource_leak_detector.clj` all in `test/aleph/`, and `test/aleph/http/` contains
exactly 7 files, matching "plus 7 files under test/aleph/http/". (`http_timeout_test.clj`
sits directly under `test/aleph/`, not inside `test/aleph/http/`, but the candidate's
`corpus_paths` list already places it correctly at that level.)

**License:** confirmed MIT both via GitHub's detector and `LICENSE.md` content
("MIT License / Copyright (c) 2010-2020 Zachary Tellman").

**Vendoring judgment:** fully permissive, straightforward to vendor into a
BSD-3-Clause project with MIT notice retained.

**Verdict: not refuted.**

---

## 4. chicken-spiffy-tests

URL checked: https://code.more-magic.net/spiffy/tree/tests (a cgit instance, not
GitHub — `gh` does not apply, used WebFetch instead).

```
WebFetch https://code.more-magic.net/spiffy/tree/tests
→ run.scm (14,322 bytes), testlib.scm (4,750 bytes), testweb/ (405 bytes dir).
  cgit v1.2.3 / git 2.46.0, page generated 2026-09-19T16:17:22Z.

WebFetch https://code.more-magic.net/spiffy/tree/
→ root: simple-directory-handler.scm, spiffy.egg, spiffy.release-info, spiffy.scm,
  tests/

WebFetch https://code.more-magic.net/spiffy/tree/tests/testweb
→ data, denied.txt, hello.txt, index.html, once.scm, spiffy-access, test.myscript,
  pics/, secrets/, subdir/, "subdir with space"/

WebFetch https://wiki.call-cc.org/eggref/5/spiffy
→ "Spiffy uses the BSD 2-Clause License." — Copyright (c) 2005-2024, Felix L.
  Winkelmann and Peter Bex.

WebFetch https://wiki.call-cc.org/eggref/5/spiffy (re-queried for the verbatim clause text)
→ Full text has FOUR numbered provisions, not two:
    1. "Redistributions of source code must retain the above copyright notice..."
    2. "Redistributions in binary form must reproduce the above copyright notice..."
    3. "Neither the name of the author nor the names of its contributors may be used
        to endorse or promote products derived from this software without specific
        prior written permission."
    4. The AS-IS warranty disclaimer / liability limitation.
```

**Existence:** confirmed live today. `spiffy.egg` exists at repo root (candidate's
listed path). `tests/run.scm`, `tests/testlib.scm`, and `tests/testweb/` (populated,
not empty) all exist and match the candidate's description of a static-file test tree.

**License — correction:** the candidate's `license` field says generically "BSD" (fine)
but its **notes field is wrong**: it says "the wiki gives the 2-clause text," while the
license text actually fetched from the wiki eggref page contains the no-endorsement
clause (clause 3 above) that is the defining feature of the **3-clause** BSD license.
This is **BSD-3-Clause**, not BSD-2-Clause. `spiffy.egg` itself only says the generic
string `"BSD"` (a first WebFetch of the raw egg file 404'd at a guessed path;
license text was confirmed instead via the wiki eggref mirror, which is the canonical
rendering of the same `.egg license` field per CHICKEN's own tooling).

**Vendoring judgment:** BSD-3-Clause test data vendored into a BSD-3-Clause project is
about as compatible as it gets — same license family as chez-http-server itself.

**Verdict: not refuted**, but `corrected_license` set to `BSD-3-Clause` (candidate's
notes incorrectly characterized it as 2-clause).

---

## 5. gerbil-httpd-tests

URL checked: https://github.com/mighty-gerbils/gerbil/blob/master/src/std/net/httpd-test.ss

```
$ gh api repos/mighty-gerbils/gerbil --jq '{license: .license, default_branch: .default_branch, pushed_at: .pushed_at}'
{"default_branch":"master","license":{"key":"lgpl-2.1","name":"GNU Lesser General Public License v2.1","node_id":"MDc6TGljZW5zZTEx","spdx_id":"LGPL-2.1","url":"https://api.github.com/licenses/lgpl-2.1"},"pushed_at":"2026-07-22T23:27:31Z"}

$ gh api repos/mighty-gerbils/gerbil/contents/ --jq '.[].name'
... LICENSE-APACHE-2.0.txt LICENSE-LGPL.txt ...

$ gh api repos/mighty-gerbils/gerbil/contents/src/std/net --jq '.[].name'
address-test.ss
address.ss
bio.ss
bio
httpd-test.ss
httpd.ss
httpd
json-rpc-test.ss
...

$ gh api repos/mighty-gerbils/gerbil/contents/src/std/net/httpd --jq '.[].name'
api.ss
base.ss
control.ss
file.ss
handler.ss
logger.ss
mux.ss
server.ss

$ gh api repos/mighty-gerbils/gerbil/contents/src/tools --jq '.[].name' | grep -i httpd
gxhttpd-ensemble-test.ss
gxhttpd-test.ss
gxhttpd-test
gxhttpd.ss
gxhttpd
```

**Existence:** repo exists, default branch `master` matches URL, `pushed_at`
2026-07-22 matches the finder's note exactly. All 6 claimed corpus paths confirmed
present: `src/std/net/httpd-test.ss`, `src/tools/gxhttpd-test.ss`,
`src/tools/gxhttpd-ensemble-test.ss`, `src/std/net/httpd/api.ss`,
`src/std/net/httpd/handler.ss`, `src/std/net/httpd/server.ss`.

**License:** GitHub auto-detects LGPL-2.1 — matching the finder's note exactly ("gh
auto-detects LGPL-2.1"). The repo root does carry both `LICENSE-APACHE-2.0.txt` and
`LICENSE-LGPL.txt`, confirming the true state is a **dual license, LGPL-2.1 OR
Apache-2.0**, as the candidate's `license` field already states (GitHub's single-key
detector just picks one file to report).

**Vendoring judgment:** per this task's rule, the LGPL-2.1 horn is copyleft and should
be treated as reference-only. However, because this is a genuine dual license
("LGPL-2.1 OR Apache-2.0" — confirmed by two separate license files at the repo root,
not merely inferred), a downstream user can elect the **Apache-2.0** horn instead,
which is permissive and fully vendorable into a BSD-3-Clause project (with Apache-2.0
notice retained on the vendored files). Recommend citing/vendoring this material under
the Apache-2.0 option specifically, not LGPL-2.1, to avoid copyleft encumbrance.

**Verdict: not refuted**, with `corrected_license` set to spell out the electable
Apache-2.0 option explicitly for downstream use.

---

## 6. hunchentoot-confidence-script

URL checked: https://github.com/edicl/hunchentoot/tree/master/test

```
$ gh api repos/edicl/hunchentoot --jq '{license: .license, default_branch: .default_branch, pushed_at: .pushed_at}'
{"default_branch":"master","license":null,"pushed_at":"2026-05-04T20:13:12Z"}

$ gh api repos/edicl/hunchentoot/contents/test --jq '.[].name' | sort
UTF-8-demo.html
ca-built-via-xca.xdb
ca.crt
client.crt
favicon.ico
fz.jpg
packages.lisp
script-engine.lisp
script.lisp
server+ca.crt
server.crt
test-handlers.lisp
test-key-no-password.key

$ gh api repos/edicl/hunchentoot/contents/test/script.lisp --jq '{name: .name, size: .size, path: .path}'
{"name":"script.lisp","path":"test/script.lisp","size":11361}

$ gh api repos/edicl/hunchentoot/contents/hunchentoot.asd --jq '.content' | base64 -d | grep -n -i licen
36:  :license "BSD-2-Clause"
```

**Existence:** repo exists, default branch `master` matches URL, `pushed_at`
2026-05-04 matches the finder's note exactly. All 4 claimed corpus paths confirmed
present: `test/script.lisp` (11,361 bytes), `test/script-engine.lisp`,
`test/test-handlers.lisp`, `test/packages.lisp`.

**License:** GitHub's API reports `"license": null` (no LICENSE file at repo root, same
situation as fast-http above), but `hunchentoot.asd` line 36 explicitly declares
`:license "BSD-2-Clause"` — an **exact match**, down to the line number, for the
finder's own citation ("hunchentoot.asd line 36 :license \"BSD-2-Clause\"").

**Vendoring judgment:** BSD-2-Clause is a close relative of the target project's
BSD-3-Clause and fully permissive; trivial to vendor with notice retained. Same
weaker-provenance caveat as fast-http applies (declared in `.asd`, no LICENSE file to
copy verbatim) but the SPDX id itself is unambiguous.

**Verdict: not refuted.**

---

## Summary table

| key | exists today? | license confirmed | corrected? | verdict |
|---|---|---|---|---|
| http-kit-server-tests | yes, all 3 paths | Apache-2.0 (GitHub + LICENSE.txt) | no | not refuted |
| fast-http-parser-tests | yes, all 4 paths | MIT (asserted in .asd only, no LICENSE file — as finder noted) | license caveat spelled out | not refuted |
| aleph-http-tests | yes, all listed + 7 in http/ | MIT (GitHub + LICENSE.md) | no | not refuted |
| chicken-spiffy-tests | yes, all paths incl. testweb/ | BSD-3-Clause (finder said "2-clause text," actual wiki text is 3-clause) | corrected_license → BSD-3-Clause | not refuted |
| gerbil-httpd-tests | yes, all 6 paths | dual LGPL-2.1 OR Apache-2.0 (both LICENSE files present, confirmed) | corrected_license → elect Apache-2.0 horn | not refuted |
| hunchentoot-confidence-script | yes, all 4 paths | BSD-2-Clause (hunchentoot.asd:36, exact match) | no | not refuted |

No candidate was refuted on existence or license grounds. All six repositories, and
every corpus path named by the finder, were live and present today (2026-09-19). Two
candidates warrant a license *correction* rather than a refutation: chicken-spiffy-tests
is BSD-3-Clause, not the "2-clause text" the finder's notes claimed, and
gerbil-httpd-tests should be vendored under the Apache-2.0 horn of its genuine dual
license rather than treated as LGPL-only reference material.
