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
