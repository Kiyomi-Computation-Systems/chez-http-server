# Skeptic verification — batch11 (app-reference / server-conformance / other-language HTTP corpus candidates)

Role: SKEPTIC. Lens: **existence** (repo + every named corpus path exists today, 2026-09-19)
and **license** (confirm SPDX id from the actual license file, not just a label in the
candidate JSON; note copyleft as usable-by-reference only, never vendored verbatim into
the BSD-3-Clause `chez-http-server` repo).

Method: `gh` CLI (`gh api repos/<owner>/<repo>` and `.../contents/<path>`) against the
live GitHub API for the four GitHub-hosted candidates (go-httpbin, racket/web-server,
ashinn/chibi-scheme, fukamachi/clack + fukamachi/woo) — this returns exact byte sizes,
`html_url`s, base64 file content, and the repo's own `license.spdx_id` field, doubling
as an existence and a license check in one shot. `gh pr view` / `gh issue view` were used
for the chibi-scheme PR/issue. For the two non-GitHub candidates (Savannah cgit for Guile,
code.more-magic.net cgit for intarweb) I used `WebFetch` plus raw `curl` of the cgit
`/plain/` endpoint to get exact byte-for-byte file content (line counts, grep counts,
license text). All commands and verbatim (trimmed) output are below, grouped by candidate.

---

## 1. `go-httpbin-reference-app`

**Claimed:** `https://github.com/mccutchen/go-httpbin`, MIT, tier 2.

```
$ gh api repos/mccutchen/go-httpbin --jq '{full_name, license: .license.spdx_id, default_branch, pushed_at, archived}'
{"archived":false,"default_branch":"main","full_name":"mccutchen/go-httpbin","license":"MIT","pushed_at":"2026-09-18T20:35:08Z"}

$ gh api repos/mccutchen/go-httpbin/contents/LICENSE --jq '.content' | base64 -d | head -5
MIT License
Copyright (c) 2016 Will McCutchen
Permission is hereby granted, free of charge, to any person obtaining a copy
```

Corpus paths — `gh api repos/mccutchen/go-httpbin/contents/httpbin` listing includes
`handlers.go`, `handlers_test.go`, `helpers.go`, `helpers_test.go`, `httpbin.go`,
`httpbin_test.go`, `middleware.go`, `middleware_test.go`, `options.go`, `responses.go`
(all named corpus files present). `gh api repos/mccutchen/go-httpbin/contents/` root
listing includes `LICENSE`, `README.md` (both present).

Approx-cases spot check — pulled the raw file and grepped:
```
$ curl -sL https://raw.githubusercontent.com/mccutchen/go-httpbin/main/httpbin/handlers_test.go -o handlers_test.go
$ grep -c '^func Test' handlers_test.go   -> 55
$ grep -c 't.Run(' handlers_test.go       -> 150
```
Matches the candidate's claim "55 Test functions with 150 t.Run subtests in
handlers_test.go" **exactly**.

**Verdict: NOT refuted.** Repo exists (pushed as recently as 2026-09-18, i.e. actively
maintained today), every named path exists, SPDX license is genuinely MIT (both
GitHub's detector and the raw LICENSE text agree). MIT test/behavioural data used
by-reference (running go-httpbin as a comparison server, or transcribing table-test
expectations) into a BSD-3-Clause project is fully compatible; the candidate's own
adaptability plan vendors no bytes at all (option b: run both servers and diff, or
hand-transcribe scenario tables), so there's no copyleft/attribution complication
either way.

---

## 2. `racket-web-server-request-fixtures`

**Claimed:** `https://github.com/racket/web-server/tree/master/web-server-test/tests/web-server`,
Apache-2.0 OR MIT, tier 1.

```
$ gh api repos/racket/web-server --jq '{full_name, license: .license.spdx_id, default_branch, pushed_at, archived}'
{"archived":false,"default_branch":"master","full_name":"racket/web-server","license":"NOASSERTION","pushed_at":"2026-08-11T02:10:23Z"}
```
GitHub's auto-detector says `NOASSERTION` (it can't parse a dual-license grant), so the
LICENSE file text was read directly:
```
$ gh api repos/racket/web-server/contents/LICENSE --jq '.content' | base64 -d
This component of Racket is distributed under the under the Apache 2.0
and MIT licenses. The user can choose the license under which they
will be using the software. There may be other licenses within the
distribution with which the user must also comply.
```
This **confirms** the candidate's claimed "Apache-2.0 OR MIT" (and independently
confirms the candidate's own note that `gh api` reports NOASSERTION for exactly the
reason stated: a dual-licence LICENSE file GitHub can't classify).

Corpus paths — `gh api repos/racket/web-server/contents/web-server-test/tests/web-server`
listing confirms `private/`, `e2e/`, `serve-tests.rkt`, `util.rkt` all present.
`.../private` listing confirms `request-test.rkt`, `response-test.rkt`,
`connection-manager-test.rkt`, `fixtures/` all present.
`.../private/fixtures` listing: **37 entries**, exactly matching the candidate's "37 raw
HTTP request byte files" claim, including the 23 `multipart-body-*` fixtures the
candidate describes. `.../e2e` listing: `README.md`, `all-e2e-tests.rkt`, `echo`,
`file-upload`, `graceful-shutdown`, `head`, `json`, `max-concurrent`, `read-write`,
`tls` — **8 scenario folders**, exactly matching "8 e2e scenario folders."

Spot check on the flagged large fixture:
```
$ gh api repos/racket/web-server/contents/web-server-test/tests/web-server/private/fixtures/multipart-body-with-long-files
{"name":"multipart-body-with-long-files", ..., "size":3000463, "type":"file", ...}
```
Confirms it is a single ~3,000,463-byte (≈3 MB) file, exactly matching the candidate's
own note "Exclude or regenerate the 3 MB multipart-body-with-long-files fixture."

**Verdict: NOT refuted.** Repo exists (pushed 2026-08-11), every named path exists,
license is genuinely dual Apache-2.0/MIT (confirmed by reading the LICENSE text, not
just trusting GitHub's UI badge). Both options are permissive and compatible with
vendoring the raw fixture bytes (not code) into a BSD-3-Clause project, provided
attribution/PROVENANCE is kept as the candidate proposes.

---

## 3. `chibi-net-tests`

**Claimed:** `https://github.com/ashinn/chibi-scheme/pull/1199`, BSD-3-Clause, tier 1.

```
$ gh api repos/ashinn/chibi-scheme --jq '{full_name, license: .license.spdx_id, default_branch, pushed_at, archived}'
{"archived":false,"default_branch":"master","full_name":"ashinn/chibi-scheme","license":"NOASSERTION","pushed_at":"2026-09-13T12:05:02Z"}
```
GitHub's detector again says NOASSERTION (non-standard header wording: "author" instead
of "copyright holder"), so the actual `COPYING` file was read:
```
$ gh api repos/ashinn/chibi-scheme/contents/COPYING --jq '.content' | base64 -d
Copyright (c) 2009-2021 Alex Shinn
All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright...
2. Redistributions in binary form must reproduce the above copyright...
3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''...
```
Three enumerated conditions (source attribution / binary attribution / non-endorsement)
— this is the classic **BSD-3-Clause** pattern, just phrased with "author" instead of
"copyright holder." Confirms the candidate's claimed license.

PR status:
```
$ gh pr view 1199 --repo ashinn/chibi-scheme --json state,mergedAt,mergeCommit,files,title,url
{"state":"MERGED","mergedAt":"2026-09-13T12:05:03Z",
 "mergeCommit":{"oid":"a2e383f685d23992a6a307fc61544b07e5843cbe"},
 "title":"Handle HTTP request parse errors and close rejected uploads cleanly",
 "files":[{"path":"tests/net-tests.scm","additions":124,"deletions":0,"changeType":"ADDED"},
          {"path":"lib/chibi/net/http-server.scm", ...},
          {"path":"lib/chibi/net/server.scm", ...},
          {"path":"lib/chibi/uri-test.sld", ...}, ...]}
```
Merged 2026-09-13T12:05:03Z — matches the candidate's "Merged 2026-09-13" and the repo's
own `pushed_at` timestamp. `tests/net-tests.scm` added with 124 lines, matching the
candidate's "15 test/test-assert forms in 124 lines."

All four named corpus paths confirmed to exist **today** on the current default branch
(`master`), not just inside the closed PR diff:
```
$ gh api repos/ashinn/chibi-scheme/contents/tests/net-tests.scm --jq '{name,size}'          -> {"name":"net-tests.scm","size":5084}
$ gh api repos/ashinn/chibi-scheme/contents/lib/chibi/uri-test.sld --jq '{name,size}'        -> {"name":"uri-test.sld","size":4615}
$ gh api repos/ashinn/chibi-scheme/contents/lib/chibi/net/http-server.scm --jq '{name,size}' -> {"name":"http-server.scm","size":21580}
$ gh api repos/ashinn/chibi-scheme/contents/lib/chibi/net/server.scm --jq '{name,size}'      -> {"name":"server.scm","size":3768}
```

Cross-check of the flaky-test note:
```
$ gh issue view 1202 --repo ashinn/chibi-scheme --json title,state,body,url
{"state":"OPEN","title":"Net tests fail on macos intel",
 "body":"Tests merged in https://github.com/ashinn/chibi-scheme/pull/1199 seem to fail
         on macos intel https://github.com/ashinn/chibi-scheme/actions/runs/...","
 "url":"https://github.com/ashinn/chibi-scheme/issues/1202"}
```
Confirms the candidate's "issue #1202 reports the suite failing on macOS Intel" claim
verbatim.

**Verdict: NOT refuted.** PR is merged, every named file exists today on the default
branch, license text is functionally BSD-3-Clause as claimed. Directly compatible with
vendoring into a BSD-3-Clause project (same license family).

---

## 4. `clack-server-suite-via-woo`

**Claimed:** `https://github.com/fukamachi/clack/blob/master/src/test/suite.lisp`
(+ woo's `t/woo.lisp`, `t/ipv6.lisp`, `woo-test.asd`), MIT, tier 2.

```
$ gh api repos/fukamachi/clack --jq '{full_name, license: .license.spdx_id, default_branch, pushed_at, archived}'
{"archived":false,"default_branch":"master","full_name":"fukamachi/clack","license":"MIT","pushed_at":"2026-02-10T20:49:31Z"}
$ gh api repos/fukamachi/clack/contents/LICENSE --jq '.content' | base64 -d | head -5
MIT License
Copyright (c) 2011 Eitaro Fukamachi
Permission is hereby granted, free of charge, to any person obtaining a copy

$ gh api repos/fukamachi/woo --jq '{full_name, license: .license.spdx_id, default_branch, pushed_at, archived}'
{"archived":false,"default_branch":"master","full_name":"fukamachi/woo","license":"MIT","pushed_at":"2026-03-21T12:50:57Z"}
$ gh api repos/fukamachi/woo/contents/woo.asd --jq '.content' | base64 -d | grep -i licen
  :license "MIT"
```

Corpus paths:
```
$ gh api repos/fukamachi/clack/contents/src/test --jq '.[].name'  -> suite.lisp
$ gh api repos/fukamachi/clack/contents/src/test/suite.lisp --jq '.size'  -> 22047
$ gh api repos/fukamachi/woo/contents/t --jq '.[].name'  -> generate-certificates.sh, ipv6.lisp, woo.lisp
$ gh api repos/fukamachi/woo/contents/ --jq '.[].name'  -> ... woo-test.asd, woo.asd, ...
```
All named paths (`src/test/suite.lisp`, `t/woo.lisp`, `t/ipv6.lisp`, `woo-test.asd`) exist.

Approx-cases spot check:
```
$ curl -sL https://raw.githubusercontent.com/fukamachi/clack/master/src/test/suite.lisp -o clack-suite.lisp
$ grep -c '(deftest ' clack-suite.lisp        -> 4
$ grep -c 'testing-app' clack-suite.lisp      -> 36
$ grep -cE '\(ok |\(is ' clack-suite.lisp     -> 86
```
Matches the candidate's "4 deftest, 36 testing-app scenarios, 86 ok/is assertions"
**exactly**.

```
$ curl -sL https://raw.githubusercontent.com/fukamachi/woo/master/t/woo.lisp
(deftest woo-server-tests
  (clack.test.suite:run-server-tests :woo))
(deftest woo-ssl-server-tests
  (let (...) (clack.test.suite:run-server-tests :woo)))
```
Confirms "woo's own t/woo.lisp is 2 deftests that delegate here" **exactly**.

**Verdict: NOT refuted.** Both repos exist and are actively maintained (pushed
2026-02-10 / 2026-03-21), every named path exists, both licenses are genuinely MIT
(GitHub detector + raw LICENSE/`.asd` text agree). MIT scenario transcription into a
BSD-3-Clause project is fully compatible; no code is proposed for verbatim vendoring.

---

## 5. `guile-web-tests`

**Claimed:** `https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/test-suite/tests`,
LGPL-3.0-or-later, tier 2.

Directory listing (`WebFetch` of the cgit tree URL) confirms all four named test files
present with plausible sizes: `web-http.test` (22,754 bytes), `web-request.test`
(3,336 bytes), `web-response.test` (5,467 bytes), `web-server.test` (5,183 bytes).

License — checked both the repo's `COPYING.LESSER` and a file header directly:
```
WebFetch https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/COPYING.LESSER
-> "GNU LESSER GENERAL PUBLIC LICENSE / Version 3, 29 June 2007"

WebFetch https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/test-suite/tests/web-http.test
-> "Copyright (C) 2010-2011, 2014-2017 Free Software Foundation, Inc."
   "...you can redistribute it and/or modify it under the terms of the GNU Lesser
    General Public License as published by the Free Software Foundation; either
    version 3 of the License, or (at your option) any later version."

WebFetch https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/module/web/server/http.scm
-> file exists; same LGPLv3-or-later header, confirming the fifth named corpus path
   (module/web/server/http.scm) also exists.
```
This is precisely **LGPL-3.0-or-later**, matching the candidate's claim, and confirms
the candidate's own note that fossies.org (which it says failed with 401/HTML shell)
was correctly abandoned in favor of the working Savannah cgit URLs.

**Verdict: NOT refuted.** Repo/path exists, license confirmed as LGPL-3.0-or-later —
a copyleft license. Per the task's instruction, this makes the material **usable by
reference only** (transcribing ~30 request-line/response-line/chunked-port test *cases*
as fresh, independently-written assertions), never vendored as LGPL source files into
the BSD-3-Clause `chez-http-server` tree. The candidate's own adaptability text already
says exactly this ("LGPL means transcribe cases rather than vendor files"), so its
tier-2 placement and stated approach are already license-correct — I flag this only to
make the constraint explicit for the synthesis agent.

---

## 6. `chicken-intarweb-tests`

**Claimed:** `https://code.more-magic.net/intarweb/tree/tests`, "BSD", tier 2.

```
WebFetch https://code.more-magic.net/intarweb/tree/tests
-> single file tests/run.scm (63,438 bytes reported by cgit; see below for actual size)

WebFetch https://code.more-magic.net/intarweb/tree/intarweb.egg
-> (license "BSD")   [verbatim egg field, exactly as candidate states]
```

Raw file fetch and exact counts:
```
$ curl -sL https://code.more-magic.net/intarweb/plain/tests/run.scm -o run.scm   [HTTP 200]
$ wc -l run.scm                                              -> 1277
$ grep -cE '^\s*\((test|test-error|test-assert)\b' run.scm   -> 441
```
Matches the candidate's "441 test/test-error/test-assert forms in 1277 lines"
**exactly**. Lines 865-950 (sampled) show the HTTP/0.9, HTTP/1.0, HTTP/1.1
request-line/version test groups the candidate cites at "lines 870-943" — confirmed
in range.

License text — the candidate's note claims "the wiki reproduces the 2-clause text,
Copyright 2008-2024." This is **wrong on both counts**. Direct fetch of the CHICKEN
wiki eggref page:
```
$ curl -sL https://wiki.call-cc.org/eggref/4/intarweb | sed -n '/license/,+40p'
<h3 id="license">License</h3>
<pre><tt> Copyright (c) 2008-2017, Peter Bex
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.

 Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.

 Neither the name of the author nor the names of its contributors may
 be used to endorse or promote products derived from this software
 without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"...
```
This is the classic **three**-clause form (source attribution / binary attribution /
non-endorsement), i.e. **BSD-3-Clause**, not 2-clause — and the copyright range is
**2008-2017**, not 2008-2024. (`code.more-magic.net/intarweb/about/` 404'd, so the wiki
page is the only license source actually confirmed; the `intarweb.egg` field itself
just says the generic, SPDX-imprecise `"BSD"`.)

**Verdict: NOT refuted on existence** — repo, `tests/run.scm`, and `intarweb.egg` all
verified live today, and the case count matches to the digit. **License label
corrected**: the finder's top-level `"license": "BSD"` field is technically what the
`.egg` file says, but it's SPDX-imprecise; the actual full text is **BSD-3-Clause**
(not the "2-clause" the finder's notes describe), copyright 2008-2017 (not 2008-2024).
This doesn't change the tier-2 compatibility judgment — BSD-3-Clause test-case
transcription into a BSD-3-Clause project is fully compatible, if anything more
straightforwardly than a 2-clause source would be — but the notes' specific textual
description of the license should be corrected for the synthesis agent.

---

## Summary table

| key | exists today | license confirmed | refuted | correction |
|---|---|---|---|---|
| go-httpbin-reference-app | yes | MIT | no | — |
| racket-web-server-request-fixtures | yes | Apache-2.0 OR MIT | no | — |
| chibi-net-tests | yes (PR merged, files on master) | BSD-3-Clause (GH shows NOASSERTION; text confirms) | no | — |
| clack-server-suite-via-woo | yes (both repos) | MIT (both) | no | — |
| guile-web-tests | yes | LGPL-3.0-or-later (copyleft — reference only) | no | — |
| chicken-intarweb-tests | yes | corrected to BSD-3-Clause (finder said generic "BSD" / wrongly described as 2-clause, 2008-2024) | no | corrected_license = BSD-3-Clause |
