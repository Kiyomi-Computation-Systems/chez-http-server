# How it works

A tour of the server from the socket to your handler, for when you want to
know why it behaves as it does, or want to work on it.

## The big picture

```text
 socket ──bytes──▶ shell ──feed──▶ parser ──callbacks──▶ core
   ▲                 ▲                                    │
   │                 └──────────── actions ◀──────────────┘
   └──writes─────────┘       (write, call the handler, close, ...)
```

The server is split in two, a pattern called *functional core, imperative
shell*:

- **The core** decides. It is pure Scheme: no sockets, no clock, no I/O. It
  takes an *event* ("these bytes arrived", "a write finished", "a tick
  passed") and answers with a list of *actions* ("write these bytes", "call
  the handler", "close"). Every rule of HTTP the server enforces lives here.
- **The shell** acts. It turns libuv callbacks into events, hands them to
  the core, and performs the actions it gets back.

Because the core never touches the network, the tests drive it directly with
any events they like, byte by byte, and check every rule without a socket.

## One connection is a state machine

Each connection is a small record and a state, such as `idle`, `head`,
`body`, `handling`, `responding` or `lingering`. `conn-step` takes the state
and an event and returns the new state and the actions. The whole table of
states and transitions is written out as data in the test suite, and every
row is checked on its own.

The state is updated in place rather than copied, so a request costs little
memory: the core allocates about 1.8 KB for curl's GET and 3.3 KB for a
browser's, and the whole server about 5 KB a GET
([Performance](performance.md)).

## Parsing

Bytes go to [chez-httparse](https://github.com/Kiyomi-Computation-Systems/chez-httparse),
an HTTP/1 parser generated from the same description as Node's llhttp and
checked against llhttp's own tests. It calls back for each piece it finds:
the method, a piece of the URL, a header name, a piece of the body. The core
keeps those pieces as positions in the read buffer, not copies, and makes a
string only when your handler asks for one.

The core also checks what the parser lets through: the request-target
against RFC 9112's forms, using
[uriparse](https://github.com/Kiyomi-Computation-Systems/uriparse); the
`Host` line; the framing of the body. A request it refuses gets its answer
from the core itself, and your handler never runs.

## The event loop

[chez-libuv](https://github.com/Kiyomi-Computation-Systems/chez-libuv) binds
libuv, the event loop under Node.js. One loop, on one thread, serves every
connection: when a socket has bytes, libuv calls back, the shell feeds the
parser, the core answers, and the shell acts.

Your handler is called after libuv's callbacks for that turn have run, not
inside them. That is what lets a handler wait.

## Handlers that wait

A handler that answers `(awaiting thunk)` gets its thunk run on a
*coroutine*: a computation that can stop in the middle and be resumed later,
built on Chez's `call/cc`. When the thunk calls `await`, `sleep-ms` or
`resolve`, its coroutine *parks* and the loop goes on serving others. When
the event comes, the coroutine is made ready, and the scheduler resumes it
between two turns of libuv. A parked handler holds under 1 KB.

## Timers

The server keeps one timer, which fires every `CHEZ_HTTP_TICK_MS` (250 ms).
Each connection's deadline (idle, header, body, write, linger) sits in a
*timing wheel*: buckets a tick wide, so arming, moving and clearing a
deadline costs nothing and allocates nothing, and each tick looks only at
the buckets that are due. That is why timeouts act up to one tick late, never
early.

## Writing

Your response becomes a list of pieces: the status line and headers the
serializer writes, then your body, copied once. Small writes in one turn are
gathered into one, so a stream of small pieces costs few system calls. A
streamed body is asked for its next piece only while the client keeps up
(the write water marks), so a slow client costs bounded memory.

## Shutting down

The listener has a small pure core of its own, `server-step`: it accepts or
refuses each arriving connection, and on a signal tells every connection to
finish, then forces the rest closed at the drain deadline. `serve` returns
when the last connection has closed.

## How it is tested

Every rule is checked from outside, against an oracle that is not the server:

- llhttp's request fixtures and libhtp's connection streams, vendored with
  their checksums, at every way of splitting their bytes into reads;
- the strict-parsing tests of Kestrel, Apache httpd and lighttpd, AWS
  http-desync-guardian's cases, and a set of request-smuggling vectors;
- real clients: curl, ApacheBench, vtest2 scripts, and an oha load test;
- the examples, each started as its own process.

A check is kept only once it has been seen to fail when the code it guards
is broken. [Building and testing](building.md) shows how to run them.
