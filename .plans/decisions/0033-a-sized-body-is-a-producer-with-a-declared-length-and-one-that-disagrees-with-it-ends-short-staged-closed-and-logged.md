# 0033: A sized body is a producer with a declared length; one that disagrees with it ends short, staged-closed and logged

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25, by form: "None of it, then close", "No: the
body is done", "Staged, like any response", "body-length-mismatch n given", each the
recommended option)
Plan: issue #216, "A producer body with a declared length", filed by the owner for circuit
Extends: [0010](0010-the-server-writes-framing-connection-and-date-and-refuses-a-response-it-cannot-write-safely.md)
(the server writes the framing) and M6's producer, a body of unknown length

## Context

At v0.8.0 (a996eef) a body is a bytevector, whose length the server counts, or a
producer, whose length it does not know. A producer goes chunked to HTTP/1.1 and
close-delimited to 1.0 (`response-framing`), and a handler's own `Content-Length` is a
`framing-field` fault, answered 500 (0010 item 1, which weighed and refused trusting a
handler's framing, as Node does). So a body whose length is known but which should not be
held whole in memory, a file, cannot be sent with its length: the client gets no size, a
HEAD cannot announce the GET's length, and an HTTP/1.0 client loses keep-alive. circuit, a
Ring-like layer over the server, streams a file's port as a producer, and so sends it
chunked.

Measured on this tree (dfdcd05, Darwin arm64, Chez 10.4.1), through the facade:
- a producer's 200 to HTTP/1.1 is `Transfer-Encoding: chunked`, and the connection kept;
- a producer's 200 with the handler's own `Content-Length: 12` is a 500, `Content-Length:
  0`, `Connection: close`, logged `invalid-response framing-field`.

A producer's raise after the head is a bare close (M6), logged `handler-failed`. Measured,
a bare close lost no byte on loopback: 4 MiB in 64 KiB pieces, then a raise, to a client
reading 64 KiB every 5 ms, arrived whole in 3 of 3 runs, and the HTTP/1.0 staged close of
the same body in 3 of 3. A bare close drops what libuv still holds once the kernel's
buffer is full, and with a pipelined request unread the kernel answers it with a reset
(0011's reason for staging every close after a response).

What a client makes of each end, measured with curl 8 against a raw server: exactly the
declared length and then a close, exit 0; fewer bytes and then a close, exit 18,
"transfer closed with N bytes remaining to read".

Peers, read from their source on 2026-10-25, or run:
- **Node 26.0.0**, run here: a handler's `Content-Length: 5` and a 10-byte write puts all
  10 bytes on the wire and keeps the connection, so the next response is read as this
  one's tail; `Content-Length: 10` and a 5-byte write keeps it too, the client waiting
  for bytes that are the next response. `strictContentLength` throws at `end()`
  (`ERR_HTTP_CONTENT_LENGTH_MISMATCH`), after the over-long write went whole, and leaves
  the response unended.
- **Go 1.25** (`net/http/server.go`): `response.write` counts the write and, past the
  declared length, writes none of it and answers `ErrContentLength`, "http: wrote more
  than the declared Content-Length" (lines 1689-1692). `shouldReuseConnection` refuses a
  connection whose written count is not the declared one, "Did not write enough. Avoid
  getting out of sync." (1733-1735). It logs neither.
- **Kestrel 9.0** (`HttpProtocol.cs`): `VerifyAndUpdateWrite` throws on the write that
  would pass the length, "too many bytes written", and turns keep-alive off (861-875);
  `VerifyResponseContentLength` reports "too few bytes written (X of Y)" as an
  application error and turns keep-alive off when any byte was written (909-931).
- **hyper 1.7** (`proto/h1/encode.rs`, `conn.rs`, `dispatch.rs`): a frame longer than
  what is left is cut to it (`msg.take(limit)`), the encoder is then at its end and the
  connection kept (`Writing::KeepAlive`), and the body is not polled again ("no more
  write body allowed"); a body that ends short is `body_write_aborted`, and the
  connection closed.
- **waitress 3.0.2** (`task.py`): a write past the length is cut to it, logged once,
  "application-written content exceeded the number of bytes specified by Content-Length
  header", and the connection kept; a short body is closed after, logged "application
  returned too few bytes (X) for specified Content-Length (Y)".
- **gunicorn 23.0.0** (`http/wsgi.py`): cut at the length, silently, the connection kept.
- **PEP 3333**: a server "should not transmit more bytes to the client than the header
  allows, and should stop iterating over the response when enough data has been sent";
  a short body: "close the connection and log or otherwise report the error".

## Decision

1. **A sized body is `(sized-body n producer)`**, from `(http-server response)` and the
   facade, as the issue proposes: `n` a count of bytes, a fixnum, and `producer` a
   producer, each refused otherwise by an assertion violation. `make-response` takes it
   beside a bytevector, a producer and `#f`.
2. **It is framed by its length.** `response-framing` is given `n`, so the response is
   `content-length`, and a HEAD's `content-length-only`; a 1xx, a 204, a 304 and a 2xx
   to CONNECT stay `no-body`. Where no body is written, and where `n` is 0, the producer
   is never called. The serializer writes `Content-Length: n` and no body; the pieces
   follow, each a write of its own, unframed.
3. **The producer is called as any producer is**: below the write water marks and the
   writes' bound, and on a coroutine for a handler that waits.
4. **The core counts the bytes, and at `n` the body is done:** the producer is let go and
   asked no more, and the response is written once its writes complete (by form, "No:
   the body is done"). A producer that lands on `n` with more to give is not seen.
5. **A piece that would take the body past `n` is not written**, none of it (by form,
   "None of it, then close"), as Go and Kestrel refuse the write that crosses the
   length. The client reads the body short and knows it is wrong.
6. **A mismatch, a piece past `n` or the eof object short of it, ends the response short
   and closes the connection staged** (by form, "Staged, like any response"): the
   writes already made complete, then the write side half-closes and the connection
   lingers, as every close after a response does (0011). The close's reason is
   `body-length-mismatch`, unless the connection closes after this response for a reason
   of its own already.
7. **A mismatch logs `body-length-mismatch n given`** (by form): the declared length and
   the bytes the producer gave, the piece not written among them, so `given` above `n` is
   the long case.

Settled here by precedent, and shown to the owner with the slice:
- A sized producer that raises, or answers what is no piece, fails as any producer does:
  a bare close, logged `handler-failed`.
- `n` is checked to be a fixnum, not just an exact integer: `response-framing` takes a
  fixnum, and 2^60 - 1 bytes is past any body.

The alternatives weighed, by form:
- for a piece past `n`: writing it up to `n`, then closing (the issue's wording; the
  client reads a whole body and cannot tell it was cut, and no peer read does this);
  writing it up to `n` and keeping the connection (hyper, waitress, gunicorn);
- at `n`: asking the producer once more, expecting the eof object, to catch one that
  lands on `n` with more (no peer read does);
- the close: at once, as a producer's raise (the issue's "as it does");
- the log: `handler-failed` with a condition naming both counts; two names, long and
  short, as Kestrel has two messages.

## Consequences

- A file streams with its length: the client sees its size, a HEAD announces it, and an
  HTTP/1.0 client keeps the connection.
- A producer whose bytes disagree with `n` can never desynchronize the connection: no
  byte past `n` is written, and a body short of it ends with the connection.
- The serializer writes pieces in `content-length` mode, unframed; the core's state keeps
  a sized body's length and the bytes it has still to write.

## Watched to fail

Every new check was red before the code it holds: the records suite stopped at load
(`sized-body-length` unbound), the serializer's 30 checks red, the stream suite's 10, and
the shell's 6 and curl's 4 against the old core (`connection.sls` at main's, the rest
new). Then 32 mutants, measured on the tree rebased onto 77ace4e (Darwin arm64, Chez
10.4.1), each with its red set predicted before the run (sha256 b15a1de5 of the specs),
every suite run for each, three at a time; and a row with no mutation, green.

| Mutant | What it breaks | Red |
|---|---|---|
| R1, R2, R3 | the length a bignum or negative, the producer no procedure, accepted | records: the refusals check |
| R4 | the producer kept wrapped | records: read back |
| S1 | the head announces 0 | serializer 7, stream 9, shell 3, curl 5, examples 2 |
| S3 | a sized body framed chunked is written | serializer: the framing refusal |
| S4 | no piece written in `content-length` mode | serializer 7, stream 9, shell 6, curl 4, examples 1 |
| S5 | a sized body's end refused | serializer 2 |
| S6 | a sized body a fault | serializer 23, stream 11, shell 3, curl 5, examples 2 |
| S7, S8 | a HEAD's mode writes a piece, or has an end | serializer: each refusal check |
| C1, C2a, C2b | the producer called at 0 bytes, for a HEAD, for a 204 | stream: the HEAD, 0 and 204 check; C2a curl 1 |
| C3 | a piece landing on the length a mismatch | stream 4, shell 4, curl 3, examples 1 |
| C4, C5 | the bytes given miscounted, long and short | stream 2; stream 3, shell 1, curl 1 |
| C6 | the producer kept once the length is written | stream 4, curl 4, examples 1, shell 3 (its leak checks) |
| C7 | the producer asked again at the length | stream 4, shell 1, curl 3 |
| C8, C11 | a mismatch keeps the connection; a short end taken as the end | stream 4, shell 2, curl 1; stream 3, shell 2, curl 2 |
| C9, C10 | a mismatch replaces the connection's reason; closes before its writes complete | stream 1 each |
| C12, C13 | a long piece written whole; the pieces not counted | stream 2; stream 8, shell 2, curl 3 |
| C15 | a sized body's count outlives it | stream: the stream behind it |
| C17 | a sized producer asked past the high water | stream 2 |
| C19 | a sized producer's raise taken as a mismatch | stream: the raise check |
| C18 | a waiting handler's producer called in place (the shell) | shell 5, contract 2, examples 1 |
| F1, D2 | the facade without `sized-body`; the reference page without its entry | serve 1, reference 1, curl's suite stops at load, examples 1; reference 1 |
| E1 | file-server.sps streams big files with no length | examples 2 |
| D1, by hand | the new heading renamed | `make check-site` names the three links to it |

Seven rows differed from their prediction, each explained:
- **S1:** in the run, curl's log check was red too: curl drops a connection that sends
  bytes past a complete response, and whether the server's next write meets the reset
  decides a `read-error` line. Alone, S1 reddened the four predicted curl checks and not
  that one.
- **S4:** the shell's short-body wait was red too: the suite's waits turn the loop
  without the run loop's guard, so the core's raise fails the wait itself.
- **C2a:** curl's log check: a HEAD's mode, kept for its pieces, is one the serializer
  refuses, so the core raised and the shell logged `callback-error`.
- **C6:** the shell's three end-of-suite leak checks: the stuck connection never closes.
- **C17:** the short-with-no-write-outstanding check too, which needs the producer to wait
  at the high water.
- **C18:** the contract's sleeping-producer script and the shell's coroutine-retention
  check: every waiting producer runs in place, not only a sized one.
- **F1:** as predicted, but the runner flagged the example's own load error on stderr.

Not watched by a mutant: that `sized-body?` answers no for a producer and a bytevector,
and that `make-response` keeps a sized body, which `define-record-type` and the response
record make so; they were red at load before the record existed. file-server.sps's
closing of its port after the last byte is not read by any check.
