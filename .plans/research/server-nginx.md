# nginx HTTP/1 connection semantics — deep read for chez-http-server

Source: https://github.com/nginx/nginx, fetched via `raw.githubusercontent.com` at
commit `ef0aa967dce9d30b824d4c839d3579d2a17e0666` ("Version bump", 2026-09-16,
`master`, currently tagged around `release-1.31.6`) on 2026-09-19. All line
numbers below are against that commit. Permalink form used throughout:
`https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/<path>#L<n>`.

Local copies fetched with `curl` (verbatim, unmodified) into
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/nginx-src/`:

```
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_request.c -o src_http_ngx_http_request.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_request.h -o src_http_ngx_http_request.h
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_request_body.c -o src_http_ngx_http_request_body.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_core_module.c -o src_http_ngx_http_core_module.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_core_module.h -o src_http_ngx_http_core_module.h
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http.h -o src_http_ngx_http.h
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_parse.c -o src_http_ngx_http_parse.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_header_filter_module.c -o src_http_ngx_http_header_filter_module.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_write_filter_module.c -o src_http_ngx_http_write_filter_module.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_upstream.h -o src_http_ngx_http_upstream.h
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/modules/ngx_http_chunked_filter_module.c -o src_http_modules_ngx_http_chunked_filter_module.c
$ curl -sf https://raw.githubusercontent.com/nginx/nginx/master/src/http/ngx_http_special_response.c -o src_http_ngx_http_special_response.c
```

All ten `curl` invocations returned `OK` and file sizes matched (`ngx_http_request.c` =
4235 lines, `ngx_http_request_body.c` = 1387 lines, `ngx_http_core_module.c` = 5523
lines, etc. — verified with `wc -l`). The nginx test suite (Perl `Test::Nginx`
harness) was already present in the shared scratchpad at
`scratchpad/fetched/nginx-tests/*.t` (fetched by an earlier research task in this
same session) and was reused for the "own test suite" section below; each file's
authorship banner (`(C) Maxim Dounin` / `(C) Nginx, Inc.` / `use Test::Nginx`) was
spot-checked to confirm provenance.

I did **not** fetch `ngx_http_upstream.c` (the module that actually implements
CONNECT tunneling and `Upgrade` proxying) — it is very large and out of the
requested file list — so the CONNECT/Upgrade section below is deliberately scoped
to what `ngx_http_request.c`/`ngx_http_core_module.c` do at the connection layer
(validate and hand off), not to the upstream tunnel implementation. This is flagged
inline.

---

## 1. Keep-alive decision rule

The rule is decided in two places and then vetoed by a third.

**a) Initial decision, from the `Connection` request header, in `ngx_http_handler`**
(`src/http/ngx_http_core_module.c:847-890`, the entry point called once headers are
fully parsed):

```c
// src/http/ngx_http_core_module.c:854-874
if (!r->internal) {
    if (r->method != NGX_HTTP_CONNECT) {
        switch (r->headers_in.connection_type) {
        case 0:
            r->keepalive = (r->http_version > NGX_HTTP_VERSION_10);
            break;
        case NGX_HTTP_CONNECTION_CLOSE:
            r->keepalive = 0;
            break;
        case NGX_HTTP_CONNECTION_KEEP_ALIVE:
            r->keepalive = 1;
            break;
        }
    }
    r->lingering_close = (r->headers_in.content_length_n > 0
                          || r->headers_in.chunked);
    ...
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_core_module.c#L854-L874)

So: **no `Connection` header at all** → keep-alive iff HTTP version > 1.0 (i.e.
HTTP/1.1 defaults to keep-alive, HTTP/1.0 defaults to close). An explicit
`Connection: close` token always wins; an explicit `Connection: keep-alive` token
always turns it on (even on an HTTP/1.0 client, which is the classic
Netscape-era `Connection: keep-alive` extension). `r->headers_in.connection_type`
itself is set while parsing the `Connection` header in
`ngx_http_process_connection` (`src/http/ngx_http_request.c:1918-1934`):
`ngx_strcasestrn(value, "close", ...)` is checked before `"keep-alive"`, and the
match is a **substring** test (`strcasestrn`), not a token/list parse — so e.g.
`Connection: keep-alive, Upgrade` still matches. If the client sends **multiple**
`Connection` headers, each one re-runs this substring test and overwrites
`connection_type`, so the *last* `Connection` header's classification wins (no
duplicate-header rejection for `Connection` — contrast with `Host`,
`Content-Length`, `Transfer-Encoding`, see §8).
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L1918-L1934)

**b) Per-response, per-location vetoes, in `ngx_http_update_location_config`**
(`src/http/ngx_http_core_module.c:1390-1424`), run again for every request once
its final location is known:

```c
// src/http/ngx_http_core_module.c:1390-1424
if (r->keepalive) {
    if (clcf->keepalive_timeout == 0) {
        r->keepalive = 0;
    } else if (r->connection->requests >= clcf->keepalive_requests) {
        r->keepalive = 0;
    } else if (ngx_current_msec - r->connection->start_time
               > clcf->keepalive_time)
    {
        r->keepalive = 0;
    } else if (r->headers_in.msie6 && r->method == NGX_HTTP_POST
               && (clcf->keepalive_disable & NGX_HTTP_KEEPALIVE_DISABLE_MSIE6))
    {
        r->keepalive = 0;   /* MSIE6 POST-over-keepalive stall workaround */
    } else if (r->headers_in.safari
               && (clcf->keepalive_disable & NGX_HTTP_KEEPALIVE_DISABLE_SAFARI))
    {
        r->keepalive = 0;   /* Safari stale-keepalive-POST bug workaround */
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_core_module.c#L1390-L1424)

**c) Close-delimited-response veto**, in the chunked-filter header handler
(`src/http/modules/ngx_http_chunked_filter_module.c:59-103`) — this is the concrete
mechanism for "a close-delimited response forces close" the task asked about:

```c
// src/http/modules/ngx_http_chunked_filter_module.c:76-99
if (r->headers_out.content_length_n == -1 || r->expect_trailers) {
    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);
    if (r->http_version >= NGX_HTTP_VERSION_11 && clcf->chunked_transfer_encoding) {
        if (r->expect_trailers) { ngx_http_clear_content_length(r); }
        r->chunked = 1;
        ...
    } else if (r->headers_out.content_length_n == -1) {
        r->keepalive = 0;
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/modules/ngx_http_chunked_filter_module.c#L76-L99)

In words: if the handler produced a body with unknown length (`content_length_n ==
-1`, i.e. it never set `Content-Length` and isn't already chunking), nginx tries to
switch to `Transfer-Encoding: chunked` — but only for an HTTP/1.1 client with
`chunked_transfer_encoding on` (the default). If either condition fails (HTTP/1.0
client, or `chunked_transfer_encoding off`), it falls back to a close-delimited
response by force-clearing `r->keepalive`, regardless of what §a/§b decided. There
is a third, harsher override for shutdown: in the header filter itself,
`if (r->keepalive && (ngx_terminate || ngx_exiting)) r->keepalive = 0;`
(`src/http/ngx_http_header_filter_module.c:204-206`) — a worker shutting down
never advertises keep-alive on its next response, so clients naturally drain off
without nginx having to interrupt in-flight connections.
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_header_filter_module.c#L204-L206)

Finally, `r->keepalive` is what actually gets written on the wire — the response
header filter (`src/http/ngx_http_header_filter_module.c:386-406` for the
length pass, `:562-578` for the write pass) emits `Connection: upgrade` for a 101,
else `Connection: keep-alive` (+ optional `Keep-Alive: timeout=N` if
`keepalive_header`/`keepalive_time` is set) when `r->keepalive`, else
`Connection: close`.
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_header_filter_module.c#L562-L578)

## 2. Pipelining policy and response ordering

nginx pipelining is **strictly serial**: it will happily read ahead into its
header buffer past the end of the current request, but it never starts parsing or
processing request *N+1* until request *N* has been fully finalized and the
connection has been recycled into keep-alive state. There is no concurrent
in-flight processing of pipelined requests and therefore no response-reordering
concern — FIFO is structural, not policed.

Evidence, in `ngx_http_set_keepalive` (`src/http/ngx_http_request.c:3351-3576`),
which is the *only* place a second request line is fed to the parser on the same
connection:

```c
// src/http/ngx_http_request.c:3372-3417
hc = r->http_connection;
b = r->header_in;

if (b->pos < b->last) {
    /* the pipelined request */
    ... /* move large header buffers to hc->free / hc->busy bookkeeping */
}

/* guard against recursive call from ngx_http_finalize_connection() */
r->keepalive = 0;

ngx_http_free_request(r, 0);   /* <-- request N's pool is destroyed HERE */

c->data = hc;
...
if (b->pos < b->last) {
    ngx_log_debug0(..., "pipelined request");
    c->log->action = "reading client pipelined request line";
    r = ngx_http_create_request(c);      /* request N+1 allocated fresh */
    ...
    r->pipeline = 1;
    c->data = r;
    ...
    rev->handler = ngx_http_process_request_line;
    ngx_post_event(rev, &ngx_posted_events);   /* deferred, not inline */
    return;
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L3372-L3459)

Key points:
- `ngx_http_free_request(r, 0)` destroys request N's memory pool *before* request
  N+1 is even allocated — there is no request object for N+1 to race against N's.
- The leftover bytes already sitting in `r->header_in`/`c->buffer` (whatever the
  client sent beyond request N's boundary, discovered by the parser's `consumed`
  count) are what's pipelined; nginx does not proactively read more off the wire
  to build a pipeline — the client had to have written request N+1 before request
  N's response went out, and the kernel socket buffer (or nginx's own
  `client_header_buffer_size`/`large_client_header_buffers`, since those persist
  across the `ngx_http_create_request(c)` boundary via `c->buffer`) is what holds
  it.
- Continuing to the next request is via `ngx_post_event(rev, &ngx_posted_events)`
  — a **posted event**, run at the end of the current event-loop iteration via
  `ngx_http_run_posted_requests`
  (`src/http/ngx_http_request.c:2680-2714`), not a direct recursive call. This
  bounds stack depth on a connection that pipelines many small requests back to
  back, and is the same posted-event technique used after every
  `ngx_http_process_request_line`/`ngx_http_process_request_headers` iteration
  (`src/http/ngx_http_request.c:1275`, `:1595`) so a fully-buffered pipeline of N
  requests unwinds the stack between each one rather than recursing N deep.
- `ngx_http_connection_t.busy`/`.free` (`hc->busy`, `hc->free`) is a free-list of
  large-header-buffer chain links reused across pipelined/keepalive requests on
  the same connection — buffers allocated for one request's oversized headers are
  recycled for the next rather than leaked per-request.
- On EOF mid-pipeline read (`r->connection->read->eof`) in
  `ngx_http_finalize_connection` (`src/http/ngx_http_request.c:3037-3040`), nginx
  just closes rather than trying to serve the partial pipelined bytes.
- `r->pipeline` / `c->pipeline` flags (set at `:3446`, `:3452`) are read back in
  `ngx_http_finalize_connection`'s lingering-close decision (§9) — a request that
  arrived pipelined makes nginx more willing to linger-close on error, since
  there may be more client-sent bytes in flight that would otherwise arrive as an
  RST-triggering write after an abrupt close.

**No dedicated pipelining test file exists** in nginx's own test suite (see §12) —
grepping the full nginx source tree listing
(`scratchpad/nginx_root_list.txt`, produced by an earlier task's `git ls-files`
against this same repo) for `pipelin` returns nothing under `src/` and the only
`*.t` test files are none named `*pipelin*`; pipelining is exercised only
incidentally as leftover bytes in `c->buffer` inside `http_keepalive.t` (see §12).

## 3. Request body streaming to handlers, with backpressure

Entry point: `ngx_http_read_client_request_body(r, post_handler)`
(`src/http/ngx_http_request_body.c:31-228`). Handler API: the caller passes an
`ngx_http_client_body_handler_pt post_handler` (`typedef void
(*ngx_http_client_body_handler_pt)(ngx_http_request_t *r);`,
`src/http/ngx_http_request.h:301`), which nginx invokes once the *entire* body
(by default; see "no buffering" mode below) has been read and filtered. This is
**not** a streaming-chunks-to-callback API by default — it is a "read
everything, then call me once" API, with a separate opt-in
(`r->request_body_no_buffering`) for handlers (only used by `proxy_pass`,
`fastcgi_pass` etc. via `*_request_buffering off`) that want to be invoked
repeatedly as data arrives.

Read loop: `ngx_http_do_read_client_request_body`
(`src/http/ngx_http_request_body.c:294-462`). Core backpressure shape:

```c
// src/http/ngx_http_request_body.c:366-417 (abbreviated)
size = rb->buf->end - rb->buf->last;
rest = rb->rest - (rb->buf->last - rb->buf->pos);
if ((off_t) size > rest) size = (size_t) rest;
if (size == 0) break;

n = c->recv(c, rb->buf->last, size);
if (n == NGX_AGAIN) break;
...
rb->buf->last += n;
r->request_length += n;

/* pass buffer to request body filter chain */
out.buf = rb->buf; out.next = NULL;
rc = ngx_http_request_body_filter(r, &out);      /* dechunk / bound by Content-Length */
if (rc != NGX_OK) return rc;

if (rb->rest == 0) break;
if (rb->buf->last < rb->buf->end) break;          /* buffer not full: wait for more data event */
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request_body.c#L366-L417)

This is a **fixed-size, pre-allocated buffer, read-until-full-or-rest-exhausted**
loop (no per-connection unbounded growth): the buffer is sized once, from
`clcf->client_body_buffer_size * 1.25` (`src/http/ngx_http_request_body.c:175-193`),
capped at `rb->rest` (remaining body bytes) if that's smaller. When the buffer
fills (`rb->buf->last == rb->buf->end`) and hasn't been fully drained by the body
filter chain (`rb->busy != NULL`, i.e. downstream — e.g. the proxy module's output
side — hasn't consumed what was already handed off), nginx **stops reading from
the socket** and returns `NGX_AGAIN` without re-registering more work, i.e. it
lets the client-side TCP window fill up rather than buffering unboundedly in
memory:

```c
// src/http/ngx_http_request_body.c:320-359
if (rb->buf->last == rb->buf->end) {
    rc = ngx_http_request_body_filter(r, NULL);   /* try to flush/advance */
    if (rc != NGX_OK) return rc;
    if (rb->busy != NULL) {
        if (r->request_body_no_buffering) {
            /* unbuffered mode: stop, let the handler drain rb->bufs itself */
            ...
            return NGX_AGAIN;
        }
        if (rb->filter_need_buffering) {
            ngx_add_timer(c->read, clcf->client_body_timeout);
            ...
            return NGX_AGAIN;
        }
        ngx_log_error(NGX_LOG_ALERT, ..., "busy buffers after request body flush");
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    flush = 0;
    rb->buf->pos = rb->buf->start;
    rb->buf->last = rb->buf->start;   /* buffer reused once downstream drained it */
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request_body.c#L320-L359)

When buffering to a file is configured (`client_body_in_file_only`, or the body
simply exceeds `client_body_buffer_size` in the default "buffer to memory, spill
to temp file" mode), `ngx_http_write_request_body`
(`src/http/ngx_http_request_body.c:547-628`) flushes accumulated in-memory
buffers to a temp file synchronously (`ngx_write_chain_to_temp_file`, blocking
disk I/O on the worker — there's a `/* TODO: n == 0 or not complete and level
event */` comment acknowledging this is not itself fully async,
`src/http/ngx_http_request_body.c:606`) — this is nginx's one acknowledged
blocking point in an otherwise event-driven pipeline.

Every read re-arms `client_body_timeout` (`src/http/ngx_http_request_body.c:437-438`,
`:346`) each time the loop would otherwise block on `NGX_AGAIN`, i.e. the timer is
an **idle** timer per-read, not a total-request-body deadline.

`Content-Length`-bounded bodies use `ngx_http_request_body_length_filter`
(`src/http/ngx_http_request_body.c:1002-1088`, not fully read but named/dispatched
at `:990-999`); chunked bodies use `ngx_http_request_body_chunked_filter`
(`:1089-1272`, dechunking happens here, in the application layer, not the wire
parser). Both funnel into `ngx_http_request_body_save_filter`
(`:1273` onward) which is the terminal filter that either hands buffers to
`ngx_http_write_request_body` or exposes them via `rb->bufs` for
`request_body_no_buffering` handlers to pull.

Pipelined bytes that follow the body inside the same read (client sent request
N+1's bytes attached to the same TCP segment as request N's last body bytes) are
explicitly rescued by `ngx_http_copy_pipelined_header`
(`src/http/ngx_http_request_body.c:465-546`, called at `:448` in the read loop) —
it copies any overrun back into `r->header_in`/`c->buffer` so `ngx_http_set_keepalive`
finds it as a "pipelined request" (§2) rather than losing it.

## 4. Response body streaming out, with backpressure

Response bodies go through `ngx_http_output_filter` → the module filter chain →
terminally `ngx_http_write_filter` (`src/http/ngx_http_write_filter_module.c:47-362`,
the tail of `ngx_http_top_body_filter`, installed at `:365-371`). Shape:

```c
// src/http/ngx_http_write_filter_module.c:213-226, 294-361 (abbreviated)
if (!last && !flush && in && size < (off_t) clcf->postpone_output) {
    return NGX_OK;   /* small buffer, no flush point yet: just accumulate */
}
if (c->write->delayed) {
    c->buffered |= NGX_HTTP_WRITE_BUFFERED;
    return NGX_AGAIN;   /* rate-limited (limit_rate): wait for the write timer */
}
...
sent = c->sent;
chain = c->send_chain(c, r->out, limit);   /* the OS write / sendfile call */
if (chain == NGX_CHAIN_ERROR) { c->error = 1; return NGX_ERROR; }
...
for (cl = r->out; cl && cl != chain; ) { ln = cl; cl = cl->next; ngx_free_chain(r->pool, ln); }
r->out = chain;   /* whatever send_chain did NOT accept stays queued */

if (chain) {
    c->buffered |= NGX_HTTP_WRITE_BUFFERED;
    return NGX_AGAIN;    /* kernel socket buffer full: caller must retry later */
}
c->buffered &= ~NGX_HTTP_WRITE_BUFFERED;
if (last) { r->response_sent = 1; }
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_write_filter_module.c#L213-L226,
https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_write_filter_module.c#L294-L361)

`c->send_chain` is the OS-level write (with `sendfile()` used when
`sendfile on` and the buffer is file-backed) and returns a partial chain — the
suffix that the kernel didn't accept because the socket send buffer is full. This
partial chain becomes the new `r->out`, and `NGX_AGAIN` propagates up to
`ngx_http_writer` (`src/http/ngx_http_request.c:3111-3181`), which is the
`c->write->handler` set by `ngx_http_set_write_handler`
(`src/http/ngx_http_request.c:3078-3108`). `ngx_http_writer` re-registers for
write-readiness (`ngx_handle_write_event(wev, clcf->send_lowat)`) and arms
`send_timeout` (`ngx_add_timer(wev, clcf->send_timeout)`) — so the write side's
"backpressure" is exactly "wait for the socket to become writable again, bounded
by `send_timeout`". `sendfile_max_chunk` (default `2m`,
`src/http/ngx_http_core_module.c:3934-3935` merge... actually confirmed at merge
default `2 * 1024 * 1024`, see §5) caps how much a single `send_chain` call will
try to push in one go, so one slow client with a huge response can't monopolize a
worker's event-loop turn doing a giant `sendfile()`. `limit_rate`/`limit_rate_after`
implement optional application-level throttling by artificially inserting delayed
write timers even when the socket is otherwise writable
(`src/http/ngx_http_write_filter_module.c:263-292`).

Handler-facing shape: `ngx_http_output_filter(r, chain)` is called by content
handlers with `ngx_chain_t` buffer chains; they call it possibly many times,
checking the return value (`NGX_OK` = fully accepted / room for more, `NGX_AGAIN`
= backed up, caller must stop producing and wait until its write-event handler is
re-invoked, `NGX_ERROR` = client gone). This is the output-side mirror of the
request-body buffer backpressure in §3 — both ultimately bottom out in "stop
touching the socket, let the event loop tell you when it's ready again", never an
unbounded internal queue.

## 5. Every named limit/timeout and its default

All from `ngx_http_core_module.c`'s directive table (`ngx_http_core_commands[]`,
`src/http/ngx_http_core_module.c:220-810`) and the `merge_srv_conf`/`merge_loc_conf`
default-fill functions (`:3590-3660` for srv, `:3700-4010`ish for loc). Directive
scope noted; `srv` = server block level (`ngx_http_core_srv_conf_t`), `loc` = location
level (`ngx_http_core_loc_conf_t`).

| Directive | Scope | Default | Source |
|---|---|---|---|
| `client_header_timeout` | srv | **60000 ms** (60s) | `ngx_conf_merge_msec_value(conf->client_header_timeout, prev->client_header_timeout, 60000);` — `ngx_http_core_module.c:3626-3627` |
| `client_header_buffer_size` | srv | **1024 bytes** | `ngx_conf_merge_size_value(conf->client_header_buffer_size, prev->client_header_buffer_size, 1024);` — `:3628-3629` |
| `large_client_header_buffers` | srv | **4 buffers × 8192 bytes** | `ngx_conf_merge_bufs_value(conf->large_client_header_buffers, prev->large_client_header_buffers, 4, 8192);` — `:3630-3632` |
| `max_headers` | srv | **1000** | `ngx_conf_merge_uint_value(conf->max_headers, prev->max_headers, 1000);` — `:3641` |
| `ignore_invalid_headers` | srv | **on** (`1`) | `ngx_conf_merge_value(conf->ignore_invalid_headers, prev->ignore_invalid_headers, 1);` — `:3643-3644` |
| `request_pool_size` | srv | **4096 bytes** | `ngx_conf_merge_size_value(conf->request_pool_size, prev->request_pool_size, 4096);` — `:3624-3625` |
| `client_max_body_size` | loc | **1 MB** (`1 * 1024 * 1024`) | `ngx_conf_merge_off_value(conf->client_max_body_size, prev->client_max_body_size, 1 * 1024 * 1024);` — `:3931-3932` |
| `client_body_buffer_size` | loc | **2 × `ngx_pagesize`** (i.e. 8 KiB on most Linux/x86 and macOS arm64 4 KiB-page systems' *doubled* value is actually 8 KiB since pagesize=4096; 16 KiB on platforms with 8 KiB pages, e.g. some ppc64/ia64 historically) | `ngx_conf_merge_size_value(conf->client_body_buffer_size, prev->client_body_buffer_size, (size_t) 2 * ngx_pagesize);` — `:3933-3935` |
| `client_body_timeout` | loc | **60000 ms** (60s) | `ngx_conf_merge_msec_value(conf->client_body_timeout, prev->client_body_timeout, 60000);` — `:3936-3937` |
| `send_timeout` | loc | **60000 ms** (60s) | `ngx_conf_merge_msec_value(conf->send_timeout, prev->send_timeout, 60000);` — `:3977` |
| `keepalive_time` | loc | **3600000 ms** (1 hour) — max *total connection lifetime* while keepalive, independent of idle timeout | `ngx_conf_merge_msec_value(conf->keepalive_time, prev->keepalive_time, 3600000);` — `:3986-3987` |
| `keepalive_timeout` | loc | **75000 ms** (75s) — idle timeout between requests on a keepalive connection | `ngx_conf_merge_msec_value(conf->keepalive_timeout, prev->keepalive_timeout, 75000);` — `:3988-3989` |
| `keepalive_requests` | loc | **1000** requests per connection | `ngx_conf_merge_uint_value(conf->keepalive_requests, prev->keepalive_requests, 1000);` — `:3994-3995` |
| `lingering_close` | loc | **`on`** (`NGX_HTTP_LINGERING_ON`, conditional — see §9) | `ngx_conf_merge_uint_value(conf->lingering_close, prev->lingering_close, NGX_HTTP_LINGERING_ON);` — `:3996-3997` |
| `lingering_time` | loc | **30000 ms** (30s) — max wall-clock time nginx will spend draining lingering-close bytes | `ngx_conf_merge_msec_value(conf->lingering_time, prev->lingering_time, 30000);` — `:3998-3999` |
| `lingering_timeout` | loc | **5000 ms** (5s) — idle-read timeout *during* lingering close; nginx closes if no bytes arrive within this window even before `lingering_time` expires | `ngx_conf_merge_msec_value(conf->lingering_timeout, prev->lingering_timeout, 5000);` — `:4000-4001` |
| `sendfile_max_chunk` | loc | **2 MB** (`2 * 1024 * 1024`) | `ngx_conf_merge_size_value(conf->sendfile_max_chunk, prev->sendfile_max_chunk, 2 * 1024 * 1024);` — `:3959-3960` |
| `postpone_output` | loc | **1460 bytes** (≈ typical Ethernet MSS) — minimum buffered size before nginx will bother writing if there's no explicit flush point | `ngx_conf_merge_size_value(conf->postpone_output, prev->postpone_output, 1460);` — `:3979-3980` |
| `client_body_in_file_only` | loc | **off** (`NGX_HTTP_REQUEST_BODY_FILE_OFF`) | `:3950-3952` |
| `client_body_in_single_buffer` | loc | **off** (`0`) | `:3953-3954` |
| `keepalive_disable` | loc | **`msie6`** (bitmask; Safari-POST workaround is opt-in) | `:3945-3948` |

(All merge-default lines cited above are from
https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_core_module.c
— see the specific `:NNNN` line anchors.)

Additionally, hard-coded (not configurable) constants relevant to connection
handling, in `src/http/ngx_http_request.h`:
- `NGX_HTTP_LINGERING_BUFFER_SIZE` = **4096 bytes** — the stack buffer size used
  to drain-and-discard bytes during lingering close
  (`src/http/ngx_http_request.h:20`; used at
  `src/http/ngx_http_request.c:3806,3826`).

`large_client_header_buffers` has a cross-check against `connection_pool_size`
(`src/http/ngx_http_core_module.c:3634-3639`): its `size` must be ≥
`connection_pool_size`, or nginx refuses to start — a config-validation
invariant, not a runtime one.

`client_body_buffer_size` is explicitly OS-page-size-dependent
(`2 * ngx_pagesize`), a portability wrinkle worth flagging for us since Chez on
macOS arm64 and Linux amd64/arm64 may have different native page sizes (typically
16 KiB on Apple Silicon macOS vs 4 KiB on x86_64 Linux vs sometimes 4 KiB or 64 KiB
on Linux arm64) — nginx bakes the *build platform's* pagesize in as the default,
which is itself a minor nginx wart (a binary built on one page-size host and run
elsewhere still gets that default) that we should avoid by choosing an explicit
fixed default rather than querying our own runtime's page size.

## 6. `Expect: 100-continue` handling

`ngx_http_test_expect` (`src/http/ngx_http_request_body.c:939-987`), called from
both `ngx_http_read_client_request_body` (`:51`) and `ngx_http_discard_request_body`
(`:655`) before any body bytes are consumed:

```c
// src/http/ngx_http_request_body.c:939-987
static ngx_int_t
ngx_http_test_expect(ngx_http_request_t *r)
{
    ngx_int_t   n;
    ngx_str_t  *expect;

    if (r->expect_tested
        || r->headers_in.expect == NULL
        || r->http_version < NGX_HTTP_VERSION_11
        ...)
    {
        return NGX_OK;
    }

    r->expect_tested = 1;

    expect = &r->headers_in.expect->value;
    if (expect->len != sizeof("100-continue") - 1
        || ngx_strncasecmp(expect->data, (u_char *) "100-continue",
                           sizeof("100-continue") - 1) != 0)
    {
        return NGX_OK;
    }

    n = r->connection->send(r->connection,
                            (u_char *) "HTTP/1.1 100 Continue" CRLF CRLF,
                            sizeof("HTTP/1.1 100 Continue" CRLF CRLF) - 1);

    if (n == sizeof("HTTP/1.1 100 Continue" CRLF CRLF) - 1) {
        return NGX_OK;
    }
    /* we assume that such small packet should be send successfully */
    r->connection->error = 1;
    return NGX_ERROR;
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request_body.c#L939-L987)

Notable design choices:
- Only fires for exactly `Expect: 100-continue` (case-insensitive, exact match,
  not a token-list parse) and only for HTTP/1.1+. HTTP/2/3 streams (`r->stream`/
  QUIC) are excluded because their own layers handle 100-continue differently.
- `r->expect_tested` is a **one-shot latch** — this function is a no-op on any
  subsequent call for the same request, so it's safe to call it from multiple
  code paths (buffered read and discard) without double-sending.
- The `100 Continue` line is written with a **raw blocking `send()`** call
  assumed to always succeed in one write ("we assume that such small packet
  should be send successfully") — there is no retry/backpressure handling here;
  if the OS refuses even 25 bytes, nginx just marks `c->error = 1` and gives up.
  This is a real (documented-as-accepted) shortcut in nginx, not a subtlety to
  copy: a 25-byte write can in principle partially fail on a nonblocking socket
  with a full send buffer, though in practice this never happens for a
  freshly-accepted connection's first write.
- **Rejection before continuation**: the size check happens earlier, in
  `ngx_http_read_early_body`/`ngx_http_process_request` path
  (`src/http/ngx_http_request.c:2247-2261`):
  ```c
  if (r->headers_in.content_length_n != -1
      && !r->discard_body
      && clcf->client_max_body_size
      && clcf->client_max_body_size < r->headers_in.content_length_n)
  {
      ...
      r->expect_tested = 1;               /* pre-poison the latch: no 100-continue sent */
      (void) ngx_http_discard_request_body(r);
      ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
      return NGX_DONE;
  }
  ```
  (https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L2247-L2261)
  So if `Content-Length` already announces a body bigger than
  `client_max_body_size`, nginx sets `r->expect_tested = 1` *before* the normal
  `ngx_http_test_expect` call would fire, which suppresses the `100 Continue` and
  goes straight to `413`. This is the "don't tell the client to send a body
  you're going to reject anyway" behavior. A `100 Continue` is otherwise sent
  unconditionally (no policy/auth check gates it) — nginx does not delay sending
  `100 Continue` until a handler has decided to accept the request; it is purely
  a Content-Length-size gate at the core layer.
- Note `Expect` is registered as a *unique* header in `ngx_http_headers_in[]`
  (`src/http/ngx_http_request.c:135-136`,
  `ngx_http_process_unique_header_line`) — a duplicate `Expect` header is a 400,
  same as duplicate `Content-Length`/`Transfer-Encoding`/`Host` (§8).

## 7. Upgrade / CONNECT

**CONNECT**, validated purely at the request-header layer in
`ngx_http_process_request_header` (`src/http/ngx_http_request.c:2098-2112`):

```c
// src/http/ngx_http_request.c:2098-2112
if (r->method == NGX_HTTP_CONNECT) {
    if (r->http_version != NGX_HTTP_VERSION_11 || !cscf->allow_connect) {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "client sent CONNECT method");
        ngx_http_finalize_request(r, NGX_HTTP_NOT_ALLOWED);   /* 405 */
        return NGX_ERROR;
    }
    if (r->headers_in.content_length_n > 0 || r->headers_in.chunked) {
        ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                      "client sent CONNECT request with body");
        ngx_http_finalize_request(r, NGX_HTTP_BAD_REQUEST);   /* 400 */
        return NGX_ERROR;
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L2098-L2112)

So: CONNECT is rejected with **405** unless it's HTTP/1.1 *and* the location has
opted in with `allow_connect` (a location-level directive gating `ngx_stream`/
forward-proxy style tunneling — CONNECT is not something nginx does anywhere by
default), and rejected with **400** if it carries a body (CONNECT must not have
one). `allow_connect` is a location-conf bitfield
(`unsigned allow_connect:1;` — `src/http/ngx_http_core_module.h:214`).
`r->keepalive` is explicitly forced off for CONNECT at the `ngx_http_handler`
level (the `if (r->method != NGX_HTTP_CONNECT)` guard around the keep-alive
switch in §1a means a CONNECT request never gets `r->keepalive` set by that
switch at all — it starts and stays `0` from `ngx_pcalloc`'s zero-init, so a
CONNECT connection is never treated as an ordinary HTTP keep-alive connection).
Actual tunnel establishment (switching the connection to raw bidirectional byte
relay) is **not implemented in `ngx_http_request.c`** — it lives in
`ngx_http_upstream.c` (not fetched for this pass; flagged as unverified detail),
which is consistent with CONNECT being meaningless without a `proxy_pass`/
similar handler behind it. `NGX_HTTP_CONNECT` request bodies being forbidden and
CONNECT being location-gated is the useful, verified takeaway; the
byte-relay/half-close mechanics of the tunnel itself are out of scope for what I
fetched.

**Upgrade** (`101 Switching Protocols`, e.g. WebSocket): the request-side
`Upgrade` header is parsed and stored (`ngx_http_headers_in[]` entry at
`src/http/ngx_http_request.c:139-141`, using the generic
`ngx_http_process_header_line`, i.e. **not** unique-checked — multiple `Upgrade`
headers are legal at the core parse layer) but `ngx_http_request.c`/
`ngx_http_core_module.c` do nothing else with it directly; there is no
core-level "generic Upgrade" handshake. What *is* core-level is response-side
support: if a handler sets `r->headers_out.status = NGX_HTTP_SWITCHING_PROTOCOLS`
(101), the header filter emits `Connection: upgrade` instead of `keep-alive`/
`close` (`src/http/ngx_http_header_filter_module.c:386-388`, `:562-564`, already
quoted in §1). `ngx_http_upstream.h` defines an `unsigned upgrade:1;` bitfield
(`src/http/ngx_http_upstream.h:418`) confirming the actual upgrade/tunnel state
machine lives in the upstream (proxy) module, which is where `proxy_pass` switches
a proxied connection into raw relay mode after a 101 — again, not fetched/verified
in this pass; flagged.

**Lesson for us, stated plainly**: nginx's *core* HTTP/1 connection layer treats
CONNECT and Upgrade as "reject unless explicitly enabled, and if enabled, get out
of the way for a module built on top" — it does not itself implement a generic
byte-tunnel primitive in the request/connection state machine we read. If we want
CONNECT/Upgrade in chez-http-server, we should design it as a distinct mode our
connection state machine drops into (stop HTTP framing entirely, become a raw
uv-stream relay) rather than trying to fit it inside the keep-alive/pipelining
state machine — which matches nginx's separation.

## 8. Framing precedence (Content-Length vs Transfer-Encoding, duplicates, HEAD, 1xx/204/304)

All in `ngx_http_process_request_header` (`src/http/ngx_http_request.c:2023-2122`)
for the **request** side:

```c
// src/http/ngx_http_request.c:2042-2086
if (r->headers_in.content_length) {
    r->headers_in.content_length_n =
        ngx_atoof(r->headers_in.content_length->value.data,
                  r->headers_in.content_length->value.len);
    if (r->headers_in.content_length_n == NGX_ERROR) {
        ... ngx_http_finalize_request(r, NGX_HTTP_BAD_REQUEST); return NGX_ERROR;   /* malformed CL value: 400 */
    }
}

if (r->headers_in.transfer_encoding) {
    if (r->http_version < NGX_HTTP_VERSION_11) {
        ... ngx_http_finalize_request(r, NGX_HTTP_BAD_REQUEST); return NGX_ERROR;   /* TE on HTTP/1.0: 400 */
    }
    if (r->headers_in.transfer_encoding->value.len == 7
        && ngx_strncasecmp(..., "chunked", 7) == 0)
    {
        if (r->headers_in.content_length) {
            ... ngx_http_finalize_request(r, NGX_HTTP_BAD_REQUEST); return NGX_ERROR;   /* CL+TE together: 400 */
        }
        r->headers_in.chunked = 1;
    } else {
        ... ngx_http_finalize_request(r, NGX_HTTP_NOT_IMPLEMENTED); return NGX_ERROR;   /* TE: gzip/identity/etc: 501 */
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L2042-L2086)

Precedence/edge cases, verified against source:
- **`Content-Length` + `Transfer-Encoding: chunked` together → 400 Bad Request.**
  nginx does not pick one and ignore the other (unlike the permissive
  "Transfer-Encoding wins" reading of RFC 7230/9112 some servers use); it treats
  the combination itself as invalid. This is the request-smuggling-safe choice
  and matches what the task's chez-httparse measurement already told us llhttp
  does structurally (flags exist for both, but nginx additionally layers this
  explicit rejection at the application/core level, not just the parser level).
- **`Transfer-Encoding` present but not exactly `chunked` → 501 Not Implemented.**
  Any other transfer-coding token (`gzip`, `identity`, `compress`, garbage) is
  rejected outright — nginx implements only `chunked` as a request
  transfer-coding.
- **`Transfer-Encoding` on an HTTP/1.0 request → 400.** (HTTP/1.0 has no
  chunked transfer-coding.)
- **Duplicate `Content-Length` → 400.** `Content-Length` is registered with
  `ngx_http_process_unique_header_line` (`src/http/ngx_http_request.c:110-112`),
  which rejects a second occurrence unconditionally
  (`src/http/ngx_http_request.c:1841-1863`, quoted in §1). Note this means
  nginx's *duplicate* rejection is about the header appearing twice as separate
  header lines — it does not itself re-parse a comma-joined
  `Content-Length: 1, 1` value specially; `ngx_atoof` would simply fail to parse
  such a value as a pure integer and hit the malformed-value 400 above.
- **Duplicate `Transfer-Encoding` → 400** (same `ngx_http_process_unique_header_line`
  mechanism, `src/http/ngx_http_request.c:130-132`).
- **Duplicate `Host` → 400** (`ngx_http_process_host`,
  `src/http/ngx_http_request.c:1866-1915`, explicit check at `:1874-1882`, quoted
  in full above).
- **`Connection` is explicitly NOT duplicate-checked** — see §1 — multiple
  `Connection` headers are legal and the last one's `close`/`keep-alive`
  substring match wins.
- **HEAD**: `r->method == NGX_HTTP_HEAD` sets `r->header_only = 1` in the response
  header filter (`src/http/ngx_http_header_filter_module.c:190-192`). The chunked
  filter explicitly **excludes HEAD** from ever adding `Transfer-Encoding:
  chunked` (`... || r->method == NGX_HTTP_HEAD ...` short-circuits straight to
  `ngx_http_next_header_filter(r)`,
  `src/http/modules/ngx_http_chunked_filter_module.c:65-73`) — so a HEAD response
  can carry whatever `Content-Length` the handler computed (representing what the
  GET response's body length *would* be) without nginx trying to chunk-encode a
  body it's not going to send. The header filter unconditionally writes
  `Content-Length` if `r->headers_out.content_length_n >= 0` regardless of
  `header_only`
  (`src/http/ngx_http_header_filter_module.c:508-513`) — i.e. **HEAD responses
  do carry Content-Length** when the handler set one, which is exactly RFC 9110 §
  9.3.2's expectation.
- **1xx**: the chunked filter also special-cases *any* status `< NGX_HTTP_OK`
  (`< 200`) to bypass the chunked-vs-close decision entirely
  (`src/http/ngx_http_header_filter_module.c:65-67` condition `r->headers_out.status
  < NGX_HTTP_OK`) — 1xx responses (e.g. the `100 Continue` in §6, or `103 Early
  Hints` — there's a dedicated `ngx_http_early_hints_filter`,
  `src/http/ngx_http_header_filter_module.c:16`, `ngx_http_early_hints_status_line`
  at `:54-55`) never get a body-framing header at all.
- **204/304**: both explicitly excluded from chunking
  (`r->headers_out.status == NGX_HTTP_NOT_MODIFIED || r->headers_out.status ==
  NGX_HTTP_NO_CONTENT`, `src/http/ngx_http_header_filter_module.c... /
  ngx_http_chunked_filter_module.c:65-67`). The main header filter additionally
  suppresses `Last-Modified` on any status other than 200/206/304
  (`src/http/ngx_http_header_filter_module.c:194-202`) — so a 204 response won't
  carry a stale `Last-Modified` either.
- **Malformed request line / version → 400 or 505.** In
  `ngx_http_process_request_line` (`src/http/ngx_http_request.c:1235-1250`):
  `NGX_HTTP_PARSE_INVALID_VERSION` specifically maps to `505 HTTP Version Not
  Supported`; every other parse error from that function
  (`NGX_HTTP_PARSE_INVALID_METHOD`, `NGX_HTTP_PARSE_INVALID_REQUEST`,
  `NGX_HTTP_PARSE_INVALID_09_METHOD`) maps to generic `400`.

## 9. Parse/policy/handler errors → responses, and connection-close decisions

The central dispatcher is `ngx_http_special_response_handler`
(`src/http/ngx_http_special_response.c:423-532`), reached from
`ngx_http_finalize_request` whenever `rc >= NGX_HTTP_SPECIAL_RESPONSE` (300) or a
handful of special sentinel codes. Its keep-alive/lingering vetoes:

```c
// src/http/ngx_http_special_response.c:436-458
r->err_status = error;

if (r->keepalive) {
    switch (error) {
        case NGX_HTTP_BAD_REQUEST:              /* 400 */
        case NGX_HTTP_REQUEST_ENTITY_TOO_LARGE:  /* 413 */
        case NGX_HTTP_REQUEST_URI_TOO_LARGE:     /* 414 */
        case NGX_HTTP_TO_HTTPS:                  /* 497, internal */
        case NGX_HTTPS_CERT_ERROR:               /* 495, internal */
        case NGX_HTTPS_NO_CERT:                  /* 496, internal */
        case NGX_HTTP_INTERNAL_SERVER_ERROR:     /* 500 */
        case NGX_HTTP_NOT_IMPLEMENTED:           /* 501 */
            r->keepalive = 0;
    }
}

if (r->lingering_close) {
    switch (error) {
        case NGX_HTTP_BAD_REQUEST:
        case NGX_HTTP_TO_HTTPS:
        case NGX_HTTPS_CERT_ERROR:
        case NGX_HTTPS_NO_CERT:
            r->lingering_close = 0;
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_special_response.c#L436-L458)

Notice the asymmetry: `400`/`413`/`414`/`500`/`501`/HTTPS-mismatch errors force
`keepalive = 0` (connection *will* close after this response), but of those, only
`400`/HTTPS-mismatch also force `lingering_close = 0` (skip the drain-before-close
step — see below). `413`/`414`/`500`/`501` still get a lingering close if the
global `lingering_close on` policy (the default) would otherwise apply — the
rationale being that for 413/414 the client may still be mid-send of a large
body/URI that nginx wants to drain rather than RST.

**Internal status codes that do not exist on the wire as such**
(`src/http/ngx_http_request.h:93-145`):

| Internal name | Value | Wire status actually sent | Notes |
|---|---|---|---|
| `NGX_HTTP_BAD_REQUEST` | 400 | 400 | |
| `NGX_HTTP_REQUEST_TIME_OUT` | 408 | 408 | |
| `NGX_HTTP_REQUEST_ENTITY_TOO_LARGE` | 413 | 413 | |
| `NGX_HTTP_REQUEST_URI_TOO_LARGE` | 414 | 414 | |
| `NGX_HTTP_CLOSE` | 444 | **none — raw close, no response sent at all** | see below |
| `NGX_HTTP_REQUEST_HEADER_TOO_LARGE` | 494 (aliases `NGX_HTTP_NGINX_CODES`) | **400** | forced via `r->err_status = NGX_HTTP_BAD_REQUEST;` — see below |
| `NGX_HTTP_TO_HTTPS` | 497 | 400 (`err_status` forced to `NGX_HTTP_BAD_REQUEST` too) | plain HTTP request to an HTTPS listener |
| `NGX_HTTP_CLIENT_CLOSED_REQUEST` | 499 | (logging-only; client already gone) | |
| `NGX_HTTP_NOT_IMPLEMENTED` | 501 | 501 | |
| `NGX_HTTP_VERSION_NOT_SUPPORTED` | 505 | 505 | |

**nginx has no HTTP 431.** What HTTP/1.1 (RFC 6585 / RFC 9110) calls
`431 Request Header Fields Too Large`, nginx implements as its own internal code
`494` and then **sends it to the client as `400 Bad Request`**:

```c
// src/http/ngx_http_special_response.c:513-524
} else if (error >= NGX_HTTP_NGINX_CODES && error < NGX_HTTP_LAST_5XX) {
    /* 49X, 5XX */
    err = error - NGX_HTTP_NGINX_CODES + NGX_HTTP_OFF_5XX;   /* selects the *body text* to use */
    switch (error) {
        case NGX_HTTP_TO_HTTPS:
        case NGX_HTTPS_CERT_ERROR:
        case NGX_HTTPS_NO_CERT:
        case NGX_HTTP_REQUEST_HEADER_TOO_LARGE:
            r->err_status = NGX_HTTP_BAD_REQUEST;   /* <-- but the *status line* becomes 400 */
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_special_response.c#L513-L524)

and `r->err_status` is what actually becomes `r->headers_out.status` at send-header
time: `if (r->err_status) { r->headers_out.status = r->err_status; ... }` in
`ngx_http_send_header` (`src/http/ngx_http_core_module.c:1916-1919`). So: nginx's
"header too large" error page text is its own custom `494` body copy, but the
wire status line is `HTTP/1.1 400 Bad Request`. **This is a real, deliberate
divergence from RFC 6585/9110's `431` that we should decide about explicitly**
rather than copy blindly — modern HTTP/1.1 servers (and the task brief's mention
of `431` in the list of statuses to consider) generally do send `431` today; nginx
predates RFC 6585 (2012) and never adopted the real code for backward-compat
reasons. We should pick 431 deliberately if we want spec conformance, and just
note that nginx is not a precedent for doing so.

The oversized-header path itself, in
`ngx_http_alloc_large_header_buffer`/`ngx_http_process_request_headers`
(`src/http/ngx_http_request.c:1656-1821`, `:1435-1470`): once a header/line no
longer fits even after promoting through all `large_client_header_buffers.num`
buffers (`NGX_DECLINED` from the allocator, `:1687,1722`), nginx sets
`r->lingering_close = 1` (`:1447`) **before** finalizing with
`NGX_HTTP_REQUEST_HEADER_TOO_LARGE` — i.e. it proactively decides to drain
whatever the client keeps sending rather than immediately RST'ing a connection
that might still be mid-header-flood.

**`NGX_HTTP_CLOSE` (444)** is nginx's "just hang up, no HTTP response at all"
sentinel — used e.g. by config authors returning `444` explicitly for malicious
traffic. In `ngx_http_finalize_request`:
```c
// src/http/ngx_http_request.c:2792-2796
if (rc == NGX_HTTP_CLOSE) {
    c->timedout = 1;                       /* triggers SO_LINGER{1,0} abrupt close, see §10 */
    ngx_http_terminate_request(r, rc);
    return;
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L2792-L2796)
— note it deliberately sets `c->timedout = 1` (even though nothing actually timed
out) purely to get the abrupt-RST-via-`SO_LINGER` behavior from
`ngx_http_free_request` (§10) rather than a graceful FIN.

**408 Request Timeout**: fires from the `rev->timedout` branch in both
`ngx_http_process_request_line` (`:1130-1135`) and
`ngx_http_process_request_headers` (`:1420-1425`) — i.e. whenever
`client_header_timeout` expires while still reading the request line or headers,
independent of `client_body_timeout` (body-read timeouts instead produce a `400`
via a different path, `ngx_http_do_read_client_request_body`'s
`c->error = 1; return NGX_HTTP_BAD_REQUEST;` on a hard read error/EOF — not
timeout-specific there; the *timer* itself firing during body read re-arms via
`ngx_add_timer(c->read, clcf->client_body_timeout)` and its expiry is handled
generically by the event layer marking `rev->timedout`, which
`ngx_http_do_read_client_request_body` does not special-case separately from
other read errors in the excerpt I read — flagged as needing a closer look at the
exact 408-vs-400 boundary for body timeouts specifically if we want to match it
precisely).

## 10. Close / shutdown protocol (lingering close, FIN, half-close, RST)

Three distinct connection-teardown paths, chosen in
`ngx_http_finalize_connection` (`src/http/ngx_http_request.c:2998-3075`, already
substantially quoted in §1/§9):

```c
// src/http/ngx_http_request.c:3042-3075 (abbreviated)
if (r->reading_body) {
    r->keepalive = 0;
    r->lingering_close = 1;
}

if (r->keepalive && clcf->keepalive_min_timeout > 0) {
    ngx_http_set_keepalive(r);
    return;
}
if (!ngx_terminate && !ngx_exiting && r->keepalive && clcf->keepalive_timeout > 0) {
    ngx_http_set_keepalive(r);
    return;
}

if (clcf->lingering_close == NGX_HTTP_LINGERING_ALWAYS
    || (clcf->lingering_close == NGX_HTTP_LINGERING_ON
        && (r->lingering_close
            || r->header_in->pos < r->header_in->last   /* unconsumed pipelined bytes */
            || r->connection->read->ready                /* more bytes sitting in the socket */
            || r->connection->pipeline)))
{
    ngx_http_set_lingering_close(r->connection);
    return;
}

ngx_http_close_request(r, 0);   /* immediate close, no linger */
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L3042-L3075)

So three outcomes per finished request: (1) recycle into keep-alive, (2) enter
lingering close, (3) close immediately. **Lingering close default policy
(`lingering_close on`) only actually lingers if there's a concrete reason to
believe the client sent/is sending more** — either the flag was set explicitly
elsewhere (large-header abort, still-reading-body-when-finalizing, certain error
paths from §9), or there are literally unconsumed bytes already buffered
(`r->header_in->pos < r->header_in->last`), or the read event is currently
`ready` (kernel says more bytes are waiting), or this connection ever pipelined.
A plain, cleanly-finished, non-pipelined, nothing-buffered request with
`keepalive` disabled just closes immediately — nginx does not linger
unconditionally even with the default `on` policy; `lingering_close always` is
what forces it unconditionally.

**Lingering close mechanics** — `ngx_http_set_lingering_close`
(`:3727-3795`) + `ngx_http_lingering_close_handler` (`:3798-3855`), both quoted
in full earlier:
1. If TLS, do an SSL-level shutdown first (`shutdown_without_free`,
   `ngx_ssl_shutdown`), which can itself return `NGX_AGAIN` and defer.
2. **Half-close the write side**: `ngx_shutdown_socket(c->fd, NGX_WRITE_SHUTDOWN)`
   — i.e. `shutdown(fd, SHUT_WR)`, sending a TCP FIN while leaving the read side
   open. This is the literal "half-close" the task asked about: nginx tells the
   client "I'm done sending" without yet closing the file descriptor, so it can
   keep reading (and discarding) whatever the client is still transmitting.
3. Switch the read handler to `ngx_http_lingering_close_handler`, which drains up
   to `NGX_HTTP_LINGERING_BUFFER_SIZE` (4096) bytes at a time into a throwaway
   stack buffer, in a loop bounded by `rev->ready`
   (`do { n = c->recv(...) } while (rev->ready);` — drains everything immediately
   available, not just one read per event).
4. Two independent expiries bound this drain: `lingering_time` (default 30s,
   wall-clock deadline computed once as `r->lingering_time = ngx_time() +
   lingering_time/1000` and checked every time the handler re-enters,
   `:3819-3823`) and `lingering_timeout` (default 5s, an **idle** timer re-armed
   after each successful drain round, `:3846-3854`, itself clamped to not exceed
   the *remaining* `lingering_time`). So: if the client keeps trickling bytes,
   nginx keeps resetting a short 5s idle timer, but never waits past the original
   30s wall-clock budget in total.
5. On EOF, read error, or either timer firing, or the parent `c->close` flag:
   `ngx_http_close_request(r, 0)` — the actual final close.

**Abrupt close (RST) path** — `ngx_http_free_request`
(`src/http/ngx_http_request.c:3980-4072`), the function that runs right before
the connection is actually torn down:
```c
// src/http/ngx_http_request.c:4034-4053
if (r->connection->timedout
#if (NGX_HTTP_V3)
    && r->connection->quic == NULL
#endif
   )
{
    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);
    if (clcf->reset_timedout_connection) {
        linger.l_onoff = 1;
        linger.l_linger = 0;
        setsockopt(r->connection->fd, SOL_SOCKET, SO_LINGER, &linger, sizeof(linger));
    }
}
```
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_request.c#L4034-L4053)
`SO_LINGER{on, 0}` makes the subsequent `close()` send an immediate **RST**
instead of the normal FIN/`TIME_WAIT` sequence — this is opt-in
(`reset_timedout_connection`, default off, not one of the directives the task
asked me to enumerate but relevant context) and only triggers when
`c->timedout` is set, which happens for genuine timeouts (client/header/body/send
timeout paths) **and** is deliberately spoofed for the `444`
(`NGX_HTTP_CLOSE`) sentinel (§9) specifically to get this RST behavior for
"just make this connection go away right now" semantics.

**Plain close** — `ngx_http_close_connection`
(`src/http/ngx_http_request.c:4093-4129`): SSL shutdown (possibly deferred if
`NGX_AGAIN`), then `ngx_close_connection(c)` (the generic nginx core connection
teardown — actual `close(fd)`) plus pool destruction. No FIN/half-close dance
here; this is what runs either directly (no keep-alive, no lingering) or as the
tail of the lingering-close and RST paths once draining is done.

**Idle-connection memory hygiene**: both `ngx_http_wait_request_handler`
(`:450-460`) and `ngx_http_set_keepalive` (`:3463-3484`) explicitly `ngx_pfree`
the connection's read buffer back to the pool allocator when idle (leaving
`b->pos = NULL` as a sentinel that `ngx_http_keepalive_handler`/
`ngx_http_wait_request_handler` check to know they must re-`ngx_palloc` before the
next read) — the point being that a large fleet of idle keep-alive connections
shouldn't each be pinning a `client_header_buffer_size`-or-larger buffer in
memory. Worth copying: keep-alive connections should not hold onto per-connection
read buffers while idle.

## 11. Application handler API shape

nginx's module/handler API is **phase-based**, not a single request-handler
callback. Phases, in order (`src/http/ngx_http_core_module.h:109-128`):
`NGX_HTTP_POST_READ_PHASE`, `NGX_HTTP_SERVER_REWRITE_PHASE`,
`NGX_HTTP_FIND_CONFIG_PHASE`, `NGX_HTTP_REWRITE_PHASE`,
`NGX_HTTP_POST_REWRITE_PHASE`, `NGX_HTTP_PREACCESS_PHASE`,
`NGX_HTTP_ACCESS_PHASE`, `NGX_HTTP_POST_ACCESS_PHASE`,
`NGX_HTTP_PRECONTENT_PHASE`, `NGX_HTTP_CONTENT_PHASE`, `NGX_HTTP_LOG_PHASE`.
(https://github.com/nginx/nginx/blob/ef0aa967dce9d30b824d4c839d3579d2a17e0666/src/http/ngx_http_core_module.h#L109-L128)

Driven by `ngx_http_core_run_phases` (`src/http/ngx_http_core_module.c:893-912`):
a flat, precompiled array of `(checker, handler)` pairs is walked; each phase's
checker decides whether to advance `r->phase_handler` or return (deferring — e.g.
waiting on a subrequest or async I/O). Relevant typedefs
(`src/http/ngx_http_request.h:301,381-382`):
```c
typedef void      (*ngx_http_client_body_handler_pt)(ngx_http_request_t *r);
typedef ngx_int_t (*ngx_http_handler_pt)(ngx_http_request_t *r);
typedef void      (*ngx_http_event_handler_pt)(ngx_http_request_t *r);
```
Content-phase handlers return `ngx_int_t` (`NGX_OK`, `NGX_DECLINED`,
`NGX_AGAIN`, or an HTTP status code to short-circuit to
`ngx_http_finalize_request`); the connection itself exposes
`r->read_event_handler`/`r->write_event_handler` (both
`ngx_http_event_handler_pt`, i.e. plain `void (*)(ngx_http_request_t*)`)
that get repointed constantly as the request moves through states — e.g.
`ngx_http_block_reading` while a handler doesn't want more input,
`ngx_http_test_reading` while producing output but watching for client
disconnect, `ngx_http_writer` while flushing a buffered response
(`src/http/ngx_http_request.c:3078-3108,3194-3213`, already quoted/referenced
above). Request-body consumption is its own explicit call
(`ngx_http_read_client_request_body(r, post_handler)`) that a content handler
opts into rather than the body being pre-read for it, mirroring the design
decision we should make explicitly for chez-http-server given chez-httparse's
callback-per-span parsing model.

Everything is driven off a single mutable `ngx_http_request_t` per (sub)request,
with `r->main` pointing at the top-level request for a subrequest tree,
`r->count`/`r->blocked` reference-counting when the request object may be freed,
and cleanup handlers (`r->cleanup`, a linked list, run in
`ngx_http_free_request`/`ngx_http_terminate_request`) as the RAII-equivalent for
resource teardown — this is the piece most different from what an R6RS/Scheme
design would naturally do (we'd more likely use dynamic-wind /
`call/cc`-free explicit close registries given chez-libuv's "server must own
every close initiation" rule from ADR-0007).

## 12. What nginx's own test suite covers (files worth copying scenarios from)

All from the `Test::Nginx` Perl harness (`nginx-tests` distribution, the same
suite already present in this session's scratchpad at
`scratchpad/fetched/nginx-tests/`, each file headed `(C) Maxim Dounin` or
`(C) Nginx, Inc.` / `(C) Sergey Kandaurov`, confirmed by `head -15` on each file
listed below):

- **`http_keepalive.t`** (209 lines) — exercises `keepalive_requests` and
  `keepalive_timeout` directly, including per-server-block overrides (`grep`
  shows `keepalive_requests 2;`/`keepalive_timeout 1 9;` at the `http{}` level vs
  `keepalive_requests 4;`/`keepalive_timeout 30s;` and `... 100;`/`... 75s;` on
  different server blocks, plus a `keepalive_timeout 0;` server to test
  keep-alive-disabled). Directly maps to our §1/§5.
- **`http_keepalive_shutdown.t`** — keep-alive behavior specifically around
  worker shutdown (the `ngx_terminate || ngx_exiting` veto from §1c).
- **`http_expect_100_continue.t`** (107 lines) — `Expect: 100-continue` handling,
  directly maps to our §6.
- **`http_header_buffers.t`** (248 lines) — `large_client_header_buffers`
  behavior (buffer promotion, `414`/`494`(→400) boundaries), maps to our §5/§9.
- **`http_max_headers.t`** (74 lines) — `max_headers` limit, maps to our §5/§9.
- **`http_headers_multi.t`** — duplicate/multi-valued headers, maps to our §8.
- **`ignore_invalid_headers.t`** — the `ignore_invalid_headers` directive's skip
  behavior, maps to our §8/§9 (invalid header line handling in
  `ngx_http_process_request_headers`, `:1490-1499`).
- **`http_host.t`** — `Host` header validation/virtual-server selection, maps to
  our §1/§8 (`ngx_http_validate_host`, `ngx_http_process_host`).
- **`http_uri.t`**, **`merge_slashes.t`** — request-URI/request-line parsing
  edge cases (not deeply covered in this report but relevant to
  `ngx_http_process_request_uri`, §1's quoted function).
- **`http_method.t`** — request method parsing/dispatch.
- **`body.t`** (233-ish lines shared range) / **`body_chunked.t`** (233 lines) —
  request body reading, `Content-Length`-bounded and chunked, maps to our §3.
- **`client_body_early_read.t`** — the `client_body_early_read` /
  `ngx_http_read_early_body` early-body-read path we read in §1 around
  `src/http/ngx_http_request.c:2221-2273`.
- **`trailers.t`** — chunked trailers / `expect_trailers`, maps to our §8's
  `r->expect_trailers` clearing of `Content-Length` in the chunked filter.
- **`request_id.t`**, **`server_tokens.t`**, **`headers.t`** — response-header
  generation edge cases (server tokens on/off/build maps to
  `ngx_http_header_filter`'s three `Server:` string variants, §1).
- **`http_request_port.t`** — port-in-`Host`-header handling
  (`ngx_http_validate_host`'s port parsing).

**Gap noted**: no dedicated pipelining test file exists in this suite (confirmed
by grepping the full nginx repo file tree already cached in the scratchpad at
`scratchpad/nginx_root_list.txt` for `pipelin` — zero hits under `src/` and no
`*.t` file named for it). Pipelining is only exercised incidentally (leftover
bytes in a keepalive test's read buffer). **This is itself a lesson**: if we want
confidence in chez-http-server's pipelining behavior (which chez-httparse's own
measured finding — "the connection layer must stop feeding after a close-marked
message" — makes a real correctness concern, not just a performance one), we
should write our *own* dedicated pipelining test file rather than expect to find
one to crib from nginx.

## 13. Concrete lessons for chez-http-server

1. **Keep-alive is a three-layer decision, and we should structure ours the same
   way**: (a) an initial per-request policy from HTTP version + `Connection`
   token (HTTP/1.1 defaults on, HTTP/1.0 defaults off, explicit tokens override),
   (b) location/config-level vetoes evaluated *after* routing (limits like
   request-count and max-connection-age), (c) a final framing-level veto: if the
   response body has no `Content-Length` and we can't/won't chunk it (HTTP/1.0,
   or chunking disabled), keep-alive must be forced off — a close-delimited body
   and a reusable connection are mutually exclusive, full stop. Given
   chez-httparse's `parser-field-ref` flags (`F-CONNECTION-KEEP-ALIVE`,
   `F-CONNECTION-CLOSE`, `F-CONNECTION-UPGRADE`) already surface (a) for us
   nearly for free — we should read them *inside* the relevant callback per the
   project's own measured warning that inter-message reset zeroes flags.

2. **Pipelining should be structurally serial, never overlapped**, matching
   nginx: read-ahead into the connection's buffer is fine and even necessary for
   TCP efficiency, but only one request should ever be "in flight" through
   read → parse → handle → write-response at a time per connection; the next
   request's processing should only start after the previous response is fully
   queued/sent and the connection recycled. This sidesteps response-ordering
   entirely (no reordering possible if there's no concurrency) and is a natural
   fit for chez-libuv's single-callback-at-a-time-per-loop-thread model — we
   don't need a queue of pending responses, just "don't call
   `uv-read-start!` /keep reading past the parser's message boundary
   until the current response's `uv-write!` has completed." Recall
   chez-httparse's own measured finding: after a `Connection: close`-marked
   message, feeding a pipelined second request produces `'error` (llhttp's
   "data after close") — so our connection layer, like nginx's, must be the one
   enforcing "stop reading further requests once this message is close-marked",
   not rely on the parser to reject it gracefully.

3. **Defer stack-depth risk on deep pipelines via a posted-work pattern.** nginx
   uses `ngx_post_event`+`ngx_http_run_posted_requests` specifically so a long
   pipeline of tiny requests doesn't recurse the C stack once per request. Since
   we're on Chez with cheap continuations/trampolining idioms, we have an easy
   native way to get the same property (a work-loop that re-enters rather than a
   self-recursive continuation chain per pipelined request) — worth calling out
   explicitly in the design so nobody accidentally writes a recursive "handle
   next pipelined request" call.

4. **Backpressure, both directions, should be "stop touching the transport, let
   the reactor wake us up" — never an unbounded internal buffer.** Request-body
   reads stop (`NGX_AGAIN`, no more `uv-read-start!`/equivalent) when the
   downstream consumer hasn't drained the current buffer; response writes stop
   (`NGX_AGAIN`) when the OS accepted only a partial chain. Given chez-libuv's
   ADR-0018 ("no bounded write queue in the binding — consumer tracks
   outstanding bytes/requests and reads `uv-stream-write-queue-size` as a
   congestion signal") and the "backpressure verbs are `uv-read-stop!`/
   `uv-read-start!`" fact, this maps directly: our body-reader should call
   `uv-read-stop!` when its own fixed-size body buffer is full and not yet
   handed to the application, and resume with `uv-read-start!` once drained —
   exactly nginx's `rb->buf->last == rb->buf->end` / `rb->busy != NULL` gate. On
   the write side, we should poll `uv-stream-write-queue-size` (nginx's
   equivalent of "the send_chain returned a nonempty leftover chain") before
   queuing more response bytes, and register interest in resuming once it drops,
   the way nginx's `ngx_http_writer` re-registers for write-readiness.

5. **Pick real limits with real, named defaults — don't leave any unbounded.**
   nginx bounds: header line count (`max_headers`, 1000), header buffer size
   escalation (`client_header_buffer_size` 1KB → `large_client_header_buffers`
   4×8KB, i.e. a hard ceiling of 32KB of headers total before `494`→400), request
   body size (`client_max_body_size`, 1MB default — deliberately small; most
   real deployments raise it), and independent idle-timeouts for each phase
   (`client_header_timeout` 60s, `client_body_timeout` 60s — re-armed per-read,
   not a total-duration budget, `send_timeout` 60s similarly per-write,
   `keepalive_timeout` 75s idle-between-requests, `keepalive_time` 1hr
   *total-connection-age* cap independent of idle activity, `keepalive_requests`
   1000 request-count cap). We should adopt this same shape — per-phase idle
   timers, not one global request timeout — since our own libuv timer handles
   are cheap (one `make-uv-timer` per timer, per the project facts) and this
   gives much better diagnostics (a slow-body-drip client looks different from a
   slow-header-drip client) than a single deadline would.

6. **The close-delimited-response rule is non-negotiable and must be enforced at
   the framing layer, not left to application code.** If our response API lets a
   handler stream a body without declaring its length up front, and we can't
   chunk (client is HTTP/1.0, or we choose not to support response chunking
   initially), we must set "close this connection after this response" as a
   *side effect of that framing choice*, the same way nginx's chunked-filter
   module does — this should not be something the handler has to remember to
   ask for.

7. **`431`/`494` decision point**: nginx's "header too large" is really its own
   internal `494` with a `400` wire status — a legacy choice that predates RFC
   6585. For chez-http-server we should explicitly decide whether to send the
   modern, correct `431 Request Header Fields Too Large` (recommended — nginx is
   not a precedent to follow here, it's a historical accident) rather than
   silently copying nginx's `400`.

8. **Half-close (`shutdown(fd, SHUT_WR)`) before full close, with two independent
   timers, is the right shape for lingering close**, and is directly expressible
   with chez-libuv: send FIN via a write-shutdown-equivalent (check whether
   chez-libuv v0.5.0 exposes `uv_shutdown` — not confirmed in the facts given;
   worth checking, since "NOT bound" list in the brief doesn't mention it
   explicitly one way or the other, only vectored writes/`uv_try_write`/TCP
   keepalive/UDP/fs are explicitly called out as unbound), keep the read side
   open, drain-and-discard with a *short* idle timer (nginx: 5s) nested inside a
   *longer* wall-clock budget (nginx: 30s), and only then call the real close.
   Since chez-libuv's ADR-0007 says close is explicit/async/"a server must own
   every close initiation" and a second `uv-close!` on a closing handle silently
   discards its callback, our lingering-close state machine needs to be
   careful to initiate exactly one `uv-close!` per handle even across the
   half-close → drain → timeout → close sequence — a good candidate for an
   explicit small state machine (`open` → `draining` → `closing` → `closed`)
   rather than ad hoc flags, given how easy it'd be to double-close a handle
   across that many event callbacks.

9. **`Expect: 100-continue` is cheap to get right**: a one-shot latch
   (equivalent to nginx's `r->expect_tested`) set before any size/policy
   rejection path, an unconditional "send `100 Continue`, no auth/policy gate"
   for anything under the size limit, and a pre-latch when we already know we're
   rejecting for size (`Content-Length` > our max) so we never promise the
   client "go ahead" right before saying "too large." Unlike nginx's raw
   assumed-to-succeed `send()`, we should route the 100-continue response
   through our normal (backpressure-aware) write path — chez-libuv's uv-write!
   already copies-and-frees, so there's no reason to special-case this as an
   unchecked blocking write the way nginx does; that's a wart we don't need to
   inherit.

10. **Duplicate-header rejection is selective, not blanket, and we should be
    explicit about which headers get it.** nginx uniquely-checks (400 on
    duplicate): `Host`, `Content-Length`, `Transfer-Encoding`, `Expect`,
    `If-Modified-Since`/`If-Unmodified-Since`/`If-Match`/`If-None-Match`/
    `If-Range`, `Content-Range`, `Authorization`/`Proxy-Authorization`. It
    explicitly does **not** unique-check `Connection`, `Cookie`,
    `Accept-Encoding`, `User-Agent`, etc. (comma/multi-instance-tolerant
    headers). We should classify our own header set the same way rather than
    either rejecting all duplicates (too strict, breaks legitimate multi-value
    headers like `Cookie`) or accepting all duplicates (opens request-smuggling
    surface via `Content-Length`/`Transfer-Encoding`).

11. **Upgrade/CONNECT are out-of-band modes, not extensions of the normal
    request/response state machine.** nginx's core connection layer validates
    and then gets out of the way (CONNECT: location-gated + version-gated +
    no-body-allowed; Upgrade: purely a response-header emission concern at the
    core layer, with the actual tunnel implemented in a separate module). We
    should design our connection state machine with an explicit "hand off to
    raw-relay mode" transition (stop HTTP parsing, stop applying HTTP framing to
    writes) rather than trying to make keep-alive/pipelining code paths handle
    it as a degenerate case.

12. **Idle connections shouldn't pin large buffers.** Both of nginx's idle paths
    (waiting for the first request line, and waiting for the next
    keep-alive request) free the connection's read buffer back to the allocator
    while idle and lazily reallocate on the next read. Given chez-libuv's
    "each `uv-read-start!` commits a 64 KiB foreign read buffer per connection
    until close" fact, this nginx pattern is *extra* relevant to us: 64 KiB is
    far larger than nginx's 1 KiB `client_header_buffer_size` default, so a
    large idle-keepalive fleet under chez-http-server could be meaningfully more
    memory-hungry than under nginx unless we actively manage it — e.g. by
    calling `uv-read-stop!` while idle-keepalive-waiting and only
    `uv-read-start!` again... but note chez-libuv's own read-buffer commitment
    is presumably tied to `uv-read-start!` itself, so if we truly want to shed
    that 64 KiB while idle we may need to `uv-read-stop!` between requests and
    re-`uv-read-start!` on the next one, trading a syscall for the memory —
    worth a deliberate design decision and probably a dedicated ADR, since it's
    a real difference in buffer-ownership model from nginx's own
    userspace-managed buffers.

13. **Application handler API**: nginx's phase-pipeline (11 phases, each with a
    checker+handler array, explicit `NGX_AGAIN`/`NGX_DECLINED`/status-code
    return protocol) is more machinery than we likely want for a v1
    chez-http-server. The narrower, directly-portable idea is the **explicit
    body-read opt-in**: a handler is invoked once headers are parsed and can
    choose whether/when to ask for the body (`ngx_http_read_client_request_body`
    taking a continuation/post-handler), rather than the body being eagerly
    read before the handler runs. This maps naturally onto chez-httparse's own
    callback shape and keeps us from committing to full-buffering as the only
    mode — we can offer a "give me the body as a single bytevector"
    convenience API for simple handlers while keeping a lower-level streaming
    path open for proxying-style use cases, exactly as nginx does with
    `request_body_no_buffering`.
