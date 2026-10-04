# chez-http-server: an HTTP/1.1 server for Chez Scheme — project brief

Date: 2026-09-19
Status: accepted for M0 — decisions 0001–0008 record what was settled
Consumers: applications written in Chez; the first is a plaintext/JSON service shaped like the TechEmpower `plaintext`/`json` tests
Dependencies (all Kiyomi, all local checkouts; pins as of 2026-09-19 night): `chez-libuv` v0.6.0, `chez-httparse` v0.4.0, `uriparse` v0.4.0, `byte-machine` v0.6.0
Research behind this brief: [`.plans/research/`](research/README.md) — 61 agent reports, a live control-flow spike, and the verified corpus catalogue

## Goal

A small, composable HTTP/1.1 origin server in R6RS Scheme for Chez, built by composing four libraries that already exist and are measured:

```
              application handler: (lambda (request respond) ...)
                             │
              ┌──────────────┴──────────────┐
              │        chez-http-server      │   THIS REPOSITORY
              │  pure connection core        │   conn-step : State × Event → State × [Action]
              │  request/response records    │
              │  limits, timing wheel        │
              │  libuv shell, scheduler      │
              └───┬──────────────┬──────────┘
                  │              │
        (generated httparse-message)   (libuv)          (uri collect) for the request-target
        chez-httparse v0.4.0           chez-libuv v0.6.0
                  │
        (byte-machine runtime) v0.6.0
```

The architecture document ([`chez-http-server-architecture.md`](chez-http-server-architecture.md)) fixed the layering; this brief fixes what is actually built, in what order, and against which evidence. Two of its names are historical: the parser it calls `chez-http1` shipped as **chez-httparse**, and `chez-byte-machine` shipped as **byte-machine**. Both are complete for our purposes (274 of 274 llhttp fixtures at every chunk size), so this project is the composition layer and nothing below it.

## What is settled (2026-09-19)

Each of these is a decision record; the one-line form is here so the brief reads on its own.

1. **The connection is a pure state machine** (decision 0002). Events in — bytes, EOF, write completions, ticks, the parser's 25 callbacks, handler responses. Actions out — feed the parser, reply to a parser callback, write, read-stop, read-start, arm a deadline, call the handler, close. The libuv shell is an interpreter of ~120 lines. Every connection-semantics test, including the llhttp corpus at every chunk size, runs with no sockets.
2. **The shell is direct callbacks; a scheduler exists only for handlers that await** (decision 0003). No continuation is ever captured under a C frame: the live spike (E1/E2) shows Chez traps any attempt to resume one as a "stale foreign context". Engines and OS-thread handlers are rejected for v1 on measured hazards.
3. **Pipelining is strictly serial in v1** (decision 0004): pause the parser at `on-message-complete`, stop reading, run the handler, write, resume. The cap is a config value in the core so a parse-ahead policy is a setting and a test later, not a redesign.
   *Amended 2026-09-25 (decision 0004):* serial by design. The cap accepts only 1, and a parse-ahead policy would be a new decision with its own design, not a setting.
   *Amended 2026-10-04 (decision 0004):* parse-ahead is not wanted, on the owner's word: no client the server meets pipelines.
4. **Bounded, nginx-style defaults; one tick timer and a timing wheel per loop** (decision 0005). Header read 60 s, idle 75 s, body inactivity 60 s, header bytes 16 KiB → 431, header count 100, target 8 KiB → 414, bodies stream unbounded, pipeline cap 1. Every limit is overridable from the environment.
5. **HTTP/1.0 is supported; an h2c preface is answered 505 and closed; upgrades hand off through one hook** (decision 0006).
   *Amended 2026-09-25 (decision 0006):* v1 serves an upgrade request and closes the connection after the response; the hook is M8's door for a handler that takes upgrades, and only the HTTP/2 preface gets 505.
6. **Corpora are vendored as data with provenance** (decision 0007): llhttp reached through chez-httparse's harness, libhtp's 102 connection streams first, the rest by tier.
7. **Twelve upstream asks were filed and tackled first** (decision 0008): chez-httparse #32–#36 (plus #42, split from #33), chez-libuv #18–#21, uriparse #9–#11. All fourteen have landed, counting #42 and the later uriparse #18: chez-httparse's in v0.3.0 and v0.4.0, uriparse's in v0.2.0, v0.3.0 and v0.4.0, chez-libuv's in v0.6.0, every pin at a release tag. No workaround remains on the request path; the one allocation v1 still accepts is the strict CONNECT target validator, which parses fresh (CONNECT is rare).

## Why this is its own repository, and where it stops

- chez-libuv's thesis is "transport only, no protocol above bytes, no backpressure policy" (its README, ADR-0018). HTTP connection semantics — keep-alive, framing precedence, limits, timeouts, ordering — are exactly what it refuses to own.
- chez-httparse's thesis is byte-exact llhttp conformance. It deliberately parses syntax and carries no connection policy; its own `AGENTS.md` records that keep-alive and needs-eof are decisions the *embedder* computes from flags.
- This repository owns everything between those two and the application: the connection state machine, request and response records, limits, timeouts, the libuv shell, the scheduler, and graceful shutdown.
- It is **not** a web framework. Routing, middleware, sessions, templating and static-file serving are downstream. The handler contract is `request → response`, with streaming and awaiting as explicit extensions of that contract.
- It is **not** HTTP/2 or TLS. Both are later layers; the design keeps a hand-off hook and a transport record so they attach without touching the core.

## The one hard design question, settled by measurement

How does Scheme interact with libuv's asynchrony? Six proposals were written independently, a live spike measured what Chez 10.4.1 actually permits, and three judges scored all six against the spike. The full paper is [`2026-09-19-async-model-options.md`](2026-09-19-async-model-options.md). The facts that decided it:

- A continuation captured inside a libuv callback cannot be resumed after the callback returns. Chez raises `attempt to return to stale foreign context`, a bare `&assertion` that escapes `uv-run` unwrapped (spike E1a/b, E2a/b, run twice each).
- A scheduler that resumes coroutines only from Scheme frames and lets callbacks merely enqueue works, at ~30 ns per suspend/resume and ~13 µs per `uv-run 'once` turn (spike E3/E3b).
- Engine expiry inside a callback clears chez-libuv's `loop-running` flag through `dynamic-wind` and lets a nested `uv-run` re-enter libuv (spike E4c/E4d); every expiry inside `parser-feed!` poisons the parser (judge experiment J1).
- A worker thread touching a loop handle corrupted the registry (spike E5b2) and a loop thread blocked in `uv-run` froze GC for other threads (spike E5c; the 1 ms timer that seemed to mask it is not a workaround, spike E5d/E5e). Both are gone at chez-libuv v0.6.0, the pin: the touch is a named `&uv-wrong-thread` refusal and the stall is at baseline (spike E5g and the E5b re-run). What remains is the ~60 ns per callback the conversion costs (spike E5f), a line in M0's baseline.

The three judges disagreed on the ranking of the single proposals and agreed on the hybrid: sans-I/O core, direct-callback shell, coroutines only for handlers that await.

## The test instrument comes first

This project has an unusual amount of ground truth and should build the instruments before the server:

1. **The llhttp corpus through the connection layer.** chez-httparse's harness libraries (`corpus-parse-file`, `corpus-scan-sizes`, `corpus-chunk-bounds`, `trace-recorder-bindings`, `trace-compare`) are R6RS and import only `(rnrs)` and `(byte-machine runtime)`. Every `type=request` fixture is fed to the core as `bytes-arrived` events at every chunk size; the rendered parser trace must still equal the recorded log (the connection layer must not perturb parsing) and the connection-level outcome — the `call-handler` sequence, the keep-alive decision, the close reason — must be chunk-size invariant. A ratchet manifest names every fixture and its status, both directions gated.
2. **libhtp's 102 connection streams** (`test/files/*.t`, BSD-3-Clause), whose `>>>`/`<<<` markers are explicit packet boundaries: pipelining, multi-packet heads, requests cut mid-token, CONNECT tunnels, HTTP/0.9, Expect: 100-continue, zero-byte and partial requests then timeout, invalid CL/TE smuggling shapes. A ~40-line loader; our own expectations per file.
3. **Connection-semantics tables**: `(state, event) → (state', actions)` as data, one row per decision, each row watched to fail first.
4. **The fake shell** that delivers scripted events and records actions, so timeouts run against a fake clock and never a sleep.
5. **A contract test** that gates every shell: the same scripted event stream through the fake shell, the direct libuv shell (M4) and the coroutine shell (M7) must produce identical wire bytes and action traces.
6. **The socket lane** in chez-libuv's own shape: `127.0.0.1:0`, clients on the same loop, iteration caps instead of wall-clock (`tests/test-echo.sps` is the template).
7. **Black-box clients** later: `curl`, `ab` (speaks HTTP/1.0), vtest2 scripts, `hurl`, `oha` for load, and the smuggling payload sets.

## Milestones

Each milestone exits on a measured count in the ledger, dated and platform-stamped, never carried forward by arithmetic (the sibling repos' rule).

### Upstream first — the twelve asks

Before M0, work the filed issues in the order the milestones need them. **chez-httparse: all landed and tagged the same day.** v0.3.0 carries #32 (`(httparse decisions)`: F-* constants, `should-keep-alive?`, `message-needs-eof?`) and #35 (`(httparse methods)`); v0.4.0 carries #33 (`parser-finish!` fires `on-message-complete` for a close-delimited body), #42 (an unsafe finish is llhttp's `invalid-eof-state`, split from #33), #34 (`parser-result-next` and the two upgrade hand-off channels, documented in `docs/api.org`) and #36 (the 501-vs-400 split by `parser-error-node-name`, documented; the code stays one per llhttp number). **uriparse: all landed and tagged the same day.** #9 (`uri-parse-authority-form` and its strict variant) and #10 (host grammar, so CR/SP in a host is `invalid-reg-name`) in v0.2.0; #11 (`uri-collector-reset!`: one collector per connection on the streaming path; `uri-parse-validate` still builds its own, so M2's validated forms kept the accept-the-allocation workaround until #18) in v0.3.0; #18 (`uri-parse-result-validate`: a reset-reused collector's `uri-collect-finish!` result gets the same audited verdict with no re-parse, 3680 -> 1584 bytes per validated target measured here; the strict CONNECT validator still parses fresh) in v0.4.0, which also states that `uri-parse-validate` is audited recognizer-equivalent to RFC 3986 Appendix A per mode (recognition only; `uri-parse` stays lenient by design). **chez-libuv: all landed and tagged the same day** in v0.6.0: #18 (`uv-write*!`, one request over a list of bytevectors or spans), #21 (`uv-tcp-keepalive!` and a reuseport bind flag, Linux/BSD-only; post-v0.1), #19 (`uv_run` and its trampolines `__collect_safe`: a blocked loop thread no longer freezes other threads' GC, spike E5g) and #20 (`(libuv async)` and enforced loop-thread affinity, `&uv-wrong-thread`), the last two prerequisites only for a future worker pool. Each open ask has a recorded workaround, so no milestone blocks on any of them. M0 pins chez-httparse at the v0.4.0 tag, uriparse at the v0.4.0 tag and chez-libuv at the v0.6.0 tag.

### M0 — the skeleton and the pure records

`Makefile` with `build`, `dev`, `test`, `clean`, `prod`, `help` (a `check-help` target, as chez-libuv); dependency wiring to the four libraries (pinned checkouts by gitlink, one library path); Linux-only CI building Chez 10.4.1 as the siblings do; the SDD ledger; `(http-server limits)` with defaults and env overrides; `(http-server request)` and `(http-server response)` records; the F-* constants, `should-keep-alive?`, `message-needs-eof?` and the method tables imported from `(httparse decisions)` and `(httparse methods)` rather than copied, with one pin test asserting the constants' values the corpus traces depend on (`F-CONNECTION-CLOSE` = 2, `F-SKIP-BODY` = 64). **Exit:** `make test` green with the pin test watched to fail; a program importing all four libraries at once runs (the 2026-09-19 smoke program in the ledger is the template).

### M1 — the instrument, with no server

Corpus loaders (llhttp through chez-httparse's harness; the libhtp `.t` loader), the fake shell, the trace recorder, the ratchet manifest, the `pr`/`release` chunk-size split. **Exit:** every request fixture loads with checksums verified; the comparator is mutation-witnessed; zero connection semantics.

### M2 — the pure connection core, request path

`conn-step` over parser events: request building; header limits answered through `reply-parser (fail code)`; keep-alive from `should-keep-alive?` over the flags read inside `on-headers-complete` (HTTP/1.0 and 1.1 rules, the literal `major > 0 and minor > 0` gate); serial pipelining with pause at `on-message-complete`, `read-stop`, and `pending-input` retained from `parser-result-next`; no feed after a close-marked message; parser error → 400 + close; request-target parsed by uriparse per form: origin-form and absolute-form through `uri-parse-validate`, `CONNECT` through `uri-parse-authority-form-validate`, `*` by literal check. **Exit:** ratchet over the request fixtures at every chunk size; chunk invariance of the outcome; the libhtp pipelining and multi-packet files pass with our expectations.

### M3 — the response path

Serializer producing the status line, the header block and the first body chunk as separate segments for one `uv-write*!` (one request, one completion, no concatenation); chunked framing; HEAD/1xx/204/304 body suppression; `Content-Length` vs close-delimited for HTTP/1.0; `Connection: close` on the last response; write accounting (bytes and request count) with high/low water. **Exit:** table tests; corpus lane still green; a serializer mutation that emits chunked to a 1.0 client goes red.

### M4 — the libuv shell and the first real server

Direct callbacks, the connection table, close ownership (`connection-close!` is the only `uv-close!` caller, gated by `rg` in `make test`), the listener, the contract test against the fake shell, the loopback suite in `test-echo.sps` shape. **Exit:** `curl` and `ab` get correct responses; counters return to zero; the contract test passes.

### M5 — timeouts and limits

The per-loop tick timer and timing wheel; per-phase deadlines re-armed on progress; 408/413/414/431 mapping; every limit from the environment. **Exit:** fake-clock table tests; slow-client socket tests (`slowhttptest` shapes) close within a tick of the deadline; no per-connection timer handle exists.

### M6 — body streaming and backpressure

Credit-based request-body delivery (`body-credit`), streaming responses with `notify-producer`, the four `read-stop` conditions and the single `read-start` predicate, `Expect: 100-continue` written only when the handler pulls the body. **Exit:** 16 MiB each way against a slow peer with bounded memory; the libhtp Expect and early-response files pass.

### M7 — the scheduler and awaiting handlers

The two-level scheduler with injectable `poll!`, the phase assertion, one-shot resume cells, coroutine handlers with `await` and `with-deadline`; the contract test extended to the coroutine shell. **Exit:** a handler awaiting `uv-getaddrinfo!` inside a pipelined connection keeps response order; R1–R5 each have a mutation that goes red.

### M8 — shutdown, hand-off, black-box, release

SIGTERM drain with deadline; the upgrade hand-off hook (h2c preface → 505 + close; the hook shape reserved for WebSocket); black-box lane (vtest2, hurl, curl); load smoke with `oha`; smuggling corpora (libhtp invalid-* files, `smuggler` payloads, the AWS desync-guardian classifications) as a robustness lane. **Exit:** v0.1.0 tagged with the measured numbers in `CHANGELOG.md`.
*Amended 2026-09-25 (decision 0006):* the core answers the HTTP/2 preface 505 itself (M2.5); M8's hook is the door for a handler that takes upgrades.

## Standing risks

1. **Allocation per request.** The naive pure core measured 6.8 KB per request; the CPS prototype 2.7 KB. The acceptance gate for M2/M3 is ≤ 3 KiB on the same workload, met by a linear mutable accumulator and retained spans rather than copies.
2. **The 64 KiB read buffer** is the dominant per-connection cost (chez-libuv's own measurement: ~625 MiB at 10k connections). `read-buffer-size` defaults to 16 KiB here; the number is a limit, not a constant.
3. **Pause protocol edges.** A pause inside `on-body-data` needs the re-feed to start at `parser-result-next`, and byte-machine needs one more feed (possibly empty) after a pause on the last body byte. Both are pinned by tests in M2/M6; chez-httparse v0.4.0's `docs/api.org` (#34) now states the rule the tests assert: re-feed from `parser-result-next`, which already points one past the fragment delivered to the pausing callback.
4. **Close-delimited response bodies** complete only at `parser-finish!` (chez-httparse v0.4.0, #33), and a finish from a half-read message answers `invalid-eof-state` (#42). Only the test client and any future proxy path see either; the server core parses requests and acts on the finish status alone.
5. **The corpus is parser truth, not server truth.** llhttp traces say what the parser saw, not what a server must do after `Connection: close` or an upgrade. Those rows live in our tables and in libhtp's files, and the ratchet lists them explicitly.
6. **"Comprehensive" has no natural stopping point.** M4 produces a usable server. Everything after it is scoped by the exit criteria above, and a milestone that wants to grow re-plans in the ledger first.
