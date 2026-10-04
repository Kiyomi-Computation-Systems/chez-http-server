# 0020: a client's close is noticed while its request is answered, and the wait its code is in raises &client-closed, once

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, in discussion: "lets do C"; by form: "Once",
"Close quietly")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14's open list
Amends: [0004](0004-pipelining-is-strictly-serial-with-read-stop-in-v1.md) item 3,
[0015](0015-a-handler-waits-with-await-and-three-verbs-of-the-servers-each-wait-one-shot-and-timed-to-the-millisecond.md)
item 4, [0002](0002-the-connection-is-a-pure-state-machine-with-an-action-interpreter.md)
item 2's vocabulary

## Context

Decision 0004 item 3 stopped reading while a handler ran. A client that left was noticed
only when the server next wrote or read, and it recorded Node's way as the alternative:
read during a handler, only to notice the client leave. M8.4 measured the speed side: never
stopping reading saved at most about 1 µs a request. The open question was the notice.

Measured 2026-10-04 on Darwin arm64 (an Apple M1), a client leaving 0.1 s into a handler's
3 s wait:

| The client | This server, before | Node 20.10 |
|---|---|---|
| closes (FIN) | its socket held until 2.94 s, closed when the handler answered | the handler told at 0.102 s |
| resets (RST) | held until 2.95 s; `read-error EPIPE` logged | the handler told at 0.107 s |
| half-closes, then reads | its 200 at 3.00 s | no answer: Node closed at 0.11 s |

A held connection costs about 20 KB and one of the 10,000 slots (docs/configuration.org),
and a waiting handler 3.6 KB more until its wait ends. A bare `await` nothing resumes held
them until the server stopped.

Read from source on 2026-10-04:
- **Go 1.25.14's server** reads in the background while a handler runs. Any read error,
  a FIN's EOF among them, cancels the request's context (`net/http/server.go`,
  `handleReadErrorLocked`: "Any error means the connection is dead").
- **Caddy v2.11.7** sends the upstream request with the client's request context
  (`reverseproxy.go`), and Go's transport closes the upstream socket when it is
  cancelled (`transport.go`, `cancelRequest` and `closeLocked`), logging 499. Go's
  transport never half-closes an HTTP/1.1 connection upstream: `CloseWrite` appears only
  in 101 tunnels. So behind Caddy, a client that leaves reaches this server as a close
  of its connection.
- **Node v22.23.3** keeps reading; with `httpAllowHalfOpen` false by default, a FIN
  ends Node's side, and a late response is buffered, not sent.
- **nginx 1.29.8**, while waiting on an upstream, peeks at the client socket; a FIN is
  "client prematurely closed connection", 499, and the upstream is closed, unless
  `proxy_ignore_client_abort`.
- **RFC 9112** §9.5: implementations SHOULD constantly monitor open connections for a
  received closure signal. §9.6: a client's half-close does not imply it is no longer
  interested in a response.

## Decision

1. **Past a request's end the connection reads, only to notice the client close.** In
   `handling` and `responding`, reading goes on, and the first delivery that arrives,
   the next request's, is held after the pause's rest and reading stops, so a client
   that pipelines is noticed no more. The held bytes are fed after the response, as the
   rest is, or handed to a switch's taker, or dropped with a close.
2. **The client's end tells the request's code.** A FIN with nothing held is the
   end of the request the client waits on: the core emits `(client-closed)`, the
   connection's 17th action, and closes once the response, if any, is written, at once,
   since the client's end, which a linger waits for, has come. A FIN with requests held
   tells no one: the client sent them and waits for their answers, which it gets, the
   connection then closing. A read error, the client's reset, tells the code too, and
   closes, as before.
3. **The wait the code is in, or else its next, raises `&client-closed`, once**
   (decided by form). The shell keeps a notice for the request, given to each coroutine
   its handler, reader or producer runs on, and closes it at `(client-closed)`. After the
   raise, waits work as before, so a handler that catches it can still finish work that
   waits. A handler that never waits is never told.
4. **A handler that lets it out is answered nothing** (decided by form): no 500 and no
   `handler-failed` line, the connection closing for `client-closed`. A raise of it with
   the client still there is a failure like any other.
5. **0015 item 4 holds for every other close**: a drain's force, a deadline, the
   shell's own. Their waits go on, and what they answer is dropped.

## Consequences

- The core's vocabulary has seventeen actions, and `handling` and `responding` read.
  The state remembers the client's end; the shells keep a notice a request, dropped as
  the parser resumes for the next, so an idle connection holds none.
- A client that half-closes and waits gets the answer a handler gives; a waiting
  handler that lets the close out gives none, as Node gives none.
- Found while building: a client that pipelines and half-closes (three requests, then
  its FIN) lost its third answer under a first rule that told the last request held.
  The contract test caught it. And the contract test's fake now drains its scheduler at
  the turns the libuv shell's did (THE TURNS), since a client's end can now come in the
  turn a handler's call waits in. Its waiting scripts, which half-closed as they sent,
  were told and answered nothing, both shells agreeing on writing nothing: a script's
  client now ends its stream once answered, two end early on purpose, and a check holds
  the rest to an answer.
- Not covered: while a body is still read, reading stops when the reader falls behind
  (M6.2), so a close waits for the next read. chez-libuv cannot reset a connection, so a
  reset is held to by the core's rows and the fake, not by a socket. On Windows libuv
  may not deliver an end again once reading restarts, which the core no longer needs.
- Weighed and not taken: A, recording it as not wanted; B, noticing and closing at
  once, as Node and nginx do, the handler running on; "every wait after" the close
  raising, like a passed deadline, where a catch-all retry loop would spin; and
  treating an uncaught raise as a failure, a 500 and a log line each time a client
  leaves.
- The mutants are in `.superpowers/sdd/m8-mutations.md` ("After M8").
