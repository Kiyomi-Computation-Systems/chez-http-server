# Skeptic verification — relevance & adaptability — batch 12

Lens: is this HTTP/1.x **server-side or connection-semantics** material (keep-alive, pipelining, framing
precedence, close, upgrade, limits, timeouts, smuggling), or is it parser-only (redundant with the llhttp
corpus chez-httparse already replays), client-only, or HTTP/2-only? Can the cases become byte streams /
scripted client sessions we replay? Default refuted=true for HTTP/2-only, client-only, or material that
adds nothing over llhttp.

All six candidates were fetched and checked against the live source (raw.githubusercontent.com for GitHub
repos, code.more-magic.net for Spiffy) rather than taken on the finder's word. Local files saved under
`scratchpad/research/`: `server_test.clj` (http-kit), `parser.lisp` + `fast-http.lisp` (fast-http),
`http_test.clj` + `http_continue_test.clj` (Aleph), `httpd-api.ss` + `httpd-handler.ss` + `httpd-server.ss`
+ `gxhttpd-test.ss` (Gerbil), `hunchentoot-script.lisp` (Hunchentoot). Spiffy was read via WebFetch only
(no raw-file mirror on code.more-magic.net).

---

## 1. http-kit-server-tests — **NOT refuted, tier 2 confirmed**

URL: https://github.com/http-kit/http-kit/blob/master/test/org/httpkit/server_test.clj
Fetched: https://raw.githubusercontent.com/http-kit/http-kit/master/test/org/httpkit/server_test.clj
(732 lines; saved as `server_test.clj`)

I listed all 41 `deftest` forms (via WebFetch) and then spot-checked the specific ones the finder called out
by `rg`-searching the downloaded file directly:

- `SpecialHttpClient` is indeed a **Java** helper class, confirmed by the import at `server_test.clj:15`:
  `org.httpkit.SpecialHttpClient`, used at lines 436, 463, 469, 475 for `getPartial`, `slowGet`, `get2`,
  `http10` — i.e. genuinely a raw-socket / partial-write / HTTP-1.0 client, not a Ring-level abstraction.
- `test-wrong-content-length` (`server_test.clj:274-279`): loops content lengths 1..1000 step 333, asserts
  `(:status resp) 200` and body length matches — this is "server computes/sends correct Content-Length for
  varying body sizes," matching the finder's summary.
- `test-respect-user-content-length` (`server_test.clj:281-289+`): legacy vs. new behavior when a handler
  sets its own `Content-Length` header — confirmed present.
- `rejects-blank-host-header` (`server_test.clj:384-387`):
  ```clojure
  (deftest rejects-blank-host-header
    (let [resp (http/get "http://localhost:4347/"
                         {:headers {"host" ""} :throw-exceptions false})]
      (is (= 400 (:status resp)))))
  ```
  Directly byte-stream-replayable: empty `Host:` header → expect 400.
- `test-host-header-port-validity` (`server_test.clj:389-394`) gives four concrete edge cases beyond the
  blank-Host test: `Host: localhost` (200), `Host: localhost:4347` (200), `Host: localhost:` (200, trailing
  colon with no port is tolerated), `Host: localhost:es` (400, non-numeric port), `Host: localhost:()` (400).
  These are excellent, directly portable acceptance-test inputs for our own Host-header validation.
- `test-graceful-stop-kills-long-inflight-requests` / `test-graceful-stop-responds-to-inflight-requests`
  (`server_test.clj:539-553`): a slow handler (2000ms or 500ms) plus a stop call with `:timeout 100` vs.
  `:timeout 3000` — confirms the finder's claimed semantics precisely (short graceful-stop timeout kills the
  slow in-flight request; a timeout longer than the handler's delay lets it finish with 200).
- `test-client-sent-one-byte-a-time`, `test-http10-keepalive`, `test-chunked-encoding`, `test-uri-len`,
  `test-duplicate-request-headers`, `test-many-headers`, `test-client-abort-server-receive-on-close`,
  `test-immediate-stop-kills-inflight-requests`, `test-server-header`,
  `test-application-gets-to-set-date` — all present exactly as named by the finder (confirmed via a full
  `deftest` name listing over the fetched file).

**Verdict**: every specific claim I checked against the actual file text held up exactly, including quoted
code. This is genuine server-side / connection-semantics material (HTTP/1.0 keep-alive, Host-header
validation, wrong/omitted Content-Length, graceful vs. immediate shutdown, client abort, chunked decoding,
byte-at-a-time delivery) driven partly over raw/partial sockets. It requires re-implementing the scenarios
in Scheme (Clojure `deftest` assertions, not vendorable data) — "effort medium" is fair. I found nothing to
refute and no reason to move it off tier 2; if anything it's one of the strongest candidates in this batch,
but I'm not inflating the finder's own tier since the reimplementation cost is real.

---

## 2. fast-http-parser-tests — **NOT refuted, tier downgraded 2 → 3**

URL: https://github.com/fukamachi/fast-http/tree/master/t
Fetched: `t/parser.lisp` (1563 lines) and `t/fast-http.lisp` (692 lines) via
`raw.githubusercontent.com/fukamachi/fast-http/master/t/{parser,fast-http}.lisp`.

Confirmed accurate, quoted directly from the downloaded files:
- Duplicate Transfer-Encoding rejection and Content-Length/Transfer-Encoding conflict rejection for
  **requests** (`parser.lisp` around lines 1437-1512), e.g.
  `(is-error (test-simple "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n") 'duplicate-transfer-encoding ...)`.
- Response leniency: `parser.lisp:1515-1524`, subtest "Response allows both Transfer-Encoding and
  Content-Length" — `(ok (http-chunked-p http) "response with TE:chunked and CL does not raise conflict
  error")`. The request/response asymmetry the finder claimed is real.
- Transfer-Encoding reset between pipelined messages (`parser.lisp:1526-1563`) — confirmed, two
  back-to-back `parse-request` calls on the same `http` object, second message's TE state is independent of
  the first's.
- "Parser poisoning after parsing-error" subtest — **not in `parser.lisp`** as the candidate's grouping
  implied, but present and exactly as described in `fast-http.lisp:658-690` (which the candidate did list
  as a corpus path): first call with an invalid method (`XYZZY / HTTP/1.1`) signals
  `fast-http.error:parsing-error`; a **second** call on the same parser instance then signals
  `fast-http.error:parser-poisoned` instead of re-parsing; `http-error-p` flips to `t`. Quoted in full in my
  working notes.
- "streaming chunk-size security limits" — confirmed at `fast-http.lisp:600-655`: a 17-hex-digit chunk-size
  split across two `funcall parser` calls signals `invalid-chunk-size` (max is 16 hex digits,
  `+max-chunk-size-digits+`), and a 1025-byte chunk extension split across two calls also signals
  `invalid-chunk-size` (`+max-chunk-extension-bytes+` = 1024); a valid 16-digit chunk-size is accepted.

**Where I push back**: this is explicitly parser-layer material (the finder's own `"layer": "parser"`), and
I checked whether the "connection-must-refuse-further-input" lesson the finder wants to extract is actually
new information versus the llhttp corpus chez-httparse already passes. It is not:

```
$ cd /Users/yuzu/github/llhttp && rg -il "duplicate.*transfer" test/request/
test/request/transfer-encoding.md
$ rg -n -i "duplicate" test/request/transfer-encoding.md
670:## POST with `chunked` and duplicate transfer-encoding
739:## POST with `chunked` and duplicate transfer-encoding (lenient)
$ rg -il "content.length.*transfer|transfer.*content.length" test/request/
test/request/content-length.md
test/request/transfer-encoding.md
```

llhttp v9.4.3's own request fixtures (`/Users/yuzu/github/llhttp/test/request/transfer-encoding.md:670,739`
and `test/request/content-length.md`) already carry both strict and lenient duplicate-Transfer-Encoding
cases and Content-Length/Transfer-Encoding conflict cases, and chez-httparse is stated (per project context)
to pass all 274 llhttp fixtures already. So the duplicate-TE and CL/TE-conflict *request-side* behavior
fast-http tests is not new. The one bit that plausibly isn't already covered by an llhttp fixture — TE+CL
both present in a **response** being tolerated (not rejected) — I could not find an equivalent explicit
fixture in `test/response/transfer-encoding.md` or `test/response/content-length.md` (checked both; the
closest hit used a decoy header `Content-Length-X`, not real `Content-Length` + real chunked `Transfer-
Encoding` together), so that one case is a legitimate, if narrow, addition. The "parser poisoning"
behavior is a fast-http **API design** choice (refuse to reuse a `make-parser` closure after an error), not
new protocol information: the project's own measurement (in the PROJECT CONTEXT) already establishes that
chez-httparse gives a bare `'error` status on the very next byte fed after a close-marked message, i.e. the
"stop feeding after an error/close" discipline is already independently known from chez-httparse's own
measured behavior — fast-http doesn't tell us anything chez-httparse hasn't already told us about our own
stack. The chunk-size/chunk-extension digit limits (16 hex digits / 1024 bytes) are fast-http's own
implementation-chosen limits, not RFC- or llhttp-derived, so they're at best a data point for choosing our
own budget, not a portable conformance case.

**Verdict**: claims are all accurate, but the practical value-add over the llhttp corpus we already have and
pass is much thinner than "12 cases, effort low" suggests once the duplicate-TE/CL-TE-conflict request-side
cases are set aside as already covered. **`corrected_tier: 3`** (reference only — one narrow response-side
TE+CL-tolerance case worth a manual unit test, nothing else clearly non-redundant).

---

## 3. aleph-http-tests — **NOT refuted, tier 3 confirmed, but two "covers" claims are mischaracterized**

URL: https://github.com/clj-commons/aleph/blob/master/test/aleph/http_test.clj
Fetched: `test/aleph/http_test.clj` (1930 lines) and `test/aleph/http_continue_test.clj` (112 lines) via
raw.githubusercontent.com.

Confirmed accurate and directly byte-stream-replayable:
- `test-overly-long-url` (`http_test.clj:612-615`): 100,000-char path → `(is (= 414 (:status @(http-get
  long-url))))`.
- `test-overly-long-header` (`http_test.clj:617-622`): 100,000-char header value → `431`.
- `test-invalid-http-version-format` (`http_test.clj:624-631`), driven over a **raw TCP socket**, not the
  Aleph client:
  ```clojure
  (let [client @(tcp/client {:host "localhost" :port port})
        _ @(s/put! client "GET / HTTP-1,1\r\n\r\n")
        response (bs/to-string @(s/take! client))]
    (is (str/starts-with? response "HTTP/1.1 400"))
    (s/close! client))
  ```
  — a clean byte stream we could replay verbatim against our own server.
- `test-idle-timeout`, `test-request-timeout`, `test-connection-timeout` (lines 719, 741, 878) — present.
- `test-max-request-body-size` (line 1135) → 413, confirmed.
- `test-in-flight-request-cancellation` (`http_test.clj:1749-1761`) — confirmed, but this is driven through
  Aleph's own client cancellation API (`http/cancel-request!`) plus a raw handler observing the server-side
  body stream close; it demonstrates "client aborts ⇒ server's request body/stream sees a close," which is
  conceptually portable (same idea as http-kit's `on-close` test) but not literally a byte sequence — it
  needs a scripted client session that opens a connection and then drops it mid-request.
- 100-continue: confirmed real and present, but in `http_continue_test.clj`, not `http_test.clj`
  (`http_continue_test.clj:46-47,79`: sends `Expect: 100-continue`, then `(wait-for c "100 Continue")`).

**Where the "covers" list overstates things**:
- *"pipelining transforms and aggregator support"* — I grepped every `pipelin` occurrence in `http_test.clj`
  (`test-pipeline-header-alteration` at line 941, `test-pipeline-transforms` at line 962,
  `test-http-object-aggregator-support`/`-raw-stream-support` at 1058/1073). Every one of these is about
  Netty's `ChannelPipeline` — the internal handler-chain / codec-ordering API — not HTTP wire-level request
  pipelining (sending multiple requests back-to-back on one connection without waiting for each response,
  which is what our task's lens means by "pipelining"). I found **no** test in this file that sends two
  requests on one connection without waiting for the first response. This claim should be read as "Netty
  channel-handler-chain plumbing," which is irrelevant to us since we aren't built on Netty and it says
  nothing about actual HTTP/1.1 pipelining semantics.
- *"HTTP/1 vs HTTP/2 version mismatch handling"* — `test-http-versions-server-config` (`http_test.clj:1447`
  onward) is entirely about **server-startup ALPN config validation** (e.g. asserting that mismatched
  `:http-versions` vs. `application-protocol-config` throws an `ExceptionInfo` with a specific message at
  server-creation time), not runtime protocol negotiation between an actual client and server. It's also
  SSL/ALPN- and HTTP/2-specific, which is out of scope for our HTTP/1.1-only server regardless.

**Verdict**: the finder's own tier-3 / "reference only beyond [the handful of status-code cases]" framing
was already appropriately conservative and matches what I found for the genuinely useful cases (414, 431,
400-bad-version-over-raw-TCP, three timeout kinds, 413, 100-continue). I'm not refuting the candidate, but
I am flagging that two of the ten "covers" bullets (pipelining, HTTP/1-vs-HTTP/2 mismatch) describe
Netty/ALPN internals rather than what their labels suggest, and both are irrelevant to us either way.
**Tier 3 stands, no correction.**

---

## 4. chicken-spiffy-tests — **Refuted for this corpus purpose (tier 3 → refuted)**

URL: https://code.more-magic.net/spiffy/tree/tests
Fetched via WebFetch: `tests/run.scm` (tree listing + summarized content) and `tests/testlib.scm`.

Harness-shape claim confirmed accurate: `testlib.scm` really does fork the server into a child process,
poll for the port, and drive it with an `intarweb`-based client:
- Port pre-check: `(define (check-port) (let ((listener #f) ...) (handle-exceptions exn (void) (set!
  listener (tcp-listen (server-port)))) (test-assert msg (tcp-listener? listener)) (tcp-close listener)))`
- Fork: `(set! spiffy-pid (process-fork (lambda () (parameterize ((root-path "./testweb") ...)
  (start-server)))))`
- Poll-until-ready: `(define (wait-for-spiffy times) (if (zero? times) #f (begin (thread-sleep! 1) (or
  (can-connect?) (wait-for-spiffy (sub1 times))))))`

Content claims (vhosts, static files, 404/exception-handler → 500, path-traversal safety via
`%2e%2e%2f`/`%5c`) also confirmed via WebFetch summary of `run.scm`.

**Why I'm refuting it for this task**: the task's lens is specifically HTTP/1.x connection semantics —
keep-alive, pipelining, framing precedence, close, upgrade, limits, timeouts, smuggling. Nothing in the
Spiffy test suite touches any of those: it is exclusively about routing/static-file/vhost/error-handler
behavior at the application layer, layered on top of whatever connection handling Spiffy already does
internally (which isn't tested here). The finder's own adaptability note already concedes this
("mostly static-file/vhost behaviour that is a later milestone... Not worth adapting now") and effectively
self-refutes the corpus's test *content*; what remains of value is purely the reusable harness *shape*
(fork+poll+client), which is an implementation pattern to imitate, not corpus material to extract, verify,
or replay. Given the strict lens, I'm marking this refuted rather than leaving it at tier 3, since as
connection-semantics/server corpus material it adds nothing; the harness idea can be kept as a footnote
without treating Spiffy as a corpus source.

---

## 5. gerbil-httpd-tests — **NOT refuted, tier upgraded 3 → 2**

URL: https://github.com/mighty-gerbils/gerbil/blob/master/src/std/net/httpd-test.ss
Fetched: `src/std/net/httpd-test.ss` (via WebFetch summary), `src/std/net/httpd/api.ss` (88 lines),
`src/std/net/httpd/handler.ss`, `src/std/net/httpd/server.ss`, `src/tools/gxhttpd-test.ss` (64 lines) — all
via raw.githubusercontent.com.

Every specific, checkable claim came back exact:
- `httpd-test.ss` test-case count/content (chunked + plain response, nested path mux with default handler,
  404, POST echo with a 16 KiB body) — confirmed via WebFetch summary; server started on
  `"127.0.0.1:19999"` via `(start-http-server! server-address mux: (make-recursive-http-mux))`.
- **All five numeric limit defaults the finder cited were verified exactly, in
  `httpd-handler.ss:323-329`:**
  ```
  323:(def request-timeout 60)
  324:(def response-timeout 120)
  325:(def max-request-headers 256)
  326:(def max-token-length 1024)
  327:(def max-request-body-length (expt 2 20)) ; 1MB
  328:(def input-buffer-size 8192)
  329:(def output-buffer-size 32768)
  ```
  This confirms not just the four the finder named (60/120/256/1024/1 MiB) but also the two buffer sizes
  (8192/32768) that make the finder's "16 KiB body larger than the server buffer" framing exactly correct:
  16384 bytes > input-buffer-size 8192.
- `gxhttpd-test.ss` has **exactly 5** `test-case` forms — I read the full 64-line file and counted them
  directly: `"/"`, `"/index.html"`, `"/handler"`, `"/servlets/hello.ss"`, `"/does-not-exist"` (the last
  asserting 404) — matching the finder's "5 test-cases in gxhttpd-test.ss" precisely.
- License: `gh api repos/mighty-gerbils/gerbil/license` auto-detects `LGPL-2.1` (via `LICENSE-LGPL.txt`,
  26430 bytes), and `LICENSE-APACHE-2.0.txt` also exists at the repo root (HTTP 200 on a direct fetch),
  confirming the finder's "LGPL-2.1 OR Apache-2.0" / "root carries LICENSE-APACHE-2.0.txt and
  LICENSE-LGPL.txt; gh auto-detects LGPL-2.1" note exactly.

**Why I'm upgrading it**: the finder rated this tier 3 ("Reference only") mostly because the test-case count
is small (7 total cases across both files). But everything I verified is precisely accurate, this is a
same-language-family (Scheme/Gambit) HTTP/1.x server with concrete, directly adoptable default values for
exactly the kind of limits our own server needs to choose (request/response timeouts, max header count, max
token length, max body length, I/O buffer sizes) — a genuinely rare and useful property none of the other
five candidates in this batch offer — plus 7 small, cleanly byte-stream/scripted-session-replayable test
cases (chunked vs. plain response, nested mux + default handler, 404, oversized POST body, static file,
dynamic handler, servlet). That combination (concrete portable numeric defaults + a handful of clean,
verified-accurate replayable cases, in a cousin Scheme implementation) justifies **`corrected_tier: 2`**
rather than reference-only tier 3.

---

## 6. hunchentoot-confidence-script — **NOT refuted, tier 3 confirmed**

URL: https://github.com/edicl/hunchentoot/tree/master/test
Fetched: `test/script.lisp` (237 lines) via raw.githubusercontent.com.

- `http-request` call count: `rg -c "http-request" hunchentoot-script.lisp` → **25**, matching "~25
  http-request steps" exactly.
- `test-acceptor-wake` confirmed at `script.lisp:40`, invoked at `script.lisp:234`, and calls into
  `hunchentoot::wake-acceptor-for-shutdown` (line 62) — a real acceptor-wake-for-shutdown test, as claimed.
- Range/Content-Range tests confirmed at `script.lisp:182-225`, and are more thorough than the finder's
  one-line summary suggested — four distinct sub-cases against a 256 KiB random-content file:
  single byte (`:range '(0 0)` → `Content-Range: bytes 0-0/N`), end-out-of-range clamped to file size,
  full-file range up to `(1- N)`, and a middle quarter-to-half-length slice — each with its own
  `Content-Range` header assertion. E.g.:
  ```lisp
  (http-request uploaded-file-url :range '(0 0))
  (http-assert 'body 'equalp (subseq range-test-buffer 0 1))
  (http-assert-header :content-range (format nil "bytes 0-0/~D" range-test-file-size))
  ```
- Cookie/session malformed-ID cases, Latin-1/UTF-8 param encoding, redirect, basic-auth, binary-response,
  and regex-dispatcher steps were all present as the finder described (spot-checked via WebFetch summary
  against the same downloaded file).

**Verdict**: accurately characterized; genuinely mostly application-level (Ring/CLOS-handler-level
concerns: cookies, sessions, auth, encoding), except the Range/Content-Range sub-cases, which are real
HTTP/1.1 protocol-layer behavior (byte-range serving, 206/416, `Content-Range` framing) but are tangential
to this task's specific connection-semantics lens (keep-alive/pipelining/framing-precedence/close/
upgrade/timeouts/smuggling) and belong to a later milestone (conditional/range requests), not this one.
**Tier 3 stands, no correction; not refuted** — the format idea (assert-per-request against a running
server) and the concrete Range test vectors are a legitimate, if low-priority, reference.

---

## Summary of verdicts

| key | refuted | corrected_tier | headline reason |
|---|---|---|---|
| http-kit-server-tests | false | 2 (unchanged) | every specific claim verified exactly against `server_test.clj`; genuine connection-semantics material (keep-alive, Host validation, graceful/immediate stop, client abort, byte-at-a-time) |
| fast-http-parser-tests | false | 3 (down from 2) | duplicate-TE and CL/TE-conflict *request* cases already exist in llhttp's own fixtures (`test/request/transfer-encoding.md:670,739`, `content-length.md`) that chez-httparse already passes; poisoning behavior is fast-http's own API design and already independently known from chez-httparse's own measured data-after-close behavior; only the response-side TE+CL-tolerance case looks non-redundant |
| aleph-http-tests | false | 3 (unchanged) | 414/431/400-bad-version/timeouts/413/100-continue confirmed real and byte-stream-replayable; "pipelining" claim is actually Netty ChannelPipeline internals (no real HTTP pipelining test found) and "HTTP/1 vs HTTP/2 mismatch" is ALPN server-config validation, not runtime negotiation — both mischaracterized and irrelevant regardless |
| chicken-spiffy-tests | true | — | harness pattern (fork+poll+client) confirmed real, but test content is 100% static-file/vhost/404 routing with zero coverage of keep-alive/pipelining/framing/close/upgrade/timeouts/smuggling; finder's own notes concede "not worth adapting now" |
| gerbil-httpd-tests | false | 2 (up from 3) | every numeric default (60/120/256/1024/1MiB/8192/32768) and test-case count (5 in gxhttpd-test.ss) verified exact in source; concrete, directly-adoptable config defaults from a cousin Scheme implementation plus 7 clean replayable cases — underrated at tier 3 |
| hunchentoot-confidence-script | false | 3 (unchanged) | 25 http-request steps and Range/Content-Range sub-cases confirmed exact; mostly application-level, Range tests are protocol-layer but tangential to this task's connection-semantics lens |
