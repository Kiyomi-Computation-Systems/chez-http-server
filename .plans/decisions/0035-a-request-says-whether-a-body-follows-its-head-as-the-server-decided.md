# 0035: A request says whether a body follows its head, as the server decided

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25: the owner's issue #228, and, by form, the
Body slot over a field of its own)
Plan: none; the issue is the design

## Context

- The core decides at the head whether a body follows: one chunked, or with a
  Content-Length above 0 (`framed?` in `conn-headers-complete-step`). It acts on the
  answer: a response given at once to a request with a body closes the connection after
  it, as `'unread-body`, and a reader answered for a request with none gets its end at
  once.
- The facade did not expose the answer. circuit, a Ring-like layer over the server,
  answers `awaiting` for every request, and its thunk wants to answer a reader only when
  a body follows. It copies the rule from the headers, and the copy drifts: the server
  reads `Content-Length: 00` as no body, as it does `0`, and a copy that tests the string
  `"0"` takes it for one. The two lookups also allocate, 64 B a request by the issue's
  count, each name turned into bytes.
- The request record's sixth field, Body, was built `#f` for every request: a handler
  reads a body through the reader it answers with. The facade did not export
  `request-body`.
- A record's size, measured on Darwin arm64, Chez 10.4.1: 64 B with six fields or seven,
  80 B with eight (16-byte alignment). Today's request has six; `request-on-done!`'s
  slot, open as #224, makes it seven.

## Decision

1. **`request-has-body? : Request -> Boolean`**, exported by the facade: `#t` when the
   request's framing announces a body, chunked or a Content-Length above 0, `#f`
   otherwise. It is the core's own `framed?`, so it agrees with the `'unread-body` close
   and the reader's end at once.
2. **The answer lives in the Body slot**, on the owner's form: the field becomes
   `has-body?`, `make-request`'s sixth argument is the Boolean, and `request-body` goes.
   It costs no byte a request, now or with #224's slot. Go's `net/http` does the like,
   giving a request with no body `http.NoBody` as its `Body` (`transfer.go:569-580`,
   go1.23.0). Not taken: a field of its own, as ASP.NET Core's
   `IHttpRequestBodyDetectionFeature.CanHaveBody` sits beside the body stream; it would
   cost 16 B a request once #224's slot lands.
3. **The core decides it once**, as it builds the request, so asking reads a field and
   allocates nothing.
4. **The name** is the issue's.

## Consequences

- No wire change. RFC 9112 §6.3 sets how a request's body length is found; a request with
  neither field has none.
- A chunked body counts even when its first chunk is its last: the framing announced one.
  The docs say so.
- `(http-server request)` loses `request-body`, which no doc covered and which was `#f`
  for every request. A program that imports all of `(http-server)` and defines
  `request-has-body?` itself no longer loads; CHANGELOG.md names the `except` import.
- An upgrade request with a Content-Length above 0 answers `#t`, as the server frames it.
  ASP.NET Core's `CanHaveBody` answers false for any upgrade; the server's own rule is
  the one a handler needs, since it is the one the close follows.
