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

Slices ①②③④⑤: ① vocabulary + table — MERGED (85e7d81, PR #7); ② head + request accumulator — MERGED in four PRs: the parser entry points (722269e, PR #10), the pure libraries (7e4ba1a, PR #11), the head (a75bf39, PR #12), and the corpus and allocation checks (70cb0cf, PR #13); ③ request-target through uriparse — in four stacked PRs (the ledger's M2.3 entry); ④ message loop: pause, read-stop, pending input; ⑤ hand-off door + error rows. The plan expected two PRs (①② then ③④⑤). ① alone is 596 inserted lines of code and tests (connection.sls 302, test-connection-table.sps 282, the fake shell's tick 12), over plan §1 rule 1's ~400, so on the owner's word (2026-09-23) it went up as its own PR. Mutation log: `.superpowers/sdd/m2-mutations.md`.

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

M2.3 — THE REQUEST-TARGET. Branch feat/m2.3-request-target, cut from main at 8209de6; 2026-09-24, Darwin arm64, Chez 10.4.1 `tarm64osx`. The slice goes up as four stacked PRs, one per step below: feat/m2.3-request-target, then feat/m2.3-target-judge, feat/m2.3-target-core and feat/m2.3-target-redirect, each cut from the one before. Each step's tree passes `make test` on its own.

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

M2.3 FIRST STEP: the target's limit.
- `on-url-data` counts the target's bytes as they arrive and refuses a target past `max-target-bytes` (8,192, decision 0005) with `(fail target-too-large)`. `reason-status` answers it 414, and docs/configuration.org says so.
- Two head rows: a target at the limit, and one byte past it, at every delivery size.

Watched to fail: mutations A, B and C. `make test` green: sixteen suites, 252 expected passes.

M2.3 SECOND STEP: the target judge, `(http-server target)`.
- `(http-server target)`, new, exports `make-target-judge`, `target-judge?` and `target-fault : TargetJudge Symbol Span -> (U #f Symbol)`. The method and the first byte pick the form:
  - CONNECT: authority-form, through `uri-parse-authority-form-validate` over a copy of the span, parsed fresh.
  - `*` alone: asterisk-form, for OPTIONS only.
  - "/" first: origin-form. The target is split at its first "?", and the two parts are judged by `(uri charset)`'s `validate-component`, over copies.
  - anything else: absolute-form, through the judge's collector ('uri mode, made on the first absolute-form target and reset before each one) and `uri-parse-result-validate`. It must then carry no fragment and no userinfo. Userinfo is read by `(uri host)`'s `authority-host-span`, the validator's own split.

  A verdict is uriparse's code, or `'asterisk-not-options`, `'fragment` or `'userinfo`. The library is not in design §3.1's table of libraries; it is introduced here.
- `tests/test-target.sps` (24 checks) tables the four forms and the three rules. The library is pure, and the core does not call it until the third step, so this step's tree passes on its own.

Watched to fail: `test-target.sps` exited 255 before the library existed. The mutations against the library ran once the core used it, and are recorded with the third step. `make test` green: seventeen suites, 276 expected passes.

M2.3 THIRD STEP: the core judges the target.
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
1. **One reason for every form rule.** A target the judge refuses closes as `'invalid-target`. Which rule fired is the judge's verdict, not the close reason.
2. **The target is judged at on-headers-complete**, where the method is known, not at on-url-complete. So a refused target's headers are still read, within the header limits.
3. **A head with no target is judged as an empty one, and refused.** The parser never completes a head without a target, and the synthetic states now read one in.
4. **`(http-server target)` is a library of its own**, so its forms and rules can be tabled without a parser.

Found and recorded, for later:
- **(M4) Absolute-form's host.** RFC 9112 §3.2.2 says an origin server MUST ignore Host and use the target's authority. The request carries the target as a span, and reading the authority from it is the handler-facing request's job, M4.
- **(owner) Two RFC rules no slice names.**
  - RFC 9110 §4.2.1: a recipient MUST reject an http(s) URI with an empty host. `http:///p` is not checked.
  - RFC 9112 §3.2: a server MUST answer 400 to an HTTP/1.1 request with no Host, with more than one, or with an invalid one.
- **(M2.5)** CONNECT reaches the handler before the hand-off (M2.1's finding). The head suite tests CONNECT only through its refusals, and test-target.sps covers the rest.

NEXT: M2.3's fourth step, the narrow redirect (decision 0009), on feat/m2.3-target-redirect, stacked on this branch.
