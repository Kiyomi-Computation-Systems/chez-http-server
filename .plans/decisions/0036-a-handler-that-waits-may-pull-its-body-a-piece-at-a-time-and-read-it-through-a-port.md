# 0036: A handler that waits may pull its body a piece at a time, and read it through a port

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25: the owner's issue #227, picked up from
another session; the four open questions by form, each the recommended, and a fifth,
item 11, by a second form after the plan-vs-landed walkthrough)
Plan: none; the issue is the design
Amends: [0013](0013-a-handler-reads-a-body-through-a-reader-it-answers-with-at-the-head-and-streams-one-out-through-a-thunk.md)
(a body is read through a reader, or now pulled) and
[0014](0014-every-handler-is-called-after-libuvs-turn-and-one-that-waits-answers-with-a-thunk-run-on-a-coroutine.md)
(a waiting handler's thunk may answer after its body has been read, or before its end)

## Context

- A handler that answered `awaiting` can wait for anything but its own body. The body
  comes through a reader the handler answers with, pushed: each piece to `on-piece`,
  then `on-end`, which gives the response. So code that reads a body is split at it:
  what runs before it runs in the thunk, what runs after in `on-end`, each piece and the
  end on coroutines of their own, so a `with-deadline`, an exception handler or a
  `parameterize` around the thunk covers neither.
- Code written to pull its input, a parser that reads a port, cannot read the body as it
  arrives. It must be handed the body whole, held to a cap (`read-whole-body`).
- A handler cannot answer partway through the body: once its thunk has answered a
  reader, only `on-end` answers.
- circuit, a Ring-like layer over the server, gives every app its body as a binary input
  port, as Ring's `InputStream` and Rack's `rack.input` are. Today it reads the body
  whole first, capped at 1 MiB, and so gives up backpressure and a `100 Continue` the
  app can decline to send.
- A layer above the server cannot turn the push into a pull: re-entering the thunk's
  continuation from each `on-piece` re-runs the drain it was captured in (decision 0025).

**Measured before the form** (2026-10-25; Darwin 25.6.0 arm64, Chez 10.4.1, libuv
1.52.1, oha 1.16.0; main at 77ace4e, the dev flavor). A shadow of the libuv shell with a
pull for the happy path, first on the library path, served oha's POSTs on one kept-alive
connection. Each figure is what the server's process allocates a request, over the
difference of two runs, with the coroutines it spawned; two rounds agreed to 1%.

| a request, Content-Length body | 16 B | 4 KiB | 64 KiB | 1 MiB |
|---|---|---|---|---|
| a GET, no body | 6,240 | | | |
| `read-whole-body` | 7,851 | 16,033 | 193,800 | 4,262,000 |
| `read-body` | 7,657 | 11,755 | 81,500 | 1,184,600 |
| `awaiting`, then `read-whole-body` | 10,800 (3) | 18,970 (3) | 197,400 (3) | 4,270,000 (3) |
| `awaiting`, then `read-body` | 10,850 (3) | 14,930 (3) | 92,900 (7) | 1,324,600 (67) |
| a pull, its events deferred to the scheduler's drain | 10,133 (1) | 18,285 (1) | 109,400 (1) | 1,353,500 (1) |
| a pull, its events dispatched in place | 9,404 (1) | 17,585 (1) | 108,530 (1) | 1,351,100 (1) |
| a pull, every piece copied | 10,133 | 18,286 | 158,700 | 2,387,000 |
| a port over the pull, `get-bytevector-n!` into 4 KiB | 15,000 | 23,177 | 115,000 | 1,371,700 |
| a port, `get-bytevector-all` | 14,974 | 31,382 | 246,900 | 3,480,000 |
| a UTF-8 text port, `get-line` of 64-byte lines | | 42,405 | 405,165 | 5,979,687 |
| a text port, `get-string-all` | 33,186 | 90,606 | 905,700 | 13,994,700 |

Chunked, as curl sends a file (one connection): 16 B, 64 KiB and 1 MiB cost
`awaiting`, then `read-body` 12,143 (3), 94,323 (7) and 1,333,829 (72) B; the pull
11,584 (1), 127,156 (1) and 1,732,674 (1) B.

- The pull runs on one coroutine a request, the thunk's, at any size.
- chez-libuv copies each read into a fresh bytevector. A piece that is all of one read
  can be handed as is; one that shares its read, the read that carried the head or a
  chunk, is copied. Copying every piece costs 45% more at 64 KiB and 76% at 1 MiB. At
  4 KiB the body shares the head's read and is copied, so the pull costs 3.3 KB more
  than a streaming reader there.
- The pull's events dispatched in place, on the thunk's coroutine, save about 730 B a
  request: the first call finds the pieces the head's read carried, and does not park.
- A custom binary input port costs 432 B to make, with Chez's 128-byte buffer
  (`custom-port-buffer-size`); what reads it costs what Chez's own procedures cost. A
  transcoded port costs 5.7 KB to make.

**Peers**, read in their sources (Ring 1.15.6 on Jetty 12.1.14's ee9 layer, Rack 3.2.7
and Puma 7.2.1, Node 26.12.1, Go 1.27.3):
- Every one hands the app a stream it makes itself: an `InputStream`, `rack.input`, the
  request's `Readable`, `r.Body`.
- `100 Continue`: Go sends it at the first `Body.Read`, and a final status first
  suppresses it and closes the connection. Ring reads the stream as it builds the
  request map, so its apps always send it; Puma sends it at the head; Node at the head
  unless the app listens for `checkContinue`.
- Caps: Go's `MaxBytesReader` wraps the body before it is read, returns the bytes up to
  the cap and `*MaxBytesError` in the same read, sticky, forces `Connection: close`, and
  sends no 413: the handler does. Jetty and Puma cap per server, Node not at all.
- Ends: each answers its end again after it. Jetty rethrows the same error forever; Go
  answers `io.EOF` again.
- Unread bodies: Go drains up to 256 KiB, then closes; Jetty drains only what it has
  buffered, then closes.

## Decision

By form, the recommended of each.

1. **`next-body-piece : [(U Nat #f)] -> (U Bytevector Eof)`**, in
   `(http-server private waits)`, and **`body-input-port : [(U Nat #f)] ->
   BinaryInputPort`**, a custom binary input port over it, made when called; both
   exported by the facade. Text is `transcoded-port`'s. The port's reads pull: making it
   pulls nothing.
2. **Where it may be called.** On the coroutine of a handler's `awaiting` thunk, or of a
   thunk it answers `awaiting` with in turn, until its answer. Off a coroutine it is
   refused as every wait is, and on any other coroutine, a reader's, a producer's or a
   taker's, it is an assertion violation.
3. **The first call pulls the body.** The core reads it as it reads a streaming reader's
   on credit, and the handler's answer is still to come. The `100 Continue` a client
   waits for is written then, after the declared length is checked against the caps. A
   request with no body answers the eof object at once.
4. **A piece** is a bytevector of a byte or more that the caller owns: a piece that is
   all of one read is that read, which nothing else keeps, and any other is copied.
5. **On credit.** Reading waits until the pull has taken every piece handed to it, so a
   handler slow to take them holds one read at most.
6. **A cap of its own**, given to the first call, below `CHEZ_HTTP_MAX_BODY_BYTES`. A
   later call that names another is an assertion violation.
7. **A body that fails while pulled is the handler's to answer.** A cap passed, a
   framing error or the body deadline: after the pieces met before it, the call raises
   `&body-failed`, `(http-server awaiting)`'s, which carries the reason and the status
   the server would answer, and so does every later call. Let out, the server answers
   that status; caught, the handler's own answer is sent. Either way the connection
   closes after it.
8. **An answer before the body's end is sent**, and the connection closes after it,
   `unread-body`, as for a response given instead of a reader.
9. **Its ends stick.** Once it has answered the eof object, every later call answers it
   again. Once the connection has closed before the body's end, every later call raises
   `&client-closed`.
10. **It is a wait where it waits.** A call with a piece or the end to answer answers it
    at once; one that must wait for the client is a wait, as any is: inside a deadline
    that has passed it raises `&deadline-passed`, and once the client has closed it
    raises `&client-closed`, once, as decision 0020 says. It raises only before it takes
    a piece, so a raise never drops bytes that left the connection.
11. **A close the server makes tells the request's code too.** When the connection
    closes before a pulled body's end for a reason of the server's own, the drain's
    deadline or a bug's close, an open pull closes the request's notice: the wait its
    code is in raises `&client-closed` once, as at a client's close, and the pull at
    every call. Decision 0023 tells a taker's waits the same way when its stream closes,
    whoever closed it, and Go cancels a request's context when its connection goes.
    Weighed and not taken: only the pull raising, the request's other waits going on as
    they do after a server's close today.

Weighed on the first form, and not taken:
- the wait alone, the docs showing a port; and the port alone, the wait private. Every
  peer gives its app the stream;
- a cap set by a verb of its own before the first call, as Go's wrapper; and no cap of
  its own, as Node and Rack;
- a cap's failure the handler's, but a framing error and the body deadline answered at
  once by the server, as for a reader; and every failure answered at once;
- every piece copied: 45% to 76% more for a body of 64 KiB to 1 MiB.

## Consequences

- **The core** gains one event and one action. `(body-pulled cap)` is the shell's word
  that the handler's code pulls the body: the core reads it as a streaming reader's on
  credit, the 100 and the caps as for a reader, and the handler's answer is still to
  come. `(deliver-body-failed reason status)` tells the pull its body failed, past a
  cap, by the parser's error or at the body deadline: reading stops, the core waits in
  `handling`, and the connection closes after the answer, for the failure's reason. A
  body met past the pull's cap before the pull is handed over up to the cap, as one met
  after it is cut, so the outcome does not depend on the reads. A reader's cap and the
  pull's are one field of the body's state now, read where a piece is counted.
  `conn-body-pulled?` tells the shells where a piece goes. The transition table gains
  fourteen rows (Q1–Q14) and the vocabulary its sixteenth event and eighteenth action.
- **The waits library keeps the pull.** A request's notice is made for its connection,
  names the coroutine of the handler's thunk its puller, and holds the pull once it
  begins. The loop's puller, the shell's, dispatches the pull's begin and its credit in
  place, on the thunk's coroutine, so no coroutine is spawned for a piece and the first
  call takes the pieces the head's read carried without parking. A connection's close
  tells the notice, so a pull not ended raises `&client-closed`. A wait a deadline or a
  close ended is let go, so a piece arriving after it wakes nothing.
- **Both shells** route a pulled body's pieces, end and failure to the notice's pull,
  in place, and neither logs a pull's failure let out, which the core answers with its
  status. The fake drains no scheduler from an event a coroutine dispatches.
- **Measured after** (2026-10-25; Darwin arm64, the landed code rebased onto cc9faa4,
  no shadow; two rounds within 0.2%):

  | a request, Content-Length body | 16 B | 4 KiB | 64 KiB | 1 MiB |
  |---|---|---|---|---|
  | a GET | 6,206 | | | |
  | `awaiting`, then `read-whole-body` | 10,610 | 18,764 | 197,180 | 4,267,700 |
  | `awaiting`, then `read-body` | 10,644 | 14,722 | 92,489 | 1,320,585 |
  | a pull | 8,466 | 16,625 | 105,199 | 1,309,487 |
  | a port over it, `get-bytevector-n!` into 4 KiB | 13,071 | 21,244 | 111,398 | 1,338,833 |

  The pull costs 2.2 KB less than a reader at 16 B, and at 1 MiB; at 4 KiB and 64 KiB
  it costs the copy of the body the head's read carried, 1.9 KB and 12.7 KB.
- **Checks:** `tests/test-connection-pull.sps` (34, through the fake at every delivery
  size), the table's fourteen rows and its vocabulary, eight contract scripts that play
  a pull to both shells, eleven socket checks in the shell suite, the facade's export
  list, and docs/reference.md's rows.
- **Mutation testing** (`scratchpad/mut/run.py`: each mutant's files in a root of its
  own, first on the library path; the tree never edited, its `git status` the same
  before and after). 50 mutants and a baseline, each with its red set predicted, and
  the specs hashed, before the run: 21 of the core, 16 of the waits, 9 of the libuv
  shell, 4 of the fake. Every one was killed. Of the first run's 47 rows, 31 matched
  their prediction exactly; the other 16 were killed with more or fewer reds than
  predicted (12), or needed work:
  - C19 (a pull accepted whatever the body's answer) survived: Q14 read the phase and
    the actions, which the mutant left as they were. Q14 moved to a group of its own
    whose step also reads `conn-body-pulled?`, and C19 then reddened it alone.
  - W4's cut was equivalent: once the queue is reversed into its front its back is
    empty, so the cut changed nothing. Re-cut to credit at every take, it reddened
    the two credit checks.
  - W15's cut also dropped an end the begin handed over in place, and reddened most of
    the suite; re-cut to only ignore the begin's answer, it reddened the two checks of a
    pull begun on a closed connection.
  - Three checks had no killer: the 100 a handler that never pulls never sends, the R2
    refusal, and Q2 (a pull of a body already ended). F4 and S9 (each shell pulling as
    the handler answers `awaiting`), W16 and C21 were written for them and reddened
    them. F4 first stopped the suite with a harness error
    before the 100's check: a bare `(resume #t)` with no resume. The suite now guards
    it, as the shell suite guards its own.
- **Rerun on the tree rebased onto cc9faa4** (#221–#223, #232, #233 under the slice):
  every cut still matched once, and every mutant was killed. 38 of 51 rows matched
  their prediction; the 13 others are the first run's prediction errors, the same rows,
  killed the same way, but for three broad mutants (C17, F1, F3) that now run the pull
  suite to its end instead of stopping at the unguarded resume.
- **Untested here:** the measurements on Linux, where CI runs the suites; a body larger
  than 1 MiB through a port.
