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

M4.3 SECOND STEP — THE SHELL'S LISTENER, AND ONE CLOSER.
- `(http-server private shell)`:
  - `handle-close!` is the one `uv-close!` call, for a connection's handle, the listener, and a refused one. Its callback follows the handle: a connection's close takes it out of the table, now keyed by handle, and reports `closed`, whoever asked for it. `refuse!`, which closed any handle it was given, and let a connection's handle pass the gate, is gone (review, C2);
  - `shell-adopt!` offers a handle with the table's size and takes the step's first action as its answer, anything but `accept` or `refuse` an assertion violation (C4). If anything raises before the handle is served it is closed, so none is left open with no one to close it (C3);
  - `shell-listen!` refuses to listen while a listener is open, or once its server has stopped listening, so a listen after a shutdown cannot open a listener nothing closes (C1). A listen that fails is closed and may be retried (C1b);
  - the listener's error is `listener-failed`, which shuts the server down (C5); a `uv-accept!` that fails is logged as `accept-failed`, and the listener listens on;
  - `server-run!` refuses an action it cannot perform, where it dropped it (C12); the server's actions run without a closure per call (C17); `closing-on-raise` takes the handle to close, and serves the listener and a connection alike (C19);
  - the trace also sees the server's events and the actions of its the shell performs;
  - `reconcile!` drops a connection whose handle is gone, which frees its place; nothing is reported to the server any more, so nothing can raise inside the run loop's handling (C9, C10, C11, C15).
- `tests/test-close-ownership.sps`, new, replaces the awk scan: it reads src/ with Chez's own reader and requires one use of `uv-close!`, in `handle-close!`. Its fixtures pin what the scan missed: a call after a `;` in a string or a `#\;`, two uses one character apart, a rename in an import (C7, C8). `make check-close-ownership` runs it alone; `make test` runs it with every suite, and CI no longer needs ripgrep.
- `tests/test-shell.sps`, fourteen checks more than M4.2's 48:
  - a bug before a connection is served: the trace raises on the arrival, and the client reads the stream's end, no connection served, the error logged;
  - the reconciliation's drop, and the run loop runs on;
  - a shell capped at one connection: it serves a client; listens on one listener at a time; two clients over the cap each read the stream's end with nothing before it, the first refusal logged and the second not; once the first client closes the next is served and the count of refusals logged; a shutdown closes the listener the clients used, which the old check did not read (sweep, N1), and the server never listens again;
  - a backlog of -1 from the limits cannot listen, and the listener is closed; a listener on a port in use cannot listen, is closed, and the shell listens again.
- Records: `docs/configuration.org` says what a refusal, running out of descriptors and the backlog's bound look like; design §3.3, §4.6 and §7.6, plan §8's M4.3 note and §9's M7 line, and global-constraints say one procedure closes every handle.
- Red before green: the shell suite with the new checks stopped at load against the first step's shell; the ownership suite failed on a copy of the tree whose shell had three owners.
- Watched to fail (m4-mutations.md): S1 to S16 but two; G1 to G5, a second caller, a second call, an alias, a call after a `;` in a string, two uses side by side; the walker's own WA to WH; the plan's M4.3-A against every suite.
- Scope statements:
  - M4.3-S10 and S11: the shell's assertions on a wrong answer or an unknown action fire only on a bug in the step, whose rows pin every answer; no check can provoke them.
  - The listener's failure and a failed `uv-accept!` are routed and logged, and not provoked: libuv 1.52.1 reports neither on Unix in a way a test can cause, and Windows is not in CI. The step's rows hold the listener's failure.
  - "comments are not uses" pins Chez's reader.
- The review's other findings, fixed: the stale single-owner statements (C14); the untied vocabulary (C13); the S7 record, which said the second listener was never closed where the first was, and the G2 record, which overstated the awk fix (sweep, N1); several checks never watched to fail (sweep, N2), now each reddened by a named mutant. Left as it is: the guard idiom repeated across nine suites (not reported; `(testing)` has no helper for it). Not this slice's: two M8 notes on WebSockets and Caddy appeared in the plan's working copy from outside this session; they are not in M4.3's commits.

`make test` green: thirty-one suites, 820 expected passes (limits 37, server 28, shell 62, close-ownership 12, exports 2), exit 0.

NEXT: two stacked PRs, on the owner's word ("Commit an open the PRs - u don't need to split into 4"). M4.3's code and tests are 896 inserted lines: feat/m4.3-server-step, the first step (444 inserted and 57 deleted), then feat/m4.3-listener, cut from it (452 and 89). Each is a little over plan §1 rule 1's ~400, and the owner kept two rather than four. Then M4.4, the contract test and the socket lane, with the upload past a refusal.

MERGED to main on 2026-09-26, on the owner's "Do closing ritual":
- **#48, the first step,** as b79bd85, without deleting its branch. The squash tree (cbf60d8) is identical to the tested tip's, 72a5c2b.
- **#49, the second step.** Retargeted to main, then rebased from 72a5c2b onto b79bd85 as 1f1655b, its tree unchanged (c586e72, the tested 71585ca's). It was force-pushed with the lease read from `ls-remote`, and merged as 140f5e1, whose tree is c586e72 too.
- **#50, the M8 notes.** Two notes another session wrote in the shared checkout, on the questions M8's door must answer before a WebSocket library can take a stream through it, and on serving behind Caddy. They were committed on their own, on the owner's "Commit the M8 notes to their own PR". The commit was built from main without touching the checkout, and the checkout's uncommitted copy was dropped once it was proven to be exactly those lines. The notes were rebased from 100ae8b onto 140f5e1 as 0e38c22 with the same patch (patch id bf7c40c), and `make test` is green on that tree. They merged as e290d1a, whose tree is 0e38c22's, 6d4e2ec. One sentence in its question 2 still gives the close-ownership rule of M4.3's working copy before the review, "each kind of handle one `uv-close!` owner"; since #49 it is `handle-close!`, one procedure for every handle.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36279194851 and 36279207840 (#48 and #49 as opened), 36280979170 (#49 rebased), 36280825011 and 36281050335 (#50, as opened and rebased).
- **Branches.** All three are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-one suites, 820 expected passes, exit 0.

MERGED to main on 2026-09-26, on the owner's "go ahead and merge this and do the closing ritual": **#51, question 2's close owner,** as 5486ddb. The sentence #50 left stale now says `handle-close!` is the one `uv-close!` in `src/`, for every kind of handle (`make check-close-ownership`). It was written in its own worktree off main, on the owner's word, since the shared checkout was the M4 session's. The squash tree (1389928) is identical to the tested tip's, ac85e2d. CI was the billing block, the `linux` job with 0 steps (36282494049). The branch is deleted local and remote, and refs pruned. `make test` green on its tree: thirty-one suites, 820 expected passes, exit 0. NEXT is unchanged.

M4.3 DONE and merged:
- `max-connections` (10,000) and `backlog` (511) are limits, the backlog at most a C `int`'s largest; `limits-with` replaces limits by name;
- `server-step`, pure, decides the listener: accept below the cap, refuse at it; a refusal episode logged twice at most; a shutdown or a failed listener closes the listener and drains;
- the shell listens, offering each connection with the table's size, and one procedure, `handle-close!`, closes every handle, held by a check that reads the source with Chez's reader;
- four questions settled by form, and the review's fifteen findings fixed.

NEXT: M4.4, the contract test and the socket lane (plan §8): the same scripted event stream through the fake shell and the direct libuv shell must give identical wire bytes and identical action traces; the socket lane's upload past a refusal (decision 0011's measurement) becomes a test. On a fresh branch cut from main after this commit, when the owner asks. Then M4.5, the facade (decision 0012), and the M4 exit.

M4.4 — THE CONTRACT TEST, AND THE SOCKET LANE (plan §8; design §8.4, §8.5). Branch feat/m4.4-contract, cut from main at 523b8fa and fast-forwarded to 5f537b6, which another session merged meanwhile (#51's plan fix and its reflect; neither touches `src/` or `tests/`); 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED first, by a spike (scratch, not kept): six client scripts played to the libuv shell over loopback, and the libuv shell's own events then given to the fake shell, gave identical events, actions and wire bytes. libuv delivered each completion before the next read. A write's completion runs in the loop's pending phase, and in the same call libuv shuts the socket for the half-close the core asks for there and runs its callback, before the poll that reads (libuv 1.52.1, `src/unix/stream.c:733-735, 1232-1238, 625-660`).

M4.4 FIRST STEP — THE SOCKET LANE'S UPLOAD PAST A REFUSAL.
- The socket lane is `tests/test-shell.sps`, which M4.2 wrote in design §8.5's shape; its header now says so.
- It gains decision 0011's measurement as a test. A client sends four MiB after a head the core refuses, with no Host, a 400. Its send buffer is small, so the upload is sent only if the server reads it, and it reads only once its send is over, as Python's http.client and Node's fetch do. It sends all of it, then reads the 400 and the stream's end: the connection lingers, reading and dropping the upload. A client that does not connect sends nothing, and both checks say how its connect ended.
- Measured under a close at once (M4.4-U), three runs of three: the send fails with EPIPE, and the stream ends in ECONNRESET, with the 400 already in the client's buffer. Python's http.client gives up at the EPIPE, which is why decision 0011 saw no status.
- `tests/shell-testing.sls`, `(shell-testing)`, new: the suite's clients and its run of the shell's loop, moved out of it to be shared with the contract test. With the clients' move alone, the suite's output was unchanged, 62 passes. A review before the first commit found eight things, all fixed on the owner's word; its record is with the second step, since its fixes fall in both. Two are here: the run closes its ticker when the shell's run loop raises, which a check provokes, and a client records a connect refused at the call as it records one refused later.
- The upload check passed at once, against M4.2's staged close, so its red is its mutants' (m4-mutations.md): M4.4-U, a close at once, and M4.4-U3, no reading while lingering. U3 found a flaw in the check first: a send the suite's own close cut short started a read on a closing handle, and the raise surfaced in the next block's wait. The client now reads only while its handle is open. The ticker's check was red first, and M4.4-K turns it red.
- Every suite green in a scratch worktree with only this step, cut from main at 5f537b6: thirty-one suites, 823 expected passes (shell 65), each exit 0; the import audit clean. U, U3 and K ran there too, turning the same checks of the shell suite red as on the finished tree.

M4.4 SECOND STEP — THE CONTRACT TEST.
- `tests/test-contract.sps`, new (design §8.4):
  - a script is a client's: what it sends, where it waits for the server to have read it, and its end, the half-close. The client plays it to the libuv shell's own listener, on the shell's loop, run by the shell's own run loop. That loop logs a callback's error and runs on; a byte-machine contract condition it raises again ends the suite, as it would end a server;
  - the libuv shell's own events are then given to a fake connection whose clock reads the same instant: each delivery and the client's end as the libuv shell received them, and each completion where it received its own, the fake delivering the one it has waiting. How the kernel divides the stream into reads is its policy (design §8.5), so a script cannot fix it;
  - nine scripts: a GET kept alive; three requests in one write; a request split across two deliveries; a request with a body; a response that closes the connection, then the linger; input that arrives while the connection lingers; a handler that raises; a handler that raises a condition with no message; and a request refused for want of a Host;
  - for each: the libuv shell read what the client sent, then its end alone, and closed; the client read the bytes the fake shell wrote; and the two traces, every event dispatched and action run, in order, are identical. The traces compare content: a condition by each of its simple conditions and any record by its type and fields, since `equal?` compares a record with fields by identity. Where the shells part, a `CONTRACT MISMATCH` line on stderr names the first byte, or the first event or action;
  - a client that does not connect plays nothing, and its read check names how the connect ended;
  - at the end, no connection and no handle is left.
- `tests/fake-shell.sls`: an optional trace, which sees each event as it is dispatched and each action before it is performed, as the libuv shell's trace does; and `fake-shell-deliver-later!`, which delivers the oldest event a later turn brings, one at a time. `tests/test-fake-shell.sps` and `tests/test-message-loop.sps` have a check each.
- `(shell-testing)` gains `client-shut!`, the half-close a script ends with.
- Red before green: the fake shell's two checks ran before it had either: test-fake-shell's body raised at the five-argument `make-fake-shell` (a harness error, after 15 passes), and test-message-loop stopped at load. The no-message script's trace check was red before the rendering compared records by content. The rest of the contract suite was written against shells that already agree, so its red is its mutants'.
- Watched to fail (m4-mutations.md), on the finished tree:
  - M4.4-A, the plan's: the Date line's space after the colon sent as a tab. Every script's wire check goes red, naming the byte, 32 in the fake's bytes and 9 in the libuv shell's: byte 22 after a 200's status line, 31 after a 400's, 41 after a 500's. The socket lane stays green, since llhttp strips a tab there as it strips a space, and so does every other suite;
  - M4.4-T and T2, the libuv shell reporting a completion twice and tracing an action after performing it: the trace checks alone;
  - M4.4-R and X, the read path dropping each delivery's last byte and a read error reported after the client's end: in this suite the read checks alone, since the fake is given the same stream;
  - M4.4-E, the listener left open: the end's check. M4.4-N, the rendering before the review: the no-message script's trace check. M4.4-P and P2, a client that cannot connect: every read check, named, the suite running on;
  - M4.4-F1 to F4, the fake shell's trace and one-at-a-time delivery: their own checks, and every contract trace check for F1 and F2.
- Survives, a scope statement: F3 and F4 leave the contract green. In these scripts the fake never has two completions waiting, by libuv's order above. The replay delivers each where the libuv shell received its own regardless, and the message loop's check holds the order.
- Records: design §8.4 and §8.5, plan §8's M4.4 note.

Found in review (2026-09-27, `/code-review high`), before the first commit: eight findings, all fixed on the owner's word ("Do the fixes"). Each premise was checked first:
- **The run of the shell's loop left its ticker when the loop raised**, as it does a byte-machine contract condition (design §6.4), so a later "no handle is left" check would have blamed the code under test. It closes the ticker on the way out now, as chez-libuv's `run-until/ticking` does, and a check provokes the raise.
- **The contract's wait said a bug that raises in a callback shows as the traces parting.** A contract condition still ends the suite; the note now says so.
- **A read error the libuv shell made itself would have been handed to the fake as input**, so both traces would agree over it. Measured first: a mutant reporting a read error after the client's end (M4.4-X) left every suite green. No script resets its connection, so the read check now requires the client's end alone, and X turns it red.
- **A condition with fields and no message never compared equal between the shells**: `equal?` compares such a record by identity (measured; a field-less record, such as `(make-error)`, is one shared instance and compares equal). A script whose handler raises one was red first. The rendering now compares a condition by its simple conditions, and any other record by its type and fields.
- **A client that could not connect stopped the suite with a harness error**, in the contract suite and in the upload check alike. Measured first with M4.4-P and a probe of the upload. A second way was found on the way: macOS refuses a connect to the client's own address at the call, with EINVAL (M4.4-P2), where a closed port refuses it at the completion. A client now records a connect refused at the call as it records one refused later, and both suites report it by name and run on.
- **The contract's wait predicates rebuilt the whole event list on every iteration.** The trace now keeps the delivered bytes in chez-libuv's byte collector, and a flag for the close, as they arrive.
- **The contract suite hand-rolled joining bytevectors**, which the byte collector already does. It uses the collector.

`make test` green: thirty-two suites, 853 expected passes (contract 28, shell 65, fake-shell 19, message-loop 20), exit 0.

NEXT: two stacked PRs, on the owner's word. M4.4's code and tests are 567 inserted lines, over plan §1 rule 1's ~400: feat/m4.4-socket-lane, the first step (176 inserted, 60 deleted), then feat/m4.4-contract, cut from it (391 inserted, 33 deleted). Then M4.5, the facade (decision 0012), and the M4 exit.

MERGED to main on 2026-09-27, on the owner's "Do closing ritual":
- **#52, the first step,** as 32aa654, without deleting its branch. The squash tree (a478baa) is identical to the tested tip's, 251ab40.
- **#53, the second step.** Retargeted to main, then rebased from 251ab40 onto 32aa654 as 962eaa8, its tree unchanged (8efdc9e, the tested 1c63567's). It was force-pushed with the lease read from `ls-remote`, and merged as a854e06, whose tree is 8efdc9e too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36319062837 (#52), 36319064692 (#53 as opened) and 36320460207 (#53 rebased).
- **Branches.** Both are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-two suites, 853 expected passes, exit 0.

M4.4 DONE and merged:
- the socket lane, `tests/test-shell.sps`, holds decision 0011's measurement as a test: a client that uploads four MiB past a refusal sends all of it, then reads the status and the stream's end;
- the cross-shell contract, `tests/test-contract.sps`: nine client scripts played to the libuv shell, its own events given to the fake shell, and the two shells' wire bytes and traces identical. The plan's mutation names the differing byte, and the socket lane stays green under it;
- the fake shell traces what it does and hands over a later turn's events one at a time, and the shell suites share `(shell-testing)`;
- the pre-commit review's eight findings fixed.

NEXT: M4.5, the facade, and what a handler sees (plan §8; decision 0012):
- `(http-server)`, decision 0001's facade;
- a handler reads the request through accessors that copy what it asks for, with the host by RFC 9112 §3.2.2;
- the server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1 and 8080;
- a facade that builds limits refuses a pipeline cap other than 1;
- finished by the plan's mutation, an absolute-form request's host read from its Host field.

Then the M4 exit (plan §8): curl and ab get correct responses and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10). It starts on a fresh branch cut from main after this commit, when the owner asks.

M4.5 — THE FACADE, AND WHAT A HANDLER SEES (plan §8; decision 0012). Branch feat/m4.5-handler-view, cut from main at a5d8474; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

Gathered before the first test, from plan §8, decision 0012 and this ledger:
- decision 0012: a handler reads the path, the query, a header's value by name and the host, as strings made when asked, and the method as llhttp's symbol; the host follows RFC 9112 §3.2.2; the server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1 and 8080;
- a facade that builds limits refuses a pipeline cap other than 1 (M2.4);
- design §6.4's `&http-server-error` and its two subtypes, "defined in the shell and exported from the facade", which design §9.1 gives to M4;
- the plan's mutation: an absolute-form request's host read from its Host field.

Settled here, where decision 0012 is silent, each with a check:
- a string is a character per byte, Latin-1, as the decision's measurement made its strings, so every byte reads back as the byte it was;
- the query is what follows the target's first "?", in every form, since a "?" can be in neither an authority nor a path (RFC 3986 §3.2, §3.3);
- asterisk-form's path is "*", authority-form's is "", and an absolute-form target's is its URI's, "/" when empty (RFC 9110 §4.2.3's normal form). Hyper's `http` crate reads all three the same way;
- a header's value is its first field's, by name in any case, as `headers-ref` reads it in the decision's measurement, and without the whitespace around it (RFC 9112 §5). So is the host from a Host field, which #54 left to M4.5. The view trims where it reads, as the Host judge (with #54) and the transfer-coding reader do. Trimming once, where the core records a value, is #54's alternative, recorded in its entry: one place for every reader, at the cost of a new span for each value with whitespace to drop. It changes M2's core. Decided below: trimmed where read;
- authority-form's host is the Host field's, by the decision's letter ("otherwise it is the Host field's value"). RFC 9112 §3.3 would read the target, the tunnel's destination. v1 answers a CONNECT and closes, so no handler needs it now. Kept, decided below (M4.5-J is its mutant).

Found:
- llhttp leaves out the whitespace before a field value and keeps what comes after it: through the core, "X-Pad:   v  x  " keeps "v  x  ". So the view trims it.
- The Host judge (M2.3's) judges that span as it is kept, so "Host: h " and "Host: h" with a tab after it are answered 400, where RFC 9112 §5 makes the value "h". This is outside M4.5, and was fixed on its own by another session: PR #54 (fix/host-trailing-whitespace), open as this is written. Its review left to M4.5 what a handler reads of such a value: settled below.
- An absolute-form target always has an authority, which may be empty ("ftp:///x"). llhttp takes one only with "//": "GET urn:example:x" never reaches the core.
- `(rnrs)` leaves out `string-set!`. The view fills its strings with it, so `(rnrs mutable-strings)` joins the pure libraries' imports, amended in global-constraints and design §3.1. Measured on an 11-byte path (scratch): 64 B that way, 96 B through a UTF-16 bytevector, 240 B through a list, 2,048 B through a Latin-1 transcoder.

MEASURED, the shipped view (scratch, not kept; two identical runs, exit 0), on decision 0012's three requests and one absolute-form GET. Bytes per request, beside the decision's (A), 80, 96 and 192:

| request | path and User-Agent | host |
|---|---|---|
| curl's GET | 112 | 64 |
| a JSON POST | 128 | 64 |
| a browser's GET | 224 | 64 |
| curl's GET, absolute-form | 3,952 | 3,904 |

A lookup by name makes the name a bytevector, 32 B, which is the difference from (A). An absolute-form target's path or host costs a uriparse parse each time it is asked for. That is accepted, as CONNECT's fresh parse is (design §7.5): absolute-form is a proxy's, rare at an origin server, and a handler that does not ask pays nothing.

M4.5 FIRST STEP — WHAT A HANDLER SEES.
- `src/http-server/view.sls`, `(http-server view)`, new, pure:
  - `request-path`, `request-query`, `request-header` and `request-host`, each a fresh string, or #f for a query or a header that is not there;
  - where each part is follows the target's form, read by `target-form`, the judge's own rule;
  - an absolute-form target's host is its authority, whatever the Host field says; otherwise the host is the Host field's value, "" when it is empty or missing.
- `(http-server target)` exports `target-form`, the rule the judge reads, which the view now reads too, and `first-question`. The allocation gate is unchanged (19 passes).
- `tests/test-view.sps`, new, thirteen checks. Each request is fed whole to a fake connection running the real core and parser, and read inside the handler's call. The rows: origin-form's path and query, with a second "?" and a percent-encoding; no "?" and an empty query; absolute-form's path, query and host; the empty path; asterisk-form and authority-form; origin-form's host; an empty Host and none; a header by name; a value's trailing whitespace; a byte above 127. One more is built by hand: a Host value with whitespace after it, which the core refuses until #54, reads without it.
- Red before green: the twelve rows through the core failed against a stub view. The hand-built host row, added after #54, passed at once against the view as written; its red is M4.5-O2's.
- Watched to fail (m4-mutations.md):
  - M4.5-A, the plan's, reddens the host row alone. Every other suite stays green;
  - B to P each redden the view's own rows, and O2, the host's value untrimmed, the hand-built row alone;
  - Q, `target-form` without its CONNECT arm, reddens the judge's CONNECT rows, two CONNECT traces and the view's authority-form row;
  - each of the thirteen checks is reddened by at least one mutant.

DECIDED on the owner's word (2026-09-27, "Go with the recommendations"), each as recommended and built:
- a value's trailing whitespace is dropped where it is read: by the Host judge (with #54), the transfer-coding reader and the view. Trimming once where the core records a value, #54's alternative, can come later as a small PR of its own;
- authority-form's host is the Host field's, by decision 0012's letter;
- an absolute-form target's parts cost a uriparse parse each time they are asked for (3,904 B, measured above), accepted as CONNECT's fresh parse is;
- the details the view settles where decision 0012 is silent (above) stand, and decision 0012 gains a dated note saying so.

Every suite green on this step alone, in a scratch worktree cut at its commit: thirty-three suites, 866 expected passes (view 13), each exit 0; the import audit clean.

NEXT: the second step, the facade, stacked on this one: `(http-server)`, what reaches the embedder; the address from `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`; the startup's `&http-server-config-error`, which refuses a pipeline cap other than 1 as the environment path does; and the docs a handler reads.

M4.5 SECOND STEP — THE FACADE. Branch feat/m4.5-facade, cut from the first.
- `src/http-server.sls`, `(http-server)`, new, the facade. It exports:
  - `serve`;
  - the six accessors a handler reads with: `request?`, `request-method`, and the view's four;
  - `make-response` and `response?`;
  - `&http-server-error` and `&http-server-config-error`, with their predicates.
  
  It imports this project's libraries alone, as design §3.1 has it. The spans stay the request's: no span accessor is exported.
- `src/http-server/private/serve.sls`, `(http-server private serve)`, new: the process's edge.
  - `start-server` reads the limits and the address through a lookup. It makes the shell, listens, and logs `listening` with the host and the port it got.
  - `serve` is `start-server` on a loop of its own, with the process's environment (`getenv`) unless a lookup is given, and the log below. It then runs the loop until the server stops: in v1, only a listener that fails stops it.
  - A setting the pure parsers refuse is raised again as an `&http-server-config-error` composed with their assertion violation, whose irritants name the variable. That covers a pipeline cap other than 1, since the facade builds limits only from the environment (M2.4's note). A `CHEZ_HTTP_HOST` that is not an IP literal is refused by chez-libuv's bind as `bad-address`; it is raised as a config error naming the variable, and the shell has closed the listener.
  - `log-line` writes each thing that happens as one line on standard output, flushed at once (Twelve-Factor XI): what happened, then each detail. A condition reads as Chez's `display-condition` shows it, its line breaks made spaces, and a record as its kind, `#<connection>`, so a line never spells out a connection's state.
- `(http-server limits)`: `address-from-environment` reads `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`, by default 127.0.0.1 and 8080 (decision 0012). The port is 0 to 65535, and 0 asks the kernel for one. The host is judged by the bind, the OS's own parser.
- `tests/test-serve.sps`, new, nine checks:
  - the facade's exports;
  - a server started through an environment on port 0: it logs where it listens, with the kernel's port; a request read through the facade's names reaches the handler, and its answer reaches the client; its limits are the environment's (a 414); and once shut down it leaves nothing on the loop;
  - `serve` refuses three malformed settings as config errors naming each;
  - a host that is not an IP literal is refused, and nothing is left open;
  - the log's two shapes.
  
  Clients run on the server's loop, every wait capped by an iteration count. `tests/test-limits.sps` gains three address rows (40).
- `make run PROGRAM=...` runs a program on the library path. `make check-imports` now reads the facade's file as well as `src/http-server/`.
- Docs:
  - `docs/handlers.org`, new: what a handler reads, keeping strings rather than the request (decision 0012's rule for spans), and answering;
  - `docs/configuration.org` gains where the server listens;
  - the README's status, stale since M0, now says M4, and there is a quick start.
  
  The docs had described the four timeouts, a 408 among them, as enforced; the shell only records deadlines until M5's wheel, and now they say so.
- Red before green:
  - the address rows failed against a stub parser;
  - the serve suite's eight behavior rows failed against a stub start that listened with default-limits and logged nothing;
  - the exports row passed at once, since the facade's list was already the one written, so its red is M4.5-Z's.
- Watched to fail (m4-mutations.md), each against every suite: M4.5-R to AE, and AF, the facade importing `(chezscheme)`, which `make check-imports` alone reddens. Every check of the step is reddened by at least one.
- Found while watching: M4.5-AC hung the serve suite. Its `serve` accepted a pipeline cap of 2, listened on 8080 and ran for good, and the run was killed. So every start that should fail also names a host no bind accepts, and so does the suite's own environment: a start past its settings, or a `serve` that read the process's environment rather than its lookup (AE), is refused at the bind. Both were run again and turned red without hanging. A failing start must not be able to run.
- Not tested in a suite: `serve`'s own run of its loop, which blocks by design. Smoke-run by hand (2026-09-27): the README's program, started with `make run` on port 18765, logged `listening 127.0.0.1 18765`. curl got a 200 with its body for a GET and for HTTP/1.0 (with `Connection: close`), the length and no body for `-I`, and two GETs on one connection. The M4 exit runs curl and ab against it.
- Records: design §6.4 (the two types, and why §6.4's third waits) and plan §8's M4.5 note.

DECIDED on the owner's word (the same words, as recommended): design §6.4's `&http-server-handler-error` is not defined in v1. A handler's raise is answered 500 and logged as `handler-failed`, and never reaches the embedder, so the wrapper has nothing to carry.

`make test` green: thirty-four suites, 878 expected passes (serve 9, limits 40, view 13), exit 0.

NEXT: two stacked PRs, on the owner's word: the first step, then the facade stacked on it. Then the M4 exit (plan §8): curl and ab get correct responses, and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10).

MERGED to main on 2026-09-27, on the owner's "Go ahead and do the commits push the PR's up and do a closing ritual":
- **#55, the first step,** as 36b0ff5, without deleting its branch until #56 was retargeted. The squash tree (ec40093) is identical to the tested tip's, 09f7be3.
- **#56, the second step.** Retargeted to main, then rebased from 09f7be3 onto 36b0ff5 as df0d6e5, its tree unchanged (3260d75, the tested 24a78db's). It was force-pushed with the lease read from `ls-remote`, and merged as 1bdb83f, whose tree is 3260d75 too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps and the billing annotation: 36325832664 (#55), 36325848593 (#56 as opened) and 36325938319 (#56 rebased). The last was still queued when #56 merged, on a tree identical to 36325848593's, and completed the same way after.
- **Branches.** Both are deleted local and remote, and refs pruned. PR #54, the Host fix, is still open, another session's work. It meets these merges at the ends of this file and of m4-mutations.md, and in plan §8's M4.5 section.

`make test` green on main: thirty-four suites, 878 expected passes, exit 0.

M4.5 DONE and merged:
- `(http-server)`, the facade: `serve` runs a handler where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1:8080, and a malformed setting raises `&http-server-config-error` naming it before anything listens;
- `(http-server view)`: a handler reads the path, the query, a header's value and the host as fresh strings, the host by RFC 9112 §3.2.2. The plan's mutation reddens the host row alone;
- the owner's decisions of 2026-09-27 are recorded in the steps above, and in decision 0012's amendment.

NEXT: the M4 exit (plan §8): curl and ab get correct responses, and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10). It starts on a fresh branch cut from main after this commit, when the owner asks.

A HOST VALUE WITH OWS AFTER IT (RFC 9112 §5). Branch fix/host-trailing-whitespace, cut from main at a5d8474 in its own worktree, and rebased onto 6bf3c34 once M4.5 merged (#55, #56); 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.
- **Found:** `Host: h ` and `Host: h\t` were answered 400 (`invalid-host`) at every delivery size, where `Host: h` reached the handler (measured with the fake shell). llhttp leaves out the OWS before a field value but keeps the OWS after it (`X: h \t ` arrives as `h \t `), and `value-fault` judged that span as it was with uriparse's `validate-authority`, which refuses a space or a tab. RFC 9112 §5 excludes that OWS from the value, so the value is `h`, and valid; §3.2's 400 is for an invalid value.
- **Fixed:** `value-fault` (`src/http-server/host.sls`) judges the value without the OWS around it, trimmed with `trim-ows` from `(http-server headers)`, as the transfer-coding reader does. The duplicate-Host and missing-Host rules are unchanged, and a value invalid without its OWS is still refused (`Host: a b `, `Host: u@h `).
- **Tests:** a row in `tests/test-host.sps` (`h `, `h\t`, `example.com:8080 \t ` and ` h` are accepted) and one in `tests/test-connection-head.sps` (`Host: h ` and `Host: h\t` are served, at every delivery size, whatever a handler reads of the value). On main's code each failed alone in its suite.
- **Watched to fail** (m4-mutations.md): HW-A, the trim removed, turns the two new rows red and nothing else in any suite. HW-B, the OWS before a value kept, turns the unit row red alone.
- **Found in review** (2026-09-27, `/code-review high`), before the first commit: three findings. On the owner's word ("Fix 2 and 3, leave 1 for M4.5"):
  - the head row pinned the handler reading `h `, so a correct trim elsewhere would have turned it red. It now leaves the headers out (`headless`); a probe that trims every value where the core records it (HW-P) leaves it green;
  - `value-fault` bound uriparse's index and never read it. Its comment now says only the code is read: R6RS has no binding that ignores a value, since `_` is an ordinary variable that shadows `(rnrs)`'s `_`, and `(http-server target)` binds the same pair the same way.
- **Left for M4.5, which settled it (#55):** its view trims a value where it reads it, so a handler reads `h` for `Host: h `. Trimming once where the core records a value is this fix's alternative, recorded in M4.5's entry above. HW-P is that trim: every suite green, the allocation lane included, though it makes a new span for every value; spans are immutable, so one is needed only when a value has OWS to drop. The paragraph this fix first carried into plan §8's M4.5 section is dropped on the owner's word, since M4.5's note there covers it.
- `docs/host-header.org` says nothing about whitespace, so it is unchanged.

`make test` green on the rebased tree: thirty-four suites, 880 expected passes (host 12, connection-head 52), exit 0. NEXT is unchanged.

MERGED to main on 2026-09-27, on the owner's "Do the closing ritual?": **#54, the Host fix,** as 52ddb1f.
- **Rebased first.** M4.5 merged meanwhile (#55, #56), so #54 was rebased from 25ca646 (on a5d8474) onto 6bf3c34 as f8623bf. The owner chose by form to drop its plan §8 paragraph, which M4.5's note there covers. Each ledger file was rebuilt as main's text followed by #54's own appended text, both proven pure appends to a5d8474's. The code and tests were byte-identical to 25ca646's; `make test` and the three mutants ran again on the rebased tree. It was force-pushed with the lease read from `ls-remote`.
- **Merged** with `--match-head-commit` and without `--delete-branch`, from this session's worktree, since the shared checkout held main. The squash tree (4d2aae4) is identical to the tested tip's, f8623bf, and its parent is 6bf3c34.
- **Local main** was caught up in the shared checkout, clean and with its session idle, by a fast-forward through `git -C`.
- **CI.** Both runs were the billing block, the `linux` job with 0 steps: 36324869520 (as opened) and 36326632003 (rebased).
- **Branches.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-four suites, 880 expected passes, exit 0. NEXT is unchanged: the M4 exit.

M4 EXIT (plan §8, §10, §12). Branch feat/m4-exit, cut from main at 64e9a3b; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m4-mutations.md, "The M4 exit".

Gathered before the first test, from the brief's M4 gate, plan §8, §10 and §12, and design §7.5:
- the brief's gate: curl and ab get correct responses, the counters return to zero, and the contract test passes;
- plan §8: the table is reconciled against `uv-loop-live-handles` at one place in the run loop, and the per-connection budget is re-measured against design §7.5's 16,384 + 264 + 1,072 and recorded, which discharges §12's risk 2;
- plan §10: the amendment slicing M5–M8 is part of M4's close-out.

Met before this branch, each with its check:
- the contract test: `tests/test-contract.sps` (M4.4), in `make test`;
- the reconciliation: `shell-run!` reconciles after a callback's error (M4.2; decision 0003 item 4), watched to fail by M4.2-C and M4.3-S2;
- "the counters" are chez-libuv's dev-build counts, which the socket lane has read at its end since M4.2.

MEASURED before the decisions (scratch):
- curl and ab as child processes on the server's own loop, through `uv-spawn!` and a pipe: curl four times and ab twice over 500 requests took 368 ms and 712 loop iterations. Every answer was correct. After them the table was empty and chez-libuv counted the listener alone; after the shutdown, nothing.
- A server holding 100, then 500, idle keep-alive connections from a Python client in its own process: its heap grew by about 1.5 KB a connection, and no more after 50 or 200 GETs each. Outside the heap are the read buffer, 16,384 B, and `uv_tcp_t`, 264 B.

DECIDED on the owner's word (2026-09-27), by form, the recommended answers:
- **The client suite runs in `make test`,** and CI installs curl and ApacheBench (`apache2-utils`). macOS ships both. A client that cannot be started fails the suite with status 2, by name. Weighed: a target of its own, `make test-clients`, outside `make test`.
- **The per-connection budget is recorded, not gated.** Weighed: holding a connection's heap to 2 KiB in `make test`, with python3 holding the connections.

BUILT:
- `tests/test-clients.sps`, new: a server started as `serve` starts one, and curl and ab each run as a child process on its loop, every wait capped by an iteration count. It checks:
  - curl: two GETs, two HEADs and two POSTs with a body, each second one on the first's connection (curl's `num_connects`), and two HTTP/1.0 GETs, each on a connection of its own. For the HEADs, the fields a GET's answer has and no content, their Date lines set aside;
  - ab: 200 requests 8 at a time, and with `-k` all 200 kept alive, none failed, none answered other than 2xx, and 4-byte documents;
  - the counters: with every client gone, the table is empty, the listener is the one handle left, and the server logged only `listening`. After the shutdown nothing is left on the loop, and chez-libuv counts no TCP handle, read buffer, write request, pipe or process.
- `(shell-testing)`: `run-until-drained`, a wait until nothing but a timer is live (below).
- `tests/test-view.sps`: #54 merged, so the host row sends `Host: h \t` through the core, where it built its request by hand.
- CI installs `curl` and `apache2-utils`.
- `.plans/research/spike/m4-exit-budget.sps` and `m4-exit-hold.py`, new, with two runs in `out/`: the per-connection budget against the real shell.
- Records:
  - design §7.5's note: about 18.2 KB a connection against the table's 17,720 B, and a parser keeps 592 B, where the table counted the 1,072 B that making one allocates;
  - plan §8's M4 exit note, and §12's risk-2 row;
  - the research README;
  - `docs/configuration.org`: an open connection holds about 18 KB, so 10,000 hold about 180 MB;
  - README's status: M4 is done.

MEASURED, the budget (`out/m4-exit-budget.run{1,2}.txt`): the heap per held connection, over sixteen readings after 1, 10, 50 and 200 GETs each, is 1,490 to 1,707 B, median about 1,540 B, with no trend in the GETs. The parts, made fresh, are:
- the core's state with its head and target judge: 192 B;
- the adapter's context: 32 B;
- a parser: 592 B;
- chez-libuv's TCP handle: 200 to 240 B.
The rest, about 500 B, is not broken down. So an idle connection holds about 18.2 KB, 16,384 B of it the buffer.

Found and fixed:
- **`tests/test-serve.sps` waited out its caps** (M4.5's). Its two waits for an empty loop could never be satisfied, since the 1 ms ticker that keeps the loop awake is live while it waits. Each ran to its 4,096 iterations: 10.5 s of the suite's 11.1 s. Both now wait until nothing but a timer is live (`run-until-drained`), then check the loop is empty. The suite takes 0.60 s, and the client suite, which first copied the pattern, 0.73 s.
- **A missing client failed as a check, not as the harness.** SRFI-64 turns a raise inside a check into a failure, so with ab off PATH the suite exited 1. Now both clients run once with their version flags before any check, and with ab off PATH the suite exits 2, naming it. The mutants M4X-A to M4X-I ran again on the final suite and turned the same checks red.
- **ab does not hold a body to its Content-Length.** With every Content-Length one byte short (M4X-I), ab reports every request complete, none failed. curl's four checks go red. So curl's checks are the ones that see framing, and ab's see concurrency, keep-alive and completion. A and B redden ab's.

Watched to fail (m4-mutations.md): M4X-A to M4X-I each redden the client checks they break, and every check of the suite is reddened by at least one. O2b and HW-Ab, run again, redden the view's host row, now also when the Host judge refuses the value.

`make test` green: thirty-five suites, 891 expected passes (clients 11), exit 0, 16.0 s.

THE AMENDMENT (plan §14, this branch): M5–M8 sliced against what M2–M4 measured. First a sweep (a subagent's extraction) of the ledger, the decisions, the design, the docs and the code, for what each milestone was left. Each item was checked against the tree before it was written.
- **M5, three slices:** the wheel and its two limits; the tick rows the core lacks (`body` answers 408, `responding` closes); one timer per loop, in both shells.
- **M6, four:**
  - how a handler reads a body, decided first (public API, measured and settled by form, as 0012 was), with the buffering helper and brief risk 3's pinned tests;
  - the read side's credit;
  - a streamed response, with the write watermarks and M3.2's carried close-delimited arm;
  - Expect and trailers, with libhtp's two Expect files.
- **M7, three:** the scheduler and the phase cell (R1, R2, R3, R5); what a handler awaits, decided first (R4); the coroutine shell in the contract test.
- **M8, four:** the drain; the hand-off door, decided first; the black-box and robustness lanes; load, and the release.
- **Found:** decision 0007 item 3 put Kestrel's `HttpParsingData` tables, and httpd's `http_strict.t` and lighttpd's `request.t` cases, in M2. No slice held them, and M2 closed without them. §14 puts them in M8.3's robustness lane.
- **Already done, though the sweep reported it open:** every entry into `responding` has armed the write deadline since M3.2 (`respond`), so the ledger's M2.1 item on the three error entries is settled.
- **Left open, and not sliced:** 0004 item 3's alternative; trimming a value once, in the core (0012's amendment); the lenient fixtures; CI's billing.

NEXT: the PR, on the owner's word: feat/m4-exit, the checks, the budget and the amendment. At the merge, M4 is complete.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **#57, the M4 exit,** as 21d041f.
- The squash tree (ecdcaf2) is identical to the tested tip's, cf6388b, and its parent is 64e9a3b.
- **CI.** The run (36330741760) was the billing block, the `linux` job with 0 steps.
- **Branches.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-five suites, 891 expected passes, exit 0.

M4 COMPLETE and merged (21d041f, PR #57): the libuv shell and the first real server. It took twelve PRs, #46 to #57, merged on 2026-09-26 and 2026-09-27. Among them, #50 and #51 are notes for M8, and #54 is the Host fix. The exit criteria are met on main:
- curl and ab get correct responses, and the counters return to zero (`tests/test-clients.sps`);
- the contract test passes (`tests/test-contract.sps`);
- the table is reconciled against `uv-loop-live-handles` in one place, `shell-run!`;
- the per-connection budget is re-measured and recorded, at about 18.2 KB per idle connection;
- plan §14 slices M5–M8. m4-mutations.md is complete, and `make check-imports` is clean.

The suite count went from M3's twenty-seven to thirty-five, adding clients, close-ownership, contract, exports, serve, server, shell and view.

NEXT: M5, timeouts and limits (plan §14):
- M5.1, the wheel and its two limits, `write-timeout-ms` and `tick-ms`;
- M5.2, the tick rows the core lacks;
- M5.3, one timer per loop, in both shells.

It starts on a fresh branch cut from main after this commit, when the owner asks.

M5.1 — THE WHEEL, AND ITS TWO LIMITS (plan §14 and §3; decision 0005 and its two amendments of 2026-09-27; design §2). Branches feat/m5.1-limits, cut from main at c14956c, and feat/m5.1-timing-wheel, cut from it; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m5-mutations.md, new.

Gathered before the first test, from plan §14, §3 and §9, decision 0005, and the ledger's M2.1 readings:
- plan §14: `(http-server wheel)`, pure: deadlines in `tick-ms` buckets, armed, disarmed and advanced to a `now` the caller gives. A deadline of D fires once, within [D, D + tick-ms], never before D. The plan's mutation: a deadline rounds down to its bucket's start;
- plan §3: `write-timeout-ms` (60,000 per write completion) and `tick-ms` (250) arrive with four things each, and `CHEZ_HTTP_TICK_MS` is read in milliseconds, which `docs/configuration.org` says beside it;
- 0005: the wheel is keyed by `(deadline div tick-ms)`, and the one tick timer per loop stops when the wheel is empty;
- M2.1's reading 2: the core arms kinds, not instants. So the wheel takes instants, and a shell adds the kind's limit to its now (M5.3).

Built first, then reviewed (`/code-review max`, 2026-09-27, before the first commit): a key API, in which the wheel kept its own table from key to entry, 15 checks, and the two limits with 5. Ten finder angles, one verifier for each of the 18 candidates, and a sweep:
- 11 confirmed, 5 plausible, 2 refuted, and 5 more from the sweep. The report held the 15 most severe.
- The wheel's logic held. Three reviewers ran it against a plain list of deadlines, up to 180,000 random operations, and it always agreed. The sweep also re-ran the 30 mutants recorded then, and every count matched.
- What they found was in the tests, the records, and what M5.3 will need.

DECIDED on the owner's word (2026-09-27), by form, the recommended answer to each of four questions:
- **The tick is 1 to 1,000 ms.** Every timeout is given in whole seconds, so a tick over a second would make one late by more than its own unit. Weighed: 2^64 − 1, the most libuv's timer takes (`uv_timer_start`'s `unsigned-64`; Chez's FFI raises above it, after the server listens), which still accepts a tick that never fires, since libuv clamps a timeout that overflows.
- **The wheel takes entries its caller keeps,** one per connection: a disarm then an arm allocates 0 B, where the key API's measured 96 B (an entry and its table cell, 48 B each), three times a keep-alive GET. Weighed: the key API.
- **Decision 0005 is amended:** the wheel fires by deadline, the tick's range, and the entries.
- **The other twelve findings are fixed as proposed,** the kind-to-limit mapping among them.

Found in review, and fixed on the owner's word:
- **Test gaps.** The first plain-list generator reached at most 32,767. A refusal counted whoever raised it, so an inexact deadline was refused by `vector-ref` after the table had changed. No row advanced to 0. No row accepted a 1 ms tick. And two setups sat outside their checks, so a raise there ended a suite as a harness error. Mutants P6, P7 and L12 survived the first suite and now die, and W and L15 now fail as checks, exit 1.
- **Records.** The design note's interval was half-open. 0005 still said a bucket fires once it expires. The wheel's header misdescribed the cursor after `now` went back. And the mutation log gave a false reason for running each mutant against its own suite: every mutant now ran against every suite.
- **For M5.2 and M5.3,** in plan §14's notes: the disarm at close, the first idle arm, the loop's clock, one mapping from kinds to limits, and each tick delivered under its own guard (the readings below).
- **Cut by the report's cap, six:**
  - the sort nothing consumes, about twice the work of a mass expiry: kept, and its order stays a promise;
  - the duplicated unlink, and the model's double filter: gone with the rework;
  - `wheel?` exported unused: kept, as six sibling predicates are;
  - 512 slots with a smaller tick, a few percent a tick: left to M5.3, which builds the wheel;
  - fixnum arithmetic: unsafe for the bignum deadlines the timeouts allow, and not material.
- **Refuted, two:** positional `make-limits` callers (none outside the library), and reusing uv-testing's generator (it exports bytes only).

M5.1 FIRST STEP — THE TWO LIMITS, AND HOW LONG EACH DEADLINE LASTS. Branch feat/m5.1-limits.
- `(http-server limits)`: `write-timeout-ms`, 60,000, from `CHEZ_HTTP_WRITE_TIMEOUT` in whole seconds, and `tick-ms`, 250, from `CHEZ_HTTP_TICK_MS` in milliseconds, 1 to 1,000. They are the sixteenth and seventeenth fields, after `linger-timeout-ms` with the other durations, each with plan §3's four things. Nothing reads them yet: M5.3's shells will. And `limits-deadline-ms`: how long each kind of deadline lasts, one mapping for both shells.
- `(http-server connection)`: `conn-deadline-kinds`, the five kinds the core arms, exported as its other vocabularies are.
- `tests/test-limits.sps`, 46 checks, 6 more than main's 40:
  - the two defaults;
  - the write and tick overrides, read inside their own check;
  - the tick's range: 1 and 1,000 accepted; 0, -1, 1,001 and a word refused;
  - each kind's own timeout, and `drain` refused.
  The variables' list, the drift guard and `limits-with`'s names are extended.
- `tests/test-connection-table.sps`, 3 checks more: the five kinds; the rows arm all five and no other; each lasts one of the limits.
- `docs/configuration.org`: the two variables, the tick's unit and range, and five timeouts not yet enforced.
- Decision 0005's first amendment of 2026-09-27: the tick's range.
- Watched to fail (m5-mutations.md, first step): L1 to L15, K1 and K2, one or more for every check the step added or extended. They ran against all thirty-five suites of the step's own tree and all thirty-six of the finished tree, with the same result.
- Every suite green on the step's own tree, a scratch worktree cut from main at c14956c: thirty-five suites, 900 expected passes (limits 46, connection-table 106), each exit 0. `make check-imports` is clean there.

NEXT: the second step, the wheel, stacked on this one.

M5.1 SECOND STEP — THE WHEEL. Branch feat/m5.1-timing-wheel, cut from the first.
- `src/http-server/wheel.sls`, `(http-server wheel)`, new and pure (`(rnrs)` only):
  - entries are the caller's: `make-wheel-entry key`, kept for as long as the key can have a deadline; `wheel-arm!` arms or moves one; `wheel-disarm!`; `wheel-advance!` returns the keys due by `now`, each disarmed, the earliest deadline first and equal ones in the order they were last armed; `wheel-entry-deadline`, `wheel-entry-key`, `wheel-count` (at 0 the shell stops its timer), `wheel-tick-ms`;
  - the index: bucket b in slot `(mod b slots)`, 512 slots unless given, each a doubly linked ring headed by a sentinel entry. A deadline whose bucket has passed is kept in the cursor's slot, the cursor being the furthest bucket reached. An advance visits the slots from the cursor's bucket to now's, each once at most;
  - it fires by each entry's deadline, never by its bucket; its instants are the loop's clock, `uv_now`, which never steps;
  - an unlinked entry's links are cleared, so an entry a connection keeps holds nothing of the wheel;
  - it refuses a tick or slot count below 1, an instant that is not an exact integer from 0, and what is not an entry, each by the procedure given it, before it changes anything.
- `tests/test-wheel.sps`, new, 18 checks:
  - when a deadline fires, a tick every 250 ms: at the first tick at or after it, row by row, on bucket boundaries and between them; every deadline from 1000 to 3000 ms once, within [D, D + 250), for ticks at three phases (the plan's interval row); an advance to 0; a deadline already past when armed;
  - one deadline per entry: fired once, disarmed and moved; what `wheel-entry-deadline` and `wheel-count` read;
  - an entry the caller keeps, disarmed or fired, holds nothing of the wheel. Weak pointers show it after a full collection, beside an entry still armed, which reads held;
  - the order an advance fires in; a deadline a revolution ahead; one advance over forty deadlines and five revolutions, set up inside its check;
  - the plain-list row: 4,000 operations, the same on the wheel and on a plain list, for six ticks and slot counts from 1 to 512. Its generator now reaches any bound. On the default wheel (tick 250, 512 slots) it arms 357 deadlines a revolution ahead and makes 176 advances over 512 buckets, where the first generator, capped at 32,767, made none (a scratch count);
  - the refusals, each checked to come from the procedure given it; and a refused arm leaves the entry and the count as they were.
- Records:
  - design §2's note: the wheel fires by deadline, within [D, D + tick-ms];
  - decision 0005's second amendment of 2026-09-27: fired by deadline, and entries each connection keeps;
  - plan §14's notes for M5.2 and M5.3 (the readings below).

MEASURED (scratch `wheel-alloc2.sps` and `wheel-cost2.sps`, two runs each, identical where they count bytes; cumulative `sstats-bytes`):
- entries the caller keeps, 1,000 armed, 100,000 operations each: making an entry 48 B, once a connection; a disarm then an arm, 0 B; moving a deadline, 0 B; an advance that fires nothing, 0 B;
- 10,000 entries at uv_now's scale, deadlines spread over 75 s, an advance every 250 ms until all fired: about 2 µs an advance (twenty runs, 12 and 13 ms of CPU), and about 81 B for each entry fired (807,200 B for 9,999: the list, its sort, the keys);
- the first allocation reading, 37.4 B, came from `bytes-allocated`, which is the live heap and drops at each collection; measured again with `sstats-bytes`, as the M2 spike does.

Readings, for M5.2 and M5.3 (plan §14's notes; flagged in the PR):
- M2.1's reading 2 left M5 to decide whether the core should also compare `now`. It need not. The wheel fires an entry only once its deadline has passed, so no tick reaches a connection early, and the core's kind guard (M2.1-D) stays as a defence.
- A tick to a closing or closed connection is already harmless: `on-tick` has no row for them. What is missing is the disarm. The core's close and hand-off clear the deadline without emitting `(disarm-deadline)`, so a closed connection would stay in the wheel, held there, until its deadline passed. M5.2 has them emit it. M5.3's libuv shell also disarms in `handle-close!` and `reconcile!`.
- A connection's first idle deadline is armed by no action: the state starts with `idle` recorded, and the core emits `(arm-deadline idle)` only after a write. M5.3 arms it at adoption, and a client that connects and sends nothing is its test.
- An advance returns its keys already disarmed, so M5.3 delivers each tick under its own guard.

A survivor, measured (M5.1-N): with the cursor never saved, the same keys fire, with more work. Twenty runs of the cost scenario took 157 and 161 ms of CPU, against 12 and 13 with the cursor: about 26 µs an advance against 2. The suite checks what fires, not the work: a scope statement.

Watched to fail (m5-mutations.md, second step): 29 mutants, each against all thirty-six suites:
- M5.1-A, the plan's, turns five wheel checks red, the interval row among them, and no other suite's;
- A2 to W, P1 to P10 and R, one or more for every check the step added;
- N survives, above.

`make test` green on the finished tree: thirty-six suites, 918 expected passes (wheel 18, limits 46, connection-table 106), exit 0. `make check-imports` is clean.

NEXT: two stacked PRs, on the owner's word ("commit it and open the two stacked PRs"):
- feat/m5.1-limits, the first step: 107 inserted lines of code and tests;
- feat/m5.1-timing-wheel, cut from it: 563, over plan §1 rule 1's ~400, since the wheel and its checks do not divide.
Then M5.2, the tick rows the core lacks (`body` answers 408, `responding` closes), with the disarm at close.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.1, as two stacked PRs.**
- **#58, the first step,** as b54c860. Its squash tree (64824e7) is identical to the tested tip's, 39e84c1, and its parent is c14956c. It merged first, keeping its branch, since #59 was based on it.
- **#59, the second step,** as 042260f. It was retargeted to main and rebased from #58's old tip. The rebased tip, 4986465, has the tested tree (9d3df90, d89ac4d's), and so does the squash, whose parent is b54c860.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36339388420 (#58), 36339406157 (#59 as opened) and 36339920482 (#59 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-six suites, 918 expected passes, exit 0.

M5.1 DONE and merged (b54c860, PR #58; 042260f, PR #59): the wheel, and its two limits.
- `(http-server wheel)` fires each deadline as `now` reaches it, and each connection keeps its own entry, so arming and disarming allocate nothing;
- `write-timeout-ms` and `tick-ms` (1 to 1,000) are limits, and `limits-deadline-ms` says how long each of the core's five deadline kinds lasts;
- decision 0005 is amended twice, and plan §14 carries the review's notes for M5.2 and M5.3.

NEXT: M5.2, every deadline the core arms has its tick row (plan §14): `body` past its deadline answers 408 and closes, and `responding` past the write deadline closes with no response. With them, per plan §14's note, the core's close and hand-off emit `(disarm-deadline)`. Then M5.3, one timer per loop in both shells. It starts on a fresh branch cut from main after this commit, when the owner asks.

M5.2 — EVERY DEADLINE THE CORE ARMS HAS ITS TICK ROW. Branch feat/m5.2-tick-rows, cut from main at 2dbef93.

Gathered: plan §14's M5.2 and its note of 2026-09-27; design §4.3's table of states and deadlines, and §4.4; decision 0005's table (on breach, body: 408 and close; write: close).

- `(http-server connection)`:
  - `body` past the body deadline answers 408, reads no more, and closes after the response in stages, as a head past its deadline does. The reason is `body-timeout`, and the 408 is framed for the request in flight: a HEAD's has no Content-Length;
  - `responding` past the write deadline closes at once, with no response: the client is not reading, so nothing more can be written to it. The close is logged, `(log write-timeout bytes)` with the bytes still outstanding, since nothing else would show it. It is `write-timeout`, whatever the connection would have closed for after its response. The write it cuts short is settled in `closing`, as a read error's is (M3.3's W5), and as the libuv shell reports a write its close cancels;
  - `draining`, entered from idle, carries the idle deadline, and past it closes as idle does: it had nothing in flight. It is the one draining row before M8, whose rows arm the write deadline there;
  - a tick clears the kind the state records, then acts: the wheel ticks a connection only as it lets its deadline go. So the record agrees with the wheel even where no row acts on the kind;
  - every close, and the hand-off, emits `(disarm-deadline)` first, armed or not (plan §14's note). The core cleared its record of the deadline there without saying so, which would leave a connection gone from the core in the shell's wheel until its deadline passed. Unconditional, as the core's other disarms are: a disarm with nothing armed is nothing to the wheel;
  - the comments: `on-tick`'s rows, `close`, the hand-off, and the header's deadline paragraph.
- `(http-server decisions)`: `body-timeout`, 408.
- `tests/test-connection-table.sps`, 119 checks (main's 106):
  - D1 to D4, the tick rows: the body's 408, a POST's and a HEAD's; the write deadline's logged close, and a 408 whose write stalls, which closes for `write-timeout`; draining's idle deadline; and a tick no row acts on, which leaves no deadline recorded. Each with its guard, and each outcome ends with the deadline recorded after;
  - T1, T2, T5, T7, L2, L3 and the fake shell's idle close now disarm first;
  - "after every row, the state records the deadline its actions leave armed", starting from nothing at a tick, since the wheel has let the deadline go. It would have caught the missing disarm, thirteen strays, and the stale record after a tick no row acted on;
  - "each deadline a row leaves armed, ticked in the state it leaves, moves the connection on": the slice's title as a check, over every (state, kind) a row leaves a connection in, armed there or carried in. It found draining's carried idle deadline, and a future row that leaves a kind where no tick row acts on it goes red (O);
  - each group's rows now run before its count is checked, and a raise while building them prints its cause (found on the way, below).
- `tests/test-connection-deadlines.sps`, new, 6 checks: each of the five kinds reached on a fake connection as a client reaches it, the kind read, then passed at its own limit, decision 0005's default, which the row states. Idle after a response closes; a head or a body left unfinished gets 408, then the staged close; a response the client never reads, its completion never delivered, is logged with its 77 bytes and closed, and the write settles; a linger closes. And a row for each kind.
- `tests/test-connection-originated.sps`, 21 checks (main's 20): the body's 408 end to end, read back by chez-httparse; every row's staged close ends with the disarm.
- `tests/test-connection-linger.sps` (9) and `tests/test-decisions.sps` (52): the closes' disarm; `body-timeout`'s 408, and `write-timeout` among the reasons with no status.
- `tests/read-back.sls`: `shown`, a write as its status, shared by the response, linger, originated and deadlines suites, where three copies were.
- Records:
  - design §4.4's amendment of 2026-09-27;
  - plan §14's notes for M6.2, M6.3 and M6.4 (below);
  - docs: responses.org's 408 row gains the body, and connections.org gains "Clients that stall", marked from M5, with the Expect case.

Reviewed (`/code-review high`, 2026-09-27, before the first commit): eight findings, all taken on the owner's "fix all eight":
- **A tick left a stale record.** A tick no row acted on kept the kind it found, though the wheel had let it go. Draining kept idle's. Now every tick clears it (D4, X).
- **The moves-on check read only arms,** so it missed the idle deadline T8 carries into draining. It now reads every state a row leaves, and draining got its row (D3, W).
- **Expect: 100-continue.** Until M6.4 the server never sends `100 Continue`, and a client that waits for it is answered 408 once the body deadline passes, though the server is the one waiting. Kept, not changed: without the deadline, a request that expects the 100 and never sends its body would hold its connection with no bound. Plan §14 has M6.4 arm the body deadline when the 100 is written, and connections.org says so.
- **The count guard swallowed a raise's cause.** It now prints the group and the condition. A raise from the core while rows are built still fails the group's count, exit 1, as M5.1's review had setups that raise fail as checks.
- **A write-timeout close was invisible.** It is now logged with the bytes outstanding. An idle close stays unlogged, as a client's own close is: a keep-alive connection going idle is the normal case.
- **D1 could not tell its request's framing.** A HEAD instance now shows it (Y).
- **The deadlines suite's clock was inert.** Each row now states the instant its deadline passed (Z).
- **`shown` was in three copies.** It is now one, in `(read-back)`.

Watched to fail (m5-mutations.md, M5.2): twenty-six mutants, A to AA, each against all thirty-seven suites of the finished tree. M5.2-A, the plan's, turns the write rows red: D2 in the table, the moves-on check, and the end-to-end write row. Every check the slice added or changed is reddened by one at least.

Found on the way: SRFI-64's simple runner names a failing check after the last check run inside its expression (scratch `nested-label.sps`, measured). Six of the table's count checks ran their rows inside themselves, so a count that fell failed under a row's name. Each group's rows now run first. No earlier mutation log misnames one.

Notes for M6 (plan §14):
- The body deadline's 408 assumes the client is the one stalling and no handler has answered.
- In M6.2, while reading is stopped for a handler's credit, the body deadline must not run.
- In M6.3, once a handler's head is on the wire, a stalled body gets a bare close.
- In M6.4, the body deadline of a request that expects the 100 starts when the 100 is written.

`make test` green on the finished tree: thirty-seven suites, 938 expected passes (connection-table 119, connection-deadlines 6, connection-originated 21), exit 0. `make check-imports` is clean. The allocation gate's GET is 1,840 B a request, as on main: a keep-alive request never closes. Size: 449 inserted lines of code and tests, past plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-27), by form: one PR. The disarm, the tick's clearing and the tick rows share the table suite's rows and derived checks. Weighed: two stacked PRs by layer, each proved green on its own tree.

NEXT: the PR, feat/m5.2-tick-rows. Then M5.3, one timer per loop in both shells.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.2, as one PR.**
- **#60** as 9edbe49. Its squash tree (e467aa5) is identical to the tested tip's, 3f67729, and its parent is 2dbef93.
- **CI.** The one run, 36344049731, was the billing block: the `linux` job with 0 steps, "The job was not started because recent account payments have failed or your spending limit needs to be increased."
- **Branches.** feat/m5.2-tick-rows deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 938 expected passes.

M5.2 DONE and merged (9edbe49, PR #60): every deadline the core arms has its tick row.
- a stalled body is answered 408, a stalled write closes with a log line, and a connection draining from idle closes past its idle deadline;
- a tick clears the deadline the state records, and every close and the hand-off disarm first, so the core and the wheel agree on every row, which the table checks;
- plan §14 carries notes for M6.2, M6.3 and M6.4, the Expect case among them.

NEXT: M5.3, one timer per loop in both shells (plan §14, and its notes of 2026-09-27). It starts on a fresh branch cut from main after this commit, when the owner asks.

M5.3 — ONE TIMER PER LOOP, IN BOTH SHELLS. Three stacked branches: feat/m5.3-fake-wheel, cut from main at 6fe18eb; feat/m5.3-shell-timer, cut from it; feat/m5.3-contract-deadlines, cut from that. 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

Gathered: plan §14's M5.3 and its notes of 2026-09-27; decision 0005 and its two amendments of that day; design §2's wheel note, §4.6's server events, and §8.4 and §8.5.

- `(http-server private shell)`, as it stands after the review below:
  - **the wheel.** One per shell, and one entry per connection, made as it is adopted. `arm-deadline` arms the entry at the loop's now, `uv_now`, plus the kind's limit (`limits-deadline-ms`), and `disarm-deadline` takes it out. No action arms a connection's first deadline, its idle one, so the shell arms it at adoption. A connection already closing is armed no more;
  - **the timer**, as 0005 has it:
    - one per shell, made at the first arm and firing every tick-ms;
    - stopped by the first firing that finds the wheel empty, so an idle server sleeps, and started again by the next arm (`uv-timer-again!`);
    - kept between busy periods, and closed once the shell has stopped listening and has no connection left.
    Each firing advances the wheel to the loop's now and ticks each connection whose deadline passed, each under its own guard, since the wheel has let them all go. It then tells the server the time, design §4.6's `(tick now)`, which asks for nothing yet. Once every tick is delivered, the first raise goes on and the run loop logs it. A later byte-machine contract condition goes on in its place, since the run loop keeps that one fatal;
  - **the loop's clock.** It is brought up to date as each handler returns: libuv reads `uv_now` once a turn, and a handler holds the loop. This is a workaround carried until chez-libuv #28 lands (decision 0008), and it calls `uv_update_time` through chez-libuv's private loop pointer;
  - **leaving the wheel.** handle-close! and the reconciliation take a connection out of the wheel: the two ways a connection leaves the table with no step of the core;
  - `shell-timer`, `shell-deadlines` and `connection-deadline`, which the socket lane reads.
- `tests/fake-shell.sls`: a fake connection keeps its deadline in a wheel of its own.
  - It arms at the fake clock's now plus the kind's limit, the idle deadline as it is made, at an instant its caller may give (a fourth argument).
  - `fake-shell-fire!` is its timer firing at the clock's now, and ticks the connection only once its deadline has passed. `fake-shell-tick!` delivers the raw `(tick now)` to any step, as before M5.3, and firing a stub step's shell is refused.
  - The linger, originated and deadlines suites, and the contract's replay, fire.
- `tests/test-connection-deadlines.sps`, 8 checks (main's 6):
  - every row's connection is made at 1,000 ms, not 0, so a deadline armed at its limit alone shows;
  - a firing a millisecond before the deadline asks for nothing;
  - a client that sends nothing is closed at the idle deadline its connection was made with;
  - a connection its client closed is ticked no more.
- `tests/test-fake-shell.sps`, 20 checks (main's 19): firing a stub step's shell is refused.
- `tests/test-shell.sps`, 79 checks (main's 65). The deadline clients run on a shell of their own with short limits (head 200 ms, idle 250, linger 300, tick 10), adopted through the suite's listener:
  - one that sends half a head reads 408, then the stream's end, and is closed once its linger passes;
  - an idle keep-alive connection is closed;
  - a lingering client that never closes is closed;
  - one that connects and sends nothing is closed at the idle deadline armed as it was adopted;
  - each deadline is met at the first time the timer fired at or after it: the instant it was armed, read where it was armed, plus the suite's limit. The firings are the server's ticks in the trace, and one must come at the tick's own instant;
  - after a handler that holds the loop 300 ms, past the idle limit, the deadline armed after its answer is still ahead;
  - a connection closed from outside the core just as a deadline is armed leaves with none armed;
  - with its wheel empty, the timer stops, firing at most once more in fifty turns of the loop, and the shell keeps it;
  - two connections adopted in one callback share a deadline, and the kept timer, started again, ticks both at one firing. Both ticks raise, the second with byte-machine's contract condition. Each is still ticked and closed, and the contract condition is the raise the run loop raises again;
  - four connections that send nothing, on a shell under 0005's limits, add one timer to the loop, repeating every tick, and chez-libuv counts one more;
  - a failed adoption leaves no deadline armed; the reconciliation takes the connection it drops out of the wheel;
  - a shell shut down with no connection left closes the timer it kept: `bad`'s, `quick`'s and the suite's own before the end's checks.
- `tests/test-contract.sps`, 35 checks (main's 28): two scripts whose deadlines pass on a shell with short limits:
  - a head never finished: 408, then the linger;
  - a client that sends nothing: the idle deadline armed at adoption.

  Each event is replayed with the loop's time it came at. The fake is made at the adoption instant, or at 0 when nothing was adopted (a check), and a tick is the fake's own timer firing then. The libuv shell's wall clock here is the loop's own, so both shells make each Date and arm each deadline at the same instant (ONE CLOCK).
- `tests/test-clients.sps`, 11 checks as before: an idle server holds the listener and the timer it keeps.
- Records:
  - design §2's, §8.4's and §8.5's notes;
  - plan §14's notes for M6.2 and M8, and the M5 exit's docs item marked done;
  - decision 0008's chez-libuv #28 row;
  - docs: the "from M5" notes gone from README, connections.org, responses.org and configuration.org, and the timeouts said to be acted on.

MEASURED (scratch spikes, two runs or more each, Darwin arm64):
- `arm-alloc.sps`, cumulative `sstats-bytes`: a disarm then an arm made as the shell makes them, `uv_now` plus the kind's limit into `wheel-arm!`, allocates nothing beyond the measuring loop's own. That is 160 B over a million calls, as an empty thunk and `uv-now` alone read;
- `stale/update-cost.sps`: `uv_update_time` through the private loop pointer, 14 to 15 ns a call and 0 B, over a million calls; `uv-now` 7 to 8 ns;
- `stale/stale-now2.sps` and `stale-now3.sps`, a handler that holds the loop 300 ms, before the refresh and after it:
  - a keep-alive connection with a 250 ms idle timeout was gone within 100 ms of its answer, and stayed idle with the refresh;
  - a 512 KiB answer under a 200 ms write timeout was cut off at 327,212 bytes, logged `write-timeout`, three runs of three, and arrived whole, 524,368 bytes, with the refresh;
  - a 4 MiB answer outlasted the 200 ms write timeout either way, so it showed nothing;
  - the first spike, a 77-byte answer, showed nothing either way. libuv 1.52 runs its timers at the end of a turn, after the poll's callbacks, so a write that completes at once replaces the stale deadline before any timer reads it.

Watched to fail, the first round (m5-mutations.md, M5.3):
- red before green, the tests edited and the shells as on main: connection-deadlines 6 (every early tick acted), shell 10, contract 1;
- then twenty-seven mutants, A to Z and Z2, each against all thirty-seven suites. M5.3-A, the plan's, a timer per armed deadline, turns the one-timer check red, and chez-libuv's count with it. Every check the slice added or changed is reddened by one at least;
- two survive, each a scope statement:
  - E, the libuv shell's disarm performed as nothing. Every v1 disarm is followed by an arm or a close, which disarms too, and M6.2's credit wait is its first check;
  - Y, the replay's fake made at 0. The replay ticks the fake only where the libuv shell ticked, and the deadlines suite holds the fake's start instant (T).

Found on the way:
- the guard check's first run failed on the test's own argument order: `(first-logged)` was evaluated before the run that makes it, as M5.2's `ticked` did (spike-harness pitfalls). It binds the run first now;
- mapping each check to a mutant before the run found four checks that could not fail, and each was strengthened then:
  - the on-time check was vacuous without the server's tick;
  - the short limits were equal;
  - nothing showed a connection leaving the wheel with no step of the core;
  - a closed fake connection's tick asked for nothing (m5-mutations.md).

Timing, not a stopwatch: the lane's deadlines pass in the loop's own time. A check that a tick came within tick-ms of its deadline would fail whenever the loop ran late, which libuv's repeating timer allows, since each firing re-arms from the loop's time then. So the check reads the trace instead: a deadline is met at the first time the timer fired at or after it, and the timer's repeat is tick-ms. The socket lane and the contract ran twenty-four times, eight at a time, all green: before the review and again after it.

Reviewed (`/code-review high`, 2026-09-27, before the first commit): ten findings, all fixed on the owner's "fix all ten". Finding 3 was settled by form: a carried workaround and an upstream ask, chez-libuv #28.
1. **The contract replay crashed when a client never connected.** It made the fake at the adoption time, which stays #f then. The fake is now made at 0 when nothing was adopted, and a check replays with nothing adopted. A scratch copy that plays a script to a port where nothing listens ended as a harness error, exit 2, before the fix. After it, the script fails by name, with ECONNREFUSED, exit 1.
2. **`arm!` could arm a connection already closing.** It now skips one, as `read-start!` does. A check closes a connection from outside the core just as its idle deadline is armed, through the trace's `closing-at`. The connection leaves the table with none armed. Before the fix it left armed: `(satisfied 2361711061 1)`.
3. **Deadlines were armed from a stale `uv_now` after a slow handler.**
   - Measured first. A handler that held the loop 300 ms had its 512 KiB answer cut off at 327,212 bytes under a 200 ms write timeout, three runs of three. It also closed a keep-alive connection with a 250 ms idle timeout at once.
   - DECIDED on the owner's word, by form: the shell calls libuv's `uv_update_time` after each handler, through chez-libuv's private loop pointer, 14 to 15 ns and 0 B a call. chez-libuv #28 asks for `uv-update-time!`, and decision 0008's table carries the row.
   - The socket lane's `/slow` check. Before the fix, the connection was already closed when its client had the answer.
4. **`tick!` kept only the first raise.** A later byte-machine contract condition now goes on in its place, since the run loop keeps that one fatal. The pair check raises from both ticks, the second with the contract condition.
5. **The one-timer check raced the 200 ms head deadline.** It now counts the timers four connections add, on a shell under 0005's limits, where no deadline can pass while the suite looks.
6. and 7. **The timer's lifetime** now follows 0005 to the letter:
   - made at the first arm;
   - stopped by the first firing that finds the wheel empty, and started again by the next arm (`uv-timer-again!`);
   - kept between busy periods, and closed once the shell has stopped listening and has no connection left.
   The checks: the timer stops (at most one firing in fifty turns of the loop) and is kept (the same handle); the pair's deadlines start it again; and a shell shut down with no connection left closes it (`bad`'s, `quick`'s and the suite's own). test-clients now finds the listener and the shell's timer on an idle server.
8. **Pairing could leave a held handle.** It is closed once the pairing wait ends without its pair.
9. **Docs.** The "from M5" notes are gone from README, connections.org, responses.org and configuration.org, so the M5 exit's docs item is done.
10. **`fake-shell-tick!` had two meanings.** `fake-shell-fire!` is now a fake connection's timer, and `fake-shell-tick!` delivers the raw tick to any step. Firing a stub shell is refused, which a check holds.

Watched to fail, after the review (m5-mutations.md, M5.3 after its review): each fix's check was red first, but three, each shown otherwise:
- finding 8's by a scratch copy;
- the stub's refused firing, and the timer's lifetime rewritten with its fix, by the mutants that restore the tree before the review.

Then thirty-five mutants, each against all thirty-seven suites. M5.3-A, the plan's, still turns the one-timer check red. Every check the review added or changed is reddened by one at least, and E and Y survive as before.

`make test` green on the finished tree: thirty-seven suites, 962 expected passes (shell 79, contract 35, fake-shell 20, connection-deadlines 8), exit 0. `make check-imports` is clean. Size: 794 inserted lines of code and tests (206 deleted), past plan §1 rule 1's ~400. Three layers, each meant to be green on its own tree:
- the fake shell's wheel, with its suites, 149;
- the libuv shell's wheel and timer, with the socket lane and the clients, 500;
- the contract's deadline scripts, 145.

DECIDED on the owner's word (2026-09-27), by form: three stacked PRs, each layer proved green on its own tree before it is committed. Weighed: two stacked PRs, both shells then the contract (649 and 145), and one PR (794).
- **feat/m5.3-fake-wheel**, the fake shell's wheel: `tests/fake-shell.sls` and its suites (deadlines, fake-shell, linger, originated), 149 inserted lines;
- **feat/m5.3-shell-timer**, the libuv shell's wheel and timer: `(http-server private shell)`, the socket lane and the clients, 500. With them go the records the code cites: decision 0008's chez-libuv #28 row, the docs, design §2's and §8.5's notes, and plan §14's notes;
- **feat/m5.3-contract-deadlines**, the contract's deadline scripts, 145, with design §8.4's note, this ledger entry and the mutation log.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the M5 exit, whose docs item is done.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **M5.3, as three stacked PRs.**
- **#61, the fake shell's wheel,** as 1e87251. Its squash tree (eae845b) is identical to the tested tip's, 85d8d60, and its parent is 6fe18eb. It merged first and kept its branch, since #62 was based on it.
- **#62, the libuv shell's wheel and timer,** as 593d7bc. It was retargeted to main and rebased from #61's old tip. The rebased tip, 447c37b, has the tested tree (542ea72, 313e14f's), and so does the squash, whose parent is 1e87251. It kept its branch for #63.
- **#63, the contract's deadline scripts,** as 791852f. It was retargeted and rebased from #62's old tip, 313e14f. The rebased tip, 9ce1bf3, and the squash have the tested tree (2fbce0e, e5356d9's), and the squash's parent is 593d7bc.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36350300156 (#61), 36350323606 (#62 as opened), 36350340863 (#63 as opened), 36353017190 (#62 rebased) and 36353077286 (#63 rebased).
- **Branches.** All three deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 962 expected passes.

M5.3 DONE and merged (1e87251, PR #61; 593d7bc, PR #62; 791852f, PR #63): one timer per loop, in both shells.
- The libuv shell keeps its connections' deadlines in one wheel. One timer ticks it: it stops when the wheel empties, and the shell keeps it. The socket lane closes each stalled client at the first firing at or after its deadline.
- The fake shell's timer is the test's, and the contract replays deadlines across both shells.
- The loop's clock is brought up to date as each handler returns, a workaround carried until chez-libuv #28 lands (decision 0008). The pin then moves, and the workaround goes.

NEXT: the M5 exit (plan §14):
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

Its docs item is done. It starts on a fresh branch cut from main after this commit, when the owner asks.

UPSTREAM LANDED (2026-09-27): chez-libuv v0.7.0 is tagged (ed30206, 17:46 -0400; annotated tag 1ff5265). #28, filed that day at M5.3's review on the owner's form, closed via PR #29 (d769da0). PR #30 documents `(libuv async)` and the one-thread-per-loop rule, and the release is PR #31. `uv-update-time! : uv-loop -> unspecified` is on `(libuv loop)`, re-exported from `(libuv)`:
- it refreshes the loop's cached clock, `uv-now`, from libuv's;
- it is legal while the loop runs, and runs nothing, not even a timer already due;
- it is checked for the loop's thread, `&uv-wrong-thread` off it, since it writes the clock the loop thread rewrites each turn (its ADR-0019). `uv-now` stays unchecked.

Between the tags, the library path gains that verb alone: its binding in `(libuv private native)`, the verb in `(libuv loop)`, and their exports, the facade's included. Every other change under `src/` is a comment. The C shim and `tests/uv-testing.sls` are byte-identical, and chez-libuv's own test-loop and test-facade gained checks.

The pin moves from v0.6.0 to the v0.7.0 tag, on a commit of its own (branch chore/chez-libuv-v0.7.0): `vendor/chez-libuv` is at ed30206. Watched to fail:
- with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2);
- with the pin moved and nothing else, the shell no longer loads. The facade now exports `uv-update-time!`, the name of the shell's workaround, and Chez refuses the library: `multiple definitions for uv-update-time! in body`. Five of the 37 suites failed, each because it loads the shell: clients, contract, serve and shell exited 255 on Chez's refusal, and exports, which loads the shell through the facade inside a check, failed that check (exit 1). This is the red decision 0008 asks a carried workaround to turn when its ask lands.

So the pin's commit imports `(except (libuv) uv-update-time!)`, keeping the workaround as it was, and the next commit drops it for the facade's verb. With that one line, `make test` is green at the new pin: thirty-seven suites, 962 expected passes, exit 0.

Smoke evidence (`.plans/research/spike/smoke-libuv-v070.sps`, Darwin arm64, Chez 10.4.1, libuv 1.52.1, on the Makefile's LIBDIRS; exit 0 on both runs, `out/smoke-libuv-v070.run{1,2}.txt`; run 2 in full, and run 1 differs only in CPU times):

    (a) after a 100 ms hold, uv-now had moved (expect 0): 0
        after uv-update-time!, it had moved (expect 100 or more): 100
        a 10 ms timer, due, had run during the call (expect #f): #f | and ran after it (expect #t): #t
    (b) a 150 ms timer armed after the hold, without the refresh, fired after (expect about 50): 51
        with the refresh (expect 149 or more: libuv's clock counts whole ms): 151
    (c) off the loop's thread (expect wrong-thread uv-update-time!): (wrong-thread uv-update-time!)
    (d) eight rounds of a million calls each, the order rotated; ns per call sorted, least, median, and bytes per call:
        uv-update-time! (15 16 16 16 16 16 16 27) least 15 median 16.0 bytes (1.6e-4)
        the workaround  (14 14 14 14 14 14 15 18) least 14 median 14.0 bytes (1.6e-4)
        uv-now          (7 7 7 7 7 7 7 8) least 7 median 7.0 bytes (1.6e-4)
        nothing         (2 2 2 2 2 2 2 2) least 2 median 2.0 bytes (1.6e-4)
    done

Reading:
- (a) and (b) are #28's claim. The refresh moves the clock by the hold and runs nothing, and a 150 ms timer armed after it fires on time, where without it the timer fired 99 ms early.
- (c) is the one behaviour the workaround did not have. The shell calls the verb only from its callbacks, on the loop's thread.
- (d): eight rounds with the order rotated, so each row is measured first in two of them. In both runs the verb's median is 16 ns a call (least 15), 2 ns over the workaround's 14 (least 14). By its source, the difference is its two checks, that the loop is open and that the caller is on its thread. Three rows have one slow result of their eight, 8 to 29 ns in the two runs, which the medians set aside. It allocates nothing: every row, the empty loop's too, reads the same 160 B over a million calls, the measurement's own.

The workaround goes in the commit after the pin's. The shell imports `(libuv)` whole again, and `call-handler!` calls the facade's `uv-update-time!` where it called its own. Its definition is gone, and with it the shell's two reaches past chez-libuv's surface: `foreign-procedure` from `(chezscheme)`, and `loop-pointer` from `(libuv private handles)`. No library under `src/` imports a chez-libuv private library now; two suites still read its dev counters through `(libuv private native)`. Watched to fail: with the refresh removed from `call-handler!`, test-shell failed one check, "after a handler that holds the loop 300 ms, the idle deadline armed after its answer is still ahead when the client has it" (78 passes, 1 failure, exit 1). With the facade's verb it passes, 79. `make test` on the two commits' tree: thirty-seven suites, 962 expected passes, exit 0.

DECIDED on the owner's word (2026-09-27), by form: two stacked PRs, each layer proved green on its own tree before it is committed. Weighed: one PR, 198 lines inserted and 21 deleted, whose squash would fold the pin into the drop; and review first, both left uncommitted.
- **chore/chez-libuv-v0.7.0**, the pin alone: the gitlink, the Makefile's `LIBUV_PIN`, the shell's import leaving out the facade's new name, global-constraints, decision 0008's #28 row and dated note, the research README, test-integration's version comment, the spike and its two runs, and this entry up to its smoke evidence. 199 lines inserted and 11 deleted, besides the gitlink;
- **refactor/uv-update-time**, the workaround dropped, and this entry's rest: 10 inserted, 17 deleted (the form weighed 6 and 17, before this decision's own lines).

Reviewed (`/code-review high`, 2026-09-27, after the PRs opened): six findings, all fixed on the owner's "fix all six".
1. **The clock was refreshed only after a handler** (#65). A deadline armed after any other hold of the loop, the shell's own work, a collection, or the work before an adoption, still started from the turn's cached time. The shell now brings the clock up to date as it adopts a connection, and in `run!` before each arm and each write, ahead of the action's trace. So the trace reads the time the action does, and the deadlines' on-time checks stay exact.
   - Not inside `arm!`, as the finding put it: that refresh would come after the trace, and a response's write runs before its arm, so its Date after a slow handler would read the stale clock.
   - A keep-alive GET's trace shows four arms (header, body, write, idle) and one write: five refreshes, about 80 ns at the spike's 16 ns median, where the handler's refresh was one. Each adoption adds one.
   - Three checks written first: the shell's own work holding the loop before an idle arm, and the work before an adoption, both red on the old tree; and a Date written after a slow handler, green there, since the handler's refresh dated it. Five mutants, each killed (`m5-mutations.md`).
   - The contract's ONE CLOCK note said both shells make each Date and deadline at the same instant, untrue since M5.3's refresh. It now says the libuv shell's are that instant or a moment later: its deadlines never earlier than the fake's, and its Dates the fake's unless a second begins in that moment, a small chance of a mismatch left as it was.
2. **No check held that `src/` imports no chez-libuv private library** (#65): `make check-imports` now refuses one, watched red with the workaround's import put back.
3. **The spike measured the verb first in every round** (#64): part (d) now rotates the order over eight rounds. In both runs the verb's median is 16 ns (least 15) against the workaround's 14, so the 2 ns is the verb's, and the records quote the medians.
4. **The refresh could raise between the handler and its answer** (#65), `&uv-wrong-thread` off the loop's thread, dropping the answer. The refresh has left `call-handler!`: the answer is dispatched first, and the refresh runs with the actions, where every chez-libuv verb the shell calls is checked the same way. The shell's header now says it runs only on the loop's thread (decision 0003).
5. **"The four that load the shell, and exports"** (#64): exports fails because the facade loads the shell, and decision 0008's note, this entry and the PR now say so.
6. **The spike stopped at the first raise** (#64): each part now names how it failed, a raise, a callback that never ran or a thread that never answered, and the program goes on.

`make test` on #64's tree: thirty-seven suites, 962 expected passes, exit 0. On #65's: thirty-seven suites, 965, exit 0.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then the M5 exit, on the merged tree.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **chez-libuv v0.7.0, as two stacked PRs.**
- **#64, the pin,** as 7c4f6d3. Its squash tree (a6c97d2) is the tested tip's, ad36839's, and its parent is 21c1fec. It merged first and kept its branch, since #65 was based on it.
- **#65, the workaround dropped and the clock refreshed wherever it is read,** as 946b500. It was retargeted to main and rebased from #64's tip, ad36839. The rebased tip, be6d372, has the tested tree (5608788, b63d828's), and so does the squash, whose parent is 7c4f6d3.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36354385484 (#64 as opened), 36354393588 (#65 as opened), 36355718381 (#64's review fixes), 36356253988 (#65's review fixes) and 36356693057 (#65 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `fix/contract-write-instants`, the contract's Date comparison in a session of its own, started from #65's tip before the merge, b63d828, and was left alone.

`make test` green on main: thirty-seven suites, 965 expected passes.

DONE and merged (7c4f6d3, PR #64; 946b500, PR #65): chez-libuv is pinned at v0.7.0.
- The shell calls chez-libuv's `uv-update-time!` as it adopts a connection, and before each arm and each write, and its workaround is gone.
- No library under `src/` imports a chez-libuv private library, which `make check-imports` holds.
- All twenty filed asks have landed; nothing is open upstream.

NEXT: the M5 exit (plan §14), on a fresh branch cut from main after this commit, when the owner asks:
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

The contract's exact Date comparison runs in its own session on `fix/contract-write-instants`, which will want rebasing onto main.

THE CONTRACT'S DATES, MADE EXACT. Branch fix/contract-write-instants, cut from #65's tip, b63d828, before #64 and #65 merged, and rebased onto main at 1fc6dc9 once they had. #65's squash, 946b500, has b63d828's tree, so the code under test is the same. 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

The flake. Since #65 the libuv shell brings the loop's clock up to date before each write, and dates the write then. The contract's fake dated its write at the instant of the event the replay last gave it: the loop's time where the trace saw that event. The two differ by the turn's work, tens of microseconds. So the Dates differed, and "the client read the bytes the fake shell wrote" failed, whenever a second began in between. #65's review had left that chance in the ONE CLOCK note.

- `tests/test-contract.sps`:
  - the trace hook records the loop's time at each write the libuv shell's connection runs. The shell calls the hook once the clock is up to date, so the time is the write's own;
  - the replay hands those instants to the fake, in order. The fake's clock, and so its deadlines, stay at the events' instants, never later than the libuv shell's, so the fake still ticks wherever the libuv shell ticked;
  - a script, "two requests in one write, the second answered in the next second". The libuv shells call the handler through `held-handler`, which holds the loop into the next second for `/next-second`: the rest of the second the loop's clock reads, and 5 ms more, by Chez's monotonic clock. The loop's own clock is left alone, so the shell's refresh before the write is the first to read the next second. The fake calls the handler itself, since its clock stands still while the handler runs;
  - the ONE CLOCK note says so.
- `tests/fake-shell.sls`: `fake-shell-date-writes!` dates a connection's next writes at the instants it is given, one each, in order. Once they run out, a write is dated at the clock's now, as every write is when none is given.
- `tests/test-connection-response.sps`: a check that writes given instants are dated at them, in order, then at the clock: RFC 9110's example instant, a second and two seconds on.
- Design §8.4: a dated note. Its M5.3 note said both shells write each Date and arm each deadline at the same instant, untrue since #65.

Weighed: moving the fake's clock to each write's instant, mid-turn, which would make its deadlines the libuv shell's too. The replay would then walk events the fake has already passed, whose instants are earlier, and the fake's clock never runs backwards.

Watched to fail (m5-mutations.md, the contract's Dates):
- red before green: contract 1, three runs of three, the fake dating each write at its clock: `(differs-at 47 49 50)`, the Date's last digit a second behind. That was the script's first form, one request held; the final form's red is dates-A's. And connection-response 1, against a stub that kept the instants and dated each write at the clock;
- then eleven mutants, and three of M4.4's run again, each against all thirty-seven suites. Every check added is reddened by one at least;
- two calibrations survive, as meant. Without the hold, the script cannot tell (dates-I). A hold that refreshed the loop's clock would hide a trace that reads the time before the refresh (dates-J), which only the socket lane's check would then catch.

Measured (this tree, Darwin arm64):
- the contract suite alone, three runs: 2.27, 1.99 and 1.99 s real, 38 passes, where it took 1.49 s before the script, 35. The hold is the rest of a second: half a second on average, a second at most;
- sixteen runs, eight at a time: all green, 38 passes each, 2.85 to 2.97 s real. The eight of a batch finish together, since their holds end at the same second of the loop's clock, the machine's uptime.

`make test` green: thirty-seven suites, 969 expected passes (contract 38, connection-response 24), exit 0. Size: 123 inserted and 43 deleted lines of code and tests, one PR.

DECIDED on the owner's word (2026-09-27), by form:
- **the script stays in the suite**, at half a second a run on average. Weighed: a scratch copy only, as the brief suggested, which would leave dates-A, G and H surviving: the replay could stop handing the fake its instants, or hand them out of order, and nothing would notice;
- **one commit, and a third PR stacked on #65**, based on refactor/uv-update-time. Weighed: the PR once #64 and #65 have merged, rebased onto main; and a review first, left uncommitted. #64 and #65 merged while the form was open (7c4f6d3, 946b500; reflect 1fc6dc9), so the commit sits on main and its PR is based there.

NEXT: the PR, merged on the owner's word. Then the M5 exit (plan §14), as the NEXT above has it.

MERGED to main on 2026-09-27, on the owner's "do closing ritual": **the contract's Dates made exact, as #66,** as c694cc6. Its squash tree (f28cd51) is the tested tip's, 68a1b5c's, and its parent is 1fc6dc9.
- **CI.** Its one run was the billing block, the `linux` job with 0 steps: 36358148109.
- **Main.** The shared checkout held `main`, clean, and was fast-forwarded there (`merge --ff-only`), once after the squash and once after this commit. This worktree was left detached at `main`.
- **Branch.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-seven suites, 969 expected passes.

DONE and merged (c694cc6, PR #66): the contract's fake dates each write at the instant the libuv shell's trace saw it, so the two shells' Dates are compared exactly. A script that holds a request into the next second keeps it so.

NEXT: the M5 exit (plan §14), on a fresh branch cut from main after this commit, when the owner asks:
- the brief's exit checked on the merged tree: fake-clock table tests, slow clients closed within a tick of their deadlines, and no timer handle per connection;
- the budget spike run again with deadlines armed, so a connection's wheel entry is priced.

M5 EXIT (plan §14). Branch feat/m5-exit, cut from main at 2f730a1; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m5-mutations.md, "The M5 exit".

Gathered before the first test, from the brief's M5 and plan §14:
- the brief's exit: fake-clock table tests; slow-client socket tests, slowhttptest's shapes, closed within a tick of the deadline; no per-connection timer handle;
- plan §14: the budget spike run again with deadlines armed, so a connection's wheel entry is priced. Its docs item was done in M5.3.

Met before this branch, each with its check:
- fake-clock table tests: `tests/test-connection-table.sps` (each deadline a row leaves armed, ticked in the state it leaves, moves the connection on; each tick row has a test), `tests/test-connection-deadlines.sps` (a row for each kind), `tests/test-wheel.sps` (a deadline of D fires within [D, D + tick-ms], never before) and `tests/test-connection-linger.sps`;
- one timer, none per connection: the socket lane's "four connections open on one shell add one timer to the loop", which M5.3-A reddens, and test-clients' idle server, which holds the listener and that timer;
- slow clients closed within a tick: the socket lane's four M5.3 clients (half a head, an idle keep-alive connection, a lingering client, one that sends nothing), each met at the first firing at or after its deadline.

Missing, of slowhttptest's shapes (its slow headers, slow body and slow read; its range attack does not apply): a head sent a piece at a time, a body sent a piece at a time then stopped, and a client that never reads. The half head is slow headers' simplest form, but no socket check held what 0005 says of the pieces: a head's never move its deadline, armed once at on-message-begin, and a body's each arm it again.

BUILT:
- `tests/test-shell.sps`, 85 checks (main's 82). The deadline shell's limits gain a body, 175 ms, and a write, 225 ms, each its own:
  - slow headers: a client that sends its head in five more pieces, one every 60 ms, reads 408 once the deadline armed as the head began passes, that deadline armed once; then the stream's end, and it is closed once its linger passes;
  - slow body: a client that sends its body a piece at a time, then stops, reads 408 once the deadline armed again at its last piece passes;
  - slow read: a client that never reads a MiB answer is closed once its write's deadline passes, sent less than the whole. The connection's send buffer is made 4,096 B as the listener accepts it; the client's receive buffer is left alone (below);
  - each deadline is met at the first firing at or after it, as the lane's other clients' are. The three run beside M5.3's four, and the suite takes 4.02 to 4.04 s, three runs, against main's 3.84 to 3.87.
- `.plans/research/spike/m5-exit-budget.sps`, `m5-exit-copy.sps` and `m5-exit-rcvbuf.sps`, new, with their runs in `out/`.
- Records: decision 0008's chez-libuv #35 row and note; design §7.3's and §7.5's notes; plan §14's M5 exit and M6 notes; the research README.

MEASURED, the budget with deadlines armed (`out/m5-exit-budget.run{1,2}.txt`): every held connection had its idle deadline armed, and the loop held one timer, with 100 held or 500. The heap per held connection over sixteen readings is 1,569 to 1,746 B, median about 1,640 B, with no trend in the GETs: about 100 B above the M4 exit's median. The parts, made fresh: the core's state 192 B, the adapter's context 32 B, a parser 592 B, chez-libuv's TCP handle 200.8 to 237.2 B, and the wheel entry 48 B. A disarm then an arm, a million times, allocate 160 B, the measuring loop's own. So an idle connection holds about 18.3 KB, 16,384 B of it the read buffer. The server's one timer is a `uv_timer_t` of 152 B.

FOUND, chez-libuv's copies (now chez-libuv #35):
- The slow reader's first form asked for `/big`, 4 MiB, and the slow body check failed on its first run. In a scratch probe of the lane, the loop's timer, due every 10 ms, did not fire for 254 ms after that request, so the slow body client sent none of its pieces in that time, and its body deadline passed first.
- chez-libuv v0.7.0 copies each write's bytes into foreign memory, and each read's out of the read buffer, one byte at a time in Scheme: `copy-in!` and `copy-out` in `(libuv private native)`. `m5-exit-copy.sps` (`out/m5-exit-copy.run{1,2}.txt`) prices them at 16 KiB, 256 KiB, 1 MiB and 4 MiB: `copy-in!` 29.7 to 31.1 ns a byte and `copy-out` 28.4 to 29.7. One `memcpy` through a foreign call costs 0.01 to 0.02 ns a byte into foreign memory, and 0.02 to 0.09 ns out into a fresh bytevector. The 4 MiB answer's work before its write is under way: the body made in 0.4 ms, serialized at once, and its segments copied in 124.6 to 125.0 ms. So a 4 MiB response holds the loop 125 ms in the copy, and a full 16 KiB read 0.47 to 0.48 ms.
- The shell cannot work around it: the copies are private, and `make check-imports` refuses chez-libuv's private libraries in shipped code (#65).
- The slow reader now asks for 1 MiB (`/wide`), whose copy is 31.2 ms, and the three new clients run beside each other.

FOUND, Darwin grows a receive buffer made small after the connect (`m5-exit-rcvbuf.sps`, two runs on each platform). A server writes 512 KiB, then 2 MiB, to a client that never reads, its send buffer made 4,096 B:
- left as the kernel makes it, the client's receive buffer is 408,300 B on Darwin and 131,072 B on Linux, and neither write completes in 2 s;
- made 16,384 B after the connect, it grew to 539,008 B on Darwin, where the 512 KiB write completed after 912 and 915 ms. On Linux it read 32,768 B, and nothing completed;
- made 16,384 B before the connect, it read 326,640 B on Darwin and 32,768 B on Linux, and nothing completed.
So the slow reader leaves the client's buffer alone. The lane's first form made it small after the connect, and under M5X-C its half MiB completed (m5-mutations.md).

On Linux: the socket lane in its final form ran in Docker's `chez-libuv-valgrind:10.4.1` image (Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree with chez-libuv's shim built there: 85 passes, three runs of three, 7.08 to 7.22 s. CI's runs are still the billing block, so this is the new checks' only Linux run.

Watched to fail (m5-mutations.md, "The M5 exit"): six mutants, M5X-A to F, each against all thirty-seven suites and again against the socket lane in its final form, with two calibrations. Every check the exit added or changed is reddened by one at least, and D, E and F redden the socket lane alone.

`make test` green: thirty-seven suites, 972 expected passes (shell 85), exit 0, 20.0 s. Size: 117 inserted and 31 deleted lines of tests, and 272 of spikes: one PR.

DECIDED on the owner's word (2026-09-27), by form, after the measurements:
- **chez-libuv #35, filed from here**: copy writes and reads in bulk. Weighed: recording it for M6, and the owner filing it;
- **M5's close waits for the fix**, as M3's waited for byte-machine #139. This branch merges; the pin moves on a commit of its own when a release carries the fix, and M5 closes then. Weighed: closing M5 now on its own criteria and carrying the copies to M6.

NEXT: the PR, feat/m5-exit, merged on the owner's word. Then chez-libuv #35: when a release carries it, its pin moves on a commit of its own, and M5 closes.

UPSTREAM LANDED (2026-09-28): chez-libuv v0.7.1 is tagged (fe3cc3e, 06:04 -0400; annotated tag c62a9f3). #35, filed the day before at the M5 exit on the owner's form, closed via PR #36 (6e8a829), and the release is PR #38:
- each write's, read's and spawned argument's bytes move with one `memcpy` in the shim, and each handle's and request's block is zeroed with one `memset`;
- no API changes, but the shim gains three exports, `chez_uv_copy_in`, `chez_uv_copy_out` and `chez_uv_zero`. A shim built from older sources fails `(import (libuv))` with `&uv-shim-unavailable`, so `make build` runs again after the upgrade, as its CHANGELOG, README and docs/building.md say (the owner relayed it).

Between the tags, the library path changes in `(libuv private native)` alone, whose export list is unchanged, and gains `(uv-bulk)`, chez-libuv's own test library, which nothing here imports. `tests/uv-testing.sls` is byte-identical.

THE PIN, branch chore/chez-libuv-v0.7.1 on feat/m5-exit; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at fe3cc3e. Watched to fail:
- with the checkout moved and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2);
- with the checkout moved and its shim not rebuilt, the socket lane refused to load, `&uv-shim-unavailable` naming `vendor/chez-libuv/build/lib/libchezlibuv.dylib` (exit 255);
- `make build` then put the checkout back at v0.7.0 and rebuilt v0.7.0's shim, since its `submodules` step checks out the commit the superproject's index records. With the gitlink staged, it rebuilt the shim from v0.7.1's sources, which exports the three.

The pin's check, in `tests/test-shell.sps`: the slow reader's MiB write holds the loop less than a tick. The lane reads the loop's time at each write the shell begins, as at each arm, and holds the time from the write's start to the write deadline armed after it under the quick shell's tick, 10 ms:
- at v0.7.0 it failed three runs of three, the write holding the loop 62, 62 and 63 ms (85 passes and 1 failure each). `m5-exit-copy.sps` prices the MiB's copy at 31.2 ms. The rest is the zeroing: v0.7.0's `uv-write*!` allocates the block it copies into with `alloc-zeroed`, which zeroes it a byte at a time (its `stream.sls` and `private/native.sls`);
- at v0.7.1 it passes three runs of three, 86 passes, the write holding the loop 0 ms by the loop's clock each time. The lane took 3.09 to 3.37 s, three runs, where the M5 exit's took 4.02 to 4.04 at v0.7.0.

Smoke evidence: `m5-exit-copy.sps` at the tag, two runs (`out/m5-exit-copy.v071.run{1,2}.txt`), beside v0.7.0's (`out/m5-exit-copy.run{1,2}.txt`):
- at 1 and 4 MiB, `copy-in!` costs 0.02 to 0.03 ns a byte, where it cost 29.72 to 29.78, and `copy-out` 0.02 to 0.1, where it cost 28.46 to 28.59. One `memcpy` there costs 0.02 to 0.03 ns a byte in and 0.02 to 0.09 out: the copies cost what it does;
- at 16 KiB, the shell's read buffer, every copy is at the clock's floor, a microsecond: `copy-out` reads 0.06 ns a byte, where it read 28.44 to 29.54;
- `copy-out` allocates what it did, 16,560 B a call at 16 KiB, at both pins;
- (c), the 4 MiB answer: its segments are copied in 0.108 and 0.12 ms, where they took 124.6 and 125.0, and its body made in 0.433 and 0.446 ms, where it took 0.418 and 0.425.

`make test` green at v0.7.1: thirty-seven suites, 973 expected passes (shell 86), exit 0, 20.1 s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree with the shim built there from v0.7.1's sources, which exports the three:
- `make test`, less its submodule and pin checks: thirty-six suites pass, 962 expected passes. The clients suite cannot start `ab` in that image (status 2);
- the clients suite, in a second container with curl 7.88.1 and ab 2.3 installed: 11 passes;
- the socket lane, three runs: 86 passes each, 5.1 to 6.0 s.

The copy is made with `COPYFILE_DISABLE=1`. macOS's tar otherwise adds `._` AppleDouble files, and five suites (corpus-inventory, exports, libhtp, libhtp-lane and ratchet) failed on them as files of their own. CI's runs are still the billing block.

Records: decision 0008's #35 row, LANDED, and its dated note (all twenty-one filed asks have landed); design §7.3's note; plan §14's M5 and M6 notes; global-constraints; the research README; test-integration's version comment; m5-mutations.md, "chez-libuv v0.7.1, the pin".

The M5 exit's own records are corrected on feat/m5-exit. Plan §14's M5 note now says a 4 MiB response holds the loop 125 ms "in the copy". Its M6 note says the 16 MiB are copied at about 30 ns a byte "as measured up to 4 MiB", where it had carried that rate to half a second, unmeasured.

M5 CLOSES with the pin: its exit is met, and the copies it was held for cost what a `memcpy` does.

DECIDED on the owner's word (2026-09-28), by form: two stacked PRs, each layer proved green on its own tree before it is committed. Weighed: review first, both left uncommitted.
- **feat/m5-exit**, the exit as built and verified at v0.7.0, with plan §14's two notes corrected: 117 inserted and 31 deleted lines of tests, and 272 of spikes;
- **chore/chez-libuv-v0.7.1**, on it: the pin, its check, and M5's close. 121 inserted and 11 deleted besides the gitlink, as the form weighed them, before this decision's own lines.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6 (plan §14), when the owner asks.

MERGED to main on 2026-09-28, on the owner's "do the closing ritual": **the M5 exit and chez-libuv v0.7.1, as two stacked PRs.**
- **#67, the M5 exit,** as fd5c2a0. Its squash tree (cb3e7f4) is the tested tip's, 53bf4d1's, and its parent is 2f730a1. It merged first and kept its branch, since #68 was based on it.
- **#68, the pin and M5's close,** as 06b7946. It was retargeted to main and rebased from #67's tip, 53bf4d1. The rebased tip, 32233bb, has the tested tree (d6e84d1, 4f06027's), and so does the squash, whose parent is fd5c2a0.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36417758819 (#67), 36417783537 (#68 as opened) and 36418170694 (#68 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #68 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: thirty-seven suites, 973 expected passes.

DONE and merged (fd5c2a0, PR #67; 06b7946, PR #68): **M5 COMPLETE.**
- The brief's M5 exit is met: fake-clock table tests; slow clients, slowhttptest's three shapes among them, closed within a tick of their deadlines; one timer per server, none per connection. The budget spike prices a connection's wheel entry at 48 B.
- chez-libuv is pinned at v0.7.1: bytes cross its FFI boundary in bulk, and the socket lane holds a MiB write under a tick.
- All twenty-one filed asks have landed; nothing is open upstream.

NEXT: M6 (plan §14), body streaming and backpressure, on a fresh branch cut from main after this commit, when the owner asks.


M6.1: HOW A HANDLER READS A BODY. Two stacked steps, cut from main at f21ab76: feat/m6.1-readers, then feat/m6.1-body-reading on it; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED FIRST (plan §14: "measured first and settled by form, as 0012 was"): `research/spike/m6-body-reading.sps`, two runs, whose allocation rows are the same.
- Brief risk 3, at chez-httparse v0.4.3: a pause inside on-body-data, fed again from `next`, delivers each body byte once, framed by Content-Length and chunked. After a pause on a body's last byte, one empty feed at `next` completes the message, and nothing else does. The plan's mutation, feeding again from where the read started, hands the head's first bytes over as body.
- The gate's JSON POST, through the real parser, adapter and core, with its body dropped as before M6: 2,320 B, 752 B under the 3,072 B gate.
- Each way of reading, a cycle modelled over the real parser, adds to that cycle: a reader handed each read's pieces as the parser meets them, 208 B (2,256 B a MiB); the plan's one-slot mailbox, the parser paused at each piece, 816 B (45,877 B a MiB); the buffering helper, 224 B; the server buffering every body, 32 B; `(handler request respond)`, 224 B. Streaming holds 80 B past today's connection once a MiB is in, and buffering 1,048,656 B.
- A body of unknown length, per 16 KiB piece: a thunk 64 B, a port 71 B, `emit`/`done` 114 B.

DECIDED on the owner's word (2026-09-28), by form, then "looks good" to the detail asked for on the first answer: decision 0013.
- A reader, answered at the head: `read-body` streams, `read-whole-body` buffers, 1 MiB, 413 past it. Weighed: the server buffering every body; `(handler request respond)`.
- Pieces as the parser meets them. Weighed: the one-slot mailbox.
- A response given instead of a reader: sent at once, then close. Weighed: after the body, keeping the connection; Go's rule.
- A body of unknown length is a thunk (M6.3). Weighed: a port; `emit` and `done`.

M6.1 FIRST STEP: the readers, and brief risk 3's pins (feat/m6.1-readers).
- `(http-server body)`, pure: `read-body` and `read-whole-body`, the readers a handler answers with, each carrying its cap and whether the core buffers the body for it. Nothing hands a body to them yet: the second step does.
- `tests/test-body.sps` (8 checks) and `tests/test-pause-pins.sps` (3). The core never pauses inside a body (decision 0013 item 3), so brief risk 3's two facts are pinned as the parser's, and the plan's mutation runs on the pins suite's own feed loop, whose feeds are capped by count.
- Decision 0013 as decided; the spike and its two runs; the research README.

`make test` green on this step's own tree, a scratch worktree cut from main with the step's files laid in: thirty-nine suites, 984 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): eleven mutants on that tree, each reddening its own suite's checks and nothing else, every one of the step's eleven checks among them. The plan's mutation, M6.1-PA, turns the two pinned rows red.

Size: 301 inserted lines of code and tests.


M6.1 SECOND STEP: the core hands a body to a reader (feat/m6.1-body-reading).

FOUND WHILE BUILDING, each raised with the owner, and recorded in decision 0013's section "Found while building":
- The form's detail that kept the connection when the whole body came with the head was dropped before it was built, the owner told at once: whether the body came with the head depends on the reads, and the outcome lane holds the outcome to one.
- Item 1 as first built made eight strict fixtures' outcomes depend on the reads (the outcome lane: `transfer-encoding.md` #9, #10, #12, #24, #25, #27, #29 and #31, chunked bodies with a bad chunk size). With the body in the head's read, the parser met the error before the handler was asked, and answered 400; in later reads the handler was asked first. Now what the feed that completes a head meets of the body waits for the handler's answer: its pieces, and an error or a cap passed.
- Pausing the parser at the head instead was built and measured through the real core: the JSON POST cost 3,248 B read whole and 3,120 B streamed, over the gate. It was taken out.
- A streaming reader past a cap was handed `abcd` at a byte a time and `abc` read whole: a piece that passes a cap is now handed over up to the cap.
- Found by checking what each reader was handed, beside the core's actions: the core let a reader go when it wrote a status of its own, so the pieces already asked for, a prefix up to a cap or those met before an error, reached nobody at one read split and the reader at another. A reader is now let go when the connection lingers or closes, or when it raises.

BUILT:
- The core, `(http-server connection)`: a request whose head announces a body (chunked, or a Content-Length above 0) is handed to its handler with the feed's result, once the feed that completed the head has returned; what that feed met of the body, its pieces and an error or a cap passed, is kept for the answer. A reader is handed each read's pieces as `deliver-body`, the read's own spans, and `deliver-body-end` once the message has ended. A whole reader's body is copied as it arrives, into one bytevector grown to the declared length or joined when chunked, and handed over as its one piece. A response given instead of a reader is sent at once, and the connection closes after it, as `unread-body`. A body past `max-body-bytes`, or past a reader's cap, is refused as `body-too-large`, answered 413 (`(http-server decisions)`), and the piece that passes the cap is handed over up to it. A reader that raises is answered 500, as a handler that raises is. `conn-body-reader` is exported for the shells, and `conn-body-buffered`, the bytes the core buffers for a whole reader, for the checks. The parser is never paused inside a body.
- Both shells perform `deliver-body` and `deliver-body-end`: the fake shell, and the libuv shell, which logs a reader's raise as a handler's.
- The facade exports `read-body` and `read-whole-body`. `docs/handlers.org` gains "Reading the body"; `docs/configuration.org` and `docs/responses.org` say what the body cap does and when 413 is sent.
- `tests/test-connection-body.sps` (27 checks, each row at every delivery size); nineteen body rows (B1 to B19) in the transition table, and H5 a reader's.
- Suites that sent a body to a handler that answered at once now read it, where their checks need the connection kept, most through (fake-shell)'s `drops-body`: the message loop, entry, head, deadlines, originated (413 now driven end to end), allocation, the trace lane's driver, the outcome and libhtp lanes, the socket lane and the clients suite. The outcome lane runs every fixture with a handler that reads every body and with one that reads none. The contract test has reader scripts, among them readers that raise, and renders a reader by its cap and kind. The retention suite checks a body read whole is let go with its reader, and the serve suite a 413 from CHEZ_HTTP_MAX_BODY_BYTES set in the environment.

DECIDED on the owner's word (2026-09-28), by form:
- the four findings kept as built: what the head's read brings of the body waits for the handler's answer. Weighed: pausing the parser at the head (3,248 B and 3,120 B, over the gate); letting those outcomes depend on the reads, the outcome lane exempting eight fixtures;
- a /code-review first, its findings fixed on the owner's word, then two stacked PRs, each layer proved green on its own tree. Weighed: the two PRs without a review; one PR.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): eight findings.
- **A whole reader's buffer was made at the declared length as the reader answered**, before any of the body came: a head alone could take up to the reader's cap, 1 MiB by default, and with no cap a declared length past what memory holds raised in the core. Fixed: the buffer grows as the body arrives, to the declared length once that is at most twice what has arrived, and doubling before, so it is never more than twice what has arrived, the buffers it grows through come to less than twice the body, and it ends exactly full. `conn-body-buffered`, exported, says how many bytes the core buffers for a whole reader, and the new checks read it: nothing buffered before a declared 64 KiB's bytes arrive, never more than twice what has arrived, the body handed over exactly its length (the body suite); 64 KiB in 1,000-byte pieces allocates 128,657 B in buffers, under twice its length (the allocation suite). Decision 0013's item 2 says so, and its review note.
- **A request refused mid-body kept a whole reader's buffer during its write**, since a status of the core's own no longer lets the reader go. Fixed: that status lets go of the buffer and the pieces kept, and keeps the reader. Checked: a whole reader past its cap mid-body buffers 3,000 bytes, then nothing, its 413 still being written.
- **A chunked whole body is copied twice at its peak.** The finding's premise was measured first and is wrong: on a chunked MiB in 64 pieces, copying each piece and joining them allocates 2,099,391 B; a doubling buffer trimmed at the end, the fix it proposed, 3,129,692 B; both hold 2 MiB at most (a scratchpad probe, two runs, the same). No change; the core's comment says why.
- **The request record's comment on its body field** said it would carry a body handle in M6. It now says the field stays #f: a handler reads a body through the reader it answers with.
- **docs/handlers.org** called any request with a Content-Length one with a body: it now says a Content-Length above 0.
- **body-piece answered one constant list in three arms.** Now `hand-on` hands a piece on by the handler's answer, and body-piece names its two answers once.
- **The suites' reading handler was written five times**: `drops-body`, in (fake-shell), replaces the message loop's, the originated, deadlines and head suites', and the outcome lane's. The socket lane's and the clients suite's handlers read a POST's body inside routes of their own, and keep them.
- **CHEZ_HTTP_MAX_BODY_BYTES never drove a 413 from the environment**: test-serve.sps starts its server with it set to 4, and a 5-byte body gets 413.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty suites, 1,069 expected passes, exit 0, 20.7 s.
- The allocation suite: curl's GET 1,840 B, unchanged; the JSON POST 2,624 B read whole and 2,432 B streamed, against the 3,072 B gate, where before M6.1, its body dropped, it cost 2,320 B; a 64 KiB body read whole, in 1,000-byte pieces, 128,657 B in buffers.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,069 expected passes, the allocation figures the same;
- the socket lane, three runs: 92 passes each.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the second step): 64 mutants on the finished tree, and every check new or changed by the slice reddened by at least one. M6.1-CK is the bug the reader's own view found; M6.1-EM to M6.1-ER were written for six changed checks the first run left without a mutant; the review rewrote the code nine mutated, eight were written again, and M6.1-CD is withdrawn, its code gone; M6.1-RA to M6.1-RH witness the review's fixes.

Records: decision 0013's sections "Found while building" and the review's, and its item 2; decision 0005's amendment (`max-body-bytes`); design §4.1, §4.4 (the body rows) and §6.5 (413); plan §14's M6.1 note, and §7's 413 note; the docs; m6-mutations.md.

Size: 1,557 inserted lines of code and tests, 213 deleted, besides records and docs. It cannot be split further and stay green: once a request with a body is handed over at its head, every suite that sends one changes with it.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6.2 (plan §14), which the M6.1 note re-scopes.

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **M6.1, as two stacked PRs.**
- **#69, the readers and brief risk 3's pins,** as fcd00b7. Its squash tree (d7408ab) is the tested tip's, 4edb4a2's, and its parent is f21ab76. It merged first and kept its branch, since #70 was based on it.
- **#70, the core hands a body to a reader,** as 780f4c0. It was retargeted to main and rebased from #69's tip, 4edb4a2. The rebased tip, 24b22ee, has the tested tree (d3af745, 1cda330's), and so does the squash, whose parent is fcd00b7.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36451927716 (#69), 36451961940 (#70 as opened) and 36452623653 (#70 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #70 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: forty suites, 1,069 expected passes.

DONE and merged (fcd00b7, PR #69; 780f4c0, PR #70): **M6.1.**
- A handler reads a request's body through the reader it answers with at the head: `read-body` streams it, and `read-whole-body` buffers it, up to 1 MiB unless given a cap. `CHEZ_HTTP_MAX_BODY_BYTES` caps every body, and 413 has its first way in.
- The parser is never paused inside a body, so brief risk 3's two facts are pinned as the parser's.
- What the head's read brings of the body waits for the handler's answer, so the outcome never depends on how the bytes were split into reads.

NEXT: M6.2 (plan §14), backpressure on the read side, as the M6.1 note re-scopes it: a reader in v1 takes each read's pieces as they are handed over, so reading waits on a credit only for an awaiting reader (M7). M6.2's check is that wait, and the body deadline stopped through it, with a reader that withholds its credit. On a fresh branch cut from main after this commit, when the owner asks.


M6.2: BACKPRESSURE ON THE READ SIDE. Two stacked steps, cut from main at e9191ef: feat/m6.2-read-backpressure, then feat/m6.2-shell-credit on it; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

SETTLED BY THE RECORDS, NO FORM: decision 0013's consequences and plan §14's M6.1 note already say what M6.2 is. A reader answered in v1 takes each read's pieces as they are handed over, so reading goes on at once; reading waits on a credit only for M7's awaiting readers; and M6.2's check is that wait, and the body deadline stopped through it, with a reader that withholds its credit.

CHOSEN WHILE BUILDING, flagged for review:
- Whether reading waits for a reader: the shell's word, since the shell hands the pieces over. A shell that hands a streaming reader its pieces on credit answers with the reader and `credit`, `(handler-responded reader credit)`, as M7's coroutine shell will. First built as a field on the reader, `grants-credit?`, which the review moved to the answer (below). Weighed: every streaming reader granting credit, the shells granting it as each piece's procedure returns, which would stop and start reading, and disarm and arm the body deadline, at every body read in v1, where no reader withholds.
- Where the connection waits: a state of its own, `awaiting-credit`, which reads nothing and arms no deadline, as design §4.3's table says of each state. Weighed: a flag inside `body`, whose row in that table says it reads and arms the body deadline.
- How the libuv shell hears a credit: `connection-body-credit!`, which no action asks for. M7's scheduler will call it; the checks call it now. The facade exports nothing new.
- A credit counts bytes. One for more than the reader was handed and has not credited is an assertion violation, as a completion the core did not ask for is (M3.3).

DECIDED on the owner's word (2026-09-28), by form, after the plan-vs-landed walkthrough: a /code-review high first, its findings fixed on the owner's word, then two stacked PRs, each layer proven green on its own tree. Weighed: the two PRs without a review; the review, then one PR of 538 lines.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): four findings, all fixed. The review's rows and checks were written with the fixes, and each was watched red by its mutant.
- **Nothing checked that a refusal wins over the wait** (the first step). A feed that hands a reader on credit pieces and then meets the parser's error, or passes a cap, is answered with its status: row C10, and two flows at every delivery size, a malformed chunked body answered 400 and one past max-body-bytes answered 413. M6.2-RA, the wait checked before the status, reddens all three.
- **A refused credit closes the connection and raises, undocumented** (the second step). `connection-body-credit!`'s comment now says so, and a socket check pins it: a credit for more than the reader was handed raises to the caller, and the connection is closed. M6.2-RB, the raise swallowed, reddens it.
- **The credit's word lived on the reader the handler builds** (both steps). Whether a shell hands a reader its pieces in place or on credit is the shell's to know: M7's coroutine shell hands each piece to the handler's coroutine. `(http-server body)` is back to M6.1's four fields, untouched by the slice, and the shell says so with the answer, anything but `credit` after it refused (row C11). The fake connection (the first step) and the libuv shell (the second) are made on credit for the checks. M6.2-RC (the word ignored) and M6.2-RD (any word taken), and M6.2-RF, RG and RH (a shell's word turned round), redden them.
- **The credit arm while the body is read could only take none** (the first step). on-body-credit's arms are split: `awaiting-credit` takes the credit, and starts reading once it covers what was handed; `body` takes only a credit of none, since nothing is owed there once a feed has returned. M6.2-RE, the `body` arm reading no credit, reddens C6.
- The rewrite left a guard doubled: `accept-reader` kept a whole reader off credit, which `owe!` does already, being called only for a streaming reader's pieces, and two guards for one property hide each other's mutants. The doubled one went before the mutants ran; M6.2-RI, a whole reader's pieces owed, reddens C2.

DECIDED on the owner's word (2026-09-28), by form, once the review's fixes had grown the slice to 674 inserted lines of code and tests: two stacked PRs still, the first 432 inserted, a little over plan §1 rule 1's ~400, as M4.3's two went. Weighed: three stacked PRs of 262, 170 and 242.

FOUND WHILE BUILDING:
- For M7, carried in plan §14: an awaiting handler asked at the head leaves reading going on until it answers, and every piece met meanwhile is kept for its answer, up to `max-body-bytes`, unset by default.
- The checks' credit calls raised out of their suites when a mutant made the core refuse a credit, so the suites stopped with a harness error. They now take a refusal as a result and fail by name, the contract's replay included (m6-mutations.md).

M6.2 FIRST STEP: the core waits for a reader's credit (feat/m6.2-read-backpressure).
- `(http-server connection)`: the eleventh state, `awaiting-credit`. An answer may carry `credit` after it, `(handler-responded reader credit)`, anything else after it being refused. The core counts the bytes it hands a streaming reader answered on credit; with credit owed once a read's feed has returned, or once the reader's answer has taken the pieces kept for it, the connection stops reading and disarms the body deadline, and `(body-credit n)` covering what was handed starts reading and arms the body deadline again. A body the parser refuses, or one past a cap, is still answered with its status. A read that ends the message hands its pieces over with the end and waits for nothing: reading stops at the pause for the response, as for every message. `handler-failed` and `read-error` act in the new state as in `body`, less the `read-stop`; `bytes-arrived` and a tick there change nothing; a credit once the message has ended, or once the reader is let go, changes nothing.
- `(fake-shell)`: a fake connection made on credit answers with each answer and `credit`.
- The checks, each reading what the reader was handed as well as the core's actions:
  - `tests/test-connection-table.sps`: eleven credit rows, C1 to C11, and the new state in T2 and D4;
  - `tests/test-connection-body.sps`: through a fake connection made on credit, at every delivery size, a reader never holds more than one read uncredited, with both framings; a malformed body and one past a cap are answered with their status; the body deadline does not run through the wait, and runs again after the credit; and a reader answered with no word of credit never makes reading wait.

`make test` green on this step's own tree, a scratch worktree cut from main with the step's files laid in: forty suites, 1,101 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): twenty-one mutants on that tree, and every check the step added or changed reddened by at least one. The plan's mutation, M6.2-D, the credit ignored, reddens the slow reader's bound at every delivery size.

Size: 432 inserted lines of code and tests, 46 deleted.

NEXT: the second step, the libuv shell's credit, stacked on this one.


M6.2 SECOND STEP: the libuv shell's credit (feat/m6.2-shell-credit).
- `(http-server private shell)`: a shell made on credit answers with each handler's answer and `credit`; v1's server never makes one. `connection-body-credit!` dispatches `(body-credit n)`, and a credit the core refuses closes the connection and raises to the caller, as any bug in a dispatch does.
- The checks:
  - `tests/test-shell.sps`, on a shell made on credit: a 64 KiB body sent at once to a streaming reader. While the reader withholds its credit, past the body deadline's length, the connection has no deadline armed, the shell's timer stops and the connection stays (plan §14's note of 2026-09-27, M5.3's); credited each time it waits, the reader is handed the body a read at a time, in order, and the response is written; and a credit for more than the reader was handed raises to the caller, and the connection is closed;
  - `tests/test-contract.sps`: a credit script, played to a libuv shell made on credit and replayed to a fake made on credit. Its waits credit the script's connection each time it waits, the replay gives the fake each credit, and a credit the fake's core refuses shows in its trace rather than raising.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty suites, 1,107 expected passes, exit 0, 21.9 s.
- The allocation suite, the same before and after the slice: curl's GET 1,840 B; the JSON POST 2,624 B read whole and 2,432 B streamed; a 64 KiB body read whole, in 1,000-byte pieces, 128,657 B in buffers.
- On a socket, by a scratch copy of the shell suite printing them, two runs, the same: the reader handed the 64 KiB body sent at once was credited four times, 16,327 B, the first read less the 57-byte head, then 16,384 B three times, and held 16,384 B at most, one read.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,107 expected passes, the allocation figures the same;
- the shell suite and the contract, three runs each: 95 and 56 passes each time.

Watched to fail (m6-mutations.md, the second step): twenty-seven mutants on the finished tree, the first step's twenty-one again and the second step's six, and every check new or changed by the slice reddened by at least one. The plan's mutation, M6.2-D, reddens the slow reader's bound on the socket as well. M6.2-Q, the timer stopped only once no connection is left, is the first mutant a check can tell from the timer's stop at an empty wheel (M5.3's note).

Records: design §4.1 (the answer's `credit`), §4.3 (the state) and §4.4's M6.2 amendment (the rows); plan §14's M6.2 note, and the note carried to M7; decision 0013's note on the consequence M6.2 built; m6-mutations.md. The docs are unchanged: a v1 handler cannot withhold its credit.

Size: 242 inserted lines of code and tests, 37 deleted; the slice, 674 and 83.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6.3, a streamed response (plan §14).

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **M6.2, as two stacked PRs.**
- **#71, the core waits for a reader's credit,** as 231a6ad. Its squash tree (24086c6) is the tested tip's, 06cbfb5's, and its parent is e9191ef. It merged first and kept its branch, since #72 was based on it.
- **#72, the libuv shell's credit,** as b36cd7f. It was retargeted to main and rebased from #71's tip, 06cbfb5. The rebased tip, de3ef65, has the tested tree (89a5aa4, 0bb79ab's), and so does the squash, whose parent is 231a6ad.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36461834323 (#71), 36461867546 (#72 as opened) and 36466500413 (#72 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #72 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: forty suites, 1,107 expected passes.

DONE and merged (231a6ad, PR #71; b36cd7f, PR #72): **M6.2.**
- Reading waits for a reader's credit when the shell hands it its pieces on credit, `(handler-responded reader credit)`: the connection waits in `awaiting-credit`, reading stopped and no deadline armed, until `(body-credit n)` covers what the reader was handed, so a slow reader holds at most one read. A refusal still wins over the wait.
- v1's shells never answer on credit, so a v1 reader takes each piece as it is handed over, and v1's figures are unchanged. The checks stand in for M7's coroutine shell with a fake connection and a libuv shell made on credit.
- The libuv shell's timer stops while a connection waits for credit and stays, the row M5.3's note asked for.

NEXT: M6.3 (plan §14), a streamed response: `handler-body-chunk` and `handler-body-end` get their rows, chunked to HTTP/1.1 and close-delimited to 1.0 (M3.2's carried arm); `write-high-water` and `write-low-water` arrive, and with them `notify-producer`; and a handler that fails after its head is on the wire gets a bare close. Decision 0013 item 8 already settled the body of unknown length: a thunk, called only below the write's high water. On a fresh branch cut from main after this commit, when the owner asks.


THE CHEZ-LIBUV v0.7.3 PIN, on the owner's word, with the release note the owner relayed. Branch chore/chez-libuv-v0.7.3, cut from main at e992ea5; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at d46654c.

UPSTREAM: chez-libuv tagged v0.7.2 (e358156; annotated tag c26a31e, 08:37 -0400) and v0.7.3 (d46654c; annotated tag 410df26, 18:20 -0400) the day it tagged v0.7.1. GitHub's objects are the sibling checkout's. Neither carries an ask of ours, so decision 0008 is unchanged:
- v0.7.2 (PR #39, release PR #40) tightens chez-libuv's own memory-gate check. Nothing under its `src/` changed;
- v0.7.3 (PRs #42 and #43, release PR #44): a Chez without threads is refused by name at import (#41), where the import failed at `make-mutex`; `uv-async-send!` is fenced against `uv-close!` (#33), so a send that races a close either completes first or raises `&uv-handle-closed`, where it could reach freed memory; and `uv-close!` is one step, even inside an engine.

Checked against chez-libuv's history between the tags, as the note said:
- no C or header file changed, so the shim is v0.7.1's, and `make build` did not rebuild it;
- the facade and every public library but `(libuv async)` are byte-identical, and `(libuv async)`'s export list is unchanged, so no new name can collide with one of ours. The library path gains `(libuv private require-threaded)`, which exports nothing. `tests/uv-testing.sls` is byte-identical;
- the server's exposure: `src/` calls `uv-close!` once, in `handle-close!`, and makes no async handle and no engine. README.org and global-constraints already ask for a threaded Chez, and CI builds one with `--threads`.

Watched to fail: with the checkout moved and its gitlink staged, and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). With both moved, it passes.

`make test` green at v0.7.3: forty suites, 1,107 expected passes (shell 95), exit 0, 21 s, as main counted at v0.7.1.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, `(threaded?)` #t), from a copy of the tree made with `COPYFILE_DISABLE=1`, the shim built there from v0.7.3's sources, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,107 expected passes;
- the shell suite, the contract and the integration suite, three runs each: 95, 56 and 5 passes each time.

CI's runs are still the billing block.

Records: global-constraints; design §5.4's note on the threads door; test-integration's version comment.

The pin moves alone: the gitlink and two changed lines, the Makefile's pin and test-integration's comment, besides these records.

DECIDED on the owner's word (2026-09-28), by form: one PR, the pin alone. Weighed: a review first; nothing committed.

NEXT: the PR, merged on the owner's word. Then M6.3 (plan §14), when the owner asks.

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **the chez-libuv v0.7.3 pin, as one PR.**
- **#73, the pin,** as cfbf8cc. Its squash tree (1917601) is the tested tip's, 959e89d's, and its parent is e992ea5.
- **CI.** Its one run was the billing block, the `linux` job with 0 steps: 36493691705.
- **Branch.** Deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #73 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletion were done by hand.

`make test` green on main: forty suites, 1,107 expected passes.

DONE and merged (cfbf8cc, PR #73): **chez-libuv is pinned at v0.7.3.** A send that races an async handle's close is refused, where it could reach freed memory; `uv-close!` is one step; and a Chez without threads is refused by name. The server's code and counts are unchanged.

NEXT: M6.3 (plan §14), a streamed response, as M6.2's NEXT sets it out, on a fresh branch cut from main after this commit, when the owner asks.


M6.3: A STREAMED RESPONSE. Four stacked steps, cut from main at cbedab8: feat/m6.3-framing, then feat/m6.3-core-stream, feat/m6.3-stream-flows and feat/m6.3-socket, each on the one before; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. A fifth, fix/m6.3-small-pieces, on the fourth after the second review (2026-09-29, below).

SETTLED BY THE RECORDS, NO FORM: decision 0013 item 8 settled the API, a producer (a thunk answering a bytevector, or the eof object at the end), called only below the write's high water, chunked to HTTP/1.1 and close-delimited to 1.0; plan §14's M6.3 settled the rest: the rows, the two water marks with `notify-producer`, a bare close once the head is on the wire, and the plan's mutation.

CHOSEN WHILE BUILDING, flagged for review (decision 0013's section "Built"):
- The head goes out first, as every response's head does, and the producer is asked for its first piece once the head is written, so a producer that fails at its first call gets the bare close. Weighed: the head held for the first piece, one write fewer a response and a 500 for a first-call failure, which would leave the client of an M7 producer that awaits before its first piece with no head until then.
- An answer that is neither a bytevector of a byte or more nor the eof object is the producer failing: the shell reports `handler-failed`, the bare close, as it does a raise. The core's `producer-event` makes the answer an event, so both shells report it alike. Weighed: the core refusing the event as a caller bug. An empty bytevector was first written as nothing, the producer asked again; the review changed that (below).
- The water marks' edges: the producer is asked at or below the high water, and after waiting, at or below the low water and the high water both; a low water above the high water is refused at startup, whichever was set; equal marks and marks of 0 are accepted.
- While a piece is asked for with no write outstanding, no deadline is armed: the producer is the one waited on, and decision 0005 has no deadline for a handler. In v1 the shells call the producer in place, so its answer comes in the same drain.
- No body is written to a HEAD, a 204 or a 304, so their producer is never called.

FOUND WHILE BUILDING:
- The M5.2 note for M6.3, a body that stalls once a handler's head is on the wire, describes a case v1 does not reach: a handler's head goes on the wire only from `handling`, the body ended, or from `body` with a response given instead of a reader, which stops reading the body (decision 0013 item 4). No body deadline runs then, and the body's 408 stands (plan §14's note; the table's S4).
- Whether a failure after the head must reach the embedder, which plan §14 left to M6.3: it need not, since it is logged as `handler-failed` as every handler's failure is, so `&http-server-handler-error` stays undefined (design §6.4's note).
- The contract's first run of the bare-close script failed its first check: the server's bare close comes before it reads the client's half-close, the first close with no linger. Such a script is marked `(bare-close)`, and the check expects no end for it. And the contract rendered a response's body by identity, which would part the shells on any producer; a producer renders as one.
- M3.2's carried arm is reached only by an HTTP/1.0 client that asked to keep the connection; one that did not closes for that. The socket's and curl's HTTP/1.0 streams ask, so dropping the arm reddens a real client (the mutants, below).
- The allocation shape "a piece costs the same however many came before it" first compared the second 32 pieces' cost with twice the first 16's, and missed by 1 B, 9,729 B against 9,728: a collection's byte in an average. It compares per-piece quotients now.
- Splitting the slice into steps found `producer-event`, which the core exports in the second step, checked first in the stream suite of the third, so its mutants could not redden their own step. The check moved to the table's vocabulary checks.

DECIDED on the owner's word (2026-09-28), by form, after the plan-vs-landed walkthrough: a /code-review high first, its findings fixed on the owner's word, then four stacked PRs, each layer proven green on its own tree: about 230 inserted lines (the limits and the piece framing), 550 (the core's stream rows, both shells' `notify-producer` and the table), 440 (the fake shell's flows and the allocation shapes) and 220 (the socket, contract and curl checks), re-measured once the review's fixes are in. Weighed: the PRs without a review; three stacked PRs (about 230, 990 and 220); two (about 1,220 and 220).

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): six findings. Each fix's checks were written first and watched red, and each has its mutant.
- **An empty piece held the loop.** Written as nothing, the producer asked again, it let a producer that answered one while it had nothing ready be called again in the same drain for as long as it did, holding every connection. On the fake shell before the fix, a scratch program: 99,998 calls in one delivery, until its dispatch cap. An empty answer is now the producer failing, the bare close: `producer-event` refuses it, and the core refuses an empty `handler-body-chunk` as the shell's bug (S13). In v1 a producer cannot wait, so an answer that is no piece is its failure.
- **A low water above the high asked the producer past the high water.** `limits-with` checks no value; with a low water of 200 and a high of 90, a completion that left 92 bytes outstanding asked the producer again. A waiting producer is now asked at or below both marks (S17, red before the fix).
- **The docs said the server waits once 256 KiB are outstanding**; it waits once more than that is, and holds at most that and a piece. handlers.org says so.
- **The docs did not say a producer may never be called, or be let go early.** They do now, and that a port left open is closed when Chez collects it. The finding said Chez never closes one: its premise was half wrong. Measured by a scratch program, 20,000 opens of `/dev/null` under a 1,024-descriptor limit all succeed with a collection every 100, and fail at the limit with none. What stands: the close waits for a collection, which descriptors do not bring on.
- **Five suites wrote their producers each.** `tests/producers.sls`, `(producers)`, holds them: `producer-of`, `sized-producer`, `sized-body` and `counted`, for the stream, shell, contract and clients suites.
- **A size line was made for every piece.** A power of two's, 2^0 to 2^24, is now made once and shared, as the status lines are; a piece of any other length still makes its own. The core's cost a piece falls from 128 B to 112 B at 16 KiB.

Re-measured once the review's fixes were in: the four steps are 260, 596, 456 and 189 inserted lines of code and tests, where the form said about 230, 550, 440 and 220. None moved by fifty lines, so the shape stands, and was not asked again.


M6.3 FIRST STEP: the write water marks, and the piece framing (feat/m6.3-framing).
- `(http-server limits)`: the eighteenth and nineteenth fields, `write-high-water` and `write-low-water`, 262,144 and 65,536 bytes outstanding, from `CHEZ_HTTP_WRITE_HIGH_WATER` and `CHEZ_HTTP_WRITE_LOW_WATER` in bytes, with plan §3's four things; a low water above the high water refused at startup, whichever was set.
- `(http-server serializer)`: `serialize-piece`, a piece of a producer's body as the segments of one write, chunked (RFC 9112 §7.1) or close-delimited, never copied (a span is uv-write*!'s `(bv start end)`), a power of two's size line made once, an empty piece refused; `serialize-end`, the last chunk and an empty trailer section, or nothing when the close ends the body.
- The checks: `tests/test-limits.sps`, 51 (main's 46), the water marks; `tests/test-serializer.sps`, 171 (main's 147), the pieces, the end, their refusals, the size lines shared.
- Nothing calls the framing yet: the core does, in the second step. `response-fault` still refuses a producer, so a handler that answers one is answered 500 until then.

`make test` green on this step's own tree, a scratch tree of main with the step's files laid in: forty suites, 1,136 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): twenty mutants on that tree, each reddening its own suite, and every check the step added or changed reddened by at least one.

Size: 260 inserted lines of code and tests, 20 deleted.

NEXT: the second step, the core streams a producer's body, stacked on this one.


M6.3 SECOND STEP: the core streams a producer's body (feat/m6.3-core-stream).
- `(http-server serializer)`: a producer's head writes no body, and a producer given a Content-Length is refused; `response-fault` takes a producer as a body. `(http-server response)` documents it.
- `(http-server connection)`: the stream, design §4.4's M6.3 rows. `respond-with` writes a producer's head and asks for its first piece when the head leaves the bytes outstanding at or below the high water; `handler-body-chunk` writes each piece and asks again at or below the high water, waiting past it; a completion asks a waiting producer again at or below both water marks; `handler-body-end` writes the last chunk, or, close-delimited, lets the close end the body, the response written once every write has completed; `handler-failed` with a piece asked for is a bare close; a piece or an end not asked for, or a piece of no bytes, is refused. Three fields hold the stream: the producer, the framing, and whether a piece is asked for. `conn-producer` and `producer-event` are exported for the shells: `producer-event` makes a producer's answer an event, refusing what is no piece, an empty bytevector among it. Every close lets the producer go. M3.2's carried arm is reached.
- Both shells perform `notify-producer`: `(fake-shell)`, and `(http-server private shell)`, which logs a producer's failure as a handler's. The fake's `write-wire` copies a span segment. Their checks are the steps' above.
- The checks: `tests/test-connection-table.sps`, 205 (main's 175), seventeen stream rows, S1 to S17, the vocabulary now wholly used, and a producer's answer as an event; `tests/test-serializer.sps`, 190, the producer's head in both framings and to a HEAD, read back by chez-httparse's response parser, and the refusals.
- Records: design §4.4's M6.3 amendment, §6.4's and §7.3's notes; decision 0005's amendment (the water marks), decision 0013's section "Built"; plan §14's M6.3 note; docs: handlers.org gains "Streaming a response", and responses.org and configuration.org the producer's framing and the two variables.

`make test` green on this step's own tree: forty suites, 1,185 expected passes, exit 0.

Watched to fail (m6-mutations.md, the second step): forty-seven mutants on that tree, the first step's twenty again and twenty-seven for the core and the producer's head, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, high water ignored, reddens S6 and S7. The shells' `notify-producer`, and a waiting producer's asked flag, are watched in the third and fourth steps, where their checks are.

Size: 596 inserted lines of code and tests, 95 deleted, past plan §1 rule 1's ~400, as the form weighed.

NEXT: the third step, the fake shell's flows, stacked on this one.


M6.3 THIRD STEP: the fake shell's flows, and the allocation shapes (feat/m6.3-stream-flows).
- `tests/test-connection-stream.sps`, new, 15 checks: every stream read back by chez-httparse's response parser, with a trace reading the bytes outstanding at every ask and write: HTTP/1.1 chunked, HTTP/1.0 close-delimited, HEAD and 204; a MiB under 0005's marks never more than a piece's write past the high water; small marks, every ask at or below the high water and every one after a completion at or below the low; four bare closes, an empty answer among them; one bytevector handed out again; a producer in place of a reader, a reader's response streamed, a GET behind a stream; a transport failure and the write deadline mid-stream letting the producer go.
- `tests/test-connection-allocation.sps`, 26 (main's 21): a piece costs the same however many came before it, at 16 KiB what it does at 128 bytes, and more at 100 bytes, its size line.
- `tests/producers.sls`, new, `(producers)`: the producers the suites stream from.

`make test` green on this step's own tree: forty-one suites, 1,205 expected passes, exit 0.

Watched to fail (m6-mutations.md, the third step): fifty mutants on that tree, the second step's forty-seven again and three more, the fake shell's `notify-producer` (FA) among them, and every check the step added reddened by at least one, but the allocation shape's calibration, the instrument's guard. The plan's mutation, M6.3-CA, reddens the slow reader's bound in the fake shell's flows.

Size: 456 inserted lines of code and tests.

NEXT: the fourth step, a streamed response on a socket, stacked on this one.


M6.3 FOURTH STEP: a streamed response on a socket, in the contract, and to curl (feat/m6.3-socket).
- `tests/test-shell.sps`, 106 (main's 95): a MiB to a client that reads nothing yet, its writes waiting, the bound kept, then read whole; HTTP/1.0 asking to keep the connection, read at the close; a GET behind a stream; a bare close, logged.
- `tests/test-contract.sps`, 65 (main's 56): three scripts, chunked, HTTP/1.0 and the bare close, which is marked; the replay records a raise in the fake's trace, where it ended the suite; a producer renders as one.
- `tests/test-clients.sps`, 13 (main's 11): curl reads a chunked stream and a GET on its connection, and an HTTP/1.0 stream kept alive, read to the close.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty-one suites, 1,227 expected passes, exit 0. On main, measured in a scratch worktree the same day: forty suites, 1,107.
- The allocation suite: curl's GET 1,840 B and the JSON POST 2,624 B read whole and 2,432 B streamed, as on main; curl's GET streamed in 16, 32 and 64 pieces of 100 bytes 7,088, 11,952 and 21,681 B, a piece 304 B through the suite's harness; eight pieces of 16 KiB and of 128 bytes 4,528 B each, of 100 bytes 4,656 B.
- A scratchpad probe, two runs, the same: a piece costs the core 112 B when its length is a power of two and 128 B otherwise, and the producer's event 64 B.
- The shell suite five runs of five green.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, threaded), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,227 expected passes, the allocation figures the same;
- the shell, contract, stream and clients suites, three runs each: 106, 65, 15 and 13 passes each time.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the fourth step): fifty-three mutants on the finished tree, the third step's fifty again and the libuv shell's three, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, reddens the slow reader's bound on a socket as well; M6.3-CC, the carried arm dropped, the HTTP/1.0 stream in the fake shell, on a socket and in curl.

Size: 189 inserted lines of code and tests, 31 deleted; the slice, 1,501 and 146.

M6.3 SECOND REVIEW (2026-09-29), on the owner's ask, before the PRs: the empty piece's fix checked again for safety and performance.

HELD: an empty piece closes its own connection alone. On a socket (a scratch server whose producer answers a piece, then an empty bytevector): curl read the head and the piece, then the body cut short (its error 18); the log named the empty bytevector, in 145 characters; the next request was answered in 0.9 ms. The shells' guard holds only the producer's call and its answer's check, so the core's refusal is never blamed on the handler, and the fix costs a piece one length check.

FOUND (a scratch server whose producers never end, and a probe in Python: a client reading as fast as it can, another sending a GET every 2 ms, and clients that never read, the server's RSS read; one run each):
- **The empty piece was the limit of a slope.** The water marks count bytes, but each piece is a write of its own, which holds the loop and memory the same whatever its size: so a turn asked some 2,500 times for 100-byte pieces and some 43,700 for 1-byte ones chunked. On Linux (Debian 12, libuv 1.44.2, in Docker, aarch64), another client's request waited 50.6 ms at the median (62.9 at most) behind 100-byte pieces, 1,019 ms (1,697) behind 1-byte ones, and 0.11 ms behind 16 KiB ones. On Darwin arm64 (libuv 1.52.1): 250 ms (359), over 5 s, and 1.83 ms. A high water of 16 KiB cut the Darwin 100-byte wait to 12.8 ms: the wait follows the pieces a turn asks for.
- **The slow reader's bound held for large pieces only.** Each write outstanding holds a `uv_write_t` (192 bytes at libuv 1.52.1, measured with `sizeof`), 16 bytes a segment and chez-libuv's records, on top of its bytes. Per client that never read, Linux: 0.26 MB of 16 KiB pieces, 0.71 MB of 100-byte ones, 21.6 MB of 1-byte ones chunked, 129.5 MB of them to HTTP/1.0 (Darwin: 0.18, 0.69, 12.4, 102.7 MB), where handlers.org promised 256 KiB and a piece.
- **A wrong answer was logged whole**: `producer-event` named the answer itself, and a 100,000-character string answered for its bytes made a 100,141-character log line.
- **The docs pointed at ports that make a producer wait**: `get-bytevector-some` on "a binary input port", a pipe's or a socket's among them, and "return a piece only once you have one", which reads as waiting for one.

DECIDED on the owner's word (2026-09-29), by form, after a second form that set the options out: (1) the writes outstanding bounded at 64, a waiting producer asked again at 16 or fewer, fixed values. Weighed: the cap and the server gathering small pieces into writes of about 16 KiB, about 28 times the throughput by a handler that gathers, but a change to the core's pacing and the serializer's framing, not prototyped; docs only. (2) An answer that is no piece named by its kind and length. Weighed: as it was. (3) A fifth stacked PR on the four, which stay as proved. Weighed: folding the fixes into the four. The doc wording goes with them.

M6.3 FIFTH STEP: small pieces capped, a wrong answer named by its kind (fix/m6.3-small-pieces), on feat/m6.3-socket.
- `(http-server connection)`: `below-high-water?` asks too for fewer than `stream-writes-high`, 64, writes outstanding, and `stream-completed` asks a waiting producer again at `stream-writes-low`, 16, or fewer. `producer-event`'s violation names the answer by `answer-kind`: `(string 5)`, `(list 2)`, `(symbol)`, `(other)`.
- `tests/test-connection-table.sps`, 210 (the fourth step's 205): S18 and S19, the cap and its resume; the answer's kind and length, never held; nineteen stream rows.
- `tests/test-connection-stream.sps`, 16 (15): a thousand 100-byte pieces, never more than 64 writes outstanding, every ask after a completion at 16 or fewer; the watch reads the writes with the bytes.
- `tests/test-shell.sps`, 110 (106): 4,000 rows of 100 bytes to a client that reads nothing yet, never more than 64 writes outstanding, then read whole and in order.
- `tests/test-connection-allocation.sps`, 26 (26): the harness performs a completion that asks for a piece; the per-piece shape compares 16, 32 and 48 pieces.
- Docs: handlers.org (the cap, gathering small rows, answering at once, a file's port, the log's naming); configuration.org (the two fixed counts).
- Records: design §4.4's M6.3 amendment and §7.3's note; decision 0005's amendment of 2026-09-29, with its prior art (h2o, nginx, Node, Go, warp and Apache, and hyper and libuv beside them, checked against their sources on the owner's ask after the PRs opened); decision 0013's second review; plan §14's note.

FOUND WHILE BUILDING:
- The allocation harness completed a stream's writes but dropped what the completions asked for, so its 64-piece stream stopped at the cap, not written whole. It performs a completion that asks for a piece now, only that one, so a stream that never waits costs what it did: a piece 304 B, the harness's own 32 B more a stream.
- The per-piece shape compared the 17th to 32nd pieces with the 33rd to 64th, and at 64 a wait at the cap put a completion's cost among the pieces': 353 B against 352. It compares the 33rd to 48th now, and CX, the growing log, still reddens it.
- The S19 helper first completed its writes by literal counts, so a mutant that miscounts a chunk made the stream rows raise while built; it reads each write's count from the state now.
- Three mutants were orphaned by the rewrite, CA, CB and CP, and re-cut on the new text.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-one suites, 1,237 expected passes, exit 0.
- The allocation suite: curl's GET streamed in 16, 32 and 48 pieces of 100 bytes 7,120, 11,984 and 16,849 B, a piece 304 B; eight pieces of 16 KiB and of 128 bytes 4,560 B each, of 100 bytes 4,688 B.
- A wrong answer's log line: 154 characters for a 100,000-character string, 153 for an empty bytevector.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,237 expected passes;
- the shell, stream, table and allocation suites, three runs each: 110, 16, 210 and 26 each time; the clients suite three runs, 13 each;
- the probe on the finished tree: another client's request waited 0.91 ms at the median (10.5 at most) behind 100-byte pieces, 0.90 ms (12.2) behind 1-byte ones and 0.11 ms (4.9) behind 16 KiB ones, 0.28 ms (16.4) with no stream; the streams read 31.2, 1.7 and 2,097.9 MB/s, and 100-byte pieces a handler gathered into 16 KiB 873.0 MB/s; per client that never read, 0.07 MB of 100-byte pieces and 0.26 MB of 16 KiB ones, and of 1-byte ones no growth measurable, the RSS falling as the heap was collected.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the fifth step): sixty-two mutants on the finished tree, the fourth step's fifty-three again, three of them re-cut, and nine more, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, still reddens the slow reader's bound with the cap in place: 16 KiB pieces meet the byte marks first.

Size: 243 inserted lines of code and tests, 61 deleted; the slice, 1,744 and 207.

NEXT: the five stacked PRs, merged bottom up on the owner's word. Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.

MERGED to main on 2026-09-29, on the owner's "do closing ritual": **M6.3, as five stacked PRs**, bottom up.
- **#74, the water marks and the piece framing,** as 6fe5651. Its squash tree (48cc431) is the tested tip's, 0c52f12's, and its parent is cbedab8.
- **#75, the core's stream,** as aad6b3d, once retargeted to main and rebased from #74's old tip: the rebased tip dcc0fe5's tree (5eac99b) is ed485c1's.
- **#76, the fake shell's flows and the allocation shapes,** as bc273ab: 7129804, tree ff82f8d, 97629f5's.
- **#77, the socket, contract and curl checks,** as 6a34361: 03545b5, tree 44c474d, 4c301cc's.
- **#78, the second review's fixes,** its two commits squashed as ea2563a: 3eef27d, tree 3370d89, 4ce8a71's.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36555535033 for #74, and 36571384652, 36571471283, 36571542231 and 36571643014 for the rebased tips.
- **Branches.** All five deleted local and remote, and refs pruned. No PR is open. The four lower PRs merged without `--delete-branch`. #78's merged it and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand. After each force-push the first read showed the old head (CONFLICTING/DIRTY for #76 to #78), and the second the rebased head, MERGEABLE/UNSTABLE.

`make test` green on main: forty-one suites, 1,237 expected passes.

DONE and merged (6fe5651, aad6b3d, bc273ab, 6a34361 and ea2563a; PRs #74 to #78): **a streamed response.** A handler's body of unknown length is a producer, chunked to HTTP/1.1 and close-delimited to 1.0. The write water marks, and 64 writes outstanding, pace it. A producer's failure after the head is a bare close, logged by its answer's kind and length.

DECIDED on the owner's word (2026-09-29), by form, while the PRs were open: **write batching goes up as its own PR, after these five.**
- **What it does.** A turn's writes under 4 KiB are copied as each is handed over, and sent as one `uv-write*!` at the drain's end, and before a shutdown or a close. A larger write sends the batch first, then goes as today. It changes the libuv shell alone: the core, its events and the contract are unchanged.
- **A scratch prototype, one run each.** On Linux, 100-byte rows 31.6 to 160.0 MB/s, and another client's median wait 0.88 to 0.22 ms; 16 KiB pieces unchanged. On Darwin, 100-byte rows 6.9 to 113.5 MB/s.
- **The copy is required.** Without it, a producer that refills one bytevector, which handlers.org allows, sent every piece of a turn as its last.
- **Where the cost was.** The core alone costs 0.08 µs a piece, so nearly all of a small piece's cost is the write path.
- **No chez-libuv issue.** `uv-write*!` and the dev-build write-request counts are all the PR uses. `uv_try_write`, and idle or check handles, would help little once batching is in, and are unmeasured.
- **Weighed:** a sixth stacked PR; a note for later.

NEXT: write batching (above), its own PR on a fresh branch cut from main after this commit, as the owner chose. Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


WRITE BATCHING, after M6.3 (feat/write-batching, cut from main at 73cfeb5): the libuv shell holds a turn's small writes and sends them as one libuv write, as the owner chose by form, its own PR after M6.3's five.
- `(http-server private shell)` alone. `write!` holds a write under 4,096 bytes (`held-below`): `hold!` copies its bytes as it holds it, behind those held, into the connection's chunks, each new one twice the last's length or the write's, so no byte is copied again before chez-libuv's copy. The drain sends what is held, `flush!`, once it has run the queue empty, and runs on while that queues more; `run!` sends it first before a `shutdown` and a `close`, and `write!` before a write of 4,096 bytes or more, which goes out alone, as before. `send!` makes every write, one guarded `uv-write*!`, and its completion, `write-done`, reports each write it carried as `write-completed`, in the order written, after one `read-error` if it failed. A raise drops what is held with what is queued. The core, its events, the water marks, the 64-write cap and the contract are unchanged.
- The checks: `tests/test-shell.sps`, 119 (main's 110): the rows a turn writes are one write request of chez-libuv's, where the core counted 48 of its writes (Darwin); each 16 KiB piece's write is one of its own; 4,000 rows handed out in one bytevector, refilled at each call, read back whole, each as it was handed over; rows whose client goes while they are outstanding, a read error, then each row's write settled, none left outstanding; a bug once a write is held sends nothing, and the close is the connection's last event. `tests/producers.sls` gains `refilled-producer`, which the stream suite's bytevector handed out again now uses (16 checks, as on main).
- Records: design §7.3's note; decision 0005's amendment of this day, and decision 0013's note; plan §14's note; docs: handlers.org (the server gathers small pieces; gathering them in the handler is still about 4.7 times faster; a piece copied as the server takes it) and configuration.org (what the 64-piece count bounds).

FOUND WHILE BUILDING:
- **chez-libuv needs no change, and no issue was filed.** Its `uv-write*!` packs a write's spans end to end in one block, but gives libuv one `uv_buf_t` a span, and libuv 1.52.1 mallocs the array of a write with more than four (`src/unix/stream.c:1370-1372`). A scratch chez-libuv giving libuv one buffer over the packed spans measured 1 to 5 % faster for 64-span writes (Linux, three runs each); the chunks make a few spans a turn.
- **Three shapes, as scratch prototypes** (Linux, three runs each, the median, for 1, 100, 1,000 and 4,000-byte pieces): each held write a bytevector of its own, 64 segments a turn, 9.7, 166, 917 and 1,534 MB/s; one bytevector grown by copying, 11.8, 172, 762 and 1,088, slower than the first at 1,000 and 4,000 bytes; chunks never copied again, 11.8, 186, 990 and 1,580, as built.
- **The cutoff stays at 4 KiB.** Held too, 8 KiB pieces streamed faster on Linux, 1,708 MB/s against 1,465, and 16 KiB ones slower, 1,814 against 2,080; on Darwin both were faster held (one run).
- **A raise now sends nothing held.** On main, a bug once the head was written still sent the head, and an HTTP/1.0 client can take a close-delimited body cut short for a whole one. A held write is dropped with the queued actions a raise drops.
- **One guarded write.** The refused write M4.2's check sends is a held one now, sent as the drain empties, so `write!`'s own guard would have been checked by nothing; every write goes through `send!`.
- The first cut of the mutant that drops the copy kept the chunks, so each write it sent ended with an empty span, which libuv finishes a turn later (`uv__write_req_update` stops on a trailing empty buffer), so a close cancelled it. Re-cut with no chunks. The finished code sends no empty span: the core writes only segments with bytes.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-one suites, 1,246 expected passes, exit 0.
- The red before green: against main's shell, the finished tests failed twice. The rows' one-write check read the core's 52 writes outstanding and 52 write requests, and the held write's bug check read the head main sent.
- A scratch server whose producers never end, a client reading as fast as it can, another sending a GET every 2 ms, main against the finished tree, three runs each, the median: 1-byte pieces 0.4 to 7.8 MB/s, 100-byte 7.3 to 131.9, 1,000-byte 68.1 to 898.8, 4,000-byte 264.5 to 1,370.5; another client's median wait behind the 100-byte pieces 3.24 ms to 0.37; 8 and 16 KiB pieces as before, 522.5 and 799.0 MB/s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, threaded, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,246 expected passes;
- the shell, contract, stream and clients suites, three runs each: 119, 65, 16 and 13 each time;
- the probe, the same way: 1-byte pieces 1.9 to 11.4 MB/s, 100-byte 32.4 to 180.8, 1,000-byte 274.4 to 965.0, 4,000-byte 899.6 to 1,578.4; another client's median wait behind them 0.80, 0.81, 0.82 and 0.93 ms to 0.19, 0.20, 0.29 and 0.62; 8 and 16 KiB pieces as before, 1,444.0 and 2,107.6 MB/s; 100-byte rows a handler gathers into 16 KiB pieces 852.6 MB/s, about 4.7 times the rows one at a time, where it was about 26;
- ten clients that never read, one run each: 0.05 MB each of 100-byte pieces and 0.26 MB of 16 KiB ones, as on main, and 0.04 MB of 1-byte ones.

Watched to fail (m6-mutations.md, "Write batching"): twenty-one mutants on the finished tree against all forty-one suites, sixteen of them new (batch-A to batch-O, and batch-A2, a calibration), M4.2's four on the write path re-cut on the new code, and M4.2-X re-run; every check this change added or changed is reddened by at least one. Three survive: batch-D, the writes held not sent before a shutdown, a scope statement, since the core asks for a shutdown only once every write has completed; batch-L, the chunks' growth, a scope statement, a cost and never the bytes; batch-A2, the calibration, as meant.

Size: 259 inserted lines of code and tests, 73 deleted: one PR, under plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-29), by form, after the walkthrough: committed and opened as one PR. Weighed: holding it for changes.

NEXT: the PR, merged on the owner's "do closing ritual". Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


WRITE BATCHING, ITS REVIEW (2026-09-29, PR #79 open): a /code-review high, on the owner's ask, found seven, none a correctness bug; then, on the owner's ask, a deeper review of three of them, each measured with scratch prototypes.
- (1) **A stream's head waited for the turn.** What was held went out only as the drain emptied, so a stream's head and first pieces waited for the turn's producer calls, up to 64. On Linux (Docker, five runs each, the median), a producer taking 200 µs a piece delayed its head from 0.12 ms to 12.74, one taking 2 ms from 0.14 to 126.3, one answering at once from 0.08 to 0.12; every stream still ended as soon or sooner. Two fixes were prototyped: what is held sent before the drain's first producer call, the head back at 0.10 to 0.19 ms, throughput unchanged (100-byte pieces 180.3 MB/s against 183.7); and what has been held a millisecond sent before each producer call, a slow producer's pieces as made, but fast small pieces 5 to 17 % slower (1-byte 11.5 MB/s to 9.6) and a turn's batch hanging on time, one check failing.
- (5) **`hold!`'s `fold-left` made a closure for every write held:** 32 bytes and some 6 ns in a scratch library (28.5 ns against 22.8 for a named let); through a whole process, some 15 of a piece's 1,430 bytes, its time within noise.
- (6) **The copy of a lone small response is not waste:** a process serving itself small keep-alive GETs allocated 367 bytes a request less than main's (11,561 against 11,928), one span costing chez-libuv less than four segments, and a prototype sending a lone write by reference 384 more (Darwin, 20,000 requests, three runs each).
- The other four: (2) a turn's one write refused at the call was tested with one write only; (3) handlers.org's "under 4 KiB" left out the chunk framing; (4) a completion's writes are dispatched one by one, so the producer refills at 16 and a batch carries 48; (7) the dev-build counters' guard is repeated in the shell suite.

DECIDED on the owner's word (2026-09-29), by form, after the deeper review: (1) what is held goes out before the drain's first producer call, and handlers.org says the pieces go out a turn at a time; weighed: the docs alone; a flush after a millisecond. (5) a named let. (2) and (3) fixed. (4) and (7) left. (6) no change, the premise measured wrong.

The fixes, a second commit on feat/write-batching:
- `(http-server private shell)`: the connection's `producer-called?`, cleared as each drain starts; `run!` sends what is held before the drain's first `notify-producer`. `hold!` copies with a named let.
- The checks: `tests/test-shell.sps`, 125 (the first commit's 119): a stream's head sent before its producer is first called, one write request, on a stream behind another on one connection; rows whose handle is closed behind the core mid-turn, the turn's one write refused at the call, a read error, then each row's write settled, none outstanding; pieces of 100 bytes and 5,000 in turn, read back in order.
- Docs: handlers.org, gathered pieces of up to 4,088 bytes, the headers before the producer's first call, the pieces up to 64 at a time.
- Records: design §7.3's note, re-measured; decision 0005's amendment and 0013's note; plan §14's note; m6-mutations.md, "After the PR's review".

FOUND WHILE FIXING: sending the head first let batch-E, the writes held not sent before a larger write, survive: the MiB's check had killed it, its head held when its first 16 KiB piece was written, and now nothing is held then. The mixed pieces' check was added for it.

Measured on the fixed tree (2026-09-29):
- `make test` green on Darwin arm64: forty-one suites, 1,252 expected passes, exit 0. On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, libuv 1.44.2), from a copy made with `COPYFILE_DISABLE=1`, curl and ab installed, less the submodule and pin checks: forty-one suites, 1,252; the shell, contract, stream and clients suites three runs each: 125, 65, 16 and 13 each time.
- Red before green: on the first commit's shell, the head-first check failed, its producer's first call finding no write request more than the handler had.
- The head, Linux, five runs each, the median, for producers taking 0, 20, 200 and 2,000 µs a piece: 0.10, 0.10, 0.13 and 0.19 ms, where main sent it at 0.09, 0.09, 0.12 and 0.20; the first piece at 0.10, 1.37, 12.76 and 126.37, where main's at 0.09, 0.09, 0.33 and 2.22; the stream's end at 0.26, 5.32, 51.52 and 513.03, where main's at 0.95, 6.32, 53.11 and 515.16. On Darwin the head at 0.21 to 0.32 ms, where main's at 0.13 to 0.27.
- The probe, main against the fixed tree, three runs each, the median. Linux: 1-byte pieces 1.9 to 11.4 MB/s, 100-byte 32.8 to 182.9, 1,000-byte 284.2 to 989.1, 4,000-byte 864.8 to 1,569.7; 8 and 16 KiB as before, 1,444.9 and 2,066.0; another client's median wait behind the 100-byte pieces 0.85 ms to 0.19; 100-byte rows a handler gathers 851.1 MB/s, about 4.7 times the rows one at a time. Darwin: 1-byte 0.4 to 7.9, 100-byte 7.3 to 132.4, 1,000-byte 68.2 to 905.2, 4,000-byte 265.5 to 1,385.1; the wait 3.24 ms to 0.37.
- Ten clients that never read, Linux, one run each: 0.03 MB each of 100-byte pieces, where main's 0.05, and 0.26 MB of 16 KiB ones, as main's.
- One process serving itself (Darwin, three runs each): a small keep-alive GET 11,577 bytes and 53.4 µs, where main's 11,920 and 54.3; a streamed 100-byte piece 1,661 bytes and 0.73 µs, where main's 3,913 and 12.2 µs.

Watched to fail (m6-mutations.md, "After the PR's review"): twenty-five mutants on the fixed tree against all forty-one suites, the twenty-one before, three of them re-cut for the named let, and four new, batch-P to batch-S; every check the fixes added is reddened by at least one. Three survive, as before: batch-D and batch-L, scope statements, and batch-A2, the calibration.

Size, the second commit: 122 inserted lines of code and tests, 28 deleted; the PR against main, 361 and 81, under plan §1 rule 1's ~400.

NEXT: the PR, updated, merged on the owner's "do closing ritual". Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.

MERGED to main on 2026-09-29, on the owner's "do ritual": **write batching, PR #79**, its two commits (c7014af, d1bdb41) squashed as 83cebc9. Its squash tree (6c1846c) is the tested tip's, d1bdb41's, and its parent is 73cfeb5.
- **CI.** Both runs were the billing block, the `linux` job with 0 steps: 36593668069 for c7014af and 36635425131 for d1bdb41.
- **Branches.** `--delete-branch` merged it, switched this checkout to main, fast-forwarded it, and deleted the branch local and remote; `git fetch --prune` cleared the remote ref. No PR is open.

`make test` green on main: forty-one suites, 1,252 expected passes.

DONE and merged (83cebc9; PR #79): **write batching.** The libuv shell holds a turn's small writes and sends them as one libuv write, a stream's head first. On Linux, 100-byte pieces stream 182.9 MB/s where they streamed 32.8, and another client waits 0.19 ms at the median behind them where it waited 0.85; the core, its events and the contract are unchanged.

NEXT: M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


M6.4, EXPECT, TRAILERS AND THE EXIT'S FILES (feat/m6.4-expect-trailers, cut from main at e1a57f6), on the owner's "Let's start on M6.4".

DECIDED on the owner's word (2026-09-29), by form, before anything was built, each on numbers measured on main (Darwin arm64, the fake shell, and curl 8.7.1 against a scratch server):
- **Trailer fields are held to the four header limits, counted afresh.** On main, 101 trailer fields, a 9,000-byte trailer value and 16 MB of trailers were each answered 200. Weighed: one budget with the head; the body's cap, as freenginx counts them, which would leave them unbounded by default here.
- **A body's chunk extensions, all of them together, are held to 16 KiB, answered 413** (found, not in the plan). On main a 16-byte body carrying 16 MB of extensions was answered 200: the kind of attack Node's CVE-2024-22019 fixed. hyper holds a body's to 16 KiB; Node holds each chunk's to 16 KiB, with a 413 (corrected in the review below: the form called 16 KiB "hyper's and Node's figure"). Weighed: left for M8.3.
- **An Expect other than 100-continue is ignored**, as nginx and hyper ignore it. Weighed: 417, as Go, Apache, Node and Python answer.
- **libhtp's two Expect files are delivered with CRLF**, and 99's handler refuses `/forbidden` as its recorded origin did: after a discussion the owner asked for ("i need more discussion on this"). Both files end their lines in a bare LF, which the strict parser refuses at the first line (`invalid-version`, bytes 16 and 24), so as vendored they check only that, which llhttp's fixture "Only LFs present" pins already. Weighed: their 400s; our own CRLF copies; left not-yet, the M6 exit amended.
- **What the parser reads and hands the core no span of gets its own PR, after M6.4** (found while checking the extension cap): the spaces between a field's colon and its value, in a head or a trailer section, and a chunk size's leading zeros; a megabyte of either was answered 200. Weighed: folded into M6.4; asked of chez-httparse first (decision 0008). Go refuses a chunk size of more than 16 hex digits and a size line over 4 KiB, nginx a header line over 8 KiB.

What was built:
- `(http-server connection)`: a request's client waits for `100 Continue` when it is HTTP/1.1, announces a body, and its Expect lists 100-continue (`body-continue?`); then the head arms no body deadline. Accepting a reader writes the 100 first, `accept-reader`, before what reading brings (`read-with`, the rest of the old procedure), and arms the body deadline while the connection still reads; a reader refused by its cap, a response instead, and a handler that raises get their final status alone (the review below: a cap the body met so far passes is answered after the 100). The 100's completion is settled in `body`, `handling` and `awaiting-credit` too. In `body`, a trailer's name and value are counted as a head's are (`trailer-bytes`, and `field-bytes` and `field-counted`, shared with the head's `header-bytes`), the head's sizes started again for them, and a chunk extension's name and value bytes are counted over the whole body against `max-chunk-extension-bytes`, 16,384 (`extension-bytes`).
- `(http-server headers)`: `field-lists?`, whether a field's comma-separated list holds a token, without regard to case, OWS trimmed, over any of its lines, read in place.
- `(http-server serializer)`: `serialize-continue`, the 100 as one shared segment, its status line and the blank line.
- `(http-server decisions)`: `chunk-extensions-too-large`, 413.
- `tests/libhtp-lane.sls`: `libhtp-packets`, the two Expect streams delivered with CRLF (`crlf-files`); `handler-for`, 99's refusing `/forbidden`; the two expectations. `tests/ratchet.txt`: both promoted, fourteen libhtp streams passing.

The checks:
- `tests/test-connection-table.sps`, 258 (main's 210): E1 to E7 for Expect, E8 for the 100's completion through M3.3's accounting step, F1 to F7 for the trailers and extensions, and their three counts.
- `tests/test-connection-expect.sps`, new, 14: at every delivery size, the 100 first for a streaming and a whole reader, the 100 as a client reads it, none for a response instead, on HTTP/1.0, with no body, or for another expectation; the 408 once the body deadline armed with the 100 passes; trailers as large as a head after a head near the limits served, and a section, a count and a value past them answered 431; extensions at 16 KiB served over two chunks, and a byte more 413, at sampled sizes.
- `tests/test-headers.sps`, 21 (18): `field-lists?`.
- `tests/test-shell.sps`, 129 (125): a client that waits for the 100 on a socket reads it alone before it sends its body, then the response; one answered at once gets no 100 and the stream's end.
- `tests/test-contract.sps`, 68 (65): a body expecting 100-continue, sent once the server has read the head.
- `tests/test-clients.sps`, 14 (13): curl, with `--expect100-timeout 60`, reads the 100, then the response.
- `tests/test-connection-originated.sps`, 23 (21): a body's extensions past 16 KiB, 413; a trailer value past its limit, 431; both with `kept`, the shape of a refusal met in the head's delivery.
- `tests/test-libhtp-lane.sps`, 19 (15): fourteen streams; the scope over the streams as delivered; every other stream delivered as cut; the two converted and nothing else changed. `tests/test-ratchet.sps`, 9: fourteen passing, 88 not-yet.
- Records: design §4.3's `body` row and §4.4's M6.4 amendment, §8.2's note; decision 0013's built note; decision 0005's amendment of this day; plan §14's note. Docs: handlers.org (Expect, trailers), connections.org (the 100 and the body timeout), configuration.org (the trailers' and extensions' limits), responses.org (413, 431).

FOUND WHILE BUILDING:
- **The 100 goes out though the whole body came with the head.** Omitting it then, as RFC 9110 allows, would make what happens depend on how the bytes were split into reads; a client must be able to read a 100 it did not wait for.
- **The Expect files' bodies say where their line ends came from.** 05's is curl 7.18's upload, and its body is its Content-Length, 216 bytes, only with CRLF: 210 as vendored. 99's was written by hand: its 14 bytes count a bare LF.
- **The lane's scope holds as delivered.** Its check counts the streams that carry pipelining or a split request; with CRLF both Expect streams carry a request split across packets, so the scope check reads the packets the lane delivers.
- **Two survivors, J and K**: the 100's completion ignored in `handling` or `awaiting-credit` leaves the phase and actions as they were, and E8 read only those. On a v1 shell those completions cannot come there, the reader's response following in the same turn, so only a row can reach them; E8 now reads the writes outstanding, and both redden it.
- **Four contract scripts were written and taken out**: the trailers and extensions within and past their limits, and an Expect head answered at once. The shells share the core and differ in nothing those scripts exercise, so no fault of either could redden them. The contract keeps the one new thing a shell does, a write while the connection still reads.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-two suites, 1,331 expected passes, exit 0 (main's forty-one, 1,252).
- Red before green: against main's source, the finished table failed 24 checks, the new flows suite 8, the shell suite 2, curl's 1 (held past the cap, 24 s), and the lane's 05.
- curl 8.7.1 asks for the 100 on an upload of 1,048,577 bytes or more, POST and PUT alike, and not at 1,048,576. Against a scratch server, main's source and this tree, three runs each: a 2 MiB POST took 1.016 s on main, waiting out curl's own second, and takes 5.4 to 6.4 ms; with Expect off, main 5.9 to 20.7 ms and this tree 5.0 to 5.3; a 100-byte POST with Expect forced, main 1.011 to 1.012 s, this tree 0.87 to 0.88 ms; a handler that refuses at once, 403 and no byte uploaded, main 0.9 to 1.2 ms, this tree 0.7 to 0.9.
- The probes that measured main, run again (the fake shell, the default limits): 101 trailer fields, a 9,000-byte trailer value and 16 MB of trailers are answered 431, the 16 MB refused in 3.0 ms of CPU where they were read in 40; 16 MB of extensions on a 16-byte body 413 in 2.5 ms, where 65; a MB of spaces before a field's value, in a head or a trailer section, and a MB of a chunk size's zeros, still 200, the next PR's.
- The allocation suite's figures are main's: curl's GET 1,840 B, the JSON POST 2,624 read whole and 2,432 streamed, ab -k's GET 2,112. A scratch probe, two runs: the Expect check costs a POST without Expect nothing, and a POST expecting 100-continue 128 B more than one with a field of the same size that is not Expect, the 100's write and its completion.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-two suites, 1,331 expected passes;
- the shell, contract, flows and clients suites, three runs each: 129, 68, 14 and 14 each time;
- curl 7.88.1 asks for the 100 from 1,048,577 bytes too; a 2 MiB POST, three runs each: main's source 1.006 to 1.017 s, this tree 1.2 to 1.8 ms; with Expect off, main 1.2 to 2.1 ms, this tree 1.1 to 1.3 ms.

Watched to fail (m6-mutations.md, "M6.4"): forty mutants on the finished tree against all forty-two suites, thirty-nine by `mut.py` and one by hand, and every check this slice added or changed reddened by at least one. None survives: J and K did, until E8 read the writes outstanding. The plan's mutation, the 100 written with the head (M6.4-A), turns the Expect rows red, E1 to E6, and the flows, the lane's two files and the socket's refusal.

Size: 1,079 inserted lines of code and tests (the new flows suite's 252 among them), 112 deleted; over plan §1 rule 1's ~400, so it goes up as PRs of their own.

DECIDED on the owner's word (2026-09-29), by form, after the walkthrough: **three stacked PRs**, each green on its own, proved in a scratch tree of its own files before its commit: the 100 in the core and the fake shell, with the header helper; the 100 on the wire, in the socket, contract and curl checks, and libhtp's two files; the trailer and extension limits, with the records. Weighed: two, four (the header helper apart), one. Measured once cut, against main, then each on the one below: 527, 206 and 359 inserted lines of code and tests, and 60, 42 and 23 deleted, where the form estimated about 460, 210 and 410. The first layer passes forty-two suites, 1,289 expected passes, the second 1,301, the third 1,331.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, then the M6 exit.

M6.4, ITS REVIEW (2026-09-29, PRs #80 to #82 open): a /code-review high, on the owner's ask, found five. The owner asked for the second and third fixed, and for more on the first: how the servers researched hold chunk extensions.
- (1) **The extensions' cap, 16 KiB for a body's together, would refuse an upload that signs every chunk**, S3's aws-chunked. Its premise did not hold: AWS's docs put `chunk-signature` in the body, under `Content-Encoding: aws-chunked` and a Content-Length that counts it, not in HTTP chunk extensions; hyper #3522, an S3 server's author asking hyper to hand extensions on, was declined, and a later comment calls the two orthogonal. No report was found of hyper's or Node's cap refusing a client; the one sender found is ICAP's `0; ieof`, not HTTP. RFC 9112 §7.1.1: a server "ought to limit the total length of chunk extensions received in a request". Read in each server's source by three research agents, the decisive lines checked again here:
  - hyper holds a body's extensions to 16 KiB (16,383 bytes pass), its count never restarted, and hands the error to the service, which answers;
  - freenginx counts every byte of a body's extensions and trailer lines against `client_max_body_size`, 1 MiB by default, 413;
  - h2o fails a body once its bytes that are not data pass 100 KiB while the data is under a quarter of all it read, 400, and holds a size to 16 hex digits;
  - Go lets a body's size lines run 16 KiB past a credit of 16 bytes and twice the data for each chunk, holds a line to 4 KiB and a size to 16 hex digits, and leaves the status to the handler;
  - Node holds each chunk's to 16 KiB, its count restarted at every chunk header, 413; its own test serves three chunks of about 10 KB each;
  - h11 holds an unfinished line to about 16 KiB, so as the reads fall; Racket a size line to 8 KiB, and closes with no response;
  - nginx and Warp hold none, and Warp misframes a size line longer than a read (read and modelled, not run).
  Behind Caddy none arrives: Go's chunk reader drops them (read, not run).
- (2) **The 100 before a refusal the core already holds**, which the finding would have left out. Its premise, that the split already changed that outcome, was measured wrong on a probe: a bad chunk after an Expect head gets the 100, then 400, at all 90 delivery sizes, and the finding's change split them, the 100 at 32 and none at 58. Beside it the probe found the split deciding: a chunked 10-byte body read whole within 4 bytes got the 100 then 413 at 30 of its 99 sizes, and 413 alone at 69, the cap checked before the 100 against the body met so far, which only some splits had met; main sends no 100 at any.
- (3) **The header's write accounting named only `responding` and `closing`** for a completion.
- (4) `find-comma` is copied from `(http-server transfer-coding)`; (5) no deadline is armed while an Expect request waits on its handler, which the shells call at once. Left: not asked for (5 researched the next day, below).

DECIDED on the owner's word (2026-09-29), by form, after the research: (2) the 100 still goes first, and the cap case is fixed, so every split gets one outcome; the finding withdrawn. Weighed: the 100 left out once a refusal is known, as the finding asked, a departure from design §8.1. (1) 16 KiB a body kept, the finding withdrawn, and the records corrected: the form had called 16 KiB "hyper's and Node's figure", and decision 0005's amendment and the core's comments had Node holding a body's. Weighed: Go's allowance, growing with the data, in the padding PR; 16 KiB a chunk, as Node. The fixes go into the PRs they belong to, the PRs above rebased and pushed with a lease. Weighed: one fix commit on #82.

The fixes:
- #80, a second commit (f745d7f): `accept-reader` refuses a reader whose cap the declared length passes before the 100, and `read-with` one whose cap the body met so far passes, after it; the header's write accounting names `body`, `handling` and `awaiting-credit` for the 100's completion, and its Expect section says what the head's feed met is answered after the 100. The checks: `tests/test-connection-expect.sps`, 16 (14), a declared length past a whole reader's cap, 413 and no 100, and a chunked body past it, the 100 then 413, each at every delivery size; `tests/test-connection-table.sps`, 260 (258), E6's body met past the cap, in `body` and, the body ended, in `handling`.
- #81 and #82 rebased onto it: #81's patch unchanged; #82's one conflict, the flows suite's header, keeps both paragraphs.
- #82, a second commit: the records. Design §4.4's M6.4 row and note, and §7.3's note of the 100's completion; decision 0005's amendment, corrected and weighed again; the core's two comments on Node; m6-mutations.md; this entry.

Measured (2026-09-29):
- `make test` green on Darwin arm64, each layer on its own tree: #80's forty-two suites, 1,293 expected passes (1,289 before the review); #81's 1,305 (1,301); #82's 1,335 (1,331), exit 0.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, libuv 1.44.2, curl 7.88.1), from a copy of #82's tree made with `COPYFILE_DISABLE=1`, less the submodule and pin checks: forty-two suites, 1,335 expected passes, exit 0; the shell, contract, flows and clients suites, three runs each: 129, 68, 16 and 14 each time.
- Red before green: on #80's first commit, the flows' chunked body past the cap failed, and E6's two new instances; the declared length's check passed there, and is watched red by R2.

Watched to fail (m6-mutations.md, "After the PRs' review"): two mutants on #82's tree against all forty-two suites: M6.4-R1, the body met checked before the 100 as before the fix, reddens the flows' body past the cap and E6's two instances; M6.4-R2, the declared length checked after the 100, the flows' declared length and E7. Forty-two mutants in all; none survives.

Size of code and tests: #80's second commit, 94 inserted lines and 52 deleted, most of them `read-with` indented anew; the layers, against main and then each on the one below, 551, 206 and 362 inserted, and 42, 42 and 23 deleted.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, its design by form on measurements, then the M6 exit.

M6.4's REVIEW, THE FIFTH FINDING RESEARCHED (2026-09-30, PRs #80 to #82 open), on the owner's "Research 5 in more detail": no deadline is armed while an Expect request waits on its handler.
- **Empty in v1.** Both shells call the handler in place, and its answer is dispatched in the same drain (`call-handler!` in `(http-server private shell)`, `perform-connection!` in `tests/fake-shell.sls`), so no tick and no read can come between the question and the answer.
- **What M7's awaiting handler would meet**, probed on the core with the answer held back (a scratch program, states built as the table builds them): an Expect head alone arms nothing until the answer, which writes the 100 and arms the body deadline; a body met in full, with or without Expect, leaves `handling` with nothing armed, design §4.3's "a slow handler is the application's problem"; a piece the client sends without waiting arms the body deadline, and a stall after it, like a head without Expect whose client sends nothing, is answered 408 while the handler has not answered, its late answer then changing nothing. The client cannot lengthen the Expect wait: it lasts as long as the handler takes.
- **Six servers, read in their source by two research agents, the decisive lines checked again here:**
  - hyper writes the 100 when the service first polls the body, and bounds nothing: its one timer is the head's, 30 s, off unless a timer is given;
  - Warp writes it on the application's first body read, and pauses its 30 s timer while the application runs ("Let the application run for as long as it wants");
  - Go writes it on the handler's first body read, and bounds nothing by default: `ReadTimeout`, opt-in, starts before the head and spans the handler; `TimeoutHandler`, opt-in, answers 503;
  - nginx writes it when a module starts reading the body, a proxy before it asks its backend, arms no client timer between head and decision, and bounds a backend's answer to 60 s, then 504;
  - Node writes it at once unless the application listens for `checkContinue`; its whole-request timer, 300 s from the request's first byte, then answers 408;
  - h2o writes it at once, before any handler, and its request timers stop before the handler runs.
- **Clients** send the body without the 100 after 1 s (curl 8.22.0's default, Go's default transport, .NET 10), 3 s (Apache HttpClient 4 and 5) or 5 s (Java 24 on, fixed); Java 21 waits with no timer of its own.

DECIDED on the owner's word (2026-09-30), by form: the finding is closed as the design's, and plan §14's M7 carries it, so that M7's rows cover the wait with the others: reading stopped while such a handler has not answered, nothing armed, and its answer bringing the 100, reading and the body deadline. Weighed: M7.2 also weighing an opt-in limit on a handler's decision time; leaving it unrecorded.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, its design by form on measurements, then the M6 exit.

MERGED to main on 2026-09-30, on the owner's "do closing ritual": **M6.4, as three stacked PRs**, bottom up.
- **#80, the 100 in the core,** its two commits (c87e01b, and the review's fix f745d7f) squashed as a149def. Its squash tree (22ad889) is the tested tip's, f745d7f's, and its parent is e1a57f6. It merged first and kept its branch, since #81 was based on it.
- **#81, the 100 on the wire and libhtp's two Expect files,** retargeted to main and rebased from #80's tip, f745d7f: 91becde became 0f9320c, its tree (85bf4a5) the tested one's, and it merged as 23ce73c, whose parent is a149def.
- **#82, the trailer and extension limits and M6.4's records,** retargeted and rebased from #81's old tip, 91becde: its three commits (2dc1f03, ec0869b, 778a472) became e159a78, acb8e93 and a7f19a0, the tip's tree (7c000e2) the tested 778a472's, and they merged as d7c4b30, whose parent is 23ce73c.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36650182193, 36650185023 and 36650187998 as opened; 36655148024, 36655150142 and 36655149369 after the review; 36696914621 for the M7 note; 36697213666 and 36697301376 for the rebased tips.
- **Branches.** #82's `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #20, #22, #68, #70, #72 and #73: the switch to main, the fast-forward and the three local deletions were by hand, and #80's and #81's remote branches went in one `git push origin --delete`. No PR is open.

`make test` green on main: forty-two suites, 1,335 expected passes.

DONE and merged (a149def, 23ce73c, d7c4b30; PRs #80 to #82): **M6.4, Expect, trailers and the exit's files.** A client that expects 100-continue is sent it when the handler answers with a reader, at every delivery size, and the body deadline waits for it: curl's 2 MiB POST, which waited out its own second on main, takes 5.4 to 6.4 ms on Darwin and 1.2 to 1.8 on Linux. A chunked body's trailers are held to the four header limits, 431, and its extensions to 16 KiB a body, 413. libhtp's two Expect files join the lane with CRLF: fourteen streams pass. The review fixed the 100 before a body met past a reader's cap, kept the extensions' rule after reading eight servers' source, and carried the Expect wait to M7.

NEXT: the padding PR (the owner's word, by form, 2026-09-29: its own PR after M6.4): the spaces before a field's value and a chunk size's leading zeros, which the parser hands the core no span of, its design by form on measurements, when the owner asks. Then the M6 exit (plan §14).


THE PADDING PR (fix/padding-limits, cut from main at d52ab78), on the owner's "start the padding PR".

Measured on main first (2026-09-30, Darwin arm64, the fake shell, the default limits, 16 KiB reads): the parser reads four runs of bytes it hands the core no span of, and a megabyte of each was answered 200: spaces or tabs before a field's value, in a head or a trailer section, an empty value's among them; zeros before a chunk size, a data chunk's or the last's; spaces past the one between the request line's parts; and empty lines, CR or LF, before a request line, at a connection's start or between requests. The strict parser refuses the rest (a folded line, spaces before a colon or after a chunk size or a version, a tab in the request line), and an extension's `;` and `=` are the only bytes of it left uncounted, at most 5 for 3 counted (wrong for empty names and values, which the strict parser takes: the review below). Two of the four were found at this step: the ledger's M6.4 entry named the whitespace and the zeros.

How the core can see them: inside every callback the parser's runtime says how many bytes it has read (byte-machine's committed offset, `parser-stream-offset`; chez-httparse's own test adapter reads it). At every delivery size an event callback sees the same number (45 of 45 sizes for a padded head, 95 of 95 for padded chunks), and a span's is its feed's first byte plus its end. Prototyped in a scratch tree, the adapter passing it with each event callback and the core measuring each run from where one piece ends to where the next begins, checked at the callbacks and at every read's end: one outcome at every delivery size sampled, 81 to 328 each; curl's GET 1,840 B a request, as on main; 4.55 µs a request against main's 4.45 to 4.60.

The servers researched, read in their source by three research agents, the decisive lines checked again here, and Node 20.10.0, Racket 9.3's web-server, h11 and Go 1.26 (in Caddy 2.11.2) run:
- whitespace before a value: counted by all but Node, in a head or a line (Go 1 MiB + 4 KiB, 431; nginx 8 KiB a line, 400; hyper and h2o 417,792 B; Warp 50 KiB, 400; Racket 8 KiB a line, closed; h11 16 KiB, only while a head is incomplete);
- request-line spaces: 400 from Go, hyper, h11 and Warp; counted in the request line by nginx (414), h2o and Racket; Node neither;
- empty lines: none from Go (4 bytes forgiven after a POST), h11, Warp and Racket; one from freenginx (since 2024, "multiple CRLFs cannot be used as a DoS vector") and h2o; any number in hyper's 417,792 B; nginx and Node unbounded;
- a chunk size's digits: 16, zeros included, in Go and h2o, 20 in h11, a line of 8 KiB in Racket; nginx, freenginx, hyper, Node and Warp only overflow.
Behind Caddy none of the four arrives: it refuses the spaces and the empty lines, counts the whitespace in its 1 MiB head and holds a size to 16 digits.

DECIDED on the owner's word (2026-09-30), by form, on those numbers:
- **Whitespace before a field's value counts with the value**, against its limit, 8 KiB, and the section's, 16 KiB, 431, in a head and in a trailer section, as the whitespace after it already does. Weighed: every byte of each line, the peers' way. The space after a colon counts, so a field at an exact limit moves by that byte.
- **A chunk size has at most 16 hex digits, zeros included, 400**, as Go and h2o hold it. Weighed: 20, as h11; Go's allowance for bytes that are not data.
- **More than one space between the request line's parts is refused, 400**, as RFC 9112 §3's grammar has it and Go, hyper, h11 and Warp answer. Weighed: counted with the target, 414, as nginx counts its request line.
- **One empty line before a request line is skipped, a second refused, 400**, as RFC 9112 §2.2 asks a server to ignore one, and as freenginx and h2o do. Weighed: counted with the target, 414; none, as Go, h11, Warp and Racket, which would fail libhtp's passing stream 61 and llhttp's two fixtures that open with one.

DECIDED again on the owner's word (2026-09-30), by form, once the rule was built: **two empty lines, 4 bytes, before a request line, then 400.** The first form said the corpora carried one at most; the scan behind it read only where each input began and ended, and llhttp's fixture "CRLF between requests, implicit `keep-alive`" (connection.md#5) has a POST's 4-byte body followed by two, which the rule of one refused: the trace lane went red, the core changing what the parser does. Two is Go's allowance after a POST ("tolerance for old buggy clients"). Weighed: two after a body only, one elsewhere; one, the fixture a recorded exception to the trace lane's rule.

What was built:
- `(http-server private adapter)`: every event callback passes the parser's position, `parser-stream-offset`, and on-headers-complete passes it after `upgrade`.
- `(http-server connection)`: the event entry is `(conn-parser-step s name at)` and on-headers-complete takes `at` last; the tagged lists follow, `(parser-event name at)` and on-headers-complete's seventh field (decision 0002's amendment of this day). The state keeps where the parser is: the bytes it has taken (`parsed`, each read's `consumed`), the position of index 0 of the delivery being fed (`base`, set as the core asks for a feed; the rest a pause keeps is fed with its delivery's), and the one run open (`mark`, `run`, `open-run!`): `lines` from a message's end, or the connection's first byte, to on-message-begin; `after-method` to the target's first bytes; `target`, the target's own, only so its end is known; `after-target`, opened at on-url-complete one byte past the target's end, to the protocol's first bytes; `whitespace` from on-header-field-complete to the value's first bytes, in a head or a trailer section; `digits` from a chunked head's end, or on-chunk-complete, to the first extension's name or on-chunk-header. A run is judged at the callback that ends it: past 4 bytes of empty lines, `empty-lines`; past one space, `request-line-spaces`; past 16 digits, `chunk-size-too-long`; the whitespace kept as the value's `pad` and counted with it and the section. At a read's end `run-past-limit` judges the open run, the digits allowed the byte that ends them, `;` or CR, and at the parser's error only the whitespace; `refuse-run` answers it as a callback's refusal is answered, from idle into head first, through `answer-refusal`, the error branch, now shared.
- `(http-server decisions)`: the three reasons, 400.
- Docs: configuration.org, the whitespace counted with a value, a chunk size's 16 digits, the two empty lines and the one space; responses.org, the 400s.

The checks:
- `tests/test-connection-entry.sps`, 33 (main's 30): an event callback without the parser's position refused, all fifteen; a span callback given a position in place of its span, all ten; on-headers-complete without it; the callbacks recorded from a parse carry the positions the parser commits.
- `tests/test-connection-table.sps`, 293 (260): every event row carries a position, and the synthetic heads read as a parse reads them: a target in a request line, a field line with its one space, a chunked head's first size line; G1 to G12, 32 instances, and their count.
- `tests/test-connection-padding.sps`, new, 15: each run at every delivery size, within its limit and a byte past, each read in a bytevector of its own at an offset, as a shell hands one over; the megabyte runs main answered 200 at sampled sizes; and the work a run costs, a megabyte of each fed to the parser one 16 KiB read.
- `tests/test-connection-originated.sps`, 26 (23): the three 400s end to end. `tests/test-connection-head.sps`, 52, and `tests/test-connection-expect.sps`, 16: their exact-limit checks count the space after a colon.

FOUND WHILE BUILDING:
- **The first form's premise was wrong** (the second form, above).
- **A request line with no version** (llhttp's "No HTTP version", sample.md#10): the run after the target first opened at every on-url-complete, so a line end met at a read's end counted as spaces, and the outcome lane split the fixture, 400 a byte at a time, 200 whole. The run opens only one byte past the target's end; a line end is two (true of a CRLF only: a bare LF is one byte too, and the review below found the split it left).
- **A span the parser's error cuts off is never handed on** (chez-httparse: "an error abandons an open span"), so at the parser's error a run's bytes could hold it: only the whitespace is judged there, its value counting with it anyway. A run past its limit and then cut off by a malformed target or chunk size is 400 at every size, its reason the run's or the parser's by the split (not an extension, whose name ends the size's run first: the review below). The same cut already splits main's own limits: a 9,000-byte target then a control byte is 400 at 63 of 174 delivery sizes and 414 at 111, a 9,000-byte field name 400 at 61 and 431 at 113. Not this PR's; for the owner.
- **The fake shell hands every read as a slice of one bytevector**, indexed from the connection's first byte, so a delivery's base of 0 was right by accident: the first mutation run's survivor P-C. The flows hand each read in a bytevector of its own. P-D, the pending rest's base set anew, was equivalent, and its line went.

Measured on the finished tree (2026-09-30, Darwin arm64):
- `make test` green: forty-three suites, 1,389 expected passes, exit 0 (main's forty-two, 1,335).
- Red before green: on the vocabulary step against main's core, the entry suite's two new refusals; on the vocabulary step's core, which reads no position, the table's sixteen refusal instances; against main's core and adapter, twelve of the flows' fifteen.
- The probes that measured main, run again: every megabyte run refused, the empty lines before a request line or between two, the request line's spaces and a chunk size's zeros 400, the whitespace before a value, in a head or a trailer section, an empty value's too, 431; two spaces in a request line 400.
- The allocation suite's figures are main's: curl's GET 1,840 B, the JSON POST 2,624 read whole and 2,432 streamed, ab -k's GET 2,112, a browser's GET 3,312.
- CPU, main's core against this tree, the fake shell, three runs each: curl's GET 4.55 to 4.80 µs a request against 4.65 to 4.75, a browser's 8.90 to 8.95 against 8.90 to 9.15, a four-chunk POST 6.30 to 6.65 against 6.35 to 6.45; a body of 200,000 one-byte chunks in 16 KiB reads, five runs a process, 65 to 69 ms against 67 to 73, some 10 to 15 ns a chunk.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, curl 7.88.1), from a copy made with `COPYFILE_DISABLE=1`, less the submodule and pin checks, the top layer's tree: forty-three suites, 1,389 expected passes, exit 0; the shell, contract, clients and padding suites, three runs each: 129, 68, 14 and 15 each time.

Watched to fail (m6-mutations.md, "The padding PR"): forty-four mutants on the finished tree against all forty-three suites, and a forty-fifth, P-Q2, for G12's instance that cutting the layers added; none survives, and every check this PR added or changed is reddened by at least one.

Size: 933 inserted lines of code and tests (the new flows suite's 259 among them, `src/` 314), 183 deleted; over plan §1 rule 1's ~400. Cut as three layers (the form below), each proved green on its own before its commit, against main and then each on the one below: 163, 576 and 228 inserted lines of code and tests, and 117, 55 and 45 deleted, where the form estimated about 190, 450 and 290; forty-two suites and 1,338 expected passes, then forty-three and 1,368, then 1,389.

DECIDED on the owner's word (2026-09-30), by form, after the walkthrough: **three stacked PRs**, each green on its own, proved before its commit: every event callback carrying the parser's position, with decision 0002's amendment; the two runs planned, the whitespace before a value and a chunk size's digits, with the runs' machinery; the two found, the request line's spaces and the empty lines before it, with the PR's records. Weighed: two, the positions and the four rules; one. And **the split found, main's own limits cut off by the parser's error, gets its own PR next**, before the M6 exit: with the positions, the core can place a target or a field name the error cut off and judge it by its limit. Weighed: carried to M8.3; folded into this PR.

NEXT: the three stacked PRs, merged bottom up on the owner's "do closing ritual". Then the PR for the split found, its design by form on measurements; then the M6 exit (plan §14).


THE PADDING PR'S REVIEW (2026-09-30, PRs #83 to #85 open): a /code-review max on the owner's ask (ten finders, a verifier for each candidate, a sweep) found fifteen, and the owner asked for all of them fixed: "lets fix all, start with the ones that need choices". Each choice's options were built in scratch copies and measured before the forms (Darwin arm64, the fake shell, every delivery size).

DECIDED on the owner's word (2026-09-30), by two forms, every option the recommended one:
- **The spaces after a target are counted however it ends.** A request line with no version ended by a bare LF, which the strict parser takes, was refused 400 or served 200 depending on where reads ended. `GET /a\nHost: x\r\n\r\n` got 400 at 9 of its 18 delivery sizes; main served it 200 at all. The core counted from one byte past the target, taking that byte for a space, but a bare LF is one byte too.
  - Now the run opens at every on-url-complete, a field or the head's end lets it go, and a read may end one byte past its limit: a versionless line's CR.
  - On a generated corpus of 3,522 and 3,549 inputs, each at every size, the PR split 296 and 330 inputs (206 and 218 of them in what was written, all with a bare LF). Now 7 and 7 split, each by its reason only (the run-then-error class below).
  - The one change in behaviour: a client that stops after one extra space waits for the header timeout instead of getting 400 at once.
  - Weighed: checking that byte for a space (the same corpus numbers, but hand-built rows then need a delivery).
- **A chunk's extensions count every byte, an empty one's too**: a byte at each name's and value's end, for its `;` or `=`.
  - A megabyte of `;=` was served 200 in 92 ms of CPU, growing linearly (8 MB took 736 ms through the libuv shell), bounded only by the body deadline. Now it gets 413 within its second 16 KiB read, in about 2 ms.
  - Weighed: every byte by position (+38 −30 lines, and a single large delivery parsed whole first); Go's 4 KiB a line alone (still served a megabyte spread over short lines).
- **A 431 names the limit its bytes passed first** (`first-past`), the field's on a tie. Of 2,856 swept trailer inputs, 224 split by their 431's reason on main and 496 on the PR; none of 56,692 swept and fuzzed inputs splits now. Weighed: leaving it.
- **An empty value's line end does not count.** 8,191 spaces and a CRLF were refused 431, where 8,191 spaces and a one-byte value were served. A malformed value at most 2 bytes past its limit, which the parser ends at a byte it then refuses, now gets its 400 instead of 431, at every size. Weighed: counting it, and saying so in the docs.
- **A run past its limit, then a parse error, goes to the next PR**, with main's own cut-off span. It is 400 at every split, but its reason depends on the split: `GET` + 3 spaces + a control byte names the run at 5 of its 31 sizes and the parser at the rest. Both halves need to know where a span the error cut off began. Weighed: fixing it here.
- **A parser-result carries the parser's own count**, `parser-result-stream-offset`, not one read's (decision 0002's amendment). The trace lane, which passes on only some results, had left the core's sum behind on 80 of its 141 reads. Weighed: spans carrying the position too (73 hand-built events to change); keeping the sum.
- **chez-httparse #55 filed**: document what `parser-stream-offset` answers inside a callback (decision 0008). Weighed: recording the reliance only.

Fixed without a choice:
- Row F3's head is now 10 bytes, at the tight limits' edge, and the table's state builder refuses a setup step the core refuses (`setup!`).
- G14 watches the four phase guards no check watched.
- The entry suite's two "all fifteen" checks are fourteen now, with a count: on-headers-complete is refused whatever its arguments, so its instance could never fail.
- A parser-result is read whole, once, before it is answered: a short one is an assertion violation again, as on main.
- The stale comment on `conn-span-callbacks` is corrected.
- The docs say 4 bytes of empty lines, name the fixed limits, and count every byte of the extensions.
- Each run's limit is stated once (`run-limits`, `close-judged!`), and on-message-begin refuses through `refuse`.
- `(decisive)` holds the action reducer that the body, Expect and padding suites each copied; `fake-shell-feed-input!` takes a delivery's offset; and `expecting` goes through `head-complete!`.

Found while building:
- **The two "all fifteen" checks** had the flaw, not one.
- **No check named the tie**, both limits passed at one byte; the padding suite's row gained one.
- **The clamp at 0 on an empty value's pad could change no outcome**: R-W3 survived. The pad goes below 0 only where the parser's error comes next. The clamp went.

The checks: padding 19 (15), the table 305 (293), entry 35 (33). In the table, G9 and G10 sit at the new allowances, G12 names the section first, G13 lets a versionless line's run go at its first field, G14 holds a run open past a 408, F4 and F5 count each delimiter, and the count is fourteen. Expect 16 and originated 26: their inputs shrink by the delimiters.

Measured on the finished tree (2026-09-30):
- `make test` on Darwin arm64: forty-three suites, 1,407 expected passes, exit 0.
- On Linux, in the same Docker image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1): forty-three suites, 1,407 passes, exit 0. The shell, contract, clients and padding suites gave 129, 68, 14 and 19 in each of three runs.
- Allocation is unchanged: curl's GET 1,840 B, the JSON POST 2,624 and 2,432, ab -k's GET 2,112, a browser's GET 3,312, a parser 1,056.
- Red before green: on f0950e2, before any edit, the padding suite's six new and changed checks failed and thirteen passed.
- Mutants: sixty-five on the reviewed tree, none survives (m6-mutations.md, "The padding PR's review"). Every new and changed check is mapped by name to a mutant that reddened it.

Size: 471 inserted lines of code and tests (`src/` 182), 317 deleted; over plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-30), by form, after the walkthrough: **two stacked PRs on #85**, each proved green on its own before its commit. The finished tree was set aside (22 files, sums, a tarball), the bottom layer was cut in place from f0950e2, and the top layer was restored from the set-aside with every sum matching. Weighed: one PR; folding each fix into #83 to #85.
- Bottom, `refactor/padding-review` (b5c6b4f): the parts that change no rule. The parser's own count, a result read whole, each run's limit stated once, `refuse` in on-message-begin, the table's `setup!` and F3, G14, the entry suite's fourteen and short result, `(decisive)`, the delivery offset, `expecting`, the adapter's #55 and the stale comment, decision 0002's amendment and the design's event table. 251 inserted lines of code and tests (`src/` 100), 235 deleted; `make test` 43 suites, 1,395 expected passes; allocation unchanged.
- Top, `fix/padding-review`: the four rules (a versionless line, empty extensions, the first limit passed, an empty value's line end), with the docs and the review's records. 234 inserted (`src/` 92), 96 deleted; 1,407.

NEXT: the two PRs, merged with #83 to #85, bottom up, on the owner's "do closing ritual". Then the PR for the split found, now with the run-then-error reason (plan §14's note); then the M6 exit.

MERGED to main on 2026-10-01, on the owner's "Do closing ritual": **the padding PR and its review, as five stacked PRs**, bottom up. Each squash tree is the tested tip's, and each merge was pinned to its head's full SHA.
- **#83, every parser event carrying the parser's position,** 59a5997, squashed as 777d36e (tree 2e5c8ca), whose parent is d52ab78. It merged first and kept its branch.
- **#84, a value's leading whitespace and a chunk size's digits,** retargeted to main and rebased from #83's tip: c615744 became f434b5e (tree d8a6fab, the tested one's). It merged as eea26fc.
- **#85, the request line's spaces and the empty lines, with the PR's records,** rebased from #84's old tip: f0950e2 became 418ca97 (tree 32ebd89). It merged as 7e43fb6.
- **#86, the review's parts that change no rule,** rebased from f0950e2: b5c6b4f became 08e4312 (tree 3d0c193). It merged as f64f410.
- **#87, the review's four rules, docs and records,** rebased from b5c6b4f: 83c98a5 became 6ab6c3b (tree 1f146f3). It merged as 17df6cc, whose parent is f64f410.
- **CI changed during the ritual.**
  - #83 to #85 as opened were the billing block, the `linux` job with 0 steps (36710798364, 36710802665, 36710805821).
  - Between 2026-09-30T11:48Z and 2026-10-01T00:37Z the block lifted. The job now runs, but `actions/checkout` cannot clone the three private sibling submodules (chez-httparse, chez-libuv, uriparse: "Repository not found"), so no build or test runs.
  - That failure hit #86 and #87 as opened (36797088983, 36797092945), every rebased tip (36797461697, 36797781000, 36797841231, 36797892375), and main's own run on 777d36e (36797428373). No PR touched `.gitmodules` or the workflow.
  - DECIDED on the owner's word, by form, during the ritual: **continue on local evidence**, each rebased tree proved equal to the tested one and each red run shown to be this checkout failure; fix CI separately. Weighed: pausing after #83 until CI can check out, which needs a token or deploy key the owner adds as an Actions secret.
- **Branches.** #87's `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #20, #22, #68, #70, #72, #73 and #82. The switch to main, the fast-forward and the five local deletions were by hand, and the four lower remote branches went in one `git push origin --delete`. No PR is open.

`make test` green on main: forty-three suites, 1,407 expected passes.

DONE and merged (777d36e, eea26fc, 7e43fb6, f64f410, 17df6cc; PRs #83 to #87): **the padding PR, what the parser reads and hands no span of held to limits.**
- Before, a megabyte of each run was served 200. Now each is refused within the read that passes its limit:
  - empty lines before a request line, past two (4 bytes), 400;
  - spaces between the request line's parts, past one, 400;
  - whitespace before a value, counted with it, 431 for the limit its bytes pass first;
  - a chunk size's digits, past 16, 400;
  - a chunk's extensions, every byte counted, 413.
- Every event carries the parser's position, and every result the parser's own count.
- The review fixed a split it had added: a versionless request line ended by a bare LF. It also fixed the empty extensions it had missed, and asked chez-httparse (#55) to document the offset it relies on.

**CI reads the private submodules through a secret, on `fix/ci-private-submodules` (2026-10-01).** The job's own token reads only this repository, and chez-libuv, chez-httparse, uriparse and chez-httparse's byte-machine are private. Checkout now fetches this repository alone. `make submodules` clones every submodule with the Actions secret `SUBMODULES_READ_TOKEN`, through a URL rewrite held in that step's environment and limited to Kiyomi-Computation-Systems' URLs. A first step fails, naming the secret, until the owner adds it: a fine-grained token with Contents read-only on those four repositories. Proved offline on Darwin arm64 (git 2.50.1; the runner has 2.55.0). Against a stand-in for github.com, with the real Makefile, 19 checks pass. One shows that a nested clone never sees a token checkout saves, so a token given to checkout alone still fails at byte-machine. Eleven checks on ci.yml's own strings pass, each watched red under a mutant. `make test`: forty-three suites, 1,407 expected passes. The job's later steps have never run on GitHub; the first run with the secret is their first. DECIDED on the owner's word (2026-10-01), by form: checkout keeps the job's own token, and the change goes up as one PR. Weighed: the secret on checkout too, which would also have to read chez-http-server.

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#88, CI reads the private submodules through a secret.** 3dcde03 was squashed as 3d006b0 (tree f7454e9, the tested tip's), whose parent is 37afef1. The owner added `SUBMODULES_READ_TOKEN` at 09:58Z. The PR's re-run (36844511280, attempt 2) then passed all 17 steps, the job's first green run on GitHub:
- the five submodules cloned at their pins in 5 s;
- Chez 10.4.1 built from source in 195 s and was cached, under the PR's ref, so main's first run builds it once more;
- `make test` on ubuntu-24.04 (git 2.55.0, libuv 1.48.0) ran forty-three suites, 1,407 expected passes.

The branch was deleted by hand, local and remote, and the shared checkout's `main` was fast-forwarded behind the guard.

THE CHEZ-HTTPARSE v0.4.4 PIN (2026-10-01), on the owner's word: "chez-http-server can now move its vendor/chez-httparse pin to the v0.4.4". Branch `chore/chez-httparse-v0.4.4`, cut from main at 8993ff0; Darwin arm64, Chez 10.4.1.

UPSTREAM: chez-httparse tagged v0.4.4 (3342428, annotated tag 9b198d4). Checked against the sibling checkout's history:
- **#56 answers our #55** (closed 2026-10-01). `docs/api.org` gains "Where a callback is in the stream":
  - an event callback reads the bytes taken before it, llhttp's `off=`;
  - a span callback reads its fragment's end, so the fragment starts at the offset less `(- to from)`, including a fragment cut off at a feed's end and an empty one.
  - That is what the core reads, and `unit.stream-offset` holds both over the 274 fixtures at chunk sizes 1, 2, 3, 7 and whole.
- **#57:** `parser-finish!` on a close-delimited body with no bytes runs no empty `on-body-data`, as llhttp. The generated parser gains one state, so it is not byte-identical to v0.4.3. The core never finishes a parser. The tests' response reader reads only the finish's status and whether its message completed, and an empty body's text is "" either way.
- Conformance is 274 of 274 and the generated-runtime ABI is 9. Its byte-machine is still v0.6.1 at 5c1cb7e, so uriparse, the other carrier, stays. The vendored llhttp corpus is unchanged from v0.4.3. Its CI clones its private byte-machine with a read token (#58).

Decision 0008's ask is closed by its landing: the pin moves on its own commit, and the adapter's comment, which cited the ask, now cites the documented section.

Measured at v0.4.4:
- `make test` (2026-10-01, Darwin arm64): forty-three suites, 1,407 expected passes, exit 0, as main. Every pin is ok: chez-httparse 3342428, its byte-machine 5c1cb7e, and uriparse released with the same.
- The corpus lanes under `CORPUS=full`: trace 7, outcome 6 and libhtp 19 expected passes, ratchet 9.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy made with `COPYFILE_DISABLE=1`, less the submodule and pin checks: forty-three suites, 1,407 expected passes. The shell, contract, clients and integration suites gave 129, 68, 14 and 5 in each of three runs.

Records: the global constraints' pin line; decision 0002's amendment (the offset documented); the adapter's comment; test-integration's and test-corpus-inventory's version comments.

The pin moves alone: the gitlink, the Makefile's pin and the comments, besides these records.

DECIDED on the owner's word (2026-10-01), by form: one PR, the pin alone. Weighed: a review first; nothing committed.

MERGED to main on 2026-10-01, on the owner's "ci is green do closing ritual": **#89, the chez-httparse v0.4.4 pin.** 6ea6558 was squashed as e909e5b (tree 027bc4a, the tested tip's), whose parent is 8993ff0.
- **CI.** Its run, 36857836010, passed: the `linux` job built and tested the PR on GitHub, the first pull request so checked since #88 gave CI its read token.
- **Branches.** `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #73 and #87. The switch to main, the fast-forward and the local deletion were by hand.

`make test` green on main at v0.4.4: forty-three suites, 1,407 expected passes, every pin ok.

NEXT, by the owner's word (2026-09-30):
- **The PR for the split found**, main's own limits cut off by the parser's error, now with the run-then-error reason. Its design goes by form on measurements.
- **Then the M6 exit** (plan §14).

THE CUT-OFF-SPAN PR (fix/cut-off-spans, cut from main at f89ad73), on the owner's word: "Lets do the next step: the PR for the remaining split, where a parse error cuts off a span past its limit, including the run-then-error reason."

Measured on main first (2026-10-01, Darwin arm64, Chez 10.4.1, the fake shell, the default limits; every delivery size under 400 bytes, and above it sizes 1 to 80, every 97th and whole). Eleven of eighteen inputs split:
- a 9,000-byte target, then a control byte: 414 at 111 of 174 sizes, 400 at 63; one of 8,193 bytes: 414 at 2 of 165;
- a 9,000-byte field name, then a control byte: 431 at 111 of 174 as the first field, at 113 as the second, and at 111 as a trailer's, 400 at the rest; one of 8,193 bytes: 431 at 4 of 165;
- a 1,000-byte name cut off past 16,000 bytes of fields: 431 (`headers-too-large`) at 107 of 256, 400 at 149;
- a run past its limit and then the parser's error, 400 either way, its reason split: `GET`, three spaces and a control byte, the run's at 5 of 29 sizes; with `/abc` before the control byte, 10 of 33; two spaces and a 9,000-byte target, 172 of 174; eighteen zeros and a `g` as a chunk size, 4 of 85.
- Not split: a value or a chunk's extensions past their limits and then a control byte (431, 413), each handed over before the error; seventeen zeros and a `g`, within the read's slack; spaces after a target; whitespace then CR and a control byte; empty lines.

A fuzz (scratch `cut/fuzz.sps`): random request lines, fields, chunk sizes and trailers under random tight limits, one byte replaced or inserted, each run at every delivery size, each read at index 3 of a bytevector of its own. Of 40,000 inputs (two seeds, a head's fields and a body's trailers), 980 split: 326 by status (414 or 431 against 400: 174, 144 and 8 for a section), 654 by reason only (489 the request line's spaces, 165 a chunk size's digits).

What an error cuts off. Seven requests, each byte replaced by and preceded by each of 22 byte values, fed whole: of 11,790 errors, a field name's span was open at 2,868, the method's at 1,665 (it has no limit), the target's at 1,156, none at 6,101. A value, an extension and the protocol are handed over before their errors. The parser says which span is open, `parser-active-span`, and an error leaves it named; it does not say where that span began (byte-machine's runtime keeps the mark private, and "a final partial fragment is forbidden outright" at an error). And an error's offset is not always the refused byte's: over 11,273 errors it is that byte's when the error's position kind is `byte` (9,132), and one past it when `boundary` (2,141), where the parser took the byte and then refused it (byte-machine's `.reference/transition-and-cursor-semantics.md` §4).

Prototyped in a scratch tree: the shell passes the parser's open span and the refused byte's offset; at the parser's error the core judges the bytes the error cut off as a read's end would, so the first limit passed in byte order names the response; a field name starts where its line starts, which the event before it gives, and a target one byte after the method's space unless that byte is another space, read from the delivery the core holds. None of the eighteen and none of the 40,000 split. On 20,000 more (a third seed), each answer is main's at one-byte reads, where nothing is cut off. The corpus lanes under `CORPUS=full` print what main's print (trace 7, outcome 6, the libhtp lane 19, the ratchet 9, libhtp 11). Allocation is unchanged: curl's GET 1,840 B. A first cut took an error's offset as the refused byte's: it split none, but answered 37 of the 20,000 otherwise than main does a byte at a time, a tab the parser takes and then refuses counted as a target's byte or a space.

DECIDED on the owner's word (2026-10-01), by two forms:
- **A parser-result has five fields, `(parser-result status offset next code span)`**: one code, an error's or a pause's, since a result has at most one, and the span the parser has open; its offset, at an error, is the refused byte's. Built once, in the adapter, for both shells. Weighed: a sixth field, 16 B more a read (curl's GET 1,856 B).
- **Ask and carry.** The owner asked first whether the change would make byte-machine a better product. Answered: yes, if a parse error records the span it abandoned and where its undelivered bytes begin, rather than the mark being exposed, which the runtime keeps private on purpose; free at runtime, no callback changed, so chez-httparse's llhttp conformance holds; any embedder that bounds a span or names a bad token needs it; byte-machine already documents the position kinds. So **byte-machine #145** was filed (2026-10-01), and the core places a cut-off span now, a workaround named in its source (decision 0008), whose line starts and space check, about twelve lines, go when it lands. Weighed: building only once #145 lands; the core alone, with no ask.

What was built:
- `(http-server private adapter)`: `parser-result-event`, the one place a feed's result becomes the core's event, for both shells: `(parser-result status offset next code span)`. The offset is the parser's count, and at an error of the parser's own the refused byte's position: the count less one where the error's position kind is `boundary`. The code is the error's or the pause's, and the span is `parser-active-span`. The libuv shell and the fake shell call it; each dropped its own builder.
- `(http-server connection)`: at the parser's own error, with no refusal of the core's held, `cut-off-past-limit` judges what was cut off:
  - a target's bytes it was not handed: from the read's start where a read's end handed the first ones; otherwise one byte past the method's space, unless that byte is another space, read from the delivery (`space-at?`), and then the spaces' 400 comes first;
  - a field name's: from the later of its line's start (`conn-line`) and the read's start, judged by `first-past` against the name's limit and the section's. `conn-line` is set at on-url-complete for a versionless line, at on-version-complete two bytes on, at each value's end, and at each chunk's size line;
  - otherwise the run still open, judged as at a read's end, every kind (`run-past-limit` lost its `error?`).
  `target-past` states the target's limit once, on-url-data's check too. The line starts and the space check are decision 0008's workaround for byte-machine #145.
- Docs: responses.org, one paragraph: the rule a request's bytes break first decides its answer, however they arrived.
- Records: decisions 0002, 0005 and 0008; design §4.2's table and note, and §4.4's error row; plan §14's note; this ledger; m6-mutations.md.

The checks:
- `tests/test-connection-cut-off.sps`, new, 11: a target, at its limit and a byte past it, then a control byte; two spaces then such a target, or three then the byte; the tabs the parser takes before refusing them; a field name at its limit and a byte past, in each place a name begins (the first field, after a field, after a versionless request line, a trailer section's first, after a trailer); the section passed by a name within its own limit; eighteen digits and seventeen; each at every delivery size. Then the result as the adapter builds it from a real parser, a pause's code among them, and decision 0008's tripwire: byte-machine's error and active-span accessors are v0.6.1's until #145 lands.
- `tests/test-connection-table.sps`, 319 (305): G12 to the new rule, with an instance within the limit; K1 to K4, twelve instances, and their count; T7's pause code in its new place.
- `tests/test-connection-entry.sps`, 35: its short-result check renamed for the new fields.
- `tests/test-serve.sps`, 11 (10): through the libuv shell, a target over the limit and then a control byte, sent in one write: 414.

FOUND WHILE BUILDING:
- **The suite's first trailer inputs never reached their trailers.** The limits it set refused the chunked head's own 17-byte `Transfer-Encoding` name first, at every size: the same trap as the fuzz's first trailer mode. Its name limit is now 17, so the head passes, and the names cut off are 17 and 18 bytes.
- **No check held what the libuv shell hands the core.** The fake shell's suites pass whatever the real shell builds. test-serve's new check is red against main's sources and under X-S1, a shell that builds its own result with no span. The contract suite reddens under X-S1 too: its two shells' traces differ at the first read that ends inside a span.

Measured on the finished tree (2026-10-01):
- `make test` on Darwin arm64: forty-four suites, 1,433 expected passes, exit 0, every pin ok.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1): forty-four suites, 1,433 passes, exit 0. The shell, contract, clients, serve and cut-off suites gave 129, 68, 14, 11 and 11 in each of three runs.
- The corpus lanes under `CORPUS=full` print what main's print: trace 7, outcome 6, the libhtp lane 19, the ratchet 9, libhtp 11.
- None of the eighteen inputs splits. Of the fuzz's 40,000, none splits; of 20,000 more, on which main splits 495, every answer is main's at one-byte reads.
- Allocation is unchanged: curl's GET 1,840 B, the JSON POST 2,624 and 2,432, ab -k's GET 2,112, a browser's GET 3,312, a parser 1,056.
- Time, 20,000 keep-alive requests on the fake shell, eight runs each, interleaved with main's: curl's GET 4.95 to 5.10 µs against 4.80 to 4.95, a chunked POST 6.65 to 7.20 against 6.55 to 7.10, a browser's GET 9.30 to 9.70 against 9.15 to 10.20.
- Red before green, and the mutants: m6-mutations.md, "The cut-off-span PR". Twenty-eight, none surviving; the padding PR's sixty-two run again, all killed, and three withdrawn.

Size: 529 inserted lines of code and tests (`src/` 155, much of it comments), 73 deleted; over plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-10-01), by form, after the walkthrough: **two stacked PRs**, each proved green on its own before its commit.
- Bottom, `refactor/parser-result-span` (dd21879): the five-field result, built once in the adapter, its span not yet read and its offset still the parser's count. It changes no rule. 107 inserted lines of code and tests, 31 deleted; `make test` 44 suites, 1,409 expected passes.
- Top, `fix/cut-off-spans`: the rule, with its checks, docs and records: the refused byte's offset, the core's judgment of what the error cut off, and the runs judged at the error. 452 inserted (`src/` 134), 72 deleted, the bottom's suite header and builder rewritten among them; 44 suites, 1,433. The finished tree was set aside (16 files, sums and a tarball), the bottom cut in place from main by scripted edits, and the top restored from the set-aside with every sum matching.
Weighed: three stacked PRs (the result; targets and runs; names and the records), each under the ~400 guide but one mechanism split across two; one PR.

NEXT: the two PRs, merged bottom up on the owner's "do closing ritual". Then the M6 exit (plan §14). When byte-machine #145 lands and its release reaches chez-httparse and uriparse, their pins move together, the tripwire goes red, and the core's line starts and space check go.

MERGED to main on 2026-10-01, on the owner's word by form ("Merge #90/#91, then PR"): **the cut-off-span PR, as two stacked PRs**, bottom up. Each squash tree is the tested tip's, and each merge was pinned to its head's full SHA.
- **#90, the five-field result,** dd21879, squashed as baec0e6 (tree 6e4cefa), whose parent is f89ad73. CI's `linux` job passed on dd21879 (36866733334). It merged first and kept its branch.
- **#91, the rule,** retargeted to main and rebased from dd21879: 7a6fd94 became bf11f16 (tree e75ce71, the tested one's), pushed with the lease from `ls-remote`. CI passed on both heads (36866785944, 36925445076). It merged as cab39b1, whose parent is baec0e6. `--delete-branch` switched this checkout to main and fast-forwarded it; the bottom branch was deleted by hand.

`make test` green on main: forty-four suites, 1,433 expected passes, every pin ok.

NEXT, by the owner's word (2026-10-01, the same form): **the pin PR**, one PR from main. byte-machine v0.7.0 (c338a57) shipped #145 the same day: a parse error names the span it abandoned (`parser-error-span`) and where its withheld bytes begin (`parser-error-span-offset`). chez-httparse v0.4.5 (0b7058e) and uriparse v0.6.2 (5ecd88f) carry it, their `src/` unchanged. Both pins move, and the core reads the two values in place of its line starts and space check; the result's `span` becomes the error's `(name . where its withheld bytes begin)`, or #f (DECIDED, the same form). Then the M6 exit (plan §14).

THE PIN PR (refactor/abandoned-span, cut from main at 4086735), on the owner's word: "uriparse and chez-httparse are both updated to byte-machine 0.7.0". Its shape was decided by form (below).

Checked against the siblings' own history first (2026-10-01):
- byte-machine v0.7.0 (c338a57, annotated tag 8b493d4) carries #145, via PR #146 and its decision 0056, released in PR #150; #145 is closed. A parse error gains two members, `parser-error-span` and `parser-error-span-offset`, both #f when no span was open. `abandon-span!` fills them where both executors hand an error back, and a delivery now advances the span's mark (§13:822). The generated ABI is still 9, and the emitted text is unchanged.
- chez-httparse v0.4.5 (0b7058e, tag 814f2df; PRs #60 and #61) and uriparse v0.6.2 (5ecd88f, tag 3cfec81; PR #31) each vendor c338a57. Neither library's `src/` changed since v0.4.4 and v0.6.1, nor chez-httparse's corpus since v0.4.0. All three tags are on GitHub.

Measured before the form (2026-10-01, Darwin arm64, Chez 10.4.1). A copy of v0.7.0's `src/` went on the library path, leaving the checkout alone (scratch `bm7/`):
- #91's tree at the new pins: 44 suites, 1,432 of 1,433 checks pass. The one red is the #145 tripwire. Allocation is unchanged: curl's GET 1,840 B; a JSON POST 2,624 read whole and 2,432 streamed; ab's GET 2,112; a browser's 3,312; the parser 1,056.
- A probe in the core compared the error's offset with the core's own placement, at every error of the 40,000 fuzzed requests at every delivery size. They agreed at all 615,192 targets and names cut off: 103,787 targets that began in the read that failed, 7,551 carried in from an earlier read, and 503,854 names. The error's span always equalled `parser-active-span`, and its offset the result's. No other span ever withheld a byte, and no withheld range began past the refused byte.
- A prototype, with the span field carrying the error's pair (`src/` +15 −31): none of the 40,000 split. On 20,000 more, it answered byte for byte as #91's tree. The eighteen hand-made inputs and the five corpus lanes print what #91's print: trace 7, outcome 6, libhtp lane 19, ratchet 9, libhtp 11.
- A sixth field instead costs 16 B a read: curl's GET 1,856 B, a browser's 3,328. The allocation suite builds its results by hand, so its builders were widened to price it.
- Time, as medians of twelve rounds whose order rotates:

  | Tree | curl's GET | a browser's GET | a chunked POST |
  |---|---|---|---|
  | #91 at v0.6.1 | 5.05 µs | 9.575 | 6.975 |
  | #91 at v0.7.0 | 5.15 | 9.625 | 6.975 |
  | the prototype at v0.7.0 | 5.175 | 9.65 | 7.05 |

DECIDED on the owner's word (2026-10-01), by one form:
- **The span field carries the error's pair.** `span` is `(name . where its withheld bytes begin)` at an error with a span open, and #f on every other result, where the core never read it. Weighed: a sixth field, 16 B more a read.
- **Merge #90 and #91 first, then this as one PR from main.** The closing ritual ran on that answer (above). Weighed: stacking it on #91; folding it into #91, so the workaround never reached main.

What was built:
- The pins: chez-httparse v0.4.5 and uriparse v0.6.2, gitlinks and `make check-pins`'s three commits, so byte-machine v0.7.0 arrives through both. Each tag was fetched from the sibling's own checkout, and both nested byte-machine checkouts follow.
- `(http-server private adapter)`: `parser-result-event : ParserResult -> Event`, built from the result alone. At an error with a span open, `span` is `(cons (parser-error-span e) (parser-error-span-offset e))`, and otherwise #f.
- `(http-server connection)`: `cut-off-past-limit` counts a target's or a name's withheld bytes from the error's offset to the refused byte, after the ones a read's end handed on. For a target that began in the read that failed, `close-judged!` judges the spaces before it first, as its first fragment's would have been. `conn-line` goes, with its five setters, the `on-version-complete` clause, and `space-at?`.
- Both shells call `(parser-result-event r)`.

Checks:
- `tests/test-connection-cut-off.sps`, 11:
  - The shape check holds the new results: need-input without a span; three errors with `(url-span . 4)` or `(url-span . 6)`; and one with none open, in the whitespace before a value.
  - New: a target the core refuses at its head's end, on a request line with no version and no fields, is answered 400 for the target at every delivery size, not for the run the line leaves open (below).
  - The tripwire is gone.
- The table's K1–K4 hand the core the error's pair: from the target's start, from the read's start for a carried one, from past the spaces, or from a name's line start.

Red before green, at the new pins:
- On the old code, the cut-off suite failed its two shape checks.
- The table failed six of K1–K4's twelve instances, in K1, K2 and K4. K3's answer, for the spaces, comes out the same either way.

Mutants (`.superpowers/sdd/m6-mutations.md`, "The pin PR"): eighty-nine on the finished tree, none surviving:
- seventeen new, Y-A1 to Y-S2, each against all forty-four suites;
- ten of the cut-off-span PR's;
- the padding PR's sixty-two.

Withdrawn, their code gone: X-B1, the tripwire's; X-L1 to X-L7, the line starts'; X-T1 and X-T5, the target's placement and its space check. Seven more were cut again as new ones. Every new and changed check is mapped by name to a mutant that reddens it.

FOUND WHILE BUILDING:
- **The guard for the core's own refusal had lost its checks.** On the first run, X-C3, which lets the cut-off judgment run under a refusal the core already holds, survived. Under #91 its checks were two refusals of spaces after the method, met as the target's first bytes arrived; #91's placement counted that read from its start as target. v0.7.0 records nothing withheld at a data callback that fails, so those checks pass with the guard gone. The guard still matters where a run is left open. A request line with no version and no fields keeps the run after its target open to its head's end, and on X-C3's mutant `GET /%zz` with no version and no fields was answered for the spaces (400 `request-line-spaces`), where the tree answers `invalid-target`. The new check holds it, and X-C3 reddens it.
- **X-C4's first run did not load:** its cut named `span`. The runner's tally now counts a suite that reports neither passes nor failures as a load failure, not a kill.
- **The allocation suite builds its results by hand,** so a field added in `parser-result-event` prices the same there. Its builders were widened to price the sixth field.
- **Decision 0008 has no row for chez-httparse #55,** filed on 2026-09-30 in the padding PR's review and landed in v0.4.4, though the ledger cites 0008 for it. It is not fixed here, so 0008's new line says every ask its table lists has landed, without a count.

`make test`: forty-four suites, 1,433 expected passes, every pin ok.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and apache2-utils' ab installed: forty-four suites, 1,433 expected passes. The shell, contract, clients, serve, cut-off and table suites each passed in all three repeat runs.

Size: `src/` +58 −84 and `tests/` +64 −74, comments included; the Makefile's three pins; the two gitlinks; the records, `.plans/` +36 −2 and `.superpowers/` +144 −1, this entry among them. One PR, by the form.

NEXT: this PR, merged on the owner's "do closing ritual" once CI is green on its head. Then the M6 exit (plan §14).

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#92, the pin PR.** fe543ee was squashed as 29ae566 (tree 2594120, the tested tip's), whose parent is 4086735.
- **CI.** Its run, 36928864872, passed on fe543ee.
- **Branches.** `--delete-branch` switched this checkout to main, fast-forwarded it, and deleted the branch, local and remote.

`make test` green on main at chez-httparse v0.4.5 and uriparse v0.6.2, with byte-machine v0.7.0 through both: forty-four suites, 1,433 expected passes, every pin ok.

NEXT: the M6 exit (plan §14). Also under way, in a session of its own started on the owner's word: chez-httparse #55's missing row in decision 0008 (FOUND above).

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#93, decision 0008's records for chez-httparse #55** (the FOUND above). 2a59fe5 was squashed as 44d30ee (tree 7c5e676, the tested tip's), whose parent is 2f685ae.
- **What.** 0008 gains #55 in the Decision paragraph's list, a row after chez-httparse #50 (LANDED 2026-10-01 in v0.4.4), and a Consequences bullet for the landing, placed by date before byte-machine #145's filing. The bullet's count, all twenty-two filed asks landed, is the table's 23 rows less #145, which was filed after #55 landed.
- **Rebased.** #92 merged while #93 was open and wrote byte-machine #145 into the same Decision sentence. So #93 was rebased onto 2f685ae, and the sentence keeps both, #55 before #145. The resolution was built two ways, which agreed byte for byte.
- **CI.** Its run, 36934579840, passed on 2a59fe5.
- **Branches.** Merged from its own worktree without `--delete-branch`, while the shared checkout held main. The branch was deleted by hand, local and remote, and the shared checkout's main was fast-forwarded behind the guard.

`make test` green on main: forty-four suites, 1,433 expected passes, every pin ok.

NEXT: the M6 exit (plan §14).

M6 EXIT (plan §14), on the owner's word: "lets close out M6". Branch feat/m6-exit, cut from main at 6b43a5a; 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m6-mutations.md, "The M6 exit".

Gathered before the first test, from the brief's M6 and plan §14:
- the brief's exit: 16 MiB each way against a slow peer with bounded memory; libhtp's Expect and early-response files pass;
- plan §14: the memory read as the M4 exit read a connection, the server's heap, the client in a process of its own; `docs/handlers.org` gains bodies.

Met before this branch, each with its check:
- libhtp's Expect files, `05-expect.t` and `99-expect-100.t`, pass since M6.4, delivered with CRLF: the ratchet's fourteen libhtp streams;
- `docs/handlers.org` covers bodies: "Reading the body" since M6.1, "Streaming a response" since M6.3, the 100 since M6.4;
- the brief's M6 scope: credit-based delivery (`body-credit`, M6.2), streaming responses with `notify-producer` (M6.3), and `100 Continue` written when the handler pulls the body (M6.4). Its "four read-stop conditions and the single read-start predicate" came from the research's parse-ahead prototype (`research/async-sans-io-state-machine.md` §5). Decision 0004 made pipelining serial, so design §4.4's rows stop reading at a message's end, at a credit wait (M6.2) and at a response given instead of a reader, and start it again when a response is written or a credit covers what was handed.

Missing:
- 16 MiB each way, read or checked. The bounds were checked at 1 MiB, streamed to a client that reads nothing, and at 64 KiB, an upload on credit, each with the client on the server's own loop;
- `35-early-response.t` passed with a handler that reads the body, as the M2 exit expected, and is the suites' only HTTP/1.0 body read. Its recorded origin answered 400 before the body, which a handler can since M6.1, and nothing ran it so;
- the README's status still listed request bodies as still to come.

MEASURED, before the form: `research/spike/m6-exit-sixteen.sps` and `m6-exit-peer.py`, two runs on each platform. A server is started as `serve` starts one. A Python peer, in a process of its own, holds one keep-alive connection to it, sends it 16 MiB as a POST's body, which `read-body` checks and keeps none of, then reads 16 MiB streamed back in 16 KiB pieces, 16,384 B at a time with 2 ms between. The server's heap is read every 50 ms after two full collections, and the peer reads its resident memory from outside.

| Each way, two runs | Darwin arm64 | Linux aarch64, in Docker |
|---|---|---|
| the upload: time; heap at most | 2.644 and 2.635 s; +61,392 and +34,328 B | 3.110 and 3.106 s; +95,104 and +74,808 B |
| the upload: resident memory | +16 and +32 KiB | +68 and +80 KiB |
| the download: time; heap at most | 2.605 and 2.616 s; +24,152 and +688 B | 3.181 and 3.122 s; +688 and +688 B |
| the download: written and not completed, at most | 262,272 B, in 16 write requests at most | 262,272 B, in 14 and 16 |
| the download: resident memory at most, then after | +1,808 then +384 KiB; +2,464 then +384 | +3,400 then −1,960 KiB; +2,376 then +128 |
| held whole: the body read by `read-whole-body`, its cap raised to 32 MiB | heap +16,847,304 and +16,863,648 B; resident +33,200 KiB | heap +16,854,384 and +16,830,496 B; resident +26,924 and +23,712 KiB |
| held whole: the answer as one bytevector | a write block of 16,777,298 B; resident +16,432 and +9,952 KiB | 16,777,298 B; resident +32,948 and +33,188 KiB |

Every byte arrived in order each way, and every piece handed the reader was 16,384 B or less. The producer was called 1,025 times, a piece each and its end. 262,272 B is the high water and one piece's write, 16,392 B: its size line, `4000` CRLF, the piece and CRLF. Linux is Debian 12 in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6), Chez 10.4.1 `tarm64le`, libuv 1.44.2, Python 3.11.2; Darwin's Python is 3.14.5.

A prototype of the check, curl at 16 MiB/s in the clients suite: 19 checks pass, and the suite took 2.85 to 2.87 s, where main's takes 0.84 to 0.88 (Darwin). Four of the mutants below each reddened their check. On Linux it took 2.63 to 2.81 s.

DECIDED on the owner's word (2026-10-02), by one form:
- **`35-early-response.t` runs both ways.** Its expectation stays, its handler reading the body. A second run answers 400 at the head, as its recorded origin did. Weighed: the early answer only, which drops the suites' one HTTP/1.0 body read; leaving it as the M2 exit wrote it.
- **The 16 MiB transfers are checks in `make test`**, curl at 16 MiB/s in the clients suite, about 2 s more. Weighed: the spike's readings alone.

BUILT:
- `tests/test-clients.sps`, 19 checks (main's 14). Against the suite's server, curl, a process of its own, sends 16 MiB chunked from its standard input, which the suite writes a 16 KiB piece at a time, to `/sixteen`, whose reader checks every byte and keeps none. It then reads 16 MiB from `/sixteen`'s producer, 1,024 pieces of 16 KiB, which the suite checks as curl hands them over and keeps none of. Each runs at 16 MiB/s (`--limit-rate`). Five checks:
  - the upload arrives in order, no read handing the reader more than the read buffer;
  - the server's heap, read every 50 ms after two full collections, five readings or more, grew by less than 1 MiB as it came in;
  - the download arrives in order;
  - the bytes written and not yet completed backed up past the low water, and never passed the high water by more than a piece's write;
  - the server's heap grew by less than 1 MiB as it went out, read the same way.
  The suite's `spawn` and `run` take a pipe for the child's standard input, a procedure that takes its output, a watch and a cap. Its other checks call them as before.
- `tests/libhtp-lane.sls` and `tests/test-libhtp-lane.sps`, 20 checks (19). `35-early-response.t` is run again, its handler answering 400 at once. After the head's packet alone, the connection has asked the handler, written the 400 and lingers, close-after `not-keep-alive`. After the whole stream and its eof, it is closed, and no reader was handed the body. The lane's own run goes through `run-stream`.
- The README's status: since M6, a handler reads a body as it arrives and can stream its response. `docs/handlers.org`: `read-body` never holds a body whole, a 16 MiB upload adding under 100 KB to the server's memory.
- `.plans/research/spike/m6-exit-sixteen.sps` and `m6-exit-peer.py`, new, with four runs in `out/`.
- Records: plan §14's M6 exit note; design §7.5's and §8.2's notes; the research README; m6-mutations.md.

Measured on the finished tree, the clients suite printing what its checks read:
- Darwin, three runs: the upload's heap +80,520 to +82,800 B and the download's +56,248 to +62,592, in 21 readings each, the bytes outstanding 262,272 at most, the largest piece 16,384. The suite took 2.80 to 2.82 s, main's 0.75;
- Linux, eight runs: the upload's heap +31,968 to +53,448 B in 21 readings, the download's +38,648 to +52,424 in 14 to 21, the bytes outstanding 229,488 to 262,272 as read after each turn. The suite took 2.37 to 2.49 s, main's 0.69 to 0.80;
- curl unlimited: two or three readings each way on both, where curl at the limit took 14 to 21. So the readings check is five, not the ten the prototype had: the download took 14 on Linux.

Watched to fail (m6-mutations.md, "The M6 exit"): nine mutants of the code, M6X-A to M6X-I, each against all forty-four suites, and three calibrations of the checks. None survives, and none failed to load. By check:
- the upload's arrival by M6X-F, the read buffer at chez-libuv's default;
- the upload's heap by M6X-B and M6X-C, the body kept by the core or by the shell, and its readings half by C-fast, curl unlimited;
- the download's arrival by M6X-I, a piece's size line a byte short;
- the bytes outstanding by M6X-A, high water ignored, and M6X-E, a write reported completed as it is sent;
- the download's heap by M6X-D, the shell keeping its writes, and C-fast;
- the lane's early run by M6X-G, the handler not asked at the head, and C-read, its handler reading.
M6X-B and M6X-C redden the clients suite alone: before the exit, no check read the heap while a body came in. M6X-H, a write sent before those held, reddens the shell suite alone, since a 16 KiB piece is never held.

`make test`: forty-four suites, 1,439 expected passes (1,433 + 6), every pin ok, 27.8 s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed: forty-four suites, 1,439 expected passes, 30.1 s. The clients suite passed its 19 and the libhtp lane its 20 in each of three runs more.

Size: `tests/` +259 −55, comments included; the spike's two files, 380 lines, and their four runs; the README and `docs/handlers.org` +6 −2; the records, `.plans/` +47 −1 and `.superpowers/` +59 before this entry.

DECIDED on the owner's word (2026-10-02), by a second form, after the walkthrough: **one PR now.** Weighed: leaving it uncommitted for the owner to read first.

NEXT: this PR, merged on the owner's "do closing ritual" once CI is green on its head. M6 is then complete. Then M7 (plan §14), when the owner asks.

MERGED to main on 2026-10-02, on the owner's "do closing ritual": **#94, the M6 exit.** 0fccd2a was squashed as d9949f6 (tree 32758a9, the tested tip's), whose parent is 6b43a5a.
- **CI.** Its run, 36997657028, passed on 0fccd2a: 1,439 expected passes in its log.
- **Branches.** `--delete-branch` deleted the remote branch but left this checkout on it, so the switch to main, the fast-forward and the local deletion were done by hand.

`make test` green on main: forty-four suites, 1,439 expected passes, every pin ok.

DONE and merged (d9949f6, PR #94): **M6 COMPLETE.**
- The brief's M6 exit is met. 16 MiB move each way against a slow peer, curl at 16 MiB/s in a process of its own, and the server's heap grows 32 to 83 KB. The bytes written and not completed stay within the high water and one piece's write. libhtp's Expect files pass, and its early-response file passes both ways: read, and answered at the head. `docs/handlers.org` covers bodies.
- M6's slices, each merged: M6.1, how a handler reads a body (decision 0013; #69, #70); M6.2, the read side's credit (#71, #72); M6.3, a streamed response (#74 to #78); write batching (#79); M6.4, Expect, trailers and the exit's files (#80 to #82); the padding PR and its review (#83 to #87); the cut-off-span PR (#90, #91); the pin PR (#92); and this exit.
- Upstream, every ask decision 0008 lists has landed; nothing is open.

NEXT: M7 (plan §14), the scheduler and awaiting handlers, on a fresh branch cut from main after this commit, when the owner asks.


M7.1: THE SCHEDULER, AND HOW A HANDLER COMES TO WAIT, on the owner's "lets start M7". Three stacked steps, cut from main at 4a7748b: feat/m7.1-scheduler, then feat/m7.1-after-the-turn and feat/m7.1-awaiting, each on the one before; 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

FOUND before the first test: plan §14's M7.1 builds "a coroutine per awaiting handler", and decision 0003 item 2 has a handler that calls `await` run as a coroutine from the scheduler's drain, but nothing said how the server comes to know a handler waits. v1 calls every handler in place, inside libuv's read, where a continuation captured can never be resumed (design §5.1). How a handler comes to wait is public API, so it was measured and settled by form first.

MEASURED FIRST: `research/spike/m7-handler-coroutines.sps`, `m7-handler-turns.sps` with `m7-handler-turns.sh`, and `m7-handler-streams.sh`, with `m7/scheduler.sls` (the spike's two-level scheduler) and `m7-coroutine-shell.patch` (a prototype coroutine shell made from the libuv shell at 4a7748b). Two runs of the first on each platform and one of each script; Linux is Debian 12 in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6), Chez 10.4.1 `tarm64le`, with apache2-utils, curl and patch installed. Decision 0014's Context has the tables. In short:
- the gate's GET through the real parser, adapter and core: 1,840 B with the handler called in place; 2,029 to 2,035 B on a coroutine that does not wait; 2,269 B on one that waits once. The time a request: 2,204 to 2,346 ns in place on Darwin, 2,274 to 2,486 on a coroutine;
- through a small shell of the spike's own, what each way adds a request: the handler's call made from the drain, in place, 64 B for each of four workloads; every call into handler code on a coroutine of its own, 195 B for the GET, 554 and 522 B for a JSON POST read by `read-body` and by `read-whole-body`, 1,669 B for a GET of 8 produced pieces. The allocation suite's JSON POST read whole is 2,624 B today: 2,688 B the first way, 3,146 B the second, over the 3,072 B gate. `call/1cc` alone is 64 B;
- a handler parked 4 or 16 calls deep holds 3,515 B, 64 deep 3,879 B, after a full collection;
- `ab -k`, 50,000 GETs, 32 connections: on Linux 64,574 to 64,998 requests a second today, 87,435 to 90,918 with the handler called after the turn in place, 87,699 to 91,586 on a coroutine, 87,141 to 89,769 with every call on one; on Darwin 33,331 to 33,516 today and 33,750 to 34,519 the other ways. At one connection, within 4 per cent each way. The gain is the deferral's, not the coroutine's; its cause is not established;
- 16 MiB with curl over loopback: on Linux the handler called after the turn streams as today's shell (downloads 8.4 to 9.3 ms, uploads 7.8 to 8.8), and every call on a coroutine costs about 2 µs a 16 KiB piece (10.4 to 11.6 ms, 9.7 to 11.0); on Darwin 24.0 to 24.8 ms and 25.3 to 26.0, uploads alike. A drain that stops at the coroutines ready as it began, as the two-level proposal's sketch has it, made each produced piece wait a turn: 43.3 to 44.0 ms on Darwin.

DECIDED on the owner's word (2026-10-02), by form, after a second form on the owner's "i need more information on the tradeoffs", which set out the two that defer side by side, and a third with the options renamed, when "on request" in the text matched no label: **B, a wrapper, after the turn.** Decision 0014: every handler is called after libuv's turn, from the scheduler's drain, in place; a handler that waits answers `(awaiting thunk)`, whose thunk runs on a coroutine, as do the reader (on credit) and the producer it answers with; a wait anywhere else is R1's refusal, a 500. Weighed: every call into handler code on a coroutine after the turn, with no wrapper; and handlers called inside the read as in v1, with the wrapper. Decision 0003 item 2 amended; plan §14's M7.1 note cuts M7.1 into three steps: the scheduler; every handler after the turn; `awaiting`. Design §5.2's note.

CHOSEN WHILE BUILDING, flagged for review, each in decision 0014's section of that name, under its step:
- the first step: a drain that runs until nothing is ready; spawning only enqueues, so a callback may spawn; the phase and the coroutine running the process's, not a scheduler's;
- the second step: one scheduler a loop, shared by every shell on it; a raise out of the drain taken by the turn's guard as a callback's; a handler whose connection has closed before the drain not called; `serve`'s loop checked in a process of its own; R5 held by `make check-imports` too, since no check can see the phase a feed runs in;
- the third step: `awaiting` exported with M7.2's verbs, not before; an answer of `awaiting` waits wherever it is given.

Tried and taken out: a scheduler for each shell (the second step: a turn of one shell's never drained another's calls, and the socket suites run several on a loop); a guard around each handler call (the second step, taken out by the review for one a turn); `credit` after a reader's end answer (the third step: the contract test caught it, the fake giving none).

FOUND WHILE BUILDING, each fixed with its check (the second step): nothing ran `serve` itself, so its loop, now the scheduler's turn, had no check (M7B-8 survived every suite until the serve suite's process); and the loops' schedulers, kept first in a weak table, held their loops for good, since a scheduler's poll holds its loop (a loop let go was never collected; an ephemeron table lets it go, M7B-11).

DECIDED on the owner's word (2026-10-02), by form, after the plan-vs-landed walkthrough: **a /code-review high of the branch first, its findings fixed on the owner's word, then three stacked PRs**, one a layer, each proved green on its own tree before its commit: the scheduler, with decision 0014 and the spike (557 inserted lines of code and tests); every handler after the turn (441 inserted, 127 deleted); `awaiting` (288 inserted, 29 deleted). Weighed: the three PRs without the review; the review, then one PR of 1,286 inserted lines.

M7.1's REVIEW (2026-10-02, on the owner's form): a /code-review high of the uncommitted branch found ten. Measured for the form, through a real socket, a client on the shell's loop sending 10,000 keep-alive GETs one at a time (scratch `review/shell-alloc.sps`, three runs each): the branch's shell, client and chez-libuv's Scheme side allocate 14,000 to 14,006 B a request where main's allocate 12,316 to 12,328, the time the same, 86 to 87 µs, the loop's round trip. Of the 1,680 B more, measured by taking each away: the guard each deferred call ran under (`in-drain`) 317 B; the phase around a feed, a closure and `dynamic-wind`, 135 B; the turn's `dynamic-wind` around its poll about 420 B, over the turns a request takes; the deferral as a whole, in-drain included, about 950 B.

DECIDED on the owner's word (2026-10-02), by three forms in one:
- **the six small findings fixed**: decision 0014 item 3's wording (a wait on no coroutine is R2's, R1's only inside a libuv callback); a handler call skipped when its connection has closed before the drain reaches it, as a waiting connection's calls are, with a check; the import rule broadened, the pure libraries importing no private library and the adapter none of the shell's or the scheduler's; the serve suite reading the child's `listening` line; and two stale comments. Weighed: the code ones only; leaving them recorded;
- **the two per-request costs cut**: one guard a turn, `shell-turn!`'s, catching whatever the drain raises as a callback's raise, in place of one a call (which also logs a contract fault once, where it was logged twice), and the feed's phase set without a closure; then the bytes and ab at one connection measured again. The poll's `dynamic-wind` stays, paid a turn, keeping the phase right after a raise. Weighed: the poll's wrapper cut too; leaving all recorded;
- **the fake shell and `awaiting` left to M7.3**, recorded: the fake answers an `awaiting` as a response, which the core answers 500, so no fake-shell suite plays a waiting handler until M7.3 gives the fake the coroutine path. Weighed: refusing it by name now.

FIXED as decided, before the first commit, each with its check or its mutant (m7-mutations.md):
- the six small ones: 0014 item 3 names R2's check and R1's; the closed connection's handler is not called (the shell suite's new check, M7R-1, the second step); the import rule, watched red by an import of the scheduler added to the adapter and to `server.sls` (the second step); the serve suite reads the child's `listening` line; the two comments;
- the two costs: one guard a turn (M7B-10 and M7R-2, the second step), and the feed's phase set and left with no closure, `scheduler-feed-begin!` returning the phase it leaves and `scheduler-feed-end!` setting it back (M7S-K and M7R-3, the first step; the shell's drain sets it back after a raise out of a feed, M7R-5, which survives, the second step). Through the same probe, three runs each beside main's again: the branch allocates 13,580 to 13,604 B a request, main's 12,306 to 12,316, where the branch allocated 14,000 to 14,006 before the fixes; the time the same, 85.8 to 86.8 µs. `ab -k` is measured on the finished tree, the third step's.


M7.1 FIRST STEP: the scheduler (feat/m7.1-scheduler).
- `(http-server private scheduler)`, 248 lines: coroutines on one-shot continuations (`call/1cc`), entered and resumed only from a drain; a turn of the drain, then `poll!`, the one injection point, in 'once when nothing is ready and 'nowait when a coroutine yielded; the phase, 'scheduling, 'in-uv-run around the poll, 'in-parser through a feed (`scheduler-feed-begin!`, `scheduler-feed-end!`); R1, R2, R3 and R5 as checks, each refusal an `&scheduler-invariant`, an `&assertion`, naming its invariant. Nothing imports it yet but its suite.
- `tests/test-scheduler.sps`: seventeen checks against scripted turns, no libuv loaded.

Every suite green on this step's own tree, a scratch worktree cut from main with the step's files laid in, run as `make test` runs them, and `make check-imports` ok: forty-five suites, 1,456 expected passes (1,439 + 17), exit 0.

Watched to fail (m7-mutations.md, the first step): twenty mutants on that tree, M7S's nineteen and the review's M7R-3, and each of the seventeen checks reddened by at least one. The plan's "swap `'once` and `'nowait`" is M7S-A, reddening the yield's check. R2's mutant is M7S-C, a park on no coroutine refused no more, and R3's M7S-B, a coroutine's first run returning normally, into the continuation that first entered it.

Records: decision 0014, 0003's note, plan §14's M7.1 note, design §5.2's note, the research README; the spike's files, and its runs in `out/`; m7-mutations.md.

Size: 566 inserted lines of code and tests, none deleted.

NEXT: the second step, every handler after the turn, stacked on this one.


M7.1 SECOND STEP: every handler after the turn (feat/m7.1-after-the-turn).
- `(http-server connection)`: the rows for an answer that comes after the drain that asks for it (decision 0014 item 1). A request whose body is still arriving waits on its handler in `handling`, reading stopped and nothing armed, and its reader's answer reads again with the body deadline (`read-on`; design §4.4's note). The table's rows that answered in `body` now answer in `handling`, and B3 starts in the head's feed: B2, B3, B4, B6, B11, B15, B19, C3, S4, E3, E5, E6 and E7.
- `(http-server private shell)`: each handler call queued on its loop's scheduler, one a loop, shared by every shell on it and kept for the loop in an ephemeron table, so a loop let go takes it along. The drain makes the call, unless its connection has closed meanwhile, and dispatches its answer there. `shell-turn!` turns the scheduler under one guard, which takes whatever the drain raises as a callback's; `loop-turn!` turns it unguarded, for the suites. Each feed is made in 'in-parser. `serve`'s loop is the turn.
- `(fake-shell)`: a handler called once the outermost drain has ended.
- `make check-imports`: the pure libraries import no private library, and the adapter neither the scheduler nor the shell or serve (R5).
- The checks: in the shell suite, a handler called after libuv's turn, from the drain, on no coroutine (`/phase`); a handler whose connection closed before the drain reached its call not called; a loop let go collected with its scheduler; a raise out of an answer's dispatch logged as a callback's, the connection closed. In the serve suite, `serve` run in a process of its own (`tests/serve-child.sps`). The message loop's `serial?` tells a wait on the handler from a message's end by the paused result before it; the body suite counts a read-stop per message and one as a request waits on its handler; the shell suite's waits turn the scheduler (`run-loop-until`).

Every suite green on this step's own tree, the first step's with this one's files laid in, run as `make test` runs them, and `make check-imports` ok with its new rule: forty-five suites, 1,463 expected passes (1,456 + 7), exit 0.

Watched to fail (m7-mutations.md, the second step): seventeen mutants on that tree, and every check the step added or changed reddened by at least one, the changed ones, the timer's check, row B3 and the message loop's `serial?`, by mutants of their own (M7B-12 to M7B-15). The plan's "call a handler from inside `on-data`" is M7B-4, reddening the `/phase` check. Three survive, each a scope statement: M7B-6, the shell feeding the parser outside `'in-parser`, and M7R-5, its drain not setting the phase back after a raise out of a feed, since nothing a feed runs can wait, and a feed raises only when the parser breaks its contract; and M7B-7, the fake shell calling a handler in place, since `call-handler` ends every drain the core runs today: M7.3's waiting scripts are where it shows.

Records: design §4.4's and §5.3's notes; global-constraints' import rule; m7-mutations.md.

Size: 501 inserted lines of code, tests and the Makefile, 137 deleted.

NEXT: the third step, `awaiting`, stacked on this one.


M7.1 THIRD STEP: `awaiting` (feat/m7.1-awaiting).
- `(http-server awaiting)`, pure, a record of a thunk (decision 0014 item 2). The facade does not export it until M7.2 brings verbs to wait with.
- `(http-server private shell)`: a handler's `awaiting` thunk run on a coroutine, and its answer dispatched on credit; until the connection's next handler is called, each call into its reader and producer made on a coroutine too, one at a time, in order, the event each call brings dispatched once it has ended (`call-waiting!`).
- The checks: in the shell suite, a handler that waits, parked until woken, nothing answered meanwhile, then its answer written; an ordinary handler that waits, a 500, R2's refusal logged; a waiting handler's reader taking each piece on a coroutine, in order, reading waiting on its credit while it takes one; its producer called on a coroutine for each piece; the next request's ordinary reader called in place. The record's own two checks in the body suite.

Measured on the finished tree (2026-10-02, Darwin arm64):
- `make test` green: forty-five suites, 1,478 expected passes (1,463 + 15), every pin ok, the import audit's new rule among them, 27.5 s.
- The allocation suite, the same as on main: curl's GET 1,840 B; the JSON POST 2,624 B read whole and 2,432 B streamed; ab -k's GET 2,112 B.
- `serve` beside main's (`research/spike/m7-serve-ab.sh`, `tests/serve-child.sps` on each tree; ab -k, 50,000 GETs, three rounds, the order alternating, nothing else running; `out/m7-serve-ab.{darwin,linux}.txt`): on Linux, 32 connections, 83,242 to 92,187 requests a second, where main serves 65,101 to 68,231; one connection, 14,247 to 15,052, where main serves 15,181 to 15,537. On Darwin, 32 connections, 32,974 to 34,940, where main serves 33,332 to 33,445; one connection, 11,831 to 11,891, where main serves 12,045 to 12,085. So the deferral's gain the spike measured holds with 32 connections on Linux, and the turn costs a lone connection 1 to 8 per cent a round on Linux and 2 per cent on Darwin. A first Linux run, made while a mutant ran beside it, served 71,709 to 84,692 at 32 connections, and was set aside.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed: `make test`, less its submodule and pin checks, forty-five suites, 1,478 expected passes, 31.3 s, the allocation figures the same; the shell, serve, scheduler and contract suites three runs more each, 148, 12, 17 and 68 passes each time.

Watched to fail (m7-mutations.md, the third step): forty-nine mutants on the finished tree, the first step's twenty and the second step's seventeen again, and the third step's twelve. Every check M7.1 added or changed is reddened by at least one, and the same three survive.

Records: plan §14's built note; decision 0014's choices of the third step; the research README's line on `m7-serve-ab.sh`, the script and its runs; m7-mutations.md.

Size: 292 inserted lines of code and tests, 32 deleted; the slice, 1,359 and 169.

NEXT: the three stacked PRs, merged bottom up on the owner's "do closing ritual" once CI is green on each head. Then M7.2 (plan §14), what a handler awaits, its decision first, when the owner asks.


MERGED to main on 2026-10-02, on the owner's "do closing ritual": **M7.1, as three stacked PRs.**
- **#95, the scheduler,** as 72ac3fb. Its squash tree (d8426e0) is the tested tip's, 1f97bfb's, and its parent is 4a7748b. It merged first and kept its branch, since #96 was based on it.
- **#96, every handler after the turn,** as 4bae222. It was retargeted to main and rebased from #95's tip, 1f97bfb. The rebased tip, 86ad663, has the tested tree (a58ec70, ed67eb4's), and so does the squash, whose parent is 72ac3fb.
- **#97, `awaiting`,** as d41de14. It was retargeted to main and rebased from #96's tip before its rebase, ed67eb4. The rebased tip, 2db446a, has the tested tree (59f665b, 41702eb's), and so does the squash, whose parent is 4bae222.
- **CI.** Each merged on `linux` SUCCESS at its head: #95 on 1f97bfb (run 37032989447); #96 on 86ad663 (run 37035025785); #97 on 2db446a (run 37035237184). Each log holds its step's count: 1,456, 1,463 and 1,478 expected passes.
- **Branches.** All three deleted, local and remote, and refs pruned. No PR is open. #97's `--delete-branch` deleted its remote branch but left this checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: forty-five suites, 1,478 expected passes, every pin ok.

DONE and merged (72ac3fb, PR #95; 4bae222, PR #96; d41de14, PR #97): **M7.1.**
- Every handler is called after libuv's turn, from the scheduler's drain, in place (decision 0014). A handler that waits answers `(awaiting thunk)`: the thunk runs on a coroutine, and so do the reader and producer it answers with, until the next request's handler is called. The core waits for every answer as for a later event: a request whose body is still arriving waits in handling, reading stopped.
- The scheduler, `(http-server private scheduler)`, one a loop, checks R1, R2, R3 and R5. R4's one-shot resume cells are M7.2's.
- `serve` with `ab -k` at 32 connections on Linux served 83,242 to 92,187 requests a second, where main served 65,101 to 68,231. A lone connection is 1 to 8 per cent slower a round on Linux, and 2 per cent on Darwin.
- `awaiting` is not exported yet: the facade exports it with M7.2's verbs. The fake shell's path for a waiting handler is M7.3's, by the review's form.

NEXT: M7.2 (plan §14), what a handler awaits. The waiting verbs are public API, so a decision record comes first, by form on measurements; the brief's exit needs `uv-getaddrinfo!`, and a resume cell is one-shot (R4). On a fresh branch cut from main after this commit, when the owner asks.


M7.2: WHAT A HANDLER WAITS WITH, on the owner's "lets start M7.2". Four stacked steps, cut from main at f5532ee: feat/m7.2-scheduler, then feat/m7.2-await, feat/m7.2-timed-waits and feat/m7.2-resolve, each on the one before; 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED FIRST: `research/spike/m7-waits.sps` with `m7-waits.sh`, which runs it twice on the tree's scheduler and twice on it patched by `m7-scheduler-escape.patch`. Linux is Debian 12 in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6), Chez 10.4.1 `tarm64le`, with patch installed. Decision 0015's Context has the tables. In short, on the patched scheduler:
- a sleep on one timer a loop, armed for the earliest of a binary heap: 4,067 B and 1,687 to 1,688 ns of CPU a sleep on Darwin, 2,168 to 2,234 on Linux, 10,000 sleeping at once; a 10 ms sleep took 11.0 ms on Darwin, 10.2 to 13.7 ms on Linux. On the deadlines' wheel it took 250.7 to 256.2 ms; on a libuv timer a sleep, 10.2 to 13.4 ms, for 5.3 KB more a sleep and 10,000 handles at once;
- `uv-getaddrinfo!` of "localhost", awaited: `("::1" "127.0.0.1")`, 4,221 B a lookup, the medians 176 to 181 µs on Darwin and 120 to 122 µs on Linux;
- a 50 ms deadline around a wait no one ended raised at 51.0 ms on Darwin and 54.9 to 55.6 ms on Linux; the resume that came later was counted, and woke nothing;
- a wait whose resume the handler's own libuv callback was to call, that callback raising first: `uv-run` raised `&uv-callback-error`, and the coroutine never ended.

FOUND while measuring: M7.1's scheduler allocates 3,756 B for each coroutine, even one that never waits, and 7,423 B for one that waits once, 10,000 at once; the spike's scheduler cost about 190 B (decision 0014). The `guard` in `enter!` sits inside the one-shot continuation the drain enters: in scratch probes on Darwin, `call/1cc` alone allocated 70 B a run, a `guard` alone 373 B, and a `guard` inside a `call/1cc` 3,596 B. An exception handler that jumps to the drain's continuation catches the same raises for 374 B, and 4,034 B for a coroutine that waits once. M7.2's first step makes it so.

DECIDED on the owner's word (2026-10-02), by form: **"Server verbs and await (Recommended)" and "One timer, a heap (Recommended)"**; and, for the third question, after the owner's "i need to understand the tradeoffs better" (answered with the three cases in which a close can be seen while code waits, a reader's and a producer's), a form dismissed, and the owner's "Do any of our other test servers do 'It goes on'?" (answered from the surveys: Warp and Node go on; Go cancels the request's context, which only the waits that watch it heed, so the first form put it under "It raises at once" too strongly; hyper drops the handler's future; nginx's proxy closes the upstream request by default, `proxy_ignore_client_abort off`, read in nginx's documentation; Racket's server kills the handler's thread): **"It goes on (Recommended)".** Decision 0015: a handler waits with `await`, `sleep-ms`, `resolve` and `with-deadline`, which the facade exports with `awaiting`; a wait is one-shot, a late resume logged as `late-resume` (R4); sleeps and deadlines are timed to the millisecond by one libuv timer a loop over a binary heap; a reader's or a producer's wait goes on when its connection closes. Weighed: the server's verbs alone; anything libuv offers; the deadlines' wheel; a libuv timer a wait; a wait that raises at once on a close. Decision 0014 item 4 noted; plan §14's M7.2 note cuts M7.2 into four steps: the scheduler without `guard`; `await`; the timed waits; the shell's waits.

DECIDED on the owner's word (2026-10-02), by form, after the plan-vs-landed walkthrough: **"Review, then 4 stacked PRs (Recommended)"**: a /code-review high of the uncommitted branch first, its findings fixed on the owner's word, then one PR a step, each proved green on its own tree before its commit. Weighed: the same with the heap a PR of its own (306 lines), and the four PRs with no review.

M7.2's REVIEW (2026-10-02, on the owner's form): a /code-review high of the uncommitted branch, all four steps, found seven:
1. an escape from `with-deadline`'s thunk by a continuation left the deadline in force: probed, a 50 ms sleep after the escape, outside the deadline, raised `&deadline-passed` at 5 ms;
2. `resolve` raised chez-libuv's own EINVAL for a name over 255 octets, which libuv refuses at the call, not `&resolve-error`: probed with a name of 300 characters;
3. `with-deadline` passed one value only: a thunk answering two raised "returned 2 values to single value return context";
4. the shell suite's failed lookup asked the host's resolver about no-such-host.invalid, so it hung on the network: with no network in Docker it answered EAI_AGAIN; `a..b`, an empty label, answers EAI_NONAME at once with a network and without, and on Darwin;
5. `late-resume` was logged with no word of which wait;
6. the scheduler's header said a coroutine keeps its deadlines, where it keeps the wait it is parked on and a count;
7. three lines of the shell over 100 characters.
Measured for the form, on a coroutine (scratch `dw-cost.sps`, `catch-cost.sps`): a `with-deadline` held by a `dynamic-wind` that tells a park from an exit costs 672 B where the exception handler's costs 688 (1,250 B and 1,232 three deep), leaves the deadline on an escape and passes two values through; a one-shot escape around libuv's call costs 208 B a lookup, where a `guard` costs 3,663.

DECIDED on the owner's word (2026-10-02), by form: **"Fix all seven (Recommended)"**. Weighed: the three bugs alone; all but the log line.

FIXED as decided, before the first commit, each in the step it belongs to, with its check or its mutant (m7-mutations.md, "The review's fixes"):
- the first and the third, in the third step: `with-deadline` is held by a `dynamic-wind`, whose after thunk a park runs too; it leaves the deadline once, unless the coroutine is suspending (the scheduler's `coroutine-suspending?`). The waits suite's checks: an escape from the thunk by a continuation takes the deadline out, and a wait after it is not cut short; every value the thunk returns comes back; a continuation that enters the thunk again and leaves it again ends the deadline once (M7T-26 to M7T-30);
- the second, in the fourth step: the shell catches a name refused at the call, by libuv's EINVAL or by chez-libuv's own refusal, with a handler that jumps out on a one-shot continuation, and answers `invalid-name`, where it tested a name for emptiness and a NUL itself; the shell suite's check gains a name of 300 characters (M7L-15 to M7L-18);
- the fourth, in the fourth step: the shell suite's failed lookup asks about `a..b`, and reads EAI_NONAME exactly;
- the fifth, in the second step: a wait's cell keeps the verb that made it, and a late resume's log line names it, `late-resume await` or `late-resume resolve`; R4's checks read it (M7W-15);
- the sixth and the seventh, in the third and the fourth steps: the scheduler's header; the shell's lines over 100 characters, and the waits' header, reflowed.
Found while fixing: the first re-cuts of M7W-1 and M7W-4 left a parenthesis open, so they did not load; their reports were read for `Exception`, and they were cut again, the parentheses counted.

M7.2 FIRST STEP: the scheduler without `guard` (feat/m7.2-scheduler).
- `(http-server private scheduler)`: a coroutine's raise caught by an exception handler that jumps to the drain's current continuation, through `end!`, which the end by its value shares; no `guard` (decision 0015's Context).
- The checks, in the scheduler suite: a coroutine that ends, by its value or by a raise, allocates no stack of its own, under 1,024 B where a parked one's stack is 3,515 B (design §5.2), 1,000 at once, the instrument calibrated by 1,000 parked at once; and a coroutine that raises after a park has its raise come to its end procedure, through the drain that resumed it.

Measured on the step's tree (2026-10-02, Darwin arm64):
- `make test` green: forty-five suites, 1,482 expected passes (1,478 + 4), every pin ok.
- What the checks read, 1,000 coroutines at once (scratch `each.sps`): 368 B ending by its value, 544 B by a raise, 3,772 B parked; on main's scheduler, 3,756 B, 4,289 B and 7,161 B.
- Its behavior unchanged, beside main's scheduler, in seven cases a check does not cover (scratch `edges.sps`): a raise after a park; an `after` thunk that raises as a raise unwinds, and as a value returns; `raise-continuable`; a `warning`; a handler inside the coroutine that raises; an error. Each ends the coroutine with the same raise.
- A `guard` that handler code runs on a coroutine still costs a stack: 4,097 B for a coroutine that runs one, where one that ends at once costs 434 B (scratch `guard-inside.sps`); `with-exception-handler` 496 B, `dynamic-wind` 416 B. So M7.2's own code on a coroutine catches nothing with `guard`.

Watched to fail (m7-mutations.md, M7.2's first step): five mutants on the step's tree, each reddening the scheduler suite alone; every check the step added is reddened by one.

Records: decision 0015; plan §14's M7.2 note; decision 0014 item 4's note; design §5.2's note; the research README's line on `m7-waits.sps`, `m7-waits.sh` and `m7-scheduler-escape.patch`, and their runs.

Size: 71 inserted lines of code and tests, 8 deleted.

NEXT: the second step, `await`, stacked on this one.

M7.2 SECOND STEP: `await` and R4 (feat/m7.2-await). The plan's note had the facade's exports, the shell's part and the docs as the fourth step, after the timed waits; built instead a verb at a time, each step one a handler can use: `await` here, `sleep-ms` and `with-deadline` next, `resolve` last.
- `(http-server private waits)`: `(await register)`, a one-shot resume on the scheduler's park and wake (R4): a resume called while `register` runs ends the wait at once; every later one is logged as `late-resume`, with the verb it came for (the review's fifth), and wakes nothing. A wait asks first whether the coroutine running may park, so one refused has run nothing; a wait on a loop that keeps no waits is an assertion violation. Nothing in it catches with `guard`.
- `(http-server private scheduler)`: `waiting-coroutine`, the refusals a park makes, now asked by a wait before it begins too; `coroutine-scheduler`; and the loop's waits, kept and never read (`scheduler-waits`).
- `(http-server private shell)`: the loop's scheduler keeps the loop's waits, made with the log of the first shell on the loop.
- The facade exports `awaiting` and `await`. `docs/handlers.org` gains "Waiting". `make check-imports` holds the waits out of the adapter, with the scheduler, the shell and serve (R5).
- The checks: the waits suite, eight, against scripted turns, no libuv; in the shell suite, a handler that waits on `await`, parked, woken by another request's ordinary handler, both answered, the second resume logged; the serve suite's list of the facade's exports.

Measured on the step's tree (2026-10-02, Darwin arm64): `make test` green, forty-six suites, 1,492 expected passes (1,482 + 10), every pin ok, the import audit's new rule among them.

Watched to fail (m7-mutations.md, M7.2's second step, and the review's fixes): fifteen mutants on the step's tree, the review's M7W-15 and design §5.3's third among them (M7W-1, both R4 rows red); every check the step added is reddened by one; M7.1's R1, R2 and R5 mutants, which matched nothing once the refusals moved into `waiting-coroutine`, re-cut and red again. The import audit's new rule, watched red in a scratch copy with the adapter importing the waits, and passed by main's rule.

Records: decision 0015's choices of the second step; design §5.3's note on R4; the scheduler's and the shell's headers; `docs/handlers.org`.

Size: 402 inserted lines of code, tests and Makefile, 33 deleted.

NEXT: the third step, `sleep-ms` and `with-deadline`, stacked on this one.
