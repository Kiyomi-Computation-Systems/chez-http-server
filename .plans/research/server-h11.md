# h11 connection-semantics extraction for chez-http-server

Source: https://github.com/python-hyper/h11 (sans-I/O HTTP/1.1 connection state machine).
Pinned commit: `62c5068c971579d61fa1b55373390e12f25fd856` (branch `master`, fetched 2026-09-19; one
commit ahead of tag `v0.16.0` = `1c5b07581f058886c8bdd87adababd7d959dc7ca`). License: MIT
(`https://raw.githubusercontent.com/python-hyper/h11/master/LICENSE.txt`).

All files below were fetched with `curl` from `raw.githubusercontent.com/python-hyper/h11/master/...`
and saved locally so line numbers are exact and checkable:

| Local mirror (this scratchpad) | Upstream URL | Lines |
|---|---|---|
| `h11-src/_connection.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_connection.py` | 659 |
| `h11-src/_state.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_state.py` | 365 |
| `h11-src/_headers.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_headers.py` | 282 |
| `h11-src/_readers.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_readers.py` | 250 |
| `h11-src/_writers.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_writers.py` | 145 |
| `h11-src/_receivebuffer.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_receivebuffer.py` | 153 |
| `h11-src/_events.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_events.py` | 369 |
| `h11-src/_util.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/_util.py` | 135 |
| `h11-src/__init__.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/__init__.py` | 62 |
| `h11-src/docs/api.rst` | `https://raw.githubusercontent.com/python-hyper/h11/master/docs/source/api.rst` | 1098 |
| `h11-src/tests/test_connection.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_connection.py` | 1120 |
| `h11-src/tests/test_state.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_state.py` | 271 |
| `h11-src/tests/test_io.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_io.py` | 583 |
| `h11-src/tests/test_events.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_events.py` | 148 |
| `h11-src/tests/test_headers.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_headers.py` | 159 |
| `h11-src/tests/test_against_stdlib_http.py` | `https://raw.githubusercontent.com/python-hyper/h11/master/h11/tests/test_against_stdlib_http.py` | 115 |

`_abnf.py` was listed in the directory (`https://api.github.com/repos/python-hyper/h11/contents/h11?ref=master`)
but not deep-read beyond confirming its role (regex grammar for request/status lines, header-field,
chunk-header — imported by `_readers.py:22` and `_headers.py:4`); not needed for connection-semantics
extraction. All quotations of h11 source/docs below are short excerpts (a line or a few lines) used for
citation and technical accuracy, not verbatim reproduction of the whole work.

Every claim below cites a `file:line` in the table above, or a docs section anchor in `docs/api.rst`.

---

## 1. Keep-alive decision rule

Function `_keep_alive(event)`, `h11-src/_connection.py:84-90`:

```python
def _keep_alive(event: Union[Request, Response]) -> bool:
    connection = get_comma_header(event.headers, b"connection")
    if b"close" in connection:
        return False
    if getattr(event, "http_version", b"1.1") < b"1.1":
        return False
    return True
```

Preceding comment block (`_connection.py:72-83`) states the simplification explicitly: h11
**does not support keep-alive with HTTP/1.0 peers at all** — RFC 7230's real rule is "HTTP/1.0
defaults to close unless both sides say `Connection: keep-alive`", but h11 collapses this to "any
HTTP/1.0 peer means close", and only implements the HTTP/1.1 half of the rule ("defaults to
keep-alive unless `Connection: close`").

This function is called from `_process_event` on every `Request` and `Response` event
(`_connection.py:305-308`):
```python
if type(event) in (Request, Response) and not _keep_alive(...):
    self._cstate.process_keep_alive_disabled()
```
`InformationalResponse` is deliberately excluded — the comment at `_connection.py:299-304` notes
RFC 7230 doesn't define what `Connection: close` on a 1xx means, so h11 ignores it there.

`process_keep_alive_disabled()` (`_state.py:267-269`) sets `ConnectionState.keep_alive = False`
and re-fires the state-triggered-transition fixed point (`_state.py:316-354`). The actual effect —
"if keep-alive is disabled, force both `CLIENT` and `SERVER` out of `DONE` into `MUST_CLOSE`" — is a
state-triggered rule, not an event-triggered one (`_state.py:342-345`):
```python
if not self.keep_alive:
    for role in (CLIENT, SERVER):
        if self.states[role] is DONE:
            self.states[role] = MUST_CLOSE
```
Keep-alive is a one-way latch: `True -> False` only, no path back (`_state.py:57-60` comment,
confirmed by the transition table having no `False -> True` case). Verified by
`test_ConnectionState_keep_alive` (`h11-src/tests/test_state.py:62-74`, single-direction assert)
and `test_reuse_simple` (`h11-src/tests/test_connection.py:489-521`).

**Close-delimited response forces close.** A response with no `Content-Length` and no
`Transfer-Encoding` (`_body_framing` returns `("http/1.0", ())`, `_connection.py:140-141`) means
"body ends when the connection closes" — this is exactly RFC 7230's close-delimited framing, kept
alive here as the `"http/1.0"` reader/writer key even for an HTTP/1.1 peer with unknown-length body
when the *peer* is HTTP/1.0 (see §7 framing precedence). `_clean_up_response_headers_for_sending`
(`_connection.py:602-659`) is where h11, as a server, decides to force `Connection: close`:
- if body framing resolves to `"chunked"` or `"http/1.0"` (unknown length) **and** the peer is
  HTTP/1.0 or unknown (`self.their_http_version is None or < b"1.1"`,`_connection.py:632-643`),
  h11 clears `Transfer-Encoding` and sets `need_close = True` (skipped only for HEAD, since a HEAD
  response never actually streams a body) — this is precisely "close-delimited response forces
  close" because an HTTP/1.0 peer cannot understand chunked framing, so there is no way to signal
  end-of-body except closing.
- unconditionally, `if not self._cstate.keep_alive or need_close:` (`_connection.py:647`), the
  `Connection` header is rewritten to add `close` and drop `keep-alive` (`_connection.py:648-652`).

So the rule a server-side caller must apply is: **h11 will tell you (via `our_state is
MUST_CLOSE`) that you must close** — you never need to compute this yourself; you just have to act
on it after sending the response (`docs/api.rst:921-928`, "Check if `conn.our_state is
h11.MUST_CLOSE`").

---

## 2. Pipelining policy and response ordering

**As a client**, h11 structurally forbids pipelining: after sending one `Request`, the client state
machine moves to `SEND_BODY` (`_state.py:198`, `EVENT_TRIGGERED_TRANSITIONS[CLIENT][IDLE]`), and
there is no `IDLE -> ...` transition available again until `start_next_cycle()` resets both sides
from `{DONE, DONE}` back to `{IDLE, IDLE}` (`_state.py:356-365`). `start_next_cycle()` itself raises
`LocalProtocolError` unless `self.states != {CLIENT: DONE, SERVER: DONE}`
(`_state.py:357-360`), and requires reading the full server response first. Docs, `docs/api.rst:660-666`, state
this explicitly: "As a client, h11 does not support pipelining. This is enforced by the structure of
the state machine."

**As a server**, h11 supports the minimal amount of pipelining required by the standard: it will
parse and deliver events for the request currently at the head of the queue, then refuse to parse
any more until the corresponding response is sent and `start_next_cycle()` is called
(`docs/api.rst:668-674`). Mechanically, this is `_extract_next_receive_event`
(`_connection.py:410-436`):
```python
if state is DONE and self._receive_buffer:
    return PAUSED
```
i.e. once the server's view of *their* role (`self.their_state`, which after receiving a full
request is `DONE`) is `DONE` **and** there is any unconsumed byte left in `_receive_buffer`
(meaning a second pipelined request has already arrived), `next_event()` returns the sentinel
`PAUSED` instead of parsing further — the extra bytes for request #2/#3 sit untouched in the
`ReceiveBuffer` (`_receivebuffer.py`). This is proven end-to-end by
`test_pipelining` (`h11-src/tests/test_connection.py:522-591`): three requests delivered in one
`receive_data()` call; `get_all_events()` yields only request #1's `Request`/`Data`/`EndOfMessage`;
`next_event()` then returns `PAUSED`; only after `send(Response)+send(EndOfMessage)+start_next_cycle()`
does request #2 become visible. `test_pipelined_close` (`tests/test_connection.py:826-865`) shows
the same mechanism composes correctly with a client that pipelines two requests and then closes its
write side (`receive_data(b"")`): the second request's `EndOfMessage` is immediately followed in the
same `get_all_events()` batch by `ConnectionClosed()`, and the server state becomes `{CLIENT:
CLOSED, SERVER: SEND_RESPONSE}` — i.e. **you can still send the second response after the client
has hung up its read side**, because TCP close is half-duplex (see §9).

**Response ordering is therefore trivially guaranteed to be FIFO by construction**, not by any
explicit "response queue" data structure — because the server literally cannot parse request #2
until it has finished (sent) the response to request #1 and called `start_next_cycle()`. There is no
possibility of reordering responses relative to requests because request #2 does not exist yet, as
far as the `Connection` object's event stream is concerned, until the app explicitly asks for it via
`start_next_cycle()`.

`PAUSED` has three distinct causes, enumerated in `docs/api.rst:733-756`: (1) pipelining as above,
(2) a completed protocol switch (`state is MIGHT_SWITCH_PROTOCOL or SWITCHED_PROTOCOL`,
`_connection.py:420-421`), (3) waiting to find out whether a proposed switch was accepted. All three
share the identical mechanical check at `_connection.py:418-421`.

---

## 3. Streaming request/response bodies; backpressure

**h11 has no I/O of its own** — this is the entire point of "sans-I/O" (`docs/api.rst:1-11` of
README, and `__init__.py:1-7` docstring-comment: "containing no networking code at all"). It
converts bytes to/from a sequence of events; the caller owns the socket, the event loop, and any
buffering/backpressure policy. This is the single most load-bearing design fact for us.

### Request bodies -> handler (receive direction)
The API is a manual pull loop over `Connection.next_event()` (`_connection.py:438-501`), fed by
`Connection.receive_data(data)` (`_connection.py:364-408`). `receive_data(b"")` is the sentinel for
"peer half-closed their write side" (`_connection.py:374-408`); calling it again is idempotent,
calling it with real bytes afterward raises `RuntimeError("received close, then received more
data?")` (`_connection.py:404-405`). Each `next_event()` call returns either a real `Event`, the
sentinel `NEED_DATA` (buffer needs more bytes before another event can be extracted,
`_connection.py:434-435`), or `PAUSED` (see §2). A body is delivered to the handler as a stream of
`Data(data=<bytes>)` events terminated by `EndOfMessage()` (`docs/api.rst:191-196`); for chunked
bodies each `Data` optionally carries `chunk_start`/`chunk_end` markers the docs explicitly tell you
not to rely on semantically (`docs/api.rst:1061-1098`, `_events.py:272-297`).

**Backpressure on the read side is 100% the caller's responsibility**, exercised simply by *not
calling* `receive_data()`/`next_event()` again until ready. `docs/api.rst:677-839` ("Flow control")
gives the two canonical patterns:
- **Pull-style** (`docs/api.rst:759-776`): a `get_next_event()` wrapper loop that calls
  `conn.receive_data(do_recv())` only when `NEED_DATA` is seen, and the caller's own outer loop
  decides when to call it (i.e. TCP-level flow control alone provides backpressure: read only when
  ready to process).
- **Push-style** (`docs/api.rst:782-831`, worked `asyncio.Protocol` example): on `PAUSED`, call
  `transport.pause_reading()`; on `start_next_cycle()`, call `transport.resume_reading()`. This is
  pause/resume backpressure driven off `PAUSED`, not off buffer size — h11 gives you *no* signal for
  "body still streaming, slow down," because a `Data` event is emitted as soon as bytes are
  available in `_receive_buffer`; if the handler is slow to consume `Data` events the caller must
  throttle its own socket reads (stop calling `receive_data`), h11 will simply hold undelivered
  bytes in the internal `bytearray`-backed `ReceiveBuffer` (`_receivebuffer.py:47-56`) with no size
  cap of its own (see §4 — the only cap applies to *incomplete, unparsed* prefix, not to body data
  being streamed through).

### Response bodies -> wire (send direction)
`Connection.send(event)` (`_connection.py:517-542`) is purely synchronous/non-blocking: it "just
immediately returns all the data you need to send for the given event, so you can apply whatever
send buffer strategy you want" (`docs/api.rst:682-685`). There is no backpressure signal from h11 on
the write side at all — `send()` never blocks and never refuses because a peer is slow; the calling
code applies TCP-level backpressure itself (e.g., by writing to a non-blocking socket, checking
what's actually written, and pausing `Data` production based on the socket's own write-buffer state
— which is exactly the shape of libuv's `uv-write!`/`uv-stream-write-queue-size` model our stack
already uses).

`send_with_data_passthrough(event)` (`_connection.py:544-575`) is the zero-copy escape hatch: for a
`Data` event, it guarantees the returned list contains the **exact object you passed in** as
`Data.data`, not a copy (`docs/api.rst:544-549`, `1002-1032`) — this is what enables `sendfile()`
support (§"sendfile", `docs/api.rst:983-1036`): wrap a `FilePlaceholder` object with `__len__`
implemented, `ContentLengthWriter`/`ChunkedWriter` only ever call `len(data)` and `write(data)` on it
(`_writers.py:78-113` comment + `ContentLengthWriter.send_data`, `_writers.py:88-92`), so they can
transparently frame a sendfile placeholder without ever touching its bytes. `test_sendfile`
(`tests/test_connection.py:868-903`) is the executable proof.

Both directions are therefore **exactly the same in spirit**: h11 is a pure translator between bytes
and events; all buffering/backpressure state lives in the caller's I/O layer, not in h11. That maps
directly onto chez-libuv's own posture (no bounded write queue in the binding either — ADR-0018 —
consumer tracks `uv-stream-write-queue-size`), which is a strong argument for putting flow control
in chez-http-server's connection/imperative-shell layer exactly where h11 puts it, rather than
trying to push it into the parser or into libuv.

---

## 4. Every named limit and timeout, with its default number

There is exactly **one built-in numeric limit** in h11, and h11 has **zero built-in timeouts** —
being sans-I/O, it has no clock and no timer of any kind. Grep of `error_status_hint=` across all
source files (the only place default-adjacent numeric-with-semantics constants appear) turns up
only two non-default hints, both documented below.

- **`DEFAULT_MAX_INCOMPLETE_EVENT_SIZE = 16 * 1024`** (16 KiB) — `_connection.py:69`, constructor
  default parameter `max_incomplete_event_size` (`_connection.py:170`, docstring
  `_connection.py:158-163`). Comment directly above it (`_connection.py:59-68`) explains scope
  precisely: "If we ever have this much buffered without it making a complete parseable event, we
  error out. The only time we really buffer is when reading the request/response line + headers
  together, so this is effectively the limit on the size of that [request/status line + headers]."
  It does **not** limit body size (a `Content-Length`-framed or chunked body streams through as
  `Data` events regardless of size; only the head-of-message buffering is capped). Enforced at
  `_connection.py:484-490`:
  ```python
  if event is NEED_DATA:
      if len(self._receive_buffer) > self._max_incomplete_event_size:
          raise RemoteProtocolError("Receive buffer too long", error_status_hint=431)
  ```
  i.e. the check only fires when the reader *still* needs more data to complete an event and the
  buffer has grown past the cap — mapped to HTTP status **431** (Request Header Fields Too Large).
  The comment cites three other implementations' precedents for the default value
  (`_connection.py:64-68`): node.js 80 KiB, Tomcat 8 KiB, IIS 16 KiB, Apache ~8 KiB/line. Tested by
  `test_max_incomplete_event_size_countermeasure` (`tests/test_connection.py:413-419`).
- **`CONTENT_LENGTH_MAX_DIGITS = 20`** — `_headers.py:15`, comment: "allow up to 1 billion TB - 1".
  Enforced in `normalize_and_validate` (`_headers.py:178-179`): a `Content-Length` value with more
  than 20 digits raises `LocalProtocolError("bad Content-Length")` (default `error_status_hint`,
  i.e. 400 — see §9). This is a pure sanity bound against integer/parsing abuse, not a
  size-of-body policy.
- **No request timeout, no header timeout, no idle-connection timeout, no keep-alive timeout, no
  body-read timeout** exist anywhere in h11. `test_408_request_timeout`
  (`tests/test_connection.py:990-994`) documents this precisely by *not* testing a timeout
  mechanism at all — it only proves that a server `Connection` object is structurally allowed to
  **spontaneously send** a `Response(status_code=408, ...)` from `IDLE` state without ever having
  seen a `Request` (`SERVER: IDLE: {Response: SEND_BODY, ...}` in `_state.py:207-210`), i.e. h11
  supports the server *emitting* a 408 as an event, but detecting that a timeout occurred is
  entirely external (a real clock/timer in the caller's event loop). The docs make the general
  principle explicit at `docs/api.rst:282-286`: "Server sending a Response directly from IDLE: This
  is used for error responses, when the client's request never arrived (e.g. 408 Request Timed Out)
  or was unparseable gibberish (400 Bad Request)."
- **No limit on number of headers, no limit on number of pipelined requests queued in the receive
  buffer**, no limit on chunk-extension length (chunk extensions are simply discarded — comment "XX
  FIXME: we discard chunk extensions. Does anyone care?", `_readers.py:186`) — anything not listed
  above is unbounded in h11 itself and left to the embedder.

---

## 5. `Expect: 100-continue` handling

`has_expect_100_continue(request)` — `_headers.py:275-282`:
```python
def has_expect_100_continue(request: "Request") -> bool:
    if request.http_version < b"1.1":
        return False
    expect = get_comma_header(request.headers, b"expect")
    return b"100-continue" in expect
```
HTTP/1.0 requests are unconditionally exempted per RFC 7231 §5.1.1 (quoted in the comment at
`_headers.py:276-278`).

State tracked as a plain boolean on `Connection`, **deliberately outside the formal state machine**
(`_connection.py:202-204`, comment: "This is pure flow-control and doesn't at all affect the set of
legal transitions, so no need to bother ConnectionState with it"):
- Set `True` when a `Request` with the header is processed (`_connection.py:311-312`).
- Cleared to `False` in three cases, all in `_process_event` (`_connection.py:313-316`):
  1. any `InformationalResponse` or `Response` is sent/received (server answered, whatever it
     said),
  2. the client itself sends `Data` or `EndOfMessage` (client "goes ahead and sends stuff anyway,"
     `docs/api.rst`'s `test_100_continue` comment) — i.e. h11 doesn't punish a client that ignores
     its own Expect header and just streams the body; it silently reconciles state.

Exposed as two read-only properties: `Connection.client_is_waiting_for_100_continue` (the literal
flag) and `Connection.they_are_waiting_for_100_continue` (`_connection.py:231-233`):
```python
@property
def they_are_waiting_for_100_continue(self) -> bool:
    return self.their_role is CLIENT and self.client_is_waiting_for_100_continue
```
— the second form is what a server actually checks (role-relative, avoids the server accidentally
reading its own state when acting as client-of-something-else in a proxy). Documented usage pattern,
`docs/api.rst:707-722`: before **any** blocking read of a request body, check
`they_are_waiting_for_100_continue` and if true, send an `InformationalResponse(100, ...)` (or, the
docs note, "it could be anything really — e.g. a full Response with a 4xx status code") *first*.
Verified by `test_100_continue` (`tests/test_connection.py:368-410`): three ways to clear the flag
are each exercised (100 Continue sent; a full Response sent instead; client sends Data anyway).

h11 itself never auto-generates the `100 Continue` response — that is 100% the embedder's decision
and the embedder's call to `send()`.

---

## 6. Upgrade / CONNECT (protocol switching)

Two independent "switch-type" mini state machines, `_SWITCH_UPGRADE` and `_SWITCH_CONNECT`
(`_state.py:180-185`), stored implicitly as membership in `ConnectionState.pending_switch_proposals:
Set[Type[Sentinel]]` (`_state.py:257-259`, comment `_state.py:24-32`).

**Proposal (client side).** In `_process_event`, when the client sends a `Request`
(`_connection.py:276-280`):
```python
if role is CLIENT and type(event) is Request:
    if event.method == b"CONNECT":
        self._cstate.process_client_switch_proposal(_SWITCH_CONNECT)
    if get_comma_header(event.headers, b"upgrade"):
        self._cstate.process_client_switch_proposal(_SWITCH_UPGRADE)
```
Both can be proposed simultaneously (a `CONNECT` request that also carries an `Upgrade:` header) —
`test_protocol_switch` (`tests/test_connection.py:594-719`) explicitly covers all four combinations
(deny/accept x CONNECT/Upgrade, including "accept CONNECT not Upgrade" and vice versa when both were
proposed).

**Recognition (server side).** `_server_switch_event(event)` (`_connection.py:260-269`):
```python
def _server_switch_event(self, event):
    if type(event) is InformationalResponse and event.status_code == 101:
        return _SWITCH_UPGRADE
    if type(event) is Response:
        if _SWITCH_CONNECT in self._cstate.pending_switch_proposals and 200 <= event.status_code < 300:
            return _SWITCH_CONNECT
    return None
```
i.e. acceptance is purely status-code-driven: **101** for Upgrade, **2xx** for CONNECT — matching
`docs/api.rst:959-969` exactly. Any other response denies the proposal implicitly: `process_event`
clears `pending_switch_proposals` on any plain `Response` that isn't tagged with a switch event
(`_state.py:289-290`).

**State-machine wiring.** Event table entries for `SERVER: SEND_RESPONSE`
(`_state.py:214-219`) special-case the *tagged* event forms `(InformationalResponse,
_SWITCH_UPGRADE) -> SWITCHED_PROTOCOL` and `(Response, _SWITCH_CONNECT) -> SWITCHED_PROTOCOL`. On
the client side, a **state-triggered** rule couples the two peers together
(`_state.py:235-238`, `STATE_TRIGGERED_TRANSITIONS`): `(MIGHT_SWITCH_PROTOCOL, SWITCHED_PROTOCOL) ->
{CLIENT: SWITCHED_PROTOCOL}` — i.e. once the *server* machine reaches `SWITCHED_PROTOCOL`, the
*client* machine (which has been parked in `MIGHT_SWITCH_PROTOCOL` since finishing its own request)
is automatically carried along, with no separate client-side event needed.

The client enters `MIGHT_SWITCH_PROTOCOL` via another state-triggered rule the moment it finishes
sending its request while a proposal is pending (`_state.py:334-336`):
```python
if self.pending_switch_proposals:
    if self.states[CLIENT] is DONE:
        self.states[CLIENT] = MIGHT_SWITCH_PROTOCOL
```
and a **documented priority rule** resolves the one case where this could race the
keep-alive-driven `DONE -> MUST_CLOSE` transition (e.g. an HTTP/1.0 client attempting `CONNECT`):
"the protocol switch takes priority" (`_state.py:87-90` comment) — evaluated first in the fixed-point
loop (`_state.py:334-345`), so `MIGHT_SWITCH_PROTOCOL` always wins over `MUST_CLOSE` when both are
enabled simultaneously.

**Once switched, h11 is out of the way.** Both `NEED_DATA`/event extraction and `send()` refuse to
operate meaningfully: `_extract_next_receive_event` returns `PAUSED` unconditionally for `state is
MIGHT_SWITCH_PROTOCOL or state is SWITCHED_PROTOCOL` (`_connection.py:420-421`); the `WRITERS`/`READERS`
dicts have no entries for those states, so any `send()` there hits the `assert writer is not None`
guard's implicit failure path through `_process_event`'s prior legality check, which raises
`LocalProtocolError` before ever reaching the writer (`test_protocol_switch`'s final two assertions,
`tests/test_connection.py:713-719`, confirm both "can't send after switching" and "can't send while
waiting for a switch").

**Leftover bytes.** `Connection.trailing_data` (`_connection.py:353-362`) is the hand-off point:
```python
@property
def trailing_data(self) -> Tuple[bytes, bool]:
    return (bytes(self._receive_buffer), self._receive_buffer_closed)
```
returns whatever raw bytes h11 had already buffered past the point of the switch (e.g. the first
bytes of a WebSocket frame that arrived in the same TCP segment as the `101` response), plus whether
EOF had already been seen. `docs/api.rst:977-980` states the intended use directly: "what h11 does
is pause parsing incoming data at the boundary between the two protocols, and then you can retrieve
any unprocessed data from `Connection.trailing_data`." The caller is expected to abandon the
`Connection` object after this and hand the socket + `trailing_data` bytes to whatever protocol
implementation takes over (`docs/api.rst:744-748`).

---

## 7. Framing precedence (Content-Length vs Transfer-Encoding, duplicates, HEAD, 1xx/204/304, HEAD responses)

Core logic: `_body_framing(request_method, event)` — `_connection.py:93-141`. Return value is a
`(kind, args)` tuple consumed by both `READERS`/`WRITERS`' `SEND_BODY` sub-dicts (`_readers.py:245-249`,
`_writers.py:140-144`) to pick `ContentLengthReader/Writer`, `ChunkedReader/Writer`, or
`Http10Reader/Writer`. Order of the four steps, verbatim from the code's own step comments:

1. **Step 1 — some responses always have an empty body regardless of headers**
   (`_connection.py:112-124`): status `204` or `304`, or `request_method == "HEAD"`, or (`CONNECT`
   **and** `2xx`) all force `("content-length", (0,))`. `InformationalResponse` (all 1xx) can never
   even reach this function — it's asserted at entry (`_connection.py:100`, `assert type(event) in
   (Request, Response)`) and the code comment notes 1xx bodies are excluded by construction, not by
   this check (`_connection.py:121-124`).
2. **Step 2 — Transfer-Encoding beats Content-Length** (`_connection.py:126-130`):
   ```python
   transfer_encodings = get_comma_header(event.headers, b"transfer-encoding")
   if transfer_encodings:
       assert transfer_encodings == [b"chunked"]
       return ("chunked", ())
   ```
   The `assert` is safe because `normalize_and_validate` (§ below) has already rejected any
   Transfer-Encoding value other than exactly `chunked` before this code ever runs.
3. **Step 3 — Content-Length** (`_connection.py:132-135`): parses the (already-deduplicated,
   already-validated) single Content-Length value into an int.
4. **Step 4 — no applicable header** (`_connection.py:137-141`): for a **request**, default is
   `("content-length", (0,))` (no body); for a **response**, default is `("http/1.0", ())` — i.e.
   close-delimited/unknown-length body, the fallback framing used when neither header is present.

**Duplicate/conflicting headers are rejected before `_body_framing` ever runs**, in
`normalize_and_validate` (`_headers.py:152-206`), which every `Headers` object is built through:
- **Content-Length**: all values for the header name are collected into a Python `set` after
  stripping whitespace (`_headers.py:172-176`); if that set has more than one distinct member,
  `LocalProtocolError("conflicting Content-Length headers")` (default 400) is raised. Note the
  precise nuance: **duplicate Content-Length headers with the *identical* value are silently
  accepted and collapsed to one** (`{length.strip() for length in value.split(b",")}` dedupes both
  within one header line's comma-list and across separate header instances since they're appended
  progressively — `elif seen_content_length != value: raise ...`, `_headers.py:183-184`) — only a
  *conflict* is an error, not mere repetition. Each value is also validated against
  `_content_length_re = re.compile(rb"[0-9]+")` (`_headers.py:72`) and the 20-digit cap (§4).
- **Transfer-Encoding**: a second `Transfer-Encoding` header of any kind is rejected outright —
  `if saw_transfer_encoding: raise LocalProtocolError("multiple Transfer-Encoding headers",
  error_status_hint=501)` (`_headers.py:190-193`) — and any value other than (case-insensitively)
  `chunked` is rejected the same way (`_headers.py:196-201`, citing RFC 7230 §3.3.1: "A server that
  receives a request message with a transfer coding it does not understand SHOULD respond with 501
  (Not Implemented)"). Both are **501**, not 400 — the only header-level use of a non-default status
  hint in the codebase.

**HEAD responses**: framing forces `content-length: 0` (Step 1), but the *headers themselves* must
still look exactly like what a `GET` response would have sent — h11 enforces this actively on the
send path via `_clean_up_response_headers_for_sending` (`_connection.py:602-659`):
```python
method_for_choosing_headers = cast(bytes, self._request_method)
if method_for_choosing_headers == b"HEAD":
    method_for_choosing_headers = b"GET"
framing_type, _ = _body_framing(method_for_choosing_headers, response)
```
i.e. it recomputes framing *as if* the request had been GET purely to decide whether to add
`Transfer-Encoding: chunked` / strip `Content-Length` on the header line, per RFC 7231 §4.3.2 (cited
in the comment, `_connection.py:608-614`) — the actual `SEND_BODY` writer for the real (HEAD)
request still uses the true `content-length: 0` framing so no body bytes are ever written. This
exact "used to give different headers for HEAD and GET" regression is what
`test_HEAD_framing_headers` (`tests/test_connection.py:1050-...`) guards.

---

## 8. Error taxonomy and status-code mapping

Two concrete exception classes, both under abstract `ProtocolError` (`_util.py:12-45`,
`_util.py:59-81`):
- **`LocalProtocolError`** — *you* (the embedder) are about to do something illegal, raised
  synchronously out of event constructors (`Request(...)`, etc.) or `Connection.send(...)`
  /`send_with_data_passthrough(...)`.
- **`RemoteProtocolError`** — the *peer* did something illegal, raised only out of
  `Connection.next_event()`.

Every `ProtocolError` carries `error_status_hint: int = 400` (`_util.py:41`, default) — "a
suggestion as to what status code a server might use if this error occurred as part of a request"
(`_util.py:23-37` docstring). **h11 never sends this response itself** — it is purely advisory data
attached to the exception; the embedder decides whether/how to use it. Concretely: `400` is the
default for essentially everything (illegal request/status line, illegal header line, bad chunk
framing, conflicting Content-Length, illegal method/target characters, missing/duplicate `Host:`
header on an HTTP/1.1 request (`_events.py:107-119`), "no request line received", "illegal chunk
header", etc.) — I did not find any occurrence of `413`, `408`, or `505` being *produced by h11
itself* anywhere in the source (confirmed by `rg -n "error_status_hint" *.py`, only three call
sites total, listed exhaustively in §4/§7): **431** for the incomplete-event buffer cap
(`_connection.py:489`) and **501** for both Transfer-Encoding problems (`_headers.py:192,200`).
`408` only ever appears in a *test* as a status code the embedder chooses to send spontaneously
(`tests/test_connection.py:990-994`) — h11 supplies the state-machine legality (`SERVER: IDLE ->
Response -> SEND_BODY` works even with no prior `Request`, `_state.py:208-210`) but not the
decision or the timer. **413 and 505 are not modeled by h11 at all** — a body too large, or an
HTTP version h11 doesn't understand well enough (h11 speaks/generates only 1.1 on send,
`_writers.py:37-38`,`47-48`, but can *receive* arbitrary version strings), are entirely the
embedder's own policy to detect and translate into a response.

**Local-error handling protocol.** `_process_error(role)` (`_connection.py:255-258`) sets
`self._cstate.states[role] = ERROR` unconditionally and re-fires state-triggered transitions.
- A failed `send()`/`send_with_data_passthrough()` sets **`our_state = ERROR`** immediately
  (`_connection.py:552-575`, the `except:` wraps the whole body and calls `self._process_error(self.our_role)`
  before re-raising) — and per `docs/api.rst:491-500`, this is **unrecoverable**: all further
  `send()` calls also raise `LocalProtocolError`, "The only thing you can reasonably [do] at this
  point is to close your socket and make a new connection."
- A failed `next_event()` sets **`their_state = ERROR`** (`_connection.py:478-501`): if
  `their_state` is already `ERROR`, raise immediately without even trying to parse
  (`_connection.py:478-479`); otherwise wrap parsing in try/except, on any `BaseException` call
  `self._process_error(self.their_role)`, and if the caught exception was a `LocalProtocolError`
  (raised internally by a reader), **re-raise it as `RemoteProtocolError`** via
  `exc._reraise_as_remote_protocol_error()` (`_connection.py:496-501`, mechanism in
  `_util.py:59-77` — an in-place `__class__` rebind plus explicit re-raise, because Python tracks
  exception *type* separately from the object). This is the documented "internally we always raise
  LocalProtocolError, and then receive_data translates it into RemoteProtocolError" strategy
  (`_util.py:48-58` comment). Crucially, **`their_state is ERROR` does not force `our_state` to
  `ERROR`** — `test_errors` proves the server can still call `c.send(Response(status_code=400,
  headers=[]))` producing literally `b"HTTP/1.1 400 \r\nConnection: close\r\n\r\n"`
  (`tests/test_connection.py:919-923`) *after* the peer's state has gone to `ERROR` — this is the
  documented escape hatch (`docs/api.rst:485-488`): "`Connection.send` still works as normal, so if
  you're implementing a server and this happens then you have an opportunity to send back a 400 Bad
  Request response."
- `send_failed()` (`_connection.py:577-585`) is the caller-initiated version of the same thing: "I
  told you I'd send those bytes but the socket write actually failed," used e.g. when a pooled
  connection's in-flight write gets cancelled — forces `our_state = ERROR` so the connection can
  never be mistakenly considered clean/reusable (`docs/api.rst:509-528`). It's idempotent
  (`test_errors`, `tests/test_connection.py:965-973`).

**Is the connection closed on error?** h11 never closes a socket itself (it has none). What it
does is make the `Connection` object permanently unusable for further traffic in the failed
direction (`ERROR` has no outgoing transitions in either the client or server `EVENT_TRIGGERED_TRANSITIONS`
table, `_state.py:196-227`, both rows are `{}`). The embedder's job, once in `ERROR`, is to send
whatever diagnostic response is still possible (peer errors only) and then actually close the
socket — h11 gives you the legality check for "can I still speak" but not the socket call.

---

## 9. Close / shutdown protocol (lingering close, FIN handling, half-close)

Everything here is in `docs/api.rst:842-952` ("Closing connections") plus the state machinery in
`_state.py` and the `receive_data`/`send` handling of `ConnectionClosed` in `_connection.py`.

- **`ConnectionClosed` is a first-class event**, both sendable and receivable
  (`_events.py:357-369`, no fields). Sending it: `send()`/`send_with_data_passthrough()` special-cases
  `type(event) is ConnectionClosed` to just update the state machine and return `None`
  (`_connection.py:564-565`) — no bytes are produced (there's nothing to write for a close). Receiving
  it: triggered by `receive_data(b"")` (`_connection.py:403-408`, the "empty bytes = EOF" convention
  matching `socket.recv()`/`file.read()`), which is safe to call repeatedly (`_connection.py:399-400`
  docstring) and, once EOF-buffer-closed, feeds `ConnectionClosed()` out of
  `_extract_next_receive_event` once the reader itself returns `None` with nothing left to parse
  (`_connection.py:424-433`) — with a documented special case for HTTP/1.0 bodies: EOF is itself
  the framing signal, so `Http10Reader.read_eof()` returns an actual `EndOfMessage()` event first
  (`_readers.py:220-221`) and only the *next* call yields `ConnectionClosed()`
  (`_connection.py:428-431` comment explains this two-step precisely).
- **Half-duplex model, stated explicitly** (`docs/api.rst:868-884`): "TCP sockets pretend to be a
  two-way connection, but really they're two one-way connections... a client could send a request,
  and then close their socket for writing... and then read the response." `ConnectionClosed`
  means "this party will not be sending any more data — nothing more, nothing less"; it never by
  itself halts the whole connection. This is exactly why `test_pipelined_close`
  (§2 above) can keep sending responses after the client's `ConnectionClosed` — client `CLOSED`
  and server `SEND_RESPONSE` coexist validly (`_state.py`'s tables have no rule forcing the server
  out of `SEND_RESPONSE` just because the client reached `CLOSED`; only `(CLOSED, DONE) ->
  {SERVER: MUST_CLOSE}` and `(CLOSED, IDLE) -> {SERVER: MUST_CLOSE}` are state-triggered,
  `_state.py:240-241` — i.e. the server is only forced to close *after* it too finishes its current
  response).
- **Clean vs. unclean close distinguished structurally**: `EVENT_TRIGGERED_TRANSITIONS` only
  permits `ConnectionClosed` from `IDLE`, `DONE`, `MUST_CLOSE`, `CLOSED` for each role
  (`_state.py:198-226`) — i.e. mid-body closes (`SEND_BODY`, `SEND_RESPONSE`) have no legal
  `ConnectionClosed` transition at all. A close received while a `ContentLengthReader` or
  `ChunkedReader` is mid-body instead hits their `read_eof()` methods
  (`_readers.py:136-142`, `206-210`), both of which unconditionally
  `raise RemoteProtocolError("peer closed connection without sending complete message body ...")`
  — this is the "half sent, then died" unclean-close detection
  (`docs/api.rst:893-899`: "if one party suddenly closes the connection while they're in the middle
  of sending a chunked response body, or when they promised a Content-Length of 1000 bytes but have
  only sent 500, then h11 knows this is a violation... and will raise a ProtocolError"). Covered by
  `test_special_exceptions_for_lost_connection_in_message_body`
  (`tests/test_connection.py:1092-...`) and `test_connection_drop`
  (`tests/test_connection.py:981-986`, a bare `GET /` followed by EOF mid-request-line).
- **Server-side lingering-close guidance is quoted (not implemented) from RFC 7230 §6.6**
  (`docs/api.rst:930-951`): h11's own docs reproduce the standard's warning that an abrupt full
  close can race a TCP RST against the client's unread response bytes, and recommend the classic
  two-stage close (half-close the write side first, keep reading until the client's own close is
  observed or the response is believed ACKed, *then* fully close) — but this is advisory prose in
  the docs, not code: **h11 has no `shutdown()`/lingering-close implementation**, because it has no
  sockets. It only tracks `our_state is MUST_CLOSE` as the signal that "you (the embedder) now need
  to go implement RFC 7230 §6.6-style lingering close yourself."
- **Documented step-by-step protocols** for the two roles (`docs/api.rst:901-928`):
  - *Client* doing a single request then closing: send `Request` with `Connection: close`; send
    rest of body; read the full `Response`+body; then `our_state is MUST_CLOSE` is guaranteed true,
    call `send(ConnectionClosed())` (a legality no-op — "between you and your conscience," the docs
    say) and close the socket.
  - *Server*: send `Response`+body; then check `our_state is MUST_CLOSE` — true "for a variety of
    reasons," the canonical one being an HTTP/1.0 client and an unknown-length response body (the
    `need_close` path in §1/§7).

---

## 10. Application handler API shape

**h11 deliberately has no handler/dispatch API of its own** — there is no `Handler`, `App`,
`Router`, or request/response callback signature anywhere in the library. `__init__.py:1-7`'s
module comment is explicit about the intended layering: "loosely modelled on hyper-h2's generic
implementation of HTTP/2... it doesn't implement all the semantics to check that what you're asking
to write to the wire is sensible, but at least it gets you out of dealing with the wire itself." The
entire public surface (re-exported in `__init__.py:9-33`) is: the `Connection` class, six event
classes (`Request`, `InformationalResponse`, `Response`, `Data`, `EndOfMessage`, `ConnectionClosed`),
ten state sentinels, two exception classes, and the two flow-control sentinels `NEED_DATA`/`PAUSED`.

The "handler API" the docs actually demonstrate (`docs/api.rst:790-836`, reproduced structurally
above in §3) is a **worked example built on top of h11**, in an application's own code, not
something h11 provides: an `asyncio.Protocol` subclass with a `_deliver_events()` loop that calls
`self.conn.next_event()` in a loop, dispatches on `type(event)` via a single `event_received(self,
event)` method the app implements, and does its own transport pause/resume for backpressure. The
`docs/api.rst:382-389` "sentinel-type-trickiness" section explicitly recommends the dispatch
mechanism: `type(event)` is always meaningful (events are instances of themselves' concrete class,
and even `NEED_DATA`/`PAUSED` satisfy `type(x) is x`), so an app can use a handler table, a
`functools.singledispatch`, or `getattr(app, "handle_" + type(event).__name__)`.

**Consequence for us**: h11's "handler API shape" is *the event/state vocabulary itself* — a
five-event push/pull protocol plus a role-relative state machine — not a callback interface. The
actual glue between "bytes in, bytes out" and "call into user code" is left 100% to the embedding
server (e.g. hyper's own `h2`/`httpcore`/etc. build very different handler APIs on top of the same
h11 core). This validates a similar split for chez-http-server: the connection-semantics core
(state machine + framing decisions) should expose an event stream, and a separate, thin imperative
shell decides how those events get turned into calls into route-handler Scheme code.

---

## 11. What h11's own test suite covers (files to mirror the intent of, not the code)

All under `h11/tests/` (`https://api.github.com/repos/python-hyper/h11/contents/h11/tests?ref=master`);
local mirrors of the ones read in depth are under `h11-src/tests/`.

- **`test_connection.py`** (1120 lines) — the load-bearing file for exactly the semantics this
  report is about. Representative `def test_*` names pulled directly
  (`rg -n "^def test_" tests/test_connection.py`): `test__keep_alive`, `test__body_framing`,
  `test_Connection_basics_and_content_length`, `test_chunked`, `test_chunk_boundaries`,
  `test_client_talking_to_http10_server`, `test_server_talking_to_http10_client`,
  `test_automatic_transfer_encoding_in_response`, `test_automagic_connection_close_handling`,
  `test_100_continue`, `test_max_incomplete_event_size_countermeasure`, `test_reuse_simple`,
  `test_pipelining`, `test_protocol_switch`, `test_close_simple`, `test_close_different_states`,
  `test_pipelined_close`, `test_sendfile`, `test_errors`, `test_idle_receive_nothing`,
  `test_connection_drop`, `test_408_request_timeout`, `test_empty_request`, `test_empty_response`,
  `test_early_detection_of_invalid_request`/`_response` (parametrized on `b"\x00"`, `b"\x20"`, and a
  raw TLS ClientHello/ServerHello prefix — i.e. **explicitly testing that h11 fails fast on a plain
  HTTP port that's actually receiving TLS bytes**, not just on well-formed-but-wrong text),
  `test_HEAD_framing_headers`, `test_special_exceptions_for_lost_connection_in_message_body`. This
  file uses a `ConnectionPair` test helper (imported from `helpers.py`, not separately fetched) that
  drives a client `Connection` and a server `Connection` side-by-side and cross-feeds their output
  bytes — i.e. it is a **paired differential/round-trip test harness**, not just unit tests against
  one side. That harness shape (drive both roles of the same conversation through the same state
  machine implementation and assert they agree) is directly reusable for chez-http-server.
- **`test_state.py`** (271 lines) — pure `ConnectionState` unit tests, independent of any bytes:
  `test_ConnectionState`, `test_ConnectionState_keep_alive`,
  `test_ConnectionState_keep_alive_in_DONE`, `test_ConnectionState_switch_denied`,
  `test_ConnectionState_protocol_switch_accepted`, `test_ConnectionState_double_protocol_switch`,
  `test_ConnectionState_inconsistent_protocol_switch`,
  `test_ConnectionState_keepalive_protocol_switch_interaction`, `test_ConnectionState_reuse`,
  `test_server_request_is_illegal` — i.e. the state machine has its own test file completely
  decoupled from parsing/writing, exercising the table-driven transitions directly by calling
  `process_event`/`process_error`/`process_keep_alive_disabled`/`process_client_switch_proposal`.
  This separation (pure FSM tests vs. byte-level tests) is a pattern worth copying for
  chez-http-server's own connection-state module.
- **`test_io.py`** (583 lines) — reader/writer unit tests independent of the `Connection`/state
  machine: `test_writers_simple`, `test_readers_simple`, `test_writers_unusual`,
  `test_readers_unusual`, `test__obsolete_line_fold_bytes` (obs-fold header continuation lines),
  `test_ContentLengthReader`, `test_Http10Reader`, `test_ChunkedReader`, `test_ContentLengthWriter`,
  `test_ChunkedWriter`, `test_Http10Writer`, `test_reject_garbage_after_request_line`,
  `test_reject_garbage_after_response_line`, `test_reject_garbage_in_header_line`,
  `test_reject_non_vchar_in_path`, `test_allow_some_garbage_in_cookies` (deliberate leniency for a
  known-broken-in-the-wild header), `test_host_comes_first` (RFC 7230's SHOULD that `Host:` be
  serialized first — `write_headers`, `_writers.py:22-33`, actively reorders for this).
- **`test_headers.py`** (159 lines) — `test_normalize_and_validate`, `test_get_set_comma_header`,
  `test_has_100_continue`.
- **`test_events.py`** (148 lines) — event constructor validation/normalization (not deep-read, but
  named consistently with the constructor logic seen in `_events.py`).
- **`test_receivebuffer.py`** — buffer-internals tests (not deep-read).
- **`test_against_stdlib_http.py`** (115 lines) — a genuine **live differential test**: spins up a
  real `socketserver.TCPServer` wrapping Python's stdlib `http.server.SimpleHTTPRequestHandler`
  (serving a real file, `test_file_path`, read once at import time), and drives it via h11-as-client
  through a real OS socket and `urlopen`-style round trip (`test_h11_as_client`, first def at
  `tests/test_against_stdlib_http.py:34`) — i.e. h11 validates itself against a second, independent
  HTTP/1.1 implementation over the real network stack, not just against its own fixtures. This is
  directly analogous to what our repo already does for the parser layer (chez-httparse's
  differential against llhttp's 274 fixtures) — h11 does the same kind of thing one layer up, for
  the *connection* semantics, against Python's own stdlib server. **We don't yet have an equivalent
  for chez-http-server's connection layer**; this is a concrete gap to plan for.

---

## 12. Concrete lessons for chez-http-server

1. **Model the state machine as h11 does: two role-local automata (client/server) plus small
   orthogonal flags (keep-alive, 100-continue, pending-switch), joined by explicit *event-triggered*
   and *state-triggered* transition tables** (`_state.py:196-246`), not as one big ad hoc automaton.
   The event-triggered table is the "what can happen when I do X" rules; the state-triggered table
   is the "when these two roles' states line up like *this*, force a transition" rules
   (keep-alive-disabled -> `MUST_CLOSE`; peer `CLOSED` -> force our own eventual `MUST_CLOSE`;
   switch-accepted on the far side -> carry the near side along). This separation made every rule in
   this report traceable to one or two lines of code, which is exactly the auditability a Scheme
   R6RS core module wants (`chez-http-server`'s own house rule: "prefer a check to a comment").
   Chez-httparse and byte-machine already track per-message parser state (`llhttp` integer flags,
   `F-CONNECTION-KEEP-ALIVE` etc.) — h11's contribution above that is the **connection-lifetime**
   state (spanning possibly many pipelined messages), which chez-http-server does not yet have
   anywhere; h11's `_state.py` is close to a direct blueprint for it.

2. **Keep-alive rule to copy almost verbatim** (`_connection.py:72-90`): HTTP/1.0 peer -> always
   close; `Connection: close` from either side -> close, latched one-way, never reversible
   (`_state.py:57-60`); otherwise HTTP/1.1 defaults to keep-alive. Given our own measured fact that
   chez-httparse errors (`'error` status) on any byte fed after a close-marked message
   (llhttp's "data-after-close" behavior, per the task's PROJECT CONTEXT), our connection layer
   **must** implement this same latch and use it to decide whether to call `parser-feed!` again at
   all after a message completes — mirroring h11's `keep_alive: True -> False` flag driving
   `DONE -> MUST_CLOSE`, i.e. after a `Connection: close` (or HTTP/1.0) message completes, stop
   feeding the parser and go straight to the close/shutdown protocol instead of expecting
   `'need-input` again.

3. **Pipelining needs no queue, only a pause flag.** h11's server-side pipelining support is
   entirely: "if the peer state just reached DONE and there is unconsumed input left in the receive
   buffer, stop parsing and return PAUSED" (`_connection.py:418-419`). Response ordering is FIFO by
   construction because request N+1 is literally never parsed into an event until the app finishes
   and reuses the cycle for request N. This is directly implementable over
   chez-httparse's `parser-feed!` `consumed` byte count (which the parser already reports, per the
   PROJECT CONTEXT, precisely so a caller can find pipelining boundaries): feed one message's worth,
   stop, wait for the response to be fully written, reset, feed the remainder. We do not need (and
   should not build) a response-reordering buffer — h11's evidence is that a correct design never
   needs one.

4. **h11 treats flow control as entirely the embedder's job; it only ever gives you `PAUSED`,
   `NEED_DATA`, and (for sends) nothing at all** (`docs/api.rst:677-839`). Given chez-libuv's own
   posture — 64 KiB foreign read buffer per connection, no bounded write queue, consumer must poll
   `uv-stream-write-queue-size`, `uv-read-stop!`/`uv-read-start!` as the only backpressure verbs —
   our connection layer should adopt exactly h11's split: the **parser/state-machine core stays a
   pure function of bytes-in/events-out and events-in/bytes-out with zero I/O awareness**, and the
   **imperative shell** (which already has to own `uv-read-stop!`/`start!` per ADR-0007/0018) is
   where "pause reading because the app hasn't drained the last `Data` event yet" and "stop
   producing more response `Data` because `uv-stream-write-queue-size` is climbing" both live. This
   maps h11's `PAUSED`-driven `transport.pause_reading()`/`resume_reading()` pattern
   (`docs/api.rst:782-831`) directly onto `uv-read-stop!`/`uv-read-start!`.

5. **Only one real limit belongs in the parser/connection core: a cap on unparsed head-of-message
   buffering (h11: 16 KiB, `_connection.py:69`), mapped to 431.** Body size limits, 413, timeouts,
   and 408/505 are all explicitly *not* h11's problem — they're the embedder's, layered on top with
   its own clock/limits. Chez-http-server should follow this division exactly: a
   `max-incomplete-event-size`-equivalent check belongs next to whatever calls
   `parser-feed!`/buffers pre-parse bytes (probably keyed off `chez-httparse`'s own head-completion
   signal), but **all timeouts (idle, header, body, keep-alive-idle) must live in the imperative
   shell using `make-uv-timer`**, since chez-libuv already models timers as handles and h11 gives no
   evidence any of this belongs in a parser/state-machine core. Concretely we should define, in the
   imperative shell design doc, explicit named timeouts (header-read timeout, body-read timeout,
   idle-keep-alive timeout, drain/lingering-close timeout) with our own chosen defaults — h11
   supplies *none* of these numbers, so we cannot "copy" them from h11; we can only copy the
   *architectural fact* that a sans-I/O core should not own them.

6. **Expect: 100-continue is a single boolean outside the formal state machine, cleared on any
   response or on the client proceeding anyway** (`_connection.py:202-204, 311-316`). This is cheap
   to add to a Scheme connection record and should be — copy the three-clause clearing rule exactly
   (informational/full response sent; client sends Data anyway) so we don't accidentally deadlock a
   handler that's waiting to decide whether to send `100 Continue` against a client that already
   started streaming.

7. **CONNECT/Upgrade: model both as a `pending-switch-proposals` set on the request side, resolved
   by response status code alone (101 for Upgrade, 2xx for CONNECT), with a "switch wins the DONE
   race against MUST_CLOSE" priority rule** (`_state.py:87-90, 334-345`). After acceptance, hand the
   remaining unparsed receive-buffer bytes back to the caller (h11's `trailing_data`,
   `_connection.py:353-362`) and stop touching the connection with the HTTP layer at all — this maps
   directly onto our own libuv layer's `uv-read-stop!` plus reusing the already-copied bytevector
   span the connection layer was holding, handed off to whatever protocol upgrade target owns the
   handle next. Both `CONNECT` and `Upgrade` should share one proposal/acceptance code path in our
   design, exactly as h11 shares `_server_switch_event`.

8. **Framing precedence to copy exactly, including the "quiet" pieces**: T-E beats C-L
   (`_connection.py:126-135`); 204/304/HEAD/CONNECT-2xx force empty body regardless of headers
   (`_connection.py:112-124`); no header on a *request* means no body, no header on a *response*
   means close-delimited (`_connection.py:137-141`); a **second, distinct** Content-Length value is
   an error but a **repeated identical** one is not (`_headers.py:172-184`) — this is an easy detail
   to get subtly wrong and worth a dedicated unit test in chez-http-server modeled directly on it;
   more than one Transfer-Encoding header, or any Transfer-Encoding value other than `chunked`, maps
   to 501 specifically, not 400 (`_headers.py:190-201`) — our error-mapping table needs this as a
   distinct case, not folded into a generic "bad request" bucket. HEAD responses must be framed as
   if for GET when deciding headers, while the real body writer still emits zero bytes
   (`_connection.py:602-618`) — two different "what would the method have been" computations
   happening at once, which is worth a named helper in our own code exactly because it's easy to
   conflate.

9. **Error status-code mapping should be a hint carried on the condition object, not baked into a
   response-sending function.** h11's `error_status_hint` (`_util.py:23-45`) is pure data attached
   to the exception; the *decision* to actually write `HTTP/1.1 400 ...\r\nConnection: close\r\n\r\n`
   to the wire, and the decision to close afterward, are made by the caller, after the fact, using
   whatever's still legal (`test_errors`, `tests/test_connection.py:904-923`, shows a server sending
   a 400 *after* the peer's state is already `ERROR` — because only `their_state`, not `our_state`,
   went to `ERROR`). Chez-http-server's parser/connection-layer conditions (already flowing through
   R6RS `raise`/`guard`, and per the PROJECT CONTEXT, through `&uv-callback-error` on the libuv
   trampoline boundary) should likewise carry a suggested status code as a field, leaving "write the
   response, then close" as an explicit, separate, later action taken by the imperative shell — not
   something the condition-raising code does for you. Also worth copying precisely: h11's `their_state
   is ERROR` does **not** force `our_state is ERROR` (`_state.py:196-227` — the `ERROR` row for each
   role is independent), which is exactly what lets a server answer a malformed request with a real
   400. Any design where "peer sent garbage" automatically forecloses "we can still speak" would be
   a regression relative to this reference.

10. **Half-duplex close semantics are load-bearing, not an edge case**: a server must be able to
    keep sending already-in-flight pipelined responses after the client has closed its write side
    (`test_pipelined_close`, §2/§9 above), and `ConnectionClosed` must only close the *direction* it
    was received/sent on, not the whole logical connection, until both sides are done
    (`docs/api.rst:868-884`). Chez-libuv's `uv-close!` is a single whole-handle close (no
    half-close/`shutdown()` primitive is mentioned as bound in the PROJECT CONTEXT's "NOT bound"
    list, and no `uv_shutdown` binding was mentioned as available) — **this is a concrete gap to
    flag in the architecture doc**: if chez-libuv has no `uv_shutdown`-equivalent for a TCP
    half-close, chez-http-server cannot literally implement h11's/RFC 7230 §6.6's two-stage
    lingering close (half-close write, keep draining reads, then close), and the design will need
    either (a) a documented deviation (full close once the response is believed flushed, accepting
    the TCP RST risk RFC 7230 §6.6 warns about), or (b) a call to extend chez-libuv with
    `uv_shutdown` bindings before this can be done properly. This should be raised explicitly as an
    open architecture question, not silently decided either way.

11. **No built-in handler/dispatch API is itself a lesson**: h11 stops at "events in, events out";
    routing, request/response object lifecycle, and body-streaming ergonomics for application code
    are all left to a layer above it (`__init__.py:1-7`, `docs/api.rst:790-836`). Chez-http-server's
    architecture doc should draw the same line: the connection-semantics module (the thing this
    report is about) should expose something isomorphic to h11's event stream — new-request /
    header-data / body-data / message-complete / connection-closed, plus the send-side mirror — and
    a **separate** module should own turning that into whatever handler-procedure calling
    convention chez-http-server chooses. Conflating the two (as an easy-to-reach-for first draft
    might) is exactly what h11 avoided, and its test suite (`test_state.py` fully decoupled from
    `test_io.py`, both decoupled from the live differential in `test_against_stdlib_http.py`) shows
    the payoff: each layer is independently, cheaply testable.

12. **Test-suite shape to imitate**: (a) a pure-FSM test file exercising `ConnectionState`-equivalent
    transitions with no bytes involved at all (`test_state.py`); (b) a pure reader/writer test file
    per framing mode, independent of the state machine (`test_io.py`); (c) a paired
    client+server-connection differential harness (`ConnectionPair`, driving both roles of the same
    conversation and cross-feeding bytes) for the connection-semantics file itself
    (`test_connection.py`); and (d) a **live differential test against a second, independent HTTP
    implementation** over a real socket (`test_against_stdlib_http.py`) — which for us has an
    obvious, already-precedented analogue: run chez-http-server's connection layer against a real
    client (e.g. curl, or Python's own `http.client`/`h11`-as-client) the same way chez-httparse
    differentials against llhttp's fixtures and AGENTS.md's "a test is finished when you have
    watched it fail" TDD discipline already demand. This is presently a gap (no such harness exists
    yet in the empty target repo) worth planning for from day one rather than bolting on later.

13. **Numeric limits we can port as sane starting defaults, clearly labeled as h11's precedent, not
    a standard**: 16 KiB max buffered-but-incomplete request head (`_connection.py:59-69`); 20-digit
    cap on a Content-Length numeral (`_headers.py:15`). Everything else — actual header count caps,
    URI length caps, body size caps, all timeouts — has **no** h11 default to copy; those need their
    own design decisions grounded in our own threat model (chez-http-server is meant to be portable
    and used directly, not sitting behind a battle-tested reverse proxy the way many h11-based
    Python stacks typically are, which raises the stakes on getting these limits right ourselves).
