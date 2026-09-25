# 0010: The server writes a response's framing, its Connection field and its Date; a handler's response it cannot write safely is answered 500

Date: 2026-09-25
Status: accepted (user decision, 2026-09-25)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §7, M3

## Context

M3 builds `(http-server serializer)`, which turns a `response` record into the
segments of one `uv-write*!` (design §3.1, §7.3). Three things it must settle were in
no plan or decision.

- **The Date.** RFC 9110 §6.6.1 says an origin server with a clock MUST send a Date in
  every 2xx, 3xx and 4xx response, and MAY in the others. The core reads no clock
  (decision 0002 item 1), so it cannot write one.
- **What a handler may put on the wire.** A response record is data from application
  code, and some of it cannot be written as given:
  - a CR, LF or NUL in a field value can split one response into two. RFC 9110 §5.5
    calls them "invalid and dangerous", and other control characters invalid too;
  - a field name must be a token (RFC 9110 §5.1). Status codes outside 100–599 are
    invalid (RFC 9110 §15), and a 1xx is interim, never a final answer;
  - a handler's own `Content-Length` or `Transfer-Encoding` would let two parts of the
    server decide where the body ends. A response carrying two framings is the shape
    of response smuggling.
- **The write watermarks.** Decision 0005 sets `write-high-water` (262,144 bytes
  outstanding, read-stop) and `write-low-water` (65,536, read-start). Plan §3 had them
  arrive in M3. But in v1 a handler's response is written with reading already
  stopped (decision 0004 item 1), and only one response is ever outstanding, so that
  read-stop can never fire.

Measured 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`, by
`research/spike/m3-response-costs.sps`, a prior, not an oracle
(`out/m3-response-costs.run{1,2}.txt`: the bytes identical, the times within 2%):

| Per response | Bytes | Time |
|---|---|---|
| a Date formatted per response, through strings | 4,016–4,032, by the time's digits | 1.2 µs |
| a Date formatted per response, straight into bytes | 208 | 0.2 µs |
| a Date the shell re-formats once a second | 0 | ~1 ns |
| the header check below, three headers | 0 | 145 ns |

On the allocation gate's workload (3,072 B per request, decision 0002's second
amendment), a prototype serializer brought the spike's 2,464 B per request to 2,576 B
for an empty 200, and to 2,912 B for three headers and a 13-byte body. A Date formatted
per response would put the second at 3,120 B. nginx and Node keep the formatted date
and re-format it when the second changes; Go formats it per response.

## Decision

1. **The serializer writes the framing fields.** `Content-Length`, or
   `Transfer-Encoding: chunked`, comes from the connection's framing decision (M3.2),
   never from the handler. A handler's own field of either name is a fault (item 2).
2. **A handler's response the serializer cannot write safely is answered 500**, and the
   connection closes after it, as after a handler that raised (design §6.5). A `log`
   action names the fault. The faults:
   - not a `response` record;
   - a status that is not an integer from 200 to 599;
   - a reason phrase that is not bytes, or holds a control character other than HTAB;
   - a header list that is not a list of name–value pairs of bytes;
   - a name that is not a token;
   - a value holding a control character other than HTAB (CR, LF and NUL among them);
   - a `Content-Length` or `Transfer-Encoding` field (item 1);
   - a `Connection` field that is not `close` (item 3);
   - a body that is neither a bytevector nor `#f`.
3. **The server writes the `Connection` field.** It writes `Connection: close` when the
   connection closes after the response, and `Connection: keep-alive` to an HTTP/1.0
   client that asked to keep it (decision 0006 item 1). A handler's `Connection: close`
   is honoured: the connection closes after that response, and the field is written
   once. Any other `Connection` value from a handler is a fault.
4. **The shell fills the Date.** Every final response the serializer writes, the core's
   own included, leaves a Date slot directly after the status line. The slot is always
   37 bytes: `Date: `, an IMF-fixdate, which is always 29 characters (RFC 9110 §5.6.7),
   and CRLF. The serializer counts it in the write's byte count and formats the line,
   from whole seconds since the epoch. The shell fills the slot from a line it
   re-formats when the second changes (M4). The fake shell fills it from its fake
   clock. A handler's own Date is written instead, and no slot is left.
5. **The write watermarks arrive in M6**, not M3. M6 streams response bodies, which is
   the first time a response can outrun its client and a test can watch the watermarks
   act. M6 settles what crossing them does. M3.3 keeps the accounting: the write's byte
   count, the bytes and writes outstanding, and the check that the core keeps no
   response bytes once the write is issued.
6. **Also settled here, as defaults shown to the owner with the decision:**
   - the status line always says `HTTP/1.1` (RFC 9110 §2.5);
   - a response the core originates has no body: `Content-Length: 0` and
     `Connection: close`;
   - a HEAD answered with no body gets no `Content-Length`, because the length a GET
     would get is unknown (RFC 9110 §8.6);
   - an HTTP/1.0 keep-alive request gets `Connection: keep-alive` back, which
     HTTP/1.0 clients such as ApacheBench's `-k` look for.

The alternatives weighed:
- for the Date:
  - no Date in v1, recording the MUST as unmet;
  - the handler's job, which leaves the core's own 400, 408, 414 and 431 without one;
- for a response that cannot be written safely:
  - repairing it silently: drop the handler's framing fields and replace CR, LF and NUL
    with spaces (RFC 9110 §5.5's rule for recipients). A handler bug would reach the
    wire changed, and unannounced;
  - trusting the handler's framing, as Node does. A `Content-Length` that disagrees
    with the body desynchronizes the connection: the client reads the next response as
    part of this one's body;
- for the watermarks: landing the fields in M3 as plan §3 said, with a read-stop no
  test can reach until M6.

## Consequences

- The core stays clockless, and a Date costs it nothing per response.
- A handler's response keeps one framing, and one `Connection` field, on the wire. A
  handler author sees a 500, and the log names what was refused.
- A body the status or the request forbids (HEAD, 204, 304, a 2xx to CONNECT) is not
  written. That is the brief's body suppression, not a fault. Only HEAD announces the
  length.
- Decision 0005's watermark row carries a dated note, and plan §3 and §7 say the pair
  moved to M6.
- Tests: `tests/test-serializer.sps` (M3.1). Mutations are in
  `.superpowers/sdd/m3-mutations.md`.
