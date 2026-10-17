# Performance

What the server costs in time and memory, measured on one machine: an Apple
M1 laptop (8 cores, 16 GB) on macOS, with Chez Scheme 10.4.1 (`tarm64osx`),
libuv 1.52.1, chez-libuv v0.11.0, and the default `make build`. Programs ran
with `chez --program`, which compiles the libraries as it loads them. The
load generator, [oha](https://github.com/hatoo/oha) 1.16.0, ran on the same
machine, so client and server shared its cores. Where a figure is a range,
it is the spread of repeated runs.

The server has no throughput target. These numbers are here so you know
what to expect, not as a benchmark to win.

## At a glance

| What | Measured |
|:--|:--|
| Small responses, 50 connections kept alive | 26,800–30,700 requests a second |
| Small responses, one connection kept alive | 10,600–10,900 requests a second, 0.09 ms each |
| Small responses, a new connection for each | about 6,400 requests a second |
| Downloading a 512 MiB file | 0.83–0.93 GB/s, memory flat |
| Uploading 512 MiB through `read-body` | 0.93–1.51 GB/s |
| An idle keep-alive connection | about 17 KiB |
| A handler that is waiting | about 0.7 KB |
| Memory a GET allocates, the whole server | about 5.2 KB |
| Start-up, to the `listening` line | 620–650 ms |

## Requests a second

[hello.sps](../examples/hello.sps), which answers every request with a
6-byte body, under oha for 10 seconds a run:

| Connections | Requests a second | Median latency | 99th percentile |
|:--|--:|--:|--:|
| 50, kept alive | 26,800–30,700 | 1.2–1.9 ms | 3.7–5.7 ms |
| 1, kept alive | 10,600–10,900 | 0.09 ms | 0.16 ms |
| 50, a new one for each request | 6,400 | 7.6 ms | 13.2 ms |

Keep-alive matters most: opening a TCP connection costs more than the
request on it. Behind a proxy that keeps its connections to the server
open, as Caddy and nginx do, the server sees the first row.

The run without keep-alive lasted 2 seconds: at this rate a longer one runs
the client out of local ports, each closed connection holding one for a
while (`TIME_WAIT`).

## The file server, beside Python's

[file-server.sps](../examples/file-server.sps) and
`python3 -m http.server` (Python 3.14) serving the same 254-byte file:

| Connections | file-server.sps, kept alive | file-server.sps, new each time | Python's http.server |
|:--|--:|--:|--:|
| 50 | 16,200–17,300 a second | 6,500 a second | 4,100 a second |
| 1 | 8,100 a second | 2,700 a second | 3,100 a second |

Python's server answers in HTTP/1.0 and closes every connection, so it never
gets keep-alive's head start. With 50 clients its 99th percentile latency
was 93 ms, against 6–8 ms here. On one connection with no keep-alive the two
are close; Python's is a little faster. The rows without keep-alive, and
Python's, are single 2-second runs.

For one large file, Python is faster: a 512 MiB download ran at
1.43–1.45 GB/s from Python against 0.83–0.93 GB/s here.

## Beside Racket's web server

The same two jobs in Racket v9.3 (CS) with its `web-server` library, 1.13:
a servlet that answers `Hello\n`, and the library's file dispatcher serving
the 254-byte file. Like this server, Racket's keeps connections alive and
runs on one core; it gives each connection a Racket thread. These runs were
made apart from the tables above, the two servers taking turns, so compare
the two columns with each other. Each kept-alive figure is two
10-second runs, each figure without keep-alive one 2-second run.

| Job | Connections | This server | Racket's |
|:--|:--|--:|--:|
| hello, kept alive | 50 | 33,100–33,800 a second | 11,600–12,800 a second |
| hello, kept alive | 1 | 10,700–11,400 a second | 6,300–6,400 a second |
| hello, new each time | 50 | 6,400 a second | 6,600 a second |
| hello, new each time | 1 | 3,900 a second | 3,200 a second |
| the file, kept alive | 50 | 16,300–16,400 a second | 6,900 a second |
| the file, kept alive | 1 | 7,900–8,000 a second | 4,300 a second |
| the file, new each time | 50 | 6,600 a second | 5,600 a second |
| the file, new each time | 1 | 3,400 a second | 2,700 a second |

With keep-alive this server answered 1.7 to 2.9 times as many requests.
With 50 clients saying hello, Racket's median latency was 4.7–5.2 ms
against 1.1–1.2 ms here, and its 99th percentile 7.4–10.6 ms against
3.0–3.2 ms. Without keep-alive the gap is at most 1.3 times, and Racket's
was a little ahead at 50 clients saying hello: opening the connection costs
more than either server's work.

The Racket hello server:

```racket
#lang racket/base
(require web-server/web-server web-server/servlet-dispatch web-server/http)
(define (start req)
  (response/full 200 #"OK" (current-seconds) #"text/plain" '() (list #"Hello\n")))
(define stop (serve #:dispatch (dispatch/servlet start)
                    #:listen-ip "127.0.0.1" #:port 8080))
(with-handlers ([exn:break? (lambda (e) (stop))]) (sync never-evt))
```

The file server is the same with
`(files:make #:url->path (make-url->path dir))` as the dispatcher, from
`web-server/dispatchers/dispatch-files` and
`web-server/dispatchers/filesystem-map`. Both ran compiled with
`raco make`.

## Beside Node

The same two jobs in Node 26.0.0: `http.createServer` answering `Hello\n`,
and, since Node has no file server of its own, the one below. Node runs on
libuv too, with one JavaScript thread. These runs, too, were made apart
from the other tables, the two servers taking turns, and counted as for
Racket.

| Job | Connections | This server | Node's |
|:--|:--|--:|--:|
| hello, kept alive | 50 | 35,300–35,600 a second | 37,900–38,000 a second |
| hello, kept alive | 1 | 11,100–11,400 a second | 11,100–11,700 a second |
| hello, new each time | 50 | 6,400 a second | 6,300 a second |
| hello, new each time | 1 | 3,900 a second | 4,200 a second |
| the file, kept alive | 50 | 13,200–14,100 a second | 17,200–17,600 a second |
| the file, kept alive | 1 | 7,400–7,600 a second | 6,400–6,500 a second |
| the file, new each time | 50 | 6,600 a second | 5,500 a second |
| the file, new each time | 1 | 3,300 a second | 3,000 a second |

Saying hello, the two are within 10% of each other in every row. Node
answered a few more requests at 50 kept-alive connections; this server's
latency was
a little lower, a median of 1.05 ms against 1.24 ms, and a 99th percentile
of 2.3–2.4 ms against 2.5–2.6 ms.

Serving the file, Node was 1.2–1.3 times ahead at 50 kept-alive
connections, and this server ahead in the other three rows. There Node
kept 1.65 cores busy against this server's one, measured over 3 seconds:
Node hands each file's stat, open and reads to libuv's thread pool, while
file-server.sps reads the file on the loop's one thread. Saying hello,
both used one core.

The Node file server:

```js
// node files.mjs PORT DIR: DIR's files on 127.0.0.1:PORT
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const port = Number(process.argv[2]);
const root = path.resolve(process.argv[3]);
http.createServer((req, res) => {
  const file = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!file.startsWith(root + path.sep)) { res.writeHead(404).end(); return; }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404).end(); return; }
    res.writeHead(200, {'Content-Type': 'text/plain', 'Content-Length': st.size});
    fs.createReadStream(file).pipe(res);
  });
}).listen(port, '127.0.0.1', () => console.log(`listening 127.0.0.1 ${port}`));
```

## Big bodies

A 512 MiB file, downloaded with curl over one connection, three times:

- **Download**, through file-server.sps's 64 KiB pieces: 0.83–0.93 GB/s.
  The server's resident memory did not grow at all during the downloads:
  a streamed body is asked for its next piece only while the client keeps up
  ([Bodies and streaming](bodies.md)).
- **Upload**, counted by a handler that reads with `read-body`:
  0.93–1.51 GB/s. `read-body` never holds the body whole.

## Memory

- **An idle connection** holds about 17 KiB: 16.5–17.1 KiB each, the growth in
  the server's resident memory between 1,000 and 4,000 idle keep-alive
  connections, over two runs. Most of it is the 16 KiB read buffer
  (`CHEZ_HTTP_READ_BUFFER_SIZE`). 10,000 connections hold about 170 MB.
- **A waiting handler** holds about 0.7 KB until its wait ends, and about
  16 B more for each call deep it waits ([Waiting](waiting.md)).
- **A slow reader of a streamed response** costs at most about 256 KiB and
  one piece (`CHEZ_HTTP_WRITE_HIGH_WATER`).

## Allocation per request

Allocation is what makes Chez's garbage collector run, so the test suite
measures it on every run:

| Request | Bytes allocated |
|:--|--:|
| a GET through the whole server: shell, scheduler, libuv binding and core | 5,156 B |
| curl's GET, in the connection core alone | 1,840 B |
| `ab -k`'s GET, in the core | 2,112 B |
| a JSON POST read whole, in the core | 2,640 B |
| a JSON POST read with `read-body`, in the core | 2,448 B |
| a browser's GET with eleven header fields, in the core | 3,312 B |

The whole-server figure must stay at or under 5,376 B, or the suite fails.
A larger body allocates no more in the core: its pieces are positions in the
read buffer, never copies.

## Start-up

`serve` printed `listening` 620–650 ms after `chez --program` started,
nearly all of it Chez compiling the libraries from source.

## Measuring it yourself

```sh
make build
make run PROGRAM=examples/hello.sps &
build/oha -z 10s -c 50 http://127.0.0.1:8080/
```

`make oha` fetches the same oha binary the test suite uses into `build/oha`.
`make test` prints the suite's own measurements as it runs, among them the
allocation figures above.
