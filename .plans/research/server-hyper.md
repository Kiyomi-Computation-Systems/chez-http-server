# hyper HTTP/1 server: connection-semantics deep read

Source: `github.com/hyperium/hyper`, fetched from `raw.githubusercontent.com` at commit
`e89d0d93d9566210ee95aea234a00952ebc4a202` (tip of `master` at fetch time, resolved via
`https://api.github.com/repos/hyperium/hyper/git/refs/heads/master` on 2026-09-19).
All files below were fetched with `curl` directly (not `WebFetch`, which summarizes/truncates)
and read in full or in the cited ranges with the `Read` tool, so line numbers are exact against
this commit. Local copies live in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/hyper-src/`.

Files fetched and confirmed readable (HTTP 200, all via
`https://raw.githubusercontent.com/hyperium/hyper/e89d0d93d9566210ee95aea234a00952ebc4a202/<path>`):

| path | local copy | lines |
|---|---|---|
| `src/proto/h1/conn.rs` | `src_proto_h1_conn.rs` | 1449 |
| `src/proto/h1/role.rs` | `src_proto_h1_role.rs` | 3233 (read 1–1150) |
| `src/proto/h1/dispatch.rs` | `src_proto_h1_dispatch.rs` | 873 |
| `src/proto/h1/io.rs` | `src_proto_h1_io.rs` | 963 |
| `src/proto/h1/encode.rs` | `src_proto_h1_encode.rs` | 698 |
| `src/proto/h1/decode.rs` | `src_proto_h1_decode.rs` | 1287 (read 1–260) |
| `src/proto/h1/mod.rs` | `src_proto_h1_mod.rs` | 113 |
| `src/server/conn/http1.rs` | `src_server_conn_http1.rs` | 572 |
| `src/headers.rs` | `src_headers.rs` | 220 |
| `src/error.rs` | `src_error.rs` | 740 (read 1–130 + grep) |
| `src/body/incoming.rs` | `src_body_incoming.rs` | 522 |
| `src/body/chan.rs` | `src_body_chan.rs` | 264 |
| `tests/server.rs` | `tests_server.rs` | 4063 (95 tests catalogued, several read verbatim) |
| `tests/client.rs` | `tests_client.rs` | 3476 (26 tests catalogued, names only) |
| `tests/h1_flush_before_yield.rs` | `tests_h1_flush_before_yield.rs` | 118 (read in full) |
| `tests/h1_shutdown_while_buffered.rs` | `tests_h1_shutdown_while_buffered.rs` | 205 (read 1–80) |
| `tests/h1_server/mod.rs` | `tests_h1_server_mod.rs` | 97 (read in full) |
| `tests/h1_server/fixture.rs` | `tests_h1_server_fixture.rs` | 136 (fetched, not deep-read) |

Everything cited below is from these files unless marked otherwise. All `file:line` citations are
against the commit above; line numbers may drift on `master` later.

---

## 1. Write buffering strategy: queue vs. flatten

File: `src/proto/h1/io.rs`.

hyper's `Buffered<T,B>` (`io.rs:32-40`) holds a `read_buf: BytesMut` and a `write_buf: WriteBuf<B>`.
`WriteBuf` has two strategies, chosen once at construction and switchable only before any data is
buffered (debug-asserted empty queue, `io.rs:100-112`):

```rust
// io.rs:59-65
pub(crate) fn new(io: T) -> Buffered<T, B> {
    let strategy = if io.is_write_vectored() {
        WriteStrategy::Queue
    } else {
        WriteStrategy::Flatten
    };
    ...
}
```

- **`WriteStrategy::Flatten`** (`io.rs:550-572`): every buffered chunk (headers, body chunks,
  chunked framing) is **copied** into one growable `Vec<u8>` (`headers: Cursor<Vec<u8>>`,
  `io.rs:520-521`). One `poll_write` per flush (`poll_flush_flattened`, `io.rs:311-328`). Used when
  the transport doesn't support vectored writes (typical for most TLS wrappers — see the builder
  doc comment on `writev`, `src_server_conn_http1.rs:357-372`) or when explicitly requested.
- **`WriteStrategy::Queue`** (`io.rs:573-580`): each buffered chunk is pushed **by reference** (no
  copy) onto a `BufList<B>` (a deque of `Buf`s, `common::buf::BufList`, not fetched but used via
  `queue.push`/`queue.chunks_vectored`). Flush uses `poll_write_vectored` with up to
  `MAX_WRITEV_BUFS = 64` iovecs per syscall (`io.rs:281-303`), advancing the queue as the kernel
  accepts bytes. Falls back to `MAX_BUF_LIST_BUFFERS = 16` distinct buffers before a flush is
  forced regardless of readiness (`io.rs:25-30`, `can_buffer` at `io.rs:584-591`).
- Header bytes always go through the same `headers: Cursor<Vec<u8>>` regardless of strategy
  (`headers_buf()`, `io.rs:139-142`); only *body* chunks differ between flatten (copied into that
  same `Vec<u8>`) and queue (kept as separate `Buf`s). `WriteBuf::chunk()`/`chunks_vectored()`
  (`io.rs:614-643`) always drain `headers` before `queue`, so a message is never reordered.
- `Buffered::can_buffer()` (`io.rs:157-159`) is the write-side backpressure gate the dispatcher
  polls before accepting another body chunk from the handler:
  `self.flush_pipeline || self.write_buf.can_buffer()`, where `can_buffer()`
  (`io.rs:584-591`) is `remaining() < max_buf_size` (flatten) or
  `queue.bufs_cnt() < 16 && remaining() < max_buf_size` (queue). `max_buf_size` defaults to
  `DEFAULT_MAX_BUFFER_SIZE = 8192 + 4096*100 = 417792` bytes (~408 KiB, `io.rs:23`, doc-referenced
  from `Builder::max_buf_size`, `src_server_conn_http1.rs:374-388`), floor
  `MINIMUM_MAX_BUFFER_SIZE = INIT_BUFFER_SIZE = 8192` (`io.rs:15-18`).
- **Lesson**: the same `max_buf_size` knob governs (a) the header-parse read-buffer ceiling
  (`Error::TooLarge`/431, see §7) and (b) the response write-buffer ceiling. hyper conflates read
  and write buffer caps into one number; worth deciding explicitly whether chez-http-server wants
  them coupled or separate, since libuv's 64 KiB per-connection foreign read buffer is a different
  knob from whatever bound we put on outstanding write bytes.

## 2. Read buffering: adaptive sizing

`ReadStrategy::Adaptive` (`io.rs:365-434`) starts each connection's read chunk size at
`INIT_BUFFER_SIZE = 8192` and doubles it (`incr_power_of_two`) whenever a read fills the entire
requested size, up to `max` (default `DEFAULT_MAX_BUFFER_SIZE`). It requires **two consecutive**
under-sized reads before halving (`decrease_now` flag, `io.rs:401-433`), and never decreases below
`INIT_BUFFER_SIZE`. This directly maps onto libuv's per-connection read buffer: our design commits
to one fixed 64 KiB `uv-read-start!` buffer per connection (per the project brief), so this
adaptive-resize behavior is *not* directly portable — but the two-strikes-before-shrink hysteresis
is a reusable idea if we ever want to size chez-httparse's feed buffer dynamically instead of
fixed 64 KiB.

## 3. Keep-alive / close decision rule

**Parse-side (request), `role.rs` `Server::parse`, `role.rs:146-380`:**

```rust
// role.rs:191-199
version = if req.version.expect("httparse completed") == 1 {
    keep_alive = true;   // HTTP/1.1 defaults to keep-alive
    is_http_11 = true;
    Version::HTTP_11
} else {
    keep_alive = false;  // HTTP/1.0 defaults to close
    is_http_11 = false;
    Version::HTTP_10
};
```

Then per `Connection` header line encountered while walking headers (`role.rs:310-319`):

```rust
header::CONNECTION => {
    // keep_alive was previously set to default for Version
    if keep_alive {
        // HTTP/1.1
        keep_alive = !headers::connection_close(&value);
    } else {
        // HTTP/1.0
        keep_alive = headers::connection_keep_alive(&value);
    }
}
```

`connection_close`/`connection_keep_alive` (`headers.rs:13-43`) split the header value on `,` and
`eq_ignore_ascii_case` each token against `"close"`/`"keep-alive"` — so `Connection: keep-alive,
close` and multi-token values are handled per RFC 7230 §6.1. Only the **last** `Connection` header
*line* wins in this loop (each new line's value overwrites `keep_alive` again) — i.e. hyper does
not OR across multiple `Connection:` header lines when parsing a request (contrast with encode-side
`connection_any_close`, §item below, and with `write_head`'s pre-emptive `Connection: close`
check, which *does* scan all lines via `get_all`).

Framing forces close regardless of `Connection` value: if both `Transfer-Encoding` and
`Content-Length` were both present (ambiguous framing, RFC 7230 §3.3.3 case 3+5), hyper accepts
`Transfer-Encoding: chunked` (dropping any duplicate/secondary `Content-Length`, `role.rs:279-287`)
but forces `keep_alive = false` at `role.rs:351-353` — that request will still be served, but the
connection cannot be reused afterward.

**Encode-side (response), `role.rs` `Server::encode`/`encode_headers`, `role.rs:382-511,
652-992`:**

- `is_last` (i.e. "this response closes the connection") starts as `!msg.keep_alive`
  (`role.rs:396-411`), where `msg.keep_alive` (`Encode.keep_alive`, server-only field,
  `mod.rs:85-94`) is computed by `Conn::encode_head` from `self.state.wants_keep_alive()`
  (`conn.rs:636`, i.e. `KA::status() != Disabled`).
- Special-cased: `101 Switching Protocols` is always `is_last = true` in the return tuple sense
  but actually forced through the upgrade path (`role.rs:396-397`: `(Ok(()), true)`); a `2xx`
  response to `CONNECT` is also forced `is_last = true` (`role.rs:398-402`) — both bypass normal
  Content-Length/close bookkeeping since the connection is about to change protocols.
- **1xx status codes cannot be returned as a Response at all** — hyper has no API for a handler
  to answer with e.g. `103 Early Hints`; attempting it replaces the response with `500 Internal
  Server Error` and returns `Error::new_user_unsupported_status_code()` (`role.rs:403-408`). (100
  Continue is handled automatically and out-of-band, see §8; other 1xx codes are simply
  unsupported on the server side of this crate.)
- While walking outgoing headers, a `Connection` header value containing `close` flips
  `is_last = true` even if it wasn't already (`role.rs:838-841`):
  `if !is_last && headers::connection_close(&value) { is_last = true; }` — so a handler can force
  connection close just by setting `Connection: close` on its `Response`, independent of
  `keep_alive`.
- **`fix_keep_alive`** (`conn.rs:666-691`, called from `enforce_version`, `conn.rs:695-723`,
  called from `encode_head` before `role::encode_headers`): if the outgoing `Connection` header
  doesn't already say `keep-alive`, then for an `HTTP/1.0` response with no explicit keep-alive,
  hyper **disables** keep-alive (`self.state.disable_keep_alive()`); for an `HTTP/1.1` response
  where the connection still wants keep-alive, hyper **adds** `Connection: keep-alive` itself.
  I.e. HTTP/1.0 is close-by-default even on the wire out, and hyper is willing to inject the
  keep-alive header for 1.0 peers that expect to see it (proven by the
  `http_10_keep_alive` test — §14).
- **`enforce_version`** (`conn.rs:695-723`) also does the reverse: if the connection's `keep_alive`
  state is already `KA::Disabled` and the response is HTTP/1.1, hyper injects `Connection: close`
  if not already present (`entry.iter().any(headers::connection_close)` check to avoid duplicating
  the token) — this is how a server-triggered close (timeout, `disable_keep_alive()`, etc.)
  surfaces on the wire even for a handler that never touched the `Connection` header.
- **Close-delimited body forces close.** `Encoder::is_close_delimited()` (`encode.rs:104-110`) is
  true only for `Kind::CloseDelimited` (server-only, used when a body's length is unknown *and*
  chunked encoding isn't allowed — HTTP/1.0 peer or a status/method that forbids chunked,
  `role.rs:920-926`). Every place the connection's `Writing` state is finalized checks this flag
  in addition to `is_last`:
  ```rust
  // conn.rs:738-742 (write_body), 764-768 (write_trailers), 810-814 (end_body)
  self.state.writing = if encoder.is_last() || encoder.is_close_delimited() {
      Writing::Closed
  } else {
      Writing::KeepAlive
  };
  ```
  This is the literal "close-delimited response forces close" rule the task asked for: a response
  whose length can only be known by reading until EOF **cannot** be followed by another response
  on the same connection, so hyper marks the connection `Writing::Closed` unconditionally once
  such a body finishes, regardless of any `Connection` header bookkeeping.
- **Request-side `Connection: close` disables pooling up front (client role, but the same
  mechanism exists for server-seen request framing).** `Conn::encode_head`
  (`conn.rs:608-663`) — client-only branch — calls `headers::connection_any_close` on the
  *request* headers and disables keep-alive before encoding if any `Connection` line says close
  (`conn.rs:615-626`), specifically so that hyper's own reuse decision doesn't depend on whether
  the backend server echoes `Connection: close` back. `connection_any_close`
  (`headers.rs:26-31`) is the one place that scans **all** `Connection` header lines
  (`get_all(...).iter().any(connection_close)`) rather than just the last one — added recently per
  the in-file comment and covered by a dedicated unit test
  (`conn.rs:1220-1278`, `client_request_connection_close_disables_keep_alive`) that specifically
  checks a `close` token buried in a comma-separated value and a `close` token in a second
  `Connection:` header line, not just the first.
- **State machine that ties it together**, `conn.rs:1093-1112` (`State::try_keep_alive`):
  ```rust
  fn try_keep_alive<T: Http1Transaction>(&mut self) {
      match (&self.reading, &self.writing) {
          (&Reading::KeepAlive, &Writing::KeepAlive) => {
              if let KA::Busy = self.keep_alive.status() {
                  self.idle::<T>();
              } else {
                  self.close();   // KA was Disabled somewhere along the way
              }
          }
          (&Reading::Closed, &Writing::KeepAlive) | (&Reading::KeepAlive, &Writing::Closed) => {
              self.close();
          }
          _ => (),
      }
  }
  ```
  So keep-alive requires **both** sides (`Reading` and `Writing`) to have reached their
  `KeepAlive` sentinel state simultaneously, *and* the tri-state `KA` flag (`Idle | Busy |
  Disabled`, `conn.rs:1043-1049`) to not have been disabled by any of the mechanisms above. Any
  mismatch (one side closed, one side keep-alive) forces a full `close()`.

## 4. Pipelining policy and response ordering

- **Requests are read strictly in order, and dispatched strictly in order, one in flight at a
  time.** `Dispatcher::poll_read_head` (`dispatch.rs:301-354`) first calls
  `self.dispatch.poll_ready(cx)` — for the server `Dispatch` impl this is
  `if self.in_flight.is_some() { Poll::Pending } else { Poll::Ready(Ok(())) }`
  (`dispatch.rs:634-640`) — so **hyper will not even attempt to parse the next request's head
  until the current handler `Future` has produced (or started producing) its response**. There is
  no concurrent-request-processing inside one `Dispatcher`; pipelining concurrency, if wanted, has
  to come from the application spawning independent tasks and the *transport* being duplicated
  (hyper doesn't do that itself for H1).
- **Response ordering is trivially FIFO** because of the above: `poll_write` only reads
  `self.dispatch.poll_msg` (which resolves the one in-flight future) once
  `conn.can_write_head()` and `body_rx.is_none()` (`dispatch.rs:360-364`), i.e. the previous
  response's body must have fully drained (`body_rx` cleared) before the next response's head can
  even be written. Pipelined *reads* can race ahead of writes (see next point) but the *write*
  order can never be reordered — there is only ever one `MessageHead` outstanding for write at a
  time, sourced directly from the queue-of-one `in_flight` future.
- **What "pipelining enabled/disabled" actually toggles is *flush granularity*, not read/dispatch
  concurrency.** `Builder::pipeline_flush` (`src_server_conn_http1.rs:400-408`) →
  `Conn::set_flush_pipeline` (`conn.rs:96-99`) → `Buffered::set_flush_pipeline`
  (`io.rs:77-84`), which also forces `WriteStrategy::Flatten`. Effect on `poll_flush`
  (`io.rs:271-305`): with `flush_pipeline` on and the *read* buffer still non-empty
  (`self.flush_pipeline && !self.read_buf.is_empty()`), `poll_flush` returns `Ready(Ok(()))`
  **without doing a real `poll_flush` syscall** — i.e. hyper defers the actual `write`/`flush`
  syscall while it believes there's more pipelined request data already buffered to process, so
  that multiple pipelined responses can be coalesced into fewer socket writes. This is exactly what
  the `pipeline_enabled` test (`tests_server.rs:1115-1166`) demonstrates: with two pipelined `GET`s
  written as one `write_all`, and `pipeline(true)`, both responses arrive in a single `read()` on
  the client side; the mirrored `pipeline_disabled` test explicitly says the un-pipelined case is
  "wishy-washy" and might still coalesce due to OS buffering (`tests_server.rs:1099-1107`) —
  i.e. hyper does not *guarantee* per-response flushes even with pipelining "disabled"; it only
  guarantees eventual flush before idling or shutdown. `pipeline_flush` docs call it
  "Experimental, may have bugs" (`src_server_conn_http1.rs:400-404`).
- **The core read/write interleaving loop** is `Dispatcher::poll_loop`
  (`dispatch.rs:166-223`): it round-robins `poll_read` → `poll_write` → `poll_flush` up to **16**
  times per wakeup before explicitly yielding via `task::yield_now`
  (`dispatch.rs:172, 221-222`), with the comment "16 was chosen arbitrarily, as that is number of
  pipelined requests benchmarks often use" (`dispatch.rs:169-171`). This is the mechanism that lets
  several pipelined request/response pairs be processed in one poll without waiting for a fresh
  wakeup, while still bounding worst-case latency/fairness against other connections on the same
  executor.
- **A close-marked message stops further request reads on the *same connection object* only
  through the ordinary `Reading::Closed` transition** — hyper's H1 layer has no special "stop
  feeding the parser after a close-delimited message" branch distinct from the general keep-alive
  state machine (§3); once `Writing`/`Reading` both resolve to `Closed`, `can_read_head()`
  (`conn.rs:175-185`) returns `false` and no more parsing is attempted. This matches the
  chez-httparse finding in the task brief (llhttp's "data-after-close" `'error` on a second
  pipelined message after `Connection: close`): hyper structurally can't hit that case, because it
  stops trying to read a new head as soon as it decides the connection is closing, rather than
  relying on the parser to reject trailing bytes.

## 5. Request body → handler streaming, and backpressure

- The parsed request body is exposed to the handler as `hyper::body::Incoming`
  (`body/incoming.rs`), backed (for H1) by a **single-slot rendezvous channel**,
  `body::chan::{Sender, Receiver}` (`src_body_chan.rs`). The channel's `State` literally holds
  `item: Option<Result<Bytes, Error>>` (`src_body_chan.rs:54-63`) — capacity **exactly one Bytes
  chunk** in flight, confirmed by the unit test `channel_buffers_one`
  (`src_body_incoming.rs:448-458`): a second `try_send_data` while one chunk is unconsumed comes
  back `Err(chunk)` (the chunk itself, un-sent).
- **`Sender::poll_ready`** (`src_body_chan.rs:66-76`) is `Ready(Ok(()))` only when
  `state.want && state.item.is_none() && state.pending_error.is_none()`; otherwise `Pending`. The
  `want` flag starts as `!wanter` (`src_body_chan.rs:19`) and is flipped to `true` the first time
  the `Receiver` is polled (`Receiver::poll_next`, `src_body_chan.rs:167-172`). So for an ordinary
  body (`wanter = false`) the sender is ready immediately; for a body constructed with
  `wanter = true` — which is exactly the **Expect: 100-continue** case
  (`IncomingBody::new_channel(other, wants.contains(Wants::EXPECT))`, `conn.rs:316-317`) — the
  sender is *not* ready until the handler actually calls `.frame()`/polls the body once. This is
  the mechanism behind §8's deferred 100-continue.
- **Dispatcher::poll_read** (`dispatch.rs:225-299`) is the read-side pump: as long as
  `self.conn.can_read_body()`, it (a) polls `body.poll_ready(cx)` — **if `Pending`, it stops
  entirely and returns `Pending`, i.e. it does not read more bytes off the socket while the
  consumer's single body slot is full** (`dispatch.rs:233-238`); (b) on `Ready(Ok(()))`, calls
  `conn.poll_read_body(cx)` to actually decode the next frame from the socket/buffer and
  `body.try_send_data(chunk)`; (c) if the receiver was dropped (`Err(_canceled)` from either
  `poll_ready` or `try_send_data`), it **stops reading application data** and either drains cheaply
  or closes the read side via `conn.poll_drain_or_close_read(cx)` (`dispatch.rs:239-246,
  256-260, 269-274`; `poll_drain_or_close_read` itself at `conn.rs:869-886`). This is hyper's
  read-direction backpressure: the TCP socket is simply not read further once the handler-side
  consumer is saturated, which is directly analogous to calling `uv-read-stop!` in our design —
  except hyper's granularity is "don't poll the OS read" rather than an explicit stop/start pair,
  because tokio's `poll_read` is naturally re-entrant/idempotent to not-call.
- **Chunked body decode limits** (`decode.rs`): `CHUNKED_EXTENSIONS_LIMIT = 1024*16` (16 KiB,
  applied to the whole body's chunk-extensions, not per chunk, `decode.rs:17-20`) and
  `TRAILER_LIMIT = 1024*16` (16 KiB total trailer bytes, `decode.rs:22-25`, overridable via
  `h1_max_header_size` — noted in-code as not yet wired up to a public builder method, "TODO:
  remove this when we land `h1_max_header_size` support", `decode.rs:24` and `conn.rs:312,320`).
  A chunk-size overflow (chunk size line too large to fit `u64`) surfaces as an `io::Error`
  containing the string `"overflow"` (test `post_with_chunked_overflow`,
  `tests_server.rs:523-551`), which the dispatcher turns into a body-stream error
  (`dispatch.rs:288-290`, `body.send_error(crate::Error::new_body(e))`) **without** aborting
  bytes already delivered — the connection is then torn down because
  `conn.rs` moves `Reading` to `Closed` on decode error (`conn.rs:399-402`).

## 6. Response body → wire streaming, and backpressure

- `Dispatcher::poll_write` (`dispatch.rs:356-448`) drives the response body: once headers are
  written (`conn.write_head`), it loops polling the handler's `Body::poll_frame` **only while**
  `self.conn.can_buffer_body()` is true (`dispatch.rs:384-386`); if the write buffer is full
  (`can_buffer_body() == !can_buffer()`, §1), it instead calls `poll_flush` and yields, rather
  than pulling more frames out of the handler's body — i.e. write-direction backpressure is
  "don't ask the handler's `Body` for more data until the transport write buffer has room",
  mirrored against the same `max_buf_size` used for reads (§1).
- Frame handling per `Body::poll_frame` result (`dispatch.rs:401-437`): a data frame that is *not*
  the last one goes to `conn.write_body(chunk)`; a data frame that *is* the body's last frame
  (`body.is_end_stream()`) is written with the combined `conn.write_body_and_end(chunk)`
  (single-call optimization to avoid a separate empty terminator write, `conn.rs:775-793`); a
  trailers frame goes to `conn.write_trailers(...)` (`conn.rs:750-773`, only actually emitted if
  the outgoing headers had a `Trailer:` header whitelisting those field names — see §9); an
  end-of-stream (`None`) triggers `conn.end_body()` (`conn.rs:795-823`), which finalizes chunked
  framing (`0\r\n\r\n`) or, for `Content-Length`, errors with
  `Error::new_body_write_aborted()` if fewer bytes were written than promised
  (`encode.rs:116-126`, `NotEof`). **Empty chunks are silently discarded at the dispatcher level**
  (`dispatch.rs:412-423`, with a `debug_assert!(chunk.remaining() != 0)` re-enforced inside
  `Conn::write_body`/`write_body_and_end`, `conn.rs:725-728, 775-778`) — verified by the
  `body_empty_chunks_ignored` test (`dispatch.rs:844-872`).
- **Encoding kinds** (`encode.rs`): `Kind::Chunked` wraps each chunk as
  `<hex-size>\r\n<data>\r\n` via a small stack-allocated `ChunkSize` `Buf` adapter
  (`encode.rs:340-396`) chained with the data and a static `"\r\n"` tail — **zero-copy**: the
  caller's `Buf`/`Bytes` is chained, not copied, at the encoder layer (copying, if any, happens
  only later at the transport `WriteBuf` flatten step, §1). `Kind::Length(remaining)` tracks
  remaining allowed bytes and silently truncates (`Take<B>`) if the handler tries to write past
  the declared `Content-Length` (`encode.rs:143-152`); `Kind::CloseDelimited`
  (server-only) just writes bytes through with no framing and marks the connection non-reusable
  (§3).
- **Trailers are opt-in and filtered.** `write_trailers` only actually emits bytes if the encoder
  was constructed `into_chunked_with_trailing_fields(names)` from a `Trailer:` response header
  (`role.rs:859-899` on encode, `encode.rs:163-217` on emit) **and** the connection is a server
  that had `allow_trailer_fields` set from the *request's* `TE: trailers` header
  (`conn.rs:750-754`, `headers::te_is_trailers`, `headers.rs:46-63`) — trailers for a field not
  pre-declared in `Trailer:` are dropped with a debug log (`encode.rs:182-190`), and a fixed
  blocklist of "structural" header names (`Authorization, Cache-Control, Content-Encoding,
  Content-Length, Content-Range, Content-Type, Host, Max-Forwards, Set-Cookie, TE, Trailer,
  Transfer-Encoding`, `encode.rs:264-280`) can never be sent as trailers even if declared.

## 7. Named limits and timeouts (with default numbers)

All from `src/proto/h1/io.rs`, `src/proto/h1/role.rs`, `src/proto/h1/decode.rs`,
`src/server/conn/http1.rs`:

| name | default | where | notes |
|---|---|---|---|
| `INIT_BUFFER_SIZE` | **8192 bytes** | `io.rs:15` | initial/minimum read-buffer grow size |
| `MINIMUM_MAX_BUFFER_SIZE` | **8192 bytes** | `io.rs:18` | floor for `Builder::max_buf_size`, panics below it (`src_server_conn_http1.rs:381-387`, test `max_buf_size_panic_too_small`) |
| `DEFAULT_MAX_BUFFER_SIZE` | **417792 bytes** (`8192 + 4096*100`, ~408 KiB) | `io.rs:23` | shared read-buffer-for-headers ceiling *and* write-buffer ceiling; header parse past this returns `Error::TooLarge` → **431** (see §11) |
| `MAX_BUF_LIST_BUFFERS` | **16** | `io.rs:30` | max distinct `Buf`s queued (Queue write strategy) before forced flush |
| `MAX_WRITEV_BUFS` | **64** | `io.rs:281` | iovec cap per `poll_write_vectored` call |
| `DEFAULT_MAX_HEADERS` | **100** | `role.rs:31` | stack-allocated header slot count (`Builder::max_headers` overrides, spills to heap, ~5% perf cost per doc comment `src_server_conn_http1.rs:333-337`); exceeding → `Error::TooLarge` → **431** |
| `MAX_URI_LEN` | **65534 bytes** (`u16::MAX - 1`) | `role.rs:34` | request-target length cap; exceeding → `Parse::UriTooLong` → **414 URI Too Long** (test `http_11_uri_too_long`, `tests_server.rs:1188-1203`) |
| `AVERAGE_HEADER_SIZE` | 30 (bytes, capacity hint only) | `role.rs:32` | not a limit, just an allocation-sizing heuristic |
| `CHUNKED_EXTENSIONS_LIMIT` | **16384 bytes** (`1024*16`) | `decode.rs:20` | total chunk-extension bytes across the whole body |
| `TRAILER_LIMIT` | **16384 bytes** (`1024*16`) | `decode.rs:25` | total trailer-field bytes, marked TODO to become configurable |
| `h1_header_read_timeout` | **30 seconds** | `src_server_conn_http1.rs:250` (`Dur::Default(Some(Duration::from_secs(30)))`) | **only takes effect if a `Timer` is configured** via `Builder::timer()` — with no timer it's silently inert (no header-read timeout at all); resets per-message and also functions as an idle-keep-alive timeout between messages (see §14 tests) |
| `pipeline_flush` | **false** | `src_server_conn_http1.rs:405-408` | "Experimental, may have bugs" |
| `h1_keep_alive` | **true** | `src_server_conn_http1.rs:246, 273-276` | |
| `h1_half_close` | **false** | `src_server_conn_http1.rs:245, 257-268` | client half-close (FIN on write side only) is *not* tolerated unless opted in |
| `date_header` (auto `Date:`) | **true** | `src_server_conn_http1.rs:254, 390-398` | |
| `title_case_headers` | **false** | `src_server_conn_http1.rs:247, 278-285` | |
| poll-loop iteration cap | **16** | `dispatch.rs:172` | not a wall-clock timeout — a fairness bound on pipelined requests processed per wakeup before yielding |

**No separate request-body-read timeout, no separate response-write timeout, and no built-in
idle-connection (post-handshake, no pending message) timeout exist in this crate at all** beyond
what `h1_header_read_timeout` incidentally provides between messages (confirmed by the
`header_read_timeout_as_idle_timeout` test name and body, `tests_server.rs:1656-1697`, which is
literally testing that the *next* request's header-read clock, not a distinct idle timer, is what
kills a connection that goes quiet between pipelined requests). Total-request-duration limits,
max-request-body-size limits, and slow-loris protection beyond the header phase are explicitly left
to the application (e.g. wrapping the `Incoming` body or racing the handler future against a
timeout) — hyper's own docs/tests only cover the header phase.

## 8. `Expect: 100-continue` handling

- Recognized case-insensitively for the token `100-continue` (RFC 2616 §14.20 note in-code,
  `role.rs:320-325`), and **only honored for HTTP/1.1** (`msg.head.version.gt(&Version::HTTP_10)`,
  `conn.rs:311`) — HTTP/1.0 requests with `Expect: 100-continue` are accepted but the expectation
  is silently ignored (test `expect_continue_but_http_10_is_ignored`, name only,
  `tests_server.rs.testnames.txt:36`). A body of length 0 also ignores it with a debug log
  (`conn.rs:303-306`).
- When honored, `Conn::poll_read_head` puts the connection in `Reading::Continue(decoder)` instead
  of `Reading::Body(decoder)` (`conn.rs:311-318`), and marks `Wants::EXPECT`
  (`conn.rs:318, mod.rs:100-103`), which the dispatcher uses to construct the body channel with
  `wanter = true` (`conn.rs:316-317`, §5).
- **The literal `100 Continue` response is only written the first time `poll_read_body` is called
  while still in `Reading::Continue` and `Writing::Init`** (`conn.rs:405-411`):
  ```rust
  Reading::Continue(decoder) => {
      if let Writing::Init = self.state.writing {
          trace!("automatically sending 100 Continue");
          let cont = b"HTTP/1.1 100 Continue\r\n\r\n";
          self.io.headers_buf().extend_from_slice(cont);
      }
      self.state.reading = Reading::Body(decoder.clone());
      return self.poll_read_body(cx);
  }
  ```
  `poll_read_body` is only reached through the dispatcher's read pump, which only calls it once
  `body.poll_ready(cx)` is `Ready` (`dispatch.rs:232-247`) — and because the body channel was
  constructed with `wanter = true`, `poll_ready` is `Pending` until the **handler actually polls
  the `Incoming` body once** (§5). **Net effect: hyper never sends `100 Continue` to a client
  whose handler doesn't touch the request body**, matching RFC 9110 §10.1.1's "MAY immediately
  respond with a final status code" allowance. This is proven end-to-end by
  `expect_continue_waits_for_body_poll` (`tests_server.rs:1022-1069`): the handler drops the
  request (never polls the body) and replies `400 Bad Request`; the client's read buffer shows
  **only** the `400` response — no `100 Continue` ever appears on the wire.
- If the handler *does* poll the body, `poll_drain_or_close_read`
  (called when a body receiver is dropped before EOF, `conn.rs:869-886`) **explicitly skips**
  emitting the 100-continue line even though it still transitions `Continue → Body` — i.e. the
  auto-100 write is strictly tied to the dispatcher's normal `poll_read_body` path, not to every
  possible `Continue → Body` transition.
- No 100-continue is ever sent for HTTP/1.0 (checked above), and no attempt is made to send it if
  the handler races ahead and writes a final status first (`Writing::Init` guard) — a handler that
  responds before ever polling the body simply never triggers the 100-continue write, consistent
  with "hyper currently doesn't support returning 1xx status codes as a Response" (§3) — 100
  Continue is entirely out-of-band from the `Service`/`Response` API.

## 9. Upgrade / CONNECT

- **Upgrade eligibility is detected at parse time**, `role.rs:243, 326-329`:
  `wants_upgrade` starts `true` for `Method::CONNECT` (any `CONNECT` request is presumptively an
  upgrade target) and is separately set to `is_http_11` (i.e. upgrade only recognized for HTTP/1.1)
  when an `Upgrade:` header is present. `Wants::UPGRADE` flows through to `poll_read_head`
  (`conn.rs:297-301`) and, if set, the dispatcher installs an `OnUpgrade` extension
  (`crate::upgrade::Pending`/`OnUpgrade`, obtained via `Conn::on_upgrade` →
  `State::prepare_upgrade`, `conn.rs:915-918, 1169-1173`) onto the parsed `Request`'s extensions
  (`dispatch.rs:322-330`) before calling the handler — the handler discovers the upgrade via
  `hyper::upgrade::on(&req)` and gets a `Future` resolving to the raw `Upgraded` I/O object once
  hyper is done with H1 framing on that connection.
- **The response encode side special-cases both `101 Switching Protocols` and a `2xx` response to
  `CONNECT`** to skip all Content-Length/Transfer-Encoding bookkeeping (`role.rs:396-402`,
  cross-referenced in §3) — sending `Content-Length` or `Transfer-Encoding` on a 2xx CONNECT
  response would violate RFC 7231, so hyper suppresses that logic entirely for those two cases
  rather than letting a handler accidentally emit a framing header hyper would then have to
  reconcile.
- **After the handler responds** (`101` or CONNECT `2xx`), `Dispatcher::poll_inner`
  (`dispatch.rs:143-164`) checks `self.conn.pending_upgrade()`
  (`Conn::pending_upgrade`, `conn.rs:163-165`, simply `self.state.upgrade.take()`) — if present,
  the whole HTTP/1 machinery stops (`Dispatched::Upgrade(pending)`) instead of trying to
  read/write more HTTP frames, and `pending.fulfill(Upgraded::new(io, read_buf))` hands the raw
  I/O object **plus any bytes already read off the wire past the request head** to the upgrade
  future (`src_server_conn_http1.rs:551-566`, the `UpgradeableConnection::poll` impl). This
  "leftover bytes" handoff is exactly the `Parts.read_buf` / `into_parts()` mechanism
  (`src_server_conn_http1.rs:93-107, 151-158`) — confirmed directly by the `upgrades` test
  (`tests_server.rs:1700-1754`): the client writes the upgrade request **and** immediately follows
  it with `"eagerly optimistic"` (protocol data for the *new* protocol, sent before the server's
  `101` even arrives — a legitimate pattern for protocols like WebSocket-over-TLS-with-early-data);
  `parts.read_buf` after `without_shutdown()` contains exactly that leftover string, proving no
  early-arriving post-upgrade bytes are lost or misparsed as a second HTTP request.
- **Two upgrade APIs exist and behave differently.** `Connection::poll_without_shutdown`/
  `without_shutdown()`/`into_parts()` (`src_server_conn_http1.rs:160-205`) is the low-level path
  that *does not* auto-detect upgrade — it's meant for a caller who will manually decide what to
  do next. `Connection::with_upgrades()` → `UpgradeableConnection`
  (`src_server_conn_http1.rs:199-205, 504-572`) is the ergonomic path that wires the above
  `pending_upgrade`/`fulfill` dance to the `hyper::upgrade::on()` future automatically. Plain
  `Connection` (no `.with_upgrades()`) still completes normally on `Dispatched::Upgrade` but calls
  `pending.manual()` instead of fulfilling it (`src_server_conn_http1.rs:217-234`) — i.e. if the
  caller didn't opt in to upgrade support, `hyper::upgrade::on()` futures on that connection will
  resolve to an explicit "upgrades not supported on this API surface" error rather than hanging.
- `graceful_shutdown()` on an already-upgraded connection is a documented no-op
  (`UpgradeableConnection::graceful_shutdown`, `src_server_conn_http1.rs:521-532`,
  and exercised by `http1_graceful_shutdown_after_upgrade`,
  `tests_server.rs:1308-1367`) — once ownership of the raw I/O has passed to the upgrade future,
  the H1 `Connection` object has nothing left to shut down.
- Full HTTP CONNECT tunneling test (`http_connect`, `tests_server.rs:1756+`) and a whole family of
  `h2_connect_*` tests exist for the h2-CONNECT-extended-protocol case (h2 doesn't apply to us) —
  see §14.

## 10. Framing precedence

All in `role.rs` `Server::parse` (`role.rs:146-380`) for parsing, `Server::encode_headers`
(`role.rs:652-992`) for encoding.

- **Parse (request) precedence, per RFC 7230 §3.3.3, implemented literally as the comment says**
  (`role.rs:228-235`):
  1. `Transfer-Encoding: chunked` (only if `chunked` is the *last* token,
     `headers::is_chunked_`, `headers.rs:159-168`, which does `s.rsplit(',').next()`) wins and
     sets `DecodedLength::CHUNKED`; **any earlier-seen `Content-Length` is deleted**
     (`role.rs:278-287`: `if is_cl && con_len.take().is_some() { headers.remove(CONTENT_LENGTH) }`).
     `Transfer-Encoding` on an HTTP/1.0 request is a hard parse error
     (`Parse::transfer_encoding_unexpected`, `role.rs:274-277`).
     `Transfer-Encoding` present but **not** ending in `chunked` is a hard parse error
     (`Parse::transfer_encoding_invalid`, `role.rs:346-349`) — hyper does not attempt to support
     any other transfer-coding.
  2. **Duplicate `Content-Length` headers are only accepted if all values are byte-identical**
     (`role.rs:296-308`); a mismatch is `Parse::content_length_invalid()` → 400. A single
     malformed value (non-digit, leading `+`, overflow — `headers::content_length_parse` /
     `from_digits`, `headers.rs:66-68, 101-126`, strict digit-only parsing, no sign chars
     accepted) is also `Parse::content_length_invalid()` → 400 (test
     `post_with_invalid_prefix_content_length`, `tests_server.rs:478-495`, `Content-Length: +5`
     rejected).
  3. **If both `Transfer-Encoding` (chunked) and `Content-Length` are present on the same
     request, the request is still accepted (TE wins, CL dropped) but keep-alive is force-disabled**
     (`role.rs:351-353`) — this is *more* lenient than RFC 7230 §3.3.3's "server... MUST respond
     with 400 (Bad Request) and then close the connection"; hyper instead processes the request
     with TE semantics and only forces connection close, rather than rejecting outright. Worth
     flagging explicitly as a place we may want to be stricter (reject) for chez-http-server, since
     TE+CL together is a classic HTTP request-smuggling vector.
  4. No `Transfer-Encoding` or `Content-Length` on a **request** → length 0 (implicit,
     `DecodedLength::ZERO` is the starting value and nothing overrides it, `role.rs:237`) —
     hyper never uses close-delimited framing for a *request* body (that `Kind::CloseDelimited`
     encoder is `#[cfg(feature = "server")]` and used only for outgoing *responses*, and on the
     decode side `Kind::Eof` is documented "should only used for Responses",
     `decode.rs:50-66`).
- **Encode (response) precedence** (`role.rs:706-992`): a handler's own `Content-Length` and
  `Transfer-Encoding` response headers are inspected header-by-header while streaming headers out
  (not pre-validated as a batch): 
  - If the `Body` impl reports a **known** length (`BodyLength::Known`) and the handler *also* set
    a `Content-Length` header, hyper trusts the body's length for the wire `Encoder` and just
    forwards the header's bytes verbatim onto the wire (`role.rs:712-744`) — a `debug_assert!`
    (debug builds only) checks they match except for the `HEAD`-with-known-len-0 special case
    (`role.rs:721-730`).
  - If the handler sets **both** a `Content-Length` header *and* the body is `Unknown` length,
    hyper parses the header value to build the `Encoder` (`role.rs:746-783`); a duplicate
    `Content-Length` header with a **different** parsed value at this point is a hard
    `Error::new_user_header()` (request/response rewound, `role.rs:752-761` — this is a
    programming-error-class failure, distinct from the parse-side "accept if identical" rule).
  - A `Transfer-Encoding` response header is honored **only** for HTTP/1.1 and only when
    `Server::can_chunked(method, status)` allows a body at all (`role.rs:812-817`); otherwise it's
    silently dropped. If present and allowed, `must_write_chunked` re-adds a trailing `, chunked`
    token if the handler's own TE value didn't already end in chunked (`role.rs:819-821`,
    `handle_is_name_written!` macro appends it at header-block end, `role.rs:679-696`).
  - **If a handler wrote neither header**, hyper picks framing from `BodyLength`
    (`role.rs:919-962`): `Unknown` → chunked (HTTP/1.1 body-allowed) or close-delimited
    (HTTP/1.0, or method/status forbids chunked); `Known(0)` or `None` → `Content-Length: 0`
    written **only if** `can_have_implicit_zero_content_length` (see HEAD rule below), else no
    header at all, encoder still `Encoder::length(0)`; `Known(len)` → explicit
    `Content-Length: <len>` if `can_have_content_length`, else forced `Encoder::length(0)`
    (silently drops the body — see 204/304/CONNECT below).
  - **`can_have_body`/`can_chunked`** (`role.rs:515-528`) is `false` for: `HEAD` responses, `2xx`
    responses to `CONNECT`, any `1xx` status, `204 No Content`, `304 Not Modified`. When false,
    the final encoder is force-reset to `Encoder::length(0)` regardless of what was computed above
    (`role.rs:965-972`) — i.e. **a handler cannot make hyper send a body for these cases even by
    setting a non-empty Body**; the bytes are simply never encoded onto the wire.
  - **`can_have_content_length`** (`role.rs:530-536`) is `false` for `1xx`, CONNECT-2xx, `204`,
    `304` — so a `Content-Length` header is omitted entirely for those (not even
    `Content-Length: 0`), confirmed by `skips_content_length_for_304_responses` and
    `skips_content_length_and_body_for_304_responses` (`tests_server.rs:2931-2981`).
  - **`can_have_implicit_zero_content_length`** (`role.rs:538-540`) is
    `can_have_content_length && method != HEAD` — i.e. **HEAD responses never get an
    auto-added `Content-Length: 0`** (they only get a Content-Length if the handler explicitly set
    one and it's non-zero via the body's length metadata), confirmed by
    `no_implicit_zero_content_length_for_head_responses` (`tests_server.rs:2983-3001`) — but
    `head_response_can_send_content_length` (`tests_server.rs:598-625`) confirms a handler *can*
    still surface a real `Content-Length` on a HEAD response (representing what a GET would have
    returned), and `head_response_doesnt_send_body` confirms the body bytes themselves are never
    written even if the handler's `Body` yields data.
  - Response body is force-truncated to zero for HEAD/CONNECT-2xx/1xx/204/304 as above, but the
    *value* of an explicit `Content-Length` a handler sets is still passed through verbatim for
    HEAD — no double bookkeeping to keep it consistent with any real body.

## 11. Parse/policy/handler-error → response mapping, and whether the connection closes

`Server::on_error` (`role.rs:484-502`), consumed from `Conn::on_parse_error`
(`conn.rs:830-847`), called only from `Conn::on_read_head_error`
(`conn.rs:333-357`, itself only reachable from `poll_read_head`'s parse-error branch,
**not** the header-read-timeout branch, which returns its error directly without going through
`on_parse_error` at all — see below):

```rust
// role.rs:484-502
fn on_error(err: &crate::Error) -> Option<MessageHead<Self::Outgoing>> {
    let status = match *err.kind() {
        Kind::Parse(Parse::Method)
        | Kind::Parse(Parse::Header(_))
        | Kind::Parse(Parse::Uri)
        | Kind::Parse(Parse::Version) => StatusCode::BAD_REQUEST,       // 400
        Kind::Parse(Parse::TooLarge) => StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE, // 431
        Kind::Parse(Parse::UriTooLong) => StatusCode::URI_TOO_LONG,     // 414
        _ => return None,
    };
    ...
}
```

| condition | status auto-sent? | connection closed? |
|---|---|---|
| bad method token, bad header token/value, bad request-URI syntax, bad/unsupported HTTP version token | **400** | yes — `on_parse_error` only fires when `Writing::Init` (no response started yet, `conn.rs:830-843`); after writing the head it still sets `self.state.error = Some(err)`, and the whole connection tears down once the dispatcher observes that error via `conn.take_error()` in `poll_inner` (`dispatch.rs:159`) — a synthetic error response is always connection-terminal in this codebase, there's no "send 400 and keep going" |
| malformed/duplicate/conflicting `Content-Length` | **400** (via `Parse::Header(Header::ContentLengthInvalid)`) | yes, same path (test `illegal_request_length_returns_400_response`, `tests_server.rs:2690-2711`, and `post_with_invalid_prefix_content_length`, `tests_server.rs:478-495`) |
| `Transfer-Encoding` present but not chunked, or chunked-but-not-last, or TE on HTTP/1.0 | **400** | yes |
| too many headers (over `h1_max_headers`, default 100) or header-parse buffer exceeds `max_buf_size` (`httparse::Error::TooManyHeaders` → `Parse::TooLarge`, `error.rs:661`) | **431** | yes (test `header_name_too_long`, `tests_server.rs:1495-1510`, a 64 KiB single header name) |
| request-target longer than 65534 bytes | **414 URI Too Long** | yes (test `http_11_uri_too_long`, `tests_server.rs:1188-1203`) — note 414 is outside the 400/408/413/431/500/501/505 set the task enumerated; hyper does emit it |
| malformed request line that could plausibly be an **HTTP/2 client preface** (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) arriving on an H1-only listener | **no auto-response at all** — `on_parse_error` short-circuits to `Err(Error::new_version_h2())` before calling `T::on_error` (`conn.rs:832-834`) | yes, connection just errors out; it's the caller's job to decide whether to say anything (relevant if someone points an h2-only client at chez-http-server without ALPN/h2c negotiation) |
| **header-read timeout** (30 s default, only active with a `Timer` configured) | **no auto-response** — the timeout error is returned directly from `poll_read_head` (`conn.rs:260-265`) and never routed through `on_read_head_error`/`on_parse_error`; `Dispatcher::poll_read_head` just does `self.dispatch.recv_msg(Err(err))?` then `self.close()` (`dispatch.rs:334-341`) | yes, socket just closes with no bytes written |
| **clean EOF while idle** (no partial request in the read buffer) | no response (nothing to respond to) — `Poll::Ready(None)` propagates, connection ends cleanly (`conn.rs:352-356`, `should_error_on_eof`/`is_idle` gate, `conn.rs:201-204`); test `empty_parse_eof_does_not_return_error` (`tests_server.rs:1369-1382`) asserts this is `Ok`, not an error at all | yes (but gracefully — no error surfaced to the caller of `serve_connection`) |
| **EOF mid-head or mid-body** (`should_error_on_eof`/`must_error` true because not idle, or the parser saw a partial parse) | **no auto-response** (peer is already gone / half-closed the write side — nothing to send back), surfaces as `Error::new_incomplete()`, `is_incomplete_message() == true` (test `nonempty_parse_eof_returns_error`, `tests_server.rs:1384-1398`) | yes |
| chunked body decode error mid-body (bad hex chunk-size, overflow, missing CRLF, etc.) | **no auto-response** — response headers may already be in flight or the handler may not have written anything yet; either way this is a *body*-stream error (`crate::Error::new_body`), not a head-parse error, so `T::on_error`/`on_parse_error` is never consulted (`dispatch.rs:288-290`); connection is torn down | yes |
| handler `Service::call` future resolves to `Err(e)` | **no auto-response, ever** — `poll_msg`'s `?` (`dispatch.rs:365`, `msg.map_err(crate::Error::new_user_service)?`) propagates straight out of `poll_write`/`poll_loop`/`poll_inner` to `poll_catch`, which calls `self.dispatch.recv_msg(Err(e))?` and returns `Dispatched::Shutdown` (`dispatch.rs:123-141`) — **hyper's H1 server layer has no concept of an automatic 500 Internal Server Error.** A `Service` that can fail must convert every failure into a valid `Response` itself (typically `Infallible` as the service error type is the idiomatic pattern in the ecosystem); an actual `Err` from the service is always connection-fatal in raw hyper. | yes, always |
| handler returns a `1xx` status as its `Response` | replaced with **500** *by hyper itself* before encoding, plus `Error::new_user_unsupported_status_code()` surfaced to the caller (`role.rs:403-408`, test `returning_1xx_response_is_error`, `tests_server.rs:1463-1493`) | yes (the malformed-response path is itself connection-fatal, same as any encode error) |

**501 Not Implemented and 505 HTTP Version Not Supported are never auto-generated anywhere in this
crate.** Unknown/custom HTTP methods are accepted as opaque tokens (`Method::from_bytes` accepts
any valid RFC 7230 token, per `http` crate semantics, not specially rejected in `role.rs`) rather
than triggering 501; unparseable/unsupported HTTP versions fall into the generic
`Parse::Version` → **400** bucket rather than a dedicated 505, with the sole exception of the
literal H2 client-preface bytes, which get no auto-response at all (table above). **408 Request
Timeout is also never sent as a response body** — the header-read-timeout path closes the socket
with no bytes written rather than writing a `408` status line (see table). If chez-http-server
wants 408/501/505 semantics, those are *not* things to copy from hyper — they're gaps to fill
ourselves.

## 12. Close / shutdown protocol

- **`Write::poll_shutdown` is only ever called from one place**: `Dispatcher::poll_inner`
  (`dispatch.rs:143-164`), and only when `self.is_done()` is true **and** the caller asked for a
  real shutdown (`should_shutdown` — `true` for the normal `Future for Dispatcher` impl,
  `dispatch.rs:503-505`; `false` for `poll_without_shutdown`, `dispatch.rs:112-121`, used for
  manual-upgrade callers who want to keep the raw I/O alive). `Conn::poll_shutdown`
  (`conn.rs:856-867`) itself is a thin wrapper: `self.io.poll_shutdown(cx)` →
  `Buffered::poll_shutdown` (`io.rs:330-333`) which **always flushes first**:
  `ready!(self.poll_flush(cx))?; Pin::new(&mut self.io).poll_shutdown(cx)`. So the *intended*
  invariant is "never shut down with unflushed bytes" — and there is a dedicated regression test,
  `tests_h1_shutdown_while_buffered.rs`, documenting a **historical bug** where
  `poll_loop`'s "wants_write_again" fast-path could return `Ready` (triggering shutdown) while a
  `poll_flush` had returned `Pending` moments earlier with bytes still buffered, because the loop
  didn't re-check flush status on that exit path; the test's own comment (`tests_h1_shutdown_while_buffered.rs:1-13`)
  spells out the exact interleaving. A sibling regression test,
  `tests_h1_flush_before_yield.rs` (read in full above, §"write buffering"), documents the mirror
  bug: yielding out of `poll_loop` without a final flush when a body's end-of-stream frame arrived
  on the *second* write-poll of one loop iteration. **Both are load-bearing lessons for our
  design**: any "poll several times, maybe yield early" loop over a connection must re-verify
  "write buffer is empty" immediately before deciding it's safe to idle or shut down — a stale
  readiness bit from an earlier poll in the same wakeup is not sufficient.
- **No graceful lingering-close / half-close read-drain by default.** `h1_half_close` defaults to
  `false` (`src_server_conn_http1.rs:245, 257-268`): if the client shuts down its write side (FIN)
  mid-request, hyper's default behavior is to treat that as connection-ending
  (`mid_message_detect_eof`, `conn.rs:487-504`, called from `poll_read_keep_alive` when not
  `allow_half_close`, `conn.rs:431-441`) — `disconnect_after_reading_request_before_responding`
  (`tests_server.rs:1436-1461`) shows that even *after* the full request was read, a client FIN
  before the response is ready causes `serve_connection` to resolve with an error and the
  in-flight handler future to be dropped (proven by the handler `panic!`ing if ever awoken again).
  With `half_close(true)` set (`http1_allow_half_close` test, `tests_server.rs:1401-1433`),
  `mid_message_detect_eof`'s first check (`conn.rs:491-493`) short-circuits to `Pending` instead
  of forcing an EOF-close — the server keeps trying to produce and send the response on a
  half-closed (write-only-from-server) socket. There's no separate "SO_LINGER" or drain-then-close
  concept beyond ordinary TCP `shutdown()` semantics (this is delegated entirely to the underlying
  `AsyncWrite`/`Write::poll_shutdown` implementation — hyper itself has no linger timer).
- **Idle EOF vs. busy EOF is the load-bearing distinction, not any explicit "close" verb.**
  `should_error_on_eof` (`conn.rs:201-204`) = `T::should_error_on_parse_eof() && !is_idle()`. For a
  server, `should_error_on_parse_eof()` defaults to `Self::is_client()` = `false`
  (`mod.rs:48-50`), so **a server essentially never treats a between-messages EOF as an error** —
  clean close is the normal, expected way a keep-alive connection ends (`server_accepts_eof_while_busy`
  test, `conn.rs:1372-1378`, even accepts EOF while "busy" e.g. before the *first* head is fully
  read — i.e. `should_read_first()` servers don't error on EOF if nothing has been written yet
  either — contrast `client_rejects_eof_while_busy`, `conn.rs:1358-1369`, where the client *does*
  error, since it's actively waiting on a specific response). This asymmetry (server lenient,
  client strict, about the exact same "EOF while a message might be in flight" situation) is a
  direct consequence of `Http1Transaction::should_error_on_parse_eof`'s default
  (`Self::is_client()`, `mod.rs:48-50`) and worth replicating: a server's read loop should treat an
  EOF that arrives with no partially-read request in the buffer as ordinary connection teardown,
  not a `500`-class internal error.
- **Second `close()` is idempotent by construction, not by any duplicate-guard** — `State::close()`
  /`close_read()`/`close_write()` (`conn.rs:1070-1087`) just set enum states to `Closed`/`KA::Disabled`;
  calling them twice is harmless because they're plain assignments, not "the first call frees a
  resource, the second one double-frees it" (unlike libuv's documented "second `uv-close!` on a
  closing handle silently discards its on-close callback" hazard called out in the project brief) —
  **hyper's `Conn` doesn't itself own a raw OS handle it must close-once; the underlying
  `Read+Write` object's actual lifecycle (and any double-close hazard) is entirely the caller's
  responsibility**, since hyper only calls `poll_shutdown` on it and then drops the `Conn`. This is
  an important asymmetry from our chez-libuv situation: hyper's state machine has no equivalent of
  "must not initiate a second close on this handle" because it was never designed against a raw
  callback-based async I/O primitive with that hazard — **we will need an explicit close-once
  guard at the boundary between our connection state machine and chez-libuv's `uv-close!`,
  something hyper's design doesn't have to think about and therefore offers no ready-made pattern
  for.**

## 13. Application handler API shape

- The `Dispatch` trait (`dispatch.rs:30-43`) is the internal seam between H1 framing and the
  public API; the server-facing implementor is `dispatch::Server<S, B>`
  (`dispatch.rs:45-52, 566-646`), generic over `S: HttpService<B>` (from `crate::service`, not
  fetched in this pass, but its shape is evident from usage: `S::call(Request<IncomingBody>) ->
  S::Future` where `S::Future: Future<Output = Result<Response<Bs>, S::Error>>`).
- **One request in flight, driven to completion before the next is dispatched** (§4): `recv_msg`
  (`dispatch.rs:621-632`) reconstructs an `http::Request<IncomingBody>` from the parsed
  `MessageHead` + streaming body and calls `self.service.call(req)`, stashing the returned
  `Future` in `in_flight: Pin<Box<Option<S::Future>>>`. `poll_msg` (`dispatch.rs:597-619`) drives
  that one future to `Ready`, converts the `http::Response<Bs>` back into a `MessageHead` + body,
  and clears `in_flight`. `poll_ready`/`should_poll` (`dispatch.rs:634-645`) gate further reads on
  `in_flight.is_none()`.
- **Both request and response bodies are `http_body::Body` trait objects** streamed as
  `Frame<Bytes>` items (data or trailers) — not `Vec<u8>`/full buffering — via `poll_frame`. The
  request side is always the concrete `hyper::body::Incoming` (§5); the response side is whatever
  body type the `Service` returns (`Bs: Body`), so response-body streaming strategy (in-memory
  `Full`, on-the-fly generator, `StreamBody`, etc.) is entirely the application's choice — hyper's
  H1 layer only requires `Bs::Error: Into<Box<dyn StdError + Send + Sync>>` and drives it via
  `poll_frame`/`size_hint()`/`is_end_stream()`.
- **`size_hint().exact()`** (checked once, right when the handler's response headers are about to
  be written, `dispatch.rs:371-378`) is how hyper decides `BodyLength::Known(n)` vs.
  `BodyLength::Unknown` for framing purposes (§10) — i.e. a `Body` impl that can report an exact
  size up front gets `Content-Length` framing "for free"; one that can't gets chunked (or
  close-delimited) framing automatically.
- **Upgrade** is carried as an `http::Extensions` value (`OnUpgrade`) on the `Request`
  (§9) — not a distinct method on the handler trait; a handler that wants upgrade support pulls it
  out of `req.extensions()` via `hyper::upgrade::on(&req)`.
- **Cancellation**: if the handler drops the request (and its body `Receiver`) without consuming
  it, the *sender* side simply gets `receiver_open = false` and further `try_send_data` calls fail
  cleanly (`src_body_chan.rs:151-153, 205-212`) — the read pump then stops pulling body bytes off
  the wire and either drains cheaply or closes the read half (`dispatch.rs:239-246`, §5); no
  panics, no special-cased "handler ignored the body" error path.

## 14. What hyper's own test suite covers (files/tests to mirror)

Full h1-relevant test files fetched: `tests/server.rs` (4063 lines, 95 `#[test]`/`#[tokio::test]`
functions catalogued — see `tests_server.rs.testnames.txt` in the scratchpad for the complete
list), `tests/client.rs` (3476 lines, 26 tests, names only), `tests/h1_flush_before_yield.rs` (118
lines, single targeted regression test, read in full), `tests/h1_shutdown_while_buffered.rs` (205
lines, single targeted regression test, read partially), `tests/h1_server/mod.rs` (97 lines, a
reusable test-fixture `Read`/`Write` shim over an `mpsc` channel — a pattern worth copying for our
own connection-semantics unit tests: a controllable, chunk-at-a-time fake socket rather than a real
TCP loopback for every test).

Groupings worth mirroring one-for-one in chez-http-server's own test suite (test names are hyper's,
verbatim, from `tests/server.rs` unless noted):

- **Body-length framing matrix**: `fixed_response_known`, `fixed_response_unknown`,
  `fixed_response_known_empty`, `chunked_response_known`, `chunked_response_known_empty`,
  `chunked_response_unknown`, `te_response_adds_chunked`, `auto_response_with_unknown_length`,
  `auto_response_with_known_length`, `auto_response_known_empty`,
  `http10_auto_response_with_unknown_length`, `http10_chunked_response`,
  `response_does_not_set_chunked_if_body_not_allowed` — this is the exhaustive cross-product of
  {known/unknown/empty length} × {HTTP/1.0, HTTP/1.1} × {explicit TE header, explicit CL header,
  neither} that §10's precedence table needs a test for each cell of.
- **Request body decode edge cases**: `post_with_content_length_body`,
  `post_with_invalid_prefix_content_length` (`Content-Length: +5` → 400), `post_with_chunked_body`,
  `post_with_chunked_overflow` (chunk-size arithmetic overflow → body error containing
  `"overflow"`, verified the connection doesn't then mis-parse the attacker's smuggled
  `GET /sneaky HTTP/1.1` as a second request), `post_with_incomplete_body` (client half-closes
  write mid-body → body error), `post_with_chunked_missing_final_digit` (malformed chunk-size hex
  digit → body error).
- **HEAD-specific**: `head_response_can_send_content_length`, `head_response_doesnt_send_body`,
  `no_implicit_zero_content_length_for_head_responses`.
- **204/304-specific**: `skips_content_length_for_304_responses`,
  `skips_content_length_and_body_for_304_responses`.
- **Keep-alive/close matrix**: `keep_alive`, `http_10_keep_alive` (server injects
  `Connection: keep-alive` on a 1.0 response), `http_10_close_on_no_ka`, `disable_keep_alive`
  (server-level opt-out), `header_connection_close` (handler sets `Connection: close` itself),
  `disable_keep_alive_mid_request` (graceful shutdown while request head is only partially read —
  exercises a duplex in-memory transport, `setup_duplex_test_server`, worth copying that harness
  pattern too), `disable_keep_alive_post_request` (graceful shutdown timing vs. the connection's
  `Drop`, using a `DebugStream` wrapper that records whether/when the transport was dropped — good
  pattern for asserting we don't leak/double-close a handle).
- **Pipelining**: `pipeline_disabled`, `pipeline_enabled` (see §4 — note the disabled test itself
  documents that it can't strictly assert non-coalescing due to OS-level buffering races; don't
  copy that flakiness, but do copy the *enabled* assertion that two pipelined requests' responses
  can arrive in one read and that a second read then sees clean EOF).
- **Timeouts**: `header_read_timeout_slow_writes`, `header_read_timeout_starts_immediately`,
  `header_read_timeout_slow_writes_multiple_requests`, `header_read_timeout_as_idle_timeout` — all
  four use a hand-rolled TCP client thread with explicit `thread::sleep` between partial writes,
  which is the right shape for testing our own header-read-timeout equivalent against libuv timers.
- **Half-close / disconnect timing**: `http1_allow_half_close`,
  `disconnect_after_reading_request_before_responding` (asserts the handler future is *dropped*,
  via a `panic!()` inside a timer callback that must never fire, if the client vanishes before the
  response is ready — an excellent cancellation-propagation test pattern to copy).
- **EOF semantics**: `empty_parse_eof_does_not_return_error`, `nonempty_parse_eof_returns_error` —
  directly exercises the idle-vs-mid-message EOF asymmetry from §12.
- **Parse/policy error → status mapping**: `parse_errors_send_4xx_response`,
  `illegal_request_length_returns_400_response`, `header_name_too_long` (→431),
  `http_11_uri_too_long` (→414) — copy these almost verbatim as our 400/431/414-equivalent tests.
- **Expect: 100-continue**: `expect_continue_sends_100`,
  `expect_continue_accepts_upper_cased_expectation`, `expect_continue_but_http_10_is_ignored`,
  `expect_continue_but_no_body_is_ignored`, `expect_continue_waits_for_body_poll` (the deferred-100
  proof from §8 — this is the single most important test to replicate, since it encodes a subtle
  and easy-to-get-wrong behavior).
- **Upgrade/CONNECT**: `upgrades`, `upgrades_new`, `upgrades_ignored`, `http_connect`,
  `http_connect_new`, `http1_graceful_shutdown_after_upgrade` (h2-CONNECT tests are h2-only, not
  relevant to us).
- **1xx-as-response rejection**: `returning_1xx_response_is_error`.
- **Buffer-size configuration**: `max_buf_size_panic_too_small`, `max_buf_size_no_panic`,
  `max_buf_size`, `max_buf_size_split_header_boundary` (headers split exactly across a
  buffer-growth boundary — a classic off-by-one class of bug worth a dedicated test in any
  byte-machine-based parser).
- **Trailers**: `http1_trailer_send_fields`, `http1_trailer_send_fields_titlecase`,
  `http1_trailer_fields_not_allowed` (no `TE: trailers` from client → trailers silently dropped),
  `http1_trailer_fields_allowed_with_comma_separated_te`,
  `http1_trailer_fields_allowed_with_multiple_te_headers`, `http1_trailer_recv_fields`,
  `http1_trailer_recv_keep_alive`.
- **Graceful shutdown timing**: `graceful_shutdown_before_first_request_no_block`.
- **Regression tests for the write-buffer/shutdown ordering hazards** (§12):
  `tests/h1_flush_before_yield.rs::h1_server_flushes_end_of_body_buffered_by_write_recheck` and
  `tests/h1_shutdown_while_buffered.rs` — both are small, targeted, deterministic repros
  (custom `AsyncWrite` that pends after N bytes) rather than integration-style TCP tests; this
  "fake transport with deliberately weird polling behavior" style is the right tool for reproducing
  our own analogous races against chez-libuv (e.g. `uv-write!`'s completion callback firing between
  two polls of our own dispatch loop).

## 15. Concrete lessons for chez-http-server

1. **Separate the read-buffer-for-headers cap from the write-buffer cap.** hyper uses one
   `max_buf_size` for both (§1, §7); given chez-libuv already fixes the *read* buffer at 64 KiB
   per connection (project brief) and has no bounded write queue at all (ADR-0018), we should
   pick our own explicit, independently-tunable numbers for (a) max bytes buffered awaiting parse
   of a request head (→ 431-equivalent) and (b) max bytes we'll let a handler get ahead of the
   client on writes before we stop pulling more chunks from it — don't silently conflate them the
   way hyper does.
2. **Model the read/write halves as two small closed state machines (`Reading`/`Writing`) plus a
   tri-state keep-alive flag (`Idle`/`Busy`/`Disabled`), and only transition to "idle, ready for
   next request" when *both* halves simultaneously reach their keep-alive sentinel** (§3,
   `conn.rs:1093-1112`). This is a clean, small pattern (5 + 4 + 3 states) that directly answers
   "when is it safe to read the next request head" without scattered ad-hoc booleans, and maps
   naturally onto our own connection struct.
3. **Copy the close-delimited-forces-close rule verbatim**: any response whose body length is
   determined by "read/write until connection closes" must unconditionally mark the connection
   non-reusable the moment that body finishes (§3) — this needs to be a property of the *encoder*
   (so every place that finalizes a write checks it), not a one-off check in the keep-alive
   decision function, or it's easy to miss a call site.
4. **Defer the automatic 100-continue write until the handler has expressed interest in the
   request body, not merely "when the head+Expect header arrives."** hyper's mechanism is a
   single-slot channel with a `want`/`wanter` gate (§5, §8) — we can get the same effect more
   simply in a single-threaded Scheme design by just not writing the `100 Continue` bytes into our
   pending-write queue until our own equivalent of "handler asked to read the body" fires; but the
   *test* to replicate (`expect_continue_waits_for_body_poll`) is the important artifact — verify
   a handler that never touches the body never sees a 100 Continue on the wire even though
   `Expect: 100-continue` was set.
5. **Body backpressure in both directions should be expressed as "stop pumping the transport,"
   not "buffer unboundedly."** Read direction: stop calling our libuv read-resume equivalent (or
   just don't re-arm/keep calling `uv-read-stop!`) while the consumer's one outstanding chunk slot
   is full (hyper's channel is capacity-1, §5) — this composes naturally with chez-libuv's
   `uv-read-stop!`/`uv-read-start!` verbs and the documented congestion signal
   (`uv-stream-write-queue-size`). Write direction: stop asking the handler's body producer for
   more frames once our own outstanding-write-bytes counter (tracked ourselves, since there's no
   bound in the binding per ADR-0018) crosses our chosen watermark, and resume by polling
   `uv-stream-write-queue-size` the way the project brief already says to.
6. **Never call the platform's "close/shutdown" primitive while any bytes are still buffered for
   write** — assert/gate this explicitly, and write hyper's exact two regression tests
   (`h1_flush_before_yield`, `h1_shutdown_while_buffered`) against our own dispatch loop once it
   exists, because both bugs were subtle interleavings of "poll write, poll flush, decide to yield
   or shut down" that are easy to reintroduce when a loop gets an "early exit" fast path added
   later (§12, §14). Given chez-libuv's ADR-0007 ("uv-close! is explicit, asynchronous, never
   GC-driven") and the hazard that a second `uv-close!` silently discards the on-close callback, we
   need a stronger invariant than hyper needs: **a single, unambiguous "who is allowed to initiate
   uv-close! for this handle" owner in our connection state machine**, checked before every close
   call site — hyper doesn't need this because it never owns a raw closeable handle with that
   double-close hazard in the first place (§12, last bullet).
7. **Treat "clean EOF with no partial message in the read buffer" as ordinary connection teardown
   for a server, not an error — but treat EOF with a partially-read request as an error.** This
   asymmetric idle-vs-mid-message EOF handling (§12) is simple to implement (one boolean: "do we
   have a partially-consumed request in flight") and avoids spurious error logs/metrics for the
   overwhelmingly common "client closed a keep-alive connection because it's done" case.
8. **Reject `Transfer-Encoding` + `Content-Length` together outright (400 + close) rather than
   hyper's more lenient "accept, TE wins, force close" (§10, point 3)** — hyper's own comment
   acknowledges the strict RFC 7230 reading is "MUST respond with 400 and close"; given our
   project is a fresh implementation with no backward-compat burden and request smuggling is a
   real concern for any HTTP server fronting other services, we should be strict here rather than
   copying hyper's leniency.
9. **Decide explicitly what we auto-generate on error, and document the gaps.** hyper only
   auto-generates 400/431/414 from its own parser; 408 (timeout) and 500 (handler error) are never
   auto-sent (§11) — connections are simply dropped in those cases, and the *application* is
   entirely responsible for turning its own failures into valid responses. If we want
   chez-http-server to be friendlier here (e.g. auto-send 408 on a header-read timeout, or a
   generic 500 on an uncaught Scheme condition from the handler, matching common server
   expectations rather than hyper's raw-library minimalism), that's a deliberate deviation to make
   and document, not an oversight to inherit silently.
10. **A one-request-in-flight-at-a-time dispatcher (§4) is simpler to implement correctly and is
    what hyper itself does** — pipelining support in hyper is purely about read-ahead + write/flush
    batching, never concurrent handler execution. We should plan chez-http-server's first cut the
    same way (serial request/response cycle per connection, pipelined *reads* allowed to run ahead
    of a still-writing response only insofar as we choose to buffer the next parsed head), and
    treat "run N handlers concurrently on one connection" as a distinctly harder, separate feature
    if we ever want it — not something to bolt onto the basic loop.
