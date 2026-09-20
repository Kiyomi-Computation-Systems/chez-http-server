# Reference server deep-read: Racket `web-server` (racket/web-server)

Chosen implementation: **Racket web-server** (`web-server-lib` + `web-server-test`), repo
https://github.com/racket/web-server, `master` at commit
**`080d2ea7dfc8b8e9a147f2d3155970098eac69b0`** (Matthew Flatt, 2026-06-28T13:39:42Z; fetched
2026-09-19). License: MIT/Apache-2.0 dual (Racket's standard package license; see
`fetched/racket/LICENSE`, 10 lines — SPDX-style dual license header, University of Utah /
PLT copyright).

I picked Racket over Guile/Chicken-spiffy/CL-woo because the computed task itself supplied the
most specific, checkable file list for Racket (`dispatch-server-unit.rkt`,
`connection-manager.rkt`, `timer.rkt`, `http/request.rkt`), and because on inspection this one
codebase directly answers essentially every question the task asks (keep-alive rule, chunked
body streaming both directions with explicit backpressure, a fully enumerated safety-limits
table with defaults, timers, graceful shutdown, HEAD/range handling, and a large e2e test
suite). I did **not** deep-read Guile/spiffy/woo for this report — only Racket. (Partial cached
fragments for those three exist under `scratchpad/research/fetched/{guile,chicken,woo}/` from
earlier, unrelated work in this shared scratchpad; I did not use them and make no claims about
them here.)

All source shown below was fetched with `curl` from `raw.githubusercontent.com` (raw text, not
summarized) or was already present in the scratchpad from an earlier fetch of the same repo/
commit family; every quoted block below is copied verbatim from the fetched file, and every
claim is tied to a `file:line` citation against that fetched copy. Local cache paths are under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/fetched/racket/`.

Commit-verification command and output:

```
$ curl -s "https://api.github.com/repos/racket/web-server/commits/master" | head -c 2000
{
  "sha": "080d2ea7dfc8b8e9a147f2d3155970098eac69b0",
  ...
  "commit": {
    "author": { "name": "Matthew Flatt", ... "date": "2026-06-28T13:39:42Z" },
    "message": "Revert \"adapt test to current net-cookies-lib\"\n\n...",
    ...
  },
  "html_url": "https://github.com/racket/web-server/commit/080d2ea7dfc8b8e9a147f2d3155970098eac69b0",
  ...
```

## Files fetched (path → raw URL → local cache)

| Repo path | Raw URL (at commit `080d2ea7`) | Local cache |
|---|---|---|
| `web-server-lib/web-server/private/connection-manager.rkt` | `.../racket/web-server/master/web-server-lib/web-server/private/connection-manager.rkt` | `fetched/racket/connection-manager.rkt` (pre-cached, verified against raw fetch below) |
| `web-server-lib/web-server/private/dispatch-server-with-connect-unit.rkt` | same tree | `fetched/racket/dispatch-server-with-connect-unit.rkt` |
| `web-server-lib/web-server/private/dispatch-server-unit.rkt` | same tree | `fetched/racket/dispatch-server-unit.rkt` |
| `web-server-lib/web-server/safety-limits.rkt` | same tree | `fetched/racket/safety-limits.rkt` |
| `web-server-lib/web-server/http/request.rkt` | same tree | `fetched/racket/request.rkt` |
| `web-server-lib/web-server/private/timer.rkt` | fetched this session | `fetched/racket/gh-private_timer.rkt` |
| `web-server-lib/web-server/http/response.rkt` | fetched this session | `fetched/racket/gh-http_response.rkt` |
| `web-server-lib/web-server/http/request-structs.rkt` | fetched this session | `fetched/racket/gh-http_request-structs.rkt` |
| `web-server-lib/web-server/http/response-structs.rkt` | fetched this session | `fetched/racket/gh-http_response-structs.rkt` |
| `web-server-lib/web-server/web-server-unit.rkt` | fetched this session | `fetched/racket/gh-web-server-unit.rkt` |
| `web-server-lib/web-server/private/raw-dispatch-server-connect-unit.rkt` | fetched this session | `fetched/racket/gh-private_raw-dispatch-server-connect-unit.rkt` |
| `web-server-lib/web-server/private/dispatch-server-sig.rkt` | fetched this session | `fetched/racket/gh-private_dispatch-server-sig.rkt` |
| `web-server-lib/web-server/private/util.rkt` | fetched this session | `fetched/racket/gh-private_util.rkt` |
| `web-server-lib/web-server/dispatchers/dispatch.rkt` | fetched this session | `fetched/racket/gh-dispatchers_dispatch.rkt` |
| `web-server-lib/web-server/private/web-server-structs.rkt` | fetched this session | `fetched/racket/gh-private_web-server-structs.rkt` |
| `web-server-lib/web-server/configuration/configuration-table-structs.rkt` | fetched this session | `fetched/racket/gh-configuration-table-structs.rkt` |
| `web-server-lib/web-server/dispatchers/dispatch-servlets.rkt` | fetched this session | `fetched/racket/gh-dispatch-servlets.rkt` |
| `web-server-test/tests/web-server/e2e/README.md` | fetched this session | `fetched/racket/e2e/e2e_README.md` |
| `web-server-test/tests/web-server/e2e/head/{tests,server}.rkt` | fetched this session | `fetched/racket/e2e/e2e_head_*.rkt` |
| `web-server-test/tests/web-server/e2e/graceful-shutdown/{tests,server}.rkt` | fetched this session | `fetched/racket/e2e/e2e_graceful-shutdown_*.rkt` |
| `web-server-test/tests/web-server/e2e/max-concurrent/{tests,server}.rkt` | fetched this session | `fetched/racket/e2e/e2e_max-concurrent_*.rkt` |
| `web-server-test/tests/web-server/e2e/read-write/tests.rkt` | fetched this session | `fetched/racket/e2e/e2e_read-write_tests.rkt` |
| `web-server-test/tests/web-server/serve-tests.rkt` | fetched this session | `fetched/racket/e2e/serve-tests.rkt` |
| `web-server-test/tests/web-server/private/{request,response,connection-manager}-test.rkt` | pre-cached | `fetched/racket/{request,response,connection-manager}-test.rkt` |

Repo tree enumeration command (used to find the e2e test layout and confirm no other file
references `responders-protocol`):

```
$ curl -s "https://api.github.com/repos/racket/web-server/git/trees/master?recursive=1" \
  | python3 -c "…filter for /tests/ paths…"
```
output included (abbreviated): `web-server-test/tests/web-server/e2e/{echo,file-upload,
graceful-shutdown,head,json,max-concurrent,read-write,tls}/{server,tests}.rkt`,
`web-server-test/tests/web-server/private/{request,response,connection-manager,gzip,
mime-types,mod-map,url-param,util,cache-table}-test.rkt`, `web-server-test/tests/web-server/
serve-tests.rkt`, `web-server-test/tests/web-server/signatures-test.rkt`, plus fixture files
under `web-server-test/tests/web-server/private/fixtures/`.

---

## 1. Keep-alive decision rule

Function `close-connection?`, `web-server-lib/web-server/http/request.rkt:205-212`:

```scheme
(define (close-connection? headers major minor client-ip host-ip)
  (or (< major 1)
      (and (= major 1) (= minor 0))
      (match (headers-assq* #"Connection" headers)
        [(struct header (f v))
         (regexp-match? #rx#"[cC][lL][oO][sS][eE]" v)]
        [#f
         #f])))
```

Rule, exactly as coded: close if HTTP major < 1, **or** HTTP/1.0 (major=1, minor=0) with no
override, **or** the request has a `Connection` header whose value contains the substring
`close` (case-insensitively, via a char-class regex, not a full token parse). There is **no
symmetric check of "Connection: keep-alive" for HTTP/1.0**— an HTTP/1.0 request is always
closed regardless of a `Connection: keep-alive` header; the code only special-cases HTTP/1.1
defaulting to keep-alive. This is the entire policy: HTTP/1.1 defaults to persistent, HTTP/1.0
defaults to non-persistent, and `Connection: close` on either forces non-persistent.

Call site — `make-read-request`, `request.rkt:119-127`:
```scheme
(define close?
  (or connection-close?
      (close-connection? headers major minor
                         client-ip host-ip)))
(values request close?)
```
`connection-close?` here is a server-wide override flag baked in at `make-read-request` creation
time (`request.rkt:88`, `#:connection-close? [connection-close? #f]`), letting an embedder force
every response to close (used e.g. for HTTP/1.0-only front ends).

The close decision then round-trips through the connection loop and into the response writer:

`private/dispatch-server-with-connect-unit.rkt:170-178` (`handle-connection/cm`):
```scheme
(let connection-loop ()
  (define-values (req close?)
    (config:read-request conn config:port port-addresses))
  (reset-connection-timeout! conn config:response-timeout)
  (set-connection-close?! conn close?)
  (config:dispatch conn req)
  (if (connection-close? conn)
      (kill-connection! conn)
      (connection-loop)))
```
`config:read-request` is `http:make-read-request` bound in `web-server-unit.rkt:41-42`. So the
decision is made once per request (before the handler runs), stashed as a **mutable field on
the `connection` struct** (`close?` field, `private/connection-manager.rkt:44-45`), and after the
handler finishes: if `close?` is true the connection is torn down; otherwise the server loops
back to read the next pipelined request off the **same** ports.

The stored `close?` flag is also what drives the **response-side** `Connection: close` header
and whether chunked framing is even attempted — `http/response.rkt:45-63`:
```scheme
(define (output-response conn resp)
  (output-response/method conn resp #"GET"))

(define/ext (output-response/method conn resp meth)
  (cond
    [(or
      ;; If it is terminated, just continue
      (terminated-response? resp)
      ;; If it is HTTP/1.0, ditto
      (connection-close? conn)
      ;; Or, if it is a HEAD request
      (bytes-ci=? meth #"HEAD"))
     (output-response-head conn resp)
     (unless (bytes-ci=? meth #"HEAD")
       (output-response-body conn resp))]
    ;; Otherwise, use chunked encoding
    [else
     (output-response-head conn resp #t)
     (output-response-body/chunked conn resp)]))
```
and `output-response-head`, `response.rkt:109-129`, unconditionally writes `Connection: close`
when `(connection-close? conn)` is true (`add-missing-headers` clause
`[#"Connection" (and (connection-close? conn) #"close")]`, `response.rkt:122`) — note
**"close" is only ever written, never "keep-alive"**; HTTP/1.1 keep-alive is communicated by
omission, per spec.

**A close-delimited response (no Content-Length, no chunked) forces close implicitly**: a
`response` whose headers include neither `Content-Length` nor a non-`identity`
`Transfer-Encoding` is *not* "terminated" (`terminated-response?`, `response.rkt:146-152`,
quoted in §5 below) and will, unless it's a HEAD/HTTP-1.0/close case, be sent **chunked**
instead — i.e. Racket's writer actively avoids the classic "close-delimited" framing for normal
GET/POST responses by wrapping any response without a known length in `Transfer-Encoding:
chunked`. The *only* place a truly close-delimited (no length, no chunking) response can occur
is precisely the three cases enumerated in `output-response/method`'s first `cond` clause
(terminated already / `connection-close?` conn / HEAD) — i.e. Racket deliberately keeps
"unterminated body + keep-alive" out of the reachable state space rather than allowing it and
relying on TCP close to delimit the body.

## 2. Pipelining policy and response ordering

There is **no read-ahead / concurrent-pipeline queue**: `connection-loop` above is a strict
`read-request → dispatch (which writes the full response) → loop`. The server never has more
than one request "in flight" per connection; it will not start reading request N+1 until
request N's handler has returned and its response has been fully written
(`config:dispatch conn req` is a blocking call that ends only after `output-response`/
`output-response/method` has completed — see `response.rkt:154-159` `output-response-body`
calling `flush-output`, and `response.rkt:161-209` `output-response-body/chunked` which
`(thread-wait to-chunker-t)` before returning). Because of this strict serialize-per-connection
loop, response ordering is **trivially correct by construction** — there is no reordering
possible/needed, at the cost of no read-side pipelining depth: a client that pipelines several
requests back-to-back onto one connection is fine (bytes queue up in the OS receive buffer /
Racket's input port), but the server only ever parses and answers them one at a time,
in order, which is also the origin of the request-line/parse-error framing rule in §7.

There's no configurable "max pipelined requests" limit distinct from the general per-connection
timeouts — a misbehaving pipelining client is bounded only by `request-read-timeout` /
`response-timeout` per round and by the OS socket buffer.

## 3. Request bodies: streaming + backpressure

**Chunked decoding**, `complete-request`, `request.rkt:159-196`:
```scheme
(define (complete-request real-ip initial-headers max-headers max-header-length max-body-length)
  (match (headers-assq* #"Transfer-Encoding" initial-headers)
    [(struct header (f #"chunked"))
     (define max-remaining-headers
       (max 0 (- max-headers (length initial-headers))))
     (define-values (decoded-ip decode-op)
       (make-pipe))
     (define total-size
       (let loop ([total-size 0])
         (define size-line (read-http-line/limited real-ip #:limit max-header-length))
         (define size-in-bytes
           (match (regexp-split #rx";" size-line)
             [(cons size-in-hex _)
              (bytes->nonnegative-integer size-in-hex 16)]))
         (cond
           [(zero? size-in-bytes) total-size]
           [else
            (define new-size (+ total-size size-in-bytes))
            (when (> new-size max-body-length)
              (network-error 'complete-request "chunked content exceeds max body length"))
            (copy-bytes! size-in-bytes real-ip decode-op)
            (read-http-line/limited real-ip #:limit 2)
            (loop new-size)])))
     (define more-headers
       (list* (header #"Content-Length" (string->bytes/utf-8 (number->string total-size)))
              (read-headers* real-ip #:max-count max-remaining-headers #:max-length max-header-length)))
     (close-output-port decode-op)
     (values decoded-ip (append initial-headers more-headers))]
    [_
     (values real-ip initial-headers)]))
```
The whole chunked body is eagerly drained into an in-memory Racket pipe (`make-pipe`) **before**
`complete-request` returns; the caller (a servlet reading bindings, or a raw handler reading the
body) sees an already-fully-received body accessible as an ordinary input port. The size guard
(`max-body-length`) is enforced chunk-by-chunk as bytes are copied, so a client can't exceed it,
but this is not a lazily-pulled stream to the *application* — it's fully materialized before the
request handler is invoked (bounded by `max-request-body-length`, default 1 MiB — see §5 table).
Body reads for the non-chunked case go through `read-bytes/lazy` (`request.rkt:283-306`), which
polls with `peek-bytes-avail!` until the full declared `Content-Length` is available, again
fully materializing the body (bounded the same way) before `read-data`'s continuation runs.

**Backpressure on the client→server direction is therefore purely the safety-limit body-size
cap plus the TCP receive window** — there's no explicit flow-control signal sent to the client;
oversize bodies are rejected via `network-error` (→ `exn:fail:network`) once the running total
crosses `max-body-length`/`max-request-body-length`. Untrusted-input hygiene is explicit and
commented at the top of the file (`request.rkt:17-29`): never use `read-bytes-line`/`read-bytes`
directly against client input because they pre-allocate based on client-claimed sizes; instead
everything goes through the bounded `read-http-line/limited` (`request.rkt:230-280`, chunked
`peek-bytes-avail!` loop with a hard `limit`) and `read-bytes/lazy` (`request.rkt:283-306`).

**Multipart file uploads** (`read-mime-multipart`, `request.rkt:614-760`) spool to a temp file
once a configurable in-memory threshold is exceeded (`make-spooled-temporary-file`,
`request.rkt:522-578`, `form-data-file-memory-threshold`, default 1 MiB — §5), which is the one
place true backpressure onto disk exists.

## 4. Response bodies: streaming + backpressure (both directions)

Handler responses are **producer-driven**, via a `response` struct field `output : output-port?
-> any` (`http/response-structs.rkt:13`, `response-structs.rkt:31-42` `response/output`). The
handler's `output` procedure is called with an output port and writes at its own pace; there is
no return value contract on byte count.

Two paths, both selected by `output-response/method` (§1):

- **Non-chunked** (HEAD / HTTP-1.0 / already-`Content-Length`-terminated): `output-response-body`,
  `response.rkt:154-159` — `((response-output bresp) o-port)` directly against the real
  connection socket, then one `flush-output`. Backpressure here is **whatever Racket's TCP
  output port does**: `write-bytes` on a full socket send buffer blocks the handler's own thread
  until the OS accepts more, i.e. natural OS-level backpressure propagates straight back to the
  application code writing the body (no server-level buffering/queueing beyond the OS socket).

- **Chunked**, `output-response-body/chunked`, `response.rkt:161-209` — the handler is run **in
  its own thread**, writing into one end of a `make-pipe`; the connection-handling code reads
  16 KiB at a time (`(make-bytes 16384)`, `response.rkt:193`) from the *other* end with
  `read-bytes-avail!` and re-emits each chunk (`~a\r\n` size line, bytes, `\r\n`) to the real
  socket, flushing after every chunk. Because `make-pipe` is itself unbounded in Racket by
  default (grows to hold whatever's written until read), **the pipe does not itself apply
  backpressure to a fast producer**; what *does* apply backpressure is the outer loop's
  `write-bytes`/`flush-output` to the real client socket blocking when the OS send buffer is
  full — since the outer loop only pulls the next 16 KiB from the pipe after finishing that
  flush, a slow client eventually stalls the pipe-draining loop, and a full pipe would (per
  Racket's pipe semantics) eventually stall the producer thread's writes into it too. So:
  double-buffered producer→pipe→(chunked framing)→socket, with backpressure ultimately anchored
  on the real socket's OS buffer, propagated backward through the pipe.
  - Every chunk written **resets the connection's response-send timeout**
    (`reset-connection-response-send-timeout!`, `response.rkt:201`) — see §5 — so a slow-but-
    steadily-producing handler can run indefinitely as long as it emits *something* at least
    every `response-send-timeout` seconds (default 60s), while a stalled handler is eventually
    killed.
  - **Client-disappears handling**: if the real socket write raises (client gone), the outer
    `with-handlers` kills the chunker thread (`response.rkt:190-192`); if the *handler* itself
    raises, the connection is killed immediately and the terminating `0\r\n\r\n` chunk is
    deliberately **not** sent (`response.rkt:178-184`, comment: "so the client can't misinterpret
    the response as successful", citing `https://github.com/racket/web-server/pull/93`) — this
    is the exact policy answer to "how do handler errors mid-stream map to the wire" for chunked
    bodies: abrupt close, no synthetic terminator, no trailer, connection killed.
  - `output-file-range` (file serving with byte-range support, `response.rkt:431-447`) uses a
    watchdog thread that `(sync (port-progress-evt limited-input))` to reset the send-timeout on
    every OS-level read progress even though the actual copy is a plain `copy-port`, so large
    static files also get the same "keep making progress or get killed" timeout treatment.

**Response headers are flushed immediately, before the body**, specifically so the chunked
producer thread can take as long as it likes before its first byte
(`response.rkt:163-164`, comment: "Flush the headers immediately since the response handler can
wait a while before writing anything out"). This is the origin of an important HTTP/1.1 subtlety
this implementation does **not** implement: true "streaming trailers" or early hint responses —
headers are just the normal header block, sent once, before any body bytes; there's no support
for HTTP trailers on the chunked encoding despite the chunked writer being hand-rolled.

## 5. Limits and timeouts — every named one, with its default

All from `web-server-lib/web-server/safety-limits.rkt:70-87` (`define-safety-limits/private-
submodule`), a macro that generates the `safety-limits` struct, its keyword constructor, an
"unlimited" constructor, and a `(module+ private)` accessor/match-expander submodule:

```scheme
(define-safety-limits/private-submodule
  max-concurrent positive-count/c 10000 #:unlimited +inf.0
  max-waiting exact-nonnegative-integer? 511 #:unlimited 511 ;; contract from tcp-listen
  request-read-timeout timeout/c 60
  max-request-line-length nonnegative-length/c (* 8 1024)
  max-request-headers nonnegative-length/c 100
  max-request-header-length nonnegative-length/c (* 8 1024)
  max-request-body-length nonnegative-length/c (* 1 1024 1024)
  max-form-data-fields nonnegative-length/c 100
  max-form-data-field-length nonnegative-length/c (* 8 1024)
  max-form-data-files nonnegative-length/c 100
  max-form-data-file-length nonnegative-length/c (* 10 1024 1024)
  form-data-file-memory-threshold nonnegative-length/c (* 1 1024 1024)
  max-form-data-parts nonnegative-length/c (+ max-form-data-fields max-form-data-files)
  max-form-data-header-length nonnegative-length/c (* 8 1024)
  response-timeout timeout/c 60
  response-send-timeout timeout/c 60
  shutdown-grace-period (or/c #f timeout/c) #f)
```

| Name | Default | Meaning (from usage sites) |
|---|---|---|
| `max-concurrent` | **10000** (`+inf.0` if unlimited) | Cap on in-progress accepted connections; enforced in the accept loop, `dispatch-server-with-connect-unit.rkt:62-67` (`in-progress . < . max-concurrent`) — beyond this the accept loop stops calling `tcp-accept` (new TCP connections queue in the OS backlog / get refused per `max-waiting`) until one finishes. |
| `max-waiting` | **511** | Passed straight to `tcp-listen`'s backlog argument (`config:max-waiting`, `dispatch-server-with-connect-unit.rkt:44`) — OS-level `listen()` backlog, comment notes "contract from tcp-listen". |
| `request-read-timeout` | **60s** | Reset at the *start* of reading each request (`reset-connection-timeout!`, `request.rkt:100`); also used as the connection's *initial* timeout at accept time via `start-connection-manager`, `connection-manager.rkt:50-54`. |
| `max-request-line-length` | **8192 bytes (8 KiB)** | Hard cap on the request line, enforced in `read-request-line` → `read-http-line/limited`, `request.rkt:317-318`. |
| `max-request-headers` | **100** | Max header *count*, enforced in `read-headers*`, `request.rkt:348-355` (`network-error … "header count exceeds limit of ~a"`). |
| `max-request-header-length` | **8192 bytes (8 KiB)** | Max length of a single (possibly line-folded) header, `request.rkt:343-373`. |
| `max-request-body-length` | **1 MiB** (`1*1024*1024`) | Applies to both non-chunked `Content-Length` bodies (`read-data`, `request.rkt:401`) and to the *running total* of a chunked body (`complete-request`, `request.rkt:180`). |
| `max-form-data-fields` | **100** | multipart/form-data non-file field count, `read-mime-multipart` bookkeeping (`request.rkt:736-741`). |
| `max-form-data-field-length` | **8 KiB** | Max bytes per non-file field. |
| `max-form-data-files` | **100** | multipart file-part count. |
| `max-form-data-file-length` | **10 MiB** | Max bytes per uploaded file. |
| `form-data-file-memory-threshold` | **1 MiB** | Above this, a file part spools to a real temp file instead of an in-memory pipe (`make-spooled-temporary-file`, `request.rkt:526-566`). |
| `max-form-data-parts` | **200** (`max-form-data-fields + max-form-data-files`, computed default) | Total multipart part count cap. |
| `max-form-data-header-length` | **8 KiB** | Per-part header line length inside multipart. |
| `response-timeout` | **60s** | Time budget for the *handler* to run and hand back a response object — reset right after `read-request` returns, before `dispatch` is called (`dispatch-server-with-connect-unit.rkt:173`, `reset-connection-timeout! conn config:response-timeout`). |
| `response-send-timeout` | **60s** | Rolling per-chunk budget once the body is being streamed out — reset on every chunk (`response.rkt:201`) and every file-range read-progress event (`response.rkt:441-445`); if the handler goes silent for this long mid-stream it's killed (this is the field carried on the private `connection*` subtype, `connection-manager.rkt:46,110-114`). |
| `shutdown-grace-period` | **`#f`** (disabled — immediate hard stop) | If set, first call to the returned `stop` thunk stops accepting new connections and waits up to this many seconds for in-flight ones to finish; a *second* call force-kills immediately — `dispatch-server-with-connect-unit.rkt:115-126` (quoted in §8). |

`make-unlimited-safety-limits` (same file) produces the same struct with every numeric field set
to `+inf.0` (except `max-waiting`, pinned at 511 because that's an OS contract, and
`shutdown-grace-period` still `#f`) — this is the default used by the *low-level* `read-request`/
`make-read-request` unless a caller opts into `(make-safety-limits)` explicitly
(`request.rkt:129-133`, doc comment warns this "leaves applications vulnerable" — i.e. Racket's
own maintainers flag "no limits by default at the low-level API" as a foot-gun,
`request.rkt:40-50`).

Timers themselves are a **single dedicated timer-manager thread per server**, not one OS timer
per connection: `private/timer.rkt:29-82` — one thread owns a `(make-hash)` of live timers,
computes the single nearest deadline, and `sync`s on an `alarm-evt` for that deadline plus a
`thread-receive-evt` for add/remove/administrative messages from other threads. `start-timer`
(`timer.rkt:105-108`) creates one, `reset-timer!`/`increment-timer!`/`revise-timer!`
(`timer.rkt:93-120`) push a `(deadline . action)` mutation through to the manager thread rather
than touching shared state directly — i.e. all timer state lives on one thread and is only ever
mutated by messages sent to it, sidestepping any lock. The doc comment at the top of the file
(`timer.rkt:6-19`) is a concise design note worth copying verbatim into our own decisions doc:
```
;; Timeout plan
;; ============
;;
;; For each connection:
;;   * start timeout on connection startup.
;;
;; For each request on a connection:
;;   * reset timeout when request data comes in,
;;   * reset timeout before the response is handled by the application,
;;   * reset timeout after the application hands the response back,
;;   * reset timeout for every chunk of data sent to the client.
```

## 6. `Expect: 100-continue`

**Not implemented.** I grepped every fetched `.rkt` file (`request.rkt`, `response.rkt`,
`dispatch-server-with-connect-unit.rkt`, `dispatch-servlets.rkt`, `web-server-unit.rkt`, etc.)
for `expect`/`100-continue` and found nothing except unrelated uses of the English word
"expected" in error messages and test helper names (`check-exn:fail:network`'s `cf` = "check
function", `make-check-expected`) — verified with:
```
$ rg -i "expect|100-continue|connect\b|websocket|upgrade" *.rkt gh-*.rkt
```
which surfaced only `Upgrade-Insecure-Requests` as literal test-fixture header data
(`request-test.rkt:824,842` — an *inbound* browser header the parser just stores like any
other, no special handling) and the unrelated `dispatch-server-connect^`/`-with-connect-`
naming (which is about `port->real-ports`, an indirection point for wrapping the raw TCP ports
— e.g. for TLS — **not** the HTTP `CONNECT` method or 100-continue). There is no code path that
inspects an `Expect` header, no 100-status short-circuit, and no delay-body-until-100-sent logic:
a client sending `Expect: 100-continue` gets no interim response and the server will simply try
to read the (declared-length) body as normal once the handler/binding code asks for it. This is
a genuine, citable gap in the reference implementation, not an oversight in my reading.

## 7. Upgrade / CONNECT

**Not implemented** at this layer either — same grep as above. GitHub's code-search API refused
unauthenticated queries (`401 Requires authentication`) so I additionally did an exhaustive
manual pass: enumerated every `.rkt` file under `web-server-lib` via the git-trees API and
`curl`-grepped each one's raw content for the literal string `responders-protocol` (used to
check whether the `responders-protocol` config hook — `[protocol (url? . -> . response?)]`,
`configuration-table-structs.rkt:60` — is wired to anything); it is declared in the config
struct but **never referenced** by that name anywhere else in `web-server-lib`, i.e. it appears
to be a vestigial/unused hook, not a live "protocol-level error → response" path. Concretely:
there is no `CONNECT` method special-casing, no HTTP `Upgrade:`/`101 Switching Protocols`
handling, and no WebSocket support inside `web-server-lib` itself (that lives in a separate
`net/websocket` codebase Racket users layer on top, outside the scope of this repo). The
`dispatch-server-connect^` signature and the `-with-connect-` unit names are unrelated
terminology collisions — they refer to `port->real-ports : input-port? output-port? ->
(values input-port? output-port?)` (`private/dispatch-server-sig.rkt:17-21`), the seam where an
embedder can wrap the raw accepted TCP ports (e.g. to add TLS) before the HTTP layer ever sees
them (raw passthrough implementation: `private/raw-dispatch-server-connect-unit.rkt:8-11`,
`(define (port->real-ports ip op) (values ip op))`). Chez-http-server should treat "Upgrade/
CONNECT" as explicitly out of scope if we want to mirror this reference's actual surface, or
consciously decide to do better.

## 8. Framing precedence

- **Content-Length vs Transfer-Encoding on requests**: `complete-request`
  (`request.rkt:159-196`, quoted in §3) checks `Transfer-Encoding` **first** via an exact
  (case-sensitive!) byte match against the literal `#"chunked"` — `(struct header (f
  #"chunked"))` is a literal-bytes pattern in `match`, so a value of `"Chunked"`, `"chunked,
  gzip"`, or anything not byte-identical to `"chunked"` falls through to the `[_ ...]` branch
  and is treated as **not chunked**, falling back to whatever `Content-Length` says (or no body
  at all). This is a real parser looseness worth not copying as-is.
- **Duplicate/conflicting Content-Length + Transfer-Encoding — a genuine smuggling-adjacent
  bug I traced end-to-end**: when a request has *both* `Transfer-Encoding: chunked` and an
  (attacker-supplied) `Content-Length` header in its initial header block, `complete-request`
  computes the *correct* decoded length in `total-size` and builds `more-headers` as
  `(list* (header #"Content-Length" total-size-bytes) trailer-headers…)` (`request.rkt:188-190`),
  then returns `(values decoded-ip (append initial-headers more-headers))`
  (`request.rkt:193`) — i.e. the **original** `initial-headers` (which may already contain a
  client-forged `Content-Length`) is placed **before** the freshly computed one in the merged
  list. `headers-assq*` (`request-structs.rkt`, first-match-wins linear scan, quoted below) then
  returns the **attacker's** `Content-Length`, not the computed one, to any later code (notably
  `read-data` in `read-bindings&post-data/raw`, `request.rkt:395-418`) that looks up
  `Content-Length` to decide how many bytes to read from the already-correctly-dechunked body
  pipe. Net effect: with conflicting headers, the *framing* of where the next pipelined request
  begins is still computed correctly (it's driven by the chunk-terminator scan against
  `real-ip`, independent of any `Content-Length`), but the **body/bindings the application
  handler receives can be silently truncated or shifted** relative to what was actually sent,
  because the wrong (client-controlled) length wins the lookup. RFC 7230 §3.3.3 says a server
  that receives both headers with differing information must reject the message (to close
  exactly this smuggling-shaped ambiguity); Racket's reference does not reject it — it silently
  prefers the client's original header for downstream body-length decisions. Chez-http-server
  should **not** copy this: reject (400) any request presenting both `Content-Length` and
  `Transfer-Encoding: chunked` (or multiple distinct `Content-Length` values), full stop.
  (`headers-assq*`, `web-server-lib/web-server/http/request-structs.rkt:87-90`:
  ```scheme
  (define (headers-assq* f hs)
    (for/first ([h (in-list hs)]
                #:when (bytes-ci=? f (header-field h)))
      h))
  ```)
- **HEAD**: handled centrally in `output-response/method` (§1/§4) — headers are always sent,
  body-writer is simply never invoked for HEAD (`response.rkt:56-59`,
  `(unless (bytes-ci=? meth #"HEAD") (output-response-body conn resp))`), and chunked framing is
  never chosen for HEAD either (it's in the same `cond` branch as "terminated"/"HTTP-1.0"). If
  the application's response has no explicit `Content-Length` (e.g. built with `response/
  output`), a HEAD reply ends up with **neither** `Content-Length` **nor** `Transfer-Encoding`
  — spec-legal for HEAD (client is defined to expect no body regardless) but worth naming
  explicitly since it's a real edge in the header-synthesis code (`add-missing-headers`,
  `response.rkt:68-79`, only auto-adds `Connection`/`Content-Type`/`Date`/`Last-Modified`/
  `Server`/`Transfer-Encoding` — **not** `Content-Length**, which is only present if the
  application itself put one in `response-headers`, e.g. via `response/full`,
  `response-structs.rkt:15-29`, which always computes an exact `Content-Length` from a
  known-length byte-list body).
- **1xx/204/304 body suppression is *not* implemented by the framework at all.**
  `output-response-body`/`output-response-body/chunked` (`response.rkt:154-209`) unconditionally
  invoke the response's `output` procedure regardless of `response-code`; there is no check
  anywhere in `response.rkt` for status codes 204, 304, or any 1xx. If an application constructs
  a `response` with code 204 and a non-empty `output` procedure, Racket's web-server will write
  that body onto the wire. Enforcing "no body for 204/304/1xx" is entirely the *application's*
  responsibility in this design, not the transport layer's. This is a real gap relative to RFC
  9110 §6.4.1/§15 that chez-http-server should close (bake the suppression into the response
  writer, not push it to handler authors).
- **Duplicate headers generally**: no de-duplication or rejection logic anywhere in
  `read-headers*` (`request.rkt:348-360`) — headers are just appended into a flat
  `(listof header?)` in arrival order; `headers-assq*`/`headers-assq` are first-match, so for
  any duplicated header the **first occurrence on the wire wins** for every internal lookup,
  silently. Combined with the Content-Length point above, this "first wins" policy is the crux
  of the smuggling-adjacent gap.

## 9. Parse/policy/handler errors → responses, and whether the connection is closed

This is the single most important structural finding for us. The **entire** per-connection loop
is guarded by exactly one `with-handlers` clause that treats **every** `exn:fail?` — whether it
came from parsing the request line, reading headers, decoding the body, running the application
handler, or writing the response — identically:

`private/dispatch-server-with-connect-unit.rkt:163-178`:
```scheme
(with-handlers ([exn:fail?
                 (lambda (e)
                   (unless (exn-expected? e)
                     ((error-display-handler)
                      (format "Connection error: ~a" (exn-message e))
                      e))
                   (kill-connection! conn))])
  (let connection-loop ()
    (define-values (req close?)
      (config:read-request conn config:port port-addresses))
    (reset-connection-timeout! conn config:response-timeout)
    (set-connection-close?! conn close?)
    (config:dispatch conn req)
    (if (connection-close? conn)
        (kill-connection! conn)
        (connection-loop))))
```
`network-error` (the constructor every parse-limit violation in `request.rkt` raises — malformed
request line, too many headers, header too long, body too long, bad multipart, etc., all via
`(raise (make-exn:fail:network …))`, `private/util.rkt:46-54`) produces an `exn:fail:network`,
which **is** an `exn:fail`, so it is caught by this same handler. **The result of every parse
failure, every safety-limit violation, and every uncaught handler exception is identical: the
connection is silently killed (`kill-connection!`) with no HTTP response written back to the
client at all.** There is no 400, no 408, no 413, no 431, no 500 at this layer — Racket's
reference server never sends a synthetic error status code for a protocol-level problem; it
just drops the TCP connection. (A 5xx *can* appear, but only if the application's own servlet
dispatcher — `dispatch-servlets.rkt`, driven by the `responders-servlet` hook,
`configuration-table-structs.rkt:53-61` — chooses to catch an exception from *inside* a loaded
servlet and turn it into a response; that is an application-level convenience layered well above
the raw parse/connection loop this task is about, and it never fires for a request-parsing
error, since `config:read-request` runs *before* `config:dispatch` is ever called.)

`exn-expected?` (`dispatch-server-with-connect-unit.rkt:180-213`) is purely a **logging** filter
— it decides whether to print "Connection error: …" to stderr, not whether to respond
differently to the client; in every case the connection is still killed:
```scheme
(define/match (exn-expected? _)
  [((or
     (exn:fail:network:errno _ _ (cons (or 54 104) 'posix))   ;; ECONNRESET
     (exn:fail:filesystem:errno _ _ (cons (or 54 104) 'posix))
     (exn:fail:network:errno _ _ (cons 32 'posix))            ;; EPIPE
     (exn:fail:filesystem:errno _ _ (cons 32 'posix))
     (exn:fail "fprintf: output port is closed" _)
     (exn:fail (regexp #rx"input port is closed") _)
     (exn:fail (regexp #rx"http input closed prematurely") _)))
   #t]
  [(_) #f])
```
The comments on these clauses (`dispatch-server-with-connect-unit.rkt:184-208`) are a good,
concrete enumeration of "expected" abrupt-disconnect causes worth mirroring in our own
error-classification: client RST while we're mid-write, broken pipe writing to a closed socket,
input port closed while reading (timeout-driven), and — explicitly — the fact that under
HTTP/1.1 "there is no explicit connection closing… so we attempt to read a new request off of a
connection as soon as the previous one was handled [and] if the client goes away, then this
error gets triggered and we can safely ignore it" (i.e., reading past EOF at the start of the
next pipelined request is expected and not logged as an error).

**Lesson**: Racket's reference deliberately puts *zero* protocol-error-to-status-code mapping in
its lowest layer. If chez-http-server wants 400/408/413/431/505 responses for malformed input
(reasonable and expected of a modern server, and explicitly requested by our own task), that is
a **deliberate improvement over this reference**, not something to copy — we should design our
own mapping rather than assume "parse error ⇒ close" is good practice; it is merely what this
particular, widely-used implementation does.

## 10. Close / shutdown protocol

**Per-connection close** — `kill-connection!`/`kill-connection-w/o-timer!`,
`private/connection-manager.rkt:82-94`:
```scheme
(define (kill-connection! conn)
  (cancel-timer! (connection-timer conn))
  (kill-connection-w/o-timer! conn))

(define (kill-connection-w/o-timer! conn)
  (with-handlers ([exn:fail:network? void])
    (close-output-port (connection-o-port conn)))
  (with-handlers ([exn:fail:network? void])
    (close-input-port (connection-i-port conn)))
  (custodian-shutdown-all (connection-custodian conn)))
```
There is **no lingering-close protocol** (no draining/discarding of any remaining unread client
bytes before closing, no explicit half-close / `shutdown(SHUT_WR)`-then-wait-for-peer-FIN
sequence, no `SO_LINGER` tuning) — it is a plain "close output, close input, shut down the whole
per-connection custodian (which cascades to kill any handler threads/subordinate resources)".
Each connection also gets its own **timer-driven** forced-kill: `new-connection`
(`connection-manager.rkt:58-80`) starts a timer whose action is
`(kill-connection-w/o-timer! conn)` when it fires, referenced through a **weak box**
(`(make-weak-box conn)`, `connection-manager.rkt:71`) specifically so a still-pending timer
doesn't itself keep a fully-handled, already-GC'able connection alive.

**Server-wide graceful shutdown** — the `stop` thunk returned by `serve`,
`private/dispatch-server-with-connect-unit.rkt:109-126`:
```scheme
;; When there is a grace period, calling stop the first time causes the server to stop accepting
;; new connections and waits for in-progress connections to finish. Calling it a second time
;; immediately kills the server. …
(let ([stopping? #f])
  (lambda ()
    (cond
      [(and (not stopping?)
            (safety-limits-shutdown-grace-period config:safety-limits))
       => (lambda (timeout)
            (set! stopping? #t)
            (thread-send listener-thd 'stop)
            (sync/timeout timeout listener-thd)
            (custodian-shutdown-all the-server-custodian))]
      [else
       (custodian-shutdown-all the-server-custodian)])))
```
`'stop` sent to the accept-loop thread flips its `accepting?` flag off
(`dispatch-server-with-connect-unit.rkt:63-67,79-81`) so no *new* TCP accepts happen, but the
loop keeps running (and keeps servicing `'done` messages from finishing handler threads) until
`in-progress` reaches zero, at which point the loop itself exits and closes the listener
(`dispatch-server-with-connect-unit.rkt:105-108`). The outer `stop` thunk `sync/timeout`s on the
listener thread for up to `shutdown-grace-period` seconds; if that elapses first (in-flight
requests still running), it force-kills everything anyway via `custodian-shutdown-all`. Calling
`stop` a **second time** always takes the `else` branch (`stopping?` is already `#t`), so it's an
unconditional immediate `custodian-shutdown-all` — this is the documented "call twice to force
an immediate kill after a grace period was already requested" escape hatch, directly verified by
`web-server-test/tests/web-server/serve-tests.rkt`'s `"kills the server if stop is called twice"`
test case (quoted in §11). With **no** `shutdown-grace-period` set (the default, `#f`), `stop`
always takes the `else` branch too — i.e. **the out-of-the-box default is an immediate hard
stop with no grace period at all**, and graceful drain is strictly opt-in.

No half-close (TCP `FIN` on the write side while still reading) appears anywhere in this
codebase — closing is always both directions via `close-output-port` + `close-input-port`
together.

## 11. Application handler API shape

Two levels are visible in the fetched sources:

- **Raw/low-level `dispatch` signature** — what the connection loop actually calls,
  `private/dispatch-server-sig.rkt:23-35` (`dispatch-server-config*^`):
  ```scheme
  [dispatch
   (-> connection? any/c any)]
  ```
  and, independently, the general dispatcher contract used throughout the dispatcher-chain
  machinery, `dispatchers/dispatch.rkt:6-11`:
  ```scheme
  (define dispatcher/c
    (connection? request? . -> . any))
  ...
  (define (next-dispatcher) (raise (make-exn:dispatcher)))
  ```
  i.e. `(connection?, request?) -> any`, invoked purely for effect (it's expected to call
  `output-response`/`output-response/method` itself against `(connection-o-port conn)`); a
  dispatcher signals "not mine, try the next one in the chain" by calling `(next-dispatcher)`,
  which `raise`s a distinguished `exn:dispatcher` a sequencing combinator
  (`sequencer:make`, referenced in `web-server-unit.rkt:62,72,76,100,105`) catches to try the
  next dispatcher in the list. This chain-of-responsibility shape (ordered list of `dispatcher/c`
  procedures, each opting in/out via a sentinel exception) is how Racket composes
  timeout-wrapping, logging, virtual hosting, static file serving, servlet dispatch, and 404
  fallback (`web-server-unit.rkt:60-113`) — worth studying as a pattern even though it's above
  the pure connection-semantics layer this task is scoped to.
- **Ergonomic servlet-style handler** — what applications actually write, confirmed from the
  e2e test `server.rkt` fixtures (`web-server-test/tests/web-server/e2e/{head,graceful-shutdown,
  max-concurrent}/server.rkt`, e.g. `e2e_max-concurrent_server.rkt:11-14`):
  ```scheme
  (define (app _req)
    (response/output
     (lambda (out)
       (display "ok" out))))
  ...
  (dispatch/servlet app)
  ```
  i.e. `request? -> response?`, a pure(-ish) function from request to response value, adapted
  into the raw `dispatcher/c` shape by `dispatch/servlet` (`web-server/servlet-dispatch`). The
  `response` value itself (`response-structs.rkt:13`, `(struct response (code message seconds
  mime headers output))`) is the boundary object: `code`/`message`/`mime`/`headers` are plain
  data, and `output` is the deferred, effectful body-writer procedure described in §4 — this
  split (immediately-decided status+headers as data vs. a lazily-invoked body-writer closure) is
  exactly the shape I'd recommend chez-http-server's own handler API mirror, since it's what
  lets the framework flush headers before the body is ready (§4) while still keeping the common
  case (`response/full`, fully-in-memory body, `response-structs.rkt:15-29`) trivially simple.

## 12. What this implementation's own test suite covers (and what we should copy)

Enumerated via the GitHub trees API (`git/trees/master?recursive=1`, filtered to
`/tests/`-containing and connection/dispatch/timer/request/response/server-relevant paths — full
command and matched path list included in the Files-fetched section above). Highlights, each
fetched and read in full this session unless noted:

- **`web-server-test/tests/web-server/private/request-test.rkt`** (1195 lines; already cached,
  read in full) — the parser/limits unit-test suite. Notable test groups (line numbers from the
  fetched copy): `"Request Line"` (983-998, incl. an `OPTIONS *` asterisk-form test and a
  request-line-too-long limit test), `"Headers"` (1000-1051, incl. line-folded/tabbed header
  continuation, too-many-headers, header-too-long, folded-header-too-long), `"Chunked
  transfer-encoding"` (1053-1083, incl. too-many-headers-after-chunked-body and
  chunked-request-too-large), `"JSON data"` (1085-1114), `"GET bindings"` / `"POST Bindings"`
  (1116-1164, incl. `post-with-invalid-content-length` and
  `post-with-body-shorter-than-content-length` — i.e. explicit tests for a non-numeric
  Content-Length and for a body that's shorter than declared), `"File Uploads"` (1166-1195+,
  multipart with spooled files, missing Content-Disposition, missing body). All driven through a
  `fixtures/` directory of raw byte-for-byte request captures (`web-server-test/tests/web-server/
  private/fixtures/*`, list enumerated via the trees API — e.g.
  `post-with-body-shorter-than-content-length`, `multipart-body-without-end-boundary`,
  `get-with-long-multi-line-header`) — **this fixture-file-per-edge-case pattern is directly
  reusable for chez-httparse/chez-http-server's own request-line/header/chunked conformance
  tests.**
- **`web-server-test/tests/web-server/private/response-test.rkt`** (206 lines, cached, read in
  full) — tests the *writer*, not the parser, using a hand-rolled buffered-pipe test harness
  that simulates OS-level socket buffering (`make-buffered-pipe`, lines 18-57) so that chunk
  boundaries are actually observable by the test. Four `test-case`s worth copying nearly
  verbatim as a design for our own response-writer tests: (1) "the request and each chunk after
  it is flushed immediately" — asserts on-the-wire byte sequence including the exact
  `"1\r\na\r\n"` chunk framing and terminal `"0\r\n\r\n"`; (2) "responders exit cleanly when the
  client disappears" — closes the simulated client's write side mid-stream and asserts the
  handler thread dies; (3) "connections are closed when responders fail" — handler `(error
  'fail)` mid-stream, asserts no further chunks (specifically no terminator) are sent; (4)
  "every chunk resets the rolling 60 second timeout window" — asserts, via direct inspection of
  `(connection-timer connection)`'s deadline, that each written chunk pushes the deadline back
  out to ~60000ms repeatedly. This is exactly the kind of white-box timer assertion our own
  FiveAM (or equivalent) suite should include for the libuv-timer-backed connection timeout.
- **`web-server-test/tests/web-server/private/connection-manager-test.rkt`** (99 lines, cached,
  read in full) — tests "Input closed"/"Output closed" (port I/O raises after the connection's
  timer fires and kills it), "Early kill" (`kill-connection!` called directly), and "Extend
  timer" (`adjust-connection-timeout!` genuinely delays the kill, verified by timing). Uses a
  neat trick worth copying: it wraps the *real* timer action in a second closure that posts to a
  test-only channel when the real action completes, so tests can `sync` on "the timeout actually
  fired" rather than using a static `sleep` — avoids flaky timing-based tests.
- **`web-server-test/tests/web-server/e2e/`** (fetched this session; `README.md` describes the
  convention: each subfolder exports a `start`/`server.rkt` pair and a `make-tests` from
  `tests.rkt` taking `(get-port get-stop)`). Directories present: `echo`, `file-upload`,
  `graceful-shutdown`, `head`, `json`, `max-concurrent`, `read-write`, `tls` (only the last four
  fetched in full this session, listed for completeness from the trees enumeration). These are
  genuine **socket-level, real-server, real-TCP** tests, the right level for chez-http-server's
  own integration suite:
  - `e2e/head/tests.rkt` — literally opens a raw TCP socket, sends `HEAD / HTTP/1.1\r\n\r\n`
    by hand, and asserts the response has the same headers as `GET` but zero body lines. Comment
    explicitly notes `net/url` and `net/http-client` both silently discard HEAD bodies, which is
    *why* the test bypasses them and speaks raw HTTP/1.1 over `tcp-connect` — a good reminder
    that testing HEAD correctness requires a raw-socket test client, not a convenience HTTP
    client.
  - `e2e/graceful-shutdown/{server,tests}.rkt` — server handler sleeps 1s between 5 lines of
    output; test opens a real connection, starts the request, calls `stop`, and asserts it still
    receives the full `"0\n1\n2\n3\n4\n"` output — i.e. an end-to-end proof that `stop` really
    does wait for the in-flight response to finish.
  - `e2e/max-concurrent/{server,tests}.rkt` — server configured with `#:max-concurrent 1
    #:max-waiting 10`; test suite has a `"sequential requests"` group (10 requests one at a
    time, all must succeed) and a `"concurrent requests"` group using a `check-concurrent-
    requests` helper that opens N connections, releases them all at once via a shared semaphore,
    and asserts a minimum number of successes/failures — directly the shape of test we should
    write for our own `max-concurrent`/backlog behavior once decided. (Note the commented-out
    `;(check-concurrent-requests 500 10 1)  times out in GitHub Actions` — even Racket's own CI
    found high-concurrency socket tests flaky enough to disable; worth planning for in our CI
    from day one rather than discovering it later.)
  - `e2e/read-write/tests.rkt` — a "sending data too slowly" test that opens a raw TCP
    connection, sends a request one **character at a time** with a 0.25s sleep between each,
    and expects a broken-pipe (`errno 32`) exception from the *client* side once the server's
    `request-read-timeout` fires and the server closes on it — this is precisely a
    slow-loris-style test and is exactly the test shape chez-http-server needs for its own
    `request-read-timeout` enforcement.
  - `web-server-test/tests/web-server/serve-tests.rkt` (fetched this session, quoted in part in
    §10) — the highest-level shutdown test file: `"stops immediately if there are no
    connections"`, `"waits for in-progress requests to finish"`, `"stops when in-progress
    requests stop"` (client closing its own read side to unblock a slow write), and `"kills the
    server if stop is called twice"` — this last one is the concrete, runnable spec for the
    double-`stop`-call escape hatch described in §10; genuinely worth porting almost line-for-
    line into our own test suite once chez-http-server has an equivalent `serve`/`stop` API.

## Lessons for us (chez-http-server), concrete and copy-ready

1. **Keep-alive rule to copy directly**: HTTP/1.1 defaults persistent; HTTP/1.0 defaults
   non-persistent regardless of any `Connection: keep-alive`; either is forced non-persistent by
   a `Connection` header whose value contains "close". Decide this **once per request**,
   immediately after parsing the request line/headers (before the handler runs), and store it as
   mutable per-connection state that both (a) drives whether the connection loop reads another
   request afterward and (b) drives whether the response writer emits `Connection: close`. Do
   **not** literally substring-match "close" the way Racket does (`#rx#"[cC][lL][oO][sS][eE]"`)
   — tokenize the `Connection` header on commas and compare tokens case-insensitively, to avoid
   both false positives and false negatives on multi-token values like `Connection: keep-alive,
   Upgrade`.
2. **Never allow "unterminated body + persistent connection" to be constructible.** Racket
   achieves this by routing every response without a known `Content-Length` through chunked
   encoding unless the connection is already going to close (HTTP/1.0, `Connection: close`, or
   HEAD) — worth copying as an invariant enforced by the response-writer, not left to
   application authors.
3. **Reject conflicting/duplicate `Content-Length`+`Transfer-Encoding` outright (400), rather
   than silently preferring whichever header appears first**, unlike Racket's reference (§8) —
   this is a genuine, traced, request-smuggling-shaped gap in the implementation we're
   otherwise learning from, not a pattern to imitate. Likewise reject (or fully normalize) a
   `Transfer-Encoding` value that isn't the exact token `chunked` rather than silently falling
   back to non-chunked framing.
4. **Bake 1xx/204/304 body suppression into the transport-level response writer**, not into
   convention/handler discipline — Racket's reference leaves this entirely to application code
   and has no framework-level guard at all (§8), which is a foot-gun we can close for free since
   we control both the response struct and the writer.
5. **Design an explicit parse/limit-violation → HTTP status mapping (400/408/413/431/505) as a
   deliberate improvement over this reference**, which maps every parse error, every safety-limit
   violation, and every uncaught handler exception to the same outcome — silently killing the
   TCP connection with no response at all (§9). Do keep Racket's underlying idea of "classify
   exceptions into an ignorable/expected set purely for logging purposes" (`exn-expected?`,
   §9) — enumerating ECONNRESET/EPIPE/"port already closed"/"EOF while reading the next
   pipelined request" as expected-and-not-worth-logging is a good, concrete, reusable
   classification list even if our error-to-status mapping goes further than Racket's.
6. **Reuse the single-timer-manager-thread design** (`timer.rkt`, §5) nearly as-is: one thread
   owning a hash of live timers, computing the single nearest deadline, blocking on that one
   alarm event plus an inbox of add/remove/reset messages from other threads — this maps well
   onto chez-libuv's own timer handles (`make-uv-timer` per connection per the project brief) if
   we instead let libuv's loop itself be the "single timer thread" and just mirror the
   reset-points enumerated in the doc comment: on connection accept, on request-line/headers
   arrival, before the handler runs, after the handler hands back a response, and on every
   chunk/range-read-progress event sent to the client. That five-point reset list
   (`timer.rkt:6-19`, quoted in §5) is directly portable to our own connection-timeout design
   and answers "when exactly do we touch the deadline" precisely.
7. **Chunked response writing should be built on a bounded/backpressuring channel, not an
   unbounded pipe.** Racket's `make-pipe` (§4) is unbounded, so backpressure from a slow client
   only reaches the response-generating thread indirectly, once the *draining* loop's own
   `write-bytes`/`flush-output` to the real socket blocks — meaning a fast handler paired with a
   slow client can still buffer an unbounded amount of already-chunked-but-unsent data in the
   pipe before backpressure bites. Given chez-libuv has **no bounded write queue either** (per
   the project brief, ADR-0018) and exposes `uv-stream-write-queue-size` as the congestion
   signal instead, chez-http-server's chunked-body writer should poll/track that queue-size (or
   equivalent outstanding-bytes counter) explicitly, rather than relying on an implicit,
   OS-buffer-anchored backpressure chain the way Racket's design does — we don't get Racket's
   free ride from blocking synchronous port writes.
8. **On a mid-stream handler error, close the connection abruptly and do not send the chunked
   terminator** (Racket's explicit, commented decision, §4, citing
   `github.com/racket/web-server/pull/93`) — copy this policy directly: a truncated-without-
   terminator chunked body is the correct signal to well-behaved clients that the response was
   incomplete/failed, whereas sending `0\r\n\r\n` after an error would let the client believe
   the response completed successfully.
9. **Graceful shutdown as a two-call state machine is a good, minimal design to copy**: first
   `stop` (when a grace period is configured) stops accepting new connections and waits up to
   the grace period for in-flight work to finish; a second `stop` call — or no grace period
   configured at all, which is the sensible default we should also pick — is an unconditional
   immediate teardown. No half-close/lingering-close protocol is needed to copy from this
   reference because it doesn't have one (§10) — if chez-http-server wants lingering-close
   semantics (draining a client's in-flight bytes before RST-avoiding close), that has to be
   designed fresh; there's no proven pattern to lift from Racket here.
10. **Handler API shape**: mirror the `request? -> response?` shape where `response` is a
    small data record for status/message/headers plus a single deferred `output :
    output-port? -> any` (or, for us, "output sink") closure for the body (§11) — this cleanly
    separates "decide status+headers now" from "produce body bytes whenever ready", which is
    exactly what lets headers flush before the body producer even starts, and is a very natural
    fit for a Scheme handler API either as CPS or as a simple record+closure the imperative
    shell calls once framing is set up.
11. **Test-suite shape to copy wholesale**: (a) fixture-file-per-edge-case unit tests for the
    parser (§12, `request-test.rkt` + `fixtures/`), (b) a hand-rolled buffered-pipe harness for
    asserting exact on-the-wire chunk framing bytes in response-writer unit tests (§12,
    `response-test.rkt`), (c) a small, real-socket e2e suite per behavior
    (`head`/`graceful-shutdown`/`max-concurrent`/`read-write`/`json`/`file-upload`/`tls`/`echo`),
    each as an independent `server.rkt`+`tests.rkt` pair driven by a shared harness taking
    `(get-port, get-stop)` (§12, `e2e/README.md`) — this last pattern in particular is directly
    reusable for chez-http-server's own end-to-end suite against real TCP sockets via
    chez-libuv, including the slow-loris-style "send one byte every 250ms and expect a
    read-timeout close" test (§12, `read-write/tests.rkt`) which is the single best concrete
    template for validating our own `request-read-timeout` behavior.
12. **Gaps we should consciously decide about rather than inherit by default**: no `Expect:
    100-continue` support (§6), no `Upgrade`/`CONNECT`/WebSocket support in the core transport
    (§7), no HTTP trailers on chunked bodies (§4), no request pipelining depth beyond
    strict one-in-flight-at-a-time per connection (§2 — fine as a starting design, but note it
    explicitly as a choice, since chez-httparse's own pipelining-boundary support via
    `consumed` byte counts from `parser-feed!` would let us go further if we ever wanted to).
