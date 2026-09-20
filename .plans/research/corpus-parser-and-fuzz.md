# Corpus survey — lens: parser-and-fuzz

Date: 2026-09-19. Machine: macOS arm64, `gh` authenticated as DarrenN, `curl`
against raw.githubusercontent.com and api.github.com. Downloaded files live in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/dl/`
(referred to as `dl/` below). Nothing was written into any git repository.

Target project: chez-http-server. Test surfaces it will have:

- (a) in-process over loopback TCP using chez-libuv's own client verbs;
- (b) black-box from external clients against a port;
- (c) a sans-I/O connection driver that replays byte streams at every chunk
  size, the way chez-httparse replays llhttp fixtures.

Tiers: 1 = vendor now (with a PROVENANCE file per chez-httparse ADR-0007),
2 = adapt later, 3 = reference only.

## 0. Baseline: what llhttp already gives us (already vendored by chez-httparse)

Local checkout `/Users/yuzu/github/llhttp`:

```
$ cd /Users/yuzu/github/llhttp && git log -1 --format='%H %cd %s' && git describe --tags
ee51043701d8b90ef647cf04790cbb1c55889825 Thu Jul 30 16:04:44 2026 +0200 chore: reclassify QUERY method as standardized (RFC 10008) (#868)
v9.4.3-1-gee51043
$ head -3 LICENSE
MIT License

Copyright © 2018 Fedor Indutny
```

Exact fixture counts (one ```` ```http ```` block per fixture; ```` ```url ```` in url.md):

```
$ rg -c '^```http' test/request/*.md test/response/*.md | awk -F: '{s+=$2} END{print s}'
253
$ rg -c '^```url' test/url.md
21
  21 test/request/connection.md
  18 test/request/content-length.md
   3 test/request/finish.md
  24 test/request/invalid.md
   5 test/request/lenient-header-value-relaxed.md
   4 test/request/lenient-headers.md
   1 test/request/lenient-version.md
  16 test/request/method.md
  13 test/request/pausing.md
   1 test/request/pipelining.md
  18 test/request/sample.md
  32 test/request/transfer-encoding.md
  11 test/request/uri.md
  18 test/response/connection.md
   4 test/response/content-length.md
   1 test/response/finish.md
  19 test/response/invalid.md
   1 test/response/lenient-version.md
  11 test/response/pausing.md
   1 test/response/pipelining.md
  20 test/response/sample.md
  11 test/response/transfer-encoding.md
```

(253 + 21 = 274, matching chez-httparse's "all 274 llhttp fixtures".)

Connection-level fixtures already present in llhttp (`test/request/connection.md`
headings, `rg -n '^## |^### '`): keep-alive flag; restart when keep-alive
explicit; no restart when keep-alive off (1.0); CRLF between requests with
implicit keep-alive; `close` flag, `close` followed by tab; CRLF between
requests with explicit close (strict and lenient); multiple Connection tokens
with folding/LWS; `upgrade` flag + pausing; "Emitting part of body and
pausing"; Upgrade GET; Upgrade POST. `test/request/pipelining.md` has exactly
one fixture ("Should parse multiple events"). So llhttp already covers the
*parser-visible* side of keep-alive / close / upgrade / pipelining, but the
oracle is a byte-offset event trace, not a server behaviour.

chez-httparse's vendoring convention (what a PROVENANCE file must look like):
`/Users/yuzu/github/chez-httparse/.plans/decisions/0007-llhttp-corpus-vendored-as-data.md`
and `/Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE`:

```
upstream-url: https://github.com/nodejs/llhttp
upstream-ref: v9.4.3-1-gee51043
upstream-commit: ee51043701d8b90ef647cf04790cbb1c55889825
retrieved: 2026-09-13
file-count: 24

sha256 628168d68bb5a8a17e0bbefb3bd74e326e1edc20583d76f52f457c82c921867d LICENSE
sha256 5d8711f1974be9ef20fe107ea5cfbad177cd65ae35f46a79fb1f1b89e1442d61 request/connection.md
...
```

Rules from ADR-0007 worth carrying over: files are never edited; a checksum
manifest is verified by a registered spec; `make corpus-refresh` copies from a
checkout named by a variable; corpus is parsed at test time by a pure Scheme
loader; disagreements go in a ratchet + decision record, never into the bytes.

llhttp also ships the OSS-Fuzz harness `test/fuzzers/fuzz_parser.c` (local) —
OSS-Fuzz `projects/llhttp/build.sh` compiles only that file; no seed corpus or
dictionary is shipped for it:

```
$ curl -sSL https://raw.githubusercontent.com/google/oss-fuzz/master/projects/llhttp/build.sh | rg -n 'corpus|dict|seed|zip|fuzz'
24:$CC $CFLAGS -c ./test/fuzzers/fuzz_parser.c -I./build/ ./build/libllhttp.a -o $WORK/fuzz_parser.o
25:$CXX $CXXFLAGS $LIB_FUZZING_ENGINE -fuse-ld=lld -I./build/ ./build/libllhttp.a $WORK/fuzz_parser.o -o $OUT/fuzz_parser
```

Verdict: **Tier 1, already done** via chez-httparse. For the server repo the
question is whether to re-vendor (duplicate 288K) or reach the fixtures
through chez-httparse's `test/vendor/llhttp`. The connection driver (c) can
reuse chez-httparse's loader and expected-trace comparator directly.

---

## 1. OISF/libhtp `test/files/*.t` — connection-level request/response streams  (TIER 1)

- URL: https://github.com/OISF/libhtp (default branch `0.5.x`)
- License: BSD-3-Clause (`LICENSE`: "Copyright (c) 2009-2010 Open Information
  Security Foundation / Copyright (c) 2010-2013 Qualys, Inc. ... Redistribution
  and use in source and binary forms, with or without modification, are
  permitted provided that the following conditions are met:")
- Status: **archived** (EOL announced July 7, 2026). README.md: "Suricata 8
  and beyond use a fork of the libhtp code that has been converted and
  rewritten to Rust. It is available under the same license from the Suricata
  repository: https://github.com/OISF/suricata/tree/main/rust/htp".
- Paths: `test/files/*.t` (102 `.t` files; the directory also holds 15
  `gztest-*.gz` and helper files), oracle in `test/test_main.cpp` (112
  `TEST_F`, referencing all 102 `.t` files), loader/format in `test/test.c`.
  OSS-Fuzz uses the same files as its seed corpus.

Evidence:

```
$ gh api repos/OISF/libhtp --jq '{default_branch, archived, pushed_at, license: .license.spdx_id}'
{"archived":true,"default_branch":"0.5.x","license":"BSD-3-Clause","pushed_at":"2026-08-14T15:15:59Z"}
$ gh api repos/OISF/libhtp/contents/test/files --jq '.[] | .name' | rg -c '\.t$'
102
$ curl -sSL https://raw.githubusercontent.com/google/oss-fuzz/master/projects/libhtp/build.sh | rg -n 'corpus'
27:# builds corpus
28:zip -r $OUT/fuzz_htp_seed_corpus.zip test/files/*.t
$ wc -l dl/libhtp-test_main.cpp ; rg -c '^TEST_F' dl/libhtp-test_main.cpp
2148 ; 112
$ rg -o '"[0-9]+-[a-z0-9_-]+\.t"' dl/libhtp-test_main.cpp | sort -u | wc -l
102
```

File list (all 102): 00-adhoc 01-get 02-header-test-apache2 03-post-urlencoded
04-post-urlencoded-chunked 05-expect 06-uri-normal 07-pipelined-connection
08-not-pipelined-connection 09-multi-packet-request-head 10-host-in-headers
100-auth-bearer 100-response-body-data 11-response-stream-closure
12-connect-request 13-compressed-response-gzip-ct
14-compressed-response-gzip-chunked 15-connect-complete 16-connect-extra
17-multipart-1 18-compressed-response-deflate 19-urlencoded-test
20-ambiguous-host 21-http09 22-php-param-processing 23-http09-multiple
24-http09-explicit 25-small-chunks 26-request-headers-raw
27-request-trailer-raw 28-response-headers-raw 29-response-trailer-raw
30-get-ipv6 31-get-request-line-nul 32/33/34-invalid-hostname
35-early-response 36-invalid-request-1-invalid-c-l
37-invalid-request-2-t-e-and-c-l 38-invalid-request-3-invalid-t-e
39-auto-destroy-crash 40-auth-basic 41-auth-digest 42-unknown-method_only
43-invalid-protocol 44..47 auth variants 48/49-invalid-response-headers
50-util 51-get-ipv6-invalid 52-invalid-path 53..59 path-utf8 variants
60-request-cookies 61-empty-line-between-requests 62-post-no-body
63/64/65-post-chunked-invalid 66-post-chunked-split-chunk
67-long-request-line 68-invalid-request-header 69-long-response-header
70-response-invalid-chunk-length 71-response-split-chunk
72-response-split-body 73-response-te-and-cl 74-response-multiple-cl
75-response-invalid-cl 76-response-no-body 77-response-folded-headers
78-response-no-status-headers 79-connect-invalid-hostport
80/81-hostname-invalid 82-put 83-auth-digest-invalid-username-2
84-response-no-status-headers-2 85-zero-byte-request-timeout
86-partial-request-timeout 87-issue-55-incorrect-host-ambiguous-warning
88-response-multiple-cl-mismatch 89-get-whitespace 90-request-uri-too-large
91-request-unexpected-body 92-http_0_9-method_only
93/94/95/96-compressed-response-* 97-requests-cut 98-responses-cut
99-expect-100.

Format (from `test/test.c` lines 64-97 `test_is_boundary`, 160-245
`test_next_chunk`, 348-395 the feed loop): a file is a sequence of chunks; a
line that is exactly `>>>` (optionally `\r`) starts a CLIENT chunk, `<<<` a
SERVER chunk; every chunk is fed to the parser as one `htp_connp_req_data` /
`htp_connp_res_data` call — i.e. `>>>` boundaries are **explicit packet
boundaries**. Samples (`cat -v`, `^M` = CR):

```
=== 07-pipelined-connection.t
>>>^M
GET /first HTTP/1.1^M
^M
GET /second HTTP/1.1^M
^M
^M
<<<^M
HTTP/1.0 200 OK^M
Content-Length: 12^M
^M
Hello World!^M
HTTP/1.0 200 OK^M
...
=== 09-multi-packet-request-head.t
>>>^M
GET / HTTP/1.0^M
^M
>>>^M
Host: www.example.com^M
^M
>>>^M
^M
^M
<<<^M
HTTP/1.0 200 OK^M
...
=== 97-requests-cut.t
>>>^M
GET /?p=%20 HTTP/1.1^M
User-Agent: Mozilla^M
^M
G^M
>>>^M
ET /?p=%21 HTTP/1.1^M
User-Agent: Mozilla
=== 37-invalid-request-2-t-e-and-c-l.t   (TE + CL, request smuggling shape)
>>>^M
POST / HTTP/1.1^M
Transfer-Encoding: chunked^M
Content-Length: 12^M
...
```

Oracle shape (C++ gtest, `test/test_main.cpp` 241-251):

```
TEST_F(ConnectionParsing, PipelinedConn) {
    int rc = test_run(home, "07-pipelined-connection.t", cfg, &connp);
    ASSERT_GE(rc, 0);
    ASSERT_EQ(2, htp_list_size(connp->conn->transactions));
    ASSERT_TRUE(connp->conn->flags & HTP_CONN_PIPELINED);
```

Flags asserted across the suite (`rg -o 'HTP_[A-Z_]+' | sort | uniq -c`):
HTP_REQUEST_COMPLETE 40, HTP_RESPONSE_COMPLETE 27, HTP_PATH_UTF 13,
HTP_HOST_AMBIGUOUS 6, HTP_REQUEST_SMUGGLING 5, HTP_FIELD_INVALID 4,
HTP_MULTI_PACKET_HEAD 2, HTP_CONN_PIPELINED 2, HTP_FIELD_REPEATED 2, ...

Covers (connection level, which llhttp lacks): pipelining vs not,
multi-packet request heads, CRLF/empty line between requests, requests cut
mid-token across packets, TE+CL and invalid-CL/invalid-TE (smuggling flags),
CONNECT then tunnel bytes (15-connect-complete, 16-connect-extra), HTTP/0.9
single and multiple, Expect/100-continue, early response before request
body finished (35), zero-byte / partial request then timeout (85, 86),
NUL in request line, ambiguous Host, invalid hostnames, IPv6 host, UTF-8 and
overlong path bytes, long request line / URI too large, unexpected body on
GET, response-side split chunks / multiple CL / TE+CL / folded headers /
no-status-line.

Redundancy with llhttp: low at connection level; some overlap on parser
errors (invalid CL, TE+CL, folding).

Adaptation:
- (c) **primary fit.** Loader is ~40 lines of Scheme (line-oriented split on
  `>>>`/`<<<`, strip one trailing CR from each chunk as test.c does). Feed
  the CLIENT chunks in order to the sans-I/O driver as separate `on-data`
  deliveries, honouring the file's packet boundaries **and** additionally
  re-splitting at every chunk size. The `<<<` chunks are the *recorded
  origin's* responses — for our server they are not an oracle; the oracle we
  write per file is: number of requests completed, whether the connection
  was marked keep-alive/close, whether a 400/411/413 was emitted for the
  invalid-* files, and that the driver never crashes or stalls.
- (a) also fits: write each `>>>` chunk with `uv-write!` in order (with a
  timer between chunks for 85/86) and observe the server's responses.
- Effort: loader trivial; oracle authoring by hand for ~60 relevant files
  (skip auth-*, compressed-response-*, multipart, php-param, response-side
  files which test a client/IDS parser, and the gzip blobs). Vendor only the
  `.t` files + LICENSE + PROVENANCE (files are ~1 KiB each).
- Since the repo is archived, the PROVENANCE should pin the commit; a
  refresh target can point at `suricata/rust/htp` if that fork keeps the
  files (not verified).

---

## 2. h2o `fuzz/http1-corpus` + `fuzz/http.dict` — libFuzzer seed corpus of packetised HTTP/1 streams  (TIER 2)

- URL: https://github.com/h2o/h2o/tree/master/fuzz
- License: MIT (`LICENSE`: "Copyright (c) 2014 DeNA Co., Ltd. Permission is
  hereby granted, free of charge, ...")
- Paths: `fuzz/http1-corpus/` (1972 files, 2,525,951 bytes, sizes 1..16384,
  mean 1281, named by SHA1), `fuzz/http.dict` (2712 lines), `fuzz/url-corpus/`
  (90 files), `fuzz/driver.cc` (the harness), `fuzz/README.md`,
  `fuzz/gather-data.patch`. (`fuzz/http2-corpus/` 1272 files, out of scope.)

Evidence:

```
$ gh api repos/h2o/h2o --jq ... ; "pushed_at": "2026-09-10T04:21:41Z", "spdx_id": "MIT"
$ gh api "repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784" --jq '.tree | length'   # http1-corpus
1972
$ ... --jq '.truncated'  -> false
$ ... --jq '[.tree[].size] | add'  -> 2525951
$ ... --jq '[.tree[].size] | (min, max, (add/length))'  -> 1 / 16384 / 1280.91
$ wc -l dl/h2o-http.dict -> 2712
40 of 40 sampled files contain --MARK--
```

Format: raw bytes written to a socketpair connected to an in-process h2o
server; `fuzz/driver.cc` line 153: `#define MARKER "\n--MARK--\n"` — the
writer thread `memmem`s for the marker and issues **one `write()` per
segment**, then drains the socket with a 10 ms select timeout, up to 20
rounds, then `shutdown(SHUT_WR)`. So each corpus file is a *packetised
request stream* with explicit write boundaries, exactly the shape our
connection driver consumes. README: "The test corpuses included in this were
initially created by first patching h2o with the included
`fuzz/gather-data.patch` and then running the unit tests. The corpuses were
then broadened via fuzzing with this fuzzer and minimized."

Sample (`cat -v`):

```
=== 006501e99f60fee122ccd177264a2da72442c29e
GET / HTTP/1.1^M
Host:/7.49.0-DEV^M
bAccept:**
--MARK--
r: http://example.com(/^M
^M

-KT / HTTP/1.1^M
...
=== 008dd45d7706994bbdcb331681e5b28c7e86fffe
POST / HTTP/1.1^M
Host: 254.0.0M-VM-^MM-^ZM-^Orunked^M
Content-Typa: application/x-www0.0el-Agent: curM-^?M-^?ding: chun!ked^M
...
a^M
helloworld^M
0^M
^M
^@^@^@^@ ...
--MARK--
```

`fuzz/http.dict` is a large, well-organised token dictionary (punctuation,
byte values incl. `nul="\x00"`, methods, versions, header names, values), MIT.

Covers: robustness/no-crash/no-hang under mutated, NUL-laden, split-at-odd-
places request streams; pipelined garbage; chunked bodies with junk. No
oracle beyond "server survives and either answers or closes".

Redundancy with llhttp: none in kind (llhttp has no fuzz seeds); heavily
h2o-specific in content (x-reproxy-url, h2o handler paths).

Adaptation:
- (c) fit: split on `"\n--MARK--\n"`, deliver each segment as one on-data,
  assert: no unguarded raise, driver reaches a terminal state (closed or
  awaiting input) within N steps, all emitted responses are well-formed.
  Also replay at every chunk size ignoring the marks.
- (a) fit as a soak lane: write segments over loopback with `uv-write!`,
  bounded by a `make-uv-timer` per connection.
- Vendoring: 2.5 MB of opaque files is heavier than ADR-0007's 288K. Options:
  vendor a subset (e.g. the ~N files that start with an ASCII method token),
  or keep the whole set out-of-tree behind a `make corpus-fetch` target with a
  pinned commit + sha256 of the tarball. Files are content-addressed by SHA1
  name, which makes a PROVENANCE manifest trivial.
- Not for the first milestone: a crash-only oracle is only useful once the
  driver exists. Hence tier 2.

---

## 3. nodejs/http-parser `test.c` — the ancestor fixture set with explicit connection oracles  (TIER 2)

- URL: https://github.com/nodejs/http-parser/blob/main/test.c
- License: MIT (`LICENSE-MIT`: "Copyright Joyent, Inc. and other Node
  contributors."), repo **archived** (`"archived": true`, pushed
  2022-06-19).
- Paths: `test.c` only (4729 lines). Arrays: `requests[]` (line 95, **47**
  entries), `responses[]` (line 1331, **30** entries), `url_tests[]` (**48**
  entries), plus 19 `test_simple(...)` scalar cases and several targeted
  tests (`test_double_content_length_error`, `test_chunked_content_length_error`,
  `test_header_cr_no_lf_error`, `test_header_overflow_error`,
  `test_content_length_overflow`, `test_no_overflow_long_body`,
  `test_message_pause`, `test_message_connect`, `test_multiple3`, `test_scan`).

Evidence:

```
$ sed -n '95,1330p' dl/http-parser-test.c | rg -c '\.name\s*='   -> 47
$ awk '/^const struct message responses\[\]/{p=1} ... ' | rg -c '\.name\s*='  -> 30
$ awk '/^const struct url_test url_tests\[\]/,/^};/' ... | rg -c '\.name\s*='  -> 48
$ rg -c '^\s*test_simple\s*\(' dl/http-parser-test.c  -> 19
```

Request names (47): curl get | firefox get | dumbluck | fragment in url | get
no headers no body | get one header no body | get funky content length body
hello | post identity body world | post - chunked body | two chunks ; triple
zero ending | chunked with trailing headers | with nonsense after the length
| with quotes | apachebench get | query url with question mark | newline
prefix get | upgrade request | connect request | report request | request
with no http version | m-search request | line folding in header value |
host terminated by a query string | host:port terminated by a query string |
host:port terminated by a space | PATCH request | connect caps request |
utf-8 path request | hostname underscore | eat CRLF between requests, no
"Connection: close" header | eat CRLF between requests even if "Connection:
close" is set | PURGE request | SEARCH request | host:port and basic_auth |
line folding in header value | multiple connection header values with
folding | ... with folding and lws (x2) | upgrade post request | connect
with body request | link request | unlink request | source request (x2) |
post - multi coding transfer-encoding chunked body | post - multi line
coding transfer-encoding chunked body | chunked with content-length set,
allow_chunked_length flag is set.

Response names (30) include: HTTP/1.0 with keep-alive and EOF-terminated 200;
HTTP/1.0 with keep-alive and a 204; HTTP/1.1 with an EOF-terminated 200;
HTTP/1.1 with a 204 (and keep-alive disabled); 101 with Upgrade (+CL, +TE);
200 with Upgrade (+CL, +TE); chunked not last TE; http version 0.9; neither
content-length nor transfer-encoding; Content-Length-X; field space; field
underscore.

Why it is not simply redundant with llhttp: `struct message` carries explicit
**connection-level expectations** that llhttp's trace format only implies via
flags — `should_keep_alive`, `message_complete_on_eof`, `upgrade` (the bytes
after the upgrade), `num_chunks`/`chunk_lengths`, `content_length`,
`body_size`, `host`/`port`/`userinfo`. And `test_scan` (line 4105) replays
every 2-cut of three concatenated messages ("total_ops = 2 * (total_len - 1)
* (total_len - 2) / 2") — the same every-boundary discipline our driver
needs, applied to pipelined triples.

Redundancy: high at the byte level — llhttp's `sample.md`, `connection.md`,
`transfer-encoding.md` were ported from these; chez-httparse already passes
those. The *oracle fields* are the added value.

Adaptation:
- (c) fit. Transcribe `requests[]`/`responses[]` into an s-expression or JSON
  data file with a one-off script (the C literals are regular: `.name=`,
  `.raw=`, `.should_keep_alive=`, `.message_complete_on_eof=`, `.upgrade=`,
  `.headers= {{k,v},...}`, `.body=`) — ~100 lines of Python; or hand-port
  only the should_keep_alive / message_complete_on_eof / upgrade columns as
  the connection driver's keep-alive oracle table (77 rows).
- Vendoring `test.c` verbatim (MIT) with PROVENANCE is fine, but the loader
  would then have to parse C — not worth it; vendor the transcription plus
  the script that produced it and a checksum of upstream `test.c`.

---

## 4. python-hyper/h11 tests — connection state-machine scenarios (keep-alive, pipelining, upgrade, close)  (TIER 2)

- URL: https://github.com/python-hyper/h11
- License: MIT (`LICENSE.txt`; API `spdx_id: MIT`; pushed 2025-04-24)
- Paths: `h11/tests/test_connection.py` (1120 lines, 28 tests),
  `h11/tests/test_io.py` (583 lines, 17 tests), `test_state.py` (10),
  `test_headers.py` (3), `test_events.py` (3), `test_against_stdlib_http.py`
  (2), `h11/tests/data/test-file` (one trivial file); `fuzz/afl-server.py`
  + `fuzz/afl-server-examples/{1,2,3,4}` (4 tiny AFL seeds, e.g.
  `GET /some-path HTTP/1.1\r\nHost: example.com\r\n`); OSS-Fuzz
  `projects/h11/fuzz_h11.py`.

Evidence — test names (`rg -o '^\s*def (test_[a-z0-9_]+)'`):

test_connection.py: test__keep_alive test__body_framing test_chunked
test_chunk_boundaries test_client_talking_to_http10_server
test_server_talking_to_http10_client
test_automatic_transfer_encoding_in_response
test_automagic_connection_close_handling test_100_continue
test_max_incomplete_event_size_countermeasure test_reuse_simple
test_pipelining test_protocol_switch test_close_simple
test_close_different_states test_pipelined_close test_sendfile test_errors
test_idle_receive_nothing test_connection_drop test_408_request_timeout
test_empty_request test_empty_response test_early_detection_of_invalid_request
test_early_detection_of_invalid_response
test_special_exceptions_for_lost_connection_in_message_body

test_io.py: test_writers_simple test_readers_simple test_writers_unusual
test_readers_unusual test__obsolete_line_fold_bytes
test_reject_garbage_after_request_line test_reject_garbage_after_response_line
test_reject_garbage_in_header_line test_reject_non_vchar_in_path
test_allow_some_garbage_in_cookies test_host_comes_first

Covers: exactly the CONNECTION-level semantics the task asks about —
keep-alive decision table by version × Connection header, body framing
decision (CL vs TE vs EOF vs HEAD/204/304), pipelining with a paused
"next request" until the response is done, protocol switch (CONNECT and
Upgrade: the bytes after the switch are handed over, not parsed), close in
every state, pipelined-then-close, 100-continue, 408 on idle timeout,
connection drop mid-body, max incomplete event size countermeasure
(slowloris), empty request/response, early rejection of invalid messages.

Redundancy with llhttp: low — this is the layer above the parser.

Format: Python code, not data; no extractable corpus. h11 is sans-I/O, so
its tests are structurally the closest thing to our (c) driver's tests.

Adaptation:
- (c) and (a): port by hand as *scenarios*, one Scheme test per h11 test,
  reusing their byte strings. Because h11's `Connection` object is a
  sans-I/O state machine (`receive_data` / `next_event` / `send`), its tests
  translate to "feed bytes, observe events, feed events, observe bytes" with
  little impedance. No PROVENANCE file needed (nothing vendored), but cite
  the upstream test name in each ported test.
- The AFL seeds are too small to matter; the `afl-server.py` harness pattern
  (throw bytes at `receive_data`, accept only "ok or RemoteProtocolError") is
  the right invariant for our fuzz lane.

---

## 5. HTTP dictionaries for fuzzing (google/fuzzing = oss-fuzz nginx; haproxy; h2o; civetweb) — (TIER 2)

- google/fuzzing `dictionaries/http.dict` — https://github.com/google/fuzzing/blob/master/dictionaries/http.dict
  — Apache-2.0 (API `spdx_id`), 152 lines. Byte-identical in content to
  OSS-Fuzz `projects/nginx/fuzz/http_request_fuzzer.dict` (152 lines,
  Apache-2.0, "# Sources: https://en.wikipedia.org/wiki/List_of_HTTP_header_fields",
  verbs GET..TRACE, WebDAV verbs ACL/BASELINE-CONTROL/BIND/..., header
  fields). Also `dictionaries/url.dict`.
- AFL++ `dictionaries/http.dict` — https://github.com/AFLplusplus/AFLplusplus/blob/stable/dictionaries/http.dict
  — repo license **AGPL-3.0**; 119 lines; `diff` shows it is a strict
  *subset* of google/fuzzing's (missing the WebDAV verbs etc.). **Do not
  vendor** (license) — it adds nothing over the Apache-2.0 copy.
- OSS-Fuzz haproxy `projects/haproxy/fuzz_h1_parse.dict` — Apache-2.0, 93
  lines, methods with trailing space, versions, line endings `"\x0d\x0a"`
  `"\x0a"` `"\x0d\x0a\x0d\x0a"`, framing headers `"Host: " "Content-Length: "
  "Transfer-Encoding: " "Connection: " "Upgrade: "`. `build.sh` lines 46-63
  also `printf`s 15 seed messages (first byte 0=req/1=resp): get_simple,
  post_cl, post_chunked, get_multi, get_http10, websocket, connect, head,
  options, resp_200, resp_301, resp_chunked, resp_connclose, resp_100,
  resp_204 — a tidy minimal seed set.
- h2o `fuzz/http.dict` — MIT, 2712 lines (see §2).
- civetweb `fuzztest/http1.dict` — https://github.com/civetweb/civetweb/tree/master/fuzztest
  — 55 lines; LICENSE.md is a multi-license file ("Civetweb License ...
  Included with all features", MIT-style); API says NOASSERTION.
  `fuzztest/http1/` holds only 2 seeds (`GET_root.bin` 26 B, `GET_test.bin`
  18 B) and the README admits "useful initial corpus and directory" is an
  open issue.

Covers: token vocabulary for a mutational fuzzer; nothing else.

Adaptation: (c) — a later fuzz lane that mutates the libhtp/h2o seeds with
dictionary tokens against the sans-I/O driver. Vendor google/fuzzing's
`http.dict` (Apache-2.0, 152 lines) and haproxy's `fuzz_h1_parse.dict`
(Apache-2.0, 93 lines) with a PROVENANCE line each; h2o's is MIT but 2.7K
lines and heavily h2o-shaped — fetch on demand.

---

## 6. narfindustries/http-garden — differential-fuzzing harness + TROPHIES payload list  (TIER 3, license)

- URL: https://github.com/narfindustries/http-garden ; paper
  https://arxiv.org/abs/2405.17737 (The HTTP Garden, Kallus et al.)
- License: **GPL-3.0** (API `spdx_id`), pushed 2026-05-28, 942 stars.
- Paths: `TROPHIES.md` (877 lines; 86 lines match `payload|\\r\\n`; each
  bug entry has a "Payload:" line, e.g.
  ``GET / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0_2e\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n0\r\n\r\n``
  for "the Python int constructor is used to parse chunk-sizes"),
  `quirks.yml` (machine-readable per-server acceptable quirks:
  `allows-http-0-9`, `allows-missing-host-header`, `joins-duplicate-headers`,
  `method-whitelist`, ...), `tools/mutations.py`, `tools/fanout.py`,
  `tools/http1.py`, `images/` (one Dockerfile per target server),
  `docker-compose.yml`.

Covers: the best public checklist of *real* HTTP/1.1 parser discrepancies
that became CVEs — chunk-size syntax (`0x`, `_`, `+`, `-`), NUL/CR/LF in
header values, bare-LF chunk terminators, TE+CL handling, whitespace before
colon, HTTP/0.9 acceptance, etc. No fixture files; payloads are inline in
Markdown.

Adaptation:
- (b) fit: the Garden's model is exactly "black-box against a port"; adding
  our server as an image (`images/<name>/Dockerfile`) later would give
  free differential testing against ~40 servers. GPL is irrelevant for
  *running* it.
- (c): the payloads are one-line request strings; author our own tests from
  the *behaviours* described (a byte string is not the copyrightable part,
  but keep the BSD-3 repo clean: do not copy TROPHIES.md). Tier 3 because of
  license and because nothing is vendorable as data.

---

## 7. h2o/picohttpparser `test.c` — small parser tests with per-byte chunked-decoder replay  (TIER 3)

- URL: https://github.com/h2o/picohttpparser (pushed 2026-04-06, not archived)
- License: dual MIT / Perl, stated **in source headers only** (no LICENSE
  file in the root listing: `.clang-format .github .gitignore .gitmodules
  Jamfile Makefile README.md bench.c misc picohttpparser.c picohttpparser.h
  picohttpparser.xcodeproj picotest test.c`). `test.c` line 3-7:
  "Copyright (c) 2009-2014 Kazuho Oku, Tokuhiro Matsuno, Daisuke Murase, ...
  The software is licensed under either the MIT License (below) or the Perl
  license."
- Paths: `test.c` (539 lines): `test_request`, `test_response`,
  `test_headers`, `test_chunked` (+ `_consume_trailer`, `_leftdata`,
  `_overhead`); 70 `PARSE(` cases, 125 `ok(` assertions, 7 `subtest(`.

Evidence: `rg -n '^static void test_|^int main' dl/pico-test.c` →
test_request:44 test_response:162 test_headers:265 test_chunked_at_once:300
test_chunked_per_byte:329 test_chunked_failure:368 test_chunked:405
test_chunked_consume_trailer:436 test_chunked_leftdata:452
test_chunked_overhead:508. `PARSE(` count 70; `ok(` 125.

Notable: `PARSE(s, last_len, exp, comment)` tests partial-input return (-2)
vs error (-1) with a `last_len` resume argument (picohttpparser re-parses
from the start; it is *not* incremental), and `test_chunked_per_byte` feeds
the chunked decoder one byte at a time — a compact every-boundary test for
the chunked body path. Comments: "bare lf cannot be used in chunk header",
"bare lf is allowed in trailers".

Redundancy with llhttp: near-total for request/response lines; the chunked
decoder tests overlap llhttp's transfer-encoding.md. No fuzz corpus in the
repo; OSS-Fuzz has no `picohttpparser` project (404). Reference only.

---

## 8. seanmonstar/httparse (Rust) — request-target byte-acceptance table + fuzz targets without seeds  (TIER 3)

- URL: https://github.com/seanmonstar/httparse (pushed 2026-06-30)
- License: Apache-2.0 OR MIT (`LICENSE-APACHE`, `LICENSE-MIT` in tree).
- Paths: `src/lib.rs` (2783 lines, 53 `#[test]`, 44 `req!`/`res!` macro
  cases: test_request_simple, _with_query_params, _with_whatwg_query_params,
  _headers, _headers_optional_whitespace, _headers_max, _multibyte,
  _one_byte_method, _partial_method, _method_no_delimiter, _method_only,
  _partial, _partial_version, _method_path_no_delimiter, _method_path_only,
  _partial_parses_headers_as_much_as_it_can, _newlines,
  _empty_lines_prefix(_lf_only), _path_backslash,
  _with_invalid_token_delimiter, _with_invalid_but_short_version,
  _with_empty_method/_path/_method_and_path; response: _simple, _newlines,
  _reason_missing(_no_space)(_with_headers), _reason_with_space_and_tab,
  _reason_with_obsolete_text_byte, _reason_with_nul_byte,
  _version_missing_space, _code_missing_space,
  _partial_parses_headers_as_much_as_it_can, _empty_lines_prefix_lf_only,
  _no_cr); `tests/uri.rs` (3692 lines, **264** `req!` cases — one per
  request-target byte/character class: which bytes are accepted in the
  path); `fuzz/fuzz_targets/{parse_request,parse_response,parse_headers,
  parse_chunk_size,parse_request_multspaces,parse_response_multspaces}.rs`
  (6 targets, **no corpus or dictionary directory**; OSS-Fuzz
  `projects/httparse/build.sh` just `cargo fuzz build`s and copies the six
  binaries).

Covers: partial-input boundaries, lenient/strict variants (multiple spaces,
empty reason), a fine-grained request-target byte table. The `tests/uri.rs`
table is the one non-redundant asset: a per-byte accept/reject oracle for
request-target that could be compared against llhttp's `uri.md` (11
fixtures) and against uriparse.

Format: Rust code; the `req!` macros are regular enough to scrape (`req! {
name, b"...", |req| { asserts } }`) but hand-porting 264 near-identical
one-byte cases is not worth it: generate our own byte-class table from RFC
3986/9112 and use httparse's as a cross-check. Tier 3.

---

## 9. MagicStack/httptools tests — llhttp binding tests, fragmented-feed examples  (TIER 3)

- URL: https://github.com/MagicStack/httptools (pushed 2026-05-25)
- License: MIT.
- Paths: `tests/test_parser.py` (694 lines, 41 tests), vendors llhttp at
  `vendor/llhttp` (a git submodule; version not readable via raw URL).
- Test names: response_1/1b/2/3/4/5, leninent_headers_1/2, cb_on_status_1,
  cb_on_body_1, cb_on_message_complete_1, upgrade_response_1,
  request_chunked_1/2/3, request_chunked_cb_error_1/2, request_upgrade_1,
  request_upgrade_flag, request_error_in_on_header /
  _on_message_begin / _cb_on_url / _cb_on_headers_complete, request_2/3/4,
  request_fragmented, request_fragmented_header, request_fragmented_value,
  request_fragmented_bytes, url_1..10, url_too_long.

Covers: what happens when a *callback* raises mid-parse (error propagation
paths), upgrade delivery (`HttpParserUpgrade` carries the offset of the
leftover bytes), a handful of fragmented feeds. Fully redundant with llhttp
at the byte level (it *is* llhttp). The callback-error tests are a pattern
worth copying for chez-httparse's `callback-failure` path, nothing to
vendor. Tier 3.

---

## 10. bahruzjabiyev/t-reqs — grammar-based HTTP/1 request fuzzer (CCS 2021)  (TIER 3)

- URL: https://github.com/bahruzjabiyev/t-reqs ; paper
  https://dl.acm.org/doi/10.1145/3460120.3485384
- License: MIT (API `spdx_id`), pushed 2024-10-30.
- Paths: `config` (a Python config with `config.grammar = {...}`: `<start>`,
  `<request>`, `<request-line>`, `<method-name>` GET..PATCH, `<version>`
  0.9/1.0/1.1/2.0/3.0, ...), `misc/example-request-line-grammar`,
  `misc/example-request-headers-grammar`, `misc/example-request-body-grammar`,
  `code/{main,input_tree,input_tree_mutator,input_tree_node,feedback-server,
  helper_functions}.py`. **No corpus files.**

Covers: generative + mutational (delete/replace/insert at tree level) HTTP/1
request fuzzing, sent over the network to one or more targets; the
differential comparison is done by hand on responses.

Adaptation: (b) only — point it at our port in a later "external fuzzers"
lane; the CFG could seed our own generator. Related academic tools checked:
- HDiff https://github.com/mo-xiaoxi/HDiff — **GPL-3.0**, pushed 2022-06-07;
  `data/SR/*.csv` are RFC requirement sentences (1945, 2068, 2616, 7230-7235
  ...), `data/abnf/*.txt` ABNF; no request corpus.
- HDHunter https://github.com/mukeran/HDHunter (USENIX Security 2025,
  "The Silent Danger in HTTP") — MIT, pushed 2025-02-18; `example_seeds/
  example{1,2,3}` are three ordinary requests (keep-alive GET, CL POST with
  `Connection: close`, chunked POST); a Vagrant VM with instrumented targets;
  no corpus.
None of the three ships a reusable request corpus; the published artefacts
are fuzzers, not data.

---

## Examined and set aside (with reasons)

- **OSS-Fuzz `projects/nginx`** — `fuzz/http_request_fuzzer.cc` is a
  libprotobuf-mutator target (`http_request_proto.proto`: `message HttpProto
  { required string request = 1; required string reply = 2; }`); no seed
  corpus in the project dir; only the dictionary (see §5).
- **OSS-Fuzz `projects/apache-httpd`** (`fuzz_request.c`, `fuzz_parse.c`,
  `fuzz_uri.c`, ...), **`projects/lighttpd`** (`fuzz_request.c`: first byte
  selects scheme port and `parseopts`, then the rest is the header block),
  **`projects/haproxy`** (`fuzz_h1_parse.c`: "We use the first byte of fuzz
  input to select between request and response parsing modes"),
  **`projects/mongoose`** (honggfuzz netdriver against a live listener) —
  harness *designs* only, no corpora. The "first byte selects mode" idiom
  is worth copying for a (c) fuzz harness.
- **OSS-Fuzz `projects/nodejs/fuzz_sources/fuzz_httpparser1.cc`** — fuzzes
  Node's llhttp binding; no corpus.
- **envoyproxy/envoy `test/common/http/http1/http1_connection_corpus/`** —
  72 cases, Apache-2.0, but they are Envoy-shaped (`:scheme:`, `-force-trace`,
  `early-data` pseudo-headers) and the fuzzer is protobuf-driven; the older
  `codec_impl_corpus` path returns 404. Reference only.
- **yhirose/cpp-httplib `test/fuzzing/corpus/`** — 15 files (3 hand seeds +
  ClusterFuzz-minimized cases), MIT, `server_fuzzer.dict` 223 lines. Too
  small to matter.
- **OSF-Fuzz `projects/picohttpparser`, `projects/hyper`** — do not exist
  (empty listings).
- **h11 `fuzz/afl-server-examples`** — 4 seeds, trivially small (see §4).

## Fit matrix

| Corpus | (a) loopback | (b) black-box | (c) sans-I/O replay | Tier |
|---|---|---|---|---|
| llhttp fixtures (vendored) | – | – | yes (already) | 1 |
| libhtp `test/files/*.t` | yes | – | **yes** | 1 |
| h2o `fuzz/http1-corpus` | soak | – | crash-only | 2 |
| http-parser `test.c` oracles | – | – | yes (transcribe) | 2 |
| h11 tests | scenarios | – | scenarios | 2 |
| HTTP dictionaries | – | – | fuzz lane | 2 |
| HTTP Garden | – | yes (later) | payload ideas | 3 |
| picohttpparser | – | – | pattern | 3 |
| httparse | – | – | uri table cross-check | 3 |
| httptools | – | – | pattern | 3 |
| T-Reqs / HDiff / HDHunter | – | yes (later) | – | 3 |

## Recommendation for the first milestones

1. Keep llhttp as the parser oracle through chez-httparse (no re-vendor).
2. Vendor libhtp's 102 `.t` files + `LICENSE` + `PROVENANCE` (pin commit on
   `0.5.x`, note the archive/EOL), write the `>>>`/`<<<` loader as the first
   input format of the (c) driver, and hand-author oracles for the
   connection-level files (07, 08, 09, 12, 15, 16, 21-24, 35, 36-38, 61-66,
   85, 86, 89-92, 97, 99).
3. Port h11's `test_connection.py` scenarios as the (c)/(a) behavioural spec
   for keep-alive / pipelining / close / upgrade / 100-continue.
4. Transcribe http-parser's `should_keep_alive` / `message_complete_on_eof`
   / `upgrade` columns (77 rows) as a keep-alive decision table test.
5. Defer h2o's corpus and the dictionaries to a fuzz lane once the driver
   exists; defer HTTP Garden / T-Reqs to an external black-box lane.

## Commands run (for reproducibility)

```
cd /Users/yuzu/github/llhttp && git log -1 --format='%H %cd %s' && git describe --tags
rg -c '^```http' test/request/*.md test/response/*.md ; rg -c '^```url' test/url.md
cat /Users/yuzu/github/chez-httparse/.plans/decisions/0007-llhttp-corpus-vendored-as-data.md
cat /Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE
curl -sSL -o dl/http-parser-test.c https://raw.githubusercontent.com/nodejs/http-parser/main/test.c
curl -sSL https://api.github.com/repos/nodejs/http-parser | rg '"archived"|"spdx_id"|"pushed_at"'
curl -sSL -o dl/pico-test.c https://raw.githubusercontent.com/h2o/picohttpparser/master/test.c
curl -sSL "https://api.github.com/repos/seanmonstar/httparse/git/trees/master?recursive=1"
curl -sSL -o dl/httparse-lib.rs https://raw.githubusercontent.com/seanmonstar/httparse/master/src/lib.rs
curl -sSL -o dl/httparse-uri.rs https://raw.githubusercontent.com/seanmonstar/httparse/master/tests/uri.rs
curl -sSL "https://api.github.com/repos/MagicStack/httptools/git/trees/master?recursive=1"
curl -sSL -o dl/httptools-test_parser.py https://raw.githubusercontent.com/MagicStack/httptools/master/tests/test_parser.py
curl -sSL "https://api.github.com/repos/python-hyper/h11/git/trees/master?recursive=1"
curl -sSL -o dl/h11-test_connection.py https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_connection.py
gh api repos/h2o/h2o/contents/fuzz ; gh api repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784
curl -sSL -o dl/h2o-driver.cc https://raw.githubusercontent.com/h2o/h2o/master/fuzz/driver.cc
curl -sSL https://raw.githubusercontent.com/h2o/h2o/master/fuzz/README.md
gh api repos/google/oss-fuzz/contents/projects/{llhttp,nginx,apache-httpd,h2o,httparse,h11,libhtp,civetweb,mongoose,lighttpd,haproxy,cpp-httplib,nodejs}
curl -sSL https://raw.githubusercontent.com/google/oss-fuzz/master/projects/{nginx,haproxy,libhtp,llhttp,...}/build.sh
gh api repos/OISF/libhtp ; gh api repos/OISF/libhtp/contents/test/files
curl -sSL -o dl/libhtp-test.c https://raw.githubusercontent.com/OISF/libhtp/0.5.x/test/test.c
curl -sSL -o dl/libhtp-test_main.cpp https://raw.githubusercontent.com/OISF/libhtp/0.5.x/test/test_main.cpp
gh api repos/narfindustries/http-garden ; curl -sSL -o dl/http-garden-TROPHIES.md https://raw.githubusercontent.com/narfindustries/http-garden/main/TROPHIES.md
gh api repos/bahruzjabiyev/t-reqs ; gh api repos/mo-xiaoxi/HDiff ; gh api repos/mukeran/HDHunter
gh api repos/AFLplusplus/AFLplusplus --jq '.license.spdx_id' ; gh api repos/google/fuzzing --jq '.license.spdx_id'
curl -sSL -o dl/google-fuzzing-http.dict https://raw.githubusercontent.com/google/fuzzing/master/dictionaries/http.dict
curl -sSL -o dl/aflpp-http.dict https://raw.githubusercontent.com/AFLplusplus/AFLplusplus/stable/dictionaries/http.dict
```

Web searches used (results only for discovery; every claim above was then
verified by fetching the repo/API):
- "HTTP Garden differential testing HTTP/1.1 parsers github narfindustries" → https://arxiv.org/abs/2405.17737, https://github.com/narfindustries/http-garden
- "T-Reqs HTTP request smuggling grammar-based fuzzer github CCS 2021 Jabiyev" → https://github.com/bahruzjabiyev/t-reqs, https://dl.acm.org/doi/10.1145/3460120.3485384
- "HDiff semantic gap attacks HTTP implementations differential fuzzing DSN 2022 code github" → https://github.com/mo-xiaoxi/HDiff
- "Identifying HTTP Desync Vulnerabilities gray-box USENIX Security 2025 Mu artifact github" → https://www.usenix.org/conference/usenixsecurity25/presentation/mu, https://github.com/mukeran/HDHunter
