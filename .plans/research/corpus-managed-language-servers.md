# Corpus survey: managed-language HTTP/1 servers (connection-semantics test suites)

Lens: managed-language-servers. Date measured: 2026-09-19. Author: corpus-finder subagent.

Target: chez-http-server (R6RS Scheme, Chez 10.4.1) composed from chez-libuv v0.5.0, chez-httparse v0.2.0 (274 llhttp v9.4.3 fixtures already pass), uriparse, byte-machine. The server will be tested (a) in-process over loopback TCP using chez-libuv client verbs, (b) black-box from external clients, (c) with a sans-I/O connection driver that replays byte streams at every chunk size.

Every count below was measured on a local checkout (SHA recorded) with the exact command shown. Nothing is from memory. Licenses come from the GitHub API `license.spdx_id` field plus the LICENSE file on disk.

## 0. Method and provenance

Scratch checkouts live under `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/corpus-dl/<name>` (nothing was written into any sibling git repository). Supporting TSVs are next to this report in `.../scratchpad/research/`:

- `licenses.tsv` (gh API license/branch/pushed_at per repo)
- `go-net-http-tests.tsv`, `netty-codec-http-tests.tsv`, `kestrel-core-tests.tsv`, `kestrel-inmemory-tests.tsv`, `node-test-http.tsv` (413 rows), `node-raw-socket-server-tests.txt` (55 rows)

### Commands used to confirm repos and licenses (verbatim output)

```
$ for r in nodejs/node golang/go hyperium/hyper python-hyper/h11 python/cpython aio-libs/aiohttp yesodweb/wai netty/netty dotnet/aspnetcore ninenines/cowboy mtrudel/bandit puma/puma; do printf "%-22s " "$r"; gh api "repos/$r" --jq '[.license.spdx_id, .default_branch, .html_url, .pushed_at] | @tsv'; done
nodejs/node            NOASSERTION	main	https://github.com/nodejs/node	2026-09-19T10:23:15Z
golang/go              BSD-3-Clause	master	https://github.com/golang/go	2026-09-19T06:12:59Z
hyperium/hyper         MIT	master	https://github.com/hyperium/hyper	2026-09-18T19:08:35Z
python-hyper/h11       MIT	master	https://github.com/python-hyper/h11	2025-04-24T23:29:20Z
python/cpython         NOASSERTION	main	https://github.com/python/cpython	2026-09-19T10:37:07Z
aio-libs/aiohttp       Apache-2.0	master	https://github.com/aio-libs/aiohttp	2026-09-19T01:38:41Z
yesodweb/wai           MIT	master	https://github.com/yesodweb/wai	2026-09-18T10:13:16Z
netty/netty            Apache-2.0	4.2	https://github.com/netty/netty	2026-09-19T09:36:55Z
dotnet/aspnetcore      MIT	main	https://github.com/dotnet/aspnetcore	2026-09-19T04:31:13Z
ninenines/cowboy       ISC	master	https://github.com/ninenines/cowboy	2026-09-16T09:02:05Z
mtrudel/bandit         MIT	main	https://github.com/mtrudel/bandit	2026-09-14T19:52:51Z
puma/puma              BSD-3-Clause	main	https://github.com/puma/puma	2026-09-16T01:31:28Z
```

`NOASSERTION` for Node and CPython is because their LICENSE files are composite. Verified on disk:
- `node/LICENSE` lines 1-20: "Node.js is licensed for use as follows: ... Copyright Node.js contributors ... Permission is hereby granted, free of charge ..." (MIT text) followed by per-dependency licenses. The individual test files carry a Joyent MIT header (see `test-http-1.0-keep-alive.js` lines 1-20 quoted in section 1).
- `cpython/LICENSE` line 73: `PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2` (SPDX `PSF-2.0`).

### Checkout SHAs (all fetched 2026-09-19)

```
node         357ba2f676126e2c0e54dca4c47085fce975836b   (sparse: test/parallel test/common test/fixtures/keys test/sequential)
go           46f508b3aa365918ac78a63340ce2343306835af   (sparse: src/net/http)
hyper        e89d0d93d9566210ee95aea234a00952ebc4a202   (Cargo.toml: version = "1.11.1")
h11          62c5068c971579d61fa1b55373390e12f25fd856   (h11/_version.py: "0.16.0+dev")
aiohttp      3497f81087cc8dee900f22cc4c431ccba6aff419   (__version__ = "4.0.0a2.dev0")
wai          9581c256dc343ab8793094fa008626db24f69633   (warp/warp.cabal: version 3.4.16)
netty        b3231b36da1963fcedcba1f99521fb6e3bf1dfa7   (branch 4.2; pom.xml:29 <version>4.2.19.Final-SNAPSHOT</version>)
aspnetcore   1fcd7ef305697a1888f3ede076010350ae9f4f8d   (sparse: src/Servers/Kestrel/{Core/test,test/InMemory.FunctionalTests,shared/test})
cowboy       c965d1a3bffa0708b0570e83233ddd3bf77b97c1   (Makefile: PROJECT_VERSION = 2.19.0)
bandit       22dade4353ee7b3635975d0d3670c85ab30b0dd4   (mix.exs: version: "1.12.5")
puma         306daddfd07fdf0ca902eb7ea89ceb7dd6139050   (lib/puma/const.rb:103 PUMA_VERSION = "8.0.2")
cpython      5b343636bae9b89cb5632ca07b01e1570e24653d   (main; only the two test files + LICENSE fetched via raw.githubusercontent.com)
```

Directory listings were additionally confirmed through the GitHub contents API (WebFetch of `https://api.github.com/repos/<owner>/<repo>/contents/<path>` for h11, hyper, bandit, cowboy, puma, warp; `gh api` for the rest). Every path named below exists at the SHA above.

---

## 1. Node.js `test/parallel/test-http-*.js` — Tier 2 (server layer, (a)/(b))

- URL: https://github.com/nodejs/node/tree/main/test/parallel
- License: MIT (node/LICENSE lines 1-20; per-file Joyent MIT header on older tests)
- Paths: `test/parallel/test-http-*.js` (413 files), `test/sequential/test-http-*.js` (7 files), harness `test/common/` (428K).

Measured:
```
$ ls node/test/parallel | rg -c '^test-http-'
413
$ gh api "repos/nodejs/node/git/trees/$TEST_SHA" --jq '.truncated'
false
$ rg -l 'net\.(connect|createConnection)\(' test-http-*.js | wc -l
      61
$ rg -l 'net\.(connect|createConnection)\(' test-http-*.js | xargs rg -l 'http\.createServer|http\.Server' | wc -l
      55
$ rg -L 'net\.(connect|createConnection)\(' test-http-*.js | wc -l
      81        # files that only use Node's own http client (harder to port)
$ cat test-http-*.js | wc -l
   25164
$ ls sequential | rg '^test-http-'
test-http-econnrefused.js test-http-keep-alive-large-write.js test-http-keepalive-maxsockets.js test-http-regr-gh-2928.js test-http-server-keep-alive-timeout-slow-client-headers.js test-http-server-keep-alive-timeout-slow-server.js test-http-server-request-timeouts-mixed.js
```
Theme buckets by filename (`ls test-http-*.js | rg -c -- "$k"`): keep-alive 21, keepalive 11, pipelin 11, chunk 10, timeout 42, upgrade 11, expect 4, parser 17, invalid 10, server- 55, content-length 9, transfer-encoding 2, close 18, destroy 14, abort 22, max-header 5, smuggl 4, insecure 3, response-splitting 1, 1.0 2.

The 55 server-side raw-socket files (server = `http.createServer`, client = `net.connect` writing literal bytes) are listed in `node-raw-socket-server-tests.txt`. Representative shapes:

`test-http-server-reject-chunked-with-content-length.js` (whole file, 29 lines): writes `POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n`, expects `clientError` with `err.code === 'HPE_INVALID_TRANSFER_ENCODING'` and **no bytes** written back before close.

`test-http-request-smuggling-content-length.js` (whole file): writes `GET / HTTP/1.1\r\nHost: localhost:5000\r\nContent-Length : 5\r\n\r\nhello` and asserts the exact response bytes `HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n`.

`test-http-1.0-keep-alive.js` lines 27-80: a data-driven `check([{name, requests:[{expectClose, data}], responses:[{headers, chunks}]}])` table for HTTP/1.0 keep-alive decisions (TE: chunked, Transfer-Encoding: chunked, Content-Length variants). Other data-driven files found by `rg -l "^check\(\[|^const tests = \[|..."`: test-http-1.0-keep-alive.js test-http-decoded-auth.js test-http-expect-handling.js test-http-host-header-ipv6-fail.js test-http-response-status-message.js test-http-server-keep-alive-timeout.js test-http-set-timeout-server.js test-http-server-unconsume.js test-http-status-code.js test-http-upgrade-advertise.js.

`test-http-server-keep-alive-timeout.js` lines 27-56: pipelines `GET /1`, `/2`, `/3` on one `net.connect` socket with `server.keepAliveTimeout = 50` and `allowHalfOpen: true`, expects timeout callback after all three.

Timeout family (11 files): test-http-server-headers-timeout-{delayed-headers,interrupted-headers,keepalive,pipelining}.js, test-http-server-request-timeout-{delayed-body,delayed-headers,interrupted-body,interrupted-headers,keepalive,pipelining,upgrade}.js — these encode headersTimeout/requestTimeout semantics across keep-alive and pipelining, directly relevant to the header/body/idle timeout policies in the architecture doc section 11.

`test-http-pipeline-flood.js` lines 1-60: flood-prevention test — server corks reads when the write side returns false; child process floods pipelined requests. This is the Node analogue of our uv-read-stop!/write-queue-size backpressure design.

Coverage: HTTP/1.0 keep-alive matrix, pipelining + timeouts, chunked/CL smuggling (4 files), invalid TE, CR-without-LF rejection, missing header separators, header count/size limits (max-headers-count-overflow, max-http-headers), response splitting, upgrade server side, EOF-on-connect, status-message, trailers, 304 with chunked.

Fit: (a) and (b). Each file is an end-to-end socket script; the 55 raw-socket files translate 1:1 into "write bytes; expect bytes/close/no-bytes" tests. Not (c): assertions are made through Node's server events (`clientError`, `err.code` values from llhttp) rather than on a byte-stream driver, though the expected llhttp error codes map directly to chez-httparse error names.

Extraction effort: manual, per file (JS with Node event API). ~55 files × ~40 lines. The 10 data-driven files are near-mechanical. The remaining ~350 files depend on Node's http client/agent and are reference only.

Tier 2. Node is also the home of llhttp, so its parser-level cases (`test-http-parser*.js`, 11 files) largely duplicate the llhttp fixtures we already vendor.

---

## 2. Go `net/http` server tests and byte-level tables — Tier 1 for the pure-data tables, Tier 2 for `serve_test.go` (server layer, (a)/(b)/(c))

- URL: https://github.com/golang/go/tree/master/src/net/http
- License: BSD-3-Clause (`go/LICENSE`: "Copyright 2009 The Go Authors. Redistribution and use in source and binary forms..."; also `PATENTS`)
- Paths: `src/net/http/serve_test.go` (243,605 B), `server_test.go` (7,538 B; mux/handshake only), `http1_server_test.go`, `readrequest_test.go`, `request_test.go`, `transfer_test.go`, `response_test.go`, `responsewrite_test.go`, `requestwrite_test.go`, `clientserver_test.go`.

Measured:
```
$ for f in serve_test.go server_test.go http1_server_test.go request_test.go readrequest_test.go transfer_test.go response_test.go responsewrite_test.go requestwrite_test.go clientserver_test.go; do printf "%4d  %s\n" "$(rg -c '^func (Test|test)[A-Za-z0-9_]*\(' "$f")" "$f"; done
 280  serve_test.go
   7  server_test.go
   1  http1_server_test.go
  53  request_test.go
   2  readrequest_test.go
   5  transfer_test.go
   8  response_test.go
   2  responsewrite_test.go
   5  requestwrite_test.go
  76  clientserver_test.go
$ rg -n '^var (reqTests|respTests|...)' *.go
response_test.go:39:var respTests = []respTest{
response_test.go:799:var readResponseCloseInMiddleTests = []struct {
readrequest_test.go:30:var reqTests = []reqTest{
readrequest_test.go:460:var badRequestTests = []struct {
requestwrite_test.go:33:var reqWriteTests = []reqWriteTest{
reqTests entries: 16      respTests entries: 23     badRequestTests: 5 (counted by eye from lines 460-483)
TestServerValidatesHeaders rows: 18   TestServerValidatesHostHeader rows: 25
TestInvalidChunkedBodies rows: 2      serverExpectTests entries: 9 (8 expectTest() + 1 literal)
$ rg -c 'net.Dial\(|ts.Listener.Addr|conn.Write\(\[\]byte|io.WriteString\(conn|newTestConn\(|testConn' serve_test.go
79
```

Pure-data tables worth vendoring now:
- `readrequest_test.go:18-24` struct `reqTest{Raw string; Req *Request; Body string; Trailer Header; Error string}`; 16 entries (raw request bytes → expected method/URL/proto/headers/Close/ContentLength/body/trailer/error). Byte-exact; ideal for (c).
- `readrequest_test.go:460-483` `badRequestTests`: bad_connect_host, smuggle_two_contentlen, smuggle_two_content_len_head, leading_space_in_header, leading_tab_in_header (helper `reqBytes` at line 455 normalises `\n`→`\r\n`).
- `response_test.go:39` `respTests` (23 entries): raw response bytes → expected Response (for our loopback test client's response reader) and `readResponseCloseInMiddleTests` at line 799.
- `serve_test.go:5414` `TestServerValidatesHeaders`: 18 rows of `{header string, want int}` e.g. `{"Foo : bar\r\n", 400}`, `{": empty key\r\n", 400}`, `{"Foo: " + 2MiB + "\r\n", 431}`; `serve_test.go:5300` `TestServerValidatesHostHeader`: 25 rows; `serve_test.go:2180` `serverExpectTests`: 9 rows (100-continue case-insensitivity, `a-pony` → 417, Expect with chunked body); `serve_test.go:7868` `TestInvalidChunkedBodies`: "bare LF in chunk size" `1\na\r\n0\r\n\r\n`, "bare LF at body end" `1\r\na\r\n0\r\n\n`.

Server-semantics tests in `serve_test.go` (names from `rg -n '^func Test' serve_test.go`): TestServerTimeouts:742, TestServerReadTimeout:948, TestServerWriteTimeout:1033, TestServeHTTP10Close:1482, TestHandlersCanSetConnectionClose11/10:1497/1503, TestHTTP10KeepAlive204Response:1520, TestHTTP11KeepAlive204Response:1524, TestHTTP10KeepAlive304Response:1528, TestKeepAliveFinalChunkWithEOF:1535, TestHeadResponses:1690, TestServerExpect:2212, TestServerUnreadRequestBodyLittle/Large:2310/2351, TestRequestBodyReadErrorClosesConnection:2565, TestInvalidTrailerClosesConnection:2596, TestRequestBodyTimeoutClosesConnection:2721, TestRequestHeaderValueCountLimit:3457, TestServerBufferedChunking:3739, TestServerGracefulClose:3761, TestContentLengthZero:3851, TestCloseNotifierPipelined:3923, TestHTTP10ConnectionHeader:4457, TestServerConnState:4761, TestServerKeepAliveAfterWriteError:5065, TestNoContentLengthIfTransferEncoding:5119, TestServerIdleTimeout:6102, TestServerShutdown:6239, TestUnsupportedTransferEncodingsReturn501:6918, TestDisableKeepAliveUpgrade:7173, TestWriteHeaderSwitchingProtocols:7239, TestServerReadAfterWriteHeader100Continue:7729, TestServerReadAfterHandlerDone100Continue:7760, TestServerExpect100ContinueUnreadBody:7815, TestInvalidChunkedBodies:7868, TestServerConnectionReuse:7990, TestServerAbortsWriteOnConnReadError:8515, TestServerIdleKeepAliveRequestContext:8639.

Fit: tables → (c) directly (byte in, verdict out) and (a) via loopback. serve_test.go cases → (a)/(b) after manual translation; many use `net.Dial` + raw writes (79 hits) but assertions go through Go handler API.

Extraction: tables are mechanical (a 1-hour script; Go string literals with `\r\n`). serve_test.go is manual, pick ~40 named above.

Tier 1 for the tables (vendor with PROVENANCE: repo, SHA 46f508b, BSD-3-Clause, file:line ranges); Tier 2 for serve_test.go.

---

## 3. hyperium/hyper `tests/server.rs` + `src/proto/h1` unit tests — Tier 2 (server layer, (a)/(b); conn.rs EOF tests are (c)-shaped)

- URL: https://github.com/hyperium/hyper/blob/master/tests/server.rs ; https://github.com/hyperium/hyper/tree/master/src/proto/h1
- License: MIT (`hyper/LICENSE`: "Copyright (c) 2014-2026 Sean McArthur / Permission is hereby granted, free of charge...")
- Paths: `tests/server.rs` (117,803 B), `tests/h1_server/{mod.rs,fixture.rs}`, `tests/h1_shutdown_while_buffered.rs`, `tests/h1_flush_before_yield.rs`, `tests/integration.rs` + `tests/support/mod.rs` (`t!` macro, 14 cases), `src/proto/h1/{conn.rs,decode.rs,dispatch.rs,encode.rs,io.rs,role.rs}`.

Measured:
```
$ for f in tests/server.rs tests/h1_server/mod.rs tests/h1_flush_before_yield.rs tests/h1_shutdown_while_buffered.rs tests/integration.rs tests/unbuffered_stream.rs tests/ready_on_poll_stream.rs; do printf "%4d  %s\n" "$(rg -c '#\[(tokio::)?test' "$f")" "$f"; done
  96  tests/server.rs
   0  tests/h1_server/mod.rs        (harness: in-memory Read/Write halves over mpsc, lines 1-80)
   1  tests/h1_flush_before_yield.rs
   1  tests/h1_shutdown_while_buffered.rs
   0  tests/integration.rs          (14 t!{} client<->server round-trips)
   1  tests/unbuffered_stream.rs
   1  tests/ready_on_poll_stream.rs
$ for f in src/proto/h1/*.rs; do printf "%4d  %s\n" "$(rg -c '#\[(tokio::)?test|#\[cfg\(test\)\]' "$f")" "$f"; done
  12  conn.rs   19  decode.rs   4  dispatch.rs   11  encode.rs   14  io.rs   0  mod.rs   28  role.rs
$ rg -c 'connect\(\)|TcpStream::connect|req.write_all|write_all\(b"' tests/server.rs
77
```

Harness shape (`tests/server.rs:3496` `struct Serve`, `:3757 fn connect(addr) -> TcpStream`, `:3768 fn serve() -> Serve`): a real TcpListener; tests open a std TcpStream and `write_all` literal request bytes, e.g. lines 38-56 `get_should_ignore_body` writes `GET / HTTP/1.1\r\nHost: example.domain\r\nConnection: close\r\n\r\nI shouldn't be read.\r\n` and asserts `server.body() == b""`; lines 691-731 `keep_alive` sends two requests on one socket, second with `Connection: close`, using `read_until(|buf| buf.ends_with(...))`.

HTTP/1 server-semantics test names (from `rg -n '^fn |^async fn ' tests/server.rs`): get_should_ignore_body:38, get_with_body:59, get_chunked_response_with_ka:418, post_with_content_length_body:460, post_with_invalid_prefix_content_length:478, post_with_chunked_body:498, post_with_chunked_overflow:524, post_with_incomplete_body:554, post_with_chunked_missing_final_digit:576, head_response_can_send_content_length:599, head_response_doesnt_send_body:628, response_does_not_set_chunked_if_body_not_allowed:658, keep_alive:691, http_10_keep_alive:731, http_10_close_on_no_ka:780, disable_keep_alive:818, header_connection_close:844, expect_continue_sends_100:877, expect_continue_accepts_upper_cased_expectation:910, expect_continue_but_http_10_is_ignored:943, expect_continue_but_no_body_is_ignored:976, expect_continue_waits_for_body_poll:1023, pipeline_disabled:1072, pipeline_enabled:1116, http_10_request_receives_http_10_response:1169, http_11_uri_too_long:1189, disable_keep_alive_mid_request:1206, disable_keep_alive_post_request:1260, http1_graceful_shutdown_after_upgrade:1309, empty_parse_eof_does_not_return_error:1370, nonempty_parse_eof_returns_error:1385, http1_allow_half_close:1403, disconnect_after_reading_request_before_responding:1437, returning_1xx_response_is_error:1464, header_name_too_long:1496, header_read_timeout_slow_writes:1513, header_read_timeout_starts_immediately:1560, header_read_timeout_slow_writes_multiple_requests:1581, header_read_timeout_as_idle_timeout:1657, upgrades:1701, http_connect:1757, upgrades_new:1810, upgrades_ignored:1879, parse_errors_send_4xx_response:2669 (`GE T / HTTP/1.1\r\n\r\n` → `HTTP/1.1 400 `), illegal_request_length_returns_400_response:2691 (`Content-Length: foo` → 400), max_buf_size:2730, max_buf_size_split_header_boundary:2757, graceful_shutdown_before_first_request_no_block:2789, streaming_body:2814, http1_response_with_http2_version:2839, skips_content_length_for_304_responses:2932, skips_content_length_and_body_for_304_responses:2955, no_implicit_zero_content_length_for_head_responses:2984, http1_trailer_send_fields:3206 ... http1_trailer_recv_keep_alive:3441 (7 trailer cases). Roughly 60 of the 96 are HTTP/1; the h2_* ones are not relevant.

`src/proto/h1/conn.rs` tokio tests (names): client_request_connection_close_disables_keep_alive, conn_reads_request_head, conn_reads_partial_request_head, conn_accepts_eof_when_idle, conn_rejects_eof_during_partial_head, client_rejects_eof_while_busy, server_accepts_eof_while_busy, conn_reads_empty_response_before_eof, conn_reads_body_and_reports_end, closed_conn_cannot_read_or_write, conn_writes_chunked_body. These are precisely the EOF-vs-state rules a libuv on-eof callback must implement (idle EOF = clean close; EOF mid-head = error; EOF after full request while responding = fine). `io.rs` has read_strategy_adaptive_* (adaptive read-buffer sizing) and `role.rs:1946 test_decoder_request` is an inline table of raw requests → body decoder kind (length/chunked/close-delimited/none).

Fit: (a)/(b) for server.rs; conn.rs cases are (c)-shaped but written against hyper's `Conn` type (in-memory `AsyncIo` mock).

Extraction: manual; the request bytes are inline `b"..."` literals; expectations depend on the `Serve` harness (`server.reply()`, `server.body()`), so each case needs a Scheme handler stub. ~60 cases, 1-2 days.

Tier 2. `tests/h1_server/fixture.rs` (16×64 KiB chunked streaming with chunk timeouts, `max_buf_size`) is a good template for our backpressure milestone.

---

## 4. python-hyper/h11 test suite — Tier 1 (connection layer, (c) first, then (a))

- URL: https://github.com/python-hyper/h11/tree/master/h11/tests
- License: MIT (`h11/LICENSE.txt`: "The MIT License (MIT) / Copyright (c) 2016 Nathaniel J. Smith <njs@pobox.com> and other contributors")
- Paths: `h11/tests/test_connection.py` (38,149 B), `test_state.py` (8,928 B), `test_io.py` (17,246 B), `test_headers.py`, `test_receivebuffer.py`, `test_events.py`, `helpers.py` (ConnectionPair), `test_against_stdlib_http.py`, `data/test-file`.

Measured:
```
$ for f in h11/tests/test_*.py; do printf "%4d  %s\n" "$(rg -c '^\s*def test_' "$f")" "$f"; done
   2  h11/tests/test_against_stdlib_http.py
  28  h11/tests/test_connection.py
   3  h11/tests/test_events.py
   3  h11/tests/test_headers.py
   1  h11/tests/test_helpers.py
  17  h11/tests/test_io.py
   2  h11/tests/test_receivebuffer.py
  10  h11/tests/test_state.py
   6  h11/tests/test_util.py
$ rg -c 'pytest.mark.parametrize' h11/tests/*.py   -> test_receivebuffer.py:1, test_connection.py:2
$ awk '/^SIMPLE_CASES = /,/^\]/' h11/h11/tests/test_io.py | rg -c '^\s+\('   -> 10
```

Connection-semantics test names (`test_connection.py`): test__keep_alive:30, test__body_framing:60, test_Connection_basics_and_content_length:104, test_chunked:171, test_chunk_boundaries:202, test_client_talking_to_http10_server:241, test_server_talking_to_http10_client:257, test_automatic_transfer_encoding_in_response:294, test_automagic_connection_close_handling:336, test_100_continue:368, test_max_incomplete_event_size_countermeasure:413, test_reuse_simple:489, test_pipelining:522, test_protocol_switch:594, test_close_simple:719, test_close_different_states:760, test_pipelined_close:826, test_sendfile:868, test_errors:904, test_idle_receive_nothing:974, test_connection_drop:981, test_408_request_timeout:990, test_empty_request:998, test_empty_response:1006, test_early_detection_of_invalid_request:1022 (parametrized: `b"\x00"`, `b"\x20"`, `b"\x16\x03\x01\x00\xa5"` TLS ClientHello), test_early_detection_of_invalid_response:1038, test_HEAD_framing_headers:1050, test_special_exceptions_for_lost_connection_in_message_body:1092.

`test_state.py`: test_ConnectionState:30, _keep_alive:62, _keep_alive_in_DONE:75, _switch_denied:87, _protocol_switch_accepted:131, _double_protocol_switch:149, _inconsistent_protocol_switch:168, _keepalive_protocol_switch_interaction:183, _reuse:201, test_server_request_is_illegal:266 — a pure table of (our_state, their_state, event) → next state, exactly the connection FSM the architecture doc puts in `connection.sls`.

`test_io.py`: readers/writers for ContentLength/Chunked/Http10 framing (test_ContentLengthReader:386, test_Http10Reader:396, test_ChunkedReader:404, ...Writer:476-518), reject_garbage_after_request_line:527, reject_garbage_in_header_line:541, reject_non_vchar_in_path:550, allow_some_garbage_in_cookies:560, host_comes_first:578, obsolete line folding:316.

Sample (test_pipelining, lines 522-594): feeds three pipelined requests in one `receive_data` call, asserts events, `PAUSED` after each message until `start_next_cycle()`, and `trailing_data == (b"SADF", False/True)` semantics after EOF. This is the exact contract our connection layer needs around chez-httparse's `consumed` count and the measured "data-after-close" behaviour.

Fit: (c) — h11 IS a sans-I/O connection state machine; every test is "bytes in / events out / state after", with no sockets. `helpers.py:62 ConnectionPair` (send events on one side, receive on the other, `expect="match"`) is a ready design for our sans-I/O driver test helper. Also (a) via `test_against_stdlib_http.py` pattern.

Extraction: manual but straightforward (~55 tests; Python literals are `b"..."`). Two days to port test_connection + test_state; the event names map to chez-httparse callbacks (Request/Data/EndOfMessage/ConnectionClosed).

Tier 1. Vendor `h11/tests/test_connection.py`, `test_state.py`, `test_io.py`, `helpers.py` verbatim as reference alongside a PROVENANCE file (repo, SHA 62c5068, MIT, 0.16.0+dev), and port case by case.

---

## 5. CPython `Lib/test/test_httpservers.py` and `test_httplib.py` — Tier 3 (reference-impl)

- URL: https://github.com/python/cpython/blob/main/Lib/test/test_httpservers.py ; https://github.com/python/cpython/blob/main/Lib/test/test_httplib.py
- License: PSF-2.0 (`LICENSE` line 73 `PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2`)
- Paths: `Lib/test/test_httpservers.py` (72,440 B, 1759 lines), `Lib/test/test_httplib.py` (109,455 B, 2771 lines)

Measured:
```
$ rg -c '^\s*def test_' test_httpservers.py  -> 103      test_httplib.py -> 131
$ rg -c 'FakeSocket\(' test_httplib.py -> 92
```
Relevant classes: `test_httpservers.py:139 BaseHTTPServerTestCase` (22 tests, real threaded server + `http.client` connection; request-line/version cases at 203-261: test_version_bogus `FUBAR`→400, test_version_digits `HTTP/9.9.9`→400, test_version_signs_and_underscores, test_major/minor_version_number_too_long, test_version_none_get→501, test_version_invalid `HTTP/9.9`→505, test_send_blank→400, test_header_close/keep_alive); `:367 HTTP09ServerTestCase` (HTTP/0.9 bare `GET /foo.html\r\n`, line 386 test_invalid_request expects `HTTP/1.0 400 ` prefix); `:982 SocketlessRequestHandler` + `:1024 BaseHTTPRequestHandlerTestCase` (19 tests) — a BytesIO-backed sans-I/O harness (`send_typical_request(message)` at ~1050 sets `rfile`/`wfile` to BytesIO and calls `handle_one_request()`): test_http_1_1, test_http_1_0, test_http_0_9, test_request_line_error_has_status_line (parametrized), test_extra_space, test_with_continue_1_0/1_1, test_header_buffering_*, test_header_unbuffered_when_continue, test_with_continue_rejected (417), test_request_length (414), test_header_length, test_too_many_headers (431), test_close_connection.
`test_httplib.py`: HeaderTests:137, TransferEncodingTest:532, BasicTest:660 (test_status_lines:868, partial reads, test_too_many_headers:1103, test_chunked:1206, test_chunked_head:1300, test_overflowing_status_line:1384, test_overflowing_header_line, test_overflowing_header_limit_after_100:1397, test_too_many_interim_responses:1410, test_overflowing_chunked_line:1439, test_early_eof:1452, test_chunked_extension:1480, test_chunked_missing_end:1490, test_chunked_trailers:1499, test_chunked_too_many_trailers:1510), PersistenceTest:2110 (test_reuse_reconnect, test_disconnected, test_100_close), TunnelTests:2498.

Fit: (b) for BaseHTTPServerTestCase-style cases; (c)-shaped for the 19 socketless cases. test_httplib is client-side — its `FakeSocket` response-parsing cases (chunked trailers, early EOF, interim responses) are a seed for the response reader our loopback test client needs.

Extraction: manual; small. http.server is HTTP/1.0-by-default and does not pipeline, so its verdicts are weak evidence of "correct" behaviour.

Tier 3 (reference only). Note: PSF-2.0 is permissive and BSD-compatible but requires keeping the PSF notice if any text is copied.

---

## 6. aio-libs/aiohttp `tests/test_http_parser.py`, `test_web_protocol.py`, `test_web_server.py`, `test_web_functional.py` — Tier 3 (reference-impl; its C parser IS llhttp)

- URL: https://github.com/aio-libs/aiohttp/tree/master/tests
- License: Apache-2.0 (`aiohttp/LICENSE.txt`: "Apache License Version 2.0, January 2004")
- Paths: `tests/test_http_parser.py` (129,466 B), `tests/test_web_protocol.py` (7,867 B), `tests/test_web_server.py` (14,194 B), `tests/test_web_functional.py` (107,188 B), `tests/test_base_protocol.py`, `tests/test_http_writer.py`; parser source `aiohttp/_http_parser.pyx`, `vendor/llhttp` (submodule; `vendor/README.rst:7` "To build this llhttp parser, first get/update the submodules").

Measured:
```
$ for f in tests/test_web_protocol.py tests/test_web_server.py tests/test_web_functional.py tests/test_http_parser.py tests/test_http_writer.py tests/test_web_request.py tests/test_web_request_handler.py tests/test_base_protocol.py; do printf "%4d  %s\n" "$(rg -c '^\s*(async )?def test_' "$f")" "$f"; done
  12  tests/test_web_protocol.py
  15  tests/test_web_server.py
 120  tests/test_web_functional.py
 231  tests/test_http_parser.py
  75  tests/test_http_writer.py
 128  tests/test_web_request.py
   4  tests/test_web_request_handler.py
  19  tests/test_base_protocol.py
$ rg -n 'params=|HttpRequestParserC|llhttp' tests/test_http_parser.py | head
56:REQUEST_PARSERS = [HttpRequestParserPy]
60:    from aiohttp.http_parser import HttpRequestParserC, HttpResponseParserC
62:    REQUEST_PARSERS.append(HttpRequestParserC)
92:@pytest.fixture(params=REQUEST_PARSERS, ids=_gen_ids(REQUEST_PARSERS))
573:        # Content-Length is excluded because llhttp rejects duplicates
```

Connection-relevant parser tests (names, `test_http_parser.py`): test_conn_default_1_0:852, test_conn_close:866, test_conn_close_1_0:873, test_conn_keep_alive_1_0:880, test_conn_keep_alive_1_1:887, test_conn_close_comma_list:894, test_conn_close_multiple_headers:901, test_conn_other_1_0:913, test_request_te_chunked_with_content_length:978, test_request_te_chunked123:992, test_request_te_empty_list_invalid:1001, test_request_te_last_chunked:1010, test_request_te_first_chunked:1017, test_request_te_duplicate_chunked:1027, test_conn_upgrade:1038, test_conn_upgrade_comma_list:1052, test_bad_upgrade:1081, test_max_header_*:1254-1346, test_http_request_message_after_close:1804, test_http_request_message_after_close_comma_list:1812, test_http_request_upgrade*:1820-1889, test_http_request_chunked_payload_and_next_message:2481, test_parse_chunked_payload_empty_body_than_another_chunked:2718, test_parse_chunked_payload_split_chunks:2760, test_duplicate_singleton_header_rejected:528, test_duplicate_host_header_rejected:594.
`test_web_protocol.py` (12): pause_reading/resume_reading backpressure rules (test_pause_reading_for_buffer_without_transport:54, test_resume_reading_if_drained_stays_paused_for_full_tail:102, test_resume_reading_stays_paused_for_msg_queue:184 ...) — a direct analogue of uv-read-stop!/uv-read-start! policy with a bounded message queue.
`test_web_functional.py` raw-socket (asyncio.open_connection) cases: test_http1_pipelined_requests_are_count_limited, test_http1_pipelined_queue_resumes_after_drain, test_http1_pipelined_behind_declined_upgrade_served_once, test_upgrade_tail_is_byte_limited, test_upgrade_tail_resumes_reading_after_websocket_prepare, test_bad_pipelined_data_behind_declined_upgrade_answers_400, test_pipelined_requests_after_deferred_upgrade_are_served, test_websocket_prepared_with_unread_body_does_not_stall, test_declined_websocket_upgrade_reads_body, test_unread_compressed_body_drain_is_bounded.

Fit: parser tests are (c)-shaped but duplicate llhttp behaviour we already have; the 10 functional raw-socket tests fit (a)/(b); test_web_protocol is a design reference for backpressure.

Extraction: mostly unnecessary (llhttp overlap). Reference only.

Tier 3.

---

## 7. yesodweb/wai `warp/test/` — Tier 2 (server layer, (a)/(b))

- URL: https://github.com/yesodweb/wai/tree/master/warp/test
- License: MIT (`warp/LICENSE`: "Copyright (c) 2012 Michael Snoyman ... Permission is hereby granted, free of charge")
- Paths: `warp/test/RunSpec.hs` (21,254 B), `RequestSpec.hs` (6,816 B), `ConnectionSpec.hs` (3,887 B), `GracefulShutdownSpec.hs` (6,596 B), `ResponseSpec.hs`, `ExceptionSpec.hs`, `SendFileSpec.hs`.

Measured:
```
$ for f in warp/test/*Spec.hs; do printf "%4d  %s\n" "$(rg -c '^\s*(it|prop) "' "$f")" "$f"; done
  30  RunSpec.hs   14  RequestSpec.hs   1  ConnectionSpec.hs (+7 testClose calls)   2  GracefulShutdownSpec.hs   5  ExceptionSpec.hs   15  SendFileSpec.hs   1  ResponseSpec.hs   5  ResponseHeaderSpec.hs
```
RunSpec.hs structure (lines 208-267): `describe "non-pipelining"` / `describe "pipelining"` × {no body, has body, chunked body} × {read, ignore} = 12 cases via `runTest n app [chunks]`; `describe "no hanging"`: `runTest 1 readBody (map S.singleton (S.unpack singlePostHello))` — the request delivered ONE BYTE PER WRITE over a real socket; `describe "connection termination"` (271): `IncompleteHeaders` for four truncations of `GET / HTTP/1.1\r\ncontent-length: 10\r\n\r`; `special input` (277-312): multiline/obs-fold headers, `foo:bar` no space; `chunked bodies` (314-430): works / lots of chunks / in chunks / `timeout in request body` (setTimeout 1, body sent in two delayed pieces). `RequestSpec.hs:47 prop "random chunking"` is a QuickCheck property splitting `GET / HTTP/1.1\r\nConnection: Close\r\n\r\n`+extra at random 1..10-byte boundaries and checking leftover bytes — the same invariant as our every-chunk-size replay. `ConnectionSpec.hs:13-45`: HTTP/1.0 Keep-Alive without Content-Length must close and send `Connection: close`; HTTP/1.1 HEAD must not add `Connection: close`; 7 `testClose` cases. `GracefulShutdownSpec.hs`: "waits for a connection accepted just before it stopped accepting", "serves the request in flight, then closes keep-alive connections and exits".

Fit: (a)/(b); the harness (`withApp`, `withMySocket`, `msWrite`/`msRead`, lines 44-83) is raw sockets.

Extraction: manual, small (~50 cases), Haskell. The pipelining × body matrix and graceful-shutdown cases are worth copying as a checklist.

Tier 2.

---

## 8. Netty `codec-http` tests — Tier 2 (connection/codec layer, (c) via EmbeddedChannel)

- URL: https://github.com/netty/netty/tree/4.2/codec-http/src/test/java/io/netty/handler/codec/http
- License: Apache-2.0 (`netty/LICENSE.txt` "Apache License"; gh API Apache-2.0)
- Paths (all under `codec-http/src/test/java/io/netty/handler/codec/http/`): `HttpRequestDecoderTest.java` (63,908 B), `HttpServerCodecTest.java` (26,614 B), `HttpObjectAggregatorTest.java` (35,037 B), `HttpServerKeepAliveHandlerTest.java` (13,697 B), `HttpServerExpectContinueHandlerTest.java`, `HttpInvalidMessageTest.java`, `MultipleContentLengthHeadersTest.java`, `HttpResponseDecoderTest.java` (65,734 B), `HttpHeaderValidationUtilTest.java`, `HttpVersionParsingTest.java`, `HttpServerUpgradeHandlerTest.java`, `HttpContentDecoderTest.java`.

Measured:
```
$ for f in ...; do printf "%4d  %s\n" "$(rg -c '@(Test|ParameterizedTest)' "$f")" "$f"; done
  78  HttpRequestDecoderTest.java
  15  HttpServerCodecTest.java
  26  HttpObjectAggregatorTest.java
   5  HttpServerKeepAliveHandlerTest.java   (2 are @ParameterizedTest over keepAliveProvider())
   2  HttpServerExpectContinueHandlerTest.java
   5  HttpInvalidMessageTest.java
   2  MultipleContentLengthHeadersTest.java (1 parameterized)
  61  HttpResponseDecoderTest.java
  23  HttpHeaderValidationUtilTest.java
  16  HttpVersionParsingTest.java
  42  HttpUtilTest.java
   5  HttpServerUpgradeHandlerTest.java
  24  HttpContentDecoderTest.java
$ rg -c 'new EmbeddedChannel' HttpRequestDecoderTest.java HttpServerCodecTest.java HttpObjectAggregatorTest.java
HttpObjectAggregatorTest.java:22  HttpServerCodecTest.java:15  HttpRequestDecoderTest.java:43
```
`HttpRequestDecoderTest.java:180-236 testDecodeWholeRequestInMultipleSteps(content, strict, expectFailure)`: `for (int i = 1; i < content.length; i++)` feeds the header at fragment size i and then the body one byte at a time into an `EmbeddedChannel(new HttpRequestDecoder(config))` and asserts the emitted HttpRequest/HttpContent/LastHttpContent sequence — every-chunk-size replay, sans-I/O. Cases (names): CRLF/LF/mixed delimiters (strict vs lenient), testMultiLineHeader:238, testEmptyHeaderValue:261, trailing headers 273-329, test100Continue:359, test100ContinueWithBadClient:383, testMessagesSplitBetweenMultipleBuffers:413, testTooLargeInitialLine*:444-462, testInitialLineWithLeadingControlChars:479, testNonCrlfControlBytesPrecedingRequestLineAreRejected:493, testTooLargeHeaders:518, header-name control chars 558-612, testWhitespaceInTransferEncoding01/02:635/645, testHeaderWithNoValueAndMissingColon:658, testMultipleContentLengthHeaders*:667-694, testInvalidTransferEncodingFraming:719 (parameterized), testChunkedLastInMultiLineTransferEncoding:729, testChunkedNotLastInTransferEncodingHttp10*:750/771, testContentLengthAndTransferEncodingHeadersWithVerticalTab/CR:790/796, testContentLengthHeaderAndChunkedHttp11(/RFC7230/Http10):814-851, mustRejectChunkSizeThatWouldCauseOverflow:1137, testChunkSizeOverflow(2):1282/1298, testInvalidVersion:1316, testNulInInitialLine:1333, testNulInVersionTokenIsRejected:1388, testNulInMethodTokenIsRejected:1394.
`HttpServerCodecTest.java` (15): testUnfinishedChunkedHttpRequestIsLastFlag, test100Continue, testChunkedHeadResponse, testConnectionClosedAfterResponseWhenBothTransferEncodingAndContentLengthRfc9112/Rfc7230, testInterleavedRequestResponseAcrossOverflow, testHeadResponseHasNoContentAfterInterimResponse, testPipelinedResponseContentPreservedAfterInterimResponse, testSwitchingProtocolsResponseHasNoContent, testMaxPipelineDepthLimited.
`HttpObjectAggregatorTest.java` (26): testOversizedRequest*, testOversizedRequestWith100Continue(AndDecoder/CloseConnection), testRequestAfterOversized100ContinueAndDecoder, testUnsupportedExpectHeaderExpectation, testPrematureClosureWithChunkedEncodingAndAggregator, testOversizedRequestWithAutoReadFalse — the 413/417/close-vs-keep-alive decision matrix for bodies over the limit.
`HttpServerKeepAliveHandlerTest.java:59 keepAliveProvider()` — parameterized matrix (version × Connection header × self-defined length) → whether the response keeps the connection; `test_KeepAlive:81`, `testPipelineKeepAlive:154`, `testConnectionClosedWhenBothTransferEncodingAndContentLengthRfc7230:219`.

Fit: (c) — EmbeddedChannel is sans-I/O; inputs are byte arrays, outputs are decoded message objects. Also a strong reference for the response side (HttpResponseDecoderTest 61 cases feed our loopback client's parser: garbage chunks, premature closure, whitespace after chunk size).

Extraction: manual; Java, byte arrays built with `Unpooled.copiedBuffer("...", CharsetUtil.US_ASCII)`; ~150 relevant cases. Apache-2.0 requires carrying NOTICE if text is copied.

Tier 2.

---

## 9. ASP.NET Core Kestrel HTTP/1 tests — Tier 1 for `shared/test/HttpParsingData.cs`, Tier 2 for the in-memory functional scripts (connection layer, (c))

- URL: https://github.com/dotnet/aspnetcore/tree/main/src/Servers/Kestrel
- License: MIT (`aspnetcore/LICENSE.txt`: "The MIT License (MIT) / Copyright (c) .NET Foundation and Contributors")
- Paths: `src/Servers/Kestrel/shared/test/HttpParsingData.cs` (554 lines, pure data), `src/Servers/Kestrel/Core/test/HttpParserTests.cs` (55,453 B), `Core/test/StartLineTests.cs`, `Core/test/HttpRequestHeadersTests.cs`, `Core/test/MessageBodyTests.cs` (59,401 B), `Core/test/Http1/Http1ConnectionTests.cs`, `Core/test/KestrelServerLimitsTests.cs`, `Core/test/TimeoutControlTests.cs`; `src/Servers/Kestrel/test/InMemory.FunctionalTests/{RequestTests,ResponseTests,ChunkedRequestTests,ChunkedResponseTests,BadHttpRequestTests,KeepAliveTimeoutTests,MaxRequestBodySizeTests,MaxRequestLineSizeTests,RequestHeaderLimitsTests,RequestHeadersTimeoutTests,RequestBodyTimeoutTests,RequestTargetProcessingTests,UpgradeTests,ConnectionLimitTests,ResponseDrainingTests}.cs`, transport `test/InMemory.FunctionalTests/TestTransport/{InMemoryConnection,InMemoryTransportConnection,TestServer}.cs`, helpers `shared/test/{TestConnection,StreamBackedTestConnection}.cs`.

Measured:
```
Core/test:  Http1/Http1ConnectionTests.cs 62 facts/theories, 25 InlineData | HttpParserTests.cs 48 / 148 InlineData | StartLineTests.cs 9 / 33 | HttpRequestHeadersTests.cs 32 / 7 | MessageBodyTests.cs 57 / 30 | KestrelServerLimitsTests.cs 39 / 51 | TimeoutControlTests.cs 15
InMemory.FunctionalTests: RequestTests 56/16 | ResponseTests 133/36 | ChunkedRequestTests 22/19 | ChunkedResponseTests 29/11 | BadHttpRequestTests 20/28 | KeepAliveTimeoutTests 6 | MaxRequestBodySizeTests 13 | MaxRequestLineSizeTests 2/16 | RequestHeaderLimitsTests 4/21 | RequestHeadersTimeoutTests 4/5 | RequestBodyTimeoutTests 3 | RequestTargetProcessingTests 3/17 | UpgradeTests 11 | ConnectionLimitTests 4 | ResponseDrainingTests 1 | HttpProtocolSelectionTests 4
HttpParsingData.cs tables (python count of string rows per table):
  18  RequestLineValidData        16  RequestLineDotSegmentData      15  RequestLineIncompleteData
  90  RequestLineInvalidData       4  RequestLineInvalidDataLineFeedTerminator
  20  MethodWithNonTokenCharData   4  MethodWithNullCharData          7  TargetWithEncodedNullCharData
  10  MethodNotAllowedRequestLine  4  TargetWithNullCharData          2  QueryStringWithNullCharData
   5  UnrecognizedHttpVersionData  4  RequestHeaderInvalidDataLineFeedTerminator
  58  RequestHeaderInvalidData    14  HostHeaderData                  9  HostHeaderInvalidData
  (TargetInvalidData is a TheoryData built in code; counted 0 by the row regex)
```
Sample `HttpParsingData.cs:142-175 RequestLineInvalidData`: `"G\r\n"`, `"GET\r\n"`, `"GET /\r\n"`, `"GET/HTTP/1.1\r\n"`, `"GET /HTTP/1.1\r\n"`, `" / HTTP/1.1\r\n"`, `"GET  HTTP/1.0\r\n"`, `"GET / HTTP/1.0\rA\n"`, `"GET   / HTTP/1.1\r\n"`, `"GET / HTTP/1.1 \r\n"`, ... (90 rows) — each is a complete byte string with an implied verdict (reject). These are used by `HttpParserTests.cs` (148 InlineData) and `BadHttpRequestTests.cs` (TestInvalidRequestLines, TestInvalidRequestLinesWithUnrecognizedVersion, TestInvalidHeaders, BadRequestIfMethodRequiresLengthButNoContentLengthInHttp10Request, BadRequestIfContentLengthInvalid, BadRequestIfHostHeaderMissing, BadRequestIfMultipleHostHeaders, BadRequestIfHostHeaderDoesNotMatchRequestTarget, TestRequestSplitting, ExtraLinesBetweenRequestsIgnored, ExtraLinesIgnoredBetweenAdjacentRequests, ExtraLinesAtEndOfConnectionIgnored).

In-memory script style (`shared/test/StreamBackedTestConnection.cs:68-138`): `SendAll(lines)`, `Send(lines)`, `Receive(lines)`, `ReceiveEnd(lines)`, `WaitForConnectionClose()`; e.g. `RequestTests.cs:152-200` `await connection.Send(...); await connection.Receive("HTTP/1.1 200 OK", ...)`; `ReceiveEnd` asserts the server closed. The transport is `TestTransport/InMemoryTransportConnection.cs` (a duplex pipe, no sockets). RequestTests names include Http11KeptAliveByDefault, Http10NotKeptAliveByDefault, Http10KeepAlive, Http10KeepAliveNotHonoredIfResponseContentLengthNotSet, Http10KeepAliveHonoredIfResponseContentLengthSet, Expect100ContinueHonored, ZeroContentLengthAssumedOnNonKeepAliveRequestsWithoutContentLengthOrTransferEncodingHeader, ContentLengthReadAsyncSingleBytesAtATime, ConnectionClosesWhenFinReceivedBeforeRequestCompletes, UpgradeRequestIsNotKeptAliveOrChunked, ServerConsumesKeepAliveContentLengthRequest, ServerConsumesKeepAliveChunkedRequest, NonKeepAliveRequestNotConsumedByAppCompletes, SingleLineFeedIsSupportedAnywhere. Http1ConnectionTests names include TakeMessageHeadersThrowsWhenHeadersExceedTotalSizeLimit/CountLimit, TakeStartLineRemovesDotSegmentsFromTarget, TakeStartLineThrowsWhenTooLong, TakeStartLineThrowsOnNullCharInTarget/Method/QueryString, ProcessRequestsAsyncEnablesKeepAliveTimeout, ContentLengthShouldBeRemovedWhenBothTransferEncodingAndContentLengthRequestHeadersExist, Http10HostHeaderNotRequired, Http11EmptyHostHeaderAccepted, BadRequestFor11BadHostHeaderFormat.

Fit: (c) is the natural home — HttpParsingData rows are byte strings; InMemory.FunctionalTests are literally send/receive scripts over an in-memory duplex, i.e. exactly what a sans-I/O connection driver replays. Also (a).

Extraction: HttpParsingData.cs → mechanical (C# string literals with `\r\n`, `\0`; one script). InMemory scripts → semi-mechanical: a Send/Receive/ReceiveEnd DSL can be transcribed to an s-expression script per test, but the server-side handler (the `app` lambda) must be re-expressed per test.

Tier 1 for `HttpParsingData.cs` (vendor now with PROVENANCE: SHA 1fcd7ef, MIT); Tier 2 for the InMemory scripts.

---

## 10. Cowboy `test/rfc7230_SUITE.erl`, `rfc7231_SUITE.erl`, `http_SUITE.erl` — Tier 1 (server layer, (a)/(b))

- URL: https://github.com/ninenines/cowboy/tree/master/test
- License: ISC (`cowboy/LICENSE`: "Copyright (c) 2011-2026, Loïc Hoguin <essen@ninenines.eu> / Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted")
- Paths: `test/rfc7230_SUITE.erl` (90,208 B), `test/rfc7231_SUITE.erl` (33,158 B), `test/http_SUITE.erl` (49,114 B), `test/req_SUITE.erl` (56,688 B), `test/security_SUITE.erl` (16,615 B: slowloris, slowloris_chunks + HTTP/2 floods), `test/rfc6585_SUITE.erl`, helper `test/cowboy_test.erl` (`raw_open/1`, `raw_send/2`, `raw_recv_head/1`, `raw_recv_rest/3`, `raw_recv/3` at lines 198-231).

Measured:
```
$ for f in test/http_SUITE.erl test/rfc7230_SUITE.erl test/rfc7231_SUITE.erl test/req_SUITE.erl test/security_SUITE.erl test/rfc6585_SUITE.erl; do printf "%4d doc()  %4d fns  %s\n" "$(rg -c '^\s*doc\(' "$f")" "$(rg -c '^[a-z][a-z0-9_]*\(Config\) ->' "$f")" "$f"; done
  51 doc()    50 fns  test/http_SUITE.erl
 156 doc()   155 fns  test/rfc7230_SUITE.erl
  76 doc()    74 fns  test/rfc7231_SUITE.erl
  94 doc()   101 fns  test/req_SUITE.erl
  16 doc()    18 fns  test/security_SUITE.erl
   4 doc()     4 fns  test/rfc6585_SUITE.erl
```
Case shape (`rfc7230_SUITE.erl:60-73 do_raw/2` + e.g. lines 1009-1019):
```erlang
reject_duplicate_content_length_header(Config) ->
	doc("Requests with duplicate content-length headers must be rejected "
		"with a 400 status code and the closing of the connection. (RFC7230 3.3.2)"),
	#{code := 400, client := Client} = do_raw(Config, [
		"POST / HTTP/1.1\r\n" "Host: localhost\r\n" "Content-length: 12\r\n" "Content-length: 12\r\n" "\r\n" "Hello world!"]),
	{error, closed} = raw_recv(Client, 0, 1000).
```
and lines 1636-1700: no_connection_header_keepalive (expects `{error, timeout}` = still open), http10_connection_keepalive, connection_close (`{error, closed}`), http10_no_connection_header_close, connection_invalid (`Connection: jndi{ldap127` → 400 + close), http10_connection_invalid. Every case = RFC citation + literal request bytes + expected status + expected socket state (closed vs timeout). rfc7230 case list (155): accept_at_least_1_empty_line, no_empty_line_after_request_line, timeout_before_request_line, timeout_after_request_line(_host/_crlf/_crlfcr), limit_request_line_8000/9000, reject_lf_line_breaks_request_line, reject_invalid_method, reject_tab_between_method_and_request_target, origin/absolute/authority/asterisk-form target cases (~45), reject_invalid_version_http09/100/111/12/2, header name/value validity (~20), reject_duplicate_content_length_header, reject_duplicate_host_header, combine_duplicate_headers, limit_headers, request_body_content_length, request_body_transfer_encoding, must_understand_chunked, reject_double_chunked_encoding, reject_non_terminal_chunked, reject_unknown_transfer_encoding, reject_invalid_content_length, reject_when_both_content_length_and_transfer_encoding, body_length_chunked_before/after, reject_invalid_chunk_size, ignore_unknown_chunk_extensions, limit_chunk_size_line, reject_invalid_chunk_size_crlf/ext_crlf/data_crlf, remove_transfer_encoding_chunked_after_body_read, no_connection_header_keepalive, http10_connection_keepalive, connection_close, http10_no_connection_header_close, connection_invalid, limit_requests_keepalive, accept_at_least_1_empty_line_keepalive, reject_lf_line_breaks_empty_line, pipeline, close_inactive_connections, ignore_requests_after_request_connection_close, ignore_requests_after_response_connection_close, reject_missing_host, reject_invalid_host, reject_userinfo, reject_absolute_form_different_host, reject_non_authoritative_host, http10_request_http11_response, close_request_close_response, no_body_in_head_response, no_body_in_204/304_response(_stream), same_content_length_as_get_in_head_response, same_transfer_encoding_as_get_in_head_response, no_content_length_in_204_response, no_transfer_encoding_in_204_response, content_length_0_when_no_body, chunked_response, no_content_length_if_transfer_encoding, http10_request_no_transfer_encoding_in_response, no_te_no_trailers, te_trailers, te_ignore_chunked, upgrade_safely_ignored.
rfc7231 (74): method_*, expect, http10_expect, expect_receive_body_omit_100_continue, expect_discard_body_skip/close, http10_status_code_100/101, status_code_100..505 (each checks framing), status_code_408_connection_close, status_code_426_upgrade_header, date_* , server_header.
http_SUITE (50): chunked_one_byte_at_a_time, chunked_one_chunk_at_a_time, chunked_split_delay_in_chunk_body/crlf, chunked_trailers_skip(_limit), http10_keepalive_false, idle_timeout_read_body(_pipeline), idle_timeout_skip_body, idle_timeout_on_send, idle_timeout_reset_on_send, max_header_value_length, request_timeout(_pipeline/_pipeline_delay/_skip_body/_skip_body_more/_infinity), set_options_idle_timeout(_only_applies_to_current_request), switch_protocol_flush, graceful_shutdown_connection, graceful_shutdown_listener.

Fit: (a) and (b) exactly — raw TCP in, status+headers+body+socket-state out. Also (c) for the majority of rfc7230 cases (no timing involved).

Extraction: near-mechanical for rfc7230/rfc7231: a script can lift `doc(...)`, the `do_raw` byte list, the `#{code := N}` match and the trailing `raw_recv` expectation into a table `(name rfc-cite request-bytes expected-status expect-close?)`. Cases that pattern-match response headers need a small predicate language. ~1 day for 200+ cases. ISC is BSD-compatible.

Tier 1. Vendor `rfc7230_SUITE.erl` and `rfc7231_SUITE.erl` verbatim under a PROVENANCE file (SHA c965d1a, ISC, cowboy 2.19.0) and generate the table from them; keep http_SUITE.erl as the timeout/chunk-pacing checklist.

---

## 11. Bandit `test/bandit/http1/protocol_test.exs` — Tier 2 (server layer, (a)/(b)); borderline Tier 1

- URL: https://github.com/mtrudel/bandit/blob/main/test/bandit/http1/protocol_test.exs
- License: MIT (`bandit/LICENSE`; gh API MIT)
- Paths: `test/bandit/http1/protocol_test.exs` (114,055 B), `test/bandit/http1/plug_test.exs` (21,336 B), helpers `test/support/simple_http1_client.ex` (`send/5`, `recv_reply/2`, `connection_closed_for_reading?/1`), `test/support/transport.ex`.

Measured:
```
$ for f in test/bandit/http1/*.exs; do printf "%4d  %s\n" "$(rg -c '^\s*test "' "$f")" "$f"; done
   9  logging_test.exs   39  plug_test.exs   189  protocol_test.exs   14  telemetry_test.exs
```
`describe` blocks (with RFC cites, line numbers): invalid requests (RFC9112§2.2, §2.3, §5.1):12; method coverage:47; method case sensitivity:73; request line limits:81; origin-form:101; absolute-form:265; authority-form:422; asterisk-form:458; Host header validation:481; request headers (RFC9112§5):507; content-length request bodies (§6.2, §6.3):640; response body content-length framing by status code:975; sendfile:1150; informational (1xx) responses:1223; Expect: 100-continue:1249; chunked request bodies (§7.1):1311; transfer-encoding edge cases (§6.1, §7.1.1):1605; response chunked:1730; content negotiation:1867; upgrade handling (RFC9110§7.8, RFC6455):2510; connection closure / error handling (RFC9112§8, §9.6):2709; connection persistence / keepalive (RFC9112§9.3):2848.
Connection-semantics tests (names, 2709-3123): raises an error if client closes while headers are being read / while body is being read / mid-chunk / while body is being written / while chunked body is being written / before sendfile; silently exits if client closes during keepalive; closes the connection by default for HTTP/1.0 requests with no connection header; closes when HTTP/1.1 client explicitly requests it; ... via comma-separated list; handles pipeline requests; handles pipeline requests with unread POST bodies; closes connection after max_requests is reached; closes connection after exception is raised; idle keepalive connections are closed after read_timeout; responses which contain a connection: close header close the connection; connection: close skips body draining when plug does not read body; keepalive mixed-case header connections are respected in HTTP/1.0; keepalive is respected in HTTP/1.0 when listed alongside other connection options; keepalive are explicitly signalled in HTTP/1.0; unread content length bodies are read before starting a new request; unread chunked bodies are read before starting a new request. Body/framing tests 640-1730 include: rejects multiple separate content length headers even if identical; non-matching multiple content lengths; negative content-length; non-integer content length; both content-length and transfer-encoding; declared content length longer than sent; TransportError on disconnect during body read; HEAD/204/304 framing; 100-continue only when body read; chunked: invalid large chunk size, invalid end marker, leading plus sign, signed zero, negative, empty after extensions, multiple TE headers, trailers, timing out mid-chunk/between chunks; non-chunked final coding; unsupported coding; TE applied twice; TE from HTTP/1.0 client.

Sample (lines 2863-2896): `SimpleHTTP1Client.send(client, "GET", "/echo_components", ["host: localhost"], "1.0")` → `{:ok, "200 OK", _, _}` then `assert SimpleHTTP1Client.connection_closed_for_reading?(client)`; the comma-list case sends `connection: keep-alive, close` and asserts `Keyword.get_values(headers, :connection) == ["close"]`.

Fit: (a)/(b). The client helper is 60 lines and maps directly to chez-libuv verbs (send request lines, recv, detect closed).

Extraction: manual but regular; Elixir `test "..." do` blocks with a 3-call pattern. ~120 relevant cases, 1-2 days. The RFC 9112 section labels make it the most current spec mapping of the twelve.

Tier 2 (adapt after cowboy; it overlaps cowboy heavily but is organised by RFC 9112 rather than 7230).

---

## 12. Puma `test/` — Tier 2 (server layer, (a)/(b))

- URL: https://github.com/puma/puma/tree/main/test
- License: BSD-3-Clause (`puma/LICENSE`: "BSD 3-Clause License / Copyright (c) 2019, Evan Phoenix. Some code by Zed Shaw, (c) 2005.")
- Paths: `test/test_puma_server.rb` (69,141 B), `test/test_persistent.rb` (6,626 B), `test/test_request_invalid_multiple.rb` (6,752 B), `test/test_request_single.rb` (24,315 B), `test/test_http11.rb` (Ragel parser unit tests), `test/test_http10.rb`, `test/test_response_header.rb`, `test/test_puma_server_hijack.rb`, helpers `test/helpers/test_puma/puma_socket.rb` (`send_http`, `send_http_read_response`, `send_http_read_all`, `send_http_read_headers`, `send_http_read_body`, `send_http_array`).

Measured:
```
$ for f in test/test_puma_server.rb test/test_persistent.rb test/test_request_invalid_multiple.rb test/test_request_single.rb test/test_http11.rb test/test_http10.rb test/test_response_header.rb test/test_puma_server_hijack.rb; do printf "%4d  %s\n" "$(rg -c '^\s*def test_' "$f")" "$f"; done
 134  test/test_puma_server.rb
  17  test/test_persistent.rb
   6  test/test_request_invalid_multiple.rb
  71  test/test_request_single.rb
  14  test/test_http11.rb
   1  test/test_http10.rb
  14  test/test_response_header.rb
   6  test/test_puma_server_hijack.rb
```
`test_persistent.rb` (17): test_one_with_content_length, test_two_back_to_back, test_post_then_get, test_no_body_then_get, test_chunked, test_chunked_with_empty_part, test_no_chunked_in_http10, test_hex, test_client11_close, test_client10_close, test_one_with_keep_alive_header, test_persistent_timeout, test_app_sets_content_length, test_allow_app_to_chunk_itself, test_two_requests_in_one_chunk (line 206: two requests in one write, expects `@valid_response * 2`), test_second_request_not_in_first_req_body, test_keepalive_doesnt_starve_clients.
`test_request_invalid_multiple.rb` (header comment cites RFC 9112 content-length / transfer-encoding / chunked): test_missing_host_http11, test_empty_host_http11, test_oversize_path_keep_alive, test_content_length_bad_characters_1_keep_alive, test_http_11_req_oversize_content_length, test_http_11_req_oversize_chunked.
`test_request_single.rb` (71): method/path/query/host parsing, test_content_length_exceeded(_chunked), test_malformed_headers_no_return/no_newline, test_bad_characters_1-3 (Content-Length), test_chunked_size_bad_characters_1-4, test_chunked_size_mismatch_1/2, underscore-header collision cases, host header ipv4/ipv6/port cases.
`test_puma_server.rb` (134) protocol subset: test_http10_req_to_http10_resp:61, test_HEAD_has_no_body:269, test_GET_with_empty_body_has_sane_chunking:277, test_back_to_back_chunked:323, test_early_hints_*:349-393, test_request_payload_too_large:411, test_http_11_keep_alive_with_large_payload:423, test_timeout_in_data_phase:619, test_idle_timeout_* (6 cases 660-758), test_http_11_keep_alive_with_body / close_with_body / without_body (789-816), test_http_10_keep_alive_with_body ... (859-888), test_Expect_100:896, test_chunked_request:905, test_large_chunked_request:964, test_chunked_request_invalid_extension_header_length(_split):994/1010, **13 chunked pause cases** test_chunked_request_pause_before_value:1044 ... test_chunked_body_pause_within_chunk_size_hex:1268 (each pauses the client at a different byte position of the chunked framing), test_chunked_keep_alive_twenty_back_to_back:1374, test_close_socket_after_max_keepalive_requests:1398, test_proxy_protocol_*:1613-1642, test_http11/10_connection_header_queue/no_queue:1721-1769, test_accept_econnaborted:1799, test_idle_connections_closed_immediately_on_shutdown:1838, test_crlf_trailer_smuggle:2167 (chunked `0\r\nX:POST / HTTP/1.1...` trailer smuggling; expects exactly 2 `200 OK`), test_cl_and_te_smuggle (following).

Fit: (a)/(b); helpers write raw strings to a TCPSocket.

Extraction: manual; Ruby heredocs with `.gsub("\n", "\r\n")`; ~100 relevant cases. The chunked-pause series is a ready-made "split at framing boundary" list for (c).

Tier 2.

---

## Cross-cutting recommendations

1. First milestones (connection object, keep-alive/limits/timeouts, pipelining): vendor now — (i) h11 `test_connection.py` + `test_state.py` as the sans-I/O contract; (ii) cowboy `rfc7230_SUITE.erl`/`rfc7231_SUITE.erl` as the raw-socket conformance table; (iii) Kestrel `HttpParsingData.cs` and Go `readrequest_test.go`/`serve_test.go` tables as byte-level verdict rows. Each gets a PROVENANCE file in the style of chez-httparse's llhttp vendoring: upstream URL, commit SHA, license name + copy of the license text, retrieval date, list of files, local modifications (none).
2. License mix: MIT (h11, hyper, warp, aspnetcore, bandit, node), BSD-3 (Go, puma), ISC (cowboy) are all compatible with the project's BSD-3-Clause; Apache-2.0 (netty, aiohttp) is compatible but requires preserving NOTICE if text is copied; PSF-2.0 (CPython) requires keeping its notice. Nothing here is copyleft.
3. Overlap with llhttp: aiohttp's C parser is llhttp (vendor/llhttp submodule), Node's parser tests target llhttp, and many "invalid request" rows in Kestrel/Go/Netty duplicate llhttp fixture verdicts. The added value of these corpora is the connection-level verdict (status code sent, Connection header, socket closed vs kept open, timeout behaviour), not parse/no-parse.
4. Every-chunk-size replay precedents: Netty `testDecodeWholeRequestInMultipleSteps` (fragment size 1..len), warp `prop "random chunking"`, warp "no hanging" (one byte per socket write), cowboy `chunked_one_byte_at_a_time`, puma's 13 chunked-pause positions, Kestrel `ContentLengthReadAsyncSingleBytesAtATime`. These justify making the sans-I/O driver's chunking loop the default for every vendored case.
5. EOF/close semantics precedents for the libuv on-eof design: hyper conn.rs (conn_accepts_eof_when_idle, conn_rejects_eof_during_partial_head, server_accepts_eof_while_busy), h11 test_close_different_states / test_pipelined_close, Kestrel ConnectionClosesWhenFinReceivedBeforeRequestCompletes, bandit "raises an error if client closes ..." series, warp IncompleteHeaders.
6. Backpressure precedents: Node test-http-pipeline-flood.js, aiohttp test_web_protocol.py (pause/resume rules with message queue), hyper tests/h1_server/fixture.rs (chunk timeouts + max_buf_size), Netty testMaxPipelineDepthLimited / testOversizedRequestWithAutoReadFalse, aiohttp test_http1_pipelined_requests_are_count_limited.

## Things I could not confirm / caveats

- Case counts are regex counts of test-function definitions (`def test_`, `#[test]`, `[Fact]/[Theory]`, `test "`, `it "`, `(Config) ->`); parametrized tests expand to more executions and table rows were counted separately where noted. Netty `@Test` count includes `@ParameterizedTest`.
- Go `TestInvalidChunkedBodies` row count was first mis-measured (my awk pattern) and re-read by eye at lines 7868-7905: 2 rows. `serverExpectTests`: 8 `expectTest(...)` calls + 1 literal = 9.
- Kestrel `TargetInvalidData` is built programmatically so my row counter reports 0.
- Node `test/parallel` git tree was fetched via the trees API with `truncated: false`, so 413 is exact for `test-http-*` (plus 67 `test-https-*`, not counted).
- CPython files were fetched from `main` via raw.githubusercontent.com rather than cloned; the SHA recorded is `repos/python/cpython/commits/main` at fetch time.
