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
