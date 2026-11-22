# Waiting

Sometimes a handler cannot answer yet: it waits for another request, for a
moment to pass, for a DNS lookup, or for work another thread does. A plain
handler cannot wait, because it
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

## Waiting for another thread: `await-outside`

Some work can only block: a database query through a C library, or a
password hash that is slow on purpose. Done in a handler, it stops every
connection. Hand it to a thread of your own instead, and wait for the answer
with `await-outside`. The loop serves everyone else meanwhile.

```scheme
;; one worker thread runs each job in turn
(define lock (make-mutex))
(define ready (make-condition))
(define jobs '())

(define (put-job! job)
  (with-mutex lock
    (set! jobs (append jobs (list job)))
    (condition-signal ready)))

(define (take-job!)
  (with-mutex lock
    (let wait () (when (null? jobs) (condition-wait ready lock) (wait)))
    (let ((job (car jobs))) (set! jobs (cdr jobs)) job)))

(fork-thread
 (lambda ()
   (let loop ()
     (let* ((job (take-job!)) (work (car job)) (resume (cdr job)))
       (resume (guard (e (#t (cons 'raised e))) (cons 'ok (work))))
       (loop)))))

;; in a handler that waits: run `work` on the worker, and give back its answer
(define (on-worker work)
  (let ((answer (await-outside (lambda (resume) (put-job! (cons work resume))))))
    (if (eq? (car answer) 'ok) (cdr answer) (raise (cdr answer)))))
```

- `(await-outside register)` calls `register` with `resume`, then waits
  until a value `resume` was called with reaches the loop, and gives it back.
- **`resume` may be called from any thread**, the loop's own too. It
  answers `#t` if the value was posted, or `#f` if not: it was called
  before, or the server has stopped.
- `#t` means posted, not seen. If a deadline or the client's close ends the
  wait first, the wait raises as any wait does, and the value that comes
  later is dropped. That is normal for a worker, so nothing is logged.
- A second call of the same `resume` answers `#f`, and the server logs
  `late-resume await-outside`.
- The handler always waits for the loop's next turn, even if `register`
  calls `resume` itself.
- A value and a deadline that come in the same turn: the value wins. The
  server hands values over before it fires that turn's timers. The
  deadline has still passed, though, so the next wait inside it raises.
- Everything else stays on the loop's thread: only this `resume` may be
  called from another. A wait begun on another thread, `await-outside` or
  any other, raises there.

### Traps

- **Bind a worker's blocking C call `__collect_safe`.** Chez stops every
  thread to collect garbage. A thread stuck in an ordinary C call can't
  stop, so the loop waits for it at its next collection, and the whole
  server freezes. chez-sqlite3 binds its calls this way. Plain Scheme code
  on a worker is fine, and so is a worker waiting in Chez's own `sleep`,
  `condition-wait` or `mutex-acquire`.
- **Don't call `(collect)` yourself** once you have workers: Chez refuses
  it while another thread is computing. Its automatic collections still
  happen.
- **`register` runs on the loop's thread.** It should only hand the work
  over. Work done in it blocks the server.
- **Catch on the worker.** A worker that raises never calls `resume`, and
  the handler waits forever. Catch, post the condition, and raise it on the
  handler's side, as above. Put a deadline around every outside wait.
- **A deadline doesn't stop the worker.** The handler gets
  `&deadline-passed` at once; the worker runs on, and its answer is
  dropped. Cancel what you can, and bound your queue, or abandoned jobs
  pile up.
- **Don't act on `#t`.** Don't commit anything because `resume` said `#t`:
  the client may never get the answer.
- **Hand over plain data.** A worker must not touch the request, its body,
  a transport, or a plain `await`'s `resume`. Take what it needs out of the
  request first.
- **Log from the handler.** A worker has its own current ports and its own
  values of Chez's thread parameters.
- **Use a Chez thread,** one made by `fork-thread`. A thread a C library
  made can't call `resume`.
- **Don't hold a lock of your own over the wait.** A wait leaves every
  `with-mutex` around it, and takes the lock again as it resumes, on the
  loop's thread: if a worker holds it then, the whole server waits.
- **Order holds per thread.** Values one thread posts arrive in the order it
  posted them. Across threads there is no order.
- **After the server stops, `resume` answers `#f`.** That is not an error
  to retry. A handler still waiting then is never woken.

[worker.sps](../examples/worker.sps) runs a slow job on a worker, with a
deadline.

## Testing a handler that waits

`(http-server testing)` runs one with no socket, on a clock your test
moves, and your test answers its lookups and plays its worker threads: see
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
- If the body fails, because it passes a cap, is malformed, stalls past the
  body deadline, or has trailers past a header limit, the call raises
  `&body-failed` once it has given you the pieces before it, and so does
  every call after. `(body-failed-reason e)` says why, such as
  `body-too-large`, and `(body-failed-status e)` is the status the server
  answers if you let the raise out, logged `request-refused`, not
  `handler-failed`: 413, 400, 408 or 431
  ([Responses](responses.md#what-the-server-answers-by-itself)).
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
