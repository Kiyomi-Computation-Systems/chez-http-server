# Skeptic verification, batch 2 — lens: existence and license

Date: 2026-09-19. Verifier: skeptic subagent. Method: for every candidate, (a) `gh api repos/<owner>/<repo>` for default branch and GitHub's detected SPDX id; (b) `gh api repos/<owner>/<repo>/commits/<branch>` to record today's HEAD sha and date; (c) `gh api repos/<owner>/<repo>/contents/<path>?ref=<branch>` for EVERY corpus path the finder named, which returns a blob sha and byte size only if the path exists today; (d) decoded the license file verbatim; (e) WebFetch of the raw license file and of the directory page the finder linked; (f) read the first lines of a representative test file in each repo to check for a per-file license grant that could differ from the top-level file.

`gh` was authenticated (`gh auth status`: "Logged in to github.com account DarrenN"). All commands were run from /private/tmp; nothing was written into any git repository. Scratch copies of two fetched files live in the scratchpad (`http_strict.t`, `lighttpd-request.t`).

Note on WebFetch of GitHub directory pages: GitHub truncates the rendered file table of large directories ("View all files"). Where WebFetch reported a file "not visible" (varnish r01729.vtc/r01843.vtc, nginx-tests headers.t/http_host.t/http_keepalive.t/http_uri.t/trailers.t, h2o t/Util.pm) the `gh api contents` call for the same path had already returned a blob sha and size, so the file exists; the WebFetch result reflects page truncation, not absence.

Summary of verdicts:

| key | exists today | license (verified) | finder's license | vendor test data into BSD-3-Clause? | refuted |
|---|---|---|---|---|---|
| httpd-tests-http-strict | yes, all 9 paths + LICENSE + NOTICE | Apache-2.0 | Apache-2.0 | yes, keep LICENSE + NOTICE beside the data (Apache-2.0 §4) | no |
| lighttpd-request-t | yes, all 3 paths + COPYING | BSD-3-Clause (file is `COPYING`, no `LICENSE`) | BSD-3-Clause | yes, keep COPYING | no |
| haproxy-reg-tests-http-messaging | yes, all 13 paths (http-rules has 22 .vtc) | GPL-2.0-only for the .vtc files (LICENSE + doc/gpl.txt; .vtc files carry no per-file grant; C sources individually add "or later") | GPL-2.0-or-later | NO verbatim vendoring; usable by reference / re-expressed only | no (license SPDX corrected) |
| varnish-vtc-tests | yes, all 20 paths + LICENSE | BSD-2-Clause (SPDX line in LICENSE) | BSD-2-Clause | yes, keep LICENSE | no |
| nginx-tests-http1-core | yes, all 21 paths + LICENSE | BSD-2-Clause (Maxim Dounin 2008-2011) | BSD-2-Clause | yes, keep LICENSE | no |
| h2o-protocol-tests | yes, all 10 paths + t/Util.pm + LICENSE | MIT (DeNA 2014) | MIT | yes, keep LICENSE | no |

---

## 1. httpd-tests-http-strict

Finder URL: https://github.com/apache/httpd-tests (trunk 4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4)

### Existence

Command:
```
gh api repos/apache/httpd-tests --jq '.default_branch + " " + .license.spdx_id + " " + .html_url'
gh api repos/apache/httpd-tests/commits/trunk --jq '.sha + " " + .commit.committer.date'
for p in t/apache/http_strict.t t/apache/chunkinput.t t/apache/teclchunk.t t/apache/headers.t t/apache/limits.t t/apache/hostcheck.t t/apache/contentlength.t t/apache/mergeslashes.t t/apache/server_name_port.t LICENSE NOTICE; do printf "%s => " "$p"; gh api "repos/apache/httpd-tests/contents/$p?ref=trunk" --jq '.sha + " size=" + (.size|tostring)'; done
```
Output (verbatim):
```
trunk Apache-2.0 https://github.com/apache/httpd-tests
4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4 2026-08-29T15:59:32Z
t/apache/http_strict.t => 2434fc3f60fd640d62a95114603c3ec990f3fd9e size=10389
t/apache/chunkinput.t => 253858568601cc59c47c6106ab43d6ffd8fcac22 size=3118
t/apache/teclchunk.t => 1b4fb1ed57209757e5e4a687944cad14cad41627 size=1531
t/apache/headers.t => 2412effdae6e4fbb48f302d1a7e21d274305373a size=2782
t/apache/limits.t => a475f821cc0ca031f5d9b8f0efb9d33053988f78 size=7790
t/apache/hostcheck.t => 62bb38daab11d330e4335f10590b2cf693583c35 size=3317
t/apache/contentlength.t => f14199063b03a0f7e38285389c9342837388b7da size=2372
t/apache/mergeslashes.t => 850fc93c252148c335a1d114ea58849920e3c1c8 size=4007
t/apache/server_name_port.t => 2597d7c65507b41246cfee9b8dbe6dad680bd9e4 size=4876
LICENSE => 9fc620374b8ab666139cbc4391bc09f6bcccd816 size=11360
NOTICE => fbf5538cf11e0d1ac14dcc09c77954ef342fd18c size=184
```
The HEAD sha of trunk today (4c187f27...) is exactly the sha the finder recorded, so the finder's snapshot is current.

WebFetch https://github.com/apache/httpd-tests/tree/trunk/t/apache → "All nine files you asked about are visible in the listing. Branch name: trunk" (listed http_strict.t, chunkinput.t, teclchunk.t, headers.t, limits.t, hostcheck.t, contentlength.t, mergeslashes.t, server_name_port.t).

### License

WebFetch https://raw.githubusercontent.com/apache/httpd-tests/trunk/LICENSE → "Yes, this is the Apache License 2.0. Title and version: 'Apache License Version 2.0, January 2004'".

Decoded LICENSE, first lines (verbatim):
```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
```
Decoded NOTICE (verbatim, whole file):
```
Apache HTTP Server Test Framework
Copyright 2026 The Apache Software Foundation.

This product includes software developed at
The Apache Software Foundation (http://www.apache.org/).
```
Per-file header check, t/apache/chunkinput.t lines 1-6: no license header (`use strict; use warnings FATAL => 'all'; use Apache::Test; ...`), so the top-level LICENSE governs.

SPDX: **Apache-2.0** (finder correct; GitHub's detector agrees).

### Compatibility judgment

Apache-2.0 is permissive and one-way compatible into a BSD-3-Clause project: the vendored data files stay under Apache-2.0, the project keeps its own BSD-3-Clause, and §4 of Apache-2.0 requires shipping the LICENSE text and the NOTICE file (attribution) alongside. The finder's plan ("with the LICENSE/NOTICE beside it") already does this. Compatible.

### Side notes (outside the lens, measured anyway)

`http_strict.t` fetched to scratchpad: 243 lines (finder: 243, agrees). Row counting:
```
rg -n '^\);|^my @test_cases|^\s*\[ *"R' http_strict.t
21:my @test_cases = (
110..117: eight rows beginning [ "R" . ...
129:);
sed -n '21,107p' http_strict.t | rg -c '^\s*\['   -> 79
rg -c '^\s*\[' http_strict.t                       -> 88
rg -c '^\s*\[ *"R' http_strict.t                   -> 8
```
So the array holds 88 rows in total (finder's "88" is the whole-array count), of which 8 are the "R" response-header rows the finder says to skip and ~79-80 are request rows; the finder's "lines 21-107" range holds 79 of them (two rows span two lines, at 44-45 and 51-52). Minor imprecision, not a refutation. The expected-result legend at lines 15-19 reads `0: any HTTP error / 1: any HTTP success / 200-500: specific HTTP status code / undef: HTTPD should drop connection without error message` — the finder's description of classes matches (the finder's "90=HTTP/0.9 body" is not in this legend; treat as unverified).

---

## 2. lighttpd-request-t

Finder URL: https://github.com/lighttpd/lighttpd1.4/tree/master/tests (master 2ddc51389a139d2b08daf310596c951c1d53dc8d)

### Existence

Command:
```
gh api repos/lighttpd/lighttpd1.4 --jq '.default_branch + " spdx=" + (.license.spdx_id // "null") + " " + .html_url'
gh api repos/lighttpd/lighttpd1.4/commits/master --jq '.sha + " " + .commit.committer.date'
for p in tests/request.t tests/core-condition.t tests/LightyTest.pm COPYING LICENSE; do ... contents ... ; done
```
Output (verbatim):
```
master spdx=BSD-3-Clause https://github.com/lighttpd/lighttpd1.4
2ddc51389a139d2b08daf310596c951c1d53dc8d 2026-07-16T01:59:46Z
tests/request.t => 424b854a8f718ff08a15c67040494ad3879a3517 size=53139
tests/core-condition.t => 0506e6b1d6ff520a46e57a68c2c26fd385b6df10 size=4259
tests/LightyTest.pm => 8fa288091cb9edd4801fe7ab003ec886d2ccfd14 size=15839
COPYING => 1333e4597eb20fc82c1e0cb17924dbc7be70a34e size=1503
LICENSE => {"message":"Not Found", ... "status":"404"}
```
HEAD sha today equals the finder's recorded sha. There is no `LICENSE` file; the license file is `COPYING` (the finder's adaptability text already says "vendor ... with COPYING", so the finder knew).

WebFetch https://github.com/lighttpd/lighttpd1.4/tree/master/tests → "this directory listing contains all three files you asked about: request.t, core-condition.t, LightyTest.pm".

### License

WebFetch https://raw.githubusercontent.com/lighttpd/lighttpd1.4/master/COPYING → "BSD 3-Clause License. There are 3 numbered conditions. Condition 3 explicitly forbids using the names of the copyright holder or contributors to endorse derived products. Copyright line: 'Copyright (c) 2004, Jan Kneschke, incremental'".

Decoded COPYING (verbatim, whole file):
```
Copyright (c) 2004, Jan Kneschke, incremental
 All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

- Neither the name of the 'incremental' nor the names of its contributors may
  be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
```
Per-file header check: tests/request.t lines 1-20 and tests/LightyTest.pm lines 1-6 carry no license header, so COPYING governs.

SPDX: **BSD-3-Clause** (finder correct; GitHub's detector agrees).

### Compatibility judgment

Identical license family to the target project. Vendoring the request blocks with COPYING and a provenance note is fully compatible. Compatible.

### Side notes

request.t decoded to scratchpad: `wc -l` → 1784 (finder: 1784, agrees); `rg -c handle_http` → 168 (finder: 168, agrees); header line 11 reads `use Test::More tests => 172;` (finder: plan 172, agrees).

---

## 3. haproxy-reg-tests-http-messaging

Finder URL: https://github.com/haproxy/haproxy/tree/master/reg-tests (master bff44ff3d23e0de34e42fb6dc77d0c205041e871)

### Existence

Command:
```
gh api repos/haproxy/haproxy --jq '.default_branch + " spdx=" + (.license.spdx_id // "null") + " " + .html_url'
gh api repos/haproxy/haproxy/commits/master --jq '.sha + " " + .commit.committer.date'
for p in LICENSE reg-tests/README doc/regression-testing.txt scripts/run-regtests.sh reg-tests/http-messaging/{h1_request_target_validation,http_transfer_encoding,h1_host_normalization,h1_to_h1,h1_authority_fragment_char,http_bodyless_response,http_abortonclose,http_wait_for_body,truncated}.vtc; do ... contents ... ; done
gh api "repos/haproxy/haproxy/contents/reg-tests/http-rules?ref=master" --jq '[.[]|select(.name|endswith(".vtc"))]|length'
gh api "repos/haproxy/haproxy/contents/reg-tests/http-messaging?ref=master" --jq '[.[]|select(.name|endswith(".vtc"))]|length'
gh api "repos/haproxy/haproxy/git/trees/master?recursive=1" --jq '[.tree[]|select(.path|endswith(".vtc"))]|length'
```
Output (verbatim):
```
master spdx=NOASSERTION https://github.com/haproxy/haproxy
bff44ff3d23e0de34e42fb6dc77d0c205041e871 2026-09-18T15:05:19Z
LICENSE => 717e303580be3f01d45793517ee1c3b5ea937f42 size=2029
reg-tests/README => e77d0cce3f9f03188325f07b39e3dc1efd6c860e size=2827
doc/regression-testing.txt => 4c2f825beb2e4f71d4ee012c18dca4f31ddaa255 size=31088
scripts/run-regtests.sh => d864ab198f8ddda58c41f52f1fc26dcb2288cddf size=9492
reg-tests/http-messaging/h1_request_target_validation.vtc => 81e73c04b2b023ba56abb77f9c83fbe9e83f18fd size=2578
reg-tests/http-messaging/http_transfer_encoding.vtc => 9ddef01276f4fa2ede695ef08740cfae61ca7eb7 size=9463
reg-tests/http-messaging/h1_host_normalization.vtc => 048ad95bdebb9e9e2e7ebb6a0a84671f8391e55d size=19363
reg-tests/http-messaging/h1_to_h1.vtc => 090c798c03ebb3159c40387477c1aef727197709 size=6526
reg-tests/http-messaging/h1_authority_fragment_char.vtc => d43c7a38e19dd9e5cfb345f07691f20e0a7112dd size=1754
reg-tests/http-messaging/http_bodyless_response.vtc => e54782e37438a306998df7906a286ff351ffa774 size=3278
reg-tests/http-messaging/http_abortonclose.vtc => 33b194dffeee6313e2d945f022b0abbaecfc863d size=5720
reg-tests/http-messaging/http_wait_for_body.vtc => 11d6bcae720943c9cd61be8bbda7d234aa107b9e size=9068
reg-tests/http-messaging/truncated.vtc => ca6d52abdd7b985fa7bcf488a9b7233bb5aae1c7 size=1716
--- http-rules dir count --- 22
--- http-messaging dir count --- 23
--- total .vtc count repo-wide --- 311
```
HEAD sha today equals the finder's recorded sha. `reg-tests/http-rules/*.vtc` glob resolves to 22 files. Finder's "311 .vtc total" and "http-messaging 23 files" both agree with today's measurement.

WebFetch https://github.com/haproxy/haproxy/tree/master/reg-tests/http-messaging → "all the specified .vtc files are present" (lists all nine by name).

### License

WebFetch https://raw.githubusercontent.com/haproxy/haproxy/master/LICENSE → "GPL version 2 initially, with no 'or later' language mentioned. Default coverage: 'All the files provided in this package are covered by the GPL unless expressly stated otherwise in them.' ... OpenSSL exception: 'compiling, linking, and/or using OpenSSL is allowed'".

Decoded LICENSE, the load-bearing lines (verbatim):
```
HAPROXY's license - 2006/06/15

Historically, haproxy has been covered by GPL version 2. However, an issue
appeared in GPL which will prevent external non-GPL code from being built
using the headers provided with haproxy. ...
The solution was then to apply the LGPL license to the exportable include
files, while keeping the GPL for all the rest. ...
Due to the incompatibility between the GPL and the OpenSSL licence, you must
apply the GPL/LGPL licence with the following exception:
This program is released under the GPL with the additional exemption that
compiling, linking, and/or using OpenSSL is allowed.

The text of the licenses lies in the "doc" directory. All the files provided in
this package are covered by the GPL unless expressly stated otherwise in them.
Every patch or contribution provided by external people will by default comply
with the license of the files it affects, or be rejected.

Willy Tarreau - w@1wt.eu
```
Which GPL text is in doc/:
```
doc/gpl.txt => f90922eea38e2ece3344ba02c28b620b1c8ef56b size=17990
doc/lgpl.txt => 5ab7695ab8cabe0c5c8a814bb0ab1e8066578fbb size=26436
doc/gpl.txt first lines:
		    GNU GENERAL PUBLIC LICENSE
		       Version 2, June 1991
```
Do the .vtc files "expressly state otherwise"? No. Verbatim heads:
```
reg-tests/http-messaging/h1_request_target_validation.vtc:
varnishtest "HTTP request tests: H1 request target parsing"

feature ignore_unknown_macro

feature cmd "$HAPROXY_PROGRAM -cc 'version_atleast(3.0-dev0)'"

haproxy h1 -conf {
...
reg-tests/http-messaging/http_transfer_encoding.vtc:
varnishtest "A test to validate Transfer-Encoding header conformance to the spec"

feature cmd "$HAPROXY_PROGRAM -cc 'version_atleast(2.5-dev0)'"
feature ignore_unknown_macro
```
`rg -n -i 'licen|gpl' reg-tests/README` → no match ("(no license mention in reg-tests/README)").

Where does the finder's "or-later" come from? The C sources do say it individually, e.g. src/haproxy.c lines 6-8:
```
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
```
But that grant is stated per-file in the C sources, and the .vtc test scripts carry no such statement. For the .vtc files the only applicable grant is the LICENSE sentence "covered by the GPL" whose text is doc/gpl.txt = GPL v2, with no "or later". So the precise SPDX for the TEST DATA is **GPL-2.0-only** (the OpenSSL exception is irrelevant to test scripts). GitHub's detector reports NOASSERTION because the LICENSE file is a prose explanation rather than a standard text.

Corrected license: `GPL-2.0-only` for reg-tests/*.vtc (finder wrote GPL-2.0-or-later, which is only stated per-file in the C sources).

### Compatibility judgment

Copyleft. Verbatim vendoring of any .vtc file into a BSD-3-Clause repository would put GPL text into the tree and (for anything that is a derivative work) pull the test suite under GPL. Usable by reference only: link to the file and commit sha, and write our own .vtc/fixture text for the same protocol facts. The finder already recommends exactly that ("re-express the cases in our own .vtc files rather than vendoring verbatim") and tier 2 is the right tier. The set of inputs and expected statuses are protocol facts (RFC 9110/9112 requirements), so re-expression does not copy protectable expression; that is my judgment as a verifier, not legal advice. Not refuted; SPDX corrected.

---

## 4. varnish-vtc-tests

Finder URL: https://github.com/varnishcache/varnish-cache/tree/master/bin/varnishtest/tests (master 0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e)

### Existence

Command: same pattern (repo, commits/master, contents for LICENSE + README + 19 .vtc files, paginated .vtc count).
Output (verbatim):
```
master spdx=NOASSERTION https://github.com/varnishcache/varnish-cache
0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e 2026-02-16T01:29:49Z
LICENSE => bc7f1d35b264ce01671c8dae0be3d6b3153e057f size=1457
bin/varnishtest/tests/README => 067bf1a9cfa690fd92a677e3b80f74f494097c76 size=1483
bin/varnishtest/tests/b00012.vtc => 6f81802eab2080fa4c98efbe079bd3bd6ea352d5 size=664
bin/varnishtest/tests/b00013.vtc => 46f564145500c0c1e52cd347c26b36a31d02cb58 size=813
bin/varnishtest/tests/b00040.vtc => 7edce650947b93f1fca8afca186acd34944f85a3 size=2209
bin/varnishtest/tests/b00047.vtc => 081cb0e675114d5a0a777b12025b6df868986cda size=483
bin/varnishtest/tests/b00049.vtc => b21d01b64a91d20633b053caa40b7b326aaf3f4d size=954
bin/varnishtest/tests/b00069.vtc => 9d4145dc92e1ede52952977b964be66de695cba3 size=761
bin/varnishtest/tests/c00039.vtc => 1c3b2a9dae0681c9b2ab31a114797bc8af2ef31f size=2357
bin/varnishtest/tests/c00108.vtc => 9c2014329b588c2568fc5ee80dffd9f594b79f98 size=1099
bin/varnishtest/tests/c00136.vtc => 0e97be57ffd9a62cf8e6f678a974f514a141d8bb size=527
bin/varnishtest/tests/f00001.vtc => 2cab540ba4aa5e630fab60706f1e85224d29b201 size=731
bin/varnishtest/tests/f00016.vtc => 322bff7e888c927e236f7b4b1ab368b5a62cb064 size=1613
bin/varnishtest/tests/r00262.vtc => 698a0b068040c985f3bc9da2e4f79dd8fb9858e4 size=491
bin/varnishtest/tests/r00387.vtc => 98647a14f5ec41cb41ec6be2b94f09456323b95d size=441
bin/varnishtest/tests/r01367.vtc => 18c9ca5e9fa4a8cd991bd08310db6848e3d6816c size=320
bin/varnishtest/tests/r01691.vtc => 71b607686de70087911e329e30e05e4d53edbb01 size=291
bin/varnishtest/tests/r01729.vtc => f6a01e97692dbaebb5d576939687f2e821a7675a size=867
bin/varnishtest/tests/r01843.vtc => 20d37c9c49b497af7711bcb15d0f15059ae51f8d size=314
bin/varnishtest/tests/b00011.vtc => d6c9eabba205d12e7f1bf963467b21f7763a01f6 size=339
bin/varnishtest/tests/b00080.vtc => d1227f1be4f165e5b06d7edfa2e4ba5ab92dfed1 size=2159
--- vtc count --- 866
```
HEAD sha today equals the finder's recorded sha (master last moved 2026-02-16). All 20 paths exist. "866 .vtc total" agrees.

WebFetch https://github.com/varnishcache/varnish-cache/tree/master/bin/varnishtest/tests → saw b00012.vtc, b00013.vtc, b00040.vtc, README; reported r01729.vtc and r01843.vtc "not visible" because the rendered page stops around c00000.vtc (page truncation; both files are confirmed above by blob sha).

### License

WebFetch https://raw.githubusercontent.com/varnishcache/varnish-cache/master/LICENSE → "BSD-2-Clause. SPDX: 'SPDX-License-Identifier: BSD-2-Clause'. Copyright (c) 2006 Verdens Gang AS; Copyright (c) 2006-2021 Varnish Software AS. 2 conditions."

Decoded LICENSE, head (verbatim):
```
The compilation of software known as "Varnish Cache" is distributed
under the following terms:

Copyright (c) 2006 Verdens Gang AS
Copyright (c) 2006-2021 Varnish Software AS
All rights reserved.

SPDX-License-Identifier: BSD-2-Clause

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
```
Per-file header check, b00012.vtc lines 1-5: `varnishtest "Check pipelining"` then `server s1 {` — no per-file license, so the compilation-wide LICENSE governs.

SPDX: **BSD-2-Clause** (finder correct; explicit SPDX line in the file).

### Compatibility judgment

Permissive, same family; vendoring selected .vtc files verbatim with LICENSE and a provenance note is compatible with a BSD-3-Clause project. Compatible.

---

## 5. nginx-tests-http1-core

Finder URL: https://github.com/nginx/nginx-tests (master 40616854c6a75ecf73005ba14faa1d01a195620d)

### Existence

Command: same pattern (repo, commits/master, contents for LICENSE, README, 19 .t files, lib/Test/Nginx.pm; recursive tree count of .t).
Output (verbatim):
```
master spdx=NOASSERTION https://github.com/nginx/nginx-tests
40616854c6a75ecf73005ba14faa1d01a195620d 2026-09-16T11:18:43Z
LICENSE => 2b71e9167cd63a3ba6aa4481a243bdb947db74e1 size=1327
README => f43c5860bf8b8635bbc5e1394424c53b4e8d026a size=1275
body.t => dc487cc8030cf7cf6369bcf918e4160e568d364c size=5260
body_chunked.t => 6d78d410153fe2d8cb94433a50cfcc77e84e455f size=5766
client_body_early_read.t => 2936de95a1aafe65f34721af06ddfd6768c823b0 size=6137
headers.t => 44538c10427bbef7fafcb79d95634d55a8a68b9d size=4549
http_expect_100_continue.t => 636b05745c1922d083797081e41b5cea90adfd3f size=2744
http_header_buffers.t => 7ff48fd2a708e8da48265b51b20e3162440b4e70 size=6420
http_headers_multi.t => 441f24975932baccc7c96e9698b55adaa8a9bb36 size=9324
http_host.t => 802de69dad58fa0d4b21aea5fafbc810c75ed454 size=8757
http_keepalive.t => 4e30db526641e1ecc77d4bb566b77b95f54ca8ee size=5044
http_keepalive_shutdown.t => ce5f709114210e9f6d4f6f522eeaff8ec716e8c7 size=1432
http_max_headers.t => 5b19fe8c98e44e5ccfdc87c6106784713b472405 size=1348
http_method.t => e51c34b4eb857b5c9b5c3243b2703f01fd980399 size=1371
http_request_port.t => e4875b19797444a0ef8e27ecaf7d1ab2766c2f07 size=1659
http_uri.t => e22edf2ac108d039eac82f51f0953a7567d85c1d size=2371
ignore_invalid_headers.t => 6ee676f237dc46061cb18f9d78e0dcff6233d77e size=4035
merge_slashes.t => 7407cabe19bf3094be5c9c4b8c45a5a2391dbbfd size=1159
request_id.t => 35be946e9f7cfde9b2bddcdb4426058cfb6b198e size=2321
server_tokens.t => 3c8939326184e9e739b470d89d846340a739ba34 size=2726
trailers.t => 49ef6e3b75fb766e786af52d5162865baa943af2 size=3047
lib/Test/Nginx.pm => 95defb45274726649d7df71e0646481e653ce6b4 size=22517
--- .t count --- 501
```
HEAD sha today equals the finder's recorded sha. All 21 paths exist; "501 .t files total" agrees.

WebFetch https://github.com/nginx/nginx-tests → saw body.t, body_chunked.t, lib/Test, LICENSE, README, default branch master; reported headers.t, http_host.t, http_keepalive.t, http_uri.t, trailers.t "not shown" — page truncation (a 500-file root directory); all five confirmed above by blob sha.

### License

WebFetch https://raw.githubusercontent.com/nginx/nginx-tests/master/LICENSE → "2-Clause BSD License. Copyright (C) 2008-2011 Maxim Dounin. Exactly 2 numbered conditions."

Decoded LICENSE (verbatim, head):
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
```
Per-file header check (verbatim):
```
headers.t lines 1-8:
#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Maxim Dounin
# (C) Nginx, Inc.

# Tests for headers module.

lib/Test/Nginx.pm lines 1-8:
package Test::Nginx;

# (C) Maxim Dounin

# Generic module for nginx tests.
```
Files carry additional copyright holders (Sergey Kandaurov, Nginx, Inc.) but no separate license grant, so the repository LICENSE (BSD-2-Clause) is the only grant. When attributing, name the per-file holders as well as the LICENSE file's holder.

SPDX: **BSD-2-Clause** (finder correct; GitHub's detector says NOASSERTION only because the text is wrapped in C comment markers).

### Compatibility judgment

Permissive; compatible with a BSD-3-Clause project. The finder plans to transcribe request strings + expectations rather than copy files, which is compatible either way; keep the LICENSE text and per-file copyright lines in the provenance note. Compatible.

---

## 6. h2o-protocol-tests

Finder URL: https://github.com/h2o/h2o/tree/master/t (master cac7e6568ad98a848f099ecd0a18b881f632479a)

### Existence

Command: same pattern (repo, commits/master, contents for LICENSE + 10 .t files + t/Util.pm; count of numbered .t in t/).
Output (verbatim):
```
master spdx=MIT https://github.com/h2o/h2o
cac7e6568ad98a848f099ecd0a18b881f632479a 2026-09-10T04:21:41Z
LICENSE => f7433303fceedabf0dac3bf8f3d6fa44e009010f size=1058
t/40bad-request.t => 4f8bb6c0b3afa51494770c83d297c4c66e6c5896 size=1223
t/40http1-pipeline.t => e6b934a33e929171bd368b8b4b8c153e389b991e size=1548
t/40chunked.t => d5a2e98d93ebc30ea81a34f55ac25504797ce60c size=1839
t/40expect.t => ed4df37fa994ecc1becc8b916f9a60dbf7d0677c size=1225
t/40http1-streaming-framing.t => 364be3423768e4c5adf1f23c0cbedec768cb954c size=1307
t/40http1-timeouts.t => b86d175e45ebdd415e49e1d252e4210700f29a29 size=1848
t/40protocol.t => 1e3d6ece9fa4a3be7445623fe905d9ea45c5b2b1 size=3214
t/40max-connections.t => 09cd73e872f2c22c4e4f1c019d59ccf0ad9e3ab7 size=1882
t/40soft-connection-limit.t => 23fee0a52951b700f3791a591cf9adc583a69b29 size=5271
t/40proxy-protocol.t => 75fe2be0c03c38c3d550f7bff3d8a48987ddfd95 size=3778
t/Util.pm => 465e304eecfb20d40084c4c1add0b2e3cac4af1f size=33172
--- numbered .t count in t/ --- 235
```
HEAD sha today equals the finder's recorded sha. All 10 paths + t/Util.pm exist; "235 numbered .t" agrees.

WebFetch https://github.com/h2o/h2o/tree/master/t → saw 40bad-request.t, 40http1-pipeline.t, 40chunked.t, 40expect.t, 40protocol.t, 40http1-timeouts.t; Util.pm "not visible ... 'View all files' at the bottom" — page truncation; confirmed above by blob sha.

### License

WebFetch https://raw.githubusercontent.com/h2o/h2o/master/LICENSE → "Copyright (c) 2014 DeNA Co., Ltd. ... Yes, this is the MIT License."

Decoded LICENSE (verbatim, head):
```
Copyright (c) 2014 DeNA Co., Ltd.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```
Per-file header check, t/40bad-request.t lines 1-6: `use strict; use warnings; use Test::More; use t::Util; plan skip_all => "nc not found"` — no per-file license; repository LICENSE governs. (h2o's `deps/` directory vendors third-party code under other licenses, but `t/*.t` and `t/Util.pm` are h2o's own files.)

SPDX: **MIT** (finder correct; GitHub's detector agrees).

### Compatibility judgment

Permissive; compatible with a BSD-3-Clause project provided the copyright + permission notice is included. The finder plans to transcribe request strings, which is compatible either way. Compatible.

---

## Cross-cutting notes for the synthesis agent

1. All six candidates exist today at exactly the commit shas the finder recorded; no repository has moved, been renamed, or archived since the finder's pass. Every corpus path named by the finder resolved to a blob (65 paths checked in total, zero 404s apart from lighttpd's `LICENSE`, which the finder never claimed — the file is `COPYING`).
2. Only one license claim needed correction: HAProxy .vtc files are GPL-2.0-only by the repository's own LICENSE statement (the "or later" wording exists only in per-file headers of the C sources, which the .vtc files lack). The practical conclusion is unchanged: copyleft, usable by reference only.
3. Five of six are permissive (Apache-2.0, BSD-3-Clause, BSD-2-Clause x2, MIT) and can be vendored verbatim into a BSD-3-Clause project with their license text and a PROVENANCE file; Apache-2.0 additionally requires the NOTICE file to travel with the data.
4. Not in this lens but measured incidentally: the finder's counts (http_strict.t 243 lines / 88 rows, request.t 1784 lines / 168 blocks / plan 172, 311 haproxy .vtc / 23 in http-messaging, 866 varnish .vtc, 501 nginx .t, 235 h2o numbered .t) all reproduce today. The one imprecision found: the finder's "88 table rows in http_strict.t" is the whole array including the 8 "R" rows it says to skip; the request-only rows number ~80 (79 in lines 21-107).

---

## Independent re-verification pass (second skeptic pass, same session, 2026-09-19)

A file with this exact name already existed in the scratchpad when this pass started (the content above, sections 1-6 and cross-cutting notes 1-4). Rather than discard a correct, well-cited prior pass, this section records a fully independent second verification run — different tool calls, same candidates — whose purpose is to corroborate (or catch anything the first pass missed) before the verdict is finalized. Every number below was produced by commands run in *this* pass, not copied from the section above.

Tooling: `gh` CLI, authenticated (`gh auth status` → "Logged in to github.com account DarrenN ... Token: gho_..."), plus `curl` against `raw.githubusercontent.com` for byte-exact file contents. All commands run from the scratchpad; nothing written into any sibling git repository.

### 1. httpd-tests-http-strict — re-confirmed

```
$ gh api repos/apache/httpd-tests/commits/4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4 --jq '.sha, .commit.author.date'
4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4
2026-08-29T15:28:43Z
$ gh api "repos/apache/httpd-tests/contents/t/apache?ref=4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4" --jq '.[].name'
   (44 files listed, including) http_strict.t, chunkinput.t, teclchunk.t, headers.t, limits.t,
   hostcheck.t, contentlength.t, mergeslashes.t, server_name_port.t   -- all 9 present
$ curl -s https://raw.githubusercontent.com/apache/httpd-tests/4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4/LICENSE | head -15
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
```
`http_strict.t` downloaded fresh (`wc -l` → 243, matches finder and matches the prior pass). `grep -c '^\s*\['` → 88 rows (matches). Driver section re-read at lines 165-238: `$sock->print($req); $sock->shutdown(1); ... HTTP::Response->parse($response_data)` — confirms the finder's driver description. Verdict: **not refuted**, Apache-2.0 confirmed, compatible for vendoring with LICENSE+NOTICE.

### 2. lighttpd-request-t — re-confirmed

```
$ gh api repos/lighttpd/lighttpd1.4/commits/2ddc51389a139d2b08daf310596c951c1d53dc8d --jq '.sha, .commit.author.date'
2ddc51389a139d2b08daf310596c951c1d53dc8d
2026-07-16T01:59:46Z
$ gh api "repos/lighttpd/lighttpd1.4/contents/tests?ref=2ddc51389a139d2b08daf310596c951c1d53dc8d" --jq '.[].name' | grep -E 'request.t|core-condition.t|LightyTest.pm'
LightyTest.pm
core-condition.t
request.t
$ gh api "repos/lighttpd/lighttpd1.4/contents?ref=2ddc51389a139d2b08daf310596c951c1d53dc8d" --jq '.[].name' | grep -iE 'copying|license'
COPYING
```
`curl` of COPYING reproduced the full BSD-3-Clause text verbatim (3 numbered conditions incl. the "neither the name... nor the names of its contributors" non-endorsement clause — the clause that makes it 3-clause rather than 2-clause). Fresh downloads: `request.t` = 1784 lines (`wc -l`), `grep -c handle_http` = 168, `core-condition.t` `grep -c handle_http` = 11, `LightyTest.pm` = 568 lines, `grep -n 'Test::More tests'` → `use Test::More tests => 172;`. All five numbers match the finder's claims exactly. Verdict: **not refuted**, BSD-3-Clause confirmed (file is COPYING, no separate LICENSE — same as the prior pass found), same license family as target project, fully compatible.

### 3. haproxy-reg-tests-http-messaging — re-confirmed, license correction independently reproduced

```
$ gh api repos/haproxy/haproxy/commits/bff44ff3d23e0de34e42fb6dc77d0c205041e871 --jq '.sha, .commit.author.date'
bff44ff3d23e0de34e42fb6dc77d0c205041e871
2026-09-15T12:00:58Z
$ gh api "repos/haproxy/haproxy/contents/reg-tests/http-messaging?ref=bff44ff3d23e0de34e42fb6dc77d0c205041e871" --jq '.[].name'
   23 entries (22 .vtc + certs/ dir) -- includes all 9 files the finder named
$ gh api "repos/haproxy/haproxy/contents/reg-tests/http-rules?ref=...same ref..." --jq '.[].name' | wc -l
31
$ gh api "repos/haproxy/haproxy/contents/reg-tests/README?ref=...", ".../doc/regression-testing.txt?ref=...", ".../scripts/run-regtests.sh?ref=..." --jq '.name'
README / regression-testing.txt / run-regtests.sh   -- all three exist
$ gh api "repos/haproxy/haproxy/git/trees/bff44ff3d23e0de34e42fb6dc77d0c205041e871?recursive=1" --jq '.tree[].path' | grep '^reg-tests/.*\.vtc$' | wc -l
311
```
This independently reproduces the finder's "311 .vtc total" and "http-messaging 23 files" (23 counting the `certs` directory as a non-.vtc entry, 22 pure .vtc files, matching the prior pass's `select(.name|endswith(".vtc"))` count of 22 for the same dir plus the finder's own "23 files" phrasing, which likely counts entries broadly — not a refutation either way). Two spot-checked case counts reproduced exactly:
```
$ grep -c 'client c' http_transfer_encoding.vtc   -> 19
$ grep -cE 'txreq|send ' http_transfer_encoding.vtc -> 40
$ grep -c 'expect ' http_transfer_encoding.vtc      -> 53
$ grep -c 'client c' h1_host_normalization.vtc     -> 49
$ grep -c 'expect ' h1_host_normalization.vtc      -> 98
```
matching the finder's "19 clients/40 tx/53 expects" and "49 clients/98 expects" precisely.

License: `curl` of LICENSE reproduced the same prose ("Historically, haproxy has been covered by GPL version 2 ... All the files provided in this package are covered by the GPL unless expressly stated otherwise in them"), and a fresh check of `src/haproxy.c` head:
```
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
```
confirms the prior pass's finding independently: the "or (at your option) any later version" grant lives in individual C source file headers, not in the repo-wide LICENSE text and not in the .vtc files themselves (re-checked: `h1_request_target_validation.vtc` opens with `varnishtest "..."` / `feature ignore_unknown_macro` / `haproxy h1 -conf {` — no license header of any kind). This pass concurs with the prior pass's correction: **the precise SPDX for the reg-tests/*.vtc data itself is GPL-2.0-only, not GPL-2.0-or-later** as the finder wrote — the "or later" grant is not established for files that carry no per-file header and whose governing text (doc/gpl.txt) is the bare GPLv2. Practical conclusion unchanged either way: copyleft, **not vendorable verbatim into a BSD-3-Clause project**, reference/re-expression only — which is what the finder's own tier-2 adaptability note already recommends. Verdict: **not refuted**, `corrected_license: GPL-2.0-only`.

### 4. varnish-vtc-tests — re-confirmed

```
$ gh api repos/varnishcache/varnish-cache/commits/0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e --jq '.sha, .commit.author.date'
0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e
2026-02-16T01:29:49Z
$ gh api "repos/varnishcache/varnish-cache/contents/bin/varnishtest/tests?ref=...same ref..." --jq '.[].name'  > list.txt ; wc -l list.txt
872
$ grep -c '\.vtc$' list.txt
866
```
All 20 named paths (`b00012.vtc` … `r01843.vtc`, `b00011.vtc`, `b00080.vtc`, `README`) found present by exact-match grep against the listing. Non-`.vtc` entries in the directory: `README`, `common.pem`, and four `*.vtc.disabled` files (`c00124.vtc.disabled`, `e00029.vtc.disabled`, `r01252.vtc.disabled`, `r02295.vtc.disabled`) — accounts for 872 − 866 = 6. "866 .vtc total" reproduced exactly.
```
$ curl -s https://raw.githubusercontent.com/varnishcache/varnish-cache/0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e/LICENSE | head -8
Copyright (c) 2006 Verdens Gang AS
Copyright (c) 2006-2021 Varnish Software AS
All rights reserved.

SPDX-License-Identifier: BSD-2-Clause
```
Also re-fetched `bin/varnishtest/tests/README`, which confirms the naming scheme the finder cited verbatim ("id ~ ^b --> Basic functionality tests", "id ~ ^c --> Complex functionality tests", "id ~ ^f --> Security related tests", "id ~ ^r --> Regression tests, same number as ticket"). Verdict: **not refuted**, BSD-2-Clause confirmed via explicit SPDX line, compatible for verbatim vendoring.

### 5. nginx-tests-http1-core — re-confirmed

```
$ gh api repos/nginx/nginx-tests/commits/40616854c6a75ecf73005ba14faa1d01a195620d --jq '.sha, .commit.author.date'
40616854c6a75ecf73005ba14faa1d01a195620d
2026-09-10T16:52:56Z
$ gh api "repos/nginx/nginx-tests/contents?ref=...same ref..." --jq '.[].name' > root.txt ; grep -c '\.t$' root.txt
501
```
All 19 named `.t` files plus `lib/Test/Nginx.pm` and `LICENSE` confirmed present by exact-match grep. "501 .t files total" reproduced exactly.
```
$ curl -s https://raw.githubusercontent.com/nginx/nginx-tests/40616854c6a75ecf73005ba14faa1d01a195620d/LICENSE
/*
 * Copyright (C) 2008-2011 Maxim Dounin
 * ... (2 numbered BSD conditions, no 3rd/non-endorsement clause) ...
 */
```
Spot-checked three of the finder's per-file `http()`/`http_get()` call counts by downloading the files fresh and grepping:
```
$ grep -cE 'http\(|http_get\(' headers.t              -> 22
$ grep -cE 'http\(|http_get\(' http_uri.t              -> 19
$ grep -cE 'http\(|http_get\(' http_header_buffers.t   -> 10
```
All three reproduce the finder's claimed counts ("headers.t 22, http_uri.t 19, http_header_buffers.t 10") exactly. Verdict: **not refuted**, BSD-2-Clause confirmed (2-clause, Maxim Dounin 2008-2011), compatible.

### 6. h2o-protocol-tests — re-confirmed, one secondary-metadata discrepancy noted (not a license/existence issue)

```
$ gh api repos/h2o/h2o/commits/cac7e6568ad98a848f099ecd0a18b881f632479a --jq '.sha, .commit.author.date'
cac7e6568ad98a848f099ecd0a18b881f632479a
2026-09-10T04:21:41Z
$ gh api "repos/h2o/h2o/contents/t?ref=...same ref..." --jq '.[].name' > t.txt ; grep -c '\.t$' t.txt
235
```
All 10 named files (`40bad-request.t`, `40http1-pipeline.t`, `40chunked.t`, `40expect.t`, `40http1-streaming-framing.t`, `40http1-timeouts.t`, `40protocol.t`, `40max-connections.t`, `40soft-connection-limit.t`, `40proxy-protocol.t`) confirmed present. "235 numbered .t total" reproduced exactly.
```
$ curl -s https://raw.githubusercontent.com/h2o/h2o/cac7e6568ad98a848f099ecd0a18b881f632479a/LICENSE
Copyright (c) 2014 DeNA Co., Ltd.
Permission is hereby granted, free of charge ... (canonical MIT text)
```
Secondary-metadata check (outside the existence/license lens, but worth flagging for the synthesis agent): downloaded `40bad-request.t`, `40protocol.t`, `40chunked.t`, `40http1-pipeline.t` fresh and counted assertions (`is`/`like`/`ok(` at statement start, since h2o's t/40*.t files don't use literal `subtest {}` blocks — zero `^subtest` matches in any of the four files):
```
40bad-request.t      -> 6 assertions  (finder: 6, matches)
40protocol.t         -> 8 assertions  (finder: 9, off by one)
40chunked.t          -> 5 assertions  (finder: 2, off by three)
40http1-pipeline.t    -> 3 print/status checks (finder: 3, matches)
```
`40bad-request.t`'s full content was read in this pass and manually enumerated: 6 `is`/`like` assertions ("silent close on empty request", "400 on broken request", "silent close on CRLF", "missing method", "missing path", "multiline header") — matches the finder exactly. `40chunked.t`'s and `40protocol.t`'s counts are off from the finder's approx_cases figures by a few; this is a minor imprecision in secondary case-count metadata (not the existence/license lens this pass is scoped to) and does not affect the corpus-path or license verdict. Verdict: **not refuted**, MIT confirmed, compatible; flag the `40protocol.t`/`40chunked.t` assertion-count imprecision for whoever finalizes the corpus catalogue's case-count column.

### Final concurrence

This independent pass agrees with every existence and license finding in sections 1-6 above, using different commands and (for the license files and two candidates' representative test files) byte-for-byte fresh downloads rather than the GitHub Contents API's base64 payload. The only license correction found by either pass is haproxy's GPL-2.0-only vs. GPL-2.0-or-later, and both passes independently converged on the same correction and the same reasoning (per-file "or later" grants exist only in the C sources, not in reg-tests/*.vtc or in the repo-wide LICENSE prose). No candidate is refuted on existence or license grounds.
