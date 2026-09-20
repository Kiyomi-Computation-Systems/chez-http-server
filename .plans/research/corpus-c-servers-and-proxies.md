# Corpus survey — lens: C servers and proxies

Date measured: 2026-09-19, on the planning machine (macOS arm64). Every count below was
produced by a command shown in this file against a copy of the upstream tree downloaded
today (codeload tarballs, no git metadata) into
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/` (hereafter `$R`).
Raw fetches are in `$R/samples/`, tree listings in `$R/*.tree.txt`, tarballs in `$R/tarballs/`.

Fit codes used throughout:

* **(a)** in-process over loopback TCP using chez-libuv's own client verbs
* **(b)** black-box from an external client against a port
* **(c)** sans-I/O connection driver replaying byte streams at every chunk size

Tier: 1 = vendor now (with a PROVENANCE file as `chez-httparse/test/vendor/llhttp/PROVENANCE` does), 2 = adapt later, 3 = reference only.

Provenance format we would copy (verbatim head of the existing file):

```
$ head -20 /Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE
# PROVENANCE -- the vendored llhttp conformance corpus
# ...
upstream-url: https://github.com/nodejs/llhttp
upstream-ref: v9.4.3-1-gee51043
upstream-commit: ee51043701d8b90ef647cf04790cbb1c55889825
retrieved: 2026-09-13
file-count: 24
sha256 628168d68bb5a8a17e0bbefb3bd74e326e1edc20583d76f52f457c82c921867d LICENSE
...
```

Upstream commits used for every count in this report (`gh api repos/<r>/commits/<branch> --jq .sha`):

| repo | branch | commit | committer date |
|---|---|---|---|
| nginx/nginx-tests | master | 40616854c6a75ecf73005ba14faa1d01a195620d | 2026-09-16T11:18:43Z |
| haproxy/haproxy | master | bff44ff3d23e0de34e42fb6dc77d0c205041e871 | 2026-09-18T15:05:19Z |
| varnishcache/varnish-cache | master | 0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e | 2026-02-16T01:29:49Z |
| vtest/VTest2 (GitHub, archived) | tag `last` | 803dcd000b1328f6e766774e23aedbd7f53e7d97 | pushed 2026-02-18T10:55:39Z |
| vtest/VTest2 (code.vinyl-cache.org, current) | main | f19e3d7d31c0a80cd6b75bab135897710c2057b7 | 2026-09-15T17:12:28+02:00 |
| h2o/h2o | master | cac7e6568ad98a848f099ecd0a18b881f632479a | pushed 2026-09-10T04:21:41Z |
| apache/httpd-tests | trunk | 4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4 | — |
| lighttpd/lighttpd1.4 | master | 2ddc51389a139d2b08daf310596c951c1d53dc8d | — |
| apache/trafficserver | master | f6e6ff94acd1f43bcd3b45ffd83fb5b83cb0b7b9 | — |
| yahoo/proxy-verifier | master | (not recorded; pushed 2026-09-03T23:12:25Z) | — |
| envoyproxy/envoy | main | 079c167d145beae09cde6a2fd1503add15d8f898 | — |
| curl/curl | master | a40991b97c0ce721e85acbe16e16fe79b7b68c51 | — |
| squid-cache/squid | master | 3cbad3277228553ebfefe6ad8c8143f7cd2e9066 | — |

---

## 0. The headline: vtest can drive our server as a black-box client (proved today)

The task asked specifically whether vtest could DRIVE our server directly. Answer: **yes, three
ways, and I built it and did it.**

### 0.1 What vtest is and where it lives now

* GitHub `https://github.com/vtest/VTest2` is **archived (read-only since 2026-02-18)**.
  `gh api repos/vtest/VTest2 --jq '.archived, .pushed_at, .license.spdx_id, .default_branch, .description'` →
  `true / 2026-02-18T10:55:39Z / NOASSERTION / main / The HTTP test-program formerly known as Varnishtest (reiterated)`.
* The GitHub README (`$R/vtest2.README.txt`, fetched from `https://raw.githubusercontent.com/vtest/VTest2/main/README.md`) says verbatim:
  > `# IMPORTANT - THIS REPOSITORY HAS MOVED` / `New location: <https://code.vinyl-cache.org/vtest/VTest2>` / `The last usable version on github has the ``last`` tag.`
  and: "This project is the second iteration of the (almost) unvarnished varnishtest program, made available as a stand-alone program because it can be used to test all sorts of HTTP clients, servers and proxies."
* New home confirmed via its Gitea API:
  `curl https://code.vinyl-cache.org/api/v1/repos/vtest/VTest2` → `vtest/VTest2 main 2026-09-15T17:16:46+02:00 https://code.vinyl-cache.org/vtest/VTest2 https://code.vinyl-cache.org/vtest/VTest2.git`;
  `.../branches/main` → `main: f19e3d7d31c0a80cd6b75bab135897710c2057b7 2026-09-15T17:12:28+02:00`.
  (WebFetch of the page also confirmed "We have left github", 2,437 commits, C 97.4%.)
* varnish-cache now vendors it as a git submodule — `https://raw.githubusercontent.com/varnishcache/varnish-cache/master/.gitmodules`:
  ```
  [submodule "bin/varnishtest/vtest2"]
      path = bin/varnishtest/vtest2
      url = https://github.com/vtest/VTest2.git
  ```
  and `gh api repos/varnishcache/varnish-cache/contents/bin/varnishtest` lists `file vtest2` (a gitlink), `dir tests`. So the DSL implementation is only in VTest2; varnish-cache keeps only the `.vtc` corpus.
* License: `https://raw.githubusercontent.com/vtest/VTest2/master/LICENSE` (`$R/vtest2.LICENSE.txt`) — "BSD 2-Clause License / Copyright (c) 2018, Vtest project". SPDX **BSD-2-Clause** (GitHub reports NOASSERTION because of the "Collection Copyright" preamble; the text is verbatim BSD-2).
* `brew search vtest` → nothing relevant (`vttest`, `vte3`, ...). `brew info --json=v2 varnish` → `varnish 9.0.4 https://www.varnish-cache.org/ BSD-2-Clause` exists as a formula, but I did **not** verify it ships `varnishtest` (`brew cat varnish` printed nothing in this shell); `which varnishtest vtest vtest2` → not found locally.

### 0.2 Building it (scratchpad only)

The GitHub `main` Makefile refuses: `make vtest` → `THIS REPOSITORY HAS MOVED. See README.rst` (rc=2). The `last` tag builds once pcre2 is on the include path (Homebrew keeps it out of the default path; Makefile line 34-36 hard-codes `-L/usr/local/lib ... -lpcre2-8`):

```
$ curl -sSL https://codeload.github.com/vtest/VTest2/tar.gz/refs/tags/last -o VTest2-last.tar.gz
$ gh api repos/vtest/VTest2/git/refs/tags/last --jq '.object.sha' → 803dcd000b1328f6e766774e23aedbd7f53e7d97
$ cd $R/tarballs/VTest2-last
$ make vtest -j4 CFLAGS="-O2 -g $(pkg-config --cflags libpcre2-8)" LDFLAGS="$(pkg-config --libs libpcre2-8)"
make rc=0
$ ./vtest -h
usage: vtest [options] file ...
    -b size                      # Set internal buffer size (default: 1M)
    -C                           # Use cleaner subprocess
    -D name=val                  # Define macro
    -E extension_shlib           # Load extension
    ...
    -j jobs                      # Run this many tests in parallel
    -k                           # Continue on test failure
    -t duration                  # Time tests out after this long
```
Binary: `$R/tarballs/VTest2-last/vtest` (376,440 bytes). `pkg-config --modversion libpcre2-8` → 10.47 (brew pcre2 10.47_1).

### 0.3 The DSL features that make black-box driving possible (cited from source)

`$R/samples/vtest2-vtc_http.c` (fetched from `https://raw.githubusercontent.com/vtest/VTest2/main/src/vtc_http.c`), lines 72–140:

```
 * \-listen STRING (server only)
 *        Dictate the listening socket for the server. STRING is of the form
 *        "IP PORT", or "/PATH/TO/SOCKET" for a Unix domain socket. ...
 * \-connect STRING (client only)
 *        Indicate the server to connect to. STRING is also of the form
 *        "IP PORT", or "/PATH/TO/SOCKET". ...
 * \-repeat NUMBER ... \-keepalive  For repeat, do not open new connections but rather run all iterations in the same connection
```
Spec commands available inside a `client {}` block (`rg -n 'SECTION: client-server\.spec\.' vtest2-vtc_http.c`, lines 274–1806): `expect`, `expect_pattern`, `rxresp`, `rxresphdrs`, `gunzip`, `txreq`, `rxreq`, `rxreqhdrs`, `rxreqbody`, `rxrespbody`, `rxchunk`, `recv`, `send`, `send_n`, `send_urgent`, `sendhex`, `chunked`, `chunkedlen`, `timeout`, `expect_close`, `close`, `accept`, `shutdown`, `fatal|non_fatal`, `txpri`, `rxpri`, `settings`, `write_body`. Verbatim docs: `send STRING — Push STRING on the connection.`; `sendhex STRING — Send bytes as described by STRING ... hex pairs`; `chunked STRING — Send STRING as chunked encoding.`; `expect_close — Reads from the connection, expecting nothing to read but an EOF.`; `txreq ... -proto STRING (default "HTTP/1.1") ... -nolen ... -hdr STRING ... -body/-bodylen/-gzipbody`.

`$R/samples/vtest2-vtc_process.c:897-` documents `process pNAME SPEC [-expect-exit N] [-expect-signal N] [-start] [-kill SIGNAL] [-wait] [-write STRING] ...` — "Run a process with stdin+stdout on a pseudo-terminal".

`$R/samples/vtest2-vtc_main.c:923` handles `case 'D':` → `extmacro_def(...)` (line 189); `varnishtest(1)` (`$R/samples/varnish-varnishtest.rst:40`) says `-D name=val      Define macro for use in scripts`.

### 0.4 Demo 1 — vtest spawns the server, connects to it, sends both a `txreq` and raw bytes

`$R/vtest-demo/demo-process.vtc`:
```
vtest "Drive an arbitrary external HTTP/1 server: vtest spawns it with 'process' and talks to it with 'client -connect'"
process p1 "exec python3 -m http.server ${port} --bind 127.0.0.1 --directory ${tmpdir}" -start
delay 1.5
client c1 -connect "127.0.0.1 ${port}" {
	txreq -url "/" -hdr "Host: localhost"
	rxresp
	expect resp.status == 200
	expect resp.http.server ~ "SimpleHTTP"
} -run
client c2 -connect "127.0.0.1 ${port}" {
	send "GET /nonexistent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	rxresp
	expect resp.status == 404
} -run
process p1 -kill TERM -expect-signal 15 -wait
```
```
$ ../tarballs/VTest2-last/vtest -v -D port=8097 demo-process.vtc
**** c2    http[ 0] |HTTP/1.0
**** c2    http[ 1] |404
**** c2    http[ 3] |Server: SimpleHTTP/0.6 Python/3.14.5
**   c2    === expect resp.status == 404
**** c2    EXPECT resp.status (404) == "404" match
**   top   === process p1 -kill TERM -expect-signal 15 -wait
**   p1    WAIT4 pid=5921 status=0x000f (user 0.150022 sys 0.081164)
#    top  TEST demo-process.vtc passed (1.815)
rc=0
```

### 0.5 Demo 2 — server started outside vtest, addressed only through a `-D` macro

`$R/vtest-demo/demo-extern.vtc` (python's http.server is HTTP/1.0 and closes after each response, hence one client per request):
```
client c1 -connect "${srv}" { txreq -url "/demo-extern.vtc"; rxresp; expect resp.proto == HTTP/1.0; expect resp.status == 200; expect resp.bodylen > 0; expect_close } -run
client c2 -connect "${srv}" { send "GET /does-not-exist HTTP/1.1\r\nHost: localhost\r\n\r\n"; rxresp; expect resp.status == 404; expect resp.http.connection == "close"; expect_close } -run
```
```
$ (nohup python3 -m http.server 8094 --bind 127.0.0.1 --directory . &) ; ../tarballs/VTest2-last/vtest -v -D srv="127.0.0.1 8094" demo-extern.vtc
**** c1    EXPECT resp.proto (HTTP/1.0) == "HTTP/1.0" match
**** c1    EXPECT resp.status (200) == "200" match
**** c1    EXPECT resp.bodylen (562) > "0" match
**   c1    === expect_close
**** c2    send|GET /does-not-exist HTTP/1.1\r
**** c2    EXPECT resp.status (404) == "404" match
**** c2    EXPECT resp.http.connection (close) == "close" match
**   c2    === expect_close
#    top  TEST demo-extern.vtc passed (1.658)
rc=0
```
(Two earlier attempts failed only on my expectations — a second `txreq` on a connection python had closed, and expecting a `Connection` header python's 200 path does not send — which is itself a nice demonstration that `expect` diffs precisely: `---- c1    EXPECT resp.http.connection (<undef>) == "close" failed`.)

### 0.6 Demo 3 — vtest's own Varnish-free self-test

`$ ./vtest -q tests/a00002.vtc` → rc=0 (`a00002.vtc: vtest "basic default HTTP transactions with expect and options"`). Of VTest2's 58 `tests/*.vtc`, `rg --files-without-match '^(varnish|haproxy) ' tests/*.vtc | wc -l` → **54** need neither Varnish nor HAProxy; they are `server`/`client` pairs exercising the DSL (`a00003 dual independent HTTP transactions`, `a00006 bidirectional message bodies`, `a00007 TCP reuse`, `a00011 gzip`, `a00016 Shutdown`, `a00019 rxrespbody -max`, `a00021 tunnel`, `a02000–a02020` HTTP/2).

**Conclusion for the design:** for fit (b) we get, for free, a scripted client that can send exact bytes (`send`/`sendhex`), pipelined requests (`txreq` twice before `rxresp`, see varnish `b00012`), chunked bodies, half-close (`shutdown`), timeouts, `expect_close`, and precise header/status/body assertions, plus `process` to spawn `chez --program server.sps` and `-expect-exit`/`-kill` to manage it. Our Makefile `test-blackbox` target = `vtest -k -j4 -t 20 -D srv="127.0.0.1 $PORT" test/vtc/*.vtc`. Downside: vtest is C, needs pcre2, and the GitHub mirror is frozen — vendoring the `last` tarball (BSD-2) or pinning `code.vinyl-cache.org` main is a CI decision to record as an ADR.

---

## 1. HAProxy reg-tests (.vtc) — tier 2

* URL: `https://github.com/haproxy/haproxy/tree/master/reg-tests` (confirmed by WebFetch of the directory page and by `gh api "repos/haproxy/haproxy/git/trees/master?recursive=1"` → `$R/haproxy-reg-tests.tree.txt`, 531 entries).
* License: `https://raw.githubusercontent.com/haproxy/haproxy/master/LICENSE` (`$R/haproxy.LICENSE.txt`): "Historically, haproxy has been covered by GPL version 2 ... All the files provided in this package are covered by the GPL unless expressly stated otherwise in them." → **GPL-2.0-or-later (with LGPL headers + OpenSSL exception)**; the `.vtc` files carry no separate notice, so they are GPL text. That is why this is tier 2 (rewrite the cases in our own words), not tier 1 (verbatim vendoring into a BSD-3 repo).
* Counts (`rg -c '\.vtc$' $R/haproxy-reg-tests.tree.txt` → **311** .vtc). Per directory (top): ssl 47, quic 30, converter 25, checks 25, **http-messaging 23**, **http-rules 22**, connection 19, cache 14 ... (`awk -F/ '{print $2}' | sort | uniq -c`).
* HTTP/1-only in http-messaging: `rg --files-without-match 'txpri|quic' http-messaging/*.vtc` → **14** files: `http_splicing, http_request_buffer, h1_authority_fragment_char, srv_ws, http_bodyless_response, http_transfer_encoding, h1_host_normalization, h1_to_h1, http_bodyless_spliced_response, http-ntlm, http_abortonclose, http_splicing_chunk, http_wait_for_body, h1_request_target_validation`. 9 use an H2 client (`txpri`).
* Case density: `rg -c '^\s*txreq' http-messaging/*.vtc http-rules/*.vtc | awk ... ` → **408** client requests across those two dirs; `h1_request_target_validation.vtc` 13 clients/13 expects; `http_transfer_encoding.vtc` 19 clients / 40 tx / 53 expects; `h1_host_normalization.vtc` 49 clients / 98 expects; `h1_to_h1.vtc` 5 clients / 14 tx / 50 expects. Repo-wide: 277 files use `feature ignore_unknown_macro`; 76 files push raw bytes with `send "`.
* Titles (`for f in http-messaging/*.vtc; do rg -m1 '^varnishtest ' $f; done`): "H1 absolute-form URI whose authority is terminated by '#' (rfc3986 3.2)", "H1 authority validation and host normalizarion based on the scheme (rfc3982 6.3.2) or the method (connect)", "HTTP request tests: H1 request target parsing", "HTTP request tests: H1 to H1", "A test to validate Transfer-Encoding header conformance to the spec", "A test to be sure payload is skipped for bodyless responses", "A test for the abortonclose option (H1 only)", "h2 desync attacks", "H2 trailers parsing", "WebSocket test", "h1/h2 support for protocol upgrade test", ...
* What the good ones contain (verbatim from `$R/samples/haproxy-h1_request_target_validation.vtc`):
  ```
  client c4 -connect ${h1_li1_sock} { txreq -req "OPTIONS" -url "*/test"; rxresp; expect resp.status == 400 } -run
  client c5 ... { txreq -req "GET" -url "*" ... expect resp.status == 400 }
  client c6 ... { txreq -req "CONNECT" -url "haproxy.org:80" -hdr "Host: haproxy.org" ... expect resp.status == 200 }
  client c9 ... { txreq -req "CONNECT" -url "http://haproxy.org:80" ... expect resp.status == 400 }
  client c12 ... { txreq -req "GET" -url "haproxy.org:80" ... expect resp.status == 400 }
  ```
  and from `http_transfer_encoding.vtc` (server side, i.e. what a *client* of ours would need to reject): `Transfer-Encoding: chunked, chunked`, `chunked, gzip, chunked`, `chunked, gzip`, `gzip`; HTTP/1.0 + TE chunked; `Transfer-Encoding: chunked` + `Content-Length: 30` + `0\r\n\r\nResponse splitting attach`; invalid trailers `x tlr: value`, `:status: 200`, `: value`, `x-tlr: val\rue`.
* Adaptation: each file = `haproxy h1 -conf { listen li1; bind "fd@${li1}"; http-request return status 200 }` + clients connecting to `${h1_li1_sock}`. Replace the `haproxy` block with `process p1 "chez --program ... --port ${port}" -start` and `-connect "127.0.0.1 ${port}"`; `syslog`/`barrier` sections (used by `h1_host_normalization.vtc` to check normalized URIs via log lines) must be re-expressed as a handler that echoes the request-target/Host into the response. Fits **(b)** directly; **(a)** after transcribing `txreq`/`expect` into Scheme.
* Reference reading: `$R/samples/haproxy-regression-testing.txt` (706 lines, `doc/regression-testing.txt`), `reg-tests/README` (`$R/haproxy-reg-tests.README.txt`: "vtest is run with -t10 and -l"), `scripts/run-regtests.sh:275`: `cmd="$VTEST_PROGRAM -b $((4<<20)) -k -t ${VTEST_TIMEOUT} -L $verbose $debug $jobcount $vtestparams $testlist"`.

## 2. Varnish `bin/varnishtest/tests/*.vtc` — tier 2

* URL: `https://github.com/varnishcache/varnish-cache/tree/master/bin/varnishtest/tests` (WebFetch + tree `$R/varnish-tests.tree.txt`, 872 entries, **866 .vtc**).
* License: `https://raw.githubusercontent.com/varnishcache/varnish-cache/master/LICENSE` (`$R/varnish.LICENSE.txt`): `SPDX-License-Identifier: BSD-2-Clause`, "Copyright (c) 2006 Verdens Gang AS / 2006-2021 Varnish Software AS". **BSD-2-Clause** — vendor-compatible.
* Naming (`$R/varnish-tests.README.txt`, verbatim): `[id]%05d.vtc`, `b` Basic, `c` Complex, `f` Security, `i` Interoperability and standards compliance, `r` Regression (same number as ticket), `t` Transport, `s` Slow ... Counts by prefix: r 375, c 130, b 98, v 64, e 38, t 28, m 22, u 22, d 16, s 14, f 10, g 9, o 8, l 8, h 7, p 10 (`sed -E 's#.*/([a-z])[0-9]+\.vtc#\1#' | sort | uniq -c`).
* Dependency reality: `rg -l '^varnish ' *.vtc | wc -l` → **854 of 866 start a `varnish v1` instance**; only 12 do not (`c00003 h00001-5 j00003 r02321 r02325 r03159 r04298 u00018`). So the corpus is not runnable as-is against us; the *client halves* are the reusable part.
* HTTP/1 request-handling files worth transcribing (titles from `head -1`):
  * `b00012 "Check pipelining"`, `b00013 "Check read-head / partial pipelining"`, `b00055/b00056` (same over UDS), `c00108 "Session pipelining exceeding available workspace"`
  * `b00040 "test certain malformed requests and validate_headers"` — raw `send "GET /1 HTTP/1.1\r\n"; send " Host: foo\r\n"` (leading SP → 400), `"\rHost: foo\r\n"` (bare CR → 400), ctrl chars 0x01/0x0d, missing header name
  * `b00047 "Check that all but HTTP/1.0 and HTTP/1.1 get 400"` — `GET /\r\n\r\n`, `HTTP/0.5`, `HTTP/1.2`, `HTTP/2.0` → 400
  * `b00049 "RFC 9110 compliance"`, `b00069 "HTTP/1 parsing checks"` — e.g. `send "POST / HTTP/1.1\r\nHost: asdf.com\r\nAsdf: b\n \r\n\r\nSj\r"` (obs-fold + leftover buffer)
  * `c00039 "request req and hdr length limits"` — 256-byte request built from exact 32-byte lines; `expect_close` at 257
  * `r01729 "C-L/T-E:chunked conflict"` — `Content-Length: 31` + `Transfer-Encoding: chunked` → 400 (request) / 503 (response)
  * `r01843 "HTTP/1.0 POST and PUT need a valid Content-Length"` → 400; `r00262 "inter-request whitespace trimming"`; `r01367 "blank GET"`; `r00387 "too long chunk header"`; `f00001 "bogusly large chunks"`; `f00016 "Do not tolerate anything else than CRLF as chunked ending"`; `r01691 "bogus Content-Length header"`; `b00011 "HTTP/1.0 EOF transmission"`; `b00080 "Keep-Alive is a hop-by-hop header"`; `c00136 "Rearm timeout_idle upon HTTP/1 keep-alive"`; `r03189 "h1 send_timeout and streaming of dripping chunks"`.
  * `rg -l '^\s*send "(GET|POST|...) ' *.vtc | wc -l` → 25 files push raw request bytes; 67 mention Transfer-Encoding; 70 use `expect_close`; 22 use `sendhex`.
* Adaptation: as for HAProxy — keep `client cN { ... }`, replace `varnish v1 -vcl+backend {} -start` with `process`/`-D`; the `server s1` backend that supplies the response has no analogue for an origin server, so the expected status must be re-derived for our handler (Varnish is a proxy: e.g. `r01729` expects 503 where we would answer 400). Fits **(b)**; individual `send` payloads are trivially (c).

## 3. nginx-tests (Perl `.t`) — tier 2

* URL: `https://github.com/nginx/nginx-tests` (WebFetch: "Perl", "prove", ports 8000–8999; tree `$R/nginx-tests.tree.txt` 513 entries, `rg -c '\.t$'` → **501** test scripts).
* License: `https://raw.githubusercontent.com/nginx/nginx-tests/master/LICENSE` (`$R/nginx-tests.LICENSE.txt`) — "Copyright (C) 2008-2011 Maxim Dounin" with exactly two conditions → **BSD-2-Clause**. Vendor-compatible.
* README (`$R/tarballs/nginx-tests/README`): `TEST_NGINX_BINARY=/path/to/nginx prove .`; `lib/Test/Nginx.pm:34` reads `$ENV{TEST_NGINX_BINARY}`.
* The helper every test uses (`lib/Test/Nginx.pm:845-955`, verbatim core):
  ```perl
  sub http_get($;%) { my ($url, %extra) = @_; return http(<<EOF, %extra);
  GET $url HTTP/1.0
  Host: localhost

  EOF
  }
  sub http_start($;%) { ... $s = $extra{socket} || IO::Socket::INET->new(Proto => 'tcp', PeerAddr => '127.0.0.1:' . port($port), %extra) ...
      $s->print($request); select undef, undef, undef, $extra{sleep} if $extra{sleep}; ... if ($extra{body}) { $s->print($extra{body}); } }
  sub http_end($;%) { ... local $/; $reply = $s->getline(); $s->close(); ... }
  ```
  i.e. raw bytes out, slurp until EOF, regex on the reply; `sleep`/`body`/`socket` extras give split writes and reuse.
* HTTP/1-core files (not module-prefixed) and `http(` call counts (`for f in ...; rg -c 'http(_get|_head)?\(' $f`): `body.t 4 (plan 15)`, `body_chunked.t 4 (18)`, `client_body_early_read.t 5 (skip_all)`, `headers.t 22 (28)`, `http_expect_100_continue.t 1 (5)`, `http_header_buffers.t 10 (10)`, `http_headers_multi.t 4 (47)`, `http_host.t 2 (60)`, `http_keepalive.t 3 (21)`, `http_keepalive_shutdown.t 1`, `http_max_headers.t 1 (2)`, `http_method.t 4`, `http_request_port.t 4 (5)`, `http_uri.t 19 (19)`, `ignore_invalid_headers.t 5 (12)`, `merge_slashes.t 2`, `request_id.t 5 (12)`, `server_tokens.t 2 (12)`, `trailers.t 3 (17)` — roughly **19 files / ~330 planned assertions** on plain HTTP/1 behaviour (keepalive_requests/keepalive_timeout, large_client_header_buffers, client_max_body_size 413, chunked pipelining, Expect: 100-continue, Host validation, request-line/URI oddities).
* Sample (`body_chunked.t:104-114`): `http_get_body('/', '0123456789', '0123456789' x 128, '0123456789' x 512, 'foobar')` → "chunked body pipelined"; `http_header_buffers.t:88-100`: `"GET / HTTP/1.0" . CRLF . "X-Foo: " . ("1234567890" x 20) . CRLF ...` → `qr/204|400/`.
* Adaptation: expectations are tied to the embedded `nginx.conf` (`%%TEST_GLOBALS%%`, `listen 127.0.0.1:8080`, `return 204`, `add_header X-...`), so vendoring verbatim buys nothing; instead **transcribe the request byte strings + regex into our fixture format** (fits **(c)** and **(b)**), and keep `Test::Nginx::http()` as the model for a 30-line Scheme `http-roundtrip` helper for (a). Not a tier-1 candidate because there is no separable data file — the data is inline Perl.

## 4. Apache httpd-tests `t/apache/http_strict.t` and friends — tier 1

* URL: `https://github.com/apache/httpd-tests` (WebFetch: "Testing Apache httpd with the Perl Test Harness", Apache::Test, "over 4,000" tests; `gh api repos/apache/httpd-tests --jq '.license.spdx_id, .default_branch'` → `Apache-2.0`, `trunk`). Tree `$R/httpd-tests.tree.txt` 1507 entries; `find t -name '*.t' | wc -l` → 206; `t/apache/*.t` → 44.
* License: **Apache-2.0** (`$R/tarballs/httpd-tests/LICENSE` head: "Apache License Version 2.0, January 2004"). Compatible with BSD-3 vendoring provided the LICENSE/NOTICE travel with the copied data.
* Raw-socket tests in `t/apache` (`rg -l 'vhost_socket' t/apache/*.t`): `chunkinput.t headers.t hostcheck.t contentlength.t pr18757.t pr35292.t http_strict.t server_name_port.t mergeslashes.t teclchunk.t`.
* **`t/apache/http_strict.t`** (`$R/httpd-http_strict.t`, 243 lines; `rg -c '^\s*\[ "'` → **88 table rows**) is a pure data table: `[ raw-request-bytes => expected_unsafe, expected_strict ]` with the legend (lines 15-19): `0: any HTTP error / 1: any HTTP success / 200-500: specific status / undef: HTTPD should drop connection without error message`. Verbatim rows (lines 21-70):
  ```
  [ "GET / HTTP/1.0\n\n"                                    =>   1, 400],
  [ "get / HTTP/1.0\r\n\r\n"                                => 501],
  [ "G\0ET / HTTP/1.0\r\n\r\n"                              => 400],
  [ "GET\t/ HTTP/1.0\r\n\r\n"                               => 400],
  [ "GET / HTTP/1.11\r\nHost: localhost\r\n\r\n"            => 400],
  [ "GET / HTTP/10.0\r\nHost: localhost\r\n\r\n"            => 400],
  [ "GET / HTTP/1.0  \r\nHost: localhost\r\n\r\n"           => 200, 400],
  [ "GET / HTTP/1.0\r\nFoo: b\0ar\r\n\r\n"                  => 400],
  [ "GET / HTTP/1.0\r\nFoo bar:bash\r\n\r\n"                => 400],
  [ "GET / HTTP/1.0\r\nFoo :bar\r\n\r\n"                    => 400],
  [ "GET / HTTP/1.0\r\n Foo:bar\r\n\r\n"                    => 400],
  [ "GET / HTTP/1.0\r\nFo: bar\r\r\n\r\n"                   => 400],
  [ "GET / HTTP/1.0\r\r"                                  => undef, undef],
  [ "GET /\r\n"                                           =>    90, undef],
  [ "GET / HTTP/1.0\r\nHost: localhost\r\n" . "Host: localhost\r\n\r\n"             => 200, 400],
  [ "GET http://localhost:80x/ HTTP/1.0\r\n\r\n"            => 400],
  [ "GET http://[4712::abcd::]/ HTTP/1.0\r\n\r\n"           => 400],
  [ "GET / HTTP/1.0\r\nHost: abc\\foo\r\n\r\n"              => 400],
  ```
  The driver (lines 165-238): `vhost_socket($vhost); $sock->print($req); $sock->shutdown(1); ... HTTP::Response->parse($response_data)`; the "R..." rows (lines 113-127) exercise *response* header validation via a CGI and need `mod_cgi` — skip those.
* Companions: `chunkinput.t` (`$R/samples/httpd-chunkinput.t`): 9 chunk-size strings (`"A; ext=val"`, `"A    "` BWS, `"A :: :: :: "` split into packets with 0.5 s sleeps, 35 hex digits → 413, `\x7F` in extension → 400, leading space → 400) × 2 URIs = 18 expected status lines; `teclchunk.t`: `Content-Length: 77` + `Transfer-Encoding: chunked` + trailer + a pipelined `GET` that "MUST fail" (smuggling); `headers.t`: obs-fold table (`"Hello: Foo\r\n Bar\r\n" => ["Hello","Foo Bar"]`, tabs, trailing WS); `limits.t`: LimitRequestLine (414), LimitRequestFieldSize (400), LimitRequestFields 64 (400), LimitRequestBody (413), merged field size; `hostcheck.t`, `contentlength.t`, `mergeslashes.t`, `server_name_port.t`.
* Adaptation: extract `@test_cases` into a data file (`test/vendor/httpd-tests/http_strict.tsv` + the exact LICENSE/NOTICE); each row becomes (bytes, expected-class) for **(c)** (feed at every split), **(a)** and **(b)**. The double column (unsafe vs strict) maps onto our lenient-flags choice. Note the 0/1/90/undef classes mean the oracle is a *class*, not an exact status — our runner needs an "any 4xx" matcher. **Tier 1.**

## 5. lighttpd `tests/request.t` — tier 1

* URL: `https://github.com/lighttpd/lighttpd1.4/tree/master/tests` (WebFetch listed `request.t core-condition.t mod-fastcgi.t mod-scgi.t LightyTest.pm run-tests.pl README`; tree `$R/lighttpd-tests.tree.txt`).
* License: `https://raw.githubusercontent.com/lighttpd/lighttpd1.4/master/COPYING` (`$R/lighttpd.COPYING.txt`: "Copyright (c) 2004, Jan Kneschke, incremental ... three conditions"); `gh api repos/lighttpd/lighttpd1.4 --jq .license.spdx_id` → **BSD-3-Clause** — identical family to ours.
* Size: `$R/lighttpd-request.t` 1784 lines, `use Test::More tests => 172`, `rg -c 'handle_http'` → **168** request blocks (+11 in `core-condition.t`). Section markers (`rg -n '^## '`): `19 Basic Request-Handling`, `429 ranges`, `703 Low-Level Response-Header Parsing - HTTP/1.1`, `715 ... Content-Length`, `735 ... Location`, `766 simple-vhost`, `785 keep-alive`, `880 404 handlers`, then module-specific (`mod_auth`, `mod_cgi`, `mod_deflate`, `mod_proxy` ...). The generic sections 19–428 and 703–878 are ~60 cases.
* Format (verbatim, `request.t:21-50`):
  ```perl
  $t->{REQUEST}  = ( <<EOF
  GET /index.html%00 HTTP/1.0
  EOF
   );
  $t->{RESPONSE} = [ { 'HTTP-Protocol' => 'HTTP/1.0', 'HTTP-Status' => 400 } ];
  ok($tf->handle_http($t) == 0, 'URL-encoding, %00');

  $t->{REQUEST}  = ( <<EOF
  POST /12345.txt HTTP/1.0
  Host: 123.example.org
  Content-Length: 2147483648
  EOF
   );
  $t->{RESPONSE} = [ { 'HTTP-Protocol' => 'HTTP/1.0', 'HTTP-Status' => 413 } ];
  ```
  Pipelined blocks are a single heredoc with a blank line between requests and a two-element RESPONSE list (`request.t:787-878`: explicit/implicit HTTP/1.0 and 1.1 keep-alive, "extra blank b/w requests" → 200/200, "excess blank" → 200 then `HTTP/1.0 400`). `SLOWREQUEST` (`:645`) splits the final CRLFCRLF into four separate writes.
* Harness semantics that a re-implementation must copy (`$R/samples/lighttpd-LightyTest.pm`, `sub handle_http`): `s/\r(?=\n)//gs; chomp; s/\n/$EOL/gs;` then `print $remote $_,$BLANK;` (so heredoc LF becomes CRLF and the blank line is appended), TCP_NODELAY, `shutdown($remote, 1)` half-close, read to EOF, then per-response: status line regex `^(HTTP\/1\.[01]) ([0-9]{3}) .+$`, headers lower-cased and comma-joined on duplicates, body cut by `content-length`.
* Adaptation: mechanical — a 40-line Perl/Scheme extractor turns each block into `(request-bytes, [(proto status headers body)...])`. Fits **(a)**, **(b)**, **(c)** (pipelined blocks are exactly the multi-message-per-buffer case). Vendor the generic sections as data with LICENSE. **Tier 1.**

## 6. h2o `t/40*.t` — tier 2

* URL: `https://github.com/h2o/h2o/tree/master/t` (WebFetch: numbering "00 unit, 10 module e2e, 40 protocol"; tree `$R/h2o-t.tree.txt` 355 entries, 235 numbered `.t`). `gh api repos/h2o/h2o --jq .license.spdx_id` → **MIT**; `$R/h2o.LICENSE.txt` "Copyright (c) 2014 DeNA Co., Ltd." MIT text.
* HTTP/1-relevant (`rg '^t/40.*\.t$' | rg -i 'http1|chunk|pipel|...'`): `40bad-request.t 40chunked.t 40expect.t 40http1-pipeline.t 40http1-streaming-framing.t 40http1-timeouts.t 40max-connections.t 40protocol.t 40proxy-protocol.t 40soft-connection-limit.t` (+ h2/h3-specific). Subtest counts: `40http1-pipeline.t` 3, `40chunked.t` 2, `40protocol.t` 9, `40bad-request.t` 6 assertions.
* Verbatim value (`$R/samples/h2o-40bad-request.t`): `nc` one-liners — empty request → silent close; `"GET / HTTP/1.2\r\na\r\n\r"` → `400 ... Content-Length: 11 ... Bad Request`; `"\r"` → silent close; `" / HTTP/1.1\r\n\r\n"` missing method → 400; `"GET  HTTP/1.1\r\n\r\n"` missing path → 400; `"GET / HTTP/1.1\r\nfoo: FOO\r\n    hoge\r\n\r\n"` → 400 "line folding of header fields is not supported". `40http1-pipeline.t`: two GETs; `POST` with `Content-Length: 5` body `abc\r` followed by GET; chunked POST (`5\r\nabc\r\n\r\n0\r\n\r\n`) followed by GET — expects `405 ... 200` in order (405 because the file handler rejects POST).
* Adaptation: every test calls `spawn_h2o(<<YAML)` from `t::Util` and needs the h2o binary, `nc`/`curl`; the raw request strings and the *shape* of expectations (order of statuses in a pipelined reply, exact body on 400) are what to transcribe. Fits **(b)** after transcription, **(c)** for the byte strings. Tier 2.

## 7. Apache Traffic Server `tests/gold_tests` + Proxy Verifier replay YAML — tier 2

* URL: `https://github.com/apache/trafficserver/tree/master/tests/gold_tests` (WebFetch listed `chunked_encoding headers pipeline bad_http_fmt timeout proxy_protocol client_connection post ...`); `gh api repos/apache/trafficserver --jq .license.spdx_id` → **Apache-2.0**. Tree `$R/ats-gold.tree.txt` 2049 entries: **587 `.test.py`** autest scripts and **323 `*.replay.yaml|json`** files.
* HTTP/1 framing directories: `chunked_encoding/replays/` (12 files: `chunk_extension_quoted_string, chunk_trailer_bare_lf, chunked, chunked_h1_flow_control, chunked_in_http_1_0, chunked_not_last, chunked_passthru_flow_control, chunked_trailer_dropped, chunked_trailer_proxied, large_chunked, malformed_chunked_header, ...`), `chunked_encoding/smuggle-client.c`, `bad_http_fmt/` (9 `printf ... | nc` requests: `GET /sdfsdf/0HTTP/1.0` no-space, `GET /sdfsdf<HTTP/1.1`, `HTTP/1.2`, `HTTP/0.9`, unknown method `xyzxyz`, IPv6), `headers/` (`good_request_after_bad.test.py`, `field_name_space.test.py`, `oversized_field.test.py`, `malformed_host_port.test.py`, gold files `bad_method.gold bad_protocol_number.gold bad_te_value.gold invalid_character_in_te_value.gold`).
* Replay format (verbatim from `$R/samples/ats-chunked_encoding_replays_malformed_chunked_header.replay.yaml`):
  ```yaml
  sessions:
  - transactions:
    - client-request:
        method: "POST"
        version: "1.1"
        url: /malformed/chunk/header
        headers:
          fields:
          - [ Host, example.com ]
          - [ Transfer-Encoding, chunked ]
          - [ uuid, 1 ]
        content:
          transfer: plain
          encoding: uri
          # Chunk header sizes are in hex, so a size of `z` is malformed.
          data: z%0D%0Aabcwxyz%0D%0A0%0D%0A%0D%0A
      # The connection will be dropped and this response will not go out.
      server-response:
        status: 200
  ```
  Cases in that one file: chunk size `z`, `3z`, `111111113` (int overflow), `3\r\r\n` (CR in BWS), `7;x\n` (bare LF after extension), `7\r` (bare CR), `3\n`, `1\r\n\r\n` (size 1, no data) — 8 request-side + 7 response-side. `chunked_not_last.replay.yaml`: `Transfer-Encoding: "chunked, gzip"` → expect 501 (RFC 9112 §6.3).
* Driver: **Proxy Verifier** `https://github.com/yahoo/proxy-verifier` (`gh api` → Apache-2.0, not archived, pushed 2026-09-03; `$R/samples/proxy-verifier-README.md` 2500 lines, "HTTP/1.x and HTTP/2", `verifier-client run --connect-http 127.0.0.1:8081 <replay_file_or_directory>`; `--format "{url}"` chooses the transaction key; `--no-proxy`). It can point straight at our port (fit **(b)**), and `encoding: uri` bodies give exact malformed bytes. But its client validates responses against `server-response`/`proxy-response` blocks written for a proxy, and needs C++/OpenSSL build; the yaml is also easy to read into our own driver (fit **(c)**).
* Tier 2: the replay yaml is worth extracting (chunk edge cases are the best I found in this lens), the autest `.test.py` scaffolding is not.

## 8. Envoy `test/common/http/http1/codec_impl_test.cc` + fuzz corpus — tier 3

* URL: `https://github.com/envoyproxy/envoy/blob/main/test/common/http/http1/codec_impl_test.cc` (WebFetch: 5,435 lines, 214 KB); raw copy `$R/envoy-codec_impl_test.cc`: `wc -l` 5435; `rg -c '^TEST_(P|F)\('` → **239** (`153 Http1ServerConnectionImplTest`, `86 Http1ClientConnectionImplTest`, names in `$R/envoy-test-names.txt`). `gh api repos/envoyproxy/envoy --jq .license.spdx_id` → **Apache-2.0**.
* Payload literals: `rg -c 'Buffer::OwnedImpl buffer\("'` → 120 (`17× "GET / HTTP/1.1\r\n\r\n"`, `6× "POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n"`, `"GET / HTTP/1.1\r\nHOST: h.com\r\nfoo_bar: bar\r\n\r\n"`, `"BAD / HTTP/1.1\r\n"`, `"QUERY /search HTTP/1.1..."`, `"OPTIONS * HTTP/1.1..."`). Example (`:772-794`): `InvalidChunkHeader` feeds `"POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n6\r\nHello \r\ninvalid\r\nWorl"` and expects `sendLocalReply` with no `decodeData`. Other named edge cases: `IdentityEncodingNoChunked`, `UnsupportedEncoding`, `ContentLengthAllBitsSet`, `ChunkedBodySplitOverTwoDispatches`, `ChunkedBodyFragmentedBuffer`, `IdentityAndChunkedBody`, `HostWithLWS`, `InnerLWSIsPreserved`, `Http10`, `EmptyHeader`.
* Sibling corpus `test/common/http/http1/http1_connection_corpus/case000..case071` (72 raw-bytes libFuzzer seeds; `$R/samples/envoy-corpus-case*`): all are the same template (`GET|HEAD|POST|PUT / HTTP/1.0|1.1|3` + duplicated `transfer-encoding: deflate`, `:scheme`, `content-length: N` + `A×N`) — low diversity; the harness `http1_connection_fuzz_test.cc` (104 lines) just calls `server_->dispatch(payload)`.
* Balsa parser tests `balsa_parser_test.cc`: 8 `TEST(` (token characters in names/methods).
* Adaptation: hand-extract ~20 payload+expectation pairs into our (c) fixture format; the gmock expectations (`decodeHeaders_(HeaderMapEqual(...))`) are Envoy-internal. Tier 3 (reference).

## 9. curl `tests/data` — tier 3 (server side) / useful request-byte source

* URL: `https://github.com/curl/curl/tree/master/tests/data` (WebFetch: GitHub truncates at 1,000 of >2,100 entries). Tree: `rg -c '^tests/data/test[0-9]+$' $R/curl-tests.tree.txt` → **2109** test files. Format spec is at `docs/tests/FILEFORMAT.md` (822 lines; NOT `tests/FILEFORMAT` — confirmed by tree grep), saved as `$R/samples/curl-FILEFORMAT.md`.
* License: `https://raw.githubusercontent.com/curl/curl/master/COPYING` (`$R/curl.COPYING.txt`): "Copyright (c) 1996 - 2026, Daniel Stenberg ... Permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby granted" → **curl** (SPDX `curl`, MIT/X-derivative; GitHub says NOASSERTION/"Other").
* Counts in `$R/tarballs/curl/tests/data`: `HTTP` keyword 1084; `<server>http` 1165; `<protocol>` verify sections **1615**; server responses with `Transfer-Encoding: chunked` 60; `swsclose` 339; `%CR|%LF` escapes 114; `HTTP/1.0` responses 61; `<servercmd>` 313; `Expect: 100-continue` 25.
* Shape (verbatim `test1`): `<reply><data crlf="headers">HTTP/1.1 200 OK ... Connection: something-close, close-something, close ...</data></reply>` and `<verify><protocol crlf="headers">GET /%TESTNUMBER HTTP/1.1\nHost: %HOSTIP:%HTTPPORT\nUser-Agent: curl/%VERSION\nAccept: */*\n\n</protocol>`; `test207`: chunked response cut short (`41%CR ... ` then close) → `CURLE_PARTIAL_FILE`.
* Why tier 3 for a *server*: the corpus is a client-conformance suite; `<reply><data>` are *responses* (useful only for a response-parser or for checking our serializer against what a client accepts), `<verify><protocol>` are exact well-formed *requests* curl emits (a good source of ~1600 benign request byte streams for (c) smoke/pipelining coverage, after `%VAR` substitution). The `sws` test server (`tests/server/sws.c`) is not reusable for us.

## 10. Squid `src/tests/testHttp1Parser.cc` — tier 3

* URL: `https://github.com/squid-cache/squid/blob/master/src/tests/testHttp1Parser.cc`; `gh api repos/squid-cache/squid --jq .license.spdx_id` → **GPL-2.0** (blocks verbatim vendoring). Tree shows `src/http/one/{Parser,RequestParser,ResponseParser,TeChunkedParser}.cc`; `test-suite/` holds only config/unit helpers (no HTTP corpus).
* `$R/squid-testHttp1Parser.cc`: 1202 lines; 7 `CPPUNIT_TEST`s (`testParserConstruct, testDripFeed, testParseRequestLineMethods, testParseRequestLineProtocols, testParseRequestLineTerminators, testParseRequestLineStrange, testParseRequestLineInvalid`); `rg -c 'input\.(assign|append)\('` → **41** inputs, 50 `testResults(__LINE__...)` checks. Each case is `input.append("GET / HTTP/1.2\r\n", 16); struct resultSet expect = { .parsed, .needsMore, .parserState, .status, .suffixSz, .method, .uri, .version }` — e.g. `GET /\r\n` → HTTP/0.9 OK; `POST /\r\n` → 400; `HTTP/2.0`/`HTTP/9.9` request-lines accepted as syntax; `HTTP/10.12` → 400 (lines 192-330). `testDripFeed` feeds one byte at a time (= our chunk-size replay idea).
* Use only as a *decision reference* for HTTP/0.9, multi-digit versions, tolerant CR handling (RFC 9112 §2.2 notes at lines 568-877).

---

## Not selected / notes

* **Squid `test-suite/`** contains no HTTP message corpus (only `squidconf/*.conf`, auth-helper scripts).
* **h2o's `deps/picohttpparser/test.c`** (MIT) is a parser unit table, outside this lens (parser lens should pick it up).
* **HAProxy `reg-tests/http-rules`** (22 files) is mostly ACL/rewrite behaviour; only worth mining for `send`-based malformed inputs.
* **Homebrew `varnish` 9.0.4** exists; whether it installs `varnishtest` was not verified here.
* **VTest2 from code.vinyl-cache.org**: the Gitea archive URL I tried (`/archive/main.tar.gz`) did not return a tarball; clone via git if the current version is wanted. The GitHub `last` tag (803dcd0) builds and is what all demos used.

## Recommendation summary

| # | corpus | tier | license | fits |
|---|---|---|---|---|
| 0 | VTest2 (vtest driver + 54 Varnish-free self-tests) | 1 (driver) | BSD-2-Clause | b |
| 4 | httpd-tests `http_strict.t` table (+chunkinput/teclchunk/headers/limits) | 1 | Apache-2.0 | a b c |
| 5 | lighttpd `request.t` generic sections | 1 | BSD-3-Clause | a b c |
| 1 | HAProxy `reg-tests/http-messaging` (14 H1 files) | 2 | GPL-2.0 (rewrite, don't copy) | b (a) |
| 2 | Varnish `bin/varnishtest/tests` (~35 H1 files) | 2 | BSD-2-Clause | b (c) |
| 3 | nginx-tests HTTP/1-core `.t` (19 files) | 2 | BSD-2-Clause | c b |
| 6 | h2o `t/40*.t` (10 files) | 2 | MIT | b c |
| 7 | ATS replay yaml (chunked_encoding, headers, bad_http_fmt) + Proxy Verifier | 2 | Apache-2.0 | c b |
| 8 | Envoy `codec_impl_test.cc` (239 tests) | 3 | Apache-2.0 | c |
| 9 | curl `tests/data` (2109; 1615 `<protocol>` request samples) | 3 | curl | c |
| 10 | Squid `testHttp1Parser.cc` (41 inputs) | 3 | GPL-2.0 | — |
