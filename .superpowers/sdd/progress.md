# chez-http-server — subagent-driven development ledger

`progress.md` is the spine; `global-constraints.md` binds every task brief. Read both before starting slice work. Close-outs are recorded here.

---

M-1 — PLANNING. Branch feat/m0-planning. 2026-09-19.

Delivered: the project brief (`.plans/2026-09-19-chez-http-server-project-brief.md`), the async-model options paper, the test corpus survey, decisions 0001–0008, this ledger. Evidence under `.plans/research/`: 61 agent reports (7 corpus finders, 28 skeptic batches, 6 async proposals, 3 judges, 8 reference-server reads, 4 gap analyses with 4 refuters), the live control-flow spike (`research/spike/`, every experiment run twice), and the two structured results (`corpus-final.json`, `track2-final.json`).

Decisions taken by the owner on 2026-09-19: strictly serial pipelining with read-stop (0004); nginx-style bounded defaults (0005); HTTP/1.0 supported, h2c answered 505, one upgrade hand-off hook (0006); upstream asks filed as issues and tackled first (0008).

Upstream issues filed 2026-09-19 (verified against source before filing): chez-httparse #32 #33 #34 #35 #36; chez-libuv #18 #19 #20 #21; uriparse #9 #10 #11; later that day chez-httparse #42 (split from #33) and uriparse #18 (follow-up to #11).

Measured environment: Darwin arm64, Chez 10.4.1 threaded (`tarm64osx`), libuv 1.52.1 (Homebrew pkg-config), CMake 4.3.3, Node v20.10.0, 8 CPUs. Baseline: the repository has no `Makefile` and no tests yet; `chez-libuv`'s shim is built and `(import (libuv))` resolves; `(generated httparse-message)` loads from the chez-httparse checkout.

Not done: the completeness critic over the research (deferred to save credits; its questions are folded into the brief's standing risks). Raw agent reports are untracked; the owner decides at the merge gate which of `.plans/research/` is committed (recommended: `spike/`, the two JSON results, this README, and the curated docs; the raw `*.md` reports optional).

UPSTREAM LANDED (2026-09-19, later): chez-httparse #32 and #35 closed on `main` (cdf51d9 methods, f878068 decisions; no tag yet); uriparse #9 and #10 closed in the v0.2.0 release (M3 charset, M4 host grammar, M9 authority-form). Local checkouts verified in sync with origin (behind 0, ahead 0, clean).

Smoke evidence, one program importing `(httparse decisions) (httparse methods) (uri collect) (uri components)` (scratchpad `smoke-upstream.sps`, run on Darwin arm64, Chez 10.4.1; exit 0):

    keep-alive quadrants (expect #f #t #t #f #t #f): #f #t #t #f #t #f
    needs-eof (expect #f #t #f #f #f): #f #t #f #f #f
    flags: 1 2 64 512
    methods: GET CONNECT 5 2
    authority-form lenient: (ok example.com:443) (err not-authority-form 15)
    authority-form strict: ok (err userinfo-forbidden 1) (err port-required 12) ok
    validate host with CR (expect err): (err invalid-reg-name 10)
    validate host with SP (expect err): (err invalid-reg-name 10)
    validate clean (expect ok): ok

The quadrant row is the literal `http.c:157` gate (1.2 keeps alive without a header, 2.0 does not); the `[::1]:8443` row is the bracket-aware split. Decision 0008's table, the brief's "Upstream first" and M0/M2 text, decision 0001's layout note and the pins above were updated to match.

UPSTREAM LANDED (2026-09-19, later still): chez-libuv #18 closed on `main` at 529ea57 (PR #22), untagged. `make build` in the checkout found the shim current. Smoke evidence (scratchpad `smoke-writev.sps`, loopback on one loop, Darwin arm64, Chez 10.4.1, libuv 1.52.1; exit 0):

    empty-list refusal: (refused uv-write*! empty-segment-list)
    on-complete err: none
    completions (expect 1): 1
    bytes match concatenation (expect match): match
    received: HTTP/1.1 200 OK / Content-Length: 5 / (blank) / helloTRAILER

Three segments — a header bytevector, the span [2,7) of "xxhelloyy", a trailer bytevector — arrived as one ordered stream with exactly one completion. M3's serializer therefore emits segments, not a concatenated head.

UPSTREAM PLANNED / LANDED (2026-09-19, evening): chez-libuv #21 closed on `main` at 83e0184 (PR #23: `uv-tcp-keepalive!`, reuseport bind flag; post-v0.1, pin unchanged at 529ea57). chez-libuv #19 and #20 answered: planned as Stage 1 (`uv_run` and all 13 trampolines `__collect_safe`, ships alone) and Stage 2 (`uv_async` as a 14th trampoline, enforced per-loop thread affinity with `&uv-wrong-thread`) of one arc; spike, design and plan sit on chez-libuv's local branch `spike/threading-collect-safe` (23fa923, not pushed). Their T2b contradicted E5c's "92 ms with a 1 ms poll". Reconciled with three new spike programs, each run twice (`research/spike/e5d-ticker-needs-trap-ticks.sps`, `e5e-gc-stall-uvrun-default.sps`, `e5f-collect-safe-callback-cost.sps`; Darwin arm64, Chez 10.4.1 threaded, libuv 1.52.1; exit 0):

    E5d  loop-thread Scheme per 1 ms tick -> worker alloc load, plain uv_run: 0 calls 439-447 ms | 100 calls 82-85 | 300 calls 29-32 | 1000+ calls 9-20 | uncontended mutex 437-438 | (sleep 0) 9-12 | __collect_safe 6-10
    E5e  through the binding, one (uv-run loop 'default): 1 ms timer 44-92 ms | 300 ms timer 10223-10240 ms | E5c baseline 26-29 ms
    E5f  per callback, 256 idle handles, 5,000,000 callbacks x 3: plain 177-192 ns | __collect_safe 235-249 ns

Reading: Chez services another thread's collect request only at `$event`, and firing the collector does not shorten the 1000-tick trap budget (Chez 10.4.1 c/schsig.c:574-594, s/cmacros.ss:2118, s/library.ss:1219-1236). The 1 ms timer is not a workaround; chez-libuv's D2 (do not ship it) stands and our #19 proposal is withdrawn in a comment posted on #19. Corrected: options paper (E5c row, new E5d-E5f rows, threads row, numbers table), spike report (E5c reading, conclusion 6, new conclusion 8, new E5d-E5f sections), brief (risk line, upstream paragraph), ADR-0003 (reopening condition), ADR-0008 (#19/#20/#21 rows, dated consequence), global-constraints (pin note), research README.

UPSTREAM LANDED (2026-09-19, night): chez-httparse v0.3.0 (734d6ce: #32, #35) and v0.4.0 (1cddba8: #33 via PR #41, #34 via PR #43 as docs, #36 via PR #44 as docs, #42 via PR #45) are tagged; all six chez-httparse issues closed. #42 was split out of #33 at our review of that fix and landed the same evening with the "uniform" answer we posted (issue 42, comment 5746115452). Local checkout at 1cddba8, in sync, byte-machine submodule at v0.6.0. Upstream conformance unchanged at 274 of 274; the generated parser is no longer byte-identical to v0.3.0 (one node added, one error-table entry renamed), generated-runtime ABI still 9. All smoke programs now live in `research/spike/smoke-*.sps`. Evidence, Darwin arm64, Chez 10.4.1, `chez --libdirs <httparse>/src:<httparse>/vendor/byte-machine/src --program`, exit 0 for each:

`smoke-finish-42.sps` (#42): the two llhttp `request/finish.md` `finish=2` inputs plus mid-header-field, mid-method and mid-body, then five feed-only URL probes showing nothing reaches the eof declaration from a feed:

    --- parser-finish! from an UNSAFE state
    (D mid-header-field  GET / HTTP/1.1\r\nHos             feed need-input finish-field 2 finish error (invalid-eof-state Invalid EOF state))
    (E finish.md#2 mid-header-value (finish=2)           feed need-input finish-field 2 finish error (invalid-eof-state Invalid EOF state))
    (F finish.md#3 mid-header-field (finish=2)           feed need-input finish-field 2 finish error (invalid-eof-state Invalid EOF state))
    (G mid-method  GE                                    feed need-input finish-field 2 finish error (invalid-eof-state Invalid EOF state))
    (H mid-body    PUT / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab feed need-input finish-field 2 finish error (invalid-eof-state Invalid EOF state))
    --- feed only: can the URL sub-machine answer unexpected-eof without a finish?
    (U1 GET http HTTP/1.1      feed error at 9 (invalid-url Invalid characters in url))
    (U2 GET http:/ HTTP/1.1    feed error at 10 (invalid-url Unexpected char in url schema))
    (U3 GET http:// HTTP/1.1   feed need-input at 24 -)
    (U4 GET http://h@ HTTP/1.1 feed need-input at 26 -)
    (U5 GET http://h: HTTP/1.1 feed need-input at 26 -)

`smoke-finish.sps` (#33; the same four situations probed on v0.2.0 before filing, where row A counted 0 completions):

    (A close-delimited response body: feed need-input finish finished finish-field 1 message-complete-count 1)
    (B idle parser, no input at all:   feed need-input finish finished finish-field 0 message-complete-count 0)
    (C complete request then EOF:      feed need-input finish finished finish-field 0 message-complete-count 1)
    (D EOF mid-header (unsafe):        feed need-input finish error finish-field 2 message-complete-count 0)

`smoke-v040.sps` (#36 and #34, using `docs/api.org`'s own `transfer-encoding-error->status` and `result-hands-off-stream?` verbatim; the last row's tail is `GET /b HTTP/1.1\r\n\r\n`, printed literally):

    --- #36: invalid-transfer-encoding split by parser-error-node-name (llhttp transfer-encoding.md inputs)
    (pigeons         error invalid-transfer-encoding Request has invalid `Transfer-Encoding` node e-request-invalid-te status 501)
    (chunkedchunked  error invalid-transfer-encoding Request has invalid `Transfer-Encoding` node e-request-invalid-te status 501)
    (chunked,deflate error invalid-transfer-encoding Invalid `Transfer-Encoding` header value node e-bad-te-value status 400)
    (empty TE + CL   error invalid-transfer-encoding Empty Transfer-Encoding node e-empty-transfer-encoding status 400)
    --- #34: the two hand-off channels and parser-result-next
    (CONNECT  paused pause (paused-upgrade Pause on CONNECT/Upgrade) error #f consumed 55 next 55 tail TUNNEL hands-off? #t)
    (Upgrade  paused pause (paused-upgrade Pause on CONNECT/Upgrade) error #f consumed 63 next 63 tail WSDATA hands-off? #t)
    (h2c PRI  error pause #f error (paused-h2-upgrade Pause on PRI/Upgrade) consumed 24 next 24 tail FRAME hands-off? #t)
    (plain pause at on-message-complete (pipelining) paused pause #f error #f consumed 19 next 19 tail GET /b HTTP/1.1<CRLFCRLF> hands-off? #f)

`smoke-upstream.sps` (regression of v0.3.0's decisions/methods and uriparse v0.2.0): output identical to the block above.

Reading: (1) M6 and the test client treat `'finished` from a close-delimited finish as completion because the callback now fires; (2) the server core acts on the finish status alone on peer EOF, so `invalid-eof-state` is documentation for the test client, not a branch in the core; (3) M5's status mapping splits `invalid-transfer-encoding` by `parser-error-node-name`, never by reason string; (4) M2/M6/M8 recognise a hand-off with the doc's two-channel check and hand the tail from `parser-result-next` onward, and a pipelining pause carries no pause reason, which is how the core tells the two apart. Updated: decision 0008 (rows #32–#36, new #42 row, dated consequence), decision 0006 (channel note), the brief ("Upstream first", risks 3 and 4, settled item 7), global-constraints (pin), memory.

UPSTREAM LANDED (2026-09-19, later that night): uriparse v0.3.0 is tagged (7fe6688, 20:30 -0400; its CHANGELOG dates the release 2026-09-20, UTC). #11 closed via PR #15 (a1b9176): `uri-collector-reset! : Collector -> unspecified` on `(uri collect)` returns a collector to its just-constructed state in place (byte-machine's `parser-reset!` with the embedder-chosen mode kept; the span table, the offset table and the verdict flags cleared; nothing reallocated), so a server holds one collector per connection instead of allocating a parser and two `eq-hashtable`s per request-target; `uri-parse` is unchanged (its decision 0029). The release also states uriparse's first conformance claim, scoped: `uri-parse-validate` is audited recognizer-equivalent to RFC 3986 Appendix A per mode (an independent whole-URI oracle read from the ABNF, an exhaustive length-0..5 sweep over a 12-byte alphabet in all three modes, the normative corpora and 213 adversarial vectors, zero deviations; recognition only, not error code or offset; `uri-parse` stays lenient by design; its decisions 0028, 0030, 0031). All three uriparse issues are closed; the pin moves from v0.2.0 to the v0.3.0 tag. Local checkout verified: `main` at 69d2a84 is the tag plus its ledger close-out, `src/` byte-identical to the tag, in sync with origin (behind 0, ahead 0, clean); vendor byte-machine at 0245db3 (v0.6.0), the commit chez-httparse vendors too.

`smoke-uriparse-v030.sps` (#11; run twice under gtimeout on Darwin arm64, Chez 10.4.1 `tarm64osx`, `chez --libdirs ~/github/uriparse/src:~/github/uriparse/vendor/byte-machine/src --program`; both runs exit 0 and agree to the line except the last reuse row, 505 vs 500 ns):

    --- #11: reset-and-reparse equals a fresh collector (components and offsets; expect #t in every row)
    (uri http://a/b?q#f -> http://h/x reuse==fresh #t offsets (0 7 8 #f #f))
    (uri http:/p -> http://a/x reuse==fresh #t offsets (0 7 8 #f #f))
    (uri-reference g/h -> /p reuse==fresh #t offsets (#f #f 0 #f #f))
    (uri-reference g:h -> a/b reuse==fresh #t offsets (#f #f 0 #f #f))
    (relative-ref //a/b?q -> p/q reuse==fresh #t offsets (#f #f 0 #f #f))
    stale query and fragment absent after reset (expect #t #t): #t #t
    mode survives the reset (expect #t b/c): #t b/c
    reset after an error result (expect (err scheme-required N) #t): (err scheme-required 7) #t
    calibration: sstats-bytes grows by about 1048576 for a 1 MiB bytevector -> 1048752
    --- one 'uri-reference target of 46 bytes, 200000 parses per pass, fresh collector vs one reset collector
    fresh: per-parse-bytes 3680 ns 1210
    reuse: per-parse-bytes 1584 ns 495
    fresh: per-parse-bytes 3680 ns 1205
    reuse: per-parse-bytes 1584 ns 505
    fresh/reuse bytes ratio: 2 time ratio x10: 24
    done

Reading: (1) The reset is byte-identical to a fresh parse across the rooted and verdict transitions and after an error result, so a reused collector needs no reuse-specific branch in the core. But it reaches only the streaming interface: `uri-parse-validate` is `uri-parse` on a fresh collector followed by `validate-result`, which walks the components leftmost-first, rebases each validator's index through the offset seam, and is not exported (collect.sls:249-263, 271-275); `uri-parse-authority-form-validate` parses a spliced copy through `uri-parse` the same way (collect.sls:370). M2 validates origin-form and absolute-form through `uri-parse-validate` and CONNECT through the authority-form validator, so on the validated path the "accept the allocation" workaround stands for v1 and #11's win waits until uriparse exports validation over a parse result (`uri-parse-result-validate : uri-parse-result -> uri-parse-result`, additive, the existing procedure). `(uri charset)`'s `validate-component` and `(uri host)`'s `validate-authority` are exported, but composing them in the server would copy the audited recognizer rather than call it. Filed as uriparse #18 (https://github.com/Kiyomi-Computation-Systems/uriparse/issues/18). (2) Measured once, not a lane (uriparse's decision 0016 applies here too): on a 46-byte origin-form target the fixed per-call cost was 2096 bytes and about 0.7 µs of a 3680-byte, 1.2 µs parse; what remains is the result and its copied components, which the collector allocates by design. uriparse's own one-shot figure is ~6.4x on a shorter target, ours 2.4x on this one; both are evidence, not gates. (3) M2's request-target validation cites an audited oracle: `uri-parse-validate` accepts exactly what RFC 3986 Appendix A accepts, per mode, so the server's request-target tests cover only what HTTP adds on top (the RFC 9112 §3.2 forms, decision 0005's byte limits) and never re-derive the URI grammar. `smoke-upstream.sps` re-run against chez-httparse v0.4.0 and uriparse v0.3.0: output identical to its block above (nine rows, exit 0). Updated: decision 0008 (row #11, the night bullet's count, a dated consequence), the brief (dependencies line, settled item 7, "Upstream first"), global-constraints (pin), research/README, memory.

UPSTREAM LANDED (2026-09-19, night, later): chez-libuv v0.6.0 is tagged (54c4ceb on ad4c1e9, 21:16 -0400; PR #27). It releases all four chez-libuv asks: #18 `uv-write*!` (529ea57, PR #22), #21 `uv-tcp-keepalive!` and the `'(reuseport)` bind flag (83e0184, PR #23) plus the new `uv-tcp-sockname-address`, #19 `uv_run` `__collect_safe` (0ae127d, PR #25: `uv_run` and every trampoline it can invoke, thirteen of fourteen, `walk` alone plain because it fires only from the synchronous `uv_walk`; ~60 ns per callback) and #20 `(libuv async)` with enforced loop-thread affinity (17374d8, PR #26: `make-uv-async` / `uv-async-send!`, send the one thread-safe verb and sends coalesce; every operational handle verb off the owner thread raises `&uv-wrong-thread` with who, expected and actual before any registry mutation; the owner is set at `make-uv-loop` and transferred at `uv-run` entry; `uv-close!`, the loop verbs and the other constructors stay outside the check, its ADR-0019). The threading spike, design and plan merged as PR #24. Local checkout verified: on `main` at ad4c1e9 = the tag, in sync with origin (behind 0, ahead 0, clean); `make build` rebuilt the shim (`libuv-shim.c` gained the `uv_async` glue). The pin moves from commit 529ea57 to the v0.6.0 tag; every dependency is now at a release tag.

Evidence, all on Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1, `CHEZSCHEMELIBDIRS=~/github/chez-libuv/src:~/github/chez-libuv/build/scheme-libs`, each program run twice, every exit 0. `research/spike/e5g-gc-stall-at-v060.sps` re-runs E5c and E5e with their method unchanged (`out/e5g-*.run{1,2}.txt`):

    E5g  worker alloc load at v0.6.0: Scheme-sleep baseline 24 ms | 'once + 300 ms timer 23-24 (was 10266-10272 at 529ea57) | 'once + 1 ms timer 35-51 (was 91-93) | one 'default + 300 ms timer 27-33 (was 10223-10240) | 'default + 1 ms timer 29-50 (was 44-92)

E5b re-run unchanged at v0.6.0 (`out/e5b-thread-direct-uv-write.v060.run{1,2}.txt`): the worker's direct `uv-write!` on the loop's handle, which went through silently at the old pin (`worker-outcome=(uv-write!-returned on-thread 1 at 36)`, the bytes arriving at the client), is now `worker-outcome=((raised (&uv-wrong-thread)) on-thread 1 at 28-30)` and the client receives nothing; the loop gives up on its 2 s wait and tears down cleanly.

`smoke-v060-async.sps` (#20; run 2 differs only in the wake count, 40):

    worker refused uv-timer-start! on the loop's timer (expect wrong-thread uv-timer-start! expected-main? #t actual-caller? #t): (wrong-thread uv-timer-start! expected-main? #t actual-caller? #t)
    worker refused make-uv-async (expect wrong-thread make-uv-async expected-main? #t actual-caller? #t): (wrong-thread make-uv-async expected-main? #t actual-caller? #t)
    items drained (expect 1000): 1000 | wakes (expect between 1 and 1001; sends coalesce): 57
    timer callback ran on thread B, not main (expect #t): #t
    main refused after the handoff (expect wrong-thread uv-timer-start! expected-main? #f actual-caller? #t): (wrong-thread uv-timer-start! expected-main? #f actual-caller? #t)
    after uv-run on main the start is accepted (expect ok): ok
    done

`smoke-v060-tcp.sps` (#21, `uv-tcp-sockname-address`, and decision 0003 item 4's store-and-reraise oracle under the collect-safe `uv-run`; both runs identical):

    sockname of the bound server (expect 127.0.0.1 and the getsockname port): 127.0.0.1 #t #t
    reuseport bind flag on this platform: (errno -45 operation not supported on socket)
    keepalive on an unconnected handle, enable with delay 0 (expect invalid-argument delay-out-of-range): (invalid-argument uv-tcp-keepalive! delay-out-of-range)
    keepalive enable 60 s on the connected client (expect ok): ok
    keepalive disable (expect ok): ok
    raise inside a timer callback comes out of uv-run (expect (uv-callback-error boom)): (uv-callback-error boom)
    the loop is still usable afterwards (expect ok): ok
    done

`smoke-writev.sps` and `smoke-libuv.sps` re-run at v0.6.0: output identical to their blocks above (one completion, bytes match; libuv 1.52.1, three timer fires).

Reading: (1) The rerun decision 0003's multi-core bullet asked for has happened at the release, not only in chez-libuv's own T1: with `uv_run` collect-safe a loop thread blocked in a poll no longer holds the collect interlock, so the worker's 27 ms of allocation costs 23-33 ms whatever the loop thread does, against 10.2 s at the old pin; the 1 ms-timer cases sit a few ms above baseline because each fire reactivates the loop thread, which then takes part in every rendezvous. (2) E5b2's registry corruption is a named refusal: the v1 shell calls no handle verb off the loop thread, so `&uv-wrong-thread` is a bug signal like `&uv-callback-error`, not a branch in the run loop; a future worker pool hands work back only through `uv-async-send!` and drains a queue on the wake, since 1000 sends became 40-57 wakes. (3) A raise inside a callback still comes out of the collect-safe `uv-run` as `&uv-callback-error` carrying the raised object and the loop stays usable, so decision 0003 item 4 holds at this pin. (4) The reuseport flag answers errno -45 (operation not supported) on macOS, as its own tests expect off Linux/BSD; the pre-fork route of decision 0003 keeps `uv-spawn!`'s `inherit-stream`, not reuseport, as its portable mechanism. Keepalive validates its delay (`delay-out-of-range` at 0) and enables and disables on a connected handle; `uv-tcp-sockname-address` mirrors the peer accessor and agrees with `uv-tcp-getsockname-port`. (5) The ~60 ns per callback (spike E5f) is in the pin and goes into M0's performance baseline; the worker-pool door is open from this pin on and stays untaken for v1. Updated: decision 0003 (item 3, dated consequence), decision 0008 (rows #18-#21, dated consequence, counts), the brief (dependencies line and diagram, settled item 7, risk line, "Upstream first"), the options paper (E5c row, threads-mailbox row, rejection paragraph, numbers table), the spike report (E5g section, conclusions 6 and 8, files), global-constraints (pin), research/README, memory.

UPSTREAM LANDED (2026-09-19, night, last): uriparse v0.4.0 is tagged (611b04b; #18 via PR #19, release PR #20); all four uriparse asks are closed. `uri-parse-result-validate : uri-parse-result -> uri-parse-result` on `(uri collect)` judges an already-parsed result: an error result and a clean result come back as the argument itself (`eq?`), and an otherwise-valid split whose bytes the ABNF rejects becomes the leftmost validation error with its absolute offset. `uri-parse-validate` is now that judgement over a fresh one-shot parse (its decision 0032), so the audited recognizer claim carries over unchanged; `uri-parse-authority-form-validate` did not change and still parses fresh (collect.sls:385). Upstream conformance 77/77, on macOS arm64 only (its Linux cell has still never run; its decisions 0017/0033). Local checkout `main` at 102c8c9, `src/` byte-identical to the tag, byte-machine gitlink still 0245db3. Smoke evidence (`research/spike/smoke-uriparse-v040.sps`, Darwin arm64, Chez 10.4.1, `chez --libdirs <uriparse>/src:<uriparse>/vendor/byte-machine/src --program`, exit 0; run 1 in full, then run 2's measurement lines):

    --- #18: reused collector + uri-parse-result-validate == fresh uri-parse-validate (expect agree #t in every row)
    (uri-reference /api/v1/items/12345?fields=name,price&limit=50 fresh ok reused ok agree #t identity same-object)
    (uri-reference /a b fresh (err invalid-pchar 2) reused (err invalid-pchar 2) agree #t identity new-error-result)
    (uri-reference /a<b>?q=1 fresh (err invalid-pchar 2) reused (err invalid-pchar 2) agree #t identity new-error-result)
    (uri-reference /ok?q=a b fresh (err invalid-query 7) reused (err invalid-query 7) agree #t identity new-error-result)
    (uri http://exa mple.com/p fresh (err invalid-reg-name 10) reused (err invalid-reg-name 10) agree #t identity new-error-result)
    (uri http://h:8x/p fresh (err invalid-port 10) reused (err invalid-port 10) agree #t identity new-error-result)
    (uri nocolon fresh (err scheme-required 7) reused (err scheme-required 7) agree #t identity same-object)
    (uri http://example.com/p?q#f fresh ok reused ok agree #t identity same-object)
    --- authority-form is unchanged in v0.4.0: its strict validator still parses fresh (collect.sls:385)
    ok (err port-required 11)
    --- one 'uri-reference target of 46 bytes, 200000 validated parses per pass: fresh uri-parse-validate vs one reset collector + uri-parse-result-validate
    fresh+validate: per-parse-bytes 3680 ns 1595
    reuse+validate: per-parse-bytes 1584 ns 835
    fresh+validate: per-parse-bytes 3680 ns 1565
    reuse+validate: per-parse-bytes 1584 ns 845
    fresh/reuse bytes ratio: 2 time ratio x10: 18
    done

    fresh+validate: per-parse-bytes 3680 ns 1585
    reuse+validate: per-parse-bytes 1584 ns 855
    fresh+validate: per-parse-bytes 3680 ns 1580
    reuse+validate: per-parse-bytes 1584 ns 860
    fresh/reuse bytes ratio: 2 time ratio x10: 18

Reading: (1) M2 holds one collector per connection and validates each origin-form or absolute-form target with `uri-parse-result-validate` over `uri-collect-finish!`: the same audited verdict as `uri-parse-validate`, at 1584 instead of 3680 bytes and about half the time per target, so the accept-the-allocation workaround on the validated path is retired and the ≤ 3 KiB per-request gate (brief, risk 1) no longer carries it; (2) CONNECT targets keep the allocation because the strict authority-form validator has no collector path; accepted without an ask, CONNECT is rare and never on the keep-alive hot path; (3) all fourteen filed asks have landed and every dependency is pinned at a release tag. Updated: decision 0008 (row #18, dated bullet), the brief (item 7, dependencies line, "Upstream first"), global-constraints (pin), research README.

Still open upstream: nothing. All fourteen filed asks (chez-httparse #32–#36 and #42, chez-libuv #18–#21, uriparse #9–#11 and #18) are closed and released.

---

M0 — SKELETON AND PURE RECORDS. Branch feat/m0-skeleton. 2026-09-19 (Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1).

Delivered: the `Makefile` (build/dev/test/clean/prod/help plus check-help, and check-pins/check-imports/submodules/deps); the dependency wiring as pinned gitlink submodules under `vendor/` assembled onto one library path — chez-libuv v0.6.0 (ad4c1e9), chez-httparse v0.4.0 (1cddba8), uriparse v0.4.0 (611b04b), byte-machine v0.6.0 (0245db3, nested under chez-httparse), and chez-srfi (7879b52) for SRFI-64; Linux-only CI (`.github/workflows/ci.yml`) that builds Chez 10.4.1 from source with a cached prefix and a floor assertion, installs libuv for the shim, and runs check-pins/build/test/check-help; the pure libraries `(http-server limits)` (decision 0005 defaults with environment overrides through an injected lookup — pure, no getenv), `(http-server headers)`, `(http-server request)` and `(http-server response)`, each importing only `(rnrs)`; the SRFI-64 test bridge `(testing)` that maps a suite to the 0/1/2/3 status vocabulary (empty selection = 2, provenance = 3); and the F-*/method pins imported from `(httparse decisions)`/`(httparse methods)`, never copied.

`make check-pins` fingerprints all five gitlinks against their pinned commits; `make check-imports` asserts no `(libuv)`/`(chezscheme)` reaches a pure library under `src/http-server/` (a negative grep, the M0 realisation of the import-audit lane). Both are prerequisites of `make test`.

Exit — `make test` green (exit 0): five suites, 55 expected passes (flag-pins 8, headers 9, integration 5, limits 19, records 14). The pin test asserts F-CONNECTION-CLOSE = 2 and F-SKIP-BODY = 64 (oracle: llhttp's FLAGS enum, `1<<1` and `1<<6`) and was watched to fail by mutating the vendored constant 2 → 3 (exit 1, one failure). Every suite was watched to fail; the five mutations, each reverted, are in `m0-mutations.md`. The "program importing all four libraries at once" runs: `tests/test-integration.sps` imports `(libuv)`, `(generated httparse-message)`, `(httparse decisions)`, `(httparse methods)`, `(byte-machine runtime)`, `(uri collect)` and `(uri components)` on the one library path and passes (libuv loop lifecycle, `compiled-machine?` over the generated parser, keep-alive/method decisions, `uri-parse-validate`); dropping uriparse from the path reddens it (`Exception: library (uri collect) not found`, exit 255).

Decisions taken in M0: chez-srfi is vendored as a fifth submodule to provide SRFI-64 (the framework global-constraints names), symlinked into `build/scheme-libs` by `make deps` exactly as chez-libuv does; the status vocabulary is a thin `(testing)` bridge over SRFI-64 rather than the parsers' hand-rolled harness, because global-constraints names SRFI-64 and its "compare against a value only success can produce" clause is the mitigation for SRFI-64's exception→#f footgun; environment overrides use the `CHEZ_HTTP_*` names documented in `docs/configuration.org` (timeouts in whole seconds, canonicalised to milliseconds). `default-limits` keeps explicit literal defaults guarded by a "default == empty environment" drift test rather than deriving one from the other. Submodule URLs are the public HTTPS Kiyomi/arcfide URLs so `--recursive` CI checkout needs no credentials.

Not done in M0 (unchanged from the ladder): the design document and the milestone plan (rungs 2 and 3) remain unwritten — the brief's M0 does not include them; they are the next planning rung whenever the owner calls for it.

---

RUNG 2 — THE DESIGN DOCUMENT. Branch docs/design-doc. 2026-09-20 (Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1).

Delivered: `.plans/2026-09-20-chez-http-server-design.md` (1,125 lines, nine numbered sections in the siblings' shape), the ladder's missing second rung. It composes decisions 0001-0008 into one system and cites them rather than re-arguing them; the mechanism the brief and the ADRs deliberately omit is what it adds. §4 is the spine M2 implements — decision 0002's fifteen events and fifteen actions verbatim, all twenty-five parser callbacks by name, nine connection states (introduced there; 0002 fixes the vocabulary but names no states) each with the deadline it arms, and the transitions as two tables including decision 0004's pause/read-stop/resume cycle. §6 is the condition hierarchy, previously the least-specified part of the ladder: the boundary rule (the pure core never raises and never catches — errors are values in the core, conditions only in the shell), the four families mapped onto what each dependency actually does, an `&http-server-error` hierarchy, and one status table. §7 is GC and buffer ownership. §8 is the test instrument. §9.3 lists the five things the document settles that no decision record holds, so any of them can be promoted to an ADR.

Two claims in `chez-http-server-architecture.md` were found wrong at the current pins and are corrected in §7 with a file:line each. The read path COPIES OUT: `on-data` receives a fresh Scheme bytevector of exactly `nread` bytes (`handles.sls:441` -> `native.sls:510-521`), not a view of the foreign read buffer, so span retention is a GC-liveness question and not a C-lifetime one, and retaining any span pins the whole delivery. Write payloads are COPIED AT THE CALL into request-owned foreign memory (`stream.sls:88-128`), so the core never retains a response bytevector until completion and write accounting tracks bytes outstanding rather than buffer liveness. The architecture document keeps its place as background per decision 0001 item 5, banner extended: §§5-15 superseded, §§1-4 retained, the stale names (`chez-http1`, `chez-byte-machine`) called out, and those two claims plus §12's error-model sketch named as wrong.

Evidence discipline: every number is quoted from the spike or a smoke program with its date and platform stamp and none is re-derived by arithmetic. One citation corrected in passing — the ~13 µs scheduler turn is spike E3's (10,000 cycles in 131-138 ms wall, 17-20 ms CPU, `spike-control-flow.md:934`), not E3b's, whose timed region contains no libuv; the options paper's "Numbers to hold onto" table attributes it to E3b and conclusion 3 names "E3/E3b" jointly.

Exit — docs only, nothing under `src/` or `tests/` moved; `make test` green before the commit (exit 0, five suites, 55 expected passes). Verified rather than asserted: every relative link resolves; every identifier named in §§3, 4, 6 and 8 exists at the current pins (the 22 harness bindings under `vendor/chez-httparse/test/support/harness/`, `(httparse decisions|methods)`, `(uri collect)`'s six, chez-libuv's condition set); the 19 parser error codes and the 25 callbacks were counted off the generated parser and the adapter table; and every file:line claim was read back against its source (three line numbers were wrong on the first pass and were corrected).

Found and recorded, not acted on: (1) chez-httparse's corpus harness libraries live under `vendor/chez-httparse/test/support/harness/`, NOT under its `src/`, so they are not on the Makefile's `LIBDIR_LIST` — M1 must add that directory (§3.2); (2) three limits field names and the environment prefix were renamed in M0 while the records still carry the old ones — `header-timeout-ms` (0005:17), `body-timeout-ms` (0005:18), `max-pipeline` (0004:14 AND 0005:27), prefix `HTTP_SERVER_<NAME>` (0005:13) — the ledger records the prefix but the three field renames are recorded nowhere, and 0004 is easy to miss because it names the field in prose rather than in 0005's table (§9.4). The second was handed to the session holding M0 and amended as `docs: amend ADRs 0004/0005 to record M0 limits naming` (PR #4, squash-merged to main as 9e010ca; a provenance fix, not a ladder rung): strictly additive, 24 insertions and 0 deletions, hunks opening at 0004:19 and 0005:37 — below every line §9.4 cites, verified from the shared object store, so the design doc needed no fixup. Both amendments are self-contained, so neither branch depends on the other's merge order.

CI is uninformative on this account and has been since before M0: GitHub Actions answers "The job was not started because recent account payments have failed or your spending limit needs to be increased" with zero steps executed. The three most recent runs — the M0 PR, the push to main after it merged, and this PR — all failed that way, so the red check carries no information about any of them. The local `make test` is the only signal, and the Linux leg (Chez 10.4.1 built from source) has not run since the condition began.

Not done: the milestone plan (rung 3) is deliberately unwritten — §9.1 cross-references the brief's M0-M8 with one line each saying which section of the design document that milestone implements, and §9.2 names the milestone plan as the next planning task. This section supersedes M0's "Not done" line above, which recorded rungs 2 and 3 as both unwritten.

---

RUNG 3 — THE MILESTONE PLAN. Branch docs/milestone-plan. 2026-09-20 (Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1).

Delivered: `.plans/2026-09-20-chez-http-server-milestone-plan.md` (699 lines), the ladder's third rung. It adds exactly three things the brief and the design document do not carry — slices with entry and exit conditions, a named mutation per slice so no test is finished by inspection, and the measured lane sizes M1 and M2 are gated on — and cites everything else. M1 through M4 are sliced (M1 in four, M2 in five, M3 in four, M4 in four); M5 through M8 carry entry conditions, the limits that arrive, the hazard each must answer and the brief's exits, and are deliberately NOT sliced. The reason is in §10 and is a sibling's record rather than an opinion: chez-httparse's own milestone plan wrote forward reachable ceilings and had to correct nearly every one, its M3 written as 44 cumulative and achieved 29, with the note that the error was "the methodology, not the arithmetic" — a fixture's deepest event does not say which capability its failure needs. M5's deadline intervals, M6's memory bound and M8's drain semantics all depend on numbers M2-M4 will produce. The amendment slicing them is part of M4's close-out, not a separate task.

Measured for the plan, not assumed (2026-09-20, Darwin arm64, Chez 10.4.1 `tarm64osx`, through chez-httparse's own harness at the v0.4.0 pin `1cddba8`): THE REQUEST LANE IS 135 FIXTURES, NOT 167. `vendor/chez-httparse/test/vendor/llhttp/request/` holds 167 fixtures in 13 files, all `passing` in chez-httparse's ratchet (274 entries: 167 request, 86 response, 21 url), but the brief's phrase is "every `type=request` fixture" and only 135 carry that type; the other 32 spread across eleven `request-lenient-*` and `request-finish` types, which name the init hook upstream compiles in and therefore the lenient flags the parser is built with. The filename does not decide it in either direction: the 11 `request-lenient-headers` fixtures live in six files (connection.md 3, lenient-headers.md 3, sample.md 2, one each in content-length.md, invalid.md, transfer-encoding.md), and `lenient-headers.md#3` (line 84) is a plain `type=request` that belongs in the strict lane. A lane built by globbing filenames would both miss lenient fixtures and swallow a strict one. Of the 135: 17 `noScan`, 13 carrying a `pause` that names a callback, 1 `skipBody`, 10,364 decoded input bytes (15,040 across all 167; median fixture 66 bytes, longest 2,044). The pr/release split costs 253 chunk-size runs and 9,512 parser feeds at `'extremes` against 9,394 runs and 53,172 feeds at `'full` — which is the number that justifies the split rather than a preference. The server runs strict, so the 32 lenient fixtures enter the ratchet as `deferred` with their type as the class word; promoting any is a decision record, not a milestone.

Settled here, following through on decision 0005's 2026-09-20 amendment: the amendment says the nine limits that are not yet fields "arrive with later milestones under the same `CHEZ_HTTP_` prefix" and leaves which milestone open. The plan's §3 assigns all nine with 0005's defaults unchanged — `max-header-field-bytes` and `max-header-value-bytes` to M2, `write-high-water` and `write-low-water` to M3, `max-connections` and `backlog` to M4, `write-timeout-ms` and `tick-ms` to M5, `drain-timeout-ms` to M8 — each arriving with four things rather than one: the field, a value test against 0005's default, its name appended to `limits-environment-variables`, and the existing "`default-limits` equals the empty environment" drift guard extended to cover it. One exception falls out, and it is to the unit and not to the prefix: `tick-ms` keeps `CHEZ_HTTP_` like every other override and is the one duration that cannot take the whole-seconds convention, because `env-seconds->ms` (`src/http-server/limits.sls:91-93`) multiplies by 1000 and 250 ms has no whole-second spelling, so its variable is `CHEZ_HTTP_TICK_MS` read by `env-integer` in its stored unit. M5 documents that beside the variable in `docs/configuration.org`.

Exit — docs only, nothing under `src/` or `tests/` moved; `make test` green before the commit (exit 0, five suites, 55 expected passes: flag-pins 8, headers 9, integration 5, limits 19, records 14). Verified rather than asserted: every relative link resolves; every file:line claim was read back against its source (`Makefile:34-39` and `:109`, `limits.sls:91-93`, `stream.sls:88-128`, byte-machine `conditions.sls:21`, corpus survey line 15); every identifier named in the slices exists at the pins, including the three `parser-result-*`/`parser-field-ref` accessors, which are exported from `(byte-machine runtime)` and not from chez-httparse's `src/`; both cited spike programs exist; the upstream count is fourteen filed asks, not the brief's stale "twelve" heading.

Two corrections made during the writing, both caught by verification rather than review. (1) The plan first framed "R1-R5 or R1-R7" as an open question for M7 — it is not: decision 0003 item 2 adopts R1-R5 as M7's checks and design §5.3 records that the other two invariants of the same proposal are already project rules enforced elsewhere, one by M4's `rg` close-ownership gate and one by v1 being single-threaded. M7's gate is five mutations, and the plan now says so. (2) The rule "a slice over roughly 400 lines gets its own PR" was first written as a description of M0's practice; M0 landed as a single PR of 845 insertions across 22 files, so the rule is a change from that practice, and M2 and M4 are marked as likely two PRs because of it.

CI has never run a job on this repository. Re-measured 2026-09-20: all TEN GitHub Actions runs — every run since the M0 pull request — ended `failure` with ZERO steps executed, aborted at the account billing check. This supersedes the rung-2 section's "three most recent runs" count above, which was accurate when written. Nothing in the plan is blocked by it, since local `make test` on Darwin arm64 is the only signal the repository has had, but M1's exit is the first that would genuinely benefit from the Linux leg: the corpus lane is the first lane whose result could plausibly differ by platform, since decoded byte counts, chunk ladders and trace rendering all run through string and bytevector paths a different Chez build could disagree about. It is an account setting, not a repository change.

Not done: no slice is implemented, and M5-M8 are not sliced (above). The plan's §13 carries one open item and it is the owner's — the CI billing condition.

---

M1 — THE INSTRUMENT, WITH NO SERVER. Branch feat/m1-instrument (cut from main at 592c2a0), MERGED to main as 6b80953 on 2026-09-20 (PR #6, `gh pr merge --squash --delete-branch`; local main fast-forwarded to 6b80953 and in sync with origin, feat/m1-instrument deleted local+remote, `make test` green on main). The four slice commits (29a7705 M1.1, 6ef1449 M1.2, a3ede21 M1.3, 3df35c5 M1.4) collapsed into 6b80953. Darwin arm64, Chez 10.4.1 `tarm64osx`.

Slices ①②③④: ① harness path + corpus inventory — DONE; ② trace lane — DONE; ③ libhtp + first provenance failure — DONE; ④ fake shell + three-lane ratchet — DONE. Mutation log: `.superpowers/sdd/m1-mutations.md` — seven mutations (the plan §5 estimated five; the fake shell earned its own and the two-way ratchet is witnessed in both directions).

M1.1 DONE: `vendor/chez-httparse/test/support/harness` added to the Makefile's `LIBDIR_LIST` (discharges design §3.2 — the harness lives under `test/support/harness`, not `src/`) and `tests/test-corpus-inventory.sps`, a drift guard on the chez-httparse v0.4.0 pin (1cddba8). Re-measured on the tree 2026-09-20: 13 request/*.md files, 167 fixtures, 135 `type=request`, 17 noScan, 13 pause (a string key naming a callback, tested for presence), 1 skipBody, 10,364 decoded bytes in the strict lane — matching plan §2 row for row, and the full type histogram matches §2.1's table. `make check-imports` clean: the harness path is test-only and reaches no pure library under `src/http-server/`, which is part of M1.1's exit and not an assumption. Watched to fail (m1-mutations.md): M1.1-A drops the harness path → `Exception: library (httparse test corpus-load) not found`; M1.1-B removes one `pause` key from `pausing.md` → exactly one failure, the pause tally at 12, everything else green. Both reverted; `make test` green, six suites, 62 expected passes (corpus-inventory 7, flag-pins 8, headers 9, integration 5, limits 19, records 14), exit 0.

M1.2 DONE: `tests/test-trace-lane.sps`, the trace lane. Drives every strict fixture through the generated parser with the harness's recorder bindings, renders via `(httparse test trace-format)` through our own `render-trace` shim, and `trace-compare`s bit-exactly against `fixture-expected` at each scheduled chunk size — the driving loop mirrors chez-httparse's own conformance driver (`run-at`/`fixture-mismatch`, generated lane) restricted to the strict lane, so it re-derives chez-httparse's result through our path, our Chez, our pins (design §8.1). Re-measured 2026-09-20: 135 strict fixtures, 0 trace mismatches at `'extremes` (253 runs) and at `'full` (9,394 runs, `CORPUS=full`); the pr/release split IS `corpus-scan-sizes`'s selection, not something built. Measured correction to §2.2: its "9,512 / 53,172 parser feeds" is the scan SCHEDULE (sum of `corpus-chunk-bounds`); the driver's ACTUAL feeds are fewer — 8,400 at `'extremes`, 47,215 at `'full` — because a fixture that errors or hands off stops feeding before its last chunk, exactly as the reference `run-at` does. The suite therefore asserts the runs (253/9,394), which the driver truly performs, not the schedule-feeds. Watched to fail (m1-mutations.md M1.2): dropping the `off=` field in `render-trace` makes `trace-compare` report `line 0 expected "off=0 message begin" got "message begin" (line-differs)` for every fixture, never a bare #f. Reverted; `make test` green, seven suites, 65 expected passes, exit 0.

M1.3 DONE: libhtp's connection-stream corpus vendored and gated. `make corpus-refresh LIBHTP_ROOT=<checkout>` copies libhtp's 102 `test/files/*.t` plus the BSD-3-Clause LICENSE under `test/vendor/libhtp/`, records upstream-url/ref (OISF/libhtp 0.5.x), the retrieval commit and a sha256 per file in PROVENANCE, and is the one recipe both the initial vendor and every refresh run (decision 0007). Vendored at commit 90c42f0c2ecd641cc059dacca09aa98e3c810177, retrieved 2026-09-20. `tests/sha256.sls` is a pure-R6RS SHA-256 (the harness fingerprint is a rolling hash, explicitly not cryptographic, so it cannot verify a sha256 manifest), calibrated against three FIPS-180-4 vectors. `tests/libhtp-corpus.sls` is a byte-faithful port of libhtp's own `test.c` chunker (`>>>` client / `<<<` server; one trailing CR stripped; empty chunks skipped; last chunk to EOF), refusing a malformed marker. `tests/test-libhtp.sps` calibrates the hasher, verifies every vendored byte against PROVENANCE (a mismatch, a miscount, or an unlisted file is status 3), and checks the loader: 102 `.t` files, all load into client/server chunks, and `01-get.t` decomposes exactly to its od-derived bytes (client 45 B ending `\r\n\r\n`, server 148 B). Re-measured on the tree: the `.t` count is 102, matching the survey's §2.3 figure, so no dated note. The loader decomposes the corpus into 318 chunks (150 client, 168 server) — recorded here, not asserted, since it is a loader-derived count and `01-get.t` is the loader's independent correctness oracle. Watched to fail (m1-mutations.md M1.3): corrupting one sha256 → exit 3 and a PROVENANCE-ERROR, the first `provenance-failure` in this repository. `make test` green, eight suites, 76 expected passes, exit 0.

M1.4 DONE: the fake shell and the three-lane ratchet. `tests/fake-shell.sls` is the imperative shell as a test double — delivers scripted events in order, threads a test-supplied stub step's state, records every returned action faithfully in order, and takes time by injection (a fake clock set and advanced explicitly, so a `tick` event carries the injected `now` and nothing sleeps, 0005). Its step shape `(step state event) -> (values state' actions)` is `conn-step`'s (design §4.1), so M2 drops its core where the stub stands. `tests/trace-lane.sls` extracts M1.2's driver so the trace suite and the ratchet share one comparator (the `render-trace` seam moved there). `tests/ratchet.txt` records a status per fixture per lane (436 entries) and `tests/test-ratchet.sps` gates it BOTH ways (0008 item 6): the deferred/in-scope split is derived from each fixture's meta and checked against the manifest (a refresh cannot smuggle a lenient fixture in as not-yet); the trace lane is RE-RUN here (135 pass, not merely trusted from M1.2); outcome and libhtp open at 0 passing / all not-yet, their comparators being M2's. Opening state measured: trace 135 passing / 32 deferred; outcome 135 not-yet / 32 deferred; libhtp 102 not-yet. Watched to fail (m1-mutations.md M1.4-A/B/C): the fake shell's recording order, and the ratchet in both directions (an unbacked promotion, and an unexplained improvement). `make test` green, ten suites, 95 expected passes, exit 0.

M1 COMPLETE and merged (6b80953, PR #6) — the instrument stands with no server. The exit criteria are met on the tree: 135 strict fixtures render byte-identically at `'extremes` (253 runs) and `'full` (9,394 runs, `CORPUS=full`); the 102 libhtp streams load with sha256 verified; the ratchet stands at trace 135 / outcome 0 / libhtp 0, 32 deferred; `make check-imports` reports no new import under `src/http-server/` (M1 added no shipped code — every library is test-only under `tests/`); the seven mutations are recorded. The suite count went from M0's five to ten (added corpus-inventory, trace-lane, libhtp, fake-shell, ratchet).

NEXT: M2 — the pure connection core (design §4), on a branch cut from main at 6b80953 when the owner asks. `conn-step` drops into the fake shell (M1.4) where the stub step stands now, and the outcome lane's 135 not-yet entries are promoted to passing as reviewed ratchet diffs as chunk-size invariance is proven; §3 assigns `max-header-field-bytes` and `max-header-value-bytes` to M2. Sliced M2.1–M2.5 in the plan; likely two PRs (M2.1–M2.2, then M2.3–M2.5). Read the plan's §6 for the slice-by-slice, then `.superpowers/sdd/progress.md` NEXT.

---

M2 — THE PURE CONNECTION CORE. Branch feat/m2-connection-core, cut from main at fe69627 (6b80953 plus the ledger commit that recorded M1's merge). 2026-09-23 (Darwin arm64, Chez 10.4.1 `tarm64osx`). M2.1 MERGED to main as 85e7d81 on 2026-09-23 (PR #7, `gh pr merge --squash --delete-branch`): local main fast-forwarded to 85e7d81 and in sync with origin, feat/m2-connection-core deleted local and remote, `make test` green on main (eleven suites, 157 expected passes, exit 0). The PR's `linux` check failed with zero steps executed, stopped by GitHub's account billing check like every earlier run, so it tells us nothing about the code.

CI RUNNER PINNED, between M2.1 and M2.2. PR #8 (fix/ci-runner-pin, cut from main at d4a49e7) MERGED to main as 1ee58d5 on 2026-09-23 (`gh pr merge --squash`): local main fast-forwarded to 1ee58d5 and in sync with origin, fix/ci-runner-pin deleted local and remote. The `linux` job runs on `ubuntu-24.04` instead of `ubuntu-latest`, which GitHub moves to Ubuntu 26.04 from 2026-10-19 (actions/runner-images#14748). The Chez cache key now carries the OS release, which step `os` reads from `/etc/os-release` (`chez-Linux-ubuntu-24.04-X64-10.4.1-threads`), so an image change misses the cache instead of restoring a Chez built against another release's libraries. Nothing was cached under the old key: the repository had no Actions cache entries. No run has proven it. Re-measured 2026-09-23: all 20 Actions runs failed with zero steps executed, stopped at the billing check. That includes PR #8's run (35938111807) and the push of 1ee58d5 (35938556500), and it supersedes the rung-3 section's count of ten. Neither of those two runs carries the "ubuntu-latest will migrate" notice that PR #7's run did. Checked locally instead (Darwin arm64): actionlint 1.7.12 is clean; the step's own script, run with `bash -e` in local ubuntu:24.04 and 26.04 images, names `ubuntu-24.04` and `ubuntu-26.04` and, with VERSION_ID missing, exits 1 having written nothing; seven mutations were watched to fail (listed in PR #8's body); `make test` green, eleven suites, 157 expected passes, exit 0.

M2.1 FOLLOW-UPS MERGED, between M2.1 and M2.2. PR #9 (docs/m2.1-follow-ups, cut from main at ce76004) MERGED to main as 62104ee on 2026-09-23 (`gh pr merge --squash --delete-branch`): local main fast-forwarded to 62104ee and in sync with origin, docs/m2.1-follow-ups deleted local and remote, the squash tree identical to the branch tip's (d5d3103), `make test` green on main (eleven suites, 157 expected passes, exit 0). It is docs and evidence only: decision 0002's three dated amendments (the sixteenth action; what the allocation gate measures; parser callbacks enter directly), `research/spike/m2-event-alloc.sps` with its two runs, and the MEASURED, SETTLED and DECIDED entries below. PR #9's `linux` check (run 35939792913) executed zero steps, stopped at the billing check as every run has been.

Slices ①②③④⑤: ① vocabulary + table — MERGED (85e7d81, PR #7); ② head + request accumulator — MERGED in four PRs: the parser entry points (722269e, PR #10), the pure libraries (7e4ba1a, PR #11), the head (a75bf39, PR #12), and the corpus and allocation checks (70cb0cf, PR #13); ③ request-target through uriparse — MERGED in four stacked PRs: the target's limit (0e789d1, PR #14), the target judge (1197f51, PR #15), the core judging the target (b3a37c9, PR #16) and the narrow redirect (ab6725d, PR #17); ④ message loop: pause, read-stop, pending input — MERGED in four stacked PRs: the pending input (936937d, PR #23), the message loop (99c0f21, PR #24), the outcome lane (955c68e, PR #25) and decision 0004 item 2 settled, the pipeline cap accepting only 1 (11abb8c, PR #26); ⑤ hand-off door + error rows — MERGED (f5c13ca, PR #27). The plan expected two PRs (①② then ③④⑤). ① alone is 596 inserted lines of code and tests (connection.sls 302, test-connection-table.sps 282, the fake shell's tick 12), over plan §1 rule 1's ~400, so on the owner's word (2026-09-23) it went up as its own PR. Mutation log: `.superpowers/sdd/m2-mutations.md`.

M2.1 DONE: `src/http-server/connection.sls`, `(http-server connection)`, importing `(rnrs)` and `(http-server response)` only. It exports the three closed sets as data (`conn-states` 9, `conn-events` 15, `conn-actions` 16), a linear state record (`make-conn-state`, which refuses a phase outside the nine) and `conn-step`, which raises an assertion violation on an event outside the vocabulary (including one that is not a tagged list). Design §4.4's nineteen rows run as data in `tests/test-connection-table.sps`: 10 happy-path and 9 termination/error rows, 33 instances, each driven from a synthetic state by one synthetic event, with no parser. "any" and "head/body" rows get one instance per state they name. A row with no instance is missing from the coverage count, and the count is asserted against the design's 10 + 9. `conn-step` also runs inside M1.4's fake shell, where the stub step used to be: an idle tick closes the connection. Watched to fail (m2-mutations.md): the plan's mutation turns exactly H9 and H10 red. Six more mutations cover the closed event set (both arms), the tick guard, the coverage count, the sixteenth action and the phase check. `make test` green: eleven suites, 157 expected passes (95 before; connection-table adds 62), exit 0. `make check-imports` is clean.

Settled in M2.1, open to the owner's review:

1. **Sixteen actions, not fifteen.** Decision 0006 item 3 says that for an upgrade the core emits `(hand-off request unconsumed-bytes)`. Design §4.4's hand-off row names that hook, but decision 0002 item 2, design §4.1 and the plan's M2.1 text all list fifteen actions without it. `conn-actions` therefore has `hand-off` as its sixteenth entry, and M2.1-F shows the entry is load-bearing. M2.1 emits `(hand-off request)`. The retained bytes (0006: `parser-result-next` onward) arrive with M2.4's remainder mechanism, and 0006 puts the contract test in M8. Done on the owner's word: 0002 carries a dated amendment (2026-09-23) naming the sixteenth action. Design §4.1 and the plan's M2.1 entry still say fifteen and cite 0002 item 2, which the amendment now completes.
2. **Deadlines are kinds, not instants.** 0005 and design §2 keep `deadline` and `deadline-kind` in the pure state and key the wheel by `(deadline div tick-ms)`. But `tick` is the only event carrying `now` (§4.1), so the core has no time to add a duration to when it arms a deadline. Also, `write-timeout-ms` is not a limits field until M5 (plan §3). So `(arm-deadline kind)` carries only the kind, and the state records which kind is armed. M5's wheel turns kind plus limits into an instant with `uv-now`, and ticks a connection only after its deadline has passed. The core acts on a tick only while that kind is still armed, and M2.1-D witnesses that guard. M5 decides whether the core should also compare `now`, which would put `now` on the events that arm deadlines.
3. **The state is linear.** `conn-step` updates the state in place and returns it. This is "pure by contract" in 0002's consequence sense: the design §7.5 prior is the naive core that copied a record per event, at 6,832 B per request against the 3 KiB gate.
4. **Events and actions are tagged lists**, and M1.4's fake shell now delivers `(tick now)` rather than `(tick . now)`. Its clock assertion was updated first and watched red, and the connection suite checks that shape.
5. **`close-after` carries the reason**, not just `#t`, and `close` carries it on: `(close reason)`. The M2 exit compares the close reason, so the core has to hold it between the error and the last write completion. The reasons so far are `eof`, `read-error`, `idle-timeout`, `parser-error`, `header-timeout`, `handler-failed`, plus the synthetic `not-keep-alive` that M2.2's keep-alive decision will set for real.

Found and recorded, not acted on. Each item is owned by a later slice:

- **(M2.5)** A CONNECT or Upgrade hand-off arrives after `on-message-complete`, so its source state is `handling`, not `head`/`body` as design §4.4 has it. The corpus shows this: in `vendor/chez-httparse/test/vendor/llhttp/request/method.md`, "CONNECT request" logs `off=116 message complete` and then `off=116 error code=22 reason="Pause on CONNECT/Upgrade"`. By the time the hand-off result arrives, the core has already emitted `call-handler` for that message. M2.1 implements the row as written, from synthetic events. M2.5 replays real results, so it must re-derive the source state and decide whether an upgrade message reaches the handler at all.
- **(M5)** The three error entries into `responding` (parser error, header timeout, handler failure) arm no write deadline in §4.4. §4.3 says `responding` arms one, and the handler-responded row does. The parser-error row also leaves the header or body deadline armed. M2.1 implements the rows literally, because the table is the spec; M5 owns the write deadline and should reconcile them.
- **(M8)** The shutdown row has nothing to drain through. "any, shutdown-requested → draining: finish in flight … then shutdown", but no row has `draining` as its source, and §4.3 says draining does not read, so a half-read request cannot finish there. Yet §4.4's own prose ("`bytes-arrived` in draining produces no `feed-parser`") implies that draining does read. M2.1 instantiates the row only on `idle`, where "finish in flight" means nothing: it goes to draining and emits `(shutdown)`. The in-flight states and `shutdown-completed` are M8's.
- The eof row's "(or finish the in-flight response first, from responding)" cannot happen in v1, because `responding` does not read. It is instantiated on `idle`, `head` and `body`.

MEASURED (2026-09-23, at the owner's request, after M2.1 merged; Darwin arm64, Chez 10.4.1 `tarm64osx`, chez-httparse at the v0.4.0 pin): what M2.1's parser events cost against the 3 KiB gate. `.plans/research/spike/m2-event-alloc.sps` runs cps-core.sps §4's workload: one keep-alive GET with three headers, fed whole, one parser with shared bindings, 1,000 untimed requests and then 10,000 measured. It reads the cumulative `(sstats-bytes (statistics))` counter, never the live heap. The two runs are identical (`out/m2-event-alloc.run{1,2}.txt`, exit 0):

    calibration: 10000 conses read as 160160 bytes (16 per pair)
    shape: (parser-event name) 32 B; (parser-event name bv from to) 80 B; pev record 48 B
    callbacks per keep-alive request: 24 = 10 spans + 14 events
    A0     parser alone, silent, no pause (cps-core 4b):      1600 B/request  (52% of the 3072 B gate)
    A1     parser alone, silent, pause + resume:              1600 B/request  (52% of the 3072 B gate)
    B      A1 + M2.1's tagged-list events:                    2848 B/request  = A1 + 1248  (92% of the 3072 B gate)
    B-rec  A1 + a record per callback:                        2752 B/request  = A1 + 1152  (89% of the 3072 B gate)
    B-reuse A1 + one reused event per shape:                  1600 B/request  = A1 + 0  (52% of the 3072 B gate)
    C      M2.1's conn-step, the whole cycle:                 3280 B/request  = A1 + 1680  (106% of the 3072 B gate)
    C-reuse C with no event allocated per callback:           2032 B/request  = A1 + 432  (66% of the 3072 B gate)

Reading:

1. The parser alone still costs 1,600 B at the v0.4.0 pin, reproducing cps-core's 4b figure (2026-09-19) exactly. Pausing and resuming at every message adds nothing.
2. M2.1's tagged lists cost 1,248 B per request: the 24 callbacks at their shapes' prices, 41% of the gate on their own. A record per callback saves only 96 B. An event that is not allocated per callback costs nothing.
3. M2.1's whole cycle costs 3,280 B per request, over the 3,072 B gate before M2.2 copies a single byte of the request. The cycle is the parser events, the four shell events (`bytes-arrived`, `parser-result`, `handler-responded`, `write-completed`) and the action lists. For scale, cps-core's request builder added 1,072 B over the parser for the method, the URL and three header pairs.
4. The gate's scope was not pinned. 0002's consequence calls it the gate "for the core", but its two priors measure different things: 2,672 B for the CPS prototype includes the parser, while 6,832 B for the naive prototype was the pure core alone (async-sans-io proposal). Read as a total, the way cps-core measured, M2.1 is already over. Read as the core alone (C − A1), it is 1,680 B, 55% of the gate. Either way, the per-callback lists are the largest cost the core adds.
5. With no event allocated per callback, the cost a direct entry point would leave, M2.1's cycle is 2,032 B, A1 + 432. The 432 B is the four shell events and the action lists. Under a total gate, that leaves 1,040 B for M2.2's request builder, less than cps-core's copying builder cost.

SETTLED on the owner's word (2026-09-23), recorded as 0002's second dated amendment, "what the allocation gate measures":

- **The number was never derived.** It first appears in the research phase's performance review (`judge-performance-operability.md` §5) as the CPS prototype's 2,672 B rounded up to the next KiB. The brief sets no throughput or latency target it could come from. It is a regression ratchet, not a requirement.
- **It is a total** (parser, adapter and core), the way its anchor was measured. The naive prior stays only as the counterexample. The response path is outside the anchor, since cps-core's handler writes nothing, so M3 re-measures with it and records the result in 0002.
- **Shape checks are the real guard.** Following chez-httparse's allocation lane ("the claim is a shape, not a number"), M2.2 and M2.3 add three: no allocation per parser callback unless the core keeps that callback's data; no allocation that grows with header or target length; and a constant cost per request. This is re-planned here, since the plan's M2.2 and M2.3 entries name no such check.
- **A byte target waits for a throughput goal**, which M8's load smoke is the first place to set. Until then, a measured reason to move 3 KiB gets a dated note on 0002.

DECIDED on the owner's word (2026-09-23), recorded as 0002's third dated amendment, "parser callbacks enter directly": parser callbacks get a path that allocates no event, the recommended shape below. The tradeoffs that were weighed:

- **The recommended shape.** The adapter calls a direct entry point with the callback's own arguments, and `conn-step`'s `parser-event` arm only unpacks the list and delegates to it. The table tests and the fake shell keep their tagged lists, and one test checks that both ways in agree.
- **Its costs.** It is a second way into the core, which 0002's "conn-step is the interface" would need to record. It is really three entry shapes: spans, bare events, and `on-headers-complete` with the parser fields the adapter reads. The core must build whatever it keeps from a span, whereas today H5's `deliver-body` shares the event's tail. And the real shell's parser events no longer appear as data, so tracing them needs a hook.
- **Why not the alternatives.** A reused mutable event also measured 0 B, but anything that shares its tail is overwritten silently by the next callback. A record per callback saves only 96 B.

M2.2 FIRST STEP DONE: parser callbacks enter directly (0002's third amendment). Branch feat/m2.2-request-head, cut from main at 7f5865e; 2026-09-23, Darwin arm64, Chez 10.4.1 `tarm64osx`. MERGED to main as 722269e on 2026-09-24 (PR #10, `gh pr merge --squash --delete-branch`): local main fast-forwarded to 722269e and in sync with origin, feat/m2.2-request-head deleted local and remote, the squash tree identical to the branch tip's (c4a3517), `make test` green on main (twelve suites, 187 expected passes, exit 0). PR #10's `linux` check (run 35981345275) executed zero steps, stopped at the billing check as every run has been. `(http-server connection)` now exports:
- `conn-parser-callbacks`, chez-httparse's 25 callbacks in llhttp's trace order, and `conn-span-callbacks`, the 10 that carry a span, both as data;
- `conn-parser-step`, whose two arities are the event shape and the span shape;
- `conn-headers-complete-step`, which takes on-headers-complete's five parser fields.

`conn-step`'s `parser-event` arm only unpacks the payload and calls them, so the transitions live in one place. `tests/test-connection-entry.sps` (30 checks) holds the amendment's rules:
- the closed set, against chez-httparse's own callback table and its parser, which refuses a binding list with a hole or an extra name;
- the reply first, for all 25 callbacks in all 9 states;
- both ways agree: one step for every callback in every state, and whole parses of three inputs recorded from the real parser (two pipelined GETs, a POST with a Content-Length body, a chunked POST with an extension), with the handler cycle between messages;
- the per-callback shape check.

Watched to fail (m2-mutations.md): against `main` the suite exits 255; against a skeleton whose entry points wrap each callback in a tagged list and call `conn-step`, it fails the closed set, reply-first and the allocation check, and both ways agree. Six mutations follow. `make test` green: twelve suites, 187 expected passes (157 before; connection-entry adds 30), exit 0. The step is 476 inserted lines of code and tests (`connection.sls` 138, the suite 334, H4 4), over plan §1 rule 1's ~400, so on the owner's word (2026-09-24) it went up as a PR of its own ahead of the head.

MEASURED (2026-09-23, Darwin arm64, Chez 10.4.1 `tarm64osx`), each callback entered 10,000 times through its entry point on fresh states, in the state it arrives in during a request, with the arguments written out as the adapter will write them:
- 23 of the 25 allocate 0 B per call;
- `on-body-data` allocates 112 B: the `deliver-body` action it passes on, and its list. The cost is the same for a 1-byte span and a 1,000-byte one;
- `on-message-complete` allocates 96 B: the `call-handler` action carrying the request, and its list.

The suite asserts the zeros and the length-independence, not the byte counts.

Settled in the first step, open to the owner's review:

1. **Every parser callback is answered, in every state.** M2.1 answered a callback with no row with no actions at all, which leaves the adapter nothing to hand the parser. A callback now always gets `(reply-parser …)` first. One with no transition from the current state answers `continue` and changes nothing. That includes the request-line callbacks in `head`, `on-reset` in `idle` and the chunk callbacks in `body`; the head gives transitions to the ones whose data it keeps.
2. **The names**: `conn-parser-step` for the 24, and `conn-headers-complete-step` for on-headers-complete.
3. **on-headers-complete's tagged form carries the five fields**: `(parser-event on-headers-complete method http-major http-minor flags content-length)`. H4's instance now carries llhttp's GET (method 1), HTTP/1.1, no flags, no length. This step accepts the fields and does not read them, so a tagged path that passed them in the wrong order would survive; the head makes them load-bearing.
4. **The adapter calls the entry points with arguments written out.** In this step's own test, `apply` spreading on-headers-complete's six arguments allocated 16 B per call, where the same call written out allocated nothing. The tagged path uses `apply`; it is the tables' way in, not the allocation-free one.

Found and recorded, for the head: **the plan's M2.2 mutation cannot bite as written.** The plan predicts that reading `flags` at on-message-complete instead of on-headers-complete sends every keep-alive decision wrong in the same direction. Measured over the 135 strict fixtures, each fed whole (2026-09-23):
- 77 messages reach both callbacks. Their flags differ in 11, and only in bit 128, `F-TRAILING`, which the zero chunk sets and `should-keep-alive?` does not read.
- All 143 `on-message-begin` calls see flags 0.

chez-httparse clears flags and content-length only after on-message-complete returns (its grammar's `after-message` runs before `restart-clear-flags` and `restart-clear-length`). Its `docs/api.org` says to read the flags "inside on-headers-complete or on-message-complete". So flags read at on-message-complete give every keep-alive decision the same answer, and the mutation would survive every test: the survivor would be the plan's premise, not a missing test. What does change between the two callbacks is content-length, which counts down to 0. The head needs a mutation that bites instead, for example flags as the reset leaves them (0). Every request would then get its version's default: a close-marked HTTP/1.1 request would stay open, and an HTTP/1.0 keep-alive request would close.

M2.2 SECOND STEP: the pure libraries. Branch feat/m2.2-libraries, cut from main at 8e957ca; 2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`. MERGED to main as 7e4ba1a on 2026-09-24 (PR #11, `gh pr merge --squash --delete-branch`): local main fast-forwarded to 7e4ba1a and in sync with origin, feat/m2.2-libraries deleted local and remote, the squash tree identical to the branch tip's (3aff1c5), `make test` green on main (fourteen suites, 225 expected passes, exit 0). PR #11's `linux` check (run 35991501418) executed zero steps, stopped at the billing check as every run has been.
- `(http-server limits)` gains `max-header-field-bytes` and `max-header-value-bytes`, 8,192 each (decision 0005's defaults), with the four things plan §3 asks of a new limit: the fields, a default test, their variables appended to `limits-environment-variables`, and the drift guard. The variable list is now asserted whole, eleven in field order, and the drift guard compares every field of `default-limits` with the empty environment. docs/configuration.org lists both.
- `(http-server span)`, new: the bytes [start, end) of a bytevector, its bounds checked when it is made, and `span->bytevector` to copy one. It is not in design §3.1's table of libraries; it is introduced here.
- `(http-server request)` documents what the core puts in the record: the method as llhttp's name (a symbol), and the target and each header name and value as spans. The record's fields are unchanged.
- `(http-server headers)` compares names that are spans or bytevectors.
- `(http-server decisions)`, new: every status the server originates, in one place (design §6.5). `reason-status` maps the core's own reasons: parser-error 400, header-timeout 408, the four header limits 431, handler-failed 500. `parser-error-status` maps chez-httparse's 18 error-channel codes to 400, except invalid-transfer-encoding at node `e-request-invalid-te` (501) and paused-h2-upgrade (505). The node split is checked against the parser at the pin: `Transfer-Encoding: pigeons` maps to 501 and `chunked,deflate` to 400.
- global-constraints.md's import rule for pure libraries now lists `(httparse decisions)` and `(httparse methods)`, as design §3.1 already did.

Watched to fail (m2-mutations.md): each new suite was red before its code, and mutations L, O, P and Q follow. 369 inserted lines of code, tests and docs. On main with this step alone, `make test` is green: fourteen suites, 225 expected passes.

Settled in the second step, open to the owner's review:

1. **The request carries spans.** The target and the header names and values are spans of the delivery (design §7.1; the no-growth shape of 0002's second amendment), and the method is llhttp's name as a symbol. The core fills them in the third step. A handler that keeps bytes past its request copies them with `span->bytevector`. What handlers see is M4's to settle.
2. **What `max-header-bytes` counts**: the header names and values as the parser delivers them, not the separators or the request line (the target has its own limit, M2.3). docs/configuration.org says so, and the core enforces it in the third step.
3. **Framing precedence moves to M3.** The plan puts it in `(http-server decisions)` in M2.2, but nothing on the request path consumes it. In strict mode chez-httparse itself refuses a request with both Transfer-Encoding and Content-Length, or with a coding after chunked, and delivering a request body is M6's. The framing decision with a consumer is the response's, M3.2's serializer.
4. **The global constraints' import list** now matches design §3.1. The core, in the third step, is the first pure library to import `(httparse decisions)` and `(httparse methods)`.

M2.2 THIRD STEP: the head. Branch feat/m2.2-head, cut from main at 083f347; 2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`. MERGED to main as a75bf39 on 2026-09-24 (PR #12, `gh pr merge --squash`): the squash tree identical to the branch tip's (71473fa). The branch was kept until #13, stacked on it, had been retargeted to main, and then deleted local and remote. PR #12's `linux` check (run 35992263518) executed zero steps, stopped at the billing check.
- `make-conn-state` takes the limits as a seventh argument and keeps a head per connection, rolled at each on-message-begin.
- In `head`, the target and each header name and value are kept as spans of their delivery. A name or value split across deliveries is copied once, when it completes.
- on-headers-complete's fields give the method, the version and the keep-alive decision. The method is llhttp's number, looked up in a vector built from `(httparse methods)`' table, so naming it allocates nothing. Keep-alive is `should-keep-alive?` over the flags; a message that does not keep the connection alive sets `close-after` to `not-keep-alive`.
- The four header limits are checked as their bytes arrive, and the count as each name completes. A tripped limit answers `(reply-parser (fail reason))` and holds the reason. The parser's error result is then answered with the reason's status, 431, not the parser's (design §6.3).
- `respond-and-close` takes the reason and reads the status from `reason-status`, so 408, 431 and 500 come from one table.
- `bytes-arrived` feeds the parser in `head` and `body` too.
- `(http-server private adapter)` binds the parser to the core. It holds one list of the 25 bindings, shared by every connection, and a per-connection context holding the state and the actions queued during a feed. It reads the five fields inside on-headers-complete, and turns each reply into continue, pause, or a callback failure carrying the reason.
- `tests/test-connection-head.sps` (17 checks) drives chez-httparse through the adapter at every delivery size. It covers the request's contents; decision 0006 item 1's keep-alive rows, alone and pipelined; each header limit at its bound and one past it; and a parser error with no refusal, answered 400. The table and entry suites now pass limits, and the entry suite's shape check covers the head's callbacks.

Watched to fail: the head suite was red before the head and the adapter existed, and mutations G, H, I, J, M and R follow. 600 inserted lines. With the second step, `make test` is green: fifteen suites, 241 expected passes.

MEASURED (2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`), each callback entered 10,000 times through its entry point on fresh states:
- 18 of the 25 allocate 0 B;
- `on-url-data`, `on-header-field-data` and `on-header-value-data` allocate 32 B each, the span;
- `on-header-value-complete` allocates 32 B, the header's two pairs;
- `on-headers-complete` allocates 64 B, the request record (with an empty head);
- `on-body-data` allocates 112 B and `on-message-complete` 96 B, as in the first step.

Each is the same for a 4-byte span as for a 1,000-byte one.

Settled in the third step, open to the owner's review:

1. **The adapter arrives now, not in M4.1.** The head's tests and the fourth step's property 1 both need the core driven by the real parser, and 0002 item 4 puts the field reads in the adapter. M4.1 keeps the shell's closures, a tracing hook (0002's third amendment) and the per-connection allocation assertion.
2. **Header names are not interned.** Design §7.1 lists interned lower-cased names among what is copied. Nothing reads names as symbols yet, and interning from bytes needs a table keyed by bytes; `(http-server headers)` compares case-insensitively instead.
3. **Name and value limits are checked as the bytes arrive.** Plan §3 checks them at their -complete callbacks; checking as the bytes arrive refuses the same messages, earlier. The count is checked as each name completes.
4. **A refusal waits for the parser's error.** Design §4.4's head row keeps the state in `head` after `fail`, so the core holds the reason until the error result arrives, and T3 answers it.
5. **Every originated status comes from one table.** `reason-status` now holds the 408 and 500 that M2.1 wrote as literals. T4 and T6 still pass, and M2.2-M shows the core reads the table.
6. **The plan's mutation is replaced.** M2.2-G passes the flags as 0, what the parser's reset leaves, and turns red exactly the keep-alive rows that carry a `Connection` header. The plan's version cannot change an answer (above, "Found and recorded, for the head").

Found and recorded, for later slices:
- **(M2.4)** The head suite's driver is a small message loop: feed on `feed-parser`, run the handler cycle at the pause, resume from `parser-result-next`, stop at close. M2.4 builds that loop into the fake shell.
- **(M6) Trailers.** A chunked body's trailer fields arrive as header callbacks in `body`. The core answers them continue, keeps nothing, and counts them against no limit.
- `research/spike/m2-event-alloc.sps` calls `make-conn-state` with six arguments and no longer runs against this tree. Its recorded outputs stand for 62104ee.

M2.2 FOURTH STEP: the corpus and allocation checks. Branch feat/m2.2-checks, cut from feat/m2.2-head at 71473fa; 2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`. MERGED to main as 70cb0cf on 2026-09-24 (PR #13, `gh pr merge --squash --delete-branch`). #13 was stacked on #12. Once #12 merged, #13 was retargeted to main and rebased onto a75bf39, dropping 71473fa, as 5115f31, whose tree is identical to bd31436's; it was force-pushed with a lease. Local main fast-forwarded to 70cb0cf and in sync with origin, feat/m2.2-checks deleted local and remote, the squash tree identical to 5115f31's, `make test` green on main (sixteen suites, 250 expected passes, exit 0). PR #13's `linux` checks (runs 35992361539 on bd31436 and 35992549026 on 5115f31) executed zero steps, stopped at the billing check.
- The trace lane now also runs every strict fixture with the core's bindings installed beside the recorder's. This is design §8.1's property 1: the connection layer must not perturb parsing. The core answers every callback and pauses at each message's end; the driver runs the handler cycle and resumes. All 135 fixtures render their recorded logs at 'extremes (253 runs) and at 'full (9,394).
- `tests/test-connection-allocation.sps` runs the CPS workload (a keep-alive GET with three headers, fed whole) through parser, adapter and core with the shell's whole cycle. It checks the total against the 3,072 B ratchet, and the other two shapes of 0002's second amendment.

Watched to fail by mutation only (N, H, K), since both checks were written after the code they measure. 237 inserted lines.

MEASURED (2026-09-24, same platform), the allocation lane:
- 2,624 B per request on the CPS workload, 85% of the 3,072 B ratchet;
- 2,624 B with a 500-byte target and a 500-byte header value;
- requests 11,001 to 21,000 cost what requests 1,001 to 11,000 did.

For scale, the spike measured M2.1's cycle with no event per callback at 2,032 B (C-reuse, on 62104ee's tree). Counting what each allocates, the 592 B between the two are the head (432 B: the target's and six header spans, three headers' pairs, the reversed header list and the request record) and the adapter's action queue (160 B: 48 B of pairs, and 112 B that `conn-context-take-actions!` spends copying).

Found and recorded, for later slices:
- **(M2.3) The target's validation may not fit under the ratchet.** The head leaves 448 B under 3,072 B. Design §7.5 measured uriparse's validation of a 46-byte origin-form target at 1,584 B with the collector reset (2026-09-19). M2.3 measures it through the core on its own tree. If it still costs that, either the allocation is found, or 0002 gets a dated note moving the ratchet with that measurement as the reason. One saving is already known: an iterator over the adapter's queued lists would not spend the 112 B that `conn-context-take-actions!` copies.
- **(M2.4)** The trace lane's core driver is the same small message loop as the head suite's.

M2.2 DONE and MERGED: its last PR, #13, landed as 70cb0cf. `make test` green: sixteen suites, 250 expected passes, exit 0. Against the 187 before the second step, the four new suites add 51 (connection-allocation 8, connection-head 17, decisions 12, span 14); limits gains 4, headers 6, records 2 and trace-lane 1; and connection-entry has one fewer, its two body-span checks having become one over all four kept spans. `make check-imports` is clean. The second, third and fourth steps come to 1,206 inserted lines of code, tests and docs (369, 600, 237), and each tree is green on its own: 225, 241 and 250 expected passes.

---

M2.3 — THE REQUEST-TARGET. Branch feat/m2.3-request-target, cut from main at 8209de6; 2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`. The slice goes up as four stacked PRs, one per step below: feat/m2.3-request-target, then feat/m2.3-target-judge, feat/m2.3-target-core and feat/m2.3-target-redirect, each cut from the one before. Each step's tree passes `make test` on its own. MERGED to main on 2026-09-24, bottom up, as four squash commits: 0e789d1 (PR #14), 1197f51 (PR #15), b3a37c9 (PR #16), ab6725d (PR #17).
- #14 merged without deleting its branch, since #15 was based on it. Each PR above it was then retargeted to main (`gh pr edit --base main`), rebased onto the squash below it (`git rebase --onto`) and force-pushed with a lease. Each rebased tree was identical to the one tested: 0051e22 to 3b03292, eb92f5f to ade452a, 44ea0ef to 2ff65ed. Each squash tree was identical to its tip's, and main's final tree is identical to the tested 2ff65ed.
- Every `linux` check executed zero steps, stopped at the billing check. That covers the four PR runs (36072710925, 36072726353, 36072750493, 36072770871) and the three runs on rebased tips (36073646847, 36073690029, 36073734316).
- #17 merged with `--delete-branch`, which fast-forwarded local main to ab6725d. The other three branches were deleted local and remote by hand, and refs pruned; no PR is open. `make test` green on main: seventeen suites, 303 expected passes, exit 0.

MEASURED (2026-09-24), before the target was judged. `.plans/research/spike/m2.3-target-alloc.sps` measures what the plan's route costs and what it judges. Two runs gave identical output (`out/m2.3-target-alloc.run{1,2}.txt`, exit 0):

    per target, B per validation   plan's route | charset route (copying) | validate-component alone
      2-byte target                        1232 |                      16 | 0
      46-byte target                       1584 |                      80 | 0
      500-byte target                      2720 |                     512 | 0
    the plan's route on /a, cumulatively: reset 16, + feed 592, + finish 1232, + validate 1232
    CONNECT example.com:443, the fresh strict validator: 3696; absolute-form, a reused 'uri collector: 1984
    per request, whole cycle     no validation 2624 (85%) | + plan's route 3856 (125%) | + charset route 2640 (85%)
      with a 500-byte target     2624                     | 5344 (173%)                | 3136 (102%)

Reading:
1. The design's 1,584 B for a 46-byte target (§7.5) reproduces exactly.
   - On the CPS workload's 2-byte target, the plan's route costs 1,232 B. It puts the cycle at 3,856 B, 784 B over the ratchet, and it grows by about 3 B per target byte.
   - All of that cost is the collector's feed and its assembly of components; validation itself allocates nothing. The core keeps the target as a span and uses no component.
2. The plan's route judges origin-form as RFC 3986 does, not as RFC 9112 does: a leading "//" opens an authority.
   - `//a@b:c/d` is a valid origin-form target (RFC 9110 §4.1: absolute-path = 1*( "/" segment )), but the plan's route refuses it as `invalid-port`.
   - It also accepts `/a#b`.
3. Judging origin-form as RFC 9112 writes it costs only the copy that `validate-component` needs, since it takes a whole bytevector. The target is split at the first "?", and the two parts are judged by `(uri charset)`.
4. 94 messages across the 135 strict fixtures reach on-headers-complete. Of these fixtures, a validating core refuses eight that llhttp parses on:
   - `uri.md#1` (`"`) and `uri.md#5` (`|`);
   - four fragments (`transfer-encoding.md#21-23`, `uri.md#8`);
   - `M-SEARCH *` (`method.md#5`);
   - absolute-form with userinfo (`uri.md#10`).

DECIDED on the owner's word (2026-09-24), asked with the numbers above:
- **Origin-form is judged by the charset route.** uriparse #21 was filed on 2026-09-24 for a `validate-component` over a range (https://github.com/Kiyomi-Computation-Systems/uriparse/issues/21). The copy is the carried workaround: 0008's row, and 0002's dated note on the target-length shape.
- **Three form rules, each answered 400:**
  - a fragment (RFC 9112 §3.2's forms have none);
  - `*` unless the method is OPTIONS (§3.2.4);
  - userinfo in absolute-form (RFC 9110 §4.2.4).
- **0002 item 1 is amended.** The core runs uriparse's scanner for absolute-form and CONNECT targets only (0002's dated amendment).

The alternatives weighed:
- the plan's route with the ratchet moved (3,856 B, with the `//` misjudgement and fragments accepted);
- the plan's route with an upstream fix first, M2.3 waiting on a collector that validates without assembling components;
- for 0002, keeping item 1 literal by splitting absolute-form ourselves as RFC 9110 §4.2.1's http-URI with `(uri host)` and `(uri charset)`, which is more URI code of our own.

M2.3 FIRST STEP: the target's limit. MERGED as 0e789d1 (PR #14).
- `on-url-data` counts the target's bytes as they arrive and refuses a target past `max-target-bytes` (8,192, decision 0005) with `(fail target-too-large)`. `reason-status` answers it 414, and docs/configuration.org says so.
- Two head rows: a target at the limit, and one byte past it, at every delivery size.

Watched to fail: mutations A, B and C. `make test` green: sixteen suites, 252 expected passes.

M2.3 SECOND STEP: the target judge, `(http-server target)`. MERGED as 1197f51 (PR #15).
- `(http-server target)`, new, exports `make-target-judge`, `target-judge?` and `target-fault : TargetJudge Symbol Span -> (U #f Symbol)`. The method and the first byte pick the form:
  - CONNECT: authority-form, through `uri-parse-authority-form-validate` over a copy of the span, parsed fresh.
  - `*` alone: asterisk-form, for OPTIONS only.
  - "/" first: origin-form. The target is split at its first "?", and the two parts are judged by `(uri charset)`'s `validate-component`, over copies.
  - anything else: absolute-form, through the judge's collector ('uri mode, made on the first absolute-form target and reset before each one) and `uri-parse-result-validate`. It must then carry no fragment and no userinfo. Userinfo is read by `(uri host)`'s `authority-host-span`, the validator's own split.

  A verdict is uriparse's code, or `'asterisk-not-options`, `'fragment` or `'userinfo`. The library is not in design §3.1's table of libraries; it is introduced here.
- `tests/test-target.sps` (24 checks) tables the four forms and the three rules. The library is pure, and the core does not call it until the third step, so this step's tree passes on its own.

Watched to fail: `test-target.sps` exited 255 before the library existed. The mutations against the library ran once the core used it, and are recorded with the third step. `make test` green: seventeen suites, 276 expected passes.

M2.3 THIRD STEP: the core judges the target. MERGED as b3a37c9 (PR #16).
- The core holds one judge per connection and judges the target in `conn-headers-complete-step`, where the method is known. A fault is refused as `'invalid-target`, which `reason-status` answers 400. The request's target is still its span.
- Six head rows, at every delivery size:
  - one row where a target of each form passes: `OPTIONS *`, a path that begins "//", and absolute-form;
  - five refusals answered 400: a byte outside RFC 3986's set, `*` with GET, an absolute-form fragment, absolute-form userinfo, and CONNECT without a port.
- The trace lane's property 1 lists the eight fixtures the core refuses by policy, each with its reason, and gates them both ways (design §8.1: the corpus is parser truth, not server truth):
  - each listed fixture is refused for its reason at every chunk size, and its trace is the log's own up to the refusal;
  - every other fixture's trace equals its log.

  `core-trace-at` now returns the refusal beside the trace. Green at 'extremes (253 runs) and at 'full (9,394).
- The allocation lane:
  - the CPS workload costs 2,640 B per request, 85% of the ratchet;
  - a 500-byte header value costs what a short one does;
  - a 500-byte target costs exactly its path's copy more, 3,136 B;
  - an absolute-form request costs exactly one reused collector's parse in place of that copy, 4,336 B;
  - the cost is constant per request.
- The table's H4 state holds a target, read in through on-url-data and on-url-complete as the parser delivers one. The entry suite's reply-first check accepts a refusal: a fresh head has no target, so it is refused.

Watched to fail (m2-mutations.md): each new check was red before its code, and mutations D through N follow. D is the plan's named mutation, a collector made per request, and it turns only the allocation check red.

`make test` green: seventeen suites, 287 expected passes, exit 0. That is 276 after the second step; connection-head now has 25, connection-allocation 10 and trace-lane 7. `make check-imports` is clean.

Settled in M2.3, open to the owner's review:
1. **One reason for every form rule.** A target the judge refuses closes as `'invalid-target`, or as `'target-redirect` when decision 0009 redirects it. Which rule fired is the judge's verdict, not the close reason.
2. **The target is judged at on-headers-complete**, where the method is known, not at on-url-complete. So a refused target's headers are still read, within the header limits.
3. **A head with no target is judged as an empty one, and refused.** The parser never completes a head without a target, and the synthetic states now read one in.
4. **`(http-server target)` is a library of its own**, so its forms and rules can be tabled without a parser.

Found and recorded, for later:
- **(M4) Absolute-form's host.** RFC 9112 §3.2.2 says an origin server MUST ignore Host and use the target's authority. The request carries the target as a span, and reading the authority from it is the handler-facing request's job, M4.
- **(owner) Two RFC rules no slice names.**
  - RFC 9110 §4.2.1: a recipient MUST reject an http(s) URI with an empty host. `http:///p` is not checked.
  - RFC 9112 §3.2: a server MUST answer 400 to an HTTP/1.1 request with no Host, with more than one, or with an invalid one.
- **(M2.5)** CONNECT reaches the handler before the hand-off (M2.1's finding). The head suite tests CONNECT only through its refusals, and test-target.sps covers the rest.

DECIDED on the owner's word (2026-09-24), after asking why llhttp accepts what M2.3 refuses: **bracket params and pipes are redirected, not refused** (decision 0009).
- **Why llhttp accepts them.** Its URL table admits every printable ASCII byte except space, `#` and `?`, under the comment "TODO(indutny): use RFC". Node 12 broke on `|` when it moved to llhttp (nodejs/node#27584), and the corpus now pins `|`.
- **What browsers send.** The WHATWG URL standard leaves `[`, `]` and `|` unencoded in paths and queries, and `{`, `}`, `\`, `^` and backtick in queries. So a strict core answers ordinary links 400. Checked 2026-09-24 against the standard's percent-encode sets. Tomcat, strict since CVE-2016-6816, added `relaxedPathChars` and `relaxedQueryChars` for the same reason.
- **What was decided.** RFC 9112 §3.2 allows a 301 to the target properly encoded in place of the 400. The owner chose the redirect, narrow: bracket params and pipes only.
- **Two guards the narrow reading needs.**
  - GET and HEAD only: a 301 may turn a POST into a GET (RFC 9110 §15.4.2).
  - No path that begins `//`: its Location would name another host.

M2.3 FOURTH STEP: the narrow redirect. MERGED as ab6725d (PR #17).
- `(http-server target)` gains `target-redirect : TargetJudge Symbol Span -> (U #f Bytevector)`. It returns the target with `|` percent-encoded in the path and `[`, `]` and `|` in the query, by uriparse's `pct-encode`. It does so only for GET or HEAD, only for origin-form, never for a path beginning `//`, and only when the encoded target is one the judge accepts and differs from the target.
- In `conn-headers-complete-step`, a refused target that redirects is refused as `'target-redirect`, and the head keeps the Location. The Location must also be within `max-target-bytes`. `respond-and-close` takes the response's headers, so the parser-error row answers `301` with `Location`. `reason-status` answers `target-redirect` with 301.
- New rows:
  - test-target.sps, 11: the redirected shapes, HEAD, the methods not redirected, brackets in a path, targets with another fault, `//`, `/\` (which browsers read as `//`), absolute-form, nothing to encode, a span inside a delivery, and the Location accepted;
  - the head suite, 5: a redirect end to end at every delivery size, a POST refused, `//` refused, and the Location at and past the limit.
- The trace lane's `request/uri.md#5` (`GET /test.cgi?query=|`) is now a listed redirect.
- Documentation:
  - decision 0009;
  - `docs/request-targets.org`, new and linked from the README and docs/configuration.org, covers what gets through, what gets 400 or 414, and the one redirect.

Watched to fail (m2-mutations.md): each new check was red before its code, and mutations O through X follow. P, the open-redirect guard, first turned only the target suite red, so the head suite gained its `//` row, and P turns that red too. The redirect is off the hot path: the allocation lane is unchanged at 2,640 B.

`make test` green: seventeen suites, 303 expected passes (target 35, connection-head 30), exit 0. The trace lane holds at 'full (9,394 runs). `make check-imports` is clean.

M2.3 DONE and MERGED: its last PR, #17, landed as ab6725d. `make test` green: seventeen suites, 303 expected passes, exit 0. Against the 250 after M2.2, the new target suite adds 35, connection-head gains 13, trace-lane 3 and connection-allocation 2. `make check-imports` is clean. The four steps are 476, 262, 361 and 377 inserted lines, and each tree passes on its own: 252, 276, 287 and 303 expected passes. uriparse #21 is still open, and the copy it would remove is carried.

UPSTREAM LANDED (2026-09-24, evening): uriparse v0.5.0 is tagged (4d95118, 20:12 -0400; its CHANGELOG dates the release 2026-09-25, UTC). #21 closed via PR #22 (bb8392a); the release is PR #23. `validate-component` on `(uri charset)` now takes an optional start and end, `Symbol Bytevector [Nat [Nat]] -> (values (Option Symbol) (Option Nat))`:
- the verdict on `bv[start, end)` is the verdict on those bytes alone, and nothing outside the range is read;
- a `%` whose HEXDIGs lie past `end` is malformed, and the index is relative to `start`;
- the two-argument call is unchanged, misuse diagnostics included (its decision 0034).

The release states no new conformance claim (its decision 0035): upstream 77/77, on macOS arm64 only. Between the two tags only `src/uri/charset.sls` changed under `src/`, and the byte-machine gitlink is still 0245db3. The local checkout's `main` is at e0aa810, the tag plus its ledger close-out, with `src/` identical to the tag.

The pin moves from v0.4.0 to the v0.5.0 tag, on a commit of its own (global-constraints): `vendor/uriparse` is at 4d95118, which `git describe --exact-match` names v0.5.0. Watched to fail, twice:
- with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2);
- with the Makefile moved and the gitlink not yet staged, `make test`'s submodule step checked 611b04b back out, and `check-pins` refused that in turn.

Found in review, and now a check: `make check-pins` also holds uriparse to the byte-machine on the library path (uriparse's own gitlink, `git rev-parse HEAD:vendor/byte-machine`, against `BYTE_MACHINE_PIN`), and refuses a vendored checkout with local edits to tracked files. A uriparse release on another byte-machine would otherwise pass, and so would a mutation left in a vendored file. Both watched to fail before and after:
- with `BYTE_MACHINE_PIN` given as forty zeros, the old check named only chez-httparse's copy; the new one names uriparse's as well (exit 2);
- with a line appended to `vendor/uriparse/src/uri/charset.sls`, the old check passed (exit 0); the new one answers `PIN DIRTY` (exit 2). The file was restored by sha256 (9cc2e325782d…).

The new comparison failed on its first run against a clean tree: a Makefile variable keeps the spaces before a trailing comment, so it compares `$(strip …)`.

Smoke evidence (`.plans/research/spike/smoke-uriparse-v050.sps`, Darwin arm64, Chez 10.4.1, `chez --libdirs vendor/uriparse/src:vendor/chez-httparse/vendor/byte-machine/src --program`, exit 0 on both runs, `out/smoke-uriparse-v050.run{1,2}.txt`; run 1 in full, and run 2's byte counts are identical):

    --- #21: ranged verdict == the verdict on a copy (expect agree in every component)
    / (path (#f #f) (#f #f) agree) no-query
    /api/v1/items/12345?fields=name,price&limit=50 (path (#f #f) (#f #f) agree) (query (#f #f) (#f #f) agree)
    //a@b:c/d (path (#f #f) (#f #f) agree) no-query
    /a<b>?q=1 (path (invalid-pchar 2) (invalid-pchar 2) agree) (query (#f #f) (#f #f) agree)
    /ok?q=a"b (path (#f #f) (#f #f) agree) (query (invalid-query 3) (invalid-query 3) agree)
    /x?a[]=1&b=| (path (#f #f) (#f #f) agree) (query (invalid-query 1) (invalid-query 1) agree)
    /p%zz (path (invalid-pct-encoded 2) (invalid-pct-encoded 2) agree) no-query
    --- a '%' whose HEXDIGs lie past end is malformed, though the bytes after end complete it
    whole /a%41: (#f #f) range [0,4) /a%4: (invalid-pct-encoded 2) range [1,5) a%41: (#f #f)
    --- 200000 origin-form targets judged per pass, path and query: in place vs on a copy
    in-place: 2 bytes-per-target 0 ns 25
    on-copy:  2 bytes-per-target 16 ns 30
    in-place: 46 bytes-per-target 0 ns 360
    on-copy:  46 bytes-per-target 80 ns 375
    in-place: 500 bytes-per-target 0 ns 3880
    on-copy:  500 bytes-per-target 512 ns 3920
    in-place: 2 bytes-per-target 0 ns 25
    on-copy:  2 bytes-per-target 16 ns 35
    in-place: 46 bytes-per-target 0 ns 355
    on-copy:  46 bytes-per-target 80 ns 375
    in-place: 500 bytes-per-target 0 ns 3900
    on-copy:  500 bytes-per-target 512 ns 3945
    done

Reading:
1. The server can judge an origin-form target's path and query in place, inside the delivery the parser handed it, and get the verdict the copy got. All seven targets agree in code and index, `//a@b:c/d` and decision 0009's `[` among them.
2. The copy was the only per-request cost that grew with the target: 16, 80 and 512 B at 2, 46 and 500 bytes. The ranged call costs nothing.
3. Nothing filed is open upstream: all fifteen asks are closed and released.
4. No check went red when the pin moved, although decision 0008 asks for one when upstream makes a workaround redundant. The #21 copy's allocation check held the copy's cost, which moving the pin does not change. Recorded in 0008, with the probe that would have met the rule.

`make test` at the moved pin, the copy still in place: seventeen suites, 303 expected passes, exit 0, and the CPS workload still costs 2,640 B. The pin MERGED as 6be4722 (PR #18). Updated: the Makefile (the pin, and `check-pins`), global-constraints (the pin), decision 0008 (row #21 and a dated note), the research README, and `tests/test-integration.sps` (its version comments).

M2.3 FOLLOW-UP: origin-form targets are judged in place. MERGED as a5eeb55 (PR #19). 2026-09-24 and 25, Darwin arm64, Chez 10.4.1 `tarm64osx`. Two stacked PRs, so each squash-merges as its own commit and the pin stays alone on main (global-constraints): chore/uriparse-v0.5.0, cut from main at bf6cb06, moves the pin (above); refactor/target-in-place, cut from it, is this entry.
- `(http-server target)` judges an origin-form target in one pass, in place. `validate-component` judges the whole target as a path; "?" is outside the path's set, so a fault at a "?" is where the query begins, and the query after it is judged next. The path is no longer walked twice, once to find the "?" and once to judge it.
- `range-copy` is gone: the redirect and CONNECT copy through `(http-server span)`'s `span->bytevector`. Both copies are accepted without an ask (0008's dated note): CONNECT's comes ahead of a fresh parse that costs far more (design §7.5), and the redirect's is on a refusal path, because `pct-encode` takes a whole bytevector.
- The allocation lane is back to the shape decision 0002's second amendment set, as its amendment of 2026-09-24 said it would be:
  - the CPS workload costs 2,624 B per request, 85% of the ratchet (it was 2,640 B);
  - a 500-byte target, all path, costs what a short one does (it was 3,136 B);
  - so does a new workload, a 500-byte target that is nearly all query;
  - an absolute-form target costs one reused collector's parse more, 4,336 B (unchanged).
- test-target.sps judges a query's first byte (`/a?"b`, `/a?|b`, `/a?%zz`, `/?%`), and its "own bytes" row gains a target with no query, inside a delivery.

Watched to fail (m2-mutations.md): against the copying judge, the three allocation checks that name the target were red. The first-byte row and the "own bytes" row pass against the copying judge too, since any correct judge passes them; mutations AA and Z are the ones they exist for. Mutations Y to AE follow.

Found in review (a max-effort code review of this branch, 2026-09-25), and fixed here:
- the lane had no query workload, so a copy of the query alone went unseen (AD: 3,168 B at a 500-byte query, over the ratchet);
- no row judged a query's first byte (AA);
- 0002 still priced absolute-form against the removed copy, and its closing note claimed more than the gate measures.

The first draft's check on a percent-encoding cut short by the target's end is dropped. It passed against the copying judge, uriparse's own suite holds the same case (its decision 0034), and no request can reach it: a target ends at a space, or at the end of the core's join.

Found and recorded, for the owner: `CONNECT :443`, an authority-form target with an empty host, is accepted. It joins the M2.3 entry's empty-host rule: RFC 9110 §4.2.1 covers http and https URIs, and a CONNECT target names the tunnel's destination (RFC 9110 §9.3.6), which an empty host does not.

`make test` green: seventeen suites, 305 expected passes (target 36, connection-allocation 11), exit 0. The trace lane holds at 'full (9,394 runs). `make check-imports` is clean.

EMPTY HOSTS: the first of M2.3's two open RFC rules. MERGED as 01f7a5d (PR #20). Branch fix/empty-host-targets, cut from refactor/target-in-place, the third stacked PR; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`.

MEASURED first, on the branch:
- the judge accepted `http:///x`, `http://:80/x`, `https://?q`, `HTTP:///x`, `http:x`, `http:/x` and `CONNECT :443`;
- uriparse keeps a scheme's case, so `HTTP:///x` arrives as "HTTP";
- no llhttp or libhtp target has an empty host, so no corpus result changes (libhtp's `CONNECT [:80` is a malformed IP literal that uriparse already refuses);
- browsers send absolute-form and CONNECT only to proxies.

DECIDED on the owner's word (2026-09-25), asked with the facts above:
- **An http or https target with no host is refused with 400.** That covers an empty host (RFC 9110 §4.2.1 and §4.2.2: "A recipient that processes such a URI reference MUST reject it as invalid") and a missing authority, which lacks the "//" the http-URI grammar requires. The scheme matches in any case.
- **A CONNECT target with an empty host is refused with 400.** No RFC sentence requires it, but the target is the tunnel's destination (RFC 9112 §3.2.3), and `:443` names none.
- **It goes up now**, as a third stacked PR on #19.

The alternatives weighed:
- the empty host only, the literal §4.2.1 sentence, which leaves `http:x` accepted;
- leaving absolute-form as it was;
- leaving CONNECT to the hand-off (M2.5);
- landing after #18 and #19 merge.

What changed:
- `(http-server target)` gains a fourth verdict, `'no-host`:
  - `absolute-form-fault` gives it for an http or https target with no authority or an empty host, after the fragment and userinfo rules;
  - `authority-form-fault` gives it for a CONNECT target whose host is empty.

  The host is `(uri host)`'s `authority-host-span`, the validator's own split. Both checks run only on the absolute-form and CONNECT paths, after uriparse's parse, and allocate nothing. The core refuses the verdict as `'invalid-target`, 400, like every form rule.
- Other schemes keep uriparse's verdict: the rule is RFC 9110's, for http and https. Whether to serve `ftp:///x` is M4's routing question.
- test-target.sps (39) tables:
  - the six no-host targets;
  - CONNECT `:443`;
  - the boundary: `ftp:///x` and `httpx:///x` are accepted.
- The head suite (32) refuses an http target with no host and a CONNECT with an empty host, each with 400 at every delivery size.
- docs/request-targets.org lists the rule.

Watched to fail: the four refusal rows were red before the rule. The boundary row held from the start, as it should; mutations AG and AH are the ones it exists for. Mutations AF to AK follow (m2-mutations.md).

Still open, for the owner: RFC 9112 §3.2's Host header rules, the other half of the M2.3 entry.

`make test` green: seventeen suites, 310 expected passes (target 39, connection-head 32), exit 0. The trace lane holds at 'full (9,394 runs). `make check-imports` is clean.

MERGED to main on 2026-09-25, as three stacked PRs landed bottom up on the owner's "do closing ritual":
- #18 merged without deleting its branch, since #19 was based on it, and #19 likewise for #20. Each PR above was retargeted to main (`gh pr edit --base main`), rebased onto the squash below it (`git rebase --onto`) and force-pushed with a lease read from the remote. Each rebased tree was identical to the one tested: 4ec070f to 61f1f86, 03a6378 to bfcd38e. Each squash tree was identical to its tip's, and main's final tree (e1ba621) is the tested top of the stack.
- Every `linux` check executed zero steps, stopped at the billing check: the three PR runs (36123052425, 36123074402, 36123957913) and the two runs on rebased tips (36125173566, 36125232784).
- #20 merged with `--delete-branch`, which deleted its remote branch but left this checkout on it. So main was fast-forwarded to 01f7a5d by hand, the three branches were deleted local and remote, and refs pruned; no PR is open. `make test` green on main: seventeen suites, 310 expected passes, exit 0.

UPSTREAM LANDED (2026-09-25): uriparse v0.6.0 is tagged (40d645f, 10:54 -0400; annotated tag cf7492c). #24, filed that morning when the owner decided RFC 9112 §3.2's Host rules, closed via PR #25 (7d19f9b); the release is PR #26. `validate-authority` and `authority-host-span` on `(uri host)` now take an optional start and end:
- `validate-authority : Bytevector [Nat [Nat]] -> (values (Option Symbol) (Option Nat))` and `authority-host-span : Bytevector [Nat [Nat]] -> (values Nat Nat)`;
- the verdict on `bv[start, end)` is the verdict on those bytes alone: an `@`, `]` or `:` past `end` splits, closes or delimits nothing;
- every number returned is relative to `start`, the fault index and both host bounds, as with `validate-component`;
- the one-argument calls are unchanged. Refusing a userinfo, which RFC 9110's Host forbids and an RFC 3986 authority allows, is the server's rule: the host starts after 0 exactly when the value holds an `@`.

The release states no new conformance claim (its decision 0037): upstream 77/77, on macOS arm64 only. Between the tags `src/uri/host.sls` gained the ranged forms, `src/uri/range.sls` is new (the one range check every ranged judge shares) and `src/uri/charset.sls` now uses it. The byte-machine gitlink is still 0245db3. The local checkout's `main` is at 90368a7, with `src/` identical to the tag.

The pin moves from v0.5.0 to the v0.6.0 tag, on a commit of its own: `vendor/uriparse` is at 40d645f, which `git describe --exact-match` names v0.6.0. Watched to fail: with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). Its nested check held: uriparse v0.6.0 was released with the byte-machine on the library path.

Smoke evidence (`.plans/research/spike/smoke-uriparse-v060.sps`, Darwin arm64, Chez 10.4.1, `chez --libdirs vendor/uriparse/src:vendor/chez-httparse/vendor/byte-machine/src --program`, exit 0 on both runs, `out/smoke-uriparse-v060.run{1,2}.txt`; run 1 in full, and run 2's byte counts are identical):

    --- #24: ranged == on a copy, verdict and host bounds (expect agree in every row)
    "x" verdict (#f #f) (#f #f) host-span (0 1) (0 1) agree
    "example.com" verdict (#f #f) (#f #f) host-span (0 11) (0 11) agree
    "example.com:8080" verdict (#f #f) (#f #f) host-span (0 11) (0 11) agree
    "[::1]:8080" verdict (#f #f) (#f #f) host-span (0 5) (0 5) agree
    "" verdict (#f #f) (#f #f) host-span (0 0) (0 0) agree
    "a b" verdict (invalid-reg-name 1) (invalid-reg-name 1) host-span (0 3) (0 3) agree
    "h:x" verdict (invalid-port 2) (invalid-port 2) host-span (0 1) (0 1) agree
    "[::1" verdict (invalid-ip-literal 0) (invalid-ip-literal 0) host-span (0 4) (0 4) agree
    "u@h" verdict (#f #f) (#f #f) host-span (2 3) (2 3) agree
    "h%zz" verdict (invalid-pct-encoded 1) (invalid-pct-encoded 1) host-span (0 4) (0 4) agree
    "h%4" verdict (invalid-pct-encoded 1) (invalid-pct-encoded 1) host-span (0 3) (0 3) agree
    --- an "@" past the value's end splits nothing: the value "h" of "h@x"
    whole h@x: (2 3) range [0,1) h: (0 1)
    --- validate-component after its range check moved to (uri range)
    path [4,8) /a%4: (invalid-pct-encoded 2) query [9,10) q: (#f #f)
    --- 200000 Host values judged per pass, validity and host bounds: in place vs on a copy
    in-place: 1 bytes-per-value 0 ns 30
    on-copy:  1 bytes-per-value 16 ns 30
    in-place: 16 bytes-per-value 0 ns 170
    on-copy:  16 bytes-per-value 32 ns 170
    in-place: 41 bytes-per-value 0 ns 480
    on-copy:  41 bytes-per-value 64 ns 485
    in-place: 1 bytes-per-value 0 ns 25
    on-copy:  1 bytes-per-value 16 ns 35
    in-place: 16 bytes-per-value 0 ns 165
    on-copy:  16 bytes-per-value 32 ns 170
    in-place: 41 bytes-per-value 0 ns 480
    on-copy:  41 bytes-per-value 64 ns 485
    done

Reading:
1. The server can judge a Host value in place, inside the delivery the parser handed it, and get a copy's verdict and host bounds. All eleven values agree, though the bytes after each hold `@`, `[`, `:` and `]`.
2. A userinfo shows as a host start after 0 (`u@h`: 2), and an `@` past a value's end is none.
3. The ranged calls allocate nothing, where judging a copy costs 16, 32 and 64 B for 1-, 16- and 41-byte values.
4. `validate-component` judges as v0.5.0 did after its range check moved.
5. Nothing filed is open upstream: all sixteen asks are closed and released.

`make test` at the moved pin: seventeen suites, 310 expected passes, exit 0; the trace lane holds at 'full (9,394 runs). Updated: the Makefile (the pin), global-constraints (the pin), decision 0008 (a row for #24 and a dated note), the research README, and `tests/test-integration.sps` (its version comments). The pin MERGED as f23e927 (PR #21).

HOST HEADER RULES: the second of M2.3's two open RFC rules (RFC 9112 §3.2). MERGED as a9b9590 (PR #22). Branch feat/host-header-rules, cut from chore/uriparse-v0.6.0, the second of two stacked PRs; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`.

MEASURED first, on main after the uriparse v0.5.0 stack merged:
- the server read no Host at all;
- of the 135 strict fixtures, 95 messages reach on-headers-complete: 84 are HTTP/1.1, 10 HTTP/1.0 and 1 another version, and 23 carry a Host;
- 65 HTTP/1.1 messages in 61 fixtures carry none (pausing.md 13, transfer-encoding.md 16, sample.md 9, uri.md 8, connection.md 8, content-length.md 5, pipelining.md 1, method.md 1), and none has two Host lines, an empty Host or an invalid one;
- 33 of the head suite's requests are HTTP/1.1 with no Host;
- judging a Host value through a copy costs 16, 32 and 64 B per request for 1-, 16- and 41-byte values, where uriparse's `validate-authority` allocates nothing on a bytevector in hand;
- other servers: nginx answers 400 for all three rules; Go for a missing Host on HTTP/1.1 (CONNECT exempt) and a malformed one; Node for a missing Host on HTTP/1.1, behind its `requireHostHeader` option, default on.

DECIDED on the owner's word (2026-09-25), asked with the facts above:
- **Two Host lines are refused with 400.**
- **An HTTP/1.1 request with no Host is refused with 400**, CONNECT included, behind a switch: `CHEZ_HTTP_REQUIRE_HOST`, default on (decision 0005's amendment of 2026-09-25). The corpus lane runs with it off, so its 61 fixtures keep full coverage; the head suite tests it on.
- **An invalid Host value waits for uriparse #24**, a ranged `validate-authority`, filed on the owner's word that day, and is then judged in place. uriparse released it as v0.6.0 the same day (above).
- **It lands on a fresh branch after the uriparse v0.5.0 stack merges.**

The alternatives weighed:
- for two Host lines, leaving them to M4;
- for a missing Host, refusing it always and listing the 61 fixtures, or leaving it for now;
- for an invalid value, copying it now and asking uriparse (carried, like #21), or leaving it to M4;
- landing as a fourth stacked PR.

Left to M4: an empty Host on origin-form (RFC 9112 §3.3: the server "can reject the request or determine whether a configured default applies"), and absolute-form's host taking precedence over Host.

What changed:
- `(http-server host)`, new and pure, exports `host-fault : (Listof (Pair Span Span)) Nat Nat Boolean -> (U #f Symbol)` over the head's kept fields. It walks them once and gives:
  - `'duplicate-host` at a second Host line, in any version;
  - `'missing-host` when there is none, on HTTP/1.1, and only with the switch on;
  - for one Host, uriparse's error code when the value is not an authority, judged in place by the ranged `validate-authority`, or `'host-userinfo` when its host starts after 0 by the ranged `authority-host-span`.

  An empty value passes.
- The core judges the Host first in `conn-headers-complete-step`, before the target, and refuses a fault as `'invalid-host`, which `reason-status` answers 400. The 400 is RFC 9112 §3.2's MUST, so a target decision 0009 would redirect still gets 400 when its Host is wrong.
- `(http-server limits)` gains a twelfth field, `limits-require-host?`, from `CHEZ_HTTP_REQUIRE_HOST`: "true" or "false", nothing else.
- The trace lane runs the core under `corpus-limits`, the defaults with the switch off.
- The head suite's rows about other rules run under `minimal`, the defaults with the switch off. Their minimal requests carry no Host, and giving them one would change the header-limit rows' arithmetic. The table's H4 head reads a Host line in, as every HTTP/1.1 head must.
- docs: `docs/host-header.org`, new, linked from the README and configuration.org; configuration.org lists the switch.

Tests:
- test-host.sps (11): one valid Host, an empty one, the name in any case, a field named like Host, no Host on HTTP/1.1 with the switch on and off, HTTP/1.0 and 0.9 with none, two Host lines in any version, four invalid values with uriparse's codes, userinfo, and a value judged in place;
- the head suite (40): eight Host rows at every delivery size, among them a redirectable target refused with 400;
- the limits suite (26): the default, "true" and "false", and three other values refused;
- the allocation lane (12): a 500-byte Host costs what a short one does, 2,624 B;
- the decisions suite: `invalid-host` is 400.

Watched to fail (m2-mutations.md): test-limits and test-host exited 255 before the code, on an unbound accessor and a missing library. The head suite's five refusal rows and the decisions suite's reasons row were red before the wiring, while the served rows held. The table's H4 and the trace lane went red at the wiring: with the switch still on, 54 fixtures' traces changed and 7 listed fixtures were refused for their Host instead, 61 in all, the count measured first. Mutations AL to AU follow.

`make test` green: eighteen suites, 333 expected passes (host 11, connection-head 40, limits 26, connection-allocation 12), exit 0. The trace lane holds at 'full (9,394 runs). `make check-imports` is clean.

MERGED to main on 2026-09-25, as two stacked PRs landed bottom up on the owner's "do closing ritual":
- #21 merged without deleting its branch, since #22 was based on it. #22 was retargeted to main, rebased onto the squash below it and force-pushed with a lease read from the remote. Its rebased tree (380fb1a) was identical to the one tested (3966dea). Each squash tree was identical to its tip's, proved against the merge commit gh reports, and main's final tree (d202d4e) is the tested top of the stack.
- Every `linux` check executed zero steps, stopped at the billing check: the two PR runs (36158713608, 36158743565) and the run on the rebased tip (36159292446).
- #22 merged with `--delete-branch`, which again left this checkout on its branch. So main was fast-forwarded to a9b9590 by hand, both branches were deleted local and remote, and refs pruned; no PR is open. `make test` green on main: eighteen suites, 333 expected passes, exit 0.

Both of M2.3's open RFC rules are now in: the empty host (#20) and the Host header (#22). Nothing filed is open upstream.

---

M2.4 — THE MESSAGE LOOP: pause, read-stop and pending input (plan §6). Cut from main at 18e6a46; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. At 571 inserted lines of code and tests before the lane, over plan §1 rule 1's ~400, the slice goes up as three stacked PRs, one per step below, each green on its own: feat/m2.4-pending-input, then feat/m2.4-message-loop and feat/m2.4-outcome-lane, each cut from the one before.

MEASURED first, on main at 18e6a46:
- `research/spike/pipeline-pause.sps` at the pins: on its three messages, 117 bytes, the parser stops at 51 and then at 98, and fed on past the close-marked second message it answers `closed-connection` at 99. These are the 2026-09-19 figures (`out/pipeline-pause.2026-09-25.run{1,2}.txt`, identical).
- `research/spike/pause-then-upgrade.sps`, new: with every message's end paused, a CONNECT tunnel and a `Connection: upgrade` request first return `paused` with no reason, the pause at on-message-complete. The hand-off comes only when the parse resumes and is fed from `next`: `paused-upgrade`, 0 bytes consumed. The h2c preface still errors at once, `paused-h2-upgrade` (`out/pause-then-upgrade.run{1,2}.txt`, identical).
- A scratch prototype of the loop over the 135 strict fixtures: 131 have one outcome at every chunk size, at 'extremes and at 'full; the other 4 are upgrades.

M2.4 FIRST STEP: the pending input (feat/m2.4-pending-input).
- `(http-server connection)` remembers the last delivery it fed the parser, sharing the event's `(bv start end)`. A `parser-result` that pauses with no reason in `handling` keeps the rest of that delivery, from `parser-result-next`, as the pending input, which H9's resume feeds.
- Three table rows for decision 0004's pause protocol, counted apart from design §4.4's 10 + 9:
  - P1 keeps the rest, and nothing when the parser stopped at the delivery's end;
  - P2: an error after a close-marked message is not answered;
  - P3: bytes after a close-marked message are not fed, in handling, responding or closing.
- `(http-server private adapter)`: `make-conn-context` takes the shell's `queue!`, which receives each callback's actions after its reply; `conn-context-take-actions!` is gone. The head suite, the trace lane and the allocation lane pass queues of their own. The CPS workload now costs 2,512 B per request (it was 2,624 B): the 112 B copy M2.2's fourth step found is gone. An absolute-form request costs 4,224 B.
- Decisions 0004 and 0002 gain dated amendments: the remainder is kept one step after the pause, and item 4's error cannot fire; the shell owns item 3's queue.

Watched to fail (m2-mutations.md): P1 was red before the core kept the rest; P2 and P3 held from the start, as they must. Mutations A, D, E, F and I follow. `make test` green: eighteen suites, 340 expected passes (connection-table 69), exit 0.

Settled in the first step, open to the owner's review:
1. **The remainder is kept one step after the pause.** Decision 0004 item 1 and design §4.4's H6 keep it at on-message-complete, but the parser says where it stopped only when the feed returns. The `parser-result` that follows the pause arrives before any queued action runs, so the core is still in `handling`. P1 is the row; 0004's amendment records it.
2. **The rest is always the end of the last delivery.** Reading stops at the pause and the rest is fed before reading starts again, so no other delivery comes between. The core remembers only that delivery, not each feed: re-recording the resume's feed, or forgetting the delivery at each result, changed nothing any test could see.
3. **The shell owns the action queue.** Design §4.5 has one queue, drained after the outermost dispatch, and the adapter's own list made two, with a copy between them. 0002's amendment records it.

M2.4 SECOND STEP: the message loop (feat/m2.4-message-loop).
- `tests/fake-shell.sls` runs actions after the outermost dispatch, from one queue; a dispatch made while the queue drains, or while the parser feeds, only queues. One depth counter counts the drain and the feed inside it. An action run anywhere but depth 1, the outermost drain, is a violation the shell records: design §6.4's check.
- `make-fake-connection`: the core through the adapter, one real parser, and a handler that answers at once. It performs:
  - feed-parser, then the result as `parser-result`;
  - resume-parser;
  - call-handler, answering a raise with `handler-failed`;
  - write, completing on a later turn;
  - read-stop and read-start: input arrives only while the connection reads;
  - close, with `closed` on a later turn.
  It records the rest. A dispatch cap turns a runaway into a harness error.
- `tests/test-message-loop.sps` (12):
  - one keep-alive request runs design §4.4's rows in order;
  - the pipelining boundary: the handler runs with [51, 117) kept, then [98, 117), and the resume feeds exactly the rest;
  - a close-marked message ends the reading: the third message is never fed, the parser reports no error, and a byte at a time only 98 of the 117 bytes arrive;
  - three pipelined GETs are served one at a time;
  - a raising handler gets 500, then close;
  - every action runs from the outermost drain, at every delivery size.
- test-fake-shell.sps (15): a dispatch made while draining queues its actions behind the rest.
- The head suite runs in the fake shell, so its own loop is gone. A refused message's response is now written and the connection closed, so those rows end in `closed`.
- `docs/connections.org`, new, linked from the README.

Watched to fail: test-fake-shell.sps and test-message-loop.sps exited 255 before the loop existed. The first loop left G alive, since nothing checked that input stops when reading does; the 98-byte row was added for it. Mutations B, C, G, H, J, K and L follow, and A, D and I reach the loop. `make test` green: nineteen suites, 355 expected passes, exit 0.

Settled in the second step, open to the owner's review:
1. **One depth counter, every action at depth 1.** Design §4.5 counts the feed and the drain in one counter, and plan §6 says no action but `reply-parser` runs at non-zero depth. The drain itself is depth 1, so the check is "depth 1 exactly". A nested drain (C) is silent but for the check: every outcome held.
2. **The fake shell leaves a hand-off unperformed.** In M2.4 the core never hands off inside the loop (below, for M2.5), so the case was removed rather than left untested.

M2.4 THIRD STEP: the outcome lane (feat/m2.4-outcome-lane).
- `tests/outcome-lane.sls`, new: design §8.1's property 2. Each strict fixture goes through one fake connection at every scheduled chunk size. Its outcome is:
  - the handlers called, with their requests;
  - the responses, by status;
  - the close and its reason;
  - the final phase and close-after;
  - the actions run outside the outermost drain.

  At every size it must equal the whole input's, and a raise is a mismatch. It runs under the trace lane's `corpus-limits`.
- `tests/test-outcome-lane.sps` (6): the instrument is calibrated on the spike's three messages, whole and a byte at a time. Every fixture not listed has one outcome at every chunk size, and the four listed upgrades still depend on it (gated both ways). It runs 'extremes in `make test` (253 runs) and 'full under CORPUS=full (9,394).
- The ratchet's outcome lane has its comparator: 131 entries promoted to passing, a reviewed diff; 4 not-yet, 32 deferred.

Watched to fail by mutation only, since the lane was written after the code it measures: M and N. On this tree the earlier mutants reach the lane:
- A turns 44 fixtures red in the lane and in the ratchet;
- B and C turn all 131 red;
- J turns 4 red;
- L fails only the calibration.

`make test` green: twenty suites, 362 expected passes, exit 0. The lane at 'full: 131 of 135.

Settled in the third step, open to the owner's review:
1. **The trace lane keeps its own driver.** M2.2 recorded its core driver as the head suite's small message loop. It is not the same loop: property 1 is parser truth, so the trace lane feeds every byte the recorder saw, past a close-marked message too, and the message loop stops there. The outcome lane is where the loop meets the corpus.
2. **What the outcome is.** Design §8.1 names the call-handler sequence, the keep-alive decision and the close reason. The keep-alive decision shows as whether a close follows a response. Feeds, reads and deadlines follow the deliveries and are left out; I, a rest fed after a close, survives the lane and dies in the loop suite.

Found and recorded:
- **(M2.5) An upgrade now reaches the handler, and at small deliveries stalls the parser.** With the pause at every message's end, an upgrade's hand-off (`paused-upgrade`) comes only on the resumed feed, after the handler has answered and the core is back in idle. The core does not answer it there. The next delivery feeds a paused parser, which byte-machine refuses (`&byte-machine-contract`). Delivered whole, there is no next delivery. So the four `Connection: upgrade` fixtures are listed, not-yet: connection.md#14, #19, #20 and #21. Six more hand-off fixtures pass the lane with outcomes M2.5 will change:
  - the four HTTP/1.0 CONNECTs (method.md#2–#4, uri.md#9) are served as plain requests and closed;
  - connection.md#18, an upgrade with nothing after it, is served and left idle;
  - the h2c preface, method.md#15, is answered 400.

  M2.1's finding said the hand-off arrives in `handling`. It arrives one step later still, and M2.5 decides where the door is.
- **(owner, settled in the fourth step below) Decision 0004 item 2 has no slice.** Item 2 keeps the `inflight`/`ready`/`head` ordering machinery in the core, "so raising the cap is a setting and a test". No slice of the milestone plan builds it. Its consequence says no response-ordering queue is exercised in v1. `pipeline-cap` is read by nothing: the core serves one request at a time whatever its value, while docs/configuration.org says the variable bounds in-flight pipelined requests.
- **(M2 exit)** Three things remain: libhtp's pipelining and multi-packet files with our expectations, the outcome lane's four upgrades (M2.5), and the lane at 'full, which holds today.

PIPELINE CAP: decision 0004 item 2 settled. The fourth stacked PR, feat/m2.4-pipeline-cap, cut from feat/m2.4-outcome-lane; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`.

The owner asked what pipelining is, what serial costs against the alternatives, and what Node gains from parsing ahead, then decided. Measured and checked for it:
- `research/spike/pipeline-parse-ahead.sps`, new: on 16 pipelined GETs in one buffer, pausing at every message's end costs 47 to 69 ns (3–5%) and 384 B per request against never pausing, one feed more per message (`out/pipeline-parse-ahead.run{1,2}.txt`). Earlier scratch runs of the same program measured 60–94 ns: the time varies by run, the bytes do not.
- 2 of the 135 strict fixtures (connection.md#2, pipelining.md#1) and 1 libhtp stream (07-pipelined-connection.t) carry more than one request.
- Checked the same day:
  - libcurl disabled HTTP/1 pipelining in 7.62.0;
  - TechEmpower's plaintext test assumes pipelining support;
  - RFC 9112 §9.3.2 lets a server work on pipelined safe requests in parallel, but its responses must leave in order;
  - Node parses ahead with an `outgoing[]` queue (research/server-node-http.md §2–§3), and needed flood throttling after CVE-2013-4450.

DECIDED on the owner's word (2026-09-25), asked with the facts above:
- **Serial by design.** Decision 0004 item 2 is withdrawn: v1 answers one request at a time by construction, and the core has no ordering machinery. Parse-ahead would be a new decision with its own design, set against a throughput goal; M8's load test is the first place to set one. Reading during a handler only to notice a client leave stays open under item 3.
- **`CHEZ_HTTP_PIPELINE_CAP` accepts only 1**; any other value is refused at startup. The field stays.
- **A fourth stacked PR now**, so the pipelining work and the decision about its cap merge together.

The alternatives weighed:
- for item 2, planning the machinery for M7, or building it before M2.5;
- for the variable, removing the field, or leaving it with the docs saying only 1 takes effect;
- for when, folding it into M2.4's first step, or landing it after the stack merges.

What changed:
- `(http-server limits)`: `limits-from-environment` refuses a pipeline cap other than 1 and names the variable, as it does a malformed value.
- test-limits.sps (26): "pipeline cap overridden 8" is replaced by "a pipeline cap of 1 is accepted; 2 and 8 are refused".
- docs/configuration.org: the row says the cap must be 1, and a paragraph says why.
- Decision 0004 gains a second amendment of the day, "item 2: serial by design", with what was weighed; decision 0005 gains one, "the pipeline cap accepts only 1". Design §2 and brief item 3, whose "a setting and a test" sentences the amendment withdraws, carry dated notes.

Watched to fail: the new row was red before the check, since "2" and "8" were accepted. Mutations O and P follow. `make test` green: twenty suites, 362 expected passes, exit 0.

Found and recorded, for M4: `make-limits` checks no field, as before, so only the environment path refuses the cap. If M4's facade lets embedders build limits directly, it must refuse a cap other than 1 too.

MERGED to main on 2026-09-25, as four stacked PRs landed bottom up on the owner's "do closing ritual":
- #23 merged as 936937d, #24 as 99c0f21, #25 as 955c68e and #26 as 11abb8c.
- #23, #24 and #25 each merged without deleting its branch, since the PR above was based on it. Each PR above was then:
  - retargeted to main (`gh pr edit --base main`);
  - rebased onto the squash below it (`git rebase --onto`, from its original parent);
  - force-pushed with a lease read from the remote.
- Each rebased tree was identical to the one tested: a1eb7cc became 878ae92, ca7449a became 4fac637, and bfecc89 became f2135c3. Each squash tree was identical to its tip's, proved against the merge commit gh reports. main's final tree (3c9d865) is the tested top of the stack.
- Every `linux` check executed zero steps, stopped at the billing check: the four PR runs (36169038698, 36169059766, 36169085974, 36169113964) and the three runs on rebased tips (36169406391, 36169486477, 36169551938).
- #26 merged with `--delete-branch`. This time gh switched this checkout to main and fast-forwarded it to 11abb8c. The other three branches were deleted local and remote by hand, and refs pruned; no PR is open.

`make test` green on main: twenty suites, 362 expected passes, exit 0.

M2.4 is done, and decision 0004 item 2 is settled. The outcome lane holds 131 of the 135 strict fixtures; the four upgrades wait for M2.5's hand-off door.

---

M2.5 — THE HAND-OFF DOOR AND THE ERROR ROWS (plan §6). Cut from main at ee23fb7 as feat/m2.5-hand-off-door; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. One slice: 429 inserted lines of code and tests (ratchet.txt's 6 among them), just over plan §1 rule 1's ~400, so it goes up as its own PR, as M2.1 did at 596.

MEASURED first, on main at ee23fb7:
- `research/spike/upgrade-door.sps`, new, at the pins (`out/upgrade-door.run{1,2}.txt`, identical):
  - answered `continue` at on-message-complete, the parser runs on to its own hand-off, `paused-upgrade`, in the same feed, a byte at a time and whole, with `next` one past the message. That holds for `Connection: upgrade` with and without a body, CONNECT over 1.1 and 1.0, and `Upgrade: h2c`;
  - answered `pause`, as the core answers every message, the hand-off comes only after a resume and a feed, even of an empty range at `next`; a plain message answers need-input there;
  - llhttp's rule (CONNECT, or both upgrade flags) equals the parser's own `upgrade` field at on-headers-complete, and an `Upgrade` or a `Connection: upgrade` alone is no upgrade;
  - the HTTP/2 preface errors, `paused-h2-upgrade`, before any on-headers-complete.
- Over the 135 strict fixtures, the rule agrees with the parser's field at every on-headers-complete, and marks exactly the nine whose llhttp logs pause for an upgrade: connection.md#14, #18–#21, method.md#2–#4 and uri.md#9.
- Three scratch prototypes of the core, each run over the 135 strict fixtures:
  - A, hand it off at the message's end: 9 outcomes changed, 26 core lines;
  - B, serve it, then close: 5 outcomes changed, 17 core lines;
  - C, serve it and keep the connection: 4 outcomes changed, 21 core lines.

  Each held all 135 at 'extremes and at 'full, at 2,512 B per request.
- Checked the same day:
  - RFC 9110 §7.8 lets a server ignore `Upgrade`, and says it "MUST ignore" one in an HTTP/1.0 request;
  - RFC 9110 §9.3.6: "most origin servers do not implement CONNECT";
  - RFC 9113 §3.1 deprecated the h2c upgrade;
  - curl's manual: `--http2` sends `Upgrade:` to an http:// URL.
  - The project's own reads of other servers (research/server-*.md): Go gives an upgrade no special handling; Node, with no listener, answers `Upgrade` as an ordinary request and closes a CONNECT with no response; h2o serves an upgrade it does not take, and that connection is not persistent.

DECIDED on the owner's word (2026-09-25), asked with the measurements above:
- **An upgrade request is served, then the connection closes** (B). The handler answers it like any other request, and the bytes after it are never read. The core never lets the parser run on to its hand-off in v1. M8 opens that door, at the message's end, for a handler that takes upgrades. This amends decision 0006 item 3.
- **`Upgrade: h2c` is an upgrade like any other.** Only the HTTP/2 preface is answered 505. This amends decision 0006 item 2.

The alternatives weighed:
- for the door, A, which is 0006 item 3 as written: the handler never sees the request, and with nothing to take it in v1 the connection closes with no response. It would also need a version check for RFC 9110's HTTP/1.0 rule;
- for the door, C: the bytes after the request would be read as HTTP requests, a request-smuggling path behind a proxy that forwards them unread;
- for `Upgrade: h2c`, keeping 0006's 505. It costs about 20 lines and a parser for the `Upgrade` token list, and it answers `curl --http2 http://…` with an error.

What changed:
- `(http-server decisions)`:
  - `result-hands-off-stream?`, the two-channel check chez-httparse's docs/api.org gives as embedder code, over the parts the parser-result event carries: a pause with `paused-upgrade`, or an error with `paused-h2-upgrade`. A code counts only on its own channel;
  - `request-upgrades?`, llhttp's `before_headers_complete` for a request. chez-httparse exports the flag bits and not the rule, so it is transcribed here and held to llhttp's recorded logs;
  - `parser-error-status` refuses `paused-h2-upgrade`, a hand-off, as it already refused `paused-upgrade`;
  - `reason-status` answers the core's new reason `http2-preface` 505, and refuses `parser-error`, whose status is the error's.
- `(http-server connection)`:
  - on-headers-complete marks an upgrade to close after its response, with the reason `upgrade`, unless the message closes anyway: `not-keep-alive` keeps precedence;
  - in head or body, a parser result that hands off, on either channel, is the door. The HTTP/2 preface is answered 505, then close. A pause-channel hand-off is design §4.4's T7 row, which the core's own flow no longer reaches. Any other error takes the refusal's status, or the one `parser-error-status` gives its code and node: 400, or 501 at `e-request-invalid-te`;
  - a parser-result event's `error` is now `(code . node)`, and tests/fake-shell.sls passes the node.
- Tests:
  - decisions 21: the four smoke-v040 rows at the pin, one test each; the channels kept apart; the rule's rows; and the rule against llhttp's logs over the 135;
  - connection-table 77: T3's 501 and 400 split, and the upgrade-door rows U1 (four instances) and U2, counted apart;
  - message-loop 18: a WebSocket handshake, a CONNECT and `Upgrade: h2c` each served and then closed, at every delivery size, with the frame after the handshake never delivered; the preface answered 505;
  - connection-head 42: `Transfer-Encoding: pigeons` answered 501, `chunked, deflate` 400;
  - outcome-lane 4: every fixture has one outcome at every chunk size, the listed-fixture gates gone;
  - ratchet: the four upgrades promoted, 135 passing, a reviewed diff.
- docs/connections.org: two paragraphs on upgrades and the preface; README's Connections line.
- Decision 0006 gains a dated amendment, with what was weighed. Dated notes where the decision is restated: design §2, §4.3, §4.4 and §6.5; the brief's item 5 and its M8; the plan's M2.5 and M8.

Seven fixtures' whole-input outcomes differ from main's:
- the five upgrades (connection.md#14 and #18–#21) are served, then closed with the reason `upgrade`, where four varied by chunk size and #18 was left idle;
- method.md#15, the HTTP/2 preface, is answered 505 (`http2-preface`) where it got 400;
- transfer-encoding.md#13, a `Transfer-Encoding` whose last coding is not chunked, is answered 501 where it got 400.

Watched to fail (m2-mutations.md): the new rows were red before the code, and mutations M2.5-A to J follow, the plan's first. The plan's mutation turns exactly the preface's row red among the four; the preface then reaches the error map, which refuses it, and the lane shows the raise. The first run of the ten came back all-green: the runner built each mutant's root from a relative path, which the suites never found. Every mutant was rerun with the root made absolute.

`make test` green: twenty suites, 385 expected passes (362 on main), exit 0. The lane at 'full: 135 of 135 in 9,394 runs. The CPS workload costs 2,512 B per request, unchanged, and an absolute-form request 4,224 B.

Settled in M2.5, open to the owner's review:
1. **The event carries the error's node.** One code's status splits by the node the parser refused at, so a parser-result's `error` is `(code . node)` rather than the code alone. The ParserError record would need byte-machine's accessors in the core, and the table's rows would stop being data.
2. **The HTTP/2 preface's 505 is the core's own reason, not the error map's.** M2.2's map answered `paused-h2-upgrade` 505. With the door checking both channels first, the map refuses it, so a check of one channel only, the plan's mutation, is loud instead of quiet.
3. **`not-keep-alive` keeps precedence over `upgrade`.** A message that closes anyway keeps its own reason. So an HTTP/1.0 request with `Upgrade`, which RFC 9110 §7.8 says must be ignored, closes as HTTP/1.0 does.
4. **The upgrade rule is transcribed, not read.** The parser's `upgrade` field decides the hand-off but is not in chez-httparse's documented `parser-field-ref` list. The rule uses documented inputs, two flags and a method, and llhttp's logs hold it.

Found and recorded:
- **(owner, upstream) chez-httparse exports the flag bits, not the upgrade rule.** (httparse decisions) mirrors llhttp's after-a-message decisions. `before_headers_complete`'s `upgrade` is the same kind of decision, and the server transcribes it. An ask to export it, or to document `upgrade` as a readable field, would retire the transcription. Not filed: that is the owner's to decide (decision 0008). (Later on 2026-09-25: filed as chez-httparse #47 on the owner's word, and landed in v0.4.1; see UPSTREAM ASK FILED AND LANDED below.)
- **(M3) A 2xx to CONNECT carries neither `Content-Length` nor `Transfer-Encoding`.** RFC 9110 §9.3.6: "A server MUST NOT send any Transfer-Encoding or Content-Length header fields in a 2xx (Successful) response to CONNECT." A v1 handler may answer a CONNECT 200, so M3's framing must drop both there.
- **(M8) The hook has no v1 user.** The core answers the HTTP/2 preface itself. M8 decides how a handler takes an upgrade, at the message's end, and writes the hook's contract test for that door.
- **(M2 exit)** One item remains: libhtp's pipelining and multi-packet files, with our expectations, promoted in the ratchet by name. The outcome lane holds 135 at 'extremes and at 'full, allocation is 2,512 B against the 3 KiB ratchet, and `make check-imports` is clean.

MERGED to main on 2026-09-25 as f5c13ca (PR #27), on the owner's "do closing ritual":
- The squash tree (0ed38c3) is identical to the tested tip's, 6e73ace, proved against the merge commit gh reports.
- The `linux` check (run 36183200210) executed zero steps, stopped at the billing check.
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to f5c13ca, as it did for #26. The branch was deleted local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty suites, 385 expected passes, exit 0.

Every slice of M2 is merged, ① to ⑤. Of M2's exit, one item remains: our expectations for libhtp's pipelining and multi-packet files.

NEXT: the M2 exit (plan §6): our expectations for libhtp's pipelining and multi-packet files, promoted in the ratchet by name, then M2's close-out, on a fresh branch cut from main after f5c13ca, when the owner asks.

UPSTREAM ASK FILED AND LANDED (2026-09-25, after M2.5 merged): chez-httparse #47, on the owner's word.

M2.5 transcribed llhttp's upgrade rule as `request-upgrades?` (settled item 4 above), and offered the ask in one line of its report, not in a form. Asked what it was, the ask shrank. The parser already stores llhttp's answer in its `upgrade` field, and `parser-field-ref` reads it. What was missing was the documentation, and llhttp documents the same answer as `llhttp_get_upgrade` (src/native/api.h:104). So #47 asks for documentation only, "Document the `upgrade` field so embedders need not copy llhttp's upgrade rule", with no new procedure. It was filed on the owner's word: "yes drop it and file the issue".

chez-httparse tagged v0.4.1 the same day: annotated tag 89d716f pointing at 9bc669c; #47 via PR #48 (fa6d7ae); release PR #49; #47 closed at 20:40 UTC. `docs/api.org`'s `parser-field-ref` table gains `upgrade`: 1 when the message upgrades, written just before on-headers-complete, and held through the body, on-message-complete and the hand-off result. It is not cleared between messages, and `parser-reset!` zeroes it. Its CHANGELOG adds the `unit.upgrade-field` lane: 160 on-headers-complete reads over 212 fixtures, held to llhttp's rule. That lane is also the first check that sees the grammar's 101 test, which had survived every lane when moved to 100.

The pin moves from v0.4.0 to the v0.4.1 tag, on a commit of its own (branch chore/pin-httparse-v0.4.1): `vendor/chez-httparse` is at 9bc669c, and its nested byte-machine is still 0245db3. Watched to fail: with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). A trap: `make test` runs `git submodule update`, which checks out the gitlink the index records. The first run put the checkout back at 1cddba8, and then failed `check-pins`. Stage the gitlink before `make test`.

Byte identity: between the tags, the only change on our library path is 14 comment lines in `src/httparse/grammar.sls` (`git diff v0.4.0 v0.4.1`). Byte-identical:
- `src/generated/`: httparse-message.sls and httparse-url.sls;
- `test/support/harness`;
- the nested `vendor/`;
- the corpus under `test/vendor/`. So test-corpus-inventory's counts hold as they are.

Smoke evidence (`.plans/research/spike/smoke-httparse-v041.sps`, Darwin arm64, Chez 10.4.1, on the Makefile's LIBDIRS; exit 0 on both runs, `out/smoke-httparse-v041.run{1,2}.txt`, identical):

    (strict-fixtures 135)
    (logged-upgrades 9 ("request/connection.md#14" "request/connection.md#18" "request/connection.md#19" "request/connection.md#20" "request/connection.md#21" "request/method.md#2" "request/method.md#3" "request/method.md#4" "request/uri.md#9"))
    (size whole on-headers-complete-reads 94 field-vs-rule-disagreements 0 field-is-1-in 9 same-as-logged #t)
    (size 1 on-headers-complete-reads 94 field-vs-rule-disagreements 0 field-is-1-in 9 same-as-logged #t)

Reading: the documented field gives the answer the server transcribed. Over the 135 strict fixtures, whole and a byte at a time, it equals llhttp's rule at all 94 on-headers-complete reads. It is 1 in exactly the nine fixtures whose logs pause for an upgrade. The spike keeps its own copy of the rule as its oracle, so it still runs once the server stops carrying one.

`make test` at the moved pin: twenty suites, 385 expected passes (as on main), exit 0. The CPS workload costs 2,512 B per request, unchanged. Updated:
- the Makefile (the pin);
- global-constraints (the pin);
- decision 0008 (a row for #47 and a dated note);
- the research README;
- the version comments in `tests/test-integration.sps` and `tests/test-corpus-inventory.sps`.

NEXT: the server reads the field, on a branch stacked on this one. The adapter passes `upgrade` into conn-headers-complete-step, the core closes after an upgrade on it, and `request-upgrades?` retires. Then the M2 exit.

THE CORE READS THE PARSER'S UPGRADE FIELD (2026-09-25). Branch refactor/upgrade-field, stacked on chore/pin-httparse-v0.4.1; Darwin arm64, Chez 10.4.1 `tarm64osx`.

The adapter reads a sixth field at on-headers-complete, `upgrade`, and passes it to conn-headers-complete-step. The core marks an upgrade to close after its response when the field is 1, where M2.5 asked `request-upgrades?`. `not-keep-alive` keeps precedence. The field is read there because it becomes this message's answer at on-headers-complete: the parser's reset does not clear it, so before that it holds the previous message's answer (chez-httparse's docs/api.org).

Retired: `request-upgrades?` and its import of the two flag bits, so (http-server decisions) now imports only (rnrs). Its rule rows leave test-decisions.sps. The corpus check moves to test-flag-pins.sps, the pin suite, and now reads the field: the strict fixtures whose llhttp logs pause for an upgrade are nine, and the field is 1 in exactly those.

Tests:
- entry: the payload has six fields, and the old five-field shape is refused. Its recorder reads `upgrade` too.
- table: U1 carries the field. Two new instances pin that the field decides: both upgrade flags with `upgrade` 0, and a CONNECT with `upgrade` 0, each with close-after #f.
- The loop's upgrade rows are unchanged. They catch the adapter's wiring (#47-A1, A2).

Mutations: seven, all killed (m2-mutations.md, "chez-httparse #47").

`make test` green: twenty suites, 386 expected passes (385 at the pin), exit 0. By suite: entry 30 (was 29), connection-table 78 (77), decisions 18 (21), flag-pins 10 (8). At 'full, the outcome lane holds 135 of 135 in 9,394 runs, and the trace lane and the ratchet hold. The CPS workload costs 2,512 B per request, unchanged: the seventh argument allocates nothing.

Updated:
- the adapter, (http-server connection) and (http-server decisions), with their comments;
- decision 0002 (item 4, and item 1 of its third amendment) and design §4.2, with dated notes: `upgrade` is read at on-headers-complete too;
- the mutation log.

NEXT: the two stacked PRs, on the owner's word. Then the M2 exit (plan §6): our expectations for libhtp's pipelining and multi-packet files, promoted in the ratchet by name, then M2's close-out.

MERGED to main on 2026-09-25, as two stacked PRs landed bottom up on the owner's "do closing ritual":
- #28, the pin, merged as b164248 without deleting its branch, since #29 was based on it. Its squash tree (5962a67) is identical to the tested tip's, a8582eb.
- #29 was retargeted to main, rebased onto b164248 and force-pushed with a lease read from the remote. The rebase took 848799d to 1106b6b with the tree unchanged (10b17d9). #29 merged as bb9aef6, whose tree is the tested one, proved against the merge commit gh reports.
- Every `linux` check executed zero steps, stopped at the billing check: runs 36190037834 (#28), 36190062358 (#29) and 36190360680 (#29's rebased tip).
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to bb9aef6. The pin branch was deleted by hand, local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty suites, 386 expected passes, exit 0.

The server now reads the parser's own `upgrade` answer, and nothing filed is open upstream: all seventeen asks are closed and released.

NEXT: the M2 exit (plan §6): our expectations for libhtp's pipelining and multi-packet files, promoted in the ratchet by name, then M2's close-out, on a fresh branch cut from main after bb9aef6, when the owner asks.

M2 EXIT: libhtp's pipelining and multi-packet streams, with our expectations. Branch feat/m2-exit-libhtp, cut from main at a801894; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`.

MEASURED first. A strict request parser fed each stream's client packets one by one:
- 27 of the 102 streams send the client side in two or more packets.
- 12 carry what the exit names:
  - two or more requests on one connection: 07, 08, 10, 20, 39, 61;
  - a request head split across packets: 09, 67;
  - a request body split across packets: 04, 27, 35, 66.
- The other 15 stop first: at a parse error (bare-LF line endings in 05, 25, 26, 97 and 99; bad chunks; a bad Transfer-Encoding), at a CONNECT (15), or at a request that never completes (63).
- A dry run of the twelve: each expected outcome was written from RFC 9112 and the decisions first, and all twelve matched.

DECIDED on the owner's word (2026-09-25), by form, both recommended:
- **Scope: the twelve**, chosen by what the streams carry rather than their names. Weighed: only the three named for it (07, 08, 09), which leaves nine that carry the same thing not-yet; and all 27 multi-packet streams, which adds fifteen whose outcomes test strictness rather than packets.
- **No Host required**, like the llhttp lanes. Weighed: the server's default, under which the six HTTP/1.1 streams without a Host (07, 08, 61, 04, 27, 66) are one 400 each and their pipelining never runs.

BUILT:
- `tests/libhtp-lane.sls`, `(libhtp-lane)`: the twelve expectations, each with its reason, and the run they are held to. Each client packet is one `bytes-arrived`; after the last, the client's `eof` arrives if the connection still reads. Every handler answers 200, under `corpus-limits`. The outcome is the outcome lane's record, plus the body delivered, joined.
- `tests/test-libhtp-lane.sps`: the scope, which a strict parser's count over all 102 streams must equal, and each expectation.
- The ratchet's libhtp comparator: a stream passes when it has an expectation and meets it. The twelve are promoted by name: libhtp 12 passing, 90 not-yet.
- `(outcome-lane)` exports `render-request`, so the two lanes render a request alike.

Red before green, then eight mutations (m2-mutations.md, "M2 exit"). Seven were killed, each by the streams it should kill. L7, the lane joining a stream's packets into one delivery, survived by design: the outcome does not depend on the split, which is the outcome lane's property.

Found and recorded:
- **RFC 9112 §3.2.2 has one guard.** L4 refuses an absolute-form request that carries a Host, and only 20-ambiguous-host.t caught it, besides the allocation suite's workload. No table or head row pins the rule that an origin server "MUST ignore the received Host header field" for absolute-form.
- **(M6) 63-post-chunked-invalid-1.t declares a 2 GiB chunk** (`80000000`), so the rest of the stream is its body and the request never completes. As designed: decision 0005's `max-body-bytes` is `#f`, since bodies stream to the handler, and only M6's buffering helper takes a limit (1 MiB, 413).

THE M2 EXIT, measured on the tree:
- the outcome lane holds 135 of 135 at 'extremes and at 'full (9,394 runs);
- the outcome is chunk-size invariant: the call-handler sequence, the keep-alive decision and the close reason (the outcome lane);
- libhtp's pipelining and multi-packet streams pass with our expectations, the twelve promoted by name;
- allocation: 2,512 B per request against the 3 KiB gate;
- `m2-mutations.md` covers M2.1 to M2.5, chez-httparse #47 and this exit; `make check-imports` is clean.

`make test` green: twenty-one suites, 401 expected passes, exit 0. By suite: libhtp-lane 14 (new), ratchet 9 (was 8).

NEXT: commit and PR on the owner's word. At the merge, M2 is complete. Then M3, the response path (plan §7).

MERGED to main on 2026-09-25 as ae1ef45 (PR #30), on the owner's "do closing ritual":
- The squash tree (e689ccd) is identical to the tested tip's, 373b5f8, proved against the merge commit gh reports.
- The `linux` check (run 36192541757) executed zero steps, stopped at the billing check.
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to ae1ef45. The branch was deleted local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-one suites, 401 expected passes, exit 0.

M2 COMPLETE and merged (ae1ef45, PR #30): the pure connection core, request path. It took 24 PRs, #7 to #30, merged on 2026-09-24 and 2026-09-25. Among them, #8 is a CI fix, #9 follow-up docs, and #18, #21 and #28 pin moves. The exit criteria are met on main:
- the outcome lane holds 135 of 135 at 'extremes and at 'full (9,394 runs), chunk-size invariant;
- libhtp's twelve pipelining and multi-packet streams pass with our expectations, promoted by name;
- allocation: 2,512 B per request against the 3 KiB gate;
- m2-mutations.md is complete, and `make check-imports` is clean.

The ratchet stands at trace 135, outcome 135 and libhtp 12 passing. Each llhttp lane defers the 32 lenient fixtures, and libhtp has 90 not-yet. The suite count went from M1's ten to twenty-one, adding connection-allocation, connection-entry, connection-head, connection-table, decisions, host, libhtp-lane, message-loop, outcome-lane, span and target.

NEXT: M3, the response path (plan §7): the serializer as a total function, framing and the suppression rules, write accounting, and the eight originated statuses. It starts on a fresh branch cut from main after this commit, when the owner asks. Carried into M3: a 2xx answer to CONNECT carries neither Content-Length nor Transfer-Encoding (RFC 9110 §9.3.6; M2.5's note).


M3 — THE RESPONSE PATH (plan §7). Branch feat/m3-response-path, cut from main at b491d1f; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, on main at b491d1f, by `research/spike/m3-response-costs.sps`, new (`out/m3-response-costs.run{1,2}.txt`: the bytes identical, the times within 1%). A prior, not an oracle:
- a Date line, per response: 4,016–4,032 B and 1.2 µs through strings (the bytes vary with the time's digits), 208 B and 0.2 µs straight into bytes, 0 B when the shell keeps the line;
- the header check (a token name, a value with no control character but HTAB): 0 B and 145 ns for three headers;
- the allocation gate's workload, its actions going nowhere: 2,464 B per request today, 2,576 B with a prototype serializer writing an empty 200, 2,912 B with three headers and a 13-byte body. A Date formatted per response would put the second at 3,120 B, over the 3,072 B gate.

Found before the first test, and put to the owner: the plan and the decisions say nothing about a Date (RFC 9110 §6.6.1 makes it a MUST for 2xx, 3xx and 4xx from a server with a clock), nothing about a handler's response that cannot be written safely, and the write watermarks' read-stop can never fire in v1.

DECIDED on the owner's word (2026-09-25), asked by form with the measurements above; recorded as decision 0010:
- **The shell fills the Date.** The serializer leaves a fixed 37-byte slot after the status line, counts it, and formats the line; the shell fills the slot from a line it re-formats once a second (M4), and the fake shell from its fake clock. A handler's own Date is written instead.
- **A handler's response the serializer cannot write safely is answered 500**, then close, with a `log` action naming the fault. The server writes Content-Length and Transfer-Encoding itself, so a handler's are refused; a handler's `Connection: close` is honoured.
- **The write watermarks arrive in M6.** M3.3 keeps the byte and write accounting and the retention check. Decision 0005 and plan §3 and §7 carry dated notes.

The alternatives weighed: for the Date, none in v1, or the handler's job; for the unsafe response, repairing it silently, or trusting the handler's framing as Node does; for the watermarks, landing them in M3 with a read-stop no test can reach.

Defaults shown to the owner with the form, and taken: the status line says `HTTP/1.1`; a response the core originates has no body, `Content-Length: 0` and `Connection: close`; a HEAD answered with no body gets no Content-Length; an HTTP/1.0 keep-alive request gets `Connection: keep-alive`.

Read as the owner's choice, and flagged for the PR:
- a `Connection` field from a handler must be exactly `close`: any other value is a fault;
- a value's other control characters are faults too, not only CR, LF and NUL (RFC 9110 §5.5 calls them invalid);
- a body a 204, a 304 or a 2xx to CONNECT forbids is not written. That is the brief's suppression, not a fault.

Found and recorded:
- nothing produces 413 before M6's buffering helper, so M3.4 sends it through the serializer alone and drives the other seven end to end;
- decision 0009's 301 is a ninth status the core originates, and it closes too;
- a tick in `body` past the body deadline has no row (design §4.4 lists only head's 408); the wheel's M5 owns it.

The slices (plan §7), each red first and finished by a named mutation:
- M3.1, the serializer: `(http-server serializer)`, a response and a framing decision to segments and their byte count, the faults, the Date line. Every row is read back through chez-httparse's strict response parser.
- M3.2, framing: the decision in `(http-server decisions)` (Content-Length, chunked, close-delimited; HEAD, 1xx, 204, 304 and the 2xx to CONNECT; HTTP/1.0), and the core writing through the serializer.
- M3.3, write accounting: the bytes and writes outstanding, and the check that the core keeps no response bytes once the write is issued.
- M3.4, the originated statuses end to end, each closing.

M3.1 — THE SERIALIZER. At 794 inserted lines of code and tests, twice plan §1 rule 1's ~400, it goes up as two stacked PRs, one per step below, each green on its own: feat/m3-response-path (this entry's records and the first step), then feat/m3.1-wire, cut from it.

M3.1 FIRST STEP: what a handler's response may carry, and the Date line (feat/m3-response-path).
- `src/http-server/serializer.sls`, `(http-server serializer)`, new and pure (it imports `(rnrs)`, response, span and headers):
  - `response-fault`: #f, or the first fault decision 0010 item 2 names: not a response, a status outside 200–599, a reason or value with a control character other than HTAB, a header list that is not pairs of bytes, a name that is not a token, a Content-Length or Transfer-Encoding, a Connection that is not `close`, a body that is neither a bytevector nor #f. The value bytes refused are exactly the ones llhttp's strict parser refuses: measured with the response reader, it refuses 0x01 and DEL, and accepts HTAB and 0x80–0xFF;
  - `response-closes?`: the handler's `Connection: close`, in any case, with whitespace around it;
  - `date-line` and `date-line-length`: an IMF-fixdate line from whole seconds since the epoch, always 37 bytes, by the proleptic Gregorian calendar's 400-year eras. Instants before 1970 or after 9999 are refused.
- `tests/test-serializer.sps`, new: the Date line against RFC 9110 §5.6.7's example, the epoch, and Chez's own UTC calendar (`time-utc->date`) over 4,347 instants from 1970 to 2400, with the leap days of 2000 and 2400 and the 2100 that is not leap; and 30 fault rows, each with its RFC or its item of decision 0010.
- Red before green: against a stub that exported the four names and answered nothing, the suite exited 1, 7 passes and 32 failures. The 7 were the rows whose answer is "no fault" or "does not close"; mutations H to N make each red.
- Mutations (m3-mutations.md): ten, B to N. Each turns exactly its rows red: the era's last day, the control characters, the 1xx statuses, HTAB, the close option's case and whitespace, the status range's end, spans, and an empty reason.
- Every suite green in a scratch worktree with only this step: twenty-two suites, 440 expected passes (serializer 39), each exit 0. `make check-imports` is clean there.

NEXT: the second step, the wire, stacked on this one.

M3.1 SECOND STEP: the wire (feat/m3.1-wire, cut from feat/m3-response-path).
- `(http-server serializer)` gains `serialize-response` and `framing-modes`. A response, a framing mode and the Connection to write become the segments of one write and their byte count: the status line, the Date slot, the header block, the body.
  - The five modes: Content-Length; Content-Length with no body, a HEAD's answer; no body; chunked; close-delimited.
  - The status line of each of the 48 registered statuses (RFC 9110 §15's phrases, and RFC 6585's) is made once; any other status gets an empty phrase. The header block is one bytevector. The body is the handler's bytevector itself, never copied; a chunked body goes out as the first chunk, its size in lowercase hex.
  - A handler's Date takes the slot's place. A handler's Connection field is never copied: the connection argument writes the one line.
- `tests/response-reader.sls`, new: a response read back by chez-httparse's strict response parser, a client that is not our code. It returns the status, the reason, each field in order, the body, and how the read ended, and finishes a close-delimited message at EOF with `parser-finish!`, as a client does.
- `tests/test-serializer.sps` gains the wire table: 17 rows, each with its wire written out by hand, its segment count (the plan's check), its byte count, and what the parser reads back; the status lines of 13 statuses; and four refusals of `serialize-response`.
- Red before green: with the first step's library and a `serialize-response` that answered nothing, the suite exited 1, 56 passes and 85 failures. The 56 were the first step's 39 and the rows' 17 "no fault" checks.
- Mutations (m3-mutations.md): A, the plan's, joins consecutive segments into one bytevector, and exactly the seven segment counts go red while every wire, byte count and read-back holds. D, F and G break the Connection line, the chunk size and the Date slot, each on its row. The first step's ten, re-run on the whole suite, go red on their rows.
- `make test` green: twenty-two suites, 542 expected passes (serializer 141), exit 0. `make check-imports` is clean.

NEXT: the two stacked PRs, on the owner's word. Then M3.2, framing: the decision in `(http-server decisions)`, and the core writing through the serializer.

MERGED to main on 2026-09-25, as two stacked PRs landed bottom up on the owner's "do closing ritual":
- #31, the first step, merged as 12eb761 without deleting its branch, since #32 was based on it. Its squash tree (800e305) is identical to the tested tip's, 759b41b.
- #32 was retargeted to main, rebased onto 12eb761 and force-pushed with a lease read from the remote. The rebase took bf69714 to 9185286 with the tree unchanged (b82defc). #32 merged as fda651d, whose tree is the tested one, proved against the merge commit gh reports.
- Every `linux` check executed zero steps, stopped at the billing check: runs 36197576823 (#31), 36197580602 (#32) and 36198237486 (#32's rebased tip).
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to fda651d. The first step's branch was deleted by hand, local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-two suites, 542 expected passes, exit 0.

M3.1 DONE and merged: `(http-server serializer)` writes a response as the segments of one write, and refuses what it cannot write safely. Nothing calls it yet; M3.2 puts it in the core's path.

NEXT: M3.2, framing (plan §7): the framing decision in `(http-server decisions)` (Content-Length, chunked, close-delimited; HEAD, 204, 304 and the 2xx to CONNECT; HTTP/1.0), and the core writing through the serializer, answering 500 for a response with a fault. On a fresh branch cut from main after fda651d, when the owner asks.

A LIBHTP RUN THAT RAISES: the ratchet crashed instead of naming the stream. MERGED as e339931 (PR #33). Branch fix/ratchet-libhtp-raise, cut from main at bd49005; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`.
- Found by M3.2-T on feat/m3.2-framing: its fault made the fake shell raise, and test-ratchet.sps exited 255, outside the status vocabulary. The ratchet computed its lane verdicts at the program's top level, and `libhtp-mismatch` ran each stream with no guard, unlike the outcome lane.
- `libhtp-mismatch` runs a stream through the outcome lane's `attempt`, now exported and taking the run as a thunk. A run that raises is a mismatch that says what it raised. The run is an optional second argument, which the new check uses.
- The ratchet's gate is a procedure the suite calls, as test-connection-table's tables are. Any other raise there, such as the trace lane's re-raise of an error other than the adapter's, is a harness error, exit 2. A violation line now ends with its lane's reason.
- Red before green, then L9 (m3-mutations.md). Under M3.2-T's fault, simulated on this tree, the ratchet exits 1 and names 141 violations, the 12 libhtp streams among them; on main it exits 255 with the report's exception.
- `make test` green: twenty-two suites, 543 expected passes (libhtp-lane 15), exit 0. `make check-imports` is clean.

MERGED to main on 2026-09-25 as e339931 (PR #33), on the owner's "do closing ritual":
- The squash tree (444989d) is identical to the tested tip's, c1e7d5d, proved against the merge commit gh reports.
- The `linux` check (run 36202813436) executed zero steps, stopped at the billing check.
- `gh pr merge --delete-branch` switched this worktree to main, which no other worktree held, and fast-forwarded it to e339931. The branch was deleted local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-two suites, 543 expected passes, exit 0.

NEXT: M3.2, framing (plan §7), on feat/m3.2-framing, which takes this fix from main. Its four test files merge with it cleanly; the ledger and the mutation log meet only at the end of each file.


M3.2 — FRAMING (plan §7). Branch feat/m3.2-framing, cut from main at bd49005 and brought up to 409b886 (PR #33's fix and its reflect) before the first commit; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, on main at bd49005:
- the request versions a handler can be asked to answer: chez-httparse's strict parser hands 0.9, 1.0, 1.1 and 2.0 to on-headers-complete, and answers 1.2, 1.9, 2.1, 3.0 and 9.9 with 400 (a scratch run through the fake connection). Of the four, only 1.1 passes llhttp's gate, `major > 0 && minor > 0`, so on every version the parser admits the gate is RFC 9112 §6.1's "HTTP/1.1 (or later minor revisions)";
- the allocation gate: 2,512 B per request, before the serializer is in the loop.

Nothing here was the owner's to decide: the plan, the brief and decision 0010 settle every rule, so there was no form. Read as the owner's choice, and flagged for the PR:
- a response the core originates is framed by the same decision as a handler's, for the request the core has built, if any. With no body it gets `Content-Length: 0`, unless that request is a HEAD, when it gets none: 0010 item 6's HEAD rule wins over its "Content-Length: 0" default, since a HEAD's Content-Length must be the GET's (RFC 9110 §8.6), which a 500 cannot know. A refusal made before the request is built (a 301, or a 400 for the Host or the target) answers no built request, so a HEAD's gets `Content-Length: 0`: a GET with the same target gets the same response, so the length is the GET's;
- chunked goes only to a request that passes the gate `should-keep-alive?` applies, so the connection's two version rules agree;
- a 205 is framed like any status, as Go and Node frame it: with no body it gets `Content-Length: 0`, one of the three framings RFC 9110 §15.3.6 allows;
- the decision takes a length the server does not know, M6's stream, already: without it, the brief's mutation, chunked to a 1.0 client, has no row to turn red;
- every entry into `responding` arms the write deadline, the core's own responses included, as design §4.3's state table says. Design §4.4's rows that write a status armed none; they carry a dated note.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings": seven findings, all fixed, each below in its step. Two had their stated causes corrected by measurement first. A status that is not a fixnum already raises an assertion in Chez's fixnum comparisons, so the gap was a fixnum outside 100–599, which was framed silently. And the fault check made twice cost 270 ns of `serialize-response`'s ~570 ns for a three-header response, but no bytes.

M3.2 is 662 inserted lines of code and tests, over plan §1 rule 1's ~400, so it goes up as three stacked PRs, one per step below, each green on its own: feat/m3.2-framing (this entry and the first step), feat/m3.2-checked-entry (the second), cut from it, and feat/m3.2-core-writes (the third), cut from that.

M3.2 FIRST STEP: the framing decision (feat/m3.2-framing).
- `(http-server decisions)` gains `response-framing`, `response-connection` and invalid-response's 500:
  - `response-framing`: the request's method and version, the response's status, and its body's length (a count, none, or unknown) to one of the serializer's five modes. First match wins: a 1xx, a 204, a 304 and a 2xx to CONNECT get no body and no length; a HEAD's answer announces the GET's length when the handler gave its body, and nothing otherwise; a known length gets Content-Length; an unknown one is chunked to HTTP/1.1 and close-delimited to any other version. A status outside 100–599 and a length outside the three kinds are refused (review);
  - `response-connection`: `close` on the last response, `keep-alive` to any version but 1.1 when the connection stays, and nothing to 1.1 when it stays.
- `tests/test-decisions.sps` gains the framing table: 26 rows over the four versions the parser admits, each with its RFC or its item of decision 0010; the checks that every answer is one of the serializer's modes and every mode is some row's answer; the refusals of a length and a status outside their kinds; and the Connection rows, by version.
- Red before green: against a stub that exported the two names and answered nothing, the suite exited 1, 17 passes and 34 failures: every new check, and the reason list, which now names invalid-response. The status check, added in review, failed first against the decision without it: 51 passes, 1 failure.
- Mutations (m3-mutations.md): thirteen, A to L and S. A is the brief's: an unknown length chunked whatever the version turns red exactly the rows for 1.0, 0.9 and 2.0, and the check that every mode is some row's answer. The rest break the version gate, the rules' order, 304, CONNECT's 2xx, a HEAD with no body, the 1xx and 2xx ranges' ends, the two Connection answers, invalid-response's status and the length and status checks, each on its rows.
- Every suite green in a scratch worktree with this step alone on 409b886: twenty-two suites, 577 expected passes (decisions 52), each exit 0.

NEXT: the second step, the serializer's entry for a checked response and what the reader sees, stacked on this one.

M3.2 SECOND STEP: the serializer's entry for a checked response, and what the reader sees (feat/m3.2-checked-entry, cut from feat/m3.2-framing).
- `(http-server serializer)` gains `serialize-checked-response`, for a response whose fault the caller has asked for already, as the core has before it frames a handler's. It does not read the fields for faults again, and checks everything else as `serialize-response` does; `serialize-response` is now the fault check, then it (review: the check was made twice per response).
- `tests/response-reader.sls`: the parser pauses at each message's end, so the reader reports `bytes-after` when bytes follow the message, the one way to see a body written where a client reads none. And it reads past an interim 1xx to the final response, as a client does (RFC 9110 §15.2), returning one alone as itself (review: it stopped at the 1xx). The serializer's 141 checks are unchanged by either.
- `tests/test-serializer.sps` gains five checks: the checked entry writes every wire row as serialize-response does, and refuses a bad mode and a close on a kept connection; and the reader's three.
- Red before green: against a stub checked entry, the suite exited 1, 144 passes and 2 failures, the entry's two checks; against M3.1's reader, exit 1, 144 passes and 2 failures, `bytes-after` and the 100 Continue. A 1xx alone reads the same with either, so that check pins it.
- Mutations (m3-mutations.md): U, V and X, each on its checks: serialize-response no longer asking for a fault, the checked entry no longer refusing a close on a kept connection, and the reader stopping at an interim response.
- Every suite green in a scratch worktree with the first two steps on 409b886: twenty-two suites, 582 expected passes (serializer 146), each exit 0.

NEXT: the third step, the core writing through the serializer, stacked on this one.

M3.2 THIRD STEP: the core writes through the serializer (feat/m3.2-core-writes, cut from feat/m3.2-checked-entry).
- `(http-server connection)`: the `write` action is `(write segments nbytes)`: the serializer's segments for one write, the Date slot among them, and the bytes they come to (design §7.3). The framing is the decision's, for the request being answered, and the Connection field says close when the connection closes after the response.
  - A handler's response with a fault is answered 500, then close, with `(log invalid-response fault)` before the write (decision 0010 item 2). One without is written with `serialize-checked-response`; the core's own responses with `serialize-response`, which reads them for faults as any caller's.
  - A handler's `Connection: close` closes the connection after its response, as 'handler-close, unless it closes already for a reason of its own (item 3).
  - A close-delimited body closes the connection after it, as 'close-delimited, when nothing else does (review). The decision gives that mode only to a body of unknown length, which a response first has in M6, so no row reaches the arm yet: plan §9's M6 entry carries its row.
  - Every entry into `responding` arms the write deadline, the core's own responses included (review; design §4.3, and §4.4's dated note).
- `tests/fake-shell.sls`: a write fills its Date slot from the fake clock, which counts milliseconds, so with the line for its whole second. It keeps the bytes, and completes with its byte count; a count that is not the bytes' own is an assertion violation. `written-status` reads a write's status from its status line.
- `tests/test-connection-response.sps`, new, every write read back by the strict response parser. Twenty-two rows through the fake connection:
  - HTTP/1.1 and 1.0, keeping the connection and closing it, and two pipelined requests;
  - a HEAD with and without the GET's body, and a 204 and a 304 each given a body;
  - a 2xx to CONNECT and a WebSocket handshake, each closing after;
  - the handler's `Connection: close` and its own Date;
  - five faults answered 500 with their logs, one of them a HEAD's, which gets no Content-Length, and a sixth with a request behind it, never answered (review);
  - a HEAD redirected before its request is built: 301 with `Content-Length: 0` (review).
  Beside them, the Date filled from the clock at RFC 9110 §5.6.7's example instant.
- The suites that record a write read its new shape:
  - the table's rows state each write's segments and byte count, the originated ones with RFC 9110's phrases, `Content-Length: 0` and `Connection: close`, each now followed by the write deadline; and M3.2's two rows, R1 and R2, table what handler-responded does with a fault and with the handler's close;
  - the head suite records each originated write's status and header block;
  - the message loop and the two lanes record the status alone, so their expectations and the ratchet are unchanged.
- `docs/responses.org`, new, and a README line: what the server writes around a handler's response, the bodies it never sends, and what it answers 500. Design §4.4 and plan §9's M6 carry dated notes.
- Red before green, against the second step's core: the new suite exited 1, 0 passes and 23 failures; the table failed 10 (H7, the seven originated writes, R1 and R2), the head suite 40, the outcome lane 3, the libhtp lane 12 and the ratchet 1 (one violation line), and the message loop exited 2 (its fake shell cannot perform the old write).
- Allocation: 2,736 B per request with the serializer in the loop, 2,512 B before, within the 3,072 B ratchet. Every shape holds.
- Mutations (m3-mutations.md): M to R, T, W, Y, Z and AA. M, N, O, P, Q, W, Y and Z each turn red exactly their rows: the handler's close, the fault check, the method and version the framing is told, the fault's log, the write deadline, a refused response's close, and the framing of a response to no request. O's HEAD row is seen only by the reader's `bytes-after`. R (never say close) and T (a byte count one off) show which suites read the field and the count. AA, the fault check made twice again, survives every suite: it changes no byte and allocates nothing, so its 270 ns is measured, not tested. The first step's twelve, re-run on the finished tree, go red in the table as before, and B, D, F, I, J and K in the core's rows too.
- Found by T: test-ratchet.sps ran its lanes outside `run-suite`, and a raise in a libhtp stream exited 255. Fixed on main by PR #33 (e339931), which this branch takes: under T the ratchet now exits 1 and names the streams.
- `make test` green: twenty-three suites, 608 expected passes (connection-response 23), exit 0. `make check-imports` is clean.

NEXT: the three stacked PRs, on the owner's word. Then M3.3, write accounting: the bytes and writes outstanding, and the check that the core keeps no response bytes once the write is issued.

MERGED to main on 2026-09-25, as three stacked PRs landed bottom up on the owner's "do closing ritual":
- #34, the first step, merged as 859aad0 without deleting its branch, since #35 was based on it. Its squash tree (b826809) is identical to the tested tip's, 845cee8.
- #35 was retargeted to main, rebased onto 859aad0 and force-pushed with a lease read from the remote. The rebase took 3f46cc5 to 29ca1cc with the tree unchanged (5e93ffa). #35 merged as ba66aa2, again keeping its branch for the PR above; its tree is the tested one, proved against the merge commit gh reports.
- #36 was retargeted and rebased the same way, from 3f46cc5, the tip it was built on: fc7dfe3 to 2d29b00, the tree unchanged (f15ca23). #36 merged as d563e03, whose tree is the tested one.
- Every `linux` check executed zero steps, stopped at the billing check: runs 36203983952 (#34), 36203990459 (#35) and 36203993158 (#36), and the rebased tips' 36204781390 (#35) and 36204828633 (#36).
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to d563e03. The two lower branches were deleted by hand, local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-three suites, 608 expected passes, exit 0.

M3.2 DONE and merged: the core writes every response through the framing decision and the serializer. A handler's response goes on the wire framed for the request it answers, with the Connection field its connection's fate calls for and a Date slot the shell fills; one the serializer cannot write safely is answered 500, and the connection closes. The brief's mutation, chunked to a 1.0 client, is witnessed (M3.2-A), one of M3's exit criteria.

NEXT: M3.3, write accounting (plan §7): the bytes and writes outstanding, and the check that the core keeps no response bytes once the write is issued, finished by the plan's mutation, the segment list retained until the completion. On a fresh branch cut from main after this commit, when the owner asks.


M3.3 — WRITE ACCOUNTING (plan §7). Branch feat/m3.3-write-accounting, cut from main at c39bcf6; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, on main at c39bcf6:
- what the core keeps once a write is issued: nothing. A scratch probe stepped a handler's response through `conn-step`, dropped the write action, and ran a full collection: the response, its body, the segment list and the header block were all released. The same probe holding the segments in a variable saw them held, but only once the program read that variable afterwards. A variable that is only assigned is compiled away, so a calibration must read what it holds after the collection;
- the core counted writes outstanding already (`conn-outstanding`, since M2.1), and `write-completed` carried a byte count (design §4.1) that nothing read;
- four drivers completed writes with counts of their own: the table's H8 to H10 (100), the entry suite's replay (10), the trace lane (1) and the allocation suite (the request's length);
- the allocation gate: 2,736 B per request.

Nothing here was the owner's to decide: the plan, design §7.3 and decision 0010 item 5 settle it, so there was no form. Read as the owner's choice, and flagged for the PR:
- the retention check is the core's half, as decision 0010 item 5 words it: a connection as the shell holds one, the core's state in the adapter's context, with its parser. The plan's "write executor" is M4.2's shell, which carries the other half (plan §8, dated note);
- a completion the core did not ask for is the shell's bug, an assertion violation, as a fake shell's count that is not its bytes' is: with no write outstanding, without a count or with one that is not a count, for more bytes than are outstanding, or for fewer than the last write left;
- a write a close cut short, when a read error closes the connection while it is outstanding, is settled by its completion in `closing` (review). In the other states no write is outstanding, and a completion changes nothing, as before. How the shell reports a cancelled write is M4's.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings": seven findings, all fixed, each premise checked against the code first.
- The accounting never settled once a read error closed a connection with a write outstanding: the cancelled write's completion in `closing` was ignored. It is settled there now (W5).
- The library header's contract said only an event outside the vocabulary raises. It now names an event the state says cannot have happened, and so does conn-step's comment.
- The count was read when the event arrived, in any state, so a completion without one raised `car`'s error, not the core's, even in idle. It is read where it is accounted, and its absence is the core's own refusal.
- `make-conn-state` checked neither count, and T2's and P3's synthetic states held a write with no bytes. The counts must be counts, zero together, and the two states carry bytes.
- The retention driver ended the suite, exit 2, when the core did not pause, asked for no write, or refused the completion, and it assumed where the header block sits. Each is now a failing check, and the header block is the first bytevector after the status line.
- The retention driver copied a write as the fake shell does. The fake shell now exports that, `write-wire`, and both use it.
- The accounting rows' step copied the table's `outcome`. It is built on it now, as the pause protocol's `kept` is, so the rows state each step's actions too.
Red before green for the review's checks: against the core before the fixes, the table exited 1, 92 passes and 4 failures: the constructor's check, W4's completion without a count and with no write outstanding, and W5.

M3.3: the writes and bytes outstanding, and the check that the core keeps no response bytes (feat/m3.3-write-accounting).
- `(http-server connection)`: the state counts the bytes outstanding beside the writes, read by `conn-outstanding-bytes`. `make-conn-state` takes them after the writes and checks that both are counts, zero together, since every write has bytes. A write is counted where it is made, in `write-action`, with its bytes. `(write-completed nbytes)` settles one, in `responding` or, for a write a close cut short, in `closing`, and one the core did not ask for is refused.
- `tests/test-connection-table.sps`: five rows, W1 to W5, each stating the step's outcome and the counts after it:
  - a write outstanding once issued, with its bytes: a handler's, the core's 408 and a fault's 500, each counted from the row's own write above;
  - a completion with more outstanding;
  - the last completion;
  - six completions refused, each breaking one condition. A refusal counts only if conn-step raises it, not a fixnum operation or `car`;
  - a write a close cut short, settled in closing.
  H8 to H10's, T2's and P3's states carry the bytes their writes come to, and the constructor's check has its own test.
- `tests/test-connection-retention.sps`, new. A connection as the shell holds one serves a request, and its write is performed as uv-write*! performs it. With the write outstanding, a full collection must release the response, its body, the segment list and the header block: a handler's response, and one with a fault, answered 500. The instrument is calibrated first: a held object is seen held, a dropped one released. Whatever goes wrong on the way is a failing check, not the suite's end.
- `tests/fake-shell.sls` exports `write-wire`, a write's bytes as a client reads them, which its own writes and the retention suite share.
- The drivers complete each write with its own byte count: the entry suite's replay, the trace lane and the allocation suite.
- Plan §7's M3.3 and §8's M4.2, and design §7.3, carry dated notes.
- Red before green: against a stub that exported the field with no accounting, the table exited 1, 82 passes and 10 failures, every W instance as they stood. The retention suite was green there, 8 passes, since the core already keeps nothing: its red is the plan's mutation.
- Allocation: 2,736 B per request, unchanged.
- Mutations (m3-mutations.md): A to L, and A2, on the finished tree after the review.
  - A is the plan's: the state keeps the segment list until the completion. Only the retention suite goes red, both cases, and every wire test holds. A2 keeps the handler's response instead, and only its case goes red.
  - D to G, and the review's H, I and K, each break the completion's check, and each turns exactly its W4 or W5 instances red. J drops the constructor's check, and only its test goes red. L asks for no write, and the retention suite fails its checks, exit 1.
  - B and C break the counting itself. W1, and W2 and W3 with W5, go red, and so does every suite that completes a write (B) or answers twice on one connection (C): the check refuses the completion.
- Found by A's first run: the mutation runner kept only the last of several edits to one file. It now applies them in turn, and no earlier spec had two.
- `make test` green: twenty-four suites, 631 expected passes (connection-table 96, connection-retention 8), exit 0. `make check-imports` is clean.
- 348 inserted lines of code and tests, under plan §1 rule 1's ~400: one PR.

NEXT: the PR, on the owner's word. Then M3.4, the originated statuses end to end (plan §7): each of design §6.5's statuses, and decision 0009's 301, produced through the serializer and closing the connection; 413 through the serializer alone.

MERGED to main on 2026-09-25 as 0206728 (PR #37), on the owner's "do closing ritual":
- The squash tree (77f5166) is identical to the tested tip's, 23da757, proved against the merge commit gh reports.
- The `linux` check (run 36212535551) executed zero steps, stopped at the billing check.
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to 0206728. The branch was deleted local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-four suites, 631 expected passes, exit 0.

M3.3 DONE and merged: the core counts the writes and the bytes outstanding, settles each write at its completion, refuses a completion it did not ask for, and keeps nothing of a response once its write is issued, which the retention suite checks by liveness. M6's write watermarks will read the bytes outstanding, and M4.2 carries the same check against the real shell's write executor.

NEXT: M3.4, the originated statuses end to end (plan §7): each of design §6.5's statuses (400, 408, 413, 414, 431, 500, 501, 505) and decision 0009's 301, produced through the serializer and closing the connection, 413 through the serializer alone; finished by the plan's mutation, one status that keeps the connection alive. On a fresh branch cut from main after this commit, when the owner asks.


M3.4 — THE ORIGINATED STATUSES END TO END (plan §7). Branch feat/m3.4-originated-statuses, cut from main at b3b1a90; 2026-09-25, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, on main at b3b1a90, by a scratch probe that provoked each status on the fake connection and read every write back with chez-httparse's strict response parser:
- every status design §6.5 and decision 0009 name, but 413, goes on the wire already: its status line and phrase, the Date, a Location for the 301, `Content-Length: 0`, `Connection: close` and no body, read back whole. The connection closes once the write completes, for the status's reason. M3.2 put the core's own responses through the serializer, and M2 closes after each;
- 413 has no way in before M6, as recorded at M3's start. Through the serializer alone it reads back the same way;
- no suite produced a 408 end to end: only the table's rows T4 and W1 make one, from a state they build;
- a status originated in `head` or `body` is written with the socket still read. Design §4.4's rows for it list no `read-stop`, but §4.3's table says `responding` does not read. The core feeds nothing in `responding`, so what arrives there is dropped. The two 500s are answered in `handling`, after reading stopped at the pause;
- the allocation gate: 2,736 B per request.

Nothing in the slice was the owner's to decide: the plan and design §6.5 settle it, so there was no form before the first test. How the connection closes after a refusal was put to the owner after the review (below). Read as the owner's choice, and flagged for the PR:
- reading on in `responding` is left as M2 made it, and written down;
- `(http-server decisions)` exports its reasons as `originated-reasons`, read from the same table as reason-status, so that the suite can check it has a row for each;
- 413's row frames and closes its response with the decisions' own procedures, as the core frames a response to no request it has read;
- the user docs gain one table of the statuses the server sends by itself (docs/responses.org). 413 is left out: the server does not send it yet.

REVIEWED before the first commit, at high effort (/code-review): six findings. On the owner's word ("fix all but the rfc 9112 issue - we need to discuss"), five are fixed, each premise checked first:
- The docs' 501 row said a Transfer-Encoding whose last coding is not chunked gets 501. Measured through the core: 501 goes to one with no chunked coding in it (gzip, deflate, identity, pigeons, chunkedchunked, and `gzip, deflate`); a coding after chunked (`chunked, deflate`, `chunked, chunked`) and an empty value get 400; chunked last is accepted. The same wrong rule was in the new suite, in `parser-error-status`'s comment and twice in test-connection-head.sps, whose own row below it answers `chunked, deflate` 400. All five now say it as measured.
- The suite's header comment, and this entry, said every row sends a request behind the offending one and another while the write is outstanding. The 408's head never ends, so nothing is behind it, and a handler's 500 is written after reading stopped. Both now say which rows send what.
- `(http-server decisions)`' table was said to be in design §6.5's order; it is by status, 0009's 301 first.
- The 408's row moved the clock by the limits' header timeout but expected the Date for 60 s. It now moves the clock a minute itself: the core reads no clock, and only the Date shows it.
- The suite copied test-connection-response.sps's read-back helpers. Both now share `(read-back)`, a test library.
Held for the owner, then decided (below): reading on in `responding` after an originated status has no bound before M5's write deadline, and design §4.3's note called it RFC 9112 §9.6's advice. §9.6 reads on after a half-close, and only until the client closes or the response has surely arrived.

MEASURED for that decision, 2026-09-25, Darwin arm64, over loopback, by a scratch spike (a Python client and server, 100 runs each). The server reads the first 4 KiB of a request, writes a 431, and closes:
- closing at once, with the rest of the request unread: the client never read the 431. Sending 8 KiB or 64 KiB, its read failed with "Connection reset by peer", though the 431 was written before the close. Sending 4 MiB, its send failed first (a reset 69 times, a broken pipe 31);
- closing in stages (shut the write side, read and drop until the client closes, then close): the client read the 431 in every run, at every size.
The core reads on only until the status's write completes, usually on the loop's next turn, and then closes at once. So a client still sending when it is refused most likely reads a reset, not the status: a head over its limit (431), a target over its limit (414), an HTTP/2 client's preface and the frames after it (505), a head the deadline cut short (408), and in M6 a body over its cap (413). The shell reads 16 KiB at a time, so a request that arrives in one read is drained. nginx lingers by default (up to 30 s, and 5 s between reads), and Go waits 500 ms after shutting its write side.
*Corrected 2026-09-26 (M3.5):* the spike counted a client that read the 431 and then met a reset as one whose read failed. Measured again on Darwin and Linux, the client read the 431 in every run at 8 KiB and 64 KiB, and the reset failed only the read after it. At 4 MiB its send failed first, as above. So a client refused while still sending loses the status only while its send is under way. What else a reset loses is in M3.5's entry below, and in decision 0011.

DECIDED on the owner's word (2026-09-25), asked with the measurement above and three options, each with its rough size: the staged close in the core, 200–300 lines; in the shell only (M4.2), about 100; none in v1, about 20. THE STAGED CLOSE GOES IN THE CORE. After a status it originates is written, the core asks for `shutdown`, the half-close, keeps reading and dropping what arrives, and closes when the client closes or a linger deadline passes. It is a timeout policy, tabled with the fake clock like the core's other deadlines, and it needs a new limit, so a decision record. This PR leaves the behaviour as M2 made it, as recommended with the options, and corrects the notes: design §4.3's said the reading on was §9.6's advice, and it is not.
Read as the owner's choice, and flagged: it lands as its own slice, M3.5, next, before the M3 exit, not in M5, which is not sliced yet (plan §10). M3.5 settles its limit and default, the state the connection lingers in, and which closes linger, measuring first. The shell's half, `uv_shutdown` and reading on until the core closes, is M4.2's, and M4.4's socket lane gets the measurement as a test.

M3.4: every originated status end to end (feat/m3.4-originated-statuses).
- `(http-server decisions)`: the core's reasons and their statuses are one table, which reason-status reads and `originated-reasons` exports.
- `tests/test-connection-originated.sps`, new. Fourteen rows, one per reason the core closes with after a status of its own, and one for each of a parser error's two statuses: the 301, three 400s (the target, the Host, the parser), the 408, the 414, the four 431s, the two 500s (a raise, and a response with a fault), the 501 and the 505. Each provokes its status as a client does. Every row but the 408, whose head never ends, sends a request behind it in the same delivery, and another is delivered while the write is outstanding if the connection still reads; after a handler's 500 it does not, since reading stopped at the pause. It states the write as the strict response parser reads it, the actions from the core's response on, and the state and reason the connection ends with. 413 goes through the serializer alone. Three checks keep the table whole: every reason `originated-reasons` lists has a row, every row's reason is one of them or a parser error's, and design §6.5's statuses but 413, and 0009's 301, each have a row.
- `tests/read-back.sls`, `(read-back)`, new: a write as read-response reads it back, for a row's expected value, which test-connection-response.sps and this suite share.
- docs/responses.org: what the server answers by itself.
- Plan §7's M3.4 and §8's M4.2, and design §4.3, carry dated notes, and plan §7 gains M3.5, the staged close.
- Red before green: the rows opened green, 18 passes, since the core already writes each status and closes after it. Their red is the plan's mutation, run once per reason: A1 to A13 each turn that reason's rows red and no other row.
- Mutations (m3-mutations.md): A1 to A13, and B to H.
  - B feeds a delivery in `responding` to the parser: the twelve rows answered while reading go red. C feeds the pending input before a close: the two 500s go red.
  - D adds a reason with no row, and E empties `originated-reasons`: each turns one coverage check red. H drops the 501 row from the table, and the statuses check goes red.
  - F gives 413 RFC 7231's phrase: its row and the serializer's go red. G leaves `Connection: close` out of the core's responses: every row driven end to end goes red, and the 413 row holds.
- Found by H's first run: the mutation runner ran each suite program from the tree, so an edited program was never run. It now runs an edited program from the mutant's root. No earlier spec edited one.
- Allocation: 2,736 B per request, unchanged.
- `make test` green: twenty-five suites, 649 expected passes (connection-originated 18), exit 0. `make check-imports` is clean.
- 288 inserted lines of code and tests after the review (255 before), under plan §1 rule 1's ~400: one PR.

NEXT: the PR, on the owner's word. Then M3.5, the staged close (plan §7, added 2026-09-25): after a status the core originates, the half-close, reading on and dropping what arrives, and the close when the client closes or a linger deadline passes, its limit and default settled by a decision record, measuring first. Then the M3 exit (plan §7): the brief's gate checked on the merged tree (the table tests, the corpus lane, and the chunked-to-1.0 mutation, M3.2-A), the serializer's segment count (M3.1-A), and the allocation gate re-measured with the response path in the loop; then M3's close-out.

MERGED to main on 2026-09-26 as 274c08b (PR #38), on the owner's "do closing ritual":
- The squash tree (a29f096) is identical to the tested tip's, bef7cb8, proved against the merge commit gh reports.
- The `linux` check (run 36238855996) executed zero steps, stopped at the billing check.
- `gh pr merge --delete-branch` switched this checkout to main and fast-forwarded it to 274c08b. The branch was deleted local and remote, and refs pruned; no PR is open.

`make test` green on main: twenty-five suites, 649 expected passes, exit 0.

M3.4 DONE and merged: every status the core originates is driven end to end, read back by a client's parser, and shown to close the connection, and `originated-reasons` keeps the table whole. The close itself is not yet safe for a client still sending, which a reset makes lose the status: the staged close is decided, and is M3.5.

NEXT: M3.5, the staged close (plan §7, added 2026-09-25): after a status the core originates is written, the core asks for `shutdown`, reads on and drops what arrives, and closes when the client closes or a linger deadline passes. Measure first; settle the linger limit and its default by a decision record, the state the connection lingers in, and which closes linger; finish with the plan's mutation, a close at once. On a fresh branch cut from main after this commit, when the owner asks. Then the M3 exit.


THE SHARED HEADER HELPERS (refactor/header-byte-helpers), the first of the Transfer-Encoding fix's two stacked PRs. Cut from main at 5e16b63; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

The fix's review, whose entry comes with the next PR, found that its new library re-implemented byte helpers the pure libraries already had: `(http-server headers)`' ASCII case folding, and the serializer's OWS test. Measured at 5e16b63: `close-option?`, the serializer's check of a handler's Connection value, trims OWS with loops of its own, and makes a span on each call to compare the value without regard to case. Nothing here was the owner's to decide.
- `(http-server headers)` exports three helpers:
  - `ows?`: SP or HTAB (RFC 9110 §5.6.3);
  - `trim-ows`: the bounds of a range without the OWS at either end;
  - `range-ci=?`: a range compared with the whole of a token, without regard to ASCII case. `header-name=?` shares its loop.
- `(http-server serializer)`'s `close-option?` reads with them, and no longer makes a span on each call.
- `tests/test-headers.sps`: three checks, one per helper. The compare's check covers a range longer than its token, and one shorter.
- Red before green: against stubs that answered wrongly (`ows?` #f, `trim-ows` the bounds unchanged, `range-ci=?` #f), the three checks failed, and every other suite was green. That run was on the combined tree, before the split.
- Mutations (m3-mutations.md, "The shared header helpers"): HA to HD, all killed on this tree. Each turns the headers suite's check and the serializer's Connection rows red.
- `make test` green: twenty-five suites, 652 expected passes (headers 18), exit 0. `make check-imports` is clean. Allocation: 2,736 B per request, unchanged.
- 64 inserted lines of code and tests.

NEXT: the Transfer-Encoding fix, stacked on this (fix/transfer-encoding-status). Then M3.5, the staged close, and the M3 exit.


FIX — THE TRANSFER-ENCODING STATUSES, BY RFC 9112 (a slice of its own, before M3.5). Branch fix/transfer-encoding-status, cut from main at 5e16b63; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, after M3.4's merge, when the owner asked whether the server does what nginx and Node do:
- through the core, on main at 5e16b63:
  - a Transfer-Encoding with no chunked coding got 501, at the parser's `e-request-invalid-te`: gzip, deflate, identity, pigeons, chunkedchunked, `gzip, deflate`, and `chunked;x=1`;
  - a coding after chunked got 400, at `e-bad-te-value`: `chunked, deflate`, `chunked, chunked`, chunked on one line and gzip on the next, and `chunked,`. An empty value got 400 too;
  - a coding before a final chunked was accepted, and its body read as chunked with the other coding never undone. That held on one line or two, in any case, with any OWS, with a parameter and with an empty element: `gzip, chunked`, `gzip, CHUNKED`, `gzip;q=0.5, chunked`, `gzip, , chunked`;
- Node v20.10.0, measured over loopback here: 400 to every invalid one, the lists with no chunked among them. It accepted a coding before a final chunked;
- nginx and Go, read on master (nginx's `ngx_http_process_request_header`; Go's net/http `determineBodyLength` and its server's 501): 501 to anything but exactly `chunked`;
- RFC 9112 §6.3 item 4: a request whose final coding is not chunked MUST get 400. §6.1: a coding the server does not understand SHOULD get 501. llhttp v9.4.3 cites the MUST at the branch that makes `e-request-invalid-te` (src/native/http.c:77-85);
- chez-httparse's docs/api.org (v0.4.1, lines 105–116), which M2.5 followed, recommends 501 at that node and says Node answers 501 there. Node does not.

DECIDED on the owner's word (2026-09-26), by form, with the table above and four options, each with its rough size: RFC 9112 EXACTLY. 400 whenever the body's end cannot be found, with no chunked or with chunked not last (§6.3's MUST). 501 when chunked is last but another coding comes first, which the server does not undo (§6.1's SHOULD). The alternatives weighed:
- like nginx and Go: 501 to anything but exactly chunked, which breaks §6.3's MUST;
- like Node: 400 to every invalid one, with a coding before chunked passed through to the handler;
- as it was, matching none of the three.
The form estimated about 60–100 lines for this option; it came to 303 with the new library's own suite and the node's removal from the event.
The same form granted one upstream ask. FILED chez-httparse #50, a docs fix: Node answers 400, and §6.3 makes the node's case a 400.

Read as the owner's choice, and flagged for the PR:
- the codings are judged after the Host and the target, so a request refused for either is answered 400 first. The two strict fixtures with a coding before chunked, transfer-encoding.md#21 (on one line) and #22 (on two), have a fragment in their target. They stay the trace lane's invalid-target refusals, and that lane now holds the order too;
- the parser's flags decide which rule applies (review). The codings are read only when the parser frames the body by a final chunked (F-CHUNKED), and where chunked sits in the list is the parser's to judge: a coding after it is the parser's 400, never the core's 501. Measured at the pin: `chunked`, `Chunked`, `gzip, chunked`, and gzip and chunked on two lines set F-CHUNKED; `gzip` and `chunked;x=1` do not, and the parser refuses them;
- the checks run in RFC order at on-headers-complete: the Host (a MUST), the framing (a MUST), the target (a SHOULD, 400 or 301), then the codings (a SHOULD, 501). A request refused for an earlier rule never meets a later one. Below 1.1 is llhttp's version gate, as should-keep-alive? applies it, so 0.9, and 2.0 in HTTP/1 syntax, count as HTTP/1.0 here;
- the node leaves the parser-result event. M2.5 added it for the split, and the event carries the error's code alone again;
- `chunked,` is refused by the parser (400), where RFC 9110 §5.6.1 asks a recipient to ignore an empty element. That strictness is llhttp's, and chez-httparse follows it; recorded, not changed.

REVIEWED before the first commit, at high effort (/code-review): six findings, all fixed on the owner's "fix all findings", each premise checked first.
- The check answered from the list alone, so its 501 relied on the parser having refused a coding after chunked, and its contract said "in any order". It now asks the parser's flags whether the body is framed by a final chunked (F-CHUNKED), and the list only whether it names another coding. Where chunked sits is the parser's to judge.
- An HTTP/1.0 request with Transfer-Encoding kept a keep-alive connection. Measured at 5e16b63: served, then the request behind it served too, and the connection stayed idle. RFC 9112 §6.1 says MUST treat its framing as faulty and close. The fix first served it and closed after; the owner then decided by form to refuse it (below).
- The new library copied the case folding and the OWS test that (http-server headers) and the serializer already had. `(http-server headers)` now exports `ows?`, `trim-ows` and `range-ci=?`, and the new library and the serializer's `close-option?` both use them. `close-option?` no longer makes a span per call.
- The head's fields were walked twice per request, once for the Host and once for the codings. Premise checked: merging the walks would not halve the name comparisons, since each field still meets both names, and a length mismatch ends most comparisons at once. What does remove the second walk is the F-CHUNKED gate, which skips it for every request whose body is not chunked.
- Comment lines left unwrapped by the edits are rewrapped.
- A unit row that repeated another went with the rewrite.

DECIDED on the owner's word (2026-09-26), by form, after the owner asked what the HTTP/1.0 decision was: REFUSE IT WITH 400. A request below HTTP/1.1 that carries Transfer-Encoding is refused as `faulty-framing`, answered 400, and the connection closes; the handler never sees it. RFC 9112 answers faulty framing with a 400 and a close (§6.3), no well-behaved HTTP/1.0 client sends the field, and nginx does the same (read on master). The alternatives weighed, with their rough sizes:
- serve it as the parser frames it (chunked), then close. This was the first build, and it needed no change, but it trusts the framing the RFC says to treat as faulty;
- ignore the field and serve the request as if it had no body, then close, as Go does. About 60–100 lines: the core would have to tell the parser to skip the body, which it cannot yet.

LANDED upstream the same day: chez-httparse #50, in v0.4.2 (29efa8f; PR #51, e2d647d; release PR #52). The generated parser is unchanged, so the pin may move alone and moves no behaviour; it stays at v0.4.1 here. The session that fixed it found a fourth node under `invalid-transfer-encoding` that #50 missed: `e-te-with-content-length`, a Content-Length followed by Transfer-Encoding. Measured through the core, it is a 400 and a close, as every parser error is now. The reverse order is `invalid-content-length`, a 400 too. The comments that listed three failures now name four.

THE FIX (fix/transfer-encoding-status):
- `(http-server transfer-coding)`, new and pure, holds both of RFC 9112 §6.1's rules, from llhttp's flags and the head's fields read in place:
  - `unsupported-transfer-coding?` is #t when the parser frames the body by a final chunked (F-CHUNKED) and a Transfer-Encoding line names another coding. The codings are every line's elements, with OWS dropped, empty elements ignored, chunked matched without regard to case, and a coding with a parameter not chunked;
  - `faulty-framing?` is #t for a request below HTTP/1.1 with the field (F-TRANSFER-ENCODING).
- `(http-server connection)`: at on-headers-complete, after the Host, a request below 1.1 with Transfer-Encoding is refused as `faulty-framing`. After the target, another coding beside a final chunked is refused as `unsupported-transfer-coding`. A parser-result's error is its code alone.
- `(http-server decisions)`: `parser-error-status` takes the code alone and answers 400 to every parser error. `faulty-framing` is a reason, answered 400, and so is `unsupported-transfer-coding`, answered 501. `http/1.1?`, llhttp's version gate, is exported.
- The shared header helpers, `ows?`, `trim-ows` and `range-ci=?`, went up in the PR below (THE SHARED HEADER HELPERS, above), and `(http-server transfer-coding)` reads with them.
- `tests/fake-shell.sls` hands the core the error's code.
- Tests:
  - `tests/test-transfer-coding.sps`, new, 12 checks. Each value is a span followed by `, gzip`, so a scan past its end changes the verdict;
  - the head suite: pigeons 400; another coding beside chunked 501, on one line and on two; chunked alone read; HTTP/1.0 with Transfer-Encoding 400, asking to keep the connection or not; and the order. A missing Host and an invalid target are each a 400 before the codings, two Hosts a 400 before the framing, and the framing a 400 before the target and the codings;
  - the decisions suite: every code 400, the reason's 501, the version gate, and at the pin `gzip, chunked` is no parser error;
  - the table: T3's three instances, the transfer-encoding one a 400;
  - the originated suite: its 501 is the core's reason now, a Transfer-Encoding with no chunked is a 400 row, and so is HTTP/1.0 with Transfer-Encoding.
- Docs and records:
  - design §6.3 and §6.5, and plan §6's M2.5, carry dated amendments;
  - docs/responses.org's 501 row says it as it is, and docs/connections.org says an HTTP/1.0 request with Transfer-Encoding gets 400;
  - decision 0008's table records #50, which needed no workaround and landed the same day, and its #36 row notes that the server dropped the split.
- Red before green, in three rounds:
  - before the review, 19 checks failed in five suites, all on the transfer codings;
  - for the review's fixes, 8 checks failed in four suites: HTTP/1.0 with Transfer-Encoding in the response suite and the table, the three helpers, `chunked, gzip` without F-CHUNKED, and the close below 1.1.
  - for the owner's 400, 6 checks failed in three suites against the tree that closed after the response: the head suite 3 (HTTP/1.0 with Transfer-Encoding, twice, and the framing's order), the originated suite 2 (its row, and the reasons' coverage) and the decisions suite 1. The unit suite could not load until the rule had its new name.
  Every other suite was green both times.
- Mutations (m3-mutations.md, "The transfer-encoding statuses"): TA to TU on the final tree, all killed, each by the checks it should turn red. Earlier sets ran before the review and before the 400, and this one replaces them.
  - TA answers `invalid-transfer-encoding` 501 again, TQ answers the new reason 400, TU answers `faulty-framing` 500, and TB drops the core's question about the codings. Each turns its status rows red.
  - TC, TD, TR and TS move the checks out of order: the codings before the target or the Host, and the framing after the target or before the Host. Each turns its order row red. TC and TD also turn the trace lane red, where #21 and #22 turn from invalid-target to unsupported-transfer-coding.
  - TE drops the F-CHUNKED gate, and TF gates on F-TRANSFER-ENCODING instead. Pigeons turns 501, and the trace lane sees the core refuse transfer-encoding.md#13 before the parser does.
  - TG reads only the first line; TH to TL break the shared helpers and the element rules; TM runs the scan past the value. Each turns its unit and helper rows red. TI also turns the trace lane red, where #27 and #29 send `chunked` with a trailing space, and TM turns every chunked request red end to end.
  - TN never asks the HTTP/1.0 rule: its rows go red. TO inverts the rule's version gate, and every HTTP/1.1 request with Transfer-Encoding is refused, across the head suite, the originated suite and the lanes. TP reads F-CHUNKED for the rule, and only the unit suite sees it, since the parser refuses every Transfer-Encoding it does not frame as chunked.
- Found while writing the mutants: the first set's scan past the value would have survived the unit suite's first helper, and the review's rewrite needed the two-line row in the other order for TG. Both were fixed before the runs.
- `make test` green: twenty-six suites, 674 expected passes (transfer-coding 12, headers 18, decisions 52, connection-head 51, connection-table 95, connection-originated 20), exit 0. `make check-imports` is clean. Allocation: 2,736 B per request, unchanged.
- 396 inserted lines of code and tests in this PR, stacked on the helpers' 64. Together they come to 460 (303 before the review), over plan §1 rule 1's ~400, so they went up as two PRs, split at the helpers, each green on its own. The first form's estimate was 60–100 lines.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M3.5, the staged close (plan §7): after a status the core originates is written, the core asks for `shutdown`, reads on and drops what arrives, and closes when the client closes or a linger deadline passes; measure first, then settle the linger limit and its default by a decision record. Then the M3 exit.

MERGED to main on 2026-09-26, bottom up, on the owner's "do closing ritual":
- #39, the shared header helpers, as 460f098. Its squash tree (8237a36) is identical to the tested tip's, b2a243c. It merged without deleting its branch, so that #40 stayed open on it.
- #40, the fix, as 93f3eaf. It was retargeted to main and rebased from b2a243c (b2dd852 -> 003cbb2, tree a556de9 unchanged, proved), then force-pushed with the lease read from the remote. Its squash tree is identical to 003cbb2's.
- Every run was the billing block, zero steps: 36244236071 (#39), 36244252138 (#40), and 36244343374 (#40's rebased tip).
- `gh pr merge --delete-branch` switched this checkout to main at 93f3eaf and deleted #40's branch. #39's was deleted by hand, local and remote, and refs were pruned; no PR is open.

`make test` green on main: twenty-six suites, 674 expected passes, exit 0.

THE TRANSFER-ENCODING STATUSES DONE and merged: every parser error is a 400; a coding beside a final chunked is the core's own 501; and a request below HTTP/1.1 with Transfer-Encoding is refused, 400, as faulty framing. Each follows RFC 9112, decided on the owner's word by form. chez-httparse #50 landed in v0.4.2, and the pin stays at v0.4.1.

NEXT: M3.5, the staged close (plan §7): after a status the core originates is written, the core asks for `shutdown`, reads on and drops what arrives, and closes when the client closes or a linger deadline passes. Measure first, then settle the linger limit and its default by a decision record; finish with the plan's mutation, a close at once. On a fresh branch cut from main after this commit, when the owner asks. Then the M3 exit.


M3.5 — THE STAGED CLOSE (plan §7), in three stacked PRs. THE FIRST: THE DECISION, THE LIMIT AND THE FAKE SHELL'S SHUTDOWN. Branch feat/m3.5-linger-groundwork, cut from main at a01364e; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.

MEASURED first, over loopback, on Darwin arm64 and on Linux 6.12.76-linuxkit (Docker's `debian:trixie`). Four Python spikes did it; they are kept as `.plans/research/spike/staged-close-*.py`, with their outputs.
- M3.4'S MEASUREMENT WAS WRONG, and its entry above carries the correction. Its spike counted a client that read the 431 and then met a reset as one whose read failed. A reset does not erase what the client has received:
  - a client that sent 8 KiB or 64 KiB past a refusal read the 431 in 100 runs of 100 on both platforms, even when its first read came 50 ms after the reset;
  - after a 64 KiB head, curl (8.7.1 / 8.14.1), Python's http.client (3.14.5 / 3.13.5) and Node's fetch (20.10.0 / 20.19.2) each reported the 431 in 20 of 20 runs.
- What a reset does lose, in 20 runs per client per platform:
  - a 4 MiB upload refused (as M6's 413 will be) and closed at once: Python and Node read the status in 0 of 20 runs on both platforms, and reported a reset or a broken pipe instead; curl read it in 20 of 20. Closed in stages, all three read it in 20 of 20;
  - a handler's 4 MiB response with `Connection: close`, while a pipelined request sits unread (the core stops reading while a handler runs, decision 0004), closed at once: cut short in 8 of 20 runs on Darwin and 13 of 20 on Linux, with 56–99% read and then a reset or 3 s of nothing. The reset throws away what the server's kernel had not yet sent. Closed in stages, all of it in 20 of 20;
  - a pipelined request that arrives after the close, once the server has read everything: the response was read in every run. On Darwin, at 10 ms apart, a reset failed the read after it in 10 of 100 runs.
- How long a staged close lasts with a client that reads and then closes: on loopback, a median of 0.05–0.10 ms after a refusal, and 0.2–0.4 ms with a pipelined request unread. The client's close ends it, not a deadline.
- What others do, read on master:
  - nginx lingers when more input may come: an unread body, a header error, input already buffered, the socket readable, or pipelining. Its flag is cleared for a 400. It lingers up to 30 s (`lingering_time`), and 5 s between reads (`lingering_timeout`);
  - Apache httpd lingers on every close, up to 30 s (`MAX_SECS_TO_LINGER`) and 2 s between reads (`SECONDS_TO_LINGER`), and 2 s in all for a "short" linger;
  - Go shuts its write side and waits 500 ms without reading (`rstAvoidanceDelay`). It does so after a 431, or after a response whose request body was not all read;
  - Node does not linger.
- On main at a01364e, every close that followed a response was at once, when the last write completed:
  - after a status the core originates: the fourteen reasons of `(http-server decisions)`, and a parser error;
  - after a response the connection does not keep: `not-keep-alive`, `upgrade`, `handler-close`, and in M6 `close-delimited`.
  The closes with no response are at the client's end, on a read error, and at the idle deadline.
- Found in the spikes' first harness: on Linux, closing a listener does not wake a thread blocked in its `accept`. So an old server took the next case's connections and answered some with the other case's status. The harness now polls a stop flag, and every number above comes from the fixed harness.

DECIDED on the owner's word (2026-09-26), by form. The form had the tables above and two questions, each option with its rough size:
- EVERY CLOSE AFTER A RESPONSE LINGERS, the core's own statuses and a handler's close alike, as RFC 9112 §9.6 describes and Apache does. The closes with no response are at once. The alternatives weighed:
  - only after the core's own statuses, as M3.4 worded it: about 5 more core lines, and the truncation stays;
  - nginx's rule, the core's statuses and a response when the core already holds more input: about 15 more. It misses most of the truncations, since a pipelined request waits unseen in the kernel while reading is stopped.
- ONE LIMIT, 30 S. `linger-timeout-ms` is 30 000, from when the connection starts lingering, and can be overridden by `CHEZ_HTTP_LINGER_TIMEOUT` in whole seconds. It is nginx's `lingering_time` and Apache's total. A client that neither sends nor closes holds its connection up to 30 s, less than the 75 s an idle one already may. The alternatives weighed:
  - 5 s, one limit: the same code;
  - nginx's two limits, 30 s in all and 5 s between reads: about 100 more lines, since it needs two deadlines per connection.
Decision 0011 records both, and decision 0005's table gains the row as a dated amendment.

Read as the owner's choice, and flagged for the PR:
- the connection lingers in a tenth state, `lingering`. There the write side is shut, the connection reads and drops what arrives, and the linger deadline is armed once and never re-armed, so a client that keeps sending cannot extend it. It closes at the client's end, at the deadline, or on a read error;
- a state that reads stops reading when it refuses a request, and reads again when it lingers. Design §4.3's table says `responding` does not read, and M2 left it reading (M3.4's note). So an end the client sends while the status is written waits in the kernel for the linger, and no state has to remember it;
- the limit is a field of `(http-server limits)` now, as the other timeouts are, though only M5's wheel will read it: the core arms deadlines by kind;
- the close names the reason the connection closes after its response, whichever way the linger ends;
- the fake shell performs `shutdown`, reporting `shutdown-completed` on a later turn as uv_shutdown's callback will, and refuses a write after it. The core ignores `shutdown-completed`;
- the outcome lane delivers the client's end once its input is sent, as the libhtp lane does, so every fixture's linger ends, at every chunk size;
- the Python spikes are kept, with their outputs, as the decision's measurement: a recorded number that was once wrong should be one anyone can re-run.

REVIEWED before the first commit, at high effort (/code-review): six findings. On the owner's "fix all findings", all six are fixed, each premise checked first. Each fix goes up with the PR that carries its code:
- A lingering connection kept all the input it had read: the pause's pending input, the last delivery, the request, and the head's spans. So it pinned its deliveries for up to 30 s, where the close had released them at once. Measured with the retention suite's weak pointers, the delivery and the request were both held while the connection lingered. Clearing the core's four fields released both, so the parser, the adapter's context and the target judge hold neither. Entering `lingering` now forgets them, and the retention suite checks it (the third PR).
- The originated suite's header said the 408's row sends nothing while the connection lingers. Its drive sends a request to every row then, so the header now says so (the second PR).
- The originated and linger suites each had the same one-delivery `deliver!`, and the same walk to the actions from the core's response on. `(read-back)` now shares `send!` and `client-close!`, a client's two moves, delivered only while the connection reads, through `fake-shell-feed-input!`, and `from-response` (the second PR). The linger suite's keep-alive contrast now reads the third answer before its client closes, and so shows that close happen at once (the third PR).
- The message-loop's `serial?` knew no staged close. A closing response's `read-start` came with no resume, so the helper would call every closing input unserial. Checked: against the spike, at every delivery size, it answered #f. It now ends a response's handling at the shutdown, after which nothing may be fed, handled or resumed. A new check runs it over the spike (the second PR).
- A raise from the fake shell's write check left the shell's depth raised, so it never drained again. Checked: after a refused write, the next dispatch's shutdown never ran. A raise now abandons its dispatch: the depth is restored, a feed's inside it included, and the actions still queued are dropped (this PR).
- Plan §3 counted five duration variables in seconds; with the linger's there are six (this PR).

THE FIRST PR (feat/m3.5-linger-groundwork): what the staged close needs before the core changes.
- `(http-server limits)`: `linger-timeout-ms`, the thirteenth field, 30 000, read from `CHEZ_HTTP_LINGER_TIMEOUT` in whole seconds. Nothing reads it yet: the core will arm its kind, and M5's wheel turn the kind into an instant.
- `tests/fake-shell.sls`: `shutdown` is performed, `shutdown-completed` arrives on a later turn as uv_shutdown's callback will, and a write after it is an assertion violation. A raise from an action abandons its dispatch (review).
- Tests: the limits suite checks the default, the override and the variable. The fake shell's suite checks that a write after the shutdown is refused, and that the shell dispatches again after it. The head suite and the trace lane build limits with the new field.
- Docs and records:
  - decision 0011, new, and decision 0005's amendment;
  - plan §3's amendment, and its count of the duration variables in seconds;
  - design §4.3's correction of M3.4's note, and the correction in M3.4's entry above;
  - the research README, and the four spikes with their outputs.
- Red before green: the limits suite could not load before the field existed, and the fake shell's recovery check failed against the drain that left its depth raised. The write-after-shutdown check is the harness's own, and SN is its red.
- Mutations (m3-mutations.md, "M3.5, first PR"): SL, SM, SN, RE and RF, run on this tree, all killed.
- `make test` green: twenty-six suites, 679 expected passes (limits 28, fake-shell 18), exit 0. `make check-imports` is clean. Allocation: 2,736 B per request, unchanged.
- 85 inserted lines of code and tests. The slice came to 615 after the review (484 before), over plan §1 rule 1's ~400, so it goes up as three stacked PRs, each green on its own: this one; the staged close, 318; and the linger suite with the input a lingering connection forgets, 212.

NEXT: the second PR, the staged close, stacked on this one.


M3.5, THE SECOND OF THREE STACKED PRS: THE STAGED CLOSE. Branch feat/m3.5-staged-close, stacked on feat/m3.5-linger-groundwork; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Measured, decided and reviewed as the first PR's entry records. Mutation log: m3-mutations.md.
- `(http-server connection)`:
  - `lingering` is the tenth state. From `responding`, the last `write-completed` with a close-after enters it, asking for `(shutdown) (read-start) (arm-deadline linger)`;
  - in it, `bytes-arrived` asks for nothing. `eof`, and a `tick` past the linger deadline, close for the close-after reason, and `read-error` logs and closes;
  - `respond` adds `(read-stop)` after the write when it leaves `head` or `body`.
- `tests/read-back.sls`: `send!`, `client-close!` and `from-response`, which the originated suite and the third PR's linger suite share (review).
- Tests:
  - the table:
    - H10 and W3 linger, and there are four `lingering` rows, L1 to L4, and T2's lingering instance;
    - the refusals from `head` or `body` stop reading: T3 three times, T4, U2, and W1's 408;
    - the closed set is ten states;
  - the originated suite follows each status's close to its end. A request sent while lingering is dropped, and each refusal stops reading;
  - in the head, response, message-loop and retention suites, a close after a response ends in `lingering`, since no client closes there. The message-loop's two "never delivered" checks now say that the bytes after the last message are read only while lingering, and never fed. Its `serial?` ends a closing response's handling at the shutdown, and a new check runs it over the spike (review);
  - the outcome lane delivers the client's end if the connection still reads, as the libhtp lane does. The libhtp lane's comment now says that the eof ends the 1.0 streams' linger.
- Docs and records:
  - design §4.3's tenth state and its amendment, and §4.4's amendment;
  - plan §8's correction for M4.2, and §9's note for M5;
  - docs/connections.org gains "How the server closes a connection", and docs/configuration.org the variable.
- Red before green: against the first PR's core, which is main's, 78 checks failed in six suites, and the table suite ended in a harness error:
  - connection-head 37;
  - connection-originated 16;
  - connection-response 13;
  - message-loop 8;
  - connection-table 3 (ten states, H10 twice), then the harness error: the synthetic `lingering` state was refused, so the rows after T2 never ran;
  - connection-retention 1.
  The spike's `serial?` check held there, since a close at once never reads again; its red was the helper's, in the review.
- Mutations (m3-mutations.md, "M3.5, second PR"): SA to SK, SO and RD, run on this tree, all killed.
  - SA is the plan's: a close at once turns the red's 78 checks red again, in the same six suites.
  - SB lingers only after the core's own statuses.
  - SC to SG each drop a part of the linger: the read-start, the shutdown, the single arming of its deadline, the close at the client's end, and the close at the deadline.
  - SH lingers after the idle deadline, a close with no response.
  - SI and SJ move the read-stop, and SK names the wrong reason.
  - SO ignores a read error while lingering, and RD feeds what arrives while lingering.
- `make test` green: twenty-six suites, 688 expected passes (connection-table 103, message-loop 19, connection-originated 20), exit 0. `make check-imports` is clean. Allocation: 2,736 B per request, unchanged.
- 318 inserted lines of code and tests.

NEXT: the third PR, the linger suite and the input a lingering connection forgets, stacked on this one.


M3.5, THE THIRD OF THREE STACKED PRS: THE LINGER SUITE, AND THE INPUT A LINGERING CONNECTION FORGETS. Branch feat/m3.5-linger-suite, stacked on feat/m3.5-staged-close; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md.
- `(http-server connection)`: entering `lingering` forgets the input: the pause's pending input, the last delivery, the request and the head (review).
- Tests:
  - `tests/test-connection-linger.sps`, new, with 9 checks:
    - four closes, each answered with a request pipelined behind it and then closed in stages until the client closes: a request's `Connection: close`, HTTP/1.0, a handler's `Connection: close`, and an upgrade;
    - a connection kept alive, as the contrast: its client's close is at once;
    - a linger ended by its deadline, by its deadline with the client still sending, and by a read error, and one that the half-close's completion leaves lingering;
  - the retention suite checks that a lingering connection holds neither the delivery nor the request (review).
- Records: plan §7's note for M3.5.
- Red before green:
  - against main's core, the linger suite failed 8 of its 9 checks; the keep-alive contrast held. The retention suite failed 3: the second PR's lingering 500, and both new checks;
  - against the second PR's core, the linger suite passes, since it checks what that PR landed. The retention check failed: the delivery and the request were both held.
- Mutations (m3-mutations.md, "M3.5, third PR"): RA to RC, run on this tree, all killed; and the second PR's mutants, run on this tree against its two suites.
- `make test` green: twenty-seven suites, 699 expected passes (connection-linger 9, connection-retention 10), exit 0. `make check-imports` is clean. Allocation: 2,736 B per request, unchanged.
- 212 inserted lines of code and tests.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the M3 exit (plan §7): the brief's gate checked on the merged tree (the table tests, the corpus lane, and the chunked-to-1.0 mutation, M3.2-A), the serializer's segment count (M3.1-A), and the allocation gate re-measured with the response path in the loop; then M3's close-out.

MERGED to main on 2026-09-26, bottom up, on the owner's "do closing ritual":
- #41, the first PR, as 4524622. Its squash tree (ff349d0) is identical to the tested tip's, f4c0f1d. It merged without deleting its branch, so that #42 stayed open on it.
- #42, the second, as f2cf35b. It was retargeted to main and rebased from f4c0f1d (6a9b687 -> bd31f6b, tree 31e7d4a unchanged, proved), then force-pushed with the lease read from the remote. Its squash tree is identical to bd31f6b's. It too merged without deleting its branch, so that #43 stayed open on it.
- #43, the third, as 8a524ba. It was retargeted to main and rebased from 6a9b687 (a7a8c8f -> 7ff4380, tree 951fe11 unchanged, proved), then force-pushed the same way. Its squash tree is identical to 7ff4380's.
- Every run was the billing block, zero steps: 36252934217 (#41), 36252953317 and 36253465031 (#42, and its rebased tip), and 36252970328 and 36253509524 (#43, and its rebased tip).
- `gh pr merge --delete-branch` switched this checkout to main at 8a524ba and deleted #43's branch. #41's and #42's were deleted by hand, local and remote, and refs were pruned; no PR is open.

`make test` green on main: twenty-seven suites, 699 expected passes, exit 0.

M3.5 DONE and merged: every close after a response is staged. The core half-closes, lingers, reading and dropping what arrives, and closes when the client does, when a read fails, or after 30 s; a lingering connection keeps none of its input. Decided on the owner's word by form (decision 0011). M3.4's reset measurement is corrected: a reset does not erase what the client has received, but it fails a client's send before it reads the status, and it throws away what of a response the kernel has not yet sent.

NEXT: the M3 exit (plan §7): the brief's gate checked on the merged tree (the table tests, the corpus lane, and the chunked-to-1.0 mutation, M3.2-A), the serializer's segment count (M3.1-A), and the allocation gate re-measured with the response path in the loop; then M3's close-out. On a fresh branch cut from main after this commit, when the owner asks. The staged close's shell half is M4.2's, and its socket test M4.4's.

M3 EXIT, FIRST PART: the brief's gate on M3's merged tree, a finding in byte-machine, and the pin that carries its fix. 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. The exit's work began on feat/m3-exit, cut from main at 160d638; the pin goes up first, on its own branch, and the exit's checks are stacked on it (the second part, next).

MEASURED first, on main at 160d638:
- **The table tests:** `make test` green, twenty-seven suites, 699 expected passes, exit 0.
- **The corpus lanes:** green under `CORPUS=full`. The trace and outcome lanes each ran 9,394 runs at 'full, and the ratchet holds trace 135, outcome 135 and libhtp 12 passing.
- **The brief's mutation and the plan's**, re-run against all twenty-seven suites:
  - M3.2-A, chunked to a 1.0 client, turns 4 of the decisions suite's checks red and nothing else. The core frames no body of unknown length before M6.
  - M3.1-A, the segments joined, turns 7 serializer checks red, the segment counts, and 2 of the connection table's, H7 and W1.
- **Allocation, with the response path in the loop:** 2,736 B per request, which is 224 B more than the M2 exit's 2,512 B. Other responses:
  - a 200 with `Content-Type` and a 13-byte body, 2,784 B;
  - a 100-byte or a 999-byte body, 2,752 B either way;
  - a 64 KiB body, 2,768 B, since its Content-Length is two digits longer;
  - a reason given, 2,768 B, since the line is built;
  - a 500-byte field from the handler, 3,248 B, since it is copied once into the header block.
- **Two shapes unchecked.** A body copied into its segment (X-BC) and a status line built per response (X-SL) each passed all twenty-seven suites.
- **FOUND: the fields the parser reads by name.** byte-machine's `byte-machine-keyword-step/v1` (runtime.sls:885, v0.6.0) copied the prefix it had matched on every byte. Five of chez-httparse's states use it: the methods, the protocols, the five header names llhttp reads, `chunked`, and the `Connection` tokens.
  - The parser alone cost 1,600 B on the gate's GET. One more field added:
    - an ordinary one, 112 B;
    - `Connection: keep-alive`, 2,944 B;
    - `Content-Length: 0`, 2,480 B;
    - `Transfer-Encoding: chunked`, 4,384 B;
    - even `Content-Type`, 1,072 B, since its name starts like `content-length`.
  - The cost grew with the square of the match. A 17-byte name matching k bytes of `Transfer-Encoding` added 112 B at k=0, 1,072 B at k=8 and 3,056 B at k=16.
  - The worst case: 97 near-miss names in a 2,162-byte request allocated 297,767 B.
  - Through the core, answering an empty 200: curl's GET 2,736 B, a browser-like GET with `Connection: keep-alive` 8,144 B, a JSON POST 6,800 B, and `ab -k` 5,824 B. `research/spike/m3-exit-keyword-alloc.sps` records these, two identical runs.
- **A patch that reads the prefix in place,** tried from a scratch copy first on the library path. It stays inside the `/v1` contract, so the parser needs no regeneration.
  - Each keyword table then costs a flat 64 B.
  - The four requests cost 1,840, 3,312, 2,384 and 2,112 B, and the worst case 6,784 B.
  - With it, every one of our suites passes at 'full, and chez-httparse's own `make test` passes 93 of 93. byte-machine's passes 157 of 158. Its mutation lane refuses the one mutation whose anchor the patch rewrites, `(= (length (car (car es))) (length p))`. Re-anchored to the patch's `(= (length (car (car es))) n)`, that mutation is caught, and the lane passes: every mutation accounted for, exit 0.

DECIDED on the owner's word (2026-09-26), by form. The first answer was the recommended one, the second was not:
- **Filing: I file it.** byte-machine #139 was filed the same day, with the numbers, the growth, the worst case and the patch. Weighed: the owner files it from a draft; or it is recorded only.
- **M3 is held for the fix.** M3 closes only after byte-machine's fix, a chez-httparse release that vendors it, and the pin move; the requests a server meets then join the gate. Weighed:
  - record it and close M3 now, the gate staying on the spike's GET (recommended);
  - print the four requests on every run, with no gate.

LANDED the same day. byte-machine v0.6.1 (5c1cb7e; PR #140, 799870b; release PR #142; its decision 0054) fixes #139 with a walk of its own: one pass over the entries finds the longest prefix any keyword shares with the input, compared in place. It re-anchors the mutation, and its allocation audit holds the shape. chez-httparse v0.4.3 (bdcdfe2; PR #53, release PR #54) vendors it and holds the same shape in its allocation lane.

MEASURED at the new pin, before moving it:
- **Our suites:** with `vendor/chez-httparse` checked out at v0.4.3, and its byte-machine at v0.6.1, every suite passes at 'full. The one exception was a probe written during the exit's work, a check that a name still cost more the more of a keyword it matched. It failed as it was built to: a name matching 1 byte of a keyword and one matching 16 both cost 2,016 B. The probe never lands; the exit's second part carries it turned round.
- **The spike:** the numbers are the patch's, exactly. The gate's GET costs 1,840 B, down from 2,736 B.
- **`make check-pins` refuses the move alone.** With both pins set to the new commits, it answered `PIN MISMATCH: vendor/uriparse was released with byte-machine 0245db3…, the library path carries 5c1cb7e…` (exit 2). The check holds uriparse to the byte-machine on the library path (PR #18).
- **uriparse runs no changed code.** It calls eight of byte-machine's runtime procedures, and none of them changed. uriparse v0.6.0's own `make test`, with byte-machine v0.6.1 in its vendor directory, passed 77 of 77.

DECIDED on the owner's word (2026-09-26), by form, the recommended answer: **uriparse cuts v0.6.1**, a release that moves its byte-machine to v0.6.1, as chez-httparse v0.4.3 did. One commit then moves byte-machine through both of its carriers, and the check stays as it is. Weighed: an exception recorded now, holding uriparse to its own release's byte-machine until it re-released. uriparse tagged v0.6.1 (88d538f; PR #27) the same day.

THE PIN MOVES, on one commit: chez-httparse v0.4.1 to v0.4.3, and uriparse v0.6.0 to v0.6.1, so byte-machine moves from v0.6.0 to v0.6.1 through both. Updated:
- the two gitlinks, and the Makefile's `HTTPARSE_PIN`, `URIPARSE_PIN` and `BYTE_MACHINE_PIN`;
- global-constraints, which now says byte-machine is one pin with two carriers;
- decision 0008: #139's row, and its two dated bullets;
- the research README, and the spike's runs at the new pin;
- the version comments in test-integration and test-corpus-inventory.

Byte identity between the tags:
- chez-httparse: `src/generated/` and the corpus under `test/vendor/` are byte-identical. On the library path, `src/httparse/grammar.sls` changed only in comments, and the harness's `drive.sls` shares its feeding loop, which it names `drive-run`, and exports `drive-result`. Nothing we import is renamed.
- byte-machine: under `src/` only `runtime.sls` changed, and in it only the keyword walk.
- uriparse: `src/`, `tools/` and `test/` are byte-identical. Only the version strings, the changelog, its ledger and the byte-machine gitlink moved.

`make test`: twenty-seven suites, 699 expected passes, exit 0. The allocation suite's gate reads 1,840 B.

NEXT: the M3 exit's second part, stacked on the pin.

M3 EXIT, SECOND PART: the checks, and the gate over requests a server meets. Stacked on the pin; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`. Mutation log: m3-mutations.md, "The M3 exit".

At the new pin, the gate's GET costs 1,840 B, and curl's GET 1,840 B, a JSON POST 2,384 B, `ab -k` 2,112 B, and a browser-like GET 3,312 B. The browser's is over the 3,072 B ratchet because it carries eleven fields to the gate GET's three. Each of the eight more costs 176 B, the parser's 64 B and the core's 112 B, and its `Connection` value costs 64 B for the keyword table it is read through, which makes the 1,472 B.

DECIDED on the owner's word (2026-09-26), by form, the recommended answer: **three requests a server meets join the gate**, each held to 3,072 B: curl's GET, the JSON POST, and `ab -k`'s. The browser's GET is printed on every run, not gated. Weighed:
- all four under a 4 KiB gate, set as decision 0002 set the first: the largest measured cost rounded up to the next KiB;
- all four under 3 KiB, with M3 staying open until each field costs less.

BUILT:
- `tests/test-serializer.sps`: every status line in the table is made once, and shared.
- `tests/test-connection-allocation.sps`:
  - a 999-byte body costs what a 100-byte one does;
  - a 17-byte field name costs the same however much of a keyword it matches, which was to have been the probe;
  - the JSON POST and `ab -k`'s GET, each within the ratchet, with curl's GET and the browser's printed;
  - the harness answers a given response.
- Records:
  - decision 0002's note: the response path fits, the finding, and the gate over requests a server meets;
  - plan §7's M3 exit note and §12's risk row;
  - the mutation log.

Watched to fail (m3-mutations.md):
- X-SL, a status line built per response, and X-BC, a body copied, each turn only their own check red. Before these checks they passed every suite.
- The old pin, byte-machine v0.6.0's `runtime.sls` first on the path, turns three checks red: the name check, the JSON POST and `ab -k`.
- X-GATE, 1,400 bytes more per response, turns the gate and both requests red.
- M3.2-A and M3.1-A re-run on the final tree as before. M3.1-A now also turns the body check red, since joining copies the body.

Read as the owner's choice, and flagged:
- **The two response shapes and the name shape.** "Prefer a check to a comment."
- **The requests, written from what each client sends:** curl 8.7.1, ApacheBench 2.3 under -k, and a Chromium browser.

Found in review (2026-09-26), and fixed on the owner's word ("fix all findings except the filed issues"):
- **curl's GET is printed, not gated.** It has the CPS workload's shape, the same three fields, so its check duplicated the ratchet's: every mutant moved the two together.
- **The browser's GET carries eleven fields, not twelve.** Its cost is now stated exactly, not as about 176 B a field.
- **The first part's records.** The spike's header named the wrong rows as gated, and the first part's entry cited the probe as though it had landed. Both are corrected in the first part, and the spike's runs were made again at both pins: the old pin was checked out for its two, and the new one restored after.
- **Left as filed:** byte-machine #139 still says twelve fields.

`make test` green: twenty-seven suites, 706 expected passes (serializer 147, connection-allocation 18), exit 0. `make check-imports` is clean.

NEXT: the two stacked PRs, on the owner's word. At the merge, M3 is complete. Then M4, the libuv shell and the first real server (plan §8).

MERGED to main on 2026-09-26, bottom up, on the owner's "do closing ritual":
- **#44, the pin,** as 8e2c7df, without deleting its branch. The squash tree (e3f1cba) is identical to the tested tip's, 2a38240.
- **#45, the exit.** Retargeted to main, then rebased from 2a38240 onto 8e2c7df as 06dfcb0, its tree unchanged (009bdd4, the tested ecf72cb's). It was force-pushed with the lease read from `ls-remote`, and merged as 4b65a98, whose tree is 009bdd4 too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36264311371, 36264322200 and 36264535045.
- **Branches.** Both are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: twenty-seven suites, 706 expected passes, exit 0.

M3 COMPLETE and merged (4b65a98, PR #45): the response path. It took fifteen PRs, #31 to #45, merged on 2026-09-25 and 2026-09-26. Among them, #33 is the ratchet's libhtp fix, #39 and #40 the Transfer-Encoding statuses, and #44 the pin carrying byte-machine #139's fix. The exit criteria are met on main:
- the table tests pass, and the corpus lanes hold at 'full (9,394 runs). The ratchet stands at trace 135, outcome 135 and libhtp 12 passing, unchanged since the M2 exit;
- the brief's mutation, chunked to a 1.0 client, turns the decision's 1.0 rows red, and the serializer's segment count is asserted (M3.1-A);
- with the response path in the loop, the allocation gate reads 1,840 B per request, against the 3,072 B ratchet. A JSON POST (2,384 B) and `ab -k`'s GET (2,112 B) are gated beside it;
- m3-mutations.md is complete, and `make check-imports` is clean.

The suite count went from M2's twenty-one to twenty-seven, adding connection-linger, connection-originated, connection-response, connection-retention, serializer and transfer-coding.

NEXT: M4, the libuv shell and the first real server (plan §8):
- M4.1, the adapter, and the closures the shell owns;
- M4.2, the shell: close ownership, the depth counter, and the staged close's shell half (`uv_shutdown`, reading on until the core closes);
- then M4.3 and M4.4, with the socket lane's staged-close test.

It starts on a fresh branch cut from main after this commit, when the owner asks.

M4 — THE LIBUV SHELL AND THE FIRST REAL SERVER (plan §8). Branch feat/m4-libuv-shell, cut from main at 76d5a13; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m4-mutations.md, new.

Gathered before the first test, from plan §8 and this ledger:
- plan §8's four slices:
  - M4.1, the adapter's check;
  - M4.2, the shell: close ownership, the depth counter, the two hazards, and two checks carried in: M3.3's retention check, and the staged close's shell half;
  - M4.3, the listener and `server-step`, with `max-connections` and `backlog` (plan §3);
  - M4.4, the contract test and the socket lane, with the upload past a refusal (decision 0011);
- the exit:
  - curl and ab get correct responses, and the counters return to zero;
  - the contract test passes;
  - the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop;
  - the per-connection budget is re-measured;
  - and the amendment slicing M5–M8 is written (plan §10);
- left to M4 by earlier slices:
  - what handlers see (M2.2);
  - absolute-form's host (RFC 9112 §3.2.2), an empty Host on origin-form, and whether to serve `ftp:///x` (M2.3);
  - a facade that builds limits must refuse a pipeline cap other than 1 (M2.4);
  - how the shell reports a cancelled write (M3.3);
  - a tracing hook (M2.2, from 0002's third amendment).

Found: no slice holds the facade, `(http-server)` (decision 0001's layout), and the exit needs it, since curl and ab need a server to run. It is M4.5, re-planned here (brief risk 6), after M4.4. What handlers see and the host rules land with it. Two of its questions are the owner's, measured first (below).

MEASURED, for what handlers see: `research/spike/m4-handler-view.sps`, new (`out/m4-handler-view.run{1,2}.txt`, identical, exit 0). It measures the bytes a view adds per request, on top of parser, adapter and core. Three views:
- (A), the spans read through accessors that copy what is asked: the path and one header's value;
- (B), every request copied to strings before the handler runs;
- (C), the spans alone.

| request | (A) | (B) | (C) |
|---|---|---|---|
| curl's GET, 3 fields | 80 | 416 | 0 |
| a JSON POST, 5 fields | 96 | 720 | 0 |
| a browser's GET, 11 fields | 192 | 1,872 | 0 |

The JSON POST costs 2,384 B through the core (the M3 exit), so (B) would put it at 3,104 B, over the 3,072 B ratchet it is gated at.

DECIDED on the owner's word (2026-09-26), by form, the recommended answers; recorded as decision 0012:
- **A handler reads the request through accessors that copy what it asks for**: the path, the query, a header's value and the host, as strings, and the method as llhttp's symbol. The host follows RFC 9112 §3.2.2: an absolute-form target's authority, whatever Host says.
- **The server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say**, defaulting to 127.0.0.1 and 8080.

The alternatives weighed:
- for the view: every request copied to strings first, or the spans alone;
- for the address: the same variables defaulting to 0.0.0.0, or the platforms' `PORT` beside `CHEZ_HTTP_HOST`.

Read as the owner's choice, and flagged: an empty Host on origin-form is served, and reads empty, since v1 has no configured default (RFC 9112 §3.3 allows either). A target of another scheme, such as `ftp:`, is the handler's routing.

M4.1 — A CONNECTION'S PARSER SHARES ONE BINDING LIST. The adapter came in M2.2, so M4.1 is its check.
- `tests/test-connection-allocation.sps`: "a connection's parser costs what one on a binding list made once does". Byte-machine's `make-parser` is measured on a list of twenty-five bindings made once, before either is measured, beside `make-conn-parser`: 1,056 B each. Design §7.5 had 1,072 B, at the pins of 2026-09-19.
- Watched to fail (m4-mutations.md): M4.1-A, the plan's mutation, builds the list per connection. It turns only that check red: 2,640 B against 1,056 B, so a list per connection costs 1,584 B more. §7.5's 1,216 B was a plain list, and the adapter's bindings are closures.
- The tracing hook is the shell's, not the adapter's. Parser callbacks reach the core directly, and the actions they queue are traced where the shell runs them, which is what M4.4's contract test compares. No consumer needs the parser events themselves.

M4.2 FIRST STEP — THE SHELL SERVES A CONNECTION.
- `src/http-server/private/shell.sls`, `(http-server private shell)`, new:
  - a shell holds what a loop's connections share: the handler, the limits, the clock, the Date line, the log, an optional trace, and the connection table;
  - `shell-adopt!` serves an accepted TCP handle: the core in idle, a parser of its own, Nagle's algorithm off, and reading started with the limits' buffer;
  - the message loop is the fake shell's: one queue, drained after the outermost dispatch, with the depth counter around `parser-feed!` and the drain, and an action run anywhere else recorded as a violation.
- The actions, as the shell performs them:
  - `write` is one `uv-write*!`, its Date slot filled. Its completion keeps the write's byte count and nothing else;
  - `shutdown` is `uv-shutdown!`, reporting `shutdown-completed`;
  - `read-stop` and `read-start` change reading only when it is not already what they ask. The first start fixes the buffer at the limits' size;
  - `close` is `connection-close!`, the one `uv-close!` call. The handle's close takes the connection out of the table and reports `closed`;
  - a handler's raise is logged and delivered as `handler-failed`;
  - deadlines are recorded and not acted on: the wheel is M5's.
- The Date is made once a second (decision 0010). The shell's clock, milliseconds since the epoch, is read when a second of the loop's own time has passed. That time is libuv's cached `uv-now`, which costs nothing to read, where the wall clock costs 48 B a reading (measured 2026-09-26). Between readings the second is the last reading plus the loop's time since.
- `tests/test-shell.sps`, new, in chez-libuv's `test-echo.sps` shape (design §8.5):
  - clients on the same loop, and a listener of the suite's own on 127.0.0.1:0, made inside the suite so a failure there is the harness's status 2;
  - every wait capped by an iteration count;
  - responses read back by chez-httparse's response parser, and the Date from RFC 9110 §5.6.7's example instant.
- What it checks:
  - a GET is answered, dated by the shell's clock, and the connection stays open;
  - three requests in one write are answered in order, reading the clock fewer times than they are answered, with no action run from anywhere but the outermost drain (design §6.4's second hazard, against the real shell);
  - the staged close's shell half: the client reads the response, then the stream's end; the connection lingers, reading, while the client holds its end open; it closes and leaves the table when the client closes; its verbs run write, shutdown, read-start, close;
  - a handler that raises is answered 500, and what it raised is logged;
  - M3.3's retention check against the real write executor. The client does not read a four-MiB response, and the connection's send buffer is asked to be small, so the write stays outstanding: chez-libuv's write-queue gauge says so before the collection. Then nothing holds the response's body;
  - at the end, every connection accepted and closed, no handle on the loop, and, where chez-libuv's dev counters are on, no TCP handle, read buffer or write request.
- `tests/test-exports.sps`, new: no library outside `private/` exports a `uv-` name, read by Chez's own `library-exports` (design §7.6, decision 0003). The facade joins its list once `src/http-server.sls` exists.
- `make check-close-ownership`, new, a prerequisite of `make test`:
  - it names every uncommented use of the name `uv-close!` in `src/` (a call, an alias, an argument to `apply`) with the definition it sits in;
  - it requires exactly one use, in `connection-close!`;
  - it needs ripgrep, which CI now installs, and without it fails by name.
- The library path gains chez-libuv's `tests/`, test-only, for `(uv-testing)`: its iteration-capped waits and loopback plumbing, used rather than copied.
- `make check-imports` now also refuses a test library, `(uv-testing)` or `(httparse test ...)`, anywhere under `src/`. Its note has said since M1.1 that it kept the harness out of shipped libraries, and until now it did not.
- Red before green: the shell suite stopped at load before the shell existed (exit 255, library not found).
- Watched to fail (m4-mutations.md):
  - M4.2-H, the queue drained inside the parser callback: the violation check, and the pipelined answers with it;
  - M4.2-R, the completion keeping the segments: the retention check alone;
  - M4.2-S, no half-close: the stream's-end checks;
  - M4.2-L, no reading while lingering: the close and everything after it;
  - M4.2-T, the table not updated at the close: its check;
  - M4.2-D, the Date one second off: its check;
  - M4.2-K, the clock read for every response: its check;
  - M4.2-G, a handler's raise not logged: its check;
  - M4.2-E, a `uv-` export: the export check, every other suite green;
  - B1–B5, the plan's Mutation B and four more: a second `uv-close!` caller, a second call, the call moved into a helper, an alias, and `apply`. Each turns the gate red, naming each use. With B1 the suites stay green, so the gate is the test.
- Survives, a scope statement (M4.2-N): Nagle's algorithm left on. chez-libuv has no getter for `TCP_NODELAY`, and what it changes is time on a link with a round trip. On loopback no stall shows either way (`research/spike/m4-nodelay.sps` on Darwin, `m4-nodelay.pl` in Docker's Linux; both twice).
- Found and fixed: the Makefile's header still named the old pins (chez-httparse v0.4.1, uriparse v0.6.0, byte-machine v0.6.0), which #44 moved without it. It now points at the `*_PIN` lines.
- A review before the first commit found fourteen things, all fixed on the owner's word. Its record is with the second step, since its fixes fall in both.
- Every suite green in a scratch worktree with only this step, cut from main at 76d5a13: twenty-nine suites, 736 expected passes (connection-allocation 19, shell 27, exports 2), each exit 0. `make check-imports` and `make check-close-ownership` are clean there, and the step's mutants ran there (m4-mutations.md).

NEXT: the second step, what fails, stacked on this one.

M4.2 SECOND STEP — WHAT FAILS: THE TRANSPORT, A BUG, A POISONED PARSER (design §6.3, §6.4's first hazard; decision 0003 item 4).
- Transport failures:
  - a failed read, write or shutdown is a `read-error` (design §6.3), whether chez-libuv raises it at the call or reports it at the completion;
  - a failed write is also settled as `write-completed`, after the close, as the core settles a write a close cut short;
  - so a write the close itself cancels is reported the same way. That is how the shell reports a cancelled write (M3.3's question).
- A bug closes its connection. Whatever raises out of a connection's outermost dispatch drops the actions still queued, and one of them may have been the close, or the read that would have seen the client go. So the connection is closed before the raise goes on to chez-libuv and the run loop. An adoption whose read cannot start is closed the same way.
- `shell-run!`: one `uv-run` under a guard.
  - A `&byte-machine-contract` is a bug that has poisoned a parser: logged, the table reconciled, and raised again.
  - Any other callback's error is logged, the table reconciled, and the loop runs on.
  - The run loop logs quietly: a log that raises there cannot take the failure's place.
  - `reconcile!` drops a connection whose handle the loop no longer has. The other direction, a live handle the table does not know, needs the server's listener, M4.3.
- `tests/test-shell.sps` checks:
  - a write that fails at its completion closes the connection as a read error, then is settled, with no half-close. The client goes while four MiB are being written to it;
  - so does a write libuv refuses at the call. The suite shuts the connection's write side behind the shell's back, and libuv 1.52.1 then refuses the write with EPIPE (measured first);
  - a real contract condition, provoked: a parser whose on-message-begin feeds it again gives `reentrancy`, and a timer's callback raises it. The run loop raises it again, having logged it first, and still does when the log raises. After an ordinary condition it runs on, having logged it;
  - a connection whose callback raises is closed, its client reading the stream's end, and so is one whose adoption fails;
  - a connection whose handle was closed behind the shell's back stays in the table until the run loop reconciles it.
- Found, and recorded in plan §8 and design §6.4: the plan's Mutation A expected a guard narrowed to `error?` to let a contract condition escape uncaught. It cannot. chez-libuv raises a callback's error again composed with `&uv-callback-error`, an `&error`, so both arms match, and what keeps it fatal is the contract arm's place first.
- Watched to fail (m4-mutations.md):
  - M4.2-A, the plan's, one `error?` arm, and M4.2-A2, the arms swapped: the loop runs on, logging a callback error;
  - M4.2-X, M4.2-J, M4.2-C, M4.2-Q and M4.2-W1 to W3: each puts back the code as it was before the review's fix, and turns that fix's check red.
- Survives, a scope statement (M4.2-F1): a shutdown's failed completion reported as success. `shutdown(2)` fails only if the client resets in the one poll between the write's completion and the shutdown, which a test on one loop cannot order. A lingering connection reads, so a reset still closes it through the read's error.

Found in review (2026-09-26, `/code-review xhigh`), and fixed on the owner's word ("fix all findings"). Each premise was checked first:
- **A shutdown's failed completion was dropped**, though the shell's note called it a read error. It is one now. The review said the connection would linger forever; a lingering connection reads, so a reset closes it anyway. What was wrong was the note.
- **A connection whose callback raised was abandoned**, its queued close or read dropped, and never closed. Now it is closed before the raise goes on.
- **A failed adoption left the handle open** and in the table. Now it is closed.
- **Nagle's algorithm was on.** The review said pipelined responses would wait for delayed acknowledgements. Measured on loopback, on Darwin and on Linux, nothing waits, with or without it. The shell turns it off anyway: the mechanism needs a round trip, which loopback does not have, and by default Go's net package turns it off for every TCP connection, and nginx for keep-alive ones. A scope statement, as above.
- **The failure paths had no test**: a write failing at either end, a handler's raise. Now they have.
- **The gate matched only calls**, so an alias or `apply` got past it. Now it matches the name.
- **The gate hung without ripgrep**, awk reading standard input. Now it fails by name, exit 2.
- **"The listener is listening" could not fail**: it ran before any connection. Now it runs at the end.
- **The suites' setup ran outside `run-suite`**, so a failed bind exited 255, not the harness's 2. Both suites moved theirs in.
- **`reconcile!` was quadratic** in the connections. Now it looks each one up in a table of the live handles, and has a check of its own.
- **Each response read the wall clock**, 48 B a reading. Now the loop's time, which costs nothing, decides when a second has passed.
- **A log that raised in the run loop took the failure's place.** Now the run loop logs quietly.
- **The trace hook hands over the actions themselves**, so a trace that keeps them keeps a response's body. `make-shell`'s note now says so.
- **The Makefile's note said the test-only check covers `src/http-server/`.** It covers all of `src/`.

`make test` green: twenty-nine suites, 757 expected passes (connection-allocation 19, shell 48, exports 2), exit 0. `make check-imports` and `make check-close-ownership` are clean.

NEXT: two stacked PRs, on the owner's word ("commit and open the PRs"). M4.1 and M4.2 are 1,017 inserted lines of code and tests (1,058 with the Makefile and CI), two and a half times plan §1 rule 1's ~400, so each step goes up on its own: feat/m4-libuv-shell (M4.1 and the first step, 716 lines), then feat/m4.2-failures, cut from it (the second, 332 inserted and 31 deleted). The shell and the exchanges it is checked by do not divide further. Then M4.3, the listener and `server-step`.

MERGED to main on 2026-09-26, bottom up, on the owner's "do closing ritual":
- **#46, M4.1 and the first step,** as 29c5c32, without deleting its branch. The squash tree (850c147) is identical to the tested tip's, 6e77155.
- **#47, the second step.** Retargeted to main, then rebased from 6e77155 onto 29c5c32 as 705e532, its tree unchanged (b9d3acb, the tested e5f3a18's). It was force-pushed with the lease read from `ls-remote`, and merged as 48d5ab9, whose tree is b9d3acb too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36269743318, 36269759615 and 36269874088.
- **Branches.** Both are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: twenty-nine suites, 757 expected passes, exit 0.

M4.1 and M4.2 DONE and merged:
- a connection's parser shares the adapter's one binding list, and a check holds it;
- the direct libuv shell serves connections: the message loop with its depth counter, the executors, `connection-close!` as the one `uv-close!` call (gated in `make test`), the staged close's shell half, and a Date made once a second;
- what fails is handled: a transport's failure is a read error, a bug closes its connection, and the run loop stops on a poisoned parser and runs on after any other callback's error;
- decision 0012 settled M4.5's two questions, by form.

NEXT: M4.3, the listener and `server-step` (plan §8):
- `server-step`, pure, with design §4.6's events and actions: `accept`, `refuse` over `max-connections`, `close-listener`, `force-close-all`, `log`;
- `max-connections` (10,000) and `backlog` (511) arrive as limits, each with its four things (plan §3);
- the shell's listener, and the reconciliation's other direction: a live handle the table does not know.

Then M4.4, the contract test and the socket lane, with the upload past a refusal; M4.5, the facade (decision 0012); and the M4 exit. It starts on a fresh branch cut from main after this commit, when the owner asks.

M4.3 — THE LISTENER AND `server-step` (plan §8; design §4.6). Branch feat/m4.3-listener, cut from main at 100ae8b; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

CHECKED first, in libuv 1.52.1's source (chez-libuv vendors it):
- libuv takes a connection off the socket before it calls the listener's callback, and stops watching the listener until the callback accepts it (`src/unix/stream.c:507-531`). So a connection the server will not serve is accepted and closed at once. That is how nginx refuses one its `worker_connections` cannot hold, and what decision 0005's "refuse in on-connection" comes to; one left unaccepted would stop the listener.
- On Unix libuv drops a failed accept itself, and when descriptors run out it sheds load by accepting and closing whatever waits (`uv__emfile_trick`). Only on Windows does an accept's error reach the callback, and there the listener has stopped (`src/win/tcp.c:1221-1231`). A `uv_accept` that fails on Unix closes the descriptor and leaves the listener listening (`src/unix/stream.c:535-594`).

Found in review (2026-09-26, `/code-review max`), before the first commit: fifteen findings, eleven confirmed by running them, four plausible. On the owner's word, "Let's work on all of them".

DECIDED on the owner's word (2026-09-26), by form, the recommended answer to each of four questions:
- **The count of open connections is the table's size.** The shell passes it with each arrival, `(connection-arrived n)`, so the step keeps no count to drift, and nothing reports a close to it for counting. `connection-closed` stays in the vocabulary for M8's drain. Weighed: the step's own count, guarded at each report site.
- **A refusal episode is logged twice at most:** the first refusal at once, then how many were refused, when a connection is next accepted or the server shuts down. Counted in the pure step. Weighed: every refusal, as nginx does.
- **A listener that fails shuts the server down:** `listener-failed` is logged, the listener closed, and the server drains, so the process ends once its connections finish and a supervisor restarts it. It is a new event in the step's vocabulary. libuv 1.52.1 reports such a failure only on Windows (`src/win/tcp.c:1221-1231`). Weighed: log only; listen again, which would need M5's timer.
- **One procedure closes every handle,** and what a close does follows the handle, not the caller: a connection's cleanup runs whoever closes it. The rule is again one `uv-close!` caller, checked by reading the source with Chez's own reader. Weighed: an owner per kind of handle.
Decision 0005 has an amendment recording the two about refusals and the listener, and the backlog's bound.

M4.3 FIRST STEP — THE TWO LIMITS, `limits-with`, AND `server-step`.
- `max-connections` (10,000) and `backlog` (511), decision 0005's, arrived with plan §3's four things each: the field, a test of its default, `CHEZ_HTTP_MAX_CONNECTIONS` and `CHEZ_HTTP_BACKLOG` in `limits-environment-variables`, and the drift guard extended. Each is at least 1. The backlog is at most 2147483647, since `uv_listen` takes it as a C `int`; a larger value wrapped negative, or raised an error that named no variable (review, C6).
- `limits-with` replaces fields by name, in an order it reads from the record type itself. The four hand-written fifteen-argument copies in the tests are gone; two of them could swap the cap and the backlog with no suite noticing (review, C18).
- `src/http-server/server.sls`, `(http-server server)`, new and pure (`(rnrs)` and the limits):
  - the vocabulary: five events (design §4.6's four and `listener-failed`), five actions, two phases;
  - the state is the phase and the refusals of the episode under way, linear as a connection's is. A state whose limits have no connection cap of at least 1 is refused, so `max-connections` = `#f` cannot reach an arrival (review, C3's trigger);
  - an arrival carries the count of connections open, and is answered first: `accept` below the cap, ending a refusal episode with `(log refused max-connections n)`; `refuse` at it, the episode's first logged `(log refusing max-connections)`; `refuse` while draining, unlogged;
  - a shutdown, or a failed listener (logged), closes the listener and drains, logging an episode under way; a second asks for nothing;
  - a tick and a close ask for nothing yet.
- `tests/test-server.sps`, new, 28 checks: the vocabulary, tied to the step (every event is taken in either phase; no row asks for an action outside the list, read from what the step answers), and a row per transition, held as data.
- Red before green: the limits suite stopped at load at `limits-with`, then failed the backlog's bound alone until it existed; the server suite stopped at load against the step before the rework.
- Watched to fail (m4-mutations.md): M4.3-A, the plan's, the step's refusal rows and nothing else in any suite; L1 to L7 and W1 to W3, the limits; B to Y, the step, one or more for every check.
- Every suite green in a scratch worktree with only this step, cut from main at 100ae8b: thirty suites, 794 expected passes (limits 37, server 28, shell 48), each exit 0. `make check-imports` and main's close-ownership gate are clean there, and the step's mutants ran there with the results they give on the finished tree.

NEXT: the second step, the shell's listener and one procedure that closes every handle, stacked on this one.
