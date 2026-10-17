# Requests

The server checks every request before your handler runs. A request it
cannot accept gets an answer from the server itself, and your handler never
sees it. This page covers the two parts it checks most closely: the
request-target and the `Host` header. Limits on sizes and times are in
[Configuration](configuration.md); versions and keep-alive in
[Connections](connections.md).

## The request-target

The request-target is the part of the request line after the method: the
`/search?q=1` in `GET /search?q=1 HTTP/1.1`.

### What gets through

| Form | Example | Used by |
|:--|:--|:--|
| origin | `/path?query` | every method but CONNECT |
| absolute | `http://example.com/path` | every method but CONNECT |
| authority | `example.com:443` | CONNECT, and only CONNECT |
| asterisk | `*` | OPTIONS, and only OPTIONS |

These are RFC 9112's four forms. Their bytes must also be valid RFC 3986.
Your handler gets the target exactly as it arrived.

### Percent-encoding is left for you

A valid percent-encoding, such as `%20` or `%00`, gets through as written.
The server does not decode it, so [your handler](handlers.md) sees `%00`, not
a NUL byte, and `%2F`, not a `/`. Decode it yourself, and decide there
whether a decoded NUL or slash is one your route allows.
[file-server.sps](../examples/file-server.sps) shows one way. Only a
malformed percent-encoding, such as `%zz`, is refused.

### What gets 400

- a byte RFC 3986 does not allow unencoded, such as `"`, `<`, `{` or `^`;
- a malformed percent-encoding, such as `%zz`;
- a fragment (`#section`), which browsers never send;
- a user name or password in a full URL (`http://user:pw@host/`);
- an `http` or `https` URL with no host (`http:///path`, `http:path`), or a
  CONNECT target with no host (`:443`);
- `*` with any method but OPTIONS, or a CONNECT target that is not
  `host:port`.

A target longer than `CHEZ_HTTP_MAX_TARGET_BYTES` (8 KiB) gets `414 URI Too
Long` instead.

### The one redirect

Browsers send `[`, `]` and `|` without encoding them, so links like
`/search?ids[]=1` would fail. For those, and only those, the server answers
`301 Moved Permanently` with the same target encoded:

```text
GET /search?ids[]=1        ->  301  Location: /search?ids%5B%5D=1
GET /maps?markers=red|blue ->  301  Location: /maps?markers=red%7Cblue
```

The browser follows the redirect, and your handler sees the encoded target.
The redirect is narrow on purpose:

- only for GET and HEAD, since a redirected POST can lose its body;
- only for brackets in the query, and pipes in the path or the query;
- never for a path that begins `//`, which a browser would read as another
  host;
- only when the encoded target is otherwise valid and within the target
  limit.

Anything else on the list above still gets 400.

After a 301, 400 or 414 the server closes the connection, as after every
answer it makes by itself: it has not read the rest of the request, so it
cannot tell where the next one would begin.

## The Host header

Every HTTP/1.1 request names the site it wants in a `Host` line, such as
`Host: example.com`. The server answers `400 Bad Request` and closes the
connection when:

- an HTTP/1.1 request has no `Host` line;
- a request has more than one `Host` line;
- the value is not a host with an optional port, such as `a b`, `h:x` or
  `[::1`;
- the value carries a user name (`user@example.com`).

These are RFC 9112's rules. An HTTP/1.0 request may leave `Host` out. An
empty `Host:` is allowed: a client sends one when its URL has no host.

To serve HTTP/1.1 requests that have no `Host`, set
`CHEZ_HTTP_REQUIRE_HOST=false` ([Configuration](configuration.md)). The
other rules always apply.

`request-host` gives your handler the host the request is for: from an
absolute target if there is one, else from `Host` ([Handlers](handlers.md)).

## Methods

The method must be one of the 36 the parser knows, in capitals: `GET`,
`HEAD`, `POST`, `PUT`, `DELETE`, `OPTIONS`, `PATCH`, the WebDAV methods and
the rest. Any other, such as `get` or `FOO`, gets `400`. Which of the known
methods a route accepts is your handler's choice: answer `405` or `501` to
the rest.
