# Verify existence/license — batch 13 (SKEPTIC pass)

Task: for each candidate, confirm the repository and named corpus paths exist TODAY, confirm the SPDX license, and judge BSD-3-Clause vendoring compatibility of the TEST DATA (not code). Default refuted=true if existence cannot be confirmed.

Note on method: the candidate's `url` is `file:///Users/yuzu/github/protium`, a **local filesystem path**, not a web resource — WebFetch does not apply. I verified it with direct filesystem inspection (`ls`, `find`, `cat`, `diff`, `rg`, `git log`) via the Bash tool instead, which is the correct and only way to confirm a `file://` URL's contents.

---

## Candidate: `protium-local-plans` — protium (local abandoned Chez+Gambit libuv attempt)

Claimed: `url = file:///Users/yuzu/github/protium`, `license = BSD-3-Clause`, tier 3, 0 HTTP test cases, 8 corpus_paths (markdown plans/ADRs + two empty `.gitkeep` dirs).

### 1. Repository existence

```
$ ls -la /Users/yuzu/github/protium/
total 128
drwxr-xr-x  26 yuzu  staff   832 Aug 21 19:10 .
...
-rw-r--r--   1 yuzu  staff  1517 Aug 15 08:24 LICENSE
...
drwxr-xr-x   7 yuzu  staff   224 Aug 17 19:04 docs
...
drwxr-xr-x@ 11 yuzu  staff   352 Aug 19 05:49 tests
```
`test -d /Users/yuzu/github/protium` → `DIR EXISTS`.

CONFIRMED: the repository exists on this machine today (2026-09-19).

`git log` inside it shows real commit history, most recent 2026-08-17:
```
486c2fc 2026-08-17 docs: record two rules M0-W3a paid for
256ccec 2026-08-17 feat: hand the Scheme side a shim it can prove it loaded (#4)
9fe1d7e 2026-08-16 feat: give the shim a native test layer, and close M0-W3
02af3d5 2026-08-16 fix: repair eight review findings, four of them latent on other platforms
bd71d3d 2026-08-16 feat: build the shim, and make its export surface falsifiable
```
This is consistent with "abandoned" (no commits since 2026-08-17, work stopped at an early milestone despite substantial native/CMake/test-harness code) and consistent with "replaced by chez-libuv" (chez-libuv has its own separate, more recent history per the task brief).

### 2. License

```
$ cat /Users/yuzu/github/protium/LICENSE
BSD 3-Clause License

Copyright (c) 2026, Kiyomi Computation Systems LLC
...
```//
Standard 3-clause BSD text (attribution + no-endorsement clauses, no additional restrictions). CONFIRMED: SPDX `BSD-3-Clause`, matching the candidate's claim exactly. No SPDX header conflicts found elsewhere (no separate LICENSE-EXCEPTION, no dual-license notice observed at the repo root).

### 3. Corpus paths — all 8 checked individually

```
OK   docs/plans/protium-project-plan.md (77226 bytes)
OK   docs/plans/protium-test-harness.md (43473 bytes)
OK   docs/plans/decisions/0003-loop-owner-thread-model.md (3269 bytes)
OK   docs/plans/decisions/0004-buffer-ownership-and-copying.md (2365 bytes)
OK   docs/plans/chez-http-server-architecture.md (18715 bytes)
OK   AGENTS.md (2871 bytes)
OK   tests/integration/.gitkeep (0 bytes)
OK   tests/lifetime/.gitkeep (0 bytes)
```
All 8 named paths exist today, exactly as listed. `tests/integration/.gitkeep` and `tests/lifetime/.gitkeep` are both literally 0 bytes, confirming the claim `approx_cases: "0 HTTP test cases (tests/integration and tests/lifetime are empty .gitkeep)"`. `find tests/` shows both directories contain nothing but the `.gitkeep` placeholder (no other files under `tests/integration/` or `tests/lifetime/`).

### 4. Spot-check of substantive claims in the finder's write-up

**a. "downstream HTTP acceptance checkpoint definition ... at project-plan lines 91-109"**
`sed -n '85,115p' docs/plans/protium-project-plan.md` shows section "### 2.4 Downstream HTTP relationship" beginning at line 91, containing:
> "the installed candidate must accept a loopback HTTP/1 request, exercise read pause/resume, send a vectored response, gracefully shut down, and explicitly close using only the supported Protium API."

This is the loopback/read-pause-resume/vectored-write/graceful-shutdown/explicit-close checklist the candidate describes, at essentially the claimed line range. CONFIRMED (line numbers accurate to within a line or two of the section body).

**b. "backpressure policy left to the consumer (section 14, lines 1033-1045)"**
```
$ grep -n "^## 14" docs/plans/protium-project-plan.md
1031:## 14. Backpressure and memory policy
```
Body (lines 1033 onward): "Protium exposes the native queued-write byte count but does not choose an HTTP server's high- and low-water marks. The downstream consumer pauses reads and resumes them according to its own policy." ... "documents that a consumer must bound its own accepted pending work." CONFIRMED, section number and line range accurate.

**c. "harness rules ... (test-harness lines 24-52)"**
`sed -n '20,55p' docs/plans/protium-test-harness.md` shows "## 2. Accepted harness decisions" with numbered rules 1–10 covering: fresh process per group (rule 4), two time bounds per async test (rule 5), deterministic/replayable seeds (rule 6), port 0 (rule 10), and (elsewhere in the same doc, rule 9) "Required tests do not use retry-until-pass...". CONFIRMED — matches "fresh process per group, two time bounds per async test, deterministic seeds, port 0, no retry-until-pass" claim.

**d. Verification discipline / AGENTS.md**
Full text read. Contains an explicit "## Verification" section: "Prove a check by what it refuses, not by what it accepts... Comments are claims, not facts... A verification step is itself a check, and can be unable to do what it claims." This matches "verification discipline (AGENTS.md)" and is consistent with — though written independently of — the target repo's own AGENTS.md TDD/mutation-discipline house rules mentioned in the task brief.

**e. "Its chez-http-server-architecture.md is byte-identical to ours except a 4-line status banner."**
```
$ diff /Users/yuzu/github/protium/docs/plans/chez-http-server-architecture.md \
       /Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md
2,5d1
<
< > Status: Background design writeup for the downstream web-server project. The
< > [Protium project plan](protium-project-plan.md) is authoritative for the
< > libuv-binding scope, decisions, sequencing, and release criteria.
698c694
<  ^
---
>  ^ 
```
PARTIALLY CONFIRMED, with one small inaccuracy noted for the record: the two files differ by (1) a 4-line status-banner block, exactly as claimed, AND (2) one incidental trailing-whitespace difference at line 698 (`" ^"` vs `" ^ "` — a single trailing space inside what looks like an ASCII-art diagram). This second diff is trivial (whitespace-only, non-substantive) and doesn't affect the finder's underlying point that the two documents are the same design writeup, but "byte-identical ... except a 4-line status banner" is not literally 100% precise — it is off by one trailing space on one line. This is a minor imprecision, not a materially wrong claim, and does not change the license/existence verdict.

**f. "rg -il http over the tree (excluding build/vendor/.akku) matched only plan documents, CHANGELOG, CMakeLists, Akku.lock and the libuv tarball spec; no HTTP code or tests were ever written."**
```
$ rg -il 'http' --glob '!build/**' --glob '!vendor/**' --glob '!.akku/**' .
./Akku.lock
./CHANGELOG.md
./CMakeLists.txt
./docs/plans/protium-test-harness.md
./docs/plans/decisions/0005-libuv-build-linkage-and-distribution.md
./docs/plans/chez-gambit-libuv-portability.md
./docs/plans/chez-http-server-architecture.md
./docs/plans/protium-project-plan.md
./docs/plans/decisions/0001-portable-public-api-and-backend-isolation.md
./docs/plans/work-items/0001-m0-repository-skeleton.md
./tests/support/cmake/ProtiumLibuvSpec.cmake
```
`tests/support/cmake/ProtiumLibuvSpec.cmake` matches only because it references `https://dist.libuv.org/dist/v1.52.1/libuv-v1.52.1.tar.gz` (the pinned libuv tarball URL) and a couple of `https://example.invalid/libuv.tar.gz` placeholders used in negative-path CMake tests — i.e., this genuinely is "the libuv tarball spec" the finder meant (a CMake spec file governing how the libuv tarball's URL/checksum is validated), just not spelled out by that exact filename in the summary. A targeted search restricted to actual source/test extensions confirms no HTTP implementation or test code exists:
```
$ rg -il 'http' --glob '!build/**' --glob '!vendor/**' --glob '!.akku/**' -g '*.scm' -g '*.sps' -g '*.sls' -g '*.c' -g '*.h' .
(no output)
```
CONFIRMED: no `.scm`/`.sps`/`.sls`/`.c`/`.h` file in protium mentions "http" — no HTTP code or tests were ever written, matching the claim exactly.

### 5. License-compatibility judgment (BSD-3-Clause vendoring)

protium's LICENSE is a standard, unmodified BSD-3-Clause (attribution + non-endorsement, no copyleft, no field-of-use restriction, no patent grant complications observed). Vendoring or referencing BSD-3-Clause material — code, docs, or test fixtures — into another BSD-3-Clause project (chez-http-server) is fully license-compatible: both licenses are permissive and require only that copyright/license notices be retained on redistributed portions. There is no copyleft concern here (contrast with, e.g., GPL/AGPL corpora that would need to stay "reference-only").

However, per the candidate's own honest characterization and confirmed above: **there is no actual test corpus to vendor**. `tests/integration/` and `tests/lifetime/` — the only two paths that could plausibly hold HTTP acceptance-test data — are empty except for `.gitkeep` placeholders (0 bytes each), and a targeted `rg` confirms zero HTTP-related source or test files anywhere in the tree. The 8 "corpus_paths" are markdown design/decision documents and an empty test-directory placeholder, not test fixtures/data. The candidate's own `format` field ("markdown plans and ADRs; harness self-tests and native shim tests only") and `adaptability` field ("No corpus to vendor. Carry the harness rules...") already say this plainly — this is process/design reference material, appropriately scored at the lowest tier (3), not an HTTP test-data corpus. That self-assessment is accurate and is not refuted by anything found here.

### Verdict

NOT REFUTED. Repository exists today at the given local path; all 8 named corpus paths exist with the stated content; license is confirmed BSD-3-Clause (SPDX-compatible with vendoring, moot here since there is no data corpus, only reference documents); every specific factual claim spot-checked (section/line citations, empty test dirs, verification-discipline text, near-identical architecture doc, absence of any HTTP code) checked out, with one trivial imprecision noted (the architecture-doc diff has one incidental trailing-whitespace line beyond the claimed 4-line status banner — does not change the substance of the claim or the tier-3 verdict).

No corrections needed to url / license / paths / tier.
