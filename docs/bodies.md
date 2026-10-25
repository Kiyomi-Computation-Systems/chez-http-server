# Bodies and streaming

How a handler reads a request's body, and how it sends a body it makes as it
goes. Neither ever needs the whole body in memory.

## Reading a body

A request with a body (a `Content-Length` above 0, or
`Transfer-Encoding: chunked`) reaches your handler as soon as its headers are
in, before its body. To read the body, answer with a *reader* instead of a
response:

```scheme
;; the whole body, as one bytevector
(serve
 (lambda (request)
   (read-whole-body
    (lambda (body) (make-response 200 #f '() body)))))

;; the body piece by piece, as it arrives
(serve
 (lambda (request)
   (let ((n 0))
     (read-body
      (lambda (bv start end) (set! n (+ n (- end start))))
      (lambda () (make-response 200 #f '() (string->utf8 (number->string n))))))))
```

- `read-whole-body` keeps the body in memory, up to 1 MiB. A bigger body gets
  `413 Content Too Large`. A second argument sets another cap:
  `(read-whole-body proc 65536)`.
- `read-body` calls its first procedure with each piece of the body, the
  bytes `bv[start, end)`, as the piece arrives. Once the body has ended it
  calls the second, which returns the response.
- `read-body` never holds the body whole, so a body of any size streams
  through: a 16 MiB upload added under 100 KB to the server's memory.
- A piece shares memory with the read it arrived in. Copy what you keep.
- A request with no body gets its end at once, so a handler can answer every
  request with a reader.
- Answer with a response instead, and the server sends it at once, without
  reading the body, and closes the connection after it.
- A client can send `Expect: 100-continue` and wait to be asked for a big
  body (curl does, for uploads over 1 MiB). Answering with a reader sends it
  `100 Continue`, and then it sends the body. Answering with a response sends
  no `100`, so the client never has to send the body at all.
- Fields sent after a chunked body (trailers) are not part of the request:
  the server reads them and drops them.
- If a reader raises, the client gets `500 Internal Server Error`.
- `CHEZ_HTTP_MAX_BODY_BYTES` caps every body, unbounded unless you set it
  ([Configuration](configuration.md)).

## Streaming a response

When you do not know the body's length before you start, give a *producer*
as the body: a procedure of no arguments that returns the next piece, a
bytevector, and the eof object when there is no more.

```scheme
;; five lines, a piece each
(serve
 (lambda (request)
   (let ((n 0))
     (make-response 200 #f '()
                    (lambda ()
                      (set! n (+ n 1))
                      (if (> n 5)
                          (eof-object)
                          (string->utf8 (string-append "line " (number->string n) "\n"))))))))
```

`(lambda () (get-bytevector-some port))` streams a file's binary input port.

- An HTTP/1.1 client gets the body chunked, and the connection stays open.
  An HTTP/1.0 client gets it with no length, and the connection closes after
  it: the close is how the client knows the body has ended.
- The server calls the producer only while the client keeps up. Once more
  than 256 KiB (`CHEZ_HTTP_WRITE_HIGH_WATER`), or 64 pieces, are written and
  not yet taken by the client, it waits until no more than 64 KiB
  (`CHEZ_HTTP_WRITE_LOW_WATER`) and 16 pieces are. So a slow client costs the
  server little more than 256 KiB and one piece.
- The server gathers pieces of up to 4,088 bytes (4 KiB less the chunk
  framing) into one write, so small rows cost it little. Each piece still
  costs a call and its framing, so return pieces of a few KiB where you can:
  100-byte rows gathered into 16 KiB pieces streamed about 4.7 times faster
  than the rows one at a time (measured on Linux).
- A producer must answer at once: while it runs, the server serves no other
  connection. Stream what is ready, such as a file. A pipe or a socket can
  make it wait for data. Never return an empty bytevector: it counts as a
  failure, like any answer that is not a piece.
- To wait between pieces, as a ticker or server-sent events do, answer with
  `awaiting`: a producer the thunk answers with may wait
  ([Waiting](waiting.md); [stream.sps](../examples/stream.sps) has one).
- The server calls the producer up to 64 times in a row and sends those
  pieces together, so a producer slow to make each piece delays its own
  pieces too.
- You may return the same bytevector each time: the server copies a piece as
  soon as it takes it.
- The headers go out before the producer is first called. If the producer
  raises, or returns what is not a bytevector with bytes in it or the eof
  object, it is too late for a `500`: the server closes the connection at
  once and logs `handler-failed`, naming what came back by its kind and
  length, such as `(string 5)`, never its value. An HTTP/1.1 client sees the
  body cut short. An HTTP/1.0 client cannot tell a cut-short body from a
  whole one.
- A `HEAD` request, a `204` or a `304` has no body, so the producer is never
  called. And the server stops calling it early when the client leaves, a
  write times out, or it fails. So don't count on reaching the eof object to
  close what the producer reads. Open a port inside the producer, on its
  first call, so a `HEAD` never opens it, and close it from a procedure
  registered with `request-on-done!`
  ([Handlers](handlers.md#when-the-response-is-done)). The server calls that
  once the response is done, however it ended:

  ```scheme
  (lambda (request)
    (let ((port #f))
      (request-on-done! request (lambda (how) (when port (close-port port))))
      (make-response 200 #f '()
                     (lambda ()
                       (unless port (set! port (open-file-input-port "big.bin")))
                       (get-bytevector-some port)))))
  ```
- A reader's response can be streamed too.

## Sending a file

Small files are simplest read whole: the server then sends their
`Content-Length`, which lets a browser show progress. For big files, stream
them with a producer that opens the file on its first call.
[file-server.sps](../examples/file-server.sps) does both, switching at 1 MiB.
