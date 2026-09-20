# Skeptic verification — corpus candidates batch 2 (relevance & adaptability)

Verification date: 2026-09-19. All files fetched directly via `curl` from
`raw.githubusercontent.com` at the exact commit SHAs given in each candidate
(not via GitHub's web UI, not via WebFetch summarization), then inspected
with `cat`/`sed`/`grep`/`wc` so counts below are exact byte-for-byte counts
of the fetched files, saved locally under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/fetched/`.

Lens applied throughout: is this HTTP/1.x **server-side / connection-semantics**
material (keep-alive, pipelining, framing precedence, close, upgrade, limits,
timeouts, smuggling), or is it parser-only (redundant with the llhttp corpus
already vendored into chez-httparse), client-only, or HTTP/2-only? Can it be
turned into byte streams / scripted client sessions we replay against
chez-http-server? What is a grounded hours estimate to extract it?

---

## 1. `httpd-tests-http-strict` (Apache httpd-tests)

**Verdict: CONFIRMED, tier 1 upheld. Not refuted.**

Fetched at commit `4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4`:
- https://raw.githubusercontent.com/apache/httpd-tests/4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4/t/apache/http_strict.t (243 lines)
- .../chunkinput.t (95 lines), teclchunk.t (58 lines), headers.t (91 lines),
  limits.t (169 lines), hostcheck.t, contentlength.t (77 lines),
  mergeslashes.t, server_name_port.t
- LICENSE: https://raw.githubusercontent.com/apache/httpd-tests/4c187f27ecbf498a28c5a1c9b4de5873a8ad1ca4/LICENSE — confirmed standard Apache License 2.0 text.

Checks performed:
- `grep -c '^\s*\[ "' http_strict.t` → **88**, matching the finder's "88 table
  rows" claim exactly. Rows are `[ bytes => unsafe_expect, strict_expect? ]`;
  the driver (lines 150-238) runs the table twice, once against an
  `http_unsafe` vhost (column 1) and once against `http_strict` (column 2,
  falling back to column 1 when absent) — this is exactly the unsafe/strict
  double-column the finder described and maps cleanly onto a lenient-flags
  choice in chez-httparse.
- The 9 rows prefixed `"R"` (lines 110-117) are indeed response-header tests
  routed through `send_hdr.pl`/CGI, correctly flagged by the finder as
  skippable — confirmed by reading the `if ($req =~ s/^R//)` branch (lines
  107-116... actually gated around line 155-158 in the full driver).
- `chunkinput.t`: `@test_strings` has 9 entries × 2 `@req_strings` = **18**
  request/response pairs, exactly matching the "18 chunk-size cases" claim.
  Confirmed raw-socket driven (`Apache::TestRequest::vhost_socket`, manual
  `$sock->print`), directly byte-stream replayable.
- `teclchunk.t`: single CL:77 + `Transfer-Encoding: chunked` request whose
  chunked body self-terminates early, followed by an embedded second
  request in the same TCP segment; asserts the smuggled `GET
  /i_do_not_exist...` is *not* answered (i.e. TE must win over CL and the
  connection must not be desynced). Confirmed genuine request-smuggling
  regression material, directly relevant to the CL+TE precedence rule our
  connection layer must implement.
- `headers.t`: obs-fold table (`$hasfix` branch) has **9** entries, matching
  "9 obs-fold rows" claim exactly. Requires a CGI backend (`env.pl`) to
  observe the canonicalized header value the backend receives — adapting
  this needs a stub CGI-equivalent handler, not just a byte-level check.
- `limits.t`: 5 conditions × 2 (succeed/fail) = **10** cases, matching
  claim. Important caveat the finder did not fully flag: this file does
  **not** send raw bytes — it builds requests via LWP's `HTTP::Request`/
  `GET()` helper (`Apache::TestRequest`), and the actual boundary values
  (`LimitRequestLine`, `LimitRequestFieldSize 1024`, `LimitRequestFields
  32`, `LimitRequestBody 65536`) are Apache config directives set in
  `extra.conf`, not fixed protocol constants. It is a **test pattern**
  (construct a request that is N bytes over an arbitrary configured limit)
  rather than a fixed corpus of byte sequences, so it needs more adaptation
  work than the raw-socket files.
- `contentlength.t`: raw-socket, 6 `Content-Length` value variants (empty,
  "0", zero-padded, overflow digit string, "-1", "123abc") × 2 URIs = 12
  cases; confirmed genuine malformed-Content-Length coverage.
- `mergeslashes.t`, `hostcheck.t`, `server_name_port.t`: confirmed raw
  request-line/Host-header tables in the same `[ bytes => code, code, cond
  ]` shape as `http_strict.t`.

**No refutation found.** This is exactly what it claims to be: a compact,
Apache-2.0-licensed, raw-byte, server-side conformance table directly
relevant to request-line/header/chunk/Host/Content-Length strictness
decisions our connection layer must make.

**Extraction effort estimate: ~6–10 hours.** The `[bytes => class...]` table
shape (present in `http_strict.t`, `hostcheck.t`, `mergeslashes.t`,
`server_name_port.t`) can share one extractor (~2h to write + a class
matcher: 0=any 4xx/5xx, 1=any 2xx/3xx, exact code, 90=HTTP/0.9, undef=drop).
The raw-socket files with inline `@test_strings`/`@resp_strings` arrays
(`chunkinput.t`, `contentlength.t`, `teclchunk.t`) are a second, similarly
mechanical pass (~2-3h). `headers.t` needs a stub CGI-echo handler (~1h).
`limits.t` needs manual translation from LWP-request-building code into
literal byte payloads sized against whatever limits we choose to test
(~2-3h, since the values aren't handed to you as bytes).

---

## 2. `lighttpd-request-t` (lighttpd1.4 tests/request.t)

**Verdict: CONFIRMED, tier 1 upheld. Not refuted.**

Fetched at commit `2ddc51389a139d2b08daf310596c951c1d53dc8d`:
- https://raw.githubusercontent.com/lighttpd/lighttpd1.4/2ddc51389a139d2b08daf310596c951c1d53dc8d/tests/request.t (**1784 lines**, exact match to claim)
- .../tests/core-condition.t (140 lines)
- .../tests/LightyTest.pm (**568 lines**, exact match to claim)
- COPYING: https://raw.githubusercontent.com/lighttpd/lighttpd1.4/2ddc51389a139d2b08daf310596c951c1d53dc8d/COPYING — confirmed genuine 3-clause BSD (attribution + disclaimer + non-endorsement clauses), matching the claimed "BSD-3-Clause".

Checks performed:
- `grep -c 'handle_http(' request.t` → **168**; `core-condition.t` → **11**.
  `Test::More tests => 172` (line 11) — both numbers match the finder's
  claim exactly (168 blocks, plan 172; the +4 comes from the two `ok()`
  calls at the top plus the plan padding logic, not investigated further
  since the count itself is confirmed).
- Section boundaries confirmed by `grep -n '^##'`: `## Basic
  Request-Handling` at line 19, next section (`## ranges`) at line 429 —
  matches the claimed "19-428" range exactly. `## Low-Level Response-Header
  Parsing - HTTP/1.1` at 703, `## simple-vhost` at 766 — matches "703-765"
  (loosely; the finder's range spans three consecutive `## Low-Level
  Response-Header Parsing - *` subsections at 703/715/735, all ending by
  765). `## keep-alive` at 785, `## 404 handlers` at 880 — matches "785-878"
  almost exactly (real end is 878, one line short of 880 for the next
  header, consistent with the claim).
  - Counted `handle_http(` occurrences inside those three ranges: 34 (basic
    request handling), 7 (header parsing), 7 (keep-alive) = 48 directly
    counted as "generic". The finder's "~60 generic" is in the right
    ballpark once the (also largely generic) 429-702 `## ranges` section is
    included, which the finder didn't cite by line range but did fold into
    "the rest lighttpd-module specific" more loosely than ideal — a minor
    imprecision, not a substantive error.
- Verified the exact pipelining claim: three consecutive blocks at lines
  ~817-878 send two `GET` requests back to back with 1, 2, and 3 blank
  lines between them respectively, expecting `[200,200]` for 1-2 blank
  lines and `[200,400]` (HTTP/1.0 400 on the desynced second message) for
  the excess-blank-line case — this is **exactly** the "extra/excess blank
  lines between requests (200/200 vs 200/400)" claim, byte for byte.
- Verified `SLOWREQUEST` (`$t->{SLOWREQUEST}=1` at request.t:645,
  `LightyTest.pm:306-341`): when set, `handle_http` sends the final
  `\r\n\r\n` as four separate `print $remote ...` calls (`"\015"`, `"\012"`,
  `"\015"`, `"\012"`) instead of one, with `autoflush(1)` set on the socket
  — this is genuinely four separate TCP writes of the terminating CRLFCRLF,
  confirming the claim precisely. (Only one such test exists in the file,
  consistent with what the finder implied.)

**No refutation found.** Confirmed as described in essentially every
verifiable detail, including exact line/byte counts. This is strong,
directly relevant, cleanly licensed (BSD-3, same family as our own project)
server-side material.

**Extraction effort estimate: ~10–14 hours.** The heredoc→`(bytes,
[(proto,status,headers,body)...])` transform itself is mechanical (~3-4h
for a Perl/Python script that strips the `<<EOF...EOF` blocks, applies
`s/\n/\r\n/`, and reads the following `$t->{RESPONSE}` hashref/arrayref
literal). The larger cost is manual curation: hand-selecting the ~50-60
generic (non-module-specific) blocks out of 168+11, since many blocks
reference lighttpd-specific vhosts, `mod_access`/`mod_auth`/`mod_cgi`/
`mod_deflate`/`mod_expire`/`mod_extforward`/`mod_proxy`/`mod_setenv`
configuration that has no chez-http-server analogue (~5-6h of judgment
calls). Replicating `LightyTest::handle_http`'s exact wire semantics
(CRLF normalization, half-close via `shutdown($remote,1)`, lower-cased
comma-joined duplicate headers) in the Scheme test harness is another
~2h.

---

## 3. `haproxy-reg-tests-http-messaging` (.vtc, HAProxy reg-tests)

**Verdict: Mostly CONFIRMED, tier 2 upheld. Not refuted, but one
specifically-cited file (`truncated.vtc`) is materially overstated.**

Fetched at commit `bff44ff3d23e0de34e42fb6dc77d0c205041e871`:
- Directory listing via GitHub API confirms **23** `.vtc` files under
  `reg-tests/http-messaging/`, exactly matching the finder's "23 files"
  claim.
- LICENSE: https://raw.githubusercontent.com/haproxy/haproxy/bff44ff3d23e0de34e42fb6dc77d0c205041e871/LICENSE — confirmed GPL-2 core (with an LGPL carve-out only for exportable headers), matching the claimed "GPL-2.0-or-later" and validating the finder's tier-2 downgrade (re-express rather than vendor verbatim).
- `h1_request_target_validation.vtc`: counted `client cN` blocks → **13**
  (c1-c9, c11-c14; no c10), exactly matching "13 clients" claim. Content
  verified: OPTIONS `*` → 200, OPTIONS with a path after `*` → 400, bare
  `GET *` → 400, CONNECT with a bare host (no port) → 400, CONNECT with a
  URL scheme → 400, GET with authority-form target → 400 — this is
  authentic request-target-form validation exactly as claimed, and the
  backend is a trivial `http-request return status 200` (no real origin
  server), which actually makes this *easier* to adapt than the finder's
  writeup implies (no backend-status-remapping problem here).
- `http_transfer_encoding.vtc`: counted **19** `client` blocks (matches
  claim exactly) and **53** `expect` occurrences (matches claim exactly).
  Verified the specific TE-conformance scenarios cited: `Transfer-Encoding:
  chunked, chunked` → 400, `chunked, gzip, chunked` → 400, `chunked, gzip`
  → 400, bare `gzip` → 400 (lines 229-257) — precise match to "'chunked,
  chunked', 'chunked, gzip, chunked'" in the candidate's `covers` list.
  Minor imprecision: the claimed "40 tx" does not correspond to any exact
  count I could reproduce — `txreq` alone is 21, `txreq`+`txresp` is 31,
  adding raw `send` calls in the fake-backend half gets to 50; none of
  these combinations is exactly 40. This looks like a loose/approximate
  sub-metric in an otherwise accurately characterized file and is not
  grounds for refutation.
- `h1_host_normalization.vtc`: **49** clients, **98** expects — both match
  the claim exactly.
- **`truncated.vtc` (cited under `covers` as "truncated chunked
  responses" and listed explicitly in `corpus_paths`) is a real problem.**
  Reading the full file: its `varnishtest` description is literally `"HTTP
  response size tests: H2->H1 (HTX and legacy mode)"`, and the *only*
  client in the file (`client c1h2`) speaks raw HTTP/2 framing
  (`txpri`/`txsettings`/`stream 1 { txreq -scheme https ... }`) against a
  `bind "fd@${feh2}" proto h2` listener. There is no HTTP/1 client-facing
  request anywhere in this file — the only H1-shaped material is the fake
  origin (`server s1`) emitting a slow, delayed, 24-chunk response body,
  which is buried inside an H2-driven test and has no independent
  "request" side to replay. This is not adaptable as an H1 byte-stream
  test the way the other files in this candidate are; at best it can
  inspire a scenario ("emit a large chunked response across many delayed
  writes and confirm nothing drops data"), which is a much smaller and
  fuzzier contribution than "truncated chunked responses" in the `covers`
  list implies. I did not check whether the other 8 files in the "9 use an
  H2 client" bucket have a similar all-H2, no-H1-client-anywhere structure;
  given this one example, I would treat that whole bucket as needing
  individual verification before relying on any of them, not just
  discounting by "uses an H2 client" as the finder's phrasing suggests.

**Not refuted overall** — `h1_request_target_validation.vtc` and
`http_transfer_encoding.vtc` (both independently and precisely verified)
carry real, high-quality, adaptable server-side material, and the finder's
counts for them are accurate to the count. But `truncated.vtc`
specifically should be dropped or heavily discounted from the extraction
list, and the "9 use an H2 client" files should not be assumed to retain
partial H1 value without a second look.

**Extraction effort estimate: ~15–25 hours.** Because of the GPL license,
each case must be hand-re-expressed (not mechanically transformed) into a
new `.vtc`/byte-stream fixture — call it ~1-1.5h per file for the ~10-14
files worth taking (`h1_request_target_validation`, `http_transfer_
encoding`, `h1_host_normalization`, `h1_to_h1`, `h1_authority_fragment_
char`, `http_bodyless_response`, `http_abortonclose`, `http_wait_for_body`,
a handful of `http-rules/*.vtc`), plus time to verify the vtest toolchain
itself (`HAPROXY_PROGRAM`/`vtest` availability was not checked on this
machine — an unverified risk item) if the (b) "run under vtest" adaptation
path is pursued rather than pure byte-stream fixture extraction.

---

## 4. `varnish-vtc-tests` (varnishtest tests)

**Verdict: CONFIRMED, tier 2 upheld. Not refuted.**

Fetched at commit `0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e`:
- GitHub API directory listing of `bin/varnishtest/tests` → **866** `.vtc`
  files, exactly matching the finder's "866 .vtc total" claim.
- LICENSE: https://raw.githubusercontent.com/varnishcache/varnish-cache/0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e/LICENSE — confirmed genuine BSD-2-Clause (`SPDX-License-Identifier: BSD-2-Clause` present verbatim), validating the finder's "vendor verbatim with LICENSE+PROVENANCE" adaptation path.
- README: https://raw.githubusercontent.com/varnishcache/varnish-cache/0038dd19804fd92cd8bd4bfe92e5a515a57d5e8e/bin/varnishtest/tests/README — naming scheme confirmed (`b`=basic, `c`=complex, `f`=security, `r`=regression-by-ticket, plus several the finder didn't mention: `t`=transport, `i`=interop, `h`=HAProxy, etc. — finder's summary was accurate as far as it went, just abbreviated).
- `b00012.vtc`: confirmed genuine pipelining test — `client c1` sends three
  `GET` requests concatenated in one `send`, expects three responses read
  back in order with the correct `bodylen`s, and a final
  `varnish v1 -expect sess_readahead == 2` assertion. Exactly matches the
  "pipelining and read-ahead" claim; the raw `send "GET /foo
  HTTP/1.1\n...\n\n..."` string is directly reusable as a byte-stream
  fixture (only the varnish-specific `x-varnish` header expectations need
  to be dropped).
- `r01729.vtc`: confirmed genuine CL+TE conflict test — `PUT` with both
  `Content-Length: 31` and `Transfer-Encoding: chunked` → expects `400`
  from the frontend (rejected before reaching any backend); matches the
  "CL + TE:chunked conflict → 400" claim precisely, with a second client
  in the same file sending TE-only and expecting `503` — that second
  expectation is Varnish-backend-selection-specific and would need to be
  translated to whatever our server does when routing succeeds (not a
  universal 400/503 choice), consistent with the finder's caveat that
  "expected statuses must be re-derived."
- `c00039.vtc`: confirmed exact byte-accounting claim. The file literally
  comments `# Each line is 32 bytes. Total: 32 * 8 == 256` and `# Each line
  is 32 except last, which is 33. Total: 32 * 7 + 33 == 257`, sets
  `http_req_size 256`, and expects `200` for the 256-byte-total request and
  `expect_close` (later `414` once `http_req_overflow_status` is
  reconfigured) for the 257-byte one — this is precisely the "exact byte
  accounting and expect_close" claim, and it's some of the cleanest,
  most literal boundary-condition test material found across all six
  candidates today.

**No refutation found.** Every specific claim I checked (total file count,
b00012, r01729, c00039, license) was accurate, several to the exact byte.

**Extraction effort estimate: ~12–18 hours** for the ~35-40 HTTP/1-relevant
files: BSD-2 permits verbatim vendoring of the `client {}` halves (saving
time versus HAProxy), but each file still needs the `varnish v1
-vcl+backend {...} -start` stanza replaced with our own server process
launch, and — as `r01729.vtc` shows — several expected status codes are
Varnish-routing artifacts (e.g. `503` for "no matching backend") that must
be individually re-derived rather than copied, which is the dominant cost
(~20-30 min/file × ~35-40 files ≈ 12-20h, in line with the finder's
implicit tier-2 rating).

---

## 5. `nginx-tests-http1-core` (nginx-tests Perl .t, HTTP/1 core subset)

**Verdict: PARTIALLY CONFIRMED. Not refuted overall, but 3 of the 19 listed
files are miscategorized and should be dropped from the extraction list;
`corrected_paths` supplied.**

Fetched at commit `40616854c6a75ecf73005ba14faa1d01a195620d`:
- GitHub API directory listing → **501** top-level `.t` files, exactly
  matching the finder's "501 .t files total" claim.
- LICENSE: https://raw.githubusercontent.com/nginx/nginx-tests/40616854c6a75ecf73005ba14faa1d01a195620d/LICENSE — confirmed 2-clause BSD, "Copyright (C) 2008-2011 Maxim Dounin", matching the claim exactly ("two-clause BSD (Maxim Dounin 2008-2011)").
- **`headers.t` is miscategorized.** Read in full: this file is titled
  "Tests for headers module" and its entire content tests the nginx
  `add_header`/`expires` *response-generation* directives (Cache-Control
  and Expires header computation from file mtimes, `expires modified`
  through a `proxy_pass` hop, `add_header ... always`, per-location
  inheritance). It has nothing to do with HTTP header *field syntax*,
  parsing correctness, obs-fold, or any connection-semantics topic in the
  SKEPTIC brief's lens. It is also miscounted: `->plan(28)` and
  `grep -c 'like(\|unlike('` both give **28**, not the claimed "headers.t
  22". This file should not be in a "HTTP/1-core" bucket at all.
- **`request_id.t`**: "Tests for request_id variable" — tests nginx's
  per-request UUID logging variable (`$request_id`). Zero connection-
  semantics relevance.
- **`server_tokens.t`**: "Tests for server_tokens directive" — tests
  whether the `Server:` response header / error-page footer discloses the
  nginx version string. Zero connection-semantics relevance; this is a
  response-formatting/disclosure feature specific to nginx, not a protocol
  conformance concern.
- By contrast, several files I checked in the same list were **accurately**
  characterized and are directly relevant:
  - `http_uri.t`: `->plan(19)` — exact match to the claimed "http_uri.t
    19". Confirmed genuine URI-normalization/request-target edge cases:
    bare `%` and `%1` (truncated percent-escape) → 400, `. `/`..` dot-
    segment handling, absolute-form (`http://host[:port][?args]`) request
    targets, raw space and control byte in the path → 400. Squarely
    relevant to our uriparse integration.
  - `http_header_buffers.t`: `->plan(10)` — exact match to "http_header_
    buffers.t 10". Confirmed genuine `large_client_header_buffers`
    boundary tests including pipelined-then-overflow and keepalive-then-
    overflow scenarios (buffer reuse across pipelined/kept-alive
    requests) — directly relevant connection-semantics material, with
    literal raw request bytes built via `CRLF`-joined strings in the
    `http(...)` helper.
  - `http_max_headers.t`: confirmed `max_headers 5` → 200 at exactly 5
    headers, 400 at 6 — clean, minimal, directly portable.
  - `ignore_invalid_headers.t`: confirmed "colon first"/"space"/"control"
    byte in header name → 400 Bad, plus `underscores_in_headers` on/off
    behavior — genuine header-syntax-strictness material.
  - `trailers.t`: confirmed to test the `add_trailer` directive (response-
    side chunked trailers), which is response-*generation* correctness
    (useful for validating our own chunked-response writer) rather than
    request-side parsing robustness — a real topic, but narrower than
    implied by being lumped in with the header/URI/buffer files above.

No separable data file exists in any of these — the finder is right that
request bytes and expectations are inline Perl tied to an embedded
`nginx.conf`, so every file (relevant or not) needs manual transcription
regardless.

**`corrected_paths`** (dropping the 3 miscategorized files):
`body.t`, `body_chunked.t`, `client_body_early_read.t`,
`http_expect_100_continue.t`, `http_header_buffers.t`,
`http_headers_multi.t`, `http_host.t`, `http_keepalive.t`,
`http_keepalive_shutdown.t`, `http_max_headers.t`, `http_method.t`,
`http_request_port.t`, `http_uri.t`, `ignore_invalid_headers.t`,
`merge_slashes.t`, `trailers.t`, `lib/Test/Nginx.pm`.

**Extraction effort estimate: ~10–14 hours** for the corrected 16-file set:
~30-45 min/file to transcribe inline request-byte strings and the
associated regex expectations, plus the one-time ~2-3h cost of building the
Scheme-side loopback-request helper modeled on `lib/Test/Nginx.pm`'s
`http()`/`http_get()` (also confirmed present in the fetched
`lib/Test/Nginx.pm`, 22517 bytes). Add ~2h of due-diligence time per
additional file pulled from the other ~480 nginx-tests files not already
vetted here, given the false-positive rate observed (3/19 ≈ 16% in this
sample).

---

## 6. `h2o-protocol-tests` (h2o t/40*.t)

**Verdict: PARTIALLY CONFIRMED. Not refuted overall, but `40protocol.t` is
miscategorized and inflates the claimed case count; correction supplied.**

Fetched at commit `cac7e6568ad98a848f099ecd0a18b881f632479a`:
- GitHub API directory listing of `t/` → **235** numbered `.t` files,
  exactly matching the finder's "235 numbered .t total" claim.
- LICENSE: https://raw.githubusercontent.com/h2o/h2o/cac7e6568ad98a848f099ecd0a18b881f632479a/LICENSE — confirmed genuine MIT text, matching the claim.
- `40bad-request.t`: 6 assertions counted (silent close on empty request;
  `400` with `Content-Length: 11`/"Bad Request" body on a broken
  request-line; silent close on a lone CRLF; `400` on missing method;
  `400` on missing path; `400` with an exact "line folding of header
  fields is not supported" body on obs-fold) — exact match to "40bad-
  request 6" and to the `covers` description. Genuinely excellent, precise
  server-side material; only the exact response bodies are h2o-specific,
  the request bytes and pass/fail behavior are universal.
- `40http1-pipeline.t`: 3 `subtest` blocks counted, exact match to
  "40http1-pipeline 3". Confirmed to be precisely "pipelined GET+GET,
  POST(Content-Length)+GET, POST(chunked)+GET with in-order statuses" as
  claimed — each subtest concatenates two full requests in one
  `syswrite()` and regex-matches both status lines appearing in order in
  one continuous read.
- **`40protocol.t` is miscategorized.** `grep -c 'subtest\s'` gives exactly
  **9**, matching the finder's raw count ("40protocol 9"), but reading the
  full file shows it is **not** a protocol-edge-case test at all: it spawns
  h2o serving two static fixture files and then, across HTTP/1, HTTP/2, TLS
  and multiple `io_uring`/`file.io_uring` configurations, shells out to
  `curl`, `nghttp`, and `ab` to fetch them and compares output length/MD5
  against the on-disk files, plus an `ab -c 10 -n 10000` load-test
  smoke-check. There is no raw request-byte manipulation anywhere in this
  file, no malformed input, no keep-alive/pipelining/framing/limit/timeout
  scenario — it is a static-file-serving-correctness-under-io_uring smoke
  test using three different external HTTP clients. It has effectively
  zero adaptability value for this project's corpus (nothing here would
  become a byte-stream fixture) and its 9 subtests should not be counted
  toward the claimed "~30 assertions" total for this candidate — doing so
  overstates the real yield by roughly a third.
- `40chunked.t`: 2 `subtest` blocks confirmed (exact match). Content is
  chunked-*response* generation correctness (push-mode proxying and
  pull-mode `server-timing` trailer injection), not malformed-chunked-
  *request* parsing — useful for validating our own chunked writer, a
  narrower claim than "chunked encoding" standing alongside the
  smuggling/parsing topics in the candidate's `covers` list might suggest.
- `40http1-timeouts.t`, `40expect.t`, `40http1-streaming-framing.t`: all
  read in full and confirmed to be genuinely on-topic (request/response
  idle-timeout-then-close behavior; `Expect: 100-continue` interim
  response; proxy's choice of outbound Content-Length vs chunked framing
  based on what the inbound client sent) — legitimate, if requiring
  external tooling (`curl`, `plackup`/Starlet, `h2o-httpclient`) rather
  than pure raw-byte scripting, to reproduce.

**Not refuted overall** — `40bad-request.t` and `40http1-pipeline.t` in
particular are exactly as good as claimed. But `40protocol.t` should be
dropped from the corpus entirely (it is file-serving/io_uring material,
not HTTP/1 protocol material) and the candidate's implied yield corrected
from "~30 assertions across ~10 files" down to **~21 assertions across 9
files** once it's excluded.

**Extraction effort estimate: ~6–9 hours** for the corrected 9-file,
~21-assertion set (excluding `40protocol.t`): most scenarios are already
expressed as a single `nc`/raw-socket payload or a two-request
`syswrite()`/`sysread()` pair, so transcription is fast (~30 min/file);
the timeout/expect/streaming-framing files need slightly more care to
reproduce their timing/external-tool dependencies as scripted delayed
writes instead (~1h each).

---

## Cross-candidate observations

- File and line **counts** given by the finder were extremely accurate
  across all six candidates when I could check them exactly against a
  freshly fetched file (88, 18, 9, 1784, 568, 168/172, 23, 866, 501, 235,
  6, 3, 9(subtests), 19, 10 — all confirmed exact matches). The finder's
  count-gathering methodology (presumably `rg -c` or similar against the
  actual fetched files) is trustworthy.
- Where the finder's writeups went wrong, it was consistently at the
  **content-relevance** layer, not the counting layer: three specific
  files (`headers.t` and `request_id.t`/`server_tokens.t` in nginx-tests;
  `40protocol.t` in h2o; `truncated.vtc` in haproxy) sound on-topic from
  their filenames and were bundled into a candidate's file list and case
  totals, but turn out on inspection to test an unrelated feature
  (response-header-generation directives, per-request logging UUIDs,
  version disclosure, and file-serving/io_uring smoke-testing
  respectively) or to have no HTTP/1-client-facing content at all
  (`truncated.vtc` is H2-client-only). This is a real, repeatable failure
  mode worth flagging to whoever does the actual extraction: **grep a
  filename match is not sufcient — every file must be read in full before
  it's trusted as corpus material**, exactly as this skeptic pass did.
- No candidate in this batch was refuted outright — all six contain
  genuine, verifiable, relevant server-side HTTP/1.x material, and none is
  purely parser-only/client-only/HTTP-2-only in aggregate. The corrections
  above are file-level trims, not whole-candidate rejections.
