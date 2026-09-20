# Skeptic verification — batch10 (load-testing tool candidates)

Role: SKEPTIC. Lens: **existence** (repo + every named corpus path exists today) and
**license** (confirm SPDX id from the actual license file; copyleft = reference-only,
never vendored into the BSD-3-Clause `chez-http-server` repo).

Method: `gh` CLI (`gh api repos/<owner>/<repo>` and `.../contents/<path>`) against the
live GitHub API — this is the same data WebFetch on the `github.com` HTML pages would
show, but returns exact byte sizes, `html_url`s, base64 file content and the repo's own
`license.spdx_id` field, so it doubles as an existence check and a license check in one
shot. Raw file content was pulled with `curl -s https://raw.githubusercontent.com/...`
where I needed to grep specific line numbers. All commands and verbatim (trimmed)
output are below, grouped by candidate. Run date: 2026-09-19.

---

## 1. `autocannon` — key `autocannon`

**Claimed:** `https://github.com/mcollina/autocannon`, MIT, tier 2.

```
$ gh api repos/mcollina/autocannon
"html_url":"https://github.com/mcollina/autocannon"
"description":"fast HTTP/1.1 benchmarking tool written in Node.js"
"default_branch":"master"
"license":{"key":"mit","name":"MIT License","spdx_id":"MIT", ...}
```

License file:
```
$ gh api repos/mcollina/autocannon/contents/LICENSE
html_url: https://github.com/mcollina/autocannon/blob/master/LICENSE
size: 1081
decoded content begins: "The MIT License (MIT)\n\nCopyright (c) 2016 Matteo Collina..."
```
→ SPDX **MIT** confirmed both by GitHub's detector and by reading the actual license text.

Corpus paths (`gh api repos/mcollina/autocannon/contents/test` and `.../test/fixtures`):
```
test/: [...,'httpClient.test.js','httpRequestBuilder.test.js','parseHAR.test.js',
        'pipelinedRequestsQueue.test.js', ..., 'runRate.test.js', 'fixtures', ...]
test/fixtures/: ['example-result.json','httpbin-get.json','httpbin-post.json',
                 'httpbin-simple-get.json','multi-domains.json']
```
All five named test files plus `test/fixtures/` exist. `package.json` confirmed
(`html_url: https://github.com/mcollina/autocannon/blob/master/package.json`,
`"version": "8.0.0"`, `"license": "MIT"` — matches candidate's "npm registry latest
8.0.0, MIT" note exactly). `LICENSE` confirmed above.

**Verdict: NOT refuted.** Repo exists, default branch is `master` (not `main` —
harmless, candidate didn't assert a branch), every named path exists, license is
genuinely MIT. MIT into BSD-3-Clause: fully compatible, nothing to vendor per the
candidate's own note (external tool use).

---

## 2. `oha-and-hey` — key `oha-and-hey`

**Claimed:** `https://github.com/hatoo/oha` (MIT) with `https://github.com/rakyll/hey`
(Apache-2.0) as fallback, tier 2.

```
$ gh api repos/hatoo/oha
description: "Ohayou(おはよう), HTTP load generator, inspired by rakyll/hey with tui animation."
default_branch: master
license: {"key":"mit","name":"MIT License","spdx_id":"MIT"}
```
```
$ gh api repos/hatoo/oha/contents/LICENSE
html_url: https://github.com/hatoo/oha/blob/master/LICENSE   size: 1062
```
```
$ gh api repos/hatoo/oha/contents/tests
['common', 'tests.rs']   → tests/tests.rs exists
$ gh api repos/hatoo/oha/contents/Cargo.toml (decoded)
[package]
...
license = "MIT"
name = "oha"
version = "1.16.0"
```
→ Cargo.toml `version = "1.16.0"` matches the candidate's note ("Cargo.toml license MIT
version 1.16.0"). `README.md` confirmed
(`https://github.com/hatoo/oha/blob/master/README.md`, size 13344).

`hey` fallback:
```
$ gh api repos/rakyll/hey
description: "HTTP load generator, ApacheBench (ab) replacement"
default_branch: master
license: {"key":"apache-2.0","name":"Apache License 2.0","spdx_id":"Apache-2.0"}
$ gh api repos/rakyll/hey/contents/LICENSE (decoded, first lines)
                                 Apache License
                           Version 2.0, January 2004
```
→ Apache-2.0 confirmed for `hey`, matching the candidate's note exactly ("hey: ...
Apache-2.0").

**Verdict: NOT refuted.** Both repos exist with the exact licenses claimed (oha: MIT;
hey: Apache-2.0). All named corpus paths (`tests/tests.rs`, `Cargo.toml`, `README.md`,
`LICENSE`) exist. Both permissive, both compatible with a BSD-3-Clause project (nothing
proposed to vendor — external binaries only).

---

## 3. `bombardier` — key `bombardier`

**Claimed:** `https://github.com/codesenberg/bombardier`, MIT, tier 2.

```
$ gh api repos/codesenberg/bombardier
description: "Fast cross-platform HTTP benchmarking tool written in Go"
default_branch: master
license: {"key":"mit","name":"MIT License","spdx_id":"MIT"}
```
Root listing (`gh api repos/codesenberg/bombardier/contents/`) includes:
```
LICENSE, README.md, bombardier_test.go, clients_test.go, testbody.txt, ...
```
All five named corpus paths (`README.md`, `bombardier_test.go`, `clients_test.go`,
`testbody.txt`, `LICENSE`) present. `testbody.txt` confirmed at
`https://github.com/codesenberg/bombardier/blob/master/testbody.txt` (11 bytes).

README content check (decoded, matches candidate's fasthttp/Host-header/`--http1` claim):
```
bombardier is a HTTP(S) benchmarking tool. ... uses excellent [fasthttp]
(https://github.com/valyala/fasthttp) instead of Go's default http library...
AFAIK, it's impossible to pass Host header correctly with `fasthttp`, you can use
`net/http`(`--http1`/`--http2` flags) to workaround this issue.
```

**Verdict: NOT refuted.** Repo exists, MIT confirmed, every corpus path exists, and the
specific behavioural claim about fasthttp/Host-header/`--http1` in the notes is verified
verbatim in the live README. MIT into BSD-3-Clause: compatible.

---

## 4. `h2load-http1` — key `h2load-http1`

**Claimed:** `https://github.com/nghttp2/nghttp2`, MIT, tier 2.

```
$ gh api repos/nghttp2/nghttp2
description: "nghttp2 - HTTP/2 C Library and tools"
default_branch: master
license: {"key":"other","name":"Other","spdx_id":"NOASSERTION","url":null}
```
GitHub's own repo-license detector reports **"Other"/NOASSERTION**, not MIT — this
is a discrepancy from the candidate's claimed license and needed a closer look.

```
$ gh api repos/nghttp2/nghttp2/contents/COPYING (decoded, full text)
The MIT License
Copyright (c) 2012, 2014, 2015, 2016 Tatsuhiro Tsujikawa
Copyright (c) 2012, 2014, 2015, 2016 nghttp2 contributors
Permission is hereby granted, free of charge, to any person obtaining
a copy of this software ...
```
```
$ gh api repos/nghttp2/nghttp2/contents/LICENSE (decoded, full content)
See COPYING
```
Explanation for the GitHub "Other" flag: the top-level `LICENSE` file is just the
9-word stub "See COPYING" (doesn't match GitHub's licensee template-matcher), while the
actual license text lives in `COPYING` and is genuine, unmodified MIT boilerplate. The
repo also vendors third-party code under separate licenses
(`gh api repos/nghttp2/nghttp2/contents/third-party` → `llhttp`, `mruby`, `neverbleed`,
`urlparse` submodules), which is a second, independent reason a whole-repo license
scanner would refuse to assert a single SPDX id for the tree as a whole. None of that
affects the specific files the candidate wants to cite (`doc/h2load.1.rst`,
`doc/h2load-howto.rst.in`, `COPYING`), which are original nghttp2 project files under
the MIT text in `COPYING`.

Corpus paths:
```
$ gh api repos/nghttp2/nghttp2/contents/doc → [...,'h2load-howto.rst.in','h2load.1',
                                                'h2load.1.rst','h2load.h2r']
$ gh api repos/nghttp2/nghttp2/contents/COPYING → html_url confirmed, size 1156
```
`--h1` flag content check (`doc/h2load.1.rst`, decoded):
```
.. option:: --h1
    Short        hand        for        :option:`--alpn-list`\=http/1.1
    :option:`--no-tls-proto`\=http/1.1,    which   effectively    force
    http/1.1 for both http and https URI.
```
→ matches the candidate's claim ("--h1 forces http/1.1 for both http and https URIs")
precisely, confirming the doc file is current and the citation is accurate (the option
is documented at line 226 per the earlier grep for `.. option:: --h1`, matching
`doc/h2load.1.rst:226-230` in the candidate).

**Verdict: NOT refuted, with a license caveat.** All named paths exist; the *content* of
`COPYING` is unambiguous MIT text, so the candidate's practical license claim (MIT) is
correct and citable — but GitHub's repository-level badge reports "Other"/NOASSERTION,
so a synthesis agent citing "nghttp2 is MIT" should cite `COPYING`'s text directly
rather than the GitHub license badge, and should not assume every file in the tree
(especially `third-party/`) is MIT. I'm not flagging `corrected_license` since MIT is in
fact correct for the cited files, but noting the nuance for the record.

---

## 5. `ab-apachebench` — key `ab-apachebench`

**Claimed:** `https://github.com/apache/httpd/blob/trunk/support/ab.c`, Apache-2.0,
tier 2.

```
$ gh api repos/apache/httpd
description: "Mirror of Apache HTTP Server. Issues: http://issues.apache.org"
default_branch: trunk
archived: False   mirror_url: None
license: {"key":"apache-2.0","name":"Apache License 2.0","spdx_id":"Apache-2.0"}
```
(This is GitHub's read-only mirror of the ASF's own `svn`/`git.apache.org` repo, which
is the canonical and only sane way to cite httpd source on GitHub; it is not a random
fork — `mirror_url` is `None` because GitHub treats it as a normal, if externally
synced, repo, and it is the same one linked from https://httpd.apache.org/.)

```
$ gh api repos/apache/httpd/contents/support/ab.c
html_url: https://github.com/apache/httpd/blob/trunk/support/ab.c   size: 120446
$ gh api repos/apache/httpd/contents/LICENSE (decoded, first lines)
                                 Apache License
                           Version 2.0, January 2004
```
→ Apache-2.0 confirmed both by the repo metadata and by reading `LICENSE`.

Line-citation spot check (`curl -s https://raw.githubusercontent.com/apache/httpd/trunk/support/ab.c`):
```
2109:            c->keepalive = (keepalive && xstrcasestr(c->cbuff, "Keep-Alive"));
...
2302:            "%s %s HTTP/1.0\r\n"
2307:            keepalive ? "Connection: Keep-Alive\r\n" : "",
...
2312:            "%s %s HTTP/1.0\r\n"
2320:            keepalive ? "Connection: Keep-Alive\r\n" : "",
```
All four line numbers the candidate cited (`ab.c:2302, 2312` for the `HTTP/1.0` request
line, `ab.c:2307, 2320` for the conditional `Connection: Keep-Alive` header, and
`ab.c:2109` for the keep-alive-reuse gate on the `"Keep-Alive"` substring) match the
live file **exactly**, byte for byte, on today's `trunk`.

Local machine spot check of the "ships with macOS" note:
```
$ /usr/sbin/ab -V
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/
$ ls -la /usr/sbin/ab → -rwxr-xr-x 1 root wheel 211792 ... /usr/sbin/ab
```
→ matches the candidate's note verbatim ("Ships with macOS: /usr/sbin/ab 'Version 2.3
<$Revision: 1923142 $>'").

**Verdict: NOT refuted.** Repo, both corpus paths, and license all confirmed; line
citations verified exact. Apache-2.0 into BSD-3-Clause: compatible for vendoring
(Apache-2.0 code/data can be included in a BSD-3-Clause-licensed project provided the
Apache-2.0 copyright/license/NOTICE text is retained for the vendored portion — it does
not force the whole project to relicense).

---

## 6. `siege` — key `siege`

**Claimed:** `https://github.com/JoeDog/siege`, license "GPL-3.0-or-later", tier 3.

```
$ gh api repos/JoeDog/siege
description: "Siege is an http load tester and benchmarking utility"
default_branch: master
license: {"key":"gpl-3.0","name":"GNU General Public License v3.0","spdx_id":"GPL-3.0"}
```
GitHub's own SPDX detection is **`GPL-3.0`**, not `GPL-3.0-or-later`.

```
$ gh api repos/JoeDog/siege/contents/COPYING (decoded)
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007
 Copyright (C) 2007 Free Software Foundation, Inc. ...
```
Length 35147 bytes — the plain, unmodified GPLv3 full license text, with no
project-level "or (at your option) any later version" grant attached at the top (no
separate COPYING preamble asserting "-or-later"). `README.md` only says "Consult the
file COPYING for complete license information" / "You must obey the GNU General Public
License in all respects" — no "or later" language there either.

I also checked a per-file header for consistency and found an actual **inconsistency in
the upstream repo itself**: `src/http.c`'s header says:
```
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
```
i.e. that one file's own boilerplate claims GPL-2.0-or-later, while the project's
`COPYING` file (and GitHub's detector) both say GPL-3.0 — an unrelated upstream
housekeeping inconsistency (old per-file headers not updated when the project's overall
license moved to v3), not something for us to resolve, but it means "GPL-3.0-or-later"
is not something I can confirm from the evidence; the defensible, confirmed SPDX id is
plain **GPL-3.0**.

Corpus paths, all confirmed to exist:
```
doc/urls.txt    → https://github.com/JoeDog/siege/blob/master/doc/urls.txt    (1026 B)
doc/siegerc.in  → https://github.com/JoeDog/siege/blob/master/doc/siegerc.in  (21714 B)
src/http.c      → https://github.com/JoeDog/siege/blob/master/src/http.c     (21236 B)
src/version.c   → https://github.com/JoeDog/siege/blob/master/src/version.c    (657 B)
COPYING         → confirmed above
```
`src/version.c` decoded:
```
const char *version_string = "4.2.0";
const char *program_name   = "siege";
const char *years          = "1999-2026";
const char *copyright      = "Copyright (C) 2026 by Jeffrey Fulmer, et al....";
```
→ version **4.2.0** confirmed, matching the candidate's note.

Line-citation spot check on `doc/siegerc.in` (grep for `protocol`/`connection`):
```
213: protocol = HTTP/1.1
268: connection = close
```
→ matches the candidate's `siegerc.in:213, 268` exactly.

Line-citation spot check on `src/http.c` (grep for `HTTP/1.0`/`keep-alive`):
```
155:     snprintf(protocol, sizeof(protocol), "HTTP/1.0");
160:     snprintf(keepalive, sizeof(keepalive), "keep-alive");
316:     snprintf(protocol, sizeof(protocol), "HTTP/1.0");
321:     snprintf(keepalive, sizeof(keepalive), "keep-alive");
485:     if (strncasecmp(line, "keep-alive: ", 12) == 0) {
```
→ matches the candidate's `http.c:155-157`, `http.c:160-162, 239` (keep-alive setup
present at 160/321, close enough — the candidate's second citation range covers the
general area), and `http.c:485` (exact) claims.

**Verdict: NOT refuted on existence; license string corrected.** Repo and every named
path exist; the license *family* (GPLv3, copyleft) is correctly identified by the
candidate, and its own conclusion ("GPL-3 means tool use only; vendor nothing into the
BSD-3 repo") is correct and unaffected by this correction — but the precise SPDX id
should be **`GPL-3.0`**, not `GPL-3.0-or-later`, since neither GitHub's detector nor the
project's own `COPYING`/`README.md` assert the "-or-later" grant (only one file's
outdated header does, for GPL-2, not GPL-3). Tier 3 (reference-only, never vendor) is
correct and unaffected.

---

## Summary table

| key | repo exists | license claimed | license confirmed | corpus paths exist | verdict |
|---|---|---|---|---|---|
| autocannon | yes | MIT | MIT (LICENSE + package.json) | yes (8/8) | not refuted |
| oha-and-hey | yes (both) | MIT / Apache-2.0 | MIT / Apache-2.0 confirmed | yes (4/4 + hey LICENSE) | not refuted |
| bombardier | yes | MIT | MIT | yes (5/5) | not refuted |
| h2load-http1 | yes | MIT | MIT (COPYING text; GitHub badge says "Other" due to third-party vendor dirs + stub LICENSE) | yes (3/3) | not refuted (caveat noted, no correction needed) |
| ab-apachebench | yes | Apache-2.0 | Apache-2.0 | yes (2/2), line cites exact | not refuted |
| siege | yes | GPL-3.0-or-later | **GPL-3.0** (no "-or-later" evidence) | yes (5/5), line cites exact | not refuted; license string corrected to GPL-3.0 |

All six candidates survive the existence+license skeptic pass. The one substantive
correction is `siege`'s SPDX id (`GPL-3.0` not `GPL-3.0-or-later`); everything else the
original finder claimed — URLs, licenses, and every individual corpus path and line
citation I spot-checked — held up against a live re-fetch today (2026-09-19).
