# M1 — mutation log

Every test in M1 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §5 names five mutations across the four slices; they are
recorded here as each slice lands.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), 2026-09-20.
The M1 library path adds the corpus harness to M0's
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness`).
Mutations were run through `make test`; the suite-level exit is recorded (Chez's
status vocabulary), and `make` itself reports its own exit 2 whenever a recipe
fails, whatever the suite's status.

## M1.1 — the harness path, and the corpus counted

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M1.1-A | `tests/test-corpus-inventory.sps` | drop `$(HTTPARSE_DIR)/test/support/harness` from `LIBDIR_LIST` (`Makefile`) — the harness path M1.1 adds is load-bearing | suite exited 255; `Exception: library (httparse test corpus-load) not found` — the inventory cannot even load without the harness directory. The other five suites were unaffected |
| M1.1-B | `tests/test-corpus-inventory.sps` | remove the `"pause"` key from the first fixture's meta (`on_message_begin`, line 6) in `vendor/chez-httparse/test/vendor/llhttp/request/pausing.md` — a vendored-byte edit, witnessed and reverted | suite exited 1; 6 expected passes, 1 unexpected failure ("13 pause keys in the strict lane"; the count fell to 12). The file/total/request/noScan/skipBody/byte assertions all held — the fixture stayed `type=request`, so only the pause tally moved |

M1.1-A witnesses §3.2's obligation: the corpus harness lives under
`test/support/harness`, not `src/`, so adding it to the path is the change the
slice exists to make. M1.1-B is the §2.1 trap made a check: the inventory reads
each fixture's `pause` meta (a string, tested for presence), not filenames, so
dropping one key moves the tally by exactly one and touches nothing else.

Both mutations were reverted — the `Makefile` edit reversed, `pausing.md`
restored with `git -C vendor/chez-httparse checkout --` (byte-identical,
submodule clean). `make test` is green afterwards: six suites, 62 expected
passes (corpus-inventory 7, flag-pins 8, headers 9, integration 5, limits 19,
records 14), exit 0.

## M1.2 — the trace lane

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M1.2 | `tests/test-trace-lane.sps` | perturb our rendering shim `render-trace` to drop the `off=N ` field from the first rendered line of every trace | suite exited 1; 2 expected passes, 1 unexpected failure. `trace-compare` reported the difference richly for each strict fixture — `request/connection.md#1 size 1: line 0 expected "off=0 message begin" got "message begin" (line-differs)` — the differing index, expected, actual and reason, never a bare `#f` |

The mutation is on OUR code, not the vendored `trace-format`: `render-trace` is
the thin shim the trace lane renders through, kept ours on purpose (design §8.1
makes `trace-format` the shared vocabulary and the driving/rendering around it
ours). A comparator that answered `#f` to a real difference would have gone
unnoticed — which is the failure this mutation exists to rule out. The
135-fixture and scan-run assertions stayed green, so the mutation broke only the
property under test.

Reverted; `make test` green afterwards: seven suites, 65 expected passes
(corpus-inventory 7, flag-pins 8, headers 9, integration 5, limits 19,
records 14, trace-lane 3), exit 0. The release lane (`CORPUS=full`) is green at
9,394 runs, 0 mismatches.

## M1.3 — libhtp's streams, and the first provenance failure

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M1.3 | `tests/test-libhtp.sps` | corrupt one sha256 in `test/vendor/libhtp/PROVENANCE` — flip the LICENSE hash's first hex digit (8→9) | suite exited 3; `PROVENANCE-ERROR libhtp: LICENSE: expected sha256 97c9… but computed 87c9…`. The first `provenance-failure` (status 3) ever raised in this repository — §4 flagged status 3 as an untested branch of the harness until this slice |

The mutation is on the manifest, the thing under test: a checksum that no longer
matches the bytes it certifies, not the test's own oracle. The three FIPS-180-4
sha256 vectors and the 103-entry manifest-parse assertion ran first (4 passes),
then `verify-provenance!` aborted the suite — a provenance failure ends the run
rather than recording a recoverable assertion, which is why it is a bare call
outside any `test-*` form (a raise inside a SRFI-64 form is swallowed into `#f`,
`(testing)`'s documented footgun). Reverted (the hash restored); `make test`
green afterwards: eight suites, 76 expected passes, exit 0.

## M1.4 — the fake shell, and the ratchet opened

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M1.4-A | `tests/test-fake-shell.sps` | in `fake-shell.sls`, record actions with `fold-right` instead of `fold-left`, reversing each event's action order | suite exited 1; 11 passes, 1 failure ("multi-action steps record in order"). The single-action, event-order, clock and state assertions held — only intra-event action order broke |
| M1.4-B | `tests/test-ratchet.sps` | flip `libhtp/files/00-adhoc.t` from not-yet to passing in `ratchet.txt` — a lane with no comparator | suite exited 1; `RATCHET VIOLATION libhtp/files/00-adhoc.t: marked passing but does not pass`, and the libhtp not-yet count fell to 101 → 2 failures. The **regression** arm of the two-way gate |
| M1.4-C | `tests/test-ratchet.sps` | flip `trace/request/connection.md#1` from passing to not-yet in `ratchet.txt` — a lane whose comparator does pass it | suite exited 1; `RATCHET VIOLATION trace/request/connection.md#1: marked not-yet but now passes`, and the trace passing count fell to 134 → 2 failures. The **improvement** arm of the two-way gate |

M1.4 has two suites, and the ratchet's defining property is that it gates BOTH
directions (decision 0008 item 6), so it is witnessed in both: B is an unbacked
promotion (marked passing where no comparator passes it), C is an unexplained
improvement (a comparator that passes a fixture marked not-yet). Each ratchet
flip trips the gate AND the lane's opening-count assertion — the two-failure
signature, as M0's mutation M2 did for the limits drift guard. All three
reverted; `make test` green afterwards: ten suites, 95 expected passes, exit 0.

The plan (§5) estimated one mutation for M1.4; it took three. The fake shell is
its own suite and global-constraints requires every test to be watched to fail
(+1), and a two-way gate is only proven by witnessing both arms (+1). M1's five
named mutations are therefore **seven** — a measured correction to the plan's
count, in the spirit of §10 (a ceiling is a bucket count until the slice runs).
