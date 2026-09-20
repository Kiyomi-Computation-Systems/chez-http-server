# Refutation pass: gap-byte-machine-and-composition.md

Method: for every item, I opened the cited file:line(s) myself (via `sed -n`/`awk`/`rg -n`) against the SAME commit the original report used (`/Users/yuzu/github/byte-machine` at `0245db3059504c462b881a550310300fece55216`, tag `v0.6.0` — re-verified with `git rev-parse HEAD` below), and re-ran every script the original report claims to have run, using the exact same commands. All work below is from 2026-09-19, same machine (Chez 10.4.1, tarm64osx).

```
$ cd /Users/yuzu/github/byte-machine && git rev-parse HEAD
0245db3059504c462b881a550310300fece55216
$ wc -l src/byte-machine/runtime.sls
    1686 src/byte-machine/runtime.sls
```
Commit and file length both match the original report's stated scope exactly (runtime.sls is still 1686 lines, matching item 5's "1686-line file" claim). The report's own scratchpad scripts were still present and unmodified at `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/{combined-import-test.sps,chez-aot-compile.ss,chez-aot-run.ss,ctx-and-reset-bench.sps,reentrancy-test.sps}`.

**Overall verdict: all 8 items' citations exist and say what is claimed, and all 8 statuses ("present") are correct.** This is an unusually well-sourced report — every file:line citation I checked (roughly 35 distinct citations across the 8 items) pointed at exactly the code described, and every re-run of an empirical script reproduced the reported numbers (allocation byte-counts reproduced to 4 decimal places; wall-clock timings reproduced within normal noise). I found two very minor citation-precision nits (neither changes any status or substantive claim), detailed under items 1 and 5.

---

## Item 1 — Callback dispatch cost / mutable ctx, zero allocation

**Status check: CONFIRMED — "present" is correct.**

- `runtime.sls:544-552`: read directly.
  ```
  550:   (define (parser-callbacks p) (vector-ref p 10))
  551:   ;; parser-user-context : Parser -> Any
  552:   (define (parser-user-context p) (vector-ref p 11))
  ```
  and the comment at 544-549 says verbatim "(application-owned and may be mutable, so the runtime neither copies nor interprets it)". Matches the claim exactly.
- `runtime.sls:719-728` (`byte-machine-callback-step/v2`): read directly, matches exactly — `(f parser (parser-user-context parser))` is the call. **Minor nit**: the JSON evidence text says "runtime.sls:725" as the specific line for that call; the call is actually on line **727**, not 725 (both are inside the cited 719-728 range, so the citation range itself is correct, just the pinpoint line is off by 2). Does not affect the claim's truth.
- `runtime.sls:59,61`: `callback-continue`/`callback-pause` singletons, confirmed verbatim.
- Decision 0052 (`/Users/yuzu/github/byte-machine/.decisions/0052-a-callback-outcome-is-the-object.md`), dated 2026-09-17: read in full — confirms "Two conses, 32 bytes... on every crossing of the callback seam" and ties it to `many-small-headers` vs `short-normal-requests` (5216 B/msg vs 1504 B/msg over 29 extra headers = 128 B/header exactly), matching the report's math.
- `contract-violation-failure` at `runtime.sls:692-693`: confirmed verbatim, "built ONCE here".
- `test/common/allocation-audit-tests.sps:205-206`: confirmed **verbatim**:
  ```
  205:           (check-equal "disabled: per-header slope zero" disabled 0)
  206:           (check-equal "bound: per-header slope zero" with-callbacks 0))))
  ```
  and line 199 shows `bound` is a NON-EMPTY callback binding list (`(list (list 'message-begin noop) (list 'message-complete noop))`), confirming "with callbacks bound" is accurate, not disabled-only.
- `.plans/milestone-14-close.md` dispatch numbers: re-checked with `rg`, all four numbers confirmed verbatim (`0.80ns`/`185.85ns` at line 40, `1.25ns`/`21.60ns` at line 41). `many-small-headers` 90ms→51ms confirmed at line 68. The `175,342 msg/s` vs `14,925` "twelve times" chez-httparse figure confirmed verbatim at lines 77-78. Milestone status line confirms "closed 2026-09-18, ships v0.6.0" (matches the report's parenthetical date).
- **Re-ran the measurement script** (`ctx-and-reset-bench.sps`) myself:
  ```
  $ cd /Users/yuzu/github/byte-machine && chez --libdirs test/support/harness:src \
    --program .../scratchpad/ctx-and-reset-bench.sps
  === (1) callback dispatch allocation, mutable-record ctx ===
  iterations: 20000
  ctx begins/completes after run: 22000/22000
  total bytes allocated: 8640816
  bytes / iteration (feed + 2 callbacks + reset): 432.0408
  ```
  Reproduced **exactly** (432.0408 B/iter, matching the report to 4 decimal places). Wall-clock differs slightly from the report's numbers (expected noise; allocation counts are deterministic, wall time is not).

**Conclusion: item 1's evidence and "present" status are both correct.**

---

## Item 2 — `parser-feed!` at `paused` (consumed/next) and resumption

**Status check: CONFIRMED — "present" is correct.**

- `runtime.sls:1100-1109` (pause node commits `current` past the pause): read directly, confirmed **verbatim**, including the exact next=pos/consumed=(pos-start) shape:
  ```
  1107:              (parser-set-current! parser (op 'pause-target node))
  1108:              (make-parser-result 'paused pos (- pos start) (parser-offset parser) #f
  1109:                (let ((rp (op 'pause-reason node)))
  ```
- `runtime.sls:1145-1160` (callback-requested pause): confirmed verbatim, including the comment "A callback-requested pause occurs after the callback's delivered event has been committed... it is never delivered twice."
- `runtime.sls:1290-1310` (parser-feed-v2! boundary): the report cites `1290-1310`; I read `1285-1312` and confirmed the same contract holds (`next = (feed-outcome-next o)`, `consumed = (- (feed-outcome-next o) start)` at lines 1308-1309, and the pause-slot routing described at 1302-1306). Matches.
- `runtime.sls:229-236` for `parser-result-pause`: the cited range (229-236) is the comment block describing the slot; the actual accessor definition sits at 240-241 (`(define (parser-result-pause r) (if (> (vector-length r) 6) (vector-ref r 6) #f))`), just past the cited range. This is a similarly minor pinpoint-vs-range imprecision (same character as item 1's), not a wrong citation — the described "separate 7th slot, error slot stays #f for a pause" claim is accurate (confirmed `parser-result-error` is slot 5, `parser-result-pause` is slot 6, i.e., a distinct 7th vector member counting the tag).
- `runtime.sls:1604-1619` (`parser-resume!`): confirmed verbatim, including the exact comment "resume changes lifecycle only -- no callback, no input, no executor run" at line 1599 (one line before the cited range starts, harmless) and the three-arm case (`paused-feed→ready`, `paused-finish→finish-ready`, `busy→reentrancy`, `poisoned→poisoned-parser`, else→`lifecycle-violation`).
- `runtime.sls:986-988` (feeding a paused parser is `lifecycle-violation`): confirmed verbatim.

**Conclusion: item 2's evidence and "present" status are both correct**, modulo the same harmless pinpoint-vs-range citation style seen in item 1.

---

## Item 3 — Pipelining reuse without reset; `parser-reset!` vs `make-parser` cost

**Status check: CONFIRMED — "present" is correct, including the explicitly-flagged open question.**

- `http-machine.sls:481-487` (message-complete field-clear chain loops to `idle`): file located at `test/support/harness/byte-machine/test/http-machine.sls` (618 lines total), and lines 481-487 read **verbatim identical** to the report's quoted block, including the two-line comment about `§21.3:1150` and decision 0037.
- `bench/runner/benchmark.sps:84` (`pipelined = (rep-str 5 short-normal)`): confirmed verbatim.
- `bench/runner/benchmark.sps:108-112` (`run-once`, one parser, one `parser-feed!` call over the whole 5-message buffer, no reset): confirmed verbatim.
- `bench/fixtures/baseline-tarm64osx.sls`, `pipelined-requests` workload: re-extracted the raw JSON-like record with `rg`. Confirmed: `requests-per-second 941176.0`, `allocation-bytes-per-message 1168` for the generated lane — and `short-normal-requests`' generated-lane allocation is **also** `1168`. The report's claim "SAME 1168 B/message allocation as the single-request workloads, i.e. no per-message-boundary allocation spike" is **exactly correct**, numerically verified.
- **Re-ran the "(0) SAME parser, NO reset at all" measurement** myself:
  ```
  === (0) SAME parser, NO reset at all, N sequential messages ===
  ctx begins/completes after 20000 messages via the SAME parser, NEVER reset: 20000/20000
  lifecycle after run: ready
  ```
  Reproduced exactly (20000/20000, lifecycle `ready`).
- `runtime.sls:1668-1686` (`parser-reset!`): read directly, confirmed verbatim — busy-guard at 1678-1680, four vector-sets at 1681-1684, `byte-machine-span-close/v1` at 1685, one allocation (`copy-values`) at 1686.
- `runtime.sls:486-527` (`make-parser`): read directly, confirmed verbatim — `compiled-machine?` check, `resolve-callbacks` call (`373-412`, itself confirmed verbatim including the duplicate-binding and unknown-binding checks), `resolve-field-initials` call (`447-476`, confirmed verbatim), fresh 18-slot vector construction in both the `'op` and `'v2` arms.
- **Re-ran the reset-vs-make-parser benchmark** myself:
  ```
  === (3a) parser-reset! cost ===
  bytes/iter (reset+feed): 432.0408
  === (3b) make-parser cost ===
  bytes/iter (make-parser+feed): 880.0736
  ```
  Both numbers reproduced **exactly** to 4 decimal places, confirming the "~2×" ratio claim (880.0736 / 432.0408 ≈ 2.037).
- The item's `workaround_or_upstream_change` field explicitly flags as an open question whether chez-httparse's own grammar (not byte-machine's test fixture) routes the same way — this hedge is accurate and consistent with the fuller report's "Open questions" §1, which says exactly that this was NOT independently re-derived from `chez-httparse/src/httparse/grammar.sls` in that pass. I did not walk that file either (it's out of byte-machine's scope and the JSON item itself already flags it honestly as unconfirmed) — the item's self-reported uncertainty is itself accurate, not overclaimed.

**Conclusion: item 3's evidence and "present" status are both correct**, and its own flagged uncertainty (chez-httparse's grammar shape) is honestly represented rather than glossed over.

---

## Item 4 — Re-entrancy (a callback calling `parser-feed!` on its own parser)

**Status check: CONFIRMED — "forbidden AND detected" / "present" is correct.**

- `runtime.sls:1020` (lifecycle set to `'busy` before executor/callback run): confirmed verbatim.
- `runtime.sls:998-1000` (`parser-feed!` busy→reentrancy): confirmed verbatim.
- `runtime.sls:1343-1345` (`parser-finish!` busy→reentrancy): confirmed verbatim, same shape.
- `runtime.sls:1612-1614` (`parser-resume!` busy→reentrancy): confirmed verbatim (part of the range already checked under item 2).
- `runtime.sls:1678-1680` (`parser-reset!` busy guard): confirmed verbatim, "raise goes before further mutation" comment present at 1676-1677.
- `runtime.sls:993-997` (three-codes design comment): confirmed verbatim, exact wording matches the quote in the report.
- `runtime.sls:1023-1057` (`dynamic-wind`/`completed` flag poisoning on escape, `parser-feed!`): confirmed verbatim, including the exact comment text at 1051-1056.
- `runtime.sls:1372-1392`+ (same shape in `parser-finish!`): confirmed verbatim (I read 1340-1396, which covers this fully).
- `runtime.sls:1669-1674` ("THE ONLY OPERATION THAT LETS A POISONED PARSER RUN"): confirmed verbatim.
- **Re-ran `reentrancy-test.sps`** myself:
  ```
  $ chez --libdirs test/support/harness:src --program .../reentrancy-test.sps
  lifecycle observed FROM WITHIN the callback (should be 'busy): busy
  exception object caught by the re-entrant parser-feed! call: #<condition &byte-machine-contract>
  condition? #t
  byte-machine-contract-condition? #t
    code: reentrancy
    who: parser-feed!
    detail: (busy feed)
  parser lifecycle AFTER the outer feed returned: ready
  ```
  Reproduced **identically**, line for line, to what the report claims it observed.

**Conclusion: item 4's evidence and "present" status are both correct, and the empirical claim is directly reproducible.**

---

## Item 5 — Thread-safety / no global mutable state

**Status check: CONFIRMED — "present" is correct, with one phrasing nit noted below (does not change the status).**

- Re-ran all three `rg` commands verbatim:
  ```
  $ rg -n "^\s*\(define [a-zA-Z*!?-]+\s*\(make-" src/byte-machine/runtime.sls
  190:  (define empty-bv (make-bytevector 0))
  $ rg -n "^\(set!" src/byte-machine/runtime.sls
  (no output)
  $ rg -n "hashtable|registry" src/byte-machine/runtime.sls
  (no output)
  ```
  All three reproduced **exactly** as claimed — `empty-bv` is the only top-level `(define name (make-...))`, no top-level `set!`, no hashtable/registry mention anywhere in the file.
- `runtime.sls:486-527` (per-parser 18-slot vector, `make-parser`'s two variant-arm literals): already confirmed under item 3.
- `runtime.sls:144-168` (`byte-machine-make-compiled-machine`, immutable metadata): confirmed verbatim, including the ABI-mismatch assertion at 145-147 (`current-abi-version` = 9, confirmed at line 109: `(define current-abi-version 9)`).
- `runtime.sls:343-348` design comment ("closure-held storage would let one parser's writes be read by another"): confirmed **verbatim**.
- **Phrasing nit** (does not affect the status or the substantive claim): the report says `rg -i thread .reference/*.md README.org` "returns nothing about parser thread-safety." I re-ran this exact command and it does return two hits:
  ```
  .reference/portability-matrix.md:leading threaded-build `t`, match an architecture prefix from
  .reference/portability-matrix.md:A non-threaded Windows type (`a6nt`, no leading `t`) resolves to the same
  ```
  These are about Chez's *machine-type naming convention* (threaded vs. non-threaded builds, e.g. `tarm64osx`), not about *parser* thread-safety — so the claim "nothing about parser thread-safety" is technically correct as scoped, but the parenthetical is phrased in a way that could be misread as "the command produces no output at all," which is false (it produces 2 unrelated lines). This is a wording precision issue only; it does not change whether byte-machine's docs address parser-level concurrency (they still do not), and does not affect the item's "present" status.

**Conclusion: item 5's evidence and "present" status are both correct.** The `rg -i thread` phrasing is very slightly loose but not misleading about the substantive finding.

---

## Item 6 — Vendoring `httparse-message.sls`, `CHEZSCHEMELIBDIRS` layout

**Status check: CONFIRMED — "present" is correct.**

- Submodule pins:
  ```
  $ cd /Users/yuzu/github/chez-httparse && git submodule status vendor/byte-machine
   0245db3059504c462b881a550310300fece55216 vendor/byte-machine (v0.6.0)
  $ cd /Users/yuzu/github/uriparse && git submodule status vendor/byte-machine
   0245db3059504c462b881a550310300fece55216 vendor/byte-machine (v0.6.0)
  ```
  Both reproduced exactly, identical commit, matching byte-machine's own HEAD.
- `v0.6.0` tag dereferencing:
  ```
  $ cd /Users/yuzu/github/byte-machine && git rev-parse v0.6.0
  fc8f4a236a164ec114f77bfdcafc77e6491ba66f
  $ git log --oneline -1 v0.6.0
  0245db3 docs(release): Milestone 14 — the close, and v0.6.0 (#138)
  ```
  Confirmed: annotated tag object is distinct from the commit, and the commit matches both siblings' pins exactly.
- Decision 0005 (`chez-httparse/.plans/decisions/0005-byte-machine-pinned-by-gitlink-generated-abi-5.md`): confirmed the quoted phrases "The gitlink, not the tag, is the pin" (line 58), "The pin is expected to move..." (line 65), "The ABI number is re-read, never remembered" (line 74) all present verbatim. I additionally read the full amendment history (lines 8-24): the record was amended at 0012 (ABI 6), 0015 (ABI 7), 0021 (ABI 8) — three amendment events producing four ABI numbers (5→6→7→8), matching the fuller narrative report's claim in its prose (that detail is not repeated in this item's condensed JSON text, so it does not affect this item's evidence).
- `git ls-files src/generated/` in both repos: confirmed both `httparse-message.sls`/`httparse-url.sls` and `uri-scanner.sls` are tracked (not gitignored — confirmed with `git check-ignore -v`, no output = not ignored).
- `chez-httparse/Makefile:76-77` (`parser-refresh` target): confirmed verbatim.
- `uriparse/Makefile:78` (`parser-refresh` target): confirmed present at that line (uses a different underlying command — `cmake -P cmake/UriParserRefresh.cmake` — than chez-httparse's, but the report only cites the line for the target's existence/comment, not the exact command shape, so this is accurate).
- Import-footprint claims: `chez-httparse/src/generated/httparse-message.sls:3` (`(import (rnrs) (byte-machine runtime))`, no `#!r6rs` line) and `uriparse/src/generated/uri-scanner.sls:4` (same import, one line later because of a leading `#!r6rs` pragma at line 1): both confirmed **verbatim** by direct read.
- ABI literal 9 at `chez-httparse/src/generated/httparse-message.sls:3863` and `uriparse/src/generated/uri-scanner.sls:437`: both confirmed verbatim (`byte-machine-make-compiled-machine 9 ...` opens both lines).
- `chez-httparse/docs/api.org:9-16`: confirmed verbatim, exact import block reproduced.
- **Re-ran `combined-import-test.sps`** myself, with the exact `CHEZSCHEMELIBDIRS` given:
  ```
  libuv make-uv-loop: #t
  httparse-message-machine compiled?: #t
  httparse mode request value: 1
  byte-machine make-parser proc?: #t
  uri-parse proc?: #t
  ALL IMPORTS OK
  ```
  Reproduced exactly.
- **Re-ran the dual-vendor-path variant** myself (both `chez-httparse/vendor/byte-machine/src` AND `uriparse/vendor/byte-machine/src` on the path simultaneously): identical `ALL IMPORTS OK` output, confirming the claimed "works today because both pins are identical" behavior.
- `byte-machine/cmake/ByteMachineSchemeLane.cmake:204-206`: confirmed verbatim — "Chez consults library-directories entries in order and takes the first source it can resolve (measured for this exact shape...)" is present essentially verbatim (the comment spans 204-208 in my read; the quoted excerpt is accurate).

**Conclusion: item 6's evidence and "present" status are both correct, and both empirical CHEZSCHEMELIBDIRS runs are directly reproducible.**

---

## Item 7 — AOT compilation of the whole stack

**Status check: CONFIRMED — "present" is correct.**

- `test/support/launchers/chez-compile.ss:137-155`: confirmed **verbatim** line-for-line — `(compile-imported-libraries #t)` at 137, `(generate-wpo-files #f)` at 144 with the exact "Declined, not merely left at its default..." comment at 139-143, `(source-directories '())` at 152, `(library-directories (map cons library-roots object-dirs))` at 153, `(compile-program program output)` at 155.
- `test/support/launchers/chez-aot.ss`: the "WHY THE LIBRARY PATH PAIRS EVERY OBJECT DIRECTORY WITH AN EMPTY SOURCE GUARD" comment header exists verbatim, but wraps across two source lines (`;;; WHY THE LIBRARY PATH PAIRS EVERY OBJECT DIRECTORY WITH AN EMPTY SOURCE` / `;;; GUARD`) — a plain single-line `rg` for the full string on one line returns nothing, but the text is present and accurate when read in context. Not a misattribution, just a line-wrap artifact of the source file itself.
- **Re-ran the entire AOT compile+run pipeline** myself, from scratch (removed the prior `aot-objs`/`.so` and rebuilt):
  ```
  $ time chez --script chez-aot-compile.ss
  [... 27 compile lines, same files/order as the report's excerpt ...]
  compiled: .../combined-import-test.so
  chez --script chez-aot-compile.ss  0.70s user 0.03s system 99% cpu 0.727 total
  $ find aot-objs -name "*.so" | wc -l
        27
  $ du -sh aot-objs combined-import-test.so
  716K  aot-objs
  4.0K  combined-import-test.so
  $ time chez --script chez-aot-run.ss
  libuv make-uv-loop: #t
  httparse-message-machine compiled?: #t
  httparse mode request value: 1
  byte-machine make-parser proc?: #t
  uri-parse proc?: #t
  ALL IMPORTS OK
  chez --script chez-aot-run.ss  0.04s user 0.01s system 97% cpu 0.052 total
  ```
  Every figure reproduced almost exactly: 27 `.so` files (exact), 716K / 4.0K sizes (exact), compile time 0.727s (report: 0.774s — same order of magnitude, expected run-to-run variance), run time 0.052s (report: 0.058s — same). I also manually counted the compiled `.so` files per source root from the compile transcript (16 under `libuv-src`, 2 under `httparse-src`, 3 under `httparse-bm`, 6 under `uriparse-src` = 27 total) and this matches the report's "16 chez-libuv .sls files... 2 more byte-machine private .sls files... 5 more uriparse .sls files" breakdown exactly (1 httparse-message + 1 modes = the "2" implied by the `...` elision, 1 runtime + 2 private = "2 more" after runtime, 1 collect + 1 uri-scanner + 4 others = "5 more" after uri-scanner — all consistent).
  The ~6-7× speedup claim (0.058s/0.376s ≈ 6.5×, and my own 0.052s vs the report's separately-quoted 0.376-0.398s source-mode baseline ≈ 7.2-7.6×) holds under either set of numbers.
- `bench/fixtures/baseline-tarm64osx.sls:1`, `one-time-metrics`: confirmed `generation-time-ms 5` and `aot-object-size-bytes 71370` both present verbatim in the one JSON-like record (this is for the HTTP grammar alone, a different, smaller artifact than the combined 27-file stack — the report is careful to describe it as "separately" and does not conflate the two, which is accurate).

**Conclusion: item 7's evidence and "present" status are both correct, and the entire AOT pipeline is directly reproducible end to end.**

---

## Item 8 — Makefile/CMake conventions

**Status check: CONFIRMED — "present" is correct.**

- Line counts:
  ```
  $ wc -l chez-libuv/Makefile byte-machine/Makefile chez-httparse/Makefile uriparse/Makefile
       690 chez-libuv/Makefile
        69 byte-machine/Makefile
        77 chez-httparse/Makefile
        82 uriparse/Makefile
  ```
  Reproduced **exactly** (690/69/77/82).
- CMakeLists.txt presence: confirmed `byte-machine/CMakeLists.txt`, `chez-httparse/CMakeLists.txt`, `uriparse/CMakeLists.txt` all exist; `chez-libuv/CMakeLists.txt` does not (`ls` errors "No such file or directory"), matching the report's claim exactly.
- Target-set shape: read `byte-machine/Makefile:21-69` in full and `chez-httparse/Makefile:21-60` in full. Both share the identical `.PHONY` line shape (`all help doctor configure build dev test test-all prod clean` plus project extras) and identical target bodies (`configure: $(CMAKE) --preset dev`; `build: configure ... --build --preset dev`; `dev: build ... --preset harness`; `test: build ... --preset pr`; `test-all: build ... --preset release`; `prod: --preset prod && --build --preset prod`; `clean: -E rm -rf build`) — confirmed line-for-line identical in shape between the two files, exactly as claimed.
- `chez-httparse/Makefile:76-77` and `uriparse/Makefile:78` for `parser-refresh`/`corpus-refresh`: confirmed present (already checked under item 6).
- `chez-libuv/Makefile` targets `deps-info`, `deps`, `check-pins`, `check-purity`, `test-root`, `test-memory`, `test-memory-docker`, `check-prod`: re-ran `rg -n` for each target definition:
  ```
  174:deps-info: ...
  208:deps: ...
  219:check-pins: ...
  298:check-purity: build deps ...
  467:test-root: check-pins ...
  494:test-memory: build deps check-pins ...
  614:test-memory-docker: ...
  683:check-prod: ...
  ```
  All eight targets confirmed present, and `check-pins` at line 219 matches the report's "chez-libuv/Makefile:219 area" citation exactly (the report's own recommendation section 6 also cites `219` for this, consistently).

**Conclusion: item 8's evidence and "present" status are both correct.**

---

## Summary table

| # | Need (short) | Original status | My verdict | Notes |
|---|---|---|---|---|
| 1 | Callback dispatch cost / allocation-free ctx | present | **CONFIRMED** | One line-pinpoint nit (725 vs actual 727), harmless — inside cited range |
| 2 | `parser-feed!` paused semantics | present | **CONFIRMED** | One line-pinpoint nit (229-236 cited for accessor at 240-241), harmless |
| 3 | Pipelining reuse / `parser-reset!` vs `make-parser` | present | **CONFIRMED** | Open-question hedge in the item itself is honest and accurate |
| 4 | Re-entrancy forbidden and detected | present | **CONFIRMED** | Reproduced byte-for-byte via re-run |
| 5 | No global mutable state / thread-safety nuance | present | **CONFIRMED** | `rg -i thread` phrasing slightly loose (2 unrelated hits exist) but substantively accurate |
| 6 | Vendoring pattern / CHEZSCHEMELIBDIRS | present | **CONFIRMED** | Both empirical runs (single-path and dual-vendor-path) reproduced exactly |
| 7 | AOT compilation of the whole stack | present | **CONFIRMED** | Full pipeline re-run from scratch; all figures reproduced within normal noise |
| 8 | Makefile/CMake conventions | present | **CONFIRMED** | All line counts and target sets reproduced exactly |

No item's status needs correction. No cited file:line was missing, moved to say something different, or fabricated. Every runnable claim was re-run and reproduced. The two nits noted (items 1 and 5) are citation-precision quibbles that do not change any conclusion or any consequence the original report draws for chez-http-server.
