# Gap analysis: chez-httparse v0.2.0 against a chez-http-server connection layer

Library under test: `/Users/yuzu/github/chez-httparse` (v0.2.0, generated parser at
`src/generated/httparse-message.sls`, built and importable at the time of this
analysis). Byte-machine runtime under test:
`/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls`.

Method: read the grammar source and the byte-machine runtime directly (never trusted
prose alone — the sibling projects' own ledgers record cases where prose drifted from
code, and this analysis found one such case, documented in item 1). Where a question
could be settled by running code, it was: `chez` 10.4.1 is on `PATH`
(`/opt/homebrew/bin/chez`), and every probe script below was run against the actual
committed, generated `httparse-message-machine` with:

```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src \
  chez --program <script>.sps
```

All probe scripts are preserved under
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/probe/`:
`flags-probe.sps`, `keepalive-probe.sps`, `eof-finish-probe.sps`,
`connect-trailer-probe.sps`, `pause-resume-probe.sps`, `pri-upgrade-probe.sps`.

Existing test files read as instructed:
`test/common/example-tests.sps`, `test/common/pausing-tests.sps`,
`test/common/message-loop-tests.sps`, `test/common/skip-body-tests.sps` (read but
superseded for evidence purposes by `response-framing-tests.sps`, `allocation-tests.sps`
and the live probes, which answer the task's specific questions more directly),
`test/common/response-framing-tests.sps`, `test/common/allocation-tests.sps`,
`test/support/harness/httparse/test/drive.sls`.

---

## 1. Is `should_keep_alive` computed by the grammar, or must the server compute it?

**Both, in a sense — and this is the sharpest gap in the library.**

The grammar *does* implement llhttp's `should_keep_alive` internally, at
`src/httparse/grammar.sls:2436–2485`. The comment block at
`src/httparse/grammar.sls:2445–2461` states the algorithm verbatim:

```
;; `should_keep_alive` FOR A REQUEST is the version test and one flag:
;;
;;   major > 0 && minor > 0   ->   keep alive unless CONNECTION_CLOSE
;;   otherwise (1.0 or 0.9)   ->   keep alive only if CONNECTION_KEEP_ALIVE
;;
;; and THEN `return !llhttp_message_needs_eof(parser)` ...
```

and the actual nodes are:

```scheme
;; src/httparse/grammar.sls:2477-2485
(make-field-branch-node 'after-message 'nonzero (list 'http-major)
                        'amc-check-minor 'amc-old #f)
(make-field-branch-node 'amc-check-minor 'nonzero (list 'http-minor)
                        'amc-modern 'amc-old #f)
(make-field-branch-node 'amc-modern 'mask-any (list 'flags F-CONNECTION-CLOSE)
                        'amc-close (needs-eof-entry "amc-eof") #f)
(make-field-branch-node 'amc-old 'mask-any (list 'flags F-CONNECTION-KEEP-ALIVE)
                        (needs-eof-entry "amc-eof") 'amc-close #f))
(needs-eof-nodes "amc-eof" 'amc-close 'amc-keep-alive)
```

**But the decision is never handed to the embedder.** There is no callback for it (it
is not one of the 25 declared callbacks — `docs/api.org:101-120`), no `parser-result`
field for it (`docs/api.org:54-58` lists only `status`, `consumed`, `stream-offset`,
`error`, `pause`), and no exported procedure anywhere in the tree:

```
$ rg -n "define.*keep-alive|should-keep-alive|export.*keep" src/ -tsls
(no matches)
```

Instead, the outcome only shows up as *which internal node the parser lands on*:
`amc-keep-alive` → `restart-clear-flags` → … → `'start` (grammar.sls:2493-2500,
2519), or `amc-close` → `closed-clear-flags` → `'closed` (grammar.sls:2502,
2511-2528). `'start` is the machine's entry node and `'closed` is a byte-dispatch node
that eats CRLFs and then either swallows or refuses further bytes
(grammar.sls:2519-2528, see item 3).

### What a connection layer can actually do

**Option A — replicate the algorithm.** All the inputs are readable, and — critically
— they are still valid **inside `on-message-complete`**, because the flags reset
(`restart-clear-flags` / `closed-clear-flags`) happens *after* the
`on-message-complete` callback fires (grammar.sls:2430-2432 fires the event; the
keep-alive test and flags-clear happen afterward in `after-message` and its
descendants). Verified live:

```
$ chez --program flags-probe.sps
=== connection.md#9 fixture (Content-Length + Connection: close) ===
(status error flags-at-headers-complete 34 flags-at-message-complete 34 consumed 138 stream-offset 138
 error (closed-connection "Data after `Connection: close`" 138))
```

`flags-at-headers-complete` and `flags-at-message-complete` are identical (34 = 0x22 =
`F-CONTENT-LENGTH`(32) | `F-CONNECTION-CLOSE`(2)) — confirming a connection layer can
read `(parser-field-ref p 'flags)`, `(parser-field-ref p 'http-major)` and
`(parser-field-ref p 'http-minor)` from inside its `on-message-complete` binding and
compute the exact same answer the grammar computes internally, using the algorithm
quoted above. (Note: `docs/api.org:287` says `flags=%x` is printed in **hex** — the
apparent "flags=22" in `message-loop-tests.sps:204`/`176` is 0x22 = 34 decimal, not a
documentation bug; a naive decimal read of that trace line is the trap, not the
library.)

The exact flag bit values needed (`src/httparse/grammar.sls:301-319`):

| Name | Value (dec) | Value (hex) |
|---|---|---|
| `F-CONNECTION-KEEP-ALIVE` | 1 | 0x1 |
| `F-CONNECTION-CLOSE` | 2 | 0x2 |
| `F-CONNECTION-UPGRADE` | 4 | 0x4 |
| `F-CHUNKED` | 8 | 0x8 |
| `F-UPGRADE` | 16 | 0x10 |
| `F-CONTENT-LENGTH` | 32 | 0x20 |
| `F-SKIP-BODY` | 64 | 0x40 |
| `F-TRAILING` | 128 | 0x80 |
| `F-TRANSFER-ENCODING` | 512 | 0x200 |

None of these constants are exported from any library — they live only as internal
`define`s in `(httparse grammar)`, which is explicitly build-time-only
(`src/httparse/grammar.sls:1-5`: "BUILD TIME ONLY... never loaded by a running
parser"). A connection layer must **hardcode its own copy** of this table today (they
are llhttp's own numbers and are extremely unlikely to change, but there is no
supported, importable source of truth for them at runtime).

**Option B — read `parser-state-name` after the fact.** `parser-state-name` is
exported from `(byte-machine runtime)` (`runtime.sls:16-31`) and, empirically, is a
100% reliable proxy for the keep-alive decision once a message completes:

```
$ chez --program keepalive-probe.sps
--- state-name after message-complete, by keep-alive decision ---
HTTP/1.1, no Connection header (default keep-alive) => status=need-input state-name=start
HTTP/1.1, Connection: close                          => status=need-input state-name=closed
HTTP/1.0, no Connection header (default close)        => status=need-input state-name=closed
HTTP/1.0, Connection: keep-alive                      => status=need-input state-name=start
```

This matches llhttp's `should_keep_alive` exactly on all four of the cases
`test/common/message-loop-tests.sps` cites as measured (1.1 restarts, 1.1+close does
not, 1.0 without keep-alive does not; the fourth combination — 1.0 with keep-alive
restarting — has no strict fixture per `message-loop-tests.sps:13-17`/decision 0009,
but the probe above shows it does restart, `state-name=start`, consistent with the
algorithm). **However this is not a documented contract for this purpose.**
`docs/api.org` never mentions `parser-state-name` as a way to read the keep-alive
decision, and the runtime's own comment on it (`runtime.sls:592-594`) stresses it
"must name a source node, not a generated internal continuation" — i.e. its whole
contract is about being a *stable, generator-independent* name, not about being a
documented keep-alive oracle. Depending on `'start`/`'closed` specifically for this
purpose means depending on the grammar's internal node-naming scheme for something the
docs never promise it for.

**Verdict: partial.** The information is present and both derivable strategies work
(verified live), but there is no supported, single-call way to ask "should this
connection stay open?" — the task's suggested fix (export a `should-keep-alive`
procedure) is exactly right.

**Proposed upstream change:** export `httparse-should-keep-alive? : Parser -> Boolean`
from `(httparse modes)` or a new small module, callable from inside
`on-message-complete`, implementing exactly the `after-message`/`needs-eof-nodes`
algorithm (grammar.sls:2445-2485) against `parser-field-ref`. This removes the need
for every embedder to hand-copy the flag-bit table and the version/flag algorithm, and
removes the fragile alternative of keying behavior off `parser-state-name` internals.

---

## 2. Framing with neither Content-Length nor Transfer-Encoding

**Request: no body, message completes immediately.** `src/httparse/grammar.sls:2113-2120`:
a request with no `F-CONTENT-LENGTH`/`F-CHUNKED`/`F-TRANSFER-ENCODING` flags reaches
`needs-eof-nodes "ahc-eof"`, and `needs-eof-nodes`'s very first branch
(`grammar.sls:643-644`) is `(equal (list 'type TYPE-REQUEST) no ...)` — i.e.
`message_needs_eof` is hard-wired to false for every request, so the answer is always
"no body," landing on `message-complete-done` immediately after headers. Verified live
(`flags-probe.sps`, "plain Connection: close, no content-length" case): `GET /
HTTP/1.1\r\nConnection: close\r\n\r\n` returns `status=need-input` with no further body
bytes expected — the message is already complete after the blank line.

**Response: read until the connection's EOF, and — this is the gap —
`on-message-complete` never fires for it.** `src/httparse/grammar.sls:2130-2150`:

```scheme
;; llhttp's `body_identity_eof`: raise `finish` to SAFE_WITH_CB, open
;; the body span, and consume everything for ever. THE SPAN NEVER
;; CLOSES and there is no `message complete` -- `response/sample.md#19`
;; records `span[body]="hello world"` as its last line, and
;; `response/sample.md#5` records nothing after `headers complete` at
;; all. What ends the message is the CONNECTION...
(make-field-action-node 'body-eof 'store (list 'finish FINISH-SAFE-WITH-CB)
                        'body-eof-open #f #f)
(make-span-start-node 'body-eof-open 'body-span 'body-eof-consume #f)
(make-byte-dispatch-node 'body-eof-consume
  '() (make-edge 'body-eof-consume 'advance) 'body-eof-end #f)
(make-span-end-node 'body-eof-end 'body-span 'body-eof-stop #f)
(make-finish-node 'body-eof-stop #f)
```

Confirmed against the actual conformance corpus at
`test/common/response-framing-tests.sps:56-68` (`response/connection.md#4`): the
expected trace for `"HTTP/1.1 200 OK\r\n\r\nHTTP/1.1 200 OK"` ends at
`"off=19 len=15 span[body]=\"HTTP/1.1 200 OK\""` — **no `message complete` line at
all.**

I verified this is true not just "until more bytes arrive" but **permanently, even
across `parser-finish!`**, which the docs (`docs/api.org:300-308`) describe as the
proper way to tell the parser "the input has ended":

```
$ chez --program eof-finish-probe.sps
feed headers:        (status need-input state body-eof-consume)
feed body chunk 1:   (status need-input state body-eof-consume message-complete-fired 0 body-so-far "hello ")
feed body chunk 2:   (status need-input state body-eof-consume message-complete-fired 0 body-so-far "hello world")
now call parser-finish! (socket EOF):
  (status finished consumed 0 stream-offset 30 state body-eof-stop
   message-complete-fired 0 body-final "hello world")
calling parser-finish! AGAIN (already finished) -- lifecycle: finished
```

`message-complete-fired` stays `0` throughout. `parser-finish!` correctly flushes any
buffered body bytes through `on-body-data` and returns `status='finished`, but **the
completion signal for this one framing shape is `parser-finish!` returning
`'finished`, not `on-message-complete`.** This asymmetry is not documented anywhere in
`docs/api.org`'s Lifecycle section (`docs/api.org:285-308`), and is explicitly
unverified by the conformance corpus per `src/httparse/grammar.sls:2146-2148`/decision
0016 ("Reached only if an embedder calls `parser-finish!`, which the corpus driver
never does"). I traced the runtime side of this too: `byte-machine`'s own
`parser-finish-op!` (`byte-machine/src/byte-machine/runtime.sls:1421-1597`) walks the
`body-eof-end` (`span-end`, no callback attached since `on-body-data` has no
"complete" event — `docs/api.org:112,116-117`) straight into `body-eof-stop`, a plain
`finish` node (`runtime.sls:1453-1456`) — there genuinely is no code path that invokes
`on-message-complete` here. The `FINISH-SAFE-WITH-CB` field value stored at
`body-eof` (grammar.sls:2141) is never read by anything — I confirmed this negatively:

```
$ rg -n "'finish\b" src/httparse/grammar.sls | grep -v "FINISH-"
2506:      ;; `update('finish', FINISH.SAFE, lenientClose)` -- so a lenient parse
```

That's the only hit and it's a comment. No `field-branch`/`field-action` node ever
*reads* `'finish`; it is written (grammar.sls:981, 2141, 2493, 2502) purely so the
value is observable via `parser-field-ref` for llhttp-trace-compatibility (matching
llhttp's own `finish=N` trace field, per `docs/api.org` and the comment at
grammar.sls:714-718), and plays no role in byte-machine's own finish logic. The "CB"
in `FINISH-SAFE-WITH-CB` therefore currently promises something (a callback on finish)
that does not happen.

**Verdict: partial.** The framing decision itself (no body for a request, read-to-EOF
for a response) is correctly implemented and documented in spirit
(`docs/api.org:279-283` mentions `content-length` counts down, but says nothing about
the EOF-terminated case). What is missing is: (a) any documentation of the
"`parser-finish!` completes silently, no `on-message-complete`" behavior for this one
case, and (b) any assertion that it is actually implemented correctly, since the
corpus never exercises it.

**Proposed upstream change:** either (a) make `parser-finish!` invoke
`on-message-complete` for the `body-eof` framing when it reaches `FINISH-SAFE-WITH-CB`
(matching the field's own name and llhttp's real semantics, where `llhttp_finish`
*does* fire `on_message_complete` for exactly this case), or (b) if that is out of
scope for v0.1/v0.2, document explicitly in `docs/api.org`'s Lifecycle section that a
response with no framing header never calls `on-message-complete` and that
`parser-finish!` returning `'finished` is the only completion signal a connection
layer will see for it. Either way, add a corpus/unit case exercising `parser-finish!`
on this path — right now the "not exercised" caveat in `docs/api.org:304-308` applies
to `'error`/`'paused` finishes, but the far more common "clean EOF-terminated body"
finish is equally unexercised and is the one a real connection layer hits constantly.

---

## 3. The data-after-close error, and its lenient flag

Confirmed exactly as the task's "measured today" note describes. The declaration:

```scheme
;; src/httparse/grammar.sls:927-928
(make-error-declaration 'data-after-close 'closed-connection
                        "Data after `Connection: close`" #f)
```

`parser-error-code` on this error is the symbol `closed-connection`; `parser-error-reason`
is the string `"Data after \`Connection: close\`"`. It is reached from
`grammar.sls:2519-2528`:

```scheme
(make-byte-dispatch-node 'closed
  (list (make-byte-case (make-byte-set-matcher (list CR LF))
                        (make-edge 'closed 'advance) #f))
  (make-edge 'lenient-data-after-close 'advance) 'clean-eof #f)
(lenient-fork 'lenient-data-after-close 'data-after-close
              'closed 'e-data-after-close)
```

i.e. once the parser has decided (item 1) not to keep the connection alive, it enters
a `'closed` state that still eats stray CR/LF (so the blank line after a body doesn't
trip it — `message-loop-tests.sps:172-176`/`request/connection.md#9`), but any other
byte either (strict, default) produces the `closed-connection` error, **consuming that
byte first** so the error offset lands one past it, or (lenient) is silently discarded
and the connection stays in `'closed` forever.

The lenient flag is `data-after-close`, bit value **32** in `httparse-lenient-flag-bits`
(`src/httparse/modes.sls:38-49`), i.e. `(httparse-lenient-flags-value '(data-after-close))`.

Live confirmation, feeding a full HTTP/1.0 keep-alive-less request followed by a second
request in the same buffer:

```
$ chez --program keepalive-probe.sps
--- feeding two whole messages in ONE parser-feed! call ---
close, then a second GET follows anyway => (status error consumed 39 len 57 error closed-connection)
```

`consumed` (39) is well short of `len` (57): the first message (`GET /a HTTP/1.1\r\n
Connection: close\r\n\r\n`, 38 bytes) parses and completes cleanly, then the `'G'` of the
second `GET` is consumed as the "closed" byte and the error fires at offset 39 (one
past it), leaving the rest of the second request (18 bytes) unconsumed in the buffer.

**Consequence for the connection layer:** it must not feed bytes of a subsequent
pipelined request once it has determined (via item 1's logic) that the connection is
closing — either by stopping reads after such a message, or by accepting that any
further bytes on that connection will surface as a hard parser `'error` (not a graceful
stop) unless the `data-after-close` leniency is turned on. Given the corpus/conformance
guarantees are strict-mode-only, turning that leniency on is not something the
connection layer should do just to avoid this — the right fix is architectural: stop
feeding after a close-decided message.

**Verdict: present.** Everything needed is here and well-specified; no proposed
change beyond exporting the flag-bit table alongside item 1's `should-keep-alive?`
so a connection layer does not have to re-derive bit 32 by hand.

---

## 4 & 5. Pipelining, and pausing to stop after message N (with the resume/refeed idiom)

**A single `parser-feed!` call continues across message boundaries automatically,
firing `on-reset` between them, unless a callback pauses it.** Directly demonstrated by
the corpus-backed case `test/common/message-loop-tests.sps:92-151`
(`request/pipelining.md#1`, three pipelined requests fed as one buffer to one
`parser-feed!` call): the trace shows `"off=44 message complete"` immediately followed
by `"off=46 reset"` then `"off=46 message begin"` for message 2 — all inside that one
`parser-feed!` invocation (the `trace` helper there calls `parser-feed!` exactly once
over the whole buffer, `message-loop-tests.sps:42`). I reproduced the same shape live
with two pipelined `GET`s and no callback pausing:

```
$ chez --program keepalive-probe.sps
keep-alive, two GETs => (status need-input consumed 38 len 38 error #f)
```

`consumed == len`: both messages were consumed in the one feed call.

**To stop after message N, pause from `on-message-complete`.** This works exactly as
the task hypothesized. Live demonstration: bind `on-message-complete` to return
`callback-pause` the first time it fires, feed three pipelined requests in one call:

```
$ chez --program pause-resume-probe.sps
feed whole buffer, pause requested after message 1 =>
  (status paused consumed 19 next 19 stream-offset 19 pause-is-machine-pause? #f mc-count 1)
resume ack: feed-ready
feed remainder from parser-result-next =>
  (status need-input consumed 38 stream-offset 57 mc-count 3)
```

`mc-count 1` at the pause point proves the parser stopped *before* touching message 2
at all (no `on-reset`/`on-message-begin` for message 2 happened yet) — this is exactly
the ordering/backpressure hook the connection layer needs. `consumed` (19) marks
exactly where message 1 ended.

`pause-is-machine-pause?` is `(parser-error? (parser-result-pause r))` — `#f` here,
confirming the documented distinction (`docs/api.org:67-69`, and the project's own test
helper `drive-requested-pause?` at
`test/support/harness/httparse/test/drive.sls:45-54`) between a **callback-requested**
pause (reason slot `#f`) and the **machine's own** pause (upgrade/CONNECT, reason
slot a `parser-error`-shaped record — see item 7).

**Resuming and re-feeding the unconsumed tail.** `parser-resume!`
(`byte-machine/src/byte-machine/runtime.sls:1604-1619`) only flips the lifecycle
(`'paused-feed` → `'ready`, returning the acknowledgement symbol `'feed-ready`) — no
callback runs, matching `docs/api.org:296-298`. The caller must then call
`parser-feed!` again starting **not from wherever it likes, but from
`parser-result-next`**, the absolute byte offset into the *same* bytevector where the
parser actually stopped:

```
;; test/support/harness/httparse/test/drive.sls:70-78 (the project's own idiom)
(define (drive-feed! r p bv from to)
  (let loop ((at from))
    (let ((res (parser-feed! p bv at to)))
      (if (drive-requested-pause? res)
          (begin (trace-recorder-note-requested-pause! r (parser-stream-offset p))
                 (parser-resume! p)
                 (loop (parser-result-next res)))
          res))))
```

My probe reproduces exactly this and confirms it: resuming and re-feeding from
`(parser-result-next r1)` (19) through the end of the buffer correctly parses *both*
remaining messages in one further call (`mc-count` goes from 1 to 3).

**Gap: `parser-result-next` is not documented.** `docs/api.org:54-58` ("Reading the
result") lists only `parser-result-status`, `parser-result-consumed`,
`parser-result-stream-offset`, `parser-result-error`, `parser-result-pause` — it never
mentions `parser-result-next`, even though it is exported publicly
(`byte-machine/src/byte-machine/runtime.sls:18`) and is *exactly* the field the
project's own test harness uses to implement resume-and-refeed
(`drive.sls:77`, quoted above). Without reading byte-machine's runtime source (or this
harness file) directly, an embedder has no way to discover that this is the field to
use, and might incorrectly assume `consumed` (which is relative to the *feed*, not
necessarily the same number when `start` isn't 0) is what to add back onto `start`.
`parser-result-next` and `parser-result-consumed` happen to be numerically related in
these single-buffer, `start=0` examples but are documented as semantically distinct
things (`consumed` = "bytes taken from this feed"), and `next` is the one that is
actually safe to use as the next `start` argument regardless of what `start` was on
this call.

**Which callbacks may pause.** Per `docs/api.org:89-90`, every callback — span or event
— can answer `callback-pause`, and `test/common/pausing-tests.sps` exercises this for
`on_message_begin` (offset 0), `on_message_complete` (at the end), `on_header_field_complete`
(mid-message, and resumes correctly into the rest, `pausing-tests.sps:114-129`), and
`on_chunk_complete` (fires — and re-pauses — on *every* invocation, not just the first,
`pausing-tests.sps:130-150`). I additionally exercised `on-message-complete` pausing
live (above). `on-headers-complete` is additionally special in that it can pause *and*
answer `'skip-body` (item 6) — the one callback that is also a decision.

**Verdict: present**, and the mechanics work exactly as hoped, but item 5's
`parser-result-next` documentation gap is real and would cost a first-time embedder a
source-diving session to discover (as it cost this analysis).

**Proposed upstream change:** add `parser-result-next` to the "Reading the result"
table in `docs/api.org:54-58`, and add one worked example of the pause → resume →
re-feed-from-`next` idiom to the docs (today it exists only in the test harness, which
an embedder building a server is not expected to read).

---

## 6. `skip-body` from `on-headers-complete`

Works exactly as documented (`docs/api.org:92-99`) and as the grammar implements it
(`src/httparse/grammar.sls:1966-1974`):

```scheme
(make-callback-node 'headers-complete 'on-headers-complete 'after-headers
                    (list (list 'skip-body 'headers-complete-skip-body))
                    'after-headers #f)
(make-field-action-node 'headers-complete-skip-body 'set-mask
                        (list 'flags F-SKIP-BODY) 'after-headers #f #f)
```

Live confirmation, simulating a client parsing the response to a `HEAD` request (a
200 response claiming `Content-Length: 500`, immediately followed by a second,
independent response in the same buffer):

```
$ chez --program connect-trailer-probe.sps  (see keepalive-probe.sps 'skip-body' section)
HEAD-response skip-body => (status need-input body-bytes-seen 0 consumed 85 len 85)
```

`body-bytes-seen 0` confirms `on-body-data` never fires despite `Content-Length: 500`;
`consumed == len` confirms the parser correctly moved straight to the second message.
This is precisely the mechanism a client-side (or CONNECT-tunnel/response) embedder
uses: remember that the just-issued request was `HEAD`, and answer `'skip-body` when
its response's `on-headers-complete` fires.

CONNECT/upgrade-with-skip-body is a second, related path
(`grammar.sls:1996`, "ahc-upgrade-skip-body") that is explicitly *not* covered by
any vendored fixture — the grammar's own comment says so: "NO VENDORED FIXTURE ARMS
SKIP-BODY ON AN UPGRADE, so this arm is transcribed from `src/native/http.c`... the
corpus cannot vouch for it" (`grammar.sls:1993`). I did not independently probe
this specific combination (an upgrade request whose embedder also answers
`'skip-body`) since it is a narrow, unlikely-to-matter-for-v1 combination for
chez-http-server (a server does not usually need to *suppress* a CONNECT request's
own body while also upgrading it), but flag it as untested-by-anyone territory if the
connection layer ever exercises it.

**Verdict: present** for the mainstream case (HEAD-response body suppression);
**unclear/untested upstream** for the CONNECT-with-explicit-skip-body combination —
worth a smoke test in chez-http-server if that combination is ever reachable, since
upstream itself says the corpus can't vouch for it.

---

## 7. Upgrade and CONNECT: pause reasons, unconsumed bytes, and a real dispatch trap

**Two distinct pause/error reasons exist, and they are NOT delivered through the same
channel — this is a genuine trap for a connection layer.**

`'paused-upgrade'` (reason `"Pause on CONNECT/Upgrade"`,
`grammar.sls:941-942`) is the *machine's own pause* — a `make-pause-node`
(`grammar.sls:2062`: `(make-pause-node 'upgrade-pause 'after-message 'upgrade-paused #f)`)
reached after `on-message-complete` fires whenever `upgrade` is set
(`grammar.sls:2433-2434`). `upgrade` is set to 1 at `bhc-upgrade-yes`
(`grammar.sls:1961-1962`), reached for: a **request** whose method is `CONNECT`
(`bhc-check-connect`, `grammar.sls:1958-1960`), a **request** carrying both
`Connection: upgrade` and an `Upgrade:` header (`before-headers-complete` /
`bhc-upgrade-request`, `grammar.sls:1942-1946`), or a **response** carrying both of
those headers *and* status 101 (`bhc-switching`, `grammar.sls:1954-1955`) — a response
with those headers under any other status is merely an "announcement" and does **not**
pause
(`response-framing-tests.sps:300-320`, `response/connection.md#12`: a 200 with
`Connection: upgrade`/`Upgrade: h2c` and no body-framing header just falls through to
the ordinary read-to-EOF body path of item 2 and never completes or pauses at all).

This is delivered via `parser-result-status = 'paused` and `parser-result-pause`
(a `parser-error`-shaped record, `parser-error?` true on it), **with `parser-result-error`
staying `#f`** — confirmed live:

```
$ chez --program connect-trailer-probe.sps
--- CONNECT pause and unconsumed tail ---
CONNECT => (status paused consumed 55 total-len 68 leftover "TLSHELLOBYTES"
            pause-reason (paused-upgrade "Pause on CONNECT/Upgrade"))
```

Input was `"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\nTLSHELLOBYTES"`
(68 bytes total, 55 of which are the CONNECT request itself). `parser-result-consumed`
is exactly 55 — **the trailing 13 bytes ("TLSHELLOBYTES", the start of whatever the
client sent immediately after its CONNECT, e.g. a TLS ClientHello) are left
unconsumed in the caller's own buffer**, retrievable as `bv[consumed:len]` (shown
above via the `leftover` field, which is exactly that slice). This is the handoff
point: the connection layer stops feeding this buffer to the httparse parser
entirely, forwards `bv[consumed:len]` (plus anything read from the socket
afterward) verbatim to whatever now owns the raw byte stream (a WebSocket
frame reader, a CONNECT tunnel splice, an HTTP/2 handler, etc.), and the httparse
parser for this connection is simply not used again — the docs never say to call
`parser-resume!` here (and doing so would just return the parser to normal HTTP/1.x
framing, which is wrong for an upgraded stream).

**The h2c prior-knowledge preface (`PRI * HTTP/2.0`) is the trap.** Its declaration —

```scheme
;; src/httparse/grammar.sls:929-933
;; PRI's HTTP/2 preface. llhttp calls it a pause in the reason and
;; implements it as an ERROR, which is why this one has a number to
;; rename and the CONNECT/Upgrade pause does not.
(make-error-declaration 'pri-upgrade 'paused-h2-upgrade
                        "Pause on PRI/Upgrade" #f)
```

— warns, in its own comment, that this one is delivered as an **error**, not a pause,
despite having "pause" in both its code and its reason text. I confirmed this live
rather than trust the comment:

```
$ chez --program pri-upgrade-probe.sps
PRI/Upgrade (h2c prior-knowledge preface) =>
  (status error consumed 24 error-slot (paused-h2-upgrade "Pause on PRI/Upgrade" 24) pause-slot #f)
```

`status` is `'error` (not `'paused`); the reason lives in `parser-result-error`, and
`parser-result-pause` is `#f`. **A connection layer that dispatches "is this an
upgrade handoff?" purely by checking `(eq? (parser-result-status r) 'paused)` will
silently miss h2c prior-knowledge requests** and instead treat them as an ordinary
parse failure (which item 10's status-code mapping would then render as a `400`, when
the right behavior is almost certainly "hang up, or attempt an HTTP/2 handshake").
The correct dispatch has to check **both** channels: `parser-result-pause` for code
`paused-upgrade`, *and* `parser-result-error` for code `paused-h2-upgrade`.

**Verdict: present but sharp-edged.** All the information needed is here and matches
upstream llhttp's own (admittedly inconsistent) behavior, faithfully reproduced. The
gap is purely one of *discoverability*: nothing in `docs/api.org` calls out that these
two "upgrade" outcomes arrive through different result channels.

**Proposed upstream change:** document this asymmetry explicitly in `docs/api.org`
next to the existing pause/error discussion (`docs/api.org:60-70`), and/or export a
single helper, e.g. `httparse-upgrade-reason : ParserResult -> (Option Symbol)`, that
checks both channels and returns `'upgrade`, `'h2-upgrade`, or `#f` uniformly, so a
connection layer has one place to ask "do I need to hand this socket off?" instead of
two.

---

## 8. Header limits: none, confirmed

No header-count or header-size limit exists anywhere in the grammar — confirmed both
by absence (no `content-length`-style counting field for headers, no `mask`/`compare`
node testing a header-section byte counter anywhere in `grammar.sls`) and live, by
feeding a 200,000-byte header value in one shot:

```
$ chez --program connect-trailer-probe.sps
--- 200000-byte header value, no configured limit ---
huge header => (status need-input header-value-bytes-seen 200000)
```

It parsed cleanly with no truncation, no error, no configuration knob consulted. This
matches the architecture doc's own stated division of labor
(`/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md:413-414`:
"maximum request sizes" and "maximum header sizes" are explicitly listed as connection-
layer, not parser, responsibilities).

**Verdict: present (as an absence) — working as intended, not a gap.** The connection
layer must count bytes itself in the span callbacks (`on-header-field-data`,
`on-header-value-data`, and for the request line, `on-method-data`/`on-url-data`) and
abort the connection (see item 10 for the right status code, 431) once a configured
budget is exceeded — most simply by returning `callback-pause` or a
`make-callback-failure` from inside the offending span callback once the running total
crosses the limit (both are legal outcomes from a span callback per
`docs/api.org:82-91`).

---

## 9. Chunked bodies: chunk-header/complete, extensions, and trailers

`on-chunk-header` fires with `content-length` already holding the decoded chunk size
(`grammar.sls:2225`, "the callback fires with the size still whole: the consume below
decrements the same field as it goes"); the chunk's data is delivered through the
**same** `on-body-data` span as a fixed-length body (`grammar.sls:2233-2238`, "the same
span and the same counted consume a fixed-length body uses... the corpus renders it as
`span[body]`") — a connection layer cannot tell "this body byte came from a chunk" from
`on-body-data` alone; if it needs to know, it has to track chunk boundaries itself via
`on-chunk-header`/`on-chunk-complete`. Chunk extensions are delivered via their own four
callbacks (`on-chunk-extension-name-data`/`-complete`,
`on-chunk-extension-value-data`/`-complete`, `docs/api.org:113-114`) — not probed live
in detail beyond what `pausing-tests.sps:151-178` already exercises (arming
`on_chunk_extension_name` pauses after the *complete* event, not the span, and its
value-data span fires normally afterward).

**Trailers are delivered as ordinary headers, through the ordinary header callbacks —
confirmed live and with full event ordering:**

```
$ chez --program connect-trailer-probe.sps
--- chunked trailers ---
trailers => status=need-input
message-begin
(header-field "Transfer-Encoding")  header-field-complete
(header-value "chunked")            header-value-complete
headers-complete
chunk-header                          ; chunk 1, len=5
(body "hello")
chunk-complete
chunk-header                          ; the zero chunk (len=0)
(header-field "X-Trailer")   header-field-complete
(header-value "value")       header-value-complete
(header-field "X-Trailer2")  header-field-complete
(header-value "v2")          header-value-complete
chunk-complete                        ; NOT headers-complete again
message-complete
```

This is exactly what `src/httparse/grammar.sls:1924-1930` and `2230-2231` implement:
the zero chunk sets `F-TRAILING` (`chunk-trailing-flag`, grammar.sls:2230-2231), and
the header-section's own blank-line node (`check-trailing`, grammar.sls:1924-1925)
branches on that flag to route to `trailer-chunk-complete` (grammar.sls:1930, which
fires **`on-chunk-complete`**, not a second `on-headers-complete`) instead of
`before-headers-complete`. **Important consequence
for a connection layer:** trailer fields are, at the callback level, indistinguishable
from ordinary headers unless the connection layer separately tracks "have I seen the
zero-length `on-chunk-header` yet" (or reads `(parser-field-ref p 'flags)` and checks
bit 128 = `F-TRAILING`) to know it is now accumulating trailers rather than headers. A
naive connection layer that stores every `on-header-field-complete`/`on-header-value-
complete` pair into "the request's headers" will silently merge trailers into the
header set, which is a request-smuggling-relevant distinction upstream servers
generally care about keeping separate (or rejecting outright, since RFC 9112 restricts
which fields trailers may legally carry).

**Verdict: present**, but worth flagging explicitly in chez-http-server's own design:
the parser does not distinguish trailers from headers in its callback shape, only in
`flags`; the connection layer needs to check `F-TRAILING` (or count `on-chunk-header`
calls) if it wants to keep the two apart, or forbid trailers outright by treating any
header activity after the first `on-chunk-header` as an error.

---

## 10. Error identity and a proposed HTTP-status mapping

`parser-error-code`/`parser-error-reason` return llhttp's own (code, reason) pairs,
deliberately, per decision 0013 (`docs/api.org:72-80`). I extracted the full set from
`src/httparse/grammar.sls:778-942` (message grammar, 41 declarations) and
`src/httparse/url-grammar.sls:216-229,498-499` (URL sub-grammar, embedded into
`on-url-data`'s validation per `docs/api.org:125-146`, 10 declarations), cross-checked
against the generated `errs` vector actually shipped in
`src/generated/httparse-message.sls:4` (61 entries, matching). Grouped by code:

| `parser-error-code` | Example reasons | Proposed HTTP status |
|---|---|---|
| `unexpected-eof` | "unexpected end of input" | **400** (or just close — a truncated message mid-stream isn't really "respond-able") |
| `unexpected-message-type` | "the embedder did not say..." | **500** — this is a chez-http-server bug (parser mis-constructed), never reachable from client input |
| `invalid-method` | "Invalid method encountered", "Expected space after method" | **400** |
| `invalid-url` | "Expected CRLF", "Invalid characters in url", "Double @ in url", etc. (11 reasons total, message + url sub-grammar) | **400** |
| `invalid-constant` | "Expected HTTP/, RTSP/ or ICE/", "Invalid method for HTTP/x.x request" | **400** (a non-HTTP method/protocol on an HTTP port) |
| `invalid-version` | "Invalid major version", "Expected dot", "Expected HTTP/2 Connection Preface" | **400**, except see `paused-h2-upgrade` below for the actual h2 preface case, which is not this code |
| `invalid-status` | "Invalid status code" (response mode only — see item 13) | **502/400** depending on whether chez-http-server is acting as a proxy parsing an upstream response, or a test harness |
| `cr-expected` / `lf-expected` / `strict` | the many CRLF-shape reasons | **400** |
| `unexpected-space` | "Unexpected space after start line" | **400** |
| `invalid-header-token` | "Invalid header field char/token/value char", "Unexpected whitespace after header value" | **400** |
| `unexpected-content-length` | "Duplicate Content-Length" | **400** (RFC 9112 §6.3 explicitly calls this a smuggling vector — never 200) |
| `invalid-content-length` | "Content-Length overflow/empty/invalid char", "...can't be present with Transfer-Encoding" | **400** |
| `invalid-transfer-encoding` | "Empty Transfer-Encoding", "...can't be present with Content-Length", "Invalid `Transfer-Encoding` header value", "Request has invalid `Transfer-Encoding`" | **400** normally; consider **501** specifically for "Request has invalid `Transfer-Encoding`" (`request-invalid-te`, grammar.sls:880-881) since RFC 9112 §6.1 recommends 501 for a transfer-coding the server doesn't understand — but note this code is also used for pure syntax errors in the header value, which *are* 400s, so this would need splitting upstream (see below) to map cleanly |
| `invalid-chunk-size` | "Invalid character in chunk size", "Chunk size overflow" | **400** |
| `closed-connection` | "Data after \`Connection: close\`" (item 3) | Not a response at all — the connection is already closing; just drop the bytes / close harder. If a status must be picked for a log line, **400**. |
| `paused-h2-upgrade` (arrives via **`parser-result-error`**, not `-pause` — item 7) | "Pause on PRI/Upgrade" | Not really an "error" — either attempt an HTTP/2 handshake, or if unsupported, **505 HTTP Version Not Supported** is the closest honest fit (RFC 9110 §15.6.6) |
| `paused-upgrade` (arrives via **`parser-result-pause`**, item 7) | "Pause on CONNECT/Upgrade" | Not an error at all — **101 Switching Protocols** / **200** (for CONNECT) is the response, and the raw stream is handed off (item 7) |
| — (no parser code; server-invented) | header section or request line exceeds a configured byte budget (item 8) | **431 Request Header Fields Too Large** |
| — (no parser code; server-invented) | body exceeds a configured byte budget | **413 Content Too Large** |

Notes on the mapping:

- **`invalid-transfer-encoding` conflates two different failure classes** (pure
  header-value syntax errors vs. "this Transfer-Encoding value is syntactically valid
  but semantically wrong/unsupported," e.g. `request-invalid-te`,
  `grammar.sls:880-881`, "Request has invalid `Transfer-Encoding`" for a request whose
  final coding isn't `chunked`). A connection layer that wants to distinguish 400 from
  501 here cannot do it from `parser-error-code` alone and would need to switch on the
  **reason string**, which decision 0013 explicitly discourages relying on alone
  (`docs/api.org:78-80`: "the code/reason pair is llhttp's, deliberately... so a
  caller can switch on the symbol and log the text" — implying the symbol, not the
  text, is meant to carry the decision). This is a minor upstream request: split
  `request-invalid-te`'s declaration onto its own code (e.g.
  `unsupported-transfer-encoding`) so a 501 decision doesn't require string-matching
  the reason text.
- **431/413 have no parser-side representation at all**, by design (item 8) — these
  are pure connection-layer policy and the mapping table above should say so
  explicitly in chez-http-server's own code/docs so nobody goes looking for a
  corresponding `parser-error-code`.
- **`parser-error-domain`** (`byte-machine/src/byte-machine/runtime.sls:302-303`)
  distinguishes `'machine` errors (all of the above) from `'callback` errors
  (`byte-machine-make-callback-error/v1`, `runtime.sls:287-291`) — the latter carry
  whatever `code`/`detail` the connection layer's *own* callback supplied via
  `make-callback-failure` (e.g. for the 431/413 cases above, if implemented as a
  callback failure rather than a pause). A connection layer building this mapping
  table should switch on `parser-error-domain` first: `'callback` errors are its own
  invention and already know their own status code; only `'machine` errors need the
  table above.

**Verdict: present** (the raw material is complete and well-specified) but the mapping
itself is necessarily a chez-http-server-side artifact — nothing here is missing from
chez-httparse, except the minor `invalid-transfer-encoding` code-granularity request
above.

---

## 11. The method field: values and the name↔number table

`(parser-field-ref p 'method)` returns llhttp's own method number (not a list index —
`docs/api.org:274`), e.g. `POST` → 3, `PATCH` → 28 (confirmed both from the doc's own
worked example, `docs/api.org:142-146`, and live in `message-loop-tests.sps:150`,
`"headers complete method=28"` for a `PATCH` fixture).

The table lives in `src/httparse/grammar.sls:155-186`:
`httparse-method-names` (47 names, alphabetical) and `httparse-method-numbers` (an
alist, name → llhttp's number, *not* alphabetical order — `grammar.sls:164-173`
explains the map is assembled from eight upstream sub-maps and the numbering is
llhttp's own, checked against the corpus). **Both are exported from `(httparse
grammar)`** (`grammar.sls:100-105`), so they are technically reachable at runtime.

**But `(httparse grammar)` is explicitly documented as build-time-only:**

```
;; src/httparse/grammar.sls:1-5
;;; (httparse grammar): the HTTP/1 grammar, as a byte-machine source machine.
;;;
;;; BUILD TIME ONLY. This library constructs the source IR; it is never loaded
;;; by a running parser. A generated parser depends on (byte-machine runtime)
;;; and nothing else.
```

and it imports `(byte-machine graph)` (`grammar.sls:106`) — the IR/verification
construction library, not something a running server should carry as a dependency. A
connection layer that wants to render `(parser-field-ref p 'method)` back into
`"PATCH"` for logging/access-log/routing purposes today has two bad options: (a)
import `(httparse grammar)` anyway, violating the library's own stated layering and
pulling in `byte-machine graph`, or (b) hand-copy the 47-entry table into
chez-http-server's own source (easy to do, but now a second copy of llhttp's numbering
to keep in sync, with no compiler-enforced link to the original).

There is also **no reverse (number → name) table exported at all** — `httparse-method-numbers`
is name → number; the only number → name helper in the file, `method-number-name`
(`grammar.sls:267-268`), builds a *node-name symbol* for the generator's own internal
use (`"method-number-post"`, not `"POST"`) and is not exported.

**Verdict: partial.** The data exists and is correct, but there is no small,
runtime-safe module to get it from — exactly the situation `(httparse modes)` was
built to avoid for the type/lenient-flags case (`modes.sls:1-15` states this
explicitly as its whole reason for existing: "THIS LIBRARY IS PURE AND DEPENDS ON
NOTHING").

**Proposed upstream change:** extract `httparse-method-names` and
`httparse-method-numbers` (and add a `httparse-method-name : Nat -> (Option String)`
reverse lookup) into a new pure, runtime-safe module — e.g. `(httparse methods)` —
mirroring `(httparse modes)`'s pattern exactly, with `(httparse grammar)` importing
*it* rather than defining the tables itself.

---

## 12. Allocation per callback / per feed

Read from `test/common/allocation-tests.sps` (its own stated methodology,
lines 1-23: differential, not absolute — "feeding a megabyte does not allocate a
megabyte") and **run live** to get real numbers on this machine:

```
$ CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src:/Users/yuzu/github/chez-httparse/test/support/harness \
    chez --program test/common/allocation-tests.sps
httparse-harness: suite=property.allocation
httparse-harness: runtime=chez version=10.4.1 machine=tarm64osx mode=unknown os=darwin architecture=arm64
httparse-allocation: unknown whole-buffer small=6112B large=6160B ratio=100%
httparse-allocation: per-feed 50B message=404B  10043B message=384B
httparse-harness: summary suite=property.allocation runtime=chez mode=unknown cases=5 failed-cases=0 checks=9 failures=0 cleanup-failures=0 skipped=0 errors=0 status=0
```

Interpretation (bindings used are all no-ops, `allocation-tests.sps:34-61`, so this
measures the parser's own cost, not the embedder's):

- **Feeding does not allocate per body byte.** A whole-buffer parse of a 50-byte-body
  message costs ~6112 B total (this is dominated by one-time parser-record and
  internal-table setup cost, per the test's own methodology note,
  `allocation-tests.sps:86-89`, subtracted via an untimed warm-up pass); a
  200×-larger 10043-byte-body message costs only ~6160 B — a 48-byte difference for
  200× the body. Spans genuinely cost nothing per byte (`docs/api.org:5-7`, "It
  allocates nothing per byte, copies no spans").
- **Allocation is per `parser-feed!` call, not per byte or per span fragment.**
  Feeding the *same* two messages one byte at a time costs ~404 B/feed (short message)
  and ~384 B/feed (long message) — i.e. **roughly constant per call regardless of
  message length**, consistent with "each `parser-feed!` returns a result" being the
  dominant cost (`allocation-tests.sps:94-97`, comment) — the `parser-result` record
  itself (`byte-machine/src/byte-machine/runtime.sls:218-223`, a 7-element vector) plus
  whatever the reference/generated executor's own per-call bookkeeping costs.
- **Practical consequence for chez-http-server:** batch reads before calling
  `parser-feed!` — read as much as is available from the libuv `on-data` callback (up
  to the 64 KiB read buffer per the chez-libuv facts in the task) and feed it as one
  call, rather than feeding byte-at-a-time or in small fixed chunks. At ~390 B/call,
  feeding a connection one byte at a time would cost ~390 B *per input byte*, which is
  the one allocation pattern actually worth avoiding; feeding it in large chunks
  amortizes that ~390 B down to noise.

**Verdict: present**, with concrete, live-measured numbers rather than just the
qualitative claim from the test file's docstring.

---

## 13. The response-mode parser for a client/test harness

`(make-parser httparse-message-machine bindings ctx (list (cons 'type
(httparse-message-type-value 'response))))` is the whole difference — same machine,
same 25 callbacks, only the `type` field initial changes (`docs/api.org:169-184`).
This was exercised extensively above (items 2, 6, 7) and by
`test/common/response-framing-tests.sps` end-to-end against real corpus fixtures
(`response/connection.md#4-18`, `response/transfer-encoding.md#3-5`). Response-specific
behavior confirmed:

- `on-status-data`/`on-status-complete` fire instead of `on-url-data`/`on-url-complete`;
  `parser-field-ref p 'status-code` gives the three-digit code (`docs/api.org:275`).
- The five no-body status codes (100, 102, 103, 204, 304) are handled specially
  (`grammar.sls:2036-2045`) and **304 explicitly ignores its own framing headers** —
  confirmed live via the corpus fixture `response/connection.md#15`
  (`response-framing-tests.sps:117-148`): a 304 with `Content-Length: 10` reads *no*
  body and restarts immediately for the next message, `Content-Length` and all.
- 101 always pauses (item 7); other statuses with upgrade headers do not
  (item 7, `response/connection.md#12`).
- No Content-Length/Transfer-Encoding on any other status ⇒ read-to-EOF, no
  `on-message-complete` (item 2).

I found no response-mode-specific gap beyond what's already covered in items 2/6/7/10
(the `invalid-status` error code, and the note in item 10 that a
proxy/test-harness consumer of response mode needs its own status-code-for-a-broken-
upstream-response policy, which is naturally outside chez-httparse's remit).

**Verdict: present.** Response mode is a first-class, well-tested mode of the same
machine; no separate gap analysis is needed for it beyond the items above, which
already account for its differences.

---

## Summary of proposed upstream changes

1. Export a `should-keep-alive?`/`connection-will-close?` procedure (item 1) — highest
   value, since every connection layer built on this library will otherwise
   hand-copy the flag-bit table and the version/flag algorithm.
2. Either make `parser-finish!` fire `on-message-complete` for the EOF-terminated
   response body, or explicitly document that it does not (item 2) — currently
   silently unspecified and untested by the corpus.
3. Document `parser-result-next` in `docs/api.org`'s result table, with a worked
   pause/resume/re-feed example (item 5) — currently only discoverable by reading the
   project's own test harness source.
4. Document the `paused-upgrade` (via `parser-result-pause`) vs. `paused-h2-upgrade`
   (via `parser-result-error`) channel split explicitly, and/or provide one unified
   "does this result mean I should hand off the socket?" helper (item 7) — a real trap
   for anyone who dispatches on `parser-result-status` alone.
5. Give `request-invalid-te` (and any other reason that should map to a different HTTP
   status than its sibling reasons under the same code) its own `parser-error-code`
   (item 10), so status-code mapping doesn't require string-matching reason text.
6. Extract `httparse-method-names`/`httparse-method-numbers` (plus a number → name
   reverse lookup) into a new pure, runtime-safe `(httparse methods)` module, mirroring
   `(httparse modes)` (item 11) — currently only available via the explicitly
   build-time-only `(httparse grammar)`.

None of these block building chez-http-server today — every one of them has a working,
verified (in several cases live-tested) workaround documented in the corresponding
section above — but items 1, 2, and 7 are the ones most likely to cause a subtle
correctness bug (wrong keep-alive decision, a silently-never-completing response body,
a missed HTTP/2 upgrade) if the connection layer is built from `docs/api.org` alone
without reading the grammar source as deeply as this analysis did.
