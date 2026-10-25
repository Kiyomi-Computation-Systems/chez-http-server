# Handlers

A handler is a procedure. The server calls it with each request and sends
back what it returns.

```scheme
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (make-response 200 #f '()
                  (string->utf8 (string-append "You asked for " (request-path request) "\n")))))
```

`serve` listens on `127.0.0.1:8080` unless `CHEZ_HTTP_HOST` and
`CHEZ_HTTP_PORT` say otherwise ([Configuration](configuration.md)). It runs
until the process gets `SIGTERM` or `SIGINT` (Ctrl-C), then finishes the
requests in flight and returns ([Connections](connections.md)). It writes one
line to standard output for each thing that happens, starting with
`listening 127.0.0.1 8080`.

Once `serve` has returned, Ctrl-C ends the process at once, so in a REPL it
ends Chez too.

## Reading the request

For `GET /a/b?x=1 HTTP/1.1` with `Host: example.com`:

| Call | Gives | Here |
|:--|:--|:--|
| `(request-method r)` | the method, a symbol | `GET` |
| `(request-path r)` | the path | `"/a/b"` |
| `(request-query r)` | what follows the first `?`, or `#f` with no `?` | `"x=1"` |
| `(request-header r "host")` | the first header with that name, or `#f` | `"example.com"` |
| `(request-header-values r "host")` | every header with that name, in order; `'()` with none | `("example.com")` |
| `(request-header-list r)` | every header, in order, as `(name . value)` | `(("Host" . "example.com"))` |
| `(request-host r)` | the site the request is for | `"example.com"` |
| `(request-http-major r)` | the version's first number | `1` |
| `(request-http-minor r)` | the version's second number | `1` |

- The method is one of the 36 the parser knows, in capitals: `GET`, `POST`,
  `PUT`, the WebDAV methods and the rest. Any other, such as `get` or `FOO`,
  gets `400 Bad Request` before your handler runs.
- Header names match in any case: `"content-type"` finds `Content-Type`.
  `request-header-list` gives each name as it was sent, so fold its case
  before you compare it.
- A list such as `Connection` may come on several lines. `request-header`
  reads the first; `request-header-values` reads them all, and
  `request-header-list` gives each line as its own pair.
- `request-header-list` gives every header as the client sent it, the ones
  about this connection only among them, such as `Connection` and
  `Transfer-Encoding` (RFC 9110 §7.6.1). A proxy removes those before it
  passes the rest on, and gives the body it sends its own `Content-Length`
  or `Transfer-Encoding`.
- The spaces around a header's value are not part of it.
- Nothing is decoded: `/a%20b` reads `"/a%20b"`. Decode it yourself if you
  need to ([Requests](requests.md)).
- Each byte is one character (Latin-1), so every byte reads back as it was
  sent. To read UTF-8 text, turn the string back into bytes with a Latin-1
  transcoder and decode those.
- A proxy names the site in the target itself: `GET http://example.com/a`.
  Then the path is `"/a"` and the host is `"example.com"`, whatever the
  `Host` line says (RFC 9112). An empty path, as in `GET http://example.com`,
  reads `"/"`.
- `OPTIONS *` has the path `"*"`, and `CONNECT example.com:443` the path
  `""`.
- With an empty `Host:`, or none (HTTP/1.0), the host is `""`.
- The version is the one the request names: `HTTP/1.2` reads `1` and `2`,
  though the server answers it as HTTP/1.1. The first number is always `1`:
  the server refuses any other version before your handler runs
  ([Connections](connections.md#versions)).

Each call makes its string when you ask, so a handler pays only for what it
reads.

### Keep strings, not the request

A request holds on to the bytes it arrived in, up to
`CHEZ_HTTP_READ_BUFFER_SIZE` (16 KiB). To keep something for later, keep the
strings you read, not the request: a request you keep keeps its bytes too.

## Answering

`(make-response status reason headers body)`:

- `status`: a number from 200 to 599;
- `reason`: a bytevector, such as `(string->utf8 "OK")`, or `#f` for the
  usual one;
- `headers`: a list of `(name . value)` pairs of bytevectors;
- `body`: a bytevector, `#f` for none, a producer that streams it, or a
  `sized-body` that streams it with its length
  ([Bodies and streaming](bodies.md)).

A handler can answer with three other things instead of a response:

| Answer | When | Page |
|:--|:--|:--|
| a reader, from `read-body` or `read-whole-body` | to read the request's body | [Bodies and streaming](bodies.md) |
| `(awaiting thunk)` | to wait for something before answering | [Waiting](waiting.md) |
| `(switch-protocols headers take-over)` | to take the connection for another protocol | [Upgrades](upgrades.md) |

What the server adds to your response, such as `Date` and `Content-Length`,
and what it refuses to send, is in [Responses](responses.md). If your handler
raises, the client gets `500 Internal Server Error` and the server logs
`handler-failed`.

## Keep it quick

Your handler runs on the server's event loop. While it runs, no other
connection is served. Do quick work in place: build a page, read a small
file. To wait for something, such as another request, a timer or a DNS
lookup, answer with `awaiting` ([Waiting](waiting.md)).

## When the server will not start

A malformed setting, such as `CHEZ_HTTP_PORT=http` or a `CHEZ_HTTP_HOST`
that is not an IP address, stops `serve` before it listens. It raises an
`&http-server-config-error` that names the variable;
`http-server-config-error?` checks for one.

`serve` also takes the environment as an optional second argument, a
procedure from a variable's name to its value or `#f`. A program can use it
to take settings from its command line, as
[file-server.sps](../examples/file-server.sps) does:

```scheme
(serve handler
       (lambda (name)
         (if (string=? name "CHEZ_HTTP_PORT") "8000" (getenv name))))
```

`getenv` here is Chez's, from `(chezscheme)`.
