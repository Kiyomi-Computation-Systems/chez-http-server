# Gap analysis: chez-libuv v0.5.0 vs chez-http-server needs

Machine facts (measured 2026-09-19): macOS 25.6.0 arm64 (Darwin Kernel
25.6.0, arm64), Chez 10.4.1, chez-libuv checkout at
`/Users/yuzu/github/chez-libuv`, `git describe --tags` = `v0.5.0-8-g23d8462`
(commit `23d8462`, `docs: tighten source comments (#17)`), shim already built
at `build/lib/libchezlibuv.dylib` (dev build, `CHEZ_LIBUV_DEBUG_COUNTERS` on).
libuv 1.52.1 via Homebrew (`/opt/homebrew/opt/libuv`).

All commands below were run from `/Users/yuzu/github/chez-libuv` with
`CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/<suite>.sps`
(the same library path the project's own `Makefile` uses, `Makefile:89`),
and none of them mutated the repository (read-only `chez --program` runs
against the already-built shim; no `make clean`, no `git checkout`, no writes
outside this scratchpad).

Every numbered item below is a server need from the task. Status legend:
**PRESENT** (binding gives the server what it needs, possibly with a sharp
edge to respect), **MISSING** (no binding surface; workaround or upstream
change proposed), **MEASURED** (settled here by running real chez-libuv code
on this machine, output pasted verbatim).

---

## 1. Accept loop and backlog — PRESENT

`uv-listen!` takes any non-negative exact integer backlog and installs
`on-connection` *before* calling into libuv, because "connections may arrive
at once":

```
src/libuv/tcp.sls:114-123
  ;; uv-listen! : uv-tcp exact-nonnegative-integer procedure -> unspecified
  ;; Store the callback before listening because connections may arrive at once.
  (define (uv-listen! tcp backlog on-connection)
    (require-open-tcp tcp 'uv-listen!)
    (unless (and (integer? backlog) (exact? backlog) (>= backlog 0))
      (raise (make-uv-invalid-argument 'uv-listen! 'backlog-out-of-range)))
    ...
    (uv-check (uv-listen-native (handle-pointer tcp 'uv-listen!) backlog)
              'uv-listen!))
```

`uv-accept!` allocates a fresh `uv-tcp` handle per accepted connection and
closes it asynchronously on a failed `uv_accept` rather than freeing it
directly (`src/libuv/tcp.sls:125-135`). There is no bound `SOMAXCONN`
constant (not in `chez_uv_constant_table`, `src/libuv-shim.c:22-143`) — the
caller's integer is passed straight to `uv_listen`, so any OS clamping is
libuv's/the kernel's, not the binding's. `on-connection` firing once per
queued connection (not batched) is inherited, un-modified libuv behaviour;
every test suite (`tests/test-tcp.sps:338`, `tests/test-echo.sps:245`,
`tests/test-lifecycle.sps:419,484`) calls `uv-listen!` with backlog `128` and
accepts inside the callback with a single `uv-accept!` per firing.

No server-side workaround needed.

## 2. Per-connection read buffer smaller than 64 KiB — PRESENT, range [1, +∞) exact positive integers

```
src/libuv/stream.sls:73-115
  (define default-read-buffer-size 65536)
  (define uv-read-start!
    (case-lambda
      ((stream on-data on-eof on-error)
       (start-reading! stream on-data on-eof on-error #f))
      ((stream on-data on-eof on-error buffer-size)
       (start-reading! stream on-data on-eof on-error buffer-size))))
  (define (start-reading! stream on-data on-eof on-error buffer-size)
    ...
    (when buffer-size
      (unless (and (integer? buffer-size) (exact? buffer-size)
                   (positive? buffer-size))
        (raise (make-uv-invalid-argument 'uv-read-start!
                                         'buffer-size-out-of-range))))
    (ensure-read-buffer! stream buffer-size)
    ...)
  (define (ensure-read-buffer! stream buffer-size)
    (if (zero? (stream-read-buf stream))
        (let ((size (or buffer-size default-read-buffer-size)))
          (set-stream-read-buf! stream (alloc-zeroed size))
          (set-stream-read-buf-len! stream size)
          (count-read-buffer-new!))
        (when (and buffer-size (not (= buffer-size (stream-read-buf-len stream))))
          (raise (make-uv-invalid-argument 'uv-read-start!
                                           'buffer-size-fixed)))))
```

Validation only requires an exact positive integer — **no upper bound is
enforced in code**; confirmed by the test suite, which probes `0`
(rejected), a float (rejected), a negative value (rejected), but never an
upper bound:

```
tests/test-tcp.sps:1202-1230
(test-equal "a buffer size of zero is refused before anything is allocated" ...)
(test-equal "an inexact buffer size is refused, naming who and why" ...
    (uv-read-start! vtcp ignore-data ignore-eof ignore-error 65536.0) ...)
(test-equal "a negative buffer size is refused, naming who and why" ...
    (uv-read-start! vtcp ignore-data ignore-eof ignore-error -1) ...)
```

The size is fixed by the **first** `uv-read-start!` on that handle,
irreversibly, until close; a later call that omits the size reuses whatever
size was fixed (cheap `uv-read-stop!`/`uv-read-start!` backpressure cycling),
and a later call with a *different* explicit size raises `'buffer-size-fixed`
— proven by a live test: `tests/test-tcp.sps:1404-1420`
("restarting with a DIFFERENT explicit buffer size is refused" /
"restarting with the size OMITTED reuses the buffer at whatever size it was
fixed"). Each new TCP handle independently picks its own size at its first
`uv-read-start!` call, so a server can freely vary sizes *per connection*
(e.g. smaller for control connections, larger for upload-heavy ones) — only
a single already-open handle's own size is locked.

`docs/api.md:142-181` recommends 4096/16384 for many-small-message workloads
based on real measurement (`spike/flow/14-readbuf-default.ss`, Debian
bookworm/aarch64): memory scales linearly (4096→~40 MiB @10k conns vs
65536→~625 MiB @10k conns, `docs/api.md:146-150`), while GC/throughput costs
did not distinguish sizes in that measurement.

No gap.

## 3. read-stop/read-start semantics and the closing-handle race — PRESENT, with a documented sharp edge

`read-dispatch` deliberately does **not** gate on handle state (unlike
`timer-dispatch`/`connection-dispatch`, which check
`(eq? (handle-state h) 'open)`), so an in-flight delivery for a handle that
has since moved to `'closing` still reaches `on-data`/`on-eof`/`on-error`:

```
src/libuv/private/handles.sls:390-397
  (define (read-dispatch stream-ptr nread buf-ptr)
    (let ((handle (registry-ref stream-ptr)))
      (if (uv-stream-record? handle)
          (cond ((positive? nread) (deliver-read-data! handle nread))
                ((zero? nread) #f)
                ((= nread (uv-eof)) (deliver-read-eof! handle))
                (else (deliver-read-error! handle nread)))
          (record-orphan-callback! 'read stream-ptr))))
```

But `uv-read-stop!` goes through `require-open-stream` →
`require-open-handle`, which **raises** `&uv-handle-closed` on a `'closing`
handle:

```
src/libuv/stream.sls:14-18,119-123        (require-open-stream / uv-read-stop!)
src/libuv/private/handles.sls:204-208     (require-open-handle raises on non-'open)
```

`docs/api.md:183-192` names this exact race and gives the guard the server
must use everywhere it calls `uv-read-stop!` from inside `on-data`:

```
(when (uv-handle-open? stream)
  (uv-read-stop! stream))
```

`tests/test-flow.sps:73-101` exercises exactly this shape (closing a reader
from inside its own `on-data`, guarded with `uv-handle-open?`) and passed on
this run (`test-flow` exit 0, 23/23 expected passes,
`/private/tmp/.../scratchpad/test-flow-output.txt`).

No gap — but the guard above must be applied unconditionally by
chez-http-server's own read handler, since an unguarded `uv-read-stop!`
racing a close is a real, reachable raise, not a hypothetical.

## 4. Write: span, completion ordering, write-on-closing-handle, on-complete-on-close — PRESENT and MEASURED

**Span support.** `uv-write!` is a `case-lambda` accepting either a whole
bytevector or an explicit `[start, end)` span, validated before any
allocation:

```
src/libuv/stream.sls:20-59
  (define uv-write!
    (case-lambda
      ((stream bv on-complete) ...)
      ((stream bv start end on-complete)
       (require-open-stream stream 'uv-write!)
       ...
       (unless (and (integer? start) (exact? start)
                    (integer? end) (exact? end)
                    (<= 0 start) (<= start end)
                    (<= end (bytevector-length bv)))
         (raise (make-uv-invalid-argument 'uv-write! 'span-out-of-range)))
       (let* ((len (- end start))
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              (block (alloc-zeroed (+ payload-offset (max len 1))))
              (payload (+ block payload-offset)))
         (copy-in! payload bv start len)
         (uv-buf-set! (+ block buf-offset) payload len)
         ...
         (uv-check (uv-write-native block (handle-pointer stream 'uv-write!)
                                    (+ block buf-offset) 1)
                   'uv-write!)
         req))))
```

**Ordering across multiple in-flight writes.** ADR-0018 rejects any
Scheme-side write queue: *every* `uv-write!` call submits synchronously to
libuv's own per-stream queue before returning
(`.plans/decisions/0018-unbuffered-write-submission.md:81-90`), so there is
no binding-side reordering — submission order to libuv is call order,
period. `uv-shutdown!` is likewise submitted synchronously
(`src/libuv/stream.sls:62-71`), so a write-then-shutdown call pair reaches
libuv in that same order and cannot race a queued write ahead of the FIN
(ADR-0018 §"Ordering").

**Write issued on a closing handle.** `uv-write!` calls `require-open-stream`
first (`src/libuv/stream.sls:14-18,26-27,32`), which raises
`&uv-handle-closed` *before allocating anything* if the handle is `'closing`
or `'closed`. A new write cannot be submitted once close has started.

**On-complete guaranteed for a write already in flight when `uv-close!`
fires.** This is the sharpest of the four sub-questions, and it is measured,
not assumed. `tests/test-tcp.sps:919-984` issues a write, immediately calls
`uv-close!` on the same handle while that write is still registered as
in-flight (`live-count 'write-req` before/after), then asserts (with a
bounded iteration cap, so it fails by name rather than hanging if
`on-complete` were silently dropped) that **both** the write's `on-complete`
**and** the handle's `on-close` fire:

```
tests/test-tcp.sps:919-984
;; --- close with a write still in flight ----------------------------------
;; Design spec S5: request callbacks tolerate a 'closing handle -- an
;; in-flight write completing with 'ECANCELED lands there. BOTH orderings
;; are legal (the write may already have been handed to the kernel when the
;; close starts), so this asserts the disjunction and RECORDS which one this
;; platform produced, rather than pretending one of them is the contract.
...
(uv-write! pclient (string->utf8 "in flight")
           (lambda (err) (collect) (set! pending-write-err err)))
(test-equal "seed: the write was in flight when uv-close! was called"
  1 (- (live-count 'write-req) write-req-live-before-pending))
(uv-close! pclient (lambda () (collect) (set! pending-closed 'on-close-ran)))
(define pending-outcome
  (run-until pl (lambda () (and (not (eq? pending-write-err 'write-cb-never-fired))
                                (eq? pending-closed 'on-close-ran))) cap))
(test-equal "both the write completion and the close callback arrived"
  'satisfied pending-outcome)
...
(test-equal "a write racing a close completes either cleanly or as 'ECANCELED"
  'a-legal-ordering
  (let ((observed (err->symbol pending-write-err)))
    (if (memq observed '(no-error ECANCELED)) 'a-legal-ordering observed)))
(test-equal "the handle's on-close callback still ran" 'on-close-ran pending-closed)
(test-equal "the write request was freed exactly once, whichever ordering won"
  write-req-live-before-pending (live-count 'write-req))
```

**MEASURED on this machine**, run today:

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-tcp.sps
...
  [informational] write after shutdown: sync=EPIPE async=not-attempted
  [informational] write racing close completed as: no-error
  [informational] 1 MiB transfer: outcome=satisfied got=1048576/1048576 writes-done=16 write-err=no-write-error on-error=on-error-never-fired
  [informational] abrupt peer close delivered as: ECONNRESET (on-eof fires: 0)
$ echo exit=$?
exit=0
```

On this run the in-flight write had already been handed off before
`uv_close`'s cancellation swept the queue, so it completed with `no-error`
(one of the two documented-legal outcomes); the suite's assertions (which
would fail by name on either an unfired callback or a non-{`no-error`,
`ECANCELED`} status) all passed. `unix/stream.c:454,464` is cited in the
design doc as libuv's own site for the `UV_ECANCELED` flush-on-close
behaviour (`.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md:475-478`);
that specific vendor-source claim was **not** independently re-verified
against the actual libuv 1.52.1 `.c` source in this sandbox (Homebrew ships
only the compiled `.dylib` and headers, not `unix/stream.c` — confirmed:
`/opt/homebrew/opt/libuv/include` has headers only), so it is reported here
as the project's own documented claim, not independently re-derived C-source
evidence; the *binding's own delivery behaviour* around it (on-complete
always fires, request freed exactly once) **is** independently measured
above.

No gap for chez-http-server: `on-complete` is a reliable place to decrement
outstanding-write bookkeeping even for writes racing a close.

## 5. Vectored/try writes — MISSING; concatenation is the required workaround

Exhaustive check of every bound `uv_*` symbol
(`src/libuv/private/native.sls:223-818`, full export grep below) shows no
`uv_try_write`, no `uv_write2`, and `uv-write-native` always calls
`raw-write` with `nbufs` hardcoded to `1`:

```
src/libuv/private/native.sls:293-294
  (define raw-write
    (foreign-procedure "uv_write" (uptr uptr uptr unsigned-int uptr) int))
src/libuv/stream.sls:56-58
  (uv-check (uv-write-native block (handle-pointer stream 'uv-write!)
                             (+ block buf-offset) 1)
            'uv-write!)
```

```
$ rg -n '"uv_' src/libuv/private/native.sls
# (full list captured; no uv_try_write / uv_write2 / uv_tcp_keepalive /
#  uv_tcp_simultaneous_accepts / uv_udp_* / uv_fs_* / uv_async_* / uv_idle_* /
#  uv_check_* / uv_prepare_* anywhere)
```

**Consequence for chez-http-server's response serializer**: it must
concatenate the status line + headers (+ first small body chunk, where
practical) into **one** bytevector before calling `uv-write!`, because each
call allocates one full request block regardless of payload size (a
zero-length write still allocates the whole struct,
`docs/api.md:194-197`) and there is no scatter/gather submission — N
separate `uv-write!` calls for N logically-contiguous pieces costs N
copies-at-the-FFI-boundary (ADR-0009) and N foreign allocations, not one.
For a streamed/chunked body, sequential `uv-write!` calls per chunk remain
correct (ordering is guaranteed per item 4 above) but the server should
batch small chunks up to a reasonable size before calling `uv-write!` rather
than writing every small chunk (e.g. every parser callback span) as its own
call.

**Proposed smallest upstream change**: a new export, e.g.

```
uv-writev! : uv-stream (listof bytevector) procedure -> uv-request
uv-writev! : uv-stream (listof (bytevector start end)) procedure -> uv-request
```

mirroring `uv-write!`'s existing shape (`stream.sls:20-59`), allocating one
request block whose payload holds N copied spans and an N-entry `uv_buf_t[]`
passed to `raw-write` with `nbufs = N`. The task's own project context notes
`uv-write*!` is already a reserved name for this, suggesting the chez-libuv
authors anticipated exactly this addition. This is additive and does not
change existing behaviour; not required for a correct v1 (concatenation
fully substitutes for it) but worth an ADR before chez-http-server locks in
"always concatenate" as a permanent architectural constraint.

## 6. Shutdown (half-close) and shutdown-after-write ordering — PRESENT, MEASURED

`uv-shutdown!` shuts only the write side; per the docs, "the read side stays
open" (`docs/api.md:58-70`); code:

```
src/libuv/stream.sls:61-71
  (define (uv-shutdown! stream on-shutdown)
    (require-open-stream stream 'uv-shutdown!)
    (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
    (let* ((block (alloc-zeroed (uv-req-size (uv-shutdown-req-type))))
           (req (%make-uv-req-record block 'shutdown stream on-shutdown)))
      (registry-register! block 'shutdown-req (handle-loop stream) req)
      (guard (e (#t (abandon-request! req) (raise e)))
        (uv-check (uv-shutdown-native block (handle-pointer stream 'uv-shutdown!))
                  'uv-shutdown!))
      req))
```

**Measured half-close behaviour** (`tests/test-tcp.sps:1425-1450`, this run):
the peer's `on-eof` fires exactly once when the client shuts its write side
down while its own read side is still being used elsewhere in the same test
(`"the peer's on-eof fired when the client shut its write side down"` /
`"the end of the stream fired on-eof exactly once"`), and the shutdown
completes cleanly (`"the shutdown and the shutdown that drove this section
both completed cleanly"` → `'(no-error no-error)`).

**Shutdown-after-write ordering** is correct by construction, per item 4:
both verbs submit synchronously and in call order, so a write issued then
immediately shut down cannot have the FIN race ahead of the data
(ADR-0018 §"Ordering", quoted above).

**Write-after-shutdown fails**, measured on this machine, this run
(`tests/test-tcp.sps:620-696`, output captured above):

```
[informational] write after shutdown: sync=EPIPE async=not-attempted
```

i.e. on macOS/libuv 1.52.1, `uv_write` itself refuses **synchronously**
(raises `&uv-errno-error` with `errno = 'EPIPE`) once the local write side
is shut down — no completion callback is ever scheduled for that call. The
suite documents both legal outcomes (sync raise, or async errno) and only
asserts the disjunction (`tests/test-tcp.sps:689-696`), since which one
libuv chooses is platform policy, not a binding contract.

No gap; the server should call `uv-shutdown!` then stop issuing `uv-write!`
on that handle (guaranteed to fail either way, but a synchronous raise means
no wasted allocation on this platform, while other platforms may take the
async path and should be guarded the same way regardless).

## 7. Timers: per-handle cost, 10k viability, `uv-timer-again!`, `uv-now` — PRESENT and cheap, MEASURED

`sizeof(uv_timer_t)` and 10,000-timer creation were measured directly on this
machine, since neither is documented as a number anywhere in chez-libuv's
own docs/ADRs:

```
$ cat > sizeof-probe3.sps <<'EOF'
#!r6rs
(import (rnrs) (libuv)
        (only (libuv private native) uv-handle-size)
        (only (libuv private constants) uv-tcp-type uv-timer-type))
(define loop (make-uv-loop))
(display "sizeof(uv_timer_t) = ") (display (uv-handle-size (uv-timer-type))) (newline)
(display "sizeof(uv_tcp_t)   = ") (display (uv-handle-size (uv-tcp-type))) (newline)
(uv-loop-teardown! loop)
EOF
$ CHEZSCHEMELIBDIRS=src:build/scheme-libs chez --program sizeof-probe3.sps
sizeof(uv_timer_t) = 152
sizeof(uv_tcp_t)   = 264

$ cat > sizeof-probe.sps <<'EOF'
#!r6rs
(import (rnrs) (libuv))
(define loop (make-uv-loop))
(define n 10000)
(define timers '())
(let loop2 ((i 0)) (when (< i n) (set! timers (cons (make-uv-timer loop) timers)) (loop2 (+ i 1))))
(display "created ") (display n) (display " timers OK") (newline)
(for-each (lambda (t) (uv-close! t)) timers)
(uv-run loop 'default)
(uv-loop-teardown! loop)
(display "closed all OK") (newline)
EOF
$ CHEZSCHEMELIBDIRS=src:build/scheme-libs chez --program sizeof-probe.sps
created 10000 timers OK
closed all OK
```

10,000 live `uv-timer` handles create and close cleanly with no error. At
152 bytes each, one-timer-per-connection at 10,000 connections costs
~1.5 MiB of foreign handle memory — negligible next to the ~625 MiB the
default 64 KiB read buffer alone costs at that scale
(`docs/api.md:146-150`). `uv-timer-again!` just re-arms a timer using its
already-set repeat interval and requires the handle to be open
(`src/libuv/timer.sls:54-58`); nothing in the ADRs or tests restricts it at
scale. `uv-now` is libuv's own *cached* loop time, updated once per
iteration — **not** a syscall per call:

```
src/libuv/loop.sls:77-81
  ;; uv-now : uv-loop -> exact-nonnegative-integer
  ;; This is libuv's cached time and changes only when the loop updates it.
  (define (uv-now loop)
    (require-open-loop loop 'uv-now)
    (uv-loop-now (loop-pointer loop 'uv-now)))
```

(`docs/api.md:21` confirms: "libuv's cached 'now', in ms, updated once per
iteration".) This makes a coarse-grained timing wheel (bucket connection
deadlines and compare against `uv-now` sampled cheaply on every iteration,
backed by one or a few real timers rather than one per connection) a viable
*alternative* design if libuv's internal O(log n) timer-heap insert/remove
ever becomes a measured hotspot — but nothing here shows that it currently
is one at 10k. Both a naive one-timer-per-connection design and a
timer-wheel design are fully supported by the primitives as they exist
today.

No gap.

## 8. `uv-run` once/nowait semantics, the re-entry guard, and the "single once may not fire a due timer" trap — PRESENT, with a documented operational trap

**Re-entry guard**, exactly as the project context states:

```
src/libuv/loop.sls:50-65
  (define uv-run
    (case-lambda
      ((loop) (uv-run loop 'default))
      ((loop mode)
       (require-open-loop loop 'uv-run)
       (when (loop-running? loop)
         (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
       ...)))
```

Calling `uv-run` (any mode, including `'nowait`) from inside a callback on
the *same* loop raises `&uv-invalid-argument` immediately rather than
re-entering libuv.

**The trap.** `'once` blocks in the kernel until the loop's next due event
and returns as soon as that ONE iteration's work is done — not specifically
whatever event the caller is waiting for. chez-libuv's own test harness
documents this precisely, because it bit them:

```
tests/uv-testing.sls:36-79
  ;; The mode is 'once: it blocks until the loop's next due event, which is
  ;; what makes a 1 ms timer test deterministic instead of a spin. ...
  ;;
  ;; WHY THIS EXISTS. `uv-run loop 'once` BLOCKS until the loop's next due
  ;; event. That is what makes a 1 ms timer test deterministic, but it also
  ;; means a predicate that never holds -- on a loop whose only remaining
  ;; handles are waiting on a socket that will never be readable -- leaves
  ;; the FIRST step blocked in the kernel, where run-until's iteration cap
  ;; never gets to count. The suite then hangs instead of failing ...
```

and separately, for a case where unrelated activity is already happening:

```
.plans/2026-08-21-chez-libuv-v0.3-process-design.md:710
  - All waits are `run-until/ticking` with iteration caps — never
    wall-clock, and a child-exit wait always uses the ticking variant (a
    blocked bare `'once` after activity can return early; deflake lesson).
```

i.e. a `'once` step can (a) block **indefinitely** if literally nothing is
due and no I/O will ever become ready (no bound timeout is exposed to the
caller), and (b) can return "early" — completing that iteration's work
without the specific awaited event having fired — when unrelated work is
also ready in the same iteration. `run-until/ticking` was written
specifically to paper over (a) by keeping a 1 ms repeating timer armed so
`'once` always has *something* to return for
(`tests/uv-testing.sls:64-79`).

**Consequence for chez-http-server's driver loop**: never assume "N calls to
`uv-run 'once`" == "N specific events delivered"; drive with a real
predicate loop, and never call `'once` on a loop with nothing guaranteed
due (keep at least one recurring timer or an armed signal watcher alive
whenever the server must remain responsive to e.g. a shutdown deadline).
`'nowait` has the complementary, simpler contract used correctly in
production code already: `tests/test-flow.sps:308-314` samples
`uv-stream-write-queue-size` synchronously right after `uv-write!` returns,
falling back to `(uv-run loop 'nowait)` only to pump the loop without
blocking when the queue hasn't gone positive yet.

No gap in the binding; this is an operational contract the server's own
event loop driver must respect and is easy to get wrong on a first pass.

## 9. Callback-error surfacing (`uv-loop-deferred-errors`) and keeping the loop alive after a raise — PRESENT, with an ordering trap to respect

A callback raise is caught by `dispatch-guarded`, stored (first one) or
queued (subsequent ones in the same run) by `loop-record-error!`, which also
calls `uv_stop` on the *current* run only — it does **not** close the loop
or any handle:

```
src/libuv/private/handles.sls:288-304
  ;; Never raise through a C callback frame. Store the first object and stop the
  ;; loop; retain later objects for inspection.
  (define (loop-record-error! loop obj)
    (require-loop loop 'uv-loop-record-error!)
    (if (loop-has-pending-error? loop)
        (set-loop-deferred-error-list!
         loop (cons obj (loop-deferred-error-list loop)))
        (begin
          (set-loop-pending-error! loop obj)
          (when (and (eq? (loop-state loop) 'open)
                     (valid-pointer? (loop-ptr loop)))
            (uv-loop-stop (loop-ptr loop))))))
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))
```

`uv-run` re-raises the stored (first) error wrapped in `&uv-callback-error`
once its own libuv call returns:

```
src/libuv/loop.sls:38-65
  (define (deliver-pending-callback-error! loop)
    (when (loop-has-pending-error? loop)
      (let ((pending (loop-pending-error loop)))
        (clear-loop-pending-error! loop)
        (raise (if (condition? pending)
                   (condition (make-uv-callback-error pending) pending)
                   (make-uv-callback-error pending))))))
  (define uv-run
    (case-lambda
      ...
      ((loop mode)
       ...
       (let ((mode-int (run-mode->int mode 'uv-run))
             (ptr (loop-pointer loop 'uv-run)))
         (set-loop-deferred-error-list! loop '())
         (let ((rc (dynamic-wind
                    (lambda () (set-loop-running! loop #t))
                    (lambda () (uv-loop-run ptr mode-int))
                    (lambda () (set-loop-running! loop #f)))))
           (deliver-pending-callback-error! loop)
           (not (zero? rc)))))))
```

To keep serving, the driver must (a) `guard` every `uv-run` call for
`uv-callback-error?`, (b) log/handle it, and (c) simply call `uv-run` again
on the *same* loop object — nothing about the loop or its handles needs
re-creating; `uv-run` clears only its own `running?` flag in the
`dynamic-wind` after-thunk (`loop.sls:62-63`), leaving the loop `'open`.

**The trap**: `(set-loop-deferred-error-list! loop '())` runs at the very
**start** of every `uv-run` call, *before* the dynamic-wind
(`loop.sls:59`) — so if two or more callbacks raise within one run, only the
first is delivered by the raise from that call; the rest sit in
`uv-loop-deferred-errors` and are **silently discarded** the instant the
server calls `uv-run` again without having read them first. The correct
pattern is:

```scheme
(guard (e ((uv-callback-error? e)
           (log-error e)
           (for-each log-error (uv-loop-deferred-errors loop))))  ; BEFORE the next uv-run
  (uv-run loop 'default))
```

`docs/api.md:23` documents the deferred list as "Everything callbacks raised
this run *after* the first", but does not spell out the reset-on-next-call
trap explicitly in the reference table — it is only derivable from the code
above and from the "three rules" in `docs/quickstart.md:96-100`. Also note:
the delivered error carries the raised *object*, not which handle/connection
raised it — for per-connection attribution the server's own callback bodies
should catch and tag their own exceptions before letting anything escape to
this binding-level net, which is a last-resort safety mechanism, not a
routing layer.

No binding gap; flagged because it is exactly the kind of ordering
requirement a first implementation is likely to miss.

## 10. Close ownership: what a second `uv-close!` does — PRESENT, documented, and directly tested

`real-close-handle!` only acts when the handle is still `'open`; a second
call while `'closing` is a complete, silent no-op:

```
src/libuv/private/handles.sls:477-486
  ;; Starting close is idempotent and asynchronous. A repeated call cannot
  ;; replace the original on-close callback.
  (define (real-close-handle! handle on-close)
    (require-handle handle 'uv-close!)
    (unless (or (not on-close) (procedure? on-close))
      (raise (make-uv-invalid-argument 'uv-close! 'on-close-not-a-procedure)))
    (when (eq? (handle-state handle) 'open)
      (set-handle-on-close! handle on-close)
      (set-handle-state! handle 'closing)
      (uv-close-native (handle-pointer handle 'uv-close!))))
```

It does not raise, does not store the second `on-close`, and that second
callback **never runs**. This is directly, currently tested and passing:

```
tests/test-timer.sps:421-437
  (uv-close! t2 (lambda () (set! t2-second-thunk 'second-thunk-ran)))
  ...
  (test-equal "a second uv-close! while 'closing ignored its on-close argument"
    'second-thunk-never-ran t2-second-thunk)
```

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-timer.sps
%%%% Starting test timer
# of expected passes      128
$ echo exit=$?
exit=0
```

Documented explicitly at `docs/api.md:267-274` ("A second `uv-close!`
silently discards its callback ... this applies to every handle kind") and
in the design doc (`.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md`
§9, which is also where chez-http-server's own architecture doc is cited as
the place to record the connection-ownership protocol this implies).

**Consequence for the server**: whatever code deregisters a connection from
its tracking table must do so from the *first* (and only guaranteed)
`on-close`; every other place that might independently want to close the
same handle (an idle-timeout firing at the same moment as a read-error
handler, for instance) must either check `uv-handle-open?` first or, better,
funnel all close-initiation through one owning code path per connection —
capture peer identity at accept, register before the first read, close only
through that one path, deregister only from its `on-close`. This is exactly
the protocol the chez-libuv design doc defers to
`.plans/chez-http-server-architecture.md` to specify.

No binding gap.

## 11. Signal watching for SIGTERM/SIGINT and the SIGINT caveat — PRESENT and well documented (ADR-0017)

```
src/libuv/signal.sls:1-84  (make-uv-signal, uv-signal-start!,
                             uv-signal-start-oneshot!, uv-signal-stop!)
```

Watchable set is the closed nine-symbol vocabulary minus `sigkill`/`sigstop`
(`'signal-unwatchable`); a watcher's mode (continuous vs. oneshot) is fixed
by its first start verb and the other verb raises `'signal-mode-fixed`
thereafter (measured vendor ratchet, `.plans/decisions/0017-...md:54-84`).
The documented graceful-shutdown pattern is exactly what chez-http-server
needs — first `SIGTERM` drains, a second kills, because the disposition
reverts to `SIG_DFL` once the oneshot fires:

```
docs/api.md:337-348
(define watcher (make-uv-signal loop))
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    ;; close the listener, start the drain timer, then:
    (uv-close! watcher)))
(uv-run loop 'default)
```

**SIGINT caveat**, measured on both platforms per the v0.4 spike and stated
plainly: watching `sigint` takes it away from Chez's own runtime
(`register-signal-handler`/`keyboard-interrupt-handler`) while armed; after
`uv-signal-stop!` (or oneshot auto-disarm) the disposition is `SIG_DFL`, not
whatever was installed before, so a subsequent Ctrl-C **terminates the
process immediately** rather than going through Chez's interrupt handling
(`docs/api.md:350-361`, `.plans/decisions/0017-signal-watching-vocabulary-and-mode.md:112-124`).
Rearming a oneshot watcher from inside its own delivery callback silently
does not take effect (vendor auto-stop runs after the callback returns) —
rearm from a later dispatch (`docs/api.md:359-361`).

```
tests/test-signal.sps → 49/49 expected passes, exit 0 (this run).
```

No gap; the server should treat SIGINT the same as SIGTERM (a watcher, not
Chez's default handler) and accept that once shutdown finishes and the
watcher is closed, a further Ctrl-C is a hard kill.

## 12. `uv-tcp-nodelay!`, peer address, sockname — ALL PRESENT

```
src/libuv/tcp.sls:8-11    (export list includes all three)
src/libuv/tcp.sls:52,70-91   uv-tcp-peer-address    (uv_tcp_getpeername)
src/libuv/tcp.sls:93-112     uv-tcp-sockname-address (uv_tcp_getsockname)
src/libuv/tcp.sls:53-70      uv-tcp-getsockname-port (ephemeral-port-after-bind-0 case)
src/libuv/tcp.sls:160-168    uv-tcp-nodelay!         (uv_tcp_nodelay, boolean-typed)
```

No gap.

## 13. TCP keepalive, SO_REUSEPORT, multi-loop/multi-process scaling — MISSING (keepalive, REUSEPORT); multi-loop viable only single-threaded

**Keepalive and REUSEPORT are absent.** Exhaustive search across the whole
repository (excluding `vendor/`, `build/`, `tests/tmp/`) finds zero
occurrences:

```
$ rg -in "keepalive|reuseport|reuse_port" . -l | grep -v '^\./vendor\|^\./build\|^\./tests/tmp'
(no output)
```

and the complete list of every bound `uv_*` symbol
(`src/libuv/private/native.sls:223-818`, the full export list at
`native.sls:6-77`) contains no `uv_tcp_keepalive`. `uv-tcp-bind!` hardcodes
its native `flags` argument to `0` — there is no way to pass
`UV_TCP_IPV6ONLY` or any REUSEPORT-style flag through the current API:

```
src/libuv/tcp.sls:42-51
  (define (uv-tcp-bind! tcp ip port)
    ...
    (uv-check (uv-tcp-bind (handle-pointer tcp 'uv-tcp-bind!) addr 0)
              'uv-tcp-bind!))
```

**Multi-loop, single OS thread: works fine**, demonstrated by the test suite
itself — `tests/test-flow.sps` alone runs three independent loops
(`loop`, `bloop`, `cloop`) sequentially in one process
(`tests/test-flow.sps:28,150,263`), and `tests/test-tcp.sps` runs several
more (`el`, `pl`, `vl`, `cl`) the same way.

**Multi-loop across multiple OS threads: not supported.** The pointer
registry is a single, process-wide, *unsynchronized* hashtable, shared by
every loop and every thread that might exist in the process:

```
src/libuv/private/handles.sls:217-218
  ;; Pointer values may be bignums, so registry identity uses eqv?, not eq?.
  (define registry (make-eqv-hashtable))
```

The callback-dispatch table is likewise one process-wide table, installed
exactly once, with the FFI trampolines themselves also process-global:

```
src/libuv/private/handles.sls:515-517
  ;; Native callback slots are installed once; this table permits each policy
  ;; implementation to arrive later without rebinding a native trampoline.
  (define dispatch-table (make-eq-hashtable))
src/libuv/private/native.sls:599-602
  ;; One process-global slot and locked trampoline per callback type.
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit walk signal))
```

The one mutex that does exist in the binding
(`src/libuv/private/native.sls:849-850`, `init-mutex`) guards only the
one-time shim/version-check initialization, not runtime handle or registry
access:

```
src/libuv/private/native.sls:849-850
  ;; Initialization is process-global and serialized in Scheme for portability.
  (define init-mutex (make-mutex))
```

`uv_async` is also not bound (see item 14), so even a caller willing to hand-
roll its own locking around the registry would have no supported way for
one thread to wake another thread's blocked `uv_run` from outside its own
loop thread.

**Consequence for scaling chez-http-server beyond one core**: a **pre-fork
multi-process** model — bind + listen once, then `fork()` N worker
processes, each calling `make-uv-loop` fresh *after* the fork and inheriting
the already-bound-and-listening fd — is the only scaling path this binding
supports today (separate address spaces sidestep the shared-registry
problem entirely; the classic accept()-races-across-forked-children pattern
needs no `SO_REUSEPORT`). A thread-per-core model within one process is
unsafe as-is. Chez's own fork/process primitives, not chez-libuv's
`(libuv process)` module (which is for spawning unrelated child *programs*,
not for forking the current process), would drive this.

**Proposed smallest upstream changes**:
- `uv-tcp-keepalive! : uv-tcp boolean [exact-nonnegative-integer] -> unspecified`,
  wrapping `uv_tcp_keepalive(handle, enable, delay)` — same shape as the
  existing `uv-tcp-nodelay!` (`src/libuv/tcp.sls:160-168`); small, additive,
  no interaction with any other decision.
- A `flags` argument on `uv-tcp-bind!` (or a dedicated
  `uv-tcp-bind-reuseport!`) plumbing `SO_REUSEPORT`/libuv's `UV_TCP_REUSEPORT`
  — note this needs a version check against the pinned libuv 1.52.1 before
  naming the exact constant, since portable `UV_TCP_REUSEPORT` support
  arrived at a specific libuv version this report did not independently
  confirm; the shim's `chez_uv_constant_table` would gain one row
  (`src/libuv-shim.c:22-143` pattern) exactly as every other constant did.

Both are out of scope for chez-http-server's presumed single-process v1 and
are genuinely server-layer scaling decisions (worker count, socket-sharing
strategy), not binding design, per the same reasoning ADR-0018 used to
reject binding-owned write queueing.

## 14. Thread-safety facts and absence of `uv_async` — MISSING `uv_async`; registry confirmed unsynchronized

Confirmed absent by the same full-export-list check as item 5/13 — no
`uv_async_init`/`uv_async_send` anywhere in `native.sls`, and no mention
outside the shim's own single-threaded-diagnostics comment and the v0.1
spike's explicitly-deferred-gap note:

```
$ rg -in "uv_async|uv-async" . -l | grep -v '^\./vendor\|^\./build\|^\./tests/tmp'
./src/libuv-shim.h
./spike/FINDINGS.md
./spike/probe.c
./spike/01-callback-gc.ss

src/libuv-shim.h:20
  /* Counters are single-threaded diagnostics. Without CHEZ_LIBUV_DEBUG_COUNTERS, ...

spike/FINDINGS.md:366-369
  - **`__collect_safe` × callback re-entry.** ... v0.1 is single-threaded and
    ADR-0008 scopes it out; mixing the two axes in one experiment would make
    any failure un-attributable. This is a known, named gap, not an
    oversight — it must be re-opened before any multi-threaded or
    `__collect_safe` use of `uv_run` is introduced.
```

The registry (`handles.sls:218`, quoted in item 13) is a bare
`make-eqv-hashtable` with no lock around `registry-register!`/
`registry-ref`/`registry-deregister!` (`handles.sls:233-260`). Combined with
the absence of `uv_async`, this means: (a) within one thread, everything
works (that is the entire test suite's operating mode); (b) across threads,
neither the data structure nor a cross-thread wake primitive exists — this
is a *named, explicit* deferral in chez-libuv's own spike findings, not an
oversight the binding forgot to mention.

**Proposed smallest upstream change**, if/when chez-http-server ever wants a
thread-per-core model instead of pre-fork multi-process: bind `uv_async_init`/
`uv_async_send` (`uv-async : uv-loop procedure -> uv-async-handle`,
`uv-async-send! : uv-async-handle -> unspecified`) plus a lock (e.g. a
`mutex`-guarded hashtable, or per-loop registries instead of one process-
global table) around the registry. This is a materially larger change than
items 5/13's additions — it touches the core GC-root data structure
(ADR-0007/ADR-0008) — and is exactly the kind of change the v0.1 spike
flagged as needing its own re-opened investigation, not a quick patch.

## 15. Windows status — explicitly deferred (ADR-0004), not a silent gap

```
.plans/decisions/0004-windows-deferred-design-clean.md:1-67
  # ADR-0004: Defer Windows CI while keeping the design Windows-clean
  ...
  ## Decision
  v0.1 verifies Linux and macOS only in CI. The design stays strictly portable
  in the meantime: no POSIX-only APIs in `libuv-shim.c`/`.h`, and every struct
  layout this binding depends on is obtained from the shim's `sizeof`/`offsetof`
  getters ... rather than hardcoded ...
  The LLP64 `long` caveat on `chez_uv_constant`'s out-param is recorded here as
  a known, currently-inert limitation: it must be revisited — most likely by
  widening the out-param type — before any constant needing more than 32 bits
  is added to a Windows-targeting build.
```

`src/libuv/handle.sls:51-52` independently corroborates the Windows-vs-Unix
platform split baked into the design (`uv-send-buffer-size`/
`uv-recv-buffer-size`: "tcp/pipe/UDP on Unix, but only tcp/UDP on Windows").
For chez-http-server's stated v1 target (macOS arm64, per the task's own
"Toolchain" facts), this is irrelevant; it only matters if/when
chez-http-server's own house rule ("portable across darwin/linux/windows...
Windows deferred", per its `AGENTS.md`) is acted on — at which point this is
the exact, already-recorded standing limitation to check against (the LLP64
`long` truncation risk in particular, since it is "currently inert" only
because no constant needing >32 bits has been added yet).

No new gap; chez-http-server's own `AGENTS.md` already defers Windows in the
same terms.

---

## Summary table

| # | Need | Status | Upstream/workaround |
|---|---|---|---|
| 1 | Accept loop / backlog | PRESENT | — |
| 2 | Sub-64KiB per-conn read buffer | PRESENT, range [1,∞) | — |
| 3 | read-stop/start & closing race | PRESENT, sharp edge | server must guard every `uv-read-stop!` with `uv-handle-open?` |
| 4 | Write span / ordering / on-complete-on-close | PRESENT, MEASURED | — |
| 5 | Vectored/try writes | MISSING | server concatenates headers+body; propose `uv-writev!` upstream |
| 6 | Shutdown half-close ordering | PRESENT, MEASURED | — |
| 7 | Timer cost @10k, `uv-timer-again!`, `uv-now` | PRESENT, MEASURED (152B/timer) | — |
| 8 | `uv-run` once/nowait, reentry guard, timer trap | PRESENT, documented trap | driver must use predicate loops, not call counts |
| 9 | Callback-error surfacing, loop stays alive | PRESENT, ordering trap | read `uv-loop-deferred-errors` before the next `uv-run` |
| 10 | Close ownership / second `uv-close!` | PRESENT, MEASURED | server centralizes close-initiation per connection |
| 11 | SIGTERM/SIGINT graceful shutdown | PRESENT | treat SIGINT like SIGTERM via a watcher |
| 12 | nodelay / peer / sockname | PRESENT | — |
| 13 | keepalive / SO_REUSEPORT / scaling | MISSING | pre-fork multi-process workaround now; propose `uv-tcp-keepalive!` + bind-flags upstream |
| 14 | Thread-safety / `uv_async` | MISSING (`uv_async`), registry unsynchronized | single-thread-per-loop only; propose `uv-async` + locked registry upstream (larger change) |
| 15 | Windows | Deferred (ADR-0004) | irrelevant to v1; matches chez-http-server's own deferral |

---

## Commands run and their exact exit codes (this session, 2026-09-19)

```
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-tcp.sps    → exit 0
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-timer.sps  → exit 0, 128 passes
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-loop.sps   → exit 0, 138 passes
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-signal.sps → exit 0, 49 passes
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-stream.sps → exit 0, 12 passes
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-flow.sps   → exit 0, 23 passes
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-echo.sps   → exit 0, 32 passes
CHEZSCHEMELIBDIRS=src:build/scheme-libs      chez --program sizeof-probe3.sps      → sizeof(uv_timer_t)=152, sizeof(uv_tcp_t)=264
CHEZSCHEMELIBDIRS=src:build/scheme-libs      chez --program sizeof-probe.sps       → created/closed 10000 timers OK
```

None of these commands modified the chez-libuv repository; the two ad-hoc
probe scripts live only under this scratchpad
(`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/sizeof-probe*.sps`).
Full captured stdout/stderr for every suite run above is saved alongside
this report at `<scratchpad>/test-*-output.txt`.

## Open questions for the synthesis agent

- The vendor-source claim (`unix/stream.c:454,464`, UV_ECANCELED-on-close
  behaviour) in chez-libuv's own v0.5 design doc was not independently
  re-verified against actual libuv 1.52.1 C source in this sandbox (only
  headers/compiled dylib were available via Homebrew); the binding's own
  observable behaviour around it *was* measured directly (item 4) and is
  sufficient for chez-http-server's design purposes, but a reader wanting
  the underlying libuv-internals citation re-verified would need the actual
  libuv source tree.
- Item 13's proposed `SO_REUSEPORT` upstream change needs the exact libuv
  version `UV_TCP_REUSEPORT` shipped in (not confirmed against 1.52.1's
  actual capability here) before it is filed as a real ADR/PR against
  chez-libuv — the task only established that the binding does not
  currently expose it, not whether the pinned libuv even supports it.
