# h2o HTTP/1 connection semantics — reference extraction for chez-http-server

Source: https://github.com/h2o/h2o, branch `master`, fetched 2026-09-19.

All files were fetched as raw text over HTTPS (`raw.githubusercontent.com`) and/or via a
shallow, sparse `git clone --depth 1 --filter=blob:none --sparse` of `include/` and `lib/`
into the scratchpad (`/private/tmp/.../scratchpad/h2o-repo`), which was used only for
full-text search (`rg`) to locate macro definitions that are not in the three files the task
named. Every fact below is anchored to a specific fetched file and line number. I was able to
fetch every file I needed; nothing in this report is from memory.

Local copies (scratchpad, not the git repo):
- `scratchpad/h2o-src/http1.c` (54344 bytes, fetched from `https://raw.githubusercontent.com/h2o/h2o/master/lib/http1.c`)
- `scratchpad/h2o-src/http1.h` (1555 bytes, from `.../include/h2o/http1.h`)
- `scratchpad/h2o-src/socket.c` (93090 bytes, from `.../lib/common/socket.c`)
- `scratchpad/h2o-src/h2o.h` (91999 bytes, from `.../include/h2o.h`)
- `scratchpad/h2o-src/evloop.c.h` (36553 bytes, from `.../lib/common/socket/evloop.c.h`)
- `scratchpad/h2o-src/uv-binding.c.h` (15098 bytes, from `.../lib/common/socket/uv-binding.c.h`)
- `scratchpad/h2o-src/picohttpparser.c` (28113 bytes, from `.../deps/picohttpparser/picohttpparser.c`)
- `scratchpad/h2o-src/config.c` (from `.../lib/core/config.c`, default-value assignments)
- `scratchpad/h2o-repo/include/h2o/header.h`, `include/h2o/socket.h`, `lib/core/context.c`,
  `lib/core/request.c` (searched via `rg` in the sparse clone for macro/enum definitions and
  the shutdown/error-response plumbing that `http1.c` calls into)
- Test files: `scratchpad/h2o-src/t_40chunked.t`, `t_40expect.t`, `t_40http1-pipeline.t`,
  `t_40http1-streaming-framing.t`, `t_40http1-timeouts.t`, `t_80http1-chunk-overhead.t`,
  `t_99fuzzer-http1.t` (all from `https://raw.githubusercontent.com/h2o/h2o/master/t/<name>`)

Below, citations are `file:line` against these local copies; the paths in the h2o repo are
identical minus the `scratchpad/h2o-src/` or `scratchpad/h2o-repo/` prefix (e.g. `http1.c:150`
== `lib/http1.c` line 150 in h2o's own tree).

---

## 1. Per-connection state machine

`struct st_h2o_http1_conn_t` (`http1.c:64-86`) holds: the `h2o_socket_t *sock`, two
independent `h2o_timer_t` entries — `_timeout_entry` (the "request timeout", i.e. time
allowed to *receive* a complete request) and `_io_timeout_entry` (the "request I/O timeout",
re-armed on every read/write progress event) — a monotonically increasing `_req_index`
(counts requests on this connection, used for logging/pipelining diagnostics), `_prevreqlen`
(byte offset into the socket's input buffer already scanned by the incremental
`phr_parse_request` call, so re-parsing after a partial read doesn't restart from byte 0),
`_unconsumed_request_size`, a `_req_entity_reader` (polymorphic content-length vs. chunked
body reader, `http1.c:88-100`), the `h2o_buffer_t *req_body` accumulator, an `upgrade`
struct `{void *data; h2o_http1_upgrade_cb cb;}`, the final output-stream object
`_ostr_final` (`http1.c:39-62`, tracks `OSTREAM_STATE_HEAD|BODY|DONE`), and the embedded
`h2o_req_t req` itself.

There is exactly one `h2o_req_t` per connection, reused across requests: `init_request`
(`http1.c:110-132`) disposes the previous request's pool/body and re-initializes in place
when `_req_index != 0`. This is the concrete mechanism behind "at most one in-flight request
per HTTP/1.x connection" (see §3, pipelining).

## 2. Keep-alive decision rule

All of the logic lives in `fixup_request` (`http1.c:430-535`), called once per parsed
request from `handle_incoming_request` (`http1.c:684`).

- HTTP version is computed as `conn->req.version = 0x100 | (minor_version != 0)`
  (`http1.c:438`) — i.e. **any** non-zero minor version from picohttpparser is folded to
  "1.1" for keep-alive purposes; only `minor_version == 0` is treated as HTTP/1.0. (Note:
  h2o never actually distinguishes HTTP/1.2, /1.3, etc. — picohttpparser only returns the
  parsed digit, and h2o treats every non-"1.0" response the same. There's no `505 HTTP
  Version Not Supported` path anywhere in the codebase — see §8.)
- **RFC 7231 §6.2 compliance**: if version < 1.1, `conn->_ostr_final.super.send_informational`
  is set to `NULL` (`http1.c:441-442`), which disables the ability to emit *any* 1xx
  response (including the eventual 100-continue write path is separate — see §6 — but a
  100-continue is still sent to 1.0 clients that send `Expect: 100-continue`; only the
  `send_informational` ostream callback used by `h2o_send_informational()` for
  handler-initiated 1xx is gated by version).
- **Connection header wins over version defaults** (`http1.c:504-531`):
  - If a `Connection:` header is present and contains the `keep-alive` token (comma-split,
    `h2o_contains_token`, `http1.c:507`), `http1_is_persistent = 1`.
  - Else if `Connection:` is absent and `version >= 0x101` (HTTP/1.1), defaults to
    persistent (`http1.c:524-526`).
  - Otherwise (`Connection: close` present, or HTTP/1.0 with no `Connection: keep-alive`)
    the request stays non-persistent (the struct field starts zeroed — `h2o_http1_accept`
    zero-fills the connection struct at `http1.c:1324-1325`, and `init_request`'s embedded
    `h2o_init_request` presumably zeroes `http1_is_persistent` per request too).
  - **`Upgrade` is only honored when there is no request body** (`http1.c:510-513`):
    `if (upgrade.base != NULL && h2o_contains_token(connection, "upgrade") &&
    *entity_header_index == -1)`. The comment explains why: h2o reuses the same
    "entity reader" machinery for both request-body streaming and post-upgrade tunnelled
    bytes, so a request that both declares a body (Content-Length/Transfer-Encoding) *and*
    asks to Upgrade is **not** treated as an upgrade at all — it falls through as an
    ordinary request with a body.
  - **Draining on shutdown**: `if (conn->req.http1_is_persistent && ctx->shutdown_requested)
    conn->req.http1_is_persistent = 0;` (`http1.c:529-530`) — see §11 for the full graceful
    shutdown protocol this participates in.
- **Close-delimited responses** (no explicit framing, response body length known only by EOF)
  are not implemented as a distinct mode for HTTP/1.1 output: `should_use_chunked_encoding`
  (`http1.c:990-1006`) forces `Transfer-Encoding: chunked` for *any* HTTP/1.1 response whose
  `content_length == SIZE_MAX`, except tunnels, 1xx/204/304, and HEAD. So a "close-delimited"
  response can only happen (a) for an HTTP/1.0 client, where chunked is unavailable
  (`req->version != 0x101` short-circuits `should_use_chunked_encoding` at `http1.c:994`) and
  the connection is forced non-persistent by the version-default rule above, or (b) when an
  error path explicitly forces `http1_is_persistent = 0` (§8). In other words: **h2o never
  sends an HTTP/1.1 response with neither Content-Length nor chunked framing while keeping
  the connection open** — if it can't frame the length, it closes.

## 3. Pipelining policy and response ordering

h2o parses pipelined bytes as they arrive but **never runs more than one request through the
handler at a time** on a given connection — response ordering is trivially guaranteed because
processing is fully serial, not because of any explicit reordering/queueing structure.

Mechanism:
- `reqread_start` (`http1.c:831-838`) arms both timers, calls `h2o_socket_read_start`, and
  then — critically — `if (conn->sock->input->size != 0) handle_incoming_request(conn);`
  (`http1.c:836-837`): if a second (pipelined) request's bytes are already sitting in the
  socket's input buffer from a previous read, it is parsed immediately, without waiting for
  another readable event.
- For a request with no body, `handle_incoming_request` calls `h2o_socket_read_stop` and
  `h2o_process_request` (`http1.c:762-765`) — reading is turned off before the handler even
  runs, so no further pipelined bytes are consumed/parsed until this response is done.
- The response is written by `finalostream_send` (`http1.c:1042-1115`) via
  `h2o_socket_sendvec`. Its callback (`on_send_complete`, `http1.c:867-912`) sets
  `_ostr_final.state = OSTREAM_STATE_DONE` and, once the request-body side is also finished
  (`conn->req.proceed_req == NULL`), calls `cleanup_connection` (`http1.c:150-173`).
- `cleanup_connection` is the only place that re-arms reading for a *new* request
  (`conn->req.http1_is_persistent` check at `http1.c:152`, else hard-close). It calls
  `init_request` then `reqread_start` again (`http1.c:161-172`) — which is where any
  already-buffered pipelined bytes for request N+1 finally get parsed and, in turn, its
  handler invoked.

So the invariant is: **exactly one `h2o_req_t` is "live" (parsed-but-not-fully-responded) per
connection at any time**; a second pipelined request can be *parsed into the socket buffer*
early opportunistically is not even done — it stays as raw bytes in `sock->input` until the
prior response fully completes. Response N+1 physically cannot be written before response N
because `_ostr_top`/`_ostr_final` is a single per-connection object reset by `init_request`.

Test coverage: `t_40http1-pipeline.t` (`https://raw.githubusercontent.com/h2o/h2o/master/t/40http1-pipeline.t`)
directly asserts this: two pipelined `GET`s get two well-ordered `200` responses (subtest "2
gets", lines 14-25); a pipelined `POST` with a body followed by a `GET` is used to prove the
server correctly consumes exactly the declared body length before parsing the next pipelined
request-line, for both `Content-Length` (lines 27-40, expects `405` then `200` — `/` is a
static-file mount that doesn't accept `POST`, so this is really testing "framing was correct,
not that parsing derailed") and `Transfer-Encoding: chunked` (lines 42-59) bodies.

## 4. Request-body streaming to the handler, with backpressure

Two entity readers, chosen in `create_entity_reader` (`http1.c:337-363`) from
`init_headers`'s single `entity_header_index` (§7 explains the Content-Length vs.
Transfer-Encoding precedence rule that feeds this):

- **Content-Length**: `create_content_length_entity_reader` (`http1.c:326-335`) +
  `handle_content_length_entity_read` (`http1.c:310-324`). Rejects (400, "broken
  content-length header") if `h2o_strtosize` fails to parse the value
  (`http1.c:349-352`); rejects (413) if the declared length exceeds
  `ctx->globalconf->max_request_entity_size` (`http1.c:354-357`), **before** any body bytes
  are read.
- **Transfer-Encoding: chunked**: `create_chunked_entity_reader` (`http1.c:298-308`) wraps
  picohttpparser's `phr_chunked_decoder` (`decoder.consume_trailer = 1` — trailers are
  consumed/discarded, not exposed to the handler). `handle_chunked_entity_read`
  (`http1.c:268-296`) calls `phr_decode_chunked` and rejects (413) once
  `bufsz + req_body_bytes_received >= max_request_entity_size` (`http1.c:278-281`, checked
  on *every* decode call, so a chunked body is capped by the same limit as Content-Length,
  just enforced incrementally instead of up front), and rejects (400, "broken
  chunked-encoding") on any decode error including the **chunk-overhead DoS guard** built
  into picohttpparser itself: `phr_decode_chunked` (`picohttpparser.c:685-696`) tracks
  `_total_overhead` (all the `\r\n`/size-line/trailer bytes that are *not* payload) and
  `_total_read`; once overhead reaches ≥100 KiB **and** payload is <25% of bytes read
  (`decoder->_total_read - decoder->_total_overhead < decoder->_total_read / 4`), it forces
  an error even though the chunked stream is otherwise syntactically valid — this stops a
  "million 1-byte chunks" amplification attack. Verified against
  `t_80http1-chunk-overhead.t` (lines 43-44), whose comment literally says *"100000 x 1B
  chunks => ok; # below our 100KB threshold"* vs. `1000000 x 1B` → `400`.

  Framing/injection hardening inside `phr_decode_chunked` worth copying:
  chunk-extension lines reject embedded bare `\n` (no line folding,
  `picohttpparser.c:588-598`), the hex chunk-size accumulator caps at
  `sizeof(size_t)*2` hex digits before erroring (`picohttpparser.c:578-581`, prevents
  size_t overflow parsing an absurdly long size line).

Both readers funnel into `handle_one_body_fragment` (`http1.c:235-266`), which is the actual
backpressure choke point:

1. `clear_timeouts(conn)` and **`h2o_socket_read_stop(conn->sock)`** (`http1.c:242-243`) —
   reading from the socket is turned off *before* the fragment is handed to the application.
2. The fragment is copied into `conn->req_body` (`h2o_buffer_try_append`,
   `http1.c:246-249` — returns 502 on allocation failure) and consumed out of `sock->input`.
3. `conn->req.entity` is pointed at the accumulated buffer and
   **`conn->req.write_req.cb(ctx, complete)`** is invoked synchronously (`http1.c:254-255`)
   — this is the push into the handler.
4. Reading is only resumed when the handler calls back through one of two paths:
   - **Non-streaming mode** (`write_req_non_streaming`, `http1.c:586-597`): if not yet
     end-of-body, it calls `resume_request_read` (`http1.c:564-569`), which re-arms both
     timers and calls `h2o_socket_read_start` again — i.e. **the handler must return control
     before the next fragment is read; there is no read-ahead.** If it *is* end-of-stream,
     `h2o_process_request` is invoked with the complete body already buffered (classic
     buffer-then-process).
   - **Streaming mode** (chosen when `h2o_req_can_stream_request()` is true,
     `write_req_first`, `http1.c:599-613`): `h2o_process_request` is called immediately with
     a *partial* body and `conn->req.proceed_req = proceed_request`
     (`http1.c:571-584`). The generator (handler-side consumer) must eventually call
     `req->proceed_req(req, errstr)`, which is `proceed_request` — it asserts the generator
     consumed exactly `req_body->size` bytes (`assert(conn->req.entity.len ==
     conn->req_body->size)`, `http1.c:580`), drains the buffer, and *only then*
     `resume_request_read`s. This is a strict one-fragment-in-flight, pull-driven flow
     control: **the h2o core will not read another byte off the wire until the application
     has both consumed and acknowledged the previous fragment.** `h2o.h:1183-1189`
     documents the contract explicitly: *"Once `write_req.cb` is called, subsequent
     invocations MUST be postponed until the `proceed_req` is called."*
5. `entity_read_do_send_error` (`http1.c:206-223`) is the uniform "abort mid-body" path used
   by all the 400/413/502 helpers: it always `h2o_socket_read_stop`s first.

There is no bounded byte-count queue analogous to chez-libuv's "no bounded write queue"
design (ADR-0018) on the *read* side either — h2o's equivalent of a read-side flow-control
signal is simply "is `read_stop` currently in effect", exactly one fragment (whatever
`h2o_buffer_try_reserve`'s growth policy handed back from a single `read()`/`recv()` syscall,
capped by `h2o_evloop_socket_max_read_size = 1MB` by default, `evloop.c.h:115`) outstanding at
a time.

## 5. Response-body streaming out, with backpressure

Two structural guarantees enforce single-write-in-flight:

- `h2o_socket_write` and `h2o_socket_sendvec` both `assert(sock->_cb.write == NULL)`
  (`socket.c:923-924`, `socket.c:940-941`) — **it is a programming-error-level invariant
  that a second write cannot be issued while one is outstanding.** `on_write_complete`
  (`socket.c:985-996`) clears `_cb.write` to `NULL` before invoking the completion callback,
  so the very next thing that callback does is typically issue the next write.
- The wire-level writer, `finalostream_send` (`http1.c:1042-1115`), is `do_send` for the
  connection's single `_ostr_final` ostream. It is called by the generator via
  `h2o_send`/`h2o_sendvec` → `h2o_ostream_send_next` → `_ostr_top->do_send` chain
  (`h2o.h:1629-1700`). On `OSTREAM_STATE_HEAD` it flattens response headers
  (`flatten_headers`, `http1.c:965-988`) into the first `iovec`; if chunked, it prepends a
  hex chunk-size line and appends the trailer/terminator via `encode_chunked`
  (`http1.c:1016-1040`); it then calls `h2o_socket_sendvec(... on_send_next_or_complete)`
  (`http1.c:1113-1114`).
  - Callback selection is the actual **pull mechanism**:
    `h2o_send_state_is_in_progress(state) ? on_send_next : on_send_complete`. `on_send_next`
    (`http1.c:840-853`) — used when the generator supplied a partial chunk
    (`H2O_SEND_STATE_IN_PROGRESS`) — on success calls **`h2o_proceed_response(&conn->req)`**,
    which (`h2o.h:2494-2500`) invokes `req->_generator->proceed(...)`: **the core does not ask
    for more data until the previous write has fully drained through the kernel socket
    buffer.** This is precisely a pull/backpressure model symmetric to the read side in §4.
  - `on_send_next` also re-arms the I/O timeout on `h2o_socket_error_write_progress`
    (`http1.c:844-846`) — a partial-write progress notification (see evloop `write_pending`,
    §5b) keeps the connection alive without hitting the I/O timeout as long as *some* bytes
    are draining, even if the full buffer hasn't gone out yet.
- **Informational (1xx) responses share the same single-write-in-flight discipline** but are
  queued explicitly because they can be triggered by the handler at arbitrary times relative
  to an in-flight final-response write: `finalostream_send_informational`
  (`http1.c:1150-1176`) appends to `informational.pending` and only calls
  `do_send_informational` if no informational write is currently in flight
  (`informational.write_inflight`, `http1.c:1119-1127`); if the *final* response's `do_send`
  is called while an informational write is still in flight, it doesn't race the socket —
  it stashes the final-response buffers in `informational.pending_final` and returns
  (`http1.c:1052-1058`), to be flushed from `on_send_informational_complete`
  (`http1.c:1129-1148`) once the in-flight informational write completes.

### 5b. Socket-layer write mechanics (evloop backend; `lib/common/socket/evloop.c.h`)

This is the piece closest to what our chez-libuv-based writer will need to replicate
(chez-libuv is closer architecturally to h2o's *libuv* backend, `uv-binding.c.h`, but the
evloop backend documents the backpressure logic more explicitly because it hand-rolls
non-blocking I/O instead of delegating to libuv's own write queue):

- `write_vecs` (`evloop.c.h:174-211`) calls `sendmsg()` non-blocking; on `EAGAIN` it returns
  `0` bytes-written-of-first-buffer and the event loop leaves the socket registered for
  writability (`link_to_statechanged`, driven from `write_pending`,
  `evloop.c.h:314-356`) so the write resumes on the next writable edge — no busy-polling.
- `write_pending` (`evloop.c.h:314-356`) is the reentry point invoked on every writable
  event: if the write did not fully drain, it advances `bufs[0].base/len` by the
  partial-write amount and returns (`evloop.c.h:328-331`) without notifying the app; only
  once `_write_buf.cnt == 0` (all buffers fully written) does it notify completion by
  scheduling the socket onto the loop's "pending" list (`evloop.c.h:348-355`), which is
  where `on_write_complete` (and thus `h2o_proceed_response`) ultimately fires from.
- `h2o_evloop_socket_max_read_size` / `_max_write_size` default to **1 MiB** each
  (`evloop.c.h:115-116`) — the per-syscall cap on how much a single readable/writable event
  will move, independent of the request/body-size limits in §6.
- Reads: `on_read_core` (`evloop.c.h:138-172`) reads into `h2o_buffer_try_reserve`'d space in
  up-to-4 KiB increments per iteration, looping until `EAGAIN`, EOF, or `max_bytes` (the
  1 MiB cap) is reached — i.e. one readable event can still deliver up to 1 MiB into the
  input buffer before yielding back to the loop, unlike the strict one-fragment-then-read-
  stop discipline http1.c imposes at the *application* layer (§4); the two layers compose:
  the socket layer will happily buffer up to 1 MiB in a single epoll-readable callback, but
  http1.c's `handle_one_body_fragment` still calls `read_stop` synchronously as soon as it
  hands the first slice to the handler, so in practice the handler sees fragments no larger
  than whatever a single `recv()` burst returned before http1.c got control back.

## 6. Named limits and timeouts (with default numbers)

All defaults are `#define`s pulled in from `include/h2o.h` (fetched copy `h2o.h`, see also
the sparse-clone search that located the header/socket-specific ones not present in
`include/h2o.h` itself) and assigned into `h2o_globalconf_t` by `h2o_config_init` in
`lib/core/config.c` (fetched copy `config.c:180-191`).

| Name | Default | Where defined | Where assigned | Applies to |
|---|---|---|---|---|
| `H2O_DEFAULT_HTTP1_REQ_TIMEOUT` | **10,000 ms** (10 s) | `h2o.h:79-80` | `config.c:184` → `config->http1.req_timeout` | Time allowed for a full request line+headers to arrive (armed by `set_req_timeout`/`resume_request_read`/`reqread_start`, `http1.c:178-187,564-569,831-838`); on expiry, `reqread_on_timeout`→`on_timeout` (`http1.c:804-829`) **silently closes** — see §8, no response bytes are sent |
| `H2O_DEFAULT_HTTP1_REQ_IO_TIMEOUT` | **5,000 ms** (5 s) | `h2o.h:81-82` | `config.c:185` → `config->http1.req_io_timeout` | Re-armed on *every* read or (partial) write progress event during body read (`http1.c:790`) or response write (`http1.c:845,872,1111`); expiry → `req_io_on_timeout`→`on_timeout`, same silent-close behavior |
| `H2O_DEFAULT_MAX_REQUEST_ENTITY_SIZE` | **1,073,741,824 bytes** (1 GiB = `1024*1024*1024`) | `h2o.h:74` | `config.c:180` | Cap on request body, both Content-Length (checked up front, `http1.c:354-357`) and chunked (checked incrementally, `http1.c:278-281`) → `413` |
| `H2O_MAX_HEADERS` | **100** | `include/h2o/header.h:37` (found via sparse-clone `rg`, not in `include/h2o.h`) | compile-time constant, used directly | Max header *fields* picohttpparser will parse per request (`struct phr_header headers[H2O_MAX_HEADERS]`, `http1.c:630-631`) |
| `H2O_MAX_REQLEN` | **417,792 bytes** (`8192 + 4096*100`, ≈408 KiB) | `include/h2o/header.h:45` | compile-time constant | Max combined size of the request-line + header block picohttpparser will scan (`http1.c:628`); exceeding it while still incomplete → **400 Bad Request**, *not* 431 (see §8) |
| `H2O_DEFAULT_HANDSHAKE_TIMEOUT` | **10,000 ms** (10 s) | `h2o.h:77-78` | `config.c:183` | TLS handshake timeout (not HTTP/1-specific, but gates the accept path before `h2o_http1_accept`) |
| `h2o_evloop_socket_max_read_size` | **1,048,576 bytes** (1 MiB) | `evloop.c.h:115` | module-global, overridable at runtime | Per-readable-event cap on bytes pulled off the socket |
| `h2o_evloop_socket_max_write_size` | **1,048,576 bytes** (1 MiB) | `evloop.c.h:116` | module-global | **Fairness cap, not a per-syscall cap**: `do_write` (`evloop.c.h:415-428`) tracks cumulative bytes written per connection *within the current `h2o_evloop_run` iteration* (`bytes_written.cur_loop/prev_loop/cur_run_count`) and, once a connection has written ≥1 MiB in this loop pass, defers further writes until the next writable-event notification instead of looping immediately — this stops one write-heavy connection from starving the rest of the event loop within a single pass |
| `H2O_SOCKET_INITIAL_INPUT_BUFFER_SIZE` | **4096 bytes** | `include/h2o/socket.h:105` (sparse-clone) | `socket.c:182-184`, `h2o_socket_buffer_prototype` | Minimum initial capacity of the per-socket `h2o_buffer_t` (comment: actual initial allocation is "~8KB", see `h2o_buffer_reserve`) |
| picohttpparser chunked-overhead guard | **102,400 bytes (100 KiB) total overhead AND overhead > 75% of bytes read** (payload < 25%) | `picohttpparser.c:691-696` | n/a (unconditional) | Anti-DoS guard against many tiny chunks; not configurable |
| `H2O_PULL_SENDVEC_MAX_SIZE` | **65,536 bytes** (64 KiB) | `include/h2o/socket.h:82` (sparse-clone) | — | Max size of a single "pull"-mode sendvec that `h2o_socket_sendvec` will flatten into a temp buffer for TLS encryption (`socket.c:960`) |
| `H2O_DEFAULT_MAX_DELEGATIONS` / `_MAX_REPROCESSES` | **5 / 5** | `h2o.h:75-76` | `config.c:181-182` | Internal request-reprocessing loop guards (mod_rewrite-style), not connection-layer per se, listed for completeness |

Notably **absent** as a distinct, named default anywhere in `include/h2o.h`, `lib/http1.c`, or
`lib/common/socket.c`/`evloop.c.h`: an idle/keep-alive timeout specific to HTTP/1 waiting
*between* requests. `req_timeout` (10 s) is reused for both "waiting for the first byte of a
new request on an otherwise-idle persistent connection" and "still assembling headers of an
in-progress request" — `resume_request_read` and `reqread_start` both arm it identically
(`http1.c:566-569` vs `831-838`), and `cleanup_connection` doesn't set a longer timeout for
the idle-between-requests case. So h2o's *effective* keep-alive idle timeout for HTTP/1 is
just 10 seconds by default, same as its header-read timeout — worth deciding explicitly for
chez-http-server rather than silently inheriting.

## 7. Framing precedence: Content-Length vs. Transfer-Encoding, duplicates, HEAD, 1xx/204/304

All decided inside `init_headers` (`http1.c:365-418`), which single-passes picohttpparser's
`headers[]` array and maintains one `*entity_header_index` slot:

```c
} else if (name_token == H2O_TOKEN_CONTENT_LENGTH) {
    if (*entity_header_index == -1)
        *entity_header_index = i;
} else if (name_token == H2O_TOKEN_TRANSFER_ENCODING) {
    *entity_header_index = i;
}
```
(`http1.c:393-397`)

Consequences, traced precisely:
- **Duplicate `Content-Length` headers**: only the **first** occurrence's index is ever
  recorded (`if (*entity_header_index == -1)` — subsequent Content-Length headers are simply
  never looked at again for framing purposes). h2o does **not** compare the values or reject
  the request for conflicting duplicate Content-Length headers — this is a known
  request-smuggling vector per RFC 9112 §6.3, which says a server "MUST reject" a message
  with multiple different Content-Length values. **h2o's http1.c does not do this
  validation at all**; it silently uses whichever value appeared first in header order.
  (A single header line with comma-joined values like `Content-Length: 5, 5` *would* fail,
  because `h2o_strtosize` on `"5, 5"` can't parse to a `size_t` and hits the `400 "broken
  content-length header"` path at `http1.c:349-352` — but that's a parse artifact, not a
  deliberate duplicate-value check.)
- **`Transfer-Encoding` always wins if present**, regardless of order relative to
  `Content-Length`, because its branch unconditionally overwrites `*entity_header_index`
  (no `if (*entity_header_index == -1)` guard) — so `Content-Length: 10\r\nTransfer-Encoding:
  chunked` *and* `Transfer-Encoding: chunked\r\nContent-Length: 10` both end up using the
  **chunked** reader. This matches RFC 7230/9112's stated precedence rule, but h2o does not
  additionally *reject* the ambiguous message (as RFC 9112 §6.3 recommends when both are
  present and the message isn't going through a trusted normalizing proxy) — it just quietly
  picks Transfer-Encoding and never surfaces the conflict.
- **Unknown Transfer-Encoding token**: `create_entity_reader` (`http1.c:340-346`) rejects
  (400, "unknown transfer-encoding") anything that isn't exactly `"chunked"`
  (case-insensitive `h2o_lcstris`) — no support for a second/identity coding, no
  comma-separated list handling.
- **HEAD**: `should_use_chunked_encoding` (`http1.c:990-1006`) returns 0 for HEAD
  (`h2o_memis(method, "HEAD")`, `http1.c:1002-1003`), so no `Transfer-Encoding: chunked`
  header is ever added to a HEAD response. But `flatten_headers` (`http1.c:965-988`) still
  writes a `Content-Length:` header whenever `req->res.content_length != SIZE_MAX`
  regardless of method — so if the handler/generator sets a content length for a HEAD
  response (the normal, correct thing to do — advertise the length the GET would have had),
  it's emitted verbatim; **it is the handler's/generator's job to never actually push body
  bytes for HEAD**, http1.c itself doesn't special-case suppressing a body write for HEAD.
- **1xx / 204 / 304**: also excluded from chunked framing by the same
  `should_use_chunked_encoding` checks (`http1.c:999-1001`,
  `100 <= status <= 199 || status == 204 || status == 304`). 1xx responses go through the
  entirely separate `finalostream_send_informational` path (`http1.c:1150-1176`), which
  never adds Transfer-Encoding or Content-Length framing at all — just status line + whatever
  headers the handler set + blank line.
- **No `Content-Length` known and not chunk-eligible** (i.e., HTTP/1.0, or a 1xx/204/304/HEAD
  response): `flatten_headers` simply omits `Content-Length` (the `if (content_length !=
  SIZE_MAX)` branch at `http1.c:973-978`); for HTTP/1.0 this becomes a close-delimited
  response, consistent with §2.

## 8. Error mapping (parse / policy / handler errors → responses) and close behavior

Every HTTP/1-layer error in `http1.c` funnels through `h2o_send_error_generic` (declared
`h2o.h:1890`, defined `lib/core/request.c:654-679`, sparse-clone), which is what actually
sets `req->http1_is_persistent = 0` when the caller passes the
`H2O_SEND_ERROR_HTTP1_CLOSE_CONNECTION` flag (`request.c:666-667`):

```c
if ((flags & H2O_SEND_ERROR_HTTP1_CLOSE_CONNECTION) != 0)
    req->http1_is_persistent = 0;
```

Status codes h2o's HTTP/1 connection layer can itself emit, all found in `http1.c`, and all
of them pass `H2O_SEND_ERROR_HTTP1_CLOSE_CONNECTION` (confirmed by reading every call site):

| Status | Trigger | Call site |
|---|---|---|
| **400** Bad Request | Unparseable request line/headers (`phr_parse_request` returns -1, not HTTP/2 preface, more than 4 bytes or non-CRLF garbage) | `send_bad_request` → `http1.c:558-562`, called from `http1.c:672`, `687` |
| **400** | `H2O_MAX_REQLEN` reached while still incomplete (headers too large) | `http1.c:648-650` → `send_bad_request` |
| **400** | Broken/unparseable `Content-Length` value | `entity_read_send_error_400`, `http1.c:349-352` |
| **400** | Unknown `Transfer-Encoding` token | `http1.c:342-344` |
| **400** | Broken chunked-encoding (incl. the picohttpparser overhead-DoS guard, §4) | `http1.c:288` |
| **400** | Malformed H2-upgrade request | `http1.c:697` (`h2o_send_error_400`, flags=`0` here — no explicit close flag passed, but the connection is abandoned anyway since it's mid-h2-upgrade) |
| **413** Payload Too Large | Content-Length exceeds `max_request_entity_size` | `entity_read_send_error_413`/`http1.c:354-357` (up front) and `http1.c:278-281` (incrementally for chunked) |
| **417** Expectation Failed | `Expect:` header present with a value other than `100-continue` | `http1.c:711-718` |
| **405** Method Not Allowed | `CONNECT` request where the connection can't be switched to streaming mode (`h2o_req_can_stream_request` false) | `http1.c:746-751` |
| **502** Bad Gateway | `h2o_buffer_try_append` OOM while buffering a body fragment, or `write_req.cb` returning non-zero (proxy/handler signaling failure while consuming a streamed body) | `entity_read_send_error_502`, `http1.c:247,256`, and the `proceed_request` errstr path, `http1.c:575-578` |

**Never emitted anywhere in `include/h2o.h` or `lib/*` (confirmed by grepping the sparse
clone for the literal numbers)**: **408 Request Timeout, 501 Not Implemented, 505 HTTP
Version Not Supported, 431 Request Header Fields Too Large.** Specifically:
- `H2O_STATUS_ERROR_*` enum (`include/h2o.h:630-642`, sparse-clone) only has
  400/401/403/404/405/413/416/417/421/500/502/503 — there is no 408/431/501/505 member,
  and no `H2O_SEND_ERROR_XXX(...)` macro instantiation for any of them
  (`include/h2o.h:1899-1911`, sparse-clone) — meaning **the helper functions to send those
  statuses don't even exist** in this codebase.
- **Timeout ⇒ silent close, not 408.** `on_timeout` (`http1.c:804-815`): on the very first
  request (`_req_index == 1`) it does bookkeeping so the connection *can be logged*
  (`h2o_req_setup`/`h2o_req_bind_conf`, and sets `req.res.reason = "Request Timeout"` purely
  for the access-log reason string) but then just calls `close_idle_connection` →
  `close_connection(conn, 1)` (`http1.c:797-802`, `134-148`) — **no bytes are written to the
  client.** A slow/idle client simply sees its TCP connection reset/closed with zero HTTP
  response, not a `408` status line.
- **Oversized request-line/headers ⇒ 400, not 431.** `http1.c:648-650` explicitly sends
  `send_bad_request(conn, "Bad Request")` (which is the 400 helper) when `H2O_MAX_REQLEN` is
  hit — h2o predates RFC 6585 431 in this code path and never migrated it.
- **No version validation ⇒ never 505.** As noted in §2, `fixup_request` folds every
  non-zero minor version into "1.1" (`http1.c:438`) and there is no rejection path for an
  unrecognized/too-high HTTP version.

**Lesson for us, explicitly**: h2o's error surface at the connection layer is intentionally
narrow (essentially: 400 for anything protocol-broken, 413 for oversized body, 417 for a bad
Expect, 405 for a body-less CONNECT edge case, 502 for internal buffering/handler failure) and
it treats timeouts and oversized-header-block as reasons to *just disappear* rather than speak
a final status line. If chez-http-server wants friendlier behavior (408 on idle timeout, 431
on oversized headers) that is a deliberate **departure** from h2o, not something to copy
blindly — but it should be a conscious choice, made knowing h2o (a security-conscious,
widely-deployed C server) chose the terser behavior.

## 9. Expect: 100-continue

Handled inline in `handle_incoming_request`, only reached for requests that have a body
(`entity_body_header_index != -1`), at `http1.c:711-739`:

1. If `Expect:` is present but its value isn't case-insensitively `"100-continue"`
   (`h2o_lcstris`, `http1.c:713`) → **417 Expectation Failed**, connection closed
   (`http1.c:714-717`).
2. **Reverse-proxy "forward" mode** (`h2o_req_should_forward_expect`, `http1.c:719`): the
   `Expect` header is re-added to `req.headers` as an ordinary header (so it gets forwarded
   verbatim to the upstream, which is then responsible for deciding whether/when to emit its
   own 100-continue) and processing jumps straight to `ProcessImmediately`
   (`http1.c:720-727`) — **h2o itself never writes a 100-continue in this mode.**
3. **Otherwise (origin-serving / non-forward mode)**: h2o **unconditionally and immediately**
   writes a **hardcoded** `"HTTP/1.1 100 Continue\r\n\r\n"` literal (`http1.c:731-732`) —
   note it's literally `"HTTP/1.1"` regardless of the client's actual minor version — via
   `h2o_socket_write(..., on_continue_sent)`, and **stops reading** until that write
   completes (`http1.c:733-734`). There is **no hook for the handler to inspect the request
   first and decide whether to allow the body** (e.g., to reject on auth/size grounds before
   the client uploads anything) in origin mode — the continue is sent optimistically, before
   `h2o_process_request` is even called. `on_continue_sent` (`http1.c:537-548`) then resumes
   reading and immediately drives the entity reader for whatever body bytes have already
   started arriving.
4. If there's no `Expect` header at all, the body read just starts immediately
   (`http1.c:735-738`).

Test coverage: `t_40expect.t` spawns an actual upstream and drives both a streaming
(reverse-proxy) and non-streaming (mruby handler reading `rack.input`) path with
`curl -H "expect: 100-continue"`, asserting the response contains both a `100` and the final
status line (lines 36-43) — i.e. it specifically checks that **both** code paths (§9.2/§9.3)
end up producing a visible 100-continue on the wire from the client's perspective, even though
internally one of them is a pass-through and the other is h2o originating it itself.

## 10. Upgrade / CONNECT

- **`CONNECT`** (`http1.c:444-445`, `475-483`): validated strictly — requires HTTP/1.1
  (`version >= 0x101`), a non-empty path, that if a `Host:` header is present it matches the
  CONNECT target exactly (`h2o_memis`), and that **no** entity header (Content-Length/
  Transfer-Encoding) is present (`*entity_header_index != -1` ⇒ reject) — any violation is a
  generic `"invalid request"` error (→ eventually a 400 via `send_bad_request`, since
  `fixup_request`'s non-NULL, non-h2-upgrade-sentinel return value is treated as a parse
  error by its caller at `http1.c:684-689`). On success, the target becomes
  `req.input.authority`, `req.input.path` is cleared, and `req.is_tunnel_req = 1`.
- **`CONNECT-UDP`** (`http1.c:446-447`, `500-502`): same tunnel flag, but skipped the
  strict CONNECT-specific validation (host/path/entity-header checks) — falls through the
  "ordinary request" branch instead, just setting `is_tunnel_req = 1`.
- **`Upgrade:` header** (e.g. WebSocket): only honored when `Connection:` contains the
  `upgrade` token **and** there's no entity header (§2's constraint, `http1.c:510-522`).
  `upgrade_is_h2` (`http1.c:420-426`) special-cases `h2c`/`h2c-14`/`h2c-16` — those trigger an
  **entirely separate path**: `fixup_request` returns the sentinel
  `fixup_request_is_h2_upgrade` (`http1.c:428,514-517`), and the caller
  (`handle_incoming_request`, `http1.c:692-699`) hands the raw socket off to
  `h2o_http2_handle_upgrade` — HTTP/1.c's connection object is essentially bypassed for h2c.
  Any *other* upgrade token becomes `req.upgrade = upgrade; req.is_tunnel_req = 1;
  req.http1_is_persistent = 0` (`http1.c:519-522`) — an upgraded connection is *never*
  eligible for further keep-alive/pipelining on the HTTP/1 side by construction.
- **Both CONNECT and non-h2c Upgrade set `is_tunnel_req`**, which changes the *body handling*
  policy: instead of Content-Length/chunked framing, a `content_length_entity_reader` is
  created with length `SIZE_MAX` (`create_content_length_entity_reader(conn, SIZE_MAX)`,
  `http1.c:753`) — i.e., "treat everything from here to socket close/handoff as body," and
  processing begins immediately (`goto ProcessImmediately`, `http1.c:758`) rather than
  waiting for a declared length.
- **The actual protocol hand-off**, `h2o_http1_upgrade` (`http1.c:1341-1359`): flattens the
  final response headers (with `Connection: upgrade` if status is 101, else `Connection:
  close`, `http1.c:1355`), writes them plus any caller-supplied extra buffers
  (`h2o_socket_write(... on_upgrade_complete)`), and on completion
  (`on_upgrade_complete`, `http1.c:914-932`) **detaches the raw `h2o_socket_t`** from the
  h2o connection object (`close_connection(conn, 0)` — note the `0`, meaning *don't* close
  the fd) and hands `(sock, headers_size)` to the caller's `h2o_http1_upgrade_cb`, where
  `headers_size = conn->_unconsumed_request_size` — the byte count of the original request
  headers still sitting at the front of `sock->input`, so the WebSocket/tunnel handler on the
  other end knows how many leading bytes to skip to reach the first real
  tunnelled/protocol-specific byte (which may already be buffered if the client pipelined
  eagerly). **This "steal the socket, hand back a byte-offset into whatever's already
  buffered" pattern is the cleanest single idea to copy** for our own upgrade support.

## 11. Close / shutdown protocol

- **No lingering close is implemented for HTTP/1** — this is explicit in the source, not
  inferred: `cleanup_connection` (`http1.c:150-156`):
  ```c
  if (!conn->req.http1_is_persistent) {
      /* TODO use lingering close */
      close_connection(conn, 1);
      return;
  }
  ```
  `close_connection(conn, 1)` (`http1.c:134-148`) unlinks both timers, disposes the request
  body buffer and request pool, and calls `h2o_socket_close(sock)` — which for a plaintext
  (non-TLS) socket goes straight to `dispose_socket` (`socket.c:503-...`, referenced from
  `h2o_socket_close`, `socket.c:627-638`) and, in the evloop backend,
  `do_dispose_socket`→`evloop_do_on_socket_close` (`evloop.c.h:382-...`,
  `epoll.c.h:281-306` in the sparse clone) which **closes the fd immediately**
  (`close(sock->fd)`) — the *only* lingering-like behavior anywhere in the socket layer is
  for **zero-copy (`MSG_ZEROCOPY`) buffer reclamation**: if there are zero-copy buffers still
  in flight, it does `shutdown(fd, SHUT_RDWR)` and polls (edge-triggered) until the kernel's
  completion notifications drain, purely to safely free the zero-copy memory — **not** to
  drain/discard unread client bytes or avoid a TCP RST on unread data. h2o closes the write
  side abruptly whenever `http1_is_persistent` is false, with the well-known risk that if the
  client has unread queued data or is still sending when the FIN/RST lands, the response
  may be lost or the client sees a connection reset. There is no explicit `SO_LINGER`
  configuration visible in the fetched files either.
- **No half-close (`CLOSE_WAIT`-style) support** is implemented for ordinary HTTP/1 request/
  response cycles — reading and writing are torn down together via the single
  `close_connection`/`h2o_socket_close` call; the only place a "close write side but keep
  read side open" pattern is used is the zero-copy reclamation case above, which is a socket-
  layer implementation detail, not an application-visible half-close feature.
- **Graceful shutdown** (SIGTERM-style drain) is a two-part protocol:
  1. `h2o_context_request_shutdown` (`lib/core/context.c:267-274`, sparse-clone) sets
     `ctx->shutdown_requested = 1` and calls every live connection's
     `callbacks->request_shutdown`. For HTTP/1 that callback is
     `initiate_graceful_shutdown` (`http1.c:1270-1273`), which is **explicitly a no-op**:
     `/* note: nothing special needs to be done for handling graceful shutdown */`. The real
     effect is indirect: the next time `fixup_request` runs for *any* request on *any*
     connection, `ctx->shutdown_requested` is checked and forces
     `http1_is_persistent = 0` (`http1.c:529-530`) — so **in-flight requests are always
     allowed to complete and get one final `Connection: close` response**; no request is
     aborted mid-flight purely because shutdown was requested.
  2. `h2o_context_close_idle_connections` (`lib/core/context.c:289-306`, sparse-clone) is a
     separate, explicitly-invoked sweep (not automatically triggered by
     `request_shutdown`) that walks the **idle** connection list only (`ctx->_conns.idle`,
     i.e. connections currently between requests, `H2O_CONN_STATE_IDLE`) and calls
     `close_idle_connection` (the HTTP/1 implementation, `http1.c:797-802`, which forces
     `http1_is_persistent = 0` and calls `close_connection(conn, 1)` — the same abrupt,
     non-lingering close as above) on up to `max_connections_to_close` of them that are older
     than `min_age`. This is how a shutting-down process reclaims connections that are
     sitting idle waiting for a next pipelined request that may never come, without waiting
     out a full keep-alive timeout.
  - `h2o_conn_set_state(&conn->super, H2O_CONN_STATE_IDLE)` is set by `cleanup_connection`
    only when `conn->sock->input->size == 0` after finishing a response (`http1.c:169-170`)
    — i.e. a connection only becomes "idle" (and thus eligible for the shutdown sweep) once
    there's genuinely nothing left buffered to process; a connection with a pipelined request
    already sitting in `sock->input` stays `H2O_CONN_STATE_ACTIVE` and is left alone by the
    idle-sweep (it'll get the `Connection: close` treatment via path 1 instead once that
    request is parsed).

## 12. Application handler API shape

The "handler" boundary in h2o is deliberately protocol-agnostic (shared across HTTP/1, H2,
H3) — `http1.c` implements the HTTP/1-specific plumbing on both sides of two symmetric,
pull-based (well-timed, backpressure-respecting) callback contracts:

**Inbound (request body → handler)**, from `include/h2o.h` (sparse-clone, cited above,
`1183-1195`) and `http1.c`'s implementation of it:
```c
typedef int  (*h2o_write_req_cb)(void *ctx, int is_end_stream);   /* core -> handler push */
typedef void (*h2o_proceed_req_cb)(h2o_req_t *req, const char *errstr); /* handler -> core resume */
```
`req->write_req = {cb, ctx}`; `req->proceed_req` starts NULL and, if the handler opts into
streaming (`h2o_req_can_stream_request`), is set to non-NULL and becomes the handler's
required "I'm done with this fragment, give me more (or finish)" signal
(`http1.c:571-624,599-613`). Contract, as documented right at the typedef: once
`write_req.cb` is called, the core will not call it again until `proceed_req` fires — this
is the read-side backpressure contract described mechanically in §4.

**Outbound (handler → response body)**, `include/h2o.h:850-889` (sparse-clone):
```c
typedef struct st_h2o_generator_t {
    void (*proceed)(h2o_generator_t *self, h2o_req_t *req); /* core -> handler: "send more" */
    void (*stop)(h2o_generator_t *self, h2o_req_t *req);    /* core -> handler: abort */
} h2o_generator_t;

struct st_h2o_ostream_t {
    struct st_h2o_ostream_t *next;
    void (*do_send)(h2o_ostream_t *self, h2o_req_t *req, h2o_sendvec_t *bufs, size_t bufcnt,
                     h2o_send_state_t state);
    void (*stop)(h2o_ostream_t *self, h2o_req_t *req);
    void (*send_informational)(h2o_ostream_t *self, h2o_req_t *req);
};
```
A handler calls `h2o_start_response(req, generator)` once it has status+headers ready, then
`h2o_send`/`h2o_sendvec(req, bufs, cnt, state)` (`h2o.h:1668-1676`) any number of times with
`state ∈ {IN_PROGRESS, FINAL, ERROR}` — and **must wait** for the core to call
`generator->proceed` again (driven, at the HTTP/1 layer, from `h2o_proceed_response` inside
`on_send_next`, `http1.c:840-853` → `h2o.h:2494-2500`) before sending the next chunk. This is
exactly the write-side backpressure contract in §5: the transport won't ask for more until
the kernel socket buffer has actually accepted the previous chunk.

This generator/ostream chain is also h2o's mechanism for *filters* (e.g. its `compress`
module, `h2o.h:2073-2102`) — `do_send` is explicitly allowed to be an intermediary that
transforms and forwards via `h2o_ostream_send_next`, meaning HTTP/1's `finalostream_send`
(§5) is not necessarily the first `do_send` a chunk hits; it's just always the *last* one
(`conn->req._ostr_top` starts pointed at it, `init_request`/`http1.c:123`, and filters
prepend themselves in front).

## 13. What h2o's own test suite covers (files, verbatim behavior asserted)

All fetched from `https://raw.githubusercontent.com/h2o/h2o/master/t/<name>`:

- **`t/40http1-pipeline.t`** (74 lines) — two back-to-back `GET`s on one connection get two
  ordered `200`s; a pipelined `POST` (both `Content-Length`-framed and
  `Transfer-Encoding: chunked`-framed) followed immediately by a `GET` proves the server
  consumed exactly the declared body before parsing the next request-line (§3).
- **`t/40expect.t`** (45 lines) — `Expect: 100-continue` against both a streaming
  (reverse-proxy) and non-streaming (mruby `rack.input`) handler path, via the
  `h2o-httpclient` test binary and `curl`; asserts a `100` line is seen before the final
  status in both modes (§9).
- **`t/40http1-timeouts.t`** (64 lines) — configures
  `http1-request-io-timeout: 2` / `http1-request-timeout: 5` against a slow-writing upstream
  (Perl PSGI handler that `sleep`s between writes) and asserts via `curl -v` stderr that a
  response that stalls long enough gets cut off ("transfer closed with outstanding read data
  remaining") vs. one that keeps the connection alive ("Connection ... left intact") — this
  is a real end-to-end proof that `req_io_timeout` is measured **per write/flush progress**,
  not just once for the whole response, matching the `on_send_next` re-arming logic in §5.
- **`t/40http1-streaming-framing.t`** (50 lines) — proxies a 50 MiB upload two ways
  (`--http1.1` default vs. explicit `-H transfer-encoding:chunked`) and inspects what framing
  header the **upstream** actually receives, proving h2o preserves/chooses
  Content-Length-vs-chunked framing correctly when acting as a client too (relevant context,
  though this is h2o's HTTP/1 *client* code, not `lib/http1.c`).
- **`t/40chunked.t`** (64 lines) — two subtests: "push mode" (reverse-proxied streaming
  response) asserts the client sees valid `transfer-encoding: chunked` framing with correctly
  sized hex chunk headers reconstructing the exact original content; "pull mode" (static file
  + `server-timing: enforce`, which forces chunked even for a file whose length is known,
  specifically to allow a trailer) asserts the trailer (`server-timing: ...`) appears after
  the terminating `0\r\n` chunk, matching `encode_chunked`'s trailer logic (`http1.c:1016-
  1040`, `send_trailers` parameter).
- **`t/80http1-chunk-overhead.t`** (71 lines) — the chunk-overhead DoS guard test (§4):
  sweeps chunk-size/count/extension combinations and asserts exactly where h2o's
  100 KiB/80%-overhead threshold in picohttpparser (`picohttpparser.c:691-696`) starts
  rejecting (`400`) vs. accepting (`200`) — including a case with a **1 KiB chunk-extension**
  string per chunk (`"; ext=" . "x" x 1000`) to prove chunk-extension bytes count toward the
  "overhead" accounting, not just the size-line/CRLF framing bytes.
- **`t/99fuzzer-http1.t`** (6 lines) — a one-line wrapper (`exec_fuzzer('http1')`) around a
  libFuzzer/AFL-style harness (not fetched in full; the harness infrastructure lives
  elsewhere in `t::Util` and `fuzz/`) — confirms h2o maintains a dedicated fuzz target for
  the HTTP/1 parse path specifically, which is directly analogous to what our project
  already has for chez-httparse (274 llhttp fixtures + differential fuzzing per the
  PROJECT CONTEXT) — nothing new to copy mechanically, but validates that continuous fuzzing
  of the byte-machine-driven parser is exactly the kind of investment a serious HTTP/1
  implementation makes.
- **`t/00unit/lib/common/socket.c`** exists (listed via GitHub API,
  `t/00unit/lib/common/socket.c`) as a unit-test target for the socket abstraction, separate
  from the integration tests above; I did not fetch its contents (out of budget for this
  pass) but flag it as a further citation source if a future pass wants unit-level socket
  read/write-backpressure test cases rather than end-to-end ones.

Additional files present in `t/` but not fetched in this pass (noted for completeness /
future follow-up): `t/50reverse-proxy-expect-100-continue.t`,
`t/50reverse-proxy-chunk-timeout-{1,2}.t`, `t/50reverse-proxy-chunked-post-termination.t`,
`t/50reverse-proxy-disconnected-keepalive.t`, `t/50unexpected-upstream-body.t`,
`t/80reverse-proxy-truncated-chunked.t` — these are all reverse-proxy-side (h2o as HTTP
*client*) tests of the same framing/timeout concerns, listed by the `t/` directory API
listing but out of scope for "h2o as an HTTP/1 *server*" per the task.

---

## Lessons for chez-http-server (concrete, citation-backed)

1. **Single-request-in-flight per connection is enough for pipelining correctness.** Don't
   build a response-reordering queue for HTTP/1.1 pipelining — just don't start handling
   request N+1 until response N is fully written (h2o: `cleanup_connection` only re-arms
   reading after `on_send_complete`, `http1.c:150-173,867-912`). Given chez-libuv's ADR-0018
   (no bounded write queue; consumer tracks `uv-stream-write-queue-size`), this maps naturally:
   we should not call `uv-read-start!` again for the next request until the current
   response's `uv-write!` has completed and we've decided to keep the connection open.

2. **Backpressure on both sides is "one fragment in flight, stop reading until
   acknowledged," not a byte-counted queue.** Copy the pattern exactly: on receiving a body
   fragment, stop reading (chez-libuv: `uv-read-stop!`), hand the fragment to the handler,
   and only resume reading once the handler has both consumed and explicitly acknowledged it
   (h2o's `write_req.cb`/`proceed_req` pair, `h2o.h:1183-1195`, `http1.c:235-266,571-624`).
   Symmetrically for the response body: don't ask the generator for more data until the
   previous `uv-write!`'s completion callback has fired (h2o: `on_send_next` →
   `h2o_proceed_response`, `http1.c:840-853`). This composes cleanly with chez-libuv's actual
   constraints (no vectored writes, no bounded write queue, buffers copied at the FFI
   boundary) — a strict one-write-outstanding-per-connection discipline is exactly what h2o
   enforces via `assert(sock->_cb.write == NULL)` (`socket.c:923-924,940-941`), and it's a
   discipline our design needs regardless of libuv's own queuing behavior, since chez-libuv
   explicitly punts on flow control to the consumer.

3. **Content-Length vs. Transfer-Encoding precedence, but do better than h2o on rejection.**
   Copy the *precedence* rule (Transfer-Encoding wins when both are present, `http1.c:393-
   397`) but **do not** copy h2o's silent-acceptance-of-conflicting-duplicates behavior
   (§7) — reject requests with multiple, differing Content-Length values or with both
   Transfer-Encoding and Content-Length present, per RFC 9112 §6.3's stricter MUST-reject
   guidance, since this is a known request-smuggling surface and h2o's own code doesn't
   protect against it at this layer.

4. **Steal-the-socket-plus-byte-offset is the right shape for Upgrade/CONNECT.** `h2o_http1_
   upgrade`'s `(h2o_socket_t *sock, size_t headers_size)` handoff (`http1.c:1341-1359,914-
   932`) is a clean, minimal API: detach the transport, tell the receiver how many
   already-buffered bytes belong to the old protocol so it can skip them. This maps directly
   onto chez-libuv's explicit-close/no-GC-driven-close model (ADR-0007) — we'd hand off the
   `uv-tcp` handle itself (not close it) plus a byte count into whatever's already sitting in
   its 64 KiB read buffer/queued bytevectors.

5. **Adopt the picohttpparser chunk-overhead DoS guard, or something equivalent, explicitly —
   don't assume the parser gives it to us for free.** The "100 KiB and >75% framing overhead
   ⇒ reject" heuristic (`picohttpparser.c:691-696`, exercised by `t_80http1-chunk-overhead.t`)
   is deliberate, tuned, and tested; verify whether chez-httparse's byte-machine-generated
   chunked-decoder callbacks already do anything like this (PROJECT CONTEXT doesn't mention
   it), and if not, implement the check at the connection layer (track total chunk-framing
   bytes vs. total payload bytes per request body) rather than assuming llhttp-fixture
   conformance implies DoS-resistance — conformance tests validate *correctness*, not *abuse
   resistance*.

6. **Be deliberate about the timeout/status-code gaps h2o leaves open.** h2o never sends 408,
   431, 501, or 505 (confirmed absent from its status-error enum, `include/h2o.h:630-642`
   sparse-clone) — idle/header timeouts just silently close the TCP connection
   (`http1.c:804-815`), and an oversized header block gets a 400 instead of a 431
   (`http1.c:648-650`). This is a legitimate, security-conscious choice (don't spend
   bytes/cycles being polite to a client that's already violated a limit), but our
   PROJECT CONTEXT's llhttp-fixture-driven parser and chez-httparse's `parser-field-ref`
   introspection make it cheap for us to be more informative (send 431/408) if we choose —
   just make that choice consciously, and if we do, don't reflexively keep the connection
   alive afterward; h2o always closes on every one of its own error paths
   (`H2O_SEND_ERROR_HTTP1_CLOSE_CONNECTION` on every single call site in `http1.c`) and we
   should default to the same "abort ⇒ close" policy for parser/framing errors, since a
   client that broke framing cannot be trusted to still agree with us about where the next
   request starts.

7. **100-continue: send it eagerly and unconditionally in origin-server mode, with no
   handler pre-approval hook** — this is h2o's simplification (`http1.c:711-734`) and it's
   a reasonable default for a v1 (RFC 7231 §5.1.1 explicitly allows a server to just always
   send 100-continue rather than evaluate the request first). Don't build a
   handler-inspects-before-100-continue hook unless a concrete need (e.g. auth-gate large
   uploads before they're sent) shows up later; h2o ships without one.

8. **No lingering close is a real, named gap in h2o, not an oversight to silently copy.**
   The `/* TODO use lingering close */` comment (`http1.c:153`) plus the confirmed absence of
   any `SO_LINGER`/drain-before-close logic anywhere in `socket.c`/`evloop.c.h`/`epoll.c.h`
   (sparse-clone) means h2o accepts the standard risk of an abrupt close racing unread client
   data (potential TCP RST swallowing a response the client already got queued but hasn't
   ACKed as "read" by the application). Given chez-libuv's ADR-0007 (`uv-close!` is explicit,
   async, never GC-driven) we have a natural place to *add* a lingering-close/half-close
   policy h2o doesn't have — worth an explicit ADR of our own on whether v1 copies h2o's
   "just close" simplicity or spends the complexity budget on a proper drain, but it should
   be a conscious decision either way, made knowing h2o — a security-hardened server used at
   scale — shipped without it.

9. **Graceful shutdown is two independent, composable mechanisms, not one.** (a) A
   process-wide flag checked lazily at the next request-parse to force `Connection: close`
   on new requests (`http1.c:529-530`) — cheap, and guarantees in-flight work always
   completes; (b) a separate, periodically-invoked sweep that force-closes genuinely *idle*
   connections only (`lib/core/context.c:289-306`, sparse-clone) — so a shutdown doesn't
   have to wait out every idle client's full keep-alive timeout. This two-mechanism split is
   worth copying as-is: it cleanly separates "stop accepting new work on this connection"
   from "reclaim connections that have literally nothing left to do."

10. **The idle-vs-active connection distinction (`H2O_CONN_STATE_IDLE/ACTIVE/SHUTDOWN`,
    `include/h2o.h:656-658` sparse-clone) is what makes both graceful shutdown and any future
    idle-connection accounting/metrics tractable** — h2o flips a connection to `IDLE`
    precisely when `cleanup_connection` finds `sock->input->size == 0` after a response
    completes (`http1.c:169-170`), i.e., "nothing buffered, genuinely waiting on the network."
    This is a cheap, three-state per-connection tag worth having in our own design from the
    start rather than retrofitting once we need graceful shutdown or connection-count metrics.
