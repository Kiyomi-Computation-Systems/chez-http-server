# 0018: oha is the load smoke's client, its release binary fetched at a pinned version and checked by sha256

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, by form: "Pinned binary, checked")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M8.4

## Context

Plan §14's M8.4 has oha's load smoke give the first throughput numbers. Its own check is
that every response is answered and none failed. The plan's mutation is a shell that
drops one write in a thousand. The brief names oha as the load client.

oha is an HTTP load generator written in Rust, MIT-licensed, at hatoo/oha on GitHub.
Its release v1.16.0 (2026-08-23) publishes binaries for macOS and Linux, amd64 and
arm64, and for Windows amd64. The release has no checksum file, but GitHub records a
sha256 for each file it serves.

Global constraints: "No other dependencies without a decision record."

Measured 2026-10-04, on Darwin arm64 (an Apple M1):
- **The release binary.** The files are 10,268,912 B (macOS arm64), 11,824,848 B (macOS
  amd64), 13,429,032 B (Linux amd64) and 11,516,216 B (Linux arm64). `make oha` fetched
  the first in 0.56 s. Each of the release's seven files, downloaded, had the sha256
  GitHub records for it.
- **From source.** `cargo install oha --version 1.16.0 --locked`, into an empty cargo
  home, took 133 s (440 s of CPU), built 225 crates from 304 MB of downloads, and made
  a 17 MB binary. oha declares Rust 1.88 or later.
- **Its report.** With `--output-format json`, oha writes the responses it counted by
  status (`statusCodeDistribution`), the requests that failed by kind
  (`errorDistribution`), and the rate. With `-t`, a request not answered in time is
  counted as a timeout, and the run still ends.
- **The smoke.** It sends 20,000 GETs on 50 kept-alive connections, then 2,000 on a
  connection each, 10 at a time. It adds 1.2 to 1.3 s to the clients suite: 6.01 and
  6.05 s without it, 7.25 and 7.35 s with it.
- **The plan's mutation.** With one write in a thousand dropped, oha counted 19,980
  responses and 20 timeouts out of the 20,000, and both of the smoke's checks failed.

## Decision

1. **oha is v1.16.0's release binary, fetched into `build/oha` by `make oha`** through
   `tests/fetch-oha.sh`, for macOS and Linux on amd64 and arm64.
   - The script pins the version and each file's sha256. Each sum was read from the
     downloaded file and matched the sha256 GitHub records for it.
   - A download with any other sum is refused (exit 2) and removed.
   - A download is written to a file of its own beside `build/oha` and renamed into
     place, so fetches running at once never write into each other's.
   - The sum is `tests/sha256.sh`'s, shared with the corpus vendoring. With neither
     `sha256sum` nor `shasum` on `PATH`, it says so and exits 2, before anything is
     fetched.
   - A binary already at `build/oha` with the pinned sum is kept.
   - On any other platform, Windows among them, the script names the platform and
     exits 2, and `OHA` names an oha.
2. **`make test` fetches it first**, unless `OHA` names another. An empty `OHA` names
   none, in the Makefile and in the suite alike, and neither does an empty `VTEST`.
   Where it cannot fetch, offline or with no pin, `make test` says so and runs every
   suite. The clients suite then fails by name, with status 2, as it does for a vtest
   that did not build (0017 item 2).
3. **CI fetches it in a step of its own**, `make oha`, before the build. The fetch takes
   about a second, so it is not cached.
4. **The smoke is in `tests/test-clients.sps`.** It reads the two tallies from oha's
   report, and the bytes of the bodies. Each run's check is that every request was
   answered 200 with its 4-byte body and none failed, kept alive and not. The rate is
   printed and not checked, since v0.1.0 sets no throughput goal (decision 0002's
   amendment of 2026-10-04). Each run's wait is capped at 25,000 turns of the loop, so
   two that never end are both cut within the suite's 120 s.
5. **The pin moves on a commit of its own.** A new version's sums go into the script,
   each matched to GitHub's record, and the smoke runs on the new oha.

## Consequences

- `make test` needs the network once, to fetch oha with curl.
- The binary is what oha's own release workflow built. The pin holds the bytes to the
  ones checked on 2026-10-04: a file GitHub serves differently is refused, not run.
- Building from source, as vtest2 is (0017), was weighed and not taken: 133 s the first
  time, and Rust wherever the tests run. So was taking whatever oha is on `PATH`, as
  curl and ab are: local versions would drift from CI's.
- The smoke's mutations are in `.superpowers/sdd/m8-mutations.md` (M8.4).
