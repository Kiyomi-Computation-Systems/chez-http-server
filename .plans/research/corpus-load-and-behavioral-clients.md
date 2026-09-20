# Corpus survey — lens: load, benchmark and behavioral clients

Date measured: 2026-09-19, on the macOS arm64 machine described in the task (Chez 10.4.1, Homebrew 7.0.4, curl 8.7.1 system binary, ab 2.3 system binary, Node via asdf, python3 3.14.5).

Scope: material usable either as a *test driver* (a load generator or scripted client we point at a port) or as a *behavioral spec* (checks a client makes on our responses, or byte streams a client is known to send). For every candidate below I record: the real URL (confirmed by a successful `git clone` and by `gh api repos/<owner>/<repo>`), the license (read from the cloned LICENSE/COPYING file and cross-checked against the GitHub SPDX field and the Homebrew formula's license field), the repo-relative paths of any test data, an approximate case count (measured with `find`/`rg`/a short Python script), how each fits our three test modes, and a tier.

Test modes referenced throughout:

- **(a)** in-process over loopback TCP, driving our server with chez-libuv's own client verbs;
- **(b)** black-box from an external client process against a port;
- **(c)** sans-I/O connection driver replaying recorded byte streams at every chunk size (the way chez-httparse replays the llhttp fixtures).

Every clone lives under `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/repos/<name>` (abbreviated `$REPOS/<name>` below). Nothing was written into any git repository.

---

## 0. Method and raw evidence

### 0.1 Clones (command and verbatim output)

```
S=/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad
clone() { name=$1; url=$2; shift 2; if [ $# -gt 0 ]; then git clone -q --depth 1 --filter=blob:none --sparse "$url" "$S/repos/$name" && git -C "$S/repos/$name" sparse-checkout set "$@" ; else git clone -q --depth 1 "$url" "$S/repos/$name"; fi; echo "== $name: $(git -C $S/repos/$name log -1 --format='%H %cd')"; }
clone tfb https://github.com/TechEmpower/FrameworkBenchmarks.git toolset
clone wrk https://github.com/wg/wrk.git
clone wrk2 https://github.com/giltene/wrk2.git
clone oha https://github.com/hatoo/oha.git
clone bombardier https://github.com/codesenberg/bombardier.git
clone nghttp2 https://github.com/nghttp2/nghttp2.git src doc integration-tests
clone siege https://github.com/JoeDog/siege.git
clone autocannon https://github.com/mcollina/autocannon.git
clone hey https://github.com/rakyll/hey.git
clone curl https://github.com/curl/curl.git tests/data tests/http tests/server docs/tests
clone hurl https://github.com/Orange-OpenSource/hurl.git integration docs
clone httpbin https://github.com/postmanlabs/httpbin.git
clone go-httpbin https://github.com/mccutchen/go-httpbin.git
clone httpd https://github.com/apache/httpd.git support
```

Output (HEAD commit and date of each clone):

```
== tfb: 57d92fbec6f8fd7431bc77326dd0484e60c96e20 Mon Mar 23 21:28:51 2026 +0000
== wrk: a211dd5a7050b1f9e8a9870b95513060e72ac4a0 Sun Feb 7 16:13:05 2021 +0900
== wrk2: 44a94c17d8e6a0bac8559b53da76848e430cb7a7 Mon Sep 23 21:46:42 2019 -0700
== oha: 0d6d370ed37108385d79a4ce34c0b8a8d7c9b6fe Thu Sep 10 13:43:05 2026 +0900
== bombardier: 2d495aca5b233bec0a5334dc4aa3cbdaef6e1bc5 Tue Mar 4 17:40:20 2025 +0000
== nghttp2: 140157a8d751e9e8b0cc15bf9bc0e2ee0c1ed987 Sun Sep 13 16:23:51 2026 +0900
== siege: c87356f7a8b04a7b07fd0f1bb84ae218b550f679 Tue Aug 18 15:00:39 2026 -0400
== autocannon: 9d645c3ba48bade008f1785991b2c660e0be3b15 Sat May 16 09:48:47 2026 +0200
== hey: 5626f79b8698df6daf9b25799c9805c6acc96740 Sat Jan 10 12:54:37 2026 -0800
== curl: a40991b97c0ce721e85acbe16e16fe79b7b68c51 Sat Sep 19 10:41:09 2026 +0200
== hurl: 4fe6150376045c15e3fe6bf6816c5015996fb925 Sat Sep 19 03:04:40 2026 +0000
== httpbin: f8ec666b4d1b654e4ff6aedd356f510dcac09f83 Wed Nov 7 15:31:50 2018 -0500
== go-httpbin: 34888fd21d6667e9f0c842db483ba595b9c8c094 Fri Sep 18 20:35:07 2026 +0000
== httpd: 7b93fd7027accbd3d2bfe9d482b5fd31ab4397db Thu Sep 17 21:17:38 2026 +0000
```

Later, `git -C $REPOS/curl sparse-checkout add tests/FILEFORMAT.md tests/README.md tests/runtests.pl tests/http/README.md` (only `tests/runtests.pl` existed; the format doc is at `docs/tests/FILEFORMAT.md`, found with `find $REPOS/curl -iname 'FILEFORMAT*'`).

### 0.2 GitHub API confirmation (license SPDX id, archived, last push, stars, default branch)

```
for r in TechEmpower/FrameworkBenchmarks wg/wrk giltene/wrk2 hatoo/oha codesenberg/bombardier nghttp2/nghttp2 JoeDog/siege mcollina/autocannon rakyll/hey curl/curl Orange-OpenSource/hurl postmanlabs/httpbin psf/httpbin mccutchen/go-httpbin apache/httpd shekyan/slowhttptest; do gh api "repos/$r" --jq '[.full_name, .license.spdx_id, .archived, .pushed_at, .stargazers_count, .default_branch] | @tsv'; done
```

```
TechEmpower/FrameworkBenchmarks	NOASSERTION	true	2026-03-24T01:39:18Z	8102	master
wg/wrk	NOASSERTION	false	2023-12-30T10:33:51Z	40406	master
giltene/wrk2	Apache-2.0	false	2024-03-03T13:40:01Z	4631	master
hatoo/oha	MIT	false	2026-09-10T04:43:05Z	10552	master
codesenberg/bombardier	MIT	false	2026-08-25T22:40:58Z	6837	master
nghttp2/nghttp2	NOASSERTION	false	2026-09-14T14:13:03Z	5052	master
JoeDog/siege	GPL-3.0	false	2026-08-18T19:18:13Z	6213	master
mcollina/autocannon	MIT	false	2026-05-16T07:48:53Z	8519	master
rakyll/hey	Apache-2.0	false	2026-01-10T20:54:51Z	20268	master
curl/curl	NOASSERTION	false	2026-09-19T08:42:35Z	42888	master
Orange-OpenSource/hurl	Apache-2.0	false	2026-09-19T05:50:04Z	19208	master
postmanlabs/httpbin	ISC	false	2024-05-24T07:51:48Z	13623	master
psf/httpbin	NOASSERTION	false	2026-06-16T21:39:46Z	83	main
mccutchen/go-httpbin	MIT	false	2026-09-18T20:35:08Z	885	main
apache/httpd	Apache-2.0	false	2026-09-19T00:10:02Z	4035	trunk
shekyan/slowhttptest	Apache-2.0	false	2026-09-16T19:24:04Z	1651	master
```

Note: **TechEmpower/FrameworkBenchmarks reports `archived: true`** (last push 2026-03-24). The corpus is still fetchable and BSD-licensed, but it will not move; vendoring is therefore the right relationship with it anyway.

### 0.3 Local tool inventory

```
for t in wrk wrk2 oha bombardier h2load ab siege autocannon hey curl hurl httpbin gtimeout timeout node python3 brew; do printf '%-12s ' "$t"; command -v "$t" || echo "(not found)"; done
```

```
wrk          (not found)
wrk2         (not found)
oha          (not found)
bombardier   (not found)
h2load       (not found)
ab           /usr/sbin/ab
siege        (not found)
autocannon   (not found)
hey          (not found)
curl         /usr/bin/curl
hurl         (not found)
httpbin      (not found)
gtimeout     /opt/homebrew/bin/gtimeout
timeout      /opt/homebrew/bin/timeout
node         /Users/yuzu/.asdf/shims/node
python3      /opt/homebrew/bin/python3
brew         /opt/homebrew/bin/brew
```

```
curl --version | head -2
curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1
Release-Date: 2024-03-27
ab -V
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
gh version 2.97.0 (2026-07-31); logged in to github.com as DarrenN
```

### 0.4 Homebrew formula metadata (macOS)

Command: `brew info --json=v2 <formula>` for each, printing `name | stable version | license | homepage | desc`.

```
wrk | 4.2.0 | LicenseRef-Homebrew-cannot-represent | https://github.com/wg/wrk | HTTP benchmarking tool
oha | 1.16.0 | MIT | https://github.com/hatoo/oha/ | HTTP load generator, inspired by rakyll/hey with tui animation
bombardier | 2.0.2 | MIT | https://github.com/codesenberg/bombardier | Cross-platform HTTP benchmarking tool
nghttp2 | 1.70.0 | MIT | https://nghttp2.org/ | HTTP/2 C Library
siege | 4.2.0 | GPL-3.0-or-later | https://www.joedog.org/siege | HTTP regression testing and benchmarking utility
hey | 0.1.5 | Apache-2.0 | https://github.com/rakyll/hey | HTTP load generator, ApacheBench (ab) replacement
hurl | 8.0.1 | Apache-2.0 | https://hurl.dev | Run and Test HTTP Requests with plain text and curl
go-httpbin | NO FORMULA
vegeta | 12.13.0 | MIT | https://github.com/tsenart/vegeta | HTTP load testing tool and library
k6 | 2.2.0 | AGPL-3.0-or-later | https://k6.io | Modern load testing tool, using Go and JavaScript
httpd | 2.4.68 | Apache-2.0 | https://httpd.apache.org/ | Apache HTTP server
curl | 8.22.0 | curl | https://curl.se | Get a file from an HTTP, HTTPS or FTP server
slowhttptest | 1.10.0 | Apache-2.0 | https://github.com/shekyan/slowhttptest | Simulates application layer denial of service attacks
```

```
brew info wrk2       -> Error: No available formula with the name "wrk2". Did you mean wrk?
brew search httpbin  -> httping, httpie   (no go-httpbin / httpbin formula)
```

Homebrew nghttp2 formula (fetched from https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/n/nghttp2.rb): url `https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz`; configure args include `--enable-app` (so `h2load`, `nghttp`, `nghttpd`, `nghttpx` are built); the formula's test block runs `nghttp`.

### 0.5 Ubuntu 24.04 (noble) apt availability (packages.ubuntu.com, fetched 2026-09-19)

| Package | Result |
|---|---|
| https://packages.ubuntu.com/noble/wrk | `wrk 4.1.0-4build2`, section universe, "HTTP benchmarking tool" |
| https://packages.ubuntu.com/search?keywords=wrk2&searchon=names&exact=1&suite=noble&section=all | none found |
| https://packages.ubuntu.com/noble/siege | `siege 4.0.7-1build5`, section web |
| https://packages.ubuntu.com/noble/apache2-utils | `apache2-utils 2.4.58-1ubuntu8.15`; file list https://packages.ubuntu.com/noble/amd64/apache2-utils/filelist confirms `/usr/bin/ab` |
| https://packages.ubuntu.com/noble/nghttp2-client | `nghttp2-client 1.59.0-1ubuntu0.4`; file list https://packages.ubuntu.com/noble/amd64/nghttp2-client/filelist confirms `/usr/bin/h2load` and `/usr/bin/nghttp` |
| https://packages.ubuntu.com/search?keywords=hey&searchon=names&exact=1&suite=noble&section=all | `hey 0.1.4-2ubuntu0.24.04.3` (amd64) / `0.1.4-2build1` (arm64 etc.), universe, "Sends some load to a web application" |
| https://packages.ubuntu.com/search?keywords=hurl&searchon=names&exact=1&suite=noble&section=all | none found (install via release `.deb` or PPA, see §4) |
| https://packages.ubuntu.com/search?keywords=oha&searchon=names&exact=1&suite=noble&section=all | none found (29 substring matches, no exact) |
| https://packages.ubuntu.com/search?keywords=bombardier&searchon=names&exact=1&suite=noble&section=all | **name clash**: `bombardier 0.8.3+nmu3`, section games, "The GNU Bombing utility" — NOT the load tool |
| https://packages.ubuntu.com/noble/python3-httpbin | `python3-httpbin 0.10.2+dfsg-1` (this is the psf fork's version line) |
| https://packages.ubuntu.com/noble/slowhttptest | `slowhttptest 1.9.0-1build2`, universe |

autocannon is npm-only: `curl -s https://registry.npmjs.org/autocannon` → `{'latest': '8.0.0'} MIT git+https://github.com/mcollina/autocannon.git`.

### 0.6 Release binaries for tools not in apt

```
gh api repos/<r>/releases/latest --jq '.tag_name + "  " + ([.assets[].name] | join(", "))'
Orange-OpenSource/hurl  8.0.1  ... hurl-8.0.1-aarch64-apple-darwin.tar.gz, hurl-8.0.1-aarch64-unknown-linux-gnu.tar.gz, hurl-8.0.1-x86_64-unknown-linux-gnu.tar.gz, hurl_8.0.1_amd64.deb, hurl_8.0.1_...
hatoo/oha               v1.16.0  oha-linux-amd64, oha-linux-amd64-pgo, oha-linux-arm64, oha-macos-amd64, oha-macos-arm64, oha-windows-amd64-pgo.exe, oha-windows-amd64.exe
codesenberg/bombardier  v2.0.2  bombardier-darwin-amd64, bombardier-darwin-arm64, bombardier-linux-amd64, bombardier-linux-arm64, ... (19 assets incl. *bsd, windows)
mccutchen/go-httpbin    v2.25.0  go-httpbin-darwin-all.tar.gz, go-httpbin-linux-amd64.tar.gz, go-httpbin-linux-arm64.tar.gz, go-httpbin-windows-*.zip, checksums.txt, sbom.json files
rakyll/hey              v0.1.5  (no assets)
shekyan/slowhttptest    v1.10.0 (no assets)
```

---

## 1. Summary table

| # | Finding | License | brew (macOS) | apt (Ubuntu noble) | Black-box vs port? | Fits | Tier |
|---|---|---|---|---|---|---|---|
| 1 | TechEmpower toolset verifications | BSD-3-Clause | n/a (Python + wrk) | wrk 4.1.0 | yes (its own runner; we port checks) | a, b, c | **1** |
| 2 | curl test-suite `<protocol>` request corpus | curl (MIT-like) | n/a (data) | n/a (data) | n/a (data) | c, a | **1** |
| 3 | curl CLI as conformance client (+ `tests/http` scenario catalogue) | curl | system curl 8.7.1; brew 8.22.0 | curl | yes | b | 2 |
| 4 | hurl scripted HTTP tests + Flask reference routes | Apache-2.0 | 8.0.1 | release .deb / PPA | yes | b | 2 |
| 5 | wrk (+ wrk2) | Modified Apache-2.0 (wrk); Apache-2.0 (wrk2) | wrk 4.2.0; no wrk2 | wrk 4.1.0; no wrk2 | yes | b | 2 (wrk2: 3) |
| 6 | autocannon | MIT | npm 8.0.0 (Node 20 present) | npm | yes | b | 2 |
| 7 | oha (hey as apt fallback) | MIT (oha), Apache-2.0 (hey) | oha 1.16.0, hey 0.1.5 | hey 0.1.4; oha via release binary | yes | b | 2 |
| 8 | bombardier | MIT | 2.0.2 | release binary (apt name is a game) | yes | b | 2 |
| 9 | h2load in HTTP/1.1 mode | MIT (nghttp2) | nghttp2 1.70.0 (`--enable-app`) | nghttp2-client 1.59.0 | yes | b | 2 |
| 10 | ab (ApacheBench) | Apache-2.0 | ships with macOS (`/usr/sbin/ab` 2.3); brew httpd | apache2-utils 2.4.58 | yes | b | 2 |
| 11 | siege | GPL-3.0-or-later | 4.2.0 | 4.0.7 | yes | b | 3 |
| 12 | go-httpbin (and postmanlabs/httpbin) as app-layer reference | MIT (go-httpbin), ISC (httpbin) | none (release tarball / `go install` / Docker) | python3-httpbin 0.10.2 | yes (reference server) | b | 2 |
| 13 | slowhttptest | Apache-2.0 | 1.10.0 | 1.9.0 | yes | b | 2 |

Considered, not listed as findings: **vegeta** (MIT, brew 12.13.0; a fine constant-rate generator but adds nothing over oha for our needs), **k6** (AGPL-3.0-or-later per Homebrew; usable as an external tool but not vendorable, and its JS scripting is heavier than hurl), **psf/httpbin** (fork of httpbin, latest 0.10.4; it is what `python3-httpbin` packages — covered under finding 12).

---

## 2. Findings in detail

### Finding 1 — TechEmpower FrameworkBenchmarks: toolset verification code (tier 1, layer: spec)

- URL: https://github.com/TechEmpower/FrameworkBenchmarks (clone HEAD `57d92fbec6f8fd7431bc77326dd0484e60c96e20`, 2026-03-23; GitHub reports **archived: true**, last push 2026-03-24, 8102 stars).
- License: BSD-3-Clause. `$REPOS/tfb/LICENSE` reads "Copyright (c) 2021, TechEmpower, Inc. All rights reserved. Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:" followed by the three standard BSD clauses (retain notice; reproduce notice in binary form; no endorsement using the TechEmpower name). GitHub's SPDX field says NOASSERTION because the file lacks the SPDX header; the text is verbatim BSD-3-Clause.
- Paths (measured with `find $REPOS/tfb/toolset/test_types -type f`; note the task brief's guess `toolset/benchmark/test_types` is wrong — that directory does not exist in the current tree):

```
toolset/test_types/__init__.py
toolset/test_types/abstract_test_type.py
toolset/test_types/cached-query/cached-query.py
toolset/test_types/db/db.py
toolset/test_types/fortune/__init__.py
toolset/test_types/fortune/fortune.py
toolset/test_types/fortune/fortune_html_parser.py
toolset/test_types/json/json.py
toolset/test_types/plaintext/plaintext.py
toolset/test_types/query/query.py
toolset/test_types/update/update.py
toolset/test_types/verifications.py
toolset/wrk/concurrency.sh
toolset/wrk/pipeline.lua
toolset/wrk/pipeline.sh
toolset/wrk/query.sh
toolset/wrk/wrk.dockerfile
```

  Sizes (`wc -l`): verifications.py 489, plaintext.py 81, json.py 69, abstract_test_type.py 134.
- Case count: 7 test types × one `verify()` each; the reusable behavioral rules are ~10 functions in `verifications.py` (`rg -n '^def ' verifications.py`: `basic_body_verification`:15, `verify_status`:44, `verify_headers`:60, `verify_helloworld_object`:122, `verify_randomnumber_object`:160, `verify_randomnumber_list`:229, `verify_updates`:283, `verify_query_cases`:329, `verify_queries_count`:420, `display_queries_count_result`:472). Only the first four and the plaintext/json types matter to us (the rest need a database).
- What it specifies (this is the de-facto behavioral spec for "a minimal correct HTTP/1.1 response"), verbatim from `toolset/test_types/verifications.py`:
  - lines 68–71: `for v in (v for v in ('Server', 'Date', 'Content-Type') if v.lower() not in headers): problems.append(('fail', 'Required response header missing: %s' % v, url))`
  - lines 73–78: `if all(v.lower() not in headers for v in ('Content-Length', 'Transfer-Encoding')): problems.append(('fail', 'Required response size header missing, please include either "Content-Length" or "Transfer-Encoding"', url))`
  - lines 80–89: Date must parse with `'%a, %d %b %Y %H:%M:%S %Z'` (IMF-fixdate) — a `warn` otherwise.
  - lines 91–102: `sleep(3)` then a second request; `if date == date2: problems.append(('fail', 'Invalid Cached Date. ...'))` — the Date header must change between two requests 3 s apart (no stale cached Date).
  - lines 104–117: Content-Type must match `'^text/plain(; ?charset=(UTF|utf)-8)?$'` for plaintext, `'^application/json(; ?charset=(UTF|utf)-8)?$'` for json, `'^text/html; ?charset=(UTF|utf)-8$'` for fortunes.
  - lines 44–57 `verify_status`: status must be exactly 200.
  - lines 15–41 `basic_body_verification`: body non-empty; for json types must `json.loads`.
  - lines 122–158 `verify_helloworld_object`: JSON object with single key `message` == `hello, world!` (case-insensitive); more than one key is a warn.
  - `plaintext.py` lines 34–45: body lower-cased must contain `b"hello, world!"`; any extra bytes produce a `warn` "Server is returning N more bytes than are required"; lines 70–81 `get_script_variables`: `'pipeline': 16` and `'accept': "text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7"`.
  - `abstract_test_type.py` lines 68–81: verification requests are issued with Python `requests.get(url, timeout=15, headers={'Accept': ...})` — i.e. an HTTP/1.1 keep-alive-capable client (urllib3) sending only Accept plus its defaults.
  - `toolset/run-tests.py` lines 182–190: defaults `--concurrency-levels [16, 32, 64, 128, 256, 512]`, `--pipeline-concurrency-levels [256, 1024, 4096, 16384]`, `--duration 15`.
- Load driver it prescribes (`toolset/wrk/*.sh`, verbatim shapes):
  - `wrk -H "Host: $server_host" -H "Accept: $accept" -H "Connection: keep-alive" --latency -d 5 -c 8 --timeout 8 -t 8 $url` (primer), then a warm-up at max concurrency, then each level with `-t min(c, nproc)`.
  - `pipeline.sh` adds `-s pipeline.lua -- 16` for plaintext; `toolset/wrk/pipeline.lua` is 12 lines: `init` concatenates `depth` copies of `wrk.format()` into one request buffer and `request()` returns it — i.e. 16 pipelined GETs per write.
  - `wrk.dockerfile`: `FROM ubuntu:24.04` + `apt-get install ... curl wrk` — TFB itself uses the Ubuntu-packaged wrk 4.1.0, which is exactly what our Linux CI would get.
- Fits: **(a)** — port `verify_headers`/`verify_status`/`verify_helloworld_object`/plaintext body rules to a Scheme predicate over a parsed response and run it in-process against our loopback server; **(b)** — run their wrk scripts verbatim against our port (and, for the true ranking harness, their Python runner); **(c)** — the same Scheme oracle can check the bytes our serializer emits in a sans-I/O test (Date format, Content-Length/Transfer-Encoding presence, Content-Type regexes), independent of sockets.
- Adaptation effort: low. Vendor the 12 `toolset/test_types` + `toolset/wrk` files (~0.9 kLOC of Python/Lua/sh) plus `LICENSE` under `test/vendor/tfb/` with a `PROVENANCE` file recording the commit `57d92fbec6f8fd7431bc77326dd0484e60c96e20`; write `verify.sls` mirroring the four verification rules. The wrk shell scripts run unchanged once `name/url/accept/levels/duration/server_host` are exported.
- Notes: repository is archived, so this is a snapshot with no upstream drift to track. The "Date must change after 3 s" rule is a good regression test for a cached-Date optimisation (many servers cache the formatted date per second).

### Finding 2 — curl test suite `<protocol>` blocks: recorded client request byte streams (tier 1, layer: connection)

- URL: https://github.com/curl/curl (clone HEAD `a40991b97c0ce721e85acbe16e16fe79b7b68c51`, 2026-09-19; 42888 stars).
- License: curl license (SPDX `curl`; MIT/X-derivative). `$REPOS/curl/COPYING`: "Copyright (c) 1996 - 2026, Daniel Stenberg, <daniel@haxx.se>, and many contributors ... Permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies." Homebrew records the formula license as `curl`.
- Paths: `tests/data/test<N>` (one XML-ish file per test), format documented in `docs/tests/FILEFORMAT.md`. Mock server used upstream: `tests/server/sws.c` (not needed by us).
- Counts (`ls $REPOS/curl/tests/data | wc -l` → 2139 entries; `ls tests/data/test* | wc -l` → 2109 test files). Measured with a Python pass over every file (script in §5.1):

```
HTTP-keyword tests: 1084   with <protocol> verify: 959   >=2 requests in one protocol block: 312
Expect:100-continue in protocol: 24   chunked upload in protocol: 21
```

  (`rg -l 'Expect: 100-continue' tests/data/test*` → 25 files; `rg -l -i 'Transfer-Encoding: chunked'` → 60 files — the latter includes server-side `<data>` responses, hence the smaller "in protocol" number.)
- What a case looks like — `tests/data/test1` verbatim:

```
<?xml version="1.0" encoding="US-ASCII"?>
<testcase>
<info>
<keywords>
HTTP
HTTP GET
</keywords>
</info>

# Server-side
<reply>
<data crlf="headers">
HTTP/1.1 200 OK
Date: Tue, 09 Nov 2010 14:49:00 GMT
Server: test-server/fake
Last-Modified: Tue, 13 Jun 2000 12:10:00 GMT
ETag: "21025-dc7-39462498"
Accept-Ranges: bytes
Content-Length: 6
Connection: something-close, close-something, close
Content-Type: text/html
Funny-head: yesyes

-foo-
</data>
</reply>

# Client-side
<client>
<server>
http
</server>
<name>
HTTP GET
</name>
<command>
http://%HOSTIP:%HTTPPORT/%TESTNUMBER
</command>
</client>

# Verify data after the test has been "shot"
<verify>
<protocol crlf="headers">
GET /%TESTNUMBER HTTP/1.1
Host: %HOSTIP:%HTTPPORT
User-Agent: curl/%VERSION
Accept: */*

</protocol>
<limits>
Allocations: 140
Maximum allocated: 136000
</limits>
</verify>
</testcase>
```

  And `tests/data/test1070` (an Expect: 100-continue POST where the server answers 403 and closes before the body is fully sent): `<command>-d @%LOGDIR/input%TESTNUMBER http://%HOSTIP:%HTTPPORT/%TESTNUMBER -H "Expect: 100-continue"</command>`, with `<protocol crlf="yes" nonewline="yes">` recording `POST /%TESTNUMBER HTTP/1.1 / Host: ... / User-Agent: curl/%VERSION / Accept: */* / Expect: 100-continue / Content-Length: 2313 / Content-Type: application/x-www-form-urlencoded / <blank> / This creates%SP` — i.e. the exact bytes curl puts on the wire, truncated where the server closed.
- Semantics of the block, `docs/tests/FILEFORMAT.md` lines 696–708: "`<protocol [nonewline="yes"][crlf="yes|headers"]>` the protocol dump curl should transmit, if `nonewline` is set, we cut off the trailing newline of this given data before comparing with the one actually sent by the client. The `<strip>` and `<strippart>` rules are applied before comparisons are made. `crlf=yes` forces the newlines to become CRLF ... `crlf=headers` forces *header* newlines to become CRLF ... runtests.pl parse and 'guess' what is a header and what is not". Variables (`%HOSTIP`, `%HTTPPORT`, `%TESTNUMBER`, `%VERSION`, `%SP`, `%repeat[...]%`) are described under "# Variables" (line 151) and "# Preprocessing" (line 22).
- Fits: **(c)** first and foremost — each `<protocol>` block is a real, complete client request stream (312 of them contain two or more requests on one connection, so they double as keep-alive/pipelining fixtures; 24 carry `Expect: 100-continue`; 21 are chunked uploads). Replay them into the sans-I/O connection driver at every chunk size and assert on the request events and on whether the connection stays open. **(a)** — the same bytes can be pushed through a chez-libuv loopback client. Not (b): curl itself is the client there (finding 3).
- Adaptation effort: medium-low. Write a small extractor (Python or Scheme) that: selects files whose `<keywords>` contain the line `HTTP`, takes `<verify><protocol>`, substitutes the variables with fixed values, applies `crlf=`/`nonewline=` per the doc, and emits `{name, bytes, expected-request-count, keywords}`. The server-side `<reply><data>` block is *not* our spec (it is what curl's fake server sent) but it tells the extractor how the exchange was supposed to end (e.g. `Connection: close`, `swsclose`, `skip:` server commands at FILEFORMAT.md line 395 "For HTTP/HTTPS").
- Notes: vendor only the extracted subset (roughly 959 protocol blocks), with `PROVENANCE` naming commit `a40991b97c0ce721e85acbe16e16fe79b7b68c51` and the extractor's exact filter. curl's mock server (`tests/server/sws.c`) is "lenient" by design, so do not treat curl's *expected server replies* as normative.

### Finding 3 — curl CLI as a black-box conformance client, with `tests/http` as the scenario catalogue (tier 2, layer: connection)

- URL: https://github.com/curl/curl (same clone); local binary `/usr/bin/curl` 8.7.1 (SecureTransport, nghttp2 1.68.1); Homebrew `curl 8.22.0`; Ubuntu `curl` (always present).
- License: curl (as above).
- Paths: `tests/http/test_*.py` (pytest suite driving real curl against Apache httpd + nghttpx + caddy). `rg -c '^    def test_' tests/http/test_*.py` summed → **345** test functions across 31 files (`test_01_basic.py` … `test_60_h3_proxy.py`).
- Directly relevant scenarios (names verbatim, file:line):
  - `tests/http/test_07_upload.py`: `:53 test_07_01_upload_1_small`, `:65 test_07_02_upload_1_large`, `:78 test_07_10_upload_sequential`, `:92 test_07_11_upload_parallel`, `:244 test_07_30_put_100k`, `:261 test_07_31_put_10m`, `:483/:501/:514 test_07_42a/b/c_upload_disconnect`, `:526 test_07_43_upload_denied`, `:561 test_07_50_put_speed_limit`, `:595 test_07_60_upload_exp100`, `:608 test_07_61_upload_exp100_timeout`, `:639 test_07_63_upload_exp100_paused`, `:355 test_07_35_h1_h2_upgrade_upload`.
  - `tests/http/test_12_reuse.py`: `:38 test_12_01_h1_conn_close`, `:57 test_12_02_h1_conn_timeout`, `:76 test_12_03_no_reuse_after_partial`, `:98 test_12_04_reuse_different_basic_credentials`, `:116 test_12_05_no_reuse_different_host`, `:129 test_12_06_reuse_same_host`.
  - `tests/http/test_04_stuttered.py`: `:40 test_04_01_download_1`, `:53 test_04_02_100_100_10`, `:73 test_04_03_1000_10_1`, `:93 test_04_04_1000_10_1` (server-side stuttered/slow responses).
- Which curl behaviours exercise what (from the recorded `<protocol>` blocks and the scenario names): `-d @file` / `-T file` with a body larger than ~1 KiB sends `Expect: 100-continue` and waits (default 1 s) for `100 Continue` before the body (test1070, test_07_60/61/63); `-H "Transfer-Encoding: chunked"` or `-T -` from stdin without a size sends a chunked upload (21 recorded streams); multiple URLs on one command line reuse the connection (312 recorded multi-request streams; test_12_06); `--http1.0` sends `HTTP/1.0` (no keep-alive unless the server adds it); `-I`/`--head` for HEAD; `--limit-rate` for slow uploads/downloads (test_07_50/51).
- Fits: **(b)** only — a stock, ubiquitous, RFC-strict client. Also the natural tool for the "differential black-box" idea in finding 12.
- Adaptation effort: low for the CLI (shell tests invoking curl with `-v --trace-ascii` and asserting on exit codes/headers); high to reuse the pytest suite itself (it needs httpd/nghttpx fixtures and tests *curl*, not the server). Use `tests/http/test_07_upload.py` and `test_12_reuse.py` as a checklist of scenarios to reproduce with plain curl commands.
- Notes: macOS system curl is 8.7.1 with SecureTransport; brew curl 8.22.0 is much newer. Pin the version in CI output so `User-Agent` and default-behaviour differences (e.g. Expect threshold) are explainable.

### Finding 4 — Orange-OpenSource/hurl: scripted HTTP test files plus the Flask routes that define expected server behaviour (tier 2, layer: server)

- URL: https://github.com/Orange-OpenSource/hurl (clone HEAD `4fe6150376045c15e3fe6bf6816c5015996fb925`, 2026-09-19; 19208 stars). Homebrew `hurl 8.0.1` (Apache-2.0). Latest release `8.0.1` ships `hurl_8.0.1_amd64.deb`, `hurl-8.0.1-aarch64-unknown-linux-gnu.tar.gz`, `hurl-8.0.1-x86_64-unknown-linux-gnu.tar.gz`, `hurl-8.0.1-aarch64-apple-darwin.tar.gz`, `hurl-8.0.1-x86_64-apple-darwin.tar.gz`.
- License: Apache-2.0 (`$REPOS/hurl/LICENSE` is the stock Apache License 2.0; GitHub SPDX Apache-2.0).
- Install on Linux CI, `docs/installation.md` lines 16–31: "For Debian >=12 / Ubuntu 22.04 and 24.04, Hurl can be installed using a binary .deb file provided in each Hurl release" (`curl --location --remote-name https://github.com/Orange-OpenSource/hurl/releases/download/$VERSION/hurl_${VERSION}_amd64.deb && sudo apt install ./hurl_...deb`) or `ppa:lepapareil/hurl`; line 64–67 `brew install hurl`; line 117 `cargo install --locked hurl`. Not in Ubuntu's own archive (§0.5).
- Paths and counts (measured):

```
integration/hurl/tests_ok/            101 directories; 182 .hurl files; 108 .py route files
integration/hurl/tests_failed/        88 .hurl
integration/hurl/tests_error_parser/  49 .hurl
integration/hurl/tests_ssl/           15 .hurl
all .hurl under integration/          400
integration/hurl/app.py, server.py    Flask app + waitress runner on 127.0.0.1:8000
```

  `integration/hurl/app.py` lines 10–22: `load_tests()` imports every `tests_*/**/*.py` and an `after_request` hook sets `response.headers["Server"] = "Flask Server"`; `server.py` lines 12–17: `--host 127.0.0.1 --port 8000`, `serve(app, host=..., port=..., threads=4)`.
- Example pair, `integration/hurl/tests_ok/head/head.hurl` + `head.py` (verbatim):

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
from app import app

@app.route("/head")
def head():
    return "Hello Head"
```

  Server-behaviour-relevant directories under `tests_ok/` (from `ls`): `add_header bytes compressed connect_to cookie delay expect follow_redirect get_large head header http_version insecure ipv6 max_redirect method no_cookie_store no_header override_header patch post put rawbytes redirect resolve retry verbose very_verbose`. `docs/manual.md` lines 171–172 document `-0, --http1.0` and `--http1.1`.
- Fits: **(b)**. Two ways: (i) adopt the `.hurl` format for *our own* black-box suite (one file per scenario; `hurl --test` gives a runner, retries, captures, and JSON reports); (ii) port a handful of the tiny Flask routes (`head`, `get_large`, `http_version`, `expect`, `delay`, `redirect`, `method`, `header`, `compressed`) into our example app and run the corresponding upstream `.hurl` files verbatim, which turns them into a behavioral spec for us.
- Adaptation effort: low for (i), low-medium for (ii) (each route is 3–10 lines of Python; the `.hurl` expects `Server: Flask Server`, which we would either replicate or strip with a small sed in the vendoring script).
- Notes: hurl's own runner proves the *client* works; the value for us is the readable assertion language and the ready-made scenario list. Every `.hurl` here targets `localhost:8000`, so port parametrisation is a `--variable` or a one-line rewrite.

### Finding 5 — wrk (with wrk2 noted) (tier 2; wrk2 tier 3, layer: load)

- URL: https://github.com/wg/wrk (clone HEAD `a211dd5a7050b1f9e8a9870b95513060e72ac4a0`, 2021-02-07 = the 4.2.0 line; GitHub last push 2023-12-30; 40406 stars). wrk2: https://github.com/giltene/wrk2 (clone HEAD `44a94c17d8e6a0bac8559b53da76848e430cb7a7`, 2019-09-23; GitHub last push 2024-03-03; 4631 stars; README says it was "in experimental/development mode").
- License: **wrk uses a modified Apache 2.0**. `diff $REPOS/wrk/LICENSE $REPOS/wrk2/LICENSE` (wrk2 carries stock Apache-2.0) shows exactly one substantive addition, a clause 4(e):

```
2,3c2,4
<                           Modified Apache 2.0 License
<                          Version 2.0.1, February 2015
---
>                                  Apache License
>                            Version 2.0, January 2004
>                         http://www.apache.org/licenses/
123,128d123
<       (e) If the Derivative Work includes substantial changes to features
<           or functionality of the Work, then you must remove the name of
<           the Work, and any derivation thereof, from all copies that you
<           distribute, whether in Source or Object form, except as required
<           in copyright, patent, trademark, and attribution notices.
```

  Homebrew therefore tags it `LicenseRef-Homebrew-cannot-represent`; GitHub says NOASSERTION. No SPDX id exists. For *running* the tool this is irrelevant; for *vendoring* its Lua scripts it means keeping the modified text verbatim in `PROVENANCE`. wrk2's LICENSE is stock Apache-2.0.
- Install: brew `wrk 4.2.0`; Ubuntu `wrk 4.1.0-4build2` (universe) — the same package TFB's `wrk.dockerfile` installs. wrk2: no brew formula ("Error: No available formula with the name "wrk2""), no Ubuntu package; build from source (needs LuaJIT + OpenSSL).
- Paths: `scripts/` — 9 Lua examples, 138 lines total: `addr.lua auth.lua counter.lua delay.lua pipeline.lua post.lua report.lua setup.lua stop.lua`. `scripts/pipeline.lua` (verbatim):

```
-- example script demonstrating HTTP pipelining

init = function(args)
   local r = {}
   r[1] = wrk.format(nil, "/?foo")
   r[2] = wrk.format(nil, "/?bar")
   r[3] = wrk.format(nil, "/?baz")

   req = table.concat(r)
end

request = function()
   return req
end
```

  wrk2 ships the same set minus `delay.lua`.
- Case count: 9 example scripts; no test corpus of its own.
- Covers: sustained keep-alive load with `-c` connections and `-t` threads, pipelining depth via Lua, custom headers/bodies, latency histograms (`--latency`); wrk2 adds `-R` constant request rate with coordinated-omission-corrected latency (from the wrk2 README).
- Fits: **(b)**. This is *the* driver TFB uses, so running `toolset/wrk/pipeline.sh` unchanged gives comparable numbers.
- Adaptation effort: none for the tool; vendoring only `pipeline.lua`-style scripts is trivial (but TFB's own 12-line `pipeline.lua`, BSD-licensed, covers the same need with a cleaner license story — prefer it).
- Notes: wrk's HTTP parser is Node's old http-parser; it is tolerant, so wrk *passing* says little about conformance. Lower wrk2 to reference-only: unmaintained since 2019 and not packaged anywhere; oha gives constant-rate + latency correction and is packaged.

### Finding 6 — autocannon (tier 2, layer: load)

- URL: https://github.com/mcollina/autocannon (clone HEAD `9d645c3ba48bade008f1785991b2c660e0be3b15`, 2026-05-16; 8519 stars). npm registry: latest `8.0.0`, MIT, repository `git+https://github.com/mcollina/autocannon.git`.
- License: MIT (`$REPOS/autocannon/LICENSE`: "The MIT License (MIT) Copyright (c) 2016 Matteo Collina"; `package.json` line 3 `"version": "8.0.0"`, line 35 `"license": "MIT"`).
- Install: `npm i -g autocannon` / `npx autocannon` (Node v20.10.0 present on this machine; Node is on every CI image). No brew/apt package.
- Paths: `test/` — 40 entries, 38 `*.test.js` files, **230** `test(` invocations (`rg -c "^test\(|^\s*test\(" test/*.test.js` summed). Notable files: `pipelinedRequestsQueue.test.js`, `httpClient.test.js`, `httpRequestBuilder.test.js`, `parseHAR.test.js`, `runRate.test.js`, `runMultipart.test.js`, `workers.test.js`, `test/fixtures/`.
- Covers (README lines cited): `-c/--connections`, `-p/--pipelining NUM` (line 45), `-d/--duration` (47), `-w/--workers` (55), `--har FILE` replay (87), `-I/--idReplacement` (116), `-E/--expectBody EXPECTED` (126) which fails the run when a body mismatches, `--renderStatusCodes` (129). README line 10: "with support for HTTP pipelining and HTTPS".
- Fits: **(b)**. Its `expectBody` plus pipelining makes it the easiest tool to assert "N pipelined requests all got the right body" from outside the process; HAR replay lets a recorded browser session become a load script.
- Adaptation effort: none (tool). Its own tests are unit tests of the client; the `test/fixtures` are not server fixtures — no vendoring value.
- Notes: uses Node's `http` client semantics in a hand-rolled TCP loop (see `lib/httpClient.js`), so it is a second, differently-lenient HTTP/1.1 client to contrast with curl.

### Finding 7 — oha, with hey as the apt-installable fallback (tier 2, layer: load)

- oha URL: https://github.com/hatoo/oha (clone HEAD `0d6d370ed37108385d79a4ce34c0b8a8d7c9b6fe`, 2026-09-10; 10552 stars). `Cargo.toml` line 12 `license = "MIT"`, line 16 `version = "1.16.0"`. Homebrew `oha 1.16.0`. Not in Ubuntu; release `v1.16.0` assets `oha-linux-amd64`, `oha-linux-arm64`, `oha-macos-arm64`, ... (§0.6). `cargo install oha` also works.
- hey URL: https://github.com/rakyll/hey (clone HEAD `5626f79b8698df6daf9b25799c9805c6acc96740`, 2026-01-10; 20268 stars). `$REPOS/hey/LICENSE` = stock Apache-2.0. Homebrew `hey 0.1.5`; **Ubuntu `hey 0.1.4-2ubuntu0.24.04.3`** (universe). Release v0.1.5 has no binary assets (`go install github.com/rakyll/hey@latest`).
- Paths/counts: oha `tests/tests.rs` — 31 `#[tokio::test]` functions (`rg -c '#\[tokio::test\]|#\[test\]' tests/tests.rs` → 31), e.g. `test_setting_custom_header`:475, `test_setting_host`:570, `test_setting_method`:588, `test_http_versions`:914, `test_unix_socket`:933, `test_connect_to`:734. hey: 9 Go tests (`hey_test.go` 5, `requester/requester_test.go` 4). Neither ships server fixtures.
- Covers (oha README lines): `-z <DURATION>` (124), `--burst-delay`/`--burst-rate` (134–137), `--http-version <HTTP_VERSION>`/`--http2` (188–191), `--disable-keepalive` (198), `--connect-to` (214), `--unix-socket` (219), `-q` rate limit with `--latency-correction` (264), `--no-tui` fast mode (244). hey README: `-n`, `-c`, `-q` QPS per worker (31–34), `-z` duration (35), `-disable-keepalive` (57), `-disable-compression` (56).
- Fits: **(b)**. oha is the best single "modern" generator for us: constant rate with latency correction (replaces wrk2), keep-alive on/off, explicit HTTP version, JSON output (`-j`). hey is the one that is `apt install`-able on Ubuntu without a third-party download.
- Adaptation effort: none.
- Notes: both use hyper/net-http-style clients (Rust hyper for oha, Go net/http for hey) — strict, well-behaved HTTP/1.1 peers, which makes them good "does a mainstream client stay happy at 10k req/s" checks but poor at provoking edge cases.

### Finding 8 — bombardier (tier 2, layer: load)

- URL: https://github.com/codesenberg/bombardier (clone HEAD `2d495aca5b233bec0a5334dc4aa3cbdaef6e1bc5`, 2025-03-04; GitHub last push 2026-08-25; 6837 stars). `$REPOS/bombardier/LICENSE`: "The MIT License (MIT) Copyright (c) 2016 Максим Федосеев". Homebrew `bombardier 2.0.2` MIT. Release `v2.0.2` provides `bombardier-linux-amd64`, `bombardier-linux-arm64`, `bombardier-darwin-arm64`, etc. (19 assets).
- **apt gotcha:** Ubuntu noble's `bombardier 0.8.3+nmu3` (section games) is "The GNU Bombing utility" — an unrelated game. Never `apt install bombardier` expecting the load tool.
- Paths/counts: 14 `*_test.go` files, 66 `func Test…` (`rg '^func Test' *_test.go | wc -l` → 66); `testbody.txt`, `testserver.cert/key`, `testclient.cert/key` are client-side fixtures only.
- Covers (README verbatim): line 3 "uses excellent fasthttp instead of Go's default http library, because of its lightning fast performance"; line 5 "With bombardier v1.1 and higher you can now use net/http client if you need to test HTTP/2.x services or want to use a more RFC-compliant HTTP client"; line 21 "AFAIK, it's impossible to pass Host header correctly with fasthttp, you can use net/http (--http1/--http2 flags) to workaround this issue." So one binary offers **two clients**: fasthttp (lenient, very fast) and `--http1` (net/http, strict).
- Fits: **(b)**.
- Adaptation effort: none.
- Notes: the fasthttp/net-http switch is the interesting property — the same command run twice tells you whether a behaviour difference is a client-leniency artefact.

### Finding 9 — h2load (nghttp2) in HTTP/1.1 mode (tier 2, layer: load)

- URL: https://github.com/nghttp2/nghttp2 (clone HEAD `140157a8d751e9e8b0cc15bf9bc0e2ee0c1ed987`, 2026-09-13; 5052 stars). `$REPOS/nghttp2/COPYING`: "The MIT License Copyright (c) 2012, 2014, 2015, 2016 Tatsuhiro Tsujikawa / nghttp2 contributors". Homebrew `nghttp2 1.70.0` (MIT) built with `--enable-app` (§0.4) so `h2load` is installed; Ubuntu `nghttp2-client 1.59.0-1ubuntu0.4` ships `/usr/bin/h2load` (file list, §0.5).
- Paths: `doc/h2load.1.rst` (man page source), `doc/h2load-howto.rst.in`; `integration-tests/` contains nghttpx tests (`nghttpx_http1_test.go` etc.), not server fixtures for us.
- HTTP/1 mode, `doc/h2load.1.rst` lines 226–230 (verbatim):

```
.. option:: --h1

    Short        hand        for        :option:`--alpn-list`\=http/1.1
    :option:`--no-tls-proto`\=http/1.1,    which   effectively    force
    http/1.1 for both http and https URI.
```

  Default `--alpn-list` is `h2,http/1.1` (line 224); for plain `http://` URIs without `--h1`, h2load attempts HTTP/2 prior-knowledge (h2c), which a pure HTTP/1.1 server will reject — so `--h1` is mandatory for us.
- Covers: `-n` requests, `-c` clients, `-t` threads, `-r` rate, `--duration`, `-m` max concurrent streams (HTTP/2 only), per-request/latency stats, request bodies via `-d`.
- Fits: **(b)**; also the only listed tool that will later exercise an h2c upgrade path if one is ever added.
- Adaptation effort: none.
- Notes: two package routes exist on both platforms, making it the most CI-portable of the C-based generators.

### Finding 10 — ab (ApacheBench) (tier 2, layer: load)

- URL: https://github.com/apache/httpd, file `support/ab.c` (clone HEAD `7b93fd7027accbd3d2bfe9d482b5fd31ab4397db`, 2026-09-17). License Apache-2.0 (`$REPOS/httpd/LICENSE`; header comment in `support/ab.c` lines 5–15).
- Install: **ships with macOS** (`/usr/sbin/ab`, "ApacheBench, Version 2.3 <$Revision: 1923142 $>"); Homebrew `httpd 2.4.68`; Ubuntu `apache2-utils 2.4.58-1ubuntu8.15` provides `/usr/bin/ab` (§0.5).
- Behaviour that matters (from `support/ab.c`):
  - lines 2302 and 2312: the request line is `"%s %s HTTP/1.0\r\n"` — **ab speaks HTTP/1.0**.
  - lines 2307 and 2320: `keepalive ? "Connection: Keep-Alive\r\n" : ""` — only `-k` adds the keep-alive header.
  - line 2109: `c->keepalive = (keepalive && xstrcasestr(c->cbuff, "Keep-Alive"));` — ab reuses the connection only if the *response* headers contain the substring `Keep-Alive` (case-insensitive). A server that answers an HTTP/1.0 `Connection: Keep-Alive` request with no explicit `Connection: keep-alive` (or `Keep-Alive:` header) will see every ab connection closed after one request.
  - `ab -h` (local) lists `-k Use HTTP KeepAlive feature`, `-p postfile`, `-u putfile`, `-T content-type`, `-H header` (repeatable), `-i` HEAD, `-l` accept variable document length, `-m method`, `-r` don't exit on receive errors, `-s` per-response timeout.
- Covers: HTTP/1.0 request semantics, HTTP/1.0 keep-alive negotiation, simple POST/PUT bodies, and a sanity check that the server tolerates a 1990s client.
- Fits: **(b)** — specifically as a *conformance probe for HTTP/1.0 handling*: with `-k` it also checks that a `Content-Length` is present (ab needs one to delimit responses on a kept-alive connection, and `-l` otherwise reports length errors).
- Adaptation effort: none.
- Notes: ab is single-threaded and inaccurate as a benchmark; keep it for the HTTP/1.0 path only.

### Finding 11 — siege (tier 3, layer: load)

- URL: https://github.com/JoeDog/siege (clone HEAD `c87356f7a8b04a7b07fd0f1bb84ae218b550f679`, 2026-08-18; 6213 stars). `src/version.c` line 7: `version_string = "4.2.0"`. Homebrew `siege 4.2.0` (GPL-3.0-or-later); Ubuntu `siege 4.0.7-1build5`.
- License: **GPL-3.0-or-later** (`$REPOS/siege/COPYING` = GNU GPL v3, 29 June 2007). Tool use in CI is fine; nothing from it should be vendored into a BSD-3 repo.
- Paths: `doc/urls.txt` (URL-list format: one URL per line, optional `POST data` or `POST <file`, `$(VAR)` substitution), `doc/siegerc.in` (defaults: line 213 `protocol = HTTP/1.1`, line 268 `connection = close`, line 133 `parser = true`, line 412 `benchmark = false`), `doc/*.pod` man sources.
- Behaviour: `src/http.c` lines 155–157/316–318 pick `HTTP/1.0` vs `HTTP/1.1` from config; lines 160–162/321–323 write `keep-alive` or `close` into the `Connection: %s` header (lines 239, 398); line 485 parses a `Keep-Alive:` response header. Default `connection = close` means siege opens a fresh TCP connection per request unless `-b`/siegerc changes it — a useful "connection churn" driver.
- Fits: **(b)**.
- Adaptation effort: none; write a `urls.txt`.
- Notes: reference-only tier because of the GPL, an HTML "parser = true" default that fetches embedded assets (turn off), and older packaged versions on Ubuntu (4.0.7).

### Finding 12 — go-httpbin (and postmanlabs/httpbin) as the app-layer behavioural reference (tier 2 for go-httpbin, 3 for httpbin; layer: reference-impl)

- go-httpbin URL: https://github.com/mccutchen/go-httpbin (clone HEAD `34888fd21d6667e9f0c842db483ba595b9c8c094`, 2026-09-18; 885 stars). `$REPOS/go-httpbin/LICENSE`: "MIT License Copyright (c) 2016 Will McCutchen"; `go.mod`: `module github.com/mccutchen/go-httpbin/v2`. Install: release `v2.25.0` tarballs (`go-httpbin-darwin-all.tar.gz`, `go-httpbin-linux-amd64.tar.gz`, `go-httpbin-linux-arm64.tar.gz`), `go install github.com/mccutchen/go-httpbin/v2/cmd/go-httpbin@latest` (README line 177), Docker `ghcr.io/mccutchen/go-httpbin` (README line 22). **No Homebrew formula** (`brew search httpbin` → only httping, httpie).
- httpbin URL: https://github.com/postmanlabs/httpbin (clone HEAD `f8ec666b4d1b654e4ff6aedd356f510dcac09f83`, 2018-11-07 on master; GitHub last push 2024-05-24; 13623 stars). `$REPOS/httpbin/LICENSE`: "ISC License Copyright (c) 2017 Kenneth Reitz". `httpbin/VERSION` = 0.9.2. The maintained fork is https://github.com/psf/httpbin (latest 0.10.4; README: forked because the PSF "were unable to get ahold of the folks at postmanlabs"), and that fork is what Ubuntu packages as `python3-httpbin 0.10.2+dfsg-1`.
- Paths/counts:
  - go-httpbin: `httpbin/httpbin.go` registers **64** routes (`rg -c 'mux.HandleFunc\(' httpbin/httpbin.go` → 64): `/get /post /put /patch /delete /head /anything /headers /response-headers /status/{code} /bytes/{n} /range/{n} /stream/{n} /stream-bytes/{n} /drip /delay/{d} /gzip /deflate /brotli /trailers /sse /jsonl /redirect/{n} /absolute-redirect/{n} /relative-redirect/{n} /redirect-to /basic-auth/... /digest-auth/... /bearer /cookies /cache /etag/{etag} /unstable /upload /dump/request /websocket/echo ...`. Tests: `httpbin/handlers_test.go` has **55** `func Test…` and **150** `t.Run(` subtests (`rg -c '^func Test'` / `rg -c '^\s+t\.Run\('`), plus `helpers_test.go` (10), `httpbin_test.go` (3), `middleware_test.go` (1), `static_assets_test.go` (2).
  - httpbin: `httpbin/core.py` has 55 `@app.route` decorators; `test_httpbin.py` has 67 `def test_` functions.
- Covers: every "application layer" behaviour a server framework must get right above the connection layer: status-code echo, header echo, chunked streaming (`/stream`, `/drip` with delays, `/sse`), range requests, redirects (relative/absolute), content-encodings, auth challenges, trailers, large/slow bodies (`/delay`, `/drip`), request dumping (`/dump/request` returns the raw request — handy for checking what a client actually sent).
- Fits: **(b)** in two roles: (i) a *reference server* to diff against — run go-httpbin on one port and our app's port of the same endpoints on another, fire identical curl/hurl/oha traffic at both and compare status/headers/body; (ii) a *behavioural spec* — `handlers_test.go` subtests spell out expected status, headers and bodies for each endpoint and can be transliterated into our own black-box tests.
- Adaptation effort: medium — no bytes to vendor; the work is choosing 10–15 endpoints (`/get /post /status /headers /response-headers /bytes /stream /delay /drip /redirect /range /trailers`) to implement in our example app and writing the diff harness.
- Notes: go-httpbin is a single static binary with arm64/amd64 Linux and macOS builds, so it is trivially available in CI; the Python httpbin is `pip install httpbin` / `apt install python3-httpbin` and is a WSGI app (needs gunicorn/waitress), so prefer go-httpbin.

### Finding 13 — slowhttptest (tier 2, layer: security)

- URL: https://github.com/shekyan/slowhttptest (GitHub: Apache-2.0, last push 2026-09-16, 1651 stars, latest tag v1.10.0 with no assets). Homebrew `slowhttptest 1.10.0` (Apache-2.0); Ubuntu `slowhttptest 1.9.0-1build2` (universe); Docker `shekyan/slowhttptest:latest`.
- License: Apache-2.0 (GitHub SPDX and Homebrew agree; not cloned — tool only).
- Test modes (from the repo page): slow headers (Slowloris, `-H`), slow body (`-B`), range-header attack (`-R`), slow read (`-X`); the newer "slowhttptest-ng" adds HTTP/2 attacks.
- Fits: **(b)**. It is the only packaged client that directly exercises the architecture doc's "slow clients, timeout behaviour, disconnect during read/write, backpressure" list (§14 of `.plans/chez-http-server-architecture.md`): it holds thousands of connections open sending a header byte every N seconds (header timeout), sends a body slower than the body timeout, or reads the response slower than we write it (write-queue growth → `uv-stream-write-queue-size` congestion signal in ADR-0018).
- Adaptation effort: none; drive from a shell test with `-c` connections, `-i` interval, `-r` rate, `-l` duration and assert the server stays responsive to a parallel curl.
- Notes: not in the task's list but squarely in the "behavioral client" lens; I added it because no other packaged tool covers the timeout/backpressure verbs.

---

## 3. Installability matrix for CI

macOS (Homebrew), all confirmed by `brew info` on 2026-09-19:

```
brew install wrk oha bombardier nghttp2 siege hey hurl slowhttptest    # h2load comes from nghttp2
# ab: /usr/sbin/ab already present; curl: /usr/bin/curl (8.7.1) or brew curl (8.22.0)
npm i -g autocannon
# go-httpbin: curl -L .../releases/download/v2.25.0/go-httpbin-darwin-all.tar.gz  or  go install github.com/mccutchen/go-httpbin/v2/cmd/go-httpbin@latest
```

Ubuntu 24.04 (apt), all confirmed on packages.ubuntu.com:

```
sudo apt-get install -y wrk siege apache2-utils nghttp2-client hey slowhttptest curl python3-httpbin
# NOT in apt: oha, bombardier (apt 'bombardier' is a game), hurl, wrk2, autocannon, go-httpbin
# hurl: curl -LO https://github.com/Orange-OpenSource/hurl/releases/download/8.0.1/hurl_8.0.1_amd64.deb && sudo apt install ./hurl_8.0.1_amd64.deb
# oha/bombardier/go-httpbin: download the linux-amd64/arm64 release binaries listed in §0.6
npm i -g autocannon
```

Every tool above runs as a separate process against `host:port`, i.e. all are usable for in-process-free black-box tests. None of the load generators offers a library mode we could call from Chez; the two *corpora* (TFB verification rules, curl `<protocol>` streams) are the only items that work in modes (a) and (c).

---

## 4. Recommendations for the first milestones

1. **Vendor now (tier 1)**: `tfb/toolset/test_types/{verifications,abstract_test_type}.py`, `plaintext/plaintext.py`, `json/json.py`, `toolset/wrk/*` and the curl `<protocol>` extraction (subset, with the extractor script) — each under `test/vendor/<name>/` with `PROVENANCE` (URL, commit, license text, extraction command).
2. **First black-box gate**: our `/plaintext` and `/json` must pass a Scheme port of TFB's `verify_headers`/`verify_status`/body checks, then `toolset/wrk/pipeline.sh` at depth 16 must complete with zero socket errors (wrk from brew/apt).
3. **Second gate**: curl-driven scenario list from `tests/http/test_07_upload.py` and `test_12_reuse.py` (Expect: 100-continue, chunked upload, connection reuse/close/timeout), expressed as `.hurl` files run by `hurl --test`.
4. **Later**: oha constant-rate latency runs; bombardier fasthttp-vs-net/http differential; h2load `--h1`; ab `-k` HTTP/1.0 keep-alive probe; slowhttptest for the timeout/backpressure milestone; go-httpbin diff harness once the app layer exists.

---

## 5. Appendix — measurement scripts and remaining verbatim outputs

### 5.1 curl protocol-block census (Python, run against `$REPOS/curl/tests/data`)

```python
import re,glob
R=".../scratchpad/repos/curl/tests/data"
multi=0; http=0; withproto=0; expect=0; chunked=0
for p in sorted(glob.glob(R+"/test*")):
    s=open(p,encoding="utf-8",errors="replace").read()
    kw=re.search(r"<keywords>(.*?)</keywords>",s,re.S)
    if not kw or not re.search(r"^HTTP$",kw.group(1),re.M): continue
    http+=1
    m=re.search(r"<protocol[^>]*>(.*?)</protocol>",s,re.S)
    if not m: continue
    withproto+=1
    proto=m.group(1)
    n=len(re.findall(r"^(GET|POST|PUT|HEAD|DELETE|OPTIONS|PATCH|CONNECT|TRACE|[A-Z]+) \S+ HTTP/1\.[01]\r?$",proto,re.M))
    if n>=2: multi+=1
    if "Expect: 100-continue" in proto: expect+=1
    if re.search(r"Transfer-Encoding: chunked",proto,re.I): chunked+=1
print("HTTP-keyword tests:",http,"with <protocol> verify:",withproto,">=2 requests in one protocol block:",multi,"Expect:100-continue in protocol:",expect,"chunked upload in protocol:",chunked)
```

Output: `HTTP-keyword tests: 1084 with <protocol> verify: 959 >=2 requests in one protocol block: 312 Expect:100-continue in protocol: 24 chunked upload in protocol: 21`

### 5.2 Other counts (commands → output)

```
ls $REPOS/curl/tests/data | wc -l                              → 2139
ls $REPOS/curl/tests/data/test* | wc -l                        → 2109
rg -l 'Expect: 100-continue' $REPOS/curl/tests/data/test* | wc -l   → 25
rg -l -i 'Transfer-Encoding: chunked' $REPOS/curl/tests/data/test* | wc -l → 60
rg -c '^    def test_' $REPOS/curl/tests/http/test_*.py | awk -F: '{s+=$2} END {print s}' → 345
find $REPOS/hurl/integration/hurl/tests_ok -name '*.hurl' | wc -l     → 182
find $REPOS/hurl/integration/hurl/tests_ok -name '*.py' | wc -l       → 108
find $REPOS/hurl/integration/hurl/tests_failed -name '*.hurl' | wc -l → 88
find $REPOS/hurl/integration/hurl/tests_error_parser -name '*.hurl' | wc -l → 49
find $REPOS/hurl/integration -name '*.hurl' | wc -l                   → 400
ls $REPOS/hurl/integration/hurl/tests_ssl/*.hurl | wc -l             → 15
ls $REPOS/wrk/scripts → addr.lua auth.lua counter.lua delay.lua pipeline.lua post.lua report.lua setup.lua stop.lua ; wc -l → 138 total
ls $REPOS/wrk2/scripts → addr.lua auth.lua counter.lua pipeline.lua post.lua report.lua setup.lua stop.lua
rg -c '#\[tokio::test\]|#\[test\]' $REPOS/oha/tests/tests.rs → 31
rg '^func Test' $REPOS/bombardier/*_test.go | wc -l → 66
rg '^func Test' $REPOS/hey/*_test.go $REPOS/hey/requester/*_test.go | wc -l → 9
rg -c "^test\(|^\s*test\(" $REPOS/autocannon/test/*.test.js (summed) → 230 ; ls test | wc -l → 40
rg -c '@app.route' $REPOS/httpbin/httpbin/core.py → 55 ; rg -c '    def test_' $REPOS/httpbin/test_httpbin.py → 67 ; cat httpbin/VERSION → 0.9.2
rg -c 'mux.HandleFunc\(' $REPOS/go-httpbin/httpbin/httpbin.go → 64 ; rg -c '^func Test' httpbin/handlers_test.go → 55 ; rg -c '^\s+t\.Run\(' httpbin/handlers_test.go → 150
rg -n 'version_string' $REPOS/siege/src/version.c → 7:const char *version_string = "4.2.0";
rg -n -i '^#? ?(protocol|connection|parser|benchmark) ' $REPOS/siege/doc/siegerc.in → 133:parser = true  213:protocol = HTTP/1.1  268:connection = close  412:benchmark = false
rg -n 'HTTP/1\.0|Keep-Alive' $REPOS/httpd/support/ab.c → 2109 (keepalive detection), 2302/2312 ("%s %s HTTP/1.0\r\n"), 2307/2320 (Connection: Keep-Alive only with -k)
```

### 5.3 Web pages fetched (all on 2026-09-19)

- https://packages.ubuntu.com/noble/wrk, /noble/siege, /noble/apache2-utils, /noble/amd64/apache2-utils/filelist, /noble/nghttp2-client, /noble/amd64/nghttp2-client/filelist, /noble/python3-httpbin, /noble/slowhttptest
- https://packages.ubuntu.com/search?keywords={hey,hurl,oha,bombardier,wrk2}&searchon=names&exact=1&suite=noble&section=all
- https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/n/nghttp2.rb
- https://github.com/postmanlabs/httpbin, https://github.com/psf/httpbin, https://github.com/giltene/wrk2, https://github.com/shekyan/slowhttptest
- https://registry.npmjs.org/autocannon (via curl)

### 5.4 Things I could not confirm / caveats

- slowhttptest was not cloned; its license and modes come from the GitHub API/page and Homebrew only. Its exact flag names (`-H -B -R -X`) are from the project page summary, so verify with `slowhttptest -h` after installing.
- hey has no release binaries; on macOS/Ubuntu use brew/apt (0.1.5 / 0.1.4), otherwise `go install`.
- The task brief's path `toolset/benchmark/test_types` for TFB does not exist at HEAD; the correct path is `toolset/test_types` (a `toolset/benchmark/` directory exists but holds the benchmarker, not the test types).
- TFB is archived on GitHub (`archived: true`), so any future changes to the verification rules will not appear upstream.
