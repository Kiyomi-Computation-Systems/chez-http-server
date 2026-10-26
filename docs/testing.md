# Testing handlers

A test can't hand your handler a request and wait: `await`, `sleep-ms`,
`with-deadline`, `resolve` and `next-body-piece` only work where the server
runs them.
`(http-server testing)` runs your handler as the server does, with no socket
and a clock your test moves. You send bytes, and read back what a client
would.

```scheme
(import (rnrs) (http-server) (http-server testing))

;; a handler that answers after a second
(define host
  (make-test-host
   (lambda (request)
     (awaiting (lambda () (sleep-ms 1000) (make-response 200 #f '() (string->utf8 "done")))))))

(define client (test-host-connect! host))
(test-client-send! client (string->utf8 "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
(test-client-responses client)                             ; => (): still asleep
(test-host-advance! host 1000)
(map test-response-status (test-client-responses client))  ; => (200)
```

Each name is in the [API reference](reference.md#testing-http-server-testing).

## The host

- `(make-test-host handler)` hosts the handler you would give `serve`.
- A second argument changes settings, as `serve`'s does: a procedure from a
  setting's name to its value, or `#f`. Without it every setting is its
  default, and the environment is not read. A malformed setting raises
  `&http-server-config-error`, as `serve` does. Nothing listens, so a
  `CHEZ_HTTP_HOST` that is not an IP address is not refused: only `serve`
  refuses it, as it listens.
- `(test-host-connect! host)` connects a client. Connect several to test
  handlers that wake each other, as a long poll does. Every connection runs
  on one scheduler and one clock, as in the server, so what is woken first
  runs first.
- Each call that does something (a connect, a send, a close, an advance, an
  answer) runs all that follows from it, then returns. Nothing runs between
  calls, so a test never sleeps.
- A `resume` your test calls itself only makes its handler ready to go on.
  `(test-host-advance! host 0)` runs it.
- Call the host from your test, not from the code it runs: a call that does
  something, made from a handler, a reader, a producer or a taker, raises an
  assertion violation there. A handler that does it fails, and the client
  gets `500`.

## Sending

- `(test-client-send! client bytes)` sends bytes as they go on the wire, so
  you can send a malformed request, two at once, or a body in pieces, some
  now and some after an advance.
- The server reads them as it reads a socket: at most
  `CHEZ_HTTP_READ_BUFFER_SIZE` bytes at a time, and only while it reads.
  What it doesn't read yet waits, as it would in the kernel.
- `(test-client-close! client)` closes the client's side, and
  `(test-client-reset! client)` resets the connection. The server reads
  either after what the client sent before it, and only while it reads: a
  handler waiting is told, as in [Waiting](waiting.md#when-the-client-leaves),
  once the server reads it. While a handler waits the server reads on,
  unless it holds another request sent behind this one, or this one's body,
  still to be read.
- A client that has reset reads nothing written after it.
- A handler that pulls its body, with `next-body-piece` or `body-input-port`,
  takes each piece as the server reads it, so a body sent in pieces comes
  to it in pieces ([Waiting](waiting.md#reading-the-body-next-body-piece-and-body-input-port)).

## Time

- The clock starts at 0 ms and moves only with
  `(test-host-advance! host ms)`. Each sleep and deadline ends at its own
  time, in order.
- The server's own timeouts (idle, header, body and the rest) fire here at
  the earliest time they can. The server checks them every
  `CHEZ_HTTP_TICK_MS`, so there one fires up to that much later: don't pin
  one to the millisecond.
- The `Date` field reads the clock from 1970: at 1000 ms it is
  `Thu, 01 Jan 1970 00:00:01 GMT`.

## Lookups

- A handler's `(resolve name)` waits until your test answers it.
  `(test-host-lookups host)` lists the names it waits on, oldest first.
- `(test-host-answer! host name '("192.0.2.1"))` gives the oldest lookup of
  that name its addresses. `(test-host-answer! host name 'EAI_NONAME)`
  makes `resolve` raise `&resolve-error` with that reason.
- A lookup a deadline ends is cancelled, and leaves the list. It still
  answers, later, and the host logs `late-resume resolve`, as the server
  does.

## What the client read

- `(test-client-responses client)` lists the responses, in order. Read each
  with `test-response-status`, `test-response-reason`,
  `test-response-headers`, `test-response-header` and `test-response-body`,
  the body de-chunked. `test-response-bytes` gives it as it was on the wire.
- A response is listed once its head is in. Until all of it is, it is not
  `test-response-complete?`.
- `(test-client-received client)` is every byte, as it came.
- `(test-client-connection-closed? client)` says whether the server has
  ended the connection.

## What the server logged

`(test-host-log host)` lists what the server would log, in order, each as
`(what . details)`: `(handler-failed e)` for a handler that raised,
`(on-done-failed e)` for a procedure given to `request-on-done!` that
raised, `(late-resume await)`, `(read-error ECONNRESET)` and the rest. As
the server does, it leaves out a handler that lets out the `&client-closed`
its client's close raised, or the `&body-failed` its pulled body raised.

## A handler still waiting

A handler waiting for something your test never sends stays parked: the
test goes on, and never hangs. `(test-client-waiting? client)` says it still
waits, and `(test-host-waiting host)` lists every such client. Code that
never lets the host go quiet, such as a producer that never ends, makes the
call that started it raise an assertion violation.

## What it leaves out

- No listener, so no connection limit, and no shutdown.
- No socket, so no addresses: `request-remote-address` and the other three
  read `#f`.
- Clients read every byte as soon as it is written, so no slow reader and no
  write timeout. A write after a reset the server hasn't read yet goes
  through; the server learns of the reset when it reads it.
- A handler that raises after its connection has closed is logged
  `handler-failed` by the server, but not here.
- A request and a reset that arrive at the same moment: the server may
  close the connection before it calls the handler, but the host always
  calls it.
- `test-client-waiting?` counts the handler's own code, not a taker's.

[test-handler-testing.sps](../tests/test-handler-testing.sps) tests
[long-poll.sps](../examples/long-poll.sps) this way: a wait, the send that
wakes it, its deadline, and a client that leaves.
