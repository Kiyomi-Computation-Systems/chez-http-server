# 0006: HTTP/1.0 is supported; an h2c preface is answered 505; upgrades hand off through one hook

Date: 2026-09-19
Status: accepted (user decision, 2026-09-19)
Plan: [the brief](../2026-09-19-chez-http-server-project-brief.md)

## Context

HTTP/1.0 clients still exist (ApacheBench speaks 1.0). Its rules differ in three places: connections close unless the client sends `Connection: keep-alive`; chunked encoding does not exist, so an unknown-length response is close-delimited; `Host` is optional. The llhttp corpus exercises 1.0 fixtures already. The HTTP/2 cleartext preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` (gRPC, `curl --http2-prior-knowledge`) and `Upgrade: h2c` both reach the embedder as a parser pause — through two channels (`paused-upgrade` via `parser-result-pause`, `paused-h2-upgrade` via `parser-result-error`; chez-httparse #34, documented in its v0.4.0 `docs/api.org` with a `result-hands-off-stream?` check that covers both). There is no HTTP/2 implementation to hand to.

## Decision

1. The keep-alive table has the 1.0 rows: `F-CONNECTION-CLOSE` → close; `F-CONNECTION-KEEP-ALIVE` → keep; else 1.1 → keep, 1.0 → close. The framing table never emits chunked to a 1.0 client: `Content-Length` when known, close-delimited with `Connection: close` otherwise.
2. An h2c preface or `Upgrade: h2c` gets `505 HTTP Version Not Supported` with `Connection: close`, then close. Both pause channels are checked.
3. One hand-off hook: when the parser pauses for an upgrade the core emits `(hand-off request unconsumed-bytes)`; the shell stops reading and gives the handler, if it opted in, the transport record plus the retained bytes (h2o's "steal the socket, hand back a byte offset" shape). v1 has no consumer of the hook except the 505 path; WebSocket and a future HTTP/2 layer attach here without touching the core.

## Consequences

- `ab` works against the server from M4.
- The hook's contract test (retained bytes are exactly `parser-result-next` onward) is written in M8 with the 505 path as its first consumer.

## Amendment (2026-09-25) — an upgrade is served, then the connection closes

Decided on the owner's word on 2026-09-25, when M2.5 settled where an upgrade meets the
connection core. Since M2.4 the core pauses the parser at every message's end
(decision 0004 item 1), so the parser's hand-off came only when the parse resumed after
the handler's answer. M2.4's core ignored it there, and the next delivery fed a paused
parser.

1. **Item 3: the core hands off only an upgrade something takes, and v1 takes none.**
   A request that asks to switch protocols reaches the handler like any other, and the
   connection closes after the response, with the close reason `upgrade`. By llhttp's
   rule that is a CONNECT, or `Connection: upgrade` with `Upgrade`. The parser is never
   resumed onto its hand-off, and the bytes after the request, which belong to another
   protocol, are never read. RFC 9110 §7.8 lets a server ignore an upgrade: "A server
   MAY ignore a received Upgrade header field if it wishes to continue using the
   current protocol on that connection."
   - The hook stays. Design §4.4's `handed-off` row is the door M8 opens for a handler
     that takes upgrades, at the message's end. Answering `continue` to
     on-message-complete brings the parser's own hand-off back in the same feed, at
     every delivery size.
   - The hook's contract test, retained bytes exactly `parser-result-next` onward, stays
     M8's, for that door. It no longer has the 505 path as its first consumer (item 2).
2. **Item 2: `Upgrade: h2c` is an upgrade like any other.** Only the HTTP/2 preface
   (`PRI * HTTP/2.0`) is answered 505, then closed. The parser hands the preface off on
   its error channel, and the core answers it itself (close reason `http2-preface`), so
   the hook has no v1 user.
   - RFC 9113 §3.1 deprecated the h2c upgrade: "This usage was never widely deployed and
     is deprecated by this document."
   - `curl --http2` sends the upgrade to an http:// URL (curl's manual). A 505 would
     answer it with an error, where a served request answers with the page over
     HTTP/1.1.

What was weighed, measured 2026-09-25 on Darwin arm64, Chez 10.4.1 `tarm64osx`, with three
prototypes of the core over the 135 strict llhttp fixtures. All three passed the outcome
lane, 135/135 at `'extremes` and at `'full`, at 2,512 B per request:
- **A: hand it off at the message's end** (item 3 as written). The handler never sees
  the request. With nothing to take it in v1, the connection closes with no response,
  as Node closes a CONNECT nobody listens for. RFC 9110 §7.8 says a server "MUST
  ignore" an `Upgrade` in an HTTP/1.0 request, and llhttp marks those too, so A would
  need a version check. 9 fixture outcomes changed, 26 core lines.
- **B: serve it, then close** (chosen). 5 fixture outcomes changed, 17 core lines. It is
  h2o's rule for an upgrade it does not take: that connection is not persistent.
- **C: serve it, and keep the connection** (Go's: no special handling). The bytes after
  the request would be read as HTTP requests. Behind a proxy that forwards them unread,
  that is a request-smuggling path. 4 fixture outcomes changed, 21 core lines.
- **For item 2: keep 505 for `Upgrade: h2c`.** The core would read the `Upgrade` value
  at the head, about 20 lines with a parser for its token list.

The parser facts are in `research/spike/upgrade-door.sps` (two identical runs):
- answered `continue`, the hand-off comes in the same feed;
- answered `pause`, it comes only after a resume and a feed, even of an empty range at
  `next`;
- llhttp's rule equals the parser's own `upgrade` field;
- the preface errors before any on-headers-complete.

## Amendment (2026-10-03) — the hook, as M8.2 opens it

Decision 0016 settled the door's shape on the owner's word, by form: a handler takes an
upgrade by answering a switch, the server writes the 101, and the stream is handed over
as a transport the server keeps. What that changes here:

1. **Item 3's hook is the switch's take-over, called once its 101 is written.** The core
   emits `(hand-off take-over retained)` at the 101's last completion, not `(hand-off
   request unconsumed-bytes)` at the parser's hand-off: the core pauses every message's
   end and never resumes the parser onto an upgrade, so that hand-off cannot come, and
   the core refuses one that did. `retained` is the core's pending input, the rest of the
   last read from `parser-result-next`, which the shell copies for the taker. "Steal the
   socket" is not what is handed over: the taker gets a transport, and the server keeps
   the stream's close, its place in `max-connections`, its deadline and the drain.
2. **The contract test landed** as `tests/test-connection-switch.sps`: at every delivery
   size, the bytes handed over, followed by what the taker reads on, are exactly the bytes
   after the request; the plan's mutation, those bytes starting a byte late, reddens it
   and the table's hand-off row (M8.2's mutation log).
3. **The amendment's item 1 stands for every upgrade not taken**: an upgrade a handler
   answers with a response is served, then closed. Only an HTTP/1.1 upgrade with no body
   can be taken (0016 item 4). Item 2 is unchanged: the HTTP/2 preface is answered 505.
