# Skeptic verification — corpus candidates batch0 (relevance & adaptability)

Role: SKEPTIC. Lens: is this genuinely HTTP/1.x SERVER-SIDE / connection-semantics
material (keep-alive, pipelining, framing precedence, close, upgrade, limits,
timeouts, smuggling) and adaptable into replayable byte streams / scripted
sessions — or is it parser-only (redundant with the already-vendored llhttp
corpus), client-only, or HTTP/2-only? All commands below were run on
2026-09-19 from this session's Bash tool. `gh` is authenticated as `DarrenN`
(`gh auth status` → `✓ Logged in to github.com account DarrenN`).

Verdict summary is at the bottom. None of the six candidates were refuted
outright; all core factual claims in the finder's report checked out against
primary sources, several to the exact byte/line/count. Two corrections are
proposed: `http-fuzz-dictionaries` down-tiered to 3 (pure dictionary/token
material, zero test cases, zero oracle, orthogonal to connection semantics —
does not deserve the same tier as scenario/data corpora), and two minor
factual notes (not tier-affecting) are flagged for the synthesis agent.

---

## 1. `llhttp-fixtures`

**Claim under test**: already fully vendored and exercised by chez-httparse;
253 HTTP fixtures (163 req / 90 resp) + 21 URL = 274; pipelining covered by
exactly 1 request + 1 response fixture; PROVENANCE/ADR-0007 mechanism exists.

Verified directly against the local checkouts (no network needed):

```
$ cd /Users/yuzu/github/llhttp && git log -1 --format="%H %ai"
ee51043701d8b90ef647cf04790cbb1c55889825 2026-07-30 17:04:44 +0300
```
Matches the commit cited by the candidate (`ee51043701d8b90ef647cf04790cbb1c55889825`, ref `v9.4.3-1-gee51043`).

```
$ rg -c '^```http' test/request/*.md | awk -F: '{sum+=$2} END{print sum}'
167
$ rg -c '^```http' test/response/*.md | awk -F: '{sum+=$2} END{print sum}'
86
$ rg -c '^```url' test/url.md
21
```
Total = 167+86+21 = 274, matching chez-httparse's own claim (see below). The
finder's split (163 req / 90 resp) differs slightly from my rg count
(167 req / 86 resp) — same total (253 HTTP fixtures), likely a counting-method
difference (some files have multiple `<!-- meta -->`-delimited fixtures per
`​```http` block vs one rg match per block start). Not material to the verdict.

Pipelining fixture count, confirmed exactly one each side:
```
$ cat test/request/pipelining.md | head -20     # single "Should parse multiple events" case, 3 pipelined POST/PUT/PATCH, framed by Content-Length
$ cat test/response/pipelining.md | head -20    # mirrors it on the response side
```
Both fixtures are pure parser event traces (`message begin` / `span[...]` /
`headers complete` / `message complete` / `reset`) with **no notion of
connection close, no multi-packet delivery, no timeout** — confirms the
candidate's own caveat that "the oracle is a parser event trace, not server
behaviour."

chez-httparse's own conformance doc corroborates the "already fully
integrated, passes all 274" claim:
```
$ rg -n '274|253|chunk size' /Users/yuzu/github/chez-httparse/docs/conformance.org
6:274 *fixtures in its conformance corpus — every HTTP fixture and every URL
7:fixture it ships, at every chunk size.*
40:and never edited. Every in-scope fixture is replayed *at every chunk size
55:Every fixture the corpus ships is gated and passing: *274 of 274*. The
```

PROVENANCE / ADR-0007 mechanism, confirmed to exist verbatim as described:
```
$ head -20 /Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE
upstream-url: https://github.com/nodejs/llhttp
upstream-ref: v9.4.3-1-gee51043
upstream-commit: ee51043701d8b90ef647cf04790cbb1c55889825
retrieved: 2026-09-13
file-count: 24
sha256 628168d68bb5a8a17e0bbefb3bd74e326e1edc20583d76f52f457c82c921867d LICENSE
...
$ find /Users/yuzu/github/chez-httparse/.plans/decisions -iname "*0007*"
/Users/yuzu/github/chez-httparse/.plans/decisions/0007-llhttp-corpus-vendored-as-data.md
```

**Verdict**: NOT REFUTED. This is the reference baseline the project already
owns and runs; the candidate's own recommendation ("do not re-vendor… reach
through chez-httparse") is correct and is exactly what should happen — there
is nothing to extract, only a pointer/README note in chez-http-server if
desired. Extraction effort: ~0 hours (already integrated); at most ~1 hour to
add a doc pointer. Tier 1 is appropriate as "the baseline that's already
there," not as a new acquisition target.

---

## 2. `libhtp-t-corpus`

**Claim under test**: OISF/libhtp, archived, BSD-3-Clause, 102 `.t` files in
`test/files`, 112 `TEST_F` oracle cases in `test/test_main.cpp`, specific flag
counts (`HTP_REQUEST_SMUGGLING` x5, `HTP_REQUEST_COMPLETE` x40), `>>>`/`<<<`
packet-boundary format, genuine connection-semantics coverage (pipelining,
multi-packet heads, CONNECT, timeouts, requests cut mid-token).

```
$ gh api repos/OISF/libhtp --jq '{archived, default_branch, license: .license.spdx_id, pushed_at}'
{"archived":true,"default_branch":"0.5.x","license":"BSD-3-Clause","pushed_at":"2026-08-14T15:15:59Z"}
```
Matches exactly.

```
$ gh api "repos/OISF/libhtp/contents/test/files?ref=0.5.x" --jq '.[].name' | grep -c '\.t$'
102
```
Matches exactly.

Fetched and read several of the named files directly
(`repos/OISF/libhtp/contents/test/files/<name>?ref=0.5.x`, base64-decoded):

- `07-pipelined-connection.t`: `>>>` block with two back-to-back `GET`
  requests, single `<<<` block with two concatenated `HTTP/1.0 200 OK`
  responses — genuine pipelining shape.
- `09-multi-packet-request-head.t`: three separate `>>>` blocks splitting
  `GET / HTTP/1.0`, then `Host: www.example.com`, then the terminating blank
  line — genuine multi-packet head delivery.
- `35-early-response.t`: client sends a `POST` with `Content-Length: 12` but
  no body bytes follow before the `<<<` 400 response — early-response-before-
  body-done shape.
- `85-zero-byte-request-timeout.t`: **no `>>>` block at all**, only a `<<<`
  408 response — confirms "zero-byte request then timeout," though the
  recorded response is the *origin server's* (Akamai) actual reply, not
  something our server would emit; this is exactly the caveat the candidate
  raises ("write our own per-file expectations… guided by test_main.cpp").
- `97-requests-cut.t`: request line literally split mid-token (`...Mozilla\n\nG` /
  `ET /?p=%21 HTTP/1.1...`) across two `>>>` blocks — genuine "requests cut"
  mid-byte coverage.
- `99-expect-100.t`, `61-empty-line-between-requests.t`: confirmed present
  and match their described shapes (100-continue then rejected, then a
  second request; blank line between two pipelined requests).

Oracle file:
```
$ gh api "repos/OISF/libhtp/contents/test/test_main.cpp?ref=0.5.x" --jq '.content' | base64 -d > libhtp-test_main.cpp
$ wc -l libhtp-test_main.cpp
2148 libhtp-test_main.cpp
$ rg -c 'TEST_F' libhtp-test_main.cpp
112
$ rg -i 'smuggl' libhtp-test_main.cpp
    ASSERT_TRUE(tx->flags & HTP_REQUEST_SMUGGLING);   (x4)
    ASSERT_FALSE(tx->flags & HTP_REQUEST_SMUGGLING);  (x1)
$ rg -c 'HTP_REQUEST_COMPLETE|REQUEST_COMPLETE' libhtp-test_main.cpp
40
$ rg -i 'pipelin' libhtp-test_main.cpp
TEST_F(ConnectionParsing, PipelinedConn) { ... test_run(home, "07-pipelined-connection.t", ...); ASSERT_TRUE(... & HTP_CONN_PIPELINED); }
TEST_F(ConnectionParsing, NotPipelinedConn) { ... "08-not-pipelined-connection.t" ...; ASSERT_FALSE(...); }
```
Every specific count in the candidate (112 TEST_F, 5 smuggling refs, 40
REQUEST_COMPLETE refs) matches exactly.

EOL/license context, also confirmed:
```
$ gh api "repos/OISF/libhtp/contents/README.md?ref=0.5.x" --jq '.content' | base64 -d | head -10
**LibHTP End-of-Life Announcement (July 7, 2026)**
Following the End of Life of Suricata 7, the libhtp project will no longer be
maintained... Suricata 8 and beyond use a fork ... rewritten to Rust ...
https://github.com/OISF/suricata/tree/main/rust/htp
```
I additionally checked whether the `.t` corpus followed the Rust rewrite (the
candidate flagged this as unverified): `rust/htp/src/test/files` exists as a
directory in `OISF/suricata` (`gh api repos/OISF/suricata/contents/rust/htp/src/test?ref=main`
lists `files` alongside `common.rs`, `gunzip.rs`, `hybrid.rs`, `main.rs`,
`mod.rs`), suggesting the corpus likely did carry over, though I did not diff
contents — this is a secondary confirmation, not load-bearing for the verdict
since the archived 0.5.x tag is stable and license-clear either way.

**Verdict**: NOT REFUTED, strongest candidate of the six by this lens. Real
server-connection-semantics byte streams (pipelining, multi-packet heads,
smuggling-shaped invalid CL/TE combos, CONNECT tunnels, timeouts, cut
requests) with a precise, mechanically-parseable `>>>`/`<<<` format and a
genuine (if C++-only) reference oracle to guide expected behavior. Tier 1
confirmed. Estimated extraction effort: **~6–10 hours** — a ~40-line Scheme
loader for the `>>>`/`<<<` format (trivial), vendoring ~40–60 of the 102
files after filtering out the auth-*, compressed-response-*, multipart, and
php-param files the candidate already flagged as out of scope, and writing
our own per-file expected-behavior table by reading the corresponding
`test_main.cpp` assertions (which do not translate 1:1 since libhtp's oracle
is IDS-flag-based, not response-based).

---

## 3. `h2o-fuzz-http1-corpus`

**Claim under test**: h2o/h2o, not archived, MIT; `fuzz/http1-corpus/` has
1972 files totaling 2,525,951 bytes, SHA1-named; `\n--MARK--\n` packet
delimiter at `driver.cc` line 153; genuine server-side harness (writes to a
real socket h2o listens on); OSS-Fuzz ships only `.options` files, no corpus.

```
$ gh api repos/h2o/h2o --jq '{archived, license: .license.spdx_id, pushed_at}'
{"archived":false,"license":"MIT","pushed_at":"2026-09-10T04:21:41Z"}
```
Matches exactly.

```
$ gh api "repos/h2o/h2o/contents/fuzz/driver.cc?ref=master" --jq '.content' | base64 -d > h2o-driver.cc
$ rg -n 'MARK' h2o-driver.cc
153:#define MARKER "\n--MARK--\n"
156:                char *p = (char *)memmem(buf + pos, len - pos, MARKER, sizeof(MARKER) - 1);
161:                    pos += sizeof(MARKER) - 1;
```
Line 153 matches exactly. Read the surrounding `writer_thread` function
(lines ~100–180): it genuinely opens a real socket, writes fuzzed bytes up to
each `--MARK--` boundary, drains the response, and repeats — i.e. it drives
h2o *as an HTTP/1 server*, not a client. This is real server-side material,
not client-only.

Corpus size, verified via the git trees API (the exact tree SHA the finder
cited):
```
$ gh api repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784 --jq '.truncated'
false
$ gh api repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784 --jq '.tree | length'
1972
$ gh api repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784 --jq '[.tree[].size] | add'
2525951
```
Both numbers match the candidate's claim exactly (1972 files, 2,525,951
bytes; mean = 2525951/1972 ≈ 1281 bytes, matching "mean 1281 bytes").

Spot-checked 3 sample blobs for the `--MARK--` delimiter (note: my first pass
using a `for` loop with `2>&1` produced corrupted/empty decodes — a tooling
artifact, not a finding; redone per-file it resolves cleanly):
```
$ gh api repos/h2o/h2o/git/blobs/0b9430e9cb0e56f1778ab6226c059b69f3e48ced --jq '.content' | base64 -d > /tmp/blob1.bin
$ grep -c -a -- '--MARK--' /tmp/blob1.bin
7
$ gh api repos/h2o/h2o/git/blobs/be5534beea37e7fbd6715f2e7bae906c6ca6c4f1 --jq '.content' | base64 -d > /tmp/blob3.bin
$ grep -c -a -- '--MARK--' /tmp/blob3.bin
1
```
Confirms "all sampled files contain --MARK--."

OSS-Fuzz claim:
```
$ gh api repos/google/oss-fuzz/contents/projects/h2o --jq '.[].name'
Dockerfile
build.sh
h2o-fuzzer-http1.options
h2o-fuzzer-http2.options
h2o-fuzzer-http3.options
h2o-fuzzer-url.options
project.yaml
```
Confirmed: only `.options` files, no in-project seed corpus, matching the
candidate's claim that the corpus lives only in-tree at h2o/h2o.

**Verdict**: NOT REFUTED. Genuinely server-side, packetized, real HTTP/1
robustness material, but — as the candidate itself notes — there is no
behavioral oracle (crash/hang-only), so it only becomes useful once a driver
exists to define our own invariants (no unguarded raise, response
well-formedness, bounded progress). Tier 2 is correctly calibrated: real
value but not immediately actionable, and 2.5MB is heavier than the project's
existing 288K llhttp vendoring precedent, so a `make`-target fetch-on-demand
(as recommended) rather than a wholesale vendor is right. Estimated
extraction effort: **~10–15 hours** once the driver exists (MARK-splitting
loader is trivial, ~1h; the real cost is selecting a representative,
size-bounded subset and defining pass/fail invariants since there is no
oracle) — largely deferred/blocked work, not a near-term win.

---

## 4. `nodejs-http-parser-test-c`

**Claim under test**: joyent/nodejs http-parser, archived, MIT; `test.c` is
4729 lines; `requests[]` at line 95 (47 messages), `responses[]` at line 1331
(30 messages), `url_tests[]` (48 tests), `test_scan` at line 4105, 19
`test_simple()` calls; connection-oracle fields
(`should_keep_alive`, `message_complete_on_eof`, `upgrade`) are the real
value-add over llhttp given byte-content overlap.

```
$ gh api repos/nodejs/http-parser --jq '{archived, license: .license.spdx_id, pushed_at, default_branch}'
{"archived":true,"license":"MIT","pushed_at":"2022-06-19T08:11:39Z","default_branch":"main"}
$ gh api "repos/nodejs/http-parser/contents/test.c?ref=main" --jq '.content' | base64 -d > nodejs-http-parser-test.c
$ wc -l nodejs-http-parser-test.c
4729 nodejs-http-parser-test.c
```
Matches exactly.

```
$ rg -n 'struct message requests' nodejs-http-parser-test.c
95:const struct message requests[] =
$ rg -n 'struct message responses' nodejs-http-parser-test.c
1331:const struct message responses[] =
$ rg -n 'test_scan' nodejs-http-parser-test.c
4105:test_scan (const struct message *r1, const struct message *r2, const struct message *r3)
$ sed -n '95,1330p' nodejs-http-parser-test.c | rg -c '\.name\s*='
47
$ sed -n '1331,2974p' nodejs-http-parser-test.c | rg -c '\.name\s*='
30
$ rg -n 'struct url_test url_tests' nodejs-http-parser-test.c
2975:const struct url_test url_tests[] =
$ sed -n '2975,3526p' nodejs-http-parser-test.c | rg -c '\.name\s*='
48
```
All three line numbers and all three message/test counts (47, 30, 48) match
the candidate's claim exactly.

One discrepancy found: `test_simple()` call count.
```
$ rg -c 'test_simple\(' nodejs-http-parser-test.c
18
```
The candidate claimed 19; actual count of call sites is 18 (verified by
listing every matching line — 18 distinct call sites at lines 4517, 4518,
4519, 4520, 4521, 4522, 4524, 4525, 4528, 4533, 4541, 4585, 4605, 4609, 4650,
4658, 4666, 4678). Minor off-by-one in the finder's report; not material to
the relevance/adaptability verdict.

Sample struct confirmed to have exactly the shape claimed (readable, regular
C struct literal, easy to transcribe):
```c
{.name= "curl get"
,.type= HTTP_REQUEST
,.raw= "GET /test HTTP/1.1\r\n..."
,.should_keep_alive= TRUE
,.message_complete_on_eof= FALSE
,.http_major= 1
,.http_minor= 1
...
```
(`sed -n '95,160p' nodejs-http-parser-test.c`)

**Verdict**: NOT REFUTED (one minor count correction noted above, not
tier-affecting). The candidate is honest that raw byte content is largely
redundant with llhttp (which is true — llhttp's own `sample.md` /
`connection.md` / `transfer-encoding.md` fixtures descend from this same
corpus), and correctly identifies the actual value as the **connection
decision-table columns** (`should_keep_alive`, `message_complete_on_eof`,
`upgrade`) that llhttp's event-trace format does not carry. Tier 2 is
appropriate. Estimated extraction effort: **~4–6 hours** for a one-off
transcription script pulling the 77 (47+30) message structs' framing-relevant
fields into an s-expression/JSON table, plus manual cross-checking against
llhttp fixtures to dedupe raw-byte overlap.

---

## 5. `h11-connection-tests`

**Claim under test**: python-hyper/h11, not archived, MIT;
`test_connection.py` 1120 lines / 28 tests, `test_io.py` 583 lines / 17
tests; specific named tests exist for pipelining, protocol switch, 408 idle
timeout, max-incomplete-event-size (slowloris) countermeasure, 100-continue;
4 tiny AFL seed files; `afl-server.py` invariant is "accept or raise
RemoteProtocolError, nothing else."

```
$ gh api repos/python-hyper/h11 --jq '{archived, license: .license.spdx_id, pushed_at, default_branch}'
{"archived":false,"license":"MIT","pushed_at":"2025-04-24T23:29:20Z","default_branch":"master"}
$ gh api "repos/python-hyper/h11/contents/h11/tests/test_connection.py?ref=master" --jq '.content' | base64 -d > h11-test_connection.py
$ wc -l h11-test_connection.py
1120 h11-test_connection.py
$ rg -c '^def test_' h11-test_connection.py
28
$ gh api "repos/python-hyper/h11/contents/h11/tests/test_io.py?ref=master" --jq '.content' | base64 -d > h11-test_io.py
$ wc -l h11-test_io.py
583 h11-test_io.py
$ rg -c '^def test_' h11-test_io.py
17
```
Every number matches exactly.

Specific named tests, all confirmed present:
```
$ rg -n 'def test_.*keep_alive|def test_.*pipelin' h11-test_connection.py
30:def test__keep_alive() -> None:
522:def test_pipelining() -> None:
826:def test_pipelined_close() -> None:
$ rg -n 'def test_.*(connect|upgrade|switch)' -i h11-test_connection.py
594:def test_protocol_switch() -> None:
...
$ rg -n '408|idle.*timeout' -i h11-test_connection.py
974:def test_idle_receive_nothing() -> None:
990:def test_408_request_timeout() -> None:
994:    p.send(SERVER, Response(status_code=408, headers=[(b"connection", b"close")]))
$ rg -n 'max.*incomplete' -i h11-test_connection.py
413:def test_max_incomplete_event_size_countermeasure() -> None:
$ rg -n 'def test_.*100' -i h11-test_connection.py
368:def test_100_continue() -> None:
```
All confirmed.

AFL seeds:
```
$ gh api "repos/python-hyper/h11/contents/fuzz/afl-server-examples?ref=master" --jq '.[].name, .[].size'
1
2
3
4
44
90
71
22
```
Confirms 4 files, sizes 44/90/71/22 bytes — genuinely tiny 2–3 line requests,
matching the candidate's dismissal of them as adding nothing.

`afl-server.py` invariant, read directly:
```python
try:
    server1.receive_data(data); process_all(server1)
    server1.receive_data(b""); process_all(server1)
except h11.RemoteProtocolError:
    pass
```
Confirms "any input is either accepted or raises RemoteProtocolError, never
anything else" exactly as claimed.

**Verdict**: NOT REFUTED. Of the six candidates this is arguably the most
directly analogous to what chez-http-server's connection driver needs to
implement, since h11 is itself a sans-I/O HTTP/1.1 connection state machine
(the same architectural shape a Scheme "functional core" connection layer
over chez-httparse would take) — its keep-alive-by-version table, body-
framing decision (CL vs TE vs EOF vs HEAD/204/304), protocol-switch handling,
and idle/slowloris timeouts are exactly the connection-semantics gaps that
parser-only fixtures (llhttp) cannot express. I considered correcting the
tier upward to 1 given this direct applicability, but left it at the
finder's **tier 2**: unlike the tier-1 candidates, nothing here is literal
corpus data to vendor — every test requires manual re-derivation into Scheme
(reading Python logic and re-expressing the byte strings + expected
decisions), which is qualitatively the same "transcribe, don't vendor" effort
class as candidate 4, so tier 2 is the consistent call. Estimated extraction
effort: **~12–20 hours** to port the ~45 connection/io-level tests
(deliberately the widest range of the six, since each test requires reading
and understanding h11 source, not just copying bytes) — but arguably the
highest design-value hours in the set.

---

## 6. `http-fuzz-dictionaries`

**Claim under test**: multiple dictionary files from google/fuzzing (Apache-
2.0), oss-fuzz nginx (152 lines, same as google/fuzzing), oss-fuzz haproxy
(93 lines + 15 printf seeds with a 0/1 req/resp first-byte convention), h2o
(2712 lines, MIT), civetweb (55 lines + 2 seeds), AFL++ (119 lines, AGPL-3.0,
strict subset — do not vendor); nginx's actual fuzzer is libprotobuf-mutator
driven with no seed corpus.

```
$ gh api "repos/google/fuzzing/contents/dictionaries/http.dict?ref=master" --jq '.content' | base64 -d > google-http.dict
$ wc -l google-http.dict
152 google-http.dict
$ gh api repos/google/fuzzing --jq '{archived, license: .license.spdx_id}'
{"archived":true,"license":"Apache-2.0"}
```
Line count and license match. **One thing the candidate did not flag**:
`google/fuzzing` is itself an **archived** repository (not mentioned in the
candidate's notes, unlike the libhtp/nodejs-http-parser candidates which did
flag their archived status) — worth noting for the synthesis agent, though
it does not change usability since the content is still fetchable and small.

```
$ gh api "repos/google/oss-fuzz/contents/projects/nginx/fuzz/http_request_fuzzer.dict?ref=master" --jq '.content' | base64 -d > nginx-http_request_fuzzer.dict
$ wc -l nginx-http_request_fuzzer.dict
152 nginx-http_request_fuzzer.dict
$ diff google-http.dict nginx-http_request_fuzzer.dict
107c107
< "P3P	"
---
> "P3P"
```
Confirms "same content" (152 lines, one trivial trailing-tab difference).

```
$ gh api "repos/google/oss-fuzz/contents/projects/haproxy/fuzz_h1_parse.dict?ref=master" --jq '.content' | base64 -d > haproxy-fuzz_h1_parse.dict
$ wc -l haproxy-fuzz_h1_parse.dict
93 haproxy-fuzz_h1_parse.dict
$ gh api "repos/google/oss-fuzz/contents/projects/haproxy/build.sh?ref=master" --jq '.content' | base64 -d | sed -n '40,65p'
```
Counted the `printf ... > "$WORK/h1_seeds/..."` lines directly: exactly 15
(`get_simple`, `post_cl`, `post_chunked`, `get_multi`, `get_http10`,
`websocket`, `connect`, `head`, `options`, `resp_200`, `resp_301`,
`resp_chunked`, `resp_connclose`, `resp_100`, `resp_204`), each prefixed with
`\x00` (request) or `\x01` (response) — confirms both the count (15) and the
"first byte 0=req/1=resp" convention exactly as claimed.

```
$ gh api "repos/civetweb/civetweb/contents/fuzztest/http1.dict?ref=master" --jq '.content' | base64 -d > civetweb-http1.dict
$ wc -l civetweb-http1.dict
55 civetweb-http1.dict
$ gh api "repos/civetweb/civetweb/contents/fuzztest/http1?ref=master" --jq '.[].name'
GET_root.bin
GET_test.bin
```
Matches "55 lines" and "2 seeds" exactly.

```
$ gh api "repos/AFLplusplus/AFLplusplus/contents/dictionaries/http.dict?ref=stable" --jq '.content' | base64 -d > aflpp-http.dict
$ wc -l aflpp-http.dict
119 aflpp-http.dict
$ gh api repos/AFLplusplus/AFLplusplus --jq '.license.spdx_id'
AGPL-3.0
```
Matches exactly (119 lines, AGPL-3.0).

```
$ sort google-http.dict > g.sorted; sort aflpp-http.dict > a.sorted; diff a.sorted g.sorted
4a5,6 ...
5a8 > "ACL"
24a28,31 > "BASELINE-CONTROL" "BIND" "CHECKIN" "CHECKOUT"
25a33 > "COPY"
59a68,70 > "LABEL" "LINK" "LOCK"
62a74,80 > "MERGE" "MKACTIVITY" "MKCALENDAR" "MKCOL" "MKREDIRECTREF" "MKWORKSPACE" "MOVE"
...
```
Confirms the claim precisely: the diff is one-directional (every AFL++ token
is present in google's, plus google has many additions — WebDAV/CalDAV verbs
etc. — with the exact token list the candidate quoted: ACL, BASELINE-CONTROL,
BIND, CHECKIN, ... LOCK, MERGE, MKACTIVITY all appear). AFL++ is confirmed to
add nothing; not vendoring it is correct.

nginx harness format:
```
$ gh api "repos/google/oss-fuzz/contents/projects/nginx/fuzz?ref=master" --jq '.[].name'
http_request_fuzzer.cc
http_request_fuzzer.dict
http_request_proto.proto
wrappers.c
$ gh api "repos/google/oss-fuzz/contents/projects/nginx/fuzz/http_request_proto.proto?ref=master" --jq '.content' | base64 -d
syntax = "proto2";
message HttpProto{
	required string request = 1;
	required string reply = 2;
}
$ gh api "repos/google/oss-fuzz/contents/projects/nginx/build.sh?ref=master" --jq '.content' | base64 -d | grep -i -A2 -B2 'corpus\|seed'
(no output)
```
Confirms both claims: libprotobuf-mutator-driven `request`/`reply` proto, and
no seed corpus anywhere in nginx's oss-fuzz build.

civetweb license, confirmed as described ("multi-licence file"):
```
$ gh api "repos/civetweb/civetweb/contents/LICENSE.md?ref=master" --jq '.content' | base64 -d | head -10
ALL LICENSES
=====
This document includes several copyright licenses for different
aspects of the software. ...
```

**Verdict**: NOT REFUTED as a factual matter — every dictionary/seed claim
checked out precisely — but I am **downgrading tier 2 → 3** on the
relevance/adaptability lens specifically. This candidate contributes **zero
test cases and zero oracle**: it is pure vocabulary (method names, header
tokens, line-ending variants) for a mutation fuzzer that does not exist yet
in this project, and by itself proves nothing about connection semantics —
unlike h2o's corpus (candidate 3), which at least constitutes 1972 concrete,
already-shaped byte streams with an implicit crash-only oracle, a dictionary
is not repayable/replayable on its own at all. Grouping it at the same tier
as h11 (a near-1:1 portable connection-state-machine test suite) or the
nodejs-http-parser struct data (a genuine decision table) overstates its
near-term value. It remains legitimate *supporting* material for a future
fuzz lane once a driver and seed corpus exist, which is why it is not
refuted outright. Estimated extraction effort: **~1–2 hours** (copy 2 small,
clearly-licensed files — google's `http.dict` and haproxy's
`fuzz_h1_parse.dict` — plus a PROVENANCE entry each); this low effort is
itself part of why it doesn't need a high tier — it's cheap to defer.

---

## Verdict table

| key | refuted | corrected_tier | extraction effort (hours) |
|---|---|---|---|
| llhttp-fixtures | false | 1 (unchanged; already integrated, 0h) | ~0 |
| libhtp-t-corpus | false | 1 (unchanged) | ~6–10 |
| h2o-fuzz-http1-corpus | false | 2 (unchanged) | ~10–15 (deferred until driver exists) |
| nodejs-http-parser-test-c | false | 2 (unchanged) | ~4–6 |
| h11-connection-tests | false | 2 (unchanged) | ~12–20 |
| http-fuzz-dictionaries | false | **3 (down from 2)** | ~1–2 |

No candidate is HTTP/2-only, client-only, or parser-only-redundant-with-
nothing-added; all six either are the baseline itself (candidate 1) or add
something llhttp's parser-event-trace fixtures do not carry (connection
decision tables, multi-packet/pipelined/timeout byte shapes, or mutation
vocabulary). The one substantive correction is de-prioritizing the pure
dictionary/token material relative to the five candidates that carry actual
test cases or scenario logic.
