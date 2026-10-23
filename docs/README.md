# chez-http-server

An HTTP/1.1 server for [Chez Scheme](https://cisco.github.io/ChezScheme/),
built on [libuv](https://libuv.org), the event loop under Node.js.

You write a *handler*: a procedure that takes a request and returns a
response. The server does the rest. It reads requests off the network,
checks them, calls your handler, writes your answer, keeps connections
alive, closes the ones that stall, and shuts down cleanly when asked.

💡 These pages are Markdown in the repository's [docs](../docs) directory.

## A taste

```scheme
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (make-response 200 #f '()
                  (string->utf8
                   (string-append "You asked for " (request-path request) "\n")))))
```

Save it as `hello.sps`, start it with `make run PROGRAM=hello.sps`, and ask:

```text
$ curl http://127.0.0.1:8080/hello
You asked for /hello
```

Press Ctrl-C and the server finishes what it is doing, then stops.

## Five ideas to keep in mind

- **A handler is just a procedure.** Request in, response out. There are no
  routes, middleware or classes to learn: use `cond` on the path.
- **One request at a time per connection.** A connection's next request
  waits until your handler has answered this one. Other connections go on.
- **Your handler runs on the event loop.** Answer quickly. To wait for
  something (another request, a timer, a DNS lookup), answer with
  `awaiting` and the server runs your code where it may wait.
- **Nothing is decoded for you.** You get the path and headers as they
  arrived: `/a%20b` stays `/a%20b`. Bodies arrive as bytes.
- **Everything is bounded.** Every timeout and size has a safe default you
  can change with an environment variable. A client cannot make the server
  wait forever or hold unbounded memory.

## What it is not

It speaks HTTP/1.1 and 1.0 over plain TCP. For TLS (`https://`) and HTTP/2,
put it behind a proxy such as Caddy or nginx (see [Deploying](deploying.md)).
For WebSockets, use [chez-websocket](https://github.com/Kiyomi-Computation-Systems/chez-websocket),
which builds on this server's upgrades.

## Read next

- [Installing](installing.md): what you need, building, and using the server
  from your own project, from a checkout or with Akku.
- [Quickstart](quickstart.md): a first server, step by step.
- [Examples](examples.md): small servers to copy from, including a file
  server like `python3 -m http.server`.
- [Handlers](handlers.md): reading a request and answering it.
- [Bodies and streaming](bodies.md): reading uploads and streaming downloads.
- [Waiting](waiting.md): handlers that wait for events, times and lookups.
- [Upgrades](upgrades.md): taking over a connection for another protocol.
- [Requests](requests.md): which requests the server accepts, and which it
  refuses before your handler runs.
- [Responses](responses.md): what the server adds to your response, and
  what it answers by itself.
- [Connections](connections.md): keep-alive, slow clients, closing and
  shutting down.
- [Configuration](configuration.md): every setting and its default.
- [Deploying](deploying.md): running it for real, behind a proxy.
- [How it works](how-it-works.md): the design, from the event loop to your
  handler.
- [Performance](performance.md): what it costs in time and memory.
- [API reference](reference.md): every exported name, one entry each.
- [Building and testing](building.md): working on the server itself, on
  your machine, in Docker or with Guix.
