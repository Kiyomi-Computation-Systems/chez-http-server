# Refutation pass: gap-chez-libuv.md

Adversarial re-check of every item in `gap-chez-libuv.md`. For each item I opened
the cited file:line(s) in `/Users/yuzu/github/chez-libuv` myself (via `sed -n`,
`grep -n`, `rg`), and re-ran every "MEASURED today" claim from scratch. All repo
paths below are relative to `/Users/yuzu/github/chez-libuv` unless noted.

Environment used for re-runs (matches the project context):
```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/tests:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program tests/<file>.sps
```
(`tests` added to `CHEZSCHEMELIBDIRS` because `tests/uv-testing.sls` is imported by
several suites and is not under `src`.)

---

## Item 1 — Accept loop and backlog — claimed PRESENT

**Verdict: CONFIRMED.**

- `src/libuv/tcp.sls:114-121` is `uv-listen!`; `:126-135` is `uv-accept!`. Verified
  with `grep -n`: `uv-listen!` header at line 114, `uv-accept!` header at line 126,
  body ending at 135. The claimed span `114-135` covers exactly these two
  procedures.
  - `uv-listen!` validates backlog only as `(and (integer? backlog) (exact? backlog)
    (>= backlog 0))` (tcp.sls:117-119) — no upper clamp, no `SOMAXCONN` reference.
- `src/libuv-shim.c` is 306 lines total; its constant table (`chez_uv_constant_table`,
  lines 22-143 as cited) has **zero** occurrences of `SOMAXCONN`
  (`grep -n "SOMAXCONN" src/libuv-shim.c` → no output). Confirmed no such constant is
  bound anywhere in the shim.
- Backlog 128 usage confirmed in all three named test files:
  ```
  tests/test-echo.sps:245:(uv-listen! server 128
  tests/test-lifecycle.sps:419:(uv-listen! wserver 128
  tests/test-lifecycle.sps:484:       (uv-listen! srv 128
  tests/test-tcp.sps:338,712,935,1014,1110,1290,1612,1753,1858: (uv-listen! ... 128 ...
  ```

No corrections needed.

---

## Item 2 — Per-connection read buffer smaller than 64 KiB — claimed PRESENT

**Verdict: CONFIRMED.**

- `src/libuv/stream.sls:73` is exactly `(define default-read-buffer-size 65536)`.
  Lines 73-115 (confirmed via `grep -n`) span from that definition through the
  `'buffer-size-fixed` raise inside `ensure-read-buffer!` (lines 107-115). The
  optional `buffer-size` argument is validated only as `(and (integer? buffer-size)
  (exact? buffer-size) (positive? buffer-size))` (lines 93-96) — no upper bound.
  First call fixes the size irreversibly; a later call with a *different* explicit
  size raises `'buffer-size-fixed` (lines 111-115); a later call that omits the size
  is always accepted (`ensure-read-buffer!` line 108 `(or buffer-size
  default-read-buffer-size)` only fires when the buffer doesn't exist yet).
- `tests/test-tcp.sps:1202-1230` confirmed: zero-size, inexact-size, and
  negative-size buffer requests are all refused pre-allocation (`live-count` before
  == after).
- `tests/test-tcp.sps:1383-1420` confirmed: default-size assertion
  (`65536 (stream-read-buf-len s-peer)`), `EALREADY` on double-start, "restarting
  with the SAME explicit size is allowed", "restarting with a DIFFERENT explicit
  size is refused, naming who and why" → `'(uv-read-start! buffer-size-fixed)`, and
  "restarting with the size OMITTED reuses the buffer at whatever size it was
  fixed."
- `docs/api.md:142-181` (actually the table is at ~145-150) contains exactly the
  cited memory table:
  ```
  | 4096  | ~1.2 MiB | ~40 MiB  |
  | 16384 | ~3.1 MiB | ~160 MiB |
  | 65536 | ~12.4 MiB| ~625 MiB |
  ```
  matching the claim's "4096B->~40MiB @10k vs 64KiB->~625MiB @10k" verbatim.

No corrections needed.

---

## Item 3 — read-stop/read-start semantics and the closing-handle race — claimed PRESENT

**Verdict: CONFIRMED**, including a fresh re-run.

- `src/libuv/private/handles.sls:390-397` is exactly `read-dispatch` (verified via
  `grep -n "define (read-dispatch" → 390`, closing `record-orphan-callback!` line
  at 397). It dispatches purely on `(uv-stream-record? handle)`, with **no** check
  of `handle-state` — i.e. it does not gate on the handle being `'open`, so a
  `'closing` handle still receives a queued delivery. Confirmed.
- `src/libuv/stream.sls:14-18` is `require-open-stream` (verified `grep -n → 14`).
  `handles.sls:204-208` is `require-open-handle`, which raises
  `(make-uv-handle-closed (handle-kind handle))` when state isn't `'open`
  (verified exact lines 204-208). Together these confirm `uv-read-stop!` (which
  calls `require-open-stream` → `require-open-handle`) raises `&uv-handle-closed`
  on a `'closing` handle.
- `docs/api.md:183-192` (the guard block, verified) contains exactly:
  ```scheme
  (when (uv-handle-open? stream)
    (uv-read-stop! stream))
  ```
  preceded by prose describing the exact race ("A stop issued from inside `on-data`
  for a delivery that raced a close therefore *raises* rather than succeeding as a
  no-op").
- **Re-ran** `tests/test-flow.sps`:
  ```
  $ CHEZSCHEMELIBDIRS=.../src:.../tests:.../build/scheme-libs chez --program tests/test-flow.sps
  %%%% Starting test flow
  # of expected passes      23
  EXIT CODE: 0
  ```
  `tests/test-flow.sps:73-101` does exercise exactly this scenario: it closes
  reader 0 from inside its own `on-data` callback guarded by
  `(when (uv-handle-open? (vector-ref peers 0)) ...)`, and asserts (line ~90-95)
  that the closed reader reaches `'closed` before survivor writes land — the
  same race the guard exists for.

No corrections needed.

---

## Item 4 — Write: span, completion ordering, write-on-closing-handle, ECANCELED — claimed PRESENT

**Verdict: CONFIRMED**, including a fresh re-run reproducing the exact printed line.

- `src/libuv/stream.sls:20-59`(actually the `case-lambda` body runs 23-58, header at
  19) is `uv-write!`: span-capable (3-arg and 5-arg `start`/`end` forms), copies
  `[start,end)` into a freshly allocated foreign block (`copy-in!` line 44), and
  calls the native write with **exactly one buffer**:
  `(uv-write-native block (handle-pointer ...) (+ block buf-offset) 1)` — the
  literal `1` is the nbufs argument (line ~55, inside the claimed `56-58` range).
- `.plans/decisions/0018-unbuffered-write-submission.md:81-90` — read verbatim:
  > "**The binding will not hold unsubmitted write blocks, will not enforce a
  > queue-depth or byte cap, and `uv-write!` will not refuse.** Every write that
  > passes validation is submitted to libuv before `uv-write!` returns, exactly as
  > it is today."
  Confirms "synchronous, unreordered submission" as claimed.
- `require-open-stream` at `stream.sls:14-18` confirmed (see item 3) — refuses a
  write on a `'closing` handle before any allocation.
- **Re-ran** `tests/test-tcp.sps` in full:
  ```
  %%%% Starting test tcp
    [informational] write after shutdown: sync=EPIPE async=not-attempted
    [informational] write racing close completed as: no-error
    [informational] 1 MiB transfer: outcome=satisfied got=1048576/1048576 writes-done=16 write-err=no-write-error on-error=on-error-never-fired
    [informational] abrupt peer close delivered as: ECONNRESET (on-eof fires: 0)
  # of expected passes      179
  EXIT: 0
  ```
  This reproduces the exact string `write racing close completed as: no-error`
  claimed, and confirms exit 0 / 179 passes (test-tcp.sps:919-984 is indeed the
  "close with a write still in flight" section: seeds a write, calls `uv-close!`,
  asserts both callbacks fire, and asserts the outcome is `no-error` or `ECANCELED`
  — "a-legal-ordering").

No corrections needed.

---

## Item 5 — Vectored/try writes — claimed MISSING

**Verdict: Status CONFIRMED (missing), but one clause of the evidence is imprecisely attributed.**

- Confirmed: no `uv_try_write` and no `uv_write2` anywhere in
  `src/libuv/private/native.sls` (`grep -n "uv_write\|try_write\|write2"` finds only
  `uv_write` itself, at lines 294 (raw foreign-procedure decl) and 763
  (`uv-write-native` wrapper)). This is a whole-file grep, not just the cited
  223-818 span, so the "missing" conclusion is robust.
- **Correction to the evidence, not the status:** the claim says *"uv-write-native
  hardcodes nbufs=1"*. This is not quite accurate. `uv-write-native` itself
  (`native.sls:763-764`) is a thin passthrough that takes `nbufs` as a parameter:
  ```scheme
  (define (uv-write-native req-ptr stream-ptr bufs-ptr nbufs)
    (raw-write req-ptr stream-ptr bufs-ptr nbufs write-cb-entry))
  ```
  and the underlying foreign call `raw-write` (`native.sls:293-294`,
  `foreign-procedure "uv_write" (uptr uptr uptr unsigned-int uptr) int`) already
  accepts an arbitrary `unsigned-int nbufs`. **The hardcoded literal `1` lives at
  the *call site* in `stream.sls` (`uv-write!`, ~line 57)**, not inside
  `uv-write-native`. In other words, the FFI entry point is already
  vectored-write-capable; only the higher-level Scheme `uv-write!` wrapper
  restricts callers to one buffer. This actually strengthens the "upstream:
  propose `uv-writev!`" recommendation in the original item (no C shim or foreign
  signature change would be needed, only a new Scheme wrapper that builds a
  `uv_buf_t[]` and passes `nbufs > 1`), but the sentence blaming
  `uv-write-native` for the hardcoding should instead blame `uv-write!`'s call
  site.
- `stream.sls:56-58` citation is close but the literal `1` argument is on the line
  in between the given range's edges (it's inside `56-58` as displayed with
  `sed -n '54,58p'`, so the range itself is fine); it is `uv-write!`, not
  `uv-write-native`, that does the hardcoding.

Status stands: **missing**, evidence direction correct, one attribution detail
corrected above.

---

## Item 6 — Shutdown (half-close) semantics and shutdown-after-write ordering — claimed PRESENT

**Verdict: CONFIRMED**, including fresh re-run.

- `src/libuv/stream.sls:61-71`(header at line 62, full definition 61-71 including
  leading comment) is exactly `uv-shutdown!`. Confirmed via `grep -n`.
- `docs/api.md:58-70` (table around line 66) contains verbatim: `` `uv-shutdown!` |
  Shut the write side down; the read side stays open ``.
- `tests/test-tcp.sps:1425-1450` is exactly the EOF-on-shutdown section: shuts
  down `sclient`'s write side, asserts the peer's `on-eof` fires exactly once,
  that it isn't reported as an error, and that write+shutdown both completed with
  `no-error`.
- `tests/test-tcp.sps:620-696` is exactly the write-after-shutdown section
  (registers a shutdown request, asserts it deregisters, then attempts a write
  after shutdown and records whichever of the two legal failure modes occurred).
- **Re-ran** `tests/test-tcp.sps` (see item 4's transcript above): printed
  `[informational] write after shutdown: sync=EPIPE async=not-attempted` verbatim,
  exit 0.

No corrections needed.

---

## Item 7 — Timers: cost per handle, 10k viability, uv-timer-again!, uv-now — claimed PRESENT

**Verdict: CONFIRMED, and independently re-measured.**

- `src/libuv/timer.sls:54-58` (header at 55) is exactly `uv-timer-again!`.
  Confirmed via `grep -n`.
- `src/libuv/loop.sls:77-81` (header at 79) is exactly `uv-now`, with the comment
  "This is libuv's cached time and changes only when the loop updates it."
  `docs/api.md` line 21 (table row) reads: `` `uv-now` | libuv's cached "now", in
  ms, updated once per iteration ``. Both confirmed.
- **Re-measured sizes independently, by compiling a small C probe against the
  same pinned Homebrew libuv** (more direct than a Scheme-side "uv-handle-size
  query"):
  ```
  $ pkg-config --cflags libuv
  -I/opt/homebrew/Cellar/libuv/1.52.1/include
  $ gcc $(pkg-config --cflags libuv) sz.c -o sz $(pkg-config --libs libuv) && ./sz
  uv_timer_t = 152
  uv_tcp_t = 264
  ```
  Exactly matches the claimed `sizeof(uv_timer_t)=152 bytes,
  sizeof(uv_tcp_t)=264 bytes`, and confirms libuv 1.52.1 is indeed the version
  actually linked.
- **Re-ran the 10k-timer viability claim** with a fresh scratchpad probe
  (`/private/tmp/.../scratchpad/probe-sizes.sps`) against the real binding:
  created 10,000 `uv-timer` handles on one loop, closed all of them, and drained
  the loop:
  ```
  created: 10000 errors: 0
  closed: 10000 / 10000
  EXIT: 0
  ```
  Confirms "10,000 uv-timer handles created and closed successfully with no
  error" exactly.

No corrections needed.

---

## Item 8 — uv-run once/nowait semantics, re-entry guard, "single once may not fire a due timer" trap — claimed PRESENT

**Verdict: CONFIRMED.**

- Re-entry guard: `src/libuv/loop.sls` — exact lines (via `grep -n`) are 55
  (`(when (loop-running? loop)`) and 56 (`(raise (make-uv-invalid-argument 'uv-run
  'loop-running)))`). Claimed range `54-56` is off by one line at the start (line
  54 is `(require-open-loop loop 'uv-run)`, the line just before the guard) but
  fully covers the actual raise; not a substantive error.
- `tests/uv-testing.sls` lines 36-79 (verified: file exists, this is the doc
  comment block above and including `run-until`/`run-until/ticking`) contains,
  close to verbatim:
  > "The mode is 'once: it blocks until the loop's next due event..."
  > "...leaves the FIRST step blocked in the kernel, where run-until's iteration
  > cap never gets to count."
  Matches the claim's paraphrase.
- `.plans/2026-08-21-chez-libuv-v0.3-process-design.md:710` — read directly, is
  **exactly**: "a blocked bare `'once` after activity can return early; deflake
  lesson." Verbatim match.

No corrections needed.

---

## Item 9 — Callback error surfacing (`uv-loop-deferred-errors`) and keeping the loop alive after a raise — claimed PRESENT

**Verdict: CONFIRMED.**

- `src/libuv/private/handles.sls:288-304` (verified) is exactly
  `loop-record-error!` (288-298) and `dispatch-guarded` (300-304). Confirmed
  `loop-record-error!` stores the first error object, and only calls
  `uv-loop-stop` on the *loop* (not `uv-close!` on any handle) when the loop is
  still `'open` — i.e. it stops only the current `uv-run`, not the loop/handles
  themselves.
- `src/libuv/loop.sls:38-65` is the full `uv-run` definition (case-lambda through
  its closing parens). Line 59 is exactly
  `(set-loop-deferred-error-list! loop '())`, confirmed to run *before* the
  `dynamic-wind` that actually invokes `uv-loop-run` (lines 60-64) — i.e. before
  that run's own callbacks can fire, exactly as claimed.
- Cross-checked `uv-loop-deferred-errors` (loop.sls:89-91): reads
  `loop-deferred-error-list`, which item 9's cited reset (line 59) wipes on every
  subsequent `uv-run` call — confirming the "must be read before the next
  `uv-run`, or later simultaneous failures are silently discarded" consequence.

No corrections needed.

---

## Item 10 — Close ownership: exactly what a second `uv-close!` does — claimed PRESENT

**Verdict: CONFIRMED**, including fresh re-run.

- `src/libuv/private/handles.sls:477-486` (verified via context read) is exactly
  `real-close-handle!`:
  ```scheme
  (define (real-close-handle! handle on-close)
    (require-handle handle 'uv-close!)
    (unless (or (not on-close) (procedure? on-close)) ...)
    (when (eq? (handle-state handle) 'open)
      (set-handle-on-close! handle on-close)
      (set-handle-state! handle 'closing)
      (uv-close-native (handle-pointer handle 'uv-close!))))
  ```
  Confirms the `when ... 'open` gate — a second call while `'closing` is a silent
  no-op that never stores or invokes the new `on-close`.
- **Re-ran** `tests/test-timer.sps`:
  ```
  %%%% Starting test timer
  # of expected passes      128
  EXIT: 0
  ```
  Matches the claimed "exit 0 (128 passes)" exactly.
  `tests/test-timer.sps:421-437` is exactly the section titled "a second
  `uv-close!` while `'closing` ignored its on-close argument" (test body
  continues one line past 437 to assert `'second-thunk-never-ran`, well within
  the spirit of the citation).
- `docs/api.md:267-274` reads verbatim: "**A second `uv-close!` silently discards
  its callback.**...this applies to every handle kind, not just processes. A
  server that deregisters a connection from `on-close` must own *every* close
  initiation for that handle; the protocol for doing that is server-layer
  design, not binding design — see
  [`.plans/chez-http-server-architecture.md`]..." — confirms both the mechanism
  and the explicit deferral to chez-http-server's own architecture doc, exactly
  as claimed.
- `.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md` §9 exists, titled
  "9. Connection ownership above the binding" (line 453) — confirmed present
  (item cites "§9" without line numbers, which is fine).

No corrections needed.

---

## Item 11 — Signal watching for SIGTERM/SIGINT and the SIGINT caveat — claimed PRESENT

**Verdict: CONFIRMED**, including fresh re-run.

- `src/libuv/signal.sls` is exactly 84 lines total (`wc -l` = 84), so "1-84"
  covers the entire file: `make-uv-signal`, `watch-symbol->int` (rejects
  `sigkill`/`sigstop` as `'signal-unwatchable`, closing the vocabulary),
  `start-signal!` (raises `'signal-mode-fixed` when a second start uses a
  different mode — the "mode-fixed-per-handle ratchet"), `uv-signal-start!`,
  `uv-signal-start-oneshot!`, `uv-signal-stop!`, and `signal-dispatch`.
- ADR-0017 (`.plans/decisions/0017-signal-watching-vocabulary-and-mode.md`)
  confirmed to contain the closed vocabulary (`sigterm sigint sighup sigquit
  sigusr1 sigusr2 sigcont`, two unwatchables), and the SIGINT caveat verbatim:
  "Watching `sigint` takes SIGINT away from the Chez runtime...after stop, the
  disposition is `SIG_DFL` — libuv does not restore what was there before, so
  SIGINT then terminates the process. Measured on both platforms..."
- `docs/api.md:315-361` read in full: contains the export table, the closed
  vocabulary description, the mode-fixed-per-handle ratchet description, the
  exact oneshot-SIGTERM drain code sample (`uv-signal-start-oneshot! watcher
  'sigterm ...`), and the "Measured caveat" paragraph about SIGINT reverting to
  `SIG_DFL`. All present, essentially verbatim to what the claim describes.
- **Re-ran** `tests/test-signal.sps`:
  ```
  %%%% Starting test signal
  # of expected passes      49
  EXIT: 0
  ```
  Matches "exit 0, 49/49 passes" exactly.

No corrections needed.

---

## Item 12 — uv-tcp-nodelay!, peer address, sockname — claimed PRESENT

**Verdict: Status CONFIRMED (present), but two of the four sub-citations have small line-number slips.**

Actual line numbers (from `grep -n` plus counted function bodies):

| Function | Claimed lines | Actual lines |
|---|---|---|
| exports block (tail) | `8-11` | export form starts at line 5; lines 8-11 do fall inside it (roughly right) |
| `uv-tcp-getsockname-port` | `53-70` | **53-70 — exact match** |
| `uv-tcp-peer-address` | `52,70-91` | **72-91** (the doc-comment header is at 72-74, body through 91). Line 52 belongs to the *previous* function, `uv-tcp-bind!` (its closing `(free! addr)))` line), not to `uv-tcp-peer-address` at all — that "52," looks like a stray/miscounted line reference. |
| `uv-tcp-sockname-address` | `93-112` | **93-112 — exact match** |
| `uv-tcp-nodelay!` | `160-168` | **160-168 — exact match** |

The function content itself is exactly as claimed:
- `uv-tcp-nodelay!` (`tcp.sls:162-168`) requires a boolean (`(unless (boolean?
  enable?) (raise ...))`) — boolean-typed, confirmed.
- `uv-tcp-peer-address` and `uv-tcp-sockname-address` both return
  `(values address port)` via `sockaddr->address-string` / `read-net-u16`.
- All exported from `(libuv tcp)` (`tcp.sls:5-11`), confirmed present in the
  export list.

Net: the functionality claim is fully correct; the `uv-tcp-peer-address` line
citation ("52,70-91") should read "72-91", with no line 52 involved. Minor,
does not change the verdict.

---

## Item 13 — TCP keepalive, SO_REUSEPORT, multi-loop/multi-process scaling — claimed MISSING

**Verdict: CONFIRMED**, with one very minor citation off-by-one.

- Re-ran the repo-wide search myself:
  ```
  $ rg -i "keepalive|reuseport|reuse_port" --glob '!vendor/**' --glob '!build/**' --glob '!**/tests-tmp/**'
  (zero hits)
  ```
  Confirms "zero hits" exactly as claimed.
- `grep -n "keepalive" src/libuv/private/native.sls` → zero hits (checked the
  *whole file*, not just the cited 223-818 span — even stronger than the
  original claim, no `uv_tcp_keepalive` anywhere).
- `src/libuv/tcp.sls:42-51` is exactly `uv-tcp-bind!`, whose native call is
  `(uv-check (uv-tcp-bind (handle-pointer tcp 'uv-tcp-bind!) addr 0) 'uv-tcp-bind!)`
  — the trailing `0` is a hardcoded flags argument, confirmed no way to request
  `SO_REUSEPORT`/`UV_TCP_REUSEPORT` through this call.
- `src/libuv/private/handles.sls:217-218` is exactly:
  ```scheme
  ;; Pointer values may be bignums, so registry identity uses eqv?, not eq?.
  (define registry (make-eqv-hashtable))
  ```
  Confirmed: one bare, unsynchronized, process-global `eqv-hashtable`.
- `handles.sls:233-260` covers `registry-register!` (233-243),
  `registry-deregister!` (246-250), `registry-ref` (254-256), plus
  `registry-loop-of`/`registry-count` immediately after — none contain any
  lock/mutex; all are plain `hashtable-set!`/`hashtable-ref`/`hashtable-delete!`
  calls. Confirmed no synchronization.
- `handles.sls:515-517` is exactly the `dispatch-table` definition (`(define
  dispatch-table (make-eq-hashtable))`), preceded by its explanatory comment —
  confirmed, another single process-global table.
- `native.sls:599-602` is exactly:
  ```scheme
  ;; One process-global slot and locked trampoline per callback type.
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit walk signal))
  ```
  Confirmed exact match to the cited range.
- `native.sls:849-850` — line 850 is exactly the comment "Initialization is
  process-global and serialized in Scheme for portability."; the `(define
  init-mutex (make-mutex))` itself is on line **851**, one line past the cited
  range's end. Trivial off-by-one; the substance (one mutex, guarding init only)
  is correct and adjacent to the cited lines.

Status stands: **missing**, evidence solid, one line-number off-by-one noted.

---

## Item 14 — Thread-safety facts (the registry) and absence of uv_async — claimed MISSING

**Verdict: Status CONFIRMED (missing/deliberately out of scope), but one clause of the evidence is FACTUALLY WRONG and needed correcting.**

- Re-ran the repo-wide search myself:
  ```
  $ rg -i "uv_async|uv-async" --glob '!vendor/**' --glob '!build/**' --glob '!**/tests-tmp/**'
  spike/FINDINGS.md:72:UV_ASYNC                           1
  spike/probe.c:38:  P_INT(UV_ASYNC);
  ```
  **This does NOT match the claim's description.** The claim says this search
  "only finds it in libuv-shim.h's single-threaded-diagnostics comment and
  spike/FINDINGS.md's explicit v0.1 deferral." In fact:
  - `src/libuv-shim.h` has **zero** occurrences of "async" in any case
    (`grep -n -i "async" src/libuv-shim.h src/libuv-shim.c` → no output). I read
    the actual "single-threaded diagnostics" comment at `libuv-shim.h:20` in
    full — it is about the **debug allocation counters**
    (`chez_uv_count_loop_new`, `chez_uv_live_tcp`, etc.), and says nothing about
    `uv_async` at all. The claim's attribution of a `uv_async` hit to this
    comment is a fabrication/confusion — that file simply is not one of the
    `rg` hits.
  - The real hits are `spike/FINDINGS.md:72` (a probe-results table row,
    `UV_ASYNC   1`, i.e. just confirming the constant exists in libuv) and
    `spike/probe.c:38` (`P_INT(UV_ASYNC);`, a probe-tool macro invocation) —
    neither of which the original claim mentions.
  - The `spike/FINDINGS.md:366-369` quote **is** accurate and *does* exist
    verbatim at those exact lines (I confirmed via `grep -n`):
    > "that same call is **not** exercised here. v0.1 is single-threaded and
    > ADR-0008 scopes it out; mixing the two axes in one experiment would make
    > any failure un-attributable. This is a known, named gap, not an
    > oversight — it must be re-opened before any multi-threaded or
    > `__collect_safe` use of `uv_run` is introduced."
    However, this passage does **not** literally contain the string
    `uv_async`/`uv-async` — it's about `uv_run` re-entrancy and
    `__collect_safe`, cited by the original agent as if it were what the
    `uv_async` grep surfaced, when it's actually a separate, topically-related
    citation bundled in under the same rg claim.
  - **Correction**: the accurate summary is: a case-insensitive repo-wide
    search (excluding vendor/build/tests-tmp) for `uv_async`/`uv-async` finds
    it only in two spike-tooling artifacts (`spike/FINDINGS.md:72`,
    `spike/probe.c:38`), confirming the constant was *probed* but never bound
    into the library proper — `uv_async_init`/`uv_async_send` do not appear
    anywhere under `src/`. The single-threaded-scope narrative is real and
    well-documented (`spike/FINDINGS.md:366-369`, verbatim as quoted, plus
    `spike/01-callback-gc.ss:21` "v0.1 is single-threaded (ADR-0008)"), but it
    is a distinct citation from the `uv_async` grep, not the same one.
- Registry citations (`handles.sls:217-218`, `233-260`) re-verified identically
  to item 13 above — confirmed accurate, no lock anywhere in the
  register/deref/deregister path.

**Net effect on the item:** the *conclusion* ("no cross-thread wake mechanism
and no synchronized shared state exist; this is a named, deliberate scope
limit of v0.5, not a silent oversight") remains true and is independently
supported by the registry evidence and the genuine `spike/FINDINGS.md:366-369`
quote. But the specific claim about where the `uv_async` grep hits land
(attributing one to `libuv-shim.h`'s counters comment) is incorrect and should
be struck/corrected as shown above.

---

## Item 15 — Windows status — claimed PRESENT

**Verdict: CONFIRMED, very precise citations.**

- `.plans/decisions/0004-windows-deferred-design-clean.md` is exactly 67 lines
  (`wc -l` = 67), so "1-67" is the entire document — confirmed. Contains the
  LLP64 `long` truncation caveat verbatim: "`long` is 64-bit on Linux/macOS
  (LP64) but only 32-bit on Windows (LLP64)." (line 34) and "The LLP64 `long`
  caveat on `chez_uv_constant`'s out-param is recorded here as..." (line 50),
  "The LLP64 `long` caveat is a standing item any future Windows-enabling..."
  (line 66).
- `src/libuv/handle.sls:51-52` is exactly:
  ```scheme
  ;; Buffer-size operations support TCP and pipes on Unix, but only TCP on
  ;; Windows; libuv reports unsupported platform cases.
  ```
  Confirmed exact match, corroborating the platform split as claimed.

No corrections needed.

---

## Summary table

| # | Need | Original status | My verdict | Notes |
|---|---|---|---|---|
| 1 | Accept loop and backlog | present | **confirmed** | — |
| 2 | Read buffer < 64 KiB | present | **confirmed** | — |
| 3 | read-stop/start race | present | **confirmed** | re-ran test-flow.sps, exit 0/23 passes |
| 4 | Write span/completion/ECANCELED | present | **confirmed** | re-ran test-tcp.sps, exit 0/179 passes, exact string match |
| 5 | Vectored/try writes | missing | **confirmed (status)** | evidence misattributes hardcoding to `uv-write-native`; it's actually the `uv-write!` call site — `uv-write-native`/`raw-write` already parametrize `nbufs` |
| 6 | Shutdown semantics | present | **confirmed** | re-ran test-tcp.sps, exact string match |
| 7 | Timers | present | **confirmed** | independently re-measured sizeof via C probe (152/264 bytes) and re-ran 10k-timer probe |
| 8 | uv-run once/nowait/re-entry | present | **confirmed** | re-entry guard citation off by 1 line (54→55), trivial |
| 9 | Callback error surfacing | present | **confirmed** | — |
| 10 | Close ownership | present | **confirmed** | re-ran test-timer.sps, exit 0/128 passes |
| 11 | Signal watching | present | **confirmed** | re-ran test-signal.sps, exit 0/49 passes |
| 12 | nodelay/peer/sockname | present | **confirmed (status)** | peer-address citation should be 72-91, not "52,70-91" |
| 13 | keepalive/reuseport/scaling | missing | **confirmed** | mutex citation off by 1 line (850→851), trivial |
| 14 | Thread-safety / uv_async | missing | **confirmed (status), evidence corrected** | rg hits are spike/FINDINGS.md:72 + spike/probe.c:38, NOT libuv-shim.h (which has zero "async" occurrences); the :366-369 quote is real but is a separate citation, not what the uv_async grep itself surfaces |
| 15 | Windows status | present | **confirmed** | very precise citations |
