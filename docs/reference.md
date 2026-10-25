# API reference

Everything `(http-server)` exports, one entry each. Types are written as
Typed Racket writes them: `Nat` is an exact non-negative integer, `[x]` an
optional argument, `(U a b)` either one.

```scheme
(import (rnrs) (http-server))
```

Shared types:

```text
Headers  = (Listof (Pair Bytevector Bytevector))
Body     = (U Bytevector #f Producer SizedBody)
Producer = (-> (U Bytevector Eof))
Answer   = (U Response BodyReader Awaiting)
```

## The server

### serve

```text
serve : (Request -> (U Answer Switch)) [(String -> (U String #f))] -> Void
```

Starts the server with this handler and runs until it is sent `SIGTERM` or
`SIGINT` and has drained. The optional second argument looks up settings in
place of the process's environment. Raises `&http-server-config-error` for a
malformed setting. See [Handlers](handlers.md) and
[Configuration](configuration.md).

### &http-server-error, http-server-error?

An `&error`: the condition type of the server's own errors.
`http-server-error? : Any -> Boolean`.

### &http-server-config-error, http-server-config-error?

An `&http-server-error`: a setting is malformed, raised by `serve` before it
listens. Its message names the variable. `http-server-config-error? : Any ->
Boolean`.

## Reading a request

Every string they give, header names included, has one character per byte
of the request (Latin-1), and is made when called. See
[Handlers](handlers.md#reading-the-request).

| Name | Type | Gives |
|:--|:--|:--|
| `request?` | `Any -> Boolean` | whether it is a request |
| `request-method` | `Request -> Symbol` | the method, such as `GET` |
| `request-path` | `Request -> String` | the path, not decoded |
| `request-query` | `Request -> (U String #f)` | after the first `?`, or `#f` |
| `request-header` | `Request String -> (U String #f)` | the first field of that name, any case |
| `request-header-values` | `Request String -> (Listof String)` | every field of that name, in order |
| `request-header-list` | `Request -> (Listof (Pair String String))` | every field, its name as sent, in order |
| `request-host` | `Request -> String` | the host the request is for, `""` if none |
| `request-http-major` | `Request -> Nat` | the first number of the version the request names, always `1` |
| `request-http-minor` | `Request -> Nat` | its second: `2` for `HTTP/1.2`, which is answered as HTTP/1.1 |

## Reading a body

See [Bodies and streaming](bodies.md).

### read-body

```text
read-body : (Bytevector Nat Nat -> Any) (-> Response) -> BodyReader
```

A reader: the first procedure gets each piece of the body as `bv[start, end)`
as it arrives; the second, called at the body's end, returns the response.

### read-whole-body

```text
read-whole-body : (Bytevector -> Response) [(U Nat #f)] -> BodyReader
```

A reader that collects the whole body, up to the cap (1 MiB by default), and
calls the procedure with it. A bigger body gets `413`.

## Answering

### make-response

```text
make-response : Nat (U Bytevector #f) Headers Body -> Response
```

A response: status (200 to 599), reason phrase (`#f` for the usual one),
headers, body. See [Responses](responses.md).

### response?

`Any -> Boolean`.

### sized-body

```text
sized-body : Nat Producer -> SizedBody
```

A body of that many bytes, made by the producer as it is sent, with its
`Content-Length`. See [Bodies and streaming](bodies.md).

## Waiting

See [Waiting](waiting.md). The waits below work only inside a thunk given to
`awaiting`, or a reader or producer it answers with.

| Name | Type | Does |
|:--|:--|:--|
| `awaiting` | `(-> Answer) -> Awaiting` | an answer that runs the thunk where it may wait |
| `await` | `((Any -> Void) -> Any) -> Any` | gives `register` a `resume`, waits for it, returns what it was called with |
| `sleep-ms` | `Nat -> Void` | waits that many milliseconds |
| `with-deadline` | `Nat (-> (Values Any ...)) -> (Values Any ...)` | runs the thunk; its waits raise `&deadline-passed` after that many milliseconds |
| `resolve` | `String -> (Listof String)` | the host's addresses, as strings |

Conditions, each an `&error`:

| Name | Raised when | Check |
|:--|:--|:--|
| `&deadline-passed` | a `with-deadline` deadline passed during a wait | `deadline-passed? : Any -> Boolean` |
| `&client-closed` | the client closed or reset the connection | `client-closed? : Any -> Boolean` |
| `&resolve-error` | a name did not resolve | `resolve-error? : Any -> Boolean` |

`resolve-error-reason : ResolveError -> Symbol` says why a lookup failed:
`EAI_NONAME` and the resolver's other codes, or `invalid-name`.

## Upgrades

See [Upgrades](upgrades.md).

### switch-protocols

```text
switch-protocols : Headers (Transport Bytevector -> Any) -> Switch
```

An answer that takes an HTTP/1.1 upgrade: the server writes `101` with these
headers, then calls the procedure with the transport and the bytes it had
already read past the request.

### The transport

| Name | Type |
|:--|:--|
| `transport?` | `Any -> Boolean` |
| `transport-write!` | `Transport Bytevector [Nat Nat] [(U #f ((U #f Symbol) -> Any))] -> Any` |
| `transport-read-start!` | `Transport (Bytevector Nat Nat -> Any) (Symbol -> Any) -> Any` |
| `transport-read-stop!` | `Transport -> Any` |
| `transport-close!` | `Transport -> Any` |
| `transport-abort!` | `Transport -> Any` |
| `transport-deadline!` | `Transport (U Nat #f) [(-> Any)] -> Any` |
| `transport-on-drain!` | `Transport (-> Any) -> Any` |
| `transport-on-close!` | `Transport (-> Any) -> Any` |

### make-transport

```text
make-transport : write read-start read-stop close deadline on-drain on-close [abort]
                 -> Transport
```

A transport of your own, for testing a taker without a server: each argument
is the procedure the matching call above ends up in. Without `abort`,
`transport-abort!` on it is refused.
