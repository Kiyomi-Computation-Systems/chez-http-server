# 0037: A request holds its connection's addresses, read once as the shell serves it

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25: the owner's issue #229, picked up with
"do issue 229 in a new session"; the version packed into one field on the owner's form,
"Pack the version (Recommended)", once `request-on-done!`'s slot had landed)
Plan: none; the issue is the design

## Context

- A request carried no address. docs/deploying.md said so on purpose: "A request does not
  carry the peer's address; behind a proxy it would be the proxy's anyway. Read
  `X-Forwarded-For` …, and trust it only from your own proxy." No decision record made
  that choice; it lived in the guide alone.
- The guide's own advice needs the address it left out. To trust `X-Forwarded-For` only
  from your own proxy, a handler must know who sent the request. That matters wherever
  the proxy is not the only one who can connect: in a container, where the guide says to
  listen on `0.0.0.0`; with no proxy; and to log or limit by peer.
- Ring's request has `:remote-addr`, `:server-name` and `:server-port`, and Rack's and
  WSGI's environments have `REMOTE_ADDR` and `SERVER_PORT`. circuit, a Ring-like layer
  over the server, answers `#f` for its `req-remote-address`.
- chez-libuv v0.11.0, the server's pin, gives both ends: `uv-tcp-peer-address` and
  `uv-tcp-sockname-address`, each `(values (or string #f) port)`. Nothing in the server
  called either.

## Decision

1. **Four accessors**, in `(http-server view)` and exported by the facade, each `#f` where
   the server can't say. The issue fixed their names and types:
   - `request-remote-address : Request -> (U String #f)`, as text, such as `"192.0.2.7"`
     or `"::1"`;
   - `request-remote-port : Request -> (U Nat #f)`;
   - `request-local-address : Request -> (U String #f)`, the end the connection came in on;
   - `request-local-port : Request -> (U Nat #f)`.
   Each address string is copied when asked for, as every string the view gives is.
2. **They are the connection's.** The libuv shell reads both ends once, in `serve!`, as it
   serves an accepted connection. A refused connection is never read. Reading in `serve!`
   rather than `accept!` covers `shell-adopt!`'s callers too.
3. **An end whose read fails is `#f`**, address and port, and the connection is served all
   the same. A peer that reset the connection before it was served has no address to read.
   The failure is not logged.
4. **Where they live:** an immutable `addresses` record in `(http-server request)` (remote
   address and port, local address and port), made once per connection. The request gains
   one field, which holds it. The shell hands it to the core as an optional last argument
   to `make-conn-state`, and the core puts the same record into every request it builds.
   The fake shell takes it as an optional last argument to `make-fake-connection`, after
   the scheduler, so both shells hand it over the same way; `(http-server testing)`'s host
   gives none, and docs/testing.md says so. `make-request`, `make-conn-state` and
   `make-fake-connection` keep their old arities, which give `no-addresses`.
5. **`make-addresses` checks what it is given:** an address is a string or `#f`, and a port
   a fixnum from 0 to 65535 or `#f`. Anything else is an assertion violation. A port given
   without its address is kept as `#f`: libuv answers no address only for a family it
   can't name, where the bytes it would read as a port are not one.
6. **The request keeps its version as one number**, the major times 256 plus the minor, so
   the addresses' field leaves it a record of seven fields. `request-http-major` and
   `request-http-minor` read the number apart and allocate nothing; each refuses anything
   but a request by its own name, as the record accessors they replace did.
   `make-request` refuses a version number outside 0 to 255: llhttp reads each as a byte,
   so the server never makes one.

## Consequences

- **Cost**, measured 2026-10-25 on Linux x86-64 in the Guix container, Chez 10.4.1:
  - `request-on-done!`'s slot (decision 0034) made the request seven fields, 64 B. An
    eighth for the addresses made it 80 B, as any record of eight fields is, on the tree
    rebased onto 1051ac0. With the version in one field, a request is 64 B again, given
    addresses or not; `tests/test-serve.sps` holds it there, beside a record of eight
    fields at 80 B;
  - each connection makes one 48 B addresses record, and its core state holds one field
    more;
  - an address read through an accessor costs its copy: 48 B for `"127.0.0.1"`, 176 B for
    a 39-character IPv6 address.
- **Behind a proxy, the remote end is the proxy.** docs/deploying.md now says to read
  `X-Forwarded-For` only when `request-remote-address` is your proxy's, and then only its
  last address, the one the proxy added: nginx's `$proxy_add_x_forwarded_for` appends to
  whatever the client sent.
- **A server listening on `::` takes IPv4 clients too**, on every platform: libuv sets
  `IPV6_V6ONLY` to 0 itself (libuv 1.52.1, `src/unix/tcp.c` and `src/win/tcp.c`). Both
  ends of such a connection then read as `"::ffff:…"`, and the guides say so.
- **libuv drops an IPv6 zone**: a link-local peer reads `"fe80::1"`, without its `%eth0`.
- **A take-over's transport carries no addresses.** A taker that needs them reads them from
  the request before it takes the stream.
- **Tests.**
  - The real-socket checks bind `127.0.0.1:0`, and one binds `::1` port 0. A host with no
    IPv6 loopback fails that check and names the errno, rather than skipping it, since an
    empty selection is a failure at every layer.
  - The oracles are the client handle's own `uv-tcp-sockname-address` and the listener's
    bound port.
  - `tests/test-contract.sps` makes the replay's fake with the addresses the libuv
    connection read, and compares them field by field.
- **Weighed and not taken:**
  - four fields on the request: a record of 10 fields, the version packed, is 96 B, where
    64 B holds the one record;
  - an eighth field, at 80 B a request: 16 B on every request, where a version in one
    field costs a shift and a mask to read;
  - the shell handing the addresses over beside the request, in a table keyed by request
    or a parameter set around the handler's call: a table costs an insert a request, and a
    parameter does not follow the request into readers, producers or an `awaiting` thunk
    run later on a coroutine;
  - a setter on the core's state, called after it is made: it keeps the constructor as it
    is, but makes the addresses mutable in the core.
