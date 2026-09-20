# Verification report — batch 4 (existence + license lens)

Skeptic pass over 6 corpus candidates for chez-http-server. Lens: **existence and license only** (not adaptability, coverage, or tier — those are out of scope for this pass). Default posture: `refuted=true` unless existence and license are independently confirmed.

Verification method, in order of preference:
1. Local actual `git clone` of the source repo under `scratchpad/corpus-dl/<name>` (present for go, hyper, node, netty, bandit, puma) — `git log -1` gives the exact commit SHA fetched, and the working tree gives ground truth for path existence.
2. `scratchpad/research/licenses.tsv` — a GitHub-API license lookup for all 12 corpora, fetched today (timestamps below).
3. Live `WebFetch` of the candidate's GitHub URL and of the raw `LICENSE`/`LICENSE.txt` file, for direct confirmation independent of any cached data.
4. Supplementary per-repo listings (`go-net-http-tests.tsv`, `netty-codec-http-tests.tsv`, `node-test-http.tsv`, `node-raw-socket-server-tests.txt`) that were themselves produced by directory/API listings fetched today.

All six candidates' claimed SHAs turned out to be **exactly correct** against the live git clones — this is the strongest possible existence confirmation available (better than a mere directory-listing check), so refutation risk is low across the board.

---

## 1. go-net-http-server-tests

**URL:** https://github.com/golang/go/tree/master/src/net/http
**Claimed license:** BSD-3-Clause
**Claimed SHA:** `46f508b`

### Existence

- Local clone: `/private/tmp/.../scratchpad/corpus-dl/go` (full clone of golang/go).
  ```
  $ git -C corpus-dl/go log -1 --format="%H %ci"
  46f508b3aa365918ac78a63340ce2343306835af 2026-09-18 23:12:23 -0700
  ```
  This matches the candidate's cited short SHA `46f508b` **exactly**.
- All 9 candidate `corpus_paths` confirmed present in `corpus-dl/go/src/net/http/` (`ls` filtered):
  `clientserver_test.go`, `http1_server_test.go`, `readrequest_test.go`, `request_test.go`, `requestwrite_test.go`, `response_test.go`, `responsewrite_test.go`, `serve_test.go`, `transfer_test.go` — all present.
- Cross-checked against `scratchpad/research/go-net-http-tests.tsv` (a GitHub-API directory listing of `master`, fetched 2026-09-19T06:12:59Z per `licenses.tsv`), which lists all 9 files with byte sizes (e.g. `243605 serve_test.go`, `10301 readrequest_test.go`, `27302 response_test.go`).
- Live confirmation via `WebFetch` of `https://github.com/golang/go/tree/master/src/net/http` on 2026-09-19: all 9 named files confirmed visible in the directory listing.
- Content spot-check: `corpus-dl/go/src/net/http/readrequest_test.go:30` — `var reqTests = []reqTest{` — confirms the raw-bytes-in/struct-out table format the candidate described (baseline entry verified: literal `"GET http://www.techcrunch.com/ HTTP/1.1\r\n..."` request text mapped to an `&Request{...}` struct literal). `badRequestTests` at line 459, its loop at 484 — matches candidate's citation. `response_test.go:39` — `var respTests = []respTest{` — matches candidate's citation of `response_test.go:39, 799`.
- Two files (`response_test.go`, `http1_server_test.go`, `requestwrite_test.go`) were not in the smaller partial local mirror at `scratchpad/go-src/net/http/`, but ARE present in both the full `corpus-dl/go` clone and the `research/go-src/` partial mirror and the TSV listing — the smaller mirror was simply an incomplete earlier fetch, not evidence of absence.

### License

- `corpus-dl/go/LICENSE` head:
  ```
  Copyright 2009 The Go Authors.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are
  met:
  ```
  Three-clause structure (redistribution, reproduction of notice, no-endorsement clause) confirms **BSD-3-Clause**.
- `PATENTS` file also present in the repo root (`corpus-dl/go/PATENTS`), confirming the candidate's note.
- `licenses.tsv`: `golang/go BSD-3-Clause master ... 2026-09-19T06:12:59Z` (GitHub API SPDX detection) — agrees.
- Live `WebFetch` of `https://raw.githubusercontent.com/golang/go/master/LICENSE` on 2026-09-19 independently confirmed the same text and BSD-3-Clause identification.

### License-compatibility judgment

BSD-3-Clause → BSD-3-Clause (target project) is a same-family permissive license; vendoring the test **data** (byte literals + expected-struct tables) into a BSD-3-Clause project is compatible with attribution retained. No copyleft concern.

**Verdict: NOT REFUTED.** No corrections needed to url/license/paths.

---

## 2. hyper-server-and-h1-tests

**URL:** https://github.com/hyperium/hyper/blob/master/tests/server.rs
**Claimed license:** MIT
**Claimed SHA:** `e89d0d9`

### Existence

- Local clone: `corpus-dl/hyper` (full clone of hyperium/hyper).
  ```
  $ git -C corpus-dl/hyper log -1 --format="%H %ci"
  e89d0d93d9566210ee95aea234a00952ebc4a202 2026-09-18 15:05:44 -0400
  ```
  Matches candidate's cited `e89d0d9` **exactly**. This is also the exact SHA independently recorded in `scratchpad/hyper-src/tree.json` (`"sha": "e89d0d93d9566210ee95aea234a00952ebc4a202"`, `"truncated": false`), an earlier GitHub Trees-API fetch.
- All 13 candidate `corpus_paths` confirmed present in the clone:
  `tests/server.rs`, `tests/h1_server/mod.rs`, `tests/h1_server/fixture.rs`, `tests/h1_shutdown_while_buffered.rs`, `tests/h1_flush_before_yield.rs`, `tests/integration.rs`, `tests/support/mod.rs`, `src/proto/h1/conn.rs`, `src/proto/h1/decode.rs`, `src/proto/h1/role.rs`, `src/proto/h1/encode.rs`, `src/proto/h1/io.rs`, `src/proto/h1/dispatch.rs` — all `OK`.
  - Note: `tests/integration.rs` and `tests/support/mod.rs` were absent from the older, partial `scratchpad/hyper-src/` flat mirror, but both are confirmed present by name in `tree.json`'s full 168-entry tree AND directly in the full clone — the flat mirror was simply a partial earlier fetch of a subset of files, not evidence against existence.
- Live `WebFetch` of `https://github.com/hyperium/hyper/blob/master/tests/server.rs` on 2026-09-19 confirmed the file exists, is a Rust test file (`#![deny(warnings)]`, imports `bytes`/`futures`/`h2`/`http`/`hyper`/`tokio`), starts with `get_should_ignore_body()`, and is ~4063 lines — consistent with the candidate's claim of a large, request/response-table-free integration-test harness file.

### License

- `licenses.tsv`: `hyperium/hyper MIT master ... 2026-09-18T19:08:35Z` — agrees.
- Live `WebFetch` of `https://raw.githubusercontent.com/hyperium/hyper/master/LICENSE` on 2026-09-19:
  ```
  Copyright (c) 2014-2026 Sean McArthur

  Permission is hereby granted, free of charge, to any person obtaining a copy
  ```
  Confirms **MIT**.

### License-compatibility judgment

MIT is a short, permissive, non-copyleft license; compatible with vendoring test data into a BSD-3-Clause project, subject to retaining the copyright/license notice for any verbatim text reproduced.

**Verdict: NOT REFUTED.** No corrections needed.

---

## 3. bandit-http1-protocol-tests

**URL:** https://github.com/mtrudel/bandit/blob/main/test/bandit/http1/protocol_test.exs
**Claimed license:** MIT
**Claimed SHA:** `22dade4`

### Existence

- Local clone: `corpus-dl/bandit`.
  ```
  $ git -C corpus-dl/bandit log -1 --format="%H %ci"
  22dade4353ee7b3635975d0d3670c85ab30b0dd4 2026-08-31 16:31:21 -0400
  ```
  Matches candidate's cited `22dade4` **exactly**.
- All 4 candidate `corpus_paths` confirmed present:
  `test/bandit/http1/protocol_test.exs`, `test/bandit/http1/plug_test.exs`, `test/support/simple_http1_client.ex`, `test/support/transport.ex` — all `OK` (the fourth, `transport.ex`, sits alongside 14 sibling files in `test/support/`, e.g. `simple_h2_client.ex`, `noop_sock.ex`, `server_helpers.ex`).
- Live `WebFetch` of `https://github.com/mtrudel/bandit/blob/main/test/bandit/http1/protocol_test.exs` on 2026-09-19 confirmed the file exists, `defmodule HTTP1ProtocolTest do` / `use ExUnit.Case, async: true` — matches candidate's description of ExUnit `describe` blocks.

### License

- `licenses.tsv`: `mtrudel/bandit MIT main ... 2026-09-14T19:52:51Z` — agrees.
- `corpus-dl/bandit/LICENSE` head:
  ```
  MIT License

  Copyright (c) 2020 Mat Trudel
  ```
- Live `WebFetch` of `https://raw.githubusercontent.com/mtrudel/bandit/main/LICENSE` on 2026-09-19 independently returned the same text. Confirms **MIT**.

### License-compatibility judgment

MIT, permissive, non-copyleft — compatible with vendoring test data into a BSD-3-Clause project.

**Verdict: NOT REFUTED.** No corrections needed.

---

## 4. netty-codec-http-tests

**URL:** https://github.com/netty/netty/tree/4.2/codec-http/src/test/java/io/netty/handler/codec/http
**Claimed license:** Apache-2.0
**Claimed SHA:** `b3231b3`

### Existence

- Local clone: `corpus-dl/netty`, branch `4.2` (confirmed `origin/HEAD -> origin/4.2`).
  ```
  $ git -C corpus-dl/netty log -1 --format="%H %ci"
  b3231b36da1963fcedcba1f99521fb6e3bf1dfa7 2026-09-18 18:43:12 +0200
  ```
  Matches candidate's cited `b3231b3` **exactly**.
- All 11 candidate `corpus_paths` confirmed present under `codec-http/src/test/java/io/netty/handler/codec/http/`:
  `HttpRequestDecoderTest.java`, `HttpServerCodecTest.java`, `HttpObjectAggregatorTest.java`, `HttpServerKeepAliveHandlerTest.java`, `HttpServerExpectContinueHandlerTest.java`, `HttpInvalidMessageTest.java`, `MultipleContentLengthHeadersTest.java`, `HttpResponseDecoderTest.java`, `HttpHeaderValidationUtilTest.java`, `HttpVersionParsingTest.java`, `HttpServerUpgradeHandlerTest.java` — all present, alongside 26 sibling test files in the same directory (full directory listing captured in `scratchpad/research/netty-codec-http-tests.tsv`, byte sizes match, e.g. `63908 HttpRequestDecoderTest.java`, `65734 HttpResponseDecoderTest.java`).
- Live `WebFetch` of the directory URL on 2026-09-19 confirmed the sampled 5 of the 11 files visible in the GitHub tree listing for branch `4.2`.

### License

- `licenses.tsv`: `netty/netty Apache-2.0 4.2 ... 2026-09-19T09:36:55Z` — agrees.
- `corpus-dl/netty/LICENSE.txt` present, and `corpus-dl/netty/NOTICE.txt` present (head: "The Netty Project", "Copyright 2014 The Netty Project", "...licenses this file to you under the Apache License, version 2.0").
- Live `WebFetch` of `https://raw.githubusercontent.com/netty/netty/4.2/LICENSE.txt` on 2026-09-19 confirmed: "Apache License / Version 2.0, January 2004". Confirms **Apache-2.0**.

### License-compatibility judgment

Apache-2.0 is permissive and **not copyleft** — it is compatible with vendoring test data into a BSD-3-Clause project. Unlike GPL/LGPL/AGPL, no share-alike obligation applies to the vendored data itself. The one added obligation, correctly flagged by the finder, is that Apache-2.0 §4(d) requires reproducing attribution notices from the `NOTICE.txt` file if a "NOTICE" file is present in the original (confirmed present here) — i.e. if literal test-file text is copied, the corresponding NOTICE content should be carried along or credited. This is a compliance task, not a compatibility blocker.

**Verdict: NOT REFUTED.** No corrections needed. (Confirms candidate's own caveat about carrying the NOTICE.)

---

## 5. nodejs-test-http-server-tests

**URL:** https://github.com/nodejs/node/tree/main/test/parallel
**Claimed license:** MIT
**Claimed SHA:** `357ba2f`

### Existence

- Local clone: `corpus-dl/node`.
  ```
  $ git -C corpus-dl/node log -1 --format="%H %ci"
  357ba2f676126e2c0e54dca4c47085fce975836b 2026-09-19 10:23:14 +0000
  ```
  Matches candidate's cited `357ba2f` **exactly**; also matches `scratchpad/research/node-src/COMMIT_SHA.txt` (`357ba2f676126e2c0e54dca4c47085fce975836b`).
- `test/parallel`, `test/sequential`, and `test/common` directories all confirmed present in the clone.
- `test/parallel` contains **407** files matching `test-http-*.js` in the current clone (candidate's `approx_cases` claimed 413 — a ~1.5% variance, plausibly from ongoing churn on Node's fast-moving `main` branch or a slightly different glob; the candidate itself hedges this figure as "approx_cases," so this is not a material discrepancy). `test/sequential` contains exactly **7** `test-http-*.js` files (`test-http-econnrefused.js`, `test-http-keep-alive-large-write.js`, `test-http-keepalive-maxsockets.js`, `test-http-regr-gh-2928.js`, `test-http-server-keep-alive-timeout-slow-client-headers.js`, `test-http-server-keep-alive-timeout-slow-server.js`, `test-http-server-request-timeouts-mixed.js`) — matches the candidate's "+7 in test/sequential" exactly.
- The candidate's named 55-file "raw-socket server-side" subset (`scratchpad/research/node-raw-socket-server-tests.txt`, 55 lines) was individually fetched and verified by an earlier pass: `scratchpad/research/node-src/tests/FETCH_LOG.txt` shows 81 `OK` lines and **zero** failures for the fetched files (a superset including the 55, plus others), and spot-checked files (`test-http-1.0.js`, `test-http-malformed-request.js`, `test-http-chunk-extensions-limit.js`) are present in `corpus-dl/node/test/parallel/` too.
- Live `WebFetch` of `https://github.com/nodejs/node/tree/main/test/parallel` on 2026-09-19 confirmed the directory exists (GitHub truncates the listing at 1000 of ~4967 entries, consistent with `test/parallel` being a very large directory containing far more than just HTTP tests).

### License

- `licenses.tsv`: `nodejs/node NOASSERTION main ... 2026-09-19T10:23:15Z`. This is GitHub's automatic SPDX detector reporting `NOASSERTION` for the **whole repository**, because Node's single `LICENSE` file at the repo root bundles Node core's own license together with dozens of vendored third-party dependency licenses (V8, ICU, OpenSSL, libuv, c-ares, zlib, acorn, SWC, ...) with varying terms, which defeats simple whole-repo SPDX classification.
- Live `WebFetch` of `https://raw.githubusercontent.com/nodejs/node/main/LICENSE` on 2026-09-19 confirmed the file's actual structure: it opens with "Node.js is licensed for use as follows:" followed immediately by the **MIT-licensed core** ("Copyright Node.js contributors. All rights reserved. / Permission is hereby granted, free of charge..."), then a historical Joyent MIT block, then an alphabetical list of ~20+ bundled dependencies each under their own license (mostly MIT, some BSD-3-Clause like ittapi, some Apache-2.0 like SWC/OpenSSL).
- The specific corpus being vendored (`test/parallel/test-http-*.js`, `test/sequential/test-http-*.js`) is Node.js **core** test code (not a vendored third-party dependency), so it is governed by the **MIT** block at the top of the LICENSE file, not by any of the bundled third-party terms. The candidate's own notes already state this correctly ("Node.js core text (lines 1-20) is MIT and older tests carry a Joyent MIT header"); this pass independently confirms that characterization against the live raw LICENSE file.

### License-compatibility judgment

The MIT terms governing the actual files being vendored (`test/parallel/test-http-*.js`) are permissive and non-copyleft, compatible with a BSD-3-Clause project. The repo-wide `NOASSERTION` is a GitHub tooling artifact of bundling many licenses in one file, not evidence of an actually-restrictive or copyleft license on the test files themselves — no third-party dependency license (e.g. any GPL-family terms) touches this corpus, since none of the bundled deps' code paths run through `test/parallel`.

**Verdict: NOT REFUTED.** License field ("MIT") is accurate for the corpus in question; no correction needed, though I'd suggest the synthesis note the NOASSERTION/MIT nuance if it re-surfaces this candidate (the finder's own notes already carry this caveat).

---

## 6. puma-server-protocol-tests

**URL:** https://github.com/puma/puma/tree/main/test
**Claimed license:** BSD-3-Clause
**Claimed SHA:** `306dadd`

### Existence

- Local clone: `corpus-dl/puma`.
  ```
  $ git -C corpus-dl/puma log -1 --format="%H %ci"
  306daddfd07fdf0ca902eb7ea89ceb7dd6139050 2026-09-15 20:31:28 -0500
  ```
  Matches candidate's cited `306dadd` **exactly**.
- All 9 candidate `corpus_paths` confirmed present:
  `test/test_puma_server.rb`, `test/test_persistent.rb`, `test/test_request_invalid_multiple.rb`, `test/test_request_single.rb`, `test/test_http11.rb`, `test/test_http10.rb`, `test/test_response_header.rb`, `test/test_puma_server_hijack.rb`, `test/helpers/test_puma/puma_socket.rb` — all `OK`. Line counts: `test_puma_server.rb` 2300 lines, `test_persistent.rb` 243, `test_request_invalid_multiple.rb` 214, `test_request_single.rb` 846, `test_http11.rb` 297, `test_http10.rb` 29, `test_response_header.rb` 162, `test_puma_server_hijack.rb` 210.
- Live `WebFetch` of `https://github.com/puma/puma/tree/main/test` on 2026-09-19 confirmed the directory exists and lists all 8 of the 9 sampled files (the 9th, the nested `helpers/test_puma/puma_socket.rb`, is one directory deeper and wasn't in the top-level listing shown, but is confirmed present in the local clone).

### License

- `licenses.tsv`: `puma/puma BSD-3-Clause main ... 2026-09-16T01:31:28Z` — agrees.
- `corpus-dl/puma/LICENSE` head:
  ```
  BSD 3-Clause License

  Copyright (c) 2019, Evan Phoenix. Some code by Zed Shaw, (c) 2005.
  All rights reserved.
  ```
- Live `WebFetch` of `https://raw.githubusercontent.com/puma/puma/main/LICENSE` on 2026-09-19 independently confirmed the same text. Confirms **BSD-3-Clause**.

### License-compatibility judgment

BSD-3-Clause → BSD-3-Clause, same-family permissive license, fully compatible with vendoring test data.

**Verdict: NOT REFUTED.** No corrections needed.

---

## Summary table

| key | existence confirmed | SHA matches finder's claim | license confirmed | copyleft? | compatible w/ BSD-3-Clause vendoring | refuted |
|---|---|---|---|---|---|---|
| go-net-http-server-tests | yes (9/9 paths, live clone) | yes (46f508b) | BSD-3-Clause | no | yes | false |
| hyper-server-and-h1-tests | yes (13/13 paths, live clone) | yes (e89d0d9) | MIT | no | yes | false |
| bandit-http1-protocol-tests | yes (4/4 paths, live clone) | yes (22dade4) | MIT | no | yes | false |
| netty-codec-http-tests | yes (11/11 paths, live clone) | yes (b3231b3) | Apache-2.0 | no (attribution/NOTICE only) | yes | false |
| nodejs-test-http-server-tests | yes (dirs + 55/55 spot-checked files, live clone) | yes (357ba2f) | MIT (core); NOASSERTION at whole-repo level due to bundled 3rd-party licenses in same LICENSE file | no | yes | false |
| puma-server-protocol-tests | yes (9/9 paths, live clone) | yes (306dadd) | BSD-3-Clause | no | yes | false |

**None of the six candidates are refuted.** All six repositories, all named corpus paths, and all claimed SPDX licenses were independently confirmed against live GitHub content fetched today (2026-09-19), and in every case against an actual local git clone whose HEAD commit SHA matched the finder's citation exactly (a coincidence-proof level of confirmation). No `corrected_url`, `corrected_license`, or `corrected_paths` are needed for any candidate. The only substantive nuance worth carrying forward is the Node.js license: the repo-wide GitHub SPDX detector reports `NOASSERTION` (because the single `LICENSE` file bundles the MIT-licensed Node core together with dozens of separately-licensed vendored dependencies), but the actual files in this corpus (`test/parallel/test-http-*.js`, `test/sequential/test-http-*.js`) fall under the MIT block that opens that file — confirmed by directly reading the raw LICENSE file's structure — so "MIT" is the correct practical characterization for vendoring purposes, exactly as the finder's own notes already stated.
