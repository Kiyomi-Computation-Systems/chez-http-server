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

Found and recorded, not acted on: (1) chez-httparse's corpus harness libraries live under `vendor/chez-httparse/test/support/harness/`, NOT under its `src/`, so they are not on the Makefile's `LIBDIR_LIST` — M1 must add that directory (§3.2); (2) three limits field names and the environment prefix were renamed in M0 while the records still carry the old ones — `header-timeout-ms` (0005:17), `body-timeout-ms` (0005:18), `max-pipeline` (0004:14 AND 0005:27), prefix `HTTP_SERVER_<NAME>` (0005:13) — the ledger records the prefix but the three field renames are recorded nowhere, and 0004 is easy to miss because it names the field in prose rather than in 0005's table (§9.4). The second was handed to the session holding M0 and amended as `docs: amend ADRs 0004/0005 to record M0 limits naming` (PR #4, branch docs/adr-config-naming, d2b51e7; a provenance fix, not a ladder rung): strictly additive, 24 insertions and 0 deletions, hunks opening at 0004:19 and 0005:37 — below every line §9.4 cites, verified from the shared object store, so the design doc needed no fixup. Both amendments are self-contained, so neither branch depends on the other's merge order.

CI is uninformative on this account and has been since before M0: GitHub Actions answers "The job was not started because recent account payments have failed or your spending limit needs to be increased" with zero steps executed. The three most recent runs — the M0 PR, the push to main after it merged, and this PR — all failed that way, so the red check carries no information about any of them. The local `make test` is the only signal, and the Linux leg (Chez 10.4.1 built from source) has not run since the condition began.

Not done: the milestone plan (rung 3) is deliberately unwritten — §9.1 cross-references the brief's M0-M8 with one line each saying which section of the design document that milestone implements, and §9.2 names the milestone plan as the next planning task. This section supersedes M0's "Not done" line above, which recorded rungs 2 and 3 as both unwritten.

NEXT: either rung 3 — the milestone plan, which slices the brief's M0-M8 against this document's sections with per-slice exits and mutation logs — or M1, the instrument with no server (the llhttp-through-chez-httparse corpus loader and the libhtp `.t` loader, the fake shell, the trace recorder, the ratchet manifest, the pr/release chunk-size split), whose first obligation is the harness library path above. Owner's call which comes first; M1 starts on a branch cut from main.
