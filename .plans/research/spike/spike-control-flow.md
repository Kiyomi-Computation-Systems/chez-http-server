# Spike: Scheme control flow inside chez-libuv callbacks

Date: 2026-09-19. Everything below was measured on this machine unless it is a
quotation from a document, in which case the URL or file:line is given.
Every experiment is its own `.sps` file, run in its own process under
`gtimeout`, twice (some negative experiments four times, stated where so).
Where the two runs differ the difference is named.

## Toolchain (measured)

| Item | Value | Command |
|---|---|---|
| Chez Scheme | 10.4.1, `(threaded?)` = `#t`, `(machine-type)` = `tarm64osx` | `chez --version`; `smoke.sps` below |
| libuv | 1.52.1 (Homebrew), `(uv-version)` = `"1.52.1"` | `brew list --versions libuv`; `smoke.sps` |
| macOS | 26.6.2 (25G83), arm64 | `sw_vers`, `uname -m` |
| C compiler | Apple clang 21.0.0 (clang-2100.1.1.101) | `cc --version` |
| timeout | `/opt/homebrew/bin/gtimeout` present (and `timeout`) | `which gtimeout timeout` |
| chez-libuv | v0.5.0 checkout at /Users/yuzu/github/chez-libuv, shim already built | `(import (libuv))` works, see smoke |

Library path used for every run (the incantation from the task, plus the spike
directory for the shared helper library):

```sh
export CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
```

Runner (`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/run.sh`, verbatim) -- runs a script twice, caps each run's saved
output at 64 KiB (an early E1b variant flooded 64 MB, see E1b), appends
`exit=<gtimeout status>`:

```sh
#!/bin/sh
# usage: run.sh NAME.sps [timeout-seconds]  -- runs the program twice in fresh
# processes under gtimeout, saving out/NAME.runN.txt with the exit code appended.
# Output is capped at 64 KiB per run (a runaway loop flooded 64 MB once).
S=/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
export CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:$S
T=${2:-60}
for i in 1 2; do
  out=$S/out/${1%.sps}.run$i.txt
  gtimeout $T chez --program $S/$1 > $out.raw 2>&1
  rc=$?
  if [ $(wc -c < $out.raw) -gt 65536 ]; then
    head -c 65536 $out.raw > $out; echo "" >> $out; echo "[output truncated at 64 KiB; raw size $(wc -c < $out.raw) bytes]" >> $out
  else cp $out.raw $out; fi
  rm -f $out.raw
  echo "exit=$rc" >> $out
  echo "== $1 run $i (gtimeout $T) =="; cat $out
done
```

Shared helper library `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/spike/common.sls` (verbatim). `show-condition`
prints the record-type names of every simple condition in a compound condition
plus Chez's `display-condition` rendering, so the condition kinds quoted below
are what Chez itself reported:

```scheme
#!r6rs
;; Shared helpers for the control-flow spike. Pure printing/timing; no libuv.
(library (spike common)
  (export say show-condition guarded now-ms condition-kinds)
  (import (rnrs)
          (only (chezscheme) display-condition current-time time-second
                time-nanosecond record-rtd record-type-name))
  (define (say . xs)
    (for-each display xs) (newline) (flush-output-port (current-output-port)))
  ;; condition-kinds : object -> (listof symbol)
  (define (condition-kinds c)
    (if (condition? c)
        (map (lambda (s) (record-type-name (record-rtd s))) (simple-conditions c))
        (list 'non-condition-raise-object c)))
  (define (show-condition tag c)
    (say tag " | kinds: " (condition-kinds c))
    (display tag) (display " | display-condition: ")
    (if (condition? c) (display-condition c) (write c))
    (newline) (flush-output-port (current-output-port)))
  ;; guarded : string thunk -> object | 'raised
  (define (guarded tag thunk)
    (guard (e (#t (show-condition tag e) 'raised)) (thunk)))
  (define (now-ms)
    (let ((t (current-time)))
      (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000)))))
```

Smoke test `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/smoke.sps`:

```scheme
(import (rnrs) (only (chezscheme) threaded? machine-type) (libuv) (spike common))
(say "threaded? " (threaded?) " machine-type " (machine-type) " libuv " (uv-version))
(define loop (make-uv-loop))
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (t) (say "timer fired")) 5 0)
(say "uv-run -> " (uv-run loop 'default))
(uv-loop-teardown! loop)
(say "ok")
```

```text
threaded? #t machine-type tarm64osx libuv 1.52.1
timer fired
uv-run -> #f
ok
exit=0
```

```text
threaded? #t machine-type tarm64osx libuv 1.52.1
timer fired
uv-run -> #f
ok
exit=0
```

### Facts about chez-libuv relied on below (file:line, read today)

- `uv_run` is bound as a plain `foreign-procedure`, **without** `__collect_safe`:
  `/Users/yuzu/github/chez-libuv/src/libuv/private/native.sls:242`
  `(define uv-loop-run   (foreign-procedure "uv_run"        (uptr int) int))`.
  This is what makes E5c's stall happen.
- The thirteen trampolines are plain `foreign-callable`s (no `__collect_safe`):
  `native.sls:650-744`.
- `uv-run` sets a `running` flag inside `dynamic-wind` and refuses re-entry:
  `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:55-63`:
  ```scheme
  (when (loop-running? loop)
    (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
  ...
  (let ((rc (dynamic-wind
             (lambda () (set-loop-running! loop #t))
             (lambda () (uv-loop-run ptr mode-int))
             (lambda () (set-loop-running! loop #f)))))
  ```
  `uv-loop-close!` (loop.sls:98-99) and `uv-loop-teardown!` (loop.sls:124-125)
  have the same guard. Because the flag is cleared by a `dynamic-wind` *after*
  thunk, any non-local exit out of `uv-run` (a raise, an engine expiry) clears
  it -- E4d shows the consequence.
- Every callback runs under `dispatch-guarded`
  (`/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:302-304`):
  ```scheme
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))
  ```
  and the stored error is re-raised from `uv-run` / `uv-loop-close!` wrapped in
  `&uv-callback-error` (loop.sls:38-44, `deliver-pending-callback-error!`).
  The timer path is `timer-dispatch` at handles.sls:316-324.
- `uv-loop-teardown!`'s drain (loop.sls:115-117, 129-146) catches
  `&uv-callback-error` from its own `uv-run`, finishes closing, and re-raises
  the stored error *after* `uv-loop-close!` -- so a "teardown -> raised" below
  with a `&uv-callback-error` still means the loop was closed.

## E0: what the Chez Scheme User's Guide says

URL fetched (HTTP 200, 202550 bytes, saved as `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/csug-foreign.html`, text
extraction in `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/csug-foreign.txt`):
<https://cisco.github.io/ChezScheme/csug10.0/foreign.html>

Command:

```sh
curl -sS -o csug-foreign.html -w "HTTP %{http_code} %{url_effective}\n" https://cisco.github.io/ChezScheme/csug10.0/foreign.html
# -> HTTP 200 https://cisco.github.io/ChezScheme/csug10.0/foreign.html
```

**Sentence in Section 4.3 (foreign-callable) pointing at 4.4, verbatim:**

> Mixed use of foreign-callable and foreign-procedure may result in nesting of foreign and Scheme calls, and this results in some interesting considerations when continuations are involved, directly or indirectly (as via the default exception handler). See Section 4.4 for a discussion of the interaction between foreign calls and continuations.

**Section 4.4 "Continuations and Foreign Calls", verbatim and complete** (the
`with-exit-proc` code listing is reproduced as extracted, line breaks as in the
page text):

```text
Section 4.4. Continuations and Foreign Calls

foreign-callable and foreign-procedure allow arbitrary
nesting of foreign and Scheme calls.
Because other languages do not support the fully general first-class
continuations of Scheme, the interaction between continuations and
nested calls among Scheme and foreign procedures is problematic.
Chez Scheme handles this interaction in a general manner by trapping
attempts to return to stale foreign contexts rather than by restricting
the use of continuations directly.
A foreign context is a foreign frame and return point corresponding to
a particular call from a foreign language, e.g., C, into Scheme.
A foreign context becomes stale after a normal return to the context or
after a return to some other foreign context beneath it on the control
stack.

As a result of this treatment, Scheme continuations may be used to
throw control either upwards or downwards logically through any mix
of Scheme and foreign frames.
Furthermore, until some return to a foreign context is actually performed,
all return points remain valid.
In particular, this means that programs that use continuations
exclusively for nonlocal exits never attempt to return to a
stale foreign context.
(Nonlocal exits themselves are no problem and are implemented
by the C library function longjmp or the equivalent.)
Programs that use continuations more generally also function
properly as long as they never actually return to a stale foreign context,
even if control logically moves past stale foreign contexts via invocation
of continuations.

One implication of this mechanism is that the C stack pointer is not
automatically restored to its base value when a continuation is used on
the Scheme side to perform a nonlocal exit.
If the program continues to run after the nonlocal exit, any further
build-up of the C stack will add to the existing build up, which might
result in a C stack overflow.
To avoid this situation, a program can arrange to set up a single C
call frame before obtaining the continuation and return to the C frame
after the nonlocal exit.
The procedure with-exit-proc below arranges to do this without
involving any C code.

(define with-exit-proc

  (lambda (p)

    (define th (lambda () (call/cc p)))

    (define-ftype ->ptr (function () ptr))

    (let ([fptr (make-ftype-pointer ->ptr th)])

      (let ([v ((ftype-ref ->ptr () fptr))])

        (unlock-object

          (foreign-callable-code-object

            (ftype-pointer-address fptr)))

        v))))
with-exit-proc behaves like call/cc except it resets
the C stack when the continuation is invoked.
To do this, it creates an ftype-pointer representing a foreign-callable
entry point for th and creates a Scheme-callable procedure for
that entry point.
This creates a wrapper for th that involves a C call.
When a call to the wrapper returns, either by explicit invocation of the
continuation passed to p or by a normal return from p,
the C stack is reset to its original value.
```

**On threads (Section 4.3 and 4.8, verbatim excerpts):**

> The __collect_safe convention for a callable activates a calling thread if the thread is not already activated, and the thread's activation state is reverted when the callable returns.

> If a foreign procedure that is called with __collect_safe can invoke callables, then each callable should also be declared with __collect_safe so that the callable reactivates the thread.

> Since active threads operating in C code prevent the storage management system from garbage collecting, a thread should be deactivated via Sdeactivate_thread or through a foreign-procedure __collect_safe declaration whenever the thread may spend a significant amount of time in C code. This is especially important whenever the thread calls a C library function, like read, that may block indefinitely.

> A thread created via the Scheme procedure fork-thread starts [...]; a thread created by some mechanism other than fork-thread must, however, be activated before it can access Scheme data or execute Scheme code. A foreign callable that is declared with __collect_safe can activate a calling thread. Otherwise, Sactivate_thread must be used to activate a thread.

(The bracketed ellipsis marks a sentence boundary lost in HTML-to-text
extraction; the two halves are consecutive sentences in the page.)

**Engines and dynamic-wind:** a case-insensitive search of the extracted page
text for `engine` and for `dynamic-wind` returned **0 matches each** (script
output: `#####  engine 0`, `#####  dynamic-wind 0`). The foreign-interface
chapter says nothing about either. `continuation` matches: 3 regions (the
two quoted above plus the `with-exit-proc` listing); `thread`: 44 matches, all
in the `__collect_safe` / `Sactivate_thread` material quoted above.

**libuv's own statements (fetched today, HTTP 200 each, saved in `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/`):**

- <https://docs.libuv.org/en/v1.x/loop.html> under `uv_run`: "uv_run() is not reentrant. It must not be called from a callback."
- <https://docs.libuv.org/en/v1.x/design.html>: "The libuv event loop (or any other API involving the loop or handles, for that matter) is not thread-safe except where stated otherwise."

## Experiments

### E1a: call/1cc captured in timer A's callback, invoked from timer B's callback (same uv-run)

Timer A (10 ms) captures a one-shot continuation inside its callback, stores it, returns normally. Timer B (40 ms) invokes it with `'from-B`.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e1a-call1cc-from-other-callback.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e1a-call1cc-from-other-callback.sps
```

Source (verbatim):

```scheme
;; E1a: capture call/1cc inside timer A's callback, return normally, invoke it
;; from timer B's callback (same uv-run).
(import (rnrs) (only (chezscheme) call/1cc) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define a-entries 0)
(define ta (make-uv-timer loop))
(define tb (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (set! a-entries (+ a-entries 1))
    (say "A: entered, entry #" a-entries)
    (let ((v (call/1cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/1cc returned " v))
    (say "A: body end, returning normally to libuv"))
  10 0)
(uv-timer-start! tb
  (lambda (t)
    (say "B: entered; invoking saved continuation with 'from-B")
    (saved 'from-B)
    (say "B: after invocation (prints only if the invocation returned)"))
  40 0)
(say "top: uv-run 'default -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: deferred errors: " (length (uv-loop-deferred-errors loop)))
(say "top: loop alive? " (uv-loop-alive? loop))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: a-entries = " a-entries)
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e1a-call1cc-from-other-callback.run1.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/1cc returned first-time
A: body end, returning normally to libuv
B: entered; invoking saved continuation with 'from-B
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: deferred errors: 0
top: loop alive? #f
teardown | kinds: (&uv-callback-error &assertion &format &message &irritants &continuation)
teardown | display-condition: Exception: attempt to invoke shot one-shot continuation
top: teardown -> raised
top: a-entries = 1
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e1a-call1cc-from-other-callback.run2.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/1cc returned first-time
A: body end, returning normally to libuv
B: entered; invoking saved continuation with 'from-B
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: deferred errors: 0
top: loop alive? #f
teardown | kinds: (&uv-callback-error &assertion &format &message &irritants &continuation)
teardown | display-condition: Exception: attempt to invoke shot one-shot continuation
top: teardown -> raised
top: a-entries = 1
top: done
exit=0
```

**Observed (both runs byte-identical):**

- A's body did **not** resume ("A: call/1cc returned from-B" never printed). Nothing crashed, nothing hung.
- `uv-run` raised a bare Chez `&assertion` -- `attempt to return to stale foreign context` -- **not** wrapped in `&uv-callback-error`, i.e. the raise escaped the callback's `dispatch-guarded` and abandoned `uv_run`'s C frames.
- `uv-loop-deferred-errors` was empty, `uv-loop-alive?` was `#f`.
- `uv-loop-teardown!` closed the loop but re-raised a *stored* callback error: `&uv-callback-error` composed with `attempt to invoke shot one-shot continuation`.

Reading of the sequence consistent with both messages and with `dispatch-guarded` / `deliver-pending-callback-error!` (loop.sls:38-44): invoking the shot one-shot continuation raised "attempt to invoke shot one-shot continuation" in the *target* (A's) dynamic context, where A's `dispatch-guarded` recorded it as the loop's pending error and returned normally through A's trampoline; that return hit A's stale foreign context and Chez raised "attempt to return to stale foreign context" outside any `dispatch-guarded`, which is what the top-level guard saw. Exit status 0 in both runs; teardown closed the loop.

### E1b: call/1cc captured in a callback, invoked from Scheme top level after uv-run returned

**First version of this script (no at-most-once guard) looped forever and was killed by the runner's output limit.** Its output exceeded 64 MB; the tool preview (persisted at `/Users/yuzu/.claude/projects/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/tool-results/b14kps0pa.txt`) began:

```text
== e1b-call1cc-from-toplevel.sps run 1 ==
A: entered, entry #1
A: call/1cc returned first-time
A: body end, returning normally to libuv
top: uv-run 'default -> #f
top: loop alive? #f
top: invoking saved continuation from top level with 'from-top
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: loop alive? #f
...
```

and repeated from "top: uv-run 'default -> raised" indefinitely. Cause: the continuation captured inside the callback contains the *whole* rest of the program -- A's trampoline return, `uv-run`, the top-level `guard`, and every top-level form after it -- so once the stale-context trap is caught by the top-level guard, the program's own "invoke the saved continuation" form runs again. The script below invokes at most once. (The raw output files of that first version were deleted to stay under the tool's persist limit; the preview above is the only record.)

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e1b-call1cc-from-toplevel.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e1b-call1cc-from-toplevel.sps
```

Source (verbatim):

```scheme
;; E1b: capture call/1cc inside timer A's callback, let uv-run return, invoke
;; the saved continuation from Scheme top level -- AT MOST ONCE, because the
;; first version of this script re-invoked it forever (the continuation
;; contains the rest of the top-level program).
(import (rnrs) (only (chezscheme) call/1cc) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define a-entries 0)
(define invocations 0)
(define ta (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (set! a-entries (+ a-entries 1))
    (say "A: entered, entry #" a-entries)
    (let ((v (call/1cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/1cc returned " v))
    (say "A: body end, returning normally to libuv"))
  10 0)
(say "top: uv-run 'default -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: loop alive? " (uv-loop-alive? loop) " (this line runs again if the continuation re-enters here)")
(if (= invocations 0)
    (begin
      (set! invocations 1)
      (say "top: invoking saved continuation from top level with 'from-top")
      (say "top: invocation -> " (guarded "invoke" (lambda () (saved 'from-top) 'returned))))
    (say "top: already invoked once; not invoking again"))
(say "top: after invocation, a-entries = " a-entries " invocations = " invocations)
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e1b-call1cc-from-toplevel.run1.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/1cc returned first-time
A: body end, returning normally to libuv
top: uv-run 'default -> #f
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: invoking saved continuation from top level with 'from-top
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: already invoked once; not invoking again
top: after invocation, a-entries = 1 invocations = 1
teardown | kinds: (&uv-callback-error &assertion &format &message &irritants &continuation)
teardown | display-condition: Exception: attempt to invoke shot one-shot continuation
top: teardown -> raised
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e1b-call1cc-from-toplevel.run2.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/1cc returned first-time
A: body end, returning normally to libuv
top: uv-run 'default -> #f
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: invoking saved continuation from top level with 'from-top
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: already invoked once; not invoking again
top: after invocation, a-entries = 1 invocations = 1
teardown | kinds: (&uv-callback-error &assertion &format &message &irritants &continuation)
teardown | display-condition: Exception: attempt to invoke shot one-shot continuation
top: teardown -> raised
top: done
exit=0
```

**Observed (both runs byte-identical):** same two messages as E1a. The top-level line after `uv-run` printed twice, proving control re-entered the top-level program *after* `uv-run` inside the invoked continuation. Note `uv-run`'s `dynamic-wind` before-thunk re-ran on re-entry (running flag set) and the after-thunk ran on the escape, so teardown was permitted afterwards. Teardown closed the loop and re-raised the stored `shot one-shot continuation` callback error. Exit 0.

### E2a: full call/cc captured in timer A's callback, invoked from timer B's callback

Identical to E1a with `call/cc` instead of `call/1cc`.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2a-callcc-from-other-callback.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2a-callcc-from-other-callback.sps
```

Source (verbatim):

```scheme
;; E2a: capture call/cc inside timer A's callback, return normally, invoke it
;; from timer B's callback (same uv-run).
(import (rnrs) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define a-entries 0)
(define ta (make-uv-timer loop))
(define tb (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (set! a-entries (+ a-entries 1))
    (say "A: entered, entry #" a-entries)
    (let ((v (call/cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/cc returned " v))
    (say "A: body end, returning normally to libuv"))
  10 0)
(uv-timer-start! tb
  (lambda (t)
    (say "B: entered; invoking saved continuation with 'from-B")
    (saved 'from-B)
    (say "B: after invocation (prints only if the invocation returned)"))
  40 0)
(say "top: uv-run 'default -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: deferred errors: " (length (uv-loop-deferred-errors loop)))
(say "top: loop alive? " (uv-loop-alive? loop))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: a-entries = " a-entries)
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2a-callcc-from-other-callback.run1.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/cc returned first-time
A: body end, returning normally to libuv
B: entered; invoking saved continuation with 'from-B
A: call/cc returned from-B
A: body end, returning normally to libuv
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: deferred errors: 0
top: loop alive? #f
top: teardown -> ok
top: a-entries = 1
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2a-callcc-from-other-callback.run2.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/cc returned first-time
A: body end, returning normally to libuv
B: entered; invoking saved continuation with 'from-B
A: call/cc returned from-B
A: body end, returning normally to libuv
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: deferred errors: 0
top: loop alive? #f
top: teardown -> ok
top: a-entries = 1
top: done
exit=0
```

**Observed (both runs byte-identical):**

- A's body **did** resume inside B's dispatch: "A: call/cc returned from-B", "A: body end, returning normally to libuv".
- When A's trampoline then returned to C, Chez raised `attempt to return to stale foreign context` -- again a bare `&assertion`, again escaping `uv-run` without `&uv-callback-error` wrapping (it happens after `dispatch-guarded` has already returned).
- Unlike E1, **no stored callback error**: `uv-loop-teardown!` returned `ok`. Deferred errors 0, loop not alive. Exit 0.

This is exactly the CSUG 4.4 rule: control may move into the captured continuation, and the trap fires only at the actual return to the stale foreign context. B's own C frames (the `uv_run` iteration that dispatched B) were abandoned by the escape.

### E2b: full call/cc captured in a callback, invoked from Scheme top level after uv-run returned

E1b with `call/cc`; at-most-once guard kept.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2b-callcc-from-toplevel.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2b-callcc-from-toplevel.sps
```

Source (verbatim):

```scheme
;; E2b: capture call/cc inside timer A's callback, let uv-run return, invoke
;; the saved continuation from Scheme top level -- AT MOST ONCE, because the
;; first version of this script re-invoked it forever (the continuation
;; contains the rest of the top-level program).
(import (rnrs) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define a-entries 0)
(define invocations 0)
(define ta (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (set! a-entries (+ a-entries 1))
    (say "A: entered, entry #" a-entries)
    (let ((v (call/cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/cc returned " v))
    (say "A: body end, returning normally to libuv"))
  10 0)
(say "top: uv-run 'default -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: loop alive? " (uv-loop-alive? loop) " (this line runs again if the continuation re-enters here)")
(if (= invocations 0)
    (begin
      (set! invocations 1)
      (say "top: invoking saved continuation from top level with 'from-top")
      (say "top: invocation -> " (guarded "invoke" (lambda () (saved 'from-top) 'returned))))
    (say "top: already invoked once; not invoking again"))
(say "top: after invocation, a-entries = " a-entries " invocations = " invocations)
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2b-callcc-from-toplevel.run1.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/cc returned first-time
A: body end, returning normally to libuv
top: uv-run 'default -> #f
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: invoking saved continuation from top level with 'from-top
A: call/cc returned from-top
A: body end, returning normally to libuv
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: already invoked once; not invoking again
top: after invocation, a-entries = 1 invocations = 1
top: teardown -> ok
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2b-callcc-from-toplevel.run2.txt`; the last line is gtimeout's exit status):

```text
A: entered, entry #1
A: call/cc returned first-time
A: body end, returning normally to libuv
top: uv-run 'default -> #f
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: invoking saved continuation from top level with 'from-top
A: call/cc returned from-top
A: body end, returning normally to libuv
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: attempt to return to stale foreign context
top: uv-run 'default -> raised
top: loop alive? #f (this line runs again if the continuation re-enters here)
top: already invoked once; not invoking again
top: after invocation, a-entries = 1 invocations = 1
top: teardown -> ok
top: done
exit=0
```

**Observed (both runs byte-identical):** A's body resumed at top level ("A: call/cc returned from-top"), then the return to the stale foreign context trapped; caught by the top-level guard *inside* the continuation, so the post-`uv-run` top-level code ran a second time (the "loop alive?" line printed twice). Teardown `ok`. Exit 0.

### E2c: is the loop still usable after the stale-foreign-context trap escaped uv-run?

E2a, then arm a fresh timer and call `uv-run` again before teardown.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2c-callcc-loop-survives.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e2c-callcc-loop-survives.sps
```

Source (verbatim):

```scheme
;; E2c: after the stale-foreign-context trap escapes uv-run (E2a), is the loop
;; still usable? Arm a new timer, run again, then tear down.
(import (rnrs) (libuv) (spike common))
(define loop (make-uv-loop))
(define saved #f)
(define ta (make-uv-timer loop))
(define tb (make-uv-timer loop))
(uv-timer-start! ta
  (lambda (t)
    (let ((v (call/cc (lambda (k) (set! saved k) 'first-time))))
      (say "A: call/cc returned " v)))
  10 0)
(uv-timer-start! tb (lambda (t) (say "B: invoking saved") (saved 'from-B)) 40 0)
(say "top: uv-run #1 -> " (guarded "uv-run#1" (lambda () (uv-run loop 'default))))
(say "top: live handles: " (length (uv-loop-live-handles loop)) " states: "
     (map uv-handle-state (uv-loop-live-handles loop)))
(define tc (make-uv-timer loop))
(uv-timer-start! tc (lambda (t) (say "C: new timer fired after the trap")) 5 0)
(say "top: uv-run #2 -> " (guarded "uv-run#2" (lambda () (uv-run loop 'default))))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2c-callcc-loop-survives.run1.txt`; the last line is gtimeout's exit status):

```text
A: call/cc returned first-time
B: invoking saved
A: call/cc returned from-B
uv-run#1 | kinds: (&assertion &format &message &irritants &continuation)
uv-run#1 | display-condition: Exception: attempt to return to stale foreign context
top: uv-run #1 -> raised
top: live handles: 2 states: (open open)
C: new timer fired after the trap
top: uv-run #2 -> #f
top: teardown -> ok
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e2c-callcc-loop-survives.run2.txt`; the last line is gtimeout's exit status):

```text
A: call/cc returned first-time
B: invoking saved
A: call/cc returned from-B
uv-run#1 | kinds: (&assertion &format &message &irritants &continuation)
uv-run#1 | display-condition: Exception: attempt to return to stale foreign context
top: uv-run #1 -> raised
top: live handles: 2 states: (open open)
C: new timer fired after the trap
top: uv-run #2 -> #f
top: teardown -> ok
top: done
exit=0
```

**Observed (both runs byte-identical):** after the trap, both original timer handles were still `open`, the new timer fired on the second `uv-run`, which returned `#f` (ran dry), and teardown returned `ok`. So on this platform abandoning `uv_run`'s C frames mid-timer-dispatch left libuv's loop in a state that a later `uv_run` accepted. This is consistent with chez-libuv's own Q2 spike (`/Users/yuzu/github/chez-libuv/spike/FINDINGS.md`, "Q2 verdict": escaping across `uv_run` leaves the loop runnable). Whether the *abandoned* iteration's remaining phases (pending, idle, poll, check, closing) were skipped is not visible here; FINDINGS.md Q2 measured that a skipped `UV_EOF` is redelivered.

### E3: the two-level loop (coroutines started from top level; callbacks only enqueue)

Scheduler: a ready queue of thunks, `step!` runs one under `call/1cc` so `suspend!` returns to the scheduler; `await!` captures the coroutine's continuation (no foreign frame beneath it, since every coroutine was started by `step!` from top level), hands a `wake` closure to a registrar, and suspends. libuv callbacks only call `wake`, which enqueues the resumption. When the ready queue is empty the scheduler calls `(uv-run loop 'once)`.

Shown: (a) `sleep!` = timer wakeup; (b) `recv!`/`send!` = TCP `on-data` / write-completion wakeups, through nested plain Scheme frames (`handle-connection!` > `recv-message!` > `recv!` > `await!`); a "ticker" coroutine runs while the handler coroutine is parked; then three 10,000-cycle cost measurements.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e3-two-level-loop.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e3-two-level-loop.sps
```

Source (verbatim):

```scheme
;; E3: two-level loop. Coroutines are started from top level (no foreign frame
;; under them); libuv callbacks only enqueue wakeups; the scheduler alternates
;; draining the ready queue with (uv-run loop 'once).
(import (rnrs) (only (chezscheme) call/1cc cpu-time) (libuv) (spike common))
(define loop (make-uv-loop))
;; ---- scheduler: pure Scheme -------------------------------------------
(define ready '())
(define (push-ready! t) (set! ready (append ready (list t))))
(define current-return #f)
(define (suspend! v) (let ((r current-return)) (set! current-return #f) (r v)))
;; await! : ((any -> void) -> void) -> any
;; register receives WAKE; whoever calls (wake v) later enqueues the resumption.
(define (await! register)
  (call/1cc (lambda (k)
    (register (lambda (v) (push-ready! (lambda () (k v)))))
    (suspend! 'suspended))))
(define (spawn! name thunk)
  (push-ready! (lambda () (thunk) (say "sched: " name " finished") (suspend! 'finished))))
(define steps 0)
(define (step! t) (set! steps (+ steps 1)) (call/1cc (lambda (ret) (set! current-return ret) (t))))
(define uv-runs 0)
(define (scheduler-run!)
  (let lp ()
    (cond ((pair? ready) (let ((t (car ready))) (set! ready (cdr ready)) (step! t) (lp)))
          ((uv-loop-alive? loop) (set! uv-runs (+ uv-runs 1)) (uv-run loop 'once) (lp))
          (else 'idle))))
;; await/cc! : same as await! but with full call/cc, for the cost comparison
(define (await/cc! register)
  (call/cc (lambda (k)
    (register (lambda (v) (push-ready! (lambda () (k v)))))
    (suspend! 'suspended))))
;; ---- awaitable primitives (called from coroutines, i.e. from top level) --
(define (sleep! ms)
  (await! (lambda (wake)
    (let ((t (make-uv-timer loop)))
      (uv-timer-start! t (lambda (tm) (uv-close! t) (wake 'timer)) ms 0)))))
(define-record-type conn (fields stream (mutable inbox conn-inbox set-conn-inbox!) (mutable waiter conn-waiter set-conn-waiter!)))
(define (conn-deliver! c item)
  (let ((w (conn-waiter c)))
    (if w (begin (set-conn-waiter! c #f) (w item))
        (set-conn-inbox! c (append (conn-inbox c) (list item))))))
(define (recv! c)
  (if (pair? (conn-inbox c))
      (let ((x (car (conn-inbox c)))) (set-conn-inbox! c (cdr (conn-inbox c))) x)
      (await! (lambda (wake) (set-conn-waiter! c wake)))))
(define (send! c bv)
  (await! (lambda (wake) (uv-write! (conn-stream c) bv (lambda (err) (wake err))))))
(define (span->bytevector bv s e)
  (let ((out (make-bytevector (- e s)))) (bytevector-copy! bv s out 0 (- e s)) out))
(define (bv-append a b)
  (let ((out (make-bytevector (+ (bytevector-length a) (bytevector-length b)))))
    (bytevector-copy! a 0 out 0 (bytevector-length a))
    (bytevector-copy! b 0 out (bytevector-length a) (bytevector-length b)) out))
;; ---- the "handler": nested calls, each level a plain Scheme frame --------
(define (recv-message! c) (let ((x (recv! c))) x))          ; depth 2
(define (handle-connection! c)                              ; depth 1
  (let lp ((n 0))
    (let ((msg (recv-message! c)))
      (if (eq? msg 'eof)
          (begin (say "handler: eof after " n " messages; closing peer + server")
                 (uv-close! (conn-stream c)) (uv-close! server))
          (begin (say "handler: got \"" (utf8->string msg) "\" via handle-connection!>recv-message!>recv!>await!")
                 (let ((err (send! c (bv-append (string->utf8 "echo:") msg))))
                   (say "handler: send! completed, err=" err))
                 (lp (+ n 1)))))))
;; ---- server / client wiring: callbacks only enqueue ---------------------
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(uv-listen! server 128
  (lambda (err)
    (let* ((peer (uv-accept! server)) (c (make-conn peer '() #f)))
      (uv-read-start! peer
        (lambda (bv s e) (conn-deliver! c (span->bytevector bv s e)))
        (lambda () (conn-deliver! c 'eof))
        (lambda (err) (show-condition "server/on-error" err) (conn-deliver! c 'eof)))
      (spawn! "handler" (lambda () (handle-connection! c))))))
(define client (make-uv-tcp loop))
(define echoes 0)
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (uv-read-start! client
      (lambda (bv s e)
        (set! echoes (+ echoes 1))
        (say "client: echo #" echoes " = \"" (utf8->string (span->bytevector bv s e)) "\"")
        (if (= echoes 1)
            (uv-write! client (string->utf8 "world") (lambda (err) #f))
            (uv-shutdown! client (lambda (err) (uv-close! client)))))
      (lambda () #f)
      (lambda (err) (uv-close! client)))
    (uv-write! client (string->utf8 "hello") (lambda (err) #f))))
(spawn! "ticker" (lambda ()
  (let lp ((i 1)) (when (<= i 4) (sleep! 8) (say "ticker: tick " i " (ran while handler waits)") (lp (+ i 1))))))
(say "top: scheduler-run! -> " (scheduler-run!) " steps=" steps " uv-runs=" uv-runs " echoes=" echoes)
;; ---- cost: 10,000 suspend/resume cycles ---------------------------------
(define (bench name cycles register)
  (spawn! name (lambda ()
    (let ((t0 (now-ms)) (c0 (cpu-time)))
      (let lp ((i 0)) (when (< i cycles) (await! register) (lp (+ i 1))))
      (say "bench " name ": " cycles " cycles in " (- (now-ms) t0) " ms wall, " (- (cpu-time) c0) " ms cpu, steps=" steps " uv-runs=" uv-runs)))))
(set! steps 0) (set! uv-runs 0)
(bench "pure-suspend-resume (wake immediately, no uv-run)" 10000 (lambda (wake) (wake 'now)))
(scheduler-run!)
(set! steps 0) (set! uv-runs 0)
(define bt (make-uv-timer loop))
(bench "timer-wakeup (0ms one-shot timer + uv-run 'once per cycle)" 10000
       (lambda (wake) (uv-timer-start! bt (lambda (tm) (wake 'timer)) 0 0)))
(scheduler-run!)
(uv-close! bt)
(set! steps 0) (set! uv-runs 0)
(spawn! "pure-suspend-resume with full call/cc" (lambda ()
  (let ((t0 (now-ms)) (c0 (cpu-time)))
    (let lp ((i 0)) (when (< i 10000) (await/cc! (lambda (wake) (wake 'now))) (lp (+ i 1))))
    (say "bench pure-suspend-resume with full call/cc: 10000 cycles in " (- (now-ms) t0) " ms wall, " (- (cpu-time) c0) " ms cpu, steps=" steps))))
(scheduler-run!)
(say "top: final uv-run -> " (uv-run loop 'default))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e3-two-level-loop.run1.txt`; the last line is gtimeout's exit status):

```text
handler: got "hello" via handle-connection!>recv-message!>recv!>await!
handler: send! completed, err=#f
client: echo #1 = "echo:hello"
handler: got "world" via handle-connection!>recv-message!>recv!>await!
handler: send! completed, err=#f
client: echo #2 = "echo:world"
handler: eof after 2 messages; closing peer + server
sched: handler finished
ticker: tick 1 (ran while handler waits)
ticker: tick 2 (ran while handler waits)
ticker: tick 3 (ran while handler waits)
ticker: tick 4 (ran while handler waits)
sched: ticker finished
top: scheduler-run! -> idle steps=11 uv-runs=18 echoes=2
bench pure-suspend-resume (wake immediately, no uv-run): 10000 cycles in 0 ms wall, 1 ms cpu, steps=10001 uv-runs=0
sched: pure-suspend-resume (wake immediately, no uv-run) finished
bench timer-wakeup (0ms one-shot timer + uv-run 'once per cycle): 10000 cycles in 131 ms wall, 17 ms cpu, steps=10001 uv-runs=10000
sched: timer-wakeup (0ms one-shot timer + uv-run 'once per cycle) finished
bench pure-suspend-resume with full call/cc: 10000 cycles in 0 ms wall, 0 ms cpu, steps=10001
sched: pure-suspend-resume with full call/cc finished
top: final uv-run -> #f
top: teardown -> ok
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e3-two-level-loop.run2.txt`; the last line is gtimeout's exit status):

```text
handler: got "hello" via handle-connection!>recv-message!>recv!>await!
handler: send! completed, err=#f
client: echo #1 = "echo:hello"
handler: got "world" via handle-connection!>recv-message!>recv!>await!
handler: send! completed, err=#f
client: echo #2 = "echo:world"
handler: eof after 2 messages; closing peer + server
sched: handler finished
ticker: tick 1 (ran while handler waits)
ticker: tick 2 (ran while handler waits)
ticker: tick 3 (ran while handler waits)
ticker: tick 4 (ran while handler waits)
sched: ticker finished
top: scheduler-run! -> idle steps=11 uv-runs=18 echoes=2
bench pure-suspend-resume (wake immediately, no uv-run): 10000 cycles in 0 ms wall, 1 ms cpu, steps=10001 uv-runs=0
sched: pure-suspend-resume (wake immediately, no uv-run) finished
bench timer-wakeup (0ms one-shot timer + uv-run 'once per cycle): 10000 cycles in 132 ms wall, 18 ms cpu, steps=10001 uv-runs=10000
sched: timer-wakeup (0ms one-shot timer + uv-run 'once per cycle) finished
bench pure-suspend-resume with full call/cc: 10000 cycles in 0 ms wall, 0 ms cpu, steps=10001
sched: pure-suspend-resume with full call/cc finished
top: final uv-run -> #f
top: teardown -> ok
top: done
exit=0
```

**Observed (runs differ only in the 0-2 ms / 131-138 ms benchmark timings):**

- The handler received "hello" and "world" through three nested Scheme frames and echoed each, awaiting write completion in between; the ticker's four 8 ms sleeps interleaved with the handler's waits; both coroutines finished; the scheduler went idle after 11 steps and 18 `uv-run 'once` calls; teardown `ok`.
- **Cost, 10,000 suspend/resume cycles:** pure (wake immediately, no `uv-run`): 0-2 ms wall (below the 1 ms clock resolution; see E3b for a per-cycle figure). With a 0 ms one-shot timer re-armed per cycle and one `(uv-run loop 'once)` per cycle: **131-138 ms wall, 17-20 ms CPU** for 10,000 cycles, i.e. about 13 us per full suspend -> `uv-run 'once` -> timer callback -> enqueue -> resume round trip, dominated by the kernel poll (wall >> CPU). Full `call/cc` in place of `call/1cc`: also 0 ms for 10,000.
- No continuation error of any kind: every continuation captured by `await!` was captured with only Scheme frames beneath it and was invoked from a scheduler step that is itself pure Scheme, so no stale foreign context is ever returned to. One-shot continuations were sufficient because each step's return continuation and each await continuation is used exactly once.

### E3b: per-cycle cost, 1,000,000 suspend/resume cycles, call/1cc vs call/cc

Same scheduler as E3, no libuv inside the timed region, 1e6 cycles, each variant run twice within the process.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e3b-suspend-resume-1e6.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 120 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e3b-suspend-resume-1e6.sps
```

Source (verbatim):

```scheme
;; E3b: per-cycle cost of the E3 scheduler's suspend/resume, 1,000,000 cycles,
;; call/1cc vs full call/cc. No libuv involvement inside the timed region.
(import (rnrs) (only (chezscheme) call/1cc cpu-time collections) (libuv) (spike common))
(define ready '())
(define (push-ready! t) (set! ready (append ready (list t))))
(define current-return #f)
(define (suspend! v) (let ((r current-return)) (set! current-return #f) (r v)))
(define (await! register)
  (call/1cc (lambda (k) (register (lambda (v) (push-ready! (lambda () (k v))))) (suspend! 'suspended))))
(define (await/cc! register)
  (call/cc (lambda (k) (register (lambda (v) (push-ready! (lambda () (k v))))) (suspend! 'suspended))))
(define (spawn! thunk) (push-ready! (lambda () (thunk) (suspend! 'finished))))
(define (step! t) (call/1cc (lambda (ret) (set! current-return ret) (t))))
(define (drain!) (let lp () (when (pair? ready) (let ((t (car ready))) (set! ready (cdr ready)) (step! t) (lp)))))
(define (bench name await)
  (spawn! (lambda ()
    (let ((t0 (now-ms)) (c0 (cpu-time)) (g0 (collections)))
      (let lp ((i 0)) (when (< i 1000000) (await (lambda (wake) (wake 'now))) (lp (+ i 1))))
      (say name ": 1000000 cycles in " (- (now-ms) t0) " ms wall, " (- (cpu-time) c0) " ms cpu, collections=" (- (collections) g0)
           " => " (/ (* 1000.0 (- (now-ms) t0)) 1000000) " us/cycle"))))
  (drain!))
(bench "call/1cc" await!)
(bench "call/cc " await/cc!)
(bench "call/1cc again" await!)
(bench "call/cc  again" await/cc!)
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e3b-suspend-resume-1e6.run1.txt`; the last line is gtimeout's exit status):

```text
call/1cc: 1000000 cycles in 34 ms wall, 34 ms cpu, collections=32 => 0.034 us/cycle
call/cc : 1000000 cycles in 32 ms wall, 33 ms cpu, collections=34 => 0.032 us/cycle
call/1cc again: 1000000 cycles in 32 ms wall, 32 ms cpu, collections=33 => 0.032 us/cycle
call/cc  again: 1000000 cycles in 30 ms wall, 30 ms cpu, collections=34 => 0.03 us/cycle
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e3b-suspend-resume-1e6.run2.txt`; the last line is gtimeout's exit status):

```text
call/1cc: 1000000 cycles in 36 ms wall, 35 ms cpu, collections=32 => 0.036 us/cycle
call/cc : 1000000 cycles in 33 ms wall, 32 ms cpu, collections=34 => 0.033 us/cycle
call/1cc again: 1000000 cycles in 34 ms wall, 34 ms cpu, collections=33 => 0.034 us/cycle
call/cc  again: 1000000 cycles in 31 ms wall, 31 ms cpu, collections=34 => 0.031 us/cycle
done
exit=0
```

**Observed:** 30-36 ms per 1,000,000 cycles for both `call/1cc` and full `call/cc`, i.e. **about 0.03 us (30-36 ns) per suspend/resume** on this machine, 32-34 minor collections per million cycles (each cycle allocates a `wake` closure, a resumption thunk and a one-element queue). No measurable advantage for `call/1cc` over `call/cc` at this shape (the captured stack is a few frames deep).

### E4a: a handler as a Chez engine, slices interleaved with uv-run from the top-level scheduler

The engine does 30 x `busy 100000`. The expire handler calls `(uv-run loop 'once)` for the first three expiries (guaranteeing a 1 ms repeating timer's callback ran in between) and `'nowait` afterwards, then resumes the returned engine.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4a-engine-scheduler.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4a-engine-scheduler.sps
```

Source (verbatim):

```scheme
;; E4a: a handler as a Chez engine; the top-level scheduler interleaves engine
;; slices with uv-run, and the engine is resumed after uv-run ran callbacks.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define fired 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm) (set! fired (+ fired 1))) 1 1)   ; 1 ms repeating
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define handler
  (make-engine (lambda ()
    (let lp ((i 0) (acc 0)) (if (= i 30) (list 'handler-done i acc) (lp (+ i 1) (+ acc (busy 100000))))))))
(define slices 0)
(define result
  (let run ((eng handler))
    (eng 5000
      (lambda (ticks-left . vals) (say "engine complete; ticks-left=" ticks-left " values=" vals) vals)
      (lambda (new-eng)
        (set! slices (+ slices 1))
        (let ((before fired))
          (if (<= slices 3) (uv-run loop 'once) (uv-run loop 'nowait))
          (when (or (<= slices 3) (= 0 (mod slices 100)))
            (say "slice " slices " expired; uv-run ran " (- fired before) " timer callback(s); resuming engine")))
        (run new-eng)))))
(say "result=" result " slices=" slices " timer callbacks total=" fired)
(uv-close! t)
(say "final uv-run -> " (uv-run loop 'default))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4a-engine-scheduler.run1.txt`; the last line is gtimeout's exit status):

```text
slice 1 expired; uv-run ran 1 timer callback(s); resuming engine
slice 2 expired; uv-run ran 1 timer callback(s); resuming engine
slice 3 expired; uv-run ran 1 timer callback(s); resuming engine
slice 100 expired; uv-run ran 0 timer callback(s); resuming engine
slice 200 expired; uv-run ran 0 timer callback(s); resuming engine
slice 300 expired; uv-run ran 0 timer callback(s); resuming engine
slice 400 expired; uv-run ran 0 timer callback(s); resuming engine
slice 500 expired; uv-run ran 0 timer callback(s); resuming engine
slice 600 expired; uv-run ran 0 timer callback(s); resuming engine
engine complete; ticks-left=4970 values=((handler-done 30 149998500000))
result=((handler-done 30 149998500000)) slices=600 timer callbacks total=15
final uv-run -> #f
teardown -> ok
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4a-engine-scheduler.run2.txt`; the last line is gtimeout's exit status):

```text
slice 1 expired; uv-run ran 1 timer callback(s); resuming engine
slice 2 expired; uv-run ran 1 timer callback(s); resuming engine
slice 3 expired; uv-run ran 1 timer callback(s); resuming engine
slice 100 expired; uv-run ran 0 timer callback(s); resuming engine
slice 200 expired; uv-run ran 0 timer callback(s); resuming engine
slice 300 expired; uv-run ran 0 timer callback(s); resuming engine
slice 400 expired; uv-run ran 0 timer callback(s); resuming engine
slice 500 expired; uv-run ran 0 timer callback(s); resuming engine
slice 600 expired; uv-run ran 0 timer callback(s); resuming engine
engine complete; ticks-left=4970 values=((handler-done 30 149998500000))
result=((handler-done 30 149998500000)) slices=600 timer callbacks total=21
final uv-run -> #f
teardown -> ok
done
exit=0
```

**Observed (runs differ only in the total timer-callback count, 15 vs 21, a timing artefact):** 600 slices; after each of the first three expiries `uv-run 'once` ran exactly one timer callback and the engine resumed and completed with the correct sum `149998500000`. An engine that expired can be resumed after a later `uv-run`. Teardown `ok`.

### E4b: (uv-run loop 'nowait) called from INSIDE an engine slice, trivial callback

The engine body itself calls `(uv-run loop 'nowait)` 300 times; a 1 ms repeating timer's callback only increments a counter. The binding's re-entry guard does not apply (the engine is not a callback).

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4b-uvrun-inside-engine.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4b-uvrun-inside-engine.sps
```

Source (verbatim):

```scheme
;; E4b: (uv-run loop 'nowait) called from INSIDE an engine slice, with a
;; trivial timer callback (expiry is overwhelmingly likely outside the callback).
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define fired 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm) (set! fired (+ fired 1))) 0 1)
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define runs-inside 0)
(define handler
  (make-engine (lambda ()
    (let lp ((i 0))
      (if (= i 300) (list 'done i 'fired fired 'runs-inside runs-inside)
          (begin (set! runs-inside (+ runs-inside 1)) (uv-run loop 'nowait) (busy 3000) (lp (+ i 1))))))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 2000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng) (set! slices (+ slices 1)) (run new-eng)))))))
(say "result=" result " slices=" slices " fired=" fired " loop-alive?=" (uv-loop-alive? loop))
(uv-close! t)
(say "final uv-run -> " (guarded "final" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4b-uvrun-inside-engine.run1.txt`; the last line is gtimeout's exit status):

```text
result=((done 300 fired 5 runs-inside 300)) slices=451 fired=5 loop-alive?=#t
final uv-run -> #f
teardown -> ok
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4b-uvrun-inside-engine.run2.txt`; the last line is gtimeout's exit status):

```text
result=((done 300 fired 6 runs-inside 300)) slices=451 fired=6 loop-alive?=#t
final uv-run -> #f
teardown -> ok
done
exit=0
```

**Observed (runs differ only in `fired` 5 vs 6):** 451 slices, 300 `uv-run` calls from inside the engine, completed normally, teardown `ok`. Calling `uv-run` from an engine slice is not itself a problem.

### E4c: engine ticks expire INSIDE a libuv callback (inside a foreign frame); engine resumed

The engine calls `(uv-run loop 'once)`; the 0 ms timer's callback does `busy 200000`, far more than the 1000-tick slice, so expiry happens inside the callback's foreign frame. The expire handler just resumes.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4c-engine-expires-inside-callback.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4c-engine-expires-inside-callback.sps
```

Source (verbatim):

```scheme
;; E4c: (uv-run loop 'once) from INSIDE an engine slice where the timer
;; callback does enough work that the engine's ticks expire INSIDE the callback
;; (inside a foreign frame). Then the expired engine is resumed.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define cb-entered 0) (define cb-finished 0)
(define t (make-uv-timer loop))
(uv-timer-start! t (lambda (tm)
                     (set! cb-entered (+ cb-entered 1))
                     (busy 200000)               ; far more than the slice's ticks
                     (set! cb-finished (+ cb-finished 1))
                     (say "callback: finished normally (entered=" cb-entered " finished=" cb-finished ")"))
                 0 0)
(define handler
  (make-engine (lambda ()
    (say "engine: calling (uv-run loop 'once) from inside the slice")
    (let ((r (uv-run loop 'once)))
      (say "engine: uv-run returned " r " (this means the callback's foreign frame returned)")
      (list 'engine-done r)))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 1000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng)
          (set! slices (+ slices 1))
          (say "expire #" slices ": cb-entered=" cb-entered " cb-finished=" cb-finished "; resuming the engine")
          (run new-eng)))))))
(say "result=" result " slices=" slices " cb-entered=" cb-entered " cb-finished=" cb-finished)
(say "loop-alive? " (guarded "alive" (lambda () (uv-loop-alive? loop))))
(say "uv-run after -> " (guarded "uv-run-after" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4c-engine-expires-inside-callback.run1.txt`; the last line is gtimeout's exit status):

```text
engine: calling (uv-run loop 'once) from inside the slice
expire #1: cb-entered=1 cb-finished=0; resuming the engine
expire #2: cb-entered=1 cb-finished=0; resuming the engine
expire #3: cb-entered=1 cb-finished=0; resuming the engine
expire #4: cb-entered=1 cb-finished=0; resuming the engine
expire #5: cb-entered=1 cb-finished=0; resuming the engine
expire #6: cb-entered=1 cb-finished=0; resuming the engine
expire #7: cb-entered=1 cb-finished=0; resuming the engine
expire #8: cb-entered=1 cb-finished=0; resuming the engine
expire #9: cb-entered=1 cb-finished=0; resuming the engine
expire #10: cb-entered=1 cb-finished=0; resuming the engine
expire #11: cb-entered=1 cb-finished=0; resuming the engine
expire #12: cb-entered=1 cb-finished=0; resuming the engine
expire #13: cb-entered=1 cb-finished=0; resuming the engine
expire #14: cb-entered=1 cb-finished=0; resuming the engine
expire #15: cb-entered=1 cb-finished=0; resuming the engine
expire #16: cb-entered=1 cb-finished=0; resuming the engine
expire #17: cb-entered=1 cb-finished=0; resuming the engine
expire #18: cb-entered=1 cb-finished=0; resuming the engine
expire #19: cb-entered=1 cb-finished=0; resuming the engine
expire #20: cb-entered=1 cb-finished=0; resuming the engine
expire #21: cb-entered=1 cb-finished=0; resuming the engine
expire #22: cb-entered=1 cb-finished=0; resuming the engine
expire #23: cb-entered=1 cb-finished=0; resuming the engine
expire #24: cb-entered=1 cb-finished=0; resuming the engine
expire #25: cb-entered=1 cb-finished=0; resuming the engine
expire #26: cb-entered=1 cb-finished=0; resuming the engine
expire #27: cb-entered=1 cb-finished=0; resuming the engine
expire #28: cb-entered=1 cb-finished=0; resuming the engine
expire #29: cb-entered=1 cb-finished=0; resuming the engine
expire #30: cb-entered=1 cb-finished=0; resuming the engine
expire #31: cb-entered=1 cb-finished=0; resuming the engine
expire #32: cb-entered=1 cb-finished=0; resuming the engine
expire #33: cb-entered=1 cb-finished=0; resuming the engine
expire #34: cb-entered=1 cb-finished=0; resuming the engine
expire #35: cb-entered=1 cb-finished=0; resuming the engine
expire #36: cb-entered=1 cb-finished=0; resuming the engine
expire #37: cb-entered=1 cb-finished=0; resuming the engine
expire #38: cb-entered=1 cb-finished=0; resuming the engine
expire #39: cb-entered=1 cb-finished=0; resuming the engine
expire #40: cb-entered=1 cb-finished=0; resuming the engine
expire #41: cb-entered=1 cb-finished=0; resuming the engine
expire #42: cb-entered=1 cb-finished=0; resuming the engine
expire #43: cb-entered=1 cb-finished=0; resuming the engine
expire #44: cb-entered=1 cb-finished=0; resuming the engine
expire #45: cb-entered=1 cb-finished=0; resuming the engine
expire #46: cb-entered=1 cb-finished=0; resuming the engine
expire #47: cb-entered=1 cb-finished=0; resuming the engine
expire #48: cb-entered=1 cb-finished=0; resuming the engine
expire #49: cb-entered=1 cb-finished=0; resuming the engine
expire #50: cb-entered=1 cb-finished=0; resuming the engine
expire #51: cb-entered=1 cb-finished=0; resuming the engine
expire #52: cb-entered=1 cb-finished=0; resuming the engine
expire #53: cb-entered=1 cb-finished=0; resuming the engine
expire #54: cb-entered=1 cb-finished=0; resuming the engine
expire #55: cb-entered=1 cb-finished=0; resuming the engine
expire #56: cb-entered=1 cb-finished=0; resuming the engine
expire #57: cb-entered=1 cb-finished=0; resuming the engine
expire #58: cb-entered=1 cb-finished=0; resuming the engine
expire #59: cb-entered=1 cb-finished=0; resuming the engine
expire #60: cb-entered=1 cb-finished=0; resuming the engine
expire #61: cb-entered=1 cb-finished=0; resuming the engine
expire #62: cb-entered=1 cb-finished=0; resuming the engine
expire #63: cb-entered=1 cb-finished=0; resuming the engine
expire #64: cb-entered=1 cb-finished=0; resuming the engine
expire #65: cb-entered=1 cb-finished=0; resuming the engine
expire #66: cb-entered=1 cb-finished=0; resuming the engine
expire #67: cb-entered=1 cb-finished=0; resuming the engine
expire #68: cb-entered=1 cb-finished=0; resuming the engine
expire #69: cb-entered=1 cb-finished=0; resuming the engine
expire #70: cb-entered=1 cb-finished=0; resuming the engine
expire #71: cb-entered=1 cb-finished=0; resuming the engine
expire #72: cb-entered=1 cb-finished=0; resuming the engine
expire #73: cb-entered=1 cb-finished=0; resuming the engine
expire #74: cb-entered=1 cb-finished=0; resuming the engine
expire #75: cb-entered=1 cb-finished=0; resuming the engine
expire #76: cb-entered=1 cb-finished=0; resuming the engine
expire #77: cb-entered=1 cb-finished=0; resuming the engine
expire #78: cb-entered=1 cb-finished=0; resuming the engine
expire #79: cb-entered=1 cb-finished=0; resuming the engine
expire #80: cb-entered=1 cb-finished=0; resuming the engine
expire #81: cb-entered=1 cb-finished=0; resuming the engine
expire #82: cb-entered=1 cb-finished=0; resuming the engine
expire #83: cb-entered=1 cb-finished=0; resuming the engine
expire #84: cb-entered=1 cb-finished=0; resuming the engine
expire #85: cb-entered=1 cb-finished=0; resuming the engine
expire #86: cb-entered=1 cb-finished=0; resuming the engine
expire #87: cb-entered=1 cb-finished=0; resuming the engine
expire #88: cb-entered=1 cb-finished=0; resuming the engine
expire #89: cb-entered=1 cb-finished=0; resuming the engine
expire #90: cb-entered=1 cb-finished=0; resuming the engine
expire #91: cb-entered=1 cb-finished=0; resuming the engine
expire #92: cb-entered=1 cb-finished=0; resuming the engine
expire #93: cb-entered=1 cb-finished=0; resuming the engine
expire #94: cb-entered=1 cb-finished=0; resuming the engine
expire #95: cb-entered=1 cb-finished=0; resuming the engine
expire #96: cb-entered=1 cb-finished=0; resuming the engine
expire #97: cb-entered=1 cb-finished=0; resuming the engine
expire #98: cb-entered=1 cb-finished=0; resuming the engine
expire #99: cb-entered=1 cb-finished=0; resuming the engine
expire #100: cb-entered=1 cb-finished=0; resuming the engine
expire #101: cb-entered=1 cb-finished=0; resuming the engine
expire #102: cb-entered=1 cb-finished=0; resuming the engine
expire #103: cb-entered=1 cb-finished=0; resuming the engine
expire #104: cb-entered=1 cb-finished=0; resuming the engine
expire #105: cb-entered=1 cb-finished=0; resuming the engine
expire #106: cb-entered=1 cb-finished=0; resuming the engine
expire #107: cb-entered=1 cb-finished=0; resuming the engine
expire #108: cb-entered=1 cb-finished=0; resuming the engine
expire #109: cb-entered=1 cb-finished=0; resuming the engine
expire #110: cb-entered=1 cb-finished=0; resuming the engine
expire #111: cb-entered=1 cb-finished=0; resuming the engine
expire #112: cb-entered=1 cb-finished=0; resuming the engine
expire #113: cb-entered=1 cb-finished=0; resuming the engine
expire #114: cb-entered=1 cb-finished=0; resuming the engine
expire #115: cb-entered=1 cb-finished=0; resuming the engine
expire #116: cb-entered=1 cb-finished=0; resuming the engine
expire #117: cb-entered=1 cb-finished=0; resuming the engine
expire #118: cb-entered=1 cb-finished=0; resuming the engine
expire #119: cb-entered=1 cb-finished=0; resuming the engine
expire #120: cb-entered=1 cb-finished=0; resuming the engine
expire #121: cb-entered=1 cb-finished=0; resuming the engine
expire #122: cb-entered=1 cb-finished=0; resuming the engine
expire #123: cb-entered=1 cb-finished=0; resuming the engine
expire #124: cb-entered=1 cb-finished=0; resuming the engine
expire #125: cb-entered=1 cb-finished=0; resuming the engine
expire #126: cb-entered=1 cb-finished=0; resuming the engine
expire #127: cb-entered=1 cb-finished=0; resuming the engine
expire #128: cb-entered=1 cb-finished=0; resuming the engine
expire #129: cb-entered=1 cb-finished=0; resuming the engine
expire #130: cb-entered=1 cb-finished=0; resuming the engine
expire #131: cb-entered=1 cb-finished=0; resuming the engine
expire #132: cb-entered=1 cb-finished=0; resuming the engine
expire #133: cb-entered=1 cb-finished=0; resuming the engine
expire #134: cb-entered=1 cb-finished=0; resuming the engine
expire #135: cb-entered=1 cb-finished=0; resuming the engine
expire #136: cb-entered=1 cb-finished=0; resuming the engine
expire #137: cb-entered=1 cb-finished=0; resuming the engine
expire #138: cb-entered=1 cb-finished=0; resuming the engine
expire #139: cb-entered=1 cb-finished=0; resuming the engine
expire #140: cb-entered=1 cb-finished=0; resuming the engine
expire #141: cb-entered=1 cb-finished=0; resuming the engine
expire #142: cb-entered=1 cb-finished=0; resuming the engine
expire #143: cb-entered=1 cb-finished=0; resuming the engine
expire #144: cb-entered=1 cb-finished=0; resuming the engine
expire #145: cb-entered=1 cb-finished=0; resuming the engine
expire #146: cb-entered=1 cb-finished=0; resuming the engine
expire #147: cb-entered=1 cb-finished=0; resuming the engine
expire #148: cb-entered=1 cb-finished=0; resuming the engine
expire #149: cb-entered=1 cb-finished=0; resuming the engine
expire #150: cb-entered=1 cb-finished=0; resuming the engine
expire #151: cb-entered=1 cb-finished=0; resuming the engine
expire #152: cb-entered=1 cb-finished=0; resuming the engine
expire #153: cb-entered=1 cb-finished=0; resuming the engine
expire #154: cb-entered=1 cb-finished=0; resuming the engine
expire #155: cb-entered=1 cb-finished=0; resuming the engine
expire #156: cb-entered=1 cb-finished=0; resuming the engine
expire #157: cb-entered=1 cb-finished=0; resuming the engine
expire #158: cb-entered=1 cb-finished=0; resuming the engine
expire #159: cb-entered=1 cb-finished=0; resuming the engine
expire #160: cb-entered=1 cb-finished=0; resuming the engine
expire #161: cb-entered=1 cb-finished=0; resuming the engine
expire #162: cb-entered=1 cb-finished=0; resuming the engine
expire #163: cb-entered=1 cb-finished=0; resuming the engine
expire #164: cb-entered=1 cb-finished=0; resuming the engine
expire #165: cb-entered=1 cb-finished=0; resuming the engine
expire #166: cb-entered=1 cb-finished=0; resuming the engine
expire #167: cb-entered=1 cb-finished=0; resuming the engine
expire #168: cb-entered=1 cb-finished=0; resuming the engine
expire #169: cb-entered=1 cb-finished=0; resuming the engine
expire #170: cb-entered=1 cb-finished=0; resuming the engine
expire #171: cb-entered=1 cb-finished=0; resuming the engine
expire #172: cb-entered=1 cb-finished=0; resuming the engine
expire #173: cb-entered=1 cb-finished=0; resuming the engine
expire #174: cb-entered=1 cb-finished=0; resuming the engine
expire #175: cb-entered=1 cb-finished=0; resuming the engine
expire #176: cb-entered=1 cb-finished=0; resuming the engine
expire #177: cb-entered=1 cb-finished=0; resuming the engine
expire #178: cb-entered=1 cb-finished=0; resuming the engine
expire #179: cb-entered=1 cb-finished=0; resuming the engine
expire #180: cb-entered=1 cb-finished=0; resuming the engine
expire #181: cb-entered=1 cb-finished=0; resuming the engine
expire #182: cb-entered=1 cb-finished=0; resuming the engine
expire #183: cb-entered=1 cb-finished=0; resuming the engine
expire #184: cb-entered=1 cb-finished=0; resuming the engine
expire #185: cb-entered=1 cb-finished=0; resuming the engine
expire #186: cb-entered=1 cb-finished=0; resuming the engine
expire #187: cb-entered=1 cb-finished=0; resuming the engine
expire #188: cb-entered=1 cb-finished=0; resuming the engine
expire #189: cb-entered=1 cb-finished=0; resuming the engine
expire #190: cb-entered=1 cb-finished=0; resuming the engine
expire #191: cb-entered=1 cb-finished=0; resuming the engine
expire #192: cb-entered=1 cb-finished=0; resuming the engine
expire #193: cb-entered=1 cb-finished=0; resuming the engine
expire #194: cb-entered=1 cb-finished=0; resuming the engine
expire #195: cb-entered=1 cb-finished=0; resuming the engine
expire #196: cb-entered=1 cb-finished=0; resuming the engine
expire #197: cb-entered=1 cb-finished=0; resuming the engine
expire #198: cb-entered=1 cb-finished=0; resuming the engine
expire #199: cb-entered=1 cb-finished=0; resuming the engine
expire #200: cb-entered=1 cb-finished=0; resuming the engine
callback: finished normally (entered=1 finished=1)
engine: uv-run returned #f (this means the callback's foreign frame returned)
result=((engine-done #f)) slices=200 cb-entered=1 cb-finished=1
loop-alive? #f
uv-run after -> #f
teardown -> ok
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4c-engine-expires-inside-callback.run2.txt`; the last line is gtimeout's exit status):

```text
engine: calling (uv-run loop 'once) from inside the slice
expire #1: cb-entered=1 cb-finished=0; resuming the engine
expire #2: cb-entered=1 cb-finished=0; resuming the engine
expire #3: cb-entered=1 cb-finished=0; resuming the engine
expire #4: cb-entered=1 cb-finished=0; resuming the engine
expire #5: cb-entered=1 cb-finished=0; resuming the engine
expire #6: cb-entered=1 cb-finished=0; resuming the engine
expire #7: cb-entered=1 cb-finished=0; resuming the engine
expire #8: cb-entered=1 cb-finished=0; resuming the engine
expire #9: cb-entered=1 cb-finished=0; resuming the engine
expire #10: cb-entered=1 cb-finished=0; resuming the engine
expire #11: cb-entered=1 cb-finished=0; resuming the engine
expire #12: cb-entered=1 cb-finished=0; resuming the engine
expire #13: cb-entered=1 cb-finished=0; resuming the engine
expire #14: cb-entered=1 cb-finished=0; resuming the engine
expire #15: cb-entered=1 cb-finished=0; resuming the engine
expire #16: cb-entered=1 cb-finished=0; resuming the engine
expire #17: cb-entered=1 cb-finished=0; resuming the engine
expire #18: cb-entered=1 cb-finished=0; resuming the engine
expire #19: cb-entered=1 cb-finished=0; resuming the engine
expire #20: cb-entered=1 cb-finished=0; resuming the engine
expire #21: cb-entered=1 cb-finished=0; resuming the engine
expire #22: cb-entered=1 cb-finished=0; resuming the engine
expire #23: cb-entered=1 cb-finished=0; resuming the engine
expire #24: cb-entered=1 cb-finished=0; resuming the engine
expire #25: cb-entered=1 cb-finished=0; resuming the engine
expire #26: cb-entered=1 cb-finished=0; resuming the engine
expire #27: cb-entered=1 cb-finished=0; resuming the engine
expire #28: cb-entered=1 cb-finished=0; resuming the engine
expire #29: cb-entered=1 cb-finished=0; resuming the engine
expire #30: cb-entered=1 cb-finished=0; resuming the engine
expire #31: cb-entered=1 cb-finished=0; resuming the engine
expire #32: cb-entered=1 cb-finished=0; resuming the engine
expire #33: cb-entered=1 cb-finished=0; resuming the engine
expire #34: cb-entered=1 cb-finished=0; resuming the engine
expire #35: cb-entered=1 cb-finished=0; resuming the engine
expire #36: cb-entered=1 cb-finished=0; resuming the engine
expire #37: cb-entered=1 cb-finished=0; resuming the engine
expire #38: cb-entered=1 cb-finished=0; resuming the engine
expire #39: cb-entered=1 cb-finished=0; resuming the engine
expire #40: cb-entered=1 cb-finished=0; resuming the engine
expire #41: cb-entered=1 cb-finished=0; resuming the engine
expire #42: cb-entered=1 cb-finished=0; resuming the engine
expire #43: cb-entered=1 cb-finished=0; resuming the engine
expire #44: cb-entered=1 cb-finished=0; resuming the engine
expire #45: cb-entered=1 cb-finished=0; resuming the engine
expire #46: cb-entered=1 cb-finished=0; resuming the engine
expire #47: cb-entered=1 cb-finished=0; resuming the engine
expire #48: cb-entered=1 cb-finished=0; resuming the engine
expire #49: cb-entered=1 cb-finished=0; resuming the engine
expire #50: cb-entered=1 cb-finished=0; resuming the engine
expire #51: cb-entered=1 cb-finished=0; resuming the engine
expire #52: cb-entered=1 cb-finished=0; resuming the engine
expire #53: cb-entered=1 cb-finished=0; resuming the engine
expire #54: cb-entered=1 cb-finished=0; resuming the engine
expire #55: cb-entered=1 cb-finished=0; resuming the engine
expire #56: cb-entered=1 cb-finished=0; resuming the engine
expire #57: cb-entered=1 cb-finished=0; resuming the engine
expire #58: cb-entered=1 cb-finished=0; resuming the engine
expire #59: cb-entered=1 cb-finished=0; resuming the engine
expire #60: cb-entered=1 cb-finished=0; resuming the engine
expire #61: cb-entered=1 cb-finished=0; resuming the engine
expire #62: cb-entered=1 cb-finished=0; resuming the engine
expire #63: cb-entered=1 cb-finished=0; resuming the engine
expire #64: cb-entered=1 cb-finished=0; resuming the engine
expire #65: cb-entered=1 cb-finished=0; resuming the engine
expire #66: cb-entered=1 cb-finished=0; resuming the engine
expire #67: cb-entered=1 cb-finished=0; resuming the engine
expire #68: cb-entered=1 cb-finished=0; resuming the engine
expire #69: cb-entered=1 cb-finished=0; resuming the engine
expire #70: cb-entered=1 cb-finished=0; resuming the engine
expire #71: cb-entered=1 cb-finished=0; resuming the engine
expire #72: cb-entered=1 cb-finished=0; resuming the engine
expire #73: cb-entered=1 cb-finished=0; resuming the engine
expire #74: cb-entered=1 cb-finished=0; resuming the engine
expire #75: cb-entered=1 cb-finished=0; resuming the engine
expire #76: cb-entered=1 cb-finished=0; resuming the engine
expire #77: cb-entered=1 cb-finished=0; resuming the engine
expire #78: cb-entered=1 cb-finished=0; resuming the engine
expire #79: cb-entered=1 cb-finished=0; resuming the engine
expire #80: cb-entered=1 cb-finished=0; resuming the engine
expire #81: cb-entered=1 cb-finished=0; resuming the engine
expire #82: cb-entered=1 cb-finished=0; resuming the engine
expire #83: cb-entered=1 cb-finished=0; resuming the engine
expire #84: cb-entered=1 cb-finished=0; resuming the engine
expire #85: cb-entered=1 cb-finished=0; resuming the engine
expire #86: cb-entered=1 cb-finished=0; resuming the engine
expire #87: cb-entered=1 cb-finished=0; resuming the engine
expire #88: cb-entered=1 cb-finished=0; resuming the engine
expire #89: cb-entered=1 cb-finished=0; resuming the engine
expire #90: cb-entered=1 cb-finished=0; resuming the engine
expire #91: cb-entered=1 cb-finished=0; resuming the engine
expire #92: cb-entered=1 cb-finished=0; resuming the engine
expire #93: cb-entered=1 cb-finished=0; resuming the engine
expire #94: cb-entered=1 cb-finished=0; resuming the engine
expire #95: cb-entered=1 cb-finished=0; resuming the engine
expire #96: cb-entered=1 cb-finished=0; resuming the engine
expire #97: cb-entered=1 cb-finished=0; resuming the engine
expire #98: cb-entered=1 cb-finished=0; resuming the engine
expire #99: cb-entered=1 cb-finished=0; resuming the engine
expire #100: cb-entered=1 cb-finished=0; resuming the engine
expire #101: cb-entered=1 cb-finished=0; resuming the engine
expire #102: cb-entered=1 cb-finished=0; resuming the engine
expire #103: cb-entered=1 cb-finished=0; resuming the engine
expire #104: cb-entered=1 cb-finished=0; resuming the engine
expire #105: cb-entered=1 cb-finished=0; resuming the engine
expire #106: cb-entered=1 cb-finished=0; resuming the engine
expire #107: cb-entered=1 cb-finished=0; resuming the engine
expire #108: cb-entered=1 cb-finished=0; resuming the engine
expire #109: cb-entered=1 cb-finished=0; resuming the engine
expire #110: cb-entered=1 cb-finished=0; resuming the engine
expire #111: cb-entered=1 cb-finished=0; resuming the engine
expire #112: cb-entered=1 cb-finished=0; resuming the engine
expire #113: cb-entered=1 cb-finished=0; resuming the engine
expire #114: cb-entered=1 cb-finished=0; resuming the engine
expire #115: cb-entered=1 cb-finished=0; resuming the engine
expire #116: cb-entered=1 cb-finished=0; resuming the engine
expire #117: cb-entered=1 cb-finished=0; resuming the engine
expire #118: cb-entered=1 cb-finished=0; resuming the engine
expire #119: cb-entered=1 cb-finished=0; resuming the engine
expire #120: cb-entered=1 cb-finished=0; resuming the engine
expire #121: cb-entered=1 cb-finished=0; resuming the engine
expire #122: cb-entered=1 cb-finished=0; resuming the engine
expire #123: cb-entered=1 cb-finished=0; resuming the engine
expire #124: cb-entered=1 cb-finished=0; resuming the engine
expire #125: cb-entered=1 cb-finished=0; resuming the engine
expire #126: cb-entered=1 cb-finished=0; resuming the engine
expire #127: cb-entered=1 cb-finished=0; resuming the engine
expire #128: cb-entered=1 cb-finished=0; resuming the engine
expire #129: cb-entered=1 cb-finished=0; resuming the engine
expire #130: cb-entered=1 cb-finished=0; resuming the engine
expire #131: cb-entered=1 cb-finished=0; resuming the engine
expire #132: cb-entered=1 cb-finished=0; resuming the engine
expire #133: cb-entered=1 cb-finished=0; resuming the engine
expire #134: cb-entered=1 cb-finished=0; resuming the engine
expire #135: cb-entered=1 cb-finished=0; resuming the engine
expire #136: cb-entered=1 cb-finished=0; resuming the engine
expire #137: cb-entered=1 cb-finished=0; resuming the engine
expire #138: cb-entered=1 cb-finished=0; resuming the engine
expire #139: cb-entered=1 cb-finished=0; resuming the engine
expire #140: cb-entered=1 cb-finished=0; resuming the engine
expire #141: cb-entered=1 cb-finished=0; resuming the engine
expire #142: cb-entered=1 cb-finished=0; resuming the engine
expire #143: cb-entered=1 cb-finished=0; resuming the engine
expire #144: cb-entered=1 cb-finished=0; resuming the engine
expire #145: cb-entered=1 cb-finished=0; resuming the engine
expire #146: cb-entered=1 cb-finished=0; resuming the engine
expire #147: cb-entered=1 cb-finished=0; resuming the engine
expire #148: cb-entered=1 cb-finished=0; resuming the engine
expire #149: cb-entered=1 cb-finished=0; resuming the engine
expire #150: cb-entered=1 cb-finished=0; resuming the engine
expire #151: cb-entered=1 cb-finished=0; resuming the engine
expire #152: cb-entered=1 cb-finished=0; resuming the engine
expire #153: cb-entered=1 cb-finished=0; resuming the engine
expire #154: cb-entered=1 cb-finished=0; resuming the engine
expire #155: cb-entered=1 cb-finished=0; resuming the engine
expire #156: cb-entered=1 cb-finished=0; resuming the engine
expire #157: cb-entered=1 cb-finished=0; resuming the engine
expire #158: cb-entered=1 cb-finished=0; resuming the engine
expire #159: cb-entered=1 cb-finished=0; resuming the engine
expire #160: cb-entered=1 cb-finished=0; resuming the engine
expire #161: cb-entered=1 cb-finished=0; resuming the engine
expire #162: cb-entered=1 cb-finished=0; resuming the engine
expire #163: cb-entered=1 cb-finished=0; resuming the engine
expire #164: cb-entered=1 cb-finished=0; resuming the engine
expire #165: cb-entered=1 cb-finished=0; resuming the engine
expire #166: cb-entered=1 cb-finished=0; resuming the engine
expire #167: cb-entered=1 cb-finished=0; resuming the engine
expire #168: cb-entered=1 cb-finished=0; resuming the engine
expire #169: cb-entered=1 cb-finished=0; resuming the engine
expire #170: cb-entered=1 cb-finished=0; resuming the engine
expire #171: cb-entered=1 cb-finished=0; resuming the engine
expire #172: cb-entered=1 cb-finished=0; resuming the engine
expire #173: cb-entered=1 cb-finished=0; resuming the engine
expire #174: cb-entered=1 cb-finished=0; resuming the engine
expire #175: cb-entered=1 cb-finished=0; resuming the engine
expire #176: cb-entered=1 cb-finished=0; resuming the engine
expire #177: cb-entered=1 cb-finished=0; resuming the engine
expire #178: cb-entered=1 cb-finished=0; resuming the engine
expire #179: cb-entered=1 cb-finished=0; resuming the engine
expire #180: cb-entered=1 cb-finished=0; resuming the engine
expire #181: cb-entered=1 cb-finished=0; resuming the engine
expire #182: cb-entered=1 cb-finished=0; resuming the engine
expire #183: cb-entered=1 cb-finished=0; resuming the engine
expire #184: cb-entered=1 cb-finished=0; resuming the engine
expire #185: cb-entered=1 cb-finished=0; resuming the engine
expire #186: cb-entered=1 cb-finished=0; resuming the engine
expire #187: cb-entered=1 cb-finished=0; resuming the engine
expire #188: cb-entered=1 cb-finished=0; resuming the engine
expire #189: cb-entered=1 cb-finished=0; resuming the engine
expire #190: cb-entered=1 cb-finished=0; resuming the engine
expire #191: cb-entered=1 cb-finished=0; resuming the engine
expire #192: cb-entered=1 cb-finished=0; resuming the engine
expire #193: cb-entered=1 cb-finished=0; resuming the engine
expire #194: cb-entered=1 cb-finished=0; resuming the engine
expire #195: cb-entered=1 cb-finished=0; resuming the engine
expire #196: cb-entered=1 cb-finished=0; resuming the engine
expire #197: cb-entered=1 cb-finished=0; resuming the engine
expire #198: cb-entered=1 cb-finished=0; resuming the engine
expire #199: cb-entered=1 cb-finished=0; resuming the engine
expire #200: cb-entered=1 cb-finished=0; resuming the engine
callback: finished normally (entered=1 finished=1)
engine: uv-run returned #f (this means the callback's foreign frame returned)
result=((engine-done #f)) slices=200 cb-entered=1 cb-finished=1
loop-alive? #f
uv-run after -> #f
teardown -> ok
done
exit=0
```

**Observed (both runs byte-identical):** the callback was entered once and its body was sliced **200 times** (`cb-entered=1 cb-finished=0` at every expiry), then finished normally, the trampoline returned to C normally, `uv-run` returned `#f` inside the engine, and the engine completed. Teardown `ok`, exit 0.

So on this Chez, an engine expiry inside a foreign-callable is a non-local exit *through* the C frames that does not stale them: per CSUG 4.4 a foreign context becomes stale only "after a normal return to the context or after a return to some other foreign context beneath it", and the expire handler here did neither. The `uv_run` C frames stayed on the C stack, suspended, for the duration of the 200 slices (CSUG 4.4: "the C stack pointer is not automatically restored ... any further build-up of the C stack will add to the existing build up").

### E4d: expiry inside a callback, then uv-run from the expire handler while the outer uv_run is suspended

E4c plus: the expire handler calls `(uv-run loop 'nowait)` before resuming -- the shape of an engine scheduler that interleaves slices with `uv-run` if a handler ever runs a callback. A second 1 ms repeating timer `t2` shows whether the nested `uv_run` dispatches callbacks.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4d-uvrun-from-expire-handler-while-callback-suspended.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e4d-uvrun-from-expire-handler-while-callback-suspended.sps
```

Source (verbatim):

```scheme
;; E4d: the engine's ticks expire INSIDE a timer callback (as in E4c), and the
;; expire handler then calls (uv-run loop 'nowait) BEFORE resuming the engine,
;; i.e. a second uv_run while the first uv_run's C frames are suspended under
;; the unfinished callback. This is what an engine scheduler that interleaves
;; uv-run with slices would do if a handler ever ran a callback.
(import (rnrs) (only (chezscheme) make-engine) (libuv) (spike common))
(define loop (make-uv-loop))
(define (busy n) (let lp ((i 0) (acc 0)) (if (= i n) acc (lp (+ i 1) (+ acc i)))))
(define cb-entered 0) (define cb-finished 0) (define t2-fired 0)
(define t1 (make-uv-timer loop))
(define t2 (make-uv-timer loop))
(uv-timer-start! t1 (lambda (tm)
                      (set! cb-entered (+ cb-entered 1))
                      (busy 200000)
                      (set! cb-finished (+ cb-finished 1))
                      (say "t1 callback: finished normally (entered=" cb-entered " finished=" cb-finished ")"))
                 0 0)
(uv-timer-start! t2 (lambda (tm) (set! t2-fired (+ t2-fired 1))) 1 1)
(define handler
  (make-engine (lambda ()
    (say "engine: calling (uv-run loop 'once) from inside the slice")
    (let ((r (uv-run loop 'once)))
      (say "engine: uv-run returned " r)
      (list 'engine-done r)))))
(define slices 0)
(define result
  (guarded "engine" (lambda ()
    (let run ((eng handler))
      (eng 1000
        (lambda (ticks-left . vals) vals)
        (lambda (new-eng)
          (set! slices (+ slices 1))
          (let ((nested (guarded "nested-uv-run" (lambda () (uv-run loop 'nowait)))))
            (when (or (<= slices 3) (= 0 (mod slices 50)))
              (say "expire #" slices ": cb-entered=" cb-entered " cb-finished=" cb-finished
                   "; nested (uv-run loop 'nowait) -> " nested "; t2-fired=" t2-fired "; resuming")))
          (run new-eng)))))))
(say "result=" result " slices=" slices " cb-entered=" cb-entered " cb-finished=" cb-finished " t2-fired=" t2-fired)
(uv-timer-stop! t2)
(say "loop-alive? " (guarded "alive" (lambda () (uv-loop-alive? loop))))
(say "uv-run after -> " (guarded "uv-run-after" (lambda () (uv-run loop 'default))))
(say "teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4d-uvrun-from-expire-handler-while-callback-suspended.run1.txt`; the last line is gtimeout's exit status):

```text
engine: calling (uv-run loop 'once) from inside the slice
expire #1: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #2: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #3: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #50: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #100: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=1; resuming
expire #150: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=2; resuming
expire #200: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=3; resuming
t1 callback: finished normally (entered=1 finished=1)
engine: uv-run returned #t
result=((engine-done #t)) slices=200 cb-entered=1 cb-finished=1 t2-fired=3
loop-alive? #f
uv-run after -> #f
teardown -> ok
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e4d-uvrun-from-expire-handler-while-callback-suspended.run2.txt`; the last line is gtimeout's exit status):

```text
engine: calling (uv-run loop 'once) from inside the slice
expire #1: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #2: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #3: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #50: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=0; resuming
expire #100: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=1; resuming
expire #150: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=2; resuming
expire #200: cb-entered=1 cb-finished=0; nested (uv-run loop 'nowait) -> #t; t2-fired=3; resuming
t1 callback: finished normally (entered=1 finished=1)
engine: uv-run returned #t
result=((engine-done #t)) slices=200 cb-entered=1 cb-finished=1 t2-fired=3
loop-alive? #f
uv-run after -> #f
teardown -> ok
done
exit=0
```

**Observed (both runs byte-identical):**

- **chez-libuv did not refuse the nested `uv-run`.** It returned `#t` at every one of the 200 expiries. The `loop-running` flag had been cleared by `uv-run`'s `dynamic-wind` after-thunk when the engine expiry exited the extent (loop.sls:60-63), so the guard at loop.sls:55-56 saw `#f`. The re-entry refusal is therefore **not** a safety net against engine expiry; it only catches the plain "call uv-run from a callback" case (E6).
- The nested `uv_run` calls dispatched `t2`'s callback three times while `t1`'s callback was suspended mid-body under the outer, still-live `uv_run` C frames -- a genuine libuv `uv_run` re-entry, which libuv documents as forbidden ("uv_run() is not reentrant. It must not be called from a callback.", loop.html). It did not crash in 2/2 runs on this platform; that is an absence of a symptom, not evidence of safety.
- The outer callback then finished, the outer `uv-run` returned `#t`, the engine completed, teardown `ok`.

### E5a: worker thread pushes onto a mutex-protected queue; loop thread polls from a 1 ms timer and writes to a TCP peer

`fork-thread` worker sleeps 50 ms, computes, pushes a bytevector under `with-mutex`; the loop thread's 1 ms repeating timer pops under the same mutex and `uv-write!`s to the accepted peer; the client (same loop) reads it back.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5a-thread-queue-timer.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5a-thread-queue-timer.sps
```

Source (verbatim):

```scheme
;; E5a: a fork-thread worker sleeps/computes and pushes a result onto a
;; mutex-protected queue; the loop thread polls from a 1 ms repeating timer and
;; writes the result to a TCP peer, which reads it back.
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time get-thread-id) (libuv) (spike common))
(define loop (make-uv-loop))
(define q '()) (define m (make-mutex))
(define t0 (now-ms))
(define worker-pushed-at #f)
(define worker-thread-id #f)
(define (compute) (let lp ((i 0) (acc 0)) (if (= i 1000000) acc (lp (+ i 1) (+ acc i)))))
(fork-thread (lambda ()
  (set! worker-thread-id (get-thread-id))
  (sleep (make-time 'time-duration 50000000 0))       ; 50 ms
  (let ((r (compute)))
    (with-mutex m
      (set! q (cons (string->utf8 (string-append "result=" (number->string r))) q))
      (set! worker-pushed-at (- (now-ms) t0))))))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define peer #f)
(define poll-timer (make-uv-timer loop))
(define polls 0)
(uv-listen! server 128 (lambda (err)
  (set! peer (uv-accept! server))
  (uv-read-start! peer (lambda (bv s e) #f) (lambda () #f) (lambda (err) #f))
  (uv-timer-start! poll-timer
    (lambda (tm)
      (set! polls (+ polls 1))
      (let ((item (with-mutex m (and (pair? q) (let ((x (car q))) (set! q (cdr q)) x)))))
        (when item
          (say "loop thread " (get-thread-id) ": got item after " polls " polls at +" (- (now-ms) t0) "ms (worker " worker-thread-id " pushed at +" worker-pushed-at "ms); uv-write! to peer")
          (uv-timer-stop! poll-timer)
          (uv-write! peer item (lambda (err) (say "loop: write complete err=" err)
                                              (uv-shutdown! peer (lambda (err) (uv-close! peer))))))))
    1 1)))
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port (lambda (err)
  (uv-read-start! client
    (lambda (bv s e) (say "client: received \"" (utf8->string (let ((o (make-bytevector (- e s)))) (bytevector-copy! bv s o 0 (- e s)) o)) "\""))
    (lambda () (say "client: eof") (uv-close! client) (uv-close! server) (uv-close! poll-timer))
    (lambda (err) (uv-close! client)))))
(say "top: uv-run -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5a-thread-queue-timer.run1.txt`; the last line is gtimeout's exit status):

```text
loop thread 0: got item after 43 polls at +57ms (worker 1 pushed at +57ms); uv-write! to peer
loop: write complete err=#f
client: received "result=499999500000"
client: eof
top: uv-run -> #f
top: teardown -> ok
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5a-thread-queue-timer.run2.txt`; the last line is gtimeout's exit status):

```text
loop thread 0: got item after 47 polls at +62ms (worker 1 pushed at +61ms); uv-write! to peer
loop: write complete err=#f
client: received "result=499999500000"
client: eof
top: uv-run -> #f
top: teardown -> ok
top: done
exit=0
```

**Observed (runs differ only in timings: 43/47 polls, +57/+62 ms):** delivered intact (`result=499999500000`), the write completion and the shutdown/close chain ran on the loop thread (thread id 0; worker was thread 1), teardown `ok`. Latency from push to pick-up was 0-1 ms, as the 1 ms poll implies.

### E5b (NEGATIVE): the worker thread calls uv-write! directly on the loop thread's handle while the loop runs

Single `uv-write!` from the worker (thread 1) on the peer handle, 20 ms after it was accepted, while thread 0 is inside `uv-run`.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5b-thread-direct-uv-write.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 20 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5b-thread-direct-uv-write.sps
```

Source (verbatim):

```scheme
;; E5b (NEGATIVE): the worker thread calls uv-write! directly on a handle owned
;; by the loop thread while the loop is running. Expected: undefined behaviour.
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time get-thread-id) (libuv) (spike common))
(define loop (make-uv-loop))
(define t0 (now-ms))
(define m (make-mutex))
(define worker-outcome 'not-run)          ; written by worker, read by loop thread
(define peer #f)
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))
(fork-thread (lambda ()
  (let wait () (unless (with-mutex m peer) (nap 1) (wait)))
  (nap 20)
  (let ((r (guard (e (#t (list 'raised (condition-kinds e))))
             (uv-write! (with-mutex m peer) (string->utf8 "from-worker")
                        (lambda (err) (say "on-complete ran on thread " (get-thread-id) " err=" err)))
             'uv-write!-returned)))
    (with-mutex m (set! worker-outcome (list r 'on-thread (get-thread-id) 'at (- (now-ms) t0)))))))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define keepalive (make-uv-timer loop))
(define ticks 0)
(uv-timer-start! keepalive (lambda (tm) (set! ticks (+ ticks 1))
                             (when (> ticks 2000) (say "loop: giving up after 2 s; worker-outcome=" (with-mutex m worker-outcome))
                                   (uv-timer-stop! keepalive) (uv-close! server) (when peer (uv-close! peer))))
                 1 1)
(uv-listen! server 128 (lambda (err)
  (let ((p (uv-accept! server)))
    (uv-read-start! p (lambda (bv s e) #f) (lambda () #f) (lambda (err) #f))
    (with-mutex m (set! peer p))
    (say "loop thread " (get-thread-id) ": peer accepted and published to the worker"))))
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port (lambda (err)
  (uv-read-start! client
    (lambda (bv s e)
      (say "client: received \"" (utf8->string (let ((o (make-bytevector (- e s)))) (bytevector-copy! bv s o 0 (- e s)) o)) "\" at +" (- (now-ms) t0) "ms; worker-outcome=" (with-mutex m worker-outcome))
      (uv-timer-stop! keepalive) (uv-close! client) (uv-close! server) (uv-close! peer) (uv-close! keepalive))
    (lambda () (uv-close! client))
    (lambda (err) (uv-close! client)))))
(say "top: uv-run -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: worker-outcome=" (with-mutex m worker-outcome))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b-thread-direct-uv-write.run1.txt`; the last line is gtimeout's exit status):

```text
loop thread 0: peer accepted and published to the worker
on-complete ran on thread 0 err=#f
client: received "from-worker" at +36ms; worker-outcome=(uv-write!-returned on-thread 1 at 36)
top: uv-run -> #f
top: worker-outcome=(uv-write!-returned on-thread 1 at 36)
top: teardown -> ok
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b-thread-direct-uv-write.run2.txt`; the last line is gtimeout's exit status):

```text
loop thread 0: peer accepted and published to the worker
client: received "from-worker" at +29ms; worker-outcome=(uv-write!-returned on-thread 1 at 29)
on-complete ran on thread 0 err=#f
top: uv-run -> #f
top: worker-outcome=(uv-write!-returned on-thread 1 at 29)
top: teardown -> ok
top: done
exit=0
```

**Observed (runs differ only in timing and print interleaving):** in 2/2 runs `uv-write!` returned on thread 1, the payload arrived at the client, and the on-complete callback ran on thread 0. No crash. This is the undefined behaviour *not* manifesting for a single call; E5b2 stresses it.

### E5b2 (NEGATIVE, stress): 2000 uv-write! from the worker thread concurrent with 2000 from the loop thread on the same handle

Run **four** times because the first two runs disagreed. Client expects 4000 bytes; a 5 s watchdog reports and closes if not.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5b2-thread-direct-uv-write-stress.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 20 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5b2-thread-direct-uv-write-stress.sps
```

Source (verbatim):

```scheme
;; E5b2 (NEGATIVE, stress): the worker thread issues 2000 uv-write! calls on
;; the loop thread's handle while the loop thread issues 2000 of its own on the
;; same handle. Client counts bytes; expected 4000 if nothing breaks.
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time get-thread-id) (libuv) (spike common))
(define loop (make-uv-loop))
(define t0 (now-ms))
(define m (make-mutex))
(define peer #f)
(define worker-ok 0) (define worker-raised '()) (define worker-done #f)
(define loop-writes 0) (define loop-completions 0) (define worker-completions 0)
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))
(fork-thread (lambda ()
  (let wait () (unless (with-mutex m peer) (nap 1) (wait)))
  (let ((p (with-mutex m peer)))
    (let lp ((i 0))
      (when (< i 2000)
        (guard (e (#t (with-mutex m (set! worker-raised (cons (condition-kinds e) worker-raised)))))
          (uv-write! p (string->utf8 "W") (lambda (err) (set! worker-completions (+ worker-completions 1))))
          (with-mutex m (set! worker-ok (+ worker-ok 1))))
        (lp (+ i 1))))
    (with-mutex m (set! worker-done #t)))))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define writer (make-uv-timer loop))
(define watchdog (make-uv-timer loop))
(define received 0)
(define client (make-uv-tcp loop))
(define (finish! why)
  (say "finish (" why ") at +" (- (now-ms) t0) "ms: received=" received " loop-writes=" loop-writes " loop-completions=" loop-completions
       " worker-ok=" (with-mutex m worker-ok) " worker-completions=" worker-completions " worker-raised=" (with-mutex m (length worker-raised))
       " worker-done=" (with-mutex m worker-done))
  (unless (null? worker-raised) (say "first worker raise kinds: " (car (reverse worker-raised))))
  (uv-close! writer) (uv-close! watchdog) (uv-close! client) (uv-close! server) (when peer (uv-close! peer)))
(uv-listen! server 128 (lambda (err)
  (let ((p (uv-accept! server)))
    (uv-read-start! p (lambda (bv s e) #f) (lambda () #f) (lambda (err) #f))
    (with-mutex m (set! peer p))
    (uv-timer-start! writer
      (lambda (tm)
        (let lp ((i 0)) (when (and (< i 50) (< loop-writes 2000))
          (uv-write! p (string->utf8 "L") (lambda (err) (set! loop-completions (+ loop-completions 1))))
          (set! loop-writes (+ loop-writes 1)) (lp (+ i 1))))
        (when (>= loop-writes 2000) (uv-timer-stop! writer)))
      0 1))))
(uv-timer-start! watchdog (lambda (tm) (finish! "watchdog 5s")) 5000 0)
(uv-tcp-connect! client "127.0.0.1" port (lambda (err)
  (uv-read-start! client
    (lambda (bv s e) (set! received (+ received (- e s)))
      (when (and (>= received 4000) (with-mutex m worker-done)) (finish! "all bytes received")))
    (lambda () (finish! "eof"))
    (lambda (err) (finish! "client error")))))
(say "top: uv-run -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b2-thread-direct-uv-write-stress.run1.txt`; the last line is gtimeout's exit status):

```text
finish (watchdog 5s) at +5000ms: received=43 loop-writes=100 loop-completions=95 worker-ok=2000 worker-completions=1165 worker-raised=0 worker-done=#t
exit=124
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b2-thread-direct-uv-write-stress.run2.txt`; the last line is gtimeout's exit status):

```text
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: invalid memory reference.  Some debugging context lost
top: uv-run -> raised
top: teardown -> ok
top: done
exit=0
```

Run 3 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b2-thread-direct-uv-write-stress.run3.txt`; the last line is gtimeout's exit status):

```text
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: invalid memory reference.  Some debugging context lost
top: uv-run -> raised
top: teardown -> ok
top: done
exit=0
```

Run 4 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5b2-thread-direct-uv-write-stress.run4.txt`; the last line is gtimeout's exit status):

```text
uv-run | kinds: (&assertion &format &message &irritants &continuation)
uv-run | display-condition: Exception: invalid memory reference.  Some debugging context lost
top: uv-run -> raised
teardown | kinds: (&assertion &format &who &message &irritants &continuation)
teardown | display-condition: Exception in registry-entry-loop: 0 is not of type #<record type registry-entry>
top: teardown -> raised
top: done
exit=0
```

**Observed -- four runs, three distinct failure modes, no success:**

- Run 1: **hang / lost data.** After 5 s only 43 of 4000 bytes had arrived; the loop thread had issued only 100 writes and 95 completions; the worker's 2000 `uv-write!` calls all *returned* but only 1165 completions ran. Teardown then hung; **gtimeout killed the process (exit=124)**.
- Runs 2 and 3: `uv-run` raised Chez `&assertion` **"invalid memory reference. Some debugging context lost"** (a memory fault caught by Chez's signal handler); teardown then reported `ok`.
- Run 4: the same invalid memory reference, and then **teardown itself raised** `Exception in registry-entry-loop: 0 is not of type #<record type registry-entry>` -- chez-libuv's unsynchronised handle/request registry (an eqv-hashtable, see task context) was corrupted by the concurrent inserts.

Conclusion for this binding on this platform: calling `uv-write!` from a non-loop thread is not merely libuv-undefined; under light contention it corrupts the binding's own registry and faults. Cross-thread delivery must go through a queue drained on the loop thread (E5a). libuv's `uv_async_send` -- the one loop API documented as callable from another thread -- is not bound in chez-libuv v0.5.0 (task context: NOT bound: `uv_async`), so the 1 ms polling timer of E5a is currently the only wake-up path.

### E5c: does a heavily allocating worker thread stall while the loop thread blocks in uv-run?

Because `uv_run` is bound without `__collect_safe` (native.sls:242), the loop thread stays *active* while blocked in `uv_run`, and CSUG says active threads in C "prevent the storage management system from garbage collecting". Worker allocates 3,000,000 ten-element vectors (~34 collections). Baseline: main thread sleeps in Scheme 1 ms at a time. Test 1: main thread blocks in `(uv-run loop 'once)` with only a 300 ms repeating timer. Test 2: same with a 1 ms timer.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5c-gc-stall-while-blocked-in-uv-run.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 60 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e5c-gc-stall-while-blocked-in-uv-run.sps
```

Source (verbatim):

```scheme
;; E5c: uv_run is bound WITHOUT __collect_safe (native.sls:242). Does a worker
;; thread that allocates heavily stall while the loop thread blocks in uv-run?
;; Baseline: worker allocates while the main thread sleeps in Scheme.
;; Test: worker allocates while the main thread blocks in (uv-run 'once) on a
;; loop whose only handle is a 300 ms timer.
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time collections) (libuv) (spike common))
(define m (make-mutex))
(define (nap ms) (sleep (make-time 'time-duration (* ms 1000000) 0)))
(define (allocate!) (let lp ((i 0) (keep '())) (if (= i 3000000) (length keep) (lp (+ i 1) (if (= 0 (mod i 100000)) (cons (make-vector 10) keep) (begin (make-vector 10) keep))))))
(define (run-worker main-wait)
  (let ((done #f) (elapsed #f) (c0 (collections)))
    (fork-thread (lambda () (let ((t0 (now-ms))) (allocate!) (with-mutex m (set! elapsed (- (now-ms) t0)) (set! done #t)))))
    (let wait () (unless (with-mutex m done) (main-wait) (wait)))
    (say "  worker elapsed " elapsed " ms; collections during: " (- (collections) c0))
    elapsed))
(say "baseline: main thread sleeps 1 ms at a time (Scheme sleep)")
(run-worker (lambda () (nap 1)))
(say "test: main thread blocks in (uv-run loop 'once) with only a 300 ms repeating timer armed")
(define loop (make-uv-loop))
(define t (make-uv-timer loop))
(define fires 0)
(uv-timer-start! t (lambda (tm) (set! fires (+ fires 1))) 300 300)
(run-worker (lambda () (uv-run loop 'once)))
(say "  timer fired " fires " times while waiting")
(say "test 2: same but the loop's timer fires every 1 ms")
(uv-timer-stop! t)
(uv-timer-start! t (lambda (tm) (set! fires (+ fires 1))) 1 1)
(set! fires 0)
(run-worker (lambda () (uv-run loop 'once)))
(say "  timer fired " fires " times while waiting")
(uv-close! t) (uv-run loop 'default) (uv-loop-teardown! loop)
(say "done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5c-gc-stall-while-blocked-in-uv-run.run1.txt`; the last line is gtimeout's exit status):

```text
baseline: main thread sleeps 1 ms at a time (Scheme sleep)
  worker elapsed 28 ms; collections during: 34
test: main thread blocks in (uv-run loop 'once) with only a 300 ms repeating timer armed
  worker elapsed 10272 ms; collections during: 34
  timer fired 35 times while waiting
test 2: same but the loop's timer fires every 1 ms
  worker elapsed 91 ms; collections during: 35
  timer fired 70 times while waiting
done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e5c-gc-stall-while-blocked-in-uv-run.run2.txt`; the last line is gtimeout's exit status):

```text
baseline: main thread sleeps 1 ms at a time (Scheme sleep)
  worker elapsed 26 ms; collections during: 34
test: main thread blocks in (uv-run loop 'once) with only a 300 ms repeating timer armed
  worker elapsed 10266 ms; collections during: 34
  timer fired 35 times while waiting
test 2: same but the loop's timer fires every 1 ms
  worker elapsed 93 ms; collections during: 35
  timer fired 70 times while waiting
done
exit=0
```

**Observed (runs differ by a few ms):**

| main thread while worker allocates | worker elapsed | collections |
|---|---|---|
| Scheme `sleep` 1 ms loop (baseline) | 26-28 ms | 34 |
| blocked in `uv-run 'once`, 300 ms timer | **10266-10272 ms** | 34 (timer fired 35 times) |
| blocked in `uv-run 'once`, 1 ms timer | 91-93 ms | 35 (timer fired 70 times) |

Each of the worker's ~34 collections had to wait until the loop thread next returned from `uv_run` into Scheme (a timer callback), i.e. up to one poll timeout per collection: 34 x 300 ms = 10.2 s. **A blocking `uv-run` on the loop thread freezes every other Scheme thread at its next allocation-triggered collection for the length of the poll.** The 1 ms timer's 3x (instead of 370x) looked like a workaround. E5d and E5e (added 2026-09-19, evening, after chez-libuv's threading spike measured the same ticker as useless) show it is not: a plain `uv_run` lets the worker collect only when the loop thread's own Scheme execution per tick reaches Chez's trap check, which chez-libuv's dispatch path happens to do and a bare callback does not. The binding must bind `uv_run` with `__collect_safe` (and, per CSUG, each callable with `__collect_safe` too); no timer substitutes.

### E5d: is E5c's 1 ms ticker a GC workaround, or an accident of how much Scheme the loop thread runs per tick?

chez-libuv's threading spike (`spike/threading/03-auto-gc-and-workaround.ss` on its `spike/threading-collect-safe` branch, 2026-09-19, its T2b) re-ran E5c's idea on raw FFI and found the 1 ms ticker useless: 448 ms with a 1 ms repeating timer (under `UV_RUN_DEFAULT` and under a `UV_RUN_ONCE` loop alike) against 591 ms plain and 6 ms with `uv_run` `__collect_safe`. That script reproduces on this machine (one run per mode: plain 587 ms, safe 6, plain-ticker 442, plain-once-ticker 526), and so does E5c (third run: 29 / 10244 / 84 ms). This experiment is chez-libuv's script with one knob added: what the loop thread executes per tick. Same worker as T2b (4000 lists of 1000 conses, allocation-triggered collections only), same 400-fire cap on the 1 ms timer, so a stall of ~440 ms means the worker never collected until the ticker ended and the loop thread parked in `condition-wait`. `*-busy N` runs N non-inlined, non-allocating procedure calls per tick; `*-mutex` acquires and releases an uncontended mutex; `once-sleep0` calls `(sleep 0)` between polls; `safe` is T2b's collect-safe mode.

Script: `.plans/research/spike/e5d-ticker-needs-trap-ticks.sps` (this repository; added 2026-09-19, evening). Chez-libuv checkout at 23fa923 (branch `spike/threading-collect-safe`; its `src/` is identical to `main` at 83e0184, `uv_run` still bound plain at native.sls:242).

Command (each run is a fresh process; the spike directory is on the library path for `(spike common)`):

```sh
cd .plans/research/spike && CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:$PWD gtimeout 180 chez --program e5d-ticker-needs-trap-ticks.sps
```

Source (verbatim):

```scheme
;; E5d: reconciling E5c (1 ms timer -> 3x slowdown) with chez-libuv
;; spike/threading T2b (1 ms timer -> ~75x, "no help"). Raw FFI like T2b: a
;; plain uv_run, a 1 ms repeating timer capped at 400 fires, a worker thread
;; that only allocates (4000 x 1000-cons lists, allocation-triggered GC only).
;; One knob: what the LOOP THREAD does per tick. once-* = between
;; (uv_run UV_RUN_ONCE) polls; default-* = inside the timer callback under one
;; (uv_run UV_RUN_DEFAULT).
;;   once / default   : nothing extra (T2b's plain-once-ticker / plain-ticker)
;;   *-busy N         : N non-inlined, non-allocating procedure calls
;;   *-mutex          : acquire and release an uncontended mutex
;;   once-sleep0      : (sleep 0) between polls
;;   safe             : uv_run and both callables __collect_safe (T2b's safe)
(import (chezscheme) (spike common))
(unless (threaded?) (say "SKIP: not threaded") (exit 3))
(define lib-path (or (getenv "LIBUV_DYLIB") "/opt/homebrew/opt/libuv/lib/libuv.dylib"))
(load-shared-object lib-path)
(define UV_RUN_DEFAULT 0) (define UV_RUN_ONCE 1) (define UV_TIMER 13)
(define ALLOC-ROUNDS 4000) (define FIRE-CAP 400)
(define uv-run-plain   (foreign-procedure                "uv_run" (uptr int) int))
(define uv-run-safe    (foreign-procedure __collect_safe "uv_run" (uptr int) int))
(define uv-loop-size   (foreign-procedure "uv_loop_size"   () size_t))
(define uv-handle-size (foreign-procedure "uv_handle_size" (int) size_t))
(define uv-loop-init   (foreign-procedure "uv_loop_init"   (uptr) int))
(define uv-loop-close  (foreign-procedure "uv_loop_close"  (uptr) int))
(define uv-timer-init  (foreign-procedure "uv_timer_init"  (uptr uptr) int))
(define uv-timer-start (foreign-procedure "uv_timer_start" (uptr uptr unsigned-64 unsigned-64) int))
(define uv-timer-stop  (foreign-procedure "uv_timer_stop"  (uptr) int))
(define uv-stop        (foreign-procedure "uv_stop"        (uptr) void))
(define uv-close       (foreign-procedure "uv_close"       (uptr uptr) void))
(define (alloc-zeroed n) (let ((p (foreign-alloc n))) (do ((i 0 (+ i 1))) ((= i n) p) (foreign-set! 'unsigned-8 p i 0))))
(define (mk-cb safe? proc) (if safe? (foreign-callable __collect_safe proc (uptr) void) (foreign-callable proc (uptr) void)))
;; step is chosen at run time so cp0 cannot inline it: every burn iteration is a real call.
(define step (if (getenv "E5D_NEVER_SET") (lambda (x) x) (lambda (x) (fx+ x 1))))
(define sink 0)
(define (burn n) (let lp ((i 0) (acc 0)) (if (fx= i n) (set! sink acc) (lp (fx+ i 1) (step acc)))))
(define (allocate!) (let lp ((i 0)) (when (fx< i ALLOC-ROUNDS) (let build ((k 0) (acc '())) (if (fx< k 1000) (build (fx+ k 1) (cons k acc)) acc)) (lp (fx+ i 1)))))
(define (trial mode n)
  (let* ((safe? (eq? mode 'safe))
         (once? (and (memq mode '(once once-busy once-mutex once-sleep0)) #t))
         (uv-run (if safe? uv-run-safe uv-run-plain))
         (m2 (make-mutex))
         (extra (case mode
                  ((once-busy default-busy) (lambda () (burn n)))
                  ((once-mutex default-mutex) (lambda () (with-mutex m2 (set! sink (fx+ sink 1)))))
                  ((once-sleep0) (lambda () (sleep (make-time 'time-duration 0 0))))
                  (else (lambda () #f))))
         (loop-ptr (alloc-zeroed (uv-loop-size)))
         (timer-ptr (alloc-zeroed (uv-handle-size UV_TIMER)))
         (fires 0)
         (timer-cb (mk-cb safe? (lambda (h) (set! fires (fx+ fires 1)) (unless once? (extra)) (when (fx>= fires FIRE-CAP) (uv-stop loop-ptr)))))
         (close-cb (mk-cb safe? (lambda (h) #f)))
         (m (make-mutex)) (cv (make-condition))
         (entered #f) (done #f) (elapsed #f) (gcs #f))
    (lock-object timer-cb) (lock-object close-cb)
    (uv-loop-init loop-ptr) (uv-timer-init loop-ptr timer-ptr)
    (uv-timer-start timer-ptr (foreign-callable-entry-point timer-cb) 1 1)
    (fork-thread
      (lambda ()
        (let spin () (unless (with-mutex m entered) (sleep (make-time 'time-duration 0 0)) (spin)))
        (sleep (make-time 'time-duration 20000000 0)) ; 20 ms: let the loop thread reach uv_run
        (let ((t0 (real-time)) (c0 (collections)))
          (allocate!)
          (let ((e (- (real-time) t0)) (g (- (collections) c0)))
            (with-mutex m (set! elapsed e) (set! gcs g) (set! done #t) (condition-signal cv))))))
    (with-mutex m (set! entered #t))
    (let ((t0 (real-time)))
      (if once?
          (let lp () (uv-run loop-ptr UV_RUN_ONCE) (extra) (when (fx< fires FIRE-CAP) (lp)))
          (uv-run loop-ptr UV_RUN_DEFAULT))
      (let ((wall (- (real-time) t0)))
        (with-mutex m (let w () (unless done (condition-wait cv m) (w))))
        (uv-timer-stop timer-ptr)
        (uv-close timer-ptr (foreign-callable-entry-point close-cb))
        (uv-run loop-ptr UV_RUN_DEFAULT)
        (uv-loop-close loop-ptr) (foreign-free timer-ptr) (foreign-free loop-ptr)
        (unlock-object timer-cb) (unlock-object close-cb)
        (say "  " mode (if (memq mode '(once-busy default-busy)) (string-append " " (number->string n) " calls/tick") "")
             ": worker alloc load " elapsed " ms; collections " gcs "; timer fired " fires "; uv_run wall " wall " ms")))))
(say "what the loop thread does per 1 ms tick -> the worker's allocation-triggered GC (plain uv_run unless 'safe')")
(for-each (lambda (spec) (trial (car spec) (cdr spec)))
  '((once . 0) (once-busy . 100) (once-busy . 300) (once-busy . 1000) (once-busy . 2000)
    (once-mutex . 0) (once-sleep0 . 0)
    (default . 0) (default-busy . 100) (default-busy . 300) (default-busy . 1000) (default-busy . 2000)
    (default-mutex . 0) (safe . 0)))
(say "done")
```

Run 1 output (verbatim, `.plans/research/spike/out/e5d-ticker-needs-trap-ticks.run1.txt`; the last line is gtimeout's exit status):

```text
what the loop thread does per 1 ms tick -> the worker's allocation-triggered GC (plain uv_run unless 'safe')
  once: worker alloc load 446 ms; collections 8; timer fired 400; uv_run wall 458 ms
  once-busy 100 calls/tick: worker alloc load 82 ms; collections 8; timer fired 400; uv_run wall 468 ms
  once-busy 300 calls/tick: worker alloc load 29 ms; collections 7; timer fired 400; uv_run wall 465 ms
  once-busy 1000 calls/tick: worker alloc load 19 ms; collections 8; timer fired 400; uv_run wall 462 ms
  once-busy 2000 calls/tick: worker alloc load 20 ms; collections 8; timer fired 400; uv_run wall 465 ms
  once-mutex: worker alloc load 437 ms; collections 7; timer fired 400; uv_run wall 456 ms
  once-sleep0: worker alloc load 12 ms; collections 8; timer fired 400; uv_run wall 458 ms
  default: worker alloc load 447 ms; collections 7; timer fired 400; uv_run wall 457 ms
  default-busy 100 calls/tick: worker alloc load 84 ms; collections 8; timer fired 400; uv_run wall 460 ms
  default-busy 300 calls/tick: worker alloc load 32 ms; collections 8; timer fired 400; uv_run wall 462 ms
  default-busy 1000 calls/tick: worker alloc load 19 ms; collections 7; timer fired 400; uv_run wall 457 ms
  default-busy 2000 calls/tick: worker alloc load 18 ms; collections 8; timer fired 400; uv_run wall 458 ms
  default-mutex: worker alloc load 437 ms; collections 8; timer fired 400; uv_run wall 453 ms
  safe: worker alloc load 10 ms; collections 7; timer fired 400; uv_run wall 462 ms
done
exit=0
```

Run 2 output (verbatim, `.plans/research/spike/out/e5d-ticker-needs-trap-ticks.run2.txt`; the last line is gtimeout's exit status):

```text
what the loop thread does per 1 ms tick -> the worker's allocation-triggered GC (plain uv_run unless 'safe')
  once: worker alloc load 442 ms; collections 8; timer fired 400; uv_run wall 455 ms
  once-busy 100 calls/tick: worker alloc load 84 ms; collections 8; timer fired 400; uv_run wall 470 ms
  once-busy 300 calls/tick: worker alloc load 31 ms; collections 7; timer fired 400; uv_run wall 459 ms
  once-busy 1000 calls/tick: worker alloc load 12 ms; collections 8; timer fired 400; uv_run wall 456 ms
  once-busy 2000 calls/tick: worker alloc load 11 ms; collections 8; timer fired 400; uv_run wall 558 ms
  once-mutex: worker alloc load 437 ms; collections 7; timer fired 400; uv_run wall 454 ms
  once-sleep0: worker alloc load 9 ms; collections 8; timer fired 400; uv_run wall 454 ms
  default: worker alloc load 439 ms; collections 7; timer fired 400; uv_run wall 455 ms
  default-busy 100 calls/tick: worker alloc load 85 ms; collections 8; timer fired 400; uv_run wall 455 ms
  default-busy 300 calls/tick: worker alloc load 32 ms; collections 8; timer fired 400; uv_run wall 456 ms
  default-busy 1000 calls/tick: worker alloc load 9 ms; collections 7; timer fired 400; uv_run wall 455 ms
  default-busy 2000 calls/tick: worker alloc load 9 ms; collections 8; timer fired 400; uv_run wall 457 ms
  default-mutex: worker alloc load 438 ms; collections 8; timer fired 400; uv_run wall 454 ms
  safe: worker alloc load 6 ms; collections 7; timer fired 400; uv_run wall 455 ms
done
exit=0
```

**Observed (two runs; worker alloc load, ms):**

| loop thread per 1 ms tick | between `UV_RUN_ONCE` polls | inside the callback, one `UV_RUN_DEFAULT` |
|---|---|---|
| nothing (T2b's harness) | 442-446 | 439-447 |
| 100 procedure calls | 82-84 | 84-85 |
| 300 procedure calls | 29-31 | 32 |
| 1000 procedure calls | 12-19 | 9-19 |
| 2000 procedure calls | 11-20 | 9-18 |
| uncontended mutex acquire/release | 437 | 437-438 |
| `(sleep 0)` | 9-12 | n/a |
| `uv_run` and callables `__collect_safe` | n/a | 6-10 |

Collections per trial: 7-8 in every row; timer fired 400 times in every row; `uv_run` wall 453-470 ms except one 558 ms outlier (once-busy 2000, run 2).

**Reading.** The ticker does nothing by itself and everything once the loop thread runs a few hundred procedure calls per tick; ~300 halves the stall, ~1000 removes it, whether the calls run between polls or inside the callback. An uncontended mutex per tick does not help; `(sleep 0)` does.

Mechanism, from the Chez 10.4.1 sources (fetched from github.com/cisco/ChezScheme at tag v10.4.1 on 2026-09-19): `S_fire_collector` sets `$collect-request-pending` and every thread's `something-pending` flag, and nothing else (c/schsig.c:574-594). A thread notices only at its next `$event`, which runs when its trap counter reaches zero; the counter starts at `default-timer-ticks` = 1000 (s/cmacros.ss:2118; c/thread.c:355), and `$event` calls `$collect-rendezvous` when a request is pending (s/library.ss:1219-1236). Only a thread *created* while a request is pending is told to check at once (c/thread.c:181-183). `mutex-acquire` is a plain foreign procedure (s/prims.ss:2007) that just locks (c/thread.c:388-404), so an uncontended acquire neither deactivates the thread nor trips its counter, which is why the `*-mutex` rows did not move; `(sleep 0)` and a `__collect_safe` call deactivate the thread, which is why those rows did.

So with a plain `uv_run` the loop thread serves the worker's collection only when its own Scheme execution per tick burns through roughly a thousand trap ticks. A bare callback does not. **The 1 ms timer is not a workaround.** It makes the loop thread run whatever Scheme its dispatch path contains once per millisecond, and the outcome depends entirely on how much that is (E5e measures chez-libuv's).

### E5e: E5c through the binding with the loop thread never leaving `uv-run 'default`

E5c's main thread returned to top-level Scheme between `'once` polls (its wait loop). Was that what opened the GC windows, or does chez-libuv's own per-callback dispatch path (trampoline -> registry lookup -> `dispatch-guarded` -> closure) suffice? Same worker as E5c (3,000,000 ten-element vectors, ~34 collections); the loop thread sits in one `(uv-run loop 'default)` until the timer callback sees the worker done and closes the timer. First a 300 ms timer, then a 1 ms timer.

Script: `.plans/research/spike/e5e-gc-stall-uvrun-default.sps` (this repository; added 2026-09-19, evening). Chez-libuv checkout at 23fa923 (branch `spike/threading-collect-safe`; its `src/` is identical to `main` at 83e0184, `uv_run` still bound plain at native.sls:242).

Command (each run is a fresh process; the spike directory is on the library path for `(spike common)`):

```sh
cd .plans/research/spike && CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:$PWD gtimeout 180 chez --program e5e-gc-stall-uvrun-default.sps
```

Source (verbatim):

```scheme
;; E5e: E5c through the binding, but the loop thread sits in ONE (uv-run loop 'default)
;; and never returns to top-level Scheme between polls: only chez-libuv's timer
;; dispatch path (trampoline -> registry -> dispatch-guarded -> closure) runs per
;; tick. If the worker still finishes in a few ms with a 1 ms timer, the binding's
;; per-callback Scheme volume alone reaches $event, and E5c's 'once wait loop was
;; not what opened the GC windows. Same worker as E5c (3,000,000 ten-element vectors).
(import (rnrs) (only (chezscheme) fork-thread make-mutex with-mutex sleep make-time collections) (libuv) (spike common))
(define m (make-mutex))
(define (allocate!) (let lp ((i 0) (keep '())) (if (= i 3000000) (length keep) (lp (+ i 1) (if (= 0 (mod i 100000)) (cons (make-vector 10) keep) (begin (make-vector 10) keep))))))
(define (trial period-ms)
  (let* ((loop (make-uv-loop)) (t (make-uv-timer loop)) (done #f) (elapsed #f) (fires 0) (c0 (collections)))
    (uv-timer-start! t (lambda (tm) (set! fires (+ fires 1)) (when (with-mutex m done) (uv-close! t))) period-ms period-ms)
    (fork-thread (lambda () (sleep (make-time 'time-duration 20000000 0)) (let ((t0 (now-ms))) (allocate!) (with-mutex m (set! elapsed (- (now-ms) t0)) (set! done #t)))))
    (uv-run loop 'default)
    (uv-loop-teardown! loop)
    (say "  period " period-ms " ms: worker elapsed " elapsed " ms; collections " (- (collections) c0) "; timer fired " fires " times")))
(say "loop thread in one (uv-run loop 'default); binding dispatch path only")
(trial 300)
(trial 1)
(say "done")
```

Run 1 output (verbatim, `.plans/research/spike/out/e5e-gc-stall-uvrun-default.run1.txt`; the last line is gtimeout's exit status):

```text
loop thread in one (uv-run loop 'default); binding dispatch path only
  period 300 ms: worker elapsed 10223 ms; collections 34; timer fired 35 times
  period 1 ms: worker elapsed 92 ms; collections 35; timer fired 92 times
done
exit=0
```

Run 2 output (verbatim, `.plans/research/spike/out/e5e-gc-stall-uvrun-default.run2.txt`; the last line is gtimeout's exit status):

```text
loop thread in one (uv-run loop 'default); binding dispatch path only
  period 300 ms: worker elapsed 10240 ms; collections 34; timer fired 35 times
  period 1 ms: worker elapsed 44 ms; collections 35; timer fired 58 times
done
exit=0
```

**Observed (two runs):**

| timer period | worker elapsed | collections | timer fired |
|---|---|---|---|
| 300 ms | 10223-10240 ms | 34 | 35 |
| 1 ms | 44-92 ms (two earlier, unrecorded runs of the same program: 43 ms) | 35 | 58-92 |

E5c's baseline for this worker: 26-29 ms.

**Reading.** The binding's dispatch path alone reaches `$event` on nearly every fire; E5c's `'once` wait loop was not the cause. E5c's "3x" and T2b's "75x" are one mechanism seen through two harnesses: a raw FFI callback executes a few procedure calls per tick, chez-libuv's executes enough. Neither is a guarantee a server can rely on, and the volume of the dispatch path is not a contract. The only fix is the binding's: `uv_run` and every trampoline `__collect_safe` (chez-libuv #19, planned 2026-09-19 as Stage 1 of its threading arc).

### E5f: what the `__collect_safe` conversion costs per callback, single-threaded

chez-libuv plans to rebind `uv_run` and all 13 trampolines `__collect_safe` (#19, Stage 1). Every callback then reactivates the thread on entry and deactivates it on return, on the loop thread of a server that forks no thread at all. Raw FFI measurement: 256 `uv_idle` handles each fire once per loop iteration, so one `kevent()` poll is amortized over 256 callbacks; 5,000,000 callbacks per trial, three trials per mode, alternating plain and safe in one process.

Script: `.plans/research/spike/e5f-collect-safe-callback-cost.sps` (this repository; added 2026-09-19, evening). Chez-libuv checkout at 23fa923 (branch `spike/threading-collect-safe`; its `src/` is identical to `main` at 83e0184, `uv_run` still bound plain at native.sls:242).

Command (each run is a fresh process; the spike directory is on the library path for `(spike common)`):

```sh
cd .plans/research/spike && CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:$PWD gtimeout 180 chez --program e5f-collect-safe-callback-cost.sps
```

Source (verbatim):

```scheme
;; E5f: what chez-libuv #19's conversion costs a single-threaded program: plain vs
;; __collect_safe on uv_run and the callable, per callback. 256 uv_idle handles
;; each fire once per loop iteration, so one kevent() poll is amortized over 256
;; callbacks; 5,000,000 callbacks per trial, three trials per mode, alternating.
(import (chezscheme) (spike common))
(define lib-path (or (getenv "LIBUV_DYLIB") "/opt/homebrew/opt/libuv/lib/libuv.dylib"))
(load-shared-object lib-path)
(define UV_RUN_DEFAULT 0) (define UV_IDLE 6)
(define K 256) (define TARGET 5000000)
(define uv-run-plain   (foreign-procedure                "uv_run" (uptr int) int))
(define uv-run-safe    (foreign-procedure __collect_safe "uv_run" (uptr int) int))
(define uv-loop-size   (foreign-procedure "uv_loop_size"   () size_t))
(define uv-handle-size (foreign-procedure "uv_handle_size" (int) size_t))
(define uv-handle-get-type (foreign-procedure "uv_handle_get_type" (uptr) int))
(define uv-loop-init   (foreign-procedure "uv_loop_init"   (uptr) int))
(define uv-loop-close  (foreign-procedure "uv_loop_close"  (uptr) int))
(define uv-idle-init   (foreign-procedure "uv_idle_init"   (uptr uptr) int))
(define uv-idle-start  (foreign-procedure "uv_idle_start"  (uptr uptr) int))
(define uv-idle-stop   (foreign-procedure "uv_idle_stop"   (uptr) int))
(define uv-close       (foreign-procedure "uv_close"       (uptr uptr) void))
(define (alloc-zeroed n) (let ((p (foreign-alloc n))) (do ((i 0 (+ i 1))) ((= i n) p) (foreign-set! 'unsigned-8 p i 0))))
(define (mk-cb safe? proc) (if safe? (foreign-callable __collect_safe proc (uptr) void) (foreign-callable proc (uptr) void)))
(define (trial safe?)
  (let* ((uv-run (if safe? uv-run-safe uv-run-plain))
         (loop-ptr (alloc-zeroed (uv-loop-size)))
         (idles (let lp ((i 0) (acc '())) (if (fx= i K) acc (lp (fx+ i 1) (cons (alloc-zeroed (uv-handle-size UV_IDLE)) acc)))))
         (fires 0)
         (idle-cb (mk-cb safe? (lambda (h) (set! fires (fx+ fires 1)) (when (fx>= fires TARGET) (uv-idle-stop h)))))
         (close-cb (mk-cb safe? (lambda (h) #f))))
    (lock-object idle-cb) (lock-object close-cb)
    (uv-loop-init loop-ptr)
    (for-each (lambda (p) (uv-idle-init loop-ptr p)
                (unless (= (uv-handle-get-type p) UV_IDLE) (say "UV_IDLE constant wrong") (exit 2))
                (uv-idle-start p (foreign-callable-entry-point idle-cb))) idles)
    (let* ((t0 (real-time)) (rc (uv-run loop-ptr UV_RUN_DEFAULT)) (ms (- (real-time) t0)))
      (for-each (lambda (p) (uv-close p (foreign-callable-entry-point close-cb))) idles)
      (uv-run loop-ptr UV_RUN_DEFAULT)
      (uv-loop-close loop-ptr) (for-each foreign-free idles) (foreign-free loop-ptr)
      (unlock-object idle-cb) (unlock-object close-cb)
      (say "  " (if safe? "safe " "plain") ": " fires " callbacks in " ms " ms = " (div (* ms 1000000) fires) " ns per callback"))))
(say "per-callback cost, " K " idle handles, " TARGET " callbacks per trial")
(for-each trial '(#f #t #f #t #f #t))
(say "done")
```

Run 1 output (verbatim, `.plans/research/spike/out/e5f-collect-safe-callback-cost.run1.txt`; the last line is gtimeout's exit status):

```text
per-callback cost, 256 idle handles, 5000000 callbacks per trial
  plain: 5000255 callbacks in 963 ms = 192 ns per callback
  safe : 5000255 callbacks in 1248 ms = 249 ns per callback
  plain: 5000255 callbacks in 945 ms = 188 ns per callback
  safe : 5000255 callbacks in 1243 ms = 248 ns per callback
  plain: 5000255 callbacks in 942 ms = 188 ns per callback
  safe : 5000255 callbacks in 1224 ms = 244 ns per callback
done
exit=0
```

Run 2 output (verbatim, `.plans/research/spike/out/e5f-collect-safe-callback-cost.run2.txt`; the last line is gtimeout's exit status):

```text
per-callback cost, 256 idle handles, 5000000 callbacks per trial
  plain: 5000255 callbacks in 891 ms = 178 ns per callback
  safe : 5000255 callbacks in 1180 ms = 235 ns per callback
  plain: 5000255 callbacks in 894 ms = 178 ns per callback
  safe : 5000255 callbacks in 1180 ms = 235 ns per callback
  plain: 5000255 callbacks in 887 ms = 177 ns per callback
  safe : 5000255 callbacks in 1195 ms = 238 ns per callback
done
exit=0
```

**Observed (two runs, three trials each):**

| mode | ns per callback |
|---|---|
| plain `uv_run` and callable | 177-192 |
| `uv_run` and callable `__collect_safe` | 235-249 |

About 60 ns per callback for the reactivate/deactivate pair.

**Reading.** At three or four callbacks per request that is ~0.2 us against the parser's 1.86 us per request (judge-performance figure): a line in the performance baseline when the pin moves past chez-libuv's Stage 1, not a design input. The spike's 13 us per `uv-run 'once` turn (E3b) is unaffected in kind.

### E6: (uv-run loop 'nowait) from inside an on-data callback -- the exact refusal

Loopback TCP pair; the server's `on-data` calls `uv-run` in all three modes and `uv-loop-teardown!`.

Script: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e6-nowait-from-on-data.sps`

Command (each run is a fresh process):

```sh
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike gtimeout 30 chez --program /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/e6-nowait-from-on-data.sps
```

Source (verbatim):

```scheme
;; E6: from inside an on-data callback, call (uv-run loop 'nowait) and record
;; the exact condition chez-libuv raises.
(import (rnrs) (libuv) (spike common))
(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define peer #f)
(define result 'not-run)
(uv-listen! server 128
  (lambda (err)
    (say "server: on-connection err=" err)
    (set! peer (uv-accept! server))
    (uv-read-start! peer
      (lambda (bv start end)
        (say "server: on-data " (- end start) " bytes; calling (uv-run loop 'nowait) from inside the callback")
        (set! result
          (guard (e (#t (show-condition "on-data/uv-run" e)
                        (say "on-data/uv-run | uv-invalid-argument? " (uv-invalid-argument? e)
                             (if (uv-invalid-argument? e)
                                 (list " who=" (uv-invalid-argument-who e) " reason=" (uv-invalid-argument-reason e))
                                 ""))
                        'raised))
            (uv-run loop 'nowait)))
        (say "server: uv-run inside on-data -> " result)
        (say "server: also trying (uv-run loop 'once) and 'default from inside on-data")
        (say "server: once -> " (guarded "on-data/once" (lambda () (uv-run loop 'once))))
        (say "server: default -> " (guarded "on-data/default" (lambda () (uv-run loop 'default))))
        (say "server: and uv-loop-teardown! from inside on-data -> " (guarded "on-data/teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
        (uv-close! peer) (uv-close! server))
      (lambda () (say "server: eof"))
      (lambda (err) (say "server: on-error") (show-condition "server/on-error" err)))))
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (say "client: connected err=" err)
    (uv-write! client (string->utf8 "ping") (lambda (err) (say "client: write done err=" err) (uv-close! client)))))
(say "top: uv-run -> " (guarded "uv-run" (lambda () (uv-run loop 'default))))
(say "top: teardown -> " (guarded "teardown" (lambda () (uv-loop-teardown! loop) 'ok)))
(say "top: result = " result)
(say "top: done")
```

Run 1 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e6-nowait-from-on-data.run1.txt`; the last line is gtimeout's exit status):

```text
client: connected err=#f
client: write done err=#f
server: on-connection err=#f
server: on-data 4 bytes; calling (uv-run loop 'nowait) from inside the callback
on-data/uv-run | kinds: (&uv-invalid-argument)
on-data/uv-run | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
on-data/uv-run | uv-invalid-argument? #t( who= uv-run  reason= loop-running)
server: uv-run inside on-data -> raised
server: also trying (uv-run loop 'once) and 'default from inside on-data
on-data/once | kinds: (&uv-invalid-argument)
on-data/once | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
server: once -> raised
on-data/default | kinds: (&uv-invalid-argument)
on-data/default | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
server: default -> raised
on-data/teardown | kinds: (&uv-invalid-argument)
on-data/teardown | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-loop-teardown!
      reason: loop-running
server: and uv-loop-teardown! from inside on-data -> raised
top: uv-run -> #f
top: teardown -> ok
top: result = raised
top: done
exit=0
```

Run 2 output (verbatim, `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/e6-nowait-from-on-data.run2.txt`; the last line is gtimeout's exit status):

```text
client: connected err=#f
client: write done err=#f
server: on-connection err=#f
server: on-data 4 bytes; calling (uv-run loop 'nowait) from inside the callback
on-data/uv-run | kinds: (&uv-invalid-argument)
on-data/uv-run | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
on-data/uv-run | uv-invalid-argument? #t( who= uv-run  reason= loop-running)
server: uv-run inside on-data -> raised
server: also trying (uv-run loop 'once) and 'default from inside on-data
on-data/once | kinds: (&uv-invalid-argument)
on-data/once | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
server: once -> raised
on-data/default | kinds: (&uv-invalid-argument)
on-data/default | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-run
      reason: loop-running
server: default -> raised
on-data/teardown | kinds: (&uv-invalid-argument)
on-data/teardown | display-condition: Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-loop-teardown!
      reason: loop-running
server: and uv-loop-teardown! from inside on-data -> raised
top: uv-run -> #f
top: teardown -> ok
top: result = raised
top: done
exit=0
```

**Observed (both runs byte-identical).** The exact condition, for citation:

```text
&uv-invalid-argument   who: uv-run   reason: loop-running
```

`(uv-invalid-argument? e)` = `#t`, `(uv-invalid-argument-who e)` = `uv-run`, `(uv-invalid-argument-reason e)` = `loop-running`; the compound condition has exactly one simple condition (`kinds: (&uv-invalid-argument)`), no `&message`, no `&who` (the `who` is the condition's own field, `conditions.sls:67-70`). Identical for `'nowait`, `'once` and `'default`. `uv-loop-teardown!` from a callback raises the same type with `who: uv-loop-teardown!`. Raised synchronously at the call site inside the callback, so the callback's own `guard` catches it and the loop continues (the outer `uv-run` returned `#f` normally, teardown `ok`). Source: loop.sls:55-56 and 124-125.

## Conclusions (measured facts, scope: Chez 10.4.1 threaded tarm64osx, libuv 1.52.1 via chez-libuv v0.5.0, macOS 26.6.2 arm64)

1. **A continuation captured inside a chez-libuv callback cannot be returned through after that callback has returned.** With full `call/cc` the callback body resumes (E2a/E2b) and Chez raises `attempt to return to stale foreign context` at the moment the trampoline returns to C. With `call/1cc` the body does not even resume: Chez raises `attempt to invoke shot one-shot continuation` in the target context (recorded by `dispatch-guarded` as a pending callback error) and then the stale-context trap (E1a/E1b). In both cases the trap is a bare `&assertion` that escapes `uv-run` unwrapped, because it fires after `dispatch-guarded` has returned. The process does not crash, the loop can be run again (E2c), and teardown closes the loop.
2. **The captured continuation includes `uv-run` and the rest of the top-level program**, so invoking it re-runs the top-level code that follows `uv-run` (E1b/E2b printed the post-`uv-run` line twice; the unguarded first E1b version looped forever). Any design that stores a callback-captured continuation must never invoke it -- there is no way to make it valid.
3. **The two-level loop works and is cheap** (E3/E3b): coroutines started from top level, `await!` capturing with only Scheme frames underneath, callbacks that only enqueue wakeups, and a scheduler that alternates the ready queue with `(uv-run loop 'once)`. Timer and TCP `on-data` / write-completion wakeups through three nested Scheme frames, and a second coroutine interleaving, all worked with no continuation errors. Cost: ~30-36 ns per pure suspend/resume (1e6 cycles in 30-36 ms; `call/1cc` and `call/cc` indistinguishable), and ~13 us per cycle when each cycle includes a 0 ms timer and one `uv-run 'once` (10,000 cycles in 131-138 ms wall, 17-20 ms CPU).
4. **Engines work as handlers driven from a top-level scheduler** (E4a: 600 slices, resumed correctly after `uv-run 'once`/`'nowait`). Calling `uv-run` from inside a slice is fine when expiry happens in Scheme (E4b). **Expiry inside a callback does not stale the foreign frame** -- the callback body was sliced 200 times and then returned normally (E4c) -- but it leaves `uv_run`'s C frames suspended on the C stack, and it **clears chez-libuv's `loop-running` flag via `dynamic-wind`**, so a nested `uv-run` from the expire handler is accepted and actually re-enters libuv's `uv_run` (E4d: 200 nested runs, callbacks of another timer dispatched during them, no crash in 2/2 runs). The binding's re-entry refusal is therefore defeated by engine expiry; a design that uses engines must guarantee that no callback ever runs inside an engine slice, or re-guard `uv-run` itself.
5. **Thread hand-off through a mutex-protected queue drained by a loop-thread timer works** (E5a). **Calling `uv-write!` from another thread does not**: one call succeeded twice by luck (E5b); 2000 concurrent calls produced a hang with lost data and a gtimeout kill, `invalid memory reference` faults inside `uv-run`, and corruption of chez-libuv's registry visible at teardown (`0 is not of type #<record type registry-entry>`) across four runs (E5b2).
6. **A loop thread blocked in `uv-run` freezes collection for every other Scheme thread** because `uv_run` is bound without `__collect_safe` (native.sls:242): a worker's 27 ms allocation loop took 10.27 s with a 300 ms poll timeout and 92 ms with a 1 ms poll (E5c). Corrected 2026-09-19 (evening), E5d/E5e: **the 1 ms poll is not a workaround.** Chez services another thread's collect request only at a trap check (`$event`), and firing the collector does not shorten the 1000-tick budget; the timer helped in E5c only because chez-libuv's per-callback dispatch path spends that budget, which a bare FFI callback does not (chez-libuv's own T2b: 448 ms, no help; E5d: 0 calls per tick 439-447 ms, 300 calls 29-32 ms, 1000 calls 9-19 ms; an uncontended mutex per tick 437-438 ms). The binding must adopt `__collect_safe` (chez-libuv #19, planned as Stage 1 of its threading arc); no timer substitutes.
8. **`__collect_safe` on `uv_run` and the callables costs about 60 ns per callback single-threaded** (E5f: 177-192 ns plain vs 235-249 ns safe per `uv_idle` callback, the poll amortized over 256 handles, 5,000,000 callbacks per trial).
7. **The re-entry refusal is exact and synchronous** (E6): `&uv-invalid-argument` with `who = uv-run`, `reason = loop-running`, identical for all three run modes, raised at the call site inside the callback and catchable there; `uv-loop-teardown!` from a callback raises the same with `who = uv-loop-teardown!`.

## Files

- Scripts: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/*.sps`, helper `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/spike/common.sls`, runner `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/run.sh`
- Raw outputs: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/out/*.runN.txt` (each ends with `exit=<gtimeout status>`)
- The scratchpad paths above are where the spike was written; the same files now live in this repository under `.plans/research/spike/` (scripts, `spike/common.sls`, `run.sh`, `out/`). E5d-E5f (added 2026-09-19, evening) were written there directly: `e5d-ticker-needs-trap-ticks.sps`, `e5e-gc-stall-uvrun-default.sps`, `e5f-collect-safe-callback-cost.sps`, outputs `out/<name>.run{1,2}.txt`. The Chez 10.4.1 sources E5d cites were fetched from github.com/cisco/ChezScheme at tag v10.4.1 (c/schsig.c, c/thread.c, c/types.h, s/cmacros.ss, s/library.ss, s/prims.ss).
- Fetched documents: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/csug-foreign.html`, `csug-foreign.txt`, `libuv-loop.html`, `libuv-threading.html`, `libuv-design.html`
