# Quickstart

A first server, one step at a time. Each step is a whole program: save it,
run it with `make run PROGRAM=your-file.sps`, and try it with `curl` from
another terminal. Ctrl-C stops it.

## 1. Answer every request

```scheme
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (make-response 200 #f '() (string->utf8 "Hello\n"))))
```

- `serve` starts the server and runs until you stop it. It listens on
  `127.0.0.1:8080` and prints `listening 127.0.0.1 8080`.
- The handler, the `lambda`, gets each request and returns a response.
- `make-response` takes a status, a reason phrase (`#f` means the usual one,
  here `OK`), a list of headers, and the body as bytes.

```text
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Date: Fri, 16 Oct 2026 12:00:00 GMT
Content-Length: 6

Hello
```

The server added `Date` and `Content-Length` for you.

## 2. Look at the request

```scheme
(import (rnrs) (http-server))

(define (text status s)
  (make-response status #f
                 (list (cons (string->utf8 "Content-Type") (string->utf8 "text/plain")))
                 (string->utf8 s)))

(serve
 (lambda (request)
   (let ((path (request-path request)))
     (cond ((string=? path "/") (text 200 "home\n"))
           ((string=? path "/hello")
            (text 200 (string-append "hello, " (or (request-query request) "stranger") "\n")))
           (else (text 404 "not found\n"))))))
```

```text
$ curl 'http://127.0.0.1:8080/hello?you'
hello, you
$ curl -i http://127.0.0.1:8080/nope
HTTP/1.1 404 Not Found
...
```

A handler routes with plain Scheme: here a `cond` on the path. Headers are
pairs of bytevectors, `(name . value)`.

## 3. Read a body

A request with a body reaches your handler before its body has arrived. To
read it, answer with a *reader* instead of a response:

```scheme
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (read-whole-body
    (lambda (body)
      (make-response 200 #f '()
                     (string->utf8
                      (string-append "got " (number->string (bytevector-length body))
                                     " bytes\n")))))))
```

```text
$ curl --data 'hello there' http://127.0.0.1:8080/
got 11 bytes
```

`read-whole-body` collects the body, up to 1 MiB by default, then calls your
procedure with it. For bodies of any size, read them piece by piece with
`read-body` ([Bodies and streaming](bodies.md)).

## 4. Stream a response

When you don't have the whole body up front, give a *producer*: a procedure
the server calls for each next piece, until it returns the eof object.

```scheme
(import (rnrs) (http-server))

(serve
 (lambda (request)
   (let ((n 0))
     (make-response 200 #f '()
                    (lambda ()
                      (set! n (+ n 1))
                      (if (> n 3)
                          (eof-object)
                          (string->utf8 (string-append "line " (number->string n) "\n"))))))))
```

The server sends it chunked, and asks for more only as fast as the client
reads. If you know the length, wrap the producer in `sized-body` and the
server sends `Content-Length` instead
([Streaming with a length](bodies.md#streaming-with-a-length)).

## 5. Change where it listens

Settings come from the environment:

```sh
CHEZ_HTTP_PORT=3000 make run PROGRAM=your-file.sps
```

Every setting, from the port to each timeout, is in
[Configuration](configuration.md).

## Next

- [Examples](examples.md): more complete servers, a file server among them.
- [Handlers](handlers.md): everything a handler can read and answer.
- [Waiting](waiting.md): handlers that wait for something before answering.
