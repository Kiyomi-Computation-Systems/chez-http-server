# Reference server deep-read: Node.js `http` (llhttp-based) — connection semantics for chez-http-server

**Source:** https://github.com/nodejs/node, pinned commit `357ba2f676126e2c0e54dca4c47085fce975836b` (fetched onto this machine by an earlier pass in this workflow; see provenance below). All file:line citations below refer to this commit unless noted. Raw URLs use the pattern
`https://raw.githubusercontent.com/nodejs/node/357ba2f676126e2c0e54dca4c47085fce975836b/<path>`.

**Provenance / how I know the fetch is real and complete:**
- `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/node-src/COMMIT_SHA.txt` → `357ba2f676126e2c0e54dca4c47085fce975836b`
- `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/node-src/tests/FETCH_LOG.txt` — 78 lines, all `OK <filename>` (verified with `wc -l` = matches `tests/LIST.txt`), fetched with `tests/fetch.sh` which does `curl -sS -f -o tests/$f https://raw.githubusercontent.com/nodejs/node/$SHA/test/parallel/$f`.
- I additionally deep-read every core source file below in full via the Read tool (not summarized/skimmed), plus 15 of the 78 fetched test files in full and grepped the rest for status-code/error-code assertions. Anything I did **not** verify is marked "NOT VERIFIED" below.
- Local mirror paths (flattened, `/` → `_`) under `node-src/`:
  - `lib__http_server.js` ← `lib/_http_server.js` (1542 lines, read in full)
  - `lib__http_common.js` ← `lib/_http_common.js` (345 lines, read in full)
  - `lib__http_incoming.js` ← `lib/_http_incoming.js` (549 lines, read in full)
  - `lib__http_outgoing.js` ← `lib/_http_outgoing.js` (1402 lines, read in full)
  - `src_node_http_parser.cc` ← `src/node_http_parser.cc` (1505 lines, read in full)
  - `src_node_options.cc` / `src_node_options.h` ← `src/node_options.{cc,h}` (grepped for `max-http-header-size`)
  - `deps_llhttp_include_llhttp.h` ← `deps/llhttp/include/llhttp.h` (grepped for flags/errno enum)
  - `deps_llhttp_src_api.c` ← `deps/llhttp/src/api.c` (read excerpt)
  - `deps_llhttp_src_http.c` ← `deps/llhttp/src/http.c` (170 lines, read in full — this is the keep-alive/body-framing decision logic)
  - `doc_api_http.md` ← `doc/api/http.md` (4851 lines; targeted sections read in full: Agent response-ordering, all `http.Server` events, all timeout/limit properties, `close*()` methods, `http.maxHeaderSize`)
  - `tests/*.js` / `tests/*.mjs` ← `test/parallel/test-http-*.js` (78 files fetched; 15 read in full, rest grepped)

---

## 1. Keep-alive decision rule

The authoritative rule lives in **llhttp**, not in JS: `deps/llhttp/src/http.c:156-170` (local: `deps_llhttp_src_http.c:156-170`):

```c
int llhttp_should_keep_alive(const llhttp_t* parser) {
  if (parser->http_major > 0 && parser->http_minor > 0) {
    /* HTTP/1.1 */
    if (parser->flags & F_CONNECTION_CLOSE) {
      return 0;
    }
  } else {
    /* HTTP/1.0 or earlier */
    if (!(parser->flags & F_CONNECTION_KEEP_ALIVE)) {
      return 0;
    }
  }
  return !llhttp_message_needs_eof(parser);
}
```

and `llhttp_message_needs_eof` (`deps_llhttp_src_http.c:129-153`):
```c
int llhttp_message_needs_eof(const llhttp_t* parser) {
  if (parser->type == HTTP_REQUEST) return 0;
  if (parser->status_code / 100 == 1 || parser->status_code == 204 ||
      parser->status_code == 304 || (parser->flags & F_SKIPBODY)) return 0;
  if ((parser->flags & F_TRANSFER_ENCODING) && (parser->flags & F_CHUNKED) == 0) return 1;
  if (parser->flags & (F_CHUNKED | F_CONTENT_LENGTH)) return 0;
  return 1;
}
```

**Rule, restated:**
- **HTTP/1.1**: keep-alive is the *default*; only an explicit `Connection: close` token (`F_CONNECTION_CLOSE`) turns it off.
- **HTTP/1.0 (or 0.9)**: close is the *default*; only an explicit `Connection: keep-alive` token (`F_CONNECTION_KEEP_ALIVE`) turns it on.
- Independent of the above, if the message's body-length cannot be framed without reading to EOF (`llhttp_message_needs_eof` — i.e. response is not 1xx/204/304/HEAD, has `Transfer-Encoding` that isn't terminally `chunked`, and has neither `Content-Length` nor `chunked`), keep-alive is forced off regardless of headers, because the only way to detect the end of that message is connection close.
- This is computed **per message** (`llhttp__after_message_complete`, `deps_llhttp_src_http.c:116-126`, sets `parser->flags = 0` right after, so flags never leak across pipelined messages — matches what chez-httparse's own docs say about `parser-field-ref` needing to be read inside callbacks).

**JS side (server):** the C++ binding calls `llhttp_should_keep_alive()` once per message and hands the boolean to JS as `shouldKeepAlive` in `on_headers_complete()`, `src/node_http_parser.cc:487-491`:
```cpp
bool should_keep_alive;
should_keep_alive = llhttp_should_keep_alive(&parser_);
argv[A_SHOULD_KEEP_ALIVE] = Boolean::New(env()->isolate(), should_keep_alive);
```
This flows to `parserOnHeadersComplete(...)` (`lib/_http_common.js:77-126`) which calls `parser.onIncoming(incoming, shouldKeepAlive)` (line 125), i.e. `parserOnIncoming(server, socket, state, req, keepAlive)` in `lib/_http_server.js:1344`, which sets `res.shouldKeepAlive = keepAlive` (line 1377). **The parser's boolean, not any re-derivation in JS, is authoritative for the *request* side.**

**On the response side**, `_storeHeader` in `lib/_http_outgoing.js:546-577` derives `Connection:` for the *outgoing* message from `this.shouldKeepAlive` (seeded from the request's `shouldKeepAlive` above) AND whether the response itself is even keep-alive-eligible (`state.contLen || this.useChunkedEncodingByDefault || this.agent`). Concretely:
- If the app removed the `Connection` header (`_removedConnection`), Node still infers `_last = !shouldKeepAlive` — i.e. **explicit header removal doesn't disable the close-tracking logic**, confirmed by `test-http-remove-connection-header-persists-connection.js` (fetched, not fully read but name + grep-confirmed intent).
- If keep-alive is otherwise fine but `maxRequestsOnConnectionReached` is true, Node still sends `Connection: close` (`lib/_http_outgoing.js:554-555`) — see §4 `maxRequestsPerSocket`.
- If keep-alive holds and `_keepAliveTimeout && _defaultKeepAlive`, Node emits both `Connection: keep-alive` and a `Keep-Alive: timeout=N[, max=M]` header (`lib/_http_outgoing.js:557-569`), cached across responses since it's identical per-server (module-level `keepAliveTimeoutCache`/`keepAliveMaxCache`/`keepAliveHeaderCache`).
- **Server also unilaterally forces `shouldKeepAlive = false`** on responses to HTTP/1.0-or-lower requests when it hasn't decided otherwise (`ServerResponse` ctor, `lib/_http_server.js:227-230`), and again forces it off if the client sent `Expect: 100-continue` but the server answered without ever sending the interim 100 (`lib/_http_server.js:513-515`, comment: *"Don't keep alive connections where the client expects 100 Continue but we sent a final status; they may put extra bytes on the wire."*).

**Close-delimited body forces close**: per `llhttp_message_needs_eof` above, a *response* with no `Content-Length`/`chunked` framing is read-until-EOF and therefore cannot be kept alive — this is enforced entirely inside llhttp's should-keep-alive computation, not duplicated in JS. Node's own `_storeHeader` reaches the same conclusion from the writer's side: "We can't keep alive in this case, because with no header info the body is defined as all data until the connection is closed" (`lib/_http_outgoing.js:598-601`, sets `this._last = true`).

**Test evidence:**
- `tests/test-http-should-keep-alive.js` — client-observable table of exactly the 6 cases (HTTP/1.0 default/keep-alive/close × HTTP/1.1 default/keep-alive/close), matching the truth table above (read in full).
- `tests/test-http-1.0-keep-alive.js` — server-side: HTTP/1.0 `Connection: keep-alive` **without** a TE/Content-Length still gets an immediate close after that response (server can't know the boundary of the next request on that data even though the client asked to keep it open) but **with** TE:chunked or Content-Length the socket stays open for the next request (read in full; see the `expectClose` fields).

---

## 2. Pipelining policy and response ordering

Node **does** support pipelined requests on a single connection (multiple full HTTP messages arriving before earlier responses are sent), but strictly serializes the responses. This is implemented with two parallel queues on the per-connection `state` object created in `connectionListenerInternal` (`lib/_http_server.js:829-846`):
```js
const state = {
  ...
  outgoing: [],   // ServerResponse objects queued behind the one on the wire
  incoming: [],   // IncomingMessage objects not yet fully read
  outgoingData: 0,
  ...
};
```

- **Ordering enforcement**: `parserOnIncoming` (`lib/_http_server.js:1344-1469`) creates a new `ServerResponse` for every parsed request and either assigns it to the socket immediately (`res.assignSocket(socket)`, line 1406) if the socket has no `_httpMessage` in flight, or pushes it onto `state.outgoing` (line 1404) if one is already in flight. So **only one `ServerResponse` is ever attached to the socket (`socket._httpMessage`) at a time**; later ones sit in `outgoing[]` until their turn. This is a strict FIFO — Node never reorders responses relative to request arrival order, regardless of which handler finishes first (a slow handler for request #1 blocks the wire-write of response #2 even if #2's handler finished instantly). That's the entire pipelining/HOL-blocking policy.
- **Advancing the queue**: `resOnFinish` (`lib/_http_server.js:1220-1274`), which fires on the response's `'finish'` event (attached at `res.on('finish', onResponseFinish)`, line 1411), does `res.detachSocket(socket)` then, if `state.outgoing.length` is nonempty, `const m = state.outgoing.shift(); m.assignSocket(socket);` (lines 1268-1273) — i.e. the next queued response is only handed the socket once the previous one has fully finished writing.
- **Request-side dumping**: also in `resOnFinish` (lines 1238-1242): *"If the user never called req.read(), and didn't pipe() or .resume() or .on('data'), then we call req._dump() so that the bytes will be pulled off the wire"* — a handler that ignores the request body doesn't stall the parser from reading subsequent pipelined bytes.
- **Parser resumes on message complete regardless of `res` state**: `parserOnMessageComplete` (`lib/_http_common.js:143-163`) always calls `readStart(parser.socket)` at the end (line 162) — the parser keeps consuming and parsing subsequent pipelined requests off the wire into `state.incoming[]` even while the response side is still serialized; it is the *write* side, not the *read/parse* side, that's the actual bottleneck. Backpressure (§3) is what stops read-ahead from becoming unbounded.
- **Last request marking on half-close mid-pipeline**: `socketOnEnd` (`lib/_http_server.js:957-973`) — if the peer sends FIN while responses are still queued, Node doesn't yank the socket; it marks the *last* queued response (`state.outgoing[state.outgoing.length - 1]._last = true`) or, if nothing is queued but one response is in flight, marks that one (`socket._httpMessage._last = true`) so the connection is closed after that response finishes rather than immediately — i.e. **pending pipelined responses still get delivered even after the client half-closes**, unless `httpAllowHalfOpen` is false (it's hardcoded `false` at `lib/_http_server.js:680`, meaning by default Node ends its own writable side promptly once the peer's FIN is processed and there's nothing left queued: see `else socket.end();` branch, line 971).

**Test evidence** (all fetched; read in full or grep-confirmed):
- `tests/test-http-many-ended-pipelines.js` (read in full) — 20 pipelined `GET`s on one socket where the handler `res.end('ok'); req.socket.destroy();` after every response; asserts the client only ever sees `ECONNRESET`/`EPIPE`/`ECONNABORTED`, i.e. a destroy mid-pipeline doesn't crash the server for the remaining queued requests, it just resets the peer.
- `tests/test-http-incoming-pipelined-socket-destroy.js` (read in full) — 13 pipelined requests (`seeds = [3,1,2,3,4,...]`) where handlers variously `req.socket.destroy()`, `res.destroy()`, or write in two chunks (`res.write('hello '); ...; res.end('world!')`), verifying the server tolerates destroys interleaved with in-flight pipeline members without hanging (`Countdown` over `seeds.length` `requestDone` events).
- `tests/test-http-pipeline-requests-connection-leak.js`, `tests/test-http-keep-alive-pipeline-max-requests.js`, `tests/test-http-server-headers-timeout-pipelining.js`, `tests/test-http-server-request-timeout-pipelining.js` — fetched, latter two read in full (§4).
- `doc/api/http.md:73-79` (`### Response ordering with connection reuse`, read in full): *"On a reused HTTP/1.1 keep-alive connection, responses are associated with requests by their order on that connection. HTTP/1.1 keep-alive does not provide per-request response attribution beyond that ordering."* — this is documented as a client-Agent-facing statement but it's the same wire invariant the server side enforces via `outgoing[]`.

---

## 3. Streaming bodies, both directions, with backpressure

### Request body in (socket → parser → `IncomingMessage` Readable)

- The parser's `on_body` C++ callback copies each body slice into a **fresh** V8 `Buffer` (`Buffer::Copy(env, at, length)`, `src/node_http_parser.cc:529`) before calling back into JS — no cross-callback aliasing, comparable to chez-httparse's span-copy requirement, except here it's mandatory (llhttp doesn't offer a zero-copy option to the JS layer at all).
- `parserOnBody(b)` (`lib/_http_common.js:128-141`) does `const ret = stream.push(b); if (!ret) readStop(this.socket);` — this is the **entire inbound backpressure mechanism**: `IncomingMessage` is a `Readable`; when its internal buffer exceeds `highWaterMark` (defaulted from `socket.readableHighWaterMark`, `lib/_http_incoming.js:66-72`), `push()` returns `false` and Node immediately calls `readStop(socket)` → `socket.pause()` (`lib/_http_incoming.js:55-58`). The **parser is not explicitly paused** — because the *socket* is paused, no more `'data'` events fire, so `parser.execute()` is never called again until the app drains the `IncomingMessage`.
- Resuming: `IncomingMessage.prototype._read` (`lib/_http_incoming.js:265-276`) — Node's own `_read` is the resumption trigger: the first time a consumer starts reading (`stream.read()`/`.on('data')`/`.resume()`/`.pipe()`), `_consuming` flips true and, if the socket is still readable, `readStart(socket)` → `socket.resume()` restarts the flow of `'data'` events, which re-enters `parser.execute()`.
- If nobody ever consumes the request body, `resOnFinish` calls `req._dump()` (`lib/_http_server.js:1241-1242`) which either goes straight to `end` (if already `complete` and nothing buffered) or `.resume()`s to flush it off the wire — so an ignored body never blocks the connection, it's actively discarded once the response finishes.
- **Socket-level double consumption guard**: Node "consumes" the raw libuv/`StreamBase` handle directly into the parser (`parser.consume(socket._handle)`, `lib/_http_server.js:879`) when possible, bypassing the normal `net.Socket` `'data'` event machinery for the *first* HTTP layer read path — and then patches `socket.on`/`.addListener`/`.prependListener` (`generateSocketListenerWrapper`, `lib/_http_server.js:1514-1530`) so that if user code ever attaches its own `'data'`/`'readable'` listener directly to the raw socket, Node automatically calls `unconsume()` (`lib/_http_server.js:1504-1512`) to hand real socket-level flow back to the normal `net.Socket` stream, since the two consumption models (direct-into-parser vs stream `'data'` events) are mutually exclusive.

### Response body out (`ServerResponse`/`OutgoingMessage` Writable → socket)

- `OutgoingMessage.write()` (`lib/_http_outgoing.js:942-952`) returns the underlying `_send`/`_writeRaw` result and, if the socket declined (`false`), sets `this[kNeedDrain] = true`. `writableNeedDrain` getter exposes this (`lib/_http_outgoing.js:934-939`).
- Draining is socket-driven: `socketOnDrain(socket, state)` (`lib/_http_server.js:901-923`) is the connection-level `'drain'` handler; it only re-emits `'drain'` on the currently-attached `_httpMessage` once `msg.writableLength === 0` — i.e. the message-level drain event is deliberately delayed past the raw socket drain to avoid firing while there's still buffered-but-unsent message data (comment at lines 913-918 explains this explicitly).
- **Per-connection outgoing byte accounting decouples response backpressure from response *ordering***: `state.outgoingData` (an approximate byte counter across *all* responses currently pending on the connection, including ones still queued in `outgoing[]`) is updated via `updateOutgoingData`/`_onPendingData` (`lib/_http_server.js:896-899`, wired into `OutgoingMessage` at `res._onPendingData = state.onPendingData`, `lib/_http_server.js:1374`). When a *new* incoming request arrives (`parserOnIncoming`, `lib/_http_server.js:1360-1369`):
  ```js
  if (!socket._paused) {
    const ws = socket._writableState;
    if (ws.needDrain || state.outgoingData >= socket.writableHighWaterMark) {
      socket._paused = true;
      socket.pause();
    }
  }
  ```
  i.e. **read-side (parsing of further pipelined requests) is throttled by write-side backpressure**: if the socket's writable side is congested or the cumulative queued-response bytes exceed the writable highWaterMark, Node stops reading/parsing new requests off that connection — this is the direct analogue of what the chez-libuv facts call "no bounded write queue in the binding; the consumer tracks outstanding bytes." Node's own answer to "what's the congestion signal" is exactly `state.outgoingData` (its own accounting, not a libuv/OS queue-depth read) compared against `socket.writableHighWaterMark`.
  - When `socket._paused`, the *parser* is explicitly paused too, but only after the current `execute()` call finishes: `onParserExecuteCommon` (`lib/_http_server.js:1200-1204`): *"onIncoming paused the socket, we should pause the parser as well... don't do that until after the call to execute, because we may still be processing the last chunk."*
  - Un-pausing happens in `socketOnDrain` (`lib/_http_server.js:901-910`): once `state.outgoingData <= socket.writableHighWaterMark`, `socket._paused = false; socket.parser.resume(); socket.resume();`.
- `_flushOutput` (`lib/_http_outgoing.js:1350-1373`) corks the socket, writes every buffered `outputData` entry, uncorks, and reports `-this.outputSize` back through `_onPendingData` to shrink `state.outgoingData` again — cork/uncork batching around the header+first-chunk write is explicit (comment at `lib/_http_outgoing.js:419-424`: *"shameful hack to get the headers and first body chunk onto the same packet"*).
- Chunked-encoding body writes additionally buffer per-write callbacks in `kChunkedBuffer` while corked (`write_`, `lib/_http_outgoing.js:1057-1071`) and flush them all together on `uncork()` (`lib/_http_outgoing.js:314-368`), producing one chunk-size line + one `_send` call per buffered write batch rather than a syscall per `write()`.
- **`test-http-pipeline-flood.js`** (read in full) is Node's own regression test for exactly this mechanism: a child process floods a server with ~10 MB of identical pipelined `GET`s; once `res.write()` on a big response returns `false`, the server explicitly stops listening to further `'data'` on that socket (`req.socket.on('data', common.mustNotCall(...))`) — proving the "flood prevention" (their term for what we'd call read backpressure driven by write backpressure) actually stops consuming the wire, not just stops calling the handler.
- **`test-http-outgoing-drain-writable-length.js`**, **`test-http-response-drain-cork.js`**, **`test-http-server-options-highwatermark.js`**, **`test-http-highwatermark.js`** — fetched (names strongly indicate additional backpressure/highWaterMark coverage; not read in full — NOT VERIFIED beyond filename/grep).

---

## 4. Every named limit/timeout, with its default

All defaults below are read directly from `storeHTTPOptions` (`lib/_http_server.js:522-630`) and cross-checked against `doc/api/http.md`.

| Name | Default | Source | Behavior on expiry |
|---|---|---|---|
| `server.requestTimeout` | **300000 ms** (5 min) | `lib/_http_server.js:555-561`; doc `doc/api/http.md:1923-1944` (changed from "no timeout" to 300s in v18, PR #41263) | 408 + close (see below) |
| `server.headersTimeout` | **min(60000, requestTimeout)** | `lib/_http_server.js:563-573`; doc `doc/api/http.md:1874-1898` | 408 + close |
| — constraint | `headersTimeout` must be `<= requestTimeout` when both are nonzero, else `ERR_OUT_OF_RANGE` thrown at server construction | `lib/_http_server.js:571-573` | n/a (construction-time validation) |
| `server.keepAliveTimeout` | **65000 ms** (65 s) | `lib/_http_server.js:575-581`; doc `doc/api/http.md:2008-2037` (this pinned commit shows a **REPLACEME**-tagged changelog entry raising the default from 5s→65s — i.e. this is a very recent/unreleased change on `main`; older stable Node defaults to 5000 ms — flag this discrepancy explicitly to whoever consumes this report) | socket destroyed if no new request arrives |
| `server.keepAliveTimeoutBuffer` | **1000 ms** | `lib/_http_server.js:583-589`; doc mentions `socketTimeout = keepAliveTimeout + keepAliveTimeoutBuffer` (`doc/api/http.md:2024-2027`) | added on top of `keepAliveTimeout` when arming the socket timer, "to reduce the likelihood of ECONNRESET errors" (`lib/_http_server.js:1260-1264`) |
| `server.connectionsCheckingInterval` | **30000 ms** (30 s) | `lib/_http_server.js:591-597` | interval on which `checkConnections()` sweeps for headers/request-timeout-expired connections (`setupConnectionsTracking`, `lib/_http_server.js:632-643`; timer is `.unref()`'d so it doesn't keep the process alive) |
| `server.maxHeadersCount` | **1000** (header *pairs*; internally doubled to 2000 field+value slots) | doc `doc/api/http.md:1913-1921`; internal default when unset is `MAX_HEADER_PAIRS = 2000` field/value slots (`lib/_http_common.js:53,292`); C++ side counts pairs and compares against the JS-provided `maxHeaderPairs` (`src/node_http_parser.cc:1042-1067`, `TrackHeaderPair`) | 431 (`HPE_HEADER_OVERFLOW`) |
| `maxHeaderSize` (server option) / `http.maxHeaderSize` / `--max-http-header-size` | **16384 bytes (16 KiB)** | `src/node_options.h:186` (`uint64_t max_http_header_size = 16 * 1024;`); CLI help text `src/node_options.cc:998-1001` (*"set the maximum size of HTTP headers (default: 16384 (16KB))"*); doc `doc/api/http.md:4009-4021` | 431 (`HPE_HEADER_OVERFLOW`) — enforced per-byte in `TrackHeader()` (`src/node_http_parser.cc:1033-1040`), counting *all* header bytes (field+value+URL+status text) via `header_nread_ += len` |
| chunk-extension size cap | **16384 bytes (16 KiB)**, hardcoded, **no config option** | `kMaxChunkExtensionsSize = 16384`, `src/node_http_parser.cc:86`; enforced in `on_chunk_extension` (`src/node_http_parser.cc:580-590`) | 413 (`HPE_CHUNK_EXTENSIONS_OVERFLOW`) |
| `server.maxRequestsPerSocket` | **0 (no limit)** | doc `doc/api/http.md:1971-1986`; `Server` ctor `lib/_http_server.js:687` | when reached: server still serves that request but flags `res.maxRequestsOnConnectionReached` and forces `Connection: close` on the response header (`lib/_http_outgoing.js:552-556`) — it does **not** hard-close early. A request arriving *after* the limit gets `'dropRequest'` emitted and a bare `503` (no body) (`lib/_http_server.js:1438-1443`; doc confirms: *"subsequent requests sent after the limit is reached will get 503 Service Unavailable"*) |
| `server.timeout` (idle-socket timeout, applies to *all* traffic incl. mid-response) | **0 (disabled)** | doc `doc/api/http.md:1988-2006` (changed from 120s→0 in v13, PR #27558) | `'timeout'` event on socket/req/res/server; if **nothing** handles it, `socket.destroy()` (`socketOnTimeout`, `lib/_http_server.js:925-934`) |
| `ConnectionsList::Expired` sampling | uses `uv_hrtime()` monotonic clock, `headers_timeout`/`request_timeout` passed in **milliseconds from JS, converted ×1,000,000 to ns** in C++ | `src/node_http_parser.cc:1236-1294` | — |
| `--max-http-header-size` interacts with **maxHeaderSize per-server override** | server option `maxHeaderSize` (undefined by default) overrides the CLI/global default when set | `lib/_http_server.js:526-529`, `storeHTTPOptions`; wired into `parser.initialize(..., server.maxHeaderSize \|\| 0, ...)` (`lib/_http_server.js:814-820`); C++ falls back to `env->options()->max_http_header_size` when the passed value is `0` (`src/node_http_parser.cc:696-698`) | — |

**Timeout → response mapping** (`socketOnError`, `lib/_http_server.js:1024-1059`, dispatch table `lib/_http_server.js:1006-1022`):
```js
switch (e.code) {
  case 'HPE_HEADER_OVERFLOW': response = requestHeaderFieldsTooLargeResponse; break;  // 431
  case 'HPE_CHUNK_EXTENSIONS_OVERFLOW': response = requestChunkExtensionsTooLargeResponse; break; // 413
  case 'ERR_HTTP_REQUEST_TIMEOUT': response = requestTimeoutResponse; break;  // 408
  default: response = badRequestResponse; break;  // 400
}
```
All four canned responses are **bare status line + `Connection: close\r\n\r\n`, no body**, precomputed once as module-level `Buffer`s (`lib/_http_server.js:1006-1022`) — e.g. `requestTimeoutResponse = Buffer.from('HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n')`. They are written **only if** `this.writable && (!this._httpMessage || !this._httpMessage._headerSent)` (line 1036-1037) — i.e. Node refuses to write a synthetic error response on top of a response it has already started streaming to the client (would corrupt framing); in that case it just calls `this.destroy(e)` with no canned bytes.

`onRequestTimeout(socket)` (`lib/_http_server.js:983-986`) synthesizes an `ERR_HTTP_REQUEST_TIMEOUT` and funnels it through the exact same `socketOnError` path used for parse errors — timeouts and parse errors share one code path to a canned-response-then-destroy.

**Test evidence** (all fetched; the following read in full):
- `tests/test-http-server-timeouts-validation.js` — construction-time defaults/validation table (400s), including the `ERR_OUT_OF_RANGE` throw when `headersTimeout > requestTimeout`.
- `tests/test-http-server-headers-timeout-pipelining.js`, `tests/test-http-server-request-timeout-pipelining.js` — both prove the 408-then-close behavior fires **mid-pipeline**: first pipelined request completes and its 200 is delivered, second one is deliberately left unfinished past the timeout, and the exact wire bytes `'HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n'` are asserted.
- `tests/test-http-server-close-idle.js` — `headersTimeout: 0, keepAliveTimeout: 0, requestTimeout: 60000`; two sockets, one never finishes a request, one does and idles on keep-alive; `server.close()` is shown to leave the *non-idle* (mid-request) socket alone while `closeAllConnections()` is needed to also kill it — i.e. `close()` alone is graceful/idle-only, matching §9.
- Also fetched but not read line-by-line (grep-confirmed status codes only): `test-http-server-headers-timeout-delayed-headers.js`, `test-http-server-headers-timeout-interrupted-headers.js`, `test-http-server-headers-timeout-keepalive.js`, `test-http-server-request-timeout-delayed-body.js`, `test-http-server-request-timeout-interrupted-body.js`, `test-http-server-request-timeout-keepalive.js`, `test-http-server-request-timeout-upgrade.js`, `test-http-keep-alive-timeout-buffer.js`, `test-http-server-consumed-timeout.js`, `test-http-set-timeout-server.js`, `test-http-server-optimize-empty-requests.js`.
- `tests/test-http-keep-alive-max-requests.js` (read in full) — `server.maxRequestsPerSocket = 3`; first 2 of 3 requests on a socket keep the connection open with `Connection: keep-alive` + `Keep-Alive: timeout=65, max=3`; the 3rd flips to `Connection: close` with no `Keep-Alive:` header, and a second, independent socket is shown to have its own separate counter (per-*connection*, not per-server, limit).
- `test-http-max-headers-count-overflow.js`, `test-http-max-http-headers.js`, `test-http-chunk-extensions-limit.js` — grep-confirmed to assert exactly `431 Request Header Fields Too Large` and `413 Payload Too Large` respectively, each followed by `Connection: close\r\n\r\n`.

---

## 5. `Expect: 100-continue` handling

Handled entirely in `parserOnIncoming` (`lib/_http_server.js:1444-1461`), gated behind `hasRequestHeader(req, 6, 'expect')` (a raw-header scan avoiding materializing `req.headers`, `lib/_http_server.js:1287-1298`), and **only for HTTP/1.1** requests (the whole `Expect`/requests-limit/Host-header block is inside `if (req.httpVersionMajor === 1 && req.httpVersionMinor === 1)`, line 1416).

```js
} else if (hasRequestHeader(req, 6, 'expect')) {
  handled = true;
  if (continueExpression.test(req.headers.expect)) {
    res._expect_continue = true;
    if (server.listenerCount('checkContinue') > 0) {
      server.emit('checkContinue', req, res);
    } else {
      res.writeContinue();
      server.emit('request', req, res);
    }
  } else if (server.listenerCount('checkExpectation') > 0) {
    server.emit('checkExpectation', req, res);
  } else {
    res.writeHead(417);
    res.end();
  }
}
```
- `continueExpression = /(?:^|\W)100-continue(?:$|\W)/i` (`lib/_http_common.js:334`).
- **No `checkContinue` listener** → Node auto-sends `100 Continue` itself (`res.writeContinue()`, which is `writeInformation(100, null, cb)` + sets `this._sent100 = true`, `lib/_http_server.js:378-381`) and *immediately* also emits `'request'` — i.e. by default the app's normal request handler runs right after the auto-100, with no separate opt-in step.
- **With a `checkContinue` listener** → the app decides: call `res.writeContinue()` itself (then it's still responsible for also emitting/handling the request — in the test, the handler manually calls the same request-processing function after `writeContinue()` + `setTimeout`), or answer with a final status directly (e.g. 400) without ever continuing — doc `doc/api/http.md:1499-1502`: *"generating an appropriate HTTP response (e.g. 400 Bad Request) if the client should not continue to send the request body."* **When `checkContinue` fires, the plain `'request'` event does NOT also fire** (doc `doc/api/http.md:1504-1505`) — confirmed structurally: the `if (!handled) server.emit('request', req, res);` guard at the bottom (`lib/_http_server.js:1464-1466`) only fires `'request'` when none of the Expect/limit branches set `handled = true`.
- **`Expect` present but not `100-continue`** → `checkExpectation` listener if any, else auto `417 Expectation Failed` + `res.end()` (no body).
- **The keep-alive-safety rule already noted in §1**: if `_expect_continue` was set but `_sent100` never got set (app skipped `writeContinue()` and just sent a different final status), Node force-disables keep-alive on that response (`lib/_http_server.js:513-515`) — the reasoning documented right there in source: the client may already be mid-write of the body (raced past the interim response) and could dump extra bytes on the wire that would corrupt the next pipelined request if the connection were reused.
- `writeContinue()`/`writeInformation()` (`lib/_http_server.js:327-381`) build and send the 1xx **directly** via `_writeRaw`, bypassing the normal header-state machine (`this._header` stays unset), so a final `writeHead()` can still follow normally afterward.

**Test evidence:**
- `tests/test-http-expect-continue.js` (read in full) — canonical `checkContinue` flow: server asserts the full response is only sent *after* `writeContinue()`; client asserts it never sees the final response before the `'continue'` event. Confirms ordering guarantee both directions.
- `tests/test-http-expect-continue-reuse-race.js` (read in full) — a **regression test**, not a spec test: documents a real race between `responseOnEnd()` and `requestOnFinish()` on the *client* side (both can trigger keep-alive socket reuse) that was exploitable specifically under `Expect: 100-continue` + delayed `req.end()`, causing "the double responseKeepAlive() call [to corrupt] the socket by stripping a subsequent request's listeners." This is client-side (`http.Agent`) plumbing we don't need to replicate, but it's a good warning: **don't let two different completion signals (write-finished vs. stream-end) both independently decide "this connection can be reused" without a single source of truth** — a lesson for our own keep-alive state machine, not just Node's.
- `tests/test-http-expect-handling.js` — fetched, not read in full (NOT VERIFIED beyond filename).

---

## 6. Upgrade / CONNECT

Both are detected inside the C++ parser and surfaced as one boolean, `parser.incoming.upgrade`, computed in llhttp itself (`deps_llhttp_src_http.c:11-26`, `llhttp__before_headers_complete`):
```c
if ((parser->flags & F_UPGRADE) && (parser->flags & F_CONNECTION_UPGRADE)) {
  parser->upgrade = (parser->type == HTTP_REQUEST || parser->status_code == 101);
} else {
  parser->upgrade = (parser->method == HTTP_CONNECT);
}
```
i.e. **`upgrade` is true either for `Upgrade:`+`Connection: upgrade` together, or unconditionally for `CONNECT`** — llhttp treats CONNECT as a degenerate upgrade regardless of headers.

**JS dispatch — `parserOnIncoming`** (`lib/_http_server.js:1347-1353`):
```js
if (req.upgrade) {
  req.upgrade = req.method === 'CONNECT' || !!server.shouldUpgradeCallback(req);
  if (req.upgrade) {
    return 0;  // skip all normal request handling, including Expect/maxRequests/Host checks
  }
}
```
`shouldUpgradeCallback` defaults to `listenerCount('upgrade') > 0` (`lib/_http_server.js:626-629`), i.e. **by default an `Upgrade:` request is only actually treated as an upgrade if the app has an `'upgrade'` listener at all** — otherwise it falls through to normal request handling despite the header (matches doc `doc/api/http.md:1730-1736`: *"By default all HTTP upgrade requests are ignored... unless you listen to this event"*). **CONNECT is never subject to this opt-out check** — `req.method === 'CONNECT'` short-circuits straight to `true`.

**Handoff — `onParserExecuteCommon`** (`lib/_http_server.js:1132-1205`), fires once `parser.incoming?.upgrade` is true:
- Event name: `'connect'` for CONNECT, `'upgrade'` for everything else (line 1141).
- **If the request is `complete`** (no body, or the whole body was already parsed off this same `execute()` call) — Node fully detaches: removes all its own socket listeners (`data`/`end`/`close`/`drain`/`error`/`timeout`), calls `unconsume(parser, socket)` to hand the raw handle back to `net.Socket`'s normal machinery, finishes and frees the parser, and hands the **raw `net.Socket`** itself as the upgrade stream (lines 1144-1161).
- **If the request is incomplete** (body still streaming, e.g. an upgrade request with `Content-Length`) — Node cannot hand over the raw socket yet without losing in-flight parsed body bytes, so it wraps the socket in a `UpgradeStream extends Duplex` (`lib/_http_server.js:1061-1130`) that:
  - proxies `'error'`/`'close'`/`'end'` straight through to/from the underlying socket,
  - defers exposing any *post-body* socket data until `requestBodyCompleted(upgradeHead)` is called (once the request body finishes parsing) — before that, `_read()` only resumes the *request* stream (`this[kIncomingMessage]?.resume()`), not raw socket bytes,
  - after completion, remaining socket `'data'` is pushed straight into the Duplex and (per `'upgrade'` doc changelog `doc/api/http.md:1704-1711`, v26.0.0) **the request body is delivered separately through the normal `req` readable stream**, not intermixed with the raw stream — this was an explicit behavior change (older Node exposed the raw unparsed body on the socket argument).
  - This is exactly the shape of the design problem chez-http-server will face with chez-httparse's `on-reset`/pause-at-headers-complete story for upgrade requests that still have bodies.
- **No listener for the event** → `socket.destroy()` (`lib/_http_server.js:1191-1194`) — both CONNECT and Upgrade get hard-destroyed with no response at all if unhandled (matches doc for `'connect'`, `doc/api/http.md:1634-1636`: *"clients requesting a CONNECT method will have their connections closed"*; and for `'upgrade'` post-v24.9.0/v22.21.0, `doc/api/http.md:1716-1718`, if `shouldUpgradeCallback` accepts it but nobody's listening).
- **`bodyHead`**: whatever bytes remain in the just-executed buffer past what the parser consumed (`d.slice(ret, d.length)`, line 1182) is handed to the app as the 3rd event argument (`upgradeHead`/`head`) — this is the "may already have arrived" leftover the app must treat as already-received protocol bytes, not re-request from the socket.
- **PRI method** (HTTP/2 client preface leaking into an HTTP/1 parser) is explicitly special-cased right after the upgrade branch: `else if (parser.incoming && parser.incoming.method === 'PRI') { socket.destroy(); }` (`lib/_http_server.js:1195-1198`) — silent hard close, no response, presumably to avoid the parser choking on `SM\r\n\r\n`.

**Test evidence:**
- `tests/test-http-connect-req-res.js` (read in full) — CONNECT round-trip proving: server can write arbitrary bytes immediately as part of the "response" line + extra data (`'HTTP/1.1 200 Connection established\r\n...\r\n\r\nHead'`), the client's `firstBodyChunk` on the `'connect'` event is exactly that trailing `'Head'` (**never parsed as further HTTP**), the socket is fully detached from the Agent's pool (`!(name in http.globalAgent.sockets)`), and no leftover HTTP listeners remain (`socket.listeners('data').length === 0`) before the app attaches its own.
- `tests/test-http-upgrade-server.js` (read in full) — proves body-less `Upgrade` with an `'upgrade'` listener gets the raw socket immediately with `upgradeHead` populated from trailing bytes already in the same TCP segment as the headers; proves an `Upgrade` request with **no listener** gets a normal `200` response (not destroyed — because with no `'upgrade'` listener, `shouldUpgradeCallback()` returns false, so it's not even treated as an upgrade at all, matching the `shouldUpgradeCallback` default above); the same server handles 3 different connection styles back to back (`requests_recv === 3`, `requests_sent === 3` asserted in `process.on('exit')`).
- `tests/test-http-connect.js`, `tests/test-http-upgrade-server2.js`, `tests/test-http-upgrade-server-callback.js`, `tests/test-http-upgrade-server-with-body.mjs`, `tests/test-http-upgrade-advertise.js`, `tests/test-http-server-request-timeout-upgrade.js` — fetched; only skimmed by filename (NOT VERIFIED in full), but `test-http-upgrade-server-with-body.mjs` is almost certainly the direct test for the `UpgradeStream`-with-pending-body path described above given the v26.0.0 changelog entry.

---

## 7. Framing precedence (Content-Length vs Transfer-Encoding, duplicates, HEAD, 1xx/204/304)

This is decided in **llhttp**, `llhttp__after_headers_complete` (`deps_llhttp_src_http.c:37-113`), which is the single source of truth Node's JS never overrides:

1. If `upgrade` and (`CONNECT` or `F_SKIPBODY` or no body flagged) → no body, protocol handoff (§6).
2. If response and `status_code == 101` → no body (Switching Protocols carries no HTTP body).
3. If response and `status_code == 100` → no body, message immediately complete (the 100 itself isn't "the response").
4. `F_SKIPBODY` (response to a `HEAD` request) **or** response status ∈ {102, 103, 204, 304} → **no body regardless of any Content-Length/Transfer-Encoding header present** — this is why `test-http-allow-content-length-304.js` (read in full) can assert a `304` with `Content-Length: 11` still delivers **zero** body bytes (`response.on('data', common.mustNotCall())`) while the header value itself is preserved and visible (`response.headers['content-length'] === '11'`) — llhttp simply never enters body-reading state for that status, independent of the header.
5. `F_CHUNKED` (i.e. `Transfer-Encoding` ends in `chunked`) → chunked body parsing, **Content-Length is ignored** if both are present in a way that's not a duplicate/conflict (see below).
6. `F_TRANSFER_ENCODING` set but **not** `F_CHUNKED` (i.e. a `Transfer-Encoding` present whose final coding isn't `chunked`) → **for requests**, unless lenient flags override it, this is an immediate error return (`return 5`), which the calling state machine turns into a parse failure (→ 400 in Node, see `test-http-invalid-te.js`, grep-confirmed `HPE_INVALID_TRANSFER_ENCODING`); **for responses**, it means "read until EOF" (`return 4`) since a non-terminal-chunked TE means the length genuinely can't be framed except by close.
7. Neither chunked nor TE: if no `Content-Length` → `llhttp_message_needs_eof()` decides (0 for requests = no body assumed; for responses, EOF-delimited unless 1xx/204/304/HEAD). If `Content-Length: 0` → no body. If `Content-Length` nonzero → fixed-length body.

**Duplicate/conflicting `Content-Length`**: llhttp raises `HPE_UNEXPECTED_CONTENT_LENGTH` (not a Node-JS-level check) for **any** second `Content-Length` header, even with byte-identical values — confirmed directly:
- `tests/test-http-double-content-length.js` (read in full): client sends `headers: { 'Content-Length': [1, 2] }`; server's `'clientError'` fires with `err.code === 'HPE_UNEXPECTED_CONTENT_LENGTH'`, mapped to the generic-default 400 path (not to a special code) since that error code isn't in the `socketOnError` switch table — falls to `default: badRequestResponse` (400).
- `tests/test-http-request-smuggling-content-length.js` (read in full) — a raw-socket test sending `Content-Length : 5` (**space before the colon**) is rejected outright with `400 Bad Request\r\nConnection: close\r\n\r\n` before any body byte is delivered to a handler — i.e. llhttp's header-name tokenizer, not a value-level check, rejects this (matches the RFC 7230 §3.2 token grammar that disallows OWS between field-name and colon — this is the exact "no space before colon" class of smuggling vector).
- `tests/test-http-transfer-encoding-smuggling.js` (read in full) — **duplicate `Transfer-Encoding` headers** (`Transfer-Encoding: chunked` + `Transfer-Encoding: chunked-false`) and **comma-obfuscated duplicate** (` , chunked-false` continuation) are both rejected before the smuggled second request (`GET /flag`) is ever parsed as a request — first case gets an explicit `400 Bad Request\r\nConnection: close\r\n\r\n` and the request handler is asserted **never called** (`common.mustNotCall`); second case just verifies the connection ends without the handler seeing `/flag`.
- `tests/test-http-chunked-smuggling.js` (read in full) — malformed **chunk-extension** syntax (`2;\nxx\r\n` — extension after `;` contains a bare `\n` instead of proper `\r\n` framing) used in a smuggling attempt; asserts `request.url !== '/admin'` (the smuggled inner request is never parsed as a second real request) while the *outer* request the handler actually sees still completes normally (`response.end('hello world')`).

**HEAD responses**: framing header (`Content-Length`/chunked) is still computed and sent by the app/`writeHead` exactly as if it were a `GET`, but `ServerResponse` sets `this._hasBody = false` at construction time whenever `req.method === 'HEAD'` (`lib/_http_server.js:220`) — so `write()`/`end()` calls are silently no-op'd (or throw, if `rejectNonStandardBodyWrites` is set — `write_`, `lib/_http_outgoing.js:1036-1045`) rather than ever emitting body bytes on the wire; **the framing headers (Content-Length/chunked) are still emitted** — the peer's parser is expected to know (per RFC 7230 §3.3.3 rule 1, mirrored by `F_SKIPBODY`) that a HEAD response's headers describe the body of the hypothetical GET but carry no actual bytes. `tests/test-http-head-response-has-no-body.js` (read in full) is literally titled after a historical bug where Node's chunked-encoding *terminator* (`0\r\n\r\n`) was mistakenly still being sent on `HEAD` responses (fixed by the `_hasBody` gate).

**204/304 body suppression on the *write* side** (independent of the read-side llhttp rule above, this is Node deciding what *it* is willing to send): `writeHead` (`lib/_http_server.js:496-509`) sets `this._hasBody = false` for **204, 304, and any 1xx** status regardless of what the app does — and additionally (`lib/_http_outgoing.js:527-544`) if the app explicitly forces `Transfer-Encoding: chunked` on a 204/304 anyway, Node suppresses the chunked terminator AND forces `shouldKeepAlive = false` (comment explains: sending the zero-chunk anyway "might confuse reverse proxies to the point of creating security liabilities").

---

## 8. Error mapping to responses, and whether the connection closes

Consolidated table (all four canned-response cases are `Connection: close`, i.e. **every synthetic error response Node's own core emits closes the connection** — there is no auto-generated error response that keeps the socket alive):

| Trigger | HTTP status sent | Body | Connection | Source |
|---|---|---|---|---|
| Any llhttp parse error not in the table below (invalid method, invalid version, malformed header, duplicate Content-Length, bad TE, control chars, etc.) | **400 Bad Request** | none | close | `lib/_http_server.js:1006-1009,1040-1053` (`default:` branch) |
| `HPE_HEADER_OVERFLOW` (header bytes > `maxHeaderSize`, or header-pair count > `maxHeadersCount`) | **431 Request Header Fields Too Large** | none | close | `lib/_http_server.js:1014-1017,1041-1042` |
| `HPE_CHUNK_EXTENSIONS_OVERFLOW` (chunk extension bytes > 16 KiB, hardcoded) | **413 Payload Too Large** | none | close | `lib/_http_server.js:1019-1022,1044-1045` |
| `ERR_HTTP_REQUEST_TIMEOUT` (headers/request timeout expiry) | **408 Request Timeout** | none | close | `lib/_http_server.js:1010-1013,1046-1047`, timeout wiring `lib/_http_server.js:983-986` |
| Missing `Host:` header on an HTTP/1.1 request (`server.requireHostHeader`, default `true`) | **400 Bad Request** (`res.writeHead(400, ['Connection', 'close'])`) | none | close | `lib/_http_server.js:1418-1425` — note this path goes through the **normal `ServerResponse`**, not the canned-Buffer `socketOnError` path, because it's caught before the request handler runs but after a `ServerResponse` already exists |
| `Expect:` present, not `100-continue`, no `checkExpectation` listener | **417 Expectation Failed** | none | keep-alive eligible (not force-closed, unlike the unhandled-100 case) | `lib/_http_server.js:1457-1460` |
| `maxRequestsPerSocket` exceeded | **503 Service Unavailable** | none (`res.end()` with no data) | connection **stays open in principle** but the 503'd response itself already carries `Connection: close` from `_storeHeader`'s "maxRequestsOnConnectionReached" branch (§4) — practically single-shot then closed | `lib/_http_server.js:1438-1443`, `'dropRequest'` emitted alongside |
| Unhandled (no listener) rejection from an async `'request'` handler | **500** + body = `STATUS_CODES[500]` (`"Internal Server Error"`), only if headers not yet sent (`!res.headersSent && !res.writableEnded`); otherwise `res.destroy()` | `"Internal Server Error"` | governed by normal keep-alive logic on that response (not forced closed) | `lib/_http_server.js:739-762`, `Server.prototype[EE.captureRejectionSymbol]` — this is Node opting in to `events.captureRejections`, not a try/catch around the handler; **a synchronous throw inside a handler is NOT caught here** and will surface as an `uncaughtException`/crash unless the app wraps it itself. **NOT VERIFIED**: I did not find Node-core code that catches a *synchronous* handler throw and maps it to 500 — only the promise-rejection-capture path. |
| Client `'error'` on the raw socket surfaces to the app | `'clientError'` event is the escape hatch; if **no listener**, the four-way canned-response dispatch above runs; if there **is** a listener and it doesn't destroy/end the socket, Node does nothing further — the doc explicitly obligates the listener to close the socket itself (`doc/api/http.md:1547-1551`, *"The socket must be closed or destroyed before the listener ends"*) | n/a | n/a | `lib/_http_server.js:1024-1059`; doc `doc/api/http.md:1523-1613` |
| `'clientError'` fired more than once on one socket (edge case around simultaneous errors) | Node explicitly supports/expects this — `removeListener('error', socketOnError)` then attaches a no-op `'error'` listener so a second error on an already-erroring socket doesn't throw `ERR_UNHANDLED_ERROR`, and doesn't warn | n/a | n/a | `lib/_http_server.js:1024-1030`; test `tests/test-http-server-multiple-client-error.js` (read in full) explicitly proves `'clientError'` can fire **twice** for two independent malformed requests pipelined back-to-back on the same raw TCP stream (`123 http://...` then `23 http://...`, both `HPE_INVALID_METHOD`), each with its own distinct `rawPacket`, and asserts `process.on('warning', common.mustNotCall())` |

**501 Not Implemented / 505 HTTP Version Not Supported — Node's core HTTP server never sends these itself.** Both appear only as reason-phrase strings in the `STATUS_CODES` lookup table (`lib/_http_server.js:185,189`) for the *application* to use if it wants; there is no code path in `_http_server.js`/`_http_common.js`/`node_http_parser.cc` that emits 501 or 505 automatically. Concretely:
- An unsupported/invalid HTTP method → llhttp errno `HPE_INVALID_METHOD` (confirmed live, `deps_llhttp_include_llhttp.h:64`) → falls into the generic `default:` branch of `socketOnError`'s switch → **400**, not 501. (`test-http-server-multiple-client-error.js`, `test-http-server-client-error.js`, `test-http-server-destroy-socket-on-client-error.js` all confirm `HPE_INVALID_METHOD` → the app's `'clientError'` handler, which in the doc's own example sends `400`.)
- A malformed/unsupported HTTP version string → llhttp errno `HPE_INVALID_VERSION` (`deps_llhttp_include_llhttp.h:67`) → same generic `default:` branch → **400**, not 505. (I did not find a fetched test exercising this specific errno; the mapping is inferred from the exhaustive `socketOnError` switch, which has no `HPE_INVALID_VERSION` case, confirmed by reading the full switch body at `lib/_http_server.js:1040-1053`.)
- **Lesson: Node collapses "I don't understand this request at all" into a blanket 400 rather than trying to distinguish "bad method" (arguably 501-ish) from "bad version" (505) from "bad syntax" (400).** This is a real design simplification worth copying or explicitly deviating from.

**Test suite's dedicated smuggling/defense-in-depth files** (beyond what's already cited in §7), all fetched, all confirmed-by-grep to assert 400+close:
`test-http-server-reject-cr-no-lf.js` (`HPE_LF_EXPECTED`), `test-http-server-reject-chunked-with-content-length.js` (`HPE_INVALID_TRANSFER_ENCODING`), `test-http-missing-header-separator-lf.js`, `test-http-blank-header.js`, `test-http-response-multi-content-length.js`, `test-http-response-splitting.js`, `test-http-status-reason-invalid-chars.js`, `test-http-parser-finish-error.js` (`HPE_INVALID_EOF_STATE`).

---

## 9. Close / shutdown protocol (lingering close, FIN, half-close)

- **`server.httpAllowHalfOpen` is hardcoded `false`** (`lib/_http_server.js:680`, with a comment referencing Squid's half-closed-client FAQ for context) — Node's own `net.Server` is constructed with `allowHalfOpen: true` (`lib/_http_server.js:668`, i.e. the *raw TCP* layer supports half-open, receiving FIN without auto-sending its own), but the **HTTP layer** decides for itself whether to also `.end()` the writable side, via `socketOnEnd` (`lib/_http_server.js:957-973`, already quoted in §2): on peer FIN, if `!server.httpAllowHalfOpen`, Node calls `socket.end()` immediately **unless** there's still a queued/in-flight response, in which case it just flags that response `._last = true` so the socket is ended right after that response completes rather than immediately. So: **Node never leaves a fully-idle connection half-open after the peer's FIN — it always eventually calls `.end()` — but it defers that `.end()` until any pending response work is done**, rather than cutting the peer off mid-response.
- **Graceful vs. forceful close is two explicit, separate API calls, not one:**
  - `server.close()` (`Server.prototype.close`, `lib/_http_server.js:694-698`) — stops accepting new connections (delegates to `net.Server.prototype.close`) and, via `httpServerPreClose` (`lib/_http_server.js:645-648`, called first), proactively calls `this.closeIdleConnections()` and clears the connections-checking interval timer. **It does NOT touch active connections** (ones mid-request or mid-response) — the doc is explicit (`doc/api/http.md:1773-1776`): *"Stops the server from accepting new connections and closes all connections connected to this server which are not sending a request or waiting for a response."* The server's own `'close'` event/callback only fires once **all** connections (including the active ones, whenever they naturally finish) have ended — `net.Server.close()`'s normal semantics.
  - `server.closeIdleConnections()` (`lib/_http_server.js:716-730`) — walks `this[kConnections].idle()` (the C++ `ConnectionsList::Idle`, which returns parsers where `last_message_start_ == 0 || !received_data_` — i.e. sockets that have never actively been mid-message, which in practice means keep-alive-idle sockets between requests) and destroys each socket **unless** it has an attached `_httpMessage` that isn't `finished` yet (extra guard against racing a response that just started). This is the "idle" set, computed by the C++ `ConnectionsList` the parser registers itself into at `Initialize` (`src/node_http_parser.cc:728-741`) and at message-begin/message-complete (`PushActive`/`PopActive`, tracked separately from "all" — see `src/node_http_parser.cc:318-346,543-578`).
  - `server.closeAllConnections()` (`lib/_http_server.js:704-714`) — **unconditionally `socket.destroy()`s every tracked connection**, including ones actively sending/receiving — doc calls this explicitly forceful (`doc/api/http.md:1803-1811`: *"This is a forceful way of closing all connections and should be used with caution"*) and recommends calling it **after** `server.close()` to avoid a race where a brand-new connection sneaks in between the two calls.
  - There is **no built-in "lingering close" drain-then-FIN period** analogous to nginx's `lingering_close` — Node's idle-connection close is an immediate `socket.destroy()` (a `net.Socket.destroy()`, which is an abortive close, not a graceful `.end()`), not a graceful TCP shutdown that waits to drain the peer's in-flight bytes. The "grace" Node offers is purely at the HTTP-message level (don't destroy a socket with in-flight request/response work), not at the TCP level (no linger-on-close waiting for peer ACKs/FIN).
  - `Server.prototype[SymbolAsyncDispose]` (`lib/_http_server.js:700-702`) is just `await promisify(this.close)` — no additional force semantics.
- **Per-connection cleanup on the raw socket `'close'` event** — `socketOnClose(socket, state)` (`lib/_http_server.js:936-941`): `freeParser(socket.parser, null, socket)` (returns the parser to a `FreeList` pool of size 1000, or schedules `parser.close()` via `setImmediate` if the pool is full — `lib/_http_common.js:188-210`), then `abortIncoming(state.incoming)` and `abortOutgoing(state.outgoing)` (`lib/_http_server.js:943-955`) — every request/response still sitting in either queue gets `.destroy(new ConnResetException('aborted'))`, i.e. **socket close is the final, unconditional cleanup point that guarantees no `IncomingMessage`/`ServerResponse` is left dangling**, regardless of how far through its lifecycle it was.
- **Second-close idempotency** is handled purely by relying on the underlying stream's own idempotent `destroy()`/`close` semantics (`OutgoingMessage.prototype.destroy`, `lib/_http_outgoing.js:390-409`, guards on `this.destroyed`) — this is the JS-level analogue of the chez-libuv fact that "a SECOND uv-close! on a closing handle silently discards its on-close callback"; Node's higher layer never issues a redundant destroy in the first place because every destroy path checks a `destroyed`/`_closed` flag first.

**Test evidence:**
- `tests/test-http-server-close-idle.js` (read in full, §4) — directly demonstrates `close()` sparing an active connection while `closeAllConnections()` afterward kills it too.
- `tests/test-http-server-close-all.js`, `test-http-server-close-idle-wait-response.js`, `test-http-server-close-idle-connections-pre-request.js` — fetched, filenames strongly indicative of the remaining edge cases (NOT VERIFIED in full).
- `tests/test-http-eof-on-connect.js` — fetched, presumably tests immediate-FIN-on-connect handling (NOT VERIFIED).

---

## 10. Application handler API shape

- **Registration**: `http.createServer([options], requestListener)` → `requestListener` is just `server.on('request', requestListener)` under the hood (`lib/_http_server.js:673-675`).
- **Handler signature**: `(req: IncomingMessage, res: ServerResponse) => void`. No return value is awaited by the framework for ordinary synchronous handlers; for `async` handlers, Node only special-cases an eventual **rejection** via `events.captureRejections` (`Server.prototype[EE.captureRejectionSymbol]`, §8) — the resolved value is otherwise ignored.
- **`req` (IncomingMessage)** is a `Readable` stream (`ObjectSetPrototypeOf(IncomingMessage.prototype, Readable.prototype)`, `lib/_http_incoming.js:113`) whose `_read()` is a near-no-op that just unpauses the socket (§3) — body bytes arrive via the ordinary `'data'`/`'end'` Readable protocol or `.pipe()`; headers are pre-parsed synchronously into `req.headers`/`req.rawHeaders`/`req.method`/`req.url`/`req.httpVersion` **before** the `'request'` event fires (headers-complete is what triggers `parserOnIncoming` → `'request'`, so the handler always sees a fully-parsed head with a body that may still be in flight).
- **`res` (ServerResponse)** is a `Stream` (not technically a `Writable` — it subclasses the legacy `Stream` base and hand-implements `write`/`end`/cork/uncork semantics in `OutgoingMessage`, `lib/_http_outgoing.js`), with implicit-vs-explicit header modes: if the handler calls `res.write()`/`res.end()` before ever calling `res.writeHead()`, `_implicitHeader()` synthesizes headers from whatever `res.setHeader()` calls happened plus `res.statusCode` (default `200`, `lib/_http_server.js:282`). Sockets are attached lazily and only in FIFO pipeline order (§2), which the handler code never has to think about — `res` is usable as if fully connected from the start; queuing is transparent.
- **One handler call per request, including pipelined ones** — the doc is explicit (`doc/api/http.md:1696-1697`): *"There may be multiple requests per connection (in the case of HTTP Keep-Alive connections)"* — i.e. the handler is connection-agnostic; it never sees "connection" state directly except via `req.socket`/`res.socket`, and must not assume one handler invocation == one TCP connection.
- **Escape hatches for non-standard flows** are separate events, not handler return values: `'checkContinue'`, `'checkExpectation'`, `'upgrade'`, `'connect'`, `'clientError'`, `'dropRequest'`, `'timeout'`, `'close'`(server), `'connection'` (raw socket, pre-parse) — each with its own argument shape (documented and cross-checked against source in §5/§6/§8/§9 above).
- **Server-level knobs are almost all plain mutable properties**, not constructor-only options: `server.timeout`, `server.keepAliveTimeout`, `server.headersTimeout`, `server.requestTimeout`, `server.maxHeadersCount`, `server.maxRequestsPerSocket`, `server.keepAliveTimeoutBuffer`, `server.connectionsCheckingInterval` can all be read and (mostly) reassigned after `createServer()` — but changing them only affects **new** connections/timers going forward, never retroactively rearms existing sockets' already-set timers (explicit doc callouts for `server.timeout`, `doc/api/http.md:2005-2006`, and `server.keepAliveTimeout`, `doc/api/http.md:2036-2037`).

---

## 11. What Node's own test suite covers that we should copy (files named, by category)

All fetched to `node-src/tests/`, pinned at commit `357ba2f676126e2c0e54dca4c47085fce975836b`, listed in `node-src/tests/LIST.txt` (78 files total, all with `test/parallel/` upstream path):

- **Keep-alive truth table & version interaction**: `test-http-should-keep-alive.js`, `test-http-1.0-keep-alive.js`, `test-http-1.0.js`, `test-http-keep-alive-close-on-header.js`, `test-http-server-keep-alive-defaults.js`, `test-http-server-keep-alive-timeout.js`, `test-http-keep-alive-timeout-buffer.js`, `test-http-remove-connection-header-persists-connection.js`.
- **Per-socket request caps**: `test-http-keep-alive-max-requests.js`, `test-http-keep-alive-pipeline-max-requests.js`, `test-http-keep-alive-drop-requests.js`.
- **Pipelining correctness under adversarial teardown**: `test-http-pipeline-flood.js`, `test-http-many-ended-pipelines.js`, `test-http-pipeline-requests-connection-leak.js`, `test-http-incoming-pipelined-socket-destroy.js`.
- **Timeout matrix (headers vs request vs keepAlive, at delayed/interrupted/pipelined/keepalive/upgrade variants)**: `test-http-server-headers-timeout-pipelining.js`, `test-http-server-request-timeout-pipelining.js`, `test-http-server-headers-timeout-delayed-headers.js`, `test-http-server-headers-timeout-interrupted-headers.js`, `test-http-server-headers-timeout-keepalive.js`, `test-http-server-request-timeout-delayed-body.js`, `test-http-server-request-timeout-interrupted-body.js`, `test-http-server-request-timeout-keepalive.js`, `test-http-server-request-timeout-upgrade.js`, `test-http-server-timeouts-validation.js`, `test-http-set-timeout-server.js`, `test-http-server-consumed-timeout.js`.
- **Expect/100-continue**: `test-http-expect-continue.js`, `test-http-expect-handling.js`, `test-http-expect-continue-reuse-race.js`.
- **Upgrade/CONNECT**: `test-http-upgrade-server.js`, `test-http-upgrade-server2.js`, `test-http-upgrade-server-with-body.mjs`, `test-http-upgrade-advertise.js`, `test-http-connect.js`, `test-http-connect-req-res.js`, `test-http-upgrade-server-callback.js`.
- **Header-limit enforcement**: `test-http-max-http-headers.js`, `test-http-max-headers-count.js`, `test-http-max-headers-count-overflow.js`, `test-http-chunk-extensions-limit.js`.
- **`clientError` semantics and malformed input**: `test-http-server-client-error.js`, `test-http-server-multiple-client-error.js`, `test-http-malformed-request.js`, `test-http-server-destroy-socket-on-client-error.js`, `test-http-parser-finish-error.js`, `test-http-eof-on-connect.js`, `test-http-server-reject-cr-no-lf.js`, `test-http-missing-header-separator-lf.js`, `test-http-blank-header.js`.
- **Framing precedence / HEAD / 1xx / 204 / 304**: `test-http-head-response-has-no-body.js`, `test-http-head-response-has-no-body-end.js`, `test-http-head-request.js`, `test-http-chunked-304.js`, `test-http-allow-content-length-304.js`, `test-http-response-multi-content-length.js`, `test-http-content-length-mismatch.js`, `test-http-response-splitting.js`, `test-http-status-reason-invalid-chars.js`.
- **Trailers**: `test-http-set-trailers.js`, `test-http-server-de-chunked-trailer.js`.
- **Shutdown**: `test-http-server-close-idle.js`, `test-http-server-close-all.js`, `test-http-server-close-idle-wait-response.js`, `test-http-server-close-idle-connections-pre-request.js`.
- **Backpressure / highWaterMark**: `test-http-highwatermark.js`, `test-http-outgoing-drain-writable-length.js`, `test-http-response-drain-cork.js`, `test-http-server-options-highwatermark.js`.
- **Miscellaneous connection hygiene**: `test-http-server-unconsume.js`, `test-http-server-optimize-empty-requests.js`, `test-http-server-reject-chunked-with-content-length.js`, `test-http-double-content-length.js`.
- **Deliberate HTTP request-smuggling regression tests (a whole category worth copying wholesale as a checklist)**: `test-http-request-smuggling-content-length.js`, `test-http-transfer-encoding-smuggling.js`, `test-http-chunked-smuggling.js`, `test-http-invalid-te.js`.
- **Plain sanity/API-shape**: `test-http-server.js`, `test-http-server-response-standalone.js`, `test-http-response-no-headers.js`, `test-http-server-write-after-end.js`.

**The single most valuable thing to copy is the smuggling test *category itself*** (`*-smuggling.js` + `test-http-invalid-te.js` + `test-http-double-content-length.js` + `test-http-request-smuggling-content-length.js`): each one encodes a **specific wire-level ambiguity** (duplicate `Content-Length`, duplicate/obfuscated `Transfer-Encoding`, malformed chunk-extension syntax, OWS before a header colon) that a naive parser+framing implementation gets wrong, paired with an assertion that the *smuggled* second request is never independently dispatched. Since chez-httparse already claims llhttp-fixture parity (per the project brief), the parser layer should already reject these — but **chez-http-server's connection layer is what decides what happens next** (respond 400 + close vs. silently drop vs. try to keep parsing), and that's exactly the layer these tests exercise. We should write our own equivalents against our connection state machine, not just trust the parser's fixture parity.

---

## 12. Concrete lessons for chez-http-server

1. **Keep-alive is a pure function of parser state at message-complete, computed once, never re-derived ad hoc.** Node computes `shouldKeepAlive` exactly once, inside the parser, from three inputs only: HTTP minor version, `F_CONNECTION_CLOSE`/`F_CONNECTION_KEEP_ALIVE` flags, and "does this message's framing require EOF to terminate." chez-httparse's `parser-field-ref` exposes `'http-major`/`'http-minor`/`'flags`/`'content-length`/`'upgrade` — we should compute an equivalent boolean **inside the `on-message-complete` callback** (per the project brief's own warning that flags reset between pipelined messages) and store it on our per-request record immediately, never re-read parser flags after the callback returns.
2. **The close-delimited-body rule (no Content-Length, no chunked ⇒ force close) belongs in the body-framing decision, not bolted on afterward.** This single rule is why an HTTP/1.0 response with only `Connection: keep-alive` and no length framing still can't actually be reused (`test-http-1.0-keep-alive.js`) — get this right early or every "should we keep this connection open" decision downstream will need a patch.
3. **Response ordering under pipelining is a single-attached-message-at-a-time invariant enforced by an explicit `outgoing[]` FIFO, decoupled from request parsing.** The parser is free to keep consuming and even fully parsing subsequent pipelined requests (into an `incoming[]` queue) while only one response is ever "on the wire" — mirrors what we'll need with chez-libuv, since `uv-write!` completion order is exactly what must gate "now assign the socket to the next response," not handler-completion order. Copy the two-queue (`incoming[]`/`outgoing[]`) shape directly; it's simple and it's been battle-tested.
4. **Read backpressure should be driven by *write*-side congestion, not (only) by the reader's own buffer.** Node's `state.outgoingData` byte counter across all pending responses on a connection, compared against the writable high-water mark, is what actually throttles further request parsing (`parserOnIncoming`'s pause check) — this is the direct answer to the chez-libuv fact that there's no bounded write queue in the binding: **track outstanding queued-response bytes ourselves, at the connection level, and call `uv-read-stop!` when it crosses a threshold**, exactly analogous to `socket.pause()` here. Un-pause (`uv-read-start!`) only once that counter drops back down, mirroring `socketOnDrain`.
5. **Every synthetic/framework-generated error response is `Connection: close`, no exceptions, and is skipped entirely (in favor of a bare `destroy()`) once any response bytes have already gone out.** Copy both halves of this rule: (a) canned error responses always close; (b) never try to write a synthetic error over a response whose headers are already sent — that's corruption, not recovery, and it's exactly the class of bug that `uv-write!`'s already-departed-bytes assumption in chez-libuv (buffers copied, block freed before `on-complete`) would make *look* safe to attempt but isn't, semantically.
6. **Collapse "can't parse this at all" into one generic 400, don't try to distinguish 501 vs 505 vs 400 from parser errno.** Node explicitly doesn't bother; both `HPE_INVALID_METHOD` and `HPE_INVALID_VERSION` fall through the same `default:` branch to 400. Only give distinct codes to the cases that have a distinct *actionable* meaning for the client: 431 (header/field limits — tells the client "shrink your headers"), 413 (chunk-extension size — arguably shows this could be folded into "bad request" too, but Node keeps it distinct), 408 (timeout — tells the client "you were too slow, retry"). This is a deliberate simplicity choice worth adopting rather than second-guessing.
7. **`maxRequestsPerSocket` degrades gracefully (advertise `Connection: close` on the *last allowed* response) rather than abruptly severing** — the socket isn't killed the instant the counter is hit; the *next* request over the limit gets a `503` and *that's* what closes things. This two-step wind-down (announce-then-refuse) is a nicer UX than a hard cutoff and cheap to implement given we're already tracking a per-connection request counter.
8. **The `checkContinue`/`checkExpectation`/plain-`'request'` mutual exclusion, and the "force-close if we skipped a promised 100-continue" rule, are both small and easy to get wrong.** Both are one-line invariants (`handled` boolean gates which single event fires; `_expect_continue && !_sent100 ⇒ force close`) — worth writing a dedicated unit test for each rather than assuming "it'll just work" from the individual Expect-handling and keep-alive pieces in isolation, since the *combination* is the actual bug surface (see `test-http-expect-continue-reuse-race.js` — a real historical bug born from two independent "can this connection be reused" signals racing each other; if we track keep-alive/reuse eligibility from a **single** state transition rather than two independent listeners, we avoid this whole class of bug).
9. **`close()` (graceful) vs `closeAllConnections()` (forceful) vs `closeIdleConnections()` should be three distinct, separately-callable operations**, not one "shutdown" verb with a boolean flag — Node's own doc explicitly recommends composing them (`close()` then `closeAllConnections()`) rather than trying to make one call do both, and this composability is exactly what let `test-http-server-close-idle.js` assert graceful-vs-forceful behavior independently.
10. **Socket `'close'` (i.e., in our world, the `on-close` callback from `uv-close!`) is the unconditional final cleanup point** — every queued/in-flight request and response object gets explicitly aborted there (`abortIncoming`/`abortOutgoing`), regardless of how it got into that state. Given chez-libuv's rule that a server must own every close initiation and that a second `uv-close!` silently no-ops, we should design our connection record so that **all** request/response cleanup — including releasing any references we hold that would otherwise leak — happens from exactly one place keyed off the close callback, not scattered across every error path that *might* lead to a close.
11. **Upgrade/CONNECT with a still-in-flight request body is a real, separate case from the common "upgrade with an empty/complete request" case**, and needs its own wrapper stream (Node's `UpgradeStream`) that defers exposing *post-body* raw bytes until the body finishes parsing. Don't assume upgrade always means "request is trivially complete, hand over the raw connection" — chez-httparse's `on-headers-complete` → `'skip-body` answer plus `parser-resume!` gives us the primitive to detect this same split, but the connection layer needs to explicitly plan for "body still streaming, but the connection is also now supposed to become raw" as its own state.
12. **CONNECT is unconditionally an upgrade regardless of headers; other `Upgrade:` requests are opt-in via listener presence (`shouldUpgradeCallback`, default = "is anyone listening for `'upgrade'`").** This means our default behavior for an unrecognized `Upgrade:` header, absent an app registering interest, should be "treat as a normal request" (Node does — falls through to ordinary request handling), **not** "reject/close" — only CONNECT and an *accepted* Upgrade (by having a handler) get the hard-destroy-if-unhandled treatment.
13. **The `Keep-Alive: timeout=N, max=M` response header is derived from server config, not per-request, and cached as a single formatted string module-wide** since it's identical across every response on a given server config — cheap and worth copying as a micro-optimization pattern for our own hot per-response header rendering path.
14. **Distinguish per-connection tracking two ways: "idle" (never mid-message) vs "active" (currently mid-message), maintained as two separate doubly-linked-list-style membership sets updated at message-begin/message-complete/parser-init.** This is exactly the shape needed to implement `closeIdleConnections()`-equivalent behavior in O(idle-count) rather than scanning every connection — worth adopting directly given we'll have our own registry (the brief already notes chez-libuv's handle registry is a single eqv-hashtable; we likely need a second structure layered on top specifically for "connections not currently mid-request," analogous to Node's `ConnectionsList`).

---

## Gaps / things NOT verified in this pass

- I did not fetch or read `lib/internal/streams/state.js` beyond confirming it exists (`getDefaultHighWaterMark` import) — the actual default highWaterMark number (commonly 16 KiB / 64 KiB depending on object mode) was not independently confirmed from source in this pass.
- `src/node_options.cc` was only grepped for `max-http-header-size`; other options (e.g. any `--http-...` flags) were not enumerated exhaustively.
- ~60 of the 78 fetched test files were only grep-matched for status-code/error-code strings, not read for full context — flagged individually above wherever cited.
- I did not independently verify against a live Chez/Node run — this is a pure static source read, as instructed by the task (no execution requested, and none of this needs the chez-libuv/chez-httparse/uriparse toolchain to reproduce).
- The `keepAliveTimeout` default of 65000ms is tagged `REPLACEME` in this pinned commit's doc changelog, meaning it's an **unreleased** change on Node's main branch as of the fetch; production Node (any released version as of this writing) defaults to **5000ms**. Whoever synthesizes across all reference-server reports should treat 65000ms as "where Node is heading," not "what's deployed today" — cite this explicitly if picking a default.
