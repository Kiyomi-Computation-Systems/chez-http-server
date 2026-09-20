# 0008: Upstream asks are filed and tackled first; the server carries a workaround for each until it lands

Date: 2026-09-19
Status: accepted (user decision, 2026-09-19)
Plan: [the brief](../2026-09-19-chez-http-server-project-brief.md) "Upstream first"

## Context

The gap analyses (research/gap-*.md, each with a citation refuter) found no blocker and twelve additive changes that make the server smaller or safer. Every claim was re-verified against the source before filing.

## Decision

The twelve issues (and #42, split out of #33 during our review of its fix), the milestone each unblocks, and the workaround meanwhile:

| Issue | Ask | Unblocks | Workaround |
|---|---|---|---|
| chez-httparse #32 | runtime-safe keep-alive / needs-eof decision + F-* constants | M2 | **LANDED 2026-09-19** in v0.3.0 (f878068): `(httparse decisions)` exports the nine F-* constants, `should-keep-alive?` (major minor type status flags) and `message-needs-eof?` (type status flags). The server imports them; no local copies |
| chez-httparse #33 | `parser-finish!` fires `on-message-complete` for close-delimited bodies, or documents that it does not | M6, test client | **LANDED 2026-09-19** in v0.4.0 (PR #41): `parser-finish!` fires `on-message-complete` once for a close-delimited body, after its last bytes, and a pause or failure that callback returns comes back out of the finish; pinned upstream by the new `unit.finish` lane. `'finished` now means what it says |
| chez-httparse #34 | document `parser-result-next` and the two upgrade channels | M2/M6 | **LANDED 2026-09-19** in v0.4.0 as documentation (PR #43, `docs/api.org` "Pausing, and where to resume" and "Upgrades hand off on two channels"): `parser-result-next` is the offset in the buffer just fed where the unconsumed tail begins, one past the fragment delivered to a pausing callback; CONNECT / `Connection: upgrade` / 101 arrive as `'paused` with `parser-result-pause` code `paused-upgrade`, the h2c preface as `'error` with code `paused-h2-upgrade`; a plain `callback-pause` carries no pause reason. The doc's `result-hands-off-stream?` is the check the server uses |
| chez-httparse #35 | `(httparse methods)` runtime module | M2 | **LANDED 2026-09-19** in v0.3.0 (cdf51d9): `httparse-method-name`, `httparse-method-number` and both tables |
| chez-httparse #36 | own error code for `request-invalid-te` | M5 | **LANDED 2026-09-19** in v0.4.0 as documentation (PR #44): the code stays `invalid-transfer-encoding` (one symbol per llhttp number, its decision 0013); `parser-error-node-name` splits it, `e-request-invalid-te` is the 501 and every other node a 400. No reason-string match anywhere |
| chez-httparse #42 | an unsafe `parser-finish!` answers llhttp's `HPE_INVALID_EOF_STATE`, not a numberless `unexpected-eof` (split from #33; we answered its open question "uniform") | M6, test client | **LANDED 2026-09-19** in v0.4.0 (PR #45): `invalid-eof-state` / "Invalid EOF state" (llhttp 14), uniform across mid-method, mid-header and mid-body. The server core reads only the finish status on peer EOF, so no workaround was needed |
| chez-libuv #18 | `uv-write*!` vectored writes | M3 | **LANDED 2026-09-19** on main (529ea57, unreleased): `uv-write*! : uv-stream (listof segment) procedure -> uv-request`, segment = bytevector or `(bv start end)`; one block, one completion; empty list refused as `empty-segment-list` |
| chez-libuv #19 | bind `uv_run` `__collect_safe` | future worker pool | none needed in v1. **PLANNED 2026-09-19** as Stage 1 of chez-libuv's threading arc (design and plan on its local `spike/threading-collect-safe` branch): `uv_run` and all 13 trampolines `__collect_safe`, shipped alone. The 1 ms-timer workaround the issue proposed is withdrawn on both sides (spike E5d/E5e) |
| chez-libuv #20 | bind `uv_async` | future worker pool | none needed in v1. **PLANNED 2026-09-19** as Stage 2, gated on #19: `make-uv-async` / `uv-async-send!` as a 14th trampoline, plus enforced per-loop thread affinity (`&uv-wrong-thread`, loop owner transferred at `uv-run` entry) |
| chez-libuv #21 | `uv-tcp-keepalive!`, reuseport bind flag | post-v0.1 | **LANDED 2026-09-19** on main (83e0184, PR #23, unreleased); the pin stays at 529ea57 until v0.6.0 or a milestone needs it |
| uriparse #9 | `uri-parse-authority-form` | M2 | **LANDED in v0.2.0**: `uri-parse-authority-form` (lenient) and `uri-parse-authority-form-validate` (strict: `userinfo-forbidden`, host grammar, `port-required`) |
| uriparse #10 | reject SP/CTL bytes in authority | M2 | **LANDED in v0.2.0** as the full host grammar: `uri-parse-validate` answers `invalid-reg-name` at the offending byte for CR or SP in a host |
| uriparse #11 | `uri-collector-reset!` | optimisation | accept the allocation |

## Consequences

- 2026-09-19, later the same day: five of the twelve landed (see the table). chez-httparse's two and chez-libuv's one are on `main` without a tag, so those pins are commits until v0.3.0 / v0.6.0 exist; uriparse's are in the v0.2.0 tag.
- 2026-09-19, night: chez-httparse tagged v0.3.0 (#32, #35) and v0.4.0 (#33, #34, #36, #42); all six of its issues are closed and its pin moves from commit f878068 to the v0.4.0 tag. Nine of the thirteen asks have landed. chez-libuv's pin stays at commit 529ea57 until v0.6.0. Verified by four smoke programs recorded in the ledger (`research/spike/smoke-finish.sps`, `smoke-finish-42.sps`, `smoke-v040.sps`, `smoke-upstream.sps`). Open: chez-libuv #19 #20 (planned upstream), uriparse #11 (optimisation); nothing on the v1 path.
- Each workaround is a named site in the server with a comment pointing at the issue and a test that will go red when the upstream change makes it redundant.
- Dependency pins move when an ask lands, one pin per commit, with the fingerprint check the siblings use.
- 2026-09-19, evening: chez-libuv #21 landed (83e0184). #19 and #20 are planned as one threading arc, Stage 1 then Stage 2; chez-libuv's threading spike re-ran the Q1 gate under collect-safe (its T1) and showed that the 1 ms-timer workaround our #19 text proposed does nothing on a bare callback (its T2b). Reconciled here as spike E5d/E5e (the ticker only works when the loop thread's per-tick Scheme path reaches Chez's trap check; chez-libuv's dispatch path does, a bare callback does not) and posted on #19. The conversion costs about 60 ns per callback (spike E5f).
