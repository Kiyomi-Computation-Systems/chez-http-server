# 0013: A handler reads a body through a reader it answers with at the head, and writes one of unknown length through a thunk

Date: 2026-09-28
Status: accepted (user decision, 2026-09-28)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M6.1

## Context

Reading a request body, and writing a response of unknown length, are public API, so
M6 opens with them (plan §14, M6.1). In v1 so far a handler is `request → response`,
called once the message has ended (decision 0012). The core emits `deliver-body` for
each piece of a body, and neither shell performs it: the body is dropped. Decision
0005 says bodies stream to the handler and only a buffering helper takes a limit,
1 MiB by default, past which the answer is 413. The brief asks for `100 Continue` only
when the handler pulls the body, and for 16 MiB each way with memory bounded.

Measured by `research/spike/m6-body-reading.sps` (2026-09-28, Darwin arm64, Chez
10.4.1, chez-httparse v0.4.3; two runs, whose allocation rows are identical). Each way
of reading is modelled as a cycle over the real parser: the pauses it asks for are
the parser's own, and the lists the core and shell would make for them are made as
the core makes them (M2.4's cycle). The figures are what a way adds to today's
cycle, in which the body is dropped. Today the gate's JSON POST costs 2,320 B
through the real parser, adapter and core, 752 B under the 3,072 B gate.

| way | JSON POST, 13 B | a MiB, Content-Length | a MiB, chunked | held once a MiB is in |
|---|---|---|---|---|
| a reader, pieces handed over as the parser meets them | 208 | 2,256 | 4,272 | 80 |
| the same, the parser paused at each piece (the plan's one-slot mailbox) | 816 | 45,877 | 86,199 | 80 |
| the buffering helper, a reader | 224 | 1,050,919 | 2,107,760 | 1,048,656 |
| the server buffering every body, the handler at the end | 32 | 1,048,679 | 2,103,504 | 1,048,592 |
| `(handler request respond)`, the design sketch's | 224 | 2,272 | 4,288 | 96 |

"Held" is what the connection holds, past what it holds today, once a MiB body's
last piece is taken and before its response: in 16 KiB reads with Content-Length,
the same in both runs. Chunked, the buffering ways hold 1,052,736 and 1,052,672 B.

A body of unknown length, per 16 KiB piece, the protocol's own cost with a
producer that hands out one bytevector again: a thunk answering a bytevector or the
eof object, 64 B (4,144 B for a 64-piece response); a binary input port read into
the server's own buffer, 71 B (4,576 B); the design sketch's `(lambda (emit done)
...)`, 114 B (7,296 B).

Brief risk 3, at chez-httparse v0.4.3, the same in both runs: a pause inside
on-body-data re-feeds from `parser-result-next`, and each body byte is delivered
once, framed by Content-Length and chunked. After a pause on a body's last byte the
message has not completed, and one empty feed at `next` completes it. Fed again from
where the read started, the parser takes the head's first bytes as body.

## Decision

1. **A request whose framing announces a body**, chunked or a Content-Length above
   0, **is handed to the handler once the feed that completed its head has
   returned**, before any of its body is handed over. A request with no body is
   handed over at its end, as before.
2. **The handler answers a response or a reader**, made by one of two procedures:
   - `(read-body on-piece on-end)` streams. `on-piece` is called with each piece of
     the body as `bv start end`, a span of the read the piece arrived in, with any
     chunk framing removed. `on-end` is called once, after the last piece, and gives
     the response;
   - `(read-whole-body proc)`, or `(read-whole-body proc max-bytes)`, buffers.
     `proc` is called with the body as one bytevector, grown as the body
     arrives to its Content-Length, or copied and joined when chunked (as
     amended by the review, below). `max-bytes` is 1 MiB (1,048,576 B) by
     default.
3. **A read's pieces are handed over as the parser meets them**, once that read's
   feed has returned, in order. The parser is never paused at a piece (weighed: the
   plan's one-slot mailbox, which adds 816 B to the JSON POST, more than the gate
   leaves it).
4. **A response given instead of a reader**, to a request whose framing announces a
   body, **is sent at once, with `Connection: close`**, and the connection closes in
   stages after it (decision 0011), dropping what arrives. So a handler that ignores
   a body loses keep-alive on that request (weighed: the response after the body is
   dropped, keeping the connection; Go's rule, dropping up to 256 KiB after it).
5. **A cap is answered 413 Content Too Large, then close.** `CHEZ_HTTP_MAX_BODY_BYTES`,
   unset by default, caps every body, streamed or buffered; `read-whole-body` has its
   own cap. A declared Content-Length over a cap is answered at once, before any of
   the body is handed over; a chunked body at the piece that passes it.
6. **A reader answered for a request with no body** gets no pieces, and its `on-end`
   at once, so a handler may read every request with `read-whole-body`.
7. **`on-piece`, `on-end` and `read-whole-body`'s procedure raising** is the handler
   raising: 500, then close, logged as `handler-failed`.
8. **A body of unknown length is a thunk** (M6.3). `(make-response status reason
   headers thunk)`: the server calls `thunk` for each piece, and it answers a
   bytevector, or the eof object at the end, as `get-bytevector-some` does, so
   `(lambda () (get-bytevector-some port))` streams a port. It is called only below
   the write's high water, so at most one piece passes it. Such a body is chunked to
   HTTP/1.1 and close-delimited to 1.0 (M3.2's carried arm). Weighed: a binary input
   port as the body; the design sketch's `emit` and `done`, one call of which can
   emit any number of pieces past high water.

The alternatives weighed for reading: the server buffering every body up to a
default cap of 1 MiB, the handler called at the end as today, with a second kind of
handler for the brief's 16 MiB; and the design sketch's `(handler request respond)`,
which changes every handler's arity.

## Consequences

- A handler that reads nothing pays nothing for a body, and a GET sees no change. A
  reader that keeps no piece holds no more than the read in flight, 16 KiB, however
  long the body is.
- A piece is a span of its read, as the request's fields are (decision 0012): a
  reader that keeps one keeps that read, up to `read-buffer-size` bytes, so what it
  keeps it copies.
- Item 4 keeps the outcome independent of how the bytes were split into reads
  (design §8.1's second property, the outcome lane). The form's detail that would
  have kept the connection when the whole body arrived with the head is not taken:
  whether it had arrived depends on the reads.
- 413 has its first way in (design §6.5, plan §7's M3.4 note).
- M6.2's credit: a reader answered in v1 takes each read's pieces as they are handed
  over, so reading goes on at once. Reading waits on the credit, and at most one
  read is ever waiting, for M7's awaiting readers.
  *Built 2026-09-28 (M6.2):* the reader stays the handler's; whether reading waits
  for it is the shell's to say, since the shell hands the pieces over. A shell that
  hands a streaming reader its pieces on credit answers with the reader and
  `credit`, as M7's coroutine shell will; v1's shells never do. With credit owed once
  a read's pieces are handed over, the connection waits in `awaiting-credit`,
  reading stopped and no deadline armed, until `(body-credit n)` covers what the
  reader was handed (design §4.4's M6.2 rows). A whole reader's pieces the core
  copies, so it owes none. The facade exports nothing new.
- Brief risk 3: no pause inside a body happens in v1, so its two facts are pinned as
  the parser's, at the pin (`tests/test-pause-pins.sps`), until a reader needs the
  one-slot pause (M7).
- M6.4: answering with a reader is pulling the body, so `100 Continue` is written
  then, when the request asked for it. Answering with a response writes the final
  status and closes (item 4).
- The facade exports `read-body` and `read-whole-body`, and `docs/handlers.org`
  gains bodies.

## Found while building (2026-09-28, M6.1)

Settled where this record's first build was wrong or the record is silent,
and kept on the owner's word (2026-09-28), by form. Weighed: pausing the
parser at the head (below); letting a body's error or cap be met before the
handler is asked when it comes in the head's read, the outcome lane
exempting eight fixtures.

- **What the feed that completes a head meets of the body waits for the
  handler's answer.** Built as item 1 first said, the handler was asked once
  that feed had returned, and the feed could go on into the body first. A
  chunked body with an error in it (a bad chunk size) was then answered 400
  without the handler when it came in the head's read, and handed to the
  handler first when it came later: eight of the 135 strict llhttp fixtures
  (`transfer-encoding.md`) had an outcome that depended on how the bytes were
  split, which the outcome lane holds to one (design §8.1's second
  property). So the pieces that feed meets are kept, and an error it meets,
  or a cap the body passes, is kept too, and both wait for the answer: a
  reader is handed the pieces, then the error's status; a response is sent,
  the body is not read, and the error is not answered. The outcome lane now
  runs every fixture with a handler that reads every body and with one that
  reads none, and each has one outcome at every chunk size.
- **Pausing the parser at the head was built, measured and not taken.** It
  also makes the outcome independent of the reads, by asking the handler
  before any of the body is parsed. Measured through the real parser,
  adapter and core by the allocation suite (Darwin arm64, two runs each): the
  JSON POST cost 3,248 B read whole and 3,120 B streamed with the pause, over
  the 3,072 B gate, and costs 2,624 B and 2,432 B without it. The table's
  figures above are the spike's model; these are the core's. With the body
  dropped, as before M6.1, the POST costs 2,320 B.
- **The form's detail that kept the connection when the whole body came
  with the head is not taken** (Consequences): whether it came depends on the
  reads.
- **A piece that passes a cap is handed over up to it**, then the request is
  refused, so a streaming reader is handed exactly the cap's bytes, however
  they were split into reads.
- **A reader is let go when the connection lingers or closes, or when it
  raises**, not when the core writes a status of its own, so the pieces
  already asked for, a prefix up to a cap or those met before an error, reach
  it. A reader that raised is handed nothing more.

The review before the first commit (2026-09-28, on the owner's "fix all
findings"):

- **A whole reader's buffer grows as the body arrives.** Made at the declared
  length when the reader answered, it let a head alone take up to the
  reader's cap, 1 MiB by default, before any of the body came, and with no
  cap a declared length past what memory holds raised in the core. Now the
  buffer grows to the declared length once that is at most twice what has
  arrived, and doubles before: it is never more than twice what has arrived,
  the buffers it grows through come to less than twice the body (128,657 B
  for 64 KiB in 1,000-byte pieces, the allocation suite), and it ends exactly
  full. A chunked body is still copied piece by piece and joined: on a
  chunked MiB that allocates 2,099,391 B, where a doubling buffer trimmed at
  the end allocates 3,129,692 B, and both hold 2 MiB at their peak.
- **A status the core writes lets a whole reader's buffer go**, while the
  reader is kept for the pieces already asked for.

## Built (2026-09-28, M6.3): item 8

Item 8 as built, with no new decision: the core writes a producer's head, then asks the
shell to call the producer, `notify-producer`, and writes each piece as its answer comes
back, `handler-body-chunk` or `handler-body-end`, which the core's `producer-event` makes
of the answer (design §4.4's M6.3 amendment). It is asked only at or below the write's
high water, and once past it, again at the low water (decision 0005's amendment of this
day). No body is written to a HEAD, a 204 or a 304, so their producer is never called.

Chosen while building, and flagged for review:

- **The head goes out first**, as every response's head does, and the producer is asked
  for its first piece once the head is written. So a producer that fails at its first
  call gets the bare close, not a 500. Weighed: holding the head for the first piece,
  one write fewer per response and a 500 for a first-call failure, which would leave the
  client of an M7 producer that awaits before its first piece with no head until then.
- **An answer that is neither a bytevector of a byte or more nor the eof object is the
  producer failing**, reported by the shell as `handler-failed`, the bare close, as a
  raise is. Weighed: the core refusing the event as a caller bug, which would make a
  handler's mistake a shell's. An empty bytevector among them, since the review (below):
  `get-bytevector-some` never answers one, and a chunk of no bytes is the last chunk.
- **While a piece is asked for with no write outstanding, no deadline is armed**: the
  producer is then the one waited on, and decision 0005 has no deadline for a handler.
  In v1 the shells call the producer in place, so its answer comes in the same drain.

The review before the first commit (2026-09-28, on the owner's "fix all findings"):

- **An empty piece is the producer failing.** Built first as writing nothing and asking
  again, it let a producer that answered one while it had nothing ready be called again
  in the same drain for as long as it did, holding the loop, every connection's: on the
  fake shell, 99,998 calls in one delivery, until its dispatch cap. In v1 a producer
  cannot wait, so an answer that is not a piece is its failure.
- **A waiting producer is asked again at or below both water marks.** `limits-with`
  checks no value, and with a low water above the high, the core asked a producer past
  the high water.
- **A power of two's size line is made once**, as the status lines are: a 16 KiB piece's
  line cost 16 B of the core's 128.
- The docs say a producer may never be called, or be let go early, and that Chez
  closes a port it collects only when a collection runs. The review's finding said Chez
  never closed one: measured, 20,000 opens of `/dev/null` under a 1,024-descriptor
  limit all succeed with a collection every 100, and fail at the limit with none.

Measured (2026-09-28, Darwin arm64; a scratchpad probe, two runs, the same): a piece
costs the core 112 B, its write and its framing, when its length is a power of two, and
128 B otherwise, its size line made for it; the producer's event 64 B, the spike's
figure for a thunk. The allocation suite's harness, which also completes each write as
a shell reports it, reads 304 B a 100-byte piece, the same at the 64th piece as at the
16th, and eight pieces cost the same at 16 KiB as at 128 bytes, and 16 B a piece more
at 100 bytes (`tests/test-connection-allocation.sps`). curl's GET, 1,840 B, and the
JSON POST, 2,624 B read whole and 2,432 B streamed, are unchanged.

The second review (2026-09-29, on the owner's ask to check the empty piece's fix for
safety and performance; decided on the owner's word, by form):

- **The fix holds.** On a socket, a scratch server's producer answered one piece, then
  an empty bytevector: curl read the head and the piece, then the body cut short (its
  error 18), the log named the empty bytevector, and the next request was answered in
  0.9 ms. The shells' guard holds only the producer's call and its answer's check, so
  the core's own refusal is never blamed on the handler.
- **The writes outstanding are bounded too, at 64**, and a waiting producer is asked
  again at 16 or fewer: a piece is a write of its own, and small pieces let a turn ask
  thousands of times, holding the loop and memory the water marks did not count
  (decision 0005's amendment of this day has the measurements).
- **An answer that is no piece is named by its kind and length**, `(string 100000)`,
  never held by the violation: the shells log it, and the answer is the response's data.
  A string answered for its bytes had made a 100,141-character log line; it makes 154.
- **The docs say a producer must answer at once**, and that `get-bytevector-some`
  streams a file's port: a pipe's or a socket's can make it wait, and every connection
  with it. And they say to gather small rows into pieces of a few KiB.
- The allocation suite's harness now performs a completion that asks for a piece, as a
  shell does, and its per-piece shape compares 16, 32 and 48 pieces: at 64, the stream
  waits at the cap, and the wait's cost would be read as the pieces'. A piece still
  reads 304 B.
