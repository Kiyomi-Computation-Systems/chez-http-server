# Examples

The repository's [examples](../examples) folder holds small servers, each
one file, each showing one thing. Run one from the checkout after
`make build`:

```sh
make run PROGRAM=examples/hello.sps
```

Each listens on `127.0.0.1:8080` unless `CHEZ_HTTP_HOST` and
`CHEZ_HTTP_PORT` say otherwise, and stops on Ctrl-C. The test suite starts
every one of them and checks what it answers, so they stay working.

| Example | Shows | Try it |
|:--|:--|:--|
| [hello.sps](../examples/hello.sps) | the smallest server | `curl 127.0.0.1:8080/` |
| [echo.sps](../examples/echo.sps) | reading a request and its body | `curl --data hi 127.0.0.1:8080/` |
| [stream.sps](../examples/stream.sps) | streaming a response, and server-sent events | `curl -N '127.0.0.1:8080/ticks?n=5&ms=1000'` |
| [long-poll.sps](../examples/long-poll.sps) | a handler that waits for another request | `curl 127.0.0.1:8080/wait`, then `curl --data hi 127.0.0.1:8080/send` |
| [file-server.sps](../examples/file-server.sps) | serving a folder, like `python3 -m http.server` | see below |

## A file server, like Python's

Python ships a file server people reach for all the time:
`python3 -m http.server`. `file-server.sps` does the same job:

```sh
make run PROGRAM=examples/file-server.sps ARGS="8000 --directory ."
```

Open `http://127.0.0.1:8000/` in a browser and you get the folder's listing.
Its command line follows Python's:

```text
chez --program examples/file-server.sps [PORT] [--bind ADDRESS] [--directory DIR]
```

What it does:

- Serves the files under the folder to `GET` and `HEAD`. Any other method
  gets `501 Not Implemented`.
- A folder with an `index.html` is served that page; one without is listed,
  each name a link.
- A folder asked for without its trailing slash, `/docs`, is redirected
  (`301`) to `/docs/`, so relative links in its page work.
- A file's `Content-Type` comes from its extension: `.html` is `text/html`,
  `.png` is `image/png`, and so on. Unknown ones are
  `application/octet-stream`.
- Every file is sent with its `Content-Length`. One up to 1 MiB is read
  whole; a bigger one is streamed in 64 KiB pieces as a sized body, so a
  huge file never sits in memory.
- `.` and `..` in a path are dropped, as Python drops them, so no request
  reaches outside the folder.

Where it differs from Python's:

- It listens on `127.0.0.1` unless you pass `--bind 0.0.0.0`. Python's
  listens on every address, so anyone on your network can read the folder.
- It keeps connections alive (HTTP/1.1). Python's answers in HTTP/1.0 unless
  given `--protocol HTTP/1.1`, so it closes each connection after one
  response.
- It sends no `Last-Modified` and answers no `If-Modified-Since`, so a
  browser fetches a file again rather than reusing its cached copy.

Like Python's, it is for local use. It serves whatever the folder holds,
symbolic links included, to anyone who can connect. [Performance](performance.md)
compares the two.

## Reading the examples

Start with `hello.sps`, then `echo.sps`. `stream.sps` and `long-poll.sps`
introduce producers and `awaiting`, explained in
[Bodies and streaming](bodies.md) and [Waiting](waiting.md).
`file-server.sps` puts the pieces together: routing on the path, reading
files, streaming big ones, and building an HTML page.
