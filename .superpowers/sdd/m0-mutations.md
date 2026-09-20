# M0 — mutation log

Every test in M0 was watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), 2026-09-19.
Each suite was run alone with the M0 library path
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs`).

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M1 | `tests/test-flag-pins.sps` | `(define F-CONNECTION-CLOSE 2)` → `3` in `vendor/chez-httparse/src/httparse/decisions.sls` (simulates an upstream drift the pin exists to catch) | exit 1; 1 unexpected failure ("F-CONNECTION-CLOSE = 1<<1"), 7 pass |
| M2 | `tests/test-limits.sps` | idle default `75000` → `70000` in `default-limits` (`src/http-server/limits.sls`) | exit 1; 2 unexpected failures (the value assertion and the default==empty-env drift guard), 17 pass |
| M3 | `tests/test-headers.sps` | disable ASCII case-folding: `(+ b 32) b))` → `b b))` in `ascii-downcase-byte` (`src/http-server/headers.sls`) | exit 1; 5 unexpected failures (every case-insensitive lookup / `header-name=?` fold), 4 pass |
| M4 | `tests/test-records.sps` | swap the `request-method` and `request-target` accessors (`src/http-server/request.sls`) | exit 1; 2 unexpected failures ("method reads back", "target reads back"), 12 pass |
| M5 | `tests/test-integration.sps` | drop `vendor/uriparse/src` from the library path (the "all four" claim is load-bearing) | exit 255; `Exception: library (uri collect) not found` — the smoke cannot even load without the fourth library |

All five mutations were reverted; `make test` is green afterwards (55 expected
passes across the five suites, exit 0).

Notes:
- M1 is the pin test the brief names explicitly. It mutates the vendored
  constant rather than the test's oracle so the failure is exactly the drift
  the pin guards against; `make check-pins` still passed during the mutation
  (it checks the gitlink commit, not the working-tree bytes), which is why the
  value pin test is a separate, necessary guard.
- M2's two failures are the mutation's signature: the idle default feeds both a
  direct value assertion and the "`default-limits` equals the empty
  environment" drift guard, which are the two properties that depend on it.
