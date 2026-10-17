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
