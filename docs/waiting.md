# Waiting

Sometimes a handler cannot answer yet: it waits for another request, for a
moment to pass, or for a DNS lookup. A plain handler cannot wait, because it
runs on the event loop and would stop every other connection. Instead it
answers `(awaiting thunk)`. The server runs `thunk` on a coroutine of its
own, and what `thunk` returns is the answer: a response or a reader. Inside
it, the calls below wait without blocking anything else, and it can read its
own body as it arrives.

```scheme
;; GET /wait waits until a POST arrives, then answers with the POST's body
(define waiting '())

(serve
 (lambda (request)
   (if (string=? (request-path request) "/wait")
       (awaiting
        (lambda ()
          (make-response 200 #f '()
                         (await (lambda (resume) (set! waiting (cons resume waiting)))))))
       (read-whole-body
        (lambda (body)
          (for-each (lambda (resume) (resume body)) waiting)
          (set! waiting '())
          (make-response 200 #f '() (string->utf8 "woke them\n")))))))
```

[long-poll.sps](../examples/long-poll.sps) is this, with a deadline and a
client that leaves forgotten.

## Waiting for an event: `await`

- `(await register)` calls `register` with `resume`, then waits until
  something calls `resume`, and gives back what `resume` was called with.
- Call `resume` once. A second call wakes nothing, and the server logs
  `late-resume await`.
- Only a handler that answered `awaiting` can wait, and so can the reader or
  the producer it answers with. A wait anywhere else fails the handler: the
  client gets `500`, and the server logs `handler-failed`.
- While a handler waits, the next request on its connection waits too. Other
  connections go on.
- A wait leaves every `dynamic-wind` around it and comes back in: each one's
  after thunk runs as the wait starts, and its before thunk as the code
  resumes. So don't release a resource in an after thunk, or it is released
  at every wait: release it when your code returns, or in an exception
  handler. Chez's `critical-section` and `with-mutex` are `dynamic-wind`s
  too, so neither holds across a wait.
- A waiting handler holds about 0.7 KB until its wait ends, and about 16 B
  more for each call deep it waits (1.7 KB 64 calls deep). Once it has
  answered, its connection holds no more than any other.

## When the client leaves

If the client closes or resets the connection while your handler waits:

- The wait it is in raises `&client-closed` (check with `client-closed?`). If
  it is not waiting just then, its next wait does. This happens once: after
  it, waits work as before. A reader or a producer that waits is told the
  same way.
- Let it raise, and the server answers nothing and closes the connection,
  logging nothing.
- Catch it to clean up, such as to drop a `resume` you kept, or to answer
  anyway: a client that only half-closed its side still reads your answer.
- A `resume` called after the close ended its wait wakes nothing, and the
  server logs `late-resume await`, as after a deadline.
- Behind a proxy such as Caddy, a client that leaves makes the proxy close
  its connection to this server, so your handler is told then too.

```scheme
;; a long poll that forgets a client that left
(awaiting
 (lambda ()
   (let ((mine #f))
     (guard (e ((client-closed? e) (set! waiting (remq mine waiting)) (raise e)))
       (make-response 200 #f '()
                      (await (lambda (resume)
                               (set! mine resume)
                               (set! waiting (cons resume waiting)))))))))
```

## Waiting for a time: `sleep-ms` and `with-deadline`

- `(sleep-ms n)` waits `n` milliseconds: a 10 ms sleep took 10 to 14 ms.
- `(with-deadline ms thunk)` runs `thunk` and gives back what it returns.
  Once `ms` milliseconds have passed, the wait `thunk` is in raises
  `&deadline-passed`, and so does every wait inside it after that.
  `deadline-passed?` tells you it was the deadline. Code that is not waiting
  is never cut short.
- A `resume` called after its deadline wakes nothing, and the server logs
  `late-resume await`, as for a second call.

```scheme
;; answer 504 if no POST comes within 30 seconds
(awaiting
 (lambda ()
   (guard (e ((deadline-passed? e) (make-response 504 #f '() #f)))
     (with-deadline 30000
       (lambda ()
         (make-response 200 #f '()
                        (await (lambda (resume) (set! waiting (cons resume waiting))))))))))
```

## Looking up a name: `resolve`

- `(resolve host)` waits for the system's resolver and gives back the
  addresses as strings: `("::1" "127.0.0.1")` for `"localhost"`, about
  0.2 ms.
- A name that does not resolve raises `&resolve-error` (check with
  `resolve-error?`). `(resolve-error-reason e)` says why: `EAI_NONAME` for a
  name no one knows, or `invalid-name` for one that cannot be asked about:
  empty, too long, or with a NUL in it.
- A lookup a deadline ends is cancelled if it has not begun yet. Either
  way it still answers later, and the server logs `late-resume resolve`.

## Testing a handler that waits

`(http-server testing)` runs one with no socket, on a clock your test
moves, and your test answers its lookups: see
[Testing handlers](testing.md).

## Reading the body: `next-body-piece` and `body-input-port`

A handler that waits can read its own body from its thunk, before it
answers, by pulling it. So code written to read a port can read the body as
it arrives:

```scheme
;; echo the body back, read through a port
(serve
 (lambda (request)
   (awaiting
    (lambda ()
      (let ((body (get-bytevector-all (body-input-port))))
        (make-response 200 #f '() (if (eof-object? body) #f body)))))))

;; count it a piece at a time, capped at 10 MiB
(awaiting
 (lambda ()
   (let loop ((n 0))
     (let ((piece (next-body-piece 10485760)))
       (if (eof-object? piece)
           (make-response 200 #f '() (string->utf8 (number->string n)))
           (loop (+ n (bytevector-length piece))))))))
```

- `(next-body-piece)` gives the body's next piece, a bytevector of a byte or
  more that is yours to keep, or the eof object at the end, and again after
  it. A request with no body gives the eof object at once.
- `(body-input-port)` is a binary input port over it, so `get-bytevector-all`,
  `get-bytevector-n` and `get-u8` work. For text, wrap it:
  `(transcoded-port (body-input-port) (make-transcoder (utf-8-codec)))`.
  Making the port reads nothing; its first read does.
- Only the thunk itself can pull, until it answers, and a thunk it answers
  `awaiting` with in turn. A reader, a producer or a plain handler cannot.
- The first pull asks for the body: a client that sent
  `Expect: 100-continue` gets `100 Continue` then. A handler that never
  pulls never sends it.
- The server reads only as fast as you take pieces, so it holds one read at
  most for you.
- Give a cap to the first call, `(next-body-piece 65536)` or
  `(body-input-port 65536)`, below `CHEZ_HTTP_MAX_BODY_BYTES`, which caps
  every body. A later call that names another cap is an error.
- If the body fails, because it passes a cap, is malformed, or stalls past
  the body deadline, the call raises `&body-failed` once it has given you
  the pieces before it, and so does every call after. `(body-failed-reason
  e)` says why, such as `body-too-large`, and `(body-failed-status e)` is the
  status the server answers if you let the raise out: 413, 400 or 408.
  Catch it to answer yourself. Either way the connection closes after the
  answer.
- Answer before the body's end, and the server sends your answer at once,
  then closes the connection.
- If the client leaves before the body's end, the call raises
  `&client-closed`, and so does every call after.
- A call with a piece or the end ready answers at once. One that must wait
  for the client is a wait like the others: inside a `with-deadline` that
  has passed it raises `&deadline-passed`, losing nothing, so you can read
  on outside it.
- A pulled body runs on your thunk's one coroutine whatever its size, where
  a reader the thunk answers with runs one for each piece: at 1 MiB, 1 to
  67.

## Costs to know

Inside a handler that waits, `guard` costs about 0.4 KB each time it runs,
and about 1.2 KB when it catches an `error`. `with-exception-handler`
costs about 0.15 KB, or 0.3 KB once the code inside it waits. Don't escape
from a raise by `call/1cc`: once the code inside it waits, or raises with
`error`, the escape costs 3.4 KB or more. One by `call/cc` costs a little
less than `guard`.
