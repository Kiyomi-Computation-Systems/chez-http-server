# 0017: vtest2 is pinned at its archived GitHub mirror's `last` tag and built from source for the black-box lane

Date: 2026-10-04
Status: accepted (user decision, 2026-10-03, by form: "curl and vtest2")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14, M8.3

## Context

Plan §14's M8.3 puts a black-box lane against a port: curl scripts beyond the M4
exit's, and vtest2's `.vtc` scripts. The owner chose curl and vtest2 by form ("curl
and vtest2"). hurl was dropped, since it reads responses through libcurl, as curl does.

vtest2 is Varnish's test driver, run alone: a script is a client's exchanges with a
server and what it expects of each answer. It reads responses with its own HTTP/1
code, which is neither curl's nor chez-httparse's. It can send any bytes (`send`), and
it can check that the server closed the connection (`expect_close`). Its license is
BSD-2-Clause.

Where it lives:
- The GitHub repository, vtest/VTest2, is archived and read-only. Its last commit,
  803dcd0 (2026-02-17), is tagged `last`. Development moved to code.vinyl-cache.org.
- No distribution packages it alone. Debian and Ubuntu ship `varnishtest` inside
  varnish, at varnish's version.

Global constraints: "Dependencies are pinned checkouts by gitlink at release tags …
No other dependencies without a decision record."

Measured 2026-10-04:
- It builds from the pinned commit with a C compiler, pcre2 and zlib. python3 and awk
  generate two of its headers. Its Makefile builds with `-Werror`.
- Darwin arm64 (Apple clang, Homebrew pcre2 10.47): 5.9 s through `make vtest`, a
  369,656-byte binary.
- Ubuntu 24.04 amd64 (gcc 13.3.0, the CI image's release, run under emulation on
  Darwin arm64): 25 s with no warning, a 458,768-byte binary.
- A script runs in about 0.16 s. The lane's twelve take 3.22 s, 1.24 s of it the
  timeouts script.
- vtest2 is POSIX code: it forks, and polls BSD sockets.
- vtest exits 2 both when a script's expectation fails and when it cannot read the
  script (a missing file, an unknown command). Its log's `----` lines name the failure.
  `vtest -h` exits 1.

## Decision

1. **vtest2 is a submodule**, `vendor/vtest2`, its gitlink at the `last` tag of the
   archived GitHub mirror, 803dcd000b1328f6e766774e23aedbd7f53e7d97. `make check-pins`
   checks it with the others, and it moves alone, on its own commit.
2. **`make vtest` builds it out of the submodule's tree**, through
   `tests/build-vtest.sh`, so `make -n` runs nothing.
   - The pinned commit's files, from the submodule's git store, are unpacked into
     `build/vtest2` and built there, so no build product lands in the submodule. A tree
     copied without its `.git` has no store: its files are built as they stand, and the
     script says so.
   - The binary is `build/vtest`. `build/vtest.pin` names the commit it was built from,
     and a binary built from any other commit is rebuilt.
   - `make test` builds it first, unless `VTEST` names another. Where it does not build,
     `make test` says so and runs every suite: the clients suite then fails by name,
     status 2.
   - pcre2's flags come from `pkg-config`.
3. **CI builds it once per pin.** It installs `libpcre2-dev`, `zlib1g-dev` and
   `python3`. It caches `build/vtest` and its stamp, keyed on the gitlink, the OS release
   and the arch, as it caches Chez. A miss runs `make vtest` and saves the result.
4. **The scripts are ours.** `tests/vtc/*.vtc` were written from RFC 9112 and the
   decisions before they first ran. HAProxy's reg-tests are GPL (0007 item 4), and
   Varnish's test a proxy, so neither is vendored.
5. **`tests/test-clients.sps` runs each script against a server of the lane's own.**
   - That server's deadlines are a second each and its bodies are capped at 1 KiB, so
     its timeouts and limits act within a run.
   - Each script is held to the verdict a manifest lists, gated both ways with
     `tests/vtc`, so a script added, removed or changing verdict is a reviewed diff.
   - A verdict is `passed`, or how vtest failed: the wait, the exit and the `----`
     lines. A script vtest cannot read fails the same way, and shows as such.
   - vtest gives each script 5 s (`-t`), so twelve that hang end within the suite's
     120 s, each with vtest's own verdict.
   - The suite reads `VTEST` from the environment, `build/vtest` unless set.

## Consequences

- `make test` needs pcre2 and zlib headers, python3 and awk, beside curl and ab.
  README.org says so.
- vtest builds on Linux and macOS. Elsewhere, Windows among them, the clients suite
  names the missing vtest, and the other suites run.
- A newer vtest is at code.vinyl-cache.org. Moving there is a new pin, a URL and a
  commit, recorded here.
- The lane's mutations are in `.superpowers/sdd/m8-mutations.md` (M8.3, the third step).
