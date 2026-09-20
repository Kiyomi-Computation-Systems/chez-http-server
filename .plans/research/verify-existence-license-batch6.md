# Skeptic verification — batch 6 — existence & license lens

Role: try to REFUTE each candidate. Default `refuted=true` unless existence of the repo AND
every named corpus path could be confirmed today, and the license could be confirmed.
Copyleft licenses (GPL-2.0/GPL-3.0) are flagged as usable-by-reference only, not
vendorable into a BSD-3-Clause project — that is a license-compatibility caveat, not
grounds for refutation by itself (the finder already scoped those as reference/Tier-3).

All checks run 2026-09-19 via `gh api` (GitHub API, authenticated as DarrenN) and `curl`
against rfc-editor.org. Raw commands and verbatim output below per candidate.

---

## 1. defparam-smuggler — defparam/smuggler

**Verdict: NOT REFUTED.** Repo, license, and all four named files confirmed exactly as claimed.

Commands run:
```
gh api repos/defparam/smuggler --jq '{full_name, license: .license.spdx_id, license_name: .license.name, default_branch, pushed_at, archived}'
gh api repos/defparam/smuggler/license --jq '{name, license: .license.spdx_id}'
gh api repos/defparam/smuggler/contents/configs/default.py --jq '{name, path, size, sha}'
gh api repos/defparam/smuggler/contents/configs/doubles.py --jq '{name, path, size, sha}'
gh api repos/defparam/smuggler/contents/configs/exhaustive.py --jq '{name, path, size, sha}'
gh api repos/defparam/smuggler/contents/lib/Payload.py --jq '{name, path, size, sha}'
```

Output:
```
{"archived":false,"default_branch":"master","full_name":"defparam/smuggler","license":"MIT","license_name":"MIT License","pushed_at":"2024-01-02T12:46:17Z"}
{"license":"MIT","name":"LICENSE"}
{"name":"default.py","path":"configs/default.py","sha":"c40645ee37942cc04e3ef402c6fa2c2084eaccf2","size":1772}
{"name":"doubles.py","path":"configs/doubles.py","sha":"6185834364ef6b0aedc5f657e05383094223d6dd","size":1654}
{"name":"exhaustive.py","path":"configs/exhaustive.py","sha":"2d2602534ddd74c1f2dff606042d5464783ddcd1","size":3263}
{"name":"Payload.py","path":"lib/Payload.py","sha":"b7858bd583e5e4fc420ccd881d489a5da743689d","size":2688}
```

`lib/Payload.py` header (via `gh api .../contents/lib/Payload.py --jq '.content' | base64 -d | head -20`) confirms the inline MIT header exactly as the finder described:
```
#!/usr/bin/python
# MIT License
#
# Copyright (c) 2020 Evan Custodio
# ...
```
Top-level repo `LICENSE` file also independently resolves to MIT via GitHub's license
detector (`gh api repos/defparam/smuggler/license`). Repo license is unambiguous — no
NOASSERTION, no split licensing.

Content spot-check: fetched `configs/default.py` and `configs/exhaustive.py` in full/partial
(`gh api .../contents/configs/default.py --jq '.content' | base64 -d`, and same for
`exhaustive.py` head -80). Both are exactly what the finder describes: a `render_template`
builder plus a `mutations[name] = render_template(...)` dict. `default.py` contains
`nameprefix1`, `tabprefix1`, `tabprefix2`, `space1`, and a byte-sweep loop over
`[0x1,0x4,0x8,0x9,0xa,0xb,0xc,0xd,0x1F,0x20,0x7f,0xA0,0xFF]` producing `midspace-`,
`postspace-`, `prespace-`, `endspace-`, `xprespace-`, `endspacex-`, `rxprespace-`,
`xnprespace-`, `endspacerx-`, `endspacexn-` variants — matches "systematic byte sweep... at
mid/post/pre/end positions" in the candidate's `covers` field.

`exhaustive.py` contains, verbatim, mutation keys `nameprefix1`, `tabprefix1`, `tabprefix2`,
`spacejoin1`, `underjoin1`, `smashed`, `space1`, `valueprefix1`, `vertprefix1`, `commaCow`,
`cowComma`, `contentEnc`, `linewrapped1`, `quoted`, `aposed`, `lazygrep`, `sarcasm`,
`yelling`, `0dsuffix`, `tabsuffix`, `revdualchunk`, `0dspam`, `nested`, `spaceFF`, `accentCH`,
`accentTE`, `x-rout`, `x-nout`, then `for i in range(0x1,0x20)` and `for i in
range(0x7F,0x100)` byte sweeps — this is a near-exact match to every named obfuscation in
the candidate's `covers` list (nameprefix, tabprefix, spacejoin, underjoin, space1,
vertprefix, commaCow/cowComma, contentEnc, linewrapped (obs-fold), quoted/aposed, lazygrep,
case variants ("sarcasm"/"yelling"), 0dsuffix/tabsuffix, revdualchunk, 0dspam, nested,
high-byte spaces). Confirms the `covers` claim is not fabricated.

I did not independently execute the configs to re-derive the exact mutation counts
(134/966/668) — Python3 was available in the sandbox but running the finder's exact
generation harness (which imports a `Payload` object model not shown here) was out of scope
for an existence/license check; the file sizes (1772/1654/3263 bytes) and directly observed
mutation-key density in `exhaustive.py` are consistent with several hundred entries once the
two `range()` byte sweeps (31 + 129 byte values × 4 positions ≈ 640 entries) are expanded, so
the approximate counts are plausible, not verified byte-for-byte.

**No corrections needed.** `refuted=false`.

---

## 2. portswigger-http-request-smuggler — PortSwigger/http-request-smuggler

**Verdict: NOT REFUTED**, with one correction: the repo-level `license` field via the GitHub
API reads `NOASSERTION`/"Other", not a clean `Apache-2.0` autodetect — but the finder's own
`notes` field already flagged this ("repo field NOASSERTION because tree bundles
turbo-intruder.jar") and supplied the correct underlying license by reading the LICENSE file
text directly, which I independently confirmed. So the finder's stated `license: "Apache-2.0"`
is correct as a characterization of the LICENSE file's contents; I'm noting the API
discrepancy for completeness but not treating it as a refutation since the finder already
accounted for it.

Commands:
```
gh api repos/PortSwigger/http-request-smuggler --jq '{full_name, license: .license.spdx_id, license_name: .license.name, default_branch, pushed_at, archived}'
gh api repos/PortSwigger/http-request-smuggler/license --jq '{name, license: .license.spdx_id}'
gh api repos/PortSwigger/http-request-smuggler/contents/src/burp/DesyncBox.java --jq '{name, path, size}'
gh api repos/PortSwigger/http-request-smuggler/contents/src/burp/ProbePayloads.java --jq '{name, path, size}'
gh api repos/PortSwigger/http-request-smuggler/contents/resources/CL-TE.py --jq '{name, path, size}'
gh api repos/PortSwigger/http-request-smuggler/contents/resources/TE-CL.py --jq '{name, path, size}'
gh api repos/PortSwigger/http-request-smuggler/contents/resources/H2-TE.py --jq '{name, path, size}'
gh api repos/PortSwigger/http-request-smuggler/contents/resources/H2-TUNNEL.py --jq '{name, path, size}'
```

Output:
```
{"archived":false,"default_branch":"master","full_name":"PortSwigger/http-request-smuggler","license":"NOASSERTION","license_name":"Other","pushed_at":"2026-08-13T10:42:16Z"}
{"license":"NOASSERTION","name":"LICENSE"}
{"name":"DesyncBox.java","path":"src/burp/DesyncBox.java","size":22748}
{"name":"ProbePayloads.java","path":"src/burp/ProbePayloads.java","size":2892}
{"name":"CL-TE.py","path":"resources/CL-TE.py","size":1115}
{"name":"TE-CL.py","path":"resources/TE-CL.py","size":1432}
{"name":"H2-TE.py","path":"resources/H2-TE.py","size":952}
{"name":"H2-TUNNEL.py","path":"resources/H2-TUNNEL.py","size":698}
```

All six named corpus paths exist. Repo was pushed 2026-08-13 (actively maintained, not
stale).

LICENSE file full text (`gh api repos/PortSwigger/http-request-smuggler/contents/LICENSE --jq '.content' | base64 -d`), 14 lines total:
```
Copyright 2022 PortSwigger Web Security
Copyright 2022 James Kettle <james.kettle@portswigger.net>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
This confirms Apache-2.0, Copyright 2022 PortSwigger / James Kettle, exactly as the finder's
`notes` state. The API's NOASSERTION is a GitHub license-detector artifact (likely from a
bundled `turbo-intruder.jar` binary or multiple license-like files in the tree confusing the
detector), not evidence of a different real license.

Content check of `ProbePayloads.java` (`gh api .../contents/src/burp/ProbePayloads.java --jq '.content' | base64 -d | head -60`): the file is a 13-entry static list (`PAYLOADS.add(new Payload(0, ...))` through `id 12`) of smuggled-prefix bodies — TRACE, bare `X`, GET variants, `HTTP/0.9`, `HTTP/1.2`, `%2f`, a pipelined GET, and a `CONNECT` to a PortSwigger collaborator-style hostname. This is exactly 13 payloads, matching the candidate's "13 probe prefix payloads" claim precisely. File header comment reads "Slim port of validator2's ProbePayloads: the set of smuggled-request prefixes used as the CL.0 attack body" — internally consistent with the candidate's description ("CL.0 smuggled prefixes (TRACE, HTTP/0.9, HTTP/1.2, %2f, pipelined, CONNECT)" — all of TRACE, HTTP/0.9, HTTP/1.2, %2f, pipelined-GET, and CONNECT are present).

`DesyncBox.java` register-call count: `grep -c "register("` on the decoded file returns 85 —
close to, and roughly consistent with, the candidate's "~90 permutation techniques" estimate
(85 raw `register(` occurrences likely include a few non-permutation Burp API registrations
mixed in, e.g. `registerContextMenuFactory`/`registerHttpListener`-style calls, so "~90" as a
rough figure for the permutation table specifically is plausible and not refuted, though I
did not classify each of the 85 call sites individually).

**Correction offered:** none to `url`/`corpus_paths`. Note only: GitHub's auto-detected repo
license field is NOASSERTION, but the actual LICENSE file text is unambiguously Apache-2.0 —
this matches, not contradicts, the finder's stated license. `refuted=false`.

---

## 3. rfc9112-framing-checklist — RFC 9112

**Verdict: NOT REFUTED.** Document exists, is fetchable, and the referenced sections exist.
No corpus paths were claimed (format explicitly "quotable reference, not vendored"), so
there is nothing to check for path existence.

Commands:
```
curl -s -o /dev/null -w "HTTP_STATUS:%{http_code}\n" https://www.rfc-editor.org/rfc/rfc9112.html
curl -s https://www.rfc-editor.org/rfc/rfc9112.html | grep -o "RFC 9112" | head -1
curl -s https://www.rfc-editor.org/rfc/rfc9112.html | grep -i -A3 "Copyright (c) 2022" | head -10
curl -s https://www.rfc-editor.org/rfc/rfc9112.html | grep -o "id=\"section-6-3\""
curl -s https://www.rfc-editor.org/rfc/rfc9112.html | grep -o "id=\"section-11\""
```

Output:
```
HTTP_STATUS:200
RFC 9112
            Copyright (c) 2022 IETF Trust and the persons identified as the
            document authors. All rights reserved.
            This document is subject to BCP 78 and the IETF Trust's Legal
id="section-6-3"
id="section-11"
```

Confirms: page returns HTTP 200, title matches, section anchors for §6.3 ("Message Body
Length") and §11 ("Security Considerations", with §11.1–§11.4 subsection headings also
present in the fetched HTML per an earlier grep pass) exist, and the copyright boilerplate
reads "Copyright (c) 2022 IETF Trust ... subject to BCP 78 and the IETF Trust's Legal
Provisions" — confirms the finder's "IETF Trust license" note and the "unknown" license field
is reasonably replaced by "IETF Trust / BCP 78 (RFC content, not open-source software
licensed)" — quoting as a normative reference (no vendoring) is the correct treatment
regardless.

**Correction offered:** `corrected_license`: "IETF Trust / BCP 78 (RFC copyright; reference-only, not vendored)" — refines "unknown" but doesn't change the finder's own conclusion ("quote as a normative reference, do not vendor"). `refuted=false`.

---

## 4. slowhttptest — shekyan/slowhttptest

**Verdict: NOT REFUTED.** Repo, license, and all four named paths confirmed.

Commands:
```
gh api repos/shekyan/slowhttptest --jq '{full_name, license: .license.spdx_id, license_name: .license.name, default_branch, pushed_at, archived}'
gh api repos/shekyan/slowhttptest/license --jq '{name, license: .license.spdx_id}'
gh api repos/shekyan/slowhttptest/contents/src --jq 'length'
gh api repos/shekyan/slowhttptest/contents/ng --jq 'length'
gh api repos/shekyan/slowhttptest/contents/man/slowhttptest.1 --jq '{name, path, size}'
gh api repos/shekyan/slowhttptest/contents/ng/man/slowhttptest-ng.1 --jq '{name, path, size}'
```

Output:
```
{"archived":false,"default_branch":"master","full_name":"shekyan/slowhttptest","license":"Apache-2.0","license_name":"Apache License 2.0","pushed_at":"2026-09-16T19:24:04Z"}
{"license":"Apache-2.0","name":"LICENSE"}
24
14
{"name":"slowhttptest.1","path":"man/slowhttptest.1","size":7721}
{"name":"ng/man/slowhttptest-ng.1","path":"ng/man/slowhttptest-ng.1","size":31681}
```

`src/` (24 entries) and `ng/` (14 entries) both exist as non-empty directories; the two man
pages exist with plausible sizes for real man-page content. Repo actively maintained (pushed
2026-09-16, three days before this check). License is a clean Apache-2.0 autodetect, no
NOASSERTION ambiguity, corroborated by the LICENSE file's own detected SPDX id.

**No corrections needed.** `refuted=false`.

---

## 5. haproxy-vtc-reg-tests — haproxy/haproxy

**Verdict: NOT REFUTED**, with one license-field nuance (same NOASSERTION-vs-LICENSE-text
pattern as candidate 2, and again already flagged by the finder). All five named `.vtc` files
exist.

Commands:
```
gh api repos/haproxy/haproxy --jq '{full_name, license: .license.spdx_id, license_name: .license.name, default_branch, pushed_at, archived}'
gh api repos/haproxy/haproxy/license --jq '{name, license: .license.spdx_id}'
gh api repos/haproxy/haproxy/contents/reg-tests/http-messaging/http_transfer_encoding.vtc --jq '{name, path, size}'
gh api repos/haproxy/haproxy/contents/reg-tests/http-messaging/h2_desync_attacks.vtc --jq '{name, path, size}'
gh api repos/haproxy/haproxy/contents/reg-tests/http-messaging/h1_request_target_validation.vtc --jq '{name, path, size}'
gh api repos/haproxy/haproxy/contents/reg-tests/http-messaging/truncated.vtc --jq '{name, path, size}'
gh api repos/haproxy/haproxy/contents/reg-tests/http-messaging/h1_to_h1.vtc --jq '{name, path, size}'
```

Output:
```
{"archived":false,"default_branch":"master","full_name":"haproxy/haproxy","license":"NOASSERTION","license_name":"Other","pushed_at":"2026-09-18T16:09:29Z"}
{"license":"NOASSERTION","name":"LICENSE"}
{"name":"http_transfer_encoding.vtc","path":"reg-tests/http-messaging/http_transfer_encoding.vtc","size":9463}
{"name":"h2_desync_attacks.vtc","path":"reg-tests/http-messaging/h2_desync_attacks.vtc","size":3051}
{"name":"h1_request_target_validation.vtc","path":"reg-tests/http-messaging/h1_request_target_validation.vtc","size":2578}
{"name":"truncated.vtc","path":"reg-tests/http-messaging/truncated.vtc","size":1716}
{"name":"h1_to_h1.vtc","path":"reg-tests/http-messaging/h1_to_h1.vtc","size":6526}
```

All five files exist (repo pushed 2026-09-18, one day before this check — actively
maintained). LICENSE file full text (`gh api repos/haproxy/haproxy/contents/LICENSE --jq '.content' | base64 -d`, 37 lines) confirms exactly the finder's characterization:
```
HAPROXY's license - 2006/06/15

Historically, haproxy has been covered by GPL version 2. ...
The solution was then to apply the LGPL license to the exportable include
files, while keeping the GPL for all the rest. ...
Due to the incompatibility between the GPL and the OpenSSL licence, you must
apply the GPL/LGPL licence with the following exception:
This program is released under the GPL with the additional exemption that
compiling, linking, and/or using OpenSSL is allowed.
```
This is precisely "GPL-2.0 with LGPL headers + OpenSSL exception" as the finder's `notes`
state. `refuted=false` for the core candidate.

**Side-claim check** (from the candidate's `notes`, not itself part of the license/existence
lens for haproxy, but checked since it's an attached factual claim): "Varnish's own VTC tests
are reachable through these since varnishcache/varnish-cache was archived 2026-02-16 and
moved to code.vinyl-cache.org." —
```
gh api repos/varnishcache/varnish-cache --jq '{full_name, archived, pushed_at}'
→ {"full_name":"varnishcache/varnish-cache","archived":true,"pushed_at":"2026-02-16T01:29:54Z"}
curl -s -o /dev/null -w "HTTP_STATUS:%{http_code}\n" https://code.vinyl-cache.org/
→ HTTP_STATUS:200
```
Both sub-claims confirm: the GitHub mirror is archived with a `pushed_at` timestamp matching
2026-02-16, and code.vinyl-cache.org resolves with HTTP 200. This is a corroborating side-note,
not load-bearing for the haproxy candidate's own verdict.

**Correction offered:** none to `url`/`corpus_paths`. Same NOASSERTION-API-vs-LICENSE-text
note as candidate 2. `refuted=false`.

---

## 6. regilero-httpwookiee — regilero/HTTPWookiee

**Verdict: NOT REFUTED** for existence — repo and all four files exist, GPL-3.0 confirmed,
staleness (last push 2017-12-02) confirmed. As the finder already concluded, this is
GPL-3.0 code, so it is **not vendorable** into the BSD-3-Clause chez-http-server repo; only
usable by reference (reading it for ideas, reimplementing facts/test-case shapes from
scratch). This matches the finder's own Tier-3 "reference only... do NOT vendor" framing —
not a refutation, a confirmation of the same conclusion.

Commands:
```
gh api repos/regilero/HTTPWookiee --jq '{full_name, license: .license.spdx_id, license_name: .license.name, default_branch, pushed_at, archived}'
gh api repos/regilero/HTTPWookiee/license --jq '{name, license: .license.spdx_id}'
gh api repos/regilero/HTTPWookiee/contents/httpwookiee/client/tests_chunks.py --jq '{name, path, size}'
gh api repos/regilero/HTTPWookiee/contents/httpwookiee/client/tests_first_line.py --jq '{name, path, size}'
gh api repos/regilero/HTTPWookiee/contents/httpwookiee/client/tests_host.py --jq '{name, path, size}'
gh api repos/regilero/HTTPWookiee/contents/httpwookiee/client/tests_regular.py --jq '{name, path, size}'
```

Output:
```
{"archived":false,"default_branch":"master","full_name":"regilero/HTTPWookiee","license":"GPL-3.0","license_name":"GNU General Public License v3.0","pushed_at":"2017-12-02T12:47:26Z"}
{"license":"GPL-3.0","name":"LICENSE"}
{"name":"tests_chunks.py","path":"httpwookiee/client/tests_chunks.py","size":29413}
{"name":"tests_first_line.py","path":"httpwookiee/client/tests_first_line.py","size":30299}
{"name":"tests_host.py","path":"httpwookiee/client/tests_host.py","size":8452}
{"name":"tests_regular.py","path":"httpwookiee/client/tests_regular.py","size":5958}
```

`pushed_at` = 2017-12-02, confirming the finder's "stale (2017)" note verbatim. License is a
clean GPL-3.0 autodetect on both the repo-level field and the dedicated `/license` endpoint —
no ambiguity, no NOASSERTION.

Test-method count spot-check (`grep -c "^    def test"` on each decoded file):
```
tests_chunks.py:      15
tests_first_line.py:  21
tests_host.py:        4
tests_regular.py:     5
```
This is an **exact** match to the candidate's stated `approx_cases`: "tests_chunks 15,
tests_first_line 21, tests_host 4, tests_regular 5" (total 45). Strong corroboration that the
finder actually read this repository rather than guessing.

**No corrections needed.** `refuted=false`.

---

## Summary table

| key | repo exists | license confirmed | corpus paths exist | verdict |
|---|---|---|---|---|
| defparam-smuggler | yes | MIT (clean) | 4/4 | not refuted |
| portswigger-http-request-smuggler | yes | Apache-2.0 (LICENSE text; API shows NOASSERTION, explained) | 6/6 | not refuted |
| rfc9112-framing-checklist | yes (HTTP 200) | IETF Trust/BCP 78, reference-only (no vendoring, as finder states) | n/a (no paths claimed) | not refuted |
| slowhttptest | yes | Apache-2.0 (clean) | 4/4 | not refuted |
| haproxy-vtc-reg-tests | yes | GPL-2.0 + LGPL headers + OpenSSL exception (LICENSE text; API shows NOASSERTION, explained) | 5/5 | not refuted |
| regilero-httpwookiee | yes | GPL-3.0 (clean), confirmed stale (2017) | 4/4 | not refuted |

No candidate in this batch was refuted on existence or license grounds. Two candidates
(PortSwigger, haproxy) show `NOASSERTION` in GitHub's auto-detected repo `license` API field,
which I flag for the record, but in both cases the actual `LICENSE` file text was fetched and
unambiguously confirms the SPDX identifier the finder already reported, and in both cases the
finder's own `notes` field had already surfaced and explained the NOASSERTION quirk — so this
is treated as corroboration, not correction.
