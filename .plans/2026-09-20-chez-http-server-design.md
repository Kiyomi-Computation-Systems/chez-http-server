# chez-http-server design: the connection core, the shell, and where errors live

Date: 2026-09-20
Status: accepted — realises [the project brief](2026-09-19-chez-http-server-project-brief.md) and composes [decisions 0001–0008](decisions/)
Async model: [the options paper](2026-09-19-async-model-options.md), settled by the live spike ([`research/spike/spike-control-flow.md`](research/spike/spike-control-flow.md))
Corpora: [the test corpus survey](2026-09-19-test-corpus-survey.md)
Supersedes: [`chez-http-server-architecture.md`](chez-http-server-architecture.md) §§5–15 (the server layer). Its §§1–4 stay as background on layers that now live in chez-libuv, chez-httparse and byte-machine
Ledger: [`.superpowers/sdd/progress.md`](../.superpowers/sdd/progress.md); house rules in [`global-constraints.md`](../.superpowers/sdd/global-constraints.md)
Tree at the time of writing: M0 merged as `d0c522b` (2026-09-19) — the `Makefile`, Linux CI, five pinned submodules, `(http-server limits|headers|request|response)`, the `(testing)` bridge, 55 expected passes across five suites

The brief is the charter: what is built, in what order, and against which evidence.
The decision records settle one question each. Neither says how the parts compose
into a running system, and both deliberately stop short of mechanism. This document
is the third view. It **cites** decisions and does not re-argue them; it adds the
detail M2 needs to start.

Two rules govern the prose. Every number is quoted from the spike or a smoke program
with its date and platform stamp, never re-derived by arithmetic (global-constraints).
And where this document introduces something no decision record holds, the sentence
says so in bold — **introduced here** — and §9.3 collects them so a later ADR can
promote any that turn out contentious.

---

## 1. Goal and non-goals

**Goal.** A small HTTP/1.1 origin server library for Chez Scheme, assembled from four
libraries that already exist and are measured: chez-libuv v0.6.0 for transport,
chez-httparse v0.4.0 (over byte-machine v0.6.0) for the message grammar, uriparse
v0.4.0 for the request-target. This repository is the composition layer and nothing
below it (decision 0001).

What it owns:

| Concern | Where it lands |
|---|---|
| The connection state machine | `(http-server connection)` — `conn-step`, pure (0002) |
| Request and response records | `(http-server request)`, `(http-server response)` — shipped in M0 |
| Framing precedence, error → status | `(http-server decisions)` — pure tables (0001) |
| Limits and timeouts as data | `(http-server limits)` — shipped in M0 (0005) |
| Deadline dispatch | `(http-server wheel)` — a hashed timing wheel, one tick timer per loop (0005) |
| Accept, drain, shutdown | `(http-server server)` — `server-step`, same shape (0002 item 5) |
| The libuv shell and the scheduler | `src/http-server/private/` (0003) |

What it refuses, each a decision already taken:

- **Not a web framework.** Routing, middleware, sessions, templating and static files
  are downstream projects. The handler contract is `request → response`, with
  streaming and awaiting as explicit extensions of that contract (0001 item 3).
- **Not HTTP/2 and not TLS.** A transport record and one upgrade hand-off hook are
  the whole provision; an h2c preface is answered `505` and closed (0001 item 4,
  0006 item 2).
- **Not a parser.** chez-httparse is byte-exact against llhttp's 274 fixtures at
  every chunk size and carries no connection policy on purpose; keep-alive and
  needs-eof are decisions the *embedder* computes from the flags, which is what this
  repository is for.
- **Not a client and not a proxy.** The response direction of HTTP/1.1 is parsed only
  by the test client. Close-delimited response bodies complete at `parser-finish!`
  and an unsafe finish answers `invalid-eof-state` (chez-httparse #33 and #42); the
  server core reads the finish status alone on peer EOF, so neither is a branch in
  it (brief, risk 4).

**The one hard question is settled.** How Scheme meets libuv's asynchrony was
answered by six independent proposals, a live spike run twice per experiment, and
three judges. The answer is a hybrid — sans-I/O core, direct-callback shell,
coroutines only for handlers that await — and it is decisions 0002 and 0003. §5
states the discipline that falls out of it.

---

## 2. Decisions summary

Read as one narrative, the eight records say this.

The server is **a pure function with an interpreter around it** (0002).
`conn-step : ConnState × Event → (values ConnState (Listof Action))` allocates only
Scheme data, calls no chez-libuv or byte-machine procedure, and reads no clock — a
`tick` event carries `now`. The libuv shell is an interpreter of that action list.
The reason is not taste: chez-httparse fires its twenty-five callbacks synchronously
inside `parser-feed!` and requires an answer from each; byte-machine refuses a
re-entrant feed and poisons a parser whose callback escapes; chez-libuv refuses
`uv-run` from inside a callback. So every wait is an event that arrives later, and
nothing that can raise may run inside a parser callback.

The shell is **direct callbacks, and a scheduler exists only for handlers that
await** (0003). No continuation is ever captured under a C frame: Chez traps any
attempt to resume one as `attempt to return to stale foreign context`, a bare
`&assertion` that escapes `uv-run` unwrapped (spike E1a/E1b, E2a/E2b). A handler that
returns a response is finished with no scheduler involved. Engines, OS-thread
handlers and callback-captured `await` are rejected for v1 on measured hazards, and
the threads door is now open but untaken.

Pipelining is **strictly serial, with read-stop** (0004). At `on-message-complete`
the core pauses the parser, stops reading, retains the remainder, runs the handler,
writes, then resumes. The cap is a field of the limits record with default 1 —
`pipeline-cap` as shipped, `max-pipeline` in both records that name it (§9.4) — and the
ordering machinery stays in the core, so raising the cap is a setting and a test
rather than a redesign.

> *Amended 2026-09-25 (decision 0004's amendment "item 2: serial by design"):* v1 is
> serial by design. The core has no ordering machinery, the cap accepts only 1, and
> parse-ahead would be a new decision with its own design, since this document's
> states (§4.3) serve one message at a time.

Limits and timeouts are **bounded, nginx-style, and data** (0005). Deadlines live in
the pure state as `deadline` and `deadline-kind`; the shell keeps a hashed timing
wheel keyed by `(deadline div tick-ms)` and dispatches `(tick now)` only to
connections in expired buckets. One tick timer per loop is the only timer handle, and
it stops when the wheel empties. Every limit is overridable from the environment.

> *Noted 2026-09-27 (M5.1; decision 0005's amendment of that day):* `(http-server wheel)`
> fires by each deadline, not by its bucket. An advance to `now` fires exactly the
> deadlines at or before `now`; the bucket says only where to look, so a deadline later in
> the current bucket, or a revolution ahead in the same slot, waits. So no deadline fires
> before D, and a caller that advances every `tick-ms` fires it within
> [D, D + `tick-ms`]. It fires less than a tick late when a tick came in the tick before D.
> At most it fires a whole tick late, when D had already passed as the ticks began: a zero
> timeout, with the timer started at its arm. The instants are the loop's clock,
> `uv_now`, which never steps. Each connection keeps its own entry in the wheel, so
> arming and disarming allocate nothing.

> *Noted 2026-09-27 (M5.3):* both shells turn `arm-deadline` into the connection's
> entry at their clock's now plus the kind's limit (`limits-deadline-ms`), and
> `disarm-deadline` into its removal. A connection's first deadline, its idle one, is
> armed as it is adopted, since no action arms it. The libuv shell's one timer is made
> when a deadline is armed and the shell has none. It fires every `tick-ms`, is stopped
> by the first firing that finds the wheel empty, so an idle server sleeps, and is
> started again by the next arm. The shell keeps it until it has stopped listening and
> no connection is left, and then closes it. Each firing advances the wheel to the
> loop's now, ticks each connection whose deadline has passed, each under its own guard,
> and tells the server the time (§4.6's `tick`). A connection closed with no step of the
> core, or dropped by the reconciliation, leaves the wheel there, and one closing is not
> armed again. libuv reads `uv_now` once a turn, and what runs in the turn holds the
> loop, a handler above all, so the shell brings it up to date (chez-libuv's
> `uv-update-time!`, #28; decision 0008) as it adopts a connection, and before each arm
> and each write, whose Date it dates: a deadline armed after a hold runs from after it.
> The fake shell's clock and timer are the test's: its firing (`fake-shell-fire!`)
> ticks the connection only once its deadline has passed.

HTTP/1.0 is **supported**, an h2c preface is answered `505`, and upgrades leave
through **one hook** (0006). The 1.0 rules differ in three places — connections close
unless the client asks for keep-alive, chunked does not exist so an unknown-length
response is close-delimited, `Host` is optional — and all three are rows in tables,
not branches scattered through the core.

> *Amended 2026-09-25 (decision 0006's amendment "an upgrade is served, then the
> connection closes"):* v1 serves an upgrade request like any other and closes the
> connection after the response. The hook is the door M8 opens for a handler that takes
> upgrades. Only the HTTP/2 preface is answered `505`; `Upgrade: h2c` is an upgrade like
> any other.

Corpora are **vendored as data with provenance** (0007). llhttp is reached through
chez-httparse's own loader, chunker, recorder and comparator rather than copied;
libhtp's 102 connection streams come first among the rest because they are the only
found corpus carrying explicit packet boundaries. A ratchet manifest names every
fixture and gates movement in both directions.

Upstream asks were **filed and tackled first** (0008). Fourteen of them, verified
against source before filing, all landed and all released by the night of
2026-09-19: chez-httparse #32–#36 and #42, chez-libuv #18–#21, uriparse #9–#11 and
#18. Every dependency is pinned at a release tag. No workaround remains on the
request path; the one allocation v1 still accepts is the strict CONNECT target
validator, which has no collector path and parses fresh (CONNECT is rare and never on
the keep-alive hot path).

---

## 3. Module layout

### 3.1 The libraries

Pure libraries live directly under `src/http-server/` and may import only `(rnrs)`,
`(rnrs mutable-strings)`, `(byte-machine runtime)`, `(generated httparse-message)`,
`(httparse modes)`, `(httparse decisions)`, `(httparse methods)`, `(uri ...)` and this
project's own pure libraries. `(libuv ...)` and `(chezscheme)` appear only under
`src/http-server/private/`, in the tests, and in the `Makefile` (global-constraints).

> *Noted 2026-09-27 (M4.5):* `(rnrs mutable-strings)` joined the list for
> `(http-server view)`, what a handler sees of a request (decision 0012). `(rnrs)`
> leaves out `string-set!`, and the view fills the fresh strings it returns with it,
> as the serializer fills fresh bytevectors.

| Library | State | Imports beyond `(rnrs)` | Arrives |
|---|---|---|---|
| `(http-server limits)` | **shipped** | — | M0 |
| `(http-server headers)` | **shipped** | — | M0 |
| `(http-server request)` | **shipped** | — | M0 |
| `(http-server response)` | **shipped** | — | M0 |
| `(http-server decisions)` | to come | `(httparse decisions)` | M2 |
| `(http-server connection)` | to come | `(httparse decisions)`, `(httparse methods)`, `(uri collect)`, own | M2 |
| `(http-server serializer)` | to come | own | M3 |
| `(http-server wheel)` | to come | — | M5 |
| `(http-server server)` | to come | own | M4/M8 |
| `(http-server private adapter)` | to come | `(generated httparse-message)`, `(byte-machine runtime)` | M4 |
| `(http-server private shell)` | to come | `(libuv)`, `(chezscheme)` | M4 |
| `(http-server private scheduler)` | to come | `(chezscheme)` | M7 |
| `(http-server)` | to come | own + `private` | M4 |

Decision 0001's consequence list names every row above except one. **Introduced
here:** `(http-server serializer)`, M3's response writer. It is pure — it turns a
`response` record plus the connection's framing decision into a list of wire segments
for one `uv-write*!` — and it is separate from `(http-server connection)` because the
serializer is the one part of the response path that is a total function of its
arguments and can be tabled independently of any connection state.

Two naming facts worth stating once, because they are easy to get wrong:

- `(http-server decisions)` holds **framing precedence and the error-to-status map
  only**. Keep-alive and needs-eof are not ours: `should-keep-alive?` and
  `message-needs-eof?` come from `(httparse decisions)`, which mirrors
  `llhttp_should_keep_alive` and `llhttp_message_needs_eof` exactly, including the
  literal `major > 0 && minor > 0` version gate. M0 already imports them rather than
  copying them, with a pin test asserting `F-CONNECTION-CLOSE` = 2 and `F-SKIP-BODY`
  = 64 against llhttp's `FLAGS` enum.
- The architecture document calls the parser `chez-http1` and the generator
  `chez-byte-machine`. Those names never shipped. Everywhere in this project they are
  **chez-httparse** and **byte-machine** (decision 0001 item 5).

### 3.2 The one library path

`make build` assembles a single `CHEZSCHEMELIBDIRS` from `src`, `tests`, the four
vendored `src/` directories and `build/scheme-libs` (`Makefile:34-39`):

```
src : tests
    : vendor/chez-libuv/src
    : vendor/chez-httparse/src : vendor/chez-httparse/vendor/byte-machine/src
    : vendor/uriparse/src
    : build/scheme-libs
```

`tests` is on the path because the `(testing)` bridge lives there;
`build/scheme-libs` carries `(srfi :64)`, symlinked from the `chez-srfi` submodule by
`make deps` with the `%3a`-escaped name resolved to `:` for implementations that want
it. chez-libuv needs only its `src/` here because its C shim is located by an absolute
path baked into a generated `config.sls` at *its* build time.

**M1 obligation, found while writing this.** chez-httparse's harness libraries — the
ones decision 0007 says the corpus lane imports rather than copies — do not live under
its `src/`. They are at `vendor/chez-httparse/test/support/harness/`, which is not on
`LIBDIR_LIST` today. M1 adds that directory to the path (and, since it is a test-only
path, `make check-imports` continues to see nothing new under `src/http-server/`).

### 3.3 The checks that hold the layout up

Prefer a check to a comment (global-constraints), so each of these is a make target
or a test rather than a paragraph:

- `make check-pins` fingerprints all five gitlinks against their pinned commits —
  chez-libuv `ad4c1e9` (v0.6.0), chez-httparse `1cddba8` (v0.4.0), uriparse `611b04b`
  (v0.4.0), byte-machine `0245db3` (v0.6.0, nested under chez-httparse), chez-srfi
  `7879b52`.
- `make check-imports` is a negative grep asserting that no `(libuv ...)` or
  `(chezscheme)` import reaches a pure library under `src/http-server/` outside
  `private/`. It is the M0 realisation of the import-audit lane, and it is a
  prerequisite of `make test`.
- `make check-help` fails if any `.PHONY` target is undocumented in `make help`.
- From M4: an `rg` gate asserting that `connection-close!` is the only `uv-close!`
  caller, and that handler-facing libraries export no `uv-*` name (0003; brief M4).
  *Amended 2026-09-26 (M4.3, decided by form):* with the listener the shell closes
  three kinds of handle: a connection's, the listener, and one the server refused.
  One procedure closes all three, `handle-close!`, the one `uv-close!` call, and what
  a close does follows the handle, not the caller: a connection's close takes it out
  of the table and reports `closed`, whoever asked for it. The check is a suite,
  `tests/test-close-ownership.sps`, which reads the source with Chez's own reader.
  The `rg` and awk scan it replaces missed a use after a `;` in a string or a `#\;`,
  and two uses one character apart.

### 3.4 The test-harness bridge

`(testing)` (`tests/testing.sls`) is a thin bridge over SRFI-64 — the framework
global-constraints names — that maps a suite to the project's exit-status vocabulary,
because SRFI-64 sets no process status:

| status | meaning |
|---|---|
| 0 | every assertion passed **and at least one ran** |
| 1 | one or more assertions failed, or unexpectedly passed |
| 2 | harness / configuration / registration error, **including an empty selection** |
| 3 | provenance failure, raised by `provenance-failure` |

Empty selection is failure at every layer: a suite that registers no assertion exits
2, and `make test` itself exits 2 when the `tests/test-*.sps` wildcard matches
nothing. SRFI-64's one footgun — an exception inside a test expression is silently
turned into `#f` — is defended by discipline rather than code: assertions compare
against a value only success can produce, never `#f` and never bare truthiness. Each
suite is its own process with its own `(exit ...)`, capped by `timeout(1)` when one
is on `PATH`.

---

## 4. Lifecycle state machines

This is the section M2 implements. Decision 0002 fixes the shape and the vocabulary;
what follows fixes the states, the transitions and the order of actions.

```
  libuv callbacks ──► events ──► conn-step (pure) ──► actions ──► libuv verbs
        ▲                             │                               │
        └─────────────────────────────┴───────────────────────────────┘
              parser callbacks are events too, and `reply-parser` is
              the one action answered synchronously, in place
```

### 4.1 The vocabulary

**Events** (decision 0002 item 2, the full set — an unknown event is an assertion
violation, a test-caught bug and never a runtime path):

| Event | Carries | Raised by |
|---|---|---|
| `bytes-arrived` | `bv start end` | the shell's `on-data` |
| `eof` | — | `on-eof` (chez-libuv delivers EOF as its own callback, never as an error) |
| `read-error` | an errno **symbol** | `on-error` |
| `write-completed` | the byte count of the completed write | `on-write-done` |
| `shutdown-completed` | — | `on-shutdown` |
| `closed` | — | `on-close` |
| `tick` | `now` | the per-loop tick timer via the wheel |
| `parser-event` | callback name + payload | inside `parser-feed!` |
| `parser-result` | status, consumed, next, error/pause | after `parser-feed!` returns |
| `handler-responded` | a `response` record, or a reader (decision 0013, M6.1), and `credit` after it when the shell hands the reader its pieces on credit (M6.2) | the `call-handler` executor, and a reader's end |
| `handler-body-chunk` | `bv start end` | a streaming producer |
| `handler-body-end` | — | a streaming producer |
| `handler-failed` | the raised object | the executor or the coroutine trampoline |
| `body-credit` | a count | the handler's body sink |
| `shutdown-requested` | — | the signal watcher, via `server-step` |

**Actions** (same item, same completeness):

`reply-parser` · `feed-parser` · `resume-parser` · `write` · `read-stop` ·
`read-start` · `call-handler` · `deliver-body` · `deliver-body-end` ·
`notify-producer` · `arm-deadline` · `disarm-deadline` · `shutdown` · `close` · `log`

### 4.2 The twenty-five parser callbacks

Every one of chez-httparse's callbacks arrives as a `parser-event`. They are all
**required** — a binding list with a hole is refused when the parser is made, not
quietly ignored — and there are exactly twenty-five:

| Spans (`bv from to`) | Their completions | Events with no span |
|---|---|---|
| `on-method-data` | `on-method-complete` | `on-reset` |
| `on-url-data` | `on-url-complete` | `on-message-begin` |
| `on-protocol-data` | `on-protocol-complete` | `on-headers-complete` *(state line)* |
| `on-version-data` | `on-version-complete` | `on-chunk-header` *(count line)* |
| `on-status-data` | `on-status-complete` | `on-chunk-complete` |
| `on-header-field-data` | `on-header-field-complete` | `on-message-complete` |
| `on-header-value-data` | `on-header-value-complete` | |
| `on-body-data` | — | |
| `on-chunk-extension-name-data` | `on-chunk-extension-name-complete` | |
| `on-chunk-extension-value-data` | `on-chunk-extension-value-complete` | |

Four facts about them that shape the core:

1. **Only `on-headers-complete` answers.** It returns `'skip-body` or nothing;
   pausing is allowed there because a resumed run re-enters the body decision exactly
   where an unpaused one would. Every other callback's outcome is
   `callback-continue`, `callback-pause`, or a `make-callback-failure`.
2. **Span bytes are not retained by the parser.** `[from,to)` indexes the bytevector
   *we* passed to `parser-feed!`; the parser copies nothing. What the core retains is
   its own decision — see §7.
3. **Flags, method, version and content-length are read inside
   `on-headers-complete`** (decision 0002 item 4), because the inter-message reset
   zeroes them: `parser-field-ref` answers `'method` `'status-code` `'http-major`
   `'http-minor` `'flags` `'content-length`, and `content-length` counts *down* as the
   body arrives, so read there it is the declared length and by `on-message-complete`
   it is zero. The event carries them forward; nothing downstream re-reads the parser.
   (2026-09-25) chez-httparse v0.4.1 also documents `'upgrade` (#47), llhttp's
   `llhttp_get_upgrade`: 1 when the message upgrades. It is read there too, and the
   core closes after an upgrade on it. The reset does not clear it, but before
   `on-headers-complete` it still holds the previous message's answer.
4. **`on-reset` fires between pipelined messages**, before the next
   `on-message-begin` and never before the first. It is the core's signal to roll the
   request accumulator, not a clock event.

### 4.3 Connection states

**Introduced here** — decision 0002 fixes the event and action vocabulary but names
no states. Nine, each with the deadline it arms (0005) and whether the socket is
being read:

| State | Reading? | Deadline armed | Meaning |
|---|---|---|---|
| `idle` | yes | `idle-timeout-ms` | open, keep-alive, nothing in flight |
| `head` | yes | `read-header-timeout-ms` | `on-message-begin` seen, head incomplete |
| `body` | yes | `body-inactivity-timeout-ms`, re-armed per `on-body-data` | head complete, body expected |
| `awaiting-credit` | **no** | none | a read's pieces handed to a reader on credit, not yet credited; reading waits for its credit (M6.2, 2026-09-28) |
| `handling` | **no** | none in v1 | parser paused at `on-message-complete`, handler running |
| `responding` | **no** | write deadline per completion | segments written, awaiting completions |
| `lingering` | yes | `linger-timeout-ms`, armed once | the last response written and the write side shut; what arrives is dropped until the client closes (decision 0011, M3.5, 2026-09-26) |
| `draining` | no | write deadline | last response written, close to follow |
| `handed-off` | no | none | an upgrade left through the hook; the core emits nothing further (M8's door, 2026-09-25) |
| `closing` | no | none | `close` issued, awaiting `closed` |
| `closed` | no | none | terminal |

Two notes. `handling` carries no deadline because decision 0005's table has no
handler-timeout row: a slow handler is the application's problem, and a client that
disappears during one is seen when reading resumes (0004 item 3). And `responding`
is entered even for an error response, with a `close-after?` flag in the state rather
than a separate `failing` state, because every error path in §6 ends the same way —
write a status, then close.

> *Noted 2026-09-25 (M3.4):* a status the core originates from `head` or `body` is
> written with the socket still being read. §4.4's rows for it list no `read-stop`, and
> M2 implemented them as written. `responding` feeds the parser nothing and answers
> nothing, so what arrives there is dropped, and the core closes as soon as the write
> completes (`tests/test-connection-originated.sps`). That is not RFC 9112 §9.6's staged
> close, and a client still sending loses the status: closing with its input unread
> makes the server's TCP stack send a reset (RFC 2525 §2.17), which erased a 431 already
> written in every run of the ledger's measurement (M3.4, 2026-09-25). On the owner's
> word the core closes in stages instead: after the status is written it asks for
> `shutdown`, reads on and drops what arrives, and closes when the client closes or a
> linger deadline passes. That lands as M3.5 (plan §7).
>
> *Corrected 2026-09-26 (M3.5):* the reset did not erase the 431. The measurement's
> spike counted a client that read the 431 and then met a reset as one whose read
> failed. Measured again, on Darwin and Linux, the client read it in every run. What a
> reset does lose is in decision 0011: a client still sending never reads the status,
> and the part of a response the kernel has not yet sent is thrown away.
>
> *Amended 2026-09-26 (M3.5; decision 0011, on the owner's word):* every close after a
> response is staged, the core's own statuses and a handler's close alike, in a tenth
> state, `lingering` (the row above). A close with no response is at once. And a state
> that reads stops reading when it refuses a request, so `responding` never reads, as
> the table says. The rows are §4.4's amendment below.

### 4.4 The transitions

The rows M2 writes as tables, one row per decision, each watched to fail first. The
happy path first:

| State | Event | State' | Actions |
|---|---|---|---|
| `idle` | `bytes-arrived` | `idle` | `feed-parser` |
| `idle` | `parser-event on-message-begin` | `head` | `reply-parser continue`, `disarm-deadline`, `arm-deadline header` |
| `head` | `parser-event on-header-*` | `head` | `reply-parser continue` (or `fail` on a limit, §6.3) |
| `head` | `parser-event on-headers-complete` | `body` | `reply-parser continue`/`skip-body`, `disarm-deadline`, `arm-deadline body` |
| `body` | `parser-event on-body-data` | `body` | `reply-parser continue`, `deliver-body`, `arm-deadline body` |
| `body` | `parser-event on-message-complete` | `handling` | **`reply-parser pause`**, `read-stop`, `disarm-deadline`, `call-handler` |
| `handling` | `handler-responded` | `responding` | `write` (the serializer's segments), `arm-deadline write` |
| `responding` | `write-completed`, more outstanding | `responding` | `arm-deadline write` |
| `responding` | `write-completed` (last), `close-after? = #f` | `idle` | `resume-parser`, `feed-parser` *pending*, `read-start`, `arm-deadline idle` |
| `responding` | `write-completed` (last), `close-after? = #t` | `closing` | `close` |

The `on-message-complete` row and the `close-after? = #f` completion row are decision
0004 item 1's cycle, and they are the whole of serial pipelining. Three details make
them work:

- **`pending-input` is retained from `parser-result-next`, not from `consumed`.** At a
  pause, `parser-result-consumed` *includes* the fragment delivered to the pausing
  callback and `next` points one past it, so a resume re-enters where an unpaused run
  would have gone. Measured on a three-message 117-byte buffer
  (`research/spike/pipeline-pause.sps`, 2026-09-19, Darwin arm64, Chez 10.4.1
  `tarm64osx`): `consumed 51` at the first `on-message-complete`, then `consumed 47`
  at the second (stream offset 98), with `on-reset` between them and
  `flags 32` then `flags 2` seen at the two `on-headers-complete` calls.
- **`read-stop` is emitted at the pause, not at the `call-handler`.** They are one
  step, so a delivery that carried two messages cannot produce a second
  `call-handler` before the first response is written.
- **After a close-marked message the core stops feeding** (0004 item 4).
  `bytes-arrived` in `draining` produces no `feed-parser`, and the parser's
  `closed-connection` error is ignored if it fires first. That error is llhttp's, and
  the corpus records it as an error at the offending offset — which is the corpus
  telling us the second request is the connection layer's problem, not the parser's.

Termination and error rows:

| State | Event | State' | Actions |
|---|---|---|---|
| any reading | `eof` | `closing` | `close` (or finish the in-flight response first, from `responding`) |
| any | `read-error` | `closing` | `log`, `close` — no response |
| `head`/`body` | `parser-result status=error` | `responding` | `write` §6.5's status, `close-after? = #t` |
| `head` | `tick` past `header` deadline | `responding` | `write` 408, `close-after? = #t` |
| `idle` | `tick` past `idle` deadline | `closing` | `close` — **no response** (0005) |
| `handling` | `handler-failed` | `responding` | `write` 500, `close-after? = #t`; bare `close` if the head is already on the wire |
| `head`/`body` | `parser-result` hands off | `handed-off` | `read-stop`, the hand-off hook (0006 item 3) |
| any | `shutdown-requested` | `draining` | finish in flight, `Connection: close` on the last response, then `shutdown` |
| `closing` | `closed` | `closed` | — |

> *Amended 2026-09-25 (decision 0006's amendment, M2.5):* the core's own flow never
> reaches the hand-off row in v1. The core pauses the parser at every message's end,
> before the parser's hand-off, and it closes after an upgrade's response, so the parser
> is never resumed onto the hand-off. The row is the door M8 opens: answering `continue`
> to on-message-complete brings the hand-off back in the same feed, with the source
> state `body` (`research/spike/upgrade-door.sps`). The error channel's hand-off, the
> HTTP/2 preface, arrives in `head` and is answered `505`, then close.

> *Amended 2026-09-25 (M3.2):* every entry into `responding` arms the write deadline, as
> §4.3's state table says, the rows above that write a status included: each is
> `write`, then `arm-deadline write`, which takes the place of a header or body deadline
> still armed. A response is written when a handler's comes back or when the core writes
> its own, and a client that stops reading is bounded either way (0005's
> `write-timeout-ms`, M5). M3.2 adds the rows for what a handler answers: a response
> the serializer cannot write safely is answered 500, then close, after
> `log invalid-response`, and a handler's `Connection: close` closes the connection after
> its response (decision 0010 items 2 and 3).

> *Amended 2026-09-26 (M3.5; decision 0011):* the staged close.
> - **The close row.** `responding`, `write-completed` (last) with `close-after? = #t`
>   enters `lingering`, not `closing`. Its actions are `shutdown`, `read-start` and
>   `arm-deadline linger`, and the pending input is still dropped.
> - **`lingering`'s rows:**
>   - `bytes-arrived` stays there and asks for nothing, so what arrives is dropped and
>     the deadline is not re-armed;
>   - `eof`, and a `tick` past the linger deadline, go to `closing` with `close`, naming
>     the reason the connection closes after its response;
>   - `read-error` goes to `closing` with `log` and `close`, as from every live state;
>   - `shutdown-completed` changes nothing.
> - **The rows that write a status from `head` or `body`** (a parser error, the header
>   deadline, the HTTP/2 preface, and every refusal) add `read-stop` after the
>   `write`, since `responding` does not read. A status written from `handling` does
>   not: reading stopped at the pause.

> *Amended 2026-09-27 (M5.2; decision 0005's table):* every deadline the core arms has
> its tick row. These three join the `head`, `idle` and `lingering` ones:
>
> | State | Event | State' | Actions |
> |---|---|---|---|
> | `body` | `tick` past `body` deadline | `responding` | `write` 408, `read-stop`, `arm-deadline write`; `close-after? = #t` |
> | `responding` | `tick` past `write` deadline | `closing` | `log write-timeout` with the bytes outstanding, `disarm-deadline`, `close` — **no response** |
> | `draining` | `tick` past the `idle` deadline carried from `idle` | `closing` | `disarm-deadline`, `close` — **no response**, as from `idle` |
>
> A write still outstanding at its deadline means a client that is not reading, so
> nothing more can be written to it. The close is at once, not staged, and names the
> write deadline, whatever the connection would have closed for after its response. It
> is logged, since nothing else would show it, with the bytes still outstanding. The
> write it cuts short is settled in `closing`, as one a read error cuts short is (M3.3).
> A connection that drains from `idle` had nothing in flight, and takes its idle deadline
> with it; the rows M8 writes for `draining` arm the write deadline there (§4.3).
>
> A tick means the wheel has let the connection's deadline go: an advance returns its
> keys already disarmed (decision 0005's amendment of 2026-09-27). So every tick clears
> the kind the state records, even where no row acts on it, and a row that keeps the
> connection arms what it needs. And every way the core lets a connection go disarms its
> deadline first. Every row that closes emits `disarm-deadline` before `close`, armed or
> not, and the hand-off row emits it before the hook. Until M5.2 the core cleared its
> record of the deadline there without saying so, which would leave a connection gone
> from the core in the shell's wheel until its deadline passed, up to 75 s (M5.1's
> review). `tests/test-connection-table.sps` checks both halves of the rule on every row:
> the kind the state records is what the row's actions leave armed, starting from nothing
> at a tick, and each kind a row leaves armed, ticked in the state it leaves, moves the
> connection on.

> *Amended 2026-09-28 (M6.1; decision 0013):* reading a body. A request whose head
> announces a body, chunked or a Content-Length above 0, is handed to the handler once
> the feed that completed its head has returned, and the handler answers with a response
> or a reader. The rows:
>
> | State | Event | State' | Actions |
> |---|---|---|---|
> | `head` | `on-headers-complete`, a body announced | `body` | `reply-parser continue`, `disarm-deadline`, `arm-deadline body`; the handler to be asked |
> | `head` | `on-headers-complete`, a declared length past `max-body-bytes` | `head` | `reply-parser (fail body-too-large)`, answered `413` |
> | `body`/`handling` | `parser-result` of that feed | the same | `call-handler` |
> | `body` | `on-body-data`, the answer to come | `body` | `reply-parser continue`, `arm-deadline body`; the piece kept |
> | `body` | `on-body-data`, a streaming reader reading | `body` | `reply-parser continue`, `deliver-body`, `arm-deadline body` |
> | `body` | `on-body-data`, a whole reader reading | `body` | `reply-parser continue`, `arm-deadline body`; the piece copied into its body |
> | `body` | `on-body-data` past a cap | `body` | `reply-parser (fail body-too-large)`, and the piece up to the cap to a streaming reader, or kept |
> | `body`/`handling` | `handler-responded`, a reader | the same | the pieces kept, as `deliver-body` (a whole reader's buffered), then `deliver-body-end` if the message has ended; `413` if the reader's cap is passed already |
> | `body`/`handling` | `handler-responded`, a response | `responding` | `write`, with `Connection: close`, `read-stop` from `body`, `arm-deadline write`; close-after `unread-body` |
> | `body` | `on-message-complete`, a streaming reader | `handling` | `reply-parser pause`, `read-stop`, `disarm-deadline`, `deliver-body-end` |
> | `body` | `on-message-complete`, a whole reader | `handling` | the same, the whole body as one `deliver-body` before the end |
> | `handling` | `handler-responded`, the reader's response | `responding` | `write`, `arm-deadline write` |
> | `handling` | `handler-responded`, a reader, for a request with no body | `handling` | `deliver-body-end` |
> | `body` | `parser-result` error, the handler not yet asked | `handling` | `read-stop`, `disarm-deadline`, `call-handler`; the error kept |
> | `body` | `handler-failed` | `responding` | `write` 500, `read-stop`, `arm-deadline write` |
>
> What the feed that completes a head meets of the body before the handler is asked waits
> for its answer, the pieces and an error or a cap passed alike, so the outcome never
> depends on how the bytes were split into reads (§8.1's second property): a reader is
> handed the pieces, then the error's status; a response is sent, the body not read, and
> the error not answered. `tests/test-connection-table.sps` holds each row (B1 to B19),
> and `tests/test-connection-body.sps` the flow at every delivery size.

> *Amended 2026-09-28 (M6.2; plan §14):* backpressure on the read side. Whether reading
> waits for a reader is the shell's to say, since the shell hands the pieces over: one that
> hands a streaming reader its pieces on credit answers with the reader and `credit`,
> `(handler-responded reader credit)`, as M7's coroutine shell will, handing each piece
> to the handler's coroutine. `(body-credit n)` then says the reader has taken `n` more
> bytes of what it was handed. v1's shells call a reader in place, as each piece is
> handed over, and answer with no word of credit, so for them reading goes on at once
> (decision 0013's consequences). Once a read's pieces are handed to a reader on credit,
> the connection waits in an eleventh state, `awaiting-credit` (§4.3's table): it reads
> nothing, and it arms no deadline, since the server, not the client, is the one waiting
> (plan §14's note of 2026-09-27). So a slow reader holds at most one read. A whole
> reader's pieces the core copies, so it owes none. The rows:
>
> | State | Event | State' | Actions |
> |---|---|---|---|
> | `body` | `parser-result` of a feed that handed a reader on credit pieces it has not credited | `awaiting-credit` | `read-stop`, `disarm-deadline` |
> | `body` | `parser-result` of such a feed, an error or a cap passed | `responding` | the status, as for any reader: the refusal, not the wait |
> | `body` | `handler-responded`, a reader on credit, pieces kept for it | `awaiting-credit` | the pieces as `deliver-body`, then `read-stop`, `disarm-deadline` |
> | `awaiting-credit` | `body-credit` covering what it was handed | `body` | `read-start`, `arm-deadline body` |
> | `awaiting-credit` | `body-credit` for part of it | `awaiting-credit` | — |
> | `body`/`awaiting-credit` | `body-credit` for more than it was handed and has not credited | — | an assertion violation: the grantor's bug |
> | `body`/`handling` | `handler-responded` with a word after the answer other than `credit` | — | an assertion violation |
> | `awaiting-credit` | `handler-failed` | `responding` | `write` 500, `arm-deadline write`; reading stopped already |
> | `awaiting-credit` | `bytes-arrived` | `awaiting-credit` | — nothing is fed |
> | `handling`/`responding` | `body-credit` | the same | — the message has ended, or the reader was let go |
>
> In `body`, nothing is owed once a feed has returned, since the core waits at the end of
> every feed that hands a reader on credit a piece, so only a credit of none is taken
> there. A read that ends the message hands its pieces over with the end, and waits for
> nothing: reading stops at the pause for the response, as for every message. A
> `read-error` in `awaiting-credit` closes, as in every live state, and a tick finds no
> deadline there. `tests/test-connection-table.sps` holds each row (C1 to C11);
> `tests/test-connection-body.sps` the flow at every delivery size, on a fake connection
> made on credit, reading what the reader was handed; and `tests/test-shell.sps`, on a
> libuv shell made on credit, the timer, which stops while a connection waits for credit
> and stays (plan §14's note of 2026-09-27, M5.3's), and a credit the core refuses,
> which closes the connection and raises to the caller.

> *Amended 2026-09-28 (M6.3; decision 0013 item 8; plan §14):* a streamed response. A
> response whose body is a producer, a procedure of no arguments the server calls for each
> piece, is written as its head, then a piece at a time. `notify-producer` asks the shell
> to call the producer; its answer comes back as `(handler-body-chunk bv start end)` or,
> at the end, `(handler-body-end)`, which the core's `producer-event` makes of it, and as
> `handler-failed` when the producer raises or answers what is neither a bytevector of a
> byte or more nor the eof object. Each piece is a write of its own, framed as the head
> framed the body:
> chunked to HTTP/1.1, close-delimited to 1.0 (M3.2's carried arm, below). The write
> water marks (decision 0005's amendment of this day) bound what is outstanding: the
> producer is asked only while the bytes outstanding are at or below `write-high-water`,
> so at most one piece passes it, and once past it, it waits until a completion brings
> them to `write-low-water`, and to the high water too, whatever limits the connection
> was given. Since the second review (below), the writes outstanding are bounded too:
> the producer is asked only while fewer than 64 are, and once at 64, again at 16 or
> fewer. The rows:
>
> | State | Event | State' | Actions |
> |---|---|---|---|
> | `handling`/`body` | `handler-responded`, a producer, a body written | `responding` | the head's `write`, `read-stop` from `body`, `arm-deadline write`, and `notify-producer` when the head leaves the bytes outstanding at or below the high water |
> | `handling` | `handler-responded`, a producer, HTTP/1.0 | `responding` | the same, close-after `close-delimited`, the head saying `Connection: close` |
> | `handling` | `handler-responded`, a producer, no body written (a HEAD, a 204, a 304) | `responding` | the head's `write`, `arm-deadline write`; the producer never called |
> | `responding` | `handler-body-chunk`, asked for | `responding` | the piece's `write`, `arm-deadline write`, and `notify-producer` at or below the high water with fewer than 64 writes outstanding; past either, the producer waits |
> | `responding` | `handler-body-chunk` of no bytes | — | an assertion violation: `producer-event` never makes one, an empty answer being the producer failing |
> | `responding` | `write-completed`, the producer waiting, at or below the low water and the high water, 16 writes or fewer outstanding | `responding` | `arm-deadline write`, or `disarm-deadline` with none outstanding; `notify-producer` |
> | `responding` | `write-completed`, the producer waiting, above the low water or the high water, or more than 16 writes outstanding | `responding` | `arm-deadline write` |
> | `responding` | `write-completed`, a piece asked for | `responding` | `arm-deadline write`, or `disarm-deadline` with none outstanding |
> | `responding` | `handler-body-end`, chunked | `responding` | the last chunk's `write`, `arm-deadline write`; the producer let go |
> | `responding` | `handler-body-end`, close-delimited | `responding`, or `lingering` with nothing outstanding | nothing, or the staged close; the producer let go |
> | `responding` | `handler-failed`, a piece asked for | `closing` | `disarm-deadline`, `close handler-failed`: no response, at once |
> | `responding` | `handler-body-chunk`/`handler-body-end` not asked for | — | an assertion violation: the shell's bug |
> | `closing` | `handler-body-chunk`/`handler-body-end` | `closing` | — the producer was let go |
>
> The response is written once its end has come and every write has completed, and then
> goes on as any response does: to `idle`, or to the staged close (decision 0011), which
> a close-delimited body always takes, the half-close being its end. With no write
> outstanding while a piece is asked for, no deadline is armed: the producer is the one
> waited on, and decision 0005 has no deadline for a handler. In v1 the shells call the
> producer in place, so its answer comes in the same drain. A failure once the head is on
> the wire gets a bare close, the handler-failed row's "bare `close` if the head is
> already on the wire": no status can be written after a head. The client of a chunked
> body sees it cut short, with no last chunk (RFC 9112 §8); a client of a close-delimited
> one cannot tell it from a whole one, and v1 does not reset the connection to say so
> (chez-libuv binds no `uv_tcp_close_reset`).
>
> *Reviewed 2026-09-28 (M6.3's /code-review):* an empty piece was first written as
> nothing, the producer asked again at once. A producer that answered one while it had
> nothing ready was then called again in the same drain for as long as it did, and held
> the loop, every connection's: on the fake shell, 99,998 calls in one delivery, until
> its dispatch cap. An empty answer is now the producer failing, the bare close. And a
> waiting producer was asked again at the low water alone, which `limits-with`, unlike the
> environment, may set above the high water; it is asked now at or below both.
> `tests/test-connection-table.sps` holds each row (S1 to S19); `tests/test-connection-stream.sps` the flows through the fake shell,
> read back by chez-httparse's response parser, with the bytes and writes outstanding
> watched at every ask and write; `tests/test-shell.sps` a MiB, and 4,000 rows of 100
> bytes, to a client that reads nothing yet, on a socket, and curl, in
> `tests/test-clients.sps`, both framings.
>
> *Reviewed again 2026-09-29 (M6.3's second review; decided on the owner's word, by
> form):* the empty piece was the limit of a slope the water marks did not see. They
> count bytes, but each piece is a write of its own, and a write holds the loop and
> memory the same whatever its size: its request, a `uv_write_t` of 192 bytes at libuv
> 1.52.1 on Darwin arm64, 16 bytes a segment, and chez-libuv's records. So a turn asked
> some 2,500 times for 100-byte pieces, and some 43,700 for 1-byte ones chunked. Measured
> on Linux (Debian 12's libuv 1.44.2, in Docker, aarch64), one run each, a client reading
> as fast as it could: another client's request waited 50.6 ms at the median behind
> 100-byte pieces and 1,019 ms behind 1-byte ones, 0.11 ms behind 16 KiB ones; and a
> client that never read held 0.71 MB of 100-byte pieces, 21.6 MB of 1-byte ones
> chunked, and 129.5 MB of them to HTTP/1.0, where the docs promised 256 KiB and a piece.
> The writes outstanding are now bounded at 64 as well, and a producer waiting at 64 is
> asked again at 16 or fewer (decision 0005's amendment of this day): on the final code
> the same run measured 0.91 and 0.90 ms, 0.07 MB of 100-byte pieces, no growth
> measurable of 1-byte ones, and 16 KiB pieces unchanged, 0.11 ms and 0.26 MB. And the
> violation `producer-event` raises names an answer that is no piece by its kind and
> length, `(string 100000)`, and never holds it: the shells log it, and a string answered
> for its bytes had put a 100,000-character page in a 100,141-character log line, 154
> characters now. The table holds the cap and its resume (S18, S19).

The hand-off row is the one that needs both channels checked. A CONNECT tunnel,
`Connection: upgrade` and a 101 arrive as `status = 'paused` with
`parser-result-pause` code `paused-upgrade`; the h2c preface `PRI * HTTP/2.0` arrives
as `status = 'error` with `parser-result-error` code `paused-h2-upgrade`, because
llhttp implements it that way. A plain `callback-pause` is also `'paused` but carries
**no** pause reason, and that is exactly how the core tells an ordinary pipelining
pause from a hand-off. chez-httparse's `docs/api.org` gives the two-channel check as
`result-hands-off-stream?`; it is embedder code, not an export, so it becomes a
procedure in `(http-server decisions)` with the doc cited beside it. Verified at the
pin by `research/spike/smoke-v040.sps` (ledger, 2026-09-19 night): the CONNECT and
Upgrade rows hand off with `hands-off? #t`, the h2c row too, and the plain pipelining
pause answers `#f`.

### 4.5 Run-to-completion

Decision 0002 item 3, stated as the rule the shell enforces:

> `reply-parser` is the one action consumed synchronously, inside the parser callback
> that produced it. Every other action is queued while a feed is running and executed
> after the outermost `dispatch!` returns.

The mechanism is a depth counter incremented around `parser-feed!` **and** around
`drain!`, so an action executed during a drain cannot start a nested drain. §6.4 turns
this into a test rather than a comment, because the consequence of getting it wrong is
silent: byte-machine poisons a parser whose callback escapes, and chez-libuv swallows
the escape and re-raises it later — so a raise inside a parser callback would leave a
poisoned parser and a deferred condition with nothing connecting them.

### 4.6 `server-step`

The listener has the same shape (0002 item 5). Its events are `connection-arrived`,
`shutdown-requested`, `tick` and `connection-closed`; its actions are `accept`,
`refuse` (over `max-connections`), `close-listener`, `force-close-all` (at the
`drain-timeout` deadline) and `log`. Keeping it a second pure step rather than shell
code means SIGTERM drain is table-tested with a fake clock exactly as connection
timeouts are, and the connection table is reconciled against
`uv-loop-live-handles` at one place in the run loop.

*Noted 2026-09-26 (M4.3):* `(http-server server)` holds it, and the owner settled
three questions by form. The state is the phase, `listening` or `draining`, and the
refusals of the episode under way; linear, like a connection's. The step keeps no
count of connections: the shell hands it the table's size with each arrival,
`(connection-arrived n)`, so no second count can drift from the table. An arrival is
always answered first, since libuv has already taken it off the socket and stops
watching the listener until it is accepted: accepted while fewer than
`max-connections` are open, otherwise refused, and closed at once, as nginx closes one
its `worker_connections` cannot hold. A refusal episode is logged twice at most: its
first refusal, then its count, when a connection is next accepted or the server stops
listening. `shutdown-requested` closes the listener, and so does a fifth event,
`listener-failed`: libuv reports a listener's failure only on Windows, where the
listener has stopped, and the server then shuts down, logged, so a supervisor starts
it again. A connection that arrives while draining is refused. M8 writes the rest of
the drain: the connections told to finish, `force-close-all` on a tick at the
deadline, and the drain's end on `connection-closed`. Until then a tick and a close
ask for nothing.

---

## 5. Callback discipline

Decision 0003 is the rule; the spike is why. Everything in this section is measured
on **Darwin arm64, Chez Scheme 10.4.1 `tarm64osx` (threaded), libuv 1.52.1,
2026-09-19**, every experiment run in its own process under `gtimeout`, twice.

### 5.1 The constraint

chez-libuv delivers every callback from inside a `foreign-callable` invoked by
libuv's C code, deep inside `uv_run`. Chez's rule for that situation (CSUG §4.4,
fetched and quoted verbatim in the spike) is that it traps attempts to return to
stale foreign contexts rather than restricting continuations directly. Measured:

| Spike | What was tried | Result |
|---|---|---|
| E1a / E1b | `call/1cc` captured in timer A's callback, invoked from timer B's callback or from top level after `uv-run` returned | `attempt to invoke shot one-shot continuation`, then `attempt to return to stale foreign context` — a bare `&assertion` escaping `uv-run` unwrapped; the loop survives and teardown works |
| E2a / E2b | the same with full `call/cc` | the callback body *does* resume, then the stale-context trap at the trampoline's return to C; the continuation includes `uv-run` and the rest of the program, so top level re-runs (the unguarded first attempt looped until the runner's output cap killed it) |
| E2c | is the loop usable afterwards? | yes — 2 live handles, a new timer fires, `uv-run #2 -> #f`, teardown ok |
| E6 | `uv-run` from inside `on-data` | `&uv-invalid-argument`, `who = uv-run`, `reason = loop-running`, raised synchronously at the call site, identical for `'nowait`, `'once` and `'default` |

So: **no continuation is ever captured under a C frame.** Not as a style preference —
as the thing the implementation traps.

### 5.2 What the shell does instead

The connection shell registers a fixed set of library-owned closures for
`on-connection`, `on-data`, `on-eof`, `on-error`, `on-write-done`, `on-shutdown`,
`on-close`, the tick timer and the signal watcher (0003 item 1). Each builds an event
and calls `dispatch!`. None runs application code beyond a synchronous
`call-handler`, and none captures a continuation.

A handler that returns a response is finished with no scheduler involved. A handler
that calls `await` runs as a coroutine created and resumed **only** from the
scheduler's `drain-ready!`, whose turn is `drain-ready!` then `(uv-run loop 'once)` —
or `'nowait` when a coroutine yielded. Measured: coroutines resumed only from Scheme
frames work through three nested Scheme frames for timer, TCP `on-data` and
write-completion wake-ups, at **30–36 ns per pure suspend/resume** (E3b: 1,000,000
cycles in 30–36 ms, `call/1cc` and `call/cc` indistinguishable; the two-level
proposal's own harness measured 24 ns for `call/1cc`, 28–29 ns for `call/cc`), and
about **13 µs per full turn** when each cycle includes a 0 ms one-shot timer and one
`uv-run 'once` (E3: 10,000 cycles in 131–138 ms wall, 17–20 ms CPU, dominated by the
kernel poll since wall ≫ CPU). *The options paper's summary table attributes the 13 µs
to E3b; E3b's timed region contains no libuv, and the figure is E3's.*

A parked coroutine is resident only while parked: **3,449 B at 4 frames deep, 3,815 B
at 16, 5,635 B at 64** (two-level M3/A.3, 10,000 parked, measured after a full
collection). An idle keep-alive connection carries no coroutine at all.

### 5.3 The invariants, as checks

Decision 0003 item 2 adopts R1–R5 of the two-level proposal as checks, not comments:

- **R1** — callbacks run no user code and capture no continuation. A `phase` cell is
  `'in-uv-run` around `uv-run`; `await`, `spawn` and the coroutine trampoline assert
  `(eq? phase 'scheduling)`.
- **R2** — continuations are captured only on coroutine stacks entered from the
  scheduler, so no foreign context exists between the scheduler and any captured
  continuation.
- **R3** — a coroutine never returns normally; it ends by invoking the scheduler's
  continuation.
- **R4** — resume cells are one-shot. A second fulfilment is a recorded fault, not a
  second resume (the late-DNS-after-timeout case).
- **R5** — parser callbacks never await. The same `phase` cell is `'in-parser` during
  `parser-feed!` and `await` asserts it is not.

Two more from the same proposal are already project rules elsewhere: exactly one
procedure calls `uv-close!` on a connection handle (the brief's M4 `rg` gate), and v1
is single-threaded (§7.4).

`poll!` is the scheduler's single injection point, so scheduler tests script
"callbacks landed" batches and never load libuv. Each invariant gets a mutation that
turns a named test red: swap `'once`/`'nowait`; remove the one-shot check in the
resume cell; call a handler from inside `on-data`.

### 5.4 What was rejected, and by what

Decision 0003 item 3, with the evidence:

- **Engines.** They work from a top-level scheduler, but expiry *inside* a callback
  leaves `uv_run`'s C frames suspended and clears chez-libuv's `loop-running` flag
  through `dynamic-wind`, so a nested `uv-run` is accepted and re-enters libuv — 200
  nested runs, no crash, the invariant simply defeated (E4c/E4d). And every expiry
  inside `parser-feed!` poisons the parser: judge experiment J1 saw
  `poisoned-expiries=28` out of 28 slices on a 76-byte two-request buffer, with the
  next feed raising `&byte-machine-contract`. Preemption is not a v1 requirement.
- **OS-thread handlers.** A worker thread touching a loop handle corrupted the
  registry (E5b2: four runs, three failure modes, no success — a 5 s watchdog hang
  with lost data, `invalid memory reference` in `uv-run`, and
  `0 is not of type #<record type registry-entry>` at teardown).
- **Callback-captured `await`.** E1/E2 above. A disciplined variant that escapes
  rather than returns survives 1000 rounds and is unrefuted, but rests on never
  returning through the stale frame with a bare `&assertion` one mistake away; both
  judges that reran it excluded it on those grounds.

The threads door is **open and untaken**. chez-libuv v0.6.0 shipped both
prerequisites the same night (#19 `__collect_safe`, #20 `(libuv async)` with enforced
loop-thread affinity), so a worker pool behind the same event inbox is admissible from
this pin on — 1000 `uv-async-send!`s coalesced into 40–57 wakes
(`smoke-v060-async.sps`). v1 does not take it. The first route to scale remains
pre-fork worker processes sharing the listening socket through `uv-spawn!`'s
`inherit-stream`, because the reuseport bind flag answers errno −45 on macOS
(`smoke-v060-tcp.sps`) and is Linux/BSD-only.

> *Noted 2026-09-28 (chez-libuv v0.7.3, pinned):* a pool's senders no longer race the
> async's close. A send either completes before the close begins or is refused with
> `&uv-handle-closed` (chez-libuv #33), where before the handle had to outlive every
> sender, or a send could reach freed memory. A close still drops the wakes pending
> at it. v1 makes no async handle.

---

## 6. The condition hierarchy

The least-specified part of the architecture document (its §12 is four buckets and a
sentence) and the part M2 cannot start without. This section makes it concrete and
composes it with what the four dependencies actually do — which is four different
things.

### 6.1 The boundary rule

**Introduced here.** It follows from decision 0002 item 1, but no record states it:

> The pure core never raises and never catches. Every error it *knows* is a value in
> its state; every error it *answers* is an action — `write` a status, then `close`.
> R6RS conditions exist only in the shell and at the embedder-facing edge.

This is what makes the corpus replay possible with no sockets: a fixture that trips a
limit or a parser error produces a *different action list*, not a different control
flow, so the comparator sees it as data. It is also what keeps §4.5's run-to-completion
rule enforceable — a core that could raise would raise inside a parser callback.

The one exception is deliberate and stays: an unknown event reaching `conn-step` is an
`assertion-violation` (decision 0002 item 2). That is a test-caught bug, never a
runtime path, and it is not part of the hierarchy below.

### 6.2 What the dependencies hand us

| Library | On failure | Extensible by us? |
|---|---|---|
| chez-libuv | **raises**, ten condition types rooted at `&uv-error < &error`; type names *and* `make-uv-*` constructors are exported | **yes** — the only one |
| chez-httparse | **returns** a `ParserResult`; parse errors are data | n/a |
| uriparse | **returns** a `uri-parse-result` record; `ok? = #f` carries a code symbol and an absolute offset | n/a |
| byte-machine | **returns** on parse failure; **raises** `&byte-machine-contract` on a contract violation | no — private, not re-exported |

Three consequences worth naming:

1. **The parse layer never raises, so lifting its records into our vocabulary is our
   job.** `parser-result-error` and `uri-parse-error-code` are data. That lift is the
   natural home for the status mapping, and it belongs in the pure
   `(http-server decisions)` where it is a table test.
2. **chez-libuv is the only library we could structurally extend.** For the others we
   can only wrap: catch by predicate and re-raise inside our own type carrying the
   original as a field, the way `&uv-callback-error` carries its cause.
3. **Discriminants are symbols everywhere** — `uv-errno-error-errno` is `'ECONNRESET`,
   `parser-error-code` is `'invalid-transfer-encoding`, `uri-parse-error-code` is
   `'invalid-reg-name`, `byte-machine-contract-condition-code` is `'reentrancy`. Only
   chez-libuv also keeps a raw platform integer, and its own ADR-0006 says that is for
   logs and never for branching. A symbol-keyed table composes across all four —
   provided we keep the namespaces apart, since `unexpected-eof` is both a
   chez-httparse URL code and a uriparse scanner code, and `invalid-pct-encoded` is
   deliberately shared between `(uri charset)` and `(uri host)`.

### 6.3 The four families

Architecture.md §12's four buckets, made concrete.

**Transport.** chez-libuv raises `&uv-errno-error` with three fields — `errno`, a
portable Scheme symbol and the only thing to branch on; `code`, the raw platform int,
for logs; `message`, the `uv_strerror_r` string — composed with `&who` and `&message`,
and delivered to our `on-error` closure. **EOF is deliberately outside the hierarchy**
(chez-libuv's ADR-0006): it arrives as the separate `on-eof` callback, never as an
errno condition, so `UV_EOF` can never masquerade as a read failure. The shell turns
both into `read-error` (carrying the symbol) and `eof` events. Neither produces an
HTTP response; both close. A write failure arrives the same way, through the write
completion.

**Parser.** chez-httparse never raises. A failed feed returns a result with
`status = 'error` and a `ParserError` carrying `parser-error-code` — one of nineteen
symbols, one per llhttp error number — plus `parser-error-node-name`,
`parser-error-reason` and `parser-error-offset`. `(http-server decisions)` holds the
pure map:

- `invalid-transfer-encoding` splits **by node name**: `e-request-invalid-te` → `501`,
  every other node → `400`. This is chez-httparse #36's answer — the code stays one
  symbol per llhttp number by its decision 0013, and the split is documented in its
  `docs/api.org` as embedder code. Verified at the pin by `smoke-v040.sps` (ledger,
  2026-09-19 night): `pigeons` and `chunkedchunked` → 501, `chunked,deflate` and the
  empty-TE case → 400.
- every other code → `400`.
- then `close`, always. A parser error means the framing is no longer trustworthy.

> *Amended 2026-09-26, on the owner's word:* the split is gone. `invalid-transfer-encoding`
> is a `400` at each of its four nodes. No `chunked`, a coding after it and an empty value
> leave the body's length undetermined, which RFC 9112 §6.3 answers with a MUST 400; a
> `Content-Length` before the `Transfer-Encoding` is a request §6.1 lets a server refuse,
> then close. The `501` goes where §6.1 puts it, to a coding the server does not
> understand. When the parser frames the body by a final `chunked` (its `F_CHUNKED`
> flag) and the list names another coding, the parser accepts the request, so the core
> refuses it itself at `on-headers-complete`, as `unsupported-transfer-coding`
> (`(http-server transfer-coding)`), after the Host and the target. The flags decide
> which rule applies, so the core reads the codings only for a chunked body, and where
> `chunked` sits in the list is the parser's to judge. A request below HTTP/1.1 with
> `Transfer-Encoding` is refused, `400`, as `faulty-framing`, right after the Host (both
> are MUSTs): §6.1 says to treat an HTTP/1.0 message's framing as faulty, and RFC 9112
> answers faulty framing with a 400 and a close. nginx does the same; Go ignores the field
> and closes after. The parser-result event carries the error's code alone again. Measured
> first (ledger, 2026-09-26): nginx and Go answer 501 to anything but exactly `chunked`,
> and Node 20 answers 400 to every invalid one. chez-httparse's docs said Node answers
> 501; that was filed upstream as chez-httparse #50, and the docs fix landed in v0.4.2
> the same day.

**Never match the reason string.** An error's identity upstream is the `(code,
reason)` pair — the corpus has reasons sharing a code and one reason under two codes —
so the reason is for logs. Node names are documented as movable, so reach for
`parser-error-node-name` only to split *within* a code already matched.

**Policy — ours alone.** Limits and timeouts are not a dependency's business and never
arrive as anyone's error: the core generates them. Per decision 0005, `431` for header
bytes or count, `414` for the request-target, `413` for a body cap (only the buffering
helper takes one; bodies stream), `408` for the header and body-inactivity deadlines.
The idle deadline is the one that produces **no response at all** — it closes.

A limit tripped *inside* a parser callback is answered with `(reply-parser (fail
code))`, which makes the parser produce a callback-domain error. The status then comes
from the policy the core already holds, **not** from that callback error: the parser is
being told to stop, not being asked what went wrong.

**Application.** A handler raise is caught at the `call-handler` executor, or in the
coroutine trampoline for an awaiting handler, and becomes a `handler-failed` event
carrying the raised object (0003, consequences). The core answers `500` and closes — or
closes bare if the response head is already on the wire, because at that point there is
no status left to send. Application code never runs under a C frame, so chez-libuv's
store-and-reraise path is unreachable from a handler by construction.

### 6.4 The shell's own types, and the two hazards

**Introduced here.** A small hierarchy, defined in the shell and exported from the
facade, for what reaches the embedder:

```
&http-server-error < &error
  ├── &http-server-config-error     ; a malformed limit at startup
  └── &http-server-handler-error    ; field: cause — a handler's raised object
```

`&http-server-handler-error` is **composed with** the original condition, the way
chez-libuv composes `&uv-callback-error` — so a `guard` on the embedder's own type
still matches through our wrapper. `&http-server-config-error` names a seam that
exists today: `limits-from-environment` currently answers a bare
`assertion-violation` for a malformed value (`src/http-server/limits.sls:80`), which is
right for a pure library but leaves the shell nothing specific to catch at startup. The
shell wraps it.

> *Noted 2026-09-27 (M4.5):* `&http-server-error` and `&http-server-config-error` are
> defined in `(http-server private serve)` and exported from the facade. The start
> composes the config error with what refused the setting: the pure parser's
> assertion violation, whose irritants name the variable, or chez-libuv's
> `bad-address` at the bind, for a `CHEZ_HTTP_HOST` that is not an IP literal.
> `&http-server-handler-error` is not defined. In v1 a handler's raise is answered 500
> and logged as `handler-failed`, and never reaches the embedder, so the wrapper has
> nothing to carry until a path hands one to an embedder.
>
> *Noted 2026-09-28 (M6.3):* plan §14 left it to M6.3 to settle whether a failure after a
> response's head is on the wire must reach the embedder. It need not: a producer that
> raises, or answers what is not a piece, gets a bare close and is logged as
> `handler-failed`, as every handler's failure is (§4.4's M6.3 amendment). So the type is
> still not defined.

Two composition hazards, both found by reading the dependencies, both turned into
checks:

1. **`&byte-machine-contract` derives from `&condition`, not `&error`**
   (`byte-machine/src/byte-machine/private/conditions.sls:21`), and no public
   byte-machine library re-exports the type name or its constructor. A catch-all
   `(guard (e ((error? e) …)) …)` in the run loop would silently miss `reentrancy`,
   `poisoned-parser`, `lifecycle-violation` and `invalid-slice`. The run loop therefore
   guards on `condition?` with an explicit `byte-machine-contract-condition?` arm,
   importing `(byte-machine private conditions)` by name — and treats any of them as a
   **fatal bug signal**, not a runtime path: log, reconcile the connection table
   against `uv-loop-live-handles`, re-raise.

   > *Noted 2026-09-26 (M4.2):* for a raise inside a callback, the catch-all's type
   > does not matter. chez-libuv raises it again from `uv-run` composed with
   > `&uv-callback-error`, an `&error`, so both arms match, and the contract arm
   > must come first. The shell's run loop has it there. Its mutation log shows a
   > guard narrowed to `error?` and the two arms swapped each turn the check red.
2. **The two dependencies disagree about an escaping callback.** byte-machine catches
   nothing and marks the parser `poisoned` on any abnormal exit — its `dynamic-wind`
   exit thunk runs on both paths and only the abnormal one leaves the flag unset
   (`runtime.sls:1050-1057`); only `parser-reset!` revives it. chez-libuv does the
   opposite: `dispatch-guarded` catches *every* raised object, stores the first, stops
   the loop, and re-raises it later from `uv-run` wrapped in `&uv-callback-error`
   (`handles.sls:326-340`, `loop.sls:39-45`). So a raise inside a parser callback
   nested in a read callback is captured by libuv **while the parser is silently
   poisoned**, with nothing connecting the two. That is precisely why decision 0002
   item 3 lets only `reply-parser` run at parser depth.

   **The check:** a test asserts that no action other than `reply-parser` executes while
   the feed-depth counter is non-zero, and its mutation — execute the action queue
   inside the callback instead of after the outermost dispatch — turns it red.

`&uv-wrong-thread` needs no guard in v1: the shell calls no handle verb off the loop
thread, so it is in the same bug-signal class as `&uv-callback-error` (0003, the
2026-09-19 night note). Verified at the pin: the E5b re-run at chez-libuv v0.6.0 turns
the old silent cross-thread `uv-write!` into
`((raised (&uv-wrong-thread)) on-thread 1 at 28-30)` with the client receiving nothing
and the loop tearing down cleanly.

### 6.5 Status codes, in one place

Every status the server can originate, and who decides it:

| Status | Origin | Closes? |
|---|---|---|
| `400` | parser error, whatever the code; a request below HTTP/1.1 with `Transfer-Encoding` (RFC 9112 §6.1) (both since 2026-09-26) | yes |
| `408` | header or body-inactivity deadline (policy) | yes |
| `413` | a body past `max-body-bytes`, or past a reader's own cap, `read-whole-body`'s 1 MiB by default (policy; decision 0013, since 2026-09-28) | yes |
| `414` | request-target over `max-target-bytes` (policy) | yes |
| `431` | header bytes or header count (policy) | yes |
| `500` | handler raise | yes |
| `501` | a transfer coding before a final `chunked`, which the server does not implement (RFC 9112 §6.1; since 2026-09-26) | yes |
| `505` | the HTTP/2 preface (decision 0006 item 2; `Upgrade: h2c` only until its 2026-09-25 amendment) | yes |

Every originated status closes the connection. That is not a simplification to revisit:
each of them means either the framing is untrustworthy or a bound was exceeded, and in
both cases the remaining bytes on the connection cannot be interpreted safely. `100
Continue` is the one server-originated response that does *not* close, and it is not an
error — it is written only when the handler pulls the body (M6), which is when it answers
with a reader (decision 0013, M6.4).

---

## 7. GC and buffer-ownership invariants

Every figure below is quoted with its date and platform stamp and is not re-derived by
arithmetic. Unless said otherwise the stamp is **2026-09-19, Darwin arm64, Chez Scheme
10.4.1 `tarm64osx` (threaded), libuv 1.52.1**.

### 7.1 The read path copies out

This corrects the architecture document's §9, which assumed parser callbacks refer
directly into a libuv read buffer. At chez-libuv v0.6.0 they do not.

The binding allocates one foreign read buffer per stream and reuses it for every read,
but `on-data` receives a **fresh Scheme bytevector of exactly `nread` bytes**, copied
out of that buffer before the callback runs
(`vendor/chez-libuv/src/libuv/private/handles.sls:441` calling `copy-out`,
`private/native.sls:510-521`). The delivery is an ordinary GC-managed Scheme object
owned by the callback.

So the retention question is a **liveness** question, not a C-lifetime question, and
the answer is different from the one the architecture document anticipated:

- Retaining a `(bv from to)` span across callbacks is **safe** — the bytevector is
  reachable as long as the core holds the span.
- Retaining *any* span pins the **whole delivery**, up to `read-buffer-size` bytes.
- Therefore the core's rule: **retain spans from the fresh delivery for the head**
  (method, target, field and value bytes) and **copy only what must outlive the
  message** — the interned lower-cased header names, and `pending-input` when a paused
  message leaves a remainder. A message whose head spans two deliveries pins two
  bytevectors, which is the bound, not a leak.

This retention discipline is half of how the ≤ 3 KiB per-request gate is met; the other
half is the linear mutable accumulator that replaces the naive prototype's per-event
record copy.

### 7.2 The read buffer is allocated once and fixed

`uv-read-start!` takes an optional buffer size. The first start allocates the buffer;
a later start may restart without a size but **may not resize** — a different size is
refused `buffer-size-fixed` (`stream.sls:176-184`). The default is 65,536 bytes
(`stream.sls:142`) and it is committed the moment `uv-read-start!` runs, whether or not
a byte ever arrives, and is not reclaimed until close.

We pass `limits-read-buffer-size`, default **16,384**. chez-libuv's own measurement,
extrapolated to 10,000 connections (`vendor/chez-libuv/docs/api.md:149-152`, measured
in its `spike/flow/FINDINGS.md`):

| buffer | 200 connections | extrapolated to 10,000 |
|---|---|---|
| 4,096 | ~1.2 MiB | ~40 MiB |
| 16,384 | ~3.1 MiB | ~160 MiB |
| 65,536 | ~12.4 MiB | ~625 MiB |

That is the brief's standing risk 2, and the reason `read-buffer-size` is a limit
rather than a constant. The same section measured that a 4 KiB buffer produced 16× as
many `on-data` deliveries as a 64 KiB one for 16 MiB of traffic and cost the same
number of collections with no monotonic throughput trend — so the size is a memory
knob, not a throughput one, and `read-stop` is what actually controls flow.

Because the size is fixed at the first start, the shell passes it once at accept time;
the pause/resume cycle of §4.4 calls `uv-read-stop!` and `uv-read-start!` with **no**
size argument thereafter.

### 7.3 Write payloads are copied at the call

The second correction to the architecture document (its §8 says the write queue must
retain references to buffers until libuv reports completion). It must not, because the
binding already did the work.

`uv-write*!` normalises and range-checks every segment, then allocates one foreign
block holding an `N`-entry `uv_buf_t[]` and the `N` **copied** spans, and issues
`uv_write` with `nbufs = N` (`stream.sls:88-128`). Each segment's `[start, end)` is
copied into request-owned foreign memory; the block is freed as a unit by the shared
write-done dispatcher, before `on-complete` runs. An empty segment list is refused
`empty-segment-list` rather than forwarded as a platform `EINVAL`.

Three consequences for M3:

- **The serializer emits segments, not a concatenated head.** Status line, header
  block and first body chunk go out as separate segments in one `uv-write*!`: one
  request, one completion, no concatenation. Verified on loopback at the pin
  (`smoke-writev.sps`, ledger): three segments — a header bytevector, the span `[2,7)`
  of `"xxhelloyy"`, a trailer bytevector — arrived as one ordered stream with exactly
  one completion, bytes matching the concatenation.
- **The core does not retain response bytevectors** until completion. A handler's body
  bytevector may be released as soon as `uv-write*!` returns.
- **Write accounting tracks bytes outstanding, not buffer liveness.** The `write`
  action's byte count feeds the `write-high-water` / `write-low-water` pair, and the
  block's own footprint is `align-16(uv_req_size(UV_WRITE))` + `N ×
  sizeof(uv_buf_t)` + `max(total, 1)`.

> *Noted 2026-09-25 (M3.3):* the core counts the writes and the bytes outstanding, and
> settles each at its `write-completed`: in `responding`, or in `closing` for a write
> a close cut short (a read error while it was outstanding). A completion the core did
> not ask for is the shell's bug, an assertion violation: with no write outstanding,
> without a count, for more bytes than are outstanding, or for fewer than the last
> write left. The second consequence is a check: `tests/test-connection-retention.sps`
> collects with a write outstanding and finds the response, its body and its segments
> released.

> *Noted 2026-09-27 (the M5 exit; Darwin arm64, Chez 10.4.1):* at chez-libuv v0.7.0
> this copy, and §7.1's out of the read buffer, move one byte at a time in Scheme:
> 29.7 to 31.1 ns a byte written and 28.4 to 29.7 ns a byte read, where one `memcpy`
> costs 0.01 to 0.02 ns (`research/spike/m5-exit-copy.sps`). A 4 MiB response holds
> the loop 125 ms in the copy, and a 16 KiB read about 0.47 ms: time in which no other
> connection is read, written or ticked. chez-libuv #35 asks for bulk copies, and the
> owner held M5's close for it.

> *Noted 2026-09-28 (chez-libuv v0.7.1, pinned):* #35 landed. Each copy, and each
> zeroing of a handle's or a request's block, is one call into the shim. The copies
> cost 0.02 to 0.03 ns a byte written and 0.02 to 0.1 ns a byte read at 1 and 4 MiB,
> what one `memcpy` costs, and the 4 MiB answer's copy takes 0.11 to 0.12 ms
> (`research/spike/out/m5-exit-copy.v071.run{1,2}.txt`). The socket lane's slow reader
> shows the whole write. Its MiB write held the loop 62 to 63 ms at v0.7.0, twice its
> copy, since the block the bytes were copied into had been zeroed a byte at a time too.
> At v0.7.1 it holds the loop under the loop clock's millisecond, and a check holds it
> under a tick.

> *Noted 2026-09-28 (M6.3):* the write water marks read the bytes outstanding. A streamed
> response's producer is asked for a piece only while they are at or below
> `write-high-water`, and once past it, again when a completion brings them to
> `write-low-water` (§4.4's M6.3 amendment). So what chez-libuv holds in write blocks
> for one connection is at most the high water and one piece's write: under 0005's
> defaults, 262,144 bytes and 16,392 for a 16 KiB piece, where a MiB streamed at once
> would all be held (`tests/test-shell.sps`).

> *Noted 2026-09-29 (M6.3's second review):* the bytes are not all a write holds. Each
> write outstanding holds its request too, a `uv_write_t` (192 bytes at libuv 1.52.1 on
> Darwin arm64), 16 bytes a segment, and chez-libuv's records of it, so under the water
> marks alone a client that never read held 0.71 MB of 100-byte pieces, and 129.5 MB of
> 1-byte ones to HTTP/1.0 (Linux, one run each). The writes outstanding are now bounded
> at 64 as well (§4.4's M6.3 amendment), so one connection holds at most the high water,
> one piece's write and 64 requests: 0.07 MB of 100-byte pieces, measured the same way.

> *Noted 2026-09-29 (write batching, after M6.3; its own PR, on the owner's word, by
> form):* the cap bounded small pieces, and each was still a write of its own, with its
> request and its completion. The libuv shell now holds a write under 4,096 bytes and sends
> a turn's held writes as one. A held write's bytes are copied as it is held, into the
> connection's chunks, each new one twice the last's length or the write's, so no byte is
> copied twice before chez-libuv's copy. What is held goes out once the drain empties the
> queue, and first before a shutdown, a close, or a write of 4,096 bytes or more, which
> goes out alone as before, and before the drain first calls a producer, so a stream's
> head never waits for its pieces. The write's completion reports each write it carried, in the
> order written, so the core and its accounting are unchanged; the contract's traces hold
> the order. A raise drops what is held with what is queued, so a bug once the head is
> held sends nothing, where the head went out before.
>
> - **The copy is made as a write is held**, not as the turn's write is issued: a
>   producer may hand out one bytevector again, refilled (handlers.org), and a prototype
>   that held pieces by reference sent every piece of a turn as its last. The shell suite
>   streams 4,000 rows from one refilled bytevector and reads them back whole.
> - **Measured on Linux** (Debian 12, libuv 1.44.2, in Docker, aarch64), a scratch server
>   whose producers never end, a client reading as fast as it can, another sending a GET
>   every 2 ms; three runs each, the median, on the tree after the PR's review:
>
>   | Pieces | Streamed, main | Batched | Another client's median wait |
>   |---|---|---|---|
>   | 1 byte | 1.9 MB/s | 11.4 MB/s | 0.85 ms, then 0.19 |
>   | 100 bytes | 32.8 | 182.9 | 0.85, then 0.19 |
>   | 1,000 bytes | 284.2 | 989.1 | 0.81, then 0.28 |
>   | 4,000 bytes | 864.8 | 1,569.7 | 0.98, then 0.68 |
>   | 8 KiB, not held | 1,472.4 | 1,444.9 | 0.78, then 0.75 |
>   | 16 KiB, not held | 2,029.9 | 2,066.0 | 0.50, then 0.50 |
>   | 100 bytes, a handler gathering 16 KiB | 854.4 | 851.1 | 1.06, then 1.01 |
>   | no stream | | | 0.26, then 0.25 |
>
>   The rows above 4,000 bytes differ by the runs' spread alone. A client that never
>   reads holds 0.03 MB of 100-byte rows, where main's held 0.05, and 0.26 MB of 16 KiB
>   pieces, as main's did (ten clients, one run each). On Darwin arm64 (libuv 1.52.1),
>   the same way: 1-byte pieces 7.9 MB/s where they streamed 0.4, 100-byte ones 132.4
>   where 7.3, 1,000-byte ones 905.2 where 68.2, and 4,000-byte ones 1,385.1 where
>   265.5; another client's median wait behind the 100-byte pieces 0.37 ms where it was
>   3.24; 8 and 16 KiB pieces as before.
> - **Three shapes were tried** as scratch prototypes, on the same Linux, three runs each,
>   the median, for 1, 100, 1,000 and 4,000-byte pieces. Each held write copied into a
>   bytevector of its own, a turn's 64 sent as 64 segments of one `uv-write*!`: 9.7, 166,
>   917 and 1,534 MB/s. The held bytes in one bytevector, grown by copying: 11.8, 172, 762
>   and 1,088. Chunks never copied again, as built: 11.8, 186, 990 and 1,580.
> - **The cutoff stays at 4 KiB.** A prototype that held 8 KiB and 16 KiB pieces too
>   streamed the 8 KiB ones at 1,708 MB/s against 1,465 written alone, but the 16 KiB ones
>   at 1,814 against 2,080 (Linux, three runs each).
> - **chez-libuv needs no change.** Its `uv-write*!` packs a write's spans end to end in
>   one block, but gives libuv one `uv_buf_t` a span, and libuv 1.52.1 mallocs the array
>   of a write with more than four (`src/unix/stream.c:1370-1372`). A scratch chez-libuv
>   giving libuv one buffer over the packed spans measured 1 to 5 % faster for 64-span
>   writes; the shell sends a few chunks a turn.
> - **The 64-write cap stays**: each piece still costs a producer's call, the core's step
>   and its framing, and the cap bounds how many a turn asks for.
> - **After the PR's review** (a /code-review high, then, on the owner's ask, a deeper
>   review of three findings, each measured; decided by form): what is held went out only
>   as the drain emptied, so a stream's head waited for the turn's producer calls, up to
>   64. On Linux, from the request, a producer that took 200 µs a piece delayed its head
>   from 0.12 ms to 12.74, and one that took 2 ms from 0.14 to 126.3. What is held now
>   goes out before the drain first calls a producer: on the tree after the review, the
>   head arrives at 0.10, 0.10, 0.13 and 0.19 ms for producers taking 0, 20, 200 and
>   2,000 µs a piece, where main sent it at 0.09, 0.09, 0.12 and 0.20 (five runs each,
>   the median). The pieces still go out a turn at a time: the first at 1.37, 12.76 and
>   126.37 ms for the three slower ones, where main sent it at 0.09, 0.33 and 2.22, and
>   the stream ends as soon or sooner: 0.26, 5.32, 51.52 and 513.03 ms, where main's
>   ended at 0.95, 6.32, 53.11 and 515.16. handlers.org says so. Weighed: the docs alone;
>   sending what has been held a millisecond before each producer call, which sent a slow
>   producer's pieces as made but slowed fast small ones 5 to 17 % (1-byte pieces 11.5
>   MB/s to 9.6) and made a turn's batch hang on time.
> - `hold!` copied with `fold-left`, whose procedure is a closure over the chunk and the
>   Date line: 32 bytes and some 6 ns a write held, in a scratch library (22.8 ns
>   against 28.5); it is a named let.
> - **The copy of a lone small response**, weighed in the review as waste, costs less
>   than it saves: a process serving itself small keep-alive GETs, a 77-byte answer each,
>   allocated 11,577 bytes a request where main's allocated 11,920, one span costing
>   chez-libuv less than four segments, and a prototype that sent a lone write's segments
>   by reference, copying only before application code ran, 384 bytes more than the
>   batched shell (Darwin, 20,000 requests, three runs each). It stays.

### 7.4 The collect-safe rendezvous

At chez-libuv v0.6.0 `uv_run` is `(foreign-procedure __collect_safe "uv_run" …)`
(`private/native.sls:261`) and thirteen of the fourteen trampolines carry the attribute
— `walk` alone stays plain, because it fires only from the synchronous `uv_walk`
(`native.sls:734`).

What that bought, measured (spike E5g, 2026-09-19 night, at the v0.6.0 pin `ad4c1e9`;
a worker thread allocating 3,000,000 ten-element vectors while the loop thread waits):

| case | v0.6.0 run 1 | run 2 | at the old pin `529ea57` |
|---|---|---|---|
| Scheme-sleep baseline | 24 ms | 24 ms | 26–29 ms |
| `'once`, 300 ms timer | 23 | 24 | **10,266–10,272** (E5c) |
| `'once`, 1 ms timer | 35 | 51 | 91–93 (E5c) |
| one `'default`, 300 ms timer | 27 | 33 | **10,223–10,240** (E5e) |
| one `'default`, 1 ms timer | 29 | 50 | 44–92 (E5e) |

A loop thread blocked in a poll no longer holds the collect interlock, so the worker's
~24 ms of allocation costs 23–33 ms whatever the loop thread does. The 1 ms rows sit a
few milliseconds above baseline because each fire reactivates the loop thread, which
then joins every rendezvous.

**What it costs**, and this is the number that belongs in M0's performance baseline:
**about 60 ns per callback** for the reactivate/deactivate pair — spike E5f, single
threaded, 256 idle handles so one `kevent()` poll is amortised over 256 callbacks,
5,000,000 callbacks per trial, three trials per mode, two runs:

| mode | ns per callback |
|---|---|
| plain `uv_run` and callable | 177–192 |
| `uv_run` and callable `__collect_safe` | 235–249 |

At three or four callbacks per request that is ~0.2 µs, against the 1.86 µs the parser
costs on an 81-byte GET (`research/async-threads-mailbox.md` spike E, same day and
machine: `100000 requests of 81 bytes: 1.86342 us/request`). It is a line in the
baseline, not a design input.

**And what it is not.** The 1 ms tick timer is not a GC workaround and never was. Spike
E5d isolated the mechanism: a ticker opens GC windows only when the loop thread's
per-tick Scheme path executes a few hundred procedure calls (0 calls 439–447 ms, 100
calls 82–85, 300 calls 29–32, 1000+ calls 9–20; an uncontended mutex per tick 437–438;
`(sleep 0)` 9–12; `__collect_safe` 6–10). Chez services another thread's collect
request only at `$event`, and firing the collector does not shorten the 1000-tick trap
budget (Chez 10.4.1 `c/schsig.c:574-594`, `s/cmacros.ss:2118`,
`s/library.ss:1219-1236`). chez-libuv's dispatch path reaches `$event`; a bare callback
does not — which is why our E5c saw 3× and chez-libuv's own T2b saw 75× for what looked
like the same experiment. Our proposed 1 ms workaround was withdrawn upstream on
chez-libuv #19.

v1 forks no thread, so none of this is a v1 feature. It is the door §5.4 describes,
plus 60 ns.

### 7.5 The per-connection and per-request budgets

Measured sizes through the binding (`research/spike/sizes.sps`, libuv 1.52.1):

```
uv_handle_size(UV_TIMER)=152  uv_handle_size(UV_TCP)=264  uv_req_size(UV_WRITE)=192
```

Per connection, resident:

| Item | Bytes | Note |
|---|---|---|
| foreign read buffer | 16,384 | `limits-read-buffer-size`; fixed at first start (§7.2) |
| `uv_tcp_t` | 264 | plus one registry entry |
| parser | 1,072 | `make-parser` with **shared** bindings |
| timer handle | **0** | one tick timer per *loop*, never per connection (0005) |
| coroutine | **0** while not parked | 3,449–5,635 B only while a handler is parked (§5.2) |

The shared binding list is load-bearing: a fresh 25-entry binding list per connection
would add **1,216 bytes** per connection, so the server builds one list per server and
passes the connection through the parser's user-context argument.

> *Re-measured 2026-09-27 (the M4 exit; Darwin arm64, Chez 10.4.1, libuv 1.52.1):*
> against the real shell, a connection held idle costs about **18.2 KB**, not the
> table's 17,720 B. `research/spike/m4-exit-budget.sps` starts a server as `serve`
> does, and a client in a process of its own holds 100, then 500, keep-alive
> connections to it. The server's heap grows by 1,490 to 1,707 B per connection
> over sixteen readings, median about 1,540 B. The readings after 1, 10, 50 and
> 200 GETs a connection do not differ beyond that spread, so a connection does not
> grow with the requests it serves. Outside the heap are the read buffer, 16,384 B,
> and `uv_tcp_t`, 264 B.
>
> The table's parser row counted what making a parser allocates (1,072 B then, and
> 1,056 B in M4.1's check). A parser keeps 592 B. The rest of the heap breaks down as:
>
> - the core's state, with its head and target judge: 192 B;
> - the adapter's context: 32 B;
> - chez-libuv's TCP handle: 200 to 240 B;
> - about 500 B not measured apart: the shell's connection record and closures,
>   the table's entry, and what reading and a served request leave in place.
>
> The buffer, a limit, is 90% of the cost. The runs are
> `out/m4-exit-budget.run{1,2}.txt`.

> *Re-measured 2026-09-27 (the M5 exit; Darwin arm64, Chez 10.4.1, libuv 1.52.1):*
> with its deadline armed, a connection held idle costs about **18.3 KB**.
> `research/spike/m5-exit-budget.sps` runs the M4 exit's spike again on the merged
> tree, where the shell arms each connection's idle deadline in the wheel entry it
> keeps (0005's amendment of 2026-09-27). Every held connection had its deadline
> armed, and the loop held one timer however many were held. The heap grows by 1,569
> to 1,746 B per connection over sixteen readings, median about 1,640 B, with no trend
> in the GETs. That median is about 100 B above the M4 exit's. The wheel entry, made
> fresh, is 48 B of it, and the rest is inside the readings' spread. Arming and
> disarming the entry allocate nothing: a million of each read 160 B, the measuring
> loop's own. The shell's one timer, a `uv_timer_t` of 152 B outside the heap, is the
> server's, not a connection's. The runs are `out/m5-exit-budget.run{1,2}.txt`.

Per request, allocation:

| Prototype | Bytes/request |
|---|---|
| naive pure core (every event copies a 13-field record; header values concatenated and stringified) | **6,832** |
| CPS core (request builder copying method, URL, three header pairs, pause + resume) | **2,672** |
| parser alone, one keep-alive GET with four headers, silent bindings | 1,600 |

**The gate for M2/M3 is ≤ 3 KiB per request** on the CPS spike's workload (decision
0002; brief risk 1), met by the linear mutable accumulator and the retained spans of
§7.1 rather than by a new allocator.

One request-path allocation was measured and then removed upstream. A validated
request-target used to cost 3,680 bytes and ~1.58 µs on a 46-byte origin-form target
because `uri-parse-validate` built a fresh collector every time; uriparse #18 (v0.4.0)
exports `uri-parse-result-validate`, so M2 holds **one collector per connection**,
resets it with `uri-collector-reset!`, and validates the finished result — **1,584
bytes and ~0.85 µs** for the same target, the same audited verdict. CONNECT targets keep
the fresh parse, because the strict authority-form validator has no collector path;
accepted without an ask, since CONNECT is rare and never on the keep-alive hot path.

### 7.6 What the core may and may not touch

Stated as the invariants `make check-imports` and the M4 `rg` gates enforce:

- The core allocates only Scheme data. It calls no chez-libuv verb, no byte-machine
  procedure, and reads no clock — `tick` carries `now`.
- The core holds no foreign pointer. Every foreign object (the read buffer, the write
  block, the handles) is owned by chez-libuv and freed by it.
- `connection-close!` is the only caller of `uv-close!`; the close callback is
  chez-libuv's sole handle-freeing site, so a double close is a bug in one place rather
  than everywhere. *Amended 2026-09-26 (M4.3):* the one caller is `handle-close!`,
  which closes a connection's handle, the listener and a refused one, its callback
  chosen by the handle (§3.3).
- Handler-facing libraries export no `uv-*` name.

---

## 8. Testing strategy

The brief's position is that this project has an unusual amount of ground truth and
should build the instruments before the server. M1 is that milestone, and nothing in
it has connection semantics. This section is concrete enough to write it from.

### 8.1 The llhttp corpus, through the connection layer

Decision 0007 item 1: llhttp fixtures are **not copied** into this repository. The
corpus lane imports chez-httparse's own loader, chunker, recorder and comparator. They
are pure R6RS over `(rnrs)` and `(byte-machine runtime)`, and they live under
`vendor/chez-httparse/test/support/harness/` (§3.2's M1 obligation):

| Library | What we use |
|---|---|
| `(httparse test corpus-load)` | `corpus-parse-file`, `fixture-input-text`, `fixture-expected`, `fixture-meta-ref`, `fixture-init-words`, `fixture-lenient-flags` |
| `(httparse test conformance)` | `corpus-scan-sizes`, `corpus-chunk-bounds`, `trace-compare`, `mismatch-index/-expected/-actual/-reason` |
| `(httparse test adapter)` | `make-trace-recorder`, `trace-recorder-bindings`, `trace-recorder-note-error!/-note-paused!/-note-finish!`, the 25-row `adapter-trace-names` table |
| `(httparse test drive)` | `drive-feed!`, `drive-chunk-ladder`, `drive-requested-pause?` |
| `(httparse test trace-format)` | the line vocabulary both sides render into |

Every `type=request` fixture is fed to the core as `bytes-arrived` events at every
chunk size, and **two** properties are gated:

1. **The connection layer must not perturb parsing.** The rendered parser trace must
   still equal the fixture's recorded log, byte for byte. The adapter may rename and
   never compute; both its tables are total over a closed set with no default, so a
   callback or error code with no row raises rather than falling back.
2. **The connection-level outcome must be chunk-size invariant.** The `call-handler`
   sequence, the keep-alive decision and the close reason are the same at size 1 as at
   whole-buffer.

The `pr` / `release` split the brief asks for **is** `corpus-scan-sizes`'s `selection`
argument, not something we build: `'extremes` runs size 1 and the whole buffer, `'full`
runs every size from 1 to the input length, and a `noScan` fixture is whole-buffer only
in both. A zero-length input still gets one run, because skipping it would let an empty
fixture pass by never executing.

**The corpus is parser truth, not server truth** (brief risk 5). llhttp's traces say
what the parser saw. What a server must do after `Connection: close`, after an upgrade,
or when a limit trips is not in them — those rows live in §8.3's tables and in libhtp's
files, and the ratchet lists them explicitly.

### 8.2 libhtp's connection streams

102 `test/files/*.t` streams, BSD-3-Clause, from a repository archived in July 2026 —
so the files will not move under us. They are the only surveyed corpus whose files
carry **explicit packet boundaries** (`>>>` client chunks, `<<<` server chunks), which
is exactly what the parser corpus cannot give: pipelining, multi-packet heads, requests
cut mid-token, CONNECT tunnels, HTTP/0.9, `Expect: 100-continue`, early responses,
zero-byte and partial requests then timeout, invalid `Content-Length`/`Transfer-Encoding`
smuggling shapes.

A ~40-line loader splits on the markers (stripping one trailing CR per chunk, as
libhtp's own `test.c` does) and delivers each client chunk as one `bytes-arrived`. The
`<<<` chunks are **a recorded origin's responses, not an oracle**, so our expectations
are ours, written per file and mutation-witnessed (0007, consequences).

Vendored under `test/vendor/libhtp/` with `LICENSE`, a `PROVENANCE` file (URL, ref,
commit, retrieval date, sha256 per file) and a `make corpus-refresh` target that
re-fetches and re-checksums. Vendored bytes are never edited.

(2026-09-25, the M2 exit) The lane delivers each client packet as one
`bytes-arrived`. After the last, the client's `eof` arrives if the connection
still reads. Every handler answers 200, and the lane runs under the llhttp lanes'
limits, with no Host required. Its outcome is the outcome lane's record plus the
body delivered. The first expectations cover the twelve streams that carry
pipelining or a request split across packets (`tests/libhtp-lane.sls`), and the
ratchet promotes them by name.

### 8.3 Connection-semantics tables

`(state, event) → (state', actions)` as data, one row per decision in §4.4, each row
watched to fail first. This is what makes the state machine reviewable: the table is
the specification, and the implementation is the thing that has to agree with it.

### 8.4 The fake shell and the cross-shell contract test

The fake shell delivers scripted events and records actions. It carries a **fake
clock**, so every timeout test drives `(tick now)` directly and no test ever sleeps
(0005, consequences).

The contract test is the gate that keeps the three shells honest: the same scripted
event stream through the fake shell, the direct libuv shell (M4) and the coroutine
shell (M7) must produce **identical wire bytes and identical action traces**. It is
written in M4 with two shells and extended in M7 to the third.

*Noted 2026-09-26 (M4.4):* `tests/test-contract.sps`. A script is a client's: what it
sends, where it waits for the server to have read it, and its end. The client plays it
to the libuv shell over loopback, and the libuv shell's own events are then given to
the fake: each delivery and the client's end as the libuv shell received them, and each
completion where it received its own, the fake delivering the one it has waiting. How
the kernel divides the stream into reads is its policy (§8.5), so a script cannot fix
it. What closes that gap is a check that the libuv shell read exactly what the client
sent, then its end. The traces are of the events each shell dispatched and the actions
each ran, in order. Where the shells part, the suite names the first byte, or the first
event or action.

*Noted 2026-09-27 (M5.3):* a script may end in a stall: the client sends nothing more
and never ends its stream, and the libuv shell's deadlines close the connection, under
short limits. Each event the fake is given comes with the loop's time it came at, and
the fake's clock is moved there first. The fake is made at the time the libuv shell
adopted its connection, and each tick is the fake's own timer firing then. The libuv
shell keeps two clocks: the wall clock its Date is made from, and the loop's, which its
deadlines use. The fake keeps one, so the libuv shell's wall clock in this test is the
loop's own. Both shells then write each Date and arm each deadline at the same
instant.

*Noted 2026-09-27 (after chez-libuv #28):* the last sentence held until the libuv shell
brought the loop's clock up to date before each arm and each write (`uv-update-time!`).
Its instants since are the event's or a moment later, where the fake's stay at the
event's. Its deadlines are never earlier than the fake's, so the fake, fired where the
libuv shell ticked, still ticks there. But a Date names a second, and one can begin in
that moment, so the Dates could differ by chance. The fake now dates each write at the
libuv shell's instant for it, in order (`fake-shell-date-writes!`): the loop's time
where the trace sees the write, which the shell calls once the clock is up to date. A
script holds its second request into the next second, so a fake dated at the event's
instant, or at the instants out of order, fails its bytes check every time.

### 8.5 The socket lane

chez-libuv's own shape, which its `tests/test-echo.sps` is the template for: bind
`127.0.0.1:0`, run clients on the same loop, cap by **iteration count and never by
wall-clock**, and assert on bytes and verb sequences only — never on how libuv
fragmented the stream, which is kernel policy.

*Noted 2026-09-26 (M4.4):* the lane is `tests/test-shell.sps`, which M4.2 wrote in
this shape. M4.4 added decision 0011's measurement to it: a client that uploads four
MiB past a refusal sends all of it, then reads the status and the stream's end, where
a close at once fails its send with EPIPE. Its clients moved to
`tests/shell-testing.sls`, to be shared with the contract test (§8.4).

*Noted 2026-09-27 (M5.3):* the lane's deadline clients run on a shell with short
limits, and their deadlines pass in the loop's own time. The iteration caps still
bound every wait. Whether a deadline was met on time is read from the trace, not from
a stopwatch:
- each deadline's instant, the loop's time where it was armed plus its limit;
- the tick's instant;
- each time the shell's timer fired, which the server's `tick` shows.

A deadline is met on time when its tick comes the first time the timer fires at or
after it. The timer's repeat, `tick-ms`, is checked apart. So the check holds however
late the loop runs, which a bound in milliseconds would not.

### 8.6 The ratchet

A manifest naming every fixture in every lane with its status. A fixture that changes
status **in either direction** fails the lane until reviewed: a regression is a failure,
and an unexplained improvement is a failure too, because it usually means the
comparator stopped comparing.

### 8.7 Status vocabulary and mutation discipline

Every suite exits with §3.4's 0/1/2/3 vocabulary through `(testing)`. Assertions
compare against a value only success can produce.

A test is finished when it has been **watched to fail**: the named mutation breaks the
asserted property and nothing else, is recorded in the milestone's mutation log, and is
reverted. A survivor is a missing test, a scope statement, or the finding itself — and
which one it is gets measured, not guessed. `m0-mutations.md` is the template: five
mutations, each with the suite, the exact edit, the observed exit status and the
failure count.

Numbers in a test come from an oracle — a fixture, a measured libuv fact, an RFC vector
— never from running the code under test. M0's pin test is the pattern: it asserts
`F-CONNECTION-CLOSE` = 2 and `F-SKIP-BODY` = 64 against llhttp's `FLAGS` enum (`1<<1`
and `1<<6`), and it was watched to fail by mutating the *vendored constant* rather than
the test's oracle, so the failure is exactly the upstream drift the pin guards against.
Note what that mutation also showed: `make check-pins` still passed during it, because
it checks the gitlink commit and not the working-tree bytes — which is why the value
pin test is a separate and necessary guard.

### 8.8 Later lanes

Black-box clients in M8, against a port rather than in process: `curl`, `ab` (which
speaks HTTP/1.0 and is why decision 0006 matters from M4), vtest2 `.vtc` scripts,
`hurl`, and `oha` for load. The robustness lane takes libhtp's `invalid-*` files, the
`smuggler` payload tables (ported as data, not as Python) and the AWS
`http-desync-guardian` classification tables. GPL-licensed material — HAProxy's
reg-tests, http-garden, HTTPWookiee, siege — is used as an external tool or by
reference, never vendored (0007 item 4).

---

## 9. Milestone sequence

### 9.1 Where each milestone lands in this document

The brief owns the milestone list and its exit gates; this table says only which part
of this document each one implements. **Slicing is rung 3's job and is not here.**

| Milestone | Implements | Status |
|---|---|---|
| M0 — skeleton and pure records | §3 (layout, path, harness bridge) | **merged, `d0c522b`, 2026-09-19** |
| M1 — the instrument, no server | §8.1, §8.2, §8.4 (fake shell), §8.6 | next |
| M2 — pure connection core, request path | §4 (all of it), §6.2–6.3, §7.1, §7.5 | |
| M3 — the response path | `(http-server serializer)` (§3.1), §7.3 | |
| M4 — libuv shell, first real server | §5.2, §6.4, §8.4 (contract test), §8.5 | |
| M5 — timeouts and limits | §4.3 deadlines, `(http-server wheel)`, §6.3 policy | |
| M6 — body streaming and backpressure | §4.1 body events, §7.2 read-stop/start | |
| M7 — scheduler and awaiting handlers | §5.2, §5.3 (R1–R5) | |
| M8 — shutdown, hand-off, black-box, release | §4.6, §4.4 hand-off row, §8.8 | |

M4 is the milestone that produces a usable server; everything after it is scoped by the
brief's exit criteria, and a milestone that wants to grow re-plans in the ledger first
(brief risk 6).

### 9.2 The next planning rung

**The milestone plan (rung 3) is not written.** It is the next planning task: it takes
the brief's M0–M8 and this document's sections and cuts them into slices with per-slice
exits and mutation logs, in the shape `chez-libuv/.plans/*-plan.md` and
`chez-httparse/.plans/2026-09-13-gate0-http-parser-milestone-plan.md` use. Nothing in
this document should be read as that plan.

### 9.3 Introduced here, recorded nowhere else

Five things this document settles that no decision record holds. Each is mechanism the
brief and the ADRs deliberately left open; any of them can be promoted to an ADR if it
turns out contentious.

1. **`(http-server serializer)`** as a library of its own (§3.1) — decision 0001's
   layout has no serializer.
2. **The error boundary** (§6.1): the pure core never raises and never catches; errors
   are values in the core and conditions only in the shell.
3. **The nine connection states** (§4.3) — decision 0002 fixes events and actions but
   names no states.
4. **`&http-server-error` and its two subtypes** (§6.4), and the decision to compose
   rather than merely wrap a handler's condition.
5. **The span-retention rule** (§7.1): retain spans from the fresh delivery for the
   head, copy only what must outlive the message — now that the delivery is known to be
   a fresh Scheme bytevector rather than a view of the foreign buffer.

### 9.4 Two drifts to reconcile

Found while writing. Neither blocks M1, and both are fixed by a dated note amended
into the record in place, which is the shape the decision README prescribes
("amended in place with a dated note ... superseded, never deleted").

1. **Three limits fields and the environment prefix were renamed in M0, and the
   records still carry the old names.** Four renames, and one of them drifts *two*
   decision records:

   | Named in a record | Shipped in `(http-server limits)` |
   |---|---|
   | `header-timeout-ms` (0005:17) | `read-header-timeout-ms` |
   | `body-timeout-ms` (0005:18) | `body-inactivity-timeout-ms` |
   | `max-pipeline` (**0004:14** and 0005:27) | `pipeline-cap` |
   | prefix `HTTP_SERVER_<NAME>` (0005:13) | prefix `CHEZ_HTTP_*`, per `docs/configuration.org` |

   The ledger's M0 close-out records the prefix as a decision taken in M0; the three
   field renames are recorded nowhere, and decision 0004 is easy to miss because it
   names `max-pipeline` in prose rather than in 0005's table. **The shipped names are
   the ones this document uses.** The fix is a dated amendment on 0004 and 0005, which
   is the owner's call, not M1's.
2. **Decision 0005's table is fifteen rows naming eighteen limits; `(http-server
   limits)` has nine fields.** The nine that are not fields yet — `write-timeout-ms`,
   `drain-timeout-ms`, `max-header-field-bytes`, `max-header-value-bytes`,
   `write-high-water`, `write-low-water`, `max-connections`, `backlog`, `tick-ms` — are
   not an omission but a sequencing choice: each arrives with the milestone that first
   needs it (M3, M5, M8), with its own default test and its own drift guard. Worth
   saying out loud so nobody reads the nine-field record as the whole of decision 0005.
