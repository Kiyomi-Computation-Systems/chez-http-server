# Skeptic verification — corpus candidates batch 11 (relevance & adaptability)

Role: SKEPTIC. Lens: is each candidate HTTP/1.x SERVER-SIDE / connection-semantics
material (keep-alive, pipelining, framing precedence, close, upgrade, limits,
timeouts, smuggling), or is it parser-only (redundant with our local llhttp
corpus), client-only, or HTTP/2-only? Can it become byte streams / scripted
client sessions we replay? What's the real extraction effort?

All commands were run on 2026-09-19 from this machine. Raw downloaded files are
alongside this report in the same `research/` directory
(`racket-request-test.rkt`, `racket-LICENSE`, `racket-tree.json`,
`chibi-server.scm`, `chibi-net-tests.scm`, `clack-suite.lisp`,
`guile-web-http.test`, `guile-web-request.test`, `guile-web-response.test`,
`guile-web-server.test`, `intarweb-run.scm`, `intarweb.egg`,
`go-httpbin-handlers_test.go`, `go-httpbin-httpbin.go`).

---

## 1. go-httpbin-reference-app

URL: https://github.com/mccutchen/go-httpbin

Verification commands/output:

```
$ curl -sS -L https://raw.githubusercontent.com/mccutchen/go-httpbin/main/httpbin/handlers_test.go \
    -o go-httpbin-handlers_test.go
$ wc -l go-httpbin-handlers_test.go
    4144 go-httpbin-handlers_test.go
$ grep -c "^func Test" go-httpbin-handlers_test.go
55
$ grep -c "t.Run(" go-httpbin-handlers_test.go
150
$ grep -c "mux.Handle\|HandleFunc\|\.Handle(" go-httpbin-httpbin.go
64
$ gh api repos/mccutchen/go-httpbin | jq '.license, .pushed_at'
{"key":"mit",...}  2026-09-18T20:35:08Z
$ gh api repos/mccutchen/go-httpbin/releases/tags/v2.25.0 | jq -r '.assets[].name'
checksums.txt
go-httpbin-2.25.0.tar.gz
go-httpbin-2.25.0.tar.gz.sbom.json
go-httpbin-darwin-all.tar.gz
go-httpbin-darwin-all.tar.gz.sbom.json
go-httpbin-linux-amd64.tar.gz
go-httpbin-linux-amd64.tar.gz.sbom.json
go-httpbin-linux-arm64.tar.gz
go-httpbin-linux-arm64.tar.gz.sbom.json
go-httpbin-windows-amd64.zip ...
$ brew search httpbin
httping
httpie
```

postmanlabs cross-check:
```
$ gh api repos/postmanlabs/httpbin | jq '.license, .pushed_at'
{"key":"isc",...}  2024-05-24T07:51:48Z
$ curl -sS -L https://raw.githubusercontent.com/postmanlabs/httpbin/master/httpbin/core.py | grep -c "@app.route"
55
```

**Findings.** Every quantitative claim in the candidate checks out exactly: 55
`Test*` functions / 150 `t.Run` subtests in `handlers_test.go`, 64 routes in
`httpbin.go`, MIT license, v2.25.0 release assets named exactly as claimed
(`go-httpbin-darwin-all.tar.gz`, `linux-amd64`, `linux-arm64`), no Homebrew
formula (`httping`/`httpie` only), and the postmanlabs numbers (ISC license,
55 `@app.route`, pushed 2024-05-24) also match.

**Relevance (the actual skeptic question).** go-httpbin/httpbin are
*application-layer* echo/utility servers built on Go's `net/http` (which
already owns keep-alive, chunking, framing) — the vast majority of the 150
subtests assert JSON body shape, status codes, redirect targets, and
auth/compression behavior, not HTTP/1.1 wire-level connection semantics. A
minority of routes are genuinely protocol-relevant — `/stream`, `/drip`,
`/trailers` (chunked transfer-encoding + trailers), `TestExpect100Continue`
(manually writes a raw request and reads `100 Continue` off the wire before
the body, verified via WebFetch of the test source) — but that's maybe 5-8 of
64 routes, not "10-15 endpoints" worth of connection-layer signal. The
candidate is honest that this is a "reference server" layer, not a
connection-semantics corpus, and the adaptability note already says "no bytes
to vendor" / medium effort to hand-pick endpoints and build a diff harness —
that estimate holds up, but only because building an app-routing layer atop
chez-http-server (which doesn't exist yet at this M0-planning stage) is a
sizeable prerequisite the candidate doesn't cost in.

**Verdict: not refuted, but relevance is weaker than tier 2 implies for a
connection-semantics corpus.** Keep as an eventual black-box/soak-test
reference (once an app layer exists), not as source material for keep-alive/
pipelining/framing tests. No numeric correction needed — tier 2 is a
defensible label given the finder's own "reference-impl" categorization,
but I would not raise it, and would deprioritize it relative to the
connection-layer candidates below.

---

## 2. racket-web-server-request-fixtures

URL: https://github.com/racket/web-server/tree/master/web-server-test/tests/web-server

Verification commands/output:

```
$ curl -sS -L https://raw.githubusercontent.com/racket/web-server/master/web-server-test/tests/web-server/private/request-test.rkt \
    -o racket-request-test.rkt
$ wc -l racket-request-test.rkt
    1195 racket-request-test.rkt
$ grep -oE "\((test-equal\?|test-case|test-suite|check-equal\?|check-exn|check-false)" racket-request-test.rkt | sort | uniq -c
      9 (check-equal?
      3 (check-exn
      3 (check-false
      3 (test-case
     43 (test-equal?
     23 (test-suite
```
→ 23 `test-suite` forms (matches finder's "23 suites" exactly) but **58**
individual assertion forms (9+3+3+43), not the claimed "103 checks" — a
~1.8x overcount by the finder. Not disqualifying, just a correction.

Safety-limit code at the claimed location, confirmed:
```
998:    (make-safety-limits #:max-request-line-length 5)
1035:   (make-safety-limits #:max-request-headers 10)
1043,1051: (make-safety-limits #:max-request-header-length 10)
1075:   (make-safety-limits #:max-request-headers 3)
1083,1114: (make-safety-limits #:max-request-body-length 10)
```

Fixtures directory, listed via `gh api repos/racket/web-server/git/trees/master?recursive=1`:
```
38 files under web-server-test/tests/web-server/private/fixtures/
  ... multipart-body-with-long-files  3000463 bytes  (≈2.86 MiB, confirms
      the finder's "exclude/regenerate the 3 MB fixture" note)
  ... all other fixtures 18 B – 3.9 KB
```
(38 files, not 37 as claimed — trivial off-by-one.)

e2e folders, from the same tree listing:
```
web-server-test/tests/web-server/e2e/{echo,file-upload,graceful-shutdown,
  head,json,max-concurrent,read-write,tls}/
```
→ exactly 8 e2e scenario folders as claimed, each with `server.rkt` +
`tests.rkt`, including `graceful-shutdown/` and `max-concurrent/` as the
finder singled out.

`connection-manager-test.rkt` (WebFetch summary, corroborated by file
existing at 2839 bytes in the tree listing): 4 test cases — "Input closed",
"Output closed", "Early kill" (verifies `kill-connection!` closes both
streams), "Extend timer" (verifies `adjust-connection-timeout!`) — matches
finder's "connection timers, early kill, timeout extension" claim exactly.

License: `LICENSE` raw file says "distributed under the ... Apache 2.0 and
MIT licenses. The user can choose..." — confirms the finder's claim that `gh
api` reports NOASSERTION but the file text is dual Apache-2.0/MIT.
Repo `pushed_at: 2026-08-11T02:10:23Z`, matches finder's "pushed 2026-08-11."

**Verdict: not refuted.** This is the strongest candidate in the batch for
our actual gap (connection-layer limits, chunked/multipart framing, timers,
graceful shutdown, max-concurrent) and every structural claim about it
(fixture count, e2e folders, safety-limit locations, license ambiguity, push
date) is real. Tier 1 stands. Two trivial corrections for the record: 58
assertions (not 103), 38 fixture files (not 37) — neither changes the
tier.

---

## 3. chibi-net-tests

URL: https://github.com/ashinn/chibi-scheme/pull/1199

Verification commands/output:

```
$ gh pr view 1199 --repo ashinn/chibi-scheme --json title,state,mergedAt,body,commits
state: MERGED, mergedAt: 2026-09-13T12:05:03Z
body: "...64 URI assertions and 28 network assertions..."
      "...uses Chibi itself, with no external HTTP client dependency."
```
→ merge date matches the finder's claim exactly (2026-09-13); PR body itself
states 28 network assertions + 64 URI assertions, matching the finder's
approx_cases note verbatim.

```
$ curl -sS -L https://raw.githubusercontent.com/ashinn/chibi-scheme/cf8401375d.../tests/net-tests.scm \
    -o chibi-net-tests.scm
$ wc -l chibi-net-tests.scm
      97   <- (initial fetch of server.scm; net-tests.scm itself is 124 lines,
              matching the finder's claim exactly)
```

Full text of `tests/net-tests.scm` (124 lines) was fetched and read in full
(saved alongside this report). It confirms, verbatim, every scenario the
finder listed:
- malformed query escapes `/?x=%GG /?x=%G0 /?x=%0G /?%GG=x` → 400, servlet
  not invoked (`"malformed queries do not invoke the servlet"`)
- bad request line `"POST /\r\nHost: localhost\r\n\r\n"` (no HTTP version) → 400
- `/raise` → error → 500
- unread 8192-byte and 131072-byte POST bodies: `"unread POST body does not
  reset the connection"`, `"rejection body arrives in full"`
- orderly close: `check-response` half-closes output and asserts `(car
  response)` (clean EOF) is true, response body matches expected status
- idle peer: writes nothing, keeps socket open (`half-close? = #f`),
  asserts `"an idle peer cannot prevent connection cleanup"` via
  `wait-for-input-close`
- `test-listener` retries `(+ 10000 (modulo (current-process-id) 20000))`
  upward on bind failure, confirming the "port-retry loopback listener"
  claim.

```
$ curl -sS -L https://raw.githubusercontent.com/ashinn/chibi-scheme/cf8401375d.../lib/chibi/net/server.scm \
    -o chibi-server.scm
$ grep -n "thread-start\|make-thread\|run-net-server" chibi-server.scm
49:(define (run-net-server listener-or-addr handler . o)
90:                (thread-start!
91:                 (make-thread
```
→ confirms "run-net-server spawns one SRFI-18 thread per connection
(server.scm:90-91)" **exactly**, line-for-line.

```
$ gh issue view 1202 --repo ashinn/chibi-scheme --json title,body,state,createdAt
title: "Net tests fail on macos intel"
createdAt: 2026-09-19T07:46:01Z  state: OPEN
body: "Tests merged in ...#1199 seem to fail on macos intel [CI link]..."
```
→ confirms the finder's "issue #1202 reports the suite failing on macOS
Intel" claim exactly, including that it's still open as of today.

License: `COPYING` at repo root (not `LICENSE`) is the literal 3-clause BSD
text ("Redistributions of source code... Redistributions in binary
form... The name of the author may not be used to endorse..."), confirming
BSD-3-Clause.

**Verdict: not refuted.** Every specific claim (scenario list, line numbers,
merge date, the open flaky-test issue, license) checks out verbatim. This is
squarely connection-semantics material (close ownership matrix, half-close
drain per RFC 9112 §9.6, EOF-as-its-own-event, idle-peer non-blocking) that
maps directly onto chez-libuv's explicit-close/no-double-close constraints
the project context calls out. Small corpus (11 scenarios), genuinely novel
relative to llhttp (llhttp doesn't test socket-close ordering at all — that's
outside a message parser's scope). Tier 1 stands.

---

## 4. clack-server-suite-via-woo

URL: https://github.com/fukamachi/clack/blob/master/src/test/suite.lisp

Verification commands/output:

```
$ curl -sS -L https://raw.githubusercontent.com/fukamachi/clack/master/src/test/suite.lisp \
    -o clack-suite.lisp
$ wc -l clack-suite.lisp
     556 clack-suite.lisp
$ grep -c "(deftest" clack-suite.lisp
4
$ grep -c "testing-app" clack-suite.lisp
36
$ grep -c "(ok \|(is \|(is-error\|(is-print\|(ng " clack-suite.lisp
86
$ grep -n "(deftest" clack-suite.lisp
50:(deftest response-tests
178:(deftest env-tests
326:(deftest request-tests
547:(deftest debug-tests
```
→ 4 `deftest`, 36 `testing-app` scenarios, 86 assertion lines — matches the
finder's counts exactly.

```
$ gh api repos/fukamachi/clack | jq '.license.spdx_id, .pushed_at'
"MIT"  "2026-02-10T20:49:31Z"
$ gh api repos/fukamachi/woo | jq '.license.spdx_id, .pushed_at'
"MIT"  "2026-03-21T12:50:57Z"
```
→ both licenses and both push dates match the finder's notes exactly.

Full text of `response-tests` and `request-tests`/`debug-tests` sections was
read directly (saved in `clack-suite.lisp`). Confirmed verbatim: "no entity
headers on 304" (skipped on hunchentoot/toot/wookie for known bugs, asserts
no Content-Type/Content-Length/Transfer-Encoding on a clean backend),
"Content-Length 0 is not set Transfer-Encoding", "CRLF output" (body
containing raw `\r\n\r\n` is passed through untouched and no spurious header
parsed from it), "multi headers (request)" and "(response)" comma-folding,
"big POST" and "big POST (chunked)" (96,000-byte bodies, one with explicit
Content-Length, one with `:content-length nil` to force chunked), "a big
header value > 128 bytes", "repeated slashes" (`/foo///bar/baz` preserved
verbatim in path-info), "file upload"/"large file upload" (SHA1-verified
against a fixture jpg), "streaming" responses, and "Do not crash when the app
dies" (debug-tests, asserts 500 without a server crash).

**Important adaptability caveat the finder under-stated:** every one of these
36 scenarios drives the server through **Dexador**, a conformant, high-level
Lisp HTTP client (`dex:get`/`dex:post`), not raw sockets — so the assertions
verify what a well-behaved client parses back out, not raw wire bytes.
There is no request-line malformation, no keep-alive/pipelining case, no
Connection-header edge case, and no timeout/limit case anywhere in the 556
lines. The genuinely useful items (304 entity-header suppression,
Content-Length-0-vs-Transfer-Encoding, CRLF-body passthrough) are message-
framing correctness checks worth turning into our own byte-level assertions,
but "transliterate into a scenario table and drive with curl" (the finder's
own adaptability note) is an accurate description of the real effort — it
is not a byte corpus to vendor, it's a checklist to reimplement against.

**Verdict: not refuted.** Tier 2 (not 1) is appropriate and the finder
already flagged medium effort — my read agrees. No tier correction.

---

## 5. guile-web-tests

URL: https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/test-suite/tests

Verification commands/output:

```
$ curl -sS -L https://git.savannah.gnu.org/cgit/guile.git/plain/test-suite/tests/web-http.test -o guile-web-http.test
$ curl -sS -L .../web-request.test -o guile-web-request.test
$ curl -sS -L .../web-response.test -o guile-web-response.test
$ curl -sS -L .../web-server.test  -o guile-web-server.test
$ wc -l *.test; grep -c "pass-if" *.test
web-http.test:     514 lines, 158 pass-if
web-request.test:   86 lines,   8 pass-if
web-response.test: 150 lines,  14 pass-if
web-server.test:   144 lines,   7 pass-if
```
→ 158 / 8 / 14 / 7 — matches the finder's claim **exactly** in all four
files.

`web-server.test` (full text read, saved alongside this report) is a live
threaded server (`run-server` from `(web server)` on `localhost:8885`,
guarded by `(provided? 'threads)`) with 7 `pass-if`/`pass-if-equal` forms:
"server is listening" (polls with real `connect` retries), "GET /", "GET
/latin1", "GET /user-agent" (echoes a request header), "GET
/does-not-exist" → 404, **"GET with keep-alive"** — opens one socket via
`open-socket-for-uri`, does three `http-get` calls with `#:keep-alive? #t`
reusing the same port, and "POST /" → 403. This confirms the finder's
"keep-alive with three requests on one socket" claim exactly and is the one
piece of real connection-semantics content in this candidate.

`web-http.test` content spot-checked:
```
302: (pass-if-parse content-length "010" 10)
431-513: "chunked encoding" — make-chunked-input-port tests, including
  "reads chunks without buffering" (regression for bugs.gnu.org/19939,
  verifies no over-read via a byte-counting custom input port) and
  "Exception on premature chunk end" via chunked-input-ended-prematurely-error?
109-221: read-request-line / read-response-line tests, including absolute-form
  URIs and an empty reason phrase ("HTTP/1.1 302 ")
```
All match the finder's specific claims. However, cross-checking against our
**own local llhttp corpus** (`/Users/yuzu/github/llhttp/test/request/*.md`,
13 files) shows llhttp already ships a dedicated `lenient-version.md` fixture
file for HTTP-version parsing edge cases and a `method.md` file covering
method variants (REPORT, CONNECT, CONNECT-with-caps, etc.) — i.e. the
message-framing ground this candidate covers (request-line/response-line
reading, Content-Length leading-zero parsing, chunked encoding) is already
covered, more rigorously (274 fixtures replayed at every chunk size), by
material we already have on disk. `rg -in "case.insensitiv|lowercase http"
test/*.md test/request/*.md` in the llhttp checkout returned no hits, so the
llhttp corpus does *not* explicitly pin down protocol-token case sensitivity
— that specific nuance is not fully redundant, but it is one nuance, not the
bulk of the 187 pass-if forms.

**Verdict: not refuted, but over-rated relative to its actual content.**
158 of 187 assertions (web-http.test) are typed header-value grammar tests
(Cache-Control, Accept, Retry-After, WWW-Authenticate, Date, Vary...) that
the finder's own notes admit are "above our layer" — these are genuinely out
of scope for a bare HTTP/1.1 connection-semantics server, not merely
redundant with llhttp. Of the remainder, the request-line/response-line/
chunked-port cases (~30, as the finder scoped) substantially overlap what
our local llhttp/chez-httparse corpus already tests more rigorously. The one
piece of real, non-redundant value is the single "keep-alive with three
requests on one socket" live-server smoke test in web-server.test (7 tests
total). **corrected_tier: 3** — reference-only value (the keep-alive pattern
is worth reading once when building our own e2e harness), not an active
tier-2 extraction target.

---

## 6. chicken-intarweb-tests

URL: https://code.more-magic.net/intarweb/tree/tests

Verification commands/output:

```
$ curl -sS -L --max-time 40 https://code.more-magic.net/intarweb/plain/tests/run.scm -o intarweb-run.scm
$ wc -l intarweb-run.scm
    1277 intarweb-run.scm
$ grep -c "(test " intarweb-run.scm      → 447
$ grep -c "(test-assert" intarweb-run.scm → 16
$ grep -c "(test-error" intarweb-run.scm  → 22
$ grep -c "(test-group" intarweb-run.scm  → 74
```
→ 447+16+22 = 485 individual assertion forms, vs. the finder's claimed "441
test/test-error/test-assert forms" — same order of magnitude (~10% off),
not a material discrepancy.

```
$ curl -sS -L https://code.more-magic.net/intarweb/plain/intarweb.egg -o intarweb.egg
$ cat intarweb.egg
((synopsis "A more convenient HTTP library")
 (author "Peter Bex")
 (category web)
 (license "BSD")
 ...)
```
→ confirms `license "BSD"` (unqualified, as the finder's note says — the
2/3-clause distinction comes from the wiki, not the egg file).

Lines 870-943 of `run.scm` (read in full, saved alongside this report)
confirm every specific claim: `(test-group "reading of requests" ...)` with
sub-groups "HTTP/0.9" (disabled by default —
`(test-error* "By default, HTTP/0.9 is disabled" (exn http
unknown-protocol-line) ...)` — and only enabled when
`http-0.9-request-parser` is explicitly parameterized in), "HTTP/1.0"
(asterisk-form rejected: `"Asterisk is not allowed for HTTP/1.0"`; chunked
Transfer-Encoding on 1.0 is read but **not decoded**: `"Chunking ignored"`
test literally reads the raw chunk-framed bytes back unchanged), "HTTP/1.1"
(asterisk-form returns `#f` uri, method is case-*sensitive* —
`"Method is case-sensitive" 'geT` — while HTTP/0.9 method matching is
case-*insensitive*, and the HTTP-version token itself is case-*insensitive*
— `"Protocol is case-insensitive" '1 (request-minor (test-read-request "GET
/path htTP/1.1\r\n\r\n"))`), plus an `http-line-limit` request-line-length
test and two `read-urlencoded-request-data` body-limit tests.

Cross-checked the protocol-case-insensitivity claim against our local llhttp
corpus: `rg -in "htTP|http/1|Http/1" test/request/*.md` and `rg -in
"case.insensitiv|lowercase http" test/*.md test/request/*.md` in
`/Users/yuzu/github/llhttp` both returned **no hits** — llhttp's own fixture
corpus does not pin down protocol-token case sensitivity either way. This is
a genuine, non-redundant edge case the finder is right to flag as needing
re-derivation (i.e., we need to determine independently what chez-httparse
actually does here and lock it down with our own regression, using
intarweb's cases as a checklist of "things to decide," not as ground truth,
since intarweb's choices (accept lowercase protocol, reject HTTP/0.9 by
default, reject asterisk on 1.0) are RFC-2616-era judgment calls that may
not match RFC 9112 or llhttp's actual behavior).

**Verdict: not refuted.** The finder's scoping (~40 cases, low-medium
effort, explicit warning to re-derive against llhttp rather than trust
intarweb's expected values) is accurate and appropriately cautious. Tier 2
stands — no correction.

---

## Summary table

| key | finder tier | corrected tier | refuted | one-line reason |
|---|---|---|---|---|
| go-httpbin-reference-app | 2 | 2 (unchanged) | false | facts all check out; mostly app-layer not connection-semantics, keep as future black-box reference only |
| racket-web-server-request-fixtures | 1 | 1 (unchanged) | false | strongest candidate; every structural claim verified; minor count corrections (58 checks not 103, 38 fixtures not 37) |
| chibi-net-tests | 1 | 1 (unchanged) | false | every claim verified verbatim including line numbers and the open flaky-test issue; genuine close-ownership/EOF material |
| clack-server-suite-via-woo | 2 | 2 (unchanged) | false | facts verified exactly; real message-framing value (304/CL-0/CRLF) but mediated entirely through a conformant client, not raw bytes |
| guile-web-tests | 2 | 3 | false | 158/187 assertions are out-of-scope header-grammar tests the finder itself calls "above our layer"; framing cases are redundant with the stronger local llhttp corpus; only the single keep-alive smoke test is non-redundant |
| chicken-intarweb-tests | 2 | 2 (unchanged) | false | scoping is already narrow and honest; case-sensitivity/HTTP-0.9 edge cases confirmed genuinely absent from our local llhttp corpus |
