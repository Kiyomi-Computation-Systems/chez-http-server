# 0034: a handler hears when its response is done, and how it ended, once, in place, newest first

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25, by form: "Called at once (Recommended)", "In
place, guarded (Recommended)", "All, newest first (Recommended)", "failed (Recommended)");
amended 2026-10-25 on the owner's "Fix the review's findings" (the amendment, below)
Plan: none; issue #217, filed by the owner for circuit
Amends: [0002](0002-the-connection-is-a-pure-state-machine-with-an-action-interpreter.md)
item 2's vocabulary,
[0015](0015-a-handler-waits-with-await-and-three-verbs-of-the-servers-each-wait-one-shot-and-timed-to-the-millisecond.md)
item 4

## Context

A handler learns nothing after it answers. A producer's last call is the one that answers
the eof object, not the last byte reaching the client, and once the client leaves the
server makes no more calls (0015 item 4), so a producer that holds a file's port never
learns to let it go. circuit, a Ring-like layer over the server, wants the moment for its
logging and metrics middleware, and to close a port body whose client leaves. The issue
proposed `(request-on-done! request proc)`, `proc : Symbol -> Any`, called once with
`written`, `client-closed` or `failed`, request-scoped as Rack's is, so middleware can
register for whatever response it ends up returning. A field on the response was weighed
there and set aside: a middleware that replaces a response would drop the one it was
handed.

The core has every moment already. `response-written` runs once every write of a response
has completed, and the 101's before a hand-off. Each way a response ends short of that runs
through `close`: the client's end or a read error, the write deadline, a producer's raise
after the head, ECANCELED from the shell's own close. A close the shell makes without a
step of the core (a drain's deadline, a bug) reaches the core as `closed`. A write's
failure reaches the core as a `read-error`, as a read's does: the shell reports both alike,
so the core cannot tell them apart.

Measured 2026-10-25 on Darwin arm64 (an Apple M1), Chez 10.4.1, at dfdcd05:
- A keep-alive GET costs the core 1,840 B (tests/test-connection-allocation.sps).
- A request record is 64 B with six fields or seven (Chez rounds records to 16 bytes), so a
  slot for the procedures costs a request nothing.
- Per procedure registered: 16 B to register (a pair), 48 B for the action that carries the
  procedures, about 347 B to call it in place under a guard, about 509 B to call it on a
  coroutine of its own instead (a spawn and the drain's turn).

Read from source by a research pass on 2026-10-25 (the shared notes hold the citations):
- **Order.** Rack 3's SPEC says the callables are called in reverse order of registration
  ("must"); Puma 7, Falcon (protocol-rack), Kestrel's `OnCompleted` (a stack), Jetty 12's
  `addCompletionListener` and Undertow's `ExchangeCompletionListener` call in reverse
  too. Node calls `'finish'` and `'close'` listeners in registration order.
- **A raise.** Puma, Falcon, Kestrel and Jetty log it and call the rest. In Undertow a
  throw breaks the chain and its callers close the connection. Rack says the callables
  should not raise.
- **Where it runs.** Synchronously in Rack and Puma (the worker thread), Node, Jetty and
  Undertow; Kestrel's is a Task the request loop awaits. Puma, Kestrel, Jetty and Undertow
  run it before the next request on a kept-alive connection; Node does not.
- **A late registration.** Jetty raises `IllegalStateException` ("No active stream") and
  Undertow `exchangeAlreadyComplete`; Puma, Falcon and Kestrel, by their code, never call
  one.
- **A client that leaves.** Rack, Kestrel, Jetty (with a Throwable) and Undertow call the
  hook; Node emits `'close'` with `writableFinished` false. Go has no hook: a request's
  context is cancelled when the client leaves or `ServeHTTP` returns.

## Decision

1. **`(request-on-done! request proc)`**, `Request (Symbol -> Any) -> Void`, from
   `(http-server request)`, exported by `(http-server)`. Any code that holds the request
   may call it: the handler, its reader, its producer, the code of a handler that waits.
   The procedures live in a slot of the request record.
2. **Each is called once, with how the response ended:**
   - `written`: the handler's response, every write completed (a switch's 101 included,
     before the stream is handed over), whether or not the client had half-closed;
   - `client-closed`: the client closed or reset the connection first, or a write
     failed, which the server cannot tell from a reset; a handler that lets the close's
     `&client-closed` out reports it too;
   - `failed` (decided by form): everything else, the server ending the request itself:
     a status of its own in place of the handler's (500 for a raise or a faulty answer;
     413, 408, 400 or 431 refusing the body a reader was reading), the write deadline, a
     producer's raise after the head, a close from outside the core. The first of these
     decides: a 500 whose write then fails is still `failed`.
   A request the core refuses before its handler is asked has no code that could have
   registered, and reports nothing.
3. **The core decides; the shells call** (decided by form, "In place, guarded"). The core
   owes an ending once it asks for the handler, `(call-handler request)`, and pays it once,
   at `response-written` or `close`, or at `closed` for a close it did not ask for: it
   marks the request done with how it ended, which hands back the procedures, and only
   when there are any it emits `(response-done how procs)`, the connection's 18th action.
   A request with none registered costs nothing more. The shell calls each in place, from
   its drain, before the actions after it: before the parser resumes for the next request
   on a kept-alive connection, so before that request's handler, and before a switch's
   take-over. A procedure must be quick and cannot wait: a wait there is refused, as
   anywhere no coroutine runs. A raise is logged `on-done-failed` and changes nothing:
   the others are still called, and the connection goes on as it would have.
4. **Newest first** (decided by form): each registered procedure is called, in reverse
   order of registration, so the outermost middleware, which registers first, hears last,
   as it unwinds.
5. **A registration after the response is done is called at once** (decided by form),
   inside the caller, with how it ended, so every procedure is called exactly once: a port
   opened by a waiting handler whose client reset while it waited is still closed. Its
   raise is the caller's.
6. **0015 item 4 holds**: no producer or reader is called after the client leaves. What
   was called before is told, once, by the request's procedures.

## Consequences

- The core's vocabulary has eighteen actions. The state remembers whether the request in
  flight owes an ending and whether it has failed; a state made in `handling` owes one, as
  its handler has been asked.
- The request record gains a mutable slot: '() while open, its procedures newest first,
  then the symbol it ended with. The core drops the procedures as it marks the request
  done, so a lingering connection keeps none.
- A connection the run loop's reconciliation drops, whose handle the loop no longer has,
  reaches no step of the core and calls nothing: it is a bug's path, logged `reconciled`.
- A sized body's length mismatch, landing beside this, is the server ending the request
  short: it marks the ending `failed`.
- Weighed and not taken: a field on the response, as the issue says; calling on a
  coroutine, which could wait but would let the next request's handler run first, about
  509 B a procedure; a raise closing the connection, as Undertow's callers do; a late
  registration ignored (Puma, Falcon, Kestrel) or refused (Jetty, Undertow); a fourth
  symbol, `refused`, for a refused body; `written` for a server's own status whose writes
  completed, which a caller could not tell from its own response; one procedure a request.

## Amendment, 2026-10-25: the stack's review

An xhigh review of #224-#226, before any merge, found that item 3's "in place, the moment
the response ends" let a procedure run while the request's own code still ran on a
coroutine: a reader of a handler that waits, inside a piece as its 413 was written, or a
producer parked between pieces when a close the core did not ask for came. A port a
procedure closed was then used after. Jetty 12 runs its completion listeners only once the
handler's threads have returned, and Kestrel awaits its request delegate first. On the
owner's "fix them":

1. **While a call into the request's code runs on a coroutine, the procedures wait for the
   connection's calls to end**, and are told then, in place, in the order the endings came.
   With no such call, as on every response written in full, they are told at once, as
   before, so a kept-alive connection still tells them before the next request is fed. A
   call that never ends, a wait nothing resumes, never lets them run.
2. **A reader the core has let go is handed no more**: a piece queued for a reader that
   waits is skipped once the connection lingers or closes, as the core's rule says, not
   delivered after.
3. **A raise that abandons a drain no longer loses an ending**: each `response-done` still
   queued is told from the scheduler's drain.
4. **A connection the run loop's reconciliation drops is told it closed**, `closed`, so its
   request reports `failed`, and it is marked closing, so what its code answers later is
   dropped, not written to the handle gone. The consequence above that it "calls nothing"
   no longer holds.
5. The shell catches a procedure's raise with a handler and a one-shot continuation, not a
   `guard`: measured on Darwin arm64, 209 B a call at any stack depth, where a guard cost
   332 B at depth 0, 934 at 50 and 2,733 at 200, and libuv's callbacks run deep.
