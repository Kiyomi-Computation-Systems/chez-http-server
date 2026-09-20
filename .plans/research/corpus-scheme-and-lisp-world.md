# Corpus survey: Scheme and Lisp world HTTP servers and their test suites

- Lens: scheme-and-lisp-world (one of seven corpus finders)
- Date measured: 2026-09-19
- All downloaded evidence lives under
  `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/dl/` (referred to below as `dl/`).
  Nothing was written into any git repository.
- Fetch tooling: `gh api` (authenticated as DarrenN; `gh auth status` printed
  `Logged in to github.com account DarrenN`), `curl -sL`, and WebFetch for
  non-GitHub hosts. WebFetch returned HTTP 401 for fossies.org and
  code.call-cc.org; those were replaced by curl against the canonical hosts
  (Savannah cgit for Guile, code.more-magic.net cgit for the CHICKEN eggs).

## 0. Summary and tiering

| # | key | repo | license | layer | tier | fits |
|---|-----|------|---------|-------|------|------|
| 1 | racket-web-server-request-fixtures | racket/web-server | Apache-2.0 OR MIT | connection | 1 | (c), (a) |
| 2 | chibi-net-tests | ashinn/chibi-scheme | BSD-3-Clause | connection | 1 | (a), (b) |
| 3 | clack-server-suite-via-woo | fukamachi/clack (+ fukamachi/woo) | MIT | server | 2 | (b) |
| 4 | guile-web-tests | GNU Guile (Savannah) | LGPL-3.0-or-later | parser + server | 2 | (c), (b) |
| 5 | chicken-intarweb-tests | code.more-magic.net/intarweb | BSD | parser | 2 | (c) |
| 6 | http-kit-server-tests | http-kit/http-kit | Apache-2.0 | server | 2 | (b) |
| 7 | fast-http-parser-tests | fukamachi/fast-http | MIT | parser | 2 | (c) |
| 8 | aleph-http-tests | clj-commons/aleph | MIT | server / security | 3 | (b) |
| 9 | chicken-spiffy-tests | code.more-magic.net/spiffy | BSD | server | 3 | (b) |
| 10 | gerbil-httpd-tests | mighty-gerbils/gerbil | LGPL-2.1 OR Apache-2.0 | server / reference-impl | 3 | (a), (b) |
| 11 | hunchentoot-confidence-script | edicl/hunchentoot | BSD-2-Clause | server | 3 | (b) |
| 12 | protium-local-plans | /Users/yuzu/github/protium | BSD-3-Clause | reference-impl | 3 | n/a |

Surveyed but not listed as findings (no test corpus): Gambit's
`examples/web-server` (thread-per-connection example, no tests) and Loko's
`samples/web-server` (fibers, hand-written response, EUPL-1.2, no tests). See
section 13.

Tier meanings: 1 = vendor now with a PROVENANCE file; 2 = adapt later;
3 = reference only.

The (a)/(b)/(c) labels are the three test strategies from the task: (a)
in-process over loopback TCP with chez-libuv client verbs; (b) black-box from
external clients against a port; (c) sans-I/O connection driver replaying byte
streams at every chunk size.

## 0.1 Handler API shapes across the surveyed servers (async-model input)

| server | concurrency model | handler signature | response API | notes |
|--------|------------------|-------------------|--------------|-------|
| Racket web-server | thread per connection under a custodian; connection-manager with per-connection timers (`private/connection-manager-test.rkt`) | dispatcher `(conn req) -> void`; servlets `(request -> response)`; `send/suspend` continuations | `response` struct written to the connection output port | tests use `make-mock-connection` (byte ports) so the server core is testable sans-socket (`util.rkt` lines 42-51) |
| Chibi `(chibi net http-server)` | thread per connection (SRFI-18 `make-thread` in `server.scm:90-91`) | servlet `(cfg request next restart)` (`http-server.scm:7-13`) | `servlet-respond`, `servlet-write` on request ports | 400 on request-construction error, 500 on servlet error (`http-server.scm:15-16`) |
| Guile `(web server)` default `http` impl | single-threaded `poll` loop; `define-server-impl http http-open http-read http-write http-close` (`server-http.cgit.scm:178-182`) | `(handler request body) -> (values response body)`; body may be bytevector, string or `(lambda (port) ...)` (`web-server.test` lines 38-52) | `build-response`, keep-alive decided in `http-write` (`keep-alive?` lines 141-165) | `(web server fibers)` in guile-fibers gives a concurrent impl with the same handler shape |
| CHICKEN spiffy | thread per connection (SRFI-18) in `accept-loop`; tests fork the server process (`testlib.scm` `process-fork`) | handlers read `current-request`/`current-response` parameters; vhost-map entries are one-argument procedures taking a continuation thunk | `send-status`, `send-response`, `send-static-file`, `write-logged-response` | intarweb does the parsing via `read-request`/`write-response` on ports |
| Gerbil `std/net/httpd` | Gambit green thread per connection spawned by acceptor actors (`server.ss` `spawn/name 'http-server-accept`); actor messages for control | `(lambda (req res) ...)` registered per path on a Mux (`httpd-test.ss` lines 43-60) | `http-response-write`, `http-response-begin/chunk/end`, `http-response-file`, `http-response-upgrade!` | explicit limits: request-timeout 60, response-timeout 120, max-request-headers 256, max-token-length 1024, max-request-body-length 1 MiB (`handler.ss:323-327`) |
| Gambit example | thread per connection when `threaded?: #t` (`http.scm:765-773`) | method-table thunks reading `(current-request)` | `reply-html`, `write-html` on the connection port | web-continuation demo serialises continuations into forms |
| Loko sample | fibers: `spawn-fiber` per accepted socket | raw `(in out)` port pair | hand-written `HTTP/1.1 200 OK` | no parser; EUPL-1.2 |
| Hunchentoot | thread per connection (taskmaster) on an `acceptor` CLOS object | `define-easy-handler`, handlers read `*request*` specials | return a string/octets or write to a stream; `send-headers` for streaming (`stream-direct` handlers in `test-handlers.lisp`) | script test drives a live server with drakma |
| Woo | libev event loop, single-threaded per worker, N worker processes; fast-http callback parser | Clack app `(lambda (env) (list status headers body))`; body may be list/pathname/octets or `(lambda (responder) ...)` for streaming | responder closure | closest architecture to ours (event-loop + callback parser) |
| http-kit | event-driven NIO loop plus worker pool | Ring `(fn [req] resp-map)`; async `(as-channel req {:on-open #(send! % ...)})` (`server_test.clj:52-58`) | `send!` with a `close?` flag for streaming (`server_test.clj:69-76`) | tests: graceful vs immediate stop, in-flight requests |
| Aleph | Netty event loop | Ring map in, map out; Manifold deferreds/streams for async bodies | streams | tests: 414/431 for long URL/header, 400 for bad version via raw TCP |

Design signal for chez-http-server: every Scheme-world server except Guile's
default impl and Loko's sample is thread-per-connection; the event-loop +
callback designs we resemble (Woo, http-kit, Aleph) all converge on the same
application contract — synchronous "request in, response out" for the common
case plus an explicit escape hatch (Woo's responder lambda, http-kit's
`as-channel`/`send!`, Aleph's Manifold stream) for streaming and deferred
responses — and all three ship test cases for stop/shutdown semantics with
in-flight requests, which the Scheme suites do not.

---

## 1. Racket web-server: `web-server-test/tests/web-server/` (Tier 1)

- URL: https://github.com/racket/web-server (default branch `master`, pushed
  2026-08-11T02:10:23Z per `gh api repos/racket/web-server`)
- License: `LICENSE` at the repo root (fetched raw; `dl/racket/LICENSE`):

  ```
  This component of Racket is distributed under the under the Apache 2.0
  and MIT licenses. The user can choose the license under which they
  will be using the software.
  ```

  SPDX: `Apache-2.0 OR MIT`. (`gh api` reported `NOASSERTION` for the
  auto-detected license because of the dual wording.)

### Corpus paths (confirmed by `gh api repos/racket/web-server/contents/...`)

Top level `web-server-test/tests/web-server/`:

```
file .../all-web-server-tests.rkt 1007
file .../dispatch-test.rkt 20877
dir  .../dispatchers
dir  .../e2e
file .../formlets-test.rkt 37645
dir  .../http
file .../lang-test.rkt 24717
dir  .../private
dir  .../pr
file .../serve-tests.rkt 4777
dir  .../stress
file .../util.rkt 3328
```

`web-server-test/tests/web-server/private/`:

```
file .../private/cache-table-test.rkt 3519
file .../private/connection-manager-test.rkt 2839
dir  .../private/fixtures
file .../private/gzip-test.rkt 812
file .../private/mime-types-test.rkt 1598
file .../private/request-test.rkt 44031
file .../private/response-test.rkt 21901
file .../private/util-test.rkt 4614
```

`web-server-test/tests/web-server/private/fixtures/` — 37 raw HTTP request
files (sizes in bytes):

```
get-with-long-multi-line-header 268
get-with-long-single-line-header 148
get-with-many-headers 622
get-with-query-params 389
headers-to-github-dot-com 928
headers-to-reddit-dot-com 1755
multipart-body-empty 18
multipart-body-field-empty 72
multipart-body-field-with-many-headers 882
multipart-body-field-without-data 70
multipart-body-field-without-name 64
multipart-body-fields-only 139
multipart-body-fields-without-data 131
multipart-body-realistic 3907
multipart-body-with-line-breaks 97
multipart-body-with-long-field 1188
multipart-body-with-long-files 3000463
multipart-body-with-long-preamble 125
multipart-body-with-mixture-of-fields-and-files 447
multipart-body-with-multiple-files 255
multipart-body-with-too-long-preamble 174
multipart-body-without-disposition 22
multipart-body-without-end-boundary 65
post-with-body-params-and-query-params 441
post-with-body-shorter-than-content-length 466
post-with-chunked-transfer-encoding 246
post-with-empty-body 428
post-with-empty-multipart-body 546
post-with-invalid-content-length 470
post-with-json-body 165
post-with-json-body-and-query-param 174
post-with-long-file 2137
post-with-multi-line-header 192
post-with-multi-line-header-tabbed 208
post-with-multipart-data-without-body 511
post-with-multipart-data-without-disposition 156
post-with-short-file 233
```

`web-server-test/tests/web-server/e2e/` (README says each subfolder holds
`server.rkt` providing `start` and `tests.rkt` providing `make-tests`):
`echo`, `file-upload`, `graceful-shutdown`, `head`, `json`, `max-concurrent`,
`read-write`, `tls`.

`web-server-test/tests/web-server/http/`: `cookies-test.rkt` 16935,
`digest-auth-test.rkt` 5489, `json.rkt` 3104, `response-test.rkt` 6699,
`xexpr.rkt` 3446.

### Case counts (measured on `dl/racket/private-request-test.rkt`)

```
$ wc -l private-request-test.rkt            -> 1195
$ rg -c '\(test-case|\(check-|\(test-equal|\(test-exn|\(test-not-exn' ... -> 103
$ rg -n '\(test-suite' | rg '"'  (suite names):
  "HTTP Requests" > "Utilities" > bytes->nonnegative-integer-suite,
  read-http-line/limited, read-bytes/lazy, make-spooled-temporary-file,
  read-request-line, read-mime-multipart; "Headers" > read-headers,
  headers-assq; "Bindings" > parse-bindings, bindings-assq; "Parsing" >
  "Request Line", "Headers", "Chunked transfer-encoding", "JSON data",
  "GET bindings", "POST Bindings", "File Uploads"
```

`private/response-test.rkt`: ~12 `test-suite` forms including range
handling (`"(get) some bad ranges (error)"`, `"(head) all bad ranges"` at
lines 288-337). `private/connection-manager-test.rkt`: 4 test-cases ("Input
closed", "Output closed", "Early kill", "Extend timer"). `serve-tests.rkt`
starts a real server with `#:port 0` and `make-safety-limits
#:shutdown-grace-period 5` and checks shutdown duration with `check-duration`.

### What it covers (verbatim excerpts, `dl/racket/private-request-test.rkt`)

The feeding mechanism is the reason this is Tier 1: requests are read from a
byte port wrapped so data arrives in random 1..127-byte chunks — the same
idea as our (c) replay-at-every-chunk-size driver:

```racket
;; Wraps `inp' so that parts of it are available in random chunk
;; sizes, like they would be under realistic network conditions.
(define randomly-chunked-ip
  (make-ip-chunker (lambda ()
                     (random 1 128))))
```
(lines 232-236)

```racket
(define (fixture/ip filename [chunker randomly-chunked-ip])
  (chunker (open-input-file (build-path fixtures filename))))
```
(lines 24-25)

```racket
(define (test-read-request b [read-request standard-read-request])
  ...
    (define conn
      (connection 0 timer ip op custodian #f))
    (define-values (req close?)
      (read-request conn 80 (lambda _ (values "to" "from"))))
    (hasheq
     'method (request-method req)
     'uri (string->bytes/utf-8 (url->string (request-uri req)))
     'headers (request-headers/raw req)
     'bindings (request-bindings/raw req)
     'body (request-post-data/raw req)
     ...
     'close? close?)))
```
(lines 101-122)

Safety-limit cases (lines 981-1110) map one-to-one onto a `limits.sls`:

```racket
     (test-exn:fail:network
      "request line too short"
      #rx"line exceeds limit of 5"
      (lambda ()
        (do-test-read-request/limits #"OPTIONS /some/path HTTP/1.1\r\n\r\n"
                                     (make-safety-limits #:max-request-line-length 5)))))
     ...
     (test-exn:fail:network
      "too many headers"
      #rx"header count exceeds limit"
      (lambda ()
        (do-test-read-request/limits
         (fixture "get-with-many-headers")
         (make-safety-limits #:max-request-headers 10))))
     (test-exn:fail:network
      "header too long"
      #rx"line exceeds limit of 10"
      ...
         (make-safety-limits #:max-request-header-length 10))))
     ...
     (test-exn:fail:network
      "chunked request too large"
      #rx"chunked content exceeds max body length"
      ...
         (make-safety-limits #:max-request-body-length 10)))))
```

Also covered: `OPTIONS * HTTP/1.1` asterisk form, obs-fold ("line-folded
header values", tabbed variant), chunked transfer-encoding with trailers
(`Some-Footer`, `Another-Footer`), JSON bodies with and without query
params, POST bindings, multipart file uploads (23 multipart fixture files,
including `without-end-boundary`, `too-long-preamble`, `field-without-name`),
`post-with-body-shorter-than-content-length`, `post-with-invalid-content-length`.

`util.rkt` shows the mock-connection pattern (lines 42-51):

```racket
(define (make-mock-connection ib)
  (define ip (open-input-bytes ib))
  (define op (open-output-bytes))
  (define tm (start-timer-manager))
  (values (make-connection 0 (make-timer tm +inf.0 void)
                           ip op (make-custodian) #t)
          ip
          op))
```

### Adaptability

- (c) primary: vendor the 37 files under `private/fixtures/` verbatim (they
  are raw HTTP bytes; 3 MB `multipart-body-with-long-files` may be excluded
  or generated) plus a hand-transcribed s-expression manifest of the expected
  `(method uri headers body close?)` tuples and the limit-violation cases
  from `request-test.rkt` lines 981-1195. Our connection driver feeds each
  file at every chunk size 1..N and asserts the manifest; the obs-fold and
  chunked-trailer cases exercise chez-httparse spans through our header
  assembly. Multipart cases are for a later body-parsing milestone.
- (a): the e2e layout (`server.rkt` `start` returns `(values stop port)`;
  `tests.rkt` `make-tests` takes port+stop thunks) is a clean pattern for
  our loopback suite; `graceful-shutdown` and `max-concurrent` are the
  scenarios to copy first.
- Effort: low for fixtures (copy + PROVENANCE), medium for the manifest
  (~40 expected-value tables to transcribe). The rackunit code itself is not
  reusable.
- PROVENANCE: record commit of `racket/web-server` master, path
  `web-server-test/tests/web-server/private/fixtures/`, license text above.

---

## 2. Chibi Scheme `tests/net-tests.scm` (Tier 1)

- URL: https://github.com/ashinn/chibi-scheme (pushed 2026-09-13T12:05:02Z);
  the corpus was added by PR #1199
  https://github.com/ashinn/chibi-scheme/pull/1199 ("Handle HTTP request
  parse errors and close rejected uploads cleanly", merged
  2026-09-13T12:05:03Z per `gh api repos/ashinn/chibi-scheme/pulls/1199`).
- License: `COPYING` (fetched raw, `dl/chibi/COPYING`): "Copyright (c)
  2009-2021 Alex Shinn ... Redistribution and use in source and binary
  forms, with or without modification, are permitted provided that the
  following conditions are met: 1. ... 2. ... 3. The name of the author may
  not be used to endorse or promote products ..." → BSD-3-Clause.
- Corpus paths (from `gh api repos/ashinn/chibi-scheme/pulls/1199/files`):

  ```
  modified Makefile +4/-1
  modified lib/chibi/net/http-server.scm +7/-3
  modified lib/chibi/net/server.scm +20/-5
  modified lib/chibi/net/server.sld +1/-1
  modified lib/chibi/uri-test.sld +20/-0
  modified lib/chibi/uri.scm +1/-1
  modified lib/srfi/18/threads.c +2/-1
  added tests/net-tests.scm +124/-0
  ```

  `tests/net-tests.scm` is 5084 bytes on master (`gh api
  .../contents/tests` listing).
- Case count: 124 lines, 15 `test`/`test-assert` forms measured with
  `rg -c '^\s*\(test'`; the PR description (WebFetch) says "64 URI
  assertions and 28 network assertions"; run with `make test-net`
  (included in `make test-all`), "using Chibi itself, with no external HTTP
  client dependency".

### What it covers (verbatim, `dl/chibi/net-tests.scm`)

```scheme
;; HTTP request errors and connection teardown, using a loopback listener.
...
;; Retry binds rather than depending on a fixed port being unused.
(define (test-listener)
  (let lp ((port (+ 10000 (modulo (current-process-id) 20000))) (tries 100))
  ...
(define (exchange port bytes half-close? inspect)
  ...
        (write-bytevector bytes out)
        (flush-output-port out)
        (if half-close? (close-output-port out))
        (inspect (read-response sock)))
...
      (check-response port "/" "404")
      (check-response port "/?a&b=c" "404")
      (test '(("a" . #f) ("b" . "c")) (request-params last-request))
      (check-response port "/?&" "404")
      (test '(("" . #f)) (request-params last-request))
      (let ((before calls))
        (for-each (lambda (target) (check-response port target "400"))
                  '("/?x=%GG" "/?x=%G0" "/?x=%0G" "/?%GG=x"))
        (test "malformed queries do not invoke the servlet" before calls))
      (check-response port "/raise" "500")
      (exchange port (string->utf8 "POST /\r\nHost: localhost\r\n\r\n") #t
        (lambda (response)
          (test-assert "bad request line returns 400"
            (string-prefix? "HTTP/1.1 400 " (cadr response)))))
      (exchange port (post "/" (make-string 8192 #\x)) #t
        (lambda (response)
          (test-assert "unread POST body does not reset the connection" (car response))
          (test-assert "rejection body arrives in full"
            (string-suffix? "rejected" (cadr response)))))
      (exchange port (post "/" (make-string 131072 #\x)) #t
        (lambda (response)
          (test-assert "large unread POST body does not reset the connection"
            (car response))
          (test-assert "large rejected upload still receives the response"
            (string-suffix? "rejected" (cadr response)))))
      (exchange port (post "/" "") #f
        (lambda (response)
          (test-assert "response finishes while the peer can still write" (car response))
          (test-assert "an idle peer cannot prevent connection cleanup"
            (wait-for-input-close last-request))))
```

The PR description (WebFetch of the PR page) explains the server-side rule
the tests pin: half-close output after flushing the response, then drain
unread input until EOF or a one-second deadline before closing, "following
the staged close described in RFC 9112, section 9.6".

### Handler API (from `dl/chibi/http-server.scm` lines 7-16, 38-70)

```
;;> A servlet is a procedure which takes four arguments: a
;;> \scheme{(chibi config)} config object, an \scheme{Http-Request} record,
;;> which contains the I/O ports and parsed request and headers;
;;> a \scheme{next} procedure to call the next available servlet if any,
;;> and a \scheme{restart} procedure to restart the servlets with a new
;;> request.
;;>
;;> Errors constructing the request return HTTP 400 (Bad Request).
;;> Unhandled servlet errors return HTTP 500 (Internal Server Error).
```

Thread model: `run-net-server` starts one SRFI-18 thread per accepted
connection (`dl/chibi/server.scm` lines 90-91: `(thread-start! (make-thread
...`).

### Adaptability

- (a) and (b): this is exactly the connection-teardown matrix we must get
  right with libuv's explicit close semantics (server owns every close; RST
  vs orderly EOF on unread bodies; response completes while the peer keeps
  the socket open; idle-peer cleanup by deadline). The 11 scenarios rewrite
  in ~150 lines against chez-libuv's `uv-tcp-connect!`/`uv-write!`/on-data
  verbs; the port-retry listener idiom is directly reusable on Chez.
- Effort: low. Vendor `tests/net-tests.scm` verbatim as the PROVENANCE
  source, then port the scenario list.
- Caveat: issue #1202 reports these tests failing on macOS Intel
  (https://github.com/ashinn/chibi-scheme/issues/1202); the deadline-based
  drain is timing-sensitive, which is a lesson in itself.

---

## 3. Clack server conformance suite, run by Woo (Tier 2)

- Woo URL: https://github.com/fukamachi/woo (MIT per `gh api repos/fukamachi/woo
  --jq .license.spdx_id` → `MIT`; `woo.asd` line 4 `:license "MIT"`; pushed
  2026-03-21).
- Woo test dir (`gh api repos/fukamachi/woo/contents/t`):

  ```
  file t/generate-certificates.sh 773
  file t/ipv6.lisp 686
  file t/woo.lisp 465
  ```

  `t/woo.lisp` (verbatim, `dl/woo/woo.lisp`) contains no cases of its own:

  ```lisp
  (deftest woo-server-tests
    (clack.test.suite:run-server-tests :woo))
  (deftest woo-ssl-server-tests
    (let ((clack.test:*clackup-additional-args*
            '(:ssl-cert-file #P"t/certs/localhost.crt"
              :ssl-key-file #P"t/certs/localhost.key"))
          (dex:*not-verify-ssl* t)
          (clack.test:*use-https* t))
      (clack.test.suite:run-server-tests :woo)))
  ```

- The real corpus is Clack's: https://github.com/fukamachi/clack, path
  `src/test/suite.lisp` (22047 bytes per `gh api
  repos/fukamachi/clack/contents/src/test`; MIT per `gh api` license; pushed
  2026-02-10).
- Case count (`dl/clack/suite.lisp`): 556 lines, 4 `deftest`
  (`response-tests`, `env-tests`, `request-tests`, `debug-tests`), 36
  `testing-app` scenarios, 86 `ok`/`is` assertions.
- Scenario names (verbatim from `rg -n testing suite.lisp`):

  ```
  "list", "pathname (plain/text)", "pathname (binary)", "bigger file",
  "multi headers (response)", "no entity headers on 304", "CRLF output",
  "test 404", "Content-Length 0 is not set Transfer-Encoding",
  "SCRIPT-NAME", "url-scheme", "handle HTTP-Header", "validate env",
  "validate env (must be integer)", "% encoding in PATH-INFO",
  "% double encoding in PATH-INFO",
  "% encoding in PATH-INFO (outside of URI characters)",
  "Invalid UTF-8 encoded PATH-INFO", "SERVER-PROTOCOL is required",
  "SCRIPT-NAME should not be nil", "Do not set COOKIE", "REQUEST-URI is set",
  "GET", "POST", "big POST", "big POST (chunked)", "multi headers (request)",
  "a big header value > 128 bytes", "request -> input seekable",
  "handle Authorization header", "repeated slashes", "file upload",
  "large file upload", "streaming", "Do not crash when the app dies"
  ```

- How it runs (`suite.lisp` lines 27-38): `run-server-tests` binds
  `*clack-test-handler*` and runs the rove suite; each `testing-app` starts
  the named backend on a port and drives it with the dexador client.

### Adaptability

- (b): a black-box conformance list for an event-loop server written by the
  author of the libev server most like ours. Scenarios are one-liners to
  re-express against our port with any HTTP client (curl or our own
  chez-libuv client). "no entity headers on 304", "Content-Length 0 is not
  set Transfer-Encoding", "CRLF output", "big POST (chunked)", "a big header
  value > 128 bytes", "Do not crash when the app dies" and "streaming" are
  the first to port.
- Effort: medium (the assertions are Lisp code, not data; transcribe into a
  scenario table).
- Woo's architecture notes for the async-model: single-threaded libev loop
  per worker, multiple worker processes, fast-http callback parser; the
  Clack app contract `(lambda (env) (list status headers body))` with a
  `(lambda (responder) ...)` body for streaming.

---

## 4. GNU Guile `test-suite/tests/web-*.test` (Tier 2)

- URL: https://cgit.git.savannah.gnu.org/cgit/guile.git/tree/test-suite/tests
  (raw files at `.../plain/test-suite/tests/<name>.test`; the older
  `git.savannah.gnu.org/cgit/...` URL 301-redirects there). Fossies mirror
  refused WebFetch and curl (HTML shell).
- License: file headers (verbatim from `dl/guile/web-server.test` lines 3-8):

  ```
  ;;;; 	Copyright (C) 2019-2020, 2022, 2023 Free Software Foundation, Inc.
  ;;;; This library is free software; you can redistribute it and/or
  ;;;; modify it under the terms of the GNU Lesser General Public
  ;;;; License as published by the Free Software Foundation; either
  ;;;; version 3 of the License, or (at your option) any later version.
  ```

  SPDX `LGPL-3.0-or-later`. Vendoring test data into a BSD-3 repo is
  license-compatible only if the vendored files keep their LGPL notice;
  transcribing the *cases* (inputs/expected values) into our own tests is
  the cleaner route.
- Corpus paths and measured counts (`curl` from Savannah cgit;
  `rg -c pass-if`):

  ```
  test-suite/tests/web-server.test    5183 bytes   7 pass-if
  test-suite/tests/web-http.test     22754 bytes 158 pass-if
  test-suite/tests/web-request.test   3336 bytes   8 pass-if
  test-suite/tests/web-response.test  5467 bytes  14 pass-if
  ```

  (`web-uri.test` and `web-client.test` exist per the Fossies listing in
  the search result but timed out during download; not counted.)

### What it covers

`web-http.test` (`dl/guile/web-http.test`): helper macros
`pass-if-parse`, `pass-if-round-trip`, `pass-if-any-error`,
`pass-if-parse-error`, `pass-if-read-request-line`,
`pass-if-write-request-line`, `pass-if-read-response-line`,
`pass-if-write-response-line` (lines 31-151); prefixes `read-request-line`,
`write-request-line`, `read-response-line`, `write-response-line`,
`general headers`, `entity headers`, `chunked encoding` (line 431). Sample
cases:

```scheme
  (pass-if-read-request-line "GET / HTTP/1.1"
  (pass-if-read-request-line "GET http://www.w3.org/pub/WWW/TheProject.html HTTP/1.1"
  (pass-if-read-request-line "HEAD /etc/hosts?foo=bar HTTP/1.1"
  (pass-if-read-response-line "HTTP/1.1 302 "
  (pass-if-parse content-length "010" 10)
  (pass-if-parse transfer-encoding "foo, chunked" '((foo) (chunked)))
  (pass-if-parse-error date "Tue, 15 Nov 1994 08:12:31 EST" date)
  (pass-if (port-eof? (make-chunked-input-port (open-input-string "0\r\n"))))
        ;; Make sure the chunked input port does not read more than what
  ...
      chunked-input-ended-prematurely-error?
```

`web-request.test`: one realistic browser request (`example-1`, lines
27-35) parsed with `read-request` from a string port and round-tripped with
`write-request`; asserts typed header values. `web-response.test`: two
examples including a chunked response (`'((chunked))` at line 137) with
`response-body-port` semantics.

`web-server.test` (full text in `dl/guile/web-server.test`): starts
`run-server` on fixed port 8885 in a thread, then `GET /`, `GET /latin1`,
`GET /user-agent`, `GET /does-not-exist` (404), `GET with keep-alive` (three
requests on one socket), `POST /` (403). Skipped when threads are absent.

### Adaptability

- (c): the request-line/response-line and chunked-input-port cases are
  small, data-like and transcribe cheaply; most of `web-http.test` is typed
  header-value parsing (Cache-Control, Date, Accept, Content-Range ...) which
  is above our connection layer.
- (b)/(a): `web-server.test` is a 7-case smoke pattern; the keep-alive
  three-in-a-row case is the one worth copying.
- Effort: low for the ~30 relevant cases; skip the typed-header part.

---

## 5. CHICKEN intarweb `tests/run.scm` (Tier 2)

- URL: https://code.more-magic.net/intarweb (cgit; raw at
  `https://code.more-magic.net/intarweb/plain/tests/run.scm`). The wiki page
  http://wiki.call-cc.org/eggref/5/intarweb states the repository URL
  verbatim as "https://code.more-magic.net/intarweb". The svn URL
  `code.call-cc.org/svn/chicken-eggs/release/5/intarweb/` returned 404 even
  with the anonymous login, so svn is not where this egg lives.
- License: `intarweb.egg` (`dl/chicken/intarweb.egg`) `(license "BSD")`;
  the wiki page reproduces the 2-clause BSD text ("Copyright (c) 2008-2024,
  Peter Bex. All rights reserved."). Latest version 2.1.0 per the wiki.
- Corpus path: `tests/run.scm` (1277 lines; 441 `test`/`test-error`/
  `test-assert` forms measured with `rg -c`).
- Coverage (test-group names, `dl/chicken/intarweb-run.scm`): `headers`
  (single, multi, miscellaneous), `specialized header parsers` (host/port,
  quality, charset, cache-control, authorization basic/digest/custom,
  authenticate, pragma, base64, range, content-disposition, normalized-uri,
  etag, if-match, http-date, If-Range, via, product, software, Set-Cookie,
  cookie, strict-transport-security), `unparsers` (...). Request parsing
  from string ports at lines 870-943:

  ```scheme
  (define (test-read-request str)
    (call-with-input-string str read-request))
      (test-error* (exn http unknown-protocol-line) (test-read-request "qux"))
      (test "Method is case-insensitive" 'GET (request-method (test-read-request "geT /path\r\n")))
      (test-error "0.9 only knows GET" (test-read-request "PUT /path"))))
    (test-group "HTTP/1.0"
      (test-error "Asterisk is not allowed for HTTP/1.0"
                  (request-uri (test-read-request "OPTIONS * HTTP/1.0\r\n")))
      (let ((req (test-read-request "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nfoo\r\na\r\n1234567890\r\n")))
    (test-group "HTTP/1.1" ; No need to test all things we test for 1.0
     (test "Method is case-sensitive" 'geT (request-method (test-read-request "geT /path HTTP/1.1\r\n\r\n")))
     (test "Protocol is case-insensitive" '1 (request-minor (test-read-request "GET /path htTP/1.1\r\n\r\n")))
                      "GET / HTTP/1.1\r\nContent-Length: 15\r\n\r\nabc=def;ghi=jkl")))
  ```

  `http-header-limit` (line 6 and line 80) is a header-count limit
  parameter exercised by the tests.
- Adaptability: (c) — the request-line/version/chunked cases (~40 forms)
  are string literals with expected values and transcribe directly; note
  intarweb accepts HTTP/0.9 and case-insensitive `htTP/1.1`, which llhttp
  (and therefore chez-httparse) rejects, so expected values must be
  re-derived against llhttp, not copied. Header-parser groups are above our
  layer. Effort: low-medium.

---

## 6. http-kit `test/org/httpkit/server_test.clj` (Tier 2)

- URL: https://github.com/http-kit/http-kit (Apache-2.0 per `gh api`;
  `LICENSE.txt` at root; pushed 2026-08-21).
- Corpus paths (`gh api repos/http-kit/http-kit/contents/test/org/httpkit`):

  ```
  file test/org/httpkit/client_protocol_test.clj 28964
  file test/org/httpkit/client_test.clj 47605
  file test/org/httpkit/server_test.clj 29669
  file test/org/httpkit/test_util.clj 1647
  file test/org/httpkit/ws_test.clj 20937
  file test/org/httpkit/num_connections.clj 1595
  ```
- Case count: 41 `deftest` in `server_test.clj` (`rg -c '^\(deftest'`).
  Names (verbatim):

  ```
  test-ring-spec test-legacy-unsafe-remote-addr-option
  test-duplicate-request-headers test-body-string test-many-headers
  test-body-file test-other-body-file test-body-inputstream
  test-body-bytearray test-wrong-content-length
  test-respect-user-content-length test-body-iseq test-body-null
  ipv6-host-header ipv6-host-header-with-port rejects-blank-host-header
  test-host-header-port-validity test-timer test-async test-async-just-body
  test-streaming-body test-client-abort-server-receive-on-close
  test-multipart test-uri-len test-client-sent-one-byte-a-time
  test-decoding-100cpu test-http10-keepalive test-chunked-encoding
  test-get-local-port test-application-gets-to-set-date
  test-immediate-stop-kills-inflight-requests
  test-graceful-stop-kills-long-inflight-requests
  test-graceful-stop-responds-to-inflight-requests
  test-use-external-thread-pool test-server-status test-server-header
  test-channel-reuse-async custom-providers test-ring-async-handlers
  can-join-server
  ```
- Handler shape (verbatim, `dl/httpkit/server_test.clj` lines 52-58, 69-76):

  ```clojure
  (defn async-handler [req]
    (as-channel req {:on-open
                     #(send! % {:status 200 :body "hello async"})}))
  ...
                     (send! channel (first seqs) false)
  ...
                     (send! channel "" true))} ;; same as (close channel)
  ```
- Adaptability: (b) — the byte-at-a-time client (`SpecialHttpClient/slowGet`
  in a Java helper, lines 461-466), HTTP/1.0 keep-alive, wrong
  Content-Length, duplicate headers, blank Host rejection, and the three
  stop/shutdown-with-in-flight-request cases are the scenarios to copy;
  everything else is Ring-specific. Assertions are Clojure code, so this is
  a scenario list to re-implement, not data to vendor. Effort: medium.

---

## 7. fast-http `t/parser.lisp` and `t/fast-http.lisp` (Tier 2)

- URL: https://github.com/fukamachi/fast-http (MIT: `fast-http.asd` line 17
  `:license "MIT"`; `gh api` returned no SPDX id and no LICENSE file at the
  root, so the asd declaration is the only license statement found; pushed
  2026-04-06).
- Corpus paths (`gh api repos/fukamachi/fast-http/contents/t`):

  ```
  file t/benchmark.lisp 2218
  file t/body-buffer.lisp 1349
  file t/fast-http.lisp 28551
  file t/multipart-parser.lisp 20501
  file t/parser.lisp 55718
  file t/test-utils.lisp 839
  file t/util.lisp 853
  ```
- Case counts: `t/parser.lisp` 1563 lines, 7 subtests, 96
  `is`/`ok`/`test-parser` forms; `t/fast-http.lisp` 692 lines, 6 subtests,
  62 assertions. Subtest names (verbatim):

  ```
  parser.lisp:   "HTTP methods" "HTTP bad methods"
                 "Transfer-Encoding trailing OWS"
                 "Duplicate Transfer-Encoding rejection"
                 "Conflicting Content-Length and Transfer-Encoding rejection"
                 "Response allows both Transfer-Encoding and Content-Length"
                 "Transfer-Encoding reset between messages"
  fast-http.lisp: "headers" "chunk body" "chunk body"
                 "streaming chunk-size security limits"
                 "Parser poisoning after parsing-error"
  ```
- Adaptability: (c). This is the parser Woo runs on; its cases were derived
  from http-parser's test.c, so most overlap the llhttp corpus we already
  replay. The distinct value is the security-flavoured subtests
  (duplicate/conflicting TE and CL, chunk-size limits, "parser poisoning
  after parsing-error", "Transfer-Encoding reset between messages") which
  double as connection-layer expectations: after an error the connection
  must refuse further input, matching the measured chez-httparse behaviour
  (data-after-close yields `'error`). Effort: low (a dozen cases).

---

## 8. Aleph `test/aleph/http_test.clj` (Tier 3)

- URL: https://github.com/clj-commons/aleph (MIT per `gh api`; `LICENSE.md`
  at root; pushed 2026-08-24).
- Corpus paths: `test/aleph/http_test.clj` 81945 bytes (56 `deftest`),
  `test/aleph/http_continue_test.clj` 4233, `test/aleph/http_timeout_test.clj`
  3653, `test/aleph/resource_leak_detector.clj` 8508, and `test/aleph/http/`
  (`client_middleware_test.clj` 13762, `client_test.clj` 3362,
  `common_test.clj` 1225, `compression_test.clj` 1197, `core_test.clj` 883,
  `http2_test.clj` 7691, `multipart_test.clj` 15749).
- Verbatim cases of interest (`dl/aleph/http_test.clj` lines 612-629, 712):

  ```clojure
  (deftest test-overly-long-url
    (let [long-url (apply str "/" (repeat (long 1e5) "a"))]
      (with-http1-server basic-handler http-server-options
        (is (= 414 (:status @(http-get long-url)))))))

  (deftest test-overly-long-header
    ...
        (is (= 431 (:status @(http-get url opts)))))))

  (deftest test-invalid-http-version-format
    (with-http1-server basic-handler http-server-options
      (let [client @(tcp/client {:host "localhost" :port port})
            _ @(s/put! client "GET / HTTP-1,1\r\n\r\n")
            response (bs/to-string @(s/take! client))]
        (is (str/starts-with? response "HTTP/1.1 400"))
        (s/close! client))))
  ```

  Other names: `test-idle-timeout`, `test-max-request-body-size`,
  `test-in-flight-request-cancellation`, `test-pipeline-transforms`,
  `test-http-object-aggregator-support`, `http2-only-client-connecting-to-http1-only-server`,
  `test-listen-socket`, `^:leak` (resource leak detector).
- Adaptability: (b) — three or four status-code expectations (414, 431, 400
  on bad version, idle timeout, max body size) worth adding to our external
  black-box list; the rest is Netty/HTTP2/SSL-specific. Effort: low for the
  handful; reference otherwise.

---

## 9. CHICKEN spiffy `tests/` (Tier 3)

- URL: https://code.more-magic.net/spiffy (cgit; wiki
  http://wiki.call-cc.org/eggref/5/spiffy gives the repository as
  "https://code.more-magic.net/spiffy"). Files: `tests/run.scm`,
  `tests/testlib.scm`, `tests/testweb/` (from
  `curl https://code.more-magic.net/spiffy/tree/tests`).
- License: `spiffy.egg` `(license "BSD")` ("Copyright (c) 2005-2024, Felix
  L. Winkelmann and Peter Bex" per the wiki).
- Case count: `tests/run.scm` 287 lines, 85 test forms; `testlib.scm` 120
  lines.
- Harness (verbatim, `dl/chicken/spiffy-testlib.scm` lines 10-11, 47-52):

  ```scheme
  (server-port (string->number
                 (or (get-environment-variable "SPIFFY_TEST_PORT") "8080")))
  ...
  (define (start-spiffy)
    (check-port)
    (set! spiffy-pid
          (process-fork
           (lambda ()
             (parameterize ((root-path "./testweb")
  ```

  The server is forked into a child process and driven through intarweb's
  client over TCP; cases send `host ("testhost" . port)` headers for vhost
  tests (`run.scm` lines 237-262) and serve a `testweb/` static tree with a
  `subdir` root-path variant (line 53).
- Adaptability: (b) only, and mostly static-file/vhost behaviour that is a
  later milestone for us. Reference for the "fork the server, poll until it
  accepts, run client cases" pattern. Effort: not worth it now.

---

## 10. Gerbil `std/net/httpd` tests (Tier 3)

- URL: https://github.com/mighty-gerbils/gerbil (pushed 2026-07-22).
- License: root has both `LICENSE-APACHE-2.0.txt` and `LICENSE-LGPL.txt`
  (`gh api` root listing); `gh api` auto-detects `LGPL-2.1`; fetched
  `LICENSE-LGPL.txt` begins "GNU LESSER GENERAL PUBLIC LICENSE Version 2.1,
  February 1999". Treat as dual `LGPL-2.1 OR Apache-2.0`.
- Corpus paths (`gh api repos/mighty-gerbils/gerbil/contents/src/std/net`
  and code search):

  ```
  src/std/net/httpd-test.ss      3822 bytes   (2 test-case, ~14 check)
  src/tools/gxhttpd-test.ss                   (5 test-case: "/", "/index.html",
                                              "/handler", "/servlets/hello.ss",
                                              "/does-not-exist")
  src/tools/gxhttpd-ensemble-test.ss
  src/std/net/httpd/{api,base,control,file,handler,logger,mux,server}.ss
  ```

  No test file exists inside `src/std/net/httpd/` itself.
- `httpd-test.ss` (verbatim excerpts, `dl/gerbil/httpd-test.ss`):

  ```scheme
  (def server-address
    "127.0.0.1:19999")
  (def (write-chunked-handler req res)
    (http-response-begin res 200 '(("Content-Type" . "text/plain")))
    (http-response-chunk res "hello ")
    (http-response-chunk res "there!")
    (http-response-end res))
  ...
      (def httpd
        (start-http-server! server-address mux: (make-recursive-http-mux)))
  ...
        ;; large data blob (bigger than server buffer)
        (let* ((data (random-u8vector 16384))
               (req (http-post (string-append server-url "/echo")
                               data: data)))
  ```
- Reference value is the API surface (`dl/gerbil/api.ss`): `start-http-server!`,
  `http-register-handler`, `http-response-write`,
  `http-response-begin/chunk/end`, `http-response-file`,
  `http-response-upgrade!`, `http-request-timeout-set!`,
  `set-httpd-max-request-headers!`, `set-httpd-max-token-length!`,
  `set-httpd-max-request-body-length!`, `set-httpd-input-buffer-size!`,
  `set-httpd-output-buffer-size!`; defaults in `handler.ss` lines 323-327:

  ```scheme
  (def request-timeout 60)
  (def response-timeout 120)
  (def max-request-headers 256)
  (def max-token-length 1024)
  (def max-request-body-length (expt 2 20)) ; 1MB
  ```

  and `read-request-headers` raising `"too many headers"` (line 413).
- Adaptability: (a)/(b) smoke only (7 cases on a fixed port 19999); tier 3.
  The limits/timeouts list is a good checklist for our `limits.sls`.

---

## 11. Hunchentoot `test/` confidence script (Tier 3)

- URL: https://github.com/edicl/hunchentoot (pushed 2026-05-04).
- License: `hunchentoot.asd` line 36 `:license "BSD-2-Clause"`; file
  headers "Copyright (c) 2004-2010, Dr. Edmund Weitz. All rights reserved."
  with the 2-clause text; README line 28-29 "Hunchentoot comes with a
  BSD-style license".
- Corpus paths (`gh api repos/edicl/hunchentoot/contents/test`):

  ```
  file test/packages.lisp 1638
  file test/script-engine.lisp 7739
  file test/script.lisp 11361
  file test/test-handlers.lisp 23576
  (+ UTF-8-demo.html, fz.jpg, favicon.ico, certificates/keys)
  ```
- Case count: `script.lisp` `test-hunchentoot` is one linear script of ~25
  `http-request` steps (26 matches for `http-request|with-script`), each
  followed by `http-assert`/`http-assert-header`/`http-assert-body`; plus
  `test-acceptor-wake` (lines 40-73) which checks that an acceptor blocked in
  accept can be woken for shutdown on a random free port (`:port 0`).
- Coverage (from `dl/hunchentoot/script.lisp` lines 86-234): home page,
  cookies, session variables, "malformed session cookie validation"
  (`"" "invalid-session-id" ":invalid-session-id" "invalid:session-id"`),
  Latin-1 and UTF-8 parameters via GET and POST, redirect, basic
  authorization, binary image from file and from RAM, file upload and
  re-download, Range requests (`:range '(0 0)`, full range, partial range
  with `Content-Range` assertion), regex-group handlers.
- Handler API: `define-easy-handler (easy-demo :uri "/hunchentoot/test/easy-demo.html" ...)`
  (`test-handlers.lisp` line 373), streaming via `send-headers`
  (`stream-direct` handlers, lines 342-361); one thread per connection.
- Adaptability: (b) — a script-engine style (request, then assert status /
  header regex / body regex) is a compact black-box format we could imitate
  with curl; the cases themselves are application-level (sessions, cookies,
  uploads). Range-request assertions are the only transport-adjacent ones.
  Reference only.

---

## 12. Local abandoned attempt: protium (Tier 3, reference-impl)

- Path: `/Users/yuzu/github/protium` (BSD-3-Clause: `LICENSE` "BSD 3-Clause
  License / Copyright (c) 2026, Kiyomi Computation Systems LLC").
- HTTP test material: none. `find tests -type f` shows `tests/integration/.gitkeep`
  and `tests/lifetime/.gitkeep` only; the populated dirs are harness
  self-tests, native shim tests, portability fixtures and CMake specs.
  `rg -il http` over the tree (excluding build/vendor/.akku) matched only
  plan documents, `CHANGELOG.md`, `CMakeLists.txt`, `Akku.lock`, and
  `tests/support/cmake/ProtiumLibuvSpec.cmake` (libuv tarball URLs).
- `docs/plans/chez-http-server-architecture.md` is the same document as
  `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md`;
  `diff` shows only a 4-line status banner and one whitespace line differ:

  ```
  2,5d1
  < 
  < > Status: Background design writeup for the downstream web-server project. The
  < > [Protium project plan](protium-project-plan.md) is authoritative for the
  < > libuv-binding scope, decisions, sequencing, and release criteria.
  698c694
  ```

- Lessons worth carrying (file:line):
  - `docs/plans/protium-project-plan.md:91-109` §2.4 defines the downstream
    HTTP acceptance checkpoint: "accept a loopback HTTP/1 request, exercise
    read pause/resume, send a vectored response, gracefully shut down, and
    explicitly close using only the supported Protium API". Note chez-libuv
    has no vectored write (`uv-write*!` is reserved), so that checkpoint
    must be rewritten for the real binding.
  - `docs/plans/protium-project-plan.md:1033-1045` §14: "Protium exposes the
    native queued-write byte count but does not choose an HTTP server's
    high- and low-water marks. The downstream consumer pauses reads and
    resumes them according to its own policy." — consistent with chez-libuv
    ADR-0018 (no bounded write queue in the binding).
  - `docs/plans/protium-test-harness.md:24-52` harness decisions: fresh
    process per test group; "Every asynchronous test has two time bounds:
    an inner monotonic deadline that can report Protium state and an outer
    CTest timeout"; deterministic seeds with operation transcripts; no
    retry-until-pass; "Protium-owned network tests use loopback and port
    `0`".
  - `docs/plans/protium-test-harness.md:69-71` goals: "detect missing,
    duplicate, late, reordered, and post-close callbacks" — the property
    list a libuv-backed connection layer should assert.
  - `docs/plans/decisions/0003-loop-owner-thread-model.md`: callback
    failures are contained at the dispatcher and by default close the
    handle — chez-libuv chose store-and-reraise instead, so our server must
    guard every handler invocation itself.
  - `docs/plans/decisions/0004-buffer-ownership-and-copying.md`: copy at
    both boundaries, "Peak native memory also includes all pending write
    snapshots, so backpressure and pending-byte limits remain important."
  - `AGENTS.md` verification rules ("Prove a check by what it refuses",
    "mutate the thing it watches and confirm it goes red") match our house
    mutation discipline.
  - `docs/plans/chez-gambit-libuv-portability.md:498-505` wanted the HTTP
    suite to run unchanged on Chez and Gambit; moot now (Gambit dropped),
    but it argues for keeping the (c) driver free of libuv imports.

---

## 13. Surveyed, not recommended as corpora

### Gambit `examples/web-server/`

- URL: https://github.com/gambit/gambit/tree/master/examples/web-server
  (`gh api` listing: `README` 1242, `base64.scm`, `html.scm` 36909,
  `http.scm` 35662, `web-server.scm` 12017, `makefile.in`). No tests.
- License: root has `LICENSE-2.0.txt` (11358 bytes, Apache 2.0); Gambit is
  documented as dual LGPL-2.1/Apache-2.0 (the LGPL file was not fetched).
- Thread model (verbatim, `dl/gambit/http.scm` lines 763-776):

  ```scheme
  (define accept-connections
    (lambda (hs server-port)
      (let loop ()
        (let ((connection
               (read server-port)))
          (if (server-threaded? hs)
              (let ((dummy-port (open-dummy)))
                (parameterize ((current-input-port dummy-port)
                               (current-output-port dummy-port))
                  (thread-start!
                   (make-thread
                    (lambda ()
                      (serve-connection hs connection))))))
              (serve-connection hs connection)))
        (loop))))
  ```

  Handlers are method-table thunks (`GET: GET/POST`) that read
  `(current-request)`; the README describes serialised web-continuations
  in hidden form fields. Reference for continuation-based handler shape
  only.

### Loko `samples/web-server/`

- URL: https://gitlab.com/weinholt/loko (GitLab API
  `projects/weinholt%2Floko?license=true` → `eupl-1.2 European Union Public
  License 1.2`, last activity 2026-07-17). Tree
  `samples/web-server/{.gitignore,Akku.lock,Akku.manifest,Makefile,README.md,web-server.sps}`.
  No `http` library and no tests (GitLab blob search returned 401 for
  anonymous; the samples tree listing was authoritative).
- `web-server.sps` header: `;; SPDX-License-Identifier: EUPL-1.2+`; it
  imports `(loko system fibers)` and `(srfi :106 socket)`, accepts in a
  loop and `spawn-fiber`s a handler that does `get-bytevector-some` once and
  writes a fixed `HTTP/1.1 200 OK` with `Connection: close`. Fiber-based
  handler shape is the only takeaway; EUPL is copyleft and should not be
  vendored into a BSD-3 repository.

### Guile `(web server)` implementation shape (for the async-model table)

`module/web/server/http.scm` fetched from Savannah cgit
(`dl/guile/server-http.cgit.scm`, 183 lines, LGPL-3.0-or-later): uses
`(ice-9 poll)`; `http-read` (lines 79-140) polls a set containing the
listener and all client ports, accepts new clients into the set, and reads
one request synchronously from a ready client; `http-write` re-adds the
client to the poll set when `keep-alive?` (lines 153-165);
`define-server-impl http http-open http-read http-write http-close` at
lines 178-182. Single-threaded, request-at-a-time; concurrency comes from
guile-fibers' separate impl.

---

## 14. Commands and outputs relied on (chronological)

1. `gh auth status` → "Logged in to github.com account DarrenN".
2. `gh api repos/racket/web-server/contents/web-server-test/tests/web-server --jq '.[] | "\(.type) \(.path) \(.size)"'` and the same for `http`, `private`, `private/fixtures`, `dispatchers`, `e2e`, `e2e/echo`, `e2e/max-concurrent`, `stress`, `servlet`, `managers`, `pr` (listings reproduced in §1).
3. `gh api repos/racket/web-server --jq '.license.spdx_id, .default_branch, .pushed_at'` → `NOASSERTION / master / 2026-08-11T02:10:23Z`; `curl raw.githubusercontent.com/racket/web-server/master/LICENSE` (text in §1).
4. `curl` of `private/request-test.rkt`, `private/response-test.rkt`, `private/connection-manager-test.rkt`, `util.rkt`, `serve-tests.rkt`, `e2e/README.md`, `e2e/all-e2e-tests.rkt`; counts via `wc -l` and `rg -c` (§1).
5. `gh api repos/ashinn/chibi-scheme/pulls/1199/files --jq ...` and `.../pulls/1199 --jq '.title, .merged_at, .html_url'` (§2); `curl .../master/tests/net-tests.scm`, `.../lib/chibi/net/http-server.scm`, `.../server.scm`, `.../COPYING`.
6. `gh api repos/fukamachi/woo/contents/t`, `gh api repos/fukamachi/woo --jq '.license.spdx_id'` → `MIT`; `curl .../woo/master/t/woo.lisp`, `woo-test.asd`, `woo.asd`; `gh api repos/fukamachi/clack/contents/src/test` and license → `MIT`; `curl .../clack/master/src/test/suite.lisp`; `rg -c testing` → 36, `rg -c '^\s*\((ok|is)\b'` → 86 (§3).
7. `curl https://cgit.git.savannah.gnu.org/cgit/guile.git/plain/test-suite/tests/{web-server,web-http,web-request,web-response}.test` (ran to completion in background task b1p7b9nd3); `rg -c pass-if` → 7 / 158 / 8 / 14; `curl .../plain/module/web/server/http.scm` (§4, §13).
8. WebFetch `http://wiki.call-cc.org/eggref/5/intarweb` and `/spiffy` (repository URLs, license text, SPIFFY_TEST_PORT); `curl https://code.more-magic.net/{intarweb,spiffy}/plain/tests/run.scm`, `.../plain/{intarweb,spiffy}.egg`, `.../tree/tests` (§5, §9). Earlier attempts: WebFetch of `code.call-cc.org/svn/...` → 401; curl with `-u anonymous:` → 404.
9. `gh api repos/http-kit/http-kit/contents/test/org/httpkit`, license → `Apache-2.0`, root listing → `LICENSE.txt`; `curl .../server_test.clj`, `test_util.clj`; `rg -c '^\(deftest'` → 41 (§6).
10. `gh api repos/fukamachi/fast-http/contents/t`; `curl .../t/parser.lisp`, `t/fast-http.lisp`, `fast-http.asd` (`:license "MIT"` at line 17); counts (§7).
11. `gh api repos/clj-commons/aleph/contents/test/aleph` and `/test/aleph/http`, license → `MIT`, root → `LICENSE.md`; `curl .../http_test.clj`; `rg -c '^\(deftest'` → 56 (§8).
12. `gh api repos/mighty-gerbils/gerbil/contents/src/std/net` and `/src/std/net/httpd`; code search `repo:mighty-gerbils/gerbil httpd filename:test`; `curl` of `httpd-test.ss`, `gxhttpd-test.ss`, `httpd/api.ss`, `httpd/server.ss`, `httpd/handler.ss`, `LICENSE-LGPL.txt` (§10).
13. `gh api repos/edicl/hunchentoot/contents/test`; `curl` of `test/script.lisp`, `test/test-handlers.lisp`, `test/script-engine.lisp`, `hunchentoot.asd`, `README.md` (§11).
14. `gh api repos/gambit/gambit/contents/examples/web-server`; `curl` of `web-server.scm`, `http.scm`, `README`; `gh api repos/gambit/gambit/contents/LICENSE-2.0.txt --jq '.name, .size'` → `LICENSE-2.0.txt / 11358` (§13).
15. `curl "https://gitlab.com/api/v4/projects/weinholt%2Floko/repository/tree?path=samples"` and `?path=samples/web-server`; `.../projects/weinholt%2Floko?license=true`; raw `samples/web-server/web-server.sps` (§13).
16. Local: `ls`, `find`, `rg -il http`, `diff` and `sed -n` over `/Users/yuzu/github/protium` (§12).

## 15. Recommendation for the first milestones

1. Vendor now (Tier 1): the 37 Racket request fixtures with a transcribed
   expectation manifest (feeds the (c) driver from day one, and its
   safety-limit cases define `limits.sls`), and Chibi's `net-tests.scm`
   scenario list (feeds the (a) loopback suite: teardown, half-close,
   unread bodies, 400/500 paths, idle-peer cleanup).
2. Adapt later (Tier 2): Clack's 36 black-box scenarios and http-kit's
   shutdown/in-flight and slow-client cases for (b); Guile's request-line
   and chunked-port cases and intarweb's request-line/version cases for
   (c), re-deriving expectations against llhttp where they disagree;
   fast-http's TE/CL conflict and post-error poisoning cases as
   connection-layer expectations.
3. Reference only (Tier 3): Aleph's 414/431/400 expectations, Gerbil's
   limit defaults, Hunchentoot's script format, spiffy's fork-and-poll
   harness, and protium's harness rules (two time bounds per async test,
   port 0, fresh process per group, no retry-until-pass).
