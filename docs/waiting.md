# Waiting

Sometimes a handler cannot answer yet: it waits for another request, for a
moment to pass, or for a DNS lookup. A plain handler cannot wait, because it
runs on the event loop and would stop every other connection. Instead it
answers `(awaiting thunk)`. The server runs `thunk` on a coroutine of its
own, and what `thunk` returns is the answer: a response or a reader. Inside
it, the calls below wait without blocking anything else.

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
- A lookup a deadline ends is cancelled if it has not begun. One already
  under way still answers later, and the server logs `late-resume resolve`.

## Costs to know

Inside a handler that waits, `guard` costs about 3.7 KB each time it runs.
`with-exception-handler` costs next to nothing.
