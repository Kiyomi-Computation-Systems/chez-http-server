# Connections

What happens on a connection from its first byte to its close: how requests
take turns, which versions are served, what a slow client gets, and how the
server shuts down.

## One request at a time

A client can send many requests over one connection. The server answers them
in order, one at a time:

1. It reads a request.
2. While your handler runs, it reads only to notice the client leave. If the
   next request arrives meanwhile, it keeps it for later and stops reading.
3. It writes your response.
4. It reads on, starting with any bytes the client already sent.

A client may send several requests without waiting for the answers
(pipelining). They are still answered one at a time, in the order they were
sent.

If the client closes the connection while your handler runs, a handler that
waits is told ([Waiting](waiting.md)). A client that sent more requests
before closing still gets every answer, and then the connection closes.

After a request that asks to close the connection (`Connection: close`, or
HTTP/1.0 without `Connection: keep-alive`), the server writes its response
and closes. Anything the client sent after that request is ignored.

## Versions

- **HTTP/1.1 and HTTP/1.0** are served. An HTTP/1.0 request that uses
  `Transfer-Encoding` gets `400 Bad Request`, and the connection closes:
  HTTP/1.0 has no `Transfer-Encoding`, so where such a body ends cannot be
  trusted.
- **A later 1.x**, such as `HTTP/1.2`, is served as HTTP/1.1. Your handler
  still reads the version the client sent: `request-http-minor` gives `2`.
- **HTTP/2's opening line** (`PRI * HTTP/2.0`) gets `505 HTTP Version Not
  Supported`, and so does any version that is not 1.x: HTTP/0.9 (a request
  line with no version, such as `GET /`), `HTTP/2.0` or `HTTP/3.0`. The
  connection closes after.
- **A version the server cannot read at all**, such as `HTTP/1.x`, gets
  `400 Bad Request`.

For HTTP/2 and HTTP/3, run a proxy in front ([Deploying](deploying.md)).

## Switching protocols

A request can ask to switch the connection to another protocol: a WebSocket
handshake (`Connection: upgrade` with `Upgrade: websocket`), `Upgrade: h2c`,
or a proxy's `CONNECT host:port`. Your handler can take an HTTP/1.1 upgrade
with no body and speak the new protocol itself ([Upgrades](upgrades.md)).
Otherwise the server answers such a request like any other, and then closes
the connection. Anything the client sent after that request is ignored.

## Clients that stall

The server stops waiting for a client that stalls:

- a kept-alive connection with no new request for `CHEZ_HTTP_IDLE_TIMEOUT`
  (75 s) is closed;
- a request whose headers take longer than `CHEZ_HTTP_READ_HEADER_TIMEOUT`,
  or whose body pauses longer than `CHEZ_HTTP_BODY_INACTIVITY_TIMEOUT` (60 s
  each), gets `408 Request Timeout`, and the connection closes;
- a client that stops reading is closed once a write has waited
  `CHEZ_HTTP_WRITE_TIMEOUT` (60 s), with no answer: nothing more can be
  written to it.

A client that sends `Expect: 100-continue` waits for `100 Continue` before
it sends its body. The server sends it when your handler starts reading the
body ([Bodies and streaming](bodies.md)), and the body timeout starts then.

## How the server closes a connection

When the server closes a connection after a response, it closes it gently:

1. It tells the client it has finished writing.
2. It keeps reading, and throws away whatever the client still sends.
3. It closes once the client closes too, or once `CHEZ_HTTP_LINGER_TIMEOUT`
   (30 s) has passed.

Closing at once while the client is still sending makes the operating system
reset the connection. A client still uploading would then see an error
instead of the answer, and the end of a long response could be lost.

A connection handed to a taker (a WebSocket, say) closes the same way when
the taker calls `transport-close!`, so the client reads the taker's goodbye.
From that call on, a write it waits for has `CHEZ_HTTP_WRITE_TIMEOUT` too.

## When the server shuts down

Send the process `SIGTERM` (what Docker, Kubernetes and systemd send) or
`SIGINT` (Ctrl-C), and the server *drains*:

1. It stops accepting connections.
2. It closes idle keep-alive connections at once. A client opens a new one
   when it next needs it.
3. It finishes each request in flight. Its response says
   `Connection: close`, if it has not started yet, and the connection then
   closes gently, as above.
4. It tells each connection a handler took over (an upgrade) to finish,
   through the taker's drain call, and waits for it to close.
5. After `CHEZ_HTTP_DRAIN_TIMEOUT` (10 s) it closes whatever is still open,
   at once.
6. Once no connection is left, `serve` returns.

It logs `draining` with the connections it waits for, `drain-timeout` if
step 5 closed any, and `stopped` at the end. A second signal changes
nothing. The server watches for both signals before it logs `listening`, so
one sent the moment that line appears drains it too. If the listener fails,
the server drains the same way, so whatever supervises it can start it
again.
