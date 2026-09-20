# Skeptic verification — batch 13 (relevance & adaptability lens)

Task: verify corpus candidate(s) found by another agent, trying to refute each
on relevance (HTTP/1.x server-side / connection-semantics material vs.
parser-only / client-only / HTTP/2-only) and adaptability (can it become
replayable byte streams / scripted sessions?), with effort estimate.

Batch contains exactly one candidate: `protium-local-plans`.

All checks below were run directly against the local filesystem
(`/Users/yuzu/github/protium`, `/Users/yuzu/github/chez-http-server`) on
2026-09-19, in this session.

## Candidate: protium-local-plans

Finder's claim, in short: this is a local, abandoned Chez+Gambit libuv
reimplementation attempt. It has **zero** HTTP test cases (the
`tests/integration/` and `tests/lifetime/` directories are empty
`.gitkeep` placeholders). Its value, if any, is as planning/process
reference (harness design rules, an HTTP acceptance-checkpoint definition,
backpressure policy language) to inform our own test suite design, not as a
corpus to vendor bytes from. Finder rated it tier 3 (lowest).

### 1. Directory structure / "0 HTTP test cases" claim

```
$ find /Users/yuzu/github/protium -type d -not -path '*/.git*' -not -path '*/.akku*' -not -path '*/build*' -not -path '*/vendor*' | sort
```
Shows `tests/{contract,distribution,feasibility,fixtures,integration,lifetime,
native,support}`. Listing `tests/integration` and `tests/lifetime` in full:

```
$ ls -la /Users/yuzu/github/protium/tests/integration/ /Users/yuzu/github/protium/tests/lifetime/
tests/integration/:
total 0
drwxr-xr-x@  3 yuzu  staff   96 Aug 15 13:34 .
drwxr-xr-x@ 11 yuzu  staff  352 Aug 19 05:49 ..
-rw-r--r--@  1 yuzu  staff    0 Aug 15 13:34 .gitkeep

tests/lifetime/:
total 0
drwxr-xr-x@  3 yuzu  staff   96 Aug 15 13:34 .
drwxr-xr-x@ 11 yuzu  staff  352 Aug 19 05:49 ..
-rw-r--r--@  1 yuzu  staff    0 Aug 15 13:34 .gitkeep
```

Both `.gitkeep` files are 0 bytes. **Confirmed**: no HTTP integration/lifetime
tests exist. `tests/feasibility/*` (the only populated test lane besides
native/contract) contains shim-loader/ABI smoke tests
(`shim-smoke.chez.sps`, `out-of-order.*`, `failing-shim-lane.*`) — these
exercise the native FFI handshake, not HTTP. Read in full:
`/Users/yuzu/github/protium/tests/feasibility/shim-smoke.chez.sps` — it
imports `(protium harness)` / `(protium shim-adapter)` and reports
fingerprints; no socket or byte-stream content of any kind.

### 2. "rg -il http … matched only plan documents / CHANGELOG / CMakeLists / Akku.lock / libuv tarball spec; no HTTP code or tests" claim

```
$ cd /Users/yuzu/github/protium && rg -il 'http' --glob '!build/**' --glob '!.akku/**' --glob '!vendor/**' --glob '!.git/**'
Akku.lock
CMakeLists.txt
CHANGELOG.md
docs/plans/chez-gambit-libuv-portability.md
docs/plans/decisions/0005-libuv-build-linkage-and-distribution.md
docs/plans/chez-http-server-architecture.md
docs/plans/decisions/0001-portable-public-api-and-backend-isolation.md
docs/plans/protium-test-harness.md
tests/support/cmake/ProtiumLibuvSpec.cmake
docs/plans/protium-project-plan.md
docs/plans/work-items/0001-m0-repository-skeleton.md
```
Inspected the non-obvious hits: `ProtiumLibuvSpec.cmake` matches are libuv
tarball download URLs (`https://dist.libuv.org/dist/v1.52.1/libuv-v1.52.1.tar.gz`,
`https://example.invalid/libuv.tar.gz`); `CHANGELOG.md` / `CMakeLists.txt`
matches are `https://keepachangelog.com`, `https://semver.org`,
`HOMEPAGE_URL "https://github.com/..."` — all incidental "http" substring
hits in URLs, not protocol code. **Confirmed accurate** (finder's list is a
slight summary — it omitted `chez-gambit-libuv-portability.md`,
`0001-portable-public-api-and-backend-isolation.md`,
`0005-libuv-build-linkage-and-distribution.md`,
`protium-test-harness.md`, `work-items/0001-m0-repository-skeleton.md` by
name, but the substantive claim — every hit is a plan/doc/build-config file,
zero HTTP code — holds exactly).

### 3. "chez-http-server-architecture.md is byte-identical to ours except a 4-line status banner"

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
`wc -l`: protium copy 807 lines, target-repo copy 803 lines (=4-line delta).
**Confirmed**: the only substantive diff is exactly the 4-line status banner
the finder described; the remaining diff hunk is a single trailing-space
character, immaterial. Claim verified almost exactly (finder said "byte
identical... except a 4-line status banner," which is accurate modulo one
trailing space no reasonable reader would count against the claim).

### 4. project-plan.md lines 91-109 — "downstream HTTP acceptance checkpoint definition"

```
$ sed -n '85,115p' /Users/yuzu/github/protium/docs/plans/protium-project-plan.md
```
Lines 90-109 (section "2.4 Downstream HTTP relationship") state the
`0.1.0` release candidate "must accept a loopback HTTP/1 request, exercise
read pause/resume, send a vectored response, gracefully shut down, and
explicitly close using only the supported Protium API." **Confirmed** —
matches finder's summary exactly, including that the checkpoint requires a
**vectored response** — which chez-libuv explicitly does NOT support
(`uv-write*!` is a reserved/unbound name per the task's chez-libuv facts).
This cross-check independently substantiates the finder's adaptability note
("rewrite the acceptance checkpoint for chez-libuv (no vectored write...)")
— it is not just plausible, it is a directly verified incompatibility.

### 5. Section 14 (backpressure policy) — finder cited lines 1033-1045

```
$ sed -n '1020,1050p' /Users/yuzu/github/protium/docs/plans/protium-project-plan.md
```
"## 14. Backpressure and memory policy" begins at line 1031 (one section
header before the finder's cited range) and the body through line ~1049
reads: "Protium exposes the native queued-write byte count but does not
choose an HTTP server's high- and low-water marks. The downstream consumer
pauses reads and resumes them according to its own policy." **Confirmed** —
the finder's paraphrase ("backpressure policy left to the consumer") is
accurate; line numbers are off by a couple of lines from the exact
section-header position but land squarely inside the cited content.

### 6. test-harness.md lines 24-52 — harness rules

```
$ sed -n '15,60p' /Users/yuzu/github/protium/docs/plans/protium-test-harness.md
```
"## 2. Accepted harness decisions" (numbered list starting at line 30)
includes items matching every rule the finder listed: fresh process per
registered test group (item 4), two time bounds per async test — inner
monotonic + outer CTest timeout (item 5), deterministic/replayable
generation with recorded seed (item 6), loopback + port 0 (item 10), and "no
retry-until-pass" (item 9, verbatim: "Required tests do not use
retry-until-pass, permanent expected failures, or permissive skips").
**Confirmed** in full.

Also independently verified the finder's "goal to detect
missing/duplicate/late/reordered/post-close callbacks" claim:
```
$ grep -n -i "missing\|duplicate\|reorder\|post-close" protium-test-harness.md
67:- detect missing, duplicate, late, reordered, and post-close callbacks;
```
Verbatim match at line 67. **Confirmed.**

### 7. ADR 0003/0004 and the "store-and-reraise instead of dispatcher-contained callback errors" adaptation note

Read `docs/plans/decisions/0003-loop-owner-thread-model.md` in full. It
states: "Every C-to-Scheme dispatcher contains callback failures. It catches
raised conditions before they cross the FFI boundary, invokes a configurable
error hook, and returns normally to C... By default, an uncaught user-callback
condition causes the affected handle to begin asynchronous close." This is a
**dispatcher-contained** model.

This is materially different from chez-libuv's actual, documented behavior
per the task brief: "a raise inside a callback is stored, the loop stopped,
and re-raised from uv-run wrapped in &uv-callback-error (store-and-reraise;
an UNGUARDED raise kills the process)." **Confirmed real semantic
divergence** — the finder's adaptability note is not boilerplate hedging, it
identifies a genuine, verified incompatibility that anyone reusing protium's
acceptance-checkpoint language would need to rewrite.

Read `docs/plans/decisions/0004-buffer-ownership-and-copying.md` in full —
describes copy-on-read/copy-on-write buffer ownership, consistent in spirit
with chez-libuv's ADR-0009 (every buffer copied at the FFI boundary), so no
contradiction there; this ADR is reference-only color, not corpus material
(no test vectors, no wire bytes).

### 8. License / metadata

```
$ head -5 /Users/yuzu/github/protium/LICENSE
BSD 3-Clause License
Copyright (c) 2026, Kiyomi Computation Systems LLC
```
**Confirmed** matches candidate's `"license": "BSD-3-Clause"`.

### 9. AGENTS.md "verification discipline" claim

Read `/Users/yuzu/github/protium/AGENTS.md` lines 1-45 in full. It has a
"## Verification" section with real teeth ("Prove a check by what it
refuses, not by what it accepts"; "mutate the thing it watches and confirm
it goes red"; "A verification step is itself a check, and can be unable to
do what it claims") — this is a parallel/precursor discipline to the target
repo's own AGENTS.md line "A test is not finished when it passes. It is
finished when you have watched it fail" (verified present in
`/Users/yuzu/github/chez-http-server/AGENTS.md`, "Testing & mutation
discipline" section). The finder's "covers: verification discipline
(AGENTS.md)" claim is a fair characterization, not a literal-quote claim, and
holds up.

## Assessment against the SKEPTIC lens

- **Relevance**: Not HTTP/2-only, not client-only, not parser-only/redundant
  with the llhttp corpus (it contains no parser code or parser fixtures at
  all — httparse/byte-machine are untouched by this repo). It is squarely
  about the same subject domain (a Chez HTTP server layered on a libuv
  binding) but at the *process/design* level, not the wire-protocol level.
- **Adaptability to byte streams**: There is nothing to extract as replayable
  bytes — `approx_cases: "0"` is verified correct (both candidate test dirs
  are literally empty `.gitkeep` placeholders, and the one populated test
  lane, `tests/feasibility/`, is shim/ABI smoke tests unrelated to HTTP).
  The candidate itself says "No corpus to vendor," which is the honest and
  verified conclusion — I could not find any counter-evidence (no hidden
  fixtures, no HTTP wire-format text anywhere in the repo outside
  `.akku`/`vendor`/`build`).
- **Effort to extract**: ~0 hours for corpus extraction (nothing to extract).
  If the goal is instead "borrow the harness-rule wording and the
  acceptance-checkpoint shape for our own `.plans`/test design," that's a
  documentation-reading/rewriting task, not corpus extraction — roughly
  1-2 hours to fold the harness-decision list and the backpressure-policy
  language into our own design docs, with the two concrete corrections the
  finder already flagged (drop vectored-write language; replace
  dispatcher-contained-error language with store-and-reraise language).
- **Tier**: Every specific, checkable fact in this candidate (line ranges,
  byte-for-byte diff claim, `rg` match list, ADR content, license, empty
  test dirs, harness-rule wording) checked out under direct verification.
  I found no exaggeration, no fabricated citation, and no mischaracterization
  to refute. Given zero actual replayable test cases exist, tier 3 (lowest —
  reference/process value only, not corpus material) is the correct rating
  and I am not adjusting it.

## Verdict

**protium-local-plans: NOT refuted** (refuted = false). The candidate is
accurately and conservatively described by the finder: it supplies zero
HTTP/1.x test cases or byte streams to replay (confirmed empty
`tests/integration/`, `tests/lifetime/`), so it cannot function as corpus
material, but its narrow claimed value — harness-design rules and an HTTP
acceptance-checkpoint shape to adapt (with the two specific, independently
verified incompatibilities: chez-libuv has no vectored write; chez-libuv
uses store-and-reraise, not protium's dispatcher-contained callback-error
model) — is real and every citation underlying it checks out against the
actual files. Tier 3 (lowest) is correct; no correction needed.
