# chez-http-server — subagent-driven development ledger

`progress.md` is the spine; `global-constraints.md` binds every task brief. Read both before starting slice work. Close-outs are recorded here.

---

## Closed milestones

A closed milestone's entries live in its own `mN-progress.md`, beside its `mN-mutations.md`; M-1's are in `m0-progress.md`. They moved there verbatim on 2026-10-05, on the owner's form. This file keeps the entries since v0.1.0, and from the next release on, the entries before each release move to an archive file at that release.

| Milestone | PRs | Closed by | `make test` on main at the close | Archive |
|---|---|---|---|---|
| M-1, planning | #1 | bb81cc1 (#1) | none: no Makefile yet | `m0-progress.md` |
| M0, the skeleton and pure records | #2–#5 | 592c2a0 (#5) | 5 suites, 55 expected passes | `m0-progress.md` |
| M1, the instrument, with no server | #6 | 6b80953 (#6) | 10 suites, 95 | `m1-progress.md` |
| M2, the pure connection core | #7–#30 | ae1ef45 (#30) | 21 suites, 401 | `m2-progress.md` |
| M3, the response path | #31–#45 | 4b65a98 (#45) | 27 suites, 706 | `m3-progress.md` |
| M4, the libuv shell and the first real server | #46–#57 | 21d041f (#57) | 35 suites, 891 | `m4-progress.md` |
| M5, timeouts and limits | #58–#68 | 06b7946 (#68) | 37 suites, 973 | `m5-progress.md` |
| M6, body streaming and backpressure | #69–#94 | d9949f6 (#94) | 44 suites, 1,439 | `m6-progress.md` |
| M7, the scheduler and awaiting handlers | #95–#105 | d3ad473 (#105) | 47 suites, 1,645 | `m7-progress.md` |
| M8, shutdown, hand-off, black-box and release | #106–#117 | fa9e745 (#117), tagged v0.1.0 | 50 suites, 1,882 | `m8-progress.md` |

---

**Plan §13's billing item settled, on `docs/ci-billing-settled` (2026-10-04),** on the owner's word ("yes, remove item 4 and amend §13"). Docs only; nothing under `src/` or `tests/` moved.
- §13 gets a dated note: the billing block lifted between 2026-09-30T11:48Z and 2026-10-01T00:37Z, and PR #88's re-run, 36844511280, was the job's first green run.
- §14's open list drops its fourth item, "CI's billing block is the owner's (§13)".
- Measured 2026-10-04 from GitHub's run list, for the runs since the secret was added (2026-10-01T09:58Z): 91. All 47 pull-request runs passed. Of the 44 runs on pushes to `main`, 37 passed and 7 were cancelled, each by the ledger commit pushed one or two minutes behind it (the workflow cancels a run in progress on the same ref), whose own run passed.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,882 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#118, plan §13's billing item settled** (the entry above). 2267371 was squashed as 821df6f (tree 99dfe63, the tested tip's), whose parent is f0672fd.
- **CI.** Its run, 37216930111, passed on 2267371: fifty suites, 1,882 expected passes on ubuntu-24.04.
- **Branches.** `--delete-branch` deleted the branch, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,882 expected passes, every pin ok.

NEXT: plan §14's open list, or a new milestone, when the owner asks.

DECIDED on the owner's word, 2026-10-04: **parse-ahead is not wanted** ("record parse-ahead as not wanted"), after a discussion of decision 0004's 2026-09-25 amendment, item 3. Recorded on `docs/parse-ahead-not-wanted`; docs only, nothing under `src/` or `tests/` moved.
- **Why.** No client the server meets pipelines: browsers turned it off, libcurl in 7.62.0, and Caddy's reverse proxy, Go's `net/http` transport, sends a connection's next request only once the last response is read. The gain would be a pipelining client's alone, and the cost is 0004's 2026-09-25 list.
- **Weighed, not taken.** Measuring a client pipelining 16 deep first; and a middle way, kept in the amendment: start a next request already in the remainder once the previous response is handed to the shell, without waiting for its writes, reading only once every write completes.
- **Records.** Decision 0004 gets the amendment "parse-ahead is not wanted". The brief's item 3 and the design's pipelining note get a dated line each, and 0005's pipeline-cap amendment a dated sentence: no design waits for the field's name. `pipeline-cap` and `CHEZ_HTTP_PIPELINE_CAP` are unchanged and accept only 1. Item 3's alternative, reading during a handler only to notice a client leave, stays on plan §14's open list.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,882 expected passes, every pin ok.

**The pipeline cap removed, on `refactor/remove-pipeline-cap` (2026-10-04),** on the owner's word ("lets remove `pipeline-cap` in its own PR"), stacked on `docs/parse-ahead-not-wanted` (#119).
- **What.** `(http-server limits)` loses `pipeline-cap`: the field, `limits-pipeline-cap`, `env-pipeline-cap` and `CHEZ_HTTP_PIPELINE_CAP`, so `make-limits` takes nineteen fields. The variable is not read: whatever it holds, the limits are `default-limits`. v0.1.0 refused any value but 1, so no deployment that started before changes.
- **Tests first.** The limits suite's new checks, run against the code before the change: 49 passes, 3 failures, each its own row's. The serve suite's malformed-setting check uses `CHEZ_HTTP_REQUIRE_HOST=yes` where it used `CHEZ_HTTP_PIPELINE_CAP=2`. Four mutants, each red, are in m8-mutations.md ("After M8").
- **Docs and records.** `docs/configuration.org` drops the variable, and CHANGELOG.md lists the removal under Unreleased. Decision 0005 gets the amendment "the pipeline cap is removed", with dated pointers from 0004's and 0005's notes of the day, the design's pipelining note and §9.4, and the brief's items 3 and 4.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,881 expected passes, every pin ok: one fewer, three checks of the cap gone and two of its absence added.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#119 and #120, stacked: parse-ahead not wanted, and the pipeline cap removed.**
- **#119, decision 0004: parse-ahead is not wanted,** as 5196c9f. Its squash tree is the tested tip's, 74ae973's (b6c9e5d), and its parent is 0f43524. CI passed on 74ae973 (run 37218010771: fifty suites, 1,882 expected passes). It merged without `--delete-branch`, since #120 was based on it.
- **#120, the pipeline cap removed,** retargeted to main and rebased from 74ae973 onto 5196c9f: adcc863 became 519f149 (tree a517af2, the tested one's), pushed with the lease. CI passed on both heads (37218775215 on adcc863, 37218965415 on 519f149), each fifty suites and 1,881 expected passes. It merged as da63738, whose parent is 5196c9f.
- **Branches.** #119's was deleted by hand, local and remote, once #120 was on main. #120's `--delete-branch` deleted its own, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,881 expected passes, every pin ok.

NEXT: plan §14's open list, or a new milestone, when the owner asks. CHANGELOG.md's Unreleased holds the removal, a change to v0.1.0's API, so the next release is 0.2.0 by semantic versioning.

DECIDED on the owner's word, 2026-10-04: **a header value is trimmed where it is read** ("close it"), after a discussion of decision 0012's 2026-09-27 amendment, which plan §14's open list carried. Recorded on `docs/trim-where-read`; docs only, nothing under `src/` or `tests/` moved.
- **Why.** No reader misses the trim: the view and the Host judge trim a whole value, and the Expect, Upgrade and Transfer-Encoding readers trim each element, as they must. The facade exports no span. Trimming where a value is read allocates nothing; trimming where it is recorded costs every field a check, and a new span for each value that ends in whitespace.
- **A correction to the discussion.** It named the tests' churn as a cost, unmeasured. M4's probe HW-P (the Host whitespace fix, above) trimmed every value where the core records it and kept every suite green, the allocation lane included. 0012's amendment records that instead.
- **Records.** Decision 0012 gets the amendment "a value is trimmed where it is read", and plan §14's open list drops the item: five remain.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,881 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#121, decision 0012: a header value is trimmed where it is read** (the entry above). 3cf200d was squashed as daec4cc (tree 7f211e2, the tested tip's), whose parent is a045206.
- **CI.** Its run, 37219916260, passed on 3cf200d: fifty suites, 1,881 expected passes on ubuntu-24.04.
- **Branches.** `--delete-branch` deleted the branch, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,881 expected passes, every pin ok.

NEXT: plan §14's open list (five items), a new milestone, or cutting 0.2.0, when the owner asks.

**M8.2's four noted findings settled, on `fix/taker-deferred-done` (2026-10-04),** on the owner's word: "close all but 6, lets talk about what it would take to fix 6", then "build the targeted fix - lets get a good handle on its impact".
- **Closed, not wanted:** the fourth (a 101 listing protocol layers, refused), the fifth (the door reading the close-after reason) and the tenth (a taker's writes not joined), each with its reason in decision 0016's amendment of this date. Plan §14's open list drops the item: four remain.
- **Fixed, the sixth.** `serve`'s loop is `run-until-stopped!`, which, once the server has stopped, makes the taker's calls still deferred to a turn (`shell-call-deferred!`). The shell keeps them in a queue of its own, which the drain's calls take from, oldest first. One pass, and nothing else the scheduler holds runs. The shell exports `shell-scheduler` for the test that queues other work.
- **Tests first.** The serve suite's two new checks, against `run-until-stopped!` before the call: 16 passes, 2 failures, the `done`s told nothing when the run returned and `ECANCELED` once the loop turned on. With the fix, 18. Six mutants, each red, are in m8-mutations.md ("After M8"); the sixth is the one-line drain the owner did not take.
- **Impact, measured** (Darwin arm64): a request's path unchanged, the whole server's allocation per GET over 100,000 GETs 10,433 B at one connection on both trees, and at 50, 8,900 to 8,903 B on main and 8,902 to 8,904 B with the fix. A refused write allocates 96 B as it is asked for and 425 B as its `done` is made, against 64 B and 409 B. `research/spike/taker-deferred-cost.sps` is new and `m8-request-alloc.sps` takes LARGE; their runs are in `out/`.
- **Docs.** `docs/handlers.org`'s caveat says the `done` comes before `serve` returns, and CHANGELOG.md's Unreleased gains Fixed.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,883 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#122, a taker's deferred `done` made before `serve` returns, and M8.2's other three noted findings closed** (the entry above). ea93f39 was squashed as 15a3d78 (tree c87bb41, the tested tip's), whose parent is 5797d66.
- **CI.** Its run, 37222739116, passed on ea93f39: fifty suites, 1,883 expected passes on ubuntu-24.04, the serve suite's eighteen among them, so the two new checks hold on Linux amd64 too.
- **Branches.** `--delete-branch` deleted the branch, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,883 expected passes, every pin ok.

NEXT: plan §14's open list (four items), a new milestone, or cutting 0.2.0, when the owner asks.

**Every 1.x served, and every other version answered 505, on `feat/serve-http-1x` (2026-10-04),** on the owner's word ("serve 1.x for 3d, keep 400 for 3c"), after a discussion of plan §14's open list: two of M8.3's noted robustness items, a lowercase method answered 400 (3c) and HTTP/1.2 and 3.0 answered 400 (3d).
- **Measured first** (Darwin arm64): the same request lines, each on a fresh connection, to this server, Node 20.10 and Apache 2.4.67 with its defaults; nginx's, Go's `net/http` and lighttpd's answers read from their request-line parsers' source, Kestrel's from its source and tables. `get /`: 400 here, in Node and nginx, 501 in Apache and lighttpd, the handler's in Go. `FOO /`: 400 here and in Node, 501 in Apache and lighttpd, the handler's in nginx, Go and Kestrel. `HTTP/1.2`: 400 here, in Node and lighttpd, served in Apache, nginx and Go, 505 in Kestrel. `HTTP/3.0`: 400 here, in Node and lighttpd, 505 in nginx, Go and Kestrel, served in Apache. RFC 9110 §9.1 (an unknown method SHOULD get 501), §6.2 (a higher minor version SHOULD be processed as the highest implemented) and §15.6.6 (505 is for a major version). Behind Caddy, which runs on Go's `net/http` (read from source, not measured), a client's HTTP/1.2 or 3.0 should never reach this server, but a `get` does.
- **Prototyped**, each a scratch copy of `src/` run against all fifty suites (an unchanged copy: 1,883 passes, 43 s): 505 for every version but 1.0 and 1.1 (2 checks moved); serving 1.x and answering the rest 505 (4 moved); 501 for a method error whose refused byte is a token character (1 moved, but `G /` and RTSP's `DESCRIBE` stayed 400 where Apache says 501).
- **DECIDED, 3d: "serve 1.x".** The adapter sets llhttp's version leniency (`LENIENT_FLAGS.VERSION`, 1 << 4) as it makes a parser; the core's rule, unchanged, refuses every version that is not 1.x with 505 and lets 1.x on as HTTP/1.1, to the Host rule, the framing and keep-alive. A version the parser cannot read stays its 400. Weighed and not taken: 505 for all but 1.0 and 1.1, Kestrel's; keeping the parser's 400. **DECIDED, 3c: "keep 400".** A method outside the parser's 36 stays its error, a 400. Weighed and not taken: 501 judged from the refused byte, inexact; handing an unknown method to the handler, which needs a mode of chez-httparse that llhttp has no counterpart for.
- **Tests first.** The head suite's nine new rows (the leniency pinned to 16; 3.0 and 0.8 answered 505; 1.2 and 1.9 served, kept alive, held to the Host rule and the framing; versions the parser cannot read, and `http/1.1`, still 400), the allocation check's mirrored initials, the robustness lane's `acceptable#9` and its count of 31, the strictness lane's departure for HTTP/1.2 (now Kestrel's, `minor-version-served`), and `version.vtc`'s c4 to c6. Against the code before the change: head 59 passes and 7 failures, allocation 25 and 1, robustness 15 and 2, strictness 16 and 1, clients 35 and 1. Twelve mutants, each red, are in m8-mutations.md ("After M8").
- **Impact** (Darwin arm64): a connection's parser allocates 1,072 B as it is made, against 1,056 B: once a connection. The lanes' verdicts move for one case each: guardian's `acceptable#9`, "Unknown but OK HTTP/1.2", served; httpd's row 15 now agrees; Kestrel's `UnrecognizedHttpVersionData#3` now departs.
- **Records.** Decision 0006 gets the amendment "every 1.x is served, and every other version answered 505", and its M8.3 amendment's item 2 a dated pointer, which also corrects it: nginx serves HTTP/1.2. Design §6.5's 400 row records 3c, and its 505 row the versions. Plan §2.1 and M8.3 get dated notes, and the open list drops the two items; the robustness lane's item keeps three. The strictness lane's old reason cited RFC 9112 §2.3 for serving 1.2 as 1.1; the rule is RFC 9110 §6.2, which the new reason cites.
- **Docs.** `docs/connections.org` says HTTP/1.2 is served as 1.1 and HTTP/3.0 gets 505, `docs/handlers.org` which methods reach a handler, and CHANGELOG.md's Unreleased gains Changed.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,892 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#123, every 1.x served and every other version answered 505, and a method the parser does not know kept at 400** (the entry above). 5022bde was squashed as 9bd2718 (tree 9cbebc1, the tested tip's), whose parent is 31ab474.
- **CI.** Its run, 37226685841, passed on 5022bde: fifty suites, 1,892 expected passes on ubuntu-24.04, the head suite's 66 among them, so its nine new rows hold on Linux amd64 too.
- **Branches.** `--delete-branch` deleted the branch, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,892 expected passes, every pin ok.

NEXT: plan §14's open list (four items: 0004 item 3's alternative, the 32 lenient fixtures, the robustness lane's three, the smuggler corpus), a new milestone, or cutting 0.2.0 (Unreleased holds Changed, Removed and Fixed), when the owner asks.

**The robustness lane's other three settled, on `test/one-provenance-checker` (2026-10-04),** on the owner's word ("keep 400 for 1, keep for 2, merge for 3"), after a discussion of plan §14's open list.
- **Measured first** (Darwin arm64): chunked requests and targets sent to this server, Node 20.10 and Apache 2.4.67, each request followed by a second on the same connection; nginx's and Go's answers read from their source, lighttpd's from its `request.t`. `a; comment`: 400 here and in Node, read by Apache, nginx, Go and lighttpd. `a ;comment`: 400 here and in Node, read by Apache and nginx, refused by Go. `GET /a%00b`: served as written here and in Node and Go; 404 in Apache, 400 in nginx, Kestrel and lighttpd. RFC 9112 §7.1.1 and RFC 9110 §5.6.3 (a recipient MUST strip BWS), RFC 3986 §2.1 and §7.3 (the code that decodes should reject `%00`). Behind Caddy, which runs on Go's `net/http` (read from source): Go writes its own bare size lines upstream, so no client's extension reaches this server, while `%00` does, as written. A prototype refusing `%00` moved only the strictness lane's eight `%00` departures, across all fifty suites.
- **DECIDED, 1: "keep 400".** A space or tab around a chunk extension's `;` or `=` stays the parser's 400. Weighed and not taken: a whitespace leniency asked of chez-httparse, which llhttp has no counterpart for (its `spaces-after-chunk-size` is no fix: it allows spaces before the `;` only). **2: "keep".** `%00` reaches a handler as written. Weighed and not taken: refusing it with 400. **3: "merge".** Weighed and not taken: keeping both checkers.
- **The merge.** `tests/test-libhtp.sps` calls `(provenance)`'s `verify-provenance!` and `read-file-bytes`, outside any test form so a failure still ends it with status 3, and its own copy goes: 12 lines in, 70 out. Its eleven checks pass. On scratch copies of the corpus, a stray file under `files/` or at the top is exit 0 in main's suite and exit 3 in the merged one; M1.3's mutation, a changed byte, a missing file and a miscount are exit 3 in both. Two mutants of `(provenance)` redden the merged suite and leave main's green (m8-mutations.md, "After M8").
- **Records.** Plan: dated notes in M1.3 and M8.3, and the open list drops the robustness lane's item; three remain. The open list had placed item 1's cases in libhtp's streams 28 and 29: they are lighttpd's `request.t` blocks 28 and 29. Design §6.5's 400 row records item 1, and the strictness lane's reasons cite both kept decisions. No CHANGELOG entry: nothing a client or an embedder meets changes.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,892 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#124, libhtp's corpus checked by the shared PROVENANCE checker, and the robustness lane's other two items kept** (the entry above). f36afd5 was squashed as 61e8f40 (tree a2c9723, the tested tip's), whose parent is 4402a0a.
- **CI.** Its run, 37228361288, passed on f36afd5: fifty suites, 1,892 expected passes on ubuntu-24.04, the libhtp suite's eleven among them, with no PROVENANCE error.
- **Branches.** `--delete-branch` deleted the branch, local and remote, switched this checkout to main and fast-forwarded it. No PR is open.

`make test` green on main: fifty suites, 1,892 expected passes, every pin ok.

NEXT: plan §14's open list (three items: 0004 item 3's alternative, the 32 lenient fixtures, the smuggler corpus), a new milestone, or cutting 0.2.0 (Unreleased holds Changed, Removed and Fixed), when the owner asks.

**The 32 lenient llhttp fixtures in the outcome lane, on `test/outcome-lane-every-fixture` (2026-10-04),** on the owner's word ("A"), after a discussion of plan §14's open list.
- **Measured first** (Darwin arm64, at a4c5191). The 32 are 29 that llhttp recorded under a lenient flag and 3 `request-finish` ones, whose logs end with what `llhttp_finish()` returns. chez-httparse v0.4.5's own ratchet passes all 167 request fixtures under their own flags. Through our path, the 29 lenient traces equal their logs, and the 3 finish ones stop a line short. Under the server's parser, read whole, 4 equal their logs (`lenient-version.md#1`, `lenient-header-value-relaxed.md#3` to `#5`) and the other 25 stop in a parser error. All 32 give one outcome at every chunk size, with both handlers. With bodies read, the server answers 22 with a 400 before any handler, `HTTP/5.6` with a 505, 4 with a 400 after a handler; it serves 3, and closes 2 cut off in their heads. 15 of the 32 inputs are byte for byte a strict fixture's; the 32 reach 15 distinct parser errors, all among the 135's; one outcome is new, a request answered and the next refused (`lenient-headers.md#2`).
- **DECIDED: "A".** The outcome lane runs all 167 request fixtures, and the trace lane keeps the 32 deferred; the ratchet derives its split per lane (decision 0019). Weighed and not taken: the trace lane taking `lenient-version.md#1` too; keeping all 32 deferred.
- **Tests first.** The ratchet's counts, outcome 167 passing and 0 deferred, and the outcome suite's "167 request fixtures in the lane", now one list counted and compared. Against the tree before the change: ratchet 7 passes and 2 failures, outcome 6 and 1; with the manifest flipped and the split unchanged, the ratchet's 32 violations. Eight mutants, each red, are in m8-mutations.md ("After M8"). Two of the core's, which make outcomes depend on the chunk size, name four of the 32, each among strict fixtures; none fails a check through the 32 alone.
- **Impact** (Darwin arm64). The outcome lane's runs go from 253 to 317 at size 1 and whole, and from 9,394 to 14,070 at every size, which ran in 0.97 s. The outcome suite and the ratchet took 0.60 to 1.01 s each, two runs each, against 0.63 to 0.86 s on a4c5191.
- **Records.** Decision 0019, new. Plan §2.1 and §11 get dated notes, and the open list drops the item: two remain. Design §8.1 says property 2 runs all 167. Since #123 the trace lane's init is the server's but for the version flag, and `invalid.md#19` (`GET / HTTP/5.6`) is the one strict fixture the server's parser reads differently: `(trace-lane)` and plan §2.1 say so. `ratchet.txt`'s "(0009)" was chez-httparse's decision 0009, written before this repository's 0009; it now cites plan §2.1 and 0019. No CHANGELOG entry: nothing a client or an embedder meets changes.
- `make test` green before the commit (Darwin arm64): fifty suites, 1,892 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **#125, the outcome lane runs all 167 request fixtures** (the entry above). 5b92367 was squashed as b303b84 (tree 51bbc3e, the tested tip's), whose parent is a4c5191.
- **CI.** Its run, 37230775068, passed on 5b92367: fifty suites, 1,892 expected passes on ubuntu-24.04, the outcome lane's seven (317 runs) and the ratchet's nine among them. It was still running when the ritual began, and had passed by the next read.
- **Branches.** `--delete-branch` deleted the remote branch and left this checkout on the local one, so main was fast-forwarded and the branch deleted by hand. No PR is open.

`make test` green on main: fifty suites, 1,892 expected passes, every pin ok.

NEXT: plan §14's open list (two items: 0004 item 3's alternative, the smuggler corpus), a new milestone, or cutting 0.2.0 (Unreleased holds Changed, Removed and Fixed), when the owner asks.

**A client's close noticed while its request is answered, on three stacked branches (2026-10-04),** on the owner's word ("lets do C"), and by form ("Once", "Close quietly"), after a discussion of plan §14's open list: decision 0004 item 3's alternative.
- **Measured first** (Darwin arm64): a client that left 0.1 s into a handler's 3 s wait was noticed here at about 3.0 s, by FIN or RST, and one that only half-closed was answered at 3.00 s; Node 20.10 told its handler at 0.102 and 0.107 s, and closed on the half-closed client at 0.11 s with no answer. Read from source: Go 1.25.14 reads in the background while a handler runs, and any read error, a FIN's among them, cancels the request; Caddy v2.11.7 sends the upstream request with the client's request, and Go's transport closes the upstream socket when it is cancelled, logging 499, never half-closing HTTP/1.1 upstream; Node v22.23.3 ends its side at a FIN (`httpAllowHalfOpen` false); nginx 1.29.8, waiting on an upstream, takes a FIN as 499 and closes the upstream, unless `proxy_ignore_client_abort`. RFC 9112 §9.5 (SHOULD watch for a closure signal) and §9.6 (a half-close is no loss of interest).
- **DECIDED: C** ("lets do C"), **"Once"** and **"Close quietly"** by form (decision 0020). Weighed and not taken: A, not wanted; B, noticing and closing at once; every wait after the close raising; an uncaught raise as a failure.
- **Built.** Past a request's end the core reads in `handling` and `responding`, holding the first delivery that arrives and stopping. A FIN with nothing held tells the request's code, `(client-closed)`, the seventeenth action, and the connection closes at once after the response; with requests held it tells no one, and they are answered first. A read error tells and closes. A response after the end closes at once, and reading never starts again. The waits keep a notice a request, which raises once; both shells give it to each coroutine the request's code runs on and let it go as the parser resumes; an uncaught raise of it is answered nothing and not logged.
- **Found while building.** A client that pipelines and half-closes lost its third answer under a first rule that told the last request held; the contract caught it. The contract's fake drained after every event, where the libuv shell drains once a turn, so it now drains at the libuv shell's turns (THE TURNS). The contract's waiting scripts half-closed as they sent and, told, answered nothing, both shells agreeing on nothing written: a script's client now ends its stream once answered, two end early on purpose, and a check holds the rest to an answer. libuv 1.52.1 delivers an end again once reading restarts (`src/unix/stream.c`); Windows may not, so the core remembers it.
- **Tests first.** The wait suite's seven, which did not load, and the table's seventeen failures, before the code; then the message loop's eight, the contract's twelve, the shell's four and the retention check widened. Forty mutants, each red, in m8-mutations.md ("After M8"), M7's two `serial?` mutants among them, still killed on this tree.
- **Impact** (Darwin arm64, `research/spike/m7-exit-budget.sps`, two runs each, alternating): a connection idle after waits holds 1,942 to 1,956 B of heap on 0020's tree against 1,926 to 1,944 B on main, the two fields; after answers at once the readings fall in two bands about 95 B apart on main and the branch alike (`client-closed-budget-small.sps`). No coroutine is left in the heap.
- **Records.** Decision 0020, new; 0004, 0015 and 0002 amended; design §4.1, §4.3, §5.3 and §7.5 notes; plan M8.4's bullet, and the open list drops the item: the smuggler corpus remains. `docs/handlers.org` and `docs/connections.org`; CHANGELOG.md's Unreleased gains Added and Changed.
- `make test` green before each commit (Darwin arm64), each layer's tree run whole: the waits, fifty suites, 1,899 expected passes; with the core, 1,934; with the shell, 1,941; every pin ok.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **a client's close noticed, as three stacked PRs** (the entry above).
- **#126, the wait library and `&client-closed`,** as b8dc00c. Its squash tree is the tested tip's, cb00c6b's, and its parent is d784013. It kept its branch, since #127 was based on it.
- **#127, the core reads past a request's end,** as c5973d4. It was retargeted to main and rebased from #126's tip, cb00c6b. The rebased tip, 6b0ec52, has the tested tree (26f72bd's), and so does the squash, whose parent is b8dc00c. It kept its branch, since #128 was based on it.
- **#128, the libuv shell tells a waiting handler, with the records,** as 9016945. It was retargeted to main and rebased from #127's first tip, 26f72bd. The rebased tip, 84b51ad, has the tested tree (5533109's), and so does the squash, whose parent is c5973d4.
- **CI.** Each merged on `linux` SUCCESS at its head: #126 on cb00c6b (run 37238709017); #127 on 6b0ec52 (run 37239186462); #128 on 84b51ad (run 37239325116). Each log holds its layer's count: fifty suites, and 1,899, 1,934 and 1,941 expected passes. The first heads of #127 and #128 had passed too (37238711071, 37238712859).
- **Branches.** All three deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: fifty suites, 1,941 expected passes, every pin ok.

NEXT: plan §14's open list (one item: the smuggler corpus), a new milestone, or cutting 0.2.0 (Unreleased holds Added, Changed, Removed and Fixed), when the owner asks.

**The smuggling corpus, as a hand-written fixed-vector lane, on `test/smuggling-framing-lane` (2026-10-04),** on the owner's forms ("Static fixtures only", then "Per-case verdict + gate"), after "commence the smuggler corpus" and a discussion of why the vendored-generator path keeps being stopped: plan §14's last open item. Decision 0021.
- **The item's history.** M8.3's attempt vendored `defparam/smuggler`'s and PortSwigger's Transfer-Encoding generators and a probe reader that drove them; a safety classifier stopped that step and the slice was dropped (plan §14's M8.3 note). Guardian's 162 cases already cover the Transfer-Encoding classes. Asked whether it was possible at all, the owner chose not to re-open the generator path but to add a small hand-written fixture set, and to record each case's verdict per case.
- **Measured first** (Darwin arm64, Chez 10.4.1), feeding the canonical framing shapes through the server's own parser to one fake connection (`scratchpad/smug/measure.sps`): every conflicting or obfuscated-coding gadget is already refused — CL.TE / TE.CL (both headers, either order), duplicate or malformed Content-Length, a space before the colon, a duplicate Transfer-Encoding, chunked not the final coding, an unknown coding, and `identity` are 400; an unimplemented coding before chunked (`gzip, chunked`) is 501. The only obfuscations served are the safe ones: a tab after the colon is OWS, so chunked is honoured, and a look-alike name (`Transfer_Encoding`, `Transfer--Encoding`) is an ordinary field, not a coding.
- **DECIDED: "Static fixtures only", then "Per-case verdict + gate"** (decision 0021). A standalone lane of nineteen hand-written fixed vectors, one per family; nothing generated, nothing vendored, no probe. Weighed and not taken: vendoring the generators and writing a probe reader (the stopped path, which duplicates guardian); closing the item as covered by guardian; a refused-only fixture set (cannot prove the served obfuscations are safe).
- **Built.** `tests/smuggling-corpus.sls` holds the vectors as data and a byte assembler; each records its measured verdict (`served`, or a refusal status) and a `safe`/`hazard` category. `tests/smuggling-lane.sls` feeds each to one fake connection (reusing `(outcome-lane)`) and gates two properties: the verdict, both ways, and the security policy that the corpus's own category and verdict agree, so no hazard is served. Chunk invariance is not re-gated (these refuse at the head; it is the outcome and robustness lanes').
- **Tests first.** Eight checks; each watched to fail under a mutant (`m8-mutations.md`, "After M8"). Two are code mutants of the status table in `(http-server decisions)` — a 501 moved, the parser-error 400 moved — so the verdict gate catches a server regression, not only a data edit; the rest are corpus-data mutants (count, category, id, assembler, policy).
- **Records.** Decision 0021, new. Plan §14's open list is now empty (its last item settled); design §8.8 gets a note. No CHANGELOG entry: nothing a client or an embedder meets changes (test-only), as for the outcome and robustness lanes.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,949 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "CI is green, do closing ritual": **the smuggling corpus, a hand-written fixed-vector lane** (the entry above). 687eee2 was squashed as 58e27ba (tree the tested tip's, parent e425eb3).
- **CI.** Its run, 37241392166, passed on 687eee2: fifty-one suites, 1,949 expected passes on ubuntu-24.04, the new smuggling lane's eight among them.
- **Branches.** `--delete-branch` deleted the remote branch and left this checkout on the local one, so main was fast-forwarded and the branch deleted by hand. No PR is open.

`make test` green on main: fifty-one suites, 1,949 expected passes, every pin ok.

**Plan §14's open list is now empty: every item is settled.** Decision 0021 recorded that the smuggler corpus is this hand-written lane, not the vendored-generator/probe path (stopped by a safety classifier, and covered by guardian) — a future session should not re-open that step.

NEXT: a new milestone, or cutting 0.2.0 (CHANGELOG.md's Unreleased holds Added, Changed, Removed and Fixed, the removal breaking, so 0.2.0 by semantic versioning), when the owner asks.

**v0.2.0's release, on `chore/release-0.2.0` (2026-10-04),** on the owner's "cut 0.2.0", with plan §14's open list empty.
- **What it carries.** Every PR since v0.1.0, #118 to #129, was read against CHANGELOG.md's Unreleased. The six a client or an embedder meets are in it: Added, `&client-closed` (#126 to #128, decision 0020); Changed, reading while a handler runs (the same three) and HTTP/1.2 to 1.9 served as 1.1 with every version that is not 1.x answered 505 (#123); Removed, the pipeline cap (#120); Fixed, a taker's deferred `done` (#122). The other six are docs or tests only (#118, #119, #121, #124, #125, #129).
- **Semantic versioning.** The removal changes v0.1.0's API (`make-limits` takes nineteen fields, not twenty), so the release is 0.2.0.
- **The pins are v0.1.0's.** Every gitlink is unchanged since the tag: chez-libuv d46654c (v0.7.3), chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Built.** CHANGELOG.md: Unreleased moved under `[0.2.0] - 2026-10-04`, with an intro naming the breaking change and the pins, a fresh empty Unreleased above it, and the link references (`[0.2.0]` compares v0.1.0 with v0.2.0). README.org's status names v0.2.0 the current release and what it adds.
- **Not re-measured.** The 0.2.0 section makes no throughput or memory claim, so the load smoke was not run again; the numbers in `[0.1.0]` stay 0.1.0's. Decision 0020 measured its own cost: an idle connection that waited holds about 16 B more, its two new fields.
- **The tag.** After the merge, once main's run on the squash is green, `v0.2.0` goes on the squash, annotated as v0.1.0's was: "chez-http-server v0.2.0 — a waiting handler is told when its client closes", with a body pointing at CHANGELOG.md. The owner's "cut 0.2.0" asks for it; the merge waits for "do closing ritual".
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,949 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

MERGED to main on 2026-10-04, on the owner's "CI is green, do closing ritual": **v0.2.0's release** (the entry above). ee9e763 was squashed as 1c86771 (tree the tested tip's, parent 27e4d6f).
- **CI.** Its run, 37242254562, passed on ee9e763: fifty-one suites, 1,949 expected passes on ubuntu-24.04. Main's run on the squash, 37242394595, passed too, with the same counts, before the tag.
- **Branches.** `--delete-branch` deleted the remote branch and left this checkout on the local one, so main was fast-forwarded and the branch deleted by hand. No PR is open.
- **TAGGED v0.2.0** on 1c86771, annotated as v0.1.0 was ("chez-http-server v0.2.0 — a waiting handler is told when its client closes", its body pointing at CHANGELOG.md's `[0.2.0]`), and pushed: `git ls-remote --tags` shows the tag object 751d28b and its commit 1c86771. No GitHub Release, as for v0.1.0.

`make test` green on main: fifty-one suites, 1,949 expected passes, every pin ok.

NEXT: a new milestone, when the owner asks. CHANGELOG.md's Unreleased is empty.

**The WebSocket path decided, on `docs/websocket-path` (2026-10-04),** on the owner's "Let's begin the websocket path", four forms ("New repo", "Can wait", "RFC 6455 only", "Autobahn in CI"), and "Create it now". Decision 0022.
- **Read first.** Plan §9's note of 2026-09-26 already said WebSocket is "a library of its own ... not code in this repository", after the owner's own question in an earlier session. Two research agents (Sonnet), each fact with its source, covered three things:
  - RFC 6455's rules for a server, and RFC 7692 §5;
  - five peers' APIs and defaults. Four read with a call that waits and Node's ws with callbacks. Message caps run from 32 KiB to none. Only coder and gorilla check `Origin` by default, and only websockets compresses by default;
  - Autobahn|Testsuite: Apache-2.0, v25.10.1, 517 cases, 301 without compression. Its image is linux/amd64 only, and Deno pins it by digest.
- **Here:** no SHA-1 or base64 in the tree; a parked `await` holds 3,637 to 3,644 B (design §5.2); Docker 29.2.1 runs on the Mac.
- **DECIDED (0022).** A private sibling repository, `chez-websocket`, created on "Create it now" (Kiyomi-Computation-Systems/chez-websocket, its first commit the siblings' license, 27ad906). Its code can wait; v1 is RFC 6455 alone; Autobahn gates it in CI, 301 cases. Weighed and not taken: the library in this repository; callbacks in place; permessage-deflate; a client; unit vectors alone.
- **Records.** Decision 0022, new. Plan §15, new: the WebSocket path, this repository's part being the door change (decision 0023, the next PR) and server 0.3.0. No code and no CHANGELOG entry.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,949 expected passes, every pin ok.

**The door lets a taker wait, on `feat/taker-awaits` (2026-10-04),** on the owner's form ("take-over answers awaiting"): decision 0023, the WebSocket path's first slice here (decision 0022).
- **DECIDED (0023).** A take-over may answer `(awaiting thunk)`. Its thunk runs on a coroutine, a notice of the taker's own attached and closed as the stream's close completes. A raise of that close is quiet; any other is logged `taker-failed` and closes the stream. Weighed and not taken: every take-over on a coroutine; a spawn verb.
- **Built**, in both shells:
  - `hand-off!` reads the take-over's answer, and `taker-wait!` spawns an `awaiting` thunk with the notice; the stream's close completion closes it.
  - The fake drains its scheduler after a delivery to a taker and after a taker's completion, each a turn of the libuv shell's, and records a thunk's raise (`fake-shell-taker-failures`).
  - A clause closing a notice made after the stream had closed was written, found unreachable while mapping the mutants, and taken out.
- **Tests first.**
  - The fake's door suite: five checks, red before the behaviour (23 and 5).
  - The shell suite: two checks red before it, with two knock-ons (190 and 4); a third, the thunk that ends, was added once the mutant map showed the libuv shell had none.
  - Sixteen mutants, each red, every one loaded (m8-mutations.md, "After M8").
- **Docs.** `docs/handlers.org` gains "A taker that waits". Its example was run as written against the fake: three reads written back in order, one of them arriving while the loop was busy, and the client's end closed the stream with nothing logged. CHANGELOG.md's Unreleased gains Added.
- **Records.** Decision 0023, new; 0016 amended; the design's door note.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,957 expected passes, every pin ok.

MERGED to main on 2026-10-04, on the owner's "Do closing ritual": **the WebSocket path's decision and the door change, as two stacked PRs** (the two entries above).
- **#131, decision 0022,** as e9f2209. Its squash tree is the tested tip's, 6c29015's, and its parent is 7477a3f. It kept its branch, since #132 was based on it.
- **#132, a take-over may answer awaiting (decision 0023),** as 9b1a421. It was retargeted to main and rebased from #131's tip, 6c29015. The rebased tip, 474fdb4, has the tested tree (796d68e's), and so does the squash, whose parent is e9f2209.
- **CI.** Each merged on `linux` SUCCESS at its head: #131 on 6c29015 (run 37248307485), #132 on 474fdb4 (run 37249149712). 796d68e's own run had passed too (37248322299). The logs hold each layer's count: fifty-one suites, and 1,949 and 1,957 expected passes.
- **Branches.** Both deleted, local and remote. No PR is open.

`make test` green on main: fifty-one suites, 1,957 expected passes, every pin ok.

NEXT: server 0.3.0, for chez-websocket to pin (CHANGELOG.md's Unreleased holds Added: a taker can wait); then chez-websocket's skeleton, in its own repository (plan §15). Both when the owner asks.

**v0.3.0's release, on `chore/release-0.3.0` (2026-10-04),** on the owner's "Cut the release", after the WebSocket path's door change.
- **What it carries.** Every PR since v0.2.0, #131 and #132, was read against CHANGELOG.md's Unreleased. The one an embedder meets is in it: Added, a taker can wait (#132, decision 0023). #131 is decision 0022 and the plan only.
- **Semantic versioning.** The addition breaks nothing in 0.2.0's API: a take-over that answers anything but `awaiting` runs as before. So the release is 0.3.0, the minor version decision 0022 named for it.
- **The release note checked.** `sleep-ms`, `resolve` and `with-deadline` find the loop's waits through the running coroutine's scheduler (`loop-waits`, waits.sls), and a taker's thunk is spawned on the shell's scheduler, so the Added entry's list of waits holds for it.
- **The pins are v0.2.0's.** Every gitlink is unchanged since the tag: chez-libuv d46654c (v0.7.3), chez-httparse 0b7058e (v0.4.5, byte-machine v0.7.0), uriparse 5ecd88f (v0.6.2), chez-srfi 7879b52, vtest2 803dcd0.
- **Main's CI on the code released.** 9b1a421's own run was cancelled 77 s in, when the ledger reflect fe75671 was pushed during it (ci.yml's concurrency group cancels a run in progress). fe75671's run, 37249382260, passed: its tree is 9b1a421's plus the ledger.
- **Built.** CHANGELOG.md: Unreleased moved under `[0.3.0] - 2026-10-04`, with an intro naming the addition, that nothing breaks, and the pins; a fresh empty Unreleased above it; the link references (`[0.3.0]` compares v0.2.0 with v0.3.0). README.org's status names v0.3.0 the current release and what it adds.
- **Not re-measured.** The 0.3.0 section makes no throughput or memory claim, so the load smoke was not run again. A taker that waits holds a parked coroutine, as a handler does (design §5.2: 3,637 to 3,644 B), and a taker that does not wait runs none.
- **The tag.** After the merge, once main's run on the squash is green, `v0.3.0` goes on the squash, annotated as v0.2.0's was: "chez-http-server v0.3.0 — a taker can wait", with a body pointing at CHANGELOG.md. The owner's "Cut the release" asks for it; the merge waits for "do closing ritual". The ledger reflect is pushed only after that run has finished.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,957 expected passes, every pin ok. Nothing tested changed: CHANGELOG.md, README.org and the ledger only.

MERGED to main on 2026-10-04, on the owner's "Do closing ritual": **v0.3.0's release** (the entry above). 8417043 was squashed as 5528fa4 (tree the tested tip's, 10c3a80, parent fe75671).
- **CI.** Its run, 37249880109, passed on 8417043: fifty-one suites, 1,957 expected passes on ubuntu-24.04, the seven pins checked twice (their own step and the test step). Main's run on the squash, 37250152054, passed too, with the same counts, before the tag.
- **Branches.** `--delete-branch` deleted the remote branch, switched this checkout to main and fast-forwarded it, and deleted the local branch. No PR is open.
- **TAGGED v0.3.0** on 5528fa4, annotated as v0.2.0 was ("chez-http-server v0.3.0 — a taker can wait", its body pointing at CHANGELOG.md's `[0.3.0]`), and pushed: `git ls-remote --tags` shows the tag object a6ea07d and its commit 5528fa4. No GitHub Release, as for v0.1.0 and v0.2.0.
- **This reflect was pushed after main's run on the squash had finished,** so it cancelled nothing (9b1a421's run had been cancelled that way).

`make test` green on main: fifty-one suites, 1,957 expected passes, every pin ok.

NEXT: chez-websocket's skeleton, in its own repository (plan §15), pinning chez-http-server at v0.3.0, when the owner asks. Its CI needs the owner's `SUBMODULES_READ_TOKEN` secret there, able to read chez-http-server and its four private dependencies. CHANGELOG.md's Unreleased is empty.

**`check-pins` names a checkout that was never cloned `<absent>`, on `fix/check-pins-absent-checkout` (2026-10-05),** on the owner's word ("apply the same fix to chez-http-server's Makefile check-pins"), after chez-websocket's M0-4b found the same shape in its own `check-pins`.
- **Measured first** (Darwin arm64, git 2.50.1). A checkout was made never-cloned by moving it aside and leaving its empty directory, the placeholder an uninitialized submodule leaves (`git submodule status` shows `-`). There `git -C` does not fail: it climbs to the repository around it and answers for that one.
  - `check_pin` named the server's own commit: `PIN MISMATCH: vendor/chez-srfi at b9663fe…`, and the same for uriparse. With chez-httparse's byte-machine absent, it named chez-httparse's commit, `at 0b7058e…`.
  - With `SRFI_PIN` set to the server's HEAD on the command line, an absent chez-srfi passed: `pin ok: vendor/chez-srfi b9663fe…`, exit 0.
  - The dirty loop read the server's status. With chez-srfi absent and one byte appended to README.org, it answered `PIN DIRTY: vendor/chez-srfi`.
  - With uriparse absent, the nested read named `HEAD:vendor/byte-machine`. The climbed read found no such path in the server's tree, and `rev-parse` without `--verify` prints an argument it cannot resolve. uriparse at its root commit, a32de37, which records no byte-machine, was named the same way.
- **Fixed in chez-websocket's form.** `check_pin`, the nested read and the dirty loop each ask for the checkout's own `.git` first. A checkout without one is `<absent>`, and the dirty loop skips it. The nested read also reads with `--verify`. A comment above the target says why.
- **Not `git submodule deinit`.** In this worktree the submodules' sections live in the shared `.git/config`, which the main checkout reads too, and deinit removes a submodule's section. Moving the checkout aside leaves the same directory and edits no config; check-pins reads none. The shared config's submodule entries were compared before and after: unchanged.
- **Watched to fail.** Four mutants of the fixed recipe, one edit each, cut by exact match. Each ran with `make -f` in eight scenarios; after each setup the checkout went back and every pin was proven ok.

| mutant | the edit | red |
|---|---|---|
| CP-A | `check_pin` reads without asking for `.git` | chez-srfi absent: `at b9663fe…`; `SRFI_PIN` = the server's HEAD: `pin ok`, exit 0; uriparse absent: `at b9663fe…`; chez-httparse's byte-machine absent: `at 0b7058e…`; the superproject below: `at` its own commit |
| CP-B | the dirty loop reads without asking for `.git` | chez-srfi absent, README.org edited: `PIN DIRTY: vendor/chez-srfi`; the superproject below, whose HEAD records a byte-machine its tree lacks: `PIN DIRTY: vendor/uriparse` |
| CP-C | the nested read without asking for `.git` | a scratch superproject holding a byte-machine gitlink of its own, at the pin, with uriparse not cloned: `pin ok: vendor/uriparse was released with byte-machine c338a57…` |
| CP-D | the nested read without `--verify` | uriparse at a32de37: `released with byte-machine HEAD:vendor/byte-machine` |

  Each mutant's full output was diffed against the fixed recipe's in every scenario: each changed only its own guard's lines, and the code before the fix changed exactly their union. With every pin present, all six recipes pass. With uriparse absent on this tree, CP-C and CP-D both still read `<absent>`: the guard and `--verify` each hold that case alone, since the server's tree has no `vendor/byte-machine` for a climbed read to find. Each is red where it alone holds. CP-C's case was built in scratch, because this tree reaches byte-machine only through chez-httparse's copy.
- **Records.** This entry only. No CHANGELOG entry: nothing a client or an embedder meets changes. README.org's sentence on `check-pins` still holds.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,957 expected passes, every pin ok.

MERGED to main on 2026-10-05, on the owner's "CI is green, do closing ritual": **`check-pins` names a checkout that was never cloned `<absent>`, PR #134** (the entry above). e2df861 was squashed as 7cf4fec (tree b4d541a, the tested tip's; parent b9663fe).
- **CI.** Its run, 37290538059, passed on e2df861: fifty-one suites, 1,957 expected passes on ubuntu-24.04, the seven pins checked twice. Main's run on the squash, 37292190293, passed too, before this reflect was pushed.
- **Branches.** Merged from this session's own worktree without `--delete-branch`, since the shared checkout holds `main`. That `main` was fast-forwarded behind the guard (on `main`, no tracked changes), and the branch was deleted on the remote and here. No PR is open.

`make test` green on main: fifty-one suites, 1,957 expected passes, every pin ok.

NEXT: a new milestone or fix here, when the owner asks. chez-websocket's skeleton is merged in its own repository (its #1 to #3, 2026-10-05), pinning this server at v0.3.0 (5528fa4), and its work goes on there (plan §15). CHANGELOG.md's Unreleased is empty: this fix is tooling only.

**`make prod` runs the suite on the prod shim, and checks it did, on `fix/prod-on-prod-shim` (2026-10-05),** on the owner's ask, after chez-websocket's M0-13 (its 4f44296) found the same shape in its own `make prod`.
- **Measured first** (Darwin arm64, GNU Make 3.81, Chez 10.4.1, libuv 1.52.1). `prod` built and checked chez-libuv's prod shim, then ran `make test`. That target's `deps` asks chez-libuv for its default flavor, dev, and chez-libuv's relink-guard relinks a shim built at the other flavor. The closing `check-prod` went in alone first, and `make prod` was red, exit 2:
  - chez-libuv's own `check-prod` passed on its `-O2` link;
  - the suite's build printed `relink-guard: shim provenance changed (flavor=dev, acquisition=pkgconfig); relinking` and linked with `-g -O0 -DCHEZ_LIBUV_DEBUG_COUNTERS`;
  - the suite passed on that dev shim: fifty-one suites, 1,957 expected passes, `make test`'s own counts;
  - the closing check failed: `check-prod: FAIL: the counters moved while the probe's scope was live: ((loop . 1) (tcp . 1) …)`.
- **Fixed in chez-websocket's form.** The suite runs with `FLAVOR=prod`, which make hands to chez-libuv's build by itself, so `deps` has no pass-through (chez-websocket's first fix had one, and its mutant, M0-12, survived). `check-prod` depends on nothing, so the closing call reads the shim the suite ran on. The help text says what the target does, and a three-line comment says why.
- **Green**, exit 0. The two `check-prod` runs pass with no relink-guard line and no second link between them. The suite names the shim it ran on: the shell suite prints "chez-libuv's counters are off in this build" five times and the clients suite once. Those six checks are the only difference from a dev run: fifty-one suites, 1,951 expected passes (shell 190 for 195, clients 35 for 36, every other suite the same).
- **Watched to fail.** Three mutants of the fixed Makefile, one edit each, cut by exact match. PF-A and PF-B ran with `make -f`, so the Makefile itself stayed fixed; PF-B started from the dev shim `make test` leaves. CH ran in a scratch copy, since `check-help` reads the file named `Makefile`.

| mutant | the edit | result |
|---|---|---|
| PF-A | the suite runs without `FLAVOR=prod`, as first written | red, exit 2: the suite's build relinks a dev shim (`flavor=dev`), the suite passes on it (1,957), and the closing `check-prod: FAIL: the counters moved …` |
| PF-B | the leading `$(MAKE) -C $(LIBUV_DIR) prod` dropped | survives, exit 0: the suite's own build relinks at prod (`relink-guard: … (flavor=prod, …)`, `-O2`), the six counter checks are skipped by name (1,951), and the closing `check-prod` passes |
| CH | `prod`'s `## ` help text made a plain comment | red: `check-help: 'prod' has no '## ' description`, exit 2 |

  PF-B survives because make hands `FLAVOR=prod` down: in its run the one `-O2` link was the suite's own build. So the verdict no longer rests on the leading line. The line stays, as in the owner's form of the fix and in chez-websocket's: chez-libuv's `prod` links from a clean tree and checks the shim before the suite starts. This survivor is a scope statement, measured.
- **Not fixed here.** On a checkout whose submodules were never cloned, `make prod` stops at its first line: ``make[1]: *** No rule to make target `prod'.  Stop.``, exit 2. `prod` reaches chez-libuv's make before anything runs `submodules`. This was measured on this worktree before `make submodules`, and is left for the owner, to keep this change to the recipe.
- **Records.** This entry only. No CHANGELOG entry: nothing a client or an embedder meets changes, and README.org does not name `make prod`.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,957 expected passes, every pin ok.

MERGED to main on 2026-10-05, on the owner's "CI is green, do closing ritual": **`make prod` runs the suite on the prod shim, and checks it did, PR #135** (the entry above). d9679b0 was squashed as eb7adc2 (tree 1f91429, the tested tip's; parent f4adaef).
- **CI.** Its run, 37292824065, passed on d9679b0: fifty-one suites, 1,957 expected passes on ubuntu-24.04, the seven pins checked twice. CI runs `make test`, never `make prod`. Main's run on the squash, 37293220131, passed too, before this reflect was pushed.
- **Rebased twice before the merge.** Main moved under the branch twice, with #134's squash 7cf4fec and then its reflect f4adaef. Each time the branch met main only at this file's end, and was resolved as main's text followed by the entry above. `make prod` (fifty-one suites, 1,951) and `make test` (1,957) were run again on the rebased tree, d9679b0.
- **Branches.** Merged from this session's own worktree without `--delete-branch`, since the shared checkout holds `main`. That `main` was fast-forwarded behind the guard (on `main`, no tracked changes), and the branch was deleted on the remote and here. No PR is open.

`make test` green on main: fifty-one suites, 1,957 expected passes, every pin ok.

NEXT: a new milestone or fix here, when the owner asks. The entry above's "Not fixed here", `make prod` on a checkout whose submodules were never cloned, is offered as a task of its own, to start from this merge. chez-websocket's work goes on in its own repository (plan §15). CHANGELOG.md's Unreleased is empty: this fix is tooling only.

**`make prod` clones the submodules first, on `fix/prod-on-fresh-clone` (2026-10-05),** on the owner's ask: the "Not fixed here" of #135's entry, cut from f761ec7 once #135 had merged.
- **Measured first** (Darwin arm64, GNU Make 3.81, Chez 10.4.1, libuv 1.52.1). A fresh worktree of `main` at f761ec7, its five submodules never cloned (`git submodule status` shows each with a leading `-`). `make prod` stopped at its first line: ``make[1]: *** No rule to make target `prod'.  Stop.``, then `make: *** [prod] Error 2`, exit 2. `prod` had no prerequisite, and its first line enters `vendor/chez-libuv`, still an empty directory. `test` reaches `submodules` only through `build` and `deps`, after that line. Nothing was cloned or built.
- **Fixed.** `prod` depends on `submodules`. The comment above it gains one sentence saying why, so the prerequisite is not dropped as one `test` already has.
- **Green**, exit 0 in 61 s, on the same worktree with the fixed Makefile laid in (blob 3d8ea52, this commit's):
  - `submodules` cloned all five and chez-httparse's byte-machine, each at its pin;
  - chez-libuv's `prod` linked the shim once, at `-O2`, and its `check-prod` passed;
  - the suite ran on that shim: fifty-one suites, 1,951 expected passes (shell 190, clients 35, the six counter checks skipped by name, as on a prod shim), every pin ok;
  - the closing `check-prod` passed.

  No relink-guard line appears anywhere in the run. The shim's one link comes before the first `check-prod`; the `-O2` lines between the two are vtest2's build.
- **On a cloned checkout** (this worktree), `make prod` passed too, exit 0 in 50 s. `submodules` printed its two commands and cloned nothing. The rest ran as above: one `-O2` link before the first `check-prod`, no relink-guard line, fifty-one suites and 1,951 expected passes, both `check-prod` runs passing.
- **Watched to fail.** One mutant of the fixed Makefile, cut by exact match. It ran with `make -f` in a second fresh worktree of f761ec7, never cloned, with the fixed Makefile laid in.

| mutant | the edit | result |
|---|---|---|
| FC | `prod`'s `submodules` prerequisite removed | red, exit 2: ``make[1]: *** No rule to make target `prod'.  Stop.`` at the first line; nothing cloned |

  FC is the rule as it stood, with the new comment: its red is the one measured first. CI runs `make submodules` as a step of its own, then `make test` and `make check-help`, and never `make prod`, so CI would not see FC: only a `make prod` on a fresh clone does.
- **Shared state.** No `git submodule deinit`: in a linked worktree it edits the common `.git/config`, which the main checkout reads. The never-cloned checkouts were fresh worktrees in this session's scratchpad, removed after. The common config's `submodule.*` lines were the same before and after.
- **chez-websocket has the same shape** at its `main`, 33534e7. Its `prod` has no prerequisite, and its first line enters `$(SERVER_DIR)/vendor/chez-libuv`, inside the server's own submodule. In a scratch clone of that commit, never cloned below, `make prod` stopped there, exit 2, with another message: `make: *** vendor/chez-http-server/vendor/chez-libuv: No such file or directory.  Stop.`. Not changed here. Its `submodules` clones the server and the pins inside it, so the same prerequisite is the likely fix there; not measured.
- **Records.** This entry only. No CHANGELOG entry: tooling only, as #134 and #135 were. README.org does not name `make prod`.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,957 expected passes, every pin ok.

MERGED to main on 2026-10-05, on the owner's "do closing ritual": **`make prod` clones the submodules first, PR #136** (the entry above). 203d74e was squashed as 97c12f5 (tree ccfcf99, the tested tip's; parent f761ec7).
- **CI.** Its run, 37294605408, passed on 203d74e: fifty-one suites, 1,957 expected passes on ubuntu-24.04, the seven pins checked twice. CI runs `make test`, never `make prod`. Main's run on the squash, 37296038720, passed too, before this reflect was pushed.
- **Branches.** Merged from this session's own worktree without `--delete-branch`, since the shared checkout holds `main`. That `main` was fast-forwarded behind the guard (on `main`, no tracked changes), and the branch was deleted on the remote and here. No PR is open.

`make test` green on main: fifty-one suites, 1,957 expected passes, every pin ok.

NEXT: a new milestone or fix here, when the owner asks. The entry above's chez-websocket gap, its `make prod` on a checkout never cloned, is a task of its own in that repository, begun 2026-10-05. CHANGELOG.md's Unreleased is empty: this fix is tooling only.

**A number is written in ASCII digits alone, on `fix/numeric-settings-ascii-digits` (2026-10-05),** on the owner's ask, after chez-websocket's M3.1 read its own variables in ASCII digits alone (its `(websocket limits)`, open as its #16).
- **Measured first** (Darwin arm64, Chez 10.4.1, the session scratchpad's `measure/`). `parse-exact` read every numeric variable with `(string->number s 10)` and kept any exact integer within the field's bounds. Chez reads a number's own prefix over the radix it is given, and more than digits as an exact integer: `+5` 5, `-0` 0, `#x1F90` 8080, `#b101` 5, `#o17` 15, `#d10` 10, `#e5` 5, `#e1e3` 1000, `#e10.0` 10, `#e#x10` 16, `10/2` 5, and `5+0i` and `5@0` 5. The ask expected `#e1e3` and `10/2` to read so; both were measured before a check relied on them.
  - Each of the 19 numeric variables, set alone to a value inside its bounds (the high water's at or above the low water's default), took twelve such spellings. Nine took `-0` too: the six timeouts, the low water, the body cap and the port. That is 237 pairs. `CHEZ_HTTP_PORT=#x1F90` listened on 8080.
  - Already refused: a space before or after, a word, an inexact number (`1e3`, `1.5`, `10.`, `#i5`), `#16r10`, U+0663 and U+FF15, a negative number, a value out of bounds. `char-numeric?` takes U+0663 and U+FF15 for digits; `string->number` reads neither.
  - Every `CHEZ_HTTP_` value set in this repository's tests, docs and scripts is plain digits.
- **DECIDED on the owner's word (2026-10-05), by form:** "ASCII digits only", the recommended option: one or more of `0` to `9`, leading zeros allowed, anything else refused at startup, naming the variable. Weighed: "Keep Scheme syntax, document", no code change; "Warn now, refuse later", not prototyped, since the pure library would have handed warnings to the shell. Recorded as decision 0005's amendment of 2026-10-05, with a dated note in 0012 for the port.
- **Tests first.** The limits suite gains:
  - four malformed checks, one for each reader's variables (the six timeouts; the tick and the ten sizes and counts; the body cap; the port), each variable alone against fifteen malformed values, the port's `#x1F90` beside them;
  - a check that those groups cover every variable but the Host switch;
  - two leading-zero checks, `007`, `0100`, `00` and `08080`.

  The serve suite's start-failure check gains a row, `CHEZ_HTTP_PORT=#x1F90`. Against main's library: fifty-one suites, the five predicted failures (limits 55 passes and 4 failures, serve 17 and 1), 1,959 expected passes. A scratch prototype of the fix: fifty-one suites green, 1,964.
- **Built.** `digits?`, one or more of `#\0` to `#\9`, runs first in `parse-exact`, the one parser `env-integer`, `env-seconds->ms`, `env-max-body` and the port share, and refuses with "expected a whole number in ASCII digits", naming the variable. The guards `n`, `integer?` and `exact?` go: on digits alone `string->number` answers an exact whole number. The bounds and their refusal are unchanged.
- **Watched to fail.** Seventeen rows, sixteen mutants and the unmutated tree, every red set named before the run and each as named (m8-mutations.md, "After M8 — a number in ASCII digits alone"). ND-EMPTY, `digits?` taking the empty string, survives: no reader parses an empty value. In that run, four at a time, the unmutated tree also reddened one shell check on the loop's real clock, "… is closed at the drain's deadline, on time"; run again alone, and under six busy loops beside main's code, it was green every time.
- **Records.** Decision 0005's amendment of 2026-10-05 and 0012's note of the day. `docs/configuration.org` says how a number is written. CHANGELOG.md's Unreleased gains a "Changed" entry: a value 0.3.0 accepted is refused, so the next release is 0.4.0.
- `make test` green before the commit (Darwin arm64): fifty-one suites, 1,964 expected passes, every pin ok.

MERGED to main on 2026-10-05, on the owner's "do closing ritual": **a number is written in ASCII digits alone, PR #139** (the entry above). aad0af7 was squashed as 1b5d1af (tree 3511598, the tested tip's; parent 64761cb).
- **CI.** Its run, 37374547037, passed on aad0af7: fifty-one suites, 1,964 expected passes on ubuntu-24.04, the seven pins checked twice. Main's run on the squash, 37375177991, waited in a GitHub Actions outage, queued from 21:19Z. On the owner's word, by form ("Wait for Actions"), this reflect was held until that run had passed, since a push to `main` cancels the run before it (`cancel-in-progress`).
- **Branches.** Merged from this session's own worktree without `--delete-branch`, since the shared checkout holds `main`. That `main` was fast-forwarded behind the guard (on `main`, no tracked changes, only `claude` and `zsh` running in it), and the branch was deleted on the remote and here. Two other sessions' PRs stay open, #137 (CI on Node 24) and #138 (the ledger archived by milestone), and both touch this file: #137 appends an entry at its end, as this one did, and #138 moves out what lies before the entries since v0.1.0. Each rebases onto this merge with main's text first, the convention #138's body states.

`make test` green on main: fifty-one suites, 1,964 expected passes, every pin ok.

NEXT: a new milestone or fix here, when the owner asks. CHANGELOG.md's Unreleased holds this change, a value 0.3.0 accepted now refused at startup, so the next release is 0.4.0. chez-websocket's work goes on in its own repository (plan §15).

**The ledger archived by milestone, on `docs/ledger-archive` (2026-10-05),** on the owner's form ("Archive closed milestones (Recommended)"; weighed: archive everything and keep a summary only, or an index with no moves), cut from 64761cb, and made again on 8c04320 once #139 had merged.
- **Measured first.** At 8c04320, `progress.md` was 5,330 lines and 768,415 B (sha256 d4f2a79e…83b70c0), and AGENTS.md asks for it to be read before every slice. Its parts, in bytes: the head and M-1 26,292; M0 15,630; M1 7,883; M2 108,948; M3 95,181; M4 72,797; M5 70,235; M6 155,632; M7 77,007; M8 74,048; the entries since v0.1.0 64,762. Only AGENTS.md names the file, so no link points into it.
- **Moved.** Lines 7 to 4989, M-1 to M8, went into nine files, `m0-progress.md` to `m8-progress.md`, each beside its milestone's mutation log. Each file has a six-line header naming the lines it holds. Every cut falls on a blank line between entries, and M-1's entries share `m0-progress.md`.
- **What stays.** This file keeps:
  - its six header lines;
  - a table of the closed milestones. Each row's PRs and closing squash come from main's log, and its counts from the milestone's last `make test` on main;
  - the entries since v0.1.0, #118 to #139.
- **AGENTS.md** says where the archives live, and that at each release the entries before it move out, verbatim. Taken literally: the entries since v0.1.0 stay now, as the form said, though v0.2.0 and v0.3.0 are cut, and the rule applies from the next release.
- **Proved.** Concatenated, the six header lines, each archive past its header and this file's last 341 lines equal the original byte for byte (`cmp`). Before this entry the file was 66,462 B.
- **Watched to fail.** Three mutants of the split, each red, the split itself green:
  - a line dropped from `m4-progress.md`;
  - `m5-progress.md` and `m6-progress.md` swapped;
  - `m7-progress.md`'s last line dropped.
- **Records.** This entry only. No CHANGELOG entry: the ledger is the project's process, not anything a client or an embedder meets.
- **Made again** on 8c04320: #139's merge and reflect appended to the file's end. Its lines 1 to 4989 are byte-identical to 64761cb's, the old file a byte prefix of the new, so the nine archives are byte-identical to the first cut's, and only the part kept grew. The proof and its three mutants were run again on the new file, green and red as before.

**CI's actions run on Node 24, on `chore/ci-node24-actions` (2026-10-05),** on the owner's form ("CI off Node 20"), cut from 64761cb.
- **Measured first.** Main's run on 64761cb, 37296266668, passed with one warning annotation: "Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/cache/restore@v4, actions/checkout@v4." GitHub's notice is its changelog of 2025-09-19.
- **Changed.** The five `uses:` lines: `actions/checkout@v4` to `@v7` (v7.0.1), and `actions/cache/restore@v4` and `actions/cache/save@v4` to `@v6` (v6.1.0), each floating major tag on its release's commit. At its tag, each declares `using: node24`, and keeps the inputs and outputs the job reads: `path` and `key`, `cache-hit` and `cache-primary-key`.
- **Read before the bump**, every release note from v4 to the tags:
  - checkout v6 keeps its token in a file of its own, included from this repository's `.git/config`. The submodules' clones never read that config: they authenticate through the step's `GIT_CONFIG_*` rewrite, as since #88.
  - checkout v7's breaking change refuses a fork's head under `pull_request_target` and `workflow_run`. This workflow uses neither.
  - cache v5 and v6 move to Node 24 and to ESM.
- **Checked locally** (Darwin arm64): actionlint 1.7.12 is clean before and after, and `make test` is green, fifty-one suites and 1,957 expected passes.
- **Watched to fail.** The red is main's annotation above, which names both actions. The green is this PR's run with no such annotation, read once it finishes and recorded at the merge.
- **Records.** This entry only. No CHANGELOG entry: CI only, nothing a client or an embedder meets.
- **Rebased** onto 8c04320, once #139 had merged, and again onto 4cdef7d, once #138 had archived this file by milestone: each time the branch met main only at this file's end, resolved as main's text followed by this entry. `make test` green again on the rebased tree: fifty-one suites, 1,964 expected passes.

**The guards' hoist, layer 1: the profile, chez-libuv #45, and one guard for a run of turns, on `feat/hoist-guards` (2026-10-05),** on the owner's forms. The first form asked for a profile ("Shell allocation profile"). The second chose "Hoist all six (Recommended)", "I file it (Recommended)" and "Ratchet in the load smoke (Recommended)". Cut from 64761cb.

- **Measured first** (Darwin arm64, Chez 10.4.1, libuv 1.52.1, oha 1.16.0). M8.4's spike on main gave 10,005 B a GET at one connection and 8,437 to 8,460 at 50 (`out/hoist-request-alloc.main-m8.run1.txt`). The session's other runs on main gave 10,001 to 10,009 and 8,458 to 8,466.
- **Where it goes.** Probes in a scratch build read `bytes-allocated` with the collector held off; a probe around nothing reads 0 B.
  - The core and the parser: 2,052 to 2,053 B, on oha's own 124-byte GET served as the gate serves one (`hoist-core-share.sps`).
  - chez-libuv: about 3.3 KB.
  - The shell and the scheduler: the rest, about 4.6 KB.

  Most of the last two is protection around the work, none of it raising (`hoist-guard-cost.sps`): a `guard` costs 288 B, 672 under 100 frames and 4,256 under 1,000; `with-exception-handler` 160; `call/1cc` with it 256; `dynamic-wind` 96.
- **Ablations**, each wrapper taken out with its protection, on M8.4's spike: a ceiling, not a fix. In B a GET, at 1 and 50 connections:
  - the turn's `guard`: −780, −90;
  - the scheduler turn's `dynamic-wind`: −295, −50;
  - `dispatch!`'s `guard` as `with-exception-handler`: −470 at 1 (at 50, ±300 between runs);
  - `drain!`'s `dynamic-wind`: −413, −415;
  - `send!`'s `guard`: −305, −300;
  - `call-handler!`'s `guard`: −430, −410;
  - the six: −2,740, −1,770;
  - chez-libuv's three: −1,165, −880;
  - all: −3,925, −2,740.
- **Filed** chez-libuv #45 (decision 0008's row and bullet). Its program is `libuv-callback-alloc.sps`. A write's round reads 3,462 to 3,509 B over five runs, at 1.0 to 1.5 runs a round.
- **Built, the turn level.**
  - `shell-run-turns!` turns the scheduler while work remains and `go-on?` holds, under one run loop's guard. The guard is set up again only after a callback's error, and a contract condition is raised again.
  - `serve`'s `run-until-stopped!` turns through it.
  - `scheduler-turn!` sets and leaves its phase with no `dynamic-wind`. Both of `run-guarded`'s arms set the phase back first, through `scheduler-turn-abandoned!`: a raise out of a turn's poll left it `'in-uv-run`.
  - `shell-turn!` is unchanged, one turn under its own guard.
- **Checks added**, four in the shell suite, through `run-turns-until` (`tests/shell-testing.sls`), which turns as `serve` does:
  - a run of turns, after an error in a callback, runs on and answers a request;
  - having logged the error and answered 200;
  - a contract condition is raised again, logged first;
  - after it, the next run answers a request and logs nothing more.
- **Watched to fail**, against every suite:

| mutant | the edit | result |
|---|---|---|
| L1-0 | unmutated, a comment | green, the clients suite once vtest was built in the worktree |
| L1-1 | the callback arm sets no phase back | red: the shell suite, 13, the new checks among them, and the two raising-callback checks before them |
| L1-2 | the contract arm sets no phase back | red: "and the next run of turns answers a request, logging nothing more" |
| L1-3 | a run of turns stops at a callback's error | red: the first two new checks |
| L1-5 | `serve`'s run never asks whether the server stopped | red: the serve suite, 4 (the drain's children and the taker's deferred dones) |
| L1-6 | a turn's poll is not `'in-uv-run` | red: the scheduler suite, 3, and the waits suite, 2 (R1's rows) |
| L1-7 | a turn's poll that returns leaves the phase `'in-uv-run` | red: the contract suite, 39, and more |

  Not run: the inner loop never asking `go-on?`, a run that never returns, which no check can stop but the runner's 600 s cap.
- **Measured on this layer**, `hoist-request-alloc.sps`, M8.4's spike turned as `serve` now turns: 8,624 to 8,630 B a GET at one connection, and 8,374 to 8,381 at 50 (`out/hoist-request-alloc.L1.run1.txt`). That is −1,375 and −80 against main. The loop now makes no closure a turn.
- `make test` green (Darwin arm64): fifty-one suites, 1,961 expected passes.
- **Rebased** onto 8c04320, once #139 had merged: the branch met main only at this file's end, resolved as main's text followed by this entry. `make test` green again on this layer's rebased tree: fifty-one suites, 1,968 expected passes.

**The guards' hoist, layer 2: one handler for a dispatch and its drain, on `feat/hoist-guards` (2026-10-05),** stacked on layer 1.
- **Built.**
  - The outermost dispatch, `dispatch-outermost!`, runs the step and the drain under one `with-exception-handler`. Its handler runs at the raise, before any unwinding: it abandons the drain (`abandon-drain!`), closes the connection and raises again.
  - This replaces `closing-on-raise`'s `guard` and `drain!`'s `dynamic-wind`. That was about 500 B a dispatch, three dispatches a request; the handler costs 160 B and captures no continuation, so a deep stack costs it nothing more.
  - `drain!` sets the depth to 1 and back to 0. `abandon-drain!` does what its after-thunk did on a raise: the depth 0, the phase before the dispatch, the queue and the held writes dropped. The after-thunk's other work on a normal exit put back what was already so.
  - `closing-on-raise` stays for the listener, the signals, an adoption and the timer's first start, none of them per request.
- **Measured** (`hoist-request-alloc.sps`): 7,724 to 7,727 B a GET at one connection, and 7,341 to 7,343 at 50 (`out/hoist-request-alloc.L2.run1.txt`). That is −900 and −1,035 against layer 1.
- **Watched to fail**, against every suite:

| mutant | the edit | result |
|---|---|---|
| L2-0 | unmutated, a comment | green |
| L2-1 | a raise does not close the connection | red: the shell suite, 14 |
| L2-2 | the handler returns where it raised again | red: "when one firing's ticks raise for both of two connections, … a contract condition is the raise the run loop raises again" (Chez raises its own non-continuable condition in the contract's place) |
| L2-6 | an abandoned drain keeps what is held | red: "with nothing written, the connection closed and gone, the error logged, the close its last event" |
| L2-7 | a drain that ends leaves the depth 1 | red: the shell suite. Its run over every suite waited out its caps and was stopped |
| L2-3 | an abandoned drain leaves the depth | survives, a scope statement |
| L2-5 | an abandoned drain keeps what is queued | survives, a scope statement |
| L2-4 | an abandoned drain leaves the phase | survives, a scope statement, as M7.1's M7R-5 did |
| L2-8 | the handler abandons nothing | survives, the three above at once, and L2-6's held write never sent |

  The scope statements:
  - A raise's connection is closed at once (`handle-close!` stops its reading and takes it out of the wheel). The only events it gets after that are a write's failed completion and `(closed)`, and the core's `on-closed` answers no action. A depth or a queue left behind has nothing left to run.
  - The phase is set back twice over: by `abandon-drain!`, and by the run loop's guard once the raise reaches it (layer 1).
- `make test` green (Darwin arm64): fifty-one suites, 1,961 expected passes.
- **Rebased** onto 8c04320 with layer 1: `make test` green again on this layer's rebased tree, fifty-one suites, 1,968 expected passes.

**The guards' hoist, layer 3: a handler's raise taken by the run loop's guard, on `feat/hoist-guards` (2026-10-05),** stacked on layer 2.
- **Built.**
  - `call-handler!` sets the shell's new `calling` field to the connection while the handler and `answered` run, and clears it before the answer is dispatched. It has no `guard` of its own.
  - `run-guarded`'s first arm takes any raise while `calling` is set, a contract condition among them, as that handler's failure (`handler-failed!`). That logs `handler-failed` and dispatches `(handler-failed e)`, under the run loop's guard again, so a raise from either is a callback's, as before. The turn then answers #t, and what the drain had still to run runs at the next turn.
- **What changed for a check.** Three shell checks turned the loop with no run loop's guard (`wait-for`, `loop-turn!`), the one way `serve` never turns it. They now turn it as `serve` does (`run-turns-until`): an ordinary handler that waits, a handler that raises, and one that raises a contract condition. `loop-turn!`, which only the tests use, no longer makes a handler's raise its failure.
- **Checks added**, three in the shell suite:
  - a handler that raises a contract condition is answered 500, logged as its failure alone, and the server runs on (the arm comes before the contract arm);
  - a bug in the dispatch of a handler's failure is logged as a callback's after it, its connection closed with nothing written, the run loop running on;
  - the `/raise` route's check now turns as `serve` does.
- **Departure from the form: `send!` keeps its `guard`.** A write libuv refuses at the call must become that connection's read error and let the drain go on, so its catch has to resume inside the libuv callback (the shell suite's "a write refused when it is issued" checks). Hoisted to the dispatch, it needs `call/1cc` there (256 B on every outermost dispatch, three a request), more than the one `guard` a write it replaces. Left as it is, with the alternatives put to the owner.
- **Measured** (`hoist-request-alloc.sps`):
  - Darwin arm64: 7,332 to 7,337 B a GET at one connection, and 6,973 to 6,980 at 50 (`out/hoist-request-alloc.L3.run1.txt`). That is −390 and −365 against layer 2, and −2,670 (−27%) and −1,470 (−17%) against main.
  - Linux aarch64, in Docker (`chez-libuv-valgrind:10.4.1` by ID, libuv 1.44.2): 7,333 to 7,340 and 6,967 to 6,969 (`out/hoist-request-alloc.L3.linux-aarch64.run1.txt`), the same.

  There, fifty suites passed. The clients suite stopped at its harness, since vtest is not built in that image.
- **Watched to fail**, against every suite:

| mutant | the edit | result |
|---|---|---|
| L3-0 | unmutated, a comment | green |
| L3-1 | the handler's arm after the contract arm | red: the shell suite, 5, the contract handler's checks first |
| L3-2 | a handler that answers leaves `calling` set | red: the shell suite, 13 (every later raise taken as that handler's) |
| L3-3 | a handler's failure leaves `calling` set | red: "when the dispatch of a handler's failure raises, …" |
| L3-4 | `calling` is never set | red: the contract suite, 12, and the shell suite |
| L3-5 | the failure's log and dispatch not under the run loop's guard | red: "when the dispatch of a handler's failure raises, …" |
| L3-6 | the failure is not logged | red: the shell suite, 4 |
| L3-7 | the failure is not dispatched | red: the contract suite, 12, and the shell suite |

- `make test` green (Darwin arm64): fifty-one suites, 1,964 expected passes.
- **Rebased** onto 8c04320 with layers 1 and 2: `make test` green again on this layer's rebased tree, fifty-one suites, 1,971 expected passes.
- **Decided by form after the plan-vs-landed walkthrough** (2026-10-05): "Keep it (Recommended)", `send!`'s guard as it is; and "Accept (Recommended)", the drain's other calls running after a poll once a handler raises. Weighed: also asking chez-libuv for a write that returns its status, or a refused write taken as a bug; and keeping call-handler!'s guard with the ratchet at 8 KiB.

**The guards' hoist, layer 4: the whole server's ratchet, on `feat/hoist-guards` (2026-10-05),** stacked on layer 3, by the owner's form ("Ratchet in the load smoke (Recommended)", set once the hoist landed).
- **Built.** The clients suite measures what a GET allocates through the whole server, after the load smoke:
  - a server of its own, on a loop of its own, its handler answering one response made once;
  - oha's 2,000 and 7,000 GETs on one connection kept alive, the loop turned as `serve` turns it (`shell-run-turns!`) with nothing else on it, each read off `sstats-bytes` (`allocated-over`);
  - the difference over 5,000 is held to `get-ratchet`, 7,680 B (7.5 KiB), and printed.
- **The value, derived.** The most measured by `hoist-request-alloc.sps` was 7,337 B on Darwin arm64 and 7,340 on Linux aarch64, so 7,680 is 340 B over it. The suite's own reading was 7,312 to 7,343 over four runs. Decision 0002's amendment of 2026-10-05 records it. CHANGELOG.md's Unreleased says a request allocates about a quarter less.
- **Watched to fail**, each mutant undoing one layer, against the clients suite:

| mutant | the edit | the suite's reading | result |
|---|---|---|---|
| R-0 | unmutated, a comment | 7,316 B | green |
| R-1 | layer 1 undone: a run of turns sets a guard up every turn (`shell-turn!`) | 8,360 B | red: "a GET through the whole server allocates at most 7680 B, …" |
| R-2 | layer 2 undone: a guard and a `dynamic-wind` around every outermost dispatch | 8,145 B | red: the same |
| R-3 | layer 3 undone: a guard around every handler call | 7,727 B | red: the same |

  R-3 clears the ratchet by 47 B, against a spread of 31 B between the suite's runs.
- `make test` green (Darwin arm64): fifty-one suites, 1,966 expected passes; the clients suite read 7,343 B a GET.
- **Rebased** onto 8c04320 with layers 1 to 3, and the CHANGELOG entry joined #139's under one "Changed". `make test` green again on this layer's rebased tree: fifty-one suites, 1,973 expected passes; the clients suite read 7,312 B a GET.
- **Decided by form** (2026-10-05): "Four stacked PRs (Recommended)", one a layer, and "Comment with the spread (Recommended)": chez-libuv #45 gained a comment giving its first row over five runs (decision 0008).

MERGED to main on 2026-10-05, on the owner's "do closing ritual": **the six PRs of the day's side work, in the order the session recommended**: #138, #137, then #140 to #143 bottom-up.
- **#138, the ledger archived by milestone.** 5f6feff was squashed as 4cdef7d (tree a67c1f7, the tested head's; parent 8c04320).
  - Its run, 37376959282, passed: fifty-one suites, 1,964 expected passes.
  - Main's run on the squash, 37380218573, passed.
- **#137, CI on Node 24.**
  - Rebased onto 4cdef7d, meeting main only at this file's end, as 9444d7c. `make test` green there: fifty-one suites, 1,964.
  - Its run, 37380351798, passed with no annotation: fifty-one suites, 1,964.
  - Squashed as d7e5177 (tree a6518bf, the tested head's; parent 4cdef7d). Main's run, 37380563492, passed.
- **#140 to #143, the guards' hoist.** All four were replayed onto d7e5177. Outside this file, each layer's changes were byte-identical to its tested twin's, and its ledger was main's text followed by its entries. `make test` green at each layer: fifty-one suites, 1,968, 1,968, 1,971 and 1,973; the clients suite read 7,344 B a GET.
  - The heads' runs passed: 37380943402, 37380946396, 37380947690 and 37380949893. On ubuntu-24.04, the ratchet read 7,342 to 7,343 B (7,328 before the replay), the same as Darwin arm64 and Linux aarch64.
  - Bottom-up, each was squashed after main's run on the squash below had finished. Each was moved up from the PR-below's tip with `move-up.sh` (the tested tree, one commit on main), then merged once its run passed:
    - #140, 08af654, as 84f022e (main's run 37381187871);
    - #141, c03d454 (run 37381220115), as a26df3a (main's run 37381509178);
    - #142, 069704c (run 37381526078), as b4a575d (main's run 37381756184);
    - #143, 7dfb212 (run 37381775726), as 5117bc5 (main's run 37382010390).

    Every squash's tree is its tested head's, and its parent the squash below.
- **Branches.** Each PR's branch was deleted on the remote and here, and this session's three worktrees removed. The shared checkout's `main` was fast-forwarded behind the guard: on `main`, no tracked changes, only `claude` and `zsh` running there.

`make test` green on main: fifty-one suites, 1,973 expected passes; the clients suite read 7,344 B a GET.

THE CHEZ-LIBUV v0.7.4 PIN, on the owner's word ("chez-libuv version bumped to 0.7.4"). Branch chore/chez-libuv-v0.7.4, cut from main at f35e77c in a worktree of its own; 2026-10-08, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at 27d84bb.

UPSTREAM: chez-libuv tagged v0.7.4 (27d84bb; annotated tag 36c7c5d, 16:35 -0400; release PR #97), 34 commits past v0.7.3. GitHub's objects are the sibling checkout's. It lands our #45 (PRs #46 and #48; the issue closed 2026-10-06): one guarded seam per callback, fixed-arity seams, `uv-run` without `dynamic-wind`, status checks in the writes and the shutdown, and, of chez-libuv's own, libuv's alloc callback for reads answered in the shim. Decision 0008's row is LANDED, with its landing bullet: all twenty-four filed asks have landed. Besides #45, the release:
- makes the stream verbs, the constructors, `uv-accept!`, `uv-spawn!` and the process verbs one step that no engine splits;
- reads a caller's strings and lists once;
- locks the table that loops on several threads share (#70), claims a loop atomically in `uv-run`, its close and its teardown (#78), and refuses a verb that makes something on a loop off the loop's thread (#79);
- leaves a loop marked running when a continuation escapes one of its callbacks.

Checked against chez-libuv's history between the tags:
- no public library's export list changed: each library's `(export ...)` form was compared between the tags. Only the private ones changed, and `(libuv private c-string)` and `(libuv private lists)` are new. `tests/uv-testing.sls` is byte-identical;
- the shim changed (`src/libuv-shim.c` and `.h`), and `make test` rebuilt it through `deps`, its `cc` line in the log;
- the server's exposure: one loop on one thread and no engine (`src/` makes none). Its coroutines run on `call/1cc` outside `uv-run`, and its callbacks only wake them, so no continuation escapes a callback. `uv-tcp-bind!` now refuses an address holding a NUL; the server's comes from CHEZ_HTTP_HOST, an environment variable, judged an IP literal first.

Watched to fail: with the checkout moved and its gitlink staged, and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). With both moved, it passes.

`make test` green at v0.7.3 and at v0.7.4 on this branch: fifty-one suites, 1,973 expected passes, every suite's count the same. The clients suite read 7,342 B a GET at v0.7.3 and 5,156 B at v0.7.4.

MEASURED at both pins the same day, Darwin arm64:

| what | v0.7.3 | v0.7.4 | program |
|---|---|---|---|
| a write's round: a 16-byte `uv-write*!`, its completion, libuv's alloc callback and the peer's read, three runs | 3,535 to 3,566 B, 1.7 to 1.8 runs a round | 1,352 to 1,355 B, 1.6 to 1.8 | `libuv-callback-alloc.sps` |
| the `uv-write*!` call alone | 760 to 860 B | 376 to 408 B | the same |
| an idle `uv-run` | 128 B | 16 B | the same |
| a timer started and a run that fires it | 1,050 B | 513 B | the same |
| a GET through the whole server, one connection kept alive, two rounds | 7,333 to 7,334 B | 5,150 B | `hoist-request-alloc.sps` |
| the same at 50 connections | 6,973 B | 5,019 to 5,023 B | the same |

THE RATCHET: decision 0002's amendment of 2026-10-05 holds a GET to 7,680 B, 340 B over the most measured at v0.7.3, so that undoing any one of the guards' hoist's three layers reddens it. At v0.7.4 none does. The hoist's mutants, its session's specs (each cut matched once on this tree), against the clients suite:

| mutant | the edit | 2026-10-05, v0.7.3 | v0.7.4 | against 7,680 B |
|---|---|---|---|---|
| R-0 | unmutated, a comment | 7,316 B | 5,143 B | green |
| R-1 | layer 1 undone: a guard set up every turn | 8,360 B | 6,177 B | green, was red |
| R-2 | layer 2 undone: a guard and a `dynamic-wind` around every outermost dispatch | 8,145 B | 5,970 B | green, was red |
| R-3 | layer 3 undone: a guard around every handler call | 7,727 B | 5,526 B | green, was red |

Records: the Makefile's pin, test-integration's version comment, global-constraints, decision 0008 (the row and the landing bullet), CHANGELOG.md's Unreleased.

DECIDED on the owner's word (2026-10-08), by form: "5,376 B (Recommended)", the ratchet at 5.25 KiB, 220 B over the most measured, so that each layer's undoing reddens it again (weighed: 5,632 B, which lets R-3 pass, and keeping 7,680 B); and "Two stacked PRs (Recommended)": this PR the pin alone, the ratchet's on it.

THE RATCHET AT 5,376 B, on the owner's form, stacked on the pin. Branch test/get-ratchet-v0.7.4, on chore/chez-libuv-v0.7.4's tip.
- **The check:** `get-ratchet` in `tests/test-clients.sps` is 5,376 B (5.25 KiB), where it was 7,680; the check itself is unchanged. Its comment gives the derivation.
- **The value, derived.** The most measured at v0.7.4 is the suite's 5,156 B (five runs read 5,143 to 5,156; the spike read 5,150), so 5,376 is 220 B over it. Decision 0002's amendment of 2026-10-08 records it. CHANGELOG.md's line on the check moves from the hoist's entry to the pin's.
- **Watched to fail**, the hoist's mutants against the clients suite at the new value:

| mutant | the edit | the suite's reading | result |
|---|---|---|---|
| R-0 | unmutated, a comment | 5,156 B | green |
| R-1 | layer 1 undone: a guard set up every turn | 6,177 B | red: "a GET through the whole server allocates at most 5376 B, …" |
| R-2 | layer 2 undone: a guard and a `dynamic-wind` around every outermost dispatch | 5,944 B | red: the same |
| R-3 | layer 3 undone: a guard around every handler call | 5,513 B | red: the same |

  R-3 clears the ratchet by 137 B; over its two runs it read 5,513 and 5,526 B.

`make test` green (Darwin arm64): fifty-one suites, 1,973 expected passes; the clients suite read 5,156 B a GET.

MERGED to main on 2026-10-08, on the owner's "do closing ritual on both": **the chez-libuv v0.7.4 pin and its ratchet**, bottom-up.
- **#144, the pin.** 6a3146b was squashed as 48119b2 (tree 705da86, the tested head's; parent f35e77c), without deleting its branch, which #145 was based on.
  - Its run, 37853618232, passed on ubuntu-24.04: fifty-one suites, 1,973 expected passes; the clients suite read 5,143 B a GET, inside the 7,680 B it still held.
  - Main's run on the squash, 37857297226, passed.
- **#145, the ratchet.** Retargeted to main and rebased from 6a3146b onto 48119b2 as b2b5705, whose tree, aca5d87, is the tested head's (71d9ad7's); pushed with the lease read from `ls-remote`.
  - Its runs passed on ubuntu-24.04: 37853621818 on 71d9ad7, the clients suite reading 5,130 B a GET against 5,376, and 37857337031 on b2b5705, reading 5,156 B. That one was still running at the merge, which went on the identical tree's passed run and `make test`, as #55/#56's did; it passed afterwards.
  - Squashed as e03c42a (tree aca5d87, the tested head's; parent 48119b2). Main's run on it, 37857501058, passed.
- **Branches.** Both were deleted on the remote and here, and this session's worktree is removed once this reflect is pushed. The shared checkout's `main` was fast-forwarded behind the guard: on `main`, no tracked changes.

`make test` green on main: fifty-one suites, 1,973 expected passes; the clients suite read 5,131 B a GET.

NEXT: nothing is open upstream (decision 0008: all twenty-four filed asks have landed). chez-websocket's work goes on in its own repository.

**The second door change, decision 0024, as four stacked branches (2026-10-08):** `docs/0024-abort-and-every-line`, `feat/transport-abort`, `feat/request-header-values` and `docs/0024-ledger`, on the owner's forms in chez-websocket's M4.2 ("Server's fake shell", "Door change: abort", "Every line, in the release"), after its "Lets start the next step".
- **Measured first** (v0.3.0's door, unchanged on main since; Darwin arm64), in chez-websocket's scratchpad:
  - **A close a client that reads nothing holds open.** 16 MiB written to such a client, the close asked for, then a 300 ms deadline: the deadline passed at 496 ms, and the stream stayed open until the client left at 2,998 ms. A raise in the deadline's call closed it at 497 ms, logged `taker-failed`; a prototype abort at 498 ms, its write told `ECANCELED`, nothing logged.
  - **A field's first line only.** Through the fake shell's parse, by chez-websocket's handshake: a split `Connection` or `Upgrade` refused 400, a split `Sec-WebSocket-Protocol`'s later offers lost, and two `Sec-WebSocket-Key` or `Sec-WebSocket-Version` lines accepted, using the first.
  - **The fake's door differed from the libuv shell's** for a client that reads nothing: no deadline armed after the close, a raise in a deadline's call escaping to the test, a waiting thunk's raise closing only after its write, and the take-over unguarded.
- **DECIDED (0024).** `transport-abort!` closes a taken stream at once, dropping what is unsent; `request-header-values` gives every field of a name; the fake's door does what the libuv shell's does. Weighed and not taken there: the binding raising at its bound, a field's first line documented, chez-websocket reading the server's internal libraries.
- **Built.**
  - The libuv shell's abort is the handle's close, as a taker's raise has it; libuv tells each write outstanding `ECANCELED`. `make-transport` takes it as an eighth procedure; one made of seven refuses `transport-abort!`, naming it.
  - The fake: a taker's write is outstanding until its turn, so a test that delivers no later turn plays a client that reads nothing. The close waits for the writes, and disarms the deadline once begun; the abort begins it at once; every call into the taker's code is guarded, a raise recorded and the stream aborted.
  - `request-header-values`, in the view and the facade.
- **Tests first**, in two stages each (m8-mutations.md, "After M8 — a taker may abort its stream"): main's code stopped three suites at load, exit 255, not the run-time failures the prediction named; the API alone reddened exactly the five named once a test-isolation fault in the shell suite was fixed. Then the values layer, as named.
- **Mutants:** the abort layer's 24 rows (23 mutants), one mismatch, A-3's two leak-check knock-ons; the values layer's 6 rows, none. Every check added or changed has a killer by value.
- **Docs.** `docs/handlers.org`: the abort's row, a deadline that aborts in the advice, eight procedures for a fake, and `request-header-values`' row. CHANGELOG.md's Unreleased gains two Added and a Fixed (the fake's door).
- **Records.** Decision 0024, new; 0016 amended; the design's door note; plan §15.
- `make test` green on each layer (Darwin arm64): fifty-one suites, and 1,973, 1,980 and 1,981 expected passes; every pin ok.

NEXT: review and the closing ritual for the four, when the owner asks; then 0.4.0's release, for chez-websocket to pin (its M4.2).
