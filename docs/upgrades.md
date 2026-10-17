# Upgrades

A client can ask to switch a connection to another protocol, such as a
WebSocket. A handler takes it by answering
`(switch-protocols headers take-over)`. The server writes
`101 Switching Protocols` with your headers, then calls
`(take-over t retained)`. From then on the connection is a plain stream of
bytes, and `t`, the *transport*, is how you use it.

For WebSockets, use
[chez-websocket](https://github.com/Kiyomi-Computation-Systems/chez-websocket):
it does the handshake and the framing on top of this.

```scheme
;; a client asking for Upgrade: echo gets back every byte it sends
(serve
 (lambda (request)
   (if (equal? (request-header request "upgrade") "echo")
       (switch-protocols
        (list (cons (string->utf8 "Upgrade") (string->utf8 "echo")))
        (lambda (t retained)
          (when (> (bytevector-length retained) 0) (transport-write! t retained))
          (transport-read-start! t
                                 (lambda (bv start end) (transport-write! t bv start end))
                                 (lambda (why) (transport-close! t)))
          (transport-on-drain! t (lambda () (transport-close! t)))))
       (make-response 200 #f '() (string->utf8 "ask for Upgrade: echo\n")))))
```

## Which requests can be taken

- An HTTP/1.1 request with `Connection: upgrade` and `Upgrade`, and no body.
  A switch answered to any other request gets `500`, and the server logs
  `invalid-response not-an-upgrade`.
- Your `Upgrade` header must name a protocol the client's did, or the client
  gets `500` (`invalid-upgrade`). The server writes `Connection: upgrade`
  itself; leave out `Content-Length` and `Transfer-Encoding`. A client that
  also sent `Expect: 100-continue` gets `100 Continue` first.
- `retained` is what the client sent after its request that the server had
  already read. It is usually empty: a WebSocket client waits for the `101`.

## The transport

| Call | Does |
|:--|:--|
| `(transport-write! t bv [start end] [done])` | sends the bytes; `done` gets `#f` once sent, or the error |
| `(transport-read-start! t on-bytes on-end)` | each read as `(on-bytes bv start end)`; `(on-end why)` once: `eof` or the error |
| `(transport-read-stop! t)` | stops reading |
| `(transport-close! t)` | closes, once your writes have gone out and the client closes too |
| `(transport-deadline! t ms proc)` | calls `proc` once `ms` milliseconds pass; `(transport-deadline! t #f)` cancels |
| `(transport-on-drain! t proc)` | calls `proc` when the server shuts down |
| `(transport-on-close! t proc)` | calls `proc` once the stream has closed, whoever closed it (at once if it has) |
| `(transport-abort! t)` | closes now: writes not yet sent are dropped, their `done` getting `ECANCELED` |

Reading:

- Each read's bytevector is yours to keep. A write of no bytes is refused.
- Nothing is read until you call `transport-read-start!` or
  `transport-close!`: what the client sends after the `101` waits for you,
  however late you start reading. Once you close, what it sends is read and
  dropped while the close waits for it to close too.

Writing:

- Nothing bounds what you write but you. A client that stops reading leaves
  your writes waiting, in memory. Count what you have written and not yet
  had `done` for; past a bound you choose, stop writing, or stop reading what
  you would echo. To close a client that never catches up, arm a deadline
  that calls `transport-abort!`.
- Each `transport-write!` is a write of its own: the server does not join
  small ones together, as it does for a response. Many small writes are
  slower than one, so join small pieces into one bytevector first.
- A write after `transport-close!` is not sent: its `done` gets `ECANCELED`.
  That `done`, and the one for a write refused as you ask for it, comes on
  the server's next turn, or, if the server stops first, before `serve`
  returns. A write you ask for in a `done` that comes then gets no `done`.

Closing:

- `transport-close!` closes gently, as the server closes its own connections
  ([Connections](connections.md)). It stops handing you reads, but keeps
  reading and throws away what the client still sends. Once your writes have
  gone out it tells the client it has finished writing, and it closes when
  the client closes too, or after `CHEZ_HTTP_LINGER_TIMEOUT` (30 s). So a
  client still sending reads your goodbye instead of a reset. Your close
  call runs then.
- After `transport-close!`, the server gives each write still waiting
  `CHEZ_HTTP_WRITE_TIMEOUT` (60 s), and aborts the stream past it.
  `transport-read-stop!` then changes nothing, and once your writes are out
  neither does a deadline; `transport-abort!` still closes at once. A
  deadline of yours that passes before then still runs.
- A client that reads again after an abort may still get part of a write
  already under way.

Deadlines and shutdown:

- One deadline at a time: a new one replaces the last. It is checked every
  `CHEZ_HTTP_TICK_MS` (250 ms), so it can pass up to that late.
- When the server shuts down, your drain call is your chance to say goodbye
  (a WebSocket sends close code 1001) and close. The server waits for the
  close, and after `CHEZ_HTTP_DRAIN_TIMEOUT` closes the stream itself. The
  drain call runs once; registered while the server is already shutting
  down, it runs at once.
- A taken stream still counts toward `CHEZ_HTTP_MAX_CONNECTIONS` until it
  has closed. One you neither read nor time out stays open, a client gone or
  not, until the server shuts down: read it, or arm a deadline that aborts
  it.

Callbacks:

- Your take-over and your callbacks run inside the server's own callbacks,
  so keep them quick: they cannot `await`. If one raises, the server logs
  `taker-failed` and closes the stream.

## A taker that waits

To wait, have your take-over answer `(awaiting thunk)`, as a handler does.
The server runs `thunk` on a coroutine, where it can `await`, `sleep-ms`,
`with-deadline` and `resolve` ([Waiting](waiting.md)). Your read callback
still runs in place: it can wake the thunk with the `resume` an `await`
handed out.

```scheme
;; each read is written back by a loop that waits for the next one
(lambda (t retained)
  (let ((reads '()) (resume-to #f))
    ;; in place: keep each read, and wake the loop if it waits
    (transport-read-start! t
                           (lambda (bv start end)
                             (set! reads (append reads (list (list bv start end))))
                             (let ((r resume-to)) (set! resume-to #f) (when r (r #t))))
                           (lambda (why) (transport-close! t)))
    ;; on a coroutine: wait for a read, write it back, again
    (awaiting
     (lambda ()
       (let loop ()
         (when (null? reads) (await (lambda (resume) (set! resume-to resume))))
         (let ((read (car reads)))
           (set! reads (cdr reads))
           (apply transport-write! t read)
           (loop)))))))
```

- When the stream closes, whoever closed it, the wait the thunk is in, or
  else its next, raises `&client-closed`, once. Let it raise and nothing is
  logged. Anything else the thunk raises is logged `taker-failed`, and the
  stream is closed.
- What the thunk returns is dropped. The stream stays open until something
  closes it.
- A thunk that waits holds memory until its wait ends, about 0.7 KB and more
  the deeper it waits, as a handler that waits does.

## Testing a taker

To test your taker without a server, make a transport of your own:
`make-transport` takes the eight procedures the calls above end up in, in
that order. Seven, without the abort, still make one, but `transport-abort!`
on it is refused. `tests/fake-shell.sls` in this repository is a fuller fake:
it plays a whole server and client around your taker, as chez-websocket's
tests use it.
