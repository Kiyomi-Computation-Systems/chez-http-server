# 0001: The project is the composition layer above chez-libuv and chez-httparse, and where it stops

Date: 2026-09-19
Status: accepted
Plan: [the brief](../2026-09-19-chez-http-server-project-brief.md) "Why this is its own repository"

## Context

The architecture document planned four libraries. Two of them already exist under other names and are complete for our purposes: chez-httparse v0.2.0 passes all 274 llhttp fixtures at every chunk size; byte-machine v0.6.0 is its generator. chez-libuv v0.5.0 refuses by design to own any protocol or backpressure policy (its ADR-0018). Nothing in between exists.

## Decision

1. chez-http-server owns HTTP connection semantics and nothing below them: the connection state machine, request and response records, framing precedence, keep-alive, limits, timeouts, the libuv shell, the scheduler, graceful shutdown.
2. The four libraries are consumed as pinned checkouts (gitlink submodules at release tags, as uriparse pins byte-machine). Gaps in them are filed upstream (decision 0008) and carried as local workarounds until fixed; the server never forks a dependency.
3. It is not a framework. Routing, middleware, static files, sessions and templating are downstream projects. The handler contract is `request → response`.
4. It is not HTTP/2 and not TLS. A transport record and one upgrade hand-off hook are the only provisions made for either.
5. The architecture document's names `chez-http1` and `chez-byte-machine` mean chez-httparse and byte-machine; the document is kept as background with a status header saying so.

## Consequences

- Library layout: `(http-server limits)`, `(http-server request)`, `(http-server response)`, `(http-server decisions)` (framing precedence and error-to-status mapping only; keep-alive and needs-eof come from `(httparse decisions)` since 2026-09-19), `(http-server connection)`, `(http-server wheel)`, `(http-server server)` are pure and import no libuv; `(http-server private adapter)`, `(http-server private shell)`, `(http-server private scheduler)` are the shell; `(http-server)` is the facade.
- A `make test` gate asserts that the pure libraries import neither `(libuv ...)` nor `(chezscheme)`.

## Noted (2026-10-03)

Item 4's transport record exists since M8.2: `(http-server transport)`, a record of
verbs over a stream that a handler takes through the upgrade hook (decision 0016). The
server's shell implements it over chez-libuv, and a taker's tests make one of their own.
A TLS layer would be a transport that wraps one.
